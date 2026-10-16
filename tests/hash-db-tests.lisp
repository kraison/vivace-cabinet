(in-package #:vivace-cabinet-test)

(def-suite hash-db-suite
  :description "HashDB per-key operations."
  :in vivace-cabinet-suite)

(in-suite hash-db-suite)

(defun constant-digest (byte)
  "A digest function giving every key the same 16 bytes."
  (lambda (key)
    (declare (ignore key))
    (make-array 16 :element-type '(unsigned-byte 8) :initial-element byte)))

(test set-and-get
  (with-temp-db (db)
    (is-true (db-set db "k" "v"))
    (is (equal "v" (db-get db "k" :as :string)))
    (is (equalp (octets-of 118) (db-get db "k")))
    (is-true (db-set db (octets-of 1 2) (octets-of 3)))
    (is (equalp (octets-of 3) (db-get db (octets-of 1 2))))
    (is-true (db-set db "k" "w"))
    (is (equal "w" (db-get db "k" :as :string)))
    (is (= 2 (db-count db)))))

(test missing-keys-give-nil-and-no-record
  (with-temp-db (db)
    (is (null (db-get db "absent")))
    (is (eq :no-record (db-error db)))
    (is (null (db-check db "absent")))
    (is (null (db-remove db "absent")))
    (is (eq :no-record (db-error db)))))

(test add-replace-append
  (with-temp-db (db)
    (is-true (db-add db "a" "1"))
    (is (null (db-add db "a" "2")))
    (is (eq :duplicate-record (db-error db)))
    (is (equal "1" (db-get db "a" :as :string)))
    (is (null (db-replace db "b" "x")))
    (is (eq :no-record (db-error db)))
    (is-true (db-replace db "a" "3"))
    (is (equal "3" (db-get db "a" :as :string)))
    (is-true (db-append db "a" "4"))
    (is-true (db-append db "c" "5"))
    (is (equal "34" (db-get db "a" :as :string)))
    (is (equal "5" (db-get db "c" :as :string)))
    (is (= 2 (db-count db)))))

(test check-seize-remove
  (with-temp-db (db)
    (db-set db "k" "value")
    (is (= 5 (db-check db "k")))
    (is (equal "value" (db-seize db "k" :as :string)))
    (is (null (db-get db "k")))
    (is (= 0 (db-count db)))
    (db-set db "j" "x")
    (is-true (db-remove db "j"))
    (is (null (db-get db "j")))
    (is (= 0 (db-count db)))))

(test values-change-size
  "Replacing and appending with larger and smaller values."
  (with-temp-db (db)
    (db-set db "k" "x")
    (db-set db "k" (make-string 5000 :initial-element #\y))
    (is (= 5000 (db-check db "k")))
    (db-set db "k" "z")
    (is (equal "z" (db-get db "k" :as :string)))
    (dotimes (i 100)
      (db-append db "k" "ab"))
    (is (= 201 (db-check db "k")))))

(test empty-keys-and-values
  (with-temp-db (db)
    (is-true (db-set db "" "v"))
    (is-true (db-set db "e" ""))
    (is (equal "v" (db-get db "" :as :string)))
    (is (equal "" (db-get db "e" :as :string)))
    (is (= 0 (db-check db "e")))))

(test large-values
  (with-temp-db (db)
    (let ((v (make-array (expt 2 20) :element-type '(unsigned-byte 8))))
      (dotimes (i (length v))
        (setf (aref v i) (mod (* 13 i) 256)))
      (is-true (db-set db "big" v))
      (is (equalp v (db-get db "big"))))))

(test non-ascii-strings
  (with-temp-db (db)
    (db-set db "clé" "naïve 日本")
    (is (equal "naïve 日本" (db-get db "clé" :as :string)))))

(test collisions-chain-correctly
  "With every key given the same digest, one chain holds them all; each
operation works at the chain's head, middle and tail."
  (let ((*key-digest* (constant-digest 7)))
    (with-temp-db (db)
      (dolist (k '("a" "b" "c" "d" "e"))
        (db-set db k (string-upcase k)))
      (is (= 5 (db-count db)))
      (dolist (k '("a" "b" "c" "d" "e"))
        (is (equal (string-upcase k) (db-get db k :as :string))))
      (is-true (db-remove db "c"))
      (is-true (db-remove db "e"))
      (is-true (db-remove db "a"))
      (is (null (db-get db "c")))
      (is (equal "B" (db-get db "b" :as :string)))
      (is (equal "D" (db-get db "d" :as :string)))
      (is (null (db-add db "b" "x")))
      (is-true (db-replace db "d" "dd"))
      (is (equal "dd" (db-get db "d" :as :string)))
      (is (= 2 (db-count db))))))

(test all-zero-digest-is-remapped
  "The linear hash reserves the all-zero key; a zero digest still works."
  (let ((*key-digest* (constant-digest 0)))
    (with-temp-db (db)
      (is-true (db-set db "z" "v"))
      (is (equal "v" (db-get db "z" :as :string))))))

(test errors-are-per-thread
  (with-temp-db (db)
    (db-get db "absent")
    (let ((other nil))
      (bt:join-thread (bt:make-thread (lambda ()
                                        (setf other (db-error db)))))
      (is (eq :success other))
      (is (eq :no-record (db-error db))))))

(test bad-arguments-signal
  (with-temp-db (db)
    (signals invalid-argument (db-set db 42 "v"))
    (signals invalid-argument (db-get db "absent" :as :symbol))))

(test reopen-keeps-everything
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "r.vch/" dir)))
      (with-db (db path)
        (dotimes (i 1000)
          (db-set db (format nil "k~a" i) (format nil "v~a" i))))
      (with-db (db path)
        (is (= 1000 (db-count db)))
        (is (equal "v777" (db-get db "k777" :as :string)))
        (is-true (db-remove db "k1"))
        (is (= 999 (db-count db)))))))

(test corrupt-header-signals
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "c.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-open-file (out (merge-pathnames "header.dat" path)
                           :direction :output :if-exists :supersede
                           :element-type '(unsigned-byte 8))
        (write-sequence (make-array 32 :element-type '(unsigned-byte 8)
                                       :initial-element 9)
                        out))
      (signals open-error (open-db path)))))

(test closed-databases-refuse-use
  (with-temp-directory (dir)
    (let ((db (open-db (merge-pathnames "x.vch/" dir))))
      (is-true (close-db db))
      (is (null (close-db db)))
      (signals invalid-argument (db-get db "k"))
      (signals invalid-argument (db-set db "k" "v"))
      (signals invalid-argument (db-count db)))))

(test concurrent-writers-are-consistent
  "Four threads write their own keys and race to add one shared key:
every key lands once and exactly one add of the shared key wins."
  (with-temp-db (db)
    (let* ((wins 0)
           (lock (bt:make-lock))
           (threads
             (loop for n below 4
                   collect
                   (let ((n n))
                     (bt:make-thread
                      (lambda ()
                        (dotimes (i 500)
                          (db-set db (format nil "t~a-~a" n i)
                                  (format nil "~a" i)))
                        (when (db-add db "shared" (format nil "~a" n))
                          (bt:with-lock-held (lock) (incf wins)))))))))
      (mapc #'bt:join-thread threads)
      (is (= 1 wins))
      (is (= 2001 (db-count db)))
      (dotimes (n 4)
        (is (equal "499" (db-get db (format nil "t~a-499" n)
                                 :as :string)))))))

(test growing-a-value-reuses-freed-space
  "300 appends of 1000 bytes: freed records are reused, so the heap grows
by a small multiple of the final value, not quadratically."
  (with-temp-db (db)
    (let ((before (db-size db))
          (chunk (make-array 1000 :element-type '(unsigned-byte 8)
                                  :initial-element 1)))
      (dotimes (i 300)
        (db-append db "log" chunk))
      (is (= 300000 (db-check db "log")))
      (is (< (- (db-size db) before) (* 20 300000))))))

(test values-of-varying-size-reuse-freed-space
  "Replacing a value with 500 different sizes from 600 to 1099 bytes
reuses freed records instead of allocating one per size."
  (with-temp-db (db)
    (let ((before (db-size db)))
      (loop for n from 600 below 1100
            do (db-set db "k" (make-string n :initial-element #\x)))
      (is (= 1099 (db-check db "k")))
      (is (< (- (db-size db) before) 50000)))))

(test every-operation-at-every-chain-position
  "Each operation on the head (e), middle (c) and tail (a) of a chain of
five keys sharing one digest; the other keys survive."
  (let ((*key-digest* (constant-digest 7))
        (keys '("a" "b" "c" "d" "e")))
    (dolist (target '("e" "c" "a"))
      (dolist (op '(:set :replace :append :check :seize :remove))
        (with-temp-db (db)
          (dolist (k keys)
            (db-set db k k))
          (ecase op
            (:set (is-true (db-set db target "new")))
            (:replace (is-true (db-replace db target "new")))
            (:append (is-true (db-append db target "+")))
            (:check (is (= 1 (db-check db target))))
            (:seize (is (equal target (db-seize db target :as :string))))
            (:remove (is-true (db-remove db target))))
          (is (equal (case op
                       ((:set :replace) "new")
                       (:append (concatenate 'string target "+"))
                       (:check target))
                     (db-get db target :as :string))
              "~a on ~a" op target)
          (dolist (k (remove target keys :test #'equal))
            (is (equal k (db-get db k :as :string))
                "~a on ~a lost ~a" op target k))
          (is (= (if (member op '(:seize :remove)) 4 5) (db-count db))))))))
