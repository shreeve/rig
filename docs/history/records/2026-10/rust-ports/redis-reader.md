# mini-redis: tests, what the reader sees, and the line counts (Reader)

`rig` is the baseline at `81a1ef48`, from 2026-10-29. Every Rig claim below comes from a probe. The probes
are in `reader-probes/redis/`, beside this file:
- `sock.rig`, `vclock.rig`, `db_nolazy.rig`, `stop.rig`, `reap.rig`;
- `dirmod/`, a directory module with a `server_test.rig`;
- `draft/`, the two side-by-side drafts with their tests and a `main`;
- `ctrlc.py`, the Ctrl-C check;
- `tracing_lines.py`, the counter for the tracing lines.

Run each probe with `RIG_OUT_DIR=$(mktemp -d)`.

## 1. Tests

### Sockets under `rig test`: they work

`sock.rig` passes under `rig test --seeds=5`, `--seeds=20`, and with `RIG_SANITIZE=1`. It does
four things:
- starts a server task on `127.0.0.1:0`;
- connects to it;
- sends `PING\r\n` and reads back `+PING\r\n`;
- cancels the server.

`vclock.rig` combines sockets, deadlines and the virtual clock. It passes all 4 tests on 20
seeds, all 80 runs in 2.4 s of wall time:
- a reply sent at once arrives within 100 ms;
- a reply sent after 50 ms arrives within 100 ms;
- a reply sent after 200 ms misses a 100 ms deadline;
- a reply sent after a minute (slept on the virtual clock) arrives within two minutes, and the
  clock reads 60 s afterwards.

The scheduler documents why this holds (docs/internals/scheduler.md, "Deterministic runs"):
- With sockets registered, the virtual clock jumps only after bytes in flight have been taken,
  plus 1 ms of real time. So a jump never ends a socket wait early.

There is one caveat, from that doc and not reproduced here. A socket's readiness is real I/O,
so a seed fixes the scheduler's choices but not when the kernel delivers bytes. Replaying a
failing seed is best effort when sockets are involved.

### How a test starts the server (probed in `dirmod/`, run as `rig test redis`)

```rig
# Starts a server on a port the system picks: the port, and the server's
# task, which the test stops when it is done.
fun start_server() -> (Int, Task[Void!])!
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  return port, run(<l)&

fun stop(server: Task[Void!]) -> Bool
  <server.cancel() catch |e| return e == task.Stop.canceled
  false

test "key_value_get_set"
  port, server = start_server()!
  s = net.connect(String("127.0.0.1:", port))!
  return false if not exchange(!s, "*2\r\n$3\r\nGET\r\n$5\r\nhello\r\n", "$-1\r\n")!
  stop(<server)
```

`exchange(s, request, reply)` writes the request and compares exactly `reply.len` bytes, using a
five-line `read_n` that stands in for Rust's `read_exact`.

Rust's `tokio::spawn` makes a detached server. Rig has no detached tasks, so the test owns its
server. `stop(<server)` ends the test: it cancels the server, waits for it, and gives the
test's `true`. An early `return false` drops the server task, which cancels it too.

### The 15 Rust tests

| Rust test | Rig test | Status |
|---|---|---|
| frame_validation: `check_rejects_invalid_negative_bulk_length` | a pure call. `catch \|e\|` compares the error with `Parse.invalid`; Rust compares the message text | now |
| server: `key_value_get_set` | as above | **partly**: Rust half-closes with `stream.shutdown()`, then expects a read of 0 bytes. Rig's `Stream` has no write-half close, so the test loses its last check (gap N1) |
| server: `key_value_timeout` | `time::pause()` and `advance(1s)` become `time.sleep(time.SECOND)!`, since the clock is already virtual | now; probed at the Db level (`draft/redis/db_test.rig`, 20 seeds) |
| server: `send_error_unknown_command` | byte for byte | now |
| server: `send_error_get_set_after_subscribe`, `send_error_publish_after_subscribe` | byte for byte. The 1 s `timeout` becomes `time.within` | after subscribe mode |
| server: `pub_sub`, `manage_subscription` | "did not receive within 100 ms" becomes `time.within(100 * time.MS, \|!s, !b\| …)` and catching `Stop.timeout` (probed, `vclock.rig` test 3) | after subscribe mode, which polls until G6 |
| client: `ping_pong_without_message`, `ping_pong_with_message` (UTF-8), `key_value_get_set` | through the ported `Client` | after `client.rig` |
| client: `receive_message_subscribed_channel`, `…_multiple_subscribed_channels` | the detached publisher becomes `p = publish(port, "hello", "world")&`, with `>p!` at the end | after `client.rig` and subscribe mode |
| client: `unsubscribes_from_channels` | `sub.subscribed.len == 0` | after `client.rig` |
| buffered_client: `pool_key_value_get_set` | `client = *Actor(<client)`. Rust's `BufferedClient` (a task and an mpsc channel) is an actor. Probed: 3 tasks share one connection, 10 seeds (`draft/redis/client_test.rig`) | now |

That makes 14 of 15 writable with no change to Rig, and one written less its last check. None
needs Tokio's test utilities. Run them with `rig test --seeds=20 redis`.

### The seeds found a race in mini-redis's design

`db_nolazy.rig` is the Db as Rust writes it: `get` returns whatever is stored, and only the purge
task removes expired keys. Its expiry test **fails at seed 1**. The test task and the purge task
both wake at t = 1 s, and the test's `get` runs first. Tokio's `advance` happens to run the
purge task first, so the Rust test hides the race.

The Rig `get` checks `expires_at` against the clock, as Redis itself does. The purge task then
only frees memory. That passes on 20 seeds. This is the best "the seed finds it" story for the
README.

## 2. What the reader sees

The comments explain the ideas in Rig's terms, in the present tense. The code makes no Rust
comparisons; those live in the README. Both drafts are probed: `draft/redis/db.rig`,
`server.rig`, `main.rig`.

### Side by side 1: the Db with expiry

Rust (`db.rs`):
- `Db { shared: Arc<Shared> }`
- `Shared { state: Mutex<State>, background_task: Notify }`
- `BTreeSet<(Instant, String)>`
- `lock().unwrap()` in every method, and `drop(state)` before `notify_one()`
- `select!` of `sleep_until` against `notified()`
- `DbDropGuard`

Rig (49 code lines in all; the excerpt is about 34):

```rig
# The keys the server holds, each with its value and the moment, on the
# monotonic clock, it expires. One actor owns the store: its methods run
# one at a time, so no caller sees it half-changed, and no lock is taken
# or released by hand.
pub obj Db
  entries: Map[String, Entry] = Map()
  wake: *Chan[Int]
  next: Int? = none
  waking: Bool = false

  pub fun get(?@, key: ?String) -> String?
    e = ?@entries.get(key) ?? return none
    if e.expires_at as at and at <= time.since_start()
      return none
    +e.data

  pub sub set(!@, key: String, value: String, ttl: Int?)!
    at: Int? = none
    if ttl as ns
      at = time.since_start() + ns
    !@entries.put(<key, Entry(data: <value, expires_at: at))
    if at as t and t < (@next ?? t + 1) and not @waking
      @waking = true
      !@wake.send(1)!

  # Drops every expired key, and gives when the next one expires.
  fun purge(!@) -> Int?
    now = time.since_start()
    next: Int? = none
    !@entries.retain(|+now, !next, _, e|
      if e.expires_at as at
        return false if at <= now
        next = math.min(at, next ?? at)
      true
    )
    @next = next
    next

# Drops keys as they expire: it sleeps until the next one does, or until
# `set` wakes it for an earlier one. It runs until it is canceled.
pub sub purge_expired(db: *Actor[Db], wake: *Chan[Int])!
  while true
    if (!db).purge() as at
      woke = time.within[Bool](at - time.since_start(), |+wake| (!wake).recv()! != none) catch |e|
        return e if e != task.Stop.timeout
        false
      !db.woken() if woke
    else
      _ = (!wake).recv()!
      !db.woken()
```

**What dissolves:**
- `Arc`, `Mutex`, every lock and unlock, and the `drop(state)` ordering: these become
  `*Actor[Db]`.
- `DbDropGuard`: the purge task lives in the server's task set, and the set's drop cancels it.
- The `BTreeSet` and its bookkeeping on overwrite: the expiry lives only on the `Entry`.

**What does not dissolve:**
- **Notify.** With no `try_send` (G7), a one-slot channel plus a `waking` flag stands in for
  `Notify`. The flag means `set` never blocks inside the actor. That costs about 5 lines;
  `try_send` would remove them.
- **Purge cost.** `purge` walks every entry (G9: no ordered set). That is O(n) per wake, where
  Rust's is O(expired × log n). The Speed expert should weigh it.

### Side by side 2: shutdown

Rust:
- `server.rs` `run` (30 code lines): a `broadcast` to notify, an `mpsc` to learn that all
  connections ended, a `select!` against the shutdown future, then destructuring and dropping
  both senders;
- `Handler::run`'s `select!` of `read_frame` against `shutdown.recv()`;
- `Handler`'s `_shutdown_complete` field;
- all of `shutdown.rs` (24 lines).

Rig:

```rig
# Serves clients on `l` until it is canceled. Ctrl-C cancels `main`,
# and the cancel reaches `run` at its `accept`; the set then drops,
# which cancels the purge task and every connection's task, at the read
# each waits in, and waits for each to end.
pub sub run(l: net.Listener)!
  wake = *Chan[Int](1)
  db = *Actor(Db(wake: +wake))
  tasks = Tasks[Void!]()
  !tasks.add(purge_expired(+db, +wake)&)
  while true
    s = l.accept()!
    !tasks.add(handle(+db, <s)&)
```

`main` is `l = net.listen(...)!` followed by `redis.run(<l)!`.

`ctrlc.py` checks the shutdown. It starts the binary, connects 3 clients, and sends SIGINT. The
results:
- the process ends by SIGINT, which a shell shows as status 130;
- each client sees the connection close;
- nothing leaks, under `RIG_SANITIZE=1`.

Shutdown is zero lines of Rig.

In the port, `handle` is `while (!conn).read_frame()! as frame` / `Command.from_frame(<frame)!` /
`(!cmd).apply(+db, !conn)!`. That shape is not probed until `Connection` exists.

### Findings from these probes

| # | Finding | Route |
|---|---|---|
| N1 | `net.Stream` has no write-half close (`shutdown`), no `read_exact`, and no local address but `port()`. One Rust test needs the half-close | std backlog (small) |
| N2 | A failed task stays in a `Tasks[Void!]` until `>ts` (`reap.rig`). A server that never waits on its set grows by one record per failed client, so `handle` must catch its non-`Stop` errors and `warn` them, as Rust logs them | port rule; maybe a SPEC note |
| N3 | `x catch \|e\| return false if e != E` reports `e` as unbound. In block form, `return … if …` as the last line of a `Void` handler reports "`if` used as a value requires an `else`" | diagnostics PR |
| N4 | `(!s).read(!got, n - got.len)` is rejected: `got` is read while lent, though `!v.push(v.len)` is accepted for self | papercut, CORE list |
| N5 | `Int` has no `x.min(y)`, and a `Float` does. Ints use `math.min` | one word per idea; note |
| N6 | `when` is a keyword, so Rust's `when` local needs a new name | none |

## 3. Measures of code

Baseline from `sloc.py`. The Rust is as published, and test files are counted only in the tests
column.

| Rust files | Lines | Tokens |
|---|---:|---:|
| `lib.rs` | 19 | 138 |
| `connection.rs` | 100 | 882 |
| `frame.rs` | 222 | 1,671 |
| `parse.rs` | 84 | 707 |
| `db.rs` | 162 | 1,164 |
| `server.rs` | 115 | 779 |
| `shutdown.rs` | 24 | 134 |
| `cmd/` (`mod` 70, `get` 38, `set` 68, `publish` 33, `subscribe` 173, `ping` 37, `unknown` 23) | 442 | 3,562 |
| **server library** | **1,168** | **9,037** |
| less tracing (`use tracing`, `#[instrument]`, `debug!`/`info!`/`error!`; `tracing_lines.py`) | −21 | −196 |
| **headline** | **1,147** | **8,841** |
| clients (`client` 188, `buffered_client` 49, `blocking_client` 77, `mod` 6) | 320 | 2,912 |
| bins (`bin/server.rs` 54, `bin/cli.rs` 108; clap and the tracing setup) | 162 | 1,120 |
| tests (`server` 292, `client` 79, `buffered_client` 22, `frame_validation` 15) | 408 | 3,483 |

How the Rig is counted to match:
- **Headline:** the `redis/` module minus `client.rig`.
- **Clients row:** `client.rig`. `blocking_client.rs` has no counterpart: with no `async` in
  Rig, the Client already blocks. `buffered_client.rs` is `*Actor(<client)`. The README says
  so, rather than hiding 126 lines.
- **Bins row:** `server.rig` and `cli.rig`, which read their arguments by hand (`std.os`).
- **Tests column:** `*_test.rig`.
- **Lines that count:** Rig's `warn` lines for errors count as code. Rust's `lib.rs` (`pub mod`,
  `pub use`) counts, though a directory module needs none.
- **`sloc.py` needs one change:** a `*_test.rig` file counts only with `--tests`. Its helpers
  (`start_server`, `read_n`) sit outside `test` blocks, so today they would count as code.

The probed drafts are 49 lines (db), 17 (server, line protocol) and 14 (client); they are not a
forecast.

## 4. Decisions (default first)

1. **Layout:** a directory module `redis/`, one file per Rust module (`frame`, `parse`,
   `connection`, `db`, `cmd`, `server`, `client`), plus `server.rig` and `cli.rig` mains, run
   with `rig test --seeds=20 redis`. Default yes.
2. **Tests:** `*_test.rig` beside the module, one per Rust test file, with Rust's test names,
   not test blocks in the port files. Default yes.
3. **Expiry:** `get` honors `expires_at`, and the purge task frees memory. The README tells the
   seed-1 race. Default yes.
4. **Headline count:** the server library less tracing, 1,147 lines and 8,841 tokens. Clients,
   bins and tests are separate rows. Default yes.
5. **Ports of the clients:** port `client.rig` (it carries 7 tests); show `BlockingClient` and
   `BufferedClient` as dissolved. Default yes.
6. **Side-by-sides:** the Db's expiry and shutdown, with comments stripped on both sides
   (`excerpts.py --code`). The Db pair may run to 45 lines a side. Default yes.
7. **The half-close test** is written less its last check, and N1 goes to the std backlog.
   Default yes.
8. **Accept errors:** keep Rust's accept back-off loop, and leave out the 250-connection
   semaphore (G8), saying so. Default yes.
9. **Findings:** N3 goes to the diagnostics PR, N2 and N4 to the backlog. Default yes.
