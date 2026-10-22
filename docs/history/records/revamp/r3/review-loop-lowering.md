# Review: loop-lowering (head bd04787e)

Reviewed: `git diff 0a10f99c...loop-lowering` (b3a204c5 the lowering, 9923ab96 /
5f02f3d7 the matrix, b7fbef05 / bd04787e the tests), in the worktree
/Users/shreeve/Data/Code/rig-loop-lowering. Binaries: that worktree's
`bin/rig` and `bin/rig-oracle`. The base 0a10f99c was built from `git archive`
(probes/review-loop-lowering/rig-base-0a10f99c, and on pup
`~/Data/Code/rig-bases/0a10f99cc316/rig`). Main is /Users/shreeve/Data/Code/rig/bin/rig
(28f20fc4).

Probes: /Users/shreeve/Data/Code/rig/.git/revamp/r3/probes/review-loop-lowering/

- `run.sh P...`: `rig check` with the branch and with main. Accepted probes run
  under `RIG_SANITIZE=1 timeout 20`. Prints the oracle's verdict.
  `probes.out` holds the output for every hand-written probe.
- `gen4.py` and `gen5.py`: a random grid of nested loops. Each generated
  program comes with the trace that a Python model of SPEC's loop semantics
  predicts (see "Grid" below).
- `run4.sh DIR [RIG]`: checks each program, runs the accepted ones sanitized
  with `timeout 20` and compares each with its `.expect`, then runs the oracle.
  It runs only on pup, through `pup.sh`.
- `check-all.sh`: `rig check` with two compilers over all 8884 `.rig` files
  under `test/` and `examples/`. The results are in `check-all.out` (against
  main) and `check-all-base.out` (against base).
- `*.result`: the pup runs.

## Verdict

**No soundness hole found.** I found no loop path where the emitted Zig runs
code in a different order, or on a different set of paths, from the ones the
ownership checker walks. That covers 4300 generated nested-loop programs and
16 hand probes. Every accepted program printed exactly the trace the model
predicts, ran sanitizer-clean, and was accepted by the oracle too.

On the same 1500-program grid, base 0a10f99c fails 378 programs:

| Failure on base | Programs |
|---|---|
| use of freed memory | 143 |
| wrong trace | 224 |
| runaway (`cap`) | 5 |
| Zig compile error ("continue outside of loop", "unused while loop label", "label not found") | 6 |

The grid can therefore see the classes the earlier reviews found, and the
branch closes all of them.

The one finding above Low is pre-existing on base and on main, and it cannot
corrupt memory (emit fails with an internal error). It is M1, below.

The new typecheck rule is the minimal rejection under the current grammar. It
flips nothing but its own test.

## Critical

None.

## High

None.

## Medium

### M1. A step that reads a condition binding only through a closure capture is accepted, then emit fails (pre-existing; the new rule has the same blind spot)

Probes:
- `c02-step-closure-reads-binding.rig`: `while some(odd(i) ?? break) as h: steps = apply(|+h, x: Int| x + h, steps)`
- `c01-step-closure-reads-binding-cond-continue.rig`: the same with `?? continue` in the condition

Commands:
```
cd .git/revamp/r3/probes/review-loop-lowering
./run.sh c01-*.rig c02-*.rig
```

Observed (branch, base 0a10f99c, and main 28f20fc4 all behave the same):
- `rig check` accepts both programs.
- `rig run` stops with "internal error: cannot emit a capture of a name that is
  not a local (sema should have rejected it)", from `emitCaptureInit`.
- On c01 the oracle reports a difference: `main prod=accept ref=reject C1 17:56
  use of h after move`. The reference sees that the condition's `continue`
  reaches a step that reads an unbound `h`.

Expected: c02 is either accepted and run (the step goes inside the binding's
scope), or rejected with a diagnostic. c01 is rejected by the new rule ("the
loop step reads `h` ... which a `continue` in the condition leaves unbound").

Root cause: `sema.stepReadsBinding` (`usesSymbol`) and typecheck's `findUse` both
compare symbol ids, and inside the closure `h` names the capture's own symbol,
not the condition's binding.
- So emit and the checker agree that the step reads no binding, and the step
  becomes the Zig continue expression, outside `if (...) |h|`. emit then cannot
  find `h`.
- `checkStepBindings` misses the read for the same reason, so the rule this
  branch extends does not fire on c01.

Since emit always fails here, nothing miscompiles. It still breaks AGENTS rule 2
(accept means correct).

Fix of the class: make "the step reads a binding of the condition" see through
captures (a capture's outer symbol counts as a use), in one place that both
`stepReadsBinding` and `findUse`/`checkStepBindings` use. That puts c02's step
inside the binding's scope (and through `checkStepUses`), and makes c01
rejected.

## Low

### L1. A labeled jump after `??` / `catch` cannot be written in parentheses or in a `while` header, and the parser's message is self-contradictory (pre-existing)

Probe: `a01-cond-continue-outer-step-reads-binding.rig`.

`while some(odd(i) ?? continue :outer) as h` fails with:
```
error: unexpected keyword `continue`; expected `return`, `break` or `continue`
```

The forms below were tried and none parses:
- `(odd(i) ?? continue :outer) > 0`
- `catch continue :outer`
- the unparenthesized forms

SPEC §12 says a jump after `??` or `catch` may name a label. That works only as
a statement, as in `x = odd(i) ?? continue :outer`.

Consequence for this branch: `hasContinue` counts every `continue`, labeled or
not. If a labeled `continue :outer` in a condition ever became writable, the
rule would wrongly reject it, since that jump leaves the loop and never needs
the binding. Today the case is unreachable. When the grammar allows it,
`hasContinue` should count only a `continue` that targets this loop.

### L2. `checkStepBindings` says "a binding of a joined condition" now that it also runs for a single `as`

That branch of the diagnostic looks unreachable for a single `as`, because
`checkStepUses` rejects a view or owning binding first. The wording is still
stale; "a binding of the condition" would fit both.

## Question 3: the new typecheck rule

**Branch against base 0a10f99c**, over all 8884 `.rig` files under `test/` and
`examples/` (`check-all-base.out`): accepted→rejected is exactly one file,
`test/reject/effects/while_step_binding_condition_continue.rig`, the rule's own
test. Nothing else differs in either direction.

**Branch against main 28f20fc4** (`check-all.out`): 9 files differ, all main
accepting and the branch rejecting.
- One is the same new test.
- The other 8 are main's newer copies PR (#61), which the branch has not merged
  (`fill` / `[n of x]` of plain structs and of views, `write_view_copied`):
  - R15-p-v3
  - r3-s36-docs-p08
  - r3-s36-loans-o01
  - r3-s36-reads-v01
  - review-lang4-b1
  - sc5-t
  - syntax-review-designer-p11
  - `test/reject/ownership/write_view_copied.rig`

  None of them involves loops.
- Every `.rig` file main changed since 0a10f99c was also checked with the
  branch, and none hits the new diagnostic.

**The branch should merge main before landing.**

Is it minimal? The rule fires only when the step reads a binding and some part
of the condition holds a `continue` outside a closure. In that case SPEC
requires the `continue` to run the step, which would read an unbound binding.
The rule could over-reject in three ways, and none applies:
- a labeled `continue :outer` in a condition does not parse (L1);
- a loop nested inside a condition cannot be written inline (a call is fine:
  `a03` accepted);
- closures are excluded.

The grid's 56 + 66 + 26 rejections are all this rule, all on joined conditions
that base rejected too. Its one gap is M1 (a read through a capture).

## Question 2: labels written only when a jump was written

The `openLabeled` / `closeLabeled` buffer marks a label used when `jumpTo` writes
a jump to it, and writes the label when the buffer closes. I found no way to
write a jump after its target's buffer has closed, or to mark a label from text
that is then discarded:

- **Nesting.** Buffers nest LIFO. Every jump is written while its target's
  buffer is open: the condition parts, the body, and the step in either
  position all lie inside `openLabeled(lp.loop)`, inside `L_res`.
- **Jumps that would escape their construct.**
  - A jump out of a `defer` is rejected (`continue` is not inside a loop).
  - A jump out of a closure is rejected.
  - Loops inside `defer`, `errdefer` and closures, with labels that repeat an
    enclosing one, work (`d04`, sanitizer-clean, correct trace).
- **A `for` source.** It is written before `enterLoop`, so a jump in it targets
  the loop around it, whose buffer is still open (`e01`: range, a Vec in place,
  a consumed Vec, an array a call makes; correct).
- **Scratch writers.** All five in emit.zig (lines 1426, 2588, 2652, 2874,
  3293) are consumed, never dropped, so a mark is never left behind without its
  jump.
- **Label names.**
  - Rig labels named `__rig_loop_6` are escaped by `ident` (`@"__rig_loop_6'"`),
    so they cannot collide with generated labels.
  - Zig keywords (`error`, `test`, `const`, `type`) are rejected by the parser.
  - `comptime`, `rig`, `std`, `i64`, `u8`, `anyerror`, and a local's own name
    all work as labels.
- **Grid.** It wraps children in labeled `match` and `raw` blocks named `m`,
  `wN`, or the loops' own `a`, and uses `break :m` from inside a child's body
  and a child's `else`. 0 failures.

## Question 4: the oracle

Over the hand probes, the oracle reports one difference, c01 (M1). There the
oracle is right and the compiler is too lenient.

Over all 4300 generated programs, the oracle rejects none that the compiler
accepts. It abstains on joined conditions and on a labeled `break` value, so on
those shapes the grid's traces and the sanitizer are the evidence.

## Grid

`gen5.py` (a superset of `gen4.py`) writes 2 or 3 nested loops.

**Loop forms**, each one of:
- `while` with:
  - a Bool condition;
  - `as`, with the step reading the binding;
  - `as`, with the step not reading it;
  - joined, with the step reading the binding;
  - joined, with the step not reading it;
  - `catch break`, `catch continue`, `catch none`;
  - an owning `D?` binding, alone or joined;
- `for` over:
  - a range;
  - a Vec in place;
  - a consumed `Vec[D]` (its elements print when dropped);
  - a String.

**Variations on each level:**
- labels: distinct, all the same `:a`, mixed, or none;
- an `else`;
- the child wrapped in a labeled `match` or `raw`;
- a loop used as a value (`r = while ...`, with `break 77` and an `else`
  value);
- a step that grows a Vec which a body view, read in a `defer`, points into
  (the s02 class);
- the body's end holds a `defer`, an owned `D` local, both, or neither.

**Jumps:** 1 to 3 per program, each a `break`, `continue`, labeled one,
`break :wrapper` or `return`, placed:
- in a body, before or after the child;
- in a child's `else`;
- in a condition (`and (gate(..) ?? J) > 0`, or as the `catch` word);
- in a step (`c = adv(..) ?? J`, including `?? continue`, which ends the step).

**Run limits:** every pass counts against a guard of 300. Each program has 20 s
per check and 20 s per run.

The model is a direct interpreter (Python exceptions for jumps, `finally` for
defers and drops) following SPEC: the step runs after the body's
defers/drops; `continue` in the condition runs the step; `continue` in the step
ends it; `break` skips the `else`; a jump in an `else` targets the loop around
it.

Results, branch bd04787e, on pup:

| Run | Programs | Ran clean with the model's trace | Rejected (all the condition-`continue` rule) | Failed |
|---|---|---|---|---|
| `gen4-seed7.result` | 800 | 774 | 26 | 0 |
| `gen5-seed11.result` | 1500 | 1444 | 56 | 0 |
| `gen5-seed23-d3.result` (depth 3) | 2000 | 1934 | 66 | 0 |

Base 0a10f99c on gen5 seed 11 (in `gen5-seed11.result`, after `BASE`): 1066 ok
and 56 rejected. The other 378 failed, broken down in the Verdict above.

Coverage over the 3500 gen5 programs (programs containing each shape):

| Shape | Programs |
|---|---|
| a loop used as a value | 1709 |
| a step that grows a Vec | 1482 |
| a labeled `match` wrapper | 1463 |
| a labeled `raw` wrapper | 1417 |
| `return` from a body | 988 |
| `catch none` | 779 |
| `catch continue` | 681 |
| a labeled `continue` | 676 |
| a consumed Vec | 636 |
| `catch break` | 520 |
| a condition `?? return` | 337 |
| a labeled `break` | 320 |
| a condition `?? continue` | 277 |
| a condition `?? break` | 242 |
| a step `?? continue` | 215 |
| a step `?? break` | 170 |
| `break :wrapper` | 96 |

Commands (the scripts travel to pup base64-encoded, since only committed work
travels):

```
G=$(base64 < gen5.py | tr -d '\n'); R=$(base64 < run4.sh | tr -d '\n')
pup.sh loop-lowering "W=\$(mktemp -d /tmp/rll.XXXX); echo $G | base64 -d > \$W/gen5.py; \
  echo $R | base64 -d > \$W/run4.sh; zig build oracle; python3 \$W/gen5.py -n 1500 --seed 11 \$W/g; \
  O=\$PWD/bin/rig-oracle bash \$W/run4.sh \$W/g \$PWD/bin/rig"
```

## Hand probes (all in `probes.out`)

| Probe | What | Result |
|---|---|---|
| a01 | labeled `continue` in a header | parser rejects (L1) |
| a02, a03 | condition `?? break` with a step reading the binding; a `continue` in a loop inside a called function | accepted, correct |
| a04 | step reads a `*B` binding | rejected by `checkStepUses` on base, main and branch alike |
| b01 | value loops: `break v` from the body, a labeled value loop left from an inner `for`, `else` values | correct, clean |
| b01-…-in-step | `break v` in a step or condition | rejected on main and branch (control) |
| b02 | `return` from a step and a condition, with owned locals | correct, clean |
| b03 | `!` / `?` from a step, a condition (owning binding) and a body, with `defer` and `errdefer` | correct, clean |
| b04 | a step that moves an owned value and one that re-points a view, both read by a body `defer`, with `continue` from the body, an inner `else` and `continue :outer` | correct, clean |
| c01, c02 | a step reading a binding through a closure capture | M1 |
| d01–d03 | constant conditions; `while true` with an `else` and a value | correct |
| d04 | loops in `defer` / `errdefer` / a closure, with repeated labels | correct, clean |
| e01 | jumps in `for` sources | correct, clean |
| e02 | value loops handing out a consumed element, an array element, an owning binding | correct, clean |

Rig has no Map type in std, so `for` over a map was not tested.

One observation, not a finding: on `break`, a consumed Vec drops the elements
left behind in reverse index order (e02 prints `drop 3`, then `drop 2`). SPEC
does not specify the order.
