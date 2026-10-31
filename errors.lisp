;;;; The API's conditions (spec: API).  Loaded before the substrate,
;;;; whose mapped files signal RESERVATION-EXHAUSTED (#6).

(in-package #:vivace-cabinet)

(define-condition vivace-cabinet-error (error)
  ((message :initarg :message :reader vivace-cabinet-error-message))
  (:report (lambda (c s)
             (write-string (vivace-cabinet-error-message c) s))))

(define-condition not-implemented (vivace-cabinet-error) ())
(define-condition invalid-argument (vivace-cabinet-error) ())
(define-condition open-error (vivace-cabinet-error)
  ((cause :initarg :cause :initform nil :reader open-error-cause))
  (:documentation "A database could not be opened.  CAUSE is the
condition that stopped it when one did (an I/O error, a damaged file),
so a caller can tell a permission problem from corruption (#6); NIL
when the refusal was this library's own, such as no database there."))
(define-condition key-too-long (vivace-cabinet-error) ())
(define-condition system-error (vivace-cabinet-error) ()
  (:documentation "A file the copy and snapshot calls could not read,
write, create or rename; the message says which and why (#8)."))
(define-condition reservation-exhausted (vivace-cabinet-error) ()
  (:documentation "A mapped file cannot grow past the address space
reserved for it at open; reopening the database reserves more."))

(defun %signal (class control &rest args)
  (error class :message (apply #'format nil control args)))
