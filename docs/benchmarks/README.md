# Benchmarks

`bench/run.sh` runs benchmark round 1 (spec: unit 3) and writes its
report.

## Running it

    bench/run.sh --quick   # a small matrix, to check the harness
    bench/run.sh           # the spec's matrix: results in bench/results/,
                           # the report in docs/benchmarks/round-1.md

Options:

- `--n "1000000"`, `--threads "1 4"`, `--repeats 3` and
  `--engines "hash kyoto-hash-native"` narrow the matrix.
- `--data DIR` is where the databases go. The default is
  `/var/tmp/vc-bench/`, which must be on a real disk, not tmpfs.
- `--out DIR` is where the results go.

It needs SBCL with Quicklisp, and Kyoto Cabinet 1.2.80's library and its
`kchashtest`, `kctreetest` and `kcutilmgr`. It also needs python3, and
cl-kyoto-cabinet in `$CL_KYOTO_CABINET` (default
`~/work/cl-kyoto-cabinet`). `vivace-cabinet/bench-test` tests the
harness at small sizes.

## The workload

The harness runs Kyoto Cabinet's order test, as `kchashtest order` and
`kctreetest order` run it (the spec's Workload section has the details):

- an open, then three timed phases (set, get and remove), then a close;
- keys are 8-digit decimals, and each value equals its key;
- with `-rnd`, keys are drawn at random, and every eighth record adds a
  random extra operation.

`bench/workload.lisp` repeats this through vivace-cabinet's generic
functions, so one workload runs on Kyoto from Lisp and on
vivace-cabinet's engines.

The port is faithful: with one thread and one seed, every engine ends
each phase with the same records as Kyoto's own program
(`port-matches-kyotos-own-test`). One difference: Kyoto's test shares
one random generator among its threads, while the port gives each
thread its own, seeded as Kyoto seeds its own.

## Engines

| Name | What runs |
|---|---|
| `kyoto-hash-native` | Kyoto's `kchashtest order` |
| `kyoto-tree-native` | Kyoto's `kctreetest order` |
| `kyoto-hash` | Kyoto's HashDB from Lisp, through `vivace-cabinet/kyoto` |
| `kyoto-tree` | Kyoto's TreeDB from Lisp, through `vivace-cabinet/kyoto` |
| `hash` | vivace-cabinet's HashDB |
| `bplus-tree` | vivace-cabinet's TreeDB on the B+ tree |
| `skip-list` | vivace-cabinet's TreeDB on the skip list |

## Each run

- **A fresh process and a fresh database.** Each run starts in its own
  process, on a new database in a new directory under `--data`. On
  btrfs that directory is made `chattr +C`, so its files are neither
  copied on write nor compressed, as database files usually are there.
- **Threads share the records.** N records over T threads is T threads
  of N/T records each.
- **Two tunings.** Every engine runs on its defaults, and tuned for N:
  - Kyoto's bucket count as its documentation advises: twice N for
    HashDB, a tenth of N for TreeDB;
  - vivace-cabinet's HashDB with `:buckets` N/8, because a bucket holds
    24 entries and splits when one overflows.

  vivace-cabinet's TreeDB has no bucket count, so it runs on defaults
  only.
- **Fixed seeds.** Repeat r of every configuration uses seed r; Kyoto's
  programs take it as `KCRNDSEED`.
- **Repeats are outermost**, so each configuration's runs spread over
  the session.

## What is recorded

`runs.csv` has one row per run:

- **Phase times** are wall seconds from the engine's own clock: Kyoto's
  programs print them in milliseconds, and the Lisp harness reads
  SBCL's real-time clock.
- **CPU** is, for a Lisp engine, the child's CPU from open to close,
  without loading Lisp. For Kyoto's programs it is the whole process's.
- **Peak RSS** is the whole process's, from `bench/measure.py`'s
  `wait4`. A Lisp process's includes SBCL's image, about 120 MB.
- **`count` and `left`** are the records after the set and remove
  phases.
- **`errors`** are unexpected failures, and **`exit`** is the process's
  exit status.

`sizes.csv` has one row per configuration: `du` of the database after a
set-only run, whose close writes every record. Kyoto's TreeDB writes its
pages only at close, so after a full run it would show the emptied
tree.

`env.txt` records the machine, CPU, memory, disks, data filesystem,
kernel, SBCL, Kyoto Cabinet, the vivace-cabinet commit and the
vivace-graph commit the code was copied from. `failures.log` keeps the
output of any run that failed.

## The report

`docs/benchmarks/round-1.md` is generated from those files. Each
record count, order and tuning gets a table. The set, get and remove
columns are thousands of records per second: the median of the runs,
with the slowest and fastest in brackets. Failed runs are left out, and
the table says how many there were.
