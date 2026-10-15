;;;; Copied from vivace-graph primitive-node.lisp at 853df62 (--only 606).
;;;; See docs/provenance.md.

(in-package #:vivace-cabinet)

(defgeneric %hash (key)
  (:documentation "The linear hash's bucket hash of KEY, a 16-byte octet
vector.  Part of the on-disk format: do not change."))

(defmethod %hash ((key #.(class-of (make-array 16 :element-type '(unsigned-byte 8)))))
  (declare (optimize (speed 3) (safety 0)))
  (let ((int (aref key 0)))
    (loop
       for subscript from 1 to 15
       for shift from 8 by 8
       do
         (incf int (ash (logand (aref key subscript) #xFF) shift)))
    int))
