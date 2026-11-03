# Would a rewrite of Rig pay? (2026-10-31)

A read-only review of Rig main at 144f70057. Three reviewers each read one area, about 15% of
its lines closely, and sampled the rest. Their full reports, with file:line evidence, are beside
this file:

- `review-frontend.md`: the grammar, `rig.zig`, `sema.zig`, `resolve.zig`, `modules.zig`
- `review-types.md`: `typecheck.zig`, `cteval.zig`, `inlining.zig`, `proofs.zig`
- `review-ownership-emit.md`: `ownership.zig`, `storage.zig`, `facts.zig`, `emit.zig`

The runtime (`sched`, `tasks`, `net`, `alloc`, `runtime.zig`) and std were not reviewed.

## Estimates

| Area | Load-bearing | Cruft | Confidence |
|---|---|---|---|
| Front end, about 30k lines | about 70% | about 30% | medium |
| Types, about 29k lines | 60–65% rules, plus 10% sound but misplaced | 25–30% | medium |
| Ownership and emit, about 24k lines | 60–65% | 35–40% | moderate |

Across the checker and emit, about a third is cruft. The types reviewer expects a rewrite to come
out 30–40% smaller.

## The same five findings, from all three reviewers independently

1. **There is no lowered IR.**
   - The tree is rewritten in place, and the whole module is checked again until nothing changes
     (`modules.zig:819-830`).
   - Typecheck changes the tree while it checks it.
   - The storage planner, the ownership checker, emit and the proofs each model evaluation on
     their own. They agree only through checks that run while emit runs.
   - Emit still decides some things itself: whether a binding is used, built-ins recognized by
     name, lowerings picked by method name, whether a binding is a pointer or a copy.
   - The oracle's `test/oracle/lower.zig` (4,652 lines) already lowers each body once, with
     evaluation order written out. It shows the target design works.
2. **Facts are keyed by source position, node id, or pointer address.** Hidden leaves get made-up
   positions. Each module has its own type store, with stand-ins for other modules' types, and
   built-ins are registered again in every module.
3. **Context lives in mutable state.**
   - `SemContext` has about 144 fields, and typecheck's `Checker` 84.
   - Emit has about 20 mode flags, which are saved and restored by hand.
   - Trial checking (`synthQuiet`) keeps its side effects, so decisions are recorded on first ask
     and checked again later (`verifyDecisions`).
4. **Library knowledge is wired into the compiler.** About 1,400 lines of typecheck type std calls
   by hand (`par`, `isolate`, `select`, `http.serve`, actors). Emit picks lowerings by method name.
   There are four constant evaluators.
5. **The vocabulary drifts.** "receiver" appears in about 580 places, against the "self" rule, and
   the IR's node names are `struct` and `lambda`.

## Carry over unchanged

- the rules and every test, the doc examples, and the oracle;
- the `handsOver` classifier and the lend table;
- the ownership checker's state model: loans on field paths, undo-trail snapshots, the loop
  fixpoint, origin checks;
- naming every hidden storage location through one function, and `need`/`unsupported` (a missing
  decision is an internal error, never a guess);
- the two-way synth/check core;
- cteval, proofs, inlining, the diagnostics, the layout rules, `modules.zig`;
- the `--facts` dumps, which are a ready harness for comparing the old and new compilers.

## A rewrite's spine

parse (Nexus; the IR keeps parentheses and bounds) → resolve (one program-wide type table) → type
(context passed down; produces a typed IR) → lower (one form with explicit temporaries and order)
→ ownership, proofs, frames and emit all read the lowered form → emit prints it.

## Decisions for the owner before a rewrite

1. **Generics.** Keep unbounded type parameters checked per instance (Zig-style; Trig has 108
   generic functions and 47 bounds), and run bounded and unbounded parameters through one
   requirement mechanism. The types reviewer suggested checking against bounds only, but that is
   a language change. [keep per instance]
2. **What kind an object of `?String` values is.** CORE calls it a view and SPEC plain data.
   [CORE's view]
3. **"Is a view" as one fact**, from the start (CORE §9, planned). [yes]
4. **End statement-long loans at their last use**, which CORE allows and the oracle accepts.
   [yes, in the new design]
5. **Keep Nexus.** A reviewer suggested a hand-written parser; fixing the grammar so the IR keeps
   parentheses and bounds removes the parser wrapper's 13 side tables. [keep Nexus]
