(in-package #:vivace-cabinet-test)

(def-suite tree-db-suite
  :description "TreeDB: types, engines, limits and reopening."
  :in vivace-cabinet-suite)

(in-suite tree-db-suite)

(test tree-db-opens-as-what-it-is
  "An existing database opens as its own type and engine; asking for
another signals OPEN-ERROR, unless a writer truncates it."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "s.vct/" dir)))
      (with-db (db path :type :tree :engine :skip-list)
        (db-set db "k" "v"))
      (with-db (db path)
        (is (typep db 'tree-db))
        (is (typep (tree-db-engine db) 'skip-list-engine))
        (is (equal "v" (db-get db "k" :as :string))))
      (signals open-error (open-db path :type :hash))
      (signals open-error (open-db path :type :tree :engine :bplus-tree))
      (with-db (db path :mode '(:writer :truncate) :type :hash)
        (is (typep db 'hash-db))
        (is (= 0 (db-count db)))))))

(test tree-db-key-limit
  "The B+ tree engine refuses keys over a quarter page; the skip list
takes them."
  (with-temp-directory (dir)
    (let ((long (make-string 1025 :initial-element #\k)))
      (with-db (db (merge-pathnames "b.vct/" dir) :type :tree)
        (signals key-too-long (db-set db long "v"))
        (is-true (db-set db (subseq long 1) "v"))
        (is (= 1 (db-count db))))
      (with-db (db (merge-pathnames "s.vct/" dir)
                   :type :tree :engine :skip-list)
        (is-true (db-set db (make-string 5000 :initial-element #\k) "v"))))))

(test tree-db-out-of-line-values-survive-reopen
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "o.vct/" dir))
          (big (make-string 100000 :initial-element #\b)))
      (with-db (db path :type :tree)
        (db-set db "big" big)
        (db-set db "small" "s")
        (db-set db "mid" (make-string 2000 :initial-element #\m)))
      (with-db (db path)
        (is (equal big (db-get db "big" :as :string)))
        (is (= 2000 (db-check db "mid")))
        (is-true (db-set db "big" "now small"))
        (is (equal "now small" (db-get db "big" :as :string)))
        (is (= 3 (db-count db)))))))

(test tree-db-small-pages
  "With 1024-byte pages, keys up to 256 bytes work and longer ones
signal."
  (with-temp-directory (dir)
    (with-db (db (merge-pathnames "p.vct/" dir) :type :tree :page-size 1024)
      (dotimes (i 300)
        (db-set db (format nil "~3,'0d~a" i
                           (make-string 200 :initial-element #\k))
                (make-string 300 :initial-element #\v)))
      (is (= 300 (db-count db)))
      (is (= 300 (db-check db (format nil "150~a"
                                      (make-string 200
                                                   :initial-element #\k)))))
      (signals key-too-long
        (db-set db (make-string 257 :initial-element #\k) "v")))))

(test tree-db-bad-arguments-signal
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "x.vct/" dir)))
      (signals invalid-argument (open-db path :type :tree :engine :bogus))
      (signals invalid-argument (open-db path :type :tree :page-size 100))
      (signals invalid-argument (open-db path :type :tree
                                              :page-size 65536)))))
