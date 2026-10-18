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
