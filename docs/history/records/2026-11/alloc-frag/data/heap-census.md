# Heap census (RIG_HEAP_RSS=1) and RIG_HEAP_HUGE_MIN_MB, for Trig's memory agent

Branch scratch/heap-census, never pushed. Base: Trig pin b4d9e7247 + a83dd857d (RIG_HUGE_MIN_MB) + 0175420e8, d13fdaad6 (RIG_TABLE_RSS).
Head 355e32b09. Census: 1b11a3ff6..279501d09 plus d4e309ee7, 355e32b09 (fixes). Knob: 21b484abf.
burst: ~/cpuq/worktrees/rig-heap-census (bin/rig built at 355e32b09). Mac: ~/Data/Code/worktrees/rig/scratch-heap-census.
Bundle to move it: ~/cpuq/tmp/hc.bundle on burst (git fetch BUNDLE scratch/heap-census).

## Build Trig with it (burst)
    . ~/cpuq/tmp/setup1123/env.sh
    git -C ~/cpuq/worktrees/trig-main worktree add --detach ~/cpuq/worktrees/trig-heapc ffdc6801   # done; misc -> trig-main/misc
    cd ~/cpuq/worktrees/trig-heapc
    RIG=~/cpuq/worktrees/rig-heap-census/bin/rig TRIG_RIG_OVERRIDE=1 TRIG_CHECK_CACHE=~/cpuq/tmp/hc/check \
      RIG_OUT_DIR=~/cpuq/tmp/hc/out tools/check/build      # 16 min; prints the binary
Built: ~/cpuq/tmp/hc/check/builds/fa1649a79c9413e4c0f7/trig (355e32b09).

## Run
    RIG_HEAP_RSS=1 trig -p .../typeorm/packages/typeorm/tsconfig.json --noEmit --singleThreaded 2> census.txt
Linux only. Unset: one byte tested per heap made, segment mapped, worker started, and at exit.

## Output (stderr, key=value, bytes)
`rig-heap-rss: peak ...` lines (the last snapshot), `peak snapshots=N`, then `rig-heap-rss: exit ...` lines. Per snapshot:
- `seg heap=I kind=small|span base=...` per segment: used_pages/used_units, released, asked_huge, rss, huge,
  hdr_rss, room_rss (resident past what is handed out), free/free_rss/whole_free_pages/whole_free_rss (small),
  vma/vma_rss/vma_huge (the smaps VMA holding the base; VMAs merge, so this is per VMA, not per segment).
- `heap=I tid main role=main|workerK|pool|other spare leads faults_ahead taken live_est bad_lists` then small:
  segs seg_rss seg_huge seg_hdr_rss seg_room_rss small_held small_free small_free_rss whole_free_pages whole_free_rss
  released_pages tail_waste full_pages small_inuse; spans: spansegs spanseg_rss spanseg_huge spanseg_hdr_rss
  spanseg_room_rss spanseg_uncarved span_live span_peak span_bound warm warm_n warm_rss cold cold_n cold_rss;
  large: large_live large_peak keep_bound kept kept_n kept_rss kept_cold kept_cold_n kept_cold_rss.
- `classes heap=I size:pages:free_bytes ...` classes with >= 256 KiB free.
- `total ...` sums, region_scan_rss (one scan of the whole region), smaps_region_rss, smaps_tables_rss,
  smaps_other_rss, vmrss, vmhwm, hwm (peak when the snapshot began), hwm_end, counts_live/peak (os.memory, -1 if absent).

How measured: resident/huge by PAGEMAP_SCAN ioctl (present, not the zero page; huge = PMD-mapped). Segments are
recorded as mapped (a table of 4 MiB slots), so none is guessed. Free blocks: every heap's free and remote list of
every class walked; each block checked against the recorded segments and its class before it is read, so a list
changed meanwhile ends the walk (bad_lists counts that). Class of a page is known only from free blocks or the
carve page; full_pages are pages with no free block (their tail waste is not counted). small_inuse = held - free
(includes full pages' tails). live_est = small_inuse + span_live + large_live (the heap's own counts). Free spans by
walking the bins (tags give length); kept large blocks via process_vm_readv. Peak: a census thread polls getrusage
maxrss each 1 ms and re-measures when it rose by max(1 MiB, 1/200); short runs (<0.3 s) lag: compare hwm, hwm_end.

## Checks
Small program (cross-heap mix) on burst: sum_seg_rss = region_scan_rss = smaps_region_rss, and region + other =
VmRSS to the page (huge pages on and off). Unit tests pass. Trig typeorm c1 (nothp): region 161.4 + tables 57.0 +
other 20.6 = 239.0 MB = VmRSS. (typeorm on burst prints "Cannot find namespace 'yargs'": burst's install may be partial; 0.86 s.)

## typeorm c1, huge pages off (RIG_HUGE_MIN_MB=100000), main heap, MB
segments 161.4 (small 102.2 + span 59.2) vs live_est 132.3 (small 74.4 + spans 57.9): gap 29.1 =
- free small blocks in partly used pages 25.8 (whole free pages only 1.0). Classes: 112B 2.7 (48 pages, 88% free),
  144B 2.6, 120B 2.6, 128B 2.5, 1280B 2.2, 104B 1.3, 160B 1.2, 1920B 0.9 ...: scattered survivors pin pages.
- warm free spans 3.9 (spanBound 17.0 not binding), cold 0.0
- segment headers 1.2 (25 x 64 KiB pages, first 4 KiB pages only), room 1.0, tail waste 0.5
- keep_large / kept large blocks: 0 (no block >= 16 MiB here).
Huge pages on: segments 165.7 (+4.3: headers whole 64 KiB, cold span 0.5, span room 0.4).
First reading: the gap is fragmentation of small classes, not keep_large or the bounds.

## RIG_HEAP_HUGE_MIN_MB=N (21b484abf)
Read once with the THP mode from /proc/self/environ, as RIG_HUGE_MIN_MB. A heap not made by the main thread
(Heap.main, gettid()==getpid() at newHeap) asks huge pages for a segment or span segment only once its taken,
counting the new segment, exceeds N MiB (whole huge pages). Main heap, Tables, large blocks: RIG_HUGE_MIN_MB as
before. Unset: as today. Unit test for the parse beside RIG_HUGE_MIN_MB's.
Fit: (1) a span segment counts 32 MiB, so N <= 32 still gives every worker's span segment huge pages; N=64 covers
them. (2) main vs leads: for Trig they agree (c1 --singleThreaded main leads; c4 no heap leads). They differ only
under N MiB: a lone worker doing a program's work keeps huge pages under leads, and a tiny main heap at c4 keeps them
under main. leads moves as heaps grow (the first heap leads trivially), so main is the steadier cut.
Compiler c4 on burst (96 cores: ~40 worker heaps take one segment each), exit, workers:
  unset  seg_rss 147-157, seg_huge 106-126, spanseg_huge 14-16; peak RSS 250-264 MB
  N=32   seg_rss 14-17,  seg_huge 0,       spanseg_huge 14-20; peak RSS 112-121 MB
  N=64   seg_rss 13,     seg_huge 0,       spanseg_huge 0;     peak RSS 84 MB
Main heap's seg_huge 4-6 MiB in every run. Burst's many workers inflate this beside pup's.
Files on burst: ~/cpuq/tmp/hc/{typeorm2-c1-*,compiler-c4-*}.err
