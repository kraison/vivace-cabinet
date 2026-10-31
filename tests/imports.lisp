(in-package #:vivace-cabinet-test)

;;; Loaded last (vivace-cabinet.asd), when every test file is in (#5).

(check-imports)

(def-suite imports-suite
  :description "The test package's view of the library."
  :in vivace-cabinet-suite)

(in-suite imports-suite)

(test check-imports-catches-a-redefined-library-function
  "CHECK-IMPORTS names an imported library function whose definition is
not the one in its snapshot, and passes once it is back."
  (let* ((symbol 'proper-listp)
         (old (fdefinition symbol))
         (snapshot (snapshot-imports)))
    (unwind-protect
         (progn
           (setf (fdefinition symbol) (lambda (x) (funcall old x)))
           (signals error (check-imports snapshot)))
      (setf (fdefinition symbol) old))
    (finishes (check-imports snapshot))))
