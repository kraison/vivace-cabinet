# Unit 2a: extract the structures from vivace-graph — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** vivace-graph's heap allocator, linear hash, skip list and B+ tree
build as the standalone `vivace-cabinet` system, and their own vivace-graph
tests (adapted) plus new B+ tree tests pass.

**Architecture:** Copy, then trim, from vivace-graph at commit `853df62`,
never touching vivace-graph itself. A small script copies whole top-level
forms by their start line from `git show 853df62:<file>`, so every copied
form is exact and the copy is reproducible. The library is octet-oriented:
vivace-graph's general serializer is not copied; tests carry a tiny codec of
their own. Layers are added bottom-up, one per task, each with its tests.

**Tech Stack:** SBCL, Quicklisp, ASDF, FiveAM, alexandria, bordeaux-threads,
cffi, cl-store, log4cl; tests also use babel and uiop.

**Spec:** `docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`,
section "Unit 2" (Extraction, Layout). Phase split recorded on
kraison/vivace-cabinet#2. The definition-level dependency map this plan
follows was made on 2026-10-16 from vivace-graph `853df62` (read-only).

## Global Constraints

- vivace-graph is never modified: read it only through
  `git -C ~/work/vivace-graph show 853df62:<file>`.
- SBCL only for tests. Copied code keeps its CCL, ECL and LispWorks branches.
- New Lisp code: spaces only, 80 columns, terse comments that point at an
  issue or doc. Copied code is left as it is, long lines included.
- Package `vivace-cabinet`; the copied files' `(in-package :graph-db)` becomes
  `(in-package #:vivace-cabinet)`.
- Work on branch `unit-2a-extraction` in `~/work/vivace-cabinet`, one commit
  per task, explicit `git add` paths, nothing pushed without Kevin's word.
- The repo is public: generic commit messages and issue text.
- Every commit message ends with:

  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ
  ```

## Commands

`VC-SUITE` (whole suite, forced recompile; exit 0 only if all pass):

```bash
cd ~/work/vivace-cabinet && sbcl --noinform --non-interactive \
  --load ~/quicklisp/setup.lisp \
  --eval '(push (truename "./") asdf:*central-registry*)' \
  --eval '(ql:quickload (list :alexandria :bordeaux-threads :cffi :cl-store :log4cl :fiveam :babel) :silent t)' \
  --eval '(asdf:load-system :vivace-cabinet/test :force (list :vivace-cabinet :vivace-cabinet/test))' \
  --eval '(asdf:test-system :vivace-cabinet)'
```

`VC-TEST <name>`: as above with the last `--eval` replaced by
`--eval '(fiveam:run! (quote vivace-cabinet-test::<name>))'` (a test or
suite name).

Logs can contain NUL bytes: read them with `grep -a`. The forced recompile
matters: ASDF judges compiled files by 1-second timestamps, so a fast
mutate-run-restore cycle otherwise runs stale code, and test files
compiled before a library layer existed would keep stale references.

**Mutation checks** in every task: copy the file aside first
(`cp F /tmp/F.keep`), mutate, run, then restore (`cp /tmp/F.keep F`).

`EXTRACT`: `python3 tools/extract-forms.py ~/work/vivace-graph 853df62`
(written in Task 1).

## Review Focus

1. **A copied form that calls something not copied.** The build must report
   no undefined function or variable at the end of compilation; each such
   warning means the copy set is short (all tasks: check the load output).
2. **Directory locations without a trailing slash.** `make-lhash` builds
   paths with both `format "~A/config.dat"` and `merge-pathnames`; a
   location without `/` scatters files into the parent. Tests use directory
   pathnames; the README states the rule (Task 4).
3. **Reopening.** A heap, linear hash or B+ tree written, closed and opened
   again must return the same contents (Tasks 1, 2 and 4 each test reopen).
4. **Removal that rebalances.** Removing many keys from a B+ tree merges
   pages and collapses the root; only vivace-graph's benchmark ever did
   this (Task 4, `bplus-remove-half-then-all`).
5. **Value-qualified removal on the B+ tree,** which compares serialized
   values with the tree's `value-equal` (`equal` by default, which never
   matches two octet vectors) (Task 4, `bplus-remove-by-value`).

## Proposals in this plan for Kevin to approve

- **log4cl is a dependency.** The copied structures make 82 `log:` calls;
  keeping log4cl avoids editing them. (The spec's dependency list did not
  name it.)
- **No general serializer.** vivace-graph's `serialize.lisp` is graph-aware
  and stays behind. The B+ tree's constructor defaults still name
  `serialize`, so callers must pass codecs (the 2b/2c layers will).
- **The buffer pool is replaced by two one-line functions**
  (`get-buffer` makes a byte vector; `get-skip-node-buffer` makes a node).
  vivace-graph only runs the pool inside an open graph.
- **Trimmed as graph-specific:** the skip list's development and benchmark
  functions, the allocator's `test-allocator`, the B+ tree's view-index
  protocol and its graph-codec factory (`make-heap-index`,
  `open-heap-index`).
- **One copied test is dropped:** `list-comparators-are-a-strict-total-order`
  tests vivace-graph's composite-key comparators, which are not copied.
- **On-disk formats stay as vivace-graph wrote them** (heap magic and version
  byte, the linear hash's `struct.dat`), but files are not interchangeable:
  `struct.dat` stores package-qualified symbols.

---

### Task 1: The heap: substrate and allocator

**Files:**
- Create: `vivace-cabinet.asd`, `LICENSE`, `package.lisp`,
  `tools/extract-forms.py`, `docs/provenance.md`
- Create (extracted): `substrate/globals.lisp`, `substrate/conditions.lisp`,
  `substrate/posix.lisp`, `substrate/utilities.lisp`, `substrate/queue.lisp`,
  `substrate/rw-lock.lisp`, `substrate/mmap.lisp`, `substrate/allocator.lisp`
- Create (new): `substrate/buffers.lisp`
- Test: `tests/package.lisp`, `tests/support.lisp`,
  `tests/allocator-tests.lisp` (adapted copy)

**Interfaces:**
- Produces: package `vivace-cabinet`; the heap API copied from vivace-graph:
  `(create-memory location size &key extent-size)`,
  `(open-memory location &key ...)`, `(close-memory m)`,
  `(allocate m size)` → `(values offset size)`, `(free m offset)`,
  `(map-memory fn m &key collect-p include-free-p)`, `get-byte`, `set-byte`,
  `get-bytes`; `(get-buffer n)` → `(simple-array (unsigned-byte 8) (n))`.
  Test package `vivace-cabinet-test` with root suite `vivace-cabinet-suite`,
  `make-temp-directory`, macros `with-temp-directory ((var) &body)` and
  `with-temp-memory ((var &key size) &body)`.

- [ ] **Step 1: Branch**

```bash
cd ~/work/vivace-cabinet && git switch -c unit-2a-extraction
```

- [ ] **Step 2: Write `tools/extract-forms.py`**

```python
#!/usr/bin/env python3
"""Copy top-level forms of FILE at REV in REPO into OUT.

usage: extract-forms.py REPO REV FILE (--only|--except) LINES OUT

LINES is a comma-separated list of 1-based form start lines, or "-".
--only keeps just those forms; --except keeps all forms but those.  A
form's start is its #+/#- line when it has one.  A ;-comment block
directly above a form travels with it.  (in-package ...) forms are
dropped; OUT starts with a provenance line and (in-package
#:vivace-cabinet).  Any LINE that is not a form start is an error.
"""
import subprocess
import sys


def form_spans(text):
    """[(start, end)] 1-based line spans of the top-level forms."""
    spans, i, n, line = [], 0, len(text), 1
    depth, start = 0, None

    def skip_block_comment(i, line):
        level = 1
        i += 2
        while level:
            if text.startswith("|#", i):
                level, i = level - 1, i + 2
            elif text.startswith("#|", i):
                level, i = level + 1, i + 2
            else:
                line += text[i] == "\n"
                i += 1
        return i, line

    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif c == ";":
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("#|", i):
            i, line = skip_block_comment(i, line)
        elif c == '"':
            i += 1
            while text[i] != '"':
                if text[i] == "\\":
                    i += 1
                line += text[i] == "\n"
                i += 1
            i += 1
        elif text.startswith("#\\", i):
            i += 3
            if text[i - 1].isalnum():
                while i < n and (text[i].isalnum() or text[i] in "-_"):
                    i += 1
        elif c == "|":
            i += 1
            while text[i] != "|":
                line += text[i] == "\n"
                i += 1
            i += 1
        elif depth == 0 and text.startswith(("#+", "#-"), i):
            if start is None:
                start = line
            i += 2
            if text[i] == "(":
                d = 0
                while True:
                    d += text[i] == "("
                    d -= text[i] == ")"
                    i += 1
                    if d == 0:
                        break
            else:
                while i < n and not text[i].isspace() and text[i] != "(":
                    i += 1
        elif c == "(":
            if depth == 0 and start is None:
                start = line
            depth += 1
            i += 1
        elif c == ")":
            depth -= 1
            i += 1
            if depth == 0:
                spans.append((start, line))
                start = None
        else:
            i += 1
    return spans


def with_comments(lines, start):
    """START moved up over a ;-comment block directly above it."""
    while start > 1 and lines[start - 2].lstrip().startswith(";"):
        start -= 1
    return start


def main():
    repo, rev, path, mode, wanted, out = sys.argv[1:7]
    text = subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"],
                          check=True, capture_output=True,
                          text=True).stdout
    lines = text.split("\n")
    spans = form_spans(text)
    starts = {s for s, _ in spans}
    want = set() if wanted == "-" else {int(x) for x in wanted.split(",")}
    bad = sorted(want - starts)
    if bad:
        sys.exit(f"{path}: not form starts: {bad}")
    pkg = [(s, e) for s, e in spans
           if lines[s - 1].lstrip().lower().startswith("(in-package")]
    keep = [(s, e) for s, e in spans if (s, e) not in pkg
            and ((s in want) == (mode == "--only"))]
    head = [f";;;; Copied from vivace-graph {path} at {rev} ({mode}"
            f" {wanted}).", ";;;; See docs/provenance.md.", "",
            "(in-package #:vivace-cabinet)", ""]
    body = []
    for s, e in keep:
        body.append("\n".join(lines[with_comments(lines, s) - 1:e]))
        print(f"  kept {s}-{e}: {lines[s - 1][:60]}")
    for s, e in spans:
        if (s, e) not in keep and (s, e) not in pkg:
            print(f"  DROPPED {s}-{e}: {lines[s - 1][:60]}")
    with open(out, "w") as f:
        f.write("\n".join(head) + "\n\n".join(body) + "\n")


main()
```

- [ ] **Step 3: Write `LICENSE`**

```
vivace-cabinet Copyright (c) 2026 Kevin Thomas Raison
Portions copied from VivaceGraph, Copyright (c) 2026 Kevin Thomas Raison.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

(Check the MIT text against `git -C ~/work/vivace-graph show
853df62:LICENSE` and use its wording if it differs.)

- [ ] **Step 4: Write `package.lisp`**

```lisp
;;;; The vivace-cabinet package.  Its :use and shadowing follow
;;;; vivace-graph's graph-db package (package.lisp at 853df62), which the
;;;; copied code was written against.

(defpackage #:vivace-cabinet
  (:use #:cl #:bordeaux-threads)
  #+sbcl (:shadowing-import-from #:sb-ext #:word)
  #+ccl (:shadowing-import-from #:closer-mop
         #:standard-method #:finalize-inheritance
         #:standard-generic-function #:defmethod #:defgeneric
         #:standard-class #:compute-discriminating-function
         #:compute-applicable-methods-using-classes
         #:compute-effective-method #:method-function
         #:make-method-lambda))
```

- [ ] **Step 5: Write `vivace-cabinet.asd` with no substrate yet**

```lisp
(defsystem "vivace-cabinet"
  :description "A Kyoto Cabinet-style key-value store in Common Lisp, built
from vivace-graph's on-disk structures."
  :author "Kevin Raison"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria" "bordeaux-threads" "cffi" "cl-store" "log4cl"
               #+(or ccl lispworks) "closer-mop")
  :serial t
  :components ((:file "package"))
  :in-order-to ((test-op (test-op "vivace-cabinet/test"))))

(defsystem "vivace-cabinet/test"
  :description "FiveAM tests for vivace-cabinet."
  :depends-on ("vivace-cabinet" "fiveam" "babel" "uiop")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "allocator-tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call
                      :fiveam :run!
                      (uiop:find-symbol* :vivace-cabinet-suite
                                         :vivace-cabinet-test))
               (error "vivace-cabinet tests failed"))))
```

- [ ] **Step 6: Write `tests/package.lisp`**

```lisp
(defpackage #:vivace-cabinet-test
  (:use #:cl #:fiveam))

(in-package #:vivace-cabinet-test)

;; The copied tests name library internals unqualified, as vivace-graph's
;; test package imported them: import every VIVACE-CABINET symbol that
;; does not clash with CL or FiveAM.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((test (find-package '#:vivace-cabinet-test))
        (lib (find-package '#:vivace-cabinet)))
    (do-symbols (s lib)
      (when (and (eq (symbol-package s) lib)
                 (not (find-symbol (symbol-name s) test)))
        (import s test)))))

(def-suite vivace-cabinet-suite :description "vivace-cabinet tests")
```

- [ ] **Step 7: Write `tests/support.lisp`**

```lisp
(in-package #:vivace-cabinet-test)

;;; Fixtures adapted from vivace-graph tests/suite.lisp at 853df62.

(defun make-temp-directory ()
  "A fresh, empty directory under the system temp directory."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames
               (format nil "vivace-cabinet-test-~36r"
                       (random (expt 36 10) (make-random-state t)))
               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-temp-directory ((var) &body body)
  "Bind VAR to a fresh directory, run BODY, then delete the tree."
  `(let ((,var (make-temp-directory)))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,var :validate t
                                        :if-does-not-exist :ignore))))

(defmacro with-temp-memory ((var &key (size '(* 1024 1024 64))) &body body)
  "Bind VAR to a fresh MEMORY backed by a temp file, run BODY, then close
it and remove the directory."
  (let ((dir (gensym "DIR")))
    `(with-temp-directory (,dir)
       (let ((,var (create-memory
                    (namestring (merge-pathnames "heap.dat" ,dir)) ,size)))
         (unwind-protect (progn ,@body)
           (ignore-errors (close-memory ,var)))))))
```

- [ ] **Step 8: Copy and adapt the allocator tests**

```bash
cd ~/work/vivace-cabinet
{ echo ";;;; Adapted from vivace-graph tests/allocator-tests.lisp at 853df62."
  echo ";;;; See docs/provenance.md."
  git -C ~/work/vivace-graph show 853df62:tests/allocator-tests.lisp \
  | sed -e 's/(in-package #:graph-db\/test)/(in-package #:vivace-cabinet-test)/' \
        -e 's/graph-db-suite/vivace-cabinet-suite/g' \
        -e 's/graph-db::/vivace-cabinet::/g'
} > tests/allocator-tests.lisp
grep -n 'graph-db' tests/allocator-tests.lisp || echo "no graph-db left"
grep -c '^(test ' tests/allocator-tests.lisp
```

Expected: "no graph-db left"; 11 tests.

- [ ] **Step 9: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit. The test files compile with undefined-function
warnings (`create-memory`, `allocate`, ...), and the 11 allocator tests fail
with `UNDEFINED-FUNCTION` errors.

- [ ] **Step 10: Extract the substrate**

```bash
cd ~/work/vivace-cabinet && mkdir -p substrate
X="python3 tools/extract-forms.py $HOME/work/vivace-graph 853df62"
$X globals.lisp --only 17,49,54,118,127,128,129,130,131,134,137,138,139,140,160,162,334,407 substrate/globals.lisp
$X conditions.lisp --only 31,39,170,178 substrate/conditions.lisp
$X posix.lisp --only 28,33,34,35,37,38,49,50,51,53,54,55,56,57,84,87,90,96,100,103,156,159,165,177,187,200,216,219,235,267 substrate/posix.lisp
$X utilities.lisp --only 250,255,258,533,538,543,547,551,560 substrate/utilities.lisp
$X queue.lisp --except - substrate/queue.lisp
$X rw-lock.lisp --except - substrate/rw-lock.lisp
$X mmap.lisp --only 3,4,8,10,41,43,45,48,69,70,81,87,88,98,103,110,129,135,138,220,226,250,542,550,559,567,574,580,584 substrate/mmap.lisp
$X allocator.lisp --except 329 substrate/allocator.lisp
```

Each run lists the forms it kept and dropped; read the lists. Every
requested line must be a form start, or the script stops.

- [ ] **Step 11: Write `substrate/buffers.lisp`**

```lisp
;;;; Stand-ins for vivace-graph's buffer pool (buffer-pool.lisp at
;;;; 853df62), which only runs inside an open graph; without it these are
;;;; exactly what vivace-graph's functions return.

(in-package #:vivace-cabinet)

(defun get-buffer (size)
  "A fresh byte vector of SIZE."
  (make-byte-vector size))

(defun get-skip-node-buffer ()
  "A fresh skip-list node (defined in structures/skip-list.lisp)."
  (%make-skip-node))
```

- [ ] **Step 12: Add the substrate to the system**

In `vivace-cabinet.asd`, replace `:components ((:file "package"))` in the
library system with:

```lisp
  :components ((:file "package")
               (:module "substrate"
                :serial t
                :components ((:file "globals")
                             (:file "conditions")
                             (:file "posix")
                             (:file "utilities")
                             (:file "queue")
                             #+(or sbcl lispworks ecl) (:file "rw-lock")
                             (:file "mmap")
                             (:file "buffers")
                             (:file "allocator"))))
```

- [ ] **Step 13: Run the suite and watch it pass**

Run: `VC-SUITE`
Expected: exit 0; the 11 allocator tests pass. In the load output, no full
`WARNING` and no undefined variable. The only undefined function allowed is
`%MAKE-SKIP-NODE` (from `buffers.lisp`; defined in Task 3). Any other
undefined name means a substrate form is missing: find its start line in
the vivace-graph file, add it to that file's `--only` list in Step 10,
re-run the extraction, and record the addition in `docs/provenance.md`.

- [ ] **Step 14: Mutation check**

In `substrate/allocator.lisp`, make `normalize-allocation-data-size` return
its argument unchanged (`(defun normalize-allocation-data-size (size) size)`
in place of the body). Run `VC-TEST allocator-suite`; confirm failures;
restore.

- [ ] **Step 15: Write `docs/provenance.md`**

```markdown
# Provenance

Code under `substrate/` and `structures/` is copied from
[vivace-graph](https://github.com/kraison/vivace-graph) at commit
`853df62` (branch `experiment`, 2026-10-07), by `tools/extract-forms.py`,
which copies whole top-level forms by their start line. Each copied file
names its source in its first line. vivace-graph itself is not changed.

| vivace-cabinet file | vivace-graph source | What was copied |
|---|---|---|
| substrate/globals.lisp | globals.lisp | ECL feature gates, `*cache-enabled*`, heap and linear-hash constants, mmap reservation parameters, `+skip-list+`, `*max-locks*` |
| substrate/conditions.lisp | conditions.lisp | serialization, deserialization, duplicate-key and nonexistent-key conditions |
| substrate/posix.lisp | posix.lisp | open, close, lseek, write, file extension, fchmod, mmap, munmap, msync, file size; their constants |
| substrate/utilities.lisp | utilities.lisp | `proper-listp`, `make-byte-vector`, `with-gensyms`, CCL rw-lock shims |
| substrate/queue.lisp | queue.lisp | whole file |
| substrate/rw-lock.lisp | rw-lock.lisp | whole file |
| substrate/mmap.lisp | mmap.lisp | mapped files, byte access, uint64 and pointer codecs; not the segment machinery |
| substrate/buffers.lisp | (new) | stand-ins for buffer-pool.lisp's `get-buffer` and `get-skip-node-buffer` |
| substrate/allocator.lisp | allocator.lisp | all but `test-allocator` |
| tests/allocator-tests.lisp | tests/allocator-tests.lisp | adapted: package and suite names |
| tests/support.lisp | tests/suite.lisp | fixtures, adapted |

Trimmed as graph-specific or unused: vivace-graph's `serialize.lisp`,
`segment.lisp`, `node-id.lisp`, `pcons.lisp`, the buffer pool, and the
development functions in the files above.
```

- [ ] **Step 16: Commit**

```bash
cd ~/work/vivace-cabinet
git add vivace-cabinet.asd LICENSE package.lisp tools/extract-forms.py \
  docs/provenance.md substrate/*.lisp tests/package.lisp \
  tests/support.lisp tests/allocator-tests.lisp
git commit -m "The heap: substrate and allocator copied from vivace-graph

Forms copied from vivace-graph 853df62 by tools/extract-forms.py; the
allocator's own tests, adapted, pass. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 2: The linear hash

**Files:**
- Create (extracted): `structures/hash-key.lisp`,
  `structures/linear-hash.lisp`, `structures/cl-store-ecl.lisp`
- Modify: `vivace-cabinet.asd`, `tests/support.lisp`, `docs/provenance.md`
- Test: `tests/linear-hash-tests.lisp` (adapted copy)

**Interfaces:**
- Consumes: Task 1's heap, mmap and lock substrate; test fixtures.
- Produces: `(make-lhash &key location buckets test key-bytes value-bytes
  ...)`, `(open-lhash location)`, `(close-lhash h)`, `(delete-lhash h)`,
  `(lhash-insert h key val)`, `(lhash-get h key)`, `(lhash-update h key
  val)`, `(lhash-remove h key)`, `(map-lhash fn h &key collect-p)`,
  `(read-lhash-count h)`. Keys are 16-byte octet vectors (not all zero);
  values unsigned 64-bit integers. Test support: `(gen-id)`,
  `with-temp-lhash ((var &rest make-args) &body)`.

- [ ] **Step 1: Add test fixtures to `tests/support.lisp`**

Append:

```lisp
(defun gen-id ()
  "A random 16-byte key whose first byte is non-zero: all-zero keys mark
empty slots in the linear hash.  (vivace-graph used a v4 UUID.)"
  (let ((id (make-array 16 :element-type '(unsigned-byte 8))))
    (dotimes (i 16)
      (setf (aref id i) (random 256)))
    (setf (aref id 0) (1+ (random 255)))
    id))

(defmacro with-temp-lhash ((var &rest make-args) &body body)
  "Bind VAR to a fresh LHASH in a temp directory, run BODY, then close it
and remove the directory.  MAKE-ARGS go to MAKE-LHASH."
  (let ((dir (gensym "DIR")))
    `(with-temp-directory (,dir)
       (let ((,var (make-lhash :location ,dir ,@make-args)))
         (unwind-protect (progn ,@body)
           (ignore-errors (close-lhash ,var)))))))
```

- [ ] **Step 2: Copy and adapt the linear-hash tests**

```bash
cd ~/work/vivace-cabinet
{ echo ";;;; Adapted from vivace-graph tests/linear-hash-tests.lisp at 853df62."
  echo ";;;; See docs/provenance.md."
  git -C ~/work/vivace-graph show 853df62:tests/linear-hash-tests.lisp \
  | sed -e 's/(in-package #:graph-db\/test)/(in-package #:vivace-cabinet-test)/' \
        -e 's/graph-db-suite/vivace-cabinet-suite/g' \
        -e 's/graph-db::/vivace-cabinet::/g'
} > tests/linear-hash-tests.lisp
grep -n 'graph-db' tests/linear-hash-tests.lisp || echo "no graph-db left"
grep -c '^(test ' tests/linear-hash-tests.lisp
```

Expected: "no graph-db left"; 14 tests. Then fix the copied
`reopen-preserves-contents`, which never closes its second handle (its file
descriptor and mappings leak for the life of the image): replace its
`(let ((h2 (open-lhash dir))) ...)` form with

```lisp
      (let ((h2 (open-lhash dir)))
        (unwind-protect
             (progn
               (is (= 30 (read-lhash-count h2)))
               (loop for (k . v) in entries
                     do (is (= v (lhash-get h2 k)))))
          (close-lhash h2)))
```

Add `(:file "linear-hash-tests")` after `(:file "allocator-tests")` in the
test system's components.

- [ ] **Step 3: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 14 linear-hash tests fail with
`UNDEFINED-FUNCTION` (`make-lhash`, ...); the allocator tests still pass.

- [ ] **Step 4: Extract the linear hash**

```bash
cd ~/work/vivace-cabinet && mkdir -p structures
X="python3 tools/extract-forms.py $HOME/work/vivace-graph 853df62"
$X primitive-node.lisp --only 606 structures/hash-key.lisp
$X linear-hash.lisp --except - structures/linear-hash.lisp
$X cl-store-ecl.lisp --except - structures/cl-store-ecl.lisp
```

Then insert the generic `%hash` needs (vivace-graph creates it implicitly
through an unrelated `defmethod`) after the `(in-package ...)` line of
`structures/hash-key.lisp`:

```lisp
(defgeneric %hash (key)
  (:documentation "The linear hash's bucket hash of KEY, a 16-byte octet
vector.  Part of the on-disk format: do not change."))
```

- [ ] **Step 5: Add the structures module to the system**

In `vivace-cabinet.asd`, after the `"substrate"` module, add:

```lisp
               (:module "structures"
                :serial t
                :components (#+ecl (:file "cl-store-ecl")
                             (:file "hash-key")
                             (:file "linear-hash")))
```

- [ ] **Step 6: Run the suite and watch it pass**

Run: `VC-SUITE`
Expected: exit 0; 11 allocator and 14 linear-hash tests pass. No undefined
name other than `%MAKE-SKIP-NODE`. Handle any other as in Task 1 Step 13.

- [ ] **Step 7: Mutation check**

In `structures/linear-hash.lisp`, make `read-lhash-count` return 0 (replace
its body with `0`). Run `VC-TEST linear-hash-suite`; confirm failures;
restore.

- [ ] **Step 8: Provenance rows**

Add to the table in `docs/provenance.md`:

```markdown
| structures/hash-key.lisp | primitive-node.lisp | the 16-byte `%hash` method, plus an explicit `defgeneric` |
| structures/linear-hash.lisp | linear-hash.lisp | whole file |
| structures/cl-store-ecl.lisp | cl-store-ecl.lisp | whole file (ECL only) |
| tests/linear-hash-tests.lisp | tests/linear-hash-tests.lisp | adapted: package and suite names; `reopen-preserves-contents` closes its second handle |
```

- [ ] **Step 9: Commit**

```bash
git add structures/hash-key.lisp structures/linear-hash.lisp \
  structures/cl-store-ecl.lisp vivace-cabinet.asd tests/support.lisp \
  tests/linear-hash-tests.lisp docs/provenance.md
git commit -m "The linear hash, copied from vivace-graph

Its own tests, adapted, pass. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 3: The skip list

**Files:**
- Create (extracted): `structures/cursors.lisp`, `structures/skip-list.lisp`,
  `structures/skip-list-cursors.lisp`
- Modify: `vivace-cabinet.asd`, `tests/support.lisp`, `docs/provenance.md`
- Test: `tests/skip-list-tests.lisp` (adapted copy)

**Interfaces:**
- Consumes: Task 1's heap; `get-skip-node-buffer` (now resolvable).
- Produces: `(make-skip-list &key heap key-equal key-comparison head-key
  head-value tail-key tail-value key-serializer key-deserializer
  value-serializer value-deserializer duplicates-allowed-p value-equal)`,
  `open-skip-list`, `close-skip-list`, `delete-skip-list`,
  `add-to-skip-list`, `find-in-skip-list`, `update-in-skip-list`,
  `remove-from-skip-list`, cursors (`make-cursor`, `make-keys-cursor`,
  `make-values-cursor`, `make-range-cursor`, `cursor-next`), `map-skip-list`.
  Every codec argument must be given (omitted ones become NIL). A key
  deserializer returns `(values key bytes-used)`. Test support:
  `(test-serialize object)` → octets, `(test-deserialize octets)` →
  `(values object bytes-used)`, `(make-integer-skip-list heap &key
  duplicates-allowed-p)`.

- [ ] **Step 1: Add the test codec and builder to `tests/support.lisp`**

Append:

```lisp
(defun test-serialize (object)
  "OBJECT's printed form as UTF-8 after a 4-byte length.  A stand-in for
vivace-graph's serializer, which is not copied."
  (let* ((text (babel:string-to-octets (prin1-to-string object)
                                       :encoding :utf-8))
         (n (length text))
         (out (make-array (+ 4 n) :element-type '(unsigned-byte 8))))
    (setf (aref out 0) (ldb (byte 8 24) n)
          (aref out 1) (ldb (byte 8 16) n)
          (aref out 2) (ldb (byte 8 8) n)
          (aref out 3) (ldb (byte 8 0) n))
    (replace out text :start1 4)
    out))

(defun test-deserialize (octets)
  "The object TEST-SERIALIZE wrote at the start of OCTETS, and the number
of bytes it used."
  (let ((n (logior (ash (aref octets 0) 24) (ash (aref octets 1) 16)
                   (ash (aref octets 2) 8) (aref octets 3))))
    (values (let ((*read-eval* nil))
              (read-from-string
               (babel:octets-to-string octets :start 4 :end (+ 4 n)
                                              :encoding :utf-8)))
            (+ 4 n))))

(defun make-integer-skip-list (heap &key duplicates-allowed-p)
  "An integer-keyed skip list over HEAP, keys and values encoded by
TEST-SERIALIZE (vivace-graph used its general serializer here)."
  (make-skip-list :heap heap
                  :head-key most-negative-fixnum :head-value 0
                  :tail-key most-positive-fixnum :tail-value 0
                  :key-equal '= :key-comparison '<
                  :key-serializer 'test-serialize
                  :key-deserializer 'test-deserialize
                  :value-serializer 'test-serialize
                  :value-deserializer 'test-deserialize
                  :value-equal 'equal
                  :duplicates-allowed-p duplicates-allowed-p))
```

- [ ] **Step 2: Copy and adapt the skip-list tests**

```bash
cd ~/work/vivace-cabinet
{ echo ";;;; Adapted from vivace-graph tests/skip-list-tests.lisp at 853df62."
  echo ";;;; See docs/provenance.md."
  git -C ~/work/vivace-graph show 853df62:tests/skip-list-tests.lisp \
  | sed -e 's/(in-package #:graph-db\/test)/(in-package #:vivace-cabinet-test)/' \
        -e 's/graph-db-suite/vivace-cabinet-suite/g' \
        -e 's/graph-db::/vivace-cabinet::/g'
} > tests/skip-list-tests.lisp
```

Delete the test `list-comparators-are-a-strict-total-order` (the whole
`(test list-comparators-are-a-strict-total-order ...)` form): it tests
vivace-graph's `less-than` and `greater-than`, which are not copied. Then:

```bash
grep -n 'graph-db\|less-than\|greater-than' tests/skip-list-tests.lisp \
  || echo "clean"
grep -c '^(test ' tests/skip-list-tests.lisp
```

Expected: "clean"; 24 tests. Add `(:file "skip-list-tests")` after
`"linear-hash-tests"` in the test system's components.

- [ ] **Step 3: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 24 skip-list tests fail with
`UNDEFINED-FUNCTION` (`make-skip-list`, ...); earlier suites pass.

- [ ] **Step 4: Extract the skip list**

```bash
cd ~/work/vivace-cabinet
X="python3 tools/extract-forms.py $HOME/work/vivace-graph 853df62"
$X cursors.lisp --except - structures/cursors.lisp
$X skip-list.lisp --except 937,968,975,981,1024,1078,1117 structures/skip-list.lisp
$X skip-list-cursors.lisp --except - structures/skip-list-cursors.lisp
```

The `--except` list drops the development and benchmark functions
(`sl-test`, `string-uuid`, `nshuffle`, `sl-perf-test`, `sl-string-test`,
`sl-dup-test`, `sl-corruption-test`).

- [ ] **Step 5: Add them to the structures module**

```lisp
                :components (#+ecl (:file "cl-store-ecl")
                             (:file "hash-key")
                             (:file "linear-hash")
                             (:file "cursors")
                             (:file "skip-list")
                             (:file "skip-list-cursors")))
```

- [ ] **Step 6: Run the suite and watch it pass**

Run: `VC-SUITE`
Expected: exit 0; allocator 11, linear-hash 14 and skip-list 24 tests pass;
no undefined names at all.

- [ ] **Step 7: Mutation check**

In `structures/skip-list-cursors.lisp`, make the `cursor-next` method
return its EOC argument at once (replace its body with `eoc`). Run
`VC-TEST skip-list-suite`; confirm failures; restore.

- [ ] **Step 8: Provenance rows**

```markdown
| structures/cursors.lisp | cursors.lisp | whole file |
| structures/skip-list.lisp | skip-list.lisp | all but the development and benchmark functions |
| structures/skip-list-cursors.lisp | skip-list-cursors.lisp | whole file |
| tests/skip-list-tests.lisp | tests/skip-list-tests.lisp | adapted: package and suite names; `list-comparators-are-a-strict-total-order` dropped (tests code not copied); keys and values use a test codec |
```

- [ ] **Step 9: Commit**

```bash
git add structures/cursors.lisp structures/skip-list.lisp \
  structures/skip-list-cursors.lisp vivace-cabinet.asd tests/support.lisp \
  tests/skip-list-tests.lisp docs/provenance.md
git commit -m "The skip list and its cursors, copied from vivace-graph

Its own tests, adapted, pass. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

### Task 4: The B+ tree, and the README

**Files:**
- Create (extracted): `structures/bplus-tree.lisp`
- Create: `tests/bplus-tree-tests.lisp`, `README.md`
- Modify: `vivace-cabinet.asd`, `docs/provenance.md`

**Interfaces:**
- Consumes: Tasks 1 and 3 (the B+ tree specializes the skip list's
  generics and makes `skip-node`s).
- Produces: `(make-bplus-tree &key heap key-comparison key-equal
  value-equal key-serializer key-deserializer value-serializer
  value-deserializer page-size)`, `(open-bplus-tree &key address heap
  ...)`, `bplus-tree-count`, `delete-bplus-tree`, `%bpt-address`, and the
  skip-list generics on it: `add-to-skip-list` (NIL for a duplicate key),
  `find-in-skip-list` → `(values node 0)` or `(values nil -1)`,
  `remove-from-skip-list (tree key &optional value)`, `update-in-skip-list`,
  `make-cursor`, `make-range-cursor` (inclusive), `cursor-next`.

- [ ] **Step 1: Write `tests/bplus-tree-tests.lisp`**

```lisp
(in-package #:vivace-cabinet-test)

;;; New: vivace-graph tested its B+ tree only through graph indexes and a
;;; benchmark (tests/perf/bplus-bench.lisp at 853df62).

(def-suite bplus-tree-suite
  :description "B+ tree insert / find / remove / cursors / reopen."
  :in vivace-cabinet-suite)

(in-suite bplus-tree-suite)

(defun integer-bplus-tree-args ()
  (list :key-comparison '< :key-equal '= :value-equal 'equal
        :key-serializer 'test-serialize :key-deserializer 'test-deserialize
        :value-serializer 'test-serialize
        :value-deserializer 'test-deserialize))

(defun make-integer-bplus-tree (heap)
  (apply #'make-bplus-tree :heap heap (integer-bplus-tree-args)))

(defun tree-value (tree key)
  "KEY's value in TREE, or NIL."
  (let ((node (find-in-skip-list tree key)))
    (and node (%sn-value node))))

(defun cursor-keys (cursor)
  (loop for node = (cursor-next cursor :eoc)
        until (eq node :eoc)
        collect (%sn-key node)))

(test bplus-insert-find
  "Inserted keys are found with their values; a duplicate key is refused."
  (with-temp-memory (heap)
    (let ((tree (make-integer-bplus-tree heap))
          (keys (alexandria:shuffle (loop for i from 1 to 200 collect i))))
      (dolist (k keys)
        (is-true (add-to-skip-list tree k (format nil "v~a" k))))
      (is (= 200 (bplus-tree-count tree)))
      (dolist (k keys)
        (is (equal (format nil "v~a" k) (tree-value tree k))))
      (is (null (add-to-skip-list tree 7 "again")))
      (is (equal "v7" (tree-value tree 7)))
      (is (null (tree-value tree 1000))))))

(test bplus-cursors-are-ordered
  "A full cursor yields every key in order; a range cursor is inclusive."
  (with-temp-memory (heap)
    (let ((tree (make-integer-bplus-tree heap))
          (keys (remove-duplicates
                 (loop repeat 5000 collect (random 100000)))))
      (dolist (k keys)
        (add-to-skip-list tree k "x"))
      (let ((sorted (sort (copy-list keys) #'<)))
        (is (equal sorted (cursor-keys (make-cursor tree))))
        (is (equal (remove-if-not (lambda (k) (<= 100 k 20000)) sorted)
                   (cursor-keys (make-range-cursor tree 100 20000))))))))

(test bplus-remove-half-then-all
  "Removing half the keys, then the rest, merges pages and collapses the
root; the tree stays correct and usable throughout."
  (with-temp-memory (heap)
    (let* ((tree (make-integer-bplus-tree heap))
           (keys (alexandria:shuffle (loop for i below 20000 collect i)))
           (gone (remove-if-not #'evenp keys))
           (kept (sort (remove-if #'evenp keys) #'<)))
      (dolist (k keys)
        (add-to-skip-list tree k (format nil "v~a" k)))
      (dolist (k gone)
        (is-true (remove-from-skip-list tree k)))
      (is (= 10000 (bplus-tree-count tree)))
      (is (equal kept (cursor-keys (make-cursor tree))))
      (is (null (tree-value tree 4)))
      (is (equal "v5" (tree-value tree 5)))
      (dolist (k kept)
        (remove-from-skip-list tree k))
      (is (= 0 (bplus-tree-count tree)))
      (is (null (cursor-keys (make-cursor tree))))
      (is-true (add-to-skip-list tree 1 "again"))
      (is (equal "again" (tree-value tree 1))))))

(test bplus-update
  "update-in-skip-list replaces a key's value."
  (with-temp-memory (heap)
    (let ((tree (make-integer-bplus-tree heap)))
      (add-to-skip-list tree 3 "old")
      (update-in-skip-list tree 3 "new")
      (is (equal "new" (tree-value tree 3)))
      (is (= 1 (bplus-tree-count tree))))))

(test bplus-remove-by-value
  "Removing with a value removes only when the stored value matches."
  (with-temp-memory (heap)
    (let ((tree (make-integer-bplus-tree heap)))
      (add-to-skip-list tree 9 "v")
      (is (null (remove-from-skip-list tree 9 "w")))
      (is (equal "v" (tree-value tree 9)))
      (is-true (remove-from-skip-list tree 9 "v"))
      (is (null (tree-value tree 9))))))

(test bplus-reopen
  "A tree written, closed with its heap, and reopened has its contents."
  (with-temp-directory (dir)
    (let* ((path (namestring (merge-pathnames "heap.dat" dir)))
           (heap (create-memory path (* 1024 1024 64)))
           (tree (make-integer-bplus-tree heap))
           (address (%bpt-address tree)))
      (dotimes (k 3000)
        (add-to-skip-list tree k (format nil "v~a" k)))
      (close-memory heap)
      (let* ((heap2 (open-memory path))
             (tree2 (apply #'open-bplus-tree :address address :heap heap2
                           (integer-bplus-tree-args))))
        (unwind-protect
             (progn
               (is (= 3000 (bplus-tree-count tree2)))
               (is (equal "v1234" (tree-value tree2 1234))))
          (close-memory heap2))))))
```

Add `(:file "bplus-tree-tests")` after `"skip-list-tests"` in the test
system's components.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `VC-SUITE`
Expected: non-zero exit; the 6 B+ tree tests fail with
`UNDEFINED-FUNCTION` (`make-bplus-tree`, ...); earlier suites pass.

- [ ] **Step 3: Extract the B+ tree**

```bash
cd ~/work/vivace-cabinet
python3 tools/extract-forms.py $HOME/work/vivace-graph 853df62 \
  bplus-tree.lisp --except 979,987,992,997,1014,1055 \
  structures/bplus-tree.lisp
```

This drops the view-index protocol (`view-index-p`, `view-index-address`,
`delete-view-index`, `view-index-backend-tag`) and the graph-codec factory
(`make-heap-index`, `open-heap-index`). Add `(:file "bplus-tree")` after
`"skip-list-cursors"` in the structures module.

- [ ] **Step 4: Run the suite**

Run: `VC-SUITE`
Expected: `bplus-insert-find`, `bplus-cursors-are-ordered`,
`bplus-remove-half-then-all`, `bplus-update` and `bplus-reopen` pass.
`bplus-remove-by-value` fails: its value-qualified remove compares the
serialized values with `equal`, which never matches two octet vectors, so
the matching remove returns NIL. If it passes instead, the comparison is on
deserialized values: skip Step 5, and record that in the commit message.

- [ ] **Step 5: Compare serialized values as octets**

In `structures/bplus-tree.lisp`, replace the `remove-from-skip-list` method
on `bplus-tree` with:

```lisp
(defmethod remove-from-skip-list ((tree bplus-tree) key
                                  &optional (value nil value-p))
  (if value-p
      ;; Stored values are compared serialized: as octets.  EQUAL, the
      ;; tree's default VALUE-EQUAL, never matches two octet vectors.
      (bpt-remove tree key (funcall (%bpt-value-serializer tree) value)
                  #'equalp)
      (bpt-remove tree key)))
```

Run: `VC-SUITE`
Expected: exit 0; all 6 B+ tree tests pass (55 tests in all: 11 + 14 + 24 +
6); no undefined names.

- [ ] **Step 6: Mutation check**

Make `bplus-tree-count` return 0; run `VC-TEST bplus-tree-suite`; confirm
failures; restore. Revert Step 5's `#'equalp` to the original call
(`(bpt-remove tree key (funcall (%bpt-value-serializer tree) value))`); run
`VC-TEST bplus-remove-by-value`; confirm it fails; restore.

- [ ] **Step 7: Write `README.md`**

```markdown
# vivace-cabinet

A Kyoto Cabinet-style key-value store in Common Lisp, built from
[vivace-graph](https://github.com/kraison/vivace-graph)'s on-disk
structures: a memory-mapped heap, a linear hash, a skip list and a B+ tree.
The design is in `docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`.

**Status:** the structures are extracted and tested on their own (unit 2a).
The Kyoto-style API (`open-db`, `db-set`, `db-get`, ...) comes next.

## Limits

- **No crash safety.** Writes go straight to shared memory maps and reach
  disk on close; a crash mid-write can leave a structure inconsistent.
- **Address space.** Each mapped file reserves 8 times its size, at least
  1 GiB, of virtual address space: about 17 GiB per linear hash and 1 GiB
  per heap. Limits on address space (`ulimit -v`) count these.
- **Locations are directories ending in `/`.** The linear hash builds file
  names both ways; a location without the slash scatters its files.
- **Tested on SBCL only.** The copied code keeps its CCL, ECL and LispWorks
  branches, untested here.
- **Files are not interchangeable with vivace-graph's**: the linear hash's
  `struct.dat` stores package-qualified symbols.

## Testing

From this directory, with Quicklisp:

    sbcl --non-interactive --load ~/quicklisp/setup.lisp \
      --eval '(push (truename "./") asdf:*central-registry*)' \
      --eval '(ql:quickload :vivace-cabinet/test)' \
      --eval '(asdf:test-system :vivace-cabinet)'

The process exits non-zero if any test fails.

## Provenance and licence

Copied code, and exactly what was copied, is listed in
`docs/provenance.md`. MIT licence; see `LICENSE`.
```

- [ ] **Step 8: Provenance rows**

```markdown
| structures/bplus-tree.lisp | bplus-tree.lisp | all but the view-index protocol and the graph-codec factory; value-qualified removal compares octets with `equalp` (if Task 4 Step 5 applied) |
| tests/bplus-tree-tests.lisp | (new) | B+ tree tests; vivace-graph tested it only through graph indexes and a benchmark |
```

- [ ] **Step 9: Commit**

```bash
git add structures/bplus-tree.lisp tests/bplus-tree-tests.lisp \
  vivace-cabinet.asd README.md docs/provenance.md
git commit -m "The B+ tree, copied from vivace-graph, with its own tests

vivace-graph tested the B+ tree only through graph indexes; it now has
structure-level tests, including merges and reopening. Value-qualified
removal compares serialized values as octets. README added. Part of #2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UMzK3UdPJGTLFA4rdQW8wJ"
```

---

## Finish

- [ ] `VC-SUITE` once more in a fresh process: exit 0, 55 tests.
- [ ] `git -C ~/work/vivace-graph status --short` is empty and its HEAD is
  still `853df62`: vivace-graph untouched.
- [ ] On kraison/vivace-cabinet#2, comment `Ready for review:` with the
  branch and `git -C ~/work/vivace-cabinet diff main...unit-2a-extraction`.
- [ ] Stop: merge and push wait for Kevin's word; phase 2b gets its own
  plan.
