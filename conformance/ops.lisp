;;;; Random operations.  A small key space makes operations collide: keys
;;;; share prefixes and lie a few edits apart, and values come from a
;;;; small pool, so adds clash, swaps succeed and matches find something.

(in-package #:vivace-cabinet-conformance)

(defparameter *keys*
  (let ((ks '()))
    (dolist (a '("a" "b" "c"))
      (push a ks)
      (dolist (b '("a" "b" "c"))
        (push (concatenate 'string a b) ks)
        (dolist (c '("a" "b"))
          (push (concatenate 'string a b c) ks))))
    (nreverse ks)))

(defparameter *values* '("" "x" "y" "z" "xy" "yz" "xyz"))

(defparameter *integer-keys* '("n0" "n1" "n2"))

(defparameter *double-keys* '("d0" "d1" "d2"))

(defparameter *int64-min* (- (expt 2 63)))

(defparameter *int64-max* (1- (expt 2 63)))

(defun pick (list)
  (nth (random (length list)) list))

(defun maybe (x)
  (and (plusp (random 3)) x))

(defun some-keys ()
  (loop repeat (1+ (random 4)) collect (pick *keys*)))

(defun random-op (tree)
  "A random operation, (NAME . ARGS).  Cursor moves held across steps
only on a TreeDB: a HashDB's order is its own in each library."
  (let ((k (pick *keys*))
        (v (pick *values*)))
    (case (random (if tree 32 26))
      ((0 1 2) `(:set ,k ,v))
      (3 `(:add ,k ,v))
      (4 `(:replace ,k ,v))
      (5 `(:append ,k ,v))
      ((6 7) `(:get ,k))
      (8 `(:check ,k))
      (9 `(:seize ,k))
      ((10 11) `(:remove ,k))
      ((12 13) `(:cas ,k ,(maybe (pick *values*)) ,(maybe v)))
      ((14 15) `(:increment ,(pick (cons k *integer-keys*))
                            ,(- (random 7) 3)
                            ,(pick (list 0 0 10 *int64-max* *int64-min*))))
      ((16 17) `(:increment-double
                 ,(pick (cons k *double-keys*))
                 ,(pick '(0d0 0.5d0 -1.25d0 0.3d0 0.1d0 2d0))
                 ,(pick (list 0d0 0d0 1.5d0
                              sb-ext:double-float-positive-infinity
                              sb-ext:double-float-negative-infinity))))
      (18 (if (zerop (random 8)) '(:clear) '(:count)))
      (19 `(:set-bulk ,(loop repeat (1+ (random 4))
                             collect (cons (pick *keys*) (pick *values*)))
                      ,(zerop (random 2))))
      (20 `(:get-bulk ,(some-keys) ,(zerop (random 2))))
      (21 `(:remove-bulk ,(some-keys) ,(zerop (random 2))))
      ;; On a HashDB, which keys a :MAX keeps depends on its order.
      (22 `(:match-prefix ,(pick '("" "a" "ab" "b" "abc" "zz"))
                          ,(and tree (pick '(nil nil 1 2)))))
      (23 `(:match-regex ,(pick '("^a" "b$" "a.c" "^(ab|ba)" "[bc]+" "x"))
                         ,(and tree (pick '(nil nil 1 2)))))
      (24 `(:match-similar ,k ,(random 3) ,(zerop (random 2))
                           ,(pick '(nil nil 1 2))))
      (25 (if (zerop (random 2)) '(:walk) `(:jump-get ,k)))
      (26 `(:cursor-jump ,(maybe k)))
      (27 `(:cursor-jump-back ,(maybe k)))
      ((28 29) '(:cursor-step))
      (30 '(:cursor-step-back))
      (t (pick `((:cursor-get) (:cursor-get) (:cursor-set-value ,v)
                 (:cursor-remove) (:cursor-seize)))))))
