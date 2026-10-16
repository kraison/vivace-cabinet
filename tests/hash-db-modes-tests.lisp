(in-package #:vivace-cabinet-test)

(def-suite hash-db-modes-suite
  :description "HashDB open modes, damaged files, size, clear, sync."
  :in vivace-cabinet-suite)

(in-suite hash-db-modes-suite)

(defun header-count (path)
  "The record count in the header of the database at PATH."
  (vivace-cabinet::%read-header (uiop:ensure-directory-pathname path)))

(test synchronize-persists-the-count
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "s.vch/" dir)))
      (with-db (db path)
        (db-set db "a" "1")
        (db-set db "b" "2")
        (is-true (db-synchronize db))
        (is (= 2 (header-count path)))))))

(test autosync-writes-through
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "a.vch/" dir)))
      (with-db (db path :mode '(:writer :create :autosync))
        (db-set db "a" "1")
        (is (= 1 (header-count path)))))))

(test reader-mode-refuses-writes
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "m.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-db (db path :mode '(:reader))
        (is (equal "v" (db-get db "k" :as :string)))
        (is (null (db-set db "k" "w")))
        (is (eq :no-permission (db-error db)))
        (is (null (db-remove db "k")))
        (is (null (db-clear db)))
        (is (equal "v" (db-get db "k" :as :string)))))))

(test opening-needs-create-or-a-database
  (with-temp-directory (dir)
    (signals open-error (open-db (merge-pathnames "none.vch/" dir)
                                 :mode '(:writer)))
    (signals open-error (open-db (merge-pathnames "none.vch/" dir)
                                 :mode '(:reader)))))

(test truncate-empties
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "t.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-db (db path :mode '(:writer :create :truncate))
        (is (= 0 (db-count db)))
        (is (null (db-get db "k")))))))

(test bad-open-arguments-signal
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "b.vch/" dir)))
      (signals invalid-argument (open-db path :mode '(:reader :writer)))
      (signals invalid-argument (open-db path :mode '(:create)))
      (signals invalid-argument (open-db path :mode '(:writer :bogus)))
      (signals invalid-argument (open-db path :type :bogus))
      (signals not-implemented (open-db path :type :tree)))))

(test corrupt-index-signals
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "i.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-open-file (s (merge-pathnames "index/table.dat" path)
                         :direction :output :if-exists :overwrite
                         :element-type '(unsigned-byte 8))
        (write-byte 0 s))
      (signals open-error (open-db path)))))

(test paths-become-directories
  "A path without a trailing slash, or a relative one, names a directory."
  (with-temp-directory (dir)
    (let ((plain (namestring (merge-pathnames "p.vch" dir))))
      (with-db (db plain)
        (db-set db "k" "v")
        (is (equal (namestring (merge-pathnames "p.vch/" dir))
                   (db-path db))))
      (is-true (probe-file (merge-pathnames "p.vch/header.dat" dir))))
    (let ((*default-pathname-defaults* dir))
      (with-db (db "rel.vch")
        (db-set db "k" "v"))
      (is-true (probe-file (merge-pathnames "rel.vch/heap.dat" dir))))))

(test size-grows
  (with-temp-db (db)
    (let ((before (db-size db)))
      (is (plusp before))
      (dotimes (i 500)
        (db-set db (format nil "k~a" i)
                (make-string 100 :initial-element #\x)))
      (is (> (db-size db) (+ before 50000))))))

(test clear-empties-and-stays-usable
  (with-temp-db (db)
    (dotimes (i 100)
      (db-set db (format nil "k~a" i) "v"))
    (is-true (db-clear db))
    (is (= 0 (db-count db)))
    (is (null (db-get db "k5")))
    (is-true (db-set db "after" "clear"))
    (is (equal "clear" (db-get db "after" :as :string)))))

(test one-writer-or-many-readers
  "A database open for writing refuses any other handle; readers share."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "l.vch/" dir)))
      (with-db (db path)
        (db-set db "k" "v")
        (signals open-error (open-db path))
        (signals open-error (open-db path :mode '(:reader))))
      (with-db (r1 path :mode '(:reader))
        (with-db (r2 path :mode '(:reader))
          (is (equal "v" (db-get r2 "k" :as :string))))
        (signals open-error (open-db path)))
      (with-db (db path)
        (is (equal "v" (db-get db "k" :as :string)))))))

(test truncate-needs-no-create
  "As in Kyoto, :WRITER :TRUNCATE empties an existing database."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "tc.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-db (db path :mode '(:writer :truncate))
        (is (= 0 (db-count db)))
        (is (null (db-get db "k"))))
      (with-db (db path :mode '(:reader))
        (is (= 0 (db-count db)))))))

(test incomplete-databases-signal-or-truncate
  "Files without a header (a crash while creating) signal OPEN-ERROR,
even with :CREATE; :TRUNCATE discards them."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "ic.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (delete-file (merge-pathnames "header.dat" path))
      (signals open-error (open-db path))
      (signals open-error (open-db path :mode '(:reader)))
      (with-db (db path :mode '(:writer :create :truncate))
        (is (= 0 (db-count db)))
        (is-true (db-set db "k2" "v2"))))))
