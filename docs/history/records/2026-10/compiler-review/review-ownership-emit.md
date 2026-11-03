# Rewrite review: ownership and code generation

Area: `src/ownership.zig` (8,918 lines, about 440 of them unit tests),
`src/storage.zig` (2,173), `src/facts.zig` (1,428), `src/emit.zig`
(11,589; 587 KB, so long lines), with `src/runtime.zig` read only where
emit leans on it. Read only; nothing built or run. Line numbers are at
`144f70057`.

Commit counts (`git log --follow`): emit 616 (61 in May, 237 in Sep,
453 in Oct), ownership 404, facts 119 and storage 81 (both created in
October by consolidation step 10). About 48 of October's 451 emit
commits are about addresses, slots, copies, or temporaries: the
weak-spots classes.

## Summary

The area has a sound core: a flow-sensitive ownership checker with
trail-based snapshots and field paths, a storage plan whose answers are
cached once and checked again, and a `Facts` boundary that keeps
emit from importing the classifiers. Two structural facts produce most
of the cruft:

1. **Three walks of one tree.** The storage planner
   (`storage.zig:1691`), the ownership checker, and the emitter each
   walk the same semantic IR (`Sexp`) with their own per-construct code.
   The proof pass adds a fourth model ("units"). They agree only by
   convention and by assertions that fire when emit runs (`hiddenStorage`,
   `inUnit`, `copiesSubject`, `verifyDecisions`). Nothing makes them
   agree by construction.
2. **No lowered IR between the checked tree and Zig text.** Emit goes
   straight from `Sexp` to strings. Each coercion, hidden storage
   location, evaluation-order fix, and address is a branch inside a
   recursive text writer, steered by about 20 mutable mode fields on
   `Emitter`.

The oracle (`test/oracle/lower.zig`, `core.zig`, `flow.zig`; 7.2k
lines in all) already shows the alternative. It lowers each body once
to vars, blocks, and steps, with every temporary a hidden var and the
evaluation order written out, then runs dataflow over that alone
(`lower.zig:1-15`, `core.zig:1-4`). That is the architecture a rewrite
should adopt for the compiler itself, with emit consuming the same
lowered form.

Estimate: **about 60-65% load-bearing design, 35-40% accumulated
cruft** (patch stacks, duplicate classifiers, mode flags, compatibility
paths, forwarding layers). Confidence: moderate. I read about 15% of
the lines closely and sampled the rest by grep and structure.

---

## 1. Emit still decides, or derives again, facts the checkers own

**a. "Is this binding used" is derived twice.** Emit's own `Scan`
(`emit.zig:11197-11236`) fills `usage.used`. The storage planner works
out the same thing separately from `ctx.facts.names` (`storage.zig:1414-1418`,
`isUsed` at 1688). The two must agree: the planner records a `catch`'s
`error_value` storage only when the name is used (`storage.zig:1786`),
and emit asks for that storage only when *its* set says so
(`emit.zig:7632`, also 4200, 4301, 4355, 5254, 5411-5512, 6781, 6854).
The rules differ slightly: emit skips compile-time functions
(`emit.zig:11231`), and storage reads `facts.names`. A disagreement is
an internal error at emit time, not a fact read once. `Scan`'s doc
comment also still promises "used or consumed, and which match bindings
view which scrutinee" (`emit.zig:11199-11201`). Only `used` is left.

**b. Built-in identity is decided by name text in three passes.**
- `swap`: `ownership.zig:5908` (`isSwapBuiltin`, which falls back to
  `self.find("swap")` without sema), `emit.zig:8248` (`isSwapCall`), and
  sema's `swapsTwoPlaces` behind `Facts.swapsTwoPlaces`.
- `print` and `warn`: `ownership.zig:5979` (`isPrint`) and
  `storage.zig:89` (`printCall`, read by emit through `Facts.printCall`).
- `none`: `storage.zig:72` (`isNoneLeaf`, by text) and the emit
  literal writer (`emit.zig:5963`, 11291, 11304, 11350).

INTERNALS says emit never matches names. These are small, but they
break "one classifier per fact".

**c. Method dispatch by name, inside emit.** `emitCallPlain`
(`emit.zig:8850`, 276 lines) is an ordered chain of more than 25
`if (special) return` tests. Several pick a lowering by method name and
receiver type, which typecheck also had to decide:
- `is_empty` (`8939`);
- `push`, `pop`, `clear`, `keep`, and `get` on a `Cell` holding a List (`8947-8957`);
- `wait_first` (`9085`);
- `get` on a sequence (`9097`);
- `set`, `swap`, `compare_swap`, `add`, and `sub` on a Cell (`9109`);
- `len` (`7434-7451`, four branches);
- `unbox` (`7511`).

`Facts.callTargetOf` and `dispatchOf` exist, but these built-ins bypass
them.

**d. Pointer or copy for a binding.** `emitBind` (`emit.zig:2902-2925`)
works out `binds_view`, `copies`, `is_lend`, and `holds_ptr` from the
type, the syntax (`expr.isKind(.read)`), and an exception list
(`writeSliceElem`, `callableFn`, `objectView`). Whether a local is a
pointer into a place or a copy is a storage decision the ownership
checker cannot see. It is safe today only because the checker treats
every bound view as carrying its loans whatever emit picks.

**e. Derive, then assert.** `copiesSubject` (`emit.zig:2672-2676`)
works out `hasTemps && !headerPoints` and fails if the answer differs
from the recorded `copiesHeader`. The fact is recorded, yet emit still
derives it and compares, which shows the rule's owner is not settled.

**f. Lowering by type, decided locally.** Emit has its own type
predicates for how a value is spelled:
- `comparesStructurally` (`10935`), which also decides whether `==` is
  structural, a question typecheck must answer the same way;
- `isPlainTy` (`10891`), `isScalarTy` (`10966`), `hasLen` (`10879`),
  `isStructLike` (`10865`), `isCellListTy` (`10819`), `loopElem` (`10855`);
- 124 calls of `self.facts.types.get(...)`.

They do not affect ownership, but they repeat decisions typecheck made
about the same expressions.

**g. The guard is a blacklist.** The facts unit test
(`facts.zig:1173-1217`) checks imports and forbids only the substrings
`.pending.` and `moves(`. It does not stop `Facts` methods from calling
classifiers: about 177 of them forward straight to `sema.*` or
`storage.*` (for example `lendByValue`, `viewHeldAsPointer`,
`optionalRouted`, and `cloneable`, `facts.zig:1096-1135`), and a
`syntax` table re-exports 31 IR helpers (`facts.zig:1139-1170`). The
boundary is real, but it sits at the file level, not the decision level.

## 2. Patch stacks

**a. Re-entrant wrapper sentinels in `emitValue`** (`emit.zig:5622-5700`).
Each coercion (splat, API-object erasure, failing through `__out`,
optional lift, code widening, keeping a temporary) is a guarded block.
It sets a sentinel field to the node, writes a prefix, calls
`emitValue` on the *same node* again, and the sentinel stops a second
application. The sentinel fields are `splatting`, `erasing_box`,
`failing`, `lifting`, `widening`, and `keeping` (`emit.zig:449-470`,
`531`). This is the clearest sign of a missing coercion layer: in a
lowered IR each would be an explicit node that typecheck inserts once.

**b. About 20 dynamic-scope mode flags on `Emitter`** (`emit.zig:371-535`):
`bare`, `ptr_tail`, `use`/`use_node`, `want_ptr`, `rt_names`,
`keep_comptime`, `literal_ty`, `place_chain`, `lending`, `read_place`,
`subject_path`, `error_codes`, `fail_slot`, `part_name`, and the six
sentinels above. There are 71 `defer self.X = saved` restores.
`read_place` alone is touched 43 times with 26 save/restore pairs.
Some context travels both as a parameter and as a field:
`emitList(sexp, tail, bare, literal_ty)` (`6488`) beside `self.bare`
and `self.literal_ty`. Correctness depends on every caller setting and
restoring the right flags.

**c. The call-dispatch chain** (above, 1c). Each runtime feature got
its own fact and its own branch:
- facts: `isHttpServe`, `isIoCopy`, `isReduceCall`, `isSuperviseCall`,
  `isIsolateCall`, `isChanMake`, `isActorMake`, `isFrozenMake`,
  `isSelect`, `parCallOf`, `isTaskJoin` (`facts.zig:404-554`);
- matching fact maps in `sema.Facts`, 67 in all (`sema.zig:1764-1976`);
- branches in `emit.zig:8966-9070`.

Errors with fields were then threaded through all of them as `XInto`
twins (`takeFailSlot`/`fail_slot`, 30 uses; 10 `*Into` runtime entry
points). Editing has left comments detached from their code: the
`par.map` comment at `emit.zig:8973-8975` sits above the actor-call
branch, its code at ~9058; the `io.copy` comment at `9019` sits above
`reduce`.

**d. Match lowering spread over seven facts.** One `match` reads
`matchMode`, `matchesInPlace`, `holdsView`, `matchRereads`,
`matchBlock`, `subjectHold`, and `headerOf`, plus `copiesSubject`
(`emit.zig:4451-4495`). The subject is re-read by pasting Zig *text*
(`placeText`, `MatchInfo.reread`, `4798`). Together these make one
lowering plan, split into flags.

**e. About ten address producers.** `emitAddressOf` (6888),
`emitLeafPtr` (7604), `emitWriteViewPtr` (6413), `emitSubjectPtr`
(2647), `emitReceiverAddress` (1682), `emitLendAddress` (6186),
`emitCellPtr` (9142), `emitCellAddress` (9163), `emitHeldAddress`
(9178), and `emitSlotAddress` (9810). weak-spots.md ("Addresses of Zig
rvalues") names the missing structural chokepoint. INTERNALS' "Addresses
of Zig temporaries" (`INTERNALS.md:4791`) reads as a list of exceptions.
`rig.noneAt` (`runtime.zig:~1677`) hands out a *mutable* pointer to a
static `none` "never written": a patch for one leaf shape.

**f. Lazy decisions, checked again afterwards.** Storage answers are
computed on first ask, cached (`decideAt`, `storage.zig:1379`), forced
early by a walk full of `_ = question(ctx, e)` lines (`storage.zig:1705-1789`),
and then all computed again by `verifyDecisions` (`1388-1404`) to catch
"two passes acted on differently". It is a good safety net. It exists
because the decisions are not made in one pass that owns them.

## 3. Leftovers

- **The ownership checker without sema.** `Checker.sema` is optional
  (`ownership.zig:661`), and there are 149 `if (self.sema)` /
  `self.sema orelse` branches. Only the ~20 unit tests that use
  `checkSource`, `expectError`, and `expectClean` (`ownership.zig:8501-8590`)
  run it without sema; `modules.zig:841` and `proofs.zig:2206` always
  pass it. It is the remnant of a pre-sema checker, and keeps a weaker
  fallback behind each check (for example `isSwapBuiltin`'s
  `self.find("swap")`).
- **Its own name resolver.** Vars are found by source text through
  `names: StringHashMap` and a scope walk with closure-crossing rules
  (`ownership.zig:670`, `find` at 1738; 19 uses), though sema already
  resolved every name to a `SymbolId`. The checker maps back to symbols
  where it needs them (`symbolAt(v.decl)`, 1690).
- **Stale prose:**
  - emit's header promises facts "from sema's facts table (`sema.zig`)"
    and says "`!@` receivers" (`emit.zig:6-8`, 21);
  - INTERNALS says bindings are `var` when "holding a value that moves
    (`sema.moves`)" (`INTERNALS.md` Emit, "Bindings"), which emit is
    forbidden to call;
  - the doc comment of `unsupported` is orphaned above the "Units"
    banner (`emit.zig:11064-11066`), and the function is at 11190.
- **Vocabulary.** "receiver" appears about 200 times across the four
  files: `hoistReceiver`, `receiverHold`, `consumesReceiver`,
  `ReceiverHold`, `MethodReceiver`, `StorageKind.receiver` →
  `__rig_recv`. AGENTS.md says "self". "struct" is used for Rig objects
  in places (`ownership.zig:21`, 684, 3176).
- **Two meanings for `discardsValue`:** sema's (`ctx.discardsValue`,
  whether a result is unused, which ownership reads) and emit's own
  (`emit.zig:2726`, whether Zig needs `_ =`).
- **Forwarding layers.** 22 one-line emit wrappers forward to `Facts`
  (`peelViews`, `variantPayload`, `isNoneLeaf`, …), and about 177
  `Facts` methods forward one line to sema or storage. That makes three
  hops for one type question.
- **Odd key encodings.** `erasedKey` packs a source position or
  `list.id | 1<<32` into one `u64` (`emit.zig:234`). `PartKey` and
  `facts.NodeKey` do similar work.
- **What is absent.** There are no `TODO`, `legacy`, `compat`,
  `workaround`, or `FIXME` markers in the four files. The cruft is
  structural, not marked.

## 4. Structural problems a rewrite fixes and increments cannot

1. **The checker walks a different structure than emit writes.**
   Ownership reads storage facts in only a few places:
   - `holdForCall`/`heldForCall` for receivers and copied arguments
     (`ownership.zig:5226-5250`);
   - match mode and `holdsView` (6938-7141);
   - `forConsumes` (7356), `stepPoint` (7498), and `eachSetStep` (4697).

   Emit reads many more that ownership never consults: `leafStep`,
   `headerPoints`, `hoistsArgs`, `fillsInPlace`, `dropKind`,
   `setOrder`, `printsByAddress`, `argumentHold` for owned arguments,
   and `zig_temp`. Ownership assumes source-order evaluation, while emit
   hoists arguments (`decideHoistsArgs`, `storage.zig:270`) to restore
   that order. weak-spots.md still lists call and `print` argument order
   as open. "The checker checks exactly what is emitted" holds for the
   storage that has facts, not for evaluation order or for every address.
2. **A lowered IR is missing.** A rewrite should lower each checked body
   once to explicit vars, temporaries, moves, lends, drops, coercions,
   and an explicit order, the oracle's `core`. Then ownership, proofs,
   and emit consume that one form. This removes:
   - the storage plan as a separate walk;
   - the units assertion (`emit.zig:11074-11120`);
   - the wrapper sentinels and mode flags;
   - `copiesSubject`-style cross-checks;
   - most of the weak-spots list (statement temporaries, payload views,
     Zig rvalue addresses, evaluation order), which are all "emit and
     checker each model the same thing" bugs.
3. **Per-function mutable state.** `Emitter.fun: FunState` (24 fields,
   `emit.zig:293-357`, 58 uses) is saved and restored by hand around
   closures (`10212-10214`). The ownership `Checker` struct has about 64
   state fields (`ownership.zig:655-840`). Both are easier with a
   per-function context value built from a lowered body.
4. **Large dispatchers.**
   - emit: `emitList` (344 lines, 6488), `emitElemCall` (307, 8370),
     `emitCallPlain` (276), `emitMatch` (247), `emitTypeTy` (151),
     `emitOptionalHead` (145), `emitIndex` (143);
   - ownership: `walkCallBody` (322, 5291), `walkMatch` (138).

   None is huge on its own. The size is in the breadth of special cases,
   not in depth.
5. **Two classifiers for drop glue.** The checker counts drops from
   sema's `resourceKind` and `typeHasDropGlue`. The runtime decides what
   a drop does by Zig comptime reflection (`needsDrop`, `dropElement`,
   `@hasDecl(T, "__rig_drop")`, `runtime.zig:1553-1597`). It works, and
   the leak checker backs it, but these are two derivations of "this
   type needs cleanup". A rewrite should emit drop glue from one decision.

## 5. What is solid; carry it over unchanged

- **The ownership abstract state** (`ownership.zig:1-130`): `Var` plus
  `Flow`, a trail of writes undone to a `Point`, so branch snapshots
  cost what changed; loans as root plus `PathId` with prefix conflicts
  (field-disjoint loans); joins; the loop fixpoint with diagnostics on
  the final walk; external loans on view parameters; `checkOrigins`
  against the signature. The rules header is a good spec in itself.
- **Recorded decisions, checked again:** the `decided`/`verifyDecisions`
  mechanism (`storage.zig:1361-1404`). Keep it as an assertion over the
  lowered IR.
- **Every hidden storage location named through one function**
  (`hiddenStorage`, `emit.zig:2221-2265`), with the 30
  `StorageKind`s and their `life`, and sanitizer poisoning of every such
  `var`. This is the seed of the lowered IR's var table.
- **`need()` and `unsupported()`** (`emit.zig:2280`, 11190): an absent
  decision is an internal error, never a guess.
- **Name mangling:** `rig.writeZigIdent` is one-to-one, context-free,
  `__rig_` prefixed, and `'`-suffixed for Zig hooks (INTERNALS, Emit,
  "Names").
- **Drop guards:** a `defer` with a flag, `rig.take`, per-field flags,
  and `rig.dropParts` (`emit.zig:2296-2380`, `runtime.zig:1588-1690`).
  This is simple, and Zig's `defer` covers every exit.
- **Representations:** `rig.Opt` with niches, the one-store `pack`, the
  `ReadView(T)` rule for generics, the error glue file
  (`writeErrorGlue`, `emit.zig:92`), and witnesses for APIs.
- **Facts-only emit at the import level.** Keep the idea, but enforce it
  by type (emit receives the lowered IR and nothing else), not by
  substring scan.
- **The oracle** as an independent second checker, and as the template
  for the new core.

## Rough sizing

| Part | Lines | Load-bearing (est.) | Cruft (est.) |
|---|---|---|---|
| ownership.zig (excluding tests) | ~8,480 | ~65% (flow engine, rules, origins) | ~35% (sema-optional paths, its own name resolver, built-in special cases, duplicate classifiers) |
| storage.zig | 2,173 | ~70% as decisions | ~30% as a separate walk and lazy-memo plumbing a lowering would subsume |
| facts.zig | 1,428 | ~40% (boundary, tests) | ~60% one-line forwarders and re-exports |
| emit.zig | 11,589 | ~60% (representation, names, drops, optionals, errors, witnesses) | ~40% (mode flags, sentinels, call-dispatch chain, address variants, re-derived predicates, the usage scan) |

Overall about 60-65% design, 35-40% accumulation. With a lowered core
IR, I would expect emit to shrink by a third or more, and ownership plus
storage to merge into lowering plus dataflow near the oracle's size
(7.2k lines today, though it abstains on some shapes). Confidence:
moderate. The direction is clear; the percentages are judgment from
sampling.
