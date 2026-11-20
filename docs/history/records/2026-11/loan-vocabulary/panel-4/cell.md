# Panel 4: the Cell kind, audited against the compiler (role: cell)

2026-11-20. Every claim below was run on `~/Data/Code/rig/bin/rig`
(main, 41d245dff, the worktree's commit). The scratch programs are in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/panel4/cell/`;
the outputs are quoted here.

## Verdict

1. **One rule holds for all six members.** Over 180 generated programs
   (six members, three kinds of view, ten acts), Cell, Signal, channel,
   actor, an object holding a Cell, and `shared.Map` give the same verdict
   for every act. The differences the brief lists are about how long a
   view lasts (a call, a task's life, a select, none for an actor's
   task), not about what the view allows. The rule needs no case for any
   member.
2. **"The handle is read-only, and the value changes only through its
   own calls" is true for each member.** While any view of `x` is in use,
   reading `x`, `+x`, `~x`, `?x`, another typed `!x`, and a marked call
   are accepted. Reassigning, moving, dropping, and lending the handle
   itself (`!*T`) are refused. Through a `!Hits`, only its Cells change:
   field writes, moving a Cell out, and replacing the value are all
   refused.
3. **The untyped trap is not one rule; it depends on whether the binding
   can be written.** `w = !c` gives a `!*Cell` only when `c` may be
   written: a local, a `!*Cell` parameter, a field of a local, `@c`, or a
   `for` element over `!cs`. For a `*Cell` parameter, the same text gives
   a `!Cell[Int]` and leaves `c` read-only. `swap(!a, !b)` has the same
   split. I recommend deciding `!h` by the type written where it goes,
   and choosing the value where nothing is written. I patched a scratch
   copy and ran the core suite (§3). Apart from gaps in my own patch,
   the change breaks two things: swapping two Cell handles with
   `swap(!a, !b)` (6 tests), and a generic `!T` inferring the handle
   (1 test).
4. **The new messages read true for every member, but only if the word
   comes from the sigil written, not from the loan the compiler records.**
   For this kind, `!x` records a *read* loan. Today's note says "`x` lent
   to read here" under a `!x`. If PR 2 maps the loan kind to the word, it
   will print "a read view of `x` is made here" under `!x`, which is
   false. The verb for `reseat(!x)` also needs care: "cannot change `x`"
   reads false when `!x.set(5)` just changed it.

Two side findings: a typed `!Actor[T]` can call nothing, and a
`!Chan[T]` can send and receive but cannot be a select arm (§5).

## 1. The matrix (questions 1 and 2)

`gen.py` writes one program for each member × view × act and runs
`rig check` on it. Each program makes a view of `x`, does the act, then
uses the view, so the view is still in use at the act.

Members (setup):

| member | `x` | typed write view | marked call |
|---|---|---|---|
| cell | `*Cell(1)` | `!Cell[Int]` | `!x.set(2)` |
| signal | `*Signal(0)` | `!Signal[Int]` | `!x.set(2)` |
| chan | `*Chan[Int](8)` | `!Chan[Int]` | `!x.send(1)!` |
| actor | `*Actor(Counter(n: 0))` | `!Actor[Counter]` | `_ = !x.add(1)` |
| holder | `*Hits(n: Cell(0), step: 2)` | `!Hits` | `_ = !x.bump()` |
| map | `shared.Map[Int, Int].new()` | `!shared.Map[Int, Int]` | `_ = !x.put_new(1, 2)` |

Views: `read` = `r = ?x`; `wtyped` = `w: !T = !x`; `wuntyped` = `w = !x`.

Acts: `read` (a `?@` call or `.get()`), `clone` (`z = +x`), `readview`
(`peek(?x)`), `mark` (the marked call), `wview` (`w2: !T = !x` then a
marked call through it), `reassign` (`x = *...`), `move` (`z = <x`),
`drop` (`<x`), `lendhandle` (`reseat(!x)`, where `reseat` takes `!*T`
and points it elsewhere), and `weak` (`k = ~x`).

Example (`mx/cell-wtyped-reassign.rig`; the header declares `Counter`,
`Hits`, `peek[T](v: ?T)` and `reseat`):

```rig
sub main()!
  x = *Cell(1)
  y = *Cell(9)
  w: !Cell[Int] = !x
  x = *Cell(3)
  !w.set(4)
  peek(?y)
```

Results (`matrix.txt`, `matrix2.txt`; A = accepted, R = refused):

| act | read view | typed `!T` | untyped `w = !x` |
|---|---|---|---|
| read | A | A | R `use of x while a write loan is live` |
| clone `+x` | A | A | R |
| `?x` | A | A | R |
| marked call | A | A | R |
| another typed `!x` | A | A | R |
| `~x` | A | A | R |
| reassign | R `cannot reassign x while it is lent` | R | R |
| move | R `cannot move x while a read loan is live` | R | R (write loan) |
| drop | R `cannot drop x while it is lent` | R | R |
| `reseat(!x)` | R `cannot lend x to write while a read loan is live` | R | R (write loan) |

All six members fill this table the same way. The one exception is the
actor's typed column, where every program fails first on
`no method add on type Actor` (§5).

(Two harness errors were fixed and rerun. The first `wview` used
`peek(?w2)`, and `peek[T]` with `T = Cell[Int]` is refused because a
Cell is never a type argument by value. The first `weak` used a
nonexistent `k.alive`.)

### The lifetimes differ; the rule does not

- **Nested calls** (`m2.rig`): `!c.add((!c).swap(4))` prints `5`.
- **An in-flight call keeps its view** (`m1.rig`, an actor):
  `print(!a.add(reseat(!a)))` gives "cannot lend `a` to write while a
  read loan is live", with the note at the outer `!a`. Even an actor's
  call holds its handle read-only while the call runs.
- **A task that holds self keeps the view for its life** (`tk/`):
  `t = (!x).bump()&` (holder), `t = (!x).put_new(1, 2)&` (map), and
  `t = bumpc(!x)&` with `bumpc(c: !Cell[Int])` (cell) each refuse a
  later `x = ...` with "cannot reassign `x` while it is lent". The same
  programs accept `+x` and `<y` of the copy. `task-cellfn-ok.rig`, two
  tasks plus `!x.set(10)` while both run, prints `true true true`.
- **An actor's task keeps nothing** (`tk/task-actor.rig`):
  `t = (!x).add(1)&`, then `x = *Actor(Counter(n: 5))`, prints `done`.
  This is the one place where a `!x` leaves no view behind once made.
  It is a count, not a view, which CORE already says.
- **Select** (`sel/`): `!ch.on_recv()` holds `ch` read-only until the
  select returns. `bump(!ch)` inside another arm's argument is refused
  (s1). `ch = *Chan[Int](1)` in an arm's body is accepted (s2, prints
  `got 7`).
- **Built-in calls cannot be tasks**: `(!x).add(1)&` on a Cell gives "a
  task runs a call of a function or a method". So "a task that holds
  self" means a method of an object holding a Cell, of a Map, or of an
  actor. A Cell, Signal, or Chan reaches a task only as an argument.
- **Crossing tasks** (`wc/`): the view rule is the same for a word-Cell
  object and for a Cell of more than one word. Only the scheduling
  differs. `wc1.rig` passes under `rig test --seeds=20` (2 passed). It
  sends eight tasks `work(+h)&`, runs two `(!h).bump()&` tasks, and calls
  `!h.bump()` while they run, giving `r.n.get() == 11`. It also runs two
  `bumpc(!c)&` tasks with `!c.add(1)`, giving 3. `rig check --tasks`
  lists no task in it as local. `wc5.rig` (a `Cell[List[Int]]` viewed by
  a task while main pushes to it) passes under 20 seeds as a local task:
  "`grow(!c)&` is local, pinned to its maker's thread by `!c`".
- **A task holding only a Cell-kind write view may be stored**:
  `!ts.push((!h).bump()&)` is accepted. `!us.push(fill(!xs)&)` with an
  ordinary `!List` is refused: "this task is lent to write, and keeps its
  write loan while it runs, so it stays where it is bound". SPEC §18
  states this. It is the same distinction as "read-only, not unusable",
  and the docs should say it in the new words: "a task that holds a write
  view of a Cell may be held in a list".

## 2. "Read-only" and "changes only through its own calls" (question 2)

Through a `!Hits` parameter (`whole/`):

| act | result |
|---|---|
| `h = Hits(n: Cell(9), step: 0)` | R: "`Hits(...)` makes a `Hits`, which holds a Cell, so it lives only behind a shared handle" |
| `h.step = 5` | R: "cannot assign through a shared handle (`*T`) ..." |
| `c = <h.n` | R: "cannot move out of `h.n`: `h` is a view; exchange its value with the Cell's own swap" |
| `h.n = Cell(4)` | R (two errors) |
| `!h.n.set(4)`, then read `h.step` | A, prints `1` |
| `c = Cell(5)` through `c: !Cell[Int]` | R: lives only behind a shared handle |

So the value is never replaced whole and changes only by its calls, for
every member. A read view does not freeze the value:
`r = ?c; !c.set(7); r.get()` prints 7 (SPEC example, rerun). This
confirms decisions.md's last fact: CORE sentence 4's "`?` promises that
nothing changes" must become "nothing changes the handle".

Two small notes:

- **The note on `h.step = 5` misnames what `h` is.** It reads "cannot
  assign through a shared handle (`*T`)" when `h` is a `!Hits`. It is
  true of where the value lives, but the type the reader sees is a view.
- **Signal escapes the "behind `*` only" check.** `List[Signal[Int]]()`
  and `peek[T]` with `T = Signal[Int]` are accepted (`sig/g2.rig`), while
  the same with `Cell[Int]` is refused. An `obj Holder  s: Signal[Int]`
  declares, but it can never be built, because `Signal(0)` is refused
  outside `*`. That makes the declaration unusable, not unsound. The
  "lives only behind `*`" check keys on "holds a Cell"
  (`holdsCellByValue`), not on `changesByMark`. Outside this vocabulary
  question; noted for the backlog.

## 3. The untyped `w = !c` (question 3, in depth)

### What the compiler does

`Checker.lendViewOf` (src/typecheck.zig, about line 7258):

```zig
if (kind == .write and self.lendsHandle(place) and !sameNode(e, self.self_obj) and !try self.handleWritable(place, operand)) {
    // lends what the handle holds: a `!T`, a read loan
```

Otherwise `!c` synthesizes `!*T`, and `recordLoan` records a write loan
(`holdsMarkedValue` is false for `.shared`). An expected `!T` re-decides
it to a read loan (`lendView`). So the untyped form picks the handle
exactly when the handle may be written. SPEC's Cell section says so in
one sentence (SPEC about line 10364): "A handle is lent as itself, `!*C`,
... only where the handle may be written (an owned mutable local, a `!*C`
parameter, a handle field of a write view); anywhere else ... `!h` lends
what it holds, a `!C`."

### Run (`u*.rig`, `ctx/`)

| program | `c` is | `w = !c` gives | result |
|---|---|---|---|
| u1 | local | `!*Cell[Int]` | R: "use of `c` while a write loan is live" at `print(c.get())` |
| u2 | local, `w: !Cell[Int] = !c` | `!Cell[Int]` | A: `1`, `5` |
| u3 | local, `w: !*Cell[Int] = !c` | `!*Cell[Int]` | R, as u1 |
| u4 | local; `w = *Cell(9)` | `!*Cell[Int]` | A: prints `9` (`c` was reseated through `w`) |
| u5 | local; `!w.set(5)` | | A: `5` |
| c1 | **parameter `c: *Cell[Int]`** | **`!Cell[Int]`** | **A: `1`, `5`; `c` read-only** |
| c8 | parameter; `w = *Cell(9)` | `!Cell[Int]` | R: "type mismatch: expected `Cell[Int]`, got `*Cell[Int]`" |
| c2 | parameter `c: !*Cell[Int]` | `!*Cell[Int]` | R, as u1 |
| c3 | field of a local, `w = !o.c` | `!*Cell[Int]` | R: "use of `o.c` while a write loan is live" |
| c4 | `w = !@c` in a `!@` method | `!*Cell[Int]` | R |
| c6 | `w = !a if k else !b` | `!*Cell[Int]` | R |
| c7 | `for c in !cs`, `w = !c` | `!*Cell[Int]` | R |
| c5 | `swap(!a, !b)` of two local handles | | A: `2 1` (the handles swap) |
| c9 | `r = ?c` untyped | `?*Cell[Int]` | A (read-only either way, harmless) |
| t1 | all members, untyped | `!*Cell`, `?*Signal`, `?*Chan`, `?*Actor`, `?*shared.Map` | (types printed by mismatch) |

The untyped trap is the same for all six members (matrix, `wuntyped`
column).

### Is it natural?

No. The same line, `w = !c`, means two things depending on whether the
binding beside it may be assigned: a local versus a parameter. A reader
cannot see that from the line. The common intent of `w = !c` on a Cell
is to keep a writer of the Cell, which is what `!c.set(5)` and every
typed form already do. The handle reading has one use, pointing `c`
elsewhere through `w` (u4). It is rare, and `w: !*Cell[Int] = !c` says
it in the open. It also has a cost: the untyped form is the only place
in the kind where `!c` makes `c` unusable, and the message it produces
("use of `c` while a write loan is live") gives no hint why
`!c.set(5)` did not do the same.

The rule then becomes uniform: **`!x` of a Cell-kind handle makes a
write view of its value, unless a `!*T` is written where it goes.** That
also matches what the SPEC sentence already does for every non-writable
binding.

### What the change breaks: an experiment

I copied the worktree to scratch (`exp/rig`, no repository files
touched), changed one condition so that the handle is lent itself only
where an expected write view is written (`lent_write`, set by
`checkExpr` when the expected type is a write view), and built:

```zig
// before
... and !try self.handleWritable(place, operand)) {
// after
... and (!sameNode(e, self.lent_write) or !try self.handleWritable(place, operand))) {
```

With it, u1 prints `1` (accepted, `c` read-only), u2 and u5 are
unchanged, u3 (typed `!*Cell`) is still refused, and u4 becomes
"type mismatch: expected `Cell[Int]`, got `*Cell[Int]`", the same as the
parameter case c8 today.

Core suite (`swarm test/rig.rip`) on the patched copy:

```text
466.08 secs for 12171 jobs by 10 workers @ 26.11 jobs/sec
16 died
```

The 16 entries are 11 distinct tests, plus the pack-level copies of the
same build failures and `cli.sigil_table`. `cli.sigil_table` fails only
because the copy has no git repository ("no Rig repository to list the
docs from"). I did not run a baseline on main; every failure below is on
the changed path. They fall into three groups:

1. **Swapping two Cell handles: 6 tests, a real dependency.**
   `swap(!a, !b)` and `swap(!a, *Cell(...))` on writable handles exchange
   the handles today. The swap's operands are synthesized with no
   expected write view, so after the change they become Cells, and the
   "`swap` moves values whole" rule refuses them. The tests are
   probes-27.021 "review-rule2-swap-writable-handles", probes-27.013
   "review-rule2-cell-handle-forms", probes-19.075 "review-cell-mark-1-p33
   replace cell", and ownership-cell.038/.040 and effects-misc.059, which
   each get one extra error. effects-misc "swap signal whole" states the
   two-meaning rule in its comment: "the Signals two handle parameters
   lend are not exchanged; handles of local bindings, which `!` lends
   themselves, still are". This is the same writability split as
   `w = !c`, in a second place.
2. **A generic `!T`: 1 test, a real dependency.** ownership-cell.027
   "cell lend a type parameter twice" (`twice[T](x: !T)` called with
   `twice(!c)`) now infers `T = Cell[Int]` instead of `*Cell[Int]` and
   is refused for another reason. decisions.md says a generic `!T` is an
   ordinary write view. Inference would have to keep the handle.
3. **My one-line patch is incomplete: 4 tests.** These are places where
   an expected `!*T` exists but does not reach the lend: a branch
   returned as `-> !*C` (`!a if k else !b`), a `match !e` on a `*E`
   holding a Cell (the emitted Zig fails: "struct `Counted(E,false)` has
   no member named `a`"), and a `!*Cnt[T]` in a generic body. The tests
   are ownership-cell.007 "cell marked handle views", probes-23.079 and
   .084, and types-write.025. A real change would carry the expected
   type into branches, match scrutinees, and generic bodies.

So the change is not one line. It is "decide `!h` by the type written
where it goes, and choose the value where nothing is written", applied
in each context that carries an expected type. It breaks one deliberate
feature: swapping or replacing two Cell-kind handles with
`swap(!a, !b)`, which then needs its own spelling (`!*T` operands, or
`a, b = <b, <a` if tuple assignment moves handles; I did not test that).
It also needs generic inference to keep `T = *Cell[Int]`. Nothing else
in the core suite depends on the untyped form choosing the handle.

A grep over test/, std/, examples/, docs/ and SPEC.md for an untyped
`NAME = !NAME` whose operand is bound to a handle found five lines
(`find_untyped.py`). Four are plain `*Tok` or `*B` handles, which are not
in the kind and are unaffected (probes-06:3944, :3974; probes-27:1539,
:2004). One is a Cell handle (probes-27:308, `viaBinding`), but its `c`
is a `*Cell` parameter, so it already gets the Cell.

What would change in the docs: SPEC's sentence on where a handle is lent
as itself (about line 10364) would read "only where a `!*C` is written
for it", CORE §4's table row needs no change, and decisions.md's
paragraph on `w = !c` goes.

## 4. The messages (question 4)

Today's text and the decided form, on each refused case. Every member
gives the same text, so one line stands for all six.

| case | today | decided form | true? |
|---|---|---|---|
| `r = ?x`, then `x = *...` | cannot reassign `x` while it is lent / note: `x` lent to read here | cannot reassign `x` while a read view of it is still in use / a read view of `x` is made here | yes |
| `w: !Cell[Int] = !x`, then `x = *...` | cannot reassign `x` while it is lent / note: **`x` lent to read here** (under `!x`) | cannot reassign `x` while a **write** view of it is still in use / a write view of `x` is made here | yes, **only if the word comes from the sigil** |
| same, `z = <x` | cannot move `x` while **a read loan** is live | cannot move `x` while a write view of it is still in use | as above |
| same, `<x` | cannot drop `x` while it is lent | cannot drop `x` while a write view of it is still in use | as above |
| a task `t = (!h).bump()&`, then `h = ...` | cannot reassign `h` while it is lent / `h` lent to read here | ... a write view of `h` ... / "still used here" at `>t` | yes; the last use is the wait |
| `v = !m.ensure(1, String("ten"))`, then `m = ...` (`misc/m4`) | cannot reassign `m` while it is lent / `m` lent to read here | ... a write view of `m` ... / still used here: at `print(v)` | yes; `v` carries it. With `V = Int` the result is copied out and `m` is free (`m3`, prints 10), as panel 3 found |
| `reseat(!x)` while a view is in use | cannot lend `x` to write while a read loan is live | **verb?** | see below |
| select: `bump(!ch)` in an arm while `!ch.on_recv()` is in use | cannot lend `ch` to write while a read loan is live / `ch` lent to read here | ... while a write view of it is still in use / a write view of `ch` is made here | yes, if worded by sigil |
| untyped `w = !x`, then `x.get()` or `!x.set(2)` | use of `x` while a write loan is live / `x` lent to write here | cannot use `x` while a write view of it is still in use / a write view of `x` is made here | true, but surprising after `!x.set(5)` works; if the trap stays, add a help line: "`w = !x` views the handle itself; write `w: !Cell[Int] = !x` to view the Cell" |

Three requirements for PR 2:

1. **Name the view by the sigil, not by the loan kind.** For this kind,
   `!x` records `.read`. Today's notes already say "lent to read" under a
   `!`. A message built from `LendKind` would say "a read view of `x` is
   made here" under `!x`. The checker needs the view's sigil, or the
   `.write_view` type, at the loan site.
2. **The verb for `reseat(!x)`.** Of the decided verbs, "change" is the
   one that fits an ordinary `f(!v)`. Here it reads false: the Cell
   changes freely by `!x.set(5)` in the next line. The act is that the
   handle may be pointed elsewhere. Suggested: "cannot reassign `x`
   through `!x` while a read view of it is still in use", or "cannot
   lend the handle `x` to write ...". Either keeps "reassign" as the
   blocked act, which is what decisions.md already says a Cell's message
   needs.
3. **"Still used here" for a task** is the `>t` (or the end of the
   task's holder). For a select it is the select. For an in-flight call
   it is the call itself, so the note can be left out when both ends are
   on one line.

`rig check --tasks` names the handle type even after the lend was
re-decided. For `grow(!c)&`, where `grow` takes `!Cell[List[Int]]`, it
reports "`!*Cell[List[Int]]` views a `*` handle ...". This is minor, but
it shows the type the reader did not write.

## 5. Members that differ beyond lifetime

- **A typed `!Actor[T]` is unusable** (`a1.rig`, `a3.rig`). Neither
  `(!w).add(1)` nor `w.count()` resolves: "no method `add` on type
  `Actor`". The type is accepted as a parameter and as a lend target, and
  test/rig/ownership-cell.rig.test:925 declares `sub actors(a:
  !Actor[Counter], b: !Actor[Counter])`, but nothing can be done through
  it. An actor is called only through its handle (`*Actor` or
  `!*Actor`, `a2.rig`, prints `1 2 2`). Either `!Actor[T]` should reach
  the actor's methods, or the docs should say that an actor's write view
  is its handle's. Under the new words, "a write view of an actor" means
  nothing a program can use today.
- **A typed `!Chan[T]` sends and receives but cannot be a select arm**
  (`sel/s4.rig`): "`w` is a `!Chan[Int]`, not a channel; each arm of
  `task.select` is `name: !ch.on_recv()` ...".
- **An actor's task call keeps nothing.** Every other member's
  self-holding task keeps the view for its life.
- **A select arm on a task** (`?t.on_end()`) is a read view of a
  `Task`, which is not in the kind. A `Tasks` set is not in it either:
  `r = ?ts`, then `!ts.add(...)`, is refused (ownership-shared-lend's
  last case).

None of these changes what a view of the handle allows. Each is about
what the value offers (an actor's methods) or how long the view lasts.

## Files

- `gen.py`, `run.sh`, `matrix.txt`, `matrix2.txt`, `mx/` (the matrix)
- `u1`..`u5`, `ctx/c1`..`c9`, `t1_types.rig` (the untyped form)
- `tk/`, `wc/`, `sel/`, `misc/` (lifetimes, tasks, select, Map results)
- `whole/` (replacing a value through a write view), `sig/` (Signal by
  value), `a1`..`a4.rig` (actor views)
- `exp/rig` (the patched copy), `exp/suite.log` (its core suite run)
- `find_untyped.py` (the grep)
