# Review of PR #917 (rv-selectfix)

Verdict: the fix holds. I found no memory error, double free, or leak left.
There is one medium issue: when a select hoists, each arm's channel
expression is evaluated after every arm's parts, so a program can see the
wrong order. There is also one low docs gap.

Probes are in `$TMPDIR/p917/` (`run.sh` runs a file with head and main
under RIG_SANITIZE=1). `concurrency-chan` and `errors-generic` are green
on head.

## Clean on head (RIG_SANITIZE=1)

Every probe below ran clean on head. Main failed on most of them with
signal 6.

- Capture modes: `|<s|` when its arm loses and when it wins, `|+s|` in
  two arms, `|!n|` beside `|?s|`, and a `|?o|` capture beside a
  `(!o.ch)` channel.
- Sends: moving out a field (`<o.name`), a send arm built by a function
  that fails (`mk(n)!`), and two generic send arms (`<x: T`).
- Structure: a closure inside an arm's closure, a select nested in an
  arm's body with `|!n|` at both levels, a select as an arm's sent
  value, a select in a loop of 20, and a select as a hoisted call's
  argument followed by `<s`.
- Waiting and failure: `time.within` with a deadline, `<w.cancel()` on a
  task waiting in a select, and a panic in an arm (out of bounds).
- Seeds: p30, every capture mode over 30 rounds under `--seeds=20`,
  passes on head and panics on main.

Programs CORE allows still check: `|?s|` beside `+s` or `String(t)`,
`n = select(|!n|)`, `n += select(|!n|)`, `<s` after the select, and a
select whose value is a `?String`.

## 1. Medium: a hoisted select evaluates its arms' channels after every arm's parts

- Where: `src/emit.zig:10077`, `hoistParts`. The select branch hoists
  only the arms' arguments. The arm emission at `src/emit.zig:9330`
  then evaluates each channel (`emitMemberBase(handle)`) inside
  `rig.selectInto(...)`, after every hoisted part. `storage.selfHold`
  records no `self` for an arm.
- p19 (side effects in the channel index):
  - head prints `arg 1, arg 3, self 1, self 2, self 3`.
  - SPEC §18 says "The select makes every arm, in order".
  - A select with no closure literal is not hoisted and runs in source
    order, so the order also depends on whether some arm captures.
- p29: `(!chs[i]).on_recv(...)` beside `(!chs[1]).on_send(bump(!i), ...)`.
  - Main receives from `chs[0]` and prints 9.
  - Head receives from `chs[1]` and prints 5.
  - The checker accepts it, because reading `i` copies it.
  - Memory is safe: a write to the list itself is rejected (p27).
- Fix: have storage record an arm's channel, when it holds a call or an
  index, as a `self` part with life `select` (as `callParts` does
  through `selfHold`). `hoistParts` then evaluates it before that arm's
  arguments, and the arm path reads the hoisted handle. Add p19 as a
  `code` or `test` case.

## 2. Low: newly rejected shapes missing from CHANGELOG and MIGRATING-0.3

Both docs list "takes or writes what another arm's closure views" and
"two arms lend one value to write". Three more shapes that main accepted
are now rejected, all correctly by CORE:

- p24: reading `n` (`on_send(n, ...)`) after an earlier arm's `|!n|`.
- p22: `(!a).on_recv(...)` beside `(!b).on_send(<a, ...)`, moving a
  channel another arm uses.
- p27: `(!chs[0])` beside `<chs`.

Fix: add these to the MIGRATING row, for example "reads, takes, or
writes what an earlier arm's closure or channel uses".
