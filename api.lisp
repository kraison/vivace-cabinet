;;;; The Kyoto Cabinet-style API: generic functions, key coercion and
;;;; OPEN-DB (spec: API; the conditions are in errors.lisp).  Engines
;;;; implement the generics.

(in-package #:vivace-cabinet)

(defgeneric close-db (db))
(defgeneric db-set (db key value))
(defgeneric db-add (db key value))
(defgeneric db-replace (db key value))
(defgeneric db-append (db key value))
(defgeneric db-get (db key &key as))
(defgeneric db-check (db key))
(defgeneric db-seize (db key &key as))
(defgeneric db-remove (db key))
(defgeneric db-count (db))
(defgeneric db-size (db))
(defgeneric db-path (db))
(defgeneric db-clear (db))
(defgeneric db-synchronize (db &key hard))
(defgeneric db-error (db)
  (:documentation "Why the calling thread's last failed operation on DB
returned NIL: :DUPLICATE-RECORD, :NO-RECORD, :NO-PERMISSION or :LOGIC,
or :SUCCESS if none has failed."))

(defun to-octets (x)
  "X as octets: octet vectors as they are, strings as UTF-8."
  (typecase x
    (octets x)
    (string (babel:string-to-octets x :encoding :utf-8))
    ((vector (unsigned-byte 8)) (coerce x 'octets))
    (t (%signal 'invalid-argument "not octets or a string: ~s" x))))

(defun check-as (as)
  (unless (member as '(:octets :string))
    (%signal 'invalid-argument "AS must be :OCTETS or :STRING: ~s" as)))

(defun from-octets (octets as)
  "OCTETS as AS, which CHECK-AS has accepted.  Under :STRING, bytes that
are not UTF-8 signal INVALID-ARGUMENT."
  (if (eq as :string)
      (handler-case (babel:octets-to-string octets :encoding :utf-8)
        (babel:character-decoding-error ()
          (%signal 'invalid-argument
                   "~d bytes that are not UTF-8 cannot be read :AS :STRING"
                   (length octets))))
      octets))

(defun %existing-header (dir)
  "The header of the database in DIR, or NIL when there is none or it
cannot be read (opening then reports that)."
  (and (probe-file (%header-file dir))
       (ignore-errors (%read-header dir))))

(defparameter *hash-db-keywords*
  '(:mode :buckets :max-locks :heap-size :heap-reservation))

(defparameter *tree-db-keywords*
  '(:mode :engine :page-size :comparator :heap-size :heap-reservation))

(defun %check-keywords (type args)
  "Signal INVALID-ARGUMENT for a keyword in the plist ARGS that OPEN-DB
does not take for a TYPE database (#7)."
  (let ((bad (loop for (k) on args by #'cddr
                   unless (member k (ecase type
                                      (:hash *hash-db-keywords*)
                                      (:tree *tree-db-keywords*)))
                     collect k)))
    (when bad
      (%signal 'invalid-argument "not keywords for a ~(~a~) database: ~{~s~^ ~}"
               type bad))))

(defun open-db (path &rest args &key (type nil type-p) engine mode
                                &allow-other-keys)
  "Open the database in directory PATH (a trailing / is added).  An
existing database opens as the type it is; TYPE (:HASH by default)
chooses what to create, and must match when given; ENGINE alone implies
:TREE.  A writer's :TRUNCATE keeps the type and engine unless TYPE or
ENGINE names others.  Other keywords: OPEN-HASH-DB and OPEN-TREE-DB; one
for the other type signals INVALID-ARGUMENT."
  (when (and type-p (not (member type '(:hash :tree))))
    (%signal 'invalid-argument "unknown database type ~s" type))
  (let* ((dir (uiop:ensure-directory-pathname (merge-pathnames path)))
         (header (%existing-header dir))
         (found (getf header :type))
         (truncating (and (listp mode) (member :writer mode)
                          (member :truncate mode)))
         ;; The type asked for: TYPE, or :TREE when only ENGINE says.
         ;; :ENGINE NIL, OPEN-TREE-DB's own default, asks for nothing
         ;; and is dropped (#7).
         (asked (cond (type-p type) (engine :tree)))
         (args (if engine
                   (alexandria:remove-from-plist args :type)
                   (alexandria:remove-from-plist args :type :engine))))
    (when (and found asked (not (eq found asked)) (not truncating))
      (%signal 'open-error "~a: a ~(~a~) database, not ~(~a~)"
               dir found asked))
    (let ((type (if (and truncating asked) asked (or found asked :hash))))
      (%check-keywords type args)
      (when (and truncating (eq type :tree) (eq found :tree)
                 (null engine))
        (setf args (list* :engine (%engine-kind (getf header :engine))
                          args)))
      (ecase type
        (:hash (apply #'open-hash-db dir args))
        (:tree (apply #'open-tree-db dir args))))))

(defgeneric db-cursor (db)
  (:documentation "A new cursor on DB, on no record yet."))
(defgeneric cursor-jump (cursor &optional key)
  (:documentation "Move to the first record, or to KEY's (on a TreeDB,
the first at or after KEY).  T, or NIL with :NO-RECORD."))
(defgeneric cursor-jump-back (cursor &optional key)
  (:documentation "Move to the last record, or the last at or before
KEY.  T, or NIL with :NO-RECORD."))
(defgeneric cursor-step (cursor)
  (:documentation "Move to the next record.  T, or NIL with :NO-RECORD
past the end."))
(defgeneric cursor-step-back (cursor)
  (:documentation "Move to the previous record.  T, or NIL with
:NO-RECORD before the start."))
(defgeneric cursor-get (cursor &key as step)
  (:documentation "The current record's key and value, or NIL with
:NO-RECORD.  With STEP, the cursor then moves past the record the way it
last moved, in the same call: a walk that reads with STEP misses nothing
another thread leaves alone."))
(defgeneric cursor-set-value (cursor value))
(defgeneric cursor-remove (cursor)
  (:documentation "Remove the current record and move past it the way
the cursor last moved."))
(defgeneric cursor-seize (cursor &key as)
  (:documentation "Remove the current record, move past it the way the
cursor last moved, and return the removed key and value."))

(defun cursor-get-key (cursor &key (as :octets) step)
  (values (cursor-get cursor :as as :step step)))

(defun cursor-get-value (cursor &key (as :octets) step)
  (nth-value 1 (cursor-get cursor :as as :step step)))

(defgeneric %release-cursor (cursor)
  (:documentation "Free what CURSOR holds outside Lisp; WITH-CURSOR
calls it.")
  (:method (cursor)
    (declare (ignore cursor))
    nil))

(defmacro with-cursor ((var db) &body body)
  "Evaluate BODY with VAR bound to a new cursor on DB, released after."
  `(let ((,var (db-cursor ,db)))
     (unwind-protect (progn ,@body)
       (%release-cursor ,var))))

(defmacro with-db ((var path &rest open-args) &body body)
  "Evaluate BODY with VAR bound to the open database at PATH; close it
afterwards."
  `(let ((,var (open-db ,path ,@open-args)))
     (unwind-protect (progn ,@body)
       (close-db ,var))))

(defgeneric db-accept (db key visitor &key writable as)
  (:documentation "Call VISITOR with KEY and its value (NIL if absent)
and, when WRITABLE (the default), apply its answer: NIL or :NOP keeps
the record, :REMOVE removes it, anything else is the new value.  The
visit is atomic for KEY; VISITOR must not use the database, and a call
on it signals INVALID-ARGUMENT.  T, or NIL with :NO-PERMISSION for a
writable visit on a reader."))

(defgeneric db-accept-bulk (db keys visitor &key writable as)
  (:documentation "DB-ACCEPT for each of KEYS in order, holding every
key's lock for the whole call: isolated from other threads, but not
all-or-nothing, since VISITOR's error leaves the keys before it
changed."))

(defgeneric db-cas (db key old new)
  (:documentation "Store NEW under KEY if its value is OLD; OLD NIL means
KEY must be absent, NEW NIL removes the record.  T, or NIL with :LOGIC
when the value is not OLD."))

(defgeneric db-increment (db key num &key orig)
  (:documentation "Add NUM to KEY's value, an 8-byte big-endian signed
integer, and return the result.  An absent key starts at ORIG (0); ORIG
the most negative 64-bit integer makes an absent key fail, the most
positive sets the value to NUM.  NIL with :LOGIC when the value is not 8
bytes, as in Kyoto Cabinet.  A result that is exactly the most negative
integer is stored and returned; Kyoto stores it but reports :LOGIC, that
being its failure value (#8)."))

(defgeneric db-increment-double (db key num &key orig)
  (:documentation "DB-INCREMENT on a double float kept as Kyoto Cabinet
keeps it: 16 bytes, the integral part and the fraction in units of
10^-15, each big-endian.  ORIG negative infinity makes an absent key
fail, positive infinity sets the value to NUM."))

(defgeneric db-set-bulk (db records &key atomic)
  (:documentation "Store RECORDS, an alist of (key . value); a key given
twice takes its last value.  The number of keys stored, or NIL.  ATOMIC
(the default) holds every key while it stores them; a failure partway
leaves the earlier keys stored either way."))

(defgeneric db-get-bulk (db keys &key atomic as)
  (:documentation "An alist of (key . value) for those of KEYS that are
present, in the order asked."))

(defgeneric db-remove-bulk (db keys &key atomic)
  (:documentation "Remove KEYS; the number removed, or NIL."))

(defgeneric db-iterate (db visitor &key writable as)
  (:documentation "Visit every record, holding the whole database: other
threads wait until it ends, as in Kyoto Cabinet.  T, or NIL with
:NO-PERMISSION for a writable iteration on a reader."))

(defgeneric db-scan-parallel (db visitor &key threads as)
  (:documentation "Visit every record from THREADS threads (4) at once,
read-only: VISITOR's answers are ignored.  An error in VISITOR is
signalled again here."))

(defgeneric cursor-accept (cursor visitor &key writable step as)
  (:documentation "DB-ACCEPT on the cursor's record.  With STEP, or when
a writable visit removes the record, the cursor then moves past it the
way it last moved.  T, or NIL with :NO-RECORD when it is on none."))

(defgeneric %cursor-db (cursor))

(defgeneric %cursor-current (cursor)
  (:documentation "Move CURSOR past removed records to its current one:
(values key value) as octets, or NIL when it is on none."))

(defgeneric %cursor-pass (cursor key)
  (:documentation "Move CURSOR on from KEY, its record just removed, as
Kyoto's cursors move after a removal."))

(defgeneric db-match-prefix (db prefix &key max as)
  (:documentation "The keys that begin with PREFIX, at most MAX of them;
in key order on a TreeDB."))

(defgeneric db-match-regex (db regex &key max as)
  (:documentation "The keys whose UTF-8 text a match of REGEX (CL-PPCRE
syntax) occurs in, at most MAX.  Bytes that are not UTF-8 read as
U+FFFD.  A bad REGEX signals INVALID-ARGUMENT."))

(defgeneric db-match-similar (db origin range &key utf max as)
  (:documentation "The keys within Levenshtein distance RANGE of ORIGIN,
nearest first, then in byte order; at most MAX.  UTF compares UTF-8
characters, else bytes."))

(defgeneric db-status (db)
  (:documentation "A plist describing DB: :TYPE, :PATH, :COUNT, :SIZE,
:WRITABLE, :AUTOSYNC, and :BUCKETS (HashDB) or :ENGINE (TreeDB)."))

(defgeneric db-occupy (db fn &key writable)
  (:documentation "Call FN with DB's path, record count and size while
holding DB: exclusively when WRITABLE (the default), else shared with
other operations.  T, or NIL with :LOGIC when FN returns NIL.  FN must
not use DB; a call on it signals INVALID-ARGUMENT."))

(defgeneric db-copy (db dest)
  (:documentation "Copy DB's files to DEST, a directory that must not
exist, as a database that opens on its own.  Holes in the index's sparse
files stay holes."))

(defgeneric db-merge (db sources &key mode)
  (:documentation "Store the records of the databases SOURCES into DB,
one source after another, by MODE: :SET (the default), :ADD, :REPLACE
or :APPEND, as the operation of that name would."))

(defgeneric db-dump-snapshot (db path)
  (:documentation "Write every record to the file PATH, in vivace-cabinet's
own format, through PATH.tmp: a dump that fails leaves PATH as it was.
T."))

(defgeneric db-load-snapshot (db path)
  (:documentation "Store every record in the snapshot file PATH.  T, or
NIL with :NO-PERMISSION on a reader.  The file is read through first, so
one that is not a whole snapshot signals INVALID-ARGUMENT, and a key too
long for DB KEY-TOO-LONG, before any record is stored."))

(define-condition transactions-not-implemented (not-implemented) ())

(defgeneric db-begin-transaction (db &key hard)
  (:documentation "Signals TRANSACTIONS-NOT-IMPLEMENTED: version 1 has no
transactions (spec: unit 4)."))

(defgeneric db-begin-transaction-try (db &key hard)
  (:documentation "Signals TRANSACTIONS-NOT-IMPLEMENTED."))

(defgeneric db-end-transaction (db &key commit)
  (:documentation "Signals TRANSACTIONS-NOT-IMPLEMENTED."))

(defmacro with-transaction ((db &key hard) &body body)
  "Run BODY in a transaction on DB, committed if BODY returns normally.
Version 1 signals TRANSACTIONS-NOT-IMPLEMENTED before BODY runs."
  (let ((d (gensym "DB"))
        (ok (gensym "OK")))
    `(let ((,d ,db)
           (,ok nil))
       (db-begin-transaction ,d :hard ,hard)
       (unwind-protect (multiple-value-prog1 (progn ,@body)
                         (setf ,ok t))
         (db-end-transaction ,d :commit ,ok)))))
