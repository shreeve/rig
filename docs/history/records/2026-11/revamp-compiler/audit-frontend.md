# Compiler audit, phase 1: the front end (2026-11-03)

Scope: `rig.grammar`, `src/rig.zig` (Lexer and Parser wrappers), `src/resolve.zig`,
`src/modules.zig`, `src/diag.zig`, at revamp-c = main a4e4ce6a8. Read-only; every probe
ran with the worktree's `bin/rig` under `RIG_SANITIZE=1`, in `$TMPDIR/fe`. Items the
10-31 review settled or deferred (no lowered IR, per-module type stores and
`registerBuiltins`, the re-check loop, `@constCast` mutation, IR names `struct`/`lambda`)
are not raised again.

## Findings

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| F1 | src/rig.zig:3774-3784 (`refersAt`), 3708-3745 (`rewriteBuiltin`) | accept-means-correct (construct dropped) | high | `builtinRefs` rewrites every leaf spelled like one of the 14 Rig-written built-in types (`Map`, `Set`, `Item`, `Items`, `Keys`, `Values`, `Members`, `HashMap`, `HashSet`, `Hash*`, `Lanes`; rig.zig:2337) into `__rig_prelude.Name`, including an enum's or error set's variant, which lives in the untagged `members` role `refersAt` does not exclude. The variant silently disappears from the type. | `enum Kind` / `List` / `Set`, then `match k` with `.List` alone: accepted as exhaustive, prints `list`; `$size(Kind)` prints 0; emitted Zig is `enum { List }`. Any use of `.Set` then fails with "no variant `Set` on enum `Kind`" pointing at the declaration that has it (probe s1). SPEC §Enums (SPEC.md:2319) reserves no variant name, and `List` and `Int` work as variants (y5). | In `refersAt`, a leaf in the `members` role of `enum`, `generic_enum`, `errors` names itself (return false). | +3 | low |
| F2 | src/rig.zig:3667-3690 (`builtinRefs` hiding), resolve.zig:4461, 4467, 3544-3552 vs 2484-2488 | wrong rejection; diagnostics; one classifier | medium | (a) The rewrite is scope-blind: a type parameter, a local, or a parameter named `Item`/`Keys`/`Map`/... is turned into the prelude type. (b) The rejection then names the hidden module: "generic type `__rig_prelude.Item` requires type arguments; write `__rig_prelude.Item[T, ...]`", "`__rig_prelude.Values` is a type, not a value". (c) "A type parameter may not take a built-in type's name" is decided twice and the two disagree: `checkTypeParamNames` (3544, a type's parameters) calls `[Cell]` "the module-level declaration `Cell`"; `resolveCtParam` (2484, a function's) calls it "a built-in type"; neither knows the prelude names. (d) A `use x as Map` in one file of a directory module hides the prelude `Map` in every file (the hiding scan is module-wide, 3668-3685), though a `use` binds in its own file only (INTERNALS, Directory modules). | b1: `fun first[Item](xs: ?List[Item]) -> Item`, `obj Box[Keys]`; b2: `Values = 3; print(Values)`; y3 `fun first[Map]`; y4 `obj Box[Cell]` vs y7 `fun f[Cell]`; b3 `s: Set = 3`. | One resolve function `builtinTypeName(name)` (primitives, sized, `Self`, registered built-ins, `rig.builtin_type_names`) used by both checks, so all report "has the name of a built-in type". Format a prelude-qualified name without the hidden module in resolveQualified and typecheck's "is a type, not a value" (sema.zig:13693 already drops it for type printing). Or take the larger fix in the closing section. | +20 | low |
| F3 | src/rig.zig:4857-4885 (`namePaths`, `namePathsIn`) | accept-means-correct | high | Every member chain in a closure's body that spells a captured path (`|?p.a|`) is replaced by the capture, whatever scope it is in. A `new p` in the body hides the outer `p`, yet the body's `p.a` still reads the capture: the program says 7 and prints 1. | c3: `p = P(a: 1)`; `g = \|?p.a\|` / `new p = P(a: 7)` / `print(p.a)` / `print(?p)` prints `1` then `P(a: 7)`. Other rebinding forms are rejected (`for p`, `if mk() as p`, a parameter `p`: c1, c4, c6), so only `new` reaches it. | Reject a `new` of the root of a path the enclosing closure captures, in resolve (`checkNewLocal`, resolve.zig:1063), with "`p.a` in this closure is the capture; name the new value otherwise". | +10 | low |
| F4 | src/rig.zig:5314-5326 (`countName`, `limitName`, `stageName`), 2117-2186 (`HiddenName`) | accept-means-correct (compiler crash); diagnostics | high | Hidden names exist for 8 chain stages, but nothing limits a chain to 8. Stage 9 to 12 compute enum values that are `zero_value`, `one_value`, `none_value`, `list_type`, ... so the chain binds a leaf whose text is `0`, `1`, `none`; stage 13 on is past the enum: `@enumFromInt` panics the ReleaseSafe compiler. | o1 (9 `map`s): "closure `0` cannot be moved..." at 4:1, a blank line; o3 (9 `take`s): "`none` is the absent optional and cannot be used as a name"; o2 (13 `map`s): `thread ... panic: invalid enum value` at rig.zig:5577 in `lowerIterChain`. SPEC §Chains states no limit. | Reject a chain of more than 8 stages where typecheck records it, naming the limit ("split the chain: bind its first stages' `collect()`"), and state the limit in SPEC §Chains; or number the hidden names past 8. | +8 | low |
| F5 | src/rig.zig:4138-4160 (`checkMatches`, `isNameLeaf`) | diagnostics (false claim) / wrong rejection | medium | `isNameLeaf` counts `none` as a name, so `o matches none` is rejected with "`none` matches every value". `none` is a value pattern: `match o` / `none =>` is accepted (u1). docs/design/matches.md rule 3 rejects `_` or a bare name only. | u1: `print(o matches none)`. | Exclude `none` in `isNameLeaf`; then either accept it (it is a match arm's pattern) or reject it with "write `o == none`" (owner's call; default: accept). | +3 | low |
| F6 | src/rig.zig:3491-3497, 4586-4606 (`loopSelf`, `lentSource`) | wrong rejection / rule consistency | medium | The self-sigil rule moves a `?` on a `for` source onto the first call's self (`for x in ?b.each()` is `(?b).each()`, SPEC §Loops over an iterator), but a `!` or `<` there stays the loop's mode. `for x in !b.counter()` (a `!@` method giving an iterator) is rejected: "method `counter` needs `self` lent to write; write `(!b).counter()`", and that spelling then runs. The same text means two things in and out of a `for` header. | l1. | Owner decision. Default: extend `lent` to `!` when the source is a method call (`loop_sigil` for `.write` too), so `for x in !b.counter()` is `(!b).counter()` advanced in place, as `!b.counter()` reads anywhere else. | +4 | medium |
| F7 | src/rig.zig:3747-3812 (`lanesMembers`, `fileAt`, `builtinRef`) | check speed (super-linear) | medium | For each built-in name, `builtinRef` calls `fileAt` (a scan of every file's end) for each entry of `firsts` (one per file): O(refs x files^2) on a directory module. | big: a 400-file directory module with 16k `Map`/`Set` mentions: lex and parse 400-434 ms; the same text as one file 19 ms; 200 files 64 ms; 400 files without Map/Set 11 ms. | Keep a `seen: []bool` per file and find the file by binary search over `Lexer.ends` (or carry the file index down the walk). | -5 | low |
| F8 | src/rig.zig:2658-2667 (`afterOnce`) | spacing rule hole | low | The exemption for `f: once ?fun()` scans the text for `: once` before the operator, so a local named `once` after a keyword argument's colon escapes the spacing rule. | v3: `g(n: once -y)` is accepted and subtracts; `x -y` is rejected everywhere else (v2). | Exempt the record by the parse: the type of a `(once name type)` parameter starts at the sigil (the wrapper sees every `once` node in `onceParams`). | +2 | low |
| F9 | src/rig.zig:4620-4652 (`waitTakesName`) | diagnostics (malformed fix-it) | low | The fix-it is spliced from source slices; `@t` has no `.`, so `>@t` gets "write `(>@)t`". | x1: `print(>@t)` in a `<@` method. | Insert the `.` when the head is `@` and the rest starts with a name. | +3 | low |
| F10 | src/rig.zig:54 (`isApiDecl`), 2424 (`Api.ownable`), 1994 (`Lexer.afterBareB`) | dead code; misplaced comment | low | No caller in src/, test/oracle, tools, or std. `afterBareB` sits between `stringError`'s doc comment (1990-1991) and `stringError`, so that comment now heads the wrong function. | `grep -rwn` of each name. | Delete the three; the comment rejoins `stringError`. | -16 | none |
| F11 | src/rig.zig:2264, src/resolve.zig:4822, src/typecheck.zig:4240 | duplication / naming | low | Three functions named `patternBinds` mean three things: a `matches` pattern binds a payload name; a leaf arm pattern binds (not `_`, not a literal); a pattern binds a given symbol. resolve.zig imports none of the others, so a reader cannot tell which is meant at a call. | the three definitions. | Rename: `rig.matchesBinds`, `resolve.leafBinds`, `Checker.bindsSymbol`. | 0 | none |
| F12 | rig.grammar:24-30, 76-79, 783-785, 1173; docs/internals/INTERNALS.md "Keywords" | stale comments; vocabulary | low | The grammar header says the rewriter "classifies three contextual words" and lists six; the token comment says every keyword but `new`, `obj`, `api`, `add`, `inline`, `called`, `rarely` is reserved, INTERNALS says all but `new`, `obj`, `inline`, `called`, `rarely`, `of`, then "so all three stay in the wrapper". The grammar says "receiver" three times (the rule: self). | the lines. | One list of contextual words in INTERNALS, the grammar comment pointing at it; "self" for "receiver". | 0 | none |
| F13 | src/typecheck.zig:5105 (message of a closure capture) | diagnostics | low | A parameter of an enclosing closure is called "a local of the enclosing function". | g1: `xs.map(\|+ys, x\| ys.filter(\|y\| y > x).count())`. | Say "a local of the enclosing closure" when the symbol is a closure parameter. | +2 | none |
| F14 | src/rig.zig:3438-3452 (`expectedHint`), 3016 (`foreignWord`) | diagnostics | low | Two common slips get no hint: `if x = 3` reports "unexpected `=`" (no "write `==`"); `fun f(x Int)` reports "unexpected name `Int`" (no "write `x: Int`"). | the `t.rig` probes. | Two `@errors`-style hints at the parse failure, beside `headerColon`. | +15 | none |

Checked and found sound (no finding): operator spacing and sigil touch over 20 forms (h1);
closure bars against bitwise `|` (m1); layout islands with `return` inside (n1);
contextual words as names, all 16 (k1); chain lowering with `continue`, nested chains,
`take`/`skip`/`enumerate`/`find`/`max_by`/`collect` of Strings, a source evaluated once
(g1, g2); a line continuation or an open bracket at a directory module's file end (dm); a
module named with the wrong case on a case-insensitive disk (cs); module-level `new`,
`+=`, destructure rejected (w1-w4); duplicate and misnamed methods outside the body
(q1, q2); constant patterns, and `new` hiding them (i1, i2); column numbers over UTF-8 (e2).

Check speed on bench/check's workload (`rig check --time`, best of 7, Mac): lex and parse
16.2 ms, resolve 13.4 ms, of 110 ms. A program of 100 one-function modules spends 8 ms in
resolve, about 80 us a module for the per-module built-ins (review 1.4, not raised). The
cached 10-13 baseline binary runs the workload in 940 ms, so it is not a comparable build,
and the guard's 10.0 / 7.3 ms per-pass baseline could not be checked against it here.

## Stated rules and restrictions

| Rule | Where | Judgment |
|---|---|---|
| A prefix sigil touches its operand; an infix operator has the same spacing on both sides | Lexer.checkSpacing, `detached_prefix` | keep; close F8's text-scan exemption |
| Tree depth 1000; 64 blocks, 512 brackets, 32 islands; 16 MiB a source | Parser.max_tree_depth, Lexer, modules.max_source_bytes | keep: they bound every recursive pass (1,200 `+` terms are rejected with a clear message) |
| A module-level binding is a constant, written `=` | Parser.moduleConsts | keep |
| A function writes its parameter list, even empty | Parser.paramList | keep |
| Captures come before parameters; a capture names a local or a field path, never an element | splitBars, capturePlace | keep |
| A captured path's text in the body always reads the capture | namePaths | change: reject `new` of its root (F3) |
| `matches` takes no `_` or bare name | checkMatches | keep, but `none` is a value (F5) |
| A wait takes a name alone (`>t`) | waitTakesName | keep; fix the fix-it (F9) |
| The 14 Rig-written built-in type names are taken module-wide, whatever the scope | builtinRefs | change: a variant, a type parameter, a local keep their own name (F1, F2) |
| A chain has at most 8 stages | HiddenName (unstated) | state it in SPEC and reject past it (F4); 8 is enough |
| A `for` source's `?` before a method call lends the call's self; `!` and `<` are the loop's mode | Parser.rewrite / loopSelf | owner decision (F6); default: `!` follows the self rule too |
| `rarely` is the first line of a body it may mark | strayRarely | keep |
| Import cycles are rejected; a directory module is the unit of mutual recursion | ModuleGraph | keep |
| A module path is spelled as on disk; `__rig` names are the emitter's | modules.findModule | keep |
| A type parameter may not take a built-in type's name | resolve 2484, 3544 | keep, decided once (F2c) |

## The biggest simplification short of a rewrite

The prelude names are the one place the wrapper resolves names by spelling, and four of
the findings (F1, F2, F7, and the hidden module in messages) come from it.
`builtinRefs`, `rewriteBuiltin`, `refersAt`, `builtinRef`, `lanesMembers`, and `fileAt`
(about 150 lines) can go: keep the one hidden `use` of the prelude per file, and have
resolve fall back to the prelude's scope when a type name finds nothing in the scope
chain (locals, type parameters, the module), the way `foreignSymbol` already reads
another module's declarations. A variant, a type parameter, or a local then shadows a
built-in name as any scope shadows an outer one, and every message prints `Map` because
no tree ever says `__rig_prelude.Map`. This needs neither one program-wide type table nor
a lowered IR; the cost is one fallback in resolve's lookup and in typecheck's `visibleIn`,
with the core suite and std as the check that nothing else relied on the rewrite.
