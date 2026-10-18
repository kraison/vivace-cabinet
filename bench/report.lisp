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
  "The rows of CSV, each a plist keyed by its column.  A row with too
few cells, cut short when a session was killed, is left out."
  (let* ((lines (remove "" (uiop:read-file-lines csv) :test #'string=))
         (columns (mapcar (lambda (h)
                            (intern (string-upcase (substitute #\- #\_ h))
                                    :keyword))
                          (uiop:split-string (first lines)
                                             :separator '(#\,)))))
    (loop for line in (rest lines)
          for cells = (uiop:split-string line :separator '(#\,))
          when (= (length cells) (length columns))
            collect (loop for c in columns
                          for cell in cells
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
