# The concurrency benchmarks, measured again with `--release` (2026-11-15)

Concurrency item 3, approved by the owner: measure again the numbers in
docs/CONCURRENCY.md and docs/launch/benchmarks.md in release builds, and
verify every HTTP claim. An outside review
([goose/review.md](../goose/review.md)) found benchmarks.md measured in
Zig's fast mode and an unverified "2.8×".

- [inventory.md](inventory.md): every claim in the concurrency docs,
  its source, date, commit, build mode, and machine; where "2.8×" came
  from; hyper's setup, audited.
- [pup-requests.md](pup-requests.md): the x86-64 Linux runs the docs
  wait on.
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

## Not measured

- x86-64 Linux: every Linux number, routed to pup ([pup-requests.md](pup-requests.md)).
  The docs give no Linux figure until then.
- Swift's memory row and Rayon's `produce` (not in the docs).
- No toolchain was missing on the Mac.
