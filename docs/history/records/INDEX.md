# Records

Why Rig is the way it is: the designs the owner approved, the panels and
reviews behind them, measurements, bisects, and the work ledger. The
docs at the root and in docs/ say what is true; these say how it was
decided and what was measured. Records are history: each keeps its date
and is not updated after the fact, and none is run as a doc test.

- [ledger.md](ledger.md): the work log; its newest "RESUME HERE" entry is the summary of record.
- `2026-10/`: the rounds of 2026-10-21 and 22, by topic (below).
- `revamp/`: the records of the revamp rounds before them (reports, designs, studies), as they were kept in `.git/revamp/`.

Bulk data (profiles, build trees, source snapshots, probe programs) is not kept here; each report summarizes what its data showed.

## 2026-10: the rounds of 2026-10-21 and 22

| Topic | What it settled | Records |
|---|---|---|
| Function values and compile-time functions (#532) | a plain `fun` value crosses tasks; `fun cap[n: Int] -> Int`, called `cap[8]`, runs in the checker | [functions/](2026-10/functions/) |
| Closure field-path captures (#539) | `\|?@template\|` captures one field | [functions/closure-path-captures.approved.md](2026-10/functions/closure-path-captures.approved.md) |
| Lazy member tables | built in Trig, measured small (symbols are about a tenth of the heap), removed | [lazy-members/](2026-10/lazy-members/) |
| Safety checks | every check removed is worth 11.2% on ts-pattern; index tests 8.0%; by site and family | [safety-checks/](2026-10/safety-checks/) |
| Map and Set internal checks | a 1.3-1.9% ceiling on ts-pattern; the restructure that let proofs cover the probes gained nothing (0.2% slower), so it was not landed; the rest needs a typed entry index or `find` returning the entry (an ownership-checker limit) | [safety-checks/len-and-map-notes.md](2026-10/safety-checks/len-and-map-notes.md), [map-set-patches/](2026-10/safety-checks/map-set-patches/) |
| List length invariant (#538) | a List's length is below 2^62 by construction, so reading it makes no test: Trig 0.8-2.9% faster | [safety-checks/len-and-map-notes.md](2026-10/safety-checks/len-and-map-notes.md) |
| Table and Slot (#536) | indexes with no bounds test; about 3% on Trig's stores in a stand-in build (store indexes treated as proven; Trig has not migrated yet); two adversarial reviews | [table-slot/](2026-10/table-slot/) |
| Scheduler ping-pong (#541) | a regression bisected to one line of #451, and its fix | [scheduler/](2026-10/scheduler/) |
| Allocator with tasks (Trig G9) | no change needed; prefault per heap gains nothing | [allocator-g9/](2026-10/allocator-g9/) |
| Memory: List growth slack | exact presizing saves 4% on Linux, nothing on the Mac; not pursued | [memory/](2026-10/memory/) |
| Audit of #532-#547 | no test or oracle weakened; one memory hole from #532 (a closure literal to an actor's task) and three check-then-fail bugs fixed; headline numbers corrected to measured ranges | [audit/](2026-10/audit/) |
| R4's placement swing (#565) | twitter on pup 2.3% slower and citm 7% faster from one 32-byte shift of identical code; accepted once by the owner | [errors-r4/accepted.md](2026-10/errors-r4/accepted.md) |
| Declared error sets (R2, #542) | its first review, and its fixes | [errors-r2/](2026-10/errors-r2/) |
| Clones across modules, and Map's `+` | its review: a nested generic hid a drop body, fixed | [clone/](2026-10/clone/) |
| Error data in the runtime (R3a) | its design, and a review with no blocker | [errors-r3a/](2026-10/errors-r3a/) |
| CORE's "A failure moves its error" | a panel of four, and the final text | [errors-core/](2026-10/errors-core/) |
| Errors that carry fields (R3, #555) | its design, and a review of eight findings, all fixed before it landed | [errors-r3/](2026-10/errors-r3/) |
| One representation for `error` (Option U) | the design check of R3's mode switch: `error` is always an `ErrorValue`, the slot has no bits without fields, and 7 latent bug classes | [errors-r3/design-check-u.md](2026-10/errors-r3/design-check-u.md) |
| Generic sets (R2.5, #569) | a function takes its set as a type parameter after `!`; a callable view of any fallible function takes the slot, so one view type serves every instance; a review of six findings, resolved | [errors-r25/](2026-10/errors-r25/) |
| Frozen values (`*Frozen[T]`) | a handle counted atomically for a value no one changes, read by many tasks; Rig's review | [frozen/](2026-10/frozen/) |
| Fix: `Stop.canceled` after a failed `par.map` | a waiter takes no cancel from the task it waits on; `par.map`, `par.each`, and `http.serve` were affected | [fixes/parmap-cancel.md](2026-10/fixes/parmap-cancel.md) |
| The consolidation round (ready, 2026-10-23) | the brief for a fresh session after errors with data: one classifier per fact, no bug open, docs, tooling, speed baseline, and optionally v0.3.0 | [consolidation/PLAN.md](2026-10/consolidation/PLAN.md) |
| pup's memory rule (consolidation track 4) | a proposal for Trig: `tools/release-slot` takes a slot only with 12 GB available and at most one other release build | [consolidation/pup-slot-memory.md](2026-10/consolidation/pup-slot-memory.md) |
| APIs Stage 3's refresh (2026-10-23) | Stage 3 of docs/design/apis.md for this period's changes: an API method fails with exactly the API's set, witnesses of a generic type are its parameters, facts no API names stay per instance, public generics state their bounds as the last step; a six-phase build plan and 15 questions with defaults; phase 1's notes and its [review](2026-10/apis-stage3/review-p1.md) | [apis-stage3/](2026-10/apis-stage3/) |
| The docs pass (consolidation track 3) | README, WELCOME, QUICK, SPEC §19, Learn Rig 03 and 04, STD, ROADMAP, and INTERNALS cover this period's features; the seven pending blocks checked | [consolidation/docs-pass.md](2026-10/consolidation/docs-pass.md) |

## Every record

### 2026-10/allocator-g9/

- [ab-pf.txt](2026-10/allocator-g9/ab-pf.txt)
- [prefault-benches.log](2026-10/allocator-g9/prefault-benches.log)
- [scale-e.txt](2026-10/allocator-g9/scale-e.txt)

### 2026-10/apis-stage3/

- [build-plan.md](2026-10/apis-stage3/build-plan.md): where Stages 1 and 2 live, where each Stage 3 piece goes, six phases with their cases, risks, and sizes; the count of `pub` generics needing bounds
- [open-questions.md](2026-10/apis-stage3/open-questions.md): what the record does not settle, each with a default
- [phase1-notes.md](2026-10/apis-stage3/phase1-notes.md): phase 1 as built (declarations and conformance), its decisions beyond the design, its new messages, and what each later phase takes
- [review-p1.md](2026-10/apis-stage3/review-p1.md): the adversarial review of phase 1: findings by severity with their fixes and cases, points for phase 2, and what was probed without findings

### 2026-10/clone/

- [review-1.md](2026-10/clone/review-1.md): Review: clones across modules, and the fix of its finding

### 2026-10/errors-core/

- [final.md](2026-10/errors-core/final.md): the panel's result, and the final text's choices
- [brief.md](2026-10/errors-core/brief.md), [expert-1-spec-author.md](2026-10/errors-core/expert-1-spec-author.md), [expert-2-ownership.md](2026-10/errors-core/expert-2-ownership.md), [expert-3-writer.md](2026-10/errors-core/expert-3-writer.md), [expert-4-core-purist.md](2026-10/errors-core/expert-4-core-purist.md)

### 2026-10/errors-r3a/

- [design.md](2026-10/errors-r3a/design.md): R3a, the runtime's error-data plumbing
- [review-1.md](2026-10/errors-r3a/review-1.md): its review, and the resolution

### 2026-10/errors-r3/

- [design-r3-1.md](2026-10/errors-r3/design-r3-1.md): R3, fields on error members: calls, catch, match, print, main
- [review-1.md](2026-10/errors-r3/review-1.md): Review: errors that carry fields (PR #555), and how each finding was fixed
- [design-check-u.md](2026-10/errors-r3/design-check-u.md): the design check that dissolved R3's `error_data` switch (Option U)
- [u-timing.md](2026-10/errors-r3/u-timing.md): Option U against main: std.json on both machines, the instruction guard, and the micro-benchmarks

### 2026-10/errors-r25/

- [design.md](2026-10/errors-r25/design.md): R2.5, generic sets: the rules, what they lower to, and where they are built
- [review-1.md](2026-10/errors-r25/review-1.md): its review: two HIGH (a re-raise into a read-only slot, `select`'s fallible arms), one MEDIUM, three LOW, and how each was resolved

### 2026-10/errors-r2/

- [review-1.md](2026-10/errors-r2/review-1.md): Review: declared error sets (branch `errsets`, PR #542)
- [review-1-fixes.md](2026-10/errors-r2/review-1-fixes.md): how each of review 1's findings was fixed

### 2026-10/fixes/

- [parmap-cancel.md](2026-10/fixes/parmap-cancel.md): `Stop.canceled` after a failed `par.map`

### 2026-10/frozen/

- [design.md](2026-10/frozen/design.md): `*Frozen[T]`: a value many tasks read
- [review-1.md](2026-10/frozen/review-1.md): Review: `*Frozen[T]` (branch `frozen`), and its fixes

### 2026-10/functions/

- [capture-free.md](2026-10/functions/capture-free.md): Can a plain `fun` value cross between tasks? Soundness review
- [closure-path-captures.approved.md](2026-10/functions/closure-path-captures.approved.md): Closures that capture a field path
- [comptime.md](2026-10/functions/comptime.md): Compile-time functions (`fun cap[n: Int] -> Int`): review and v1 design
- [ctfun-build.md](2026-10/functions/ctfun-build.md): Compile-time functions v1: build report
- [grammar-recommended.diff](2026-10/functions/grammar-recommended.diff)
- [syntax-cost.md](2026-10/functions/syntax-cost.md): Compile-time functions and fun values in tasks: syntax and cost review

### 2026-10/lazy-members/

- [PLAN.md](2026-10/lazy-members/PLAN.md): Lazy member tables in Trig: the plan
- [exactness.md](2026-10/lazy-members/exactness.md): Lazy member tables in Trig: exactness and measurement plan
- [port-map.md](2026-10/lazy-members/port-map.md): Port map: lazy member tables (#64475, #64526) into Trig
- [rig-fit.md](2026-10/lazy-members/rig-fit.md): Lazy member tables in Trig: how they fit Rig

### 2026-10/memory/

- [presize-ab-mac.txt](2026-10/memory/presize-ab-mac.txt)
- [presize-ab-pup.txt](2026-10/memory/presize-ab-pup.txt)

### 2026-10/safety-checks/

- [expert-B-proof-ranges.md](2026-10/safety-checks/expert-B-proof-ranges.md): Panel B: extending the proof pass (ranges, hoisting, slices, unwraps)
- [len-and-map-notes.md](2026-10/safety-checks/len-and-map-notes.md): Length invariant and Map/Set checks: notes
- [measurement.md](2026-10/safety-checks/measurement.md): What safety checks cost Trig (2026-10-21)
- [plan.md](2026-10/safety-checks/plan.md): Next Rig round (after fun-and-comptime lands): what safety checks cost Trig

### 2026-10/safety-checks/data/

- [census-all.summary.txt](2026-10/safety-checks/data/census-all.summary.txt)
- [census-base.summary.txt](2026-10/safety-checks/data/census-base.summary.txt)
- [census-bounds.summary.txt](2026-10/safety-checks/data/census-bounds.summary.txt)
- [census-cast.summary.txt](2026-10/safety-checks/data/census-cast.summary.txt)
- [census-fast.summary.txt](2026-10/safety-checks/data/census-fast.summary.txt)
- [census-index.summary.txt](2026-10/safety-checks/data/census-index.summary.txt)
- [census-other.summary.txt](2026-10/safety-checks/data/census-other.summary.txt)
- [census-overflow.summary.txt](2026-10/safety-checks/data/census-overflow.summary.txt)
- [census-tags.summary.txt](2026-10/safety-checks/data/census-tags.summary.txt)
- [measure-switch.diff](2026-10/safety-checks/data/measure-switch.diff)
- [rank-base-tsp.txt](2026-10/safety-checks/data/rank-base-tsp.txt)
- [times2.summary.txt](2026-10/safety-checks/data/times2.summary.txt)
- [times3.check](2026-10/safety-checks/data/times3.check)
- [times3.medians.txt](2026-10/safety-checks/data/times3.medians.txt)
- [times3.summary.txt](2026-10/safety-checks/data/times3.summary.txt)

### 2026-10/scheduler/

- [pingpong-bisect.md](2026-10/scheduler/pingpong-bisect.md): bench/net pingpong regression on pup (2026-10-21)
- [wake-fix.md](2026-10/scheduler/wake-fix.md): Fix for the pingpong regression: PR #541 (merged as f14b86c58), rows in PR #543
- [align.md](2026-10/scheduler/align.md): Each worker on cache lines of its own (#552), and the full field layout measured against it (2026-10-22)

### 2026-10/table-slot/

- [build-notes.md](2026-10/table-slot/build-notes.md): Table/Slot build: details
- [design-expert-A.md](2026-10/table-slot/design-expert-A.md): Panel A: typed ids into append-only stores, and counters that only count up
- [review-1-holes.md](2026-10/table-slot/review-1-holes.md): Table/Slot: holes for the builder (adversarial review of A-typed-ids.md, option B)
- [review-2-holes.md](2026-10/table-slot/review-2-holes.md): Table/Slot: second review, against 6fde90632 (table-slot)
- [store-unchecked-ab.txt](2026-10/table-slot/store-unchecked-ab.txt)

### revamp/

- [CORE-draft.md](revamp/CORE-draft.md): Rig Core (draft 3)
- [audit-brackets-emit.md](revamp/audit-brackets-emit.md): Audit: `brackets` branch, emitter correctness and code review
- [audit-brackets-frontend.md](revamp/audit-brackets-frontend.md): Audit: brackets branch, front end and type checker
- [audit-brackets-ownership.md](revamp/audit-brackets-ownership.md): Audit: brackets branch, ownership soundness of generic functions and methods
- [audit-ca.md](revamp/audit-ca.md): Audit: closure-args (borrowed callables, `|?x|` / `|!x|`)
- [audit-cmp.md](revamp/audit-cmp.md): Audit: cmp-foundations (structural `==`, String/`[]U8` ordering)
- [audit-ctsizes-frontend.md](revamp/audit-ctsizes-frontend.md): Audit: ct-sizes, front end (grammar, checker, diagnostics, docs)
- [audit-ctsizes-soundness.md](revamp/audit-ctsizes-soundness.md): Audit: ct-sizes, soundness and emit correctness
- [audit-docs.md](revamp/audit-docs.md): Audit: documentation truth and quality (revamp @ 5f2bdbc)
- [audit-emit.md](revamp/audit-emit.md): Audit: code generator and runtime (`src/emit.zig`, `src/runtime.zig`)
- [audit-final.md](revamp/audit-final.md): Final verification: revamp @ 94df525
- [audit-followups.md](revamp/audit-followups.md): Audit: `main..followups` (nested arrays, borrowed operands, expected-type inference)
- [audit-frontend.md](revamp/audit-frontend.md): Front-end audit (revamp, base 5f2bdbc)
- [audit-fuzz.md](revamp/audit-fuzz.md): Generative fuzz audit: accept means correct (branch `revamp`, base 5f2bdbc)
- [audit-gaps.md](revamp/audit-gaps.md): Completeness audit: small gaps (revamp @ 206ea77)
- [audit-modgen-frontend.md](revamp/audit-modgen-frontend.md): Audit: generics across modules (grammar, checker, diagnostics, docs)
- [audit-modgen-soundness.md](revamp/audit-modgen-soundness.md): Audit: generics across modules — soundness lens
- [audit-ownership.md](revamp/audit-ownership.md): Audit: ownership checker (`src/ownership.zig`), revamp @ 5f2bdbc
- [audit-refuzz.md](revamp/audit-refuzz.md): Re-fuzz of the merged revamp (snapshot 5263941)
- [audit-sb.md](revamp/audit-sb.md): Adversarial audit: `slices-bytes` (main..slices-bytes, 4 commits)
- [audit-sc2.md](revamp/audit-sc2.md): Audit: syntax-cleanup-2 (adversarial review, R13)
- [audit-sema.md](revamp/audit-sema.md): Audit: declaration pass and semantic core (src/resolve.zig, src/sema.zig)
- [audit-tests.md](revamp/audit-tests.md): Audit: tests, build and CI; diagnostics and the newcomer experience
- [audit-typecheck.md](revamp/audit-typecheck.md): Audit: expression type checker (src/typecheck.zig)
- [brief-common.md](revamp/brief-common.md): Common brief for revamp implementers (phase B)
- [brief-simplify.md](revamp/brief-simplify.md): Brief: simplification pass (no behavior change)
- [burst-brief.md](revamp/burst-brief.md)
- [design-step2.md](revamp/design-step2.md): Step 2 design: array sizes from compile-time values, and value parameters on generic types
- [design-step3.md](revamp/design-step3.md): Design: generics across modules (based on `ct-sizes`)
- [design-step3c.md](revamp/design-step3c.md): Step 3c design summary (Plan agent, 2026-09-26, read-only vs main ff9aa85)
- [rig-update-2026-10-15.md](revamp/rig-update-2026-10-15.md)
- [syntax-review.md](revamp/syntax-review.md): Syntax review (5 read-only agents, 2026-09-27) — condensed findings

### revamp/r3/

- [audit-step1-facts.md](revamp/r3/audit-step1-facts.md): REVAMP-3 audit: HANDOFF step 1, "Type facts"
- [audit-step2-classify-exit.md](revamp/r3/audit-step2-classify-exit.md): REVAMP-3 audit: HANDOFF step 2, "One classifier and one exit"
- [audit-steps3-6.md](revamp/r3/audit-steps3-6.md): REVAMP-3 audit: HANDOFF steps 3–6 (the Core's planned rules)
- [bigint-report.md](revamp/r3/bigint-report.md): std.bigint report (2026-10-16)
- [bigint-review.md](revamp/r3/bigint-review.md): Review of PR #287, std.bigint (head 00965cb2d), 2026-10-16
- [brief-buildcpu.md](revamp/r3/brief-buildcpu.md): Queued round: `rig build --cpu` (owner-approved 2026-10-15, after inline2)
- [brief-common.md](revamp/r3/brief-common.md): Common brief for REVAMP-3 subagents (Rig)
- [brief-copies.md](revamp/r3/brief-copies.md): Brief: one "copies" fact (the design owner's item 3)
- [brief-declreqs.md](revamp/r3/brief-declreqs.md): Queued round: declared requirements for built-in methods
- [brief-destination-passing.md](revamp/r3/brief-destination-passing.md): Queued round: destination-passing for large aggregates
- [brief-enumorder.md](revamp/r3/brief-enumorder.md): Queued round: enums order (Trig NEEDS 44; owner-approved 2026-10-16)
- [brief-frameowners.md](revamp/r3/brief-frameowners.md): Round brief: frameowners
- [brief-grapheme-name.md](revamp/r3/brief-grapheme-name.md): Brief: one short name for "how many characters a reader sees"
- [brief-inline2.md](revamp/r3/brief-inline2.md): Brief: inline (step 3), on frameowners
- [brief-noalias.md](revamp/r3/brief-noalias.md): Queued round: `noalias` for write views (owner-approved 2026-10-15, after `rig build --cpu`)
- [brief-roundA-field-loans.md](revamp/r3/brief-roundA-field-loans.md): Round A brief: disjoint field loans (NEEDS 28)
- [brief-roundB-keeps.md](revamp/r3/brief-roundB-keeps.md): Round B brief: `keeps s` (NEEDS 11)
- [brief-step3.md](revamp/r3/brief-step3.md): Brief: HANDOFF step 3, "Reads and lends" (REVAMP-3)
- [brief-step4-5.md](revamp/r3/brief-step4-5.md): Brief: HANDOFF step 4 ("Containers hold anything") + the rest of step 5 (REVAMP-3)
- [brief-widemasks.md](revamp/r3/brief-widemasks.md): Queued round: fast wide masks in Simd (json.rig NEEDS, 2026-10-15)
- [brief-zignames.md](revamp/r3/brief-zignames.md): Queued round: names that collide in emitted Zig (found by #247's review, 2026-10-16)
- [bulk.sh](revamp/r3/bulk.sh)
- [checkprof-uncommitted.patch](revamp/r3/checkprof-uncommitted.patch)
- [ci-forensics.md](revamp/r3/ci-forensics.md): Rig CI forensic report
- [classify_equiv.py](revamp/r3/classify_equiv.py)
- [cold-evidence.md](revamp/r3/cold-evidence.md): Cold-path evidence for the oncecall rule / a `cold` marker (json.rig, 2026-10-13)
- [copies-boundary.md](revamp/r3/copies-boundary.md): Design note: where a read view of a value that copies is copied out
- [ctrlc-proposal.md](revamp/r3/ctrlc-proposal.md): Ctrl-C: an interrupt cancels `main`
- [design-proofs-v2.md](revamp/r3/design-proofs-v2.md): Design v2: checks the compiler proves away, rebuilt on units
- [design-proven-checks.md](revamp/r3/design-proven-checks.md): Design: checks the compiler proves away
- [design-reference-checker.md](revamp/r3/design-reference-checker.md): Design: a reference ownership checker for Rig (the oracle)
- [emit_equiv.py](revamp/r3/emit_equiv.py)
- [flakes-report.md](revamp/r3/flakes-report.md): Test flakes (PR #300)
- [followup-sema-dump.md](revamp/r3/followup-sema-dump.md): Follow-up: `check --facts=sema` panics on SPEC.md block at L5516
- [gate-report.md](revamp/r3/gate-report.md): What I built (all in #277)
- [gates.sh](revamp/r3/gates.sh)
- [gauntlet-design.md](revamp/r3/gauntlet-design.md): Test strategy and merge queue: Rig's gauntlet (expert report, 2026-10-17)
- [gauntlet-report.md](revamp/r3/gauntlet-report.md): Gauntlet report (2026-10-17)
- [hashmap-report.md](revamp/r3/hashmap-report.md): std.hash Map and Set against Trig's ordered map (NEEDS 42)
- [irdump.py](revamp/r3/irdump.py)
- [json-handoff.md](revamp/r3/json-handoff.md): std.json handoff from the "Rig - json.rig" session (2026-10-16)
- [json-resume.md](revamp/r3/json-resume.md): std.json: resume here ("Rig - json.rig" session, paused 2026-10-13)
- [json-to-rig.md](revamp/r3/json-to-rig.md): std.json → Rig: where it stands, and what it needs from the compiler
- [json-x86-20261013.log](revamp/r3/json-x86-20261013.log)
- [lend-base-redesign.md](revamp/r3/lend-base-redesign.md): lend-base, redesigned
- [lend-base-resume.md](revamp/r3/lend-base-resume.md): lend-base: resume notes (review round 1 fixes)
- [loc.sh](revamp/r3/loc.sh)
- [nexus-lsp-dryrun.md](revamp/r3/nexus-lsp-dryrun.md): Nexus PR #50 (`nexus --editor`) dry run on Rig, 2026-10-16
- [nexus-lsp-review.md](revamp/r3/nexus-lsp-review.md)
- [nexus-pin-recipe.md](revamp/r3/nexus-pin-recipe.md): Nexus pin through Zig's package manager (recipe from the Nexus session, 2026-10-10)
- [nexus-sync-keeps.diff](revamp/r3/nexus-sync-keeps.diff)
- [nexus-sync-polish.diff](revamp/r3/nexus-sync-polish.diff)
- [nexus-sync-rename.diff](revamp/r3/nexus-sync-rename.diff)
- [nexus-sync-seam2b.diff](revamp/r3/nexus-sync-seam2b.diff)
- [nexus-sync-v0.2.0.diff](revamp/r3/nexus-sync-v0.2.0.diff)
- [notes-0.1.4.md](revamp/r3/notes-0.1.4.md): Fixed
- [notes-0.1.5.md](revamp/r3/notes-0.1.5.md): Fixed
- [notes-0.1.6.md](revamp/r3/notes-0.1.6.md): Fixed
- [notes-0.2.0.md](revamp/r3/notes-0.2.0.md): New in the language
- [notes-0.2.1.md](revamp/r3/notes-0.2.1.md): Fixed
- [notes-0.2.2.md](revamp/r3/notes-0.2.2.md): Fixed
- [notes-0.2.3.md](revamp/r3/notes-0.2.3.md): Fixed
- [notes-0.2.4.md](revamp/r3/notes-0.2.4.md): Fixed
- [notes-0.2.5.md](revamp/r3/notes-0.2.5.md): The rule
- [notes-0.2.6.md](revamp/r3/notes-0.2.6.md): Fixed
- [notes-0.2.7.md](revamp/r3/notes-0.2.7.md): New
- [notes-0.2.8.md](revamp/r3/notes-0.2.8.md): Fixed
- [notes-0.2.9.md](revamp/r3/notes-0.2.9.md): Fixed
- [one-decider-inventory.md](revamp/r3/one-decider-inventory.md): One decider: inventory of emit's ownership and memory decisions
- [open-items.md](revamp/r3/open-items.md): Open items that must not be lost (post-v0.2.0)
- [owner-brief-ownership-regex.md](revamp/r3/owner-brief-ownership-regex.md): Owner brief: field loans, `keeps`, the `replace` fix, std.regex
- [payload-loan-redesign.md](revamp/r3/payload-loan-redesign.md): payload-loan, redesigned
- [polish_rewrite.py](revamp/r3/polish_rewrite.py)
- [pr-arm-temps.md](revamp/r3/pr-arm-temps.md): Keep a match arm's temporaries in the arm, and count an assignment target's uses after its value
- [pr-assign-desugar.md](revamp/r3/pr-assign-desugar.md): Check and emit an assignment as its value, then its store
- [pr-b4a.md](revamp/r3/pr-b4a.md): Summary
- [pr-b4b.md](revamp/r3/pr-b4b.md): Summary
- [pr-barefor.md](revamp/r3/pr-barefor.md): Bare `for`
- [pr-bits.md](revamp/r3/pr-bits.md): PR: bit methods and the wrapping left shift
- [pr-cache-cap.md](revamp/r3/pr-cache-cap.md): Cap the package cache by size (branch cache-cap)
- [pr-cell-mark.md](revamp/r3/pr-cell-mark.md): Mark every change to a shared Cell with a write lend
- [pr-cell-mut.md](revamp/r3/pr-cell-mut.md): Emit views of Cell holders as mutable pointers, and drop `@constCast`
- [pr-cell-temp.md](revamp/r3/pr-cell-temp.md): Lend or change a temporary holding a Cell, in its statement's slot
- [pr-cell-temp2.md](revamp/r3/pr-cell-temp2.md): Keep a temporary holding a Cell in its statement's slot, reached by one leaf walk
- [pr-closure-arity.md](revamp/r3/pr-closure-arity.md): PR closure-arity
- [pr-closures.md](revamp/r3/pr-closures.md): PR notes: closures as values, round 1 (`closures`)
- [pr-codev.md](revamp/r3/pr-codev.md): Generate src/parser.zig at build time
- [pr-copies.md](revamp/r3/pr-copies.md): One "copies" fact (ownership lane B)
- [pr-decide.md](revamp/r3/pr-decide.md): Decisions: `for x in !it`, and CORE on Static and holders
- [pr-docs-rules.md](revamp/r3/pr-docs-rules.md)
- [pr-errors-r1-notes.md](revamp/r3/pr-errors-r1-notes.md): PR notes: errors that carry data, round R1 (`errors`)
- [pr-errors.md](revamp/r3/pr-errors.md): What round 1 does
- [pr-fieldloans.md](revamp/r3/pr-fieldloans.md): The rule as built
- [pr-fold.md](revamp/r3/pr-fold.md): The fold (text plan, step 2): one text view
- [pr-for-iter.md](revamp/r3/pr-for-iter.md): Walk an iterator with `for`
- [pr-forlend.md](revamp/r3/pr-forlend.md): A soundness fix found on the way
- [pr-grid-delta.md](revamp/r3/pr-grid-delta.md): Rerun only what changed: `--delta` and a results cache
- [pr-gtloans.md](revamp/r3/pr-gtloans.md): The hole, on `main`
- [pr-hashapi.md](revamp/r3/pr-hashapi.md)
- [pr-hashfast.md](revamp/r3/pr-hashfast.md)
- [pr-header-paths.md](revamp/r3/pr-header-paths.md): Summary
- [pr-hotfix4.md](revamp/r3/pr-hotfix4.md): Summary
- [pr-hotfix5.md](revamp/r3/pr-hotfix5.md): Summary
- [pr-hotfix6.md](revamp/r3/pr-hotfix6.md): Summary
- [pr-hotfix7.md](revamp/r3/pr-hotfix7.md): Summary
- [pr-ignored-bang.md](revamp/r3/pr-ignored-bang.md): Summary
- [pr-inline.md](revamp/r3/pr-inline.md): Inline small, only-called functions
- [pr-keeps.md](revamp/r3/pr-keeps.md): The rule as built
- [pr-keywords.md](revamp/r3/pr-keywords.md): Keywords in the grammar
- [pr-lend-base.md](revamp/r3/pr-lend-base.md): Summary
- [pr-longtokens.md](revamp/r3/pr-longtokens.md): Design
- [pr-loop-lowering.md](revamp/r3/pr-loop-lowering.md): Lower every loop through one desugaring the checker walks
- [pr-mapfields.md](revamp/r3/pr-mapfields.md): The empty constructor `T()`
- [pr-mapset.md](revamp/r3/pr-mapset.md): R0: B1 to B3
- [pr-move-done.md](revamp/r3/pr-move-done.md): `<` always leaves its source done
- [pr-never-data.md](revamp/r3/pr-never-data.md): Mutation is never data
- [pr-objchain.md](revamp/r3/pr-objchain.md): Spell struct as obj, and continue a statement on a leading-dot line
- [pr-one-decider-2.md](revamp/r3/pr-one-decider-2.md): One decider, stage 2: the match, header, call, loop, and print decisions
- [pr-one-decider.md](revamp/r3/pr-one-decider.md): One decider: emit reads the checkers' decisions, never makes them
- [pr-payload-loan.md](revamp/r3/pr-payload-loan.md): Summary
- [pr-payload-names.md](revamp/r3/pr-payload-names.md): Summary
- [pr-polish-params.md](revamp/r3/pr-polish-params.md): Polish: parameter lists on every definition, Rig's own builtins, a style check
- [pr-polish.md](revamp/r3/pr-polish.md): Summary
- [pr-proofs.md](revamp/r3/pr-proofs.md): PR notes: proven checks, round 1 (`proofs`)
- [pr-proofs2.md](revamp/r3/pr-proofs2.md): PR notes: proven checks on units (`proofs2`)
- [pr-rem-min.md](revamp/r3/pr-rem-min.md): Summary
- [pr-rename.md](revamp/r3/pr-rename.md): v0.3.0 renames: `^T`, `List`, `String` / `?String`
- [pr-revamp.md](revamp/r3/pr-revamp.md): Summary
- [pr-rig-names.md](revamp/r3/pr-rig-names.md): `@name(T)` returns Rig's names
- [pr-rules.md](revamp/r3/pr-rules.md): Summary
- [pr-seam2b.md](revamp/r3/pr-seam2b.md): Summary
- [pr-seam3.md](revamp/r3/pr-seam3.md): Seam 3: a box, an optional, and a generic T hold a read view of an owner
- [pr-setorder.md](revamp/r3/pr-setorder.md): PR #128 (setorder): one recorded order for every assignment
- [pr-simd.md](revamp/r3/pr-simd.md): SIMD round 1 (`simd` branch): what was built, and open questions
- [pr-static.md](revamp/r3/pr-static.md): Static (text plan, step 1)
- [pr-syntax-a.md](revamp/r3/pr-syntax-a.md): Summary
- [pr-syntax-b.md](revamp/r3/pr-syntax-b.md): Summary
- [pr-targetarch.md](revamp/r3/pr-targetarch.md): Semantics
- [pr-test-infra.md](revamp/r3/pr-test-infra.md): Speed up the test tooling (no compiler semantics change)
- [pr-v022.md](revamp/r3/pr-v022.md): Summary
- [pr-while-step.md](revamp/r3/pr-while-step.md): Check a while step after the body, and send labeled continues through it
- [proofguard-parked.md](revamp/r3/proofguard-parked.md): proofguard: parked (2026-10-12)
- [proposal-call-stores.md](revamp/r3/proposal-call-stores.md): Proposal: a signature that reads an argument without keeping it
- [proposal-closures.md](revamp/r3/proposal-closures.md): Proposal: closures as values (Trig NEEDS 5)
- [proposal-compact-optionals.md](revamp/r3/proposal-compact-optionals.md): Proposal: compact optionals ("this object's none is id 0")
- [proposal-errors.md](revamp/r3/proposal-errors.md): Proposal: errors that carry data (Trig NEEDS 7)
- [proposal-field-loans.md](revamp/r3/proposal-field-loans.md): Proposal: field-disjoint loans
- [proposal-generic-loans.md](revamp/r3/proposal-generic-loans.md): Proposal: loans ride on `T`
- [proposal-hashfast.md](revamp/r3/proposal-hashfast.md): Proposal: hashfast, faster std.hash Map and Set, and a string interner
- [proposal-modules-constants.md](revamp/r3/proposal-modules-constants.md): Proposal: modules at scale, and constant tables
- [proposal-panic-print.md](revamp/r3/proposal-panic-print.md): Proposal: `panic`, `warn`, and `dbg` beside `print`
- [proposal-regex.md](revamp/r3/proposal-regex.md): Proposal: std.regex, a linear-time matching engine (NEEDS 24)
- [proposal-results-tuples.md](revamp/r3/proposal-results-tuples.md): Proposal: multiple results, not tuples
- [proposal-shared-scans.md](revamp/r3/proposal-shared-scans.md): Proposal: share std.json's general routines through std
- [proposal-small-spellings.md](revamp/r3/proposal-small-spellings.md): Proposal: small features Trig found, and how to spell them
- [proposal-symbols.md](revamp/r3/proposal-symbols.md): Proposal: symbols (`:name`), and labels move off `:`
- [proposal-text-names-v2.md](revamp/r3/proposal-text-names-v2.md): Proposal v2: the words and names for measuring text
- [proposal-text-names.md](revamp/r3/proposal-text-names.md): Proposal: the words and names for measuring text in Rig
- [proposal-traits-map.md](revamp/r3/proposal-traits-map.md): OWNER DECISIONS (2026-10-13, via the Trig session) — these override the text below
- [proposal-unicode.md](revamp/r3/proposal-unicode.md): Proposal: std.unicode, and the text helpers Trig asked for (NEEDS 22 follow-on)
- [pup-base.sh](revamp/r3/pup-base.sh)
- [pup-gates.sh](revamp/r3/pup-gates.sh)
- [pup-lib.sh](revamp/r3/pup-lib.sh)
- [pup.md](revamp/r3/pup.md): pup: the Linux test machine
- [pup.sh](revamp/r3/pup.sh)
- [review-307.md](revamp/r3/review-307.md): Review: PR #307 (stack-overflow-139), overflow handler
- [review-arm-temps-2.md](revamp/r3/review-arm-temps-2.md): Review 2: arm-temps (45fa39d4, e65b2bff; base main d6b0b6b2)
- [review-arm-temps.md](revamp/r3/review-arm-temps.md): Review: arm-temps (45fa39d4, base main b0f156c9)
- [review-assign-desugar.md](revamp/r3/review-assign-desugar.md): Review: assign-desugar (202b13fd)
- [review-b4a-round2.md](revamp/r3/review-b4a-round2.md): Review round 2: B4a fixes (b4-emit at b7e89291)
- [review-b4a.md](revamp/r3/review-b4a.md): Review: B4a (branch `b4-emit` at 26f0d3ce)
- [review-b4b-1.md](revamp/r3/review-b4b-1.md): Review: B4b part 1 (2d47a2db, d9225c3c)
- [review-b4b-2.md](revamp/r3/review-b4b-2.md): Review: B4b part 2 (ddefa968, "Let a read match's payload views outlive the arm where the match reads in place")
- [review-b4b-3.md](revamp/r3/review-b4b-3.md): Review: B4b part 2, second round (6b00e981) and part 3 (61b7cf53, 800bd825)
- [review-c-rules-round2.md](revamp/r3/review-c-rules-round2.md): Review round 2: the C rules (`c-rules` at `1c06aac9`)
- [review-c-rules.md](revamp/r3/review-c-rules.md): Review: the C rules (`c-rules` at `8f4ea627`)
- [review-cache-cap-1.md](revamp/r3/review-cache-cap-1.md): Review: cache-cap (src/main.zig, test/) -- can it delete/rename/modify what rig did not create, or a package in use?
- [review-cell-mark-1.md](revamp/r3/review-cell-mark-1.md): Review: cell-mark (PR #100, head c0721793), round 1
- [review-cell-mark-2.md](revamp/r3/review-cell-mark-2.md): Review: cell-mark (PR #100, head 340406f2), round 2
- [review-cell-mut.md](revamp/r3/review-cell-mut.md): Review: cell-mut (head 4c521b6a, against main 0cd9f3e3)
- [review-cell-temp-2.md](revamp/r3/review-cell-temp-2.md): Review round 2: cell-temp (1fb2acba, base main 5e551bc5)
- [review-cell-temp.md](revamp/r3/review-cell-temp.md): Review: cell-temp (09cc3e04, `git diff 81c75010...cell-temp`)
- [review-cell-temp2-2.md](revamp/r3/review-cell-temp2-2.md): Review: cell-temp2, round 2 (e5111234, then 7fb643b4)
- [review-cell-temp2.md](revamp/r3/review-cell-temp2.md): Review: cell-temp2 (543d4e2a, base 5db36f06)
- [review-copies-2.md](revamp/r3/review-copies-2.md): Review 2: branch `copies`, the fix commits
- [review-copies.md](revamp/r3/review-copies.md): Review: branch `copies` (one "copies" fact)
- [review-fold-1.md](revamp/r3/review-fold-1.md): Review: fold (601f9ecd vs main 3ed2964f), adversarial soundness, round 1
- [review-fold-2.md](revamp/r3/review-fold-2.md): Review: fold 0d9a73af, round 2 (argument evaluation order after the H1 fix)
- [review-for-iter-1.md](revamp/r3/review-for-iter-1.md): Review 1 of for-iter (ebc35dda on a2398d67)
- [review-for-iter-2.md](revamp/r3/review-for-iter-2.md): Review 2 of for-iter (857d86e8)
- [review-grid-delta.md](revamp/r3/review-grid-delta.md): Review: grid-delta (dc422902), can `--delta` give a false green?
- [review-header-paths-1.md](revamp/r3/review-header-paths-1.md): Review: header-paths (PR #96), round 1
- [review-header-paths-2.md](revamp/r3/review-header-paths-2.md): Review: header-paths (PR #96), round 2
- [review-hotfix7.md](revamp/r3/review-hotfix7.md): Review: hotfix-generic-payload (v0.2.1 candidate)
- [review-ignored-bang-2.md](revamp/r3/review-ignored-bang-2.md): Re-review: `ignored-bang` at a4325ccb (merges main 1d356a09)
- [review-ignored-bang-3.md](revamp/r3/review-ignored-bang-3.md): Review 3: ignored-bang at d4cd3085 (new since a4325ccb)
- [review-ignored-bang-4.md](revamp/r3/review-ignored-bang-4.md): Review 4: ignored-bang fix commits (d4cd3085..309a3e5c)
- [review-ignored-bang.md](revamp/r3/review-ignored-bang.md): Review: `ignored-bang` at 596161e4 (impl da4cf0b3)
- [review-lend-base-1.md](revamp/r3/review-lend-base-1.md): Review: PR #90 `lend-base` (e73f7390 vs main faceba15)
- [review-lend-base-2.md](revamp/r3/review-lend-base-2.md): Review 2: PR #90 `lend-base` (bb46d1a0 vs main faceba15) — PARTIAL
- [review-lend-base-3.md](revamp/r3/review-lend-base-3.md): Review 3: PR #90 `lend-base`, the redesign (f395daef vs main faceba15)
- [review-loop-lowering.md](revamp/r3/review-loop-lowering.md): Review: loop-lowering (head bd04787e)
- [review-move-done-2.md](revamp/r3/review-move-done-2.md): Review round 2: `move-done` at c1a7d3f4 (base c169ec89)
- [review-move-done.md](revamp/r3/review-move-done.md): Review: `move-done` (1738234f, a82ee668) on main c169ec89
- [review-never-data-1.md](revamp/r3/review-never-data-1.md): review-never-data-1: adversarial soundness review of `never-data` (7d224dab vs 0fc49541)
- [review-never-data-2.md](revamp/r3/review-never-data-2.md): review-never-data-2: F1 / F2 fixes at 3fa689e0
- [review-one-decider-2.md](revamp/r3/review-one-decider-2.md): Review: one-decider-2 at 173b6a6e (base main 53cbff4f)
- [review-payload-loan-1.md](revamp/r3/review-payload-loan-1.md): Review 1 of PR #94 (payload-loan), head 310f5ecb, base main 48f20f2a
- [review-payload-loan-2.md](revamp/r3/review-payload-loan-2.md): Review 2 of PR #94 (payload-loan), head 14d85287, base main 48f20f2a
- [review-payload-loan-3.md](revamp/r3/review-payload-loan-3.md): Review 3 of PR #94 (payload-loan), the redesign, head 4fd21fa6, base main 48f20f2a
- [review-payload-loan-4.md](revamp/r3/review-payload-loan-4.md): Review 4 of PR #94 (payload-loan), head d2a437c5, against 4fd21fa6 (base main 48f20f2a)
- [review-payload-loan-5.md](revamp/r3/review-payload-loan-5.md): Review 5 (final) of PR #94 (payload-loan), head d73cebf6, against 48f20f2a
- [review-payload-names.md](revamp/r3/review-payload-names.md): Review: payload-names at bf652b0e
- [review-polish-1.md](revamp/r3/review-polish-1.md): Review: PR #95 `polish` (head aea73c3f, base 48f20f2a), round 1
- [review-polish-2.md](revamp/r3/review-polish-2.md): Review: PR #95 `polish` (head ac9dcd8a), round 2: cache deletion only
- [review-polish-3.md](revamp/r3/review-polish-3.md): Review: PR #95 `polish` (head 48b6db55), round 3: locks, tag, recognizer
- [review-rename-1.md](revamp/r3/review-rename-1.md): Review of PR #109 (rename, 2fbed81c vs 369f1230)
- [review-rules-1.md](revamp/r3/review-rules-1.md): Review of PR #102 (rules), c60184c3 - reviewer 1
- [review-seam2-round2.md](revamp/r3/review-seam2-round2.md): Review: seam2 round 2 (fixes ee6744f9, d723648b, 5ecbb669, c4b5e9f8)
- [review-seam2.md](revamp/r3/review-seam2.md): Review: seam2 (`!` lends any value to write), round 1
- [review-seam2b-fixes.md](revamp/r3/review-seam2b-fixes.md): Review: seam2b fix commits (1f5e16c6, dff5d589, e4e327da, e416deb8)
- [review-seam2b.md](revamp/r3/review-seam2b.md): Review: seam2b (`!` lends any value to write), round 1
- [review-seam3-1.md](revamp/r3/review-seam3-1.md): Review seam3-1: use-after-free hunt in programs PR #104 newly accepts
- [review-seam3-2.md](revamp/r3/review-seam3-2.md): Review seam3-2: is `sema.reachedTypeVars` complete? (head 5f9fb4ff)
- [review-static-2.md](revamp/r3/review-static-2.md): Review of PR #105 (Static), a204f003: can a view of an owner get type Static?
- [review-stdjson.md](revamp/r3/review-stdjson.md): Review: std.json round (`stdjson`, worktree /Users/shreeve/Data/Code/rig-stdjson)
- [review-step1-round2.md](revamp/r3/review-step1-round2.md): Review round 2: REVAMP-3 step 1 fixes (`r3-step1` HEAD `67f88767`)
- [review-step1.md](revamp/r3/review-step1.md): Review: REVAMP-3 step 1, "Type facts" (`485e1a06..r3-step1` = `b7ca0e90`)
- [review-step10-round2.md](revamp/r3/review-step10-round2.md): Review round 2: step 10 storage facts (`r3-step10-facts` at `9594b403`)
- [review-step10.md](revamp/r3/review-step10.md): Review: REVAMP-3 step 10 storage facts (`r3-step10-facts` at `144dd575`)
- [review-step2.md](revamp/r3/review-step2.md): REVAMP-3 review: HANDOFF step 2, "One classifier and one exit"
- [review-step3-round2.md](revamp/r3/review-step3-round2.md): Review round 2: REVAMP-3 step 3 fixes (`r3-step3` HEAD `58250e50`)
- [review-step3.md](revamp/r3/review-step3.md): Review: REVAMP-3 step 3, "Reads and lends" (`r3-step3`, `911d91c0..5e38370e`)
- [review-step45-round2.md](revamp/r3/review-step45-round2.md): Review round 2: REVAMP-3 steps 4 and 5 fixes (`r3-step45` at `a2e72ce8`)
- [review-step45.md](revamp/r3/review-step45.md): Review: REVAMP-3 steps 4 and 5 (`r3-step45` at `3098df0f`)
- [review-step6.md](revamp/r3/review-step6.md): Review: REVAMP-3 step 6, result origins (`r3-step6` at `24b9759b`)
- [review-syntax-a-1.md](revamp/r3/review-syntax-a-1.md): Review: PR #92 `syntax-a` (head c755b7c0, base main c7085d43)
- [review-syntax-a-2.md](revamp/r3/review-syntax-a-2.md): Review: PR #92 `syntax-a`, round 2 (c755b7c0..689d9ddc)
- [review-syntax-b-1.md](revamp/r3/review-syntax-b-1.md): Review syntax-b, round 1 (PR #93, head 4d8cb4a8, base main 79768d0b)
- [review-syntax-b-2.md](revamp/r3/review-syntax-b-2.md): Review syntax-b, round 2 (PR #93, head 15b151da, base main 79768d0b)
- [review-test-infra-fixes.md](revamp/r3/review-test-infra-fixes.md): Re-review: `test-infra` fix commits (48e8ab77..93411ac1, diff 48e8ab77..09595e0f)
- [review-test-infra.md](revamp/r3/review-test-infra.md): Review: branch `test-infra` (48e8ab77, 6 commits over main 0cbf7e7a)
- [review-v022.md](revamp/r3/review-v022.md): Review: seam2-hotfixes, the v0.2.2 candidate
- [review-view-payload.md](revamp/r3/review-view-payload.md): Review: fix-view-payload-match (f5b0d00d), fast gate
- [review-while-step-2.md](revamp/r3/review-while-step-2.md): Review 2: while-step-hotfix (fix 955fa5c6)
- [review-while-step.md](revamp/r3/review-while-step.md): Review: while-step-hotfix
- [riff-templates.md](revamp/r3/riff-templates.md): Riff: string templates, "show the expression", and the inline wrap
- [rig-questions.md](revamp/r3/rig-questions.md): Open questions for the Rig session (design owner), REVAMP-3
- [round1-nexus-sync.diff](revamp/r3/round1-nexus-sync.diff)
- [round1-report.md](revamp/r3/round1-report.md): Round 1 — R + F + 0: rendering, flushing, `warn` and `panic`
- [round1-review.md](revamp/r3/round1-review.md): PR #292 review, round 1 (head 82ff55a6e)
- [simd64-overflow-report.md](revamp/r3/simd64-overflow-report.md): aarch64: vector `uadd.with.overflow` reports overflow where there is none when the sum is also used (32+ byte lanes)
- [stack-overflow-report.md](revamp/r3/stack-overflow-report.md): stack_overflow_recursion exit 139 (release, Linux x86_64)
- [step1-carveout.md](revamp/r3/step1-carveout.md): Step 1 carve-out: stopping 1.5 (in-place views), and what that does to 1.6
- [study-mutation-never-data.md](revamp/r3/study-mutation-never-data.md): Study: "mutation is never data"
- [study-prefix-xor.md](revamp/r3/study-prefix-xor.md): Study: the in-string mask (prefix XOR) on x86 and arm64, 2026-10-15
- [study-write-view-bindings.md](revamp/r3/study-write-view-bindings.md): Study: write views held in bindings (rules 3 and 4)
- [survey-move-done.md](revamp/r3/survey-move-done.md): Survey: `<` on a place that is neither ended nor emptied (move-done)
- [survey-move-done.tsv](revamp/r3/survey-move-done.tsv)
- [syntax-a-resume.md](revamp/r3/syntax-a-resume.md): syntax-a: resume here
- [templates-design.md](revamp/r3/templates-design.md): Backtick templates: how not to screw it up
- [terminology-guide.md](revamp/r3/terminology-guide.md): Terminology guide: lend, view, loan (REVAMP-3, HANDOFF step 7)
- [text-api-final.md](revamp/r3/text-api-final.md): Rig text API: the owner's final, consolidated (2026-10-13, via Trig)
- [where.sh](revamp/r3/where.sh)
- [zig-audit.md](revamp/r3/zig-audit.md): Zig 0.17 audit of the Zig that Rig owns
- [zig-guide-addendum.md](revamp/r3/zig-guide-addendum.md): 4.3 Folding and wrapping traps for code that generates Zig (silent or surprising)

### revamp/r3/cell-mark/

- [rewrite.py](revamp/r3/cell-mark/rewrite.py)

### revamp/r3/decide/

- [rewrite.py](revamp/r3/decide/rewrite.py)

### revamp/r3/errors/

- [bench2.sh](revamp/r3/errors/bench2.sh)

### revamp/r3/errors-panel/

- [1-languages.md](revamp/r3/errors-panel/1-languages.md): Errors that carry data: a languages survey, and the approved design measured against it
- [2-backend.md](revamp/r3/errors-panel/2-backend.md): Errors that carry data: the backend view (panel expert 2)
- [3-ownership.md](revamp/r3/errors-panel/3-ownership.md): Expert 3: ownership and real error use
- [4-review.md](revamp/r3/errors-panel/4-review.md): Review 4: an adversarial read of errors-spec.md
- [README.md](revamp/r3/errors-panel/README.md): Errors with data: panel and SPEC
- [errors-spec.md](revamp/r3/errors-panel/errors-spec.md): Errors that carry data: the SPEC

### revamp/r3/held/

- [0001-Search-std.sort-and-std.slices-for-a-view-of-the-val.patch](revamp/r3/held/0001-Search-std.sort-and-std.slices-for-a-view-of-the-val.patch)
- [0002-Move-a-loop-local-name-out-with-a-bare-break.patch](revamp/r3/held/0002-Move-a-loop-local-name-out-with-a-bare-break.patch)
- [0003-Release-a-view-field-s-old-loans-when-it-is-pointed-.patch](revamp/r3/held/0003-Release-a-view-field-s-old-loans-when-it-is-pointed-.patch)

### revamp/r3/json-tools/

- [colon.patch.md](revamp/r3/json-tools/colon.patch.md): colon: the `:` after a key decided with one read (std.json experiment, 2026-10-16)
- [make_wsspec.py](revamp/r3/json-tools/make_wsspec.py)

### revamp/r3/logs/

- [fieldloans-burst-matrix2.log](revamp/r3/logs/fieldloans-burst-matrix2.log)

### revamp/r3/objchain/

- [bulk.py](revamp/r3/objchain/bulk.py)
- [bulk2.py](revamp/r3/objchain/bulk2.py)
- [compare_rewrite.py](revamp/r3/objchain/compare_rewrite.py)
- [dockeys.py](revamp/r3/objchain/dockeys.py)

### revamp/r3/origins/

- [fit.md](revamp/r3/origins/fit.md): Origins: fit with Rig and its users
- [formal.md](revamp/r3/origins/formal.md): Origins: the formal model and Rust parity
- [impl.md](revamp/r3/origins/impl.md): Origins: the implementation plan
- [prior-art.md](revamp/r3/origins/prior-art.md): Origins: prior art
- [red-team.md](revamp/r3/origins/red-team.md): Origins: red team
- [synthesis-power.md](revamp/r3/origins/synthesis-power.md): Origins: the recommended design (synthesis, power lens)
- [synthesis-simplicity.md](revamp/r3/origins/synthesis-simplicity.md): Origins: one recommended design (synthesis, simplicity lens)

### revamp/r3/origins/probes-impl/

- [proto-inferred.diff](revamp/r3/origins/probes-impl/proto-inferred.diff)

### revamp/r3/parity/

- [BRIEF.md](revamp/r3/parity/BRIEF.md): Parity panel brief: what Rig needs to be on par with Rust
- [concurrency.md](revamp/r3/parity/concurrency.md): concurrency
- [formal-methods.md](revamp/r3/parity/formal-methods.md): formal-methods
- [rust-soundness.md](revamp/r3/parity/rust-soundness.md): rust-soundness
- [simplicity-assurance.md](revamp/r3/parity/simplicity-assurance.md): simplicity-assurance
- [systems-ffi.md](revamp/r3/parity/systems-ffi.md): systems-ffi
- [types-traits.md](revamp/r3/parity/types-traits.md): types-traits

### revamp/r3/polish/

- [rewrite.py](revamp/r3/polish/rewrite.py)

### revamp/r3/rename/

- [compare_rewrite.py](revamp/r3/rename/compare_rewrite.py)
- [docs_box.py](revamp/r3/rename/docs_box.py)
- [remap_oracle.py](revamp/r3/rename/remap_oracle.py)
- [rewrite.py](revamp/r3/rename/rewrite.py)
- [tagrename.py](revamp/r3/rename/tagrename.py)

### revamp/r3/rev147/

- [pupcmd.sh](revamp/r3/rev147/pupcmd.sh)

### revamp/r3/review-fold-2-probes/

- [run.sh](revamp/r3/review-fold-2-probes/run.sh)

### revamp/r3/review-for-iter-1-probes/

- [head_b.txt](revamp/r3/review-for-iter-1-probes/head_b.txt)

### revamp/r3/review-header-paths-1-probes/grid1/

- [results.log](revamp/r3/review-header-paths-1-probes/grid1/results.log)

### revamp/r3/review-header-paths-1-probes/grid2/

- [results.log](revamp/r3/review-header-paths-1-probes/grid2/results.log)

### revamp/r3/review-header-paths-1-probes/tools/

- [batch.sh](revamp/r3/review-header-paths-1-probes/tools/batch.sh)
- [gen.py](revamp/r3/review-header-paths-1-probes/tools/gen.py)
- [gen2.py](revamp/r3/review-header-paths-1-probes/tools/gen2.py)
- [one.sh](revamp/r3/review-header-paths-1-probes/tools/one.sh)
- [oracle-narrow-receiver-own-lend.diff](revamp/r3/review-header-paths-1-probes/tools/oracle-narrow-receiver-own-lend.diff)
- [oracle_all.sh](revamp/r3/review-header-paths-1-probes/tools/oracle_all.sh)
- [oracle_recv.sh](revamp/r3/review-header-paths-1-probes/tools/oracle_recv.sh)
- [p.sh](revamp/r3/review-header-paths-1-probes/tools/p.sh)
- [recv_files.txt](revamp/r3/review-header-paths-1-probes/tools/recv_files.txt)

### revamp/r3/review-lend-base-2-probes/

- [chk.sh](revamp/r3/review-lend-base-2-probes/chk.sh)
- [gen.py](revamp/r3/review-lend-base-2-probes/gen.py)
- [hint.gen.txt](revamp/r3/review-lend-base-2-probes/hint.gen.txt)
- [probe.sh](revamp/r3/review-lend-base-2-probes/probe.sh)
- [run1.sh](revamp/r3/review-lend-base-2-probes/run1.sh)
- [runall.sh](revamp/r3/review-lend-base-2-probes/runall.sh)

### revamp/r3/review-lend-base-3-probes/

- [hint.py](revamp/r3/review-lend-base-3-probes/hint.py)
- [probe.sh](revamp/r3/review-lend-base-3-probes/probe.sh)

### revamp/r3/review-lend-base-3-probes/s/

- [list.txt](revamp/r3/review-lend-base-3-probes/s/list.txt)

### revamp/r3/review-payload-loan-1-probes/

- [probe.sh](revamp/r3/review-payload-loan-1-probes/probe.sh)

### revamp/r3/review-payload-loan-2-probes/

- [probe.sh](revamp/r3/review-payload-loan-2-probes/probe.sh)
- [results.txt](revamp/r3/review-payload-loan-2-probes/results.txt)

### revamp/r3/review-payload-loan-4-probes/

- [probe.sh](revamp/r3/review-payload-loan-4-probes/probe.sh)
- [results.txt](revamp/r3/review-payload-loan-4-probes/results.txt)

### revamp/r3/review-payload-loan-5-probes/

- [probe.sh](revamp/r3/review-payload-loan-5-probes/probe.sh)
- [results.txt](revamp/r3/review-payload-loan-5-probes/results.txt)

### revamp/r3/review-payload-loan-5-probes/equiv30/

- [results.txt](revamp/r3/review-payload-loan-5-probes/equiv30/results.txt)

### revamp/r3/review-payload-loan-5-probes/gen/

- [acc.sh](revamp/r3/review-payload-loan-5-probes/gen/acc.sh)
- [g1.py](revamp/r3/review-payload-loan-5-probes/gen/g1.py)
- [g2.py](revamp/r3/review-payload-loan-5-probes/gen/g2.py)
- [g3.py](revamp/r3/review-payload-loan-5-probes/gen/g3.py)
- [g4.py](revamp/r3/review-payload-loan-5-probes/gen/g4.py)
- [g5.py](revamp/r3/review-payload-loan-5-probes/gen/g5.py)
- [g6.py](revamp/r3/review-payload-loan-5-probes/gen/g6.py)
- [g7.py](revamp/r3/review-payload-loan-5-probes/gen/g7.py)
- [g8.py](revamp/r3/review-payload-loan-5-probes/gen/g8.py)

### revamp/r3/review-seam3-1-probes/

- [SUMMARY.txt](revamp/r3/review-seam3-1-probes/SUMMARY.txt)

### revamp/r3/review-syntax-b-2-probes/

- [trial-fixes.diff](revamp/r3/review-syntax-b-2-probes/trial-fixes.diff)

### revamp/r3/revsimd2/

- [rw_end_grid_gen.py](revamp/r3/revsimd2/rw_end_grid_gen.py)

### revamp/r3/rules/

- [rewrite.py](revamp/r3/rules/rewrite.py)

### revamp/r3/sigil-test/

- [lengths.txt](revamp/r3/sigil-test/lengths.txt)
- [reader-questions.md](revamp/r3/sigil-test/reader-questions.md): Reading questions
- [translate.py](revamp/r3/sigil-test/translate.py)

### revamp/r3/sigil-test/cheatsheets/

- [A.md](revamp/r3/sigil-test/cheatsheets/A.md): Rig on one page
- [B.md](revamp/r3/sigil-test/cheatsheets/B.md): Rig on one page
- [C.md](revamp/r3/sigil-test/cheatsheets/C.md): Rig on one page
- [D.md](revamp/r3/sigil-test/cheatsheets/D.md): Rig on one page

### revamp/r3/sigil-test/key/

- [questions.md](revamp/r3/sigil-test/key/questions.md): Reading questions and answer key
- [writing-solutions.md](revamp/r3/sigil-test/key/writing-solutions.md): Writing tasks: solutions (variant A)

### revamp/r3/sigil-test/results/

- [GRADES.md](revamp/r3/sigil-test/results/GRADES.md): Sigil usability test: grades
- [read-A1.md](revamp/r3/sigil-test/results/read-A1.md): Answers
- [read-A2.md](revamp/r3/sigil-test/results/read-A2.md): Answers
- [read-B1.md](revamp/r3/sigil-test/results/read-B1.md): Answers
- [read-B2.md](revamp/r3/sigil-test/results/read-B2.md): Answers
- [read-C1.md](revamp/r3/sigil-test/results/read-C1.md): Answers
- [read-C2.md](revamp/r3/sigil-test/results/read-C2.md): Answers
- [read-D1.md](revamp/r3/sigil-test/results/read-D1.md): Answers
- [read-D2.md](revamp/r3/sigil-test/results/read-D2.md): Answers

### revamp/r3/sigil-test/results/write-A/

- [notes.md](revamp/r3/sigil-test/results/write-A/notes.md): Notes

### revamp/r3/sigil-test/results/write-B/

- [notes.md](revamp/r3/sigil-test/results/write-B/notes.md): Notes

### revamp/r3/sigil-test/results/write-C/

- [notes.md](revamp/r3/sigil-test/results/write-C/notes.md): Notes

### revamp/r3/sigil-test/results/write-D/

- [notes.md](revamp/r3/sigil-test/results/write-D/notes.md): Notes

### revamp/r3/sigil-test/results-clean/

- [GRADES.md](revamp/r3/sigil-test/results-clean/GRADES.md): Grades: clean no-guide test, variants A and D
- [clean-A-fable.md](revamp/r3/sigil-test/results-clean/clean-A-fable.md): Rig reading report
- [clean-A-haiku.md](revamp/r3/sigil-test/results-clean/clean-A-haiku.md): First guesses
- [clean-A-opus.md](revamp/r3/sigil-test/results-clean/clean-A-opus.md): Rig reading exercise
- [clean-A-sonnet.md](revamp/r3/sigil-test/results-clean/clean-A-sonnet.md): Rig: reading it cold
- [clean-D-fable.md](revamp/r3/sigil-test/results-clean/clean-D-fable.md): Rig: reading cold
- [clean-D-haiku.md](revamp/r3/sigil-test/results-clean/clean-D-haiku.md): Step 1: First guesses
- [clean-D-opus.md](revamp/r3/sigil-test/results-clean/clean-D-opus.md): Rig: first guesses, answers to the reading questions, and revised meanings
- [clean-D-sonnet.md](revamp/r3/sigil-test/results-clean/clean-D-sonnet.md): Rig: first-contact read
- [prompt.txt](revamp/r3/sigil-test/results-clean/prompt.txt)
- [prompt2.txt](revamp/r3/sigil-test/results-clean/prompt2.txt)

### revamp/r3/sigil-test/results-cold/

- [GRADES.md](revamp/r3/sigil-test/results-cold/GRADES.md): Cold sigil test: grades
- [cold-Ah.md](revamp/r3/sigil-test/results-cold/cold-Ah.md): Cold reading of Rig sigils: answers
- [cold-Ao.md](revamp/r3/sigil-test/results-cold/cold-Ao.md): Answers
- [cold-As.md](revamp/r3/sigil-test/results-cold/cold-As.md): Cold reading of Rig (set A)
- [cold-Dh.md](revamp/r3/sigil-test/results-cold/cold-Dh.md): Cold reading of Rig sigils: answers
- [cold-Do.md](revamp/r3/sigil-test/results-cold/cold-Do.md): Answers
- [cold-Ds.md](revamp/r3/sigil-test/results-cold/cold-Ds.md): Cold reading of Rig

### revamp/r3/sigil-test/writing/

- [tasks.md](revamp/r3/sigil-test/writing/tasks.md): Writing tasks

### revamp/r3/speed/

- [brief.md](revamp/r3/speed/brief.md): Brief: how do we iterate on Rig much faster?
- [infra.md](revamp/r3/speed/infra.md): infra: make verification much faster without weakening it
- [process.md](revamp/r3/speed/process.md): Speed: the process and the plan ("process")
- [timeline.md](revamp/r3/speed/timeline.md): timeline: where the wall-clock time goes

### revamp/r3/step10/

- [design.md](revamp/r3/step10/design.md): Step 10: one lowering for the checker and the emitter (design study)

### revamp/r3/study-write-view-bindings/

- [analyze.py](revamp/r3/study-write-view-bindings/analyze.py)
- [bugs.md](revamp/r3/study-write-view-bindings/bugs.md)
- [bugs.py](revamp/r3/study-write-view-bindings/bugs.py)
- [extract_docs.sh](revamp/r3/study-write-view-bindings/extract_docs.sh)
- [fallout.md](revamp/r3/study-write-view-bindings/fallout.md): Fallout: programs accepted on main that each config rejects
- [findings2.py](revamp/r3/study-write-view-bindings/findings2.py)
- [gen_matrix.py](revamp/r3/study-write-view-bindings/gen_matrix.py)
- [groups.json](revamp/r3/study-write-view-bindings/groups.json)
- [instrumentation.diff](revamp/r3/study-write-view-bindings/instrumentation.diff)
- [run_all.sh](revamp/r3/study-write-view-bindings/run_all.sh)
- [sites.md](revamp/r3/study-write-view-bindings/sites.md)
- [sites.py](revamp/r3/study-write-view-bindings/sites.py)
- [sweep.py](revamp/r3/study-write-view-bindings/sweep.py)

### revamp/r3/syntax-input/

- [RIG-SYNTAX.md](revamp/r3/syntax-input/RIG-SYNTAX.md): Rig spelling for Trig

### revamp/r3/syntax-input/rig-syntax/

- [README.md](revamp/r3/syntax-input/rig-syntax/README.md): Rig syntax: ideas from Trig, deferred
- [RIG-SYNTAX-OPTIONS.md](revamp/r3/syntax-input/rig-syntax/RIG-SYNTAX-OPTIONS.md): Rig syntax options: guards, conditionals, and how much freedom
- [RUBY-IDIOMS.md](revamp/r3/syntax-input/rig-syntax/RUBY-IDIOMS.md): The owner's Ruby, said in Rig

### revamp/r3/traits-map-probes/

- [run.sh](revamp/r3/traits-map-probes/run.sh)

### revamp/r3/widemasks/

- [inter.py](revamp/r3/widemasks/inter.py)
- [mac-build.sh](revamp/r3/widemasks/mac-build.sh)
- [mac-time.log](revamp/r3/widemasks/mac-time.log)
- [mac-time.py](revamp/r3/widemasks/mac-time.py)
- [pup-build.sh](revamp/r3/widemasks/pup-build.sh)
- [pup-time.sh](revamp/r3/widemasks/pup-time.sh)

### revamp/reports/

- [SPEC.full.md](revamp/reports/SPEC.full.md): The Rig Language Reference
- [addpub.py](revamp/reports/addpub.py)
- [alldiff.sh](revamp/reports/alldiff.sh)
- [bench.sh](revamp/reports/bench.sh)
- [chk.sh](revamp/reports/chk.sh)
- [cmp.sh](revamp/reports/cmp.sh)
- [dead.py](revamp/reports/dead.py)
- [loc.py](revamp/reports/loc.py)
- [parenify.py](revamp/reports/parenify.py)
- [pr.md](revamp/reports/pr.md): Correctness
- [pr11.md](revamp/reports/pr11.md): Language
- [pr12.md](revamp/reports/pr12.md): Language
- [pr13.md](revamp/reports/pr13.md): Language
- [pr14.md](revamp/reports/pr14.md): Language
- [pr15.md](revamp/reports/pr15.md): Language
- [pr16.md](revamp/reports/pr16.md): Language
- [pr17.md](revamp/reports/pr17.md): The rule
- [pr26.md](revamp/reports/pr26.md): Language
- [pr27.md](revamp/reports/pr27.md): Changes
- [pr28.md](revamp/reports/pr28.md): Each error belongs to its set
- [pr29.md](revamp/reports/pr29.md): The bug
- [pr30.md](revamp/reports/pr30.md): Mechanism
- [pr9.md](revamp/reports/pr9.md): Language
- [scan.sh](revamp/reports/scan.sh)
- [verify.py](revamp/reports/verify.py)

### revamp/reports/R11a/

- [r.sh](revamp/reports/R11a/r.sh)

### revamp/reports/R11b/

- [fuzz.py](revamp/reports/R11b/fuzz.py)
- [fuzz1.py](revamp/reports/R11b/fuzz1.py)
- [t.sh](revamp/reports/R11b/t.sh)

### revamp/reports/R11b/perf/

- [gen.py](revamp/reports/R11b/perf/gen.py)

### revamp/reports/R11b/repro/F2_selfnesting_cubic/

- [gen.py](revamp/reports/R11b/repro/F2_selfnesting_cubic/gen.py)

### revamp/reports/R13/

- [fuzz.py](revamp/reports/R13/fuzz.py)
- [r.sh](revamp/reports/R13/r.sh)
- [rfuzz.py](revamp/reports/R13/rfuzz.py)
- [tfuzz.py](revamp/reports/R13/tfuzz.py)

### revamp/reports/R15/

- [fuzz.py](revamp/reports/R15/fuzz.py)
- [sfuzz.py](revamp/reports/R15/sfuzz.py)
- [t.sh](revamp/reports/R15/t.sh)

### revamp/reports/R16/

- [t.sh](revamp/reports/R16/t.sh)
- [tm.sh](revamp/reports/R16/tm.sh)

### revamp/reports/R3c1/

- [r.sh](revamp/reports/R3c1/r.sh)
- [rm.sh](revamp/reports/R3c1/rm.sh)

### revamp/reports/audit-docs/

- [links.py](revamp/reports/audit-docs/links.py)
- [notes.md](revamp/reports/audit-docs/notes.md): notes

### revamp/reports/audit-docs/p/

- [run.sh](revamp/reports/audit-docs/p/run.sh)

### revamp/reports/audit-emit/

- [cmp.sh](revamp/reports/audit-emit/cmp.sh)
- [t.sh](revamp/reports/audit-emit/t.sh)
- [zr.sh](revamp/reports/audit-emit/zr.sh)

### revamp/reports/audit-frontend/

- [p.sh](revamp/reports/audit-frontend/p.sh)

### revamp/reports/audit-fuzz/

- [casepack.py](revamp/reports/audit-fuzz/casepack.py)
- [fuzz_parse.py](revamp/reports/audit-fuzz/fuzz_parse.py)
- [gen_cf.py](revamp/reports/audit-fuzz/gen_cf.py)
- [gen_ctx.py](revamp/reports/audit-fuzz/gen_ctx.py)
- [gen_feat.py](revamp/reports/audit-fuzz/gen_feat.py)
- [gen_gen.py](revamp/reports/audit-fuzz/gen_gen.py)
- [gen_int.py](revamp/reports/audit-fuzz/gen_int.py)
- [gen_lit.py](revamp/reports/audit-fuzz/gen_lit.py)
- [gen_mod.py](revamp/reports/audit-fuzz/gen_mod.py)
- [gen_ovf.py](revamp/reports/audit-fuzz/gen_ovf.py)
- [gen_own.py](revamp/reports/audit-fuzz/gen_own.py)
- [gen_tmp.py](revamp/reports/audit-fuzz/gen_tmp.py)
- [harness.py](revamp/reports/audit-fuzz/harness.py)
- [runq.sh](revamp/reports/audit-fuzz/runq.sh)
- [split.py](revamp/reports/audit-fuzz/split.py)
- [summ.py](revamp/reports/audit-fuzz/summ.py)

### revamp/reports/audit-ownership/

- [gen_perf.py](revamp/reports/audit-ownership/gen_perf.py)
- [gen_perf2.py](revamp/reports/audit-ownership/gen_perf2.py)
- [gen_perf3.py](revamp/reports/audit-ownership/gen_perf3.py)
- [t.sh](revamp/reports/audit-ownership/t.sh)
- [t1.sh](revamp/reports/audit-ownership/t1.sh)

### revamp/reports/audit-tests/

- [cov.sh](revamp/reports/audit-tests/cov.sh)
- [gen.py](revamp/reports/audit-tests/gen.py)

### revamp/reports/core-audit/

- [CORE.md](revamp/reports/core-audit/CORE.md): Rig Core (draft for review)
- [WORK-ORDER.md](revamp/reports/core-audit/WORK-ORDER.md): Realizing the Rig Core: gap map and work order
- [containers.md](revamp/reports/core-audit/containers.md): Core audit: containers, assignment, and the standard library
- [docs.md](revamp/reports/core-audit/docs.md): Core audit: documents against the Core
- [emit.md](revamp/reports/core-audit/emit.md): Core audit: failure, syntax outside the core, and emit honesty
- [kinds.md](revamp/reports/core-audit/kinds.md): Core audit: value kinds and type facts
- [loans.md](revamp/reports/core-audit/loans.md): Core audit: loans, control flow, shared storage
- [reads.md](revamp/reports/core-audit/reads.md): Core audit: reads, lends, and temporaries

### revamp/reports/core-audit/probes/docs/

- [results-main.txt](revamp/reports/core-audit/probes/docs/results-main.txt)
- [results-rig-text.txt](revamp/reports/core-audit/probes/docs/results-rig-text.txt)

### revamp/reports/core-audit/probes/emit/

- [proto-d3-d6-newly-rejected.txt](revamp/reports/core-audit/probes/emit/proto-d3-d6-newly-rejected.txt)
- [proto-d3-d6.diff](revamp/reports/core-audit/probes/emit/proto-d3-d6.diff)
- [run.sh](revamp/reports/core-audit/probes/emit/run.sh)

### revamp/reports/core-audit/probes/emit/speed/

- [bench.py](revamp/reports/core-audit/probes/emit/speed/bench.py)
- [prof-debug-head.txt](revamp/reports/core-audit/probes/emit/speed/prof-debug-head.txt)
- [synth.py](revamp/reports/core-audit/probes/emit/speed/synth.py)
- [timer.patch](revamp/reports/core-audit/probes/emit/speed/timer.patch)

### revamp/reports/core-audit/probes/kinds/

- [run.sh](revamp/reports/core-audit/probes/kinds/run.sh)

### revamp/reports/core-audit/probes/loans/

- [results-check-main.txt](revamp/reports/core-audit/probes/loans/results-check-main.txt)
- [results-check-rig-text.txt](revamp/reports/core-audit/probes/loans/results-check-rig-text.txt)

### revamp/reports/core-audit/probes/reads/

- [results.txt](revamp/reports/core-audit/probes/reads/results.txt)
- [run.sh](revamp/reports/core-audit/probes/reads/run.sh)

### revamp/reports/docs/

- [SPEC.orig.md](revamp/reports/docs/SPEC.orig.md): The Rig Language Reference
- [SYNTAX.orig.md](revamp/reports/docs/SYNTAX.orig.md): Rig Syntax: A Guide for Zig and Rust Programmers
- [blocks.py](revamp/reports/docs/blocks.py)
- [links.py](revamp/reports/docs/links.py)
- [t.sh](revamp/reports/docs/t.sh)

### revamp/reports/docs/ed/

- [apply.py](revamp/reports/docs/ed/apply.py)
- [renum.py](revamp/reports/docs/ed/renum.py)
- [spec1.py](revamp/reports/docs/ed/spec1.py)
- [spec2.py](revamp/reports/docs/ed/spec2.py)
- [spec3.py](revamp/reports/docs/ed/spec3.py)
- [spec4.py](revamp/reports/docs/ed/spec4.py)
- [spec5.py](revamp/reports/docs/ed/spec5.py)
- [spec6.py](revamp/reports/docs/ed/spec6.py)
- [spec7.py](revamp/reports/docs/ed/spec7.py)
- [spec8.py](revamp/reports/docs/ed/spec8.py)
- [spec9.py](revamp/reports/docs/ed/spec9.py)

### revamp/reports/docs/probes/rm/

- [p.sh](revamp/reports/docs/probes/rm/p.sh)
- [p2.sh](revamp/reports/docs/probes/rm/p2.sh)
- [p3.sh](revamp/reports/docs/probes/rm/p3.sh)

### revamp/reports/fe/t/

- [f6.sh](revamp/reports/fe/t/f6.sh)

### revamp/reports/fix/

- [stage.py](revamp/reports/fix/stage.py)

### revamp/reports/fix11/

- [runone.sh](revamp/reports/fix11/runone.sh)

### revamp/reports/mig/

- [fix_md.py](revamp/reports/mig/fix_md.py)
- [fix_rig.py](revamp/reports/mig/fix_rig.py)

### revamp/reports/own/

- [t1.sh](revamp/reports/own/t1.sh)

### revamp/reports/purity/

- [designer.md](revamp/reports/purity/designer.md): Rig: a designer's review for consistency, symmetry, and completeness
- [newbie.md](revamp/reports/purity/newbie.md): Rig through a newcomer's eyes
- [principles.md](revamp/reports/purity/principles.md): Rig principles audit: did the sigils hold?
- [rustzig.md](revamp/reports/purity/rustzig.md): Rig through Rust and Zig eyes

### revamp/reports/purity/newbie/

- [log.md](revamp/reports/purity/newbie/log.md): Newcomer error log

### revamp/reports/review-errors/

- [p.sh](revamp/reports/review-errors/p.sh)

### revamp/reports/review-lang4/

- [r.sh](revamp/reports/review-lang4/r.sh)

### revamp/reports/review-place/

- [cmp.sh](revamp/reports/review-place/cmp.sh)
- [run1.sh](revamp/reports/review-place/run1.sh)
- [runacc.sh](revamp/reports/review-place/runacc.sh)
- [split.sh](revamp/reports/review-place/split.sh)

### revamp/reports/review-revamp-checkers/

- [cmp.sh](revamp/reports/review-revamp-checkers/cmp.sh)

### revamp/reports/review-revamp-rest/mut/

- [acc.py](revamp/reports/review-revamp-rest/mut/acc.py)
- [acc2.py](revamp/reports/review-revamp-rest/mut/acc2.py)
- [crash.py](revamp/reports/review-revamp-rest/mut/crash.py)
- [mut.py](revamp/reports/review-revamp-rest/mut/mut.py)
- [mut2.py](revamp/reports/review-revamp-rest/mut/mut2.py)

### revamp/reports/review-sc5/

- [both.sh](revamp/reports/review-sc5/both.sh)

### revamp/reports/review-sc5/fuzz/

- [gen.py](revamp/reports/review-sc5/fuzz/gen.py)
- [num.py](revamp/reports/review-sc5/fuzz/num.py)
- [num2.py](revamp/reports/review-sc5/fuzz/num2.py)
- [num3.py](revamp/reports/review-sc5/fuzz/num3.py)

### revamp/reports/review-std/

- [r.sh](revamp/reports/review-std/r.sh)
- [x.sh](revamp/reports/review-std/x.sh)

### revamp/reports/review-subctor/

- [r.sh](revamp/reports/review-subctor/r.sh)

### revamp/reports/review-take/

- [r.sh](revamp/reports/review-take/r.sh)

### revamp/reports/review-text/

- [run.sh](revamp/reports/review-text/run.sh)

### revamp/reports/review-text2/

- [run.sh](revamp/reports/review-text2/run.sh)

### revamp/reports/review-text3/

- [run.sh](revamp/reports/review-text3/run.sh)

### revamp/reports/review-text4/

- [cmp.sh](revamp/reports/review-text4/cmp.sh)
- [run.sh](revamp/reports/review-text4/run.sh)

### revamp/reports/rv-sema/

- [hunks.py](revamp/reports/rv-sema/hunks.py)

### revamp/reports/rvtests/

- [base_cli1.tsv](revamp/reports/rvtests/base_cli1.tsv)
- [base_cli2.tsv](revamp/reports/rvtests/base_cli2.tsv)
- [base_cold.tsv](revamp/reports/rvtests/base_cold.tsv)
- [base_warm.tsv](revamp/reports/rvtests/base_warm.tsv)
- [pin.py](revamp/reports/rvtests/pin.py)

### revamp/reports/sb/

- [c4a.py](revamp/reports/sb/c4a.py)
- [c4b.py](revamp/reports/sb/c4b.py)
- [d5.py](revamp/reports/sb/d5.py)
- [docs3.py](revamp/reports/sb/docs3.py)
- [docs4.py](revamp/reports/sb/docs4.py)
- [i5.py](revamp/reports/sb/i5.py)
- [probe.sh](revamp/reports/sb/probe.sh)

### revamp/reports/sc2/

- [classify.py](revamp/reports/sc2/classify.py)
- [fill.py](revamp/reports/sc2/fill.py)
- [opth.py](revamp/reports/sc2/opth.py)

### revamp/reports/seams/

- [main-sweep.tsv](revamp/reports/seams/main-sweep.tsv)
- [one.sh](revamp/reports/seams/one.sh)
- [root-cause.md](revamp/reports/seams/root-cause.md): Why Rig's recent work keeps producing soundness bugs, and how to stop it
- [strategy.md](revamp/reports/seams/strategy.md): Is there merit in Rig? A strategy review
- [surface.md](revamp/reports/seams/surface.md): Rig's language surface: heartburn, and a path back to a small core
- [temporaries.md](revamp/reports/seams/temporaries.md): Temporaries in Rig: one rule
- [text-sweep.tsv](revamp/reports/seams/text-sweep.tsv)

### revamp/reports/seams/surface/

- [run.sh](revamp/reports/seams/surface/run.sh)

### revamp/reports/split/

- [split.py](revamp/reports/split/split.py)
- [verify.sh](revamp/reports/split/verify.sh)

### revamp/reports/split/out/0/docs/

- [INTERNALS.md](revamp/reports/split/out/0/docs/INTERNALS.md): Rig compiler internals

### revamp/reports/split/out/1/docs/

- [INTERNALS.md](revamp/reports/split/out/1/docs/INTERNALS.md): Rig compiler internals

### revamp/reports/split/out/2/docs/

- [INTERNALS.md](revamp/reports/split/out/2/docs/INTERNALS.md): Rig compiler internals

### revamp/reports/split/out/3/docs/

- [INTERNALS.md](revamp/reports/split/out/3/docs/INTERNALS.md): Rig compiler internals

### revamp/reports/split/out/4/docs/

- [INTERNALS.md](revamp/reports/split/out/4/docs/INTERNALS.md): Rig compiler internals

### revamp/reports/split/out/5/docs/

- [INTERNALS.md](revamp/reports/split/out/5/docs/INTERNALS.md): Rig compiler internals

### revamp/reports/split/out/6/docs/

- [INTERNALS.md](revamp/reports/split/out/6/docs/INTERNALS.md): Rig compiler internals

### revamp/reports/stdlib/

- [fnlen.py](revamp/reports/stdlib/fnlen.py)
- [rig-today.md](revamp/reports/stdlib/rig-today.md): Rig today: the de-facto standard library, and what blocks a real one
- [rust-std.md](revamp/reports/stdlib/rust-std.md): Rust's standard library as a model for Rig's
- [zig-std.md](revamp/reports/stdlib/zig-std.md): Backing Rig's standard library with Zig 0.16 std

### revamp/reports/stdlib/zig/

- [handedit.py](revamp/reports/stdlib/zig/handedit.py)
- [run.sh](revamp/reports/stdlib/zig/run.sh)

### revamp/reports/stdlib/zig/proto/

- [build.sh](revamp/reports/stdlib/zig/proto/build.sh)

### revamp/reports/stdlib/zig/req/

- [handedit.py](revamp/reports/stdlib/zig/req/handedit.py)

### revamp/reports/syntax-review/complete/

- [run.sh](revamp/reports/syntax-review/complete/run.sh)

### revamp/reports/syntax-review/symmetry/

- [probe.sh](revamp/reports/syntax-review/symmetry/probe.sh)

### revamp/reports/t/

- [probe.sh](revamp/reports/t/probe.sh)

### revamp/reports/tc/

- [checkall.sh](revamp/reports/tc/checkall.sh)
- [f01run.py](revamp/reports/tc/f01run.py)
- [stage.py](revamp/reports/tc/stage.py)
