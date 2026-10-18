;;;; Benchmark round 1 (spec: unit 3): Kyoto Cabinet's order test on
;;;; each engine, the matrix of runs, and the report.  How to run it:
;;;; docs/benchmarks/README.md.

(defpackage #:vivace-cabinet-bench
  (:use #:common-lisp #:vivace-cabinet #:vivace-cabinet-kyoto)
  (:export #:*engines* #:run-order #:run-native #:run-matrix
           #:write-report #:main))
