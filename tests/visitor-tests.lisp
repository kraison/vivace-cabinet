(in-package #:vivace-cabinet-test)

(defun answer (value)
  "A visitor that ignores its arguments and answers VALUE."
  (lambda (k v)
    (declare (ignore k v))
    value))

(def-db-test accept-applies-the-visitors-answer
  "NIL and :NOP keep a record, :REMOVE removes it, anything else is the
new value; an absent key's value is NIL."
  (with-temp-db (db)
    (db-set db "a" "1")
    (db-set db "b" "2")
    (let ((seen '()))
      (is-true (db-accept db "a" (lambda (k v) (push (list k v) seen) :nop)
                          :as :string))
      (is (equal '(("a" "1")) seen)))
    (is-true (db-accept db "a" (lambda (k v)
                                 (declare (ignore k))
                                 (concatenate 'string v "!"))
                        :as :string))
    (is (equal "1!" (db-get db "a" :as :string)))
    (is-true (db-accept db "b" (answer :remove)))
    (is (null (db-get db "b")))
    (is-true (db-accept db "c" (lambda (k v)
                                 (declare (ignore k))
                                 (if v :nop "new"))))
    (is (equal "new" (db-get db "c" :as :string)))
    (is-true (db-accept db "absent" (answer :remove)))
    (is-true (db-accept db "d" (answer nil)))
    (is (null (db-get db "d")))
    (is (= 2 (db-count db)))))

(def-db-test read-only-visits-change-nothing
  (with-temp-db (db)
    (db-set db "a" "1")
    (is-true (db-accept db "a" (answer :remove) :writable nil))
    (is-true (db-accept db "z" (answer "new") :writable nil))
    (is (equal "1" (db-get db "a" :as :string)))
    (is (null (db-get db "z")))))

(def-db-test visitors-on-a-reader
  "A reader refuses writable visits and allows read-only ones."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "v.vc/" dir)))
      (with-test-db (db path)
        (db-set db "k" "v"))
      (with-test-db (db path :mode '(:reader))
        (is (null (db-accept db "k" (answer :remove))))
        (is (eq :no-permission (db-error db)))
        (is (null (db-accept-bulk db '("k") (answer :remove))))
        (let ((got nil))
          (is-true (db-accept db "k" (lambda (k v)
                                       (declare (ignore k))
                                       (setf got v)
                                       :nop)
                              :writable nil :as :string))
          (is (equal "v" got)))))))

(def-db-test accept-bulk-visits-every-key-in-order
  (with-temp-db (db)
    (dolist (k '("a" "b" "c"))
      (db-set db k k))
    (let ((seen '()))
      (is-true (db-accept-bulk db '("c" "a" "zz" "b")
                               (lambda (k v)
                                 (push (cons k v) seen)
                                 (cond ((equal k "a") :remove)
                                       (v :nop)
                                       (t "new")))
                               :as :string))
      (is (equal '(("c" . "c") ("a" . "a") ("zz") ("b" . "b"))
                 (reverse seen)))
      (is (null (db-get db "a")))
      (is (equal "new" (db-get db "zz" :as :string))))))

(def-db-test bulk-visits-do-not-deadlock
  "Four threads visit 200 keys each, two in each order, 50 times over:
all finish, none signals, and every visit landed."
  (with-temp-db (db)
    (let ((keys (loop for i below 200 collect (keyed i)))
          (lock (bt:make-lock))
          (errors '()))
      (flet ((visit-all (ks)
               (handler-case
                   (dotimes (j 50)
                     (db-accept-bulk db ks
                                     (lambda (k v)
                                       (declare (ignore k))
                                       (concatenate 'string v "x"))
                                     :as :string))
                 (error (c)
                   (bt:with-lock-held (lock)
                     (push (princ-to-string c) errors))))))
        (let ((threads
                (loop for n below 4
                      collect (let ((ks (if (evenp n) keys (reverse keys))))
                                (bt:make-thread
                                 (lambda () (visit-all ks)))))))
          (is-true (finish-within threads 120))
          (is (null errors) "~s" errors)
          (is (every (lambda (k)
                       (= 200 (length (db-get db k :as :string))))
                     keys)))))))

(def-db-test visitor-errors-leave-the-database-usable
  "An error in a visitor reaches the caller, changes nothing, and leaves
every lock released."
  (with-temp-db (db)
    (db-set db "a" "1")
    (flet ((boom (k v)
             (declare (ignore k v))
             (error "boom")))
      (signals simple-error (db-accept db "a" #'boom))
      (signals simple-error (db-accept-bulk db '("a" "b") #'boom)))
    (is (equal "1" (db-get db "a" :as :string)))
    (is-true (db-set db "a" "2"))
    (is (equal "2" (db-get db "a" :as :string)))))

(def-db-test iterate-visits-every-record-once
  (with-temp-db (db)
    (dotimes (i 300)
      (db-set db (keyed i) "v"))
    (let ((seen '()))
      (is-true (db-iterate db (lambda (k v)
                                (declare (ignore v))
                                (push k seen)
                                :nop)
                           :writable nil :as :string))
      (is (equal (loop for i below 300 collect (keyed i))
                 (sort seen #'string<))))
    (is-true (db-iterate db (lambda (k v)
                              (if (char= #\0 (char k 5))
                                  :remove
                                  (string-upcase v)))
                         :as :string))
    (is (= 270 (db-count db)))
    (is (equal "V" (db-get db (keyed 1) :as :string)))
    (is (null (db-get db (keyed 10))))))

(def-db-test iterate-holds-the-database
  "A write started during an iteration lands only after it."
  (with-temp-db (db)
    (dotimes (i 50)
      (db-set db (keyed i) "v"))
    (let ((writer nil)
          (last-visit 0)
          (written 0))
      (db-iterate db (lambda (k v)
                       (declare (ignore k v))
                       (unless writer
                         (setf writer
                               (bt:make-thread
                                (lambda ()
                                  (db-set db "late" "x")
                                  (setf written
                                        (get-internal-real-time)))))
                         (sleep 0.3))
                       (setf last-visit (get-internal-real-time))
                       :nop)
                  :writable nil)
      (bt:join-thread writer)
      (is (>= written last-visit))
      (is (equal "x" (db-get db "late" :as :string))))))

(def-db-test scan-parallel-visits-every-record-once
  "Four threads visit 2000 records; answers are ignored."
  (with-temp-db (db)
    (dotimes (i 2000)
      (db-set db (keyed i) (keyed i)))
    (let ((seen '())
          (lock (bt:make-lock)))
      (is-true (db-scan-parallel db (lambda (k v)
                                      (bt:with-lock-held (lock)
                                        (push (cons k v) seen))
                                      :remove)
                                 :threads 4 :as :string))
      (is (every (lambda (r) (equal (car r) (cdr r))) seen))
      (is (equal (loop for i below 2000 collect (keyed i))
                 (sort (mapcar #'car seen) #'string<)))
      (is (= 2000 (db-count db))))))

(def-db-test scan-parallel-passes-on-visitor-errors
  (with-temp-db (db)
    (dotimes (i 100)
      (db-set db (keyed i) "v"))
    (signals simple-error
      (db-scan-parallel db (lambda (k v)
                             (declare (ignore k v))
                             (error "boom"))))
    (signals invalid-argument (db-scan-parallel db (answer :nop) :threads 0))
    (is (= 100 (db-count db)))))

(def-db-test cursor-accept-visits-the-current-record
  (with-temp-db (db)
    (dotimes (i 10)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (let ((n 0))
        (loop while (cursor-accept cur (lambda (k v)
                                         (declare (ignore k))
                                         (incf n)
                                         (concatenate 'string v "!"))
                                   :step t :as :string))
        (is (= 10 n)))
      (is (every (lambda (i) (equal "v!" (db-get db (keyed i) :as :string)))
                 (loop for i below 10 collect i)))
      (cursor-jump cur)
      (loop while (cursor-accept cur (answer :remove)))
      (is (= 0 (db-count db)))
      (is (null (cursor-accept cur (answer :nop))))
      (is (eq :no-record (db-error db))))))

(def-db-test iterate-errors-leave-the-database-usable
  (with-temp-db (db)
    (dotimes (i 10)
      (db-set db (keyed i) "v"))
    (signals simple-error
      (db-iterate db (lambda (k v)
                       (declare (ignore k v))
                       (error "boom"))))
    (is-true (db-set db "after" "x"))
    (is (= 11 (db-count db)))))

(def-db-test scan-parallel-holds-the-database
  "A write started during a parallel scan lands only after it."
  (with-temp-db (db)
    (dotimes (i 50)
      (db-set db (keyed i) "v"))
    (let ((lock (bt:make-lock))
          (writer nil)
          (last-visit 0)
          (written 0))
      (db-scan-parallel
       db (lambda (k v)
            (declare (ignore k v))
            (bt:with-lock-held (lock)
              (unless writer
                (setf writer
                      (bt:make-thread
                       (lambda ()
                         (db-set db "late" "x")
                         (setf written (get-internal-real-time)))))))
            (sleep 0.01)
            (bt:with-lock-held (lock)
              (setf last-visit (get-internal-real-time)))
            :nop)
       :threads 2)
      (bt:join-thread writer)
      (is (>= written last-visit))
      (is (equal "x" (db-get db "late" :as :string))))))

(define-condition serious-trouble (serious-condition) ())

(def-db-test scan-parallel-passes-on-serious-conditions
  "A serious condition that is not an error, such as running out of
stack, reaches the caller too, and the database stays usable."
  (with-temp-db (db)
    (dotimes (i 100)
      (db-set db (keyed i) "v"))
    (signals serious-trouble
      (db-scan-parallel db (lambda (k v)
                             (declare (ignore k v))
                             (error 'serious-trouble))))
    (is-true (db-set db "after" "x"))))

(def-db-test cursor-edits-reach-a-record-after-removal
  "An edit through a cursor whose record another call removed acts on a
record that is still there."
  (with-temp-db (db)
    (dotimes (i 6)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur (keyed 1))
      (db-remove db (keyed 1))
      (is-true (cursor-set-value cur "x"))
      (is (= 1 (count "x" (loop for i below 6
                                collect (db-get db (keyed i) :as :string))
                      :test #'equal)))
      (is-true (cursor-remove cur))
      (is (= 4 (db-count db))))))

(def-db-test cursor-accept-never-visits-a-removed-record
  "While another thread sets and removes the same keys, CURSOR-ACCEPT
never calls its visitor with NIL: an answer for a removed record would
recreate it."
  (with-temp-db (db)
    (let ((stop nil)
          (nils 0)
          (errors '()))
      (let ((churn (bt:make-thread
                    (lambda ()
                      (handler-case
                          (loop for i from 0
                                until stop
                                do (let ((k (keyed (mod i 8))))
                                     (if (evenp (floor i 8))
                                         (db-set db k "v")
                                         (db-remove db k))))
                        (error (c)
                          (push (princ-to-string c) errors)))))))
        (unwind-protect
             (with-cursor (cur db)
               (dotimes (i 20000)
                 (when (cursor-jump cur (keyed (mod i 8)))
                   (cursor-accept cur (lambda (k v)
                                        (declare (ignore k))
                                        (unless v
                                          (incf nils))
                                        :nop)))))
          (setf stop t)
          (bt:join-thread churn))
        (is (null errors) "~s" errors)
        (is (zerop nils) "~d visits of NIL" nils)))))

(def-db-test cursor-is-nowhere-after-clear
  "DB-CLEAR leaves every cursor on no record, as in Kyoto, until it
jumps again."
  (with-temp-db (db)
    (db-set db (keyed 0) "v")
    (with-cursor (cur db)
      (cursor-jump cur)
      (db-clear db)
      (db-set db (keyed 0) "w")
      (is (null (cursor-get-key cur)))
      (is (eq :no-record (db-error db)))
      (is (null (cursor-step cur)))
      (is-true (cursor-jump cur))
      (is (equal "w" (cursor-get-value cur :as :string))))))

(def-db-test walks-see-every-untouched-record
  "While another thread removes and re-adds other records, a match, a
merge and a cursor walk that reads with :STEP see every record nothing
touches."
  (with-temp-directory (dir)
    (with-test-db (db (merge-pathnames "w.vc/" dir))
      (with-test-db (m (merge-pathnames "m.vc/" dir))
        (dotimes (i 400)
          (db-set db (keyed i) "v"))
        (let* ((stop nil)
               (errors '())
               (missed 0)
               (churn (bt:make-thread
                       (lambda ()
                         (handler-case
                             (loop for i from 1 by 2
                                   until stop
                                   do (let ((k (keyed (mod i 400))))
                                        (db-remove db k)
                                        (db-set db k "v")))
                           (error (c)
                             (push (princ-to-string c) errors)))))))
          (flet ((count-missed (keys)
                   (let ((seen (make-hash-table :test 'equal)))
                     (dolist (k keys)
                       (setf (gethash k seen) t))
                     (loop for i below 400 by 2
                           unless (gethash (keyed i) seen)
                             do (incf missed)))))
            (unwind-protect
                 (dotimes (round 60)
                   (count-missed (db-match-prefix db "" :as :string))
                   (count-missed
                    (with-cursor (c db)
                      (when (cursor-jump c)
                        (loop for k = (cursor-get-key c :as :string :step t)
                              while k
                              collect k))))
                   (when (zerop (mod round 10))
                     (db-clear m)
                     (db-merge m (list db))
                     (count-missed (db-match-prefix m "" :as :string))))
              (setf stop t)
              (bt:join-thread churn)))
          (is (null errors) "~s" errors)
          (is (zerop missed) "~d untouched records missed" missed))))))

(def-db-test read-only-cursor-accept-stays-put
  "A read-only CURSOR-ACCEPT whose visitor answers :REMOVE removes
nothing and leaves the cursor where it was."
  (with-temp-db (db)
    (db-set db "a" "v")
    (db-set db "b" "v")
    (with-cursor (cur db)
      (cursor-jump cur "a")
      (is-true (cursor-accept cur (answer :remove) :writable nil))
      (is (= 2 (db-count db)))
      (is (equal "a" (cursor-get-key cur :as :string))))))
