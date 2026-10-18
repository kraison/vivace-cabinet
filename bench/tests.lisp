(in-package #:vivace-cabinet-bench)

(fiveam:def-suite bench-suite
  :description "The benchmark harness, at small sizes.")

(fiveam:in-suite bench-suite)

(defmacro with-scratch ((var) &body body)
  "Bind VAR to a new directory for the test's databases."
  `(let ((,var (prepare-directory
                (merge-pathnames
                 (format nil "vc-bench-test-~36r/"
                         (random (expt 36 8) (make-random-state t)))
                 (uiop:temporary-directory)))))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,var :validate t
                                        :if-does-not-exist :ignore))))

(fiveam:test rng-matches-kyotos-myrand
  "From seed 42, the numbers Kyoto's own myrand gives (cmdcommon.h,
compiled and run)."
  (let ((r (make-rng 42)))
    (fiveam:is (equal '(843145 662182 733804 671905 787782 90793)
                      (loop repeat 6 collect (myrand r 1000000))))))

(fiveam:test keys-are-kyotos
  "Keys as Kyoto's order test prints them, %08lld."
  (flet ((k (n) (map 'string #'code-char (key-octets n))))
    (fiveam:is (equal "00000000" (k 0)))
    (fiveam:is (equal "00000001" (k 1)))
    (fiveam:is (equal "99999999" (k 99999999)))
    (fiveam:is (equal "123456789" (k 123456789)))))

(fiveam:test order-test-runs-on-every-lisp-engine
  "Sequential runs set, find and remove every record; random runs find
nothing unexpected; every phase is timed."
  (with-scratch (dir)
    (dolist (engine '(:hash :bplus-tree :skip-list :kyoto-hash :kyoto-tree))
      (dolist (random '(nil t))
        (let ((r (run-order engine :n 600 :threads 3 :random random
                                   :tuned t :dir (prepare-directory dir))))
          (fiveam:is (eql 0 (getf r :errors)) "~a ~a: ~s" engine random r)
          (fiveam:is (every (lambda (p) (realp (getf r p)))
                            '(:open :set :get :remove :close :cpu)))
          (if random
              (fiveam:is (< 0 (getf r :left) (getf r :count) 600)
                         "~a: ~s" engine r)
              (fiveam:is (equal '(600 0) (list (getf r :count)
                                               (getf r :left)))
                         "~a: ~s" engine r)))))))
