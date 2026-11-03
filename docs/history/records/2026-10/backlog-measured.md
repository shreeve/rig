# Measured and not taken, from the backlog (2026-11-03)

Two entries of docs/internals/backlog.md that recorded a measurement and
no work, kept as written when the backlog was cleaned.

## bench/hash after inlining a generic type's small members (#246)

On the Mac (aarch64), pooled medians of 8 layouts x 21 runs against main:

- `int hit` is 2-6% slower, and `small 4` and `small 8` 2-3% slower:
  LLVM spills registers differently in a function that holds several
  loops once more is inlined into it. The code of `int hit`'s loop is
  the same as main's, and x86 shows no difference. Needs a study.
- `int edit_put-hit` is 3.0% slower (95% interval -3.8% to +9.6%):
  inside the noise, but worth measuring again.
- Judge memory-bound bench/hash rows by medians with intervals and an
  unchanged control row, not by the fastest of N runs, which swung
  single rows several percent either way on unchanged code.

## Map and Set with 4-byte stored hashes

An entry's hash takes 8 bytes. The tag came from the stored bits up to
2^25 slots, and from the top of the whole hash, recomputed from the
keys, past that. It matched the 8-byte version's speed; it saves 4
bytes an entry.
