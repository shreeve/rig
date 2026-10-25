# Faulting ahead by the heap that does the work (2026-10-24)

Trig found that `prefault` never ran in its runs: strace of `trig
--checkers 1` on ts-pattern showed one `MADV_POPULATE_WRITE`, the first
1 MiB, and none after. Trig's `main` is a fiber, so `std.file.read` runs
on the blocking pool; the pool thread allocated the file buffer, made a
second heap, and the rule then in place ("while the program has one
heap", `heaps_made`) turned faulting ahead off for good.

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
