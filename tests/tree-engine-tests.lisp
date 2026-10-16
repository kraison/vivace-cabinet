(in-package #:vivace-cabinet-test)

(def-suite tree-engine-suite
  :description "TreeDB's ordered engines, tested on a bare heap."
  :in vivace-cabinet-suite)

(in-suite tree-engine-suite)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *engine-kinds* '(:bplus-tree :skip-list)
    "The engines each DEF-ENGINE-TEST runs on."))

(defvar *engine-kind* :bplus-tree)

(defun make-test-engine (heap)
  (ecase *engine-kind*
    (:bplus-tree (make-bplus-engine heap))
    (:skip-list (make-skip-list-engine heap))))

(defun open-test-engine (heap address)
  (ecase *engine-kind*
    (:bplus-tree (open-bplus-engine heap address))
    (:skip-list (open-skip-list-engine heap address))))

(defmacro def-engine-test (name &body body)
  "Define NAME/<engine> in TREE-ENGINE-SUITE for each of *ENGINE-KINDS*."
  `(progn
     ,@(loop for kind in *engine-kinds*
             collect `(test (,(alexandria:symbolicate name "/" kind)
                             :suite tree-engine-suite)
                        (let ((*engine-kind* ,kind))
                          ,@body)))))

(defmacro with-temp-engine ((var) &body body)
  "Bind VAR to a new engine of *ENGINE-KIND* in a temp heap."
  (let ((heap (gensym "HEAP")))
    `(with-temp-memory (,heap)
       (let ((,var (make-test-engine ,heap)))
         ,@body))))

(defun oct (string)
  "STRING as UTF-8 octets."
  (babel:string-to-octets string :encoding :utf-8))

(defun octets-of-length (n byte)
  (make-array n :element-type '(unsigned-byte 8) :initial-element byte))

(def-engine-test engine-put-get-delete
  (with-temp-engine (e)
    (is (null (engine-get e (oct "a"))))
    (engine-put e (oct "a") (oct "1"))
    (engine-put e (oct "b") (oct "2"))
    (is (equalp (oct "1") (engine-get e (oct "a"))))
    (engine-put e (oct "a") (oct "one"))
    (is (equalp (oct "one") (engine-get e (oct "a"))))
    (is (= 2 (engine-count e)))
    (is-true (engine-delete e (oct "a")))
    (is (null (engine-delete e (oct "a"))))
    (is (null (engine-get e (oct "a"))))
    (is (= 1 (engine-count e)))))

(def-engine-test engine-empty-key-and-value
  (with-temp-engine (e)
    (engine-put e (oct "") (oct ""))
    (engine-put e (oct "a") (oct "x"))
    (is (equalp (oct "") (engine-get e (oct ""))))
    (is (equalp (oct "") (engine-ceiling e nil nil)))
    (is (equalp (oct "a") (engine-ceiling e (oct "") t)))
    (is (equalp (oct "") (engine-floor e (oct "a") t)))))

(def-engine-test engine-orders-keys
  "Ceiling and floor, strict and not, walk the keys in unsigned byte
order; a key that is a prefix of another sorts first."
  (with-temp-engine (e)
    (let* ((*random-state* (sb-ext:seed-random-state 7))
           (keys (remove-duplicates
                  (loop repeat 1000
                        collect (let ((v (octets-of-length (1+ (random 6))
                                                           0)))
                                  (dotimes (i (length v) v)
                                    (setf (aref v i) (random 256)))))
                  :test #'equalp))
           (sorted (sort (copy-list keys) #'octets<)))
      (dolist (key keys)
        (engine-put e key (reverse key)))
      (is (= (length keys) (engine-count e)))
      (is (equalp sorted
                  (loop for key = (engine-ceiling e nil nil)
                          then (engine-ceiling e key t)
                        while key collect key)))
      (is (equalp (reverse sorted)
                  (loop for key = (engine-floor e nil nil)
                          then (engine-floor e key t)
                        while key collect key)))
      (multiple-value-bind (key value) (engine-ceiling e (first sorted) nil)
        (is (equalp (first sorted) key))
        (is (equalp (reverse (first sorted)) value)))
      (is (null (engine-ceiling e (car (last sorted)) t)))
      (is (null (engine-floor e (first sorted) t))))))

(def-engine-test engine-ceiling-and-floor-of-absent-keys
  (with-temp-engine (e)
    (dolist (s '("b" "d" "f"))
      (engine-put e (oct s) (oct s)))
    (is (equalp (oct "d") (engine-ceiling e (oct "c") nil)))
    (is (equalp (oct "d") (engine-ceiling e (oct "c") t)))
    (is (equalp (oct "b") (engine-floor e (oct "c") nil)))
    (is (equalp (oct "d") (engine-floor e (oct "dd") t)))
    (is (equalp (oct "b") (engine-ceiling e (oct "") nil)))
    (is (null (engine-ceiling e (oct "g") nil)))
    (is (null (engine-floor e (oct "a") nil)))
    (is (equalp (oct "f") (engine-floor e (oct "zzz") nil)))))

(def-engine-test engine-holds-mixed-sizes
  "400 records, keys of 2 to 1024 bytes and values up to 50 KB, in random
order; then half of them removed."
  (with-temp-engine (e)
    (let* ((*random-state* (sb-ext:seed-random-state 11))
           (records
             (loop for i below 400
                   collect (let ((k (octets-of-length (+ 2 (random 1023))
                                                      7)))
                             (setf (aref k 0) (ldb (byte 8 8) i)
                                   (aref k 1) (ldb (byte 8 0) i))
                             (cons k (octets-of-length
                                      (nth (mod i 5) '(0 10 1000 3000 50000))
                                      (mod i 256)))))))
      (dolist (r (alexandria:shuffle (copy-list records)))
        (engine-put e (car r) (cdr r)))
      (is (= 400 (engine-count e)))
      (is (every (lambda (r) (equalp (cdr r) (engine-get e (car r))))
                 records))
      (loop for r in records
            for i from 0
            when (evenp i) do (engine-delete e (car r)))
      (is (= 200 (engine-count e)))
      (is (every (lambda (r) (equalp (cdr r) (engine-get e (car r))))
                 (loop for r in records
                       for i from 0
                       when (oddp i) collect r))))))

(def-engine-test engine-reopens-at-its-address
  (with-temp-memory (heap)
    (let ((e (make-test-engine heap)))
      (dotimes (i 50)
        (engine-put e (oct (format nil "k~2,'0d" i)) (oct "v")))
      (engine-close e)
      (let ((again (open-test-engine heap (engine-address e))))
        (is (= 50 (engine-count again)))
        (is (equalp (oct "k00") (engine-ceiling again nil nil)))
        (is (equalp (oct "k49") (engine-floor again nil nil)))))))

(def-engine-test engine-copies-keys-and-values
  "Changing a vector after storing it, or one the engine returned, leaves
the record as it was."
  (with-temp-engine (e)
    (let ((key (oct "key"))
          (value (oct "value")))
      (engine-put e key value)
      (fill key 0)
      (fill value 0)
      (let ((got (engine-get e (oct "key"))))
        (is (equalp (oct "value") got))
        (fill got 0))
      (is (equalp (oct "value") (engine-get e (oct "key")))))))

(test bplus-engine-key-limit
  "A key over a quarter page signals KEY-TOO-LONG; a quarter page is fine."
  (with-temp-memory (heap)
    (let ((e (make-bplus-engine heap)))
      (finishes (engine-put e (octets-of-length 1024 1) (oct "v")))
      (signals key-too-long (engine-put e (octets-of-length 1025 1)
                                        (oct "v"))))))

(test bplus-engine-frees-out-of-line-values
  "Replacing or removing a value kept out of line frees its record."
  (with-temp-memory (heap)
    (let ((e (make-bplus-engine heap))
          (big (octets-of-length 5000 3)))
      (engine-put e (oct "k") big)
      (engine-put e (oct "k") big)
      (let ((before (read-memory-pointer heap)))
        (dotimes (i 50)
          (engine-put e (oct "k") big))
        (engine-delete e (oct "k"))
        (engine-put e (oct "k") big)
        (is (= before (read-memory-pointer heap)))))))
