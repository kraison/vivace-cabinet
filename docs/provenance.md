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
