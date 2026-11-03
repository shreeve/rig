# Memory in a network server: the runtime's share

Runtime expert, 2026-10-29. Probe: `port-probes/redis-speed/kv.rig` (a task per
connection, a `*Actor[Db]` store, `Map[String, String]`) against `tkv` (Tokio, same
logic). Scripts, the kv variants, the prototype patch (`mem-runtime.diff`) and raw
output are in `reviews/mem-runtime-probes/`. Each row is a fresh server: RSS at start,
with N connections held idle (each did one SET and one GET), and the most seen during
3 s of N connections loading it (P=1, SET/GET over 10,000 keys, 32 B values).
Attribution: `vmmap` regions on the Mac, `/proc/PID/smaps` on pup, and the code.

## 1. What it costs

**Mac (M5, 10 workers, 16 KiB pages), RSS in MB.** Rig is the baseline `8c8f0531`
(`--release=fast`); "Rig+fix" is master `1b2f4b59d` with the three fixes of §3
(a prototype build, `mem-runtime.diff`).

| N | Rig idle | Rig load | Rig+fix idle | Rig+fix load | tkv idle | tkv load |
|---|---|---|---|---|---|---|
| 0 (start) | 5.2 | | 2.2 | | 2.1 | |
| 1 | 5.6 | 7.7 | 2.6 | 4.8 | 2.2 | 4.7 |
| 50 | 7.4 | 17.3 | 3.6 | 8.4 | 3.2 | 5.3 |
| 200 | 12.3 | 35.1 | 6.1 | 11.2 | 6.5 | 8.4 |
| 1000 | 38.6 | 91.9 | 19.8 | 26.3 | 23.5 | 25.6 |
| 50, P=16 | | 20.9 | | 9.6 | | 5.7 |

**pup (x86-64 Linux, 4 KiB pages), server on cores 0,5,1,2,3,4 (6 workers), RSS in MB.**
Rig `81a1ef486` as the probe was built; "b0" is master unchanged, "b1" master with the fixes.

| N | Rig idle | Rig load | b0 load | b1 idle | b1 load | tkv idle | tkv load |
|---|---|---|---|---|---|---|---|
| 0 (start) | 3.05 | | 4.07 | 2.54 | | 3.0 | |
| 50 | 5.4 | 7.5 | 8.5 | 2.8 | 4.4 | 3.7 | 5.6 |
| 200 | 11.2 | 14.5 | | | | 5.1 | 8.0 |
| 1000 | 41.5 | 62.2 | 72.3 | 7.2 | 9.0 | 12.5 | 19.8 |

Unpinned on pup (22 workers): start b0 8.3, b1 2.7, tkv 3.4 MB; N=50 under load b0 14.5,
b1 5.7, tkv 6.3; N=1000 under load b0 77.1, b1 10.6, tkv 21.8.

**Fixed cost and slope today.**
- Fixed: about **290 KiB per worker** at start on the Mac (5.2 MB at 10 workers, 2.6 MB
  at 1; `RIG_WORKERS` sweep) and **265 KiB per worker** on pup (8.3 MB at 22, 3.05 at 6).
  tkv's start is 2.1 MB (Mac) and 3.0–3.4 (pup) whatever the worker count.
- Under load the fixed part grows by about **1 MB per worker** on the Mac (N=50: 6.7 MB at
  1 worker, 8.7 at 2, 11.2 at 4, 16.3 at 10), which is why 50 connections cost 17 MB.
- Per idle connection: **33 KiB** on the Mac (tkv 21), **38.5 KiB** on pup (tkv 9.4).
- Per active connection: **87 KiB** on the Mac at N=1000 (tkv 23.5), **59 KiB** on pup
  (tkv 16.8).

## 2. What each is made of

Mac, N=1000 (dirty KiB from vmmap; `vmcat.py`): idle 38.1 MB = allocator heaps 16.7 +
task stacks 16.4 + thread-local storage in libc malloc 3.2 + smp/page allocator 0.9 + image
0.7. Under load 94.5 MB = heaps 54.3 + stacks 33.2 + TLS 3.2 + smp 2.9. At N=50 under
load: heaps 9.2, stacks 3.6, TLS 3.2, smp 1.9.

1. **Each worker's 256 KiB signal stack is resident** (the per-worker fixed cost). Every
   thread, worker or blocking pool, calls Zig's `std.Thread.maybeAttachSignalStack`
   (in `std.Thread.callFn`, and again in `sched.workerMain` and `runtime.attachSignalStack`),
   whose stack is `threadlocal var signal_stack: [1 << 18]u8` (`std.options.signal_stack_size`,
   default 256 KiB; the binary's `__thread_bss` is 0x40024 bytes). On macOS dyld mallocs
   and zeroes each thread's TLS block (`malloc_history`: 9 calls of 278,528 bytes from
   `_tlv_get_addr`); on Linux Zig's thread start zeroes it in the thread's mapping (smaps:
   264 KiB resident per thread mapping). 10 workers: 2.7 MB; 22 on pup: 5.6 MB. tkv's
   threads have no such buffer.
2. **The read buffer is reserved at `max` before the read and held while the task waits.**
   `net.read_from` calls `ensureUnusedCapacity(want)` and then `readSome`, which parks on
   `EAGAIN` holding it. `kv.rig` reads with `max` 16,384 into a fresh String each request
   (`buf = String(?buf[pos..])`), so every request allocates a new block, and Zig's
   growth rule (`n + n/2 + 128`) makes it **24,704 bytes** for 16,384 asked. Idle: one
   such block per connection, 16 KiB of it touched on the Mac, all of it on Linux (the
   allocator prefaults; smaps: 34.8 MB of heap for 1,000 idle connections). Under load the
   blocks are allocated on one worker and freed on another as tasks move, so ten heaps
   each fill with them: heaps grow 16.7 → 54 MB at N=1000 (Mac), 3 → 50 MB (pup). With
   one worker they do not grow (16.6 → 17.1 MB), and with the program reusing its buffer
   (`kv-reuse.rig`, `!buf.clear()`) they grow half as much (28 MB). bench/http does not pay
   this: `net.Conn` reads into a worker block (`sched.takeBlock`) and holds none while idle;
   `std.net.Stream.read` has no such path.
3. **A task that blocks touches a second stack page.** `sched.block` keeps the deadlock
   walk (`Walk`: 64 paths, 64 + 64 steps, 256 seen) and a 1 KiB message buffer in its own
   frame: **15,504 bytes** (`sub sp, sp, #15504`, the largest frame in the binary). It runs
   on every contended actor call and task wait in a program with actors, and the calls it
   makes below that frame touch one more page, though the walk itself runs only when the
   wait leads on to another blocked fiber. Mac: stacks are 16 KiB each idle, 32 KiB each
   under load (vmmap: 445 of 583 stacks at 32 KiB); with one worker (no contention, no
   `block`) 16 KiB under load. pup: 4 → 5–8 KiB.
4. **Stacks of ended tasks keep their pages.** A worker keeps up to 64 free stacks
   (`keep_free`) with every page their fibers touched (the free-list link sits in the top
   page; nothing is released). After 1,000 connections close: 14–15.5 MB of stacks stay
   on the Mac, 2.2–2.9 MB on pup. This is the "after" column, not the peak; at N=50 it is
   half of the 3.6 MB of stacks (the hold phase's 50 tasks and the load's 50).
5. **Task records and registrations in Zig's `SmpAllocator`.** `sched.spawn` (task records),
   `spawnDetached` (actor runners), and `register` (one `Registration` per socket) use
   `std.heap.smp_allocator`, whose per-thread 64 KiB slabs per size class make the
   0.9 → 2.9 MB (Mac) "other" column. Not per connection; per worker × size class.
6. **Not costs here:** the poller (one kqueue/epoll per worker, 64 events on the stack),
   worker rings (256 pointers, 64 `Worker` records allocated, untouched beyond the ones
   used), the actor mailbox (calls live in the caller's frame, `tasks.zig` `Call`), `Tasks[Void]`
   (drops ended tasks on each `add`), worker thread stacks (176 KiB dirty for all ten),
   and the 64 MiB task stacks and 16 MiB guards (address space only).

## 3. Fixes, ranked by MB saved

Measured with the prototype (`mem-runtime.diff`, 108 lines) except where marked.

| # | Fix | File | Saves (measured) | Cost |
|---|---|---|---|---|
| 1 | Read into the worker's block when the String lacks room for `max`; append only the bytes that came; hold nothing while waiting (`readBlock`, as `net.Conn.fill` does) | `src/net.zig` `read_from` | pup N=1000: idle 34 MB, load ~50 MB; Mac N=1000 load ~45 MB; Mac N=50 load ~6 MB | One memcpy of the bytes read when the String has no room. A String with room is read into directly, as now, so a program that keeps its buffer stays zero-copy. |
| 2 | Map each thread's signal stack (`mmap`, `NORESERVE`, untouched until a signal) instead of Zig's TLS array; root sets `std_options.signal_stack_size = null` | `src/runtime.zig` (`attachAltStack`), `src/sched.zig` `workerMain`, `src/main.zig` `writeRootFlags` | 256–290 KiB per worker: Mac 3.0 MB at start; pup 1.5 MB (6 workers), 5.6 MB (22) | None at run time. Also add it in `sched.poolMain`, which the prototype missed: pool threads now have no alternate stack. |
| 3 | Move the deadlock walk out of `block`'s frame into a `noinline walkFrom` (or a static under the `graph` lock, which serializes walks) | `src/sched.zig` `block` | One page per blocking task: Mac 16 KiB (16 MB at N=1000, 0.8 MB at N=50), pup 4 KiB | None; the walk runs as before. |
| 4 | Release the pages of kept stacks below their top page (`madvise` `DONTNEED`/`FREE_REUSABLE`) when a worker goes to sleep, or lower `keep_free` from 64 | `src/sched.zig` `releaseStack`, `sleep` | Not built. The after-burst stacks: Mac up to 14 MB at N=1000, pup ~2 MB. Not the peak. | A syscall per kept stack per sleep; bench/tasks `spawn` and `chain` must not move. |
| 5 | Task records and registrations from Rig's own heap or a per-worker cache, not `SmpAllocator` | `src/sched.zig` `spawn`, `spawnDetached`, `register` | Not built. Up to ~2 MB on the Mac at 10 workers, less on pup | Measure first; they are kept outside the leak checker's count on purpose. |
| 6 | `read_from`'s direct path: reserve exactly `max` for an empty String (`ensureTotalCapacityPrecise`), not 1.5× | `src/net.zig` | Not built. 8 KiB per connection that keeps its buffer | None. |

Fixes 1–3 together, against the same source without them: Mac N=50 under load
17.9 → 8.4 MB (tkv 5.3), N=1000 86 → 26 MB (tkv 25.6); pup pinned N=50 8.5 → 4.4 MB
(tkv 5.6), N=1000 72 → 9.0 MB (tkv 19.8); pup unpinned N=50 14.5 → 5.7 MB (tkv 6.3).
Per connection after them: Mac 17.6 KiB idle, 24 KiB under load; pup 4.7 and 6.5 KiB.

**What is left on the Mac at N=50 under load** (7.5 MB dirty): allocator heaps 2.6 MB (ten
heaps' partly filled 64 KiB pages: the allocator expert's), `SmpAllocator` slabs and worker
blocks 2.2 MB (fix 5), stacks 1.6 MB (50 live pages of 16 KiB plus the hold phase's kept
stacks: fix 4), TLS remnants 0.5 MB.

**Speed of fixes 1–3** (best of 7 interleaved rounds, pup pinned, pup's load average was
80 from another job, so treat as noisy; then 5 rounds on the Mac at load 10): unpipelined
C=1 7.6% faster, C=50 1.6% slower, pipelined C=1 2.1% slower, C=50 1.1% slower, 16 KB
values (C=8, P=2) **5.0% slower** on pup; on the Mac within 2.1% either way, C=50 P=16
4.4% faster. The 16 KB row is fix 1's copy; it needs a quiet pup before anyone believes
it, and if it holds, read straight into the String once a block read comes back full (more
is waiting), so only the first read of a large burst is copied. The suite was not run on
the prototype.

## 4. Safety for Trig and the benches

- **Trig** uses neither `std.net` nor actors (`grep` of `~/Data/Code/trig/src`), so fixes 1
  and 3 do not run in it. Fix 2 removes 256 KiB of resident TLS from each of its worker
  threads (5.6 MB of peak RSS at 22 workers on pup) and costs one `mmap` per thread at
  start. No hot path changes. Trig's light gate still applies to any runtime change.
- **bench/net** reads into a fresh `String()` each time (`net.rig` `echo`, `client`), so
  fix 1 changes its path: a 64-byte copy in place of a 6 KiB allocation and free. Run
  bench/net and bench/http before merging. **bench/actors** and **bench/tasks** see fix 3
  (frame layout only) and fix 4 if built (the `sleep` path); both run on pup, as the
  runtime rule requires.

## 5. Tokio, and how close Rig's model gets

Tokio's task is a stackless future: its state is the async function's live variables
(about 300 bytes a task in bench/tasks' `memory`) plus what it allocates, and an idle `tkv` connection
holds its 16 KiB `BytesMut` (9.4 KiB per connection on pup, 21 on the Mac). Rig's task
keeps a stack, and a stack costs at least one page while the task lives: 4 KiB on Linux,
16 KiB on Apple. That is the floor of Rig's model without a language change, and it is
already below `tkv`'s per connection once Rig holds no read buffer while it waits (fix 1):
4.7 against 9.4 KiB on pup, 17.6 against 21 KiB on the Mac. A Tokio server written to hold
no buffer while idle (`readable().await`, then `try_read` into a shared buffer) would get
under 1 KiB (an estimate, not measured), and Rig cannot follow it there with stacks. Tokio's threads also carry
no 256 KiB signal stacks (fix 2), and its workers' allocations go to one malloc rather
than ten heaps fed blocks freed on other threads (fix 1 removes most of that traffic).

## 6. Decisions (defaults first)

1. Build fixes 1–3 as one runtime change, with the pool-thread alternate stack added
   (default), gated on bench/net, bench/http, bench/actors, bench/tasks on the Mac and
   pup, and Trig's light gate.
2. Re-time the 16 KB value row on a quiet pup before landing fix 1; if it holds,
   read straight into the String after a full block read (default).
3. Fix 4 (trim kept stacks at sleep) and fix 5 (records off `SmpAllocator`) wait until
   1–3 land and the allocator expert's changes are in, then are measured (default).
