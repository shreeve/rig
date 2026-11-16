# The concurrency benchmarks, measured again with `--release` (2026-11-15)

Concurrency item 3, approved by the owner: measure again the numbers in
docs/CONCURRENCY.md and docs/launch/benchmarks.md in release builds, and
verify every HTTP claim. An outside review
([goose/review.md](../goose/review.md)) found benchmarks.md measured in
Zig's fast mode and an unverified "2.8×".

- [inventory.md](inventory.md): every claim in the concurrency docs,
  its source, date, commit, build mode, and machine; where "2.8×" came
  from; hyper's setup, audited.
- [pup-requests.md](pup-requests.md): the x86-64 Linux runs, as asked
  of pup.
- `raw/`: every board's output as the scripts printed it, with the date,
  the load, and the commit.
- `idle_footprint.py`: an idle HTTP connection's footprint, page tables
  included, for every server alike (test/cli/http_idle_footprint.sh's
  method).
- `fork/`: the fork-join programs, Rig's (`fork.rig`, kept from a
  scratch harness of 2026-11-10) and a Rayon twin written for this
  record (the first was lost), and `run.py`, which rotates them.

## Method

Apple M5, 10 cores, macOS (Darwin 27.2), main 7a2efd0f3. Rig
`--release` (ReleaseSafe); Tokio 1.54.1 from the `misc/tokio` clone
(hyper's from crates.io, by its Cargo.lock), `cargo build --release`
with LTO and one codegen unit; Go 1.27.3; Rust 1.99.1. Every timed run
held the Mac's claim (`tools/mac-claim`), which waits for the machine to
go quiet. Each script interleaves its variants and keeps the fastest of
each benchmark; where two boards ran, the docs give the fastest over
both (both boards are below).

## Results, Mac

Old: docs/launch/benchmarks.md (2026-10-20, fast mode) or CONCURRENCY.md
(2026-11-08, fast mode). New: release.

| Benchmark | Rig old | Rig new | Tokio new | Go new | Board 1 / board 2 (Rig) |
|---|---|---|---|---|---|
| spawn | 105 ns (151 in CONCURRENCY) | 133 ns | 175 ns | 228 ns | 133 / 161 |
| chain | 44 ns (42) | 51 ns | 165 ns | 199 ns | 51 / 53 |
| fanout | 78.2 ms (81.1) | 65.8 ms | 66.1 ms | 67.2 ms | 65.8 / 67.0 |
| yield | 10 ns (4) | 6 ns | 39 ns | 226 ns | 6 / 6 |
| hog | 80.5 µs (162 ns) | 153 ns | 3.3 ms | 3.4 ms | 191 / 153 |
| produce | (6.7 ms) | 5.3 ms | 6.0 ms | 5.8 ms | 5.3 / 5.9 |
| memory, resident | 17.0 KiB (16.6) | 16.6 KiB | 262 B | 2.9 KiB | 16.6 / 16.6 |
| sleeping task, footprint | 32.7 KiB, 16.1 page tables | 17.1 KiB, 537 B page tables | 264 B | 2.9 KiB | one run |
| actor solo | 5.0 ns | 5.0 ns | 138 ns | 3.4 ns | one board |
| actor contend | 31 ns | 15 ns | 267 ns | 77 ns | one board |
| actor spread | 0.9 ns | 0.9 ns | 30 ns | 0.5 ns | one board |
| ping-pong | 14.9 µs | 16.4 µs | 13.6 µs | 16.4 µs | 16.68 / 16.38 |
| echo | 5.9 µs | 8.5 µs | 5.8 µs | 7.3 µs | 8.54 / 8.60 |
| connect | 59.7 µs | 50.7 µs | 59.7 µs | 61.7 µs | 50.77 / 50.73 |
| HTTP req/s | 169,215 | 128,402 | 139,202 | 120,522 | 127,797 / 128,402 |
| HTTP p50 / p99 | 369 / 641 µs | 492 / 690 µs | 453 / 617 µs | 521 / 1,014 µs | |
| idle connection, resident | 17.0 KiB | 16.7 KiB | 18.6 KiB | 18.5 KiB | |
| idle connection, footprint | 17.2 KiB | 17.3 KiB | 18.7 KiB | 20.2 KiB | one run, 2,000 connections |
| psum | 2.74 ms (Rayon 2.43) | 2.83 ms | Rayon 2.39 ms | | fastest of 20 |
| qsort | 85.8 ms (Rayon 48.7) | 80.2 ms | Rayon 52.5 ms | | fastest of 20 |

What changed in what the docs say:
- `fanout` is level with Tokio and Go (65.8 against 66.1 and 67.2 ms,
  within noise), not 5 to 22% behind: loops run with no yield checks
  since preemption by signal.
- `hog` is 153 ns, not 77 to 80 µs: the docs' launch numbers predate
  preemption by signal.
- A sleeping task's footprint is 17.1 KiB, not 32.7: a release build
  gives it a dense stack, under shared page tables. A task with
  recursion or a call through a pointer keeps a large stack (32.7 KiB on
  the Mac at 39e1ed89f, which build mode does not change).
- Contended actor calls are 15 ns, half the launch figure.
- Loopback round trips are slower than Tokio's: ping-pong 20%, echo
  47%. The docs said the three stay close.
- HTTP on the Mac: Rig 7.8% fewer requests than hyper (was 5.6%), 6.5%
  more than Go. Every server's absolute rate is lower than on
  2026-10-20 (hyper 139,202 against 179,227), so the machine's state
  moved, not one runtime.
- An idle connection's footprint, measured for all three alike, is
  under hyper's and Go's: 17.3 against 18.7 and 20.2 KiB. The docs had
  compared Rig's footprint with the others' resident memory.
- Fork-join: the old figures were the "signal" arm of a fast-mode
  scratch build; in release the sum trails Rayon by 18% and the
  quicksort by 53%.

## Echo: not a Rig regression

Rig's echo, 8.5 µs, is 44% over the 5.91 µs bench/net/PROGRESS.md
holds for a `rig-safe` build of a8acfdc5c (2026-10-30). Two A/Bs on the
same boards, each against today's 7a2efd0f3 and Tokio
([raw/net-ab-mac.txt](raw/net-ab-mac.txt),
[raw/net-ab2-mac.txt](raw/net-ab2-mac.txt)):

| Rig | ping-pong | echo | connect |
|---|---|---|---|
| 7a2efd0f3 | 16.42 / 16.01 µs | 8.63 / 8.58 µs | 51.19 / 50.70 µs |
| ec0a2a743 (2026-11-09) | 16.46 µs | 8.60 µs | 50.18 µs |
| a8acfdc5c (2026-10-30) | 16.23 µs | 8.55 µs | 49.71 µs |
| Tokio | 14.12 / 14.15 µs | 6.09 / 6.18 µs | 61.22 / 61.97 µs |

The 2026-10-30 build is as slow today as main: the gap came with the
machine (macOS), not with a Rig change, and it costs Rig more than
Tokio (Tokio's echo was 5.68 µs on 2026-10-20). Why is open: a
system-call profile of echo in both runtimes is the next step.

## Results, x86-64 Linux (pup)

Intel Core Ultra 9 185H, 22 cores, at bfd872b6d (rows T, M, A, N, F,
H1, H2) and 1f35fc1da (D, H3, H4, F2, M2, D2), whose compiler and runtime are
7a2efd0f3's; each row in a slot of its own with no other holder, its
file in `raw/` (`<row>-pup.txt`) headed by the slot's line (free 2 MiB
blocks, load). Every timed row ran on cores 0-11 unless it says not.

| Benchmark | Rig | Tokio | Go | Rows |
|---|---|---|---|---|
| spawn | 168 ns | 236 ns | 210 ns | T, fastest of 7 |
| chain | 100 ns | 213 ns | 234 ns | T |
| fanout | 59.6 ms | 65.4 ms | 55.1 ms | T |
| yield | 6 ns | 32 ns | 244 ns | T |
| hog | 316 ns | 3.2 ms | 3.0 ms | T |
| produce | 6.0 ms | 5.5 ms | 4.9 ms | T |
| memory, resident | 4.7 KiB | 373 B | 2.8 KiB | T |
| sleeping task, footprint | 5.2 KiB, 521 B page tables | 391 B | 2.8 KiB | M2 |
| actor solo | 11 ns | 241 ns | 11 ns | A, fastest of 7 |
| actor contend | 24 ns | 232 ns | 52 ns | A |
| actor spread | 2.0 ns | 25 ns | 1.8 ns | A |
| ping-pong | 5.30 µs | 4.90 µs | 5.53 µs | N, fastest of 7 |
| echo | 1.10 µs | 1.29 µs | 0.96 µs | N |
| connect | 25.2 µs | 31.3 µs | 43.1 µs | N |
| HTTP req/s | 592,080-845,543 | 352,122-365,783 | 444,064-450,728 | H1, H2a-c, H2t, H3a: 18 runs |
| HTTP, hyper at 6 workers | | 473,053-485,942 | | H3b |
| HTTP p50 / p99, fastest run | 59 / 284 µs | 165 / 340 µs | 98 / 737 µs | |
| HTTP server CPU per request | 5.86-6.50 µs | 5.07-5.21 µs (5.37-5.39 at 6) | 15.16-15.36 µs | H2t, H3a, H3b |
| HTTP server cores used | 4.9-5.2 | 1.8 (2.5-2.6 at 6) | 6.7-6.8 | H3a, H3b |
| idle connection, resident | 8.8 KiB | 10.8 KiB | 18.9 KiB | H1, H2, 10,000 idle |
| idle connection, footprint | 9.7 KiB, 0.50 page tables | 10.9 KiB | 20.1 KiB | D2, 2,000 idle |
| psum | 6.66 ms | Rayon 4.48 ms | | F2, fastest of 20 |
| qsort | 120.55 ms | Rayon 117.25 ms | | F2 |
| HTTP, 12 workers each, cores 0-19 | 675,746-865,439 | 441,917-446,793 | 539,544-549,245 | H4c |

What holds hyper (H3): not its CPU per request, which is the lowest of
the three, nor Nagle's algorithm (H3c, `HYPER_NODELAY=1`: 354k-364k, as
without). At its default of a worker per core its busiest worker is busy
a sixth of the time and the server uses 1.8 cores; at 6 workers it
serves a third more (473k-486k), its best on these cores; at 24 it
serves the same as at 12. The docs compare Rig with hyper at 6 workers
as well as at its default.

### Rows that measured the slot, not the runtimes

H2u, H4a and H4b ran without `taskset` and every server fell under
90,000 requests a second. The thread counts H4a adds show why: each
runtime started as for about two CPUs (Rig and Tokio 3 threads, Go 7-9,
against 13, 13 and 20 on cores 0-11), and H4b, with 12 workers forced,
still used under 1.2 cores. The process could run on about two CPUs
only, and an explicit `taskset -c 0-19` (H4c) gave all three their
throughput back. Those rows measure how the slot's affinity was set,
not the servers, and no doc cites them. F, M and D ran without
`taskset` too, and ran again pinned as F2, M2 and D2, which print the
slot shell's own affinity first: `nproc` 2, mask 0x300000, the two
low-power cores 20 and 21. Every command without its own `taskset` ran
there. F's 23.4 ms sum and 709 ms quicksort were those two cores; pinned,
they are 6.66 and 120.55 ms. M's footprint, memory rather than time,
moved little (5.1 KiB unpinned, 5.2 pinned), and D's more (10.7 KiB
unpinned, 9.7 pinned); the docs give the pinned figures.

## Not measured

- Swift's memory row and Rayon's `produce` (not in the docs).
- No toolchain was missing on the Mac.
