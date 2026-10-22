# REVAMP-3 audit: HANDOFF step 1, "Type facts"

Auditor scope: one fact per question (copyable, unique, needs cleanup, may
hold a loan, cloneable, read-view representation), `struct T unique`,
Cell ⇒ unique (docs/CORE.md §1, pending example at docs/CORE.md:106), and
the C1 false rejections.

- Compiler: `/Users/shreeve/Data/Code/rig-revamp/bin/rig` (== main
  `2d9e490f`, byte-identical to `.git/revamp/r3/rig-base`). All line numbers
  below are against `2d9e490f`.
- Probes: `.git/revamp/r3/probes/kinds/` — the 56 kinds probes and 12
  branch probes copied from `core-audit/probes/kinds/`, containers probes
  `l03 l04 l05 c01 c02 c03`, and 19 new probes in `new/`. Old outputs are
  in `old/`. Runner: `probes/kinds/run.sh FILE...` (`RIG=`, sanitizer on).
- `probes/kinds/cellscan/`: `scan.py` (approximates Cell ⇒ unique with the
  current compiler by giving every non-generic struct that holds a Cell
  inline an empty `drop`, then diffs diagnostics), `bare.py` (heuristic
  scan for bare `Cell[T]` copies), `work/result.json`, `bare.txt`.
- `probes/kinds/sweep/`: `sweep.py` and `base.tsv` — `rig check` of every
  tracked entry point (6,386 files → 12,094 lines), used to count which
  existing tests hit each affected diagnostic.

---

## 0. Summary

1. Every finding of `core-audit/kinds.md` still holds on `2d9e490f`
   (55 of 56 kinds probes and all 12 branch probes give the same result);
   the one change is k23 (`-n` of plain data is now rejected, as Core §8
   says). The Text work added four borrow/view facts that are correct and
   need no change.
2. The facts live in `sema.zig`: `Contents` (1921), `Borrows` (1950),
   `Reach` (2087, propagated by `computeReach` 2133), `TypeInfo` (1962,
   `packed u18`), computed by `computeTypeInfo` (2208). `unique` fits as
   one more `Reach` bit (u5→u6) seeded by a `SymbolFlags` bit (7 spare)
   and by `Cell`, and one more `TypeInfo` bit (u18→u19).
3. Building step 1 naively has three traps that the existing tests do not
   catch: removing `Rng`'s empty `drop` makes accepted programs emit Zig
   that does not compile (n16b, n17: the emitter and typecheck 1254 use
   glue to mean "owned, writable binding"); ownership 2780's `isCopy` is a
   receiver-by-address question, not a copy question (n03); and the
   generic `.plain` requirement mixes "copies" with "discards/leaves a
   temporary" (sema 793–795).
4. Cell ⇒ unique newly rejects 7 tracked programs (1 behavior test, 6
   corpus probes) plus the Core pending example; no existing reject test
   asserts a C1 false rejection, so C1 flips no test. Making loop and match
   bindings of Cell-holders views (needed before the rule can be called
   built: n08 shows a stale read today) turns 9 currently rejected
   programs into accepted ones and rewrites one reject test.
5. Plan: 8 small commits (§5). Two are pure refactors with an empty
   IR-equivalence diff, one is grammar-only, one widens (views), one is
   the planned narrowing; the Rng commit must switch emit's `kindOf` to
   "moves" in the same change.

---

## 1. Probe re-run (current compiler, `RIG_SANITIZE=1`)

Status relative to `kinds.md`: **holds** = same result and the finding
stands; **changed** = different result.

| Probe | Today | Status |
|---|---|---|
| k01 plain struct bare bind | copies (`P(x: 1…) P(x: 9…)`) | holds |
| k02/k03/k50 owning, `*T`, `~T` bare bind | rejected, use `<` | holds |
| k04/k55 views | read view copies; write view moves | holds |
| k05/k06/k29/k31/k47/k49 `+x` on plain, handles, owned closures | works | holds |
| k07/k08/k09/k28 `+` on Vec, Box, struct of handles, `?Vec` | "cannot clone" | holds (step 5) |
| k10 Cell-holder bare bind | **forks**: `0 5` | holds (F3) |
| k11 `+` on Cell-holder | **forks**: `0 5` | holds (F3) |
| k12/c01 `Vec[Counter]` | rejected (admission) | holds |
| k13 set Cell in by-value param | rejected "needs a place" | holds (F11) |
| k14 `s = r` (Rng) | rejected, message says "two bindings would each run the destructor" (false) | holds |
| k15 `+r` | rejected | holds |
| k16/l04 `Vec[Rng]` | rejected | holds |
| k17/l03 `[2]Rng` | rejected "own resources" | holds (F8) |
| k18 `Cell(Rng)` | **works** | holds — a regression trap (F7) |
| k19 `<p` of plain-struct payload | rejected `match e reads e` | holds (C1) |
| k20 assign to payload copy | rejected | holds (correct) |
| k21 `<s.p` of plain field | rejected "partial moves" | holds (C1) |
| k22 `\|+p\| take(p)` plain | rejected "smuggle the handle" | holds (C1) |
| **k23** `-n`, `-p` on plain | **now rejected**: "`-n` drops nothing: `n` is plain data" (typecheck.zig:551) | **changed**: matches Core §8; kinds.md "accepted, only end the name" is stale |
| k24/k25/k27/k52 | as before | holds |
| k26 struct with `!T` bare bind | rejected | holds |
| k30 generic copy of `T = Vec` | rejected per instance | holds |
| k32 stack `Signal` | rejected | holds |
| k33/k56 owning enum / drop struct | rejected | holds |
| k34 `Cell[Counter]` | rejected (admission) | holds |
| k35 array of Cell-holders `b = a` | **forks**: `0 9` | holds (F3) |
| k36 bare `Cell[Int]` `b = a`, `+a` | **forks**: `1 5 7` | holds (F3) |
| k37/k38 | `1 11`, `1 1 11` | holds |
| k39 | rejected | holds |
| k41 field-wise clone | works | holds |
| k42 `\|+a\|` Cell-holder | rejected (isPlainData) | holds; inconsistent with k11 |
| k43 generic copy out of `?T` | type mismatch (readValue) | holds |
| k44 optional Cell-holder copy | rejected only at `set` | holds |
| k45 `k = h.c` field copy | **forks**: `0 4` | holds (F3) |
| k46 copy plain out of `?P` | rejected (only scalars copy out) | holds (C4, not step 1) |
| k48 stack closure | pinned | holds |
| k51 `Vec[V]` with `?T` | rejected | holds |
| k54 `<c` of plain-enum payload | rejected | holds (C1) |
| l05 struct holding Rng | rejected (glue) | holds |
| c02 `for x in ?a`, `x.hit()` (Cell-holders) | rejected: "`x` is a loop or match binding, a copy" | holds (F16) |
| c03 indexing works | `11 0` | holds |
| branch k40, t01–t11 | same as on text-core | holds (merged) |

New probes (`new/`):

| Probe | Result today | What it shows |
|---|---|---|
| n01 payload kinds | `1`, `5` | baseline: read/write/`?e` match payloads |
| n02 `c = w`, `w: !Color` | **rejected** "would duplicate a unique borrow" | C1-class false rejection: ownership 2341 `isCopy` ≠ typecheck `readValue` (8130) |
| n02b same with `!Int` | works | control |
| n03 `a.show(bump(!a))`, `?self` on plain struct | rejected (read hold on receiver) | ownership 2780 guards evaluation order; must not become `copyable` (F2) |
| n04b reassign module constants | "cannot reassign constant" first | globals are constants: the `isCopy` global sites 2575/2597 are low impact |
| n05 `Rng == Rng`; discard `Rng.seeded(3)` | both rejected via glue | after `unique`: `==` accepted unless kept out (F7); discard accepted (wrong rejection fixed) |
| n06b `if p as s` (Rng place) | rejected, use `<p` | unique place in `as` must stay rejected |
| n07 `match e .a(c) => c.hits.set(4)` | rejected "needs a place" | read-mode payload of Cell-holder is a copy (F16) |
| n08 `for k in a: a[0].hits.set(9); print(k…)` | prints `0 0` | **stale read: loop binding forks a Cell-holder** (F16) |
| n09 generic `keep(a)` stores Cell-holder | `0 3` | fork through generic T (F3) |
| n10 Cell.get of `Cell[Int]`, `+` on `*Cell` | `1 1 1 6` | unaffected controls |
| n11 `Cell[Rng].get()` | rejected (glue) | must stay rejected: copy-out needs copyable |
| n12 `k = make().c`; `j = h.c` | `2 1 5` | field copy forks (F3) |
| n13 by-value `Cell[Int]` param `set` | rejected | wrong once the param owns its Cell (F11) |
| n14 array of Cell-holders: `b = a`, `x = a[1]`, `a.get(0) as y` | rejected only at `set` | every array copy-out path must check copyable |
| n15 `if o as c` (Cell-holder place) | rejected only at `set` | becomes "use `<o`" |
| n16 `if <o as p: !p.bump()` (plain struct) | rejected (pattern bindings immutable) | control |
| n16b same for a struct holding `Rng`, and for `Rng` | **works** (`true 4`, `true`) | **trap**: typecheck 1254 grants writes only to glue bindings (F1) |
| n17 `g = <r; !g.next()`, `match <e .a(r) => !r.next()`, `Cell(Rng).replace` | **works**; emitted Zig saved as `n17_rng_param_write.emit.zig` | **trap**: emit binds owned payloads/`as` as `var` only when `kindOf != null` (F1) |
| n18 `hit(?(a if flag else b))` Cell-holders | rejected (temporary holds a Cell) | correct; keep the temporary branch |
| n19 `k = o ?? d` Cell-holders | `0 5 7` | fork through `??` (F3) |
| n20 `print((a if f else b).hits.get(), bump(?a))` | `0 1` | correct today; becomes rejected when holdBranchLeaf's Cell branch goes live (F6) |

---

## 2. Findings

Severity: **Critical** = unsound today; **High** = a step-1 implementation
trap that would break accept-means-correct or soundness; **Medium** = a
proxy whose replacement changes behavior and needs care; **Low** = stale
text or cosmetic.

| ID | file:line | Sev | Finding | Evidence | Proposed fix | Est. net LOC | Risk |
|---|---|---|---|---|---|---|---|
| F1 | src/emit.zig:5386-5394 (`kindOf`), 2726, 2829-2832, 2203, 2288, 765-772, 4622, 4716; src/typecheck.zig:1254 | **High** | "Owns, so the binding is its own writable value" is answered by drop glue. `Rng` only gets owned `var` storage and writable `as`/payload bindings because of its empty `drop`. Removing the `drop` (the HANDOFF's `struct Rng unique`) makes typecheck reject `if <p as r: !r.next()` (n16b) or, if 1254 is fixed alone, emit `const r = payload.r` / `\|r\|` captures that `!r.next()` cannot take `&mut` of — accepted programs whose Zig does not compile. | n16b, n17 (+ saved emitted Zig: lines 7-11, 29-31, 38-40 are the glue-driven owned paths) | `kindOf` keys on `moves` (= cleanup ∨ unique ∨ depends-on-T), as it already does for `maybeDropGlue`. `rig.drop` of a type without cleanup is a comptime no-op (`runtime.zig:113`). Typecheck 1254/1260/1264 use `moves`. Add n16b and n17 as behavior tests **before** removing the `drop`. | +6 / −4 | Medium (emit diffs in every Rng and Cell program; no runtime change) |
| F2 | src/ownership.zig:2780 | **High** | The receiver reservation uses `isCopy`, but its question is "is the receiver passed by address" (LEND), not "is it copyable". kinds.md C1 maps it to `copyable`; doing so drops the read hold for plain-struct receivers, so `a.show(bump(!a))` would be accepted while the emitted call passes `&a` and `show` reads `a` after `bump` — the checker/emit order class. | n03 (rejected today, correctly) | Keep the exact current set in step 1 (call it `sema.isScalar`, prims + String + errors); later, if desired, `!sema.lendByValue(ty)` after a probe on `![]T`/slice receivers, which `lendByValue` treats as copies. | ±0 | High if misrouted |
| F3 | src/ownership.zig:4236-4250 (`owningKind`), typecheck.zig:3567-3575 (`ownsResource`), 8093-8094, 8936 | High (planned rule) | A Cell-holder or bare `Cell[T]` copies silently and forks state: bare bind (k10, k36), `+` (k11), field read (k45, n12), array copy (k35), `??` (n19), generic T (n09), by-value argument (corpus p33/a02). Other sites reject it instead (k42 `\|+a\|`, k12, k34, k13). | k10, k11, k35, k36, k45, n09, n12, n19 | Core §1 (planned): `unique` bit seeded by Cell; `moves` includes it; `+` rejects it (Core sentence 2: a unique type has no `+`). | see §5 | Medium–High |
| F4 | src/sema.zig:793-795, 820; typecheck.zig:3567-3575, 8873, 8936 | Medium | `Requirement.plain` ("owns no resource: the body copies, discards, or leaves a temporary") is one requirement for two questions. The CLEAN callers (649 "discards a value", 3636/3643 "leaves a temporary", 3424 "moves out of a temporary a part", 915 "overwrites an element") and the COPY callers all record `.plain`, checked as `!glue`. Once `unique` exists, `.plain = copyable` would reject `T = Rng` for a body that only discards a `T`; `.plain = !glue` would admit `T = Counter` for a body that copies it (n09). | n09; read of 3567-3575 and call sites | Split into `.copyable` (COPY sites) and `.no_cleanup` (CLEAN sites); `satisfies`: `moves(ty) == .no` / `!cleanup(ty)`. Same split for ownership's `checkCopies` (594: `typeHasDropGlue` → `moves`). | +15 / −8 | Medium |
| F5 | src/ownership.zig:3630-3655 (`bindPayload`) | Medium | kinds.md C1 subtlety. With `isCopy → copyable`, a payload that is copyable but holds a read view (a `?N` field, a struct with `?T`) takes the first branch, which keeps both the scrutinee value's loans and the root's flow loans (`unionLoans(scrut_value.loans, flows[root].loans)`; `viewLoans` returns them unchanged for a type that is not view-only, 1808-1814). So the loans are kept; no `copyable && !borrows.any` restriction is needed. What does change: such a payload stops being an alias, so `<p` and `return p` of it are accepted (correct: a read view copies), and "cannot reassign match binding" no longer fires for it (typecheck already rejects assignment to a payload copy, k20). Write-mode payloads are `!T` (not copyable) and generic `T` payloads are "depends" (must stay alias). | n01; read of 3630-3655, 1808-1834 | Condition: `copyable(ty) == .yes`; keep `depends` on the alias path. Add k19, k54 and a `?N`-payload variant (`<p` then use after `!x` conflict) as tests. | ±0 | Low–Medium |
| F6 | src/ownership.zig:2939-2948 (`holdBranchLeaf`) | Medium | The Cell branch (`.write` hold when the place holds a Cell) is reachable only for a type with glue *and* a Cell, because `owningKind == null` returns first. With Cell ⇒ unique it becomes live for every Cell-holder: `print((a if f else b).hits.get(), bump(?a))` (n20, correct today, prints `0 1`) becomes rejected. Not a Core rule; it is the checker modelling emit order. | n20 | Either accept the new rejection (report to design owner) or keep the branch keyed on `cleanup` only. Decide before 1.6. | ±0 | Low |
| F7 | src/resolve.zig:2119 (Cell element), src/sema.zig:2887 (`.drop` not equatable), typecheck.zig:649 (discard) | Medium | Three acceptances of `Rng` hinge on glue: `Cell[Rng]` is admitted only because glue is one of the Cell element alternatives (k18, works today); `Rng ==` is refused only because it declares `drop` (n05); a discarded `Rng` is refused as leaking (n05). Removing the `drop` silently flips all three: k18 starts failing (regression), `==` and discard start working (acceptance changes). | k18, n05, n11 | Cell element rule `isCopyElement ∨ cleanup ∨ unique` (keeps k18; also admits `Cell[Counter]`, k34 — see Q3); `Cell.get` stays `moves`-gated (n11). `==`: decide (Q4); to preserve today, add a `.unique` reason next to `.drop` in `EquatableWalk.stepDecl`. Discard: accept (wrong rejection). | +6 | Low |
| F8 | src/resolve.zig:646, 663; typecheck.zig:4406, 4521, 4569, 6416, 6610 | Medium | Array/slice admission is keyed on glue ("own resources"). After the Rng change, `[2]Rng` is admitted (k17, l03). Arrays of Cell-holders are admitted today (c03, k35). Every array copy path must then check `moves`: whole-array copy (k35), `x = a[i]`, `a.get(i)`, `[n of x]`, `fill`/`copy` (n14). | k17, l03, k35, n14 | Keep admission on `cleanup` (its meaning: owns resources); switch the copy-out paths to `copyable` in the same commit as the facts that make them non-copyable. Add n14 + `[2]Rng` tests. | ±0 | Medium |
| F9 | src/ownership.zig:2341 vs typecheck.zig:8130 | Medium | Two "scalar read through a `!T`" rules: ownership `isCopy(pointee)` (prims, String, `any_error`) and typecheck `readValue` (prims, String, plain enums). `c = w` with `w: !Color` passes typecheck and is rejected by ownership. | n02 (rejected), n02b (works) | Move `readValue`'s predicate to sema (`readsAsValue`/`isScalar`) and call it at 2341. | +6 / −3 | Low |
| F10 | src/ownership.zig:2114, 2164, 2327, 3295, 3388, 3636-3639 (`isCopy`) | Low | C1 false rejections unchanged since `dd36c78`: `<p` of a plain payload (k19, k54), `<s.p` of a plain field (k21), `\|+p\| take(p)` (k22). The sweep found **no** tracked test or corpus probe that hits these with a plain type (all 30 hits in `sweep/base.tsv` involve glue), so C1 flips no existing test. | k19, k21, k22, k54; `sweep/base.tsv` | Replace `isCopy` with `copyable`. | −10 / +4 | Low |
| F11 | src/typecheck.zig:1282-1296 (`requireCellPlace`); emit.zig:766 (`mutable_copy`) | Low | A by-value parameter holding a Cell may change it through a `?self` method (corpus p33/a02: emit copies the param into a `var`, 766), but `c.hits.set(…)` on the same param is rejected (k13, n13). Both act on the callee's own copy today. Once a Cell-holder is unique the param owns its Cell (moved in), and Core sentence 9 says a Cell changes through any path. | k13, n13, corpus p32/p33 | Optional commit 1.7: allow `.param` roots in `requireCellPlace` for `moves` types; keep `.temporary`. | −3 | Low |
| F12 | docs | Low | `kinds.md` k23 row ("accepted, only end the name") is stale; SPEC.md:691-694 says "`Cell`s that hold only Copy values" are Copy, which contradicts Core §1 (planned); SPEC.md:3519-3523 states the by-value-param and loop/match "only a copy" rules that step 1 removes. | k23; SPEC | Update with the commits that change them (§5). | — | — |
| F13 | src/sema.zig:3192-3196, 3229; typecheck.zig:8127-8129 | Low | `holdsWriteBorrow`'s doc comment sits above `mayHoldView`; `holdsWriteBorrow` (3229) has none. `readValue`'s doc says "or an error" but the code admits no error type. | read | Fix the comments in 1.1. | ±0 | — |
| F14 | src/emit.zig:5381-5385 | Low | `kindOf`'s comment says it "only picks the call"; it also decides `var` vs `const`, owned prelude vs alias, and owned closure envs (2726, 2829, 4622, 4716, 4946, 765). | read | Reword when F1 lands. | ±0 | — |
| F15 | src/ownership.zig:4096-4126 (`runsDropBody`) | Low | Imported types answer "runs a user drop body" with glue (4101), so an imported struct holding only a Vec counts. Rng's change removes one false positive. | kinds.md | Out of step 1 (kinds C5). | — | — |
| F16 | src/emit.zig:2741-2752 (`payloadAliases`), 2349-2382, 2121-2160 (`emitFor`); typecheck.zig:1742-1790 (`elementTypeForLoop`), 2283-2289 (payload binding types) | High (planned rule) | A read-mode match payload and an array/slice loop element are emitted as **copies** (`\|payload\|` + `const x = payload.f`; `for (a) \|x\|`). For a Cell-holder the copy is observable: changes through it are lost (hence the four typecheck patches 3313-3321, 6338-6345, 8032-8035, `requireCellPlace` `.pattern`), and a change through the original is not seen (n08 prints `0 0`, should be `9 0`). The Core's "a Cell-holder is never copied" cannot be called built while these copy. | n07, n08, c02; corpus w001-w010 | Bind loop elements and read-mode payloads whose type holds a Cell as read views `?T`, the way `as` over a borrow already does (typecheck 1492) and the Vec resource loop does (1749 → `?elem`; emit `by_ptr` at 2139-2147 already handles a `borrow_read` element). Then delete the pattern branches of the four patches. | −30 / +35 | Medium–High |
| F17 | rig.grammar:290-291, 513-515; src/rig.zig:754-770 | Medium (process) | `unique` needs a schema slot. Adding `unique:tag(unique)?` to `struct`/`generic_struct` gives every struct node a new `_` slot, so `rig parse`/`normalize` output changes for every program declaring a struct (8 `test/ir/*.sexp` snapshots), while `--facts` changes only for structs that use it (absent roles are not printed). `rig.grammar` and `src/rig.zig` are mirrored in Nexus. | `rig parse` of k01: `(struct P (: x Int) (: y Int))` | Contextual keyword (like `of`, rig.zig:769); separate grammar commit; `./test/run --update ir`; notify the Nexus owner. | +20 grammar/lexer (+ regenerated parser) | Low |

No **Critical** finding: nothing on `2d9e490f` is memory-unsafe here.
The forks (F3, F16) are wrong-meaning acceptances of exactly the kind the
planned Core rule removes.

---

## 3. Refreshed site inventory (`2d9e490f`)

Questions (kinds.md legend): **COPY** may it be copied implicitly ·
**MOVES** is a bare use a move (owning, handle, unique, or depends on T) ·
**CLEAN** must it be released · **UDROP** runs a user `drop` ·
**BORROW/WBORROW/VIEW/TEXT** may hold a loan / a write loan / a String
view / reach a Text · **CLONE** what `+x` does · **CELL** holds a Cell
inline (representation) · **LEND** is `?T` a copy or a pointer ·
**SCALAR** a small value read through a borrow / closure ABI / comptime ·
**ELEM** container admission. **PROXY** = answers one question with a
predicate built for another. "→" = the fact it should read after step 1.

### 3.1 sema.zig — definitions

| Line | Helper / field | Computes | Used for | → |
|---|---|---|---|---|
| 1921-1941 | `Contents` (`glue` 1926, `cell` 1929, `plain` 1933, `held` 1935, `borrows` 1937) | per declared type | all | add `unique` |
| 1950-1957 | `Borrows` (`any`, `write`, `view`, `text`) | per type | BORROW/WBORROW/VIEW/TEXT | unchanged |
| 1962-1980 | `TypeInfo` packed u18: `has_type_var`, `holds_type_var`, `glue`, `cell`, `plain`, `borrows`, `poison`, `depth` | per interned type | all | add `unique` (u19) |
| 2005-2027 | `symbolContents` (drop ⇒ glue 2012; Vec/Box glue 2024; builtins not plain 2025) | glue, plain | | seed `plain = false` for declared unique |
| 2043-2083 | `holdsIn` (`.text` glue 2049, handles glue 2053) | glue/plain/type_var | | unchanged |
| 2087-2110 | `Reach` u5 (`cell`, `borrows`), masks `all`/`borrows_only`/`text_only` | inline reach | CELL, BORROW | add `unique` (u6), masked like `cell` |
| 2133-2165 | `computeReach` | propagation | | seed `unique` from the symbol flag |
| 2173-2204 | `reachOf` (Cell sets `.cell` 2189) | | | Cell sets `.unique` too |
| 2208-2235 | `computeTypeInfo` | | | copy `r.unique` |
| 2385 | `isHeapBuiltin` | structural mask | — | — |
| 2539 | `isAddress` | structural | — | — |
| 2634 | `typeHasDropGlue` | glue | CLEAN, used as COPY (**PROXY**) | `needsCleanup` |
| 2698 / 2709 | `isClosureValue` / `isClosureResult` | prim, plain enum, optional of one | SCALAR (owned-closure ABI) | unchanged |
| 2759 | `isPlainEnum` | | SCALAR, `==` | unchanged |
| 2805-2905 | `notEquatable` / `EquatableWalk` (`.drop` 2887) | | `==` | Q4 |
| 2922 | `isCopyPrimitive` | Bool, Int, Float, String, literals | SCALAR (as a "copy" test: **PROXY** at ownership 4206) | unchanged |
| 2955 | `assignWritesThrough` | structural | | |
| 3016 | `isBuiltinGeneric` | naming | — | — |
| 3155-3172 | `readBorrowCopies` / `copiedByBorrow` | glue ∨ maybe ∨ cell ⇒ pointer; else scalar/view | LEND | name `lendByValue`; behavior unchanged |
| 3176 | `holdsCellByValue` | `cell` | CELL; in typecheck patches copy forks (**PROXY**) | CELL only |
| 3182 | `holdsBorrow` | `borrows.any` | BORROW | unchanged |
| 3187 | `mayHoldBorrow` | any ∨ holds_type_var | BORROW (depends) | unchanged |
| 3192-3199 | `mayHoldView` (doc comment of `holdsWriteBorrow` misplaced above it, F13) | any ∨ view | BORROW incl. String | unchanged |
| 3202 | `reachesText` | `borrows.text` | TEXT (a loan is forwarded or kept) | unchanged |
| 3224 | `holdsViewOnly` | view ∧ ¬any ∧ ¬type_var ∧ ¬poison | VIEW | unchanged |
| 3229 | `holdsWriteBorrow` | `borrows.write` | WBORROW | unchanged |
| 3236 | `isCopyElement` | prim ∨ `isPlainData` | ELEM | unchanged (plain excludes unique) |
| 3246 | `isPlainData` | plain ∧ ¬glue | COPY ∧ ¬BORROW (**PROXY** where used as COPY) | `plain` = copyable ∧ ¬borrows.any |
| 3255 | `maybeDropGlue` | ¬glue ∧ holds_type_var | "depends" for CLEAN and COPY | the `depends` arm of `moves` |
| 3261 | `heldTypeVars` | | requirements | unchanged |
| 793-795, 820 | `Requirement.plain` | "owns no resource: copies, discards, or leaves a temporary" | COPY + CLEAN (**PROXY**, F4) | split `.copyable` / `.no_cleanup` |
| 386-410 | `SymbolFlags` (7 spare bits) | | | add `unique` |
| 1350 / 1354 | `recordCellTemp` / `lendsCellTemp` | per-expression | CELL temporaries | unchanged |

### 3.2 ownership.zig

| Line | Helper / site | Question | Today | → |
|---|---|---|---|---|
| 353-363 | `Owning` union | diagnostic label | also decides | label only; add `.unique` |
| 4203-4207 | `isCopy` def (prims + `any_error`) | narrower than every other rule (**PROXY**) | | delete |
| 2114 | `moveVar`: payload copied out | COPY | isCopy (**PROXY**, k19/k54) | `copyable` |
| 2164 | `movePath` | COPY | isCopy (**PROXY**, k21) | `copyable` |
| 2327 | captured value copied out | COPY | isCopy (**PROXY**, k22) | `copyable` |
| 2341 | `!T` read as its value | SCALAR | isCopy(pointee) (**PROXY**, n02) | `readsAsValue` (= typecheck `readValue`) |
| 2575, 2576, 2597 | reassign / globals | COPY | isCopy | `copyable` (globals are constants: n04b) |
| 2780 | receiver reservation | LEND (receiver by address) | isCopy (**PROXY**) | keep the exact set (`isScalar`), F2 |
| 3295 | `cap_clone` makes a resource capture | COPY | isCopy (**PROXY**, k22 root) | `copyable` |
| 3388 / 3389 | `returnMoves` | COPY / MOVES | isCopy / owningKind | `copyable` / `moves` |
| 3636, 3639 | `bindPayload` | COPY | isCopy (**PROXY**, root of k19/k54) | `copyable == .yes` (F5) |
| 4236-4250 | `owningKind` def (glue ∨ maybe) | MOVES + label | (**PROXY**) | `moves` + `kindLabel` |
| 1622 | walkName payload/generic | MOVES | owningKind | `moves` |
| 2077 | `ownsPlace` | MOVES | owningKind | `moves` |
| 2195 | `rejectBorrowedView` element of generic T | MOVES(depends) | owningKind == .generic | `moves == .depends` |
| 2337 | `checkNoImplicitCopy` name | MOVES | owningKind | `moves` |
| 2353 | member/index | MOVES | owningKind | `moves` |
| 2383 | `m?` | MOVES | owningKind | `moves` |
| 2911 | `holdArgRead` | read in place (= not copyable) | owningKind (**PROXY**) | `moves` |
| 2945-2946 | `holdBranchLeaf` (+ Cell ⇒ write) | MOVES + CELL | owningKind gates a mostly dead Cell branch (F6) | `moves`; decide F6 |
| 594 | `checkCopies` | COPY | `typeHasDropGlue` (**PROXY**: a Cell-holder T passes, n09) | `moves(arg) != .no` |
| 1170 | `holderLiveDepth` | CLEAN | glue ∨ maybe | `needsCleanup` (unique ⇒ NLL-short, correct: its emitted drop is a no-op) |
| 2534 | `envDrops` | CLEAN | glue ∨ maybe | unchanged |
| 4065, 4075 | `checkDropOrder` | UDROP / CLEAN | runsDropBody / glue | unchanged |
| 4096-4126 | `runsDropBody` / `fieldsRunDropBody` (imported → glue 4101) | UDROP | (**PROXY** for imported) | out of scope (C5) |
| 4225-4232, 3733, 3867 | `isResourceVec` → `resource_vec` → `loop_borrow` | elements walked by borrowed slot (= ¬copyable element) | glue (**PROXY**) | `moves(elem)` |
| 2976-2982 | `readsPlainValue` | COPY ∧ ¬BORROW | isPlainData (**PROXY**) | `plain` |
| 4253 + 23 sites (580, 1209, 1337, 1476, 1798, 2036, 2238, 2264, 2550, 2618, 2680, 2870, 2885, 2963, 2971, 2980, 3023, 3103, 3130, 3284, 3636, 3870, 4181) | `mayCarryBorrow` → `mayHoldView` | BORROW (+String) | correct | unchanged |
| 4272 + 6 sites (1633, 2240, 2343, 2356, 2383, 3648) | `carriesWriteBorrow` | WBORROW | correct | unchanged |
| 536, 565, 580, 4265 | `holdsBorrowType` / `holdsBorrow` | BORROW | correct | unchanged |
| 1484, 1811, 2889 | `holdsViewOnly` | VIEW | correct | unchanged |
| 1839-1846 | `mayOwnText` → `reachesText` ∨ `containsTypeVar` | TEXT | correct | unchanged |
| 1934, 4210 | `isText` | structural | | |

### 3.3 typecheck.zig

| Line | Op string / site | Question | Today | → |
|---|---|---|---|---|
| 3567-3575 | `ownsResource` def | COPY or CLEAN, records `.plain` | (**PROXY**, F4) | split: `requireCopyable` / `requireNoCleanup` |
| 649 | "discards a value" | CLEAN | ownsResource | `requireNoCleanup` |
| 915 | "overwrites an element" | CLEAN | ownsResource | `requireNoCleanup` |
| 1393 | "uses in a loop step a binding" | MOVES (keeps Rng's behavior) | ownsResource | `requireCopyable` |
| 1492 | `as` over a borrow binds `?inner` | ¬copyable | holdsCellByValue ∨ ownsResource | `requireCopyable` (one fact) |
| 3092 | "copies out with `??` a value" | COPY | ownsResource | `requireCopyable` |
| 3215 | "moves out of a borrow a value" | COPY | ownsResource | `requireCopyable` |
| 3424 | "moves out of a temporary a part" | CLEAN | ownsResource | `requireNoCleanup` |
| 3516 | `synthClone` "clones a value" (+ hand list 3505-3514) | CLONE (**PROXY**) | | `cloneable` |
| 3586 | `lendTemp` branching lend of a named value | COPY (lending it copies into a slot) | glue (**PROXY**) | `moves` |
| 3636, 3643 | "leaves a temporary" | CLEAN | ownsResource | `requireNoCleanup` |
| 4376, 4382 | Vec / Cell-Vec index copy | COPY | ownsResource | `requireCopyable` |
| 4406 | "slices a Vec" | ELEM | ownsResource | `requireNoCleanup` (unchanged meaning) |
| 4521 | "puts in an array a value" | ELEM | ownsResource | `requireNoCleanup` (F8) |
| 4569 | `[n of x]` | COPY | ownsResource | `requireCopyable` |
| 6354 | `Cell.get` | COPY | ownsResource | `requireCopyable` (n11) |
| 6364 | `Vec.get` | COPY | ownsResource | `requireCopyable` |
| 6416 | `fill`/`copy` | COPY | ownsResource | `requireCopyable` |
| 6580 | Cell-Vec `get` | COPY | ownsResource | `requireCopyable` |
| 6610 | `sequenceGet` | COPY | ownsResource + holdsWriteBorrow | `requireCopyable` |
| 8093-8094 | `\|+x\|` | COPY | isPlainData ∨ maybe+ownsResource (**PROXY**, k42 vs k11) | `copyable` (+ requirement) |
| 1254, 1260, 1264 | `as`/`match <` binding owns ⇒ writable; diagnostic wording | MOVES | glue (**PROXY**, F1) | `moves` |
| 1421 | joined step bindings | MOVES (conservative) | glue | `moves` |
| 1606 | loop over borrow of a temporary | CLEAN | glue | `needsCleanup` |
| 1749 | Vec elements borrowed | ¬copyable element | glue (**PROXY**) | `moves(elem)`; F16 extends to arrays/slices with `cell` |
| 1823 | made value matched ⇒ consumed | MOVES | ownsResource | `requireCopyable` |
| 1831 | branching match subject | MOVES | glue | `moves` |
| 2954 | `==` operand temporary | CLEAN | glue | `needsCleanup` |
| 551 | `-x` of plain data | ¬BORROW ∧ COPY | isPlainData ∧ ¬mayHoldView | `plain` |
| 2022 | `viewsMatched` | ¬plain ∨ view | isPlainData | `plain` |
| 8930-8936 | `satisfies(.plain)` | COPY+CLEAN | ¬glue | split |
| 3292, 7637-7638, 5849, 786, 7290, 3539, 8218 | `readValue` (8130: prim ∨ plain enum) | SCALAR | | sema `readsAsValue` |
| 8122 | `operandValue` | SCALAR + T | | unchanged |
| 7292 | `readBorrowCopies` | LEND | | `lendByValue` |
| 3313-3321 | borrow of a pattern copy / temporary holding a Cell | CELL patch | | delete pattern branch (1.5); keep temporary |
| 6336-6345 | `?self` call on pattern copy / temporary | CELL patch | | same |
| 8032-8035 | capture `?x` of pattern copy | CELL patch | | delete (1.5) |
| 1282-1296 | `requireCellPlace` (rejects `.param`, `.pattern`, `.temporary`) | place | | `.pattern` falls away with views; `.param` optional (F11) |
| 7899, 7941 | `isClosureValue`/`Result` | SCALAR (ABI) | | unchanged |
| 7755 | `isPlainEnum` (fromBackingInt) | SCALAR | | unchanged |
| 4573, 4895, 5704, 6421 | `holdsBorrow` | BORROW | | unchanged |
| 1779, 2245, 6610, 6941 | `holdsWriteBorrow` | WBORROW | | unchanged |
| 5161, 5173 | `mayHoldBorrow` | BORROW (depends) | | unchanged |

### 3.4 emit.zig

| Line | Site | Question | → |
|---|---|---|---|
| 5386-5394 | `kindOf` (glue ∨ maybe) | CLEAN + shape of the drop call, **and** owned/`var` (**PROXY**, F1) | `moves` |
| 765-766, 772, 817 | param `kind`, `mutable_copy` (cell, no kind) | MOVES / CELL | `kind` via `moves`; `mutable_copy` becomes dead for unique-by-Cell (delete in 1.6) |
| 1206 | `_ = x` discard | CLEAN | unchanged (no-op drop) |
| 1253, 1260 | local kind, `needs_ptr_self` (cell) | MOVES / CELL | `kindOf`; `cell` term stays (representation) |
| 1293, 5435 | `isPlainTy` | "needs a Zig annotation" (not a kind) | rename `needsAnnotation` (cosmetic) |
| 1336, 1401 | write-through replace / may own | CLEAN | unchanged |
| 2133 | Vec consumed by `for` | MOVES | unchanged via `kindOf` |
| 2203 | loop element resource | MOVES | via `kindOf` |
| 2288 | match consume mode | MOVES | via `kindOf` |
| 2726 | `payloadLocal` kind | MOVES (owned payload is `var`) | via `kindOf` |
| 2741-2752 | `payloadAliases` read mode by value | CELL representation (F16) | addr for `cell` fields |
| 2829-2832, 2869 | `as` owned binding | MOVES | via `kindOf` |
| 3125-3131 | `isPtrBorrowTy` / `readBorrowIsPtr` | LEND | `lendByValue` |
| 3141-3148 | `genericReadBorrow` (maybe ∧ ¬cell) | LEND (generic) | unchanged |
| 3317-3335 | `.clone` (cloneOptional, Text `.clone()`, cloneStrong/Weak, unsupported for glue value) | CLONE | read `cloneable` (no change in output) |
| 3507, 3518, 4580, 4909 | `== none` / enum-literal temp drop; `isOwnedValue`; place owns | CLEAN | unchanged |
| 4622, 4716 | hoisted receiver/arg `var` (kind or cell) | MOVES + CELL | via `kindOf` |
| 4946, 4968, 5027 | closure env owning; `cap_clone` kind | MOVES / CLONE | via `kindOf` |
| 5533 | `containsTypeVar` | structural | — |
| 5509 | `isPlainEnum` | SCALAR | — |

### 3.5 resolve.zig

| Line | Site | Question | → |
|---|---|---|---|
| 646, 663 | array / slice element "own resources" | ELEM | `needsCleanup` (F8) |
| 906, 2377-2382 | `isCtValueType` | SCALAR | unchanged |
| 1467, 1513 | `is_drop_method` | UDROP source | unchanged |
| 2119 | Cell element: `isCopyElement ∨ glue` | ELEM (**PROXY**: Rng admitted via fake drop) | `isCopyElement ∨ cleanup ∨ unique` (F7, Q3) |
| 2123-2129 | Vec element: copy element, handle, Box | ELEM | unchanged |
| 2133 | Box: ¬holdsBorrow | BORROW | unchanged |
| 2137 | Signal: `isCopyElement` | ELEM | unchanged |
| 2150, 2154 | owned closure type params/result | SCALAR | unchanged |
| 378 | declare nominal type | | set `SymbolFlags.unique` from the struct's `unique` role |

### 3.6 runtime.zig (comptime mirrors)

| Line | Mirror | Fact | Step-1 impact |
|---|---|---|---|
| 40-59 | `needsDrop` | CLEAN | none (unique adds no runtime meaning; `rig.drop` is a no-op without it, 113) |
| 64-80 | `holdsCell` | CELL | none |
| 88-99 | `ReadBorrow` / `copiedBorrow` | LEND | none |
| 113-133 | `dropElement` gated by `needsDrop` | CLEAN | makes F1's "emit unique as owned" safe |
| 437 | `cloneOptional` | CLONE | none |
| 220 | `isText` | structural | none |

**Count.** About 140 call sites of about 30 helpers answer 11 questions;
about 45 are proxies (COPY by glue / `isCopy` / `isPlainData`, MOVES by
glue in emit, CLEAN+COPY in one requirement).

---

## 4. The facts after step 1

Kept where they live now: `sema.zig` `Contents` → `Reach` → `TypeInfo`.

| Fact | Where | Definition | Replaces |
|---|---|---|---|
| `cleanup` (keep the field name `glue` until the step-6 rename) | `TypeInfo.glue` | user `drop`, or holds `*T`, `~T`, Vec, Box, Text, owned closure | unchanged meaning; Rng loses it |
| `unique` | **new** `SymbolFlags.unique` → `Contents.unique` → `Reach.unique` → `TypeInfo.unique` | declared `unique`, or holds a `Cell` inline (bare `Cell[T]` too); propagates with the `cell` mask (not through handles, borrows, Vec/Box heap) | the empty `drop` in Rng; the copy-fork patches |
| `holds_type_var` | existing | depends on T | |
| `moves(ty) -> enum{no, yes, depends}` | **new fn** | `cleanup ∨ unique` → yes; else `holds_type_var` → depends; else no | `owningKind != null`, `ownsResource` (COPY), glue-as-COPY, emit `kindOf` test |
| `copyable(ty)` | **new fn** | `moves == .no ∧ ¬borrows.write` (depends → depends) | `ownership.isCopy`, `checkCopies`, `.plain` requirement, `isResourceVec` |
| `plain(ty)` | `isPlainData` | `copyable ∧ ¬borrows.any` (Contents.plain is false for declared unique; Cell already sets it false) | as now |
| `borrows.{any,write,view,text}` | existing | | unchanged |
| `cell` | existing | representation only (emit storage, LEND, F16 views) | the copy patches stop using it |
| `cloneable(ty) -> enum{copy, bump, text, no}` | **new fn** | today's `synthClone` list exactly — copyable → copy; `*T`, `~T`, optional of one → bump; Text → text; else no — with `unique` → no | `synthClone` switch; emit `.clone` dispatch. Step 5 extends it structurally |
| `lendByValue(ty)` | rename `readBorrowCopies` | unchanged | `readBorrowCopies`, `readBorrowIsPtr`, mirror `ReadBorrow` |
| `readsAsValue(ty)` (SCALAR through a borrow) | move typecheck `readValue`'s predicate to sema | prim ∨ plain enum | `readValue`, ownership 2341 |
| `kindLabel(ty)` | ownership | diagnostic text only | `Owning` |

**Can "cloneable" and "lend representation" land without behavior
change?** Yes. `cloneable` reproduces `synthClone`'s list (3505-3519) and
emit's dispatch (3317-3335) byte for byte; it only changes behavior when
`unique` enters it (1.4/1.6, planned: Core sentence 2 says a unique type
has no `+`). `lendByValue` is a rename. Both give an empty IR diff in 1.1.

---

## 5. Commit plan

Each commit keeps the four gates green and is checked with
`.git/revamp/r3/irdump.py` (old vs new compiler) plus a diff of every
reject test's diagnostics. "Flips" lists tests whose expectation changes.

### 1.1 Add the type facts (no behavior change)
- **Files:** `src/sema.zig` only (+ unit tests in `sema.zig`'s test block).
- **Add:** `SymbolFlags.unique`, `Contents.unique`, `Reach.unique` (u6,
  in the `all` mask, out of `borrows_only`/`text_only`, so it propagates
  exactly like `cell`), `TypeInfo.unique` (u19), `computeTypeInfo`
  copies it. The bit is seeded only by `SymbolFlags.unique`, which
  nothing sets until 1.3; the Cell seed lands in 1.6. Functions `moves`,
  `copyable`, `cloneable`, `lendByValue` (= `readBorrowCopies`, kept as
  an alias until 1.8), `readsAsValue`. `moves` = `cleanup ∨ depends`
  until 1.4 adds `∨ unique`.
- **Fix comments:** F13.
- **IR diff:** none (parse/normalize/check/facts/emit identical).
- **Tests:** `zig build test`: `moves`/`copyable`/`cloneable` of `Int`,
  `P`, `?P`, `!P`, a struct with `?T`, `Vec[Int]`, `*P`, `T` (depends),
  imported types; the `unique` propagation cases (`[2]U`, `U?`, `Wrap[U]`
  unique; `*U`, `Vec[U]`, `Box[U]` not) are added in 1.3, once a struct
  can be declared unique.
- **Size:** +90 / −5. **Risk:** low.

### 1.2 One copy rule: switch consumers to the facts (C1)
- **Files:** `src/ownership.zig`, `src/typecheck.zig`, `src/sema.zig`
  (`Requirement`), `src/emit.zig` (`kindOf` reads `moves`; identical
  while `moves` excludes unique).
- **Delete:** `ownership.isCopy` (4203-4207), `owningKind`'s decision part
  (4236-4250 → `kindLabel`), `isResourceVec`'s glue test, `ownsResource`
  (3567-3575) → `requireCopyable` + `requireNoCleanup`;
  `Requirement.plain` → `.copyable` + `.no_cleanup` (sema 793-795, 820;
  typecheck 8873, 8885, 8936).
- **Switch:** every row of §3.2/§3.3 marked `copyable`, `moves`,
  `requireCopyable`, `requireNoCleanup`, `plain`, `readsAsValue`;
  ownership 594 (`checkCopies`) → `moves`. **Not** 2780 (F2): keep its
  exact set under a named `isScalar`.
- **Behavior change:** only wrong rejections become acceptances: k19,
  k21, k22, k54, n02. The sweep shows no tracked file depends on them.
- **IR diff:** none for tracked programs (expected: zero check/emit diffs;
  any diff is a bug in the switch).
- **New tests:** `test/behavior/ownership/` k19 (`<p` plain payload), k54,
  k21 (`<s.p` plain field), k22 (`|+p|` plain), n02 (`!Color` read); a
  `?N`-payload `<p` + later `!x` conflict (F5); reject: n03 stays
  rejected (guards F2).
- **Docs:** CORE.md §1 plain row stays "built" (now true); SPEC "Copy
  values" unchanged.
- **Size:** −70 / +45. **Risk:** low–medium (ownership; one branch at a
  time).

### 1.3 Grammar: `struct T unique`
- **rig.grammar:** lexer token `unique` (after `of`, line 166, with a
  comment: "after a struct header's name: the struct is unique");
  `@display` `UNIQUE: "`unique`"`; schema: split line 290 into
  `struct name:leaf unique:tag(unique)? ...members` and
  `enum, errors name:leaf ...members`; line 291 into
  `generic_struct name:leaf tparams:group unique:tag(unique)? ...members`
  and `generic_enum …`; rules 513-515 gain
  `STRUCT name:name UNIQUE INDENT members:members OUTDENT → (struct unique:unique)`
  and the generic form. `zig build parser`.
- **src/rig.zig:** `classifyWord` (754-770): `unique` is a keyword only
  when the line head is `struct` (or `pub struct`), at bracket depth 0,
  after the name or the closing `]`, and the next token ends the line;
  a name everywhere else (field `unique: Bool`, `p.unique`, `unique = 1`
  keep working). Lexer unit tests next to 1881-1889.
- **src/resolve.zig:378:** set `SymbolFlags.unique`; `symbolContents`
  seeds `Contents.unique` and `plain = false`; `computeReach` seeds
  `Reach.unique`. Still unread by `moves`.
- **Decisions:** allow on generic structs (structural, no drop involved);
  `unique` with a `drop` body is accepted (redundant). Not on enums (a
  payload holding a Cell is inferred).
- **IR diff:** `parse`/`normalize`: every `struct`/`generic_struct` node
  gains a `_` slot — all programs with structs differ, mechanically;
  `--facts`: unchanged (absent roles are not printed); check/emit: none.
  `./test/run --update ir` rewrites the 8 `test/ir/*.sexp` snapshots that
  contain a struct.
- **Tests:** `test/ir` snapshot with `struct R unique`; `test/reject/syntax`
  `struct R unique extra`; behavior: `unique` as a field and a local.
- **Nexus:** `rig.grammar` and `src/rig.zig` are mirrored — report the new
  token, the schema split, and the contextual rule to the Nexus owner.
- **Size:** +25 (grammar/lexer/resolve) + regenerated parser. **Risk:** low.

### 1.4 `unique` moves; `Rng` is `unique`
- **Files:** `src/sema.zig` (`moves` reads `unique`; only declared types
  have it until 1.6), `std/random.rig` (8-12: `pub struct Rng unique`, comment
  rewritten, `drop` removed), `src/ownership.zig` (`Owning.unique` label;
  message "bare use of `Rng` value `r` in binding would copy a unique
  value; use `<r` to move it" — lowercase `use `<r`` as the Core example
  expects), `src/typecheck.zig` (`synthClone`: unique → "`+x` cannot
  clone a `random.Rng`: it is unique; …", keeping the tested prefix),
  `src/resolve.zig:2119` (Cell element `∨ unique`, F7), `src/sema.zig:2887`
  (Q4), `src/emit.zig` (`kindOf` = `moves`, F1, already from 1.2).
- **Behavior:** Rng values no longer get a `__rig_drop` (emit loses the
  method; `rig.drop` calls stay as comptime no-ops); `[2]Rng` admitted
  (F8, wrong rejection removed), discard of an Rng accepted (n05),
  `Cell[Rng]` unchanged (k18), `Cell[Rng].get()` still rejected (n11),
  `Vec[Rng]` still rejected (admission is step 4).
- **IR diff:** parse/facts of `std/random.rig`; emit of every program
  using `Rng` (no `__rig_drop` on Rng, otherwise identical); check:
  message text in `test/reject/std/rng_not_copy.rig`, corpus
  `review-std-r5.rig`, `t1-rr.rig`.
- **Flips:** `test/reject/std/rng_not_copy.rig` (`# error:` text).
  `rng_no_clone.rig` keeps its prefix.
- **New tests (land first, in this commit's parent if possible):** n16b
  and n17 as `test/behavior/std/rng_owned_bindings.rig` (guards F1); k17
  `[2]Rng` with `b = a` rejected, `[n of r]` rejected, `a.get(0)` rejected;
  k18 + n11 (Cell[Rng] works, `get` rejected); l05 (struct holding Rng
  still moves).
- **Docs:** CORE.md §1 bullet 1 (Rng) *(planned)* → *(built)*; STD.md
  195-199 (Rng "moves"); SPEC "owning values" list (Rng is not owning:
  add a "unique" sentence).
- **Size:** −15 / +40. **Risk:** medium (emit; F1).

### 1.5 A Cell-holder is viewed, not copied, by loops and matches
(widening; lands before 1.6)
- **typecheck:** `elementTypeForLoop` (1742-1790): array and slice
  elements with `cell` are `?elem` in read/iter mode (as the Vec resource
  path at 1749-1762); `checkVariantPattern` (2283-2289): in read mode a
  payload field with `cell` binds `?f.ty`. This is the `as` rule at 1492
  applied to the other two binders.
- **emit:** nothing for loops (`emitFor` `by_ptr` already handles a
  `borrow_read` element over `&array`, 2139-2147); `payloadAliases`
  (2741-2752) sets `addr` for a `borrow_read` binding and the arm
  captures `|*payload|` (2381-2382) with `@constCast` as `?self` calls do.
- **Delete:** the `.pattern` branches of typecheck 3313-3317, 6338-6341,
  8032-8035 (keep the `.temporary` branches: n18, `made().hit()`), and the
  `.pattern` case of `requireCellPlace` becomes unreachable for cell
  types (bindings are `indirect`).
- **Flips:** `test/reject/ownership/cell_set_on_param.rig` (errors at
  36-37 `x`, 40 `k`, 43 `w` disappear; rewrite to keep the param and
  temporary errors); corpus becoming accepted (must run sanitizer-clean):
  `review-place-b8-w001, w002, w005, w006, w009, w010`,
  `review-place-b2-q036_cell_loop_set`, part of
  `purity-principles-p32_paramcell`; probe c02 and n07, n08 (`9`, `0`).
- **IR diff:** emit for loops over arrays of Cell-holders and read-mode
  matches with Cell payloads; check for the files above.
- **New tests:** n08 (behavior: `9`/`0`), c02 (behavior), n07 (behavior).
- **Docs:** SPEC.md:3519-3523 (loop or match binding "only a copy").
- **Size:** −30 / +35. **Risk:** medium–high (emit; Weak spot "owning
  values behind Cell").

### 1.6 A type holding a Cell is unique (the planned narrowing)
- **sema:** `reachOf` (2187-2192): a `Cell` sets `Reach.unique` next to
  `.cell`, so a bare `Cell[T]` and every inline holder are unique.
- **emit:** delete `mutable_copy` (90, 766, 772, 817-…) — a Cell-holder
  param now has `kind == .value` via `moves`; `needs_ptr_self`'s cell term
  (1260) and 4622's `cell` stay (representation).
- **Behavior (planned, Core §1):** implicit copies of a Cell-holder or a
  bare `Cell[T]` are rejected ("use `<c`"), `+` on one is rejected (Core
  sentence 2), generic `T = Counter` rejected where the body copies a `T`
  (n09). F6: holdBranchLeaf's Cell branch becomes live (n20 rejected) —
  decide first.
- **Flips (7 tracked programs + 1 doc example):**

  | File | Line | Copy | Rewrite |
  |---|---|---|---|
  | `test/behavior/runtime/cell_set_through_read_borrow.rig` | 37 `print(lent(k), k.hits.get())` | by-value arg | `print(lent(<k))`, read the count before; or `fun lent(c: ?Counter)` (the test's point is "a by-value parameter is the callee's own copy", which no longer exists: rewrite the comment and the expected output) |
  | `test/corpus/docs-p-copycell.rig` | 6 `d = c` (bare Cell), 11 `r = p` | bind | corpus probe: now rejected — still satisfies the corpus contract; leave as is |
  | `test/corpus/audit-docs-p-cc.rig` | 3 `d = c` | bind | same (rejected) |
  | `test/corpus/purity-principles-p22_cellcopy.rig` | 9 `b = a` | bind | rejected |
  | `test/corpus/purity-principles-p31_constcell.rig` | 19 `bump(k)` | arg | rejected |
  | `test/corpus/purity-principles-p33_parammethod.rig` | 17 `viaMethod(k)` | arg | rejected |
  | `test/corpus/seams-surface-a02_cell_copy.rig` | 14 `b = a`, 17 `via(a)` | bind, arg | rejected |
  | `docs/CORE.md:106` | `d = c` | bind | `rig pending` → `rig reject`, error `use `<c`` |

  Method: `cellscan/scan.py` (struct holders, 95 programs) found 6;
  `bare.py` found the 2 bare-Cell copies (the other 38 hits are `print`
  reads or `?Cell` parameters). Not covered by the scan: generic and enum
  holders (20 files, inspected by hand: constructions only, no copies).
  No test clones a Cell-holder with `+` and no test instantiates a
  copying generic with one.
- **IR diff:** check for the 7 files; emit for every program with a
  by-value Cell local or Cell-holder (~270 files): `var` + no-op
  `rig.drop` guards where `const` was emitted.
- **New tests:** reject k10, k11, k36 (`b = a`, `+a`), k45/n12 (`h.c`),
  k35 (array copy), n09 (generic), n19 (`??`), n15 (`if o as c` → `<o`),
  k44; behavior: `b = <a` then `b.hit()`; `*<c` then `+h` (a shared
  Cell-holder still clones as a handle).
- **Docs:** CORE.md §1 bullet 2 *(planned)* → *(built)*, CORE.md:161-163
  sentence 2 status; SPEC.md:691-694 (Copy no longer includes Cells);
  SPEC §10 Cell (3488-3523) "a Cell-holder moves"; WELCOME/FAQ if they
  show a Cell copy (none found by grep).
- **Size:** −40 / +10 (+ test rewrites). **Risk:** medium.

### 1.7 (optional) A by-value parameter owns its Cell
- `requireCellPlace` (1282-1296): `.param` roots are places for `moves`
  types (F11). Flips `test/reject/types/cell_vec_by_value.rig` (both
  errors), the param errors of `cell_set_on_param.rig` (16, 19),
  corpus `review-place-b2-q034_cell_param_set`, p32 (8, 16), k13, n13.
- **Size:** −5. **Risk:** low. Can wait for step 3.

### 1.8 Names and docs
- `readBorrowCopies` → `lendByValue` callers; `isPlainTy` →
  `needsAnnotation`; `kindOf`'s comment (F14); INTERNALS.md 573-583,
  1012-1014, 1098, 1129, 1148 ("drop glue" as the copy rule) and the facts
  table; runtime mirrors' comments name the facts they mirror.
- **Size:** ±0. **Risk:** none.

**Total (1.1-1.6):** about −170 / +245 lines of compiler, most of the
addition in 1.1's facts and tests.

**Order constraints:** 1.2 before anything reads `unique`; 1.4's n16b/n17
tests before the `drop` is removed; 1.5 before 1.6 (so 1.6 never has to
reject a loop or match binding for being a copy); only one of these
branches touches `src/ownership.zig` at a time.

---

## 6. Acceptance changes beyond the Core's planned rules (to the design owner)

| # | Change | Commit | Why | Recommendation |
|---|---|---|---|---|
| A1 | `Rng == Rng` becomes valid (today refused because Rng "declares `drop`") | 1.4 | `notEquatable` keys on the `drop` member (sema 2887) | Ask (Q4). Preserving = add a `.unique` reason. |
| A2 | `[N]Rng` arrays become valid (k17, l03) | 1.4 | array admission is "owns resources" (cleanup) | Accept: Core §5 (decided) says arrays hold any type; every copy path checks `copyable`. |
| A3 | Discarding an Rng temporary becomes valid (n05) | 1.4 | CLEAN | Accept (wrong rejection). |
| A4 | `Cell[Counter]`, `Cell[Cell[Int]]` become valid (k34) if the Cell element rule reads `unique` | 1.4/1.6 | keeping `Cell[Rng]` needs `∨ unique` | Ask (Q3); alternative keeps them rejected until step 4. |
| A5 | `print((a if f else b).hits.get(), bump(?a))` becomes rejected (n20) | 1.6 | holdBranchLeaf's Cell branch goes live (F6) | Ask; it is the checker modelling emit order, not a Core rule. |
| A6 | By-value Cell parameters can `set` (k13, n13) | 1.7 | Core sentence 9 | Optional; wrong rejection removed. |
| A7 | `while … as r : step(r)` with a unique `r` stays rejected (1393/1421 mapped to `moves`) | 1.2/1.4 | conservative | None (preserves today for Rng; Cell-holders newly rejected only where a bare place copy would already be). |

## 7. Soundness risks

1. **F1** — accept-means-correct: unique without cleanup must take the
   owned emit paths. Guarded by n16b/n17 behavior tests.
2. **F2** — moving 2780 to `copyable` reopens an evaluation-order hole
   (the "checker models a different program than emit" class).
3. **F8/n14** — every array copy-out path must check `copyable` in the
   same commit that admits unique arrays, or `[2]Rng` copies silently.
4. **F16** — the read-mode match payload pointer capture: the subject
   must be addressable and mutable storage (the emitter already puts
   Cell-holders in `var`, 1257-1260); `@constCast` on a `const` comptime
   array would be UB — test arrays built from literals (`a = [C(...)]`).
5. **F4** — a single `.plain` requirement would either reject harmless
   generic discards of `Rng` or admit generic copies of Cell-holders.
6. Weak spots touched: "owning values behind Cell … and generic
   instances" (1.5, 1.6) and "evaluation order" (F2, F6). Run the full
   corpus after 1.2, 1.5 and 1.6.

---

## 8. Open design questions

- **Q1. `unique` spelling and position.** `struct Rng unique` as a
  contextual keyword after the header (proposed), with the schema slot
  `unique:tag(unique)?` on `struct`/`generic_struct`. Allowed on generic
  structs? (proposed yes). On enums? (proposed no; inferred from a Cell
  payload).
- **Q2. Do loop/match bindings of every `moves` type become views, or
  only those holding a Cell?** Proposed for step 1: only `cell` types
  (the one case where a by-value binding is observably different from a
  view, the same rule `lendByValue` uses). The general "read in place"
  is Core sentence 1 (planned), step 3.
- **Q3. Cell element admission after Rng loses its `drop`.** Keep
  `Cell[Rng]` (works today) by admitting `unique` — which also admits
  `Cell[Counter]` and `Cell[Cell[Int]]` — or keep today's set exactly
  until step 4?
- **Q4. Is a `unique` type equatable?** Today Rng is not (because of the
  fake `drop`); Cell-holders are not (Cell has no `==`). `==` copies
  nothing, so nothing in the Core forbids it.
- **Q5. `+` on a Cell-holder.** The Core decides it: a unique type has no
  `+` (sentence 2), so `+a` is rejected in 1.6 (today it forks, k11).
  `+h` on a `*Counter` is a count bump and stays. No design answer
  needed; noted because kinds.md C2 suggested "clone = a new Cell", which
  the Core rules out.
- **Q6. F6/A5:** accept the new rejection of a branching `print` read of
  a Cell-holder followed by a lend of it, or keep holdBranchLeaf's Cell
  branch keyed on `cleanup`?
- **Q7. by-value Cell parameters (F11/A6):** in step 1 or step 3?
- **Q8. `-x` on a unique value without cleanup** (`-r` for an Rng) stays
  accepted and only ends the name (proposed: yes, as for any non-plain
  value; `plain` excludes unique).
