(defpackage #:vivace-cabinet-test
  (:use #:cl #:fiveam))

(in-package #:vivace-cabinet-test)

;; The copied tests name library internals unqualified, as vivace-graph's
;; test package imported them: import every VIVACE-CABINET symbol that
;; does not clash with CL or FiveAM.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((test (find-package '#:vivace-cabinet-test))
        (lib (find-package '#:vivace-cabinet)))
    (do-symbols (s lib)
      (when (and (eq (symbol-package s) lib)
                 (not (find-symbol (symbol-name s) test)))
        (import s test)))))

(def-suite vivace-cabinet-suite :description "vivace-cabinet tests")
