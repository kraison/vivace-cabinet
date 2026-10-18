;;;; Kyoto's C API (kclangc.h).  cl-kyoto-cabinet loads the library and
;;;; its exported bindings are used where they take keys as pointer and
;;;; size; the calls below are those it binds with string keys (which
;;;; cannot carry every byte), leaves unexported, or does not bind.  The
;;;; match calls take and return C strings: keys holding a zero byte do
;;;; not pass.

(in-package #:vivace-cabinet-kyoto)

(cffi:defcstruct kcstr
  (buf :pointer)
  (size :size))

(cffi:defcstruct kcrec
  (key (:struct kcstr))
  (value (:struct kcstr)))

(cffi:defcfun ("kcdbget" %kcdbget) :pointer
  (db :pointer) (kbuf :pointer) (ksiz :size) (sp :pointer))

(cffi:defcfun ("kcdbseize" %kcdbseize) :pointer
  (db :pointer) (kbuf :pointer) (ksiz :size) (sp :pointer))

(cffi:defcfun ("kcdbcheck" %kcdbcheck) :int32
  (db :pointer) (kbuf :pointer) (ksiz :size))

(cffi:defcfun ("kcdbremove" %kcdbremove) :boolean
  (db :pointer) (kbuf :pointer) (ksiz :size))

(cffi:defcfun ("kcdbreplace" %kcdbreplace) :boolean
  (db :pointer) (kbuf :pointer) (ksiz :size) (vbuf :pointer) (vsiz :size))

(cffi:defcfun ("kcdbincrint" %kcdbincrint) :int64
  (db :pointer) (kbuf :pointer) (ksiz :size) (num :int64) (orig :int64))

(cffi:defcfun ("kcdbincrdouble" %kcdbincrdouble) :double
  (db :pointer) (kbuf :pointer) (ksiz :size) (num :double) (orig :double))

(cffi:defcfun ("kcdbcas" %kcdbcas) :boolean
  (db :pointer) (kbuf :pointer) (ksiz :size)
  (ovbuf :pointer) (ovsiz :size) (nvbuf :pointer) (nvsiz :size))

(cffi:defcfun ("kcdbsize" %kcdbsize) :int64
  (db :pointer))

(cffi:defcfun ("kcdbsetbulk" %kcdbsetbulk) :int64
  (db :pointer) (recs :pointer) (rnum :size) (atomic :int32))

(cffi:defcfun ("kcdbremovebulk" %kcdbremovebulk) :int64
  (db :pointer) (keys :pointer) (knum :size) (atomic :int32))

(cffi:defcfun ("kcdbgetbulk" %kcdbgetbulk) :int64
  (db :pointer) (keys :pointer) (knum :size) (recs :pointer)
  (atomic :int32))

(cffi:defcfun ("kcdbmatchprefix" %kcdbmatchprefix) :int64
  (db :pointer) (prefix :pointer) (strary :pointer) (max :size))

(cffi:defcfun ("kcdbmatchregex" %kcdbmatchregex) :int64
  (db :pointer) (regex :pointer) (strary :pointer) (max :size))

(cffi:defcfun ("kcdbmatchsimilar" %kcdbmatchsimilar) :int64
  (db :pointer) (origin :pointer) (range :uint32) (utf :int32)
  (strary :pointer) (max :size))

(cffi:defcfun ("kccurjumpkey" %kccurjumpkey) :boolean
  (cur :pointer) (kbuf :pointer) (ksiz :size))

(cffi:defcfun ("kccurjumpback" %kccurjumpback) :boolean
  (cur :pointer))

(cffi:defcfun ("kccurjumpbackkey" %kccurjumpbackkey) :boolean
  (cur :pointer) (kbuf :pointer) (ksiz :size))

(cffi:defcfun ("kccurstepback" %kccurstepback) :boolean
  (cur :pointer))

(cffi:defcfun ("kccursetvalue" %kccursetvalue) :boolean
  (cur :pointer) (vbuf :pointer) (vsiz :size) (step :int32))

(cffi:defcfun ("kccurseize" %kccurseize) :pointer
  (cur :pointer) (ksp :pointer) (vbp :pointer) (vsp :pointer))

(cffi:defcfun ("kccurecode" %kccurecode) :int32
  (cur :pointer))

;;; Moving bytes across

(defmacro with-octets ((ptr v) &body body)
  "Run BODY with PTR pointing at the bytes of the octets V, pinned."
  `(cffi:with-pointer-to-vector-data (,ptr ,v)
     ,@body))

(defun %copy-in (ptr size)
  "SIZE bytes at PTR as new octets."
  (let ((v (make-array size :element-type '(unsigned-byte 8))))
    (with-octets (p v)
      (cffi:foreign-funcall "memcpy" :pointer p :pointer ptr :size size
                                     :pointer))
    v))

(defun %take (ptr size)
  "SIZE bytes at PTR as octets, PTR then freed; NIL for a null PTR."
  (unless (cffi:null-pointer-p ptr)
    (prog1 (%copy-in ptr size)
      (kyoto-cabinet-ffi:kcfree ptr))))

(defmacro with-c-string ((ptr v) &body body)
  "Run BODY with PTR pointing at a zero-terminated copy of the octets V."
  (let ((n (gensym "N"))
        (src (gensym "SRC")))
    `(let ((,n (length ,v)))
       (cffi:with-foreign-pointer (,ptr (1+ ,n))
         (with-octets (,src ,v)
           (cffi:foreign-funcall "memcpy" :pointer ,ptr :pointer ,src
                                          :size ,n :pointer))
         (setf (cffi:mem-aref ,ptr :uint8 ,n) 0)
         ,@body))))

(defun %c-string-octets (ptr)
  "The zero-terminated bytes at PTR as octets."
  (%copy-in ptr (cffi:foreign-funcall "strlen" :pointer ptr :size)))
