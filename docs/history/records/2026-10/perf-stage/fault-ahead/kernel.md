# Why 65% fewer page faults barely moved Trig: kernel-side profile

pup, kernel 7.0.0-38-generic, THP madvise (defrag madvise), all mTHP sizes never,
init_on_alloc=1 (Ubuntu default), 8 GB swapfile on (1.4 GB used), session cgroup.
Everything on core 3 (sibling 4 idle). Builds: /zfs/worktrees/rig/ta-trig/packs/{main,new}/bin; tsrs as given. ts-pattern.

## 1. Answer

1. Batching removes only the trap. A populated page still goes through handle_mm_fault one
   4 KiB page at a time (GUP -> faultin_page). It still pays page allocation, the PTE lock,
   memcg charge and stats, LRU add, rmap, zeroing, and the swap-throttle check. Only
   exception entry/exit and the VMA lookup go away: ~800-870 kernel cycles per avoided fault
   (Trig: 17-22M for 25.4k; microbenchmark: 780). The first half of the hypothesis is right.
2. But the remainder is not mostly zeroing. Zeroing is 8% of Trig's kernel time (~470
   cycles per 4K page, in cache) and page allocation is 21%. The biggest share, ~47%, is
   per-4K-folio bookkeeping: the PTE lock and map, the fault core, memcg, LRU, and the
   __folio_throttle_swaprate/blk_cgroup_congested check, which runs on every anon folio
   because swap is on (10% by itself). A 4K page costs Trig ~5,000-5,600 kernel cycles, and
   ~85% of that remains when it is populated rather than faulted.
3. The user-side saving was cancelled. An avoided fault also saves ~700 user cycles
   (pipeline refill and cache/TLB loss after iret; microbenchmark 76.4M vs 30.3M user cycles
   per 65.5k pages), which would be ~18M for Trig. The new build, however, retires +169M user
   instructions (+1.83%, deterministic over 5 runs). The added push check changed inlining
   across the program: 45k symbols differ in size; get_tuple_target_type, for example, grew
   from 2.5 KB to 14 KB. User cycles rose 14-18M. This is for the user-side expert.

Net: kernel 5-6% lower (0.4-0.5% of total), user flat or up, total 0.4% lower.

## 2. perf stat (core 3; 5 interleaved rounds, medians; stat5.txt, tp-*.txt)

| | main | new | tsrs (1 run) |
|---|---|---|---|
| page faults (trap) | 39,087 | 13,651 | 17,289 |
| minflt (trap + GUP) | 53,644 | 54,034 | 17,384 |
| kmem:mm_page_alloc | 52,842 | 53,240 | 17,250 |
| madvise calls | 194 | 1,713 | 27 |
| mmap / munmap / mremap | 152 / 96 / 15 | same | 27 / 7 / 0 |
| tlb:tlb_flush | 995 | 997 | 36 |
| cycles:k | 319.9M | 302.6M | 174.3M |
| instructions:k | 297M | 309M | 92M |
| cycles:u | 3,991M | 4,009M | 2,862M |
| instructions:u | 9,267.4M | 9,436.7M (+1.83%) | 7,222M |
| dTLB load walk cycles | 86M | 83M | 34M |
| dTLB store walk cycles | 20M | 12.7M | 21M |
| max RSS | 273 MB | 275 MB | 207 MB |

Populate executes more kernel instructions than faulting (the GUP walk) but fewer kernel
cycles: a trap is cheap in instructions and costly in cycles.

## 3. Kernel decomposition

Recorded with perf record -e cycles:k -c 5000000 -g, 80 runs per binary (rec.sh). The 5M
period keeps sampling to at most one sample per 1 ms tick: perf_event_max_sample_rate is
1000, and shorter periods throttle and bias the profile. Classified by cat.py (context = the
outermost kernel entry; work = the innermost known function, with locks charged to their
caller). Shares are scaled to the perf stat medians.

| work | main | new | tsrs |
|---|---|---|---|
| trap entry/exit + VMA lookup | 38M (12%) | 26M (8%) | 22M (13%) |
| page allocation (pcp/buddy, rmqueue_bulk) | 67M (21%) | 50M (17%) | 20M (12%) |
| zeroing (kernel_init_pages) | 26M (8%) | 31M (10%) | 71M (41%) |
| PTE lock/map + fault core | 79M (25%) | 83M (28%) | 32M (18%) |
| swap throttle (__folio_throttle_swaprate, blk_cgroup_congested) | 33M (10%) | 20M (7%) | 8M (5%) |
| memcg charge/stats + LRU + rmap | 37M (11%) | 38M (13%) | 10M (6%) |
| populate GUP walk | 4M (1%) | 12M (4%) | 0 |
| munmap/mmap/mremap (free, zap, VMA, TLB) | 21M (7%) | 24M (8%) | 1M (1%) |
| timer/IRQ/other | 17M (5%) | 19M (6%) | 11M (6%) |
| total | 320M | 303M | 174M |

By context: in main, faults take 59% and madvise 22% (alloc.zig's prefault). In new, faults
take 22% and madvise 59%. The fault context fell 125M (sampled) and madvise rose 88M: the
work moved rather than disappeared. TLB shootdowns are negligible (one thread, local
flushes, 1.5M).

Per avoided fault: ~850 cycles saved (trap ~680 + VMA lookup ~170), and ~250 cycles of GUP
walk added per populated page. Batching keeps caches warm, which trimmed page allocation and
the swap check by a further ~30M sampled. The sampled delta (44M) is noisier than the perf
stat delta (17-22M).

Microbenchmark (pf.c, 256 MiB; kernel cycles per 4K page, 3 runs each):

| method | kernel | extra user cycles |
|---|---|---|
| fault each 4K | 4,000 | +700 |
| MADV_POPULATE_WRITE 64 KiB | 3,220 | 0 |
| populate 1 MiB | 3,110 | 0 |
| THP fault (2 MiB) | 1,810 (95% zeroing, ~2.4 B/cycle, DRAM-bound) | 0 |
| THP populate | 1,800 | 0 |

## 4. Trig vs tsrs: the extra 146M kernel cycles

Both programs instantiate ~210 MiB. Trig does so as ~53.6k separate 4K folios; tsrs puts
129 MiB in 63 huge pages and pays the per-folio work only ~17k times.

| work | Trig main - tsrs |
|---|---|
| PTE lock/map + fault core | +47M |
| page allocation | +47M |
| memcg + LRU + rmap | +27M |
| swap throttle | +25M |
| munmap/mmap/mremap | +20M |
| trap + VMA lookup | +16M |
| zeroing | -45M (THP zeroes whole 2 MiB pages out of cache) |

Almost all of the excess comes from 4K granularity, not from the amount of memory.

Where Trig's pages come from (perf record -e page-faults:u -d mapped to mmaps; smaps; strace):
- Tables: 32.2k faults (82%), 126 MiB. 40 tables are touched, with pages per table
  [5545, 4503, 4004, 3977, 3286, 2655, 2100, 1324, 1224, 602, ...]. 75% of those pages
  (24.1k, 94 MiB) lie beyond each table's first 2 MiB.
- alloc.zig segment region: ~14.5k pages (57 MiB), all populated by madvise, at 4K (no MADV_HUGEPAGE).
- Big blocks (plain mmap/mremap): ~6.7k faults; 51 MB of them are already THP.
- munmap churn is small: 2.5 MiB outside the end-of-run table unmaps. The ~20M munmap
  context is mostly end-of-run table teardown, which exit would pay anyway.

## 5. Remedies, ranked (estimates for ts-pattern, one checker)

1. Huge pages for table memory past the first 2 MiB (Rig runtime, table.zig). Keep
   NOHUGEPAGE on the first 2 MiB and MADV_HUGEPAGE the rest, 2 MiB-aligned. This covers
   24.1k pages (75% of table faults). A page costs ~5,000 at 4K, ~3,900 populated, ~1,800 as
   THP: -55M kernel vs new, -80M vs main (1.3-1.8% of total), plus fewer dTLB walks.
   Costs ~+9 MiB RSS (a <=2 MiB tail on ~9 large tables). Risk: direct-compaction stalls
   under fragmentation (defrag=madvise). In the 40-table model (tab.c), push time with THP
   past 2 MiB matched populate.
2. THP for alloc.zig's segment region (Rig runtime). 57 MiB is populated at 4K (~4,900
   cycles/page). As THP: ~-45M kernel (1%), with at most +1 MiB RSS per heap at the 1 MiB
   prefault step. Remedies 1 and 2 together would bring Trig's kernel time from ~300M to
   ~170-180M, about tsrs's level. dTLB walks are 106M cycles vs tsrs's 55M, partly
   overlapped; expect a further 0.5-1% of total.
3. Touch fewer fresh pages (Trig's allocation pattern). Each 4K page not touched saves
   ~5,000 kernel cycles at 4K, ~1,800 under THP. Trig's footprint is close to tsrs's
   (210 vs ~200 MiB), so this is incremental: 10% fewer pages ~25M (0.6%), and less after
   remedies 1 and 2. Reuse within the run is already high (almost nothing is freed and refaulted).
4. Fault-ahead as built: -17 to -22M kernel (0.4-0.5%). Remedy 1 makes it moot for large
   tables. For small tables it is worth keeping only if the +1.83% user-instruction
   inlining shift is fixed (for example, by keeping the check out of the inlined push).
5. munmap/mremap churn: <=5M. Not worth doing.

Outside Rig: on a machine without swap, the swap-throttle check (~20-33M, 10%) disappears.
64 KiB mTHP (hugepages-64kB/enabled) would cut bookkeeping 16x without the 2 MiB overshoot.
Both are machine settings and were not changed. MADV_NOHUGEPAGE also blocks mTHP on tables.

## Commands

    taskset -c 3 perf stat -e cycles:u,cycles:k,instructions:u,instructions:k,page-faults,dtlb_load_misses.walk_active,dtlb_store_misses.walk_active -- BIN -p tsconfig.trig.json --noEmit --singleThreaded
    sudo taskset -c 3 perf stat -x, -e page-faults,kmem:mm_page_alloc,kmem:mm_page_free,syscalls:sys_enter_{madvise,mmap,munmap,mremap},tlb:tlb_flush -- BIN ...
    ./rec.sh    # perf record -e cycles:k -c 5000000 -g, 80 runs per binary
    perf script --no-inline --kallsyms=kallsyms -i P-main.data -F comm,period,ip,sym | python3 cat.py 80 bin
    perf record -e page-faults:u -c 1 -d -- BIN ...; perf script --show-mmap-events -F addr,ip,sym
    gcc -O2 -o pf pf.c;  taskset -c 3 perf stat -e cycles:k,cycles:u ./pf {touch,pop64k,pop1m,thp,thppop} 256 1
    gcc -O2 -o tab tab.c; taskset -c 3 perf stat -e cycles:u,cycles:k,page-faults ./tab {touch,pop64k,thp2m}
    strace -e trace=mmap,munmap,mremap,madvise BIN ...; nm -S --size-sort (symdiff.txt)

Files here: stat5.txt, tp-*.txt, rss-*.txt, cat-{main,new,tsrs}.txt, P-*.data, pf-*.data,
strace-main.txt, pfa-main.txt, smaps-*, symdiff.txt, tabstat.txt, pf.c, tab.c, cat.py, rec.sh.
