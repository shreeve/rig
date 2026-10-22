Owner: "revive #229 or redo it so that it can ride on a good foundation" (2026-10-15). Plan by a Plan agent; checked by the foreman.

# Brief: inline (step 3), on frameowners

**Start** when #237 merges. Branch `inline2` from `main`. The reference is tag `archive/inline` (794943cbc). Don't merge it: its base is 5f1badec7, before #230 and #237, and six files conflict (`src/inlining.zig`, `src/typecheck.zig`, `src/sema.zig`, `src/main.zig`, `docs/INTERNALS.md`, `SPEC.md`).

## What #237 already gives you
- `frame_owners` plus `ownerOf`, `frame_calls` (with `copies` per defer exit), and `Account{own, marked, auto}`.
- `fits()` per owner, with unknown `own` failing every limit, and `compiled` owners.
- **Receiver-type call resolution is done.** `SemContext.callTargetOf` is recorded at the four resolution sites:
  - `functionCall`, method call, `associatedCall`, cross-module call (`noteTarget` / `noteMethodTarget`, which follows proxies).
  - `inlining.Pass.target` reads it and falls back to name groups only for calls nothing resolved.
  - Test: `test/cli/inline.sh` `wrappers.rig` (`Binder.kind` is inlined; `Node.kind`, which calls itself through a field, is not).
- Step 3 only routes `inline` calls through that same fact. `decide` must never resolve a name for a marked call.

## Revive or redo, by file
| File / part | Verdict |
|---|---|
| `rig.grammar`: `INLINE` token, `mark: inline\|called\|rarely`, comments | REVIVE verbatim from 605d60ed7. Then re-sync Nexus. |
| `src/rig.zig`: `Marker.inline`, `classifyWord`, `misplacedMarker`, `repeated_marker`, messages; remove `no_inline_marker` | REVIVE |
| `src/resolve.zig`: `inline_marked` flag on symbols and `Field`s | REVIVE |
| `src/resolve.zig`: `inline_decls` key | REDO: key by #237's `FnRef{module,pos}` |
| `src/sema.zig`: `SymbolFlags.inline_marked` | REVIVE. Use the spare `_: u1` bit; no widening to u32. |
| `src/sema.zig`: `InlineCall{fun,subst,bytes}`, `inline_decls`/`inline_frames`/`inline_calls`, `recordInlineCall`, `inlineCallOf`, `declaringContext` | REVIVE |
| `src/sema.zig`: #229's own `FnRef{module,owner,index}`, `methodRef`, `FrameSize` | DROP. Keep one `FnRef`, #237's. Following proxies already lives in `noteMethodTarget`. |
| `src/sema.zig`: `Account.marked` | REDO: from `u128` to `FrameCount` (an inline callee's reach is larger than its bytes; both must land in the caller) |
| `typecheck`: `functionValue` rejection, `inst_own`, `inlineFrame`, `addInlined`, `unknownFrame` (fail closed), unit test | REVIVE |
| `typecheck`: `noteInline` | REDO: one helper records the target and, when the callee is `inline`, the instance subst, at the same four sites (one fact per call) |
| `typecheck`: `FrameWalker` integration | REDO. `addInlined` runs in `ownerFrame`'s per-owner walk. Slots are tagged `marked` so the account reports them apart, and `checkFrame` limits own+marked. Defer copies come free from `deferBody`. Delete #229's `.fun` skip and `captures_only`. An `inline` function stays an owner but never goes into `large_frames`. |
| `inlining.zig` | REDO on #237's `Pass`. Keep #229's ideas: the `marker` field, `forcedCycles` DFS with `cycleError` naming `Type.m`, `byRule`, `largestIn`, and the rule never un-inlining a marked function. Edges are `owner(f).calls` whose call target is marked `inline`. `added(o)` adds `copies * added(owner(g))` for each inline callee `g` (its `auto` lands in the caller), so the 64 KiB cap reaches through it. `fits` includes `marked`. Drop `cur`, the `closures` counter, `by_node`, `declared()`, `InlineEdge.bytes` and `unknown_frame` (null `own` already covers them). Replace `biggest.?` with an internal error. |
| `src/main.zig`: run `decide` before `writeAllDiagnostics` (cycle errors come from `decide`) | REVIVE |
| `src/main.zig`: `--facts=frames` | #237's printer, plus a marked column |
| `src/emit.zig` | No change for the marker (`isInlined` already writes `inline fn`; `inline` wins over `noinline`). ADD: in debug builds, an internal error if emit writes a call to a Rig function whose `callTargetOf` is `.none` or null, so "the checker checks exactly what is emitted" holds for the frame facts. |
| Docs: `SPEC.md` "Function markers", `SYNTAX.md`, `RIG-MANTRAS.md` | REVIVE |
| Docs: `INTERNALS.md` Inlining | REDO in frame-owner terms (the marked part) |
| Docs: `TODO.md` generic-members line | Delete when built |
| Tests: all 40-odd `marker_*`, `rev224-*`, `rev229-*`, `markers.sh`, `inline_budget.sh` | REVIVE |
| Tests: `inline_frames.sh` | Fold its cases (chain, generic instance, compile-time value, method directly and through a box, iterator) into `frames.sh` |

## Ordered steps
1. **Bench baseline first.** `bench/hash` on main has no ensure rows (#240 timed them ad hoc). Add hit and miss rows for `ensure`, `ensure_with`, and `edit`-then-`put`, Int and String keys, each in a `called` group. Time on main in a Mac exclusive window with load under 4.
2. **Tests first, failing** (list below). Record each one's failure on main or on #237's head.
3. Syntax: grammar, `rig.zig`, `resolve.zig`, flags, value-use / `main` / `extern zig` / two-marker rejections.
4. Typecheck facts: `InlineCall` at the four sites, `inlineFrame` per declaring module, `addInlined` in owner walks, `Account.marked`.
5. `decide`: marked functions, cycles, chain accounting, `fits` with marked, no panic.
6. Small generic members:
   - Drop `!o.of_generic_type` from eligibility, and fix #237's per-instance default (risk 1 below). A generic owner with no instance recorded anywhere becomes `compiled = false`. One whose instances are not all counted gets `own = null`, so it is never inlined.
   - Decide per declaration: emit writes one Zig declaration for all instances. Its frame is the largest over every instance, which is a sound bound.
   - Check that `rig.rt` laundering applies to generic-type methods: inline it, pass a literal, and confirm the overflow panics at run time.
   - Measure. If `ensure` or `ensure_with` is over `max_size` (60 nodes), mark them (or `find`) `inline fun` in `std/hash.rig` and re-measure.
7. Emit's target assertion. Then docs.
8. Gates, review, merge. Then tell Trig (the five-line `ensure` rerun), json (`inline fun number`, the two-copy reader) and Nexus (grammar).

## Tests that must exist before the code
**One per old finding, with whether #237's design removes its class:**

| Finding | Class removed by #237? | Test |
|---|---|---|
| #224 r1: generic inline frames uncounted | No. #229's recorded subst plus `addInlined` fixes it, so revive it. | `rev224-generic-frame`, `marker_generic_frame`, `rev229-nested-generic`, `marker_generic_instances` |
| #224 r1: test-block calls unchecked | Yes: a test block is an owner | `marker_frame_in_test`; `frame_owners.sh` test-pile |
| #224 r1 (wrong reject): same-name std wrapper read as a cycle | Yes: the call-target fact plus `byRule` | `rev224-std-wrapper`; `inline.sh` `wrappers.rig` |
| #224 r1 (wrong reject): closure calls attributed to the outer function | Yes: `ownerOf` | `rev229-closure-self`, `marker_frame_siblings` |
| #224 r2: alias across modules, lookup by position fails open | Yes: the target is recorded at resolution with the declaring module, and a miss is an error | `rev224-alias-frame`, `reject/modules/marker_frame_alias`, `marker_frame_across` |
| #229 r1: unknown own frame counted as 0, so a wrapper was inlined (80 MB) | Mostly: null `own` is never inlined. The residual is #237's per-instance `.{0,0}` default. | `rev229-wrap-generic`; NEW sibling: a generic member whose only instance is made inside another generic body or another module |
| #229 r2: inline call inside a closure omitted | Yes: a closure is an owner | `rev229-closure-pile` with the reviewer's original `inline fun g` (crashes on 794943cbc) |
| Step 3 chain | n/a | `rev229-chain-pile`: `a` (rule) calls `g` (`inline`), which calls `w` (rule), 300 times; prints `91200`, sanitizer-clean |

**Siblings (inline variants of `frame_owners.sh`):** one `inline` call in each of:
- a `defer` at 1,200 exits (marked counted per copy);
- an `errdefer`;
- a `drop` body;
- a match arm;
- an iterator `next` (the rewrite's call node);
- `main`;
- a nested closure;
- a generic instance made in another module.

**Other new tests:**
- An `inline` function large enough to be noinline: it is never written `noinline`, and the caller's reach gets it.
- An `inline` member of a generic type, cross-module.
- The `ensure` emit check: `pub inline fn ensure` appears in the `Map` instance.
- `frames.sh`: every owner with marked calls holds its account at or above Zig's prologue reservation, within 4 KiB, in debug. Also in `--release` for owners with only marked callees.

## Risks: where a second soundness round could come from
1. **Defaults that fail open.**
   - #237 sets `own = instances.get(..) orelse {0,0}` for per-instance owners. That is harmless while generic members are never inlined. Once they are, it is #229 r1 again.
   - Also grep for any other `orelse 0` or `orelse .{0,0}` on frame paths.
2. **Calls emit writes that have no recorded target.** In `target()`, `.none` means "no frame". That is sound only if no Rig function hides behind it:
   - operator or builtin dispatch;
   - drop glue calling a user `drop`;
   - generic bodies calling through a type variable. Today these are builtins only; `hash` can't be user-defined (`SPEC.md`).
   - The emit assertion in step 7 turns this into a crash in the suite, not in the field.
3. **Double paths for one callee.** Marked values are counted by typecheck, and marked `auto` by `decide`. Missing the second is the chain-pile bug. Counting both twice is only conservative.
4. **`inline` × #230.** `large_frames`/`noinline` and the reach factor: an `inline` callee's reach must be added at every call and every copy. Use `marked` as a `FrameCount`, never as bytes alone.
5. **Generic instances counted in modules that failed**, or made only under `--tests` (the `compiled` flag).
6. **Cycle edges.** A cycle through a generic instance or an alias must still be found (`rev224-generic-cycle`, `rev229-cycle-objects`).

## Gates
- **Mac (`-j 2`):** build, unit tests (fresh cache), vocab, style, `frames.sh`, `frame_owners.sh`, `markers.sh`, `inline_budget.sh`.
- **burst** (`--note "#<PR> inline2"`, `--ship test/json/data`), one at a time:
  - suite `--delta`;
  - corpus `--delta`;
  - the **full matrix** (this is classifier work);
  - `inline_grid` (all three release shards).
- **equiv** against the main it merges. Only new tests and SPEC examples may change in `check`/`facts`. Every `emit` diff must fall into one of exactly these categories, counted, with zero others:
  - `pub fn` to `pub inline fn` in generic types;
  - parameters renamed `__rig_in_`;
  - `rig.rt` laundering.
- **JSON benchmark guard** (`bench/json/guard.py`): no row slower.
- **`bench/check/guard.py`:** `rig check` time per pass within its bounds.
- **Mac timing window** (`cpuq --exclusive`, load under 4, fastest of interleaved runs):
  - hits: `ensure` and `ensure_with` each within 2% of `edit`-then-`put`;
  - no `bench/hash` row more than 2% slower than main.
- **One adversarial review**, aimed at risks 1–6. A second soundness round stops the feature again.

## Size
- **Source:** about +600 / −150 net.
  - `typecheck` about +180, `inlining.zig` about +170 (−120), `sema.zig` about +90, `rig.zig`/grammar/`resolve.zig` about +70, emit/main about +30.
- **Tests:** about +1,000 (about 750 revived, 250 new).
- **Docs:** about +150.
- **Total:** about 60 files and about 1,800 lines, roughly #229's size. Expect 1–1.5 agent days plus a burst matrix and one Mac window.

### Critical Files for Implementation
- `/Users/shreeve/Data/Code/rig/src/inlining.zig`
- `/Users/shreeve/Data/Code/rig/src/typecheck.zig`
- `/Users/shreeve/Data/Code/rig/src/sema.zig`
- `/Users/shreeve/Data/Code/rig/rig.grammar` and `/Users/shreeve/Data/Code/rig/src/rig.zig`
- `/Users/shreeve/Data/Code/rig/test/cli/frame_owners.sh` and `/Users/shreeve/Data/Code/rig/bench/hash/map.rig`
## Added by the foreman after #237's report
- std.hash: #237's receiver-type resolution now inlines `Symbols.intern`, `Symbols.rebuild` and `Table.reset` (main kept them out of line only through a name clash). Map's and Set's growth is deliberately `rarely`; mark `Symbols.rebuild` (and `Table.reset` if it's growth-only) `rarely` too, and keep it only if the Mac window shows no bench/hash row slower.
- The fail-closed per-instance default (risk 1) is yours: #237 left `own = .{0,0}` for a generic owner with no recorded instance because making it unknown un-inlined std's small helpers in 76 programs. Tell "no instance at all" (compiled = false) from "instances but no frame record" (own = null) using the instance lists.
- Follow-ups already on main, from #237's review (TODO.md, not this round): nested `defer`s make `rig check` store 3^k entries; the expansion limit counts a call once, not once per copy.
