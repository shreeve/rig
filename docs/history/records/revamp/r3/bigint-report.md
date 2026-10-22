# std.bigint report (2026-10-16)

Branch `std-bigint`, PR #287 (https://github.com/shreeve/rig/pull/287).
Gate: `tools/gate` green on head 00965cb2d (suite, corpus, matrix on burst; both required checks success). Not merged.

## What landed

- `std/bigint.rig`, plus `std/bigint.zig` for three panics. Both are listed in `std/embed.zig`.
  - `BigInt` is a sign plus normalized `List[U64]` limbs, with U128 products.
  - Zero has no limbs and is never negative. The fields are private.
- API:
  - `bigint.parse(s, base = 0) -> BigInt!`:
    - Go `SetString` syntax, with base 0 prefixes and `_`.
    - Fails with `ParseError.invalid`.
    - Panics on a base that is not 0 or 2 to 36.
  - `bigint.from_int(n)`, `a.text()` (base 10), `a.clone()`.
  - `a.compare(b)`, `a.equals(b)`, `a.sign()`, `a.bit_len()`.
  - `a.add(b)`, `a.sub(b)`, `a.mul(b)`.
  - `a.shl(n)`, and `a.shr(n)`, which rounds down as `>>` does.
  - `a.pow(e)`.
  - `a.to_f64()`: nearest, ties to even, rounded once, and inf past `Float.max`.
  - A negative shift or power panics.
- Allocation (stated in docs/STD.md and the module header):
  - Every result allocates its limbs once, sized before they are filled. Zero allocates nothing.
  - `pow` allocates one more List.
  - `text` allocates its String, plus a copy of the limbs above 8 limbs.
  - `compare`, `equals`, `sign`, `bit_len`, and `to_f64` allocate nothing.
- `src/runtime.zig` (a separate commit): `List(capacity: n)` now allocates exactly n slots.
  - It used to go through `reserve` and grow to `@max(n, 4, 2*len)`.
  - In ReleaseSafe the extra slots cost a memset. That made 1-limb add and shr slower than the port until this fix.
- Tests (all sanitizer-clean; expected values come from Python's int and float):
  - `bigint_parse`: Go's stringTests.
  - `bigint_arith`: Go's sumZZ and prodZZ, limb-boundary edges paired every way, and 24 random pairs of 1 to 9 limbs.
  - `bigint_shift_pow`: shl and shr around every limb boundary, and pow, including 2^100000 and (-3)^20001.
  - `bigint_to_f64`: ties, sticky bits, DBL_MAX, and inf.
  - Five panic tests.
  - Two reject tests: no `==`, no `<`, no construction, a private field; and use after move.
- `docs/STD.md`: an index row and a `## std.bigint` section, with a run example and a reject example.
- `bench/bigint/` with a README, and a row in the AGENTS.md map.

## Speed

`bench/bigint/README.md` has the full table for both machines. std is faster on every row.

The smallest margins:
- arm64 (the Mac, shared, `cpuq run --local`): mul 1L 10% faster, shr 1L 10% faster, add 1L 16% faster.
- x86 (pup, `cpuq lease pup-bench --exclusive`, `taskset -c 2`): shr 1L 7% faster, parse16 1L 12% faster, shr 2L 12% faster, mul 1L 17% faster.

At large sizes:
- parse 64L: about 20 times as fast.
- mul 64L: 3 to 4 times as fast.
- pow: 4 to 17 times as fast.
- to_f64: 36 to 450 times as fast, because it reads only the top two limbs and then stops at the first set bit below them.

## Rig gaps found

1. `+x` cannot clone an object from another module (SPEC.md:4905, by design). So BigInt has a `clone()` method; a clone hook would let `+a` work.
2. `print(a)` shows the private fields, `BigInt(neg: true, limbs: [5])`. There is no print hook that would show the number.
3. The `==` diagnostic on a BigInt names the private field `limbs`.
4. Rig code has no panic builtin. std needs an extern Zig file for it (`std/bigint.zig`), and user code cannot have one.
5. There is no `black_box` for benchmarks. The harness cycles through 8 inputs and folds a checksum, so LLVM cannot hoist work out of the loop.
6. Proofs do not cover List indexing (`x[i]` with `i < x.len`) or indices like `i + 1`, so the inner loops keep their bounds checks. Slicing to `[..]` first helps.
7. (Fixed here) `List(capacity: n)` over-allocated.
8. A note for Trig: Trig's pow_f64 rounds twice (to 256 bits, then to 53), while std's `to_f64` rounds once. On a tie the last bit can differ, and std's result is the correctly rounded one.

## Process notes

- The first gate failed on one oracle check: the new reject test was not listed in test/oracle/rejections, so it was added (5e6529b84). Two later gate runs went red only because main had moved; each time I merged main and reran.
- The local full suite could not finish on the Mac: load was about 10, and the runtime change reruns every test. One run hit my own 50-minute bound; the rerun was projected at over 13 hours. I stopped it and relied on `tools/gate`, which runs the suite, corpus, and matrix on burst.
- Before the merge, the bigint tests passed locally (11 of 11), and they passed again after merging main.
