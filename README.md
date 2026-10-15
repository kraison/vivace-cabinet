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
