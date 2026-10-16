(in-package #:vivace-cabinet-test)

(def-suite hash-cursor-suite
  :description "HashDB's forward cursor."
  :in vivace-cabinet-suite)

(in-suite hash-cursor-suite)

(test hash-cursor-visits-every-record-once
  "2000 records, so the index splits: a walk sees each exactly once."
  (with-temp-db (db)
    (let ((keys (loop for i below 2000 collect (keyed i))))
      (dolist (k keys)
        (db-set db k k))
      (with-cursor (cur db)
        (is-true (cursor-jump cur))
        (let ((seen (cursor-walk cur #'cursor-step)))
          (is (= 2000 (length seen)))
          (is (equal keys (sort seen #'string<))))))))

(test hash-cursor-walks-collision-chains
  (let ((*key-digest* (constant-digest 9)))
    (with-temp-db (db)
      (dolist (k '("a" "b" "c" "d"))
        (db-set db k k))
      (with-cursor (cur db)
        (cursor-jump cur)
        (is (equal '("a" "b" "c" "d")
                   (sort (cursor-walk cur #'cursor-step) #'string<)))))))

(test hash-cursor-jumps-to-a-key
  "A jump to a key lands on it and walks on as a full walk would."
  (with-temp-db (db)
    (dotimes (i 300)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (let* ((all (cursor-walk cur #'cursor-step))
             (from (nth 100 all)))
        (is-true (cursor-jump cur from))
        (is (equal (nthcdr 100 all) (cursor-walk cur #'cursor-step)))
        (is (null (cursor-jump cur "absent")))
        (is (eq :no-record (db-error db)))))))

(test hash-cursor-edits-records
  "SET-VALUE changes the current record; REMOVE and SEIZE take it and
move on, until the database is empty."
  (with-temp-db (db)
    (dotimes (i 500)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (let ((first (cursor-get-key cur :as :string)))
        (is-true (cursor-set-value cur "w"))
        (is (equal "w" (db-get db first :as :string)))
        (multiple-value-bind (k v) (cursor-seize cur :as :string)
          (is (equal first k))
          (is (equal "w" v)))
        (is (null (db-get db first))))
      (loop while (cursor-remove cur))
      (is (= 0 (db-count db))))))

(test hash-cursor-reads-past-removed-records
  (with-temp-db (db)
    (dotimes (i 5)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (let ((first (cursor-get-key cur :as :string)))
        (db-remove db first)
        (is (not (equal first (cursor-get-key cur :as :string))))
        (is (= 4 (length (cursor-walk cur #'cursor-step))))))))

(test hash-cursor-moves-forward-only
  (with-temp-db (db)
    (db-set db "k" "v")
    (with-cursor (cur db)
      (cursor-jump cur)
      (signals not-implemented (cursor-jump-back cur))
      (signals not-implemented (cursor-step-back cur)))))

(test hash-cursor-on-an-empty-database
  (with-temp-db (db)
    (with-cursor (cur db)
      (is (null (cursor-jump cur)))
      (is (eq :no-record (db-error db)))
      (is (null (cursor-get cur)))
      (is (null (cursor-step cur))))))

(test hash-cursor-sees-records-others-leave-alone
  "While another thread removes and re-adds other keys, a walk that no
bucket split overlaps sees every untouched record once."
  (with-temp-db (db :buckets 256)
    (dotimes (i 2000)
      (db-set db (format nil "s~4,'0d" i) "v"))
    (dotimes (i 2000)
      (db-set db (format nil "c~4,'0d" i) "v"))
    (let* ((stop nil)
           (bad 0)
           (clean 0)
           (churn (bt:make-thread
                   (lambda ()
                     (let ((*random-state* (sb-ext:seed-random-state 9)))
                       (loop until stop
                             do (let ((k (format nil "c~4,'0d"
                                                 (random 2000))))
                                  (db-remove db k)
                                  (db-set db k "v"))))))))
      (unwind-protect
           (progn
             ;; Churn splits overflowing buckets until none overflows;
             ;; walk once the bucket count has held for 2 s.
             (loop with steady = 0
                   for tries below 60
                   for before = (bucket-count (hash-db-index db))
                   do (sleep 0.5)
                      (if (= before (bucket-count (hash-db-index db)))
                          (incf steady)
                          (setf steady 0))
                   until (>= steady 4))
             (dotimes (walk 20)
             (let ((before (bucket-count (hash-db-index db))))
               (with-cursor (cur db)
                 (cursor-jump cur)
                 (let ((stable (count #\s (cursor-walk cur #'cursor-step)
                                      :key (lambda (k) (char k 0)))))
                   (when (= before (bucket-count (hash-db-index db)))
                     (incf clean)
                     (unless (= 2000 stable)
                       (incf bad))))))))
        (setf stop t)
        (bt:join-thread churn))
      (is (plusp clean))
      (is (= 0 bad) "~a of ~a walks miscounted" bad clean))))
