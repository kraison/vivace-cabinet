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
   (clears :initform 0 :accessor %db-clears)
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

(defgeneric %sync-storage (db hard)
  (:documentation "Flush DB's mapped files: to the device when HARD,
else to the operating system."))

;;; Files and the header

(defun %heap-file (dir) (merge-pathnames "heap.dat" dir))
(defun %index-dir (dir) (merge-pathnames "index/" dir))
(defun %header-file (dir) (merge-pathnames "header.dat" dir))
(defun %header-temp-file (dir) (merge-pathnames "header.tmp" dir))

(defun %put-u64 (octets offset n)
  (dotimes (i 8)
    (setf (aref octets (+ offset i)) (ldb (byte 8 (* 8 i)) n))))

(defun %get-u64 (octets offset)
  (let ((n 0))
    (dotimes (i 8 n)
      (setf n (logior n (ash (aref octets (+ offset i)) (* 8 i)))))))

(defun %replace-file (path octets hard)
  "Write OCTETS to PATH through PATH.tmp and rename(2), so PATH holds its
old or its new contents and never less (#6).  HARD fsyncs the file
before the rename and the directory after it."
  (let* ((tmp (namestring (make-pathname :type "tmp" :defaults path)))
         (fd (%posix-open tmp (logior +o-wronly+ +o-creat+ +o-trunc+))))
    (unwind-protect
         (cffi:with-pointer-to-vector-data (p octets)
           (unless (= (length octets) (%posix-write fd p (length octets)))
             (error "short write to ~a" tmp))
           (when hard
             (%posix-fsync fd)))
      (%posix-close fd))
    (%posix-rename tmp (namestring path))
    (when hard
      (let ((dir (%posix-open (uiop:pathname-directory-pathname path)
                              +o-rdonly+)))
        (unwind-protect (%posix-fsync dir)
          (%posix-close dir))))))

(defun %write-header (db &key open hard)
  "Write DB's header: magic VCAB, format 1, type, OPEN (1 while a writer
has the database open), engine, record count, structure address.  It
replaces header.dat whole; HARD makes it durable."
  (let ((h (make-array +header-bytes+ :element-type '(unsigned-byte 8)
                                      :initial-element 0)))
    (replace h +header-magic+)
    (setf (aref h 4) 1
          (aref h 5) (%type-code db)
          (aref h 6) (if open 1 0)
          (aref h 7) (%engine-code db))
    (%put-u64 h 8 (%record-count db))
    (%put-u64 h 16 (%header-address db))
    (%replace-file (%header-file (%db-dir db)) h hard)))

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
  (dolist (f (list (%header-file dir) (%header-temp-file dir)
                   (%heap-file dir)))
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

(defun %check-count (name value least)
  "Signal INVALID-ARGUMENT unless VALUE, the tuning keyword NAME's, is an
integer of at least LEAST."
  (unless (and (integerp value) (>= value least))
    (%signal 'invalid-argument "~s must be an integer of at least ~d: ~s"
             name least value)))

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
    (cond ((uiop:directory-exists-p dir))
          ((probe-file dir)
           (%signal 'open-error "~a: not a directory" dir))
          ((and writer (member :create mode))
           (ensure-directories-exist dir))
          (t (%signal 'open-error
                      "~a: no database here (open with :CREATE)" dir)))
    (setf (%db-lock-fd db)
          (or (handler-case (lock-directory dir writer)
                (error (c)
                  (%signal 'open-error "~a: ~a" dir c)))
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
               (%write-header db :hard t))
             (%close-storage db)
             (setf (%db-open-p db) nil)
             t)
      (%unlock db))))

;;; Per-key machinery

(defun %stripe (db digest)
  "The stripe lock for a 16-byte DIGEST."
  (aref (%db-stripes db) (%stripe-index digest)))

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

(defun %autosync (db)
  "Synchronize DB after a write under :AUTOSYNC, unless another thread
has closed it meanwhile: CLOSE-DB synchronized it then (#6)."
  (with-write-lock ((%db-lock db))
    (when (%db-open-p db)
      (%sync-storage db nil)
      (%write-header db :open t))))

(defmacro %writing ((db) &body body)
  "Run BODY if DB is writable and, when its first value is not NIL (a
logical failure returns NIL), synchronize under :AUTOSYNC; otherwise
fail with :NO-PERMISSION."
  (let ((values (gensym "VALUES")))
    `(if (%db-writable-p ,db)
         (let ((,values (multiple-value-list (progn ,@body))))
           (when (and (first ,values) (%db-autosync-p ,db))
             (%autosync ,db))
           (values-list ,values))
         (%fail ,db :no-permission))))

;;; Whole-database operations

(defmethod db-path ((db database))
  (namestring (%db-dir db)))

(defmethod db-count ((db database))
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (%record-count db)))

(defmethod db-synchronize ((db database) &key hard)
  "Flush DB's files to the operating system and write its header; with
HARD, force both to the device (#6).  T."
  (with-write-lock ((%db-lock db))
    (%check-open db)
    (when (%db-writable-p db)
      (%sync-storage db hard)
      (%write-header db :open t :hard hard))
    t))

(defmethod db-clear ((db database))
  (if (%db-writable-p db)
      (with-write-lock ((%db-lock db))
        (%check-open db)
        (%close-storage db)
        (%delete-storage (%db-dir db))
        (%create-storage db)
        (%write-header db :open t)
        ;; Cursors positioned before a clear are invalid, as in Kyoto.
        (incf (%db-clears db))
        t)
      (%fail db :no-permission)))

;;; Visiting records (visitors.lisp builds on these)

(defun %stripe-index (digest)
  (logand (logior (aref digest 0) (ash (aref digest 1) 8))
          (1- +stripes+)))

(defun %call-with-stripes (db digests mode fn)
  "Call FN holding DB's lock shared and the stripes of DIGESTS for MODE
(:READ or :WRITE), each taken once and in index order, so that calls
over overlapping keys cannot deadlock."
  (let ((indexes (sort (remove-duplicates (mapcar #'%stripe-index digests))
                       #'<)))
    (with-read-lock ((%db-lock db))
      (%check-open db)
      (labels ((take (rest)
                 (if (null rest)
                     (funcall fn)
                     (let ((s (aref (%db-stripes db) (first rest))))
                       (ecase mode
                         (:read (with-read-lock (s) (take (rest rest))))
                         (:write (with-write-lock (s)
                                   (take (rest rest)))))))))
        (take indexes)))))

(defgeneric %key-digest (db key)
  (:documentation "KEY's 16-byte digest, which picks its stripe."))

(defgeneric %visit (db key digest visitor as writable)
  (:documentation "Call VISITOR with KEY and its value (NIL when absent),
both decoded AS, and when WRITABLE apply its answer: NIL or :NOP keeps
the record, :REMOVE removes it, anything else is stored.  The caller
holds KEY's stripe, or the whole database.  Returns the answer."))

(defgeneric %key-batches (db)
  (:documentation "A function that returns the next batch of DB's keys
on each call and NIL when there are no more; safe to call from several
threads.  Each key comes in one batch when nothing writes meanwhile."))

(defun %walk-keys (db fn)
  "Call FN with each of DB's keys; FN may change or remove that key's
record.  The caller holds DB exclusively."
  (loop with next = (%key-batches db)
        for batch = (funcall next)
        while batch
        do (mapc fn batch)))

(defgeneric %size (db)
  (:documentation "DB-SIZE without the lock."))

(defmethod db-size ((db database))
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (%size db)))
