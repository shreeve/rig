# Lend doctrine for `!` through a handle: panel brief (2026-11-15)

The owner approved, in his own words "Yes, do it", a docs-only
cleanup: say in CORE and SPEC what `!` lends when a method is called
through a handle, and how long a `task.select` arm holds its channel.
It changes no program and no compiler behavior: the compiler and the
reference checker (`bin/rig-oracle`, as of #1094) already behave as
described.

## The tension
- CORE §4's lend table, row `*T`, `*{A}`, `!x lends` column: "nothing of
  the value (`!h` lends the handle itself)".
- SPEC "Actors" (~line 14036): a `!@` method is called marked,
  `!a.add(x)`, needs a handle you hold (through `?a` it is rejected), and
  "The `!` marks the call, and lends nothing: the actor changes its own
  value." With `&` the task "keeps none of the handle".
- SPEC "Shared handles" (~9258): `!h` lends only the handle itself (a
  `!*T`), never a write view of the value; `!h.push(x)` through a
  `*List[T]` is rejected. SPEC "Cell" (~9535): a handle is lent as
  itself, `!*C`, only where it may be written; elsewhere `!h` lends what
  it holds, a `!C`.
- SPEC "Channels" (~14160-14200): arms `!ch.on_recv()`,
  `!ch.on_send(<v)`, `?t.on_end()`; "The select makes every arm, in
  order, before it waits, so what an arm lends stays lent, and what it
  sends stays taken, until the select returns." It does not say whether
  an arm's `!ch` is a write lend. The compiler accepts two arms on one
  channel (`select(got: !ch.on_recv(), put: !ch.on_send(8))`), and
  rejects `select(got: !chs[0].on_recv(), put: !chs[0].on_send(grow(!chs)))`
  with "cannot lend `chs` to write while a read loan is live", the note
  on the first arm's `chs`.

## Draft wording (to review, not to defend)
1. CORE §4, one line after the table:
   "`!` before a method called through a handle marks the call and
   lends nothing of the value: an actor's `!a.add(x)` is a message,
   and the actor changes its own value (SPEC, "Actors"). `!h` standing
   alone lends the handle itself."
2. SPEC "Channels", after "until the select returns.":
   "An arm's `!ch` holds the channel's place to read until then, so two
   arms may name one channel, and a write to that place while the
   select holds it is rejected."
   With a `rig` example (two arms on one channel, prints `got 7`) and a
   `rig reject` example (the `grow(!chs)` program above).

## Questions
1. Is the CORE line true of every handle kind the row covers (`*T`,
   `*{A}`, `*Actor`, `*Chan`, `*Cell`)? A Cell's `!c.set(x)`, a
   channel's `!ch.send(x)`, and a plain `*T`'s rejected `!h.push(x)`
   must not be misdescribed. If the line should name only actors, or
   say "through an actor's or channel's handle", say which.
2. Does it fit CORE §10 (one paragraph, no exception list, the rule
   follows the type)? Does it contradict sentence 9 ("a change is a
   marked call through a handle you hold")?
3. Is the SPEC sentence exact (a read lend of the channel's place,
   held until the select returns), and would an AI writing Rig guess it
   right? Better wording?
4. Anything else in CORE/SPEC that the change leaves inconsistent.

Rules: docs only; Rig vocabulary (lend, view, loan, never "borrow";
"object", never "struct"; "self", never "receiver"; tasks, never
threads); timeless prose. Read docs/CORE.md §2 sentence 9, §4, §8,
SPEC "Shared handles", "Cell", "Actors", "Channels", and try programs
with `~/Data/Code/worktrees/rig/sched-pair-test/bin/rig check FILE`
(RIG_OUT_DIR set to a temp dir) to confirm any claim.
