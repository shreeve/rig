# Audit: concurrency and I/O runtime (2026-11-03)

Scope: `src/sched.zig`, `src/tasks.zig`, `src/net.zig`; `std/task`, `std/par`,
`std/net`, `std/http`, `std/time`, `std/os`, `std/file`, `std/io` (`.rig` and
`.zig`); their sections of docs/STD.md, docs/design/concurrency.md,
docs/internals/scheduler.md. Base edc481031, Zig 0.17.0, macOS (arm64).
Every file in scope was read in full. Settled decisions of the
2026-10 concurrency panel are not re-raised; panel 1's finding 6 (waits
that spin on `yield`) was raised but never decided, and returns here
with new evidence (C5, C6).

Probes are in the session scratchpad (`probes/*.rig`), built with this
worktree's `bin/rig`; each is quoted in full under "Probes" below. No
tracked file other than this one was changed. No suite was run: every
finding is backed by a probe or by the cited lines.

## Findings

Most severe first. LOC is the estimated net change; negative is code removed.

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| C1 | src/sched.zig:1074-1093, 1148-1170; std/net.rig:252-254; docs/STD.md:1022 | lost wakeup / livelock | critical | A `Registration` has one waiter slot per direction, but `Listener.accept(?@)` is documented as sharable ("tasks that share the listener may each wait for one"). A second waiter overwrites the first's slot (`waiter.fiber.store(f)`, 1162). The first is never woken. When a cancel or a deadline then wakes it, `Waiter.leave` (1091) spins forever on a CAS that expects its own fiber, burning a worker at 100%. | probe `accept2`: two tasks accept on `?l`, two clients connect, all inside `time.within(2 s)`. The program never ends: 0% CPU for 2 s (the lost wakeup), then 93-100% CPU until killed (the `leave` spin). | Give each direction a short intrusive list of waiters under the registration's lock, and wake all of them on an edge, since each retries its accept. Or make `accept` take `!@` and fix the docs (an API change, with a Trig note). | +35 (list) or +3 (API) | medium |
| C2 | src/tasks.zig:1482, 1520 (called under `lockAll`, 1656-1668) | panic holding a lock | high | `sendNow` panics ("send on a closed channel") and `close` panics (senders waiting) while holding the channel's `SpinLock`. A panic unwinds nothing, so after `task.isolate` (or `http.serve`'s per-request isolate) catches it, the lock stays held. Every later operation on that channel spins forever at 100% CPU. `close`'s panic also lands in the closer, not in the waiting sender its comment names (1509-1510), and leaves that sender asleep. | probe `chanpanic`: a send on a closed channel inside `task.isolate`, then `recv` in `main`. The isolate reports the panic, and `recv` then spins at 100% CPU. | Decide under the lock, unlock, then panic. For `close` with senders waiting, claim each sender and wake it with a "closed" mark, so its own `send` panics in its own task, as SPEC §18 says a later send does. | +12 | low |
| C3 | src/runtime.zig:8222-8236 (`fail`) vs 8195-8203 (`panicAfterFlush`) | inconsistent panic dispatch | high | Rig's `panic(...)` (`rt.fail`) never calls `tasks.actorsDie`, while a runtime panic (an index, an overflow) does. So (a) `panic()` in an actor's method on its runner ends the whole program, though concurrency.md says "a method run on the actor's own task stops the panic there". (b) `panic()` in a method run inline under an isolate leaves the actor `busy` forever, and its next call is reported as a deadlock. | probe `slotleak` (`panic()` on the runner, caller isolated): exits 134. The same program with an index panic (`slotleak_oob`) stays up: "first -9, held 0". Probe `inlinepanic`: "first -9", then "panic: deadlock: ... Box.add". | Route `fail` through the same boundary logic as `panicAfterFlush`: one function that runs `actorsDie`, then the isolate, then the program's end. | -10 | low |
| C4 | src/tasks.zig:2119-2124 (`runInline` sets `t.control = null`), 1349-1351 (`panicked` reads `task().control`), 1229-1239 | hang + spin | high | A panic in an actor method that runs inline on a task under an isolate (not the isolate's own fiber) reaches `panicked` with `task().control == null`. So `Control.finish` is skipped and the task stays on the isolate's list. `Isolate.stop(true)` then yields in a loop forever. In `http.serve`, a handler that starts a task which calls an idle actor whose method panics never answers, and the connection's task never ends. | probes `v_spawn` and `v_spawn_sup`: `t = (!c).add(-1)&; >t` inside `task.isolate`, with the method panicking. Timeout after 3 s at 200% CPU. The same call made directly on the isolate's fiber (`v_direct`) returns -9. | Keep the task's own `Control` where a panic finds it (a `TaskState` field set at task start and never swapped), and finish it in `panicked`. | +4 | low |
| C5 | src/tasks.zig:2404-2421 | leak → hang | high | An `&` call's mailbox slot (`pending`) and its handle are given back in a Zig `defer`, which a panic never runs. Each `&` call whose method panics on the runner leaks one slot of `capacity`. Once all are leaked, every later `&` call to that actor spins in `actorSpawn` forever. A supervised actor, meant to outlive panics, wears out. | probe `slotleak_oob` (index panic, supervised, `mailbox: 1`): the isolate catches it ("first -9"), then the next `(!c).add(-5)&` hangs (timeout). With `mailbox: 2` the same program finishes ("second -4"). | Give the slot back where the message is answered (`Message.answer`, which `kill` also calls), not in the task's `defer`. Then the handle's drop is the only thing left on the panic path, and it is accepted as abandoned memory. | +6 | medium |
| C6 | src/tasks.zig:2391-2402 (slot wait), 1229-1239 (`Isolate.stop`); src/sched.zig:294-301 (`yield`) | busy wait; deterministic livelock | high | Two waits spin on `rt.sched.yield()` rather than park: an `&` call waiting for a mailbox slot, and an isolate waiting for its tasks. Each burns a core for as long as it waits. In a deterministic run (`rig test`, `RIG_SEED`) `yield` never advances the virtual clock, so when progress needs a timer, the run spins forever. | probe `actorslot` (`mailbox: 1`, method sleeps 10 ms, four `&` calls): unseeded it ends in 0.17 s. With `RIG_SEED=1` it runs at 99.6% CPU forever. | Park on the `Wait` protocol: the runner ticks a `Wakeup` on the actor when it answers an `&` call, and `Control.finish` ticks one on the isolate. Until then, have `yield` charge `check_cost` of virtual time. | +15 / -10 | medium |
| C7 | src/sched.zig:267-273 (`wakeLast` → `notify`); src/tasks.zig:2469-2474 | wasted wakes | medium | `task.check()` yields even when nothing waits, and every requeue notifies a sleeping worker. So a lone task that calls `check()` in a loop kicks a sleeper (a system call) on each call. The sleeper wakes, steals the task, and the task moves between workers. | probe `checks` (1M `task.check()`, release build): 1 worker 0.025 s wall, 0.025 s CPU. 8 workers 0.05 s wall, 0.05 s user + 0.04 s system, about 20,000 sleeps and 5,000 steals (`RIG_SCHED_STATS`). 2x the wall time, 4x the CPU. | `check()` yields only when `hasOwnWork`, as `tick` does. `requeue` notifies only when the ring held other fibers. | +3 | low |
| C8 | src/net.zig:451-479, 537-542, 595-741; src/sched.zig:1806-1828; src/net.zig:429-435 | hot-path cost; complexity | medium | Each `File.read`, `write`, and `sync` pays: a `fcntl(DUPFD_CLOEXEC)` and a `close`; a process-wide `SpinLock` with a hash-map put and remove (`lent`); and a pool round trip, even for a regular file, which `file.read` reads in the task because "a local disk read is cheaper than the pool's two wakes" (std/file.zig:127). `fileWrite` copies the whole payload (`ownArgs`). `io.copy` from a file allocates a fresh String per 64 KiB block and copies it twice (`fileRead`, then `@memcpy` into `buf`). | code as cited. Per `io.copy` block from file to file: 2 dups, 2 closes, 4 locked map operations, 2 pool trips, 2 allocations, 3 copies of 64 KiB. | Dissolve `lent`. Pass an owned `Fd` (and, for `fileReadInto`, the String) by value as a pool-call argument, and have `freeArgs` drop owned arguments when the call never runs, as `run` already drops an abandoned result. Read a `File` that is a regular file in the task, as `file.read` does (fstat once at open). Give `io.copy` a read path that fills `buf` in place. Measure with `cat`/loco. | -80 | medium |
| C9 | src/sched.zig:880-897 | wasted system calls | medium | `Poller.remove` kicks the poller on every deregister, which means every socket close, whether or not a worker sleeps in it. That is one wasted `kevent`/eventfd write, and the kick it leaves wakes the next sleeper in that poller for nothing. | code: `p.kick()` comes before `p.lock.lock()`, unconditionally. | Try the lock first, and kick and wait only when it is held. | +3 | low |
| C10 | std/net.rig:254-256 vs src/net.zig:1032 | locality | medium | `Listener.accept` registers each new stream with the poller of the acceptor's worker. A hand-written server's sockets all land in that one poller, and their readiness wakes their fibers into that worker's run-next slot. `http.serve` avoids this by registering in the connection's own task (`Conn.init`). The two server paths differ. | code as cited; not yet measured. | Register lazily on the first `EAGAIN`, from the waiting task's worker, which needs `reg` by place (`!@`). Measure on `bench/net` before landing. | +12 | medium |
| C11 | docs/design/concurrency.md:334-340, 352-353, 774 | docs claim unbuilt behavior | medium | "Cleanup is shielded, within a grace period", decision 6's "cleanup is shielded, within a grace deadline", and "a watchdog reports a canceled task still running" describe nothing in `src/`: there is no shielding, grace deadline, or watchdog. SPEC §18 (12783-12787) says the opposite: every waiting point after a cancel fails. North Star 6. | `grep -i 'shield\|grace\|watchdog' src/*.zig` finds nothing. | Mark both as planned, or strike them in favor of SPEC's rule. | ±0 | low |
| C12 | src/sched.zig:1809-1842 | weak safeguard | low | `ownArgs`'s compile-time guard checks only a top-level pointer or an optional one. A struct holding a mutable pointer (a `rig.String` by value) passes, and only `[]const u8` is copied, not `[:0]const u8` or `[]const []const u8`. scheduler.md claims an argument the call could write through "does not compile". No caller misuses it today. | code as cited. | Recurse into struct, array, and union fields. Reject any pointer but `[]const u8`, plus the owned types of C8. | +10 | low |
| C13 | src/tasks.zig:682-701; src/net.zig:863-874 | O(n) per add | low | `Tasks[Void].add` (`dropEnded`) and `http.serve` (`reap`) scan every live task on each add or accept. With 10,000 open connections, each accept makes 10,000 atomic loads. | code as cited. | Have `Control.finish` push onto an intrusive done list (Treiber stack) that `add` and `reap` drain. | +15 | low |
| C14 | src/sched.zig:2849-2913 vs src/tasks.zig:2267-2335; tasks.zig:403-448, 1533-1549; sched.zig:1673-1787 | duplication | low | `Header` and `Message` are the same one-shot completion: `end`/`answer`, the two `isEnded`, and `waitEnd`/`waitAnswer`, line for line. `Wakeup`, `Sel`, and the pool call's `C` repeat the same begin, publish, look again, commit handshake. | side-by-side reading. | One `sched.Done` (status, waiter, epoch, `finish`, `wait(cancel, deadline)`) and one `sched.Count` (`Wakeup`). C6's waits use them too. | -60 | medium |
| C15 | src/tasks.zig:327-348, 948-950, and the 11 `x`/`xInto` pairs (178-187, 231-239, 488-496, 721-729, 792-800, 1012-1017, 1061-1066, 1103-1108, 1245-1251, 1290-1296, 1786-1793); 1683-1684; src/sched.zig:1234 | dead code, concision | low | `Handle(T)` wraps one pointer: `result` and `stopped` are the same call, and `keep` does nothing. `parRun` has no caller. Each `x` only forwards to `xInto(…, rt.no_slot)`, which emit could call directly. `selectArms` breaks on both branches of a CAS. `serviceAll` takes a `w` it discards. | `grep -rn 'parRun('`: the definition only. | Inline `Handle` into `Task`; drop `parRun`; emit `xInto(…, rig.no_slot)` and drop the 11 wrappers. | -70 | low |
| C16 | std/net.zig:1-57, std/task.zig:6-12, std/time.zig:11-33 | concision | low | 22 shim functions that only forward one call each. | code as cited. | `pub const listen_on = rig.net.listen_on;` and so on, once `rig.expectShim` (emit.zig:827) is checked to accept an alias. | -40 | low |
| C17 | std/task.rig:15, docs/STD.md:830; std/task.rig:2-3, docs/STD.md:821, SPEC.md:12782; std/file.rig:2-5; std/os.rig:8-9; std/time.zig:1-2; src/sched.zig:563-574; docs/internals/scheduler.md:95-96, 345-347 | docs mismatch | low | (a) "give other threads a turn": it gives other tasks a turn. (b) The lists of waiting points leave out I/O, channels, `select`, sets, actor calls, and pool calls. (c) std/file.rig says every call runs on the blocking pool, and os.rig says `cwd` does, but `read` of a regular file, `exists`, `stat`, `realpath`, and `read_dir` run in the task (file.zig:4-10, 346-349). (d) time.zig says sleeping goes "through Zig's std.Io". (e) `advanceClock`'s doc comment is glued onto `deadlock_message`, and `advanceClock` has none. (f) scheduler.md tells before-and-after history ("where it took 1.5 s"). | text as cited. | Fix the wording. | ±0 | low |
| C18 | src/tasks.zig:96-97, 109, 162-163; docs/design/concurrency.md:74, 280 | vocabulary | low | "receiver" is used for self; "borrow" is used for lend. | text as cited. | "self"; "lend". | ±0 | low |
| C19 | src/net.zig:153-182, 221-224 | blocking fallback | low | When registration fails in a scheduled program (`watch` returns 0), `waitFor` falls back to `poll(2)` on the worker thread, blocking every fiber on it. A `poll` error (`else => return`) counts as ready, so the caller's read loop spins. | code as cited. | Fail with `NetError.failed` when a scheduled task has no registration. Treat a `poll` error as a failure. | +4 | low |
| C20 | src/tasks.zig:605-610 | overflow | low | `enterDeadline` returns `@intCast(d)` of an outer deadline that may exceed `Int`, for a `time.within(Int.max, …)` inside another. Safe builds panic there. | arithmetic: `nowNs() + maxInt(i64)` is more than `maxInt(i64)`. | Saturate at `never`. | +1 | low |
| C21 | src/sched.zig:826, 834 | errno handling | low | A `kqueue`, `epoll_create1`, or `eventfd` that fails (EMFILE) is reported as out of memory (`rt.oom`). | code as cited. | A panic naming the call and its errno. | +3 | low |
| C22 | src/tasks.zig:510-511; src/sched.zig:2096 | small costs | low | `task.all` heap-allocates its `Wakeup`, though every task is joined before it returns. A deterministic pick is `orderedRemove`, O(n) per pick. | code as cited. | A `Wakeup` on the stack; `swapRemove`, which is still deterministic. | -3 | low |

## Restrictions and rules

| Rule | Where | Kind | Verdict |
|---|---|---|---|
| Only a fallible task can be canceled; a wait on an infallible task finishes | concurrency.md decisions 2 and 6; tasks.zig:251-257 | safeguard (no failure the type hides) | Keep. |
| `blockingStop` copies `[]const u8` arguments and rejects pointers the call could write through | sched.zig:1806-1842 | safeguard (no use after free once a waiter leaves) | Keep the guarantee. The whole-payload copy is a hidden allocation: move to owned arguments (C8), and make the guard deep (C12). |
| A task's stack: 64 MiB reserved, guard of at least 16 MiB and at least twice the largest frame | scheduler.md "Stacks" | safeguard (an overflow cannot reach another's memory) | Keep. |
| At most 64 workers (`task.workers`, and `RIG_WORKERS` is silently clamped) | sched.zig:1907, 1970, 1981, 1997 | restriction | Relax: size `all_workers` from the core count. A 96-core machine runs 64 workers, and `RIG_WORKERS=128` gives 64 without a word. |
| Blocking pool: `soft` = performance cores − 1 (2 to 8), `max` 64; `RIG_BLOCKING_THREADS` | sched.zig:1323, 1457-1479 | tuning with an override | Keep. |
| A task that makes a local task stays pinned to its worker for life | sched.zig:283-292; concurrency.md "Local tasks" ("from then on") | restriction | Could unpin once no local child lives: a non-atomic count is confined to one task, not one thread, so once the children end nothing is shared. Relax only if a program shows the need. |
| An `&` call takes one of `capacity` (64) mailbox slots | tasks.zig:2189, 2380-2425 | safeguard (backpressure) | Keep. Its wait must park (C6), and a panic must give the slot back (C5). |
| An actor method runs inline only with a quarter of the stack free | tasks.zig:2246-2260 | safeguard | Keep until stack bounds are proven per method. |
| Deadlock detection only in a program that makes actors | sched.zig:2518-2521 | scope (every cycle passes through an actor) | Keep. |
| A send on a closed channel panics; `close` with senders waiting panics | SPEC.md:13327-13328; tasks.zig:1482, 1520 | rule | Keep the rule, but panic outside the lock and in the sender's task (C2). |
| A yield check never fails; only `task.check()!` delivers a cancel to a computation | concurrency.md "Yielding" | safeguard (effects stay visible) | Keep. |
| `http.serve`: 60 s idle, 10 s head, 16 MiB body, by environment variables | net.zig:799-834 | safeguard | Keep. |
| Deterministic runs: one thread, blocking calls in place, a virtual clock | sched.zig:505-555 | safeguard (reproducible tests) | Keep. `yield` must cost virtual time (C6). |
| `rig.blocking` (cannot be stopped; may take writable buffers) | sched.zig:1588-1600; runtime.zig:117-120 | escape hatch | Only `os.sync` uses it. Fold it into `blockingStop` and drop the `stoppable` comptime split, unless a caller appears. |
| `Listener.accept` through a read view, shared by tasks | std/net.rig:252-254 | feature | Broken (C1): fix it, or take `!@`. |
| `waitReady` budget 128; ring 256; run-next streak 3; `stealNext` after 3 µs; look at the poller every 61 turns or 250 µs | sched.zig:1204, 2337, 383, 2163, 2099, 324 | tuning | Keep. Each is measured in bench/tasks PROGRESS. |

## The biggest simplification

`sched.zig` and `tasks.zig` each re-implement one handshake five times:
publish a waiter and its epoch, look once more, commit, and on waking
look again. It appears as `Header` (a task's end), `Message` (an actor's
answer), `Wakeup` (a set's count), `Sel` (a select), and the blocking
pool's call state. The two waits that do not use it spin on `yield`
instead (an `&` call's mailbox slot, and an isolate's stop), and that is
where three of the high findings live: C4, C5, and C6. One `sched.Done`
(one-shot) and one `sched.Count` (a counter a waiter sleeps on), each
with the cancel and deadline handshake written and proven once, would
remove about 60 lines of near-copies. They would also let every wait in
the runtime park, so no wait burns a core and no deterministic run
livelocks. Next to it, dissolving `net.zig`'s `lent` table by passing
owned descriptors and buffers as pool-call arguments (C8) removes about
80 lines and the one process-wide lock on the file path.

## Probes

Built with `RIG_OUT_DIR=<tmp> bin/rig build <probe>.rig -o <probe>` and
run under `timeout`. CPU was sampled with `ps -o %cpu`.

`accept2` (C1):

```text
use std.net
use std.time

fun take(l: ?net.Listener) -> Int!
  c = l.accept()!
  _ = <c
  1

sub main()!
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  a = take(?l)&
  b = take(?l)&
  time.sleep(50 * time.MS)!
  c1 = net.connect(String("127.0.0.1:", port))!
  c2 = net.connect(String("127.0.0.1:", port))!
  n = time.within(2 * time.SECOND, |<a, <b| >a! + >b!)!
  print(n)
```

`chanpanic` (C2):

```text
use std.task

fun bad(ch: *Chan[Int]) -> Int!
  !ch.send(2)!
  0

sub main()!
  ch = *Chan[Int](4)
  !ch.send(1)!
  !ch.close()
  r = task.isolate(|+ch| bad(+ch)!) catch -9
  print("isolated", r)
  print((!ch).recv()! ?? -1)
```

`inlinepanic` (C3b):

```text
use std.task

obj Box
  hits: Int

  fun add(!@, n: Int) -> Int
    if n < 0
      panic("bad")
    @hits += n
    @hits

sub main()!
  c = *Actor(Box(hits: 0))
  r = task.isolate(|+c| (!c).add(-1)) catch -9
  warn("first", r)
  warn("second", (!c).add(1))
```

`v_spawn` (C4) is `inlinepanic`'s `Box` with
`fun bump(c: *Actor[Box], n: Int) -> Int` written as
`t = (!c).add(n)&` then `>t`, and `main` calling
`task.isolate(|+c| bump(+c, -1)) catch -9`.

`slotleak` / `slotleak_oob` (C3a, C5): a supervised `Box` with
`mailbox: 1`. A task `x = hold(+c)&` holds the actor inline in a 50 ms
`slow()`. Meanwhile `task.isolate(|+c| bump(+c, -1))` queues an `&`
call, which the runner runs and which panics: by `panic("bad")` in
`slotleak`, by an index out of bounds in `slotleak_oob`. Then `main`
makes one more `&` call, `(!c).add(-5)&`.

`actorslot` (C6):

```text
use std.time

obj Slow
  hits: Int

  fun add(!@, n: Int) -> Int!
    time.sleep(10 * time.MS)!
    @hits += n
    @hits

sub main()!
  c = *Actor(Slow(hits: 0), mailbox: 1)
  ts = Tasks[Int!]()
  for 0..4
    !ts.add((!c).add(1)&)
  xs = >ts!
  print(xs.len)
```

`checks` (C7), a release build:

```text
use std.task

fun spin(n: Int) -> Int!
  s = 0
  for i in 0..n
    task.check()!
    s += i
  s

sub main()!
  t = spin(1_000_000)&
  print(>t!)
```
