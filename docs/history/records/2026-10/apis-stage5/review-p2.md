# APIs Stage 5, phase 2: adversarial review (2026-10-24)

A review of PR #622 ([phase2-notes.md](phase2-notes.md)) against the
approved CORE text (§4, "A shared API object counts a value of hidden
type, and an API object crosses tasks only by a bound it names"), SPEC
§18, the panel's holes A1 to A7 and the reviewer's fixes
([core-panel/](core-panel/)), the defaults of
[open-questions.md](open-questions.md), and the `*Frozen` record
([../frozen/](../frozen/)). The branch was first rebased on `main`
after #617 and #621 landed. About 230 probe programs, each checked, run
with `RIG_SANITIZE=1` (`RIG_LEAK_TRACE=1` for programs, the task probes
as `test` blocks under seeds 1 to 20), and given to the oracle; five
multi-task programs ran on real threads on the Mac and on pup. Each fix
has its case, each seen failing first; the full suite is green (10,381
jobs).

## Findings, by severity

### High: accepted, then a crash

1. **A long chain of `*{A + Syncs}` overflowed the stack at its last
   drop.** A frozen value may hold `*{A + Syncs}` handles (fix 2), so
   200,000 frozen links each holding the next as a `*{Node + Syncs}`
   is a program the phase accepts; dropping its head's last count
   recursed once per link and died of a stack overflow. The cause is
   older: `Counted.dropStrong` sent a `*T`'s last drop through the
   drop queue past 256 nested drops, but released an atomic count's
   value at once, so a chain of 3,000,000 `*Frozen[Link]` overflowed
   on `main` too; the object's table only added frames per link.
   *Fixed:* the atomic count's last drop takes the same path as a
   plain one, depth and queue included. The queue is the running
   task's, and the value whose count that task took to zero is its
   alone, so it is sound to queue it there, as the frozen value has no
   weak handle and a queued value already has `strong == 0`. Cases
   "apis object shared a long frozen chain drops without deep
   recursion" (`seeds: 20`, the last counts given back on two tasks)
   and "frozen chain drops without deep recursion".

### Medium: accepted, then failed in Zig

2. **A value aligned below its counted allocation.** An object of no
   fields, or a plain enum (`enum Kind: Shape`), erased to a `*{Shape}`
   failed in Zig: the table entries find the allocation around the
   value by `@fieldParentPtr`, which may not raise a pointer's
   alignment. *Fixed:* `heldAt` aligns the parent pointer, which the
   allocation's own alignment makes true. Case "apis object shared a
   value of small alignment" (counts, weak handles, a `drop` body, and
   a frozen enum).
3. **`+o` of an optional object handle.** `+t` of a `(*{Shape})?` or a
   `(*{Shape + Syncs})?` failed in Zig: the runtime's
   `cloneOptional` took any handle that is not a `*Shared(T)` for a
   weak one. *Fixed:* a counted object's handle counts strongly. Case
   "apis object shared optional handles counted".
4. **A frozen value as an inferred type argument** (A1, through
   generics; older than this phase). `count[T](h: *T)` given a
   `*Frozen[Int]` inferred `T = Frozen[Int]`, which SPEC already keeps
   from every type argument but which only a written one was checked
   for; the generic `*T` was then a plain `*Shared(T)` in Zig, and a
   `~T` would have been a weak handle of a frozen value. A Zig error
   today, so nothing that ran is newly rejected. *Fixed:* the one
   decider of where a type may stand, `sema.misplaced`, gains
   `.frozen` (`frozenMisplaced`, which the resolver's check of a
   written type also reads), and an instance's type arguments are
   checked by it as a Cell's and a bare object's are: "a frozen value
   lives only behind its handle, so `Frozen[Int]` is no type argument,
   written or inferred: pass the handle whole where a `T` goes,
   `*Frozen[Int]`". A generic object's field, `Wrap(h: *Frozen(...))`
   with `h: *T`, is rejected the same way. Case "frozen as an inferred
   type argument"; SPEC's Frozen values section says so.

### Low: messages

5. **A bare object's message named no handle.** "`{Shape}` has no size
   of its own" listed `?{Shape}`, `!{Shape}`, and `^{Shape}`; it now
   adds `*{Shape}` (SPEC, apis.md, and the case "apis object bare
   local").

## The builder's decisions

1. **A shared object changes only through `*Cell` fields its `?@`
   methods count and set:** sound. A `*{A}` stays with its task, so a
   Cell its value holds changes as behind a `*T`; a one-word Cell
   counted out of it and changed on another task is the Cell's own
   atomic rule. A `*{A + Syncs}` holds a frozen value, which holds no
   Cell: rejected when written (`*Frozen(Counter(hits: *Cell(0)))`),
   at a generic body's instance (`wrap[T: Shape](x: T) ->
   *{Shape + Syncs}` with `T = Counter`), and through an object it
   holds (`^{A}` and views never freeze; only a `*{A + Syncs}` does).
   No path to a Cell under a `*{A + Syncs}` was found.
2. **A Cell of an API object is rejected with a final message:** right;
   `Cell[*{Shape}]`, `Cell[~{Node}?]`, `Cell[List[*{Node}]]`, and
   `add Cell[T]: Shape` erased from a `*Cell[Int]` are all rejected,
   so no cycle of objects forms through a Cell. A strong cycle of
   objects through a Cell of a concrete holder leaks, as SPEC's
   "Cycles" says of every strong cycle; parent pointers held as
   `~{Node}` in a tree release it whole (probed, no leak).
3. **Views share the box's table; the fix text says `*<x`; erasure
   facts record the value's type:** sound. No view reaches a table's
   drop, clone, or weak entries (a view's `+` copies the view, and a
   handle's braces name no `Clone`), and `?s` of a `*{A}` lends the
   counted table's view, whose method entries are the box's.

## On pup (x86-64)

A copy of the branch with these fixes, built through Trig's release
slot (never cores 3 or 4). Five multi-task programs ran on real
threads, each five times under `RIG_SANITIZE=1` and three times in
release, all clean and alike: a frozen plugin registry (fix 2) of
eight `*{Plugin + Syncs}` read by sixteen tasks counting each plugin
2,000 times, one plugin counted out on another task while the
registry's last handle went; 20,000 frozen objects through a channel
to two readers; twenty frozen chains of 20,000 links whose last counts
were given back on three tasks; `par.map` over 1,000
`*{Shape + Syncs}` with a captured `|+s|`; and an actor handing out
and replacing frozen objects to three readers and a writer. The task
probes ran as tests under seeds 1 to 20 (the last count on another
task, a frozen value's `drop` body there, a registry read by eight
tasks, handles back from tasks, `?s` lent to tasks, `+s` in loops,
fallible calls, an actor's state, small values, a long chain), all
passing. `zig build test` passed with `-Doptimize=debug`, `safe`, and
`fast`. The copy was removed.

## Parked

- Low, older (Stage 4): a function that returns `(^{Shape})!` or
  `(*{Shape})!` does not erase its last expression (`^Square(...)` is
  "type mismatch: expected `^{Shape}!`"); binding it to an object
  first works. A rejection, not a hole.
- Low, older: the oracle rejects `s = task.isolate(|| mk())!` where
  `mk` gives a `*{Shape}` (as for a `^{Shape}`, noted in the phase's
  notes); not for a `*{Shape + Syncs}`. No suite case has it.
- Design note: `+s` of a `*{A}` in a function's result makes the
  result keep its argument lent (`first(?xs) -> *{Shape}` keeps `xs`),
  as the hidden value may hold a view; `+ Owned` or `+ Syncs` frees
  it. Consistent with CORE ("both forms carry the loans of what they
  hold"), and the cost of an unnamed bound.

## Probed without findings

A1: `~` of a `*{A + Syncs}` and of a `*{Shape}` of an API that syncs,
through a generic `~h`, an optional, a List, a field `~{Shape + Syncs}`,
`*Frozen` into `*{A}` directly, moved, optional, and through generic
bounds; conversions between `*{A}` and `*{A + Syncs}` both ways. A2:
`*T` into `*{A + Syncs}` through `[T: Shape + Syncs]`, a `type`
alias, a field, a List, a task's argument, `*<x`, `*Frozen(<x)` in a
generic body without `Syncs`, and `*Frozen[T]` of an unbounded `T`
holding a `*T` or a Cell (rejected at the instance); a `?{A + Syncs}`
lent from a `*{A}` (rejected). A4: the loans of `~{A}` after `<s`, a
second weak handle, a List and a field of weak handles, a weak handle
returned, upgraded into a binding, `*<w`, and a weak in an owned
closure; each write while a view the value holds might be read was
rejected. A5: `!sq` as `!*{Shape}`, `?sq` as `?*{Shape}`, optionals of
both, `List[*Square]` as `List[*{Shape}]` by value and by view,
`~Square` as `~{Shape}`, `swap(!a, !b)` (rejected, as for any value
that may hold a view), a List's `swap`, and a slot written. Drops: a
`List[*{A}]` and an object holding two, dropped with a count kept, in
loops, popped, reassigned, and replaced (the order a `*T`'s is), a
`drop` body reading a loan at the last count, a frozen value's `drop`
body on the task that took its last count. Counts: `+s` in loops on
three tasks, `+s` and `<s` while a weak handle is upgraded, `<s` and
reassignment while a `?s` view lives (rejected), `+s` of a view
returned `from`. Calls: fallible `?@` methods through `*{A}`, its
views, and `*{A + Syncs}` on tasks, with an error holding a `String`;
`!@` and `<@` rejected through a handle and its views. `Print` through
handles, Lists, and objects holding a `~{A}`; `==` rejected; generic
`Clone` rejected at the instance. Crossing: a `*{A}` and a `~{A}`
given or lent to a task through generics, fields, Lists, `Box[T]`,
`par.map`, captures, an actor's arguments and results, and a task's
result (each rejected); `*{A + Syncs}` through a task, a channel, an
actor's state, results, and replacement, `par.map` with `|+s|`, a
frozen registry of plugins (fix 2) read by sixteen tasks, a frozen
handle counted out of it on another task. `Owned` in `*{A + Syncs}`
through a `type` alias and a List (fix 3); an API built on `Owned +
Syncs`. Built-in types as API values (`add Int`, `add String`,
`add List[T]`, an enum), and `add Actor[T]` and `add Chan[T]` erased
in a generic body (rejected). Owned closures over `*{A + Owned}` and
`~{A + Owned}`. The oracle decided each accepted `main` it was given
and agreed with the compiler but for the parked `task.isolate` case.

Trig (4056d57): it declares no API and writes no `Frozen`, `*{`, or
`~{`, so nothing it writes meets the phase or these fixes; the
runtime change reaches only an atomic count's last drop of a value
with a drop, past 256 nested drops.
