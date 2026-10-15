;;;; Copied from vivace-graph globals.lisp at 853df62 (--only 17,49,54,118,127,128,129,130,131,134,137,138,139,140,160,162,334,407).
;;;; See docs/provenance.md.

(in-package #:vivace-cabinet)
;;; ECL threading-primitive capability gate.
;;;
;;; The custom rw-lock (rw-lock.lisp) uses a `(sleep 0.001)` busy-poll on ECL
;;; instead of condition-variable blocking, a workaround for ECL 21.2.1 bugs
;;; (mp:wait-on-semaphore blocking indefinitely, condition-variable-broadcast
;;; missing waiters, condition-variable-timedwait unreliable before 23.09.09).
;;; Those are fixed in modern ECL, where the poll's ~1 ms/handoff floor is pure
;;; overhead.  Push :GRAPH-DB-ECL-MODERN-MP when running ECL >= 23.9.9 so the
;;; rw-lock can take the blocking path; older ECL keeps the safe poll fallback.
;;;
;;; eval-when so the feature is set before rw-lock.lisp is read/compiled (it
;;; loads after globals per graph-db.asd).  Default-to-safe: any parse failure or
;;; older version leaves the feature absent (poll path).  Validate on the target
;;; ECL: a wrong gate would reintroduce the 21.2.1 hangs.
#+ecl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((parts (mapcar (lambda (s) (or (parse-integer s :junk-allowed t) 0))
                       (uiop:split-string (lisp-implementation-version)
                                          :separator "."))))
    (destructuring-bind (&optional (major 0) (minor 0) (patch 0) &rest rest) parts
      (declare (ignore rest))
      (when (or (> major 23)
                (and (= major 23) (or (> minor 9)
                                      (and (= minor 9) (>= patch 9)))))
        (pushnew :graph-db-ecl-modern-mp *features*)))))

;;; ECL synchronized-hash-table capability gate (GH #101).
;;;
;;; SBCL and CCL mark every concurrently-accessed table :SYNCHRONIZED / :SHARED.
;;; ECL arms were written without an equivalent because ECL once had none -- see
;;; the note in skip-list.lisp, which found rehash races and SIGSEGVs and guarded
;;; that table with an explicit lock instead.  Modern ECL does support it:
;;; measured on 26.5.5, eight threads x 20k inserts over a deliberately
;;; undersized table complete losslessly with :SYNCHRONIZED T and LIVELOCK
;;; without it.
;;;
;;; PROBED, not version-gated: the version at which ECL gained this is not
;;; documented anywhere we can check, and the oldest supported ECL (21.2.1) is
;;; not installed on any host here, so a threshold would be a guess.  Constructing
;;; a table is the direct question.  Default-to-safe: if the keyword is rejected
;;; the feature stays absent and those tables are exactly as they are today.
;;;
;;; LIMITATION: this proves the keyword is ACCEPTED, not that it is HONOURED.  An
;;; ECL that accepted and ignored it would probe true and stay racy -- no worse
;;; than today, but not fixed either.  26.5.5 is verified honoured by the test
;;; above; re-run it when raising the floor to a version between 21.2.1 and 26.5.5.
#+ecl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (ignore-errors (hash-table-p (make-hash-table :test 'eql :synchronized t)))
    (pushnew :graph-db-ecl-sync-hash *features*)))

(defvar *cache-enabled* t)

;; v2 (2026): MVCC node head grew 15 -> 31 bytes (commit-epoch + prev-pointer).
;; v3 (#166): type-id widened 16 -> 32 bits, head grew 31 -> 33 bytes, ve-key
;; 18 -> 20, vev-key 34 -> 36.  Old (v1/v2) graphs must be migrated via
;; MIGRATE-GRAPH (snapshot + replay); a v1 or v2 graph is refused at
;; OPEN-GRAPH, not silently misread.
(alexandria:define-constant +storage-version+     #x03)

(alexandria:define-constant +data-magic-byte+     #x17)

(alexandria:define-constant +lhash-magic-byte+    #x18)

(alexandria:define-constant +overflow-magic-byte+ #x19)

(alexandria:define-constant +config-magic-byte+   #x20)

(alexandria:define-constant +null-key+
  (make-array '(16) :element-type '(unsigned-byte 8) :initial-element 0)
   :test 'equalp)

(alexandria:define-constant +max-key+
  (make-array '(16) :element-type '(unsigned-byte 8) :initial-element 255)
   :test 'equalp)

(alexandria:define-constant +key-bytes+ 16)

(alexandria:define-constant +value-bytes+ 8)

(alexandria:define-constant +bucket-size+ 24)

(alexandria:define-constant +data-extent-size+ (* 1024 1024 100))

;; Each memory-mapped file reserves a virtual-address window up front (PROT_NONE,
;; MAP_NORESERVE — address space only, no committed memory) and maps the file
;; into the head of it.  Growth re-maps more of the file into the reserved window
;; with MAP_FIXED, so the base pointer never moves and concurrent readers never
;; fault or need a lock.  A file may grow up to its reservation; exceeding it
;; signals an error.  The reservation is proportional to the file's initial size
;; (with a floor) rather than a flat huge value: a graph has ~15-20 mapped files,
;; so a flat multi-GB reservation each would reserve enormous VA per graph (which
;; can fail on macOS).  See mmap.lisp.
(defparameter *mmap-reservation-multiplier* 8
  "Growth headroom: a mapped file reserves this multiple of its initial size.")

(defparameter *mmap-min-reservation* (* 1024 1024 1024)
  "Floor, in bytes, for a mapped file's virtual-address reservation.")

(alexandria:define-constant +skip-list+ 20)

(defparameter *max-locks* 10000)
