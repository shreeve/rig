# Step 2 panel: one rule for `!` through a handle (2026-11-15)

The owner approved, in his own words "Yes, all three", a three-step cleanup
of how `!` lends through a handle. Step 1 is merged (#1095): a select arm
or a change through any read view, read-only slices included, is rejected,
and a channel or actor made in a generic holds no view. This panel judges
step 2, the single rule, before any compiler change. The owner chose
"Panel only": a written soundness argument, no Lean proof. He sees this
design and your verdict first.

## The rule as drafted
> `!` on a call through a handle needs a handle you hold, never a read
> view. It lends the handle's place to read for as long as the call, its
> task, or the select uses it, never a write view of the shared value.

## Read first
- `inventory.md`: every handle kind and `!` call, what the compiler and the
  reference checker lend today, and what the rule would lend; 84 probes;
  where each lend is decided (`sema.changesByMark`, `isActorCall`,
  `selectArmOf`, `requireAccess`, the oracle's `handleSlot`).
- `soundness.md` and `clarity.md`: the first panel, on an earlier draft
  that was wrong ("lends nothing").
- `select-read-view.md`: step 1.
- docs/CORE.md §2 (sentences 4, 6, 8, 9), §4's lend table, and §10; SPEC
  "Shared handles", "Cell", "Actors", "Channels", "Generic bodies".
- std/ for Cell, Signal, Chan, shared.Map and every type holding a Cell.

## What changes (from the inventory)
A write lend becomes a read lend for every marked call through a `*Cell`
(also a Cell of a List), `*Signal`, `*Chan`, or a `*T` whose `T` holds a
Cell (std.shared's `*Map` among them), and for a `!*Cell` parameter. A
task of a Cell-holding object, `(!h).bump()&`, keeps the read loan for
the task's life. Actors, select arms, `*Frozen`, plain `*T`, `*{A}`, `~T`,
and `Tasks`/`Task` are unchanged. Newly accepted, for example:
`!c.add((!c).swap(4))`, `!ch.send((!ch.recv()! ?? 0) + 5)!`, and a view
`r = ?c` kept across `!c.set(5)`.

## Open points the inventory raised
1. `shared.Map.ensure` returns `?V from @`, a view into a Cell-holding
   object. So the premise cannot be "a shared home gives out no views".
   Is "every view it gives out stays valid while any handle to it lives"
   the true premise, and does every std type satisfy it? Cell's
   `List`, `swap`, `compare_swap`, Signal?
2. Tasks: an actor's `!a.add(1)&` keeps no loan of the handle today (the
   actor counts itself), while a Cell-holding object's task needs the loan
   for its whole life. Does the rule's "for as long as ... uses it"
   capture both, and how should CORE say it?
3. Calls through a write view rather than a handle (`c: !Cell[Int]`,
   `(!@).m()` inside a method) would still lend to write, unlike the
   handle case. Should the rule follow the method's self ("a change that
   touches only a shared value lends to read") rather than "through a
   handle"?
4. One classifier: today "read" is an exception list over a general write
   path, coded in typecheck, ownership, and the oracle separately. What
   one fact should replace it, and where is it decided?

## Rules for the panel
Read-only; write only your report. Rig vocabulary: lend, view, loan
(never "borrow"); "object" (never "struct"); "self" (never "receiver");
tasks (never threads). Timeless prose. At most 400 words. Use the
worktree's bin/rig and bin/rig-oracle (main fa01646fc) for any probe,
with RIG_OUT_DIR set to a temp dir under your scratch folder. A program
the rule would accept but the compiler rejects today can often be tested
by the same aliasing through a second handle (`h2 = +h`), which is
accepted today; run such programs under RIG_SANITIZE=1.
