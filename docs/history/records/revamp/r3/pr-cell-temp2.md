# Keep a temporary holding a Cell in its statement's slot, reached by one leaf walk

## What changes

A temporary may be lent to read or to write; it lives until its
statement ends, and any change made through the view, a Cell's
included, lands in it and is dropped with it. So these forms, rejected
before, now work:

```rig
bump(?made(1))                 # was: "cannot lend a temporary that holds a Cell"
made(5).hit()                  # was: "cannot call `hit` on a temporary that holds a Cell"
made(7).hits.set(4)            # was: "`Cell.set` needs a Cell that has a place"
made().lines.push(1)           # and replace, pop, clear, `c[i] = e`
fresh().set(4)                 # a Cell that is itself a temporary
(a if k else made()).hit()     # changes `a`, or the temporary made there
(w if k else mk(5)).t.score()  # was rejected even when the method only reads
(o if k else mko(5))?.hit()    # a branching optional, unwrapped
```

The change is seen by a view the call returns within the statement, and
by the temporary's `drop` when the statement ends. In a generic body the
same holds at an instance that holds a Cell (the old "the generic body
calls `run` on a temporary" instance error is gone).

Still rejected: `?(a if c else made())`, a branching value with a name's
leaf (or a part of a temporary) lent as a whole, which would copy a
unique value (lend each branch: `?a if c else ?made()`); a view of the
temporary kept past its statement; and `<` on a Cell member's receiver,
`(<c).push(1)`, which follows the read-receiver rule `(<c).set(1)`
already did.

## Design: one leaf walk

Which made values a change through an interior-mutable view can land
in, and so need a slot, is decided once, in `storage.zig`:

- `storage.leafStep(ctx, e)` is the one classification of how the
  address of a value reached where its leaves are is found: an `if`, a
  `??`/`catch` fallback, an `e?`/`e!` unwrap, a place, a part of a made
  value, a lend, a made value, or a jump. Inside a value that branches
  beside a name's, every branching form is walked to its parts
  (`sema.valueParts`), the leaves `sema.valueLeaves` gives a read.
- `storage.madeLeaves(ctx, e)` follows those steps and returns the made
  values reached: a value that branches at each leaf, any other value
  (an all-made branch included) whole, a part through the value it is a
  part of.
- **Typecheck records** the slot (`dropsTemp`) on each of them
  (`keepReached`), at every change site whose place starts at a
  temporary (`keepsCellChange`: a `?self` method on an interior-mutable
  receiver, `set`/`replace`, a `Cell[Vec]`'s `push`/`pop`/`clear`,
  `c[i] = e`), and wherever a value that branches and holds a Cell is
  read by address (`readInPlace`: the object of a field, element, or
  method, `storage.reachesLeaf`, the predicate emit uses). A read lend
  already slots its temporary (`lendTemp`).
- **Emit reads them:** `emitLeafPtr`, `emitPayloadHolder`, and the
  storage planner switch on the same `leafStep`; a made leaf is reached
  in its slot. The backstop stays: a made value whose type holds a Cell
  that no slot keeps is an internal error (`refuseHeldCell`), in the
  leaf walk, the payload capture, and now on a Cell member's path
  (`emitCellAddress`).

- **A literal leaf** (`none`, the one an optional branch may have) has
  its own step, `LeafStep.literal`: no slot keeps it and it holds no
  Cell, so `keepReached` and emit consume the step with no filter of
  their own. Emit reaches a `none` leaf as `rig.noneAt(T?)`, the address
  of an absent optional whose payload no branch captures (it is never
  written). A `none` branch read by value is typed `@as(T?, null)`.
- **No second walk:** `emitAddressOf` sends a value `reachesLeaf`
  reaches to `emitLeafPtr`, so a Cell member on a bare Cell that
  branches is addressed at its leaf, not through Zig's address of the
  branching expression.
- **Where a statement's temporaries live** is one decision,
  `sema.stmtTemps`: every part of the statement, a branch, a `??`
  fallback, a `catch` handler's value and a `match` arm's included, but
  not a block or closure, a header, or a `while` step. Emit declares a
  slot for each where the statement starts (`emitTempSlots`), and the
  ownership checker holds each in a hidden var for the statement: one a
  handler or arm makes, in a var made before the scope it opens for its
  names (`holdPartTemps`). Before this, `walkCatch` scoped them to the
  handler, while emit kept them for the statement.
- **A jump ends a statement's loans:** a path that leaves a statement
  (`continue`, `break`) no longer carries the loans the statement took
  for its own end (`temps`) to where it jumps (`exitTo`).

The desugaring (docs/INTERNALS.md, Sema, temporaries): `mk().c.set(v)`
is `_t = mk()`, `Cell.set(?_t.c, v)`, `-_t`; `(a if k else mk()).hit()`
is the per-branch lend `N.hit(?a if k else ?mk())`.

This removes the two mismatches round 2 found. Typecheck slotted
`valueLeaves`'s leaves while emit stopped at a nested all-made branch,
`mkf()!`, `mko()?`, and the payload holder; now emit descends exactly as
the walk does (H1). And `storage.constLeaf`'s rejection (review-cell-mut
L1) is gone: the made leaf gets a slot instead.

## Fixed

- **H1 class** (`b01`, `b02`, `b05`–`b08`): every accepted form reaches
  its leaves where the slot facts say; no internal error.
- **M1** (`b03`, `l01`): a `Cell[Vec]` member reads its receiver like
  every method (`readInPlace`), so a named leaf's use is recorded and a
  temporary receiver of `get(i)` is dropped (the leak on main).
- **M2** (`b04`): `poke(!((<a) if k else M))`. A kept value under a
  write lend was emitted in the pointer-tail context, so `<a`'s name was
  emitted as a tail with no recorded use; `rig.keep`'s value is now
  emitted as a value.
- `(d if k else (mkd(5) if j else mkd(8))).hit()` and the other
  nested-branch forms that lost a change into a copy on main.
- **Review cell-temp2, round 1:**
  - H1: a `none` leaf reached the backstop, `(o if k else none)?.hit()`
    (57 grid programs), and `(b if j else (mko(5) if k else none)?).c.get()`
    regressed from main. Fixed by `LeafStep.literal`.
  - L1: `none` leaves gave Zig compile errors, 16 grid programs, 5 of
    them accepted by main too. Fixed by typing a branch's `none`.
  - H2: the ownership checker panicked (index out of bounds in
    `mayOwnView`, 37 grid programs, and 3 on main) on a handler-made
    leaf under a view-returning `?self` method. M1: read forms main ran
    were rejected (`print((a if k else (mkf(-1) catch mk(5))).c.get())`,
    27 programs; round 2's Low 1). Both fixed by `sema.stmtTemps` and
    `holdPartTemps`. A stale loan root is now an internal-error
    diagnostic in `carryLoan`, never an out-of-bounds read, and the
    stmt-temp lookups check that the var is still the temporary's.
    `zig build -Doptimize=ReleaseSafe`: the grids and test/ check with
    0 panics and the same verdicts as Debug.
  - L3: `(a if k else mk(10)).hitn(maybe(i - 1) ?? continue)` in a loop
    was rejected ("use of `a` while a write loan is live"). Fixed by
    the jump rule. The reviewer's `# expect:` for p17/p18 were wrong;
    the corpus copies hold the hand-checked output.
- **Review cell-temp2, round 2, H1:** a Cell member on a bare `Cell[T]?`
  branch with a `none` leaf, `((none if k else o) ?? mkww(5).t).set(77)`
  (11 grid programs), was a Zig compile error at e5111234. Fixed by the
  `emitAddressOf` rule; the commit lists every address site checked.

## Tests

New behavior tests (all `# release`): `cell_temporary_lent`,
`cell_temporary_lent_uses`, `cell_temporary_set`,
`cell_branch_made_leaf` (ported from the first attempt),
`cell_branch_leaf_forms` (H1's shapes with `drop` and a bare
`Cell[Vec]`), `cell_temporary_forms` (catch naming its error, headers,
returned views, `defer`, closures), `cell_method_part_of_made_leaf` and
`generic_cell_method_temporary` (formerly rejects), `cell_vec_temporary_read`
(l01), `ownership/write_lend_branch_moved_leaf` (b04).

New rejects: `cell_temporary_lent_named_leaf`, `cell_temporary_view_kept`.
Updated: `cell_moved_receiver`. Removed: `cell_set_on_param` (its forms
are accepted, in `cell_temporary_set`).

Round 3 adds `ownership/catch_handler_temporary_read` (handler
temporaries read, viewed through `me()`, in a `while` header, under a
named handler: the c01–c04 shapes) and `types/cell_bare_branch_none_leaf`
(bare-Cell branches with `none` leaves in a loop), both `# release`. The
oracle's allowlisted `review-copies-2-q05g` difference is gone (the
compiler now agrees: the handler's temporary lives for the statement)
and is removed from `test/oracle/differences`.

Corpus: the 57 round-1 probes (`review-cell-temp-*`), the 26 round-2
probes (`review-cell-temp-2-*`), and the 27 hand probes of this
branch's first review (`review-cell-temp2-*`), each with the oracle's
verdict on every function it decides.

The oracle: the first attempt's fix (a `??` fallback or `catch`
handler is no statement of its own) is ported, which removes its false
C5 on `(opt(?b) ?? ?mkt(0)).n`, already present on main (x01–x05).

Matrix: a `celltemp.<type>.<shape>` family, 103 programs (7 types × 15
shapes): every operation that applies, in a statement, an argument, a
loop, an `if` and a `while` condition, each leaf taken, in debug and
`--release`, against a model's trace. Every program must be accepted.

## Verification

Final head: a1742b34 (7fb643b4 plus the merge of main 70fe1d2e,
which brings only docs/ROADMAP.md).

**Grids**, debug (`RIG_SANITIZE=1`) and `--release`:

| Grid | Checked | Accepted | Run |
|---|---|---|---|
| review-cell-temp-2 (22,890 programs) | rechecked at e5111234: same verdict for all 22,890 as before, 0 rejected that main accepts, 0 oracle differences, ReleaseSafe compiler agrees | 14,787 | 3,092 combined programs: 3,092/3,092 on the Mac and on pup at 9f1161f4; emit unchanged for them since (checked byte for byte at 9f1161f4) |
| review-cell-temp2 grid 1 (8,000) | at e5111234 | 5,122 (0 rejected that main accepts, 0 oracle differences, ReleaseSafe agrees) | 208 combined programs at 7fb643b4: **208/208** on the Mac |
| review-cell-temp2 grid 2 (8,000) | at e5111234 | 5,038 (same) | at e5111234: 11 Zig errors (above), each **ok** at 7fb643b4; the reviewer's own run at 7fb643b4: all exact |

The second review ran both of its grids at 7fb643b4 independently:
10,160 accepted programs exact in debug and release, 0 checker panics
(Debug and ReleaseSafe), 0 backstop hits, 0 oracle differences.

**Gates on pup** (`pup-gates.sh`, PUP_CORES=12, at a1742b34):

- suite: 2,841 passed, 4 pending (oracle, doc, vocab, style, classify
  included)
- corpus: 7,040 passed
- matrix: 5,333 programs, 2,607 ran clean, 2,726 rejected, 0 failed
  (the `celltemp.` family's 103 included, debug and release)
- `zig build test` (fresh cache): 127/129, 2 skipped (the aarch64-only
  tests)
- `oracle doc vocab`: 339 passed, 4 pending

## Equivalence against main 70fe1d2e

`test/equiv.py` on pup, main 70fe1d2e against a1742b34: 9,437 programs,
4,489 differ.

- **pkg only (4,177):** the runtime gained `rig.noneAt`, so every
  program's package hash changes.
- **emit (165, 3 of them new files):** 298 of the 306 changed lines type
  a branch's `none` as `@as(?T, null)`; the rest are a `none` leaf
  reached as `rig.noneAt(T?)` and the slot-kept branching value reached
  in its slot (below).
- **sema / storage / emit (21):** the 19 listed below, plus two new
  corpus probes.
- **check / facts (124):** 96 are files this branch adds or renames; the
  other 28 are the 23 listed below and 5 with the same verdict and
  other diagnostics: the SPEC example's moved line,
  `review-copies-2-q05f`, `q05i` and `receiver_view_of_temporary_leaves_tail`
  (a handler's or arm's temporary is now reported at its statement's
  end: a note added, another temporary named, or an order changed), and
  `review-copies-2-q05g`, rejected before and accepted now (its
  allowlisted oracle difference is gone: the handler's temporary lives
  for the statement, as emit keeps it).

Earlier equivalence against main 5db36f06 (128 differ; the Mac and pup
agree), whose non-new items are still these:

**Rejected before, accepted now** (each the intended rule):
`r3-review2-q94` and `review-step1-round2-q94` (literal temporaries lent
to read), `review-place-b10-y009_ptemp` (`show(?mk())`),
`review-place-b8-w007_temp_cell_view` (`mk().hit()`, `bump(?mk())`),
`review-place-b11-z3` (`(<p).c.push(1)`), `review-cell-mut-r02`, `r04`,
`r04a` (generic temporaries and branch parts: the old `.cell_place`
instance error), `review-cell-mut-r07` (read-only `?self` on a branch
part, review-cell-mut L1).

**Accepted before, rejected now** (one, intended):
`review-place-b11-z5`, `(<c).push(1)` on a loop binding: `push` follows
the read-receiver rule `(<c).set(…)` already followed.

**Rejected before and after, other diagnostics:** `p-cell_move`, `p39`
×2, `q08` ×2 (later lines only), `p42b` ×2 (now the header-copy rule),
`r3-kinds-n18` and `review-cell-mut-r01` (now the named-leaf lend rule),
`review-place-b11-z1`, `z2`, `z4`, and `cell_moved_receiver` (the
read-receiver rule).

**Accepted before and after, emitted Zig differs:**
- A Cell-holding part of a temporary used as a `?self` receiver is
  reached in the slot that keeps its base, not copied into the call's
  block: `cell_in_literal_field`, `cell_in_temporary_field`,
  `call_held_receiver_values`, `cell_part_receiver_view_in_statement`,
  `cell_view_param`, `kept_temporary_receiver_in_place`, q11 ×2, q15 ×2,
  y001.
- A generic temporary receiver whose type `depends` is kept in a slot:
  `generic_temporary_receiver`, `generic_cell_method_part_of_temp`,
  `review-cell-mut-r04b`, `r04c`.
- A slot-kept branching value is reached in its slot, not through an
  `@as(T, …)` copy of it: `receiver_by_what_it_hands_over`,
  `temporary_part_view_in_statement`, `text_friction`,
  `r3-or-branch-part-receiver`, `review-step10-a28`.

All of these run sanitizer-clean in the gates.

## Known follow-ups (not in this PR)

From the second review (`review-cell-temp2-2.md`); none is a soundness
hole:

- **M1: a `match` arm's temporary that views the arm's binding is
  rejected; main accepts it.** Holding an arm's temporaries for the
  statement (where emit declares their slots, before the `switch`) makes
  a temporary such as `mkht(?x)` outlive the arm's binding `x`. Main
  accepted it, with the slot holding `&x` of a prong-local `const` past
  the prong: a dangling view a user `drop` could read (q12), so the
  checker is right about what emit does. The choice is (a) keep an
  arm's temporaries in the arm in both emit and the checker (`stmtTemps`
  stopping at arms), or (b) keep the rejection and align the INTERNALS
  desugaring and the oracle's model. The oracle reports these as
  `stricter`.
- **L1: a `defer` that reads a name a jumping statement lent to write is
  rejected** (pre-existing): `exitTo` runs the jump's defers before it
  ends the statement's loans.
- **L2: on an early leave, made arguments drop before a slot temporary
  made between them** (pre-existing, same on main): SPEC's "last made
  first" holds for slots only.
- `rig.noneAt` returns a mutable pointer to a static that nothing
  writes; a debug assertion, or a `*const` return, would make a future
  write through it loud.
- The oracle still abstains on branching Cell holders.
