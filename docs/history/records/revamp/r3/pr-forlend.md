A `for` over an iterator a method returns can now be written in one line:

```rig
for e in ?ages.items()
  print(e.key, e.value)
```

`?ages.items()` is `(?ages).items()` by the receiver-sigil rule, as it is before any call, and the loop holds the iterator it makes, which keeps `ages` lent to read for the loop. Until now this was rejected with a hint to bind the iterator first (`it = ?ages.items()`, then `for e in !it`). It is the form `std.hash`'s Map needs (proposal-traits-map B2).

## A soundness fix found on the way

On `main`, a `for` over an iterator the loop holds (a value made there, `for x in mk(?v)`, or a place it takes, `for x in <it`) dropped the loans that iterator holds inside the loop body. This was accepted, and under the sanitizer it is a use of freed memory:

```rig
for x in Cur(xs: ?v[0..2], i: 0)
  for _ in 0..100
    !v.push(x)        # reallocates what the next `next` reads
```

The class: the hidden binding that holds the iterator was declared at a position inside the `for` keyword, so `ownership.Checker.liveFrom` read the loop as enclosing the declaration, and the binding's last use (the loop's condition, before the body) as behind every statement of the body. Its loans ended at the body's first statement. The binding is now declared at the position before the `for`, as the desugaring `{ h = e; while (!h).next() as x }` says. Siblings checked: the made, moved, labeled, and (new) lent sources all go through the one hold, and the only other hidden names (`next`, the discard `_`) bind nothing that holds a loan.

### Its sibling: a deferred body

The independent review found the same class one step over: `checkDeferBody` sets `loop` to null, so liveness inside a deferred body saw no enclosing loop, and a holder whose last use is the loop's header counted as dead. Accepted on `main`, a use of freed memory in debug:

```rig
s = ?v[0..2]
i = 0
while s[i] > 0 : i += 1
  defer grow(!v)        # grow pushes 100 times
  print(i)
```

Likewise with `for x in smk(?v)`, `for x in ?b.each()`, and `while (!c).next() as x`. A deferred body still sees no loop for `break` and `continue`, but the loops around it stay in force for liveness (`Checker.defer_loops`, read by `liveFrom`). Closures, the other place `loop` is cleared, are checked as functions of their own, and their state is rewound.

## Changes

- `src/rig.zig`: the hold is declared before the loop; `Parser.loopReceiverSource` records, for a `for` whose `?` the receiver-sigil rule puts on a place's method call, that source with the `?` moved, and the desugaring holds it (`IterSource.lent`).
- `src/ownership.zig`: `defer_loops`, the loops around each deferred body being walked, which `liveFrom` counts.
- `src/typecheck.zig`: `iterLoop` classifies `?` before such a made iterator as `.lent`; the hints for `b.each()` and `!b.each()` name `for ... in ?b.each()`, the form that now compiles, and `!b.drain()` of a method that writes its receiver is reported once, at the call, which names `(!b).drain()`.
- SPEC §6 (the source table, and an example), docs/INTERNALS.md (the desugaring table).

## Tests

- `test/behavior/syntax/for_lent_made_iterator.rig`: the form, nested, through a field path, with `break`, and a write after the loop.
- `test/reject/ownership/for_held_iterator_keeps_lent.rig`: a write in the body of a loop over a made, taken, lent, and labeled iterator is rejected (the first commit, without the lent case, fails on `main`).
- `test/reject/ownership/for_lent_iterator_write.rig`: writing or moving the lent place in the body.
- `test/reject/ownership/for_iterator_made_view.rig`: the hints.
- `test/reject/ownership/defer_in_loop_keeps_lent.rig`: a deferred write in a loop over a slice the condition reads, a `while … as` iterator, and a held and a lent `for` iterator.
- `test/corpus/rev206-*.rig`: eight of the reviewer's probes.
- `test/matrix.py`: `dloop.<source>.<write>`, 24 cells: eight loop sources (a `while` condition reading a slice, `while … as`, and a `for` over a made, lent, named, or taken iterator, a List, or a slice) × a deferred write to what the source views (rejected), a deferred write elsewhere, or a write after the loop (run in debug and `--release`).

## Gates

- Full gates on pup (`pup-gates.sh`, `--delta`, -j 6) at 9db79a8f6, with main 11c79bc07 (#203) merged in: corpus 10069/0; matrix 11381 programs, 0 failed; unit 172/175 (3 skipped). The suite and oracle, doc, vocab at the final 0acd17a9e (which adds only the oracle's four `dloop.*.defer` rejections to `test/oracle/rejections`): suite 3705 passed, 0 failed; oracle, doc, vocab 450/0.
- In the earlier full run, three `cli/` timing tests failed under load and passed rerun alone.
- Emit equivalence against main over 13,136 programs and doc blocks (before the deferred-body fix, which changes no emit): the one difference is `test/reject/ownership/for_iterator_made_view.rig`'s hints. No accepted program's Zig changed.
- The new tests, the 24 `dloop.` cells (8 rejected, 16 run clean in debug and `--release`), and the reviewer's eight probes.
