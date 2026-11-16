# Soundness review (expert 1), 2026-11-15

## Q1: false for Cells and channels

- c1: `r = ?c`, `!c.set(5)`, `r.get()`: rejected, "cannot lend `c` to
  write while a read loan is live". The same with `!ch.send` and
  `!ch.recv` (ch1, ch5).
- a1: `r = ?a`, `!a.add(1)`, `r.count()`: accepted.
- a2, act.rig: `!a.add(grab(!a))`: rejected, "`a` lent to read here".
- a5 (through `?*Actor`), h1 (`!h.push` on `*List`), and api1 (`!@`
  through `*{A}`): rejected.

A Cell's or channel's marked call lends the handle to write. An actor's marked call lends the handle to
read for the call. Neither "lends nothing", so the line must name the
kinds of handle.

## Q2: §10 and sentence 9

It fits, with no exception list: each outcome follows the method's
self (sentence 9's `!@` on what is shared, an actor's message,
sentence 8's read-only handle). "Lends nothing" contradicts sentence 9
as built (c1).

## Q4: other inconsistencies

1. **SPEC "Actors"** says "lends nothing", which a2 refutes. Suggested:
   "The `!` marks the call and lends the handle to read for it, as a
   self; nothing of the actor's value is lent."
2. **The CORE row for `*T`** says "nothing of the value", but
   `take(!c)` into a `!Cell[Int]` is accepted (c2), and SPEC "Cell"
   says `!h` lends `!C`. The row should add: "of a `T` that holds a
   Cell, also the `!T` that changes only its Cells."
3. **A compiler gap, for the backlog.** `!ch.on_recv()` and
   `!ch.on_send(3)` arms with `ch: ?*Chan[Int]` are accepted (s4, s7),
   and s4 runs and prints `got 7`. `!r.recv()` through the same view is
   rejected (ch2). The arms break sentence 4 ("`?` promises that
   nothing changes").
4. **The SPEC select sentence** is correct (s1, s2, s3). It should add
   "through a handle the task holds", so that "read" does not suggest
   a `?ch` is enough.

## Recommended CORE line (after the §4 table)

A marked call through a handle lends the handle, as its type says.
Through a `Cell` or a channel, `!c.set(x)` lends it to write, as a `!@`
self, and changes only what the handles share (sentence 9). Through an
actor, `!a.add(x)` lends it to read for the call, which is a message,
and needs a handle you hold; the actor changes its own value (SPEC,
"Actors"). Through any other handle, a `!@` call is rejected. `!h`
standing alone lends the handle itself.
