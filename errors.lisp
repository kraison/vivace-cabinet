;;;; The API's conditions (spec: API).  Loaded before the substrate,
;;;; whose mapped files signal RESERVATION-EXHAUSTED (#6).

(in-package #:vivace-cabinet)

(define-condition vivace-cabinet-error (error)
  ((message :initarg :message :reader vivace-cabinet-error-message))
  (:report (lambda (c s)
             (write-string (vivace-cabinet-error-message c) s))))

(define-condition not-implemented (vivace-cabinet-error) ())
(define-condition invalid-argument (vivace-cabinet-error) ())
(define-condition open-error (vivace-cabinet-error) ())
(define-condition key-too-long (vivace-cabinet-error) ())
(define-condition reservation-exhausted (vivace-cabinet-error) ()
  (:documentation "A mapped file cannot grow past the address space
reserved for it at open; reopening the database reserves more."))

(defun %signal (class control &rest args)
  (error class :message (apply #'format nil control args)))
