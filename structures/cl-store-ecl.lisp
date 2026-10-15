;;;; Copied from vivace-graph cl-store-ecl.lisp at 853df62 (--except -).
;;;; See docs/provenance.md.

(in-package #:vivace-cabinet)
#+ecl
(in-package :cl-store)

#+ecl
(eval-when (:compile-toplevel :load-toplevel :execute)

  ;; Enumerate a structure's slots the same way the supported impls do.
  (defmethod serializable-slots-using-class ((object t) (class structure-class))
    (class-slots class))

  ;; cl-store's SERIALIZABLE-SLOTS has no applicable method for a structure
  ;; object on ECL; route it through SERIALIZABLE-SLOTS-USING-CLASS as on the
  ;; other implementations.
  (defmethod serializable-slots ((object structure-object))
    (serializable-slots-using-class object (class-of object)))

  ;; Store structs under the STANDARD-OBJECT type code; RESTORE-TYPE-OBJECT
  ;; handles the read side for both.
  (defstore-cl-store (obj structure-object stream)
    (output-type-code +standard-object-code+ stream)
    (store-type-object obj stream)))
