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
