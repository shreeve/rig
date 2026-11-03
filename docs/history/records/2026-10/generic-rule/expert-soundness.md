# Expert: soundness and the Core

Probes: `soundness-probes/p*.rig`, run with `closure-view-fix` bin/rig, `RIG_SANITIZE=1`.

## Verdict
The hole is wider than stated. A generic body takes any `T` it holds by value (a field, an element, a local) to hold no view. So whatever a function value puts in one goes unseen, through a write-view argument or through its result.

Accepted, then use of freed memory:
- Map: `update` (p1), `retain` (p2), and `ensure_with(String("a"), |k| k)` through its result (p3b; `keeps make` lets it compile).
- A program's own generics:
  - `f(?@ks[0], !@vs[0])` (p7); its concrete twin is rejected: "a value never holds a view of itself".
  - `f(?a, !b); b` on locals (p16); its concrete twin is rejected: "cannot return a view of `a`".
  - `push(f(?@ks[0]))` with `keeps f` (p18b).
- Any callable: `*sub` (p9), a named function with `keeps` (p11), forwarding through a generic (p10).

Caught today: captures (p4, p5), lent parameters (p6, p13), a method's `keeps` (p17).

## Rule: R1, worded for the class
In SPEC "Generic bodies", replace "A `T` the body holds by value carries no loans it tracks, so…refused" with:

> A `T` the body holds by value carries no loans it tracks, so the body needs a `T` that holds no view wherever it could put a view in one. That happens where a method of the instance keeps an argument's view in it, where a function value is given a write view of it beside a view, or where it holds as one a function value's result from a call given a view. An instance whose `T` can hold a view is refused at the call or type that makes it, with a note at the body line.

It is a per-instance requirement, as a copy of a `T` is; the built-in table's `update`, `retain`, and insert carry it too.

Cost: harmless refusals (`update(|k, v| v = none)` at a viewing `V`); use an owned `V` or loop over `items`. Trig makes no such calls; std is unchecked.

## What R2 misses
- **The result path.** `|k| k` is a correct callback.
- **`*fun`.** CORE §7 lets an owned closure keep views, so R2 means a CORE change.
- **A second classifier.** It duplicates the caller-side rule of probe 1.

R1 as problem.md words it misses the result path and a body's own locals.

## CORE
No change. CORE leaves per-instance checks to SPEC, and sentence 7 already says "nothing narrows its result or its stores".

A side bug: p18 blames a view "of `f`" and accepts `keeps f`. Drop `keeps make` once this lands.
