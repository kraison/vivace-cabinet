;;;; The database and stripe locks: a reader-writer lock that, when a
;;;; writer leaves, lets the readers then waiting in before the next
;;;; writer.  The copied RW-LOCK prefers writers, so back-to-back
;;;; whole-database calls starved per-key calls (#8).  Readers arriving
;;;; while a writer waits wait too, so writers do not starve either.

(in-package #:vivace-cabinet)

(defstruct (fair-lock (:constructor make-fair-lock ()))
  (mutex (sb-thread:make-mutex :name "fair lock"))
  (readers-cv (sb-thread:make-waitqueue))
  (writers-cv (sb-thread:make-waitqueue))
  ;; Threads holding it shared, and the one holding it exclusively.
  (readers 0 :type fixnum)
  (writer nil)
  (waiting-readers 0 :type fixnum)
  (waiting-writers 0 :type fixnum)
  ;; Counts the times waiting readers were let in together.
  (admissions 0 :type fixnum))

(defun %readers-may-enter-p (lock)
  (and (null (fair-lock-writer lock))
       (zerop (fair-lock-waiting-writers lock))))

(defun %pass-on (lock)
  "With the mutex held and no writer: let every waiting reader in, or
wake one waiting writer."
  (cond ((plusp (fair-lock-waiting-readers lock))
         (incf (fair-lock-readers lock) (fair-lock-waiting-readers lock))
         (setf (fair-lock-waiting-readers lock) 0)
         (incf (fair-lock-admissions lock))
         (sb-thread:condition-broadcast (fair-lock-readers-cv lock)))
        ((plusp (fair-lock-waiting-writers lock))
         (sb-thread:condition-notify (fair-lock-writers-cv lock)))))

(defun %release-shared (lock)
  "With the mutex held: give up one shared hold."
  (when (and (zerop (decf (fair-lock-readers lock)))
             (plusp (fair-lock-waiting-writers lock)))
    (sb-thread:condition-notify (fair-lock-writers-cv lock))))

(defun %wait-shared (lock)
  "With the mutex held: wait until let in with the other waiting readers,
or until no writer holds or waits for LOCK."
  (let ((mutex (fair-lock-mutex lock))
        (turn (fair-lock-admissions lock))
        (in nil))
    (incf (fair-lock-waiting-readers lock))
    (unwind-protect
         (loop
           (sb-thread:condition-wait (fair-lock-readers-cv lock) mutex)
           (cond ((/= turn (fair-lock-admissions lock))
                  ;; Let in: %PASS-ON counted us among the readers.
                  (return (setf in t)))
                 ((%readers-may-enter-p lock)
                  (decf (fair-lock-waiting-readers lock))
                  (incf (fair-lock-readers lock))
                  (return (setf in t)))))
      ;; Unwound while waiting.
      (unless in
        (if (/= turn (fair-lock-admissions lock))
            (%release-shared lock)
            (decf (fair-lock-waiting-readers lock)))))))

(defun acquire-shared (lock)
  (sb-thread:with-mutex ((fair-lock-mutex lock))
    (if (%readers-may-enter-p lock)
        (incf (fair-lock-readers lock))
        (%wait-shared lock))))

(defun release-shared (lock)
  (sb-thread:with-mutex ((fair-lock-mutex lock))
    (%release-shared lock)))

(defun acquire-exclusive (lock)
  (let ((mutex (fair-lock-mutex lock))
        (held nil))
    (sb-thread:with-mutex (mutex)
      (incf (fair-lock-waiting-writers lock))
      (unwind-protect
           (progn
             (loop until (and (null (fair-lock-writer lock))
                              (zerop (fair-lock-readers lock)))
                   do (sb-thread:condition-wait (fair-lock-writers-cv lock)
                                                mutex))
             (setf (fair-lock-writer lock) (current-thread)
                   held t))
        (decf (fair-lock-waiting-writers lock))
        ;; Unwound while waiting: pass on a wakeup that may have been
        ;; ours, and free the readers that waited for us.
        (when (and (not held) (null (fair-lock-writer lock)))
          (%pass-on lock))))))

(defun release-exclusive (lock)
  (sb-thread:with-mutex ((fair-lock-mutex lock))
    (unless (eq (fair-lock-writer lock) (current-thread))
      (error "~a is not held by this thread" lock))
    (setf (fair-lock-writer lock) nil)
    (%pass-on lock)))

(defmacro with-shared-lock ((lock) &body body)
  "Run BODY holding LOCK shared."
  (let ((l (gensym "LOCK")))
    `(let ((,l ,lock))
       (acquire-shared ,l)
       (unwind-protect (progn ,@body)
         (release-shared ,l)))))

(defmacro with-exclusive-lock ((lock) &body body)
  "Run BODY holding LOCK exclusively.  Not recursive: a thread that
holds LOCK either way and asks again waits for itself."
  (let ((l (gensym "LOCK")))
    `(let ((,l ,lock))
       (acquire-exclusive ,l)
       (unwind-protect (progn ,@body)
         (release-exclusive ,l)))))
