# One decider: emit reads the checkers' decisions, never makes them

Most memory-safety holes found lately were two parts of the compiler deciding
the same thing separately (Cell mutability in sema and the runtime;
typecheck's leaf walk and emit's; loop and assignment order; emit's own
"copy or point?" against the recorded fact; a payload's declared vs
instantiated field type). AGENTS.md states "one classifier per fact", but
nothing enforced it. This round makes it structural for emit, moves the
first class of decisions, and lists the rest with a plan.

Inventory: `.git/revamp/r3/one-decider-inventory.md` (every ownership or
memory decision emit makes, its owning fact or "pending", and the plan).

## Commits

1. **d1ef287d Read sema in emit only through a Facts view.** New
   `src/facts.zig`. `emit.zig` imports `std`, `parser.zig`, `rig.zig`,
   `facts.zig`, `diag.zig` only; `sema.zig`, `storage.zig`, `resolve.zig`
   are unreachable, so a call of `sema.copies` or
   `storage.matchesInPlace` from emit does not compile. `Facts` holds the
   context as `*const anyopaque` and offers:
   - node facts (the facts table and storage facts, read-only);
   - types: the type table, symbols, and per-type answers about how a
     value is held in Zig (view as pointer or copy, `*T` vs `*const T`,
     `rig.ReadView`, what `+x` lowers to), one answer per type;
   - `Facts.syntax`: IR-only helpers that read no fact;
   - `Pending`: the node decisions emit still makes with a classifier the
     checkers also call, or with a per-type predicate combined into its own
     rule. This is the allowlist (27 entries at this commit).

   A unit test (`facts.zig`, "emit reads the checkers' decisions only
   through Facts") fails if emit imports any other compiler file, names the
   opaque context, `@ptrCast`, or `anyopaque`, if `Pending` exceeds its
   budget, or if a `Pending` entry is no longer used (so the list only
   shrinks, and a moved class must delete its entries). A second test checks
   that `Facts` answers as the context it wraps for every node.
   Emitted Zig, every facts dump, and the package hash: byte-identical to
   main across 9,720 programs (`test/equiv.py`).

2. **5ed43d2b Record the leaf walk once and name Zig's temporaries as
   storage.** The mechanism for "decided once":
   - `sema.Question` / `SemContext.decided`: a question about a node is
     answered the first time any pass asks it and recorded; every later ask,
     emit's included, reads the record.
   - `storage.verifyDecisions`, at the end of the storage plan, asks every
     recorded question again from the final facts. An answer that changed
     after it was recorded is an internal error: the "two passes acted on
     different answers" class, now caught mechanically.
   - Emit only reads (`Facts.leafStep`, `Facts.reachesLeaf`); an unrecorded
     answer is an internal error.

   First class moved: **the leaf walk**. `leafStep` and `reachesLeaf` were
   computed separately by typecheck (`madeLeaves`, `readInPlace`), the plan
   (`Planner.leaf`), and emit (`emitLeafPtr`, `emitPayloadHolder`,
   `emitAddressOf`, `emitIndexBase`, `emitMemberBase`). They are now
   decisions. The plan decides `reachesLeaf` for every expression, and walks
   the leaves of a header subject that yields a leaf's address
   (`subjectHeader`), as `emitSubjectPtr` reaches it.

   Two of HANDOFF's four "addresses of Zig rvalues" are now named by a new
   storage fact, **`zig_temp`** (Zig's own temporary, owned, life
   statement):
   - `emitLeafPtr`'s `&@as(T, value)` for a made leaf no slot keeps, and
     `&@as(T, lit)`, plus a made payload holder captured `|*v|`;
   - `&[...]` for a temporary array lent to a call that evaluates its
     arguments where they stand.

   `Emitter.zigTemporary` requires the fact before emit writes any of
   these. `rig check --facts=storage` prints them; test
   `test/cli/facts_storage.sh` checks two. `Pending` goes from 27 to 25.

3. **bf094123 Read an optional a field's view holds through the view
   once.** A bug the inventory found, of exactly this class (an emit-local
   decision re-deriving what another rule had already done):
   - `if h.o as t`, with `h.o` a field (or element, `hs[1].o`) holding a
     read view of an optional, passed `rig check` and emitted
     `if ((h.o.*).*)`, which Zig rejects.
   - emitOptionalHead decided by the subject's shape (`value == .src`)
     whether its value was already dereferenced; the member rule had
     already dereferenced the field.
   - Any view other than a name's is now read through the pointer it is,
     once.
   - Main fails the same program. Test:
     `test/behavior/emit/optional_view_field_as.rig`.

4. **e9b1eca6 Seal recorded decisions after the plan, and tokenize emit's
   imports.** Follow-up to the independent review:
   - A question asked after `verifyDecisions` is answered but not
     recorded. Before this, emit's `Pending.madeLeaves` could record
     `leaf_step` late: one corpus program,
     `review-cell-temp-b03_catch_named`, did. So every record now comes
     from a pass that ran before the ownership checker.
   - Two nodes sharing a decision's key is an internal error, where before
     an assert could never fire.
   - A module with errors skips the check.
   - The import test reads `emit.zig` with `std.zig.Tokenizer`, so
     `@import ("sema.zig")` split over lines is caught (verified by adding
     one), and it bans `@fieldParentPtr`.
   - The docs name the few `Facts` node queries that only combine recorded
     facts.

## Equivalence against main

Checked with `test/equiv.py` over 9,721 programs: tests, examples, std,
corpus, and every doc block. Sections compared: parse, normalize, check,
facts, sema facts, storage facts, emit, and the package hash.

- At HEAD, emit and the package are byte-identical except for
  `optional_view_field_as.rig`, the fixed bug.
- Storage facts gain `zig_temp` lines in 13 programs, additions only.
- An emit sweep of all 8,684 non-reject programs hits no internal error and
  no `verifyDecisions` drift.

So no recorded fact disagreed with emit's old local decision for the leaf
walk. The one disagreement found (bug A) was an emit-local shape rule.

## Found bugs and latent two-classifier sites

- Fixed: bug A, above.
- Not fixed, each listed in the inventory with its class:
  - consuming `for`: emit and the plan use one formula, ownership uses
    `mode` and `taken`;
  - print by address: emit's shape plus `readByAddress` vs ownership's
    `holdRead`;
  - catch-all by address: emit's `catchAllByAddress` vs typecheck's
    `copies != yes` arm-view rule;
  - a match's `held_view` is computed in three passes;
  - `dropsWhenTested` is a drop no checker walks;
  - the hoists recompute the `by` the storage fact records.

  None reproduces as a miscompile today. Each is a step of the plan.

## Not done (plan)

`Pending` has 25 entries; getting to zero is about ten classes of work,
larger than this round's budget. Order (inventory section 10):

1. **V** — a recorded `viewRead` for places holding a view (bug A's class).
2. **A** — the address chokepoint: a `?self` receiver no slot keeps, and
   block yields.
3. **M** — match decisions.
4. **H** — header decisions.
5. **C** — call hoisting, mostly mechanical with `Question`.
6. **O** — assignment and loop order.
7. **P** — print by address.
8. **D** — drop when tested.
9. **B** — binding form per symbol (removes `moves` and
   `assignWritesThrough`).
10. **X** — element access (removes `copies` and `holdsCellByValue`).

## Review

One independent review ran on d1ef287d..bf094123:
- No soundness bug found.
- Emit was byte-identical to main over 9,810 test and example programs
  and 4,442 generated matrix programs, apart from the fixed one.
- `zig_temp`: every site is behind `zigTemporary`, and the plan records
  exactly the matching cases.
- The bf094123 fix holds for fields, elements, nested paths, `(?h).o`,
  `*H` fields, calls, `Vec` elements, branching values, and generic
  fields. All run sanitizer-clean; main fails each at Zig compile.

What it found, all fixed in e9b1eca6:
- emit could record decisions late through `Pending`;
- the import test could be dodged by spacing;
- the record assert was dead;
- the verifier ran on modules with errors;
- docs overclaimed.

Its remaining note: `emitPayloadHolder`'s `.lend` arm (`|*v|` on a lend)
is an rvalue address no fact names, but it is unreachable today, since
view-held drop or unique values are rejected.

## Gate results

- At bf094123 (`GATES_DELTA=1`, Mac under cpuq, -j 5), every gate passed:
  - suite: 2,888 passed, 3 pending;
  - corpus: 7,294 passed;
  - matrix: 5,877 programs, 3,213 ran clean, 2,664 rejected, 0 failed;
  - unit: 131/132 (1 skipped).
- At e9b1eca6 (-j 6, delta), every gate passed with the same counts:
  - suite: 2,888;
  - corpus: 7,294;
  - matrix: 5,877 programs, 0 failed;
  - unit: 131/132.
- Also an emit sweep of 8,684 programs with 0 internal errors, and the
  lints passing.
