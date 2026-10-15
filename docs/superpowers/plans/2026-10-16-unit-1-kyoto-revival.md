# Unit 1: kyoto-persistence on Kyoto Cabinet 1.2.80 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** cl-kyoto-cabinet and kyoto-persistence load on current SBCL with
Kyoto Cabinet 1.2.80, and each has a FiveAM suite that passes.

**Architecture:** Two existing public repos, one branch each. cl-kyoto-cabinet
is fixed first: its CFFI declarations disagree with Kyoto's C header (`size_t`
declared 32-bit, wrong return types), and its marshalling code hands Kyoto
4-byte slots for 8-byte size out-parameters, which corrupts memory
(cl-kyoto-cabinet#3). kyoto-persistence then gets its own fixes: `kcmalloc`
called with a pointer instead of a size (SIGABRT on the first `serialize`),
negative-integer and timestamp encoding, `pointer-search`'s off-by-one, and
`klist-remove` writing back the wrong bytes.

**Tech Stack:** SBCL, Quicklisp, CFFI (`:size` is 8 bytes), FiveAM 1.4.3,
cl-ppcre, Kyoto Cabinet 1.2.80 (`/usr/include/kclangc.h`,
`/usr/lib/libkyotocabinet.so`).

**Spec:**
`~/work/vivace-cabinet/docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`,
section "Unit 1". Issues: kraison/cl-kyoto-cabinet#5, #3;
kraison/kyoto-persistence#2; tracker kraison/vivace-cabinet#1.

## Global Constraints

- SBCL only. Kyoto Cabinet 1.2.80 from Arch `extra` (already installed on
  robotron, 2026-10-16).
- Lisp source: spaces only, never tabs; 80 columns maximum; terse comments
  that point at an issue rather than explain at length.
- Run every test in a fresh `sbcl` process, never in a shared REPL image: a
  memory fault kills the whole image.
- Branch `kc-1.2.80` in each repo (`git switch -c kc-1.2.80` from `master`).
  One commit per task. Stage explicit paths only (never `git add -A`, `.` or
  `commit -a`). Nothing is pushed without Kevin's word.
- Both repos are public: commit messages and issue comments stay generic.
- vivace-graph is not touched.
- Every commit message ends with:

  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ
  ```

## Commands

`CKC-SUITE` (cl-kyoto-cabinet, whole suite; exit 0 only if all pass):

```bash
cd ~/work/cl-kyoto-cabinet && sbcl --noinform --non-interactive \
  --load ~/quicklisp/setup.lisp \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval '(ql:quickload :cl-kyoto-cabinet/test :silent t)' \
  --eval '(asdf:test-system :cl-kyoto-cabinet)'
```

`CKC-TEST <name>` (one test): as above, but replace the last `--eval` with
`--eval '(fiveam:run! (quote cl-kyoto-cabinet-test::<name>))'`.

`KP-SUITE` (kyoto-persistence, against the cl-kyoto-cabinet working tree):

```bash
cd ~/work/kyoto-persistence && sbcl --noinform --non-interactive \
  --load ~/quicklisp/setup.lisp \
  --eval '(push (truename "../cl-kyoto-cabinet/") asdf:*central-registry*)' \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval '(ql:quickload :kyoto-persistence/test :silent t)' \
  --eval '(asdf:test-system :kyoto-persistence)'
```

`KP-TEST <name>`: as above, last `--eval` replaced by
`--eval '(fiveam:run! (quote kyoto-persistence-test::<name>))'`.

## Review Focus

The inputs most likely to bite a user that the old code never exercised, each
pinned by a test in the task named:

1. Non-ASCII string keys and values: UTF-8 bytes outnumber characters, and the
   old code passed character counts as lengths (Task 2, `non-ascii-strings`).
2. Keys and values containing NUL: lengths, not terminators, must bound them
   (Task 2, `embedded-nul`; Task 6, NUL-separated keys).
3. Absent keys: get and remove on a missing key return NIL, not an error
   (Task 2, `missing-key`; Task 6, `get-phash` on an absent key).
4. Negative integers and timestamps with a fraction of a second: -1 came back
   as 0, and timestamps lost their nanoseconds (Task 4).
5. A value at the very end of a stored duplicate list, which `pointer-search`
   never examined (Task 5, `pointer-search`).

## Proposals in this plan for Kevin to approve

- **Timestamp encoding changes** (Task 4): stored as nanoseconds since 1900
  instead of whole seconds. A kyoto-persistence store written by the old code
  would read its timestamps wrong. No such store is known.
- **`test.lisp` is deleted** (Task 7): its four routines become FiveAM tests.

---

## Part A: cl-kyoto-cabinet

Start: `cd ~/work/cl-kyoto-cabinet && git switch -c kc-1.2.80`

### Task 1: Test system, and FFI declarations that match kclangc.h

**Files:**
- Modify: `cl-kyoto-cabinet.asd` (add the test system)
- Create: `tests/package.lisp`, `tests/ffi-tests.lisp`
- Modify: `kyoto-cabinet-ffi.lisp:101-339` (every `defcfun`)

**Interfaces:**
- Produces: package `cl-kyoto-cabinet-test` (uses `cl`, `fiveam`,
  `kyoto-cabinet`); suite `:cl-kyoto-cabinet`; helpers `temp-db-path`
  (type) → string, macro `with-temp-db ((var type) &body body)`, `octets`
  (&rest bytes) → `(simple-array (unsigned-byte 8))`, `file-string` (path)
  → string. FFI after this task: `kcdbclose` returns `:boolean`, `kcmalloc`
  takes `(size :size)`, every `size_t` is `:size`.

- [ ] **Step 1: Add the test system to `cl-kyoto-cabinet.asd`**

In the existing `(defsystem cl-kyoto-cabinet ...)`, add this option after
`:depends-on`:

```lisp
    :in-order-to ((test-op (test-op :cl-kyoto-cabinet/test)))
```

Then append at the end of the file:

```lisp
(defsystem cl-kyoto-cabinet/test
  :description "FiveAM tests for cl-kyoto-cabinet."
  :depends-on (:cl-kyoto-cabinet :fiveam :cl-ppcre)
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "ffi-tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call :fiveam :run! :cl-kyoto-cabinet)
               (error "cl-kyoto-cabinet tests failed"))))
```

- [ ] **Step 2: Create `tests/package.lisp`**

```lisp
(defpackage #:cl-kyoto-cabinet-test
  (:use #:cl #:fiveam #:kyoto-cabinet))

(in-package #:cl-kyoto-cabinet-test)

(def-suite :cl-kyoto-cabinet :description "cl-kyoto-cabinet tests")

(defun temp-db-path (type)
  "A fresh path under /var/tmp for a database of TYPE, \"kch\" or \"kct\"."
  (format nil "/var/tmp/ckc-test-~36r.~a"
          (random (expt 36 10) (make-random-state t)) type))

(defmacro with-temp-db ((var type) &body body)
  "Evaluate BODY with VAR bound to a KC-DBM open for writing on a fresh
file of TYPE; close it and delete the file afterwards."
  (let ((path (gensym "PATH")))
    `(let ((,path (temp-db-path ,type))
           (,var (make-instance 'kc-dbm)))
       (unwind-protect
            (progn (dbm-open ,var ,path :write :create)
                   ,@body)
         (ignore-errors (dbm-close ,var))
         (when (probe-file ,path) (delete-file ,path))))))

(defun octets (&rest bytes)
  "A simple (unsigned-byte 8) vector holding BYTES."
  (make-array (length bytes) :element-type '(unsigned-byte 8)
                             :initial-contents bytes))

(defun file-string (path)
  "The contents of the file at PATH, read as Latin-1."
  (with-open-file (in path :external-format :latin-1)
    (let ((s (make-string (file-length in))))
      (subseq s 0 (read-sequence s in)))))
```

- [ ] **Step 3: Create `tests/ffi-tests.lisp`**

```lisp
(in-package #:cl-kyoto-cabinet-test)

(in-suite :cl-kyoto-cabinet)

(defparameter *kclangc* #p"/usr/include/kclangc.h")

(defun squeeze (text)
  "TEXT without C comments, with whitespace runs collapsed to one space."
  (ppcre:regex-replace-all
   "\\s+" (ppcre:regex-replace-all "(?s)/\\*.*?\\*/" text " ") " "))

(defun c-type (declaration)
  "The type in C parameter DECLARATION: \"const char* kbuf\" gives
\"const char*\"."
  (ppcre:regex-replace "\\s*\\b\\w+$" (string-trim " " declaration) ""))

(defun header-prototypes ()
  "Map each kc* function in kclangc.h to (return-type . arg-types)."
  (let ((table (make-hash-table :test 'equal)))
    (ppcre:do-register-groups (ret name args)
        ("((?:const )?\\w+\\**) (kc\\w+)\\(([^)]*)\\);"
         (squeeze (file-string *kclangc*)))
      (setf (gethash name table)
            (cons ret
                  (if (member (string-trim " " args) '("" "void")
                              :test #'string=)
                      '()
                      (mapcar #'c-type (ppcre:split "," args))))))
    table))

(defun kw (symbol)
  (intern (symbol-name symbol) :keyword))

(defun ffi-defcfuns ()
  "(c-name return-type arg-types) for every defcfun in the FFI source,
types as keywords."
  (let ((*package* (find-package :kyoto-cabinet-ffi))
        (*read-eval* t)
        (result '()))
    (with-open-file (in (asdf:system-relative-pathname
                         :cl-kyoto-cabinet "kyoto-cabinet-ffi.lisp"))
      (loop for form = (read in nil in)
            until (eq form in)
            when (and (consp form) (eq (first form) 'cffi:defcfun))
              do (destructuring-bind ((c-name lisp-name) ret &rest args)
                     (rest form)
                   (declare (ignore lisp-name))
                   (push (list c-name (kw ret)
                               (mapcar (lambda (a) (kw (second a))) args))
                         result))))
    (nreverse result)))

(defun allowed-types (c-type position)
  "CFFI types that correctly declare C-TYPE at POSITION, :return or :arg.
A returned char* is KC-allocated and must be kcfree'd, so only :pointer
may declare it."
  (flet ((c= (s) (string= c-type s)))
    (cond ((c= "void") '(:void))
          ((c= "size_t") '(:size :uint64 :unsigned-long))
          ((c= "int32_t") '(:int32 :int :boolean))
          ((c= "uint32_t") '(:uint32 :unsigned-int :dbm-open-flags))
          ((c= "int64_t") '(:int64 :long :long-long))
          ((c= "uint64_t") '(:uint64 :unsigned-long))
          ((c= "double") '(:double))
          ((c= "const char*") '(:string :pointer))
          (t '(:pointer)))))

(test kclangc-parser
  "The header parser reads two known prototypes, and the FFI reader finds
the defcfuns; otherwise the next test could pass on empty data."
  (let ((protos (header-prototypes)))
    (is (equal '("int32_t" "KCDB*" "const char*" "size_t" "const char*"
                 "size_t")
               (gethash "kcdbset" protos)))
    (is (equal '("char*" "KCDB*" "const char*" "size_t" "size_t*")
               (gethash "kcdbget" protos)))
    (is (<= 50 (length (ffi-defcfuns))))))

(test ffi-matches-kclangc
  "Every defcfun agrees with its kclangc.h prototype: return type,
argument count and each argument's width (cl-kyoto-cabinet#3)."
  (let ((protos (header-prototypes)))
    (dolist (decl (ffi-defcfuns))
      (destructuring-bind (c-name ret args) decl
        (let ((proto (gethash c-name protos)))
          (is-true proto "~a is not in kclangc.h" c-name)
          (when proto
            (destructuring-bind (c-ret . c-args) proto
              (is (member ret (allowed-types c-ret :return))
                  "~a returns ~a, declared ~s" c-name c-ret ret)
              (is (= (length c-args) (length args))
                  "~a takes ~d args, declared with ~d"
                  c-name (length c-args) (length args))
              (loop for c in c-args
                    for l in args
                    for i from 1
                    do (is (member l (allowed-types c :arg))
                           "~a arg ~d is ~a, declared ~s"
                           c-name i c l)))))))))

(test close-returns-t
  "dbm-close reports success as T; kcdbclose returns int32_t."
  (let ((db (make-instance 'kc-dbm))
        (path (temp-db-path "kch")))
    (unwind-protect
         (progn (dbm-open db path :write :create)
                (is (eq t (dbm-close db))))
      (when (probe-file path) (delete-file path)))))
```

- [ ] **Step 4: Run the suite and watch it fail**

Run: `CKC-SUITE`
Expected: `kclangc-parser` passes. `ffi-matches-kclangc` fails with about 20
messages, including `kcdbset arg 3 is size_t, declared :UINT32`,
`kcatoi returns int64_t, declared :POINTER`, `kcdbincrint takes 5 args,
declared with 4` and `kcdbclose returns int32_t, declared :POINTER`.
`close-returns-t` fails (it gets a SAP, not T). The process exits non-zero.

- [ ] **Step 5: Replace every `defcfun` in `kyoto-cabinet-ffi.lisp`**

Replace lines 101 to the end of the file (from `(cffi:defcfun ("kcmalloc"`
onward) with:

```lisp
;;; Declarations follow /usr/include/kclangc.h (1.2.80); tests/ffi-tests
;;; checks each.  size_t is :size; a returned char* is :pointer because
;;; the caller must kcfree it (cl-kyoto-cabinet#3).

(cffi:defcfun ("kcmalloc" kcmalloc) :pointer
  (size :size))

(cffi:defcfun ("kcfree" kcfree) :void
  (ptr :pointer))

(cffi:defcfun ("kctime" kctime) :double)

(cffi:defcfun ("kcatoi" kcatoi) :int64
  (str :string))

(cffi:defcfun ("kcatoix" kcatoix) :int64
  (str :string))

(cffi:defcfun ("kcatof" kcatof) :double
  (str :string))

(cffi:defcfun ("kchashmurmur" kchashmurmur) :uint64
  (buf :pointer)
  (size :size))

(cffi:defcfun ("kchashfnv" kchashfnv) :uint64
  (buf :pointer)
  (size :size))

(cffi:defcfun ("kcnan" kcnan) :double)

(cffi:defcfun ("kcinf" kcinf) :double)

(cffi:defcfun ("kcchknan" kcchknan) :boolean
  (num :double))

(cffi:defcfun ("kcchkinf" kcchkinf) :boolean
  (num :double))

(cffi:defcfun ("kcecodename" kcecodename) :string
  (code :int32))

(cffi:defcfun ("kcdbnew" kcdbnew) :pointer)

(cffi:defcfun ("kcdbopen" kcdbopen) :boolean
  (db :pointer)
  (path :string)
  (mode dbm-open-flags))

(cffi:defcfun ("kcdbdel" kcdbdel) :void
  (db :pointer))

(cffi:defcfun ("kcdbset" kcdbset) :boolean
  (db :pointer)
  (kbuf :pointer)
  (ksiz :size)
  (vbuf :pointer)
  (vsiz :size))

(cffi:defcfun ("kcdbadd" kcdbadd) :boolean
  (db :pointer)
  (kbuf :pointer)
  (ksiz :size)
  (vbuf :pointer)
  (vsiz :size))

(cffi:defcfun ("kcdbappend" kcdbappend) :boolean
  (db :pointer)
  (kbuf :pointer)
  (ksiz :size)
  (vbuf :pointer)
  (vsiz :size))

(cffi:defcfun ("kcdbget" kcdbget) :pointer
  (db :pointer)
  (kbuf :string)
  (ksiz :size)
  (sp :pointer))

(cffi:defcfun ("kcdbclose" kcdbclose) :boolean
  (db :pointer))

(cffi:defcfun ("kcdbecode" kcdbecode) :int
  (db :pointer))

(cffi:defcfun ("kcdbemsg" kcdbemsg) :string
  (db :pointer))

(cffi:defcfun ("kcdbaccept" kcdbaccept) :boolean
  (db :pointer)
  (kbuf :pointer)
  (ksiz :size)
  (fullproc :pointer)
  (emptyproc :pointer)
  (opq :pointer)
  (writable :boolean))

(cffi:defcfun ("kcdbiterate" kcdbiterate) :boolean
  (db :pointer)
  (fullproc :pointer)
  (opq :pointer)
  (writable :boolean))

(cffi:defcfun ("kcdbincrint" kcdbincrint) :int64
  (db :pointer)
  (kbuf :pointer)
  (ksiz :size)
  (num :int64)
  (orig :int64))

(cffi:defcfun ("kcdbincrdouble" kcdbincrdouble) :double
  (db :pointer)
  (kbuf :pointer)
  (ksiz :size)
  (num :double)
  (orig :double))

(cffi:defcfun ("kcdbcas" kcdbcas) :boolean
  (db :pointer)
  (kbuf :pointer)
  (ksiz :size)
  (ovbuf :pointer)
  (ovsiz :size)
  (nvbuf :pointer)
  (nvsiz :size))

(cffi:defcfun ("kcdbremove" kcdbremove) :boolean
  (db :pointer)
  (kbuf :string)
  (ksiz :size))

(cffi:defcfun ("kcdbgetbuf" kcdbgetbuf) :int32
  (db :pointer)
  (kbuf :pointer)
  (ksiz :size)
  (vbuf :pointer)
  (max :size))

(cffi:defcfun ("kcdbclear" kcdbclear) :boolean
  (db :pointer))

(cffi:defcfun ("kcdbsync" kcdbsync) :boolean
  (db :pointer)
  (hard :boolean)
  (proc :pointer)
  (opq :pointer))

(cffi:defcfun ("kcdbcopy" kcdbcopy) :boolean
  (db :pointer)
  (dest :string))

(cffi:defcfun ("kcdbbegintran" kcdbbegintran) :boolean
  (db :pointer)
  (hard :boolean))

(cffi:defcfun ("kcdbbegintrantry" kcdbbegintrantry) :boolean
  (db :pointer)
  (hard :boolean))

(cffi:defcfun ("kcdbendtran" kcdbendtran) :boolean
  (db :pointer)
  (commit :boolean))

(cffi:defcfun ("kcdbdumpsnap" kcdbdumpsnap) :boolean
  (db :pointer)
  (dest :string))

(cffi:defcfun ("kcdbloadsnap" kcdbloadsnap) :boolean
  (db :pointer)
  (src :string))

(cffi:defcfun ("kcdbcount" kcdbcount) :int64
  (db :pointer))

(cffi:defcfun ("kcdbsize" kcdbsize) :int64
  (db :pointer))

(cffi:defcfun ("kcdbpath" kcdbpath) :pointer
  (db :pointer))

(cffi:defcfun ("kcdbstatus" kcdbstatus) :pointer
  (db :pointer))

(cffi:defcfun ("kcdbcursor" kcdbcursor) :pointer
  (db :pointer))

(cffi:defcfun ("kccurdel" kccurdel) :void
  (cur :pointer))

(cffi:defcfun ("kccuraccept" kccuraccept) :boolean
  (cur :pointer)
  (fullproc :pointer)
  (opq :pointer)
  (writable :boolean)
  (step :boolean))

(cffi:defcfun ("kccursetvalue" kccursetvalue) :boolean
  (cur :pointer)
  (vbuf :pointer)
  (vsiz :size)
  (step :boolean))

(cffi:defcfun ("kccurremove" kccurremove) :boolean
  (cur :pointer))

(cffi:defcfun ("kccurgetkey" kccurgetkey) :pointer
  (cur :pointer)
  (sp :pointer)
  (step :boolean))

(cffi:defcfun ("kccurgetvalue" kccurgetvalue) :pointer
  (cur :pointer)
  (sp :pointer)
  (step :boolean))

(cffi:defcfun ("kccurget" kccurget) :pointer
  (cur :pointer)
  (ksp :pointer)
  (vbp :pointer)
  (vsp :pointer)
  (step :boolean))

(cffi:defcfun ("kccurjump" kccurjump) :boolean
  (cur :pointer))

(cffi:defcfun ("kccurjumpkey" kccurjumpkey) :boolean
  (cur :pointer)
  (kbuf :string)
  (ksiz :size))

(cffi:defcfun ("kccurstep" kccurstep) :boolean
  (cur :pointer))

(cffi:defcfun ("kccurdb" kccurdb) :pointer
  (cur :pointer))

(cffi:defcfun ("kccurecode" kccurecode) :int
  (cur :pointer))

(cffi:defcfun ("kccuremsg" kccuremsg) :string
  (cur :pointer))
```

`kcdbget`, `kcdbremove` and `kccurjumpkey` keep `kbuf :string`: callers pass
both Lisp strings and foreign pointers, and CFFI's `:string` passes a pointer
through unchanged. Task 2 moves the string callers onto pointers.

- [ ] **Step 6: Run the suite and watch it pass**

Run: `CKC-SUITE`
Expected: exit 0; all three tests pass.

- [ ] **Step 7: Mutation check**

Change `kcdbset`'s `(ksiz :size)` back to `(ksiz :uint32)`, run
`CKC-TEST ffi-matches-kclangc`, and confirm it fails naming `kcdbset arg 3`.
Restore `:size`. Then change `kcdbclose`'s return type back to `:pointer`,
run `CKC-TEST close-returns-t`, confirm it fails, and restore `:boolean`.

- [ ] **Step 8: Commit**

```bash
git add cl-kyoto-cabinet.asd tests/package.lisp tests/ffi-tests.lisp \
  kyoto-cabinet-ffi.lisp
git commit -m "FFI declarations match kclangc.h; add a FiveAM suite

size_t is :size, return types follow the header, and kcdbincrint and
kcdbcas take their full argument lists. A test checks every defcfun
against /usr/include/kclangc.h. Part of #5.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 2: Marshalling — 8-byte size slots, Kyoto-owned memory, byte lengths

**Files:**
- Modify: `kyoto-cabinet.lisp` (helper functions, lines 336-664)
- Modify: `kyoto-cabinet-dbm.lisp:159-182` (`iter-item`, `iter-item-fast`)
- Create: `tests/marshalling-tests.lisp`
- Modify: `cl-kyoto-cabinet.asd` (add the file to the test system)

**Interfaces:**
- Consumes: Task 1's helpers and FFI.
- Produces: macro `with-size-slot ((var) &body body)` in package
  `kyoto-cabinet`, binding VAR to a foreign `:size`. `iter-item-fast` returns
  `(values key-ptr key-size value-ptr value-size)`, where `key-size` and
  `value-size` are foreign `:size` slots and `value-ptr` a foreign `:pointer`
  slot; the caller `kcfree`s `key-ptr` and `foreign-free`s the three slots.
  kyoto-persistence (Task 6) depends on this.

- [ ] **Step 1: Add `"marshalling-tests"` to the test system**

In `cl-kyoto-cabinet.asd`, change the test system's components to:

```lisp
  :components ((:file "package")
               (:file "ffi-tests")
               (:file "marshalling-tests"))
```

- [ ] **Step 2: Create `tests/marshalling-tests.lisp`**

```lisp
(in-package #:cl-kyoto-cabinet-test)

(in-suite :cl-kyoto-cabinet)

(test no-32-bit-size-slots
  "KC writes a size_t (8 bytes) through every size out-parameter; a
4-byte slot corrupts memory (cl-kyoto-cabinet#3)."
  (dolist (name '("kyoto-cabinet.lisp" "kyoto-cabinet-dbm.lisp"))
    (let ((text (file-string
                 (asdf:system-relative-pathname :cl-kyoto-cabinet name))))
      (dolist (re '("\\([\\w-]+ :(?:int|uint32|unsigned-int)\\)"
                    "foreign-alloc :(?:int|uint32|unsigned-int)\\b"
                    "mem-ref [\\w-]+ :(?:int|uint32|unsigned-int)\\)"))
        (is (null (ppcre:all-matches-as-strings re text))
            "~a: ~s" name (ppcre:all-matches-as-strings re text))))))

(test readme-example
  "The README session, which crashed SBCL in cl-kyoto-cabinet#3."
  (with-temp-db (db "kch")
    (is (eq t (dbm-put db "Ilya" "Sterin" :mode :keep)))
    (is (equal "Sterin" (dbm-get db "Ilya")))
    (is (eq t (dbm-remove db "Ilya")))
    (is (eq t (dbm-put db 123 "456" :mode :keep)))
    (is (equal "456" (dbm-get db 123)))
    (is (eq t (dbm-put db 123 (octets 100 101) :mode :replace)))
    (with-iterator (iter db)
      (is (eq t (iter-first iter)))
      (is (equal '(123 "de")
                 (multiple-value-list
                  (iter-item iter :key-type :integer)))))))

(test missing-key
  "A missing key is not an error: dbm-get and dbm-remove return NIL."
  (with-temp-db (db "kch")
    (is (null (dbm-get db "absent")))
    (is (null (dbm-get db "absent" :octets)))
    (is (null (dbm-remove db "absent")))))

(test large-value
  "A 1 MiB value round-trips through the size_t length paths."
  (with-temp-db (db "kch")
    (let ((value (make-array (expt 2 20) :element-type '(unsigned-byte 8))))
      (dotimes (i (length value))
        (setf (aref value i) (mod (* i 7) 256)))
      (is (eq t (dbm-put db "big" value)))
      (is (equalp value (dbm-get db "big" :octets))))))

(test non-ascii-strings
  "String keys and values travel as UTF-8 bytes and come back whole."
  (dolist (type '("kch" "kct"))
    (with-temp-db (db type)
      (is (eq t (dbm-put db "clé" "naïve 日本")))
      (is (equal "naïve 日本" (dbm-get db "clé")))
      (is (eq t (dbm-put db 7 "日本")))
      (is (equal "日本" (dbm-get db 7)))
      (is (eq t (dbm-remove db "clé")))
      (is (null (dbm-get db "clé"))))))

(test embedded-nul
  "Keys and values may contain NUL: lengths, not terminators, bound them."
  (with-temp-db (db "kch")
    (let ((key (format nil "a~cb" (code-char 0)))
          (text (format nil "x~cy" (code-char 0)))
          (value (octets 1 0 2 0 3)))
      (is (eq t (dbm-put db key value)))
      (is (equalp value (dbm-get db key :octets)))
      (is (eq t (dbm-put db "s" text)))
      (is (equal text (dbm-get db "s"))))))
```

- [ ] **Step 3: Run the suite and watch it fail**

Run: `CKC-SUITE`
Expected failures: `no-32-bit-size-slots` (lists `(size-ptr :int)`,
`foreign-alloc :uint32`, `foreign-alloc :unsigned-int`,
`mem-ref size-ptr :int)` and others); `non-ascii-strings` (the `"clé"` get
returns NIL, the int-keyed value comes back short); `embedded-nul` (the string
value is cut at the NUL). `readme-example`, `missing-key` and `large-value`
may pass or may crash the process: the corruption is intermittent, which is
why #3 was hard to pin.

- [ ] **Step 4: Fix `with-string-value` and add `with-size-slot`**

In `kyoto-cabinet.lisp`, replace the `with-string-value` macro (lines
336-343), whose cleanup tested the literal symbol `value-ptr`, with:

```lisp
(defmacro with-string-value ((value-ptr initform) &body body)
  "Evaluate BODY with VALUE-PTR bound to INITFORM, a KC-allocated
pointer; kcfree it afterwards."
  `(let ((,value-ptr ,initform))
     (unwind-protect
          (progn
            ,@body)
       (when (and ,value-ptr (not (null-pointer-p ,value-ptr)))
         (kcfree ,value-ptr)))))

(defmacro with-size-slot ((var) &body body)
  "Evaluate BODY with VAR bound to a foreign size_t for a KC size
out-parameter.  KC writes 8 bytes (cl-kyoto-cabinet#3)."
  `(with-foreign-object (,var :size)
     ,@body))
```

- [ ] **Step 5: Use 8-byte slots in the mechanical cases**

In `get-pointer->pointer`, `get-string->octets`, `get-octets->octets`,
`get-octets->string` and `get-pointer`, replace each
`(with-foreign-object (size-ptr :int)` with `(with-size-slot (size-ptr)`, and
each `(mem-ref size-ptr :int)` with `(mem-ref size-ptr :size)`. In
`get-something`, replace `(with-foreign-object (size :pointer)` with
`(with-size-slot (size)`. In `copy-foreign-value`, replace
`(mem-ref size-ptr :int)` with `(mem-ref size-ptr :size)`.

- [ ] **Step 6: Rewrite the functions that need more than a slot change**

Replace `get-string->string` (it passed the character count as the key
length, leaked a `foreign-alloc`, and read the value up to its first NUL):

```lisp
(defun get-string->string (db key fn)
  "Returns a value from DB under KEY using FN where the key and value
are strings."
  (declare (optimize (speed 3)))
  (declare (type function fn))
  (with-foreign-string ((key-ptr key-len) key :null-terminated-p nil)
    (with-size-slot (size-ptr)
      (with-string-value (value-ptr (funcall fn (ptr-of db)
                                             key-ptr key-len size-ptr))
        (if (null-pointer-p value-ptr)
            (maybe-raise-error db "(key ~a)" key)
            (foreign-string-to-lisp value-ptr
                                    :count (mem-ref size-ptr :size)))))))
```

Replace `get-int32->string`:

```lisp
(defun get-int32->string (db key fn)
  "Returns a value from DB under KEY using FN where the key is a
32-bit integer and the value a string."
  (declare (optimize (speed 3)))
  (declare (type function fn))
  (let ((key-len (foreign-type-size :int32)))
    (with-foreign-object (key-ptr :int32)
      (with-size-slot (size-ptr)
        (setf (mem-ref key-ptr :int32) key)
        (with-string-value (value-ptr (funcall fn (ptr-of db)
                                               key-ptr key-len size-ptr))
          (if (null-pointer-p value-ptr)
              (maybe-raise-error db "(key ~a)" key)
              (foreign-string-to-lisp value-ptr
                                      :count (mem-ref size-ptr :size))))))))
```

Replace `get-int32->octets` (it freed Kyoto's memory with `foreign-free`):

```lisp
(defun get-int32->octets (db key fn)
  "Returns a value from DB under KEY using FN where the key is a
32-bit integer and the value an octet vector."
  (declare (optimize (speed 3)))
  (declare (type function fn))
  (let ((key-len (foreign-type-size :int32)))
    (with-foreign-object (key-ptr :int32)
      (with-size-slot (size-ptr)
        (setf (mem-ref key-ptr :int32) key)
        (with-string-value (value-ptr (funcall fn (ptr-of db)
                                               key-ptr key-len size-ptr))
          (if (null-pointer-p value-ptr)
              (maybe-raise-error db "(key ~a)" key)
              (copy-foreign-value value-ptr size-ptr)))))))
```

Replace `put-int32->string` (it passed the character count as the value
length):

```lisp
(defun put-int32->string (db key value fn)
  "Inserts VALUE into DB under KEY using FN where the key is a 32-bit
integer and the value is a string."
  (declare (optimize (speed 3)))
  (declare (type simple-string value)
           (type function fn))
  (let ((key-len (foreign-type-size :int32)))
    (with-foreign-object (key-ptr :int32)
      (setf (mem-ref key-ptr :int32) (convert-to-foreign key :int32))
      (with-foreign-string ((value-ptr value-len) value
                            :null-terminated-p nil)
        (or (funcall fn (ptr-of db) key-ptr key-len value-ptr value-len)
            (maybe-raise-error db "(key ~a) (value ~a)" key value))))))
```

In `rem-string->value`, change `(kcdbremove (ptr-of db) key key-len)` to
`(kcdbremove (ptr-of db) key-ptr key-len)`.

Replace the `:string` method of `convert-to-lisp` so it honours the size:

```lisp
  (:method ((type (eql :string)) what-ptr &optional size)
    (if size
        (foreign-string-to-lisp what-ptr :count (mem-ref size :size))
        (foreign-string-to-lisp what-ptr)))
```

- [ ] **Step 7: Rewrite `iter-item` and `iter-item-fast`**

In `kyoto-cabinet-dbm.lisp`, replace both methods (lines 159-182). The old
`iter-item` leaked one allocation, freed Kyoto's key region with
`foreign-free`, and used `:pointer` slots for sizes:

```lisp
(defmethod iter-item ((iter kc-iterator)
                      &key (key-type :string) (value-type :string))
  "Returns the key and value at ITER as two values, or NIL at the end.
Does not advance ITER."
  (with-size-slot (key-size)
    (with-size-slot (value-size)
      (with-foreign-object (value-ptr :pointer)
        (let ((key-ptr (kccurget (ptr-of iter) key-size value-ptr
                                 value-size nil)))
          (if (null-pointer-p key-ptr)
              (progn (maybe-raise-error iter) nil)
              ;; One region holds key and value; one kcfree (kclangc.h).
              (unwind-protect
                   (values (convert-to-lisp key-type key-ptr key-size)
                           (convert-to-lisp value-type
                                            (mem-ref value-ptr :pointer)
                                            value-size))
                (kcfree key-ptr))))))))

(defmethod iter-item-fast ((iter kc-iterator))
  "Returns KC's key pointer and three foreign slots: key size, value
pointer and value size.  The caller kcfrees the key pointer, which holds
the value too, and foreign-frees the three slots."
  (let* ((key-size (foreign-alloc :size))
         (value-size (foreign-alloc :size))
         (value-ptr (foreign-alloc :pointer))
         (key-ptr (kccurget (ptr-of iter) key-size value-ptr value-size
                            nil)))
    (values key-ptr key-size value-ptr value-size)))
```

- [ ] **Step 8: Run the suite and watch it pass**

Run: `CKC-SUITE` three times in a row (the corruption was intermittent).
Expected: exit 0 each time; all tests pass.

- [ ] **Step 9: Mutation check**

In `get-string->octets`, change `(with-size-slot (size-ptr)` back to
`(with-foreign-object (size-ptr :int)`, run `CKC-TEST no-32-bit-size-slots`,
confirm it fails, restore. (Editing the macro body itself would not trip the
scan: it reads `(,var :size)`.) In `get-string->string`,
replace `key-ptr key-len` in the `funcall` with `key (length key)`, run
`CKC-TEST non-ascii-strings`, confirm it fails, restore. Remove `:count
(mem-ref size-ptr :size)` from `get-string->string`, run `CKC-TEST
embedded-nul`, confirm it fails, restore.

- [ ] **Step 10: Commit**

```bash
git add kyoto-cabinet.lisp kyoto-cabinet-dbm.lisp \
  tests/marshalling-tests.lisp cl-kyoto-cabinet.asd
git commit -m "Size out-parameters are size_t; strings use byte lengths

Kyoto writes 8 bytes through every size out-parameter; the old 4-byte
slots corrupted memory (#3). Kyoto-allocated results are kcfree'd,
string keys and values use their UTF-8 byte length, and string values
are read by length, so NUL survives. Part of #5.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 3: Transactions, tree iteration, and how to run the tests

**Files:**
- Create: `tests/behaviour-tests.lisp`
- Modify: `cl-kyoto-cabinet.asd` (add the file)
- Modify: `README` (add a Testing section)

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: nothing new; these tests pin behaviour unit 3's conformance check
  relies on.

- [ ] **Step 1: Add `"behaviour-tests"` to the test system's components**

```lisp
  :components ((:file "package")
               (:file "ffi-tests")
               (:file "marshalling-tests")
               (:file "behaviour-tests"))
```

- [ ] **Step 2: Create `tests/behaviour-tests.lisp`**

```lisp
(in-package #:cl-kyoto-cabinet-test)

(in-suite :cl-kyoto-cabinet)

(test transaction-commit
  "with-transaction commits when its body returns normally."
  (with-temp-db (db "kch")
    (with-transaction (db) (dbm-put db "k" "v"))
    (is (equal "v" (dbm-get db "k")))))

(test transaction-rollback
  "with-transaction rolls back when its body signals."
  (with-temp-db (db "kch")
    (ignore-errors
     (with-transaction (db)
       (dbm-put db "k" "v")
       (error "abort")))
    (is (null (dbm-get db "k")))))

(test tree-iteration
  "A tree database iterates in byte order; iter-go-to jumps to a key."
  (with-temp-db (db "kct")
    (dolist (k '("b" "c" "a"))
      (dbm-put db k (string-upcase k)))
    (is (= 3 (dbm-num-records db)))
    (with-iterator (iter db)
      (is (eq t (iter-first iter)))
      (is (equal '("a" "b" "c")
                 (loop collect (iter-key iter) while (iter-next iter))))
      (is (eq t (iter-go-to iter "b")))
      (is (equal "B" (iter-value iter))))))
```

- [ ] **Step 3: Run the suite**

Run: `CKC-SUITE`
Expected: exit 0. These tests pin behaviour that already works after Tasks 1
and 2, so they pass at once; Step 4 proves they can fail.

- [ ] **Step 4: Mutation check**

In `kyoto-cabinet-dbm.lisp`, make `dbm-commit` call `(kcdbendtran (ptr-of
db) NIL)`; run `CKC-TEST transaction-commit`; confirm it fails; restore
`T`. In the string method of `iter-go-to`, pass `(1- key-len)` instead of
`key-len` to `kccurjumpkey`; run `CKC-TEST tree-iteration`; confirm it fails
(the cursor lands on `"a"`, value `"A"`); restore. (Mutating `iter-next`
instead would make the test's loop collect forever.)

- [ ] **Step 5: Add a Testing section to `README`**

Append to `README`:

```
Testing
-------

Needs Kyoto Cabinet (tested with 1.2.80; the FFI test reads
/usr/include/kclangc.h), SBCL and Quicklisp. From this directory:

  sbcl --non-interactive --load ~/quicklisp/setup.lisp \
    --eval '(push (truename "./") asdf:*central-registry*)' \
    --eval '(ql:quickload :cl-kyoto-cabinet/test)' \
    --eval '(asdf:test-system :cl-kyoto-cabinet)'

The process exits non-zero if any test fails. Run the suite in its own
process: a memory fault in foreign code takes the whole Lisp down.
```

- [ ] **Step 6: Commit**

```bash
git add tests/behaviour-tests.lisp cl-kyoto-cabinet.asd README
git commit -m "Test transactions and tree iteration; document the suite

Part of #5.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

---

## Part B: kyoto-persistence

Start: `cd ~/work/kyoto-persistence && git switch -c kc-1.2.80`. Every
command here loads cl-kyoto-cabinet from `../cl-kyoto-cabinet/`, which must
be on its `kc-1.2.80` branch with Part A done.

### Task 4: Test system, serialization that works

**Files:**
- Modify: `kyoto-persistence.asd` (add the test system)
- Create: `tests/package.lisp`, `tests/serialize-tests.lisp`
- Modify: `serialize.lisp` (10 `kcmalloc` sites, integer and ratio lengths,
  timestamps)
- Modify: `uuid.lisp` (2 `kcmalloc` sites)

**Interfaces:**
- Consumes: cl-kyoto-cabinet's `kcmalloc (size)` from Task 1.
- Produces: package `kyoto-persistence-test` (uses `cl`, `fiveam`; local
  nickname `kp` for `kyoto-persistence`); suite `:kyoto-persistence`;
  helpers `round-trip` (object) → object, `temp-store-path` (type) → string.
  `serialize` returns `(values pointer size)` with the pointer from
  `kcmalloc`, to be released with `kcfree`.

- [ ] **Step 1: Add the test system to `kyoto-persistence.asd`**

In `(defsystem kyoto-persistence ...)`, add after `:depends-on`:

```lisp
  :in-order-to ((test-op (test-op :kyoto-persistence/test)))
```

Append at the end of the file:

```lisp
(defsystem kyoto-persistence/test
  :description "FiveAM tests for kyoto-persistence."
  :depends-on (:kyoto-persistence :fiveam :cl-ppcre)
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "serialize-tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call :fiveam :run! :kyoto-persistence)
               (error "kyoto-persistence tests failed"))))
```

- [ ] **Step 2: Create `tests/package.lisp`**

```lisp
(defpackage #:kyoto-persistence-test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:kp #:kyoto-persistence)))

(in-package #:kyoto-persistence-test)

(def-suite :kyoto-persistence :description "kyoto-persistence tests")

(defun round-trip (object)
  "Serialize OBJECT, deserialize the bytes, free them; return the copy."
  (multiple-value-bind (ptr size) (kp:serialize object)
    (unwind-protect (kp:deserialize ptr size)
      (kyoto-cabinet-ffi:kcfree ptr))))

(defun temp-store-path (type)
  "A fresh path under /var/tmp for a store of TYPE, \"kch\" or \"kct\"."
  (format nil "/var/tmp/kp-test-~36r.~a"
          (random (expt 36 10) (make-random-state t)) type))
```

- [ ] **Step 3: Create `tests/serialize-tests.lisp`**

```lisp
(in-package #:kyoto-persistence-test)

(in-suite :kyoto-persistence)

(test serialize-round-trips
  "Every supported type survives serialize then deserialize."
  (dolist (x (list "hello" "" "naïve 日本" 0 1 255 256 (expt 2 70)
                   (- (expt 2 70)) 1/3 -7/2 1.5f0 -2.25d0 #\a #\λ t nil
                   :key 'kp:open-store '(1 "two" 3.0d0) '(1 . 2)))
    (is (equal x (round-trip x)) "~s did not round-trip" x)))

(test negative-integers
  "Negative integers keep their magnitude; -1 and negative powers of 256
were encoded with too few bytes (kyoto-persistence#2)."
  (dolist (x (list -1 -2 -255 -256 -65536 (- (expt 2 64)) -256/3))
    (is (eql x (round-trip x)) "~s came back as ~s" x (round-trip x))))

(test uuid-round-trip
  (let ((u (uuid:make-v4-uuid)))
    (is (uuid:uuid= u (round-trip u)))))

(test timestamp-round-trip
  "Timestamps keep their nanoseconds."
  (let ((ts (local-time:now)))
    (is (local-time:timestamp= ts (round-trip ts)))))
```

- [ ] **Step 4: Run the suite and watch it fail**

Run: `KP-SUITE`
Expected: every test fails, each with a `SERIALIZATION-ERROR` whose reason is
a type error: `kcmalloc` now takes a size (Task 1) and is still passed a
pointer. (Before Task 1, the same call aborted SBCL with SIGABRT.)

- [ ] **Step 5: Pass sizes to `kcmalloc`**

At each of these 12 sites the code binds `sz` to a one-element foreign int
holding the size, passes `sz` to `kcmalloc`, then frees it:

| File:line | Size expression |
|---|---|
| `uuid.lisp:37` | `18` |
| `uuid.lisp:63` | `16` |
| `serialize.lisp:114` | `3` |
| `serialize.lisp:125` | `size` |
| `serialize.lisp:187` | `total-length` |
| `serialize.lisp:222` | `(+ 2 total-bytes)` |
| `serialize.lisp:249` | `(+ 1 length-of-encoded-length vector-length)` |
| `serialize.lisp:278` | `1` |
| `serialize.lisp:285` | `1` |
| `serialize.lisp:301` | `(+ 1 (length encoded-length) size)` |
| `serialize.lisp:354` | `(+ 1 length-of-encoded-length total-length)` |
| `serialize.lisp:382` | `(+ 1 length-of-encoded-length total-length)` (on line 383) |

Line numbers are as before this step; edit from the bottom of each file up so
they stay valid. At each site: delete the `(sz (foreign-alloc :int :initial-element EXPR))`
binding, change `(kcmalloc sz)` (or `(kyoto-cabinet-ffi:kcmalloc sz)`) to
`(kcmalloc EXPR)` with the same package prefix, and delete the matching
`(foreign-free sz)` or `(cffi:foreign-free sz)`. Where deleting the binding
leaves `(let* ((vec ...)))`, keep the `let*`. Example, `serialize.lisp:114`:

```lisp
;; before
      (let* ((sz (foreign-alloc :int :initial-element 3))
             (vec (kyoto-persistence:kcmalloc sz)))
        ...
        (foreign-free sz)
        (values vec 3))
;; after
      (let* ((vec (kyoto-persistence:kcmalloc 3)))
        ...
        (values vec 3))
```

Check: `rg -n 'initial-element|foreign-free sz|kcmalloc sz' serialize.lisp
uuid.lisp` prints nothing.

- [ ] **Step 6: Size negative numbers by magnitude**

In `serialize.lisp`, `compute-serialized-length` for integers (originally
line 106; Step 5 removed lines below it, not above):

```lisp
(defmethod compute-serialized-length ((int integer))
  (let ((n-bytes (ceiling (integer-length (abs int)) 8)))
    (list (+ 2 n-bytes) n-bytes 2 1)))
```

In `serialize` for ratios (originally around line 183), change
`(numerator-bytes (ceiling (integer-length numerator) 8))` to
`(numerator-bytes (ceiling (integer-length (abs numerator)) 8))`.

- [ ] **Step 7: Store timestamps with nanoseconds**

Replace `serialize` for timestamps and its `deserialize-help` (originally
lines 161-171; find them by `(defmethod serialize ((timestamp timestamp))`):

```lisp
(defmethod serialize ((timestamp timestamp))
  ;; Nanoseconds since 1900; whole seconds lost the fraction
  ;; (kyoto-persistence#2).
  (multiple-value-bind (ptr len)
      (serialize (+ (* (timestamp-to-universal timestamp) 1000000000)
                    (nsec-of timestamp)))
    (setf (mem-aref ptr :unsigned-char 0) +timestamp+)
    (values ptr len)))

(defmethod deserialize-help ((become (eql +timestamp+)) pointer
                             header-length data-length)
  (declare (type integer become header-length data-length))
  (multiple-value-bind (seconds nsec)
      (floor (deserialize-help +positive-integer+ pointer header-length
                               data-length)
             1000000000)
    (values (universal-to-timestamp seconds :nsec nsec)
            (+ header-length data-length))))
```

- [ ] **Step 8: Run the suite and watch it pass**

Run: `KP-SUITE`
Expected: exit 0; all four tests pass.

- [ ] **Step 9: Mutation check**

Remove `(abs int)` from `compute-serialized-length` (back to `int`), run
`KP-TEST negative-integers`, confirm it fails on -1, restore. Remove
`(nsec-of timestamp)` from the sum (leave `0`), run `KP-TEST
timestamp-round-trip`, confirm it fails, restore.

- [ ] **Step 10: Commit**

```bash
git add kyoto-persistence.asd tests/package.lisp \
  tests/serialize-tests.lisp serialize.lisp uuid.lisp
git commit -m "Serialization works: kcmalloc gets sizes; fix integers, timestamps

kcmalloc was passed a pointer to the size, so Kyoto tried to allocate a
memory address's worth of bytes and aborted. Negative integers are
sized by magnitude (-1 came back as 0), and timestamps keep their
nanoseconds; stored timestamps change encoding. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 5: Searching and cutting stored byte sequences

**Files:**
- Create: `tests/buffer-tests.lisp`
- Modify: `kyoto-persistence.asd` (add the file)
- Modify: `utilities.lisp:8-15` (`pointer-search`), `utilities.lisp:42`
  (`extract-subseq`)

**Interfaces:**
- Consumes: Task 4's test package.
- Produces: `extract-subseq` returns a `kcmalloc`'d buffer (release with
  `kcfree`), so `klist-free` (Task 7) frees memory the way it was allocated.

- [ ] **Step 1: Add `"buffer-tests"` to the test system's components**

```lisp
  :components ((:file "package")
               (:file "serialize-tests")
               (:file "buffer-tests"))
```

- [ ] **Step 2: Create `tests/buffer-tests.lisp`**

```lisp
(in-package #:kyoto-persistence-test)

(in-suite :kyoto-persistence)

(defun foreign-octets (&rest bytes)
  "A malloc'd buffer holding BYTES; free it with foreign-free."
  (let ((p (cffi:foreign-alloc :unsigned-char :count (length bytes))))
    (loop for b in bytes
          for i from 0
          do (setf (cffi:mem-aref p :unsigned-char i) b))
    p))

(defun buffer-octets (p n)
  "The first N bytes at P, as a list."
  (loop for i below n collect (cffi:mem-aref p :unsigned-char i)))

(test pointer-search
  "Finds a subsequence's offset, including one ending at the last byte
(the old tp routine, plus that edge)."
  (let ((seq (foreign-octets 0 1 2 3 4 5 6 7 8 9))
        (mid (foreign-octets 1 2 3 4))
        (tail (foreign-octets 7 8 9))
        (absent (foreign-octets 4 3)))
    (unwind-protect
         (progn
           (is (eql 1 (kp::pointer-search mid 4 seq 10)))
           (is (eql 7 (kp::pointer-search tail 3 seq 10)))
           (is (null (kp::pointer-search absent 2 seq 10))))
      (mapc #'cffi:foreign-free (list seq mid tail absent)))))

(test extract-subseq
  "Removes the first occurrence of a subsequence (the old tp2 routine)."
  (let ((seq (foreign-octets 0 1 2 3 4 5 6 7 8 9))
        (cut (foreign-octets 1 2 3 4)))
    (unwind-protect
         (multiple-value-bind (new len) (kp::extract-subseq seq 10 cut 4)
           (is (eql 6 len))
           (is (equal '(0 5 6 7 8 9) (buffer-octets new len)))
           (kyoto-cabinet-ffi:kcfree new))
      (mapc #'cffi:foreign-free (list seq cut)))))
```

- [ ] **Step 3: Run the suite and watch it fail**

Run: `KP-SUITE`
Expected: `pointer-search` fails on the tail case (NIL instead of 7);
everything else passes.

- [ ] **Step 4: Fix `pointer-search` and `extract-subseq`'s allocation**

In `utilities.lisp`, change `pointer-search`'s first line of its body from
`(dotimes (i (- seq-len subseq-len))` to:

```lisp
  (dotimes (i (1+ (- seq-len subseq-len)))
```

In `extract-subseq`, change
`(new-seq (foreign-alloc :unsigned-char :count new-len))` to:

```lisp
                      (new-seq (kcmalloc new-len)))
```

- [ ] **Step 5: Run the suite and watch it pass**

Run: `KP-SUITE`
Expected: exit 0.

- [ ] **Step 6: Mutation check**

Undo the `1+`, run `KP-TEST pointer-search`, confirm it fails, restore.

- [ ] **Step 7: Commit**

```bash
git add tests/buffer-tests.lisp kyoto-persistence.asd utilities.lisp
git commit -m "pointer-search checks the last position; cut buffers via kcmalloc

Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 6: Persistent hash tables

**Files:**
- Create: `tests/phash-tests.lisp`
- Modify: `kyoto-persistence.asd` (add the file)
- Modify: `phash.lisp:30-41` (`map-phash`)

**Interfaces:**
- Consumes: cl-kyoto-cabinet's `iter-item-fast` (Task 2: `:size` slots);
  Task 4's helpers.
- Produces: `map-phash (func phash &key collect?)` unchanged in signature.

- [ ] **Step 1: Add `"phash-tests"` to the test system's components**

```lisp
  :components ((:file "package")
               (:file "serialize-tests")
               (:file "buffer-tests")
               (:file "phash-tests"))
```

- [ ] **Step 2: Create `tests/phash-tests.lisp`**

```lisp
(in-package #:kyoto-persistence-test)

(in-suite :kyoto-persistence)

(defmacro with-temp-phash ((var) &body body)
  "Evaluate BODY with VAR bound to a phash on a fresh file; close and
delete it afterwards."
  (let ((path (gensym "PATH")))
    `(let* ((,path (temp-store-path "kch"))
            (,var (kp:open-phash ,path)))
       (unwind-protect (progn ,@body)
         (ignore-errors (kp:close-phash ,var))
         (when (probe-file ,path) (delete-file ,path))))))

(test size-slots-read-as-size-t
  "map-phash reads Kyoto's size slots as size_t; :unsigned-int read only
half of each (kyoto-persistence#2)."
  (let ((text (with-open-file
                  (in (asdf:system-relative-pathname
                       :kyoto-persistence "phash.lisp"))
                (let ((s (make-string (file-length in))))
                  (subseq s 0 (read-sequence s in))))))
    (is (null (ppcre:all-matches-as-strings
               "mem-ref [\\w-]+ :(?:int|uint32|unsigned-int)\\)" text)))))

(test phash-set-get-map
  "NUL-separated keys, :keep never overwrites, absent keys give NIL, and
map-phash sees every entry (the old phash-test routine)."
  (with-temp-phash (h)
    (let ((keys (loop for i below 10
                      collect (format nil "k~a~c~a" i (code-char 0) i))))
      (loop for k in keys
            for i from 0
            do (kp:set-phash h k i))
      (kp:set-phash h (first keys) 99 :mode :keep)
      (is (eql 0 (kp:get-phash h (first keys))))
      (is (eql 9 (kp:get-phash h (nth 9 keys))))
      (is (null (kp:get-phash h "absent")))
      (let ((seen (kp:map-phash (lambda (k v) (cons k v)) h
                                :collect? t)))
        (is (= 10 (length seen)))
        (is (equal (sort (copy-list keys) #'string<)
                   (sort (mapcar #'car seen) #'string<)))))))

(test phash-remove
  "rem-phash removes a key and leaves the others."
  (with-temp-phash (h)
    (kp:set-phash h "a" 1)
    (kp:set-phash h "b" 2)
    (kp:rem-phash h "a")
    (is (null (kp:get-phash h "a")))
    (is (eql 2 (kp:get-phash h "b")))))
```

- [ ] **Step 3: Run the suite and watch it fail**

Run: `KP-SUITE`
Expected: `size-slots-read-as-size-t` fails, listing the two
`mem-ref ... :unsigned-int)` reads. The phash tests should pass already (the
low half of a little-endian size_t is the right number); if any fails,
diagnose it with superpowers:systematic-debugging before going on.

- [ ] **Step 4: Fix `map-phash`**

In `phash.lisp`, change `(mem-ref key-size :unsigned-int)` and
`(mem-ref val-size :unsigned-int)` to `(mem-ref key-size :size)` and
`(mem-ref val-size :size)`. In the cleanup, change
`(when (pointerp val-ptr) (kcfree val-ptr))` to
`(when (pointerp val-ptr) (foreign-free val-ptr))`: `val-ptr` is the slot
`iter-item-fast` allocated, not Kyoto memory.

- [ ] **Step 5: Run the suite and watch it pass**

Run: `KP-SUITE`
Expected: exit 0.

- [ ] **Step 6: Mutation check**

In `map-phash`, change `(if collect?` to `(if nil` so it never collects; run `KP-TEST phash-set-get-map`;
confirm it fails; restore. Change `rem-phash`'s body to `nil`; run
`KP-TEST phash-remove`; confirm it fails; restore.

- [ ] **Step 7: Commit**

```bash
git add tests/phash-tests.lisp kyoto-persistence.asd phash.lisp
git commit -m "map-phash reads size_t slots and frees what it allocated

Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 7: Duplicate lists in trees, and the README

**Files:**
- Create: `tests/btree-tests.lisp`
- Modify: `kyoto-persistence.asd` (add the file)
- Modify: `kyoto-list.lisp` (`klist-free`, `klist-remove`)
- Modify: `README` (currently empty)
- Delete: `test.lisp`

**Interfaces:**
- Consumes: Tasks 4 to 6.
- Produces: `klist-remove (klist value &optional serializer)` stores the
  shortened list under the klist's key.

- [ ] **Step 1: Add `"btree-tests"` to the test system's components**

```lisp
  :components ((:file "package")
               (:file "serialize-tests")
               (:file "buffer-tests")
               (:file "phash-tests")
               (:file "btree-tests"))
```

- [ ] **Step 2: Create `tests/btree-tests.lisp`**

```lisp
(in-package #:kyoto-persistence-test)

(in-suite :kyoto-persistence)

(test klist-concat-and-remove
  "Values appended under one key read back in order; removing one stores
the list without it (the old klist-test routine)."
  (let* ((path (temp-store-path "kct"))
         (tree (kp:open-btree path :duplicates-allowed? t)))
    (unwind-protect
         (progn
           (dotimes (i 1000)
             (kp:set-btree tree 1 (format nil "V-~a" i) :mode :concat))
           (let ((l (kp:get-btree tree 1 :mode :klist)))
             (unwind-protect
                  (progn
                    (is (equal "V-300" (kp:klist-nth l 300)))
                    (is-true (kp:klist-has-value? l "V-501"))
                    (kp:klist-remove l "V-900"))
               (kp:klist-free l)))
           (let ((l (kp:get-btree tree 1 :mode :klist)))
             (unwind-protect
                  (let ((items (kp:map-klist #'identity l :collect? t)))
                    (is (= 999 (length items)))
                    (is (not (member "V-900" items :test #'equal)))
                    (is (equal "V-999" (car (last items)))))
               (kp:klist-free l))))
      (ignore-errors (kp:close-btree tree))
      (when (probe-file path) (delete-file path)))))
```

- [ ] **Step 3: Run the suite and watch it fail**

Run: `KP-SUITE`
Expected: `klist-concat-and-remove` fails after the removal: the stored list
has 1 item, not 999, because `klist-remove` wrote the removed value back
instead of the shortened list.

- [ ] **Step 4: Fix `klist-remove` and `klist-free`**

In `kyoto-list.lisp`, `klist-remove`: delete the debugging line
`(format t "extract-subseq returned ~A / ~A~%" new-ptr new-len)`, and change
the write-back from

```lisp
               (dbm-put-fast (klist-db klist)
                             (klist-key klist) (klist-key-size klist)
                             value-ptr value-size :mode :replace))))
```

to

```lisp
               (dbm-put-fast (klist-db klist)
                             (klist-key klist) (klist-key-size klist)
                             new-ptr new-len :mode :replace))))
```

In `klist-free`, the second `when` tests the list pointer before freeing the
key; make it test the key:

```lisp
  (when (and (pointerp (klist-key klist))
             (not (null-pointer-p (klist-key klist))))
    (kcfree (klist-key klist))))
```

- [ ] **Step 5: Run the suite and watch it pass**

Run: `KP-SUITE`
Expected: exit 0; all tests pass.

- [ ] **Step 6: Mutation check**

Put `value-ptr value-size` back in the `dbm-put-fast` call, run `KP-TEST
klist-concat-and-remove`, confirm it fails, restore.

- [ ] **Step 7: Delete `test.lisp` and write `README`**

`git rm test.lisp` (its four routines are now `serialize-tests`,
`buffer-tests`, `phash-tests` and `btree-tests`). Write `README`:

```
kyoto-persistence
=================

Persistent Lisp data on Kyoto Cabinet: hash stores (phash), tree stores
with duplicate-value lists (btree, klist), and the serializer that
encodes Lisp values as bytes. Built on cl-kyoto-cabinet.

Limits: timestamps before 1900 are not supported; the integer encoding
holds up to 255 bytes of magnitude.

Testing
-------

Needs Kyoto Cabinet (tested with 1.2.80), SBCL, Quicklisp, and a
cl-kyoto-cabinet checkout beside this one. From this directory:

  sbcl --non-interactive --load ~/quicklisp/setup.lisp \
    --eval '(push (truename "../cl-kyoto-cabinet/") asdf:*central-registry*)' \
    --eval '(push (truename "./") asdf:*central-registry*)' \
    --eval '(ql:quickload :kyoto-persistence/test)' \
    --eval '(asdf:test-system :kyoto-persistence)'

The process exits non-zero if any test fails. Run the suite in its own
process: a memory fault in foreign code takes the whole Lisp down.
```

- [ ] **Step 8: Commit**

```bash
git add tests/btree-tests.lisp kyoto-persistence.asd kyoto-list.lisp \
  README
git commit -m "klist-remove stores the shortened list; README and tests

klist-remove wrote the removed value back instead of the remaining list.
test.lisp's routines are now FiveAM tests. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

(`git rm` already staged the deletion of `test.lisp`.)

---

## Finish

- [ ] Run `CKC-SUITE` and `KP-SUITE` once more, each in a fresh process;
  both exit 0.
- [ ] On kraison/cl-kyoto-cabinet#5, #3 and kraison/kyoto-persistence#2,
  comment `Ready for review:` with the branch and the review command:
  `git -C ~/work/cl-kyoto-cabinet diff master...kc-1.2.80` and
  `git -C ~/work/kyoto-persistence diff master...kc-1.2.80`.
- [ ] Update the tracker (kraison/vivace-cabinet#1): unit 1 awaiting review.
- [ ] Stop. Merging and pushing wait for Kevin's word; the issues close when
  the fixes reach `master` on GitHub, since #3 was reported by someone
  outside who will look there.
