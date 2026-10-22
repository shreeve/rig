# The worker's fields apart by cache line (2026-10-22)

The follow-up to wake-fix.md's open finding: after #541, `bench/tasks`'
`yield` was slower (Mac 6 to 9 ns, pup 24 to 27 ns) from the `Worker`
struct's layout, not its logic.

## Cause
- Zig places an auto-layout struct's fields in any order (by alignment, not as declared). Main's `Worker` was 2336 bytes at 16-byte alignment: not a multiple of 128, so worker i's last line was worker i+1's first.
- That shared line held worker i's `tick`, `lifo_streak`, `woken`, `servicing`, `searching` and worker i+1's `current`, `after`, `next_sleeper`, `polled_at`, and its first ring slots: fields both workers write at every switch.
- Main's line 16 held `ring.head`, `ring.tail`, and `lifo` (which thieves read and take from) beside `free` and `timers`; line 17 held `sp` and the stats beside `pinned` and the poller (which other threads lock), and the watcher's `watch_mark`.
- #541's two fields moved the boundary, which is why "main with the two fields added, unused" was as slow.

## Layout (src/sched.zig, `Worker`, `apart`)
- The fields only the worker's thread touches fill one cache line (123 bytes: `sp`, `current`, `after`, the free lists, `returned`, `tick`, `polled_at`, `servicing`, `searching`, `rng`, the stats).
- Every other field is of a type that begins a span of `apart` bytes and fills it, so field order cannot matter: `ring` (slots aligned; `head` and `tail` share the line after them), `lifo: Padded(?*Fiber)`, `poller`, `timers`, `pinned` (each type's first field aligned), and `sleep: Sleep` (`woken`, `idle`, `due`, `slept`, `watch_mark`, `next`, `thread`). `Padded(T)` replaces `Flag` (`waiting`).
- `apart` is `std.atomic.cache_line` (128) on x86-64, and 256 on Apple's cores (below). `Worker` is 2944 bytes on pup, 3840 on the Mac.
- A unit test checks it: the own fields within one line, every other field aligned to `apart` and whole spans, the size a multiple of `apart`.

## Variants (own driver: interleaved, best of N, ns per op)
- `pad`: main plus `align(cache_line)` on one field, so `Worker` is 128-aligned and no line spans two workers. One line of source.
- `grp`: own fields (two lines), ring with `head` and `tail` each on its own line, `lifo`, poller, timers, pinned, `Sleep`, each on lines of its own.
- `grpb`: `grp` with `head` and `tail` sharing a line. `grpc`: `grpb` with `thread` in `Sleep`, so the own fields fit one line.
- `final`: `grpc` with every span `apart` bytes: identical to `grpc` on x86-64.

pup, cores 8,9 (two hyperthreads of one P-core), 15 runs:

| | main | pad | grp | grpb | grpc |
|---|---|---|---|---|---|
| spawn | 67.98 | 63.20 | 63.56 | 63.50 | 63.33 |
| chain | 86.09 | 85.80 | 86.45 | 85.63 | 85.62 |
| fanout (ms) | 309.8 | 309.8 | 309.5 | 309.4 | 309.6 |
| yield | 24.94 | 22.06 | 22.55 | 22.19 | 22.04 |
| actors solo | 11.64 | 11.35 | | 11.61 | 11.61 |
| actors contend | 14.57 | 14.27 | | 14.51 | 14.63 |

pup, cores 6,8 (two P-cores), 11 runs: yield main 32.06, pad 20.42, grpb 20.02, grpc 19.93; spawn 75.63, 58.48, 58.70, 59.91; fanout 299.9, 296.4, 296.7, 296.4 ms.

- On pup every layout fixes it, within 2% of one another, except actors `solo` on cores 8,9, where `pad` is 2.5% faster than all the others, main included (likely code placement).
- `grp` (head and tail on separate lines) was 2% slower on yield than `grpb`.
- pingpong, echo, connect, http on pup cores 8,9: every variant within 1% of main, but `grpb` echo 2.1% slower in one run of 9.

## The Mac: 256 bytes apart
On the Mac, `grpc` was slower than `pad` and no faster than pre-#541 (yield best, same runs):

| run | main | pre-#541 | pad | grpc | shifted grpc |
|---|---|---|---|---|---|
| 30 reps | 9.27 | 6.08 | 5.24 | 6.91 | |
| 20 reps | | 5.88 | 5.12 | 6.62 | 5.61 to 5.76 (sh1, sh2, sh3) |
| 20 reps | | 5.71 | 5.17 | 6.49 | 5.56 (sh1), 5.57 (g256) |

- `sh1` to `sh3` add one to three unused padded lines to `grpc`; `g256` aligns only `Sleep` to 256. Each puts the worker's own line 256 bytes from the next worker's ring, where `grpc` (23 lines a worker) put it beside it for every other worker: a store to the neighboring 128-byte line slowed it. So `apart` is 256 on Apple's cores.
- Coloring fiber stack tops (16 offsets, 128 bytes apart) changed nothing for main, `pad`, or `grpc`: stack-top cache sets are not the cause.
- `pad` stays 5-15% faster than `final` on the Mac's yield (25 runs: `pad` 5.35, `final` 5.80, pre-#541 6.24): within what code placement moves on Apple cores, and `pad` leaves the owner's hot lines beside the ring's ends, the run-next slot, the poller, pinned queue, and watch mark, which other workers write. The Mac load was 3 to 15 throughout (other sessions' suites), so Mac numbers are noisy.

## Before and after (the commit's own builds)
Bench scripts' cells; rows in each PROGRESS.md. pup pinned to cores 8,9; the Mac's tasks row from a 40-run interleaved best.

| | Mac main | Mac after | pup main | pup after |
|---|---|---|---|---|
| spawn | 98 ns | 97 ns | 69 ns | 64 ns |
| chain | 44 ns | 44 ns | 86 ns | 86 ns |
| fanout | 78.5 ms | 78.8 ms | 309.7 ms | 309.7 ms |
| yield | 8 ns (7.51) | 6 ns (5.61) | 25 ns (24.95) | 22 ns (22.06) |
| hog | 78.62 us | 73.71 us | 129.49 us | 129.76 us |
| pingpong | 14.81 us | 14.95 us | 4.87 us | 4.86 us |
| echo | 5.91 us | 5.92 us | 3.57 us | 3.62 us |
| connect | 48.60 us | 49.78 us | 26.48 us | 27.01 us |
| actors solo / contend / spread | 5.1 / 32 / 1.0 ns | 5.0 / 29 / 0.9 ns | 12 / 15 / 11 ns | 12 / 15 / 11 ns |
| http req/s | 170,835 | 171,646 | 208,863 | 210,820 |

- Pre-#541 yield, same runs: Mac 6.24 (final 5.80, 25 runs), pup 24 (#541's row).
- pup on two P-cores (6,8): yield 33.08 to 19.72, spawn 71.51 to 57.29, fanout 299.8 to 296.4 ms.
- Mac pingpong in two other runs: 1.9% and 0.6% faster. pup echo 0.6% to 1.4% slower across three runs; Mac and pup connect are noisy (wake-fix.md).

## Checks
- pup `zig build test` in debug, safe and fast: 243, 242, 240 pass (1, 2, 4 skipped).
- #541's "two tasks that answer each other over a socket stay on one worker" and the layout test: pass on pup (Debug, ReleaseSafe, ReleaseFast) and the Mac.
- Mac `tools/heavy swarm test/rig.rip all -q`: 9656 jobs green, test/cli/sched_forkjoin.sh among them.
