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
    (with-exclusive-lock ((%db-lock db))
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
  (with-exclusive-lock ((%db-lock db))
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

(defgeneric %cursor-edit (c visit &key writable)
  (:documentation "Visit C's current record with VISIT, a function of
its key and value as octets that answers as a visitor does; retried if
another thread removes the record first.  The record's (values key
value), or NIL with the reason."))

(defmethod %cursor-edit (c visit &key (writable t))
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

(defmethod %cursor-edit ((c tree-cursor) visit &key (writable t))
  ;; The record is found and visited under one hold of the database, as
  ;; by Kyoto's single accept: a key another thread puts before it
  ;; meanwhile draws the edit to itself, not past it (#9).
  (let ((db (%tc-db c))
        (from (%tc-key c)))
    (if (null from)
        (%fail db :no-record)
        (%accepting (db writable)
          (with-shared-lock ((%db-lock db))
            (%check-open db)
            (let ((e (tree-db-engine db)))
              (flet ((edit (k)
                       ;; Under K's stripe.  (values done key value):
                       ;; done when K is still the first record at or
                       ;; after FROM, else the record now there to try.
                       (multiple-value-bind (now old)
                           (engine-ceiling e from nil)
                         (if (and now (equalp now k))
                             (let ((answer (funcall visit k old)))
                               (when writable
                                 (case answer
                                   ((nil :nop))
                                   (:remove (engine-delete e k))
                                   (t (engine-put e k (to-octets answer)))))
                               (values t k old))
                             (values nil now nil)))))
                (let ((k (and (= (%tc-clears c) (%db-clears db))
                              (engine-ceiling e from nil))))
                  (loop
                    (setf (%tc-key c) k)
                    (unless k
                      (return (%fail db :no-record)))
                    (multiple-value-bind (done next old)
                        (let ((s (%stripe db (%key-digest db k))))
                          (if writable
                              (with-exclusive-lock (s) (edit k))
                              (with-shared-lock (s) (edit k))))
                      (when done
                        (return (values k old)))
                      (setf k next)))))))))))

(defmethod cursor-accept (cursor visitor &key (writable t) step
                                              (as :octets))
  (check-as as)
  (let* ((removed nil)
         (k (%cursor-edit cursor
                          (lambda (k v)
                            (let ((answer (funcall visitor
                                                   (from-octets k as)
                                                   (from-octets v as))))
                              (when (and writable (eq answer :remove))
                                (setf removed t))
                              answer))
                          :writable writable)))
    (and k
         (progn (when (or removed step)
                  (%cursor-pass cursor k))
                t))))
