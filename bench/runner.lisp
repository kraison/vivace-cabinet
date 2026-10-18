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
of its own; exit 1 if the run had errors, as Kyoto's programs do."
  (let ((r (apply #'run-order (getf spec :engine)
                  :dir (uiop:ensure-directory-pathname (getf spec :dir))
                  (alexandria:remove-from-plist spec :engine :dir))))
    (with-standard-io-syntax
      (let ((*read-default-float-format* 'double-float))
        (format t "~&RESULT ~s~%" r)))
    (finish-output)
    (uiop:quit (if (eql 0 (getf r :errors)) 0 1))))

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
                            dir log set-only phases)
  "One run of ENGINE in its own process on a new database in DIR: the
phases' seconds and :COUNT, :LEFT and :ERRORS as RUN-ORDER gives them,
:CPU seconds (the child's own count over the phases for a Lisp engine;
the whole process for Kyoto's programs), :RSS-KB at the process's peak,
:SIZE-KB of the database after it closed, and :EXIT.  SET-ONLY runs
the set phase alone: closing then writes every record, so :SIZE-KB is
the size holding them (after a full run, Kyoto's TreeDB writes its
emptied pages only at close).  PHASES chooses a Lisp child's phases.
A failed child's output goes to LOG."
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
                                 (cond (set-only (list :phases '(:set)))
                                       (phases (list :phases phases)))))))
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
