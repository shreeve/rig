# Phase B, expert A: the pipeline and the IR

The compiler Rig should have been, designed from a blank page with what is
known now, and the path to it from `revamp-base` (645996606) in steps that
each prove themselves. My lens is the pipeline and the IR: the passes, their
order, what each hands the next, whether sema runs twice, how modules are
checked, and how the parser wrapper relates to the grammar. The other parts
are covered more briefly.

Every claim about today's code cites `file:line` in the read-only tree at
`~/Data/Code/worktrees/rig/revamp-base-ro`. Line counts include doc
comments; "non-test" leaves out the inline `test` blocks. Where I did not
measure something I say "unknown" or "estimated".

---

## 1. Today, as found

### 1.1 The passes and their sizes

| Pass | File(s) | Lines (non-test) | Reads | Writes |
|---|---|---|---|---|
| Grammar | `rig.grammar` | 1,466 | | generated `src/parser.zig` |
| Lexer wrapper | `src/rig.zig:1073-2703` | 1,630 | `BaseLexer` | tokens |
| Parser wrapper | `src/rig.zig:3235-6815` | 3,580 | the raw tree | the semantic IR, plus 7 side tables on `Parser` |
| IR helpers | `src/rig.zig:28-1073` | about 1,045 | | |
| Modules | `src/modules.zig` | 1,162 | files | `Module`s, check order |
| Sema front door | `src/sema.zig` | 18,124 | the tree | `SemContext` |
| Resolve | `src/resolve.zig` | 5,902 | the tree | symbols, scopes, declaration types |
| Typecheck | `src/typecheck.zig` | 25,928 | the tree, `SemContext` | facts, decisions, *the tree* |
| Cteval | `src/cteval.zig` | 2,175 | the tree | compile-time values |
| Storage plan | `src/storage.zig` | 2,766 | the tree, facts | storage facts, decisions |
| Ownership | `src/ownership.zig` | 9,498 | the tree, facts, storage predicates | diagnostics, *facts in sema* |
| Proofs | `src/proofs.zig` | 2,236 | the tree, facts | proof facts in sema |
| Program-wide | `inlining.zig`, `returns.zig`, `units.zig`, `symbols.zig` | 1,908 | every module | *facts in each sema* |
| Facts (emit's view) | `src/facts.zig` | 1,292 | `SemContext`, storage predicates | |
| Emit | `src/emit.zig` | 12,428 | the tree, `Facts` | Zig text |

The core compiler (front end to emit, with `diag`, `fastmap`, `timing`,
`nametable`) is 95,128 lines with 4,219 of inline tests, so about 90,900
non-test, plus the 1,466-line grammar: **about 92,400 lines**. The CLI and
tools (`main`, `lsp`, `editor`, `frames`, `bolt`, `pgo`, `map_trace`, `lib`)
add 6,938 and are outside this design.

### 1.2 The pipeline as it runs

`ModuleGraph.check` (`src/modules.zig:861-953`) is the real pipeline for one
module, and `main.zig:948-970` adds the program-wide passes:

1. `sema.check` (`src/sema.zig:6684-6747`) runs, in order:
   `registerBuiltins` (every module, `resolve.zig:5268`), `resolveSymbols`,
   `resolveDeclarations`, `computeContents`, `checkInfiniteTypes`,
   `checkOptionalLoops`, `checkTypeSizes`, `computeOrigins`,
   `checkDeclarations`, `recordCellObjects`, then `typecheck.checkModule`,
   `recordFrameOwners`, `checkFrames`, `checkUnreadLocals`,
   `checkDeclaredApis`, `computePlainBits`, `expandInstantiations`,
   `recordInstancePlain`, `checkGenericInstantiations`, then
   `storage.plan` (`sema.zig:6738`), then `indexAllMembers`,
   `recordTypeWitnesses`, `recordPlainFacts`. Storage is planned *inside*
   sema, before ownership.
2. **The loop.** While typecheck found any of five type-directed rewrites
   (iterator loops, byte literals, chains, option groups, spreads), the
   Parser wrapper rewrites the tree in place and `sema.check` runs again
   from nothing, discarding the old context (`modules.zig:892-902`).
3. `checkEmbeds` (`modules.zig:904`).
4. If sema reported a type error, ownership is skipped (`modules.zig:908-911`).
5. The ownership checker walks the tree (`modules.zig:913-916`), and its
   results are written *back into sema*: `plain_reqs`
   (`modules.zig:942`) and `old_nones` (`modules.zig:944-946`).
6. Proofs, on a checked module, write `proven` and friends into sema
   (`modules.zig:952`).
7. Program-wide (`main.zig:948-970`): `storage.decideWords`,
   `storage.decideExactEnums` (`storage.zig:2656`, `2697`),
   `inlining.decide` (`inlining.zig:1467`), `returns.decide`
   (`returns.zig:104`), `markTextTables`; later `units.decide`
   (`main.zig:1021`). Each writes into every module's `SemContext`.
8. Emit, per module, through `Facts.of(m.sema)` (`main.zig:2233`).

### 1.3 What each pass hands the next

- **Parser wrapper → everyone.** A Nexus `Sexp` tree, plus side tables on
  `Parser` that sema reads through `ctx.parser` (`sema.zig:4284`):
  `pad_homes`, `self_sigils`, `loop_names`, `group_targets`,
  `paren_suffixes`, `detached`, `prelude_names` (`rig.zig:3235-3285`).
  Typecheck reads them (`typecheck.zig:6194`, `9961`, `19091`).
- **Sema → everyone.** One `SemContext` with **165 fields**
  (`sema.zig:4281-6574`). Inside it, four recorders that do one job in
  four ways:
  - `Facts`: **75 hash maps** (`sema.zig:1915-2154`), keyed in three
    spaces: a leaf's source position, a list node's id with bit 32 set, or
    the address of a rewritten node's items with bit 33 set
    (`decisionKey`, `exprKey`, `sema.zig:1879-1907`).
  - `Decided`: **36 `Question`s** (`sema.zig:2505-2622`), answered on
    first ask through a `*const SemContext` and chained by node
    (`sema.zig:2665-2727`), then all asked again by
    `storage.verifyDecisions` (`storage.zig:1615-1630`) to catch two passes
    that acted on different answers.
  - Storage facts: a `FastMap(StorageKey, Storage)` (`sema.zig:2730`,
    field `storage`), 34 kinds.
  - Proof facts: `proven`, `proven_if`, `flags`, `unit_of`, `unit_roots`,
    each its own map on `SemContext`.
  - Plus program-wide decisions parked per module: `inlined`,
    `never_returns`, `split_units`, `inline_*`, `text_tables`,
    `exact_enums`, `word_held`.
- **Ownership → emit.** Nothing direct; it writes `old_nones` into sema,
  which emit reads to leave out a drop.
- **Facts → emit.** `facts.zig` (about 235 `pub fn`s) wraps the context;
  a tokenizer test keeps emit from importing anything else
  (`facts.zig:1282`). But `facts.zig` itself imports `storage.zig` and
  `sema.zig` (`facts.zig:32-35`) and answers some questions by calling
  them.

### 1.4 Findings that shape the design

1. **Sema runs twice on any module that iterates a Map.** A `for` over an
   iterator, a byte literal, a chain, an option group, or a spread sends
   the module round the loop at `modules.zig:892-902`, which reruns
   everything, `registerBuiltins` and resolve included. The trigger is
   common: `Map.items()` and `values()` return iterator objects
   (`std/prelude.rig:177`, `185`, `297`), and Trig's `checker` module
   (68,153 lines, the largest) iterates one
   (`trig/src/checker/nodebuilder.rig:1039`, `for types in
   ?seen_names.values()`), as do `ast` (`ast/prebuilt.rig:81`) and
   `compiler` (`compiler/program.rig:945`). So, by reading (not
   measuring), Trig's largest modules pay two full checks. The share of
   `rig check` time this costs is **unknown**; it is the first thing the
   pilot measures.
2. **Typecheck mutates the tree while it checks it.** `padLambda`
   (`typecheck.zig:22585`) and `dropTail` through a `@constCast`
   (`typecheck.zig:22647`). The tree's shape depends on how far typecheck
   has got.
3. **Trial checks keep their side effects.** `synthQuiet` drops the
   diagnostics but keeps every fact and decision it recorded
   (`typecheck.zig:3281-3288`; 30 uses). This is why decisions are
   memoized on first ask and verified later.
4. **Evaluation order is modelled four times.** The storage plan decides
   hidden storage and order (`storage.SetOrder`, the hoists); the
   ownership checker calls 31 storage predicates directly
   (`ownership.zig:143`) and models holds and statement temporaries
   itself (`holdForCall`, `ownership.zig:5908`); proofs cut bodies into
   units (`rig.eachUnit`, `rig.zig:367`) and read `storage.eachSetStep`
   (`proofs.zig:65`); emit writes the order and asserts it stays inside
   proof units. weak-spots.md lists "evaluation order versus what is
   emitted" as an area reviewers keep finding problems in.
   `verifyDecisions` exists because these can disagree; it costs 5.2% of a
   release `rig check` (records/2026-11/check-creep).
5. **Emit still decides by name.** `len` is lowered by field name and type
   shape (`emit.zig:7960-7979`); there are 52 `std.mem.eql(u8, ...)` in
   emit. The 2026-10-31 review found more (whether a binding is used,
   built-ins by name, pointer or copy).
6. **Per-module type stores with proxies.** Each module interns its own
   types and copies others' in through `importType`, `proxyOf`,
   `importSymbol` (`sema.zig:15075`, `15168`, `15185`); built-ins are
   registered again in every module (`resolve.zig:5268`), with 23
   `*_sym_id` fields on `SemContext`. Generic instances are expanded,
   checked, and ownership-checked in each importer
   (INTERNALS, "Constants").
7. **Finished contexts are not finished.** Ownership, proofs, and four
   program-wide passes write into a `SemContext` after sema returned it
   (`modules.zig:942-952`, `main.zig:948-970`).
8. **The oracle already lowers.** `test/oracle/lower.zig` (4,972 lines)
   lowers each body once into vars and straight-line ops, with every
   statement temporary a hidden var and the evaluation order written out
   (`lower.zig:1-15`, `core.zig:1-4`), and its dataflow (`flow.zig`, 919
   lines) checks CORE's rules on that alone. The lowered form is proven
   to carry the ownership model.

The 2026-10-31 review (records/2026-10/compiler-review/rewrite-review.md)
found findings 1-6 independently, and estimated a third of the checker and
emit to be cruft. What it did not have was a path that keeps Rig working at
every commit; that is most of this document.

---

## 2. The ideal pipeline

### 2.1 Passes, in order

```text
             per file           program-wide           per function             program-wide     per module
source ─► lex ─► parse ─► normalize ─► declare ─► elaborate ─► instances ─► lower ─► ownership ─► proofs ─► decide ─► emit (Zig)
          (Nexus + wrapper)            (resolve)   (typecheck)              (LIR)                            [later: LLVM]
```

| # | Pass | Consumes | Produces | Granularity |
|---|---|---|---|---|
| 1 | **lex** | bytes | tokens (layout, contextual words) | file |
| 2 | **parse** | tokens | syntax tree (Nexus `Sexp`) | file |
| 3 | **normalize** | syntax tree | the semantic tree, rewritten only syntactically, plus *node marks* (bit columns by node id) | module |
| 4 | **declare** | every module's semantic tree | the program table: one symbol table, one type store, declarations, contents, sizes, origins | program, modules in dependency order |
| 5 | **elaborate** | semantic tree + program table | the typed tree: the same tree with type-directed desugarings applied at their sites, and the fact columns | function |
| 6 | **instances** | typed trees | each generic instance once: requirements, sizes, plain bits | program |
| 7 | **lower** | typed tree + facts | **LIR**: structured regions of ops with explicit locals (named and hidden), explicit order, explicit drops and defers, explicit checks, explicit views, copies, and moves | function |
| 8 | **ownership** | LIR + types | diagnostics; annotations on LIR ops (`drops_old`); plain requirements | function |
| 9 | **proofs** | LIR | the proven bit on LIR check ops | function |
| 10 | **decide** | every function's LIR | the program decisions: inline set, never-return set, word-held objects, exact enum tags, split units, symbols, text tables | program |
| 11 | **emit** | LIR + layout + decisions | one Zig file per module | module |

`rig check` stops after 9 (or 10, for the diagnostics `decide` reports, such
as an `inline` cycle). The language server stops after 9 for one module.

### 2.2 Why this order

- **Normalize before declare.** Every pass after normalize reads one tree
  shape. Today that holds only after the module loop ends.
- **Declare program-wide.** Rig rejects import cycles, so modules can be
  declared in dependency order into one table. One type store deletes the
  proxy machinery (finding 6), and each generic instance is checked once
  for the program instead of once per importer.
- **Elaborate is the only pass that may desugar by type.** A desugaring
  that needs a type (an iterator `for`, a byte literal, a chain, a group,
  a spread, a closure's padding and tail drops) happens where typecheck
  learns the type, and the desugared form is what typecheck then checks.
  Nothing downstream ever sees the sugar, and nothing is checked twice
  (2.4).
- **Lower once, before ownership.** Ownership, proofs, and emit read the
  same LIR, so "the checker checks exactly what is emitted" (North Star 4)
  becomes structural: there is one evaluation order, written once.
  `Decided`, `Question`, `verifyDecisions`, and the storage predicates
  shared by three passes all go.
- **Ownership on LIR is proven practice.** The oracle does it today
  (finding 8). Ownership diagnostics keep source positions because every
  LIR op keeps the span of the node it came from.
- **Proofs after ownership,** as today, because they rest on its
  acceptance (`modules.zig:950-952`).
- **Program-wide decisions in their own table,** never written into a
  module's facts after the fact (finding 7).
- **Emit prints.** It reads LIR, the layout of each type, and the program
  decisions, and decides nothing.

### 2.3 The IR at each stage

**The syntax tree** is Nexus's, unchanged in kind. The grammar builds every
node shape that one rule can build alone; today some of that is done later
by the wrapper. Inclusive ranges can be emitted as `(.. a b inclusive)` by
the rule's action, and type-parameter bounds can fill a `bounds` role in the
schema instead of being moved there by `Parser.boundsIn`.

**The semantic tree** is the syntax tree after normalize. It is the same
arena, and node ids are kept as today. Normalize does only the rewrites that
need a node's context but no type: `pub` on members, module-level bindings
as constants, the bar-list split into captures and parameters, the `for`
source sigil as the loop's mode, a statement `<e` as a drop, the `??` jump
regrouping, the self-sigil rule, methods attached from outside the body, and
the hidden `use` of the prelude. What normalize learns that the tree does
not hold becomes a **node mark**: a bit column indexed by node id (written
by the self-sigil rule, by a `paren` suffix, and as a loop name), never a
side table keyed by position and never a new schema slot. The records
rejected the schema slot because it changes the commonest nodes for every
reader (records/2026-10/compiler-review/ir-tags-deferred.md). A bit column
changes no reader.

**The typed tree** is the semantic tree plus the fact columns
(section 3). Where elaborate desugars, it writes the new subtree into the
same arena with fresh node ids from the parser's counter (as `newNode` does
today) and links it in place of the sugar. It is not a copy of the module.

**LIR** is Rig's own data structure, not Nexus's, so its ids are dense by
construction:

```text
Func   { sym, span, params: []LocalId, locals: []Local, body: RegionId }
Local  { name or hidden kind (one of today's 34 StorageKinds), ty, life, by }
Region { ops: []OpId }                      -- in order
Op     (struct of arrays: tag, ty, span, a, b, extra)
  place:    local, field(place, f), elem(place, i), deref(view), unbox(place)
  value:    const, read(place), copy(place), move(place), take(place),
            view_read(place), view_write(place), clone, box, share, weak,
            upgrade, lift(value, levels), call(callee, args, self_mode),
            intrinsic(enum, args), closure(env, fn)
  effect:   store(place, value; drops_old), drop(local | place),
            check(index | bytes | add; proven), panic, fail(error)
  control:  block(region, label), if(cond, then, else), loop(region, label),
            switch(subject, arms), break(label, value), continue(label),
            return(value), defer(region, on_error)
```

It is **structured**, not a control-flow graph. Zig has no `goto`, and
today's emit writes labeled blocks; a CFG would have to be put back into
structure for Zig, and identity would not survive that. Ownership already
works on structure (undo trail, loop fixpoint, `ownership.zig:1-60`), and an
LLVM backend turns structured regions into basic blocks in a few hundred
lines. Every built-in operation emit now finds by name (`len`, Cell
methods, element methods, String operations, tasks) becomes an `intrinsic`
with an enum tag, decided in elaborate (`builtinCallOf` and friends already
record most of them).

LIR never holds a type-directed sugar, a parenthesis, or a statement
temporary that is not a local. Every hidden storage location is a `Local`
whose kind names it (`__rig_tmp`, `__rig_hdr`, ...). The storage-facts table
of INTERNALS ("Storage facts") becomes the list of hidden local kinds.

### 2.4 Does sema need to run twice? No.

Today it does because the five rewrites need a type, typecheck is the only
pass that has types, and the rewriter is the Parser wrapper, which runs
before typecheck. So typecheck records the site, the wrapper rewrites the
tree, and the whole module is checked again (`modules.zig:892-902`). The
first run's facts for the module are discarded, and the first run checks
the loop body with the loop variable untyped (INTERNALS, "Loops over an
iterator").

Each rewrite is **local** to one statement or expression, and typecheck
knows it needs the rewrite at the moment it learns the type
(`Checker.iterLoop`, `typecheck.zig:4009`; `byteString`,
`typecheck.zig:20309`). So elaborate does it there:

1. **Mark.** Before checking a node that may need a rewrite (a `for`
   statement, a literal meeting an expected type, a call with a spread),
   take a mark in the recorder (section 3: a trail of every fact write,
   symbol, scope, interned type, and list append since the mark).
2. **Learn.** Synthesize what decides it (the `for` source's type).
3. **Rewrite or go on.** If no rewrite is needed, go on: nothing is
   undone. If one is, roll back to the mark, build the desugared subtree
   (the same builders as today, `Parser.desugarIterLoops`,
   `byteLiterals`, `desugarChains`, `desugarOptions`, moved out of the
   Parser into elaborate), make its symbols and scopes with resolve's body
   walker on that subtree (`resolve.zig:90`), and check the new subtree in
   its place.

Option groups change a function's parameter list, a declaration. A group is
an object known after declare, so its parameters are rewritten in declare
(before any body is checked); only its uses and spreads are rewritten at
call sites in elaborate.

The rules the desugaring implies stay the rules of the desugared form,
because the desugared form is what is checked (INTERNALS: "The checker
rules are the ones this desugaring implies"). This keeps today's guarantee
that no pass has a form of its own for an iterator loop.

The same trail makes `synthQuiet` honest: a quiet check rolls back what it
recorded (finding 3). That is a **behaviour** step of its own (7.2, F9),
because some decisions now first recorded in a quiet check may be relied on.

### 2.5 How modules are checked

- **Load** as today (`ModuleGraph`, worklist, dependency order, directory
  modules, embeds). `modules.zig` is sound (the review said so too) and
  stays.
- **Declare** every module in dependency order into the program table. A
  module whose import failed is not declared further (today's rule).
- **Elaborate** each module's functions after its imports are declared
  and its own declarations are done. Order across modules stays
  dependency order at first, so diagnostics come out in today's order;
  nothing in the design needs it.
- **Instances** once per program: the per-importer expansion
  ("an instance made here ... is expanded, checked ..., sized, and
  ownership-checked here", INTERNALS "Constants") becomes once per
  instance. The first module to make an instance owns its diagnostics.
- **Lower, ownership, proofs** per function, skipped for a module with a
  type error (today's rule, `modules.zig:908`).
- **Decide, emit** as in 2.1.

---

## 3. Facts

### 3.1 The facts that exist

Grouped by who should record them, from the 75 `Facts` maps, 36 questions,
34 storage kinds, the proof maps, and the program-wide fields:

| Group | Examples today | Recorder in the ideal |
|---|---|---|
| Names and scopes | `names`, `writes`, `rebinds`, `scopes` | elaborate (body), declare (module) |
| Types | `types`, `lifts`, `reads`, `views`, `slice_views`, `payload_copies` | elaborate |
| Calls | `call_slots`, `call_params`, `instances`, `generic_calls`, `ct_calls`, `elem_calls`, `builtin_calls`, `string_calls`, `swap_calls`, `durations` | elaborate |
| What an expression hands over | `hands`, `uses`, `headers`, `takes`, `loans`, `temp_drops`, `written_temps`, `in_place_reads` | elaborate (one classifier, `handsOver`, `sema.zig:16540`) |
| Std forms | `task_joins`, `par_calls`, `actor_*`, `chan_makes`, `select_*`, `isolate_calls`, `http_serves`, `io_copies`, `reduce_calls` | elaborate, then they become `intrinsic` ops in LIR |
| Storage and order | 34 storage kinds, `set_order`, `hoists_args`, `bind_hold`, `compound_call`, `reaches_leaf`, ... (most of the 36 questions) | **not facts**: LIR structure, made by lower |
| Ownership results | `old_nones`, `plain_reqs` | ownership, as LIR annotations and an instance table |
| Proofs | `proven`, `proven_if`, `flags`, `unit_of`, `unit_roots` | proofs, as a bit on LIR check ops; units are LIR statements |
| Per type | `TypeInfo`, `TypeMemo`, `byte_sizes`, `cell_objects`, `plain_bits`, ... | declare and instances, computed in phase order |
| Program | `inlined`, `never_returns`, `split_units`, `word_held`, `exact_enums`, `text_tables` | decide, in a program table |

### 3.2 Can facts, storage, and proofs share one recorder?

**Yes, as a step on the way; and in the end two of the three stop being
facts at all.**

- **On the way** (steps F1 and F8): one `Record`, a set of typed columns
  declared in one table. A list node's columns are arrays indexed by node
  id (`DenseMap`, as `types` and `Decided.by_list` already are since #834,
  records/2026-10/check-speed). A leaf's are `FastMap`s keyed by position,
  until every name a rewrite writes is a real node. There is one `put`, one
  `get`, a trail for mark and rollback, and a seal per phase: once a phase
  ends, its columns are read-only, so no answer can change after a reader
  saw it. The storage facts and proof facts move into this recorder
  unchanged; the three key spaces (`sema.zig:1879-1907`) become two
  (node id, leaf position), and the items-address key goes.
- **In the end:** the facts elaborate records stay in `Record` (they are
  the typed tree). The storage facts and the 36 questions become LIR
  structure: a hidden local, an op order, a `drops_old` bit. Proofs become
  one bit per check op. `Decided` and `verifyDecisions` are deleted, and
  with them their 5.2% of a release check (check-creep). The cost of a
  wrong order is no longer a panic at emit; there is one order.

### 3.3 How emit reads them

Emit imports `lir.zig`, `layout.zig` (how each type is held in Zig: a view as
a pointer or a copy, a word-held object, an optional's form), and the
program decisions. It cannot reach `Record`, sema, or any classifier. The
tokenizer test at `facts.zig:1282` stays, with a shorter allow list. Today
some `Facts` methods still compose recorded facts by node shape (`stmtTemps`,
`selfOf`, `argParams`, ..., INTERNALS "Emit"). In LIR those shapes are
already ops, so the list goes to zero.

---

## 4. Shared machinery

- **Walkers.** Today every pass has its own recursive walk over `Sexp`
  (`resolve.zig:90`, `storage.zig:1916`, `ownership.zig:3267`,
  `symbols.zig:45`, `cteval.zig:325`, `typecheck.zig:23926`, ...). In the
  ideal, two walks are hand-written per kind: elaborate (over the tree) and
  lower (tree to LIR). Everything after lower walks LIR, which has about
  25 op kinds against the schema's 94 node kinds, through **one region
  walker** with per-op hooks, shared by ownership, proofs, decide, and
  emit. Walks that only collect (names, symbols, typed-invalid checks) use
  one generic child visitor driven by the schema (`rig.children`).
- **Diagnostics.** One sink per module (`diag.zig`, kept), with today's
  dedupe of repeated messages (`SemContext.reported`) and the mapping of a
  synthetic node's position to its home (`Parser.homeOf`, used at
  `modules.zig:922-926`), owned by the sink rather than repeated in each
  pass.
- **Type queries.** One structural visitor: the children of a type and how
  each is held. Each type fact (`moves`, `copies`, needs cleanup, may hold
  a view, `viewHeldAsPointer`, contents, sizes) is a fold over it, computed
  in SCC order (`Components`, which is sound) once declarations are done.
  The review counted 163 hand-written `switch (ctx.types.get(...))` sites
  in sema (review-frontend.md, section 2). The lazy `TypeMemo` written
  through `*const` (`sema.zig:2632`) goes, because each fold is complete
  before its first reader.
- **The trail.** One undo log type serves the recorder (mark and rollback
  for elaboration and quiet checks) and the ownership checker, which keeps
  its own trail of flow writes today (`ownership.zig:1-15`).
- **Maps.** Dense columns first: most of the compiler's hash maps are keyed
  by node id or type id and become arrays. What stays sparse (leaf
  positions, interning, memo keys) uses `fastmap.Map`, which is std's table
  with a one-multiply hash (`fastmap.zig:1-12`). `src/unordered.zig` is
  Rig's own faster table (bench/hash's FOA layout), but it imports the
  runtime for Rig's `==`, hash, and drops (`unordered.zig:39`). **Should
  they be shared?** Only after the columns land and a profile shows the
  remaining maps matter. If they do, split `unordered.zig`'s table core
  (groups, tags, overflow bytes, growth) into a file with no runtime
  import, parameterized by a hash and eql context. The runtime keeps
  `UnorderedMap` as a wrapper adding Rig's semantics, and `fastmap.Map`
  becomes that core. One table, two users, and the runtime's speed guard
  watches it. Swapping first would be measuring a table the next step
  deletes. One trap: a pass that iterates a hash map and emits in that
  order would change emit; any swap needs an emit-diff, not only the check
  guard.

---

## 5. The back end

### 5.1 What emit consumes

LIR, `layout.zig`, and the program decisions (2.1, 3.3). Emit becomes a
printer: one function per op kind, plus type spelling, names
(`rig.writeZigIdent`, which moves into emit since only Zig needs it), error
glue, and the package writer. The per-function state of today's emitter (67
fields, `emit.zig:431-12125`, about 20 of them mode flags saved and
restored by hand, as the 2026-10-31 review counted) shrinks to the printer's position in a region, because
the modes were decisions (am I in a header, a value block, a yield, a cut
unit), and those are LIR structure now.

### 5.2 What LIR shares with a future LLVM backend

The memory notes record that the owner wants the LLVM backend in December
2026, with a private lowered IR first and the second backend behind a flag.
What the two backends share:

- **LIR itself**: control flow, locals, order, drops, checks with their
  proven bits, views and copies made explicit.
- **`layout.zig`**: how each type is held. A backend must agree with the
  runtime on it. Today it is spread through `facts.zig` and emit's type
  spelling (`emitTypeTy`, `emit.zig:11419`).
- **The program decisions**: inline set, never-return set, word-held
  objects, exact enum tags.
- **The intrinsic list**: one enum of runtime operations with their
  signatures. Emit spells each as a call into the Zig runtime; an LLVM
  backend would call a symbol.

What they do **not** share: Zig spelling, `writeZigIdent`, Zig's comptime
generics. That last point is the LLVM backend's largest unknown and does not
belong to this rebuild. The runtime's generic types (`rig.Task(T)`,
`UnorderedMap(K, V)`, `rig.String` operations) are instantiated by Zig's
comptime from the emitted text. An LLVM backend cannot call a comptime
generic; it needs the runtime's instances exported per type, or those
operations lowered in LIR. I would only make sure the intrinsic list names
operations rather than Zig spellings, so either choice stays open.

### 5.3 Where typecheck's 26,000 lines split

Typecheck is one `Checker` (95 fields, `typecheck.zig:115-22959`) followed
by free functions. Its seams, from its own layout:

| File | Today | Lines | Holds |
|---|---|---|---|
| `check/module.zig` | `typecheck.zig:62-1776` | 1,715 | module walk, constants, error fields, `add` methods, groups and spreads |
| `check/stmt.zig` | `1777-3270` | 1,500 | statements, bindings, assignment (`checkSet` 2366, `checkCompound` 2737, `checkPlaceAssign` 2620) |
| `check/flow.zig` | `3270-4800` | 1,530 | conditions, `if`, `while`, `for` (`checkFor` 3817, `iterLoop` 4009), jumps |
| `check/patterns.zig` | `4400-6000` | 1,600 | `match`, subjects, patterns, coverage |
| `check/expr.zig` | `6000-7900` | 1,900 | names, operators, equality, numbers, literals |
| `check/views.zig` | `7900-9220`, `19000-21700` | 4,000 | views and loans (`recordLoan` 7908, `checkWriteView` 8192), temporaries, erasure, kept sets, view bases |
| `check/calls.zig` | `9220-10640`, `11100-11300`, `12700-15820` | 4,700 | calls, targets, arguments (`checkArgs` 12817), inference, instantiation |
| `check/stdforms.zig` | `10640-11100`, `11300-12700`, `13800-14250`, `15820-19000` | 5,000 | the std forms typed by hand: tasks, `par`, `select`, actors, chains, durations, String, bit and SIMD calls |
| `check/closures.zig` | `22500-22960` | 460 | closures, captures |
| `check/compat.zig` | `22962-23713` | 750 | compatibility, classification |
| `check/generics.zig` | `23713-25144` | 1,430 | generic requirements, frames |
| `check/apis.zig` | `25144-25890` | 750 | APIs of a program's own |

(The ranges are where each concern lives, read from the function list. They
interleave in places and are approximate to 100 lines.)

Three rules make the split more than a move:

1. **The environment is passed down.** `no_hold`, `ternary_cond`,
   `plain_cond`, `else_conds`, `quiet`, `in_ct_fun`, ... are fields saved
   and restored by hand (for example `checkIfValue`,
   `typecheck.zig:3297-3320`). They become an `Env` value passed by value
   down the walk, so a helper's inputs are visible.
2. **`Checker` methods become free functions over `*Checker`** in their
   file. Zig has no partial structs and no `usingnamespace`.
3. **`stdforms.zig` is one file with one rule:** it is where the compiler
   knows the standard library by name, so a later change that moves that
   knowledge into std declarations has one place to empty. Moving it now
   would be a std or language change, which the rebuild does not make.

The split is pure code motion, so it is an identity step whose proof is
trivial. Its value is that later steps touch one file each.

---

## 6. Line budgets

Set from the design, then checked against what today's code does. All
non-test.

| Pass | Today | Budget | Reasoning |
|---|---|---|---|
| grammar | 1,466 | 1,500 | absorbs inclusive ranges and bounds; nothing leaves it |
| lexer | 1,630 | 1,500 | sound and a Nexus strength; the deletion review trims it |
| syntax diagnostics | about 1,000 (`rig.zig:3546-4265`) | 800 | foreign words, hints; their own file |
| normalize | about 1,500 (`rig.zig:4265-5756`) | 900 | side tables become marks; two rewrites move into the grammar |
| type-directed builders | about 1,060 (`rig.zig:5756-6815`) | 800 | move into elaborate; one builder API |
| IR helpers | about 1,045 | 600 | units and skeletons go to LIR; Zig names go to emit |
| diag | 233 | 300 | gains the home mapping and dedupe |
| modules and driver | 1,162 | 1,100 | stays; loses the loop and the write-backs |
| **front end** | **about 9,100** | **7,500** | |
| types (store, one visitor, folds, view table, tables) | about 9,760 (sema types, holds, queries) | 6,000 | one visitor; one store deletes proxies and `imported_nominal` cases |
| declare (resolve, symbols, scopes) | about 6,720 | 4,500 | built-ins once; program-wide |
| recorder (columns, trail, seals) | about 4,700 (`Facts`, recording API, `SemContext`) | 1,500 | one declared table of columns, one API |
| elaborate (typecheck, generics, APIs, `handsOver`, sema entry) | about 28,300 | 18,000 | no second-run seams, `Env` replaces save and restore, quiet checks honest, the reviewers' 25-30% cruft |
| cteval | 2,175 | 1,800 | one evaluator with a partial mode absorbs sema's folds, inlining's `valueOf`, typecheck's float folds (net across files) |
| **middle** | **about 51,700** | **31,800** | |
| LIR (types, builder, dump) | 0 | 800 | new |
| lower | 0 (storage 2,766, plus emit's, ownership's, and proofs' order logic) | 6,000 | replaces storage, an estimated 3,500 lines of emit's structural decisions, about 1,500 of ownership's order modelling, and proofs' unit walk |
| ownership | 9,498 | 6,000 | about 25 op kinds instead of every tree form; the oracle checks most of CORE in 6,100 lines on a lowered form |
| proofs | 2,236 | 1,600 | units are LIR statements |
| decide (inlining, returns, units, symbols, words, enums) | about 2,100 | 1,700 | a program table instead of writes into each module |
| emit and layout | 13,720 (emit 12,428, facts 1,292) | 8,500 | a printer per op (about 4,500), layout (1,000), types and names (1,500), glue and package (1,500) |
| **back end** | **about 30,100** (storage included) | **24,600** | |
| **total** | **about 92,400** (with the small files: `fastmap`, `timing`, `nametable`, the rest of `rig.zig`) | **about 63,900** | 31% fewer |

The prior review expected 30-40% smaller (rewrite-review.md, "Estimates").
The budget sits at the low end, because lower and LIR are new code (6,800
lines) that has to be paid for out of storage, emit, ownership, and proofs.
Inline unit tests are budgeted apart and are not cut to meet a budget.

---

## 7. The path

Each step is **identity** (the emit snapshot identical, every suite green,
the oracle unchanged, the check guard within 2%) or **behaviour** (a failing
case first, hunks classified). No step is both. Steps are grouped in three
tracks that touch different files, so three agents can work at once. Within
a track the order matters; across tracks only the dependencies marked.

### 7.1 Front track (F): sema once

| Step | Kind | What |
|---|---|---|
| F1 | identity | **One recorder API.** Every fact write in sema, typecheck, storage, ownership's write-backs, and proofs goes through `Record.put(column, node, value)`, the columns declared in one table. Storage stays as it is (the same maps). Add the trail: mark and rollback over fact writes, symbols, scopes, the type store's interning, and the module-level lists. Unused yet. |
| F2 | identity | **Byte literals elaborated at the site.** `byteString` rewrites the leaf and records its facts in place, with a rollback of what the literal's first check recorded. `SemContext.byte_literals` and its arm of the loop go. |
| **F3** | identity | **Iterator loops elaborated at the `for` (the pilot, 7.4).** `iterLoop` rolls back to the mark taken at `checkFor`'s start, builds the desugared statement, resolves its symbols and scopes with resolve's body walker, and checks it in place. `iter_loops` and its arm go. |
| F4 | identity | Chains, the same way (`desugarChains` moves into elaborate). |
| F5 | identity | Option groups: the parameter rewrite in declare, uses and spreads at call sites. |
| F6 | identity | Delete the loop (`modules.zig:892-902`); `padLambda` and `dropTail` become elaboration builders (no `@constCast`). `sema.check` runs once per module. |
| F7 | identity | Split typecheck into the files of 5.3, with `Env`. Code motion only. |
| F8 | identity | Columns dense by node id for every list-node fact (some are since #834); leaf facts stay keyed by position. |
| F9 | behaviour | `synthQuiet` rolls back. Any decision that first came from a quiet check and changes is a case. |
| F10 | identity | Normalize: inclusive ranges and bounds built by the grammar; the side tables become node marks; `rig normalize` output unchanged (`rig parse` changes for those two forms, a debugging command: classify as neutral). |

### 7.2 Middle track (M): one program table

| Step | Kind | What |
|---|---|---|
| M1 | identity | A program table for the program-wide decisions (`inlined`, `never_returns`, `split_units`, `word_held`, `exact_enums`, `text_tables`), read by emit, out of `SemContext`. |
| M2 | identity, one per fold | One structural type visitor; each type query rewritten as a fold over it, one query per step, each proven alone. |
| M3 | identity (diagnostics may differ, then behaviour) | One program-wide type store and symbol table; built-ins once; proxies deleted. If an instance's diagnostic now appears once instead of in every importer, that half is a behaviour step. |
| M4 | behaviour | One constant evaluator with a partial mode (records/2026-10/compiler-review/evaluators-deferred.md says why it cannot be identity). |

### 7.3 Back track (B): LIR

| Step | Kind | What |
|---|---|---|
| B1 | identity | **LIR as a transcription of emit.** Define LIR, and split emit into `lower` (builds LIR) and `print` (writes Zig) for one family of constructs at a time, keeping today's text exactly: plain expressions, then calls with held arguments, statement temporaries, headers, `match`, loops, closures, tasks, `select`. emit-diff after each family. The storage facts of a finished family are read from LIR locals. |
| B2 | identity | When every family is lowered, `storage.plan` and its predicates go; `Question`, `Decided`, `verifyDecisions` go. `--facts=storage` prints the hidden locals of LIR in today's format (the oracle and tests read it). |
| B3 | identity | Proofs on LIR: units are LIR statements, and the proven bit is on check ops. |
| B4 | identity (accept and reject identical) | **Ownership on LIR.** During the step, a self-check build runs the old and new checkers and compares their verdicts and diagnostics on the suite, the doc examples, and the corpus (`~/Data/Code/rigs.txt`); the old checker and the comparison are removed when the step lands. |
| B5 | identity | `facts.zig` shrinks to `layout.zig`; emit imports `lir.zig` and `layout.zig` only. |
| B6 | behaviour (phase E) | Inlining measured on LIR ops, not tree nodes; a Trig race. Then the LLVM backend, if the owner calls it. |

Dependencies: F1 before F2-F6 and B1; F6 before B1's families that touch
desugared forms (loops, chains); M1 before B5; B2 before B3 and B4.

### 7.4 The pilot: F3, iterator loops elaborated where typecheck finds them

I would pilot F3, with F1 and F2 landing before it as its two small
enablers, rather than the typecheck split.

- **It answers the design question this document hangs on.** If a
  type-directed rewrite can be elaborated at its site with emit
  byte-identical, sema runs once and the front track is safe. If it cannot,
  the design must change before twenty steps depend on it, and that is
  what a pilot is for (rebuild.md, phase C).
- **It is hard in the ways the rebuild will be hard.** It touches the
  recorder, resolve, typecheck, the Parser, and the module loop. It must
  keep symbol, type, and list numbering from reaching the emitted text,
  and it has a sharp proof.
- **It has a speed signal.** Every module that iterates a Map, Trig's
  `checker` among them (1.4, finding 1), stops paying a second sema run.
  The check guard and `rig check --time` on Trig both show it. The pilot
  first adds a temporary counter of sema rounds per module, removed in the
  same step, so the gain is known before the code is written.
- **It removes lines:** the loop arm, `iter_loops`, the first run's
  untyped loop variable, and the second `registerBuiltins`.

The typecheck split (F7) is pure motion. Its proof cannot fail, so it
measures the process's pace but not whether identity holds under redesign.
It also goes better after F2-F6, when the elaboration code has found its
home.

**What could break identity in F3, and what I would check first:**

1. **Symbol order.** Today the second run's resolve walk makes the hidden
   binding `h` and the new block's scope in tree order. In F3 they are
   made when typecheck reaches the loop. Emit names locals from symbol
   *names* and its own counter (`Emitter.fresh`, `emit.zig:2361`), not
   from symbol ids, and iterates `symbols` only for module-level error glue
   (`emit.zig:153`), so I expect no text change. Unverified.
2. **Type id order.** The first run's interned types survive in F3 unless
   rolled back. F1's trail covers interning, so the store is truncated at
   rollback. Whether emit's text depends on type id order is **unknown**.
3. **List append order** (generic uses, instances, frames). A rollback to
   the statement's mark and a re-check in place append in the same walk
   order as the second run does today, so the order should match.

### 7.5 Running order for three agents

```text
agent 1 (front):  F1 → F2 → F3 (pilot) → F4 → F5 → F6 → F7 → F8 → F10 → F9
agent 2 (middle): M1 → M2 (folds, one by one) → M3 → M4
agent 3 (back):   waits for F1; B1 (families) → B2 → B3 → B4 → B5
```

---

## 8. Considered and rejected

| Idea | Why not |
|---|---|
| A hand-written parser | The owner keeps Nexus (rewrite-review.md, decision 5); the grammar and node marks remove the side tables, which were the reason to want one |
| Lower before typecheck, so the desugarings are syntactic | Iterator-ness, byte literals, chains, and spreads all depend on inferred types (a local's type, an expected type); no pre-pass can know them |
| Typecheck builds a full typed copy of each module (a separate HIR) | Doubles the tree's memory for the 95% of nodes no desugaring touches; the typed tree is the semantic tree plus columns, with desugared subtrees linked in |
| A CFG lowered IR (the oracle's basic blocks) as the only form | Zig needs structured control flow; rebuilding structure from a CFG would not keep emit identical, and ownership already works on structure |
| Keep ownership on the tree and lower only for emit | Leaves two models of evaluation order, so the checker would still check something other than what is emitted; `verifyDecisions` would stay |
| Keep `Decided` and make `verifyDecisions` self-check only (5.2% of a release check) | An owner decision for today's code (check-creep); in this design both go, so the policy question dissolves |
| Swap `fastmap` for `unordered.zig`'s table now | Most maps become dense columns first; measure what is left before choosing a table |
| Parser reuse (Nexus `reset`) for `rig check` | Closed: trees live through the pipeline, and the prize is about 1.2% of a check (records/2026-10/compiler-review/parser-reuse-deferred.md); after lowering frees trees it could return, as an idea row |
| One arena for the compiler | Measured: it hid a wrong free and kept 2.1 GB resident against 0.65 GB on `smp_allocator` (records/2026-10/check-speed). A per-function arena for LIR in `rig check`, freed after proofs, is allowed but must be measured |
| A schema slot for the self-sigil and paren facts | Rejected in the records for changing the commonest nodes for every reader (ir-tags-deferred.md); node marks give the same with no reader changed |
| Moving the std forms typed by hand into std declarations during the split | A std or language change, not a rebuild step; `stdforms.zig` keeps them in one file for later |
| Inlining measured on LIR inside an identity step | It changes which functions inline, so emitted code; it is B6, a behaviour step with a race |
| Checking modules in parallel | The compiler is single-threaded, `rig check` of Trig is about 2 s, and nothing here needs it; it would change diagnostic order |
| One evaluator inside the identity path | Unifying the four evaluators changes what folds (evaluators-deferred.md); it is M4 |
| Self-hosting | Out of scope (rebuild.md, decision 4) |

---

## 9. Risks, and what would make me stop

**Risks**

1. **B1 is the largest step, and emit's text is the proof.** Today's emit
   makes hundreds of small shape choices (value blocks, `rig.keep(&slot,
   &flag, value).*`, labeled header blocks). LIR must carry every one of
   them, or the printer must make it from LIR alone. Lowering one family at
   a time keeps each diff small. If a family needs LIR to say "print it the
   old way", LIR is too weak there and needs a better op, not a flag.
2. **B4 changes the checker that guards memory safety.** Its proof is
   accept and reject identical, with the same message and position, on the
   suite, the doc examples, the corpus, and Trig; the oracle stays the
   independent second opinion and is never weakened.
3. **`rig check` speed.** Lowering is a new pass in `rig check`. It must be
   paid for by what goes: the second sema run (F6), `storage.plan`, and
   `verifyDecisions`. Each step runs the check guard against the
   committed baseline. On the order of costs, I expect the front track
   alone to make Trig's check faster, but that is an estimate until the
   pilot's counter reports.
4. **Memory.** `rig emit` and `rig build` hold every function's LIR until
   emit. It must be compact (struct of arrays, about 16-24 bytes an op) and
   lower than the storage and decision maps it replaces (`Decided` alone
   was 5.2 million entries on Trig before #834). Trig's peak for emit is
   the bar.
5. **Identity through renumbering** (7.4). Symbol, type, and list order
   must not reach the text. If one does, that is found in the pilot.
6. **Three tracks, one `typecheck.zig`.** F7 moves code that F2-F5 edit,
   so F7 runs after them; B1 and the front track meet in elaborate's
   records, so B1 starts only after F1.

**Stop rules, on top of rebuild.md's**

- If F3's emit is not identical after two attempts for the same reason
  (for example, emit's text depends on type id order), stop the front
  track. Either make emit independent of that order as a behaviour step
  of neutral hunks, approved, or revisit 2.4.
- If any B1 family needs a second representation of the same order
  (a decision made both in lower and in print), stop and redesign that
  family's ops.
- If B4's dual run disagrees on a verdict and the oracle sides with the old
  checker, the new checker is wrong: fix it, never the oracle. A second
  disagreement of the same kind stops B4.
- If the check guard's instructions rise more than 2% at any step and the
  step cannot show what it buys, stop the step.

---

## Answers, in one place

1. **Does sema need to run twice?** No. The five rewrites are local and
   type-directed, so elaborate does each at its site: mark, learn the
   type, roll back, check the desugared form in place. Option groups are
   rewritten in declare. Today any module that iterates a Map, Trig's
   largest among them, runs sema twice.
2. **Can facts, storage, and proofs share one recorder?** Yes on the way:
   one `Record` of typed columns, dense by node id, with a trail and phase
   seals (F1, F8). In the end storage and proofs are LIR structure (hidden
   locals, op order, a proven bit), and `Decided`, the 36 questions, and
   `verifyDecisions` are deleted.
3. **Where does typecheck split?** Into twelve files by concern (5.3), with
   an `Env` passed down and the std forms in one file; pure motion, after
   the elaboration steps.
4. **What does emit share with an LLVM backend?** LIR, `layout.zig`, the
   program decisions, and the intrinsic list of runtime operations. Not Zig
   spelling. How an LLVM backend calls the runtime's comptime generics is
   that backend's open question.
5. **What compiler and runtime Zig can be shared?** The hash-table core,
   once a profile after the dense columns shows it matters (split
   `unordered.zig` into a core with no runtime import and a Rig wrapper).
   The object-file readers of `frames.zig` and `alloc.zig`'s image loader
   both parse Mach-O and ELF headers, a small merge to try. `nametable.zig`
   is already shared. The larger shared asset is the intrinsic list: one
   description of the runtime's operations for every backend.
