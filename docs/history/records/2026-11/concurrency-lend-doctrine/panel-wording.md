# Step 2 panel, expert 3: wording (2026-11-15)

Probed with the lend-doctrine worktree's `bin/rig` and `bin/rig-oracle`
(main fa01646fc). Programs: the inventory's `c01`...`m06`, and mine in the
session scratchpad, `panel-w/` (`z01`-`z08`, `e*`). "[now]" means accepted
or rejected today; "[step 2]" means rejected today with a loan conflict,
accepted once the rule is built.

## Judgment

**Point 3: follow the type of what `!` lends, not "through a handle".**
"Through a handle" makes the reader track a place's history; the type
is on the binding. Then `!c.add((!c).swap(4))`
reads the same for `c: *Cell[Int]`, `!*Cell[Int]`, and `!Cell[Int]`,
and `(!@).bump((!@).bump(1))` follows. "The method's self" is the wrong
anchor: an actor call's self is the actor's `!T`, which does not change
by mark, and `hit(!h)` is no method call. What `!` lends (the Cell, the
object holding one, the channel, the actor) is right in every row,
and each such value lives only behind `*`. It also accepts c18, k13,
k04 (`hit2(!h, !h)`), and z08, each reachable through `+h` today and
clean under `RIG_SANITIZE=1` (z04, z05, k05, k08).

**Point 2: one duration, sentence 6.** "For as long as the call, its
task, or the select uses it" is sentence 6 restated as a list. A loan
lasts while the view it carries is used: a task that holds self keeps
it for its life (k11 stays rejected), an arm until the select returns.
An actor's call gives the actor a count of its own, not a view, so
`!a.add(1)&` keeps nothing (a06 stays accepted).

**Point 1: the premise holds.** *Such a value is never replaced whole,
and every view it gives out lasts while it lives*: it does not copy
(z01, z02 rejected); Cell, Signal, Chan, and actors hand out values
only; shared.Map views values it never replaces; a Cell-holding
object's `!@` method views only unchanging fields or a Cell itself.

**Point 4: the one fact.** The type fact exists, `sema.changesByMark(T)`;
keep its name. One fix: it answers yes for an erased `{A}` (its reach
marks `cell` as a precaution). For the loan it must answer from the
concrete type at the lend, and an erased `{A}` or a type parameter
counts as no (z07 must stay rejected). The node fact, recorded once by
typecheck where `!x`'s view is chosen (`synthLend`, with actor calls
routed through it as step 1 routed arms through `armHandle`):
`loanOf(lend)` (or `markLoan`, `lendKind`). It is `.read` when the lent
view is a write view of a `changesByMark` value, else `.write`.
Ownership reads it, dropping the `isActorCall` and `selectArmOf`
overrides; the oracle derives it from CORE alone.

**Wording.** "Never a write view of the shared value" is false (self is
a `!Cell` or `!Hits`); the texts below say both halves.

## CORE: sentence 9, first sentences (replace "What you share is a `Cell`, and it changes only by a marked call: `!c.set(5)`.")

> What you share changes only by a marked call, `!c.set(5)`: a `Cell`,
> a `Signal`, a channel, an actor (SPEC §18), or a value that holds a
> `Cell`, and §4 says what the call lends.

## CORE §4: the handle rows (replace the `*T`, `*{A}` row)

| Owner `x` | `?x` lends | `!x` lends | Status |
|---|---|---|---|
| `*T`, `*{A}` | the read views of `T`; of a `*{A}`, the `?{A}` it holds | the handle itself, `!*T` | built |
| `*T` whose `T` changes by a marked call (sentence 9) | the read views of `T` | the handle itself, `!*T`, or a `!T`, which changes only by marked calls | built |

## CORE §4: the paragraph after the table

> `!x` puts a write loan on `x`, and only a read loan when what it lends
> is a write view of a value that changes by a marked call (sentence 9),
> by a marked call or alone: `!c.set(5)`, `!h.bump()`, `!ch.send(<v)!`,
> `!a.add(x)`, a select's `!ch.on_recv()`, `hit(!h)` for a `!Hits`. Such
> a value lives only behind `*`. It is never replaced whole, and every
> view it gives out lasts while it lives, so many write views of it may
> live at once, each changing only what every handle shares, while `x`
> stays put and keeps the value alive. So `!c.add((!c).swap(4))` is
> accepted, and so is a view `r = ?c` kept across `!c.set(5)`, whether
> `c` is a `*Cell[Int]`, a `!*Cell[Int]`, or a `!Cell[Int]`. `!h` that
> lends the handle itself, a `!*T` the callee may point elsewhere, puts
> a write loan on `h`. A marked call through a read view is rejected
> (sentence 4). The loan lasts as long as the view it carries
> (sentence 6): for the call, for the life of a task that holds self,
> or until a select returns. An actor's call gives the actor a count of
> its own, not a view, so `!a.add(x)&` keeps no loan once made.
> *(planned)*

*(planned)* becomes *(built)* when step 2 lands. Until then, the
[step 2] examples are `rig pending`.

## SPEC

**Shared handles.** Replace "`!h` lends only the handle itself (a
`!*T`), never a write view of the value. Writing a field ... rejected
too." with:

> `!h` lends the handle itself, a `!*T` the callee may point elsewhere,
> and so lends `h` to write. Writing a field, calling a `!@` method, or
> consuming the value through a handle is rejected, because other
> handles share it, so `!h.push(x)` through a `*List[T]` is rejected
> too. Only a value that changes by a marked call (Core sentence 9: a
> `Cell` or a value that holds one, a `Signal`, a channel, an actor)
> changes through a handle. Such a call, or `!h` lending its `!T`,
> lends `h` only to read ([Cell](#cell)).

**Cell.** Replace "`!c` where `c` is a handle lends the handle:
`bump(!local)` ... `k: *Counter`." with:

> A marked call lends the place it names to read, not to write. So does
> `!h` handing over a `!Cell[T]`, or a `!S` of a value that holds a
> Cell. The place keeps the value alive, and what changes is only what
> every handle shares. So two such lends of one place may live at once,
> `!c.add((!c).swap(4))`, and a read view may live across one,
> `r = ?c`, `!c.set(5)`, `r.get()`. This holds whether `c` is a
> `*Cell[Int]`, a `!*Cell[Int]`, or a `!Cell[Int]`. A task made by a
> call through a value that holds a Cell, `(!h).bump()&`, keeps that
> read loan for its life. `!c` lending the handle itself, a
> `!*Cell[T]`, lends `c` to write.

**Signal.** "Both are marked calls, as a Cell's are" becomes:

> Both are marked calls, and lend as a Cell's do.

**Actors.** Replace "The `!` marks the call, and lends nothing: the
actor changes its own value." with:

> The `!` marks the call, and lends the handle's place to read for it,
> as a Cell's marked call does. The actor changes its own value, one
> method at a time, so `(!a).add((!a).add(1))` runs, and
> `!xs[0].add(grow(!xs))` is rejected.

In the `&` paragraph, "but it keeps none of the handle, which may be
used again while it runs" becomes:

> but none of the handle: the call gives the actor a count of its own,
> so the handle may be used, reassigned, or dropped while the task runs.

**Channels.** Replace "Sending and receiving change the channel, so
each is marked with `!` through a handle the task holds, and each is"
with:

> Sending and receiving change the channel, so each is marked with `!`
> through a handle the task holds, never a read view. The mark lends
> the handle's place to read, as a Cell's does, so
> `!ch.send((!ch.recv()! ?? 0) + 5)!` passes on what it receives. Each
> is

In the arm paragraph, after "as `!ch.recv()` does", add:

> and lends the handle's place to read until the select returns: two
> arms may name one channel, and a write to that place before the
> select returns (`grow(!chs)` in an arm) is rejected

Two more lines say "lends the handle `c`" and become "lends `c` to
read": QUICK.md "Shared state" and SYNTAX.md's `(!c).set(5)` row.

## Examples, one accepted and one rejected per row

The errors shown are today's text.

| Row | Accepted | Rejected |
|---|---|---|
| `*Cell[T]` | `!c.add((!c).swap(4))` [step 2, c01] | `_ = !cs[0].add(grow(!cs))`, `grow` pushing to `cs`: "cannot lend `cs` to write while a read loan is live" [now, e01r] |
| `*Cell[List[T]]` | `!c.push((!c).pop() ?? 0)` [step 2, c09] | `bump(!c[0])`: "cannot lend an element of a Cell's List" [now, e02r] |
| `?*Cell[T]` | `fun peek(c: ?*Cell[Int]) -> Int` with `c.get()` [now, e03a] | `!c.set(5)` with `c: ?*Cell[Int]`: "cannot lend to write through a read view `?*Cell[Int]`" [now, e03r] |
| `*Signal[T]` | `r = ?sig`, `!sig.set(7)`, `print(r.get())` [step 2, s02] | `!s.set(1)` with `s: ?*Signal[Int]`: "through a read view `?*Signal[Int]`" [now, s03] |
| `*Chan[T]` calls | `!ch.send((!ch.recv()! ?? 0) + 5)!` [step 2, ch01] | `!xs[0].send(grow(!xs))!`: "cannot lend `xs` to write while a read loan is live" [now, ch05] |
| `*Chan[T]` arms | `task.select(got: !ch.on_recv(), put: !ch.on_send(8))!` [now, sel01, prints `got 7`] | `!ch.on_recv()` with `ch: ?*Chan[Int]`: "through a read view `?*Chan[Int]`" [now, sel03] |
| `Task[T]` arm | `task.select(done: ?t.on_end())!` [now, e16a] | `done: !t.on_end()`: "an arm on a task's end lends the task to read" [now, e16r] |
| `*Actor[T]` | `print((!a).add((!a).add(1)))` [now, a01] | `!xs[0].add(grow(!xs))`: "cannot lend `xs` to write while a read loan is live" [now, a02] |
| `*Actor[T]`, `?@` | `a.count()` [now] | `(!a).count()`: "`count` only reads the actor: call it bare" [now, e07r] |
| `*Actor[T]`, `&` | `t = !a.add(1)&`, then `a = *Actor(Counter(n: 5))`, `>t` [now, a06, prints `1 5`] | `!a.add(1)&` with `a: ?*Actor[Counter]` [now, a04] |
| `*Frozen[T]` | `size(?p)` with `size(p: ?Page)`, and `p.n` [now, e08a] | `!p.bump()`: "cannot call method `bump`, which writes `self`, through a shared handle" [now, f01] |
| plain `*T` | `reset(!h)` with `sub reset(h: !*User)` [now, e09a] | `!h.push(4)` on a `*List[Int]` [now, h01]; `older(!h)` to a `!User`: "expected `!User`, got `!*User`" [now, e09r] |
| `*T`, `T` holds a Cell: calls | `(!h).bump((!h).bump(1))` [step 2, k02]; `show(?h, !h.bump())` [step 2, k09] | `!h.bump()` with `h: ?*Hits`: "through a read view `?*Hits`" [now, e10r_view_param] |
| ... tasks | `t = (!h).bump()&`, then `h.n.get()` [step 2, k10] | `t = (!h).bump()&`, then `h = *Hits(...)`: "cannot reassign `h` while it is lent" [now, k11] |
| ... result views | `w = !h.cell()`, then `h.n.get()` [step 2, k07] | `w = !h.cell()`, `h = *Hits(...)`, `!w.add(1)`: "cannot reassign `h`" [now, e10r_cell_rebind] |
| ... `!h` alone | `hit2(!h, !h)` with `!Hits` parameters [step 2, type rule, z03] | `both(!h, !h)` with `!*Hits` parameters: "while a write loan is live" [now, e10r_repoint_two] |
| `!*Cell[T]` parameter | `!c.add((!c).swap(4))` [step 2, c17] | `r = ?c`, `c = *Cell(9)`, `r.get()`: "cannot reassign `c` while it is lent" [now, e11r] |
| `!Cell[T]`, `!@` (no handle) | `!c.add((!c).swap(4))` with `c: !Cell[Int]` [step 2, type rule, c18]; `(!@).bump((!@).bump(1))` [step 2, type rule, z06] | `c = d` with `d: ?Cell[Int]`: "only a value that copies is copied out of a view" [now, z01] |
| `*{A}` | `s.count()` [now, e13a]; two `!{Bump}` of one `*Hits` [step 2, type rule, z08] | `!s.bump()`: "`*{Bump}` only reads, as any handle" [now, p01]; two `!{Grow}` of one owned `Bag` [now, must stay, z07] |
| `~T` | `if *w as h` then `!h.set(2)` [now, e14a] | `!w.set(2)`: "reaches its value only once upgraded" [now, w01] |
| `Tasks[T]` | `!ts.add(work(+h)&)` [now] | `r = ?ts` live across `!ts.add(work(2)&)`: "cannot lend `ts` to write while a read loan is live" [now, t01] |
| std.shared `*Map` | `r = !m.ensure(1, s)`, then `!m.put_new(2, s2)`, `print(r)` [step 2, m04] | the same with `m = shared.Map[...].new()` while `r` lives: "cannot reassign `m` while it is lent" [now, m05] |
