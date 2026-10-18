;;;; bench/run.sh's entry point.

(in-package #:vivace-cabinet-bench)

(defun results-directory (name)
  (asdf:system-relative-pathname :vivace-cabinet
                                 (format nil "bench/results/~a/" name)))

(defun main (&key quick out data repeats ns threads engines)
  "Run the matrix and write its report.  QUICK runs a small matrix that
checks the harness in a few minutes, into a temporary directory;
otherwise the spec's matrix goes to bench/results/MACHINE-DATE/ and its
report to docs/benchmarks/round-1.md.  The other keywords override the
matrix's parts."
  (let* ((stamp (remove-if-not #'alphanumericp
                               (subseq (timestamp) 0 16)))
         (out (or (and out (uiop:ensure-directory-pathname out))
                  (if quick
                      (merge-pathnames (format nil "vc-bench-quick-~a/"
                                               stamp)
                                       (uiop:temporary-directory))
                      (results-directory
                       (format nil "~a-~a" (machine-instance) stamp)))))
         (out (run-matrix :ns (or ns (if quick '(2000) '(1000000 10000000)))
                          :threads (or threads (if quick '(1 2) '(1 4 8)))
                          :repeats (or repeats (if quick 2 5))
                          :engines (or engines *engines*)
                          :data (or data (default-data-directory))
                          :out out))
         (report (if quick
                     (merge-pathnames "report.md" out)
                     (asdf:system-relative-pathname
                      :vivace-cabinet "docs/benchmarks/round-1.md"))))
    (ensure-directories-exist report)
    (write-report out :report report)
    (format t "~&runs: ~a~%report: ~a~%"
            (uiop:native-namestring (merge-pathnames "runs.csv" out))
            (uiop:native-namestring report))
    report))
