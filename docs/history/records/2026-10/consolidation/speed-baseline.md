# The round's speed baseline (2026-10-23)

Consolidation track 6. The owner's rule: nothing late may slow earlier
work. The reference is ace79d579, main before 2026-10-21; it is timed
against main at c77a86b07 (#570), each compiler building the same
programs. The census (census.md) repeats this after each batch of
merges.

## Method

- **Builds.** Each compiler is built from its own tree: on the Mac in
  worktrees (`tools/heavy zig build`, ReleaseSafe), on pup from `git
  archive` copies under `/zfs/worktrees/rig/census/`, each build on a
  release slot (`/zfs/trig-pup/trial/slot.sh`) with 12 GB available.
  Every benchmark program is built by its own tree's `bin/rig`; the
  benchmark sources (`bench/*/*.rig`, bench-json's driver) are the same
  in both trees.
- **Timing.** Interleaved rounds, one run of each build per round, the
  fastest of all rounds kept (`census/census.py`). std.json: 10 rounds
  of `bench-json --time-only --reps 3`, so the fastest of 30, about
  400 ms each. tasks and net: 15 or 30 rounds; actors 30; http 6 loads
  of 3 s at 64 connections, the highest req/s kept with its run's
  latencies. Trig: 10 rounds (`census/trigtime.py`).
- **Where.** arm64 on the Mac (Apple M5, 10 cores), at `nice 19`
  (`tools/low`), with other sessions' work running (load 3 to 5), so
  only the fastest runs count. x86 on pup (Core Ultra 9 185H),
  single-threaded runs on core 6 (its sibling 7 idle), the concurrent
  benchmarks on the P-core pair 8,9, as the PROGRESS rows of 2026-10-22
  were; no other release build ran during the timing, and Trig's
  four-hourly full run did not overlap it.
- **Reading.** "N% faster/slower" is main against the reference. Within
  2% is noise. A change past 2% is bisected over the first-parent
  merges and confirmed by timing the merge and its parent.

## std.json (MB/s, the full corpus)

| file | Mac safe ref / main | Mac fast ref / main | pup safe ref / main | pup fast ref / main |
|---|---|---|---|---|
| twitter | 3572 / 3680 (3.0% faster) | 3576 / 3703 (3.6% faster) | 3112 / 2939 (**5.6% slower**) | 2726 / 3039 (11.5% faster) |
| twitterescaped | 3201 / 3206 | 3249 / 3253 | 2535 / 2376 (**6.3% slower**) | 2412 / 2699 (11.9% faster) |
| canada | 2107 / 2148 (1.9% faster) | 2277 / 2216 (**2.7% slower**) | 1329 / 1365 (2.7% faster) | 1497 / 1532 (2.3% faster) |
| citm_catalog | 4189 / 4357 (4.0% faster) | 4245 / 4357 (2.6% faster) | 3079 / 2997 (**2.7% slower**) | 2890 / 3206 (10.9% faster) |
| gsoc-2018 | 8344 / 8460 (1.4% faster) | 8327 / 8269 (0.7% slower) | 6075 / 5934 (**2.3% slower**) | 5881 / 6098 (3.7% faster) |
| github_events | 4102 / 4286 (4.5% faster) | 4117 / 4306 (4.6% faster) | 3407 / 3325 (**2.4% slower**) | 3216 / 3692 (14.8% faster) |

The Mac's first census (2026-10-22, main then before #565 and #566,
ledger) found the same: 1-4% faster, with canada fast 1.8% slower, then
within noise. Three runs here read it 2.3%, 2.7%, and 2.6% (20 rounds of
canada alone), so it is past the line.

### The regression: #538, bisected

Both slowdowns are one merge, **#538 (e071d413f, commit 20bbb0726,
"runtime: reading a List's, String's, or slice's length makes no
test")**.

- **Instructions (Mac, rig-safe, per byte, `guard.py`'s method).** The
  reference and every merge up to #537 count what guard.txt holds;
  #538 adds 3.0% on twitterescaped (9.3068 → 9.5844), 1.0% on twitter
  and 1.3% on gsoc-2018, and every later merge stays within 0.15% of it:

  | merge | twitterescaped | twitter | gsoc-2018 |
  |---|---|---|---|
  | ace79d579 (reference) | 9.3075 | 7.8329 | 3.4472 |
  | #536 cafc9b5a0 | 9.3078 | 7.8314 | 3.4471 |
  | #537 897a7a159 | 9.3068 | 7.8341 | 3.4482 |
  | **#538 e071d413f** | **9.5844** | **7.9154** | **3.4911** |
  | #539, #540, #541, #550, #555, #566, #565 | 9.5835-9.5941 | 7.9134-7.9252 | 3.4889-3.4974 |
  | c77a86b07 (main) | 9.5837 | 7.9160 | 3.4899 |

- **pup, timed (core 6, 10 rounds), #537 against #538:** safe builds
  slower on twitter (3.8%), twitterescaped (6.3%), gsoc-2018 (3.8%),
  github_events (2.9%) and citm_catalog (1.3%); fast builds faster on
  every file, by 2.2% (canada) to 14.3% (twitter). The rest of pup's
  safe gap to the reference is R4's accepted 32-byte shift (twitter
  safe 2.0%, errors-r4/accepted.md).
- **Mac canada fast, timed (12 rounds of 5):** 2291 MB/s at the
  reference, 2283 at #537, 2232 at #538 (2.6% slower), and 2225-2230
  at every later merge (2.7-2.9%). Its instruction count is the
  reference's (14.910 per byte against 14.909): `document` is 1,084
  bytes larger after #538 and the slowdown is layout inside it.

Not fixed here (the track's rule: bisect and report). #538 trades
pup's safe builds for its fast ones; whether it stays, or the length
read keeps a range fact for LLVM in safe builds, is the owner's call.

## Tasks, actors, sockets, HTTP (rig-fast)

Time per operation, as the PROGRESS rows give it.

| benchmark | Mac ref → main | pup (cores 8,9) ref → main |
|---|---|---|
| tasks spawn (per task) | 158 → 140 ns (12.9% faster) | 65 → 63 ns (3.8% faster) |
| tasks chain | 43.9 → 44.1 ns (0.6% slower) | 86 → 86 ns |
| tasks fanout (per run) | 77.2 → 77.2 ms | 309.6 → 309.3 ms |
| tasks yield | 5.9 → 5.0 ns (17.7% faster) | 22 → 22 ns (1.2% faster) |
| tasks hog (per step) | 90.8 → 70.4 us (29.0% faster) | 129.8 → 130.2 us (0.3% slower) |
| actors solo (per call) | 5.0 → 5.0 ns | 11.6 → 11.6 ns |
| actors contend | 31.2 → 30.6 ns (2.1% faster) | 14.5 → 14.5 ns |
| actors spread | 0.90 → 0.91 ns (1.9% slower) | 10.5 → 10.5 ns |
| net pingpong (per trip) | 15.29 → 14.65 us (4.3% faster) | 10.72 → 4.94 us (2.17x faster) |
| net echo | 5.91 → 5.74 us (3.0% faster) | 3.54 → 3.57 us (0.6% slower) |
| net connect (per conn) | 47.7 → 47.4 us (0.6% faster) | 26.8 → 26.3 us (1.7% faster) |
| http req/s (p50, p99) | 177,887 → 175,176 (1.5% slower; 268 → 263 us, 1641 → 1609 us) | 200,411 → 211,581 (5.6% faster; 188 → 188 us, 3441 → 3401 us) |

Mac tasks and net are from 30 rounds. An earlier 15-round run read net
pingpong 3.7% and echo 2.1% slower and tasks fanout 2.1% slower; the
30-round run reverses them (4.3% and 3.0% faster, fanout 0.0%), so they
are the Mac's load, not the change. pup's pingpong is the fix of #541
(the regression bisected to #451, records/2026-10/scheduler/).
Memory per task and per idle connection were not measured: they follow
the page and stack sizes, which no merge since the reference changed.

## Trig

Current Trig (37f9e6b) passes functions to tasks (#532), so the
reference cannot build it. The baseline uses **Trig 6191efb** (#174,
2026-10-21 15:19, the last Trig main before G2), which both compilers
accept and build, and whose output is identical under both.

### `rig check --time` of Trig (ms, the fastest of 10 per pass)

| pass | Mac ref / main | pup (core 6) ref / main |
|---|---|---|
| lex and parse | 134 / 133 | 222 / 225 |
| resolve | 1395 / 1364 (2.3% faster) | 2349 / 2367 |
| typecheck | 562 / 564 | 886 / 897 |
| storage | 930 / 951 (2.1% slower) | 1842 / 1878 (1.9% slower) |
| ownership | 225 / 224 | 358 / 359 |
| proofs | 53 / 53 | 90 / 91 |
| inlining | 34 / 35 | 60 / 60 |
| other | 20 / 20 | 46 / 47 |
| **total** | **3355 / 3344 (0.3% faster)** | **5906 / 5956 (0.8% slower)** |

The total is within noise on both. `storage` is 2% slower on both
machines, at the line; the census watches it.

### Trig's projects (`trig -p tsconfig.trig.json --noEmit`, release builds, one checker)

| project | Mac ref / main | pup (core 6) ref / main |
|---|---|---|
| ts-pattern | 0.770 / 0.722 s (6.6% faster; 0.9% fewer instructions, 1.3% fewer cycles) | 1.183 / 1.171 s (1.0% faster) |
| zod3 | 0.141 / 0.140 s (0.1% faster; 1.2% fewer instructions) | 0.231 / 0.228 s (1.4% faster) |

The Mac's ts-pattern wall time moves more than its cycles (3.05G →
3.01G); its cycles are the better reading on a loaded Mac.

## The json instruction guard

`bench/json/guard.py` on main fails: twitterescaped 2.5% above
guard.txt (9.5865 against 9.3549), the rest 0.2-1.1% above. guard.txt
(2026-10-15) matches the reference within 0.5%; the whole rise is #538
(above). Its refresh on main (`--update`) is its own PR, which accepts
#538's counts as the new baseline: merging it is the owner's decision
about #538.

## std.json's hot functions, aligned: tried, not opened

R4 (#565) moved `document`, `escaped`, and `skip_plain_ascii` 32 bytes
later on pup, with identical code, and twitter swung 2.3% slower and
citm 7% faster (errors-r4/accepted.md). Aligning each to 64 bytes would
pin its offset within a cache line, so that code placed before it could
not move it.

**How it was tried.** Rig has no way to align a function from source,
and emit decides nothing a fact does not record, so the trial patches
the emitted Zig: a `zig` first on `PATH` (census/align/zig) rewrites
the three functions of the json module as `fn ...(...) align(64) i64`
before running Zig. The addresses confirm it (Mac: `document` at
0x18900, `escaped` at 0x1a280, `skip_plain_ascii` at 0x1d5c0).

**It removes the swing.** pup, core 6, 6 rounds, #566 (U) against #565
on U (R4u), the pair of the accepted shift:

| file | R4u vs U, as built | R4u vs U, aligned |
|---|---|---|
| twitter safe / fast | 2.0% slower / 2.7% slower | 0.1% faster / 0.2% faster |
| twitterescaped safe / fast | 0.3% slower / 2.9% faster | 0.1% faster / 0.2% faster |
| citm_catalog safe / fast | 1.2% slower / 6.3% faster | 0.3% slower / 0.4% faster |
| github_events safe / fast | 0.5% faster / 7.1% faster | 0.3% faster / 0.2% faster |
| canada, gsoc-2018 | within 1.4% | within 0.1% |

**It is slower than main's placement**, so it fails std.json's rule
(never slower beyond 2%, on any file, on either machine). Aligned
against main as built:

| file | Mac safe | Mac fast | pup safe | pup fast |
|---|---|---|---|---|
| twitter | 4.8% slower | 0.4% slower | 0.5% slower | **4.9% slower** |
| twitterescaped | 0.9% slower | 0.1% faster | 0.2% faster | **2.8% slower** |
| canada | **2.4% slower** | 1.0% faster | 0.6% faster | 0.2% slower |
| citm_catalog | **7.8% slower** | 0.5% slower | 1.0% faster | **5.7% slower** |
| gsoc-2018 | **3.0% slower** | 0.1% slower | **2.4% slower** | 1.0% faster |
| github_events | **4.7% slower** | 0.5% slower | 0.7% slower | **5.4% slower** |

Alignment fixes the offset, but the best offset differs by file, build,
and machine: on pup, citm_catalog's and github_events' fast builds run
best with the functions 32 bytes past a line, where main has them since
R4, and twitter's at the line; the Mac aligns functions to 4 bytes, and
64 is a worse placement for its safe builds. No one alignment is never slower, so no
PR was opened.

**What it would take.** Even if a placement held, std cannot ask for
it: aligning needs a compiler fact (every function holding a loop, which
would move all of Trig's code too) or a marker on the function, which is
a language feature, outside this round. The census instead watches
twitter, citm, and github_events on pup, where the swing shows.

## The scripts

`census/census.py` (build and time std.json and the concurrent
benchmarks for several trees), `census/trigtime.py` (Trig's projects and
`rig check --time`), and `census/align/zig` (the alignment trial's
patch). census.md says how to run a census with them.
