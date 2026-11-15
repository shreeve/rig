# A select arm through a read view (2026-11-15)

The hole: a receive or send arm of `task.select` whose channel's handle
was reached through a read view passed `rig check` and changed the
channel. With `ch: ?*Chan[Int]`, `match task.select(got: !ch.on_recv())!`
received (it printed `got 7`), while `!ch.recv()` through the same view
was rejected. That broke Core sentence 4, "`?` promises that nothing
changes", which SPEC "Cell" already applies to every handle: "A read
view of a handle, or of a value that holds one, is not lent to write at
all ... however the view is reached". The owner approved the fix ("Yes,
all three").

## Cause and fix

`taskSelect` and `taskSelectNamed` (src/typecheck.zig) checked only that
an arm was marked with `!`, then typed the handle under the mark with
`synthExpr(handle)`, so the `!` itself never went through `synthLend`,
the one check of a write lend. A marked method call types its self as
`synthExpr(obj)` with `self_obj` set to it, which runs `synthLend` on the
`!` node. The arms now do the same (`armHandle`): one classifier, and
the same diagnostics as the plain call's. Emit reads the arm's handle
as before (`storage.heldSelf`, emit's `selectArmOf` branch), but the
typed lend changes what storage holds for two shapes, both for the
better (found by review, below): a handle made in the arm, which
leaked, and a branch of handles, which emit could not lower. Typing
the `!` records a type on it, which the ownership checker read as a
call storing every argument in a `Chan` (an arm closure's `|?s|` was
then "cannot store a view of `s` in a `Chan`"). The first version of
this change skipped the store check for every arm, on the claim that
what a send arm sends is of a type that holds no view; review showed
that false (below), and the check now applies to a send arm's value,
its first argument, alone. A task arm, `?t.on_end()`, lends to read, so a
read view of a task stays accepted, and `!t.on_end()` and
`<t.on_end()` stay rejected by their own check.

The reference checker (test/oracle) lent every arm's handle to read and
accepted all of these. It now has a rule from Core s4, C10: an arm that
receives or sends changes its channel, so a handle seen through a read
view (a place reached through one, or itself one) is rejected. Since the
compiler now stops at the arm's `!` and leaves the select untyped, the
oracle abstains on these programs ("a type with an error"), and its
verdict is moot there. Built against the old typecheck, the new oracle
reports every probe below as `DIFF prod=accept ref=reject C10` at the
compiler's own positions, and accepts the controls, so the rule catches
the hole should sema ever accept it again.

## Probes

Each probe receives (or sends) through the path named. "Before" is
`bin/rig` and `bin/rig-oracle` at 3a3ba5038; "after" is this branch.

| Probe | Path | Compiler before | Compiler after | Oracle before | Oracle after (old sema) |
|---|---|---|---|---|---|
| p01 | named `on_recv`, `?*Chan` parameter | ran, `got 7` | rejected | accept | C10 |
| p02 | named `on_send`, `?*Chan` parameter | ran, `put` | rejected | accept | C10 |
| p13 | p01 beside a `time.after` arm | ran | rejected | accept | C10 |
| p03 | `if o as c` read binding | ran | rejected, with the `if !o as c` hint | accept | C10 |
| p12 | `while o as c` read binding | ran | rejected | accept | C10 |
| p04 | `match l`, `.ch(:c)` | ran | rejected, with the `match !l` hint | accept | C10 |
| p05 | `for c in chs` | ran | rejected | accept | C10 |
| p06 | field of a `?W`, `!w.ch.on_recv()` | ran | rejected | accept | C10 |
| p07 | element of a `?List[*Chan[Int]]` | ran | rejected | accept | C10 |
| p08 | `|?ch|` capture, named arm | ran | rejected | accept | C10 |
| p14 | `|?ch|` capture, older closure spelling | ran | rejected | accept | C10 |
| p09 | older spelling `(!ch).on_recv(f)`, `?*Chan` parameter | ran, `7` | rejected | accept | C10 |
| p10 | older spelling `(!ch).on_send(3, f)` | ran | rejected | accept | C10 |
| p11 | `?t.on_end()` of a `t: ?Task[Int]` | ran, `done 9` | ran, `done 9` | accept | accept |
| k01 | controls: a `*Chan` and a `!*Chan` parameter, a field of a `!W`, an element of an owned List, a `|+ch|` capture | ran | ran | accept | accept |

The rejection is the plain call's: through a `?*Chan` binding, "cannot
lend to write through a read view `?*Chan[Int]`; take a write view, or
share a handle of your own with `+h`"; through a field or an element of
a read view, "cannot lend to write through a read view (`?T`); take a
write view (`!T`) to mutate". A `time.after` arm has no handle and is
unchanged. `!t.on_end()` and `<t.on_end()` were rejected before and
after ("an arm on a task's end lends the task to read").

## Who is affected

No select arm in Trig (`~/Data/Code/trig`, 0 uses of `on_recv`,
`on_send`, `on_end`, or `task.select`), std (0), examples, or bench.
The CHANGELOG lists it among the holes closed since 0.3.0.

## After review (2026-11-15)

An adversarial review of the first commit (bc368cf99) found:

1. A channel of a type that holds a view could be made in a generic
   body: `*Chan[T](1)` at `mk[?String]()`. `chanMake` checks the
   element type where it is written, and a type parameter holds no view
   there; nothing asked the instance. A send arm then put `?s` in it
   with no store check (before and after the first commit), and the
   receiver read freed text: "use of freed memory" under
   `RIG_SANITIZE=1`. `*Actor(Box(v: v))` at `T = ?String` was accepted
   the same way. The ownership checker now asks each instance of a
   body that makes a channel or an actor (`*Actor.supervised` too) for
   a `T` that holds no view, the requirement a `T` stored in a Cell
   already made (`requireNoView`, checked by `checkViews`), and a send
   arm's value goes through `send`'s store check. Cells and Signals
   were closed already: a generic body that stores a `T` in one is
   checked at each instance.
2. A `[]T` was not treated as a read view of its elements where a
   handle is lent: `requireAccess` exempts a lend of a handle that
   changes by a marked call before it reports the slice, so
   `!s[0].on_recv()`, `!s[0].set(5)` on a `[]*Cell[Int]`,
   `!s[0].c.set(5)` on a `[]*Node`, a Signal's `set`, and an actor's
   `!@` method on a `[]*Actor[Box]` were accepted, also through
   `s = ?xs[..]` of a `?List`. `placeOf` now marks a read-only slice
   on the path as it marks a read view (`view_blocked`, `view`), so
   each is rejected as through a `?List`. A `![]T` is unchanged.
3. Two `rig run` verdicts changed with the first commit, for the
   better, untested and unlisted: `got: !make().on_recv()` (and the
   older spelling) leaked its channel and is clean; an arm on a
   branch, `!(a if k else b).on_recv()`, stopped emit with an internal
   error and runs. Each now has a `test`.
4. An arm whose handle is no channel got the lend's error first, with
   wrong advice (`!n.on_recv()` of an `n: Int`: "cannot lend parameter
   `n` to write"). `armHandle` drops the lend's diagnostics when the
   handle is no channel, so "`n` is a `Int`, not a channel" comes alone.

The reference checker's C10 now covers every marked change through a
handle seen through a read view, judged from the types of the place as
written (a `?T`, or a `[]T`, on its path): a select arm, a Cell's or
Signal's change, and an actor's `!@` method. The compiler's lend
errors leave Cell and actor calls typed, so the oracle decides those
cases in the suite (`# oracle: f reject C10`); a select arm's error
leaves the select untyped, so there it abstains.

| Probe | Before (bc368cf99) | After |
|---|---|---|
| `mk[?String]()` making `*Chan[T](1)`, and a List of such | accepted | rejected at the instance |
| `*Actor(Box(v: v))`, `*Actor.supervised(*\|\| Box[T?](v: none))` at `?String` | accepted | rejected at the instance |
| send arm `put: !ch.on_send(?s)` of a `*Chan[?String]`, both spellings | accepted (sanitizer: use of freed memory) | "cannot store a view of `s` in a `Chan`" |
| send arm in a generic body at `T = ?String` | accepted | rejected at the instance |
| arm, `(!s[0]).recv()`, through `[]*Chan`, and through `?xs[..]` | accepted, ran | rejected |
| `!s[0].set(5)` on `[]*Cell` and `[]*Signal`, `!s[0].c.set(5)` on `[]*Node` | accepted, ran | rejected; oracle C10 |
| `!s[0].add(1)` on `[]*Actor[Box]`, and through `?xs[..]` | accepted | rejected; oracle C10 |
| `got: !make().on_recv()`, `(!make()!).on_recv(f)` | (3a3ba5038: leaked) clean | clean, tested |
| `got: !(a if k else b).on_recv()`, both spellings | (3a3ba5038: internal error) runs | runs, tested |
| `!n.on_recv()`, `!flag.on_recv()`, `!ch.on_recv()` of a `T` or `?T` | lend error first, wrong advice | "not a channel" alone |

## Second review (2026-11-15)

A second review of c2d65f917 (313 programs) found no way left to break
either rule, and the two checkers agreeing on every accepted program.
It found four things, fixed after it:

1. The requirement a channel or actor made in a generic body asks of
   `T` is the one a `T` stored in a Cell asks, so a body checked by its
   bounds (a `pub` one, or one with bounds such as `[T: Sends]`) that
   makes a channel of `T`, or an actor whose value holds one, needs
   `T: Owned` where it is declared, even if it puts nothing in. The
   CHANGELOG and SPEC's generics and bounds passages say so. Trig, std,
   examples, and bench make no channel or actor of a type parameter.
2. The reference checker did not store a send arm's value in its
   channel, so it accepted under C8 what it rejects for `send`. It now
   does.
3. The requirement's message named every home that carries no loan; it
   now names what the body does.
4. `par.map`'s closure loses its own errors in a quiet pass (an
   internal error, or an accepted program that fails in emit): a
   backlog entry, not this change.

## Not done here

The actor call through a read view of its handle has a check of its own
in `actorCall` (it reads the self's type for `.read_view`), though the
`!` there already goes through `synthLend` first; folding it is for the
broader lend change, with CORE's wording.
