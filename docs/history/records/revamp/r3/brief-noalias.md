# Queued round: `noalias` for write views (owner-approved 2026-10-15, after `rig build --cpu`)

## Why
A write view `!x` is exclusive: while it's live, the ownership checker proves nothing else reads or writes `x`. Zig can't see that, so a function taking `!List` as `*List` reloads the List's length after every store and keeps state on the stack (RIG-NOTES 8). Marking the pointer `noalias` hands Zig the fact the checker proved. json.rig's honest harness measured keeping the parser's state in registers as worth up to 7% on the Mac and 12% on citm. That's an upper bound for all ways of doing it; noalias alone may get less. A hand-made local tape won on the Mac and lost on x86.

## Soundness (the whole point; a wrong noalias is silent miscompilation the sanitizer can't catch)
- One fact, decided once, in ownership/facts: "this parameter's write view is exclusive for the call". Emit reads it and imports no classifier. Specify it as a desugaring in docs/INTERNALS.md. A CORE change, if any, goes to the expert team first.
- Never inside or reachable from `raw`. Probe each shape with its own test:
  - write views reached through shared handles `*T` and `Cell`;
  - closures capturing `!x`;
  - split write slices (`![]T` halves);
  - two parameters that are fields of one object;
  - `!self` with another parameter derived from self;
  - generic instances;
  - iterator `next`;
  - `defer`;
  - inlined calls (inline2), where noalias must not survive into a caller where it no longer holds.
- Read views: decide separately. Interior mutability (`Cell`, shared handles) may forbid `noalias` on `*const T`. Start with write views only.
- An adversarial review hunting any call where two pointers to the same memory reach a noalias parameter. "A second soundness round stops the feature."

## Speed
Lands only if it passes the speed rule (more than 2% faster somewhere, no more than 2% slower anywhere) on BOTH the Mac and pup: JSON guard and benchmark (exclusive windows), bench/hash, Trig's binder A/B. RIG-NOTES 8's push loop is the first target.

## Gates
Full matrix, corpus, equivalence with every emit diff categorized (only `noalias` added on write-view pointer parameters), unit tests, the timing windows, and the review.
