;;;; Whole-database administration (spec: API): status, occupying the
;;;; database, copying its files, and merging others into it.

(in-package #:vivace-cabinet)

(defgeneric %status (db)
  (:documentation "DB-STATUS's entries for DB's type.")
  (:method ((db hash-db))
    (list :buckets (bucket-count (hash-db-index db))))
  (:method ((db tree-db))
    (list :engine (%engine-kind (%engine-code db)))))

(defmethod db-status ((db database))
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (list* :type (if (typep db 'tree-db) :tree :hash)
           :path (db-path db)
           :count (%record-count db)
           :size (%size db)
           :writable (%db-writable-p db)
           :autosync (%db-autosync-p db)
           (%status db))))

(defmethod db-occupy ((db database) fn &key (writable t))
  (flet ((run ()
           (%check-open db)
           (if (funcall fn (db-path db) (%record-count db) (%size db))
               t
               (%fail db :logic))))
    (if writable
        (with-write-lock ((%db-lock db)) (run))
        (with-read-lock ((%db-lock db)) (run)))))

;;; Copying

(defun %copy-sparse (from to)
  "Copy file FROM to TO, leaving 64 KiB runs of zeros as holes: the
linear hash's index files are mostly holes."
  (let ((buf (make-array 65536 :element-type '(unsigned-byte 8))))
    (declare (type (simple-array (unsigned-byte 8) (65536)) buf))
    (with-open-file (in from :element-type '(unsigned-byte 8))
      (with-open-file (out to :direction :output :if-exists :error
                              :element-type '(unsigned-byte 8))
        (let ((pos 0)
              (hole nil))
          (loop for n = (read-sequence buf in)
                until (zerop n)
                do (setf hole (loop for i below n always (zerop (aref buf i))))
                   (if hole
                       (file-position out (+ pos n))
                       (write-sequence buf out :end n))
                   (incf pos n))
          ;; A file ending in a hole needs its last byte written to keep
          ;; its length.
          (when hole
            (file-position out (1- pos))
            (write-byte 0 out)))))))

(defun %copy-tree (from to)
  (ensure-directories-exist to)
  (dolist (f (uiop:directory-files from))
    (%copy-sparse f (merge-pathnames (file-namestring f) to)))
  (dolist (d (uiop:subdirectories from))
    (%copy-tree d (merge-pathnames
                   (make-pathname :directory
                                  (list :relative
                                        (car (last (pathname-directory d)))))
                   to))))

(defun %mark-closed (dir)
  "Clear the open flag in DIR's header."
  (with-open-file (s (%header-file dir) :direction :io :if-exists :overwrite
                                        :element-type '(unsigned-byte 8))
    (file-position s 6)
    (write-byte 0 s)))

(defmethod db-copy ((db database) dest)
  (let ((to (uiop:ensure-directory-pathname (merge-pathnames dest)))
        (dir (%db-dir db)))
    (when (probe-file to)
      (%signal 'invalid-argument "~a already exists" to))
    ;; A copy inside the database would copy itself without end.
    (when (or (uiop:subpathp to dir)
              (and (probe-file dir) (uiop:subpathp to (truename dir))))
      (%signal 'invalid-argument "~a is inside the database ~a" to dir))
    (with-write-lock ((%db-lock db))
      (%check-open db)
      (when (%db-writable-p db)
        (%sync-storage db)
        (%write-header db :open t))
      (%copy-tree (%db-dir db) to)
      ;; Synchronized just now, so the copy needs no recount; a reader's
      ;; header says what the last writer left.
      (when (%db-writable-p db)
        (%mark-closed to))
      t)))

;;; Merging

(defmethod db-merge ((db database) sources &key (mode :set))
  (unless (member mode '(:set :add :replace :append))
    (%signal 'invalid-argument
             "MODE must be :SET, :ADD, :REPLACE or :APPEND: ~s" mode))
  (when (member db sources)
    (%signal 'invalid-argument "a database cannot merge into itself"))
  (if (not (%db-writable-p db))
      (%fail db :no-permission)
      (dolist (src sources t)
        (with-cursor (cur src)
          (when (cursor-jump cur)
            (loop
              (multiple-value-bind (k v) (cursor-get cur :step t)
                (unless k
                  (return))
                (ecase mode
                  (:set (db-set db k v))
                  (:add (db-add db k v))
                  (:replace (db-replace db k v))
                  (:append (db-append db k v))))))))))
