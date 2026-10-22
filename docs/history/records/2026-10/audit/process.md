# Process audit: shreeve/rig PRs #532-#547 (2026-10-22)

Read-only. Sources: `gh pr view/diff` for each PR (#544's diff is over GitHub's 300-file limit; read locally as `963013bfd..86af3b982`), origin/main 9477f3e8d extracted to a scratch dir, records in docs/history/records/. Nothing in any repo was changed (one `git fetch` updated remote refs in ~/Data/Code/rig, which is 17 behind origin/main).

## Verdicts

| Area | Verdict |
|---|---|
| 1. Tests | Clean: no expectation weakened to pass. One probe hollow before and after (#540). One unit test rewritten for an intended behavior change; covers a different property (#541) |
| 2. Failing case first / docs | Clean for all 9 code PRs; #537's CHANGELOG line came later (#544) |
| 3. Perf claims | Measured honestly (interleaved, byte-identical), but 3 headlines are rounded up or not traceable: #536's 3.1%, #538's 1.4-2.9%, #541's "2.0x". The method behind #536's measurement is not recorded |
| 4. Gates | Rig full suite before every merge. Trig gate before merge only for #532 and #542. The batch's merge-before-gate is half recorded. #542 had no second review |
| 5. Vocabulary / attribution | Clean: no "borrow", "receiver", or "struct" for obj; no AI attribution in 30 commits or 16 PR bodies. Bare signed percentages appear in records |
| 6. CHANGELOG / HANDOFF | Mostly true. HANDOFF understates #541's yield loss and leaves out the Trig light gate |

## Problems, ranked

1. **Batch gate record (#535-#541).** ledger.md:175 says "Landed on main (f14b86c58), all gated (Rig full suite; Trig release build + projects byte-identical)". That reads as gated before merge.
   - The owner's rule, ledger.md:188, is "light gate before merge".
   - At merge, the PR bodies of #535, #536, #538, #539 and #541 all show the Trig gate unchecked.
   - Only ledger.md:171 ("Verified after the merge of #535-#541") is accurate. The owner's order to merge first is recorded nowhere.
   - len-and-map-notes.md:73-74 says #538 "merged ... in the coordinator's combined gate", which says the same thing in a softer way.
   - Fix: add one dated line to the ledger: merged on the owner's order before the gate, then verified after.

2. **#542 got no second review.**
   - Review 1 found 4 blockers and 4 majors. Its fixes (4c4f7724f) were never reviewed again, and review-1-fixes.md notes that the first version of fix 2 crashed the compiler.
   - Before #547, HANDOFF said "a second round of such findings stops it for redesign". That implies a second look was planned; #547 replaced the line with "on main".
   - INDEX.md:28 lists only "its first review, and its fixes".
   - No owner approval of the merge is recorded. Every merge shows as `shreeve`, so GitHub cannot tell the owner's merges from an agent's. The standing permission ("review clean") assumes a clean review, and this one was not confirmed clean.
   - Gates were otherwise done: the full suite on the merge (9,656 jobs) and a Trig light gate on 700eb5aaa.
   - Fix: a re-review of 4c4f7724f and the commits after it.

3. **#541 scheduler.**
   - Merged with "pup zig build test", the benchmarks and Trig unchecked in its PR body. The benchmark rows came 18 minutes later (#543). wake-fix.md says pup tests passed but not when.
   - "pup pingpong 2.0x faster" (ledger.md:171) matches no recorded number:
     - the bench row: 6.98 to 4.92 us, 1.42x;
     - unpinned under Trig load: 19.7 to 10.7, 1.84x;
     - a "quiet moment": 11.2 to 5.2, 2.15x.
   - HANDOFF.md:50 calls the loss "yield's few nanoseconds". The rows show:
     - Mac yield 6 to 9 ns (50% slower);
     - pup yield 24 to 27 ns (12% slower);
     - Mac spawn 13% slower;
     - Mac hog 67.5 to 102 us (51% slower), which wake-fix.md's table leaves out. Hog is historically noisy, at 73-112 us.
   - The fork-join unit test (sched.zig:3420) now ticks a yield check every turn:
     - Stronger: it demands real parallelism (the task must see 1000 of the maker's turns).
     - Weaker: it no longer covers a maker that makes no yield check, or the `stealNext` path.
     - This is an intended, disclosed behavior change (CHANGELOG, scheduler.md), not a cheat.

4. **#536's 3.1%.**
   - store-unchecked-ab.txt gives 3.1% only as the mean of times rounded to 2 decimals. Fastest-of-10 gives 3.0%, and cycles 2.8%.
   - The "store" variant (a switch that left stores unchecked by field name, slightly generous) is described in no record. The file has no header naming the variant, machine, or pinning; its first line is a load average of 3.2/7.8/10.5.
   - CHANGELOG.md:231-232 ("On Trig's stores, the same reads without a test made ts-pattern 3.1% faster") does not say it was a proxy measurement or that Trig hasn't migrated. HANDOFF.md:47-48 and ledger.md:181 ("when its stores migrate") do say that Trig hasn't migrated.
   - Speed-feature rule: about 1,600 lines landed on a proxy gain that is not yet realized. The design itself was approved by the owner.
   - The PR left "rig check --time on a quiet machine" undone (1.4% slower on a loaded Mac).

5. **#538's "1.4-2.9% faster"** (INDEX.md:24, ledger.md:183).
   - The range is run 1's times. Run 2 gives 0.8-1.9%.
   - Cycles fell only 0.6-1.2% in run 1, and in run 2 zod3 and tiny-invariant used 0.1-0.2% *more* cycles.
   - Fairer: "1.4-1.8% faster on ts-pattern".
   - The check removal itself is sound: an invariant held by construction, a panic at growth, debug asserts, and new `bomb` cases.

6. **Low.**
   - Bare signed percentages (the "N% faster" rule):
     - "(+0.2%)" at INDEX.md:23 and ledger.md:168;
     - the tables in len-and-map-notes.md (#545, #546).
   - The "tell Nexus" box was left unchecked in #532 and #539 (both change rig.grammar and src/rig.zig). #542 changes both files too, with no box.
   - #540: probe audit-ownership-f08 (probes-05.rig.test:2958) was stopped by an unused-binding error before and by "never called" now. It never reaches the ownership rule it was written for. Add a variant that calls `f()`.
   - HANDOFF.md:23 says "no CI, gates, or required checks" and leaves out the owner's Trig light gate.
   - wake-fix.md points to an experiment tree in a session scratchpad, which will not last.

## Clean

- **Oracle.**
  - #536 and #539 each add 2 lines to test/oracle/rejections and remove none. `coverage` and `differences` are untouched in all 16 PRs.
  - The oracle code changes are justified adaptations:
    - #532 skips compile-time functions, which run in the checker on plain values, and treats `ct_call` as a constant;
    - #539 lowers path captures from CORE section 7 and abstains only on new forms;
    - #542 reads `Fallible.ok`.
- **Existing-test edits, all legitimate.**
  - #532 concurrency-task: 3 messages reworded to "a closure or function lent for a call".
  - #532 modules-imported: still `errors: 2`. The message now spells the field's declared `*fun` type correctly ("an owned closure").
  - #538 emit_shapes: the `rig.len` to `rig.lenOf` rename.
  - #536 _lib.sh: an env var added to the cache key.
  - #540 probe: the new rule's message.
- **Failing cases first:** every code PR names them, and #541's test fails on main (1000-1600 crossings against a bound of 500).
- **Measurements:** interleaved, with output byte-identical in all.
- **Cost claims:**
  - "No run-time cost" for compile-time functions is backed by 7 `code` cases, and the compile-time cost table is honest.
  - "Function values cross at no run-time cost" is a structural claim, not a measured one.
- **#535's benchmark note** declines to misattribute the pingpong slowdown, which led to the bisect.
- **Vocabulary:** the only "struct" hits are Zig code.
