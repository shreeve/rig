# Small-class fragmentation: ceilings (a) and (c), measured (scratch, nothing lands)

Branch scratch/heap-census (Mac worktree ~/Data/Code/worktrees/rig/scratch-heap-census; burst ~/cpuq/worktrees/rig-heap-census).
- base   355e32b09  census only (RIG_HEAP_RSS)
- (c)    886bd071c + 142549fbb (test)  RIG_SMALL_BORROW=N: a class whose list and remote list are empty and whose page is
         carved out takes a free block of one of the N classes above (alignment <= 8) before a new page; freed, it goes on
         its own length's list. Cost when unset: one global-byte test in allocSlow. trimIdle walks every list when on.
- (a)    605c2f2d9  classes 136 and 152 (8 B steps 96..160), comptime `fine_mid`; carries (c)'s switch too.
- 0f044d51c  (c) reads its switch on the Mac (getenv) as well.
Unit tests pass on burst for (c) and (a). Trig ffdc6801 outputs are byte-identical across all arms (md5 per project).

Pup binaries (TRIG_TARGET_CPU=meteorlake, plain release via tools/check/build): /zfs/trig-pup/trial/frag/trig-{base,borrow,fine};
results /zfs/trig-pup/trial/frag/r/ (t-* census+VmHWM, i-* perf stat). Runs: pupe, c1 on E-core 12, c4 on 12-15.
Projects: /zfs/trig-pup/corpus/typeorm/packages/typeorm and .../typescript-benchmarking/cases/solutions/Compiler, tsconfig.json.

## c1 instructions:u (cpu_atom), 3 runs each, spread < 0.002%
| arm | typeorm | vs base | Compiler | vs base |
|---|---|---|---|---|
| base | 6261.49 M | | 1748.95 M | |
| borrow bin, unset | 6262.65 | +0.019% | 1749.01 | +0.003% |
| (c) N=1 | 6276.10 | +0.233% | 1749.55 | +0.034% |
| (c) N=2 | 6276.61 | +0.241% | 1749.56 | +0.035% |
| (a) | 6262.00 | +0.008% | 1749.02 | +0.004% |
| (a)+(c)2 | 6274.89 | +0.214% | 1749.57 | +0.035% |

## VmHWM (MB, /usr/bin/time %M), huge pages off (RIG_HUGE_MIN_MB=100000) / as today
| arm | typeorm c1 | Compiler c1 | typeorm c4 (3 runs) | Compiler c4 (3 runs) |
|---|---|---|---|---|
| base | 228.8 / 242.7 | 68.1 / 72.6 | 249.5 252.5 247.2 = 249.7 / 255.4 | 80.7 79.7 81.2 = 80.5 / 107.0 |
| (c)1 | 228.9 / 242.7 | 68.1 / 72.5 | 253.6 / 247.2 | 79.6 / 106.2 |
| (c)2 | 226.8 / 240.6 (-0.9%) | 68.0 / 72.6 | 254.0 234.6 240.3 = 243.0 (-2.7%) / 247.2 | 75.9 77.3 81.8 = 78.4 (-2.7%) / 103.0 |
| (a) | 230.0 / 244.9 (+0.5%) | 68.2 / 72.6 | 243.1 246.4 236.7 = 242.0 (-3.1%) / 261.4 | 79.4 82.3 83.2 = 81.6 (+1.4%) / 106.5 |
| (a)+(c)2 | 226.8 / 240.6 | 68.2 / 72.0 | 256.4 / 238.1 | 81.7 / 108.6 |
(MB = %M KB x 1024 / 10^6; c4 rows single runs unless three are shown. c4 spread is +-3%: (c)2 and (a) at c4 are within it.)

## Census, typeorm c1, huge pages off (exit = peak here), MB
| arm | segments | live_est | small free (resident) | whole-free pages |
|---|---|---|---|---|
| base | 155.1 | 131.2 | 21.6 | 0.9 |
| (c)1 | 155.1 | 131.7 | 20.4 | 1.2 |
| (c)2 | 153.0 | 132.7 | 17.2 | 1.0 |
| (a) | 156.2 | 131.1 | 21.7 | 0.9 |
Borrowing turns 4.4 MB of free blocks into live ones (live_est rises 1.5 MB: the borrowed blocks' extra bytes), net -2.1 MB of
segments. Fine classes move nothing at c1. typeorm c4 off, segments: base 172.6, (c)2 161.7, (a) 167.7 (3-run means).

## Reading
The free small blocks are spread over most pages of the busy classes (typeorm c1: 21.6 MB free in 100 MB of class pages,
0.9 MB in wholly free pages), so a neighbouring class can reuse only the free blocks of the class just above it, and only
when its own page runs out: (c) recovers about a fifth of them, 0.9% of VmHWM at c1 (maybe 2-3% at c4, inside the noise),
for +0.23% instructions on typeorm. Finer classes (a) do not help at c1. Neither is "several percent at no speed cost", so
no design note. The free space is survivors pinning pages across classes, which neither ceiling reaches; that points at
lifetime separation (the held (b)), not class layout.

## Mac guards
bench/hash/guard.py and bench/json/guard.py under tools/mac-claim, PATH and RIG at each Mac Rig
(scratchpad/hc/mac/{m0,mc,ma}, mc with RIG_SMALL_BORROW=2): see guards.log / guard-*.log beside this file.
