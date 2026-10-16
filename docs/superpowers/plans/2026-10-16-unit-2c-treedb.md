# Unit 2c: TreeDB and cursors — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** TreeDB, an ordered database on the B+ tree (the default engine)
or the skip list, behind the API HashDB already has; Kyoto-style cursors on
both database types; and B+ tree pages that split by bytes (#4).

**Architecture:** What HashDB and TreeDB share (the directory and its
lock, the header, open modes, error codes, stripe locks) moves into a
`database` base class. TreeDB keeps its records in an *engine* with one
small protocol (get, put, delete, count, ceiling, floor), implemented over
the B+ tree and over the skip list. Cursors hold their position as a key
and move by asking the engine for the next or previous key; HashDB's cursor
walks the index a bucket at a time, forward only.

**Tech Stack:** SBCL, FiveAM, the unit 2a structures, the unit 2b HashDB.

**Spec:** `docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`,
sections "Storage" (TreeDB) and "API" (cursors); phase split and decisions
on kraison/vivace-cabinet#2.

**Dry run:** every Lisp block below was run, in this order, in a scratch
copy of the repository before the plan was written: the suite passed
(12,151 checks) and every mutation check below failed as stated. The
executor still works test-first from the plan.

## Global Constraints

- SBCL only. New Lisp: spaces only, 80 columns, terse comments.
- Lines carried over unchanged from copied code keep their width (a few
  in `bplus-tree.lisp` exceed 80 columns); every new line fits 80.
- vivace-graph is never modified. Changes to copied code are recorded in
  `docs/provenance.md`.
- Keys and values are `(simple-array (unsigned-byte 8) (*))`; strings are
  accepted and stored as UTF-8.
- Logical failures return NIL and set the reason `db-error` reports; real
  errors signal `vivace-cabinet-error` subclasses.
- Branch `unit-2c-treedb` in `~/work/vivace-cabinet`; one commit per task;
  explicit `git add` paths; nothing pushed without Kevin's word.
- Public repo: generic commit messages and issue text.
- Every commit message ends with:

  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ
  ```

## Commands

`VC-SUITE` (forced recompile; temp files on disk, since one copied test
needs about 2 GB and `/tmp` here is a small tmpfs):

```bash
mkdir -p /var/tmp/vc-tests && cd ~/work/vivace-cabinet && \
TMPDIR=/var/tmp/vc-tests sbcl --noinform --non-interactive \
  --load ~/quicklisp/setup.lisp \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval '(ql:quickload (list :alexandria :bordeaux-threads :cffi :cl-store :log4cl :fiveam :babel) :silent t)' \
  --eval '(asdf:load-system :vivace-cabinet/test :force (list :vivace-cabinet :vivace-cabinet/test))' \
  --eval '(asdf:test-system :vivace-cabinet)'
```

`VC-TEST <name>`: the same with the last `--eval` replaced by
`--eval '(unless (fiveam:run! (quote vivace-cabinet-test::<name>)) (uiop:quit 1))'`.
`<name>` may be a test or a suite. Tests made by `def-db-test`,
`def-tree-test` and `def-engine-test` are named `<name>/<kind>`, e.g.
`set-and-get/skip-list`.

Mutation checks: change the code in place as stated (never append a second
definition: that is a full compiler WARNING and the build stops), run the
named test, confirm it fails *as a test failure, not a compile error*, and
restore the file byte for byte. A test that hangs is a failure too: run
mutation checks under `timeout 600`. Logs can contain NUL bytes: `grep -a`.

## Review Focus

1. **Cursors while other threads write**: the cursor's record replaced or
   removed, keys added beside it. Task 6's
   `cursor-follows-removal-by-others` covers removal; check the skip list's
   remove-and-re-add window by reading `engine-put` and `tree-cursor`.
2. **Keys and values at the limits**: 1024-byte keys, key plus value
   exactly a quarter page, empty keys, 100 KB values (Tasks 3-4
   `engine-holds-mixed-sizes`, `engine-empty-key-and-value`; Task 5
   `tree-db-key-limit`, `tree-db-small-pages`).
3. **Opening the wrong way**: an existing database asked for as another
   type or engine, `:truncate` across types, a damaged header on each kind
   (Task 5 `tree-db-opens-as-what-it-is`; `corrupt-header-signals/<kind>`).
4. **Concurrent writers on both tree engines** (Task 5
   `concurrent-writers-are-consistent/<kind>`).
5. **Custom comparators**, including reopening with a different one, which
   nothing can detect (Task 6 `custom-comparator-orders-records`; README
   Limits).

## Proposals in this plan for Kevin to approve

- **A shared base class.** `database.lisp` takes over the directory lock,
  header, modes, error codes and stripes from `hash-db.lisp`; HashDB and
  TreeDB supply storage through six generic functions.
- **The header names the type.** Byte 5 is the type (1 HashDB, 2 TreeDB),
  byte 7 the engine, bytes 16-23 the engine's address in the heap; a 2b
  database still reads as a HashDB. An existing database opens as what it
  is: `:type` and `:engine` choose what to create, and a mismatching one
  signals `open-error` (a writer's `:truncate` may change the type).
- **Out of line by key plus value.** The spec puts values over a quarter
  page out of line; this plan does so when the key and the value
  *together* exceed a quarter page. Every cell then fits a quarter page,
  which is what lets a byte-based split always produce two pages that fit.
- **Cursors hold a key, not a page.** Each move asks the engine for the
  next or previous key: O(log n) per step, but valid however other threads
  change the tree. If the current record is removed, the cursor reads the
  next one (Kyoto's behaviour).
- **HashDB's cursor goes forward only**, a bucket at a time, in no useful
  order. A record that a concurrent bucket split moves can be seen twice
  or missed.
- **Replacing a value**: the B+ tree engine removes and re-inserts under
  its write lock, so cursors never miss the key; the skip list cannot, so
  a cursor passing a key at the moment it is replaced may miss it. The
  copied skip list frees removed records only at close.
- **Comparators are not stored**; pass the same one at every open.
- **`:page-size`** is 1024 to 32768 bytes (the page's offsets are 16-bit).
- **`cursor-accept` moves to 2d** with the other visitors.
- **Copied code changes**: the B+ tree splits by bytes (#4), and
  `bpt-insert`/`bpt-remove` gain lock-free cores TreeDB calls under one
  lock.
- **The skip list's sentinels** get a key no real key can equal: the
  copied search tests its tail node against the key, so with an empty
  sentinel key an empty user key matched the tail and the next remove
  looped forever (found by the dry run).

---

### Task 1: B+ tree pages split by bytes (#4)

**Files:**
- Modify: `structures/bplus-tree.lisp` (`%bpt-store-or-split`; new
  `%bpt-split-index`), `tests/bplus-tree-tests.lisp`,
  `docs/provenance.md`, `README.md`

**Interfaces:**
- Produces: `(%bpt-split-index leaf-p entries)` → split index; page splits
  that fit whenever every cell fits a quarter page.

- [ ] **Step 1: Branch**

```bash
cd ~/work/vivace-cabinet && git switch -c unit-2c-treedb
```

- [ ] **Step 2: Write the failing test**

Append to `tests/bplus-tree-tests.lisp`:

```lisp
(test bplus-split-by-bytes
  "A page of small entries splits by bytes, so it still takes large ones:
after 12 one-byte values, 300-, 400- and 600-byte values used to fail
after 12, 9 and 6 inserts (#4)."
  (dolist (size '(300 400 600 1000))
    (with-temp-memory (heap)
      (let ((tree (make-integer-bplus-tree heap))
            (big (make-string size :initial-element #\v)))
        (loop for k from 1 to 12
              do (add-to-skip-list tree k "x"))
        (loop for k from 13 to 60
              do (is-true (add-to-skip-list tree k big)))
        (is (= 60 (bplus-tree-count tree)))
        (is (equal big (tree-value tree 60)))
        (is (equal (loop for k from 1 to 60 collect k)
                   (cursor-keys (make-cursor tree))))))))
```

- [ ] **Step 3: Run it and watch it fail**

Run: `VC-TEST bplus-tree-suite`
Expected: non-zero exit; `bplus-split-by-bytes` fails with an unexpected
`TYPE-ERROR` (the overflowing half encodes to NIL); the other B+ tree
tests pass.

- [ ] **Step 4: Split by bytes**

In `structures/bplus-tree.lisp`, replace the whole `%bpt-store-or-split`
defun (from `(defun %bpt-store-or-split` up to, not including,
`(defun %bpt-split-leaf`) with:

```lisp
(defun %bpt-split-index (leaf-p entries)
  "Where to split ENTRIES: the first index whose earlier cells hold half
the bytes, so a page of mixed sizes splits into two that fit (#4).  An
internal split keeps an entry each side of the one that moves up."
  (let* ((sizes (mapcar (lambda (e) (+ 2 (%bpt-entry-cell-size leaf-p e)))
                        entries))
         (half (/ (reduce #'+ sizes) 2))
         (n (length entries))
         (acc 0)
         (i 0))
    (dolist (s sizes)
      (incf acc s)
      (incf i)
      (when (>= acc half)
        (return)))
    (max 1 (min i (- n (if leaf-p 1 2))))))

(defun %bpt-store-or-split (tree addr leaf-p link entries)
  "Write ENTRIES back to page ADDR, splitting if they overflow.  Return :NO-SPLIT
or (SEP-DKEY SEP-SKEY RIGHT-ADDR)."
  (let ((buf (%bpt-encode-page tree leaf-p link entries)))
    (if buf
        (progn (%bpt-write-page tree addr buf) :no-split)
        ;; Overflow -> split by bytes (#4).
        (let* ((n (length entries))
               (mid (%bpt-split-index leaf-p entries)))
          (when (< n 2)
            (error "B+ tree: single entry too large for a ~A-byte page"
                   (%bpt-page-size tree)))
          (unless (and (%bpt-encode-page tree leaf-p 0
                                         (subseq entries 0 mid))
                       (%bpt-encode-page tree leaf-p 0
                                         (subseq entries
                                                 (if leaf-p mid (1+ mid)))))
            (error "B+ tree: entries too large for two ~A-byte pages"
                   (%bpt-page-size tree)))
          (if leaf-p
              ;; Leaf split: right keeps the upper half; its first key is copied
              ;; up as the separator (the key itself STAYS in the right leaf).
              (let* ((left (subseq entries 0 mid))
                     (right (subseq entries mid))
                     (right-addr (%bpt-alloc-page tree))
                     (sep (first right)))
                (%bpt-write-page tree right-addr
                                 (%bpt-encode-page tree t link right))   ; right.next = old next
                (%bpt-write-page tree addr
                                 (%bpt-encode-page tree t right-addr left)) ; left.next = right
                (list (first sep) (second sep) right-addr))
              ;; Internal split: the middle entry moves UP (removed from this
              ;; level); its child becomes the right node's P0.
              (let* ((left (subseq entries 0 mid))
                     (mid-entry (nth mid entries))
                     (right (subseq entries (1+ mid)))
                     (right-addr (%bpt-alloc-page tree)))
                (%bpt-write-page tree right-addr
                                 (%bpt-encode-page tree nil (third mid-entry) right))
                (%bpt-write-page tree addr
                                 (%bpt-encode-page tree nil link left))
                (list (first mid-entry) (second mid-entry) right-addr)))))))
```

In `docs/provenance.md`, append to the B+ tree row's last cell:
`; full pages split by bytes, not entry count (#4)`.

In `README.md`, delete this Limits bullet:

```markdown
- **B+ tree entries of mixed sizes.** The B+ tree splits a full page by
  entry count, not bytes, so a page of small entries can fail to take a
  large one (issue #4); to be fixed before TreeDB uses it.
```

- [ ] **Step 5: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures.

- [ ] **Step 6: Mutation check**

Make `%bpt-split-index`'s body `(floor (length entries) 2)`; run
`VC-TEST bplus-split-by-bytes`; confirm it fails; restore.

- [ ] **Step 7: Commit**

```bash
git add structures/bplus-tree.lisp \
  tests/bplus-tree-tests.lisp \
  docs/provenance.md \
  README.md
git commit -m "B+ tree: split full pages by bytes, not entry count

A page holding small entries could not take large ones: its halves by
count did not fit. Fixes #4.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 2: A database base shared by every type

**Files:**
- Create: `database.lisp`
- Replace: `hash-db.lisp` (whole file)
- Modify: `api.lisp` (`open-db`), `vivace-cabinet.asd`,
  `tests/hash-db-modes-tests.lisp`

**Interfaces:**
- Produces: class `database` with readers `%db-dir`, `%db-writable-p`,
  `%db-autosync-p`, `%db-tuning`, `%db-lock`, `%db-stripes` and accessors
  `%db-heap`, `%db-open-p`, `%db-lock-fd`; generics `%type-code`,
  `%engine-code`, `%header-address`, `%record-count`, `%create-storage`,
  `%open-storage (db header)`, `%close-storage`, `%sync-storage`;
  `(%read-header dir)` → plist `:type :open :engine :count :address`;
  `%write-header`, `%check-mode`, `%open-database (db mode)`, `%unlock`,
  `%stripe`, `%check-open`, `with-key-locked`, `%fail`, `%writing`,
  `%heap-file`, `%header-file`, `%index-dir`; methods `close-db`,
  `db-error`, `db-path`, `db-count`, `db-synchronize`, `db-clear` on
  `database`. HashDB keeps `hash-db-index`, `hash-db-record-count`.
- `open-db` dispatches on an existing database's header type.

- [ ] **Step 1: Write the failing tests**

Apply these test edits with this script (run from the repository):

```bash
python3 - <<'EOF'
p = 'tests/hash-db-modes-tests.lisp'
t = open(p).read()
edits = [
 ('  (vivace-cabinet::%read-header (uiop:ensure-directory-pathname path)))',
  '  (getf (%read-header (uiop:ensure-directory-pathname path)) :count))'),
 ('''  (close-memory (hash-db-heap db))
  (%unlock db)
  (setf (hash-db-open-p db) nil))''',
  '''  (close-memory (%db-heap db))
  (%unlock db)
  (setf (%db-open-p db) nil))'''),
 ("      (signals invalid-argument (open-db path :mode '(:writer :bogus)))\n",
  "      (signals invalid-argument (open-db path :mode '(:writer :bogus)))\n"
  "      (signals invalid-argument (open-db path :mode :writer))\n"),
]
for old, new in edits:
    assert t.count(old) == 1, old
    t = t.replace(old, new)
open(p, 'w').write(t)
EOF
```

Then append to `tests/hash-db-modes-tests.lisp`:

```lisp
(test header-names-the-type
  "The header records the database type, so OPEN-DB can dispatch on it."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "h.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (let ((header (%read-header path)))
        (is (eq :hash (getf header :type)))
        (is (= 1 (getf header :count)))
        (is (null (getf header :open)))))))
```

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit. Failing: `header-names-the-type` (`%read-header`
returns a number, not a plist), `synchronize-persists-the-count` and
`autosync-writes-through` (the helper's `getf`),
`unclosed-writers-are-recounted` (`%db-heap` is undefined) and
`bad-open-arguments-signal` (a non-list mode signals `TYPE-ERROR`).
Everything else passes.

- [ ] **Step 3: Write `database.lisp`**

```lisp
;;;; What every database type shares: the directory and its lock, the
;;;; header, open modes, per-thread error codes and per-key stripe locks
;;;; (spec: API).  HashDB and TreeDB supply storage through the generics
;;;; below.

(in-package #:vivace-cabinet)

(alexandria:define-constant +stripes+ 1024)
(alexandria:define-constant +header-bytes+ 32)
(alexandria:define-constant +header-magic+ #(86 67 65 66) :test 'equalp)
(alexandria:define-constant +open-modes+
    '(:reader :writer :create :truncate :autosync) :test 'equal)

(defclass database ()
  ((dir :initarg :dir :reader %db-dir)
   (writable :initarg :writable :reader %db-writable-p)
   (autosync :initarg :autosync :reader %db-autosync-p)
   (tuning :initarg :tuning :reader %db-tuning)
   (heap :initform nil :accessor %db-heap)
   (lock :initform (make-rw-lock) :reader %db-lock)
   (stripes :reader %db-stripes
            :initform (let ((v (make-array +stripes+)))
                        (dotimes (i +stripes+ v)
                          (setf (aref v i) (make-rw-lock)))))
   (errors :initform (make-hash-table :test 'eq
                                      #+sbcl :weakness #+sbcl :key)
           :reader %db-errors)
   (errors-lock :initform (make-lock "database errors")
                :reader %db-errors-lock)
   (open-p :initform nil :accessor %db-open-p)
   (lock-fd :initform nil :accessor %db-lock-fd)))

;;; What each type supplies

(defgeneric %type-code (db)
  (:documentation "The header's type byte: 1 for HashDB, 2 for TreeDB."))

(defgeneric %engine-code (db)
  (:documentation "The header's engine byte; 0 for a type without one.")
  (:method ((db database)) 0))

(defgeneric %header-address (db)
  (:documentation "The heap address the header records, or 0.")
  (:method ((db database)) 0))

(defgeneric %record-count (db))

(defgeneric %create-storage (db)
  (:documentation "Create DB's storage in its existing directory."))

(defgeneric %open-storage (db header)
  (:documentation "Open DB's storage; HEADER is %READ-HEADER's plist."))

(defgeneric %close-storage (db)
  (:documentation "Close whatever of DB's storage is open."))

(defgeneric %sync-storage (db)
  (:documentation "Flush DB's mapped files to disk."))

;;; Files and the header

(defun %heap-file (dir) (merge-pathnames "heap.dat" dir))
(defun %index-dir (dir) (merge-pathnames "index/" dir))
(defun %header-file (dir) (merge-pathnames "header.dat" dir))

(defun %put-u64 (octets offset n)
  (dotimes (i 8)
    (setf (aref octets (+ offset i)) (ldb (byte 8 (* 8 i)) n))))

(defun %get-u64 (octets offset)
  (let ((n 0))
    (dotimes (i 8 n)
      (setf n (logior n (ash (aref octets (+ offset i)) (* 8 i)))))))

(defun %write-header (db &key open)
  "Write DB's header: magic VCAB, format 1, type, OPEN (1 while a writer
has the database open), engine, record count, structure address."
  (let ((h (make-array +header-bytes+ :element-type '(unsigned-byte 8)
                                      :initial-element 0)))
    (replace h +header-magic+)
    (setf (aref h 4) 1
          (aref h 5) (%type-code db)
          (aref h 6) (if open 1 0)
          (aref h 7) (%engine-code db))
    (%put-u64 h 8 (%record-count db))
    (%put-u64 h 16 (%header-address db))
    (with-open-file (out (%header-file (%db-dir db))
                         :direction :output :if-exists :supersede
                         :element-type '(unsigned-byte 8))
      (write-sequence h out))))

(defun %read-header (dir)
  "DIR's header as a plist: :TYPE (:HASH or :TREE), :OPEN, :ENGINE, :COUNT
and :ADDRESS.  Signals OPEN-ERROR for anything else."
  (let ((h (make-array +header-bytes+ :element-type '(unsigned-byte 8))))
    (with-open-file (in (%header-file dir) :element-type '(unsigned-byte 8))
      (unless (= +header-bytes+ (read-sequence h in))
        (%signal 'open-error "~a: header too short" dir)))
    (unless (and (equalp (subseq h 0 4) +header-magic+)
                 (= 1 (aref h 4))
                 (member (aref h 5) '(1 2)))
      (%signal 'open-error "~a: not a vivace-cabinet database" dir))
    (list :type (if (= 1 (aref h 5)) :hash :tree)
          :open (= 1 (aref h 6))
          :engine (aref h 7)
          :count (%get-u64 h 8)
          :address (%get-u64 h 16))))

(defun %storage-present-p (dir)
  "True when any of a database's files exist in DIR."
  (or (probe-file (%header-file dir)) (probe-file (%heap-file dir))
      (probe-file (%index-dir dir))))

(defun %delete-storage (dir)
  (dolist (f (list (%header-file dir) (%heap-file dir)))
    (when (probe-file f)
      (delete-file f)))
  (uiop:delete-directory-tree (%index-dir dir) :validate t
                                               :if-does-not-exist :ignore))

;;; Opening and closing

(defun %check-mode (mode)
  "Signal INVALID-ARGUMENT unless MODE lists open modes with exactly one
of :READER and :WRITER."
  (unless (and (listp mode)
               (every (lambda (m) (member m +open-modes+)) mode))
    (%signal 'invalid-argument "MODE must be a list of ~s: ~s"
             +open-modes+ mode))
  (unless (= 1 (count-if (lambda (m) (member m mode)) '(:reader :writer)))
    (%signal 'invalid-argument
             "MODE needs exactly one of :READER and :WRITER: ~s" mode)))

(defun %guard-storage (db thunk)
  "Call THUNK, which creates or opens DB's storage; if it fails, close
what it opened and signal OPEN-ERROR."
  (handler-case (funcall thunk)
    (error (c)
      (ignore-errors (%close-storage db))
      (if (typep c 'open-error)
          (error c)
          (%signal 'open-error "~a: ~a" (%db-dir db) c)))))

(defun %open-existing (db)
  (let ((header (%read-header (%db-dir db))))
    (unless (= (%type-code db) (if (eq :hash (getf header :type)) 1 2))
      (%signal 'open-error "~a: a ~(~a~) database" (%db-dir db)
               (getf header :type)))
    (%open-storage db header)))

(defun %unlock (db)
  (when (%db-lock-fd db)
    (unlock-directory (%db-lock-fd db))
    (setf (%db-lock-fd db) nil)))

(defun %open-database (db mode)
  "Lock DB's directory, then open, create or truncate its storage as MODE
says.  Returns DB."
  (let ((dir (%db-dir db))
        (writer (%db-writable-p db)))
    (unless (probe-file dir)
      (unless (and writer (member :create mode))
        (%signal 'open-error
                 "~a: no database here (open with :CREATE)" dir))
      (ensure-directories-exist dir))
    (setf (%db-lock-fd db)
          (or (lock-directory dir writer)
              (%signal 'open-error "~a: open in another handle" dir)))
    (let ((ok nil))
      (unwind-protect
           (progn
             (cond ((and writer (member :truncate mode)
                         (%storage-present-p dir))
                    (%delete-storage dir)
                    (%guard-storage db (lambda () (%create-storage db))))
                   ((probe-file (%header-file dir))
                    (%guard-storage db (lambda () (%open-existing db))))
                   ((%storage-present-p dir)
                    (%signal 'open-error "~a: incomplete database (open ~
                                          with :TRUNCATE to discard it)"
                             dir))
                   ((and writer (member :create mode))
                    (%guard-storage db (lambda () (%create-storage db))))
                   (t (%signal 'open-error
                               "~a: no database here (open with :CREATE)"
                               dir)))
             (when writer
               (%write-header db :open t))
             (setf ok t))
        (unless ok
          (%unlock db))))
    (setf (%db-open-p db) t)
    db))

(defmethod close-db ((db database))
  (with-write-lock ((%db-lock db))
    (prog1 (when (%db-open-p db)
             (when (%db-writable-p db)
               (%write-header db))
             (%close-storage db)
             (setf (%db-open-p db) nil)
             t)
      (%unlock db))))

;;; Per-key machinery

(defun %stripe (db digest)
  "The stripe lock for a 16-byte DIGEST."
  (aref (%db-stripes db)
        (logand (logior (aref digest 0) (ash (aref digest 1) 8))
                (1- +stripes+))))

(defun %check-open (db)
  (unless (%db-open-p db)
    (%signal 'invalid-argument "the database is closed")))

(defmacro with-key-locked ((db digest mode) &body body)
  "Run BODY holding DB's lock shared and DIGEST's stripe for MODE (:READ
or :WRITE)."
  (let ((d (gensym "DB")) (s (gensym "STRIPE")))
    `(let ((,d ,db))
       (with-read-lock ((%db-lock ,d))
         (%check-open ,d)
         (let ((,s (%stripe ,d ,digest)))
           ,(ecase mode
              (:read `(with-read-lock (,s) ,@body))
              (:write `(with-write-lock (,s) ,@body))))))))

(defun %fail (db code)
  "Record CODE as the calling thread's last failure on DB; return NIL."
  (with-lock-held ((%db-errors-lock db))
    (setf (gethash (current-thread) (%db-errors db)) code))
  nil)

(defmethod db-error ((db database))
  (with-lock-held ((%db-errors-lock db))
    (values (gethash (current-thread) (%db-errors db) :success))))

(defmacro %writing ((db) &body body)
  "Run BODY if DB is writable, then synchronize under :AUTOSYNC;
otherwise fail with :NO-PERMISSION."
  `(if (%db-writable-p ,db)
       (multiple-value-prog1 (progn ,@body)
         (when (%db-autosync-p ,db)
           (db-synchronize ,db)))
       (%fail ,db :no-permission)))

;;; Whole-database operations

(defmethod db-path ((db database))
  (namestring (%db-dir db)))

(defmethod db-count ((db database))
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (%record-count db)))

(defmethod db-synchronize ((db database) &key hard)
  (declare (ignore hard))
  (with-write-lock ((%db-lock db))
    (%check-open db)
    (when (%db-writable-p db)
      (%sync-storage db)
      (%write-header db :open t))
    t))

(defmethod db-clear ((db database))
  (if (%db-writable-p db)
      (with-write-lock ((%db-lock db))
        (%check-open db)
        (%close-storage db)
        (%delete-storage (%db-dir db))
        (%create-storage db)
        (%write-header db :open t)
        t)
      (%fail db :no-permission)))
```

- [ ] **Step 4: Replace `hash-db.lisp`**

Its per-key operations are unchanged apart from `%db-heap`; storage moves
behind the generics.

```lisp
;;;; HashDB: records in a heap, indexed by the linear hash from a key's
;;;; 16-byte digest to the first record of that digest's chain (spec:
;;;; HashDB).  DATABASE supplies the directory, header, modes and locks.

(in-package #:vivace-cabinet)

(defun murmur3-digest (key)
  (murmur3-128 key 0))

(defvar *key-digest* 'murmur3-digest
  "Function from key octets to a 16-byte digest.  Tests bind it to force
collisions; a database must keep one digest function for life.")

(defclass hash-db (database)
  ((index :initform nil :accessor hash-db-index)
   (record-count :initform 0 :accessor hash-db-record-count)
   (count-lock :initform (make-lock "hash-db count")
               :reader hash-db-count-lock)))

;;; Storage

(defmethod %type-code ((db hash-db)) 1)

(defmethod %record-count ((db hash-db))
  (with-lock-held ((hash-db-count-lock db))
    (hash-db-record-count db)))

(defun %count-records (db)
  "DB's records, counted by walking every chain in the index."
  (let ((heap (%db-heap db))
        (n 0))
    (map-lhash (lambda (entry)
                 (loop for addr = (cdr entry) then (record-next heap addr)
                       until (zerop addr)
                       do (incf n)))
               (hash-db-index db))
    n))

(defmethod %create-storage ((db hash-db))
  (destructuring-bind (&key buckets max-locks heap-size heap-reservation)
      (%db-tuning db)
    (let ((dir (%db-dir db)))
      (ensure-directories-exist (%index-dir dir))
      (setf (%db-heap db) (let ((*mmap-min-reservation* heap-reservation))
                            (create-memory (namestring (%heap-file dir))
                                           heap-size))
            (hash-db-index db) (make-lhash :location (%index-dir dir)
                                           :buckets buckets
                                           :max-locks max-locks)
            (hash-db-record-count db) 0))))

(defmethod %open-storage ((db hash-db) header)
  "Open the heap and the index, recounting the records if a writer left
them open."
  (destructuring-bind (&key heap-reservation &allow-other-keys)
      (%db-tuning db)
    (let ((dir (%db-dir db)))
      (setf (%db-heap db) (let ((*mmap-min-reservation* heap-reservation))
                            (open-memory (namestring (%heap-file dir))))
            (hash-db-index db) (open-lhash (%index-dir dir))
            (hash-db-record-count db) (if (getf header :open)
                                          (%count-records db)
                                          (getf header :count))))))

(defmethod %close-storage ((db hash-db))
  (when (hash-db-index db)
    (close-lhash (hash-db-index db))
    (setf (hash-db-index db) nil))
  (when (%db-heap db)
    (close-memory (%db-heap db))
    (setf (%db-heap db) nil)))

(defmethod %sync-storage ((db hash-db))
  (let ((index (hash-db-index db)))
    (sync-region (memory-mmap (%db-heap db)))
    (dolist (mf (list (%lhash-config index) (%lhash-table index)
                      (%lhash-overflow index)))
      (sync-region mf))))

(defun open-hash-db (dir &key (mode '(:writer :create)) (buckets 4)
                           (max-locks *max-locks*)
                           (heap-size (* 64 1024 1024))
                           (heap-reservation (* 64 1024 1024 1024)))
  "Open the HashDB in DIR.  MODE holds :READER or :WRITER, and any of
:CREATE, :TRUNCATE, :AUTOSYNC.  BUCKETS and MAX-LOCKS tune the linear
hash; HEAP-SIZE is the heap's first size; HEAP-RESERVATION is the address
space the heap may grow into before it must be reopened."
  (%check-mode mode)
  (%open-database
   (make-instance 'hash-db :dir dir
                           :writable (and (member :writer mode) t)
                           :autosync (and (member :autosync mode) t)
                           :tuning (list :buckets buckets
                                         :max-locks max-locks
                                         :heap-size heap-size
                                         :heap-reservation heap-reservation))
   mode))

;;; Per-key machinery

(defun %digest (key)
  "KEY's digest from *KEY-DIGEST*, with the linear hash's reserved
all-zero key remapped (spec: HashDB)."
  (let ((d (funcall *key-digest* key)))
    (if (every #'zerop d)
        (let ((c (copy-seq d)))
          (setf (aref c 15) 1)
          c)
        d)))

(defun %find (db digest key)
  "The address of KEY's record and of the record before it in DIGEST's
chain (NIL at the head); NIL if KEY is absent."
  (let ((heap (%db-heap db)))
    (loop with prev = nil
          for addr = (lhash-get (hash-db-index db) digest)
            then (record-next heap addr)
          until (or (null addr) (zerop addr))
          when (record-key= heap addr key)
            do (return (values addr prev))
          do (setf prev addr))))

(defun %insert-record (db digest key value)
  (let* ((index (hash-db-index db))
         (head (lhash-get index digest))
         (addr (write-record (%db-heap db) key value (or head 0))))
    (if head
        (lhash-update index digest addr)
        (lhash-insert index digest addr))
    (with-lock-held ((hash-db-count-lock db))
      (incf (hash-db-record-count db)))
    addr))

(defun %replace-record (db digest addr prev key value)
  (let* ((heap (%db-heap db))
         (new (write-record heap key value (record-next heap addr))))
    (if prev
        (setf (record-next heap prev) new)
        (lhash-update (hash-db-index db) digest new))
    (free-record heap addr)
    new))

(defun %unlink-record (db digest addr prev)
  (let* ((heap (%db-heap db))
         (next (record-next heap addr)))
    (cond (prev (setf (record-next heap prev) next))
          ((zerop next) (lhash-remove (hash-db-index db) digest))
          (t (lhash-update (hash-db-index db) digest next)))
    (free-record heap addr)
    (with-lock-held ((hash-db-count-lock db))
      (decf (hash-db-record-count db)))))

;;; Operations

(defmethod db-set ((db hash-db) key value)
  (%writing (db)
    (let* ((k (to-octets key)) (v (to-octets value)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (%replace-record db d addr prev k v)
              (%insert-record db d k v))
          t)))))

(defmethod db-add ((db hash-db) key value)
  (%writing (db)
    (let* ((k (to-octets key)) (v (to-octets value)) (d (%digest k)))
      (with-key-locked (db d :write)
        (if (%find db d k)
            (%fail db :duplicate-record)
            (progn (%insert-record db d k v) t))))))

(defmethod db-replace ((db hash-db) key value)
  (%writing (db)
    (let* ((k (to-octets key)) (v (to-octets value)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (progn (%replace-record db d addr prev k v) t)
              (%fail db :no-record)))))))

(defmethod db-append ((db hash-db) key value)
  (%writing (db)
    (let* ((k (to-octets key)) (v (to-octets value)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (%replace-record db d addr prev k
                               (concatenate
                                'octets
                                (record-value (%db-heap db) addr) v))
              (%insert-record db d k v))
          t)))))

(defmethod db-get ((db hash-db) key &key (as :octets))
  (check-as as)
  (let* ((k (to-octets key)) (d (%digest k)))
    (with-key-locked (db d :read)
      (let ((addr (%find db d k)))
        (if addr
            (from-octets (record-value (%db-heap db) addr) as)
            (%fail db :no-record))))))

(defmethod db-check ((db hash-db) key)
  (let* ((k (to-octets key)) (d (%digest k)))
    (with-key-locked (db d :read)
      (let ((addr (%find db d k)))
        (if addr
            (record-value-length (%db-heap db) addr)
            (%fail db :no-record))))))

(defmethod db-seize ((db hash-db) key &key (as :octets))
  (check-as as)
  (%writing (db)
    (let* ((k (to-octets key)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (prog1 (from-octets (record-value (%db-heap db) addr) as)
                (%unlink-record db d addr prev))
              (%fail db :no-record)))))))

(defmethod db-remove ((db hash-db) key)
  (%writing (db)
    (let* ((k (to-octets key)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (progn (%unlink-record db d addr prev) t)
              (%fail db :no-record)))))))

(defmethod db-size ((db hash-db))
  "Bytes in use: the heap's extent and the index's buckets and overflow.
File sizes would overstate: the index files are sparse."
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (let ((index (hash-db-index db)))
      (+ (read-memory-pointer (%db-heap db))
         (* (bucket-count index) (%lhash-bucket-bytes index))
         (read-lhash-next-overflow-pointer index)))))
```

- [ ] **Step 5: Dispatch `open-db` on the header**

In `api.lisp`, replace the whole `open-db` defun with:

```lisp
(defun %existing-type (dir args)
  "The type of the database in DIR, unless ARGS truncate it or its header
cannot be read (opening then reports that)."
  (let ((mode (getf args :mode)))
    (unless (and (listp mode) (member :writer mode) (member :truncate mode))
      (and (probe-file (%header-file dir))
           (ignore-errors (getf (%read-header dir) :type))))))

(defun open-db (path &rest args &key (type nil type-p) &allow-other-keys)
  "Open the database in directory PATH (a trailing / is added).  An
existing database opens as the type it is; TYPE (:HASH by default)
chooses what to create, and must match when given.  Other keywords:
OPEN-HASH-DB."
  (when (and type-p (not (member type '(:hash :tree))))
    (%signal 'invalid-argument "unknown database type ~s" type))
  (let* ((dir (uiop:ensure-directory-pathname (merge-pathnames path)))
         (found (%existing-type dir args)))
    (when (and found type-p (not (eq found type)))
      (%signal 'open-error "~a: a ~(~a~) database, not ~(~a~)"
               dir found type))
    (let ((args (alexandria:remove-from-plist args :type)))
      (ecase (or found type :hash)
        (:hash (apply #'open-hash-db dir args))
        (:tree (%signal 'not-implemented
                       "TreeDB is not built yet"))))))
```

In `vivace-cabinet.asd`, add `(:file "database")` after
`(:file "dir-lock")`.

- [ ] **Step 6: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures; `grep -a -i undefined` on the log finds
nothing.

- [ ] **Step 7: Mutation checks**

1. In `%check-mode`, drop `(listp mode)` from the `and`; run `VC-TEST
   bad-open-arguments-signal`; confirm it fails; restore.
2. In `%write-header`, write `2` instead of `(%type-code db)`; run
   `VC-TEST header-names-the-type`; confirm it fails; restore.

- [ ] **Step 8: Commit**

```bash
git add database.lisp \
  hash-db.lisp \
  api.lisp \
  vivace-cabinet.asd \
  tests/hash-db-modes-tests.lisp
git commit -m "A database base class shared by every type

The directory lock, header, open modes, error codes and stripe locks move
out of HashDB. The header names the database type, and OPEN-DB opens an
existing database as what it is. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 3: Octet order, the engine protocol and the B+ tree engine

**Files:**
- Create: `tree-engine.lisp`, `bplus-engine.lisp`,
  `tests/tree-engine-tests.lisp`
- Modify: `structures/bplus-tree.lisp` (`bpt-insert`, `bpt-remove`),
  `api.lisp`, `package.lisp`, `vivace-cabinet.asd`, `docs/provenance.md`

**Interfaces:**
- Consumes: Task 1's split; the heap and record functions.
- Produces: `(octets< a b)` (exported); condition `key-too-long`
  (exported); `%equal-under`; generics `engine-get`, `engine-put`,
  `engine-delete`, `engine-count`, `(engine-ceiling e key strict)`,
  `(engine-floor e key strict)` → `(values key value)` or NIL, KEY NIL for
  the first/last; `engine-address`, `engine-close`;
  `(make-bplus-engine heap &key less page-size)`,
  `(open-bplus-engine heap address &key less)`; B+ tree
  `%bpt-insert-top`, `%bpt-remove-top`. Tests: `def-engine-test`,
  `*engine-kinds*`, `make-test-engine`, `open-test-engine`,
  `with-temp-engine`, `oct`, `octets-of-length`.

- [ ] **Step 1: Write the failing tests**

Create `tests/tree-engine-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-suite tree-engine-suite
  :description "TreeDB's ordered engines, tested on a bare heap."
  :in vivace-cabinet-suite)

(in-suite tree-engine-suite)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *engine-kinds* '(:bplus-tree)
    "The engines each DEF-ENGINE-TEST runs on."))

(defvar *engine-kind* :bplus-tree)

(defun make-test-engine (heap)
  (ecase *engine-kind*
    (:bplus-tree (make-bplus-engine heap))))

(defun open-test-engine (heap address)
  (ecase *engine-kind*
    (:bplus-tree (open-bplus-engine heap address))))

(defmacro def-engine-test (name &body body)
  "Define NAME/<engine> in TREE-ENGINE-SUITE for each of *ENGINE-KINDS*."
  `(progn
     ,@(loop for kind in *engine-kinds*
             collect `(test (,(alexandria:symbolicate name "/" kind)
                             :suite tree-engine-suite)
                        (let ((*engine-kind* ,kind))
                          ,@body)))))

(defmacro with-temp-engine ((var) &body body)
  "Bind VAR to a new engine of *ENGINE-KIND* in a temp heap."
  (let ((heap (gensym "HEAP")))
    `(with-temp-memory (,heap)
       (let ((,var (make-test-engine ,heap)))
         ,@body))))

(defun oct (string)
  "STRING as UTF-8 octets."
  (babel:string-to-octets string :encoding :utf-8))

(defun octets-of-length (n byte)
  (make-array n :element-type '(unsigned-byte 8) :initial-element byte))

(def-engine-test engine-put-get-delete
  (with-temp-engine (e)
    (is (null (engine-get e (oct "a"))))
    (engine-put e (oct "a") (oct "1"))
    (engine-put e (oct "b") (oct "2"))
    (is (equalp (oct "1") (engine-get e (oct "a"))))
    (engine-put e (oct "a") (oct "one"))
    (is (equalp (oct "one") (engine-get e (oct "a"))))
    (is (= 2 (engine-count e)))
    (is-true (engine-delete e (oct "a")))
    (is (null (engine-delete e (oct "a"))))
    (is (null (engine-get e (oct "a"))))
    (is (= 1 (engine-count e)))))

(def-engine-test engine-empty-key-and-value
  (with-temp-engine (e)
    (engine-put e (oct "") (oct ""))
    (engine-put e (oct "a") (oct "x"))
    (is (equalp (oct "") (engine-get e (oct ""))))
    (is (equalp (oct "") (engine-ceiling e nil nil)))
    (is (equalp (oct "a") (engine-ceiling e (oct "") t)))
    (is (equalp (oct "") (engine-floor e (oct "a") t)))))

(def-engine-test engine-orders-keys
  "Ceiling and floor, strict and not, walk the keys in unsigned byte
order; a key that is a prefix of another sorts first."
  (with-temp-engine (e)
    (let* ((*random-state* (sb-ext:seed-random-state 7))
           (keys (remove-duplicates
                  (loop repeat 1000
                        collect (let ((v (octets-of-length (1+ (random 6))
                                                           0)))
                                  (dotimes (i (length v) v)
                                    (setf (aref v i) (random 256)))))
                  :test #'equalp))
           (sorted (sort (copy-list keys) #'octets<)))
      (dolist (key keys)
        (engine-put e key (reverse key)))
      (is (= (length keys) (engine-count e)))
      (is (equalp sorted
                  (loop for key = (engine-ceiling e nil nil)
                          then (engine-ceiling e key t)
                        while key collect key)))
      (is (equalp (reverse sorted)
                  (loop for key = (engine-floor e nil nil)
                          then (engine-floor e key t)
                        while key collect key)))
      (multiple-value-bind (key value) (engine-ceiling e (first sorted) nil)
        (is (equalp (first sorted) key))
        (is (equalp (reverse (first sorted)) value)))
      (is (null (engine-ceiling e (car (last sorted)) t)))
      (is (null (engine-floor e (first sorted) t))))))

(def-engine-test engine-ceiling-and-floor-of-absent-keys
  (with-temp-engine (e)
    (dolist (s '("b" "d" "f"))
      (engine-put e (oct s) (oct s)))
    (is (equalp (oct "d") (engine-ceiling e (oct "c") nil)))
    (is (equalp (oct "d") (engine-ceiling e (oct "c") t)))
    (is (equalp (oct "b") (engine-floor e (oct "c") nil)))
    (is (equalp (oct "d") (engine-floor e (oct "dd") t)))
    (is (equalp (oct "b") (engine-ceiling e (oct "") nil)))
    (is (null (engine-ceiling e (oct "g") nil)))
    (is (null (engine-floor e (oct "a") nil)))
    (is (equalp (oct "f") (engine-floor e (oct "zzz") nil)))))

(def-engine-test engine-holds-mixed-sizes
  "400 records, keys of 2 to 1024 bytes and values up to 50 KB, in random
order; then half of them removed."
  (with-temp-engine (e)
    (let* ((*random-state* (sb-ext:seed-random-state 11))
           (records
             (loop for i below 400
                   collect (let ((k (octets-of-length (+ 2 (random 1023))
                                                      7)))
                             (setf (aref k 0) (ldb (byte 8 8) i)
                                   (aref k 1) (ldb (byte 8 0) i))
                             (cons k (octets-of-length
                                      (nth (mod i 5) '(0 10 1000 3000 50000))
                                      (mod i 256)))))))
      (dolist (r (alexandria:shuffle (copy-list records)))
        (engine-put e (car r) (cdr r)))
      (is (= 400 (engine-count e)))
      (is (every (lambda (r) (equalp (cdr r) (engine-get e (car r))))
                 records))
      (loop for r in records
            for i from 0
            when (evenp i) do (engine-delete e (car r)))
      (is (= 200 (engine-count e)))
      (is (every (lambda (r) (equalp (cdr r) (engine-get e (car r))))
                 (loop for r in records
                       for i from 0
                       when (oddp i) collect r))))))

(def-engine-test engine-reopens-at-its-address
  (with-temp-memory (heap)
    (let ((e (make-test-engine heap)))
      (dotimes (i 50)
        (engine-put e (oct (format nil "k~2,'0d" i)) (oct "v")))
      (engine-close e)
      (let ((again (open-test-engine heap (engine-address e))))
        (is (= 50 (engine-count again)))
        (is (equalp (oct "k00") (engine-ceiling again nil nil)))
        (is (equalp (oct "k49") (engine-floor again nil nil)))))))

(def-engine-test engine-copies-keys-and-values
  "Changing a vector after storing it, or one the engine returned, leaves
the record as it was."
  (with-temp-engine (e)
    (let ((key (oct "key"))
          (value (oct "value")))
      (engine-put e key value)
      (fill key 0)
      (fill value 0)
      (let ((got (engine-get e (oct "key"))))
        (is (equalp (oct "value") got))
        (fill got 0))
      (is (equalp (oct "value") (engine-get e (oct "key")))))))

(test bplus-engine-key-limit
  "A key over a quarter page signals KEY-TOO-LONG; a quarter page is fine."
  (with-temp-memory (heap)
    (let ((e (make-bplus-engine heap)))
      (finishes (engine-put e (octets-of-length 1024 1) (oct "v")))
      (signals key-too-long (engine-put e (octets-of-length 1025 1)
                                        (oct "v"))))))

(test bplus-engine-frees-out-of-line-values
  "Replacing or removing a value kept out of line frees its record."
  (with-temp-memory (heap)
    (let ((e (make-bplus-engine heap))
          (big (octets-of-length 5000 3)))
      (engine-put e (oct "k") big)
      (engine-put e (oct "k") big)
      (let ((before (read-memory-pointer heap)))
        (dotimes (i 50)
          (engine-put e (oct "k") big))
        (engine-delete e (oct "k"))
        (engine-put e (oct "k") big)
        (is (= before (read-memory-pointer heap)))))))
```

In `vivace-cabinet.asd`, add `(:file "tree-engine-tests")` after
`"hash-db-modes-tests"` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; every test in `tree-engine-suite` fails
(`UNDEFINED-FUNCTION` `MAKE-BPLUS-ENGINE`, an unbound `KEY-TOO-LONG`
class); everything else passes.

- [ ] **Step 3: Give `bpt-insert` and `bpt-remove` lock-free cores**

TreeDB replaces a value by removing and inserting under one write lock. In
`structures/bplus-tree.lisp`, replace the whole `bpt-insert` defun with:

```lisp
(defun %bpt-insert-top (tree dkey skey sval)
  "BPT-INSERT's work, for a caller holding the tree's write lock."
  (let ((res (%bpt-insert tree (%bpt-root tree) dkey skey sval)))
    (cond ((eq res :dup) nil)
          (t
           (when (consp res)
             ;; Root split: grow a new internal root.
             (destructuring-bind (sep-dkey sep-skey right-addr) res
               (let ((new-root (%bpt-alloc-page tree))
                     (old-root (%bpt-root tree)))
                 (%bpt-write-page
                  tree new-root
                  (%bpt-encode-page tree nil old-root
                                    (list (list sep-dkey sep-skey
                                                right-addr))))
                 (setf (%bpt-root tree) new-root)
                 (incf (%bpt-height tree)))))
           (incf (%bpt-count tree))
           (%bpt-sync-root tree)
           t))))

(defun bpt-insert (tree dkey skey sval)
  "Insert DKEY -> value.  DKEY is the deserialized key; SKEY / SVAL the serialized
key / value bytes.  Duplicate keys are a no-op (returns NIL); returns T on insert."
  (with-bpt-write-lock (tree)
    (%bpt-insert-top tree dkey skey sval)))
```

and the whole `bpt-remove` defun with:

```lisp
(defun %bpt-remove-top (tree dkey &optional (sval nil sval-p) value-equal)
  "BPT-REMOVE's work, for a caller holding the tree's write lock."
  (let ((veq (or value-equal (%bpt-value-equal tree))))
    (multiple-value-bind (status)
        (%bpt-delete tree (%bpt-root tree) dkey sval sval-p veq t)
      (when (eq status :removed)
        (%bpt-maybe-collapse-root tree)
        (decf (%bpt-count tree))
        (%bpt-sync-root tree)
        t))))

(defun bpt-remove (tree dkey &optional (sval nil sval-p) value-equal)
  "Remove DKEY from its leaf.  With SVAL given, only remove when the stored value
also matches (via VALUE-EQUAL or the tree's).  Returns T if a key was removed.
Merges underfull pages on the way up and collapses a degenerate root."
  (with-bpt-write-lock (tree)
    (if sval-p
        (%bpt-remove-top tree dkey sval value-equal)
        (%bpt-remove-top tree dkey))))
```

In `docs/provenance.md`, append to the B+ tree row's last cell:
`; BPT-INSERT and BPT-REMOVE run lock-free cores, %BPT-INSERT-TOP and
%BPT-REMOVE-TOP, which TreeDB calls under one lock`.

- [ ] **Step 4: Write `tree-engine.lisp`**

```lisp
;;;; The ordered store under TreeDB, one per engine (spec: TreeDB).  Keys
;;;; and values are octets.  ENGINE-CEILING and ENGINE-FLOOR give TreeDB
;;;; its order; with KEY NIL they find the first and the last record.

(in-package #:vivace-cabinet)

(defun octets< (a b)
  "Unsigned lexicographic order on octet vectors; a prefix sorts first.
TreeDB's default comparator."
  (let ((m (mismatch a b)))
    (cond ((null m) nil)
          ((= m (length a)) t)
          ((= m (length b)) nil)
          (t (< (aref a m) (aref b m))))))

(defun %equal-under (less)
  "The key equality the strict order LESS implies."
  (lambda (a b)
    (not (or (funcall less a b) (funcall less b a)))))

(defgeneric engine-get (engine key)
  (:documentation "KEY's value, or NIL."))

(defgeneric engine-put (engine key value)
  (:documentation "Store VALUE under KEY, replacing any value; T."))

(defgeneric engine-delete (engine key)
  (:documentation "Remove KEY; true if it was there."))

(defgeneric engine-count (engine))

(defgeneric engine-ceiling (engine key strict)
  (:documentation "The first record at or after KEY (after it when
STRICT) as (values key value), or NIL; the first record when KEY is NIL."))

(defgeneric engine-floor (engine key strict)
  (:documentation "The last record at or before KEY (before it when
STRICT) as (values key value), or NIL; the last record when KEY is NIL."))

(defgeneric engine-address (engine)
  (:documentation "Where the engine's header lies in the heap."))

(defgeneric engine-close (engine))
```

- [ ] **Step 5: Write `bplus-engine.lisp`**

```lisp
;;;; TreeDB's default engine: the B+ tree.  Keys sit in the pages; a value
;;;; sits there too when it and its key fit a quarter page, else in a heap
;;;; record the page points to.  So every cell fits a quarter page and a
;;;; full page always splits into two that fit (spec: TreeDB; #4).

(in-package #:vivace-cabinet)

(defclass bplus-engine ()
  ((tree :initarg :tree :reader %bpe-tree)
   (heap :initarg :heap :reader %bpe-heap)))

(defun %bpe-tree-args (less)
  (list :key-comparison less :key-equal (%equal-under less)
        :value-equal 'equalp
        :key-serializer 'identity :key-deserializer 'identity
        :value-serializer 'identity :value-deserializer 'identity))

(defun make-bplus-engine (heap &key (less 'octets<) (page-size 4096))
  (make-instance 'bplus-engine
                 :heap heap
                 :tree (apply #'make-bplus-tree :heap heap
                              :page-size page-size (%bpe-tree-args less))))

(defun open-bplus-engine (heap address &key (less 'octets<))
  (make-instance 'bplus-engine
                 :heap heap
                 :tree (apply #'open-bplus-tree :heap heap :address address
                              (%bpe-tree-args less))))

(defun %bpe-quarter (e)
  (floor (%bpt-page-size (%bpe-tree e)) 4))

(defun %bpe-encode (e key value)
  "VALUE's leaf bytes: 0 and the value, or 1 and the address of a heap
record holding it when KEY and VALUE together exceed a quarter page."
  (if (<= (+ (length key) (length value)) (%bpe-quarter e))
      (let ((v (make-array (1+ (length value))
                           :element-type '(unsigned-byte 8))))
        (setf (aref v 0) 0)
        (replace v value :start1 1))
      (let ((v (make-array 9 :element-type '(unsigned-byte 8)
                             :initial-element 1))
            (addr (write-record (%bpe-heap e)
                                (make-array 0 :element-type
                                            '(unsigned-byte 8))
                                value 0)))
        (dotimes (i 8 v)
          (setf (aref v (1+ i)) (ldb (byte 8 (* 8 i)) addr))))))

(defun %bpe-record (sval)
  "The heap record address in leaf bytes SVAL, or NIL for an inline value."
  (when (= 1 (aref sval 0))
    (let ((addr 0))
      (dotimes (i 8 addr)
        (setf addr (logior addr (ash (aref sval (1+ i)) (* 8 i))))))))

(defun %bpe-decode (e sval)
  (let ((addr (%bpe-record sval)))
    (if addr
        (record-value (%bpe-heap e) addr)
        (subseq sval 1))))

(defun %bpe-free (e sval)
  "Free the heap record leaf bytes SVAL point to, if any."
  (let ((addr (and sval (%bpe-record sval))))
    (when addr
      (free-record (%bpe-heap e) addr))))

;;; Ordered lookups in the leaves; the caller holds the tree's lock.

(defun %bpt-entry-at (buf idx)
  "The key and value bytes of leaf slot IDX in BUF."
  (let* ((slot (%bpt-slot-off buf idx))
         (klen (buf-u16 buf slot)))
    (values (subseq buf (+ slot 2) (+ slot 2 klen))
            (%bpt-cell-sval buf slot))))

(defun %bpt-ceiling (tree key strict)
  "The first leaf entry at or after KEY (after it when STRICT), or the
first entry when KEY is NIL, as (values key value-bytes); NIL past the
end."
  (multiple-value-bind (buf count link idx)
      (if key
          (%bpt-leaf-at tree key)
          (multiple-value-bind (b c l) (%bpt-leftmost-leaf tree)
            (values b c l 0)))
    (when (and key strict (< idx count)
               (bpt-key= tree key
                         (%bpt-slot-key tree buf (%bpt-slot-off buf idx))))
      (incf idx))
    (loop while (and (>= idx count) (/= link 0))
          do (setf buf (%bpt-read-page tree link buf)
                   count (buf-u16 buf +bpt-p-count-offset+)
                   link (buf-u64 buf +bpt-p-link-offset+)
                   idx 0))
    (when (< idx count)
      (%bpt-entry-at buf idx))))

(defun %bpt-rightmost-leaf (tree addr)
  "The last leaf under the page at ADDR."
  (let ((buf nil))
    (loop
      (setf buf (%bpt-read-page tree addr buf))
      (when (%bpt-leaf-p buf)
        (return buf))
      (let ((n (buf-u16 buf +bpt-p-count-offset+)))
        (setf addr (if (zerop n)
                       (buf-u64 buf +bpt-p-link-offset+)
                       (%bpt-slot-child buf (1- n))))))))

(defun %bpt-last-entry (buf)
  (let ((n (buf-u16 buf +bpt-p-count-offset+)))
    (when (plusp n)
      (%bpt-entry-at buf (1- n)))))

(defun %bpt-floor (tree key strict)
  "The last leaf entry at or before KEY (before it when STRICT), or the
last entry when KEY is NIL, as (values key value-bytes); NIL before the
start.  Leaves link forward only, so the descent remembers the subtree
just left of its path."
  (if (null key)
      (%bpt-last-entry (%bpt-rightmost-leaf tree (%bpt-root tree)))
      (let ((addr (%bpt-root tree))
            (buf nil)
            (left nil))
        (loop
          (setf buf (%bpt-read-page tree addr buf))
          (when (%bpt-leaf-p buf)
            (return))
          (let ((idx (%bpt-page-bsearch tree buf
                                        (buf-u16 buf +bpt-p-count-offset+)
                                        key)))
            (cond ((> idx 0) (setf left (%bpt-slot-child buf (1- idx))))
                  ((= idx 0) (setf left (buf-u64 buf +bpt-p-link-offset+))))
            (setf addr (if (< idx 0)
                           (buf-u64 buf +bpt-p-link-offset+)
                           (%bpt-slot-child buf idx)))))
        (multiple-value-bind (idx exact)
            (%bpt-page-bsearch tree buf (buf-u16 buf +bpt-p-count-offset+)
                               key)
          (when (and exact strict)
            (decf idx))
          (cond ((>= idx 0) (%bpt-entry-at buf idx))
                (left (%bpt-last-entry (%bpt-rightmost-leaf tree left))))))))

;;; The engine protocol

(defmethod engine-get ((e bplus-engine) key)
  (let ((tree (%bpe-tree e)))
    (with-bpt-read-lock (tree)
      (multiple-value-bind (sval found) (%bpt-find tree key)
        (and found (%bpe-decode e sval))))))

(defmethod engine-put ((e bplus-engine) key value)
  (when (> (length key) (%bpe-quarter e))
    (%signal 'key-too-long "a ~d-byte key; the B+ tree's limit is ~d"
             (length key) (%bpe-quarter e)))
  (let ((tree (%bpe-tree e))
        (sval (%bpe-encode e key value))
        (old nil))
    (with-bpt-write-lock (tree)
      (multiple-value-bind (osval found) (%bpt-find tree key)
        (when found
          (setf old osval)
          (%bpt-remove-top tree key)))
      (%bpt-insert-top tree key key sval))
    (%bpe-free e old)
    t))

(defmethod engine-delete ((e bplus-engine) key)
  (let ((tree (%bpe-tree e))
        (old nil))
    (with-bpt-write-lock (tree)
      (multiple-value-bind (osval found) (%bpt-find tree key)
        (when found
          (setf old osval)
          (%bpt-remove-top tree key))))
    (when old
      (%bpe-free e old)
      t)))

(defmethod engine-count ((e bplus-engine))
  (bplus-tree-count (%bpe-tree e)))

(defmethod engine-ceiling ((e bplus-engine) key strict)
  (let ((tree (%bpe-tree e)))
    (with-bpt-read-lock (tree)
      (multiple-value-bind (k sval) (%bpt-ceiling tree key strict)
        (and k (values k (%bpe-decode e sval)))))))

(defmethod engine-floor ((e bplus-engine) key strict)
  (let ((tree (%bpe-tree e)))
    (with-bpt-read-lock (tree)
      (multiple-value-bind (k sval) (%bpt-floor tree key strict)
        (and k (values k (%bpe-decode e sval)))))))

(defmethod engine-address ((e bplus-engine))
  (%bpt-address (%bpe-tree e)))

(defmethod engine-close ((e bplus-engine))
  (close-bplus-tree (%bpe-tree e)))
```

In `api.lisp`, after `(define-condition open-error (vivace-cabinet-error)
())`, add:

```lisp
(define-condition key-too-long (vivace-cabinet-error) ())
```

In `package.lisp`, extend the export list: after `#:db-error` add
`#:key-too-long #:octets<` (on a new line, keeping 80 columns). In
`vivace-cabinet.asd`, add `(:file "tree-engine")` and
`(:file "bplus-engine")` after `(:file "hash-db")`.

- [ ] **Step 6: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures, no undefined names.

- [ ] **Step 7: Mutation checks**

1. In `%bpt-floor`, replace the `cond` that sets `left` with `(progn)`;
   run `VC-TEST tree-engine-suite`; confirm `engine-orders-keys/bplus-tree`
   fails; restore.
2. In `octets<`, swap the two prefix clauses' results (`t` and `nil`); run
   `VC-TEST tree-engine-suite`; confirm failures; restore.
3. In `engine-put` (B+ tree), delete `(%bpe-free e old)`; run `VC-TEST
   bplus-engine-frees-out-of-line-values`; confirm it fails; restore.
4. In `%bpe-encode`, make the test `(if t`; run `VC-TEST
   tree-engine-suite`; confirm `engine-holds-mixed-sizes/bplus-tree`
   fails; restore.

- [ ] **Step 8: Commit**

```bash
git add tree-engine.lisp \
  bplus-engine.lisp \
  tests/tree-engine-tests.lisp \
  structures/bplus-tree.lisp \
  api.lisp \
  package.lisp \
  vivace-cabinet.asd \
  docs/provenance.md
git commit -m "TreeDB's engine protocol and the B+ tree engine

Octet keys in unsigned byte order; values in the page, or in a heap record
when key and value exceed a quarter page; keys over a quarter page
signal KEY-TOO-LONG. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 4: The skip-list engine

**Files:**
- Create: `skip-list-engine.lisp`
- Modify: `tests/tree-engine-tests.lisp`, `vivace-cabinet.asd`

**Interfaces:**
- Consumes: Task 3's protocol and tests.
- Produces: `(make-skip-list-engine heap &key less)`,
  `(open-skip-list-engine heap address &key less)`, class
  `skip-list-engine`.

- [ ] **Step 1: Run the engine tests on the skip list too**

In `tests/tree-engine-tests.lisp`: change `*engine-kinds*` to
`'(:bplus-tree :skip-list)`; in `make-test-engine` add the clause
`(:skip-list (make-skip-list-engine heap))`; in `open-test-engine` add
`(:skip-list (open-skip-list-engine heap address))`.

- [ ] **Step 2: Run them and watch the skip-list half fail**

Run: `VC-TEST tree-engine-suite`
Expected: non-zero exit; every `…/skip-list` test fails
(`UNDEFINED-FUNCTION` `MAKE-SKIP-LIST-ENGINE`); the `…/bplus-tree` ones
pass.

- [ ] **Step 3: Write `skip-list-engine.lisp`**

```lisp
;;;; TreeDB's skip-list engine: each record a heap node of any size (spec:
;;;; TreeDB).  Keys are stored after a 4-byte length.  The list caches and
;;;; returns the vectors it was given, so the engine keeps and hands out
;;;; copies.

(in-package #:vivace-cabinet)

(defclass skip-list-engine ()
  ((sl :initarg :sl :reader %sle-list)))

(defun %sle-encode-key (key)
  "KEY as a 4-byte little-endian length and its octets.  The head and
tail sentinels' key, :END, is length #xFFFFFFFF, which no key can have."
  (let* ((end (eq key :end))
         (n (if end 0 (length key)))
         (v (make-array (+ 4 n) :element-type '(unsigned-byte 8))))
    (dotimes (i 4)
      (setf (aref v i) (if end 255 (ldb (byte 8 (* 8 i)) n))))
    (unless end
      (replace v key :start1 4))
    v))

(defun %sle-decode-key (bytes)
  "The key at the start of BYTES, and the bytes it took."
  (let ((n (logior (aref bytes 0) (ash (aref bytes 1) 8)
                   (ash (aref bytes 2) 16) (ash (aref bytes 3) 24))))
    (if (= n #xFFFFFFFF)
        (values :end 4)
        (values (subseq bytes 4 (+ 4 n)) (+ 4 n)))))

(defun %sle-key-equal (less)
  "Key equality under LESS.  The list's search tests its tail against
the key, so the sentinels' :END must never match, not even an empty key."
  (let ((equal (%equal-under less)))
    (lambda (a b)
      (and (not (eq a :end)) (not (eq b :end)) (funcall equal a b)))))

(defun %sle-args (less)
  (list :key-equal (%sle-key-equal less) :key-comparison less
        :key-serializer '%sle-encode-key :key-deserializer '%sle-decode-key
        :value-serializer 'identity :value-deserializer 'identity
        :duplicates-allowed-p nil :value-equal 'equalp))

(defun make-skip-list-engine (heap &key (less 'octets<))
  (let ((none (make-array 0 :element-type '(unsigned-byte 8))))
    (make-instance 'skip-list-engine
                   :sl (apply #'make-skip-list :heap heap
                              :head-key :end :head-value none
                              :tail-key :end :tail-value none
                              (%sle-args less)))))

(defun open-skip-list-engine (heap address &key (less 'octets<))
  (make-instance 'skip-list-engine
                 :sl (apply #'open-skip-list :heap heap :address address
                            (%sle-args less))))

(defun %sle-copies (node)
  "Copies of NODE's key and value, as (values key value)."
  (values (copy-seq (%sn-key node)) (copy-seq (%sn-value node))))

(defun %sle-real-p (sl node)
  "True unless NODE is NIL or SL's head or tail."
  (and node
       (/= (%sn-addr node) (%sl-head-pointer sl))
       (/= (%sn-addr node) (%sl-tail-pointer sl))))

(defun %sle-search (sl key)
  "KEY's level-0 predecessor and successor in SL."
  (let ((preds (make-array (%sl-max-level sl)))
        (succs (make-array (%sl-max-level sl))))
    (%find-in-skip-list sl key preds succs)
    (values (aref preds 0) (aref succs 0))))

(defun %sle-last (sl)
  "SL's last node, or its head when SL is empty: descend each level
until the next node is the tail."
  (let ((pred (%sl-head sl))
        (tail (%sl-tail-pointer sl)))
    (loop for level from (1- (%sl-max-level sl)) downto 0
          do (loop for next = (aref (%sn-pointers pred) level)
                   until (= next tail)
                   do (setf pred (read-skip-node sl next))))
    pred))

(defmethod engine-get ((e skip-list-engine) key)
  (let ((node (%find-in-skip-list (%sle-list e) key)))
    (and node (copy-seq (%sn-value node)))))

(defmethod engine-put ((e skip-list-engine) key value)
  (let ((sl (%sle-list e))
        (k (copy-seq key)))
    (when (%find-in-skip-list sl k)
      (remove-from-skip-list sl k))
    (add-to-skip-list sl k (copy-seq value))
    t))

(defmethod engine-delete ((e skip-list-engine) key)
  (remove-from-skip-list (%sle-list e) key))

(defmethod engine-count ((e skip-list-engine))
  (%sl-length (%sle-list e)))

(defmethod engine-ceiling ((e skip-list-engine) key strict)
  (let* ((sl (%sle-list e))
         (node (if key
                   (nth-value 1 (%sle-search sl key))
                   (node-forward sl (%sl-head sl)))))
    (when (and key strict (%sle-real-p sl node)
               (funcall (%sl-key-equal sl) key (%sn-key node)))
      (setf node (node-forward sl node)))
    (when (%sle-real-p sl node)
      (%sle-copies node))))

(defmethod engine-floor ((e skip-list-engine) key strict)
  (let* ((sl (%sle-list e))
         (node (if key
                   (multiple-value-bind (pred succ) (%sle-search sl key)
                     (if (and (not strict) (%sle-real-p sl succ)
                              (funcall (%sl-key-equal sl) key
                                       (%sn-key succ)))
                         succ
                         pred))
                   (%sle-last sl))))
    (when (%sle-real-p sl node)
      (%sle-copies node))))

(defmethod engine-address ((e skip-list-engine))
  (%sl-address (%sle-list e)))

(defmethod engine-close ((e skip-list-engine))
  (close-skip-list (%sle-list e)))
```

In `vivace-cabinet.asd`, add `(:file "skip-list-engine")` after
`(:file "bplus-engine")`.

- [ ] **Step 4: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures.

- [ ] **Step 5: Mutation checks**

1. In `engine-put` (skip list), pass `value` instead of
   `(copy-seq value)`; run `VC-TEST
   engine-copies-keys-and-values/skip-list`; confirm it fails; restore.
2. Make `%sle-last` return `(%sl-head sl)`; run `VC-TEST
   engine-orders-keys/skip-list`; confirm it fails; restore.
3. Run `timeout 600` with `%sle-key-equal` returning `(funcall equal a b)`
   alone: `engine-empty-key-and-value/skip-list` must not pass (it loops;
   the timeout ends it). Restore.

- [ ] **Step 6: Commit**

```bash
git add skip-list-engine.lisp \
  tests/tree-engine-tests.lisp \
  vivace-cabinet.asd
git commit -m "TreeDB's skip-list engine

Records as heap nodes of any size. The sentinels get a key no record can
have: the copied search tests its tail against the key, so an empty key
used to match it. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 5: TreeDB, and the API tests on every engine

**Files:**
- Create: `tree-db.lisp`, `tests/tree-db-tests.lisp`
- Modify: `api.lisp` (`open-db`), `tests/support.lisp`,
  `tests/hash-db-tests.lisp`, `tests/hash-db-modes-tests.lisp`,
  `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: Task 2's base, Tasks 3-4's engines.
- Produces: class `tree-db` (`tree-db-engine`); `(open-tree-db dir &key
  mode engine page-size comparator heap-size heap-reservation)`;
  `open-db :type :tree`. Tests: `*db-type-args*`, `open-test-db`,
  `with-test-db`, suite `api-suite`, `*db-kinds*`, `db-test-forms`,
  `def-db-test`.

- [ ] **Step 1: Make the API tests run on every kind**

Append to `tests/support.lisp`:

```lisp
(defvar *db-type-args* '(:type :hash)
  "OPEN-DB arguments naming the database type a test runs on.")

(defun open-test-db (path &rest args)
  "OPEN-DB on PATH with ARGS and *DB-TYPE-ARGS*."
  (apply #'open-db path (append args *db-type-args*)))

(defmacro with-test-db ((var path &rest args) &body body)
  "WITH-DB through OPEN-TEST-DB."
  `(let ((,var (open-test-db ,path ,@args)))
     (unwind-protect (progn ,@body)
       (close-db ,var))))

(def-suite api-suite
  :description "The API on every database type and engine."
  :in vivace-cabinet-suite)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *db-kinds*
    '((hash :type :hash)
      (bplus-tree :type :tree :engine :bplus-tree)
      (skip-list :type :tree :engine :skip-list))
    "Each kind of database an API test runs on: a name and OPEN-DB args.")

  (defun db-test-forms (name body kinds)
    "One test per kind in KINDS, named NAME/<kind>, in API-SUITE."
    (let ((doc (and (stringp (first body)) (list (first body))))
          (body (if (stringp (first body)) (rest body) body)))
      (loop for (kind . args) in kinds
            collect `(test (,(alexandria:symbolicate name "/" kind)
                            :suite api-suite)
                       ,@doc
                       (let ((*db-type-args* ',args))
                         ,@body))))))

(defmacro def-db-test (name &body body)
  "Define NAME/<kind> in API-SUITE for every kind in *DB-KINDS*."
  `(progn ,@(db-test-forms name body *db-kinds*)))
```

and in its `with-temp-db`, open with `open-test-db` instead of `open-db`:

```lisp
       (let ((,var (open-test-db (merge-pathnames "t.vch/" ,dir)
                                 ,@open-args)))
```

Then convert the tests that are not HashDB's alone with this script:

```bash
python3 - <<'EOF'
GENERIC = {
 'tests/hash-db-tests.lisp': [
  'set-and-get', 'missing-keys-give-nil-and-no-record',
  'add-replace-append', 'check-seize-remove', 'values-change-size',
  'empty-keys-and-values', 'large-values', 'non-ascii-strings',
  'errors-are-per-thread', 'bad-arguments-signal',
  'reopen-keeps-everything', 'corrupt-header-signals',
  'closed-databases-refuse-use', 'concurrent-writers-are-consistent'],
 'tests/hash-db-modes-tests.lisp': [
  'synchronize-persists-the-count', 'autosync-writes-through',
  'reader-mode-refuses-writes', 'opening-needs-create-or-a-database',
  'truncate-empties', 'paths-become-directories', 'size-grows',
  'clear-empties-and-stays-usable', 'one-writer-or-many-readers',
  'truncate-needs-no-create', 'incomplete-databases-signal-or-truncate'],
}
for path, names in GENERIC.items():
    text = open(path).read()
    for name in names:
        start = text.index('\n(test %s\n' % name) + 1
        end = text.find('\n(', start + 1)
        end = len(text) if end < 0 else end
        form = text[start:end]
        form = form.replace('(test %s\n' % name, '(def-db-test %s\n' % name, 1)
        form = form.replace('(with-db (', '(with-test-db (')
        form = form.replace('(open-db ', '(open-test-db ')
        text = text[:start] + form + text[end:]
    open(path, 'w').write(text)
p = 'tests/hash-db-modes-tests.lisp'
t = open(p).read()
old = "      (signals not-implemented (open-db path :type :tree)))))"
assert t.count(old) == 1
t = t.replace(old, "      (signals invalid-argument\n"
                   "               (open-db path :type :tree :engine :bogus)))))")
open(p, 'w').write(t)
EOF
```

The tests left as plain `test` (collisions, digests, recounting, the
index, heap reuse) are HashDB's alone.

- [ ] **Step 2: Write the TreeDB tests**

Create `tests/tree-db-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-suite tree-db-suite
  :description "TreeDB: types, engines, limits and reopening."
  :in vivace-cabinet-suite)

(in-suite tree-db-suite)

(test tree-db-opens-as-what-it-is
  "An existing database opens as its own type and engine; asking for
another signals OPEN-ERROR, unless a writer truncates it."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "s.vct/" dir)))
      (with-db (db path :type :tree :engine :skip-list)
        (db-set db "k" "v"))
      (with-db (db path)
        (is (typep db 'tree-db))
        (is (typep (tree-db-engine db) 'skip-list-engine))
        (is (equal "v" (db-get db "k" :as :string))))
      (signals open-error (open-db path :type :hash))
      (signals open-error (open-db path :type :tree :engine :bplus-tree))
      (with-db (db path :mode '(:writer :truncate) :type :hash)
        (is (typep db 'hash-db))
        (is (= 0 (db-count db)))))))

(test tree-db-key-limit
  "The B+ tree engine refuses keys over a quarter page; the skip list
takes them."
  (with-temp-directory (dir)
    (let ((long (make-string 1025 :initial-element #\k)))
      (with-db (db (merge-pathnames "b.vct/" dir) :type :tree)
        (signals key-too-long (db-set db long "v"))
        (is-true (db-set db (subseq long 1) "v"))
        (is (= 1 (db-count db))))
      (with-db (db (merge-pathnames "s.vct/" dir)
                   :type :tree :engine :skip-list)
        (is-true (db-set db (make-string 5000 :initial-element #\k) "v"))))))

(test tree-db-out-of-line-values-survive-reopen
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "o.vct/" dir))
          (big (make-string 100000 :initial-element #\b)))
      (with-db (db path :type :tree)
        (db-set db "big" big)
        (db-set db "small" "s")
        (db-set db "mid" (make-string 2000 :initial-element #\m)))
      (with-db (db path)
        (is (equal big (db-get db "big" :as :string)))
        (is (= 2000 (db-check db "mid")))
        (is-true (db-set db "big" "now small"))
        (is (equal "now small" (db-get db "big" :as :string)))
        (is (= 3 (db-count db)))))))

(test tree-db-small-pages
  "With 1024-byte pages, keys up to 256 bytes work and longer ones
signal."
  (with-temp-directory (dir)
    (with-db (db (merge-pathnames "p.vct/" dir) :type :tree :page-size 1024)
      (dotimes (i 300)
        (db-set db (format nil "~3,'0d~a" i
                           (make-string 200 :initial-element #\k))
                (make-string 300 :initial-element #\v)))
      (is (= 300 (db-count db)))
      (is (= 300 (db-check db (format nil "150~a"
                                      (make-string 200
                                                   :initial-element #\k)))))
      (signals key-too-long
        (db-set db (make-string 257 :initial-element #\k) "v")))))

(test tree-db-bad-arguments-signal
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "x.vct/" dir)))
      (signals invalid-argument (open-db path :type :tree :engine :bogus))
      (signals invalid-argument (open-db path :type :tree :page-size 100))
      (signals invalid-argument (open-db path :type :tree
                                              :page-size 65536)))))
```

In `vivace-cabinet.asd`, add `(:file "tree-db-tests")` after
`"tree-engine-tests"` in the test system.

- [ ] **Step 3: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; every `…/bplus-tree` and `…/skip-list` test in
`api-suite`, every test in `tree-db-suite`, and
`bad-open-arguments-signal` fail (`:type :tree` signals
`NOT-IMPLEMENTED`); every `…/hash` test passes.

- [ ] **Step 4: Write `tree-db.lisp`**

```lisp
;;;; TreeDB: an ordered database on the B+ tree (the default) or the skip
;;;; list (spec: TreeDB).  Per-key work holds the key's stripe under the
;;;; database lock, as in HashDB; the engine keeps the order.

(in-package #:vivace-cabinet)

(defclass tree-db (database)
  ((engine :initform nil :accessor tree-db-engine)))

(defun %engine-kind (code)
  (case code (1 :bplus-tree) (2 :skip-list)))

;;; Storage

(defmethod %type-code ((db tree-db)) 2)

(defmethod %engine-code ((db tree-db))
  (if (typep (tree-db-engine db) 'skip-list-engine) 2 1))

(defmethod %header-address ((db tree-db))
  (engine-address (tree-db-engine db)))

(defmethod %record-count ((db tree-db))
  (engine-count (tree-db-engine db)))

(defun %open-heap (db create)
  "Create or open DB's heap within its address-space reservation."
  (destructuring-bind (&key heap-size heap-reservation &allow-other-keys)
      (%db-tuning db)
    (let ((*mmap-min-reservation* heap-reservation)
          (file (namestring (%heap-file (%db-dir db)))))
      (setf (%db-heap db) (if create
                              (create-memory file heap-size)
                              (open-memory file))))))

(defmethod %create-storage ((db tree-db))
  (destructuring-bind (&key engine page-size comparator &allow-other-keys)
      (%db-tuning db)
    (let ((heap (%open-heap db t)))
      (setf (tree-db-engine db)
            (ecase (or engine :bplus-tree)
              (:bplus-tree (make-bplus-engine heap :less comparator
                                                   :page-size page-size))
              (:skip-list (make-skip-list-engine heap :less comparator)))))))

(defmethod %open-storage ((db tree-db) header)
  (destructuring-bind (&key engine comparator &allow-other-keys)
      (%db-tuning db)
    (let ((dir (%db-dir db))
          (kind (%engine-kind (getf header :engine)))
          (address (getf header :address)))
      (unless kind
        (%signal 'open-error "~a: unknown TreeDB engine ~a" dir
                 (getf header :engine)))
      (when (and engine (not (eq engine kind)))
        (%signal 'open-error "~a: a ~(~a~) TreeDB, not ~(~a~)"
                 dir kind engine))
      (let ((heap (%open-heap db nil)))
        (setf (tree-db-engine db)
              (ecase kind
                (:bplus-tree
                 (open-bplus-engine heap address :less comparator))
                (:skip-list
                 (open-skip-list-engine heap address :less comparator))))))))

(defmethod %close-storage ((db tree-db))
  (when (tree-db-engine db)
    (engine-close (tree-db-engine db))
    (setf (tree-db-engine db) nil))
  (when (%db-heap db)
    (close-memory (%db-heap db))
    (setf (%db-heap db) nil)))

(defmethod %sync-storage ((db tree-db))
  (sync-region (memory-mmap (%db-heap db))))

(defun open-tree-db (dir &key (mode '(:writer :create)) engine
                           (page-size 4096) (comparator 'octets<)
                           (heap-size (* 64 1024 1024))
                           (heap-reservation (* 64 1024 1024 1024)))
  "Open the TreeDB in DIR.  ENGINE is :BPLUS-TREE (the default when
creating) or :SKIP-LIST; PAGE-SIZE (1024 to 32768) applies to a new B+
tree.  COMPARATOR, a strict less-than on octet vectors, is not stored:
pass the same one at every open.  MODE and the heap keywords are as for
OPEN-HASH-DB."
  (%check-mode mode)
  (unless (member engine '(nil :bplus-tree :skip-list))
    (%signal 'invalid-argument "unknown TreeDB engine ~s" engine))
  (unless (and (integerp page-size) (<= 1024 page-size 32768))
    (%signal 'invalid-argument "PAGE-SIZE must be 1024 to 32768: ~s"
             page-size))
  (%open-database
   (make-instance 'tree-db :dir dir
                           :writable (and (member :writer mode) t)
                           :autosync (and (member :autosync mode) t)
                           :tuning (list :engine engine
                                         :page-size page-size
                                         :comparator comparator
                                         :heap-size heap-size
                                         :heap-reservation heap-reservation))
   mode))

;;; Operations

(defmacro %with-tree-key ((db k key mode) &body body)
  "Bind K to KEY as octets and run BODY holding K's stripe for MODE."
  `(let ((,k (to-octets ,key)))
     (with-key-locked (,db (murmur3-128 ,k) ,mode)
       ,@body)))

(defmethod db-set ((db tree-db) key value)
  (%writing (db)
    (let ((v (to-octets value)))
      (%with-tree-key (db k key :write)
        (engine-put (tree-db-engine db) k v)))))

(defmethod db-add ((db tree-db) key value)
  (%writing (db)
    (let ((v (to-octets value)))
      (%with-tree-key (db k key :write)
        (let ((e (tree-db-engine db)))
          (if (engine-get e k)
              (%fail db :duplicate-record)
              (engine-put e k v)))))))

(defmethod db-replace ((db tree-db) key value)
  (%writing (db)
    (let ((v (to-octets value)))
      (%with-tree-key (db k key :write)
        (let ((e (tree-db-engine db)))
          (if (engine-get e k)
              (engine-put e k v)
              (%fail db :no-record)))))))

(defmethod db-append ((db tree-db) key value)
  (%writing (db)
    (let ((v (to-octets value)))
      (%with-tree-key (db k key :write)
        (let* ((e (tree-db-engine db))
               (old (engine-get e k)))
          (engine-put e k (if old (concatenate 'octets old v) v)))))))

(defmethod db-get ((db tree-db) key &key (as :octets))
  (check-as as)
  (%with-tree-key (db k key :read)
    (let ((v (engine-get (tree-db-engine db) k)))
      (if v
          (from-octets v as)
          (%fail db :no-record)))))

(defmethod db-check ((db tree-db) key)
  (%with-tree-key (db k key :read)
    (let ((v (engine-get (tree-db-engine db) k)))
      (if v
          (length v)
          (%fail db :no-record)))))

(defmethod db-seize ((db tree-db) key &key (as :octets))
  (check-as as)
  (%writing (db)
    (%with-tree-key (db k key :write)
      (let* ((e (tree-db-engine db))
             (v (engine-get e k)))
        (if v
            (progn (engine-delete e k)
                   (from-octets v as))
            (%fail db :no-record))))))

(defmethod db-remove ((db tree-db) key)
  (%writing (db)
    (%with-tree-key (db k key :write)
      (or (engine-delete (tree-db-engine db) k)
          (%fail db :no-record)))))

(defmethod db-size ((db tree-db))
  "Bytes the heap has used."
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (read-memory-pointer (%db-heap db))))
```

In `api.lisp`'s `open-db`, replace the `:tree` clause with
`(:tree (apply #'open-tree-db dir args))` and end the docstring with
`Other keywords: OPEN-HASH-DB and OPEN-TREE-DB."`. In
`vivace-cabinet.asd`, add `(:file "tree-db")` after
`(:file "skip-list-engine")`.

- [ ] **Step 5: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures; each converted test runs three times
(`grep -a -c 'Running test .*/SKIP-LIST' <log>` gives 32: the 25 API tests
and the 7 engine tests).

- [ ] **Step 6: Mutation checks**

1. In `%existing-type`, make the `and` form `(and nil dir)`; run
   `VC-TEST tree-db-opens-as-what-it-is`; confirm it fails; restore.
2. In TreeDB's `%open-storage`, make the engine check `(when nil`; run
   `VC-TEST tree-db-opens-as-what-it-is`; confirm it fails; restore.

- [ ] **Step 7: Document TreeDB in `README.md`**

Replace the **Status** paragraph with:

```markdown
**Status:** HashDB and TreeDB work (units 2b and 2c): `open-db`,
`db-set`, `db-get`, `db-add`, `db-replace`, `db-append`, `db-check`,
`db-seize`, `db-remove`, `db-count`, `db-size`, `db-path`, `db-clear`,
`db-synchronize`, `db-error`, `close-db`, `with-db`. Cursors and the rest
of Kyoto's API follow.
```

After the paragraph that ends "…opening an incomplete database otherwise
signals `open-error`.", add:

```markdown
A TreeDB keeps its records in key order:

    (vivace-cabinet:with-db (db "/var/data/words.vct" :type :tree)
      (vivace-cabinet:db-set db "pear" "green")
      (vivace-cabinet:db-set db "apple" "red"))

`:type :tree` chooses TreeDB when creating; an existing database opens as
whatever it is, and a `:type` or `:engine` that does not match it signals
`open-error`. TreeDB takes `:engine` (`:bplus-tree`, the default, or
`:skip-list`), `:page-size` (B+ tree pages of 1024 to 32768 bytes, 4096
by default), `:comparator` (a strict less-than on octet vectors; the
default, `octets<`, is unsigned byte order) and the heap keywords.
```

In **Limits**, before the **Readers need write permission** bullet, add:

```markdown
- **B+ tree keys.** A key longer than a quarter page (1024 bytes at the
  default page size) signals `key-too-long`. A value goes in a heap
  record outside the page when it and its key exceed a quarter page.
- **Comparators are not stored.** Open a TreeDB with the same
  `:comparator` every time; another order misplaces records silently.
- **The skip list frees removed records at close.** On the skip-list
  engine, removing or replacing a record unlinks it at once but frees
  its space only at `close-db`.
```

- [ ] **Step 8: Commit**

```bash
git add tree-db.lisp \
  tests/tree-db-tests.lisp \
  api.lisp \
  tests/support.lisp \
  tests/hash-db-tests.lisp \
  tests/hash-db-modes-tests.lisp \
  vivace-cabinet.asd \
  README.md
git commit -m "TreeDB on the B+ tree and skip-list engines

The API tests now run on HashDB and on TreeDB with each engine. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 6: Cursors, and TreeDB's

**Files:**
- Create: `tree-cursor.lisp`, `tests/cursor-tests.lisp`
- Modify: `api.lisp`, `package.lisp`, `tests/support.lisp`,
  `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: Task 5's TreeDB and engines; `db-replace`, `db-remove`,
  `db-seize`.
- Produces (exported): `db-cursor`, `with-cursor`, `cursor-jump`,
  `cursor-jump-back`, `cursor-step`, `cursor-step-back`, `cursor-get`
  (values key value), `cursor-get-key`, `cursor-get-value`,
  `cursor-set-value`, `cursor-remove`, `cursor-seize`; class
  `tree-cursor`. Tests: `def-tree-test`, `keyed`, `cursor-walk`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/support.lisp`:

```lisp
(defmacro def-tree-test (name &body body)
  "Define NAME/<kind> in API-SUITE for each TreeDB kind in *DB-KINDS*."
  `(progn ,@(db-test-forms name body
                           (remove :hash *db-kinds*
                                   :key (lambda (k) (getf (rest k) :type))))))

(defun keyed (i)
  "The I-th test key, zero-padded so string order is numeric order."
  (format nil "k~5,'0d" i))

(defun cursor-walk (cursor step)
  "The keys, as strings, from CURSOR's record on, moving with STEP."
  (loop while (cursor-get-key cursor)
        collect (cursor-get-key cursor :as :string)
        while (funcall step cursor)))
```

Create `tests/cursor-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-tree-test cursor-walks-in-order-both-ways
  (with-temp-db (db)
    (let* ((*random-state* (sb-ext:seed-random-state 3))
           (keys (loop for i below 500 collect (keyed i))))
      (dolist (k (alexandria:shuffle (copy-list keys)))
        (db-set db k (string-upcase k)))
      (with-cursor (cur db)
        (is-true (cursor-jump cur))
        (is (equal keys (cursor-walk cur #'cursor-step)))
        (is (eq :no-record (db-error db)))
        (is (null (cursor-get cur)))
        (is-true (cursor-jump-back cur))
        (is (equal (reverse keys) (cursor-walk cur #'cursor-step-back)))))))

(def-tree-test cursor-jumps-to-keys
  "A jump lands on the first record at or after the key, a jump back on
the last at or before it."
  (with-temp-db (db)
    (dolist (k '("b" "d" "f"))
      (db-set db k (string-upcase k)))
    (with-cursor (cur db)
      (is-true (cursor-jump cur "d"))
      (is (equal "d" (cursor-get-key cur :as :string)))
      (is-true (cursor-jump cur "c"))
      (is (equal "d" (cursor-get-key cur :as :string)))
      (is (null (cursor-jump cur "g")))
      (is (eq :no-record (db-error db)))
      (is-true (cursor-jump-back cur "e"))
      (is (equal "d" (cursor-get-key cur :as :string)))
      (is (null (cursor-jump-back cur "a")))
      (is-true (cursor-jump-back cur))
      (multiple-value-bind (k v) (cursor-get cur :as :string)
        (is (equal "f" k))
        (is (equal "F" v))))))

(def-tree-test cursor-edits-records
  "SET-VALUE, REMOVE and SEIZE act on the current record; REMOVE and
SEIZE move to the next."
  (with-temp-db (db)
    (dotimes (i 10)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (is-true (cursor-set-value cur "first"))
      (is (equal "first" (db-get db (keyed 0) :as :string)))
      (is-true (cursor-remove cur))
      (is (equal (keyed 1) (cursor-get-key cur :as :string)))
      (multiple-value-bind (k v) (cursor-seize cur :as :string)
        (is (equal (keyed 1) k))
        (is (equal "v" v)))
      (is (equal (keyed 2) (cursor-get-key cur :as :string)))
      (is (= 8 (db-count db)))
      (cursor-jump-back cur)
      (is-true (cursor-remove cur))
      (is (null (cursor-get-key cur)))
      (is (= 7 (db-count db))))))

(def-tree-test cursor-follows-removal-by-others
  "When something else removes the current record, the cursor reads the
next one."
  (with-temp-db (db)
    (dotimes (i 5)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur (keyed 2))
      (db-remove db (keyed 2))
      (is (equal (keyed 3) (cursor-get-key cur :as :string)))
      (is-true (cursor-step-back cur))
      (is (equal (keyed 1) (cursor-get-key cur :as :string))))))

(def-tree-test cursor-on-an-empty-database
  (with-temp-db (db)
    (with-cursor (cur db)
      (is (null (cursor-jump cur)))
      (is (eq :no-record (db-error db)))
      (is (null (cursor-jump-back cur)))
      (is (null (cursor-get cur)))
      (is (null (cursor-step cur)))
      (is (null (cursor-remove cur))))))

(def-tree-test cursor-on-a-reader
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "r.vct/" dir)))
      (with-test-db (db path)
        (db-set db "k" "v"))
      (with-test-db (db path :mode '(:reader))
        (with-cursor (cur db)
          (is-true (cursor-jump cur))
          (is (equal "v" (cursor-get-value cur :as :string)))
          (is (null (cursor-set-value cur "w")))
          (is (eq :no-permission (db-error db)))
          (is (null (cursor-remove cur)))
          (is (equal "v" (db-get db "k" :as :string))))))))

(def-tree-test custom-comparator-orders-records
  (with-temp-db (db :comparator (lambda (a b) (octets< b a)))
    (dolist (k '("a" "b" "c"))
      (db-set db k k))
    (with-cursor (cur db)
      (cursor-jump cur)
      (is (equal '("c" "b" "a") (cursor-walk cur #'cursor-step))))))
```

In `vivace-cabinet.asd`, add `(:file "cursor-tests")` after
`"tree-db-tests"` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 14 cursor tests (7 per tree engine) fail
(`UNDEFINED-FUNCTION` `DB-CURSOR`); everything else passes.

- [ ] **Step 3: The cursor API**

In `api.lisp`, before `(defmacro with-db`, add:

```lisp
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
(defgeneric cursor-get (cursor &key as)
  (:documentation "The current record's key and value, or NIL with
:NO-RECORD."))
(defgeneric cursor-set-value (cursor value))
(defgeneric cursor-remove (cursor)
  (:documentation "Remove the current record and move to the next."))
(defgeneric cursor-seize (cursor &key as)
  (:documentation "Remove the current record, move to the next and return
the removed key and value."))

(defun cursor-get-key (cursor &key (as :octets))
  (values (cursor-get cursor :as as)))

(defun cursor-get-value (cursor &key (as :octets))
  (nth-value 1 (cursor-get cursor :as as)))

(defmacro with-cursor ((var db) &body body)
  "Evaluate BODY with VAR bound to a new cursor on DB."
  `(let ((,var (db-cursor ,db)))
     ,@body))
```

In `package.lisp`, add to the exports:

```lisp
           #:db-cursor #:with-cursor #:cursor-jump #:cursor-jump-back
           #:cursor-step #:cursor-step-back #:cursor-get #:cursor-get-key
           #:cursor-get-value #:cursor-set-value #:cursor-remove
           #:cursor-seize
```

- [ ] **Step 4: Write `tree-cursor.lisp`**

```lisp
;;;; TreeDB's cursor: its position is a key, so changes to the tree leave
;;;; it valid; each move asks the engine for the next or previous key
;;;; (spec: API).  If its record is removed, the cursor reads the next.

(in-package #:vivace-cabinet)

(defclass tree-cursor ()
  ((db :initarg :db :reader %tc-db)
   (key :initform nil :accessor %tc-key)))

(defmethod db-cursor ((db tree-db))
  (make-instance 'tree-cursor :db db))

(defun %tc-find (c fn key strict)
  "The key (FN engine KEY STRICT) finds in C's database, or NIL."
  (let ((db (%tc-db c)))
    (with-read-lock ((%db-lock db))
      (%check-open db)
      (values (funcall fn (tree-db-engine db) key strict)))))

(defun %tc-seek (c fn key strict)
  "Move C to the record (FN engine KEY STRICT) finds; T, or NIL with
:NO-RECORD."
  (setf (%tc-key c) (%tc-find c fn key strict))
  (or (and (%tc-key c) t)
      (%fail (%tc-db c) :no-record)))

(defmethod cursor-jump ((c tree-cursor) &optional key)
  (%tc-seek c #'engine-ceiling (and key (to-octets key)) nil))

(defmethod cursor-jump-back ((c tree-cursor) &optional key)
  (%tc-seek c #'engine-floor (and key (to-octets key)) nil))

(defmethod cursor-step ((c tree-cursor))
  (if (%tc-key c)
      (%tc-seek c #'engine-ceiling (%tc-key c) t)
      (%fail (%tc-db c) :no-record)))

(defmethod cursor-step-back ((c tree-cursor))
  (if (%tc-key c)
      (%tc-seek c #'engine-floor (%tc-key c) t)
      (%fail (%tc-db c) :no-record)))

(defmethod cursor-get ((c tree-cursor) &key (as :octets))
  (check-as as)
  (let ((db (%tc-db c)))
    (if (null (%tc-key c))
        (%fail db :no-record)
        (multiple-value-bind (k v)
            (with-read-lock ((%db-lock db))
              (%check-open db)
              (engine-ceiling (tree-db-engine db) (%tc-key c) nil))
          (setf (%tc-key c) k)
          (if k
              (values (from-octets k as) (from-octets v as))
              (%fail db :no-record))))))

(defmethod cursor-set-value ((c tree-cursor) value)
  (if (%tc-key c)
      (db-replace (%tc-db c) (%tc-key c) value)
      (%fail (%tc-db c) :no-record)))

(defmethod cursor-remove ((c tree-cursor))
  (let ((k (%tc-key c)))
    (cond ((null k) (%fail (%tc-db c) :no-record))
          ((db-remove (%tc-db c) k)
           (setf (%tc-key c) (%tc-find c #'engine-ceiling k t))
           t))))

(defmethod cursor-seize ((c tree-cursor) &key (as :octets))
  (check-as as)
  (let ((k (%tc-key c)))
    (if (null k)
        (%fail (%tc-db c) :no-record)
        (let ((v (db-seize (%tc-db c) k)))
          (when v
            (setf (%tc-key c) (%tc-find c #'engine-ceiling k t))
            (values (from-octets k as) (from-octets v as)))))))
```

In `vivace-cabinet.asd`, add `(:file "tree-cursor")` after
`(:file "tree-db")`.

- [ ] **Step 5: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures.

- [ ] **Step 6: Mutation checks**

1. In `tree-cursor`'s `cursor-get`, replace `(engine-ceiling (tree-db-engine
   db) (%tc-key c) nil)` with `(values (%tc-key c) (engine-get
   (tree-db-engine db) (%tc-key c)))`; run `VC-TEST
   cursor-follows-removal-by-others/bplus-tree`; confirm it fails;
   restore.
2. In `cursor-step-back`, seek with `#'engine-ceiling`; run `VC-TEST
   cursor-walks-in-order-both-ways/skip-list`; confirm it fails; restore.

- [ ] **Step 7: Document cursors in `README.md`**

In the Status paragraph, replace "`with-db`. Cursors and the rest
of Kyoto's API follow." with "`with-db`, and cursors. The rest of
Kyoto's API follows." (reflow to 76 columns). Before `## Limits`, add:

```markdown
## Cursors

    (vivace-cabinet:with-cursor (cur db)
      (when (vivace-cabinet:cursor-jump cur)
        (loop do (print (vivace-cabinet:cursor-get-key cur :as :string))
              while (vivace-cabinet:cursor-step cur))))

`cursor-jump` moves to the first record, or on a TreeDB to the first at
or after a key; `cursor-jump-back` to the last, or the last at or before
a key; `cursor-step` and `cursor-step-back` move one record.
`cursor-get` returns the current key and value (`cursor-get-key` and
`cursor-get-value` one of them), `cursor-set-value` replaces the value,
and `cursor-remove` and `cursor-seize` remove the record and move to the
next. A move past either end returns NIL with `:no-record`. A TreeDB
cursor holds its position as a key, so other threads' changes leave it
valid; if its record is removed, it reads the next one. Give each thread
its own cursor.
```

In **Limits**, after the skip-list bullet, add:

```markdown
- **Skip-list cursors can miss a key being replaced.** The skip-list
  engine replaces a value by removing and re-adding its record, so a
  cursor passing that key at that moment does not see it.
```

- [ ] **Step 8: Commit**

```bash
git add tree-cursor.lisp \
  tests/cursor-tests.lisp \
  api.lisp \
  package.lisp \
  tests/support.lisp \
  vivace-cabinet.asd \
  README.md
git commit -m "Cursors, and TreeDB's

Jump, step and step back in key order on either engine; get, set, remove
and seize the current record. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 7: HashDB's cursor

**Files:**
- Create: `hash-cursor.lisp`, `tests/hash-cursor-tests.lisp`
- Modify: `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: Task 6's cursor generics; HashDB's `%digest`, `%find`,
  `hash-db-index`; the linear hash's `read-bucket`, `bucket-offset`,
  `hash`, `%bucket-count`, `%lhash-split-lock`, `%lhash-level`,
  `%lhash-table`.
- Produces: class `hash-cursor`; `db-cursor` on a HashDB.

- [ ] **Step 1: Write the failing tests**

Create `tests/hash-cursor-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-suite hash-cursor-suite
  :description "HashDB's forward cursor."
  :in vivace-cabinet-suite)

(in-suite hash-cursor-suite)

(test hash-cursor-visits-every-record-once
  "2000 records, so the index splits: a walk sees each exactly once."
  (with-temp-db (db)
    (let ((keys (loop for i below 2000 collect (keyed i))))
      (dolist (k keys)
        (db-set db k k))
      (with-cursor (cur db)
        (is-true (cursor-jump cur))
        (let ((seen (cursor-walk cur #'cursor-step)))
          (is (= 2000 (length seen)))
          (is (equal keys (sort seen #'string<))))))))

(test hash-cursor-walks-collision-chains
  (let ((*key-digest* (constant-digest 9)))
    (with-temp-db (db)
      (dolist (k '("a" "b" "c" "d"))
        (db-set db k k))
      (with-cursor (cur db)
        (cursor-jump cur)
        (is (equal '("a" "b" "c" "d")
                   (sort (cursor-walk cur #'cursor-step) #'string<)))))))

(test hash-cursor-jumps-to-a-key
  "A jump to a key lands on it and walks on as a full walk would."
  (with-temp-db (db)
    (dotimes (i 300)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (let* ((all (cursor-walk cur #'cursor-step))
             (from (nth 100 all)))
        (is-true (cursor-jump cur from))
        (is (equal (nthcdr 100 all) (cursor-walk cur #'cursor-step)))
        (is (null (cursor-jump cur "absent")))
        (is (eq :no-record (db-error db)))))))

(test hash-cursor-edits-records
  "SET-VALUE changes the current record; REMOVE and SEIZE take it and
move on, until the database is empty."
  (with-temp-db (db)
    (dotimes (i 500)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (let ((first (cursor-get-key cur :as :string)))
        (is-true (cursor-set-value cur "w"))
        (is (equal "w" (db-get db first :as :string)))
        (multiple-value-bind (k v) (cursor-seize cur :as :string)
          (is (equal first k))
          (is (equal "w" v)))
        (is (null (db-get db first))))
      (loop while (cursor-remove cur))
      (is (= 0 (db-count db))))))

(test hash-cursor-reads-past-removed-records
  (with-temp-db (db)
    (dotimes (i 5)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (let ((first (cursor-get-key cur :as :string)))
        (db-remove db first)
        (is (not (equal first (cursor-get-key cur :as :string))))
        (is (= 4 (length (cursor-walk cur #'cursor-step))))))))

(test hash-cursor-moves-forward-only
  (with-temp-db (db)
    (db-set db "k" "v")
    (with-cursor (cur db)
      (cursor-jump cur)
      (signals not-implemented (cursor-jump-back cur))
      (signals not-implemented (cursor-step-back cur)))))

(test hash-cursor-on-an-empty-database
  (with-temp-db (db)
    (with-cursor (cur db)
      (is (null (cursor-jump cur)))
      (is (eq :no-record (db-error db)))
      (is (null (cursor-get cur)))
      (is (null (cursor-step cur))))))
```

In `vivace-cabinet.asd`, add `(:file "hash-cursor-tests")` after
`"cursor-tests"` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 7 `hash-cursor-suite` tests fail (no
`DB-CURSOR` method for a `HASH-DB`); everything else passes.

- [ ] **Step 3: Write `hash-cursor.lisp`**

```lisp
;;;; HashDB's cursor: forward through the index a bucket at a time, in no
;;;; useful order (spec: API).  It reads a bucket's keys when it reaches
;;;; the bucket, so a record a concurrent split moves to a later bucket
;;;; can be seen twice, and one moved to an earlier bucket missed.

(in-package #:vivace-cabinet)

(defclass hash-cursor ()
  ((db :initarg :db :reader %hc-db)
   (bucket :initform -1 :accessor %hc-bucket)
   (pending :initform nil :accessor %hc-pending)
   (key :initform nil :accessor %hc-key)))

(defmethod db-cursor ((db hash-db))
  (make-instance 'hash-cursor :db db))

(defun %hc-bucket-keys (db bucket)
  "The keys in BUCKET of DB's index, chain by chain, and whether BUCKET
is past the last one.  Each chain is read under its stripe."
  (let* ((index (hash-db-index db))
         (heap (%db-heap db))
         (past nil)
         (digests (with-read-lock ((%lhash-split-lock index))
                    (if (< bucket (%bucket-count index))
                        (mapcar #'car
                                (read-bucket index (%lhash-table index)
                                             (bucket-offset index bucket)))
                        (setf past t)))))
    (values (unless past
              (loop for d in digests
                    nconc (with-read-lock ((%stripe db d))
                            (loop for addr = (lhash-get index d)
                                    then (record-next heap addr)
                                  until (or (null addr) (zerop addr))
                                  collect (record-key heap addr)))))
            past)))

(defun %hc-advance (c)
  "Move C to the next key and return it, or NIL at the end.  The caller
holds the database lock."
  (loop
    (when (%hc-pending c)
      (return (setf (%hc-key c) (pop (%hc-pending c)))))
    (multiple-value-bind (keys past)
        (%hc-bucket-keys (%hc-db c) (incf (%hc-bucket c)))
      (when past
        (return (setf (%hc-key c) nil)))
      (setf (%hc-pending c) keys))))

(defmacro %with-hash-cursor ((db c) &body body)
  "Run BODY with DB bound to C's database, holding its lock shared."
  `(let ((,db (%hc-db ,c)))
     (with-read-lock ((%db-lock ,db))
       (%check-open ,db)
       ,@body)))

(defmethod cursor-jump ((c hash-cursor) &optional key)
  (%with-hash-cursor (db c)
    (if (null key)
        (progn (setf (%hc-bucket c) -1
                     (%hc-pending c) nil)
               (or (and (%hc-advance c) t)
                   (%fail db :no-record)))
        (let* ((k (to-octets key))
               (d (%digest k))
               (index (hash-db-index db)))
          (if (with-read-lock ((%stripe db d))
                (%find db d k))
              (let ((b (with-read-lock ((%lhash-split-lock index))
                         (hash index (%lhash-level index) d))))
                (setf (%hc-bucket c) b
                      (%hc-pending c) (rest (member k (%hc-bucket-keys db b)
                                                    :test #'equalp))
                      (%hc-key c) k)
                t)
              (%fail db :no-record))))))

(defmethod cursor-step ((c hash-cursor))
  (%with-hash-cursor (db c)
    (if (and (%hc-key c) (%hc-advance c))
        t
        (%fail db :no-record))))

(defmethod cursor-get ((c hash-cursor) &key (as :octets))
  (check-as as)
  (%with-hash-cursor (db c)
    (loop
      (let ((k (%hc-key c)))
        (unless k
          (return (%fail db :no-record)))
        (let* ((d (%digest k))
               (v (with-read-lock ((%stripe db d))
                    (let ((addr (%find db d k)))
                      (and addr (record-value (%db-heap db) addr))))))
          (when v
            (return (values (from-octets k as) (from-octets v as))))
          (%hc-advance c))))))

(defmethod cursor-set-value ((c hash-cursor) value)
  (if (%hc-key c)
      (db-replace (%hc-db c) (%hc-key c) value)
      (%fail (%hc-db c) :no-record)))

(defun %hc-next (c)
  (%with-hash-cursor (db c)
    (%hc-advance c)))

(defmethod cursor-remove ((c hash-cursor))
  (let ((k (%hc-key c)))
    (cond ((null k) (%fail (%hc-db c) :no-record))
          ((db-remove (%hc-db c) k)
           (%hc-next c)
           t))))

(defmethod cursor-seize ((c hash-cursor) &key (as :octets))
  (check-as as)
  (let ((k (%hc-key c)))
    (if (null k)
        (%fail (%hc-db c) :no-record)
        (let ((v (db-seize (%hc-db c) k)))
          (when v
            (%hc-next c)
            (values (from-octets k as) (from-octets v as)))))))

(defmethod cursor-jump-back ((c hash-cursor) &optional key)
  (declare (ignore key))
  (%signal 'not-implemented "a HashDB cursor moves forward only"))

(defmethod cursor-step-back ((c hash-cursor))
  (%signal 'not-implemented "a HashDB cursor moves forward only"))
```

In `vivace-cabinet.asd`, add `(:file "hash-cursor")` after
`(:file "tree-cursor")`.

- [ ] **Step 4: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures, no undefined names.

- [ ] **Step 5: Mutation checks**

1. In `%hc-bucket-keys`, replace the inner chain `loop` with `(list
   (record-key heap (lhash-get index d)))`; run `VC-TEST
   hash-cursor-walks-collision-chains`; confirm it fails; restore.
2. In `cursor-jump`, set `(%hc-pending c)` to `(%hc-bucket-keys db b)`
   instead of the keys after K; run `VC-TEST hash-cursor-jumps-to-a-key`;
   confirm it fails; restore.

- [ ] **Step 6: Document it in `README.md`**

At the end of the Cursors section, add:

```markdown
A HashDB cursor moves forward only, in no useful order, as in Kyoto
Cabinet: `cursor-jump-back` and `cursor-step-back` signal
`not-implemented`, and `cursor-jump` with a key lands on that key's
record. It reads the index a bucket at a time, so a record that a
concurrent writer's bucket split moves can be seen twice or missed.
```

- [ ] **Step 7: Commit**

```bash
git add hash-cursor.lisp \
  tests/hash-cursor-tests.lisp \
  vivace-cabinet.asd \
  README.md
git commit -m "HashDB's cursor, forward only

Walks the index a bucket at a time; backward moves signal NOT-IMPLEMENTED,
as in Kyoto Cabinet. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

---

## Finish

- [ ] `VC-SUITE` once more: exit 0.
- [ ] On kraison/vivace-cabinet#2, comment `Ready for review:` with the
  branch and `git -C ~/work/vivace-cabinet diff main...unit-2c-treedb`.
- [ ] Stop: merge and push wait for Kevin's word. The push to main closes
  #4 (Task 1's commit says "Fixes #4"); kraison/vivace-graph#404 stays
  open, since vivace-graph is not changed here.
