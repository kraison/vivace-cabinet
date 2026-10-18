(in-package #:vivace-cabinet-test)

(def-db-test bulk-operations
  "Set, get and remove many records at once, atomically or not; a key
given twice takes its last value."
  (with-temp-db (db)
    (dolist (atomic '(t nil))
      (db-clear db)
      (is (= 3 (db-set-bulk db '(("a" . "1") ("b" . "2") ("c" . "3")
                                  ("a" . "4"))
                            :atomic atomic)))
      (is (equal "4" (db-get db "a" :as :string)))
      (is (= 3 (db-count db)))
      (is (equal '(("c" . "3") ("a" . "4"))
                 (db-get-bulk db '("c" "zz" "a" "c") :atomic atomic
                                                     :as :string)))
      (is (= 2 (db-remove-bulk db '("a" "zz" "b" "a") :atomic atomic)))
      (is (equal '("c") (mapcar #'car (db-get-bulk db '("a" "b" "c")
                                                   :as :string))))
      (is (= 1 (db-count db))))))

(def-db-test bulk-operations-on-a-reader
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "b.vc/" dir)))
      (with-test-db (db path)
        (db-set db "k" "v"))
      (with-test-db (db path :mode '(:reader))
        (dolist (atomic '(t nil))
          (is (null (db-set-bulk db '(("k" . "w")) :atomic atomic)))
          (is (null (db-remove-bulk db '("k") :atomic atomic)))
          (is (eq :no-permission (db-error db)))
          (is (equal '(("k" . "v"))
                     (db-get-bulk db '("k") :atomic atomic :as :string))))))))
