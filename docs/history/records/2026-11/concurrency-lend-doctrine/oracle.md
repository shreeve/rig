# The reference checker learns the shared lend

The reference ownership checker (`bin/rig-oracle`, `test/oracle/`)
models Core §4's handle rows and the paragraph after the table, and
SPEC's "Lending a shared value to write", from those docs alone: no
line of `src/ownership.zig` or of typecheck's lend code was read.

## What it models

One derivation, `Lowerer.lendsToRead` in `test/oracle/lower.zig`: `!x`
puts only a read loan on `x` when what it lends is a write view of a
value that changes by a marked call, reached through `x`'s views, its
handle, and a box: a `Cell`, a `Signal`, a `Chan`, an `Actor`, or a
value that holds a Cell. An API object `{A}` or a type parameter is no
such value. Through a handle the loan is on the handle's slot. It
serves both kinds of write lend:

- a marked call's self (`!c.set(5)`, `!ch.send(v)!`, a select's
  `!ch.on_recv()`, an actor's `!@` method, `(!@).bump()` of a value
  holding a Cell): lowered as a read receiver, its loan made before the
  arguments and carried by the result and by a task of the call;
- `!x` handed to a call (`argLendsToRead`): the parameter's declared
  type says what is lent, since sema types the argument as the write
  view of `x` itself. `!*T` lends the handle (a write loan), `!T` of a
  type parameter is a write loan, and `!T` or `!{A}` of anything else
  lends the value `x` reaches, judged by its type at the lend.

`!h` lending the handle itself, assigning, and dropping stay writes. A
marked call through a read view is C10, as before.

It replaces two special cases in `call`: an actor's method call was
forced to a read of its handle, and a select arm was forced to a read;
both are now the derivation (Chan and Actor are on its list). What
stays actor-specific is what SPEC says of actors alone: a task of an
actor's call keeps none of the handle. A Cell's or Signal's mark used to
lend the handle's slot to write (`handleSlot`, reserved then write);
that write loan is gone.

## SPEC's 22 rows

`ref` is the oracle's verdict on `main` (or the function named), by
`bin/rig-oracle --sema -v`. "sema" means the docs' rejection is a type
rule the compiler's semantic checks report, which is not an ownership
question: the oracle gives no rejection there (it abstains or accepts),
and none is expected of it.

| Row | Accepted example | Rejected example |
|---|---|---|
| 1 `*Cell[T]` | accept (pending) | reject C4, `cs` written under the read loan |
| 2 `*Cell[List[T]]` | accept (pending) | sema (an element of a Cell's List); oracle abstains |
| 3 `?*Cell[T]` | accept | reject C10 (`bump`) |
| 4 `*Signal[T]` | accept (pending) | reject C10 (`poke`) |
| 5 `*Chan[T]` send, receive | accept (pending) | reject C4, `xs` written under the read loan |
| 6 `*Chan[T]` select arms | accept | sema (through a read view); oracle abstains, a type with an error |
| 7 `Task[T]` select arm | accept | sema (an arm on a task's end lends to read); oracle abstains |
| 8 `*Actor[T]` `!@` | accept | reject C4, `xs` written under the read loan |
| 9 `*Actor[T]` `?@` | accept | sema (call it bare); oracle abstains |
| 10 `*Actor[T]` task | accept | reject C10 (`poke`) |
| 11 `*Frozen[T]` | accept | sema (a `!@` method through a handle); oracle abstains |
| 12 plain `*T` | accept | sema (expected `!User`, got `!*User`); oracle accepts |
| 13 holds a Cell: calls | accept (pending) | reject C10 (`poke`) |
| 14 ... tasks | sema stops first in today's compiler (T2 at `!ts.add`); oracle abstains. The case without the set, in `ownership-shared-lend`, is accepted | reject C4, `h` moved under the task's read loan |
| 15 ... result views self | accept (pending) | reject C4, `h` moved under `w`'s read loan |
| 16 ... `!h` alone | accept (pending) | reject C4, two write loans of `h` (`!*Hits`) |
| 17 `!*Cell[T]` parameter | `bump` and `main` accept (pending) | reject C4 (`f`), `c` written under `r`'s read loan |
| 18 `!Cell[T]`, `!@` | `Hits.twice`, `swapped`, `main` accept (pending) | reject C6 (`put`), the oracle's own reason beside sema's |
| 19 `*{A}` | accept (pending) | first: reject C4, two write loans of `b`; second: sema (`*{Bump}` only reads); oracle abstains |
| 20 `~T` | accept | sema (reaches its value only once upgraded); oracle abstains |
| 21 `Tasks[T]` | accept | reject C4, `ts` written under `r`'s read loan |
| 22 `shared.Map` | oracle abstains (a generic type at an owner whose methods copy a `T`) | oracle abstains, same |

Every accepted example the oracle decides is accepted, and every
rejection that is an ownership rule is rejected, with the rule the docs
give. Core §4's own pair: the pending example is accepted, and the
rejected one (`c` reassigned while `r = ?c` lives) is C4.

## test/oracle/rejections

Added, each a rejection the docs state (UNLISTED before):
`doc/SPEC/6e790c81a094` (row 1), `3a5386487e53` (5), `6f6bdfd43b96`
(8), `7486b4a2ab96` (14), `9f3519e8bdc6` (15), `35455f1c0a95` (16),
`e9d91cef58ff f` (17), `5e01d44bc259` (19), `c81df2996cab` (21), and
`doc/CORE/84254a225afc` (Core §4's rejected example).

`doc/SPEC/5cf88226f148 main`, UNLISTED before this change, is row 1's
accepted example, `!c.add((!c).swap(4))`. The docs accept it ("So
`!c.add((!c).swap(4))` is accepted", Core §4): the oracle was wrong,
and now accepts it, so it is not listed.

Also added: the ten rejections of `test/rig/ownership-shared-lend.rig.test`
(`test/reject/ownership/shared_lend_*`), whose cases state the oracle's
verdict on every function they decide, one or two for each row kind.

Removed, each a program the docs now accept:

- `test/reject/ownership/cell_mark_lends_the_handle.rig main`: `seen = ?c`
  kept across `!c.set(2)`. Core §4: "and so is a view `r = ?c` kept
  across `!c.set(5)`".
- `test/reject/probes/review-cell-mark-1-p21_same_handle_twice.rig main`:
  `f(!h, ?h)` with `x: !H` for an `H` that holds a Cell. Core §4 lists
  "`hit(!h)` for a `!Hits`" among the lends to read, and row 16 accepts
  `hit2(!h, !h)`; a read view lives beside them.

Both `fail` cases (`ownership-cell` "cell mark lends the handle",
`probes-19` "review-cell-mark-1-p21 same handle twice") still expect
the compiler's old rejection; the compiler change turns them around.

## Expected `stricter` until the compiler builds the rule

The compiler here rejects what the oracle now accepts: the 12 pending
doc examples' functions (rows 1, 2, 4, 5, 13, 15, 16, 17 `bump`, 18
`Hits.twice` and `swapped`, 19, and Core §4's pending example), the two
removed rejections above, and the `known:` cases of
`test/rig/ownership-shared-lend.rig.test`. None is allowlisted.

## Gaps the oracle leaves to sema

- Through a `!T` of a value that holds a Cell, Core §4 says only marked
  calls change it; a callee assigning such a view's plain field is a
  type rule the oracle does not check.
- `shared.Map` (row 22) stays undecided, as every generic type at an
  owner whose methods copy a `T` is.
