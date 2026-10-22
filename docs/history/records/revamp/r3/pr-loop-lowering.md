# Lower every loop through one desugaring the checker walks

Two review rounds on `while` steps (review-while-step.md,
review-while-step-2.md) kept finding the same class: **emit ran a
loop's step, the body's defers and drops, the `else`, and the targets of
`continue` on different paths from the ones the ownership checker
walks.** The lowering chose its shape from analyses (`jumpsToLoop`,
`keptLabel`, `labelUsed`, a redirect stack popped after the `else`), and
each analysis could disagree with the checker. Per AGENTS ("a second
soundness round stops the feature"), this replaces the lowering with one
desugaring, emitted the same way for every loop form, which the checker
already walks.

## The desugaring (docs/INTERNALS.md, "Loops")

For `:L while a as x and c: step` with an `else`:

```text
L_res: {                         // the loop's block: what its header holds, its `else`, its value
    L: while (true) : (step) {   // the step here when it reads no binding of the condition
        x = a or break           // one `if` per part of the condition, each `else break`
        c or break
        L_body: { body }         // the body's own scope; `continue` is `break :L_body`
        step                     // here when it reads a binding (`sema.stepReadsBinding`)
    }
    else                         // after the loop, outside its jump target
}
```

A `for` uses the same skeleton: Zig's `for`, or a `while` over a
consuming iterator or a range (its counter is the continue expression),
with the element bound in the body's block. Its source is evaluated
before the loop's jump target is entered, so a jump there targets the
loop around it, as the checker walks it.

The checker's walk matches it step by step (the table in INTERNALS):
condition, binding, body, body-end drops and defers, step, back edge,
`continue` from each part, `break`/`break x`, and `else`.

- **Jumps** resolve by lexical scope through one stack of `JumpTarget`s
  (loops and labeled `match`/`raw` blocks), as `walkJump` does. Each
  target says where a `continue` goes from the part being emitted:
  `continue :L` from the condition, `break :L_body` from the body,
  `break :L_step` from the step. A loop's target is popped before its
  `else`. Every Rig jump is written with an explicit Zig label, so none
  relies on Zig's innermost-loop rule. A Rig label that repeats an
  enclosing one becomes a generated `__rig_label_N`.
- **Labels without analysis.** Zig rejects an unused label. Each labeled
  construct is written into a buffer (`openLabeled`) and gets its label
  when it closes (`closeLabeled`), only if the resolver wrote a jump to
  it. The blocks are always there; an unused one is a plain `{ }`.
- **A `break` skips the `else`** by leaving `L_res`; a failing condition
  part leaves the Zig loop and falls into the `else`. The
  `__rig_ended_N` flag is gone.

## Removed

`emitWhileJoined`, `jumpsToLoop`, `keptLabel`, `labelUsed`,
`stepLabel`, `rigLabelOf`, `zigLabel`, `writeJumpLabel`, `emitElse`,
`valueLoop`, the `JumpRedirect`/`redirects` stack, `labels`,
`value_loops`, `value_else`, and the `__rig_ended_N` flag. The native
`while (c) |x| : (step)` special case is gone too; every `while` is the
one skeleton. src/emit.zig: +289 −348.

## One rule made consistent with SPEC

SPEC says a `continue` in a `while` condition "runs the step and tests
again". When the step read a binding of the condition, the checker sent
that `continue` to the head instead (the binding was unbound), and emit
followed, so `while some(odd(i) ?? continue) as h: steps += h` silently
skipped the step. The type checker already rejected this for joined
conditions; it now rejects it for every condition (`checkStepBindings`),
as SPEC's "Joined bindings" rule says, and SPEC's `while` section says
so. A `continue` in the condition therefore always goes through the
step. New test: `test/reject/effects/while_step_binding_condition_continue.rig`.

## A step reads a binding through a closure's capture too

Whether a step reads a binding of the condition is decided once, by
`sema.findUse`, which `sema.stepReadsBinding` (emit and the ownership
checker) and the type checker's step rules (`checkStepUses`,
`checkStepBindings`) all use: a name reads the binding when it is the
binding or a closure's capture of it (a capture symbol's `origin` leads
back to it). Before, all three compared symbol ids, and inside a closure
`h` is the capture's own symbol (review-loop-lowering M1):

- `while some(i) as h: s = apply(|+h, x: Int| x + h, s)` was taken for a
  step that reads no binding. On main it worked only through Zig's
  native `while (c) |h| : (step)`; with a jump in the condition (and on
  this branch before the fix, for every condition) the step landed
  outside the binding's scope and emit failed with an internal error.
  It now runs in the binding's scope:
  `test/behavior/emit/loop_step_reads_binding_through_capture.rig`.
- With `?? continue` in the condition, the same step escaped the rule
  above, and the oracle reported a use after move. It is rejected now:
  `test/reject/effects/while_step_capture_condition_continue.rig`.

The rule's other diagnostic now says "a binding of the condition"
rather than "of a joined condition", since it covers a single `as` too
(L2). A labeled jump in a condition cannot be written today (L1, a
grammar gap recorded in open-items.md); if it ever can, the rule's
`hasContinue` must count only a `continue` that targets this loop.

## Tests

- Every s*, e*, and l* probe of review-while-step-2 is a test (written
  first; 16 failed before the change):
  `test/behavior/emit/loop_step_after_body_*` (s01, s01b, s01c, s02,
  s03), `loop_else_*` (e01 while/for, e02, e03, e04, e05, e06, e08),
  `loop_label_shadow_*` (l01–l04), `loop_step_order_nested_match_value`
  (gen2 matchvalue.joined.catchbreak, against the plain reference
  trace), and `test/reject/syntax/loop_else_continue_own_label.rig` (e07).
- All the hand-written probes (but the parser-rejected c01) and the
  gen2 matchvalue cells are in `test/corpus/review-while-step-2-*`, with
  the oracle's verdicts (it abstains on joined conditions).
- `test/matrix.py` has a `loop.` context: outer {while, while-as,
  joined, catch-break, for} × inner {while, for, while-as, match, if} ×
  jump {continue, continue :outer, break :outer, continue in the inner
  construct's else} × body end {defer, owned local with a `drop`}: 200
  programs, each of which must print the trace `loop_trace` computes
  from the jumps' meaning. Every generated loop counts its passes and
  stops at a cap no `continue` skips, and each matrix program is now
  stopped past its time (`--timeout`), past 1 MB of output, or when its
  processes hold more than `--mem` (a watchdog: the sanitizer reserves
  64 GiB of address space, so an address-space limit stops it). `--rig`
  tests another compiler.

- `test/behavior/emit/loop_else_continue_runs_step.rig`: the shape that
  never ends on main (an outer loop whose only progress is its step,
  with `continue` in an inner loop's `else`), bounded by a guard.
- The independent review's hand probes (all but a01, which only the
  parser rejects) and 44 programs of its random nested-loop grid (36 of
  gen5 seed 11, most of them ones base 0a10f99c ran wrong, and 8 of
  seed 23 at depth 3) are in `test/corpus/review-loop-lowering-*`, with
  the oracle's verdicts (c01: `main reject C1`). Every grid program
  carries its iteration guard.
- The matrix watchdog is adapted to #63's runner: it keeps its
  started-file evidence, build store, and `--shard`, and runs each
  program under the watchdog.

## Gates

pup, head 04302a97 (main e7b15af7 merged; `pup-gates.sh`, -j 12):

| Gate | Result |
|---|---|
| suite | 2771 passed, 0 failed, 4 pending |
| corpus | 6830 passed, 0 failed |
| matrix (with the 200 `loop.` cells) | 5099 programs: 2370 ran clean, 2729 rejected, 0 failed |
| `zig build test` (fresh cache) | 124/126 passed, 2 skipped |
| oracle doc vocab | 329 passed, 0 failed, 4 pending |

Mac (heavy.sh): `./test/run loop while for_ label step oracle doc/INTERNALS
doc/SPEC doc/test-README unit classify vocab parser`: 1561 passed, 0 failed.

Loop grids, on pup only, each program capped at 20 s, 2 GB held, and
1 MB of output:

| Grid | This branch | Base |
|---|---|---|
| matrix `loop.` (200) | 200 ran clean with the expected trace | main 0a10f99c: 44 failed: 32 run the step before the body's `defer`/drop (s-class), 12 never end (`continue` in an inner `else` skips the step, e-class) |
| review-while-step `gen/` (70), review-while-step-2 `gen2/` (125) and `gen3/` (70), at 5f02f3d7 | 265 programs: every `grow` cell rejected, every `read` cell prints `4004 4`, every other cell prints its plain reference's trace, all sanitizer-clean, and the oracle rejects nothing the compiler accepts | (the reviews' results: C1, C2, H1) |
| review-loop-lowering gen5, seed 11 (1500) and seed 23 depth 3 (2000), at 04302a97 | 3378 print the model's trace sanitizer-clean, 122 rejected (all the condition-`continue` rule), 0 failed, 0 oracle disagreements | base 0a10f99c on seed 11: 378 failed (the review) |

## Equivalence

`test/equiv.py` against main e7b15af7 over 9172 programs (every tracked
program and doc block; `pkg` hashes each whole emitted package): 975
differ.

- **Accepted → rejected: three programs**, all the condition-`continue`
  rule: its two reject tests and the review's probe c01
  (`test/corpus/review-loop-lowering-c01-*`). No other corpus,
  behavior, example, or doc program changes its verdict.
- **Diagnostic wording: two** (`joined_while_step_bindings.rig`, corpus
  w40): "a binding of a joined condition" becomes "a binding of the
  condition".
- **Emit failed → emits: one**, the review's probe c02 (M1).
- **Emit only, the rest** (781 programs with `emit` and `pkg`, 188 with
  `pkg` alone: their imported modules', std's included, loops). With
  generated ids normalized, every changed line is one of:
  - renumbering only (342 programs): the loops' labels take ids;
  - loop headers (365): `while (c) : (s)` and `while (x) |h|` become
    `while (true)` with the step as its continue expression or after
    the body; a Zig loop gets a label where a jump names it;
  - condition parts (343): `if (!(c)) break;` and
    `if (x) |h| { ... } else break;` inside the loop;
  - blocks and labels (395): the body's block (`__rig_body_N:` when a
    `continue` leaves it), the loop's result block (`__rig_loop_N:`), a
    labeled `match` or `raw` always in a block;
  - jumps (172): `break;` / `continue;` become labeled
    (`break :__rig_while_N`, `break :__rig_body_N`, `break :__rig_loop_N`
    to skip an `else`);
  - `else` (44): the loop's `else` follows the loop in its block instead
    of Zig's `while … else`;
  - step placement (43): a step that reads a binding moves after the
    body's block;
  - other (28): the removed `__rig_ended_N` flag, statements that moved
    into the body's block, and c02's emit, which used to fail.

## Performance

`--release` binaries of every example and of a loop-heavy benchmark
(nested `while … as … and`, `continue :outer`, `for` with `continue`)
are byte-for-byte the same size as main's, and the benchmark runs in the
same time (5 runs: 0.080 s vs main's 0.079 s, same output).
