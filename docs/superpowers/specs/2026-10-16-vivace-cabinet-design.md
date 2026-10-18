# vivace-cabinet: design

Date: 2026-10-16. Status: draft for Kevin's review.

## Purpose

An experiment with four goals, all of them Kevin's:

1. A reusable, standalone Common Lisp key-value library, `vivace-cabinet`,
   built from vivace-graph's on-disk structures.
2. A published comparison of that library against Kyoto Cabinet, a mature
   C++ engine.
3. Evidence for vivace-graph's future storage choices.
4. Curiosity: what the numbers are.

The experiment has three units, done in order, plus one that is conditional:

| Unit | What | Repos |
|---|---|---|
| 1 | kyoto-persistence working on Kyoto Cabinet 1.2.80 | cl-kyoto-cabinet, kyoto-persistence |
| 2 | vivace-cabinet: extraction, record layer, Kyoto-style API | vivace-cabinet |
| 3 | Benchmark round 1 and conformance check | vivace-cabinet |
| 4 | Transactions (write-ahead log, crash recovery), only if Kevin decides after round 1 | vivace-cabinet |

This spec covers units 1 to 3. Each unit gets its own implementation plan.

## Constraints

- **vivace-graph is not changed.** Code is copied out of it, never moved.
  Moving vivace-graph onto vivace-cabinet is out of scope.
- **SBCL only** for tests and benchmarks. Copied code keeps its CCL, ECL and
  LispWorks branches untouched, but they are not tested in this work.
- **No transactions in version 1.** The API reserves them.
- **Public repos.** cl-kyoto-cabinet, kyoto-persistence and vivace-cabinet are
  public; issues stay generic.
- **License:** vivace-cabinet is MIT, carrying vivace-graph's copyright
  notice (Kevin Thomas Raison), since its code is copied from there.

## Unit 1: kyoto-persistence on Kyoto Cabinet 1.2.80

Both repos date from 2010 (cl-kyoto-cabinet was last touched in 2019).
kyoto-persistence depends on cl-kyoto-cabinet's `dbm-*` protocol, which binds
56 Kyoto C functions through CFFI.

- Install `kyotocabinet` 1.2.80 from Arch's `extra` repository
  (`omarchy pkg add kyotocabinet`).
- **cl-kyoto-cabinet:** load under current SBCL and CFFI against the 1.2.80
  library. It has no tests; add a FiveAM suite covering open, put, get,
  remove, iterate and transactions on hash (`.kch`) and tree (`.kct`)
  databases. Fix what breaks.
- **kyoto-persistence:** `test.lisp` holds four routines (`klist-test`,
  `phash-test`, `tp`, `tp2`) that print results without checking them. Turn
  them into FiveAM tests with assertions. Fix what breaks.
- **Done when** both suites pass on SBCL and Kyoto Cabinet 1.2.80, and each
  README says how to run them. Work goes on a branch in each repo; nothing is
  pushed without Kevin's word.

## Unit 2: vivace-cabinet

### Extraction: copy and trim

The three structures sit entirely in vivace-graph's lower layers and depend on
none of the graph, schema or transaction code:

```
posix, rw-lock -> mmap -> allocator -> linear-hash -> skip-list (+ cursors)
                                                    -> bplus-tree
```

A function-level dependency check (2026-10-16, vivace-graph `853df62`) found:

| vivace-graph file | What the structures use | Action |
|---|---|---|
| `posix.lisp` | mmap, msync, munmap, open, file size and extension calls | copy |
| `rw-lock.lisp` | `rw-lock`, `with-read-lock`, `with-write-lock` | copy |
| `mmap.lisp` | all; uses `vector-segment` from `segment.lisp` | copy, plus that one function |
| `allocator.lisp` | all: heap, free list, allocation headers | copy |
| `linear-hash.lisp`, `skip-list.lisp`, `skip-list-cursors.lisp`, `cursors.lisp`, `bplus-tree.lisp` | all | copy |
| `buffer-pool.lisp` | `get-buffer`, `get-skip-node-buffer` (2 of 39 definitions) | copy those two |
| `globals.lisp` | `*cache-enabled*`, `*max-locks*`, `*mmap-min-reservation*`, `*mmap-reservation-multiplier*`, `+key-bytes+` (16), `+value-bytes+` (8), `+bucket-size+` (24) | copy those |
| `utilities.lisp` | `gen-id`, `less-than`, `make-byte-vector`, `make-rw-lock`, `proper-listp`, `with-gensyms`, the lock macros | copy those |
| `conditions.lisp` | four conditions: serialization, deserialization, duplicate key, nonexistent key | copy those |
| `serialize.lisp` | graph-aware (vertex and edge type codes); the byte API does not need it | leave; copy only the uint64 and key helpers the structures call |
| `node-id`, `pcons`, `queue`, `mailbox` | nothing | leave |

The B+ tree is marked experimental in vivace-graph; it is copied as it stands.

**Provenance.** Each copied file begins with one line naming its vivace-graph
source file and commit, and what was trimmed. `docs/provenance.md` lists every
copied file, so the copies can be compared with vivace-graph later.
vivace-graph's `tests/allocator-tests.lisp`, `linear-hash-tests.lisp` and
`skip-list-tests.lisp` are copied and adapted to the new package. The B+ tree
is only tested through graph-level index tests there, so it gets new
structure-level tests.

### Layout

```
vivace-cabinet/            package VIVACE-CABINET
├── substrate/             copied, trimmed (table above)
├── structures/            copied: linear-hash, skip-list, skip-list-cursors,
│                          cursors, bplus-tree
├── records.lisp           new: variable-length key/value records in the heap
├── hash-db.lisp           new: HashDB
├── tree-db.lisp           new: TreeDB
└── api.lisp               new: the Kyoto-style API
```

ASDF systems:

- `vivace-cabinet`: the library. Depends on cffi, alexandria,
  bordeaux-threads, cl-store (the linear hash saves its header with it) and
  cl-ppcre (for `db-match-regex`).
- `vivace-cabinet/test`: FiveAM suites.
- `vivace-cabinet/bench`: benchmarks; the only system that needs
  cl-kyoto-cabinet and libkyotocabinet.
- `vivace-cabinet/conformance`: the differential check against Kyoto; also
  needs cl-kyoto-cabinet.

### Storage

A database is a directory (`foo.vch` for hash, `foo.vct` for tree) holding the
memory-mapped heap, the structure's own files and a small header. Kyoto uses
one file per database; the README states the difference.

**HashDB.** The linear hash is fixed-width: 16-byte keys, 8-byte values,
equality by `uuid-array-equal`. It becomes an index from key digests to
records:

- A record is `[next u64][key-len u32][value-len u32][key][value]`, allocated
  from the heap and reclaimed through the allocator's free list.
- The linear hash maps a 128-bit MurmurHash3 (x64) digest of the key,
  implemented in Lisp, to the record's address.
- Lookups compare the full key. Records whose keys share a digest chain
  through `next`.
- A digest equal to the linear hash's reserved null key is remapped by
  flipping its last bit, applied the same way on every lookup.
- Read-modify-write operations (`db-add`, `db-cas`, `db-increment`,
  `db-append`, `db-accept`) run under the linear hash's per-bucket locks, so
  each is atomic for its key.
- Iteration order is unspecified, as in Kyoto's HashDB.

**TreeDB.** `:engine :bplus-tree` (default) or `:skip-list`.

- Keys are byte vectors in unsigned lexicographic order, Kyoto's default. A
  custom comparator may be given as a Lisp function.
- Keys are unique (no duplicates), as in Kyoto.
- B+ tree pages are 4096 bytes by default and store entries inline. Values
  longer than a quarter page are stored out of line as heap records, with the
  page holding the pointer. Keys longer than a quarter page (1024 bytes at the
  default size) signal `key-too-long`; this is a version 1 limit, documented.
- The skip list stores each entry in a variable-size heap node, so it has no
  size limits.

**Durability.** `db-synchronize` flushes the heap and structures with msync;
`close-db` synchronizes and writes the headers. A crash during a write can
leave the database inconsistent. The README says so; unit 4 is the fix.

### API

It mirrors Kyoto's `BasicDB` and `Cursor` in CLOS. Names take a `db-` or
`cursor-` prefix because Kyoto's own (`set`, `get`, `remove`, `append`,
`replace`, `count`, `step`) clash with Common Lisp symbols.

| Kyoto | vivace-cabinet |
|---|---|
| `open`, `close` | `open-db` (`:type :hash` or `:tree`, `:engine`, `:mode` with `:reader :writer :create :truncate :autosync`, tuning keywords `:buckets :page-size :max-locks` in place of `tune_*`), `close-db`, `with-db` |
| `set add replace append` | `db-set db-add db-replace db-append` |
| `get check seize remove` | `db-get` (with `:as :string`), `db-check`, `db-seize`, `db-remove` |
| `increment increment_double cas` | `db-increment db-increment-double db-cas` |
| `set_bulk get_bulk remove_bulk` | `db-set-bulk db-get-bulk db-remove-bulk` |
| `accept accept_bulk iterate scan_parallel` | `db-accept db-accept-bulk db-iterate db-scan-parallel` |
| `match_prefix match_regex match_similar` | `db-match-prefix db-match-regex db-match-similar` |
| `count size path status clear synchronize occupy copy merge` | `db-count db-size db-path db-status db-clear db-synchronize db-occupy db-copy db-merge` |
| `dump_snapshot load_snapshot` | `db-dump-snapshot db-load-snapshot`, in vivace-cabinet's own format |
| `begin_transaction begin_transaction_try end_transaction` | `db-begin-transaction db-begin-transaction-try db-end-transaction`, `with-transaction`; in version 1 they signal `transactions-not-implemented` |
| `Cursor` | `db-cursor`, `with-cursor`, `cursor-jump cursor-jump-back cursor-step cursor-step-back cursor-get-key cursor-get-value cursor-get cursor-set-value cursor-remove cursor-seize cursor-accept` |

- **Visitors** are functions `(lambda (key value) ...)` returning `:nop`,
  `:remove` or a new value; `value` is `nil` when the key is absent. One
  function covers Kyoto's `visit_full` and `visit_empty`.
- **Logical failures return `nil`** and record a reason readable with
  `db-error` (`:duplicate-record`, `:no-record`, `:logic`, ...), as Kyoto
  returns `false`. Examples: `db-add` on an existing key, `db-remove` on a
  missing one.
- **Real errors signal conditions**: I/O failure, invalid arguments,
  `not-implemented` (backward cursor moves on a HashDB, as in Kyoto),
  `key-too-long`, `transactions-not-implemented`.
- **Keys and values** are `(unsigned-byte 8)` vectors; strings are accepted and
  stored as UTF-8.
- **Thread safety:** a database object may be shared between threads, as in
  Kyoto.

## Unit 3: benchmark round 1

### Workload

Kyoto's `order` test, as run by `kchashtest order` and `kctreetest order`
(checked against both programs' source in Kyoto Cabinet 1.2.80, where the
two run the same workload):

- Keys are 8-byte zero-padded decimals (`"00000001"`, ...) and each value
  equals its key.
- Timed phases run in turn: open, set, get, remove, close.
- With `-th T`, *each* thread does `rnum` records, thread `i` taking keys
  `i*rnum + 1` to `(i+1)*rnum`. N records over T threads are therefore run
  as `-th T` with `rnum` = N/T.
- `-rnd` does more than change the order. Each key is drawn at random from
  1 to `rnum*T`, so keys repeat and some are never set. After every eighth
  record, each phase also does one more operation on that key, chosen at
  random: a set, an append, a remove or a cursor read (1/8 each), or a get
  (1/2).
- The Lisp harness repeats this workload exactly, extra operations
  included, so that rows 1 and 2 below are comparable.

The matrix:

- order: sequential and random (Kyoto's `-rnd`);
- N: 1,000,000 and 10,000,000;
- threads: 1, 4 and 8, with the N records divided among the threads.

### Engines

| | Engine | Run by |
|---|---|---|
| 1 | Kyoto native: `kchashtest order`, `kctreetest order` | Kyoto's own binaries |
| 2 | Kyoto through cl-kyoto-cabinet | Lisp harness |
| 3 | vivace-cabinet HashDB | Lisp harness |
| 4 | vivace-cabinet TreeDB, B+ tree engine | Lisp harness |
| 5 | vivace-cabinet TreeDB, skip-list engine | Lisp harness |

Rows 1 and 2 measure the cost of reaching Kyoto through FFI. Rows 2 to 5 are
the like-for-like engine comparison. The harness reaches row 2 through an
adapter defining the vivace-cabinet generic functions over cl-kyoto-cabinet's
FFI calls, for the operations the benchmark uses.

### Fairness

- Kyoto runs with transactions and autosync off, matching vivace-cabinet
  version 1.
- Each engine runs twice: on defaults, and tuned for N. Tuned means Kyoto's
  bucket count (`bnum`) set to 2N as its documentation recommends, and the
  linear hash's initial `:buckets` set so N records fit without splitting.
- Each run starts from a fresh database on a real disk, not tmpfs, and is
  repeated 5 times; results report the median and the spread.

### Recorded per run

Wall time and operations per second per phase, CPU time, peak resident
memory, database size on disk, and the environment: CPU, RAM, disk, kernel,
SBCL version, Kyoto version, vivace-cabinet commit, and the vivace-graph
commit the code was copied from.

### Output

Raw CSV under `bench/results/`, and a generated
`docs/benchmarks/round-1.md`. `bench/run.sh` reproduces everything. robotron
(2 cores, 4 threads) oversubscribes the 8-thread runs; the results name the
machine that produced the published numbers.

### Conformance check

`vivace-cabinet/conformance` runs random sequences of operations against
vivace-cabinet and against Kyoto, and fails on any difference in return value
or `db-error` reason. It shows the API mirrors Kyoto, and catches semantic
differences that would skew the benchmark.

## Testing

- **API suite**: one FiveAM suite run against all three engines (HashDB,
  TreeDB with each engine). It covers every API function and Kyoto's edge
  cases: `db-add` on an existing key returns `nil` with `:duplicate-record`;
  `db-cas` succeeding and failing; `db-increment` on a non-numeric value;
  visitors returning `:remove`, `:nop` and a new value; cursor order on
  TreeDB; backward cursor moves on HashDB signalling `not-implemented`.
  Also: persistence across close and reopen; B+ tree out-of-line values and
  `key-too-long`; concurrent writers.
- **Copied structure tests**: vivace-graph's allocator, linear hash and skip
  list tests, adapted, plus new B+ tree tests.
- **Conformance**: as above.
- **Mutation check**: for each test, delete the line it protects and watch it
  fail before trusting it.

## Tracking

- `~/work/vivace-cabinet` is a local git repo until Kevin agrees to create
  the public GitHub repo `kraison/vivace-cabinet`.
- A private project board, a tracker issue in vivace-cabinet, and one epic
  per unit: unit 1 in kyoto-persistence (cross-referencing
  cl-kyoto-cabinet), units 2 and 3 in vivace-cabinet. Unit 4 gets an epic
  only if Kevin decides to build it.

## Out of scope

- Any change to vivace-graph, including moving it onto vivace-cabinet.
- Transactions and crash recovery (unit 4).
- Kyoto's in-memory database types (CacheDB, GrassDB and the others).
- Lisp-object serialization in the core library.
- Testing on Lisps other than SBCL.
