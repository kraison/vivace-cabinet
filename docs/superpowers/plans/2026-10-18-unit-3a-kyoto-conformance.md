# Unit 3a: a Kyoto adapter and the conformance check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kyoto Cabinet behind vivace-cabinet's generic functions (the
`vivace-cabinet/kyoto` adapter, which the benchmark's row 2 also uses),
and `vivace-cabinet/conformance`: random operation sequences run on both,
failing on any difference in a result or a `db-error` reason.

**Architecture:** The adapter is a class, `kyoto-db`, with methods on
the existing generic functions, calling Kyoto's C API through
cl-kyoto-cabinet's bindings and its own. The conformance runner draws
operations from a small key space, so they collide, and applies each one
to both databases, comparing outcomes in an order both libraries define.
The dry run's first conformance runs found TreeDB cursors that did not
behave as Kyoto's. Task 2 gives both cursor types Kyoto's model, before
Task 3 adds the runner, so every commit's suites pass.

**Tech Stack:** SBCL, FiveAM, CFFI, cl-kyoto-cabinet
(`~/work/cl-kyoto-cabinet`), Kyoto Cabinet 1.2.80.

**Spec:** `docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`,
unit 3: "Engines" (row 2's adapter) and "Conformance check"; the phase
split is on kraison/vivace-cabinet#3. Kyoto's cursor behaviour is from
`/usr/include/kcplantdb.h` (the `Cursor` class), checked by running Kyoto
through the adapter.

**Dry run:** every block below was applied, task by task, to a copy of
`main` (079ba62). Each failing-test step failed exactly as its Expected
line says. At the end the core suite passed (12,877 checks) and the
conformance suite passed (19 checks: the adapter tests, and 20
sequences of 1,000 steps on each kind). A longer run, 3 kinds × 40 seeds
× 2,000 steps, found no difference. Every mutation check below failed as a test
failure.

## Global Constraints

- SBCL only. New Lisp: spaces only, 80 columns, terse comments.
- vivace-graph and cl-kyoto-cabinet are not changed. cl-kyoto-cabinet's
  gaps are kraison/cl-kyoto-cabinet#7.
- The core system and its suite do not need Kyoto; only
  `vivace-cabinet/kyoto` and `vivace-cabinet/conformance` do.
- Logical failures return NIL and set the reason `db-error` reports; real
  errors signal `vivace-cabinet-error` subclasses. The adapter follows
  this too.
- Branch `unit-3a-kyoto-conformance` in `~/work/vivace-cabinet`; one
  commit per task; explicit `git add` paths; nothing pushed without
  Kevin's word.
- Public repo: generic commit messages and issue text.
- Every commit message ends with:

  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ
  ```

## Commands

`VC-SUITE` (the core suite, as in unit 2; about a minute):

```bash
mkdir -p /var/tmp/vc-tests && cd ~/work/vivace-cabinet && \
TMPDIR=/var/tmp/vc-tests sbcl --noinform --non-interactive \
  --load ~/quicklisp/setup.lisp \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval '(ql:quickload (list :alexandria :bordeaux-threads :cffi :cl-ppcre :cl-store :log4cl :fiveam :babel) :silent t)' \
  --eval '(asdf:load-system :vivace-cabinet/test :force (list :vivace-cabinet :vivace-cabinet/test))' \
  --eval '(asdf:test-system :vivace-cabinet)'
```

`VC-CONFORM` (the conformance suite; about ten seconds):

```bash
mkdir -p /var/tmp/vc-tests && cd ~/work/vivace-cabinet && \
TMPDIR=/var/tmp/vc-tests sbcl --noinform --non-interactive \
  --load ~/quicklisp/setup.lisp \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval '(push (merge-pathnames "work/cl-kyoto-cabinet/" (user-homedir-pathname)) asdf:*central-registry*)' \
  --eval '(ql:quickload (list :alexandria :bordeaux-threads :cffi :cl-ppcre :cl-store :log4cl :fiveam :babel) :silent t)' \
  --eval '(asdf:load-system :vivace-cabinet/conformance :force (list :vivace-cabinet :vivace-cabinet/kyoto :vivace-cabinet/conformance))' \
  --eval '(asdf:test-system :vivace-cabinet/conformance)'
```

`VC-TEST <name>` and `VC-CONFORM-TEST <name>`: the same with the last
`--eval` replaced by
`--eval '(unless (fiveam:run! (quote <package>::<name>)) (uiop:quit 1))'`,
where `<package>` is `vivace-cabinet-test` or
`vivace-cabinet-conformance`. Tests made by `def-db-test` and
`def-tree-test` are named `<name>/<kind>` (`hash`, `bplus-tree`,
`skip-list`); the conformance tests are `conforms/<kind>`.

Mutation checks: change the code in place as stated, run the named test,
confirm it fails *as a test failure, not a compile error*, and restore
the file byte for byte. Run them under `timeout 400`. Logs can contain NUL
bytes: `grep -a`. Kyoto runs in the test process: a memory fault in
foreign code ends it, so run each suite in its own process, as the
commands do.

## Review Focus

1. **Keys and values of any bytes through the adapter**, zero bytes
   included: they must survive set, get, check, a cursor jump and remove
   (Task 1 `adapter-carries-every-byte`).
2. **Kyoto cursors not released by `with-cursor`**: `close-db` must
   delete them before the database, or Kyoto touches freed memory (Task 1
   `adapter-releases-cursors`).
3. **A record removed under a cursor by another call**, then the cursor
   reads, edits or steps: it acts on the next record, as Kyoto's does
   (Task 2 `cursor-moves-on-from-removed-records`,
   `cursor-edits-reach-a-record-after-removal`,
   `cursor-follows-removal-backward`).
4. **Cursor edits racing removals from another thread**: a visitor never
   sees NIL, and no removed record comes back (Task 2
   `cursor-accept-never-visits-a-removed-record`; the stress test).
5. **`db-clear` with cursors open**: they are on no record until they
   jump again (Task 2 `cursor-is-nowhere-after-clear`).

## Proposals in this plan for Kevin to approve

- **Cursors follow Kyoto's model, which reverses 2c's da01fcc. This one
  needs an explicit yes: it changes three 2c tests.** Kyoto's tree
  cursor, checked through the adapter, does this:
  - Each read, edit or step first moves to the first record at or after
    the cursor's key.
  - After a backward move, a removal moves to the previous record.

  So after a backward move, a read of a removed record returns the
  *next* record. 2c's review fix had made it return the previous one.
  The three tests that change:
  - `cursor-follows-removal-backward` now expects the next record.
  - `cursor-edits-records` now expects a removal after a backward move
    to land on the previous record.
  - The stress test no longer checks a backward walk's order. Under
    Kyoto's model, a backward walk can read a record twice while other
    threads remove records; forward walks are still checked.

  The alternative keeps 2c's behaviour: the conformance generator then
  avoids removals while its cursor last moved backward, and the README
  states the difference.
- **Edits through a cursor whose record was removed act on the next
  record**, as Kyoto's do. Today they fail with `:no-record` (#7's
  "stale key" item). `cursor-accept` likewise never visits NIL (#8's
  item).
- **`db-clear` invalidates every cursor**, as Kyoto's does.
- **The adapter binds some Kyoto calls itself.** It uses
  cl-kyoto-cabinet's exported bindings and its library loading. Where
  cl-kyoto-cabinet's bindings take string keys, are unexported or are
  missing, it binds the calls itself, with pointer keys
  (kraison/cl-kyoto-cabinet#7). Row 2 of the benchmark therefore
  reaches Kyoto through CFFI, as cl-kyoto-cabinet does, rather than
  through its `dbm-*` layer.
- **`with-cursor` releases its cursor** through a new internal generic,
  `%release-cursor`, which does nothing for vivace-cabinet's own
  cursors; Kyoto's must be deleted.
- **What the check compares, and what it leaves out**
  (`docs/conformance.md`):
  - A HashDB's order is its own in each library, so its walks and
    matches are compared as sorted sets, and its cursors only by a jump
    and a read.
  - Increments landing exactly on the most negative 64-bit integer are
    left out (#8).
  - Keys are ASCII, and regular expressions are ones both engines read
    alike.
  - Visitors, status, copy, merge and snapshots are not compared.
- **Kyoto's other error codes** map to keywords named after Kyoto's
  (`:invalid`, `:broken`, `:system`, ...).
- **Suite size**: 20 sequences of 1,000 operations per kind, about ten
  seconds. `check-conformance` runs longer ones.

---

### Task 1: The Kyoto adapter

**Files:**
- Create: `kyoto/package.lisp`, `kyoto/ffi.lisp`, `kyoto/db.lisp`,
  `kyoto/cursor.lisp`, `conformance/package.lisp`,
  `conformance/support.lisp`, `conformance/adapter-tests.lisp`
- Modify: `api.lisp` (`with-cursor`), `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: the generic functions in `api.lisp`; `to-octets`,
  `from-octets`, `check-as`, `%signal`, `%cursor-db`;
  cl-kyoto-cabinet's exported `kcdbnew`, `kcdbopen`, `kcdbclose`,
  `kcdbdel`, `kcdbecode`, `kcdbset`, `kcdbadd`, `kcdbappend`,
  `kcdbcount`, `kcdbclear`, `kcdbcursor`, `kccurdel`, `kccurjump`,
  `kccurstep`, `kccurget`, `kccurremove`, `kcfree`.
- Produces: package `vivace-cabinet-kyoto` exporting `kyoto-db`,
  `(open-kyoto-db path &key (mode '(:writer :create)) tuning)` and
  `(kyoto-error-code code)`; methods on `kyoto-db` for `close-db`,
  `db-error`, `db-path`, `db-count`, `db-size`, `db-clear`, `db-set`,
  `db-add`, `db-replace`, `db-append`, `db-get`, `db-seize`, `db-check`,
  `db-remove`, `db-increment`, `db-increment-double`, `db-cas`, the bulk
  calls, the matches and `db-cursor`; class `kyoto-cursor` with the
  cursor methods. In vivace-cabinet: generic `(%release-cursor cursor)`,
  which `with-cursor` calls. Package `vivace-cabinet-conformance` with
  `(fresh-directory name)`, suite `conformance-suite` and macro
  `(with-kyoto (var file) &body)`.

- [ ] **Step 1: Branch**

```bash
cd ~/work/vivace-cabinet && git switch -c unit-3a-kyoto-conformance
```

- [ ] **Step 2: Write the failing tests**

The adapter's package imports `%release-cursor`, so this step also adds
that hook. In `api.lisp`, replace

```lisp
(defmacro with-cursor ((var db) &body body)
  "Evaluate BODY with VAR bound to a new cursor on DB."
  `(let ((,var (db-cursor ,db)))
     ,@body))
```

with

```lisp
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
```

Create `kyoto/package.lisp`:

```lisp
;;;; Kyoto Cabinet behind vivace-cabinet's API (spec: unit 3).  Used by
;;;; the conformance check and by the benchmark's Kyoto-from-Lisp row.

(defpackage #:vivace-cabinet-kyoto
  (:use #:common-lisp #:vivace-cabinet)
  (:import-from #:vivace-cabinet
                #:to-octets #:from-octets #:check-as #:%signal #:octets
                #:%release-cursor #:%cursor-db)
  (:export #:kyoto-db #:open-kyoto-db #:kyoto-error-code))
```

Create `conformance/package.lisp`:

```lisp
;;;; The conformance check (spec: unit 3): random operation sequences run
;;;; on vivace-cabinet and on Kyoto Cabinet, compared step by step.

(defpackage #:vivace-cabinet-conformance
  (:use #:common-lisp #:vivace-cabinet #:vivace-cabinet-kyoto)
  (:export #:check-conformance #:*kinds* #:run-sequence))
```

Create `conformance/support.lisp`:

```lisp
;;;; What the conformance tests share: a suite and fresh directories.

(in-package #:vivace-cabinet-conformance)

(defun fresh-directory (name)
  "A new directory under the temporary directory, named after NAME."
  (let ((dir (merge-pathnames
              (format nil "~a-~36r/" name
                      (random (expt 36 8) (make-random-state t)))
              (uiop:temporary-directory))))
    (if (probe-file dir)
        (fresh-directory name)
        (ensure-directories-exist dir))))

(fiveam:def-suite conformance-suite
  :description "vivace-cabinet against Kyoto Cabinet.")

(fiveam:in-suite conformance-suite)

(defmacro with-kyoto ((var file) &body body)
  "Bind VAR to a new Kyoto database in FILE, in a fresh directory."
  (let ((dir (gensym "DIR")))
    `(let ((,dir (fresh-directory "vc-kyoto")))
       (let ((,var (open-kyoto-db (merge-pathnames ,file ,dir)
                                  :mode '(:writer :create :truncate))))
         (unwind-protect (progn ,@body)
           (close-db ,var)
           (uiop:delete-directory-tree ,dir :validate t))))))
```

Create `conformance/adapter-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-conformance)

(fiveam:in-suite conformance-suite)

(fiveam:test adapter-reports-kyotos-reasons
  (with-kyoto (db "a.kch")
    (fiveam:is-true (db-set db "k" "v"))
    (fiveam:is (null (db-add db "k" "w")))
    (fiveam:is (eq :duplicate-record (db-error db)))
    (fiveam:is (null (db-remove db "absent")))
    (fiveam:is (eq :no-record (db-error db)))
    (fiveam:is (null (db-increment db "k" 1)))
    (fiveam:is (eq :logic (db-error db)))))

(fiveam:test adapter-carries-every-byte
  "Keys and values with zero bytes pass through intact."
  (with-kyoto (db "b.kct")
    (let ((k (coerce #(0 1 0 255) '(simple-array (unsigned-byte 8) (*))))
          (v (coerce #(0 0 7) '(simple-array (unsigned-byte 8) (*)))))
      (fiveam:is-true (db-set db k v))
      (fiveam:is (equalp v (db-get db k)))
      (fiveam:is (= 3 (db-check db k)))
      (with-cursor (c db)
        (fiveam:is-true (cursor-jump c k))
        (fiveam:is (equalp k (cursor-get-key c))))
      (fiveam:is-true (db-remove db k))
      (fiveam:is (zerop (db-count db))))))

(fiveam:test adapter-releases-cursors
  "WITH-CURSOR deletes Kyoto's cursor; CLOSE-DB deletes any left."
  (with-kyoto (db "c.kch")
    (with-cursor (c db)
      (cursor-jump c))
    (fiveam:is (null (vivace-cabinet-kyoto::%kdb-cursors db)))
    (db-cursor db)
    (fiveam:is (= 1 (length (vivace-cabinet-kyoto::%kdb-cursors db))))))
```

In `vivace-cabinet.asd`, before `(defsystem "vivace-cabinet/test"`, add:

```lisp
(defsystem "vivace-cabinet/kyoto"
  :description "Kyoto Cabinet behind vivace-cabinet's API, through
cl-kyoto-cabinet."
  :depends-on ("vivace-cabinet" "cl-kyoto-cabinet" "cffi" "bordeaux-threads")
  :pathname "kyoto/"
  :serial t
  :components ((:file "package")))

(defsystem "vivace-cabinet/conformance"
  :description "Random operation sequences on vivace-cabinet and Kyoto
Cabinet, compared step by step."
  :depends-on ("vivace-cabinet" "vivace-cabinet/kyoto" "fiveam" "alexandria"
               "uiop")
  :pathname "conformance/"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "adapter-tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call
                      :fiveam :run!
                      (uiop:find-symbol* :conformance-suite
                                         :vivace-cabinet-conformance))
               (error "conformance tests failed"))))
```

- [ ] **Step 3: Run the suites and watch the adapter tests fail**

Run: `VC-CONFORM`
Expected: non-zero exit; the 3 adapter tests
(`adapter-reports-kyotos-reasons`, `adapter-carries-every-byte`,
`adapter-releases-cursors`) fail with `UNDEFINED-FUNCTION` `OPEN-KYOTO-DB`.

Run: `VC-SUITE`
Expected: exit 0, no failures (12,832 checks): `with-cursor`'s change
keeps the core suite green.

- [ ] **Step 4: Write the adapter**

Create `kyoto/ffi.lisp`:

```lisp
;;;; Kyoto's C API (kclangc.h).  cl-kyoto-cabinet loads the library and
;;;; its exported bindings are used where they take keys as pointer and
;;;; size; the calls below are those it binds with string keys (which
;;;; cannot carry every byte), leaves unexported, or does not bind.  The
;;;; match calls take and return C strings: keys holding a zero byte do
;;;; not pass.

(in-package #:vivace-cabinet-kyoto)

(cffi:defcstruct kcstr
  (buf :pointer)
  (size :size))

(cffi:defcstruct kcrec
  (key (:struct kcstr))
  (value (:struct kcstr)))

(cffi:defcfun ("kcdbget" %kcdbget) :pointer
  (db :pointer) (kbuf :pointer) (ksiz :size) (sp :pointer))

(cffi:defcfun ("kcdbseize" %kcdbseize) :pointer
  (db :pointer) (kbuf :pointer) (ksiz :size) (sp :pointer))

(cffi:defcfun ("kcdbcheck" %kcdbcheck) :int32
  (db :pointer) (kbuf :pointer) (ksiz :size))

(cffi:defcfun ("kcdbremove" %kcdbremove) :boolean
  (db :pointer) (kbuf :pointer) (ksiz :size))

(cffi:defcfun ("kcdbreplace" %kcdbreplace) :boolean
  (db :pointer) (kbuf :pointer) (ksiz :size) (vbuf :pointer) (vsiz :size))

(cffi:defcfun ("kcdbincrint" %kcdbincrint) :int64
  (db :pointer) (kbuf :pointer) (ksiz :size) (num :int64) (orig :int64))

(cffi:defcfun ("kcdbincrdouble" %kcdbincrdouble) :double
  (db :pointer) (kbuf :pointer) (ksiz :size) (num :double) (orig :double))

(cffi:defcfun ("kcdbcas" %kcdbcas) :boolean
  (db :pointer) (kbuf :pointer) (ksiz :size)
  (ovbuf :pointer) (ovsiz :size) (nvbuf :pointer) (nvsiz :size))

(cffi:defcfun ("kcdbsize" %kcdbsize) :int64
  (db :pointer))

(cffi:defcfun ("kcdbsetbulk" %kcdbsetbulk) :int64
  (db :pointer) (recs :pointer) (rnum :size) (atomic :int32))

(cffi:defcfun ("kcdbremovebulk" %kcdbremovebulk) :int64
  (db :pointer) (keys :pointer) (knum :size) (atomic :int32))

(cffi:defcfun ("kcdbgetbulk" %kcdbgetbulk) :int64
  (db :pointer) (keys :pointer) (knum :size) (recs :pointer)
  (atomic :int32))

(cffi:defcfun ("kcdbmatchprefix" %kcdbmatchprefix) :int64
  (db :pointer) (prefix :pointer) (strary :pointer) (max :size))

(cffi:defcfun ("kcdbmatchregex" %kcdbmatchregex) :int64
  (db :pointer) (regex :pointer) (strary :pointer) (max :size))

(cffi:defcfun ("kcdbmatchsimilar" %kcdbmatchsimilar) :int64
  (db :pointer) (origin :pointer) (range :uint32) (utf :int32)
  (strary :pointer) (max :size))

(cffi:defcfun ("kccurjumpkey" %kccurjumpkey) :boolean
  (cur :pointer) (kbuf :pointer) (ksiz :size))

(cffi:defcfun ("kccurjumpback" %kccurjumpback) :boolean
  (cur :pointer))

(cffi:defcfun ("kccurjumpbackkey" %kccurjumpbackkey) :boolean
  (cur :pointer) (kbuf :pointer) (ksiz :size))

(cffi:defcfun ("kccurstepback" %kccurstepback) :boolean
  (cur :pointer))

(cffi:defcfun ("kccursetvalue" %kccursetvalue) :boolean
  (cur :pointer) (vbuf :pointer) (vsiz :size) (step :int32))

(cffi:defcfun ("kccurseize" %kccurseize) :pointer
  (cur :pointer) (ksp :pointer) (vbp :pointer) (vsp :pointer))

(cffi:defcfun ("kccurecode" %kccurecode) :int32
  (cur :pointer))

;;; Moving bytes across

(defmacro with-octets ((ptr v) &body body)
  "Run BODY with PTR pointing at the bytes of the octets V, pinned."
  `(cffi:with-pointer-to-vector-data (,ptr ,v)
     ,@body))

(defun %copy-in (ptr size)
  "SIZE bytes at PTR as new octets."
  (let ((v (make-array size :element-type '(unsigned-byte 8))))
    (with-octets (p v)
      (cffi:foreign-funcall "memcpy" :pointer p :pointer ptr :size size
                                     :pointer))
    v))

(defun %take (ptr size)
  "SIZE bytes at PTR as octets, PTR then freed; NIL for a null PTR."
  (unless (cffi:null-pointer-p ptr)
    (prog1 (%copy-in ptr size)
      (kyoto-cabinet-ffi:kcfree ptr))))

(defmacro with-c-string ((ptr v) &body body)
  "Run BODY with PTR pointing at a zero-terminated copy of the octets V."
  (let ((n (gensym "N"))
        (src (gensym "SRC")))
    `(let ((,n (length ,v)))
       (cffi:with-foreign-pointer (,ptr (1+ ,n))
         (with-octets (,src ,v)
           (cffi:foreign-funcall "memcpy" :pointer ,ptr :pointer ,src
                                          :size ,n :pointer))
         (setf (cffi:mem-aref ,ptr :uint8 ,n) 0)
         ,@body))))

(defun %c-string-octets (ptr)
  "The zero-terminated bytes at PTR as octets."
  (%copy-in ptr (cffi:foreign-funcall "strlen" :pointer ptr :size)))
```

Create `kyoto/db.lisp`:

```lisp
;;;; A Kyoto Cabinet database as a vivace-cabinet database: the generic
;;;; functions over Kyoto's C API, for the operations the conformance
;;;; check and the benchmark use.

(in-package #:vivace-cabinet-kyoto)

(defclass kyoto-db ()
  ((ptr :initarg :ptr :accessor %kdb-ptr)
   (path :initarg :path :reader %kdb-path)
   (cursors :initform '() :accessor %kdb-cursors)
   (lock :initform (bt:make-lock "kyoto cursors") :reader %kdb-lock)))

(defparameter *mode-flags*
  '((:reader . :read) (:writer . :write) (:create . :create)
    (:truncate . :truncate) (:autosync . :autosync))
  "vivace-cabinet's open modes and Kyoto's.")

(defun open-kyoto-db (path &key (mode '(:writer :create)) tuning)
  "Open the Kyoto Cabinet database in the file PATH, whose extension
picks its type (.kch HashDB, .kct TreeDB).  TUNING is a plist of Kyoto's
tuning parameters, e.g. (:bnum 2000000).  Returns a KYOTO-DB."
  (let* ((flags (mapcar (lambda (m)
                          (or (cdr (assoc m *mode-flags*))
                              (%signal 'invalid-argument
                                       "unknown mode ~s" m)))
                        mode))
         (name (format nil "~a~{#~(~a~)=~a~}"
                       (uiop:native-namestring (merge-pathnames path))
                       tuning))
         (ptr (kyoto-cabinet-ffi:kcdbnew)))
    (unless (kyoto-cabinet-ffi:kcdbopen ptr name flags)
      (let ((code (kyoto-cabinet-ffi:kcdbecode ptr)))
        (kyoto-cabinet-ffi:kcdbdel ptr)
        (%signal 'open-error "~a: Kyoto error ~a" name code)))
    (make-instance 'kyoto-db :ptr ptr :path (merge-pathnames path))))

(defun %ptr (db)
  (or (%kdb-ptr db)
      (%signal 'invalid-argument "the Kyoto database is closed")))

(defun kyoto-error-code (code)
  "Kyoto's error CODE as vivace-cabinet's DB-ERROR reason."
  (case code
    (0 :success) (1 :not-implemented) (2 :invalid) (3 :no-repository)
    (4 :no-permission) (5 :broken) (6 :duplicate-record) (7 :no-record)
    (8 :logic) (9 :system) (t :misc)))

(defmethod db-error ((db kyoto-db))
  (kyoto-error-code (kyoto-cabinet-ffi:kcdbecode (%ptr db))))

(defmethod close-db ((db kyoto-db))
  (let ((ptr (%kdb-ptr db)))
    (when ptr
      (mapc #'%release-cursor (copy-list (%kdb-cursors db)))
      (setf (%kdb-ptr db) nil)
      (prog1 (kyoto-cabinet-ffi:kcdbclose ptr)
        (kyoto-cabinet-ffi:kcdbdel ptr)))))

(defmethod db-path ((db kyoto-db))
  (namestring (%kdb-path db)))

(defmethod db-count ((db kyoto-db))
  (kyoto-cabinet-ffi:kcdbcount (%ptr db)))

(defmethod db-size ((db kyoto-db))
  (%kcdbsize (%ptr db)))

(defmethod db-clear ((db kyoto-db))
  (kyoto-cabinet-ffi:kcdbclear (%ptr db)))

;;; One record

(defmacro %with-kv ((k kp v vp) (key value) &body body)
  "Run BODY with K and V the octets of KEY and VALUE, KP and VP pointing
at their bytes."
  `(let ((,k (to-octets ,key))
         (,v (to-octets ,value)))
     (with-octets (,kp ,k)
       (with-octets (,vp ,v)
         ,@body))))

(defmethod db-set ((db kyoto-db) key value)
  (%with-kv (k kp v vp) (key value)
    (kyoto-cabinet-ffi:kcdbset (%ptr db) kp (length k) vp (length v))))

(defmethod db-add ((db kyoto-db) key value)
  (%with-kv (k kp v vp) (key value)
    (kyoto-cabinet-ffi:kcdbadd (%ptr db) kp (length k) vp (length v))))

(defmethod db-replace ((db kyoto-db) key value)
  (%with-kv (k kp v vp) (key value)
    (%kcdbreplace (%ptr db) kp (length k) vp (length v))))

(defmethod db-append ((db kyoto-db) key value)
  (%with-kv (k kp v vp) (key value)
    (kyoto-cabinet-ffi:kcdbappend (%ptr db) kp (length k) vp (length v))))

(defmacro %with-key ((k kp) key &body body)
  `(let ((,k (to-octets ,key)))
     (with-octets (,kp ,k)
       ,@body)))

(defun %fetch (fn db key as)
  "Call the Kyoto function FN on KEY, which returns a value and its size;
the value AS, or NIL."
  (check-as as)
  (%with-key (k kp) key
    (cffi:with-foreign-object (sp :size)
      (let ((v (%take (funcall fn (%ptr db) kp (length k) sp)
                      (cffi:mem-ref sp :size))))
        (and v (from-octets v as))))))

(defmethod db-get ((db kyoto-db) key &key (as :octets))
  (%fetch #'%kcdbget db key as))

(defmethod db-seize ((db kyoto-db) key &key (as :octets))
  (%fetch #'%kcdbseize db key as))

(defmethod db-check ((db kyoto-db) key)
  (%with-key (k kp) key
    (let ((n (%kcdbcheck (%ptr db) kp (length k))))
      (and (>= n 0) n))))

(defmethod db-remove ((db kyoto-db) key)
  (%with-key (k kp) key
    (%kcdbremove (%ptr db) kp (length k))))

;;; Numbers and compare-and-swap

(defmethod db-increment ((db kyoto-db) key num &key (orig 0))
  (%with-key (k kp) key
    (let ((n (%kcdbincrint (%ptr db) kp (length k) num orig)))
      ;; Kyoto's failure value: a sum that is exactly it reads as failure.
      (and (/= n (- (expt 2 63))) n))))

(defmethod db-increment-double ((db kyoto-db) key num &key (orig 0d0))
  (%with-key (k kp) key
    (let ((n (%kcdbincrdouble (%ptr db) kp (length k)
                              (float num 1d0) (float orig 1d0))))
      (and (not (sb-ext:float-nan-p n)) n))))

(defmethod db-cas ((db kyoto-db) key old new)
  (let ((o (and old (to-octets old)))
        (n (and new (to-octets new)))
        (none (make-array 0 :element-type '(unsigned-byte 8))))
    (%with-key (k kp) key
      (with-octets (op (or o none))
        (with-octets (np (or n none))
          (%kcdbcas (%ptr db) kp (length k)
                    (if o op (cffi:null-pointer)) (length (or o none))
                    (if n np (cffi:null-pointer)) (length (or n none))))))))

;;; Bulk: Kyoto takes arrays of KCSTR and KCREC

(defun %fill-kcstr (str octets)
  "Point the KCSTR at STR to a foreign copy of OCTETS."
  (let ((buf (cffi:foreign-alloc :uint8 :count (max 1 (length octets)))))
    (with-octets (p octets)
      (cffi:foreign-funcall "memcpy" :pointer buf :pointer p
                                     :size (length octets) :pointer))
    (setf (cffi:foreign-slot-value str '(:struct kcstr) 'buf) buf
          (cffi:foreign-slot-value str '(:struct kcstr) 'size)
          (length octets))))

(defun %free-kcstr (str)
  (cffi:foreign-free (cffi:foreign-slot-value str '(:struct kcstr) 'buf)))

(defmacro %with-kcstrs ((ptr list) &body body)
  "Run BODY with PTR an array of KCSTR holding copies of LIST's octets."
  (let ((n (gensym "N")) (i (gensym "I")) (x (gensym "X")))
    `(let ((,n (length ,list)))
       (cffi:with-foreign-object (,ptr '(:struct kcstr) (max 1 ,n))
         (loop for ,x in ,list for ,i from 0
               do (%fill-kcstr (cffi:mem-aptr ,ptr '(:struct kcstr) ,i) ,x))
         (unwind-protect (progn ,@body)
           (dotimes (,i ,n)
             (%free-kcstr (cffi:mem-aptr ,ptr '(:struct kcstr) ,i))))))))

(defun %bulk-count (n)
  (and (>= n 0) n))

(defmethod db-set-bulk ((db kyoto-db) records &key (atomic t))
  (let ((n (length records)))
    (cffi:with-foreign-object (recs '(:struct kcrec) (max 1 n))
      (flet ((field (i name)
               (cffi:foreign-slot-pointer
                (cffi:mem-aptr recs '(:struct kcrec) i) '(:struct kcrec)
                name)))
        (loop for (key . value) in records for i from 0
              do (%fill-kcstr (field i 'key) (to-octets key))
                 (%fill-kcstr (field i 'value) (to-octets value)))
        (unwind-protect
             (%bulk-count (%kcdbsetbulk (%ptr db) recs n (if atomic 1 0)))
          (dotimes (i n)
            (%free-kcstr (field i 'key))
            (%free-kcstr (field i 'value))))))))

(defmethod db-remove-bulk ((db kyoto-db) keys &key (atomic t))
  (let ((ks (mapcar #'to-octets keys)))
    (%with-kcstrs (arr ks)
      (%bulk-count (%kcdbremovebulk (%ptr db) arr (length ks)
                                    (if atomic 1 0))))))

(defmethod db-get-bulk ((db kyoto-db) keys &key (atomic t) (as :octets))
  (check-as as)
  (let ((ks (mapcar #'to-octets keys)))
    (%with-kcstrs (arr ks)
      (cffi:with-foreign-object (recs '(:struct kcrec) (max 1 (length ks)))
        (let ((n (%kcdbgetbulk (%ptr db) arr (length ks) recs
                               (if atomic 1 0))))
          (and (>= n 0)
               (loop for i below n
                     collect (flet ((take (name)
                                      (let ((s (cffi:foreign-slot-pointer
                                                (cffi:mem-aptr
                                                 recs '(:struct kcrec) i)
                                                '(:struct kcrec) name)))
                                        (from-octets
                                         (%take (cffi:foreign-slot-value
                                                 s '(:struct kcstr) 'buf)
                                                (cffi:foreign-slot-value
                                                 s '(:struct kcstr) 'size))
                                         as))))
                               (cons (take 'key) (take 'value))))))))))

;;; Matching: Kyoto returns keys as C strings in an array of MAX slots

(defun %matches (db max as fn)
  "Call FN with an array of MAX (or every record's) slots and that size;
the keys it fills, AS."
  (check-as as)
  (let ((slots (or max (db-count db))))
    (cffi:with-foreign-object (strary :pointer (max 1 slots))
      (let ((n (funcall fn strary slots)))
        (and (>= n 0)
             (loop for i below n
                   collect (let ((p (cffi:mem-aref strary :pointer i)))
                             (prog1 (from-octets (%c-string-octets p) as)
                               (kyoto-cabinet-ffi:kcfree p)))))))))

(defmethod db-match-prefix ((db kyoto-db) prefix &key max (as :octets))
  (with-c-string (p (to-octets prefix))
    (%matches db max as (lambda (arr slots)
                          (%kcdbmatchprefix (%ptr db) p arr slots)))))

(defmethod db-match-regex ((db kyoto-db) regex &key max (as :octets))
  (with-c-string (p (to-octets regex))
    (%matches db max as (lambda (arr slots)
                          (%kcdbmatchregex (%ptr db) p arr slots)))))

(defmethod db-match-similar ((db kyoto-db) origin range
                             &key utf max (as :octets))
  (with-c-string (p (to-octets origin))
    (%matches db max as (lambda (arr slots)
                          (%kcdbmatchsimilar (%ptr db) p range
                                             (if utf 1 0) arr slots)))))
```

Create `kyoto/cursor.lisp`:

```lisp
;;;; Kyoto cursors as vivace-cabinet cursors.  Kyoto's must be deleted:
;;;; WITH-CURSOR releases them, and CLOSE-DB deletes any still live.

(in-package #:vivace-cabinet-kyoto)

(defclass kyoto-cursor ()
  ((ptr :initarg :ptr :accessor %kc-ptr)
   (db :initarg :db :reader %kc-db)))

(defmethod db-cursor ((db kyoto-db))
  (let ((c (make-instance 'kyoto-cursor
                          :ptr (kyoto-cabinet-ffi:kcdbcursor (%ptr db))
                          :db db)))
    (bt:with-lock-held ((%kdb-lock db))
      (push c (%kdb-cursors db)))
    c))

(defmethod %release-cursor ((c kyoto-cursor))
  (let ((db (%kc-db c)))
    (bt:with-lock-held ((%kdb-lock db))
      (when (%kc-ptr c)
        (kyoto-cabinet-ffi:kccurdel (%kc-ptr c))
        (setf (%kc-ptr c) nil)
        (setf (%kdb-cursors db) (delete c (%kdb-cursors db)))))))

(defmethod %cursor-db ((c kyoto-cursor))
  (%kc-db c))

(defun %cur (c)
  (or (%kc-ptr c)
      (%signal 'invalid-argument "the Kyoto cursor is released")))

(defun %backward (c ok)
  "OK, but a backward move that Kyoto refuses as not implemented (on a
HashDB) signals NOT-IMPLEMENTED, as vivace-cabinet's do."
  (or ok
      (if (= 1 (%kccurecode (%cur c)))
          (%signal 'not-implemented "a HashDB cursor moves forward only")
          nil)))

(defmethod cursor-jump ((c kyoto-cursor) &optional key)
  (if key
      (%with-key (k kp) key
        (%kccurjumpkey (%cur c) kp (length k)))
      (kyoto-cabinet-ffi:kccurjump (%cur c))))

(defmethod cursor-jump-back ((c kyoto-cursor) &optional key)
  (%backward c (if key
                   (%with-key (k kp) key
                     (%kccurjumpbackkey (%cur c) kp (length k)))
                   (%kccurjumpback (%cur c)))))

(defmethod cursor-step ((c kyoto-cursor))
  (kyoto-cabinet-ffi:kccurstep (%cur c)))

(defmethod cursor-step-back ((c kyoto-cursor))
  (%backward c (%kccurstepback (%cur c))))

(defun %record (fn as)
  "Call FN with pointers for the key size, value pointer and value size;
it returns the key region, which holds the value too.  (values key
value) AS, or NIL."
  (cffi:with-foreign-objects ((ksp :size) (vbp :pointer) (vsp :size))
    (let ((kp (funcall fn ksp vbp vsp)))
      (unless (cffi:null-pointer-p kp)
        (unwind-protect
             (values (from-octets (%copy-in kp (cffi:mem-ref ksp :size)) as)
                     (from-octets (%copy-in (cffi:mem-ref vbp :pointer)
                                            (cffi:mem-ref vsp :size))
                                  as))
          (kyoto-cabinet-ffi:kcfree kp))))))

(defmethod cursor-get ((c kyoto-cursor) &key (as :octets))
  (check-as as)
  (%record (lambda (ksp vbp vsp)
             (kyoto-cabinet-ffi:kccurget (%cur c) ksp vbp vsp nil))
           as))

(defmethod cursor-seize ((c kyoto-cursor) &key (as :octets))
  (check-as as)
  (%record (lambda (ksp vbp vsp)
             (%kccurseize (%cur c) ksp vbp vsp))
           as))

(defmethod cursor-set-value ((c kyoto-cursor) value)
  (let ((v (to-octets value)))
    (with-octets (vp v)
      (%kccursetvalue (%cur c) vp (length v) 0))))

(defmethod cursor-remove ((c kyoto-cursor))
  (kyoto-cabinet-ffi:kccurremove (%cur c)))
```

In `vivace-cabinet.asd`, in `vivace-cabinet/kyoto`, replace
`:components ((:file "package")))` with

```lisp
  :components ((:file "package")
               (:file "ffi")
               (:file "db")
               (:file "cursor")))
```

- [ ] **Step 5: Run the suites**

Run: `VC-SUITE`, then `VC-CONFORM`
Expected: both exit 0 with no failures; `grep -a -i undefined` on each log
finds nothing.

- [ ] **Step 6: Mutation checks**

1. In `kyoto/db.lisp`, replace

   ```lisp
         (and (/= n (- (expt 2 63))) n))))
   ```

   with

   ```lisp
         n)))
   ```

   run `VC-CONFORM-TEST adapter-reports-kyotos-reasons`; confirm it fails as
   a test failure; restore the file.
2. In `api.lisp`, replace

   ```lisp
        (unwind-protect (progn ,@body)
          (%release-cursor ,var))))
   ```

   with

   ```lisp
        (progn ,@body)))
   ```

   run `VC-CONFORM-TEST adapter-releases-cursors`; confirm it fails as a
   test failure; restore the file.
3. In `kyoto/db.lisp`, replace

   ```lisp
   (6 :duplicate-record)
   ```

   with

   ```lisp
   (6 :duplicate)
   ```

   run `VC-CONFORM-TEST adapter-reports-kyotos-reasons`; confirm it fails as
   a test failure; restore the file.

- [ ] **Step 7: Document the adapter in `README.md`**

Before `## Limits`, add:

```markdown
## Kyoto Cabinet behind the same API

The `vivace-cabinet/kyoto` system opens a Kyoto Cabinet database and
answers vivace-cabinet's generic functions for it. It goes through
[cl-kyoto-cabinet](https://github.com/kraison/cl-kyoto-cabinet), which
needs Kyoto Cabinet 1.2.80's library:

    (let ((db (vivace-cabinet-kyoto:open-kyoto-db "/var/data/words.kct")))
      (vivace-cabinet:db-set db "apple" "red")
      (vivace-cabinet:close-db db))

The file's extension picks the type (`.kch` HashDB, `.kct` TreeDB).
`:mode` takes vivace-cabinet's modes, and `:tuning` Kyoto's tuning
parameters, as in `'(:bnum 2000000)`. It covers the record operations,
increments, compare-and-swap, bulk operations, matching, `db-count`,
`db-size`, `db-clear` and cursors, with Kyoto's reasons from `db-error`.
Kyoto's match calls pass keys as C strings, so a key holding a zero byte
does not match. The conformance check and the benchmark use it.
```

- [ ] **Step 8: Commit**

```bash
git add api.lisp \
  kyoto/package.lisp \
  kyoto/ffi.lisp \
  kyoto/db.lisp \
  kyoto/cursor.lisp \
  conformance/package.lisp \
  conformance/support.lisp \
  conformance/adapter-tests.lisp \
  vivace-cabinet.asd \
  README.md
git commit -m "Kyoto Cabinet behind vivace-cabinet's API

The vivace-cabinet/kyoto system: a KYOTO-DB answering the generic
functions through cl-kyoto-cabinet and Kyoto's C API. WITH-CURSOR now
releases its cursor, which Kyoto's need. Part of #3.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 2: Cursors behave as Kyoto's

**Files:**
- Modify: `database.lisp` (a count of clears), `api.lisp` (two cursor
  generics), `visitors.lisp` (`%cursor-edit`, `cursor-accept`),
  `tree-cursor.lisp`, `hash-cursor.lisp`, `tests/cursor-tests.lisp`,
  `tests/visitor-tests.lisp`, `tests/concurrency-tests.lisp`, `README.md`

**Interfaces:**
- Consumes: `db-accept`, the engines' `engine-ceiling` and
  `engine-floor`, the HashDB cursor's `%hc-advance` and
  `%with-hash-cursor`.
- Produces: `(%db-clears db)`, raised by `db-clear`; generics
  `(%cursor-current cursor)` → `(values key value)` as octets or NIL,
  and `(%cursor-pass cursor key)`; `(%cursor-edit cursor visit &key
  (writable t))` → `(values key value)` of the record visited, or NIL
  with the reason. Cursor behaviour: reads, edits and steps act on the
  first record at or after the cursor's key; removing moves on in the
  direction last moved; `db-clear` leaves cursors on no record.

The model, from `kcplantdb.h` and checked through Task 1's adapter on
both Kyoto types: `jump-back k3`, then removing k3 elsewhere, reads k4;
a removal after `jump-back` lands on the previous record; after another
call removes k1, `cursor-set-value` sets k2; after another call removes
k3, `cursor-step` lands on k5; after `db-clear`, reads and steps fail
with `:no-record` until the cursor jumps.

- [ ] **Step 1: Write the failing tests**

In `tests/cursor-tests.lisp`, replace the whole `cursor-edits-records`
test

```lisp
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
```

with

```lisp
(def-tree-test cursor-edits-records
  "SET-VALUE, REMOVE and SEIZE act on the current record; REMOVE and
SEIZE move to the next, or after a backward move to the previous, as
Kyoto's do."
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
      (is (equal (keyed 8) (cursor-get-key cur :as :string)))
      (is (= 7 (db-count db)))
      (cursor-jump cur (keyed 8))
      (is-true (cursor-remove cur))
      (is (null (cursor-get-key cur)))
      (is (= 6 (db-count db))))))
```

and the whole `cursor-follows-removal-backward` test

```lisp
(def-tree-test cursor-follows-removal-backward
  "Moving backward, a cursor whose record is removed reads the previous
one, not the next."
  (with-temp-db (db)
    (dotimes (i 5)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump-back cur (keyed 3))
      (db-remove db (keyed 3))
      (is (equal (keyed 2) (cursor-get-key cur :as :string)))
      (is-true (cursor-step-back cur))
      (is (equal (keyed 1) (cursor-get-key cur :as :string)))
      (db-remove db (keyed 1))
      (is (equal (keyed 0) (cursor-get-key cur :as :string))))))
```

with

```lisp
(def-tree-test cursor-follows-removal-backward
  "Moving backward too, a cursor whose record is removed reads the next
one, as Kyoto's does; stepping back then goes below it."
  (with-temp-db (db)
    (dotimes (i 5)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump-back cur (keyed 3))
      (db-remove db (keyed 3))
      (is (equal (keyed 4) (cursor-get-key cur :as :string)))
      (is-true (cursor-step-back cur))
      (is (equal (keyed 2) (cursor-get-key cur :as :string))))))
```

Append to `tests/cursor-tests.lisp`:

```lisp
(def-tree-test cursor-moves-on-from-removed-records
  "After another call removes the current record, the cursor's edits
and steps act on the next record, as Kyoto's do."
  (with-temp-db (db)
    (dotimes (i 6)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur (keyed 1))
      (db-remove db (keyed 1))
      (is-true (cursor-set-value cur "x"))
      (is (equal "x" (db-get db (keyed 2) :as :string)))
      (cursor-jump cur (keyed 3))
      (db-remove db (keyed 3))
      (is-true (cursor-step cur))
      (is (equal (keyed 5) (cursor-get-key cur :as :string))))))
```

Append to `tests/visitor-tests.lisp`:

```lisp
(def-db-test cursor-edits-reach-a-record-after-removal
  "An edit through a cursor whose record another call removed acts on a
record that is still there."
  (with-temp-db (db)
    (dotimes (i 6)
      (db-set db (keyed i) "v"))
    (with-cursor (cur db)
      (cursor-jump cur (keyed 1))
      (db-remove db (keyed 1))
      (is-true (cursor-set-value cur "x"))
      (is (= 1 (count "x" (loop for i below 6
                                collect (db-get db (keyed i) :as :string))
                      :test #'equal)))
      (is-true (cursor-remove cur))
      (is (= 4 (db-count db))))))

(def-db-test cursor-accept-never-visits-a-removed-record
  "While another thread sets and removes the same keys, CURSOR-ACCEPT
never calls its visitor with NIL: an answer for a removed record would
recreate it."
  (with-temp-db (db)
    (let ((stop nil)
          (nils 0)
          (errors '()))
      (let ((churn (bt:make-thread
                    (lambda ()
                      (handler-case
                          (loop for i from 0
                                until stop
                                do (let ((k (keyed (mod i 8))))
                                     (if (evenp (floor i 8))
                                         (db-set db k "v")
                                         (db-remove db k))))
                        (error (c)
                          (push (princ-to-string c) errors)))))))
        (unwind-protect
             (with-cursor (cur db)
               (dotimes (i 20000)
                 (when (cursor-jump cur (keyed (mod i 8)))
                   (cursor-accept cur (lambda (k v)
                                        (declare (ignore k))
                                        (unless v
                                          (incf nils))
                                        :nop)))))
          (setf stop t)
          (bt:join-thread churn))
        (is (null errors) "~s" errors)
        (is (zerop nils) "~d visits of NIL" nils)))))

(def-db-test cursor-is-nowhere-after-clear
  "DB-CLEAR leaves every cursor on no record, as in Kyoto, until it
jumps again."
  (with-temp-db (db)
    (db-set db (keyed 0) "v")
    (with-cursor (cur db)
      (cursor-jump cur)
      (db-clear db)
      (db-set db (keyed 0) "w")
      (is (null (cursor-get-key cur)))
      (is (eq :no-record (db-error db)))
      (is (null (cursor-step cur)))
      (is-true (cursor-jump cur))
      (is (equal "w" (cursor-get-value cur :as :string))))))
```

In `tests/concurrency-tests.lisp`, replace

```lisp
(defun stress-walk-ok-p (db forward)
  "Walk DB one way; true when the keys come strictly in order."
```

with

```lisp
(defun stress-walk-ok-p (db forward)
  "Walk DB one way; true when a forward walk's keys come strictly in
order.  A backward walk's need not: as in Kyoto, a cursor whose record
another thread removes reads the next one."
```

and

```lisp
            (when (and k prev
                       (if forward (string<= k prev) (string<= prev k)))
              (setf ok nil))
```

with

```lisp
            (when (and k prev forward (string<= k prev))
              (setf ok nil))
```

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; 15 tests fail:
`cursor-edits-reach-a-record-after-removal`,
`cursor-accept-never-visits-a-removed-record` and
`cursor-is-nowhere-after-clear` on each kind, and `cursor-edits-records`,
`cursor-follows-removal-backward` and `cursor-moves-on-from-removed-records`
on the two tree kinds; everything else passes.

- [ ] **Step 3: Count clears**

In `database.lisp`, after the slot
`(open-p :initform nil :accessor %db-open-p)`, add

```lisp
   (clears :initform 0 :accessor %db-clears)
```

and in `db-clear`, replace

```lisp
        (%write-header db :open t)
        t)
```

with

```lisp
        (%write-header db :open t)
        ;; Cursors positioned before a clear are invalid, as in Kyoto.
        (incf (%db-clears db))
        t)
```

- [ ] **Step 4: The shared cursor edit**

In `api.lisp`, after `(defgeneric %cursor-db (cursor))`, add:

```lisp
(defgeneric %cursor-current (cursor)
  (:documentation "Move CURSOR past removed records to its current one:
(values key value) as octets, or NIL when it is on none."))

(defgeneric %cursor-pass (cursor key)
  (:documentation "Move CURSOR on from KEY, its record just removed, as
Kyoto's cursors move after a removal."))
```

In `visitors.lisp`, replace the whole `cursor-accept` method

```lisp
(defmethod cursor-accept (cursor visitor &key (writable t) step
                                              (as :octets))
  (let ((k (cursor-get-key cursor)))
    (and k
         (db-accept (%cursor-db cursor) k visitor :writable writable :as as)
         (progn (when step
                  (cursor-step cursor))
                t))))
```

with

```lisp
(defun %cursor-edit (c visit &key (writable t))
  "Visit C's current record with VISIT, a function of its key and value
as octets that answers as a visitor does; retried if another thread
removes the record first.  The record's (values key value), or NIL with
the reason."
  (let ((db (%cursor-db c)))
    (loop
      (let ((k (%cursor-current c))
            (old nil))
        (unless k
          (return (%fail db :no-record)))
        (unless (db-accept db k (lambda (key v)
                                  (if (setf old v)
                                      (funcall visit key v)
                                      :nop))
                           :writable writable)
          (return nil))
        (when old
          (return (values k old)))))))

(defmethod cursor-accept (cursor visitor &key (writable t) step
                                              (as :octets))
  (check-as as)
  (let ((removed nil))
    (and (%cursor-edit cursor
                       (lambda (k v)
                         (let ((answer (funcall visitor (from-octets k as)
                                                (from-octets v as))))
                           (when (eq answer :remove)
                             (setf removed k))
                           answer))
                       :writable writable)
         (progn (cond (removed (%cursor-pass cursor removed))
                      (step (cursor-step cursor)))
                t))))
```

- [ ] **Step 5: The TreeDB cursor**

In `tree-cursor.lisp`, replace everything before
`(defmethod %cursor-db ((c tree-cursor))` with:

```lisp
;;;; TreeDB's cursor, as Kyoto's tree cursor behaves (kcplantdb.h): its
;;;; position is a key.  Each read, edit or step first moves it to the
;;;; first record at or after that key; removing a record moves it on in
;;;; the direction it last moved; DB-CLEAR leaves it nowhere.

(in-package #:vivace-cabinet)

(defclass tree-cursor ()
  ((db :initarg :db :reader %tc-db)
   (key :initform nil :accessor %tc-key)
   (backward :initform nil :accessor %tc-backward)
   (clears :initform 0 :accessor %tc-clears)))

(defmethod db-cursor ((db tree-db))
  (make-instance 'tree-cursor :db db))

(defun %tc-find (c fn key strict)
  "(FN engine KEY STRICT) in C's database: (values key value), or NIL."
  (let ((db (%tc-db c)))
    (with-read-lock ((%db-lock db))
      (%check-open db)
      (funcall fn (tree-db-engine db) key strict))))

(defun %tc-place (c key backward)
  "Put C at KEY, NIL for nowhere; T, or NIL with :NO-RECORD."
  (setf (%tc-key c) key
        (%tc-backward c) backward
        (%tc-clears c) (%db-clears (%tc-db c)))
  (or (and key t)
      (%fail (%tc-db c) :no-record)))

(defmethod %cursor-current ((c tree-cursor))
  (when (/= (%tc-clears c) (%db-clears (%tc-db c)))
    (setf (%tc-key c) nil))
  (when (%tc-key c)
    (multiple-value-bind (k v) (%tc-find c #'engine-ceiling (%tc-key c) nil)
      (setf (%tc-key c) k)
      (and k (values k v)))))

(defmethod %cursor-pass ((c tree-cursor) key)
  (%tc-place c (%tc-find c (if (%tc-backward c)
                               #'engine-floor
                               #'engine-ceiling)
                         key t)
             (%tc-backward c)))

(defmethod cursor-jump ((c tree-cursor) &optional key)
  (%tc-place c (%tc-find c #'engine-ceiling (and key (to-octets key)) nil)
             nil))

(defmethod cursor-jump-back ((c tree-cursor) &optional key)
  (%tc-place c (%tc-find c #'engine-floor (and key (to-octets key)) nil)
             t))

(defmethod cursor-step ((c tree-cursor))
  (let ((k (%cursor-current c)))
    (if k
        (%tc-place c (%tc-find c #'engine-ceiling k t) nil)
        (%fail (%tc-db c) :no-record))))

(defmethod cursor-step-back ((c tree-cursor))
  (if (and (%tc-key c) (= (%tc-clears c) (%db-clears (%tc-db c))))
      (%tc-place c (%tc-find c #'engine-floor (%tc-key c) t) t)
      (%fail (%tc-db c) :no-record)))

(defmethod cursor-get ((c tree-cursor) &key (as :octets))
  (check-as as)
  (multiple-value-bind (k v) (%cursor-current c)
    (if k
        (values (from-octets k as) (from-octets v as))
        (%fail (%tc-db c) :no-record))))

(defmethod cursor-set-value ((c tree-cursor) value)
  (let ((v (to-octets value)))
    (and (%cursor-edit c (lambda (k old)
                           (declare (ignore k old))
                           v))
         t)))

(defmethod cursor-remove ((c tree-cursor))
  (let ((k (%cursor-edit c (constantly :remove))))
    (and k (progn (%cursor-pass c k) t))))

(defmethod cursor-seize ((c tree-cursor) &key (as :octets))
  (check-as as)
  (multiple-value-bind (k v) (%cursor-edit c (constantly :remove))
    (when k
      (%cursor-pass c k)
      (values (from-octets k as) (from-octets v as)))))
```

- [ ] **Step 6: The HashDB cursor**

In `hash-cursor.lisp`, replace the slot
`(key :initform nil :accessor %hc-key)))` with

```lisp
   (key :initform nil :accessor %hc-key)
   (clears :initform 0 :accessor %hc-clears)))
```

In `cursor-jump`, after `(%with-hash-cursor (db c)`, add the line

```lisp
    (setf (%hc-clears c) (%db-clears db))
```

and replace everything from `(defmethod cursor-step ((c hash-cursor))` up
to, not including, `(defmethod cursor-jump-back ((c hash-cursor)` with:

```lisp
(defmethod %cursor-current ((c hash-cursor))
  (%with-hash-cursor (db c)
    (when (/= (%hc-clears c) (%db-clears db))
      (setf (%hc-key c) nil))
    (loop
      (let ((k (%hc-key c)))
        (unless k
          (return nil))
        (let* ((d (%digest k))
               (v (with-read-lock ((%stripe db d))
                    (let ((addr (%find db d k)))
                      (and addr (record-value (%db-heap db) addr))))))
          (when v
            (return (values k v)))
          (%hc-advance c))))))

(defmethod %cursor-pass ((c hash-cursor) key)
  (declare (ignore key))
  (%with-hash-cursor (db c)
    (%hc-advance c)))

(defmethod cursor-step ((c hash-cursor))
  (if (and (%cursor-current c)
           (%with-hash-cursor (db c)
             (%hc-advance c)))
      t
      (%fail (%hc-db c) :no-record)))

(defmethod cursor-get ((c hash-cursor) &key (as :octets))
  (check-as as)
  (multiple-value-bind (k v) (%cursor-current c)
    (if k
        (values (from-octets k as) (from-octets v as))
        (%fail (%hc-db c) :no-record))))

(defmethod cursor-set-value ((c hash-cursor) value)
  (let ((v (to-octets value)))
    (and (%cursor-edit c (lambda (k old)
                           (declare (ignore k old))
                           v))
         t)))

(defmethod cursor-remove ((c hash-cursor))
  (let ((k (%cursor-edit c (constantly :remove))))
    (and k (progn (%cursor-pass c k) t))))

(defmethod cursor-seize ((c hash-cursor) &key (as :octets))
  (check-as as)
  (multiple-value-bind (k v) (%cursor-edit c (constantly :remove))
    (when k
      (%cursor-pass c k)
      (values (from-octets k as) (from-octets v as)))))
```

- [ ] **Step 7: Run the suites**

Run: `VC-SUITE`, then `VC-CONFORM`
Expected: both exit 0 (core: 12,877 checks) with no failures;
`grep -a -i undefined` on each log finds nothing.

- [ ] **Step 8: Mutation checks**

1. In `tree-cursor.lisp`, replace

   ```lisp
     (%tc-place c (%tc-find c (if (%tc-backward c)
                                  #'engine-floor
                                  #'engine-ceiling)
                            key t)
   ```

   with

   ```lisp
     (%tc-place c (%tc-find c #'engine-ceiling
                            key t)
   ```

   run `VC-TEST cursor-edits-records/bplus-tree`; confirm it fails as a test
   failure; restore the file.
2. In `tree-cursor.lisp`, replace

   ```lisp
     (when (/= (%tc-clears c) (%db-clears (%tc-db c)))
       (setf (%tc-key c) nil))
     (when (%tc-key c)
   ```

   with

   ```lisp
     (when (%tc-key c)
   ```

   run `VC-TEST cursor-is-nowhere-after-clear/skip-list`; confirm it fails
   as a test failure; restore the file.
3. In `hash-cursor.lisp`, replace

   ```lisp
       (when (/= (%hc-clears c) (%db-clears db))
         (setf (%hc-key c) nil))
   ```

   with

   (nothing: delete those lines)

   run `VC-TEST cursor-is-nowhere-after-clear/hash`; confirm it fails as a
   test failure; restore the file.
4. In `visitors.lisp`, replace

   ```lisp
                                     (if (setf old v)
                                         (funcall visit key v)
                                         :nop))
   ```

   with

   ```lisp
                                     (progn (setf old (or v (make-array 0 :element-type '(unsigned-byte 8))))
                                            (funcall visit key v)))
   ```

   run `VC-TEST cursor-accept-never-visits-a-removed-record/hash`; confirm
   it fails as a test failure; restore the file.
5. In `tree-cursor.lisp`, replace

   ```lisp
   (defmethod cursor-step ((c tree-cursor))
     (let ((k (%cursor-current c)))
   ```

   with

   ```lisp
   (defmethod cursor-step ((c tree-cursor))
     (let ((k (%tc-key c)))
   ```

   run `VC-TEST cursor-moves-on-from-removed-records/bplus-tree`; confirm it
   fails as a test failure; restore the file.

- [ ] **Step 9: Document it in `README.md`**

In the Cursors section, replace

```markdown
and `cursor-remove` and `cursor-seize` remove the record and move to the
next. A move past either end returns NIL with `:no-record`. A TreeDB
cursor holds its position as a key, so other threads' changes leave it
valid; if its record is removed, it reads the next one. Give each thread
its own cursor.
```

with

```markdown
and `cursor-remove` and `cursor-seize` remove the record and move to the
next (after a backward move, to the previous). A move past either end
returns NIL with `:no-record`. Cursors behave as Kyoto Cabinet's do. If
another call removes a cursor's record, the cursor's next read, edit or
step acts on the record after it, whichever way the cursor last moved,
so a backward walk can read a record twice while other threads remove
records. `db-clear` leaves every cursor on no record until it jumps
again. A TreeDB cursor holds its position as a key, so other threads'
changes leave it valid. Give each thread its own cursor; `with-cursor`
releases its cursor when its body exits.
```

- [ ] **Step 10: Commit**

```bash
git add database.lisp \
  api.lisp \
  visitors.lisp \
  tree-cursor.lisp \
  hash-cursor.lisp \
  tests/cursor-tests.lisp \
  tests/visitor-tests.lisp \
  tests/concurrency-tests.lisp \
  README.md
git commit -m "Cursors behave as Kyoto Cabinet's

Reads, edits and steps act on the first record at or after the cursor's
key; a removal moves on in the direction last moved; DB-CLEAR leaves
cursors on no record. Found by the conformance check against Kyoto.
Part of #3.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 3: The conformance runner

**Files:**
- Create: `conformance/ops.lisp`, `conformance/run.lisp`,
  `conformance/tests.lisp`, `docs/conformance.md`
- Modify: `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: Task 1's adapter, `fresh-directory`, `with-kyoto` and
  `conformance-suite`; Task 2's cursor behaviour.
- Produces (in `vivace-cabinet-conformance`): `*kinds*`; `(random-op
  tree)` → `(name . args)`; `(perform db op cursor tree)` → `(:value r)`,
  `(:fails reason)` or `(:signals class)`; `(run-sequence kind seed
  steps dir)` → NIL or the first difference as a plist;
  `(check-conformance &key kinds seeds steps from)` → the differences;
  `(replay kind seed steps &key show)`.

- [ ] **Step 1: Write the failing tests**

Create `conformance/tests.lisp`:

```lisp
(in-package #:vivace-cabinet-conformance)

(fiveam:in-suite conformance-suite)

(defmacro def-conformance-test (kind)
  `(fiveam:test ,(alexandria:symbolicate "CONFORMS/" kind)
     ,(format nil "Random sequences agree with Kyoto on ~(~a~)." kind)
     (let ((diffs (check-conformance :kinds '(,kind) :seeds 20 :steps 1000)))
       (fiveam:is (null diffs) "~{~s~%~}" diffs))))

(def-conformance-test :hash)
(def-conformance-test :bplus-tree)
(def-conformance-test :skip-list)
```

In `vivace-cabinet.asd`, in `vivace-cabinet/conformance`, replace
`(:file "adapter-tests"))` with

```lisp
               (:file "adapter-tests")
               (:file "tests"))
```

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-CONFORM`
Expected: non-zero exit; `conforms/hash`, `conforms/bplus-tree` and
`conforms/skip-list` fail with `UNDEFINED-FUNCTION` `CHECK-CONFORMANCE`; the
adapter tests pass.

- [ ] **Step 3: Write the runner**

Create `conformance/ops.lisp`:

```lisp
;;;; Random operations.  A small key space makes operations collide: keys
;;;; share prefixes and lie a few edits apart, and values come from a
;;;; small pool, so adds clash, swaps succeed and matches find something.

(in-package #:vivace-cabinet-conformance)

(defparameter *keys*
  (let ((ks '()))
    (dolist (a '("a" "b" "c"))
      (push a ks)
      (dolist (b '("a" "b" "c"))
        (push (concatenate 'string a b) ks)
        (dolist (c '("a" "b"))
          (push (concatenate 'string a b c) ks))))
    (nreverse ks)))

(defparameter *values* '("" "x" "y" "z" "xy" "yz" "xyz"))

(defparameter *integer-keys* '("n0" "n1" "n2"))

(defparameter *double-keys* '("d0" "d1" "d2"))

(defparameter *int64-min* (- (expt 2 63)))

(defparameter *int64-max* (1- (expt 2 63)))

(defun pick (list)
  (nth (random (length list)) list))

(defun maybe (x)
  (and (plusp (random 3)) x))

(defun some-keys ()
  (loop repeat (1+ (random 4)) collect (pick *keys*)))

(defun random-op (tree)
  "A random operation, (NAME . ARGS).  Cursor moves held across steps
only on a TreeDB: a HashDB's order is its own in each library."
  (let ((k (pick *keys*))
        (v (pick *values*)))
    (case (random (if tree 32 26))
      ((0 1 2) `(:set ,k ,v))
      (3 `(:add ,k ,v))
      (4 `(:replace ,k ,v))
      (5 `(:append ,k ,v))
      ((6 7) `(:get ,k))
      (8 `(:check ,k))
      (9 `(:seize ,k))
      ((10 11) `(:remove ,k))
      ((12 13) `(:cas ,k ,(maybe (pick *values*)) ,(maybe v)))
      ((14 15) `(:increment ,(pick (cons k *integer-keys*))
                            ,(- (random 7) 3)
                            ,(pick (list 0 0 10 *int64-max* *int64-min*))))
      ((16 17) `(:increment-double
                 ,(pick (cons k *double-keys*))
                 ,(pick '(0d0 0.5d0 -1.25d0 0.3d0 0.1d0 2d0))
                 ,(pick (list 0d0 0d0 1.5d0
                              sb-ext:double-float-positive-infinity
                              sb-ext:double-float-negative-infinity))))
      (18 (if (zerop (random 8)) '(:clear) '(:count)))
      (19 `(:set-bulk ,(loop repeat (1+ (random 4))
                             collect (cons (pick *keys*) (pick *values*)))
                      ,(zerop (random 2))))
      (20 `(:get-bulk ,(some-keys) ,(zerop (random 2))))
      (21 `(:remove-bulk ,(some-keys) ,(zerop (random 2))))
      ;; On a HashDB, which keys a :MAX keeps depends on its order.
      (22 `(:match-prefix ,(pick '("" "a" "ab" "b" "abc" "zz"))
                          ,(and tree (pick '(nil nil 1 2)))))
      (23 `(:match-regex ,(pick '("^a" "b$" "a.c" "^(ab|ba)" "[bc]+" "x"))
                         ,(and tree (pick '(nil nil 1 2)))))
      (24 `(:match-similar ,k ,(random 3) ,(zerop (random 2))
                           ,(pick '(nil nil 1 2))))
      (25 (if (zerop (random 2)) '(:walk) `(:jump-get ,k)))
      (26 `(:cursor-jump ,(maybe k)))
      (27 `(:cursor-jump-back ,(maybe k)))
      ((28 29) '(:cursor-step))
      (30 '(:cursor-step-back))
      (t (pick `((:cursor-get) (:cursor-get) (:cursor-set-value ,v)
                 (:cursor-remove) (:cursor-seize)))))))
```

Create `conformance/run.lisp`:

```lisp
;;;; Running a sequence on both databases and comparing each step.

(in-package #:vivace-cabinet-conformance)

(defparameter *kinds*
  '((:hash (:type :hash) "k.kch")
    (:bplus-tree (:type :tree :engine :bplus-tree) "k.kct")
    (:skip-list (:type :tree :engine :skip-list) "k.kct"))
  "Each kind compared: a name, vivace-cabinet's OPEN-DB arguments, and
the Kyoto file, whose extension picks the same database type.")

(defun sorted-octets (list)
  (sort (copy-list list) #'octets<))

(defun walk-keys (db)
  (with-cursor (c db)
    (when (cursor-jump c)
      (loop for k = (cursor-get-key c)
            while k
            collect k
            while (cursor-step c)))))

(defun %perform (db op cursor tree)
  "Apply OP to DB, with CURSOR the sequence's cursor on DB; the result,
in an order both libraries share."
  (destructuring-bind (name &rest args) op
    (flet ((ordered (keys)
             (if tree keys (sorted-octets keys))))
      (ecase name
        (:set (apply #'db-set db args))
        (:add (apply #'db-add db args))
        (:replace (apply #'db-replace db args))
        (:append (apply #'db-append db args))
        (:get (db-get db (first args)))
        (:check (db-check db (first args)))
        (:seize (db-seize db (first args)))
        (:remove (db-remove db (first args)))
        (:cas (apply #'db-cas db args))
        (:increment (db-increment db (first args) (second args)
                                  :orig (third args)))
        (:increment-double (db-increment-double db (first args) (second args)
                                                :orig (third args)))
        (:count (db-count db))
        (:clear (db-clear db))
        (:set-bulk (db-set-bulk db (first args) :atomic (second args)))
        (:get-bulk (let ((r (db-get-bulk db (first args)
                                         :atomic (second args))))
                     ;; Kyoto returns them in key order.
                     (sort (copy-list r) #'octets< :key #'car)))
        (:remove-bulk (db-remove-bulk db (first args) :atomic (second args)))
        (:match-prefix (ordered (db-match-prefix db (first args)
                                                 :max (second args))))
        (:match-regex (ordered (db-match-regex db (first args)
                                               :max (second args))))
        (:match-similar (db-match-similar db (first args) (second args)
                                          :utf (third args)
                                          :max (fourth args)))
        (:walk (ordered (walk-keys db)))
        (:jump-get (with-cursor (c db)
                     (and (cursor-jump c (first args))
                          (multiple-value-list (cursor-get c)))))
        (:cursor-jump (cursor-jump cursor (first args)))
        (:cursor-jump-back (cursor-jump-back cursor (first args)))
        (:cursor-step (cursor-step cursor))
        (:cursor-step-back (cursor-step-back cursor))
        (:cursor-get (multiple-value-list (cursor-get cursor)))
        (:cursor-set-value (cursor-set-value cursor (first args)))
        (:cursor-remove (cursor-remove cursor))
        (:cursor-seize (multiple-value-list (cursor-seize cursor)))))))

(defparameter *list-ops* '(:get-bulk :match-prefix :match-regex
                           :match-similar :walk)
  "Operations whose result is a list, NIL when empty, not a failure.")

(defun perform (db op cursor tree)
  "OP's outcome on DB: (:VALUE result), (:FAILS reason) for a NIL
result, or (:SIGNALS condition-class)."
  (handler-case
      (let ((r (%perform db op cursor tree)))
        (if (and (or (null r) (equal r '(nil)))
                 (not (member (first op) *list-ops*)))
            (list :fails (db-error db))
            (list :value r)))
    (vivace-cabinet-error (c)
      (list :signals (type-of c)))))

(defun run-sequence (kind seed steps dir)
  "Run STEPS random operations from SEED on new databases of KIND (see
*KINDS*) in DIR, one vivace-cabinet's and one Kyoto's.  NIL when every
outcome agrees, else the first difference as a plist."
  (destructuring-bind (name args file) (assoc kind *kinds*)
    (declare (ignore name))
    (let* ((tree (eq :tree (getf args :type)))
           (*random-state* (sb-ext:seed-random-state seed))
           (v (apply #'open-db (merge-pathnames "v.vc/" dir) args))
           (k (open-kyoto-db (merge-pathnames file dir)
                             :mode '(:writer :create :truncate))))
      (unwind-protect
           (with-cursor (vc v)
             (with-cursor (kc k)
               (loop for step from 1 to steps
                     for op = (random-op tree)
                     for ov = (perform v op vc tree)
                     for ok = (perform k op kc tree)
                     unless (equalp ov ok)
                       return (list :kind kind :seed seed :step step :op op
                                    :vivace-cabinet ov :kyoto ok))))
        (close-db v)
        (close-db k)))))

(defun check-conformance (&key (kinds (mapcar #'first *kinds*)) (seeds 10)
                               (steps 2000) (from 1))
  "Run SEEDS sequences of STEPS operations, seeds FROM onwards, on each
of KINDS.  The differences found, the first of each sequence."
  (loop for kind in kinds
        nconc (loop for seed from from below (+ from seeds)
                    for d = (let ((dir (fresh-directory "vc-conformance")))
                              (unwind-protect
                                   (run-sequence kind seed steps dir)
                                (uiop:delete-directory-tree
                                 dir :validate t
                                     :if-does-not-exist :ignore)))
                    when d collect d)))

(defun replay (kind seed steps &key (show 12))
  "Rerun KIND's sequence from SEED for STEPS operations, printing the
last SHOW operations with both outcomes."
  (destructuring-bind (name args file) (assoc kind *kinds*)
    (declare (ignore name))
    (let* ((dir (fresh-directory "vc-replay"))
           (tree (eq :tree (getf args :type)))
           (*random-state* (sb-ext:seed-random-state seed))
           (v (apply #'open-db (merge-pathnames "v.vc/" dir) args))
           (k (open-kyoto-db (merge-pathnames file dir)
                             :mode '(:writer :create :truncate))))
      (unwind-protect
           (with-cursor (vc v)
             (with-cursor (kc k)
               (loop for step from 1 to steps
                     for op = (random-op tree)
                     for ov = (perform v op vc tree)
                     for ok = (perform k op kc tree)
                     when (> step (- steps show))
                       do (format t "~&~4d ~s~%     v ~s~%     k ~s~%"
                                  step op ov ok))))
        (close-db v)
        (close-db k)
        (uiop:delete-directory-tree dir :validate t)))))
```

In `vivace-cabinet.asd`, in `vivace-cabinet/conformance`, add
`(:file "ops")` and `(:file "run")` before `(:file "tests")`.

- [ ] **Step 4: Run the suites**

Run: `VC-SUITE`, then `VC-CONFORM`
Expected: both exit 0 (conformance: 19 checks) with no failures;
`grep -a -i undefined` on each log finds nothing.

Then run a longer check once, from the REPL with the system loaded:
`(vivace-cabinet-conformance:check-conformance :seeds 40 :steps 2000)`.
Expected: `NIL` (the dry run: 240,000 steps in about 30 seconds).

- [ ] **Step 5: Mutation checks**

1. In `conformance/run.lisp`, replace

   ```lisp
                (if tree keys (sorted-octets keys))))
   ```

   with

   ```lisp
                keys))
   ```

   run `VC-CONFORM-TEST conforms/hash`; confirm it fails as a test failure;
   restore the file.
2. In `conformance/run.lisp`, replace

   ```lisp
                    (not (member (first op) *list-ops*)))
   ```

   with

   ```lisp
                    t)
   ```

   run `VC-CONFORM-TEST conforms/bplus-tree`; confirm it fails as a test
   failure; restore the file.
3. In `tree-cursor.lisp`, replace

   ```lisp
     (%tc-place c (%tc-find c (if (%tc-backward c)
                                  #'engine-floor
                                  #'engine-ceiling)
                            key t)
   ```

   with

   ```lisp
     (%tc-place c (%tc-find c #'engine-ceiling
                            key t)
   ```

   run `VC-CONFORM-TEST conforms/skip-list`; confirm it fails as a test
   failure; restore the file.

- [ ] **Step 6: Document it**

Create `docs/conformance.md`:

```markdown
# The conformance check

`vivace-cabinet/conformance` (spec: unit 3) runs random sequences of
operations on a vivace-cabinet database and on a Kyoto Cabinet database
of the same type. It fails at the first step whose outcomes differ: the
result, the `db-error` reason of a failure, or the condition signalled.
Kyoto is reached through `vivace-cabinet/kyoto`, the adapter the
benchmark also uses.

## What it runs

- **Kinds.** HashDB against Kyoto's HashDB (`.kch`); TreeDB on the B+
  tree and on the skip list, each against Kyoto's TreeDB (`.kct`).
- **Keys and values.** 30 short keys over `a`, `b` and `c`, which share
  prefixes and lie a few edits apart, plus three keys for integer and
  three for double increments. Values come from a pool of seven short
  strings, so adds clash, swaps succeed and matches find something.
- **Operations.**
  - The single-record calls: set, add, replace, append, get, check,
    seize, remove.
  - Compare-and-swap, and both increments, with Kyoto's extreme `:orig`
    values.
  - `db-count`, `db-clear`, and bulk set, get and remove, atomic or not.
  - The three matches, a whole cursor walk, and a jump to a key followed
    by a read.
  - On a TreeDB, also a cursor held across steps: jumps and steps both
    ways, reads, value sets, removes and seizes.
- **Size.** The test suite runs 20 sequences of 1,000 operations on each
  kind. `(check-conformance :seeds 100 :steps 5000)` runs more and
  returns the differences; `(replay kind seed step)` prints the
  operations before one.

## What it leaves out, and why

- **HashDB order.** A HashDB's order is its own in each library, so its
  walks and matches are compared as sorted sets, and its cursors only by
  a jump and a read. `:max` is not tried on its prefix and regex
  matches. Kyoto returns bulk gets in key order, so both are compared
  in key order.
- **An increment landing exactly on the most negative 64-bit integer.**
  Kyoto reports that value as failure (#8). Small steps never reach it.
- **Regular expressions and key bytes.** The expressions used read alike
  in CL-PPCRE and in Kyoto's engine. Keys are ASCII: Kyoto's match calls
  take C strings, and its regular expressions read bytes where
  vivace-cabinet reads UTF-8.
- **Visitors, status, copy, merge and snapshots.** The adapter does not
  reach them, and snapshots differ in format by design.
- **Concurrency.** The check runs on one thread; the stress tests cover
  threads.

## What it found

Its first runs, in unit 3a's dry run, found TreeDB cursors that did not
behave as Kyoto's. After another call removed the current record, a
cursor's edits failed and its steps landed one record early. A removal
after a backward move went forward. `db-clear` left cursors in place.
HashDB agreed on every step. Unit 3a gave both cursor types Kyoto's
behaviour (`kcplantdb.h`, the `Cursor` class); then 240,000 steps on the
three kinds found no difference.
```

In `README.md`'s Testing section, replace

```markdown
The process exits non-zero if any test fails. One linear-hash test copies
a hash's two sparse 1000 MiB files without keeping them sparse, so the
temp directory needs about 2 GB free; where `/tmp` is a small tmpfs, run
with `TMPDIR=/var/tmp`.
```

with

```markdown
The process exits non-zero if any test fails. One linear-hash test copies
a hash's two sparse 1000 MiB files without keeping them sparse, so the
temp directory needs about 2 GB free; where `/tmp` is a small tmpfs, run
with `TMPDIR=/var/tmp`.

The conformance check runs random sequences of operations on
vivace-cabinet and on Kyoto Cabinet, and fails on any difference in a
result or a `db-error` reason; `docs/conformance.md` says what it
compares. It needs Kyoto Cabinet 1.2.80 and cl-kyoto-cabinet, here
checked out in `~/work/cl-kyoto-cabinet`:

    sbcl --non-interactive --load ~/quicklisp/setup.lisp \
      --eval '(push (truename "./") asdf:*central-registry*)' \
      --eval '(push (merge-pathnames "work/cl-kyoto-cabinet/"
                                     (user-homedir-pathname))
                    asdf:*central-registry*)' \
      --eval '(ql:quickload :vivace-cabinet/conformance)' \
      --eval '(asdf:test-system :vivace-cabinet/conformance)'
```

- [ ] **Step 7: Commit**

```bash
git add conformance/ops.lisp \
  conformance/run.lisp \
  conformance/tests.lisp \
  vivace-cabinet.asd \
  docs/conformance.md \
  README.md
git commit -m "The conformance check against Kyoto Cabinet

Random operation sequences on vivace-cabinet and Kyoto, compared step by
step on HashDB and both TreeDB engines. Part of #3.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

---

## Finish

- [ ] `VC-SUITE` and `VC-CONFORM` once more: both exit 0.
- [ ] On kraison/vivace-cabinet#3, comment `Ready for review:` with the
  branch and `git -C ~/work/vivace-cabinet diff main...unit-3a-kyoto-conformance`.
- [ ] On #7, note that cursor edits no longer use a stale key, and on #8
  that `cursor-accept` no longer visits NIL; both are on the branch.
- [ ] Stop: merge and push wait for Kevin's word.
