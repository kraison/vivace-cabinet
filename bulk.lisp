;;;; Bulk operations (spec: API).  Atomic ones are one DB-ACCEPT-BULK;
;;;; the rest loop over the single-record operations, as Kyoto's do.

(in-package #:vivace-cabinet)

(defun %last-values (records)
  "RECORDS' keys as octets, each once in the order first given, and a
table of each key's last value."
  (let ((table (make-hash-table :test 'equalp))
        (keys '()))
    (loop for (key . value) in records
          do (let ((k (to-octets key)))
               (unless (nth-value 1 (gethash k table))
                 (push k keys))
               (setf (gethash k table) (to-octets value))))
    (values (nreverse keys) table)))

(defmethod db-set-bulk ((db database) records &key (atomic t))
  (multiple-value-bind (keys table) (%last-values records)
    (if atomic
        (and (db-accept-bulk db keys
                             (lambda (k v)
                               (declare (ignore v))
                               (gethash k table)))
             (length keys))
        (loop for k in keys
              unless (db-set db k (gethash k table))
                return nil
              count t))))

(defun %unique-octets (keys)
  "KEYS as octets, each once, in the order first given."
  (let ((seen (make-hash-table :test 'equalp)))
    (loop for key in keys
          for k = (to-octets key)
          unless (gethash k seen)
            collect (setf (gethash k seen) k))))

(defmethod db-get-bulk ((db database) keys &key (atomic t) (as :octets))
  (check-as as)
  (let ((found '()))
    (if atomic
        (db-accept-bulk db (%unique-octets keys)
                        (lambda (k v)
                          (when v
                            (push (cons (from-octets k as) (from-octets v as))
                                  found))
                          :nop)
                        :writable nil)
        (dolist (k (%unique-octets keys))
          (let ((v (db-get db k)))
            (when v
              (push (cons (from-octets k as) (from-octets v as)) found)))))
    (nreverse found)))

(defmethod db-remove-bulk ((db database) keys &key (atomic t))
  (if atomic
      (let ((n 0))
        (and (db-accept-bulk db (%unique-octets keys)
                             (lambda (k v)
                               (declare (ignore k))
                               (if v
                                   (progn (incf n) :remove)
                                   :nop)))
             n))
      (if (%db-writable-p db)
          (count-if (lambda (k) (db-remove db k)) (%unique-octets keys))
          (%fail db :no-permission))))
