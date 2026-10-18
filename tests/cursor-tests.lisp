(in-package #:vivace-cabinet-test)

(def-tree-test cursor-walks-in-order-both-ways
  (with-temp-db (db)
    (let* ((*random-state* (sb-ext:seed-random-state 3))
           (keys (loop for i below 500 collect (keyed i))))
      (dolist (k (alexandria:shuffle (copy-list keys)))
        (db-set db k (string-upcase k)))
      (with-cursor (cur db)
        (is-true (cursor-jump cur))
        (is (equal keys (cursor-walk cur #'cursor-step)))
        (is (eq :no-record (db-error db)))
        (is (null (cursor-get cur)))
        (is-true (cursor-jump-back cur))
        (is (equal (reverse keys) (cursor-walk cur #'cursor-step-back)))))))

(def-tree-test cursor-jumps-to-keys
  "A jump lands on the first record at or after the key, a jump back on
the last at or before it."
  (with-temp-db (db)
    (dolist (k '("b" "d" "f"))
      (db-set db k (string-upcase k)))
    (with-cursor (cur db)
      (is-true (cursor-jump cur "d"))
      (is (equal "d" (cursor-get-key cur :as :string)))
      (is-true (cursor-jump cur "c"))
      (is (equal "d" (cursor-get-key cur :as :string)))
      (is (null (cursor-jump cur "g")))
      (is (eq :no-record (db-error db)))
      (is-true (cursor-jump-back cur "e"))
      (is (equal "d" (cursor-get-key cur :as :string)))
      (is (null (cursor-jump-back cur "a")))
      (is-true (cursor-jump-back cur))
      (multiple-value-bind (k v) (cursor-get cur :as :string)
        (is (equal "f" k))
        (is (equal "F" v))))))

(def-tree-test cursor-edits-records
  "SET-VALUE, REMOVE and SEIZE act on the current record; REMOVE and
SEIZE move to the next, or after a backward move to the previous, as
Kyoto's do."
  (with-temp-db (db)
    (dotimes (i 10)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (is-true (cursor-set-value cur "first"))
      (is (equal "first" (db-get db (keyed 0) :as :string)))
      (is-true (cursor-remove cur))
      (is (equal (keyed 1) (cursor-get-key cur :as :string)))
      (multiple-value-bind (k v) (cursor-seize cur :as :string)
        (is (equal (keyed 1) k))
        (is (equal "v" v)))
      (is (equal (keyed 2) (cursor-get-key cur :as :string)))
      (is (= 8 (db-count db)))
      (cursor-jump-back cur)
      (is-true (cursor-remove cur))
      (is (equal (keyed 8) (cursor-get-key cur :as :string)))
      (is (= 7 (db-count db)))
      (cursor-jump cur (keyed 8))
      (is-true (cursor-remove cur))
      (is (null (cursor-get-key cur)))
      (is (= 6 (db-count db))))))

(def-tree-test cursor-follows-removal-by-others
  "When something else removes the current record, the cursor reads the
next one."
  (with-temp-db (db)
    (dotimes (i 5)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur (keyed 2))
      (db-remove db (keyed 2))
      (is (equal (keyed 3) (cursor-get-key cur :as :string)))
      (is-true (cursor-step-back cur))
      (is (equal (keyed 1) (cursor-get-key cur :as :string))))))

(def-tree-test cursor-on-an-empty-database
  (with-temp-db (db)
    (with-cursor (cur db)
      (is (null (cursor-jump cur)))
      (is (eq :no-record (db-error db)))
      (is (null (cursor-jump-back cur)))
      (is (null (cursor-get cur)))
      (is (null (cursor-step cur)))
      (is (null (cursor-remove cur))))))

(def-tree-test cursor-on-a-reader
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "r.vct/" dir)))
      (with-test-db (db path)
        (db-set db "k" "v"))
      (with-test-db (db path :mode '(:reader))
        (with-cursor (cur db)
          (is-true (cursor-jump cur))
          (is (equal "v" (cursor-get-value cur :as :string)))
          (is (null (cursor-set-value cur "w")))
          (is (eq :no-permission (db-error db)))
          (is (null (cursor-remove cur)))
          (is (equal "v" (db-get db "k" :as :string))))))))

(def-tree-test custom-comparator-orders-records
  (with-temp-db (db :comparator (lambda (a b) (octets< b a)))
    (dolist (k '("a" "b" "c"))
      (db-set db k k))
    (with-cursor (cur db)
      (cursor-jump cur)
      (is (equal '("c" "b" "a") (cursor-walk cur #'cursor-step))))))

(def-tree-test cursor-follows-removal-backward
  "Moving backward too, a cursor whose record is removed reads the next
one, as Kyoto's does; stepping back then goes below it."
  (with-temp-db (db)
    (dotimes (i 5)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump-back cur (keyed 3))
      (db-remove db (keyed 3))
      (is (equal (keyed 4) (cursor-get-key cur :as :string)))
      (is-true (cursor-step-back cur))
      (is (equal (keyed 2) (cursor-get-key cur :as :string))))))

(def-tree-test cursor-moves-on-from-removed-records
  "After another call removes the current record, the cursor's edits
and steps act on the next record, as Kyoto's do."
  (with-temp-db (db)
    (dotimes (i 6)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur (keyed 1))
      (db-remove db (keyed 1))
      (is-true (cursor-set-value cur "x"))
      (is (equal "x" (db-get db (keyed 2) :as :string)))
      (cursor-jump cur (keyed 3))
      (db-remove db (keyed 3))
      (is-true (cursor-step cur))
      (is (equal (keyed 5) (cursor-get-key cur :as :string))))))
