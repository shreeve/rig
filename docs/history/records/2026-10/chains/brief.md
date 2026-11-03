# Chain panel brief (2026-11-03): how a fused chain becomes a loop

## The task
Rig is an indentation-sensitive systems language that compiles to Zig. The owner's first priority is
speed (the race is against Rust; a feature must cost nothing at run time: inline, no allocation, no
boxed closures), then clean, consistent syntax that is ideal for AIs to write. Approved and about to
be built: **fused iterator chains**, `docs/design/iterators.md` in the worktree
`~/Data/Code/worktrees/rig/chains` (read it first). A chain such as

```
oldest = ?@entries.items()
  .filter(|e| e.value.state matches .ready)
  .min_by(|e| e.value.touched) ?? break
```

is not a value: it is rewritten into the `for` loop it means **before** the ownership checker,
storage planner, proof pass, and emit run, so they check and emit exactly that loop (North Star 4:
"the checker checks exactly what is emitted"). Stages: `map filter take skip enumerate zip`.
Consumers: `sum count reduce collect any all find min max`, plus `min_by(key)` and `max_by(key)`
(first item on ties). The `trim` example in `../brief.md` must compile and run as fast as its hand
loop (there in `../brief.md`, "Rig today").

## How rewrites work today
- `src/modules.zig` (~line 853): sema checks the module, records facts (`iter_loops`,
  `byte_literals`), the Parser wrapper rewrites the tree (`Parser.desugarIterLoops` in
  `src/rig.zig`, ~line 4924; `iterWhile` turns `for x in it` into `while (!h).next() as x`, with a
  hidden binding `h`), and sema checks the module again, in rounds, until nothing is left to rewrite.
  Sema's TypeIds do not survive between rounds (the type store is rebuilt).
- The wrapper builds nodes with `self.base.newNode(kind, children, span)`. Every leaf is a source
  span; a name no source text holds is a "hidden leaf" (`HiddenName` in `src/rig.zig`, a fixed enum
  of static texts such as "for iterator", unwritable by a program because of the space). Leaves are
  keyed by position, so each hidden leaf needs a position no other leaf holds. One IR node may not
  appear twice in the tree (facts are keyed by node, and emit's debug self-check rejects writing a
  unit twice).
- A loop is a value (SPEC "Loops as values"): `while true` ... `break v`, or a `for` with `break v`
  and an `else` value. `new x = e` declares a binding that may shadow. Closures may be bound to
  locals (`f = |x| x + 1`) and are inlined by Zig.

## The problem
`sum`, `min`, `max`, `min_by`, `max_by`, and `collect` need state declared **before** the loop
(the running sum, the best item, the List), and its type is the item type at the end of the stages
(after `map`, the type a closure returns), or a key type. Rig cannot write that type at rewrite
time: `best = none` is rejected ("cannot infer the type of `none`"), there is no `$type(x)` type
annotation, a hidden leaf cannot hold arbitrary text, and round-1 TypeIds are gone in round 2.
`count`, `any`, `all`, `reduce(start, f)` (`acc = start`), and `find` (a `for` value: `break item`,
`else none`) need no declared type.

## The options so far
1. **Peel the first item (the session's default).** Find the first item that passes the stages and
   start the state from it, so its type is inferred: `new best = item`. A second loop continues the
   same iterator (`for item2 in !h`, holding the source in a hidden `h`) or the rest of a list
   (`s[i + 1..]`). Only existing features, so every checker and emit understand it unchanged. Cost:
   each stage's call is written twice (each closure bound once to a hidden name), and an empty
   `sum()` / `collect()` needs a typed `0` / empty List from the else branch.
2. **An internal type node** the rewrite alone writes, e.g. `(type_of e)` or `(item_type src)`, which
   sema resolves and emit writes from the resolved type. One loop, but a new kind of type that sema
   and emit must handle, and its expression must be in scope before the loop.
Others are welcome: a native `chain` IR node checked and emitted as a loop; sema typing the chain in
round 1 and passing type *text* to the rewrite (synthetic text appended to the module's source);
std generic helpers; anything else that keeps chains free at run time.

## Your answer: ≤400 words to report, the full version in your file (`zig.md`, `rust.md`, `swift.md` here)
1. Which lowering you would build, and why, judged by: run-time cost and the Zig LLVM sees; how
   little it adds to the compiler that every later change carries; soundness (the ownership checker
   must see what runs); error messages in the user's terms.
2. For `min_by` over a Map's items (`trim`), the exact Rig (or IR) your lowering produces, and the
   Zig you expect emit to write, against the hand loop in `../brief.md`.
3. The traps: iterator sources vs lists vs ranges; `take`/`find` must not pull an item past what
   they need; closures with captures (`|?n, x|`, `|<r|`); `collect` of views; failing closures.
4. Anything the approved design gets wrong that should go back to the owner.

Read the code to ground your answer (`src/rig.zig`, `src/modules.zig`, `src/sema.zig`,
`src/typecheck.zig`, `src/emit.zig`; `bin/rig` in the `matches` worktree builds and runs Rig, e.g.
`~/Data/Code/worktrees/rig/matches/bin/rig run f.rig`, `bin/rig emit f.rig`). Do not edit the
worktrees or `~/Data/Code/rig`; write scratch programs in your own temp directory.
