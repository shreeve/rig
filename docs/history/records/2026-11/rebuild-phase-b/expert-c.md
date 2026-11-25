# Phase B, expert C: the compiler Rig should have been

Lens: the back end and the boundary with the runtime. The whole design is
covered, the back end most deeply. Source read: `revamp-base`
(645996606), read-only, in `~/Data/Code/worktrees/rig/revamp-base-ro`.
Every `file:line` below is at that commit. Probes ran with the cached
baseline `rig` on small programs in a scratch directory; no suite or
benchmark ran.

The short version:

1. **One lowered IR (LIR), structured, with storage as data.** Every
   function body is lowered once, after typecheck, into structured
   regions, ordered operations, explicit storage (vars), and nested pure
   or left-to-right expression trees. The storage plan, the proofs'
   units, the ownership checker's model of evaluation, frame accounting,
   and emit's ordering logic are all the same thing today, written four
   times; in the ideal they are one lowering, and every later pass reads
   its output.
2. **Emit becomes a printer.** The Zig backend prints LIR and the type
   table's representation facts. It decides nothing, because it is
   handed no tree to decide from. A future LLVM backend reads the same
   LIR.
3. **The runtime boundary is a closed list.** Emitted code reaches the
   runtime through one enumerated face and one config record; every
   type the compiler classifies carries its classification to the
   runtime as a marker, so the runtime's reflective mirrors of the
   compiler's classifiers (`needsDrop`, `fillsWithZeros`, `ReadView`)
   become compositions of markers rather than second classifiers.

---

## 1. Today, as found

### 1.1 Sizes

`wc -l src/*.zig` is 140,078 lines; std is 8,384 lines of Rig and 10,361
of Zig shims and tables. The back end and the runtime:

| File | Lines | Tests in file | Doc + comment lines | Role |
|---|---:|---:|---:|---|
| `src/emit.zig` | 12,537 | 109 | 2,779 | Zig code generation |
| `src/facts.zig` | 1,655 | 363 | 325 | emit's read-only view of sema and storage |
| `src/storage.zig` | 2,774 | 8 | 681 | the storage plan, the recorded decisions |
| `src/proofs.zig` | 2,930 | | | proven checks, by units |
| `src/inlining.zig`, `returns.zig`, `units.zig`, `symbols.zig` | 1,578 / 146 / 103 / 95 | | | program-wide facts after checking |
| `src/frames.zig`, `bolt.zig`, `pgo.zig` | 516 / 704 / 347 | 40 | | reading and relaying out the built executable |
| `src/runtime.zig` | 12,333 | 1,406 | 2,922 | the runtime, written beside each program |
| `src/sched.zig` | 11,482 | 3,719 | 2,852 | fibers, workers, pollers, timers, the pool |
| `src/tasks.zig` | 3,367 | 141 | 847 | tasks, sets, `par`, actors, channels, `select` |
| `src/alloc.zig` | 4,854 | 1,466 | 1,276 | the release allocator |
| `src/ordered.zig`, `unordered.zig` | 1,410 / 1,319 | 147 / 179 | | the tables behind `Map`/`Set`, `HashMap`/`HashSet` |
| `src/net.zig`, `table.zig`, `split.zig` | 2,577 / 325 / 345 | | | sockets and HTTP, `Table[T, n]`, split builds |
| `src/fastmap.zig` | 153 | 24 | | the compiler's hash maps |

Test and comment counts are from an `awk` over `^test "` blocks and
`//`/`///` lines; the runtime's code proper is about 8,000 lines of
`runtime.zig`, 4,900 of `sched.zig`, 2,400 of `tasks.zig`, and 2,100 of
`alloc.zig`.

### 1.2 What reads what

```text
modules.check (modules.zig:862)
  sema.check (modules.zig:883) ── resolve, typecheck, cteval, storage.plan (sema step 8)
  while typecheck found iterator loops, byte literals, chains, groups, spreads:
      rewrite the tree (Parser.desugar*), sema.check again        (modules.zig:893-901)
  ownership.Checker (modules.zig:913) ── reads sema facts + a few storage facts
      writes back: plain_reqs, old_nones into sema                (modules.zig:934-939)
  proofs.check (modules.zig:945) ── writes Proven per node into sema
program-wide: inlining.decide, returns.decide, storage.decideWords,
              units.decide, symbols.collect, text tables
main.emitPackage (main.zig:2205)
  per module: Emitter.init(..., Facts.of(m.sema)) (main.zig:2233), 12 mode
              settings (2235-2244), em.emit(m.ir) (2248),
              proofs.checkUnitOrder(trace) re-walks the units (2249-2255)
  root flags appended as text (2256-2260); map_trace rewrites emitted
              text (2283-2290); error glue, symbols file (2306-2328)
  runtime files appended verbatim (2209-2219)
```

- Emit imports only `parser`, `rig`, `facts`, `diag`, `nametable`
  (emit.zig:31-38) and walks the semantic IR (`Sexp`). `facts.zig`
  imports `sema`, `storage`, and `resolve` (facts.zig:31-35) and
  offers 235 `pub fn`s, of which a large share forward to `sema.*` or
  `storage.*` (311 references to the two modules in the file). The
  boundary holds at the import level, enforced by a unit test that reads
  `emit.zig` with Zig's tokenizer (INTERNALS.md:4726-4738), not at the
  decision level: audit E5 (records 2026-11/revamp-compiler/
  audit-storage-emit.md) lists `Facts` methods that still run a
  classifier when emit asks.
- sema's fact table is 78 fields (`sema.Facts`, sema.zig:1915), mostly
  `FastMap(NodeKey, …)` or position-keyed maps (sema.zig:1917-1962);
  `SemContext` has 165 fields (sema.zig:4281-6574). Leaves are keyed by
  source position, list nodes by node id (INTERNALS.md:1772-1777,
  1866-1871).
- The storage plan records 36 decision questions (`sema.Question`,
  sema.zig:2505) on first ask, forces them with a walk
  (`storage.plan`, storage.zig:1635), and answers each again at the end
  to catch two passes acting differently (`verifyDecisions`,
  storage.zig:1615); it is the largest pass of `rig check` on
  bench/check's workload (26.5 of 101.4 ms, bench/check/guard.txt).
- Storage has 30-odd kinds (`sema.StorageKind`, sema.zig:2339-2449),
  each named in emit through one function, `hiddenStorage`
  (emit.zig:2390), and Zig's own temporaries through `zigTemporary`
  (emit.zig:2443). This is the seed of a var table, already built.
- Ownership writes facts emit reads: `old_nones` (assignments whose old
  value is `none` and drop nothing, sema.zig:2055-2056, recorded at
  modules.zig:936-939). The checker is not only a judge; it is a
  producer of lowering facts.

### 1.3 Emit's shape

- **Mode state.** `Emitter` has about 70 fields (emit.zig:431-660),
  among them about 20 dynamic-scope flags (`bare`, `ptr_tail`, `use`,
  `want_ptr`, `rt_names`, `keep_comptime`, `literal_ty`, `place_chain`,
  `read_place`, `subject_path`, `error_codes`, `fail_slot`, …) and the
  re-entrance sentinels `viewing`, `failing`, `widening`, `splatting`,
  `durationing`, `erasing_box`, `keeping`, `lifting`. There are 70
  `defer self.X = saved` restores. `emitValue` (emit.zig:6054) applies
  each coercion by setting a sentinel to the node, writing a prefix,
  calling itself on the same node, and letting the sentinel stop the
  second application (emit.zig:6061-6110). That is a missing coercion
  layer.
- **Text pasting.** Emit writes a sub-expression into a scratch buffer
  and pastes its text where it is needed (`emitObjectCall`,
  emit.zig:1758-1771; `MatchInfo.reread`, review-ownership-emit §2d).
  Zig text is its only intermediate form.
- **The call chain.** `emitCall` (emit.zig:9343) then `emitCallArgs`
  (emit.zig:9524, 276 lines) is an ordered chain of fact tests:
  `printCall`, `stringCall`, `swapCallOf`, numeric conversion by name
  text (9534), alias callees, variant literals, closures, `dispatchOf`,
  constructors by symbol, function values, `builtinCallOf`,
  `taskJoinOf`, `isActorCall`, `isSelect`, `selectArmOf`, `isHttpServe`,
  `isReduceCall`, `isIoCopy`, `isSuperviseCall`, `isIsolateCall`,
  `parCallOf` (9530-9760). Each std form got its own fact and branch;
  each runtime entry its own string.
- **Address producers.** `emitAddressOf` (7414), `emitLeafPtr` (8158),
  `emitWriteViewPtr` (6910), `emitSubjectPtr` (2819), `emitSelfAddress`
  (1812), `emitCellPtr` (9849), `emitCellAddress` (9870),
  `emitHeldAddress` (9885), `emitSlotAddress` (10620). weak-spots.md
  ("Addresses of Zig rvalues") names two kinds of address no storage
  fact covers and asks for a structural chokepoint.
- **Emit's own type predicates** remain (`comparesStructurally`,
  `isPlainTy`, `isScalarTy`, … audit-emit X6 and review §1f), and 129
  direct `self.facts.types.get(` reads.
- **Duplicate models.** Emit enters and leaves the proof pass's units
  (emit.zig:11995-12127) so that a self-checking build can assert, after
  the fact, that it wrote what proofs walked (main.zig:2246-2255). The
  storage plan, the ownership checker, proofs, and emit each walk the
  same `Sexp` with per-construct code (review-ownership-emit.md §"Three
  walks of one tree").
- **What is solid** and carries over unchanged: `rig.writeZigIdent`,
  every hidden location named through one function, `need`/
  `unsupported` (an absent decision is an internal error), drop guards
  as a `defer` with a flag, `rig.Opt` with niches and the one-store
  `pack`, `ReadView(T)` for generics, error glue, witnesses, the site
  marks for failure traces (emit.zig:71-103), split builds' cut
  prologue (`emitCut`, emit.zig:2083).

### 1.4 The runtime's interface to compiled code

- **Files written verbatim.** Nine runtime files are embedded with
  `@embedFile` (emit.zig:49, 106-120; main.zig:35) and written into
  every package (main.zig:2209-2219).
- **The face.** Emit spells 226 distinct `rig.*` names inside string
  literals (a grep of quoted `rig.` names in emit.zig). Nothing lists
  them in one place; `test/cli/preempt_calls.txt` lists only the calls
  out of `rig_text` (scheduler.md "Preemption").
- **Config by root declarations.** The program tells the runtime what
  it is through `pub const __rig_*` declarations in the root, read with
  `@hasDecl(root, …)`: `__rig_tasks`, `__rig_task_guard`,
  `__rig_dense_stride`, `__rig_start_early`, `__rig_preempt` (probe
  output of `f(x)&`), and the env-driven `__rig_leak_trace`,
  `__rig_sanitize`, `__rig_verify_proofs`, `__rig_heap_profile`,
  `__rig_map_trace`, `__rig_since_start`, `__rig_memory`,
  `__rig_run_started` (INTERNALS.md:191-199, 5854). main.zig appends
  them as text (main.zig:2256-2260).
- **Vocabulary that exists for emit's shape.** `rt` (a run-time
  identity that stops Zig folding, runtime.zig:1968), `keep` (hold a
  temporary in its statement's slot from inside an expression,
  runtime.zig:1928), `take` (runtime.zig:1948), `noneAt` (a mutable
  pointer to a static `none`, runtime.zig:1939), `copiedOut`
  (runtime.zig:1785), `someViewed`/`someViewedPtr` (runtime.zig:1750,
  1762), `poison` (runtime.zig:1769), `discard`/`discardAt`
  (runtime.zig:2996, 3005), the `Proven` and `If` twins of every checked
  operation (`atProven`, `elemPtrProven`, `atIf`, `elemPtrIf`, `addIf`,
  `addProven`, `swapProven`, `simdReadProven`, `simdWriteProven`,
  `readIntProven`, `writeIntProven`: runtime.zig:5108-5166, 5402, 5615,
  5676, 6397-6408), the duration twins (`durationInt`/`Float` and their
  `Clamp`/`Try` forms, INTERNALS.md:1666), and the `*Into` waits that
  take an error slot (tasks.zig:671, 1193, 1238, 1265, 1325, 1564, 1620,
  2253).
- **Mirrored classifiers.** Because Zig instantiates Rig's generics,
  the runtime decides again, by reflection, facts the compiler decided:
  `needsDrop` mirrors `typeHasDropGlue` (runtime.zig:1215; the header of
  table.zig:6-7 says so), `fillsWithZeros` mirrors `sema.tableFill`
  (table.zig:63-67, sema.zig:16402), `ReadView` mirrors
  `sema.viewByValue` (runtime.zig:1248), `Opt` mirrors
  `sema.optionalRouted`, and `typeName` mirrors the type printer
  through markers (runtime.zig:4403). The reflective walkers
  `dropElement`, `eql`, `hashAs`, `cloneValue`, `writeValue`
  (runtime.zig:1808, 1991, 2267, 2921, and Output) each traverse
  `@typeInfo` on their own. review-ownership-emit §4.5 calls drop glue
  "two derivations of this type needs cleanup".
- **Split builds.** Each runtime global is a `split.cell`
  (split.zig:30) and each thread-local a slot of unit 0's block
  (split.zig:46, list at 59-70), because every unit compiles the
  runtime. Release builds are one unit (Split builds record, 7.5-9.4%
  slower split).
- **Compiler and runtime already share code.** `nametable.zig` builds
  the table the runtime's `NameTable` reads (nametable.zig:1-9,
  runtime.zig:4971); `resolve.zig` imports the runtime for `Feature`
  (resolve.zig:26); a sema test checks the compiler's prediction of
  `runtime.Mask(n)`'s size against the runtime (sema.zig:18771-18776).
  The compiler's maps are `std.HashMapUnmanaged` with a multiply hash
  (fastmap.zig:10-12); the runtime's tables are Rig's own boost-FOA and
  ordered designs, which depend on the runtime for allocation, `hash`,
  and `eql` (unordered.zig:39, 330, 347, 422; ordered.zig:43, 228-238).
- **Text patching of output.** `RIG_MAP_TRACE` rewrites the Zig emitted
  for std/prelude.rig (`map_trace.instrument`, main.zig:2283-2290), a
  layer over emit's text.

### 1.5 Where today's design costs

The 2026-10-31 rewrite review (records 2026-10/compiler-review/) and
the 2026-11-04 audits found the same structural causes independently;
in my reading, at revamp-base, they still hold:

1. No lowered IR between the checked tree and Zig text.
2. Facts keyed by position, node id, or address, in many hash maps.
3. Context in mutable state (`SemContext`, `Emitter`'s mode flags).
4. Library knowledge wired into the compiler (typecheck's std forms;
   emit's call chain).
5. Two classifiers of one fact across the compiler/runtime boundary.

The bugs the audits found in the back end are of one class: "a part of
a construct that one walk models and another does not" (audit E1, E2,
X1, X2; weak-spots' statement temporaries, payload views, Zig rvalue
addresses, evaluation order).

---

## 2. The ideal pipeline

```text
source ─► lex/parse (Nexus) ─► syntax tree (keeps parentheses, bounds, ids for every node and leaf)
        ─► resolve (program-wide type table, symbols, declarations, groups expanded)
        ─► typecheck (bidirectional) ─► typed tree: types + elaborations as nodes
        ─► lower ─► LIR (per function: vars, regions, ops, expression trees)
        ─► ownership (dataflow over LIR)      ┐ readers of LIR;
        ─► proofs (writes `proven` into checks)┘ neither rewrites it
        ─► program-wide: inlining, never-returns, word-held, frames,
                         units, symbols, text tables, error glue plan
        ─► backend: Zig printer (today) │ LLVM (December 2026)
        ─► zig build-exe / build-obj ─► frames warning, BOLT, PGO
```

### 2.1 The passes

1. **Lex and parse.** Nexus-generated, as today. The grammar keeps
   parentheses and how a handle's suffix groups, which removes the
   parser wrapper's remaining side tables (compiler-review/
   ir-tags-deferred.md). Every node gets an id, leaves included (an
   index of leaves built once by the wrapper if Nexus cannot number
   them), so no fact is keyed by position and no hidden leaf needs an
   invented one.
2. **Resolve.** One type table for the program, not one per module
   with proxies (rewrite-review finding 2). Groups and spreads, which
   are declaration shapes, expand here, so no signature is rewritten
   after typecheck.
3. **Typecheck.** As today's synth/check core, which carries over. Its
   output is the typed tree: every expression's type, its symbol, and
   each coercion it inserts (lift, splat, code widening, erasure, view
   rows, duration, copy out) as an explicit node in the typed tree, not
   a side-table entry emit rediscovers by sentinel. It also records the
   type-directed desugarings it finds (a `for` over an iterator, a byte
   literal, a chain) as typed facts, which the lowering expands; it
   rewrites no tree.
4. **Lower.** New, and the centre of the design. One walk per function
   body turns the typed tree into LIR (section 5): every hidden storage
   location a var with its kind, hold, and life; every statement
   temporary a var dropped at its statement's end; the evaluation order
   written out; every drop, move, view, clone, and coercion an
   operation; every check an operation carrying its proof slot; every
   yield point an operation. It absorbs today's `storage.plan`
   (storage.zig:1635), typecheck's temporary and header recording
   (`recordTempDrop`, `rejectHeaderCopy`, INTERNALS.md:2035-2037), the
   proofs' units (proofs.zig:38-49), and emit's ordering (`hoistsArgs`,
   `emitHoistedCall`, `SetOrder`). The oracle's `test/oracle/lower.zig`
   (4,972 lines) does this for a subset already, with evaluation order
   written out (lower.zig:1-15).
5. **Ownership.** Dataflow over LIR, the oracle's model
   (`test/oracle/core.zig`, `flow.zig`), with today's checker's state
   (loans on field paths, the undo trail, the loop fixpoint, origins),
   which the rewrite review says to carry over. It walks exactly what is
   emitted, because the backend prints the same LIR: AGENTS.md's "the
   checker checks exactly what is emitted" holds by construction. It
   records nothing emit reads. `old_nones` (a store whose old value the
   dataflow knows is `none`, so it drops nothing) becomes the store op's
   `drops_old` flag; whether the lowering can decide it with a small
   flow of its own or must ask the checker's result is unknown until
   built.
6. **Proofs.** The same facts and rules as today, over LIR ops; a unit
   is an op. They fill each check op's `proven` set. The emit-side
   unit assertion (emit.zig:11995-12127, main.zig:2246-2255) has nothing
   left to assert.
7. **Program-wide facts.** On LIR: inlining (sizes are op counts),
   never-returns (divergence is a property of a region), word-held
   objects, frame accounts (a frame owner's slots are its vars and
   the materialized expression temporaries), split units (sizes from
   LIR), symbols, `from_text` tables, and the error glue plan.
8. **Backend.** The Zig printer prints LIR and type representations.
   It holds no tree and asks no classifier.
9. **Build and after.** Unchanged: `zig build-exe` (or `build-obj` per
   unit), then `frames.zig`, `bolt.zig`, `pgo.zig` on the executable.

### 2.2 Why this order

- Ownership needs the evaluation order, the storage, and the drops; so
  it must run after they are decided, and they must be decided in a
  form it can walk. Today that form is the tree plus 36 memoized
  questions; in the ideal it is LIR.
- Proofs need the order too (units) and the ownership verdict
  (proofs run on accepted code, modules.zig:943-946); after ownership on
  LIR is natural.
- The program-wide facts need every module lowered and checked:
  inlining's frame limits and the frame accounts count the slots Zig
  writes, which LIR names.
- The backend runs last and only prints.

### 2.3 Does sema need to run twice?

No. It runs twice because typecheck finds type-directed desugarings
(iterator loops, byte literals, chains, groups, spreads), the tree is
rewritten, and the module is checked again so every later pass sees
the desugared form (modules.zig:883-901). In the ideal, groups and
spreads expand in resolve (they are declaration shapes); the other
three are recorded by typecheck as typed facts (`IterLoop{next, item}`,
`ByteLiteral{bytes}`, `Chain{stages}`) and expanded by the lowering,
which every later pass reads. Nothing is checked twice, and today's
second-check cost (a full sema of every module that uses one of these,
which in Trig is most) goes away. The one thing the second check gives
today, that the ownership checker walks the desugared loop, the LIR
gives by construction.

---

## 3. Facts: what emit must be handed so it decides nothing

Emit is handed, and only handed:

**A. The LIR of every function** (section 5), which carries:

- the var table: for each var its type, its name class (a user
  binding, or a hidden kind with an id: today's `StorageKind`), `by`
  (owned, copy, pointer, buffer), `life`, its drop (`ResourceKind`, or
  none), its alive flag, whether Zig must see it as `var`, and whether
  the sanitizer poisons it;
- regions and ops in order, with jump targets resolved (`JumpDest`);
- every coercion as a node (`lift` with the optional it packs into,
  `splat` with the vector, `widen` to an `ErrorValue`, `view` with its
  rows, `erase` to an API object, `duration` with its unit and how,
  `copy_out`);
- every call with its resolved target and kind (`direct`, `witness`,
  `table` through an API object, `closure`, `fn_ref`, `actor`,
  `intrinsic(id)`), its error slot, and whether its result crosses the
  inline boundary (`rt` or `var_in_place`, today's `callsInlined`
  branch, emit.zig:9372-9395);
- every check with its kind, its operands, its `proven` set, and its
  flag (today's `Proven`, `ProvenIf`);
- every `match` as one plan (subject mode, hold, rereads, selection,
  per-binding capture), not seven flags (review §2d);
- every loop with its step point, fold, and consumption.

**B. The type table's representation facts,** one record per type,
computed once where the type is interned:

| Fact | Today |
|---|---|
| Zig spelling class (scalar, pointer view, `ReadView`, `Opt`, niche, flag-none, word-held packed, tagged union, error value) | `viewHeldAsPointer`, `optionalRouted`, `wordBits`, `decideWords`, `isErrorValueForm`, emit's own `isScalarTy` etc. |
| drop glue kind (none, user `drop`, parts, handle, box, weak) | `typeHasDropGlue`, `resourceKind`, runtime `needsDrop` |
| clone kind | `cloneable` |
| `==`, hash, order kind (bytes, structural, tag, by `@intFromEnum`) | emit's `comparesStructurally`, runtime `eql`, `compare` |
| table fill (zeros or made) | `sema.tableFill`, runtime `fillsWithZeros` |
| name parts for `$name` and print | `formatTypeMarked`, `__rig_name` |
| size and alignment as Rig predicts them | `checkTypeSizes`, `minBytes` |

**C. Module-level declarations,** lowered too: types with their fields
and their glue, witnesses and API tables, error sets, constants, the
test table, `extern zig` shims with the exact Zig type each must have
(`expectShim`), text tables.

**D. Program-wide facts:** inlined, called, rarely, never-returns,
unit owner (split builds), symbol numbering, word-held types,
`from_text` tables, the error glue plan, and the **runtime config**:
one record (tasks, task guard, dense stride, start early, preempt,
leak trace, sanitize, verify proofs, heap profile, map trace, since
start, memory, run started), which the printer writes as one
declaration (section 4.3).

What emit is no longer handed: the tree (`Sexp`), the source text
(except for the site marks' places, which an op carries as a position),
`SemContext`, or any classifier. The facts boundary test becomes a type
fact: the printer's entry point takes `*const lir.Module` and
`*const types.Table`, and nothing else is in scope.

### 3.1 Can facts, storage, and proofs share one recorder?

Yes, and further: two of the three stop being side tables.

- **Typed-tree facts** (type, symbol, scope, instance, call slots,
  generic call, view rows) go in one node-indexed store: a dense array
  per fact kind, indexed by node id, written by the pass that owns the
  fact and sealed when that pass ends (a `Sealed(T)` view each later
  pass is given, so a write after the seal does not compile). This
  replaces the 78 fields of `sema.Facts` (sema.zig:1915) and most of
  the 165 `FastMap` uses in sema.zig. The leaf-by-position keys and
  `DenseMap`'s `1 << 32 | id` trick (fastmap.zig:66-73) go with it.
- **Storage facts** are LIR vars. There is no `storageOf(node, kind)`
  table; there is the var the lowering made.
- **Proofs** write into the `proven` field of LIR check ops.
- **Decisions** (`sema.Question`, 36 of them) are not recorded on
  first ask and verified later (storage.zig:1587-1631); the lowering
  makes each once, in the walk that owns it, and they are LIR data.
  `verifyDecisions` becomes a self-check that lowers each function twice
  and compares the two LIRs, in self-checking builds only.

---

## 4. Shared machinery

### 4.1 Inside the compiler

- **The node store** (section 3.1): one generic `NodeTable(T)` over
  node ids, used by resolve, typecheck, and lowering. One recorder API,
  sealed per pass.
- **LIR**: data structures, a verifier (every `addr` targets a var or a
  place rooted at one; every var's `life` contains its uses; every
  region's exits drop its vars), and a text form for `rig lir`
  (ROADMAP: "a text form a Nexus grammar parses back for round-trip
  tests and yield points as explicit operations"). The verifier is the
  structural address chokepoint weak-spots.md asks for.
- **One evaluator** with a partial mode, cteval's, for constant folding,
  compile-time functions, inlining's guards, and float constants
  (compiler-review/evaluators-deferred.md: four evaluators today).
- **One type printer** for diagnostics and `$name` (as today).
- **Diagnostics** as today.
- **One call-part list.** Each call's parts in written order (callee
  when it acts, else self, then each argument, each with its hold),
  decided once by the lowering; audit-storage-emit's "biggest
  simplification" and the cure of E1/E2/X1/X2's class.
- **Intrinsics as a table.** The std forms typecheck types by hand
  (`actorCall` typecheck.zig:16835, `taskSelect` 18166,
  `taskSelectNamed` 18244, `par`, `isolate`, `supervise`, `http.serve`,
  `io.copy`, `reduce`: about 1,400 lines per the rewrite review) become
  rows: a std declaration whose signature Rig can state, plus an
  `intrinsic` attribute naming the runtime entry and the parts of the
  call the runtime needs (slot, limit, per). Typecheck reads the row;
  the lowering emits `call(intrinsic(id))`; the printer has one switch
  arm. The 15-odd `is*Call` facts and emit's chain (emit.zig:9530-9760)
  collapse.

### 4.2 Between the compiler and the runtime

The compiler already compiles `runtime.zig` as a module (resolve.zig:26,
nametable.zig:7). What it should share, in order of value:

1. **The classifiers that both sides need, as markers.** The compiler
   classifies each type once (section 3, B) and the printer writes the
   classification into each emitted type as one declaration,
   `pub const __rig_repr: rig.Repr = .{ .glue = .parts, .zeros = true,
   .view = .pointer, … }`. The runtime's `needsDrop`, `fillsWithZeros`,
   `ReadView`, and `Opt` read the marker for a type the program
   declares, and compose for Zig's anonymous types (an optional, an
   array, an error union, a pointer) and the runtime's own types (which
   declare their own `__rig_repr`). The composition rules are a few
   lines each and are the same rules the compiler uses for the same
   shapes; a unit test compiled into `bin/rig` checks, for a corpus of
   types, that the compiler's classifier and the runtime's composition
   agree, as sema.zig:18771 already does for `Mask`. One classifier per
   fact, across the boundary.
2. **Checked arithmetic.** `sema.ctArith` (sema.zig:17358) folds
   constants with Rig's overflow rules; the runtime panics with them.
   One `arith.zig` of pure functions (wide add, sub, mul, shift with
   range tests, the duration conversions' `total` and `clamped` math)
   used by cteval at check time and by the runtime's checked operations
   at comptime makes "the same answer at compile time and run time"
   true by construction. It changes no emitted code, so it is an
   identity step.
3. **Name mangling.** `rig.writeZigIdent` and the runtime's `rigName`
   (which strips the `'` suffix, INTERNALS.md:4773) are two halves of
   one bijection; one small file used by both.
4. **The hash tables.** `unordered.zig` and `ordered.zig` take their
   allocator, hash, and `==` from the runtime's globals. Made generic
   over a comptime `Env` (allocate, free, hash, eql, drop), with the
   runtime's `Env` the default, the same tables serve the compiler's
   intern and memo maps (the type-pair memos `TypeMemo`, the interner),
   which remain once node facts are dense arrays. The runtime's code for
   `Map` and `HashMap` is unchanged at the instance the program uses, so
   no guarded row moves; whether the compiler gains is unknown and is
   measured by `bench/check/guard.py` (instructions) and Trig's
   `rig check` time. fastmap.zig keeps its multiply hash as the
   compiler's `Env.hash`.
5. **Not shared:** the release allocator as the compiler's allocator.
   The compiler moved from an arena to `smp_allocator` for peak memory
   (INTERNALS.md:1785-1789: 2.1 GB against 0.65 GB on Trig);
   `alloc.zig` might do better or worse, unknown, and it is a
   measurement, not a design call.

### 4.3 The runtime face and the config record

- **One face.** The names emitted code may reach are an enum in the
  backend (`RtFn`), with the spelling of each in one table. A comptime
  test in `bin/rig`'s build checks that every `RtFn` exists in the
  runtime (`@hasDecl`), and the preemption section lists
  (`preempt_calls.txt`) are derived from the same table: which entries
  are in `rig_text`, which are inline, which take a lock.
- **One config record.** The root declares `pub const __rig_config:
  rig.Config = .{ … }` with every program-wide setting the runtime
  reads, defaults spelled in `rig.Config`. The 13-odd `@hasDecl(root,
  "__rig_…")` reads become field reads of one comptime value; a typo is
  a compile error instead of a silently absent setting. This changes
  emitted text (a behaviour step whose hunks are all "neutral"), and no
  machine code.

### 4.4 Which runtime code exists because of how emit was built

| Piece | Why it exists | In the ideal |
|---|---|---|
| `keep(&slot, &flag, v).*` (runtime.zig:1928) | emit writes a statement temporary from inside the expression that uses it | the LIR assigns the slot as an op before the use; the printer writes `slot = v; flag = true;` and uses `slot`. A neutral step, measured (it changes what LLVM sees) |
| `noneAt` (runtime.zig:1939), `someViewed*` (1750-1762), `copiedOut` (1785) | addresses of values no storage holds | LIR vars; the verifier forbids `addr` of an expression |
| `rt` (runtime.zig:1968) | Zig folds comptime-known values that Rig specifies as checked at run time | stays: it is a Zig-backend necessity, measured (perf-stage/table-reads.md; `rt-by-value` #816 was 0.6-2.2% slower). The printer writes it exactly where today's emit does |
| `Proven`/`If` twins (runtime.zig:5108-5166, 5402, 5615, 5676, 6397-6408) | one runtime function per combination of omitted tests | one function per operation with a comptime `Checks` argument (lower, upper, both, and an optional flag); the same machine code by construction of comptime, smaller source |
| duration twins (`durationInt`/`Float` × plain/`Clamp`/`Try`) | one function per conversion mode | one function per number kind with a comptime `how` |
| `*Into` waits and `no_slot` (tasks.zig) | errors with fields threaded through each wait | one convention: every runtime entry that can fail takes the slot last; `no_slot` stays (revamp-runtime next-round C15/C16) |
| `split.cell`, `split.local` (split.zig:30, 46) | each unit compiles the runtime | stays: split is for debug builds only, and the mechanism is 345 lines |
| `map_trace.instrument` rewriting text (main.zig:2283-2290) | no hook in emit | a prelude-level comptime branch on `rig.config.map_trace`, or a printer hook on the prelude's methods; low priority |
| `__rig_*` root declarations | config by `@hasDecl` | one `rig.Config` record (4.3) |

### 4.5 Which runtime code could be smaller without being slower

- The twins above: about 250 lines of runtime.zig, machine code
  unchanged where the comptime arguments fold as the twins do (to be
  confirmed by the json, hash, and text guards, since the emitted calls
  change spelling).
- The five reflective walkers (`dropElement`, `eql`, `hashAs`,
  `cloneValue`, `writeValue`) share one comptime traversal of a type's
  parts (struct fields in order, a union's active payload, an array's
  elements, an optional's payload, the `outOfLine` depth cut at eight,
  INTERNALS.md:5815). Perhaps 300 lines; the code each instance makes
  must be measured, since `eql` and `hashAs` are on Trig's hot path and
  a different shape can lay out differently.
- Duplicates the runtime audits found and left: the nested-release
  guard written three times (audit-runtime R7), `isShared` twice (R9),
  three spin locks in alloc.zig (R15), one completion primitive in
  sched.zig (C14, about 60 lines, on the task-join hot path, so timed).
- Not smaller: the scheduler, the allocator, and the tables. Every
  piece of them has a record of what it bought (scheduler.md, the
  `alloc-*` and `hash-race` records), and their size is the price of
  measured speed. I budget them flat.

---

## 5. The back end

### 5.1 The LIR

Structured, not a CFG, because the Zig backend needs structured
control flow (Zig has no `goto`), the ownership checker already runs
its fixpoint over structured loops, and a structured IR lowers to an
LLVM CFG mechanically. The shape:

```text
Module   { funcs, types (repr ids), decls, witnesses, api_tables, error_sets,
           consts, tests, shims, text_tables }
Func     { owner: FrameOwner, sym, params: []VarId, result, marks: {inline,
           called, rarely, noreturn, cut_unit?, section}, vars: []Var, body: Region }
Var      { ty, name: user(SymbolId) | hidden(kind, id), by: owned|copy|pointer|buffer,
           life, drop: ?ResourceKind, flag: ?VarId, mutable, poison, src: NodeId }
Region   = block { ops, exits }            exits: drops (last made first), defers, errdefers
         | loop  { label, body, step?, yield: turn|none, fold? }
         | if    { cond: Expr, then, else }
         | switch{ plan: MatchPlan, prongs }
         | labeled { label, result: ?VarId, body }
Op       = bind(VarId, Expr) | store(Place, Expr, drops_old) | eval(Expr)
         | drop(VarId) | disarm(flag) | poison(VarId)
         | check(kind, operands, proven, flag?) | yield(kind)
         | break(label, Expr?) | continue(label) | return(Expr?) | fail(Expr, site)
         | region(Region)
Expr     = var(VarId) | const | place(Place) | addr(Place) | deref(Expr)
         | unop/binop(op, flavour: checked|wrapping|saturating|proven, ...)
         | call(target, kind, args: []Expr, slot?, crossing: none|rt|var_in_place)
         | try(Expr, site) | coerce(kind, Expr) | field/index/slice(Expr, ...)
Place    = { root: VarId, path: []Step }   Step = field | elem(Expr, checks) | deref | payload
```

Rules that make it work:

- **Storage is only vars.** An `Expr` never takes an address of
  another `Expr`; `addr` takes a `Place` rooted at a var. A value that
  needs an address and no name is a hidden var with life `statement`
  (today's `zig_temp`, which already is a storage kind). That closes
  weak-spots' "Addresses of Zig rvalues" in the verifier, not by
  review.
- **Order is op order, then left to right.** Ops run in sequence;
  inside one op's expression tree, operands run left to right before
  the operation, which is Zig's rule and the rule SPEC gives where no
  part is hoisted. The lowering hoists a part into a var exactly where
  storage.zig's `hoistsArgs`, `setOrder`, `hoistsResults`, and
  `heldFirst` hoist today, so the printer can nest the rest as today's
  emit does. The LLVM backend reads the same order.
- **Exits are explicit at the region.** A block's exits list its drops
  and defers. The Zig printer writes them as `defer` (as emit does
  today, emit.zig:2468 `emitGuard`); the LLVM backend expands them at
  each exit, `fail` included.
- **Every op carries a node id** for diagnostics and for the site marks
  of failure traces.
- **Yield checks are ops** (`yield(turn)` at a loop's head,
  `yield(tick)` at a call cycle's cut), so the preempted build and the
  checked build differ in one flag the printer reads, and an LLVM
  backend sees them.

### 5.2 What the Zig printer does

- Types and declarations from the repr table: structs, tagged unions,
  `__rig_name`, `__rig_repr`, `__rig_drop` from the glue kind, witnesses,
  API tables, error sets and glue, `expectShim` blocks.
- Functions: signature from the type table, `pub inline fn`/
  `noinline fn` from marks, `@branchHint(.cold)` for `rarely`,
  `linksection(rig.preempt_section)`, `@setEvalBranchQuota(rig.eval_quota)`,
  the `rig.rt` binding of an inlined function's parameters
  (INTERNALS.md:5184-5189), the cut prologue for split builds
  (`emitCut`, emit.zig:2083).
- Bodies: one print function per region kind and per op kind; one per
  `Expr` kind; one per coercion kind (`emitLift` etc. today); names
  through `writeZigIdent` and the hidden kind's prefix; site marks.
- Nothing else. Its state is the output writer, the indent, and the
  names of the scope (for shadowing renames, emit.zig:4785-4789's rule).
  No mode flags, because what they encoded (`ptr_tail`, `want_ptr`,
  `read_place`, `rt_names`, `literal_ty`, `place_chain`) is now in the
  LIR (an `Expr` says whether it is a pointer or the value, a check op
  says what it tests, a literal carries its type).

### 5.3 What the Zig printer shares with an LLVM backend

Shared: the LIR; the type table and its repr facts (layout, niches,
drop glue, clone, equality, hash kinds); the program-wide facts
(inlined, never-returns, word-held, symbols, units); the check ops and
their proofs; the yield ops; the error-slot convention; the runtime
config record.

Not shared: everything that exists because the target is Zig source:
`rig.rt`, `@setEvalBranchQuota`, `ReadView(T)` and `Opt(T)` as comptime
functions, Zig's generics standing for Rig's, `@hasDecl` markers,
`expectShim`, the site marks' text positions, `defer` as the spelling
of exits.

What an LLVM backend needs that the Zig backend does not, and the LIR
must allow:

1. **Monomorphization.** Zig instantiates Rig's generic functions and
   types today (INTERNALS.md:4987-4997); LLVM cannot. The LIR stays
   generic (the Zig printer needs it so), and the LLVM backend
   instantiates functions and types over the type table itself. The
   repr facts are computed per instance there.
2. **The runtime's generic half.** `List(T)`, `Shared(T)`, `Box(T)`,
   `Opt(T)`, `String`, the tables, and the reflective walkers are
   comptime-generic Zig, which LLVM IR cannot call. A type-erased
   runtime ABI would make the containers slower (keys hashed and
   compared through pointers), which the speed rule forbids. The path I
   recommend: the LLVM backend asks a generated Zig file for the
   instances its code uses (`export fn` wrappers of
   `List(i64).push`, …), Zig compiles that file to bitcode, and the two
   bitcode modules are linked and optimized together, so the instances
   inline into Rig's code as they do today. `pgo.zig` already builds
   from Zig's bitcode with `zig cc` (INTERNALS.md:253), which shows the
   toolchain can take bitcode. Whether `zig cc` links and optimizes two
   bitcode modules with LTO at Zig 0.17's LLVM 22.1.8, and at what build
   cost, is unknown and is the first measurement of the LLVM stage.
3. **The monomorphic runtime** (the scheduler, the allocator, I/O,
   stacks, panics, print of scalars) is called through its C-ABI
   functions or the same bitcode; the split between generic and
   monomorphic parts is worth making explicit in the runtime's file
   layout before December (a directory `src/rt/` with `core/` and
   `generic/`), as an identity step for the Zig backend.
4. **What it could gain** (IDEAS.md:147-153): `noalias` from ownership
   facts (measured at 0.2% fewer instructions on Trig through Zig,
   records perf-stage/table-reads; LLVM may do more with
   `dereferenceable`, unknown), no Zig analysis at build time (unmeasured;
   IDEAS asks for that measure first), debug information in Rig's terms.

### 5.4 Split builds, frames, BOLT, PGO

- **Units** (units.zig:52) decide by source size today; on LIR they
  decide by op count, closer to LLVM's cost. Cutting stays a mark on
  the LIR function, printed as today's prologue. `rig.split.crosses`
  stays Zig's decision, since only Zig knows the lowered signature.
- **Frames.** Frame owners and accounts move from typecheck
  (`recordFrameOwners` typecheck.zig:23896, `checkFrames` 23840) to a
  pass over LIR, where a frame's slots are its vars and its
  materialized expression temporaries: what Zig writes, rather than an
  estimate from the tree's shape. The reach factor and the measured
  bound stay (INTERNALS.md "The program's stack"). Destination passing,
  which INTERNALS says would make the bound hold by construction, is an
  LLVM-backend option, not a Zig-backend change (section 8).
- **frames.zig, bolt.zig, pgo.zig** read the built executable; they
  are independent of the pipeline and stay as they are.

### 5.5 Where typecheck splits (brief, from my reading)

typecheck.zig's own banners give the seams: declarations (560-983),
groups and spreads (983-1770), statements (1770-5954), synthesis
(5954-10543), calls (10543-19316, 8,773 lines, the std forms among
them), checking against an expected type (19316-22146), builtins
(22146-22510), closures (22510-22962), compatibility and
classification (22962-23713), generic requirements and frames
(23713-25144), APIs (25144-25890). From the back end's side the split
that matters is what leaves typecheck: temporaries and header copies
(to the lowering), frames (to the LIR pass), and the std forms (to the
intrinsic table). What stays is six files of roughly 2,500-3,500 lines:
statements and declarations; synthesis; calls (resolution, slots,
inference); checking, builtins, closures; compatibility and
requirements; APIs.

---

## 6. Line budget

Budgets come from the design: what each pass must do, sized against
the closest existing code that does it (the oracle's lowering for
`lower`, today's printing paths for the printer), not from today's
file sizes. Every file's budget counts its tests and docs, as the
ledger's scoreboard will.

### 6.1 The compiler

| Pass | Today (files) | Today | Budget | Reasoning |
|---|---|---:|---:|---|
| lex and parse wrapper | rig.zig | 7,706 | 5,200 | the grammar keeps parentheses and groups; the type-directed desugars leave for the lowering |
| diagnostics | diag.zig | 337 | 350 | as is |
| modules | modules.zig | 1,172 | 950 | no recheck loop (modules.zig:883-901), no write-back from ownership |
| resolve | resolve.zig | 5,930 | 5,600 | one program-wide type table replaces per-module stores and proxies; groups expand here |
| sema core | sema.zig | 19,539 | 9,500 | types, symbols, type facts, the node store; the 36 questions and their memo plumbing, and classifiers that are lowering decisions, leave |
| typecheck | typecheck.zig | 26,390 | 17,000 | 30-35% smaller per the 10-31 review; temporaries, frames, std forms leave |
| cteval | cteval.zig | 2,175 | 2,000 | one evaluator with a partial mode absorbs three |
| **lower** (new) | storage.zig and parts of typecheck, emit | (2,774) | 6,500 | the oracle's lower.zig is 4,972 for a subset that abstains on some shapes; plus evaluation order, every storage kind, match plans, coercions |
| **lir** (new) | none | 0 | 1,500 | data, verifier, text form and its round trip |
| ownership | ownership.zig | 9,768 | 6,000 | dataflow over LIR; no name resolver of its own, no sema-optional paths (review §3); oracle core+flow+kinds is 2,156 |
| proofs | proofs.zig | 2,930 | 2,200 | units are ops; no emit-side unit model |
| frame accounts (new file) | part of typecheck | (unknown) | 900 | owners and accounts over LIR vars |
| inlining, returns | inlining.zig, returns.zig | 1,724 | 1,200 | sizes and divergence read from LIR |
| units, symbols | units.zig, symbols.zig | 198 | 200 | as is |
| type repr facts (new) | part of facts.zig and sema | | 600 | one record per type, both backends |
| facts boundary | facts.zig | 1,655 | 0 | the LIR and the repr table are the interface |
| **Zig backend** | emit.zig | 12,537 | 6,800 | declarations, types, witnesses, glue about 2,100 (today's 690-2260 and 11415-11970); bodies on LIR about 3,000; split, sites, misc 400; docs 1,300 |
| fastmap | fastmap.zig | 153 | 60 | `DenseMap` goes with dense node tables |
| map_trace | map_trace.zig | 155 | 0 | a hook, not a text rewrite |
| main (CLI, package, cache) | main.zig | 3,256 | 2,900 | config record, simpler `emitPackage` |
| nametable, timing, lib | | 148 | 148 | as is |
| lsp, editor | lsp.zig, editor.zig | 1,952 | 1,952 | outside this lens; flat |
| frames, bolt, pgo | | 1,567 | 1,567 | flat |
| **Compiler total** | | **102,066** | **73,100** | 28% smaller |

The back end proper (storage, facts, emit, proofs, inlining, returns,
units: 21,723 lines today) becomes lower, lir, repr, the Zig backend,
proofs, inlining, returns, units: 18,900. Its share of the savings is
small because the lowering is new code that also takes work from
typecheck; the larger savings are sema's memo plumbing (−10,000),
typecheck (−9,400), and ownership (−3,800), which the LIR makes
possible.

### 6.2 The runtime

| File | Today | Budget | Reasoning |
|---|---:|---:|---|
| runtime.zig | 12,333 | 11,600 | twins (−250), keep/noneAt/someViewed vocabulary after flattening (−120), config record (−100), audit duplicates R7/R9/R10/R11 (−40), reflective traversal shared (−200, if measured even) |
| sched.zig | 11,482 | 11,300 | C14's one completion primitive and small duplicates; nothing measured is cut |
| tasks.zig | 3,367 | 3,150 | actor calls through the ordinary method lowering (X1/X2's class), `Into` wrappers (C15/C16) |
| alloc.zig | 4,854 | 4,830 | one spin lock (R15) |
| ordered.zig, unordered.zig | 2,729 | 2,790 | a comptime `Env` for the compiler's use |
| net.zig | 2,577 | 2,500 | C8's file I/O path |
| table.zig, split.zig | 670 | 645 | `fillsWithZeros` reads the marker |
| **Runtime total** | **38,012** | **36,815** | 3% smaller |

std: flat, plus about 200 lines of Rig declarations for the intrinsic
rows that replace typecheck's hand typing.

**Total: 140,078 → about 109,900 (22% smaller), with the runtime's
measured code kept.**

---

## 7. The path

Before the rebuild's first step: any back-end bug the audits found
that is still open at revamp-base (I did not re-probe E1, E2, X1, X2,
X4, X5) lands on `main` first as its own behaviour step, so the rebuild
reproduces fixed output (rebuild.md "When the old code was wrong").

Steps, in order. **I** is an identity step (byte-identical emit,
`tools/emit-diff revamp-base`), **B** a behaviour step.

| # | Step | Kind | Notes |
|---|---|---|---|
| 1 | **Pilot: the var table.** `storage.plan` produces, per frame owner, an ordered table of vars (node, kind, by, life, type, drop, flag), folding in `Symbol.hold`, `dropKind`, `partDrops`, and `SetOrder.drops_old`; `hiddenStorage` (emit.zig:2390), `zigTemporary` (2443), `emitTempSlots` (2744), `emitGuard` (2468), and the ownership checker's `holdForCall` (ownership.zig:5908) read it. Emit keeps its own name counter (emit.zig:2454), so names do not move. | I | budget: net −500 lines across storage, facts, emit |
| 2 | Facts become reads: E5's live classifiers recorded as questions; `copiesSubject` and `emitBind`'s pointer-or-copy recorded (E6, E7); one `builtin_of` fact for `swap`, `none`, conversions, `print` (X6, review §1b); emit's type predicates become repr facts. The facts test becomes positive: every `Facts` method reads a table. | I | each of these is a small identity change; batch into two PRs |
| 3 | Intrinsic table: std forms as declarations with an `intrinsic` row; one call kind in emit for all of them; actor calls as method calls with a self (fixes X1/X2's class if open, else identity). | I (+B if a bug) | typecheck's hand typing of std forms shrinks |
| 4 | The node store: dense per-fact arrays by node id, leaf ids, sealing; the position keys go. | I | check speed measured (guard), expected faster; peak memory on Trig's check measured |
| 5 | Typecheck split along section 5.5's seams. | I | the rebuild's default pilot; mostly moves |
| 6 | `arith.zig` shared by cteval and the runtime; `names.zig` shared by `writeZigIdent` and `rigName`. | I | no emitted change |
| 7 | **Lowering in shadow.** `lower` builds LIR for every function from the typed tree and the recorded facts; in self-checking builds the var table and evaluation order it produces are compared with step 1's table and storage's decisions; emit is unchanged. | I | proves the LIR holds every decision before anything reads it |
| 8 | **The printer, construct by construct.** The Zig printer prints a function from LIR when every construct in it is ported, else today's emit writes it; the printer allocates names in the order emit's recursion does, so the output is byte-identical. Ends with emit's body writer, its mode flags, and storage.zig deleted. | I | the long step; several PRs, one construct family each |
| 9 | Proofs on LIR; the unit assertion deleted. | I | |
| 10 | Frames and inlining on LIR. | I | inlining decisions must not move; compare `inlined` sets over the corpus |
| 11 | Sema once: iterator loops, byte literals, chains expanded by the lowering; groups and spreads by resolve. | I | emit identical and diagnostics identical over the suite and the corpus (`~/Data/Code/rigs.txt`) |
| 12 | **Ownership on LIR,** run in shadow over the suite and the corpus until its verdicts and diagnostics match, then swapped in. | I | identity here means same acceptance, same diagnostics, same emit; the oracle stays independent |
| 13 | Neutral emit changes, each alone, measured by the json, hash, and text guards and Trig's light gate: flattened statement temporaries (no `rig.keep`), the `rig.Config` record, the twins collapsed, `__rig_repr` markers with the runtime's mirrors reading them, names from var ids. | B | each PR classifies every hunk as neutral; a race only if a guard moves |
| 14 | Hash tables with a comptime `Env`, used by the compiler's remaining maps. | I | emit identical; kept only if the check guard improves |
| 15 | The runtime split into `core/` and `generic/` for the LLVM stage. | I | file moves |
| 16 | Phase E: the LLVM backend from LIR, behind a flag, after the bitcode-link measurement (5.3). | B | December 2026 per ROADMAP |

### 7.1 My pilot, and why

**Step 1, the var table.** The rebuild's default pilot is typecheck's
split (step 5). From the back end's side I would pilot step 1 instead:

- It tests the design's central bet, that a decision can become data
  emit only prints, and holds byte identity while doing it. A typecheck
  split mostly moves code and is identical by construction; it measures
  the process's pace more than its proof.
- It crosses three passes (storage, ownership, emit) and the facts
  boundary, so it exercises the deletion review and the "two copies are
  a finding" rule on real duplication (storage's map, facts'
  forwarders, emit's slot bookkeeping).
- It is bounded: the 30-odd storage kinds are already named through
  one function (emit.zig:2390), so the step changes what that function
  reads, not every site.
- Its result is the LIR's var table, which steps 7 and 8 build on.

If the owner wants a harder pilot, step 7 restricted to calls (the call
part list in shadow, compared with `hoistsArgs`, `selfHold`, and
`heldFirst`) is the next choice: it is where the last audits' bugs were.

---

## 8. Considered and rejected

| Idea | Why not |
|---|---|
| A CFG IR (basic blocks) shared by everything | the Zig backend needs structured control flow; a structured IR lowers to a CFG mechanically for LLVM, not the other way round. The oracle's core uses blocks (core.zig:1-4) for dataflow only, which structured regions serve as well |
| Monomorphizing in the Zig backend | Zig already instantiates; one body per Rig body keeps Zig's build smaller (INTERNALS.md:4987-4997). Monomorphization belongs to the LLVM backend |
| A type-erased runtime ABI for LLVM | containers hashed and compared through pointers are slower; the speed rule forbids it. Zig-built instances linked as bitcode instead (5.3) |
| Split release builds | Trig 7.5-9.4% slower as 8 units, 14-21% as module units (records 2026-10/build-split) |
| Changing the std `Map`/`HashMap` tables in the rebuild | the Swiss "Map stage" was 1.5-3.8% slower in PGO wall time (map-stage/build.md); hashbrown for Trig's maps moves Trig's wall by +0.42% to −0.69% (2026-11/map-replay). Sharing the tables with the compiler changes no program's table |
| mimalloc for programs | 1.0-2.4% slower than alloc.zig as shipped (mimalloc-ceiling) |
| Binding object parameters without `rig.rt` | #816 `rt-by-value`: Trig 0.6-2.2% slower (perf-stage/codegen-gap.md). The printer writes `rt` exactly where emit does |
| An inline `rig.rt` for optional results | four times the compile time of a large program, and the same store-forward stall (perf-stage/table-reads.md, emit.zig:9372-9387) |
| Direct calls for known function arguments as a program-wide fact | about 1% on small projects, nothing on large ones (perf-stage/direct-calls.md) |
| `noalias` on views through Zig | 0.2% fewer instructions on Trig (Table reads record); revisit only in the LLVM backend |
| Strip-mined loops with one yield check per block | 0.5-1.4% more instructions on Trig, no gain (2026-11/loop-split, panels); preemption by signal replaced it |
| Cheaper yield checks (flag per turn, check at function entry) | timers starve, or 2.2-3.9% more instructions (2026-10/sched-check) |
| Spans and false-edge proofs | within noise, 0.01-0.25% more instructions (perf-stage/proofs.md); the proofs pass keeps its rules as they are |
| Destination passing as the Zig backend's strategy | would make the frame bound hold by construction (INTERNALS "The program's stack"), but rewrites every function's emitted shape, with no measurement; an LLVM-backend option |
| Async state machines to shrink tasks | the owner's rule: one model, real stacks |
| A hand-written parser | the owner kept Nexus (rewrite-review decision 5) |
| Re-checking after desugaring (sema twice) | replaced by typed desugaring facts and the lowering (2.3) |
| Keeping `verifyDecisions` as the mechanism | it exists because decisions are memoized on first ask (storage.zig:1587-1631); the lowering makes each once. A determinism self-check replaces it |
| The release allocator for the compiler | unknown either way; a measurement, not a design (4.2) |
| Moving the runtime's generic containers into Rig now | would let both backends compile them, but the owner's method is "fastest Zig first, then Rig emits it", and the tables' speed is Zig-tuned; not before the LLVM stage's bitcode path is measured |
| Self-hosting | out of scope (rebuild.md decision 4) |

---

## 9. Risks, and what would make me stop

1. **Byte identity from LIR.** Emit numbers hidden names from one
   counter in the order its recursion meets them (emit.zig:2454), and
   nests expressions where its branches happen to. The printer must
   reproduce both. If a construct family's identity proof fails twice
   for the same reason, I would stop that family, land a neutral
   renaming step once (every hunk a name, guards unmoved), and resume
   identity against the renamed output. If more than one family needs
   that, the "printer by construct" strategy is wrong and the design
   goes back to the lead.
2. **Ownership on LIR changes verdicts or diagnostics.** Positions and
   messages must match over the suite and the corpus; a program Trig
   or loco compiles must stay accepted. Shadow mode first (step 12);
   if the shadow checker cannot match after two rounds of fixes on one
   rule, that rule stays on today's checker and the step stops (the
   mantras' "second round of soundness fixes stops a feature").
3. **Check speed and memory.** LIR is a materialized form that lives
   from lowering to printing, across the program-wide passes. Today
   storage is 26% of `rig check` on bench/check's workload and the
   compiler peaks at 0.65 GB on Trig. If LIR costs more than storage
   and facts save, the guard fails. Mitigations: indices not pointers,
   struct-of-arrays, and dropping a module's LIR once printed; a
   fallback is re-lowering at print time (lowering is deterministic),
   which costs time to save memory. Stop if `bench/check/guard.py`
   regresses past 2% after mitigation.
4. **Emitted speed.** Identity steps keep it by construction. The
   neutral steps (13) change text and could move layout: the 2026-10
   R4 record shows one 32-byte shift of identical code moving twitter
   2.3% on pup. Each such step runs the guards alone and is reverted if
   one moves past 2%.
5. **The LLVM stage's runtime.** If Zig 0.17's toolchain cannot link
   and optimize Rig's bitcode with Zig-built instance bitcode at an
   acceptable build cost, the LLVM backend cannot keep the runtime's
   generic code fast, and the December plan needs the owner's decision
   (generic containers in Rig, or no LLVM backend yet). The rebuild does
   not depend on it: the LIR pays for itself in the Zig backend.
6. **Hidden coupling in the runtime mirrors.** Replacing reflection by
   markers (step 13) assumes every type the runtime classifies is either
   emitted (and marked), a runtime type (and marked), or one of Zig's
   anonymous shapes. A type a std shim declares in Zig would be none of
   these; the comptime check must fail closed (no marker, no rule:
   compile error), never guess.

What would make me stop the whole back-end track: step 7 (lowering in
shadow) unable to reproduce storage's decisions on the suite after its
second round, which would mean the decisions are not functions of the
typed tree and the recorded facts, and the LIR's premise is false.
