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

(test only-defined-library-symbols-are-imported
  "A library symbol with no definition on it, such as one a source load
interns for a lexical variable, is not imported: a test helper of that
name would otherwise be defined on it (#5)."
  (let ((stray (intern "NO-DEFINITION-HERE" '#:vivace-cabinet)))
    (unwind-protect
         (progn
           (is (not (member stray (importable-symbols))))
           (is (defined-p 'proper-listp))
           (is (defined-p '*cache-enabled*))
           (is (defined-p 'bplus-tree))
           (is (defined-p 'uint64)))
      (unintern stray '#:vivace-cabinet))))
