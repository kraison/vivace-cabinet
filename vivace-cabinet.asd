(defsystem "vivace-cabinet"
  :description "A Kyoto Cabinet-style key-value store in Common Lisp, built
from vivace-graph's on-disk structures."
  :author "Kevin Raison"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria" "babel" "bordeaux-threads" "cffi" "cl-ppcre"
               "cl-store" "log4cl" "uiop" #+(or ccl lispworks) "closer-mop")
  :serial t
  :components ((:file "package")
               (:module "substrate"
                :serial t
                :components ((:file "globals")
                             (:file "conditions")
                             (:file "posix")
                             (:file "utilities")
                             (:file "queue")
                             #+(or sbcl lispworks ecl) (:file "rw-lock")
                             (:file "mmap")
                             (:file "buffers")
                             (:file "allocator")
                             (:file "heap-bytes")))
               (:module "structures"
                :serial t
                :components (#+ecl (:file "cl-store-ecl")
                             (:file "hash-key")
                             (:file "linear-hash")
                             (:file "cursors")
                             (:file "skip-list")
                             (:file "skip-list-cursors")
                             (:file "bplus-tree")))
               (:file "murmur3")
               (:file "records")
               (:file "api")
               (:file "dir-lock")
               (:file "database")
               (:file "hash-db")
               (:file "tree-engine")
               (:file "bplus-engine")
               (:file "skip-list-engine")
               (:file "tree-db")
               (:file "tree-cursor")
               (:file "hash-cursor")
               (:file "visitors")
               (:file "atomic-ops")
               (:file "bulk")
               (:file "match")
               (:file "admin"))
  :in-order-to ((test-op (test-op "vivace-cabinet/test"))))

(defsystem "vivace-cabinet/test"
  :description "FiveAM tests for vivace-cabinet."
  :depends-on ("vivace-cabinet" "fiveam" "babel" "uiop")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "allocator-tests")
               (:file "linear-hash-tests")
               (:file "skip-list-tests")
               (:file "bplus-tree-tests")
               (:file "murmur3-tests")
               (:file "record-tests")
               (:file "hash-db-tests")
               (:file "hash-db-modes-tests")
               (:file "tree-engine-tests")
               (:file "tree-db-tests")
               (:file "cursor-tests")
               (:file "hash-cursor-tests")
               (:file "concurrency-tests")
               (:file "visitor-tests")
               (:file "atomic-ops-tests")
               (:file "bulk-tests")
               (:file "match-tests")
               (:file "admin-tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call
                      :fiveam :run!
                      (uiop:find-symbol* :vivace-cabinet-suite
                                         :vivace-cabinet-test))
               (error "vivace-cabinet tests failed"))))
