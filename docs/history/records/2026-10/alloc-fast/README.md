# The allocator's fast path (2026-10-24)

Committee expert A2 (beat-tsrs) found that each call of the release
allocator took about 48 instructions to allocate and 55 to free, over
about 11M calls on Trig's ts-pattern, against mimalloc's 15 to 20. Two
items were built and measured apart, then together, against Rig main
`99dcccf13` (which holds the prefault fix, #674):

1. **The fast path** (`i1`, kept): `alloc` and `free` serve a small
   block of up to 1024 bytes, aligned to 8 or less, from and to the
   running thread's free list with no call, and leave the rest to
   `allocSlow` and `freeSlow`.
2. **The small-block remaps** (`i2`, dropped): `reallocSlice` judged
   inline (`smallInPlace`) whether a small block keeps its class, and
   moved one that does not without asking `remap`, whose `resize` and
   `remap` calls a growing List or String always had refused. The patch
   is `item2-remap.patch`.

## The fast path and its proofs

On x86-64 (Trig's build on pup) `alloc` is now 23 instructions to its
return and `free` 26, each one function with the frame pointer pushed
and popped and no call; before, `alloc` pushed four registers, called
`heap`, and checked the owner and the bound on the way.

The thread's heap is a thread-local (`my_heap`), and `heap` is never
inlined because a fiber may resume on another thread after a switch,
and a compiler may keep a thread-local's address within a function.
The fast paths read `my_heap` themselves, and are never inlined
either: the read is made in their own frame, never in a caller's that
spans a switch, and between it and their last use of the heap they call
nothing that could switch. The slow paths still go through `heap`.

Two checks the fast paths no longer make, each proved in a comment in
`src/alloc.zig`:

- **The owner check** (`mustOwn`, in safe builds): `my_heap` is written
  only by `newHeap`, which sets the heap's `owner` to the running thread
  in the same call, and by `threadExit`, to null, and `owner` is written
  nowhere else. A heap read from `my_heap`, on the thread that runs on
  until the read is used, is therefore that thread's. The runtime's own
  tests keep the check on the fast paths (`builtin.is_test`), so the
  scheduler's test of fibers that move between threads (`sched.zig`, "a
  fiber that allocates, moves to another worker, and allocates again")
  would still catch a fast path that used a stale heap.
- **The bound on `free[c]`**: the class is a `Class` (`u6`), read from
  `small_table`, whose entries are classes (each below `class_count`,
  44, asserted at compile time to be at most 64); `free` has 64 slots,
  so the type proves the bound. The other per-class arrays keep 44
  slots and their checks, on the slow paths.

The alignment check on the freed pointer and the null check on its
segment stay: two instructions each, never taken.

## Trig on pup

Trig main `ffdb2a3` (src/ with tools/trig/main.rig), built release
(Zig's safe mode, as Trig ships) by each Rig on a release slot
(`build.sh`). `measure.py`: ts-pattern and zod3, `trig -p
tsconfig.trig.json --noEmit`, at `--checkers 1` on core 6 (7 idle) and
at the default checkers unpinned; the four builds interleaved, order
reversed every other round; fastest wall of 10 with its user time,
fewest user instructions (perf, P and E cores summed), fewest page
faults, largest RSS. Two sets (`trig-1.md`, `trig-2.md`); pup ran other
sessions' release builds on its slots (cores 0, 1, 2, 5, 10, 11)
throughout.

At one checker, the instructions:

| project | base | i1 | i2 | both |
|---|---:|---:|---:|---:|
| ts-pattern | 11,703.8M | 11,491.0M (1.8% fewer) | 11,662.3M (0.35% fewer) | 11,448.5M (2.2% fewer) |
| zod3 | 2,134.5M | 2,090.97M (2.0% fewer) | 2,119.8M (0.69% fewer) | 2,078.7M (2.6% fewer) |

(the fewest of either set; the two sets agree within 0.1%). Item 1
saves 213M on ts-pattern, as A2 estimated (250 to 350M); item 2 saves
41M (A2: 50 to 70M, with a fused grow call not built).

The walls, fastest of 10 in each set (s):

| project | checkers | base | i1 | i2 | both |
|---|---|---:|---:|---:|---:|
| ts-pattern | 1 | 1.242 / 1.236 | 1.233 / 1.243 | 1.238 / 1.265 | 1.244 / 1.252 |
| ts-pattern | all | 0.529 / 0.524 | 0.521 / 0.516 | 0.521 / 0.509 | 0.523 / 0.508 |
| zod3 | 1 | 0.234 / 0.232 | 0.237 / 0.234 | 0.230 / 0.232 | 0.232 / 0.229 |
| zod3 | all | 0.149 / 0.164 | 0.159 / 0.159 | 0.161 / 0.157 | 0.168 / 0.159 |

Page faults (37.5K and 8.5K at one checker) and peak RSS (344 MB and 93
MB) are the same for every build. A third set of 20 rounds at one
checker (`cycles.py`, `trig-cycles.md`) gives fastest walls of 1.250,
1.251, 1.246, 1.241 s on ts-pattern and 0.235, 0.230, 0.231, 0.229 s on
zod3; user cycles there spread by 10% from run to run, too much to
read. The saving is about 2% of the instructions but cheap ones (loads
and stores that hit), and no wall moves beyond the run-to-run spread,
about 1%.

## Benchmarks on pup (cores 6, 7)

`bench.sh`: bench/tasks, actors, net and http (rig-fast) and bench/json
(rig-safe and rig-fast), each Rig's own copy, the four builds
interleaved, 3 rounds (`benches-pup.log`, summarized by `benchsum.py`
and `jsonsum.py`). Best of 3:

| bench | case | base | i1 | i2 | both |
|---|---|---:|---:|---:|---:|
| tasks | spawn ns/task | 67 | 66 | 67 | 67 |
| tasks | chain ns/task | 92 | 93 | 95 | 95 |
| tasks | fanout ms/run | 321.3 | 324.0 | 340.1 | 325.7 |
| tasks | yield ns | 25 | 25 | 25 | 25 |
| tasks | hog us/step | 141.92 | 141.98 | 145.68 | 141.92 |
| tasks | memory KiB/task | 4.6 | 4.6 | 4.6 | 4.6 |
| actors | solo ns/call | 13 | 13 | 13 | 12 |
| actors | contend ns/call | 16 | 16 | 16 | 15 |
| actors | spread ns/call | 11 | 11 | 11 | 11 |
| net | pingpong us/trip | 5.58 | 5.59 | 5.67 | 5.35 |
| net | echo us/trip | 4.15 | 4.06 | 4.11 | 4.09 |
| net | connect us/conn | 31.8 | 30.96 | 31.76 | 31.46 |
| http | req/s | 183751 | 185600 | 183010 | 184605 |
| http | p50 / p99 us | 204 / 3495 | 207 / 3492 | 223 / 3486 | 217 / 3480 |

Item 1 moves each within 1.1% (chain 1.1% slower, fanout 0.8% slower,
echo 2.2% faster, connect 2.6% faster, http 1.0% more requests).

std.json, MB/s, best of 3 rounds of 5 (rig-safe / rig-fast):

| file | base | i1 | both |
|---|---:|---:|---:|
| twitter | 2703 / 2876 | 2723 / 2844 | 2667 / 2792 |
| twitterescaped | 2277 / 2421 | 2289 / 2436 | 2188 / 2433 |
| canada | 1186 / 1314 | 1189 / 1310 | 1191 / 1311 |
| citm_catalog | 2727 / 2796 | 2703 / 2799 | 2744 / 2842 |
| gsoc-2018 | 5289 / 5723 | 5345 / 5790 | 5248 / 5725 |
| github_events | 3116 / 3348 | 3054 / 3298 | 3145 / 3303 |

The benchmark parses into one reused document, so its timed loop does
not allocate. github_events read 2.0% slower for i1 in safe mode; under
perf on core 6 the base and i1 programs retire the same instructions
(9,499M to 9,510M, and 9,516M to 9,524M, for 20,000 parses) and take
423 to 430 ms either way, so the gap is noise.

## std.json on the Mac

`tools/low`, 1-minute load 3.6 to 6.0 during the run (above the
brief's 4 at times), builds interleaved, best of 10 rounds of 5
(`json-mac.log`):

| file | base | i1 | i1 vs base |
|---|---:|---:|---|
| twitter | 3632 / 3705 | 3625 / 3702 | 0.2% / 0.1% slower |
| twitterescaped | 3247 / 3271 | 3251 / 3272 | same |
| canada | 2076 / 2229 | 2081 / 2226 | 0.2% faster / 0.1% slower |
| citm_catalog | 4328 / 4354 | 4299 / 4364 | 0.7% slower / 0.2% faster |
| gsoc-2018 | 8525 / 8283 | 8536 / 8287 | same |
| github_events | 4309 / 4304 | 4305 / 4312 | same |

A first run of 5 rounds of 3 (`json-mac-first.log`) read every build
0.3 to 4.9% slower than base in the order they ran, the drift of a
machine that was settling; the longer run shows none.

## Verdicts

- **Item 1, kept.** About 75 lines; 1.8% fewer instructions on
  ts-pattern and 2.0% on zod3 at one checker, past the bar of 1% fewer
  single-thread instructions; nothing slower beyond 1.1%.
- **Item 2, dropped.** About 25 lines for 0.35% fewer instructions on
  ts-pattern (0.69% on zod3), under the 1% bar, and no wall it moves.
  Its savings stack on item 1's (both: 2.2% and 2.6%), so it may be
  worth taking with A2's fused grow call, if that brings it past the
  bar.

## Gates

Rig's full suite (`tools/heavy swarm test/rig.rip all -q`) green on the
Mac, with both items and with item 1 alone; `zig build test` on pup in
debug, safe and fast.
