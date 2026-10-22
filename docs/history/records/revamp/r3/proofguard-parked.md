# proofguard: parked (2026-10-12)

Parked by the coordinator before any code was written: once `peek` is
inlined, LLVM already removes the check (identical instructions per byte
on all six JSON files; canada's 5% was profiler attribution). No branch
was pushed: `proofguard` had no commits beyond origin/main d9e738783.

## Done

Read design-proofs-v2.md, design-proven-checks.md §round 2 ("false
edges, noreturn branches"), pr-proofs2.md, src/proofs.zig, and rig.zig's
`leavesBody` / `isJump` / `skeletonOf`.

## Plan, as far as it got

- Rule: after `return|break|continue … if C`, or `if C` (no `else`)
  whose `then` always leaves, the rest of the block is walked as if
  wrapped in `if not C`. INTERNALS "Proven checks" gets that desugaring.
- One classifier: turn `genGuard(e, out)` into `genCond(e, truth, out)`:
  a comparison flips its operator when `truth` is false; `not x` recurses
  with `!truth`; `a or b` under false and `a and b` under true recurse on
  both. Applied on the unit's exit only, through `addMade` with `K(g)`, as
  the true edge is. A condition with more than one guard part (top `and`
  chain) or an `as` part gives no false-edge facts (or the meet of each
  part's false exit; not needed for `peek`).
- "Always leaves": one positive list, `rig.leavesBody` / `isJump` on the
  last statement of the `then` block (and `panic`, if sema's `noreturn`
  type can be read as a recorded fact rather than re-derived).

## Design questions hit

1. Do not use the walk's own `State.dead` as "always leaves": a
   `break :blk` to a labeled block inside the `then` sets `dead` at the
   `then`'s end, yet control falls through to after the `if`. Check
   whether `dead` already misleads `walkWhile`'s step meet in that shape
   (it keeps the break point's facts, which looks sound, but confirm).
   A `break`/`continue` counts only when its `JumpDest` target encloses
   the `if`.
2. `genCond` with `not` also makes `if not (i >= s.len)`'s true edge
   prove `s[i]`: the "G1: a near miss proves nothing" unit test asserts
   it does not, so that case moves to a new test.
3. `rig.leavesBody` lists `return` and failing `!`/`?`; pr-proofs2 notes
   "a propagate statement does not end a block's path". A `then` whose
   last statement is `x!` does not always leave; only `return`, a jump
   out of the enclosing construct, or a call typed `noreturn` should.
4. `defer` in the `then` block runs before leaving and is harmless to
   the rest of the block (it is not reached); a `defer` in the enclosing
   block is unaffected.

## Left

Everything: code, the adversarial tests listed in the brief (guard that
sometimes falls through, writes of `i`/`s` after the guard, defers,
nested-loop `break`, `continue` in a `while` step, `and`/`or`, `?`/`!`
in C), the `unit.`/`proof.` grid guard-shape axis, docs, gates, and the
`peek` asm and `bench/json/guard.py` measurement.
