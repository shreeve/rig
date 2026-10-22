# Open questions for the Rig session (design owner), REVAMP-3

These decisions belong to the design owner. Each one cites its evidence. None of them blocks a safety fix, and every soundness hole found so far has been fixed or rejected.

## A. Where CORE.md and the compiler disagree
Step 8 found these (probes in `logs/step8/probes/`). In each, either CORE's wording or the compiler has to move. CORE is fixed, so these are wording or status proposals.
1. **CORE §4, "a read view of plain data copies".** The compiler copies numbers, Bool, String and plain enums out of a `?P`, but rejects a plain struct (`fun f(p: ?P) -> P  p`).
   - **Proposal:** qualify the status (*built* for scalars, String and plain enums; *planned* for plain structs), or narrow the wording.
2. **CORE §5, `copy` / `fill` / `[n of x]` "need copyable elements".** The compiler requires plain data, so a read view (`fill(?m)` on `[?Int]`) is rejected.
   - **Proposal:** say "plain-data elements".
3. **CORE sentence 1 marks "a block's last value" as planned,** but a name local to the block already moves bare as a value block's last value. Outer names and `break x` still need `<x`.
   - **Proposal:** a status update to *built* for block-local names.
4. **The kind of a struct of Strings.** By CORE's kinds it is a view; the compiler treats it as plain data (Cell.get, fill and `[n of x]` accept it). SPEC follows the compiler.
   - **Decide:** which is right?
5. **`for x in mk().items`** is rejected for a Vec of owners. CORE §3 says a value made there that `for` binds is taken.
   - **Decide:** a status note, or build it.

## B. SPEC wordings to confirm (step 8)
1. **Kinds table, third column**, "A bare name where the value is taken":
   - plain: copies;
   - owning: moves only as `return x` or a function's last value; anywhere else rejected (`<x` / `+x`);
   - handle: the same (`<h` / `+h`);
   - view: copies a read view; a write view is rejected (`<w`).
2. **§7 Lending, where a read lend goes unwritten:**
   - an argument to a view parameter;
   - a method's receiver;
   - the subject of `for`, `if … as` and `match`;
   - a held view or function name lent on to read.

   A lend kept in a binding or a field is always written.

## C. Rules the oracle found CORE doesn't decide
1. Does a call's view result keep a write argument write-lent? (r3-or-pa-downgrade, r3-s36-loans-r04)
2. Does dropping a Vec of views at the end of its scope use those views? (r3-s45-v-v14, v27, review-place-b3-r032, b7-v025)
3. Does a bare write-view element or field, used as a value, copy what it sees? (r3-s45-v-v09, review-lang4-a3, b3)
4. Field-disjoint loans: today, field loans are unioned.

## D. Conservative limits that wait for redesign (documented in HANDOFF's weak spots)
1. **Payload views.** A view of a read-`match` payload is usable within its arm only, "for now" (CORE sentence 1). Lifting it needs step 10's B4/B5, where emit points instead of copying. The facts already show that an unguarded match on a plain place subject with no temporaries is matched in place.
   - **Decide:** lift for that case after the consolidation?
2. **Header temporaries.** Every header whose subject makes a statement temporary is rejected; it lifts with B4.
3. **The rest of step 10's open questions** (step10/design.md §4), for example whether a branching receiver should be a per-leaf pointer or a rejection. Revamp already uses per-leaf pointers.

## E. Items held back from the consolidation
1. **5.4, bare `break x` of a loop-local owner** (commit 3acb07a9 on r3-step45-held).
   - The oracle models it under `--planned`.
   - It waits until emit's usage scan becomes a recorded fact (step10/design.md).
2. **n39, field-precise re-pointing:** after the freeze, together with field-precise loans.
3. **4.6, std search taking `x: ?T`:** it newly rejects `slices.contains(?v[..], ?t[4..5])`, an explicit lend of a branching value.
   - **Decide:** extend implicit lends, or accept the rewrite.
4. **`into` for stores, function-type `from`, and path tokens:** after the freeze, as Core changes.

## F. Decisions already taken with the user (for the record)
- **Keep `Text` (owned) / `String` (view).** No rename. Teaching is done with a diagnostic note and a WELCOME line.
- **Patch releases v0.1.1–v0.1.6** fixed the live holes in released Rig.
- **Step 10 builds design B** (storage facts: B1, B2, B3) inside the consolidation. The full lowering IR is decided later, by measurement.
- **Std `from` clauses:** strip_prefix, strip_suffix and cut (`from s`); os.env (`from static`).
- **The Nexus mirror diffs** are `logs/step6/nexus-mirror.diff` (`from`) and `step7/nexus.diff` (the read_view/write_view node renames). Send them with the merge commit and the sha256 prefixes.

## Decisions (user as design owner, 2026-10-05)
- **A:** A1–A3 and A5 were resolved by the CORE status-word commit b3fa17c7, now on main. A4 was refuted by the final review: the compiler matches CORE's read-view kind.
- **C1:** a call lent `!v` that returns only a read view leaves `v` read-lent while the view lives. If the call stored a write view (by its store facts), `v` stays write-lent.
- **C2:** dropping a container of views is not a use of those views. Their loans end at the container's last real use.
- **C3:** a bare write-view field or element used as a value reads the value it sees: `x = h.w` copies the Int. Only a call's `!T` result bound without a type keeps the view (M2).
- **D:** B4 is the next major work: emit yields `&place`, never a copy, for headers and match subjects. Then lift arm-local payload views for place subjects and the header-temporary rejection, followed by an independent review round in which the stop rule applies.
- **E3:** std search taking `?T` waits for the planned whole-branch lend `?(a if c else b)` (CORE §3), so that no working program breaks.
- **C4/E2:** field-precise loans, and re-pointing a view field that releases its old loans, come as their own round after B4. CORE is updated first, then the usual review.
- **B:** both SPEC wordings are approved as they stand (the Kinds table's third column; where a read lend goes unwritten).
- **E1 (bare `break x`):** DECIDED. `break x` moves a name declared in the loop body without `<`, matching `return x`. The explicit forms `return <x` and `break <x` stay valid; that is verified on v0.2.0 with probes/break/forms.rig, sanitizer-clean. An outer name still needs `break <x`. It lands with B4, once the emitter's usage scan has become a recorded fact. The docs state one rule: "Write `<x` when `x` stays in scope after the move; where `x`'s scope ends with the move, the move is plain." 
- **Seam 1 (DECIDED):** a binding takes the type of what's on its right, and an annotation converts. This replaces C3.
  - `x = h.w` (a write view in a place) is rejected; write `x: Int = h.w` or `x = <h.w`.
  - `w = f(!n)` keeps the view.
- **Seam 2:** `!mk().m()` is accepted when the call's result is used (`!mk().pop()`, `!mk().take()`). When the result is discarded, it's rejected, because the change would be lost. Proposed; awaiting the user's confirmation of this refinement.
- **Seam 3 (DECIDED):** Box, optionals and generic `T` accept any read view, tracking its loans as Vec does. Cell and Signal stay no-loan (CORE sentence 9). This comes after B4.
- **Round C review:** clean (review-c-rules.md), with four Low findings. L2 is item #4 (an argument's write lend ends when the call returns), folded into round C.
- **Seam 2 (DECIDED):** `!` lends any value to write, named or temporary. `!mk().bump()`, `!mk().pop()` and `!mk().take()` are all accepted, whether or not the result is used. Bare `mk().bump()` stays rejected, with the hint to add `!`. It's queued after round C.
- **Seam 3, corrected scope (CORRECTED AGAIN by the ^T design study):** the written type `Box[?U]` is rejected even for plain `U`. `Box(?x)` of an Int only works because the view copies to an Int. v0.2.0 lets views of plain data and Strings into optionals, generic struct fields and generic `T`. The real gap is views of OWNERS (`?Vec`, `?Text`) in `Box` and a generic function's `T`, rejected while `Vec[?Vec]` works. The fix: one holder rule ("a value that holds a view keeps the viewed thing lent while it's used") for every holder except Cell and Signal. Probes: probes/cellstr/.
- **Future idea:** let library types declare their own drop and lend rows, without traits, so `Text` could live in std over `Vec[U8]`. A later design project.

## Ideas for later (not decided, not scheduled)
- **Library types that declare their own drop and lend rows,** without traits. A std type could say "`Text` lends `String` from its bytes" and how it drops, so `Text` could be written in std over `Vec[U8]` and fewer types would be built into the compiler. This needs a small, checkable declaration form; Rig doesn't want traits or `unsafe` outside `raw`.
- **A `Chr` type:** a Unicode code point (a `U32`) decoded from text by `for c in s.chars()`. It's a decoded value, not a slice element; `String` stays bytes.
- **A full lowering IR, decided by measurement:** checker and emitter consume one lowered program. Start it only if, after B4, more than one Critical or High finding per review round is still in the "checker and emit model different programs" class (step10/design.md).
- **A structural address chokepoint:** every `&` and `|*x|` emit writes targets a place, a slot or fact-named storage, and the chokepoint checks each fact's `life` (HANDOFF weak spots).
- **cpuq follow-ups for Rig:** split the corpus and equivalence runs into chunks; preemptible jobs once cpuq has them.
- **Names (DECIDED 2026-10-06):**
  - `Vec` → `List`: its own mechanical round, proved by equivalence, targeting v0.3.0.
  - Keep `Cell`, `Text`/`String`, `Box`, `Signal`, `[N]T`, `[]T`, `*T` and `~T`.
  - Add a WELCOME line: "`*T` is a counted pointer, like Rust's `Rc<T>`".
  - Every named type is an owner; views are spelled with symbols (`?T`, `!T`, `[]T`), except `String`.
- **Teaching rule (DECIDED 2026-10-06):** "Owners have names. A view is written with `?` or `!`, or is a slice: `[]T` for elements, `String` for text." The user rejected spelling the text view as a quote or backtick symbol, because type positions need a word. Add this rule to WELCOME and SPEC, together with the `*T` note.
- **Box → `^T` (DECIDED 2026-10-06, "a BIG DEAL").** It ships in v0.3.0 together with Vec → List, and must meet the reviewers' conditions first:
  - publish the restated rule;
  - reject `^^T`, `^*T`, `*^T` and `^~T`;
  - write one rule for what reaches through `^`;
  - settle how unboxing is spelled;
  - fix the method-shadowing class;
  - add migration and dead-key hints;
  - fix the docs (DESIGN's `^w`, SPEC's `eval`, the CORE tables).

  Reports: holding-rule/*.md.
- **Bugs added to the v0.2.1 hotfix:**
  - `Box[*S]` field access fails in Zig;
  - a circular `upgrade` hint on a boxed weak handle;
  - a generic struct with a `*T` field at a closure type fails in Zig.
- **Seam 1, REVISED (DECIDED 2026-10-06):** "A bare name or place only reads" (CORE sentence 1, extended to places).
  - `x = w`, `x = h.w` and `x = v[i]` read the value their write view sees. v0.2.0 already reads `x = w`.
  - A call's `!T` result is a value, so `w = f(!n)` keeps the view.
  - This replaces the earlier "a binding takes the type of the right side", which conflicted with sentence 1.
- **Known stricter-than-Core cases:** three split-statement forms (match_arm_writes, write_result_whole, stored_whole). They're for a later round, in which a result's read loans end at their last use within a statement.
- **String and Cell (proposed, awaiting the user):**
  1. Reword CORE §10 and sentence 9 now, so a Cell's rule reads plainly as a loan check.
  2. Later: `s: String from static` on parameters and fields (see Ideas for later).
- **^T design study (holding-rule/design.md):**
  - **Prototype:** `^T` works as a drop-in for `Box[T]`. With every source rewritten, 3766 accepted programs emit byte-identical Zig. The grammar has no conflicts.
  - **Spellings:** `^Node(...)` makes a box, `^<x` boxes an existing owner, and `^x` copies plain data into a box.
  - **Kind:** in CORE §1, `^T` is an owning kind.
  - **`^fun`:** rejected, and reserved for a future uniquely-owned closure.
  - **Still to decide:** the combinations `^^T`, `^*T`, `*^T` and `^~T`. The design study says allow them (rejecting would be an exception list); the red team says reject them (they look like typos).
  - **Live bug:** `x = *none` crashes the emitter. Added to v0.2.1.
- **Heap-sigil stacking (DECIDED):** reject `^^T`, `^*T`, `*^T` and `^~T` (and `**T`, already rejected) in type resolution, not the parser. The rule is "a value is held one way on the heap", and resolution also catches stacking that arrives through an alias or a generic.
- **Text plan (DECIDED 2026-10-06, staged):**
  1. `Static`, in today's spelling, after seam 3.
  2. The fold (one text view), after B4b.
  3. The rename in v0.3.0 with `^T` and `List`: Text→String, String→?String.

  Conditions:
  - `Static` converts to `?String` only where the text is read (including through branches, `??`, list literals, read slices and generics), never where it can be written.
  - Hints point to a `?String` parameter.
  - Fix the `(?T?)?` hint.
  - Seam 3 covers handles too.

  Reports: text-rule/*.md. Effort: about 9–11 agent-days.

## `<` on a place (decided 2026-10-07)
**Decision (user): Option A.** `<` always leaves its source done: a name is ended, an optional place is emptied to `none`, and a place that can be neither (a plain field or element whose value copies: `<s.n`, `<v[0]`, `<s.p` with plain `P`) is rejected, with the hint "`s.n` already copies; drop the `<`". Before: `<` on a plain field or element silently copied and left the source usable, unlike `<n` on a local. Queued as its own small round ahead of B4b, with its own review.

## Function definitions write their parameter list (decided 2026-10-07)
**Decision (user):** a function always writes its parameter list, even when empty: `sub main()`, `fun answer() -> Int`. This matches calls (`f()`) and function types (`sub()`). The parenless form `sub main` is rejected with a fix-it ("write `sub main()`: a function's parameter list is always written, even when empty"). Grammar change (Nexus sync), a mechanical rewrite of tests, examples, std and docs, and a style lint (one blank line between top-level declarations). It goes in the polish round after `move-done`.

## Rig's own compiler builtins (decided 2026-10-07)
**Decision (user):** `@` marks a compiler builtin. Rig's safe builtins get Rig names, usable anywhere: `@size(T)` (was `@sizeOf`), `@align(T)` (was `@alignOf`), `@type(x)` (was `@TypeOf`), `@name(T)` (was `@typeName`). Zig's builtins keep their Zig names and work only inside `raw`. Outside `raw`, the old Zig spellings get a fix-it ("write `@size(I64)`"). SPEC's placeholder `@name(args)` becomes `@builtin(args)`. Rejected: `T.size` (it collides with enum variants and type functions named `size`), `size_of(T)`, `@type(T)` and `@text(T)` for the name (`@type` is taken, and `Text` is being renamed).

## A temporary holding a Cell, lent to read (decided 2026-10-07)
**Decision (user, on the recommendation of three independent reviews):** lift the rejection of `?mkc()`. A temporary holding a Cell may be lent to read, as one lent to write already can (`!mkc()`), and as a field of a temporary (`?mk().p`) and a generic `f(?mk())` already can. The temporary lives in its statement's slot (the existing `lendTemp`/`dropsTemp` facts), and a change through the view lands there and is dropped with it. This applies to the receiver form `mkc().hit()` too. `?(a if c else mkc())` stays rejected (it would copy a unique value), by extending the `namedLeaf` rejection to `holdsCellByValue`. CORE is unchanged: §3 already says "a temporary may be lent to read or to write". SPEC ~4049 ("only a temporary's Cell has no place") changes. Reviews: language designer (lift), soundness reviewer (lift; probes and a patched copy in scratchpad/mkc/), skeptic (keep for now on cost grounds, unify later).

## `@name(T)` returns Rig's names (decided 2026-10-07)
**Decision (user):** `@name(T)` returns the type's name as written in Rig (`"Int"`, `"Bool"`, `"Point"`, `"Vec[Int]"`, `"Int?"`, `"?Point"`), not Zig's (`"i64"`, `"__rig_main.Point"`). A type known where it is written gets the string from sema's type printer; a type parameter maps the Zig type back at compile time through a runtime helper, with user types read from a name constant the compiler writes into each one. `@name(Vec[Int])` (unsupported today) works.

## Releases after v0.2.9 (decided 2026-10-08)
**Decision (user):** every change, fixes included, ships in the v0.3.x line; v0.2.x gets no further releases. The next tag is v0.3.0, cut only after the deep gate. Docs state this timelessly (no dates or history wording).

## CORE sentence 1 status words (approved 2026-10-08)
**Approved (user):** commit 7366148a in #84 marks `break x` of a loop-declared name and payload views past the arm as built, and states "Write `<x` when `x` stays in scope after the move".

## Payload fields by name (decided 2026-10-08)
**Decision (user):** a pattern takes a variant's fields either in order, all of them (`.circle(r, c)`), or by name, any of them (`.circle(radius: r)`, the rest ignored and left with the subject), but never both ways in one pattern. One sentence for SPEC: "A pattern binds a variant's fields either in order, all of them, or by name, any of them; it doesn't mix the two."

## A `!` that would be ignored (decided 2026-10-08)
**Decision (user):** reject it, with a hint that offers both fixes. Where a write lend `!x` lands in a value slot that stores a plain value (e.g. `Opt.some(v: !n)` building `Opt[Int]`, or a generic `get(!n)` inferring `T = Int`), the compiler rejects: "`!n` here is read, not held: `Opt.some` stores an `Int`. Write `Opt[!Int].some(v: !n)` to keep a write view of `n`, or `Opt.some(v: n)` to store a copy." Inferring the view type was rejected: it would silently lock `n` for the holder's life (AGENTS rule 4, effects stay visible). Relaxing to inference later stays possible without breaking code.

## A written `!x` where a read view goes (decided 2026-10-08)
**Decision (user, "it's POLS"):** rejected, with the fix `?x`. `rd(!n)` where `rd` takes `?Int` is an error: "`rd` only looks at `n`; write `rd(?n)`". With the ignored-`!` rule, one rule holds everywhere: a written `!x` is kept only where its slot holds a write view. CORE §4 (approved) reads: "A written `!x` is kept only where the type it goes to holds a write view; read as a value anywhere else (copied out there, an operand, an index, `print`), its `!` would be ignored, so it is rejected: a type that says `!T` keeps the view, and `x` alone is the copy. *(built)* Where a read view goes, a written `!x` is rejected too: write `?x`. *(built)*"

## CORE wording for the written-`!` rule (approved 2026-10-08)
**Approved (user), replacing the earlier wording:** appended to CORE sentence 4: "A written `!` must lend to write: `!x` is rejected wherever `x` is only read: an operand, an index, `print`, a copy, or an argument the callee only reads. Write `x` to copy it, `?x` to lend it to read, or `!T` in the type to keep the write view. *(built)*" The §4 sentences are removed; SPEC gets the Written / Where it goes / Write instead table. Diagnostic: "`rd` only reads `n`; write `rd(?n)`". Vocabulary: read/write only.

## A lend is never the base of a path (decided 2026-10-08)
`(!x)` / `(?x)` as the object of a field or index is rejected everywhere; write the lend on the whole path (`!p.o`) or nothing where the assignment shows the write (`arr[i] += 7`). Owner: "do the most POLS thing". Replaces fixing the `(!arr)[0] = 7` miscompile; `(!p).x = 5` stops working (v0.3.0 break).

## A write call used as a value puts the `!` in parentheses (decided 2026-10-08)
Statement: `!v.push(x)`, `!set.insert(k)`. Value used (condition, `as` header, operand, binding, argument, return): `(!set).insert(k)`, `if (!tapes).pop() as t`, `x = (!v).remove(0)`. Replaces the "Bool value used" trigger. Short form in value position rejected with an exact hint. Round after lend-base, with `drop x` and the spacing rules (v0.3.0 breaking syntax).

## v0.3.0 syntax decisions (approved 2026-10-09: "Approve 1, 2, 3, 4 and 6")
1. Drop now is a statement `<x` (move nowhere); `-` is only negation. A statement `<s.f` takes and drops the field. CORE sentence 2: "**2. `<x` moves, `+x` makes a new owner.** A statement `<x` moves `x` nowhere, so it drops now."
2. Spacing (Swift-style): an operator between two values has the same spacing on both sides; a sigil touches what it marks; `.` has no spaces. Otherwise rejected with a hint.
3. A slice is lent the way its name is: implicit read as an argument (`total(w[1..3])`), `!w[1..3]` to write; a binding marks it (`s = ?w[1..3]`).
4. Multi-line closure body: `)` (or `]`) on its own line at the call's indentation; one-line body inline; hanging `)` on the last body line rejected.
6. CORE: "`?` promises that nothing changes except a field whose type is a `Cell`."
Also approved earlier: a write call used as a value puts the `!` in parentheses.
Plan: syntax-a (1, 2, 4, 6 + TODO.md) in parallel with lend-base (grammar/lexer/statement level); syntax-b (3 + write-call rule) after lend-base (lend/receiver classifiers).

## `for` over an iterator (approved 2026-10-09: "Approve 0.3")
`for x in it`, where `it` has `next(!self) -> T?`, is the desugaring `while (!it).next() as x`; the checker walks exactly that. Replaces the roadmap's "a `for` never calls user methods". IDEAS.md §0 sets the bar: shorter and plainer than idiomatic Rust, measured by a Rust-parity corpus.

## Sigils stay `?` look / `!` act (decided 2026-10-09)
Blind tests (guided A/B/C/D, no-guide A/D, truly clean A/D across 4 models) tied on accuracy; D slightly preferred, A had brief `!`-as-not and `?T`-as-optional slips. Owner: "stick with A for right now... update any rules that need it, plug any holes." Follow-ups: `not` + comparison needs parentheses; one-page sigil guide; plain error messages; lasting-borrow `?` at the call when the result keeps the loan; print/Text read implicitly; a no-value closure's last line is a statement.

## Design study after v0.3.0: write views only in bindings (approved to study, 2026-10-09)
Proposal: a write view `!T` lives only in a binding, a parameter, or a return value — never stored inside another value (struct field, optional, enum payload, generic T, Vec element, branch result kept). Read views, owners, `*T` stay storable. Motivation: nearly every soundness hole in rounds #89–#96 involved a write view held inside another value. Study: survey tree/std/examples for stored write views, what each would become (pass `!v` per call, `*T`/`*Cell`, or restructure), what checker code/rules it deletes, blind readability of alternatives. Owner also asked whether `*x` is better than `!x`: answer — not as a replacement for lending (`*x` allocates + refcounts), but `*T` (with Cell for mutation) is the candidate for long-lived shared mutable state stored in values.

## "Mutation is never data" — the converged reveal (2026-10-09)
Three independent researchers (bug-cluster map, other languages, sigil algebra) converged: `!T` is a passing mode, not storable data (params, returns, receivers, local/header bindings only); Cell only behind `*` (shared mutable state = `*Cell[T]`, maybe spelled `*!T`). CORE could read: "You change what you were lent with `!`, or what you share with `*`." Evidence: examples/ and std/ store zero write views; every example Cell is `*Cell`; ~12 recent review rounds' Criticals live here. Secondary reveals: a branch is a value never a place; a header always binds by reference; a sigil's operand is a path or a call (grammar); one view per owner (`?String`, `?[T]` = slice). Read views stay storable (std Split/Lines store String). Measurement experiment running: study-mutation-never-data.md.

## Approved 2026-10-09 ("yes to all three")
1. Adopt "a `Cell` lives only behind `*`" for v0.3.0 (CORE sentence to be proposed for approval).
2. Adopt "a write view is never stored inside a value" (params, returns, receivers, local/header bindings only; no strict closure rule).
3. Measure next: branches over write views are never places; `(!T)?` only as a parameter.
Inline `a if c else b` stays (owner asked): the problems are branching values used as places, in every form (`if` blocks as values, `??`, `catch`, `e?`), not the ternary's spelling; "a branch is a value, never a place" fixes all forms.

## Study 2 result (2026-10-09): rule 3p
Rule 3p: a branching value over write views is rejected as a write view (bound, matched, passed, stored) only when one of its leaves is a PLACE (a name or field holding a write view); made leaves (`!a if c else !b`, `getw(!x) catch !y`) stay. With rules 1+2+3p: 9 of 11 write-view Critical/High findings unwritable (130/145 probes); fallout 21 programs (1 behavior test). Rule 4 (`(!T)?` only as param/return) adds little (+1 finding); optional. Remaining finding (syntax-b-2 C2, match !x payload loan) is already rejected by #94's checker, just not unwritable by syntax. Proposed: adopt 3p in the "never data" round; it makes headerCopiesWriteView + header-paths' path-walk deletable (~85 lines). Awaiting owner.

## Rule 3p approved (2026-10-09, owner: "proceed full steam ahead")
Never-data round = Cell only behind `*` + write views never stored + rule 3p + branch redesign (every in-place read of a branch is a lend through lendsBranch).

## CORE wording approved (2026-10-10, owner: "approve A–D")
A §8 "The sigil leads the whole path" bullet; B shortened sentence 9 (four plain facts, Cell changes through any handle or view); C new §5 rule "Write views are not stored"; D stale fixes (sentence 2, sentence 7, §6, §1 Cell bullet -> pointer, §5 opening). Ships with #97.
Then (approved): a shared Cell changes only by a marked call, `!c.set(5)` — `?` then promises no change, no exception; own follow-up round after #97.

## Approved 2026-10-10 ("all as recommended")
1. Static CORE wording (sentence 9 no-loan homes keep Static text; §1 Static is plain; sentence 7 Static/module constants live for the program; §4 Static reads as String where only read, nothing converts String to Static).
2. A text literal in a binding is a Static (as built).
3. `for x in !it` required for an existing iterator (flip `bare_place_advances`); bare `for` only for made iterators.
4. CORE §5 holder sentence: "`^T`, optionals, and a generic `T` hold any value but a write view, as a `List` does. A holder of a read view carries its loan."
Do these as one small round right AFTER the rename lands (use the renamed spellings).

## Nexus: unpinned, instant co-development (owner, 2026-10-10)
Supersedes the zig-fetch pin recipe. Don't commit src/parser.zig; `zig build` generates it from rig.grammar with the sibling ../nexus checkout (cached); drop the parser freshness check; CI checks out Nexus main beside Rig. Nexus may rebuild freely (no more "clear" holds). Small PR right after the rename lands.

## Rename CORE text approved (2026-10-10, owner: "APPROVE ALL FOUR")
1 `^T` held like a handle, behaves like an owner (one owner, `<b` moves, `+b` copies into a new box); 2 a `String` lends a `?String` (its bytes), its only read view; `+s` of a `?String` is a new `String`; 3 a value is held one way on the heap (`^T`, `*T`, `~T`), stacking rejected; 4 teaching rule "Names say what a value is; sigils say how you hold it." Ships with #109.
Also recorded (owner interest): "Nexus outputs Rig" — route 1 (Zig-backed Rig wrapper around a Nexus Zig parser, days) and route 2 (Nexus Rig emitter + Rig runtime, weeks; needs constant tables + traits/closures = Trig #2/#3/#5). Post-v0.3.0 roadmap candidate.

## Bare `for` with no loop variable (owner request via Trig, 2026-10-11)
`for 0..2` runs the body per element binding nothing; exactly `for _ in <iterable>` (same checks, lowering `for (0..2) |_|`). Recommendation: any iterable (ranges, slices, lists, `!it`, made iterators), since it IS `for _ in X`. Grammar: after `for`, NAME then `in` = binding form; otherwise the bare form (LALR(1) decides; conflicts must be zero or justified). Small grammar round after the decide branch lands; in v0.3.0.

## Bitwise complement is `x.not()` (owner decision via Trig, 2026-10-11)
On every integer type (Bool too, equal to `not b`); Rust's own name (std::ops::Not::not). No grammar change. SPEC states `x.not()` flips every bit (`0.not() == -1`); `not x` on an integer stays rejected with hint "`not` takes a Bool; for the bitwise complement write `x.not()`".

## PROPOSED via Trig (fork) session as owner decision, 2026-10-11 — awaiting the owner's direct confirmation: keyword `obj` replaces `struct` (family use/sub/fun/new/obj). Concern to raise: `obj` is a very common variable name (JS/TS), so a reserved `obj` breaks those names; option: make `obj` contextual (keyword only where a declaration starts) via Nexus @keywords, like unique/from/static. Plan if confirmed: migration script rename + `struct` rejected with hint "write `obj Name`", docs/examples updated, v0.3.0.
## Also PROPOSED via Trig (fork), 2026-10-11, awaiting the owner's direct confirmation
2 Leading-dot continuation: a line indented deeper than its statement that starts with `.` continues the expression above (method chains without wrapping parens). Caution: `match` arms start with `.variant` at deeper indentation under a block header, so the rule must apply only where the line above does not open a block (match/if/for/while/fun/sub/closure body).
3 A closure may declare fewer (trailing) parameters than its expected function type; omitted ones are never bound; an owned argument nobody binds is dropped by the caller (state it); middle params still need `_`; `*` stays required for kept closures.
## CONFIRMED by owner directly (2026-10-11)
(1) `obj` replaces `struct`, as a contextual keyword (a keyword only where a declaration starts; `obj` stays usable as a name). (2) Leading-dot chain continuation on deeper-indented lines, not after a line that opens a block. (3) Closures may omit trailing parameters (never bound; the caller drops an unbound owned argument). All for v0.3.0.
## Owner decisions 2026-10-11 (perf)
- All perf work lands BEFORE the v0.3.0 tag.
- Bit ops are methods: x.leading_zeros(), x.trailing_zeros(), x.count_ones() (Int result; zero -> bit width).
- Inlining: compiler decides by a size rule, no syntax.
- Via Trig (owner decisions): `<<%` wrapping left shift (amount still < width or panic); bit intrinsics + <<% next, before SIMD.
- Via Trig: SIMD approved — Simd[T, n] (mask Simd[Bool, n]); lane + panics, +% wraps (checked sum helper; never @shrExact); v == w is a mask, `if mask` rejected with hint .any()/.all(); start now as freeze exception, order rtfast -> bits/<<% -> SIMD r1; byte lookup in r2 (OOB -> 0). Design: ~/Data/Code/trig/docs/simd/ @ 7360b16.
- Stack protector: owner asked for my recommendation (pending).
## Owner 2026-10-11 (direct)
- "I agree 100% with Trig": Trig's relayed decisions (bits/<<% before SIMD; SIMD's five decisions) and the SIMD proposal's recommendations, incl. its CORE paragraph (struct->obj), stand. Remaining open questions take the proposal's recommendations (implicit splat, v.with only, min/max by arity, no byte order for 1-byte lanes; pad:/blocks(N)/module constants in round 2).
- Stack guard: as recommended — after rtfast, Trig re-measures; if >~1%, enable the protector only when a program contains raw or extern "c" code; else keep as is.
## Owner 2026-10-11 (proven checks design, .git/revamp/r3/design-proven-checks.md)
- CORE bullet §10.2 APPROVED. rig.len cap 2^62-1 + SPEC line APPROVED. Proof assertions run in every debug build APPROVED.
- Stack guard RESOLVED (Trig measurement on rtfast): -fno-stack-protector mean −0.3%, mixed signs, within noise -> keep protector everywhere; no work.
- Owner 2026-10-11: `!t.push[T, e](v)` name APPROVED (plus `!t.reserve(n)`).
- Owner (via Trig, consistent with direct "100% with Trig"): m.first() -> Int? APPROVED; "pull out all the stops" to beat sonic-rs, same quality bar. Saturating spelling still open (SIMD round 2).
## Owner decision (via Trig, 2026-10-11): JSON moves into Rig as std.json
- Rule 5 read as "out of the language", std/ hosts libraries (agreed). Layout: std/json.rig; test/json (./test/run json; subset in gates, full in deep gate); third-party data fetched by pinned sha256 script, not vendored; bench/json (competitors, timers) not in CI; docs/json; API lands as-is, marked experimental; idiomatic API (! errors) later with owner names. Trig keeps its copy until std.json lands.
- Owner (via Trig): stdjson lands LAST (rebase on clean main, re-gate, re-bench; include tiered scan if simd+simdfirst landed). Land each round as soon as gates+review pass.
## Owner 2026-10-12
- Bracket rule (precise): "After a name, square brackets give compile-time arguments and parentheses give run-time ones. Indexing is the one familiar exception." NOT in CORE; add to QUICK.md, SYNTAX top; fix over-broad wording in README/SYNTAX/FAQ/DESIGN/WELCOME. (round bracketdocs)
- String write window: first try zero-new-API fast short copies inside `add` (round shortadd), measure; only if clearly short, add `!t.push(v, keep: k)` (owner prefers keep: over a new name).
- Pending owner OK: table.lookup(v); +| -| saturating (= Zig's own; grammar check vs closure bars); cur.shift_in[k](prev).
## Owner decisions via Trig (2026-10-12)
- Trig's core needs come AS SOON AS Trig needs them (not "after v0.3.0"): modules at scale (1), traits + Map/Set (2), closures as values (5), constant tables (3). Bring each as a concrete written proposal: options + recommendation, CORE wording, desugaring, failing reject/pending tests. Order: modules first (modules.zig/resolve.zig, can run beside an ownership lane), then traits+Map/Set, then closures; constant tables wherever they fit. Proposals started: .git/revamp/r3/proposal-{modules-constants,traits-map,closures}.md.
- pup gate worktrees + logs moved to /zfs/rig/rig-wt (pup-lib.sh WTS, pup-gates.sh RLOG). Old ~/Data/Code/rig-wt (20 GB on root disk) to be removed after in-flight pup jobs finish.
- Suggestion (not decided): deep gate as a manual GitHub Actions workflow split 16+ ways on larger runners.
- Owner APPROVED (via json.rig, 2026-10-12): table.lookup(v) (idx>=16 -> 0); +| -| saturating (vectors; scalars for consistency; grammar check); cur.shift_in[k](prev). Round simd2 started.
- Owner RENAMED (via json.rig): joined shift is `cur.lag[k](prev)` (not shift_in). Added to simd2: lane shifts by constant/scalar `v >> c`, `v << c` (<<% wraps), lookup with 32/64-lane index over a 16-entry table.
## Owner 2026-10-12 (direct)
- APPROVED: modules at scale + constant tables proposal (.git/revamp/r3/proposal-modules-constants.md), all 11 decisions as recommended, incl. the constants CORE paragraph. Start building. Constant tables after the constfold bug fix lands.
- Hashing is spelled `x.hash()` (not `@hash(x)`); traits/Map proposal otherwise pending approval. Closures proposal pending approval.
- Owner 2026-10-12: order after modules = CLOSURES before traits+Map/Set.
- Owner 2026-10-12: APPROVED closures proposal (.git/revamp/r3/proposal-closures.md) as recommended, all 11 decisions incl. CORE §5 text. Build starts now beside modules.
- Owner 2026-10-12: APPROVED small-spellings proposal as recommended: f.to_bits()/Float.from_bits(u); I32.wrap(x); Status.from_int(n)->Status? (from_int reserved on enums) + @variants(T); math.shortest(f)->Decimal?; std text runes (rune_at, rune_before, runes, is_space_rune, obj Rune) + trim/words Unicode whitespace; expect(cond)! (own round). Order: 18,20,17,19 then 22 then 25.
- Owner 2026-10-12: keep "no inlining syntax". After inlinect lands, start a round that AUTOMATICALLY marks failure paths cold (`!` propagation, catch blocks, panics -> Zig @branchHint(.cold)), no syntax. A `cold` marker only if a measured case remains afterwards (spelling = owner). PGO kept in mind for later.
- Owner 2026-10-12: frexp spelled `x.fraction()` + `x.exponent()` (x = fraction * 2^exponent, fraction in [0.5,1), docs mention "C/Python/Go frexp"); NaN/infinity as `Float.nan()` / `Float.inf()`. `error` as any-error type: deferred to the errors-with-data proposal (in progress).
## Owner 2026-10-12: APPROVED as recommended
- Errors with data (.git/revamp/r3/proposal-errors.md), all 18 decisions incl. CORE paragraph; rounds R1->R4 (R2 unblocks `error` type for #151).
- std.unicode now (.git/revamp/r3/proposal-unicode.md), 11 decisions as recommended.
- std.regex after traits (.git/revamp/r3/proposal-regex.md), as recommended — BUT new input: ~/Data/Code/nexis/src/regex.zig (owner's own, 103K, Java syntax, Pike VM, linear, refuses backtracking constructs, docs/REGEX.md) + regex_tables.zig (Java 25 Unicode categories/case maps). Propose to owner: back std.regex by this engine (Zig-backed) instead of a Rig rewrite; Rig API (Regex/Matcher/views) on top. Decide when regex is scheduled.
- Owner 2026-10-12 (RIG-NOTES): note 7 (cold marker) DEFERRED; rely on the inferred cold-paths round.
- Owner: note 2 APPROVED — a module constant (NAME / mod.NAME) of a matchable type is a match pattern, by value; duplicates rejected like literals.
- Owner: note 15 APPROVED — 'x' is a U8 byte literal (ASCII only; escapes like '
' '\' '\''; non-ASCII rejected with a hint to use a rune).
- Owner: note 16 APPROVED — an enum value's name as text is the conversion `Static(e)` (Static(Status.ok) == "ok"); no reserved method name. (Consider revisiting from_int similarly? from_int stays as approved.)
