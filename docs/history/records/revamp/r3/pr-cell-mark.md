# Mark every change to a shared Cell with a write lend

A shared `Cell` is changed only by a marked call: `!c.set(5)`,
`(!c).replace(v)`, `!c.push(x)`, `(!c).pop()`, `!c.clear()`, and
`(!c)[i] = e`, and a `Signal`'s `set` and `subscribe`. Reading,
`c.get()`, `c.len`, `c[i]`, stays unmarked.

## Decisions to confirm

Exact CORE text (commit "State in Core that ? changes nothing and a shared
Cell changes by a marked call", the only commit that touches the CORE
sentences):

- Sentence 4, after "`?x` lends `x` to read, and `!x` lends it to write,
  as whichever view the context expects (§4)":

  > `?` promises that nothing changes.

  (was: "`?` promises that nothing changes but a `Cell`, which lives
  behind a shared handle (sentence 9).")

- Sentence 8: "Handles only read (a `Cell` inside one changes by a marked
  call: sentence 9)." (was "still changes").

- Sentence 9:

  > **9. Shared storage.** You change what you were lent with `!`, or what
  > you share with `*`. A name's own value changes by assigning it. What
  > you share is a `Cell`, and it changes only by a marked call:
  > `!c.set(5)`. A value that holds a `Cell` lives only behind `*` ...

  (was: "... and it changes through any handle or view of it.")

Two rules follow from the sentences; confirm they are not exceptions:

1. A write view of a value that holds a Cell changes its Cells and
   Signals and nothing else. Such a value lives only behind `*`, and a
   handle's other fields only read (sentence 8), so this is sentence 8,
   not a new rule; `swap` and `replace` refuse such a value whole for
   the same reason.
2. `(!c)[i] = e` is the mark of an element assignment (the grammar has no
   `!c[i] = e`); on a `!Cell[Vec[T]]` binding the assignment is its own
   mark, as for a Vec. The hint is "write `(!c)[i] = e`: changing a
   shared Cell is marked with `!`".

## What `!c` lends, and the loan rules

`!c` lends the handle `c`, as `!v.push(x)` lends `v`. It is not exclusive
over the shared Cell, since another handle is another name. The loan
rules needed no case for it: `!c.set(5)` records a write loan on the
binding `c` and none on the Cell. `test/reject/ownership/cell_mark_lends_the_handle.rig`
shows both halves: a view of `c` held across `!c.set(2)` conflicts; a view
of `d = +c` does not (`test/behavior/runtime/cell_marked_calls.rig`).

How the rule is enforced, in one place: `Cell` and `Signal` members take
`!self` (`resolve.registerBuiltins`), and the lend table lets a `*T` lend
a write view of its `T` when `T` changes by a mark (`sema.changesByMark`,
`sema.lendsAs`). The receiver-sigil rule is the whole enforcement; no
dedicated check. The only added diagnostics are the hint on the existing
"needs its receiver lent to write" error and the element-assignment form.
The typechecker has exemptions so that a lend of a handle is not a write
of what holds it (`lendsHandle`, `lendsMarked`, `lendsPath` in
`typecheck.zig`): a handle is lent, not rebound, so a `const` binding, a
parameter, a capture, a read view, or a slice that holds it may be lent.

## Deleted

- The mutable pointer for a read view of a value holding a Cell
  (`emitViewPtrTy`, `emit` lend rows) and `Facts.holdsCellByValue`: a read
  view is a `*const T` like any other. Proof: the unit test
  `check: ... gone` now also asserts `ownership.zig`, `emit.zig`, and
  `facts.zig` do not mention `holdsCellByValue`; every Cell test runs
  with `*const` views, in debug, sanitized, and `# release`.
- The write-kind loan `ownership.holdBranchLeaf` took on a held read leaf
  that holds a Cell, and the "cannot lend `x` to read, which holds a
  Cell, ..." clause of `conflicts` that reported it. Every program that
  reached it was already rejected by `cellCopiedByBranch`; the suite,
  corpus, and matrix verdicts are unchanged by its removal.
- The "`push` changes a Cell through any path to it; remove the `!`"
  diagnostic: a `!` there is now the required mark. The reject test
  `receiver_sigil_without_receiver` now checks `!log.get(0)` ("`get` only
  reads the Cell").
- Docs: "interior mutability", "through any path", "a read view included"
  for Cells (CORE 4/8/9, SPEC Lending, Changes and shared storage, Cell,
  Signal, INTERNALS Views/Cells, WELCOME, DESIGN).

## Migration

| Before | After |
|---|---|
| `c.set(5)` | `!c.set(5)` |
| `x = c.replace(v)` | `x = (!c).replace(v)` |
| `c.push(x)`, `c.clear()` | `!c.push(x)`, `!c.clear()` |
| `x = c.pop()`, `if c.pop() as x` | `x = (!c).pop()`, `if (!c).pop() as x` |
| `c[i] = e` (Cell of a Vec) | `(!c)[i] = e` |
| `sig.set(v)`, `sig.subscribe(cb)` | `!sig.set(v)`, `!sig.subscribe(cb)` |
| `sub hit(?self)` that sets a Cell; `k.hit()` | `sub hit(!self)`; `!k.hit()` |
| `sub f(c: ?Cell[T])`; `f(c)` | `sub f(c: !Cell[T])`; `f(!c)` |
| `\|+c\| c.set(1)` | `\|+c\| !c.set(1)` |
| `(a if k else b).c.set(1)` | `!(a if k else b).c.set(1)` |
| `match h` / `if h as x` / `for x in v` that sets a Cell in an arm | `match !h` / `if !h as x` / `for x in ?v` with `!x.hit()` on a handle |
| a read view of a Cell (stored, captured, returned) that changes it | no replacement: hold another handle (`+c`) and mark it, or take `!` where a view may stand |
| `print(c, grow(!c))`-style programs that relied on a read view | `d = +c; print(c, grow(!d))` (the same hazard, through another handle) |

`.git/revamp/r3/cell-mark/rewrite.py NEW_RIG OLD_RIG [--md]` redoes the
tree rewrite: the compiler finds each site, the script applies the fix
the diagnostic gives, and a program is checked again until nothing new
is drawn. It is idempotent.

## Tests

New: `test/behavior/runtime/cell_marked_calls.rig`,
`test/behavior/ownership/cell_marked_handle_views.rig`;
`test/reject/runtime/{cell_unmarked_set,signal_unmarked_set,cell_read_view_unchanged,cell_holder_write_view_changes_cells}.rig`,
`test/reject/ownership/{cell_mark_lends_the_handle,cell_holder_whole_value}.rig`; SPEC `rig reject`
examples for each. No behavior test became a reject test; programs
whose point was a change through `?` use another handle or a `!` view.

Soundness found while building this, each fixed with a test (the class
is "a lend of a handle is exempt from the blocks on what holds it"):
`swap`/`replace` of a Cell holder through a handle (wrote plain data
through a shared handle); `!w.h` handing a callee a `!*C` to re-point a
field of a shared value; `(!c)[i] = ?text` skipping the "no view in a
Cell" check (the lend-based target path); an emit miss for a write view of
a handle used as a method receiver (`**RcBox` has no `.value`); a crash in
`match !x` on a call returning `!Box[*E]`.

## Corpus

22 probes that ran clean before were rewritten to keep their point
(another handle, `!` forms). About 180 probes were already rejected for
other reasons and are rejected still, some now by the missing mark; their
remaining `# oracle:` verdicts about functions that changed through `?`
were dropped. Not rewritten: `test/corpus` programs whose point was a
stored `?` view of a holder that changes it.

## Oracle

`test/oracle/lower.zig` lends the handle's slot for a marked call through
a handle (`handleSlot`) and models a `Cell[Vec]` member with the Vec
method's receiver; 8 rejections are listed (`test/oracle/rejections`).

## Review round 1 (head 340406f2)

Class: what `!` on a handle lends. One decider, `handleWritable` in
`typecheck.zig` (`requireAccess` with the handle exemption off, so exactly
the existing "may this place be written" fact): `!c` lends the handle
itself (`!*T`, re-pointable) only where `c` may be written; elsewhere
(`const`, non-`!` parameter, `|+c|` capture, module-level binding, field
of a shared value, slice element) it lends the value the handle holds,
and a callee expecting `!*T` gets "this handle is read-only here; pass
`+c` to share a new handle, or lend the contents". The field-only case
is gone; the general rule covers it. A read view of a handle, or a read
view on the path to one (`?S` holding a handle), is never lent to write
(M1), so CORE 4 stands as written; `+h` gives a handle of your own to
mark. The four H1 programs (p45, p47, p69, p76) are rejected.

All 76 probes are in `test/corpus` (`review-cell-mark-1-*`); nine are
also reject tests (`handle_lend_*`), and
`behavior/ownership/handle_lend_writable.rig` runs the allowed cases.
Tests that changed a Cell through `?` now use `!` headers, `(+x)`, or
Cell-by-value fields (reactive fixtures, `memo_canary`); three generic
`?T` tests read instead of change. Not a bug, noted: a `?self` on a
holder can see its Cell change during a call that lends another handle
(p43).

## Gates (head 340406f2, merged with origin/main after #99)

cpuq, `zig build -j"$CPUQ_CORES"`, Nexus 2.1.0: `./test/run` 3134 passed,
0 failed, 3 pending (existing); `--delta corpus` 9725 passed;
`matrix.py --delta` 0 failed; `zig build test` 137 passed, 1 skipped.
`test/equiv.py` against 78467727 (12259 programs): the only programs both
compilers accept whose Zig differs are `call_held_receiver_values` and
`cell_part_receiver_view_in_statement` (`*Q` -> `*const Q`, the deleted
pointer form); 853 others differ only in `check`/`facts`. The deep gate
is not run.
