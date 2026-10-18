;;;; A Kyoto Cabinet database as a vivace-cabinet database: the generic
;;;; functions over Kyoto's C API, for the operations the conformance
;;;; check and the benchmark use.

(in-package #:vivace-cabinet-kyoto)

(defclass kyoto-db ()
  ((ptr :initarg :ptr :accessor %kdb-ptr)
   (path :initarg :path :reader %kdb-path)
   (cursors :initform '() :accessor %kdb-cursors)
   (lock :initform (bt:make-lock "kyoto cursors") :reader %kdb-lock)))

(defparameter *mode-flags*
  '((:reader . :read) (:writer . :write) (:create . :create)
    (:truncate . :truncate) (:autosync . :autosync))
  "vivace-cabinet's open modes and Kyoto's.")

(defun open-kyoto-db (path &key (mode '(:writer :create)) tuning)
  "Open the Kyoto Cabinet database in the file PATH, whose extension
picks its type (.kch HashDB, .kct TreeDB).  TUNING is a plist of Kyoto's
tuning parameters, e.g. (:bnum 2000000).  Returns a KYOTO-DB."
  (let* ((flags (mapcar (lambda (m)
                          (or (cdr (assoc m *mode-flags*))
                              (%signal 'invalid-argument
                                       "unknown mode ~s" m)))
                        mode))
         (name (format nil "~a~{#~(~a~)=~a~}"
                       (uiop:native-namestring (merge-pathnames path))
                       tuning))
         (ptr (kyoto-cabinet-ffi:kcdbnew)))
    (unless (kyoto-cabinet-ffi:kcdbopen ptr name flags)
      (let ((code (kyoto-cabinet-ffi:kcdbecode ptr)))
        (kyoto-cabinet-ffi:kcdbdel ptr)
        (%signal 'open-error "~a: Kyoto error ~a" name code)))
    (make-instance 'kyoto-db :ptr ptr :path (merge-pathnames path))))

(defun %ptr (db)
  (or (%kdb-ptr db)
      (%signal 'invalid-argument "the Kyoto database is closed")))

(defun kyoto-error-code (code)
  "Kyoto's error CODE as vivace-cabinet's DB-ERROR reason."
  (case code
    (0 :success) (1 :not-implemented) (2 :invalid) (3 :no-repository)
    (4 :no-permission) (5 :broken) (6 :duplicate-record) (7 :no-record)
    (8 :logic) (9 :system) (t :misc)))

(defmethod db-error ((db kyoto-db))
  (kyoto-error-code (kyoto-cabinet-ffi:kcdbecode (%ptr db))))

(defmethod close-db ((db kyoto-db))
  (let ((ptr (%kdb-ptr db)))
    (when ptr
      (mapc #'%release-cursor (copy-list (%kdb-cursors db)))
      (setf (%kdb-ptr db) nil)
      (prog1 (kyoto-cabinet-ffi:kcdbclose ptr)
        (kyoto-cabinet-ffi:kcdbdel ptr)))))

(defmethod db-path ((db kyoto-db))
  (namestring (%kdb-path db)))

(defmethod db-count ((db kyoto-db))
  (kyoto-cabinet-ffi:kcdbcount (%ptr db)))

(defmethod db-size ((db kyoto-db))
  (%kcdbsize (%ptr db)))

(defmethod db-clear ((db kyoto-db))
  (kyoto-cabinet-ffi:kcdbclear (%ptr db)))

;;; One record

(defmacro %with-kv ((k kp v vp) (key value) &body body)
  "Run BODY with K and V the octets of KEY and VALUE, KP and VP pointing
at their bytes."
  `(let ((,k (to-octets ,key))
         (,v (to-octets ,value)))
     (with-octets (,kp ,k)
       (with-octets (,vp ,v)
         ,@body))))

(defmethod db-set ((db kyoto-db) key value)
  (%with-kv (k kp v vp) (key value)
    (kyoto-cabinet-ffi:kcdbset (%ptr db) kp (length k) vp (length v))))

(defmethod db-add ((db kyoto-db) key value)
  (%with-kv (k kp v vp) (key value)
    (kyoto-cabinet-ffi:kcdbadd (%ptr db) kp (length k) vp (length v))))

(defmethod db-replace ((db kyoto-db) key value)
  (%with-kv (k kp v vp) (key value)
    (%kcdbreplace (%ptr db) kp (length k) vp (length v))))

(defmethod db-append ((db kyoto-db) key value)
  (%with-kv (k kp v vp) (key value)
    (kyoto-cabinet-ffi:kcdbappend (%ptr db) kp (length k) vp (length v))))

(defmacro %with-key ((k kp) key &body body)
  `(let ((,k (to-octets ,key)))
     (with-octets (,kp ,k)
       ,@body)))

(defun %fetch (fn db key as)
  "Call the Kyoto function FN on KEY, which returns a value and its size;
the value AS, or NIL."
  (check-as as)
  (%with-key (k kp) key
    (cffi:with-foreign-object (sp :size)
      (let ((v (%take (funcall fn (%ptr db) kp (length k) sp)
                      (cffi:mem-ref sp :size))))
        (and v (from-octets v as))))))

(defmethod db-get ((db kyoto-db) key &key (as :octets))
  (%fetch #'%kcdbget db key as))

(defmethod db-seize ((db kyoto-db) key &key (as :octets))
  (%fetch #'%kcdbseize db key as))

(defmethod db-check ((db kyoto-db) key)
  (%with-key (k kp) key
    (let ((n (%kcdbcheck (%ptr db) kp (length k))))
      (and (>= n 0) n))))

(defmethod db-remove ((db kyoto-db) key)
  (%with-key (k kp) key
    (%kcdbremove (%ptr db) kp (length k))))

;;; Numbers and compare-and-swap

(defmethod db-increment ((db kyoto-db) key num &key (orig 0))
  (%with-key (k kp) key
    (let ((n (%kcdbincrint (%ptr db) kp (length k) num orig)))
      ;; Kyoto's failure value: a sum that is exactly it reads as failure.
      (and (/= n (- (expt 2 63))) n))))

(defmethod db-increment-double ((db kyoto-db) key num &key (orig 0d0))
  (%with-key (k kp) key
    (let ((n (%kcdbincrdouble (%ptr db) kp (length k)
                              (float num 1d0) (float orig 1d0))))
      (and (not (sb-ext:float-nan-p n)) n))))

(defmethod db-cas ((db kyoto-db) key old new)
  (let ((o (and old (to-octets old)))
        (n (and new (to-octets new)))
        (none (make-array 0 :element-type '(unsigned-byte 8))))
    (%with-key (k kp) key
      (with-octets (op (or o none))
        (with-octets (np (or n none))
          (%kcdbcas (%ptr db) kp (length k)
                    (if o op (cffi:null-pointer)) (length (or o none))
                    (if n np (cffi:null-pointer)) (length (or n none))))))))

;;; Bulk: Kyoto takes arrays of KCSTR and KCREC

(defun %fill-kcstr (str octets)
  "Point the KCSTR at STR to a foreign copy of OCTETS."
  (let ((buf (cffi:foreign-alloc :uint8 :count (max 1 (length octets)))))
    (with-octets (p octets)
      (cffi:foreign-funcall "memcpy" :pointer buf :pointer p
                                     :size (length octets) :pointer))
    (setf (cffi:foreign-slot-value str '(:struct kcstr) 'buf) buf
          (cffi:foreign-slot-value str '(:struct kcstr) 'size)
          (length octets))))

(defun %free-kcstr (str)
  (cffi:foreign-free (cffi:foreign-slot-value str '(:struct kcstr) 'buf)))

(defmacro %with-kcstrs ((ptr list) &body body)
  "Run BODY with PTR an array of KCSTR holding copies of LIST's octets."
  (let ((n (gensym "N")) (i (gensym "I")) (x (gensym "X")))
    `(let ((,n (length ,list)))
       (cffi:with-foreign-object (,ptr '(:struct kcstr) (max 1 ,n))
         (loop for ,x in ,list for ,i from 0
               do (%fill-kcstr (cffi:mem-aptr ,ptr '(:struct kcstr) ,i) ,x))
         (unwind-protect (progn ,@body)
           (dotimes (,i ,n)
             (%free-kcstr (cffi:mem-aptr ,ptr '(:struct kcstr) ,i))))))))

(defun %bulk-count (n)
  (and (>= n 0) n))

(defmethod db-set-bulk ((db kyoto-db) records &key (atomic t))
  (let ((n (length records)))
    (cffi:with-foreign-object (recs '(:struct kcrec) (max 1 n))
      (flet ((field (i name)
               (cffi:foreign-slot-pointer
                (cffi:mem-aptr recs '(:struct kcrec) i) '(:struct kcrec)
                name)))
        (loop for (key . value) in records for i from 0
              do (%fill-kcstr (field i 'key) (to-octets key))
                 (%fill-kcstr (field i 'value) (to-octets value)))
        (unwind-protect
             (%bulk-count (%kcdbsetbulk (%ptr db) recs n (if atomic 1 0)))
          (dotimes (i n)
            (%free-kcstr (field i 'key))
            (%free-kcstr (field i 'value))))))))

(defmethod db-remove-bulk ((db kyoto-db) keys &key (atomic t))
  (let ((ks (mapcar #'to-octets keys)))
    (%with-kcstrs (arr ks)
      (%bulk-count (%kcdbremovebulk (%ptr db) arr (length ks)
                                    (if atomic 1 0))))))

(defmethod db-get-bulk ((db kyoto-db) keys &key (atomic t) (as :octets))
  (check-as as)
  (let ((ks (mapcar #'to-octets keys)))
    (%with-kcstrs (arr ks)
      (cffi:with-foreign-object (recs '(:struct kcrec) (max 1 (length ks)))
        (let ((n (%kcdbgetbulk (%ptr db) arr (length ks) recs
                               (if atomic 1 0))))
          (and (>= n 0)
               (loop for i below n
                     collect (flet ((take (name)
                                      (let ((s (cffi:foreign-slot-pointer
                                                (cffi:mem-aptr
                                                 recs '(:struct kcrec) i)
                                                '(:struct kcrec) name)))
                                        (from-octets
                                         (%take (cffi:foreign-slot-value
                                                 s '(:struct kcstr) 'buf)
                                                (cffi:foreign-slot-value
                                                 s '(:struct kcstr) 'size))
                                         as))))
                               (cons (take 'key) (take 'value))))))))))

;;; Matching: Kyoto returns keys as C strings in an array of MAX slots

(defun %matches (db max as fn)
  "Call FN with an array of MAX (or every record's) slots and that size;
the keys it fills, AS."
  (check-as as)
  (let ((slots (or max (db-count db))))
    (cffi:with-foreign-object (strary :pointer (max 1 slots))
      (let ((n (funcall fn strary slots)))
        (and (>= n 0)
             (loop for i below n
                   collect (let ((p (cffi:mem-aref strary :pointer i)))
                             (prog1 (from-octets (%c-string-octets p) as)
                               (kyoto-cabinet-ffi:kcfree p)))))))))

(defmethod db-match-prefix ((db kyoto-db) prefix &key max (as :octets))
  (with-c-string (p (to-octets prefix))
    (%matches db max as (lambda (arr slots)
                          (%kcdbmatchprefix (%ptr db) p arr slots)))))

(defmethod db-match-regex ((db kyoto-db) regex &key max (as :octets))
  (with-c-string (p (to-octets regex))
    (%matches db max as (lambda (arr slots)
                          (%kcdbmatchregex (%ptr db) p arr slots)))))

(defmethod db-match-similar ((db kyoto-db) origin range
                             &key utf max (as :octets))
  (with-c-string (p (to-octets origin))
    (%matches db max as (lambda (arr slots)
                          (%kcdbmatchsimilar (%ptr db) p range
                                             (if utf 1 0) arr slots)))))
