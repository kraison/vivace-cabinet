(in-package #:vivace-cabinet-test)

(defun sorted (strings)
  (sort (copy-list strings) #'string<))

(def-db-test match-prefix-finds-keys
  (with-temp-db (db)
    (dolist (k '("apple" "apricot" "banana" "app" "ap" "b"))
      (db-set db k "v"))
    (is (equal '("app" "apple") (sorted (db-match-prefix db "app"
                                                         :as :string))))
    (is (equal '("ap" "app" "apple" "apricot")
               (sorted (db-match-prefix db "ap" :as :string))))
    (is (= 6 (length (db-match-prefix db ""))))
    (is (null (db-match-prefix db "zz")))
    (is (= 2 (length (db-match-prefix db "ap" :max 2))))
    (is (null (db-match-prefix db "ap" :max 0)))))

(def-tree-test match-prefix-keeps-key-order
  "In byte order the matches come in key order; under another order
every key is still checked."
  (with-temp-db (db)
    (dolist (k '("apple" "apricot" "banana" "app" "ap" "b"))
      (db-set db k "v"))
    (is (equal '("ap" "app" "apple" "apricot")
               (db-match-prefix db "ap" :as :string))))
  (with-temp-db (db :comparator (lambda (a b) (octets< b a)))
    (dolist (k '("apple" "apricot" "banana" "app" "ap" "b"))
      (db-set db k "v"))
    (is (equal '("apricot" "apple" "app" "ap")
               (db-match-prefix db "ap" :as :string)))))

(def-db-test match-regex-finds-keys
  (with-temp-db (db)
    (dolist (k '("cat" "category" "dog" "concat" "café"))
      (db-set db k "v"))
    (is (equal '("cat" "category")
               (sorted (db-match-regex db "^cat" :as :string))))
    (is (equal '("cat" "category" "concat")
               (sorted (db-match-regex db "cat" :as :string))))
    (is (equal '("café") (db-match-regex db "é$" :as :string)))
    (is (= 2 (length (db-match-regex db "cat" :max 2))))
    (signals invalid-argument (db-match-regex db "("))))

(def-db-test match-similar-orders-by-distance
  "Nearest first, then byte order; UTF compares characters, not bytes."
  (with-temp-db (db)
    (dolist (k '("kitten" "sitten" "sitting" "mitten" "kit" "café" "cafe"))
      (db-set db k "v"))
    (is (equal '("kitten" "mitten" "sitten")
               (db-match-similar db "kitten" 1 :as :string)))
    (is (equal '("kitten" "mitten")
               (db-match-similar db "kitten" 1 :max 2 :as :string)))
    (is (equal '("cafe" "café")
               (db-match-similar db "cafe" 1 :utf t :as :string)))
    (is (equal '("cafe") (db-match-similar db "cafe" 1 :as :string)))
    (signals invalid-argument (db-match-similar db "x" -1))))

(def-db-test matching-skips-nothing-on-bytes-that-are-not-utf-8
  "A key that is not UTF-8 reads as U+FFFD for a regex and for UTF
distances; byte distances use its bytes."
  (with-temp-db (db)
    (db-set db (octets-of 255 254 97) "v")
    (db-set db "a" "v")
    (is (= 2 (length (db-match-regex db "a$"))))
    (is (= 2 (length (db-match-similar db "a" 2 :utf t))))
    (is (equalp (list (octets-of 255 254 97))
                (db-match-prefix db (octets-of 255))))))
