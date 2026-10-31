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

(defun file-octets (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence v in)
      v)))

(def-db-test failed-dumps-keep-the-old-snapshot
  "A dump that succeeds replaces the file at its path; one that fails
leaves it as it was, and no temporary file behind."
  (with-temp-directory (dir)
    (let ((file (merge-pathnames "keep" dir))
          (db (open-test-db (merge-pathnames "s.vc/" dir))))
      (unwind-protect
           (progn
             (db-set db "k" "v")
             (is-true (db-dump-snapshot db file))
             (let ((one (file-octets file)))
               (db-set db "k2" "v2")
               (is-true (db-dump-snapshot db file))
               (let ((two (file-octets file)))
                 (is (not (equalp one two)))
                 (close-db db)
                 (signals vivace-cabinet-error (db-dump-snapshot db file))
                 (is (equalp two (file-octets file)))
                 (is (equal '("keep")
                            (mapcar #'file-namestring
                                    (uiop:directory-files dir)))))))
        (ignore-errors (close-db db))))))

(def-db-test bad-snapshots-load-nothing
  "A snapshot cut short, or holding a key too long for the database,
signals before any record is stored (#8)."
  (with-temp-directory (dir)
    (let ((whole (merge-pathnames "whole.snap" dir))
          (cut (merge-pathnames "cut.snap" dir))
          (long (merge-pathnames "long.snap" dir)))
      (with-test-db (db (merge-pathnames "s.vc/" dir))
        (dotimes (i 3)
          (db-set db (keyed i) "v"))
        (db-dump-snapshot db whole))
      (let ((all (file-octets whole)))
        (with-open-file (out cut :direction :output
                                 :element-type '(unsigned-byte 8))
          (write-sequence all out :end (- (length all) 12))))
      ;; In key order, so the long key comes last.
      (with-db (src (merge-pathnames "o.vct/" dir) :type :tree
                                                   :engine :skip-list)
        (db-set src "a" "v")
        (db-set src "b" "v")
        (db-set src (make-string 2000 :initial-element #\z) "v")
        (db-dump-snapshot src long))
      (with-test-db (db (merge-pathnames "l.vc/" dir))
        (signals invalid-argument (db-load-snapshot db cut))
        (is (= 0 (db-count db)))
        (cond ((eq :bplus-tree (getf *db-type-args* :engine))
               (signals key-too-long (db-load-snapshot db long))
               (is (= 0 (db-count db))))
              (t
               (is-true (db-load-snapshot db long))
               (is (= 3 (db-count db)))))))))

(def-db-test file-trouble-signals-system-error
  "A missing snapshot, a dump into a missing directory and a copy under
a file signal SYSTEM-ERROR, a VIVACE-CABINET-ERROR (#8), and change
nothing."
  (with-temp-directory (dir)
    (with-test-db (db (merge-pathnames "s.vc/" dir))
      (db-set db "k" "v")
      (signals system-error
        (db-load-snapshot db (merge-pathnames "none.snap" dir)))
      (signals system-error
        (db-dump-snapshot db (merge-pathnames "nodir/x.snap" dir)))
      (with-open-file (out (merge-pathnames "afile" dir) :direction :output)
        (write-line "x" out))
      (signals system-error (db-copy db (merge-pathnames "afile/c.vc/" dir)))
      (is (equal "v" (db-get db "k" :as :string)))
      (is (equal '("afile")
                 (mapcar #'file-namestring (uiop:directory-files dir))))
      (is (equal '("s.vc")
                 (mapcar (lambda (d) (car (last (pathname-directory d))))
                         (uiop:subdirectories dir)))))))
