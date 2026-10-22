# Step 1 carve-out: stopping 1.5 (in-place views), and what that does to 1.6

Branch `r3-step1` at `67f88767`. The base for comparison is `485e1a06` (`rig-485e`).
I ran individual programs only, no suites:

- the round-1 and round-2 review probes, against the base compiler;
- a marker compiler: HEAD with an error at every point where 1.5 makes a unique loop element or a Cell-holding read payload a view or an owned binding. It is built in a scratch copy, at `scratchpad/s3/mark`.

The marker compiler ran `rig check` over all 8,022 programs: every tracked program, every doc example, and every matrix cell. The script is `scratchpad/s3/scan.py` and the results are in `scratchpad/s3/scan.txt`.

## 1. What belongs to the stopped feature, and what stands alone

### Stopped feature: in-place views of loop elements and read-match payloads
These revert.

| Commit | Hunks that belong to 1.5 | Hunks that stand alone |
|---|---|---|
| `8e84548b` View a Cell-holding loop element or read-match payload in place | all of it: typecheck `elementTypeForLoop` (array and slice `?elem`) and `checkVariantPattern` (read payload `?F`); emit `payloadAliases` `viewed` and `\|*payload\|`; the SPEC Cell paragraph on loop and match views; the tests `cell_holder_loop_views.rig` and `cell_holder_payload_views.rig`; the rewrite of `cell_set_on_param.rig` | none |
| `f278584b` Take a made array in a loop header, … | the made-array path. Emit: `owned`, `__rig_src_N`, `for (&src) \|*k\|`. Typecheck: the place-or-lend view test. The deletion of the three `.pattern` Cell patches and of the capture patch, `.pattern` in `requireCellPlace`, and the new `cell_place` text. Tests: `loop_takes_made_array`, `match_takes_made_cell_holder`, `loop_made_element_{copy,escapes,not_view}` | **the temporary-slot fix.** `lendTempArray`, `recordCellTemp` on a temporary array lent as `[]T`, the hoisted `var` slot with `_ = &slot`, and no drop guard for a lent temporary array. It fixes base's crash on `p47e`, and `31d3a6c3` (in-place `s[i]`) needs it. Test: `cell_holder_temp_array_slice.rig`, cut down to its `s[0]` forms |
| `77af6c2b` (M1) | `owns_elem` and `owned_bindings` for a loop element (makes a made array's unique element writable) | everything else: cleanup-only checks, admitting `[N]Random`, the SPEC unique paragraph (it changes in §4) |
| `31d3a6c3` Reach a Cell-holding element in place … | none | **all of it.** `emitIndexBase` indexes a generic array view through the pointer (no `rig.borrowed` copy). `rig.elemPtr` reaches a Cell-holding or generic slice element. A slice step makes a place `indirect`. Requirement `no_cell` on a generic loop element or read payload. These fix base forks (`p38c`, `p47c`), or reject them (`p38`, `p38b`), and do not depend on views |
| `96d45917` (M2) | none | all of it (a pointer view lifted into an optional). Its test `view_lifted_to_optional.rig` drops the lines for loop-element and payload views |
| `c015e49d` | SPEC: the loop/match view sentences. INTERNALS: the Cell clause in the match-capture sentence | the L1 requirement rename `no_move`, the L6 messages, CORE §9 status, the no-op drop note, the `cell` and `unique` matrix rows and the `for_literal` context, `move_unique_element.rig` (rewrite it with a declared `unique` struct, see §2), the `while_step` expectation. The by-value parameter text in SPEC is rewritten in §4 |
| `361889f4` | none | all of it (oracle list: `Random` copies, the fixed element copies) |
| `b7ca0e90` (1.8) | INTERNALS "Type facts": `isUnique` "or a `Cell`" (only if 1.6 goes, §2) | the rest |

### 1.6 (`2cab5408`)
1.6 is not part of 1.5, but in §2 I conclude it cannot stand without it.

## 2. Without 1.5, what 1.6 does to loop elements and read payloads

Without 1.5, the base rules return:

- a read loop over an array or slice binds each element by copy (`for (a) |k|`);
- a read match binds each payload by copy (`|p| const c = p.c`);
- the ownership checker treats the payload as an alias of the scrutinee.

With 1.6, a Cell holder is unique, so each of these bindings is a **copy of a unique value**. Neither checker sees it as one: a loop binding and a payload binding are not bare uses. That leaves two choices.

**(a) Leave them as copies, with base's `.pattern` patches restored.**
- Changes through the copy are rejected (`k.hit()`, `?k`, `|?k|`, `Cell.set`).
- But reads of a stale copy remain. For example, `for k in a: a[0].hits.set(9); print(k.hits.get())` prints `0` where the meaning is `9`. This is probe n08 from the step-1 audit. The same holds for a payload whose scrutinee's Cell changes through another path.
- That is a **silent fork**. CORE §1 "a type that holds a Cell is unique" cannot be marked built.

**(b) Reject them.** "A loop or read match would copy a unique element or payload; loop with `!a` or `<a`, or match with `!e` or `<e`."
- Sound, but it rejects **correct read-only programs** that base accepts. In the scan, the tracked base-accepted programs with such a binding are:
  - `test/corpus/review-place-b5-t023_match_write_cell_set.rig`, from `match ?s .a(c) => print(c.get())`;
  - `test/corpus/review-place-b8-w004_matchwrite_cell_borrow.rig`, from `match ?e .a(p) => print(p.c.get())`;
  - step 1's own new test `loop_made_element_copy.rig`.
- The class is larger than the count: every read-only loop or match over a Cell holder. Through a `?` lend it would have no working spelling at all, since `!` needs write access.
- That breaks "no correct program newly rejected beyond the planned rule's explicit copies".

The scan's other 37 marked programs are step 1's own new tests and matrix cells, which base rejected anyway, or the corpus probes that 1.5 turned from rejected into accepted (w001, w002, w005, w006, w009, w010, q036, p32, p-forms). Doc examples: none.

**Conclusion: 1.6 is not acceptable on its own. Defer it to step 3 with 1.5.**
- Step 3 builds "reads in place" for every type, which is the redesign 1.5 needs.
- Cell ⇒ unique belongs with it, so that every place a Cell holder is bound is a view or a take, decided by step 2's `handsOver`.

**Declared `unique` (Random) after the carve-out.** 1.4 and M1 stay, so `[N]Random` is admitted, and there is one new risk.
- A read loop over a held `[N]Random` binds a copy of a unique value.
- The copy is immutable and the array is held read for the loop, so a read is not observable.
- But `<r` would move a duplicate out, and step 1 promises that a unique value is never copied.
- Rule: **a loop that reads (bare or `?`) an array or slice whose elements are unique is rejected; write it as `for r in !a`, or take the array with `<a`.** In a generic body, a loop element also requires `no_move`. `no_cell` stays.
- Base rejected `[N]Rng` outright, so no base-accepted program is newly rejected. The new rejections are q06's and q55's read loops (both new forms), and `random_array.rig`'s read loop, which is rewritten.
- A read-match payload of a declared-unique type keeps base's owner model: an alias that cannot be written or moved. That is base's treatment of owners, and Random has no interior mutability, so the copy is unobservable.

## 3. Is the carve-out state free of the round-1 and round-2 findings?

Yes, if the plan in §4 is followed. Every hole is in a form that base rejected, and the carve-out returns those rejections; the independent fixes stay. These are the expected verdicts after the carve-out ("base" is `rig-485e` with `Random` renamed back to `Rng`).

### Round 1
| Probe | Base | After the carve-out |
|---|---|---|
| p17e, p17f, p17h, p17i, p42, p42c (literal or made loop, `k.hit()` / `set`) | rejected (`.pattern` patch / `cell_place`) | rejected, the same |
| p17g (match on a made value, `c.hit()`) | rejected | rejected |
| p32b, p32d (`saved = k`) | type mismatch | type mismatch |
| p47 (literal → `[]Counter`, callee loops `k.hit()`) | rejected | rejected (patch) |
| p47e (`look([lit])`, `bumpc(?s[0])`) | **Bus error** | runs, `1` (slot fix kept) |
| p47c (`s[0].hit()` on a slice) | `0` (fork) | `2` (`elemPtr` kept) |
| p38c (`f(?xs[0])` generic) | `0` (fork) | `1` (index through pointer kept) |
| p38, p38b (generic loop or payload copy of `Counter`) | `0 0`, `1 …0` (fork) | rejected (`no_cell` kept) |
| p33c, p34b, p34c (loop or payload element into `(?C)?`) | type mismatch | type mismatch |
| p34, p34d (named view into `(?C)?`) | Zig compile error | runs (M2 kept) |
| p46, p49, p35 | rejected | rejected |

### Round 2
| Probe | Base | After the carve-out |
|---|---|---|
| **q09, q14, q16, q17** (R2-C1: match on part of a made value) | rejected (patch / `cell_place`) | rejected |
| **q90, q91, q92** (R2-C2: payload escapes) | type mismatch | type mismatch |
| **q50, q52, q53, q54, q56** (R2-H1: `for` over a branch, `catch`, `??`, parentheses, `o?` with `k.hit()`) | rejected (patch) | rejected |
| q55 (branch over `[2]Random`) | arrays rejected | rejected (the unique-element loop rule in §2) |
| q06 (made and held `[2]Random`: read loops, `!a` loop, swap) | arrays rejected | the read loops are rejected; `!a`, `swap` and `!a[0].next()` alone would run |
| q07, q08, q95 | rejected | rejected (copy-outs, branch lend, write of made) |
| q70, q71 (slices of Random) | slices rejected | q70's copies are rejected; q71's `![]Random` writes run |
| q01–q05, q60, q61, q80 (made-loop forms) | rejected (patch); q05 "use of `k` after move" | rejected |
| q10, q12, q13, q94 | rejected (patch) | rejected |
| q11, q15, q20 | run | run |
| q30, q31 | type mismatch (loop element `Counter`) | rejected; their named-view lifts alone run (M2) |
| q32 | Zig error | runs (M2) |
| q34 (R2-M1: `((?P)?)?`) | Zig error | runs **once the fix in §4 step 4 lands** (unwrap every optional level) |
| q33, q41, q57, q93 | rejected | rejected, the same |
| q40 (Random hint) | — | the hint fires |

R2-M2 (by-value Cell parameters, and literal slices against `?[literal]`) is not a soundness hole. After the carve-out it is base's rule again: a by-value parameter holding a Cell is the callee's copy. The SPEC text in §4 states it as one rule, and 1.7, step 3, replaces it. R2-L1 is fixed in §4 step 4.

## 4. The plan, commit by commit

Each commit reverts by hunk, keeps the tree building, and is checked with `test/equiv.py` against the previous commit's binary. The full gates run at the end.

1. **"Bind loop elements and read payloads by copy again" (revert 1.5).**
   - Revert all of `8e84548b`.
   - From `f278584b`, revert the made-array emit, the place-or-lend view test, the patch deletions, the `.pattern` in `requireCellPlace`, the `cell_place` text, and the five tests listed in §1.
   - From `77af6c2b`, revert `owns_elem` and `owned_bindings`.
   - From `c015e49d`, revert the SPEC and INTERNALS view sentences.
   - Keep the temporary slot (`lendTempArray`, the hoisted `var`), and cut `cell_holder_temp_array_slice.rig` down to its `s[0]` forms.
   - Expected equivalence: back to base verdicts for the 1.5-only programs (w001…q036 rejected again, emit for t023/w004 back to copies) and the removed tests.
2. **"Defer Cell ⇒ unique to step 3" (revert 1.6, `2cab5408`).**
   - `isUnique` = declared only; restore `mutable_copy`.
   - Restore the seven programs rewritten with `<` and `cell_set_through_read_borrow.rig`.
   - Remove `cell_holder_copies`, `cell_holder_no_clone` and `cell_holder_generic_copy`. They return in step 3, and git keeps them.
   - Keep `cell_holder_moves.rig` (moving a Counter still works).
   - Rewrite `move_unique_element.rig` and the sema unit test with a declared `unique` struct.
   - Remove the matrix `cell` row only if its cells disagree; they should simply be rejected or run.
   - Keep `readByAddress`, which is the M1 predicate.
3. **"Reject a read loop over unique elements".** This is §2's rule for declared unique types: an error in `elementTypeForLoop` for arrays and slices, plus `no_move` on generic loop elements. Tests:
   - `random_array.rig`, read loops replaced by `!a` and `<a`;
   - a new `test/reject/std/random_read_loop.rig` covering q55, q06's read loops, `for r in ?a`, and a slice;
   - q50, q52, q53, q56 and q09, q14, q16, q90, q91 as reject tests in `test/reject/ownership/` (the class guards the review asked for);
   - a `match_subject` context over `H(...).e` and array-typed `for` contexts (`ternary`, `nullish`, `catch`, `optional`) in `test/matrix.py`.
4. **"Lift a pointer view through every optional level, and document stdNameHint" (R2-M1, R2-L1).**
   - `emitBareAs` unwraps optionals repeatedly; add q34 to `view_lifted_to_optional.rig`.
   - Move `stdNameHint`'s doc comment off `notPublic`'s.
5. Rename (`9ed096c9`) and the oracle list (`361889f4`) stay as they are, re-based over 1–4 if the reverts touch their lines.

### What the docs must then say
- **CORE §1:**
  - bullet 1 (`struct Random unique`) stays *(built)*;
  - bullet 2 ("a type that holds a `Cell` … is unique") goes back to *(planned)*;
  - the example at ~L106 goes back to ` ```rig pending ` with its `use \`<c\`` error.
- **CORE sentence 2:** "*(built* for plain data, handles, closures, `Text`, and `unique` types" stays true; "unique" now means declared types only.
- **CORE §9:** the type-facts bullet stays *(built)*.
- **SPEC "Copy values":**
  - restore "… and `Cell`s that hold only Copy values";
  - the unique paragraph covers only a struct declared `unique` (and what holds one inline): it moves, has no clone and no `==`, and nothing copies it out. An array may hold it, but a loop over its elements must write (`!a`) or take (`<a`), since a read loop copies each element. The paragraph must not mention Cell.
- **SPEC §10 Cell:** restore base's rule as one statement, true of the code: "a by-value parameter and a loop or match binding hold a copy of a Cell-holding value; a change through the copy (a `?self` method, a lend, `set`, `replace`) is rejected, since it would not reach the original." Note that step 3 makes them views or owners. Check the `?self`-on-a-parameter case against `p46` and `p33` before writing: base accepts `c.hit()` on a by-value parameter (corpus `p33`), so the sentence must say exactly which forms are rejected.
- **INTERNALS:** `isUnique` is declared only, the match-capture sentence returns to copies, and the type-facts table changes to match.

### What step 3 inherits
- The redesign: one classification of loop and match subjects (step 2's `handsOver`: place, lend, made, branch), then reads in place for every type.
- Cell ⇒ unique, with its seven rewrites and three reject tests.
- `requireCellPlace` for parameters (1.7).
- The round-2 probes as the acceptance set.
