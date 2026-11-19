# Code alignment: the measurement (Expert A, 2026-11-19)

The question ([brief.md](brief.md)): which layout property makes
qsort-mac's s0 placement 15% slower at 1 worker, and which means removes
it. Rig b7bb1df1d (main after #1172), `rig build --release`, Apple M5,
Zig 0.17.0. Every timed run inside `tools/mac-claim`; programs in
rotating order each round ([probes/board.py](probes/board.py)); paired
ratios to a reference placement by round, median [quartiles]; an A/A arm
(a byte copy of the reference); every sum checked (psum 16760439056,
qsort 4194304). The Mac carried other sessions' work (load 3 to 8). Raw
samples in [raw/](raw/); the programs are made by the scripts in
[probes/](probes/) and are not kept.

## The answer in short

- **The property is a hot loop crossing a 4 KiB boundary.** s0's
  partition loop (its low push path, `0x...bff4` to `0x...c01c`) runs
  across `0x...c000`. s18, which is s0 moved by exactly 4,096 bytes, is as
  slow (1.151 of s1); s36, whose loop crosses 4 KiB at another offset
  within 64 and 128 bytes, is as slow (1.144). s10 and s25, at s0's
  offset within 64 bytes but clear of 4 KiB, run like s1 (1.005, 0.967).
  Not 16 KiB (the page), not 32, 64 or 128 bytes.
- **A synthetic copy of the loop shows it alone**: the same instructions
  at 70 offsets ([probes/loopgen.py](probes/loopgen.py)). With the loop's
  top just before any 4 KiB boundary (`0x0ff4`, `0x1ff4`, `0x2ff4`,
  `0x3ff4`, and `0x0fe0` to `0x0ffc`) it takes 2.10-2.19 ms; at every
  offset clear of one, 1.43-1.72 ms, whatever its offset within 128 bytes.
  The loop is 25-45% slower across 4 KiB, also with every branch predicted
  (sorted data). The cost is in the runs every iteration or the low path
  fetches straight through; the high path's short runs (3 instructions
  between taken branches) cross 4 KiB at no cost.
- **Function alignment does not remove it.** It moves every placement, so
  each aligned arm's eight placements happen to miss the crossing (spread
  1.020-1.040 at 1 worker against 1.146 unaligned), but a placement made
  at qsort `0x...f00` under `align(128)` (so also 16-, 32- and 64-aligned)
  crosses 4 KiB and is 16.5% slower (1.165 [1.146-1.198]). For a loop of
  L hot bytes the chance of a crossing is about L/4096 at any function
  alignment below 4 KiB.
- **What removes it: shifting the function that holds the crossing loop,
  found after the link.** A check of the linked program
  ([probes/straddle.py](probes/straddle.py): inner loops of at most 256
  bytes whose span crosses 4 KiB) names qsort in s0, s18, s36 and the
  `align(128)` placement; `align(64)` on qsort alone (`align(256)` where
  it was already 128-aligned) clears all four, and all four then run at
  the reference's speed: 1.009-1.020 of s1 at 1 worker, A/A 1.008.
- **Loop-head padding is not available.** Zig 0.17 passes no
  `-align-loops`; `asm volatile (".p2align 6")` before the loop lands
  where LLVM puts it (it aligned an earlier loop, and the partition loop
  moved by 28 bytes, still unaligned); compiling Zig's bitcode with
  `zig cc -falign-loops=64` changes the code (245 instructions in qsort
  against 357) and aligned only one inner loop. And loop alignment helps
  only loops no longer than the alignment.
- **Not every crossing loop costs.** In the placement sweep, std.sort's
  insertion loop, its partition loop, psum's loop and qsort's other loops
  each cross 4 KiB in some placement (s2, s20, s28, s30, s38, s47, s13,
  s14, s17, s31, s32, s35) and none of those is slower (0.973-1.021). A
  layout check can name candidates, not costs.

## Placements

[probes/gen.py](probes/gen.py) makes qsort-mac's shift/ programs: fork.rig
with K never-taken prints that only grow `main`; K = 0 to 47 built
([probes/buildk.sh](probes/buildk.sh)). qsort's 357 instructions are the
same in all (same mnemonic hash, [raw/layout-k.txt](raw/layout-k.txt)).
The partition loop sits at qsort+0xe4: the low push path is qsort+0xe4 to
+0x10c (40 bytes, the loop's top), the shared counter and load block
+0xec to +0x100, the high push path +0x12c to +0x138 and +0x154 to +0x160.

Screen, board screen1 (12 rounds, 1 worker), qsort ms and ratio to s1:

| | qsort at | partition loop | ms | / s1 |
|---|---|---|---:|---|
| s0 | 0x10005bf10 | crosses 4 KiB (and 16 KiB) | 189.7 | 1.157 [1.107-1.199] |
| s18 | 0x10005cf10 | s0 + 4,096: crosses 4 KiB | 192.4 | 1.151 [1.106-1.210] |
| s36 | 0x10005df0c | crosses 4 KiB, other offset | 191.9 | 1.144 [1.119-1.192] |
| s10 | 0x10005c7d0 | s0's offset mod 64, clear | 169.6 | 1.005 [0.980-1.076] |
| s25 | 0x10005d550 | s0's offset mod 64, clear | 166.0 | 0.967 [0.948-1.049] |
| s23, s44 | | clear | 163.9, 164.1 | 0.986, 1.003 |
| s5 | | clear | 164.9 | 0.990 |
| s1 A/A | | | 163.7 | 0.992 [0.955-1.022] |

Validation, board validate (12 rounds, 1 worker): of the placements whose
straddle check names some other inner loop (std.sort's `sortRegion`,
`quicksort`, `heapsort`; psum; qsort's 28- and 92-252-byte loops; main's),
none is slower than s1 (0.973-1.021), and s0 again is (1.157).

## The synthetic loop

[probes/loopgen.py](probes/loopgen.py): qsort's partition loop byte for
byte in layout (registers renamed), each copy in its own region with the
loop's top at a given offset; 2^22 random Ints split around the middle
element; every copy timed each round, rotating; 21 rounds, medians in ms.
Runs loop1/loop2 ([raw/loop1.txt](raw/loop1.txt),
[raw/loop2.txt](raw/loop2.txt)), and loop2-random/-sorted with the
high-path offsets:

| loop top at | what crosses 4 KiB | random | random | sorted |
|---|---|---:|---:|---:|
| 1024-1276, every 4 bytes (64 offsets) | nothing | 1.43-1.72 | 1.44-1.72 | 2.18-2.39 (7 offsets) |
| 0x0f8c | high path's second run (3 instructions) | | 1.65 | 2.62 |
| 0x0fb4 | high path's first run | | 1.79 | 2.35 |
| 0x0fd4 | nothing (the high path is on the next page) | 1.67 | 1.74 | 2.09 |
| 0x0fe0 | low path, after its compare | 2.13 | 2.26 | 2.56 |
| 0x0ff0, 0x0ff4 | low path, through the shared block | 2.10-2.11 | 2.17-2.21 | 3.06-3.16 |
| 0x0ffc | low path, its first instruction | 2.12 | 2.17 | 2.56 |
| 0x1ff4, 0x2ff4, 0x3ff4 | as 0x0ff4, at 8, 12 and 16 KiB | 2.10-2.11 | 2.15-2.17 | 3.15-3.19 |

The spread clear of 4 KiB is bimodal from run to run (one offset reads
1.43 in one run and 1.64 in the next), and shows no pattern within 32,
64 or 128 bytes; every crossing of the low path reads high in every run,
with tight quartiles. (The sorted rows run slower throughout, for a
reason not looked into; within them a crossing costs 17-45%.) The
earlier qsort-mac straddle test (a smaller loop, 2-10%) agrees in sign.

## The means, on the real program

Board means ([raw/means.json](raw/means.json),
[raw/means-stats.txt](raw/means-stats.txt)): 48 programs, 16 rounds, at 1
and 10 workers, ratios to base-s1. Function alignment by a probe rig
whose emit writes `align(N)` on every emitted function when
`RIG_PROBE_ALIGN=N` (a copy of main with one helper in src/emit.zig; not
committed); the eight placements K = 0 to 7 under each.

| arm | 1 worker: median of placements | spread | 10 workers | spread |
|---|---:|---:|---:|---:|
| base (no alignment) | 169.1 | 1.146 (s0) | 62.2 | 1.077 |
| align(16) | 169.7 | 1.034 | 62.1 | 1.076 |
| align(32) | 169.9 | 1.020 | 62.4 | 1.059 |
| align(64) | 170.5 | 1.040 | 61.5 | 1.038 |
| align(128) | 169.9 | 1.027 | 62.3 | 1.093 |
| A/A (base-s1's copy) | 171.0 (1.008) | | 61.3 (0.992) | |

None of the aligned arms' eight placements crosses 4 KiB (the straddle
check finds no qsort crossing there, [raw/straddle-align64.txt](raw/straddle-align64.txt)
for align(64) at K = 0 to 40), which is the whole of their narrower
spread. The crossing placements and the shift that clears them:

| program | partition loop | 1 worker / base-s1 | 10 workers |
|---|---|---|---|
| s18 | crosses | 1.158 [1.147-1.171] | 1.055 |
| s36 | crosses | 1.172 [1.140-1.233] | 1.052 |
| align(128), qsort at 0x...f00 | crosses | 1.165 [1.146-1.198] | 1.042 |
| s0, qsort `align(64)` | clear | 1.009 [0.989-1.030] | 1.023 |
| s18, qsort `align(64)` | clear | 1.020 [0.998-1.037] | 0.987 |
| s36, qsort `align(64)` | clear | 1.012 [0.991-1.041] | 1.029 |
| the align(128) one, qsort `align(256)` | clear | 1.014 [0.990-1.071] | 1.023 |

At 10 workers the board's own noise (quartiles of about ±8%) hides most
of it; the crossing reads 4-6% there.

## Cost

Of `align(64)` on every emitted function (the probe rig,
`RIG_PROBE_ALIGN=64`), the one function alignment worth costing, though
it removes nothing:

- **Size.** qsort-mac: the program section grows from 8,876 to 8,952
  bytes, the file not at all ([raw/size-qsort.txt](raw/size-qsort.txt)).
  Trig (tools/trig/main.rig, CHECK_IDS false, `rig build --release`, its
  libtrees made by tools/trig/gen-libtrees, the probe rig at Rig main
  b7bb1df1d with `TRIG_RIG_OVERRIDE=1`): 5,132 functions emitted
  `align(64)`; the program section grows by 80,832 bytes, 0.78% (10,407,212
  to 10,488,044), the file by 0.27% ([raw/size-trig.txt](raw/size-trig.txt)).
- **std.json's and the tables' guards** (instructions, so blind to layout
  by design): every row within 0.2% of its baseline in both arms, base
  and align(64) alike ([raw/guards-base.txt](raw/guards-base.txt),
  [raw/guards-a64.txt](raw/guards-a64.txt)); the padding is never run.
- **Trig at one checker on the Mac: not measured.** Both builds exist
  and [probes/trig-ab.sh](probes/trig-ab.sh) races them (Trig's
  tools/bench/ab, 20 shuffled rounds, A/A, instructions and cycles), but
  for the last hour of the round the Mac never went quiet (load 9 to 15,
  other sessions' suites and gates), and the claim gave up. Its run
  instructions cannot differ but by the guards' noise (the padding is
  never run); its time is a layout lottery like any other build's.
- **Crossings in Trig.** The layout check on Trig: 106,310 loops in the
  program section; 1,332 inner loops (at most 256 bytes) cross 4 KiB in
  the base build, 1,278 under align(64)
  ([raw/straddle-trig-base.txt](raw/straddle-trig-base.txt),
  [raw/straddle-trig-a64.txt](raw/straddle-trig-a64.txt)): about 1.2% of
  them in any build, as L/4096 predicts. Trig holds its loops in 2,344
  functions, 645 of them over 4 KiB; aligning each to its size's next
  power of two (at most 4 KiB) would pad the section by about 29%
  ([raw/padcost-trig.txt](raw/padcost-trig.txt)) and still leave those
  645 unprotected.

## For the design

- The property to avoid is an inner loop's straight-line hot run crossing
  a 4 KiB boundary on the M5. Function alignment at 16-128 bytes neither
  causes nor prevents it; only an alignment of at least the function's
  size (to the next power of two, at most 4 KiB) would, at a cost in
  padding of up to that size per function.
- What prevents it is a decision made after the link, when addresses are
  known: find the inner loops that cross 4 KiB and move their functions.
  The check is cheap (a pass over the program section's branches), but it
  cannot tell a hot loop from a cold one (twelve of the thirteen crossing
  placements tried cost nothing), and in a large program some loop
  always crosses: it can only aim at loops a profile (`--pgo`) or a
  fact names hot, or clear every crossing loop of at most a few hundred
  bytes by giving their functions a larger alignment until none crosses.
- x86 is untested: [probes/pup-job.sh](probes/pup-job.sh) with
  [probes/loopgen-x86.py](probes/loopgen-x86.py) asks the same question on
  pup's Meteor Lake (every 1-byte offset of the loop top in 128 bytes,
  and just below 4 KiB).

## Files

- probes/emit-align.diff: the probe rig (`RIG_PROBE_ALIGN=N` writes
  `align(N)` on every emitted function); built in a scratch copy, never
  committed.
- probes/: gen.py, buildk.sh, buildall.sh (the eight placements under each
  alignment), alignpkg.sh (align(N) on a package's functions by hand),
  relink.sh and apart.py (rebuild an edited package as `rig build
  --release` does), looppad.sh, bcbuild.sh and buildmeans.sh (the loop
  padding and bitcode routes, rejected), buildfix.sh and hitgen.sh (the
  shifted fixes and the align(128) crossing placement), layout.py and
  straddle.py (where things sit; the layout check), loopgen.py and
  loopgen-x86.py (the synthetic loop), board.py, stats.py, armstats.py,
  claim.sh, buildtrig.sh, guards.sh, padcost.py, trig-ab.sh, pup-job.sh.
- raw/: layout-k.txt, layout-align.txt, straddle-align64.txt,
  straddle-trig-base.txt, straddle-trig-a64.txt, padcost-trig.txt,
  size-qsort.txt, size-trig.txt, guards-base.txt, guards-a64.txt, screen1,
  validate and means (`.json` samples, `.log` with the machine's load;
  means-stats.txt), loop1, loop2, loop2-random, loop2-sorted.

## Recommended defaults

1. Emit no function alignment for layout: `align(16)` to `align(128)`
   neither causes nor removes the crossing (an `align(128)` placement is
   16.5% slower), and costs 0.78% of Trig's program section.
2. Keep the boards' two or three placements and their median; add the
   layout check (probes/straddle.py's rule) to board tooling, so a row
   whose hot loop crosses 4 KiB is flagged, not read as a regression.
3. If a compiler means is built, make it the post-link check aimed at
   loops a profile (`--pgo`) names hot, shifting their functions by
   alignment until clear; no blanket fix (Trig has about 1,300 crossing
   inner loops in any build, and most crossings cost nothing).
4. No loop-head padding: Zig 0.17 offers none that lands reliably.
5. Run probes/pup-job.sh on pup before deciding anything for x86.
6. Race Trig with probes/trig-ab.sh when the Mac is quiet, if the lead
   still wants align(64)'s time.
