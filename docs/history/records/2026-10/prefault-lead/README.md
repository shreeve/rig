# Faulting ahead by the heap that does the work (2026-10-24)

Trig found that `prefault` never ran in its runs: strace of `trig
--checkers 1` on ts-pattern showed one `MADV_POPULATE_WRITE`, the first
1 MiB, and none after. Trig's `main` is a fiber, so `std.file.read` runs
on the blocking pool; the pool thread allocated the file buffer, made a
second heap, and the rule then in place ("while the program has one
heap", `heaps_made`) turned faulting ahead off for good.

Both decisions here were timed with main first after every switch.
Timed again with the order rotated (2026-10-31), zod3's gains are level
and both rules stay; [timing-audit](../timing-audit/README.md) has the
numbers on today's main.

## The rule

A heap faults in ahead while it leads (`leads` in `src/alloc.zig`): it
has taken from the system, in segments and in large blocks mapped or
grown by `mremap`, at least four times what every other heap has
together. Each heap counts what it takes (`Heap.taken`) and adds it to
one program-wide total (`taken_all`), both on paths that already make a
system call. A program on one thread always leads; a pool thread that
reads files, or a worker that barely allocates, does not stop the heap
beside it; in a program of several busy threads none leads, so each
faults lazily, as before. A new heap's first segment counts before it
asks, so it leads only a program whose other heaps have taken a quarter
of it or less: a worker that starts does not fault in its first stretch.

## Trig on pup

Trig main `a16e538` (src/ with tools/trig/main.rig), built by Rig main
`12b0bdc88` and by the change. ts-pattern and zod3, `trig -p
tsconfig.trig.json --noEmit`, at `--checkers 1` pinned to core 6 (7
idle) and at the default (4 checkers) unpinned; interleaved, fastest
wall of 10 (with its user time), least sys time, fewest page faults
(perf's `page-faults`: traps; `MADV_POPULATE_WRITE` pages are counted
by the kernel's `min_flt` but are not traps), largest RSS
(`pfmeasure.py`). pup ran other sessions' builds on the release slots
throughout. Two sets:

| project | checkers | build | wall s | sys s | user s | page faults | RSS MB |
|---|---|---|---:|---:|---:|---:|---:|
| ts-pattern | 1 | main | 1.406 / 1.374 | 0.117 / 0.109 | 1.278 / 1.264 | 81013 | 328 |
| ts-pattern | 1 | change | 1.367 / 1.346 | 0.099 / 0.101 | 1.256 / 1.231 | 37769 | 342 |
| ts-pattern | 4 | main | 0.562 / 0.572 | 0.132 / 0.147 | 1.433 / 1.512 | 94536 | 381 |
| ts-pattern | 4 | change | 0.539 / 0.556 | 0.154 / 0.155 | 1.376 / 1.463 | 89658 | 382 |
| zod3 | 1 | main | 0.268 / 0.257 | 0.026 / 0.020 | 0.233 / 0.237 | 19688 | 88 |
| zod3 | 1 | change | 0.250 / 0.247 | 0.027 / 0.026 | 0.223 / 0.214 | 8549 | 93 |
| zod3 | 4 | main | 0.168 / 0.176 | 0.050 / 0.060 | 0.341 / 0.343 | 33057 | 140 |
| zod3 | 4 | change | 0.171 / 0.155 | 0.041 / 0.053 | 0.342 / 0.341 | 28685 | 142 |

At one checker ts-pattern runs 2.1 to 2.9% faster and zod3 4.0 to 7.2%
faster, with 53% and 57% fewer page faults and 4% and 6% more RSS. At
four checkers the heap that parses leads until the checkers' heaps
grow, so faulting ahead covers the serial phase only; the walls move
within the run-to-run spread (ts-pattern 2.9 to 4.3% faster, zod3 1.8%
slower to 13% faster). An earlier set timed with `/usr/bin/time` (10 ms
sys resolution) read ts-pattern at four checkers 3.9% slower, so the
four-checker numbers are noise either way.

strace (`-e trace=madvise`) counts `MADV_POPULATE_WRITE` calls on
ts-pattern: main 1 at one checker and 1 at four; the change 274 at one
checker and 101 at four, each on one thread.

## The many-thread protection

`bench/tasks` and `bench/http` (rig-fast), pinned to cores 6 and 7,
main and the change interleaved, 3 rounds (`benches.log`). Best of 3:

| bench | main | change |
|---|---:|---:|
| spawn | 65 ns/task | 65 ns/task |
| chain | 92 ns/task | 92 ns/task |
| fanout | 321.8 ms/run | 325.6 ms/run |
| yield | 25 ns | 25 ns |
| hog | 142.72 us/step | 142.06 us/step |
| memory | 4.6 KiB/task | 4.6 KiB/task |
| http req/s | 186013 (mean 178050) | 181707 (mean 177890) |
| http p50 / p99 | 223 / 3490 us | 208 / 3497 us |

Both faulted in ahead exactly as main does: strace counts one
`MADV_POPULATE_WRITE` in `bench/tasks` and one in the http server
under 2 s of load, for both builds. The http server's best-of-3 is 2.3%
apart, its means 0.1%; its rounds ran 173K to 186K for either build.

## Trig's teardown (ts-pattern, one checker, core 6)

`teardown.py` and strace `-ttt -T`. Trig drops its program, then writes
its diagnostics (one `writev` of 190 KB), then exits. From the last
output to the process's end takes 7 to 10 ms, 0.5 to 0.6% of the wall:
0.1 to 0.2 ms in the process (to `exit_group`), and the rest the
kernel freeing the address space. The drops before the output start
about 21 to 23 ms before `exit_group`: 167 `munmap` calls (35 GB of
address space, mostly the reservations: 4.3 GB, 3.0 GB, and a 403 MB
block), 12.7 to 14.8 ms inside the calls under strace, which slows each
call. All of it, from the first drop's `munmap` to the end, is about 30
ms of a 1.54 to 1.61 s traced run, about 2%. The change moves none of
it (main 9.1 to 9.9 ms from the last output to the end, the change 9.5
to 10.3).

# Faulting ahead by every large heap (2026-10-25)

At four checkers none of Trig's heaps leads: four checker heaps fill
their segments densely, and all faulted lazily, 91K page faults on
ts-pattern. A heap now also faults in ahead once it has taken from the
system two segments' worth, 8 MB (`prefault_big`, `faultsAhead` in
`src/alloc.zig`), whatever the others have taken.

## Where the line falls

A probe build logged each heap's `taken` as it crossed each step
(`heaps.sh`; the probe read `RIG_PF_MB` and `RIG_PF_LOG` from the
environment and is not in the change). Trig at four checkers, 16 MB
steps: ts-pattern's heaps reach 112, 66, 49 and 32 MB, zod3's 48, 17
and 17 (a heap under 16 MB logs nothing). Every bench heap on pup, 4 MB
steps, stays at its first segment: `bench/tasks` 15 heaps of 4 MB,
`tasks many` 2, `bench/actors` 22, `bench/net` 22, and the http server
66 heaps over a whole `bench-http` run, its idle connections among
them. So two segments separates them: a checker's heap passes it early,
and a server's or a task program's workers never reach it.

The threshold swept on the probe trig at four checkers (`sweep.py`,
fastest of 10, pup at load 6 to 7 from other sessions; 0 is main's
rule):

| project | MB | wall s | sys s | user s | page faults | RSS MB |
|---|---:|---:|---:|---:|---:|---:|
| ts-pattern | 0 | 0.499 | 0.158 | 1.227 | 91667 | 382 |
| ts-pattern | 8 | 0.471 | 0.119 | 1.208 | 51437 | 402 |
| ts-pattern | 12 | 0.463 | 0.134 | 1.203 | 53153 | 401 |
| ts-pattern | 16 | 0.484 | 0.139 | 1.246 | 56502 | 400 |
| ts-pattern | 32 | 0.491 | 0.143 | 1.264 | 67278 | 399 |
| ts-pattern | 64 | 0.521 | 0.153 | 1.366 | 83506 | 392 |
| zod3 | 0 | 0.162 | 0.049 | 0.314 | 30871 | 142 |
| zod3 | 8 | 0.162 | 0.044 | 0.316 | 20069 | 150 |
| zod3 | 12 | 0.164 | 0.055 | 0.312 | 22540 | 149 |
| zod3 | 16 | 0.161 | 0.063 | 0.311 | 26768 | 147 |
| zod3 | 32 | 0.165 | 0.055 | 0.316 | 28248 | 144 |
| zod3 | 64 | 0.165 | 0.055 | 0.328 | 30893 | 142 |

64 MB, the proposal's starting point, saves 9% of ts-pattern's faults
and none of zod3's: each heap faults its first 64 MB lazily, and only
two of ts-pattern's heaps pass it. 8 MB saves the most, for 5% more
peak memory.

## Trig on pup

Trig main `8e2f21f` (src/ with tools/trig/main.rig), built by Rig main
`c2639a40f` and by the change, `pfmeasure.py` as above (one checker on
core 6, four unpinned), two sets: 10 rounds at load 2.1 to 2.6, and 20
rounds at load 2.9 to 3.8, from other sessions' work.

| project | checkers | build | wall s | sys s | user s | page faults | RSS MB |
|---|---|---|---:|---:|---:|---:|---:|
| ts-pattern | 1 | main | 1.244 / 1.248 | 0.090 / 0.082 | 1.150 / 1.130 | 44545 | 342 |
| ts-pattern | 1 | change | 1.280 / 1.232 | 0.095 / 0.095 | 1.166 / 1.123 | 42764 | 342 |
| ts-pattern | 4 | main | 0.522 / 0.515 | 0.141 / 0.153 | 1.371 / 1.357 | 91389 | 383 |
| ts-pattern | 4 | change | 0.524 / 0.515 | 0.157 / 0.130 | 1.378 / 1.327 | 51406 | 402 |
| zod3 | 1 | main | 0.251 / 0.243 | 0.024 / 0.023 | 0.216 / 0.214 | 11051 | 93 |
| zod3 | 1 | change | 0.239 / 0.233 | 0.021 / 0.024 | 0.206 / 0.208 | 9255 | 93 |
| zod3 | 4 | main | 0.170 / 0.162 | 0.056 / 0.054 | 0.336 / 0.333 | 30813 | 142 |
| zod3 | 4 | change | 0.160 / 0.155 | 0.057 / 0.056 | 0.311 / 0.306 | 20019 | 150 |

At four checkers ts-pattern takes 44% fewer page faults and zod3 35%
fewer, for 5.0% and 5.6% more peak memory (402 MB rather than 383, 150
rather than 142). zod3 runs 4 to 6% faster with 7 to 8% less user time;
ts-pattern's wall is unchanged (0.4% slower, then equal) with 0.5 to 2%
less user time, and its sys time moves within the spread (12% less in
one set, 11% more in the other). At one checker ts-pattern is within
the spread (2.9% slower, then 1.3% faster), with 4% fewer faults; zod3
takes 16% fewer and runs 4 to 5% faster.

strace (`-f -e trace=madvise`) counts `MADV_POPULATE_WRITE` by thread.
ts-pattern at four checkers: main 100 calls, all on one thread; the
change 371, on five threads (205, 63, 56, 41, 6). zod3 at four: main
84 on one; the change 198 on four (129, 25, 23, 21). At one checker,
ts-pattern 247 and 261, zod3 126 and 141, each on one thread.

## The benches

`bench/tasks`, `actors`, `net` and `http` (rig-fast) on cores 6 and 7,
main and the change interleaved (`benches-large.sh`,
`benches-large.log`, at load 3.2 to 4.4; five more rounds of `tasks` at
load 3.9 to 5.4). Best of 3 (`tasks`, of 8):

| bench | main | change |
|---|---:|---:|
| spawn | 63 ns/task | 63 ns/task |
| chain | 92 ns/task | 91 ns/task |
| fanout | 309.8 ms/run | 310.8 ms/run |
| yield | 24 ns | 24 ns |
| hog | 133.42 us/step | 134.09 us/step |
| memory | 4.6 KiB/task | 4.6 KiB/task |
| actors solo / contend / spread | 12 / 15 / 11 ns/call | 13 / 16 / 11 ns/call |
| net pingpong / echo | 5.38 / 4.02 us/trip | 5.33 / 4.04 us/trip |
| net connect | 30.32 us/conn | 30.23 us/conn |
| http req/s | 188786 | 188856 |
| http p50 / p99 | 204 / 3444 us | 206 / 3480 us |

`pfcount.sh` counts `MADV_POPULATE_WRITE` in each, under strace: one in
`tasks`, `actors` and `net`, eight in `tasks many`, and one in the http
server under 64 connections for 2 s, the same for main and the change.
No bench heap reaches two segments, so the change runs the benches'
code as main does; actors' 1 ns steps are the timer's resolution.

The unit tests passed on pup in Debug, ReleaseSafe and ReleaseFast.
