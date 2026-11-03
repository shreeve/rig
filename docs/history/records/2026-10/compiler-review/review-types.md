# Review: types and effects (typecheck, cteval, inlining, proofs)

Scope: `src/typecheck.zig` (22,447 lines, 825 commits), `src/cteval.zig`
(2,063 lines, 4 commits), `src/inlining.zig` (1,473 lines, 37 commits),
`src/proofs.zig` (2,951 lines, 29 commits), with the parts of
`src/sema.zig` they lean on. Read only; nothing built or run.

Method: function-size and keyword surveys of the whole of typecheck.zig
(828 functions, list in `tc-fns.tsv` beside this file), close reading of
about 15% of it (the Checker state, the dispatchers, generic
requirements, frames, the compatibility relation, literal handling),
the headers and hot spots of the other three files, and `git log`
sizes over time.

## Shape of typecheck.zig

| Section (by its own banners) | Lines | Share |
|---|---:|---:|
| Header and `Checker` state (`:1-523`) | 523 | 2% |
| Declarations (`:524-1060`) | 537 | 2% |
| Statements (`:1061-4730`) | 3,670 | 16% |
| Expressions: synthesis (`:4731-8974`) | 4,244 | 19% |
| Calls (`:8975-15573`) | 6,599 | 29% |
| Expressions: checking (`:15574-18327`) | 2,754 | 12% |
| Builtins, closures (`:18328-19104`) | 777 | 3% |
| Compatibility and helpers (`:19105-19829`) | 725 | 3% |
| Generic requirements, frames (`:19830-21230`) | 1,401 | 6% |
| User APIs (`:21231-21965`) | 735 | 3% |
| Unit tests (`:21966-22447`) | 482 | 2% |

Comments are 4,289 lines (19%); blank lines 1,025. There are about
1,140 diagnostic call sites (`err`, `errAt`, `badCall`, `note`), one per
20 lines, and 1,297 lines holding a backticked message string.

Growth: 3,985 lines on 2026-09-24 (when it was split out of sema),
8,798 on 10-01, 10,157 on 10-08, 14,471 on 10-15, 19,125 on 10-22,
22,105 on 10-29. About 3,500 lines a week and not slowing; sema.zig grew
alongside it from 2,666 to 16,933. 552 of its 825 commits are from
October.

By function name (a lower bound; scattered branches inside core
functions are not counted):

| Area | Functions | Lines |
|---|---:|---:|
| core typing (everything else) | 606 | 15,667 |
| user APIs, API objects, bounds, conformances | 71 | 1,763 |
| concurrency forms (tasks, actors, par, isolate, select, http, io) | 37 | 1,370 |
| diagnostic text and fix-it builders | 43 | 1,232 |
| compile-time functions | 9 | 607 |
| Cell, Signal, Frozen, Static, handles, Hasher, Printer | 20 | 399 |
| frame accounting | 14 | 354 |
| Simd | 13 | 324 |
| Table and Slot | 12 | 191 |
| unit tests | 3 | 479 |

A further 1,174 lines anywhere in the file mention an API object,
Simd/lane, Slot/Table, actor/task, Cell, a `ct_` type, Signal, Frozen,
or Static.

## 1. Re-derivation (one fact decided in more than one place)

**Four constant evaluators.** Integer folding is `sema.constInt` /
`sema.ctFoldBy` (sema.zig:14718-14770). Float folding is a second,
text-driven evaluator in typecheck: `floatConstIn`, `floatLimit`,
`floatOp`, `floatOverflows` (typecheck.zig:19436-19504), used by
`checkFloatConstant` (:17872). `floatLimit` recognizes `F32.max` by
comparing the object's text with `"F32"`, `"F64"`, `"Float"`
(:19465-19478), not by resolving the name. Compile-time functions have
`cteval.Eval` with its own `CtVal` (cteval.zig:58). inlining.zig has a
fourth, smaller one, with yet another `CtVal = union { boolean, int }`
(inlining.zig:216) and `valueOf` (inlining.zig:1128-1150), which reads
`true` and `false` by text and finds compile-time parameters by
comparing declaration positions. cteval does share `sema.ctArith`
(cteval.zig:1370), so integer arithmetic means one thing; floats and
the inlining guard evaluator do not share it.

**Literal kind is decided from text in every pass.** The IR has no
literal node kinds: an integer, float, string, `true`, `false`, or
`none` is a `.src` leaf, and each pass asks `sema.isIntLiteralText`,
`isFloatLiteralText`, `isStringLiteralText`, or compares with `"none"`
and `"true"`. Counted: typecheck 40 sites, sema 18, emit 18, storage 7,
cteval 7, inlining 3, ownership 2, proofs 1. Examples:
`checkContextual` (typecheck.zig:16625-16636), `isContextual` (:19745),
`isDefaultLiteral` (:19752), `isWhileTrue` (:19569, `while true` found by
comparing the condition's text with `"true"`). The classifier is one
function, so the answers agree, but the question is asked about 96
times instead of being answered once by the parser.

**Names compared by text instead of symbol.** `readsNameIn`
(:19581) asks whether a name appears in a subtree by comparing leaf
text; `hasCodeWord` / `hasWord` (:19715-19736) scan the module's source,
comments stripped by hand, to decide whether a name a hint might
suggest is declared anywhere. These are diagnostic helpers, but they
re-derive from text what resolve knows.

**Parent lookup by search.** Nodes have no parent links, so
`parentIn` (:19691) searches from a root to find a node's parent and
`isCallee` (:19702) calls it twice; `contains`, `inIndex`, `inArgument`
(:19314-19335) are linear searches too (about 50 call sites).

**Identity by source position.** Leaves have no node id
(`sema.nodeKey`, sema.zig:1713, null for a leaf), so leaf facts are keyed
by `src.pos`; functions are keyed by declaration position plus module
(`body_pos`, `req.body != r.fun.pos` at typecheck.zig:20635, inlining's
`OwnerKey = { module, pos }`, inlining.zig:252). About 126 position
comparisons in typecheck.

**Frames predict emit's temporaries a second way.** `FrameWalker.walk`
(typecheck.zig:20120-20185) models which array literals, fills, calls,
and copies Zig will hold as temporaries, reading `storage.fillsInPlace`,
`storage.hasStorage`, `storage.reachesLeaf`, but it runs before
`storage.plan` (sema.zig:5994-5995 vs 6008) and keeps its own positive
list of what copies (`copiedIn`, :20194). Then a `reach_factor` covers
what the model misses (doc at :19920-19947). It is a deliberate
over-approximation, but it is a second model of the emitted code.

**What is already done well here:** the value classifier really is one
(`sema.handsOver`, sema.zig:14104; typecheck wraps it in `hands`,
typecheck.zig:6948), binding access is one (`sema.decideBindingAccess`),
and both are pinned by self-tests that read the compiler's own source
and count call sites (typecheck.zig:22151-22305). That enforcement is
crude (it breaks on a rename) but it works; a rewrite should keep the
invariant and enforce it with types instead.

No "category defined as not another" stood out in this area: the
positive-list style (`copiedIn`, cteval's `Pure`, proofs' fact lists) is
followed consistently.

## 2. Patch stacks

**The Checker carries its context as 84 mutable fields.**
`Checker` (typecheck.zig:145-397) holds the scope and body, then a long
run of "the X being checked" fields, 30 of them `Sexp = .nil`
sentinels: `handled`, `shared_operand`, `local_value`, `task_wait`,
`cell_home`, `in_place`, `member_pattern`, `return_operand`,
`discarded`, `discard_named`, `test_tail`, `results_ok`, `bound_value`,
`bound_call`, `results_tail`, `as_call`, `lent_write`, `receiver_obj`,
`not_operand`, `logic_operands`, `ternary_cond`, `outer_write`,
`receiver_of`, `lent_temp`, `view_arg`, `ignored_in`, `held_base`,
`matching`, `lent_callable`, `callable_kept`, and more. An inner check
recognizes its context by `sameNode(e, self.<field>)`. Each field is
set and restored by hand: 148 save/restore lines (`receiver_of` six
times, `results_ok` and `in_place` five each). This is the clearest
patch stack in the area: each time a check needed to know its parent, a
field was added rather than a parameter. Several exist only to choose a
diagnostic: `not_operand`, `logic_operands`, and `ternary_cond` are read
only to word the Simd-mask error (:10910-10915); `ignored_in`,
`kept_reported`, `uncaptured_reported` only suppress duplicate reports.

**Speculative checking with persistent side effects.** `synthQuiet`
(:2456-2463) types an expression with `ctx.quiet` raised and then
truncates the diagnostics, but `recordType`, symbol flags, and facts
stay. Every side effect that must not survive a trial needs its own
`if (ctx.quiet == 0)` guard (:4969, :6234, :6718; sema.zig:7886 for
array sizes), plus `tentative` (22 uses) for generic instances found
during `argType`, plus `trial_take` for `noteTakeable`. Closures for
`task.isolate`, `par`, `select`, and fallibility are checked "quietly
first as one that cannot fail" and then again as one that can
(:14118-14147, :14604-14609, :14751-14767, :14872-14878). A debug-only
pass, `checkTypedClean` (sema.zig:6046-6060), exists to catch "a verdict
whose diagnostic was dropped (a quiet check's, kept and reused)". That
is a rescue check for a rescue mechanism.

**Arguments are typed twice.** `argType` (:11927-11946) synthesizes
each argument quietly to infer type parameters, caches it in
`arg_types`, adjusts for literal results and write lends, and the
argument is checked again against the instantiated parameter. Literal
defaulting, `literal_results`, `result_hints`, `result_expected`, and
`beside` (:363-397) are all patches on a one-shot, left-to-right
matcher (`inferBindings`, :11681; `bindArg`, :12223) standing in for
inference variables.

**The member-call dispatcher is a chain of special forms.**
`synthMemberCall` (:12885-13168, 284 lines) tries, in order:
`taskJoin`, `parCall`, `isolateCall`, `httpServe`, `ioCopy`,
`taskSelect` (std modules recognized by name, e.g. `"std.par"` at
:14395), then `simdTypeCall`, `slotTypeCall`, `symbolTypeCall`,
`numberTypeCall`, `apiNameCall`, `actorSupervised`, `waitOperand`,
`spelledWait`, `actorCall`, `reduceCall`, `elemsCall`, `stringCall`,
`bitCall`, `floatCall`, `simdCall`, then `hash`, `order`, Hasher `add`,
Printer `value` by method name, `apiShorthand`, field calls, `upgrade`,
and finally ordinary method lookup. Each library form with a
signature the type language cannot write (a closure whose fallibility
decides the call's, captures that must sync, a listener taken) is typed
by hand in the checker: `httpServe` (:14792, 45 lines), `ioCopy`
(:14837), `parCall` / `parWorkers` (:14393, :14497, 180 lines),
`isolateCall` (:14587, 88 lines), `taskSelect` (:14699, 54 lines),
`actorSupervised` (:13772, 77 lines). About 1,400 lines in all.

**The subtype relation has accreted exceptions.** `meets`
(:19216-19261) special-cases `Static` read as `?String` (three places),
`?T` reading as a `[]T`, `any_error` versus set parameters, error unions
by subset, and literals meeting `Slot`. Each is reasonable alone;
together they are the shape a relation takes when types are added one at
a time.

**Generic requirements are an open-ended enum.** `sema.Requirement`
(sema.zig:3143-3230) has 28 variants inferred from what a generic body
does: `numeric`, `ordered`, `order`, `equatable`, `hashable`, `integer`,
`signed`, `float`, `fits`, `shift`, `copies`, `clones`, `no_cleanup`,
`array_len`, `lane_count`, `slot_count`, `sized`, `bytes`,
`whole_division`, `not_error`, `error_set`, `not_function`, `named`,
`printable`, `frozen`, `no_task`, `task`, `meets`. Each new feature that
a body can apply to a `T` adds a variant, a recorder, a checker
(`satisfies`), and a message (`reportTaskReq`, :20605).

**Lowering-driven rejections live in the type checker.**
`rejectHeaderCopy` (:4161-4172) rejects a header "since a temporary it
makes ends with the header", after asking `storage.headerPoints`; the
weak-spots page lists header temporaries, payload views, and Zig
rvalue addresses as the areas reviewers keep finding bugs in. About
480 of the 1,096 error sites in typecheck (44%, by keyword) concern
views, lends, places, temporaries, takes, Cells, or task crossing:
ownership-adjacent rules decided during typing. `checkLendBases`
(:16928) is a second walk over the typed tree inside typecheck that
enforces a lend rule.

**Type-directed desugaring by re-running sema.** typecheck records
iterator `for` loops and byte literals (`iter_loops`, `byte_literals`,
sema.zig:4196-4205), modules.zig rewrites the untyped tree, and the
whole module is checked again until nothing is found
(modules.zig:826-831). The pitfall list in AGENTS.md ("sema runs
twice") follows from there being no typed IR for typecheck to emit.

## 3. Leftovers

Little dead code: one unused function, `containsExpr`
(typecheck.zig:17696), and one orphaned doc comment with no declaration
(:125-126, "The diagnostic for an operand of `<` ... whose type has no
order"). No old spellings are still accepted; no `TODO`, `legacy`,
`compat`, or `workaround` markers in any of the four files. The
project cleans as it goes, and the self-test at :22205-22212 asserts that
names from a removed design ("interiorMutable", "lendsCellTemp", ...)
stay gone.

Vocabulary drift, against AGENTS.md's "one vocabulary":

- "receiver" appears 276 times in typecheck.zig and 82 in sema.zig,
  including type and function names: `sema.MethodReceiver`
  (typecheck.zig:53), `ReceiverTypeKind`, `classifyReceiverType`
  (:19263-19267), `ReceiverShape`, `receiver_obj`, `receiver_of`,
  `checkReceiverMode`, `takesReceiver`. The docs say "self".
- "struct" in comments 8 times in typecheck, 8 in proofs (e.g. "a struct
  binding `d`", proofs.zig:105), 24 in sema; IR kinds are still
  `.@"struct"` and `.generic_struct` (rig.grammar:401, matched at
  typecheck.zig:534, :737, :1173).
- "borrow" appears nowhere. Good.

Small hard-coded library knowledge: `sema.noteRuntimeRead`
(sema.zig:5941-5945) keys on `"std.time"` / `"since_start"` and
`"std.os"` / `"memory"`; 69 uses of `ctx.<name>_sym_id` for prelude types
(`list` 11, `simd` 6, `signal` 6, `slot`, `cell`, `actor` 5 each, ...).

## 4. Structural problems a rewrite would fix

1. **Two generic models at once.** The apis.md table
   (docs/design/apis.md:41-47) tells the story: generics began as C++/Zig
   templates, "checked against every instance", and bounds and APIs were
   added in five stages. Today an unbounded parameter is still checked
   per instance through inferred `Requirement`s and recorded
   `GenericMethodCall`s, and a bounded one against its bounds alone
   (`checkBoundedBodies`, typecheck.zig:21066-21085: "A parameter with
   no bound keeps per-instance checking"). `checkGenericInstantiations`
   (:19869-19946) runs, per instance: `misplacedArgs`, `checkBounds`,
   `checkRequirements`, `checkMethodCalls`, `checkInstanceSizes`, then
   `checkReaches` for methods reached later. Ownership has the same
   split: a generic callee's write lend lasts to the statement's end
   because "a `T` could hold anything" (weak-spots.md, "Statement-long
   loans"). A rewrite designed with bounds from the start would check
   every generic body once, against its bounds, and keep per-instance
   work to sizes and layout. The 28-variant `Requirement` enum would
   collapse into a short list of built-in APIs.

2. **No typed IR.** The tree is an untyped S-expression whose leaves
   are source spans. Types live in side tables keyed by node id or
   position, literals are recognized by text, parents are found by
   search, and desugaring needs a second run of sema. A rewrite should
   have typecheck produce an elaborated, typed IR (literal kinds,
   resolved symbols, parent or path links, explicit conversions and
   reads through views), and desugar iterator loops and byte literals
   there.

3. **No mid-level IR for temporaries and places.** Header temporaries,
   payload views, statement-long loans, Zig rvalue addresses, the frame
   walker's copy model, and `storage.zig` all reason about what emit
   will materialize. A MIR with explicit temporaries, scopes, and drops
   (Rust's design) would let ownership and frame accounting read one
   model, and would take most of the 44% of ownership-adjacent
   rejections out of the type checker.

4. **Context as parameters, not fields.** An explicit `Expect` or
   `Context` value passed down the bidirectional walk (expected type,
   position, use, lend mode, discarded, handled) replaces 84 fields and
   148 save/restore lines, and makes the checks pure enough that a
   trial needs no `quiet` guards.

5. **Inference variables.** Unification over type variables, including
   one for a closure's fallibility, replaces `argType`'s
   synthesize-then-check, the quiet two-pass closure checks, literal
   result patches, and `result_hints`.

6. **Library forms declared in the library.** With effect-polymorphic
   fallibility (`fun map[T, U, E](xs: ?[]T, f: fun(?T) -> U!E) -> []U!E`)
   and `Sends`/`Syncs` bounds on closures and captures, `par.map`,
   `par.each`, `task.isolate`, `task.select`, `http.serve`, `io.copy`,
   and actor supervision become std declarations, not 1,400 lines of
   hand typing in `synthMemberCall`'s chain.

7. **Very large functions and file.** `synthMemberCall` (284 lines),
   `checkSet` (197), `checkCompound` (183), `checkContextual` (172),
   `checkMatch` (165), `checkFor` (160), `bindArg` (156), `checkArgs`
   (147), `checkLambdaGiven` (147). The Calls section alone is 6,600
   lines. The file mixes typing, a fix-it engine (`LendBaseFix`, the
   ~400 lines from :17079), frame accounting (:19920-20512), generic
   instance checking, and API conformance. These are separable modules
   today; a rewrite should start them separate.

8. **Shared mutable state.** `SemContext` has 144 fields
   (sema.zig:3814-5897) shared by resolve, typecheck, storage, and
   frames; typecheck writes symbol flags (`repointed`, `rebound`,
   `access`; 32 sites) and facts while it types. resolve calls back into
   typecheck for compile-time functions (`resolve.ensureCtFun` ->
   `typecheck.checkCtFun`, resolve.zig:1497), and `checkCtFun`
   duplicates `checkModule`'s fifteen-`defer` setup
   (typecheck.zig:59-123). Ownership feeds requirements back for
   importers (`plain_reqs`, modules.zig:850). The pass order is real,
   but the interfaces between passes are the whole context.

9. **Per-module type tables.** `TypeId`s are module-local, so a nominal
   from another module is a separate variant, `imported_nominal`
   (sema.zig:423), handled in 15 places in typecheck and 39 in sema. A
   program-wide type interner removes the variant.

## 5. What is solid and should carry over

- **The bidirectional core:** `synthExpr` / `checkExpr` with poison
  types (`unknown`, `invalid`) that stop cascades, and every type and
  name recorded once in a facts table that emit reads
  (typecheck.zig:1-31 states it well).
- **The rules themselves.** Each rejection has cases in `test/rig`, and
  the messages are unusually good (a fix written in the user's own
  source). A rewrite should port the test corpus first and treat it as
  the specification; the cost of this area is in its rules, and the
  rules are earned.
- **One classifier per fact,** where it has been applied
  (`sema.handsOver`, `decideBindingAccess`), and the self-tests that
  hold it.
- **cteval.zig.** Self-contained, well bounded (step, depth, byte, and
  nesting limits, cteval.zig:39-55, so `rig check` gives the same
  verdict everywhere), a positive list of what runs (`Pure`,
  cteval.zig:405-470), arithmetic shared with constant folding. Four
  commits; carry it over, and make it the one constant evaluator.
- **proofs.zig.** A clear, documented abstract interpretation over
  units, six named facts, positive lists, soundness argued from the
  Core (proofs.zig:1-58), with emit asserting unit order. Its weak point
  is its reliance on typecheck and resolve recording every write
  (`recordWrite`); a MIR would give it writes directly. About 730 of its
  lines are tests and dump tooling.
- **inlining.zig.** One program-wide decision with stated rules
  (inlining.zig:1-50), Tarjan cycles, conservative fallback by name. Keep
  the design; drop its private evaluator.
- **The API design** (docs/design/apis.md: visible dispatch, braces mark
  the cost, `from`/`keeps` on API methods). The design is sound; it is
  the staged implementation beside the template model that costs.
- **Frame accounting** is a real safety feature (stack reach below the
  guard), well documented at :19920-19947. Keep the rule; compute it
  from a MIR instead of predicting Zig's temporaries.

## 6. How much serves the rarely used features

By function name, user APIs and API objects are about 1,760 lines,
compile-time functions about 610, Simd about 320, Table and Slot about
190, and Cell, Signal, Frozen, Static, Hasher, and Printer about 400:
roughly 3,300 lines, 15% of the file, before counting the branches these
features add inside core functions (1,174 lines mention them) and the
`Requirement` variants they add (`lane_count`, `slot_count`, `bytes`,
`frozen`, `meets`, `named`). Including those, I estimate 20-25% of
typecheck serves these features. Concurrency forms are another 1,370
lines (6%), but Trig uses tasks, so they are not rare.

Proofs, inlining, and frames serve every program. cteval serves only
compile-time functions but is small.

## Estimate

typecheck.zig, of its ~17,100 non-comment, non-blank lines:

- **Load-bearing rules, which a rewrite must re-implement:** about
  60-65%. Most of the volume is rules with tests and tailored
  diagnostics, not cruft.
- **Overhead from structure** (context fields and their save/restore,
  quiet and tentative trials with their guards, double typing of
  arguments, text-based literal and name checks, parent searches,
  hand-typed library forms, the second generic model, the float
  evaluator, the re-check loop's bookkeeping): about 25-30%. A rewrite
  with a typed IR, a MIR, inference variables, and bounds-only generics
  would not write this code.
- **Misplaced but sound** (fix-it engine, frame walker, API
  conformance, lowering-driven ownership rejections): about 10%. It
  would move to other modules, not disappear.

A rewrite keeping every rule could make this area perhaps 30-40%
smaller, and, more importantly, take out the classes of bug the
weak-spots page keeps listing (temporaries, payload views, statement
loans). cteval, proofs, and inlining are 85-90% load-bearing; their
cruft is the duplicate evaluators.

Confidence: medium. The structural findings (context fields, quiet
checking, two generic models, text literals, re-check loop, dispatcher
chain) are certain and cited. The percentages come from name and
keyword classification plus close reading of about 15% of
typecheck.zig, so they could be off by ten points either way.
