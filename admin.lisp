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
  (%holding (db :shared)
    (list* :type (if (typep db 'tree-db) :tree :hash)
           :path (db-path db)
           :count (%record-count db)
           :size (%size db)
           :writable (%db-writable-p db)
           :autosync (%db-autosync-p db)
           (%status db))))

(defmethod db-occupy ((db database) fn &key (writable t))
  (flet ((run ()
           (if (%visiting (db)
                 (funcall fn (db-path db) (%record-count db) (%size db)))
               t
               (%fail db :logic))))
    (if writable
        (%holding (db :exclusive) (run))
        (%holding (db :shared) (run)))))

;;; Copying

(alexandria:define-constant +seek-data+ 3)
(alexandria:define-constant +seek-hole+ 4)
(alexandria:define-constant +enxio+ 6)

(defun %lseek (fd offset whence)
  "lseek(2): the new offset, or -1."
  (cffi:foreign-funcall "lseek" :int fd :long offset :int whence :long))

(defun %next-data (fd from size)
  "The next run of data in FD at or after FROM as (values start end), or
NIL when only holes remain (SEEK_DATA and SEEK_HOLE).  A file system
without them reports the rest of the file as data."
  (let ((start (%lseek fd from +seek-data+)))
    (cond ((>= start 0)
           (let ((end (%lseek fd start +seek-hole+)))
             (values start (if (minusp end) size end))))
          ((= (sb-alien:get-errno) +enxio+) nil)
          (t (values from size)))))

(defun %file-mode (path)
  "PATH's permission bits."
  (multiple-value-bind (ok dev ino mode)
      (sb-unix:unix-stat (uiop:native-namestring path))
    (declare (ignore dev ino))
    (and ok (logand mode #o7777))))

(defun %set-length (stream length)
  "ftruncate(2) STREAM's file to LENGTH, once its output is written."
  (finish-output stream)
  (unless (zerop (cffi:foreign-funcall "ftruncate"
                                       :int (sb-sys:fd-stream-fd stream)
                                       :long length :int))
    (%signal 'system-error "cannot set the length of ~a" (pathname stream))))

(defun %copy-sparse (from to)
  "Copy file FROM to TO with FROM's mode, reading only FROM's data (#8)
and leaving 64 KiB runs of zeros as holes: the linear hash's index
files are mostly holes.  Returns the number of bytes read."
  (let ((buf (make-array 65536 :element-type '(unsigned-byte 8)))
        (bytes 0))
    (declare (type (simple-array (unsigned-byte 8) (65536)) buf))
    (with-open-file (in from :element-type '(unsigned-byte 8))
      (with-open-file (out to :direction :output :if-exists :error
                              :element-type '(unsigned-byte 8))
        (let ((size (file-length in))
              ;; Seeking for data must not move IN's own offset.
              (fd (%posix-open from +o-rdonly+)))
          (unwind-protect
               (loop with pos = 0
                     while (< pos size)
                     do (multiple-value-bind (start end)
                            (%next-data fd pos size)
                          (unless start
                            (return))
                          (file-position in start)
                          (file-position out start)
                          (loop while (< start end)
                                do (let ((n (read-sequence
                                             buf in
                                             :end (min 65536 (- end start)))))
                                     (when (zerop n)
                                       (return))
                                     (incf bytes n)
                                     (if (loop for i below n
                                               always (zerop (aref buf i)))
                                         (file-position out (+ start n))
                                         (write-sequence buf out :end n))
                                     (incf start n)))
                          (setf pos end)))
            (%posix-close fd))
          ;; The copy's length, holes at the end included, and mode.
          (%set-length out size)
          (%posix-fchmod (sb-sys:fd-stream-fd out) (%file-mode from)))))
    bytes))

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
    (%holding (db :exclusive)
      (%with-system-errors
        (when (%db-writable-p db)
          (%sync-storage db nil)
          (%write-header db :open t))
        (%copy-tree (%db-dir db) to)
        ;; Synchronized just now, so the copy needs no recount; a
        ;; reader's header says what the last writer left.
        (when (%db-writable-p db)
          (%mark-closed to)))
      t)))

;;; Merging

(defmethod db-merge ((db database) sources &key (mode :set))
  (unless (member mode '(:set :add :replace :append))
    (%signal 'invalid-argument
             "MODE must be :SET, :ADD, :REPLACE or :APPEND: ~s" mode))
  (when (member db sources)
    (%signal 'invalid-argument "a database cannot merge into itself"))
  (%ensure-open db)
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
