# PR #688 panel, adversary A: drops, flow, paths

Head 9ea69ee13 built in ~/Data/Code/worktrees/rig/panel688a (bin/rig, bin/rig-oracle).
Main: ~/Data/Code/worktrees/rig/span-type/bin/rig. All runs RIG_SANITIZE=1, RIG_OUT_DIR=scratch.
Probes: /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/1762ad8a-9823-467a-b54f-a392863cb42c/scratchpad/p688/{a1..a10,r1..r6}.rig, run.sh.
Field type `Tok` has a `drop` body that prints, so every drop is visible.

## Accepted (PR), each value dropped exactly once, sanitizer clean, oracle agrees
- a1: `if <p.t as x` without else (some / none), `match` arm moves / other arm not,
  early return vs fall-through, loop move+break (with a continue on an earlier turn).
- a2: error after the move, error before the move (t drops on the error path),
  `!` propagation after/before the move, `(<p.t)?` with none and some,
  `?` propagation before the move, `errdefer` reading `p.name` while `p.t` moved.
- a3: nested `<p.a.b` (b optional): p.a.c and p.name still readable, all drop once;
  `if <q.a as i` then `<i.b` (as-bound keeps the take: i.b == none true); `=!` local move.
- a5: `once` closure `|<p|` moving `p.t`, called and not called; task `eat(<p.t)&`.
  Oracle abstains on both (closure holding a drop-body value; task).
- a6: linked list `<n.next` (^Node?) of a parameter, recursive; `w =! !q` keeps the take.
- a7: `if <p.t as x and x.n > 5` false: x dropped before the else.  while + return.
- a8: generic `Two[T]` with T = Tok (some, none); `<@val` in `fun drained(<@)`.
- a9: `=!` local declared in a loop body, moved on alternate turns, continue/break:
  flag resets per turn, every value once.
- a4/a10 (also on main, identical output): loop var `for p in <ps`, `if <o as s`,
  `match <o` payload binding, `|!p|` capture of an assignable local: all keep the take.

## Rejected (PR), oracle agrees on every one
- r1: errdefer reads moved `p.t` (C1); errdefer moves it (B2); else branch reads `p.t` (C1);
  move + continue, next turn (C1); `<p.t?` (C3, "move it before the `?`"); passing p whole.
- r2: else-branch read of a *name* moved in the condition is rejected the same way (consistent);
  `<p` after `<p.t`; `<p.a` after `<p.a.b`, also for a `=!` local (C1).
- r3: read loan then move (C4); conditional move then read / then `<p` (C1);
  box param `<b.t` (C3, new message).
- r4: inner break, outer next turn (C1); while next turn (C1).
- r5: `?p` and `|?p|` after the move (C1); `|?p|` live before the move (C4).
- r6: `|?p|` once capture `<p.t`: read-view take rejected, same as main.

## Meaning of old programs
- `=!` local take, read as none after: rejected on main ("cannot take fixed binding") for a
  moving optional; for a copying optional still a take and still rejected (m1). Nothing to change.
- Loop, as, match bindings and write views/captures keep the take: identical output on main.
- Structural argument: where fixedOwner is true, requireBinding(.take) fails (param/capture not
  write view, fixed local not write view), and fixedOwner refuses every path step requireAccess
  would mark `blocked`/`indirect` except a box, which moveField then rejects. So only rejected
  programs change.

## Findings
1. (Low, message) `fun boxed(b: ^P) -> Int: eat(<b.t)` now says
   "cannot move out of `b.t`: a box frees what it holds as one; take the box's value with
   `<b.unbox()` first" (was "cannot take parameter `b` ... take `b: !^P`"). Still rejected,
   oracle agrees. fixedOwner could list `.box` (sema.boxedType) to keep the old take message;
   either message is correct.
2. (Info, coverage) Oracle abstains on the once-closure and task cases (a5); compiler output is
   correct there, but nothing independent checks it.
3. (Info) Else-branch rejection is right: it matches names (`if <t as x ... else t`), and in the
   else the field is known none, so nothing useful is lost.

Verdict: sound.
