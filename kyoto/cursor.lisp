;;;; Kyoto cursors as vivace-cabinet cursors.  Kyoto's must be deleted:
;;;; WITH-CURSOR releases them, and CLOSE-DB deletes any still live.

(in-package #:vivace-cabinet-kyoto)

(defclass kyoto-cursor ()
  ((ptr :initarg :ptr :accessor %kc-ptr)
   (db :initarg :db :reader %kc-db)))

(defmethod db-cursor ((db kyoto-db))
  (let ((c (make-instance 'kyoto-cursor
                          :ptr (kyoto-cabinet-ffi:kcdbcursor (%ptr db))
                          :db db)))
    (bt:with-lock-held ((%kdb-lock db))
      (push c (%kdb-cursors db)))
    c))

(defmethod %release-cursor ((c kyoto-cursor))
  (let ((db (%kc-db c)))
    (bt:with-lock-held ((%kdb-lock db))
      (when (%kc-ptr c)
        (kyoto-cabinet-ffi:kccurdel (%kc-ptr c))
        (setf (%kc-ptr c) nil)
        (setf (%kdb-cursors db) (delete c (%kdb-cursors db)))))))

(defmethod %cursor-db ((c kyoto-cursor))
  (%kc-db c))

(defun %cur (c)
  (or (%kc-ptr c)
      (%signal 'invalid-argument "the Kyoto cursor is released")))

(defun %backward (c ok)
  "OK, but a backward move that Kyoto refuses as not implemented (on a
HashDB) signals NOT-IMPLEMENTED, as vivace-cabinet's do."
  (or ok
      (if (= 1 (%kccurecode (%cur c)))
          (%signal 'not-implemented "a HashDB cursor moves forward only")
          nil)))

(defmethod cursor-jump ((c kyoto-cursor) &optional key)
  (if key
      (%with-key (k kp) key
        (%kccurjumpkey (%cur c) kp (length k)))
      (kyoto-cabinet-ffi:kccurjump (%cur c))))

(defmethod cursor-jump-back ((c kyoto-cursor) &optional key)
  (%backward c (if key
                   (%with-key (k kp) key
                     (%kccurjumpbackkey (%cur c) kp (length k)))
                   (%kccurjumpback (%cur c)))))

(defmethod cursor-step ((c kyoto-cursor))
  (kyoto-cabinet-ffi:kccurstep (%cur c)))

(defmethod cursor-step-back ((c kyoto-cursor))
  (%backward c (%kccurstepback (%cur c))))

(defun %record (fn as)
  "Call FN with pointers for the key size, value pointer and value size;
it returns the key region, which holds the value too.  (values key
value) AS, or NIL."
  (cffi:with-foreign-objects ((ksp :size) (vbp :pointer) (vsp :size))
    (let ((kp (funcall fn ksp vbp vsp)))
      (unless (cffi:null-pointer-p kp)
        (unwind-protect
             (values (from-octets (%copy-in kp (cffi:mem-ref ksp :size)) as)
                     (from-octets (%copy-in (cffi:mem-ref vbp :pointer)
                                            (cffi:mem-ref vsp :size))
                                  as))
          (kyoto-cabinet-ffi:kcfree kp))))))

(defmethod cursor-get ((c kyoto-cursor) &key (as :octets) step)
  (check-as as)
  (%record (lambda (ksp vbp vsp)
             (kyoto-cabinet-ffi:kccurget (%cur c) ksp vbp vsp step))
           as))

(defmethod cursor-seize ((c kyoto-cursor) &key (as :octets))
  (check-as as)
  (%record (lambda (ksp vbp vsp)
             (%kccurseize (%cur c) ksp vbp vsp))
           as))

(defmethod cursor-set-value ((c kyoto-cursor) value)
  (let ((v (to-octets value)))
    (with-octets (vp v)
      (%kccursetvalue (%cur c) vp (length v) 0))))

(defmethod cursor-remove ((c kyoto-cursor))
  (kyoto-cabinet-ffi:kccurremove (%cur c)))
