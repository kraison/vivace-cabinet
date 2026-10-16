;;;; HashDB: records in a heap, indexed by the linear hash from a key's
;;;; 16-byte digest to the first record of that digest's chain (spec:
;;;; HashDB).  Per-key work holds the digest's stripe lock under the
;;;; database's lock, which clear, close and synchronize take alone.

(in-package #:vivace-cabinet)

(defun murmur3-digest (key)
  (murmur3-128 key 0))

(defvar *key-digest* 'murmur3-digest
  "Function from key octets to a 16-byte digest.  Tests bind it to force
collisions; a database must keep one digest function for life.")

(alexandria:define-constant +stripes+ 1024)
(alexandria:define-constant +header-bytes+ 32)
(alexandria:define-constant +header-magic+ #(86 67 65 66) :test 'equalp)

(defclass hash-db ()
  ((dir :initarg :dir :reader hash-db-dir)
   (writable :initarg :writable :reader hash-db-writable-p)
   (autosync :initarg :autosync :reader hash-db-autosync-p)
   (tuning :initarg :tuning :reader hash-db-tuning)
   (heap :initform nil :accessor hash-db-heap)
   (index :initform nil :accessor hash-db-index)
   (record-count :initform 0 :accessor hash-db-record-count)
   (count-lock :initform (make-lock "hash-db count")
               :reader hash-db-count-lock)
   (lock :initform (make-rw-lock) :reader hash-db-lock)
   (stripes :reader hash-db-stripes
            :initform (let ((v (make-array +stripes+)))
                        (dotimes (i +stripes+ v)
                          (setf (aref v i) (make-rw-lock)))))
   (errors :initform (make-hash-table :test 'eq
                                      #+sbcl :weakness #+sbcl :key)
           :reader hash-db-errors)
   (errors-lock :initform (make-lock "hash-db errors")
                :reader hash-db-errors-lock)
   (open-p :initform nil :accessor hash-db-open-p)
   (lock-fd :initform nil :accessor hash-db-lock-fd)))

;;; Files

(defun %heap-file (dir) (merge-pathnames "heap.dat" dir))
(defun %index-dir (dir) (merge-pathnames "index/" dir))
(defun %header-file (dir) (merge-pathnames "header.dat" dir))

(defun %write-header (db)
  "Write DB's header: magic VCAB, format 1, type 1 (hash), record count."
  (let ((h (make-array +header-bytes+ :element-type '(unsigned-byte 8)
                                      :initial-element 0))
        (n (hash-db-record-count db)))
    (replace h +header-magic+)
    (setf (aref h 4) 1
          (aref h 5) 1)
    (dotimes (i 8)
      (setf (aref h (+ 8 i)) (ldb (byte 8 (* 8 i)) n)))
    (with-open-file (out (%header-file (hash-db-dir db))
                         :direction :output :if-exists :supersede
                         :element-type '(unsigned-byte 8))
      (write-sequence h out))))

(defun %read-header (dir)
  "The record count in DIR's header; signals OPEN-ERROR for anything but
a HashDB header."
  (let ((h (make-array +header-bytes+ :element-type '(unsigned-byte 8))))
    (with-open-file (in (%header-file dir) :element-type '(unsigned-byte 8))
      (unless (= +header-bytes+ (read-sequence h in))
        (%signal 'open-error "~a: header too short" dir)))
    (unless (and (equalp (subseq h 0 4) +header-magic+)
                 (= 1 (aref h 4))
                 (= 1 (aref h 5)))
      (%signal 'open-error "~a: not a vivace-cabinet HashDB" dir))
    (let ((n 0))
      (dotimes (i 8 n)
        (setf n (logior n (ash (aref h (+ 8 i)) (* 8 i))))))))

(defun %create-storage (db)
  (destructuring-bind (&key buckets max-locks heap-size heap-reservation)
      (hash-db-tuning db)
    (let ((dir (hash-db-dir db)))
      (ensure-directories-exist (%index-dir dir))
      (setf (hash-db-heap db) (let ((*mmap-min-reservation*
                                      heap-reservation))
                                (create-memory (namestring (%heap-file dir))
                                               heap-size))
            (hash-db-index db) (make-lhash :location (%index-dir dir)
                                           :buckets buckets
                                           :max-locks max-locks)
            (hash-db-record-count db) 0)
      (%write-header db))))

(defun %open-storage (db)
  "Open DB's existing files.  A failure closes what opened and signals
OPEN-ERROR."
  (destructuring-bind (&key heap-reservation &allow-other-keys)
      (hash-db-tuning db)
    (let ((dir (hash-db-dir db)))
      (handler-case
          (setf (hash-db-record-count db) (%read-header dir)
                (hash-db-heap db) (let ((*mmap-min-reservation*
                                          heap-reservation))
                                    (open-memory
                                     (namestring (%heap-file dir))))
                (hash-db-index db) (open-lhash (%index-dir dir)))
        (error (c)
          (when (hash-db-heap db)
            (ignore-errors (close-memory (hash-db-heap db)))
            (setf (hash-db-heap db) nil))
          (if (typep c 'open-error)
              (error c)
              (%signal 'open-error "~a: ~a" dir c)))))))

(alexandria:define-constant +open-modes+
    '(:reader :writer :create :truncate :autosync) :test 'equal)

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

(defun open-hash-db (dir &key (mode '(:writer :create)) (buckets 4)
                           (max-locks *max-locks*)
                           (heap-size (* 64 1024 1024))
                           (heap-reservation (* 64 1024 1024 1024)))
  "Open the HashDB in DIR.  MODE holds :READER or :WRITER, and any of
:CREATE, :TRUNCATE, :AUTOSYNC.  BUCKETS and MAX-LOCKS tune the linear
hash; HEAP-SIZE is the heap's first size; HEAP-RESERVATION is the address
space the heap may grow into before it must be reopened."
  (let ((bad (set-difference mode +open-modes+)))
    (when bad
      (%signal 'invalid-argument "unknown open modes ~s" bad)))
  (unless (= 1 (count-if (lambda (m) (member m mode)) '(:reader :writer)))
    (%signal 'invalid-argument
             "MODE needs exactly one of :READER and :WRITER: ~s" mode))
  (let* ((writer (and (member :writer mode) t))
         (db (make-instance 'hash-db
                            :dir dir :writable writer
                            :autosync (and (member :autosync mode) t)
                            :tuning (list :buckets buckets
                                          :max-locks max-locks
                                          :heap-size heap-size
                                          :heap-reservation
                                          heap-reservation))))
    (unless (probe-file dir)
      (unless (and writer (member :create mode))
        (%signal 'open-error
                 "~a: no database here (open with :CREATE)" dir))
      (ensure-directories-exist dir))
    (setf (hash-db-lock-fd db)
          (or (lock-directory dir writer)
              (%signal 'open-error "~a: open in another handle" dir)))
    (let ((ok nil))
      (unwind-protect
           (progn
             (cond ((and writer (member :truncate mode)
                         (%storage-present-p dir))
                    (%delete-storage dir)
                    (%create-storage db))
                   ((probe-file (%header-file dir)) (%open-storage db))
                   ((%storage-present-p dir)
                    (%signal 'open-error "~a: incomplete database (open ~
                                          with :TRUNCATE to discard it)"
                             dir))
                   ((and writer (member :create mode)) (%create-storage db))
                   (t (%signal 'open-error
                               "~a: no database here (open with :CREATE)"
                               dir)))
             (setf ok t))
        (unless ok
          (%unlock db))))
    (setf (hash-db-open-p db) t)
    db))

(defun %unlock (db)
  (when (hash-db-lock-fd db)
    (unlock-directory (hash-db-lock-fd db))
    (setf (hash-db-lock-fd db) nil)))

(defmethod close-db ((db hash-db))
  (with-write-lock ((hash-db-lock db))
    (prog1 (when (hash-db-open-p db)
             (when (hash-db-writable-p db)
               (%write-header db))
             (close-lhash (hash-db-index db))
             (close-memory (hash-db-heap db))
             (setf (hash-db-open-p db) nil)
             t)
      (%unlock db))))

;;; Per-key machinery

(defun %digest (key)
  "KEY's digest from *KEY-DIGEST*, with the linear hash's reserved
all-zero key remapped (spec: HashDB)."
  (let ((d (funcall *key-digest* key)))
    (if (every #'zerop d)
        (let ((c (copy-seq d)))
          (setf (aref c 15) 1)
          c)
        d)))

(defun %stripe (db digest)
  (aref (hash-db-stripes db)
        (logand (logior (aref digest 0) (ash (aref digest 1) 8))
                (1- +stripes+))))

(defun %check-open (db)
  (unless (hash-db-open-p db)
    (%signal 'invalid-argument "the database is closed")))

(defmacro with-key-locked ((db digest mode) &body body)
  "Run BODY holding DB's lock shared and DIGEST's stripe for MODE (:READ
or :WRITE)."
  (let ((d (gensym "DB")) (s (gensym "STRIPE")))
    `(let ((,d ,db))
       (with-read-lock ((hash-db-lock ,d))
         (%check-open ,d)
         (let ((,s (%stripe ,d ,digest)))
           ,(ecase mode
              (:read `(with-read-lock (,s) ,@body))
              (:write `(with-write-lock (,s) ,@body))))))))

(defun %fail (db code)
  "Record CODE as the calling thread's last failure on DB; return NIL."
  (with-lock-held ((hash-db-errors-lock db))
    (setf (gethash (current-thread) (hash-db-errors db)) code))
  nil)

(defmethod db-error ((db hash-db))
  (with-lock-held ((hash-db-errors-lock db))
    (values (gethash (current-thread) (hash-db-errors db) :success))))

(defmacro %writing ((db) &body body)
  "Run BODY if DB is writable, then synchronize under :AUTOSYNC;
otherwise fail with :NO-PERMISSION."
  `(if (hash-db-writable-p ,db)
       (multiple-value-prog1 (progn ,@body)
         (when (hash-db-autosync-p ,db)
           (db-synchronize ,db)))
       (%fail ,db :no-permission)))

(defun %find (db digest key)
  "The address of KEY's record and of the record before it in DIGEST's
chain (NIL at the head); NIL if KEY is absent."
  (let ((heap (hash-db-heap db)))
    (loop with prev = nil
          for addr = (lhash-get (hash-db-index db) digest)
            then (record-next heap addr)
          until (or (null addr) (zerop addr))
          when (record-key= heap addr key)
            do (return (values addr prev))
          do (setf prev addr))))

(defun %insert-record (db digest key value)
  (let* ((index (hash-db-index db))
         (head (lhash-get index digest))
         (addr (write-record (hash-db-heap db) key value (or head 0))))
    (if head
        (lhash-update index digest addr)
        (lhash-insert index digest addr))
    (with-lock-held ((hash-db-count-lock db))
      (incf (hash-db-record-count db)))
    addr))

(defun %replace-record (db digest addr prev key value)
  (let* ((heap (hash-db-heap db))
         (new (write-record heap key value (record-next heap addr))))
    (if prev
        (setf (record-next heap prev) new)
        (lhash-update (hash-db-index db) digest new))
    (free-record heap addr)
    new))

(defun %unlink-record (db digest addr prev)
  (let* ((heap (hash-db-heap db))
         (next (record-next heap addr)))
    (cond (prev (setf (record-next heap prev) next))
          ((zerop next) (lhash-remove (hash-db-index db) digest))
          (t (lhash-update (hash-db-index db) digest next)))
    (free-record heap addr)
    (with-lock-held ((hash-db-count-lock db))
      (decf (hash-db-record-count db)))))

;;; Operations

(defmethod db-set ((db hash-db) key value)
  (%writing (db)
    (let* ((k (to-octets key)) (v (to-octets value)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (%replace-record db d addr prev k v)
              (%insert-record db d k v))
          t)))))

(defmethod db-add ((db hash-db) key value)
  (%writing (db)
    (let* ((k (to-octets key)) (v (to-octets value)) (d (%digest k)))
      (with-key-locked (db d :write)
        (if (%find db d k)
            (%fail db :duplicate-record)
            (progn (%insert-record db d k v) t))))))

(defmethod db-replace ((db hash-db) key value)
  (%writing (db)
    (let* ((k (to-octets key)) (v (to-octets value)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (progn (%replace-record db d addr prev k v) t)
              (%fail db :no-record)))))))

(defmethod db-append ((db hash-db) key value)
  (%writing (db)
    (let* ((k (to-octets key)) (v (to-octets value)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (%replace-record db d addr prev k
                               (concatenate
                                'octets
                                (record-value (hash-db-heap db) addr) v))
              (%insert-record db d k v))
          t)))))

(defmethod db-get ((db hash-db) key &key (as :octets))
  (check-as as)
  (let* ((k (to-octets key)) (d (%digest k)))
    (with-key-locked (db d :read)
      (let ((addr (%find db d k)))
        (if addr
            (from-octets (record-value (hash-db-heap db) addr) as)
            (%fail db :no-record))))))

(defmethod db-check ((db hash-db) key)
  (let* ((k (to-octets key)) (d (%digest k)))
    (with-key-locked (db d :read)
      (let ((addr (%find db d k)))
        (if addr
            (record-value-length (hash-db-heap db) addr)
            (%fail db :no-record))))))

(defmethod db-seize ((db hash-db) key &key (as :octets))
  (check-as as)
  (%writing (db)
    (let* ((k (to-octets key)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (prog1 (from-octets (record-value (hash-db-heap db) addr) as)
                (%unlink-record db d addr prev))
              (%fail db :no-record)))))))

(defmethod db-remove ((db hash-db) key)
  (%writing (db)
    (let* ((k (to-octets key)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (progn (%unlink-record db d addr prev) t)
              (%fail db :no-record)))))))

(defmethod db-count ((db hash-db))
  (with-read-lock ((hash-db-lock db))
    (%check-open db)
    (with-lock-held ((hash-db-count-lock db))
      (hash-db-record-count db))))

;;; Whole-database operations

(defmethod db-path ((db hash-db))
  (namestring (hash-db-dir db)))

(defmethod db-size ((db hash-db))
  "Bytes in use: the heap's extent and the index's buckets and overflow.
File sizes would overstate: the index files are sparse."
  (with-read-lock ((hash-db-lock db))
    (%check-open db)
    (let ((index (hash-db-index db)))
      (+ (read-memory-pointer (hash-db-heap db))
         (* (bucket-count index) (%lhash-bucket-bytes index))
         (read-lhash-next-overflow-pointer index)))))

(defun %sync-storage (db)
  (let ((index (hash-db-index db)))
    (sync-region (memory-mmap (hash-db-heap db)))
    (dolist (mf (list (%lhash-config index) (%lhash-table index)
                      (%lhash-overflow index)))
      (sync-region mf))
    (%write-header db)))

(defmethod db-synchronize ((db hash-db) &key hard)
  (declare (ignore hard))
  (with-write-lock ((hash-db-lock db))
    (%check-open db)
    (when (hash-db-writable-p db)
      (%sync-storage db))
    t))

(defmethod db-clear ((db hash-db))
  (if (hash-db-writable-p db)
      (with-write-lock ((hash-db-lock db))
        (%check-open db)
        (close-lhash (hash-db-index db))
        (close-memory (hash-db-heap db))
        (%delete-storage (hash-db-dir db))
        (%create-storage db)
        t)
      (%fail db :no-permission)))
