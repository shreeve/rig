# Review 2: while-step-hotfix (fix 955fa5c6)

Reviewed: `955fa5c6` "Send every continue that targets a loop through that
loop's step", with 1972f26c for context. Worktree head is 4ff42874 (adds corpus
probes only). Branch `while-step-hotfix`, worktree /Users/shreeve/Data/Code/rig-while-step.
Binaries: `zig build` and `zig build oracle` in the worktree (bin/rig is current
with src/emit.zig). Main comparisons use /Users/shreeve/Data/Code/rig/bin/rig
(main 9e8ac153).

Probes: /Users/shreeve/Data/Code/rig/.git/revamp/r3/probes/review-while-step-2/

- `run.sh P...` checks each probe, runs accepted ones with `RIG_SANITIZE=1`, and
  prints oracle verdicts. `probes.out` holds the output for every hand-written probe.
- `gen2.py` and `gen2-run.sh` make a differential grid (125 programs) in `gen2/`.
  It covers outer condition {plain, joined, joined2, catch break, catch none} ×
  mid condition {plain, joined, catch break} × 11 paths. Steps, defers and drops
  print a trace, and every variant must print exactly what the plain/plain
  variant prints. Plain/plain lowers to Zig's own `while (c) |h| : (step)`, so it
  is correct by construction. Results are in `gen2.result`.
- `gen3.py` and `gen3-run.sh` extend the first review's grow/read grid in `gen3/`
  (70 programs). It adds 3-level nesting, mixed labels (`continue :outer`,
  `continue :mid`, `break :mid`, unlabeled `continue` in one body), and an
  unlabeled `continue` in an inner `for` within a joined outer loop. Results are
  in `gen3.result`.
- `old-gen.out` and `old-w.out` hold the first review's grid and w* probes,
  re-run on the new build. `oracle.out` holds the oracle sweep.

## Verdict

The fix is correct for what it targets. The redirect stack resolves an
unlabeled jump to the innermost loop and a labeled one to the innermost loop of
that name, at any depth. C1 and H1 of the first review are fixed:

- w04, w05, w12, w13, w14 and w15 print `25 5` / `21 5` sanitizer-clean.
- All 35 `read` cells of the first grid print `4004 4`, and all 35 `grow` cells
  are rejected.
- The new grids pass everywhere except the cells listed below.
- The commit's own test and `test/matrix.py -k step.` pass: 180 programs, 90 ran
  clean, 90 rejected, 0 failed.

**Soundness holes do remain.** There are two Critical holes in the same
feature, both in the emitter's step-inside lowering (`emitWhileJoined`), and both
predate the branch (main shows them too):

1. **C1.** When the body has no `continue` aimed at the loop, the step runs
   before the body's defers and drops.
2. **C2.** An unlabeled `continue` in a nested loop's `else` skips the step.
   This is the exact class the fix names ("a loop's step runs on exactly the
   paths the checker sends through it"), and the fix missed this path.

Both are accepted, and both end in `use of freed memory` under `RIG_SANITIZE=1`.

Label shadowing also gives accepted programs that Zig rejects (H1).

The oracle never rejects anything the compiler accepts. It abstains on every
joined condition, so it cannot see these holes. It accepts s01c, the `catch
break` form of C1, which shows the checker's model is the intended one and the
fault is in emit.

## Critical

### C1. A step that reads a binding runs before the body's defers and drops when the body has no `continue` to the loop: use of freed memory

Probes:
- `s01-step-before-body-defer-move.rig` (joined condition; the step moves `b`,
  which a body `defer` reads)
- `s01c-catchbreak.rig` (the same with `(mkf(?v, i) catch break) as h`)
- `s02-step-grows-body-defer-view.rig` (the step grows `w`, which a body `defer`
  reads through a view `s = ?w[..]` taken in the body)
- `s03-step-before-body-drop.rig` (a trace only: a body local's drop and the
  `defer` print after `step`, unlike the plain loop)
- `gen2/matchvalue.*.{joined,catchbreak}`: 10 cells whose trace differs from the
  plain reference
- `s01b-with-continue-ok.rig` is the control: the same program with a
  `continue if i == 99` in the body is correct.

```
cd /Users/shreeve/Data/Code/rig/.git/revamp/r3/probes/review-while-step-2
B=/Users/shreeve/Data/Code/rig-while-step/bin
$B/rig check s01-step-before-body-defer-move.rig        # accepted
RIG_SANITIZE=1 $B/rig run s01-step-before-body-defer-move.rig
```

Observed: rc 134, `error: rig: use of freed memory`, at the body's
`defer print("d", b[0])`. s01c and s02 behave the same. Main
(/Users/shreeve/Data/Code/rig/bin/rig) behaves the same.

Expected: `d 1`, `d 2`, `d 3`, then `end 6 3`, which is what s01b prints.

Shape:
```rig
while mk(?v, i) as h and i >= 0: k += h.s[0] + take(<b)
  i += 1
  b = fresh(i)
  defer print("d", b[0])
```

Emitted (`$B/rig emit s01-...`): the body statements and `{ step }` share one Zig
scope inside the `if`s, so the step moves `b` and then the body's Zig `defer`
reads it.

```zig
if (mk(&v, i)) |h| { if (i >= 0) {
    i += 1; b = fresh(i); defer rig.print(.{ "d", b.at(0) });
    { k += ... take(rig.take(&__rig_alive_b, b)) ... }   // step, before the defer
} else break; } else break;
```

Root cause: `emitWhileJoined`, src/emit.zig around lines 2155-2167. When
`step_inside` holds and `jumpsToLoop(body, rig_label, .cont, false)` is false,
the body is written with `emitStmts(stmtsOf(body))` and not as a block. The
checker (`loopIteration`, ownership.zig, "runs in the bindings' scope, after
the body's own scope ends") pops the body scope before `walkStep`. It therefore
runs the body's defers and drops first and releases their loans, and accepts a
step that moves or grows what they read. The INTERNALS text this commit adds
says `while true { x = a or break; { body }; step }`, but the emitted code drops
the braces in this case.

Class: the step runs at the point where the checker walks it. This is a sibling
of the class the commit names, on the fall-off-the-end path and not the
`continue` path. Siblings checked:

- With a body `continue`, the step is correct: the labeled block closes first.
- In a joined loop whose step does not read a binding, the step is correct: it is
  Zig's continue expression after the whole body.
- In a plain `while c as h: step`, the step is correct: Zig runs the continue
  expression after the body's defers.
- Inner loops (`gen2/matchvalue` with a joined or catch-break mid loop) are
  affected in the same way.

Fix direction: always emit the body as a block when `step_inside` is true, and
label it only when a `continue` targets the loop. Keep s01, s01c, s02 and s03 as
tests. s03 is the trace check. Add a matrix shape where the step moves or grows
what a body `defer` reads.

### C2. An unlabeled `continue` in a nested loop's `else` skips the step of a joined step-inside loop around it: use of freed memory

Probes:
- `e01-while-else-continue-joined.rig`
- `e01-for-else-continue-joined.rig`
- `e03-value-loop-else-continue-joined.rig` (the `else` of a loop used as a value)
- `e04-joined-inner-else-continue.rig` (the inner loop is itself joined, and its
  `else` runs behind the `__rig_ended` flag)
- `e06-else-loop-then-continue.rig` (a loop inside the `else`, then `continue`)
- Controls: `e02-while-else-continue-plain-ok.rig` (plain outer) and
  `e05-while-else-continue-labeled-ok.rig` (`continue :outer`). Both print
  `21 5`.

```
$B/rig check e01-while-else-continue-joined.rig          # accepted
RIG_SANITIZE=1 $B/rig run e01-while-else-continue-joined.rig
```

Observed: rc 134, `use of freed memory` in `take`. All five probes behave the
same, and so does main.

Expected: `21 5`, as e02 prints. SPEC says a `continue` in a loop's `else`
"leaves the loop around this one". The checker sends it to the outer loop's step
(`step_conts`).

Shape:
```rig
while mk(?v, i) as h and i >= 0: a = fresh(h.s[0])
  i += 1
  k += take(<a)
  j = 0
  while j < 2: j += 1
    k += 0
  else
    continue          # emitted as a bare Zig `continue` to `while (true)`: no step
  k += 100
```

Root cause (src/emit.zig). There are two independent defects:

1. `jumpsToLoop` (around line 1786) walks every child of a nested `while` or
   `for` with `nested = true`, the `else` included. The `else` runs after that
   loop, so its unlabeled jumps target the enclosing loop. The outer loop
   therefore sees no `continue` and makes no `__rig_body_N` block (e01, e03).
2. `emitWhile`, `emitFor` and `emitWhileJoined` push their redirect entry and
   pop it in a `defer` at function end, after `emitElse` (or after the
   `if (__rig_ended_N)` else in `emitWhileJoined`). An unlabeled jump in the
   `else` therefore resolves to the ended loop's own entry (`cont = null`) and is
   written as a bare Zig `continue`. Zig sends it to the enclosing `while (true)`,
   whose head has no continue expression. This holds even when a body block
   exists (e04, e06).

Class: the same as the commit's, "a continue that targets a loop goes through
that loop's step". The commit placed the scope of a loop's redirect, and of
`jumpsToLoop`'s nesting, around the loop's `else` as well, but the `else` lies
outside the loop. Siblings checked:

- A labeled `continue :outer` from an `else` is correct (e05).
- `continue :a` in loop `:a`'s own `else` is rejected (e07).
- An unlabeled `break` in an inner `else` is correct, because it leaves the
  enclosing Zig loop.
- A loop-as-value `else` (e03) fails through defect 1 alone, because
  `emitLoopValue` writes its `else` after the loop's entry is popped.

Fix direction:
- In `jumpsToLoop`, walk a nested loop's `else` with the caller's `nested`.
- Pop the loop's redirect entry (and, for `labelUsed`/`zigLabel`, treat the
  label as out of scope) before writing its `else`.
- Add the `else` path to the matrix's STEP_SHAPES:
  `while j < 2: j += 1` / `else` / `continue`, under joined and `catch break`
  conditions.

## High

### H1. Label shadowing: accepted programs fail Zig compilation ("accept means correct")

Probes:
- `l01-shadow-label-continue.rig` (`:a while J` holding `:a for` with `continue :a`)
- `l02-shadow-label-break.rig` (an inner `:a for` with `break :a`)
- `l03-shadow-label-joined-inner.rig` (the inner `:a` is a joined step-inside
  loop)
- `l04-shadow-label-match.rig` (an inner `:a match` with `break :a`)
- `e08-else-continue-shadowed-label.rig` (`continue :a` in the `else` of an inner
  `:a` loop, which names the outer `:a`)

```
$B/rig check l01-shadow-label-continue.rig && RIG_SANITIZE=1 $B/rig run l01-shadow-label-continue.rig
```

Observed: `rig check` accepts all five. Zig then fails:

| Probe | Zig error |
|---|---|
| l01, l03 | `unused block label` (`__rig_body_N`) |
| l02, l04 | `unused while loop label` (`a`) |
| e08 | `continue outside of loop or labeled switch expression` |

Expected:

| Probe | Output |
|---|---|
| l01 | `end 3 6` |
| l02 | `end 3 3` |
| l03 | `end 3 9 3` |
| l04 | `end 3 3` |
| e08 | `21 5` |

Alternatively, these programs should be rejected. SPEC says "A label may repeat
an enclosing one's name; the innermost is meant".

Root cause: the predicates that decide what the outer loop needs do not respect
label scope. `jumpsToLoop` matches any jump of the same name and does not stop
at a nested `.labeled` of that name. It drives the `__rig_body_N` block,
`keptLabel` and `stepLabel`. `labelUsed` does stop there, but it treats a
shadowing loop's `else` as inside the shadow (e08). `redirected` resolves the
jumps themselves correctly (innermost first), so the mismatch produces an unused
or missing label, not a misrouted jump.

The branch improves on main here. On main, l01's inner `continue :a` was
redirected to the outer body block, which is a misroute. Now it is a compile
error. No soundness hole was found in this class, because a label the
predicates over-count only adds an unused label.

Fix direction: give `jumpsToLoop` the same label-scope rule as `labelUsed` (stop
at a nested `.labeled` of the same name, except that loop's `else`). Fix
`labelUsed` for the `else` too, or derive both from one resolver.

## Low (carried over, unchanged)

- L1 of the first review: `w48-grow-then-return-ok.rig` is still over-rejected
  (the oracle reports `stricter`).
- L2 of the first review: `w32` (`stricter`), and `w21`/`w28` are sema rules,
  unchanged.

## Checked and sound

| Area | Probes | Result |
|---|---|---|
| First review's grid (5 conditions × 7 paths × grow/read) | `old-gen.out` | 35 read cells print `4004 4`, 35 grow cells rejected |
| First review's w01–w57 | `old-w.out` | Same verdicts as before. w04/w05/w12–w15 now correct; no regressions |
| p49/p50 review-copies corpus probes | run.sh over test/corpus | Same as before (p49e and p50c run clean, the rest rejected) |
| 3 levels (`for`→`while`→`for`, `while`→joined `:mid`→`for`), mixed labels, unlabeled `continue` in an inner `for`, `if`/`else` with a value | gen3 (70) | 35 read cells match the plain reference, 35 grow cells rejected (loan live) |
| Differential trace grid: deep3 (outer > mid > for, with `continue`, `continue :mid`, `break :mid`, `continue :outer`, `break :outer`), for > `while as`, `if`/`else`, `match` arms, `match` as a value, a `catch continue` / `?? continue` in a mid condition, `?? continue :outer` in a mid step, a loop as a value, a `defer` holding a loop, unlabeled `continue` in `for` and in `if` | gen2 (125) | 115 identical to the plain reference and sanitizer-clean. The 10 that differ are C1 (matchvalue) |
| Drop and defer order on `continue :outer` (body locals of the outer, mid and inner loops; a `defer` in each) | gen2 traces | Each value is dropped once and each defer runs once, innermost first and in reverse order, before the outer step. `break :outer` skips the step (`for_whileas`) |
| Closures | c01–c05 | `|| continue :outer` is a parse error. Block bodies and `?? continue :outer` are rejected ("a closure body cannot leave a loop around it"). A closure's own loop inside a joined body runs clean (c03) |
| `defer` bodies | d01–d03 | `defer continue :outer`, `defer` block `continue`, and `defer ... ?? continue :outer` are all rejected |
| `continue :a` in loop `:a`'s own `else` | e07 | Rejected |
| A jump in a nested condition | gen2 condjump* | A labeled jump cannot appear in a `while` header (grammar). An unlabeled `catch continue` / `?? continue` in a mid condition targets the mid loop correctly |
| Commit test `test/behavior/emit/while_step_nested_jumps.rig` | `RIG_SANITIZE=1` | `25 5 / 21 5 / 21 5 / 5021 5 / 3011 3` |
| `test/matrix.py -k step.` | via heavy.sh | 180 programs: 90 clean, 90 rejected, 0 failed |

Oracle: `bin/rig-oracle -v` over every new probe (gen2, gen3, s/e/l/c/d) gave
the counts below, by function. The first review's set, re-run in `old-w.out`
and `old-gen.out`, gave the same verdicts as before.

| prod | ref | Functions |
|---|---|---|
| accept | accept | 1080 |
| accept | unknown | 110 |
| reject | reject | 15 |
| reject | unknown | 27 |

There was **no compiler-accepts / oracle-rejects**. The only `stricter`
differences are the known w32 and w48. `ref=unknown` is every joined `and`
chain, which includes all the C1, C2 and H1 probes except s01c (the oracle
accepts it, the same as prod).

## The redirect fix itself

`redirects` is a stack. `redirected` scans from the innermost entry, takes the
first entry for an unlabeled jump, and takes the first entry whose `rig_label`
matches for a labeled one.

- The step and body entries carry the loop's label and sit above its loop
  entry, so jumps that target the loop from its step or body find them first.
  A labeled jump to an outer loop passes them by name.
- The nested-step case works because Zig allows a `break :blk` out of a
  continue expression (`deep`, `stepjump`).
- `keptLabel` is right to leave out the body's `continue :label` at any depth,
  since `__rig_body_N` handles those. It counts every labeled `break` (body,
  condition, step) and every `continue` in the condition or step. Its only
  defects are the shadowing over-count (H1) and the `else` scope (C2).
