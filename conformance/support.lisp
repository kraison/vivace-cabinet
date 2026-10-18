;;;; What the conformance tests share: a suite and fresh directories.

(in-package #:vivace-cabinet-conformance)

(defun fresh-directory (name)
  "A new directory under the temporary directory, named after NAME."
  (let ((dir (merge-pathnames
              (format nil "~a-~36r/" name
                      (random (expt 36 8) (make-random-state t)))
              (uiop:temporary-directory))))
    (if (probe-file dir)
        (fresh-directory name)
        (ensure-directories-exist dir))))

(fiveam:def-suite conformance-suite
  :description "vivace-cabinet against Kyoto Cabinet.")

(fiveam:in-suite conformance-suite)

(defmacro with-kyoto ((var file) &body body)
  "Bind VAR to a new Kyoto database in FILE, in a fresh directory."
  (let ((dir (gensym "DIR")))
    `(let ((,dir (fresh-directory "vc-kyoto")))
       (let ((,var (open-kyoto-db (merge-pathnames ,file ,dir)
                                  :mode '(:writer :create :truncate))))
         (unwind-protect (progn ,@body)
           (close-db ,var)
           (uiop:delete-directory-tree ,dir :validate t))))))

