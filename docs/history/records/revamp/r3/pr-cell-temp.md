# Lend or change a temporary holding a Cell, in its statement's slot

## What changes

A temporary that holds a `Cell`, or is one, now lives in its statement's
slot like any other lent temporary. Any change to its Cell lands there:

```rig
bump(?made(1))              # was: "cannot lend a temporary that holds a Cell"
made(5).hit()               # was: "cannot call `hit` on a temporary that holds a Cell"
made(7).hits.set(4)         # was: "`Cell.set` needs a Cell that has a place"
made().lines[0] = 4         # likewise; so are replace, push, pop, clear
fresh().set(4)              # a Cell that is itself a temporary
(<a).c.set(10)              # a value moved out is a temporary too
```

The change is seen by a view the call returns within the statement, and
by the temporary's `drop` when the statement ends. This was already true
for `!made()`, `?made().p`, and a generic `f(?mk())`. Now every form
follows the one rule, with no exceptions listed. SPEC §10 states it once.

A value that branches with a leaf a name holds is reached at the leaf
it takes. `(a if c else made()).hit()` changes `a` where it is. When the
branch taken is `made()`, the value it makes lives in its own slot.

### Bugs this fixes

These programs were accepted but ran wrong. The class is a Cell change
written into storage Zig keeps for the expression, which may be
read-only:
- `(a if k else C(c: Cell(2))).c.set(5)`, `(o ?? C(...)).hit()` and
  `(C(...) if k else a).hit()` gave a bus error in a Mac debug build
  and silently wrong output in release (both machines). These forms were
  new on this branch before this round.
- `(w if k else W(inner: C(...))).inner.hit()` crashed on main already.
- `(mkh(1) if c else mkh(2)).d.hit()` and `bump(?(mkh(3) if c else
  mkh(4)).d)` lost the change on main: the change went into a copy, so
  the `drop` saw the old value.

### Still rejected

- `?(a if c else made())`: a branching value with a leaf a name holds,
  or a part of a temporary, lent as a whole. Lending it would copy that
  leaf into the slot. Lend each branch instead: `?a if c else ?made()`.
  This now covers every type that moves (`sema.moves`), `unique` types
  included.
- A view of the temporary kept past its statement: `x = keep(?made())`,
  `K(r: ?made())`.
- `for x in ?arr()` and the other header rules, unchanged.
- `<` on a receiver that a Cell member takes as a read view, as in
  `(<n).set(2)` and now also `(<c).push(1)`. `<` would end the binding
  for a call that only lends it. This is the rule every `?self` method
  already follows.

### Design note on k09

Why are `?(a if c else mk())` and `!(a if c else mk()).bumpw()` still
rejected, when a `?self` receiver on the same branch reaches the leaf
and may change `a`?

A receiver is reached at its leaves, because Zig takes the address of
the leaf. A lend as an argument produces a single `?T` or `!T` value,
which today is the address of one slot holding a copy. Reaching leaves
for argument lends too would mean lending the address of the leaf
taken, with made leaves in slots, as this PR now does for receivers.
That would turn CORE §3's planned item into one rule: "a branching
value is reached at its leaves; its made leaves live in the slot". It
is a change to the lend rule and to `ownership.zig`'s `receiverLeaves`
for arguments. It belongs in its own branch, not in this soundness fix.

Decision: `.git/revamp/r3/rig-questions.md`, "A temporary holding a Cell,
lent to read". The coordinator extended it in later rounds to Cell
members on a temporary's Cell, `c[i] = e` included. CORE is unchanged,
because §3 already says "a temporary may be lent to read or to write".

## How

- `src/typecheck.zig`:
  - `keepsCellChange` decides once where a Cell change through a
    temporary lands. Both Cell sites call it:
    - `requireCellPlace` (`set`, `replace`, `push`, `pop`, `clear`,
      `c[i] = e`)
    - the `?self` receiver check
  - What `keepsCellChange` records:
    - A temporary, or a part of one: `cell_temps` plus `lendTemp`, so
      the slot keeps it (`dropsTemp`).
    - A branching value with a named leaf: `keepMadeLeaves` records each
      made leaf, or the base of a made part, in the slot. It recurses
      into a part of a branching value.
  - `readLeaf`: a made leaf beside a named one, whose type holds a Cell,
    is also kept in the slot when it is only read, since it is reached
    by address and a Cell there may change.
  - `lendsToRead`: the whole-temporary rejection is gone.
  - `lendTemp`: the `namedLeaf` gate is now `sema.moves(ty) == .yes`.
    The message says "a part of a temporary" when the leaf is one.
  - `cellVecCall`: a `<` receiver is rejected as `set`'s is.
  - The `cell_place` message is reworded.
- `src/emit.zig`:
  - `emitLeafPtr` and `emitPayloadHolder` refuse to reach a Cell that
    is not in a slot. That would mean taking the address of a Zig
    temporary, and it is an internal error, never silent.
  - `hoistReceiver` takes how it holds the receiver from
    `ReceiverHold.by`, the rule the storage planner records.
  - `emitAddressOf` adds no `&` to a receiver held by address.
  - `emitMemberBase` reaches a slot-kept branching value in the slot,
    not through an `@as(T, ...)` copy.
- `test/oracle/lower.zig`: a `??` fallback or `catch` handler is no
  statement of its own. Its temporaries are the statement's, as an
  `if` branch's are; only the error a `catch` binds leaves with it. This
  fixes the oracle's false C5 on `(opt(?b) ?? ?mkt(0)).n`, which was
  already there on main. The fix uses no compiler facts.
- `test/matrix.py`: a new `cellleaf.` family, the reviewer's grid. The
  axes are:
  - type: with `drop`, or without
  - made leaf: constant constructor, call, part of either
  - shape: `A if k else M`, `M if k else A`, `o ?? M`
  - operation: `set`, `replace`, `hit`, `me`, each branch lent
  - which leaf is taken

  There are 200 programs, each checked against its exact expected output.
- Docs:
  - SPEC §10 states the rule once and gives the named-leaf receiver
    rule.
  - SPEC §7 is updated.
  - The SPEC example shows a named-leaf receiver with `drop` observing
    the change.
  - INTERNALS gives the desugaring (`mk().c.set(v)` is `_t = mk()`,
    `Cell.set(?_t.c, v)`, `-_t`) and updates the `lendsCellTemp` row.

### Audit of emit's leaf addresses and `@constCast` sites

`emitLeafPtr` has these arms:

| Arm | How it reaches the value |
|---|---|
| `if` | `emitIfYield` with `.leaf_ptr`, which recurses into each branch |
| `??`, `catch` | capture the payload `\|*v\|` of `emitPayloadHolder(left)`: a place's `(&p).*`, or a slot's `rig.keep(...).*`, an lvalue |
| `e!`, `e?` | as `??`; a named leaf is a place |
| `catch` handler with a binding | `emitYieldBlock` with `.leaf_ptr` |
| place, a part of a made value, a lend | `emitAddressOf`: a place, or a slot-kept base through `emitPlace` |
| a made value | the slot when `dropsTemp`; otherwise `&@as(T, e)`, now refused for a Cell-holding type |

`emitPayloadHolder` refuses a Cell-holding made value that is not in a
slot.

The `@constCast` sites all go through `emitCellAddress` →
`emitAddressOf`:

| Site | Use |
|---|---|
| `set` / `replace` | `emitCall` |
| `c[i] = e` | `emitPlaceAssign` → `emitCellPtr` |
| `push`, `pop`, `clear`, `get(i)` | `emitCellPtr` |
| `c[i]` read, `.len` | `emitIndex`, `emitMember` → `emitCellPtr`; read only |

Each writes to a place, a view, a shared handle's value, or a slot.
With `keepsCellChange`, `keepMadeLeaves` and `readLeaf`, a written Cell
is never in a Zig temporary. The two emitter checks above make any
regression an internal error.

## Tests

- `test/behavior/types/cell_branch_made_leaf.rig` is new. It covers no
  `drop` and constant made values, run in debug and in release:
  - `if` either way round
  - `??`
  - `catch`
  - a part of a made value
  - a part of a branching value
  - views returned and used within the statement (k10, with a 16-word
    pad)
  - a bare `Cell`
  - a generic `gen[T]`
- `test/behavior/types/cell_temporary_set.rig` gains `c[i] = e` (also
  with hoisted operands), `(<b).hits.set(17)`, and a `drop` that prints
  the Vec's first element.
- `cell_temporary_lent.rig` and `cell_temporary_lent_uses.rig` are
  unchanged.
- `test/reject/ownership/cell_temporary_lent_named_leaf.rig` adds a part
  of a temporary (with the new message) and a `unique` type.
- `test/reject/types/cell_moved_receiver.rig`: all five `<` receivers
  now give the read-receiver rule.
- `test/reject/ownership/cell_set_on_param.rig` is removed. Nothing it
  rejected is rejected now, and its forms are in `cell_temporary_set`.
- All 57 review probes are kept as
  `test/corpus/review-cell-temp-*.rig`, with the oracle's verdict on
  every function it decides. Three had wrong expected output (k04, b01,
  b02); they are corrected and checked by hand.

## Verification

- **Reviewer's grid** (200 programs): 192 run with the expected output
  and 8 are rejected (the `?o ?? ?M` lend spelling), in debug
  (`RIG_SANITIZE=1`) and in `--release`. Nothing crashes or prints
  wrong output.
- **Every review probe and Cell behavior test**, in debug and in
  release: all as expected. There are no compiler-accepts /
  oracle-rejects differences.
- **Targeted Mac checks**: 970 passed. The full local suite also passed.
- **pup gates**, on 1fb2acba, all green:
  - suite: 2800 passed, 4 pending
  - corpus: 6962 passed
  - matrix: 5299 programs, 2565 ran clean, 2734 rejected, 0 failed
  - unit tests: 124/126 passed, 2 skipped
  - `oracle doc vocab`: 335 passed, 4 pending

## Equivalence

`test/equiv.py` with a build of main at 5e551bc5 (v0.2.5, merged in) as
the old compiler: 9324 programs, 90 differ. 58 of them are new files:
the tests above and the 57 corpus probes.

Rejected before, accepted now (all intended forms):
- `r3-review2-q94` and `review-step1-round2-q94`: a temporary array
  literal, a constructor holding one, and a constructor, each lent to
  read.
- `review-place-b10-y009_ptemp`: `show(?mk())`.
- `review-place-b8-w007_temp_cell_view`: `mk().hit()` and `bump(?mk())`.
- `review-place-b11-z3`: `(<p).c.push(1)`, a moved value as a
  temporary.

Accepted before, rejected now (one, intended):
- `review-place-b11-z5`: `(<c).push(1)` on a loop binding. `push` now
  follows the read-receiver rule that already rejected `(<c).set(…)`.

Rejected before and still rejected, with a different diagnostic: the
`namedLeaf` cases (n18, q08 ×2), the header-copy rule (p42b ×2),
unrelated errors (p39 ×2), and the moved receivers (`p-cell_move`,
`z1`, `z2`, `z4`, `cell_moved_receiver`).

Accepted before and after, with different emitted Zig only:
- A part of a temporary as a receiver of a Cell-changing method is now
  in its slot rather than copied into the call's block. This covers
  `cell_in_literal_field`, `call_held_receiver_values`,
  `cell_in_temporary_field`, q11 ×2, q15 ×2 and y001.
- A slot-kept branching value is reached in place. This covers
  `receiver_by_what_it_hands_over`,
  `temporary_part_view_in_statement`, `text_friction`,
  `r3-or-branch-part-receiver` and a28.

All of these run sanitizer-clean in the gates.
