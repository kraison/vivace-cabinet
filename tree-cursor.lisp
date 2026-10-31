;;;; TreeDB's cursor, as Kyoto's tree cursor behaves (kcplantdb.h): its
;;;; position is a key.  Each read, edit or step first moves it to the
;;;; first record at or after that key; removing a record moves it on in
;;;; the direction it last moved; DB-CLEAR leaves it nowhere.

(in-package #:vivace-cabinet)

(defclass tree-cursor ()
  ((db :initarg :db :reader %tc-db)
   (key :initform nil :accessor %tc-key)
   (backward :initform nil :accessor %tc-backward)
   (clears :initform 0 :accessor %tc-clears)))

(defmethod db-cursor ((db tree-db))
  (make-instance 'tree-cursor :db db))

(defun %tc-search (c fn)
  "Call FN on C's database's engine, holding the database shared: FN's
(values key value), then the clear count read under the same hold (#9).
A count the cursor's differs from means a clear came between.  A move
asks the engine for the key alone, so it reads no value (#7)."
  (let ((db (%tc-db c)))
    (with-read-lock ((%db-lock db))
      (%check-open db)
      (multiple-value-bind (k v) (funcall fn (tree-db-engine db))
        (values k v (%db-clears db))))))

(defun %tc-place (c key backward clears)
  "Put C at KEY, NIL for nowhere, as of the clear count CLEARS; T, or
NIL with :NO-RECORD."
  (setf (%tc-key c) key
        (%tc-backward c) backward
        (%tc-clears c) clears)
  (or (and key t)
      (%fail (%tc-db c) :no-record)))

(defun %tc-jump (c fn key backward)
  "Put C at the record (FN engine KEY NIL) finds."
  (multiple-value-bind (k v clears)
      (%tc-search c (lambda (e) (funcall fn e key nil nil)))
    (declare (ignore v))
    (%tc-place c k backward clears)))

(defun %tc-move (c fn backward)
  "Put C at the record (FN engine) finds from C's key: nowhere when C
is nowhere, or when the database was cleared since C was placed."
  (if (%tc-key c)
      (multiple-value-bind (k v clears) (%tc-search c fn)
        (declare (ignore v))
        (%tc-place c (and (= clears (%tc-clears c)) k) backward clears))
      (%fail (%tc-db c) :no-record)))

(defmethod %cursor-current ((c tree-cursor))
  (when (%tc-key c)
    (multiple-value-bind (k v clears)
        (%tc-search c (lambda (e) (engine-ceiling e (%tc-key c) nil)))
      (setf (%tc-key c) (and (= clears (%tc-clears c)) k))
      (and (%tc-key c) (values k v)))))

(defmethod %cursor-pass ((c tree-cursor) key)
  (let ((fn (if (%tc-backward c) #'engine-floor #'engine-ceiling)))
    (%tc-move c (lambda (e) (funcall fn e key t nil)) (%tc-backward c))))

(defmethod cursor-jump ((c tree-cursor) &optional key)
  (%tc-jump c #'engine-ceiling (and key (to-octets key)) nil))

(defmethod cursor-jump-back ((c tree-cursor) &optional key)
  (%tc-jump c #'engine-floor (and key (to-octets key)) t))

(defmethod cursor-step ((c tree-cursor))
  ;; Past the record a read would land on, found under the same hold.
  (%tc-move c (lambda (e)
                (let ((k (engine-ceiling e (%tc-key c) nil nil)))
                  (and k (engine-ceiling e k t nil))))
            nil))

(defmethod cursor-step-back ((c tree-cursor))
  (%tc-move c (lambda (e) (engine-floor e (%tc-key c) t nil)) t))

(defmethod cursor-get ((c tree-cursor) &key (as :octets) step)
  (check-as as)
  (multiple-value-bind (k v) (%cursor-current c)
    (cond ((null k) (%fail (%tc-db c) :no-record))
          (t (when step
               (%cursor-pass c k))
             (values (from-octets k as) (from-octets v as))))))

(defmethod cursor-set-value ((c tree-cursor) value)
  (let ((v (to-octets value)))
    (and (%cursor-edit c (lambda (k old)
                           (declare (ignore k old))
                           v))
         t)))

(defmethod cursor-remove ((c tree-cursor))
  (let ((k (%cursor-edit c (constantly :remove))))
    (and k (progn (%cursor-pass c k) t))))

(defmethod cursor-seize ((c tree-cursor) &key (as :octets))
  (check-as as)
  (multiple-value-bind (k v) (%cursor-edit c (constantly :remove))
    (when k
      (%cursor-pass c k)
      (values (from-octets k as) (from-octets v as)))))

(defmethod %cursor-db ((c tree-cursor))
  (%tc-db c))

(defmethod %key-batches ((db tree-db))
  (let ((e (tree-db-engine db))
        (lock (make-lock "tree key batches"))
        (last nil)
        (done nil))
    (lambda ()
      (with-lock-held (lock)
        (unless done
          (let ((batch (loop repeat 256
                             for k = (engine-ceiling e last (and last t) nil)
                             while k
                             collect (setf last k))))
            (unless batch
              (setf done t))
            batch))))))
