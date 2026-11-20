# Panel 4 brief: Cell, Signal, channel, actor, under the new words

## Where the owner is

The owner has settled the words for views. They are in `../decisions.md`;
read that first. In short:

- A **place** is a variable, a field, or an element.
- `?v` makes a **read view** of `v`. Until its last use, `v` is
  **read-only**: it may be read, copied, and given read views, but not
  changed, assigned, moved, or dropped.
- `!v` makes a **write view** of `v`. Until its last use, `v` can't be
  used at all, except for a Cell and its kind, which a write view leaves
  only read-only.
- Messages name the act and the view that blocks it: "cannot change `v`
  while a read view of it is still in use", and "cannot use `n` while a
  write view of it is still in use". Notes point at both ends of the
  view: "a read view of `v` is made here" and "still used here".

The one part not yet reviewed is the Cell kind: a `Cell`, `Signal`,
channel, actor, or an object holding a `Cell` (std's `shared.Map`).
CORE says that each changes only through its own calls, lives only
behind `*`, and is never replaced whole. So a write view of one leaves
its handle read-only, and many may be in use at once
(`!c.add((!c).swap(4))` is accepted). The owner asks whether this is
right, natural, and as simple as it can be.

## The questions

1. **One rule or several?** Does every member really behave the same
   under `?x` and `!x`? Check each against the compiler. Note where they
   differ: an actor's call gives the actor a count, not a view, so
   `!a.add(x)&` keeps nothing once made; a select's `!ch.on_recv()`; a
   task that holds self; only a one-word Cell, and objects built from
   them, may cross tasks.
2. **Is "read-only" true for each?** For each member, with a view alive,
   which acts are refused and which are accepted? Is "the handle is
   read-only, and the value changes only through its own calls" true
   for each?
3. **The untyped trap.** `w = !c` with no type makes a write view of the
   handle (`!*Cell`), so `c` can't be used at all, while `!c.set(5)` and
   `w: !Cell[Int] = !c` leave `c` read-only. Is that natural, or should
   the untyped form choose the Cell? What would the change break?
4. **The messages.** Do the new messages read true for each member, on
   the cases the compiler rejects?
5. **Naming the group.** Is a list of members enough, or does the group
   need a name? If it does, name candidates and check each against the
   words Rig already uses (`grep` over docs, std and src).

## Where to look

The worktree is `~/Data/Code/worktrees/rig/loan-vocab/`.

- **CORE:** `docs/CORE.md`, sentence 9 ("Shared storage") and §4's rule
  for a value that changes by a marked call.
- **SPEC:** "Changes and shared storage" (line ~9129), "Shared handles"
  and "Lending a shared value to write" (~9217), "Cell" and "Signal"
  (~10190), and §18 "Tasks", "Actors", "Channels" (~14225).
- **std:** `std/shared.rig`.
- **Tests:** `test/rig/ownership-shared-lend.rig.test` and the tests for
  Cell, Signal, channels, and actors under `test/rig/`.
- **Compiler:** `src/sema.zig` (`changesByMark`, `holdsMarkedValue`),
  `src/typecheck.zig` (`lendsMarked`), `src/ownership.zig`.
- **A compiler** is at `~/Data/Code/rig/bin/rig`, built from `main`.

Scratch programs go in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/panel4/ROLE/`.
Concurrency cases run with `bin/rig test --seeds=20`. Do not edit any file
except your report.

## Your report

Write it to `panel-4/ROLE.md` beside this file, with every program you
ran and its output. Return at most 400 words, verdict first.
