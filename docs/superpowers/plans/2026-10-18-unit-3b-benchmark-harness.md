# Unit 3b: the benchmark harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** `bench/run.sh`, which runs Kyoto Cabinet's order test on every
engine of the spec's table, records each run, and writes the report. It
is tested at small sizes; phase 3c runs the full matrix.

**Architecture:** `vivace-cabinet/bench` ports Kyoto's order test to
vivace-cabinet's generic functions, so one workload drives Kyoto from
Lisp and vivace-cabinet's three engines. Each run is a fresh process on
a fresh database: a Lisp child for those four engines, Kyoto's own
`kchashtest` or `kctreetest` for the native rows. `bench/measure.py`
reads each child's CPU and peak memory with `wait4`. The matrix writes
`runs.csv`, `sizes.csv` and `env.txt`, and the report generator turns
them into markdown.

**Tech Stack:** SBCL, FiveAM, Kyoto Cabinet 1.2.80 and its test
programs, python3 (`measure.py` only), bash (`run.sh`).

**Spec:** `docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`,
unit 3: "Workload", "Engines", "Fairness", "Recorded per run", "Output";
the phase split is on kraison/vivace-cabinet#3. Kyoto's test source is
`kchashtest.cc` and `kctreetest.cc` of 1.2.80; its tuning advice is in
its `doc/spex.html`.

**Dry run:** every block below was applied, task by task, to a copy of
`main` (8e92e65). Each failing-test step failed exactly as its Expected
line says. The final harness suite passed (49 checks), and the core
(12,920) and conformance (25) suites were unaffected. `bench/run.sh
--quick` ran 96 timed runs and 24 size runs in under two minutes, and
every mutation check below failed as a test failure.

## Global Constraints

- SBCL only. New Lisp: spaces only, 80 columns, terse comments.
- vivace-graph and cl-kyoto-cabinet are not changed.
- The core system and its suite do not depend on the benchmark.
- Branch `unit-3b-benchmark-harness` in `~/work/vivace-cabinet`; one
  commit per task; explicit `git add` paths; nothing pushed without
  Kevin's word.
- Public repo: generic commit messages and issue text.
- Every commit message ends with:

  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ
  ```

## Commands

`VC-BENCH-TEST` (the harness's suite; about 20 seconds):

```bash
mkdir -p /var/tmp/vc-tests && cd ~/work/vivace-cabinet && \
TMPDIR=/var/tmp/vc-tests sbcl --noinform --non-interactive \
  --load ~/quicklisp/setup.lisp \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval '(push (merge-pathnames "work/cl-kyoto-cabinet/" (user-homedir-pathname)) asdf:*central-registry*)' \
  --eval '(ql:quickload (list :alexandria :bordeaux-threads :cffi :cl-ppcre :cl-store :log4cl :fiveam :babel) :silent t)' \
  --eval '(asdf:load-system :vivace-cabinet/bench-test :force (list :vivace-cabinet :vivace-cabinet/kyoto :vivace-cabinet/bench :vivace-cabinet/bench-test))' \
  --eval '(asdf:test-system :vivace-cabinet/bench-test)'
```

`VC-BENCH-ONE <name>`: the same with the last `--eval` replaced by
`--eval '(unless (fiveam:run! (quote vivace-cabinet-bench::<name>)) (uiop:quit 1))'`.

`VC-SUITE` and `VC-CONFORM` are unit 3a's: the core and conformance
suites, run at the end of Task 3 to show nothing else moved.

Mutation checks: change the code in place as stated, run the named test,
confirm it fails *as a test failure, not a compile error*, and restore
the file byte for byte. Run them under `timeout 400`. Logs can contain
NUL bytes: `grep -a`.

## Review Focus

1. **The port drawing Kyoto's keys and operations.** With one thread
   and one seed, each engine must end each phase with exactly the
   records Kyoto's own program ends with (Task 2
   `port-matches-kyotos-own-test`; Task 1 `rng-matches-kyotos-myrand`,
   `keys-are-kyotos`).
2. **Records divided among threads.** N records over T threads must
   still be N records, with none lost or doubled, in Lisp and in Kyoto's
   programs (Task 1 `order-test-runs-on-every-lisp-engine`, 3 threads;
   Task 2 `runs-in-their-own-processes`, 2 threads).
3. **A run that fails.** The report must leave it out and say so,
   never average it in (Task 3 `report-takes-medians`).
4. **Engines without a tuning knob.** vivace-cabinet's TreeDB must run
   on defaults only, not twice as the same thing (Task 3
   `matrix-writes-a-row-per-run`).
5. **Every child measured.** Both kinds of child must report CPU, peak
   memory and size (Task 2 `runs-in-their-own-processes`).

## Proposals in this plan for Kevin to approve

- **A spec correction: Kyoto's TreeDB is tuned to a tenth of N.** The
  spec says to tune Kyoto's bucket count to 2N "as its documentation
  recommends". Its documentation says that for HashDB; for TreeDB it
  advises about 10% of the records. vivace-cabinet's TreeDB has no
  bucket count, so it runs on defaults only. The correction is a commit
  on main before the branch.
- **vivace-cabinet's HashDB is tuned to N/8 buckets.** A bucket holds
  24 entries and splits when one overflows, so N/8 makes an overflow
  unlikely. That is how "N records fit without splitting" is read.
- **`bench/measure.py`, a 20-line Python wrapper, measures each run.**
  GNU `time` is not installed, and SBCL cannot read one child's peak
  memory once it has waited for several. The wrapper reads CPU and peak
  RSS with `wait4`.
- **CPU and memory are measured as follows.**
  - A Lisp child counts its own CPU over the timed phases, leaving out
    loading Lisp; Kyoto's programs report the whole process.
  - Peak RSS is the whole process's in both. A Lisp process's includes
    SBCL's image, about 120 MB.
- **Size comes from a separate set-only run per configuration**
  (`sizes.csv`). Kyoto's TreeDB writes its pages only at close, so
  measuring after the full run shows the emptied tree (20 KB where the
  records took megabytes).
- **The data directory** defaults to `/var/tmp/vc-bench/`, made
  `chattr +C` on btrfs, so files are neither copied on write nor
  compressed. robotron's `/var/tmp` is btrfs with zstd compression.
- **Seeds are fixed per repeat** (Kyoto's programs take them as
  `KCRNDSEED`). Each Lisp thread has its own generator, where Kyoto's
  threads share one.
- **The report** gives thousands of records per second: the median of
  the repeats, with the slowest and fastest in brackets, a table per
  record count, order and tuning.
- **Where results go.** `--quick` writes to a temporary directory. The
  full run writes `bench/results/MACHINE-DATE/` and
  `docs/benchmarks/round-1.md`.
- **A heads-up for 3c, not decided here.** A pilot at 100,000 records
  ran Kyoto at about a million records a second, and vivace-cabinet's
  HashDB, B+ tree and skip list at about 50,000, 15,000 to 35,000, and
  10,000 to 20,000 on sets. Scaled up, the spec's full matrix (10
  million records, 5 repeats) would take about 40 hours on robotron.
  3c's plan will propose the machine and the schedule.

---

### Task 1: Kyoto's order test in Lisp

**Files:**
- Create: `bench/package.lisp`, `bench/workload.lisp`, `bench/tests.lisp`
- Modify: `vivace-cabinet.asd`

**Interfaces:**
- Consumes: vivace-cabinet's generic functions, `open-db`; unit 3a's
  `open-kyoto-db`; `with-cursor`, `cursor-get :step`.
- Produces (package `vivace-cabinet-bench`): `*engines*`; `(make-rng
  seed)`, `(myrand rng range)`; `(key-octets n)`; `(native-p engine)`,
  `(tunable-p engine)`, `(bucket-tuning engine n)`, `(engine-path engine
  dir)`, `(open-engine engine dir n tuned)`; `(prepare-directory dir)`;
  `(run-phase db phase rngs rnum random)`; `(run-order engine &key n
  threads random tuned seed dir phases)` → plist `:open :set :get
  :remove :close` seconds, `:cpu`, `:count`, `:left`, `:errors`. The
  suite `bench-suite` and macro `with-scratch`.

- [ ] **Step 1: Branch**

```bash
cd ~/work/vivace-cabinet && git switch -c unit-3b-benchmark-harness
```

- [ ] **Step 2: Write the failing tests**

Create `bench/package.lisp`:

```lisp
;;;; Benchmark round 1 (spec: unit 3): Kyoto Cabinet's order test on
;;;; each engine, the matrix of runs, and the report.  How to run it:
;;;; docs/benchmarks/README.md.

(defpackage #:vivace-cabinet-bench
  (:use #:common-lisp #:vivace-cabinet #:vivace-cabinet-kyoto)
  (:export #:*engines* #:run-order #:run-native #:run-matrix
           #:write-report #:main))
```

Create `bench/tests.lisp`:

```lisp
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
```

In `vivace-cabinet.asd`, before `(defsystem "vivace-cabinet/test"`, add:

```lisp
(defsystem "vivace-cabinet/bench"
  :description "Benchmark round 1: Kyoto Cabinet's order test on Kyoto
and on vivace-cabinet."
  :depends-on ("vivace-cabinet" "vivace-cabinet/kyoto" "alexandria"
               "bordeaux-threads" "uiop")
  :pathname "bench/"
  :serial t
  :components ((:file "package")))

(defsystem "vivace-cabinet/bench-test"
  :description "Tests of the benchmark harness, at small sizes."
  :depends-on ("vivace-cabinet/bench" "fiveam")
  :pathname "bench/"
  :components ((:file "tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call
                      :fiveam :run!
                      (uiop:find-symbol* :bench-suite
                                         :vivace-cabinet-bench))
               (error "benchmark harness tests failed"))))
```

- [ ] **Step 3: Run the suite and watch it fail**

Run: `VC-BENCH-TEST`
Expected: non-zero exit; `rng-matches-kyotos-myrand`, `keys-are-kyotos` and
`order-test-runs-on-every-lisp-engine` fail with `UNDEFINED-FUNCTION`
`MAKE-RNG`, `KEY-OCTETS` and `PREPARE-DIRECTORY`.

- [ ] **Step 4: Write the workload**

Create `bench/workload.lisp`:

```lisp
;;;; Kyoto's order test (kchashtest.cc and kctreetest.cc, procorder)
;;;; through vivace-cabinet's generic functions, so one workload runs on
;;;; Kyoto through the adapter and on vivace-cabinet's own engines.

(in-package #:vivace-cabinet-bench)

;;; Kyoto's random numbers (cmdcommon.h, myrand): xorshift on 64-bit
;;; words.  Kyoto's test shares one generator among its threads; here
;;; each thread has its own, seeded as Kyoto's mysrand seeds.

(defstruct (rng (:constructor %make-rng (x)))
  (x 0 :type (unsigned-byte 64))
  (y 362436069 :type (unsigned-byte 64))
  (z 521288629 :type (unsigned-byte 64))
  (w 88675123 :type (unsigned-byte 64)))

(declaim (inline myrand))
(defun myrand (rng range)
  "Kyoto's myrand: the next number below RANGE."
  (declare (type rng rng) (type (integer 1 #.(1- (expt 2 63))) range)
           (optimize speed))
  (let* ((x (rng-x rng))
         (tt (logxor x (ldb (byte 64 0) (ash x 11))))
         (w (rng-w rng)))
    (declare (type (unsigned-byte 64) x tt w))
    (setf (rng-x rng) (rng-y rng)
          (rng-y rng) (rng-z rng)
          (rng-z rng) w
          (rng-w rng) (logxor w (ash w -19) tt (ash tt -8)))
    (mod (ldb (byte 63 0) (rng-w rng)) range)))

(defun make-rng (seed)
  "A generator in the state Kyoto's mysrand leaves its own."
  (let ((r (%make-rng (ldb (byte 64 0) seed))))
    (dotimes (i 16 r)
      (myrand r 1))))

(defun key-octets (n)
  "N as Kyoto's order test writes keys (%08lld): decimal, zero-padded
to 8 digits, as octets."
  (declare (type (integer 0 #.(1- (expt 2 62))) n))
  (let* ((len (do ((len 8 (1+ len))
                   (p 100000000 (* p 10)))
                  ((< n p) len)))
         (v (make-array len :element-type '(unsigned-byte 8))))
    (do ((i (1- len) (1- i))
         (m n (floor m 10)))
        ((< i 0) v)
      (setf (aref v i) (+ 48 (mod m 10))))))

;;; Engines

(defparameter *engines*
  '(:kyoto-hash-native :kyoto-tree-native :kyoto-hash :kyoto-tree
    :hash :bplus-tree :skip-list)
  "The engines: Kyoto's own test programs (spec rows 1), Kyoto through
the adapter (row 2), and vivace-cabinet's three (rows 3 to 5).")

(defun native-p (engine)
  (member engine '(:kyoto-hash-native :kyoto-tree-native)))

(defun tunable-p (engine)
  "Whether ENGINE has a tuning knob: TreeDB in vivace-cabinet has none."
  (not (member engine '(:bplus-tree :skip-list))))

(defun bucket-tuning (engine n)
  "The bucket count ENGINE is tuned to for N records (spec: Fairness;
docs/benchmarks/README.md): Kyoto's HashDB twice N and its TreeDB a
tenth, as Kyoto's documentation advises; the linear hash N/8, so that
no 24-entry bucket overflows and splits."
  (ecase engine
    ((:kyoto-hash :kyoto-hash-native) (* 2 n))
    ((:kyoto-tree :kyoto-tree-native) (max 1 (ceiling n 10)))
    (:hash (max 1 (ceiling n 8)))))

(defun engine-path (engine dir)
  "Where ENGINE keeps its database in DIR."
  (merge-pathnames (ecase engine
                     ((:kyoto-hash :kyoto-hash-native) "db.kch")
                     ((:kyoto-tree :kyoto-tree-native) "db.kct")
                     (:hash "db.vch/")
                     ((:bplus-tree :skip-list) "db.vct/"))
                   dir))

(defun open-engine (engine dir n tuned)
  "A new, empty database of ENGINE in DIR, tuned for N records if TUNED."
  (let ((path (engine-path engine dir))
        (mode '(:writer :create :truncate)))
    (ecase engine
      (:hash (apply #'open-db path :type :hash :mode mode
                    (and tuned (list :buckets (bucket-tuning engine n)))))
      ((:bplus-tree :skip-list)
       (open-db path :type :tree :engine engine :mode mode))
      ((:kyoto-hash :kyoto-tree)
       (open-kyoto-db path :mode mode
                           :tuning (and tuned
                                        (list :bnum
                                              (bucket-tuning engine n))))))))

(defun prepare-directory (dir)
  "Make DIR new and empty.  On btrfs, its files are then neither
copied on write nor compressed (chattr +C), as database files usually
are there."
  (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)
  (ensure-directories-exist dir)
  (ignore-errors
   (uiop:run-program (list "chattr" "+C" (uiop:native-namestring dir))
                     :ignore-error-status t :error-output nil))
  dir)

;;; The workload

(defun extra-op (db k rng)
  "After every eighth record of a random run, one more operation on K,
chosen as Kyoto's test chooses.  True when it failed unexpectedly."
  (case (myrand rng 8)
    (0 (not (db-set db k k)))
    (1 (not (db-append db k k)))
    (2 (db-remove db k) nil)
    (3 (with-cursor (c db)
         (when (cursor-jump c k)
           (case (myrand rng 8)
             (1 (cursor-get-value c :step (zerop (myrand rng 10))))
             ((2 3) (cursor-get c :step (zerop (myrand rng 10))))
             (4 (when (zerop (myrand rng 8))
                  (cursor-remove c)))
             (t (cursor-get-key c :step (zerop (myrand rng 10))))))
         nil))
    (t (db-get db k) nil)))

(defun phase-work (db phase id rnum threads random rng)
  "Thread ID's part of PHASE (:SET, :GET or :REMOVE): RNUM records, keys
from ID*RNUM+1, or drawn at random from 1 to RNUM*THREADS.  The number
of unexpected failures."
  (let ((base (* id rnum))
        (range (* rnum threads))
        (errors 0))
    (loop for i from 1 to rnum
          do (let ((k (key-octets (if random
                                      (1+ (myrand rng range))
                                      (+ base i)))))
               (unless (ecase phase
                         (:set (db-set db k k))
                         (:get (or (db-get db k) random))
                         (:remove (or (db-remove db k) random)))
                 (incf errors))
               (when (and random (zerop (mod i 8)) (extra-op db k rng))
                 (incf errors))))
    errors))

(defun run-phase (db phase rngs rnum random)
  "Run PHASE from one thread per generator in RNGS, as Kyoto's test
does: in the calling thread when there is one.  Unexpected failures."
  (let ((threads (length rngs)))
    (if (= threads 1)
        (phase-work db phase 0 rnum 1 random (first rngs))
        (let* ((results (make-array threads :initial-element 0))
               (workers
                 (loop for rng in rngs
                       for id from 0
                       collect (let ((rng rng) (id id))
                                 (bt:make-thread
                                  (lambda ()
                                    (setf (aref results id)
                                          (handler-case
                                              (phase-work db phase id rnum
                                                          threads random
                                                          rng)
                                            (serious-condition (c) c))))
                                  :name "order test")))))
          (mapc #'bt:join-thread workers)
          (loop for r across results
                when (typep r 'condition)
                  do (error r)
                sum r)))))

(defun seconds-since (start)
  (/ (float (- (get-internal-real-time) start) 1d0)
     internal-time-units-per-second))

(defun run-order (engine &key (n 1000000) (threads 1) random tuned
                              (seed 1) dir (phases '(:set :get :remove)))
  "Run Kyoto's order test on ENGINE, a Lisp-reached engine, in the
fresh directory DIR: open, then PHASES, then close, each timed, N
records divided among THREADS.  A plist: each phase's seconds, :CPU
seconds over them, :COUNT after the set phase, :LEFT after the remove
phase, and :ERRORS, the unexpected failures."
  (let* ((rnum (max 1 (floor n threads)))
         (rngs (loop for id below threads collect (make-rng (+ seed id))))
         (cpu (get-internal-run-time))
         (result '())
         (db nil))
    (flet ((timed (phase fn)
             (let ((start (get-internal-real-time)))
               (prog1 (funcall fn)
                 (setf (getf result phase) (seconds-since start))))))
      (timed :open (lambda () (setf db (open-engine engine dir n tuned))))
      (let ((errors 0))
        (dolist (phase '(:set :get :remove))
          (when (member phase phases)
            (incf errors (timed phase (lambda ()
                                        (run-phase db phase rngs rnum
                                                   random))))
            (case phase
              (:set (setf (getf result :count) (db-count db)))
              (:remove (setf (getf result :left) (db-count db))))))
        (timed :close (lambda () (close-db db)))
        (list* :cpu (/ (float (- (get-internal-run-time) cpu) 1d0)
                       internal-time-units-per-second)
               :errors errors
               result)))))
```

In `vivace-cabinet.asd`, in `vivace-cabinet/bench`, replace
`:components ((:file "package")))` with

```lisp
  :components ((:file "package")
               (:file "workload")))
```

- [ ] **Step 5: Run the suite**

Run: `VC-BENCH-TEST`
Expected: exit 0 with no failures (35 checks); `grep -a -i undefined` on the
log finds nothing.

- [ ] **Step 6: Mutation checks**

1. In `bench/workload.lisp`, replace

   ```lisp
   (tt (logxor x (ldb (byte 64 0) (ash x 11))))
   ```

   with

   ```lisp
   (tt (logxor x (ldb (byte 64 0) (ash x 10))))
   ```

   run `VC-BENCH-ONE rng-matches-kyotos-myrand`; confirm it fails as a test
   failure; restore the file.
2. In `bench/workload.lisp`, replace

   ```lisp
     (let* ((len (do ((len 8 (1+ len))
   ```

   with

   ```lisp
     (let* ((len (do ((len 7 (1+ len))
   ```

   run `VC-BENCH-ONE keys-are-kyotos`; confirm it fails as a test failure;
   restore the file.
3. In `bench/workload.lisp`, replace

   ```lisp
                            (:remove (or (db-remove db k) random)))
   ```

   with

   ```lisp
                            (:remove (or (db-get db k) random)))
   ```

   run `VC-BENCH-ONE order-test-runs-on-every-lisp-engine`; confirm it fails
   as a test failure; restore the file.

- [ ] **Step 7: Commit**

```bash
git add bench/package.lisp \
  bench/workload.lisp \
  bench/tests.lisp \
  vivace-cabinet.asd
git commit -m "Benchmark: Kyoto's order test in Lisp

Kyoto's order test through vivace-cabinet's generic functions, with its
random numbers and keys, on Kyoto from Lisp and on vivace-cabinet's
engines. Part of #3.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 2: Runs in their own processes, and Kyoto's own programs

**Files:**
- Create: `bench/native.lisp`, `bench/runner.lisp`, `bench/measure.py`
- Modify: `bench/tests.lisp`, `vivace-cabinet.asd`

**Interfaces:**
- Consumes: Task 1's `run-order`, `engine-path`, `bucket-tuning`,
  `native-p`, `prepare-directory`.
- Produces: `(parse-native-output text)` → the same plist as
  `run-order`; `(native-command engine dir n threads random tuned
  &optional set-only)`; `(measured command &key environment)` →
  `(values output plist)` with `:wall :user :system :rss-kb :exit`;
  `(lisp-command spec)`, `(child spec)`, `(read-result output)`;
  `(du-kb path)`; `(run-one engine &key n threads random tuned seed dir
  log set-only)` → `run-order`'s plist plus `:rss-kb`, `:size-kb`,
  `:exit`, with `:cpu` from the child; `(command-output &rest
  command)`; `(bench-file name)`.

- [ ] **Step 1: Write the failing tests**

Append to `bench/tests.lisp`:

```lisp
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
```

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-BENCH-TEST`
Expected: non-zero exit; `native-output-is-read`,
`runs-in-their-own-processes` and `port-matches-kyotos-own-test` fail with
`UNDEFINED-FUNCTION` `PARSE-NATIVE-OUTPUT` or `RUN-ONE`; Task 1's tests
pass.

- [ ] **Step 3: Write the runner**

Create `bench/measure.py` and make it executable (`chmod +x`):

```python
#!/usr/bin/env python3
"""measure.py OUT CMD [ARG...]: run CMD, then write its wall seconds,
user and system CPU seconds, peak resident kilobytes and exit status to
OUT as one line.  GNU time is not installed everywhere; wait4 gives the
same numbers for exactly this child."""
import os
import subprocess
import sys
import time

out, cmd = sys.argv[1], sys.argv[2:]
start = time.monotonic()
child = subprocess.Popen(cmd)
_, status, usage = os.wait4(child.pid, 0)
wall = time.monotonic() - start
with open(out, "w") as f:
    f.write("%.6f %.6f %.6f %d %d\n" % (wall, usage.ru_utime, usage.ru_stime,
                                       usage.ru_maxrss,
                                       os.waitstatus_to_exitcode(status)))
sys.exit(0)
```

Create `bench/native.lisp`:

```lisp
;;;; Kyoto's own test programs (spec: Engines, row 1): kchashtest and
;;;; kctreetest order, run as child processes and read from their
;;;; output.

(in-package #:vivace-cabinet-bench)

(defparameter *phase-headers*
  '(("opening the database:" . :open) ("setting records:" . :set)
    ("getting records:" . :get) ("removing records:" . :remove)
    ("closing the database:" . :close))
  "The line that starts each timed phase in Kyoto's order test output.")

(defun parse-native-output (text)
  "The phases' seconds, :COUNT after the set phase and :LEFT after the
remove phase from Kyoto's order test output TEXT, and :ERRORS, 0 when
it ends with \"ok\"."
  (let ((phase nil)
        (result '())
        (ok nil))
    (dolist (line (uiop:split-string text :separator '(#\Newline)) result)
      (let ((header (cdr (assoc line *phase-headers* :test #'string=))))
        (cond (header (setf phase header))
              ((uiop:string-prefix-p "time: " line)
               (setf (getf result phase)
                     (let ((*read-default-float-format* 'double-float))
                       (read-from-string (subseq line 6)))))
              ((uiop:string-prefix-p "count: " line)
               (case phase
                 (:set (setf (getf result :count)
                             (parse-integer line :start 7
                                                 :junk-allowed t)))
                 (:remove (setf (getf result :left)
                                (parse-integer line :start 7
                                                    :junk-allowed t)))))
              ((string= line "ok") (setf ok t)))))
    (setf (getf result :errors) (if ok 0 1))
    result))

(defun native-command (engine dir n threads random tuned &optional set-only)
  "Kyoto's order test command for ENGINE: N records over THREADS, each
of which Kyoto runs N/THREADS records; with SET-ONLY, its set phase."
  (append (list (if (eq engine :kyoto-hash-native) "kchashtest" "kctreetest")
                "order")
          (and set-only (list "-set"))
          (and (> threads 1) (list "-th" (princ-to-string threads)))
          (and random (list "-rnd"))
          (and tuned
               (list "-bnum" (princ-to-string (bucket-tuning engine n))))
          (list (uiop:native-namestring (engine-path engine dir))
                (princ-to-string (max 1 (floor n threads))))))
```

Create `bench/runner.lisp`:

```lisp
;;;; Each run in a fresh process on a fresh database, measured (spec:
;;;; Fairness, Recorded per run).

(in-package #:vivace-cabinet-bench)

(defun bench-file (name)
  "The file NAME in bench/."
  (asdf:system-relative-pathname :vivace-cabinet
                                 (concatenate 'string "bench/" name)))

(defun command-output (&rest command)
  "COMMAND's standard output with surrounding whitespace trimmed, or
NIL when it fails."
  (ignore-errors
   (string-trim '(#\Space #\Newline)
                (uiop:run-program command :output :string
                                          :error-output nil))))

(defun measured (command &key environment)
  "Run COMMAND under measure.py: (values its output, a plist of :WALL,
:USER and :SYSTEM seconds, :RSS-KB at its peak and :EXIT)."
  (uiop:with-temporary-file (:pathname out)
    (let ((output (uiop:run-program
                   (append (and environment (cons "env" environment))
                           (list "python3"
                                 (uiop:native-namestring
                                  (bench-file "measure.py"))
                                 (uiop:native-namestring out))
                           command)
                   :output :string :error-output :output
                   :ignore-error-status t)))
      (values output
              (with-open-file (in out)
                (let ((*read-default-float-format* 'double-float))
                  (list :wall (read in) :user (read in) :system (read in)
                        :rss-kb (read in) :exit (read in))))))))

(defun lisp-command (spec)
  "A fresh SBCL that loads the benchmark and runs SPEC, a plist of
RUN-ORDER's arguments with its :ENGINE."
  (flet ((push-form (system)
           (format nil "(push ~s asdf:*central-registry*)"
                   (namestring (asdf:system-source-directory system)))))
    (list "sbcl" "--noinform" "--non-interactive"
          "--load" (uiop:native-namestring
                    (merge-pathnames "setup.lisp"
                                     (symbol-value
                                      (find-symbol "*QUICKLISP-HOME*"
                                                   "QL"))))
          "--eval" (push-form "vivace-cabinet")
          "--eval" (push-form "cl-kyoto-cabinet")
          "--eval" "(asdf:load-system :vivace-cabinet/bench)"
          "--eval" (with-standard-io-syntax
                     (format nil "(vivace-cabinet-bench::child '~s)" spec)))))

(defun child (spec)
  "In a benchmark child: run SPEC and print RUN-ORDER's plist on a line
of its own."
  (let ((r (apply #'run-order (getf spec :engine)
                  :dir (uiop:ensure-directory-pathname (getf spec :dir))
                  (alexandria:remove-from-plist spec :engine :dir))))
    (with-standard-io-syntax
      (let ((*read-default-float-format* 'double-float))
        (format t "~&RESULT ~s~%" r)))
    (finish-output)))

(defun read-result (output)
  "The plist a child printed in OUTPUT, or NIL."
  (let ((line (find-if (lambda (l) (uiop:string-prefix-p "RESULT " l))
                       (uiop:split-string output
                                          :separator '(#\Newline)))))
    (and line
         (with-standard-io-syntax
           (let ((*read-default-float-format* 'double-float))
             (read-from-string (subseq line 7)))))))

(defun du-kb (path)
  "Kilobytes PATH takes on disk, as du counts them."
  (let ((out (command-output "du" "-sk" (uiop:native-namestring path))))
    (and out (parse-integer out :junk-allowed t))))

(defun run-one (engine &key (n 1000000) (threads 1) random tuned (seed 1)
                            dir log set-only)
  "One run of ENGINE in its own process on a new database in DIR: the
phases' seconds and :COUNT, :LEFT and :ERRORS as RUN-ORDER gives them,
:CPU seconds (the child's own count over the phases for a Lisp engine;
the whole process for Kyoto's programs), :RSS-KB at the process's peak,
:SIZE-KB of the database after it closed, and :EXIT.  SET-ONLY runs
the set phase alone: closing then writes every record, so :SIZE-KB is
the size holding them (after a full run, Kyoto's TreeDB writes its
emptied pages only at close).  A failed child's output goes to LOG."
  (prepare-directory dir)
  (unwind-protect
       (multiple-value-bind (output m)
           (if (native-p engine)
               (measured (native-command engine dir n threads random tuned
                                         set-only)
                         :environment (list (format nil "KCRNDSEED=~d"
                                                    seed)))
               (measured (lisp-command
                          (list* :engine engine :n n :threads threads
                                 :random random :tuned tuned :seed seed
                                 :dir (namestring dir)
                                 (and set-only (list :phases '(:set)))))))
         (let ((r (if (native-p engine)
                      (parse-native-output output)
                      (read-result output))))
           (when (and log (or (null r) (/= 0 (getf m :exit))))
             (with-open-file (s log :direction :output :if-exists :append
                                    :if-does-not-exist :create)
               (format s "~&== ~s~%~a~%" (list engine n threads random
                                               tuned seed)
                       output)))
           (append (list :cpu (if (native-p engine)
                                  (+ (getf m :user) (getf m :system))
                                  (getf r :cpu))
                         :rss-kb (getf m :rss-kb)
                         :size-kb (du-kb (engine-path engine dir))
                         :exit (getf m :exit))
                   (alexandria:remove-from-plist r :cpu))))
    (uiop:delete-directory-tree dir :validate t
                                    :if-does-not-exist :ignore)))
```

In `vivace-cabinet.asd`, in `vivace-cabinet/bench`, add `(:file
"native")` and `(:file "runner")` after `(:file "workload")`.

- [ ] **Step 4: Run the suite**

Run: `VC-BENCH-TEST`
Expected: exit 0 with no failures (42 checks); `grep -a -i undefined` on the
log finds nothing.

- [ ] **Step 5: Mutation checks**

1. In `bench/workload.lisp`, replace

   ```lisp
       (2 (db-remove db k) nil)
   ```

   with

   ```lisp
       (2 nil)
   ```

   run `VC-BENCH-ONE port-matches-kyotos-own-test`; confirm it fails as a
   test failure; restore the file.
2. In `bench/native.lisp`, replace

   ```lisp
                    (:remove (setf (getf result :left)
   ```

   with

   ```lisp
                    (:get (setf (getf result :left)
   ```

   run `VC-BENCH-ONE native-output-is-read`; confirm it fails as a test
   failure; restore the file.
3. In `bench/runner.lisp`, replace

   ```lisp
                            :rss-kb (getf m :rss-kb)
   ```

   with

   ```lisp
                            :rss-kb nil
   ```

   run `VC-BENCH-ONE runs-in-their-own-processes`; confirm it fails as a
   test failure; restore the file.
4. In `bench/native.lisp`, replace

   ```lisp
                   (princ-to-string (max 1 (floor n threads))))))
   ```

   with

   ```lisp
                   (princ-to-string n))))
   ```

   run `VC-BENCH-ONE runs-in-their-own-processes`; confirm it fails as a
   test failure; restore the file.

- [ ] **Step 6: Commit**

```bash
git add bench/native.lisp \
  bench/runner.lisp \
  bench/measure.py \
  bench/tests.lisp \
  vivace-cabinet.asd
git commit -m "Benchmark: each run in its own process, and Kyoto's own programs

A Lisp child per run, or kchashtest/kctreetest read from their output;
measure.py reads CPU and peak memory with wait4. With one thread and one
seed, the port ends each phase with Kyoto's own records. Part of #3.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 3: The matrix, the report and `bench/run.sh`

**Files:**
- Create: `bench/matrix.lisp`, `bench/report.lisp`, `bench/main.lisp`,
  `bench/run.sh`, `docs/benchmarks/README.md`
- Modify: `bench/tests.lisp`, `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: Task 2's `run-one`, `command-output`, `du-kb`; Task 1's
  `tunable-p`, `*engines*`.
- Produces: `*columns*`, `*size-columns*`; `(write-header stream
  columns)`, `(write-row stream row columns)`; `(environment data)`,
  `(write-environment path data)`; `(configurations engines ns orders
  tunings)`; `(run-matrix &key engines ns threads orders tunings
  repeats data out seed)` → OUT; `(read-runs csv)`; `(write-report out
  &key csv size-csv env report title)` → REPORT; `(main &key quick out
  data repeats ns threads engines)`.

- [ ] **Step 1: Write the failing tests**

Append to `bench/tests.lisp`:

```lisp
(fiveam:test report-takes-medians
  "Each cell: the median of the runs, the slowest and fastest beside
it; a failed run is left out and said so."
  (with-scratch (dir)
    (with-open-file (s (merge-pathnames "runs.csv" dir) :direction :output)
      (write-header s *columns*)
      (loop for (engine set exit) in '((:hash 1 0) (:hash 2 0) (:hash 5 0)
                                       (:bplus-tree 1 0) (:bplus-tree 1 1))
            for repeat from 1
            do (write-row s (list :machine "m" :engine engine
                                  :tuning :default :order :sequential
                                  :n 1000000 :threads 1 :repeat repeat
                                  :open 0.5 :set set :get 1 :remove 1
                                  :close 0.5 :cpu 3 :rss-kb 2048
                                  :count 1000000 :left 0 :errors 0
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
      (fiveam:is (search "1 of 2 runs failed" text) "~a" text))))

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
```

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-BENCH-TEST`
Expected: non-zero exit; `report-takes-medians` fails on the unbound
`*COLUMNS*` and `matrix-writes-a-row-per-run` with `UNDEFINED-FUNCTION`
`RUN-MATRIX`; the other tests pass.

- [ ] **Step 3: Write the matrix, the report and the entry point**

Create `bench/matrix.lisp`:

```lisp
;;;; The matrix of runs, written as CSV with the environment beside it
;;;; (spec: Recorded per run, Output).

(in-package #:vivace-cabinet-bench)

(defparameter *columns*
  '(:machine :started :engine :tuning :order :n :threads :repeat :seed
    :open :set :get :remove :close :cpu :rss-kb :count :left :errors
    :exit)
  "runs.csv's columns, in order: one row per run.")

(defparameter *size-columns*
  '(:engine :tuning :order :n :size-kb :count :exit)
  "sizes.csv's columns: one row per configuration's set-only run.")

(defun csv-cell (x)
  (typecase x
    (null "")
    (keyword (string-downcase (symbol-name x)))
    (float (format nil "~,6f" x))
    (ratio (format nil "~,6f" (float x 1d0)))
    (t (princ-to-string x))))

(defun write-header (stream columns)
  (format stream "~{~a~^,~}~%"
          (mapcar (lambda (c) (substitute #\_ #\- (csv-cell c))) columns)))

(defun write-row (stream row columns)
  (format stream "~{~a~^,~}~%"
          (mapcar (lambda (c) (csv-cell (getf row c))) columns))
  (finish-output stream))

(defun timestamp ()
  (multiple-value-bind (s mi h d mo y) (decode-universal-time
                                        (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            y mo d h mi s)))

(defun provenance-commit ()
  "The vivace-graph commit the copied code comes from, as
docs/provenance.md names it."
  (let* ((text (uiop:read-file-string
                (asdf:system-relative-pathname :vivace-cabinet
                                               "docs/provenance.md")))
         (i (search "at commit" text))
         (a (and i (position #\` text :start i)))
         (b (and a (position #\` text :start (1+ a)))))
    (and b (subseq text (1+ a) b))))

(defun environment (data)
  "The environment the runs ran in (spec: Recorded per run), as
(name . value) pairs."
  (let ((repo (uiop:native-namestring
               (asdf:system-source-directory :vivace-cabinet)))
        (cpuinfo (uiop:read-file-lines "/proc/cpuinfo"))
        (meminfo (uiop:read-file-lines "/proc/meminfo")))
    (flet ((field (lines name)
             (let ((l (find-if (lambda (l) (uiop:string-prefix-p name l))
                               lines)))
               (and l (string-trim '(#\Space #\Tab)
                                   (subseq l (1+ (position #\: l))))))))
      `(("machine" . ,(machine-instance))
        ("cpu" . ,(field cpuinfo "model name"))
        ("cores" . ,(command-output "nproc"))
        ("memory" . ,(field meminfo "MemTotal"))
        ("disks" . ,(format nil "~{~a~^; ~}"
                            (mapcar (lambda (l)
                                      (format nil "~{~a~^ ~}"
                                              (uiop:split-string
                                               l :separator " ")))
                                    (uiop:split-string
                                     (or (command-output
                                          "lsblk" "-dno"
                                          "NAME,MODEL,ROTA,SIZE")
                                         "")
                                     :separator '(#\Newline)))))
        ("data directory" . ,(uiop:native-namestring data))
        ("data filesystem" . ,(command-output
                               "findmnt" "-no" "SOURCE,FSTYPE,OPTIONS" "-T"
                               (uiop:native-namestring data)))
        ("kernel" . ,(command-output "uname" "-sr"))
        ("sbcl" . ,(lisp-implementation-version))
        ("kyoto cabinet" . ,(first (uiop:split-string
                                    (or (command-output "kcutilmgr"
                                                        "version")
                                        "")
                                    :separator '(#\Newline))))
        ("vivace-cabinet" . ,(format nil "~a~:[~; (uncommitted changes)~]"
                                     (or (command-output "git" "-C" repo
                                                         "rev-parse" "HEAD")
                                         "unknown")
                                     (plusp (length
                                             (command-output
                                              "git" "-C" repo "status"
                                              "--porcelain" "--"
                                              "." ":!bench/results")))))
        ("vivace-graph source" . ,(provenance-commit))
        ("started" . ,(timestamp))))))

(defun write-environment (path data)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (loop for (k . v) in (environment data)
          do (format s "~a: ~a~%" k (or v "")))))

(defun default-data-directory ()
  #p"/var/tmp/vc-bench/")

(defun configurations (engines ns orders tunings)
  "Each (engine n order tuning) the matrix runs: an engine without a
tuning knob on defaults only."
  (loop for n in ns
        nconc (loop for order in orders
                    nconc (loop for tuning in tunings
                                nconc (loop for engine in engines
                                            when (or (eq tuning :default)
                                                     (tunable-p engine))
                                              collect (list engine n order
                                                            tuning))))))

(defun run-matrix (&key (engines *engines*) (ns '(1000000 10000000))
                        (threads '(1 4 8)) (orders '(:sequential :random))
                        (tunings '(:default :tuned)) (repeats 5)
                        (data (default-data-directory)) out (seed 1))
  "Run every configuration on each of THREADS, REPEATS times, into
OUT/runs.csv, a row per run as it ends; first, one set-only run per
configuration into OUT/sizes.csv.  OUT/env.txt records the
environment, and OUT/failures.log the output of any run that failed.
Repeats are outermost, so each configuration's runs spread over the
session.  Returns OUT."
  (let* ((out (uiop:ensure-directory-pathname out))
         (dir (merge-pathnames "run/"
                               (uiop:ensure-directory-pathname data)))
         (log (merge-pathnames "failures.log" out))
         (configs (configurations engines ns orders tunings)))
    (ensure-directories-exist out)
    (ensure-directories-exist dir)
    (write-environment (merge-pathnames "env.txt" out) data)
    (with-open-file (s (merge-pathnames "sizes.csv" out)
                       :direction :output :if-exists :supersede)
      (write-header s *size-columns*)
      (loop for (engine n order tuning) in configs
            do (write-row s (list* :engine engine :tuning tuning
                                   :order order :n n
                                   (run-one engine :n n
                                                   :random (eq order :random)
                                                   :tuned (eq tuning :tuned)
                                                   :seed seed :dir dir
                                                   :log log :set-only t))
                          *size-columns*)))
    (with-open-file (s (merge-pathnames "runs.csv" out)
                       :direction :output :if-exists :supersede)
      (write-header s *columns*)
      (dotimes (repeat repeats out)
        (loop for (engine n order tuning) in configs
              do (dolist (th threads)
                   (let ((run-seed (+ seed repeat)))
                     (write-row
                      s (list* :machine (machine-instance)
                               :started (timestamp)
                               :engine engine :tuning tuning :order order
                               :n n :threads th :repeat (1+ repeat)
                               :seed run-seed
                               (run-one engine :n n :threads th
                                               :random (eq order :random)
                                               :tuned (eq tuning :tuned)
                                               :seed run-seed :dir dir
                                               :log log))
                      *columns*))))))))
```

Create `bench/report.lisp`:

```lisp
;;;; The report (spec: Output): runs.csv and env.txt as markdown, the
;;;; median of each configuration's runs with the slowest and fastest.

(in-package #:vivace-cabinet-bench)

(defparameter *engine-names*
  '((:kyoto-hash-native . "Kyoto HashDB, kchashtest")
    (:kyoto-tree-native . "Kyoto TreeDB, kctreetest")
    (:kyoto-hash . "Kyoto HashDB, from Lisp")
    (:kyoto-tree . "Kyoto TreeDB, from Lisp")
    (:hash . "vivace-cabinet HashDB")
    (:bplus-tree . "vivace-cabinet TreeDB, B+ tree")
    (:skip-list . "vivace-cabinet TreeDB, skip list")))

(defun parse-cell (s)
  "A CSV cell: a number, a keyword for a word, or NIL when empty."
  (cond ((string= s "") nil)
        ((every (lambda (c) (or (digit-char-p c) (find c "+-.eEdD"))) s)
         (let ((*read-default-float-format* 'double-float))
           (with-standard-io-syntax
             (let ((*read-default-float-format* 'double-float))
               (read-from-string s)))))
        ((every (lambda (c) (or (alphanumericp c) (char= c #\-))) s)
         (intern (string-upcase s) :keyword))
        (t s)))

(defun read-runs (csv)
  "The rows of CSV, each a plist keyed by its column."
  (let* ((lines (remove "" (uiop:read-file-lines csv) :test #'string=))
         (columns (mapcar (lambda (h)
                            (intern (string-upcase (substitute #\- #\_ h))
                                    :keyword))
                          (uiop:split-string (first lines)
                                             :separator '(#\,)))))
    (loop for line in (rest lines)
          collect (loop for c in columns
                        for cell in (uiop:split-string line
                                                       :separator '(#\,))
                        nconc (list c (parse-cell cell))))))

(defun read-environment (path)
  (loop for line in (uiop:read-file-lines path)
        for i = (position #\: line)
        when i
          collect (cons (subseq line 0 i)
                        (string-trim " " (subseq line (1+ i))))))

(defun median (xs)
  (let* ((v (sort (coerce xs 'vector) #'<))
         (n (length v)))
    (if (oddp n)
        (aref v (floor n 2))
        (/ (+ (aref v (1- (floor n 2))) (aref v (floor n 2))) 2))))

(defun good-p (run)
  "Whether RUN finished with every phase timed and nothing failing."
  (and (eql 0 (getf run :exit)) (eql 0 (getf run :errors))
       (every (lambda (p) (numberp (getf run p)))
              '(:open :set :get :remove :close))))

(defun rate-cell (runs phase)
  "Thousands of records per second in PHASE: the median, then the
slowest and fastest run in brackets."
  (let ((rates (loop for r in runs
                     collect (/ (getf r :n) (max 1d-9 (getf r phase))
                                1000))))
    (flet ((k (x) (if (>= x 100)
                      (format nil "~:d" (round x))
                      (format nil "~,1f" x))))
      (if (= 1 (length rates))
          (k (first rates))
          (format nil "~a (~a–~a)" (k (median rates))
                  (k (reduce #'min rates)) (k (reduce #'max rates)))))))

(defun median-cell (runs key &key (scale 1) (digits 1))
  (let ((xs (remove nil (mapcar (lambda (r) (getf r key)) runs))))
    (cond ((null xs) "")
          ((zerop digits) (format nil "~:d" (round (median xs) scale)))
          (t (format nil "~,vf" digits (/ (median xs) scale))))))

(defun section-title (n order tuning)
  (format nil "~:d records, ~(~a~) order, ~a" n order
          (if (eq tuning :tuned) "tuned" "default tuning")))

(defun size-cell (sizes engine n order tuning)
  "Megabytes ENGINE's database takes holding N records, from its
set-only run in SIZES."
  (let ((row (find-if (lambda (r) (and (eq engine (getf r :engine))
                                       (eql n (getf r :n))
                                       (eq order (getf r :order))
                                       (eq tuning (getf r :tuning))
                                       (eql 0 (getf r :exit))))
                      sizes)))
    (if (and row (getf row :size-kb))
        (format nil "~,1f" (/ (getf row :size-kb) 1024))
        "")))

(defun write-section (s runs sizes n order tuning)
  (format s "~&### ~a~%~%" (section-title n order tuning))
  (format s "| Engine | Threads | Set | Get | Remove | Open + close (s) ~
| CPU (s) | Peak RSS (MB) | Size (MB) |~%")
  (format s "|---|---:|---:|---:|---:|---:|---:|---:|---:|~%")
  (dolist (engine (mapcar #'car *engine-names*))
    (dolist (th (sort (remove-duplicates
                       (mapcar (lambda (r) (getf r :threads)) runs))
                      #'<))
      (let* ((all (remove-if-not
                   (lambda (r) (and (eq engine (getf r :engine))
                                    (eql th (getf r :threads))))
                   runs))
             (good (remove-if-not #'good-p all)))
        (when all
          (format s "| ~a | ~d | ~a | ~a | ~a | ~a | ~a | ~a | ~a |~%"
                  (cdr (assoc engine *engine-names*)) th
                  (if good (rate-cell good :set) "")
                  (if good (rate-cell good :get) "")
                  (if good (rate-cell good :remove) "")
                  (if good
                      (format nil "~,2f"
                              (median (mapcar (lambda (r)
                                                (+ (getf r :open)
                                                   (getf r :close)))
                                              good)))
                      "")
                  (median-cell good :cpu)
                  (median-cell good :rss-kb :scale 1024 :digits 0)
                  (size-cell sizes engine n order tuning))
          (when (/= (length good) (length all))
            (format s "| ↳ ~d of ~d runs failed and are left out | | | | ~
| | | | |~%"
                    (- (length all) (length good)) (length all))))))))

(defun write-report (out &key (csv (merge-pathnames "runs.csv" out))
                              (size-csv (merge-pathnames "sizes.csv" out))
                              (env (merge-pathnames "env.txt" out))
                              (report (merge-pathnames "report.md" out))
                              (title "Benchmark round 1"))
  "Write REPORT, markdown made from CSV, SIZE-CSV and ENV.  Returns
REPORT."
  (let* ((runs (read-runs csv))
         (sizes (and (probe-file size-csv) (read-runs size-csv)))
         (environment (read-environment env))
         (cores (ignore-errors
                 (parse-integer (cdr (assoc "cores" environment
                                            :test #'string=)))))
         (repeats (reduce #'max runs :key (lambda (r) (getf r :repeat))
                                     :initial-value 0)))
    (with-open-file (s report :direction :output :if-exists :supersede)
      (format s "# ~a~%~%" title)
      (format s "Kyoto Cabinet's order test (set, get, remove) on Kyoto ~
Cabinet and vivace-cabinet, as `bench/run.sh` ran it on ~a. The raw ~
results are in `~a`. What each engine and column is: ~
`docs/benchmarks/README.md`.~%~%"
              (cdr (assoc "machine" environment :test #'string=))
              (enough-namestring csv (asdf:system-source-directory
                                      :vivace-cabinet)))
      (format s "## Environment~%~%| | |~%|---|---|~%")
      (loop for (k . v) in environment
            do (format s "| ~a | ~a |~%" k v))
      (format s "~%## Results~%~%Set, get and remove are thousands of ~
records per second: the median of ~d runs, with the slowest and ~
fastest in brackets. Open + close, CPU and peak RSS are medians; size ~
is the database holding all its records, from one set-only run. ~
vivace-cabinet's TreeDB has no tuning knob, so it runs on defaults ~
only.~%" repeats)
      (when (and cores (some (lambda (r) (> (getf r :threads) cores)) runs))
        (format s "~%Runs with more threads than the machine's ~d ~
hardware threads oversubscribe it.~%" cores))
      (dolist (n (sort (remove-duplicates (mapcar (lambda (r) (getf r :n))
                                                  runs))
                       #'<))
        (dolist (order '(:sequential :random))
          (dolist (tuning '(:default :tuned))
            (let ((section (remove-if-not
                            (lambda (r) (and (eql n (getf r :n))
                                             (eq order (getf r :order))
                                             (eq tuning (getf r :tuning))))
                            runs)))
              (when section
                (terpri s)
                (write-section s section sizes n order tuning)))))))
    report))
```

Create `bench/main.lisp`:

```lisp
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
```

Create `bench/run.sh` and make it executable (`chmod +x`):

```bash
#!/bin/bash
# bench/run.sh [--quick] [--out DIR] [--data DIR] [--repeats N]
#              [--n "N ..."] [--threads "T ..."] [--engines "E ..."]
# Run benchmark round 1 and write its report: docs/benchmarks/README.md.
# Needs SBCL with Quicklisp, Kyoto Cabinet 1.2.80, python3, and
# cl-kyoto-cabinet in $CL_KYOTO_CABINET (default ~/work/cl-kyoto-cabinet).
set -euo pipefail
cd "$(dirname "$0")/.."
args=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) args="$args :quick t" ;;
    --out) args="$args :out \"$2\""; shift ;;
    --data) args="$args :data \"$2\""; shift ;;
    --repeats) args="$args :repeats $2"; shift ;;
    --n) args="$args :ns '($2)"; shift ;;
    --threads) args="$args :threads '($2)"; shift ;;
    --engines) args="$args :engines '($(echo "$2" | sed -E 's/([a-z-]+)/:\1/g'))"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
kc="${CL_KYOTO_CABINET:-$HOME/work/cl-kyoto-cabinet}"
exec sbcl --noinform --non-interactive \
  --load "$HOME/quicklisp/setup.lisp" \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval "(push (truename \"$kc/\") asdf:*central-registry*)" \
  --eval '(asdf:load-system :vivace-cabinet/bench)' \
  --eval "(vivace-cabinet-bench:main $args)"
```

In `vivace-cabinet.asd`, in `vivace-cabinet/bench`, add `(:file
"matrix")`, `(:file "report")` and `(:file "main")` after `(:file
"runner")`.

- [ ] **Step 4: Run the suites and the quick matrix**

Run: `VC-BENCH-TEST`
Expected: exit 0 with no failures (49 checks); `grep -a -i undefined` on the
log finds nothing.

Run: `VC-SUITE`, then `VC-CONFORM`
Expected: both exit 0 (core 12,920 checks, conformance 25).

Run: `bench/run.sh --quick --out /var/tmp/vc-bench-quick`
Expected: it prints the paths of `runs.csv` and `report.md`;
`runs.csv` has 97 lines (a header and 96 runs), `sizes.csv` 25, and
`report.md` a table for each order and tuning at 2,000 records.

- [ ] **Step 5: Mutation checks**

1. In `bench/report.lisp`, replace

   ```lisp
             (format nil "~a (~a–~a)" (k (median rates))
   ```

   with

   ```lisp
             (format nil "~a (~a–~a)" (k (reduce #'max rates))
   ```

   run `VC-BENCH-ONE report-takes-medians`; confirm it fails as a test
   failure; restore the file.
2. In `bench/report.lisp`, replace

   ```lisp
     (and (eql 0 (getf run :exit)) (eql 0 (getf run :errors))
   ```

   with

   ```lisp
     (and (eql 0 (getf run :errors))
   ```

   run `VC-BENCH-ONE report-takes-medians`; confirm it fails as a test
   failure; restore the file.
3. In `bench/matrix.lisp`, replace

   ```lisp
                                               when (or (eq tuning :default)
                                                        (tunable-p engine))
   ```

   with

   ```lisp
                                               when t
   ```

   run `VC-BENCH-ONE matrix-writes-a-row-per-run`; confirm it fails as a
   test failure; restore the file.

- [ ] **Step 6: Document it**

Create `docs/benchmarks/README.md`:

```markdown
# Benchmarks

`bench/run.sh` runs benchmark round 1 (spec: unit 3) and writes its
report.

## Running it

    bench/run.sh --quick   # a small matrix, to check the harness
    bench/run.sh           # the spec's matrix: results in bench/results/,
                           # the report in docs/benchmarks/round-1.md

Options:

- `--n "1000000"`, `--threads "1 4"`, `--repeats 3` and
  `--engines "hash kyoto-hash-native"` narrow the matrix.
- `--data DIR` is where the databases go. The default is
  `/var/tmp/vc-bench/`, which must be on a real disk, not tmpfs.
- `--out DIR` is where the results go.

It needs SBCL with Quicklisp, and Kyoto Cabinet 1.2.80's library and its
`kchashtest`, `kctreetest` and `kcutilmgr`. It also needs python3, and
cl-kyoto-cabinet in `$CL_KYOTO_CABINET` (default
`~/work/cl-kyoto-cabinet`). `vivace-cabinet/bench-test` tests the
harness at small sizes.

## The workload

The harness runs Kyoto Cabinet's order test, as `kchashtest order` and
`kctreetest order` run it (the spec's Workload section has the details):

- an open, then three timed phases (set, get and remove), then a close;
- keys are 8-digit decimals, and each value equals its key;
- with `-rnd`, keys are drawn at random, and every eighth record adds a
  random extra operation.

`bench/workload.lisp` repeats this through vivace-cabinet's generic
functions, so one workload runs on Kyoto from Lisp and on
vivace-cabinet's engines.

The port is faithful: with one thread and one seed, every engine ends
each phase with the same records as Kyoto's own program
(`port-matches-kyotos-own-test`). One difference: Kyoto's test shares
one random generator among its threads, while the port gives each
thread its own, seeded as Kyoto seeds its own.

## Engines

| Name | What runs |
|---|---|
| `kyoto-hash-native` | Kyoto's `kchashtest order` |
| `kyoto-tree-native` | Kyoto's `kctreetest order` |
| `kyoto-hash` | Kyoto's HashDB from Lisp, through `vivace-cabinet/kyoto` |
| `kyoto-tree` | Kyoto's TreeDB from Lisp, through `vivace-cabinet/kyoto` |
| `hash` | vivace-cabinet's HashDB |
| `bplus-tree` | vivace-cabinet's TreeDB on the B+ tree |
| `skip-list` | vivace-cabinet's TreeDB on the skip list |

## Each run

- **A fresh process and a fresh database.** Each run starts in its own
  process, on a new database in a new directory under `--data`. On
  btrfs that directory is made `chattr +C`, so its files are neither
  copied on write nor compressed, as database files usually are there.
- **Threads share the records.** N records over T threads is T threads
  of N/T records each.
- **Two tunings.** Every engine runs on its defaults, and tuned for N:
  - Kyoto's bucket count as its documentation advises: twice N for
    HashDB, a tenth of N for TreeDB;
  - vivace-cabinet's HashDB with `:buckets` N/8, because a bucket holds
    24 entries and splits when one overflows.

  vivace-cabinet's TreeDB has no bucket count, so it runs on defaults
  only.
- **Fixed seeds.** Repeat r of every configuration uses seed r; Kyoto's
  programs take it as `KCRNDSEED`.
- **Repeats are outermost**, so each configuration's runs spread over
  the session.

## What is recorded

`runs.csv` has one row per run:

- **Phase times** are wall seconds from the engine's own clock: Kyoto's
  programs print them in milliseconds, and the Lisp harness reads
  SBCL's real-time clock.
- **CPU** is, for a Lisp engine, the child's CPU from open to close,
  without loading Lisp. For Kyoto's programs it is the whole process's.
- **Peak RSS** is the whole process's, from `bench/measure.py`'s
  `wait4`. A Lisp process's includes SBCL's image, about 120 MB.
- **`count` and `left`** are the records after the set and remove
  phases.
- **`errors`** are unexpected failures, and **`exit`** is the process's
  exit status.

`sizes.csv` has one row per configuration: `du` of the database after a
set-only run, whose close writes every record. Kyoto's TreeDB writes its
pages only at close, so after a full run it would show the emptied
tree.

`env.txt` records the machine, CPU, memory, disks, data filesystem,
kernel, SBCL, Kyoto Cabinet, the vivace-cabinet commit and the
vivace-graph commit the code was copied from. `failures.log` keeps the
output of any run that failed.

## The report

`docs/benchmarks/round-1.md` is generated from those files. Each
record count, order and tuning gets a table. The set, get and remove
columns are thousands of records per second: the median of the runs,
with the slowest and fastest in brackets. Failed runs are left out, and
the table says how many there were.
```

In `README.md`, before `## Limits`, add:

```markdown
## Benchmark

`bench/run.sh` runs Kyoto Cabinet's order test on Kyoto Cabinet (its
own programs, and from Lisp through `vivace-cabinet/kyoto`) and on
vivace-cabinet's three engines, and writes a report;
`docs/benchmarks/README.md` says how, and what each number means.
`bench/run.sh --quick` checks the harness in a few minutes.
```

- [ ] **Step 7: Commit**

```bash
git add bench/matrix.lisp \
  bench/report.lisp \
  bench/main.lisp \
  bench/run.sh \
  bench/tests.lisp \
  vivace-cabinet.asd \
  docs/benchmarks/README.md \
  README.md
git commit -m "Benchmark: the matrix, the report and bench/run.sh

runs.csv, sizes.csv and env.txt, and a markdown report of each
configuration's median with its slowest and fastest run. --quick
checks the harness in a few minutes. Part of #3.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

---

## Finish

- [ ] `VC-BENCH-TEST`, `VC-SUITE` and `VC-CONFORM` once more: all exit 0.
- [ ] On kraison/vivace-cabinet#3, comment `Ready for review:` with the
  branch and `git -C ~/work/vivace-cabinet diff main...unit-3b-benchmark-harness`.
- [ ] Stop: merge and push wait for Kevin's word.
