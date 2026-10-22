# Review of PR #287, std.bigint (head 00965cb2d), 2026-10-16

Independent adversarial review. Built from a detached worktree of
origin/std-bigint (scratchpad), every run through `cpuq run --local --cores 2`.

## Verdict

Merge after a small doc fix. The arithmetic is correct on everything I
threw at it, and runs sanitizer-clean. The one rule-1 problem is in the
allocation paragraph: one claim is false and none of it is tested.

## What I ran

All probes ran under `RIG_SANITIZE=1 bin/rig run`. Every one exited 0 and
matched its oracle exactly. No probe found a bug, so none were added to
test/corpus. They are in the scratchpad `probes/` directory:
gen_arith.py, gen_parse.py, gen_parse2.py, gen_f64.py, edge.rig and cap.rig.

| Probe | Cases | Oracle | Result |
|---|---|---|---|
| add, sub, mul, shr(n), shl(n), pow(e), compare, equals, sign, bit_len, to_f64 on random values (0, ±1..3, 2^64k±3, all-ones and 2^63 limb patterns, random up to 600 bits; n in {0,1,63,64,65,127,128,129,rand≤700}; e in 0..40) | 4,500 rows | Python int, `python3 -I` | identical |
| zero results: each one checked by sign()==0, equals(0), compare both ways (finds a negative zero, which text alone would print as "-0") | inside the above | — | no negative zero |
| parse: Go-SetString edge list × bases {0,2,7,8,10,16,36}, plus 8,000 fuzz strings over digits/letters/`_`/`+-`/space/prefixes | 8,658 | **Go 1.27 math/big `SetString`** (real Go, not a model) | identical |
| to_f64: exact ties, tie+deep sticky bit, tie−1, random low bits, ±; 2^(64k)±1 for k ≤ 39; DBL_MAX, DBL_MAX + half ulp ± 1, 2^1024±1 | 3,164 | Python float(int), OverflowError → ±inf | identical bits |
| edges: pow(-1, 10^18 and 10^18+1), pow(1, 2^62), pow(0, 10^18), 0^0, (-1)^0, (-2)^3, (-2^64)^3, (-3)^41; shr of -1, -2^64, -2^64-1, -(2^128-1), -2^128, -(2^65-1) at 63/64/65/127/128; Int.min; shr by 10^18 | 31 | Python | identical |
| `./test/run -j 2 bigint` | 11 | — | 11 pass |
| `zig build test` with a fresh cache dir | — | — | pass |

Checked by reading the code as well:
- The Möller–Granlund constant `v` equals floor((2^128−1)/10^19) − 2^64, and 10^19 is ≥ 2^63, so the divisor is normalized.
- `text`'s bound on groups, `n*64/63 + 1`, holds for every n from 9 to 10^6.
- `parse`'s capacity, `len/per + 1`, is always enough, so parse allocates exactly once.
- to_f64 cannot return a subnormal: the smallest nonzero BigInt is 1, and n ≥ 2 limbs gives e ≥ 1. So that concern does not apply.

## Findings

### 1. Low (doc, rule 1): "zero allocates nothing" is false, and the allocation claims are untested

docs/STD.md and the module header say that every result "allocates its
limbs, sized before they are filled … zero allocates nothing". From the code:
- `parse("0")` calls `List(capacity: (1-0)/19 + 1)`, which is initCapacity(1). That allocates one slot for a zero.
- `from_int(0).add(from_int(0))` goes through `add_limbs([], [])`, which is `List(capacity: 1)`: one slot for a zero.
- `from_int(1).shr(1)`, or any shr whose surviving limbs come out empty on the main path, uses `List(capacity: x.len - q)`. That is one slot or more for a zero.
- `from_int(n)` uses `List()` and then `push`. `grow` rounds that up to 4 slots, so it is not "sized before filled", and it holds 32 bytes for one limb.

No test counts allocations, so none of this paragraph is checked.

Fix: either return `zero()` early in these paths and build from_int with
`List(capacity: 1)`, or soften the wording to "at most one allocation per
result".

### 2. Low (perf, runtime change): small exact capacities pay a realloc

The new initCapacity keeps the old behaviour for negative n (the same
"negative size" panic) and for n = 0 (`.empty`). The zero-size-T path is
the same too. The only change is for n = 1..3, which used to get 4 slots
through `grow`'s `@max(want, 4, 2*len)`. Now pushing past n reallocates.

Measured in `--release` on arm64 (cap.rig, 5M iterations, 3 rounds):
- `List(capacity: 1)` then 4 pushes: 14 ns.
- `List(capacity: 2)` then 4 pushes: 15 ns.
- `List(capacity: 4)`, which is what the old capacity 1 gave: 8 ns.
- So that pattern is about 75% slower.

No call site in the tree hits this:
- The bigint sites are exact or upper bounds.
- The `back`/`back_hs` scratch Lists in std/hash.rig are filled to at most their capacity.
- There are none in examples.

User code that passes a low hint pays it. A minor inconsistency:
`!v.reserve(1)` on an empty List still gives 4 slots. The "exactly n" in
the runtime doc comment is not tested, apart from the runtime unit test,
which grows past 2.

### 3. Low (benchmark fairness): the add and shl rows are not Trig's code

I compared `bench.rig` between its PORT markers against Trig b2d44c7
`src/jsnum/gostd.rig`, block by block, and every block is verbatim.

But `nat_add` and `nat_shl` come from the author: Trig has neither. They
are written "port-style":
- `List()` with no capacity;
- a `t += y[i] if i < y.len` branch on every limb.

bench.rig's comment says so. README.md says only "copied verbatim", so a
reader takes the add and shl rows as a comparison against Trig.

### 4. Info (benchmark honesty): the numbers reproduce, but one row is noise

The optimizer cannot delete the work:
- `measure` folds every result into `sink` and prints when `sink == 7`.
- The allocating operations cannot be hoisted.
- to_f64 is 0.66 ns at 1L and 1.43 ns flat from 2L to 64L, as an algorithm that reads two limbs predicts.

Its pure loop could in principle be partly hoisted, since there is no
black_box. But its lead over the port, 37x to 500x, makes that moot.

My arm64 run (shared Mac, load about 5) agrees with the README within
about 15% on every row except shl 1L:
- README: port 47 ns, "344% faster".
- Here: port 16.6 ns against std 9.2 ns, 81% faster.
- x86's 58% is consistent with this run.

The README's arm64 shl 1L figure is noise and should be re-measured. Std
is faster on every row in my run too. The smallest margin is add 2L, 8%
faster; the README says 18%.

## Not defects (checked)

- Signs in add, sub and mul: every mixed and zero case normalizes, with no negative zero.
- shr floors like Python's `>>`.
- to_f64 rounds once, to nearest, ties to even, and overflows to inf correctly. That includes a value that rounds up to 2^64 inside the top 64 bits.
- parse matches Go for base-0 prefixes and `_`, signs, "", "0x" alone, "0_", "08", and a set base taking no prefix and no `_`.
- pow with e = 0, base 0, ±1, and negative powers of two (the shl fast path).
- The panic messages for a bad base, a negative shift and a negative power are tested.
- Failed parses free their limbs under the sanitizer (3,744 invalid parses ran clean).

## Side observation, not this PR

My first to_f64 probe put 3,000 `print(bigint.parse("<lit>")!.to_f64().to_bits())`
statements in one fallible `main`. cpuq killed the build at 16 GB RSS. The
same cases through a helper `sub f(s)!` built in seconds. Some stage of the
compiler or Zig scales badly with many `!` propagations in one body. I did
not find which stage.
