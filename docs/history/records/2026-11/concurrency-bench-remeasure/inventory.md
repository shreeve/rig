# The concurrency docs' performance claims, and where each came from (2026-11-15)

Every number or comparison in docs/CONCURRENCY.md, docs/launch/benchmarks.md,
docs/design/concurrency.md, docs/learn/04-concurrency.md, README.md, and
docs/launch/*.md, as of main 7a2efd0f3, with the script, date, commit,
build mode, and machine behind it. "fast" is Zig's ReleaseFast
(`--release=fast`, the old `rig-fast` variant), which Rig no longer builds;
"release" is `--release` (ReleaseSafe, every check kept). The
re-measurement is in [README.md](README.md).

## Sources

| Id | Script | Date | Rig commit | Rig build | Machine | Method |
|---|---|---|---|---|---|---|
| L | bench/tasks, actors, net, http (one run each) | 2026-10-20 | b805f1b85 (parent of f1b4fe643) | fast | Mac M5 and pup | best of 7 (tasks, actors) or 3 (net, http) |
| P8 | bench/tasks/bench-tasks, PROGRESS row | 2026-11-08 | 0d1c64647 | fast | Mac M5 | best of 5 |
| A | bench/actors PROGRESS reference rows and #405 row | 2026-10-20 | (#405) | fast | Mac M5 | best of 5 |
| H | bench/http PROGRESS, #1001 row and reference rows | 2026-10-20 (hyper, Go), 2026-11-07 (Rig) | bdfc70ed9 + #1001 | fast | Mac M5 | best of 3, against hyper and Go rows 18 days older |
| S | bench/tasks/bench-scale memory row (SCALING.md) | 2026-11-04 (Mac), 2026-11-05 (pup) | 39e1ed89f | fast | Mac M5 and pup | `footprint`; VmRSS plus VmPTE |
| D | test/cli/http_idle_footprint.sh | 2026-11-09 | main at 15bd04bf4 | release | Mac M5 and pup | `footprint`; VmRSS plus VmPTE; 2,000 connections |
| F | a scratch harness, not in the repository (helper-scratch-1110/fork: fork.rig, fk3.py, a Rayon twin since lost) | 2026-11-10 | hog-newest worktree | fast, "signal" arm | Mac M5 | fastest of 20, rotating |

## Claims

| Doc | Claim | Source |
|---|---|---|
| benchmarks.md | Tasks tables, both machines: spawn, chain, fanout, yield, hog, memory (resident) for Rig, Tokio, Go | L |
| benchmarks.md | "a sleeping Rig task holds 32.7 KiB on the Mac and 8.9 KiB on Linux" | S |
| benchmarks.md | "ahead of Tokio and Go in spawn, chain, yield and hog on both machines"; behind in memory and `fanout` "by 5 to 16 percent" | L |
| benchmarks.md | Actor calls table, both machines (solo, contend, spread) | L |
| benchmarks.md | Networking table, both machines (ping-pong, echo, connect) | L |
| benchmarks.md | HTTP table, both machines (req/s, p50, p99, per idle connection) | L |
| benchmarks.md | idle connection "17.2 KiB on the Mac and 9.2 KiB on Linux" page tables included | D |
| CONCURRENCY.md | "starts faster than a goroutine" | P8 |
| CONCURRENCY.md | chain "at 47 ns a task on the Mac" (Handoff) | P8-era (#1001 row: 47 ns), fast |
| CONCURRENCY.md | "Measured" table: spawn 151, chain 42, yield 4, fanout 81.1 ms, hog 162 ns, produce 6.7 ms, 16.6 KiB against Tokio and Go | P8 (labelled "best of 5"; Tokio and Go from the same run) |
| CONCURRENCY.md | "a chain is 4.3 times as fast as Tokio's, and a yield 9 times. `fanout` is 22% slower" | P8 |
| CONCURRENCY.md | 32.7 KiB (16.1 KiB page tables) Mac against Tokio 267 B, Go 2.9 KiB; 8.9 KiB (4.3) pup against 388 B, 2.9 KiB | S |
| CONCURRENCY.md | psum 2.74 ms against Rayon 2.43 ms; quicksort 85.8 ms against 48.7 ms, "fastest of 20" | F |
| CONCURRENCY.md | actor solo 5.2 ns against Go 3.7 ns and Tokio 134 ns | A (5.2 is the 2026-10-30 rig-safe row; 3.7 and 134 are the 10-20 references) |
| CONCURRENCY.md | `http.serve` 163,212 req/s (p99 786 µs), "9.5% fewer than hyper's 180,339 (p99 614 µs) and about Go's 163,675 (p99 1,071 µs)"; 16.8 KiB against hyper 18.6, Go 18.5 | H |
| CONCURRENCY.md | idle connection 17.2 KiB page tables included | D |
| CONCURRENCY.md | "a task keeps about 3 KiB free below its stack pointer" | src/sched.zig `preempt_room`, a constant, not a measurement |
| design/concurrency.md | 32.7 KiB Mac, 8.9 KiB Linux | S |
| design/concurrency.md | "an idle connection costs less than Tokio's or Go's" | resident memory only (L); with page tables it is less than Go's and about hyper's (D against L) |
| learn/04-concurrency.md | idle actor "about 5 ns a call on an Apple M5" | L |
| learn/04-concurrency.md | 32.7 KiB Mac, 8.9 KiB Linux, "about 300 bytes in Tokio and 2.9 KiB in Go" | S |
| README.md | "Starting and switching tasks costs less than in Tokio or Go, and the HTTP server answers about as many requests as hyper on a Mac, and more on Linux" | L |
| launch/post.md | idle actor 5 ns, Go mutex 3.5 ns, Tokio actor 135 ns | L (Mac) |
| launch/post.md | start-and-wait 44 to 80 ns, Tokio 118 to 250, Go 188 to 271 | L (chain, both machines) |
| launch/post.md | switch 8 to 10 ns against 42 to 47 ns | L (yield) |
| launch/post.md | wait behind a long computation 77 to 80 µs against 2.3 to 4.3 ms, 2.0 to 4.3 ms | L (hog; preemption by signal has since made it ns) |
| launch/post.md | contended actor 31 to 35 ns against 65 to 79 ns | L |
| launch/post.md | HTTP Mac 169,000 against 179,000; Linux 830,000 against hyper 297,000 and Go 235,000 | L |
| launch/post.md | 32.7 KiB Mac, 8.9 KiB Linux; idle connection resident under hyper's and Go's, with its page table more than hyper's | S, L |
| launch/post.md | fanout trails "by 5 to 16 percent"; connect on Linux 36 µs against Tokio's 31 | L |
| launch/faq.md | 16 KiB / 4 KiB pages; 32.7 / 8.9 KiB; 300 B Tokio; 2.9 KiB Go | S |
| launch/faq.md | idle connection 17.2 / 9.2 KiB page tables included, against hyper's 18.6 and 10.8 KiB resident | D against L |
| launch/faq.md | "On the Mac, hyper is a little ahead of Rig, and Go a little behind both" | L |

docs/internals/scheduler.md, outside this item's list, repeats S (32.7 / 8.9
KiB) and L's resident 17 / 5.2 KiB.

## "2.8×"

No doc writes "2.8" or "2.8 times" for a Rig speed. The figure is the
outside review's own division ([goose/review.md](../goose/review.md),
"Against its claims", 2): Linux HTTP, 830,158 requests a second against
hyper's 296,728, from source L. The docs carry it as "830,000 a second
against hyper's 297,000" (launch/post.md), the HTTP table
(benchmarks.md), "and more on Linux" (README.md), and the FAQ's "so much
higher than hyper's".

What supports it: one run of `bench/http/bench-http` on pup on
2026-10-20, Rig in fast mode, unpinned, load generator on the same
machine; the #397 row of bench/http/PROGRESS.md (845,844) is from the
same day. What weakens it:
- Rig's own figure on pup ranges from 125,591 to 1,124,804 requests a
  second across PROGRESS.md's rows, by which cores the server and the
  load generator ran on; hyper was measured once, unpinned, on
  2026-10-20, and never on the core sets that gave Rig's later rows.
- It was never measured in release mode.
- hyper's setup was not audited before (below).

It is not supported as a current claim. The docs no longer state it;
pup-requests.md asks for the measurement that would.

## hyper's setup, audited

bench/http/tokio/src/main.rs against server.rig and go/main.go, all
three answering the same load generator's `GET / HTTP/1.1` (bytes read
from each server on the Mac with curl):

| | Rig `http.serve` | hyper 1 on Tokio | Go `net/http` |
|---|---|---|---|
| Runtime | one worker per core | `multi_thread`, a worker per core | `GOMAXPROCS` = cores |
| Connection | a task per connection, keep-alive | `tokio::spawn` per connection, `http1::Builder` defaults, keep-alive | a goroutine per connection, keep-alive |
| TCP_NODELAY | set (src/net.zig) | not set | set (Go's default) |
| Response | 93 bytes: status, `content-length`, `content-type` | 130 bytes: adds `date` | 130 bytes: adds `Date` |
| Build | `--release` | `--release`, LTO, one codegen unit | `go build` |

Neither difference should explain a factor of 2.8: Nagle's algorithm
holds back a write only while earlier data waits for its
acknowledgment, and each connection has one small response in flight
at a time (not checked by a trace of hyper's writes); hyper and Go
format the date once a second. On the Mac the same setup leaves Rig
7.8% fewer requests than hyper (README.md), so it does not handicap
hyper there. The
setup is fair as written. The gap's source, CPU per request against
contention with the load generator for cores, is what pup's
measurement must show (pup-requests.md, row H2). It showed neither
(README.md, "Results, x86-64 Linux"): hyper spends the least CPU on a
request, and its workers sit mostly idle at its default count; at 6
workers it serves a third more, and Rig's lead over that is 1.2 to 1.7
times across 18 runs, not 2.8.
