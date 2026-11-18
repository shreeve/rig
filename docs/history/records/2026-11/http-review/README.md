# Deep review: Rig's HTTP and scheduler path (2026-11-17, main a1742e713)

Every claim cites a file and line of main, a board row
(the Rig session's `hyper-1116/REPORT.md`), or a test run on a real server. Details the
two review agents wrote: `http-correctness.md`, `sched-soundness.md` (this
folder).

## 1. The tail gap to hyper was the load generator

The one row Rig trailed hyper on, p99 at 80,000 requests a second on one
core of pup (about 950 µs against 600), measured bench/mixed's generator.

- **Cause.** `drive()` paced each connection with `time.Sleep`
  (bench/mixed/load/main.go). Go's timers wait in epoll, whose timeouts are
  whole milliseconds, so a sleeping goroutine wakes up to 1 ms late whenever
  every thread of the generator is idle. How often that is depends on how
  the server's answers arrive.
- **Evidence in the old boards.** Each run records the generator's own
  lateness (`timer_p99`). Run by run, on boards V to Y, every arm's p99 is
  its `timer_p99` plus a constant: main 590→931, 688→1012, 479→836 (+340);
  hyper 62→494, 147→580, 503→933 (+440); D2 135→316 … 141→328 (+185). The
  lateness itself was 585-660 µs against main, 140-260 against hyper, 138
  against D2.
- **Confirmed (board Z, slot 541, quiet honoured).** The same binaries with
  a generator that sends on time (one thread reads the clock and writes each
  request; lateness 5 µs):

  | 80k, one core, 10,000 idle | p50 | p99 (7 runs) | p99.9 |
  |---|---|---|---|
  | main, sleeping generator | 43 | 920 (786-999) | 1,415 |
  | hyper, sleeping generator | 44 | 650 (559-747) | 1,381 |
  | main, on-time generator | 30 | 50 (48-51) | 67 |
  | hyper, on-time generator | 33 | 51 (51-53) | 85 |
  | Pingora, on-time generator | 31 | 56 (55-398) | 87 |

  At 40k: main 18 / 53 / 70, hyper 18 / 54 / 143. At 120k: main 23 / 62 /
  82, hyper 17 / 56 / 105. Ceiling: main 151.5k / 144.7k, hyper 149.7k /
  142.0k.
- **Consequences.** Main is level with hyper at p99 and ahead at p99.9; the
  one row hyper leads is 120k, by 6 µs at p50 and p99. The holder (two
  rounds) and the D line (D, D2, D3) fixed a row that measured the
  generator; D4 was stopped before any board (archive/shared-sleep). The
  Mac's tail rows used the same generator and need retiming.
- **Fix.** Draft PR #1130 (`load-pacer`): the on-time generator, `-pace
  sleep` kept to reproduce old boards, README caveat on PROGRESS.md's rows.

## 2. Correctness: the HTTP server (all confirmed on a running server)

Sent to a server built from main, debug and release:

| # | Request | What happens | Where |
|---|---|---|---|
| a | `GET / HTTP/1.1` with `Content-Length: 0` (or any body-less method with a length or chunked, kept alive; `curl -X DELETE -d '{}'`) | **the whole server process dies**, "reached unreachable code" | net.zig:1017, 1126-1135: `answer` decides a body by its headers, Zig's `readerExpectContinue` by its method |
| b | chunked body, chunk size `FFFFFFFFFFFFFFFF` + 1 byte | **the whole server process dies**, "integer overflow" | Zig std/http.zig:588, reached from net.zig:1018 |
| c | handler answers 204 or 304 with a body | length and body bytes are sent; a client reads none, so they prefix the next answer on the connection | net.zig:1105-1121 |
| d | `Content-Length : 34` (space or tab before the colon) | header ignored, body read as a second request: request smuggling behind a proxy that drops the space | net.zig:1409-1414 |
| e | `Content-Length: 10`, 3 bytes, client closes | handler runs with the 3 bytes as a whole body, 200 | net.zig:1018-1023 (Zig's `appendRemaining` takes the early end as the end) |
| f | chunk-size lines `5\n`, `\r\n`, ` 5`, `1g`, `0x10` | all accepted by Zig's `ChunkParser`; a proxy reading them another way puts the body's end elsewhere | Zig std/http/ChunkParser.zig:35-100 |
| g | trailers whose first line is 2-3 bytes (`a:b`) | the trailer section ends there; the rest is parsed as the next request | Zig std/http.zig:680-705 |

a and b are remote denial of service by one request. No test sent a
body-less method with a length, or a large chunk size.

**Fix, written test-first: draft PR #1131** (branch `http-body`, two
commits; every gate green: core suite, Linux unit tests in three modes,
Trig light 119 of 119, loco, and pup board AA level with main on cycles,
p99, the ceiling and the closed loop): 204/304 go out as the status line alone; a header
line with no colon or a name that is no token is 400; the server reads
bodies itself (`readBody`, about 90 lines) as strictly as it reads heads,
whatever the method, with extensions counted against the body's limit, and
a body cut short gets no answer; Zig's `readerExpectContinue`,
`discardBody`, and `ChunkParser` are no longer used. Unit tests: 51 chunk
framings at four read sizes each; 21 new requests in test/cli/std_http.sh.

Left for a follow-up, each small (http-correctness.md 6-11): no deadline for
a whole body or a whole response (a client can hold 16 MiB a connection by
sending a byte a minute); `Connection` read as one word, not a list, and
HTTP/1.0 kept alive on any value but `close`, with no `keep-alive` in the
answer; CONNECT reaches the handler; `Content-Encoding: br` is 400; targets
with spaces and absolute-form targets pass through unreduced; no Host
check; some accept errors Linux means as "retry" end `serve`.

Checked and sound: the request's views into the read buffer, `Conn`'s
buffer hold and release, pipelining, Content-Length forms, close and
deregistration.

## 3. Correctness: the scheduler (by trace, not reproduced)

No lost wakeup of a queued fiber, double run, use of a freed registration,
ordering mistake in a store-then-load pair, or ABA on the run-next slots.
Three gaps of one kind, a duty one sleeping worker holds for the others
that is not handed on when it leaves its sleep (sched-soundness.md):

1. **A timer loses its covering sleeper** (medium). `kickForTimer`
   (sched.zig:2169) kicks one sleeper; when that one leaves its sleep early
   nothing kicks another, so a deadline in the heap of a worker that makes
   no yield checks, or sleeps, can pass while other workers sleep with no
   timeout. Fix: on leaving `sleep`, `kickForTimer(earliestDue())`.
2. **The poller watch can lapse** (low to medium). `passWatch` kicks one
   sleeper; if its first look finds work it leaves without watching and
   passes nothing on (sched.zig:4312-4319).
3. **A quietly filled run-next slot can go unseen** (low, plausible).

Each needs a failing test before a fix; none is in the Lean model's scope.

## 4. Speed, by measured share

- **Kernel time is 78% of a trivial request's cycles and 38% of the mix's**
  (pup profile of main, board Y's data). Rig's own code is under 22%: the
  largest user functions are `Poller.poll` 2.8%, `runtime.inCode` 2.65%,
  `sched.search` 1.9%, `sched.loop` 1.85%. What is left to win in user code
  is small; system calls a request are the lever, and Rig already makes
  fewer context switches than hyper (0.64 against 0.68 a request).
- **Thread placement near saturation.** On two E-cores at 60k (untimed),
  binding each worker thread to its own CPU took p99 from 44-126 ms to
  150 µs for Rig and hyper alike. In a slot on one P-core's two threads
  (board P) it changes little for Rig: equal medians at 120k, 140k and
  150k, and it removes the one run in four with a millisecond tail at
  120k. No case for binding in the runtime from that board; the E-core
  case (two separate cores) is left as a note.
- **Rig holds up past hyper's capacity** (board P, no idle connections):
  at 150k on one core Rig is 36 / 160 µs (p50 / p99) where hyper is
  266 / 2,062.
- **`runtime.inCode` at 2.65%** of a trivial request is the preemption
  signal's "is this the program's code" test; worth a look at why it runs
  that often on a server whose handlers return in microseconds.
- **A response larger than the 8 KiB write buffer** goes out as two writes
  and two segments (net.zig:2067-2082); `writev` makes it one. No bench row
  covers it.
- **120k on one core:** hyper leads by 6 µs at p50 and p99 (17 / 56 against
  23 / 62). Unexplained; the on-time generator makes it measurable now.

## 5. Smaller and clearer

- With bodies read by `readBody`, `respond` no longer calls
  `writeExpectContinue`, `discardBody` is gone, and Zig's reader state and
  trailers are never set: about 25 lines out, done in `http-body`.
- sched.zig: `park` / `parkApart`, `wakeLast` / `wakeLastApart`, and
  `Timers.fire`'s own batch are dead (sched-soundness.md).
- On Linux the watch (`watch_every`, `sleepIn`'s watch, `passWatch`,
  `busyDescriptors`, `watchWanted`) exists to bound a wait that board Z
  shows is not costing the tail. Whether it still earns its lines is a
  question for a board with the on-time generator: main against main with
  the watch compiled out.

## 6. Also found on the way

- **Main's core suite is red on `cli.wait_sync`**, since 46f2ac3af (the
  connection-deadline change of the HTTP stack): `Deadline.come` touches a
  wait's word and is not a step of Wait.lean. Reproduced on a clean build
  of main. The scheduler merges since were gated on unit tests and swarm
  areas, not the core, so nothing caught it. Fixed in #1132 (merged):
  `come` is `interrupt` for the present epoch, now checked by the script
  and named in Wait.lean. `cli.exit_teardown` failed once under load (it
  waits 5 ms where it should wait for a signal); Concurrency is fixing it.
- The records concurrency-holder and concurrency-watch are corrected in
  #1129; WHERE-WE-STAND carries board Z's rows.

## What followed

- #1130: the on-time generator. #1129: the two tail records corrected.
- #1131: the HTTP server's bugs of §2 fixed. #1136: its follow-ups (a
  body's deadline, `Connection` as a list, Host required, CONNECT
  refused, accept's retries).
- #1132, #1133, #1134: main's core suite whole again, and a test of the
  moving deadline.
- #1135: the timer's cover (§3, the first gap). The second, the watch,
  is in review; the third is being tested.
- Board P: binding worker threads to CPUs gives no case for the runtime.
- The standings against hyper after all of it:
  [concurrency-standings](../concurrency-standings/README.md).
