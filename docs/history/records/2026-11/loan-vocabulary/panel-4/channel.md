# Panel 4, channel: channels, actors, select arms, tasks that hold self

Auditor's report on BRIEF.md questions 1, 2 and 4, for the members other
than a plain `Cell`. Every claim below was run against the compiler at
`~/Data/Code/rig/bin/rig` (rig 0.3.0, main at 41d245dff); the worktree's
`bin/rig` gives the same first diagnostic on every program here.
Concurrency cases ran under `rig test --seeds=20`. Programs and outputs are
in the appendix, and in `scratchpad/panel4/channel/` by member.

## Verdict

**One rule, true for every member at the level of the place.** For a
`Cell`, `Signal`, channel, actor, a `Cell` object (`*Hits`), and
`shared.Map`, a write view of the value, made by a marked call
(`!c.set(5)`, `!ch.send(1)!`, `!a.add(1)`, `!h.bump()`, `!m.ensure(k, v)`)
or bound with its type (`w: !Cell[Int] = !c`), leaves the handle exactly
as a read view does: read, `+c`, `?c`, and more marked calls are accepted;
reassign, move, drop, and `!c` as a `!*T` are refused. The verdicts are
the same for all six, and the 20-seed runs pass.

It is not "as simple as it can be" in four places, all in *which views a
member's calls accept* and *how long a view lasts*, not in what the
read-only state allows:

1. **An actor's call made a task keeps nothing.** `t = !a.add(1)&` lets
   `a` be reassigned, moved, dropped, or lent as `!*Actor` while `t`
   runs. It fits the rule only if CORE says the task holds a handle (a
   count) of its own, not a view.
2. **A task of a call through any other member holds its view until it
   is waited for or dropped**, and the drop at the end of the block counts
   as a use even when `t` is never named again. "Until its last use" must
   say so.
3. **A select arm takes only a handle.** A `!Chan[Int]`, which can
   `send` and `recv`, is refused as an arm. So a function that selects
   takes `!*Chan` (an ordinary write view: the caller's handle can't be
   used at all) or `+ch`.
4. **An actor's value views have no methods.** `?Actor[T]` and
   `!Actor[T]` are accepted as types but call nothing; every actor call
   goes through `*`, `?*` or `!*`. A write view that leaves an actor
   read-only exists only as the mark on a call.

Crossing tasks is not a difference in the rule: every member's handle
and views go to tasks; a member that doesn't cross cores makes the task
*local* (same thread), and read-only means the same either way.

The two new message forms read true on every conflict the compiler
rejects, **if the view is named by the sigil written, not by the loan the
checker records**. Under a write view of the Cell kind the checker records
a read loan and today's note says "`c` lent to read here" at `!c`. Eight
other messages still say lend or loan, or say something false.

## Question 1: one rule or several?

| Member | Write view by marked call | Write view bound with type | Task holding self | Select arm |
|---|---|---|---|---|
| `*Cell[T]` | read-only (cell/r_*, w_call) | `!Cell[T]`: read-only, all calls (cell/w_*) | built-in method: no task at all | n/a |
| `*Signal[T]` | read-only (signal/r_call, r_sub) | `!Signal[T]`: read-only, `set` works (signal/w_*) | built-in method: no task at all | n/a |
| `*Chan[T]` | read-only (chan/r_send) | `!Chan[T]`: read-only, send/recv work (chan/w_type) | built-in: no task at all | **handle only** (chan/s_wview_arm, p_wparam) |
| `*Actor[T]` | read-only for the call (actor/nest, call_reassign_arg) | `!Actor[T]`: accepted, **no methods** (actor/w_type, misc/actor_wview_bind) | **keeps nothing** (actor/t_*) | n/a |
| `*Hits` (holds a Cell) | read-only (task/hits_read_call) | `!Hits`: read-only, fields not written (misc/hits_wfield) | read-only **until waited or dropped** (task/hits_*) | n/a |
| `*shared.Map` | read-only, kept by a result `from @` (map/s_ensure_*) | `!shared.Map`: read-only (map/w_*) | (a user type: as `*Hits`) | n/a |

**The actor's count.** A synchronous `!a.add(x)` keeps a write view, and
its handle read-only, for the call: `(!a).add((!a).add(1))` runs (4), and
`(!a).add(grow(!a))` with `grow(h: !*Actor[Counter])` is refused. With
`&` the task takes a count of its own: `t = !a.add(1)&` followed by
`a = *Actor(...)`, `<a`, `b = <a`, or `reset(!a)` are all accepted and
run (actor/t_assign, t_drop, t_move, t_handle; seeds: "actor call task
keeps no view"). A `?@` call made a task, `a.count()&`, keeps nothing
either (actor/t_read). The task still keeps its *arguments'* views:
`t = !a.size(?s)&` then `!s.push("d")` is refused (misc/actor_arg_rview_task).
This is consistent with the one rule only once CORE says: "an actor's
call made a task gives the task a handle of its own, not a view, so the
view ends where the call is made". CORE §4 already says nearly this
("gives the actor a count of its own, not a view"); it should say what
the *task* holds, since the task is what outlives the line.

**A task that holds self.** `t = (!h).bump()&` of a `*Hits` leaves `h`
read-only for the task's life: `h.step`, `h.peek()`, another
`!h.bump()` and a second task are accepted (task/hits_read_call,
hits_two_tasks); reassigning, moving, or dropping `h` is refused
(hits_assign, hits_move, hits_drop), also with the task in a `Tasks`
(hits_set). The view is not ended by the last mention of `t`:

```rig
  t = (!h).bump()&
  h = *Hits(n: Cell(5), step: 1)   # refused: t is never named again
```

is refused (task/hits_unmentioned), while `<t` or `>t` before the
reassignment is accepted (hits_dropped_then, hits_joined_then). The use
that ends it is the task's wait or drop, which for an unnamed task is
the end of its block, where no token stands. Such a task with read views
only goes anywhere a value holding those views goes: returned
`-> Task[Int] from h` (hits_return, hits_return2), held in a set.

Built-in members can't be a task at all: `(!c).add(1)&`,
`(!c).send(1)&`, `(!s).set(2)&` are refused (task/cell_add, chan_send,
sig_set), so "a task that holds self" means a user method of a Cell
object or a type like `shared.Map`, plus the actor (which holds none).

**A select's `!ch.on_recv()`.** The arm's write view leaves `ch`
read-only until the select returns, consistent with "until its last
use": two arms on one channel run (chan/s_two); an arm that writes the
handle, `!c.on_send(grow(!c))`, is refused (s_arm_assign); a read view
`r = ?c` alive across the select is accepted (s_arm_read); reassigning
`c` in the winner's body, or after binding the select's value and before
matching it, is accepted (s_body_assign, s_bound_later). A `?t.on_end()`
arm likewise ends at the select (misc/task_onend_assign).

The difference is what an arm accepts. Through a `!*Chan[Int]` it works
(chan/p_hparam). Through a `!Chan[Int]`, a local or a parameter, it is
refused: "`w` is a `!Chan[Int]`, not a channel" (s_wview_arm,
p_wparam), though `!w.send(1)!` and `!w.recv()!` work (w_type,
misc/chan_task_vview). Since `!*Chan` is an ordinary write view, a task
that selects on the caller's channel makes the caller's handle unusable
until joined:

```rig
  t = take(!c)&        # take(ch: !*Chan[Int]) selects on ch
  !c.send(1)!          # refused: use of `c` while a write loan is live
```

(misc/chan_task_hview), where `take(ch: !Chan[Int])` with `recv`
instead is accepted (chan_task_vview).

**Actor value views.** `w: !Actor[Counter] = !a` and
`fun peek(a: ?Actor[Counter])` are accepted as types, and every call
through them is refused with "no method `count` on type `Actor`"
(actor/w_type, w_param, misc/actor_rparam, actor_wview_bind). Functions
take `?*Actor` or `!*Actor`, and `!*Actor` is ordinary:
`t = bump(!a)&` then `peek(?a)` is refused (misc/actor_hparam).

**What crosses tasks.** Every member's handle (`+x`), read view (`?x`)
and write view (`!x`) may be given to a task (cross/*). `rig check
--tasks` shows which tasks are local:

| Given to a task | Runs |
|---|---|
| `*Cell[Int]`, `*Actor[T]`, `*Chan[List[Int]]`, `*shared.Map`, a word-Cell `*Hits` | any core |
| `*Cell[List[Int]]` (by `+c`, `?c`, or `!c`), `*Signal[Int]`, `*Log` holding a `List` or a `Cell[List]` | local, pinned to its maker's thread |
| `*Chan[?String]` | refused at the type: "a channel's values hold no loan" |

So crossing changes where a task runs, not what the read-only state
allows. It is sound because nothing gives a view *into* a Cell's
contents: `for x in c`, `for x in ?c` and `sum(?c)` with `sum(xs: []Int)`
on a `*Cell[List[Int]]` are refused (cell/for_push, for_view_push,
slice_push). A local task reading `c.len` in a loop while its maker
pushes 100 values runs and passes all seeds (cross/v_cell_list; seeds
"local task with a write view of a list cell").

## Question 2: is "read-only" true for each?

With a view alive, for each of Cell, Signal, channel, actor, `*Hits`,
`shared.Map`:

| Act on the handle | Under `?x` | Under a write view of the value |
|---|---|---|
| read (`get`, `len`, a field, a `?@` call) | accepted | accepted |
| another read view `?x` | accepted | accepted |
| `+x`, another handle | accepted | accepted |
| a marked call `!x.m()`, another write view | accepted | accepted |
| reassign `x = ...` | refused | refused |
| move `<x` | refused | refused |
| drop `<x` | refused | refused |
| `!x` as the handle (`!*T`) | refused | refused |

So "the handle is read-only, and the value changes only through its own
calls" is true for each, with three precisions:

- **Copied** means `+x`, a new handle; a bare copy of a handle is
  refused everywhere, so the docs should say "read, given another handle,
  and given views".
- **Its own calls** include the methods of a user type: through a
  `!Hits`, `w.step = 3` is refused (misc/hits_wfield), so a write view of
  a Cell object changes only its Cells, through its methods.
- **For an actor**, "its own calls" run on the actor, one at a time, and
  are reached only through a handle, never through `?Actor[T]` or
  `!Actor[T]`.

`shared.Map` meets it by declaration: `r = ?m.get(1)` lives across
`!m.put_new(2, ...)` (map/get_put, s_get_put), `a = !m.ensure(5, ...)`
of a `String` keeps `m` read-only while `a` lives (s_ensure_put,
s_ensure_assign), and an `Int` result copied out keeps nothing
(ensure_assign).

## Question 4: the messages

**The two forms fit every conflict rejection**, member by member:

| Case | Today | Proposed, and true? |
|---|---|---|
| reassign under `r = ?c` (all members) | cannot reassign `c` while it is lent; note `c` lent to read here | cannot reassign `c` while a read view of it is still in use: true |
| reassign/move/drop under `w: !Cell = !c`, `(!h).bump()&`, `!m.ensure`, a select arm | ... while it is lent; note **`c` lent to read here** at `!c` | cannot reassign `c` while a **write** view of it is still in use; note "a write view of `c` is made here": true, but only if the checker names the sigil |
| `grow(!c)` in an arm, `(!a).add(grow(!a))` | cannot lend `c` to write while a read loan is live | see below |
| untyped `w = !c`, then `c.get()` | use of `c` while a write loan is live | cannot use `c` while a write view of it is still in use: true; needs a note that `w = !c` views the handle (Q3) |

`noteLoan` (src/ownership.zig:1390) prints `@tagName(loan.kind)`, and a
marked write view records `kind = .read` (`sema.loanOfView`), so a
straight rename would print "a read view of `c` is made here" under the
`!` of `!c.set(5)`. That is false. The loan record needs the sigil (or a
`marked` flag) beside its kind.

**Taking the handle's own write view.** For an ordinary value,
"cannot change `v` while ..." is right. For the Cell kind it reads false
next to an accepted `!c.set(5)` on the line above: the act refused is
`!c` as a `!*Cell`, which may reassign `c`. Say that: "cannot take a
write view of the handle `c` (a `!*Cell[Int]`, which may reassign it)
while a read view of it is still in use".

**"Still used here"** needs two sites that are not names: for a task,
the `>t`, or the end of the block where `t` drops ("`t` is dropped here,
at the end of the block, and waits for the task"); for a select arm, the
`task.select` call.

**Messages outside the two forms that still say lend or loan, or say
something false:**

1. "cannot lend to write through a read view `?*Chan[Int]`; take a write
   view, or share a handle of your own with `+h`" (all members): say
   "cannot change a `Chan` through a read view `?*Chan[Int]`".
2. "a method an actor runs takes no write view: `!xs` lends `xs` to
   write" (misc/actor_arg_wview).
3. "a channel's values hold no loan, and a `?String` may hold a view"
   (cross/h_chan_view): say "hold no view".
4. "`m.get(1)` keeps `m` lent while `r` lives; write `?m.get(1)`"
   (map/get_* before the fix).
5. "an arm on a task's end lends the task to read" (SPEC).
6. False: "a task runs a call of a function or a method: `f(x)&`,
   `(!v).m(x)&`" for `(!c).add(1)&`, which is that shape. Say a Cell's,
   Signal's, or channel's own method is not made a task.
7. False-sounding: "`w` is a `!Chan[Int]`, not a channel" for a write
   view of a channel.
8. False: "cannot assign through a shared handle (`*T`)" for
   `w.step = 3` with `w: !Hits`, which is a write view, not a handle.
9. `rig check --tasks` says `fill(!c)&` with `fill(c: !Cell[List[Int]])`
   "views a `!*Cell[List[Int]]`", the handle view, the one that makes
   `c` unusable. Also "this task is lent to write, and keeps its write
   loan" (the first try at task/hits_return, `h.bump()&` through a
   `!Hits`).

## For the owner

1. **Keep one rule**, and in CORE §9 (or §4) say what a view lasts for
   the three special uses: a task of a call through a Cell-kind value
   keeps its view until waited for or dropped, the end of its block
   included; an actor's call made a task holds a handle of its own and
   keeps no view; a select arm's view lasts until the select returns.
   Default: yes.
2. **A select arm through a `!Chan[T]`**: accept it, so a channel's
   value view does what its handle does and a task that selects can
   leave the caller's handle read-only. Default: accept (one rule, no
   exception); the alternative is to document "an arm takes a handle".
3. **`?Actor[T]` and `!Actor[T]`**: refuse them as types, with "an actor
   is reached through its handle: `?*Actor[T]`, or `+a`", since they
   accept nothing today. Default: refuse. Making them callable is the
   other choice, larger.
4. **Messages**: name the view by its sigil (needs the loan record to
   carry it), use "take a write view of the handle" for `!*T` of the
   Cell kind, and fix items 1 to 9 above in the same PR. Default: yes.

## Appendix: every program and its output

Each case: the program, then `REJECT` with the diagnostics (file name
removed), or `ACCEPT` and its run output. A `*.rig` with `test` blocks
ran under `rig test --seeds=20`. `signal/cb_self.rig`'s leak report is
the strong-capture cycle SPEC's Signal section warns of, not a finding.

#### `cell/for_push.rig`

```rig
sub main()
  c = *Cell(List[Int]())
  !c.push(1)
  for x in c
    !c.push(x)
  print(c.len)
```

```text
REJECT
4:12: error: cannot iterate over `*Cell[List[Int]]`; a `for` source must be a range `a..b`, an array, a `?String`, a `List`, or an iterator (a type with `next(!@) -> T?`)
```

#### `cell/for_view_push.rig`

```rig
sub main()
  c = *Cell(List[Int]())
  !c.push(1)
  r = ?c
  for x in r
    !c.push(x)
  print(c.len)
```

```text
REJECT
5:12: error: cannot iterate over `?*Cell[List[Int]]`; a `for` source must be a range `a..b`, an array, a `?String`, a `List`, or an iterator (a type with `next(!@) -> T?`)
```

#### `cell/r_assign.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  r = ?c
  c = *Cell(2)
  print(r.get())
```

```text
REJECT
7:3: error: cannot reassign `c` while it is lent
6:8:   note: `c` lent to read here
```

#### `cell/r_call.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  r = ?c
  !c.set(5)
  print(r.get())
```

```text
ACCEPT; run:
5
```

#### `cell/r_clone.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  r = ?c
  d = +c
  !d.set(6)
  print(r.get())
```

```text
ACCEPT; run:
6
```

#### `cell/r_drop.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  r = ?c
  <c
  print(r.get())
```

```text
REJECT
7:4: error: cannot drop `c` while it is lent
6:8:   note: `c` lent to read here
```

#### `cell/r_handle.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  r = ?c
  reset(!c)
  print(r.get())
```

```text
REJECT
7:10: error: cannot lend `c` to write while a read loan is live
6:8:   note: `c` lent to read here
```

#### `cell/r_move.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  r = ?c
  d = <c
  print(r.get(), d.get())
```

```text
REJECT
7:8: error: cannot move `c` while a read loan is live
6:8:   note: `c` lent to read here
```

#### `cell/r_read.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  r = ?c
  print(c.get())
  print(r.get())
```

```text
ACCEPT; run:
1
1
```

#### `cell/r_view.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  r = ?c
  s = ?c
  print(s.get(), r.get())
```

```text
ACCEPT; run:
1 1
```

#### `cell/slice_push.rig`

```rig
fun sum(xs: []Int) -> Int
  n = 0
  for x in xs
    n += x
  n

sub main()
  c = *Cell(List[Int]())
  !c.push(1)
  print(sum(?c))
```

```text
REJECT
10:13: error: type mismatch: expected `[]Int`, got `?*Cell[List[Int]]`
```

#### `cell/u_read.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w = !c
  print(c.get())
  w = *Cell(9)
```

```text
REJECT
7:9: error: use of `c` while a write loan is live
6:8:   note: `c` lent to write here
```

#### `cell/w_assign.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  c = *Cell(2)
  !w.set(3)
```

```text
REJECT
7:3: error: cannot reassign `c` while it is lent
6:20:   note: `c` lent to read here
```

#### `cell/w_call.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  !c.set(4)
  !w.add(1)
  print(c.get())
```

```text
ACCEPT; run:
5
```

#### `cell/w_clone.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  d = +c
  !w.set(3)
  print(d.get())
```

```text
ACCEPT; run:
3
```

#### `cell/w_drop.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  <c
  !w.set(3)
```

```text
REJECT
7:4: error: cannot drop `c` while it is lent
6:20:   note: `c` lent to read here
```

#### `cell/w_handle.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  reset(!c)
  !w.set(3)
```

```text
REJECT
7:10: error: cannot lend `c` to write while a read loan is live
6:20:   note: `c` lent to read here
```

#### `cell/w_move.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  d = <c
  !w.set(3)
  print(d.get())
```

```text
REJECT
7:8: error: cannot move `c` while a read loan is live
6:20:   note: `c` lent to read here
```

#### `cell/w_read.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  print(c.get())
  !w.set(3)
  print(w.get())
```

```text
ACCEPT; run:
1
3
```

#### `cell/w_two.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  v: !Cell[Int] = !c
  !w.add(1)
  !v.add(1)
  print(c.get())
```

```text
ACCEPT; run:
3
```

#### `cell/w_view.rig`

```rig
sub reset(h: !*Cell[Int])
  h = *Cell(0)

sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  s = ?c
  !w.set(3)
  print(s.get())
```

```text
ACCEPT; run:
3
```

#### `signal/cb_self.rig`

```rig
sub main()
  c: *Signal[Int] = *Signal(1)
  r = ?c
  !c.subscribe(*|+c| print("cb", c.get()))
  !c.set(2)
  print(r.get())
```

```text
ACCEPT; run:
cb 2
2
error: rig: memory leak detected: 4 allocations (152 bytes) never freed
note: build with RIG_LEAK_TRACE=1 set (`RIG_LEAK_TRACE=1 rig run ...`) to see where each was allocated
```

#### `signal/r_assign.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  r = ?c
  c = *Signal(2)
  print(r.get())
```

```text
REJECT
7:3: error: cannot reassign `c` while it is lent
6:8:   note: `c` lent to read here
```

#### `signal/r_call.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  r = ?c
  !c.set(5)
  print(r.get())
```

```text
ACCEPT; run:
5
```

#### `signal/r_handle.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  r = ?c
  reset(!c)
  print(r.get())
```

```text
REJECT
7:10: error: cannot lend `c` to write while a read loan is live
6:8:   note: `c` lent to read here
```

#### `signal/r_move.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  r = ?c
  d = <c
  print(r.get(), d.get())
```

```text
REJECT
7:8: error: cannot move `c` while a read loan is live
6:8:   note: `c` lent to read here
```

#### `signal/r_sub.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  r = ?c
  !c.subscribe(*|| print("cb"))
  !c.set(2)
  print(r.get())
```

```text
ACCEPT; run:
cb
2
```

#### `signal/u_read.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  w = !c
  print(c.get())
  w = *Signal(9)
```

```text
REJECT
7:9: error: use of `c` while a write loan is live
6:8:   note: `c` lent to write here
```

#### `signal/w_assign.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  w: !Signal[Int] = !c
  c = *Signal(2)
  !w.set(3)
```

```text
REJECT
7:3: error: cannot reassign `c` while it is lent
6:22:   note: `c` lent to read here
```

#### `signal/w_call.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  w: !Signal[Int] = !c
  !c.set(4)
  !w.set(5)
  print(c.get())
```

```text
ACCEPT; run:
5
```

#### `signal/w_drop.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  w: !Signal[Int] = !c
  <c
  !w.set(3)
```

```text
REJECT
7:4: error: cannot drop `c` while it is lent
6:22:   note: `c` lent to read here
```

#### `signal/w_handle.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  w: !Signal[Int] = !c
  reset(!c)
  !w.set(3)
```

```text
REJECT
7:10: error: cannot lend `c` to write while a read loan is live
6:22:   note: `c` lent to read here
```

#### `signal/w_read.rig`

```rig
sub reset(h: !*Signal[Int])
  h = *Signal(0)

sub main()
  c: *Signal[Int] = *Signal(1)
  w: !Signal[Int] = !c
  print(c.get())
  !w.set(3)
  print(w.get(), c.get())
```

```text
ACCEPT; run:
1
3 3
```

#### `chan/p_hparam.rig`

```rig
use std.task

sub take(ch: !*Chan[Int])!
  !ch.send(1)!
  match task.select(got: !ch.on_recv())!
    .got(v?) => print("got", v)
    .got(none) => print("closed")

sub main()!
  c = *Chan[Int](2)
  take(!c)!
```

```text
ACCEPT; run:
got 1
```

#### `chan/p_wparam.rig`

```rig
use std.task

sub take(ch: !Chan[Int])!
  !ch.send(1)!
  match task.select(got: !ch.on_recv())!
    .got(v?) => print("got", v)
    .got(none) => print("closed")

sub main()!
  c = *Chan[Int](2)
  take(!c)!
```

```text
REJECT
5:27: error: `ch` is a `!Chan[Int]`, not a channel; each arm of `task.select` is `name: !ch.on_recv()`, `name: !ch.on_send(<v)`, `name: ?t.on_end()`, or `name: time.after(ms: 50)`
```

#### `chan/r_assign.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  r = ?c
  c = *Chan[Int](1)
  _ = r
```

```text
REJECT
9:3: error: cannot reassign `c` while it is lent
8:8:   note: `c` lent to read here
```

#### `chan/r_handle.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  r = ?c
  reset(!c)
  _ = r
```

```text
REJECT
9:10: error: cannot lend `c` to write while a read loan is live
8:8:   note: `c` lent to read here
```

#### `chan/r_send.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  r = ?c
  !c.send(5)!
  print(!c.recv()! ?? -1)
  _ = r
```

```text
ACCEPT; run:
5
```

#### `chan/s_arm_assign.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

fun grow(h: !*Chan[Int]) -> Int
  h = *Chan[Int](1)
  1

sub main()!
  c = *Chan[Int](2)
  !c.send(7)!
  match task.select(got: !c.on_recv(), put: !c.on_send(grow(!c)))!
    .got(v?) => print("got", v)
    .got(none) => print("closed")
    .put => print("put")
```

```text
REJECT
13:62: error: cannot lend `c` to write while a read loan is live
13:27:   note: `c` lent to read here
```

#### `chan/s_arm_read.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  !c.send(7)!
  r = ?c
  match task.select(got: !c.on_recv())!
    .got(v?) => print("got", v)
    .got(none) => print("closed")
  _ = r
```

```text
ACCEPT; run:
got 7
```

#### `chan/s_body_assign.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  !c.send(7)!
  match task.select(got: !c.on_recv())!
    .got(v?)
      c = *Chan[Int](1)
      print("got", v)
    .got(none) => print("closed")
```

```text
ACCEPT; run:
got 7
```

#### `chan/s_bound_later.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  !c.send(7)!
  s = task.select(got: !c.on_recv())!
  c = *Chan[Int](1)
  <c
  match s
    .got(v?) => print("got", v)
    .got(none) => print("closed")
```

```text
ACCEPT; run:
got 7
```

#### `chan/s_two.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  !c.send(7)!
  match task.select(got: !c.on_recv(), put: !c.on_send(8))!
    .got(v?) => print("got", v)
    .got(none) => print("closed")
    .put => print("put")
```

```text
ACCEPT; run:
put
```

#### `chan/s_view_arm.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  r = ?c
  !c.send(7)!
  match task.select(got: !r.on_recv())!
    .got(v?) => print("got", v)
    .got(none) => print("closed")
```

```text
REJECT
10:27: error: cannot lend to write through a read view `?*Chan[Int]`; take a write view, or share a handle of your own with `+h`
```

#### `chan/s_wview_arm.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  w: !Chan[Int] = !c
  !c.send(7)!
  match task.select(got: !w.on_recv(), put: !c.on_send(1))!
    .got(v?) => print("got", v)
    .got(none) => print("closed")
    .put => print("put")
```

```text
REJECT
10:27: error: `w` is a `!Chan[Int]`, not a channel; each arm of `task.select` is `name: !ch.on_recv()`, `name: !ch.on_send(<v)`, `name: ?t.on_end()`, or `name: time.after(ms: 50)`
```

#### `chan/t_send_task.rig`

```rig
sub main()!
  c = *Chan[Int](2)
  t = !c.send(1)&
  c = *Chan[Int](1)
  >t!
```

```text
REJECT
3:8: error: a task runs a call of a function or a method: `f(x)&`, `(!v).m(x)&`
```

#### `chan/t_send_task_read.rig`

```rig
sub main()!
  c = *Chan[Int](2)
  t = !c.send(1)&
  !c.send(2)!
  >t!
  print(!c.recv()! ?? -1)
```

```text
REJECT
3:8: error: a task runs a call of a function or a method: `f(x)&`, `(!v).m(x)&`
```

#### `chan/w_assign.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  w: !Chan[Int] = !c
  c = *Chan[Int](1)
  !w.send(3)!
```

```text
REJECT
9:3: error: cannot reassign `c` while it is lent
8:20:   note: `c` lent to read here
```

#### `chan/w_move.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  w: !Chan[Int] = !c
  d = <c
  !w.send(3)!
  print(!d.recv()! ?? -1)
```

```text
REJECT
9:8: error: cannot move `c` while a read loan is live
8:20:   note: `c` lent to read here
```

#### `chan/w_type.rig`

```rig
use std.task

sub reset(h: !*Chan[Int])
  h = *Chan[Int](1)

sub main()!
  c = *Chan[Int](2)
  w: !Chan[Int] = !c
  !w.send(1)!
  !c.send(2)!
  print(!c.recv()! ?? -1, !w.recv()! ?? -1)
```

```text
ACCEPT; run:
1 2
```

#### `actor/call_reassign_arg.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

fun grow(h: !*Actor[Counter]) -> Int
  h = *Actor(Counter(n: 100))
  1

sub main()
  a = *Actor(Counter(n: 1))
  print((!a).add(grow(!a)))
```

```text
REJECT
20:24: error: cannot lend `a` to write while a read loan is live
20:11:   note: `a` lent to read here
```

#### `actor/nest.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  print((!a).add((!a).add(1)))
```

```text
ACCEPT; run:
4
```

#### `actor/r_assign.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  r = ?a
  a = *Actor(Counter(n: 2))
  print(r.count())
```

```text
REJECT
17:3: error: cannot reassign `a` while it is lent
16:8:   note: `a` lent to read here
```

#### `actor/r_call.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  r = ?a
  !a.add(1)
  print(r.count())
```

```text
ACCEPT; run:
2
```

#### `actor/r_handle.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  r = ?a
  reset(!a)
  print(r.count())
```

```text
REJECT
17:10: error: cannot lend `a` to write while a read loan is live
16:8:   note: `a` lent to read here
```

#### `actor/r_move.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  r = ?a
  b = <a
  print(r.count(), b.count())
```

```text
REJECT
17:8: error: cannot move `a` while a read loan is live
16:8:   note: `a` lent to read here
```

#### `actor/rview_task.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  r = ?a
  t = !r.add(1)&
  print(>t)
```

```text
REJECT
17:8: error: cannot lend to write through a read view `?*Actor[Counter]`; take a write view, or share a handle of your own with `+h`
```

#### `actor/t_assign.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  t = !a.add(1)&
  a = *Actor(Counter(n: 5))
  print(>t, a.count())
```

```text
ACCEPT; run:
2 5
```

#### `actor/t_drop.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  t = !a.add(1)&
  <a
  print(>t)
```

```text
ACCEPT; run:
2
```

#### `actor/t_handle.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  t = !a.add(1)&
  reset(!a)
  print(>t, a.count())
```

```text
ACCEPT; run:
2 0
```

#### `actor/t_move.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  t = !a.add(1)&
  b = <a
  print(>t, b.count())
```

```text
ACCEPT; run:
2 2
```

#### `actor/t_read.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  t = a.count()&
  a = *Actor(Counter(n: 5))
  print(>t)
```

```text
ACCEPT; run:
1
```

#### `actor/w_param.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

fun bump(w: !Actor[Counter]) -> Int
  (!w).add(1)

sub main()
  a = *Actor(Counter(n: 1))
  print(bump(!a), a.count())
```

```text
REJECT
15:8: error: no method `add` on type `Actor`
```

#### `actor/w_type.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

sub reset(h: !*Actor[Counter])
  h = *Actor(Counter(n: 0))

sub main()
  a = *Actor(Counter(n: 1))
  w: !Actor[Counter] = !a
  !w.add(1)
  print(a.count())
```

```text
REJECT
17:6: error: no method `add` on type `Actor`
```

#### `task/cell_add.rig`

```rig
sub main()
  c = *Cell(1)
  t = (!c).add(1)&
  print(>t)
```

```text
REJECT
3:7: error: a task runs a call of a function or a method: `f(x)&`, `(!v).m(x)&`
```

#### `task/chan_send.rig`

```rig
sub main()!
  c = *Chan[Int](2)
  t = (!c).send(1)&
  >t!
  print(!c.recv()! ?? -1)
```

```text
REJECT
3:7: error: a task runs a call of a function or a method: `f(x)&`, `(!v).m(x)&`
```

#### `task/hits_assign.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

  fun peek(?@) -> Int
    @n.get()

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  h = *Hits(n: Cell(5), step: 1)
  print(>t)
```

```text
REJECT
14:3: error: cannot reassign `h` while it is lent
13:9:   note: `h` lent to read here
```

#### `task/hits_drop.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

  fun peek(?@) -> Int
    @n.get()

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  g = +h
  <h
  print(>t, g.step)
```

```text
REJECT
15:4: error: cannot drop `h` while it is lent
13:9:   note: `h` lent to read here
```

#### `task/hits_dropped_then.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  <t
  h = *Hits(n: Cell(5), step: 1)
  print(h.step)
```

```text
ACCEPT; run:
1
```

#### `task/hits_joined_then.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  print(>t)
  h = *Hits(n: Cell(5), step: 1)
  print(h.step)
```

```text
ACCEPT; run:
2
1
```

#### `task/hits_move.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

  fun peek(?@) -> Int
    @n.get()

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  g = <h
  print(>t, g.step)
```

```text
REJECT
14:8: error: cannot move `h` while a read loan is live
13:9:   note: `h` lent to read here
```

#### `task/hits_nojoin.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

  fun peek(?@) -> Int
    @n.get()

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  print(h.step)
```

```text
ACCEPT; run:
2
```

#### `task/hits_read_call.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

  fun peek(?@) -> Int
    @n.get()

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  print(h.step, h.peek())
  !h.bump()
  r = ?h
  print(>t > 0, r.n.get())
```

```text
ACCEPT; run:
2 0
true 4
```

#### `task/hits_return.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

  fun peek(?@) -> Int
    @n.get()

fun start(h: !Hits) -> Task[Int] from h
  (!h).bump()&

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = start(!h)
  print(h.step)
  print(>t)
```

```text
ACCEPT; run:
2
2
```

#### `task/hits_return2.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

  fun peek(?@) -> Int
    @n.get()

fun start(h: !*Hits) -> Task[Int] from h
  (!h).bump()&

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = start(!h)
  print(h.step)
  print(>t)
```

```text
ACCEPT; run:
2
2
```

#### `task/hits_set.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

sub main()
  h = *Hits(n: Cell(0), step: 2)
  ts = Tasks[Int]()
  !ts.add((!h).bump()&)
  h = *Hits(n: Cell(9), step: 1)
  for r in >ts
    print(r)
```

```text
REJECT
12:3: error: cannot reassign `h` while it is lent
11:13:   note: `h` lent to read here
```

#### `task/hits_two_tasks.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

  fun peek(?@) -> Int
    @n.get()

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  u = (!h).bump()&
  print(>t + >u, h.n.get())
```

```text
ACCEPT; run:
6 4
```

#### `task/hits_unmentioned.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

sub main()
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  h = *Hits(n: Cell(5), step: 1)
  print(h.step)
```

```text
REJECT
11:3: error: cannot reassign `h` while it is lent
10:9:   note: `h` lent to read here
```

#### `task/hits_wparam_task.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

fun run(h: !Hits) -> Int
  t = (!h).bump()&
  u = (!h).bump()&
  print(h.step)
  >t + >u

sub main()
  h = *Hits(n: Cell(0), step: 2)
  print(run(!h))
```

```text
ACCEPT; run:
2
6
```

#### `task/list_task.rig`

```rig
sub main()
  xs = List[Int]()
  t = (!xs).push(1)&
  print(xs.len)
  >t
```

```text
REJECT
3:7: error: a task runs a call of a function or a method: `f(x)&`, `(!v).m(x)&`
```

#### `task/list_task_unmentioned.rig`

```rig
sub fill(xs: !List[Int])
  !xs.push(1)

sub main()
  xs = List[Int]()
  t = fill(!xs)&
  print(xs.len)
```

```text
REJECT
7:9: error: use of `xs` while a write loan is live
6:13:   note: `xs` lent to write here
```

#### `task/sig_set.rig`

```rig
sub main()
  c: *Signal[Int] = *Signal(1)
  t = (!c).set(2)&
  >t
```

```text
REJECT
3:7: error: a task runs a call of a function or a method: `f(x)&`, `(!v).m(x)&`
```

#### `map/ensure_assign.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  _ = !m.put_new(1, 10)
  a = !m.ensure(5, 50)
  m = shared.Map[Int, Int].new()
  print(a)
```

```text
ACCEPT; run:
50
```

#### `map/ensure_two.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  _ = !m.put_new(1, 10)
  a = !m.ensure(5, 50)
  b = !m.ensure(6, 60)
  print(a, b, m.len())
```

```text
ACCEPT; run:
50 60 3
```

#### `map/get_assign.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  _ = !m.put_new(1, 10)
  r = ?m.get(1)
  m = shared.Map[Int, Int].new()
  print(r ?? -1)
```

```text
REJECT
7:3: error: cannot reassign `m` while it is lent
6:8:   note: `m` lent to read here
```

#### `map/get_drop.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  _ = !m.put_new(1, 10)
  r = ?m.get(1)
  <m
  print(r ?? -1)
```

```text
REJECT
7:4: error: cannot drop `m` while it is lent
6:8:   note: `m` lent to read here
```

#### `map/get_put.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  _ = !m.put_new(1, 10)
  r = ?m.get(1)
  _ = !m.put_new(2, 20)
  print(r ?? -1, m.len())
```

```text
ACCEPT; run:
10 2
```

#### `map/s_ensure_assign.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, String].new()
  _ = !m.put_new(1, String("ten"))
  a = !m.ensure(5, String("fifty"))
  m = shared.Map[Int, String].new()
  print(a)
```

```text
REJECT
7:3: error: cannot reassign `m` while it is lent
6:8:   note: `m` lent to read here
```

#### `map/s_ensure_put.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, String].new()
  _ = !m.put_new(1, String("ten"))
  a = !m.ensure(5, String("fifty"))
  _ = !m.put_new(2, String("twenty"))
  print(a, m.len())
```

```text
ACCEPT; run:
fifty 3
```

#### `map/s_get_put.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, String].new()
  _ = !m.put_new(1, String("ten"))
  r = ?m.get(1)
  _ = !m.put_new(2, String("twenty"))
  print(r ?? "none", m.len())
```

```text
ACCEPT; run:
ten 2
```

#### `map/w_assign.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  _ = !m.put_new(1, 10)
  w: !shared.Map[Int, Int] = !m
  m = shared.Map[Int, Int].new()
  _ = !w.put_new(3, 30)
```

```text
REJECT
7:3: error: cannot reassign `m` while it is lent
6:31:   note: `m` lent to read here
```

#### `map/w_type.rig`

```rig
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  _ = !m.put_new(1, 10)
  w: !shared.Map[Int, Int] = !m
  _ = !m.put_new(2, 20)
  _ = !w.put_new(3, 30)
  print(m.len(), w.len())
```

```text
ACCEPT; run:
3 3
```

#### `cross/h_actor.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

sub work(a: *Actor[Counter])
  _ = !a.add(1)

sub main()
  a = *Actor(Counter(n: 0))
  t = work(+a)&
  u = work(+a)&
  >t
  >u
  print((!a).add(0))
```

```text
ACCEPT; run:
2
```

#### `cross/h_cell_int.rig`

```rig
sub work(c: *Cell[Int])
  for 0..100
    !c.add(1)

sub main()
  c = *Cell(0)
  t = work(+c)&
  u = work(+c)&
  >t
  >u
  print(c.get())
```

```text
ACCEPT; run:
200
```

#### `cross/h_cell_list.rig`

```rig
sub work(c: *Cell[List[Int]])
  !c.push(1)

sub main()
  c = *Cell(List[Int]())
  t = work(+c)&
  >t
  print(c.len)
```

```text
ACCEPT; run:
1
```

#### `cross/h_chan_list.rig`

```rig
sub work(c: *Chan[List[Int]])!
  !c.send(List[Int]())!

sub main()!
  c = *Chan[List[Int]](1)
  t = work(+c)&
  print((!c.recv()! ?? List[Int]()).len)
  >t!
```

```text
ACCEPT; run:
0
```

#### `cross/h_chan_view.rig`

```rig
sub work(c: *Chan[?String])!
  !c.send("x")!

sub main()!
  c = *Chan[?String](1)
  t = work(+c)&
  >t!
```

```text
REJECT
5:8: error: a channel's values hold no loan, and a `?String` may hold a view
```

#### `cross/h_hits_list.rig`

```rig
obj Log
  n: Cell[Int]
  xs: List[Int]

  fun bump(!@) -> Int
    !@n.add(1)

sub work(h: *Log)
  _ = !h.bump()

sub main()
  h = *Log(n: Cell(0), xs: List[Int]())
  t = work(+h)&
  >t
```

```text
ACCEPT; run:
```

#### `cross/h_map.rig`

```rig
use std.shared

sub work(m: *shared.Map[Int, Int], k: Int)
  _ = !m.put_new(k, k)

sub main()
  m = shared.Map[Int, Int].new()
  t = work(+m, 1)&
  u = work(+m, 2)&
  >t
  >u
  print(m.len())
```

```text
ACCEPT; run:
2
```

#### `cross/h_signal.rig`

```rig
sub work(s: *Signal[Int])
  !s.set(1)

sub main()
  s: *Signal[Int] = *Signal(0)
  t = work(+s)&
  >t
  print(s.get())
```

```text
ACCEPT; run:
1
```

#### `cross/v_cell_list.rig`

```rig
fun peek(c: ?Cell[List[Int]]) -> Int
  n = 0
  for 0..100
    n += c.len
  n

sub main()
  c = *Cell(List[Int]())
  t = peek(?c)&
  for i in 0..100
    !c.push(i)
  print(>t >= 0, c.len)
```

```text
ACCEPT; run:
true 100
```

#### `cross/v_cell_list_h.rig`

```rig
fun peek(c: ?*Cell[List[Int]]) -> Int
  n = 0
  for 0..100
    n += c.len
  n

sub main()
  c = *Cell(List[Int]())
  t = peek(?c)&
  for i in 0..100
    !c.push(i)
  print(>t >= 0, c.len)
```

```text
ACCEPT; run:
true 100
```

#### `cross/v_map.rig`

```rig
use std.shared

fun look(m: ?shared.Map[Int, Int]) -> Int
  m.get(1) ?? -1

sub main()
  m = shared.Map[Int, Int].new()
  _ = !m.put_new(1, 10)
  r = m.get(1) ?? -1
  t = look(?m)&
  _ = !m.put_new(2, 20)
  print(>t, r, m.len())
```

```text
ACCEPT; run:
10 10 2
```

#### `cross/w_cell_list.rig`

```rig
sub fill(c: !Cell[List[Int]])
  for i in 0..100
    !c.push(i)

sub main()
  c = *Cell(List[Int]())
  t = fill(!c)&
  for i in 0..100
    !c.push(i)
  >t
  print(c.len)
```

```text
ACCEPT; run:
200
```

#### `cross/w_hits_celllist.rig`

```rig
obj Log
  xs: Cell[List[Int]]

  fun add(!@, i: Int) -> Int
    !@xs.push(i)
    @xs.len

sub main()
  h = *Log(xs: Cell(List[Int]()))
  t = (!h).add(1)&
  u = (!h).add(2)&
  for i in 0..100
    !h.add(i)
  print(>t + >u > 0, h.xs.len)
```

```text
ACCEPT; run:
true 102
```

#### `cross/w_hits_list.rig`

```rig
obj Log
  n: Cell[Int]
  xs: List[Int]

  fun bump(!@) -> Int
    !@n.add(1)

sub main()
  h = *Log(n: Cell(0), xs: List[Int]())
  t = (!h).bump()&
  u = (!h).bump()&
  print(>t + >u)
```

```text
ACCEPT; run:
3
```

#### `cross/w_signal.rig`

```rig
sub work(s: !Signal[Int])
  !s.set(1)

sub main()
  s: *Signal[Int] = *Signal(0)
  !s.subscribe(*|| print("cb"))
  t = work(!s)&
  !s.set(2)
  >t
  print(s.get())
```

```text
ACCEPT; run:
cb
cb
1
```

#### `misc/actor_arg_rview_task.rig`

```rig
obj Counter
  n: Int

  fun size(!@, s: ?String) -> Int
    @n += s.len
    @n

sub main()
  a = *Actor(Counter(n: 4))
  s = String("abc")
  t = !a.size(?s)&
  !s.push("d")
  print(>t)
```

```text
REJECT
12:3: error: cannot lend `s` to write while a read loan is live
11:15:   note: `s` lent to read here
```

#### `misc/actor_arg_wview.rig`

```rig
obj Counter
  n: Int

  sub take(!@, xs: !List[Int])
    !xs.push(@n)

sub main()
  a = *Actor(Counter(n: 4))
  xs = List[Int]()
  !a.take(!xs)
```

```text
REJECT
10:11: error: a method an actor runs takes no write view: `!xs` lends `xs` to write
```

#### `misc/actor_hparam.rig`

```rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

fun peek(a: ?*Actor[Counter]) -> Int
  a.count()

fun bump(a: !*Actor[Counter]) -> Int
  (!a).add(1)

sub main()
  a = *Actor(Counter(n: 4))
  t = bump(!a)&
  print(peek(?a))
  print(>t)
```

```text
REJECT
20:15: error: cannot lend `a` to read while a write loan is live
19:13:   note: `a` lent to write here
```

#### `misc/actor_rparam.rig`

```rig
obj Counter
  n: Int

  fun count(?@) -> Int
    @n

fun peek(a: ?Actor[Counter]) -> Int
  a.count()

sub main()
  a = *Actor(Counter(n: 4))
  print(peek(?a))
```

```text
REJECT
8:5: error: no method `count` on type `Actor`
```

#### `misc/actor_wview_bind.rig`

```rig
obj Counter
  n: Int

  fun count(?@) -> Int
    @n

sub main()
  a = *Actor(Counter(n: 4))
  w: !Actor[Counter] = !a
  print(w.count(), a.count())
  a = *Actor(Counter(n: 1))
```

```text
REJECT
10:11: error: no method `count` on type `Actor`
```

#### `misc/chan_task_hview.rig`

```rig
use std.task

sub take(ch: !*Chan[Int])!
  match task.select(got: !ch.on_recv())!
    .got(v?) => print("got", v)
    .got(none) => print("closed")

sub main()!
  c = *Chan[Int](2)
  t = take(!c)&
  !c.send(1)!
  >t!
```

```text
REJECT
11:4: error: use of `c` while a write loan is live
10:13:   note: `c` lent to write here
```

#### `misc/chan_task_vview.rig`

```rig
sub take(ch: !Chan[Int])!
  print("got", !ch.recv()! ?? -1)

sub main()!
  c = *Chan[Int](2)
  t = take(!c)&
  !c.send(1)!
  >t!
```

```text
ACCEPT; run:
got 1
```

#### `misc/hits_wfield.rig`

```rig
obj Hits
  n: Cell[Int]
  step: Int

sub main()
  h = *Hits(n: Cell(0), step: 2)
  w: !Hits = !h
  w.step = 3
  print(h.step)
```

```text
REJECT
8:3: error: cannot assign through a shared handle (`*T`); other handles may exist. To change a value that handles share, hold it in a `Cell[T]`.
```

#### `misc/task_onend_assign.rig`

```rig
use std.task

fun nine() -> Int
  9

sub main()!
  t = nine()&
  match task.select(done: ?t.on_end())!
    .done
      t = nine()&
      print(>t)
```

```text
ACCEPT; run:
9
```

#### `seeds/concurrency.rig`, run with `rig test --seeds=20`

```rig
use std.task
use std.shared

obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

  fun count(?@) -> Int
    @n

obj Hits
  n: Cell[Int]
  step: Int

  fun bump(!@) -> Int
    !@n.add(@step)

obj Log
  xs: Cell[List[Int]]

  fun add(!@, i: Int) -> Int
    !@xs.push(i)
    @xs.len

sub work(c: *Cell[Int])
  for 0..100
    !c.add(1)

sub fill(c: !Cell[List[Int]])
  for i in 0..50
    !c.push(i)

sub put(m: *shared.Map[Int, Int], k: Int)
  _ = !m.put_new(k, k)

sub produce(ch: *Chan[Int], n: Int)!
  for i in 0..n
    !ch.send(i)!
  !ch.close()

test "actor call task keeps no view: handle reassigned while it runs"
  a = *Actor(Counter(n: 0))
  t = !a.add(1)&
  a = *Actor(Counter(n: 5))
  >t == 1 and a.count() == 5

test "actor call task keeps no view: handle dropped while it runs"
  a = *Actor(Counter(n: 0))
  b = +a
  t = !a.add(1)&
  <a
  >t == 1 and b.count() == 1

test "hits tasks hold self read-only; marked calls go on meanwhile"
  h = *Hits(n: Cell(0), step: 2)
  t = (!h).bump()&
  u = (!h).bump()&
  for 0..10
    _ = !h.bump()
  x = >t
  y = >u
  h.n.get() == 24 and x > 0 and y > 0

test "word cell crosses cores"
  c = *Cell(0)
  ts = Tasks[Void]()
  for 0..8
    !ts.add(work(+c)&)
  >ts
  c.get() == 800

test "local task with a write view of a list cell, pushes meanwhile"
  c = *Cell(List[Int]())
  t = fill(!c)&
  for i in 0..50
    !c.push(i)
  >t
  c.len == 100

test "local method tasks on a list-cell object"
  h = *Log(xs: Cell(List[Int]()))
  t = (!h).add(1)&
  u = (!h).add(2)&
  for i in 0..20
    _ = !h.add(i)
  x = >t
  y = >u
  h.xs.len == 22 and x > 0 and y > 0

test "shared map crosses, views survive puts"
  m = shared.Map[Int, Int].new()
  _ = !m.put_new(0, 0)
  r = ?m.get(0)
  ts = Tasks[Void]()
  for k in 1..9
    !ts.add(put(+m, k)&)
  >ts
  (r ?? -1) == 0 and m.len() == 9

test "select arms on one channel, handle reassigned in a body"
  ch = *Chan[Int](4)
  p = produce(+ch, 5)&
  sum = 0
  open = true
  while open
    match task.select(got: !ch.on_recv())!
      .got(v?) => sum += v
      .got(none) => open = false
  >p!
  ch = *Chan[Int](1)
  !ch.send(1)!
  sum == 10 and (!ch.recv()! ?? 0) == 1
```

```text
exit 0: 160 lines "ok" (8 tests, 20 seeds), each seed ending "8 passed, 0 failed"
```
