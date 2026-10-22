# REVAMP-3 audit: HANDOFF steps 3–6 (the Core's planned rules)

Read-only audit of `main` 2d9e490f (== `rig-revamp` worktree base), compiler
`.git/revamp/r3/rig-base`. Every probe ran under `RIG_SANITIZE=1`.

- Probes, outputs and results: `.git/revamp/r3/probes/steps3-6/`
  - `run.sh` (RIG= override; check, then sanitize-run if accepted; `file.out` per probe)
  - `results-{reads,containers,loans,emit-docs-kinds,new}.txt`: one line per probe (`OK`, `OK!rc`, `REJ <first error>`)
  - `reads/ containers/ loans/ emit/ docs/ kinds/`: the core-audit probes, re-run (378 files)
  - `new/`: 58 new probes for this audit (n01–n44, n33b–n33s)
  - `proto-d3-d6/`: a measurement prototype of decisions 3 and 6 (typecheck.diff, std-text.diff) and its effect on
    every `.rig` file and doc example (`final-diff.tsv`; 6,254 programs checked with both compilers)
- Line numbers: `src/*.zig`, `rig.grammar`, `std/*` at 2d9e490f. "M:" lines in the old reports are stale; every
  citation below is current.

---

## 0. Summary

1. **One critical hole (C1), found in step 5's area:** a bare *block-local* owner at the tail of a value block
   (an `if`/`match` branch, a `catch` handler, a `while … else`) is moved by emit but not by the ownership
   checker, so the block's `defer` still sees it live. A `defer` that writes it reallocates a buffer the result
   now owns: **use of freed memory** under the sanitizer, in 7 accepted shapes (§1).
2. Step 3 and step 4 only turn rejections into acceptances; no accepted program changes meaning. Every gap row
   from `reads.md` and `containers.md` is still open except: the strings branch landed (Text rows built), B3 is
   now a rejection, B4 (`*[…]` indexed) is fixed. Two Core status claims are stale (§2.5).
3. Step 5 measured on the current tree: decision 3 newly rejects 4 behavior tests, changes 3 reject tests, 17
   corpus probes, and needs `std/text.rig:144` rewritten in the same commit (otherwise 12 behavior, 10 reject,
   10 doc examples that `use std.text` break). Decision 6 newly rejects 1 behavior test, 2 SPEC examples, 5 corpus
   probes. `=!` → `const`: 168 statement lines in 111 `.rig` files, 24 comment lines, 27 doc lines, 9 test
   expectations.
4. Step 6's "whole-program parameter summaries" are not a planned Core rule; they are consolidation of
   sentence 9 (per value). Sentence 7's narrowing is planned but, like the Bool long form, has no `rig pending`
   example. Both need a design-owner nod (OQ11, OQ12).
5. Order: decisions 3, 5, 6 (commits 5.1–5.3) depend on nothing and can land before step 1. Everything else in
   steps 3–6 needs step 1's facts, step 2's `handsOver`, or both (§4). The C1 hotfix should land now.

---

## 1. Critical: accepted programs that are unsound

### C1. A block-local owner moved out of a value block's tail is still live for the block's `defer`

```rig
sub main
  c = true
  x = if c
    v: Vec[Int] = Vec()
    !v.push(1)
    defer
      for i in 0..100
        !v.push(i)
    v
  else
    w: Vec[Int] = Vec()
    w
  !x.push(3)
  print(x.len, x[0])
```

`rig check` accepts it; `RIG_SANITIZE=1 rig run` dies with `rig: use of freed memory` in `x.v.push(3)`
(`new/n33f_block_tail_bare_vec_defer.out`). The emitted Zig is
`break :blk rig.take(&__rig_alive_v, v);` followed by the block's `defer`, which pushes into the moved-from
copy, reallocates, and frees the buffer `x` now owns.

**Shapes accepted and crashing** (all `OK!134`, use of freed memory):

| Probe | Sink | Tail |
|---|---|---|
| `n33b_block_tail_move_defer_realloc` | binding | `if` branch, struct with a Vec field |
| `n33f_block_tail_bare_vec_defer` | binding | `if` branch |
| `n33j_fun_tail_if_defer` | function result | `if` branch block in a `fun`'s tail |
| `n33k_match_arm_tail_defer` | binding | `match` arm block |
| `n33l_catch_handler_tail_defer` | binding | `catch \|_\|` handler block |
| `n33p_while_else_tail_defer` | binding | `while … else` value block |
| `n33s_field_block_tail_defer` | field assignment | `if` branch |

`n33_block_tail_move_defer_writes` (no reallocation) is accepted and prints `2 1`, the moved-from copy's
write landing in `x`'s buffer: wrong output without a crash.

**Sibling sites checked and correctly rejected** ("use of `v` after move"): `<v` at the block tail
(`n33e`), `return <v` (`n33g`), `break <v` (`n33h`), `x = <v` (`n33i`), a closure body's tail (`n33m`), a
function body's direct tail (`n33q`, `n34`). A defer that drops (`-v`) is rejected by the defer rule
(`n33c`, `n33d`). An `errdefer` that writes is not reached on the success path (`n33o`, correct).

**Root cause (two passes decide the move differently):**

- emit moves by syntax: `Scan.consumeTail` (`src/emit.zig:5617-5635`) marks every bare name in a tail position
  of a block, `if`, `match`, `??`, or `catch` as consumed, and `emitName` emits `rig.take` for it
  (`src/emit.zig:2971`).
- ownership never moves it before the block's exit:
  - `walkBlock` (`src/ownership.zig:1422-1439`) walks the tail with `walkStmtValue` (1431), then `popScope`
    (1437), which runs the block's defers with the name still live;
  - `walkTailBranch` (`src/ownership.zig:1597-1606`) moves the tail name with `consumeTailName` only after
    `walk(body)` has already run the body's defers, and only for `sink == .ret` (1616);
  - `checkNoImplicitCopy` resolves the tail name by text before the block's names exist
    (`self.find(self.text(expr)) orelse return`, `src/ownership.zig:2317`), so a block-local tail is never
    reported or moved. (The same lookup finds an *outer* name of the same text: `n29` passes only because the
    outer `r` is an `Int`; `n30` is a false rejection.)

This is the AGENTS class "the checker checks exactly what is emitted" plus "leaving a scope": the emitter adds
a move the checker did not walk, at a point before the scope's exit.

**Fix (class):** the checker records the move at the tail statement, before the scope's exit runs defers, for
every sink (binding, field, argument, result, `break`), and emit reads that recorded fact instead of
`Scan.consumeTail`. Hotfix now (small, `src/ownership.zig` only): in `walkBlock`, when the block is a value
block and its last statement is a bare name of a var declared in this scope with an owning kind, `moveVar` it
before `popScope`; delete the after-walk `consumeTailName` call for that case. Class fix: step 5.4 on top of
step 2's `exitTo`/`takeLeaf`. Tests to add: the 7 shapes above as reject tests ("use of `v` after move" at
the defer), the 4 reads-only shapes as behavior tests, and a `test/matrix.py` axis "block-local tail ×
{defer write, defer read, errdefer} × {binding, field, result, argument}".

**Also stale:** Core sentence 1 says a block's last value "takes `<x` today" (`docs/CORE.md:123-125`), and
SPEC says only `return x` or a function's last expression moves bare (`SPEC.md:2515-2518`). In fact a
block-local name at a value block's tail already moves (`n18`, `n31`, accepted and correct without defers).

No other accepted-but-unsound program was found among the 436 probes (378 re-run + 58 new). Accepted probes
that the old audits flagged are now sound: `loans/c10`, `c10b` (B4 fixed, run clean); `reads/q01`–`q14`
(temporaries, run clean); `loans/c01` (`*V(r: ?a)`, every escape caught).

---

## 2. Refreshed gap tables

Status: **gap** (still rejected or wrong), **fixed**, **changed** (different behavior or message).
"Was" is the result recorded in the core-audit reports (main dd36c78 / strings branch).

### 2.1 Step 3: reads and lends (`reads.md` §1)

| Probe | Rule | Was | Now (2d9e490f) | Status | Current site |
|---|---|---|---|---|---|
| `a02`, `a05`, `containers/l01` | bare arg to `?T` | rejected, "lend a read borrow" | same | gap | hint `src/typecheck.zig:7105-7111` (`mismatch`); take check `src/ownership.zig:1557-1576` (`walkConsumed`) → `2307` |
| `a03`, `g01`, `containers/g01` | bare Copy / literal to `?Int` | rejected | same | gap | same |
| `f01`, `f03`, `f05`, `docs/p05`, CORE L144 | `for x in v` over a Vec | rejected "write `for x in ?v`" | same | gap | `src/typecheck.zig:1585-1589`; `1750-1757` (resource Vec); ownership `walkFor` `src/ownership.zig:3703-3742` (`resource_vec` keyed on written mode, 3731); emit `emitFor` `src/emit.zig:2133-2140` |
| `f06` | `for` over an array lends | lend (SPEC says copy) | same | doc gap | `src/ownership.zig:3720-3733` |
| `i01`, `i03`, `docs/p06` | `if o as x` over an owning optional | rejected "would alias" | same | gap | typecheck `checkOptionalBinding` `src/typecheck.zig:1477-1508`; ownership `walkConditionParts` `src/ownership.zig:3472` (`walkConsumed(.binding)`) |
| `m03` | `match b` on a Box | rejected "`match ?b`" | same | gap | `src/typecheck.zig:1845-1862` |
| `m05` | `match h` on `*E` | rejected "cannot `match`" | same | gap | `src/typecheck.zig:1863-1871` |
| `l01b` | bare array to `[]T` | rejected | same | gap | `src/typecheck.zig:7012-7017` |
| `l02`, `l02b`, `l03`, `l14`, `containers/l02`, `p02`, `l06` (shuffle), `docs/p13`, `p18`, CORE L485 | Vec lends `[]T` / `![]T` | rejected | same | gap | no row: `checkExpr` chain `src/typecheck.zig:6929-6933` |
| `l04`, `l04b`, `docs/p17` | `*T` lends `?T` | rejected | same | gap | no row |
| `l04c` | `*T` members read | works | same | built | — |
| `l05`, `l05b` | Box lends `?T` | `?b` works, bare rejected | same | gap (bare) | `boxLent` `src/typecheck.zig:7071-7088` |
| `l06`, `l07`, `l07b`, `x06` | `X?` lends `View?` | rejected | same | gap | no row |
| `l06b` | `if ?o as x` gives `x: ?S` | works | same | built | — |
| `l08`, `l16`, `l08b`, `l08c` | callables | fn bare ok; closure, owned closure need `?`; alias `?F` bug | same | gap | `lendCallable` `src/typecheck.zig:7807-7836` |
| `l11`, `l12`, `n21` | Box composes | rejected | same | gap | `boxLent` one level (`7084`); members `src/typecheck.zig:3738`, `6317` |
| `l13` | `![]T` → `[]T` | works | same | built | `src/typecheck.zig:6940` (`recordReadView`) |
| `l15`, `x10` | `*Text` → String | rejected | same | gap | no row |
| `x01`, `x04`, `x05`, `x07`, `x08`, `x12`, `x13` | Text rows | branch only | **built on main** | fixed (strings landed) | `textAsString` `src/typecheck.zig:7036-7069` |
| `x02` | bare Text → String | rejected | same | gap | `src/typecheck.zig:7058-7063` |
| `x03`, `x05b` | `for b in t` (Text / `?Text`) | rejected | same | gap | `src/typecheck.zig:1803-1810` (only `mode == .read`) |
| `x08b`, `x09`, `docs/p07`, `containers/br_t07`, `br_x08` | `Box[Text]`, `Box[Vec]` members | rejected | same | gap | `src/typecheck.zig:3738` (fields), `6317` (methods) |
| `x11` | `self.title[..2]` read bare | rejected "write `?self.title[..2]`" | same | gap | `src/typecheck.zig:4446` |
| `v01`, `loans/o01`, `docs/p08` | plain struct copied out of a view | rejected | same | gap (step 1 `copyable`) | `src/typecheck.zig:6950-6957` |
| `g03` | `?(a if c else b)` | rejected | same, new wording | changed | Core §3 says planned |
| `q01`–`q16` | §3 temporaries | main rejected, branch accepted | **as Core §3** (q01–q07, q09, q10, q12–q14 run clean; q08, q11, q15, q16 rejected as §3 says) | fixed | — |
| `s01`–`s03` | `for` over a branching Vec | branch double-free | rejected "bind this to a name first" | fixed (sound) | `src/typecheck.zig:1595-1597` |
| `t01` | `return b` / tail moves bare | accepted | same | built | `src/ownership.zig:3357-3385` |
| `t02`, `n25`–`n27` | `break b`, value `if`/`match`/ternary of an outer owner | rejected | same | gap (OQ1) | `src/ownership.zig:3913` (`walkConsumed(value, .brk)`) → `2338` |
| `n18`, `n31` | block-local tail moves | (not probed) | accepted, moves | **built, undocumented; unsound with defer (C1)** | `src/emit.zig:2971`, `5617-5635` |
| `w01`, `r04`, `r06` | write lend / consuming receiver stay written | rejected | same | correct | — |

### 2.2 Step 4: containers and assignment (`containers.md` §1)

| # | Rule | Was | Now | Status | Current site |
|---|---|---|---|---|---|
| 1 | Vec holds any type (`v01`–`v03`, `v05`, `v06`, `h05`, `l04`, `br_t01`, `br_t05`, `c01`, `n42`, `docs/p04`, `p24`, `p27`, `p33`, CORE L535) | rejected | same | gap | `src/resolve.zig:2125-2131` (`builtinElementError`) |
| 2 | arrays hold any type (`a01`–`a06`, `br_t06`, `l03`, `docs/p26`) | rejected | same | gap | `src/resolve.zig:645-648`; literal `src/typecheck.zig:4520-4523` |
| 3 | slices of owners (`s01`, `s02`, `br_t03`, `docs/p28`) | rejected | same | gap | `src/resolve.zig:662-665`; `vecSliceElem` `src/typecheck.zig:4400-4409` |
| 4–5, 7 | `v[i]`, `?v[i]`, `!v[i]`, `+v[i]` of owners (`v04`, `h01`, `h02`, `h04`, `br_t02`, `loans/c13`, `docs/p12`, `p29`) | rejected | same | gap | `indexInto` `src/typecheck.zig:4374-4379` |
| 6 | `<v[i]` of an optional owner | blocked by row 1 | same; plain optional works (`p03`), array optional works (`docs/p37`) | gap | row 1 |
| 8 | element assignment drops old | rejected | same | gap | `src/typecheck.zig:914-917` |
| 9–10 | swap / sort for any element (`p02`, `l06`, `br_t03`) | rejected | same | gap | §4 Vec row; row 3 |
| 11 | loops over arrays of Cell-holders bind a view (`c02`) | rejected "a copy" | same | gap | `src/typecheck.zig:6341` |
| 13 | `v.get(i)` for owners (`n44`) | rejected | same | gap / OQ9 | `src/typecheck.zig:6364` |
| 15 | §6 evaluation order (`o01`, `o02`, `o03`, `docs/p38`) | built | same | built | — |
| 16 | `w = !n` re-points a local (`b01`, `b11`, `n41`, CORE L589) | rejected | same | gap | `src/typecheck.zig:728-735` |
| 17 | `w = <w2` (B3) | silently wrote through | **rejected** "would write through" (`b17`, `b24`, `b25`) | changed (sound; gap remains) | `src/typecheck.zig:728-735`, `handsOverWriteBorrow` `820` |
| 18 | bare held write view on the RHS: local writes through (`b23`, `n14`), field rejected (`b13`) | inconsistent | same | gap | `checkPlaceAssign` `src/typecheck.zig:893-895`; ownership `2338-2343` |
| 19 | `?T` place re-points (`b03`, `b04`, `n40`); `r = 5` rejected (`b18`, `b22`) | consistent | same | built | — |
| 20 | `![]T` local re-point (`b15`) rejected; field re-points (`b20`) | inconsistent | same | gap | `src/typecheck.zig:722-727` |
| 21 | parameters immutable (`b08`); `!T` param writes through (`b07`, `n23`) | — | same | built | — |
| 22 | `new` takes every form (`b06`, `b06b`, `docs/p23`) | parse error | same | gap | `rig.grammar:435` |
| new | a re-pointed **field** keeps the old loan (`n39`: `h.w = !n; m = 10` rejected) while a local releases it (`n40`) | — | false rejection | gap | `walkFieldAssign` `src/ownership.zig:2656-2700` unions loans |
| 23 | `os.env(?name)` over-borrows (`br_x01`) | branch | same on main | gap (OQ14) | `std/os.rig` `env` |
| 24 | `Rng` in containers (`l03`, `l04`, `docs/p09`) | rejected | same | gap (step 1 `unique`) | `std/random.rig:8-12` |

### 2.3 Step 5 rows

| Probe | Rule | Now | Status | Site |
|---|---|---|---|---|
| `f01`, `f02`, `f04`, `f07`, `f08`, `f16`, `f17`, `f18`, `f19`, `g04`, `n15`, `docs/p11`, `br_x11`, CORE L322 | error value meets `T!` only via `return` | accepted silently | gap (planned) | `compatible` `src/typecheck.zig:8206`; `checkReturn` `668-692`; closure returns `7969` |
| `f09` | `return e` | accepted | built | — |
| `s19`, `docs/p32` | Bool write call used as value | accepted (prints `show false`) | gap (planned) | `checkReceiverSigil` `src/typecheck.zig:6844-6849`; `startsNegationOperand` `1455-1475` |
| `s15`, `s18`, `docs/p36` | `=!` | accepted; `ok =! done` prints `false` | gap (planned) | `rig.grammar:127,218,386,431,433,461-462`; `src/rig.zig:305-307,419,435,723-724,1233-1235,1586-1587` |
| `s16`, `s17` | `=!` touching / rebinding | rejected | built | `src/rig.zig:723-724` |
| CORE L574 | `const x = e` | "Rig has no `const`" | gap (planned) | `src/rig.zig:1235`; `const` reserved `rig.grammar:91` |
| `t02`, `n25`–`n28`, `reject/ownership/loop_value_owning_without_move.rig` | `break x`, block tail of an outer name | rejected; `break <a` works | gap (OQ1) | `src/ownership.zig:3913`, `2307-2392` |
| `n18`, `n31`, C1 | block-local tail | moves (emit), unmodeled (ownership) | **unsound** | §1 |
| `k07`, `k08`, `k09`, `n19`, `docs/p15`, CORE L185 | `+x` of Vec, Box, owning struct | rejected | gap (planned) | `synthClone` `src/typecheck.zig:3515-3518`; emit `src/emit.zig:3317-3336` (`unsupported` at 3332) |

### 2.4 Step 6 rows (`loans.md` §2, §6)

| Probe | Rule | Now | Status | Site |
|---|---|---|---|---|
| `t01`, `t02`, `t03`, `t04`, `t08`, `t10`, `t11`, `c07` | literal/static into generic, Cell, owned closure | accepted | built | — |
| `t05`, `text_st06` | a Text's view into a Cell | rejected | correct | `src/ownership.zig:2853` |
| `t06`, `n09` | generic body storing `T` in a Cell, `T = String` from literals | rejected per type | gap (step 6) | `checkViews` `src/ownership.zig:578-590`; `requireNoView` `2429`, call site `2843` |
| `t07` | `String` parameter stored in a Cell | rejected | gap (step 6) | `src/ownership.zig:2844-2854` (param `ext` loan) |
| `t09` | owned closure captures a `String` parameter | rejected | gap (step 6) | `walkLambda` `src/ownership.zig:3242-3256` |
| `r01`–`r04` | result loans narrowed by signature | rejected (over-borrow) | gap (planned, S7) | `walkCall` `src/ownership.zig:2742`, result union `~2858`; `checkEscape` `3392` |
| `text_st05` | String-from-String over-borrow | rejected | not fixed by `produces` | — |
| `g01` | view of a module constant | accepted | built | `isGlobal` `src/ownership.zig:873` |
| `br_x01` | `os.env` result over-borrows its argument | rejected | gap, outside the Core | OQ14 |

### 2.5 Core status claims that are stale

1. Sentence 1 (`docs/CORE.md:123-127`): "a block's last value … take `<x` today". A block-local name already
   moves (n18, n31), unsoundly with a defer (C1).
2. §4 Text row "built" is now true (the strings branch landed); the core-audit's correction no longer applies.
3. Sentence 7: `os.env`'s result is not listed among whole-program views; a `String` from it over-borrows
   (`br_x01`). Only matters if the design owner wants it (OQ14).

---

## 3. Plans, by step, as landable commits

Column keys: **Own** = touches `src/ownership.zig`; **Cls** = touches typecheck's classification of
expressions. Both "yes" commits fall under "one branch at a time". "Flips" lists reject tests that must be
edited (each loses one or more `# error:` lines; files are not deleted unless every case flips). Every commit
runs the suite, `./test/run corpus`, `test/matrix.py` and `zig build test`; a refactor commit also passes the
IR-equivalence gate (`rig check --facts` dumps and every reject test's diagnostics unchanged).

### Step 3: reads and lends

Prerequisites: step 1 (lend representation: copy or pointer per read view; `copyable` for "a bare name copies
plain data", which also closes `v01`), step 2 (`handsOver`: only a place or a view lends implicitly; a literal
must not count as a place, as `isPlaceExpr` does today, `src/typecheck.zig:8395`).

| # | Commit | Files / functions | Rejections → acceptances | Meaning changes | Flips | New tests | Docs | Net LOC | Own | Cls |
|---|---|---|---|---|---|---|---|---|---|---|
| 3.1a | Lend through one `lendsAs` table | sema: `Lend`, `lendsAs`, `facts.lends` replacing `callables` (600), `views` (606), `unboxed` (609), `array_views` `.borrowed` (629), `text_lends` (643) and their accessors (1295-1407); typecheck: `checkExpr` 6929-6940 one call replacing `arrayAsSlice` borrowed arms (6998-7010), `textAsString` (7036-7069), `boxLent` (7071-7088), the lend half of `lendCallable` (7807-7836), `recordReadView` (6940); ownership `readsAsView` 1853, `isArrayView` 1908, `lentCallable` 1662 → `lendOf`; emit 2906-2934, 3157, 3281, `emitUnboxed` 2954 → `emitLend` | none (pure refactor) | none | none | unit tests for `lendsAs` rows | INTERNALS facts table | −80 | yes (readers) | yes |
| 3.1b | New lend rows: Vec, `*T`, `X?`, composition, callable alias | `lendsAs` rows `elems(Vec)`, `handle`, `optional`, recursion; emit `v.items()`, `&h.value`, `(if (o) \|*p\| … else null)` | `l02`, `l02b`, `l03`, `l14`, `p02`, `l06`, `docs/p13`, `p18`, CORE L485 (promote); `l04`, `docs/p17`; `l06`, `l07`, `l07b`, `x06`; `l11`, `l12`; `l15`, `x10`; `l08c` | none | none | one behavior test per row, plus a loan test per row (`!v` while `sort.sort(!v)`'s view lives, `-h` while `?h` view lives) | CORE §4 table: Vec, `*T`, `X?`, Box composing → built; std/sort.rig, std/slices.rig headers and STD.md drop `!v[..]` | +60 | small | yes |
| 3.2 | A bare place reads where a view is expected (arguments) | typecheck `checkExpr`/`mismatch` 7090-7111: bare place or view + read target → `Lend{implicit}`; ownership `walkConsumed` 1557: a recorded lend walks `walkBorrow(place, .read)` before `checkNoImplicitCopy`; emit arg path reads the fact | `a02`, `a03`, `a05`, `g01`, `containers/l01`, `containers/g01`, `l01b`, `l04b`, `l05b`, `l08b`, `l16`, `x02`, `docs/p21` | none: every such program is rejected today; a write lend stays written | `reject/types/missing_borrow_sigil.rig` (line 20 only; the `!x` case at 21 stays), `reject/types/array_as_slice.rig` (lines 25; 26 stays), `reject/types/closure_lending_hints.rig` (44-45), `reject/types/text_lent_as_string.rig`, `text_hints.rig` | bare arg to `?T`, `[]T`, String, `?fun`; a bare Copy arg keeps a loan for the call (`add(!n, n)` rejected as `add(!n, ?n)` is) | CORE S1 status; SPEC §4 "lending"; WELCOME | +40/−20 | yes | yes |
| 3.3 | A bare place reads in `for`, `if … as`, `while … as`, `match` | typecheck `checkFor` delete 1585-1589, `elementTypeForLoop` 1750-1757 and 1803 (Text), `checkOptionalBinding` 1477-1508 (owning bare place → `x: ?T`; plain stays a copy), `checkMatch` 1845-1871 (Box and `*E` through `lendsAs`); ownership `walkFor` 3731 (`resource_vec` from the lend fact, not the written mode), `walkConditionParts` 3472, `walkMatch` 3519 (`lent` from the fact); emit `emitFor` 2133-2140, `evalSubject` 2409, the `as` pointer capture | `f01`, `f03`, `f05`, `docs/p05`, CORE L144 (promote); `i01`, `i03`, `docs/p06`; `m03`, `m05`; `x03`, `x05b` | none (plain optionals still copy; a named array already lends, `f06`) | `reject/ownership/vec_for_no_borrow.rig`, `reject/syntax/for_vec_needs_borrow.rig`, `reject/ownership/box_vec_bare_iteration.rig`, `reject/types/box_match_owned.rig`, `reject/ownership/match_consume_borrow.rig` (line 22) | `n10` shape with a bare source stays rejected; writes to `o` inside `if o as x` of `Int?` stay accepted | SPEC §6 (`for` over an array lends, not copies), SYNTAX for-mode, WELCOME | +30/−40 | yes | yes |
| 3.4 | Box and handle members read through the table; a bare Text slice reads | typecheck member lookup 3738, 6317 (`lendsAs` unbox steps), `4446` | `x08b`, `x09`, `docs/p07`, `br_t07`, `br_x08`, `n21`, `x11` | none | `reject/types/box_value_access.rig`, `reject/types/text_forms.rig` (the `?self.title[..2]` case) | `!b.add("x")` on `Box[Text]`, `b.len` on `Box[Vec]`, `Box[Box[S]].n` | SPEC Box section | +30/−20 | no | yes (receiver resolution) |

Soundness risks: (1) the `optional` step must lend through a pointer capture into the owner's slot, never a
copy of an owning optional; (2) a `*T` view's loan must sit on the handle's binding so `-h`, `h = …`, and
`<h` conflict; (3) `Box[Text]`→String must keep `viewLoans` (`src/ownership.zig:1808`) on the box's root;
(4) generic inference `math.min(?a, ?b)` must infer `T = String` from a Text lend (`containers.md` §2);
(5) 3.3 changes three passes' reading of `For.mode`: record the effective mode once (in the lend fact) and make
`walkFor`/`emitFor` read only that.

### Step 4: containers hold anything; one rule for borrow places

Prerequisites: step 1 (`copyable` for `copy`/`fill`/`[n of x]`/`get`; `needs cleanup` for array drops; `may
hold a loan` for Vec of views; `unique` for `Rng`), step 2 (`handsOver`: `.place` vs `.part_of_made` for
`<v[i]` and `mk()[0]`), 3.1b (Vec → `[]T`, element lends).

| # | Commit | Files / functions | Rejections → acceptances | Meaning changes | Flips | New tests | Docs | Net LOC | Own | Cls |
|---|---|---|---|---|---|---|---|---|---|---|
| 4.1a | Admit owners in Vec, arrays, slices | `src/resolve.zig:2125-2131` (Vec: anything but a borrowed callable), `645-648`, `662-665`; `src/typecheck.zig:4520-4523`, `4400-4409`; array literal of owners takes each element (`walkConsumed(e, .element)`); runtime array into-iterator for `for x in <a` | containers rows 1–3 (owners); `n42` | none | `reject/types/vec_bad_element.rig`, `generic_vec_element_per_instance.rig`, `generic_inference_checks.rig` (Vec cases), `text_is_owned.rig` (line 13), `reject/modules/foreign_builtin_element/main.rig`, `array_of_resources.rig`, `array_of_resources_declared_later.rig`, `slice_element_owning.rig`, `reject/ownership/slice_resource_vec.rig` | `Vec[Text]`, `Vec[Vec[Int]]`, a record owning a Text, array of Boxes dropped at scope end, `sort_by` on `Vec[Text]`, generic body copying `xs[i]` with owning `T` rejected per instance | SPEC §2/§10 ("arrays cannot hold …", SPEC.md has it), STD | +40/−30 | small | no |
| 4.1b | Views in a Vec | Vec flow holds the union of pushed loans (`mayCarryBorrow(Vec[?T])`, `src/ownership.zig:4253`); write views unique per push | `v05`, `v06`, `loans/a06` | none | none | push `?a` then write `a` rejected; push `!a` twice rejected | — | +40 | yes | no |
| 4.2 | Every element is a place | `indexInto` 4374-4379 returns the element; `src/typecheck.zig:914-917` allows owner element assignment; emit reads an owning element via `constSlot`/`slot`, never `at(i)`; ownership treats `index` like `member` (already, `checkNoImplicitCopy` `.index` arm 2349-2360) | rows 4–8; `v04`, `h01`, `h02`, `h04`, `br_t02`, `loans/c13`, `docs/p12`, `p29`, CORE L535 (promote with 4.1a) | none | `reject/types/vec_index_resource.rig` | `?v[i]`/`!v[i]` conflict with `push`; `v[i] = x` drops the old value once; `x = v[i]` of an owner rejected ("an element cannot be moved out"); `<v[i]` of `T?` leaves `none`; RHS that reallocates `v` | CORE §4 elements row, §5 status | +30/−20 | yes | yes |
| 4.3 | Loops and `get` over owning elements | for-spec `src/ownership.zig:3703-3742` binds a view for arrays/slices of owners or Cell-holders; drop `src/typecheck.zig:6341` diag; unify `Vec.get` (6364), `sequenceGet`, Cell `vecGet` on `copyable` (OQ9) | row 11 (`c02`), row 13 per OQ9 | none | `reject/types/sequence_get_owning.rig` per OQ9 | `for x in ?a` of Cell-holders calls `!x`-free methods on the slot | SPEC §6 | +20/−30 | yes | no |
| 4.4 | One rule for assigning to a borrow place (Core §6) | sema `AssignMode {store, write_through, repoint}` + `facts.assign_modes` replacing `through_writes` (652, 1338-1345) and `assignWritesThrough` (2955); typecheck `checkSet` 720-735 (delete the re-point rejection; keep the `![]T`/parameter immutability as such), 760-764 (unwrap only in `write_through`), `checkPlaceAssign` 893-895; ownership `reassign` 2586-2621 (branch on the mode; `repoint` replaces the flow's loans) and `walkFieldAssign` 2656 (a re-pointed field replaces, not unions, its loans: `n39`); emit `emitBind` 1238 (`var` when re-pointed), `emitRebind` 1324 | `b01`, `b15`, `b17`, `b24`, `b25`, `b13` (writes through), `n41`, `n39`, CORE L589 (promote) | none: `b23` local `w = w2` already writes through and `b21` field `h.w = <w2` already re-points | `reject/ownership/repoint_local_write_borrow.rig`, `reject/ownership/assign_borrow_to_local_write_borrow.rig` (all 6 lines 58-63) | re-point to a shorter-lived place rejected (`n04`, `n36`–`n38` pass today); old loan released after re-point (local and field); a re-pointed `![]T` local | CORE §6 status; SPEC §4 assignment, §7 write borrows; SYNTAX §9; the `new w = …` hint text | +60/−40 | yes | yes |
| 4.5 | `new` takes every binding form | `rig.grammar:435` add `NEW target ":" type "=" value` and, after 5.3, `NEW CONST …`; schema `op` needs a tag for a fixed shadow (OQ3); `zig build parser`; Nexus re-sync | `b06`, `b06b`, `docs/p23` | none | none | `new x: T = e`, `new const x = e` | SYNTAX bindings | +6 | no | no |
| 4.6 | Std search takes a view | `std/sort.rig:108,122`, `std/slices.rig:15,19`: `x: T` → `x: ?T` (needs 3.2 so bare Copy args still work) | `slices.contains(?v, ?t)` over `Vec[Text]` | none if 3.2 has landed (callers pass Copy values bare) | none | search a `Vec[Text]` with a String | STD.md | ±0 | no | no |

Soundness risks: generic bodies instantiated with owning `T` (every copy of `xs[i]` must register `.plain`,
`src/resolve.zig:650-658`); an `at(i)` bit copy reaching a consuming position; element assignment whose RHS
reallocates; `Vec[!T]` uniqueness; `[n of x]`, `copy`, `fill` must stay `copyable`-only (Core §5 says so).

### Step 5: the remaining planned rules

| # | Commit | Files / functions | Rejections → acceptances | Accepted programs newly rejected (planned rule) | Flips / rewrites | New tests | Docs | Net LOC | Own | Cls |
|---|---|---|---|---|---|---|---|---|---|---|
| 5.1 | Fail only through `return` (decision 3) | typecheck: a `Checker` field naming the `return` operand (set in `checkReturn` 668-692 and the closure `return` sites near 7969); `compatible`'s `.fallible` arm (8206) accepts an error value only for that operand's branch leaves; diagnostic with the hint `return E.x` (CORE L336 requires the text `return Bad.oops`); **same commit:** `std/text.rig:144` → `return ParseError.invalid`; then delete the failing-tail-block machinery if dead: `src/ownership.zig:1289`, `1435` (`exitDefers(.failing_result)`), emit `markReturningBlocks` `src/emit.zig:1670` (verify `mayFail` 3961 has no other trigger) | none | measured (`proto-d3-d6/final-diff.tsv`): behavior `effects/errdefer_in_failing_value_block.rig`, `ownership/defer_effects_at_continuing_exits.rig`, `ownership/temporaries_drop_order.rig`, `types/optional_fallback_from_context.rig`; 17 corpus probes (valid outcome: rejected); 0 SPEC/WELCOME examples; CORE L322 (promote) | rewrite each bare error tail `E.bad` → `return E.bad` (the 4 behavior tests, ~10 lines); reject tests whose asserted error changes: `reject/ownership/errdefer_effect_at_failing_tail_block.rig`, `errdefer_reads_moved_on_failure.rig`, `errdefer_reads_value_moved_before_block_fails.rig` (their subject, a failing tail block, no longer exists: rewrite with `return E.bad` and keep only if the ownership error survives, else delete) | each form from `emit.md` §3.1 rejected (f01, f02, f04, f07, f08, f16–f19, g04); `return e`, `return a if c else E.bad` accepted | SPEC §13 "Failing" (`SPEC.md:4652-4666`), STD parse_bool | +25/−20 | only if the dead-code deletion is included | no |
| 5.2 | A used write-call `Bool` is `(!s).m()` (decision 6) | `checkReceiverSigil` 6844-6849: short form only when the receiver sigil starts the expression statement; delete `startsNegationOperand` 1455-1475 and `negation_operand` (114, 1443-1445) | none | `behavior/types/receiver_sigil_bool_value.rig`; SPEC examples `SPEC.md` L841, L921; 5 corpus probes (`audit-fuzz-pf2-accepted-0bb6dd2b9b`, `docs-probes-nb`, `purity-principles-p18_notbang`, `review-sc3-n1`, `seams-surface-a01_bool_short`) | `x = !s.insert(k)` → `x = (!s).insert(k)` (≈8 lines); `reject/types/receiver_sigil_bool_result.rig` stays | binding, argument, `match` subject, `return`, ternary forms rejected; statement form accepted | CORE §8 status (no pending example exists: OQ11), SPEC `:818-827`, SYNTAX `:326-329` | +4/−45 | no | no |
| 5.3 | Spell a fixed binding `const` (decision 5) | grammar: `CONST target:name "=" value → (set op:fixed)` and typed form; remove `=!` binding productions (`rig.grammar:431,433,461-462`) and keep the `=!` token only for a hard error (OQ4); `src/rig.zig`: 305-307, 419, 435, 723-724 (ambiguity check goes), 1233-1235 (habit hints), 1586-1587 (module level), 1884 (`const` leaves the reserved list); messages naming `=!` in typecheck (9 lines), sema (5), resolve (2), ownership (2), emit (2); Nexus re-sync | `const x = e`, CORE L574 (promote) | every `x =! e` (planned rule): 168 statement lines in 111 files (§5) | `reject/syntax/fixed_assign_touching_operand.rig` (becomes "`=!` is gone"), `habit_const.rig` (delete or invert), `habit_let.rig` (hint text), `module_fixed_binding*.rig`, expectations in `lend_held_write_borrow_needs_mutable.rig:27`, `write_borrow_lent_bare_unwritable.rig:31`, `fixed_binding_reuses_visible_name.rig:11`, `ct_arg_param_arithmetic.rig:28`, `test/cli/ct_diagnostics.sh:113`, `test/cli/emit_shapes.sh:22`; IR snapshot `test/ir/sigils.rig` (`--update ir`) | `const` as a compile-time argument; `const` rejected at module level; `x =! y` rejected with the rewrite | SPEC (6), SYNTAX (8), WELCOME (2), FAQ (1), DESIGN (2), INTERNALS (7), CORE §6/§8 status | +15/−25 (compiler) | no | no |
| 5.4 | A taken tail or `break` moves its name (sentence 1; closes C1's class) | ownership: one take point at the tail statement before the scope's exit (step 2's `exitTo` + `takeLeaf(sink)`), for every sink; delete the after-walk `consumeTailName` path (1597-1630) and the by-text lookup in `checkNoImplicitCopy` (2317); `walkJump` 3913 accepts a bare `break x` under OQ1's rule; emit: `Scan.consumeTail` (5617-5635) and `emitName`'s `tail` take (2971) read the recorded move | `t02` (if `b` is loop-local, OQ1); `n25`–`n27` and `reject/ownership/loop_value_owning_without_move.rig` only if OQ1 chooses "any name" | none | `loop_value_owning_without_move.rig` per OQ1 | the C1 shapes (rejected), block-local tails in every sink (accepted, drop counts checked), `break x` of a loop-local owner | CORE S1 status; SPEC "Moves" (`SPEC.md:2515-2518`) | +40/−50 | yes | yes |
| 5.5 | `+x` clones Vec, Box, owning structs (sentence 2) | typecheck `synthClone` 3515-3518 → step 1 `cloneable`; emit 3317-3336 → `rig.cloneValue(&x)`; runtime: a comptime recursive clone (plain copy, handle `cloneStrong`/`cloneWeak`, Text `clone` 974, Vec deep, Box, optional, struct field-wise, tagged union); generic `+x` registers a `cloneable` requirement per instance | `k07`, `k08`, `k09`, `n19`, `docs/p15`, CORE L185 (promote) | none | `reject/types/clone_drop_glue_struct.rig` (cases without a `drop` body), `reject/ownership/box_owns_uniquely.rig` (the `+b` case), `reject/types/clone_borrowed_resource.rig` (`+r` of `?Vec` reads through: decide by sentence 2); `reject/std/rng_no_clone.rig` stays (unique) | clone then mutate each independently, leak-free; a struct with a `drop` body, a `unique` type, a Cell-holder: not cloneable | CORE S2 status; SPEC clone section | +70/−10 | small | no |

The C1 hotfix (§1) precedes 5.4 and should land before step 1; it is `src/ownership.zig`-only.

### Step 6: whole-program views and loan origins

Prerequisites: step 1 (`may hold a loan`), step 2 (`handsOver` carries "lives for the whole program", Core §9),
3.1 (the lend rows are edges of `produces`).

| # | Commit | Files / functions | Rejections → acceptances | Meaning changes | Flips | New tests | Docs | Net LOC | Own | Cls |
|---|---|---|---|---|---|---|---|---|---|---|
| 6.1 | Name the whole-program fact | ownership: `isStatic(Value)` from empty loans, global roots (`isGlobal` 873), and a `Loan.static` root for extern results with no lent parameter; replace the implicit checks in `isLocalLoan` 3205 | none (refactor, IR-equivalent) | none | none | — | INTERNALS | +20/−10 | yes | yes |
| 6.2 | Summarize parameters that must live for the whole program | ownership: a store into shared storage (`walkCall` 2821-2856, `walkFieldAssign` Cell Vec 2673-2678, `walkLambda` owned capture 3242-3256) whose only loans are `ext` loans on parameters records `static_params` instead of an error; each direct call checks those arguments with `isStatic`; summaries iterate to a fixpoint per module and are stored in `SemContext` for importers; a function with a non-empty summary cannot be referenced as a value; generic instances: `checkViews` (578-590) per type → per call | `t06`, `t07`, `t09`, `n09` | none (the error moves from the store to the call for non-static arguments) | `reject/ownership/text_string_param_in_cell.rig`, `string_borrow_in_cell.rig`, `string_view_untracked.rig`, `cell_vec_element_view.rig`, `text_view_escaping_closure.rig`, `reject/types/generic_inference_checks.rig` (its `T = String` store case), `reject/modules/foreign_chain_requirement/main.rig` (`generic_body_arith_string.rig` and `generic_optional_literal.rig` reject for other reasons and stay): each keeps its rejection only where the argument views a local Text, at the call, with a note at the store | `Holder[String]` with literals (t06), `h.put(?t[..])` rejected at the call, propagation through a wrapper, cross-module | CORE S9 wording (per value), SPEC Cell/closures | +300–500 | yes | yes |
| 6.3 | Narrow a result's loans to arguments that can produce it (S7, planned) | sema `produces(P, R)` memoized over the `holds()` walker plus lend rows (Text→String, `[N]T`/Vec→`[]T`, handles, callable results, type variables reach anything; unknown → produces); ownership `walkCall` result union (~2858) skips arguments that cannot produce the result's view target; defense check in `checkEscape` 3392 | `r01`–`r04` | none | none | over-borrow cases accepted; every under-borrow attempt (field, payload, handle, closure, generic) rejected; fuzzer generator | CORE S7 status (add an ordinary example: OQ11), SPEC | +100–150 | yes | no |

---

## 4. Dependencies

| Part | Needs step 1 facts | Needs step 2 | Could land first? |
|---|---|---|---|
| C1 hotfix | no | no | **yes, now** |
| 5.1 decision 3 (errors via `return`) | no | no | **yes** (typecheck `compatible`, std/text.rig) |
| 5.2 decision 6 (Bool long form) | no | no | **yes** (typecheck receiver sigil) |
| 5.3 decision 5 (`const`) | no | no | **yes** (grammar, rig.zig, mechanical rewrite) |
| 4.5 `new x: T = e` | no | no | yes (grammar); `new const` after 5.3 |
| 3.1a `lendsAs` refactor | lend representation (emit of `?T` copy vs pointer) | no | technically yes; sequence after step 2 (one-branch rule: it touches classification) |
| 3.1b new rows | lend representation | no | after 3.1a |
| 3.2, 3.3 implicit reads | copyable, lend representation | `handsOver` (place / view vs made; literals are not places) | no |
| 3.4 members | no | no | after 3.1a |
| 4.1a admission | copyable, needs cleanup, unique (`Rng`) | no | no (step 1) |
| 4.1b views in Vec | may hold a loan | no | no |
| 4.2 element places | copyable | `handsOver` (`.part_of_made`) | no |
| 4.3 loops/get | copyable | no | no |
| 4.4 borrow places | — | `handsOver` (view vs value RHS → `assignMode`) | no |
| 4.6 std search | — | — | after 3.2 |
| 5.4 tail/break moves | — | `handsOver.takeLeaf`, `exitTo` | no (the hotfix covers C1 meanwhile) |
| 5.5 `+x` | cloneable, unique | no | no |
| 6.1 | may hold a loan | `handsOver` static flag | no |
| 6.2 | may hold a loan | 6.1 | no |
| 6.3 | — | — | after 3.1b (edges) |

Suggested order after steps 1–2: 3.1a, 3.1b, 3.4, 3.2, 3.3, 4.1a, 4.2, 4.1b, 4.3, 4.4, 4.6, 5.4, 5.5, 6.1, 6.3,
6.2. Commits marked Own=yes or Cls=yes are serialized on one branch.

---

## 5. Mechanical rewrite: `=!` → `const`

Counts at 2d9e490f (`git grep`):

| Kind | Files | Lines |
|---|---|---|
| statement `name =! e` / `name: T =! e` (and one `errdefer x =! 1`) | behavior 14, reject 17, ir 1, corpus 79 (111 files) | 168: behavior 18, reject 17, ir 1, corpus 132 (24 typed) |
| module-level `pub X =! e` (already rejected) | corpus 7, reject 1 | 8 (leave: they test the rejection) |
| `x =!y` (token test) | 1 | 1 (rewrite by hand) |
| comments in `.rig` | | 24 |
| docs: SPEC 6 (1 code), SYNTAX 8 (2 code), WELCOME 2 (1 code), FAQ 1, CORE 1, DESIGN 2, INTERNALS 7 | | 27 |
| test expectations / cli | 7 reject tests, 2 cli scripts | 9 |
| compiler | rig.grammar 8, rig.zig 11, typecheck 9, sema 5, resolve 2, ownership 2, emit 2 | 39 (by hand) |

Script outline (run after the grammar accepts `const`):

```sh
# 1. statement forms, code lines only (not comments), skipping module-level `pub`
git grep -lP '^\s*(errdefer\s+|defer\s+)?[A-Za-z_]\w*(\s*:\s*[^=#]+?)?\s*=!\s' -- '*.rig' |
  xargs perl -pi -e 's/^(\s*)((?:errdefer\s+|defer\s+)?)([A-Za-z_]\w*)(\s*:\s*[^=#]+?)?\s*=!\s+/$1$2const $3$4 = /'
# 2. by hand: test/reject/syntax/{fixed_assign_touching_operand,habit_const,habit_let,module_fixed_binding*}.rig,
#    the 9 expectation lines, comments (`a \`=!\` binding` -> `a \`const\` binding`), Markdown prose
# 3. ./test/run --update ir   (test/ir/sigils.rig)
# 4. check: git grep -n '=!' -- '*.rig' '*.md' leaves only the module-level corpus files and the token test
```

Decision 3's rewrite (`E.x` tail → `return E.x`) and decision 6's (`!s.m()` used → `(!s).m()`) are small
(≈11 and ≈8 lines outside the corpus) and done by hand; the 22 corpus probes that start rejecting are left
as they are (a rejection is a valid corpus outcome).

---

## 6. Open questions for the design owner (with recommendations)

1. **OQ1 `break x` and a block's last value: which names move?** Core S1: "moves only where the value leaves
   for good: `return x`, `break x`, or `x` as the last value of a function or block". Today a block-local tail
   moves (n18), an outer name is rejected (n27, n25, n26), and `break b` of an outer `b` is rejected
   (`reject/ownership/loop_value_owning_without_move.rig`). *Recommend:* a bare name moves only where its own
   scope ends with that use (block-local tail, loop-local `break x`, any local or parameter in `return`); an
   outer name still needs `<x`. This keeps "a bare name never moves something still in scope", keeps that
   reject test, and is what emit already assumes for block-locals.
2. **OQ2 `?o` of `S?`.** `?S?` reads as `?(S?)` today, and `if ?o as x` gives `x: ?S` (`l06b`). *Recommend:*
   `?o` keeps type `?(S?)`; `(?S)?` (and `String?`, `([]T)?`) is a lend target that `lendsAs` reaches from it;
   document one spelling per type.
3. **OQ3 `const` grammar.** *Recommend:* `const x = e` and `const x: T = e` as statements; at module level
   `const` is rejected with "a module-level binding is already constant" (as `=!` is today,
   `src/rig.zig:1586-1587`); shadowing a fixed binding is `new const x = e`, which needs the `op` role to hold
   both "shadow" and "fixed" (a `shadow_fixed` tag; schema change, Nexus re-sync).
4. **OQ4 does `x =! e` stay as a migration?** *Recommend:* remove it from the grammar but keep `=!` as a lexer
   token that is always an error ("write `const x = e`"). Deleting the token lets `x =! y` re-lex as
   `x = !y`, a write lend: a silent meaning change for any old source.
5. **OQ5 `new x: T = e`.** *Recommend:* yes (4.5).
6. **OQ6 where an unwritten read lend is allowed.** S1 lists `?T` arguments, `for`, `if … as`, `match`. Does a
   binding or assignment whose expected type is a view also lend bare (`x: ?Bag = b`; `r = b` with `r: ?T`)?
   *Recommend:* reading positions only (arguments to view parameters, `for`, `as`, `match`, receivers);
   bindings and assignments are taking positions (§3) and keep `?b`. That also settles §6 for `?T` places: a
   bare `T` there is a type error with the hint `?b`.
7. **OQ7 a made value where a view argument is expected** (`size(mk())` with `?T`): *Recommend:* lend it as a
   statement temporary, exactly as `?mk()` is today; land after names (3.2b).
8. **OQ8 error values inside a `return` operand.** *Recommend:* allowed in the operand's branch leaves
   (`return a if c else E.bad`), nowhere deeper (not in a nested call's argument).
9. **OQ9 `v.get(i)` for a non-copyable element.** Core §5 lists `copy`, `fill`, `[n of x]` as copy-only but
   not `get`. *Recommend:* `get` is copy-only too (it returns the element by value), with a hint to
   `?v[i]`; or, if wanted, it returns the read view optional (`(?T)?`, `String?` for Text).
10. **OQ10 sorting `Vec[Text]`.** `sort.sort` needs `<`, and Text has none (`br_x04`). *Recommend:* Core §5's
    "sorting works for any element" means `sort_by`; adding `<` to Text is a new feature, out of the freeze.
11. **OQ11 planned rules without a `rig pending` example:** the Bool long form (Core §8) and sentence 7's
    narrowing. *Recommend:* add a `rig pending` block for each now, so the commits that build them promote it.
12. **OQ12 step 6's parameter summaries** are not a planned Core rule: they make sentence 9 per value
    across calls, and they move an error from the store to the call site. *Recommend:* treat as consolidation
    (only rejections become acceptances), but confirm, since callers then depend on callee bodies (the Core's
    "rules follow the value's type" principle, `docs/CORE.md:686`).
13. **OQ13 a bare held write view on an assignment's right side** (`w = w2` local writes through, `b23`;
    `self.w = to` field is rejected, `b13`). *Recommend:* both write through (S1: a bare name reads); `<w2`
    re-points.
14. **OQ14 `os.env`'s result** over-borrows its argument (`br_x01`). *Recommend:* out of scope unless the
    design owner adds `os.env` to sentence 7's whole-program list with a std-only marker.
15. **OQ15 S1's status text** is stale (§2.5); fix it in the C1 hotfix commit.
16. **OQ16 `*T` lends:** confirm the view's loan sits on the handle's binding (so `-h`, `h = …` conflict), and
    that `!h` lends `!*T` (the handle), never `!T`.
