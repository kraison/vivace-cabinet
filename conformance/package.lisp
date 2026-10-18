;;;; The conformance check (spec: unit 3): random operation sequences run
;;;; on vivace-cabinet and on Kyoto Cabinet, compared step by step.

(defpackage #:vivace-cabinet-conformance
  (:use #:common-lisp #:vivace-cabinet #:vivace-cabinet-kyoto)
  (:export #:check-conformance #:*kinds* #:run-sequence))
