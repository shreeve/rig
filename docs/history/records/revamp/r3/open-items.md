# Open items that must not be lost (post-v0.2.0)

Each item stays open until its fix is merged into `main` and a test in the repo guards it. Check this list before every merge and every round.

## B4a (b4-emit) must not merge until both are done
- [x] **B4a-M1, latent (introduced by B4a):** FIXED in b7e89291 (re-review clean, review-b4a-round2.md). a guarded `match w.r` where the field `r` holds a generic read view points into a `rig.viewed(...)` temporary after its statement.
  - **Fix:** one classifier drives both the storage fact and emit; reach the view in place.
  - **Guards:**
    - an emit_shapes.sh check (no `&rig.viewed(` field address);
    - behavior tests g20 and g22;
    - corpus probe g21.
  - **Source:** review-b4a.md; probes/review-b4a/g20,g21,g22.
- [x] **B4b-C1, critical for B4b:** FIXED in b7e89291 by `startsOutsideHeader`; unit test plus reject test header_place_inside_temporary (re-review clean). `headerPoints` says "point" for a place reached through a view of the header's own temporary (`match id(?mk()).e`, `(?mk()).e`, `for x in id(?mk()).xs`, `if`/`while id(?mk()).o as n`).
  - **Fix:** the classifier treats such paths as copies, and they stay rejected.
  - **Guards:**
    - a reject test for x05, x05b and x05c;
    - a unit test for `headerPoints`.
  - **Source:** review-b4a.md; probes/review-b4a/x05*.

## Must be re-checked when B4b lifts the limits
- [ ] Re-run every review-b4a probe under the real B4b (not the experiment): x05*, g20–g22, x03, x04, x12–x16. All must be either rejected or sanitizer-clean with correct output.
- [ ] Decide the `as` rejection over a Cell holder separately (review-b4a: still on in the experiment).

## Other open items
- [ ] **v0.2.1 hotfix:** the independent review is pending (review-hotfix7.md). Rebase after #52, then PR, release and tag.
- [ ] **Round C's known compiler-stricter cases** (in test/oracle/differences): match_arm_writes, write_result_whole, stored_whole, and a generic callee's argument write lend.
- [ ] **The `(?T?)?` hint bug:** the compiler suggests `(?Text?)?`; it should suggest `(?Text)?` (text-rule/redteam.md).
- [ ] **The domain-model trap:** literal-only `String` fields fail with a misleading "store a Text" hint (text-rule/readability.md). Stage 1 (`Static`) fixes it.
- [ ] **unbox method shadowing:** a Box's own methods hide T's methods with the same name. `^T` (with no `unbox`) fixes it.

## From the v0.2.1 hotfix review (review-hotfix7.md), Low, all predating the hotfix
- [ ] **Oracle disagreement p26** (generic `if getw(w).p as v` / `return take(<v)`): the compiler accepts (sound) and the oracle rejects with C7. Fix the oracle's model; this shape can't be allowlisted.
- [ ] **`*T` at a view type through generics:** `H[?Int]` holding `*(?n)` is accepted (f04), while `*?Int` written directly is rejected. Add a `not_view` requirement next to `not_function`. Loans are still tracked, so it's not a hole.
- [ ] **Two hints:**
  - The box-match hint suggests `match ?mkb(<x)`, which is then rejected (p46, p47).
  - The weak-upgrade hint always names `w` and `s`, even when those names are already in scope (w04, w05).
- [ ] **Oracle gap p36:** the oracle accepts reassigning the subject while a payload that views it is live; the compiler correctly rejects. Add an oracle test.

- [ ] **Low, already there before B4a (review-b4a-round2):** B4b could later accept these two forms; they're sound but rejected today: a payload view leaving `match w.r?`, and returning a view from `match r` after `if w.r as r`.

## Seam 2 (branch `seam2`, "`!` lends any value to write")
- [ ] **Built on `seam2`, awaiting the independent review and merge.**
- [ ] **Nexus mirror re-sync:** `src/rig.zig` changed (the receiver-sigil rule now reaches a made or parenthesized receiver after `!`). Diff: logs/seam2/nexus-mirror-rig.zig.diff.
- [ ] **Owner decision (consistency):** `?mkc()`, a read lend of a temporary that holds a Cell, is still rejected ("a change through the view would have no place"), while `!mkc()` is accepted: the write lend keeps it in its statement's slot, which is that place. Lift the read rejection the same way, or keep it.
- [ ] **Pre-existing diagnostic:** `inc(!5)` and `inc(!(2 + 3))` report "type mismatch: expected `!Int`, got `!Int`" (an integer literal's type). It should say what `!false` now says: a literal is never lent to write.
- [x] **Fixed on `seam2` (pre-existing, accept-means-correct):** `setb(!false)` and `sets(!"abc")` were accepted by v0.2.1 and failed in Zig (`&false` is a const pointer). Now rejected: a literal lives for the whole program, as a constant does. Guard: test/reject/ownership/write_lend_temporary_rejected.rig.
- [x] **Fixed on `seam2` (emit, same class):** a write-lent temporary reached through `emitMemberBase` took the lend's type (`(slot.*).*` on a Text, `@as(*S, ...)`), and a write-lent branching temporary was wrapped in an `@as(T, ...)` copy, so the write would have reached a copy. Guards: write_lend_temporary_siblings.rig, write_lend_temporary_branches.rig, write_receiver_temporary_lent.rig.
- [ ] **Parse change to note in the release notes:** `!f(x).g()` and `!(e).g()` now lend `f(x)` / `e` as `g`'s receiver, where v0.2.1 lent `g`'s result. Equivalence: no accepted program changed. A program where `g` takes no `!self` and returns a write view would now be rejected with "`g` does not write its receiver; drop the `!`"; `!(f(x).g())` keeps the old meaning.

## Seam 2 review round 1 (review-seam2.md)
- [ ] **C1:** a store into a write-lent receiver with no name is lost. It's live in v0.2.1 via `wrap(!h).keep(?s.t)` (h06). Fixing it in seam2 in a separate commit, hotfix-able.
- [ ] **C2:** `<(!x).f` and `<(?x).f` move a field out through a lend. It's live in v0.2.1 (c08, c09, c14, c15). Fixing it in seam2 in a separate commit, hotfix-able.
- [ ] **M1:** `!Color.red` and `!E.bad` emit Zig that doesn't compile (v0.2.1). Fix: one "is a constant" classifier.
- [ ] **These pre-existing fixes must reach a release (v0.2.2)** whether or not seam 2 itself lands.
- [ ] **For the user:** seam 2's parse change (`!f(x).g()` now lends `f(x)` as g's receiver; `!(f(x).g())` keeps the old meaning).
- [ ] **For the user:** `?mkc()` (a read lend of a temporary holding a Cell) is rejected while `!mkc()` is accepted.
- [ ] **Nexus re-sync** for seam 2's src/rig.zig change.

## From the seam 2 review round 1 (review-seam2.md)
- [ ] **C1 (Critical, pre-existing class):** a store into a write receiver that is no named place was lost (`wrap(!h).keep(?s.t)`, `(!a if c else !b).keep(...)`: use-after-free on v0.2.1). Fixed on `seam2-hotfixes` (worktree rig-seam2-hf, from main 089169c1), cherry-picked to `seam2`. Guards: test/reject/ownership/store_into_unnamed_receiver.rig, test/behavior/ownership/store_into_unnamed_receiver.rig; seam 2's own forms in write_lend_temporary_stores.rig (oracle verdicts C5). Hotfix candidate for main.
- [ ] **C2 (Critical, pre-existing):** `<(!s).items`, `<(?s).items`, `<(!p).items` through a parameter, and `<(?v)[0]` moved a part out through a lend. Fixed on `seam2-hotfixes`, cherry-picked. Guards: test/reject/ownership/move_through_lend.rig, test/behavior/ownership/take_through_lend.rig. Hotfix candidate.
- [ ] **M1 (pre-existing):** `!Color.red`, `!E.bad`, `!false` and `!"abc"` were accepted and failed in Zig. One classifier, `isConstant` (literal, `none`, unit variant, error value, operator on constants); `!5`, `!-5` and `!(2 + 3)` get its message. Guard: test/reject/types/write_lend_constant.rig. Hotfix candidate. (Module constants and `const` bindings stay with `requireBinding`, by their binding facts.)
- [x] L1 hints and L4 reach: fixed on `seam2` only.
- [ ] **Oracle gaps:** the oracle abstains on `<(!x).f` ("a sigil on an accessed object") and on unsigiled write receivers that are no place (h06). Teach it, so C1/C2 are double-checked.

## SEAM 2 STOPPED (second soundness round; review-seam2-round2.md)
- [ ] **R2-1:** a store reached through a write loan in an assignment target is not recorded. It's live in v0.2.1: z11, z16, z02, z10. Being fixed as a class on seam2-hotfixes → v0.2.2.
- [ ] **R2-2:** the move-through-view check is syntactic. It's live in v0.2.1: w05, w16, w18. Fix it by type → v0.2.2.
- [ ] **R2-3:** type-level constants (`!Int.max`, `!U8.max`, imported variants) fail in Zig in v0.2.1. → v0.2.2.
- [ ] **Seam 2 redesign:** rebuild on top of the v0.2.2 class fixes, then a fresh review. The seam2 branch is frozen at c4b5e9f8 for reference.

## Seam 2 STOPPED after review round 2 (review-seam2-round2.md); v0.2.2 class fixes
- [x] Seam 2 stopped per AGENTS' second-round rule. Branch `seam2` is frozen at c4b5e9f8; it gets rebuilt as a redesign on top of v0.2.2.
- [ ] **v0.2.2 on `seam2-hotfixes`** (worktree rig-seam2-hf, on origin/main 0544af8a): cfc1d120, 4c2de16c, de34e52e, 0e44c503, e8e0fa87, b20a906a. Awaiting review, then PR and release.
  - R2-1: one `storeThroughLend` for calls and assignments (`(!h).r = v`, `wrap(!h).r = v`, `wv(!v)[0].r = v`).
  - R2-2: a move through a view is decided by the type on its path (`viewOnPath`), replacing the syntactic `lendOnPath`.
  - R2-3: `isConstant` classifies by meaning: number limits, variants of any module, and branches that are constants in every branch.
- [ ] **Oracle gaps to close:** the oracle abstains on `(!h).r = v` and `<(!s).f` ("a sigil on an accessed object") and on a write receiver with no `!` (h06). It accepts z01 and z07 (seam 2 forms).
- [ ] **Misleading note (Low, from round 2):** "`mkh()` still holds it after the statement" describes a holder dropped later within the statement. Seam 2's redesign should reword it.

## From the v0.2.2 review (review-v022.md)
- [ ] **Medium 2 (in v0.2.1 too):** assigning a closure to a `!fun` parameter (`g = |n| n + 100`) hits "internal error: cannot emit this expression". Accept-means-correct: fix it or reject it in sema.
- [ ] **Oracle gap:** the oracle flags `<(!s if c else !t).o` as unsound; the compiler is right. Fix the oracle model.
- [ ] **Conservative rule:** overwriting a field doesn't release the loan it held. This belongs with field-precise loans (after B4).

## Testing policy (DECIDED 2026-10-06, once pup is set up)
- **pup (Linux x86_64, about 16 cores via cpuq), the bulk:** the full corpus, full matrix, equivalence, the four gates, and fuzzing, every round (r3/pup-gates.sh).
- **Mac (macOS aarch64), targeted, every round:**
  - the build and the full suite;
  - `oracle doc vocab`;
  - the round's new tests and all reviewer probes under RIG_SANITIZE=1;
  - a random corpus sample, e.g. 10%.
- **Mac, full:** the complete corpus and matrix before every release.
- **GitHub CI:** Linux and macOS on every PR, unchanged.
- **The safety bar is unchanged:** a round merges only when pup's full gates, the Mac's targeted runs, the independent review and CI are all green.

## Speed: repo-side fixes for a small PR
- [ ] **test/run cleanup:** a sampled suite run deletes the build caches of every corpus program it didn't run (test/run lines 838–861). Fix it in the repo, so a sampled run never deletes caches of the kind it sampled. gates.sh already works around this with a separate RIG_TEST_OUT for the corpus.
- [ ] **CI:** cache test builds in macOS CI, and skip the heavy CI on version-only release PRs.

## Seam 2 redesign (`seam2b`, worktree rig-seam2b, on main d3504c38 = v0.2.2)
- [ ] **Built; awaiting the fresh independent review.** The old `seam2` branch is frozen as reference.
- [ ] **Nexus mirror re-sync of `src/rig.zig`.** Diff: logs/seam2b/nexus-mirror-rig.zig.diff.
- [x] Found while porting, fixed on `seam2b`: emit declared an assignment's temporary slots in tree order (target before value). That dropped the value's temporaries first, while the value is made first (Core §6) and the checker drops the target's first. `(!mkh()).r = ?mk(1).t` read a freed value in `mkh()`'s `drop`. Emit now orders value before target (f288c667). On main, both sides can't hold temporaries a view of each other, so this is seam 2 reach only.
- [x] The misleading "still holds it after the statement" note is reworded for a holder temporary (7e58af0c).
- [x] The oracle decides lend paths and write receivers whose value is a write view. All 154 round-1 and round-2 probes are in test/corpus/review-seam2-* with their oracle verdicts.
- [ ] **Owner decision still open:** `?mkc()`, a read lend of a Cell-holding temporary, is rejected while `!mkc()` is accepted.

## pup (READY 2026-10-06, r3/pup.md)
- **Helpers:**
  - `r3/pup.sh <branch> <cmd>`;
  - `r3/pup-gates.sh <branch> <prefix>`, run with `PUP_CORES=12`, since -j 16 pushes pup's load to ~50 and trips the valve;
  - `r3/pup-base.sh <commit>`, for equivalence bases.
- **Full gates take about 10 minutes at 16 cores,** versus 60–90 on the Mac.
- **A second backend:** pup's debug builds use Zig's self-hosted backend and linker (x86_64 Linux), so it tests a second code generator.
- **Disk:** a run leaves about 40 GB of test executables; pup-gates cleans up.
- **Every round uses pup for the full gates and equivalence,** plus the Mac's targeted runs, per the testing policy.

## From the seam2b review (review-seam2b.md), deferred
- [ ] **Low 4 (pre-existing, precision):** a call-held receiver inside a branch keeps its loan past the statement. `x = !a.me().bump() if c else 0`, then `!a.items.push(1)` is rejected; the temporary form is rejected as escaping. The hidden var the call holds is not ended (`endCallHeld`) inside the branch. Same on rig-v022. Probes zq01, zq03; fuzz runc.log `*__meb__cond*` (18).
- [ ] **Low 5 (pre-existing, precision):** `!a.me().me().bump()` is rejected ("a view of `a.me()` outlives the call"); a single `.me()` works. The oracle accepts. Probes zd03, zd04.
- [ ] **Low 6 (oracle gaps):** the oracle accepts `swap` of view-holding fields (zn01 pre-existing; e01, t01, t04, t05, t06), and a made write view as a loop's `break` value (e05: it treats it as a copy, where a binding is a view). The compiler rejects all of them.

## Seam2b fixes (2026-10-06)
- [x] Medium 1 (`writesTemp` fact, 1f5e16c6), Low 1 (holdsPastDrop via dropRunsBody, dff5d589), Low 2 + `as` hint (e4e327da, e416deb8). pup gates green on e416deb8; equivalence vs rig-v022: 0 accepted→rejected.
- [x] Targeted re-review of the four fix commits (review-seam2b-fixes.md): no soundness hole, 4 Lows.
- [x] All four Lows fixed (c314ca09, 94f504af), 163 probes kept (1877b9cb), pup gates green, equivalence 0 accepted->rejected.
- [x] PR #58 merged 2026-10-06 (9e8ac153). seam2/seam2b branches deleted (local, origin, pup) and worktrees removed.
- [ ] Nexus mirror re-sync of src/rig.zig (no Nexus session is running): diff 0cbf7e7a..9e8ac153 in nexus-sync-seam2b.diff. Supersedes the seam2 diffs above.

## Test-infra (2026-10-06)
- [x] Six commits on `test-infra` (48e8ab77): corpus cache fix, fast discovery, RIG_BUILD_STORE, equiv base cache + pkg section, AGENTS two-lane rule, --shard. Gates green on pup and Mac. Mac new-branch gates 33 min -> 4.5 min; pup 8.9 -> 3.3 min.
- [x] pup disk policy: pup-gates.sh removes the shared store when under 50 GB is free.
- [x] Independent review for false greens (review-test-infra.md): store key sound; High-1 corpus/matrix pass a program that never ran (pre-existing shape, reachable via the store); M2 prune leaves broken entries; M3 zig_cache.sh no longer tests the default path; Lows.
- [x] Review fixes on test-infra (3bd38b1c): runs need a started file (High-1, every runner checked), prune via trash (M2), zig_cache off/on (M3), Lows; pup gates green.
- [x] Started-file hook only in run/test packages (09595e0f); main merged (93411ac1); combined gates green on pup and Mac.
- [x] Targeted re-review (review-test-infra-fixes.md): shipped programs and CLI clean; M1 started-path can be fooled (dir collision), L2 shared path, L9 signal death passes (pre-existing), L8 known/pending never-ran, L4/L6 heal and nesting.
- [x] Round 2 fixes, main merged; PR #63 merged 2026-10-06 (e7b15af7); branch/worktree deleted everywhere.
- [x] pup disk: the store is a link to /zfs/rig/rig-build-store (ZFS pool on the internal NVMe, 560 GB free, lz4). pup-gates checks free space on the store's filesystem.
- [ ] Later: CI could cache the store between runs.

## Lane B: copies (2026-10-06)
- [x] Six commits on `copies` (bc176613): one `sema.copies` fact at every duplication site; §4/§5/§7 planned rules built; pup gates green; equivalence vs rig-v022: only the two hole probes go accepted->rejected.
- [ ] **Live hole in v0.2.2** (confirmed on main 0cbf7e7a): `r: ?W?` with W holding a write view; `x = r ?? W(...)` / `x = r?` copies the write view out of a read view and writes through it (test/corpus/copies-hole-*.rig on `copies`). Fixed by the copies fact. Ship as v0.2.3 once copies lands (review first), instead of a separate instance hotfix.
- [x] Independent review (review-copies.md): no hole introduced. High p51 (`??` view result not adapted, Zig error); M1 p47 (checkStepUses asks copies, not moves); M2 p52b (pre-existing Zig error); L1 cloneable says write-view holders clone; L2 p60; L3 p25 unclassified; boundary design note.
- [x] Copies fixes (7b84177d H1+M2, 99a3b8f4 M1, 0f4d23c0 L1), probes kept, main merged (4a59ae5b); pup gates + Mac green; equiv vs 9e8ac153: accepted->rejected only the two hole probes + p60.
- [x] Targeted re-review of the copies fixes (review-copies-2.md): no soundness hole; H2 `??`/`catch` copied out into `P?` fails Zig (q09*, main has it for (!Int)? too); L4 catch copy-out after handler (classify).
- [x] H2 fix (fallbackType), probes kept, main 0a10f99c merged; pup gates + Mac green; equiv vs 0a10f99c: 4 accepted->rejected (2 hole probes, p60, q09h which failed Zig on main). PR #61 merged (28f20fc4), on a base without #60; combined main re-gated on pup before release.
- [ ] Design note copies-boundary.md (incl. catch copy-out addendum) for the user.
- [ ] **Critical, live in v0.2.2 and main 9e8ac153 (confirmed):** `while c as h: step` with the step using `h`; h's loans not live through the body, step reads freed memory (p49 family). Hotfix branch `while-step-hotfix` (worktree ../rig-while-step), fix in ownership.zig (lane A). Then independent review, PR, release v0.2.3.
- [ ] After #58 merges: merge main into copies (expect conflicts near checkExpr copy-out mismatch, recordAdapted, fill/copy element checks), full gates on the combined tree on pup, then PR --auto.
- [ ] Decision for the user: the kept boundary (`x = r` with `r: ?Point` and no type stays a `?Point`).
- [ ] Then release v0.2.3 (seam 2 + copies + the hole fix).
- [x] Review of while-step-hotfix (review-while-step.md): p49 fix correct. **Critical, live in v0.2.2 and main (confirmed):** `continue :outer` from a nested `while` skips the outer step through emitWhileJoined (emitWhile nulls `redirect`), UAF (w14, w15). High: keptLabel misses nested `continue :label`, Zig errors (w05, w12, gen). Low w48: return path sent through step.
- [ ] Hotfix agent fixes the emit class (step runs on exactly the checker's paths) on the same branch; then re-review, PR, release v0.2.3.

## pup sharing (2026-10-06)
- [x] Em's timing runs hold the `pup-bench` lease on pup; Rig uses pup only while it is free. pup.sh waits for the lease (bench_held). cpuq will enforce this itself later.
- [ ] Note: `cpuq pause`/`stop` didn't stop pup jobs' children (CMD-PID 0); killed by process group. Asked cpuq what pup.sh should change (exec / setsid).

## Loop lowering (2026-10-06)
- [x] Second review of while-step-hotfix (review-while-step-2.md): redirect stack correct for its target. **Two more Criticals, live on main (confirmed):** s01/s02 (emitWhileJoined runs step before body defers/drops when no continue targets the loop), e01-e06 (unlabeled continue in a nested loop's else skips the outer step). High l01-l04 (reused labels, Zig errors).
- [x] Per "a second soundness round stops the feature": while-step-hotfix stops patching; it lands as verified (p49 class + labeled continue), with the rest listed as known remaining.
- [x] `loop-lowering` built (bd04787e): one desugaring, emitWhileJoined/jumpsToLoop/keptLabel/labelUsed/redirect stack removed; s/e/l holes fixed; condition `continue` with a binding-reading step rejected; loop. matrix 200/200; pup gates green; equiv vs 0a10f99c: 1 accepted->rejected (new reject test), 716 emit-only; release binaries identical size.
- [x] Independent review (review-loop-lowering.md): no soundness hole (4300 generated loops on pup, 0 failures; base fails 378). M1 closure-capture step read (pre-existing internal error), L1 labeled jump after ??/catch unparsable, L2 wording.
- [x] M1/L2 fixed (dddf6c55: `sema.findUse` sees captures, shared by stepReadsBinding and the step rules; tests for c01 and c02), review probes and a gen5 sample kept (cb42c6ec), main e7b15af7 (+#63) merged (04302a97; matrix watchdog adapted to its runner). pup gates green at 04302a97; gen5 grids 3500, 0 failed; equiv vs e7b15af7: 3 accepted->rejected (the rule), 2 wording, c02 emit-fails->emits, rest emit-only. Next: PR, v0.2.4.
- [ ] **L1 (grammar, pre-existing; review-loop-lowering.md):** a labeled jump after `??` / `catch` cannot be written in parentheses or in a `while` header (`while some(odd(i) ?? continue :outer) as h`, `(odd(i) ?? continue :outer) > 0`, `catch continue :outer`), only as a statement (`x = odd(i) ?? continue :outer`), though SPEC §12 says such a jump may name a label; the parser's message contradicts itself ("unexpected keyword `continue`; expected `return`, `break` or `continue`"). Not changed on loop-lowering. **When the grammar allows it:** typecheck's `checkStepBindings` counts every `continue` in a `while` condition (`hasContinue`); narrow it to a `continue` that targets this loop, since a `continue :outer` leaves the loop and never reads the binding. Probe: probes/review-loop-lowering/a01.
- [x] Released v0.2.3 (tag on 9fe7858a, https://github.com/shreeve/rig/releases/tag/v0.2.3). Next: v0.2.4 = loop-lowering (+ test-infra #63).
- [x] while-step-hotfix verified at 4ff42874: pup gates green (one cli timeout under load, passed on rerun); equivalence vs 9e8ac153: 20 accepted->rejected, all holes except w48 (prod-strict) and the SPEC example. PR #59 merged 2026-10-06 (0a10f99c); branch, worktree, origin and pup copies deleted.
- [ ] Filed by the hotfix agent: `while (f() catch continue) as h: step(h)` skips the step after that continue (not memory; contradicts SPEC). Fold into loop-lowering.
- [x] pup.sh quoting bug (apostrophe in a comment inside the remote script, 16:24) fixed and verified.

## Remainder trap (2026-10-06)
- [x] Found by test-infra's stricter corpus runner on pup: `Int.min % -1` traps on x86_64 (`@rem`), a false green before. Confirmed on main (rc 134 on pup). Fix on `rem-min` (fa171af7): `%` lowers to `rig.rem`, which gives 0 for a signed divisor of -1 (sema's constant fold already did). Test test/behavior/types/remainder_by_minus_one.rig.
- [x] Rebased (e447452c); Mac targeted 792/0; pup gates green. PR #60 merged (4058dda0).
- [x] Release v0.2.3 = #58 + #59 + #60 + #61, released.
- [x] Combined main 28f20fc4 on pup: suite 2737/1 (cli/test_out_dir timed out under load; passes alone, 145 s run), corpus 6731/0, matrix 4899/0, unit ok, odv 329/0.
- [ ] Flaky: cli/test_out_dir runs near its 120 s timeout on pup under load (seen twice). Speed it up or give it a longer budget (test-infra).

## `<` always leaves its source done (2026-10-07, user approved option A)
- [x] Round `move-done` built (a82ee668): `MoveSource` fact in walkMove; 11 programs accepted->rejected (survey-move-done.md); pup gates green; equiv explained. **Also fixes a live UAF in v0.2.4 (confirmed on main):** `w = <(a if c else b).v` moved a Vec out of `a` while `a` still dropped it.
- [x] Independent review (review-move-done.md): if-branch fix holds; **Critical C1 (`for x in <mk().v` etc.) and C2 (`<(mk().v if c else …)`, `catch`, `<mk().o?`) UAF, also live on main**; H1 branching copy parts escape the rule; M1 `<self` on copy part has no form; M2 typecheck tempBase split; M3 kept cases inconsistent.
- [x] Class fixed in one fact `sema.moveSource` (+ `moveLeaves`) at c1a7d3f4; tempBase/movedTail removed; Mac checks + pup suite green; equiv vs c169ec89: 12 accepted->rejected (survey), 1 rejected->accepted (consuming receiver copies).
- [x] pup gates green (c1a7d3f4). Second review (review-move-done-2.md): **no soundness hole** (28,815 generated programs). Hard-gate items: H1 oracle treats a branch of write views as read (model fix); H2 `<` on a `|+n|` copy capture leaves it unchanged (reject). M1 `<(!mks(1)).o` exception. Lows.
- [x] Fixed H1/H2/M1/Lows (19bec64d); grid 0 oracle diffs, 3685 accepted run clean; gates green. PR #67 merged (81c75010); branch deleted. Released v0.2.5 (tag on 5e551bc5).

## Polish round (after move-done)
- [x] polish merged as #69 (0cd9f3e3); branch deleted. Nexus sync diff: nexus-sync-polish.diff.
- [ ] Ask user: `@name(T)` returns Zig names (`i64`) today; recommend Rig names (`Int`).
- [ ] (running on `polish`, worktree ../rig-polish; part A tooling now, part B script rewrite re-run after cell-temp merges) Parentheses required on every function definition (user decided 2026-10-07): grammar + fix-it diagnostic, mechanical rewrite, SYNTAX rule, lint incl. blank lines between top-level declarations, Nexus sync, breaking-change note.
- [ ] Rig builtins (user decided 2026-10-07): `@size`, `@align`, `@type`, `@name` replace `@sizeOf`, `@alignOf`, `@TypeOf`, `@typeName` outside `raw` (fix-it for the old names); Zig builtins only in `raw`; SPEC placeholder becomes `@builtin(args)`. Check SPEC's other `@` uses (`@intCast` at SPEC ~5631) are inside `raw`.
- [x] Docs round `docs-rules` merged as #66 (cdc17232), incl. the `-x` look-alike clause; branch deleted: prefix = how you hold it / postfix = control flow (WELCOME first screen, `not` for negation); closure bars rule in SYNTAX; "no implicit shadowing" stated once in WELCOME.
- [ ] Fold into B4b: binding enum payload fields by name ("not supported yet").

## Order (2026-10-07)
move-done (running) || docs-rules (running) -> polish round (parens on definitions, @size family, style lint; mechanical rewrite done while no other branch is open) -> B4b (+ payload fields by name, bare `break x`) -> seam 3 -> Static -> fold -> ^T + List + text rename -> final review -> v0.3.0.

## Read-lent Cell temporaries (user decided 2026-10-07)
- [ ] Round `cell-temp` (running, worktree ../rig-cell-temp, from move-done e53ad87d; merges main after #67): delete typecheck's whole-temporary Cell rejection (~3778) and the receiver sibling (~7028); extend the namedLeaf rejection to holdsCellByValue; tests (whole, holder, branching guard, drop-observed change, kept view rejected); SPEC ~4049; review; PR.
- [x] cell-temp built (09cc3e04): ?mkc(), mkc().hit(), made().hits.set/replace/push/pop/clear accepted; namedLeaf extended; emit reaches branching slot temporaries in place. **Pre-existing accept-means-correct bug fixed:** `(mkh(1) if c else mkh(2)).d.hit()` changed a Zig copy (drop saw the old value). pup gates green; equiv vs 81c75010: 0 accepted->rejected.
- [x] My call per the decision: push/pop/clear on a temporary's Cell[Vec] accepted (same check as set/replace); `c[i] = e` into a temporary's part stays rejected (like any assignment into a temporary's part).
- [x] Review (review-cell-temp.md): **Critical: branching receiver with a taken made leaf writes a Cell change through @constCast of a const Zig temporary (read-only memory; bus error / wrong values in release). Partly live on main (k11).** Medium: c[i]=e boundary; oracle ?? false positive (main). Lows.
- [x] Class fix at 1fb2acba (`keepsCellChange`, keepMadeLeaves, readLeaf; emit backstop; all @constCast via emitCellAddress); grid in matrix (`cellleaf.`); k11 + copy bug on main fixed; oracle ?? fixed; c[i]=e accepted; pup gates green; equiv: 1 accepted->rejected (z5, intended).
- [x] Second review (review-cell-temp-2.md): **soundness hole -> feature STOPPED per AGENTS.** C1 (live on main, all releases): Cell changes through `?self`/`?T` are emitted as `@constCast` writes through `*const` pointers = UB in --release (z07 plain ?self counter: bus error on Mac, segfault on pup; z04 double free). H1 backstop reached by 1164 accepted grid programs. Branch kept unmerged for reference.
- [x] Hotfix `cell-mut` built (4c521b6a): `sema.interiorMutable` fact; views of interior-mutable types emit as *T/[]T (ReadPtr/ReadSlice for generics); var storage; no @constCast in emit; `# release` test marker; `cellmut.` matrix (debug+release); pup gates green; equiv: 1 accepted->rejected (constLeaf, was UB). Main fails 64/509 release grid cases.
- [x] Review (review-cell-mut.md): **no const write remains, no wrong output** (debug+release, Mac+pup). H1 regression: sema and runtime decide interior mutability differently for generics holding T behind a pointer/Vec -> Zig compile errors on programs main runs (x01-x06). M1 generic `.depends` forms; L1 constLeaf rejects read-only methods; L2 matrix ignores rejections.
- [x] Fixes at fbae7c5c: sema writes `__rig_interior_mutable` into each type; runtime only reads it; `.cell_place` generic requirement; matrix fails on rejection. cellmut grid 131/131 debug+release on Mac and pup (main fails 47). pup gates green. PR #70 (auto-merge on CI).
- [x] #70 merged (f1290ba4); branch deleted. Release PR #71 in CI; notes in notes-0.2.6.md.
- [x] Released v0.2.6 (tag on 5db36f06).
- [ ] `cell-temp2` (worktree ../rig-cell-temp2, from 5db36f06): redo the read-lent Cell temporary decision on top of cell-mut; L1 (read-only ?self on unslotted made leaf rejected) lifted by the cell-temp redo. Then redo cell-temp on top. Open (pre-existing): b04 internal error, l01 `mk(5).get(0)` leak.
- [x] CI sharded: #72 merged (c1ed3fd9); CI ~10 min instead of ~25. Branch deleted.
- [ ] Roadmap kernel track: #73 (auto-merge).
- [ ] Mac build store is 189 GB (disk 87% used): ask user before trimming to 1-2 days.
- [x] cell-temp2 built (ee45a847 incl. main merge): storage.leafStep single classifier; constLeaf removed; b04 and l01 fixed; 22,890-program grid: 0 new rejections vs main, 0 oracle diffs, 3,092 combined pass debug+release on Mac and pup; backstop unreachable; Mac gates green; equiv explained (1 accepted->rejected: review-place-b11-z5, intended).
- [ ] Known over-rejection (pre-existing class, ownership.zig walkCatch scopes handler temporaries to the handler while emit slots them for the statement): `print((n if k else (mknf(-1) catch mkn(7))).c.get())` now rejected for no-drop types (main rejected it for drop types). Future ownership fix.
- [x] Review (review-cell-temp2.md): no soundness hole, no wrong output (9,781 accepted grid programs exact in debug+release). H1 `none` leaf reaches backstop (madeLeaves vs keepReached vs refuseHeldCell: a second classifier). H2 checker panic (index OOB in mayOwnView; walkCatch scopes handler temps to the handler while emit slots them for the statement; main has 3 rarer). M1 = H2 as over-rejection.
- [x] Fixes e5111234 + 7fb643b4; second review clean (no soundness hole); pup gates green at a1742b34; equiv classified. PR #76 (auto-merge). Then v0.2.7.
- [x] rig-names built (234034bc): @name returns Rig names; all names from the printer; pup gates green; equiv explained. PR #74 (auto-merge).
- [x] Flaky CI false failure: test/run's `diff <(...)` hit `/dev/fd/63: Bad file descriptor` on macOS (#73's doc/SPEC/L1857 had correct output). Fixed by piping into `diff -`: PR #75 (auto-merge). #73's failed job rerun.
- [x] Second review of cell-temp2 (review-cell-temp2-2.md): **no soundness hole** at e5111234 and 7fb643b4; 10,160 accepted grid programs exact in debug+release; 0 checker panics (Debug and ReleaseSafe); 0 backstop hits; 0 oracle diffs. H1 (11 Zig compile errors) fixed at 7fb643b4 and verified.
- [ ] Follow-up M1 (cell-temp2 review 2): a temporary made in a `match` arm that views the arm's binding is now rejected (q07, plain types; main accepts). Cause: holdPartTemps holds arm temporaries for the statement (emit does too, on main as well). **Main has UB here (q12: reads a prong-local copy after its scope).** Design: keep an arm's temporaries in the arm, in emit and checker. Own round after cell-temp2.
- [ ] Follow-up L1/L2 (pre-existing): defer reading a write-lent name with `continue` over-rejected (q14); `?? continue` drop order 7,5,6 vs SPEC's last-made-first (q15).

## Faster process (user decided 2026-10-08)
- [x] AGENTS.md: "Land fast, release deep" + "Rerun only what changed" (in release PR #77).
- [x] cell-temp2 merged as #76 (b0f156c9); branch deleted everywhere. Release PR #77 (v0.2.7) in CI; notes in notes-0.2.7.md.
- [x] `arm-temps` 45fa39d4: arm temporaries in the arm (works). Fast review (review-arm-temps.md) found **Critical: assignment-target liveness**: `place = <value with nested statements>` treats the target's views as dead inside the value; new via `pat => s` arms (l09-l12, l17, l18, l21) and **LIVE ON MAIN** via block arms, `if` blocks, `catch` blocks (l13, l14, l16; l14 confirmed UAF on main).
- [ ] Class fix in liveness (target views held live through the value), tests + matrix axis, gates, quick re-review; then patch release.
- [x] `grid-delta` dc422902: results cache + --delta (no change 3.2 min, diag-only 4.0 min); safety test results_cache.sh; where.sh.
- [x] grid-delta review (no Critical/High), both Mediums + Lows fixed (debd2458), gates green. PR #80 (auto-merge). Known limit: a file changed and restored during a single program's run.
- [ ] Asked cpuq for a standing Rig slice/window on pup.
- [x] arm-temps e65b2bff: assignment-target liveness fix (Checker.indexUses: a target's uses count at the end of the assignment); gates green (Mac); new matrix axis target.* (main fails 18, all UAF); equiv: only l13/l14/l16 accepted->rejected. Re-review running (review-arm-temps-2.md).
- [ ] Follow-up (High, on main): guard on a consuming `match` that changes a Cell through a view of the binding: Zig compile error (`expected '*D', found '*const D'`); repro scratchpad/arm/guardcell.rig.
- [ ] Follow-up (Low): l07 over-rejection (later arm guard); read-view reassignment over-rejection.
- [x] Re-review of arm-temps (review-arm-temps-2.md): branch makes nothing worse and closes l13/l14/l16, m11/m12/m32, m39-m41 (live on main). Second soundness round -> stop patching. Remaining, also on main: **Critical m42-m46** (last nested scope re-points target view; indexUses at hi == popScope check) and **High m47/m48** (write-view name target emitted `w.* = switch`, pointer before value).
- [x] arm-temps merged as #78 (1080547c); branch deleted. Released v0.2.8 (#79 merged, tag on c0b21e50; includes the DESIGN.md Zag edit that another session committed on local main; local main reset to origin).
- [ ] Redesign `assign-desugar` (worktree ../rig-assign-desugar from e65b2bff): `place op= value ==> { __v = value; place op= __v }` in checker and emit; then v0.2.9.
- [x] DESIGN.md Zag edit carried in release PR #79.
- [ ] AGENTS: clarify that a patch release closing live holes ships after its fast gate; the deep gate runs before feature releases (v0.3.0).
- [x] assign-desugar 202b13fd fast-gate review clean (review-assign-desugar.md): closes m42-m48 and n04/n22/n34/n39/n40/n43 (live on main); 0 new over-rejection; 0 oracle diffs.
- [x] assign-desugar 9fc5359f: review items done, gates green, grid 783/0, equiv explained. PR #81 (auto-merge). v0.2.9 notes drafted (notes-0.2.9.md).
- [x] assign-desugar merged as #81 (eb238dd3). grid-delta #80 CI fix (bash `$D—` under C locale -> `${D}—`, 9abdb028). Release PR #82 built on grid-delta (lands #80 too).
- [ ] B4b started (worktree ../rig-b4b): header temporaries accepted where emit points; arm-local payload views lifted where emit matches in place; bare `break x` (E1); optional payload fields by name. CORE status word in its own droppable commit.
- [x] Released v0.2.9 (tag on 62d0e0b5): #80 grid-delta + #81 assign-desugar. Branches deleted; only main + b4b.
- [x] B4b part 1 (2d47a2db Vec-element write match fix, pre-existing since v0.2.0; d9225c3c header temporaries accepted where emit points) fast review clean (review-b4b-1.md). Lows L1 stale probe comments, L2 oracle C2 false positive (pre-existing).
- [x] #83 HANDOFF: every change ships in v0.3.x (timeless wording).
- [x] B4b part 2 ddefa968: arm-local payload views lifted except where emit matches a copy; new fact storage.catchAllByAddress; generic catch-all captured by pointer (fixed a wrong-output case the old rule hid); 102 rejected->accepted, 0 accepted->rejected. Fast review (review-b4b-2.md): **Critical regression in generic bodies** (`match o1 if c else o2`: reachesPlace says in place, emit copies when guarded, checker records no loan; `.depends` slips past `moves == .yes`) and **High** (guarded generic catch-all: wholeExpr re-derives by-address instead of catchAllByAddress). Fixes requested as classes; a second soundness round would stop part 2.
- [ ] Follow-up (pre-existing on main): `fun first[T](x: ?T, d: ?T) -> ?T  match wrap(x) .some(v) => v` with `wrap[T](x: ?T) -> Opt[?T]` passes check, fails in Zig ("expected type 'T', found '*const T'").
- [x] B4b part 2 fixes 6b00e981 (matchesInPlace for branches only via pointer views or header points; `moves != .no`; wholeBinding reads catchAllByAddress). Part 3: 61b7cf53 (consumed fact shared by emit and checker; moveVar internal error on unrecorded moves) + 800bd825 (bare `break x`). Gates green; equiv: 130 rejected->accepted, 0 accepted->rejected. Combined review clean (review-b4b-3.md): no soundness hole in A or B; 207 newly accepted, 0 newly rejected; 0 oracle diffs. PR #84 opened WITHOUT auto-merge pending owner approval of CORE commit 7366148a.
- [x] one-decider stage 1 (e9b1eca6): emit can't import sema/storage/resolve (Facts view, tokenizer test); recorded answers + drift check sealed after plan; leaf walk recorded once; zig_temp fact; Pending allowlist 25 (budget test); bug fix `if h.o as t` (on main). Equiv byte-identical except the bug test. PR #87 auto-merge.
- [x] one-decider stage 2 (173b6a6e): Pending 25 -> 7, byte-identical; review clean (review-one-decider-2.md). PR #88 auto-merge.
- [ ] Stage 3 notes: guard Facts passthroughs in the budget; emit.zig:2522 own holds_view; ~30% slower check (record + reverify every answer) -> consider verifying only in debug/test builds.
- [ ] one-decider stage 3: Pending 7 -> 0 (actsBeforeStore, stepReadsBinding, assignWritesThrough, moves, copies, holdsCellByValue, madeLeaves) + place-holding-view reads + ?self/block-yield rvalue addresses + ownership side of drop-when-tested. (was: shrink Pending 25 -> 0 per inventory section 10 (place-holding-view reads first). Two-classifier items: for-consumes-source, print-by-address, catch-all by address, held_view x3, rig.isNone drop.
- [x] (original) "one decider, enforced" round (lint/interface so emit only reads recorded facts; allowlist shrinking to zero).
- [x] B4b merged as #84 (bfae9569); branch deleted. #83 merged; branch deleted.
- [x] Opt[?T] payload fix (from the user's spawned session, f5b0d00d): review clean (review-view-payload.md). PR #85 auto-merge.
- [ ] Follow-ups: oracle payloadOf reads declared field type (stricter only); ownership treats view-typed payload as view of subject (over-rejections p10/p12/p13).
- [ ] **DECIDED, round `ignored-bang` running (worktree ../rig-ignored-bang):** a `!` in a value slot does nothing. `o = Opt.some(v: !n)` builds `Opt[Int]` (not `Opt[!Int]`), and generic `get(!n)` infers `T = Int`, so the write lend is silently read (repro: match !o / .some(v) => v += 1; print(n) prints 1). With an expected type (`.a(r: !x)` returning `G[!Int]`, or explicit `G[!Int].a(r: !x)`) it does build the view; `G.a(r: !x)` there is rejected ("expected G[!Int], got G[Int]"). A `!` with no effect sits badly with AGENTS rule 4 (effects stay visible): reject it, or infer the view type?
- [ ] **Ownership precision follow-up (from the view-payload session):** viewpay cells `viewpay.*.*.whole` ("`w` does not live long enough") and `viewpay.*.local.{ret,guard}` ("cannot return a view of `o`") are correct programs rejected. Fix: in ownership bindPayload, when payloadFieldOf(b) is itself a view, treat the binding as a copy of that view carrying the matched value's loans, with no alias_of the subject. The viewpay grid shows when those cells start running.
- [ ] HANDOFF health numbers: count the new suite tests and the viewpay matrix family at the next HANDOFF update.
- [ ] RESUMED: payload-names at bf652b0e (review commit 4dbc9cab), main merged; also fixes a main crash (wrong-arity positional pattern panics the storage planner). To resume: rerun grid on head (remaining ~160 cells), gates GATES_DELTA=1, equiv vs 8f7cf2c6 (base built at scratchpad/pn-base), fill PR placeholders; start fast-gate review of 4dbc9cab in parallel; then PR. Nexus mirror sync for a rig.grammar comment.
- [x] payload-names review clean (review-payload-names.md): no soundness hole; identity with positional `_` form on 821 widened cells; arity crash fix confirmed. PR #86 auto-merge.
- [ ] Follow-ups (Low): duplicate-field note points at the value not `h` (L1); `.two(a: x, b: x)` wording (L2, also main); oracle reads declared field type for generic view fields beside an owning field (L3, from #85; grid with owning `z: Text` field would trip the gate); oracle accepts move out of a write-match binding (L4, oracle gap).
- [x] #86 payload-names merged; branch deleted everywhere.
- [x] ignored-bang built (da4cf0b3, head 596161e4): recordAdapted rejects `!x` read in a value slot; 150-cell grid clean; equiv: 9 differ (all intended). Review running (review-ignored-bang.md). **Holds for the owner:** 596161e4 adds one CORE §4 sentence (needs approval); open design: `!` still ignored in operator operands, `print(!n)`, `rd(!n)` with `rd(?Int)`.
- [x] ignored-bang review (review-ignored-bang.md): no memory hole; NOT one decider: untyped loop `break !n` still read (High 1); `f(?!n)` compiles to bad Zig (High 2, on main); docs overclaim (operators, print, index, range, +!n, <!n). Sent back: generalize to "a written `!x` is accepted only where its slot holds a write view", one named decider incl. bindArg; Lows (hints). 
- [x] DECIDED: `rd(!n)` where a read view goes is rejected ("write `?n`"); CORE §4 sentence approved with that ending.
- [ ] Oracle follow-up (Low 2, on main): a loan carried out of a loop by a break value isn't tracked.
- [x] ignored-bang generalized (a4325ccb): decider Checker.writeLendRead; readOf the only read recorder (unit test); loops keep a write view like `if`; inference consistent; rd(!n) with ?Int kept (owner question); CORE sentence alone in a509c939. Gates green; grid 235/0; equiv 16 intended. Re-review running (review-ignored-bang-2.md). PR waits for the owner's CORE approval.
- [x] ignored-bang re-review (review-ignored-bang-2.md): no memory hole; loop-keeps-view sound. High 1: `!x` leaves in if/match/loop values read as a value still accepted (main too); Medium 2: handsOver vs view_loops (two classifiers); Low: reachThrough `(!p).x`. Sent back; then merge 53cbff4f and gates.
- [x] ignored-bang d4cd3085: read-view `!x` rejected; leaves via sema.yieldedLeaves (view_loops deleted); paths; CORE sentence 4 (approved, "copy it") in its own commit; SPEC table; gates green; grid 300/0; equiv 27 check-only. Final review running (review-ignored-bang-3.md).
- [ ] Follow-ups from ignored-bang: `(!arr)[0] = 7` emits `&arr[0] = 7` (pre-existing miscompile, main too); oracle break-value loans; hint for `x catch !d` read by `+`; optional: handsOver `.made` vs `.branches` for match/block/loop (unify, separate change).

## Blind review takeaways (2026-10-08, two agents with no Rig knowledge, 40 programs)
Both: real merit; agentic fit is review-visibility + strict compiler. Proposed (awaiting user):
- statement `-x` -> `drop x` (drop vs negate ambiguity; both called it the worst footgun)
- formatter + stricter whitespace (`w . get()`, `a <b`)
- agent tooling: `rig check --json` with fix-its, `rig explain`, one-page sigil spec
- idiomatic example corpus (not regression tests)
- `!` reads as "not": keep, lint `!x != ...`, teach early
- later: trait bounds, error payloads, concurrency / atomic `*T`

## `(!arr)[i]` miscompile family (pre-existing; needs design call)
Accepted, then the Zig fails: `(!arr)[0] = 7`, `(!arr)[i] += 7`, `(!v)[0] = 9` (Vec), `if !(!arr)[0] as v`.
`(!p).x = 5` works. Decide: should they run (fix emit) or be rejected? The suite cannot hold a known miscompile.

## From review-ignored-bang-4 (Low, after #89)
- hint for `(!(!p).q).o` suggests `(!p).q.o` (itself rejected); should suggest `p.q.o`
- value loop whose only `break :a` belongs to an inner same-label loop: now rejected (correct), but the message should say the break targets the inner loop
- the comment on path-error suppression overstates (an unrelated error in the statement hides it until fixed)

## Next syntax round (after lend-base): write-call-as-value rule
Approved by owner 2026-10-08: see rig-questions.md "A write call used as a value puts the `!` in parentheses".

## From review-syntax-a-2 (Low, after #92)
- spacing hint after a line ending in a comment quotes a word from the comment
- `-x` hint on a captured view / loop view says `<v` (rejected); derive from the check that rejects `<x`
- SPEC: say a statement `<?x` / `<!x` is rejected, not just "does nothing"

## CRITICAL (pre-existing on main, found by review-syntax-b-1): slice of a write view of a Text lends nothing
`t: !Text; s = t[1..]; !t.add(...)` -> use-after-free. Fixing in syntax-b (#93) as a class (sliceLendsObject over every object/view kind) + matrix family. Oracle also accepted it. Must be fixed before v0.3.0 tag regardless.

## CRITICAL (pre-existing on main, review-syntax-b-2 C2): a lend of a `match !x` payload binding puts no loan on it
`s = ?t[1..]; !t.add(...)` in a `match !e` arm -> use-after-free. Own round `payload-loan` (ownership.zig lendOn), class over every view-binding kind + matrix family. Must land before v0.3.0.

## Tooling: rig trims its own package cache (from Emdb, 2026-10-09)
pup's ~/.cache/rig reached 48 GB (5,929 per-program package dirs from grids/probes run with bare `bin/rig run`). Done now: pup jobs set XDG_CACHE_HOME=/zfs/rig/xdg-cache and prune entries unused >2 days (pup-lib.sh prelude). To do: `rig` itself trims the cache base by age/size (Go-style: touch on use, trim at most once a day, entries unused N days), plus `rig clean`.

## Accept-means-correct on main (review-payload-loan-4 M1/M2), follow-ups
- `for x in v` over `Vec[?P]`, then `x.n`: Zig fails (probes i04, i05) — emit binding wrong while type/access agree
- generic `match !g` with T = Int, a `|?x|` capture: Zig fails (i07)

## Retire heavy.sh (owner, 2026-10-09)
Agents call cpuq directly: `cpuq run --cores 2-6 --label "rig:$(basename "$PWD")" -- <cmd>` with `-j "$CPUQ_CORES"`. test/run's RIG_BUILD_STORE_DAYS default -> 2 (in #95). Delete .git/revamp/r3/heavy.sh once no running agent uses it.

## cpuq 0.9.0 on pup (2026-10-09): window_lend = 180
Waiting cpuq jobs (rig-pup:*) may start beside an idle pup-bench hold and get SIGSTOPped when the owner works again. A test under `timeout` can then report a spurious timeout: rerun any timeout from a pup run alone before trusting it.

## Where heavy work runs (owner via cpuq, 2026-10-09)
When the Mac shows ~5+ waiting in `cpuq status` and `cpuq status --host pup` has room, send Linux-compatible heavy work to pup through pup's cpuq: `pup-gates.sh <branch> <log-prefix>` (GATES_DELTA=1) or `pup.sh <branch> '<cmd "$CPUQ_CORES">'`. Never run on pup outside cpuq.

## header-paths (#96) review 2 (2026-10-09): third soundness round in this class -> redesign
Oracle NOT weakened (verified); #96 adds no unsafe acceptance. Open Criticals (on main too):
- C1: `for x in ?(a if c else b).v` over owned/element leaves: for's `?` mode skips lendsBranch
- C2: branch of write-view places passed bare where `?T` expected (implicit read view): `sl(a if c else b)`, `sw(o?)`, `RV(r: a if c else b)`; 36/120 grid UAF
Medium: oracle rejections gate skips modules with sema errors; no stale-entry check.
Redesign: every in-place read of a branching value (sigil, for mode, implicit read-view conversion) is a lend that asks lendsBranch — fold into the "never data" + 3p round.

## Bugs found by never-data helper (2026-10-09), repros in scratchpad/A1/
1. `qs[g(0)].get(k: g(1), j: g(2))` on `[2]*Q` element with reordered named args: Zig fails (`**RcBox(Q)` field access).
2. `(?h1 if c else ?h2).n` with `*H` handles: Zig fails (`*const *RcBox(H)` field access).
3. `look([Text("abc")])` with `look(xs: []Text)` (implicit slice lend of an array literal holding resources) LEAKS; `?[...]` does not. Likely from syntax-b's implicit slice lend (#93).

## Nexus generator speedup (nexus#13, efcaf5b; announced 2026-10-10)
Parsers +65% faster for Rig, identical trees/API, different generated code; @infix folds into parse table so in-expression "expected …" lists may differ. CI pins v2.0.0. Asked Nexus to hold the LOCAL ../nexus/bin/nexus rebuild until Rig is clear (test/run's parser check compares regenerated parser.zig byte-for-byte). Then: small Rig PR = regenerate src/parser.zig + fix syntax-error expectations + bump CI's Nexus pin when tagged.

## Nexus v2.1.0 tagged (f2e267a): after #97 lands, tell Nexus "now" (local rebuild), then one PR: regenerate src/parser.zig (header stamp only) + CI pin ref v2.1.0, cache key nexus-v2.1.0-...

## Follow-up (review-rules-1, Minor): lasting lend through `??`/`catch` into a constructor field or array element stays implicit (`Holder(seen: headm(v) ?? ?v[..])`); safe, visibility only.

## Follow-ups (review-for-iter-2, cosmetic/limitation): caret mid-`for` and note column off by one on generated-loop errors; a generic `g: !T` is rejected as a `for` source. Owner decision pending: require `for x in !it` for an existing iterator (switch `bare_place_advances` in typecheck.zig).

## Agent rule: never `pkill -f test/run` (killed another project's run, 2026-10-10). Stop only your own PIDs.

## Trig's needs (post-v0.3.0 roadmap input, from Trig session 2026-10-10; full: ~/Data/Code/trig NEEDS.md f7687cd, docs/analysis 01-05)
Trig = TypeScript checker in pure Rig (port of ts-rust), WASM-first pure core. Prototype: 3 slices ran sanitizer-clean in ~half the Rust lines.
Blocking, in order: 1 modules at scale (subdirs, cyclic imports, methods outside struct body); 2 traits then generic Map/Set; 3 constant tables (module const array of structs); 4 match conveniences (char literals, named constants as patterns, match on strings); 5 closures as values (stored, writing callbacks); 6 ambient checker context (implicit context; no mutable globals); 7 errors carrying data + a design for recover-like catch; 8 program-lifetime arenas; 9 WASM target (no-OS runtime/std, exported text functions). Later: file/console I/O, JSON/stdin, threads. Scale: rig check ~48 µs/line (~30 s / 600K lines), emits ~1.9x Zig.
Doc/compiler mismatches to check in the v0.3.0 docs pass: SPEC `+s` of a String gives Text (recheck after fold); FAQ overstates generic bodies; ROADMAP lists arrays of owning values as future but they work. Over-lend: one String field makes a whole struct "holds a view", so a method that only clones its String arg keeps the caller's text lent.

## Nexus keyword proposal (2026-10-10): move Rig keyword handling into the grammar
Step 1 reserved words as lexer rules (drop rig.zig keywords StaticStringMap); step 2 contextual words (new, of, unique, from, static) via @keywords/@as (Nexus 2.3.0); step 3 previous-token classification (Rig = design partner, after v0.3.0). Agreed: Nexus prototypes steps 1-2 on scratch AFTER the rename lands; Rig lands it via its own PR (identical trees on Nexus's 138 + Rig suite/equiv, conflicts justified in INTERNALS, diagnostics unchanged). Tell Nexus "clear" for bin/nexus rebuild after the rename.

## Trig milestone + needs 10-15 (2026-10-10)
Full TS scanner ported (trig src/scanner.rig 188173d): 131/131 oracle cases under RIG_SANITIZE; ~2,290 Rig lines vs ~3,900 Rust (+~2,100 generated tables).
10 integer constants adapt to U8 like literals (or char literals); ~56 `Int(…)` wraps.
11 BIGGEST: a signature that reads an argument without keeping it — struct holding a String makes every String/!Text arg of its !self methods count as stored (same as the prototype's over-lend). Candidate: v0.3.0-adjacent fix to the "may store" inference (a param the body never stores carries no kept loan).
12 a field and a method with the same name.
13 `Text()` as a field default.
14 an enum variant's name as a Static (`@name`-like on values) — replaces a 351-arm match.
15 a `panic`.

## [SUPERSEDED by unpinned co-dev] Nexus pin via zig package manager (proposed by Nexus 2026-10-10): `zig fetch --save=nexus git+https://github.com/shreeve/nexus#v2.2.0`; build.zig uses b.dependency("nexus").artifact("nexus") for `zig build parser`; point test/run parser check + AGENTS.md at the pinned binary. Small PR after the rename. Ends local rebuild coordination.

## Follow-ups (review-rename-1, minor): `~^T`, `~~T`, `*~T` accepted as written types (unproducible); rig.grammar:880 comment still says `Vec[Int]`.

## Performance needs from Trig's JSON effort (2026-10-10), target simdjson/sonic-rs class (2-4 GB/s); build each as a general feature
Order by unlocked speed: 3 bounds-check control (unchecked index/slice inside `raw` -> scoped @setRuntimeSafety(false); and/or proven-safe check elimination; NOTE a global `--release=fast` conflicts with "safe code cannot corrupt memory" — prefer scoped raw); 1 SIMD vector types (plain data, lane ops, @select/@shuffle/@reduce); 2 bit intrinsics (popcount/ctz/clz/byteswap/rotate, wrapping/overflow arith); 6 `@embed("file")` -> Static; 7 monotonic clock in std; 4 I128/U128; 5 chosen allocators/arenas (real design; overlaps Trig #8). JSON agent will report gains vs Zig std.json, sonic-rs, simd-json on twitter/canada/citm_catalog.
  UPDATE (owner via Trig): "We really want to be able to ensure safety." Bounds-check work is SAFE-ONLY, prioritized: (1) checker-proved bound elimination (loop index < len, range checked by an earlier if); (2) safe block/vector iteration `for chunk in bytes.blocks(64)` (one check per block + remainder); (3) a padded-buffer type guaranteeing N readable bytes past the end. Unchecked raw indexing last resort; Trig won't use it. JSON agent will measure safe --release vs ReleaseFast of the same Zig.
  UPDATE (owner via Trig): SWAR first (128-bit compares beat SIMD in other code; portable incl. WASM without SIMD128). New priority for perf: (a) checker-proved bound elimination + safe `bytes.blocks(N)`; (b) U128/I128; (c) bit intrinsics (ctz first: first matching byte = ctz(mask)/8); (d) safe block-to-integer reads `U64.from_le(block8)` / `U128.from_le(block16)`. Then SIMD vectors, padded buffers, @embed, clock, arenas.
  CORRECTION (Trig): I128/U128 already exist (SPEC.md:106-107); dropped from the perf list. Remaining SWAR gaps: bit intrinsics (ctz/clz/popcount) + safe block-to-integer read. NEW small need: bitwise complement (`~` is the weak sigil; today `x ^ U128.max`). Spelling to decide (e.g. a method like `x.flip()`, or a builtin) — owner call.

## Trig JSON results (2026-10-11): safe Rig (no raw), 1702/1702 sanitizer-clean, 1.5-7x faster than Zig std.json (ReleaseFast) on the same tape work
MB/s Rig vs zig-tape: twitter 1824/782, canada 879/564, citm 2393/1250, gsoc 3687/541, github_events 2411/900. Safety cost measured: overflow checks 1-18%, bounds 1-11%.
Revised perf order (trig docs/json/RIG-NEEDS.md): 1 SIMD vectors + byte mask (est 2-4x); 2 checker-proved check elimination (overflow on i+8 after `while i+8 <= len`, the >=0/<len pair) + padded buffer (up to 18%); 3 bytes.blocks(N) (1-11%); 4 bit intrinsics ctz/clz/popcount (3-8%); 5 wide reads -> wide loads (`s.read[U128,.little]` loads upper 8 bytes bytewise on aarch64; 0-17%); 6-10 clarity: Float.from_bits/bits, bitwise complement, @embed or >64KB literals, char literals, errors with data. `bytes.read[T,e](at)` already exists (SPEC:773).

## Nexus keyword prototype ACCEPTED (2026-10-11): steps 1+2 (patches in ~/Data/Code/nexus/.git/unify/rig-keywords/: REPORT.md, step1.patch, step2.patch). Bar met: 138/138 trees, suite+equiv 0 diff, 0 conflicts, pinned diagnostics unchanged (step 2 rewords 3 invalid-program messages: accepted), speed neutral, -67 lines in rig.zig. Apply as one Rig PR AFTER barefor lands (rebase grammar onto the bare-for alternative), add INTERNALS note (`rig tokens` prints ident for promoted unique/from/static). `new`/`of` -> step 3.
  Nexus rebase notes: (1) `for` is a reserved-word lexer rule in step 1, bare-for alternative uses the same token; (2) step 2 `@as IDENT = [ctx!]` is permissive promotion: if bare-for leaves a name next to from/unique/static in some state, re-run the conflict check + 138 trees. Ask Nexus to regenerate patches if the rebase is hairy.

## Wide reads (Trig f23243e, RESULTS.md "Wide reads"): runtime.zig readInt/writeInt for 16-byte types lower to 16 byte loads (std.mem.readInt @bitCast of [16]u8). Fix: load via @Vector(n,u8) (`bytes[i..][0..n].*`), @bitCast, @byteSwap for big-endian: ldp on aarch64, 2x mov x86_64, 2x i64.load wasm32, v128.load simd128; n<=8 identical. +9-27% on U128 kernels.
Trig field table: Rig (safe) beats every parser on gsoc-2018 (4792 vs zimdjson 3800, simd-json tape 3849); elsewhere 59-81% of zimdjson/simd-json; 1.6-3.3x serde_json; 1.5-7x Zig std.json.
  CORRECTION (Trig d8a3136): sonic-rs measured and is fastest on gsoc-2018 (4698) vs Rig safe 2987 / fast-experiment 3304; Rig still beats simd-json (2665) and zimdjson (2270) there. Rig-fast as % of fastest: twitter 49% (zimdjson), canada 63% (sonic-rs), citm 80%, github_events 76%. Fast vs safe: +0-2% on 3 files, +11% gsoc, +15% canada = overflow-check cost, recoverable by checker-proved bounds. (noisy run, load 12-14; ratios only)

## Build store regrew to 376 GB in ~2 days despite 2-day pruning (renames rebuilt everything). Follow-up: give test/run's build store a SIZE cap (like the package cache cap), e.g. 50 GB, LRU by `used`; consider 1-day default.

## #115 verified by Trig (clean interleaved, load 4-5, best of 11): one read[U128] +1..+23% (gsoc +23%, github_events +16%, twitter +8%); now ties two U64 reads within 2-4%. Coming from Trig: SIMD recommendation + runtime findings (List.push not inlined; String.add via Writer.Allocating; String.clear memset 0xAA).

## Trig compiler profile (2026-10-11, evidence in Trig scratchpad/profile/)
All patches combined (rig-safe): twitter +2–4%, canada +26–29%, citm +18–25%, gsoc +9–12%, github +12–17%.
1. Checker-proved check elimination (`read[T]` under dominating `i + 8 <= len`; `i += 1` under `i < len`): +2.3–7.1%. Bounds +4–11%, overflow +1–11% total.
2. `for c, k in s[at..]` emits usize→i64 @intCast check per iteration: canada +3.7%. Class fix in emit -> round `forcast`.
3. Inline control (hot helpers stay calls; skip_space outlined at 6 sites): +1–14%. Needs decision: `inline` marker vs compiler heuristic; cold/unlikely marker.
4. Bit intrinsics (leading_zeros/trailing_zeros/count_ones): canada +10.9% from clz. Needs naming decision (methods, like x.not()).
5. Stack protector in safe builds: 0–4% (partly String.add writer, fixed by rtfast). Needs decision.
Not worth: merging rig.index sign+unsigned compare (−1..−4%); optionals/error unions; drops/defers.
- bits measured by Trig: canada +16..38% from real leading_zeros. Follow-up (low): bit-intrinsic results are nonneg, so `/ 2^k` on them can lower to a shift (measured 4–6% on SWAR helpers). Fold into proven-checks round 2 (nonneg facts; design §11 "bit-intrinsic ranges").
- Nexus adds generated `Span.text(source)` (clamped). Optional Rig cleanup: replace diag.textOf/textBetween with it — do AFTER simd/proofs/inline/strput merge (touches ~25 sites).
## Trig on simd c94e359c3 (2026-10-11)
- 16-lane string scan: gsoc +13–22%; all 22 variants 10495/10495.
- Fix in r1 (sent to simd agent): generic-n compare emit bug (accept-means-correct), NEON bits fmov + @select, any() via umaxv, messages.
- Round 2 input: m.first() -> Int? (needs owner name OK), pad: as STOP byte (at==len allowed), blocks(N) from any offset yielding (block, offset), module-level Simd constants, byte lookup.
- Proofs r2: Simd read range check under i+16<=len; rig.len check-at-creation idea; `m << m.leading_zeros()` rule.
- Inline: small entry + out-of-line run must not be re-merged.
- strput gated by Trig: twitterescaped −7.2% instr/byte, no regressions. Round `pushtrim` started: reject byte order on 1-byte T (push+read), remove never-firing checks in runtime append paths (invariant-justified).
- Later (String API, Trig RIG-NEEDS 12): partial-word append (byte count, or !t.truncate(n)); a reserved-window write `write[T,e](at,v)` checked once per window; String len reloaded from memory each push (aliasing) — consider a local "writer" handle that keeps len in a register. Needs design + owner names.
- Trig gate #125 (c793cbb39): no regression; instr/byte −5.5..−17% on 5 files, canada +0.24%. Re-gate after comptime-leak fix.
- simd follow-up (after r1 lands, small round): any()/all() at >16 lanes must survive loops — OR the 16-byte pieces then umaxv/uminv intrinsic (aarch64, comptime-guarded; LLVM folds the @reduce(.Max,@select) form back to bitcast). Repro: Trig scratchpad jsonsimd/zigmask/m2.zig scanUmaxv; jsonsimd/repro/anybits.rig. Also a following bits() after any() costs 146 instrs.
- simd+inline merge conflict: src/sema.zig name list ("splats" vs "string_nums") — keep both.
## Trig preview of full stack (main+proofs+inline+simd), 2026-10-11
- Scalar Trig = 1.02x sonic-rs geomean (2644 vs 2591 MB/s); +29% over main alone, inline is most of it. Wins twitter 1.11, citm 1.09, github 1.23; behind canada 0.87, escaped 0.92, gsoc 0.95.
- SIMD variant ~24% SLOWER in time despite fewer instructions: two vector->GPR crossings per string exit on the critical path. Fix: m.first() via shrn#4 nibble mask (one crossing); any-then-locate should compute nibble mask once. Instruction counts misled; measure cycles/time.
- Merge note for proofs redesign: emit .read/.write arm conflicts with simd; vectors take simdRead/simdWrite, numSize null for vectors.
- Priority for Trig: inline first, then proofs (after redesign).
- main: a function holding two 7.2 MB arrays segfaults instead of a stack-guard diagnostic (value_size_limit is per value, not per frame). Class: frame size; #125 added a frame budget for inlining — extend to every function frame. Round after current ones.
## Trig 2026-10-11 evening: beats sonic-rs on 5/6 (main+proofs+inline+simd): twitter 1.09x, escaped 1.09x, canada 1.05x, citm 1.07x, github 1.07x, gsoc 0.91x (tiered SIMD needs simd+simdfirst).
- Round rtclear started: List.clear O(n) for plain elems; verify List.push / push[T,e] residual checks.
- Language need (design + owner): multiple results — out-param `!U64` stays in a register only when inlined; inline limit (60 nodes) forced splitting take_digits (9% instrs on canada). Options: tuple/multi-return, or out-params kept in registers; or revisit the inline size threshold with measurement.
- Proofs redesign input: `i < n and src[i]` with `n = src.len` bound earlier still emits both checks (equalities = round 2 item).
- Bit casts via [8]U8 fold to fmov: clarity-only, no speed need.
- Trig af54e2f: tiered scan (16B SWAR then 16-lane SIMD + nibble first, overlapping tail) beats sonic-rs on ALL 6 files: gsoc 1.02x, twitter 1.06x, escaped 1.06x, canada 1.03x, citm 1.07x, github 1.09x. Draft src/json-tier.rig.draft @ af54e2f → std.json PR after simd+simdfirst land.
- simd follow-up (low, perf): aarch64 4/8-byte byte-lane vector reads/writes now 8–18 instrs (ld1r + per-lane) since 0ca5e289a exact-bytes fix; was one ldr w. Load as uN then @bitCast. Probe .git/revamp/r3/revsimd2/.
- main (low): unmarked Cell branch base error suggests `(!b.c if yes else d.c)[i] = e`, which is itself rejected (incompatible types). Probe .git/revamp/r3/rev128/cell_branch_hint.rig.
- Deep gate now includes bench/json/guard.py (instructions/byte vs bench/json/guard.txt, fails >2% over; macOS) once std.json lands.
- proofs2 landing: remeasure std.json vs sonic-rs (bench/json) and update docs/json/RESULTS.md; deep gate runs bench/json/guard.py.
- Syntax design input from Trig (owner 2026-10-11 discussion, Ruby idioms, consumer summary) saved locally at .git/revamp/r3/syntax-input/ (copied from Trig 42a8a60). Fold relevant parts into IDEAS.md when a syntax round takes them up; proposed forms must be marked pending/non-rig fences there.
- proofs2 #138: deep unit. grid (4,782 cells) not run yet -> include in next deep gate on pup.
- JSON guard: #144 regenerates guard.txt at 34ffed549 (post-proofs2); tools now median-of-5. Every round that changes std.json speed must run `bench/json/guard.py --update` and commit the baseline.
## Owner decision via Trig (2026-10-12, CORRECTED): WASM is Trig's EVENTUAL target — not urgent; Trig develops natively (arm64 + x86-64), compiles to wasm32 at the end; WASM must not constrain current work. NEEDS 9 stays after 1/2/5. Spike: welcome when convenient, low priority. Standing asks that also help native: memory compactness (NEEDS 8, per-value layout), core needs no threads.
### (superseded first message)
- Trig ships as wasm32; every milestone (from the scanner) must build + pass tests in WASM.
- Rig asks: NEEDS 9 (WASM target) moves up to right after NEEDS 1 (modules at scale), 2 (traits + Map/Set), 5 (closures). Covers: runtime/std with no OS calls in wasm32 (allocator, output), host-exported text functions, `rig build --target wasm32-wasi` (+ freestanding) supported and tested, a suite subset under wasmtime.
- Memory weighs more (4 GB cap; tsc 1.78 GB on Next.js): arenas, compact layout (NEEDS 8), per-value header costs.
- SIMD128 lowering speed now measured on WASM.
- Known today: runtime mask helpers pass unit tests under wasmtime ±simd128; a whole-program wasm32-wasi build failed on a std Environ error (simdfirst round). Plan: a cheap WASM feasibility spike to size the work.
## Trig Phase 0 needs (NEEDS 16-27, 2026-10-12)
- Started: matchperf (16, quadratic match checking), trigfix (21 math + abs(-0.0) bug, 13 String() default, 27 [N]Static->[]?String, 7-small error type gaps).
- Modules: asked builder to add test files seeing module privates (Go _test style), as a decision to confirm.
- Need owner spellings (proposal batch): 17 enum from backing int + all-variants list; 18 Float<->U64 bits; 19 shortest float digits / exponent format; 20 wrapping int conversion (Go int32(i)); 22 std UTF-8 rune decode + Unicode whitespace; 25 test assertions; 23 bigint / 24 regex (low).
- Later/design: 26 partial moves (ownership), 7 errors with data (big).
- Trig's order after modules: closures before traits+Map/Set (closures gate 131 of 257 Go files, maps 82, interfaces 33) — owner to decide.
- Inliner gaps (from json.rig, 2026-10-12): (1) a compile-time parameter blocks inlining (src/inlining.zig) — specializing document[dense: Bool] pushed skip_ws/scalar out of line, 10-15% more instructions; must be free. (2) no way to keep a cold path out of line (inlining the bitmap everywhere cost 4-6% when unused); owner chose "no inline syntax" — a `cold` marker is an owner decision.
- proofguard (early-return guard proofs) PARKED 2026-10-12: json.rig measured zero gain (LLVM already removes the check after inlining; "5%" was profiler attribution of the access, not the check). Real value is consistency only; resume later from branch proofguard + .git/revamp/r3/proofguard-parked.md. Lesson: size checks by removing them and counting (bench/json/checks/sizing.py), not by profiler leaf frames.
- QUEUED (start when inlinect PR merges): round `coldpaths` — infer cold for failure paths (! propagation, catch, panic, maybe `none` returns — measure), emit @branchHint(.cold); no syntax; measure std.json + examples; verify no semantic change (equiv: only hint lines).
- pup: /zfs/rig/nexus is a symlink to the pup nexus checkout (needed since worktrees moved to /zfs: rig finds nexus in the nearest parent dir).
