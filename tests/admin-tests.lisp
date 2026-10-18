(in-package #:vivace-cabinet-test)

(def-suite admin-suite
  :description "Copying and merging that are not per kind."
  :in vivace-cabinet-suite)

(in-suite admin-suite)

(defun sorted-records (db)
  "DB's records as (key . value) strings, in key order."
  (let ((rs '()))
    (db-iterate db (lambda (k v) (push (cons k v) rs) :nop)
                :writable nil :as :string)
    (sort rs #'string< :key #'car)))

(def-db-test status-describes-the-database
  (with-temp-db (db)
    (db-set db "k" "v")
    (let ((s (db-status db)))
      (is (eq (getf *db-type-args* :type) (getf s :type)))
      (is (= 1 (getf s :count)))
      (is (= (db-size db) (getf s :size)))
      (is (equal (db-path db) (getf s :path)))
      (is (eq t (getf s :writable)))
      (is (null (getf s :autosync)))
      (if (eq :tree (getf s :type))
          (is (eq (getf *db-type-args* :engine) (getf s :engine)))
          (is (plusp (getf s :buckets)))))))

(def-db-test occupy-runs-with-the-database-held
  (with-temp-db (db)
    (db-set db "k" "v")
    (let ((args nil))
      (is-true (db-occupy db (lambda (path count size)
                               (setf args (list path count size))
                               t)))
      (is (equal (list (db-path db) 1 (db-size db)) args)))
    (is (null (db-occupy db (lambda (&rest r) (declare (ignore r)) nil)
                         :writable nil)))
    (is (eq :logic (db-error db)))))

(def-db-test copy-makes-a-database-of-its-own
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "o.vc/" dir))
          (copy (merge-pathnames "c.vc/" dir)))
      (with-test-db (db path)
        (dotimes (i 200)
          (db-set db (keyed i) (keyed i)))
        (is-true (db-copy db copy))
        (signals invalid-argument (db-copy db copy))
        (db-set db "after" "copy"))
      (with-db (c copy)
        (is (= 200 (db-count c)))
        (is (equal (keyed 7) (db-get c (keyed 7) :as :string)))
        (is (null (db-get c "after")))
        (is (eq (getf *db-type-args* :type) (getf (db-status c) :type)))))))

(test copy-keeps-holes
  "The index's 1000 MiB sparse files stay sparse in a copy."
  (with-temp-directory (dir)
    (let ((copy (merge-pathnames "c.vch/" dir)))
      (with-db (db (merge-pathnames "o.vch/" dir))
        (db-set db "k" "v")
        (db-copy db copy))
      (let ((kb (parse-integer
                 (uiop:run-program
                  (list "du" "-k" (namestring
                                   (merge-pathnames "index/table.dat" copy)))
                  :output '(:string :stripped t))
                 :junk-allowed t)))
        (is (< kb 10240) "~a KiB on disk" kb)))))

(def-db-test merge-modes
  "Each mode stores a source's records as its operation would."
  (with-temp-directory (dir)
    (with-test-db (src (merge-pathnames "s.vc/" dir))
      (db-set src "y" "b")
      (db-set src "z" "b")
      (dolist (case '((:set ("x" . "a") ("y" . "b") ("z" . "b"))
                      (:add ("x" . "a") ("y" . "a") ("z" . "b"))
                      (:replace ("x" . "a") ("y" . "b"))
                      (:append ("x" . "a") ("y" . "ab") ("z" . "b"))))
        (with-test-db (m (merge-pathnames
                          (format nil "m-~(~a~).vc/" (first case)) dir))
          (db-set m "x" "a")
          (db-set m "y" "a")
          (is-true (db-merge m (list src) :mode (first case)))
          (is (equal (rest case) (sorted-records m)))))
      (signals invalid-argument (db-merge src (list src)))
      (signals invalid-argument (db-merge src '() :mode :bogus)))))

(test merge-across-types
  "A HashDB merges into a TreeDB, which then holds the records in order."
  (with-temp-directory (dir)
    (with-db (h (merge-pathnames "h.vch/" dir))
      (dolist (k '("c" "a" "b"))
        (db-set h k k))
      (with-db (tr (merge-pathnames "t.vct/" dir) :type :tree)
        (is-true (db-merge tr (list h)))
        (is (equal '("a" "b" "c") (db-match-prefix tr "" :as :string)))))))

(def-db-test occupy-holds-the-database
  "A write started inside a writable DB-OCCUPY lands only after it."
  (with-temp-db (db)
    (let ((writer nil)
          (inside 0)
          (written 0))
      (is-true (db-occupy db (lambda (path count size)
                               (declare (ignore path count size))
                               (setf writer
                                     (bt:make-thread
                                      (lambda ()
                                        (db-set db "late" "x")
                                        (setf written
                                              (get-internal-real-time)))))
                               (sleep 0.3)
                               (setf inside (get-internal-real-time))
                               t)))
      (bt:join-thread writer)
      (is (>= written inside))
      (is (equal "x" (db-get db "late" :as :string))))))

(def-db-test copy-holds-the-database
  "Other threads' writes wait while DB-COPY runs, so the copy's count is
the number of records it holds."
  (with-temp-directory (dir)
    (let ((copy (merge-pathnames "c.vc/" dir))
          (stop nil))
      (with-test-db (db (merge-pathnames "o.vc/" dir))
        (let ((writers
                (loop for w below 2
                      collect (let ((w w))
                                (bt:make-thread
                                 (lambda ()
                                   (loop for i from 0
                                         until stop
                                         do (db-set db (format nil "~d-~d" w i)
                                                    "v"))))))))
          (sleep 0.2)
          (unwind-protect (db-copy db copy)
            (setf stop t)
            (mapc #'bt:join-thread writers))))
      (with-db (c copy)
        (let ((n 0))
          (db-iterate c (lambda (k v)
                          (declare (ignore k v))
                          (incf n)
                          :nop)
                      :writable nil)
          (is (= n (db-count c))))))))
