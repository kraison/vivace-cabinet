;;;; The ordered store under TreeDB, one per engine (spec: TreeDB).  Keys
;;;; and values are octets.  ENGINE-CEILING and ENGINE-FLOOR give TreeDB
;;;; its order; with KEY NIL they find the first and the last record.

(in-package #:vivace-cabinet)

(defun octets< (a b)
  "Unsigned lexicographic order on octet vectors; a prefix sorts first.
TreeDB's default comparator."
  (let ((m (mismatch a b)))
    (cond ((null m) nil)
          ((= m (length a)) t)
          ((= m (length b)) nil)
          (t (< (aref a m) (aref b m))))))

(defun %equal-under (less)
  "The key equality the strict order LESS implies."
  (lambda (a b)
    (not (or (funcall less a b) (funcall less b a)))))

(defgeneric engine-get (engine key)
  (:documentation "KEY's value, or NIL."))

(defgeneric engine-put (engine key value)
  (:documentation "Store VALUE under KEY, replacing any value; T."))

(defgeneric engine-delete (engine key)
  (:documentation "Remove KEY; true if it was there."))

(defgeneric engine-count (engine))

(defgeneric engine-ceiling (engine key strict)
  (:documentation "The first record at or after KEY (after it when
STRICT) as (values key value), or NIL; the first record when KEY is NIL."))

(defgeneric engine-floor (engine key strict)
  (:documentation "The last record at or before KEY (before it when
STRICT) as (values key value), or NIL; the last record when KEY is NIL."))

(defgeneric engine-address (engine)
  (:documentation "Where the engine's header lies in the heap."))

(defgeneric engine-close (engine))
