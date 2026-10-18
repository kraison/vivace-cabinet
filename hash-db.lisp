;;;; HashDB: records in a heap, indexed by the linear hash from a key's
;;;; 16-byte digest to the first record of that digest's chain (spec:
;;;; HashDB).  DATABASE supplies the directory, header, modes and locks.

(in-package #:vivace-cabinet)

(defun murmur3-digest (key)
  (murmur3-128 key 0))

(defvar *key-digest* 'murmur3-digest
  "Function from key octets to a 16-byte digest.  Tests bind it to force
collisions; a database must keep one digest function for life.")

(defclass hash-db (database)
  ((index :initform nil :accessor hash-db-index)
   (record-count :initform 0 :accessor hash-db-record-count)
   (count-lock :initform (make-lock "hash-db count")
               :reader hash-db-count-lock)))

;;; Storage

(defmethod %type-code ((db hash-db)) 1)

(defmethod %record-count ((db hash-db))
  (with-lock-held ((hash-db-count-lock db))
    (hash-db-record-count db)))

(defun %count-records (db)
  "DB's records, counted by walking every chain in the index."
  (let ((heap (%db-heap db))
        (n 0))
    (map-lhash (lambda (entry)
                 (loop for addr = (cdr entry) then (record-next heap addr)
                       until (zerop addr)
                       do (incf n)))
               (hash-db-index db))
    n))

(defmethod %create-storage ((db hash-db))
  (destructuring-bind (&key buckets max-locks heap-size heap-reservation)
      (%db-tuning db)
    (let ((dir (%db-dir db)))
      (ensure-directories-exist (%index-dir dir))
      (setf (%db-heap db) (let ((*mmap-min-reservation* heap-reservation))
                            (create-memory (namestring (%heap-file dir))
                                           heap-size))
            (hash-db-index db) (make-lhash :location (%index-dir dir)
                                           :buckets buckets
                                           :max-locks max-locks)
            (hash-db-record-count db) 0))))

(defmethod %open-storage ((db hash-db) header)
  "Open the heap and the index, recounting the records if a writer left
them open."
  (destructuring-bind (&key heap-reservation &allow-other-keys)
      (%db-tuning db)
    (let ((dir (%db-dir db)))
      (setf (%db-heap db) (let ((*mmap-min-reservation* heap-reservation))
                            (open-memory (namestring (%heap-file dir))))
            (hash-db-index db) (open-lhash (%index-dir dir))
            (hash-db-record-count db) (if (getf header :open)
                                          (%count-records db)
                                          (getf header :count))))))

(defmethod %close-storage ((db hash-db))
  (when (hash-db-index db)
    (close-lhash (hash-db-index db))
    (setf (hash-db-index db) nil))
  (when (%db-heap db)
    (close-memory (%db-heap db))
    (setf (%db-heap db) nil)))

(defmethod %sync-storage ((db hash-db))
  (let ((index (hash-db-index db)))
    (sync-region (memory-mmap (%db-heap db)))
    (dolist (mf (list (%lhash-config index) (%lhash-table index)
                      (%lhash-overflow index)))
      (sync-region mf))))

(defun open-hash-db (dir &key (mode '(:writer :create)) (buckets 4)
                           (max-locks *max-locks*)
                           (heap-size (* 64 1024 1024))
                           (heap-reservation (* 64 1024 1024 1024)))
  "Open the HashDB in DIR.  MODE holds :READER or :WRITER, and any of
:CREATE, :TRUNCATE, :AUTOSYNC.  BUCKETS and MAX-LOCKS tune the linear
hash; HEAP-SIZE is the heap's first size; HEAP-RESERVATION is the address
space the heap may grow into before it must be reopened."
  (%check-mode mode)
  (%open-database
   (make-instance 'hash-db :dir dir
                           :writable (and (member :writer mode) t)
                           :autosync (and (member :autosync mode) t)
                           :tuning (list :buckets buckets
                                         :max-locks max-locks
                                         :heap-size heap-size
                                         :heap-reservation heap-reservation))
   mode))

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

(defun %find (db digest key)
  "The address of KEY's record and of the record before it in DIGEST's
chain (NIL at the head); NIL if KEY is absent."
  (let ((heap (%db-heap db)))
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
         (addr (write-record (%db-heap db) key value (or head 0))))
    (if head
        (lhash-update index digest addr)
        (lhash-insert index digest addr))
    (with-lock-held ((hash-db-count-lock db))
      (incf (hash-db-record-count db)))
    addr))

(defun %replace-record (db digest addr prev key value)
  (let* ((heap (%db-heap db))
         (new (write-record heap key value (record-next heap addr))))
    (if prev
        (setf (record-next heap prev) new)
        (lhash-update (hash-db-index db) digest new))
    (free-record heap addr)
    new))

(defun %unlink-record (db digest addr prev)
  (let* ((heap (%db-heap db))
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
                                (record-value (%db-heap db) addr) v))
              (%insert-record db d k v))
          t)))))

(defmethod db-get ((db hash-db) key &key (as :octets))
  (check-as as)
  (let* ((k (to-octets key)) (d (%digest k)))
    (with-key-locked (db d :read)
      (let ((addr (%find db d k)))
        (if addr
            (from-octets (record-value (%db-heap db) addr) as)
            (%fail db :no-record))))))

(defmethod db-check ((db hash-db) key)
  (let* ((k (to-octets key)) (d (%digest k)))
    (with-key-locked (db d :read)
      (let ((addr (%find db d k)))
        (if addr
            (record-value-length (%db-heap db) addr)
            (%fail db :no-record))))))

(defmethod db-seize ((db hash-db) key &key (as :octets))
  (check-as as)
  (%writing (db)
    (let* ((k (to-octets key)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (prog1 (from-octets (record-value (%db-heap db) addr) as)
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

(defmethod %size ((db hash-db))
  "Bytes in use: the heap's extent and the index's buckets and overflow.
File sizes would overstate: the index files are sparse."
  (let ((index (hash-db-index db)))
    (+ (read-memory-pointer (%db-heap db))
       (* (bucket-count index) (%lhash-bucket-bytes index))
       (read-lhash-next-overflow-pointer index))))

;;; Visiting

(defmethod %key-digest ((db hash-db) key)
  (%digest key))

(defmethod %visit ((db hash-db) k d visitor as writable)
  (multiple-value-bind (addr prev) (%find db d k)
    (let ((answer (funcall visitor (from-octets k as)
                           (and addr (from-octets (record-value (%db-heap db)
                                                                addr)
                                                  as)))))
      (when writable
        (case answer
          ((nil :nop))
          (:remove (when addr
                     (%unlink-record db d addr prev)))
          (t (let ((v (to-octets answer)))
               (if addr
                   (%replace-record db d addr prev k v)
                   (%insert-record db d k v))))))
      answer)))
