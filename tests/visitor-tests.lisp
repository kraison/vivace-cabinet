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
