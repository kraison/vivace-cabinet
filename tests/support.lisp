(in-package #:vivace-cabinet-test)

;;; Fixtures adapted from vivace-graph tests/suite.lisp at 853df62.

(defun make-temp-directory ()
  "A fresh, empty directory under the system temp directory."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames
               (format nil "vivace-cabinet-test-~36r"
                       (random (expt 36 10) (make-random-state t)))
               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-temp-directory ((var) &body body)
  "Bind VAR to a fresh directory, run BODY, then delete the tree."
  `(let ((,var (make-temp-directory)))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,var :validate t
                                        :if-does-not-exist :ignore))))

(defmacro with-temp-memory ((var &key (size '(* 1024 1024 64))) &body body)
  "Bind VAR to a fresh MEMORY backed by a temp file, run BODY, then close
it and remove the directory."
  (let ((dir (gensym "DIR")))
    `(with-temp-directory (,dir)
       (let ((,var (create-memory
                    (namestring (merge-pathnames "heap.dat" ,dir)) ,size)))
         (unwind-protect (progn ,@body)
           (ignore-errors (close-memory ,var)))))))

(defun gen-id ()
  "A random 16-byte key whose first byte is non-zero: all-zero keys mark
empty slots in the linear hash.  (vivace-graph used a v4 UUID.)"
  (let ((id (make-array 16 :element-type '(unsigned-byte 8))))
    (dotimes (i 16)
      (setf (aref id i) (random 256)))
    (setf (aref id 0) (1+ (random 255)))
    id))

(defmacro with-temp-lhash ((var &rest make-args) &body body)
  "Bind VAR to a fresh LHASH in a temp directory, run BODY, then close it
and remove the directory.  MAKE-ARGS go to MAKE-LHASH."
  (let ((dir (gensym "DIR")))
    `(with-temp-directory (,dir)
       (let ((,var (make-lhash :location ,dir ,@make-args)))
         (unwind-protect (progn ,@body)
           (ignore-errors (close-lhash ,var)))))))
