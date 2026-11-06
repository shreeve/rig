# Huge-page panel of 2026-11-06: synthesis

The owner approved these defaults on 2026-11-06 ("Approve the defaults").

Four experts (linux, allocator, macos, critic); the reports are beside this file. Read only; pup was out of reach.

## The owner's questions

- **Are huge pages one of the main reasons tsrs wins?**
  - At one thread, half true. The race is 1.02 (0.97 with signal preemption), while tsrs alone swings 8.6% with pup's huge pages. What remains of the gap is tsrs's luck with the kernel's compactor.
  - At four checkers, false. Huge pages explain about a sixth of the 46 ms gap. Density and file assignment explain more.
- **How tsrs does it.**
  - One 32 GiB reservation with one bump finger per thread. Chunks double from 2 to 64 MiB, each aligned to 2 MiB and advised MADV_HUGEPAGE with no gate.
  - Records of every kind share that one dense range, so tsrs wastes at most one partly used 2 MiB block per thread.
  - Its mimalloc heap is not advised (`no_thp`).
  - On fragmented memory it compacts in the fault. When that fails it is 6% slower: a lottery.
- **Why Rig's tries cost memory.** Trig has about 43 growing Tables per checker, each its own finger. A huge page per partly filled range costs about 1-2 MiB each. No advice policy on today's layout is free in RSS.
- **Were the earlier tries premature?** Not on the kernel side: nothing relevant has landed since Linux 7.0. But every prize number (3.1%, 2.3%, 1.4%, 4.6%) was taken on Trig of late October, so they are stale.
- **Is there a stall-free way past the free blocks?** No, not in Linux 7.0 under defrag=madvise. Fault, populate and collapse all compact. A failed compaction averages 0.7-1.2 ms, with single windows up to 21-84 ms.
- **The Mac** has no user huge pages (superpages unsupported, no contiguous hint), and tsrs gets none there either. Memory costs are 5-8% of Trig's time there, and no piece can be cut by more than about 1%. Exit is 0.011 ms/MiB, against 0.09-0.13 on pup.

## Ranked, with kill thresholds (critic's order)

1. **pup: THP on/off for both programs**, 2x2, 20 interleaved rounds, quiet and natural, core 3 and cores 0-11 with c4.
   - Trig is switched off by a prctl wrapper, tsrs by MIMALLOC_ALLOW_THP=0.
   - Counted: compactions, THP faults, exit, P-core walks, RssAnon.
   - Kill: tsrs gains less than 1.5 points more than Trig at both pins, natural. Then all Table huge-page work stops.
2. **Free: record machine state in every race row** (free 2 MiB blocks, thp_fault_alloc and compact_stall for each program). Slots after compaction have opened at 1, 82 and 270 free blocks, so one-thread ratios aren't comparable across days.
3. **Offline: a census of each Table's density.** Kill D1 if push-dense Tables hold under half of small-page Table memory at c4-8. The same data prices smaller first windows (1 MiB or 512 KiB).
4. **D1: a typed record arena** (one dense range per checker, 32-bit refs, tsrs's layout), only after 1 and 3 pass.
   - Its ceiling is about 3-4% after the share bound.
   - Kill: under 3% faster at c4 or under 1.5% at c1.
   - It needs a CORE change, and a sound design first: a Ref used in another arena must be a type error.
5. **Low: window-at-a-time advice for push-grown Tables.** It needs its own hook, since alloc.zig's populate path never sees Table growth. Kill: under 2% gross, any stall, or more than 0.3% instructions.
6. **Small correctness fixes:**
   - read the THP mode from sysfs (under `enabled=always`, Rig's advice only adds stalls);
   - count only the thread's NUMA node in the buddyinfo reading.
   No speed claim on pup.
7. **Drop:**
   - PROT_NONE plus SIGSEGV windows: a read(2) into an unopened window fails with EFAULT, which breaks "accept means correct";
   - the Mac as a control: ISA, PGO, cores, pages and scheduler all differ;
   - mTHP, prctl modes, hugetlbfs, a huge= tmpfs, userfaultfd, MADV_COLLAPSE, asking always;
   - Mac prefault, per-heap VM objects, one Tables region on the Mac.
