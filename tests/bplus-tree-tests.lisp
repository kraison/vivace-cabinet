(in-package #:vivace-cabinet-test)

;;; New: vivace-graph tested its B+ tree only through graph indexes and a
;;; benchmark (tests/perf/bplus-bench.lisp at 853df62).

(def-suite bplus-tree-suite
  :description "B+ tree insert / find / remove / cursors / reopen."
  :in vivace-cabinet-suite)

(in-suite bplus-tree-suite)

(defun integer-bplus-tree-args ()
  (list :key-comparison '< :key-equal '= :value-equal 'equal
        :key-serializer 'test-serialize :key-deserializer 'test-deserialize
        :value-serializer 'test-serialize
        :value-deserializer 'test-deserialize))

(defun make-integer-bplus-tree (heap)
  (apply #'make-bplus-tree :heap heap (integer-bplus-tree-args)))

(defun tree-value (tree key)
  "KEY's value in TREE, or NIL."
  (let ((node (find-in-skip-list tree key)))
    (and node (%sn-value node))))

(defun cursor-keys (cursor)
  (loop for node = (cursor-next cursor :eoc)
        until (eq node :eoc)
        collect (%sn-key node)))

(test bplus-insert-find
  "Inserted keys are found with their values; a duplicate key is refused."
  (with-temp-memory (heap)
    (let ((tree (make-integer-bplus-tree heap))
          (keys (alexandria:shuffle (loop for i from 1 to 200 collect i))))
      (dolist (k keys)
        (is-true (add-to-skip-list tree k (format nil "v~a" k))))
      (is (= 200 (bplus-tree-count tree)))
      (dolist (k keys)
        (is (equal (format nil "v~a" k) (tree-value tree k))))
      (is (null (add-to-skip-list tree 7 "again")))
      (is (equal "v7" (tree-value tree 7)))
      (is (null (tree-value tree 1000))))))

(test bplus-cursors-are-ordered
  "A full cursor yields every key in order; a range cursor is inclusive."
  (with-temp-memory (heap)
    (let ((tree (make-integer-bplus-tree heap))
          (keys (remove-duplicates
                 (loop repeat 5000 collect (random 100000)))))
      (dolist (k keys)
        (add-to-skip-list tree k "x"))
      (let ((sorted (sort (copy-list keys) #'<)))
        (is (equal sorted (cursor-keys (make-cursor tree))))
        (is (equal (remove-if-not (lambda (k) (<= 100 k 20000)) sorted)
                   (cursor-keys (make-range-cursor tree 100 20000))))))))

(test bplus-remove-half-then-all
  "Removing half the keys, then the rest, merges pages and collapses the
root; the tree stays correct and usable throughout."
  (with-temp-memory (heap)
    (let* ((tree (make-integer-bplus-tree heap))
           (keys (alexandria:shuffle (loop for i below 20000 collect i)))
           (gone (remove-if-not #'evenp keys))
           (kept (sort (copy-list (remove-if #'evenp keys)) #'<)))
      (dolist (k keys)
        (add-to-skip-list tree k (format nil "v~a" k)))
      (dolist (k gone)
        (is-true (remove-from-skip-list tree k)))
      (is (= 10000 (bplus-tree-count tree)))
      (is (equal kept (cursor-keys (make-cursor tree))))
      (is (null (tree-value tree 4)))
      (is (equal "v5" (tree-value tree 5)))
      (dolist (k kept)
        (remove-from-skip-list tree k))
      (is (= 0 (bplus-tree-count tree)))
      (is (null (cursor-keys (make-cursor tree))))
      (is-true (add-to-skip-list tree 1 "again"))
      (is (equal "again" (tree-value tree 1))))))

(test bplus-update
  "update-in-skip-list replaces a key's value."
  (with-temp-memory (heap)
    (let ((tree (make-integer-bplus-tree heap)))
      (add-to-skip-list tree 3 "old")
      (update-in-skip-list tree 3 "new")
      (is (equal "new" (tree-value tree 3)))
      (is (= 1 (bplus-tree-count tree))))))

(test bplus-remove-by-value
  "Removing with a value removes only when the stored value matches."
  (with-temp-memory (heap)
    (let ((tree (make-integer-bplus-tree heap)))
      (add-to-skip-list tree 9 "v")
      (is (null (remove-from-skip-list tree 9 "w")))
      (is (equal "v" (tree-value tree 9)))
      (is-true (remove-from-skip-list tree 9 "v"))
      (is (null (tree-value tree 9))))))

(test bplus-reopen
  "A tree written, closed with its heap, and reopened has its contents."
  (with-temp-directory (dir)
    (let* ((path (namestring (merge-pathnames "heap.dat" dir)))
           (heap (create-memory path (* 1024 1024 64)))
           (tree (make-integer-bplus-tree heap))
           (address (%bpt-address tree)))
      (dotimes (k 3000)
        (add-to-skip-list tree k (format nil "v~a" k)))
      (close-memory heap)
      (let* ((heap2 (open-memory path))
             (tree2 (apply #'open-bplus-tree :address address :heap heap2
                           (integer-bplus-tree-args))))
        (unwind-protect
             (progn
               (is (= 3000 (bplus-tree-count tree2)))
               (is (equal "v1234" (tree-value tree2 1234))))
          (close-memory heap2))))))
