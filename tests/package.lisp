(defpackage #:vivace-cabinet-test
  (:use #:cl #:fiveam))

(in-package #:vivace-cabinet-test)

;; The copied tests name library internals unqualified, as vivace-graph's
;; test package imported them: import every VIVACE-CABINET symbol that
;; names a definition and does not clash with CL or FiveAM.  Loading
;; the library from source interns symbols no definition is on (lexical
;; variables, for one) that its FASLs do not, and a test helper named
;; like one of those would be defined on it, so they are left out and
;; the import set is the same either way (#5).
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun defined-p (symbol)
    "Does SYMBOL name a function, macro, variable, class or type?"
    (or (fboundp symbol)
        (boundp symbol)
        (find-class symbol nil)
        #+sbcl (sb-ext:valid-type-specifier-p symbol)))

  (defun importable-symbols ()
    "The library symbols to import: those naming a definition whose
name is not yet accessible here."
    (let ((test (find-package '#:vivace-cabinet-test))
          (lib (find-package '#:vivace-cabinet))
          (result '()))
      (do-symbols (s lib result)
        (when (and (eq (symbol-package s) lib)
                   (defined-p s)
                   (not (find-symbol (symbol-name s) test)))
          (push s result)))))

  (import (importable-symbols) '#:vivace-cabinet-test))

;; So a test helper named like a library internal cannot silently
;; redefine it, the definitions are noted now and checked once every
;; test file is loaded, in tests/imports.lisp (#5).

(defun imported-symbols ()
  "The VIVACE-CABINET symbols this package imported."
  (let ((lib (find-package '#:vivace-cabinet))
        (result '()))
    (do-symbols (s (find-package '#:vivace-cabinet-test) result)
      (when (eq (symbol-package s) lib)
        (push s result)))))

(defun definitions-of (symbol)
  "SYMBOL's global function, macro function and SETF function, or NILs."
  (list (and (fboundp symbol) (fdefinition symbol))
        (macro-function symbol)
        (and (fboundp `(setf ,symbol)) (fdefinition `(setf ,symbol)))))

(defun snapshot-imports ()
  "An alist of each imported library symbol and its definitions now."
  (mapcar (lambda (s) (cons s (definitions-of s))) (imported-symbols)))

(defvar *imported-definitions* (snapshot-imports)
  "The imported symbols' definitions as they were at import.")

(defun check-imports (&optional (snapshot *imported-definitions*))
  "Signal an error naming each imported library symbol whose function,
macro or SETF function is not the one in SNAPSHOT (by default, the one
at import): a test file redefined a library definition instead of
defining its own.  Reloading a library file after the tests trips it
too; reload the test system then."
  (let ((changed (loop for (s . defs) in snapshot
                       unless (every #'eq defs (definitions-of s))
                         collect s)))
    (when changed
      (error "Test files redefined library definitions: ~{~S~^, ~}"
             changed))))

(def-suite vivace-cabinet-suite :description "vivace-cabinet tests")
