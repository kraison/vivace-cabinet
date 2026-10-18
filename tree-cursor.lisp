;;;; TreeDB's cursor: its position is a key, so changes to the tree leave
;;;; it valid; each move asks the engine for the next or previous key
;;;; (spec: API).  If its record is removed, the cursor reads the next one
;;;; in the direction it last moved.

(in-package #:vivace-cabinet)

(defclass tree-cursor ()
  ((db :initarg :db :reader %tc-db)
   (key :initform nil :accessor %tc-key)
   (backward :initform nil :accessor %tc-backward)))

(defmethod db-cursor ((db tree-db))
  (make-instance 'tree-cursor :db db))

(defun %tc-find (c fn key strict)
  "The key (FN engine KEY STRICT) finds in C's database, or NIL."
  (let ((db (%tc-db c)))
    (with-read-lock ((%db-lock db))
      (%check-open db)
      (values (funcall fn (tree-db-engine db) key strict)))))

(defun %tc-seek (c fn key strict)
  "Move C to the record (FN engine KEY STRICT) finds; T, or NIL with
:NO-RECORD.  FN ENGINE-FLOOR makes C's direction backward."
  (setf (%tc-backward c) (eq fn #'engine-floor)
        (%tc-key c) (%tc-find c fn key strict))
  (or (and (%tc-key c) t)
      (%fail (%tc-db c) :no-record)))

(defmethod cursor-jump ((c tree-cursor) &optional key)
  (%tc-seek c #'engine-ceiling (and key (to-octets key)) nil))

(defmethod cursor-jump-back ((c tree-cursor) &optional key)
  (%tc-seek c #'engine-floor (and key (to-octets key)) nil))

(defmethod cursor-step ((c tree-cursor))
  (if (%tc-key c)
      (%tc-seek c #'engine-ceiling (%tc-key c) t)
      (%fail (%tc-db c) :no-record)))

(defmethod cursor-step-back ((c tree-cursor))
  (if (%tc-key c)
      (%tc-seek c #'engine-floor (%tc-key c) t)
      (%fail (%tc-db c) :no-record)))

(defmethod cursor-get ((c tree-cursor) &key (as :octets))
  (check-as as)
  (let ((db (%tc-db c)))
    (if (null (%tc-key c))
        (%fail db :no-record)
        (multiple-value-bind (k v)
            (with-read-lock ((%db-lock db))
              (%check-open db)
              (funcall (if (%tc-backward c) #'engine-floor #'engine-ceiling)
                       (tree-db-engine db) (%tc-key c) nil))
          (setf (%tc-key c) k)
          (if k
              (values (from-octets k as) (from-octets v as))
              (%fail db :no-record))))))

(defmethod cursor-set-value ((c tree-cursor) value)
  (if (%tc-key c)
      (db-replace (%tc-db c) (%tc-key c) value)
      (%fail (%tc-db c) :no-record)))

(defmethod cursor-remove ((c tree-cursor))
  (let ((k (%tc-key c)))
    (cond ((null k) (%fail (%tc-db c) :no-record))
          ((db-remove (%tc-db c) k)
           (setf (%tc-key c) (%tc-find c #'engine-ceiling k t))
           t))))

(defmethod cursor-seize ((c tree-cursor) &key (as :octets))
  (check-as as)
  (let ((k (%tc-key c)))
    (if (null k)
        (%fail (%tc-db c) :no-record)
        (let ((v (db-seize (%tc-db c) k)))
          (when v
            (setf (%tc-key c) (%tc-find c #'engine-ceiling k t))
            (values (from-octets k as) (from-octets v as)))))))

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
