;;;; Copied from vivace-graph conditions.lisp at 853df62 (--only 31,39,170,178).
;;;; See docs/provenance.md.

(in-package #:vivace-cabinet)
(define-condition serialization-error (error)
  ((instance :initarg :instance)
   (reason :initarg :reason))
  (:report (lambda (error stream)
             (with-slots (instance reason) error
               (format stream "Serialization failed for ~a because of ~a."
                       instance reason)))))

(define-condition deserialization-error (error)
  ((instance :initarg :instance)
   (reason :initarg :reason))
  (:report (lambda (error stream)
             (with-slots (instance reason) error
               (format stream "Deserialization failed for ~a because of ~a."
                       instance reason)))))

(define-condition duplicate-key-error (error)
  ((instance :initarg :instance)
   (key :initarg :key))
  (:report (lambda (error stream)
             (with-slots (instance key) error
               (format stream "Duplicate key ~S in ~S."
                       key instance)))))

(define-condition nonexistent-key-error (error)
  ((instance :initarg :instance)
   (key :initarg :key))
  (:report (lambda (error stream)
             (with-slots (instance key) error
               (format stream "Nonexistent key ~S in ~S."
                       key instance)))))
