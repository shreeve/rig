# Audit: emit, second half (src/emit.zig 5,900-11,957), frames, symbols (2026-11-04)

Phase 2 of the compiler revamp. Read only; nothing in the tree changed.

**Read, line by line:** `src/emit.zig` 5,840-11,957 (to the end, starting at
`bindOptionalView` so the range opens on a whole function), plus 1-120 and
330-620 for the `Emitter` fields; `src/frames.zig` 1-250 (all);
`src/symbols.zig` 1-95 (all). Also read where a finding led: `storage.zig`
70-110, 221-388, 1729; `typecheck.zig` 7790-7880, 11054-11110, 13100-13275,
13869-14107; `ownership.zig` 6150-6232; `tasks.zig` 2480-2516;
`runtime.zig` 4935-4975; `rig.zig` hidden leaves; `diag.zig` 47-55, 180.

**Base:** origin/main dd355f669 (phase 1 landed), `bin/rig` and
`bin/rig-oracle` of the rv-audit2 worktree. Probes in the session
scratchpad, run with `RIG_SANITIZE=1` and `RIG_OUT_DIR`, each also through
`bin/rig-oracle -v`. (One slip: importing `bench/check/guard.py` ran its
`main()`, whose `zig build` was a cached no-op; `bin/rig`'s timestamp did
not change.)

## Findings

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| X1 | emit.zig:9308-9315, 9127-9134; storage.zig:221-236, 377-388; typecheck.zig:14065 | NS2, NS1 (order) | critical | An actor call's handle is evaluated **after** its arguments whenever the arguments are hoisted (keyword order differs from parameter order, or an argument may leave after an owned one). The ownership checker walks the handle first, as written. `storage.hasSelf` reads `callParamsOf`, and `actorCall` records its `CallSite` without `has_self` (the handle "stands for self"), so `selfHold` decides nothing and `hoistSelf` holds nothing; emit then writes `rig.actorCall(<handle>, ...)` inside the call block after the `__rig_arg_N_i` temporaries. An argument that frees what the handle expression reads is a use of freed memory in safe Rig. The oracle abstains ("a method reached through a handle"). | P-X1a: `!pick(?hs, 0).add(b: consume(<hs), a: side("a", 2))` prints `consume 1`, `a`, `pick 1`, then `rig: use of freed memory` in `pick` (`hs.*.constSlot(i)`). P-X1b: `!pick(?hs, 0).add(b: side("b", 1), a: side("a", 2))` prints b, a, pick; so does the task form `(!pick(?hs, 0)).add(...)&`. Without hoisting the order is right. | `storage.heldSelf`: return the handle (`ir.Member.object(callee)`) for `isActorCall`, as it already does for select arms, so `decideSelfHold` holds it in its turn; emit's two actor branches then read it through `hoistedOf` as any self. Add both probes as cases (one `bomb`-free run under sanitize, one order). Check the sibling forms: `rig.actorSpawn`, `*Actor(x, mailbox:)`. | +4 | low: a hold the planner already makes for methods |
| X2 | typecheck.zig:14034-14107 (no `readLeaf(obj)`); emit.zig:9308-9315, 9127-9134 | NS2 (leak) | high | A handle made by a call and used as the self of a `?@` actor method, `mka(3).get()` or `pick(?hs, 0).get()&`, is never dropped: no temporary is recorded for it, so emit writes `rig.actorCall(rig.rt(mka(3)), ...)` with no slot, and the actor (its state and box) leaks. A `!@` call is fine (`lendTemp` records the write lend's slot), and so is every other method's made self (`readLeaf` at typecheck.zig:13272) and a Cell's. `actorCall` returns before the method path's `readLeaf`. `actorSpawn` clones the handle (tasks.zig:2514), so the caller's copy must be dropped. | P-X2: `print(mka(3).get())` → `memory leak detected: 1 allocation (144 bytes)`; `print((*Actor(Acc(total: 1))).get())` likewise; `t = pick(?hs, 0).get()&` → 176 bytes. | In `actorCall`, for `self_mode == .read` and a self that is no place, `try self.readLeaf(obj)`, as the method path does. Cases for the three forms. | +1 | none |
| X3 | emit.zig:6318-6327 (`writeModuleName`), 2245-2252 (`nameTaken`) | speed (quadratic) | high | Every module-level name written inside a type scans all the type's members (`srcText` of each `fun`/`sub` name), and every local declared inside one scans all its methods: O(methods x names). On generated objects of n methods, emit's cost over `rig check` grows 4x per doubling (500: 226M instructions, 1000: 850M, 2000: 3.27G, 4000: 12.9G; `rig emit` 0.59 s against `rig check` 0.09 s at 4000). On Trig (`Checker` has 3,244 methods), building to Zig with a stub `ZIG` takes 2.68 s against `check`'s 1.74 s (42.5G vs 27.4G instructions), and a `sample` of the emit phase puts 521 of its 592 samples in `writeModuleName` and 68 in `nameTaken`. | `bigN.rig` generator (an object with N methods each calling a module function); `sample` of `rig build` on Trig's sources (`tools/trig/main.rig` over `src/`). | One `StringHashMapUnmanaged(void)` of the nominal's method names (Rig names) built once when `self.nominal` is set, and the Zig names beside it for `nameTaken`; both checks become lookups. Measure Trig's build before and after (expected: most of the 0.95 s emit share). | +10 | none |
| X4 (V12) | emit.zig:7028-7055; runtime.zig:4955-4962 | diagnostics | low | A run-time shift amount at or past the width, or negative, panics with Zig's cast text, `integer does not fit in destination type` (`@shlExact(@as(u8, x), @intCast(@as(u64, @intCast(n))))`), not Rig's; the vector shifts' `laneAmount` the same. SPEC §4 says it panics (behavior right). | P-V12: `x: U8 = 1; n = side(9); print(x << n)` and `x >> n`, `y <<% n`. | `rig.shiftAmount(T, n)`: test `0 <= n < bits`, panic with the constant check's text (`shift amount `9` is out of range for `U8` (0..7)`); emit and `laneAmount` call it. | +12 | none |
| X5 | emit.zig:8190-8238 (`$plain`, `$name` of `$type(x)`), 8146-8162 (`$size($type(x))`); ownership walk of builtin args | NS1/NS4 | medium | `$type(x)` is written inside `@TypeOf`, which Zig never evaluates, but the checkers walk `x` as evaluated: `$size($type(<s))` is a move of `s` to the ownership checker (a later `print(s)` is "use after move") while the program never moves it, and `$size($type(side(1)))` never calls `side`. Nothing leaks (the drop flag stays armed), but the checker checks what is not emitted. SPEC "Builtins" says neither. | P-X5: `print($size($type(side(1))), $name($type(side(2))), $plain($type(side(3))))` prints `32 String false` and no `side`; adding `print($size($type(<s)))` then `print(s)` is rejected. | Owner's call: (a) SPEC says `$type(x)` does not evaluate `x`, and typecheck/ownership walk it as a type position (no use, no move); or (b) reject an operand with effects (a call, a move). Default (a): it is Zig's and costs nothing. | +6 | low |
| X6 | emit.zig:9273-9298, 9428-9465, 7757-7779, 7833-7838, 8582-8586, 9194, 6286, 9843, 11661, 11674, 11720 | NS4 | medium | review-ownership-emit §1b/§1c still hold in this range: emit picks lowerings by method name (`is_empty`, a Cell-of-List's `push/pop/clear/keep/get`, a Tasks' `wait_first`, a sequence's `get`, a Cell's `set/swap/compare_swap/add/sub`, `len`, `unbox`), recognizes `swap` and number conversions by text with no symbol, and tests `none` by text in five places beside `storage.isNoneLeaf`. Each agrees with typecheck today (dispatch facts are read first, so an API method of the same name wins: probes P-23). | grep at the lines given; all probes agree. | Typecheck records one `builtin_method` fact (an enum) where it resolves each of these calls, as `elemCallOf` already is for element methods; `emitCallPlain` switches on it. `swap`: one `storage.swapCall` read by ownership (6155) and emit. `none`: every site calls `Facts.isNoneLeaf`. Small and mechanical; not a rewrite. | -15 | low (emit-diff should be empty) |
| X7 | emit.zig:8389-8401, 9390-9402, 8365 | NS4, duplication | low | The option names and defaults of `*Actor.supervised(f, mailbox:, restarts:, per:)`, `task.supervise(f, restarts:, per:)`, and `*Actor(x)`'s mailbox (`64`, `-1`, `0`) live in emit as text, while typecheck owns the names (typecheck.zig:13900, 13977) and builds the parameters (`optionParams`). Two copies of one loop, too. Order is right (hoisting reorders: P-3). | P-3 prints per, restarts, 7 for `task.supervise(\|\| work()!, per: ..., restarts: ...)`. | Typecheck records the call's slots with defaults (`callSlotsOf`, `.default` entries) and emit writes them through `emitArgs`, as for any call. | -15 | low |
| X8 | emit.zig:9969-9972, facts.zig:924-926; emit.zig:6177-6179; 10186; 11478-11480; emit.zig:6-8; INTERNALS "Emit", Bindings (`sema.moves`) | dead code, stale comments | low | `Emitter.lentLiteral` and `Facts.lentLiteral` have no callers (storage calls its own); `erasedObject` takes `from` and discards it; a stray doc line `/// storage.keptInSlot.` sits above `emitSlotAddress`; `unsupported`'s doc comment is still orphaned above the "Units" banner (review §3); the file header still says facts come "from sema's facts table (`sema.zig`)"; INTERNALS still says bindings are `var` when "holding a value that moves (`sema.moves`)", which emit may not call. | grep | Delete the two functions and the parameter; move the doc comment; fix the header and INTERNALS. | -12 | none |
| X9 | emit.zig:7099-7124, 7175-7192, 7952-7970; 6870-6917 vs 10660-10698; 8942-8956 | duplication | low | The catch handler (binding with `catchBinding`; nameless with a fields slot, `dropFailure ... else unreachable`; nameless without) is written three times (value, statement, leaf address); the `cloneable` switch twice (`+x` and `\|+x\|`); `.order` and `.total_order` are one branch with two names. | read | One `writeCatchHandler(sexp, slot, result, how)`; one `writeClone(ty, operand writer)`. | -45 | low |
| X10 | emit.zig:11604-11607 | diagnostics | low | `unsupported` locates its node in `self.source`, the module's joined source, so an internal error in a directory module's second file names the wrong line and no file; `emitPanic` (10435-10445) uses `self.file.locate`. | read | Use `self.file.locate` and print the path. | +2 | none |
| X11 | emit.zig:11812-11830 (`sameNode`, `partKey`) | positions (priority 4) | low | A leaf is identified by its position alone, while rewrites place hidden leaves at real positions: `asMatch`'s discard at the pattern's start (rig.zig:3901), `bareFor`'s at `for` (5666), `iterWhile`'s at `key-1`, `key`, `key+2` (5644-5648). Every sentinel (`lending`, `keeping`, `lifting`, `failing`, ...) and `hoistedOf` compare through it. No probe found two such leaves meeting in one emit decision. | read | Compare `pos` and `id` (and `len`) for leaves. | +2 | none |
| X12 | emit.zig:556-572 vs 583, 2617 | cleanup | low | `deinit` frees neither `additions` nor `erased_slots`, both appended with `self.allocator`. | read | Free them. | +2 | none |
| X13 | frames.zig:131-155 | robustness | info | A Mach-O load command is read at `off + 64` after checking only `off + 8`, and `k * 80` is `u32` arithmetic: a truncated executable panics the compiler. It reads only the executable it just built. Both readers checked against real binaries: arm64 `big` 6,432 bytes (Mach-O), x86_64 cross-compiled 12,000 bytes through `__zig_probe_stack` (ELF). | harness over `frames.read` | Check `off + size <= bytes.len` and widen to `usize`. | +2 | none |
| X14 | symbols.zig:66 vs emit.zig:7001, 9840 | one spelling | info | `__rig_symbols.zig` spells each tag with `std.zig.fmtString`, emit writes `@"{s}"` raw. Symbol names are identifiers with `-` and `.` only (SYNTAX "Symbols"), so they never differ; one helper would keep them so. The rest of symbols.zig is sound: sorted, deduplicated, independent of module order. | read | One `writeSymbolTag`. | 0 | none |
| X15 | typecheck (outside the range) | diagnostics | low | Two messages met while probing: a `zip` over a chain says "is a `invalid`" (internal type name, article), for `src("d").take(1).zip(src("e").skip(2))`; a `catch \|e\|` handler that ends in `)` on its last line gets "a closure body below its bar list ends with `)`", though no closure is written. | P-15, P-5 | To the typecheck/front-end owners. | 0 | none |

No other accepted program failed. Probes that held, each under
`RIG_SANITIZE=1` and the oracle (accept/accept or abstaining): keyword
reordering with hoisted calls and errors with fields at every depth
(`f(s("abc"), g(n)!)! + f(s("x"), m)!`, `f(b: g(5)!, a: s("kw"))`); `catch`
with and without a binding as a `?@` self and inside a `?String` view's
statement; routed optional lifts of hoisted arguments, normal and
`RIG_STRICT_OPTIONALS=1`; ternary bindings (`a + b if pair(3) as a, b else
-1`, `and` joins); constructor field order; named `select` arms with
side-effecting channels and moved send values; chains (source, stage
arguments, and per-item calls in source order); API-object and witness
calls with a made self and reordered keywords (self first); Cell methods
on made handles; closure literals lent to calls that may keep them
(rejected); built-in element calls, `$variants`, `$name`, `wrap`,
`from_bits`, `from_text`, `push[T, e]`, `swap`; cross-module parameter
defaults in nested directory modules.

## review-ownership-emit §1, status in this range

| §1 item | status |
|---|---|
| a. "is this binding used" derived twice | **Resolved.** Emit's `Scan` is gone; `Facts.isUsed` is `sema.isUsed`, the same set `storage.Planner.isUsed` reads (storage.zig:1729). |
| b. built-ins by name in three passes | **Still true, agreeing.** `swap`: `ownership.isSwapBuiltin` (6155, no longer falling back to `find`), `emit.isSwapCall` (8582), `sema.swapsTwoPlaces`. `print`/`warn`: `ownership.isPrint` (6225) beside `storage.printCall` (89), which emit reads. `none`: X6. Fixable in a small change (X6). |
| c. lowering by method name | **Still true** (X6), at new lines; the detached `par.map` and `io.copy` comments are fixed. |
| d. pointer or copy in `emitBind`, e. `copiesSubject` | Outside this range. |
| f. emit's own type predicates | **Still true**: `comparesStructurally` 11350, `isScalarTy` 11380, `isPlainTy` 11305, `hasLen` 11293, `isStructLike` 11279, `isCellListTy` 11233, `loopElem` 11269. They decide spelling only; typecheck gates every `==` they lower (probe P-13: handles and functions rejected, optional enums, symbols, NaN, `Bool?` right). |

## Rules and restrictions met, with a judgment

| Rule (where stated) | Judgment |
|---|---|
| A parameter default is a literal, a constant, or a number type's limit; a field default also an empty or literal constructor (typecheck) | Keep: it is what lets `emitDefault` write a default in another module's file without evaluating anything there. |
| `[n of x]` copies `x`, so `x` must copy (SPEC) | Keep. |
| A fallible call is wrapped in `!` or `catch` (SPEC §15) | Keep: it is why every call that takes `__out` is given one (`fail_slot`). |
| A task on a temporary that owns a resource is rejected; a view of a temporary may not outlive its statement | Keep; the actor read path should drop its made handle as Cells and methods do (X2), not be rejected. |
| A closure literal lent to a call whose result may hold it is rejected | Keep: it is what makes `hoistClosure`'s environment, in the call's block, sound. |
| `==` is not defined for handles and functions | Keep. |
| A shift amount is below the bit count: constant rejected, run time panics (SPEC §4) | Keep; give the panic Rig's text (X4). |
| `$type(x)` only as the argument of `$size`, `$align`, `$name`, `$plain` (SPEC "Builtins") | Keep, and say that `x` is not evaluated (X5). |
| Symbols: names with `-` and `.`, `:a.text` is one symbol (SYNTAX) | Sound and documented; surprising once (probe P-33 printed `:abc.text`). No change. |

## The biggest simplification that is not a rewrite

`emitCallPlain` is still an ordered chain of name and fact tests, and the
two real bugs here (X1, X2) come from actor calls taking a path of their
own past the facts that every method call gets: the self hold, the
temporary's slot. Recording an actor call as a call with a self (the
handle in its turn, a made handle in its statement's slot) lets both of
its branches go through the ordinary method lowering with the runtime's
`actorCall`/`actorSpawn` as the callee, and a single `builtin_method` fact
from typecheck (X6), with option slots and defaults recorded as any call's
(X7), would turn the rest of the chain into one switch over recorded facts.
That removes every method-name comparison from emit, about 60 lines,
without a lowered IR.

## Probes (session scratchpad, `ae/`)

P-X1a (`p22.rig`, use of freed memory):

```text
obj Acc
  total: Int
  sub add(!@, a: Int, b: Int)
    @total += a * 10 + b
  fun get(?@) -> Int
    @total

fun side(s: ?String, n: Int) -> Int
  print(s)
  n

fun consume(hs: List[*Actor[Acc]]) -> Int
  print("consume", hs.len)
  hs.len

fun pick(hs: ?List[*Actor[Acc]], i: Int) -> *Actor[Acc]
  print("pick", hs.len)
  +hs[i]

sub main()
  hs = List[*Actor[Acc]]()
  !hs.push(*Actor(Acc(total: 0)))
  keep = +hs[0]
  !pick(?hs, 0).add(b: consume(<hs), a: side("a", 2))
  print(keep.get())
```

P-X2 (`p27.rig`, leak):

```text
obj Acc
  total: Int
  fun get(?@) -> Int
    @total

fun mka(n: Int) -> *Actor[Acc]
  *Actor(Acc(total: n))

sub main()
  print(mka(3).get())
```

P-V12 (`p1.rig`): `x: U8 = 1`, `n = side(9)`, `print(x << n)` panics
`integer does not fit in destination type`.

P-X5 (`p11.rig`): `print($size($type(side(1))), $name($type(side(2))),
$plain($type(side(3))))` prints `32 String false` and never calls `side`.

X3 generator: `obj Big` with N methods `fun mI(?@) -> Int  helper(@v) +
helper(I) + helper(@v * 2)`, and `rig check` and `rig emit` under
`/usr/bin/time -l`.
