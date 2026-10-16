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
| substrate/heap-bytes.lisp | transactions.lisp | `set-bytes` on `memory` |
| structures/hash-key.lisp | primitive-node.lisp | the 16-byte `%hash` method, plus an explicit `defgeneric` |
| structures/linear-hash.lisp | linear-hash.lisp | whole file; `open-lhash` signals when it cannot open, after unmapping what it mapped (vivace-graph's returned a handle whose files were unmapped) |
| structures/cl-store-ecl.lisp | cl-store-ecl.lisp | whole file (ECL only) |
| structures/cursors.lisp | cursors.lisp | whole file |
| structures/skip-list.lisp | skip-list.lisp | all but the development and benchmark functions; one cached node object per address (`%sl-cache-node`), and add and remove re-read each locked predecessor's pointer before validating (two objects for one node livelocked concurrent writers) |
| structures/skip-list-cursors.lisp | skip-list-cursors.lisp | whole file |
| structures/bplus-tree.lisp | bplus-tree.lisp | all but the view-index protocol and the graph-codec factory; value-qualified removal compares octets with `equalp` (vivace-graph's compared them with `equal`, which never matches); full pages split by bytes, not entry count (#4); BPT-INSERT and BPT-REMOVE run lock-free cores, %BPT-INSERT-TOP and %BPT-REMOVE-TOP, which TreeDB calls under one lock |
| tests/allocator-tests.lisp | tests/allocator-tests.lisp | adapted: package and suite names |
| tests/linear-hash-tests.lisp | tests/linear-hash-tests.lisp | adapted: package and suite names; `reopen-preserves-contents` closes its second handle; `open-lhash-signals-on-a-corrupt-table` is new |
| tests/skip-list-tests.lisp | tests/skip-list-tests.lisp | adapted: package and suite names; `list-comparators-are-a-strict-total-order` dropped (tests code not copied); keys and values use a test codec |
| tests/bplus-tree-tests.lisp | (new) | B+ tree tests; vivace-graph tested it only through graph indexes and a benchmark |
| tests/support.lisp | tests/suite.lisp | fixtures, adapted |

Trimmed as graph-specific or unused: vivace-graph's `serialize.lisp`,
`segment.lisp`, `node-id.lisp`, `pcons.lisp`, the buffer pool, and the
development functions in the files above.
