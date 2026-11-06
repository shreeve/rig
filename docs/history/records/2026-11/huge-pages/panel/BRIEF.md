# Panel of 2026-11-06: huge pages and memory performance, Trig against tsrs

The owner asks: how does tsrs (a Rust port of tsgo) get its memory performance, which Trig (a TypeScript checker written in Rig) believes is one of the main reasons tsrs wins? What can Rig do that it hasn't tried? Were the earlier attempts premature, so we should try again now? Or should we try again with an improved approach? "We haven't found anything new" is an acceptable answer, if the evidence supports it.

## What exists (read these first; don't re-propose what's closed without saying what's different)

**Rig.** The repo is ~/Data/Code/rig; read it with `git -C ~/Data/Code/rig show origin/main:PATH`.
- src/alloc.zig, the allocator of release builds: a heap per thread, segments, large blocks, and the huge-page gate `hugeFree` / `hugeFreeFor` / `adviseHuge`, which reads /proc/buddyinfo, with spare 64 and floor 8; also `MADV_NOHUGEPAGE` uses.
- src/table.zig, `reserve`: a `Table[T, n]` reserves a large range and grows into it.
- Records, in docs/history/records/2026-10/perf-stage/:
  - thp-fragmented.md, thp-gate.md, thp-spare.md, table-huge.md (+ table-huge-data/);
  - kernel-time.md, kernel-leads.md, stlb-aliasing.md, table-arena.md, table-reads.md;
  - fault-ahead/, scaling-2.md, startup-15-16.md.
- More records: 2026-10/table-prefault/README.md and docs/history/records/archive-tags.md (every closed attempt).
- The exit panel of yesterday, in 2026-11/panels/exit/: os.md says 60% of tsrs's memory is on 2 MiB pages; the exit is kernel page freeing, 0.09-0.13 ms per resident MiB.
- 2026-11/panels/table-arena/: STLB aliasing; level on P-cores.

**Trig.** At ~/Data/Code/trig (read only).
- docs/RESULTS.md: search "huge", "fault", "tsrs", "RSS", "teardown".
- HANDOFF.md's "To Rig" list: "huge pages for large Tables on a fragmented machine".
- Trig's message today, in short:
  - the old `hugepages` branch was 4-7% faster on five small projects but 13% slower on ts-pattern (360 failed compaction stalls a run);
  - table-prefault's huge-page arm gave 1.2% fewer cycles at one checker but 9% more RSS at four;
  - tsrs's ts-pattern edge moves with pup's huge pages (15.6K against 35.9K faults);
  - exit teardown is 22 ms of ts-pattern's 0.275 s at 8 checkers, against tsrs's 0.229 s.

**tsrs.** At ~/Data/Code/trig/misc/tsrs (read only).
- notes/mem-no-thp.md is the key file:
  - mimalloc v3 is built with `no_thp`, so the heap is not advised;
  - tsrs's own bump arena (`tsrs_core::reserve`) keeps MADV_HUGEPAGE: 2-6% less wall time;
  - `PR_SET_THP_DISABLE` cost 4-10%.
- Also notes/linux-x86-round.md, mem-64.md, mem-linux-residency-32.md, perf-memory-traffic-32.md, and docs/RUST.md.
- The source: crates/tsrs_core (allocator, reserve).
- mimalloc's own source may be in ~/.cargo/registry.

**Machines.**
- pup is the x86-64 Linux race machine: Linux 7.0, THP enabled=madvise and defrag=madvise, khugepaged max_ptes_none 511, compaction_proactiveness 20. Its memory is often fragmented by builds; /proc/buddyinfo often shows 5-69 free 2 MiB blocks. Every timing slot opens with drop_caches + compact_memory. pup is OUT OF REACH today: use the recorded numbers.
- The Mac is Apple Silicon: 16 KiB pages, no THP for user memory.

## Rules (they bind every expert)

- **Honesty.** No gain that only moves cost out of the measured window, games a benchmark, or depends on a machine state a user wouldn't have. Note: compacting before a slot applies to both programs alike.
- **Memory.** The owner's rule is no speed for memory: Trig's peak RSS no higher. Any proposal that raises RSS must say by how much, where and why. The trade is the owner's to decide.
- **Speed bar** on Trig: more than 1.5% faster, or at least 1% fewer instructions on one checker. A gain of 1.5-2% needs 20 interleaved rounds.
- **Measure the share first.** Bound each idea by its target's measured share (kernel cycles, faults, teardown, TLB) before claiming a gain.
- **Read only.**
  - Never edit, branch, commit or fetch in ~/Data/Code/rig, ~/Data/Code/trig or ~/Data/Code/loc.
  - Scratch goes under the panel's scratch folder (not kept).
  - Mac experiments only through `~/Data/Code/rig/tools/low CMD`, after checking that ~/Data/Code/mumps-compare/.mac-quiet doesn't exist.
  - No pup, no burst.
- **Vocabulary:** lend/view/loan, never "borrow"; a Rig `obj` is an "object"; say "N% faster/slower", never bare +/- percentages.

## Output

1. **Full report** to ~/Data/Code/Claude/rig/rig/panels-1106-huge/<lens>.md, with:
   - concrete designs, with the code paths (file:line);
   - each design's expected gain, with its basis, and its RSS cost;
   - the risks;
   - the measurement that would settle it, and its first step (pup when it returns).
2. **Reply to the foreman:** at most 400 words. List each proposal as NEW, RETRY (premature before: say why now), IMPROVED (a better form of a tried idea), or DROP. End with your top recommendation.
