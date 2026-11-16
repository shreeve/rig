# Lend doctrine: inventory of `!` through a handle (2026-11-15)

What `!` lends today, for every handle and every marked call through
one, and what the owner's rule would lend:

> `!` on a call through a handle needs a handle you hold, never a read
> view. It lends the handle's place to read for as long as the call or
> select holds it, never a write view of the shared value.

Probed with the lend-doctrine worktree's `bin/rig` and `bin/rig-oracle`
(main after #1094). The probe programs are in the session scratchpad,
`inventory/` (listed at the end); "c01" names `c01_*.rig`. "Write" and
"read" are the kind of loan the ownership checker records on the place
that holds the handle (`c`, `xs`, `o.c`), not on the shared value.
"Oracle" is `rig-oracle --sema -v`: accept, reject (its rule), or
abstain (its reason); "sema" means the compiler stopped before the
ownership checker. The select arm through a `?` view (sel03) is treated
as fixed by the separate change in progress.

## The table

| Handle | Call | Docs say | Compiler lends today | Oracle | Rule would lend | Change |
|---|---|---|---|---|---|---|
| `*Cell[T]` | `!c.set(v)`, `!c.swap(v)`, `(!c).compare_swap(o, n)`, `!c.add(n)`, `!c.sub(n)` | SPEC 9509: "`!c` where `c` is a handle lends the handle"; CORE §4 row (1231): "nothing of the value (`!h` lends the handle itself)" | **write** for the call; self is a `!Cell[T]`; the arguments may read `c` (c02, c07 accepted). Rejected: c01 `!c.add((!c).swap(4))`, c03 `show(?c, !c.add(1))`, c08 `r = ?c` live across `!c.set(5)`, c05 `!xs[0].add(grow(!xs))` | same: C4 "write loan" on c01, c03, c05, c08 | read for the call; self still a `!Cell[T]` | **write to read**: c01, c03, c08 newly accepted; c05 stays rejected |
| `*Cell[T]` | `c.get()` | SPEC 9404: a copy | read | read | read | none |
| `*Cell[List[T]]` | `!c.push(x)`, `(!c).pop()`, `!c.keep(n)`, `!c.clear()`, `(!c)[i] = x` | SPEC 9409-9410 | **write** (c09 `!c.push((!c).pop() ?? 0)` rejected; c09b accepted) | abstains ("an argument without a parameter") | read | **write to read**: c09 newly accepted |
| `*Cell[List[T]]` | `c.len`, `c[i]`, `c.get(i)` | copies | read | abstains | read | none |
| `?*Cell[T]`, `?Cell[T]` | any marked call | SPEC 9509-9511, 9541-9546: rejected | rejected in sema (c06) | (sema) | rejected | none |
| `*Signal[T]` | `!s.set(v)`, `!s.subscribe(cb)` | SPEC 10508: "Both are marked calls, as a Cell's are" | **write** (s02 `r = ?sig` live across `!sig.set(7)` rejected); through `?*Signal` rejected (s03) | C4 "read loan" conflict on s02 | read | **write to read**: s02 newly accepted |
| `*Signal[T]` | `s.get()` | a copy | read | read | read | none |
| `*Chan[T]` | `!ch.send(<v)!`, `!ch.recv()!`, `!ch.close()` | SPEC 14156-14158: "marked with `!` through a handle the task holds" | **write**. Rejected: ch01 `!ch.send((!ch.recv()! ?? 0) + 5)!`, ch03 `r = ?ch` live across a send, ch05 `!xs[0].send(grow(!xs))!`; through `?*Chan` rejected (ch02) | C4 "write loan" (ch01, ch05), "read loan" (ch03) | read | **write to read**: ch01, ch03 newly accepted; ch05 stays rejected |
| `*Chan[T]` | select arms `!ch.on_recv()`, `!ch.on_send(<v)` | SPEC 14196-14197: what an arm lends "stays lent ... until the select returns"; the kind is not said | **read**, until the select returns: sel01 (two arms on one channel) accepted, prints `got 7`; sel02 (`grow(!chs)` in an arm) and sel04 (`!ch.recv()` in an arm) rejected. Through `?*Chan`: accepted (sel03, the gap) | read (`arm_call`); sel03 accepted | read until the select returns; through `?ch` rejected | none for a held handle; sel03 newly rejected (the separate change) |
| `Task[T]` (an owned value, not a handle) | select arm `?t.on_end()` | SPEC 14178-14187: lends `t` to read; `!t.on_end()` rejected | read (sel05) | read | out of scope | none |
| `*Actor[T]` | `!a.m(x)` (`!@`), `(!a).m(x)` | SPEC 14036-14038: "needs a handle you hold ... lends nothing" | **read** for the call: a01 `(!a).add((!a).add(1))` accepted, prints `2`; a03 `r = ?a` live across `!a.add(1)` accepted; a02 `!xs[0].add(grow(!xs))` rejected ("read loan"); through `?*Actor` rejected (a04) | read (`actor_call`); C4 "read loan" on a02 | read | none (the docs' "lends nothing" is wrong) |
| `*Actor[T]` | `a.m(x)` (`?@`) | SPEC 14034 | read; `(!a).count()` rejected (a07) | read | read | none |
| `*Actor[T]` | `!a.m(x)&` | SPEC 14046-14048: "keeps none of the handle" | read while the call is made, **none** for the task's life: a06 rebinds `a` while `t = !a.add(1)&` runs, accepted, prints `1 5`; a05 accepted | same | read while the call is made, none after | none, **if** "as long as the call holds it" is read so; read as the task's life it would newly reject a06 |
| `*Frozen[T]` | `!f.m()`, `!f.push(x)` | SPEC 14303: "nothing writes through it" | rejected in sema (f01, f02) | abstains | rejected (holds no Cell) | none |
| plain `*T` | `!h.m()` (`!@`), `!h.push(x)` on `*List[T]` | SPEC 9258-9262: rejected | rejected in sema (h01, h02) | abstains ("a write receiver through a handle") | rejected | none |
| plain `*T` | `!h` alone for a `!*T` | SPEC 9258-9259: "`!h` lends only the handle itself (a `!*T`)" | write of the place; repoints (h03b, also `f(!xs[0])`); for a `!T`, a type mismatch (h03) | accept | not a call through a handle; stays write | none |
| `*T`, `T` holds a Cell | `!h.bump()` (`!@`) | SPEC 9534-9536; CORE 848: "Through a handle only its Cells change" | **write** for the call; self is a `!Hits`. k01 `(!h).bump() + (!h).bump()` (in turn) accepted; rejected: k02 `(!h).bump((!h).bump(1))`, k09 `show(?h, !h.bump())`, k12 `r = ?h` live across `!h.bump()`, k16 a `?String` of a plain field live across `!p.hit()` | same (C4 on k02, k09, k12, k16) | read for the call; self still a `!Hits` | **write to read**: k02, k09, k12, k16 newly accepted |
| `*T`, `T` holds a Cell | `(!h).bump()&` | not said | **write** for the task's life: k10 (reads `h` while `t` runs) and k11 (rebinds `h`) rejected | same | read for the task's life (the task's self views the box the place keeps alive) | **write to read**: k10 newly accepted; k11 stays rejected |
| `*T`, `T` holds a Cell | a `!@` method whose result views self: `fun cell(!@) -> !Cell[Int]`; std's `!m.ensure(k, v) -> ?V from @` | not said | the result keeps the loan its own type names: `w = !h.cell()` keeps a **write** loan (k07: `h.n.get()` while `w` lives, rejected); `r = !m.ensure(1, s)` keeps a **read** loan (m04: `m.len()` accepted, `!m.put_new` rejected); a function returning `!h.cell()` through `h: !*Hits` accepted (k14) | k07 reject; m04 abstains; k14 accept | a read loan of the place, whatever the result's type | **write to read**: k07, m04 newly accepted; k14 must stay accepted (see answer 2) |
| `*T`, `T` holds a Cell | `!h` alone for a `!T` (`hit(!h)`) or a `!*T` (`repoint(!h)`) | SPEC 9537-9542: `!*C` where the handle may be written, else `!C` | write of the place: k03 accepted; k04 `hit2(!h, !h)` rejected ("write loan") | accept k03; reject k04 | not a call; the rule says nothing; `!*T` must stay write | none (k04 could follow the same argument; not proposed) |
| `!*Cell[T]` parameter (a write view of a handle) | `!c.add((!c).swap(4))` | as `*Cell` | **write** (c17 rejected) | C4 | read: the place holds a handle | **write to read**: c17 newly accepted |
| `!Cell[T]` parameter, `!@` of a Cell-holding object (write views, no handle) | `!c.add((!c).swap(4))`, `(!@).bump((!@).bump(1))` | not said | write (c18, k13 rejected) | C4 | not a call through a handle: stays write | none, but now **inconsistent** with c01/c17 (see answer 2) |
| `*{A}` | `!s.m()` (`!@`) | CORE 1445-1446: "Like every handle, it only reads" | rejected in sema, "`*{Bump}` only reads, as any handle" (p01), even when the hidden type holds a Cell | abstains | rejected | none |
| `*{A}`, `*{A + Syncs}` | `s.m()` (`?@`), `?s` | CORE 1446 | read (p02, p03) | accept | read | none |
| `~T`, `~{A}` | any call | SPEC 9284: "reaches nothing else" | rejected in sema (w01); `if *w as h` gives a `*T`, which follows its row (w02) | abstains | rejected | none |
| `Tasks[T]` (an owned value, not a handle) | `!ts.add(f(x)&)` | SPEC 13614 | write of the owner (t01: `!ts.add` with `?ts` live rejected) | C4 "read loan" | out of scope: must stay write | none |
| `Task[T]` | `<t.cancel()`, `>t` | SPEC 13530 | takes `t` (t02) | accept | out of scope | none |
| std.shared `*Map[K, V]` (a word-Cell object) | `!m.put_new(k, v)`, `!m.ensure(k, v)`; `m.get(k)`, `m.has(k)`, `m.len()` | std/shared.rig | write for the `!@` calls; read for the rest (m01-m04) | abstains ("a generic type at an owner whose methods copy a `T`") | read | as the Cell-holding rows: m04 newly accepted |

std gives or takes no other handle: across std/, only std/shared.rig
names one (`Map.new() -> *Map[K, V]`, its methods through `*Map`); no
std module declares a `*Cell`, `*Chan`, `*Actor`, or `*Signal`
parameter or result.

## 1. Does a Cell, Signal, or Chan method give or keep a view of the shared value?

**The built-ins give none.** Their declarations (src/resolve.zig
`registerBuiltins`, 5040-5076 and 5313-5325) return only values: Cell
`get` -> `T`, which must copy (`cell_get`, 5006: "copies out with
`Cell.get`"), `swap` -> `T` owned, `compare_swap` -> `Bool`, `add`/`sub`
-> `T`, `set` -> `Void`; Chan `send` -> `Void!`, `recv` -> `T?!` (moved),
`close` -> `Void`; Signal `get` -> `T` (copies, `signal_get`), `set`,
`subscribe` -> `Void`. A `Cell[List[T]]`'s `pop` -> `T?`, `get(i)` ->
`T?`, `c[i]` a copy, and "an element cannot be lent" (SPEC 9428). The
shims agree: src/runtime.zig `Cell` (2816: `get`, `set`, `swap`,
`compare_swap`, `add`, `sub`, `listPush`, `listPop`, `listLen`,
`listAt`, `listGet`, `listSet`, `listKeep`) and `Signal` (3138), and
src/tasks.zig `Chan` (1442: `send`, `recv`, `close`) return `T`,
`Opt(T)`, `bool`, `Int`, or `void`, never a pointer. `.value` is
refused ("a Cell is read with `c.get()` ...", c19, c20), and a `for`
over a `*Cell[List[T]]` is rejected (c10). What goes in carries no loan
(SPEC 9416-9419, CORE 857-858: "no-loan homes"), and the ownership
checker gives a built-in's result no loan on self (ownership.zig
`walkCallBody`: "A built-in's methods hand out values, never views of
self"). An actor's result "holds no view of the actor's state", checked
(typecheck.zig `actorCall`: "may view the actor's state").

**But a value that holds a Cell may give views of itself through a
`!@` method**, and std does: `shared.Map.ensure(!@, k, v) -> ?V from @`
and `get(?@, k) -> (?V)? from @` view the map's values in place, sound
because nothing is replaced or taken (std/shared.rig, header). A user
object may return `?@title` (a plain field, k16) or `!@n`, a write view
of a Cell (k07). None of these breaks the relaxation, since every such
view is already reachable through a second handle with no loan at all:
k17 (a `?String` of `p.title` live across `!q.hit()`), k08 (two
`!Cell[Int]` views of one Cell from two handles), m03 (a `?V` from
`!m.ensure` live across `!d.put_new`), c04, c13, ch06, k05 are all
accepted today and run clean under `RIG_SANITIZE=1`. The write loan on
the place holding one handle guards nothing that `+h` does not already
open. The premise for the panel is therefore: *a shared home's
contents change only by whole replacement, and every view a Cell-holding
value gives is of what never changes or is replaced whole* — not "no
views at all".

## 2. Which programs would the rule newly accept, and reject?

**Newly accepted** (all rejected today, by both checkers where the
oracle decides):

- c01 `!c.add((!c).swap(4))`; c09 `!c.push((!c).pop() ?? 0)`
- c03 `show(?c, !c.add(1))`, and c14 `show(?o, !o.c.add(1))` (a
  handle field of an owned object; today "cannot lend `o.c` to write
  while a read loan on `o` is live")
- c08 `r = ?c`, `!c.set(5)`, `r.get()`; s02 the same for a Signal;
  ch03 for a channel; k12 for a Cell-holding object
- ch01 `!ch.send((!ch.recv()! ?? 0) + 5)!`
- k02 `(!h).bump((!h).bump(1))`; k09 `show(?h, !h.bump())`
- k16 `t = ?p.name()` (a view of a plain field) live across `!p.hit()`
- k07 `w = !h.cell()` then `h.n.get()` while `w` lives; m04 `r =
  !m.ensure(1, s)` then `!m.put_new(2, s2)` while `r` lives
- k10 reading `h` while `t = (!h).bump()&` runs
- c17 `!c.add((!c).swap(4))` with `c: !*Cell[Int]`

Still rejected, as they must be: every write of the place during the
call (c05, ch05, a02, sel02, k11, m05), every marked call through a
read view (c06, s03, ch02, a04, k15), and every `!@` call through a
plain `*T`, `*Frozen`, `*{A}`, or `~T`.

**Newly rejected: none for a held handle**, since a read loan conflicts
with a subset of what a write loan does, provided four points hold:

1. **sel03**, a select arm through `?*Chan`, is accepted today and the
   rule rejects it. The separate change rejects it first; until that
   lands, this rule alone would be the change that rejects it.
2. **An actor's call with `&`** keeps no loan on the place today (a06).
   "For as long as the call holds it" must mean the making of the call
   for an actor (the message takes a count of its own), but the task's
   life for a Cell-holding object's `(!h).bump()&`, whose self views
   the box the place keeps alive (k11 must stay rejected). Worded as
   one duration, one of the two breaks.
3. **A write-view result from a read-lent self.** k14 returns `!h.cell()`
   (a `!Cell[Int]`) out of `fun pick(h: !*Hits) -> !Cell[Int]`, accepted
   today with the result carried by a write loan. Under the rule the
   result is a write view whose loan is a read loan of the place; the
   implementation must keep k14 accepted (the result's write view
   reaches only Cells, already aliased across handles, k08).
4. **"Never a write view of the shared value"** is not what the callee
   gets: a Cell's or a Cell-holding object's self is still a `!Cell[T]`
   or `!Hits`, a write view that changes only Cells (SPEC 9534). The
   rule is exact about the *loan* (read, on the place), not the self's
   type; the docs must say both, or the sentence reads as false.

**One inconsistency the rule leaves.** It covers calls through a
handle, so c18 (`c: !Cell[Int]`, `!c.add((!c).swap(4))`) and k13
(`(!@).bump((!@).bump(1))` inside a Cell-holding object's `!@` method)
stay rejected while c01 and c17 become accepted. The same argument
covers them (a write view of a value that changes by mark), but it is a
second relaxation, not this rule; likewise `hit2(!h, !h)` (k04).

## 3. Where each lend is decided today

There is **one classifier for "may change through a handle"** and
**several for "what a marked call through one lends"**.

- `sema.changesByMark` (src/sema.zig 11520) is the one list of what a
  write lend may reach through a `*`: a Cell, a Signal, or a value
  holding a Cell by value. `holdsCellByValue` reads `ctx.holds(ty).cell`,
  which is true for `Cell`, `Actor`, and `Chan` (sema.zig 7686-7687), so
  actors and channels are on the list too.
- **typecheck.zig**: `requireAccess` (2385) admits the write lend
  through a handle via `lendsHandle` (2374) and `lendsMarked` (2346)
  and rejects it through a read view (2396-2401); `synthLend` (7083,
  at 7159) decides `!h` alone as `!*C` (`handleWritable`, 2361) or
  `!C`; `checkSelfMode` (17073) rejects a `!@` self through a `*T`
  unless `changesByMark`; `actorCall` (14810, dispatched at 13874 by
  `sema.actorOfHandle`) checks an actor's `!@`/`?@` marks, refuses `?a`,
  and records `recordActorCall` (14887); `taskSelect` (16112) and
  `taskSelectNamed` (16190) record `recordSelectArm`, and synthesize
  the arm's handle with `synthExpr`, never `requireAccess`, which is
  why sel03 passes.
- **ownership.zig**: `walkCallBody` (5615) takes the self's loan kind
  from the explicit `!` (`(write c)` gives `.write`) or `selfMode`
  (8773: an unmarked self of a `*T` is `.read`), then overrides it to
  `.read` when `sema.isActorCall` or `sema.selectArmOf` holds (5645-5647,
  "An actor call's `!` marks the call, not a lend"). So the read lend is
  a per-kind exception (actor, select arm) over the general write path,
  keyed by two facts typecheck records.
- **The oracle** (test/oracle/lower.zig, independently by design):
  `call` (3587) sets `actor_call` from `sema.actorOfHandle` and
  `arm_call` from the arm's parameters, and lends `.read` for them
  (3809); every other marked self goes through `handleSlot` (3171),
  which lends the handle's slot to write; `lend` (3270) does the same
  for `!h` alone.

So the rule would replace the exception list with one decision: a
marked call whose self place crosses a handle (`lendsHandle` in
typecheck, `handleSlot` in the oracle) lends that place to read, in
`walkCallBody` and in the oracle's `call`, with the select arm's handle
checked by `requireAccess` like any other self.

## Probe programs

In `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/inventory/`
(not durable), run by `run.sh` there (`rig check`, `rig run` when
accepted, `rig-oracle --sema -v`):

- Cell: c01_two_marked, c02_read_in_args, c03_view_then_set,
  c04_other_handle, c05_rebind_during, c06_through_view,
  c07_cas_get_set, c08_held_read_view, c09_cell_list, c09b_cell_list_ok,
  c10_cell_list_iter, c11_amp, c12_amp_rebind (a built-in's method is
  never a task: rejected in sema), c13_cell_list_two_handles,
  c14_field_handle, c15_bang_param, c16_bang_param_handles,
  c17_write_handle_param, c18_write_view_self, c19_value_field,
  c20_value_field_list, c21_swap_whole
- Signal: s01_signal, s02_signal_view_held, s03_signal_view
- Chan: ch01_two_marked, ch02_view, ch03_held_view, ch04_close,
  ch05_rebind, ch06_other_handle, ch07_amp, ch08_amp_two (both
  rejected in sema, as c11)
- select: sel01_two_arms, sel02_grow, sel03_view, sel04_arm_and_send,
  sel05_end, sel06_body_writes
- Actor: a01_nested, a02_rebind, a03_held_view, a04_through_view,
  a05_amp, a06_amp_rebind, a07_readm_marked, a08_write_view_arg
- plain `*T`: h01_list_push, h02_write_method, h03_bang_h_arg,
  h03b_repoint_only
- Cell-holding `*T`: k01_hits_nested, k02_hits_nested_arg,
  k03_hit_param, k04_hit_param_two, k05_hit_two_handles,
  k06_plain_field_write (a `!@` method writing a plain field or a List
  field: rejected in sema), k07_return_cell_view,
  k08_return_cell_view2, k09_view_and_call, k10_amp_task,
  k11_amp_rebind, k12_hits_view_held, k13_hits_write_view,
  k14_return_view_out, k15_hits_view_param, k16_view_of_plain_field,
  k17_view_two_handles
- std.shared: m01_shared_map, m02_shared_map_two,
  m03_shared_map_handles, m04_shared_map_string, m05_shared_map_rebind,
  m06_get_then_ensure
- API objects, Frozen, weak, tasks: p01_api_write, p02_api_read,
  p03_api_syncs, f01_frozen_write, f02_frozen_list, w01_weak,
  w02_weak_up, t01_tasks, t02_task_cancel

Not determined: the oracle's verdict where it abstains (Cell-of-List
calls, `*Frozen`, `*{A}` writes, std.shared); whether the ownership
checker, changed as answer 3 says, keeps k14 accepted (answer 2, point
3) without a further change.
