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

(fiveam:test repeats-share-no-generator
  "Repeat R runs on seed R, yet no thread of any repeat draws the same
numbers as another's: here five repeats of eight threads."
  (flet ((draws (rng)
           (loop repeat 8 collect (myrand rng 1000000))))
    (let ((streams (loop for seed from 1 to 5
                         nconc (mapcar #'draws (thread-rngs seed 8)))))
      (fiveam:is (= 40 (length (remove-duplicates streams
                                                  :test #'equal)))))))

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

(fiveam:test interrupted-sessions-keep-their-rows
  "A session stopped partway, as by Ctrl-C, keeps the rows it wrote."
  (with-scratch (dir)
    (let* ((out (merge-pathnames "out/" dir))
           (csv (merge-pathnames "runs.csv" out))
           (worker (bt:make-thread
                    (lambda ()
                      (run-matrix :engines '(:kyoto-hash-native) :ns '(200)
                                  :threads '(1) :orders '(:sequential)
                                  :tunings '(:default) :repeats 200
                                  :data (merge-pathnames "data/" dir)
                                  :out out)))))
      (loop repeat 600
            until (and (probe-file csv) (<= 2 (length (read-runs csv))))
            do (sleep 0.1))
      (ignore-errors (bt:destroy-thread worker))
      (ignore-errors (bt:join-thread worker))
      (sleep 0.5)
      (fiveam:is-true (probe-file csv))
      (fiveam:is (<= 2 (length (and (probe-file csv) (read-runs csv))))))))

(fiveam:test reports-skip-a-truncated-row
  "A row cut short, as when power is lost mid-write, is left out."
  (with-scratch (dir)
    (with-open-file (s (merge-pathnames "runs.csv" dir) :direction :output)
      (write-header s *columns*)
      (write-row s (list :machine "m" :engine :hash :tuning :default
                         :order :sequential :n 1000 :threads 1 :repeat 1
                         :open 0.1 :set 0.1 :get 0.1 :remove 0.1
                         :close 0.1 :cpu 0.5 :rss-kb 1024 :count 1000
                         :left 0 :errors 0 :exit 0)
                 *columns*)
      (format s "m,2026-10-18T00:00:00Z,hash,default,seq"))
    (with-open-file (s (merge-pathnames "env.txt" dir) :direction :output)
      (format s "machine: m~%"))
    (fiveam:is (= 1 (length (read-runs (merge-pathnames "runs.csv" dir)))))
    (fiveam:is-true (probe-file (write-report dir)))))

(fiveam:test failed-runs-do-not-stop-the-session
  "A run that cannot start, in the child or in the parent, becomes a
failed row and the session goes on."
  (with-scratch (dir)
    (let ((out (merge-pathnames "out/" dir))
          (*kyoto-programs* '((:kyoto-hash-native . "no-such-kchashtest")
                              (:kyoto-tree-native . 42))))
      (run-matrix :engines '(:kyoto-hash-native :kyoto-tree-native :hash)
                  :ns '(200) :threads '(1) :orders '(:sequential)
                  :tunings '(:default) :repeats 1
                  :data (merge-pathnames "data/" dir) :out out)
      (let ((exits (mapcar (lambda (r) (list (getf r :engine) (getf r :exit)))
                           (read-runs (merge-pathnames "runs.csv" out)))))
        (fiveam:is (equal '((:kyoto-hash-native 127) (:kyoto-tree-native -1)
                            (:hash 0))
                          exits)
                   "~s" exits))
      (fiveam:is-true (probe-file (merge-pathnames "failures.log" out))))))

(fiveam:test runs-stop-at-their-timeout
  "A run still going at its timeout is killed, with its threads and any
child of its own, and reported as timed out."
  (with-scratch (dir)
    (let* ((start (get-internal-real-time))
           (r (run-one :hash :n 5000000 :dir (merge-pathnames "db/" dir)
                             :timeout 3))
           (seconds (/ (- (get-internal-real-time) start)
                       internal-time-units-per-second)))
      (fiveam:is (eql -9 (getf r :exit)) "~s" r)
      (fiveam:is-true (getf r :timed-out))
      (fiveam:is (< seconds 30) "~,1f s" seconds)
      (fiveam:is (null (command-output "pgrep" "-f"
                                       (namestring dir)))))))

(fiveam:test interrupted-runs-leave-no-child
  "A run interrupted mid-way, as Ctrl-C or a kill unwinds it, takes its
child with it at once."
  (with-scratch (dir)
    (let* ((db (merge-pathnames "db/" dir))
           (worker (bt:make-thread
                    (lambda () (run-one :hash :n 5000000 :dir db)))))
      (loop repeat 300
            until (command-output "pgrep" "-f" (namestring db))
            do (sleep 0.1))
      (fiveam:is-true (command-output "pgrep" "-f" (namestring db)))
      (ignore-errors (bt:destroy-thread worker))
      (loop repeat 100
            while (command-output "pgrep" "-f" (namestring db))
            do (sleep 0.1))
      (fiveam:is (null (command-output "pgrep" "-f" (namestring db))))
      (ignore-errors (bt:join-thread worker)))))

(defun holders (path)
  "The PIDs of processes whose command line holds PATH."
  (let ((out (command-output "pgrep" "-f" (namestring path))))
    (and out (uiop:split-string out :separator '(#\Newline)))))

(fiveam:test terminated-sessions-stop-at-once
  "A session sent SIGTERM mid-run, as kill or systemd sends it, stops at
once and takes its run's child with it."
  (with-scratch (dir)
    (let* ((db (merge-pathnames "db/" dir))
           (session (uiop:launch-program
                     (sbcl-command
                      (format nil "(vivace-cabinet-bench::run-one :hash ~
:n 5000000 :dir #p~s)" (namestring db)))
                     :output nil :error-output nil)))
      (unwind-protect
           (progn
             (loop repeat 600
                   until (probe-file (merge-pathnames "db.vch/" db))
                   do (sleep 0.1))
             (fiveam:is-true (probe-file (merge-pathnames "db.vch/" db)))
             (uiop:terminate-process session)
             (loop repeat 150
                   while (holders db)
                   do (sleep 0.1))
             (fiveam:is (null (holders db)) "still running: ~s"
                        (holders db)))
        (dolist (pid (holders db))
          (command-output "kill" "-9" pid))
        (ignore-errors (uiop:wait-process session))))))

(defun holder-lines (path)
  "\"PID command line\" for each process whose command line holds PATH."
  (let ((out (command-output "pgrep" "-a" "-f" (namestring path))))
    (and out (uiop:split-string out :separator '(#\Newline)))))

(defun poisoned-home (dir)
  "A home directory in DIR whose .sbclrc exits with status 3."
  (let ((home (merge-pathnames "home/" dir)))
    (ensure-directories-exist home)
    (with-open-file (s (merge-pathnames ".sbclrc" home) :direction :output)
      (write-line "(sb-ext:exit :code 3 :abort t)" s))
    (format nil "HOME=~a" (uiop:native-namestring home))))

(fiveam:test builds-ignore-the-users-init-file
  "The SBCL that builds a session's core reads no ~/.sbclrc, which could
change how the code under test is compiled."
  (with-scratch (dir)
    (multiple-value-bind (output m)
        (measured (sbcl-command "(uiop:quit 0)")
                  (merge-pathnames "measure.out" dir)
                  :environment
                  (list (poisoned-home dir)
                        (format nil "XDG_CACHE_HOME=~a"
                                (uiop:native-namestring
                                 (uiop:xdg-cache-home)))))
      (fiveam:is (eql 0 (getf m :exit)) "~a" output))))

(fiveam:test core-children-load-nothing
  "A child started from a session's core reads no init file and loads
no code: with a ~/.sbclrc that exits and no FASL cache, it still runs."
  (with-scratch (dir)
    (let ((core (bench-core dir))
          (db (prepare-directory (merge-pathnames "db/" dir))))
      (multiple-value-bind (output m)
          (measured (lisp-command (list :engine :hash :n 300
                                        :dir (namestring db))
                                  core)
                    (merge-pathnames "measure.out" dir)
                    :environment (list (poisoned-home dir)
                                       "XDG_CACHE_HOME=/nonexistent/cache"))
        (fiveam:is (eql 0 (getf m :exit)) "~a" output)
        (fiveam:is (eql 300 (getf (read-result output) :count)))))))

(fiveam:test sessions-run-children-from-their-core
  "A session's Lisp runs, size runs and timed runs alike, start from the
core it saved when it began, not from the checkout as it is when each
run starts; the session deletes the core when it ends."
  (with-scratch (dir)
    (let* ((data (merge-pathnames "data/" dir))
           (run (merge-pathnames "run/" data))
           (core (uiop:native-namestring
                  (merge-pathnames "bench.core" data)))
           (session (uiop:launch-program
                     (sbcl-command
                      (format nil "(vivace-cabinet-bench::run-matrix ~
:engines '(:hash) :ns '(50000) :orders '(:sequential) ~
:tunings '(:default) :threads '(1) :repeats 1 :data #p~s :out #p~s)"
                              (namestring data)
                              (namestring (merge-pathnames "out/" dir))))
                     :output nil :error-output nil))
           (seen '()))
      (unwind-protect
           (progn
             (loop repeat 6000
                   while (uiop:process-alive-p session)
                   do (dolist (l (holder-lines run))
                        (when (search "vivace-cabinet-bench::child" l)
                          (pushnew l seen :test #'string=)))
                      (sleep 0.05))
             (fiveam:is-true (find-if (lambda (l) (search ":PHASES (:SET)" l))
                                      seen))
             (fiveam:is-true (find-if-not
                              (lambda (l) (search ":PHASES (:SET)" l))
                              seen))
             (dolist (l seen)
               (fiveam:is-true (search (format nil "--core ~a" core) l)
                               "~a" l))
             (fiveam:is (null (probe-file core))))
        (uiop:terminate-process session)
        (loop repeat 150
              while (holders run)
              do (sleep 0.1))
        (dolist (pid (holders run))
          (command-output "kill" "-9" pid))
        (ignore-errors (uiop:wait-process session))))))
