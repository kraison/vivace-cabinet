# Unit 2d: the rest of the API — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** The rest of Kyoto Cabinet's database API on HashDB and TreeDB:
visitors (`db-accept`, `db-accept-bulk`, `db-iterate`, `db-scan-parallel`,
`cursor-accept`), `db-cas`, `db-increment`, `db-increment-double`, bulk
set, get and remove, `db-match-prefix`, `db-match-regex`,
`db-match-similar`, `db-status`, `db-occupy`, `db-copy`, `db-merge`,
snapshots, and transaction calls that signal
`transactions-not-implemented`.

**Architecture:** Everything rests on one primitive, a *visit*: call a
function with a key and its value while holding that key's stripe lock,
and apply its answer. Each database type supplies `%visit` and
`%key-digest`; `db-accept` and `db-accept-bulk` take the stripes (in index
order, so bulk calls cannot deadlock) and visit. Compare-and-swap,
increments and the atomic bulk operations are visits. `db-iterate` and
`db-scan-parallel` hold the whole database and walk its keys in batches
each type supplies (`%key-batches`). Matching walks a cursor; copying,
merging and snapshots use files, cursors and `db-iterate`.

**Tech Stack:** SBCL, FiveAM, CL-PPCRE (new), babel; units 2b and 2c's
HashDB, TreeDB and cursors.

**Spec:** `docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`,
section "API" (the table and the bullets under it) and "Testing"; phase
split and decisions on kraison/vivace-cabinet#2. Kyoto's semantics, where
the spec defers to them, are from Kyoto Cabinet 1.2.80's `kcdb.h` and
`kcpolydb.h`.

**Dry run:** every block below was applied, task by task, to a copy of
`main` (3c97bd8) before the plan was written. Each task's failing-test
step failed exactly as its Expected line says, the final suite passed
(12,741 checks, no undefined names), and every mutation check below
failed as a test failure. The executor still works test-first from the
plan.

## Global Constraints

- SBCL only. New Lisp: spaces only, 80 columns, terse comments.
- vivace-graph is never modified.
- No transactions in version 1: the transaction calls signal
  `transactions-not-implemented`.
- Keys and values are `(simple-array (unsigned-byte 8) (*))`; strings are
  accepted and stored as UTF-8.
- Logical failures return NIL and set the reason `db-error` reports; real
  errors signal `vivace-cabinet-error` subclasses.
- A database object may be shared between threads.
- Branch `unit-2d-rest-of-api` in `~/work/vivace-cabinet`; one commit per
  task; explicit `git add` paths; nothing pushed without Kevin's word.
- Public repo: generic commit messages and issue text.
- Every commit message ends with:

  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ
  ```

## Commands

`VC-SUITE` (forced recompile; temp files on disk, since one copied test
needs about 2 GB and `/tmp` here is a small tmpfs; about a minute):

```bash
mkdir -p /var/tmp/vc-tests && cd ~/work/vivace-cabinet && \
TMPDIR=/var/tmp/vc-tests sbcl --noinform --non-interactive \
  --load ~/quicklisp/setup.lisp \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval '(ql:quickload (list :alexandria :bordeaux-threads :cffi :cl-ppcre :cl-store :log4cl :fiveam :babel) :silent t)' \
  --eval '(asdf:load-system :vivace-cabinet/test :force (list :vivace-cabinet :vivace-cabinet/test))' \
  --eval '(asdf:test-system :vivace-cabinet)'
```

(`:cl-ppcre` is quickloaded from Task 1 on; the system depends on it from
Task 5.)

`VC-TEST <name>`: the same with the last `--eval` replaced by
`--eval '(unless (fiveam:run! (quote vivace-cabinet-test::<name>)) (uiop:quit 1))'`.
`<name>` may be a test or a suite. Tests made by `def-db-test` and
`def-tree-test` are named `<name>/<kind>`, e.g. `bulk-operations/hash`;
the kinds are `hash`, `bplus-tree` and `skip-list`.

Mutation checks: change the code in place as stated (never append a second
definition: that is a full compiler WARNING and the build stops), run the
named test, confirm it fails *as a test failure, not a compile error*, and
restore the file byte for byte. Run them under `timeout 400`: a mutation
that deadlocks must not hang the session. Logs can contain NUL bytes:
`grep -a`.

Test-writing traps the dry run hit:

- A test that starts threads catches errors inside them: an unhandled
  error in a thread ends the whole `--non-interactive` run.
- A test file with plain `test` forms needs its own `def-suite` and
  `in-suite`; otherwise its tests join whichever suite the file loaded
  before it named, or none.
- `with-db` takes its keywords literally; to open with a list of
  arguments in a variable, `(apply #'open-db path args)`.

## Review Focus

1. **A visitor that signals**: the error reaches the caller, the record is
   unchanged and every lock is released, so the next call works (Task 1
   `visitor-errors-leave-the-database-usable`; Task 4
   `iterate-errors-leave-the-database-usable`,
   `scan-parallel-passes-on-visitor-errors`).
2. **Bulk calls from several threads over the same keys in opposite
   orders** finish (Task 1 `bulk-visits-do-not-deadlock`), and a write
   from another thread during `db-iterate` waits for it to end (Task 4
   `iterate-holds-the-database`).
3. **Keys that are not UTF-8** under `db-match-regex` and
   `db-match-similar :utf t`: they read as U+FFFD, and nothing is skipped
   or signals (Task 5 `matching-skips-nothing-on-bytes-that-are-not-utf-8`).
4. **Snapshot files that are not whole snapshots**: another file's bytes,
   or a snapshot cut short, signal `invalid-argument` instead of loading
   garbage (Task 7 `bad-snapshots-signal`).
5. **Copies of sparse files**: the index's 1000 MiB files stay sparse, a
   file that ends in a hole keeps its length, and the copy opens as a
   database of its own, without the writes made to the original after it
   (Task 6 `copy-keeps-holes`, `copy-makes-a-database-of-its-own`).

## Proposals in this plan for Kevin to approve

- **Visitors' answers.** The spec's `:nop`, `:remove` or a new value; NIL
  also keeps the record. Visitors get octets, or strings with
  `:as :string`.
- **Visitors run under locks and must not use the database**, as in
  Kyoto: `db-accept` holds its key's stripe, `db-accept-bulk` the stripes
  of all its keys, `db-iterate` the whole database.
- **`db-scan-parallel` holds the database exclusively**, so its threads
  read without locks; Kyoto's lets readers continue during a scan.
  `:threads` defaults to 4 (Kyoto has no default). Answers are ignored,
  and a visitor's error is signalled again in the caller.
- **Increments use Kyoto's encodings byte for byte**, so the conformance
  check can compare values: an 8-byte big-endian integer, and a double as
  16 bytes (the integral part, then the fraction in units of 10^-15). The
  64-bit extremes and the infinities as `:orig` mean what they mean in
  Kyoto.
- **A new `db-error` code, `:logic`**: a compare-and-swap that finds
  another value, an increment of a value of another size, a `db-occupy`
  function that returns NIL.
- **Bulk operations take lists.** `db-set-bulk` takes an alist (a key
  given twice takes its last value; the count is of distinct keys);
  `db-get-bulk` returns an alist of the keys found, in the order asked
  (Kyoto: a map).
- **Regular expressions** use CL-PPCRE, a new dependency, on keys decoded
  as UTF-8 (bytes that are not UTF-8 read as U+FFFD); Kyoto matches bytes
  with its own engine. A bad expression signals `invalid-argument`, as
  the spec says of invalid arguments; Kyoto returns -1 with its LOGIC
  error.
- **`db-match-similar`** returns the nearest keys first, then in byte
  order, as Kyoto's PolyDB does; `:max` keeps the nearest.
- **`db-copy`** copies the database's files, keeping the index's sparse
  files sparse, into a directory that must not exist yet.
- **`db-merge`** takes the sources one after another, so under `:set` a
  key in several sources takes the last source's value; Kyoto merges all
  sources together in key order.
- **`db-status`** returns a plist (Kyoto: a map of strings).
- **Snapshots** are in vivace-cabinet's own format, as the spec says,
  described in the README.
- **Transactions**: `transactions-not-implemented` is a subclass of
  `not-implemented`; `with-transaction` signals before its body runs.
- **`cursor-accept`** arrives here, as unit 2c's plan deferred it.

---

### Task 1: Visitors: `db-accept` and `db-accept-bulk`

**Files:**
- Create: `visitors.lisp`, `tests/visitor-tests.lisp`
- Modify: `database.lisp` (`%stripe`; append the visiting helpers),
  `hash-db.lisp`, `tree-db.lisp`, `api.lisp`, `package.lisp`,
  `vivace-cabinet.asd`, `tests/support.lisp`, `README.md`

**Interfaces:**
- Consumes: `database`'s `%db-lock`, `%db-stripes`, `%check-open`,
  `%fail`, `%db-writable-p`, `%db-autosync-p`, `db-synchronize`;
  `to-octets`, `from-octets`, `check-as`; HashDB's `%digest`,
  `(%find db digest key)` → `(values addr prev)`, `%insert-record`,
  `%replace-record`, `%unlink-record`, `record-value`; TreeDB's
  `tree-db-engine`, `engine-get`, `engine-put`, `engine-delete`;
  `murmur3-128`.
- Produces: exported `(db-accept db key visitor &key (writable t)
  (as :octets))` and `(db-accept-bulk db keys visitor &key (writable t)
  (as :octets))`, each → T, or NIL with `:no-permission`;
  `(%stripe-index digest)` → index; `(%call-with-stripes db digests mode
  fn)` (MODE `:read` or `:write`); generics `(%key-digest db key)` →
  16-byte digest and `(%visit db key digest visitor as writable)` → the
  answer, called holding KEY's stripe or the whole database; macro
  `(%accepting (db writable) &body body)`. Tests: `answer`,
  `finish-within`.

- [ ] **Step 1: Branch**

```bash
cd ~/work/vivace-cabinet && git switch -c unit-2d-rest-of-api
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/support.lisp`:

```lisp
(defun finish-within (threads seconds)
  "Wait up to SECONDS for THREADS to end; destroy any still running.
True when all ended in time."
  (loop repeat (* 2 seconds)
        while (some #'bt:thread-alive-p threads)
        do (sleep 0.5))
  (let ((stuck (remove-if-not #'bt:thread-alive-p threads)))
    (mapc #'bt:destroy-thread stuck)
    (null stuck)))
```

Create `tests/visitor-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(defun answer (value)
  "A visitor that ignores its arguments and answers VALUE."
  (lambda (k v)
    (declare (ignore k v))
    value))

(def-db-test accept-applies-the-visitors-answer
  "NIL and :NOP keep a record, :REMOVE removes it, anything else is the
new value; an absent key's value is NIL."
  (with-temp-db (db)
    (db-set db "a" "1")
    (db-set db "b" "2")
    (let ((seen '()))
      (is-true (db-accept db "a" (lambda (k v) (push (list k v) seen) :nop)
                          :as :string))
      (is (equal '(("a" "1")) seen)))
    (is-true (db-accept db "a" (lambda (k v)
                                 (declare (ignore k))
                                 (concatenate 'string v "!"))
                        :as :string))
    (is (equal "1!" (db-get db "a" :as :string)))
    (is-true (db-accept db "b" (answer :remove)))
    (is (null (db-get db "b")))
    (is-true (db-accept db "c" (lambda (k v)
                                 (declare (ignore k))
                                 (if v :nop "new"))))
    (is (equal "new" (db-get db "c" :as :string)))
    (is-true (db-accept db "absent" (answer :remove)))
    (is-true (db-accept db "d" (answer nil)))
    (is (null (db-get db "d")))
    (is (= 2 (db-count db)))))

(def-db-test read-only-visits-change-nothing
  (with-temp-db (db)
    (db-set db "a" "1")
    (is-true (db-accept db "a" (answer :remove) :writable nil))
    (is-true (db-accept db "z" (answer "new") :writable nil))
    (is (equal "1" (db-get db "a" :as :string)))
    (is (null (db-get db "z")))))

(def-db-test visitors-on-a-reader
  "A reader refuses writable visits and allows read-only ones."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "v.vc/" dir)))
      (with-test-db (db path)
        (db-set db "k" "v"))
      (with-test-db (db path :mode '(:reader))
        (is (null (db-accept db "k" (answer :remove))))
        (is (eq :no-permission (db-error db)))
        (is (null (db-accept-bulk db '("k") (answer :remove))))
        (let ((got nil))
          (is-true (db-accept db "k" (lambda (k v)
                                       (declare (ignore k))
                                       (setf got v)
                                       :nop)
                              :writable nil :as :string))
          (is (equal "v" got)))))))

(def-db-test accept-bulk-visits-every-key-in-order
  (with-temp-db (db)
    (dolist (k '("a" "b" "c"))
      (db-set db k k))
    (let ((seen '()))
      (is-true (db-accept-bulk db '("c" "a" "zz" "b")
                               (lambda (k v)
                                 (push (cons k v) seen)
                                 (cond ((equal k "a") :remove)
                                       (v :nop)
                                       (t "new")))
                               :as :string))
      (is (equal '(("c" . "c") ("a" . "a") ("zz") ("b" . "b"))
                 (reverse seen)))
      (is (null (db-get db "a")))
      (is (equal "new" (db-get db "zz" :as :string))))))

(def-db-test bulk-visits-do-not-deadlock
  "Four threads visit 200 keys each, two in each order, 50 times over:
all finish, none signals, and every visit landed."
  (with-temp-db (db)
    (let ((keys (loop for i below 200 collect (keyed i)))
          (lock (bt:make-lock))
          (errors '()))
      (flet ((visit-all (ks)
               (handler-case
                   (dotimes (j 50)
                     (db-accept-bulk db ks
                                     (lambda (k v)
                                       (declare (ignore k))
                                       (concatenate 'string v "x"))
                                     :as :string))
                 (error (c)
                   (bt:with-lock-held (lock)
                     (push (princ-to-string c) errors))))))
        (let ((threads
                (loop for n below 4
                      collect (let ((ks (if (evenp n) keys (reverse keys))))
                                (bt:make-thread
                                 (lambda () (visit-all ks)))))))
          (is-true (finish-within threads 120))
          (is (null errors) "~s" errors)
          (is (every (lambda (k)
                       (= 200 (length (db-get db k :as :string))))
                     keys)))))))

(def-db-test visitor-errors-leave-the-database-usable
  "An error in a visitor reaches the caller, changes nothing, and leaves
every lock released."
  (with-temp-db (db)
    (db-set db "a" "1")
    (flet ((boom (k v)
             (declare (ignore k v))
             (error "boom")))
      (signals simple-error (db-accept db "a" #'boom))
      (signals simple-error (db-accept-bulk db '("a" "b") #'boom)))
    (is (equal "1" (db-get db "a" :as :string)))
    (is-true (db-set db "a" "2"))
    (is (equal "2" (db-get db "a" :as :string)))))
```

In `vivace-cabinet.asd`, add `(:file "visitor-tests")` after
`(:file "concurrency-tests")` in the test system.

- [ ] **Step 3: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 18 visitor tests fail (6 per kind:
`accept-applies-the-visitors-answer`, `read-only-visits-change-nothing`,
`visitors-on-a-reader`, `accept-bulk-visits-every-key-in-order`,
`bulk-visits-do-not-deadlock`, `visitor-errors-leave-the-database-usable`)
with `UNDEFINED-FUNCTION` `DB-ACCEPT` or `DB-ACCEPT-BULK`; everything else
passes.

- [ ] **Step 4: Stripes and the visit protocol**

In `database.lisp`, replace the whole `%stripe` defun:

```lisp
(defun %stripe (db digest)
  "The stripe lock for a 16-byte DIGEST."
  (aref (%db-stripes db)
        (logand (logior (aref digest 0) (ash (aref digest 1) 8))
                (1- +stripes+))))
```

with

```lisp
(defun %stripe (db digest)
  "The stripe lock for a 16-byte DIGEST."
  (aref (%db-stripes db) (%stripe-index digest)))
```

and append to `database.lisp`:

```lisp
;;; Visiting records (visitors.lisp builds on these)

(defun %stripe-index (digest)
  (logand (logior (aref digest 0) (ash (aref digest 1) 8))
          (1- +stripes+)))

(defun %call-with-stripes (db digests mode fn)
  "Call FN holding DB's lock shared and the stripes of DIGESTS for MODE
(:READ or :WRITE), each taken once and in index order, so that calls
over overlapping keys cannot deadlock."
  (let ((indexes (sort (remove-duplicates (mapcar #'%stripe-index digests))
                       #'<)))
    (with-read-lock ((%db-lock db))
      (%check-open db)
      (labels ((take (rest)
                 (if (null rest)
                     (funcall fn)
                     (let ((s (aref (%db-stripes db) (first rest))))
                       (ecase mode
                         (:read (with-read-lock (s) (take (rest rest))))
                         (:write (with-write-lock (s)
                                   (take (rest rest)))))))))
        (take indexes)))))

(defgeneric %key-digest (db key)
  (:documentation "KEY's 16-byte digest, which picks its stripe."))

(defgeneric %visit (db key digest visitor as writable)
  (:documentation "Call VISITOR with KEY and its value (NIL when absent),
both decoded AS, and when WRITABLE apply its answer: NIL or :NOP keeps
the record, :REMOVE removes it, anything else is stored.  The caller
holds KEY's stripe, or the whole database.  Returns the answer."))
```

Append to `hash-db.lisp`:

```lisp
;;; Visiting

(defmethod %key-digest ((db hash-db) key)
  (%digest key))

(defmethod %visit ((db hash-db) k d visitor as writable)
  (multiple-value-bind (addr prev) (%find db d k)
    (let ((answer (funcall visitor (from-octets k as)
                           (and addr (from-octets (record-value (%db-heap db)
                                                                addr)
                                                  as)))))
      (when writable
        (case answer
          ((nil :nop))
          (:remove (when addr
                     (%unlink-record db d addr prev)))
          (t (let ((v (to-octets answer)))
               (if addr
                   (%replace-record db d addr prev k v)
                   (%insert-record db d k v))))))
      answer)))
```

Append to `tree-db.lisp`:

```lisp
;;; Visiting

(defmethod %key-digest ((db tree-db) key)
  (murmur3-128 key))

(defmethod %visit ((db tree-db) k d visitor as writable)
  (declare (ignore d))
  (let* ((e (tree-db-engine db))
         (old (engine-get e k))
         (answer (funcall visitor (from-octets k as)
                          (and old (from-octets old as)))))
    (when writable
      (case answer
        ((nil :nop))
        (:remove (when old
                   (engine-delete e k)))
        (t (engine-put e k (to-octets answer)))))
    answer))
```

- [ ] **Step 5: `db-accept` and `db-accept-bulk`**

Append to `api.lisp`:

```lisp
(defgeneric db-accept (db key visitor &key writable as)
  (:documentation "Call VISITOR with KEY and its value (NIL if absent)
and, when WRITABLE (the default), apply its answer: NIL or :NOP keeps
the record, :REMOVE removes it, anything else is the new value.  The
visit is atomic for KEY; VISITOR must not use the database.  T, or NIL
with :NO-PERMISSION for a writable visit on a reader."))

(defgeneric db-accept-bulk (db keys visitor &key writable as)
  (:documentation "DB-ACCEPT for each of KEYS in order, atomically for
all of them."))
```

Create `visitors.lisp`:

```lisp
;;;; Visitors (spec: API): a function of a key and its value (NIL when
;;;; absent) that answers :NOP, :REMOVE or a new value.  It runs while
;;;; the key's stripe, or the whole database, is held, so it must not
;;;; call the database.

(in-package #:vivace-cabinet)

(defmacro %accepting ((db writable) &body body)
  "Run BODY, which visits for WRITABLE.  A writable visit on a reader
fails with :NO-PERMISSION, and one under :AUTOSYNC synchronizes after."
  `(cond ((not ,writable) ,@body)
         ((not (%db-writable-p ,db)) (%fail ,db :no-permission))
         (t (multiple-value-prog1 (progn ,@body)
              (when (%db-autosync-p ,db)
                (db-synchronize ,db))))))

(defmethod db-accept ((db database) key visitor &key (writable t)
                                                     (as :octets))
  (check-as as)
  (%accepting (db writable)
    (let* ((k (to-octets key))
           (d (%key-digest db k)))
      (%call-with-stripes db (list d) (if writable :write :read)
                          (lambda ()
                            (%visit db k d visitor as writable)))
      t)))

(defmethod db-accept-bulk ((db database) keys visitor &key (writable t)
                                                          (as :octets))
  (check-as as)
  (%accepting (db writable)
    (let* ((ks (mapcar #'to-octets keys))
           (ds (mapcar (lambda (k) (%key-digest db k)) ks)))
      (%call-with-stripes db ds (if writable :write :read)
                          (lambda ()
                            (mapc (lambda (k d)
                                    (%visit db k d visitor as writable))
                                  ks ds)))
      t)))
```

In `package.lisp`, add to the end of the export list (inside its closing
parentheses), on a new line:

```lisp
           #:db-accept #:db-accept-bulk
```

In `vivace-cabinet.asd`, add `(:file "visitors")` after
`(:file "hash-cursor")` in the library.

- [ ] **Step 6: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures; `grep -a -i undefined` on the log finds
nothing.

- [ ] **Step 7: Mutation checks**

1. In `hash-db.lisp`, replace

   ```lisp
             (:remove (when addr
                        (%unlink-record db d addr prev)))
   ```

   with

   ```lisp
             (:remove nil)
   ```

   run `VC-TEST accept-applies-the-visitors-answer/hash`; confirm it fails
   as a test failure; restore the file.
2. In `tree-db.lisp`, replace

   ```lisp
       (when writable
         (case answer
           ((nil :nop))
           (:remove (when old
   ```

   with

   ```lisp
       (when t
         (case answer
           ((nil :nop))
           (:remove (when old
   ```

   run `VC-TEST read-only-visits-change-nothing/bplus-tree`; confirm it
   fails as a test failure; restore the file.
3. In `visitors.lisp`, replace

   ```lisp
                             (lambda ()
                               (%visit db k d visitor as writable)))
   ```

   with

   ```lisp
                             (lambda ()
                               (ignore-errors (%visit db k d visitor as writable))))
   ```

   run `VC-TEST visitor-errors-leave-the-database-usable/hash`; confirm it
   fails as a test failure; restore the file.
4. In `database.lisp`, replace

   ```lisp
     (let ((indexes (sort (remove-duplicates (mapcar #'%stripe-index digests))
                          #'<)))
   ```

   with

   ```lisp
     (let ((indexes (remove-duplicates (mapcar #'%stripe-index digests))))
   ```

   run `VC-TEST bulk-visits-do-not-deadlock/hash`; confirm it fails as a
   test failure; restore the file.

- [ ] **Step 8: Document visitors in `README.md`**

Before `## Limits`, add:

```markdown
## Visitors and the rest of the API

    (vivace-cabinet:db-accept
     db "apple"
     (lambda (key value)
       (declare (ignore key))
       (if value (concatenate 'string value "!") :nop))
     :as :string)

A visitor is a function of a key and its value (NIL when the key is
absent) whose answer says what becomes of the record: NIL or `:nop`
keeps it, `:remove` removes it, and anything else is the new value.
`db-accept` visits one key, and `db-accept-bulk` a list of keys in order,
atomically for all of them. `:writable nil` visits without changing
anything, the only kind of visit a reader allows. A visitor runs while
the database holds its key's lock, so it must not use the database.
```

- [ ] **Step 9: Commit**

```bash
git add database.lisp \
  hash-db.lisp \
  tree-db.lisp \
  api.lisp \
  visitors.lisp \
  package.lisp \
  vivace-cabinet.asd \
  tests/support.lisp \
  tests/visitor-tests.lisp \
  README.md
git commit -m "Visitors: DB-ACCEPT and DB-ACCEPT-BULK

A visitor sees a key and its value and answers :NOP, :REMOVE or a new
value, applied while the key's stripe is held. Bulk visits take their
stripes in index order. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 2: Compare-and-swap and increments

**Files:**
- Create: `atomic-ops.lisp`, `tests/atomic-ops-tests.lisp`
- Modify: `api.lisp`, `package.lisp`, `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: Task 1's `db-accept`; `%fail`, `%signal`, `to-octets`,
  `invalid-argument`, the `octets` type.
- Produces: exported `(db-cas db key old new)` → T, or NIL with `:logic`;
  `(db-increment db key num &key (orig 0))` → the new integer, or NIL;
  `(db-increment-double db key num &key (orig 0d0))` → the new double, or
  NIL. The `db-error` code `:logic`. Constants `+int64-min+`,
  `+int64-max+`, `+decunit+`; `(%int64 n)`, `(%int64-octets n)`,
  `(%octets-int64 v start)`.

Kyoto's rules, which the tests pin (`kcdb.h`, `increment` and
`increment_double`): NUM 0 only reads; ORIG the most negative 64-bit
integer (or negative infinity) makes an absent key fail; ORIG the most
positive (or positive infinity) sets the value to NUM whatever it was; a
value of another size fails with `:logic`.

- [ ] **Step 1: Write the failing tests**

Create `tests/atomic-ops-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-db-test cas-swaps-only-the-expected-value
  (with-temp-db (db)
    (is-true (db-cas db "k" nil "1"))
    (is (null (db-cas db "k" nil "2")))
    (is (eq :logic (db-error db)))
    (is (null (db-cas db "k" "x" "2")))
    (is (equal "1" (db-get db "k" :as :string)))
    (is-true (db-cas db "k" "1" "2"))
    (is (equal "2" (db-get db "k" :as :string)))
    (is-true (db-cas db "k" "2" nil))
    (is (null (db-get db "k")))
    (is-true (db-cas db "k" nil nil))
    (is (null (db-get db "k")))))

(def-db-test increments-follow-kyoto
  "8-byte big-endian integers; ORIG for an absent key, the 64-bit
extremes as Kyoto Cabinet reads them, wrap-around, and NIL with :LOGIC
for a value of another size."
  (with-temp-db (db)
    (let ((min (- (expt 2 63)))
          (max (1- (expt 2 63))))
      (is (= 5 (db-increment db "n" 5)))
      (is (= 12 (db-increment db "n" 7)))
      (is (equalp (octets-of 0 0 0 0 0 0 0 12) (db-get db "n")))
      (is (= 12 (db-increment db "n" 0)))
      (is (= -3 (db-increment db "n" -15)))
      (is (= 110 (db-increment db "m" 10 :orig 100)))
      (is (null (db-increment db "absent" 1 :orig min)))
      (is (eq :logic (db-error db)))
      (is (null (db-get db "absent")))
      (is (= 4 (db-increment db "n" 4 :orig max)))
      (is (= max (db-increment db "big" max)))
      (is (= min (db-increment db "big" 1)))
      (db-set db "text" "hello")
      (is (null (db-increment db "text" 1)))
      (is (eq :logic (db-error db)))
      (signals invalid-argument (db-increment db "n" (expt 2 64))))))

(def-db-test double-increments-follow-kyoto
  "16 bytes: the integral part, then the fraction in 10^-15 units."
  (with-temp-db (db)
    (is (= 1.5d0 (db-increment-double db "d" 1.5d0)))
    (is (= 3.75d0 (db-increment-double db "d" 2.25d0)))
    (is (equalp (concatenate '(vector (unsigned-byte 8))
                             (octets-of 0 0 0 0 0 0 0 3)
                             (octets-of 0 2 #xaa #x1e #xfb #x94 #xe0 0))
                (db-get db "d")))
    (is (= 3.75d0 (db-increment-double db "d" 0)))
    (is (= 1.25d0 (db-increment-double db "d" -2.5d0)))
    (is (= 2d0 (db-increment-double db "d" 0.75d0)))
    (is (equalp (octets-of 0 0 0 0 0 0 0 2 0 0 0 0 0 0 0 0)
                (db-get db "d")))
    (is (= 10.5d0 (db-increment-double db "e" 0.5d0 :orig 10)))
    (is (= 2d0 (db-increment-double
                db "d" 2 :orig sb-ext:double-float-positive-infinity)))
    (is (null (db-increment-double
               db "absent" 1 :orig sb-ext:double-float-negative-infinity)))
    (is (eq :logic (db-error db)))
    (db-set db "text" "hello")
    (is (null (db-increment-double db "text" 1)))
    (is (eq :logic (db-error db)))))

(def-db-test increments-on-a-reader
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "i.vc/" dir)))
      (with-test-db (db path)
        (db-increment db "n" 3))
      (with-test-db (db path :mode '(:reader))
        (is (null (db-increment db "n" 1)))
        (is (eq :no-permission (db-error db)))
        (is (= 3 (db-increment db "n" 0 :orig (- (expt 2 63)))))
        (is (null (db-cas db "n" nil "x")))))))
```

In `vivace-cabinet.asd`, add `(:file "atomic-ops-tests")` after
`(:file "visitor-tests")` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 12 tests fail (4 per kind:
`cas-swaps-only-the-expected-value`, `increments-follow-kyoto`,
`double-increments-follow-kyoto`, `increments-on-a-reader`) with
`UNDEFINED-FUNCTION` `DB-CAS`, `DB-INCREMENT` or `DB-INCREMENT-DOUBLE`;
everything else passes.

- [ ] **Step 3: Write the operations**

Append to `api.lisp`:

```lisp
(defgeneric db-cas (db key old new)
  (:documentation "Store NEW under KEY if its value is OLD; OLD NIL means
KEY must be absent, NEW NIL removes the record.  T, or NIL with :LOGIC
when the value is not OLD."))

(defgeneric db-increment (db key num &key orig)
  (:documentation "Add NUM to KEY's value, an 8-byte big-endian signed
integer, and return the result.  An absent key starts at ORIG (0); ORIG
the most negative 64-bit integer makes an absent key fail, the most
positive sets the value to NUM.  NIL with :LOGIC when the value is not 8
bytes, as in Kyoto Cabinet."))

(defgeneric db-increment-double (db key num &key orig)
  (:documentation "DB-INCREMENT on a double float kept as Kyoto Cabinet
keeps it: 16 bytes, the integral part and the fraction in units of
10^-15, each big-endian.  ORIG negative infinity makes an absent key
fail, positive infinity sets the value to NUM."))
```

In `api.lisp`, in `db-error`'s docstring, replace

```lisp
returned NIL: :DUPLICATE-RECORD, :NO-RECORD or :NO-PERMISSION, or
:SUCCESS if none has failed."))
```

with

```lisp
returned NIL: :DUPLICATE-RECORD, :NO-RECORD, :NO-PERMISSION or :LOGIC,
or :SUCCESS if none has failed."))
```

Create `atomic-ops.lisp`:

```lisp
;;;; Compare-and-swap and increments, each one visit (spec: API).  The
;;;; numbers are stored as Kyoto Cabinet stores them, so a conformance
;;;; check reads the same bytes (kcdb.h: increment, increment_double).

(in-package #:vivace-cabinet)

(alexandria:define-constant +int64-min+ (- (expt 2 63)))
(alexandria:define-constant +int64-max+ (1- (expt 2 63)))
(alexandria:define-constant +decunit+ 1000000000000000)

(defun %int64 (n)
  "N wrapped to a signed 64-bit integer, as C arithmetic wraps."
  (let ((u (ldb (byte 64 0) n)))
    (if (logbitp 63 u) (- u (expt 2 64)) u)))

(defun %int64-octets (n)
  "N as 8 big-endian bytes, two's complement."
  (let ((v (make-array 8 :element-type '(unsigned-byte 8)))
        (u (ldb (byte 64 0) n)))
    (dotimes (i 8 v)
      (setf (aref v i) (ldb (byte 8 (* 8 (- 7 i))) u)))))

(defun %octets-int64 (v start)
  (let ((u 0))
    (dotimes (i 8)
      (setf u (logior (ash u 8) (aref v (+ start i)))))
    (%int64 u)))

(defmethod db-cas ((db database) key old new)
  (let ((ov (and old (to-octets old)))
        (nv (and new (to-octets new)))
        (ok nil))
    (and (db-accept db key
                    (lambda (k v)
                      (declare (ignore k))
                      (cond (v (if (and ov (equalp v ov))
                                   (progn (setf ok t)
                                          (or nv :remove))
                                   :nop))
                            (ov :nop)
                            (t (setf ok t)
                               (or nv :nop)))))
         (or ok (%fail db :logic)))))

(defun %check-int64 (&rest numbers)
  (dolist (n numbers)
    (unless (typep n '(signed-byte 64))
      (%signal 'invalid-argument "not a 64-bit integer: ~s" n))))

(defmethod db-increment ((db database) key num &key (orig 0))
  (%check-int64 num orig)
  (let ((result nil))
    (and (db-accept
          db key
          (lambda (k v)
            (declare (ignore k))
            (cond ((and v (/= (length v) 8)) :nop)
                  (v (let ((onum (if (= orig +int64-max+)
                                     0
                                     (%octets-int64 v 0))))
                       (if (and (zerop num) (/= orig +int64-max+))
                           (progn (setf result onum) :nop)
                           (%int64-octets
                            (setf result (%int64 (+ num onum)))))))
                  ((= orig +int64-min+) :nop)
                  (t (%int64-octets
                      (setf result (if (= orig +int64-max+)
                                       num
                                       (%int64 (+ num orig))))))))
          :writable (or (/= num 0) (/= orig +int64-min+)))
         (or result (%fail db :logic)))))

;;; Doubles: computed with float traps masked, since infinities and NaN
;;; are values here, as in C.

(defun %nan-p (x) (sb-ext:float-nan-p x))
(defun %inf-p (x) (sb-ext:float-infinity-p x))

(defun %split-double (x)
  "X's integral part and its fraction in units of 10^-15, truncated
toward zero as C's modf does; NaN gives both the most negative 64-bit
integer, an infinity the most positive or negative and 0."
  (cond ((%nan-p x) (values +int64-min+ +int64-min+))
        ((%inf-p x) (values (if (plusp x) +int64-max+ +int64-min+) 0))
        (t (multiple-value-bind (integ frac) (truncate x)
             (values (%int64 integ) (truncate (* frac +decunit+)))))))

(defun %fixed-octets (integ fract)
  (concatenate 'octets (%int64-octets integ) (%int64-octets fract)))

(defun %fixed-value (integ fract)
  (+ (float integ 1d0) (/ (float fract 1d0) +decunit+)))

(defun %increment-full (v num orig)
  "Kyoto's visit_full: (values answer result) for the stored value V."
  (let ((set-p (and (%inf-p orig) (plusp orig))))
    (if (/= (length v) 16)
        (values :nop nil)
        (multiple-value-bind (linteg lfract)
            (if set-p
                (values 0 0)
                (values (%octets-int64 v 0) (%octets-int64 v 8)))
          (cond ((and (= linteg +int64-min+) (= lfract +int64-min+))
                 (values :nop nil))
                ((= linteg +int64-max+)
                 (values :nop sb-ext:double-float-positive-infinity))
                ((= linteg +int64-min+)
                 (values :nop sb-ext:double-float-negative-infinity))
                ((and (zerop num) (not set-p))
                 (values :nop (%fixed-value linteg lfract)))
                ((or (%nan-p num) (%inf-p num))
                 (multiple-value-bind (i f) (%split-double num)
                   (values (%fixed-octets i f) num)))
                (t
                 (multiple-value-bind (di df) (%split-double num)
                   (let ((i (%int64 (+ linteg di)))
                         (f (+ lfract df)))
                     (when (>= f +decunit+)
                       (setf i (%int64 (1+ i))
                             f (- f +decunit+)))
                     (values (%fixed-octets i f) (%fixed-value i f))))))))))

(defun %increment-empty (num orig)
  "Kyoto's visit_empty: (values answer result) for an absent key."
  (if (or (%nan-p orig) (and (%inf-p orig) (minusp orig)))
      (values :nop nil)
      (let ((n (if (%inf-p orig) num (+ num orig))))
        (multiple-value-bind (i f) (%split-double n)
          (values (%fixed-octets i f) n)))))

(defmethod db-increment-double ((db database) key num &key (orig 0d0))
  (let ((num (float num 1d0))
        (orig (float orig 1d0))
        (result nil))
    (sb-int:with-float-traps-masked (:overflow :invalid :inexact
                                     :divide-by-zero)
      (and (db-accept db key
                      (lambda (k v)
                        (declare (ignore k))
                        (multiple-value-bind (answer r)
                            (if v
                                (%increment-full v num orig)
                                (%increment-empty num orig))
                          (setf result r)
                          answer)))
           (if (or (null result) (%nan-p result))
               (%fail db :logic)
               result)))))
```

In `package.lisp`, add to the end of the export list (inside its closing
parentheses), on a new line:

```lisp
           #:db-cas #:db-increment #:db-increment-double
```

In `vivace-cabinet.asd`, add `(:file "atomic-ops")` after
`(:file "visitors")` in the library.

- [ ] **Step 4: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures; `grep -a -i undefined` on the log finds
nothing.

- [ ] **Step 5: Mutation checks**

1. In `atomic-ops.lisp`, replace

   ```lisp
         (setf (aref v i) (ldb (byte 8 (* 8 (- 7 i))) u)))))
   ```

   with

   ```lisp
         (setf (aref v i) (ldb (byte 8 (* 8 i)) u)))))
   ```

   run `VC-TEST increments-follow-kyoto/hash`; confirm it fails as a test
   failure; restore the file.
2. In `atomic-ops.lisp`, replace

   ```lisp
                        (when (>= f +decunit+)
   ```

   with

   ```lisp
                        (when nil
   ```

   run `VC-TEST double-increments-follow-kyoto/skip-list`; confirm it fails
   as a test failure; restore the file.

- [ ] **Step 6: Document them in `README.md`**

Replace the paragraph that begins "As in Kyoto Cabinet, an operation that
fails" with (this also lists `key-too-long`, which the README omitted;
#7):

```markdown
As in Kyoto Cabinet, an operation that fails for an ordinary reason (adding
a key that exists, removing one that doesn't, writing to a reader, a
compare-and-swap that finds another value) returns NIL, and
`(db-error db)` says why: `:duplicate-record`, `:no-record`,
`:no-permission` or `:logic`. Real problems signal `vivace-cabinet-error`
subclasses: `open-error`, `invalid-argument`, `key-too-long`,
`not-implemented`. `db-check` returns the value's size; `db-size` returns
the bytes in use, not file sizes (the index files are sparse).
```

In `README.md`, add this paragraph before `## Limits`, after the paragraph
the last task added:

```markdown
`db-cas` stores a new value only when the old one is as given (NIL: the
key must be absent; a new value of NIL removes the record).
`db-increment` adds to an 8-byte big-endian integer, and
`db-increment-double` to a double stored as Kyoto Cabinet stores one
(the integral part, then the fraction in units of 10^-15, 8 bytes each),
so the bytes are Kyoto's; `:orig` is an absent key's starting value.
```

- [ ] **Step 7: Commit**

```bash
git add atomic-ops.lisp \
  tests/atomic-ops-tests.lisp \
  api.lisp \
  package.lisp \
  vivace-cabinet.asd \
  README.md
git commit -m "Compare-and-swap and increments, in Kyoto's encodings

DB-CAS, DB-INCREMENT and DB-INCREMENT-DOUBLE, each one visit. A new
DB-ERROR code, :LOGIC, for a swap or increment that cannot apply.
Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 3: Bulk set, get and remove

**Files:**
- Create: `bulk.lisp`, `tests/bulk-tests.lisp`
- Modify: `api.lisp`, `package.lisp`, `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: Task 1's `db-accept-bulk`; `db-set`, `db-get`, `db-remove`,
  `%db-writable-p`, `%fail`, `check-as`, `to-octets`, `from-octets`.
- Produces: exported `(db-set-bulk db records &key (atomic t))` → the
  number of distinct keys stored, or NIL; `(db-get-bulk db keys &key
  (atomic t) (as :octets))` → alist of the keys found, in the order
  asked; `(db-remove-bulk db keys &key (atomic t))` → the number removed,
  or NIL. `(%last-values records)`, `(%unique-octets keys)`.

- [ ] **Step 1: Write the failing tests**

Create `tests/bulk-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-db-test bulk-operations
  "Set, get and remove many records at once, atomically or not; a key
given twice takes its last value."
  (with-temp-db (db)
    (dolist (atomic '(t nil))
      (db-clear db)
      (is (= 3 (db-set-bulk db '(("a" . "1") ("b" . "2") ("c" . "3")
                                  ("a" . "4"))
                            :atomic atomic)))
      (is (equal "4" (db-get db "a" :as :string)))
      (is (= 3 (db-count db)))
      (is (equal '(("c" . "3") ("a" . "4"))
                 (db-get-bulk db '("c" "zz" "a" "c") :atomic atomic
                                                     :as :string)))
      (is (= 2 (db-remove-bulk db '("a" "zz" "b" "a") :atomic atomic)))
      (is (equal '("c") (mapcar #'car (db-get-bulk db '("a" "b" "c")
                                                   :as :string))))
      (is (= 1 (db-count db))))))

(def-db-test bulk-operations-on-a-reader
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "b.vc/" dir)))
      (with-test-db (db path)
        (db-set db "k" "v"))
      (with-test-db (db path :mode '(:reader))
        (dolist (atomic '(t nil))
          (is (null (db-set-bulk db '(("k" . "w")) :atomic atomic)))
          (is (null (db-remove-bulk db '("k") :atomic atomic)))
          (is (eq :no-permission (db-error db)))
          (is (equal '(("k" . "v"))
                     (db-get-bulk db '("k") :atomic atomic :as :string))))))))
```

In `vivace-cabinet.asd`, add `(:file "bulk-tests")` after
`(:file "atomic-ops-tests")` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 6 tests fail (2 per kind: `bulk-operations`,
`bulk-operations-on-a-reader`) with `UNDEFINED-FUNCTION` `DB-SET-BULK`;
everything else passes.

- [ ] **Step 3: Write the operations**

Append to `api.lisp`:

```lisp
(defgeneric db-set-bulk (db records &key atomic)
  (:documentation "Store RECORDS, an alist of (key . value); a key given
twice takes its last value.  The number of keys stored, or NIL.  ATOMIC
(the default) stores them all at once."))

(defgeneric db-get-bulk (db keys &key atomic as)
  (:documentation "An alist of (key . value) for those of KEYS that are
present, in the order asked."))

(defgeneric db-remove-bulk (db keys &key atomic)
  (:documentation "Remove KEYS; the number removed, or NIL."))
```

Create `bulk.lisp`:

```lisp
;;;; Bulk operations (spec: API).  Atomic ones are one DB-ACCEPT-BULK;
;;;; the rest loop over the single-record operations, as Kyoto's do.

(in-package #:vivace-cabinet)

(defun %last-values (records)
  "RECORDS' keys as octets, each once in the order first given, and a
table of each key's last value."
  (let ((table (make-hash-table :test 'equalp))
        (keys '()))
    (loop for (key . value) in records
          do (let ((k (to-octets key)))
               (unless (nth-value 1 (gethash k table))
                 (push k keys))
               (setf (gethash k table) (to-octets value))))
    (values (nreverse keys) table)))

(defmethod db-set-bulk ((db database) records &key (atomic t))
  (multiple-value-bind (keys table) (%last-values records)
    (if atomic
        (and (db-accept-bulk db keys
                             (lambda (k v)
                               (declare (ignore v))
                               (gethash k table)))
             (length keys))
        (loop for k in keys
              unless (db-set db k (gethash k table))
                return nil
              count t))))

(defun %unique-octets (keys)
  "KEYS as octets, each once, in the order first given."
  (let ((seen (make-hash-table :test 'equalp)))
    (loop for key in keys
          for k = (to-octets key)
          unless (gethash k seen)
            collect (setf (gethash k seen) k))))

(defmethod db-get-bulk ((db database) keys &key (atomic t) (as :octets))
  (check-as as)
  (let ((found '()))
    (if atomic
        (db-accept-bulk db (%unique-octets keys)
                        (lambda (k v)
                          (when v
                            (push (cons (from-octets k as) (from-octets v as))
                                  found))
                          :nop)
                        :writable nil)
        (dolist (k (%unique-octets keys))
          (let ((v (db-get db k)))
            (when v
              (push (cons (from-octets k as) (from-octets v as)) found)))))
    (nreverse found)))

(defmethod db-remove-bulk ((db database) keys &key (atomic t))
  (if atomic
      (let ((n 0))
        (and (db-accept-bulk db (%unique-octets keys)
                             (lambda (k v)
                               (declare (ignore k))
                               (if v
                                   (progn (incf n) :remove)
                                   :nop)))
             n))
      (if (%db-writable-p db)
          (count-if (lambda (k) (db-remove db k)) (%unique-octets keys))
          (%fail db :no-permission))))
```

In `package.lisp`, add to the end of the export list (inside its closing
parentheses), on a new line:

```lisp
           #:db-set-bulk #:db-get-bulk #:db-remove-bulk
```

In `vivace-cabinet.asd`, add `(:file "bulk")` after `(:file "atomic-ops")`
in the library.

- [ ] **Step 4: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures; `grep -a -i undefined` on the log finds
nothing.

- [ ] **Step 5: Mutation checks**

1. In `bulk.lisp`, replace

   ```lisp
                             (when v
                               (push (cons (from-octets k as) (from-octets v as))
                                     found))
   ```

   with

   ```lisp
                             (push (cons (from-octets k as) (and v (from-octets v as)))
                                   found)
   ```

   run `VC-TEST bulk-operations/bplus-tree`; confirm it fails as a test
   failure; restore the file.
2. In `bulk.lisp`, replace

   ```lisp
                                  (if v
                                      (progn (incf n) :remove)
                                      :nop)))
   ```

   with

   ```lisp
                                  (incf n)
                                  (if v :remove :nop)))
   ```

   run `VC-TEST bulk-operations/hash`; confirm it fails as a test failure;
   restore the file.
3. In `bulk.lisp`, replace

   ```lisp
                  (unless (nth-value 1 (gethash k table))
                    (push k keys))
   ```

   with

   ```lisp
                  (push k keys)
   ```

   run `VC-TEST bulk-operations/hash`; confirm it fails as a test failure;
   restore the file.

- [ ] **Step 6: Document them in `README.md`**

In `README.md`, add this paragraph before `## Limits`, after the paragraph
the last task added:

```markdown
`db-set-bulk` stores an alist of keys and values (a key given twice
takes its last value) and returns how many it stored; `db-get-bulk`
returns an alist of the keys it finds; `db-remove-bulk` returns how many
it removed. Each is atomic unless given `:atomic nil`.
```

- [ ] **Step 7: Commit**

```bash
git add bulk.lisp \
  tests/bulk-tests.lisp \
  api.lisp \
  package.lisp \
  vivace-cabinet.asd \
  README.md
git commit -m "Bulk set, get and remove

Atomic by default, as one DB-ACCEPT-BULK; a key given twice takes its
last value. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 4: Iterating, scanning in parallel, and `cursor-accept`

**Files:**
- Modify: `database.lisp`, `hash-cursor.lisp`, `tree-cursor.lisp`,
  `api.lisp`, `visitors.lisp`, `package.lisp`,
  `tests/visitor-tests.lisp`, `README.md`

**Interfaces:**
- Consumes: Task 1's `%visit`, `%key-digest`, `%accepting`, `db-accept`;
  the HashDB cursor's `%hc-db` and `(%hc-bucket-keys db bucket)` →
  `(values keys past-the-end-p)`; the TreeDB cursor's `%tc-db`;
  `(engine-ceiling engine key strict)`; `cursor-get-key`, `cursor-step`.
- Produces: exported `(db-iterate db visitor &key (writable t)
  (as :octets))` → T, or NIL with `:no-permission`;
  `(db-scan-parallel db visitor &key (threads 4) (as :octets))` → T;
  `(cursor-accept cursor visitor &key (writable t) step (as :octets))` →
  T, or NIL with `:no-record`. Generics `(%key-batches db)` → a
  thread-safe function returning the next list of keys or NIL, and
  `(%cursor-db cursor)`; `(%walk-keys db fn)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/visitor-tests.lisp`:

```lisp
(def-db-test iterate-visits-every-record-once
  (with-temp-db (db)
    (dotimes (i 300)
      (db-set db (keyed i) "v"))
    (let ((seen '()))
      (is-true (db-iterate db (lambda (k v)
                                (declare (ignore v))
                                (push k seen)
                                :nop)
                           :writable nil :as :string))
      (is (equal (loop for i below 300 collect (keyed i))
                 (sort seen #'string<))))
    (is-true (db-iterate db (lambda (k v)
                              (if (char= #\0 (char k 5))
                                  :remove
                                  (string-upcase v)))
                         :as :string))
    (is (= 270 (db-count db)))
    (is (equal "V" (db-get db (keyed 1) :as :string)))
    (is (null (db-get db (keyed 10))))))

(def-db-test iterate-holds-the-database
  "A write started during an iteration lands only after it."
  (with-temp-db (db)
    (dotimes (i 50)
      (db-set db (keyed i) "v"))
    (let ((writer nil)
          (last-visit 0)
          (written 0))
      (db-iterate db (lambda (k v)
                       (declare (ignore k v))
                       (unless writer
                         (setf writer
                               (bt:make-thread
                                (lambda ()
                                  (db-set db "late" "x")
                                  (setf written
                                        (get-internal-real-time)))))
                         (sleep 0.3))
                       (setf last-visit (get-internal-real-time))
                       :nop)
                  :writable nil)
      (bt:join-thread writer)
      (is (>= written last-visit))
      (is (equal "x" (db-get db "late" :as :string))))))

(def-db-test scan-parallel-visits-every-record-once
  "Four threads visit 2000 records; answers are ignored."
  (with-temp-db (db)
    (dotimes (i 2000)
      (db-set db (keyed i) (keyed i)))
    (let ((seen '())
          (lock (bt:make-lock)))
      (is-true (db-scan-parallel db (lambda (k v)
                                      (bt:with-lock-held (lock)
                                        (push (cons k v) seen))
                                      :remove)
                                 :threads 4 :as :string))
      (is (every (lambda (r) (equal (car r) (cdr r))) seen))
      (is (equal (loop for i below 2000 collect (keyed i))
                 (sort (mapcar #'car seen) #'string<)))
      (is (= 2000 (db-count db))))))

(def-db-test scan-parallel-passes-on-visitor-errors
  (with-temp-db (db)
    (dotimes (i 100)
      (db-set db (keyed i) "v"))
    (signals simple-error
      (db-scan-parallel db (lambda (k v)
                             (declare (ignore k v))
                             (error "boom"))))
    (signals invalid-argument (db-scan-parallel db (answer :nop) :threads 0))
    (is (= 100 (db-count db)))))

(def-db-test cursor-accept-visits-the-current-record
  (with-temp-db (db)
    (dotimes (i 10)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur)
      (let ((n 0))
        (loop while (cursor-accept cur (lambda (k v)
                                         (declare (ignore k))
                                         (incf n)
                                         (concatenate 'string v "!"))
                                   :step t :as :string))
        (is (= 10 n)))
      (is (every (lambda (i) (equal "v!" (db-get db (keyed i) :as :string)))
                 (loop for i below 10 collect i)))
      (cursor-jump cur)
      (loop while (cursor-accept cur (answer :remove)))
      (is (= 0 (db-count db)))
      (is (null (cursor-accept cur (answer :nop))))
      (is (eq :no-record (db-error db))))))

(def-db-test iterate-errors-leave-the-database-usable
  (with-temp-db (db)
    (dotimes (i 10)
      (db-set db (keyed i) "v"))
    (signals simple-error
      (db-iterate db (lambda (k v)
                       (declare (ignore k v))
                       (error "boom"))))
    (is-true (db-set db "after" "x"))
    (is (= 11 (db-count db)))))
```

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 18 new tests fail (6 per kind:
`iterate-visits-every-record-once`, `iterate-holds-the-database`,
`scan-parallel-visits-every-record-once`,
`scan-parallel-passes-on-visitor-errors`,
`cursor-accept-visits-the-current-record`,
`iterate-errors-leave-the-database-usable`) with `UNDEFINED-FUNCTION`
`DB-ITERATE`, `DB-SCAN-PARALLEL` or `CURSOR-ACCEPT`; everything else passes.

- [ ] **Step 3: Key batches**

Append to `database.lisp`:

```lisp
(defgeneric %key-batches (db)
  (:documentation "A function that returns the next batch of DB's keys
on each call and NIL when there are no more; safe to call from several
threads.  Each key comes in one batch when nothing writes meanwhile."))

(defun %walk-keys (db fn)
  "Call FN with each of DB's keys; FN may change or remove that key's
record.  The caller holds DB exclusively."
  (loop with next = (%key-batches db)
        for batch = (funcall next)
        while batch
        do (mapc fn batch)))
```

Append to `hash-cursor.lisp` (a batch is one bucket's keys):

```lisp
(defmethod %cursor-db ((c hash-cursor))
  (%hc-db c))

(defmethod %key-batches ((db hash-db))
  (let ((bucket -1)
        (lock (make-lock "hash key batches")))
    (lambda ()
      (loop
        (multiple-value-bind (keys past)
            (%hc-bucket-keys db (with-lock-held (lock) (incf bucket)))
          (cond (past (return nil))
                (keys (return keys))))))))
```

Append to `tree-cursor.lisp` (a batch is up to 256 keys in order):

```lisp
(defmethod %cursor-db ((c tree-cursor))
  (%tc-db c))

(defmethod %key-batches ((db tree-db))
  (let ((e (tree-db-engine db))
        (lock (make-lock "tree key batches"))
        (last nil)
        (done nil))
    (lambda ()
      (with-lock-held (lock)
        (unless done
          (let ((batch (loop repeat 256
                             for k = (engine-ceiling e last (and last t))
                             while k
                             collect (setf last k))))
            (unless batch
              (setf done t))
            batch))))))
```

- [ ] **Step 4: The whole-database visitors**

Append to `api.lisp`:

```lisp
(defgeneric db-iterate (db visitor &key writable as)
  (:documentation "Visit every record, holding the whole database: other
threads wait until it ends, as in Kyoto Cabinet.  T, or NIL with
:NO-PERMISSION for a writable iteration on a reader."))

(defgeneric db-scan-parallel (db visitor &key threads as)
  (:documentation "Visit every record from THREADS threads (4) at once,
read-only: VISITOR's answers are ignored.  An error in VISITOR is
signalled again here."))

(defgeneric cursor-accept (cursor visitor &key writable step as)
  (:documentation "DB-ACCEPT on the cursor's record, then CURSOR-STEP
when STEP.  T, or NIL with :NO-RECORD when the cursor is on none."))

(defgeneric %cursor-db (cursor))
```

Append to `visitors.lisp`:

```lisp
(defmethod db-iterate ((db database) visitor &key (writable t)
                                                  (as :octets))
  (check-as as)
  (%accepting (db writable)
    (with-write-lock ((%db-lock db))
      (%check-open db)
      (%walk-keys db (lambda (k)
                       (%visit db k (%key-digest db k) visitor as writable)))
      t)))

(defmethod db-scan-parallel ((db database) visitor &key (threads 4)
                                                        (as :octets))
  (check-as as)
  (unless (typep threads '(integer 1))
    (%signal 'invalid-argument "THREADS must be a positive integer: ~s"
             threads))
  ;; The database is held throughout, so the workers read unlocked.
  (with-write-lock ((%db-lock db))
    (%check-open db)
    (let* ((next (%key-batches db))
           (lock (make-lock "scan failure"))
           (failure nil)
           (workers
             (loop repeat threads
                   collect (make-thread
                            (lambda ()
                              (handler-case
                                  (loop for batch = (funcall next)
                                        while (and batch (not failure))
                                        do (dolist (k batch)
                                             (%visit db k (%key-digest db k)
                                                     visitor as nil)))
                                (error (c)
                                  (with-lock-held (lock)
                                    (unless failure
                                      (setf failure c))))))
                            :name "vivace-cabinet scan"))))
      (mapc #'join-thread workers)
      (when failure
        (error failure))
      t)))

(defmethod cursor-accept (cursor visitor &key (writable t) step
                                              (as :octets))
  (let ((k (cursor-get-key cursor)))
    (and k
         (db-accept (%cursor-db cursor) k visitor :writable writable :as as)
         (progn (when step
                  (cursor-step cursor))
                t))))
```

In `package.lisp`, add to the end of the export list (inside its closing
parentheses), on a new line:

```lisp
           #:db-iterate #:db-scan-parallel #:cursor-accept
```

- [ ] **Step 5: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures; `grep -a -i undefined` on the log finds
nothing.

- [ ] **Step 6: Mutation checks**

1. In `visitors.lisp`, replace

   ```lisp
     (%accepting (db writable)
       (with-write-lock ((%db-lock db))
         (%check-open db)
         (%walk-keys
   ```

   with

   ```lisp
     (%accepting (db writable)
       (with-read-lock ((%db-lock db))
         (%check-open db)
         (%walk-keys
   ```

   run `VC-TEST iterate-holds-the-database/hash`; confirm it fails as a test
   failure; restore the file.
2. In `visitors.lisp`, replace

   ```lisp
         (when failure
           (error failure))
   ```

   with

   ```lisp
         (when nil
           (error failure))
   ```

   run `VC-TEST scan-parallel-passes-on-visitor-errors/skip-list`; confirm
   it fails as a test failure; restore the file.

- [ ] **Step 7: Document them in `README.md`**

In `README.md`, add this paragraph before `## Limits`, after the paragraph
the last task added:

```markdown
`db-iterate` visits every record while holding the whole database:
other threads wait until it ends, as in Kyoto Cabinet.
`db-scan-parallel` visits every record from `:threads` threads (4) at
once, read-only, also holding the database. `cursor-accept` visits a
cursor's record, and with `:step t` moves on.
```

- [ ] **Step 8: Commit**

```bash
git add database.lisp \
  hash-cursor.lisp \
  tree-cursor.lisp \
  api.lisp \
  visitors.lisp \
  package.lisp \
  tests/visitor-tests.lisp \
  README.md
git commit -m "DB-ITERATE, DB-SCAN-PARALLEL and CURSOR-ACCEPT

Iterating and scanning hold the whole database and walk its keys in
batches each database type supplies. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 5: Matching keys

**Files:**
- Create: `match.lisp`, `tests/match-tests.lisp`
- Modify: `vivace-cabinet.asd` (the CL-PPCRE dependency), `api.lisp`,
  `package.lisp`, `README.md`

**Interfaces:**
- Consumes: `with-cursor`, `cursor-jump`, `cursor-get-key`, `cursor-step`;
  `octets<`, `%db-tuning`, `tree-db`; `invalid-argument`, `%signal`,
  `check-as`.
- Produces: exported `(db-match-prefix db prefix &key max (as :octets))`,
  `(db-match-regex db regex &key max (as :octets))` and
  `(db-match-similar db origin range &key utf max (as :octets))`, each → a
  list of keys. `(%edit-distance a b)`, `(%walk-cursor db fn &optional
  from)`, `(%key-text octets)`.

- [ ] **Step 1: Write the failing tests**

Create `tests/match-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(defun sorted (strings)
  (sort (copy-list strings) #'string<))

(def-db-test match-prefix-finds-keys
  (with-temp-db (db)
    (dolist (k '("apple" "apricot" "banana" "app" "ap" "b"))
      (db-set db k "v"))
    (is (equal '("app" "apple") (sorted (db-match-prefix db "app"
                                                         :as :string))))
    (is (equal '("ap" "app" "apple" "apricot")
               (sorted (db-match-prefix db "ap" :as :string))))
    (is (= 6 (length (db-match-prefix db ""))))
    (is (null (db-match-prefix db "zz")))
    (is (= 2 (length (db-match-prefix db "ap" :max 2))))
    (is (null (db-match-prefix db "ap" :max 0)))))

(def-tree-test match-prefix-keeps-key-order
  "In byte order the matches come in key order; under another order
every key is still checked."
  (with-temp-db (db)
    (dolist (k '("apple" "apricot" "banana" "app" "ap" "b"))
      (db-set db k "v"))
    (is (equal '("ap" "app" "apple" "apricot")
               (db-match-prefix db "ap" :as :string))))
  (with-temp-db (db :comparator (lambda (a b) (octets< b a)))
    (dolist (k '("apple" "apricot" "banana" "app" "ap" "b"))
      (db-set db k "v"))
    (is (equal '("apricot" "apple" "app" "ap")
               (db-match-prefix db "ap" :as :string)))))

(def-db-test match-regex-finds-keys
  (with-temp-db (db)
    (dolist (k '("cat" "category" "dog" "concat" "café"))
      (db-set db k "v"))
    (is (equal '("cat" "category")
               (sorted (db-match-regex db "^cat" :as :string))))
    (is (equal '("cat" "category" "concat")
               (sorted (db-match-regex db "cat" :as :string))))
    (is (equal '("café") (db-match-regex db "é$" :as :string)))
    (is (= 2 (length (db-match-regex db "cat" :max 2))))
    (signals invalid-argument (db-match-regex db "("))))

(def-db-test match-similar-orders-by-distance
  "Nearest first, then byte order; UTF compares characters, not bytes."
  (with-temp-db (db)
    (dolist (k '("kitten" "sitten" "sitting" "mitten" "kit" "café" "cafe"))
      (db-set db k "v"))
    (is (equal '("kitten" "mitten" "sitten")
               (db-match-similar db "kitten" 1 :as :string)))
    (is (equal '("kitten" "mitten")
               (db-match-similar db "kitten" 1 :max 2 :as :string)))
    (is (equal '("cafe" "café")
               (db-match-similar db "cafe" 1 :utf t :as :string)))
    (is (equal '("cafe") (db-match-similar db "cafe" 1 :as :string)))
    (signals invalid-argument (db-match-similar db "x" -1))))

(def-db-test matching-skips-nothing-on-bytes-that-are-not-utf-8
  "A key that is not UTF-8 reads as U+FFFD for a regex and for UTF
distances; byte distances use its bytes."
  (with-temp-db (db)
    (db-set db (octets-of 255 254 97) "v")
    (db-set db "a" "v")
    (is (= 2 (length (db-match-regex db "a$"))))
    (is (= 2 (length (db-match-similar db "a" 2 :utf t))))
    (is (equalp (list (octets-of 255 254 97))
                (db-match-prefix db (octets-of 255))))))
```

In `vivace-cabinet.asd`, add `(:file "match-tests")` after
`(:file "bulk-tests")` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 14 tests fail (`match-prefix-finds-keys`,
`match-regex-finds-keys`, `match-similar-orders-by-distance` and
`matching-skips-nothing-on-bytes-that-are-not-utf-8` on each kind,
`match-prefix-keeps-key-order` on the two tree kinds) with
`UNDEFINED-FUNCTION` `DB-MATCH-PREFIX`, `DB-MATCH-REGEX` or
`DB-MATCH-SIMILAR`; everything else passes.

- [ ] **Step 3: Write the matches**

In `vivace-cabinet.asd`, replace

```lisp
  :depends-on ("alexandria" "babel" "bordeaux-threads" "cffi" "cl-store"
               "log4cl" "uiop"
```

with

```lisp
  :depends-on ("alexandria" "babel" "bordeaux-threads" "cffi" "cl-ppcre"
               "cl-store" "log4cl" "uiop"
```

Append to `api.lisp`:

```lisp
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
```

Create `match.lisp`:

```lisp
;;;; Keys matching a prefix, a regular expression, or within an edit
;;;; distance (spec: API).  A TreeDB in unsigned byte order jumps to a
;;;; prefix; anything else walks every key, as Kyoto Cabinet's PolyDB
;;;; does (kcpolydb.h: match_prefix, match_regex, match_similar).

(in-package #:vivace-cabinet)

(defun %prefix-p (prefix key)
  (and (<= (length prefix) (length key))
       (not (mismatch prefix key :end2 (length prefix)))))

(defun %byte-ordered-p (db)
  "True when DB keeps its keys in unsigned byte order."
  (and (typep db 'tree-db)
       (eq 'octets< (getf (%db-tuning db) :comparator))))

(defun %walk-cursor (db fn &optional from)
  "Call FN with each key a cursor on DB reaches, from FROM (a jump) or
the first record, until FN returns :STOP."
  (with-cursor (cur db)
    (when (cursor-jump cur from)
      (loop for k = (cursor-get-key cur)
            while (and k (not (eq :stop (funcall fn k))))
            while (cursor-step cur)))))

(defun %key-text (k)
  (babel:octets-to-string k :encoding :utf-8 :errorp nil))

(defmethod db-match-prefix ((db database) prefix &key max (as :octets))
  (check-as as)
  (let ((p (to-octets prefix))
        (ordered (%byte-ordered-p db))
        (found '())
        (n 0))
    (%walk-cursor db (lambda (k)
                       (cond ((and max (>= n max)) :stop)
                             ((%prefix-p p k) (push k found) (incf n) nil)
                             (ordered :stop)))
                  (and ordered p))
    (mapcar (lambda (k) (from-octets k as)) (nreverse found))))

(defmethod db-match-regex ((db database) regex &key max (as :octets))
  (check-as as)
  (let ((scanner (handler-case (cl-ppcre:create-scanner regex)
                   (cl-ppcre:ppcre-syntax-error (c)
                     (%signal 'invalid-argument
                              "bad regular expression ~s: ~a" regex c))))
        (found '())
        (n 0))
    (%walk-cursor db (lambda (k)
                       (cond ((and max (>= n max)) :stop)
                             ((cl-ppcre:scan scanner (%key-text k))
                              (push k found)
                              (incf n)
                              nil))))
    (mapcar (lambda (k) (from-octets k as)) (nreverse found))))

(defun %edit-distance (a b)
  "The Levenshtein distance between vectors A and B."
  (let* ((n (length b))
         (prev (make-array (1+ n)))
         (curr (make-array (1+ n))))
    (dotimes (j (1+ n))
      (setf (aref prev j) j))
    (dotimes (i (length a) (aref prev n))
      (setf (aref curr 0) (1+ i))
      (dotimes (j n)
        (setf (aref curr (1+ j))
              (min (1+ (aref prev (1+ j)))
                   (1+ (aref curr j))
                   (+ (aref prev j) (if (eql (aref a i) (aref b j)) 0 1)))))
      (rotatef prev curr))))

(defun %code-points (octets)
  (map 'vector #'char-code (%key-text octets)))

(defmethod db-match-similar ((db database) origin range &key utf max
                                                              (as :octets))
  (check-as as)
  (unless (typep range '(integer 0))
    (%signal 'invalid-argument "RANGE must be a natural number: ~s" range))
  (let* ((o (to-octets origin))
         (oseq (if utf (%code-points o) o))
         (hits '())
         (order 0))
    (%walk-cursor db (lambda (k)
                       (let* ((kseq (if utf (%code-points k) k))
                              (d (and (<= (abs (- (length oseq)
                                                  (length kseq)))
                                          range)
                                      (%edit-distance oseq kseq))))
                         (when (and d (<= d range))
                           (push (list d k order) hits))
                         (incf order)
                         nil)))
    (let ((sorted (sort hits (lambda (x y)
                               (cond ((/= (first x) (first y))
                                      (< (first x) (first y)))
                                     ((octets< (second x) (second y)) t)
                                     ((octets< (second y) (second x)) nil)
                                     (t (< (third x) (third y))))))))
      (mapcar (lambda (h) (from-octets (second h) as))
              (if max
                  (subseq sorted 0 (min max (length sorted)))
                  sorted)))))
```

In `package.lisp`, add to the end of the export list (inside its closing
parentheses), on a new line:

```lisp
           #:db-match-prefix #:db-match-regex #:db-match-similar
```

In `vivace-cabinet.asd`, add `(:file "match")` after `(:file "bulk")` in the
library.

- [ ] **Step 4: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures; `grep -a -i undefined` on the log finds
nothing.

- [ ] **Step 5: Mutation checks**

1. In `match.lisp`, replace

   ```lisp
   (if (eql (aref a i) (aref b j)) 0 1)
   ```

   with

   ```lisp
   (if (eql (aref a i) (aref b j)) 0 2)
   ```

   run `VC-TEST match-similar-orders-by-distance/hash`; confirm it fails as
   a test failure; restore the file.
2. In `match.lisp`, replace

   ```lisp
                          (cond ((and max (>= n max)) :stop)
                                ((cl-ppcre:scan
   ```

   with

   ```lisp
                          (cond ((and nil max (>= n max)) :stop)
                                ((cl-ppcre:scan
   ```

   run `VC-TEST match-regex-finds-keys/bplus-tree`; confirm it fails as a
   test failure; restore the file.
3. In `match.lisp`, replace

   ```lisp
   (babel:octets-to-string k :encoding :utf-8 :errorp nil)
   ```

   with

   ```lisp
   (babel:octets-to-string k :encoding :utf-8)
   ```

   run `VC-TEST matching-skips-nothing-on-bytes-that-are-not-utf-8/hash`;
   confirm it fails as a test failure; restore the file.

- [ ] **Step 6: Document them in `README.md`**

In `README.md`, add this paragraph before `## Limits`, after the paragraph
the last task added:

```markdown
`db-match-prefix`, `db-match-regex` (CL-PPCRE syntax, matched against
keys read as UTF-8) and `db-match-similar` (Levenshtein distance in
bytes, or in characters with `:utf t`; nearest first) return lists of
keys, at most `:max` of them. On a TreeDB in byte order,
`db-match-prefix` reads only the matching keys and returns them in
order; every other match reads every key.
```

- [ ] **Step 7: Commit**

```bash
git add match.lisp \
  tests/match-tests.lisp \
  vivace-cabinet.asd \
  api.lisp \
  package.lisp \
  README.md
git commit -m "Matching keys by prefix, regular expression and edit distance

Regular expressions use CL-PPCRE, a new dependency. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 6: Status, occupying, copying and merging

**Files:**
- Create: `admin.lisp`, `tests/admin-tests.lisp`
- Modify: `database.lisp`, `hash-db.lisp`, `tree-db.lisp` (`db-size`
  becomes `%size`), `api.lisp`, `package.lisp`, `vivace-cabinet.asd`,
  `README.md`

**Interfaces:**
- Consumes: Task 4's `db-iterate` (tests); `with-cursor`, `cursor-get`;
  `db-set`, `db-add`, `db-replace`, `db-append`; `%record-count`,
  `%sync-storage`, `%write-header`, `%header-file`, `%db-dir`,
  `%engine-code`, `%engine-kind`, `bucket-count`, `hash-db-index`.
- Produces: exported `(db-status db)` → plist `:type :path :count :size
  :writable :autosync` and `:buckets` (HashDB) or `:engine` (TreeDB);
  `(db-occupy db fn &key (writable t))`, FN called with `(path count
  size)` → T, or NIL with `:logic`; `(db-copy db dest)` → T;
  `(db-merge db sources &key (mode :set))` → T, or NIL with
  `:no-permission`. Generics `(%size db)` (DB-SIZE unlocked) and
  `(%status db)`; `(%copy-sparse from to)`, `(%mark-closed dir)`.

A trap the dry run hit: `%copy-sparse` must not ask the *output* stream
its `file-length` to see whether the file ended in a hole. SBCL's answer
ignores bytes still in the stream's buffer, so a short file that ends in
data got a zero byte written over its end, and the copy's linear-hash
`struct.dat` would not load. The code below tracks the last block
instead.

- [ ] **Step 1: Write the failing tests**

Create `tests/admin-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-suite admin-suite
  :description "Copying and merging that are not per kind."
  :in vivace-cabinet-suite)

(in-suite admin-suite)

(defun sorted-records (db)
  "DB's records as (key . value) strings, in key order."
  (let ((rs '()))
    (db-iterate db (lambda (k v) (push (cons k v) rs) :nop)
                :writable nil :as :string)
    (sort rs #'string< :key #'car)))

(def-db-test status-describes-the-database
  (with-temp-db (db)
    (db-set db "k" "v")
    (let ((s (db-status db)))
      (is (eq (getf *db-type-args* :type) (getf s :type)))
      (is (= 1 (getf s :count)))
      (is (= (db-size db) (getf s :size)))
      (is (equal (db-path db) (getf s :path)))
      (is (eq t (getf s :writable)))
      (is (null (getf s :autosync)))
      (if (eq :tree (getf s :type))
          (is (eq (getf *db-type-args* :engine) (getf s :engine)))
          (is (plusp (getf s :buckets)))))))

(def-db-test occupy-runs-with-the-database-held
  (with-temp-db (db)
    (db-set db "k" "v")
    (let ((args nil))
      (is-true (db-occupy db (lambda (path count size)
                               (setf args (list path count size))
                               t)))
      (is (equal (list (db-path db) 1 (db-size db)) args)))
    (is (null (db-occupy db (lambda (&rest r) (declare (ignore r)) nil)
                         :writable nil)))
    (is (eq :logic (db-error db)))))

(def-db-test copy-makes-a-database-of-its-own
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "o.vc/" dir))
          (copy (merge-pathnames "c.vc/" dir)))
      (with-test-db (db path)
        (dotimes (i 200)
          (db-set db (keyed i) (keyed i)))
        (is-true (db-copy db copy))
        (signals invalid-argument (db-copy db copy))
        (db-set db "after" "copy"))
      (with-db (c copy)
        (is (= 200 (db-count c)))
        (is (equal (keyed 7) (db-get c (keyed 7) :as :string)))
        (is (null (db-get c "after")))
        (is (eq (getf *db-type-args* :type) (getf (db-status c) :type)))))))

(test copy-keeps-holes
  "The index's 1000 MiB sparse files stay sparse in a copy."
  (with-temp-directory (dir)
    (let ((copy (merge-pathnames "c.vch/" dir)))
      (with-db (db (merge-pathnames "o.vch/" dir))
        (db-set db "k" "v")
        (db-copy db copy))
      (let ((kb (parse-integer
                 (uiop:run-program
                  (list "du" "-k" (namestring
                                   (merge-pathnames "index/table.dat" copy)))
                  :output '(:string :stripped t))
                 :junk-allowed t)))
        (is (< kb 10240) "~a KiB on disk" kb)))))

(def-db-test merge-modes
  "Each mode stores a source's records as its operation would."
  (with-temp-directory (dir)
    (with-test-db (src (merge-pathnames "s.vc/" dir))
      (db-set src "y" "b")
      (db-set src "z" "b")
      (dolist (case '((:set ("x" . "a") ("y" . "b") ("z" . "b"))
                      (:add ("x" . "a") ("y" . "a") ("z" . "b"))
                      (:replace ("x" . "a") ("y" . "b"))
                      (:append ("x" . "a") ("y" . "ab") ("z" . "b"))))
        (with-test-db (m (merge-pathnames
                          (format nil "m-~(~a~).vc/" (first case)) dir))
          (db-set m "x" "a")
          (db-set m "y" "a")
          (is-true (db-merge m (list src) :mode (first case)))
          (is (equal (rest case) (sorted-records m)))))
      (signals invalid-argument (db-merge src (list src)))
      (signals invalid-argument (db-merge src '() :mode :bogus)))))

(test merge-across-types
  "A HashDB merges into a TreeDB, which then holds the records in order."
  (with-temp-directory (dir)
    (with-db (h (merge-pathnames "h.vch/" dir))
      (dolist (k '("c" "a" "b"))
        (db-set h k k))
      (with-db (tr (merge-pathnames "t.vct/" dir) :type :tree)
        (is-true (db-merge tr (list h)))
        (is (equal '("a" "b" "c") (db-match-prefix tr "" :as :string)))))))
```

In `vivace-cabinet.asd`, add `(:file "admin-tests")` after
`(:file "match-tests")` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 14 tests fail (`status-describes-the-database`,
`occupy-runs-with-the-database-held`, `copy-makes-a-database-of-its-own` and
`merge-modes` on each kind, and `copy-keeps-holes` and `merge-across-types`
in `admin-suite`) with `UNDEFINED-FUNCTION` `DB-STATUS`, `DB-OCCUPY`,
`DB-COPY` or `DB-MERGE`; everything else passes.

- [ ] **Step 3: `%size` under `db-size`**

Append to `database.lisp`:

```lisp
(defgeneric %size (db)
  (:documentation "DB-SIZE without the lock."))

(defmethod db-size ((db database))
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (%size db)))
```

In `hash-db.lisp`, replace

```lisp
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

with

```lisp
(defmethod %size ((db hash-db))
  "Bytes in use: the heap's extent and the index's buckets and overflow.
File sizes would overstate: the index files are sparse."
  (let ((index (hash-db-index db)))
    (+ (read-memory-pointer (%db-heap db))
       (* (bucket-count index) (%lhash-bucket-bytes index))
       (read-lhash-next-overflow-pointer index))))
```

In `tree-db.lisp`, replace

```lisp
(defmethod db-size ((db tree-db))
  "Bytes the heap has used."
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (read-memory-pointer (%db-heap db))))
```

with

```lisp
(defmethod %size ((db tree-db))
  "Bytes the heap has used."
  (read-memory-pointer (%db-heap db)))
```

- [ ] **Step 4: Write the operations**

Append to `api.lisp`:

```lisp
(defgeneric db-status (db)
  (:documentation "A plist describing DB: :TYPE, :PATH, :COUNT, :SIZE,
:WRITABLE, :AUTOSYNC, and :BUCKETS (HashDB) or :ENGINE (TreeDB)."))

(defgeneric db-occupy (db fn &key writable)
  (:documentation "Call FN with DB's path, record count and size while
holding DB: exclusively when WRITABLE (the default), else shared with
other operations.  T, or NIL with :LOGIC when FN returns NIL.  FN must
not use DB."))

(defgeneric db-copy (db dest)
  (:documentation "Copy DB's files to DEST, a directory that must not
exist, as a database that opens on its own.  Holes in the index's sparse
files stay holes."))

(defgeneric db-merge (db sources &key mode)
  (:documentation "Store the records of the databases SOURCES into DB,
one source after another, by MODE: :SET (the default), :ADD, :REPLACE
or :APPEND, as the operation of that name would."))
```

Create `admin.lisp`:

```lisp
;;;; Whole-database administration (spec: API): status, occupying the
;;;; database, copying its files, and merging others into it.

(in-package #:vivace-cabinet)

(defgeneric %status (db)
  (:documentation "DB-STATUS's entries for DB's type.")
  (:method ((db hash-db))
    (list :buckets (bucket-count (hash-db-index db))))
  (:method ((db tree-db))
    (list :engine (%engine-kind (%engine-code db)))))

(defmethod db-status ((db database))
  (with-read-lock ((%db-lock db))
    (%check-open db)
    (list* :type (if (typep db 'tree-db) :tree :hash)
           :path (db-path db)
           :count (%record-count db)
           :size (%size db)
           :writable (%db-writable-p db)
           :autosync (%db-autosync-p db)
           (%status db))))

(defmethod db-occupy ((db database) fn &key (writable t))
  (flet ((run ()
           (%check-open db)
           (if (funcall fn (db-path db) (%record-count db) (%size db))
               t
               (%fail db :logic))))
    (if writable
        (with-write-lock ((%db-lock db)) (run))
        (with-read-lock ((%db-lock db)) (run)))))

;;; Copying

(defun %copy-sparse (from to)
  "Copy file FROM to TO, leaving 64 KiB runs of zeros as holes: the
linear hash's index files are mostly holes."
  (let ((buf (make-array 65536 :element-type '(unsigned-byte 8))))
    (declare (type (simple-array (unsigned-byte 8) (65536)) buf))
    (with-open-file (in from :element-type '(unsigned-byte 8))
      (with-open-file (out to :direction :output :if-exists :error
                              :element-type '(unsigned-byte 8))
        (let ((pos 0)
              (hole nil))
          (loop for n = (read-sequence buf in)
                until (zerop n)
                do (setf hole (loop for i below n always (zerop (aref buf i))))
                   (if hole
                       (file-position out (+ pos n))
                       (write-sequence buf out :end n))
                   (incf pos n))
          ;; A file ending in a hole needs its last byte written to keep
          ;; its length.
          (when hole
            (file-position out (1- pos))
            (write-byte 0 out)))))))

(defun %copy-tree (from to)
  (ensure-directories-exist to)
  (dolist (f (uiop:directory-files from))
    (%copy-sparse f (merge-pathnames (file-namestring f) to)))
  (dolist (d (uiop:subdirectories from))
    (%copy-tree d (merge-pathnames
                   (make-pathname :directory
                                  (list :relative
                                        (car (last (pathname-directory d)))))
                   to))))

(defun %mark-closed (dir)
  "Clear the open flag in DIR's header."
  (with-open-file (s (%header-file dir) :direction :io :if-exists :overwrite
                                        :element-type '(unsigned-byte 8))
    (file-position s 6)
    (write-byte 0 s)))

(defmethod db-copy ((db database) dest)
  (let ((to (uiop:ensure-directory-pathname (merge-pathnames dest))))
    (when (probe-file to)
      (%signal 'invalid-argument "~a already exists" to))
    (with-write-lock ((%db-lock db))
      (%check-open db)
      (when (%db-writable-p db)
        (%sync-storage db)
        (%write-header db :open t))
      (%copy-tree (%db-dir db) to)
      ;; Synchronized just now, so the copy needs no recount; a reader's
      ;; header says what the last writer left.
      (when (%db-writable-p db)
        (%mark-closed to))
      t)))

;;; Merging

(defmethod db-merge ((db database) sources &key (mode :set))
  (unless (member mode '(:set :add :replace :append))
    (%signal 'invalid-argument
             "MODE must be :SET, :ADD, :REPLACE or :APPEND: ~s" mode))
  (when (member db sources)
    (%signal 'invalid-argument "a database cannot merge into itself"))
  (if (not (%db-writable-p db))
      (%fail db :no-permission)
      (dolist (src sources t)
        (with-cursor (cur src)
          (when (cursor-jump cur)
            (loop
              (multiple-value-bind (k v) (cursor-get cur)
                (unless k
                  (return))
                (ecase mode
                  (:set (db-set db k v))
                  (:add (db-add db k v))
                  (:replace (db-replace db k v))
                  (:append (db-append db k v))))
              (unless (cursor-step cur)
                (return))))))))
```

In `package.lisp`, add to the end of the export list (inside its closing
parentheses), on a new line:

```lisp
           #:db-status #:db-occupy #:db-copy #:db-merge
```

In `vivace-cabinet.asd`, add `(:file "admin")` after `(:file "match")` in
the library.

- [ ] **Step 5: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures; `grep -a -i undefined` on the log finds
nothing.

- [ ] **Step 6: Mutation checks**

1. In `admin.lisp`, replace

   ```lisp
                   do (setf hole (loop for i below n always (zerop (aref buf i))))
   ```

   with

   ```lisp
                   do (setf hole nil)
   ```

   run `VC-TEST copy-keeps-holes`; confirm it fails as a test failure;
   restore the file.
2. In `admin.lisp`, replace

   ```lisp
                     (:add (db-add db k v))
   ```

   with

   ```lisp
                     (:add (db-set db k v))
   ```

   run `VC-TEST merge-modes/hash`; confirm it fails as a test failure;
   restore the file.

- [ ] **Step 7: Document them in `README.md`**

In `README.md`, add this paragraph before `## Limits`, after the paragraph
the last task added:

```markdown
`db-status` returns a plist describing the database. `db-occupy` calls a
function with the database's path, record count and size while holding
it. `db-copy` copies the database's files into a new directory, which
opens as a database of its own. `db-merge` stores other databases'
records by `:mode` (`:set`, `:add`, `:replace` or `:append`), one source
after another, so under `:set` a key in several sources takes the last
one's value.
```

- [ ] **Step 8: Commit**

```bash
git add admin.lisp \
  tests/admin-tests.lisp \
  database.lisp \
  hash-db.lisp \
  tree-db.lisp \
  api.lisp \
  package.lisp \
  vivace-cabinet.asd \
  README.md
git commit -m "DB-STATUS, DB-OCCUPY, DB-COPY and DB-MERGE

A copy keeps the index's sparse files sparse and opens as a database of
its own. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 7: Snapshots and transactions

**Files:**
- Create: `snapshot.lisp`, `transactions.lisp`,
  `tests/snapshot-tests.lisp`
- Modify: `api.lisp`, `package.lisp`, `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: Task 4's `db-iterate`; `db-set`, `%get-u64`, `%fail`,
  `%signal`, `%db-writable-p`, `invalid-argument`, `not-implemented`.
- Produces: exported `(db-dump-snapshot db path)` → T;
  `(db-load-snapshot db path)` → T, or NIL with `:no-permission`;
  condition `transactions-not-implemented` (a `not-implemented`);
  `(db-begin-transaction db &key hard)`, `(db-begin-transaction-try db
  &key hard)`, `(db-end-transaction db &key commit)`, each signalling it;
  macro `(with-transaction (db &key hard) &body body)`.

- [ ] **Step 1: Write the failing tests**

Create `tests/snapshot-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-db-test snapshots-round-trip
  "A snapshot holds every record; loading it into an empty database of
any kind brings them all back."
  (with-temp-directory (dir)
    (let ((file (merge-pathnames "all.snap" dir)))
      (with-test-db (db (merge-pathnames "s.vc/" dir))
        (dotimes (i 100)
          (db-set db (keyed i) (make-string i :initial-element #\v)))
        (db-set db "" "")
        (db-set db "big" (make-string 50000 :initial-element #\b))
        (is-true (db-dump-snapshot db file)))
      (dolist (args '((:type :hash) (:type :tree :engine :skip-list)))
        (let ((db (apply #'open-db (merge-pathnames
                                    (format nil "l~a.vc/" (length args))
                                    dir)
                         args)))
          (unwind-protect
               (progn
                 (is-true (db-load-snapshot db file))
                 (is (= 102 (db-count db)))
                 (is (equal (make-string 42 :initial-element #\v)
                            (db-get db (keyed 42) :as :string)))
                 (is (equal "" (db-get db "" :as :string)))
                 (is (= 50000 (db-check db "big"))))
            (close-db db)))))))

(def-db-test bad-snapshots-signal
  (with-temp-directory (dir)
    (let ((good (merge-pathnames "good.snap" dir))
          (bad (merge-pathnames "bad.snap" dir))
          (cut (merge-pathnames "cut.snap" dir)))
      (with-test-db (db (merge-pathnames "s.vc/" dir))
        (db-set db "k" "value")
        (db-dump-snapshot db good)
        (with-open-file (out bad :direction :output
                                 :element-type '(unsigned-byte 8))
          (write-sequence (octets-of 1 2 3 4 5 6 7 8) out)
          (write-sequence (make-array 8 :element-type '(unsigned-byte 8)
                                        :initial-element 255)
                          out))
        (let ((all (with-open-file (in good :element-type '(unsigned-byte 8))
                     (let ((v (make-array (file-length in)
                                          :element-type '(unsigned-byte 8))))
                       (read-sequence v in)
                       v))))
          (with-open-file (out cut :direction :output
                                   :element-type '(unsigned-byte 8))
            (write-sequence all out :end (- (length all) 12))))
        (signals invalid-argument (db-load-snapshot db bad))
        (signals invalid-argument (db-load-snapshot db cut))))))

(def-db-test transactions-signal
  (with-temp-db (db)
    (signals transactions-not-implemented (db-begin-transaction db))
    (signals transactions-not-implemented (db-begin-transaction-try db))
    (signals transactions-not-implemented (db-end-transaction db))
    (signals not-implemented (with-transaction (db) (db-set db "k" "v")))
    (is (null (db-get db "k")))))
```

In `vivace-cabinet.asd`, add `(:file "snapshot-tests")` after
`(:file "admin-tests")` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 9 tests (3 per kind: `snapshots-round-trip`,
`bad-snapshots-signal`, `transactions-signal`) fail: `UNDEFINED-FUNCTION`
`DB-DUMP-SNAPSHOT`, and "unknown type specifier:
TRANSACTIONS-NOT-IMPLEMENTED"; everything else passes.

- [ ] **Step 3: Write snapshots and the transaction calls**

Append to `api.lisp`:

```lisp
(defgeneric db-dump-snapshot (db path)
  (:documentation "Write every record to the file PATH, in vivace-cabinet's
own format.  T."))

(defgeneric db-load-snapshot (db path)
  (:documentation "Store every record in the snapshot file PATH.  T, or
NIL with :NO-PERMISSION on a reader; a file that is not a whole snapshot
signals INVALID-ARGUMENT."))

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
```

Create `snapshot.lisp`:

```lisp
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

(defmethod db-dump-snapshot ((db database) path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :element-type '(unsigned-byte 8))
    (write-sequence +snapshot-magic+ out)
    (db-iterate db (lambda (k v)
                     (%write-u64 (length k) out)
                     (%write-u64 (length v) out)
                     (write-sequence k out)
                     (write-sequence v out)
                     :nop)
                :writable nil)
    (%write-u64 +snapshot-end+ out)
    t))

(defmethod db-load-snapshot ((db database) path)
  (if (not (%db-writable-p db))
      (%fail db :no-permission)
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (unless (equalp +snapshot-magic+ (%read-octets in 8 path))
          (%signal 'invalid-argument "~a: not a vivace-cabinet snapshot"
                   path))
        (loop for klen = (%read-u64 in path)
              until (= klen +snapshot-end+)
              do (let* ((vlen (%read-u64 in path))
                        (k (%read-octets in klen path))
                        (v (%read-octets in vlen path)))
                   (db-set db k v)))
        t)))
```

Create `transactions.lisp`:

```lisp
;;;; Transactions: in version 1 every call signals (spec: API; unit 4).

(in-package #:vivace-cabinet)

(defun %no-transactions ()
  (%signal 'transactions-not-implemented
           "transactions are not implemented in version 1"))

(defmethod db-begin-transaction ((db database) &key hard)
  (declare (ignore hard))
  (%no-transactions))

(defmethod db-begin-transaction-try ((db database) &key hard)
  (declare (ignore hard))
  (%no-transactions))

(defmethod db-end-transaction ((db database) &key commit)
  (declare (ignore commit))
  (%no-transactions))
```

In `package.lisp`, add to the end of the export list (inside its closing
parentheses), on a new line:

```lisp
           #:db-dump-snapshot #:db-load-snapshot
           #:transactions-not-implemented #:db-begin-transaction
           #:db-begin-transaction-try #:db-end-transaction
           #:with-transaction
```

In `vivace-cabinet.asd`, add `(:file "snapshot")` and then
`(:file "transactions")` after `(:file "admin")` in the library.

- [ ] **Step 4: Run the suite**

Run: `VC-SUITE`
Expected: exit 0, no failures; `grep -a -i undefined` on the log finds
nothing.

- [ ] **Step 5: Mutation checks**

1. In `snapshot.lisp`, replace

   ```lisp
           (unless (equalp +snapshot-magic+ (%read-octets in 8 path))
   ```

   with

   ```lisp
           (unless (progn (%read-octets in 8 path) t)
   ```

   run `VC-TEST bad-snapshots-signal/hash`; confirm it fails as a test
   failure; restore the file.
2. In `snapshot.lisp`, replace

   ```lisp
       (%write-u64 +snapshot-end+ out)
       t))
   ```

   with

   ```lisp
       t))
   ```

   run `VC-TEST snapshots-round-trip/skip-list`; confirm it fails as a test
   failure; restore the file.

- [ ] **Step 6: Document them, and the status, in `README.md`**

In `README.md`, add these two paragraphs before `## Limits`, after the
paragraph the last task added:

```markdown
`db-dump-snapshot` writes every record to one file, and
`db-load-snapshot` stores a snapshot's records into a database of either
type. The format is vivace-cabinet's own: 8 magic bytes, then each
record's key length and value length (8 bytes each, little-endian), key
and value, and a key length of 2^64-1 at the end.

Version 1 has no transactions: `db-begin-transaction`,
`db-begin-transaction-try`, `db-end-transaction` and `with-transaction`
signal `transactions-not-implemented`.
```

In the paragraph that begins "As in Kyoto Cabinet, an operation that
fails", replace

```markdown
subclasses: `open-error`, `invalid-argument`, `key-too-long`,
`not-implemented`. `db-check` returns the value's size; `db-size` returns
the bytes in use, not file sizes (the index files are sparse).
```

with

```markdown
subclasses: `open-error`, `invalid-argument`, `key-too-long`,
`not-implemented` and its subclass `transactions-not-implemented`.
`db-check` returns the value's size; `db-size` returns the bytes in use,
not file sizes (the index files are sparse).
```

Replace the Status paragraph with:

```markdown
**Status:** HashDB and TreeDB (unit 2) have Kyoto Cabinet's database
API except transactions: records, cursors, visitors, compare-and-swap
and increments, bulk operations, matching, status, copying, merging and
snapshots. Unit 3 benchmarks them against Kyoto Cabinet.
```

- [ ] **Step 7: Commit**

```bash
git add snapshot.lisp \
  transactions.lisp \
  tests/snapshot-tests.lisp \
  api.lisp \
  package.lisp \
  vivace-cabinet.asd \
  README.md
git commit -m "Snapshots, and transaction calls that signal

DB-DUMP-SNAPSHOT and DB-LOAD-SNAPSHOT in vivace-cabinet's own format;
the transaction calls signal TRANSACTIONS-NOT-IMPLEMENTED, as version 1
has none. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

---

## Finish

- [ ] `VC-SUITE` once more: exit 0 (12,741 checks in the dry run).
- [ ] On kraison/vivace-cabinet#2, comment `Ready for review:` with the
  branch and `git -C ~/work/vivace-cabinet diff main...unit-2d-rest-of-api`.
- [ ] On kraison/vivace-cabinet#7, note that the README now lists
  `key-too-long` (Task 2).
- [ ] Stop: merge and push wait for Kevin's word.
