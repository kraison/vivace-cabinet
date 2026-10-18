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

(defun %tc-find (c fn key strict)
  "(FN engine KEY STRICT) in C's database: (values key value), or NIL."
  (let ((db (%tc-db c)))
    (with-read-lock ((%db-lock db))
      (%check-open db)
      (funcall fn (tree-db-engine db) key strict))))

(defun %tc-place (c key backward)
  "Put C at KEY, NIL for nowhere; T, or NIL with :NO-RECORD."
  (setf (%tc-key c) key
        (%tc-backward c) backward
        (%tc-clears c) (%db-clears (%tc-db c)))
  (or (and key t)
      (%fail (%tc-db c) :no-record)))

(defmethod %cursor-current ((c tree-cursor))
  (when (/= (%tc-clears c) (%db-clears (%tc-db c)))
    (setf (%tc-key c) nil))
  (when (%tc-key c)
    (multiple-value-bind (k v) (%tc-find c #'engine-ceiling (%tc-key c) nil)
      (setf (%tc-key c) k)
      (and k (values k v)))))

(defmethod %cursor-pass ((c tree-cursor) key)
  (%tc-place c (%tc-find c (if (%tc-backward c)
                               #'engine-floor
                               #'engine-ceiling)
                         key t)
             (%tc-backward c)))

(defmethod cursor-jump ((c tree-cursor) &optional key)
  (%tc-place c (%tc-find c #'engine-ceiling (and key (to-octets key)) nil)
             nil))

(defmethod cursor-jump-back ((c tree-cursor) &optional key)
  (%tc-place c (%tc-find c #'engine-floor (and key (to-octets key)) nil)
             t))

(defmethod cursor-step ((c tree-cursor))
  (let ((k (%cursor-current c)))
    (if k
        (%tc-place c (%tc-find c #'engine-ceiling k t) nil)
        (%fail (%tc-db c) :no-record))))

(defmethod cursor-step-back ((c tree-cursor))
  (if (and (%tc-key c) (= (%tc-clears c) (%db-clears (%tc-db c))))
      (%tc-place c (%tc-find c #'engine-floor (%tc-key c) t) t)
      (%fail (%tc-db c) :no-record)))

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
                             for k = (engine-ceiling e last (and last t))
                             while k
                             collect (setf last k))))
            (unless batch
              (setf done t))
            batch))))))
