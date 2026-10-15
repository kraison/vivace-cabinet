(defsystem "vivace-cabinet"
  :description "A Kyoto Cabinet-style key-value store in Common Lisp, built
from vivace-graph's on-disk structures."
  :author "Kevin Raison"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria" "bordeaux-threads" "cffi" "cl-store" "log4cl"
               #+(or ccl lispworks) "closer-mop")
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
                             (:file "allocator")))
               (:module "structures"
                :serial t
                :components (#+ecl (:file "cl-store-ecl")
                             (:file "hash-key")
                             (:file "linear-hash")
                             (:file "cursors")
                             (:file "skip-list")
                             (:file "skip-list-cursors")
                             (:file "bplus-tree"))))
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
               (:file "bplus-tree-tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call
                      :fiveam :run!
                      (uiop:find-symbol* :vivace-cabinet-suite
                                         :vivace-cabinet-test))
               (error "vivace-cabinet tests failed"))))
