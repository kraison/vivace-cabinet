(in-package #:vivace-cabinet-test)

(def-suite hash-db-modes-suite
  :description "HashDB open modes, damaged files, size, clear, sync."
  :in vivace-cabinet-suite)

(in-suite hash-db-modes-suite)

(defun header-count (path)
  "The record count in the header of the database at PATH."
  (getf (%read-header (uiop:ensure-directory-pathname path)) :count))

(def-db-test synchronize-persists-the-count
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "s.vch/" dir)))
      (with-test-db (db path)
        (db-set db "a" "1")
        (db-set db "b" "2")
        (is-true (db-synchronize db))
        (is (= 2 (header-count path)))))))

(def-db-test autosync-writes-through
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "a.vch/" dir)))
      (with-test-db (db path :mode '(:writer :create :autosync))
        (db-set db "a" "1")
        (is (= 1 (header-count path)))))))

(def-db-test reader-mode-refuses-writes
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "m.vch/" dir)))
      (with-test-db (db path) (db-set db "k" "v"))
      (with-test-db (db path :mode '(:reader))
        (is (equal "v" (db-get db "k" :as :string)))
        (is (null (db-set db "k" "w")))
        (is (eq :no-permission (db-error db)))
        (is (null (db-remove db "k")))
        (is (null (db-clear db)))
        (is (equal "v" (db-get db "k" :as :string)))))))

(def-db-test opening-needs-create-or-a-database
  (with-temp-directory (dir)
    (signals open-error (open-test-db (merge-pathnames "none.vch/" dir)
                                 :mode '(:writer)))
    (signals open-error (open-test-db (merge-pathnames "none.vch/" dir)
                                 :mode '(:reader)))))

(def-db-test truncate-empties
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "t.vch/" dir)))
      (with-test-db (db path) (db-set db "k" "v"))
      (with-test-db (db path :mode '(:writer :create :truncate))
        (is (= 0 (db-count db)))
        (is (null (db-get db "k")))))))

(test bad-open-arguments-signal
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "b.vch/" dir)))
      (signals invalid-argument (open-db path :mode '(:reader :writer)))
      (signals invalid-argument (open-db path :mode '(:create)))
      (signals invalid-argument (open-db path :mode '(:writer :bogus)))
      (signals invalid-argument (open-db path :mode :writer))
      (signals invalid-argument (open-db path :type :bogus))
      (signals invalid-argument
               (open-db path :type :tree :engine :bogus)))))

(test corrupt-index-signals
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "i.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-open-file (s (merge-pathnames "index/table.dat" path)
                         :direction :output :if-exists :overwrite
                         :element-type '(unsigned-byte 8))
        (write-byte 0 s))
      (signals open-error (open-db path)))))

(def-db-test paths-become-directories
  "A path without a trailing slash, or a relative one, names a directory."
  (with-temp-directory (dir)
    (let ((plain (namestring (merge-pathnames "p.vch" dir))))
      (with-test-db (db plain)
        (db-set db "k" "v")
        (is (equal (namestring (merge-pathnames "p.vch/" dir))
                   (db-path db))))
      (is-true (probe-file (merge-pathnames "p.vch/header.dat" dir))))
    (let ((*default-pathname-defaults* dir))
      (with-test-db (db "rel.vch")
        (db-set db "k" "v"))
      (is-true (probe-file (merge-pathnames "rel.vch/heap.dat" dir))))))

(def-db-test size-grows
  (with-temp-db (db)
    (let ((before (db-size db)))
      (is (plusp before))
      (dotimes (i 500)
        (db-set db (format nil "k~a" i)
                (make-string 100 :initial-element #\x)))
      (is (> (db-size db) (+ before 50000))))))

(def-db-test clear-empties-and-stays-usable
  (with-temp-db (db)
    (dotimes (i 100)
      (db-set db (format nil "k~a" i) "v"))
    (is-true (db-clear db))
    (is (= 0 (db-count db)))
    (is (null (db-get db "k5")))
    (is-true (db-set db "after" "clear"))
    (is (equal "clear" (db-get db "after" :as :string)))))

(def-db-test one-writer-or-many-readers
  "A database open for writing refuses any other handle; readers share."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "l.vch/" dir)))
      (with-test-db (db path)
        (db-set db "k" "v")
        (signals open-error (open-test-db path))
        (signals open-error (open-test-db path :mode '(:reader))))
      (with-test-db (r1 path :mode '(:reader))
        (with-test-db (r2 path :mode '(:reader))
          (is (equal "v" (db-get r2 "k" :as :string))))
        (signals open-error (open-test-db path)))
      (with-test-db (db path)
        (is (equal "v" (db-get db "k" :as :string)))))))

(def-db-test truncate-needs-no-create
  "As in Kyoto, :WRITER :TRUNCATE empties an existing database."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "tc.vch/" dir)))
      (with-test-db (db path) (db-set db "k" "v"))
      (with-test-db (db path :mode '(:writer :truncate))
        (is (= 0 (db-count db)))
        (is (null (db-get db "k"))))
      (with-test-db (db path :mode '(:reader))
        (is (= 0 (db-count db)))))))

(def-db-test incomplete-databases-signal-or-truncate
  "Files without a header (a crash while creating) signal OPEN-ERROR,
even with :CREATE; :TRUNCATE discards them."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "ic.vch/" dir)))
      (with-test-db (db path) (db-set db "k" "v"))
      (delete-file (merge-pathnames "header.dat" path))
      (signals open-error (open-test-db path))
      (signals open-error (open-test-db path :mode '(:reader)))
      (with-test-db (db path :mode '(:writer :create :truncate))
        (is (= 0 (db-count db)))
        (is-true (db-set db "k2" "v2"))))))

(defun abandon-db (db)
  "Drop DB as a process exit would: unmap and unlock, no header write."
  (close-lhash (hash-db-index db))
  (close-memory (%db-heap db))
  (%unlock db)
  (setf (%db-open-p db) nil))

(test unclosed-writers-are-recounted
  "A writer that exits without CLOSE-DB leaves its records but not its
count; the next open counts the records again, chains included."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "u.vch/" dir)))
      (let ((db (open-db path)))
        (dotimes (i 3)
          (db-set db (format nil "k~a" i) "v"))
        (let ((*key-digest* (constant-digest 7)))
          (dotimes (i 3)
            (db-set db (format nil "c~a" i) "v")))
        (abandon-db db))
      (with-db (db path :mode '(:reader))
        (is (= 6 (db-count db))))
      (with-db (db path)
        (is (= 6 (db-count db)))
        (db-remove db "k0")
        (db-remove db "k1"))
      (with-db (db path)
        (is (= 4 (db-count db)))))))

(test header-names-the-type
  "The header records the database type, so OPEN-DB can dispatch on it."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "h.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (let ((header (%read-header path)))
        (is (eq :hash (getf header :type)))
        (is (= 1 (getf header :count)))
        (is (null (getf header :open)))))))

(defun mapping-permissions (dir)
  "The permission column of each line of /proc/self/maps that names a
file under DIR, or :UNKNOWN where there is no /proc."
  (if (probe-file "/proc/self/maps")
      (let ((prefix (namestring (truename dir))))
        (with-open-file (in "/proc/self/maps")
          (loop for line = (read-line in nil)
                while line
                when (search prefix line)
                  collect (second (uiop:split-string line :separator " ")))))
      :unknown))

(def-db-test readers-map-read-only
  "A reader maps the files read-only (#6), so it opens a database whose
files it may not write; on Linux /proc/self/maps shows the protection."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "ro.vch/" dir)))
      (with-test-db (db path)
        (db-set db "k" "v")
        (let ((perms (mapping-permissions path)))
          (unless (eq perms :unknown)
            (is (member "rw-s" perms :test #'equal)))))
      (uiop:run-program (list "chmod" "-R" "a-w" (namestring path)))
      (unwind-protect
           (with-test-db (db path :mode '(:reader))
             (is (equal "v" (db-get db "k" :as :string)))
             (is (= 1 (db-count db)))
             (let ((perms (mapping-permissions path)))
               (unless (eq perms :unknown)
                 (is (and perms (every (lambda (p) (equal p "r--s")) perms))
                     "a reader's mappings: ~a" perms))))
        (uiop:run-program (list "chmod" "-R" "u+w" (namestring path)))))))

(defun truncate-file (path n)
  "Cut the file at PATH down to its first N bytes."
  (let ((head (make-array n :element-type '(unsigned-byte 8))))
    (with-open-file (in path :element-type '(unsigned-byte 8))
      (read-sequence head in))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :element-type '(unsigned-byte 8))
      (write-sequence head out))))

(defun fill-db (path n)
  "A database at PATH holding N records of 100 bytes."
  (with-test-db (db path)
    (dotimes (i n)
      (db-set db (keyed i) (make-string 100 :initial-element #\x)))))

(test truncated-index-signals
  "An index file shorter than its bucket count or overflow pointer says
signals OPEN-ERROR instead of reading as empty or faulting (#6)."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "ti.vch/" dir)))
      (fill-db path 200)
      (truncate-file (merge-pathnames "index/table.dat" path) 1000)
      (signals open-error (open-db path))
      (signals open-error (open-db path :mode '(:reader))))
    (let ((path (merge-pathnames "to.vch/" dir)))
      (fill-db path 200)
      (truncate-file (merge-pathnames "index/overflow.dat" path) 1)
      (signals open-error (open-db path)))
    (let ((path (merge-pathnames "tcf.vch/" dir)))
      (fill-db path 200)
      (truncate-file (merge-pathnames "index/config.dat" path) 70)
      (signals open-error (open-db path)))))

(def-db-test truncated-heap-signals
  "A heap shorter than its own allocation pointer signals OPEN-ERROR at
open rather than a memory fault at the first lookup past its end (#6)."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "th.vch/" dir)))
      (fill-db path 2000)
      (truncate-file (merge-pathnames "heap.dat" path) 100000)
      (signals open-error (open-test-db path))
      (signals open-error (open-test-db path :mode '(:reader))))))

(test header-is-replaced-whole
  "The header goes to header.tmp and is renamed over header.dat (#6), so
a reader of the old file sees all of it, never a truncated one; :HARD
makes the replacement durable."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "hr.vch/" dir)))
      (with-db (db path)
        (db-set db "a" "1")
        (db-synchronize db)
        (with-open-file (old (merge-pathnames "header.dat" path)
                             :element-type '(unsigned-byte 8))
          (db-set db "b" "2")
          (is-true (db-synchronize db :hard t))
          (is (null (probe-file (merge-pathnames "header.tmp" path))))
          (let ((h (make-array +header-bytes+
                               :element-type '(unsigned-byte 8))))
            (is (= +header-bytes+ (read-sequence h old)))
            (is (= 1 (%get-u64 h 8)))))
        (is (= 2 (header-count path)))))))

(test bad-tuning-signals
  "Tuning keywords that are not integers in range signal
INVALID-ARGUMENT at open, not DIVISION-BY-ZERO at the first use (#6)."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "bt.vch/" dir)))
      (signals invalid-argument (open-db path :buckets 0))
      (signals invalid-argument (open-db path :max-locks 0))
      (signals invalid-argument (open-db path :buckets "x"))
      (signals invalid-argument (open-db path :heap-size -1))
      (signals invalid-argument (open-db path :heap-reservation nil))
      (signals invalid-argument (open-db path :type :tree :heap-size 1.5))
      (is (null (probe-file path))))))

(test a-file-is-not-a-database
  "A path naming a file signals OPEN-ERROR (#6)."
  (with-temp-directory (dir)
    (let ((file (merge-pathnames "plain" dir)))
      (with-open-file (s file :direction :output)
        (write-line "x" s))
      (signals open-error (open-db file))
      (signals open-error (open-db file :mode '(:reader))))))

(def-db-test reservation-exhaustion-signals
  "Growing the heap past its reservation signals RESERVATION-EXHAUSTED
(#6), and the records already stored stay readable."
  (with-temp-db (db :heap-size (* 1024 1024) :heap-reservation 1)
    (db-set db "first" "v")
    (signals reservation-exhausted
      (dotimes (i 20)
        (db-set db (keyed i) (make-string 100000 :initial-element #\x))))
    (is (equal "v" (db-get db "first" :as :string)))))

(def-db-test autosync-skips-failures-and-closed-databases
  "Under :AUTOSYNC a write that fails logically does not synchronize,
and a write whose database another thread closed before its
synchronize does not signal (#6)."
  (with-temp-directory (dir)
    (let* ((path (merge-pathnames "as.vch/" dir))
           (header (merge-pathnames "header.dat" path))
           (db (open-test-db path :mode '(:writer :create :autosync))))
      (db-set db "k" "v")
      (delete-file header)
      (is (null (db-add db "k" "w")))
      (is (null (probe-file header)))
      (is (null (db-replace db "absent" "w")))
      (is (null (probe-file header)))
      (is-true (db-set db "k" "w"))
      (is-true (probe-file header))
      (close-db db)
      (finishes (%autosync db))
      (is (null (getf (%read-header path) :open))))))

(test open-error-keeps-its-cause
  "An OPEN-ERROR from a failure in the files carries that condition as
its cause; one from this library's own refusal has none (#6)."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "oc.vch/" dir)))
      (handler-case (progn (open-db path :mode '(:reader))
                           (fail "opened a missing database"))
        (open-error (e)
          (is (null (open-error-cause e)))))
      (with-db (db path) (db-set db "k" "v"))
      (with-open-file (s (merge-pathnames "index/table.dat" path)
                         :direction :output :if-exists :overwrite
                         :element-type '(unsigned-byte 8))
        (write-byte 0 s))
      (handler-case (progn (open-db path)
                           (fail "opened a damaged database"))
        (open-error (e)
          (is (typep (open-error-cause e) 'error))
          (is (search "magic" (princ-to-string (open-error-cause e)))))))))

(test close-syncs-the-storage-before-the-clean-header
  "CLOSE-DB syncs the heap and index to the device while the header
still says open, and only then writes the clean header hard (#6), so a
power loss between the two cannot leave a clean header over stale data."
  (with-temp-directory (dir)
    (let* ((path (merge-pathnames "co.vch/" dir))
           (db (open-db path))
           (seen '())
           (method (defmethod %sync-storage :around ((db database) hard)
                     (push (list hard (getf (%read-header (%db-dir db))
                                            :open))
                           seen)
                     (call-next-method))))
      (unwind-protect
           (progn
             (db-set db "k" "v")
             (close-db db)
             (is (equal '((t t)) seen)))
        (remove-method #'%sync-storage method))
      (is (null (getf (%read-header path) :open))))))

(defun file-mode-string (path)
  "The permission field of `ls -l` for PATH, such as -rw-r--r--."
  (subseq (uiop:run-program (list "ls" "-ld" (namestring path))
                            :output :string)
          0 10))

(test header-mode-follows-the-umask
  "header.dat is created with mode #o666 less the umask, as any file is
(#6), not a fixed #o640 that drops the group write a second writer
account needs."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "hm.vch/" dir))
          (plain (merge-pathnames "plain" dir)))
      (with-open-file (s plain :direction :output)
        (write-line "x" s))
      (with-db (db path)
        (db-set db "k" "v")
        (db-synchronize db))
      (is (equal (file-mode-string plain)
                 (file-mode-string (merge-pathnames "header.dat" path)))))))
