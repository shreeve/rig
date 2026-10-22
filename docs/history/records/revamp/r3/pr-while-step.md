# Check a while step after the body, and send labeled continues through it

## Summary

This PR fixes two holes in how `while … : step` loops are compiled.
Both share one class: **a loop's step must run on exactly the paths
the checker sends through it, and nowhere else.** Two more holes of
that class remain in `emitWhileJoined`, and so does a label-scope bug.
All three are pre-existing and are left to the loop-lowering redesign
(see "Known remaining").

1. **The checker walked the step in source order (Critical).**
   `src/ownership.zig` checked the step where it is written, before
   the body. So the body could grow a Vec or Text that the
   condition's binding views, and the step then read freed memory.
2. **Emit dropped a nested `continue :label` (Critical, and High where
   it does not compile).** A `continue :outer` from a loop nested in
   the body did not reach the outer loop's step when that loop is
   written as nested `if`s, that is, a joined condition or one with a
   jump such as `catch break`. The checker sends that path through the
   step and emit skipped it, so the program used memory after it was
   moved or freed. When the step could not be skipped, the emitted Zig
   failed to compile instead.

Both holes are live in v0.2.2 and on main.

## Hole 1: the checker walked the step before the body

```rig
struct S
  s: []Int

fun mk(v: ?Vec[Int]) -> S?
  if v.len < 40
    return S(s: ?v[..])
  none

sub main
  v: Vec[Int] = Vec()
  !v.push(1)
  k = 0
  while mk(?v) as h: k += h.s[0]
    !v.push(2)
  print(k, v.len)
```

Main accepts this program, and under `RIG_SANITIZE=1` it stops with
"use of freed memory". The oracle rejects it (C4).

There were two causes:

- **Liveness is textual.** The step is written before the body, and
  `h` is declared inside the loop. So the body did not count the
  step's use of `h`, and `h`'s loan on `v` had already ended at
  `!v.push(2)`. A name declared before the loop was already handled:
  it stays live anywhere in the loop (p49c, p49f).
- **Scope.** The checker popped the binding's scope before it walked
  the step. So the step's `h` named no var, and anything the step did
  with `h` carried no loan. For example, w51 stores `h` into `last`
  through a call.

## Hole 2: emit dropped a nested `continue :outer`

```rig
:outer while mk(?v, i) as h and i >= 0: a = fresh(h.s[0])
  i += 1
  k += take(<a)
  j = 0
  while j < 3: j += 1
    break :outer if i > 100
    continue :outer if j == 2
```

`emit.zig` tracked where a loop's jumps go in one slot,
`Emitter.redirect`. `emitWhile` cleared that slot, so a `while` nested
in the body lost the outer loop's redirect
(`continue` → `break :__rig_body_N`). The `continue :outer` was then
written as a raw Zig `continue :outer`. That has two outcomes:

- If something else kept the Zig label, the `continue` jumped to the
  head of a `while (true)` that has no continue expression, so the step
  was skipped. The program then used `a` after the move, and later
  after the free (w14, w15).
- Otherwise the program did not compile in Zig ("label not found",
  "unused block label"). This affected w05, w12, and 18 cells of the
  review's generated grid.

The step of a `while` nested in the body, and a `while` used as a
step's region, had the same single-slot problem.

## The fix

The rule is stated as a desugaring in docs/INTERNALS.md (Control flow,
Emit "Loops"), and both the checker and emit follow it:

```
while c as x: step   ==   while true { x = c or break; { body }; step }
```

**`sema.stepReadsBinding`** is the one classifier for "the step reads
a binding of the condition". It moved out of emit, and emit and the
checker now both use it.

**Ownership** (`loopIteration`, `walkJump`, `indexUses`):

- A step that reads a binding is walked in the bindings' scope, after
  the body's own scope ends, so the body's defers run first.
- A `continue` in the body goes on to the step (`LoopCtx.step_point`
  and `step_conts`).
- A `continue` in the condition or in the step goes back to the head,
  as emit does. Any other step runs after the bindings' scope ends, as
  before.
- `indexUses` counts every use in a step just past the body
  (`stepAt`). While the step is walked, `stmtStart` and `stmtEnd`
  report that same position. So a view the step reads is live through
  the body.
- A `continue` inside the step used to be left out of the join at the
  loop's back edge. It is now joined there.
- The "moved in a previous iteration" note now takes into account that
  the step runs after the body.

**Emit:** `Emitter.redirect` is now a stack, `redirects`. Every loop
pushes an entry with its Rig label. A region that redirects its jumps
(a step, or a body that its step runs after) pushes its own entry. An
unlabeled jump takes the innermost entry, and `jump :L` takes the
innermost entry labeled `L`, from any depth: a nested `while`,
`while … as`, `for`, `match` arm, or an inner step. `keptLabel` needs
no change, because every labeled `continue` that targets the loop now
becomes `break :__rig_body_N`.

**typecheck is unchanged.** `checkStepUses` still rejects `?T`/`!T`
and owning bindings in a step. Those are storage facts: the storage
really ends with the body. They are not loan facts.

**Docs:**

- SPEC §6 `while` gets a `rig reject` example.
- SPEC's "How long a loan lasts" now lists the step.
- INTERNALS gives:
  - the desugaring;
  - the liveness rule;
  - the `continue` row of the exits table;
  - the loop lowering and the redirect stack.
- test/README describes the matrix additions.

## Siblings checked

Each sibling below is now either rejected or runs sanitizer-clean with
the right output.

**Plain `while c: step`, with a name declared before the loop**
(p49c, p49f, w08): already rejected, unchanged.

**Conditions.** The holes in this group are fixed:

- an optional condition (p49);
- `x!` (w37);
- `catch none`;
- `catch break` (w15);
- joined, either `a as h and c` (p49g, w05, w14) or `c and a as h`.

**How the step reads `h`.** These holes are fixed:

- a field;
- a method;
- a closure;
- a slice or String binding (p49b, p49d);
- a generic instance (w22);
- an optional of a view (w55);
- a call that stores `h` (w51).

**`for`:** it has no step, so it is unaffected.

**`continue` in the body:** the state on the `continue` path now
reaches the step. The test `while_step_after_continue_moved` fails if
that join is removed.

**`continue :outer` from a nested loop.** It now runs the step at any
depth: a `for`, a `while`, a `while … as`, a `match` arm, or an inner
step's `?? continue :outer`. This covers plain, joined, `catch none`,
and `catch break` outer loops. On the review's 70-cell grid, all 35
grow cells are rejected and all 35 read cells print the right output.

**`break` and `break :outer` from nested loops** leave the loop
without running the step. Their defers run once (the
`leaves` and `deep` cases in `while_step_nested_jumps`).

**Loops used as a value** (`break 7`, `continue`, `else`) give the
right value (w38).

**`defer` in the body** runs before the step (w07, w53).

**Over-rejections:**

- A path that leaves through `break` or `return` without reaching the
  step still keeps the step's loans live (the matrix
  `step.*.break.grow` cells and w48). Liveness is textual, and the same
  was already true for outer names (w32, on main too). These are
  classified prod-strict in `test/oracle/differences`.
- Making liveness path-sensitive is a separate change.

**Found and not fixed (not a memory issue):**
`while (f() catch continue) as h: step(h)`, a single `as` part with a
`continue` in its value, silently skips the step on that path. SPEC
says such a `continue` runs the step. For a joined condition,
typecheck rejects this form (w57); for a single part it does not. The
checker matches emit here, so the program stays sound. This is filed
as a separate task.

## Known remaining

The second review (`review-while-step-2.md`, probes in
`probes/review-while-step-2/`) found the issues below. All of them are
pre-existing: they are live on main and in v0.2.2, and this branch does
not introduce them. Under AGENTS, "a second soundness round stops the
feature", so they are not patched here. The loop-lowering redesign
fixes them next, as one desugaring.

- **s01, s01c, s02 (Critical).** These loops have a joined or
  `catch break` condition and a step that reads a binding, and no
  `continue` targets the loop. In that case `emitWhileJoined` writes the
  body without a block, so the step runs before the body's defers and
  drops. The checker walks the step after them. The result is use of
  freed memory. s03 is a trace of the same order.
- **e01–e06 (Critical).** These loops have a joined or `catch break`
  condition and a step that reads a binding. An unlabeled `continue` in
  the `else` of a loop nested in the body skips the outer loop's step.
  The checker sends that path through the step. The result is use of
  freed memory. A `continue :outer` from the same place is correct
  (e05).
- **l01–l04 and e08 (High).** These programs reuse a label name for a
  nested loop or `match` (`:a` inside `:a`). The predicates that decide
  what the outer loop needs (`jumpsToLoop`, `keptLabel`) do not respect
  label scope. So accepted programs fail to compile in Zig, with
  "unused block label", "unused while loop label", or "continue outside
  of loop".

## Tests

**New tests in test/reject/ownership and test/behavior:**

- `test/reject/ownership/while_step_reads_binding_after_grow.rig`
  covers 12 hole siblings.
- `test/reject/ownership/while_step_after_continue_moved.rig` covers
  the `continue` path reaching the step.
- `test/behavior/ownership/while_step_reads_binding.rig` holds the
  forms that stay valid. It prints values that show when the step ran.
- `test/behavior/emit/while_step_nested_jumps.rig` holds w05, w14, and
  w15, plus `continue :outer` from deep nesting and `break :outer`
  with defers.

**The matrix:** `test/matrix.py` gets a new
`step.<owner>.<holder>.<shape>.<then>` family of 180 cells. It has 15
loop shapes, including `continue :outer` from an inner `for`, `while`,
or `while … as`, under plain, joined, and `catch break` outer loops.
Each `read` cell must print the number of steps it ran.

On the base compiler:

- 42 of the 48 original grow cells crash with "use of freed memory";
- 24 of the new labeled `read` cells fail to compile.

On this branch, every one of the 180 cells is rejected or runs clean
with the right output.

**The corpus:**

- `test/corpus/review-copies-p49*`, `p50*`;
- `review-while-step-w*` (all 53);
- 10 cells from the generated grid (`review-while-step-gen-*`).

Each carries the oracle's verdicts.

**SPEC:** a new `rig reject` example.

## Verification

- Gates on pup (`pup-gates.sh`, `PUP_CORES=12`, head 4ff42874;
  logs in `logs/while-step/pup2.*`):
  - suite: 2702 passed, 7 pending, 1 failed. The failure is
    `cli/test_out_dir`, which timed out after 120 s under the run's
    load. Rerun alone on pup at -j 4, all 23 cli tests passed.
  - corpus: 6422 passed, 0 failed.
  - matrix: 3817 programs; 1543 ran clean, 2274 rejected, 0 failed.
  - `zig build test` with a fresh cache: 124/126 passed, 2 skipped
    (the aarch64-only tests).
  - oracle, doc and vocab: 326 passed, 7 pending, 0 failed.
- Mac, targeted (`./test/run while step loop label continue break
  classify parser doc/SPEC doc/docs/INTERNALS review-copies
  review-while-step emit`): 1615 passed, 0 failed. `zig build test`
  with a fresh cache: 125/126 passed, 1 skipped.
- Equivalence (`test/equiv.py`, base main 9e8ac153): 8727 programs, 31
  differ, all explained below. No program outside the new tests and
  probes changed.
  - **20 programs go from accepted to rejected.** 19 are holes, and on
    the base compiler each one:
    - crashes with "use of freed memory": p49, p49b, p49d, p49g; w22–w25,
      w27, w37, w54, w55; gen catchnone-whilefor-grow; the new reject
      test; the new SPEC example;
    - fails to compile in Zig: gen joined-while-grow,
      joined2-whilefor-grow, catchbreak-match-grow;
    - or stores a loan the checker never saw: w51.

    The 20th is w48. It is the over-rejection described above, and it
    is classified.
  - **1 program changes only a note's wording:**
    `while_step_after_continue_moved` is rejected by both compilers.
  - **10 programs change only their emit output.** All are labeled
    `continue`s through a joined or `catch break` outer loop:
    `while_step_nested_jumps`, w05, w12, w14, w15, and the gen read
    cells catchbreak-match, catchbreak-whileas, joined-match,
    joined-while, and joined2-forwhile. On the base compiler each
    fails to compile, or skips the step and uses memory after it was
    moved or freed. No other program's emitted Zig changed.
