;;;; The Kyoto Cabinet-style API: conditions, generic functions, key
;;;; coercion and OPEN-DB (spec: API).  Engines implement the generics.

(in-package #:vivace-cabinet)

(define-condition vivace-cabinet-error (error)
  ((message :initarg :message :reader vivace-cabinet-error-message))
  (:report (lambda (c s)
             (write-string (vivace-cabinet-error-message c) s))))

(define-condition not-implemented (vivace-cabinet-error) ())
(define-condition invalid-argument (vivace-cabinet-error) ())
(define-condition open-error (vivace-cabinet-error) ())
(define-condition key-too-long (vivace-cabinet-error) ())

(defun %signal (class control &rest args)
  (error class :message (apply #'format nil control args)))

(defgeneric close-db (db))
(defgeneric db-set (db key value))
(defgeneric db-add (db key value))
(defgeneric db-replace (db key value))
(defgeneric db-append (db key value))
(defgeneric db-get (db key &key as))
(defgeneric db-check (db key))
(defgeneric db-seize (db key &key as))
(defgeneric db-remove (db key))
(defgeneric db-count (db))
(defgeneric db-size (db))
(defgeneric db-path (db))
(defgeneric db-clear (db))
(defgeneric db-synchronize (db &key hard))
(defgeneric db-error (db)
  (:documentation "Why the calling thread's last failed operation on DB
returned NIL: :DUPLICATE-RECORD, :NO-RECORD or :NO-PERMISSION, or
:SUCCESS if none has failed."))

(defun to-octets (x)
  "X as octets: octet vectors as they are, strings as UTF-8."
  (typecase x
    (octets x)
    (string (babel:string-to-octets x :encoding :utf-8))
    ((vector (unsigned-byte 8)) (coerce x 'octets))
    (t (%signal 'invalid-argument "not octets or a string: ~s" x))))

(defun check-as (as)
  (unless (member as '(:octets :string))
    (%signal 'invalid-argument "AS must be :OCTETS or :STRING: ~s" as)))

(defun from-octets (octets as)
  "OCTETS as AS, which CHECK-AS has accepted."
  (if (eq as :string)
      (babel:octets-to-string octets :encoding :utf-8)
      octets))

(defun %existing-type (dir args)
  "The type of the database in DIR, unless ARGS truncate it or its header
cannot be read (opening then reports that)."
  (let ((mode (getf args :mode)))
    (unless (and (listp mode) (member :writer mode) (member :truncate mode))
      (and (probe-file (%header-file dir))
           (ignore-errors (getf (%read-header dir) :type))))))

(defun open-db (path &rest args &key (type nil type-p) &allow-other-keys)
  "Open the database in directory PATH (a trailing / is added).  An
existing database opens as the type it is; TYPE (:HASH by default)
chooses what to create, and must match when given.  Other keywords:
OPEN-HASH-DB and OPEN-TREE-DB."
  (when (and type-p (not (member type '(:hash :tree))))
    (%signal 'invalid-argument "unknown database type ~s" type))
  (let* ((dir (uiop:ensure-directory-pathname (merge-pathnames path)))
         (found (%existing-type dir args)))
    (when (and found type-p (not (eq found type)))
      (%signal 'open-error "~a: a ~(~a~) database, not ~(~a~)"
               dir found type))
    (let ((args (alexandria:remove-from-plist args :type)))
      (ecase (or found type :hash)
        (:hash (apply #'open-hash-db dir args))
        (:tree (apply #'open-tree-db dir args))))))

(defmacro with-db ((var path &rest open-args) &body body)
  "Evaluate BODY with VAR bound to the open database at PATH; close it
afterwards."
  `(let ((,var (open-db ,path ,@open-args)))
     (unwind-protect (progn ,@body)
       (close-db ,var))))
