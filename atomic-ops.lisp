;;;; Compare-and-swap and increments, each one visit (spec: API).  The
;;;; numbers are stored as Kyoto Cabinet stores them, so a conformance
;;;; check reads the same bytes (kcdb.h: increment, increment_double).

(in-package #:vivace-cabinet)

(alexandria:define-constant +int64-min+ (- (expt 2 63)))
(alexandria:define-constant +int64-max+ (1- (expt 2 63)))
(alexandria:define-constant +decunit+ 1000000000000000)

(defun %int64 (n)
  "N wrapped to a signed 64-bit integer, as C arithmetic wraps."
  (let ((u (ldb (byte 64 0) n)))
    (if (logbitp 63 u) (- u (expt 2 64)) u)))

(defun %int64-octets (n)
  "N as 8 big-endian bytes, two's complement."
  (let ((v (make-array 8 :element-type '(unsigned-byte 8)))
        (u (ldb (byte 64 0) n)))
    (dotimes (i 8 v)
      (setf (aref v i) (ldb (byte 8 (* 8 (- 7 i))) u)))))

(defun %octets-int64 (v start)
  (let ((u 0))
    (dotimes (i 8)
      (setf u (logior (ash u 8) (aref v (+ start i)))))
    (%int64 u)))

(defmethod db-cas ((db database) key old new)
  (let ((ov (and old (to-octets old)))
        (nv (and new (to-octets new)))
        (ok nil))
    (and (db-accept db key
                    (lambda (k v)
                      (declare (ignore k))
                      (cond (v (if (and ov (equalp v ov))
                                   (progn (setf ok t)
                                          (or nv :remove))
                                   :nop))
                            (ov :nop)
                            (t (setf ok t)
                               (or nv :nop)))))
         (or ok (%fail db :logic)))))

(defun %check-int64 (&rest numbers)
  (dolist (n numbers)
    (unless (typep n '(signed-byte 64))
      (%signal 'invalid-argument "not a 64-bit integer: ~s" n))))

(defmethod db-increment ((db database) key num &key (orig 0))
  (%check-int64 num orig)
  (let ((result nil))
    (and (db-accept
          db key
          (lambda (k v)
            (declare (ignore k))
            (cond ((and v (/= (length v) 8)) :nop)
                  (v (let ((onum (if (= orig +int64-max+)
                                     0
                                     (%octets-int64 v 0))))
                       (if (and (zerop num) (/= orig +int64-max+))
                           (progn (setf result onum) :nop)
                           (%int64-octets
                            (setf result (%int64 (+ num onum)))))))
                  ((= orig +int64-min+) :nop)
                  (t (%int64-octets
                      (setf result (if (= orig +int64-max+)
                                       num
                                       (%int64 (+ num orig))))))))
          :writable (or (/= num 0) (/= orig +int64-min+)))
         (or result (%fail db :logic)))))

;;; Doubles: computed with float traps masked, since infinities and NaN
;;; are values here, as in C.

(defun %nan-p (x) (sb-ext:float-nan-p x))
(defun %inf-p (x) (sb-ext:float-infinity-p x))

(defun %split-double (x)
  "X's integral part and its fraction in units of 10^-15, truncated
toward zero as C's modf does; NaN gives both the most negative 64-bit
integer, an infinity the most positive or negative and 0."
  (cond ((%nan-p x) (values +int64-min+ +int64-min+))
        ((%inf-p x) (values (if (plusp x) +int64-max+ +int64-min+) 0))
        (t (multiple-value-bind (integ frac) (truncate x)
             (values (%int64 integ) (truncate (* frac +decunit+)))))))

(defun %fixed-octets (integ fract)
  (concatenate 'octets (%int64-octets integ) (%int64-octets fract)))

(defun %fixed-value (integ fract)
  (+ (float integ 1d0) (/ (float fract 1d0) +decunit+)))

(defun %increment-full (v num orig)
  "Kyoto's visit_full: (values answer result) for the stored value V."
  (let ((set-p (and (%inf-p orig) (plusp orig))))
    (if (/= (length v) 16)
        (values :nop nil)
        (multiple-value-bind (linteg lfract)
            (if set-p
                (values 0 0)
                (values (%octets-int64 v 0) (%octets-int64 v 8)))
          (cond ((and (= linteg +int64-min+) (= lfract +int64-min+))
                 (values :nop nil))
                ((= linteg +int64-max+)
                 (values :nop sb-ext:double-float-positive-infinity))
                ((= linteg +int64-min+)
                 (values :nop sb-ext:double-float-negative-infinity))
                ((and (zerop num) (not set-p))
                 (values :nop (%fixed-value linteg lfract)))
                ((or (%nan-p num) (%inf-p num))
                 (multiple-value-bind (i f) (%split-double num)
                   (values (%fixed-octets i f) num)))
                (t
                 (multiple-value-bind (di df) (%split-double num)
                   (let ((i (%int64 (+ linteg di)))
                         (f (+ lfract df)))
                     (when (>= f +decunit+)
                       (setf i (%int64 (1+ i))
                             f (- f +decunit+)))
                     (values (%fixed-octets i f) (%fixed-value i f))))))))))

(defun %increment-empty (num orig)
  "Kyoto's visit_empty: (values answer result) for an absent key."
  (if (or (%nan-p orig) (and (%inf-p orig) (minusp orig)))
      (values :nop nil)
      (let ((n (if (%inf-p orig) num (+ num orig))))
        (multiple-value-bind (i f) (%split-double n)
          (values (%fixed-octets i f) n)))))

(defmethod db-increment-double ((db database) key num &key (orig 0d0))
  (let ((num (float num 1d0))
        (orig (float orig 1d0))
        (result nil))
    (sb-int:with-float-traps-masked (:overflow :invalid :inexact
                                     :divide-by-zero)
      (and (db-accept db key
                      (lambda (k v)
                        (declare (ignore k))
                        (multiple-value-bind (answer r)
                            (if v
                                (%increment-full v num orig)
                                (%increment-empty num orig))
                          (setf result r)
                          answer)))
           (if (or (null result) (%nan-p result))
               (%fail db :logic)
               result)))))
