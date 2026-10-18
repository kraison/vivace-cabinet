(in-package #:vivace-cabinet-conformance)

(fiveam:in-suite conformance-suite)

(fiveam:test adapter-reports-kyotos-reasons
  (with-kyoto (db "a.kch")
    (fiveam:is-true (db-set db "k" "v"))
    (fiveam:is (null (db-add db "k" "w")))
    (fiveam:is (eq :duplicate-record (db-error db)))
    (fiveam:is (null (db-remove db "absent")))
    (fiveam:is (eq :no-record (db-error db)))
    (fiveam:is (null (db-increment db "k" 1)))
    (fiveam:is (eq :logic (db-error db)))))

(fiveam:test adapter-carries-every-byte
  "Keys and values with zero bytes pass through intact."
  (with-kyoto (db "b.kct")
    (let ((k (coerce #(0 1 0 255) '(simple-array (unsigned-byte 8) (*))))
          (v (coerce #(0 0 7) '(simple-array (unsigned-byte 8) (*)))))
      (fiveam:is-true (db-set db k v))
      (fiveam:is (equalp v (db-get db k)))
      (fiveam:is (= 3 (db-check db k)))
      (with-cursor (c db)
        (fiveam:is-true (cursor-jump c k))
        (fiveam:is (equalp k (cursor-get-key c))))
      (fiveam:is-true (db-remove db k))
      (fiveam:is (zerop (db-count db))))))

(fiveam:test adapter-releases-cursors
  "WITH-CURSOR deletes Kyoto's cursor; CLOSE-DB deletes any left, which
then signal instead of reaching freed memory."
  (with-kyoto (db "c.kch")
    (with-cursor (c db)
      (cursor-jump c))
    (fiveam:is (null (vivace-cabinet-kyoto::%kdb-cursors db)))
    (let ((left (db-cursor db)))
      (fiveam:is (= 1 (length (vivace-cabinet-kyoto::%kdb-cursors db))))
      (close-db db)
      (fiveam:is (null (vivace-cabinet-kyoto::%kdb-cursors db)))
      (fiveam:is (null (vivace-cabinet-kyoto::%kc-ptr left)))
      ;; Only when released: a live one would reach freed memory.
      (when (null (vivace-cabinet-kyoto::%kc-ptr left))
        (fiveam:signals invalid-argument (cursor-jump left))))))

(fiveam:test adapter-matches-refuse-zero-bytes
  "Kyoto's match calls take C strings: a pattern holding a zero byte
signals INVALID-ARGUMENT rather than matching on the part before it."
  (with-kyoto (db "z.kct")
    (db-set db "ab" "v")
    (let ((p (coerce #(97 0 98) '(simple-array (unsigned-byte 8) (*)))))
      (fiveam:signals invalid-argument (db-match-prefix db p))
      (fiveam:signals invalid-argument (db-match-regex db p))
      (fiveam:signals invalid-argument (db-match-similar db p 1)))))
