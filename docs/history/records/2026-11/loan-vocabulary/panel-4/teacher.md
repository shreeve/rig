# Panel 4, teacher: one rule, and the name it already has

Role: a language designer and teacher, on the brief's questions 1 and 5,
and the CORE §9 paragraph. Every program below was run with
`~/Data/Code/rig/bin/rig` (rig 0.3.0, main at 41d245dff); the programs and
their output are in the appendix.

## Verdict

1. **One rule is right.** All six members (`Cell`, `Signal`, `Chan`,
   `Actor`, an object holding a `Cell`, std's `shared.Map`) answer `?x`
   and `!x` identically on every case I ran: a marked call while a read
   view lives is accepted, a typed write view leaves the place readable
   and callable, and reassigning or dropping under either view is
   refused. Where they differ, they differ on other axes: how long a view
   lasts (a call, a task, a select; an actor's `&` call keeps nothing),
   which views have methods (an actor's have none), and which cross
   threads. None of these is a second view rule, and none should be
   folded into the group's name.
2. **The group needs a name, and it already has one: "holds a Cell".**
   The docs refer to the group about 50 times as "a value that changes
   by a marked call", which is not precise (`!v.push(1)` on a `List` is
   a marked call too). The compiler already says "holds a Cell" of
   channels and actors in its own messages ("a value of `Chan[Int]`
   holds a Cell, so it lives only behind a shared handle"), the phrase
   appears about 115 times, nearly all in this sense, and it is the test a user applies to
   their own type. So: **a Cell, or a value that holds one**, with
   `Signal` counted among them. No new word.
3. **One gap to close first:** the compiler does not count `Signal` as
   holding a Cell, so `sub g(s: Signal[Int])` and `List[Signal[Int]]()`
   are accepted where the `Chan` and `Actor` forms are refused (s_param).
   It is harmless (no `Signal` can exist by value), but it makes "never
   a parameter or element by value" false for `Signal`. Default: count
   `Signal` as holding a Cell in `reachOf` (sema.zig ~7783), after
   checking what else the `cell` flag drives.

## Question 1: is one rule right for all of them?

### The matrix

Each cell is one program (appendix: `a_*`, `r1_*` … `r5_*`).

| Case | Cell | Signal | Chan | Actor | Hits | shared.Map |
|---|---|---|---|---|---|---|
| `r = ?x`, then a marked call, then `r` used | accepted | accepted | accepted | accepted | accepted | accepted |
| `w: !T = !x`, then `x` read and called, then `w` used (r5, a_*) | accepted | accepted | accepted | accepted* | accepted | accepted |
| nested: `!x.m((!x).m2())` | accepted | n/a | accepted | accepted | accepted | n/a |
| `r = ?x; x = new` (r1) | refused: reassign | same | same | same | same | same |
| `w: !T = !x; x = new` (r2) | refused: reassign | same | same | same | same | same |
| `w: !T = !x; <x` (r4) | refused: drop | same | same | same | same | same |
| `w = !x` untyped, then `x` used (r3) | refused: use | same | same | same | same | same |

\* `w: !Actor[C] = !a` is accepted, but nothing can be done with it: a
`?Actor[T]` or `!Actor[T]` has no methods ("no method `add` on type
`Actor`", a_actor). An actor's calls go only through a handle, `*`,
`?*`, or `!*` (a_actor3).

So the view rule is the same for every member: **a write view of the
value leaves the place read-only; a write view of the handle (untyped
`w = !x`) is ordinary.**

### Where they differ, and why it is not a second rule

- **How long the view lasts.** A marked call's view lasts for the call;
  a task that holds self keeps it for the task's life
  (`t = (!h).bump()&; h = …` is refused); a select's `!ch.on_recv()`
  until the select returns. An actor's call gives the actor a count,
  not a view, so `t = !a.add(1)&; a = …` is accepted. All four are "until
  its last use": the actor's view simply has its last use at the call.
  A teacher states this once, under the rule, not as an exception.
- **Which views have methods.** Only the actor: its views of the value
  have none. That belongs in SPEC §18 ("an actor is reached only
  through a handle"), not in the view rule.
- **Which cross threads.** A word `Cell`, a word-Cell object, a channel,
  an actor and `shared.Map` cross; a `Signal` and any other `Cell` make
  their task local (SPEC §18, Local tasks; v_sigtask and v_listcell run,
  as local tasks). This is the sends/syncs table's axis, and it cuts
  through the group. A name built on it (anything like "shared" or
  "sync") would be wrong for half the members.
- **The compiler's own test** is `changesByMark`: a `Cell`, a `Signal`,
  or a type whose `cell` flag is set, which `reachOf` sets for `Cell`,
  `Chan` and `Actor` and for anything holding them by value, but not for
  `Signal`. That is the gap in the verdict.

## Question 5: does the group need a name?

### Why a name, though the owner chose a list

The owner's decision is that the group is "named by its members, not by
a term". A teacher agrees with the second half and not quite the first:

- The rule has to refer to the group in one breath: "can't be used at
  all, or is only read-only when …". A five-item list does not fit
  there, and "a Cell or its kind" is a name already, a vague one.
- The docs already use a name, about 50 times: "a value that changes by
  a marked call". It is the wrong one: a `List` also changes by marked
  calls; what sets the group apart is *only*, and *behind `*`*.
- The open member, "an object holding a `Cell`", is the user's way in.
  A user asks of their own type "is it one?", and the answer has to be a
  test they can apply to their declaration.
- No message needs the name: each names the concrete type it saw. The
  name is for the docs, the notes, and the reader's head.

So the choice is not name or no name, but which. The best one is the
phrase the compiler already speaks.

### Candidates, checked against Rig's words

Grep over `docs SPEC.md src std test AGENTS.md README.md`, history left
out:

| Candidate | Hits | What the hits mean |
|---|---|---|
| holds a Cell / holding a Cell | 115 / 26 | exactly this sense: "lives only behind `*`"; the compiler says it of `Chan` and `Actor` |
| Cell-like | 0 | free |
| the Cell kind | 0 as a phrase; "kind" 2240, "kinds of value" 4 | CORE §1 is titled "Four kinds of value" |
| method-only | 0; "methods only" 11 | docs/design/apis.md: an `api` is "methods only, no fields"; `*{A}` "reaches `?@` methods only" |

Also checked and dropped: "shared value" (24; means anything behind
`*`), "guarded" (238; guard clauses, and it implies a lock a `Signal`
has none of), "live value" (5; the old "a read loan is live"),
"interior" (8; "interior mutability" in the welcome table, but Rig says
"change", not "mutable"), "sealed" (38, and other languages' sealed
classes), "self-changing" (0, but reads as changing by itself).

**1. "holds a Cell" (recommended).**

- CORE: "`!v` makes a write view of `v`. Until its last use, `v` can't
  be used at all, or, when it is or holds a `Cell` (§9), is only
  read-only."
- Message (today's, unchanged): "a value of `Chan[Int]` holds a Cell, so
  it lives only behind a shared handle: write `*Chan[Int]`". A possible
  note for the untyped trap: "`w = !c` is a write view of the handle
  itself; `c` holds a Cell, so write `w: !Cell[Int] = !c` to view the
  Cell".
- Declaration:

  ```rig
  # A count tasks share. It holds a Cell, so it lives only behind `*`,
  # and a write view of it leaves its handle read-only.
  obj Hits
    n: Cell[Int]
  ```

  No new word; the user checks their own fields. Its one weakness, that
  "a Cell holds a Cell" is odd, is met by saying "is or holds".

**2. "Cell-like".**

- CORE: "… or, when it is Cell-like (§9), is only read-only."
- Message: "a `Chan[Int]` is Cell-like, so it lives only behind a shared
  handle: write `*Chan[Int]`".
- Declaration: "# Hits is Cell-like: it holds a Cell, so …". The
  declaration has to say "holds a Cell" anyway to say why, which is the
  sign the extra word adds nothing.

**3. "the Cell kind".**

- CORE: "… or, when it is of the Cell kind (§9), is only read-only."
- Message: "a `Chan[Int]` is of the Cell kind, so it lives only behind a
  shared handle".
- Declaration: "# Hits is of the Cell kind: it holds a Cell, so …".
  A learner who has read §1's "Four kinds of value" looks for a fifth row
  in that table and does not find one. Keep "kind" for §1.

**4. "method-only".**

- CORE: "… or, when it is method-only (§9), is only read-only."
- Message: "a `Chan[Int]` is method-only, so it lives only behind a shared
  handle".
- Declaration: "# Hits is method-only: it changes only through its
  methods". It names the reason well, but an `api` is already "methods
  only", and an API object is the one thing expressly *outside* the group
  (`!s` of a `*{A}` views only the handle). Rejected for the collision.

**What goes:** "changes by a marked call" as the group's name (keep
"marked call" for the call itself), "its kind" and "its kin".

## The CORE §9 paragraph

In the decided words; read-only belongs to the place; no lend, lent or
loan. Every claim was run (appendix) or is today's CORE unchanged in
substance (the task and frozen sentences).

> **9. Shared storage.** A name's own value changes by assigning it,
> and what you were given changes through a write view, `!`. What you
> share through `*` changes only through its own calls. A `Cell` changes
> only by its marked calls, `!c.set(5)`, and so does a value that holds
> one: an object with a `Cell` field, std's `shared.Map`, and a channel
> or an actor (SPEC §18); a `Signal` counts as one too. Such a value
> lives only behind `*` (`*Cell(0)`, or a field of a value made with
> `*`): never a local, parameter, element, or type argument by value. It
> is never replaced whole (`swap` exchanges none; a Cell's own
> `!c.swap(v)` does, in one step), and every view it gives out lasts
> while it lives. So a write view of it leaves the place it came from
> only read-only: the handle stays put, so nobody may assign, move, or
> drop it, while the value still changes through its own calls, and many
> write views of it may be in use at once, `!c.add((!c).swap(4))`. That
> is so when the view is of the value, as in `!c.set(5)` or
> `w: !Cell[Int] = !c`. `w = !c` with no type makes a write view of the
> handle itself, a `!*Cell[Int]` that can point `c` elsewhere, which is
> an ordinary write view: `c` can't be used at all until its last use.
> An actor's call gives the actor a count of its own, not a view, so
> `!a.add(x)&` leaves `a` free once it is made. A `Cell` of one word may
> go to other tasks, each change landing at once in one order every task
> sees, and so may a *word-Cell object*: an object that holds a `Cell`
> and whose every field, as declared, is plain data (§1), a `Cell` of one
> word, or another word-Cell object. Through a handle only its Cells
> change; its handles, weak ones too, count atomically, and its `drop`
> runs in whichever task drops the last. A `get` then a `set` are two
> changes, not one. A frozen value, `*Frozen(x)`, also lives only behind
> `*`, and holds only data that never changes: no `Cell`, `Signal`, task,
> closure, view, or handle but another frozen value's. So its handles
> count atomically and go to any task, erased they are a
> `*{A + Syncs}` (§4), and `?f` makes a read view of the frozen value,
> a `?T`. A `Cell`, a `Signal`, and an owned closure hold no views, so
> they keep text only as a `Static`. *(built, but for `Signal` by value
> as a parameter or element, which today's compiler accepts)*

Two follow-ups for the editor:

- §1's bullet "A type that holds a `Cell`, or a bare `Cell[T]`, lives
  only behind `*`" becomes "A `Cell`, and a type that holds one (a
  `Signal`, channel, and actor count), live only behind `*`".
- §4's table row "`*T` whose `T` changes by a marked call (sentence 9)"
  becomes "`*T` whose `T` is or holds a `Cell` (sentence 9)".

## Appendix: the programs and their output

Programs are in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/panel4/teacher/`;
each was run with `rig run FILE`, first three lines of output shown.
`a_actor.rig` is kept to show the `!Actor[T]` dead end.

#### a_actor.rig

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun get(?@) -> Int
    @n

sub poke(a: !Actor[Counter])
  _ = !a.add(1)

sub main()
  a = *Actor(Counter(n: 0))
  r = ?a
  _ = !a.add(1)
  print(a.get())
  print((!a).add((!a).add(1)))
  print(r.get())
```

```text
a_actor.rig:12:10: error: no method `add` on type `Actor`
  _ = !a.add(1)
         ^
```

#### a_actor3.rig

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun get(?@) -> Int
    @n

sub poke(a: !*Actor[Counter])
  _ = !a.add(1)

fun look(a: ?*Actor[Counter]) -> Int
  a.get()

sub main()
  a = *Actor(Counter(n: 0))
  poke(!a)
  print(a.get(), look(?a))
```

```text
1 1
```

#### a_cell.rig

```rig
sub main()
  c = *Cell(1)
  r = ?c
  !c.set(5)
  w: !Cell[Int] = !c
  print(c.get())
  !c.add((!c).swap(4))
  !w.set(9)
  print(r.get(), w.get(), c.get())
```

```text
5
9 9 9
```

#### a_chan.rig

```rig
fun seen(c: ?Chan[Int]) -> Int
  1

sub main()!
  ch = *Chan[Int](4)
  r = ?ch
  !ch.send(1)!
  w: !Chan[Int] = !ch
  !ch.send((!ch.recv()! ?? 0) + 5)!
  !w.send(7)!
  print(!ch.recv()! ?? -1, !w.recv()! ?? -1, seen(r))
```

```text
6 7 1
```

#### a_hits.rig

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@, k: Int) -> Int
    !@n.add(k)

sub main()
  h = *Hits(n: Cell(0), step: 2)
  r = ?h
  _ = !h.bump(1)
  w: !Hits = !h
  print(h.step)
  print((!h).bump((!w).bump(1)))
  print(r.n.get(), w.n.get())
```

```text
2
4
4 4
```

#### a_map.rig

```rig
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  r = ?m
  _ = !m.put_new(1, 10)
  v = m.get(1) ?? 0
  w: !shared.Map[Int, Int] = !m
  _ = !w.put_new(2, 20)
  x = ?m.get(2)
  _ = !m.put_new(3, 30)
  print(v, x ?? 0, r.len(), w.len())
```

```text
10 20 3 3
```

#### a_signal.rig

```rig
sub main()
  s: *Signal[Int] = *Signal(0)
  r = ?s
  !s.set(5)
  w: !Signal[Int] = !s
  print(s.get())
  !w.set(9)
  print(r.get(), w.get(), s.get())
```

```text
5
9 9 9
```

#### h_chan.rig

```rig
obj P
  ch: Chan[Int]

sub main()!
  x = *P(ch: Chan[Int](2))
  w: !P = !x
  !x.ch.send(4)!
  print(!w.ch.recv()! ?? -1)
```

```text
h_chan.rig:5:14: error: a channel lives only behind a shared handle: write `*Chan[T](n)`
  x = *P(ch: Chan[Int](2))
             ^~~~~~~~~
```

#### h_signal.rig

```rig
obj W
  s: Signal[Int]

sub main()
  x = *W(s: Signal(0))
  w: !W = !x
  print(x.s.get())
  !w.s.set(3)
  print(x.s.get())
```

```text
h_signal.rig:5:13: error: stack-local `Signal[T]` is not supported: a Signal lives behind a shared handle; construct it with `*Signal(...)`
  x = *W(s: Signal(0))
            ^~~~~~
```

#### r1_actor.rig

```rig
obj C
  n: Int

  fun get(?@) -> Int
    @n

sub keep(v: ?Actor[C])
  print(1)

sub main()
  x = *Actor(C(n: 0))
  r = ?x
  x = *Actor(C(n: 0))
  keep(r)
```

```text
r1_actor.rig:13:3: error: cannot reassign `x` while it is lent
  x = *Actor(C(n: 0))
  ^
```

#### r1_cell.rig

```rig

sub keep(v: ?Cell[Int])
  print(1)

sub main()
  x = *Cell(1)
  r = ?x
  x = *Cell(1)
  keep(r)
```

```text
r1_cell.rig:8:3: error: cannot reassign `x` while it is lent
  x = *Cell(1)
  ^
```

#### r1_chan.rig

```rig

sub keep(v: ?Chan[Int])
  print(1)

sub main()!
  x = *Chan[Int](1)
  r = ?x
  x = *Chan[Int](1)
  keep(r)
```

```text
r1_chan.rig:8:3: error: cannot reassign `x` while it is lent
  x = *Chan[Int](1)
  ^
```

#### r1_hits.rig

```rig
obj Hits
  n: Cell[Int]

sub keep(v: ?Hits)
  print(1)

sub main()
  x = *Hits(n: Cell(0))
  r = ?x
  x = *Hits(n: Cell(0))
  keep(r)
```

```text
r1_hits.rig:10:3: error: cannot reassign `x` while it is lent
  x = *Hits(n: Cell(0))
  ^
```

#### r1_map.rig

```rig
use std.shared
sub keep(v: ?shared.Map[Int, Int])
  print(1)

sub main()
  x = shared.Map[Int, Int].new()
  r = ?x
  x = shared.Map[Int, Int].new()
  keep(r)
```

```text
r1_map.rig:8:3: error: cannot reassign `x` while it is lent
  x = shared.Map[Int, Int].new()
  ^
```

#### r1_signal.rig

```rig

sub keep(v: ?Signal[Int])
  print(1)

sub main()
  x = *Signal(1)
  r = ?x
  x = *Signal(1)
  keep(r)
```

```text
r1_signal.rig:8:3: error: cannot reassign `x` while it is lent
  x = *Signal(1)
  ^
```

#### r2_actor.rig

```rig
obj C
  n: Int

  fun get(?@) -> Int
    @n

sub keep(v: !Actor[C])
  print(1)

sub main()
  x = *Actor(C(n: 0))
  w: !Actor[C] = !x
  x = *Actor(C(n: 0))
  keep(!w)
```

```text
r2_actor.rig:13:3: error: cannot reassign `x` while it is lent
  x = *Actor(C(n: 0))
  ^
```

#### r2_cell.rig

```rig

sub keep(v: !Cell[Int])
  print(1)

sub main()
  x = *Cell(1)
  w: !Cell[Int] = !x
  x = *Cell(1)
  keep(!w)
```

```text
r2_cell.rig:8:3: error: cannot reassign `x` while it is lent
  x = *Cell(1)
  ^
```

#### r2_chan.rig

```rig

sub keep(v: !Chan[Int])
  print(1)

sub main()!
  x = *Chan[Int](1)
  w: !Chan[Int] = !x
  x = *Chan[Int](1)
  keep(!w)
```

```text
r2_chan.rig:8:3: error: cannot reassign `x` while it is lent
  x = *Chan[Int](1)
  ^
```

#### r2_hits.rig

```rig
obj Hits
  n: Cell[Int]

sub keep(v: !Hits)
  print(1)

sub main()
  x = *Hits(n: Cell(0))
  w: !Hits = !x
  x = *Hits(n: Cell(0))
  keep(!w)
```

```text
r2_hits.rig:10:3: error: cannot reassign `x` while it is lent
  x = *Hits(n: Cell(0))
  ^
```

#### r2_map.rig

```rig
use std.shared
sub keep(v: !shared.Map[Int, Int])
  print(1)

sub main()
  x = shared.Map[Int, Int].new()
  w: !shared.Map[Int, Int] = !x
  x = shared.Map[Int, Int].new()
  keep(!w)
```

```text
r2_map.rig:8:3: error: cannot reassign `x` while it is lent
  x = shared.Map[Int, Int].new()
  ^
```

#### r2_signal.rig

```rig

sub keep(v: !Signal[Int])
  print(1)

sub main()
  x = *Signal(1)
  w: !Signal[Int] = !x
  x = *Signal(1)
  keep(!w)
```

```text
r2_signal.rig:8:3: error: cannot reassign `x` while it is lent
  x = *Signal(1)
  ^
```

#### r3_actor.rig

```rig
obj C
  n: Int

  fun get(?@) -> Int
    @n

sub main()
  x = *Actor(C(n: 0))
  w = !x
  print(x.get())
  w = *Actor(C(n: 0))
```

```text
r3_actor.rig:10:9: error: use of `x` while a write loan is live
  print(x.get())
        ^
```

#### r3_cell.rig

```rig

sub main()
  x = *Cell(1)
  w = !x
  print(x.get())
  w = *Cell(1)
```

```text
r3_cell.rig:5:9: error: use of `x` while a write loan is live
  print(x.get())
        ^
```

#### r3_chan.rig

```rig

sub main()!
  x = *Chan[Int](1)
  w = !x
  !x.close()
  w = *Chan[Int](1)
```

```text
r3_chan.rig:5:4: error: use of `x` while a write loan is live
  !x.close()
   ^
```

#### r3_hits.rig

```rig
obj Hits
  n: Cell[Int]

sub main()
  x = *Hits(n: Cell(0))
  w = !x
  print(x.n.get())
  w = *Hits(n: Cell(0))
```

```text
r3_hits.rig:7:9: error: use of `x` while a write loan is live
  print(x.n.get())
        ^
```

#### r3_map.rig

```rig
use std.shared
sub main()
  x = shared.Map[Int, Int].new()
  w = !x
  print(x.len())
  w = shared.Map[Int, Int].new()
```

```text
r3_map.rig:5:9: error: use of `x` while a write loan is live
  print(x.len())
        ^
```

#### r3_signal.rig

```rig

sub main()
  x = *Signal(1)
  w = !x
  print(x.get())
  w = *Signal(1)
```

```text
r3_signal.rig:5:9: error: use of `x` while a write loan is live
  print(x.get())
        ^
```

#### r4_actor.rig

```rig
obj C
  n: Int

  fun get(?@) -> Int
    @n

sub keep(v: !Actor[C])
  print(1)

sub main()
  x = *Actor(C(n: 0))
  w: !Actor[C] = !x
  <x
  keep(!w)
```

```text
r4_actor.rig:13:4: error: cannot drop `x` while it is lent
  <x
   ^
```

#### r4_cell.rig

```rig

sub keep(v: !Cell[Int])
  print(1)

sub main()
  x = *Cell(1)
  w: !Cell[Int] = !x
  <x
  keep(!w)
```

```text
r4_cell.rig:8:4: error: cannot drop `x` while it is lent
  <x
   ^
```

#### r4_chan.rig

```rig

sub keep(v: !Chan[Int])
  print(1)

sub main()!
  x = *Chan[Int](1)
  w: !Chan[Int] = !x
  <x
  keep(!w)
```

```text
r4_chan.rig:8:4: error: cannot drop `x` while it is lent
  <x
   ^
```

#### r4_hits.rig

```rig
obj Hits
  n: Cell[Int]

sub keep(v: !Hits)
  print(1)

sub main()
  x = *Hits(n: Cell(0))
  w: !Hits = !x
  <x
  keep(!w)
```

```text
r4_hits.rig:10:4: error: cannot drop `x` while it is lent
  <x
   ^
```

#### r4_map.rig

```rig
use std.shared
sub keep(v: !shared.Map[Int, Int])
  print(1)

sub main()
  x = shared.Map[Int, Int].new()
  w: !shared.Map[Int, Int] = !x
  <x
  keep(!w)
```

```text
r4_map.rig:8:4: error: cannot drop `x` while it is lent
  <x
   ^
```

#### r4_signal.rig

```rig

sub keep(v: !Signal[Int])
  print(1)

sub main()
  x = *Signal(1)
  w: !Signal[Int] = !x
  <x
  keep(!w)
```

```text
r4_signal.rig:8:4: error: cannot drop `x` while it is lent
  <x
   ^
```

#### r5_actor.rig

```rig
obj C
  n: Int

  fun get(?@) -> Int
    @n

sub keep(v: !Actor[C])
  print(1)

sub main()
  x = *Actor(C(n: 0))
  w: !Actor[C] = !x
  print(x.get())
  keep(!w)
```

```text
0
1
```

#### r5_cell.rig

```rig

sub keep(v: !Cell[Int])
  print(1)

sub main()
  x = *Cell(1)
  w: !Cell[Int] = !x
  print(x.get())
  keep(!w)
```

```text
1
1
```

#### r5_chan.rig

```rig

sub keep(v: !Chan[Int])
  print(1)

sub main()!
  x = *Chan[Int](1)
  w: !Chan[Int] = !x
  !x.close()
  keep(!w)
```

```text
1
```

#### r5_hits.rig

```rig
obj Hits
  n: Cell[Int]

sub keep(v: !Hits)
  print(1)

sub main()
  x = *Hits(n: Cell(0))
  w: !Hits = !x
  print(x.n.get())
  keep(!w)
```

```text
0
1
```

#### r5_map.rig

```rig
use std.shared
sub keep(v: !shared.Map[Int, Int])
  print(1)

sub main()
  x = shared.Map[Int, Int].new()
  w: !shared.Map[Int, Int] = !x
  print(x.len())
  keep(!w)
```

```text
0
1
```

#### r5_signal.rig

```rig

sub keep(v: !Signal[Int])
  print(1)

sub main()
  x = *Signal(1)
  w: !Signal[Int] = !x
  print(x.get())
  keep(!w)
```

```text
1
1
```

#### f_elem.rig

```rig
sub main()
  xs = List[Chan[Int]]()
  ys = List[Signal[Int]]()
  zs = List[Actor[Int]]()
  print(xs.len, ys.len, zs.len)
```

```text
f_elem.rig:4:8: error: a value of `Actor[Int]` holds a Cell, so it lives only behind a shared handle: write `*Actor[Int]`
  zs = List[Actor[Int]]()
       ^
```

#### f_frozen.rig

```rig
obj Page
  n: Int

sub main()
  p = *Frozen(Page(n: 1))
  w: !Page = !p
  print(w.n)
```

```text
f_frozen.rig:6:14: error: type mismatch: expected `!Page`, got `!*Frozen[Page]`
  w: !Page = !p
             ^~
```

#### f_param.rig

```rig
sub f(s: Signal[Int])
  print(1)

sub g(c: Chan[Int])
  print(1)

sub main()
  print(0)
```

```text
f_param.rig:4:10: error: a value of `Chan[Int]` holds a Cell, so it lives only behind a shared handle: write `*Chan[Int]`
sub g(c: Chan[Int])
         ^~~~~~~~~
```

#### s_cellsig.rig

```rig
sub main()
  c = *Cell(*Signal(1))
  print(c.get().get())
```

```text
s_cellsig.rig:3:11: error: `Cell.get` returns a copy of the value, and a `*Signal[Int]` owns what it must release, so it can't be copied; write `(!cell).swap(<new)`, which puts `new` in and hands back the old value
  print(c.get().get())
          ^
```

#### s_obj.rig

```rig
obj Ui
  sig: *Signal[Int]
  n: Int

sub main()
  u = *Ui(sig: *Signal(1), n: 2)
  w = !u
  print(u.n)
  print(w.n)
```

```text
s_obj.rig:8:9: error: use of `u` while a write loan is live
  print(u.n)
        ^
```

#### s_param.rig

```rig
sub f(s: ?Signal[Int])
  print(s.get())

sub g(s: Signal[Int])
  print(s.get())

sub main()
  ys = List[Signal[Int]]()
  sig = *Signal(1)
  f(?sig)
  print(ys.len)
```

```text
1
0
```

#### v_handle.rig

```rig
sub main()
  c = *Cell(1)
  w = !c
  w = *Cell(9)
  print(c.get())
```

```text
9
```

#### v_two.rig

```rig
sub two(a: !Cell[Int], b: !Cell[Int])
  !a.set(b.get() + 1)
  !b.set(a.get() + 1)

sub main()
  c = *Cell(1)
  two(!c, !c)
  print(c.get())
```

```text
3
```

#### v_sigtask.rig

```rig
fun read(s: *Signal[Int]) -> Int
  s.get()

sub main()
  s = *Signal(1)
  t = read(+s)&
  print(>t)
```

```text
1
```

#### v_listcell.rig

```rig
fun read(c: *Cell[List[Int]]) -> Int
  c.len

sub main()
  c = *Cell(List[Int]())
  t = read(+c)&
  print(>t)
```

```text
0
```

