;;;; What every database type shares: the directory and its lock, the
;;;; header, open modes, per-thread error codes and per-key stripe locks
;;;; (spec: API).  HashDB and TreeDB supply storage through the generics
;;;; below.

(in-package #:vivace-cabinet)

(alexandria:define-constant +stripes+ 1024)
(alexandria:define-constant +header-bytes+ 32)
(alexandria:define-constant +header-magic+ #(86 67 65 66) :test 'equalp)
(alexandria:define-constant +open-modes+
    '(:reader :writer :create :truncate :autosync) :test 'equal)

(defclass database ()
  ((dir :initarg :dir :reader %db-dir)
   (writable :initarg :writable :reader %db-writable-p)
   (autosync :initarg :autosync :reader %db-autosync-p)
   (tuning :initarg :tuning :reader %db-tuning)
   (heap :initform nil :accessor %db-heap)
   (lock :initform (make-rw-lock) :reader %db-lock)
   (stripes :reader %db-stripes
            :initform (let ((v (make-array +stripes+)))
                        (dotimes (i +stripes+ v)
                          (setf (aref v i) (make-rw-lock)))))
   (errors :initform (make-hash-table :test 'eq
                                      #+sbcl :weakness #+sbcl :key)
           :reader %db-errors)
   (errors-lock :initform (make-lock "database errors")
                :reader %db-errors-lock)
   (open-p :initform nil :accessor %db-open-p)
   (lock-fd :initform nil :accessor %db-lock-fd)))

;;; What each type supplies

(defgeneric %type-code (db)
  (:documentation "The header's type byte: 1 for HashDB, 2 for TreeDB."))

(defgeneric %engine-code (db)
  (:documentation "The header's engine byte; 0 for a type without one.")
  (:method ((db database)) 0))

(defgeneric %header-address (db)
  (:documentation "The heap address the header records, or 0.")
  (:method ((db database)) 0))

(defgeneric %record-count (db))

(defgeneric %create-storage (db)
  (:documentation "Create DB's storage in its existing directory."))

(defgeneric %open-storage (db header)
  (:documentation "Open DB's storage; HEADER is %READ-HEADER's plist."))

(defgeneric %close-storage (db)
  (:documentation "Close whatever of DB's storage is open."))

(defgeneric %sync-storage (db)
  (:documentation "Flush DB's mapped files to disk."))

;;; Files and the header

(defun %heap-file (dir) (merge-pathnames "heap.dat" dir))
(defun %index-dir (dir) (merge-pathnames "index/" dir))
(defun %header-file (dir) (merge-pathnames "header.dat" dir))

(defun %put-u64 (octets offset n)
  (dotimes (i 8)
    (setf (aref octets (+ offset i)) (ldb (byte 8 (* 8 i)) n))))

(defun %get-u64 (octets offset)
  (let ((n 0))
    (dotimes (i 8 n)
      (setf n (logior n (ash (aref octets (+ offset i)) (* 8 i)))))))

(defun %write-header (db &key open)
  "Write DB's header: magic VCAB, format 1, type, OPEN (1 while a writer
has the database open), engine, record count, structure address."
  (let ((h (make-array +header-bytes+ :element-type '(unsigned-byte 8)
                                      :initial-element 0)))
    (replace h +header-magic+)
    (setf (aref h 4) 1
          (aref h 5) (%type-code db)
          (aref h 6) (if open 1 0)
          (aref h 7) (%engine-code db))
    (%put-u64 h 8 (%record-count db))
    (%put-u64 h 16 (%header-address db))
    (with-open-file (out (%header-file (%db-dir db))
                         :direction :output :if-exists :supersede
                         :element-type '(unsigned-byte 8))
      (write-sequence h out))))

(defun %read-header (dir)
  "DIR's header as a plist: :TYPE (:HASH or :TREE), :OPEN, :ENGINE, :COUNT
and :ADDRESS.  Signals OPEN-ERROR for anything else."
  (let ((h (make-array +header-bytes+ :element-type '(unsigned-byte 8))))
    (with-open-file (in (%header-file dir) :element-type '(unsigned-byte 8))
      (unless (= +header-bytes+ (read-sequence h in))
        (%signal 'open-error "~a: header too short" dir)))
    (unless (and (equalp (subseq h 0 4) +header-magic+)
                 (= 1 (aref h 4))
                 (member (aref h 5) '(1 2)))
      (%signal 'open-error "~a: not a vivace-cabinet database" dir))
    (list :type (if (= 1 (aref h 5)) :hash :tree)
          :open (= 1 (aref h 6))
          :engine (aref h 7)
          :count (%get-u64 h 8)
          :address (%get-u64 h 16))))

(defun %storage-present-p (dir)
  "True when any of a database's files exist in DIR."
  (or (probe-file (%header-file dir)) (probe-file (%heap-file dir))
      (probe-file (%index-dir dir))))

(defun %delete-storage (dir)
  (dolist (f (list (%header-file dir) (%heap-file dir)))
    (when (probe-file f)
      (delete-file f)))
  (uiop:delete-directory-tree (%index-dir dir) :validate t
                                               :if-does-not-exist :ignore))

;;; Opening and closing

(defun %check-mode (mode)
  "Signal INVALID-ARGUMENT unless MODE lists open modes with exactly one
of :READER and :WRITER."
  (unless (and (listp mode)
               (every (lambda (m) (member m +open-modes+)) mode))
    (%signal 'invalid-argument "MODE must be a list of ~s: ~s"
             +open-modes+ mode))
  (unless (= 1 (count-if (lambda (m) (member m mode)) '(:reader :writer)))
    (%signal 'invalid-argument
             "MODE needs exactly one of :READER and :WRITER: ~s" mode)))

(defun %guard-storage (db thunk)
  "Call THUNK, which creates or opens DB's storage; if it fails, close
what it opened and signal OPEN-ERROR."
  (handler-case (funcall thunk)
    (error (c)
      (ignore-errors (%close-storage db))
      (if (typep c 'open-error)
          (error c)
          (%signal 'open-error "~a: ~a" (%db-dir db) c)))))

(defun %open-existing (db)
  (let ((header (%read-header (%db-dir db))))
    (unless (= (%type-code db) (if (eq :hash (getf header :type)) 1 2))
      (%signal 'open-error "~a: a ~(~a~) database" (%db-dir db)
               (getf header :type)))
    (%open-storage db header)))

(defun %unlock (db)
  (when (%db-lock-fd db)
    (unlock-directory (%db-lock-fd db))
    (setf (%db-lock-fd db) nil)))

(defun %open-database (db mode)
  "Lock DB's directory, then open, create or truncate its storage as MODE
says.  Returns DB."
  (let ((dir (%db-dir db))
        (writer (%db-writable-p db)))
    (unless (probe-file dir)
      (unless (and writer (member :create mode))
        (%signal 'open-error
                 "~a: no database here (open with :CREATE)" dir))
      (ensure-directories-exist dir))
    (setf (%db-lock-fd db)
          (or (lock-directory dir writer)
              (%signal 'open-error "~a: open in another handle" dir)))
    (let ((ok nil))
      (unwind-protect
           (progn
             (cond ((and writer (member :truncate mode)
                         (%storage-present-p dir))
                    (%delete-storage dir)
                    (%guard-storage db (lambda () (%create-storage db))))
                   ((probe-file (%header-file dir))
                    (%guard-storage db (lambda () (%open-existing db))))
                   ((%storage-present-p dir)
                    (%signal 'open-error "~a: incomplete database (open ~
                                          with :TRUNCATE to discard it)"
                             dir))
                   ((and writer (member :create mode))
                    (%guard-storage db (lambda () (%create-storage db))))
                   (t (%signal 'open-error
                               "~a: no database here (open with :CREATE)"
                               dir)))
             (when writer
               (%write-header db :open t))
             (setf ok t))
        (unless ok
          (%unlock db))))
    (setf (%db-open-p db) t)
    db))

(defmethod close-db ((db database))
  (with-write-lock ((%db-lock db))
    (prog1 (when (%db-open-p db)
             (when (%db-writable-p db)
               (%write-header db))
             (%close-storage db)
             (setf (%db-open-p db) nil)
             t)
      (%unlock db))))

;;; Per-key machinery

(defun %stripe (db digest)
  "The stripe lock for a 16-byte DIGEST."
  (aref (%db-stripes db)
        (logand (logior (aref digest 0) (ash (aref digest 1) 8))
                (1- +stripes+))))

(defun %check-open (db)
  (unless (%db-open-p db)
    (%signal 'invalid-argument "the database is closed")))

(defmacro with-key-locked ((db digest mode) &body body)
  "Run BODY holding DB's lock shared and DIGEST's stripe for MODE (:READ
or :WRITE)."
  (let ((d (gensym "DB")) (s (gensym "STRIPE")))
    `(let ((,d ,db))
       (with-read-lock ((%db-lock ,d))
         (%check-open ,d)
         (let ((,s (%stripe ,d ,digest)))
           ,(ecase mode
              (:read `(with-read-lock (,s) ,@body))
              (:write `(with-write-lock (,s) ,@body))))))))

(defun %fail (db code)
  "Record CODE as the calling thread's last failure on DB; return NIL."
  (with-lock-held ((%db-errors-lock db))
    (setf (gethash (current-thread) (%db-errors db)) code))
  nil)

(defmethod db-error ((db database))
  (with-lock-held ((%db-errors-lock db))
    (values (gethash (current-thread) (%db-errors db) :success))))

(defmacro %writing ((db) &body body)
  "Run BODY if DB is writable, then synchronize under :AUTOSYNC;
otherwise fail with :NO-PERMISSION."
  `(if (%db-writable-p ,db)
       (multiple-value-prog1 (progn ,@body)
         (when (%db-autosync-p ,db)
           (db-synchronize ,db)))
       (%fail ,db :no-permission)))

;;; Whole-database operations

(defmethod db-path ((db database))
  (namestring (%db-dir db)))

(defmethod db-count ((db database))
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (%record-count db)))

(defmethod db-synchronize ((db database) &key hard)
  (declare (ignore hard))
  (with-write-lock ((%db-lock db))
    (%check-open db)
    (when (%db-writable-p db)
      (%sync-storage db)
      (%write-header db :open t))
    t))

(defmethod db-clear ((db database))
  (if (%db-writable-p db)
      (with-write-lock ((%db-lock db))
        (%check-open db)
        (%close-storage db)
        (%delete-storage (%db-dir db))
        (%create-storage db)
        (%write-header db :open t)
        t)
      (%fail db :no-permission)))
