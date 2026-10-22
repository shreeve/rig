# PR notes: proven checks on units (`proofs2`)

Design: `.git/revamp/r3/design-proofs-v2.md` §9.2 (v1's CORE bullet and
SPEC sentences stand, marked built). Branch `proofs2`, from `loopfacts`
(e93638c1d) with origin/main d9b6328da merged in. Depends on loopfacts
(#134): merge origin/main again once it lands. The walk reads
`JumpDest` through `jumpDestOf` only (none of `sema.breaksOut` /
`breakValues` / `hasValueBreaks`), so loopfacts' review change is a plain
merge.

## What is built

- Taken from `proofs` (17a670f0b) by path or 3-way patch: `recordWrite`
  and the write sites (resolve, typecheck, sema), `Proven` / `provenOf` /
  `--facts=proofs`, emit's four sites, the runtime helpers, `rig.len`'s
  2^62-1 cap (noinline cold panic), `RIG_VERIFY_PROOFS`, the
  `test/behavior/proofs` pairs, `facts_proofs.sh`, `emit_shapes.sh`, the
  `proof.` grid, the docs. Merged with main's SIMD and byte-access
  changes: a `Simd` read/write is never proven; the proven byte helpers
  panic with main's `bytesPanic` message (`provenOffset` returns null for
  an unproven test that fails).
- `rig.eachUnit` (one positive list; `structured_kinds` is the
  skeleton, every other statement is a unit; leaves are no unit),
  `rig.eachGuardOperand` (guard parts split at the top `and` chain),
  `rig.eachBody`, `rig.selectionParts`. The storage plan records
  `unitOf` / `unitRootKind` (`SemContext.unit_of`, outside `--facts=sema`;
  marking stops at nested blocks).
- `src/proofs.zig`: subjects, facts, `Kills`, gens, uses kept; the walk
  rewritten on units: `A(u) = E - K(u)` (an assignment's own store left
  out of `K(u)`), gens only on a unit's exit, the skeleton of v2 §2.3
  (guard parts in order, `L = E - K(loop)`, step from the meet of the
  body end and every `.step` jump, selection then arms, `match_rereads`
  proves nothing, jumps less every pending defer, `raw` opaque, a dead
  state as the meet's identity). E1: `eq(n, s)` after `n = s.len`,
  converted at gen time.
- Emit: `enterUnit` / `leaveUnit` at each unit's code (statements, values,
  guard parts, a `for` source until the loop starts, a `match`'s
  selection paused around each arm); `inUnit`, on in every debug build of
  the compiler (`facts.check_units`), asserts every expression, set,
  check site, and hidden storage (not a statement slot's declaration) is
  written in the unit that holds it. `RIG_NO_PROOFS=1` ignores `provenOf`.
- The unit-order test (`proofs.checkUnitOrder`): every debug build of the
  compiler traces emit's units (a continue-expression step re-ordered
  after the body) and jumps and checks them against the walk: same
  units, same nesting, the units of each block in the same order, each
  jump to the same `JumpDest.To`. A unit test runs it over
  `test/behavior/{emit,proofs}` and checks a swapped pair and a
  misdirected jump fail it.
- `./test/run --proofs-diff[=all]`: debug, `--release`, `--release` with
  `RIG_NO_PROOFS=1`; same stdout, exit, panic message; no proven check
  failing.
- `test/matrix.py` `unit.` grid: 21 forms (call, binding, name,
  compound, element, element compound, four target roots, return, while
  plus a `continue` in its condition, body, and step, if/else, guarded
  match, value if/and/match, defer) x write (`bump(!i)`, `|!i|` closure,
  nested `i += 1`, none) x write slot x use (`s[i]`, `read[U32]`, `i + 1`,
  `!s.write[U32]`) x use slot x guard (`if`, `while`, `c = s[i]`). Its
  model is per form: the slots whose write ends the guard's facts at the
  use's slot. Default run 366 cells (bump/s[i]/if for every slot pair,
  plus no-write for every slot under each guard); `--deep` 4,782.
- Tests: the four round-1 holes and both rev126 probes as
  `test/behavior/proofs/*` (`call_target_mut`, `call_target_compound_mut`,
  `index_writes_mut`, `value_block{,_mut}`, `len_equal{,_mut,_write}`),
  and unit tests (holes, value guards, E1 x3, eachUnit's list).
- Docs: INTERNALS "Proven checks" rewritten as the unit desugaring (units,
  facts, the skeleton table, the three checks), `unitOf` in the facts
  table, test/README (`--proofs-diff`, `unit.`), matrix docstring.

## Holes, and what makes each impossible

| Hole | Now |
|---|---|
| 1 `continue` in a `while` condition | the jump carries `A(p)` of its guard part to `.step`; the step starts from the meet |
| 2 a match guard writes `i` | all guards are one selection unit; arms start from its exit |
| 3 `t[i] = src[i]` | G2 only on the unit's exit |
| 4 `pick(!t, !i)[0] = s[i]` (rev126, both probes) | `!i` is in `K(u)` |

No new hole was found in the unit rule. Nothing was patched around.

## Finding: `int_bound_write_mut.rig:10` (pup suite at abdac66d1)

`cli/facts_proofs` failed: `+ no_overflow is proven, but the program
shows it can fail` at `return i + 1 + n` in

    n = s.len; i = at; if i < n: n -= 2; return i + 1 + n # keeps

Not a platform difference: the Mac dump is the same (`10:12 + no_overflow`);
my Mac `./test/run proofs` run had failed `cli/facts_proofs` earlier on
the one-byte `read[U8, .little]` files, and I did not rerun the CLI test
after fixing them.

Cause: E1, as designed (v2 §4): `n = s.len` gives `eq(n, s)`; the guard
`i < n` gives `below(i, 1, int n)` and with it `below(i, 1, len s)`, which
lasts while `i` and `s` do, so `n -= 2` ends only the first. `i + 1 <=
s.len <= 2^62 - 1`, so the add cannot overflow: the proof is true. The
`# keeps:` mark was round 1's, which had no E1; its own comment said the
add "cannot overflow ... Round 1 drops the fact all the same". The rule
and the implementation agree; the test's expectation was stale.
Classification: a stale test, not a soundness hole (no wrong proof).

Siblings checked: every derived `below(_, _, len s)` dies when `i` is
written or `s` re-pointed (`len_equal_mut.rig`, E1 unit test 3); `eq`
dies when `n` is written (E1 unit test 2: `s[i]` after `n = s.len` under
an older `i < n` stays unproven); `len_equal_write.rig` (`s[i]` after
`n -= 2`, proven) is the same shape as the failing one. Fix: the test
keeps its intent with a bound that is no length (`n = m`, nothing
proven), and `len_equal_add.rig` pins the original shape as proven.

## Deviations and choices

- Value-position guards prove nothing (owner decision); `i += 1` in a
  value `match` arm under an outer guard is no longer proven either.
- G4 (`fits`) is made only where a length is surely read: a guard part's
  `s.len` bound and `n = s.len` / `i = s.len`.
- G2 for a call statement is the `!s.write` statement only.
- A `propagate` statement does not end a block's path (only
  `return`/`break`/`continue` statements do).

## Structural changes after the first review (d95173024, c4b544760)

1. `rig.stmtClass` places every IR tag (structured, unit, raw, none) in
   an exhaustive switch: a new tag fails to compile until placed; a
   `none` tag met as a statement is an opaque unit, and kills every fact
   (`collectKills`).
2. `rig.skeletonOf` is the one skeleton: `eachUnit` lists units by it
   and `proofs.walkStmt` switches on it (exhaustive over the union).
3. The unit-order test checks every occurrence: a unit's code starts
   once; only `pause`/`resume` (a `match` selection around each arm, an
   `as` part's held value) may write more of it; each jump is written
   once. The unit test checks a duplicated unit fails it.

## Measured (arm64 Mac, Zig 0.17, `--release`; input from `os.args()`, the loop inlined into `main`)

Before = main (d9b6328da), after = proofs2 (abdac66d1).

| Loop | Before | After |
|---|---|---|
| SWAR `i = 0; while i + 8 <= s.len: w = s.read[U64](i) ...; i += 8` | 15 instructions, 7 conditional branches per iteration (overflow of the guard's add, guard, read sign, two read range, the count's add, the back edge) | 10 instructions, 4 branches (the read's three tests gone) |
| scan `i = 0; while i < s.len: c = s[i] ... s.read[U64](i) ... i += 8 / i += 1` (skip_space) | 26 instructions, 11 branches (sign of `s[i]`, `i += 1` overflow, `i + 8` overflow, read range) | 19 instructions, 7 branches: no test left in the loop |
| `n = src.len; while i < n and src[i] != 0: i += 1` | 5 instructions, 2 branches | the same: LLVM already proves it once inlined with `i = 0`. The emitted Zig changes (`rig.at` to `rig.atProven(src, i, .both)`, `i += 1` to `rig.addProven`), which matters where LLVM cannot see `n == src.len` |
| std/json.rig's loops (`skip_space`, `take_digits` + `take_last_digits`, the U64 tier of `skip_plain_ascii`, copied verbatim) | `main` 445 instructions, 79 conditional branches | 430 instructions, 70 branches |

std/json.rig itself: `rig check --facts=proofs` lists 35 proven tests
(index uppers, the U64 reads' uppers, `skip_space`'s read both ways,
every `+=` and guard add in the scanning loops).

Debug still asserts: the debug builds hold 4 (swar), 8 (scan), 4
(lenvar), and 13 (json loops) calls of `rig.runtime.proofPanic`; the
release builds none. RIG_NO_PROOFS=1 emit of every program equals main's
(d948f6af7) emit byte for byte; the 65 programs whose emit differs with
proofs differ only on lines holding a `*Proven` helper (addProven 53,
atProven 37, elemPtrProven 10, readIntProven 10, in the abdac66d1 run).

## Gates (pup, Linux x86_64, `GATES_DELTA=1`, head 7ca32904a = c4b544760 + main f1e066202)

- suite: 3423 passed, 0 failed, 3 pending (2 json data groups skipped:
  no fetched data on pup).
- corpus: 10046 passed, 0 failed.
- matrix: 9040 programs, 5440 ran clean, 3600 rejected, 0 failed (the
  `proof.` grid and the default `unit.` grid, 366 cells, included; the
  full run at c4b544760 took 3787 s, this one carried it over).
- unit (`zig build test`, fresh cache): 159/161 passed, 2 skipped.
- oracle, doc, vocab: 399 passed, 0 failed (oracle silent).
- `./test/run --proofs-diff behavior examples corpus`: 11210 passed, 0
  failed (debug, `--release`, `--release` + RIG_NO_PROOFS=1 agree on
  every program with a proven test).
- Mac: the `unit.` grid 366/366; `rig emit` of all 11.6k programs with
  the containment assertion and the stricter order test: no internal
  error; RIG_NO_PROOFS=1 emit equal to main's for every program.
- equiv (abdac66d1 vs d9b6328da): 12835 programs, 4835 differ: 4463
  `pkg` only (the runtime), 303 `sema`+`pkg` (loopfacts' `jump_dests`),
  3 `check`/`facts` (loopfacts' moved diagnostics), 66 `emit`: each a
  proven-site substitution (checked by RIG_NO_PROOFS=1 equality above).
- Not run: the `unit.` grid with `--deep` (4782 cells), for the deep
  gate.
PR: https://github.com/shreeve/rig/pull/138

## Re-check follow-up (1b39121f4)

- `placeUnits` now rejects a resume after a later unit: while a unit is
  paused, only units inside its construct (a `match`'s arms; none for an
  `as` part) may start, and no unit stays paused. The unit-order test
  moves a real resume past the next sibling's unit and must fail (it
  fails with the check disabled, on drop_value_payload.rig among others).
- `test/behavior/proofs/held_as.rig`: a held `if mk(s[i]).o as r` with
  `s[i]` proven in the held value and the body.
- pup: `./test/run --delta` 3424 passed, 0 failed; unit 159/161 (2
  skipped). Emit is unchanged; `rig emit` of every program passes the
  stricter check.
