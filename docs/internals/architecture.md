# Rig's target architecture

The compiler the rebuild builds toward, and the path to it from
`revamp-base`. [rebuild.md](rebuild.md) holds the rules every step
follows. This page holds the target. It merges three designs written
independently in phase B, each from a blank page:

- A: the pipeline and the IR;
- B: the checkers and their facts;
- C: the back end and the runtime boundary.

The three are kept in full in
[docs/history/records/2026-11/rebuild-phase-b/](../history/records/2026-11/rebuild-phase-b/).
Where they agreed, this page says so once. Where they differed, it
gives the choice and the reason.

## The one idea

Today four parts of the compiler each model how a function runs, and
each walks the tree on its own to do it:

- the storage plan (`src/storage.zig`);
- the proofs' units (`src/proofs.zig`);
- the ownership checker's own model of order, temporaries, and calls
  (`src/ownership.zig`);
- emit's ordering and address logic (`src/emit.zig`).

They are kept in agreement by 36 decisions recorded lazily and checked
again in release builds (`verifyDecisions`, 5.2% of `rig check`'s
instructions).

All three designs reached the same answer on their own: **lower each
function once**, after type checking, into one structured lowered IR
(LIR). It makes evaluation order, hidden variables, drops, coercions,
and checks explicit. Ownership, proofs, frame accounts, inlining, and
emit all read it, and emit becomes a printer of LIR. "The checker
checks exactly what is emitted" (North Star 4) then holds by the
structure, not by agreement between walks. A later LLVM backend reads
the same LIR.

## The pipeline

| # | Pass | Consumes | Produces |
|---|---|---|---|
| 1 | lex, parse (Nexus), wrapper | source | the semantic tree; node marks replace the wrapper's side tables |
| 2 | declare | trees of all modules | symbols, scopes, declarations; built-ins once per program |
| 3 | types | declarations | one program-wide type store (no per-module proxies) |
| 4 | elaborate (typecheck) | tree, symbols, types | typing facts in the recorder; the five type-directed rewrites built and checked where they are found |
| 5 | cteval | elaborated tree | constants; one evaluator with a partial mode |
| 6 | lower | elaborated tree, typing facts | LIR per function: order, hidden variables, drops, coercions, check operations |
| 7 | ownership | LIR | verdicts and diagnostics; laid out by CORE's sentences |
| 8 | proofs | LIR | the proven bit on each check operation |
| 9 | decide | LIR, program | inlining, never-returning functions, units, words, frame accounts: one program table |
| 10 | print | LIR, type layout | Zig, one file per module |

**Sema runs once.** Today a `for` over an iterator, byte literals,
chains, option groups, and spreads are rewritten only after a first
check, so a module that has one is checked twice (`modules.zig:892-902`).
Each of the five needs a type, but each is local to one statement.
Elaborate rewrites at the spot where it learns the type, behind a mark
it can roll back, and checks the rewritten form in place. Option groups
are rewritten earlier, with the declarations.

Experts A and B put this in elaborate; C put it in lower. This page
follows A and B. It lands early, it gives a speed number at once, and
ownership and lower then see only desugared forms. By reading, Trig's
largest module loops over a `Map`'s values, so it probably pays two
full checks today. The pilot measures that first.

## Facts

- **One recorder.** Every fact lives in one record keyed by node id,
  in declared columns. Each column has one writer pass, enforced at
  compile time, and it is sealed at the end of that pass. The recorder
  carries a trail (mark and roll back) over fact writes, which
  elaboration's rewrites need. Symbols, scopes, and type interning join
  it only when a step needs them: each is made once for what it names,
  and F3 keeps emit identical without rolling them back. Nodes made by
  rewrites get ids, so no fact is keyed by an address.
- **Then fewer facts.** Storage decisions become LIR variables. Proofs
  become bits on LIR check operations. The 36 lazy questions,
  `Question`, `Decided`, and `verifyDecisions` are deleted, which takes
  their 5.2% out of `rig check` (an owner policy question that
  dissolves rather than being answered).
- **What emit reads:** only the LIR and a type layout table (how each
  type is spelled and held in Zig: one record per type, shared by both
  backends). `src/facts.zig` shrinks to that table.
- **Facts decided in more than one place** (B's table) become one
  writer each: the builtin a call names (`print`, `swap`, `none`,
  conversions), place roots and paths, the symbol a variable names, and
  the order of an old value's drop on assignment.

## Shared machinery

- **One place walker,** shared by elaborate and lower.
- **One structural type visitor,** with each type query rewritten as a
  fold over it.
- **One constant evaluator,** in place of four.
- **Elaborate's context as one value** (`Expect`), replacing 34
  sentinel fields and their save-and-restore.
- **A closed runtime boundary:**
  - Emit spells 226 runtime names as loose strings; they become one
    enumerated list.
  - The scattered `__rig_*` root declarations become one config record.
  - A per-type marker carries the compiler's classification, so the
    runtime stops deciding drop glue, table fill, and view shape again
    by reflection.
- **Zig code shared by the compiler and the runtime:** checked
  arithmetic (`arith.zig`, for cteval and the runtime) and name mangling
  (`names.zig`). The compiler's maps mostly become dense columns. The
  rest may move to Rig's own tables (`src/unordered.zig`) only if the
  check guard shows a gain.

## Where typecheck splits

By the part that owns each decision:

- elaborate's core (expressions, statements, the five rewrites);
- places and views;
- builtins;
- std forms (one dispatch table);
- APIs;
- generics;
- hints;
- frame accounts, which move onto LIR variables.

Temporaries and header decisions leave typecheck for lower.

## The ownership checker, laid out by CORE

Expert B's layout puts each of CORE's sentences in one place, so CORE
§10's paragraph test can be audited in the code:

- `state`: variables, flows, loans, and their join;
- `live`: liveness on the LIR's control-flow view;
- `transfer`: one transfer function per LIR operation, sentences 1 to
  10;
- `rules`: one positive predicate per rule, each citing its sentence;
- `origins`: origins and reach;
- `exits`: CORE §9's one exit primitive;
- `generic`: generic bodies;
- `notes`: messages naming both ends of a view.

The second ownership checker (`bin/rig-oracle`) keeps its own lowering,
so a lowering bug cannot hide in both checkers. It has 142 recorded
differences, 68 of them where the compiler is stricter. Most of those
come from structure, not rules: liveness judged by source position,
loans that last a whole statement, and views rooted on write-view
bindings. Ownership on LIR, with loans ending at their last use, removes
most of them (the owner approved ending them at last use for the new
design, records/2026-10/compiler-review/rewrite-review.md, decision 4).

## Line budgets

Budgets come from the three designs, set from what each pass must do,
not from today's sizes, and taken near their middle. In-file unit
tests are counted apart. The ledger keeps the scoreboard.

| Pass | Today | Budget |
|---|---:|---:|
| front end (lexer, wrapper, normalize, syntax diagnostics, diag) | about 9,100 | 7,000 |
| modules and driver | 1,172 | 950 |
| declare (resolve, symbols, scopes) | about 6,700 | 4,800 |
| types (store, visitor, view reach) | about 9,000 | 6,000 |
| recorder | about 4,700 | 1,200 |
| elaborate and its splits (typecheck, places, builtins, std forms, APIs, generics, hints) | about 28,300 | 19,000 |
| cteval | 2,175 plus three evaluators | 2,000 |
| LIR (definition, verifier, text form) | 0 | 1,000 |
| lower | 2,774 (storage), plus logic from typecheck, sema, emit | 6,000 |
| ownership | 9,768 | about 10,900 |
| proofs | 2,930 | 2,000 |
| decide (inlining, returns, units, symbols, words, frames) | about 2,500 | 2,000 |
| print and type layout (emit, facts) | 14,192 | 8,000 |
| **these passes** | **about 93,000** | **about 71,000 (24% smaller)** |
| CLI, LSP, editor, frames/BOLT/PGO | about 6,800 | about 6,400 |
| runtime (runtime, sched, tasks, alloc, tables, net, table, split) | 38,012 | 36,800 (3% smaller) |

Ownership's budget is about 10,900, not 6,000: what remains after
the region-driven walk is Core's transfer for each operation, the
unstored loans, liveness, and the message forms, which stay as they
are, so a smaller checker would change what Rig reports.

The runtime stays nearly flat because its code is measured: the
scheduler, the allocator, and the tables keep what earned its place.
Lower and LIR are about 7,000 new lines, paid for out of storage, emit,
ownership, proofs, and typecheck.

## The path

Each step is **I** (identity: `tools/emit-diff revamp-base` prints
`identical`, every suite green, the oracle unchanged, the check guard
within 2%) or **B** (behaviour: a failing case first, every emit hunk
classified, per rebuild.md). Two tracks touch different files, so they
can run at once, with a third agent for shared or later work.

**Before step 1.** Any back-end bug the audits found that is still open
at `revamp-base` lands on `main` first, as its own B step, so the
rebuild reproduces fixed output. Expert C names E1, E2, X1, X2, X4, and
X5, none re-probed yet.

### Phase C: two pilots, in parallel

The spec's default pilot, typecheck's split, moves code, so its proof
cannot fail. A and C both argued it tests the process's pace but not
whether identity holds through a real redesign, and that is what a
pilot is for. The plan runs two small pilots on disjoint files instead.
Each tests one half of the central bet, and the split comes right after.

| Pilot | Steps | Tests | Measures |
|---|---|---|---|
| **Front: sema once, for iterator loops** (A) | F1 the recorder's trail (mark and roll back over fact writes; symbols, scopes, and interning only when a step needs them), unused yet; F2 byte literals elaborated at the site; F3 iterator loops elaborated at the `for` | that a type-directed rewrite at its site keeps emit identical; the known unknown is whether type-id order reaches emitted text | sema rounds per module, counted before the change; `rig check --time` on Trig |
| **Back: the var table** (C) | storage's plan produces, per frame owner, an ordered table of hidden variables; emit's temporaries and guards and ownership's call holds read it; emit keeps its own name counter | that a decision can become data that emit only prints, byte-identical | net lines (budget: −500 across storage, facts, and emit) |

If either pilot cannot hold identity at a reasonable pace, the rebuild
stops there and the owner decides (rebuild.md, stop rules).

### Phase D: the rebuild

**Front track** (elaborate and recorder files):
1. F4 chains and F5 option groups and spreads, elaborated the same way;
   F6 the module loop deleted, so sema runs once (I).
2. Typecheck's split by decision owner, with `Expect` as one context
   value (I, mostly code motion).
3. Dense columns by node id for every list-node fact (I; the check guard
   and peak memory on Trig's check are measured).
4. Every fact behind the recorder, one writer per column; nodes made by
   rewrites get ids (I).
5. Duplicate deciders, batched: the builtin column, one place walker,
   ownership finding variables by symbol id (I).
6. The intrinsic table: std forms as declarations with an intrinsic
   row, one call kind in emit (I, or B where it fixes a bug).
7. One program-wide type store and symbol table, built-ins once,
   proxies deleted; one type visitor with queries as folds; one program
   table for program-wide decisions (I; a diagnostic that now appears
   once instead of in each importer is its own B step).

**Back track** (storage, emit, proofs, ownership files):
1. LIR in shadow: lower builds LIR for every function from the typed
   tree and the recorded facts, and self-check builds compare its
   variables and order with the var table and storage's decisions. Nothing
   reads it yet, and it is consumed within the phase or reverted (I).
2. The printer, one family of constructs at a time: plain expressions,
   calls with held arguments, statement temporaries, headers, `match`,
   loops, closures, tasks, `select`. A function prints from LIR when
   every construct in it is ported, else from today's emit. Names are
   allocated in the order emit's recursion allocates them (I, several
   PRs).
3. Storage dissolves: lower decides from the typing record alone;
   `Question`, `Decided`, and `verifyDecisions` are deleted (I; `rig
   check` faster by about 5%).
4. Proofs on LIR; frames and inlining on LIR, with inlining decisions
   unchanged over the corpus (I).
5. Ownership on LIR, run in shadow over the suite, the doc examples, and
   the corpus until verdicts and diagnostics match, then swapped in. Its
   files are laid out by CORE (I).
6. `facts.zig` becomes the type layout table; emit imports only the LIR
   and the layout (I).

**Shared, by a third agent when the files are free:**
- `arith.zig` and `names.zig` shared by the compiler and the runtime;
- the closed list of runtime names (all I).

### Phase E: behaviour steps

Each one is measured. A program a release accepted is never rejected
without the release-note and Trig rules.

- Loans end at their last use, with liveness on LIR's control-flow
  view; the oracle's liveness differences shrink, and every newly
  accepted program is a case clean under `RIG_SANITIZE=1`.
- Quiet checks roll back (`synthQuiet`).
- Lowering's rejections move out of typecheck: in a program with both
  a type error and one of these, only the type error is reported.
- Frame accounts from LIR variables (inlining may change: guards, and a
  race if a hot function moves).
- One constant evaluator with a partial mode.
- Neutral emit changes, each alone, with every hunk classified:
  - flattened statement temporaries;
  - the config record;
  - the runtime's twins collapsed;
  - the per-type markers, read by the runtime.
- Inlining measured on LIR operations, with a Trig race.
- Normalize's two side-table forms built by the grammar.

### Ahead of December

**The LLVM bitcode measurement.** An LLVM backend reading LIR needs
monomorphization and the runtime's generic code built by Zig and linked
as bitcode. Whether Zig 0.17 can do that link is unknown, and it decides
the backend's shape. It is a small, read-only experiment that can run
any time in phase D. The runtime's split into `core/` and `generic/`
follows only if it passes.

## Considered and rejected

| Idea | Why not |
|---|---|
| A new repository, or a hand-written parser | Owner decisions: rebuild in place; keep Nexus (rewrite-review, decision 5) |
| Lower before typecheck, so the rewrites are syntactic | All five need inferred types |
| A control-flow-graph LIR as the only form | Zig needs structured control flow, and emit could not stay identical; liveness uses a CFG view of the structured LIR instead |
| Keep ownership on the tree and lower only for emit | Leaves two models of order, so the checker would check something other than what is emitted |
| The oracle sharing the compiler's lowering | A lowering bug could then hide in both checkers |
| One arena for the compiler | Measured: it hid a wrong free and held 2.1 GB against 0.65 GB (records/2026-10/check-speed); a per-function LIR arena may be measured later |
| Checking modules in parallel | `rig check` of Trig is about 2 s; it would change diagnostic order |
| Swapping every map for Rig's tables now | Most maps become dense columns first; measure the rest |
| Self-hosting | Out of scope (rebuild.md, decision 4) |

## Risks

- **Byte-identical emit from LIR** is the biggest risk, and all three
  designs name it. Emit numbers hidden names from one counter in
  recursion order, and the printer must match it exactly. Stop rule: a
  construct family whose proof fails twice for the same reason lands one
  renaming-only B step, every hunk classified neutral, then resumes. If
  the shadow lowering cannot reproduce storage's decisions, the
  premise is false and the back track stops.
- **Type-id order** does not reach emitted text: F3 elaborates
  iterator loops in place, with symbols, scopes, and interned types not
  rolled back and so numbered differently from a second check, and the
  emitted Zig of every program, Trig's included, is identical.
- **Ownership's swap** must keep every verdict and message. The shadow
  run over the suite, the doc examples, and the corpus is the proof, and
  the oracle stays independent.

## Decisions for the owner

1. Approve this page. Default: approve.
2. The pilots: two small pilots in parallel, sema once for iterator
   loops (front) and the var table (back), with typecheck's split right
   after. Default: yes. The alternative is the spec's single pilot,
   typecheck's split.
3. Sema-once in elaborate (A, B) rather than in lower (C). Default:
   elaborate.
4. The LLVM bitcode measurement as a small side experiment during phase
   D. Default: yes.
