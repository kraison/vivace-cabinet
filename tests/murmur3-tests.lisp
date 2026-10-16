(in-package #:vivace-cabinet-test)

(def-suite murmur3-suite
  :description "MurmurHash3 x64 128 against SMHasher's check."
  :in vivace-cabinet-suite)

(in-suite murmur3-suite)

(test murmur3-empty-is-zero
  "The empty input with seed 0 hashes to sixteen zero bytes."
  (is (every #'zerop (murmur3-128 (octets-of) 0))))

(test murmur3-returns-16-octets
  (is (typep (murmur3-128 (octets-of 1 2 3))
             '(simple-array (unsigned-byte 8) (16)))))

(test murmur3-matches-smhasher-verification
  "SMHasher's verification value for MurmurHash3_x64_128, #x6384BA69:
hash the first I bytes of 0..255 with seed 256-I for every I, then hash
the concatenated results with seed 0; the value is the first 4 bytes."
  (let ((key (make-array 256 :element-type '(unsigned-byte 8)))
        (hashes (make-array (* 256 16) :element-type '(unsigned-byte 8))))
    (dotimes (i 256)
      (setf (aref key i) i))
    (dotimes (i 256)
      (replace hashes (murmur3-128 (subseq key 0 i) (- 256 i))
               :start1 (* 16 i)))
    (let ((final (murmur3-128 hashes 0)))
      (is (= #x6384BA69
             (logior (aref final 0) (ash (aref final 1) 8)
                     (ash (aref final 2) 16) (ash (aref final 3) 24)))))))
