# vivace-cabinet

A Kyoto Cabinet-style key-value store in Common Lisp, built from
[vivace-graph](https://github.com/kraison/vivace-graph)'s on-disk
structures: a memory-mapped heap, a linear hash, a skip list and a B+ tree.
The design is in `docs/superpowers/specs/2026-10-16-vivace-cabinet-design.md`.

**Status:** HashDB and TreeDB (unit 2) have Kyoto Cabinet's database
API except transactions: records, cursors, visitors, compare-and-swap
and increments, bulk operations, matching, status, copying, merging and
snapshots. Unit 3 benchmarks them against Kyoto Cabinet.

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

A TreeDB keeps its records in key order:

    (vivace-cabinet:with-db (db "/var/data/words.vct" :type :tree)
      (vivace-cabinet:db-set db "pear" "green")
      (vivace-cabinet:db-set db "apple" "red"))

`:type :tree` chooses TreeDB when creating; an existing database opens as
whatever it is, and a `:type` or `:engine` that does not match it signals
`open-error`. A writer's `:truncate` keeps the type and engine unless
`:type` or `:engine` names others. TreeDB takes `:engine` (`:bplus-tree`, the default, or
`:skip-list`), `:page-size` (B+ tree pages of 1024 to 32768 bytes, 4096
by default), `:comparator` (a strict less-than on octet vectors; the
default, `octets<`, is unsigned byte order) and the heap keywords.

As in Kyoto Cabinet, an operation that fails for an ordinary reason (adding
a key that exists, removing one that doesn't, writing to a reader, a
compare-and-swap that finds another value) returns NIL, and
`(db-error db)` says why: `:duplicate-record`, `:no-record`,
`:no-permission` or `:logic`. Real problems signal `vivace-cabinet-error`
subclasses: `open-error`, `invalid-argument`, `key-too-long`,
`not-implemented` and its subclass `transactions-not-implemented`.
`db-check` returns the value's size; `db-size` returns the bytes in use,
not file sizes (the index files are sparse).

## Cursors

    (vivace-cabinet:with-cursor (cur db)
      (when (vivace-cabinet:cursor-jump cur)
        (loop do (print (vivace-cabinet:cursor-get-key cur :as :string))
              while (vivace-cabinet:cursor-step cur))))

`cursor-jump` moves to the first record, or on a TreeDB to the first at
or after a key; `cursor-jump-back` to the last, or the last at or before
a key; `cursor-step` and `cursor-step-back` move one record.
`cursor-get` returns the current key and value (`cursor-get-key` and
`cursor-get-value` one of them), `cursor-set-value` replaces the value,
and `cursor-remove` and `cursor-seize` remove the record and move to the
next. A move past either end returns NIL with `:no-record`. A TreeDB
cursor holds its position as a key, so other threads' changes leave it
valid; if its record is removed, it reads the next one. Give each thread
its own cursor.

A HashDB cursor moves forward only, in no useful order, as in Kyoto
Cabinet: `cursor-jump-back` and `cursor-step-back` signal
`not-implemented`, and `cursor-jump` with a key lands on that key's
record. It reads the index a bucket at a time, so a record that a
concurrent writer's bucket split moves can be seen twice or missed.

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

`db-cas` stores a new value only when the old one is as given (NIL: the
key must be absent; a new value of NIL removes the record).
`db-increment` adds to an 8-byte big-endian integer, and
`db-increment-double` to a double stored as Kyoto Cabinet stores one
(the integral part, then the fraction in units of 10^-15, 8 bytes each),
so the bytes are Kyoto's; `:orig` is an absent key's starting value.

`db-set-bulk` stores an alist of keys and values (a key given twice
takes its last value) and returns how many it stored; `db-get-bulk`
returns an alist of the keys it finds; `db-remove-bulk` returns how many
it removed. Each is atomic unless given `:atomic nil`.

`db-iterate` visits every record while holding the whole database:
other threads wait until it ends, as in Kyoto Cabinet.
`db-scan-parallel` visits every record from `:threads` threads (4) at
once, read-only, also holding the database. `cursor-accept` visits a
cursor's record, and with `:step t` moves on.

`db-match-prefix`, `db-match-regex` (CL-PPCRE syntax, matched against
keys read as UTF-8) and `db-match-similar` (Levenshtein distance in
bytes, or in characters with `:utf t`; nearest first) return lists of
keys, at most `:max` of them. On a TreeDB in byte order,
`db-match-prefix` reads only the matching keys and returns them in
order; every other match reads every key.

`db-status` returns a plist describing the database. `db-occupy` calls a
function with the database's path, record count and size while holding
it. `db-copy` copies the database's files into a new directory, which
opens as a database of its own. `db-merge` stores other databases'
records by `:mode` (`:set`, `:add`, `:replace` or `:append`), one source
after another, so under `:set` a key in several sources takes the last
one's value.

`db-dump-snapshot` writes every record to one file, and
`db-load-snapshot` stores a snapshot's records into a database of either
type. The format is vivace-cabinet's own: 8 magic bytes, then each
record's key length and value length (8 bytes each, little-endian), key
and value, and a key length of 2^64-1 at the end.

Version 1 has no transactions: `db-begin-transaction`,
`db-begin-transaction-try`, `db-end-transaction` and `with-transaction`
signal `transactions-not-implemented`.

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
- **B+ tree keys.** A key longer than a quarter page (1024 bytes at the
  default page size) signals `key-too-long`. A value goes in a heap
  record outside the page when it and its key exceed a quarter page.
- **Comparators are not stored.** Open a TreeDB with the same
  `:comparator` every time; another order misplaces records silently.
- **The skip list frees removed records at close.** On the skip-list
  engine, removing or replacing a record unlinks it at once but frees
  its space only at `close-db`.
- **Skip-list cursors can miss a key being replaced.** The skip-list
  engine replaces a value by removing and re-adding its record, so a
  cursor passing that key at that moment does not see it.
- **Readers need write permission.** Files are mapped read-write even
  for `:reader`, so a reader that may not write them gets `open-error`.
- **Appending copies the value.** `db-append` writes a new record each
  time, and the heap keeps freed records of the sizes a value passed
  through: a value grown 1000 bytes at a time to 300 KB leaves about
  4 MB of heap. Records over 512 bytes take up to 25% more than their
  size, so freed space fits records of similar size.
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
