# Audit: types and effects, second pass (typecheck 136-11500, cteval), 2026-11-03

Scope: `src/typecheck.zig` and `src/cteval.zig` at revamp-c = main
a4e4ce6a8, after the first pass (`audit-types.md`, rows T1-T17, not
repeated here). Read with the 10-31 review (`review-types.md`,
`evaluators-deferred.md`); nothing they settled or deferred is raised
again (literal kinds by text, the context fields as a design, the four
evaluators, the frame walker, the template generic model).

## What was read

- typecheck.zig 136-11510, line by line, all of it: the `Checker` state,
  declarations, statements, places and access, conditions and loops,
  `match` and coverage, synthesis, operators, the ownership sigils,
  members and indexing, compile-time arguments and `synthCtCall`, calls
  through `checkArgs`, conversions, `print`/`panic`, String, bit, float,
  number-type, enum and slot functions, and every vector form. (The
  first pass's spans 2255-2280, 2440-2475, 2690-2725, 9800-9912 fall
  inside and were read again; their rows are not repeated.)
- cteval.zig 1-405 (values, `Scalar`, `Arr`, `State`, `checkSignature`,
  `checkNames`), 684-1254 (`markIn`, `targetOf`, `signatureOf`,
  `callAt`, `evaluate`, `argValue`, `valueCall`, `recordCall`,
  `writeValue`, `Eval` set-up, `alloc`), 1853-2063 (`member`, `made`,
  helpers, `writeStringLiteral`).
- Docs: INTERNALS "Flags", "Generics", "APIs and API objects",
  "Compile-time functions", "Vectors"; SPEC "Numeric conversions",
  "Chains", range patterns; the first pass's report and the ledger.

## Probes

About 75 programs in `$TMPDIR/aud2`, run with this worktree's `bin/rig`
and `RIG_SANITIZE=1`, along each rule the code above decides: integer
and float literals and their defaults, constant folding and fits
(`U8` constants, `Int.min / -1`, shifts by constants, `1 << 70`),
conversions (`F32(1e300)`, `Int` of a huge or NaN float, `U8(255.9)`,
slots and enum values to narrow types), compound operators (`%=` on
floats, `<<%=`, `%=` by a run-time zero), `match` coverage (error unions
with one member name in two sets, `U8` and `I8` full ranges, `U64` max,
text duplicates, `matches` with `r?` and `none` fields), optionals
(nested `(Int?)?`, `??` through it, `?` propagation, ordering and `==`
of optionals), error sets (`!` into a narrower set, `catch |e| return
e`, `_ = f() catch |e| print(e)` of a `String!`), several results
(`!`, `?`, `as`, `while ... as a, b`), generic requirements (literal
fits, whole division, shifts, `==` with a literal beside `T?`, nested
literal results), constant folding of locals against every write path
(`f(!i)`, `swap`, `|!i|`, a held `!T`, a call's `!T` assigned
through, `for x in !t`), vectors (lane and `with` indexes at run time,
shifts by too much, `select` of literals, masks, `lookup`, compound
shifts), chains (`sum` overflow, `zip`, `enumerate`, `skip`/`take`,
`collect` of views), compile-time functions (arguments in types, enum
values, aliases, `Simd` counts; panics; Bool and enum constants), and
module constants. Each run either panicked where the program was wrong
or printed the right answer, except the rows below.

## Findings

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| U1 | cteval.zig:886-894 (`argValue`, plain-enum branch), reached from cteval.zig:946-984 (`valueCall`) | accept-means-correct | high | Where a compile-time call is folded outside a body (an array length in a type, a type alias, an enum's value, a `Simd` count), an argument for a plain-enum parameter is read by its member name alone: the object is never resolved or checked against the parameter's type. `[size[Nowhere.east]]Int` with `Nowhere` unbound, `type Pair = [size[Nope.south]]Int`, and `enum Code` with `b = size[Bogus.north]` are accepted and run (`Code.b` is 1); `[size[Other.east]]Int`, where `size` takes `Dir` and `Other` is another enum, is accepted and computed as `Dir.east`. In a body or a module constant the same call is rejected, since `synthCtCall` types each argument first (`checkCtValue`, typecheck.zig:8406) and `valueCall` does not. SPEC "Compile-time functions" / INTERNALS: arguments are values of the parameter's type. | probes ct1.rig (prints `[1, 2, 3]`), ct5.rig, ct6.rig (prints `2 1`), ct11.rig; ct2.rig and ct7.rig, the same calls in a constant and a body, are rejected | in `argValue`'s enum branch resolve a `.member`'s object through `names` (`names.symbol`) and require it to name `ty`'s enum (unbound: report the name; another type: "expected `Dir`, got `Other`"); better, U3's shared argument check | +15 | low: `fail` cases for the two messages; the evaluator's results are unchanged for well-typed calls |
| U2 | cteval.zig:874-884, 975-977 | diagnostics | low | In the same out-of-body path, an argument of the wrong scalar kind, or one naming an unbound name, is reported as "must be known at compile time; pass a literal, ...": `[size[1]]Int` for `size[b: Bool]`, and `[size[Bogus.x]]Int` for `size[n: Int]` (no "unbound name" error at all). The value is known; its type is wrong, or the name does not exist. | probes ct3.rig, ct12.rig | report a type mismatch where `ctFoldBy` answers `.mismatch` or the value is of another kind, and an unbound name where `names.symbol` finds none (falls out of U3) | +8 | none |
| U3 | typecheck.zig:8401-8433 vs cteval.zig:956-981; typecheck.zig:8459-8465 vs cteval.zig:988-994 | one classifier per fact; duplication | medium | The arguments of a compile-time call are checked twice, by two copies that disagree (U1, U2): `synthCtCall`'s loop and `valueCall`'s loop each import the parameter type, test for an enclosing compile-time parameter, switch on `argValue`, and print the same three messages, but only the first types the argument. `enclosingCtParam` and `paramArg` are one function written twice ("is `e` a compile-time parameter of an enclosing generic, or a `=!` binding of one"). | the lines; probes ct1 vs ct2 | one `cteval.ctArgs(ctx, call, target, f, names, typer)` used by both, where the body path passes its `checkCtValue` and the type path a check of each argument's kind and enum against the parameter's type; one `paramArg` | -30 | low: `swarm test/rig.rip types-ct*` and doc examples pin the messages |
| U4 | typecheck.zig:14561-14567 (found by probe; outside the range read) | doc and rule disagree | medium | SPEC "Chains" says `collect` of views is rejected with the fix `.map(\|x\| +x).collect()`, but the check lists only `.read_view` and `.write_view`, so a `?String` or `[]T` item passes: `List[String]`'s `xs.filter(\|s\| s.len > 1).collect()` is accepted as a `List[?String]`. It is memory-safe (the List keeps `xs` lent; the oracle accepts the read and rejects a later `!xs.push`), so the divergence is SPEC against code, not a hole. | probes ch3.rig (prints `["bb"]`), ch6.rig (`!xs.push` after it rejected; oracle: 1 rejected) | decide with the owner: test `sema.mayHoldView(it)` as the SPEC says (and add a `fail` case), or say in SPEC that `collect` of views gives a List of views that keeps the source lent | +1 | low |
| U5 | typecheck.zig:5683-5684 with 5509-5511 (`numericOperands` → `orderingOperand`) | diagnostics | low | `a > 2` with `a: Int?` says "`Int?` cannot be ordered", in the same program that accepts `a < b` of two `Int?` (`orderedBeside`): an optional orders; what fails is an `Int?` beside an `Int`. | probe e2.rig | where the other operand's type is the optional's value type, say so: "`a` is an `Int?` and `2` an `Int`: compare `a ?? 0 > 2`, or `if a as v`" | +4 | none |
| U6 | cteval.zig:2045-2063 (`writeStringLiteral`) | diagnostics | low | A compile-time `panic`'s message is unescaped by hand and knows only `\n \t \r \0`: `panic("bad \x41 \u{42}")` is reported as `bad x41 u{42}`; `\0` is read though `checkEscapes` (typecheck.zig:4970-4998) rejects it. | probe ct8.rig | decode with the escape reader the run time uses (`textLiteralBytes`, which `checkTextPattern` already calls) | -15 | none |
| U7 | typecheck.zig:1373-1377, 3992-3993, 6414-6428, 7373-7374, 8319, 9115-9116, 10565-10566; 2808-2812 | stale comments | low | Seven more doc comments sit on the wrong declaration, each above another function's doc, which then reads as one comment, while their own function has none: `checkDiscard`'s (above the several-results banner), `tempBase`'s (above `madeBase`), `fallbackType`'s (above `recordFallbackLiterals`), `synthBox`'s (above `stackedSpelling`), `sourceText`'s (above `headerText`), `synthCall`'s (above `inlineResult`), `enumFromTextCall`'s (above `symbolNamed`). At 2808-2812 a superseded comment stands above the one that replaced it. (T6 found three of this kind.) | the lines | move each onto its function; delete the superseded two lines | -2 | none |
| U8 | typecheck.zig:3296-3299; 4664-4666 with sema.zig:5712-5741 | leaks in the compiler | low | Two allocations use `ctx.allocator`, which nothing frees: `iterLoop` builds its hint prefix (`dupe`, `allocPrint`) for every `for` over an iterator, before knowing it will report, and `payloadTestsOf` allocates the `binds` and `tests` slices that `payload_binds`/`payload_tests` keep, and no code frees those slices. `smp_allocator` hides it from `rig check`; the language server re-checks in one process and grows. | the lines; `grep payload_tests src/*.zig` | the arena (`self.ctx.arena.allocator()`), as every other message and fact slice here uses; build `head` only where it is reported | 0 | none |
| U9 | typecheck.zig:3242-3244 with 3340; 2384-2386; 3256-3261 | dead code; needless complexity | low | `bare_place_advances` is a `const false` "switch", so the `.place => if (bare_place_advances) .place else` arm has a dead half; `const verb: Verb = switch (access) { else => access.verb() }` is a switch of one arm; `loopLendsSelf` takes `self` only to discard it and returns `ir.For.lent(node) != .nil`. | the lines | drop the constant and its branch; `access.verb()`; inline the wrapper | -10 | none |
| U10 | typecheck.zig:10645-10686; 10574-10605; 4912-4937 vs 6842-6864; 9759-9771 | duplication | low | `simdNamed` and `slotNamed` are one function with `.simd`/`.slot` and the symbol swapped; `symbolTypeCall` and `enumFromTextCall` share their argument checks and `checkArgs` set-up line for line; `cellCopiedByBranch` and `lendsBranch` each walk the leaves with the same positive list (`made`, `lend`, `jump`, or `isConstant`) and build the same "each branch lent" fix; `hasVariantNames` repeats `isBuiltinEnumTy`'s body. | the lines | `builtinTypeNamed(obj, sym_id, tag)`; one `fromTextCall(callee, result_of, …)`; one `namedBranchLeaf(leaves)` and `lentWiths(leaves, sigil)`; `hasVariantNames` calls `isBuiltinEnumTy` | -45 | none: messages unchanged |
| U11 | rig.grammar range patterns (front end; found by probe) | wrong rejection; diagnostics | low | A range pattern's end written in parentheses is a parse error with a misleading message: `0..(1 + 1) =>` gives "a range needs an end; only a slice leaves a side open", while `for i in 0..(1 + 1)` parses. SPEC (range patterns) and `checkRangePattern` (typecheck.zig:4536-4538) take any constant integer bound. | probe rp3.rig | let a range pattern's bounds be the operand forms a `for` range takes; `checkRangePattern` already folds them | small, front end | low (grammar change, conflicts policy) |
| U12 | typecheck.zig:6579 | diagnostics | low | "`e` is a `AB` error": the article is written `a` by hand where `article(name)` is used elsewhere. | probe g5.rig | `article(try self.tyName(actual))` | 0 | none |
| U13 | cteval.zig:841 | effects | info | `evaluate` maps any `std.Thread.spawn` failure (thread quota, resource limits) to `error.OutOfMemory`, so a machine that cannot start the 512 MiB-stack thread stops `rig check` with "out of memory". | the line | report it as a diagnostic at the call ("could not start the compile-time evaluator") | +3 | none |

No critical finding. No accepted program in the probes miscompiled,
leaked, or crashed under `RIG_SANITIZE=1`; every run-time check the
rules promise (lane and `with` indexes, shift amounts, float-to-integer
truncation and NaN, conversions of slots and enum values, division by
a run-time zero, overflow in `sum`) panicked where written. Constant
folding of locals (`const_ints`, typecheck.zig:1809) was tried against
six write paths and never folded a written binding. Vocabulary is clean
in the ranges read: no "borrow", "receiver", or "struct" for an object.

## Stated rules and restrictions

| Rule (where stated) | Where decided | Judgment |
|---|---|---|
| A compile-time function reads only integer module constants (INTERNALS "Compile-time functions": "integer constants, plain enums, and integer aliases") | cteval.zig:342-352 | Sound but narrower than the evaluator: `FAST = true` and `HOME = Dir.south` are values `Eval` holds (`CtVal.boolean`, `.variant`), and `patternConst` already knows them (probe ct13). Worth lifting when compile-time functions next change; not urgent. |
| A Bool argument of a compile-time call in a type position | grammar: `[size[true]]Int` is "unexpected keyword `true`; expected a type, an integer or `-`" (probe ct4/ct10) | An enum argument is written there, a Bool cannot: an unstated asymmetry. Either accept `true`/`false` there or say in SPEC that a function called in a type takes integers and enum values. |
| `F32(x)` of a constant too large is an infinity (SPEC "Numeric conversions") while `x: F32 = 1e300` is rejected | typecheck.zig:9741-9747 | Stated and consistent: the conversion is the written way to accept rounding. Keep. |
| A range pattern's end may be one past the type's largest value only as a literal (`checkRangePattern`, typecheck.zig:4547) | typecheck.zig:4547-4554 | `128..TOP` with `TOP = 256` is a type mismatch (an `Int` constant beside a `U8`), so a named limit cannot reach the top; acceptable, since `128..=255` says it. Leave. |
| A module constant's arithmetic must be computed by Rig; an element of a constant array is no constant (`B = A[1]` rejected) | typecheck.zig:564-638 | Sound: Zig would fold it again and stop at an overflow. Leave. |
| `collect` of views is rejected (SPEC "Chains") | typecheck.zig:14561 | See U4: the rule as written is not the rule built. |
| Lane and mask forms (INTERNALS "Vectors") | typecheck.zig:10607-11054 | Built as documented; every probe agreed with the table. |

## The biggest simplification that is not a rewrite

A compile-time call's arguments are checked in two places that have
already drifted: `synthCtCall` (typecheck.zig:8401-8433), which types
each argument first and so rejects `size[Other.east]`, and
`valueCall` (cteval.zig:946-984), which runs where types, aliases, and
enum values fold it and reads an enum argument by its member name
alone (U1, U2), with the "enclosing compile-time parameter" test
written twice (`enclosingCtParam`, `paramArg`). Folding both into one
`cteval.ctArgs`, which checks each argument's kind and enum against
the parameter and reports unbound names, with the body path adding
only its `checkCtValue`, removes about 30 lines, makes the verdict the
same wherever a call is written, and fixes the one high finding of
this pass by construction rather than by a patch to `argValue`.
