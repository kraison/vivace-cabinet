;;;; TreeDB: an ordered database on the B+ tree (the default) or the skip
;;;; list (spec: TreeDB).  Per-key work holds the key's stripe under the
;;;; database lock, as in HashDB; the engine keeps the order.

(in-package #:vivace-cabinet)

(defclass tree-db (database)
  ((engine :initform nil :accessor tree-db-engine)))

(defun %engine-kind (code)
  (case code (1 :bplus-tree) (2 :skip-list)))

;;; Storage

(defmethod %type-code ((db tree-db)) 2)

(defmethod %engine-code ((db tree-db))
  (if (typep (tree-db-engine db) 'skip-list-engine) 2 1))

(defmethod %header-address ((db tree-db))
  (engine-address (tree-db-engine db)))

(defmethod %record-count ((db tree-db))
  (engine-count (tree-db-engine db)))

(defun %open-heap (db create)
  "Create or open DB's heap within its address-space reservation."
  (destructuring-bind (&key heap-size heap-reservation &allow-other-keys)
      (%db-tuning db)
    (let ((*mmap-min-reservation* heap-reservation)
          (file (namestring (%heap-file (%db-dir db)))))
      (setf (%db-heap db) (if create
                              (create-memory file heap-size)
                              (open-memory file))))))

(defmethod %create-storage ((db tree-db))
  (destructuring-bind (&key engine page-size comparator &allow-other-keys)
      (%db-tuning db)
    (let ((heap (%open-heap db t)))
      (setf (tree-db-engine db)
            (ecase (or engine :bplus-tree)
              (:bplus-tree (make-bplus-engine heap :less comparator
                                                   :page-size page-size))
              (:skip-list (make-skip-list-engine heap :less comparator)))))))

(defmethod %open-storage ((db tree-db) header)
  (destructuring-bind (&key engine comparator &allow-other-keys)
      (%db-tuning db)
    (let ((dir (%db-dir db))
          (kind (%engine-kind (getf header :engine)))
          (address (getf header :address)))
      (unless kind
        (%signal 'open-error "~a: unknown TreeDB engine ~a" dir
                 (getf header :engine)))
      (when (and engine (not (eq engine kind)))
        (%signal 'open-error "~a: a ~(~a~) TreeDB, not ~(~a~)"
                 dir kind engine))
      (let ((heap (%open-heap db nil)))
        (setf (tree-db-engine db)
              (ecase kind
                (:bplus-tree
                 (open-bplus-engine heap address :less comparator))
                (:skip-list
                 (open-skip-list-engine heap address :less comparator))))))))

(defmethod %close-storage ((db tree-db))
  (when (tree-db-engine db)
    (engine-close (tree-db-engine db))
    (setf (tree-db-engine db) nil))
  (when (%db-heap db)
    (close-memory (%db-heap db))
    (setf (%db-heap db) nil)))

(defmethod %sync-storage ((db tree-db))
  (sync-region (memory-mmap (%db-heap db))))

(defun open-tree-db (dir &key (mode '(:writer :create)) engine
                           (page-size 4096) (comparator 'octets<)
                           (heap-size (* 64 1024 1024))
                           (heap-reservation (* 64 1024 1024 1024)))
  "Open the TreeDB in DIR.  ENGINE is :BPLUS-TREE (the default when
creating) or :SKIP-LIST; PAGE-SIZE (1024 to 32768) applies to a new B+
tree.  COMPARATOR, a strict less-than on octet vectors, is not stored:
pass the same one at every open.  MODE and the heap keywords are as for
OPEN-HASH-DB."
  (%check-mode mode)
  (unless (member engine '(nil :bplus-tree :skip-list))
    (%signal 'invalid-argument "unknown TreeDB engine ~s" engine))
  (unless (and (integerp page-size) (<= 1024 page-size 32768))
    (%signal 'invalid-argument "PAGE-SIZE must be 1024 to 32768: ~s"
             page-size))
  (%open-database
   (make-instance 'tree-db :dir dir
                           :writable (and (member :writer mode) t)
                           :autosync (and (member :autosync mode) t)
                           :tuning (list :engine engine
                                         :page-size page-size
                                         :comparator comparator
                                         :heap-size heap-size
                                         :heap-reservation heap-reservation))
   mode))

;;; Operations

(defmacro %with-tree-key ((db k key mode) &body body)
  "Bind K to KEY as octets and run BODY holding K's stripe for MODE."
  `(let ((,k (to-octets ,key)))
     (with-key-locked (,db (murmur3-128 ,k) ,mode)
       ,@body)))

(defmethod db-set ((db tree-db) key value)
  (%writing (db)
    (let ((v (to-octets value)))
      (%with-tree-key (db k key :write)
        (engine-put (tree-db-engine db) k v)))))

(defmethod db-add ((db tree-db) key value)
  (%writing (db)
    (let ((v (to-octets value)))
      (%with-tree-key (db k key :write)
        (let ((e (tree-db-engine db)))
          (if (engine-get e k)
              (%fail db :duplicate-record)
              (engine-put e k v)))))))

(defmethod db-replace ((db tree-db) key value)
  (%writing (db)
    (let ((v (to-octets value)))
      (%with-tree-key (db k key :write)
        (let ((e (tree-db-engine db)))
          (if (engine-get e k)
              (engine-put e k v)
              (%fail db :no-record)))))))

(defmethod db-append ((db tree-db) key value)
  (%writing (db)
    (let ((v (to-octets value)))
      (%with-tree-key (db k key :write)
        (let* ((e (tree-db-engine db))
               (old (engine-get e k)))
          (engine-put e k (if old (concatenate 'octets old v) v)))))))

(defmethod db-get ((db tree-db) key &key (as :octets))
  (check-as as)
  (%with-tree-key (db k key :read)
    (let ((v (engine-get (tree-db-engine db) k)))
      (if v
          (from-octets v as)
          (%fail db :no-record)))))

(defmethod db-check ((db tree-db) key)
  (%with-tree-key (db k key :read)
    (let ((v (engine-get (tree-db-engine db) k)))
      (if v
          (length v)
          (%fail db :no-record)))))

(defmethod db-seize ((db tree-db) key &key (as :octets))
  (check-as as)
  (%writing (db)
    (%with-tree-key (db k key :write)
      (let* ((e (tree-db-engine db))
             (v (engine-get e k)))
        (if v
            (progn (engine-delete e k)
                   (from-octets v as))
            (%fail db :no-record))))))

(defmethod db-remove ((db tree-db) key)
  (%writing (db)
    (%with-tree-key (db k key :write)
      (or (engine-delete (tree-db-engine db) k)
          (%fail db :no-record)))))

(defmethod %size ((db tree-db))
  "Bytes the heap has used."
  (read-memory-pointer (%db-heap db)))

;;; Visiting

(defmethod %key-digest ((db tree-db) key)
  (murmur3-128 key))

(defmethod %visit ((db tree-db) k d visitor as writable)
  (declare (ignore d))
  (let* ((e (tree-db-engine db))
         (old (engine-get e k))
         (answer (funcall visitor (from-octets k as)
                          (and old (from-octets old as)))))
    (when writable
      (case answer
        ((nil :nop))
        (:remove (when old
                   (engine-delete e k)))
        (t (engine-put e k (to-octets answer)))))
    answer))
