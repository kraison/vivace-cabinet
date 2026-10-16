# vivace-cabinet

A Kyoto Cabinet-style key-value store in Common Lisp, built from
[vivace-graph](https://github.com/kraison/vivace-graph)'s on-disk
structures: a memory-mapped heap, a linear hash, a skip list and a B+ tree.
The design is in `docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`.

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
strings are stored as UTF-8 and read back with `:as :string`. One handle
may have a database open for writing, or any number for reading, in this
process or others; an open that conflicts signals `open-error` (an
advisory `flock` on the directory, which network filesystems may not
honour).

`open-db` takes `:mode`, a list of `:reader` or `:writer` plus any of
`:create`, `:truncate`, `:autosync` (default `(:writer :create)`), and
tuning keywords: `:buckets` and `:max-locks` for the index, `:heap-size`,
and `:heap-reservation` (default 64 GiB of address space the heap may
grow into in one session). A writer's `:truncate` empties the database,
or discards one left incomplete by a crash while creating; opening an
incomplete database otherwise signals `open-error`.

As in Kyoto Cabinet, an operation that fails for an ordinary reason (adding
a key that exists, removing one that doesn't, writing to a reader) returns
NIL, and `(db-error db)` says why: `:duplicate-record`, `:no-record` or
`:no-permission`. Real problems signal `vivace-cabinet-error` subclasses:
`open-error`, `invalid-argument`, `not-implemented`. `db-check` returns the
value's size; `db-size` returns the bytes in use, not file sizes (the
index files are sparse).

## Limits

- **No crash safety.** Writes go straight to shared memory maps and reach
  disk on close; a crash mid-write can leave a structure inconsistent. A
  writer that exits without `close-db` leaves its records, and the next
  open counts them again by walking the whole index.
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
- **Readers need write permission.** Files are mapped read-write even
  for `:reader`, so a reader that may not write them gets `open-error`.
- **Appending copies the value.** `db-append` writes a new record each
  time, and the heap keeps freed records of the sizes a value passed
  through: a value grown 1000 bytes at a time to 300 KB leaves about
  4 MB of heap. Records over 512 bytes take up to 25% more than their
  size, so freed space fits records of similar size.
- **B+ tree entries of mixed sizes.** The B+ tree splits a full page by
  entry count, not bytes, so a page of small entries can fail to take a
  large one (issue #4); to be fixed before TreeDB uses it.
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

The process exits non-zero if any test fails. One linear-hash test copies
a hash's two sparse 1000 MiB files without keeping them sparse, so the
temp directory needs about 2 GB free; where `/tmp` is a small tmpfs, run
with `TMPDIR=/var/tmp`.

## Provenance and licence

Copied code, and exactly what was copied, is listed in
`docs/provenance.md`. MIT licence; see `LICENSE`.
