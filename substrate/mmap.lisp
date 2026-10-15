;;;; Copied from vivace-graph mmap.lisp at 853df62 (--only 3,4,8,10,41,43,45,48,69,70,81,87,88,98,103,110,129,135,138,220,226,250,542,550,559,567,574,580,584).
;;;; See docs/provenance.md.

(in-package #:vivace-cabinet)
#+lispworks(deftype word () '(unsigned-byte 64))

#+ecl(deftype word () '(unsigned-byte 64))

(deftype uint64 () '(integer 0 18446744073709551615))

(defstruct (mapped-file
             (:conc-name m-)
             (:predicate mapped-file-p))
  path pointer fd
  ;; Length, in bytes, of the virtual-address window reserved for this mapping
  ;; (computed at open from the file's size then: see *mmap-reservation-multiplier*
  ;; and *mmap-min-reservation*).  POINTER is fixed at the base of that window
  ;; for the life of the mapping: the file is mapped into the head, and
  ;; extend-mapped-file maps more of it into the reserved tail with MAP_FIXED.
  ;; Because POINTER never moves and the reservation is never unmapped until
  ;; close, concurrent readers never fault and need no lock.  See
  ;; docs/mmap-remap-race-plan.md.
  ;;
  ;; RESERVED-SIZE can GROW without POINTER moving:
  ;; EXTEND-RESERVATION-IN-PLACE (below) claims the address range immediately
  ;; after the window, which is the cheap way a vector segment grows past its
  ;; reservation.  Readers are unaffected -- there is nothing for them to
  ;; observe.
  ;;
  ;; ONE EXCEPTION MOVES POINTER, and it is not a general one:
  ;; RELOCATE-VECTOR-SEGMENT-MAPPING (below) does move POINTER, for a vector
  ;; segment only, because a segment -- unlike the heap and the linear hash --
  ;; holds an rw-lock over every one of its readers.  It is the FALLBACK for
  ;; when the adjacent range above cannot be claimed.  Read its docstring
  ;; before calling it from anywhere else; the short version is: don't.
  (reserved-size 0 :type integer))

;;; Diagnostic: count SEGV-retries in the accessor :around methods.  With the
;;; stable-address mapping no remap moves the pointer, so this must stay 0 under
;;; concurrency; the regression test asserts it.  The :around handlers remain a
;;; cheap backstop.  Plain incf (a racy count is fine for a diagnostic).
(defparameter *mmap-segv-retries* 0)

(defstruct mpointer mmap loc)

(defmethod mapped-file-length ((mapped-file mapped-file))
  (%posix-file-size-fd (m-fd mapped-file)))

(defmethod set-byte :around (mf offset byte)
  (handler-case
      (call-next-method)
    #+sbcl
    (sb-kernel::memory-fault-error (c)
      (incf *mmap-segv-retries*)
      (log:error "SEGV: GOT ~A in ~A; retrying." c mf)
      (set-byte mf offset byte))
    #+ccl
    (CCL::INVALID-MEMORY-ACCESS (c)
      (incf *mmap-segv-retries*)
      (log:error "SEGV: GOT ~A in ~A; retrying." c mf)
      (set-byte mf offset byte))
    #+ecl
    (ext:segmentation-violation (c)
      (incf *mmap-segv-retries*)
      (log:error "SEGV: GOT ~A in ~A; retrying." c mf)
      (set-byte mf offset byte))))

;; Raw write.  Safe lock-free because the mapping's base pointer is stable for
;; its lifetime (see mmap-file / extend-mapped-file).
(declaim (inline %set-byte))

(defun %set-byte (mapped-file offset byte)
  (declare (type word offset))
  (declare (type (integer 0 255) byte))
  #+ecl
  (ffi:c-inline ((m-pointer mapped-file) offset byte)
                (:pointer-void :cl-index :unsigned-byte) :unsigned-byte
                "*((unsigned char *)(((char*)#0)+#1))=#2"
                :one-liner t)
  #-ecl
  (setf (cffi:mem-aref (m-pointer mapped-file) :unsigned-char offset) byte))

(defmethod set-byte ((mapped-file mapped-file) offset byte)
  ;;(log:debug "SET-BYTE: ~A ADDR ~A TO ~A" (m-path mapped-file) offset byte)
  ;; Lock-free: the pointer is stable (see mmap-file / extend-mapped-file).
  (%set-byte mapped-file offset byte))

;; Raw read.  Safe lock-free because the mapping's base pointer is stable.
(declaim (inline %get-byte))

(defun %get-byte (mapped-file offset)
  (declare (type word offset))
  #+ecl
  (ffi:c-inline ((m-pointer mapped-file) offset)
                (:pointer-void :cl-index) :unsigned-byte
                "*((unsigned char *)(((char*)#0)+#1))"
                :one-liner t)
  #-ecl
  (cffi:mem-aref (m-pointer mapped-file) :unsigned-char offset))

(defmethod get-byte ((mapped-file mapped-file) offset)
  ;; Lock-free: the pointer is stable (see mmap-file / extend-mapped-file).
  (%get-byte mapped-file offset))

(defmethod get-bytes ((mapped-file mapped-file) offset length)
  (declare (type word offset length))
  (let ((vec (make-byte-vector length)))
    (dotimes (i length)
      (setf (aref vec i) (%get-byte mapped-file (+ i offset))))
    vec))

(defmethod set-bytes :around (mf vec offset length)
  (handler-case
      (call-next-method)
    #+sbcl
    (sb-kernel::memory-fault-error (c)
      (incf *mmap-segv-retries*)
      (log:error "SEGV: GOT ~A in ~A; retrying." c mf)
      (set-bytes mf vec offset length))
    #+ccl
    (CCL::INVALID-MEMORY-ACCESS (c)
      (incf *mmap-segv-retries*)
      (log:error "SEGV: GOT ~A in ~A; retrying." c mf)
      (set-bytes mf vec offset length))
    #+ecl
    (ext:segmentation-violation (c)
      (incf *mmap-segv-retries*)
      (log:error "SEGV: GOT ~A in ~A; retrying." c mf)
      (set-bytes mf vec offset length))))

(defmethod set-bytes ((mapped-file mapped-file) vec offset length)
  (declare (type word offset length))
  (dotimes (i length)
    (%set-byte mapped-file (+ i offset) (aref vec i)))
  vec)

(defmethod size-of ((mmap mapped-file))
  (%file-size (m-path mmap)))

(defun mmap-file (file &key (create-p t) (size (* 4096 25600)) reservation)
  "Use mmap() to map FILE into memory.

Reserves a virtual-address window (PROT_NONE, anonymous, MAP_NORESERVE — address
space only) and maps the file into the head of it with MAP_FIXED.  The returned
mapped-file's POINTER is the base of that window, and GROWTH NEVER MOVES IT:
EXTEND-MAPPED-FILE grows by re-mapping the file into the reserved window, so
concurrent readers never fault.  The file may grow up to the reservation, which
defaults to *MMAP-RESERVATION-MULTIPLIER* times SIZE (floored at
*MMAP-MIN-RESERVATION*); pass RESERVATION to override.

ONE THING CAN MOVE POINTER, and it is not growth:
RELOCATE-VECTOR-SEGMENT-MAPPING re-reserves a larger window and re-maps the
file into it, which is how a VECTOR SEGMENT grows past its reservation.  It is
callable ONLY by a subsystem that can exclude every reader of the mapping for
the duration (today: the vector segment, under its own rw-lock) — read that
function's contract before assuming a base pointer you cached is still valid.
For every other mapped file in this system the reservation is a hard ceiling
and POINTER is stable for the life of the mapping."
  (log:debug "Opening mmap ~A" file)
  (when (and (not create-p) (not (probe-file file)))
    (error "mmap-file: ~A does not exist and create-p is not true." file))
  (let ((fd (%posix-open
             file
             (if create-p
                 (logior +o-creat+ +o-rdwr+)
                 +o-rdwr+)))
        (base nil)
        (reserved nil)
        (ok nil))
    ;; Unwind cleanly on any failure once FD is open: an interrupted create
    ;; step, or a MAP_FAILED file-map (the second %POSIX-MMAP below) after the
    ;; anonymous window was already reserved, must not leak the fd or the VA
    ;; window.  Before this, a failed file-map left both open -- ordinarily a
    ;; ~1 GiB leak per retry, now up to *SEGMENT-MIN-RESERVATION* (16 GiB) for
    ;; a vector segment, so a retry loop against a nearly-full filesystem or
    ;; address space could exhaust it far faster than before.
    (unwind-protect
        (progn
          (when create-p
            (%posix-extend-file-backing fd size)
            ;; Belt-and-suspenders: set the mode explicitly to #o640 (owner rw,
            ;; group r) so database files are reopenable without being
            ;; world-accessible, even if the open() mode argument is not
            ;; honored on some platform.
            (%posix-fchmod fd #o640))
          ;; Make sure the file size is set right!
          (setq size (%posix-file-size-fd fd))
          (setq reserved (max (or reservation
                                  (* *mmap-reservation-multiplier* size))
                              *mmap-min-reservation*
                              size))
          ;; Reserve the address window with no access and no backing.
          (setq base (%posix-mmap
                      (cffi:null-pointer)
                      reserved
                      +prot-none+
                      (logior +map-private+
                              +map-anonymous+
                              +map-noreserve+)
                      -1
                      0))
          ;; Map the file over the head of the reservation (replaces the
          ;; PROT_NONE pages for [base, base+size); MAP_FIXED keeps the addr).
          (let* ((pointer (%posix-mmap
                           base
                           size
                           (logior +prot-read+ +prot-write+)
                           (logior +map-shared+ +map-fixed+)
                           fd
                           0))
                 (path (truename file))
                 (mf (make-mapped-file :path path
                                       :fd fd
                                       :pointer pointer
                                       :reserved-size reserved)))
            (setf ok t)
            mf))
      (unless ok
        (when base (ignore-errors (%posix-munmap base reserved)))
        (ignore-errors (%posix-close fd))))))

(defmethod sync-region ((mapped-file mapped-file) &key addr length
                        (sync +ms-sync+))
  (%posix-msync (or addr (m-pointer mapped-file))
                (or length (mapped-file-length mapped-file))
                sync))

(defmethod munmap-file ((mapped-file mapped-file) &key (save-p nil)
                        (sync +ms-sync+))
  (when save-p
    ;;(log:debug "Calling msync on ~S" mapped-file)
    ;; Only the file-backed head is dirty/syncable, not the reserved tail.
    (%posix-msync (m-pointer mapped-file)
                  (mapped-file-length mapped-file)
                  sync))
  ;;(log:debug "Calling munmap on ~S" mapped-file)
  ;; Release the whole reserved window (file mapping + PROT_NONE tail).
  (%posix-munmap (m-pointer mapped-file)
                 (if (plusp (m-reserved-size mapped-file))
                     (m-reserved-size mapped-file)
                     (mapped-file-length mapped-file)))
  (%posix-close (m-fd mapped-file))
  (setf (m-pointer mapped-file) nil)
  nil)

;; One platform-independent implementation: there is no mremap and no munmap of
;; the live region.  We grow the backing file, then re-map the whole file at the
;; SAME base address (MAP_FIXED, offset 0).  MAP_FIXED replacement is atomic, so
;; a concurrent reader of an existing offset never observes an unmapped address,
;; and the base pointer is unchanged — no lock and no SEGV.  See
;; docs/mmap-remap-race-plan.md.
(defmethod extend-mapped-file ((mapped-file mapped-file) (length integer))
  (log:debug "EXTENDING MMAP ~A" mapped-file)
  (let* ((old-len (mapped-file-length mapped-file))
         (new-len (+ old-len length)))
    (when (> new-len (m-reserved-size mapped-file))
      (error "mmap reservation exhausted for ~A: need ~D bytes, reserved ~D.~%~
The reservation is computed at open from the file's size then, so reopening the ~
graph recomputes it against the now-larger file and grants fresh headroom.  To ~
raise it up front, bind GRAPH-DB::*MMAP-RESERVATION-MULTIPLIER* or ~
GRAPH-DB::*MMAP-MIN-RESERVATION* (or MAKE-GRAPH's heap/index size) before ~
opening the graph.  Exception: a VECTOR SEGMENT never reaches this error at ~
all -- its floor is GRAPH-DB:*SEGMENT-MIN-RESERVATION*, and %SEG-GROW ~
re-reserves and relocates its mapping (under the segment's write lock) before ~
calling this, so for segments the reservation is not a ceiling.  Only if that ~
relocation is disabled or fails does a segment signal, and it signals ~
VECTOR-SEGMENT-CAPACITY-EXHAUSTED, not this."
             (m-path mapped-file) new-len (m-reserved-size mapped-file)))
    ;; Extend the backing file first so the newly mapped pages have storage.
    (%posix-extend-file-backing (m-fd mapped-file) new-len)
    ;; Re-map [0, new-len) over the reserved window at the same base.
    (%posix-mmap (m-pointer mapped-file)
                 new-len
                 (logior +prot-read+ +prot-write+)
                 (logior +map-shared+ +map-fixed+)
                 (m-fd mapped-file)
                 0)
    mapped-file))

(defmethod serialize-uint64 ((mf mapped-file) int offset)
  (declare (type word int offset))
  ;;(log:debug "MMAP: SERIALIZING UINT64 ~A TO ADDR ~A" int offset)
  (dotimes (i 8)
    (%set-byte mf offset (ldb (byte 8 (* i 8)) int))
    (incf offset))
  offset)

(defmethod deserialize-uint64 ((mf mapped-file) offset)
  "Decode a UINT64."
  (declare (type word offset))
  (let ((int 0))
    (declare (type word int))
    (dotimes (i 8)
      (setq int (dpb (%get-byte mf (+ i offset)) (byte 8 (* i 8)) int)))
    int))

(defmethod deserialize-uint64 ((array array) offset)
  "Decode a UINT64."
  (let ((int 0))
    (declare (type word int))
    (dotimes (i 8)
      (setq int (dpb (aref array (+ i offset)) (byte 8 (* i 8)) int)))
    int))

(defmethod incf-uint64 ((mf mapped-file) offset)
  (declare (type word offset))
  (let ((int (deserialize-uint64 mf offset)))
    (incf int)
    (serialize-uint64 mf int offset)
    int))

(defmethod decf-uint64 ((mf mapped-file) offset)
  (declare (type word offset))
  (let ((int (deserialize-uint64 mf offset)))
    (serialize-uint64 mf (decf int) offset)
    int))

(defmethod serialize-pointer ((mf mapped-file) pointer offset)
  ;;(log:debug "SERIALIZING POINTER ~A TO ADDR ~A" pointer offset)
  (serialize-uint64 mf pointer offset))

(defmethod deserialize-pointer ((mf mapped-file) offset)
  ;;(log:debug "DESERIALIZING POINTER AT ADDR ~A" offset)
  (deserialize-uint64 mf offset))
