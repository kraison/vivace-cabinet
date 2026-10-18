;;;; Kyoto Cabinet behind vivace-cabinet's API (spec: unit 3).  Used by
;;;; the conformance check and by the benchmark's Kyoto-from-Lisp row.

(defpackage #:vivace-cabinet-kyoto
  (:use #:common-lisp #:vivace-cabinet)
  (:import-from #:vivace-cabinet
                #:to-octets #:from-octets #:check-as #:%signal #:octets
                #:%release-cursor #:%cursor-db)
  (:export #:kyoto-db #:open-kyoto-db #:kyoto-error-code))
