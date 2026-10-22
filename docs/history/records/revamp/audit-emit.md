# Audit: code generator and runtime (`src/emit.zig`, `src/runtime.zig`)

Branch `revamp` @ 5f2bdbc (suite 1671/0/0). I read `src/emit.zig` (5,367 lines) and
`src/runtime.zig` (1,807 lines) in full, plus AGENTS.md, docs/INTERNALS.md (Emit, The
runtime) and the relevant SYNTAX/SPEC sections. I ran ~120 probe programs through
`bin/rig check|run|emit|test|build` (Debug, `--release`, `--release=fast`). Probes are in
`scratchpad/audit-emit/*.rig` (session scratchpad
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/audit-emit`).

Every fix marked "verified" below was applied to a scratch copy of the tree
(`scratchpad/rigcopy`, patch in `scratchpad/audit-emit/fixes.diff`: 2 files, +29/-75) and
the full suite was run on it: **1671 passed, 0 failed** (twice; a third run under heavy
parallel load had one timeout that did not reproduce). Tracked files were not touched.
Per AGENTS.md each fix still needs its failing test first; the probe files are the seeds.

Severity: **critical** = `rig check` accepts it and the emitted Zig fails to compile (or
corrupts memory / leaks); **high** = accepted, builds, wrong output; **medium** = safety or
platform gap; **low** = dead code, stale docs, cost, formatting.

Overall: the front end now rejects nearly everything the emitter cannot lower (every
earlier EM-* finding I re-probed is fixed), so the remaining bugs are in names the
emitter introduces that are not in the reserved `__rig` namespace, one runtime width
assumption, and one evaluation-order gap in argument hoisting.

## Findings

| ID | file:line | category | severity | finding | evidence (repro -> command -> output) | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| EMIT-1 | emit.zig:4453 (`pub fn invoke(`), 3677, 3849; runtime.zig:605, 653 (`Env.invoke`) | Zig compile error (name collision) | critical | A closure's environment method is named `invoke`, which is not reserved. (a) Any local or parameter named `invoke` in a function that creates a closure; (b) a closure parameter or body local named `invoke`; (c) a module-level declaration named `invoke` used inside a closure body: all fail in Zig. | ee4.rig: `invoke = 3` / `print(invoke)` / `f = \|\| print("x")` / `f()` -> `bin/rig run` -> `error: declaration 'invoke' shadows local variable from outer scope`. ee6.rig: `fun invoke(x: Int) -> Int` + `f = \|a: Int\| invoke(a) + 1` -> `error: ambiguous reference`. ee7.rig: `fun helper(invoke: Int)` holding a closure -> `shadows function parameter`. ee (closure param `\|invoke: Int\|`) -> `function parameter shadows declaration of 'invoke'`. | Name it `__rig_invoke` (emit.zig 3 sites; runtime.zig `Env.invoke` in `Closure.init` and `FnRef.of`, plus the 4 test envs). **Verified**: ee/ee4-ee8 run, suite green. | 0 | low |
| EMIT-2 | runtime.zig:877-884 (`index`) | Zig compile error | critical | `index` narrows a signed index with `@as(i64, i)` and assigns an unsigned one to `u64`, so an `I128`/`U128` index, which sema accepts, does not compile. Reached from `xs[i]` (array), `v[i]` (Vec `at/slot/constSlot`), `s[i]` (`rig.at`/`elemPtr`), `!b.swap(i, j)`, and `c[i]` on a `Cell[Vec]`. | b1.rig: `xs = [10, 20, 30]`, `i: I128 = 1`, `j: U128 = 2`, `print(xs[i], xs[j])` -> `bin/rig run` -> `runtime.zig:879:72: error: expected type 'i64', found 'i128'` and `:81: expected type 'u64', found 'u128'`. b4.rig (`!b.swap(i, j)`) same error via `swap`. | `const idx = std.math.cast(usize, i) orelse indexPanic(); if (idx >= count) indexPanic(); return idx;` (handles every width and `comptime_int`; negatives fail the cast). **Verified**: b1 prints `20 30` / `5` / `99`, b4 runs, `zig test src/runtime.zig` 20/20, suite green. | -4 | low |
| EMIT-3 | emit.zig:459, 483, 4738 (`Self`) | Zig compile error (name collision) | critical | A generic type is emitted as `return struct { const Self = @This(); ... }` and its methods spell the type `Self`. A module-level declaration named `Self` (sema accepts `fun Self` and `Self = 3`) makes every such use ambiguous. | gg.rig: `fun Self -> Int` + `struct W[T]` with `fun get(?self) -> Int` -> `bin/rig run` -> `error: ambiguous reference ... const Self = @This()`; gg2.rig (`Self = 3`) same. | Spell it `__rig_Self` (enterNominal, emitGenericHead, emitTypeTy). **Verified**: gg/gg2 print `3`; suite green. | 0 | low |
| EMIT-4 | emit.zig:2041, 2058, 2062, 2314, 2439 (`fresh("whole")`, `fresh("payload")`) | Zig compile error (name collision) | critical (unlikely in practice) | Match-arm captures are named `payload_N` / `whole_N`, outside the reserved namespace and never registered in `local_names`, so a user binding of that spelling in the arm shadows the capture. | mm.rig: `match <s` / `.c(_, k)` / `payload_1 = k + 1` -> `bin/rig run` -> `error: local constant 'payload_1' shadows capture from outer scope`. | `fresh("__rig_payload")`, `fresh("__rig_whole")`. **Verified**: mm.rig prints `3 2` / `drop 1`; suite green. | 0 | none |
| EMIT-5 | emit.zig:4107-4112 (`hoistReceiver`: `if (!contains(recv, &.{.call}) and !(writes and temporary)) return;`) | wrong output (evaluation order) | high | When a method call's arguments are hoisted (keyword arguments reordered, an owned argument before one that may leave, or a lent closure literal), a receiver *place with an index* is left in the call, so it is evaluated after the arguments. An argument that changes the index makes the call act on a different element. The unhoisted call (Zig's own order) evaluates the receiver first, so the same source means two things. | z8.rig: `cs = [C(n: 5), C(n: 6)]`, `k = 0`, `!cs[k].put(Vec(), bump(!k)!)` -> run -> `5 113 1` (cs[1] changed); expected `112 6 1`. Emitted: `const __rig_arg_2_1 = try bump(&k); ... cs[rig.index(k, 2)].put(...)`. z2.rig (kwargs `!cs[k].sub2(b: bump(!k), a: two())`) -> `5 106 1`; z3.rig (same call, positional, not hoisted) -> `105 6 1`. | Also hoist the receiver's address when it contains an index: `contains(recv, &.{ .call, .index })`. **Verified**: z2 -> `105 6 1`, z8 -> `112 6 1` (emits `const __rig_recv_2 = &cs[rig.index(k, 2)];` first); suite green. | 0 | low |
| EMIT-6 | runtime.zig:474-476 (`Box.__rig_print` writes its value with `top = false`) | print formatting | low | A boxed String prints quoted at the top level, unlike a shared handle or an optional. | cc1.rig: `print(Box("hi"), *"hi", o, "hi")` with `o: String? = "hi"` -> `"hi" hi hi hi`. | Treat `Box` in `writeValue` like `RcBox` (mark it, then `writeValue(w, value.value.*, top)`), and drop `Box.__rig_print`. | 0 | none |
| EMIT-7 | emit.zig:84-86 (`Local.scrutinee`), 140-141 + 146 (`Usage.views`), 871-880 (`consumeFlag` scrutinee branch), 1284-1292 (`emitDrop` `.none` branch), 2303, 2368, 2417, 5078-5083, 5132-5141 | dead code | low | The "a match payload views its scrutinee; moving it out consumes the scrutinee" machinery cannot run: sema rejects every move, drop, or tail-return of a payload out of `match m`, `match ?m`, `match !m` (catch-all bindings too), and the `match <m` paths reset `scrutinee` to null. | u3.rig (12 combinations: `take(<r)`, `-r`, `take2(<x)`, `-x` x 3 modes) all rejected (`cannot move r out of m: match m reads m`, `cannot move out of r: it is borrowed from m`); u4.rig (tail return) rejected. | Delete; `consumeFlag` becomes `return if (local.guard == .flag) local.flag else null;`. **Verified** removal: suite green. | -40 | low |
| EMIT-8 | emit.zig:942-945 (`emitStmt`: "A local read for nothing is discarded by address") | dead code | low | Sema rejects a bare name or borrow as a statement in every position. | u2.rig: `a` as last statement, in an `if`, a match arm, a loop body, a `defer`, a value block -> all `this expression does nothing as a statement`. | Delete. **Verified**. | -4 | none |
| EMIT-9 | emit.zig:4574-4595 | duplication | low | `emitClosureTy` and `emitFnRefTy` are the same function but for `rig.Closure(` vs `rig.FnRef(`. | code reading | One `emitCallableTy(comptime runtime_type: []const u8, f)`. | -10 | none |
| EMIT-10 | emit.zig:5307, 4647-4649, 3725-3729, 10-11; runtime.zig:875-876; docs/INTERNALS.md:905-908 | stale comments / docs | low | (1) `/// e without the borrow sigils around it.` is orphaned above `fieldIsPointee` (belongs to `unborrowed`, 5317). (2) `lambdaReturn`'s doc line sits on top of `lambdaYields`' doc, and `lambdaReturn` has none. (3) The `set`/`replace` Cell comment is above the Cell-Vec block; the code it describes is at 3754. (4) Header: "A binding is `const` unless reassigned, written through, or `*Self`" omits the other `var` causes (compile-time-known initializer, Cell holder, value with drop glue; 1074-1083). (5) runtime `index` comment describes the bitcast trick (goes with EMIT-2). (6) INTERNALS "Borrows": "A `?T` of plain data is a plain Zig value" contradicts the code (`readBorrowIsPtr`/`copiedBorrow`: only scalars and views are copied; `fun same(a: ?P, b: ?P)` with a plain 2-Int struct emits `a: *const P`); the runtime table's `ReadBorrow` row is the accurate one. | c1.rig emit: `pub fn same(a: *const P, b: *const P) bool`. | Move/fix the comments; restate the INTERNALS bullet as the `ReadBorrow` rule. | 0 | none |
| EMIT-11 | emit.zig:2825-2828 (`emitBorrowOf`), 2855-2864 (`emitDeref`), 2480-2482 (`emitOptionalHead`), generic `for x in xs` + `?x` | generated-code quality / cost | low | Round trips and copies that Debug builds pay and readers see: `rig.lend(&rig.elemPtr(xs, j).*)` (sort.rig), `rig.eql((&p).*, (&q).*)` for `?p == ?q` (c1.rig), `if ((slot).*)` (tree.rig); a generic loop `for x in xs` whose element is only lent copies each `T` and then lends the copy (`for (xs) \|x\| ... rig.lend(&x)`, sort.rig `map`); a guarded match on a generic `?self` re-copies the union with `rig.borrowed(Self, self)` for the test and every binding (nn.rig). | `bin/rig emit examples/sort.rig`, c1.rig, `examples/tree.rig`, nn.rig | Peel `&(e).*` in `emitAddressOf` when `e` already yields a pointer; capture `\|*x\|` when the element is only borrowed; bind the guarded subject once as a pointer. All optional; ReleaseSafe/Fast optimize these away. | -5 | low |
| EMIT-12 | runtime.zig: `Int`, `isStrongHandle`, `needsDrop`, `holdsCell`, `dropElement`, `Usage`, `usage`, `flush`, `Callback`, `writeValue`, `stack_reserve`, `stack_size` | trusted-code surface | low | `pub` but referenced by neither emitted code nor main.zig (only inside the runtime). The runtime is "trusted, kept small and reviewed". | `grep 'rig\.<name>' src/emit.zig src/main.zig` -> 0 hits each | Make them private. | 0 | none |
| EMIT-13 | emit.zig:617-640 (main); Zig start code | UX | low | An error escaping a fallible `sub main!` prints Zig's error return trace with paths into `~/.cache/rig/...`. | v4.rig: `sub main!` / `return E.bad if r.n > 0` -> `error: bad` then `/Users/.../.cache/rig/v4-.../__rig_main.zig:30:9 ... return E.bad;`. | Emit the body as `__rig_main` and a wrapper `main` that catches, prints `error: bad`, exits 1 (after `rig.finish`). | +8 | low |
| EMIT-14 | runtime.zig:1410-1807 | size | low | The runtime's unit tests (~400 of 1,807 lines, 22%) are written into every emitted package as `rig/runtime.zig`. Zig never analyzes them there, so it costs only bytes and reading time. | `wc -l` | Optional: move to `src/runtime_test.zig` (needs a few internals made `pub` or a test-only re-export). | 0 | low |

Other probes that passed (no finding): Box with drop glue, `?b`/`!b` lending, `<b.unbox()`, box in
generics; borrow-returning methods through `if`/`match` (`?Big`, `!Big`); generic types and
functions with owning `T` (per-instance rejection of copies); guarded matches in all three
modes incl. `match <call()` non-exhaustive, write-mode guard bindings, subject evaluated once;
joined `as` chains in `if`/`while`/value `if`, `while` with `?? break/continue` in condition
and step, labeled value loops as a function tail; wrapping ops and folding on `=!` constants,
128-bit limits, shift-range checks; plain enums with explicit values and conversions;
cross-module field and parameter defaults (`@import("lib.zig").limit`), cross-module generic
types/functions; `replace`/`swap`/`<s.b`; `Cell[Vec]` through borrows and handles; `Signal`
reentrant `set`; closures (stack, owned, lent, nested, in generics, `\|!s\|` of a write slice);
hoisted kwargs/owned-arg calls; modules named `std`, `rig`, `builtin`; Zig keywords as labels
and locals; raw builtins (all misuse rejected by sema); `rig test` (error, panic, names);
every example identical in Debug, `--release`, and `--release=fast` (hello: 428 KB
ReleaseSafe, vs 443 KB for a plain Zig hello).

Out of scope, seen in passing (front end): `x ?? continue :outer` and `f() catch break :outer`
do not parse (`unexpected ':'`); inside parentheses the message is self-contradictory:
`unexpected keyword 'continue'; expected 'return', 'break' or 'continue'` (k1.rig original,
line 13). SYNTAX.md:239 still says a call "as a statement also `f a`", but paren-free calls
are rejected (`print 3` -> "`print` is called with parentheses").

## Restrictions

| rule | where | serves North Star? | recommendation |
|---|---|---|---|
| A parameter or generic parameter may not share a module-level declaration's name ("use a different name") | sema (hh.rig, hh3-hh5) | Only indirectly: it dodges Zig's no-shadowing rule. The emitter already renames colliding locals (`zigNameFor`/`nameTaken`), but emits parameters and generic type parameters under their Rig names (`emitGenericHead`, `type_var`). | Relax (language question 1): route parameters and type parameters through `zigNameFor`. |
| Labeled jumps are not allowed as a `??` / `catch` fallback | grammar (oo.rig, oo2.rig) | No; the emitter lowers any jump in that position (`emitList` `.break/.continue` -> `emitStmt` -> `writeJumpLabel`). | Allow (language question 2); fix the contradictory message either way. |
| `.get(i)` on a Vec, array, slice, or String takes only `Int`; `x[i]` takes any integer type | sema (b1.rig line 12: `expected Int, got I128`); runtime `Vec.get`, `elementAt`, `vecGet` take `Int` | No; the runtime converts with `std.math.cast` anyway. | Accept any integer type (language question 3). |
| A field of borrow type is only rebound (`v.a = !z`); `v.a = 5` and `v.a += 1` on `a: !Int` are rejected, while `x = 5` on a local `x: !Int` writes through | sema (o1.rig: `expected !Int, got Int`; `+= requires a numeric target`) | Unclear; the two rules differ for the same type. | Language question 4. |
| A parameter default is a literal or module constant; `F32.max` is allowed but an alias limit (`Real.max`, `Small.min`) is rejected | sema (mod3) | Mostly (a default is re-spelled at each call site, across modules). The alias case is an inconsistency: `emitDefault` can write the folded limit like `intLimit` does. | Allow alias limits (language question 5); keep the rest. |
| Subscribing from inside a subscriber panics | runtime.zig:747 | Yes: `set` iterates `subs.items()`, which a push could reallocate. | Keep (documented), or queue the subscription as reentrant `set`s are. |
| `--release=fast` drops overflow/conversion checks | main.zig:67-69, documented in README/SPEC | Documented cost-model choice. | Keep. |

## LANGUAGE QUESTIONS

1. Should a parameter or generic parameter be allowed to share a module-level name (the emitter would rename it in Zig), as Rust and Python allow?
2. Should `e ?? continue :outer`, `e ?? break :outer`, and `f() catch break :outer` be accepted?
3. Should `x.get(i)` accept any integer type, as `x[i]` does?
4. Should `v.a = e` on a field of type `!T` write through the borrow (as `x = e` does for a local `x: !T`), with `v.a = !z` kept for rebinding, or should locals follow the field rule?
5. Should a parameter default accept a number type's limit through an alias (`Real.max`)?

## Biggest simplification opportunity

The emitter carries twelve implicit mode fields (`bare`, `ptr_tail`, `want_ptr`, `rt_names`,
`keep_comptime`, `literal_ty`, `place_chain`, `read_place`, `lent`, `unboxing`, `value_else`,
`redirect`: ~110 references and 27 save/restore sites) and re-derives ownership facts in its
own `Scan` pass (95 lines: `used`, `consumed`, and the dead `views`). Passing one explicit
`Ctx` value to `emitValue`/`emitPlace` (tail, want-pointer, read-only place, compile-time, literal
type) would make each position's context visible at the call and remove the save/restore
dance where the historical bugs (EM-1, the readThrough one-shot flag) came from. And since
`SymbolFlags` has 6 spare bits, typecheck/ownership can record `read` and `moved` per binding
(they already compute both: "assigned but never read", use-after-move), which deletes `Scan`
and `Usage` and makes the alive-flag decision exact. Together with EMIT-7/8/9 that is
roughly -200 lines of emit.zig with no change in output.
