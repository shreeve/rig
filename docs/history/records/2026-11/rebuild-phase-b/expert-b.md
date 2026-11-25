# Phase B, Expert B: the checkers and their facts

The design I would build from a blank page, knowing what Rig is now. My
lens is the checkers (sema, resolve, typecheck, cteval, storage,
ownership, proofs, inlining, returns), the facts they record, and how
those facts reach emit. The whole pipeline is covered, but most depth
goes there.

Base: tag `revamp-base`, commit 645996606, read in
`~/Data/Code/worktrees/rig/revamp-base-ro`. Every `file:line` below is at
that commit. Nothing was built or run; every claim comes from reading the
code, INTERNALS, CORE, and the records. Where I could not tell, I say
"unknown".

## Answers in brief

1. **Does sema need to run twice?** No. The second run exists because five
   desugarings need types: iterator `for`s, byte literals, chains, groups,
   and spreads (`modules.zig:884-902`). Typecheck finds each one, the
   Parser wrapper rewrites the untyped tree, and the whole module is
   checked again. The ideal typechecker elaborates each one where it finds
   it: it builds the desugared subtree, declares its hidden bindings in
   the scope it is in, and checks that subtree in place. One check per
   module. Section 7, step 4 is the path. It is probably an identity step,
   but symbol numbering is a risk.
2. **Can the facts table, storage, and proofs share one recorder?** Yes,
   and in the end most of them stop being side tables at all. In the
   interim, one `Record` holds every column, all keyed by node id, each
   with exactly one writer pass, sealed when that pass ends. That
   replaces about 80 maps under 3 key schemes, plus the storage map, the
   `decided` memo, `proven`, and `unit_of`. In the final design, storage
   and decisions become variables and order in a lowered body IR
   (**BIR**), and proofs become bits on BIR check ops. Only the typing
   facts stay as columns.
3. **Where does typecheck split?** By who owns each decision, not by
   syntax. Typing proper (synth/check, compatibility, calls, statements,
   fallibility, the raw boundary) stays. Lowering decisions (statement
   temporaries, header classes, the rejections that ask storage) leave
   for `lower`. Separate files take places and access, the view-syntax
   rules, built-in method typing, std forms, APIs, generics, frames, and
   hints/fix-its. Context goes down as a value instead of in 95 fields.
   Section 5 gives the cut, with sizes.
4. **What does emit share with a future LLVM backend?** The BIR, plus a
   `layout` table saying how each type is held, plus the program-wide
   decisions. A backend is a printer of BIR. Only spelling is
   Zig-specific: `defer` for drop guards, Zig comptime for generic
   bodies, `rig.*` helper calls. The BIR must therefore make every
   type-dependent decision an explicit op, never an implicit Zig comptime
   test.
5. **What do the oracle's differences imply?** `test/oracle/differences`
   holds **142** entries at revamp-base: 68 prod-strict, 71 ref-gap,
   3 core-gap. I could not reproduce the brief's 185. Most prod-strict
   entries are structural, not about rules: textual liveness, loans that
   last a statement, loans rooted on write-view bindings, and checks
   that read the emitted body's shape. The oracle reaches these verdicts
   in 7,926 lines by lowering once and running one dataflow. That is
   direct evidence that a BIR-based ownership checker can be smaller and
   more precise. The oracle must keep its own lowering (section 8).

---

## 1. Today, as found

### 1.1 The checkers

Sizes are total lines (in-file unit tests in parentheses). Non-comment,
non-blank code is in the last column.

| File | Lines (tests) | Code | What it decides and records |
|---|---|---|---|
| `sema.zig` | 19,539 (~1,600) | 12,779 | The type store, symbols and scopes, contents, type facts, the `Facts` record, `SemContext`, the entry point `check`, the classifiers `handsOver`, `viewsOf`, `moveSource`, `viewAs`, view reach, constant folding |
| `resolve.zig` | 5,930 (38) | 4,698 | Built-ins (per module), symbols, declarations, declared types, rules on declared types |
| `typecheck.zig` | 26,390 (~500) | 20,035 | Every expression's type and the typing facts. Also statement temporaries, header classes, place access, view-syntax rules, library forms, APIs, generic instances, frames, fix-its |
| `cteval.zig` | 2,175 | 1,715 | Compile-time functions: checks bodies and runs them |
| `storage.zig` | 2,774 (7) | 1,873 | Hidden storage, the 36 recorded `Question`s, assignment order, word-held objects |
| `ownership.zig` | 9,768 (~420) | 6,713 | Moves, views, loans, drops, origins, exits; records `plain_reqs` and `old_nones` |
| `proofs.zig` | 2,930 (~760) | 2,223 | Index, byte, and add checks known to pass; result bounds; flags |
| `inlining.zig` | 1,578 | 1,088 | Which functions are emitted `inline`, for the whole program |
| `returns.zig` | 146 | 93 | Which functions never return |
| `facts.zig` | 1,655 (~373) | 1,280 | Emit's read-only view: 234 `pub fn`, 109 of them one-line forwards to `sema`/`storage` |
| `emit.zig` | 12,537 (128) | 9,122 | The Zig text |

Checker stack plus emit: **85,422 lines, about 81,600 without in-file
tests.**

**sema.zig** is the front door and the shared state:

- `check` runs builtins, symbols, declarations, contents, sizes, the
  declaration checks, typecheck, frame owners, frames, unread locals,
  declared APIs, generic expansion, instance checks, and `storage.plan`,
  in that order (`sema.zig:6717-6744`).
- `SemContext` (`sema.zig:4281`) has about 176 fields. They hold symbols,
  scopes, the type store, the `Facts` record, storage, decisions, proofs,
  units, `plain_reqs`, `word_held`, and more (`sema.zig:4485`, `4560`,
  `4584`, `4628`, `4697`, `4751`, `4765`).
- `Facts` (`sema.zig:1915-2331`) holds about 80 maps under three key
  schemes:
  - a leaf's position, `u32` (`names`, `writes`, `rebinds`);
  - `exprKey`, a position or a node id with bit 32 set, `u64`
    (`sema.zig:1895`);
  - `NodeKey`, a node id (`sema.zig:1861`).
- Decisions use a fourth key, the address of a node's items with bit 33
  set, for nodes a rewrite built without an id (`decisionKey`,
  `sema.zig:1880`).

Sema's sections are uneven. The banner "Associated types and iterators"
(`sema.zig:10299-13654`, 3,355 lines) also holds Cell placement, task
crossing, word layout, and std's datetime knowledge (`isLeapYear`,
`monthDays`, `zoneNamed`). The view-reach section is 2,227 lines
(`sema.zig:13654-15881`). The record types and `Question`/`Decided` take
`sema.zig:1852-4278`, and `SemContext`'s methods take
`sema.zig:4278-6577`.

**resolve.zig** registers the built-in generics and enums again in every
module (`resolve.zig:5268`). Each module has its own type store, so
another module's type is the variant `imported_nominal` (45 uses in sema,
16 in typecheck, 5 in emit). Resolve calls back into typecheck for
compile-time functions (`resolve.zig:1624`). cteval rewrites the tree
during resolve (`markCalls`, `resolve.zig:1407`).

**typecheck.zig** is a bidirectional checker (`synthExpr`/`checkExpr`,
`typecheck.zig:1-31`). Its `Checker` (`typecheck.zig:115`) has 95
fields. 34 of them are `Sexp = .nil` context sentinels, which an inner
check recognizes with `sameNode`. There are 85 `defer self.X = saved`
restores. Trial checking uses `synthQuiet`/`ctx.quiet` (51 uses), and
facts survive the trial. Besides typing, the file decides:

- statement temporaries: `readLeaf` (`typecheck.zig:9120`), `viewTemp`
  (`9082`), `checkWriteView` (`8192`), recorded as `temp_drops` and
  `written_temps`;
- header copies: `rejectHeaderCopy` (`5117`), which asks
  `storage.headerPoints` while typing;
- place access: `placeOf` (`2925`) and `requireAccess` (`3090`);
- branch views and path bases: `viewsBranch` (`8070`) and
  `checkViewBases` (`20739`);
- where a Cell may be made: `cellMadeAway` (`5984`);
- frames: `checkFrames` (`23840`) and `FrameWalker` (`23995`);
- library forms: `synthMemberCall` (`15823`, 307 lines) dispatches to
  `par`, `isolate`, `select`, `http.serve`, `io.copy`, actors, and more;
- generic instances and APIs (`23713-25144`, `25144-25890`).

It imports `storage.zig` and calls about 20 of its predicates
(`storage.livesIn`, `headerPoints`, `matchesInPlace`, `fillsInPlace`,
`reachesLeaf`, ...) before `storage.plan` has run. Of its 1,190
diagnostic sites, about 595 have view, place, temporary, move, Cell, or
task wording: ownership-shaped rules decided during typing. By function
name, about 13,000 of its 26,000 lines fall outside typing proper:

- views and places: 2,837
- built-in methods: 1,928
- concurrency forms: 1,611
- hints: 1,583
- generics: 1,435
- compile-time functions: 1,126
- APIs: 1,037
- options: 724
- temporaries: 649
- frames: 406

(These are name-based estimates, and the groups overlap.)

**cteval.zig** is self-contained, bounded, and built on a positive list.
It shares integer arithmetic with constant folding (`sema.ctArith`,
`sema.zig:17358`). It is one of **four** constant evaluators (table
1.2).

**storage.zig** records `sema.Storage` for every hidden location, and
answers each `sema.Question` (36 kinds, `sema.zig:2505`) through
`decideAt` (`storage.zig:1605`). That function decides on first ask,
from any pass, and records through a `*const SemContext`
(`recordDecision`, `sema.zig:5830`). `plan` (`storage.zig:1635`) forces
the questions for every node of their kind. Then `verifyDecisions`
(`storage.zig:1615`) asks every one again and panics on a change. It
runs in every build, release included. The check-creep record measured
5.2% of `rig check`'s instructions for it on the guard's workload. On
that workload, storage is the largest pass: 26.5 of 101 ms
(`bench/check/guard.txt`).

**ownership.zig** walks the tree as a flow-sensitive abstract
interpretation (`ownership.zig:1-80`):

- the state is `Var` plus `Flow`, a trail of writes undone to a `Point`,
  and loans as a root and a path;
- loops run to a fixpoint;
- one exit primitive, `exitTo`, handles every exit (`ownership.zig:2317`).

Its sections follow mechanism, not CORE: vars, state, liveness,
expressions, places, view/move/clone/drop, copies, bindings, calls,
closures, return, branches, loops, defer, types
(`ownership.zig:1280-8734`). Points that matter for the redesign:

- **Names by text.** It finds vars by text through its own
  `names: StringHashMap` and scope walk (`ownership.zig:683`, `find` at
  `2151`), though sema resolved every leaf to a symbol.
- **Textual liveness.** Liveness is the largest source position of a
  use, per symbol (`indexUses`/`noteUse`, `ownership.zig:2618-2660`;
  `last_use` at `742`).
- **A second place walker.** It walks places itself (`resolvePlace`,
  `ownership.zig:3757`).
- **A back-edge to emit.** It records which assignments replace `none`
  (`old_nones`, `ownership.zig:5733`). `modules.zig:944-946` copies them
  into sema's record, which emit then reads.

**proofs.zig** runs on accepted modules (`modules.zig:952`). Its
abstract interpretation over units is clear (`proofs.zig:1-58`). It
reads writes from `recordWrite`, which resolve and typecheck call at 6
sites (`sema.zig:5561`), and its soundness depends on that list being
complete. Emit's `enterUnit`/`inUnit` (`emit.zig:12001`, `12041`) and
`checkUnitOrder` assert that emit writes units in the walk's order.

**inlining.zig** and **returns.zig** are program-wide and small:

- Inlining has its own evaluator (`CtVal`, `inlining.zig:215`; `valueOf`,
  `1207`). A call no check resolved reaches every function of that name.
- returns has its own divergence rule (`returns.zig:85`).

**facts.zig** wraps the module's `SemContext` as an `*const anyopaque`
(`facts.zig:127`), so any method can call any classifier. A unit test
guards the import list (`facts.zig:1282`). Emit reads 245 distinct
`Facts` members, calls `self.facts.types.get` 129 times, and has type
predicates of its own (`isPlainTy`, `comparesStructurally`,
`isScalarTy`, `emit.zig:11820-11895`).

### 1.2 Facts decided in more than one place

"Decided" means computed from the program by its own logic. A fact
computed once and read many times is not a row here.

| Fact | Where it is decided | Notes |
|---|---|---|
| The binding a name names | `sema` `facts.names` (`sema.zig:1917`); ownership's text map and scope walk (`ownership.zig:683`, `2151`) | A second name resolver, with its own rules for crossing closures |
| A place's path, and whether it passes through a view or handle | `typecheck.placeOf` (`typecheck.zig:2925`); `ownership.resolvePlace` (`ownership.zig:3757`) | Both walk the same `member`/`index` chain and both work out views and handles on the way |
| `print`/`warn` is the built-in | `storage.printCall` (`storage.zig:89`); `ownership.isPrint` (`ownership.zig:6685`) | Both use text plus `symbolOf == null` |
| A binding is used | `checkUnreadLocals` (`sema.zig:6804`); `ctx.used` (`sema.zig:4632`, `storage.zig:1910`); ownership's `last_use`/`uses` (`ownership.zig:742`, `2618`) | Three walks over leaves, three slightly different questions |
| A binding is written | `recordWrite` from resolve and typecheck (`sema.zig:5561`), read by proofs and the symbol flags; ownership re-derives writes as it walks | Proofs is sound only while the recorded list is complete |
| A statement's temporaries | decided in typecheck (`typecheck.zig:9120`, `9082`, `8192`); grouped by `sema.stmtTemps` (`sema.zig:13588`); slots planned by `storage.plan` (`storage.zig:1635`); modelled by ownership (`holdTemp` `3117`, `dropStmtTemps` `3176`); written by emit (`emitTempSlots`, `emit.zig:2744`) | Recorded once, modelled in four walks. weak-spots.md lists it as the first area that needs care |
| A header points or copies | `typecheck.rejectHeaderCopy` (`typecheck.zig:5117`) asks `storage.headerPoints` (`storage.zig:591`) during typing; recorded, then checked again (`storage.zig:1615`) | A typing rejection that depends on a lowering decision |
| Evaluation order | `storage.SetOrder` and `hoistsArgs` (`storage.zig:1253`, `314`); ownership walks source order and patches with holds and `late` (INTERNALS "Liveness"); emit hoists | A fact for assignments and hoisted calls only. weak-spots still lists call and `print` argument order |
| A statement diverges | `returns.diverges` (`returns.zig:85`); typecheck's `noreturn` types (`typecheck.zig:6452`); `rig.leaves` (`rig.zig:237`) | Three positive lists |
| What Zig holds in a frame | typecheck's `FrameWalker` (`typecheck.zig:23995`), run before `storage.plan` (`sema.zig:6731` against `6744`) | A second model of emitted temporaries, padded by `reach_factor` |
| A constant's value | `cteval.Eval`; `sema.ctFoldBy`/`constIntBy`/`constBoolBy` (`sema.zig:17311-17740`); `inlining.valueOf` (`inlining.zig:1207`); typecheck's float folding (`typecheck.zig:23296-23354`) | The 2026-10-31 records deferred merging them to a rewrite |
| A type needs drop glue | `sema.typeHasDropGlue` (`sema.zig:8954`); the runtime's `needsDrop` by Zig reflection (`runtime.zig:1215`) | The leak checker backs it up |
| A literal's kind | by text, at roughly 106 sites: typecheck 44, sema 19, emit 13, resolve 12, cteval 9, ownership 2, storage 3, inlining 3, proofs 1 (counted by grep) | One classifier, asked about a hundred times |
| How a type compares or copies, in emit | `emit.zig:11820-11895` against sema's type facts | Spelling decisions repeated in emit |
| What an expression hands over | `sema.handsOver` (`sema.zig:16540`) is one classifier, but it is *recomputed*: 81 calls in typecheck, 11 in storage, 6 in ownership. It is also recorded as the `hands` decision and verified | Check-creep found it run four times per expression, now two |
| An assignment's old value is `none` | ownership (`ownership.zig:5733`) into sema (`sema.zig:5634`), which emit reads | A checker writing a fact for emit: a back-edge |

Vocabulary drift that remains: 23 identifiers in typecheck and 9 in sema
still say "lend". "receiver" is gone (0 hits in the checkers and emit).

### 1.3 What the oracle shows

The oracle (`test/oracle/`, 7,926 lines) works in three stages:

- it lowers each body to vars, blocks, and ordered steps, with every
  temporary a hidden var (`lower.zig:1-15`, 4,972 lines);
- it names each check for the CORE sentence it enforces (`core.zig`
  `Rule`: C1-C10, B1-B4, T1, T2);
- it runs a backward liveness and a forward loan dataflow over that core
  alone (`flow.zig:1-5`).

The 142 differences group like this. I classified the prod-strict notes
by reading each one.

| Group | Count | Cause in the compiler's structure |
|---|---|---|
| Textual liveness: a `while` step's use counted after the body, a name declared before a loop live through it, a later arm's guard, deferred code's last use | about 25 | `last_use` is a source position (`ownership.zig:2651`), not CFG liveness |
| A write-view binding (`match !e`, `if !w as r`, `for t in !v`) roots its views on the binding, so they end with its scope | about 15 | A loan on the binding var, where the binding's own loans should pass through (INTERNALS "Binding access") |
| Loans that last a statement: handler blocks copied out after the block, `errdefer` against a view an earlier argument made | about 8 | The statement-temporaries model: a temporary's life is its statement, by construction |
| Older rules than the Core (`_ = w`, `Q(p: w, o: w)`, element view copied by `y = x`) | about 14 | Rules decided in typecheck from syntax |
| Generic instances checked against the emitted body's shape (`peek(^R)`, `cnt(?o)`) | 2 | The emit shape leaks into checking |
| A bounded store chain (17 write views) | 1 | A deliberate work bound (North Star 1) |
| ref-gap | 71 | 38 are one oracle gap: a store through a `(!T)?` parameter's write view. The rest are generic-instance and `from @` precision |
| core-gap | 3 | Open CORE questions |

Two structural consequences:

1. A program whose ownership-shaped rejection happens in typecheck never
   reaches either ownership checker. The oracle's `coverage` header says
   so for `rejectHeaderCopy`, Cell placement, and `hidesNoTask`. Those
   rules are invisible to the second checker.
2. The prod-strict groups are not rule choices. A checker that reads a
   lowered body and computes liveness on its CFG would reach the
   oracle's verdicts on most of them.

---

## 2. The ideal pipeline

```text
source ─▶ Lexer ─▶ Nexus parser ─▶ Parser wrapper (syntax-only rewrites)
        AST: the S-expression tree, immutable after the wrapper
                 │
modules ─────────┤  load, order; one Program owns the type table
                 ▼
declare        symbols, scopes, declared types        → Program.types, Module.symbols
contents       what each type holds; type facts       → TypeInfo (one row per type)
typecheck      bidirectional typing + elaboration     → Record (typing columns, keyed by node id)
generics       instance requirements, bounds, sizes   → Record (instances), diagnostics
lower          one BIR per body: temporaries, order,  → Bir.Module
               storage, drops, header classes,
               coercions; lowering rejections
ownership      dataflow over BIR                      → diagnostics, plain_reqs
proofs         dataflow over BIR                      → proven bits on BIR check ops
frames         stack account over BIR                 → frame accounts
── program-wide ──
words, inlining, returns, units, symbols              → Program record columns
emit           BIR + layout → Zig text
(later) llvm   BIR + layout → LLVM IR
```

Why this order and these IRs:

- **The AST stays immutable after the wrapper.** Every fact is keyed by
  the id of a node the tree holds. A rewrite that needs types does not
  rewrite the AST behind the checker's back (`modules.zig:892-902`):
  typecheck elaborates it (section 7, step 4). Then the tree a pass reads
  is the tree every earlier pass recorded facts about.
- **Typecheck records only typing.** Types, symbols, call targets and
  slots, instances, the view-table rows a coercion used, lifts,
  reads-through, built-in call kinds, jump destinations, payload
  bindings. It decides no storage and asks no storage question. That
  removes the circular dependency in which typecheck asks `storage.*`
  during typing (`typecheck.zig` imports `storage.zig`; 20 predicates)
  and the lazy-memo-plus-verify machinery that circle needs
  (`storage.zig:1496-1631`).
- **`lower` is the single owner of evaluation.** Everything that is about
  what the emitted program does at run time is decided here, once, as
  structure: which temporaries exist and how long they live, how a header
  holds its subject, the order of a call's parts, which values drop where
  and how, which binding is a pointer or a copy, which coercions apply
  (lift, read-through, erase, splat, widen). Today that is spread over
  typecheck's temporary decisions, `sema.handsOver`/`stmtTemps`/
  `moveSource`, all of `storage.zig`, and emit's mode flags and
  sentinels. The classifiers (`handsOver`, `viewsOf`, `moveSource`,
  `viewAs`) become lowering's internals. After `lower`, nobody asks them.
- **Ownership, proofs, frames, and emit read the same BIR.** Then "the
  checker checks exactly what is emitted" (North Star 4) holds by
  construction, not through runtime agreement checks (`hiddenStorage`,
  `inUnit`, `checkUnitOrder`, `verifyDecisions`, `copiesSubject`).
- **Ownership stays after typing.** A module with type errors is not
  ownership-checked (`modules.zig:908-911`). Nothing about that changes.
- **Proofs stay after ownership.** Their soundness rests on the checker's
  acceptance (`proofs.zig:52-58`).
- **The program-wide passes stay where they are.** Word-held objects,
  inlining, returns, units, and symbols are decided after every module is
  checked (`main.zig:963-968`). They write columns keyed by symbol on one
  program record.

The BIR is structured, not a CFG of basic blocks. Zig emit needs the
structure (blocks, labeled loops, `defer`), the proof walk follows the
structure (INTERNALS "Between units"), and byte-identical emit is only
reachable if the BIR keeps the shape emit writes today. Ownership derives
a CFG view from the structure for liveness (section 4).

---

## 3. Facts

### 3.1 The ideal set

There are three homes. Each fact has exactly one writer.

**A. Program declarations.** Written by `declare` and `contents`, read by
everyone:

- Symbols, scopes, and declared types, in one program-wide type table: no
  `imported_nominal`, no per-module built-ins.
- `TypeInfo` per type, with one function per question, as CORE §9 lists
  them and INTERNALS "Type facts" already does: `copies`, `moves`,
  `isUnique`, `typeHasDropGlue`, `cloneable`, `mayHoldView`,
  `viewByValue`, `changesByMark`, `holdsCellByValue`, `misplaced`, view
  reach. These are good today. Keep them, and make sure every pass asks
  them, emit's predicates included (`emit.zig:11820-11895`).

**B. Typing columns** (the `Record`). Written by typecheck and generics
only, keyed by node id:

| Column | From today |
|---|---|
| `symbol_of`, `type_of`, `scope_of` | `facts.names`, `types`, `scopes` |
| `call` (target, params with origins, slots, generic arguments, dispatch) | `call_params`, `call_slots`, `generic_calls`, `dispatch`, `callTargetOf` |
| `builtin` (one enum: element method, built-in method, String operation, swap, print, a std form: `par`, `isolate`, `select`, `serve`, `copy`, actor make/call, chan make, frozen make, reduce, supervise) | about 20 maps today (`elem_calls`, `builtin_calls`, `string_calls`, `swap_calls`, `task_joins`, `par_calls`, `actor_makes`, ...) |
| `instance`, `ct_value` | `instances`, `ct_calls` |
| `coercion` (view rows, lift, read-through, payload copy, splat, widen, erase, duration form) | `views`, `slice_views`, `lifts`, `reads`, `payload_copies`, `splats`, `code_widenings`, `erasures`, `durations` |
| `pattern` (payload bindings, payload fields, error members, member tests, exhaustive) | `payload_binds`, `payload_fields`, `error_members`, `member_tests`, `exhaustive`, `set_pattern_members` |
| `jump_dest` | `jump_dests` |
| `access` (a binding's read or write access, recorded once) | `Symbol.access` |

The decisions are folded into the enums. A `builtin` column of one
`union(enum)` replaces about 20 boolean maps and makes emit's
`emitCallPlain` chain a single switch.

**C. The BIR.** Written by `lower` only. It is not a set of facts *about*
the tree: it is the program after lowering, which is why the storage
facts, the 36 decisions, `temp_drops`, `written_temps`, `header_copies`,
`headers`, `uses`, `takes`, `consumed`, `Symbol.hold`, `old_nones`,
`repoints`, `unit_of`, and the use and write sets all disappear as
records. Each becomes a var, an op, or a field on an op.

Later passes write annotations on BIR ops in BIR-owned columns:

- proofs: the `proven` bits and flags on check ops, and `result_bounds`
  per function symbol;
- ownership: `plain_reqs` per generic symbol, for importers;
- frames: accounts per frame owner.

### 3.2 One recorder

**Interim (section 7, step 1).** One `Record` per module, used by every
pass that records today. It has:

- **One key.** `NodeId` for list nodes, and the leaf's position, in one
  `u64` `Key`, exactly `exprKey` (`sema.zig:1895`). No address keys:
  every node a rewrite builds gets an id from the generated parser's
  `newNode`, as the `captures` node already does (INTERNALS "The parser
  wrapper").
- **Columns declared once,** each with its writer pass as a comptime
  field: `.{ .name = "lifts", .key = .expr, .value = Lift, .writer =
  .typecheck }`. `rec.put(.typecheck, .lifts, node, v)` fails to compile
  for any other pass. That turns North Star 4 from a convention into a
  type error.
- **A seal per pass.** When the writer pass ends, its columns are sealed.
  A write after the seal is an internal error in every build. A read
  before the seal is one in self-check builds. This replaces
  `Decided.sealed` (`sema.zig:5831`) and its silent drop of a late
  answer.
- **Dense columns** (type, symbol, hands) are arrays indexed by id
  (`fastmap.DenseMap`, as `types` is today). Sparse ones are `fastmap.Map`.
  The check-speed record's lesson stands: integer keys hashed by one
  multiply, no Wyhash over bytes.

**Final.** Columns of kind B stay. The `Record` drops the storage,
decisions, `proven`, and `unit_of` columns as the BIR takes them over.

### 3.3 How emit reads them

Emit's entry is
`emit(bir: *const Bir.Module, layout: *const Layout, prog: *const ProgramFacts)`.

- No `SemContext` and no `*anyopaque` can be reached. Today's guard, an
  import scan plus forbidden substrings (`facts.zig:1282`), becomes a
  type boundary.
- `Layout` is the part of today's `Facts` that is about types (INTERNALS
  "Facts": "how each type is held in Zig"): Zig spelling, `viewByValue`,
  word-held, `Opt` niches, `ReadView` routing, `WritePtr`, a type's
  comparison and hash meaning. A Facts method about a node has no
  successor, because the node's decision is in the BIR op.
- `facts.zig`'s 109 forwarding methods and its 31 IR re-exports
  (review-ownership-emit §1g) go with it.

---

## 4. Shared machinery

1. **IR access** stays as Nexus generates it: `ir.get`, the per-kind
   views, `rig.children`. Hidden leaves are read through `rig.leafText`,
   and spans through `diag.textBetween`/`textOf` (AGENTS.md pitfalls).
2. **One `Key` and one `Record`** (3.2), shared by declare, typecheck,
   generics, and the program-wide passes.
3. **The type facts** (3.1 A): one function per question, in
   `types/facts.zig`, asked by every pass, emit's layout included.
4. **The body skeleton.** `rig.stmtClass`, `skeletonOf`, and `eachUnit`
   (`rig.zig:298`, `336`, `367`) are already the one list of structured
   statements and units that proofs and emit share. In the BIR it becomes
   the structure itself: a unit is a BIR block of ordered ops, and a
   structured statement is a BIR node. One generic driver, `bir/walk.zig`,
   walks the skeleton with hooks (`unit`, `branch`, `join`, `loop`,
   `jump`, `exit`). Ownership runs it with a fixpoint at loops. Proofs
   run it with `L = E - K(loop)` and no fixpoint (INTERNALS "Between
   units"). Frames run it once. Today each pass writes its own
   control-flow walk.
5. **One use-def index per body,** built by `lower`: each var's uses in
   evaluation order, its writes, and its CFG last-use. Unread locals, the
   storage plan's `used`, ownership's liveness, and proofs' kills all
   read it (the 1.2 rows "A binding is used" and "A binding is written").
6. **One evaluator.** cteval's, with a partial mode: values may be
   unknown, `and`/`or` decide on a known side, compile-time parameters
   bind per instance, and there is one arithmetic per number type
   (`sema.ctArith`). Constant folding, compile-time functions, inlining's
   guards, and float limits all go through it. This is the design the
   2026-10-31 record deferred (`compiler-review/evaluators-deferred.md`).
7. **Literal kinds decided once.** Typecheck records a literal's kind
   (int, float, string, bool, none) in the `Record` the first time it
   types the leaf, and every later pass reads it. That retires about 106
   text comparisons. (A literal-kind tag in the grammar would do it
   better, but that is a front-end and Nexus question for another
   expert's lens.)
8. **Diagnostics with two ends and fix-its.** `diag.zig` plus one hints
   module: today's `ViewBaseFix`, `staticHint`, and the message builders,
   moved out of typecheck. Ownership's "both ends of a view" notes
   (INTERNALS "Both ends of a view") stay its own. Every BIR op carries
   its source span, so ownership and proofs report at source positions
   with no lookup back into the tree.
9. **The trail state engine** (`Var` plus `Flow`, trail, `Point`, join;
   `ownership.zig:158-660`) is good and stays. Nothing else needs it:
   proofs' facts meet without a trail.
10. **`fastmap`** for every compiler map, and `smp_allocator` for the
    compiler. The check-speed record measured a one-arena compiler at
    2.1 GB peak against 0.65 GB.

---

## 5. The back end, and where typecheck splits

### 5.1 What emit consumes

Today emit consumes the tree, the type store, and 245 `Facts` members. It
reconstructs evaluation from all three under about 20 mode fields,
sentinels re-entered on the same node (review-ownership-emit §2a), and
77 save/restore pairs (`defer self.X = saved`, counted by grep).

In the ideal design, emit consumes only:

- **the BIR** of each function, test, closure body, `drop` body, and
  module constant initializer;
- **`Layout`** (3.3);
- **program facts**: inline, `noreturn`, word-held, unit ownership,
  symbol numbers.

### 5.2 The BIR

```text
Function { sym, params: []VarId, result, body: Block, vars: []Var }
Var      { name: ?SymbolId | hidden kind (temp, header_value, held, taken, it, elem,
           subject, whole, payload, as_value, viewed, leaf, error_value, argument,
           self, environment, invoked, new_value, base, index, slot, api_object,
           result_place, results, held_header, task_record, zig_temp),
           ty, by: owned|copy|pointer|buffer, life: statement|header|construct|
           iteration|arm|body|expression|handler|call|block, drop: ?DropKind,
           flagged: bool }
Block    { scope, stmts: []Stmt, defers: []Defer }
Stmt     = Unit{ ops } | If{ guards, then, else } | Loop{ kind, head, body, step, else, label }
         | Match{ select: Unit, arms } | Labeled | Raw{ ops } | DeferAt
Op       = bind(var, Value) | store(Place, Value, order) | drop(var|Place, kind)
         | eval(Value) | check(kind, Value..., proven, flag) | jump(dest) | ret(Value)
         | propagate(kind) | panic(pieces) | yield_point
Value    = place(var, path) | view(read|write, Place, rows) | copy(Place) | take(Place)
         | move(var) | clone(Value, how) | lift(Value, levels) | read_through(Value)
         | erase(Value, api) | splat(Value, V) | widen(Value) | literal(kind, text)
         | op(tag, Value, Value) | make(ctor, fields) | call(Call) | branch(...)
         | depends(TypeParam, if_owning, else)
Call     { target, self: ?Arg, args: []Arg, hoisted: bool, result: ?VarId }
Arg      = in_place(Value) | held(VarId)
```

Notes:

- Inside a unit, values stay expression trees, not SSA. Emit writes Zig
  that reads like today's (the identity proof needs it to *be* today's),
  and the op order is explicit wherever it is not source order (hoisting
  makes `held` args, an assignment makes `new_value`, `base`, `index`,
  `slot` in its `set_order`).
- Every type-dependent decision is an explicit `depends` op: whether a
  `T` drops, copies, or is viewed by value at each instance. Zig's
  backend writes it as a comptime test (`rig.needsDrop(T)`,
  `rig.ReadView(T)`). An LLVM backend resolves it while monomorphizing.
  No decision may hide in Zig comptime alone.
- `yield_point` is explicit (ROADMAP: "yield points as explicit
  operations").
- It has a text form, which a Nexus grammar parses back for round-trip
  tests (ROADMAP's LLVM item), and a verifier: every var defined before
  use, every hidden var dropped on every path, every check inside its
  unit. The verifier runs in self-check builds.
- `rig check --facts=storage` and `--facts=proofs` keep their output.
  They print from the BIR.

**What LLVM shares:** the BIR, `Layout`, the program facts, and the
runtime's C-ABI entry points. **What stays Zig's:** `defer` for drop
guards (LLVM gets cleanup blocks from the same `drop` ops and flags),
Zig comptime for generic bodies (LLVM monomorphizes from `depends`), and
the `rig.*` helper spellings (LLVM calls the same runtime functions
exported, or inlines their BIR equivalents).

### 5.3 Where typecheck splits

The cut is by decision owner. Sizes are my budgets (section 6), with
today's name-based estimate after the arrow.

| New home | Holds | Budget (today ~) |
|---|---|---|
| `typecheck/core.zig` + `stmts.zig` + `calls.zig` + `compat.zig` | synth/check, statements, calls, inference, compatibility (`meets`, `compatible`, `unify`), fallibility, the raw boundary, elaboration of the five type-directed desugarings | 11,000 (about 14,000 of today's core, after the context change) |
| `typecheck/places.zig` | `placeOf`, `requireAccess`, binding access, `handleWritable` | 1,100 |
| `typecheck/views.zig` | the view-syntax rules (CORE §8 "the sigil leads the path"): `checkViewBases`, `viewsBranch`, the branch-view deciders, `cellMadeAway`, `misplaced` homes | 1,400 (2,837 for places and views together) |
| `typecheck/builtins.zig` | typing of symbol-less built-in methods: element methods, String operations, Simd, Cell and Signal, Table and Slot, number and enum functions, bits | 1,800 (1,928) |
| `typecheck/stdforms.zig` | `par`, `isolate`, `select`, `http.serve`, `io.copy`, actors, supervise, reduce: everything `synthMemberCall` reaches by name | 1,200 (1,611) |
| `typecheck/apis.zig` | conformance, witnesses, erasure checks | 900 (1,037 + sema's associated-type code) |
| `generics.zig` | requirements, instance checks, bounds | 1,600 (1,435 + `sema.Requirement`) |
| `hints.zig` | fix-its and message builders (`ViewBaseFix`, `staticHint`, the `plainText`-style helpers) | 1,300 (1,583) |
| → `lower` | `readLeaf`, `viewTemp`, `viewTempIn`, `checkWriteView`, `recordTempDrop`, `copiesHeader`, `rejectHeaderCopy`, header classes (`headerOf`, `heldBaseOf`, `takesSubject`), `useOf` | leaves typecheck (649 + the header code) |
| → `frames.zig` over BIR | `recordFrameOwners`, `checkFrames`, `FrameWalker` | leaves typecheck (406) |
| → `cteval.zig` | `checkCtFun` (404 lines, which duplicates `checkModule`'s setup, `typecheck.zig:84`) and float folding | leaves typecheck (1,126) |

**Context as a value.** One `Expect` struct passed down `synthExpr`/
`checkExpr`, holding the expected type, use (read/take/view), whether the
value is discarded, whether it is handled (`catch`/`!`), the statement
it belongs to, the self being viewed, and the argument being viewed. It
replaces the 34 sentinel fields and their 85 restores. A trial check
then needs no `quiet` guard on facts, because a trial writes into a
scratch `Record` layer that is dropped, or merged on success. This is
the mechanical half of the review's "context passed down"
(`compiler-review/rewrite-review.md`, finding 3). Inference variables, the
other half, are a behaviour change and are not part of the split.

---

## 6. Line budgets

Total lines including doc comments, excluding in-file unit tests, which
move to `test/` or stay as they are and are counted apart. The budgets
come from what each part must do and from comparable code that exists
(the oracle's lowering, core, and flow), not from scaling today's files.

| Pass | Budget | Today | Reasoning |
|---|---|---|---|
| `types/` (store, program-wide interner, `TypeInfo`, contents, type facts, view reach) | 6,500 | about 9,000 of sema (types, what values hold, type queries, view reach) | One table, so no `imported_nominal` (45 sites in sema). View reach is earned complexity (CORE s7) and keeps its memo |
| `declare` (built-ins once, symbols, scopes, declarations, declared-type rules) | 5,000 | 5,930 resolve + about 1,750 of sema (symbols, entry points) | Built-ins registered once per program; no callback into typecheck for compile-time functions |
| `record.zig` (columns, keys, seals) | 1,200 | about 4,700 (sema's fact types, `Question`/`Decided`, `SemContext` methods) | Columns are declared, not hand-written as record/query method pairs; storage and decisions leave |
| typecheck core | 11,000 | about 14,000 | Context as a value; elaboration replaces the re-check bookkeeping; no storage questions |
| places + views | 2,500 | about 2,837 | Rules kept; one place walker shared with lowering |
| builtins | 1,800 | about 1,928 | Kept; the `builtin` column replaces its fact maps |
| stdforms | 1,200 | about 1,611 | Kept; one dispatch table |
| apis | 900 | about 1,037 + sema | |
| generics | 1,600 | about 1,435 + sema's `Requirement` | |
| hints | 1,300 | about 1,583 | Moved, not cut much: the messages are earned |
| cteval (the one evaluator) | 2,300 | 2,175 + three other evaluators (about 600) | Partial mode added; three evaluators deleted |
| `bir.zig` (definition, text form, verifier) | 900 | 0 | New |
| `lower.zig` | 5,500 | storage 2,774 + typecheck's temporaries and headers (about 1,000) + sema's `handsOver`/`viewsOf`/`moveSource`/`stmtTemps` (about 1,800) + emit's ordering and address logic (unknown, at least 1,500) | The oracle's `lower.zig` is 4,972 lines without storage, coercions, or diagnostics |
| ownership | 6,500 | 9,768 | Reads BIR: no name resolver, place walker, liveness walk, statement-temporary model, or call-hold model of its own. Rules and two-ended diagnostics kept (the oracle's core, flow, and kinds are about 2,150 lines with no fix-its) |
| proofs | 2,000 | 2,930 (about 760 tests) | Writes come from BIR ops; no unit cross-check machinery |
| frames | 400 | about 406 in typecheck | Counts BIR vars, not a prediction of Zig's |
| inlining / returns / words | 900 / 100 / 250 | 1,578 / 146 / about 300 | Inlining loses its evaluator; returns reads divergence from BIR |
| emit (BIR → Zig) | 7,500 | 12,537 | No mode flags, sentinels, address producers, built-in dispatch by name, or re-derived predicates |
| `layout.zig` (was `facts.zig`) | 600 | 1,655 | Type spelling only |
| **Total** | **about 60,000** | **85,422 (about 81,600 without tests)** | **About 26% smaller.** The three reviewers of 2026-10-31 estimated a third of this code was cruft. I kept every rule and message, so I land below their estimate |

`units.zig`, `symbols.zig`, `modules.zig`, `rig.zig`, the runtime, and
std are outside this table. `rig.zig` loses its type-directed desugarers
(`desugarIterLoops`, `desugarChains`, `desugarOptions`, `byteLiterals`)
to typecheck's elaborator. I did not measure their size.

---

## 7. The path

Every step names its kind: **I** (identity: `tools/emit-diff revamp-base`
prints identical and the diagnostics are unchanged) or **B** (behaviour).
They run in order. Steps on disjoint files may run in parallel, three
agents at most.

**Step 0, the pilot (I): typecheck's split, cut by decision owner, with
context passed as a value.**

- **PR a.** Move frames, std forms, APIs, generics instance checking,
  hints, built-in method typing, and `checkCtFun` out of `typecheck.zig`
  into the files of 5.3, each behind a narrow interface
  (`fn(*Checker, Sexp, Expect) Error!TypeId`).
- **PR b.** Replace the 34 sentinels and their restores with `Expect`.
- **Proof:** emit-diff identical on every program; the core suite green
  with the oracle silent; `bench/check/guard.py` within 2%; Trig's and
  loco's light gates.
- **Budget:** net −900 source lines or better.

Why this pilot:

- It is the default the rebuild page names, and I agree with it for a
  reason of my own. Every later step in my path needs these seams: the
  lowering decisions can leave typecheck only once its context is a value
  and its non-typing parts are out.
- It is pure identity. It touches the largest file and the most
  diagnostics, so it measures the process honestly: the pace, how often
  identity fails, and whether the deletion review finds real merges (the
  place walker, the duplicated `checkCtFun` setup).
- If it cannot hold identity at a sane pace, nothing later will.

**Step 1 (I): one key, one recorder.**

- Gives every rewrite-built node an id, so `decisionKey`'s address keys
  go.
- Introduces `record.zig` with writer-checked columns and seals.
- Moves `Facts`, storage, decisions, `proven`, `unit_of`, and the symbol
  flags typecheck writes behind it.
- `SemContext` keeps symbols, scopes, and types.
- Emit unchanged by construction. The check guard must not move.

**Step 2 (I): duplicate deciders, batched.**

- Ownership finds vars by `SymbolId` (deletes `names` and `find`).
- `print`/`warn` and `swap` identity read the `builtin` column.
- One place walker records root and path once; ownership's
  `resolvePlace` reads it.
- `old_nones` moves out of the ownership checker: the plan decides it
  where it decides `SetOrder.drops_old`, so the back-edge goes. This is
  identity only if the plan's rule equals the checker's flow result.
  Otherwise it is a B step with a case.

Each piece is its own small PR.

**Step 3 (I): the BIR in shadow.**

- `bir.zig` and `lower.zig` build a BIR for every body from today's
  record: storage facts, decisions, temporaries, units.
- The verifier asserts, in self-check builds, that the BIR's hidden vars
  are exactly the storage facts, and its units exactly `rig.eachUnit`'s.
- Nothing reads the BIR yet. It adds lines, and the PR says why: steps 5
  to 7 consume it within the same phase, or it is reverted. No layer is
  kept "for later".

**Step 4 (I, with a B fallback): sema once.**

- Typecheck elaborates the five type-directed desugarings where it finds
  them: it builds the subtree with the parser's `newNode`, declares the
  hidden bindings into the current scope through `declare`, and checks
  the subtree in place. Facts of the replaced sugar are orphaned ids.
- `modules.zig:892-902` is deleted.
- Identity holds if the hidden names are numbered in discovery order, as
  the rewriter numbers them today. Symbol ids change; emit names locals
  by their text, which I believe but have not verified.
- If emit-diff shows hunks, they are names only. The step then lands as
  B with every hunk classified "neutral".
- Expected gain: one fewer typecheck and resolve per module that has any
  of the five forms. Its size on Trig is unknown; measure with
  `rig check --time` before the step.

**Step 5 (I): proofs read the BIR.**

- Units and writes come from BIR ops. `recordWrite` stays only as long
  as the symbol flags need it, then goes.
- The proven bits must be identical, and emit-diff proves they are.

**Step 6 (I, several PRs): emit reads the BIR, construct by construct.**

- Order: statement temporaries, headers, calls and arguments,
  assignments, `match`, loops, closures.
- Each PR deletes the storage-fact reads, mode flags, sentinels, and
  address producers its construct used.
- The last PR deletes `enterUnit`, `inUnit`, and `checkUnitOrder`, which
  the shared BIR makes unnecessary.

**Step 7 (I): `lower` decides; storage dissolves.**

- `storage.zig`'s deciders move into `lower`, which now builds the BIR
  from the typing record alone.
- `Question`, `Decided`, `decideAt`, and `verifyDecisions` are deleted.
  The BIR verifier runs in self-check builds.
- Because nothing is decided lazily any more, the open policy question
  (check-creep: `verifyDecisions` costs 5.2% in release builds)
  disappears. Expected: `rig check` faster by at least that.
- This step is the hard one in my lens. Typecheck still asks storage
  questions (`rejectHeaderCopy`, the frame walker, `arm_view`), so those
  callers must ask `lower`'s pure functions instead, unrecorded, until
  step 9 moves them.

**Step 8 (I): ownership reads the BIR, with today's verdicts.**

- Today's textual liveness is reproduced from the spans on BIR ops, so
  verdicts and messages stay identical.
- Ownership loses its name resolver, place walker, temporary model, and
  call-hold model.
- Its files are laid out by CORE (8a below).

**Step 9 (B): CFG liveness, and loans ended at their last use.**

- The owner accepted ending statement-long loans at their last use for
  the new design (`compiler-review/rewrite-review.md`, decision 4).
- It accepts the liveness group of differences (about 25) and some of
  the statement group.
- Proof: the oracle silent; every newly accepted program a case that
  runs clean under `RIG_SANITIZE=1`; `differences` shrinks.
- No program a release accepted is rejected. If the corpus finds one, it
  is a release-notes item with a note to Trig first.

**Step 10 (B): lowering rejections move out of typecheck.**

- `rejectHeaderCopy` and the temporary rejections become `lower`
  diagnostics.
- In a program with both a type error and one of these, only the type
  error is reported now. Cases with `errors: N` may change, and each
  change is listed.
- After this step typecheck imports nothing from `lower`.

**Step 11 (B): frames from the BIR.** `FrameWalker` and `reach_factor` are
deleted, and frames count real vars. Frame accounts change, so inlining
decisions may change emitted `inline`. Needs the guards, and a race if
any hot function changes.

**Step 12 (B): one evaluator.** cteval gains its partial mode, and the
other three evaluators are deleted. This may change what inlining's
guards fold, so it needs emit-diff hunks classified and the guards.

**Step 13 (I): one program-wide type table.** It removes
`imported_nominal` and the per-module built-ins. This belongs to the
front-end expert's lens. I list it because `types/`'s budget assumes it.

**8a. Ownership laid out to fit CORE.**

| File | Holds | CORE |
|---|---|---|
| `ownership/state.zig` | `Var`, `Flow`, `Loan` (root plus path), trail, `Point`, join | the preface, sentences 5 and 6 |
| `ownership/live.zig` | backward liveness on the BIR's CFG view; whether a holder is live | sentence 6 |
| `ownership/transfer.zig` | one transfer function per BIR op: copy (s1), move/clone (s2), drop (s3), view (s4), store (§5), call (s7), share/weak (s8), mark (s9), propagate (s10) | sentences 1 to 10 |
| `ownership/rules.zig` | one positive predicate per rule, each with its sentence cited, and the table of which ops can break it | the rules, as the oracle's `Rule` enum names them |
| `ownership/origins.zig` | `checkOrigins`, `carry`, reach queries | sentence 7 |
| `ownership/exits.zig` | the one exit primitive | CORE §9 "per path, one exit primitive" |
| `ownership/generic.zig` | `plain_reqs`, callables, items | SPEC "Generic bodies" |
| `ownership/notes.zig` | the two ends of a view, messages | |

With this layout CORE §10's test can be audited. A feature that fits the
Core adds BIR ops, and if it adds a rule, it adds a row to `rules.zig`
with a sentence.

---

## 8. Considered and rejected

- **The ownership checker and the oracle sharing one lowering, or
  merging.** Rejected. The oracle's value is that it shares none of the
  compiler's ownership code (INTERNALS "The reference ownership
  checker"), and AGENTS.md forbids weakening it. The BIR is the
  *emitted* program: the compiler's checker reads it, so it checks what
  is emitted. The oracle lowers the *source's meaning* on its own, so a
  lowering bug cannot hide in both. The structures converge. The code
  must not.
- **A typed copy of the tree (a new typed AST).** Rejected in favour of
  columns on the immutable AST keyed by node id. A copy would double the
  front end's memory on Trig, and the `--facts` dumps, the oracle's
  reader, and `rig normalize` already read the AST.
- **A basic-block, SSA lowered IR.** Rejected for the BIR. Emit's
  identity proof needs the structure Zig is written in, and the proof
  walk follows the skeleton. Ownership derives a CFG view for liveness.
  An SSA form for LLVM can be built from the BIR later.
- **Keeping lazy decisions plus `verifyDecisions` as the safety net.**
  Rejected: it exists because no single pass owns the decisions
  (review-ownership-emit §2f). With one owner the safety net has nothing
  left to catch. Simply turning it off in release builds is the policy
  question check-creep sent to the owner (5.2% of instructions). My
  design dissolves the question instead of answering it.
- **Moving only the files, without moving the decisions.** Rejected as an
  end state ("dissolve, don't patch"), though steps 0 and 3 start that
  way to keep each step provable.
- **Checking generic bodies against their bounds only.** This is a
  language change. The owner kept per-instance checking
  (`compiler-review/rewrite-review.md`, decision 1). Out of scope.
- **Inference variables in typecheck.** They would change which programs
  infer, so this is behaviour with acceptance risk. Not part of the
  split. A possible later B step.
- **Declaring std forms in std** through effect-polymorphic signatures.
  That is a language feature, out of scope. The forms are isolated in
  `stdforms.zig` instead.
- **A one-arena compiler.** Measured negative: 2.1 GB against 0.65 GB
  peak on Trig, and it hid a wrong free (`check-speed/README.md`).
- **Parser reuse across modules (row 37).** About 1.2% of a check at
  best, and impossible while every tree lives to emit
  (`compiler-review/parser-reuse-deferred.md`). The BIR makes it
  possible, because a module's tree can be dropped once its BIR and
  record exist. Not a goal of the rebuild.
- **New proof rules during the rebuild.** Spans and false-edge proofs
  measured within noise (#686, #687, `perf-stage/proofs.md`). Rules (a)
  to (c) of the check ceiling were held by the owner (`check-ceiling/`).
  The BIR makes a per-method write summary cheap (S1 there), but that is
  a phase E behaviour step at most.
- **Hashing keys as bytes, or keying facts by pointer.** Measured
  negative (check-speed: 35% fewer instructions from the one-multiply
  hash). Address keys are also how `decisionKey` keys rewrite-built
  nodes today, and the one-key step removes them.
- **Running the oracle on the BIR to speed it up.** Rejected for the
  independence reason above.

---

## 9. Risks, and what would make me stop

1. **Identity of emit through the BIR (steps 3, 6, 7).** Emit's hidden
   names and slot numbers follow its walk order today. The BIR must
   number them in the same order. *Stop:* if one construct's move fails
   identity twice for the same reason, step 6 stops, and the BIR is
   revisited for that construct before any other moves.
2. **Ownership verdict identity (step 8).** Reproducing textual liveness
   over the BIR may need span bookkeeping that is as tangled as today's.
   *Stop:* if two attempts fail, merge step 8 into step 9 as one
   behaviour step with the oracle as the gate. Accept more, never less,
   with every new acceptance a sanitizer-clean case.
3. **Compiler speed and memory.** The BIR adds a structure per body.
   Trig's check peaked at 0.65 GB after #834, and that number is from
   2026-10-31; revamp-base's is in its baseline record, which I did not
   read. *Bar:* `lower` plus the BIR cost no more than today's storage
   pass plus `verifyDecisions`, and peak RSS rises by no more than 5%.
   *Stop:* the check guard more than 2% over `revamp-base` after step 7.
4. **Hidden coupling through `SemContext`.** About 176 fields are shared
   by every pass, and some are written by passes that should only read
   (typecheck writes symbol flags at 32 sites, per the October review).
   Step 1's writer-checked columns will surface couplings nobody has
   listed, and each one is a small design question. *Stop:* if step 1
   needs more than a handful of exceptions to compile, the column
   ownership table is wrong and is redesigned, not patched.
5. **Diagnostics.** Messages and positions are part of the suite (`fail`
   cases, `test/hints.py`). Every BIR op must carry its span, and the
   two-ended notes must find the same holder. A lost note is a failed
   identity.
6. **Sema once (step 4).** The second check may be hiding order-dependent
   facts: unread locals, rebinds, and generic expansion over the
   desugared tree. *Stop:* if it is not identity or names-only after two
   tries, keep the loop and move on. Its gain is unmeasured.
7. **The oracle.** It is never weakened. A BIR-based checker accepting
   what the oracle rejects is a soundness hole: the step stops and is
   bisected.
8. **Trig.** It builds at every commit. Every compiler step runs Trig's
   and loco's light gates.

What I am least sure of:

- the true size of emit's ordering and address logic that moves into
  `lower` (unknown, so `lower`'s budget may be low by 1,000 lines);
- whether the five desugarings can be checked in place without changing
  any diagnostic;
- how much of typecheck's 595 ownership-shaped diagnostics are truly
  type-structural (they stay) rather than lowering (they move).

Each is answered by the first step that touches it, and the stop rules
above say what happens if the answer is bad.
