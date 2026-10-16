# Unit 2b: records and HashDB — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Kyoto-style hash database: `open-db`, `db-set`, `db-get`,
`db-add`, `db-replace`, `db-append`, `db-check`, `db-seize`, `db-remove`,
`db-count`, `db-size`, `db-path`, `db-clear`, `db-synchronize`, `db-error`,
`close-db` and `with-db`, on records in the heap indexed by the linear hash.

**Architecture:** A key's 128-bit MurmurHash3 digest is the linear hash's
16-byte key; its 8-byte value is the heap address of the first record in a
chain of records whose keys share that digest. Records are
`[next][key length][value length][key][value]`. Per-key operations hold one
of 1024 read-write locks chosen by digest, under a database-wide read-write
lock that clear, close and synchronize take exclusively. Logical failures
return NIL and record a reason per thread, as Kyoto does.

**Tech Stack:** SBCL, FiveAM, babel (UTF-8), uiop (paths), the unit 2a
substrate and structures.

**Spec:** `docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`,
sections "Storage" (HashDB, Durability) and "API". Phase split on
kraison/vivace-cabinet#2.

## Global Constraints

- SBCL only. New Lisp: spaces only, 80 columns, terse comments.
- Copied code (one form, Task 2) via `tools/extract-forms.py` from
  vivace-graph `853df62`; vivace-graph is never modified.
- Keys and values are `(simple-array (unsigned-byte 8) (*))`; strings are
  accepted and stored as UTF-8.
- Logical failures return NIL and set the reason `db-error` reports; real
  errors signal conditions (`invalid-argument`, `open-error`,
  `not-implemented`).
- Branch `unit-2b-hashdb` in `~/work/vivace-cabinet`; one commit per task;
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
`--eval '(fiveam:run! (quote vivace-cabinet-test::<name>))'`.

Mutation checks: copy the file aside (`cp F /var/tmp/vc-tests/F.keep`),
replace a function body in place (never append a second definition: that
is a full compiler WARNING and the build stops), run, restore. Logs can
contain NUL bytes: `grep -a`.

## Review Focus

1. **Keys whose digests collide.** Chains must work at their head, middle
   and tail, for every operation (Task 3, `collisions-chain-correctly`,
   using the `*key-digest*` test hook).
2. **One key written from several threads at once.** Exactly one `db-add`
   wins; no record is lost or duplicated (Task 3,
   `concurrent-writers-are-consistent`).
3. **Reopening.** Count and contents survive close and reopen, and a
   `db-synchronize` without close (Task 3, `reopen-keeps-everything`;
   Task 4, `synchronize-persists-the-count`).
4. **Damaged or missing files** signal `open-error` instead of returning
   a broken handle (Task 3, `corrupt-header-signals`; Task 4,
   `corrupt-index-signals`, `opening-needs-create-or-a-database`).
5. **Values changing size**, empty keys and values, 1 MiB values, and
   paths without a trailing slash (Task 3, `values-change-size`,
   `empty-keys-and-values`, `large-values`; Task 4,
   `paths-become-directories`).

## Proposals in this plan for Kevin to approve

- **Record lengths are u64**, so the header is 24 bytes, not the spec's
  16 (u32 lengths): the heap API has u64 codecs only. Costs 8 bytes a
  record.
- **`db-check` returns the value's size, or NIL** when the key is absent
  (Kyoto returns -1).
- **`db-size` is bytes in use** (the heap's extent plus the index's buckets
  and overflow), not file sizes: the index files are sparse 1000 MiB files.
- **Locking:** 1024 striped read-write locks chosen by digest, under one
  database-wide read-write lock for clear, close and synchronize.
- **Heap address space:** `:heap-reservation` defaults to 64 GiB, so a
  database can grow past 1 GiB in one session (the 2a README limit).
- **Reader mode refuses writes** with NIL and `:no-permission` (Kyoto's
  NOPERM).
- **Writes allocate a new record and free the old one**; updating in place
  is a later optimization. Records are copied into the heap a byte at a
  time (vivace-graph's `set-bytes`); a bulk copy waits for the benchmarks.
- **No cursor in 2b:** the HashDB cursor moves to 2c with the ordered ones;
  visitors (`db-iterate` and so on) stay in 2d.
- **A failed open signals `open-error`; using a closed database signals
  `invalid-argument`.** To make that possible, the copied `open-lhash`
  changes: it signals after unmapping what it mapped, where vivace-graph's
  logs and returns a handle whose files are unmapped (Task 4).

---

### Task 1: The key digest

**Files:**
- Create: `murmur3.lisp`, `tests/murmur3-tests.lisp`
- Modify: `vivace-cabinet.asd`, `tests/support.lisp`

**Interfaces:**
- Produces: `(murmur3-128 octets &optional (seed 0))` → a 16-byte
  `(simple-array (unsigned-byte 8) (16))`, h1 then h2, each
  little-endian; type `octets` = `(simple-array (unsigned-byte 8) (*))`.
  Test helper `(octets-of &rest bytes)` → octets.

- [ ] **Step 1: Branch**

```bash
cd ~/work/vivace-cabinet && git switch -c unit-2b-hashdb
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/support.lisp`:

```lisp
(defun octets-of (&rest bytes)
  "BYTES as an octet vector."
  (make-array (length bytes) :element-type '(unsigned-byte 8)
                             :initial-contents bytes))
```

Create `tests/murmur3-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-suite murmur3-suite
  :description "MurmurHash3 x64 128 against SMHasher's check."
  :in vivace-cabinet-suite)

(in-suite murmur3-suite)

(test murmur3-empty-is-zero
  "The empty input with seed 0 hashes to sixteen zero bytes."
  (is (every #'zerop (murmur3-128 (octets-of) 0))))

(test murmur3-returns-16-octets
  (is (typep (murmur3-128 (octets-of 1 2 3))
             '(simple-array (unsigned-byte 8) (16)))))

(test murmur3-matches-smhasher-verification
  "SMHasher's verification value for MurmurHash3_x64_128, #x6384BA69:
hash the first I bytes of 0..255 with seed 256-I for every I, then hash
the concatenated results with seed 0; the value is the first 4 bytes."
  (let ((key (make-array 256 :element-type '(unsigned-byte 8)))
        (hashes (make-array (* 256 16) :element-type '(unsigned-byte 8))))
    (dotimes (i 256)
      (setf (aref key i) i))
    (dotimes (i 256)
      (replace hashes (murmur3-128 (subseq key 0 i) (- 256 i))
               :start1 (* 16 i)))
    (let ((final (murmur3-128 hashes 0)))
      (is (= #x6384BA69
             (logior (aref final 0) (ash (aref final 1) 8)
                     (ash (aref final 2) 16) (ash (aref final 3) 24)))))))
```

Add `(:file "murmur3-tests")` after `"bplus-tree-tests"` in the test
system's components.

- [ ] **Step 3: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 3 murmur3 tests fail with
`UNDEFINED-FUNCTION`; all 55 earlier tests pass.

- [ ] **Step 4: Write `murmur3.lisp`**

```lisp
;;;; MurmurHash3 x64 128, after Austin Appleby's public-domain reference
;;;; (SMHasher MurmurHash3.cpp): HashDB's key digest (spec: HashDB).

(in-package #:vivace-cabinet)

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(declaim (inline %u64+ %u64* %rotl64))
(defun %u64+ (a b) (ldb (byte 64 0) (+ a b)))
(defun %u64* (a b) (ldb (byte 64 0) (* a b)))
(defun %rotl64 (x r)
  (logior (ldb (byte 64 0) (ash x r)) (ash x (- r 64))))

(defun %fmix64 (k)
  (setf k (logxor k (ash k -33))
        k (%u64* k #xff51afd7ed558ccd)
        k (logxor k (ash k -33))
        k (%u64* k #xc4ceb9fe1a85ec53))
  (logxor k (ash k -33)))

(defun %le-u64 (octets start count)
  "COUNT (at most 8) bytes of OCTETS from START, little-endian."
  (let ((v 0))
    (dotimes (i count v)
      (setf v (logior v (ash (aref octets (+ start i)) (* 8 i)))))))

(defun murmur3-128 (octets &optional (seed 0))
  "MurmurHash3_x64_128 of OCTETS with SEED: 16 bytes, h1 then h2, each
little-endian, as the reference writes its output."
  (declare (type octets octets))
  (let* ((len (length octets))
         (nblocks (floor len 16))
         (h1 seed)
         (h2 seed)
         (c1 #x87c37b91114253d5)
         (c2 #x4cf5ad432745937f))
    (dotimes (i nblocks)
      (let ((k1 (%le-u64 octets (* 16 i) 8))
            (k2 (%le-u64 octets (+ 8 (* 16 i)) 8)))
        (setf k1 (%u64* (%rotl64 (%u64* k1 c1) 31) c2)
              h1 (logxor h1 k1)
              h1 (%u64+ (%u64* (%u64+ (%rotl64 h1 27) h2) 5) #x52dce729)
              k2 (%u64* (%rotl64 (%u64* k2 c2) 33) c1)
              h2 (logxor h2 k2)
              h2 (%u64+ (%u64* (%u64+ (%rotl64 h2 31) h1) 5)
                        #x38495ab5))))
    (let* ((tail (* 16 nblocks))
           (rest (- len tail)))
      (when (> rest 8)
        (let ((k2 (%le-u64 octets (+ tail 8) (- rest 8))))
          (setf h2 (logxor h2 (%u64* (%rotl64 (%u64* k2 c2) 33) c1)))))
      (when (> rest 0)
        (let ((k1 (%le-u64 octets tail (min rest 8))))
          (setf h1 (logxor h1 (%u64* (%rotl64 (%u64* k1 c1) 31) c2))))))
    (setf h1 (logxor h1 len)
          h2 (logxor h2 len)
          h1 (%u64+ h1 h2)
          h2 (%u64+ h2 h1)
          h1 (%fmix64 h1)
          h2 (%fmix64 h2)
          h1 (%u64+ h1 h2)
          h2 (%u64+ h2 h1))
    (let ((out (make-array 16 :element-type '(unsigned-byte 8))))
      (dotimes (i 8 out)
        (setf (aref out i) (ldb (byte 8 (* 8 i)) h1)
              (aref out (+ 8 i)) (ldb (byte 8 (* 8 i)) h2))))))
```

In `vivace-cabinet.asd`, add `"babel"` and `"uiop"` to the library's
`:depends-on`, and after the `"structures"` module add
`(:file "murmur3")`.

- [ ] **Step 5: Run the suite and watch it pass**

Run: `VC-SUITE`
Expected: exit 0; 58 tests pass. This code gave #x6384BA69 when the plan
was written, so a failure of the verification test means the
transcription differs from the plan's block: diff the two.

- [ ] **Step 6: Mutation check**

In `%fmix64`, change `-33` in its last line to `-32`; run
`VC-TEST murmur3-suite`; confirm the verification test fails; restore.

- [ ] **Step 7: Commit**

```bash
git add murmur3.lisp tests/murmur3-tests.lisp tests/support.lisp \
  vivace-cabinet.asd
git commit -m "MurmurHash3 x64 128 for HashDB key digests

Checked against SMHasher's verification value. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 2: Records in the heap

**Files:**
- Create (extracted): `substrate/heap-bytes.lisp`
- Create: `records.lisp`, `tests/record-tests.lisp`
- Modify: `vivace-cabinet.asd`, `docs/provenance.md`

**Interfaces:**
- Consumes: the heap API (`allocate`, `free`, `get-bytes`,
  `serialize-uint64`, `deserialize-uint64` on `memory`); Task 1's
  `octets-of` (tests).
- Produces: `+record-header-bytes+` (24); `(write-record heap key value
  next)` → address; `(record-next heap addr)` and `(setf (record-next heap
  addr) next)`; `(record-key heap addr)`, `(record-value heap addr)` →
  octets; `(record-value-length heap addr)`; `(record-key= heap addr key)`;
  `(free-record heap addr)`.

- [ ] **Step 1: Write `tests/record-tests.lisp`**

```lisp
(in-package #:vivace-cabinet-test)

(def-suite record-suite
  :description "Key/value records in the heap."
  :in vivace-cabinet-suite)

(in-suite record-suite)

(test record-round-trip
  (with-temp-memory (heap)
    (let* ((k (octets-of 1 2 3))
           (v (octets-of 9 8))
           (a (write-record heap k v 0)))
      (is (equalp k (record-key heap a)))
      (is (equalp v (record-value heap a)))
      (is (= 2 (record-value-length heap a)))
      (is (= 0 (record-next heap a)))
      (is-true (record-key= heap a k))
      (is (not (record-key= heap a (octets-of 1 2 4))))
      (is (not (record-key= heap a (octets-of 1 2)))))))

(test record-chain-links
  (with-temp-memory (heap)
    (let* ((a (write-record heap (octets-of 1) (octets-of 1) 0))
           (b (write-record heap (octets-of 2) (octets-of 2) a)))
      (is (= a (record-next heap b)))
      (setf (record-next heap b) 0)
      (is (= 0 (record-next heap b))))))

(test record-empty-key-and-value
  (with-temp-memory (heap)
    (let ((a (write-record heap (octets-of) (octets-of) 0)))
      (is (equalp (octets-of) (record-key heap a)))
      (is (equalp (octets-of) (record-value heap a))))))

(test record-large-value
  (with-temp-memory (heap)
    (let ((v (make-array 100000 :element-type '(unsigned-byte 8))))
      (dotimes (i (length v))
        (setf (aref v i) (mod (* 7 i) 256)))
      (let ((a (write-record heap (octets-of 5) v 0)))
        (is (equalp v (record-value heap a)))))))

(test freed-record-space-is-reused
  "A freed record's space goes to the next record of the same size."
  (with-temp-memory (heap)
    (let ((a (write-record heap (octets-of 1 2) (octets-of 3 4) 0)))
      (free-record heap a)
      (is (= a (write-record heap (octets-of 5 6) (octets-of 7 8) 0))))))
```

Add `(:file "record-tests")` after `"murmur3-tests"` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 5 record tests fail with
`UNDEFINED-FUNCTION`.

- [ ] **Step 3: Copy vivace-graph's `set-bytes` for the heap**

```bash
cd ~/work/vivace-cabinet
python3 tools/extract-forms.py $HOME/work/vivace-graph 853df62 \
  transactions.lisp --only 606 substrate/heap-bytes.lisp
```

Expected: `kept 606-...: (defmethod set-bytes ((memory memory) ...`. It
writes one byte at a time through the heap's `set-byte`. Add
`(:file "heap-bytes")` after `(:file "allocator")` in the substrate
module, and this row to the table in `docs/provenance.md`, after the
allocator row:

```markdown
| substrate/heap-bytes.lisp | transactions.lisp | `set-bytes` on `memory` |
```

- [ ] **Step 4: Write `records.lisp`**

```lisp
;;;; Key/value records in the heap: [next u64][key length u64][value
;;;; length u64][key][value].  NEXT chains records whose keys share a
;;;; digest (spec: HashDB).

(in-package #:vivace-cabinet)

(alexandria:define-constant +record-header-bytes+ 24)

(defun write-record (heap key value next)
  "Allocate a record holding KEY and VALUE (octets) linked to NEXT;
return its address."
  (let* ((klen (length key))
         (vlen (length value))
         (addr (allocate heap (+ +record-header-bytes+ klen vlen))))
    (serialize-uint64 heap next addr)
    (serialize-uint64 heap klen (+ addr 8))
    (serialize-uint64 heap vlen (+ addr 16))
    (set-bytes heap key (+ addr +record-header-bytes+) klen)
    (set-bytes heap value (+ addr +record-header-bytes+ klen) vlen)
    addr))

(defun record-next (heap addr)
  (deserialize-uint64 heap addr))

(defun (setf record-next) (next heap addr)
  (serialize-uint64 heap next addr)
  next)

(defun record-key-length (heap addr)
  (deserialize-uint64 heap (+ addr 8)))

(defun record-value-length (heap addr)
  (deserialize-uint64 heap (+ addr 16)))

(defun record-key (heap addr)
  (get-bytes heap (+ addr +record-header-bytes+)
             (record-key-length heap addr)))

(defun record-value (heap addr)
  (get-bytes heap
             (+ addr +record-header-bytes+ (record-key-length heap addr))
             (record-value-length heap addr)))

(defun record-key= (heap addr key)
  "True when the record at ADDR holds KEY."
  (and (= (length key) (record-key-length heap addr))
       (equalp key (record-key heap addr))))

(defun free-record (heap addr)
  (free heap addr))
```

Add `(:file "records")` after `(:file "murmur3")` in the library system.

- [ ] **Step 5: Run the suite and watch it pass**

Run: `VC-SUITE`
Expected: exit 0; 63 tests pass.

- [ ] **Step 6: Mutation check**

Make `record-key=`'s body just `t`; run `VC-TEST record-suite`; confirm
`record-round-trip` fails; restore.

- [ ] **Step 7: Commit**

```bash
git add substrate/heap-bytes.lisp records.lisp tests/record-tests.lisp \
  vivace-cabinet.asd docs/provenance.md
git commit -m "Key/value records in the heap

Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 3: HashDB per-key operations and the API

**Files:**
- Create: `api.lisp`, `hash-db.lisp`, `tests/hash-db-tests.lisp`
- Modify: `package.lisp` (exports), `vivace-cabinet.asd`,
  `tests/support.lisp`

**Interfaces:**
- Consumes: Task 1's `murmur3-128`, `octets`; Task 2's record functions;
  the linear hash (`make-lhash`, `open-lhash`, `close-lhash`, `lhash-get`
  → value or NIL, `lhash-insert`, `lhash-update`, `lhash-remove`); the
  heap (`create-memory`, `open-memory`, `close-memory`); `make-rw-lock`,
  `with-read-lock`, `with-write-lock`; bordeaux-threads' `make-lock`,
  `with-lock-held`, `current-thread`.
- Produces (exported): conditions `vivace-cabinet-error`,
  `not-implemented`, `invalid-argument`, `open-error`; `(open-db path
  &key type mode buckets max-locks heap-size heap-reservation)`,
  `(close-db db)` → T, or NIL if already closed; `(with-db (var path
  &rest open-args) &body)`; `(db-set db key value)`, `db-add`,
  `db-replace`, `db-append` → T or NIL; `(db-get db key &key (as
  :octets))` → octets, string or NIL; `(db-check db key)` → size or NIL;
  `(db-seize db key &key as)`; `(db-remove db key)` → T or NIL;
  `(db-count db)`; `(db-error db)` → `:success`, `:duplicate-record`,
  `:no-record` or `:no-permission`; generics `db-size`, `db-path`,
  `db-clear`, `db-synchronize` (methods in Task 4).
- Produces (internal, for Task 4): `*key-digest*`; class `hash-db` with
  readers `hash-db-dir`, `hash-db-writable-p`, `hash-db-tuning`, accessors
  `hash-db-heap`, `hash-db-index`, `hash-db-record-count`,
  `hash-db-open-p`, and `hash-db-lock`; `open-hash-db`; `%signal`,
  `%fail`, `%check-open`, `%read-header`, `%write-header`,
  `%create-storage`, `%open-storage`, `%header-file`, `%heap-file`,
  `%index-dir`. Test helper `with-temp-db`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/support.lisp`:

```lisp
(defmacro with-temp-db ((var &rest open-args) &body body)
  "Bind VAR to a new database in a temp directory; close it afterwards."
  (let ((dir (gensym "DIR")))
    `(with-temp-directory (,dir)
       (let ((,var (open-db (merge-pathnames "t.vch/" ,dir) ,@open-args)))
         (unwind-protect (progn ,@body)
           (ignore-errors (close-db ,var)))))))
```

Create `tests/hash-db-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-suite hash-db-suite
  :description "HashDB per-key operations."
  :in vivace-cabinet-suite)

(in-suite hash-db-suite)

(defun constant-digest (byte)
  "A digest function giving every key the same 16 bytes."
  (lambda (key)
    (declare (ignore key))
    (make-array 16 :element-type '(unsigned-byte 8) :initial-element byte)))

(test set-and-get
  (with-temp-db (db)
    (is-true (db-set db "k" "v"))
    (is (equal "v" (db-get db "k" :as :string)))
    (is (equalp (octets-of 118) (db-get db "k")))
    (is-true (db-set db (octets-of 1 2) (octets-of 3)))
    (is (equalp (octets-of 3) (db-get db (octets-of 1 2))))
    (is-true (db-set db "k" "w"))
    (is (equal "w" (db-get db "k" :as :string)))
    (is (= 2 (db-count db)))))

(test missing-keys-give-nil-and-no-record
  (with-temp-db (db)
    (is (null (db-get db "absent")))
    (is (eq :no-record (db-error db)))
    (is (null (db-check db "absent")))
    (is (null (db-remove db "absent")))
    (is (eq :no-record (db-error db)))))

(test add-replace-append
  (with-temp-db (db)
    (is-true (db-add db "a" "1"))
    (is (null (db-add db "a" "2")))
    (is (eq :duplicate-record (db-error db)))
    (is (equal "1" (db-get db "a" :as :string)))
    (is (null (db-replace db "b" "x")))
    (is (eq :no-record (db-error db)))
    (is-true (db-replace db "a" "3"))
    (is (equal "3" (db-get db "a" :as :string)))
    (is-true (db-append db "a" "4"))
    (is-true (db-append db "c" "5"))
    (is (equal "34" (db-get db "a" :as :string)))
    (is (equal "5" (db-get db "c" :as :string)))
    (is (= 2 (db-count db)))))

(test check-seize-remove
  (with-temp-db (db)
    (db-set db "k" "value")
    (is (= 5 (db-check db "k")))
    (is (equal "value" (db-seize db "k" :as :string)))
    (is (null (db-get db "k")))
    (is (= 0 (db-count db)))
    (db-set db "j" "x")
    (is-true (db-remove db "j"))
    (is (null (db-get db "j")))
    (is (= 0 (db-count db)))))

(test values-change-size
  "Replacing and appending with larger and smaller values."
  (with-temp-db (db)
    (db-set db "k" "x")
    (db-set db "k" (make-string 5000 :initial-element #\y))
    (is (= 5000 (db-check db "k")))
    (db-set db "k" "z")
    (is (equal "z" (db-get db "k" :as :string)))
    (dotimes (i 100)
      (db-append db "k" "ab"))
    (is (= 201 (db-check db "k")))))

(test empty-keys-and-values
  (with-temp-db (db)
    (is-true (db-set db "" "v"))
    (is-true (db-set db "e" ""))
    (is (equal "v" (db-get db "" :as :string)))
    (is (equal "" (db-get db "e" :as :string)))
    (is (= 0 (db-check db "e")))))

(test large-values
  (with-temp-db (db)
    (let ((v (make-array (expt 2 20) :element-type '(unsigned-byte 8))))
      (dotimes (i (length v))
        (setf (aref v i) (mod (* 13 i) 256)))
      (is-true (db-set db "big" v))
      (is (equalp v (db-get db "big"))))))

(test non-ascii-strings
  (with-temp-db (db)
    (db-set db "clé" "naïve 日本")
    (is (equal "naïve 日本" (db-get db "clé" :as :string)))))

(test collisions-chain-correctly
  "With every key given the same digest, one chain holds them all; each
operation works at the chain's head, middle and tail."
  (let ((*key-digest* (constant-digest 7)))
    (with-temp-db (db)
      (dolist (k '("a" "b" "c" "d" "e"))
        (db-set db k (string-upcase k)))
      (is (= 5 (db-count db)))
      (dolist (k '("a" "b" "c" "d" "e"))
        (is (equal (string-upcase k) (db-get db k :as :string))))
      (is-true (db-remove db "c"))
      (is-true (db-remove db "e"))
      (is-true (db-remove db "a"))
      (is (null (db-get db "c")))
      (is (equal "B" (db-get db "b" :as :string)))
      (is (equal "D" (db-get db "d" :as :string)))
      (is (null (db-add db "b" "x")))
      (is-true (db-replace db "d" "dd"))
      (is (equal "dd" (db-get db "d" :as :string)))
      (is (= 2 (db-count db))))))

(test all-zero-digest-is-remapped
  "The linear hash reserves the all-zero key; a zero digest still works."
  (let ((*key-digest* (constant-digest 0)))
    (with-temp-db (db)
      (is-true (db-set db "z" "v"))
      (is (equal "v" (db-get db "z" :as :string))))))

(test errors-are-per-thread
  (with-temp-db (db)
    (db-get db "absent")
    (let ((other nil))
      (bt:join-thread (bt:make-thread (lambda ()
                                        (setf other (db-error db)))))
      (is (eq :success other))
      (is (eq :no-record (db-error db))))))

(test bad-arguments-signal
  (with-temp-db (db)
    (signals invalid-argument (db-set db 42 "v"))
    (signals invalid-argument (db-get db "absent" :as :symbol))))

(test reopen-keeps-everything
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "r.vch/" dir)))
      (with-db (db path)
        (dotimes (i 1000)
          (db-set db (format nil "k~a" i) (format nil "v~a" i))))
      (with-db (db path)
        (is (= 1000 (db-count db)))
        (is (equal "v777" (db-get db "k777" :as :string)))
        (is-true (db-remove db "k1"))
        (is (= 999 (db-count db)))))))

(test corrupt-header-signals
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "c.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-open-file (out (merge-pathnames "header.dat" path)
                           :direction :output :if-exists :supersede
                           :element-type '(unsigned-byte 8))
        (write-sequence (make-array 32 :element-type '(unsigned-byte 8)
                                       :initial-element 9)
                        out))
      (signals open-error (open-db path)))))

(test closed-databases-refuse-use
  (with-temp-directory (dir)
    (let ((db (open-db (merge-pathnames "x.vch/" dir))))
      (is-true (close-db db))
      (is (null (close-db db)))
      (signals invalid-argument (db-get db "k"))
      (signals invalid-argument (db-set db "k" "v"))
      (signals invalid-argument (db-count db)))))

(test concurrent-writers-are-consistent
  "Four threads write their own keys and race to add one shared key:
every key lands once and exactly one add of the shared key wins."
  (with-temp-db (db)
    (let* ((wins 0)
           (lock (bt:make-lock))
           (threads
             (loop for n below 4
                   collect
                   (let ((n n))
                     (bt:make-thread
                      (lambda ()
                        (dotimes (i 500)
                          (db-set db (format nil "t~a-~a" n i)
                                  (format nil "~a" i)))
                        (when (db-add db "shared" (format nil "~a" n))
                          (bt:with-lock-held (lock) (incf wins)))))))))
      (mapc #'bt:join-thread threads)
      (is (= 1 wins))
      (is (= 2001 (db-count db)))
      (dotimes (n 4)
        (is (equal "499" (db-get db (format nil "t~a-499" n)
                                 :as :string)))))))
```

Add `(:file "hash-db-tests")` after `"record-tests"` in the test system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 16 hash-db tests fail (`UNDEFINED-FUNCTION`
`OPEN-DB`, or an unbound `*KEY-DIGEST*`).

- [ ] **Step 3: Export the API from `package.lisp`**

Add to the `defpackage` form:

```lisp
  (:export #:vivace-cabinet-error #:not-implemented #:invalid-argument
           #:open-error #:open-db #:close-db #:with-db
           #:db-set #:db-add #:db-replace #:db-append #:db-get #:db-check
           #:db-seize #:db-remove #:db-count #:db-size #:db-path
           #:db-clear #:db-synchronize #:db-error)
```

- [ ] **Step 4: Write `api.lisp`**

```lisp
;;;; The Kyoto Cabinet-style API: conditions, generic functions, key
;;;; coercion and OPEN-DB (spec: API).  Engines implement the generics.

(in-package #:vivace-cabinet)

(define-condition vivace-cabinet-error (error)
  ((message :initarg :message :reader vivace-cabinet-error-message))
  (:report (lambda (c s)
             (write-string (vivace-cabinet-error-message c) s))))

(define-condition not-implemented (vivace-cabinet-error) ())
(define-condition invalid-argument (vivace-cabinet-error) ())
(define-condition open-error (vivace-cabinet-error) ())

(defun %signal (class control &rest args)
  (error class :message (apply #'format nil control args)))

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
returned NIL: :DUPLICATE-RECORD, :NO-RECORD or :NO-PERMISSION, or
:SUCCESS if none has failed."))

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
  "OCTETS as AS, which CHECK-AS has accepted."
  (if (eq as :string)
      (babel:octets-to-string octets :encoding :utf-8)
      octets))

(defun open-db (path &rest args &key (type :hash) &allow-other-keys)
  "Open the database in directory PATH (a trailing / is added).  TYPE is
:HASH; :TREE comes in phase 2c.  Other keywords: OPEN-HASH-DB."
  (let ((dir (uiop:ensure-directory-pathname (merge-pathnames path))))
    (case type
      (:hash (apply #'open-hash-db dir
                    (alexandria:remove-from-plist args :type)))
      (:tree (%signal 'not-implemented "TreeDB arrives in phase 2c"))
      (t (%signal 'invalid-argument "unknown database type ~s" type)))))

(defmacro with-db ((var path &rest open-args) &body body)
  "Evaluate BODY with VAR bound to the open database at PATH; close it
afterwards."
  `(let ((,var (open-db ,path ,@open-args)))
     (unwind-protect (progn ,@body)
       (close-db ,var))))
```

- [ ] **Step 5: Write `hash-db.lisp`**

```lisp
;;;; HashDB: records in a heap, indexed by the linear hash from a key's
;;;; 16-byte digest to the first record of that digest's chain (spec:
;;;; HashDB).  Per-key work holds the digest's stripe lock under the
;;;; database's lock, which clear, close and synchronize take alone.

(in-package #:vivace-cabinet)

(defun murmur3-digest (key)
  (murmur3-128 key 0))

(defvar *key-digest* 'murmur3-digest
  "Function from key octets to a 16-byte digest.  Tests bind it to force
collisions; a database must keep one digest function for life.")

(alexandria:define-constant +stripes+ 1024)
(alexandria:define-constant +header-bytes+ 32)
(alexandria:define-constant +header-magic+ #(86 67 65 66) :test 'equalp)

(defclass hash-db ()
  ((dir :initarg :dir :reader hash-db-dir)
   (writable :initarg :writable :reader hash-db-writable-p)
   (autosync :initarg :autosync :reader hash-db-autosync-p)
   (tuning :initarg :tuning :reader hash-db-tuning)
   (heap :initform nil :accessor hash-db-heap)
   (index :initform nil :accessor hash-db-index)
   (record-count :initform 0 :accessor hash-db-record-count)
   (count-lock :initform (make-lock "hash-db count")
               :reader hash-db-count-lock)
   (lock :initform (make-rw-lock) :reader hash-db-lock)
   (stripes :reader hash-db-stripes
            :initform (let ((v (make-array +stripes+)))
                        (dotimes (i +stripes+ v)
                          (setf (aref v i) (make-rw-lock)))))
   (errors :initform (make-hash-table :test 'eq
                                      #+sbcl :weakness #+sbcl :key)
           :reader hash-db-errors)
   (errors-lock :initform (make-lock "hash-db errors")
                :reader hash-db-errors-lock)
   (open-p :initform nil :accessor hash-db-open-p)))

;;; Files

(defun %heap-file (dir) (merge-pathnames "heap.dat" dir))
(defun %index-dir (dir) (merge-pathnames "index/" dir))
(defun %header-file (dir) (merge-pathnames "header.dat" dir))

(defun %write-header (db)
  "Write DB's header: magic VCAB, format 1, type 1 (hash), record count."
  (let ((h (make-array +header-bytes+ :element-type '(unsigned-byte 8)
                                      :initial-element 0))
        (n (hash-db-record-count db)))
    (replace h +header-magic+)
    (setf (aref h 4) 1
          (aref h 5) 1)
    (dotimes (i 8)
      (setf (aref h (+ 8 i)) (ldb (byte 8 (* 8 i)) n)))
    (with-open-file (out (%header-file (hash-db-dir db))
                         :direction :output :if-exists :supersede
                         :element-type '(unsigned-byte 8))
      (write-sequence h out))))

(defun %read-header (dir)
  "The record count in DIR's header; signals OPEN-ERROR for anything but
a HashDB header."
  (let ((h (make-array +header-bytes+ :element-type '(unsigned-byte 8))))
    (with-open-file (in (%header-file dir) :element-type '(unsigned-byte 8))
      (unless (= +header-bytes+ (read-sequence h in))
        (%signal 'open-error "~a: header too short" dir)))
    (unless (and (equalp (subseq h 0 4) +header-magic+)
                 (= 1 (aref h 4))
                 (= 1 (aref h 5)))
      (%signal 'open-error "~a: not a vivace-cabinet HashDB" dir))
    (let ((n 0))
      (dotimes (i 8 n)
        (setf n (logior n (ash (aref h (+ 8 i)) (* 8 i))))))))

(defun %create-storage (db)
  (destructuring-bind (&key buckets max-locks heap-size heap-reservation)
      (hash-db-tuning db)
    (let ((dir (hash-db-dir db)))
      (ensure-directories-exist (%index-dir dir))
      (setf (hash-db-heap db) (let ((*mmap-min-reservation*
                                      heap-reservation))
                                (create-memory (namestring (%heap-file dir))
                                               heap-size))
            (hash-db-index db) (make-lhash :location (%index-dir dir)
                                           :buckets buckets
                                           :max-locks max-locks)
            (hash-db-record-count db) 0)
      (%write-header db))))

(defun %open-storage (db)
  (destructuring-bind (&key heap-reservation &allow-other-keys)
      (hash-db-tuning db)
    (let ((dir (hash-db-dir db)))
      (setf (hash-db-record-count db) (%read-header dir)
            (hash-db-heap db) (let ((*mmap-min-reservation*
                                      heap-reservation))
                                (open-memory (namestring (%heap-file dir))))
            (hash-db-index db) (open-lhash (%index-dir dir))))))

(defun open-hash-db (dir &key (mode '(:writer :create)) (buckets 4)
                           (max-locks *max-locks*)
                           (heap-size (* 64 1024 1024))
                           (heap-reservation (* 64 1024 1024 1024)))
  "Open, or create, the HashDB in DIR.  Task 4 adds modes."
  (declare (ignore mode))
  (let ((db (make-instance 'hash-db
                           :dir dir :writable t :autosync nil
                           :tuning (list :buckets buckets
                                         :max-locks max-locks
                                         :heap-size heap-size
                                         :heap-reservation
                                         heap-reservation))))
    (if (probe-file (%header-file dir))
        (%open-storage db)
        (%create-storage db))
    (setf (hash-db-open-p db) t)
    db))

(defmethod close-db ((db hash-db))
  (with-write-lock ((hash-db-lock db))
    (when (hash-db-open-p db)
      (when (hash-db-writable-p db)
        (%write-header db))
      (close-lhash (hash-db-index db))
      (close-memory (hash-db-heap db))
      (setf (hash-db-open-p db) nil)
      t)))

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

(defun %stripe (db digest)
  (aref (hash-db-stripes db)
        (logand (logior (aref digest 0) (ash (aref digest 1) 8))
                (1- +stripes+))))

(defun %check-open (db)
  (unless (hash-db-open-p db)
    (%signal 'invalid-argument "the database is closed")))

(defmacro with-key-locked ((db digest mode) &body body)
  "Run BODY holding DB's lock shared and DIGEST's stripe for MODE (:READ
or :WRITE)."
  (let ((d (gensym "DB")) (s (gensym "STRIPE")))
    `(let ((,d ,db))
       (with-read-lock ((hash-db-lock ,d))
         (%check-open ,d)
         (let ((,s (%stripe ,d ,digest)))
           ,(ecase mode
              (:read `(with-read-lock (,s) ,@body))
              (:write `(with-write-lock (,s) ,@body))))))))

(defun %fail (db code)
  "Record CODE as the calling thread's last failure on DB; return NIL."
  (with-lock-held ((hash-db-errors-lock db))
    (setf (gethash (current-thread) (hash-db-errors db)) code))
  nil)

(defmethod db-error ((db hash-db))
  (with-lock-held ((hash-db-errors-lock db))
    (values (gethash (current-thread) (hash-db-errors db) :success))))

(defmacro %writing ((db) &body body)
  "Run BODY if DB is writable, then synchronize under :AUTOSYNC;
otherwise fail with :NO-PERMISSION."
  `(if (hash-db-writable-p ,db)
       (multiple-value-prog1 (progn ,@body)
         (when (hash-db-autosync-p ,db)
           (db-synchronize ,db)))
       (%fail ,db :no-permission)))

(defun %find (db digest key)
  "The address of KEY's record and of the record before it in DIGEST's
chain (NIL at the head); NIL if KEY is absent."
  (let ((heap (hash-db-heap db)))
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
         (addr (write-record (hash-db-heap db) key value (or head 0))))
    (if head
        (lhash-update index digest addr)
        (lhash-insert index digest addr))
    (with-lock-held ((hash-db-count-lock db))
      (incf (hash-db-record-count db)))
    addr))

(defun %replace-record (db digest addr prev key value)
  (let* ((heap (hash-db-heap db))
         (new (write-record heap key value (record-next heap addr))))
    (if prev
        (setf (record-next heap prev) new)
        (lhash-update (hash-db-index db) digest new))
    (free-record heap addr)
    new))

(defun %unlink-record (db digest addr prev)
  (let* ((heap (hash-db-heap db))
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
                                (record-value (hash-db-heap db) addr) v))
              (%insert-record db d k v))
          t)))))

(defmethod db-get ((db hash-db) key &key (as :octets))
  (check-as as)
  (let* ((k (to-octets key)) (d (%digest k)))
    (with-key-locked (db d :read)
      (let ((addr (%find db d k)))
        (if addr
            (from-octets (record-value (hash-db-heap db) addr) as)
            (%fail db :no-record))))))

(defmethod db-check ((db hash-db) key)
  (let* ((k (to-octets key)) (d (%digest k)))
    (with-key-locked (db d :read)
      (let ((addr (%find db d k)))
        (if addr
            (record-value-length (hash-db-heap db) addr)
            (%fail db :no-record))))))

(defmethod db-seize ((db hash-db) key &key (as :octets))
  (check-as as)
  (%writing (db)
    (let* ((k (to-octets key)) (d (%digest k)))
      (with-key-locked (db d :write)
        (multiple-value-bind (addr prev) (%find db d k)
          (if addr
              (prog1 (from-octets (record-value (hash-db-heap db) addr) as)
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

(defmethod db-count ((db hash-db))
  (with-read-lock ((hash-db-lock db))
    (%check-open db)
    (with-lock-held ((hash-db-count-lock db))
      (hash-db-record-count db))))
```

In `vivace-cabinet.asd`, after `(:file "records")` add `(:file "api")`
and `(:file "hash-db")`.

- [ ] **Step 6: Run the suite and watch it pass**

Run: `VC-SUITE`
Expected: exit 0; 79 tests pass; no undefined names in the build output
(`grep -a -i 'undefined'` finds nothing).

- [ ] **Step 7: Mutation checks**

1. In `%unlink-record`, replace the `cond` with `(lhash-remove (hash-db-index
   db) digest)` alone: removing a chain's head then drops its tail. Run
   `VC-TEST collisions-chain-correctly`; confirm it fails; restore.
2. In `%digest`, return `d` unchanged; run `VC-TEST
   all-zero-digest-is-remapped`; confirm it fails; restore.
3. In `db-add`, swap `(%fail db :duplicate-record)` for `t`; run
   `VC-TEST add-replace-append`; confirm it fails; restore.
4. In `db-get`, delete the `(check-as as)` line; run `VC-TEST
   bad-arguments-signal`; confirm it fails; restore.

- [ ] **Step 8: Commit**

```bash
git add api.lisp hash-db.lisp tests/hash-db-tests.lisp tests/support.lisp \
  package.lisp vivace-cabinet.asd
git commit -m "HashDB: per-key operations behind a Kyoto-style API

A key's MurmurHash3 digest indexes a chain of heap records; set, add,
replace, append, get, check, seize, remove and count, with Kyoto's NIL
plus reason for logical failures. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 4: Opening modes, damaged files and whole-database operations

**Files:**
- Modify: `hash-db.lisp` (replace `%open-storage` and `open-hash-db`; add
  `db-size`, `db-path`, `db-clear`, `db-synchronize`)
- Modify: `structures/linear-hash.lisp` (`open-lhash`),
  `tests/linear-hash-tests.lisp`, `docs/provenance.md`
- Create: `tests/hash-db-modes-tests.lisp`
- Modify: `vivace-cabinet.asd`, `README.md`

**Interfaces:**
- Consumes: Task 3's `hash-db` class and helpers (its Produces block);
  `read-memory-pointer`, `memory-mmap`, `sync-region`, `bucket-count`,
  `%lhash-bucket-bytes`, `read-lhash-next-overflow-pointer`,
  `%lhash-config`, `%lhash-table`, `%lhash-overflow`, `m-pointer`,
  `munmap-file`.
- Produces: `open-hash-db` with MODE (exactly one of `:reader`/`:writer`,
  plus `:create`, `:truncate`, `:autosync`); `(db-size db)` → bytes in
  use; `(db-path db)` → namestring; `(db-clear db)` → T or NIL;
  `(db-synchronize db &key hard)` → T; `open-lhash` signals when it cannot
  open.

- [ ] **Step 1: Write the failing tests**

Append to `tests/linear-hash-tests.lisp`:

```lisp
(test open-lhash-signals-on-a-corrupt-table
  "A bad magic byte makes OPEN-LHASH signal, not return a handle whose
files are unmapped."
  (with-temp-directory (dir)
    (close-lhash (make-lhash :location dir :buckets 4))
    (with-open-file (s (merge-pathnames "table.dat" dir)
                       :direction :output :if-exists :overwrite
                       :element-type '(unsigned-byte 8))
      (write-byte 0 s))
    (signals error (open-lhash dir))))
```

Create `tests/hash-db-modes-tests.lisp`:

```lisp
(in-package #:vivace-cabinet-test)

(def-suite hash-db-modes-suite
  :description "HashDB open modes, damaged files, size, clear, sync."
  :in vivace-cabinet-suite)

(in-suite hash-db-modes-suite)

(defun header-count (path)
  "The record count in the header of the database at PATH."
  (vivace-cabinet::%read-header (uiop:ensure-directory-pathname path)))

(test synchronize-persists-the-count
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "s.vch/" dir)))
      (with-db (db path)
        (db-set db "a" "1")
        (db-set db "b" "2")
        (is-true (db-synchronize db))
        (is (= 2 (header-count path)))))))

(test autosync-writes-through
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "a.vch/" dir)))
      (with-db (db path :mode '(:writer :create :autosync))
        (db-set db "a" "1")
        (is (= 1 (header-count path)))))))

(test reader-mode-refuses-writes
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "m.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-db (db path :mode '(:reader))
        (is (equal "v" (db-get db "k" :as :string)))
        (is (null (db-set db "k" "w")))
        (is (eq :no-permission (db-error db)))
        (is (null (db-remove db "k")))
        (is (null (db-clear db)))
        (is (equal "v" (db-get db "k" :as :string)))))))

(test opening-needs-create-or-a-database
  (with-temp-directory (dir)
    (signals open-error (open-db (merge-pathnames "none.vch/" dir)
                                 :mode '(:writer)))
    (signals open-error (open-db (merge-pathnames "none.vch/" dir)
                                 :mode '(:reader)))))

(test truncate-empties
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "t.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-db (db path :mode '(:writer :create :truncate))
        (is (= 0 (db-count db)))
        (is (null (db-get db "k")))))))

(test bad-open-arguments-signal
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "b.vch/" dir)))
      (signals invalid-argument (open-db path :mode '(:reader :writer)))
      (signals invalid-argument (open-db path :mode '(:create)))
      (signals invalid-argument (open-db path :mode '(:writer :bogus)))
      (signals invalid-argument (open-db path :type :bogus))
      (signals not-implemented (open-db path :type :tree)))))

(test corrupt-index-signals
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "i.vch/" dir)))
      (with-db (db path) (db-set db "k" "v"))
      (with-open-file (s (merge-pathnames "index/table.dat" path)
                         :direction :output :if-exists :overwrite
                         :element-type '(unsigned-byte 8))
        (write-byte 0 s))
      (signals open-error (open-db path)))))

(test paths-become-directories
  "A path without a trailing slash, or a relative one, names a directory."
  (with-temp-directory (dir)
    (let ((plain (namestring (merge-pathnames "p.vch" dir))))
      (with-db (db plain)
        (db-set db "k" "v")
        (is (equal (namestring (merge-pathnames "p.vch/" dir))
                   (db-path db))))
      (is-true (probe-file (merge-pathnames "p.vch/header.dat" dir))))
    (let ((*default-pathname-defaults* dir))
      (with-db (db "rel.vch")
        (db-set db "k" "v"))
      (is-true (probe-file (merge-pathnames "rel.vch/heap.dat" dir))))))

(test size-grows
  (with-temp-db (db)
    (let ((before (db-size db)))
      (is (plusp before))
      (dotimes (i 500)
        (db-set db (format nil "k~a" i)
                (make-string 100 :initial-element #\x)))
      (is (> (db-size db) (+ before 50000))))))

(test clear-empties-and-stays-usable
  (with-temp-db (db)
    (dotimes (i 100)
      (db-set db (format nil "k~a" i) "v"))
    (is-true (db-clear db))
    (is (= 0 (db-count db)))
    (is (null (db-get db "k5")))
    (is-true (db-set db "after" "clear"))
    (is (equal "clear" (db-get db "after" :as :string)))))
```

Add `(:file "hash-db-modes-tests")` after `"hash-db-tests"` in the test
system.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; these 11 tests fail and the 79 earlier ones
pass: `open-lhash-signals-on-a-corrupt-table` (no signal);
`synchronize-persists-the-count`, `paths-become-directories`,
`size-grows`, `clear-empties-and-stays-usable` (no applicable method);
`autosync-writes-through`, `reader-mode-refuses-writes`,
`opening-needs-create-or-a-database`, `truncate-empties`,
`bad-open-arguments-signal`, `corrupt-index-signals` (Task 3's
`open-hash-db` ignores MODE and does not check the index). The failing
run leaves some databases open; that is harmless in a test process.

- [ ] **Step 3: Make `open-lhash` signal**

In `structures/linear-hash.lisp`, `open-lhash`'s handler clause is:

```lisp
      (error (c)
        (log:debug "Cannot open lhash: ~S" c)
        (munmap-file (%lhash-config lhash))
        (munmap-file (%lhash-table lhash))
        (munmap-file (%lhash-overflow lhash))))
```

Replace it with:

```lisp
      (error (c)
        (log:debug "Cannot open lhash: ~S" c)
        (dolist (mf (list (%lhash-config lhash) (%lhash-table lhash)
                          (%lhash-overflow lhash)))
          (when (and mf (m-pointer mf))
            (munmap-file mf)))
        (error c)))
```

(A file that failed to map leaves its slot NIL; the old clause then
signalled `no-applicable-method` from `munmap-file`.) In
`docs/provenance.md`, change the linear-hash row's last cell to:
`whole file; \`open-lhash\` signals when it cannot open, after unmapping
what it mapped (vivace-graph's returned a handle whose files were
unmapped)`.

- [ ] **Step 4: Replace `%open-storage` and `open-hash-db`; add the
  whole-database methods**

In `hash-db.lisp`, replace `%open-storage` with:

```lisp
(defun %open-storage (db)
  "Open DB's existing files.  A failure closes what opened and signals
OPEN-ERROR."
  (destructuring-bind (&key heap-reservation &allow-other-keys)
      (hash-db-tuning db)
    (let ((dir (hash-db-dir db)))
      (handler-case
          (setf (hash-db-record-count db) (%read-header dir)
                (hash-db-heap db) (let ((*mmap-min-reservation*
                                          heap-reservation))
                                    (open-memory
                                     (namestring (%heap-file dir))))
                (hash-db-index db) (open-lhash (%index-dir dir)))
        (error (c)
          (when (hash-db-heap db)
            (ignore-errors (close-memory (hash-db-heap db)))
            (setf (hash-db-heap db) nil))
          (if (typep c 'open-error)
              (error c)
              (%signal 'open-error "~a: ~a" dir c)))))))
```

Replace `open-hash-db` with:

```lisp
(alexandria:define-constant +open-modes+
    '(:reader :writer :create :truncate :autosync) :test 'equal)

(defun %delete-storage (dir)
  (dolist (f (list (%header-file dir) (%heap-file dir)))
    (when (probe-file f)
      (delete-file f)))
  (uiop:delete-directory-tree (%index-dir dir) :validate t
                                               :if-does-not-exist :ignore))

(defun open-hash-db (dir &key (mode '(:writer :create)) (buckets 4)
                           (max-locks *max-locks*)
                           (heap-size (* 64 1024 1024))
                           (heap-reservation (* 64 1024 1024 1024)))
  "Open the HashDB in DIR.  MODE holds :READER or :WRITER, and any of
:CREATE, :TRUNCATE, :AUTOSYNC.  BUCKETS and MAX-LOCKS tune the linear
hash; HEAP-SIZE is the heap's first size; HEAP-RESERVATION is the address
space the heap may grow into before it must be reopened."
  (let ((bad (set-difference mode +open-modes+)))
    (when bad
      (%signal 'invalid-argument "unknown open modes ~s" bad)))
  (unless (= 1 (count-if (lambda (m) (member m mode)) '(:reader :writer)))
    (%signal 'invalid-argument
             "MODE needs exactly one of :READER and :WRITER: ~s" mode))
  (let* ((writer (and (member :writer mode) t))
         (db (make-instance 'hash-db
                            :dir dir :writable writer
                            :autosync (and (member :autosync mode) t)
                            :tuning (list :buckets buckets
                                          :max-locks max-locks
                                          :heap-size heap-size
                                          :heap-reservation
                                          heap-reservation)))
         (exists (probe-file (%header-file dir))))
    (when (and exists writer (member :truncate mode))
      (%delete-storage dir)
      (setf exists nil))
    (cond (exists (%open-storage db))
          ((and writer (member :create mode)) (%create-storage db))
          (t (%signal 'open-error
                      "~a: no database here (open with :CREATE)" dir)))
    (setf (hash-db-open-p db) t)
    db))
```

Append:

```lisp
;;; Whole-database operations

(defmethod db-path ((db hash-db))
  (namestring (hash-db-dir db)))

(defmethod db-size ((db hash-db))
  "Bytes in use: the heap's extent and the index's buckets and overflow.
File sizes would overstate: the index files are sparse."
  (with-read-lock ((hash-db-lock db))
    (%check-open db)
    (let ((index (hash-db-index db)))
      (+ (read-memory-pointer (hash-db-heap db))
         (* (bucket-count index) (%lhash-bucket-bytes index))
         (read-lhash-next-overflow-pointer index)))))

(defun %sync-storage (db)
  (let ((index (hash-db-index db)))
    (sync-region (memory-mmap (hash-db-heap db)))
    (dolist (mf (list (%lhash-config index) (%lhash-table index)
                      (%lhash-overflow index)))
      (sync-region mf))
    (%write-header db)))

(defmethod db-synchronize ((db hash-db) &key hard)
  (declare (ignore hard))
  (with-write-lock ((hash-db-lock db))
    (%check-open db)
    (when (hash-db-writable-p db)
      (%sync-storage db))
    t))

(defmethod db-clear ((db hash-db))
  (if (hash-db-writable-p db)
      (with-write-lock ((hash-db-lock db))
        (%check-open db)
        (close-lhash (hash-db-index db))
        (close-memory (hash-db-heap db))
        (%delete-storage (hash-db-dir db))
        (%create-storage db)
        t)
      (%fail db :no-permission)))
```

- [ ] **Step 5: Run the suite and watch it pass**

Run: `VC-SUITE`
Expected: exit 0; 90 tests pass; no undefined names.

- [ ] **Step 6: Mutation checks**

1. In `open-hash-db`, drop `(member :truncate mode)` from the truncate
   test's `and` (every writer open truncates): run `VC-TEST
   reopen-keeps-everything`; confirm it fails; restore.
2. In `%sync-storage`, remove `(%write-header db)`; run `VC-TEST
   synchronize-persists-the-count`; confirm it fails; restore.
3. In `open-lhash`'s handler, delete `(error c)`; run `VC-TEST
   corrupt-index-signals`; confirm it fails; restore.
4. In `db-clear`, remove `(%delete-storage (hash-db-dir db))`; run
   `VC-TEST clear-empties-and-stays-usable`; confirm it fails (the
   recreate finds the old index); restore.

- [ ] **Step 7: Document the API in `README.md`**

Replace the **Status** paragraph with:

```markdown
**Status:** HashDB works (unit 2b): `open-db`, `db-set`, `db-get`,
`db-add`, `db-replace`, `db-append`, `db-check`, `db-seize`, `db-remove`,
`db-count`, `db-size`, `db-path`, `db-clear`, `db-synchronize`,
`db-error`, `close-db`, `with-db`. TreeDB, cursors and the rest of Kyoto's
API follow.

## Use

    (vivace-cabinet:with-db (db "/var/data/words.vch")
      (vivace-cabinet:db-set db "apple" "red")
      (vivace-cabinet:db-get db "apple" :as :string))   ; => "red"

A database is a directory (a trailing `/` is added): `header.dat`,
`heap.dat`, and the index in `index/`. Keys and values are octet vectors;
strings are stored as UTF-8 and read back with `:as :string`.

`open-db` takes `:mode`, a list of `:reader` or `:writer` plus any of
`:create`, `:truncate`, `:autosync` (default `(:writer :create)`), and
tuning keywords: `:buckets` and `:max-locks` for the index, `:heap-size`,
and `:heap-reservation` (default 64 GiB of address space the heap may
grow into in one session).

As in Kyoto Cabinet, an operation that fails for an ordinary reason (adding
a key that exists, removing one that doesn't, writing to a reader) returns
NIL, and `(db-error db)` says why: `:duplicate-record`, `:no-record` or
`:no-permission`. Real problems signal `vivace-cabinet-error` subclasses:
`open-error`, `invalid-argument`, `not-implemented`. `db-check` returns the
value's size; `db-size` returns the bytes in use, not file sizes (the
index files are sparse).
```

In **Limits**, replace the **Address space** and **Growth stops at the
reservation** bullets with:

```markdown
- **Address space.** Each mapped file reserves 8 times its size, at least
  1 GiB, of virtual address space: about 17 GiB per linear hash. A
  HashDB's heap reserves `:heap-reservation` (64 GiB by default), so an
  open HashDB holds about 81 GiB. Limits on address space (`ulimit -v`)
  count these.
- **Growth stops at the reservation.** A HashDB's heap cannot grow past
  `:heap-reservation` until it is reopened, and each linear-hash file
  stops at 8000 MiB; the error names vivace-graph's `GRAPH-DB` package.
  Using the structures directly, bind
  `vivace-cabinet::*mmap-reservation-multiplier*` or
  `vivace-cabinet::*mmap-min-reservation*` before creating or opening to
  reserve more.
```

- [ ] **Step 8: Commit**

```bash
git add hash-db.lisp structures/linear-hash.lisp \
  tests/linear-hash-tests.lisp tests/hash-db-modes-tests.lisp \
  docs/provenance.md vivace-cabinet.asd README.md
git commit -m "HashDB: open modes, damaged files, size, clear, synchronize

Reader, writer, create, truncate and autosync modes; damaged files
signal OPEN-ERROR (OPEN-LHASH now signals instead of returning a broken
handle). README documents the API. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

---

## Finish

- [ ] `VC-SUITE` once more: exit 0, 90 tests.
- [ ] On kraison/vivace-cabinet#2, comment `Ready for review:` with the
  branch and `git -C ~/work/vivace-cabinet diff main...unit-2b-hashdb`.
- [ ] Stop: merge and push wait for Kevin's word; phase 2c gets its own
  plan (with #4, the B+ tree split).
