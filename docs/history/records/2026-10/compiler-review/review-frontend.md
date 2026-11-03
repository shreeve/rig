# Front-end review: what a rewrite would change

Area: `rig.grammar` (1,365 lines), `src/rig.zig` (5,385), `src/sema.zig`
(16,933), `src/resolve.zig` (5,396), `src/modules.zig` (933). That is
30,012 lines. Read only, at `144f70057`. `typecheck.zig` (22,447 lines) is
outside this area. I read it only where the front end hands work to it.

Churn (commits touching each file, with the share whose subjects mention
fix, bug, reject, unsound, or crash):

| File | Commits | Fix-like | Commits since 2026-10-01 |
|---|---|---|---|
| rig.grammar | 197 | 18 | n/a |
| src/rig.zig | 268 | 27 (31 incl. panic) | 149 |
| src/sema.zig | 572 (with --follow) | 53 | 466 |
| src/resolve.zig | 269 | 28 | 185 |
| src/modules.zig | 60 | 1 | n/a |

sema.zig has been rewritten heavily in the last month: 466 of its 572
commits came after Oct 1. The code is very clean on the surface. There
are no `TODO`, `hack`, `legacy`, or `compat` markers, because the
timeless-prose rule removes them. The cruft therefore does not show up in
a grep. It shows up in structure: side tables, re-runs, guards against
pass disagreement, and per-question walkers.

---

## 1. Structural problems a rewrite fixes and incremental work can't

### 1.1 The tree is rewritten in place after checking, then the whole module is checked again

- `src/modules.zig:819-830` runs `sema.check`. When typecheck found
  `for`-over-iterator loops or string literals used as bytes, it then
  mutates the IR in place (`Parser.byteLiterals`,
  `Parser.desugarIterLoops`) and runs `sema.check` again **from
  scratch**, in a `while` loop that repeats until nothing changes. The
  re-run repeats everything:
  - `registerBuiltins` (a 289-line function, `src/resolve.zig:4880`)
  - symbol resolution and declarations
  - contents
  - typecheck
  - generic expansion
  - the storage plan (`sema.check`, `src/sema.zig:5956-6012`, calls
    `storage.plan` at 6005)

  Any module with a single `for x in it` pays for two full checks.
- Typecheck also mutates the tree *during* checking, through a const
  parser:
  - `typecheck.zig:18730` calls `p.padLambda(node, known)`.
  - `typecheck.zig:18792` calls `p.dropTail(&@constCast(node.items())...)`.
  - The `@constCast` lives in `rig.zig:4401-4428`. There are 14
    `@constCast`s in rig.zig.

  So the shape of the IR depends on how far typecheck has got.
- The cause: lowering that needs types (iterator loops, byte literals,
  tail drops of closures that return nothing) has no place in the
  pipeline. It runs as a "parser" rewrite triggered by sema.
- Rewrite: make the pipeline syntax → resolved/typed HIR → a lowering pass
  → MIR, which ownership, storage, and emit read. Typed desugaring belongs
  in the lowering, run once.

### 1.2 Facts keyed by source position and node id, with tricks to keep them apart

- `Facts` (`src/sema.zig:1764`, 67 hash maps) and `SemContext` (146
  `AutoHashMapUnmanaged` in sema.zig) key facts in three spaces
  (`src/sema.zig:1725-1758`):
  - a leaf's source **position**
  - a list node's id with bit 32 set
  - for "a list node a rewrite built without a number", the node's
    **items pointer address** with bit 33 set (`decisionKey`, 1727)
- Because facts are keyed by position, synthetic leaves get invented
  positions:
  - `hiddenLeaf(key - 1, .iterator)` and `hiddenLeaf(key + 2, .iterator)`
    (`rig.zig:4558-4559`) use offsets into the `for` keyword so that no
    real leaf collides.
  - `padLambda` numbers hidden parameters past the end of the source
    (`rig.zig:4422`), and `pad_homes` maps them back for diagnostics.
- The 16-bit leaf `id` is overloaded (`rig.zig:2141-2175`). It holds:
  - a keyword ordinal
  - a byte value (`0xFE00+b`, `byteLeaf`)
  - a path capture (`0xFDFF`)
  - a hidden name (`0xFF00+`)
- `SemContext.decision` (`sema.zig:5184-5193`) panics if "two nodes share
  the key of a decision". That guard is needed only because keys are not
  unique by construction.
- Rewrite: give every node a dense id when it is made (the lowering
  included) and keep facts in arrays indexed by id. Synthetic names
  become real nodes, not leaves with forged positions.

### 1.3 Facts decided lazily, recorded, and re-verified because passes could disagree

- `Question` (`sema.zig:2305-2393`, 28 questions) and the `Decided` memo
  form a guard rail. Each answer is "decided once, the first time a pass
  asks it". `storage.verifyDecisions` (`storage.zig:1389-1404`) asks
  every question again at the end and panics if "the facts now give" a
  different answer. Recording goes through a `*const SemContext`
  (`recordDecision`, `sema.zig:5202`).
- This is a patch over unstratified fact computation: facts can still
  change after a consumer read them.
- Alongside it are two other memo systems:
  - `TypeInfo`, computed when a type is interned (`sema.zig:6833`)
  - `TypeMemo`, lazy and written through const (`sema.zig:2402`)
- `contents_ready` toggles between them (`sema.zig:6895`, 6919, 6929;
  `holdsByteSlice` vs the memo at 12123/12201).
- Rewrite: strict phases. Each fact table is complete before any pass
  that reads it starts, so the memo, the sealing, and the verification
  are all unnecessary.

### 1.4 Per-module type stores with imported proxies

- Each module's `SemContext` has its own `TypeStore`. Another module's
  type becomes `imported_nominal` (`sema.zig:420`), and `importType`,
  `importSymbol`, `proxyOf`, `fillProxy`, and `importParam` copy it in
  (`sema.zig:12661-12940`).
- That needs extra machinery:
  - an `import_depth` bound of 64
  - an `import_pending` queue so that recursion does not overflow
    (12800-12816)
- Every type walker has to carry `(ctx, ty)` pairs and switch contexts at
  each foreign nominal (`nominalDecl`, 10371; `ByteSliceItem`, 12139).
  `imported_nominal` appears 39 times in sema.zig and 15 in typecheck.
- `registerBuiltins` re-creates `Cell`, `List`, `Chan`, `Actor`, and the
  rest in **every** module, with 23 hard-wired `*_sym_id` fields
  (`sema.zig:3829-3860`). Those fields are read 154 times in sema, 69 in
  typecheck, 45 in facts, and 40 in resolve.
- Rewrite: one program-wide type store and symbol table. Built-ins are
  declared once.

### 1.5 `SemContext` is a god object for every pass

- About 144 fields (`sema.zig:3814-~4250`). They include state owned by
  later passes:
  - storage: `storage`, `discards`
  - inlining: `inlined`, `inline_decls`, `inline_frames`,
    `inline_heights`, `inline_calls`
  - frames: `frame_sizes`, `frame_owners`
  - a nine-field "plain bits" cluster: `plain_reqs`, `plain_regions`,
    `plain_tests`, `plain_bits`, `uses_plain_bits`, `plain_answers`,
    `plain_items`, `type_plain_bits`, `plain_test_bits`
- Fields were added one at a time as parallel arrays:
  - `generic_uses`, `generic_uses_in`, `generic_uses_at`,
    `generic_uses_guard`
  - `generic_fn_uses`, `generic_fn_uses_in`, `generic_fn_uses_guard`
- Ownership writes back into sema after it runs
  (`modules.zig:845-850`: `plain_reqs.appendSlice(own.ownPlainReqs())`,
  `recordOldNone`).
- Rewrite: a context per phase, each with an explicit read-only input and
  an output.

### 1.6 Mutable global state, saved and restored, standing in for an environment

- **Method bounds on an owner's parameters.** These mutate the shared
  `Symbol.apis` in place, then snapshot, re-widen, and restore it
  (`widenOwnerBounds`, `snapshotWidened`, `rewiden`,
  `restoreOwnerBounds`; `sema.zig:9708-9775`). Deferred checks have to
  carry snapshots (`resolve.DeferredCheck.bounds`).
- **Speculative checking.** `ctx.quiet` (43 uses in typecheck) suppresses
  diagnostics. `checkTypedClean` (`sema.zig:6043-6057`) then exists to
  catch "a verdict whose diagnostic was dropped (a quiet check's, kept
  and reused)".
- **Compile-time functions.** These need type facts before declarations
  are resolved. `beginEarlyContents` and `endEarlyContents`
  (`sema.zig:6902-6935`) compute contents for plain enums, set
  `contents_ready = true`, and then *take it all back*.
- Each of these is a flag added to rescue an earlier ordering decision.
  Rewrite: pass a bounds environment to queries, make speculative checks
  return a result instead of mutating state, and resolve declarations on
  demand with cycle detection.

### 1.7 The IR drops information, so the wrapper keeps it in side tables or recovers it from spans

`rig.Parser` holds 13 side tables keyed by node id or position
(`rig.zig:2322-2386`):

- `receiver_sigils`
- `once_params`
- `placed_rarely`
- `loop_receivers`
- `paren_suffixes`
- `pub_members`
- `read_only_members`
- `outside_members`
- `bounds`
- `owner_bounds`
- `assoc_bounds`
- `detached`
- `pad_homes`

Later passes query them, so sema holds a `parser` pointer: `isPubMember`,
`boundsAt`, and the rest are called 26 times from typecheck and 11 from
resolve.

The worst case is the **receiver-sigil rewrite** (`rig.zig:4105-4198`):

- The grammar binds `!x.v.push(1)` as `!(x.v.push(1))`, so the wrapper
  re-associates the tree to `(!x.v).push(1)`.
- The grammar drops parentheses, so it tells `!(v.pop())` from
  `!v.pop()` by **re-lexing the source** after the sigil (`afterSigil`)
  and comparing span starts.
- It then records the node so that the checker can reject some calls only
  in the short form (`Checker.parenthesized`).
- The same span-sniffing happens in `paren_suffixes` (`*(T?)`) and
  `touchesOperand`.

Rewrite: keep a `paren` node, or a flag on the node, and give prefix
sigils over method chains their precedence in the parser. The rewrite and
all three tables disappear.

### 1.8 Name resolution done syntactically in the parser

- `builtinRefs` and `rewriteBuiltin` (`rig.zig:3345-3485`) rewrite every
  mention of 14 prelude names (`builtin_type_names`, 2119) to
  `__rig_prelude.Name` **before sema**. Shadowing is decided by scanning
  top-level declaration names and API `type` members.
- There is a patch on top: "a file that names a member `lanes` uses the
  prelude too" (`lanesMembers`, 3425).
- Built-in types therefore have two mechanisms:
  - the hard-wired Zig `registerBuiltins` (`Cell`, `List`, `Chan`, `^T`,
    `Simd`, `Table`, ...)
  - prelude rewriting (`Map`, `Set`, `HashMap`, `Lanes`)
- Rewrite: one mechanism. The prelude is an outer scope in resolution,
  with intrinsics marked in Rig source.

### 1.9 A lexer driven by context

`Lexer` carries about 45 state fields (`rig.zig:824-924`), among them:

- `label_sigil`, `label_name`, `after_label`, `after_jump_label`
- `symbol_name`, `closed_bars`, `member_dot`
- `last2_cat`, `before_cat`

It decides about 10 contextual keywords by lookahead probes
(`classifyWord`, `rig.zig:1530-1550`):

- `new`, `obj`, `api`, `add`, `inline`, `called`, `rarely`
- `of`, `unique`, `from`, `static`, `keeps`, `once`

It also decides `if` (three ways), `:` (four ways), `|`, `??`, `&`, `,`,
and `..`. After that it excuses one spacing rule by scanning text
backwards for `once` (`afterOnce`, 2431).

These are the costs of an LALR generator. The rules themselves (layout,
islands, `.`-chain joins) are language design. The way they are
implemented is accidental. A hand-written recursive-descent parser could
decide contextual words where it already knows the context.

---

## 2. Re-derivation (one fact decided in several places)

- **Type walkers by question.** sema.zig contains 163
  `switch (ctx.types.get(...))` sites, and 38 lines peel
  `.optional, .read_view, .write_view, ...` by hand.
  - `holdsByteSlice` (12153) and `objectUnprinted` (8824) are near
    copies of the same explicit-stack walk, and they peel different
    wrapper sets: the second peels `.weak`, the first does not.
  - Others like them: `objectUnownedIn`, `blockerIn`, `reachOf`,
    `holdsIn`, `minBytesOf`, `runsDropBody`, `EquatableWalk`,
    `TargetWalk`, `ReachWalk`, `Components`.
  - Each difference is a local decision. A new `Type` variant
    (`slot`, `simd`, `callable`, `results`, `api_object` were all added
    late) has to be threaded through every one, with an `else =>`
    default waiting to misclassify it.
  - Rewrite: one generic structural visitor ("children of a type, with
    how each child is held"), with the questions written as folds over
    it.
- **"Plain" has two meanings.**
  - `isPlain` (`sema.zig:3389`) is CORE §1: provides both `Copy` and
    `Owned`.
  - `TypeInfo.plain` (6847) means "no resource, marked view, or type
    parameter, but may hold a `?String`". It is read only through
    `holdsNoLoanButText` (12085), whose doc comment has to explain how it
    differs from plain.
  - So the field's name contradicts the Core.
- **"Is a view" is answered in several places.**
  - `isReadOrWriteView` (10227)
  - `isViewType`, which adds slices and `string_view` (11758)
  - `holdsMarkedView`, `mayHoldMarkedView`, `mayHoldView`
    (10818-10834)
  - `holdsViewOnly` (11346)
  - `viewHeldAsPointer` (11311)
  - `isErasedView` (641)
  - `readsAsValue`

  On top of these, `typecheck.isTemporary` (6895) re-derives
  "temporary" from `handsOver` plus `isReadOrWriteView`. weak-spots.md
  admits it: "Whether an expression is a view is not one fact yet".
- **`?String` is a special type kind.** Interning folds
  `read_view(String)` to `string_view` (`sema.zig:924`). Then
  `string_view` has to be listed beside `read_view` throughout: 54 sites
  in sema and 58 in typecheck, with a separate `Views.string_view` bit
  next to `marked`, plus special cases such as `matchAssoc` at 9667. This
  is the design question still open in weak-spots ("CORE calls it a
  view, SPEC plain data"). The code stacks special cases because the
  decision was never made.
- **Two homes for IR helpers.** `rig.zig:37-620` (exits, units,
  skeletons, guard parts) and `sema.zig:13463` ("IR helpers shared by
  the sema passes").
- **Primitive and type-parameter names resolved by string.**
  `resolveType` (`resolve.zig:3831`) compares names to `"error"` and
  `"Self"`, scans type parameters linearly by name, and keeps primitives
  in a separate name table (`primitive_type_names`, 4754) rather than as
  scope symbols.

## 3. Patch stacks (exceptions layered on exceptions)

- **The receiver-sigil rule** (1.7). Its history: `!` came first, then
  `<`, then `?`, then `for` sources (`loop_receivers`), then `>t` waits
  (`waitTakesName`). It is checked in 23 places outside rig.zig.
- **Statement-drop rewriting.** `dropStatement` and `valueTail` run in
  the wrapper, then typecheck undoes part of the work with `dropTail`
  once it learns a closure's type. It is a three-step dance because the
  value-ness of a closure body is decided before its type is known.
- **Bounds stripped out of the tree.** `tparamBounds`, `owner_bounds`,
  and `assoc_bounds` take bounds off `[T: Ord]` and store them by
  position. Resolve reads them back through the parser.
- **Diagnostic splicing.** `resolveSymbols` splices shadow diagnostics
  back into position "so diagnostics stay in the order a one-pass check
  would give" (`resolve.zig:55-68`).
- **Old-name shims.** `renamedApi` (`resolve.zig:1213`) rejects
  `Moves`/`Shares` toward `Sends`/`Syncs`. This is small, but it is a
  real leftover.

## 4. Leftovers and vocabulary drift

- **Names that clash with the docs' vocabulary.**
  - "receiver": 35 uses in rig.zig, 72 in sema.zig, 10 in resolve.zig
    (`receiverSigil`, `isReceiverSigil`, `MethodReceiver`,
    `Question.receiver_hold`). The rule says self, never receiver.
  - IR kinds `struct` and `generic_struct` (`rig.grammar` schema), where
    the language says `obj`/object.
  - `lambda` for a closure.
  - `TypeInfo.plain` (above).
- **Misplaced code.**
  - Zig identifier escaping (`writeZigIdent`, Zig keyword and primitive
    tables, `rig.zig:635-822`) is an emit concern in the front-end file.
  - The facts dump writer (`writeFactsDump`, `writeFactValue`,
    `sema.zig:2860-3130`) lives in sema.
- **Section headers that no longer match.** sema.zig's "Associated types
  and iterators" banner (9427) now covers 4,000 lines: tasks and
  crossing, frozen, origins, drop bodies, cloning, imports, member
  lookup, and type formatting.
- **No dead IR kinds.** All 94 schema kinds are used in at least two
  passes. Dead code is not the problem. Accretion is.
- **Directory modules are handled by concatenation.** A directory module
  is its files concatenated, with `Lexer.ends` and `crossesFile`
  (`rig.zig:2396`, `modules.zig`). It is a cheap trick that works, but
  every position-to-file mapping (`fileAt`, a linear scan,
  `rig.zig:3442`) pays for it.

## 5. What is solid: carry into a rewrite

- **The `handsOver` classifier** (`sema.zig:14052-14183`): positive
  lists, one kind per expression, recorded. With `MoveSource`
  (14186+), it is exactly the "one classifier per fact" shape.
- **The lend table** (`sema.zig:13606+`): `LendStep` rows composed in
  order. It is small and principled.
- **`TypeStore` interning with poison types** (`invalid`/`unknown`
  compatible with everything), so one error does not cascade.
- **The `Components` SCC order** for computing contents
  (`sema.zig:6885-6899`), so walks never nest through chains of types.
- **Bounded recursion everywhere:** tree depth 1000, nesting 64/512/32,
  alias height 200, token length. Keep the limits.
- **Diagnostics:**
  - `foreign_words` (`rig.zig:2812`)
  - expected-token messages from `@display`/`@errors`
  - layout messages that show the layout to write
  - `headerColon`, `bareResults`, and the other hints

  They are about 900 lines of `rig.zig:2443-3240`, high-value UX, and
  should be ported unchanged.
- **Layout rules as a specification:** INDENT/OUTDENT, layout islands
  for closures in brackets, `.`-chain joins under a positive rule, and
  `else` continuation. The rules are good. Only the implementation
  strategy changes.
- **`modules.zig` as a whole:** module keys, directory modules, embedded
  std, cycle reporting at `use`, and "a module with type errors is not
  ownership-checked". Small (60 commits, 1 fix-like) and clean.
- **The `--facts=` dumps:** keyed by node kind and span, with no
  compiler ids. They are the ideal differential harness. A rewrite can
  diff its facts against the old compiler's on the whole suite.
- **The test assets:** the sema unit tests (about 1,600 lines), the
  `test/rig` cases, the oracle, and doc examples. These are the most
  valuable thing to carry over.
- **The grammar's `@schema`**, as a declared IR with named roles and
  `ir.slot(.kind, .role)`. The idea is right, even if the IR needs paren
  and bound nodes and a typed lowering stage after it.

## 6. Estimate of load-bearing design vs accumulated cruft

| Part | Lines | Load-bearing | Cruft/compensation | Notes |
|---|---|---|---|---|
| rig.grammar | 1.4k | ~90% | ~10% | dropped parens/bounds force wrapper work |
| rig.zig lexer | ~1.2k | ~65% | ~35% | contextual-keyword probes, flag state |
| rig.zig wrapper diagnostics | ~0.9k | ~95% | ~5% | keep |
| rig.zig wrapper rewrites | ~1.4k | ~45% | ~55% | receiver sigil, side tables, builtinRefs, in-place desugaring, forged positions |
| rig.zig misc (IR helpers, Zig idents, tests) | ~1.9k | ~85% | ~15% | misplaced, not wrong |
| sema.zig code (excl. comments, tests) | ~9.6k | ~65-70% | ~30-35% | god context, duplicated walkers, 3 memo systems, import proxies, widen/restore, early window, quiet |
| resolve.zig | 5.4k | ~80% | ~20% | hard-wired builtins duplicated per module; name-string resolution |
| modules.zig | 0.9k | ~90% | ~10% | re-check loop is the one structural wart |

**Overall: roughly 70% load-bearing and 30% cruft by lines.** Line count
understates the gain, though. The structural items (1.1 to 1.6) cost
more than their lines:

- they cause the double check
- they force the decision verification
- they make every walker carry a module context
- they make every new type kind touch about 160 switch sites
- they keep the "is a view" fact from being unified

A rewrite that only reorganized files would recover little. A rewrite
that changes the IR and the phase structure would remove most of it.

**Confidence: medium.** I read about 15% of the area's lines closely.
The structural findings (1.1 to 1.8) are certain, because they are
directly visible in the code and the docs admit several of them. The
percentage split is a judgment from sampling, ±10 points.

## 7. What a rewrite should do differently here

1. **A hand-written parser over a layout-aware lexer**, so contextual
   keywords, prefix-sigil precedence over call chains, and parentheses
   are decided in the parser. The IR keeps `paren` and type-parameter
   bounds, so there are no side tables.
2. **A dense node id for every node.** Facts live in arrays indexed by
   id, never by source position or pointer. Synthetic nodes are real
   nodes.
3. **Strict phases:**
   - parse
   - resolve (program-wide, prelude as an outer scope)
   - type (producing a typed HIR plus fact tables)
   - **lower** (iterator loops, byte literals, tail drops, closure
     padding, implicit lends made explicit)
   - MIR, which storage, ownership, proofs, and emit read

   Nothing mutates an earlier phase's output, and nothing is checked
   twice.
4. **One program-wide `TypeStore` and symbol table**, with built-ins
   declared once (in Rig, intrinsics marked), not per module and not in
   two mechanisms.
5. **One structural type visitor.** Type facts are folds over it,
   computed in SCC order and finished before typecheck reads them, so no
   lazy memo or verification is needed.
6. **A context per phase**, with storage, inlining, and frame state
   taken out of `SemContext`, and **environments passed as arguments**
   (bounds, speculative mode) instead of global flags with save and
   restore.
7. **Settle the open questions before coding:**
   - the kind of a `?String` (view or plain), which removes the
     `string_view` special kind
   - the per-expression "is a view" fact
   - the naming: self, not receiver; object, not struct; closure, not
     lambda
