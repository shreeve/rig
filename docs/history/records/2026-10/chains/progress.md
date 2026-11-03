# Row 2 progress (worktree ~/Data/Code/worktrees/rig/chains, branch `chains` on main 94873583e)

Read first: decision.md (owner's 7 decisions; ties follow Rust: min first, max last), summary.md,
zig.md §2 (the exact trim lowering + emitted Zig), rust.md, swift.md (traps: owned List elements
need an index; ranges hold bounds; take tests before next(); closures bound once, in place).

## Plan, in slices (each tested before the next)
1. Infrastructure: `(item_type NAME)` wrapper node (rig.grammar), resolved by
   `TypeResolver.chainItemType` (src/resolve.zig): closure -> result (ok of fallible); slice/array/
   List -> element as `for` reads it (copy or read view); range -> int; iterator -> `next` item;
   else the binding's own type.  [DONE, builds]
2. Hidden names for the rewrite (HiddenName in src/rig.zig: "chain source", "chain item",
   "chain value", "chain best", "chain key", "chain first", per-stage "chain stage N",
   "chain count N", "chain limit N"), synthetic leaf positions via `pad_homes`
   (pos = source.len + padded; Parser.span maps to the home), and hidden names exempt from
   `checkShadowing` (resolve.zig) so nested chains work.
3. Round 1: typecheck recognizes a call chain of stage methods ending in a consumer (or a `for`
   source that is a stage chain) on a for-able source the type does not give such a method;
   records it (sema fact `chains`, with the source kind: iterator / List-array-slice / range).
   modules.zig loop: `or m.sema.chains.items.len > 0` -> `parser.desugarChains`.
4. Rewrite (Parser.desugarChains): `while true` value wrapping: hold source, bind each closure
   once (`new f = |e: (item_type PREV)| body`), state, loop(s), `break result`. Peel for
   min/max/min_by/max_by (zig.md §2). Iterator sources loop as `while COND and (!h).next() as x`.
5. Slice 1 = trim end to end: iterator source, filter, count, min_by, max_by (+ code test, timing).
6. Then Lists/arrays/slices (owned elements: index), ranges, then map/take/skip/enumerate/zip,
   sum/collect/reduce/any/all/find/min/max.
7. Ownership: allow `!@entries.take(+oldest.key)` where oldest views @entries; fail case for
   `take(oldest.key)`. trim as a passing case.
8. Docs (SPEC after `for`, STD, iterators.md pending -> ordinary, CHANGELOG, HANDOFF), gates,
   measurements (Mac, then pup via Swiss), PR. Owner merges.

## Status 2026-11-03 (later)
- DONE: item_type resolver; hidden names; round-1 recognition (`Checker.chainCall`, sema `chains`);
  rewrite `Parser.desugarChains`/`lowerIterChain`/`lowerConsumer`/`lowerPeel`/`lowerForChain` in
  src/rig.zig. Leaves are made in source order (names resolve by position). Works: count, sum,
  any, all, find, reduce, collect(untested), filter, map, take, skip, enumerate, for-chains on a
  List; trim (Map iterator, filter + min_by) = hand loop output `2 60 4`, sanitizer-clean.
- SPLIT OUT: `!@entries.take(+oldest.key)` needs ownership to start a write receiver's lend after
  its arguments (ownership.zig walkCallBody: `lendOn(... .write)` at receiver walk) + oracle + CORE
  paragraph: its own change, after chains. Typecheck allowance drafted then reverted.
- TODO: zip; Lists of owned elements in min/max/find (index form); ranges tests; place iterators
  (`for x in !it` style); errors in chain terms; tests; docs; measurements; gates.
- Mac timings (release, tools/low, fastest of N interleaved; programs in /tmp/claude-501/ch/bench):
  trim filter+min_by over 200k Map entries x20: hand(clone) 2471-2546 us, hand(view) 2749-2812,
  chain 2314-2350 (chain 6-8% faster: one key clone at the end). filter+map+sum over 20M U64:
  loop 5455-5573 us, chain 5468-5501 (noise). Emitted Zig = zig.md §2 shape.
- DONE since: index form for element sources (min/max/*_by/find) w/o map; inclusive ranges;
  `for x in ?m.keys().filter(f)` puts the `?` back on the source's self; place iterators must be
  written `(!it).stage(...)` (round-1 error with the fix).
- Later: zip (one per chain); for-chains lend a List element on (`new p = ?item`); hidden-leaf
  diagnostics map to their home (sema report); failing closures rejected with the fix (follow-up);
  tests test/rig/types-chains.rig.test (16 cases) pass; design page examples now ordinary; docs
  SPEC "Chains", STD, CHANGELOG, HANDOFF, iterators.md decision 8. Full suite `all` running.
- Follow-ups for the owner's list: failing closures in chains; errors in chain terms (type errors
  inside a chain can name `chain value`); `take(+best.key)` (ownership: write receiver lend after
  args + oracle + CORE).
