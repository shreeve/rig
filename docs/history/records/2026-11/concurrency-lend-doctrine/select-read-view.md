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
`!` node. The arms now do the same (`armHandle`): one classifier, the
same diagnostics as the plain call's, and nothing new for emit, which
reads the arm's handle as before (`storage.heldSelf`, emit's
`selectArmOf` branch). Typing the `!` records a type on it, which the
ownership checker read as a call storing its arguments in a `Chan`
(an arm closure's `|?s|` was then "cannot store a view of `s` in a
`Chan`"); it now reads the arm fact first, since an arm hands its
function to the select, and what a send arm sends is of the channel's
type, which holds no view. That is what it decided before, when the
`!` had no type. A task arm, `?t.on_end()`, lends to read, so a
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

## Not done here

The actor call through a read view of its handle has a check of its own
in `actorCall` (it reads the self's type for `.read_view`), though the
`!` there already goes through `synthLend` first; folding it is for the
broader lend change, with CORE's wording.
