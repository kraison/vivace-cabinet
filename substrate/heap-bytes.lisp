;;;; Copied from vivace-graph transactions.lisp at 853df62 (--only 606).
;;;; See docs/provenance.md.

(in-package #:vivace-cabinet)
;;; FIXME: Find a better home for this method
(defmethod set-bytes ((memory memory) vec offset length)
  (declare (type word offset length))
  (dotimes (i length)
    (set-byte memory (+ i offset) (aref vec i)))
  vec)
