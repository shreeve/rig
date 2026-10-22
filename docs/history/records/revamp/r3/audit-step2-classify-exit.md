# REVAMP-3 audit: HANDOFF step 2, "One classifier and one exit"

Read-only audit of `main` at `2d9e490f` (the `revamp` worktree at the same
commit). Compiler: `/Users/shreeve/Data/Code/rig/.git/revamp/r3/rig-base`
(byte-identical to `rig-revamp/bin/rig`). Every `file:line` is in
`/Users/shreeve/Data/Code/rig-revamp/src/` at that commit.

Probes: `/Users/shreeve/Data/Code/rig/.git/revamp/r3/probes/step2/`.

- `run1.sh f.rig...`: check, then `RIG_SANITIZE=1 run`.
- `sweep.sh OUT f.rig...`: one TSV line per probe.
- `results-step2.tsv`: this audit's 31 probes.
- `sweep-core-audit.tsv`: the 315 earlier core-audit probes (reads, loans, emit) re-run on today's compiler.
- `instrument-exit.diff`, `instrument-exit-hits.tsv`: the exit instrumentation experiment (§3.3).

---

## 0. Summary

1. **Two live unsound classes on `main`, both W1/W3 (critical).** Each is
   "a branching value in a position no classifier covers; emit takes or
   drops its name leaves, and the checker sees a read":
   - **F1, the receiver of a consuming method:** `(a if c else b).total()`
     with `total(<self)`, `(mk() catch d).total()`, `(h.o?).total()`, and
     `(a if c else b).unbox()`. All four are accepted and hit a use of
     freed memory.
   - **F2, a `== none` or `== .variant` test:** `(a if c else b) != none`,
     `(a if c else b) != .dot`, `h.o? != .dot`, `(o ?? d) != .dot`, and
     `(mk(false) catch d) != .dot`. All five are accepted and hit a use of
     freed memory.
2. **None of the 315 earlier core-audit probes is unsound today.** U1–U4,
   s01/s03, the header-view escapes, and the Cell `print` order are all
   fixed. The only non-zero exits are the specified bounds panic and
   programs that fail on purpose.
3. **The classifier inventory today:**
   - 13 syntactic classifiers in typecheck, 9 in ownership, and 7 emit
     decisions;
   - 16 concrete disagreements (§2.2), two of them unsound (F1, F2);
   - the root of both: emit takes any tail name the checker did not
     record as `readsInPlace` (`emit.zig:2971`). The default is
     "take", not "read".
4. **The flow map today:**
   - `exitDefers` (`ownership.zig:4007`, with `Exit.goesOn`, 231–256)
     already unifies defers at all five exits;
   - what remains for `exitTo` is merging `leaveTo` + `capture` + the
     report, at about 30 sites.
   - An instrumented build ran over all 6,386 tracked `.rig` programs:
     - no live loan is ever filtered without a report;
     - every rewind's extra vars are `.hidden` (statement temporaries,
       or the match `hold` var).

   So `exitTo` changes no diagnostics. But loans.md's planned assertion
   `vars.len == p.vars` is false on 85 rewinds, all of valid programs: it
   must be "every var past the point is hidden".
5. **Step 2 can be a pure refactor.** It needs no change to what the Core
   allows. Fixing F1 and F2 makes some accepted programs rejected, or read
   in place, but those programs are unsound today. The classifier also
   exposes about 6 wrong rejections (§5), which the reviewer may flip or
   keep. Statement temporaries are touched by commits B3, B4 and E2–E4:
   **see the warning in §4.0.**

---

## 1. Findings table

Severity: critical = accepted and unsound; high = a design premise or gate
that is wrong; medium = wrong rejection or a classifier fact decided twice;
low = cosmetic, or unreachable today.

| ID | file:line | Sev | Finding | Evidence | Proposed fix | Est. net LOC | Risk |
|---|---|---|---|---|---|---|---|
| F1 | typecheck.zig:8265 (`classifyReceiverShape` calls `if`, `match`, `catch`, `propagate`, `propagate_none` an `.rvalue`); typecheck.zig:6896 (`.value` accepts `.rvalue`); typecheck.zig:6332–6334 (no take for `.value`); ownership.zig:2768, 2791 (a `.value` receiver is only `walk`ed, never `walkConsumed`); emit.zig:4544 (`consumedTemporary`: `!isPlace` → the callee owns it); emit.zig:2971 (the tail name is `rig.take`n) | **critical** | The receiver of a consuming method (`<self`, a built-in `unbox`) that is a branching value over a name or field. Emit moves the leaf (alive flag cleared, or a payload copied out of `h.o`). The checker never marks it moved, so a later use reads freed memory. | `r01_consume_ternary_recv`, `r02_consume_optprop_recv` (through `h: !H`), `r03_consume_catch_recv`, `r13_unbox_ternary`: all ACC with "use of freed memory". Siblings: `r05` (`??`, rejected because `??` is `lvalue_bare`), `r08` (`<a if c else <b`, clean), `r09`/`r10`/`r12` (`?self` receivers, clean). | Hotfix: in ownership.zig `walkCall`, walk a `.value` receiver with `walkConsumed(obj, .argument)`. `checkNoImplicitCopy` then rejects the bare leaves (`use <a`), and Core §5 already writes `<a if c else <b`. Step 2: the receiver is classified by `handsOver` (B5). | +3, plus 4 reject tests | low (only unsound programs become rejected) |
| F2 | typecheck.zig:2921–2928 (the contextual path for `none` or `.variant` returns before `readLeaf`, 2954); emit.zig:3505 and 3518 (`!isPlace` → `rig.isNone` / `rig.isVariantDiscard`, which drop the operand, runtime.zig:285, 444); ownership walks `==` as a read (ownership.zig:1534–1537, operators: children walked, no take) | **critical** | Comparing with `none` or a bare variant a branching value whose leaf is a name, or `o?` of a place: emit drops the name's value, and the checker sees a read. | `e01_variant_eq_ternary_owners`, `e02_none_eq_ternary_owners`, `e04_variant_eq_optprop`, `e06_variant_eq_nullish`, `e10_variant_eq_catch`: all ACC with "use of freed memory". Controls: `e05` (a name), `e07` (a call): clean. | Hotfix: in the contextual path, reject an owning operand with a named leaf (`namedLeaf`): "bind it first". Step 2 (B6): call `readLeaf(other)`, and emit drops only an operand whose fact is `.made`, never a `.branches` one. That makes the hotfix's rejections into reads (Core §3: "an `==` operand" reads). | hotfix +6; step 2 +10 | low (hotfix); medium (B6, which touches temporaries) |
| F3 | emit.zig:2971 (`tail and !readsInPlace` → `writeTake`) | high | The class root of F1 and F2. Emit **takes** a branch-tail name by default. Only typecheck's `recordReadInPlace` (typecheck.zig:3627) turns that off, so any context that forgets to classify becomes a silent move. | F1, F2 | Invert the default. Typecheck records a `Use` fact (read / take / lend) for every value position a branching value reaches. Emit takes a tail name only for `take`, and Debug panics when a branching value in value position has no `Use`. This is commit B9. | +40 | medium |
| F4 | ownership.zig:920–933 (`rewind`); loans.md §5 assertion | high | The planned debug assertion `vars.len == p.vars` is false on valid programs. Statement temporaries (`holdTemp`, 1371) and the match `hold` var (3552) are added without a scope, and they survive `rewind`. | Instrumented build over 6,386 programs: 85 unbalanced rewinds in `if`, `while`, `set`, `call`, `defer`, and labeled-`match` statements. Every extra var is `.hidden`, and none is ever missing (`instrument-exit-hits.tsv`). | Assert instead: every var at index `>= p.vars` is `.hidden`, and `vars.len >= p.vars` (E1). | +8 | low |
| F5 | main.zig:291–300 (`--facts` prints only syntax roles) | high (gate) | The IR-equivalence gate cannot see the facts step 2 changes: `temp_drops`, `in_place_reads`, `taken_subjects`, `takes`, `cell_temps`, `reads`. Only their indirect effect in `emit` shows. | main.zig:291–300; `irdump.py` | First commit (A0): a sema-fact dump that `irdump.py` adds to each program. | +60 | none |
| F6 | ownership.zig:942–971 (`capture`), 3943–3950 (`leaveTo`) | medium | W2 still holds: `capture` filters loans on vars `>=` the point without a report, except statement temporaries (955–961). Soundness relies on callers calling `leaveTo` first (3443, 3587, 3836, 3930). Today nothing is lost (§3.3), but by caller discipline, not structure. | instrumentation: every `FILTER` with `live=true` comes from a program `leaveTo` already rejected | `exitTo` (E2–E4) | +30 | medium (temporaries: 955–961 is the round-3 temporaries fix) |
| F7 | ownership.zig:766–770 (`releaseVarsFrom` drops temporaries on scope vars silently) | low | A silent drop that cannot happen today: `walkStmtValue` (1364) clears a statement's temps before any scope pops. | reasoning; no instrument hit | `std.debug.assert` that none remains (E4) | +2 | low |
| F8 | ownership.zig:629–641 (`errSpan` de-duplicates the message but still counts `errors_found`) | medium (plan risk) | Moving reports into `exitTo` may report one loan twice. The `errors_found == found` guards (ownership.zig:2770–2779, 2830; walkFor 3713, 3727) would then skip later checks, which changes *other* diagnostics in reject tests. | code | `exitTo` reports each holder once: merge `leaveTo`'s loop and `capture`'s temporary report into one reporter. | 0 | low |
| D1 | typecheck.zig:8395 `isPlaceExpr`, emit.zig:5849 `isPlace` vs typecheck.zig:3353 `isTemporary` vs ownership.zig:1743 `resolvePlace` | low | A literal leaf is a *place* to `isPlaceExpr`/`isPlace`, a *temporary* to `isTemporary`, *not a place* to `resolvePlace`, and *not named* to `namedLeaf` (3601). | static | `handsOver`: a literal is `.made` with `static` | — | — |
| D2 | the same four, on `?x` / `!x` | low | A place to typecheck and emit; not a place to `resolvePlace`; "nothing" (fresh) to `checkNoImplicitCopy` (2380 `else`). No unsound effect, because loans cover it. | static | `.lend` | — | — |
| D3 | typecheck.zig:8265 vs 8360 `isBranching` vs emit.zig:4544 | (F1) | Receivers: `??` and blocks are places (`lvalue_bare`), `match` is a value, `if`/`catch`/`e?` are made values. To `isBranching`, `??` branches and `match` does not. To emit, all of them are temporaries. | `r05` rejected while `r01` is accepted | `handsOver` | — | — |
| D4 | typecheck.zig:2921 vs 2950–2955 | (F2) | The two `==` paths in one function: the contextual path never classifies its operand, the other calls `readLeaf`. | F2 probes | B6 | — | — |
| D5 | typecheck.zig:1997–2003 `tempBase` vs ownership.zig:3536–3540, 3570–3577 (`header_temps`) | medium | "A binding outlives a header temporary" is decided twice. Typecheck catches `match mk().s`; ownership catches `match ?mk()`. The messages differ. | `m02` ("the arms' bindings would outlive the temporary"), `m01` ("a borrow of the temporary … outlives its statement") | One fact: `handsOver == .part_of_made` and `.lend` of a `.made`; one diagnostic | −10 | **temporaries** |
| D6 | typecheck.zig:8370–8392 `readLeaves` (catch: value and handler) vs ownership.zig:2920–2937 `holdBranchReads` (catch: handler only) vs ownership.zig:2045–2073 `movedTail` and 2307–2391 `checkNoImplicitCopy` (catch: value and the handler's tail) | low | Three recursion sets for `catch`. They agree today only because a `catch` value is always a fallible call, since no name can hold a `T!` (`x01_fallible_binding`). | `x01` | One `valueLeaves` | — | — |
| D7 | typecheck.zig:8360–8366 `isBranching` (`if` with an `else` only) vs ownership.zig:2362–2363 (`if` recursed whatever its `else`) | low | The two disagree on an `if` with no `else`. It is Void, so it never reaches either one. | static | `valueLeaves` | — | — |
| D8 | ownership.zig:4394 `isValueExpr` vs emit.zig:5897 `isValueStmt` | low | They disagree on a `block`, and on an `if` with no `else`. Neither difference is reachable from source today (a bare block is not a statement; typecheck rejects an `else`-less `if` tail). | static | one `sema.yieldsValue` | −8 | low |
| D9 | typecheck.zig:1594, 1605 (`for`: `!isPlaceExpr and !makesValue` → "bind first") vs emit.zig:2133 (`!isPlace` and owning → consuming loop) | medium (wrong rejection) | The two agree only because typecheck rejects the gap. `for x in (mk() if c else mk2())` and `for x in <a if c else <b` are rejected, although every leaf is made here. | static; SPEC.md:2196–2210 keeps its (correct) named-leaf example | `.made` (all-made branches) → consuming loop. **Optional flip** (§5). | 0 | medium |
| D10 | typecheck.zig:1822–1835 (`match`: `makesValue` → consume; `isBranching` + drop glue → "bind first") | medium (wrong rejection) | `match mk() if c else mk2()` and `match <a if c else <b` are rejected, although all their leaves are made. | static | the same as D9. **Optional flip.** | 0 | medium |
| D11 | typecheck.zig:3494–3497 (`synthClone` → `synthOperand` → `rejectResourceTemporary`, 3642) | medium (wrong rejection) | `+(a if c else b)` and `+mk()` of a Text are rejected as "a temporary that owns a resource", but `+e` only reads `e` (Core §3). | `c01_clone_ternary_text` | Read the operand through `readLeaf`. **Optional flip.** | +2 | low |
| D12 | typecheck.zig:3642–3645 used by `synthOperand` (3552) for write receivers and `!e` | low (wrong reason) | `!(a if c else b).push(2)` and `!(h.o?).push(5)` are rejected, correctly, but with "this `Vec[Int]` is a temporary that owns a resource". It is a name's value. | `r06`, `r11` | The message comes from `handsOver` (`.branches`: "lend each branch"). Lending `!(X?)` is step 3/5 (`lendsAs`), not step 2. | 0 | low |
| D13 | ownership.zig:1579–1606 (`setTail`/`takeTail`/`walkTailBranch`: `if` and `match` only) vs `checkNoImplicitCopy` (which also recurses `??`, `catch`, `e!`, `e?`) | low | The tail-consumer marker and the copy checker recurse different forms. A bare name in a `??`/`catch` operand that is returned is reported, not moved. That matches Core sentence 1 (only `return x` and a function's last value move), so this is not a bug. | static | `valueLeaves` with a `takes_tail` flag | — | — |
| D14 | typecheck.zig:820–829 `handsOverWriteBorrow` vs ownership.zig:1632–1640 `isWriteBorrowPlace` | none | They answer different contexts (assigning reads, an argument lends on). Listed so the plan does not merge them by mistake. | — | keep both, written over `handsOver` | — | — |

---

## 2. Inventory 1: classifiers of "what an expression hands over"

### 2.1 Where each one is, and what it says

**typecheck.zig**

| Classifier | Defined | Positive list | Call sites |
|---|---|---|---|
| `isPlaceExpr` | 8395–8401 | any leaf (literals too), `member`, `index`, `read`, `write` | 1490, 1505 (`checkOptionalBinding`); 1587, 1594, 1605, 1606, 1617 (`checkFor`); 1752 (`elementTypeForLoop`); 1881, 1883 (`checkMatch` "viewed"); 1999 (`tempBase`); 3274 (`synthBorrow`); 3583 (`lendTemp`); 3601 (`namedLeaf`); 3627, 3628 (`readLeaf`); 3643 (`rejectResourceTemporary`); 3666 (`synthMember`); 4321, 4334 (`synthIndex`); 4422 (`synthSlice`); 6332 (receiver); 7013 (`arrayAsSlice`); 7826 (`lendCallable`) |
| `makesValue` | 8351–8358 | `call`; `e!`/`e?` of one | 1594, 1605 (`for`), 1822, 1823 (`match`) |
| `isBranching` | 8360–8368 | `if` with an `else`, `??`, `catch`, `e!`, `e?` | 1831 (`match`), 3596 (`namedLeaf`) |
| `readLeaves` | 8370–8393 | recurses the `isBranching` forms; `catch` covers its value and its handler, with no `tailOf` | 3599, 3625 |
| `namedLeaf` | 3591–3604 | a leaf that is a non-literal identifier other than `none`, or an `isPlaceExpr` list | 3586 (`lendTemp`), 3625 (`readLeaf`) |
| `readLeaf` | 3620–3640 | `.made` leaves own a resource → `recordTempDrop`; place leaves → `recordReadInPlace` only when there are more than one leaf | `synthReadTemp` 3608, used at 1822, 3666, 4321, 4334, 4921; also 2954 (`==`), 6333 (`?self` receiver) |
| `lendTemp` | 3582–3589 | the base of a non-place is a temporary; a named branching leaf is an error | 1806, 3324, 4449, 4460, 7054 |
| `rejectResourceTemporary` | 3642–3645 | `!isPlaceExpr` and owning → error | 3559 (`synthOperand`), 6255, 6263, 6302, 6334 |
| `isTemporary` | 3353–3358 | `placeOf` base: a leaf with no symbol, or a list whose type is not a borrow | 3324 |
| `tempBase` | 1997–2003 | `isPlaceExpr` and `placeOf.base` is a recorded temporary | 1600, 1942 |
| `placeOf` / `Place.root` | 1080–1121 / 993–1013 | a path: `.temporary` / `.borrowed` / ... by the base's type | about 28 sites (`requireAccess`, Cell, slices) |
| `classifyReceiverShape` | 8259–8270 | `.rvalue` = `call`, `builtin`, `array`, `array_fill`, `clone`, `share`, `weak`, **`if`, `match`, `catch`, `propagate`, `propagate_none`**; `??`, `block`, `member`, a name → `lvalue_bare` | 6864 (`checkReceiverMode`) |
| `handsOverWriteBorrow` | 820–829 | `write` → yes; `member`/`index` → no; otherwise by type | 731 |
| path utilities `unborrowedNode` / `lentPlace` / `placeRoot` / `findMove` | 8151 / 8157 / 8164 / 8178 | they peel different sigils (`placeRoot` peels `<`; `lentPlace` does not) | 1801, 3709, 4391, 6314, 6316, 7060; 6348, 6584; 1984–1989 |

**ownership.zig**

| Classifier | Defined | Positive list | Call sites |
|---|---|---|---|
| `resolvePlace` | 1743–1767 | a tracked name, `member`, `index` (not `?x`, not `<x`) | 1752, 1875, 1940, 2012, 2030, 2076, 2226, 2658, 2768, 2906, 2941, 3525, 3724, 3727 |
| `checkNoImplicitCopy` | 2307–2391 | a name and `member`/`index` are places; recurses the tails of `if`, `match`, a block, `??` (both operands), `catch` (the value and the handler's tail), `e!`, and `e?` when owning; **anything else (`?x`, `<x`, a call, a lambda) is fresh** | 1468 (temporary), 1567 (`walkConsumed`), 3360, 3374 (return) |
| `movedTail` + `ownsPlace` | 2045–2078 | the same recursion; a leaf that `resolvePlace` resolves and that owns | 2013 (`walkMove`) |
| `holdArgRead` / `holdBranchReads` / `holdBranchLeaf` | 2903–2952 | `resolvePlace`; recurses an `if` with an `else`, `??`, the `catch` **handler only**, `e!`, `e?` | 2811, 2840 |
| `isWriteBorrowPlace` | 1632–1640 | a name, `member`, `index`, of a type that carries `!T` | 1573 |
| `setTail`/`takeTail`/`walkTailBranch`/`consumeTailName` + `tailOf` | 1579–1630, 4383–4392 | marks an `if`/`match` whose tail the sink consumes; a bare tail name moves only for `.ret` | 1469, 1574, 3375, 3416, 3516 |
| `isValueExpr` / `isValue` | 4394–4400 / 3686–3688 | a leaf; any list but `set`/`return`/`break`/`continue`/`while`/`for`/`drop`/`pass`/`defer`/`errdefer`/`labeled` | 1283, 3373 |
| `walkFor` "made source" | 3724 | `resolvePlace(source) == null` → the elements carry the source's loans | — |
| `walkMatch` subject | 3519–3535 | `lent` = `?`/`!`; `resolvePlace` of what is under them | — |
| `readsPlainValue`, `inVarStorage`, `throughReadSlice` | 2976, 1977, 1960 | type and path facts (step 1 and paths; not hands-over) | — |

**emit.zig**

| Decision | Where | Rule |
|---|---|---|
| `isPlace` | 5849–5852 | a copy of `isPlaceExpr` |
| statement discard | 1214–1219 | `isPlace` and not `index` → `_ = &place` |
| consuming `for` | 2133 | a Vec and (`<` or (`!isPlace` and owning)) |
| match subject | 2286–2290 (`takesSubject` fact), 2329, 2416 (`evalSubject`: `isPlace` and not `<` and no temporaries → `&place`) | — |
| `== none` / `== .variant` drop | 3505, 3518 | `!isPlace` and owning → `rig.isNone` / `rig.isVariantDiscard`, **which drop the operand** |
| receiver | 4520 (`hoistsArgs`), 4540–4550 (`consumedTemporary`), 4601–4620 (`hoistReceiver`) | `!isPlace` and not `<` → a temporary |
| tail take | 2971 | a tail name is `rig.take`n unless `readsInPlace` |
| `isValueStmt` / `yieldsValue` | 5897–5905 / 3477–3479 | a leaf; not `set`/`drop`/`pass`/the jumps/`defer`/`block`/`while`/`for`/`labeled`; an `if` only with an `else` |

**sema facts that already carry part of the answer:** `temp_drops`
(sema.zig:629–633, 1408–1416), `in_place_reads` (634–636, 1418–1426),
`taken_subjects` (637–639, 1428–1436), `takes` (651–653), `reads`
(602–604), `cell_temps` (657–659), `text_lends`, `array_views`,
`unboxed`, `views`. A new fact belongs in the same table
(`Facts`, sema.zig:592–663).

### 2.2 The disagreement matrix (node kind × classifier)

P = place, F = fresh or made, B = recurse (branches), – = not a place / does nothing.

| Node | `isPlaceExpr` / emit `isPlace` | `resolvePlace` | `makesValue` | `isBranching` / `readLeaves` | receiver shape | `checkNoImplicitCopy` | `holdBranchReads` | emit temporary? |
|---|---|---|---|---|---|---|---|---|
| name | P | P | – | leaf | P | P | P | no |
| literal / `none` | **P** | – | – | leaf (not named) | P | – | – | no |
| `a.f`, `a[i]` | P | P | – | leaf | P | P | P | no |
| `?x` / `!x` | P | **–** | – | leaf (named) | explicit | **F** | – | no |
| `<x` | – | – | – | leaf | explicit | F | – | excluded |
| call, builtin, `+x`, `*x`, `~x`, array | – | – | call only | leaf | F | F | – | yes |
| `e!` / `e?` | – | – | of a call | **B** | **F** | B | B | **yes** |
| `if` with an `else` | – | – | – | **B** | **F** | B | B | **yes** |
| `match` | – | – | – | leaf | **F** | B (arms) | – | yes |
| block | – | – | – | leaf | **P** | B | – | yes |
| `??` | – | – | – | **B** | **P** | B | B | **yes** |
| `catch` | – | – | – | **B** (value + handler) | **F** | B (value + handler) | B (handler) | **yes** |

The bold cells are where a branching value is "made here" to one
consumer and "may be a name's" to another. F1 and F2 are two of them.

---

## 3. Inventory 2: the flow map of ownership.zig

### 3.1 The primitives

| Primitive | Lines | What it does |
|---|---|---|
| `here` | 908–915 | the trail length, var count, a copy of the temporaries, and reachability |
| `rewind` | 920–931 | undoes the trail; restores temporaries and reachability. **Does not truncate vars**, so hidden vars added since the point survive (F4) |
| `stateAt` | 934–936 | — |
| `capture` | 942–971 | the changes since `p` to vars `< p.vars`, with loans filtered `< p.vars` (962) and temporaries filtered (967). A loan on a statement temporary whose holder is live after the statement is reported (955–961) |
| `apply` | 973–979 | — |
| `leave` | 982–986 | `capture` + `rewind` |
| `joinAt` | 990–994 | `leave` + `join`* + `apply` |
| `join` / `joinFlow` | 999–1019 | the status maximum and the union of loans |
| `leaveTo` | 3943–3950 | reports each holder `< depth` live at `at` that holds a loan `>= depth`, then `capture`. **Temporaries are not reported** |
| `escapeVarsFrom` / `checkValueEscapesScope` | 1449–1452 / 1442–1445 | a value's loans on closing vars: report, then filter |
| `releaseVarsFrom` (`popScope`) | 752–771 | report holders live at the scope's end (only when reachable), filter; **temporaries on scope vars are removed silently** (766–770) |
| `dropStmtTemps` | 1381–1410 | for each statement temporary: report holders live after the statement, then mark it dropped |
| `exitDefers` | 4007–4017 | runs defers for `scope_end`, `failing_result`, `jump`, `return`, and `propagate`; rewinds when `Exit.goesOn` (231–256: `propagate` and `failing_result`) |
| `runDefers` / `runDefersTo` / `checkDeferBody` | 4021–4038 / 4042–4052 / 3986–4003 | — |

### 3.2 Call sites (save, restore, join, exit), with their function

| Function | Lines and operations |
|---|---|
| `popScope` | 737 `exitDefers(.scope_end)`, 738 `checkDropOrder`, 744 `releaseVarsFrom` |
| `walkFun` | 1250 `here`, 1266 push, 1270 pop, 1271 `rewind` |
| `walkBody` | 1289 `exitDefers(.failing_result)` (goes on) |
| `walkStmtValue` | 1364 temporaries shrink, 1365 `dropStmtTemps` |
| `walkBlock` | 1426 push, 1435 `exitDefers(.failing_result)` (goes on), 1436 escape, 1437 pop |
| `walk` | 1479 temporaries shrink (`readsThrough` of plain data) |
| `walkIndicesHeld`, `keepViewTemps` | 1791 remove, 1820 shrink |
| `walkCall` | 2776, 2814, 2878 reservation remove/reinsert; 2818 (`print`/Text), 2886 (the result holds no borrow) shrink; 2843–2853 Cell argument loans cleared after the report |
| `walkSwapCall` | 3014, 3026 shrink |
| `walkLambda` | 3273 `here`, 3289 push, 3309 pop, 3312 `rewind` |
| `walkReturn` | 3350 `exitDefers(.return)`, then unreachable |
| `walkIf` | 3422 condition `walkStmt`; 3423 `here`; 3425, 3427 `leave`; 3428 `join` + `apply` |
| `walkIfBinding` | 3439 `here`; 3443 **`leaveTo`** (a failing part); 3446–3447 escape + pop; 3449, 3452 `leave`; 3450, 3453 `apply` |
| `walkConditionParts` | 3473 shrink, 3474 push, 3476 `dropStmtTemps` |
| `walkCatch` | 3482 `here`; 3484 push; 3490–3491 escape + pop; 3492 `leave`; 3493 `join(stateAt(base), s)` |
| `walkNullish` | 3501 `here`, 3503 `leave`, 3504 `join(stateAt(base), s)` |
| `walkMatch` | 3541 `dropStmtTemps` (header); 3545 shrink (a lent subject); 3552 hidden `hold` var (no scope); 3554 `here`; 3566 `apply(start)`; 3567 push; 3586 guard `walkStmt`; 3587 **`leaveTo`** (a failed guard); 3591, 3602 `hold` cleared; 3592–3593 escape + pop; 3595 `leave`; 3596, 3597, 3600 `join`; 3601 `apply` |
| `walkFor` | 3721 `headerTempLoan` report; 3739 `dropStmtTemps` |
| `walkLabeled` | 3756 `here`, 3760 `joinAt(breaks)` |
| `walkLoop` | 3765 `here`; 3786, 3797, 3801 `apply`; 3788, 3799 `rewind`; 3789 `join`; 3815 `joinAt(breaks)` |
| `loopIteration` | 3836 **`leaveTo`** (a failing `as` part); 3839 `capture` (the condition fails); 3841/3844 push/pop; 3846 `joinAt(conts)`; 3848 `capture` (back edge) |
| `walkJump` | 3928 `escapeVarsFrom`; 3929 `exitDefers(.jump)`; 3930 **`leaveTo`** |
| `walkPropagate` | 3955 `exitDefers(.propagate)` (goes on) |
| `checkDeferBody` | 3987 `here`; 3996 `leave` (where written); at an exit its effects are kept (`report_changes = false`) |
| `exitDefers` | 4008 `here` when it goes on; 4011–4014 run; 4016 `rewind` |

**Totals:**
- `here` 11, `leave` 9, `leaveTo` 4, `capture` directly 2 (+2 inside helpers), `joinAt` 3, `join` 9, `apply` 11, `rewind` 5 (+1 in `leave`), `exitDefers` 5;
- 7 push/pop pairs; 11 places that shrink or remove temporaries.

### 3.3 Every place a loan leaves the state without a report (S1–S14, today's lines)

| Site | Today | Status |
|---|---|---|
| S1 `capture` | 962, 967 | Silent, except statement temporaries (955–961). The instrumented run found 21 filters; each one with `live=true` was in a program `leaveTo` had already rejected, and those with `live=false` are dead holders. **Nothing is lost today**, but by caller discipline. |
| S2 `leaveTo` | 3943–3950 | Temporaries are not reported. 3 hits, all a `break` value's own statement loans (`loop_value_moves_out`, `temporary_views_in_statement`, `loop_value_borrows_loop_local`), whose value carries the real loans. Safe. |
| S3 `releaseVarsFrom` | 758–770 | Reports only when reachable; temporaries removed silently (F7). |
| S4 `escapeVarsFrom` | 1449–1452 | Reports first. |
| S5 the end of a statement | 1364 | By definition. |
| S6 `readsThrough` | 1479, 1819–1823 | A copy of plain data, or the view keeps its own loans. |
| S7 `walkCall` | 2818, 2886; `walkSwapCall` 3014, 3026 | The result keeps nothing. |
| S8 headers | 3473, 3541, 3545; the `hold` var cleared at 3591, 3602 | Bindings hold their own loans. The `hold` var keeps the subject's loans through the guards (bea65026, the second temporaries slip). |
| S9 `walkSwapCall` | 3000–3030 | Typecheck rejects borrow-holding values for `replace`/`swap`. |
| S10 a Cell argument | 2843–2853 | Reported, then cleared. |
| S11 type gates | `mayCarryBorrow` → `.{}` at 1798, 2037, 2884, 3874, … | They are copies. |
| S12 whole-body rewinds | 1271, 3312, 3996 | Intended. |
| S13 defers at an exit | `exitDefers` 4007–4017 | **Fixed** (PR #32, `Exit.goesOn`): rewinds where the path goes on. `u01`–`u04` and `f09`–`f11` are rejected today (`sweep-core-audit.tsv`). |
| S14 `reassign` | 2586–2620 | Re-pointing; intended. |

**Instrumentation (`instrument-exit.diff`, applied to a scratch copy, never
to tracked files).** It logs:
- every `rewind` whose var stack is not at the point;
- every non-temporary loan `capture` filters;
- every temporary `leaveTo` drops.

The run covered all 6,386 tracked `.rig` files (`find test examples std`),
with `rig check` only. Results:
- 85 unbalanced rewinds, **all of hidden vars**. With quiet loop rounds
  included, none had a non-hidden extra var and none was short.
- 21 capture filters, none of which loses a live loan that is not already
  reported.
- 3 temporaries dropped at `leaveTo`, all safe.

---

## 4. Implementation plan

### 4.0 Statement temporaries: READ THIS FIRST

Step 2 rewrites the code that decides **which nodes are statement
temporaries and which reads are in place**:
- `readLeaf`, `namedLeaf`, `lendTemp`, `tempBase`, `isTemporary`;
- the subject's temporary read in `checkMatch`;
- the temporary reads in `synthMember` and `synthIndex`.

In ownership it also rewrites the reporting that guards them:
- `capture` 955–961, the round-3 fix;
- the match `hold` var at the guard `leaveTo` (3587), the second slip
  (bea65026);
- `headerTempLoan` in `walkFor`.

**The two soundness slips since the redesign were in exactly these
lines.** A third slip stops the feature for redesign (AGENTS.md). Rules for
this step:

1. **Do not touch** `holdTemp`, `dropStmtTemps`, `stmt_drops`,
   `emitTempSlots`, `tempSlot`, `rig.keep`, or the `while` header handling.
   They consume the facts; step 2 changes only who computes them.
2. **The first commit adds a sema-fact dump (A0).** Every later commit must
   show identical `temp_drops`, `in_place_reads`, `taken_subjects`, `takes`
   and `cell_temps` for every program, except programs listed in the
   commit.
3. **Two subtleties of `readLeaf` must be preserved exactly:**
   - it records an in-place read only when a read has **more than one**
     leaf (3627; so `print(o?)` records none);
   - a branching value whose every leaf is made is **one** temporary at
     the branching node (3622–3624), not one per leaf.
4. **Run the corpus (all 4,273) and the extended matrix (B9)** after B3,
   B4, B6, and E2–E4. Do not run only the default sample.

### 4.1 The `handsOver` fact

**Where.** A pure function in sema.zig beside `Facts`:
`pub fn handsOver(ctx: *const SemContext, node: Sexp) Hands`. It reads only
recorded facts (`symbolOf`, `typeOf`, `instanceOf`, `takes`). It is
"decided once" because it is the only definition, and every pass calls it.
Whether to memoize it in `Facts` as `hands: AutoHashMap(u64, Hands)` is
open question Q1.

The `Use` fact of B9 (read / take / lend per value position) **is**
recorded, by typecheck, because it depends on context.

```zig
pub const Hands = struct {
    kind: Kind,
    /// Lives for the whole program: a literal, a module constant, a
    /// function. Recorded now for step 6; no consumer in step 2.
    static: bool = false,

    pub const Kind = enum {
        place,         // a name of a value binding, or a member/index path from a place, view, or lend
        part_of_made,  // a member/index path whose base is .made (mk().v[0])
        made,          // made here: call, builtin, constructor, +x, *x, ~x, <x, array,
                       // array_fill, lambda, an operator result, a literal, enum_lit,
                       // match, block, a value loop; and branches whose every leaf is made
        lend,          // ?x, !x, ?x[a..b], !x[a..b]
        view,          // place or made, of a view type (?T, !T, []T, ![]T, String): copies carry the loans
        branches,      // `if` with an else, ??, catch, e!, e?; at least one leaf not made
        jump,          // return, break, continue
        none,          // not a value: statements, declarations, types, patterns
    };
};
pub fn valueLeaves(node: Sexp, buf) []Sexp  // the operands a .branches value passes through, and
                                            // the tails a match/block/if value takes (tailOf)
pub fn yieldsValue(source, node) bool       // replaces isValueExpr + isValueStmt + hasValueBreaks pairs
```

**The positive list.** It is an exhaustive `switch` on `Tag` with **no
`else` arm**: a new IR kind is a compile error until someone classifies
it. That is AGENTS.md's "positive list". The order of the tests:
1. `jump`;
2. `branches` (collapsed to `made` when every leaf is made);
3. `lend`;
4. `view`, if the type is a view (step 1's type fact);
5. `place` / `part_of_made` / `made`.

**How compound forms recurse.** Only `valueLeaves` recurses. The operands
are:
- `if`: `tailOf(then)`, `tailOf(else)`;
- `??`: left, right;
- `catch`: value, `tailOf(handler)`;
- `e!`, `e?`: value;
- `match`: each arm's `tailOf(body)`;
- `block`: `tailOf`.

Consumers never switch on node kinds.

The receiver-shape special cases stay outside `handsOver`. They are
syntax, not ownership: `isReceiverSigil` and "`!v.push` applies `!` to
`v`" (Core §8).

### 4.2 The commits

Order: A0, then B1–B9, then E1–E5. Each is green on all four gates and on
IR equivalence. "Owner" marks the commits that change **typecheck's
classification** or **ownership.zig**. All of step 2 is therefore one
branch, and no other branch may touch those files while it is open. Step
1 (type facts) must merge first, because `view` and `takeLeaf` use its
`copyable` / `needs cleanup` facts.

**Hotfix H (recommended before step 1, on its own branch; Owner).** It
fixes F1 and F2 as rejections:
- ownership.zig `walkCall`: walk a `.value` receiver with
  `walkConsumed(obj, .argument)`;
- typecheck.zig at 2921: an owning contextual-compare operand for which
  `namedLeaf` returns a leaf is rejected with "bind it first".

New reject tests, one per sibling:
- the receiver: ternary, `catch`, `o?` through `!H`, `Box.unbox`;
- the compare: ternary with `none`, ternary with a variant, `o?`, `??`,
  `catch`.

Size about +10 LOC, +9 tests. Expected: no IR or emit change for any
existing program (none uses these forms; check with the dump).

| # | Commit | Files / functions | Expected dump differences | Tests that flip | New tests | Net LOC |
|---|---|---|---|---|---|---|
| A0 | Dump sema's expression facts for the equivalence gate | main.zig (`--facts=sema`, or `RIG_FACTS=sema`), sema.zig (`writeSemaFacts`: every `Facts` set keyed by span); `irdump.py` adds the dump | new section only | none | none | +60 |
| B1 | Add `handsOver`, `valueLeaves`, `yieldsValue` to sema | sema.zig; unit tests in `zig build test` with a table of one row per `Tag` group | none (no consumers) | none | unit tests: every node kind, and every compound recursion | +170 |
| B2 | Decide value statements once (`yieldsValue`) | ownership.zig `isValue`/`isValueExpr` (3686, 4394) and emit.zig `yieldsValue`/`isValueStmt` (3477, 5897) call `sema.yieldsValue` | none (D8 is unreachable) | none | a unit test of the rows they disagreed on | −15 |
| B3 (**Owner, temporaries**) | Read leaves through `handsOver` | typecheck.zig: `readLeaf` (3620), `namedLeaf` (3591), `readLeaves`/`isBranching` (8360–8393) deleted; `synthReadTemp` unchanged | **identical sema facts and emit**; keep the `> 1 leaf` rule and the one-temporary rule exactly | none | behavior: `print(o?)`, `print(a if c else mk())`, `print(mk() if c else none)` with drop order (they pin the two `readLeaf` subtleties) | −25 |
| B4 (**Owner, temporaries**) | Classify places and made values once in typecheck | typecheck.zig: every `isPlaceExpr` site (table in §2.1), `makesValue` (1594, 1605, 1822, 1823), `isTemporary` (3324), `tempBase` (1999), `lendTemp` (3583), `rejectResourceTemporary` (3643); delete `isPlaceExpr`, `makesValue`, `isTemporary` | identical, **unless** the reviewer takes the optional flips D9/D10/D11 (§5); each flip lists its programs | with flips: none existing (no test asserts them; SPEC.md:2200's example stays rejected) | with flips: behavior tests for `for x in (mk() if c else mk2())`, `match <a if c else <b`, `+(a if c else b)` | −30 |
| B5 (**Owner**) | Classify receivers by what they hand over | typecheck.zig `classifyReceiverShape` (8259) → `handsOver`: `.made` → rvalue; `.branches` → a take of each leaf; ownership.zig `walkCall` 2768/2791 (if H has not landed); emit.zig `consumedTemporary` 4544, `hoistReceiver` 4607, `hoistsArgs` 4520 → `handsOver` | none after H; otherwise F1's programs become rejected | H's tests stay | `?self`/`!self`/`<self` × place/made/branches/`<` leaves (a 12-cell table test) | −10 |
| B6 (**Owner, temporaries**) | Read a compared operand as any `==` operand | typecheck.zig 2921–2928: `readLeaf(other)` when owning; emit.zig 3505, 3518: drop with `isNone`/`isVariantDiscard` only when the operand is `.made` and no slot holds it (`!dropsTemp`); a `.branches` operand is read in place | sema facts: `in_place_reads` added for the F2 programs, otherwise identical; emit: identical for every existing program | H's compare rejections become **behavior** tests (Core §3: an `==` operand reads) | the five F2 probes as behavior tests (sanitizer-clean, right output) | +10 |
| B7 (**Owner**) | Take leaves through `handsOver` in ownership | ownership.zig: `checkNoImplicitCopy` (2307) → `takeLeaf(e, sink)` over `handsOver` + `valueLeaves`; `movedTail`/`ownsPlace`/`reportMovedTail` (2045–2092) → `walkMove` uses `valueLeaves`; `holdBranchReads`/`holdBranchLeaf` (2920–2952) → one loop over `valueLeaves`; `isWriteBorrowPlace` (1632); `walkFor` 3724 and `walkMatch` 3519–3535 → `handsOver`. `resolvePlace` stays a **path resolver**, called only for `.place`/`.lend` | **identical diagnostics, positions, and text** (`reportAlias` messages unchanged) | none | a sibling test per sink (binding, argument, field, element, return, break) × leaf form (place, field, `o?`, `catch` handler); `test/matrix.py` covers most | −60 |
| B8 | Classify emit's remaining places once | emit.zig: discard 1216, `for` 2133, subject 2329/2416 → `handsOver` (plus `resolvePath` for "addressable"); delete `isPlace` (5849) | emit identical | none | none | −10 |
| B9 (**Owner**) | Record the use of every branching value, and take only what is taken | typecheck records `Use` (`read`/`take`/`lend`) at every context that reaches a `.branches`/`.made` value (`sema.Facts.uses`); emit.zig 2971 takes a tail name only for `take`; a Debug panic when a branching value in value position has no `Use`. Lint in `test/run`: no `isPlaceExpr`, `isPlace(`, `makesValue`, `isBranching`, `readLeaves`, `classifyReceiverShape` in `src/` | facts: a new `uses` section; emit identical | none | `test/matrix.py`: add contexts `recv_value` (a `<self` method on `drop`, `Box.unbox`), `recv_write`, `eq_none` (an optional type), `eq_variant` (a payload enum), `clone` (`+E`), `discard` (`_ = E`); this is the "test that catches a sibling" for F1 and F2 | +60 |
| E1 (**Owner**) | Assert that scopes balance at every rewind | ownership.zig `rewind` (920) and `apply` (973): `assert(vars.len >= p.vars)` and every `vars[p.vars..]` is `.hidden` (F4) | none | none | none (the instrumented run is the evidence; the gates exercise it in Debug) | +8 |
| E2 (**Owner, temporaries**) | Add `exitTo`, the one way a path ends | ownership.zig: `exitTo(.{ .to, .exit: ?Exit, .resume_at })` = run defers (`exitDefers`' body) → report loans `>= to.vars` held by holders live at `resume_at`, **including statement-temporary loans** (merging `leaveTo` 3945–3948 with `capture` 955–961 into one reporter that reports each holder once, F8) → `capture` → `rewind` if `goesOn`. Replace `leaveTo` at 3443, 3587, 3836 and `exitDefers` + `leaveTo` at 3929–3930; delete `leaveTo` | identical diagnostics | none | reject: a defer storing a borrow at `break` and at the end of a scope; `?? continue` storing an inner loan (`x03`); a labeled match guard storing a loan; a failed `while … as` part storing a loan (sibling of `joined_as_failing_part_stores`) | +25 |
| E3 (**Owner, temporaries**) | End branches with `exitTo` | ownership.zig: `leave` (982) becomes `exitTo(.{ .to = p })` + `rewind`, used by `walkIf` 3425/3427, `walkIfBinding` 3449/3452, `walkCatch` 3492, `walkNullish` 3503, `walkMatch` 3595, `joinAt` 991, `checkDeferBody` 3996; `loopIteration` 3839/3848 `capture` → `exitTo`. `capture` and `filterLoansBelow` are then called only from `exitTo` and `escapeVarsFrom` | identical (per the instrumentation, no live loan is lost) | none | none beyond E2 | −5 |
| E4 (**Owner**) | Fold every remaining exit into `exitTo` | ownership.zig: `walkReturn` 3350, `walkPropagate` 3955, `walkBody` 1289, `walkBlock` 1435 → `exitTo` (`.return` / `.propagate` / `.failing_result`, result unused); `popScope` 737–744 uses the same reporter in place of `releaseVarsFrom`'s own loop; delete `exitDefers`; assert that no temporary on a scope var survives (F7) | identical | none | none | −15 |
| E5 | Document the desugaring | docs/INTERNALS.md: "Exits": `exitTo` is the one exit; the S-site table; the hidden-var invariant. CORE §9's two planned rows become *(built)* in the same change (CORE §9 has no `rig pending` example to promote) | — | — | — | docs |

**Totals:**
- source: about +170 (sema) −155 (the old classifiers) +60 (`Use` + emit) +13 (exits), so **about +90 net, range +40 to +140**; plus +60 for A0;
- tests: about 9 hotfix tests, about 20 sibling tests, and 6 new matrix contexts (about 400 generated programs).

**IR-dump expectations, per commit:**
- `parse`, `normalize` and `check --facts` (syntax) are identical
  throughout.
- `check` diagnostics are identical except where H or B6 lists them.
- `emit` is identical except for the F2 programs (B6) and the optional
  flips (B4).
- The A0 sema dump is identical except for the `uses` (B9) and
  `in_place_reads` (B6) rows.

**What touches what.**
- **typecheck's classification:** H, B3, B4, B5, B6, B9.
- **ownership.zig:** H, B5 (unless H landed), B7, B9 (the lint only),
  E1–E4.
- **The rest:** B1/B2/A0 touch only sema, main and emit; B8 touches only
  emit.
- Step 3 (`lendsAs`) must not start until step 2 merges.

---

## 5. What step 2 cannot avoid changing (beyond a pure refactor)

1. **F1/F2 programs** (accepted today, unsound):
   - receivers become rejected ("use `<a`", as Core §5 writes takes from
     a branching value);
   - `== none` / `== .variant` of a branching value becomes a sound
     in-place read (Core §3).

   Neither goes beyond the Core. Both must be listed in the PR.
2. **Optional flips (wrong rejections the unified classifier exposes).**
   The reviewer should decide (Q2):
   - D9 `for x in (mk() if c else mk2())`;
   - D10 `match <a if c else <b`;
   - D11 `+(a if c else b)` and `+mk()` of a Text.

   D9 and D10 rest on reading Core §3 ("a call's result that … `for`
   binds is taken") as covering every *made* value, not only a call. The
   Core does not say whether `+v` or an array literal in a `for` header is
   taken or is a statement temporary. **That is a gap in the Core, not a
   step 2 decision.**
3. **Nothing in `exitTo` changes acceptance.** The evidence is the 6,386-
   program instrumentation (§3.3). Diagnostics stay identical provided
   the reporter reports each holder once (F8).
4. **No `rig pending` example becomes ordinary in step 2.** Core §9's
   per-expression and per-path rows are "planned" with no example, so
   only their status words change (E5).

---

## 6. Re-run of the earlier probes (task 3)

`sweep-core-audit.tsv`: the 315 probes in `reads/`, `loans/`,
`loans/text/`, `emit/`, `emit/text/`, and `emit/mod/f20–f23`.

- **187 rejected, 128 accepted.** No accepted probe uses freed memory,
  leaks, or fails to compile.
- The 6 non-zero exits are intended:
  - `a04` is the specified bounds panic;
  - `f13` and `f20`–`f23` fail on purpose, or have no `main`.
- Output changes since dd36c78 are fixes:
  - the emit `u01`–`u08` and `t05`/`t06` Cell probes used freed memory
    and now print the Cell after its later arguments, as the
    `test/behavior/emit/print_reads_cell_*` tests specify;
  - `s07`/`s23`/`s26`/`s32` are rejected under the statement-`-x` rule.
- Status changes in `reads/` since main dd36c78, in both directions:
  - **now accepted** (the text-core landing): `q01`–`q07`, `q09`,
    `q10`, `q12`–`q14`, `r02`, `r03`, `x01`, `x04`, `x05`, `x07`,
    `x08`, `x12`, `x13`, `e04`, `m04`;
  - **now rejected:** `q11`, per Core §3.
- The earlier soundness holes are closed: `s01`/`s03` (`for` over `o?`
  or a ternary), `q08`/`q15`/`q16` (header views), and `u01`–`u04` and
  `f09`–`f11` (defers at continuing exits). All are rejected today.

**The only accepted unsound programs found are this audit's F1 and F2
probes** (`results-step2.tsv`: r01, r02, r03, r13, e01, e02, e04, e06,
e10).

---

## 7. Open questions

- **Q1. Is `handsOver` recorded or computed?**
  - The proposal: a pure sema function over recorded facts, plus a
    recorded per-context `Use` fact (B9). That meets AGENTS.md's
    "recorded as a fact" through `Use`, and avoids a map entry per
    expression.
  - The alternative: memoize `Hands` in `Facts`, which costs about 1
    entry per expression node.
- **Q2. Flip D9/D10/D11 in step 2, or keep them rejected?** Both are
  allowed. Flipping D9/D10 also needs the Core to say whether a non-call
  made value in a `for`/`match` header is taken, or is a statement
  temporary (Core §3 names only "a call's result").
- **Q3. Land hotfix H now, as its own reviewed branch (like PR #32), or
  fold F1/F2 into step 2's B5/B6?** H is about 10 lines and closes two
  live use-after-free classes. Waiting for steps 1 and 2 leaves `main`
  unsound for their duration. H counts as "the" ownership branch while it
  is open.
- **Q4. Does `static` (lives for the whole program) belong in `Hands`
  now?** Core §9 includes it. No step-2 consumer exists, so the
  alternative is to add it in step 6 with its consumers.
- **Q5. Does the A0 sema dump ship in the CLI** (a debug flag), or live
  only in a test helper? It changes no language behavior, but it is a
  user-visible option during the feature freeze.
- **Q6.** Step 3 adds implicit read lends of bare names. Should
  `handsOver` already carry a recorded override slot for them, so step 3
  touches only the context table and not the classifier?
