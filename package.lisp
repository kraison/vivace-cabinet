;;;; The vivace-cabinet package.  Its :use and shadowing follow
;;;; vivace-graph's graph-db package (package.lisp at 853df62), which the
;;;; copied code was written against.

(defpackage #:vivace-cabinet
  (:use #:cl #:bordeaux-threads)
  #+sbcl (:shadowing-import-from #:sb-ext #:word)
  #+ccl (:shadowing-import-from #:closer-mop
         #:standard-method #:finalize-inheritance
         #:standard-generic-function #:defmethod #:defgeneric
         #:standard-class #:compute-discriminating-function
         #:compute-applicable-methods-using-classes
         #:compute-effective-method #:method-function
         #:make-method-lambda)
  (:export #:vivace-cabinet-error #:not-implemented #:invalid-argument
           #:open-error #:open-db #:close-db #:with-db
           #:db-set #:db-add #:db-replace #:db-append #:db-get #:db-check
           #:db-seize #:db-remove #:db-count #:db-size #:db-path
           #:db-clear #:db-synchronize #:db-error
           #:key-too-long #:octets<
           #:db-cursor #:with-cursor #:cursor-jump #:cursor-jump-back
           #:cursor-step #:cursor-step-back #:cursor-get #:cursor-get-key
           #:cursor-get-value #:cursor-set-value #:cursor-remove
           #:cursor-seize
           #:db-accept #:db-accept-bulk
           #:db-cas #:db-increment #:db-increment-double
           #:db-set-bulk #:db-get-bulk #:db-remove-bulk
           #:db-iterate #:db-scan-parallel #:cursor-accept
           #:db-match-prefix #:db-match-regex #:db-match-similar
           #:db-status #:db-occupy #:db-copy #:db-merge
           #:db-dump-snapshot #:db-load-snapshot
           #:transactions-not-implemented #:db-begin-transaction
           #:db-begin-transaction-try #:db-end-transaction
           #:with-transaction))
