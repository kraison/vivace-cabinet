(in-package #:vivace-cabinet-test)

(def-db-test cas-swaps-only-the-expected-value
  (with-temp-db (db)
    (is-true (db-cas db "k" nil "1"))
    (is (null (db-cas db "k" nil "2")))
    (is (eq :logic (db-error db)))
    (is (null (db-cas db "k" "x" "2")))
    (is (equal "1" (db-get db "k" :as :string)))
    (is-true (db-cas db "k" "1" "2"))
    (is (equal "2" (db-get db "k" :as :string)))
    (is-true (db-cas db "k" "2" nil))
    (is (null (db-get db "k")))
    (is-true (db-cas db "k" nil nil))
    (is (null (db-get db "k")))))

(def-db-test increments-follow-kyoto
  "8-byte big-endian integers; ORIG for an absent key, the 64-bit
extremes as Kyoto Cabinet reads them, wrap-around, and NIL with :LOGIC
for a value of another size."
  (with-temp-db (db)
    (let ((min (- (expt 2 63)))
          (max (1- (expt 2 63))))
      (is (= 5 (db-increment db "n" 5)))
      (is (= 12 (db-increment db "n" 7)))
      (is (equalp (octets-of 0 0 0 0 0 0 0 12) (db-get db "n")))
      (is (= 12 (db-increment db "n" 0)))
      (is (= -3 (db-increment db "n" -15)))
      (is (= 110 (db-increment db "m" 10 :orig 100)))
      (is (null (db-increment db "absent" 1 :orig min)))
      (is (eq :logic (db-error db)))
      (is (null (db-get db "absent")))
      (is (= 4 (db-increment db "n" 4 :orig max)))
      (is (= max (db-increment db "big" max)))
      (is (= min (db-increment db "big" 1)))
      (db-set db "text" "hello")
      (is (null (db-increment db "text" 1)))
      (is (eq :logic (db-error db)))
      (signals invalid-argument (db-increment db "n" (expt 2 64))))))

(def-db-test double-increments-follow-kyoto
  "16 bytes: the integral part, then the fraction in 10^-15 units."
  (with-temp-db (db)
    (is (= 1.5d0 (db-increment-double db "d" 1.5d0)))
    (is (= 3.75d0 (db-increment-double db "d" 2.25d0)))
    (is (equalp (concatenate '(vector (unsigned-byte 8))
                             (octets-of 0 0 0 0 0 0 0 3)
                             (octets-of 0 2 #xaa #x1e #xfb #x94 #xe0 0))
                (db-get db "d")))
    (is (= 3.75d0 (db-increment-double db "d" 0)))
    (is (= 1.25d0 (db-increment-double db "d" -2.5d0)))
    (is (= 2d0 (db-increment-double db "d" 0.75d0)))
    (is (equalp (octets-of 0 0 0 0 0 0 0 2 0 0 0 0 0 0 0 0)
                (db-get db "d")))
    (is (= 10.5d0 (db-increment-double db "e" 0.5d0 :orig 10)))
    (is (= 2d0 (db-increment-double
                db "d" 2 :orig sb-ext:double-float-positive-infinity)))
    (is (null (db-increment-double
               db "absent" 1 :orig sb-ext:double-float-negative-infinity)))
    (is (eq :logic (db-error db)))
    (db-set db "text" "hello")
    (is (null (db-increment-double db "text" 1)))
    (is (eq :logic (db-error db)))))

(def-db-test increments-on-a-reader
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "i.vc/" dir)))
      (with-test-db (db path)
        (db-increment db "n" 3))
      (with-test-db (db path :mode '(:reader))
        (is (null (db-increment db "n" 1)))
        (is (eq :no-permission (db-error db)))
        (is (= 3 (db-increment db "n" 0 :orig (- (expt 2 63)))))
        (is (null (db-cas db "n" nil "x")))))))

(def-db-test double-increments-match-kyotos-bytes
  "Results and bytes from Kyoto Cabinet 1.2.80 on x86-64, which computes
the fraction in long double."
  (with-temp-db (db)
    (flet ((bytes-are (key &rest bytes)
             (is (equalp (apply #'octets-of bytes) (db-get db key))
                 "~a" key)))
      (is (= 0.3d0 (db-increment-double db "a" 0.3d0)))
      (bytes-are "a" 0 0 0 0 0 0 0 0 0 1 #x10 #xd9 #x31 #x6e #xbf #xff)
      (db-increment-double db "b" 0.7d0)
      (is (= 1.299999999999998d0 (db-increment-double db "b" 0.6d0)))
      (bytes-are "b" 0 0 0 0 0 0 0 1 0 1 #x10 #xd9 #x31 #x6e #xbf #xfe)
      (db-increment-double db "c" -0.3d0)
      (bytes-are "c" 0 0 0 0 0 0 0 0
                 #xff #xfe #xef #x26 #xce #x91 #x40 #x01)
      (is (= 10.1d0 (db-increment-double db "h" 0.1d0 :orig 10)))
      (bytes-are "h" 0 0 0 0 0 0 0 #x0a 0 0 #x5a #xf3 #x10 #x7a #x3f #xff))))

(def-db-test double-increments-past-64-bits-follow-kyoto
  "An integral part past 64 bits is stored as the most negative integer,
which reads back as negative infinity; a sum past 64 bits wraps."
  (with-temp-db (db)
    (is (= 1d19 (db-increment-double db "e" 1d19)))
    (is (equalp (octets-of #x80 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
                (db-get db "e")))
    (is (= sb-ext:double-float-negative-infinity
           (db-increment-double db "e" 1)))
    (db-increment-double db "g" 9d18)
    (is (= -4.4674407370955162d17 (db-increment-double db "g" 9d18)))))
