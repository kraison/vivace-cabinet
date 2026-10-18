(in-package #:vivace-cabinet-test)

;;; Writers, readers and cursors together, under a watchdog: the
;;; skip-list engine once livelocked here (unit 2c's final review).

(defun stress-key (i)
  (format nil "k~4,'0d" i))

(defun stress-value-ok-p (key v)
  "True when V is a value the stress writers write under KEY: KEY, = and
v's, or v's alone (appended to an absent key)."
  (flet ((vs (s) (every (lambda (c) (char= c #\v)) s)))
    (or (vs v)
        (and (> (length v) (length key))
             (string= key v :end2 (length key))
             (char= #\= (char v (length key)))
             (vs (subseq v (1+ (length key))))))))

(defun stress-walk-ok-p (db forward)
  "Walk DB one way; true when a forward walk's keys come strictly in
order.  A backward walk's need not: as in Kyoto, a cursor whose record
another thread removes reads the next one."
  (with-cursor (cur db)
    (let ((prev nil)
          (ok t))
      (when (if forward (cursor-jump cur) (cursor-jump-back cur))
        (loop
          (let ((k (cursor-get-key cur :as :string)))
            (when (and k prev forward (string<= k prev))
              (setf ok nil))
            (when k
              (setf prev k)))
          (unless (if forward (cursor-step cur) (cursor-step-back cur))
            (return))))
      ok)))

(defun stress-writer (db w note)
  (let ((*random-state* (sb-ext:seed-random-state (+ 100 w))))
    (handler-case
        (dotimes (j 10000)
          (let* ((k (stress-key (random 2000)))
                 (v (format nil "~a=~a" k (make-string (random 100)
                                                       :initial-element #\v))))
            (case (random 5)
              ((0 1) (db-set db k v))
              (2 (db-replace db k v))
              (3 (db-remove db k))
              (4 (db-append db k "v")))))
      (error (c) (funcall note (princ-to-string c))))))

(defun stress-reader (db r note stop)
  (let ((*random-state* (sb-ext:seed-random-state (+ 200 r))))
    (handler-case
        (loop until (funcall stop)
              do (let* ((k (stress-key (random 2000)))
                        (v (db-get db k :as :string)))
                   (when (and v (not (stress-value-ok-p k v)))
                     (funcall note (list :bad-value k v)))))
      (error (c) (funcall note (princ-to-string c))))))

(defun stress-walker (db forward note stop)
  (handler-case
      (loop until (funcall stop)
            do (unless (stress-walk-ok-p db forward)
                 (funcall note (list :out-of-order forward))))
    (error (c) (funcall note (princ-to-string c)))))

(def-tree-test concurrent-writers-readers-and-cursors
  "Eight writers set, replace, remove and append over 2000 shared keys
while two readers and two cursors run.  Every value read belongs to its
key, cursors stay in order, and the writers finish within two minutes."
  (with-temp-db (db)
    (let* ((lock (bt:make-lock))
           (stop nil)
           (finished 0)
           (problems '())
           (note (lambda (p)
                   (bt:with-lock-held (lock) (push p problems))))
           (stopped (lambda () stop)))
      (dotimes (i 1000)
        (db-set db (stress-key i) (format nil "~a=v" (stress-key i))))
      (let ((writers
              (loop for w below 8
                    collect (let ((w w))
                              (bt:make-thread
                               (lambda ()
                                 (stress-writer db w note)
                                 (bt:with-lock-held (lock)
                                   (incf finished)))))))
            (others
              (append
               (loop for r below 2
                     collect (let ((r r))
                               (bt:make-thread
                                (lambda ()
                                  (stress-reader db r note stopped)))))
               (loop for forward in '(t nil)
                     collect (let ((forward forward))
                               (bt:make-thread
                                (lambda ()
                                  (stress-walker db forward note
                                                 stopped))))))))
        (loop repeat 240
              until (= finished 8)
              do (sleep 0.5))
        (setf stop t)
        (is (= 8 finished) "only ~a of 8 writers finished" finished)
        (dolist (th writers)
          (when (bt:thread-alive-p th)
            (bt:destroy-thread th)))
        (mapc #'bt:join-thread others)
        (is (null problems) "~s" problems)))))
