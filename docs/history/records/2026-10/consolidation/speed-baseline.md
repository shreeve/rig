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

## #538: the length range in safe builds, tried

A follow-up, to give the owner data. Main (4f832692f) with #538's test
still gone, but in safe builds only `heldLen` tells LLVM the range the
test gave it, with no compare (`if (n > max_len) unreachable` under
`@setRuntimeSafety(false)`, inside `if (builtin.mode == .safe)`; the
change is [len-range.patch](len-range.patch), which `git apply` puts back
on main at 4f832692f). Fast builds are unchanged.

**Instructions (Mac, rig-safe, per byte):** below the reference on
every file but twitterescaped: twitter 7.7317, twitterescaped 9.3740
(0.7% above the reference's 9.3075), canada 15.6229, citm_catalog
7.8374, gsoc-2018 3.4508, github_events 6.9291. So the range is what
#538 cost in instructions.

**Time (MB/s, 10 rounds, fastest of 30), ref / main / range:**

| file | Mac safe | Mac fast | pup safe (core 6) | pup fast |
|---|---|---|---|---|
| twitter | 3547 / 3654 / 3477 | 3488 / 3678 / 3651 | 3027 / 2824 / 3001 | 2660 / 2927 / 2966 |
| twitterescaped | 3121 / 3183 / 3098 | 3239 / 3255 / 3256 | 2478 / 2273 / 2415 | 2363 / 2587 / 2629 |
| canada | 2085 / 2097 / 2054 | 2271 / 2189 / 2200 | 1306 / 1321 / 1332 | 1444 / 1472 / 1488 |
| citm_catalog | 4159 / 4267 / 4071 | 4120 / 4330 / 4291 | 3006 / 2877 / 3056 | 2807 / 3087 / 3101 |
| gsoc-2018 | 8191 / 8336 / 8286 | 8157 / 8262 / 8147 | 5821 / 5634 / 5784 | 5659 / 5792 / 5914 |
| github_events | 4060 / 4320 / 4089 | 4102 / 4284 / 4247 | 3331 / 3183 / 3366 | 3135 / 3544 / 3578 |

- **pup safe** comes back to within 2% of the reference on five files
  (citm 1.7% and github_events 1.1% faster than it), but twitterescaped
  stays 2.5% slower; against main the range is 0.8-6.3% faster.
- **pup fast** keeps #538's gain (0.5-2.1% above main).
- **Mac safe** loses: the range is 5.1% (twitter), 4.8% (citm_catalog),
  5.6% (github_events), and 2.1% (canada) slower than main, and twitter
  2.0% and citm_catalog 2.1% slower than the reference. Fewer
  instructions, slower: layout again.
- **Trig on pup** (current Trig 37f9e6b, release builds, core 6, 10
  rounds): ts-pattern 1.345 / 1.346 s and zod3 0.345 / 0.346 s, main /
  range; `rig check --time` total 6062 / 6101 ms (0.6% slower). No
  change.

**A trade-off, so no PR.** The range fixes pup's safe builds (but not
twitterescaped) and costs the Mac's safe builds about 5%. It is also the
assumption the owner declined on 2026-10-22 ("No LLVM assumption of a
List's length bound": undefined behavior if the invariant broke), here
limited to safe builds. The decision on #538 is the owner's.

## #538: std.json's hot loops in plain Rig, tried

The owner kept #538 on 2026-10-23 ("Yes, let's go with your
recommendation"): no length read makes a test, and std.json's hot loops
are to bring pup's safe builds back within 2% of the reference with no
range assumption, while nothing gets slower than main beyond 2%. Two
candidates came close; neither meets every bar, so no PR. Both are kept
here as patches on main at 6fe6e9369 (`git apply`).

**Where the checks came back (pup, rig-safe, `perf`).** #538 left LLVM
no range for a slice's length, so in the functions std.json keeps out of
line, which take `src` as a parameter, every `at + k` tests overflow
(13 overflow branches in `escaped`, which inlines `escape`, `unicode`
and `hex_value`, against 1 at the reference), `0 <= i < n` takes two
compares where one did, and `skip_plain_ascii` on x86_64 kept its
TIER stage's first test, `at + 8 <= s.len`, an add safe builds test,
with its five constants loaded, though TIER is 0 there. Per call that
is about ten instructions; main runs 6 to 9% more instructions than the
reference on pup (twitter 535M against 496M per 100 parses).

**A ([json-len-a.patch](json-len-a.patch)): two changes.**
`skip_plain_ascii` compiles its SWAR stage only when `TIER > 0`, and
`escaped` tests `src.len < 0 or src.len > MAX_INPUT` as it starts (the
test `document` makes, once more per escaped string): one unsigned
compare, after which LLVM knows `0 <= n <= MAX_INPUT`, so the escapes'
adds cannot overflow (3 overflow branches left in `escaped`). No range is
assumed: the test runs, and fails with `.too_large`.

**B ([json-len-b.patch](json-len-b.patch)): A, and `document`'s
whitespace after a value is skipped on each path** (after a scalar, and
after each close, `skip_space(src, i + 1)`), not at the top of the loop
where the paths join: there LLVM keeps `skip_space`'s `at < 0` test, and
tail-duplicates it, since it cannot see `0 <= i` through the join.

**Time (MB/s, 15 rounds of `--reps 3`, the fastest of 45; ref
ace79d579 / main 6fe6e9369 / candidate; then the candidate against main;
against the reference). pup on core 6, its sibling idle; the Mac at
`nice 19` with load 5 to 33.**

A:

| file | pup safe | pup fast | Mac safe | Mac fast |
|---|---|---|---|---|
| twitter | 3098 / 2925 / 3047 (4.2% faster; 1.6% slower) | 2707 / 3030 / 3238 (6.9% faster; 19.6% faster) | 3521 / 3619 / 3581 (1.1% slower; 1.7% faster) | 3519 / 3668 / 3668 (same; 4.2% faster) |
| twitterescaped | 2557 / 2363 / 2554 (8.1% faster; 0.1% slower) | 2427 / 2694 / 2737 (1.6% faster; 12.8% faster) | 3172 / 3166 / 3209 (1.4% faster; 1.2% faster) | 3221 / 3238 / 3225 (0.4% slower; 0.1% faster) |
| canada | 1331 / 1359 / 1327 (**2.4% slower**; 0.3% slower) | 1489 / 1520 / 1478 (**2.8% slower**; 0.7% slower) | 2089 / 2133 / 2048 (**4.0% slower**; 2.0% slower) | 2262 / 2198 / 2188 (0.5% slower; 3.3% slower) |
| citm_catalog | 3039 / 2990 / 3074 (2.8% faster; 1.2% faster) | 2867 / 3184 / 3170 (0.4% slower; 10.6% faster) | 4202 / 4330 / 4252 (1.8% slower; 1.2% faster) | 4158 / 4284 / 4336 (1.2% faster; 4.3% faster) |
| gsoc-2018 | 6056 / 5895 / 6067 (2.9% faster; 0.2% faster) | 5881 / 6061 / 6525 (7.7% faster; 11.0% faster) | 8320 / 8372 / 8394 (0.3% faster; 0.9% faster) | 8253 / 8173 / 8175 (same; 0.9% slower) |
| github_events | 3417 / 3326 / 3515 (5.7% faster; 2.9% faster) | 3202 / 3684 / 3762 (2.1% faster; 17.5% faster) | 4079 / 4257 / 4228 (0.7% slower; 3.7% faster) | 4081 / 4240 / 4237 (0.1% slower; 3.8% faster) |

B:

| file | pup safe | pup fast | Mac safe | Mac fast |
|---|---|---|---|---|
| twitter | 3096 / 2933 / 3119 (6.3% faster; 0.7% faster) | 2707 / 3041 / 3229 (6.2% faster; 19.3% faster) | 3458 / 3549 / 3317 (**6.5% slower**; 4.1% slower) | 3437 / 3575 / 3546 (0.8% slower; 3.2% faster) |
| twitterescaped | 2557 / 2377 / 2584 (8.7% faster; 1.1% faster) | 2412 / 2686 / 2695 (0.3% faster; 11.7% faster) | 3105 / 3094 / 3143 (1.6% faster; 1.2% faster) | 3186 / 3154 / 3193 (1.2% faster; 0.2% faster) |
| canada | 1328 / 1361 / 1379 (1.3% faster; 3.8% faster) | 1493 / 1525 / 1522 (0.2% slower; 1.9% faster) | 2073 / 2093 / 2058 (1.7% slower; 0.7% slower) | 2265 / 2163 / 2219 (2.6% faster; 2.0% slower) |
| citm_catalog | 3058 / 2991 / 3088 (3.2% faster; 1.0% faster) | 2856 / 3200 / 3228 (0.9% faster; 13.0% faster) | 4146 / 4209 / 4006 (**4.8% slower**; 3.4% slower) | 4095 / 4264 / 4223 (1.0% slower; 3.1% faster) |
| gsoc-2018 | 6064 / 5942 / 6155 (3.6% faster; 1.5% faster) | 5936 / 6109 / 6488 (6.2% faster; 9.3% faster) | 8097 / 8214 / 7933 (**3.4% slower**; 2.0% slower) | 8037 / 8059 / 8037 (0.3% slower; same) |
| github_events | 3422 / 3329 / 3549 (6.6% faster; 3.7% faster) | 3231 / 3701 / 3691 (0.3% slower; 14.2% faster) | 3993 / 4199 / 3877 (**7.7% slower**; 2.9% slower) | 4006 / 4217 / 4157 (1.4% slower; 3.8% faster) |

- **pup safe**, the goal: A is within 2% of the reference on every file
  (twitter 1.6% slower the worst), and B is faster than it on every file
  (0.7% to 3.8%).
- **A misses on canada**: 2.4% (pup safe), 2.8% (pup fast), and 1.2-4.4%
  (Mac safe, three runs) slower than main. A does not touch canada's
  code (no escapes, few strings); `document` is 44 bytes larger on the
  Mac, and LLVM duplicates `skip_space`'s sign test into the paths that
  join after a value. In pup's fast build canada runs 0.9% *fewer*
  instructions than main and about 2% more cycles: placement.
- **B misses on the Mac's safe builds**: 3.4% to 7.7% slower than main on
  four files, with fewer instructions than main on all six (guard.py:
  twitter 7.8658 against 7.9172, citm_catalog 8.0175 against 8.0343).
  The Mac was loaded (load 18), but the sign matches every Mac run of
  a `document` change here.

**Also tried.** `document` testing `n < 0 or n > MAX_INPUT` itself
(LLVM then knows the range wherever `document` inlines): pup's
instructions at the range patch's or below, but the Mac's safe builds
2-5% slower than main (twitter, canada, citm_catalog, github_events),
as with the range patch. `skip_space` with no sign guard (its loop's
flag tests `0 <= i`): pup 4-10% fewer instructions than main, every
safe build 1.6-5.3% faster than the reference (citm_catalog's fast build
2.1% slower than main), but on the Mac LLVM then inlines `number` into
`document` (286 more instructions in it) and four safe builds run
5.8-14.8% slower than main (citm_catalog 4295 → 3661 MB/s). `called fun
number` against that: canada 9.5% more instructions on the Mac.

**Why the gap persists.** The checks the proofs cannot remove are in the
out-of-line functions: the pass proves from facts within one body, and
`escaped`, `skip_plain_ascii`, and the rest start with no fact about
their `at`, and their early returns (`return at if at < 0`) make none
(the proof uses a guard on its true edge only). A real test of the
length per call fixes that on x86 (A, B). What is left is placement:
every change to `document`'s code moves the Mac's safe builds by 2-8%
and canada on pup by 2-3%, either way, with the instruction counts
falling. No change here is a net win with nothing slower than main
beyond 2%; whether to take A (pup's safe builds back at the reference;
canada at the line) is the owner's call.

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

**Dropped.** The alignment is dropped: aligned, citm_catalog's safe
build on the Mac is 7.8% slower than main's (4357 → 4016 MB/s), and
pup's fast builds up to 5.7% slower; and std has no way to ask for a
function's alignment without a new language feature.

## After the night (2026-10-23)

The round's merges, #571 to #595, timed alone: main at e03bceffd
against 463de5898, main before the round. Main moved on to 5134b26fc
(#593, whose emitted Zig is byte-identical, and #597, tests) during the
run; e03bceffd was timed on both machines. Both trees hold #538, so its
safe-build cost on pup is in neither column. Method as above: std.json
10 rounds of `--reps 3`, the fastest of 30; Trig 37f9e6b, release
builds, `--singleThreaded` (one checker, as in the baseline), 10
rounds. The Mac ran under `tools/low` at a load of 2 to 4; pup on core
6, its sibling idle, at a load under 2, with no build or Trig run beside
it (a Trig run that overlapped a light gate's build was discarded and
rerun).

- **std.json, Mac:** safe 0.5% slower to 0.5% faster, fast 0.2% slower
  to 0.3% faster, on every file.
- **std.json, pup:** safe 1.1% slower (github_events) to 0.2% faster,
  fast 0.6% slower to 0.2% faster; twitter, citm_catalog, and
  github_events, the files R4's placement swing moves, all within 1.1%.
- **Trig:** ts-pattern 0.712 / 0.716 s and zod3 0.154 / 0.155 s on the
  Mac (the same instructions); 1.258 / 1.264 s and 0.248 / 0.249 s on
  pup.

Every row is within 2%, so nothing was bisected: the round slowed none
of these measures.

## The scripts

`census/census.py` (build and time std.json and the concurrent
benchmarks for several trees), `census/trigtime.py` (Trig's projects and
`rig check --time`), and `census/align/zig` (the alignment trial's
patch). census.md says how to run a census with them.
