# narrow-split: why race 754's wide arm (W) checks slower than main's path (M) (2026-11-24)

Measurement only. Nothing built, nothing changed. Binary: race 754's PGO+BOLT phase-wide build
(`/zfs/trig-pup/trial/pw/bin-bolt`, sha16 907f23b6619f4fa7), copied to `/zfs/trig-pup/trial/narrow/trig`. Arms as in
phases-sweepPW.sh: M = M4, W = W4 (`RIG_WIDE=1`), `taskset -c 0-11 ... --checkers 4`, nuxt and webpack. Every run went
through pupx, one call per run, under `/tmp/pup-timing.lock`, arms shuffled within each round, 15:20-15:35 MST.

## Verdict

**Placement dominates. Cold caches are about 0, and the narrowing itself costs about 1 ms.** The placement cost is
the six surviving workers keeping the CPUs they held in the 12-wide front end. When two of the four checker threads
sit on sibling hyperthreads of one P-core, they stay there for the whole check: 0-2 migrations, because each logical
CPU runs exactly one task and the balancer has nothing queued to pull. Both run at IPC 1.15-1.25 instead of 1.8-1.95
(about 0.64x). That makes the check bimodal: +50 ms on nuxt and +106 ms on webpack whenever it happens.
In the runs with no stacking (flat runs), the rest of W's excess is allocator and cross-core traffic from the parked
donor heaps: freeSlow triples, and snoop-forwarded loads double, at an even rate through the whole check.
A cheap fix is plausible:
1. at narrow, keep one surviving worker per physical core, by pinning them or by choosing which workers to park by
   core;
2. keep frees out of the parked heaps, for example by having the survivors adopt the parked heaps' free lists at
   narrow.

M also stacks in 5-7% of runs (+36 / +48 ms), so (1) would help main's path too.

## 1. Repro (plain, as the harness: /usr/bin/time, no perf; `s1`, 16 rounds/arm, clean)

| cell | M check median | W check median | paired W-M median | W runs per round, ms |
|---|---:|---:|---:|---|
| nuxt c4 | 255.0 | 257.5 | +3.5 | 350 240 249 255 258 297 262 250 244 257 253 253 307 260 260 318 |
| webpack c4 | 280.0 | 331.0 | +46.5 | 289 327 278 287 335 292 288 399 294 416 274 393 402 388 341 401 |

The webpack +12 reproduces as a median only by chance of the mix: W is bimodal. In the race, 1 of 10 W webpack runs
was stacked (333). In mine it was 8-9 of 16 (the ~390-416 runs). Under switch-event recording (`sw`, ~no overhead,
16 rounds/arm) the medians are nuxt 252.5 / 256.0 (+3.5) and webpack 281.5 / 291.0 (+9.5); the means are +19.5 and
+42. A first pass of rounds 9-16 of `s1`, and an earlier stat set, ran while a foreign trig test swarm (affinity
0-21, not under the lock) loaded the P-cores. Those runs are in `s1-dirty` and `s2-dirty`, not used, and were re-run. one.sh now refuses a
run while a swarm runs and logs `pre_busy`.

## 2. Placement, measured per run (switch events: CPU of every thread, every switch)

Pooled over sw, rec and stat runs (56 runs per arm; "stacked" = more than 50 ms of the check with two of the
program's threads on one P-core's sibling pair):

| | stacked share M / W | W check, flat / stacked mean | cost per stacked run | flat W - M by set (sw, rec, stat A/B/C) |
|---|---|---|---:|---|
| nuxt c4 | 5% / 54% | 253.8 / 303.6 | **+49.8** | -2.8, +2.6, -1.1, +4.6, -3.5 (about 0) |
| webpack c4 | 7% / 39% | 286.4 / 392.1 | **+105.7** | +5.9, +4.2, -0.9, +3.6, +5.2 (about +3.6; race's 9 flat runs +11) |

- **Example, sw W nuxt r1:** the busy threads sit on CPUs 5, 9, 2 and 0 from the check's start to its end, and 5
  and 0 are core 0's siblings. **Webpack r10:** CPUs 7 and 6, core 3. Stacked runs show ~210 ms (nuxt) and ~375 ms
  (webpack, the two long checkers together) of doubled core time (`extra.txt` §2).
- **No checker on a parked worker:** the parked threads have 0 on-CPU ms in the check (7 threads run: main + 6
  workers). Check migrations: median 0-1 in both arms.
- **Why ~50% in my runs:** 4 busy threads on random distinct CPUs out of 12 land on 4 distinct cores with
  p = 0.485. The race saw 0/10 and 1/10; I can't recover its placement after the fact.
- **Per stacked run:** if the share of stacked runs is f_W in W and f_M in M, the mean cost is
  f_W x cost - f_M x cost_M. That gives **+25 ms on nuxt** and **+38 ms on webpack** in my runs, and about +0 / +5 in
  the race's medians.

The placement category also covers heaps: their cross-heap frees and their remote traffic. In the flat runs
(rec, 16 rounds/arm: nuxt 6 W flat runs, webpack 8), mean Gcycles per run in the check:

| check, flat runs | nuxt M / W / d | webpack M / W / d |
|---|---|---|
| rig.alloc.freeSlow | 0.017 / 0.059 / +0.042 | 0.032 / 0.076 / +0.044 |
| rig.alloc.alloc (+ allocSlow) | 0.093 / 0.113 / +0.020 | 0.076 / 0.105 / +0.029 |
| alloc page/span, trimIdle | 0.029 / 0.021 / -0.008 | 0.013 / 0.010 / -0.004 |
| checker code | 3.524 / 3.542 / +0.018 | 3.829 / 3.874 / +0.045 |
| kernel | 0.255 / 0.260 / +0.005 | 0.295 / 0.297 / +0.002 |
| scheduler (rig.sched/tasks, spinning) | 0.0046 / 0.0053 / +0.0007 | 0.0032 / 0.0027 / -0.0004 |

At ~63-65 ms of check wall per Gcycle (4.6 GHz, 3.35-3.5 busy cores), the allocator rows come to **+3.2 ms (nuxt)**
and **+4.4 ms (webpack)**.

In the flat webpack runs, W's checker code also has more cache misses:
- L2 demand misses +0.46 M, served mostly by snoops (perf stat set C, whole check): `xsnp_fwd` 160 K -> 386 K and
  `xsnp_no_fwd` 42 K -> 87 K, while L3 hits and L3 misses stay flat.
- The excess comes at an even rate through the check (0.5 K/ms in its first 20 ms, 0.8 K/ms after). It is far more
  than the idle cores' L2s could hold of the load's data (2 cores x 32 K lines).
- So it is ongoing write sharing between the active checkers' cores, consistent with frees into donor heaps whose
  blocks the other heaps then take. That is an inference: call chains were unavailable, because the BOLT binary has
  no frame pointers.
- It costs **+1.1 ms (nuxt), +2.9 ms (webpack)** (checker-code row).

The cycle estimates (+4.3 / +7.3) sit above the measured flat W-M (~0 / +3.6, race +11). On nuxt the 4th checker
finishes early, so not every cycle lands on the critical path.

## 3. Cold caches (the load's data in other cores' L2)

The first 20 ms of the check, flat runs, W - M:

| | nuxt | webpack |
|---|---|---|
| L2-miss stall cycles (rec / stat B), Gc | -0.002 / -0.000 | -0.001 / +0.009 |
| L2-missing loads (rec / stat B), M | -0.003 / +0.015 | -0.015 / +0.008 |
| snoop-forwarded loads (stat C), K | +13.6 | +10.5 |

So it costs **~0 ms (nuxt), at most +0.6 ms (webpack)**. A P-core refills its 2 MB L2 in a few ms of the check
(about 6 M L2 misses in about 260 ms over about 3.4 cores), so the load's data can't matter past the check's start.
The excess misses in §2 are spread through the whole check and served by snoops between active cores, so they are
not cold caches.

## 4. The narrowing itself

- **Inside the check:** scheduler symbols, spinning included (claimSpinning is inlined into rig.sched.loop / next),
  are flat. Kernel +0.005 / +0.002 Gc. That's **about +0.3 / +0.1 ms**.
- **From the bind's end to the check's start** (ids + rest + checkers create + before check, means of 75 runs/arm):
  nuxt 7.85 -> 9.00 (**+1.15 ms**), webpack 3.61 -> 4.43 (**+0.8 ms**). This is outside "Check time".
- **In the narrow window:** the parked workers' trimIdle costs +0.029 Gc and the kernel +0.02 Gc (nuxt), on
  otherwise idle threads.

## 5. The split, ms of check wall (W - M)

| | nuxt c4 | webpack c4 |
|---|---:|---:|
| 1a placement: SMT stacking, cost per stacked run | +49.8 | +105.7 |
| 1a mean over my runs (54% / 39% of W runs stacked vs 5% / 7% of M) | +25 | +38 |
| 1a in the race's medians (0/10, 1/10 stacked) | ~0 | ~0 (mean +5) |
| 1b placement: heaps (freeSlow, alloc, cross-core snoops), cycle estimate | +4.3 | +7.3 |
| 1b measured flat-run W - M (mine; race) | ~0 ±3; +2 | +3.6; +11 |
| 2 cold caches | ~0 | ≤ +0.6 |
| 3 narrowing: inside the check / bind end to check start | +0.3 / +1.15 | +0.1 / +0.8 |

## Method, scripts, data (pup: /zfs/trig-pup/trial/narrow/)

- **one.sh** `OUTDIR MODE PROJ ARM TAG`: one run.
  - Refuses during a slot (75) or while a foreign trig test swarm runs (76).
  - Modes:
    - `plain`: as the harness;
    - `sw`: switch events only;
    - `A` / `B` / `C`: `perf stat -I 10` in three unmultiplexed event sets, under switch recording:
      - A: cycles and instructions, u and k;
      - B: l2_rqsts.demand_data_rd_miss, mem_load_retired.l2_miss, memory_activity.stalls_l2_miss (this CPU's
        cycle_activity.stalls_l2_miss), mem_load_retired.l3_hit;
      - C: mem_load_l3_hit_retired.xsnp_fwd and xsnp_no_fwd, mem_load_retired.l3_miss, dtlb_load_misses.walk_active;
      - all three add task-clock, context switches, cpu-migrations and faults;
    - `rec` / `rec2`: perf record sampling cycles, instructions, L2-miss stall cycles, L2-missing loads (rec2 adds
      xsnp_fwd), with switch events and CPU;
    - `recg`: `-g`; it gave no call chains, since the binary has no frame pointers.
  - perf, time and the shell run on core 13, the program on 0-11.
- **drive.sh** (run on the Mac) `OUTNAME ROUNDS MODES`: rounds, with the (mode, arm) pairs shuffled.
- **Analysis scripts:**
  - **rows.py:** row medians and paired deltas.
  - **ph2.py:** perf stat cut by the program's own rows into front, gap, check, check0 (the first 20 ms) and check1,
    with each run classified by stack.tsv.
  - **prof2.py:** perf record and switch analysis per window: doubled core-ms, migrations, IPC solo vs doubled,
    cycles by category and symbol; writes stack.tsv.
  - **pool.py:** the pooled stacked share and cost.
  - **extra.py:** the gap means, the stacked threads' CPUs, and the freeSlow caller attempt.
- **Data sets:**
  - s1: plain, 16 rounds;
  - s5: sw, 16;
  - s6: stat A/B/C, 8 each;
  - s3 + s4 (linked as s34): rec, 16;
  - s7: recg, 3.
- **Outputs:** s5/prof.txt, s34/prof.txt, s6/prof.txt, s6.ph.txt, extra.txt.
