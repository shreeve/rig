# Review: while-step-hotfix

Reviewed head: `9bbbdca39ae6b8af301e504627576cbc5c944311` (branch `while-step-hotfix`,
worktree /Users/shreeve/Data/Code/rig-while-step), two commits over main 9e8ac153:

- 1972f26c Check a while step after the body, where it runs
- 9bbbdca3 Keep the review-copies p49 and p50 probes in the corpus

Binaries: `zig build` and `zig build oracle` in the worktree. Main comparisons use
/Users/shreeve/Data/Code/rig/bin/rig (main 9e8ac153).

Probes: /Users/shreeve/Data/Code/rig/.git/revamp/r3/probes/review-while-step/
(`run.sh P...` checks each probe, runs accepted ones with `RIG_SANITIZE=1`, and
prints oracle verdicts. `gen.py` with `gen-run.sh` builds and runs the 70-program
labeled-continue grid in `gen/`.)

## Verdict

The checker change is correct for what it targets. Every p49/p50 probe and every
probe below that grows, clears, drops, moves or reassigns what the step reads is
rejected. The valid shapes (p49e, p50c, w36, w46, w47, w49, w50, w52, w53) run
sanitizer-clean with the right output. The oracle never rejects anything the
compiler accepts (sweep: 123 programs, 377 functions, only 2 `stricter`
differences).

**A soundness hole does remain** in the same feature: the step can be skipped. One
emit bug in the lowering of a `while` whose step reads a condition binding lets a
`continue :outer` from a nested `while` bypass the step. The checker walks that
path through the step, so it accepts programs that then use moved and freed
memory. This is live in v0.2.2 and on main, and the hotfix does not touch it. The
branch's test comment and SPEC/INTERNALS say a `continue :outer` from a nested
loop goes on to the step, but that is true only when the nested loop is a `for`.

## Critical

### C1. `continue :outer` from a nested `while` skips the step of a joined or jump-condition `while` whose step reads a binding: use of freed memory

Probes:
- `w14-labeled-continue-skips-step-uaf.rig` (joined condition `mk(?v, i) as h and i >= 0`)
- `w15-catchbreak-continue-skips-step-uaf.rig` (single condition with a jump: `(mk(?v, i) catch break) as h`)

```
cd /Users/shreeve/Data/Code/rig/.git/revamp/r3/probes/review-while-step
/Users/shreeve/Data/Code/rig-while-step/bin/rig check w14-labeled-continue-skips-step-uaf.rig   # accepted
RIG_SANITIZE=1 /Users/shreeve/Data/Code/rig-while-step/bin/rig run w14-labeled-continue-skips-step-uaf.rig
```

Observed: `rig check` accepts, and the run aborts with
`error: rig: use of freed memory`, rc 134, in `take` → `a.at(0)`. w15 behaves the
same. The oracle accepts w15 (`ref=accept`) and abstains on w14 (joined). Main and
v0.2.2 behave the same.
Expected: the program prints `21 5`, because each `continue :outer` runs the step
`a = fresh(h.s[0])`, which refills `a`. Otherwise it should be rejected.

The shape:
```rig
:outer while mk(?v, i) as h and i >= 0: a = fresh(h.s[0])
  i += 1
  k += take(<a)
  continue if i > 200          # a direct continue keeps the body block label used
  j = 0
  while j < 3: j += 1
    break :outer if i > 100    # keeps the Zig label `outer`
    continue :outer if j == 2  # emitted as Zig `continue :outer`: skips the step
```

Emitted Zig (`bin/rig emit w12-...`):
```zig
outer: while (true) {
    if (mk(&v, i)) |h| { if (i >= 0) {
        __rig_body_2: { ... while (j < 3) : ({ j += 1; }) { ... continue :outer; } }
        { a = fresh(h.s[0]) ... }          // step, never reached by `continue :outer`
    } else break; } else break;
}
```

Root cause (src/emit.zig):
1. `emitWhile` (lines 2055-2058) calls `shieldRedirect()` and then sets
   `self.redirect = null`. A nested `while` therefore drops the outer loop's
   step-inside redirect (`cont = "break :__rig_body_N"`, set at line 2153). A
   `continue :outer` inside it is emitted as a raw Zig `continue :outer`. `emitFor`
   only shields, which is why the branch's tests and the matrix pass: their
   `labeled` shape uses an inner `for`.
2. `keptLabel` (lines 2172-2183) does not count `continue :label` in the body, so the
   Zig label is usually dropped. The result is a Zig compile error (C2). When
   something else keeps the label (a `break :outer` in the body, or a jump in the
   condition or step), Zig compiles `continue :outer` to the head of
   `while (true)`, which has no continue expression, so the step is skipped.
3. The checker (`loopIteration`, `exitTo` with `t.step_point`) sends that continue
   through the step, as SPEC and INTERNALS say. The checker and emit therefore
   disagree. A move or drop that the step's reassignment was meant to repair is
   seen again on the next iteration.

Class: any jump that names an outer step-inside loop from inside a construct that
resets `self.redirect`. That covers every nested `while`, whether plain, stepped,
`as`, joined, or under a `for` or `match`. Siblings checked with the `gen/` grid:
conditions {plain, joined, joined2 `n >= 0 and ... as h`, `catch none`, `catch break`}
× paths {for, while, while+if, for→while, while→for, while-as, match→while}. Every
`grow` cell is rejected. The `read` cells fail exactly where the outer loop takes
`emitWhileJoined` with step-inside (joined, joined2, catch-break) and the continue
sits inside a `while`: 18 cells, all accepted, then a Zig compile error. The plain
and `catch none` outer loops use Zig's own continue expression and are correct
(w13, w04).

Fix direction: replace the single-slot `redirect` with a stack searched by Rig label,
or have `emitWhile` shield instead of clear, and resolve a labeled jump against
every enclosing redirect. Count nested `continue :label` in `keptLabel`, or drop
the need for it. Add `while` and joined or `catch break` conditions to the matrix's
`labeled` STEP_SHAPE. w14, w15, w05 and the gen `*.while.read` cells are regression
tests.

## High

### H1. The same bug fails Zig compilation: accepted programs do not build ("accept means correct")

Probes: `w05-labeled-continue-inner-while-joined.rig`, `w12-labeled-continue-skips-step-move.rig`,
and 18 cells in `gen/` (`joined.while.read`, `joined.whilecond.read`, `joined.forwhile.read`,
`joined.whilefor.read`, `joined.whileas.read`, `joined.match.read`, the same 6 for
`joined2.*` and for `catchbreak.*`).

```
/Users/shreeve/Data/Code/rig-while-step/bin/rig check w05-labeled-continue-inner-while-joined.rig   # accepted
RIG_SANITIZE=1 /Users/shreeve/Data/Code/rig-while-step/bin/rig run w05-labeled-continue-inner-while-joined.rig
```

Observed: `__rig_main.zig: error: label not found: 'outer'`. w12 instead fails with
`error: unused block label` for `__rig_body_2`.
Expected: prints `25 5`.
Root cause: C1 (1) and (2). This is the visible face of the same defect. It is
listed separately because these are valid programs that a user would write first.

## Low

### L1. New over-rejection: growing on a path that `return`s before the step

Probe: `w48-grow-then-return-ok.rig`

```
/Users/shreeve/Data/Code/rig-while-step/bin/rig check w48-grow-then-return-ok.rig
/Users/shreeve/Data/Code/rig-while-step/bin/rig-oracle -v w48-grow-then-return-ok.rig
```

Observed: rejected with `cannot lend v to write while a read loan is live`, while
the oracle prints `stricter ... run prod=reject ref=accept`. Main accepts it.
Expected: accepted (prints 4). The push happens only on a path that returns and
never reaches the step.
Root cause: textual liveness. The step's use of `h` counts at `stepAt` for the
whole body, whatever path leads there. The six allowlisted `step.*.break.grow`
matrix entries are this same class. `return`, and presumably a `break :outer` to
an enclosing loop, is an unlisted sibling. It is not a gate failure today, since
no corpus or matrix program has the shape, but it would become one if w48 were
added to the corpus. Classify it with the `break` entries.

### L2. Pre-existing over-rejections (not introduced by the branch; listed for completeness)

- `w32-outer-repoint-after-grow-ok.rig`: the body grows `v` and then re-points the
  outer slice before the step reads it. This is rejected on main too, and the
  oracle reports it as `stricter`. A var declared outside a loop is live anywhere
  in the loop.
- `w21-write-view-binding-ok.rig`, `w28`: a step may not use a `?T` / `!T` binding
  ("a view that lives only in the body"). This is a sema rule, the same on main.

## Checked and sound (all rejected or run clean, oracle agrees or abstains)

| Area | Probes | Result |
|---|---|---|
| Original holes | review-copies p49, p49b-g, p50, p50b, p50c | p49 family and p50/p50b rejected; p49e, p50c run clean |
| Owned binding read in step (Vec, Text, `*T`) | w01, w02, w03 | rejected by sema ("ends with the body before the step runs") |
| Owned binding dropped before a step that does not read it; plain and joined; `continue` | w50 | runs clean, drop before step on every path |
| Joined condition with a `drop`-body binding and a step reading `h` | w40, w41 | sema rejects w40; w41 runs clean |
| `continue :outer` via inner `for`, plain/`catch none` outer via inner `while` | w04, w13, gen | correct output |
| Body re-points an outer view or write view at a body local | w06, w31 | rejected (does not live long enough) |
| Body `defer` reads `h` and grows; valid `defer` with `continue` | w07, w53 | rejected / 3212 |
| Step grows what an outer view, a closure, or the condition reads | w08, w09, w10, w30 | rejected |
| Body stores `h` in an outer var, step grows | w11 | rejected |
| Step stores `h` through `keep(!last, h)` | w51, w52 | rejected / runs clean |
| Generic instance holding the view | w22 | rejected (oracle abstains) |
| Reassign, move, or drop the source in the body | w23, w24, w25 | rejected |
| `*T` handle: reassign a lent handle; clone and drop | w26, w27, w33 | rejected / runs clean |
| Weak handle upgraded in the step, strong replaced | w29 | runs clean (`0 1`) |
| Cell view binding in the step | w28 | sema rejects (view binding) |
| Temporary viewed by a binding or by the step's assignment | w34, w42 | rejected |
| Step re-points an outer slice that the body reads after a push | w35 | rejected |
| Condition writes `v` and binds a view; step reads it | w36 | runs clean |
| Fallible condition `mk(?v)! as h` | w37 | rejected |
| Loop as a value: `break 7`, `continue`, `else` | w38 | correct (`7 209 4`) |
| Joined loop `else`, `continue` | w39 | correct |
| `h` immutable; shadowing with `new h` in the body (plain, joined) | w43-w47 | rejected / step reads the condition's `h` |
| Optional-of-view binding | w55 | rejected |
| Step and its own `grow(!w) + h.s[0]` in one statement | w54 | rejected |
| `continue` in the condition with a step reading a binding | w57 | sema rejects |
| Branch matrix `-k step.` (96 programs) | via heavy.sh | 48 ran clean, 48 rejected, 0 failed |

Loop forms covered: `while c: step` (Bool), `while c as h: step` (optional, fallible
`!`, `catch none`, `catch break`), joined `a as h and c` and `c and a as h`, labeled
loops, loops nested in the body (`for`, `while`, `while as`, `match`), `continue`,
`continue :outer`, `break`, `break :outer`, `break x` with `else`, `return`, `defer`
in the body and in the enclosing scope, and loops as values. `for` has no step in
the grammar. As the step's use of `h`: a field, a method, a closure (branch test),
a call that stores it, compound assignment, and `??`. (`if as` cannot appear in a
step.) As `h`: a slice, a String, a struct holding a view, a generic instance, an
optional of a view, a write view, a Cell view, and `*T`/`~T`.

## Checker vs emit

- Plain `while c as h: step` (no join, no jump in the condition): Zig
  `while (c) |h| : (step) body`. Body defers and the binding's drop run before the
  continue expression, and every `continue`, labeled or not, runs it. This matches
  the checker in both the step-inside and step-outside cases.
- Joined or jump-condition, step not reading a binding:
  `while (true) : (step) { if (a) |x| {...} else break; }`. Every `continue`
  (including one in the condition) runs the step after the bindings end. This
  matches.
- Joined or jump-condition, step reading a binding:
  `while (true) { if (a) |x| { __rig_body: { body } { step } } }`. A direct
  `continue` becomes `break :__rig_body`, which matches. A labeled
  `continue :outer` from a nested `while` does not match (C1). A `continue` in the
  condition is rejected by sema when the step reads a binding (w57), so the
  checker's "continue in the condition goes back to the head" path is unreachable.
- `stepAt` = body end + 1. It lies before the `else` and before the next
  statement, so liveness after the loop is unaffected. `stmtStart` and `stmtEnd`
  during the step use it, which is conservative.
