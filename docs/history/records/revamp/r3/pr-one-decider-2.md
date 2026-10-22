# One decider, stage 2: the match, header, call, loop, and print decisions

Stage 1 (#87) made emit read sema only through `Facts`, added recorded
decisions (`sema.Question`, answered once, verified at the end of the
storage plan, sealed), and moved the leaf walk. This stage moves seven
more classes of node decision out of emit and into records that every
pass reads. `Pending`, the allowlist of decisions emit still makes
itself, goes from **25 to 7**.

Base: e9b1eca6, plus origin/main once #87 merged (173b6a6e).

## Commits

Each commit is byte-identical to stage 1 under `test/equiv.py` (9,721
programs: parse, normalize, check, all facts dumps, emit, package hash).
Each also passed an emit sweep of 8,684 programs with no internal error
and no drift in `verifyDecisions`.

1. **52de819d Stop at a payload captured by address from a lend.**
   - `emitPayloadHolder`'s `.lend` arm took an address no fact names.
     Typecheck rejects every lend of an optional or fallible value whose
     payload is read by address (it would hand over a resource or a type
     parameter's value from inside a view).
   - The arm is now an internal error, documented in INTERNALS
     ("Addresses of Zig temporaries"). The sweep confirms nothing reaches
     it.
2. **81b2b96a Decide each match's reach and bindings once, in every pass.**
   - New questions for each `match`: `match_mode`, `matches_in_place`,
     `match_rereads`, `match_block`, `subject_hold`, and `holds_view`.
   - New questions for each binding within its match:
     `catch_all_by_address` and `payload_by_address`. The memo now carries
     a context node (`at`) for questions that depend on the construct.
   - **held_view** was computed in three passes (typecheck's header-copy
     rejection, the ownership checker's returned-view check, and emit).
     All three now read `holds_view`.
   - **Catch-all by address:**
     - typecheck's arm-view and copy-requirement rules used
       `catchAllByAddress(ty, true)` with its own `arm_local`;
     - emit used `catchAllByAddress(ty, in_place)`;
     - typecheck's `readBinding` applied the catch-all rule to payload
       bindings too.

     All now read the per-binding records. Typecheck now records a
     payload binding's field and type before it asks: the old order would
     have recorded an answer from incomplete facts, and `verifyDecisions`
     would have stopped there.
   - The plan decides every binding's answer, guarded arms included. It
     used to skip guarded arms, where emit still asked.
   - Unifying `readBinding` changed no accepted or rejected program
     (equivalence: 0 differ).
   - Unit test: "Facts reads every match decision the plan made".
3. **bf525bae Decide once whether a for loop consumes its source.**
   - Emit and the plan shared one formula; the ownership checker used
     another (`<v`, or an array made there).
   - `for_consumes` is now read by all three. The ownership checker walks
     a consumed source as taken, which is what emit does: it hands the
     elements over.
   - 0 programs differ, so nothing accepted or rejected changed.
4. **dd60d5be Decide once whether print reads an argument by address.**
   - Emit's own shape-and-type rule is now `print_by_address`, decided by
     the plan for every `print`, `Text(...)`, and `add` argument.
   - The ownership checker's `holdRead` is a loan rule over every
     argument read in place. It covers these, so it stays as it is
     (documented).
   - `readByAddress` leaves Pending.
5. **c8ce5ff0 Decide once whether a test against none drops its operand.**
   - `rig.isNone` and `rig.isVariantDiscard`'s drop is now
     `drops_when_tested`, decided for every `==` and `!=` operand.
   - The decision reads the facts as they stand after typecheck. It is
     **not** a value with no cleanup, as stage 1's inventory assumed:
     `w.upgrade() != none` drops a `*P?` there.
   - The suite runs leak-free, so the drop happens once. But the ownership
     checker still models this operand as a temporary read in place, not
     as dropped by the test. That is left for a later round, listed below.
6. **6f7ffc87 Record what each expression hands over and how headers
   reach.**
   - `hands` (`handsOver`'s kind) is decided by the plan for every
     expression, like `reaches_leaf`. Emit's `handsOver` and `hasStorage`
     read it.
   - New `header_points` and `views_optional_value`.
   - `handsOver`, `hasStorage`, `headerPoints`, and `viewsOptionalValue`
     leave Pending.
7. **b8c9c9ec Decide once how a call holds its receiver and arguments.**
   - New questions: `hoists_args`, `receiver_hold`, `consumes_receiver`,
     `argument_hold`, and `pure_arg`.
   - Emit used to ask `argumentHold` about a consumed receiver, a question
     the plan never asked. It now holds that receiver as a value of its
     own, with the same output.
   - Six entries leave Pending, including the unused `keptInSlot`.

## Pending (7 left)

| Entry | Class | Plan |
|---|---|---|
| `actsBeforeStore` | O | `assignForm(set)`, shared by emitPlaceAssign and plan.placeAssign |
| `stepReadsBinding` | O | `loop_step(while)`; the ownership checker asks it too |
| `assignWritesThrough` | B | per-symbol binding form |
| `moves` | B | per-symbol binding form, drop kind |
| `copies` | X | `elemAccess(index)` |
| `holdsCellByValue` | X | `elemAccess(index)` (redundant with `copies` there) |
| `madeLeaves` | A | the address chokepoint; reads recorded leaf steps but walks itself |

## Not done

- **Class V, how a place holding a view is read.** It removes no Pending
  entry. Emit decides it with context flags (`ptr_tail`, `want_ptr`) set
  by callers from the expected type's representation, and with a
  name/field/element shape rule. Making it a recorded fact means
  extending `readsThrough` to places, decided where typecheck adapts the
  view. That rewrites emit's dereference path, roughly ten sites, while
  keeping output byte-identical. It does not fit this budget.

  Started instead with the coordinator's two-classifier list, which all
  shrink Pending. Stage 1's bug A, from this class, is already fixed.
- **Class A beyond `madeLeaves`:** the `?self` receiver no slot keeps,
  and labeled block yields.
- **The ownership side of `drops_when_tested`:** the checker should walk
  the drop where the test makes it.

## Found bugs

None. Every class was byte-identical across the corpus, including
accept/reject. Stage 1's inventory flagged three two-classifier sites as
possible disagreements: catch-all vs arm-view, the consuming `for`, and
print by address. Each has a single classifier now. None of them changed
an outcome, so the two rules agreed on every program in the suite,
corpus, and docs.

## Gates

GATES_DELTA=1, through cpuq (`heavy.sh gates.sh`), at the merge head:
see "Gate results" below.

## Gate results

At 173b6a6e (`-j 5`, `--delta`), every gate passed:
- suite: 2,888 passed, 3 pending;
- corpus: 7,294 passed;
- matrix: 5,877 programs, 3,213 ran clean, 2,664 rejected, 0 failed;
- unit: 132/133 (1 skipped).

Lints pass. The log is the second "gates 173b6a6e" block of
`logs/one-decider-2.sum`, which also holds stage 1's last run.

## Review
One independent review found nothing Critical, High or Medium. `test/equiv.py` against main 53cbff4f, cached and `--no-cache`: 9,721 programs, 0 differ. A mutated emit (an `@import("sema.zig")`, or an 8th `Pending` entry) fails the unit test. Notes for stage 3:
- `Facts` passthroughs that forward to a storage function aren't covered by the budget.
- `emit.zig` still derives its own `holds_view` for a match on a lent call returning a view.
- `rig check` is about 30% slower on the largest program, from recording and re-verifying every answer.
- One sound loosening: a payload bound as a view where the match reads in place no longer gets the generic no-Cell requirement. No program in the tree reaches it.
