;;;; Visitors (spec: API): a function of a key and its value (NIL when
;;;; absent) that answers :NOP, :REMOVE or a new value.  It runs while
;;;; the key's stripe, or the whole database, is held, so it must not
;;;; call the database.

(in-package #:vivace-cabinet)

(defmacro %accepting ((db writable) &body body)
  "Run BODY, which visits for WRITABLE.  A writable visit on a reader
fails with :NO-PERMISSION, and one under :AUTOSYNC synchronizes after."
  `(cond ((not ,writable) ,@body)
         ((not (%db-writable-p ,db)) (%fail ,db :no-permission))
         (t (multiple-value-prog1 (progn ,@body)
              (when (%db-autosync-p ,db)
                (db-synchronize ,db))))))

(defmethod db-accept ((db database) key visitor &key (writable t)
                                                     (as :octets))
  (check-as as)
  (%accepting (db writable)
    (let* ((k (to-octets key))
           (d (%key-digest db k)))
      (%call-with-stripes db (list d) (if writable :write :read)
                          (lambda ()
                            (%visit db k d visitor as writable)))
      t)))

(defmethod db-accept-bulk ((db database) keys visitor &key (writable t)
                                                          (as :octets))
  (check-as as)
  (%accepting (db writable)
    (let* ((ks (mapcar #'to-octets keys))
           (ds (mapcar (lambda (k) (%key-digest db k)) ks)))
      (%call-with-stripes db ds (if writable :write :read)
                          (lambda ()
                            (mapc (lambda (k d)
                                    (%visit db k d visitor as writable))
                                  ks ds)))
      t)))

(defmethod db-iterate ((db database) visitor &key (writable t)
                                                  (as :octets))
  (check-as as)
  (%accepting (db writable)
    (with-write-lock ((%db-lock db))
      (%check-open db)
      (%walk-keys db (lambda (k)
                       (%visit db k (%key-digest db k) visitor as writable)))
      t)))

(defmethod db-scan-parallel ((db database) visitor &key (threads 4)
                                                        (as :octets))
  (check-as as)
  (unless (typep threads '(integer 1))
    (%signal 'invalid-argument "THREADS must be a positive integer: ~s"
             threads))
  ;; The database is held throughout, so the workers read unlocked.
  (with-write-lock ((%db-lock db))
    (%check-open db)
    (let ((next (%key-batches db))
          (lock (make-lock "scan failure"))
          (failure nil)
          (workers '())
          (started nil))
      (flet ((fail (c)
               (with-lock-held (lock)
                 (unless failure
                   (setf failure c))))
             (work ()
               (loop for batch = (funcall next)
                     while (and batch (not failure))
                     do (dolist (k batch)
                          (%visit db k (%key-digest db k) visitor as nil)))))
        ;; Every worker started is joined before the lock is released.
        (unwind-protect
             (progn
               (dotimes (i threads)
                 (push (make-thread (lambda ()
                                      (handler-case (work)
                                        (serious-condition (c) (fail c))))
                                    :name "vivace-cabinet scan")
                       workers))
               (setf started t))
          (unless started
            (fail :abandoned))
          (dolist (w workers)
            (ignore-errors (join-thread w)))))
      (when failure
        (error failure))
      t)))

(defun %cursor-edit (c visit &key (writable t))
  "Visit C's current record with VISIT, a function of its key and value
as octets that answers as a visitor does; retried if another thread
removes the record first.  The record's (values key value), or NIL with
the reason."
  (let ((db (%cursor-db c)))
    (loop
      (let ((k (%cursor-current c))
            (old nil))
        (unless k
          (return (%fail db :no-record)))
        (unless (db-accept db k (lambda (key v)
                                  (if (setf old v)
                                      (funcall visit key v)
                                      :nop))
                           :writable writable)
          (return nil))
        (when old
          (return (values k old)))))))

(defmethod cursor-accept (cursor visitor &key (writable t) step
                                              (as :octets))
  (check-as as)
  (let ((removed nil))
    (and (%cursor-edit cursor
                       (lambda (k v)
                         (let ((answer (funcall visitor (from-octets k as)
                                                (from-octets v as))))
                           (when (eq answer :remove)
                             (setf removed k))
                           answer))
                       :writable writable)
         (progn (cond (removed (%cursor-pass cursor removed))
                      (step (cursor-step cursor)))
                t))))
