## Summary

Builds the decided rule: **`!` lends any value to write, named or temporary.**

- **Accepted now:**
  - `!mk().bump()`, `!mk().pop()`, `x = !mk().take()`, `!mk().items.push(1)`;
  - `grow(!mk())`, `!mk()[..]`, `(!mk()).r = v`;
  - `swap`, `replace` and write slices of parts of a branching temporary.
- **Where the temporary lives:** in its statement's slot until the statement ends, as a read-lent temporary does.
- **Still rejected:** a write method on a temporary with no `!`, with the hint "add `!`: `!mk().bump()`". The hint is reworded when a `!` is present but doesn't reach the receiver: `!o?.pop()`, a `for` source, or a call through a module or type. In that last case a `Bool` call is pointed to `not`.

It relies on v0.2.2's classifiers instead of repeating them:
- `isConstant` keeps constants from being lent to write.
- `storeThroughLend` records a store into a write-lent temporary through its write loan.
- `viewOnPath` stops a part from being moved out through any view.

## Changes

- **Parser wrapper:** `!` reaches the receiver of the chain's first method call, including a value no name holds. `!mk().pop()` is `(!mk()).pop()`, and a literal or a parenthesized expression works the same way. `!a.b(x)(y).g()` keeps its v0.2.1 parse. `?` and `<` are unchanged.
- **Typecheck:**
  - `lendsToWrite` keeps a temporary in its slot and records the fact `writesTemp`.
  - A branching value that may be a name's is lent per branch.
  - `!` before a call through a module or type gets one clear diagnostic.
  - `as` over a header temporary's write view advises binding it first.
- **Ownership:**
  - The slot is lent to write (`lendTempToWrite`).
  - A holder temporary uses its views when dropped only through a `drop` body (`holdsPastDrop`), as a named holder does.
  - A view held by an earlier temporary of the same statement gets an accurate diagnostic.
- **Emit:**
  - A write-lent temporary is reached in its slot at every site that lends it, never through a copy. Emit reads `writesTemp`, so `swap`, `replace`, write slices and hoisted receivers need no special case.
  - An assignment's value temporaries are dropped after its target's. That matches the order they are made and the checker's order.
- **Oracle:** models write lends of temporaries, paths through `!e` and `?e`, and write receivers whose value is a write view. Its coverage floors are raised.
- **Tests:**
  - behavior tests under the sanitizer with a stack clobber;
  - reject tests for what stays rejected;
  - three matrix contexts;
  - every reviewer probe from the three review rounds (`test/corpus/review-seam2-*`, `review-seam2b-fixes-*`), with oracle verdicts.

## Core conformance

- **Sentence 4:** built as stated, with its sentence and example in CORE.
- **Sentence 9:** every change is still marked by `!`.
- **§3 and sentence 3:** a write-lent temporary is dropped where its statement ends, on every path out, last made first. A view of it is usable only within the statement.
- **Sentence 6:** a stored view keeps its loans live while the holder holds it. Dropping a holder uses its views only through a `drop` body, for temporaries as for names.
- **Sentence 2:** nothing is moved out through the lend.
- **Sentences 7 and 8:** constants are never lent to write, and writing through a shared handle stays rejected.
- **§10:** specified as a desugaring, with no exception list.
- **The checker checks exactly what is emitted:**
  - the slot is the `temp` storage fact;
  - being written is the `writesTemp` fact;
  - the drop order is the same in the checker and in emit.

## Review

- **Rounds 1 and 2:** found holes that turned out to be pre-existing classes. Those were fixed on `main` and released in v0.2.2, and seam 2 was redesigned on top of that.
- **Fresh review of the redesign:** no soundness hole. It found one Medium, accepted programs whose Zig did not compile through `swap`, `replace`, write slices and hoisted receivers, plus some Lows. All are fixed.
- **Targeted re-review of the fixes:** no soundness hole, with about 2,500 generated programs and over 50 handwritten probes. Its four Lows are fixed.
- **Deferred to `open-items`:** three over-strict rejections that predate this branch, and two oracle gaps where the compiler rejects correctly.

## Verification

Gates on pup at `1877b9cb`:

| Check | Result |
|---|---|
| Suite | 2,691 passed, 7 pending |
| Corpus | 6,349 of 6,349 |
| Matrix | 3,637 programs, 0 failed |
| Unit tests (`zig build test`) | 124 of 126 passed, 2 skipped |
| `oracle doc vocab` | 325 passed |

- **Mac:** the suite and `oracle doc vocab` also passed there.
- **Equivalence against v0.2.2** (8,649 programs): no program goes from accepted to rejected. 170 go from rejected to accepted (the new tests and probes). 142 are rejected either way with new wording or new probes, and 5 doc examples differ.

## Behavior changes

Only acceptances: programs that v0.2.2 rejected now run.

## Nexus mirror

`src/rig.zig` changed: `!` now reaches a made or parenthesized receiver. It needs a re-sync to the Nexus mirror.
