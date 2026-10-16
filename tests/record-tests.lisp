(in-package #:vivace-cabinet-test)

(def-suite record-suite
  :description "Key/value records in the heap."
  :in vivace-cabinet-suite)

(in-suite record-suite)

(test record-round-trip
  (with-temp-memory (heap)
    (let* ((k (octets-of 1 2 3))
           (v (octets-of 9 8))
           (a (write-record heap k v 0)))
      (is (equalp k (record-key heap a)))
      (is (equalp v (record-value heap a)))
      (is (= 2 (record-value-length heap a)))
      (is (= 0 (record-next heap a)))
      (is-true (record-key= heap a k))
      (is (not (record-key= heap a (octets-of 1 2 4))))
      (is (not (record-key= heap a (octets-of 1 2)))))))

(test record-chain-links
  (with-temp-memory (heap)
    (let* ((a (write-record heap (octets-of 1) (octets-of 1) 0))
           (b (write-record heap (octets-of 2) (octets-of 2) a)))
      (is (= a (record-next heap b)))
      (setf (record-next heap b) 0)
      (is (= 0 (record-next heap b))))))

(test record-empty-key-and-value
  (with-temp-memory (heap)
    (let ((a (write-record heap (octets-of) (octets-of) 0)))
      (is (equalp (octets-of) (record-key heap a)))
      (is (equalp (octets-of) (record-value heap a))))))

(test record-large-value
  (with-temp-memory (heap)
    (let ((v (make-array 100000 :element-type '(unsigned-byte 8))))
      (dotimes (i (length v))
        (setf (aref v i) (mod (* 7 i) 256)))
      (let ((a (write-record heap (octets-of 5) v 0)))
        (is (equalp v (record-value heap a)))))))

(test freed-record-space-is-reused
  "A freed record's space goes to the next record of the same size."
  (with-temp-memory (heap)
    (let ((a (write-record heap (octets-of 1 2) (octets-of 3 4) 0)))
      (free-record heap a)
      (is (= a (write-record heap (octets-of 5 6) (octets-of 7 8) 0))))))
