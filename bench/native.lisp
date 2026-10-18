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

(defparameter *kyoto-programs*
  '((:kyoto-hash-native . "kchashtest") (:kyoto-tree-native . "kctreetest"))
  "The program each native engine runs.")

(defun native-command (engine dir n threads random tuned &optional set-only)
  "Kyoto's order test command for ENGINE: N records over THREADS, each
of which Kyoto runs N/THREADS records; with SET-ONLY, its set phase."
  (append (list (cdr (assoc engine *kyoto-programs*)) "order")
          (and set-only (list "-set"))
          (and (> threads 1) (list "-th" (princ-to-string threads)))
          (and random (list "-rnd"))
          (and tuned
               (list "-bnum" (princ-to-string (bucket-tuning engine n))))
          (list (uiop:native-namestring (engine-path engine dir))
                (princ-to-string (max 1 (floor n threads))))))
