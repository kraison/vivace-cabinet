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

(fiveam:test native-output-is-read
  (let ((r (parse-native-output (format nil "<In-order Test>~%~
opening the database:~%count: 0~%time: 0.002~%setting records:~%~
....... (00001000)~%count: 1260~%size: 6338328~%time: 0.008~%~
getting records:~%count: 1257~%time: 0.002~%removing records:~%~
count: 503~%time: 0.004~%closing the database:~%time: 0.003~%ok~%"))))
    (fiveam:is (equalp '(0.002d0 0.008d0 0.002d0 0.004d0 0.003d0 1260 503 0)
                       (mapcar (lambda (k) (getf r k))
                               '(:open :set :get :remove :close :count :left
                                 :errors))))))

(fiveam:test runs-in-their-own-processes
  "Kyoto's own program and a Lisp child each run measured: every
record set and removed, the process's CPU and memory, and the size."
  (with-scratch (dir)
    (dolist (engine '(:kyoto-hash-native :hash))
      (let ((r (run-one engine :n 600 :threads 2 :dir dir)))
        (fiveam:is (equal '(600 0 0 0)
                          (mapcar (lambda (k) (getf r k))
                                  '(:count :left :errors :exit)))
                   "~a: ~s" engine r)
        (fiveam:is (every (lambda (k) (realp (getf r k)))
                          '(:set :cpu :rss-kb :size-kb)))))))

(fiveam:test port-matches-kyotos-own-test
  "One thread, one seed: Kyoto's own program, Kyoto from Lisp and
vivace-cabinet end each phase with the same records, so the port draws
the same keys and the same extra operations."
  (with-scratch (dir)
    (dolist (group '((:kyoto-hash-native :kyoto-hash :hash)
                     (:kyoto-tree-native :kyoto-tree :bplus-tree
                      :skip-list)))
      (let ((counts (mapcar (lambda (engine)
                              (let ((r (run-one engine :n 3000 :random t
                                                       :seed 7 :dir dir)))
                                (list (getf r :count) (getf r :left))))
                            group)))
        (fiveam:is (= 1 (length (remove-duplicates counts :test #'equal)))
                   "~s" (mapcar #'cons group counts))))))

(fiveam:test report-takes-medians
  "Each cell: the median of the runs, the slowest and fastest beside
it; a failed run is left out and said so."
  (with-scratch (dir)
    (with-open-file (s (merge-pathnames "runs.csv" dir) :direction :output)
      (write-header s *columns*)
      (loop for (engine set errors exit) in '((:hash 1 0 0) (:hash 2 0 0)
                                              (:hash 5 0 0)
                                              (:bplus-tree 1 0 0)
                                              (:bplus-tree 1 0 1)
                                              (:bplus-tree 1 3 0))
            for repeat from 1
            do (write-row s (list :machine "m" :engine engine
                                  :tuning :default :order :sequential
                                  :n 1000000 :threads 1 :repeat repeat
                                  :open 0.5 :set set :get 1 :remove 1
                                  :close 0.5 :cpu 3 :rss-kb 2048
                                  :count 1000000 :left 0 :errors errors
                                  :exit exit)
                          *columns*)))
    (with-open-file (s (merge-pathnames "sizes.csv" dir) :direction :output)
      (write-header s *size-columns*)
      (write-row s '(:engine :hash :tuning :default :order :sequential
                     :n 1000000 :size-kb 3072 :count 1000000 :exit 0)
                 *size-columns*))
    (with-open-file (s (merge-pathnames "env.txt" dir) :direction :output)
      (format s "machine: m~%cores: 4~%"))
    (let ((text (uiop:read-file-string (write-report dir))))
      (fiveam:is (search (format nil "| vivace-cabinet HashDB | 1 | ~
500 (200–1,000) | 1,000 (1,000–1,000) | 1,000 (1,000–1,000) | 1.00 | ~
3.0 | 2 | 3.0 |")
                         text)
                 "~a" text)
      (fiveam:is (search "2 of 3 runs failed" text) "~a" text))))

(fiveam:test matrix-writes-a-row-per-run
  "A row per run and per size run; an engine without a tuning knob runs
on defaults only."
  (with-scratch (dir)
    (let* ((out (merge-pathnames "out/" dir))
           (data (merge-pathnames "data/" dir)))
      (run-matrix :engines '(:kyoto-hash-native :bplus-tree) :ns '(300)
                  :threads '(1) :orders '(:sequential)
                  :tunings '(:default :tuned) :repeats 2 :data data :out out)
      (let ((runs (read-runs (merge-pathnames "runs.csv" out)))
            (sizes (read-runs (merge-pathnames "sizes.csv" out))))
        (fiveam:is (= 6 (length runs)))
        (fiveam:is (= 3 (length sizes)))
        (fiveam:is (every (lambda (r) (eql 0 (getf r :exit))) runs))
        (fiveam:is (notany (lambda (r) (and (eq :bplus-tree (getf r :engine))
                                            (eq :tuned (getf r :tuning))))
                           runs))
        (fiveam:is (probe-file (write-report out)))))))

(defclass lying-db () ()
  (:documentation "A database whose every get returns the wrong value."))

(defmethod db-get ((db lying-db) key &key as)
  (declare (ignore key as))
  (coerce #(122 122) '(simple-array (unsigned-byte 8) (*))))

(fiveam:test get-phase-checks-values
  "As in Kyoto's test, a get that returns another value is an error."
  (fiveam:is (= 10 (phase-work (make-instance 'lying-db) :get 0 10 1 nil
                               (make-rng 1)))))

(fiveam:test failing-runs-say-so
  "A Lisp child whose run has errors exits 1, and its output is logged."
  (with-scratch (dir)
    (let* ((log (merge-pathnames "failures.log" dir))
           (r (run-one :hash :n 100 :dir (merge-pathnames "db/" dir)
                             :log log :phases '(:get))))
      (fiveam:is (= 100 (getf r :errors)) "~s" r)
      (fiveam:is (= 1 (getf r :exit)) "~s" r)
      (fiveam:is-true (probe-file log)))))
