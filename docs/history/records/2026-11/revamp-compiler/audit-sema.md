# Audit of src/sema.zig (2026-11-03)

Scope: `src/sema.zig` (17,379 lines) at revamp-c, base main a4e4ce6a8. Read: INTERNALS "Sema" through
"What crosses to a task", review-frontend.md (sema's parts), review-types.md where it touches sema,
weak-spots.md, the end of backlog.md. Probes ran with this worktree's `bin/rig` (and `bin/rig-oracle`,
built by `zig build oracle`) in `$TMPDIR/sa`. Nothing tracked was changed. Items the 10-31 review
settled or deferred (position-keyed facts, the god context, per-module type stores, `string_view` as a
kind, "is a view" as one fact, the four evaluators, quiet checks) are not raised again.

## Findings

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| M1 | sema.zig:11309-11316, 11474-11490 (`blockerIn`'s `.parameterized_nominal`, `fieldsBlock`) | accept-means-correct (crossing) | High | A user generic's fields are not walked at the instance. The type arguments are walked at the *outer* `how`, and a field's `T` is skipped ("a generic parameter in a field stands for an argument, which its instance checks"). So a field `r: ?T` never puts `T` under `.shares`. concurrency.md, "What may cross cores": `?T` sends only when `T` syncs, and `Task[T]` never syncs. `W[Task[Int]]` holding `?Task[Int]` goes to a task on another core. The same type without generics is rejected. The same hole lets `W[^{A + Sends}]` (no `Syncs`) be read from two tasks through `?T`. Oracle: accepts (it does not model crossing). | P1 below: `rig check` accepts and `RIG_SANITIZE=1 rig run` prints `1 5`. P1b (non-generic `obj H` with `r: ?Task[Int]`) is rejected. | Walk a user generic's fields with its arguments bound: keep a frame of params→args in `Walk`, as `deepCloneable`'s `CloneFrame` does, and at `.type_var` walk the argument at the field's `how`. Keep the argument pre-walk only for built-in generics. `taskParams` follows from the same walk. | +30 | medium: it may reject a Trig generic that holds `?T` of a Sends-only type (correctly). Run Trig's light gate. |
| M2 | sema.zig:8046 (`minBytesOf`, `else => 8`), 8076-8081 (`isAddress`) | accept-means-correct (sizes) | High | `minBytes` counts every read view as one pointer (8 bytes). A read view of a type `lendByValue` holds is a copy of the value: `?Simd[I64, 64]` is 512 bytes, `?I128` 16, `?[]T` 16, `?(Int?)` 16. Arrays of such views pass `max_value_bytes` and `max_frame_bytes` (frames use the same count), and emit lays them out at full size. `isAddress(.read_view)` is wrong the same way: no flag is counted for an optional of one. | P2: `[20000 of ?v]` with `v: Simd[I64, 64]` is accepted and emitted as `[20000]@Vector(64, i64)` (10 MB). The same array of `v` is rejected at 10,240,000 bytes. P2b: `[140000 of ?v]`: `--facts=frames` counts 1,121,024 bytes, and the run dies with "rig: stack overflow". | `.read_view => \|inner\| if (lendByValue(ctx, inner)) minBytesOf(inner) else 8`, and the same test in `isAddress`. One classifier: what a read view is, at run time, is `lendByValue`. | +6 | low: rejects only arrays that are now oversized. |
| M3 | sema.zig:7529 (`optionalOfHolder`: `isObject(ctx, inner)`) | accept-means-correct (Zig error) | High | `checkOptionalLoops` refuses `X?` in a type `X`'s own layout only when `X` is an object. A payload enum's optional is routed through `rig.Opt` as well (`optionalRouted` → `isCompound`, sema.zig:8774-8785), and it fails in Zig the same way. backlog.md lists objects, and the imported-generic case, but not enums. | P3: `enum Tree` with `node(kids: List[Tree?])` passes `rig check`, then Zig fails: "dependency loop with length 2 … `Tree` depends on `Tree__struct_891`". | Ask the same classifier emit uses: `isCompound` in place of `isObject` at 7529, and say "object or enum" in the message. | +2 | low: what it newly rejects never compiled. |
| M4 | sema.zig:14032-14071 (`sliceLend`), 14210-14220 (`lentElem`) vs 14078-14152 (`lendRows`) | wrong rejection; one classifier per fact | Medium | Three functions decide what a value lends of its elements, and they peel handles differently. `lendRows` lends `[]T` through `*T` and `*Frozen[T]` (CORE §4 table: `*T` lends "the read views of `T`"; `List[T]` lends `[]T`). `sliceLend` follows a handle only for a String, so `h[0..1]` of a `*List[Int]` (or `*Frozen[List]`) is rejected while `count(h)` is accepted. CORE says "a slice `x[a..b]` is the same lend". `lentElem` peels `.shared` but not `Frozen`, so generic inference of `[]T` from a `*Frozen[List[Int]]` fails while the concrete call passes. (The box case is already in weak-spots.) | P4: `count(?h[0..0])` gives "cannot slice a value of type `*List[Int]`". P4b: `total(f)` with `total[T: Num](xs: []T)` gives "expected `[]T`, got `*Frozen[List[Int]]`", while `count(f)` passes. | Derive both from the lend table: `lentElem` = the `elems` row of `lendRows`, with `frozenValue` at `.shared`. `sliceLend` takes the `handle` row (and `Frozen`) for arrays and Lists as it does for a String. | +10 | low |
| M5 | sema.zig:12481-12526 (`holdsByteSlice`) vs 9049-9089 (`objectUnprinted`) | wrong rejection; one classifier per fact | Medium | Two walks answer "what does `print` write of this value", and they disagree. `objectUnprinted` skips the fields of a type with its own `Print` (9081). `holdsByteSlice` walks them anyway, so `obj B: Print` holding `b: []U8` with `sub print(?@, out: !Printer)` cannot be printed. SPEC "Own meanings" (3542-3590): `print` calls the method "for the type and for the type as a part of another value". `printedTypeVars` uses the same walk, so it also adds `Requirement.printable` for a parameter that only a custom-printed field holds. | P5: `print(x)` gives "cannot print a `B`: the `[]U8` it holds would print as text". | One walk, "the parts `print` writes", with the Print skip and one wrapper set. Both questions become folds over it (see M6 and the simplification below). | -20 | low |
| M6 | sema.zig:9062 (`objectUnprinted` peels `.weak`) | wrong rejection | Low | A weak handle prints only whether its value lives (SPEC 4098, "a weak handle prints whether its value lives"). `holdsByteSlice` does not peel `.weak`, but `objectUnprinted` does, so printing `~Holder`, where `Holder` holds a `^{Shape}` with no `Print`, is rejected. | P6: `print(w)` with `w = ~h` gives "`^{Shape}` cannot be printed…". With a printable object, `print(~h)` gives `~(alive)`. | Drop `.weak` from 9062, or fold into M5's walk. | -1 | low |
| D1 | sema.zig:11165-11170 (`Blocker` has no `how`); typecheck.zig:21115-21120 | diagnostic | Low | The crossing message is worded from the *top-level* `how`, not from the `how` the blocker was reached under. A `Task` reached through `?Task` inside a moved object is reported as "a value that changes through handles that stay on this core". | P1b's message: "`H` holds `Task[Int]`, a value that changes through handles that stay on this core". | Record the `how` (and `local`) in `Blocker` where `blockerIn` returns it, and word the message from that. | +6 | none |
| S1 | resolve.zig:5425-5431 (`tableMethod`) → sema.zig:12006-12020 (`defaultOrigins`) and 12029-12044 (`viewReachOf`, no memo before `holds_final`) | check speed | Medium | Every module registers the four hash tables again. For about 40 methods it works out each signature's origins with fresh `TargetWalk` and `ReachWalk` walks, each in its own scratch arena (mmap/munmap). The answer is the same bit mask in every module. On the bench/check workload (59 modules), sampled 5 times: `registerBuiltins` is 19 of 252 samples (7.5%) and `registerTable` 12 (5%). On 1,501 near-empty modules, `registerTable` is 37-43 of 140 samples (28%), about 40 µs a module. This likely explains much of the ledger's "resolve" growth since guard.txt (7.3 ms there, 13.4 ms now). | `sample` of `rig check` on `$TMPDIR/sa/wl` (gen.py workload) and on `$TMPDIR/sa/empty` (1,501 modules) | Origins are module-independent bits, so compute each table method's once per process (a comptime table, or a cache on the module map) and copy it. Or set origins lazily on the first call of a table method. Re-measure with `bench/check/guard.py --rig`. | +20 | low (self-check builds can assert the cached bits equal fresh ones) |
| S2 | sema.zig:7561-7580 (`holdsByValue`, dedupe by `indexOfScalar`), called per `X?` field from 7529 | check speed (super-quadratic) | Low | `checkOptionalLoops` runs a BFS over the by-value graph for each optional field, and dedupes by a linear scan of the queue: O(N³) on a chain of objects each holding the previous one's optional. | `obj Oi` with `p: O(i-1)?`: N=500 gives 3.9 ms "resolve", N=1000 gives 18.4 ms, N=2000 gives 119 ms. A sample shows `mem.findScalar` under `optionalOfHolder` (sema.zig:7529) as the top of stack. | A bitset over symbols for `seen`, or one reverse-reachability pass per holder. The SCC order `Components` already computes would serve. | +5 | none |
| C1 | sema.zig: `formatApis` (1663), `setKeyOf` (8591), `setIn` (8643; `setInAt` stays, `subsetAt` calls it), `reachesString` (11499), `SemContext.recordNamedType` (4919) | dead code | Low | No caller in src/, tools/, or test/oracle/. | `grep -rw` over src/ test/oracle/ tools/ (1 hit each: the definition) | Delete. | -35 | none |
| C2 | sema.zig:7725 (`isBuiltinCallName`, test-only caller 16943) vs typecheck.zig:9531-9537 (`lookupQuiet == null`), ownership.zig:6081-6084 and 6151-6156 (`symbolOf == null`), emit.zig:8567-8570, rig.zig:3283 | one classifier per fact | Low | "This call is the built-in `print`, `warn`, or `swap`" is decided by text in five places. Typecheck asks a scope lookup, while ownership and emit ask whether a symbol was recorded. They agree only because typecheck records no symbol on the built-in path. Sema's own classifier is used only by a unit test. | lines cited | Record a fact once, where typecheck takes the built-in path (`builtinCallOf(callee)`), and have the others read it. Then delete `isBuiltinCallName` or make it the one classifier. | -5 | low |
| C3 | sema.zig:2458-2467 | stale comment | Low | `Decided`'s doc comment ("The `Question`s decided so far. Held behind a pointer…") is fused onto `TypeMemo`'s, and `Decided` (2497) has none. | lines cited | Move the three lines to `Decided`. | 0 | none |
| C4 | sema.zig:7535 (`walked.items.len < 64`) | silent cap | Low | `optionalOfHolder` stops walking generic instances past 64 with no diagnostic, so a deeper chain of `W[W[…[X]]]` is not checked and fails in Zig. The bound is a guard against cycles. | code | Report "too deep" when the cap is hit, or bound by `walked` dedupe alone (it already dedupes). | +3 | none |
| C5 | many walkers: `holdsByteSlice` 12501, `objectUnprinted` 9062, `objectUnownedIn` 9138, `taskIn` 11441, `nestsWriteView` 11026, `holdsCallable` 8296, `findHeapStacked` 8380, `handleAt` 8516, `reachedTypeVars` 12894, `reachesTypeVar` 12909, `setParamAsValue` 12930, `setParamUnlent` 12966 | duplication | Low | Each hand-writes its own wrapper set over `optional/read_view/write_view/shared/weak/range/callable/slot/fallible/array/slice/results/parameterized_nominal`. M5 and M6 are two divergences of this kind that matter. Others differ on `.range`, `.callable`, `.results`, and `.slot` without (found) effect. `TypeChildren` (7800) already is the structural visitor; the walkers do not use it. | grep of the arms | See the simplification below. | -150 | low |

## Probes

```text
# P1 (M1): accepted, runs, prints "1" "5"
obj W[T]
  r: ?T
fun work() -> Int
  5
fun peek(w: W[Task[Int]]) -> Int
  1
sub main()
  t = work()&
  w = W[Task[Int]](r: ?t)
  u = peek(<w)&
  print(>u)
  print(>t)

# P1b: the same with `obj H` / `r: ?Task[Int]` is rejected ("`<h` is given to a task: `H` holds `Task[Int]`, …")

# P2 / P2b (M2)
sub main()
  v = Simd[I64, 64].splat(7)
  a = [20000 of ?v]          # accepted; [20000 of v] is rejected at 10,240,000 bytes
  print(a[19999][3])
# with 140000: accepted, frames count 1,121,024 bytes, run: "rig: stack overflow"

# P3 (M3): rig check passes; zig: "dependency loop with length 2"
enum Tree
  leaf(n: Int)
  node(kids: List[Tree?])
sub main()
  k: List[Tree?] = List()
  !k.push(Tree.leaf(n: 1))
  t = Tree.node(kids: <k)
  match t
    .node(kids) => print(kids.len)
    .leaf(n) => print(n)

# P4 / P4b (M4)
fun count(xs: []Int) -> Int
  xs.len
fun total[T: Num](xs: []T) -> Int
  xs.len
sub main()
  h = *List[Int]()
  print(count(h), count(?h[0..0]))   # count(h) passes; the slice: "cannot slice a value of type `*List[Int]`"
  v: List[Int] = List()
  f = *Frozen(<v)
  print(count(f), total(f))          # total(f): "expected `[]T`, got `*Frozen[List[Int]]`"

# P5 (M5): "cannot print a `B`: the `[]U8` it holds would print as text"
obj B: Print
  b: []U8
  sub print(?@, out: !Printer)
    !out.text("B")
sub main()
  arr: [2]U8 = [1, 2]
  x = B(b: ?arr[..])
  print(x)

# P6 (M6): "`^{Shape}` cannot be printed"; print(~h) of a printable H gives "~(alive)"
api Shape
  fun area(?@) -> Int
obj Sq: Shape
  s: Int
  fun area(?@) -> Int
    @s * @s
obj Holder
  sh: ^{Shape}
sub main()
  h = *Holder(sh: ^Sq(s: 2))
  w = ~h
  print(w)
```

Probed and found sound: generic substitution of `?T` at `T = String` and `T = ?String` (fields,
payloads, `from` results); infinite types through imported generics and payload generics; instance
sizes through imported generics; write views through aliases and inference; `==`/hash for a type
with its own `Eq` holding a function value; error-set ambiguity for a bare `.name`; constant folding
of `%`, `/`, `<<` against runtime (same answers and panics); callable views in fields.

## Stated rules and restrictions in sema

| Rule or restriction | Where | Judgment |
|---|---|---|
| A value takes at most 8 MiB (`max_value_bytes`), a frame 13 MiB | sema.zig:150, 167 | Keep. Fix the read-view undercount (M2), or the limit is not what it says. |
| A value nests at most 1,000 levels by value | sema.zig:158 | Keep (Zig's own stack). |
| An alias nests at most 200 deep (`max_alias_height`) | sema.zig:7086 | Keep. |
| `T!` stands only as a result or `Task[T!]` | resolve, via `misplaced` homes | Keep. |
| A write view is never in a field, element, type argument, view, or handle (Core §5) | `writeViewMisplaced` 11002 | Keep. `nestsWriteView` does not look inside `.results`, but results stand only where a write view may. |
| A Cell only behind `*` (Core sentence 9); an API object is unsized; `Frozen` only behind `*` | `misplaced` 10968 | Keep. |
| A callable view only as a parameter, local, or result | resolve 3226, `holdsCallable` | Keep. |
| `X?` may not appear in `X`'s own layout (`checkOptionalLoops`) | 7502 | Keep as a restriction until backlog's lazy layout is measured. Extend it to payload enums (M3). Report rather than cap at 64 instances (C4). |
| A value holding `[]U8` cannot be printed | `holdsByteSlice` | Keep, but not through a type that prints itself (M5) or a weak handle. |
| Generic instances nest at most 24 deep | `deepInstance` 6370 | Keep. |
| A crossing type parameter is decided per instance | `blockerIn` | Keep the rule. The implementation must walk fields at the instance (M1). |
| Slicing goes through a String's handles but not a List's | `sliceLend` | Lift. CORE §4 lends `[]T` through `*T` (M4). Boxes are already listed in weak-spots. |
| An unread local is a lint | `checkUnreadLocals` 6283 | Keep. |

## The biggest simplification that is not a rewrite

`TypeChildren` (sema.zig:7800) already enumerates a type's children. Give it a second output, *how*
each child is held: by value, through a read view, through a write view, behind a handle, in heap
memory (a List, box, or table), or as a type argument bound to a declaration's fields (with the
params→args frame M1 needs). Then rewrite the dozen hand-rolled walkers in C5 as small folds over
that one iterator, with their per-question choices stated once as data (for example "print does not
enter `.weak`; skips fields of a type with its own `Print`"). That removes the class behind M1, M5,
and M6 (each a walker that chose its wrapper set or its generic-field handling locally), lets a new
`Type` variant be classified once instead of in about a dozen `else =>` arms, and is local to
sema.zig: every caller keeps its function name and signature. Estimated at 150 fewer lines, with
the self-check build asserting old and new answers equal over the suite before the old walkers go.
