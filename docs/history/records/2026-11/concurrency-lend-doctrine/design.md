# One rule for what `!` lends to a shared value: design note (2026-11-15)

The owner approved the three steps ("Yes, all three"). Step 1 is merged
(#1095). This is step 2's design, for his decision before any compiler
change. Behind it: the inventory ([inventory.md](inventory.md), 84 probes),
the first panel ([soundness.md](soundness.md), [clarity.md](clarity.md)),
and the step-2 panel of three ([panel-soundness.md](panel-soundness.md),
[panel-breaker.md](panel-breaker.md), [panel-wording.md](panel-wording.md)).

## The problem
What `!` lends to a shared value depends on its kind today, by exceptions
coded separately in typecheck, ownership, and the reference checker:
- a Cell's, Signal's, channel's, or Cell-holding object's call lends the
  handle's place to write, so `!c.add((!c).swap(4))` is rejected;
- an actor's call and a select arm lend it to read, so
  `(!a).add((!a).add(1))` runs.
Two holes slipped through those exceptions (closed in #1095).

## The rule
> `!x` puts a write loan on `x`, and only a read loan when what it lends
> is a write view of a value that changes by a marked call: a Cell, a
> Signal, a channel, an actor, or a value holding a Cell. `!h` lending
> the handle itself (a `!*T` the callee may point elsewhere), rebinding,
> and dropping still lend to write. A marked call through a read view is
> rejected. The loan lasts as long as the view it carries (CORE
> sentence 6): for the call, for the life of a task that holds self, or
> until a select returns; an actor's call keeps none.

It follows the type of what `!` lends, not where the value came from
(CORE §10). It accepts more programs and rejects none.

## Why it is sound (panel: SOUND WITH CONDITIONS)
Premise: such a value is never replaced whole, and every view it gives
out lasts while any handle to it lives. Every std type meets it: Cell,
Cell of a List, Signal, Chan, and `shared.Map`, whose `ensure` views
entries it never moves or frees before the map drops. So a write loan of
the place guards nothing a second handle (`h2 = +h`) does not already
open today. Each such program runs clean under `RIG_SANITIZE=1`, including
an `ensure` view held across 50,000 puts.

Breaker: NOT BROKEN, 17 attacks. Each was also run in a form legal today,
through a second handle, task, or actor, under the sanitizer, and the
task ones with seeds 1 to 20.

## Conditions
1. A std type that changes by a marked call must meet the premise by its
   declaration. CORE states the premise.
2. The loan begins before the call's arguments are evaluated, and lasts
   per sentence 6.
3. An erased `{A}`, or a type parameter, counts as not changing by mark
   for the loan: two `!{Grow}` lends of one owned object stay rejected.
4. **First, a North Star 1 bug on main, found by the panel.** A method
   task through a handle, `(!h).bump()&`, passes `rig check` and fails in
   Zig. Its fix is in progress, and the rule's task clause waits for it.

## Consequences
- Newly accepted:
  - `!c.add((!c).swap(4))` and `!ch.send((!ch.recv()! ?? 0) + 5)!`;
  - a view `r = ?c` kept across `!c.set(5)`;
  - `hit2(!h, !h)`;
  - `(!@).bump((!@).bump(1))`.
- A task holding only a read loan may go into a set or be returned, as
  `work(+h)&` already may.
- `(!c)[0] = (!c).pop() ?? 9` (accepted) and `!c.push((!c).pop() ?? 0)`
  (rejected) come to agree.

## Implementation (one PR)
- **One fact:** typecheck records `loanOf(lend)` where `!x`'s view is
  chosen (`synthLend`): read when the lent view is a write view of a
  value `sema.changesByMark` judges by its concrete type, else write.
  Ownership reads it, and drops its actor and select-arm overrides.
- **Oracle:** the reference checker derives the same from the new CORE
  text alone.
- **Docs in the same PR:**
  - CORE sentence 9, §4's handle rows, and the paragraph after the table;
  - SPEC "Shared handles", "Cell", "Actors" ("lends nothing" goes),
    "Channels";
  - QUICK and SYNTAX;
  - an accepted and a rejected doc example for each of 22 handle rows.
- **Gates:**
  - the core suite;
  - Trig's and loco's light gates;
  - a sanitizer pass of the concurrency cases;
  - emit-diff and the four guards;
  - the oracle's rejection diff, read line by line by session Rig.
