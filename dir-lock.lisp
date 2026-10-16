;;;; Advisory locks on a database directory: one handle writes or several
;;;; read, as Kyoto Cabinet locks its database file.  flock(2).

(in-package #:vivace-cabinet)

(alexandria:define-constant +lock-sh+ 1)
(alexandria:define-constant +lock-ex+ 2)
(alexandria:define-constant +lock-nb+ 4)

(defun lock-directory (dir writer)
  "Lock DIR without waiting: exclusive for a WRITER, else shared.  Returns
the fd holding the lock, or NIL when another open file holds a
conflicting one, in this process or another."
  (let ((fd (%posix-open dir +o-rdonly+)))
    (if (zerop (cffi:foreign-funcall
                "flock" :int fd
                :int (logior (if writer +lock-ex+ +lock-sh+) +lock-nb+)
                :int))
        fd
        (progn (%posix-close fd) nil))))

(defun unlock-directory (fd)
  "Release LOCK-DIRECTORY's lock by closing FD."
  (%posix-close fd))
