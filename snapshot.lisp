;;;; Snapshots: every record in one file, in vivace-cabinet's own format
;;;; (spec: API).  Magic, then each record's key length and value length
;;;; (u64, little-endian), key and value; a key length of 2^64-1 ends it.

(in-package #:vivace-cabinet)

(alexandria:define-constant +snapshot-magic+ #(86 67 83 78 65 80 0 1)
  :test 'equalp)
(alexandria:define-constant +snapshot-end+ (1- (expt 2 64)))

(defun %write-u64 (n out)
  (dotimes (i 8)
    (write-byte (ldb (byte 8 (* 8 i)) n) out)))

(defun %read-octets (in n path)
  "N bytes from IN; signals INVALID-ARGUMENT if PATH ends first."
  (when (> n (- (file-length in) (file-position in)))
    (%signal 'invalid-argument "~a: the snapshot ends early" path))
  (let ((v (make-array n :element-type '(unsigned-byte 8))))
    (read-sequence v in)
    v))

(defun %read-u64 (in path)
  (%get-u64 (%read-octets in 8 path) 0))

(defun %skip-octets (in n path)
  "Move IN past N bytes; signals INVALID-ARGUMENT if PATH ends first."
  (let ((end (+ (file-position in) n)))
    (when (> end (file-length in))
      (%signal 'invalid-argument "~a: the snapshot ends early" path))
    (file-position in end)))

(defun %check-snapshot (in path limit)
  "Read the snapshot IN through once: INVALID-ARGUMENT unless PATH is a
whole snapshot, KEY-TOO-LONG for a key longer than LIMIT (NIL: no
limit).  Leaves IN after the magic, at the first record."
  (unless (equalp +snapshot-magic+ (%read-octets in 8 path))
    (%signal 'invalid-argument "~a: not a vivace-cabinet snapshot" path))
  (loop for klen = (%read-u64 in path)
        until (= klen +snapshot-end+)
        do (let ((vlen (%read-u64 in path)))
             (when (and limit (> klen limit))
               (%signal 'key-too-long "~a: a ~d-byte key; the limit is ~d"
                        path klen limit))
             (%skip-octets in (+ klen vlen) path)))
  (file-position in 8))

(defun %rename-over (from to)
  "Rename file FROM to TO, replacing TO.  rename(2), since RENAME-FILE
fills a missing type in TO from FROM."
  (unless (zerop (cffi:foreign-funcall
                  "rename" :string (uiop:native-namestring from)
                  :string (uiop:native-namestring to) :int))
    (%signal 'vivace-cabinet-error "cannot rename ~a to ~a" from to)))

(defmethod db-dump-snapshot ((db database) path)
  (let* ((to (merge-pathnames path))
         (tmp (uiop:parse-native-namestring
               (concatenate 'string (uiop:native-namestring to) ".tmp"))))
    ;; A failed dump deletes the new TMP and leaves TO as it was.
    (with-open-file (out tmp :direction :output :if-exists :supersede
                             :element-type '(unsigned-byte 8))
      (write-sequence +snapshot-magic+ out)
      (db-iterate db (lambda (k v)
                       (%write-u64 (length k) out)
                       (%write-u64 (length v) out)
                       (write-sequence k out)
                       (write-sequence v out)
                       :nop)
                  :writable nil)
      (%write-u64 +snapshot-end+ out))
    (%rename-over tmp to)
    t))

(defmethod db-load-snapshot ((db database) path)
  (if (not (%db-writable-p db))
      (%fail db :no-permission)
      (with-open-file (in path :element-type '(unsigned-byte 8))
        ;; All or nothing: a bad snapshot signals before any record
        ;; is stored.
        (%check-snapshot in path (%key-limit db))
        (loop for klen = (%read-u64 in path)
              until (= klen +snapshot-end+)
              do (let* ((vlen (%read-u64 in path))
                        (k (%read-octets in klen path))
                        (v (%read-octets in vlen path)))
                   (db-set db k v)))
        t)))
