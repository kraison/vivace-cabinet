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
                         (:get (let ((v (db-get db k)))
                                 ;; Kyoto checks the value begins with K.
                                 (if v
                                     (and (>= (length v) (length k))
                                          (not (mismatch k v
                                                         :end2 (length k))))
                                     random)))
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
