# mini-redis: how to measure the Rig port against Tokio

Speed and measurement expert, 2026-10-29. Probe sources and raw runs:
`port-probes/redis-speed/` (kv.rig, load.rs, tkv/, run.sh, mac-run1.txt, mac-run2.txt).
Probes built with the baseline Rig `81a1ef486` (`rig 0.2.9`).

## 1. The workload

**Tools.** `redis-benchmark` and `memtier_benchmark` are not installed on the Mac or pup.
The mini-redis client (`mini-redis-cli`, `clients/client.rs`) makes one connection per
process and has no pipelining, so it cannot load a server. The plan uses a load generator of
our own, `load.rs` (std-only Rust, `rustc -C opt-level=3 -C target-cpu=native`): C
connections, a thread each, `TCP_NODELAY`, each sending a batch of P commands (SET and GET
alternating over K = 10,000 keys, V-byte values) and waiting for all P replies; it prints
req/s and the batch latency p50/p99. The same binary loads every server. If the owner
installs Redis (`brew install redis`), `redis-benchmark -t set,get -c C -P P -n N -r 10000
-d V --threads 4` becomes a second, independent client; a thread per connection stops
scaling past about 200 connections, so for C = 1,000 we need it or an event-driven mode in
`load.rs` (mio is cached).

**The cases** (each 3 s, servers interleaved, best of 3 rounds; 20 rounds for any gap under 2%):

| Case | C | P | What it shows |
|---|---|---|---|
| latency | 1 | 1 | one wake each way: socket + scheduler latency |
| throughput | 50 | 1 | many sockets ready at once |
| pipelined | 1, 8, 50 | 16 | parse and store cost, no syscall per command |
| many | 200 (1,000 with redis-benchmark) | 1 | scheduler with many idle-ish connections; mini-redis caps at 250 (`MAX_CONNECTIONS`), so the port keeps the cap and the case stays under it |
| value size | 50 | 16 | V = 32 B, 1 KiB, 64 KiB: copies against shared `Bytes`, and the allocator's cross-thread frees of blocks over 32 KiB |
| pub/sub fan-out | 1 publisher, S = 1, 10, 100 subscribers on one channel | | messages delivered per second and publish-to-receive p99; needs a `--pubsub` mode in load.rs (SUBSCRIBE, then PUBLISH with a timestamp in the payload) |
| churn | 64 clients, each: connect, SET, GET, close, repeat | | accept, task spawn, close; on the Mac wait for `sysctl net.inet.tcp.pcbcount` to fall between runs (TIME_WAIT, bench/net README) |

**Measures.** req/s and p50/p99 from the client. Server CPU and peak memory from
`/usr/bin/time -l` (Mac) or `/usr/bin/time -v` (pup) around the server, killed at the end;
report CPU as µs of user+sys per request. Check correctness before timing: a GET after a SET
returns the value (done for all four probe servers).

**Machines.** arm64 on the Mac (client and server share the cores: no `taskset` on macOS,
so the Mac rows are partly client-bound, as bench/http's are). x86 on pup: server on P-core
pairs `taskset -c 0,5,1,2,3,4` with `RIG_WORKERS=6` (Tokio's `available_parallelism` follows
the affinity mask already), client on `taskset -c 6,7,8,9,10,11`; loopback; pup's
`/zfs/trig-pup/rig-next/bin/rig` or a Rig built there, Rust built there. Never on burst.

**Builds.**
- Rust: upstream source unchanged, plus `[profile.release] lto = true, codegen-units = 1`
  (no `panic = "abort"`: upstream unwinds), `RUSTFLAGS="-C target-cpu=native" cargo build
  --release --locked`. Upstream's `#[tokio::main]` is the multi-thread runtime with one worker
  per core; keep it. It does not build `--offline` (the optional `opentelemetry` deps are not
  cached); online it builds in 16 s (owner approved the downloads). Run with
  `mini-redis-server --port N`; its `tracing` subscriber at INFO stays on, as upstream ships it.
- Rig: `rig build --release -o mini-redis-rig` as the headline row, `--release=fast` as the
  second row (bench/ uses fast).
- A fair-shape Tokio control, `tkv` (built `--offline` from the cached tokio 1.53): the same
  parse and reply logic as the Rig probe, `Arc<Mutex<HashMap<String, Bytes>>>` as mini-redis
  keeps it, one write per read. It separates "Rig against Tokio" from "Rig against
  mini-redis's choices" (a `Frame` allocated per command, a flush per frame, tracing).

**Fairness rule.** The port keeps mini-redis's semantics: one flush per reply frame, as
`Connection::write_frame` does. Writing once per read batch is a valid optimization, but it is
measured as a separate row on both sides (tkv does it), never as the port's headline.

## 2. The hot path, Rust against Rig

Per command, mini-redis does: `read_buf` into a 4 KiB `BytesMut`; `Frame::check` over a
`Cursor`, then `Frame::parse`, which allocates a `Vec<Frame>` and a `Bytes` per bulk string
(slices of the read buffer via `copy_to_bytes`, shared, no copy); `Command::from_frame`
(a `String` for the key); `Db::get` takes the `std::sync::Mutex`, clones the `Bytes`
(an atomic increment); `write_frame` through a `BufWriter`, five small `write_all`s and one
`flush` = one `write(2)` per reply frame.

Rig's equivalent, read from the source:
- **Sockets are event-driven, not on the blocking pool.** `src/net.zig`: each socket is
  non-blocking and registered with a worker's poller; `read_from` tries `read(2)` and on
  `EAGAIN` parks the task (`sched.waitReady`); `write_to` likewise. So the `std.file`
  18 µs-a-call problem does not touch the request path. bench/net has Rig level with Tokio on
  the Mac (pingpong 14.0 against 14.1 µs, echo 5.9 against 5.7 µs, connect 46 against 57 µs).
  On pup the latest echo rows (4.5 µs on core 6 alone, 3.6 µs on cores 6,7) are pinned to one
  or two cores; Tokio's 1.6 µs reference ran unpinned, so it needs re-running pinned before
  anyone reads a gap into it.
- **The store.** `Mutex<State>` becomes a `*Actor[Db]`: 5 ns a call solo, 31 ns contended on
  the M5, against Tokio's own actor at 135 and 269 ns, and Go's mutex at 3.5 and 79 ns
  (bench/actors). A `std::sync::Mutex` uncontended is about the same as Rig's solo call;
  contended, the actor wins (below).
- **Parse.** A view parser over the read String (`?buf[a..b]`, `text.find`,
  `text.parse_int`) allocates nothing until a key or value is stored. Cheaper than
  `Frame::parse`'s `Vec` and `Bytes` per command.
- **Copies.** SET copies key and value out of the read buffer on both sides (Rust's
  `Bytes` slice keeps the whole 4 KiB read block alive instead; that is a share, not a copy).
  GET is the difference: Rust clones a `Bytes` (one atomic add), Rig's actor returns
  `String(v)`, a copy. For 32 B a copy costs about what the atomic does; at 64 KiB it is a
  memcpy plus a block that is allocated on the actor's worker and freed on the connection's,
  the allocator's weak case. The remedy, if the 64 KiB row loses: keep values as frozen
  shared `*String` in the `Map` and return a share (unverified that `Map[String, *String]`
  through an actor emits as cheaply as hoped; probe it when the port is written).
- **Read buffer.** `String` has no "drop the first n bytes" (`SPEC.md` String table:
  `add`, `push`, `reserve`, `clear`, views), so leftover bytes after a partial frame are
  re-copied into a fresh String: `buf = String(?buf[pos..])`. With P = 1 the port should
  `!buf.clear()` when `pos == buf.len` (no allocation). A partial frame at the end of a read
  is rare except for large values.
- **Pub/sub.** `Subscribe::apply` is a `select!` over a socket read, a `StreamMap` of
  broadcast receivers, and shutdown. `task.select` takes channel arms only
  (`on_recv`, `on_send`), not a socket read, so the Rig port needs a reader task and a
  writer task per subscriber joined by a `*Chan` (or the actor pushes into each
  subscriber's `Chan`). That is one more task wake per delivered message than Tokio's
  `select!`; the fan-out case measures it.

## 3. The probe (Mac, M5, 10 cores, load 2–3, client and server sharing the machine)

`kv.rig`: a RESP GET/SET server, a task per connection in a `Tasks[Void]`, the store a
`*Actor[Db]` holding `Map[String, String]`, view parse, one write per read. `tkv`: the same
in Tokio. Best of 3 interleaved rounds (2 for the second table), req/s:

| Case | rig (`--release=fast`) | rig (`--release`) | tkv (Tokio) | mini-redis |
|---|---|---|---|---|
| C=1, P=1 | 66,655 (p50 14.2 µs) | 61,622 | 66,232 (14.2 µs) | 63,245 (15.2 µs) |
| C=50, P=1 | 160,269 | 157,388 | 166,956 | 164,562 |
| C=50, P=16 | **2,473,926** (p99 632 µs) | 2,224,218 | 1,294,607 (p99 1,151 µs) | 848,707 (p99 1,661 µs) |
| C=1, P=16 | 817,549 | | 847,352 | 427,075 |
| C=8, P=16 | **1,900,436** | | 1,306,441 | 698,962 |
| C=200, P=1 | 159,313 | | 168,598 | 168,204 |
| peak RSS (3 cases) | 18–20 MB | 23–26 MB | 6.1–6.2 MB | 7.5–7.7 MB |
| server CPU per request (round 1) | 2.6 µs | | 6.0 µs | 8.2 µs |

Read:
- **Unpipelined, all four tie** at 14 µs a round trip and 160–167k req/s: the client threads
  and the kernel bound these on the Mac. Rig is 4% slower at C=50 and 5.5% at C=200, in both rounds;
  within what client-bound runs can show, so pup decides it.
- **Pipelined with contention, Rig is 1.9× tkv and 2.9× mini-redis** (C=50) and 1.45× tkv at
  C=8. tkv's system time is 1.7× Rig's: the `std::sync::Mutex` contended across 10 workers
  parks threads; the actor does not. This is a real Rig advantage over mini-redis's design,
  not over Tokio as such (a sharded map would narrow it); report it with that caveat.
- **Pipelined without contention (C=1), Rig is 3.5% slower than tkv**: the actor call and the GET
  copy per command against an uncontended lock and a refcount.
- **mini-redis is half of tkv pipelined**: its flush per frame (16 `write(2)`s where tkv
  does one), a `Frame` tree per command, and tracing spans.
- **Memory: Rig holds 3× the RSS** at 50 connections: per-worker heaps of the release
  allocator and a stack page per task. Idle-connection memory (bench/http) is lower than
  hyper's, so this is fixed overhead, to be confirmed by a C sweep (1, 50, 250).

## 4. Prediction

- **Win:** pipelined and multi-connection throughput (actor against a contended mutex);
  CPU per request; tail latency under contention (p99 half of tkv's).
- **Tie:** unpipelined latency and req/s (system calls dominate); churn (bench/net connect
  is level or better); small-value GET/SET at C=1.
- **Lose:** peak memory (3× at 50 connections); pub/sub fan-out (an extra task hop per
  message without a socket arm in `select`); large values (64 KiB GET copies and
  cross-thread frees over 32 KiB); possibly 4 to 6% at C≥50 unpipelined, to be settled on pup.

**What to fix first if it loses, by file:**
1. Large values: `src/alloc.zig` (cross-thread frees over 32 KiB; mimalloc-bench finding),
   then the port's value type (shared frozen values, no copy on GET).
2. Fan-out: a socket-readable arm for `task.select` (`std/task.rig`, `src/tasks.zig`,
   `src/net.zig`'s `waitFor`), a design item for the owner, not a fix.
3. Memory: worker heap retention in `src/alloc.zig` and the block cache in `src/sched.zig`
   (`takeBlock`, 64 blocks a worker).
4. Unpipelined gap at many connections, if pup confirms it: the wake path in `src/sched.zig`
   (`waitReady`, run-next) and the per-loop tick (2–8% in hot loops).
5. Read-buffer compaction: a String method to drop a prefix in place (`std` String; naming
   is the owner's), only if the partial-frame path shows in a profile.

## 5. Decisions (defaults first)

1. Load tool: our `load.rs` (default), with `redis-benchmark` as a cross-check only if the
   owner installs Redis.
2. Headline Rig build: `--release` (default), `--release=fast` as a second row.
3. The port flushes once per reply frame, as upstream (default); batch-per-read is a
   separate row on both sides.
4. The Tokio rows: upstream mini-redis (headline) plus the `tkv` control (default), so a win
   from the actor is not credited to Rig against Tokio itself.
5. pup is the authority for any gap under 10% (default); the Mac rows are reported as
   client-bound.
6. Rust build: LTO, one codegen unit, native CPU, unwinding kept, tracing kept (default).
