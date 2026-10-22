# PR notes: proven checks, round 1 (`proofs`)

Design: `.git/revamp/r3/design-proven-checks.md`, round 1 (§11).
Branch: `proofs`, from main d47fb6ac1, merged with origin/main after
`bits` (#122), `spanclamp` (#123), and `rtfast` (#121) landed.

## What is built

- `recordWrite` (`sema.WriteKind`: assign, compound, lend_write,
  elem_store, take, capture, move), keyed by node, in
  `SemContext.write_sites` (outside `sema.Facts`, so `--facts=sema` is
  unchanged). Resolve and typecheck record each site where they set the
  flags before; the `reassigned` / `written` flags are derived from the
  record. `move` (`<x` of the binding) sets no flag.
- `src/proofs.zig`: the pass, its dump, and unit tests (guard table row
  by row, near misses, G2/G3, kill rows, joins, and the walk-order test
  over every program in `test/behavior/emit/`).
- `sema.Proven`, `SemContext.proven` / `provenOf` / `recordProven`,
  `Facts.provenOf`, `rig check --facts=proofs`.
- Emit's four sites: `rig.atProven` / `rig.elemPtrProven`,
  `rig.readIntProven` / `rig.writeIntProven`, `rig.addProven` for `+`,
  and `i = rig.addProven(i, c);` for `+=`.
- Runtime: `Proven`, `provenIndex`, the helpers, `proofPanic`,
  `verify_proofs` (every debug build; `RIG_VERIFY_PROOFS=1` adds
  `__rig_verify_proofs` to an optimized build's root), and `rig.len`
  tests `n <= max_len = 2^62 - 1` ("length out of range").
- Tests: `test/behavior/proofs/` (§8.2's pairs plus the holes found
  below, each `# release`, each use marked `# proves:` / `# keeps:`),
  `test/cli/facts_proofs.sh` (swar.rig dump line by line, every mark),
  `test/cli/emit_shapes.sh` (proven shapes, unproven `rig.at`), the
  `proof.` grid in `test/matrix.py` (1,040 cells; `--deep` adds every
  write with its use nested), and `test/run` / matrix / corpus fail on
  "rig: a proven check failed" even where a panic is expected.
- Docs: INTERNALS "Proven checks" (and pipeline, source map, runtime
  table, `RIG_VERIFY_PROOFS`), SPEC §1 and §2 lines (§10.3), CORE §9
  bullet marked *(built)* (§10.2), AGENTS map, test/README.

## Holes in the design text, and what was done

Each was found by the debug assertion firing, and each fix only
narrows what is proven (no broader rule):

1. **`continue` in a `while` condition.** §4.3 says the step sees the
   body's starting facts less the body's writes. A `continue` in the
   condition (`while (o ?? continue) > 0 and i < n : i += 1`) reaches the
   step before the guard after it ran. Fix: when the condition holds a
   `continue`, the step starts from the loop's entry facts.
   Test: `cond_continue_mut.rig`.
2. **`match` arm guards.** An arm runs after earlier arms' guards ran and
   failed; a guard that writes `i` (`1 if bump(!i) => ...`) changes what
   later arms see. Fix: every arm starts from the subject's facts less
   every guard's writes. Test: `match_guard_mut.rig`.
3. **Assignment order (found by the independent review).** §4.3/§5 say
   an assignment's value runs before its target. Emit guarantees that
   only when the value can act (`actsBeforeStore`); otherwise it writes
   `place = value` and Zig finds the place first. G2 from the value
   (`t[i] = src[i]`, `t[i + 1] = t[i]`, `ps[i].x = src[i]`) proved the
   target, and with `i = -1` a release build stored outside the slice.
   Fix: the target's indexes are walked from the facts before the value
   less the value's writes, which hold in either order. Tests:
   `assign_order_mut.rig`, `shift_up_mut.rig`.
4. **Order within one expression.** Not a firing hole, but the design
   relied on written order inside an expression (a `fits` from an
   earlier argument proving a later `+`). Every part of an expression is
   now walked from the facts before it, with every write in the
   expression applied before and after (`walkAtomic`).
5. **G2 for `!s.write[T, e](i, v)`.** `v` is any expression and may write
   `i` (`!s.write(i, f(!i))`); the facts are added only when nothing in
   the statement writes `i` or re-points `s`.

## Deviations

- The proven read/write helpers are `rig.readIntProven(...)` /
  `rig.writeIntProven(...)` with the trailing `.both` etc., not a 5th
  argument on `rig.readInt`, so every unproven site emits exactly what
  it did before (equiv shows differences only at proven nodes).
- `rig.atProven(s, i, .upper)` stands where the sign is unknown (the
  sign test is still made); `rig.at(s, i)` stands where nothing is
  proven.
- §8.2 #22 (fields): the twin uses a local copy of the field, since a
  field is never a subject in round 1. #24 (`n -= 2` after `i < n`)
  cannot panic in round 1: an `Int` bound proves only adds, and a later
  `n` does not change what the guard showed of `i`. It is kept as an
  "absent from the dump, runs clean" pair.
- A literal bound (`while j < 3`) is no bound (§2.1), as designed.

## Temptations noted, not acted on (round 2)

- False edges (`return x if i >= n`), fixpoint/shift rule (the guard's
  own `i + 8`), `n = s.len` equalities, `for` index/range facts, owned
  `String` / `List` / `[N]T` bounds, `isNonNegativeIntLiteral` folding.
- A more precise step state for a condition `continue` that comes after
  the guard (round 1 drops all guard facts whenever the condition holds
  any `continue`).
- Note for round 2: `String.length()` tests only up to `Int.max`, so an
  owned `String` bound must go through the `max_len` test before `fits`
  can hold for it (the reviewer's note).

## Open questions

1. `raw` blocks: the pass kills every fact at a `raw` block's exit, but
   a raw block that stored the address of a local somewhere and a later
   raw-free write through it would be invisible. Raw is the boundary
   (SPEC §15); is that acceptable for round 1?
2. `--release=fast`: an overflowing checked `+` in a guard is already
   undefined behavior there; proofs built on such a guard inherit that.
   Fine by SPEC §1, but worth a sentence?
3. The walk-order test compares assignments only (each function body,
   outside closures, defers, and `raw`). It catches a moved step or
   reordered statements; the value/target order inside one assignment is
   covered instead by walking the target from what holds either way.

## Trig findings (coordinator, Rig 990221765 / Trig 3fc96ea)

### 1. The length test at every read blocks inlining

What this PR changes: on main, `rig.len` was `@intCast`, whose safety
test (`n <= Int.max`) and panic path were already at every `s.len` read
in safe builds; that is what Trig measured. This PR replaces it with
`n <= 2^62 - 1`, the same one compare, and moves the panic out of line:
`lenPanic` is `noinline` with a cold branch hint, and the conversion is
then an exact `@bitCast`, so no second safety path is left. That fits
round 1 (it is `rig.len`). Whether it is enough for LLVM to inline
`skip_space` again is for Trig to re-measure.

Round 2 candidate (recommended, as its own reviewed change): make
`fits(s)` hold where a length is made, so a read needs no test. Where
every slice-view length comes from:

| Source | Length |
|---|---|
| a String's bytes (`String.bytes()`, `?t[..]`) and a List's items | an allocation's, through `defaultAllocator`: at most the address space (2^48 on arm64/x86-64), for elements of at least one byte |
| an array, `?a[..]`, `!a[..]` | a compile-time `N`, at most `max_value_bytes` |
| a string literal, a `Static` | compile time |
| slicing (`rig.slice`, `sliceMut`) | at most its source's |
| `os.args()` | the OS's, bounded by its argument limit |
| a Zig-backed std function's or `extern`'s result, a slice made in `raw` | whatever the foreign code says: not established by Rig |
| a slice of a zero-size element type | memory does not bound it; only a counter does |

Sound if: memory-backed slices of elements of nonzero size are bounded
by the address space (a fact of the target, as `max_len` already
assumes); the foreign row tests the cap once where the slice enters
(each Zig-backed declaration's result, `extern` results, and the end of
a `raw` block that makes a slice); and zero-size element types keep the
read test. The risk is the foreign row: every entry point must be
listed, and a new one added later without the test would make `fits`
an unchecked assumption, so it needs a positive list and a test that
fails on an unlisted entry point, as `facts.zig`'s import test does.

### 2. `m << m.leading_zeros()` is checked needlessly

The exactness test cannot fail: shifting by the count of leading zeros
loses no set bit. The amount test (below the width) still can, for
`m == 0` (`clz(0) = W`). This is the design's round-3 `range(x, lo, hi)`
rule (§9.2), not round 1. Recommendation: round 2 or 3, as a positive
rule on that exact shape (`x << x.leading_zeros()`, `x` a local not
written between), dropping only the exactness test, and the amount test
too under a `x != 0` guard. Until then Trig can write
`m <<% m.leading_zeros()` (from `bits`): no exactness test, amount test
kept.

## Measured evidence (arm64, Zig 0.17, ReleaseSafe asm of the emitted package)

SWAR loop (`i = 0; while i + 8 <= s.len: w = s.read[U64, .little](i); ...; i += 8`):

- Zig before: `rig.readInt(u64, s, i, .little)`, `i += 8`;
  after: `rig.readIntProven(u64, s, i, .little, .both)`, `i = rig.addProven(i, 8)`.
- asm before, per iteration: the guard (`adds #8; b.vs`, `cmp; b.gt`),
  then the read's sign (`tbnz x9, #63`) and range (`subs; b.lo`,
  `cmp x10, #7; b.ls`) tests before `ldr`. After: the guard only
  (`adds x9, x8, #16; b.vs` fused with the next `i + 8`, `cmp; b.hi`),
  then `ldr`. Three tests gone.

`while i < s.len` scan (skip_space from `i = 0`):

- Zig before: `rig.at(s, i)`, `(i + 8) <= ...`, `rig.readInt(...)`,
  `i += 8`, `i += 1`; after: `rig.atProven(s, i, .both)`,
  `rig.addProven(i, 8)`, `rig.readIntProven(..., .both)`,
  `i = rig.addProven(i, 8)`, `i = rig.addProven(i, 1)`.
- asm loop before: 20 instructions with 7 test branches (`tbnz` sign of
  `s[i]`, `adds/b.vs` for `i + 8`, `sub/cmp/b.lo` for the read, `adds/b.vs`
  for `i += 1`); after: 13 instructions with none but the loop's own
  `cmp`s.
- A plain `while i < s.len: t +%= Int(s[i]); i += 1` loop was already
  vectorized with no tests by LLVM before; unchanged.

Debug still asserts: the debug asm of the same scan has 7 calls of
`rig.runtime.proofPanic` (s[i] lower and upper, three adds, the read's
two), the ReleaseSafe asm none; and the holes above were each found by
that assertion firing in a debug run.

### 3. SIMD reads (Trig, on the unmerged `simd` branch)

Under `while i + 16 <= s.len`, `s.read[Simd[U8, 16]](i)` keeps its range
test (`cmp/b.hi`, `cmp/b.ls`, about 4 instructions per block). Round 2,
once `simd` lands: treat a `Simd` read as a `read[T]` of `@size(T)`
bytes. In round 1 the width comes from `numSize` (integer and float
types only), so a `Simd` element call proves nothing (positive list); the
rule needs `numSize` to answer `N * @size(E)` for `Simd[E, N]`, the
proven helper on the vector load, and its own `proof.` uses and twins
(§9.3 of the design).

## Gates (combined tree: main 990221765 with bits #122, spanclamp #123, rtfast #121)

- `./test/run --delta`: 3,304 passed, 0 failed, 0 known, 3 pending.
- `./test/run --delta corpus`: 10,032 passed.
- `test/matrix.py --delta`: 8,180 programs, 4,666 ran clean, 3,514 rejected, 0 failed (the `proof.` grid's 1,040 cells included; it also ran alone, 1,040/1,040).
- `./test/run oracle`: 5/5. `zig build test`: pass.
- Equiv vs 990221765: 12,728 programs; 4,684 differ only in `pkg` (the runtime), 59 in `emit` and `pkg`; every emit difference is a proven-site substitution (atProven 24, readIntProven 7, elemPtrProven 8, addProven 38 programs, proven `+=` 36). No difference in parse, normalize, check, `--facts`, `--facts=sema`, `--facts=storage`.
- strput (#124) landed after gating; it merges cleanly and was not gated here.
- Independent review: two passes; the first found hole 3, the second (18 more probes) none.

PR: https://github.com/shreeve/rig/pull/126 (auto-merge not enabled).
