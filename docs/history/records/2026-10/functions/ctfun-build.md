# Compile-time functions v1: build report

Branch `fun-and-comptime`, commit `1405820b9` on top of `e36369d62` (left alone). Not pushed.

## What was built (comptime.md §1–§5)

- **Declaration.** `rig.isCtFun(decl)`: a `fun` with tparams and `params == _`. The Parser wrapper
  (`Parser.ctFunShape`, src/rig.zig) lets the form stand only at module level, every bracket field
  `name: Type`, with `->`, a body, no marker, no `from`/`keeps`. Rejections with their own messages:
  `sub s[n: Int]` (both readings), method form (in a body or `fun P.c[...]`), `inline`/`called`, no
  result, no body. `fun s[T] -> Int` and `fun f -> Int` keep the old fix-it. `fun t[]` keeps the parse
  hint.
- **Order.** `resolve.orderModuleConsts` orders constants and compile-time functions together; a cycle
  of functions alone is recursion, a cycle through a constant is reported at the constant
  (`N` → `f` → `N`). `foldModuleConsts` checks each function in that order (`ensureCtFun`): signature
  (`ensureCtSig`, plain enums it names resolved early, `resolveEnumsNamed`), `cteval.checkNames`
  (constants must be folded integers, aliases integer aliases, types plain enums), the body typed by
  `typecheck.checkCtFun` (`Checker.in_ct_fun`), then `cteval.checkBody` (positive list). Separate
  stages for signature and body detect "needs its own value".
- **Evaluator** `cteval.Eval` (new file src/cteval.zig): tree walk over checked IR, types from
  `typeOf`, arithmetic through `sema.ctArith` (factored out of `ctFoldBy`, which now calls it).
  Limits 10M steps, depth 256, plus a 64 MiB cap on values made. Memo per declaring module
  (`SemContext.ct.memo`), failures too. Cross-module `pub` calls evaluate in the declaring context.
- **Calls.** `ctFoldBy` asks `names.ctCall(e)` on bracket nodes: `ConstNames` evaluates (types,
  constants, enum values), `CheckedNames` reads the recorded value. Typecheck `synthCtCall` checks
  arguments, computes, records `Instance.ct_call`. In a body, `ctCallInBody` types only (any argument,
  but result-sizing params follow `ctIntArg`). Generic-parameter argument gets the v1 message.
- **Emit.** Scalars as literals (`@as(i64, 7)`, `@as(Mode, .loose)`); arrays in bodies as one
  `const __rig_ct_N` per module per value; module constants as literals. Skips: `rig.eachBody`,
  storage walk, ownership, proofs summaries, frame owners, inlining mentions, emit, oracle (which also
  folds a ct call as a constant).

## Deviations from comptime.md

1. **Contents window.** Typecheck needs ownership facts (`contents_ready`), computed after all
   declarations. Bodies are checked before that, so `sema.beginEarlyContents`/`endEarlyContents`
   compute contents for the early plain enums and recompute type facts around the body check only.
2. **Grammar:** used the recommended diff without its `STRING_DQ`/`STRING_SQ` `targ` alternatives
   (text parameters are deferred; keeps today's errors for strings in types).
3. **`Mode` result emits `@as(Mode, .loose)`**, not `Mode.loose`.
4. **Range-pattern bounds** cannot be calls: patterns have no call syntax. Not in the test list.
5. **Aliases in bodies** are limited to integer aliases (an object alias is rejected by name before
   typing; it would otherwise read as an unresolved type).
6. **Fill length** failure says "makes an array of length -1: an array length runs from 0 to ..."
   rather than the instance message (no instance exists).
7. LSP hover not done (optional).

## Tests

- `test/rig/ctfun.rig.test`: 68 cases (16 test, 45 fail, 7 code), all green.
- `test/torture/27_ct_runaway.rig`: steps, depth, and size limits, 0.14 s.
- `test/cli/facts_sema.sh`: `instances index ... "squares[3]" ct [0, 1, 4]`.
- Docs: SPEC §16 "Compile-time functions" (runnable example, `rig reject`, `rig pending` for
  `cap[n]` in a generic), SPEC Arrays and Constants, SYNTAX §8 (functions bullet, generics table row
  and paragraph), §11, DESIGN "Brackets for compile time", INTERNALS (source map, Constants, new
  "Compile-time functions"), AGENTS map row.

## Suites (Mac, through tools/heavy)

- core `swarm test/rig.rip -q`: 5358 jobs, green (oracle coverage and rejections unchanged).
  An earlier run had one `concurrency-deadlock.007` failure under load 9; it passed alone and in the
  final run.
- `cli`: 91 jobs green. `probes`: 4053 jobs green. `zig build test` green.

## Timing (ReleaseSafe, `rig check --time`, best of 7 interleaved; instructions median of 7)

| Input | base total | new total | instructions |
|---|---|---|---|
| bench/check workload | 129.30 ms | 128.70 ms (0.5% faster) | 2,486.3M → 2,490.3M (0.16% more) |
| bench/terminal/bench.rig (std.terminal) | 34.76 ms | 34.70 ms (0.2% faster) | 563.4M → 563.6M (0.04% more) |

Load was 5 to 12 (other agents), so per-pass times move about 3%; totals are within noise.
Debug compiler: 10M steps take about 1.7 s; release about 0.14 s.

## Grammar note for the Nexus session

`rig.grammar` changed: `tatom`'s instance alternative became a shared `ccall` rule
(`name "[" types "]"` and `name "." name "[" types "]"` → `generic_inst`), also used by `dim` and
`cunit`. Nexus keeps a verbatim copy in `grammars/rig/`; `src/rig.zig` changed too (wrapper).
Not edited in the Nexus repo.

## Review round (commit 41abde13a, on d7fb63943)

1. Views/writes into a call: `cteval.markCalls` retags `index`/`inst`/`generic_inst` whose callee
   names a ct function (scope-aware `lookupBefore`, so `new cap = ...` hides it) as a new IR kind
   `ct_call` (schema `@wrapper`). `shapeOf` lists it as `.made`; fact `SemContext.ctCallOf`
   replaces `Instance.ct_call`. l4/n3/l3/l5/n4/n7/n8/n2 now get the array-literal verdicts.
   Ownership and storage now check ct bodies too (a loop changing its source is rejected, as at run time).
2. Early window: plain enums join the constant/ct-function order; their variants (and values) are
   resolved there (`resolveVariantsEarly`, `TypeResolver.part`), methods in the normal loop.
   Signatures resolve outside the window (`ensureCtSig` closes and reopens it). `endEarlyContents`
   resets the contents it computed. Chosen over "no caches during the window" because it keeps the
   window to complete plain types, so nothing wrong can be cached. h5/h1/h4 fixed by walking
   parameter groups in `constNamesIn`.
3. Variants are ordinals; `Int(m)`, `U8(m)`, `<` use the declared value; Bool orders false<true;
   all union reads go through checked helpers (no panics).
4. Evaluation runs on a 512 MiB-stack thread; `max_nest` 20,000 counted in `exec`/`held`
   (measured 2.5–10.7 KiB per nesting in a debug build).
5. Each op in `typeOf(node)` (shifts included); results checked against the substituted result type.
6. Owned/borrowed discipline (`Held`), every array allocated alone and tracked in `live`; copies on
   every binding, assignment, element, result.
7. `_ = e`; live-memory cap; per-call memo (`Eval.memo`) with the module memo only for the same
   top-level call; foreign calls in bodies import the signature; `[(cap[2])]T` parses (dim only;
   `(cap[2]) * 2` gives a shift/reduce conflict, so not added).

Tests: ctfun 98 cases. Core 5387 jobs, CLI 91, probes 4053: green.
Timing (load 10–13): workload 134.69 → 136.63 ms (1.4% slower, noise level), instructions 0.2% more;
terminal 35.81 → 35.66 ms, instructions 0.13% more.
