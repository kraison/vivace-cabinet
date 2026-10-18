(in-package #:vivace-cabinet-test)

(def-db-test snapshots-round-trip
  "A snapshot holds every record; loading it into an empty database of
any kind brings them all back."
  (with-temp-directory (dir)
    (let ((file (merge-pathnames "all.snap" dir)))
      (with-test-db (db (merge-pathnames "s.vc/" dir))
        (dotimes (i 100)
          (db-set db (keyed i) (make-string i :initial-element #\v)))
        (db-set db "" "")
        (db-set db "big" (make-string 50000 :initial-element #\b))
        (is-true (db-dump-snapshot db file)))
      (dolist (args '((:type :hash) (:type :tree :engine :skip-list)))
        (let ((db (apply #'open-db (merge-pathnames
                                    (format nil "l~a.vc/" (length args))
                                    dir)
                         args)))
          (unwind-protect
               (progn
                 (is-true (db-load-snapshot db file))
                 (is (= 102 (db-count db)))
                 (is (equal (make-string 42 :initial-element #\v)
                            (db-get db (keyed 42) :as :string)))
                 (is (equal "" (db-get db "" :as :string)))
                 (is (= 50000 (db-check db "big"))))
            (close-db db)))))))

(def-db-test bad-snapshots-signal
  (with-temp-directory (dir)
    (let ((good (merge-pathnames "good.snap" dir))
          (bad (merge-pathnames "bad.snap" dir))
          (cut (merge-pathnames "cut.snap" dir)))
      (with-test-db (db (merge-pathnames "s.vc/" dir))
        (db-set db "k" "value")
        (db-dump-snapshot db good)
        (with-open-file (out bad :direction :output
                                 :element-type '(unsigned-byte 8))
          (write-sequence (octets-of 1 2 3 4 5 6 7 8) out)
          (write-sequence (make-array 8 :element-type '(unsigned-byte 8)
                                        :initial-element 255)
                          out))
        (let ((all (with-open-file (in good :element-type '(unsigned-byte 8))
                     (let ((v (make-array (file-length in)
                                          :element-type '(unsigned-byte 8))))
                       (read-sequence v in)
                       v))))
          (with-open-file (out cut :direction :output
                                   :element-type '(unsigned-byte 8))
            (write-sequence all out :end (- (length all) 12))))
        (signals invalid-argument (db-load-snapshot db bad))
        (signals invalid-argument (db-load-snapshot db cut))))))

(def-db-test transactions-signal
  (with-temp-db (db)
    (signals transactions-not-implemented (db-begin-transaction db))
    (signals transactions-not-implemented (db-begin-transaction-try db))
    (signals transactions-not-implemented (db-end-transaction db))
    (signals not-implemented (with-transaction (db) (db-set db "k" "v")))
    (is (null (db-get db "k")))))
