;;;; HashDB's cursor: forward through the index a bucket at a time, in no
;;;; useful order (spec: API).  It reads a bucket's keys when it reaches
;;;; the bucket, so a record a concurrent split moves to a later bucket
;;;; can be seen twice, and one moved to an earlier bucket missed.

(in-package #:vivace-cabinet)

(defclass hash-cursor ()
  ((db :initarg :db :reader %hc-db)
   (bucket :initform -1 :accessor %hc-bucket)
   (pending :initform nil :accessor %hc-pending)
   (key :initform nil :accessor %hc-key)
   (clears :initform 0 :accessor %hc-clears)))

(defmethod db-cursor ((db hash-db))
  (make-instance 'hash-cursor :db db))

(defun %hc-bucket-keys (db bucket)
  "The keys in BUCKET of DB's index, chain by chain, and whether BUCKET
is past the last one.  Each chain is read under its stripe."
  (let* ((index (hash-db-index db))
         (heap (%db-heap db))
         (past nil)
         (digests (with-read-lock ((%lhash-split-lock index))
                    (if (< bucket (%bucket-count index))
                        ;; Under the bucket's lock: removing a key clears
                        ;; the bucket and re-adds the rest.
                        (with-locked-hash-bucket (index bucket)
                          (mapcar #'car
                                  (read-bucket index (%lhash-table index)
                                               (bucket-offset index
                                                              bucket))))
                        (setf past t)))))
    (values (unless past
              (loop for d in digests
                    nconc (with-read-lock ((%stripe db d))
                            (loop for addr = (lhash-get index d)
                                    then (record-next heap addr)
                                  until (or (null addr) (zerop addr))
                                  collect (record-key heap addr)))))
            past)))

(defun %hc-advance (c)
  "Move C to the next key and return it, or NIL at the end.  The caller
holds the database lock."
  (loop
    (when (%hc-pending c)
      (return (setf (%hc-key c) (pop (%hc-pending c)))))
    (multiple-value-bind (keys past)
        (%hc-bucket-keys (%hc-db c) (incf (%hc-bucket c)))
      (when past
        (return (setf (%hc-key c) nil)))
      (setf (%hc-pending c) keys))))

(defmacro %with-hash-cursor ((db c) &body body)
  "Run BODY with DB bound to C's database, holding its lock shared."
  `(let ((,db (%hc-db ,c)))
     (with-read-lock ((%db-lock ,db))
       (%check-open ,db)
       ,@body)))

(defmethod cursor-jump ((c hash-cursor) &optional key)
  (%with-hash-cursor (db c)
    (setf (%hc-clears c) (%db-clears db))
    (if (null key)
        (progn (setf (%hc-bucket c) -1
                     (%hc-pending c) nil)
               (or (and (%hc-advance c) t)
                   (%fail db :no-record)))
        (let* ((k (to-octets key))
               (d (%digest k))
               (index (hash-db-index db)))
          (if (with-read-lock ((%stripe db d))
                (%find db d k))
              (let ((b (with-read-lock ((%lhash-split-lock index))
                         (hash index (%lhash-level index) d))))
                (setf (%hc-bucket c) b
                      (%hc-pending c) (rest (member k (%hc-bucket-keys db b)
                                                    :test #'equalp))
                      (%hc-key c) k)
                t)
              (%fail db :no-record))))))

(defmethod %cursor-current ((c hash-cursor))
  (%with-hash-cursor (db c)
    (when (/= (%hc-clears c) (%db-clears db))
      (setf (%hc-key c) nil))
    (loop
      (let ((k (%hc-key c)))
        (unless k
          (return nil))
        (let* ((d (%digest k))
               (v (with-read-lock ((%stripe db d))
                    (let ((addr (%find db d k)))
                      (and addr (record-value (%db-heap db) addr))))))
          (when v
            (return (values k v)))
          (%hc-advance c))))))

(defmethod %cursor-pass ((c hash-cursor) key)
  (declare (ignore key))
  (%with-hash-cursor (db c)
    (%hc-advance c)))

(defmethod cursor-step ((c hash-cursor))
  (if (and (%cursor-current c)
           (%with-hash-cursor (db c)
             (%hc-advance c)))
      t
      (%fail (%hc-db c) :no-record)))

(defmethod cursor-get ((c hash-cursor) &key (as :octets) step)
  (check-as as)
  (multiple-value-bind (k v) (%cursor-current c)
    (cond ((null k) (%fail (%hc-db c) :no-record))
          (t (when step
               (%cursor-pass c k))
             (values (from-octets k as) (from-octets v as))))))

(defmethod cursor-set-value ((c hash-cursor) value)
  (let ((v (to-octets value)))
    (and (%cursor-edit c (lambda (k old)
                           (declare (ignore k old))
                           v))
         t)))

(defmethod cursor-remove ((c hash-cursor))
  (let ((k (%cursor-edit c (constantly :remove))))
    (and k (progn (%cursor-pass c k) t))))

(defmethod cursor-seize ((c hash-cursor) &key (as :octets))
  (check-as as)
  (multiple-value-bind (k v) (%cursor-edit c (constantly :remove))
    (when k
      (%cursor-pass c k)
      (values (from-octets k as) (from-octets v as)))))

(defmethod cursor-jump-back ((c hash-cursor) &optional key)
  (declare (ignore key))
  (%signal 'not-implemented "a HashDB cursor moves forward only"))

(defmethod cursor-step-back ((c hash-cursor))
  (%signal 'not-implemented "a HashDB cursor moves forward only"))

(defmethod %cursor-db ((c hash-cursor))
  (%hc-db c))

(defmethod %key-batches ((db hash-db))
  (let ((bucket -1)
        (lock (make-lock "hash key batches")))
    (lambda ()
      (loop
        (multiple-value-bind (keys past)
            (%hc-bucket-keys db (with-lock-held (lock) (incf bucket)))
          (cond (past (return nil))
                (keys (return keys))))))))
