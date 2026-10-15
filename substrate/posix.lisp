;;;; Copied from vivace-graph posix.lisp at 853df62 (--only 28,33,34,35,37,38,49,50,51,53,54,55,56,57,84,87,90,96,100,103,156,159,165,177,187,200,216,219,235,267).
;;;; See docs/provenance.md.

(in-package #:vivace-cabinet)
;;; ---------------------------------------------------------------------------
;;; Constants.  open(2) flags, lseek(2) whence, mmap(2) prot/flags, msync flags.
;;; Several differ between Darwin and Linux/Bionic.  CRUCIAL for cross-compiling:
;;; these are evaluated at COMPILE time against the HOST's *features*, so a plain
;;; #+darwin gate would bake Mac values into an Android (Linux) target.  Pick the
;;; Linux/Bionic values whenever the TARGET is Linux-like: either we're building
;;; for Android (the build pushes :graph-db-android) or the host itself isn't
;;; Darwin.  Only a native Darwin build (no android flag) takes the Darwin values.
;;; ---------------------------------------------------------------------------
(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (or (member :graph-db-android *features*)
            (not (member :darwin *features*)))
    (pushnew :graph-db-posix-linux *features*)))

(defconstant +o-rdonly+ 0)

(defconstant +o-rdwr+   2)

(defconstant +o-creat+  #+graph-db-posix-linux #o100 #-graph-db-posix-linux #x0200)

(defconstant +seek-set+ 0)

(defconstant +seek-end+ 2)

(defconstant +prot-none+  0)

(defconstant +prot-read+  1)

(defconstant +prot-write+ 2)

(defconstant +map-shared+    #x01)

(defconstant +map-private+   #x02)

(defconstant +map-fixed+     #x10)

(defconstant +map-anonymous+ #+graph-db-posix-linux #x20   #-graph-db-posix-linux #x1000)

(defconstant +map-noreserve+ #+graph-db-posix-linux #x4000 #-graph-db-posix-linux #x40)

;; MAP_FIXED_NOREPLACE (Linux 4.17+).  "Place the mapping at exactly ADDR, or
;; fail with EEXIST" -- the opposite of MAP_FIXED, which places it there by
;; EVICTING whatever was already mapped.  Used by
;; EXTEND-RESERVATION-IN-PLACE (mmap.lisp) to claim the range immediately after
;; a reservation.
;;
;; Darwin has no equivalent, so it contributes NO BIT there (0).  That is
;; deliberate and it is SAFE.  Do NOT be tempted to substitute +MAP-FIXED+ as a
;; fallback: MAP_FIXED would clobber whatever occupies the range, which is the
;; one outcome this whole mechanism exists to avoid.
;;
;; An unknown flag bit is simply IGNORED by the kernel, which leaves ADDR as an
;; ADVISORY HINT -- it does NOT degrade to MAP_FIXED.  Measured on two kernels
;; (a page mapped with a sentinel, then reclaimed at the same address with this
;; flag):
;;
;;   Linux 5.15.0-179 -- flag honoured: rejected with EEXIST, sentinel intact.
;;   Linux 4.15.0-213 -- flag ignored:  mapping landed at a DIFFERENT address,
;;                                      sentinel intact.
;;
;; So the flag is an efficiency win where it exists (a clean rejection instead
;; of a map-then-unmap), and the actual SAFETY property everywhere -- Darwin,
;; pre-4.17 Linux, 4.17+ Linux alike -- is the caller's post-hoc check that the
;; address it got back is exactly the address it asked for.  No version gate is
;; needed or wanted.
(defconstant +map-fixed-noreplace+
  #+graph-db-posix-linux #x100000 #-graph-db-posix-linux 0)

(defconstant +ms-sync+       #+graph-db-posix-linux #x04   #-graph-db-posix-linux #x10) ; Linux 4, Darwin 16

;; (void *)-1 as an unsigned 64-bit address: mmap's failure sentinel (MAP_FAILED).
(defconstant +map-failed-address+ (1- (expt 2 64)))

;;; ---------------------------------------------------------------------------
;;; Syscall wrappers.  size_t -> :unsigned-long, off_t -> :long, mode_t ->
;;; :unsigned-int (all correct on the LP64 targets above).
;;; ---------------------------------------------------------------------------
(declaim (inline %posix-close %posix-lseek %posix-fchmod %posix-munmap
                 %posix-msync))

;; %POSIX-OPEN's #+ecl c-inline needs open(2)'s declaration.
#+ecl
(ffi:clines "#include <fcntl.h>")

(defun %posix-open (path flags &optional (mode #o640))
  "open(2).  PATH is a Lisp pathname/string.  Returns the fd, signals on error.

MODE rides CFFI's VARARGS path, not a plain FOREIGN-FUNCALL.  open(2) is
`int open(const char *, int, ...)`, and Apple arm64 passes a variadic argument
differently from a fixed one, so a fixed-argument MODE is read from somewhere
the callee never wrote: the file is created with an arbitrary mode, and a
different one each run (0140 and 0200 both observed for this 0640 default).
When that mode omits owner read/write the next ordinary OPEN of the path fails
EACCES -- which is every graph in the image, since the type registry (#186) and
the system clock (#182) both create their files here.  GH #218.

ECL cannot use the varargs form: CFFI's ECL backend drops the variadic MODE
on Darwin/arm64 too (files created mode 000), so ECL compiles a direct C call
instead -- correct ABI by construction.  GH #306."
  (let ((fd #+ecl (ffi:c-inline ((namestring path) flags mode)
                                (:cstring :int :int) :int
                                "open(#0,#1,#2)" :one-liner t)
            #-ecl (cffi:foreign-funcall-varargs
                   "open"
                   (:string (namestring path) :int flags)
                   :unsigned-int mode
                   :int)))
    (when (minusp fd)
      (error "posix open failed for ~A (flags ~D)" path flags))
    fd))

(defun %posix-close (fd)
  (cffi:foreign-funcall "close" :int fd :int))

(defun %posix-lseek (fd offset whence)
  (let ((r (cffi:foreign-funcall "lseek" :int fd :long offset :int whence :long)))
    (when (minusp r)
      (error "posix lseek failed for fd ~D (offset ~D, whence ~D)" fd offset whence))
    r))

(defun %posix-write (fd ptr count)
  "write(2). FD is an open file descriptor, PTR is a foreign pointer, COUNT is size_t.
Returns the number of bytes written, or signals an error on failure."
  (let ((r (cffi:foreign-funcall "write"
                                 :int fd
                                 :pointer ptr
                                 :unsigned-long count
                                 :long)))
    (when (minusp r)
      (error "posix write failed for fd ~D (count ~D)" fd count))
    r))

(defun %posix-extend-file-backing (fd new-length)
  "Extends the file backed by FD to NEW-LENGTH bytes by seeking to (1- NEW-LENGTH) and writing a zero byte.
Signals an error if lseek or write fails (e.g. ENOSPC)."
  (%posix-lseek fd (1- new-length) +seek-set+)
  (cffi:with-foreign-string (null-buf (string (code-char 0)))
    (let ((written (%posix-write fd null-buf 1)))
      (unless (= written 1)
        (error "posix write failed to extend file fd ~D to ~D bytes (wrote ~D bytes)"
               fd new-length written)))))

(defun %posix-fchmod (fd mode)
  (cffi:foreign-funcall "fchmod" :int fd :unsigned-int mode :int))

(defun %posix-mmap (addr length prot flags fd offset)
  "mmap(2).  ADDR is a foreign pointer (or null-pointer).  Returns the mapping
pointer, signals on MAP_FAILED."
  (let ((p (cffi:foreign-funcall "mmap"
                                 :pointer addr
                                 :unsigned-long length
                                 :int prot
                                 :int flags
                                 :int fd
                                 :long offset
                                 :pointer)))
    (when (= (cffi:pointer-address p) +map-failed-address+)
      (error "posix mmap failed (len=~D fd=~D prot=~D flags=~D)"
             length fd prot flags))
    p))

(defun %posix-munmap (addr length)
  (cffi:foreign-funcall "munmap" :pointer addr :unsigned-long length :int))

(defun %posix-msync (addr length flags)
  (cffi:foreign-funcall "msync" :pointer addr :unsigned-long length :int flags :int))

;;; ---------------------------------------------------------------------------
;;; File size without stat(2).  Avoids mirroring the platform-specific struct
;;; stat layout (st_size offset differs across Darwin/glibc/Bionic): for an open
;;; fd, lseek to SEEK_END returns the size; for a path, CL file-length suffices.
;;; ---------------------------------------------------------------------------
(defun %posix-file-size-fd (fd)
  (%posix-lseek fd 0 +seek-end+))

(defun %file-size (path)
  (with-open-file (s path :element-type '(unsigned-byte 8) :if-does-not-exist :error)
    (file-length s)))
