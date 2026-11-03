# After 33D: the oracle taught CORE §6, then the `for` header (t05)

Written 2026-11-01 by Rig language analysis, after #859 (33D) merged as 183e9820d. These are two
rows, one after the other. The owner approved both as decisions 4 and 5 of
`core-33d/draft-2.md`. Each starts with `wt new NAME` from main and follows AGENTS.md "How a
change is made". Queue keeper: Rig - Swiss.

## Row 1: teach the oracle CORE §6 (tests only)

**Goal.** `bin/rig-oracle` (`test/oracle/`) is a second ownership checker written from CORE alone.
It doesn't model CORE §6's paragraph as #859 rewrote it (docs/CORE.md §6, "A call evaluates its self
and arguments left to right..."). It copies out a view argument where it stands, so it accepts
`print(r, poke(!a))` with `r = ?a`, which the compiler rejects. Teach it the paragraph from the CORE
text, not from `src/ownership.zig`, the way the oracle was written:
- Plain data read as a value (an operand, a field or element read, an argument of a plain type) is
  copied where it stands and keeps nothing lent.
- Whatever else an earlier argument or operand hands over (a view, which `print` and `String`
  arguments are; a value that shares storage its place owns; what a write view reaches) stays
  lent, to read, until the call returns or the operator yields.

**Where.** `test/oracle/lower.zig`, 4652 lines. Calls are lowered in `call` (about line 3499) and
`callParts` (about 1149). Argument carries are in `resultCarry` and `isArgVar` (about 3980–4157).
Draft 2 put the change near lines 2553 and 3840 and estimated 40–80 lines. The oracle lowers to
explicit temporaries and runs liveness in `flow.zig`. The likely shape: a view argument's
temporary, or an operand's, is used again at the call or operator, so it stays live through the
later arguments. A plain copy isn't.

**Done when.**
- The 15 `ref-gap` lines whose note cites "Core §6" are reported FIXED and deleted from
  `test/oracle/differences`. They are the `{int,plain,array,simd}.arg_then_write.{read_view,write_view}`
  lines, `box/plain/array.arg_then_write.destructure_view`, and
  `{int,plain,array,simd}.arg_then_write.destructure_write`.
- Nothing the oracle accepts today turns into a compiler-accepts-oracle-rejects DIFF. That would
  mean the compiler is unsound or the oracle is wrong; find out which, and never delete a line to
  get green.
- New rejections are added to `test/oracle/rejections` in place. Don't re-sort that file: it isn't
  sorted, and sorting it makes a 3,500-line diff.
- The coverage floors in `test/oracle/coverage` hold.
- The gates are the full suite (`swarm test/rig.rip all -q -w 6`, which runs the oracle and the
  matrix). Tests only, so no Trig, loco, json or hash gates, and the PR says so.
- One command shows every finding: `bin/rig-oracle --set tests --allow test/oracle/differences
  --rejects test/oracle/rejections --coverage test/oracle/coverage --list
  .zig-cache/rig-tests/oracle/tests.list`. For the matrix: `python3 test/matrix.py --oracle -k
  arg_then_write`.

## Row 2: the `for` header (t05)

**Goal.** Accept `review-header-paths-1-t05` (still a `prod-strict` line in differences):

```rig
a = !xs[0]
b = !ys[0]
for x in a.arr      # (a if c else b).arr in the original
  ...!xs.push...    # in the body
```

`a.arr` is a plain `[3]Int` copied once when the loop starts. Today a use in a `for` header
counts as a use in the loop (`LoopCtx.start` includes the header, `src/ownership.zig`
`loopStartFrom`). So `a`, declared outside the loop, stays live through the body, and the write to
`xs` conflicts with it.

**The rule** (fits sentence 6; check with Swiss whether CORE §3 needs a clause): a `for` header runs
once, before the first pass. A `while` condition runs on every pass. So a use in a `for` header
belongs to the loop's entry, not to its body, but only where the header copies its source out.
Where the loop reads its source in place (a view, a List), it reads it on every pass (CORE §3),
and the source must stay live.

**Cases.** These come from `core-33d/expert-adversary.md`.
- **Accepted:** t05 and t05c (`arr = a.arr` first, already accepted).
- **Rejected:** t05w (a `while` condition, in `ownership-last`); for1b, for3 and `for x in ?v`,
  all with a body that writes the source's owner (in `ownership-last`).
- **The adversary's t05r and t05s:** read their notes before deciding.
- **Must stay rejected:** a `for` over a view or a List whose body grows it. A wrong acceptance
  there reads freed memory, which the sanitizer catches.

**Size.** Small: about 20–40 lines in the `for` walk (`walkFor`) and liveness (`liveFrom` /
`loopStartFrom`), plus about 6 cases. Its differences line goes.

**Gates.** It's a compiler change, so the full set:
- the full suite and `zig build test`;
- `tools/emit-diff BASE`, which must be identical, Trig included (`emit-diff` checks Trig too);
- loco's light gate;
- Trig's light gate, waived if Trig's emit is identical;
- basecheck, then "ready #N SHA" to Rig - Swiss.

## Lessons from 33D

- `tools/emit-diff` runs `rig check` on Trig, and it caught a false rejection: the copy rule
  tainted a type parameter's value in Trig's generic multimap. Run it early, not only at the end.
- A closure literal's type holds no view, but the closure carries its captures. Any "loan-free
  value" shortcut has to exclude callables and type-parameter values (`carriesNoLoan`).
- In a zsh command, `echo ===X` fails and ends the `&&` chain. Use `echo "-- X"`.
