;;;; Copied from vivace-graph utilities.lisp at 853df62 (--only 250,255,258,533,538,543,547,551,560).
;;;; See docs/provenance.md.

(in-package #:vivace-cabinet)
(defun proper-listp (x)
  "Is x a proper (non-dotted) list?"
  (or (null x)
      (and (consp x) (proper-listp (rest x)))))

(defun make-byte-vector (length)
  (make-array `(,length) :element-type '(unsigned-byte 8) :initial-element 0))

(defmacro with-gensyms (syms &body body)
  `(let ,(loop for s in syms collect `(,s (gensym)))
    ,@body))

#+ccl
(defmacro with-read-lock ((lock) &body body)
  `(ccl:with-read-lock (,lock)
     (progn ,@body)))

#+ccl
(defmacro with-write-lock ((lock) &body body)
  `(ccl:with-write-lock (,lock)
     (progn ,@body)))

#+ccl
(defun make-rw-lock ()
  (ccl:make-read-write-lock))

#+ccl
(defun rw-lock-p (thing)
  (ccl::read-write-lock-p thing))

#+ccl
(defun acquire-write-lock (lock &key wait-p)
  (declare (ignore wait-p))
  (let ((locked (ccl:make-lock-acquisition)))
    (declare (dynamic-extent locked))
    (ccl::write-lock-rwlock lock locked)
    (when (ccl::lock-acquisition.status locked)
      lock)))

#+ccl
(defun release-write-lock (lock)
  (declare (ignore wait-p))
  (ccl::unlock-rwlock lock))
