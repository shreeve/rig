# mini-redis in Rig: the design (design and idiom expert, 2026-10-29)

Every claim below about what Rig accepts, emits or does was probed with
`$R` = the baseline `rig` at `81a1ef48`. The probes are in
`rust-ports/redis-probes/`. The main one is `server.rig`, 268 code lines:
frame, connection, Db actor with expiry, purge task, GET/SET(PX)/PUBLISH/
SUBSCRIBE, the connection limit, and Ctrl-C shutdown. It is driven by
a Python client
(`redis_client.py`, `hold.py`, `lim.py`, `idle.py` in the session
scratchpad). Under `RIG_SANITIZE=1`, all of these pass:
- SET and GET;
- GET of a missing key gives `$-1`;
- `SET t temp PX 50` is gone 120 ms later;
- an unknown command gets `-ERR unknown command 'FOO'`;
- a frame split across two writes;
- SUBSCRIBE to two channels, PUBLISH, and the message arriving;
- PUBLISH after the subscriber closes gives `:0`;
- 200 pipelined SETs.

Ctrl-C with an idle connection and a subscriber still open closes both
sockets and exits 130, with no leak report. With `MAX_CONNECTIONS = 2`,
the third client waits until one closes.

## 1. Layout

One program directory, `compare/rig/mini-redis/`, with sibling modules
(probe `lay/`: two files with `sub main` in one directory, each `use
frame`, both run):

| File | Holds | Rust it replaces |
|---|---|---|
| `frame.rig` | `type Bytes = *Frozen[String]`, `enum Frame`, `error Wire`, `parse`, `encode`, `bulk` | frame.rs |
| `conn.rig` | `obj Connection`: `read_frame`, `write_frame` | connection.rs |
| `db.rig` | `obj Db` (entries, subscribers, expirations), `obj Expiry: Ord`, `purge_task` | db.rs (and `DbDropGuard`) |
| `cmd.rig` | `enum Command`, `obj Args` (the frame cursor), `from_frame`, `apply`, subscribe mode | cmd/*.rs, parse.rs |
| `server.rig` | `sub main()!`, `serve`, `handle`, the connection permits | server.rs, bin/server.rs, shutdown.rs |
| `client.rig` | `obj Client` (`get`, `set`, `set_expires`, `publish`, `subscribe -> Subscriber`, `ping`) | clients/client.rs, blocking_client.rs |
| `cli.rig` | `sub main()!` over `std.os` arguments | bin/cli.rs |

- Rig has no async, so the blocking client is the client, and
  blocking_client.rs dissolves.
- `buffered_client.rs` (a task plus an mpsc channel that serialises
  calls) becomes `*Actor[Client]`, with no file: probe `verb.rig` runs
  an actor holding a `net.Stream` and calling `(!c).ping()!`.
- `shutdown.rs` dissolves (§4).
- Tests: Rust's `tests/server.rs`, `tests/client.rs` and
  `frame_validation.rs` become `test` blocks under their own names, in
  `server.rig`, `client.rig` and `frame.rig`.

## 2. Each type, its Rig form and its ownership

| Rust | Rig | Ownership |
|---|---|---|
| `Bytes` | `type Bytes = *Frozen[String]` (probe `weak.rig`) | A counted handle, frozen. `+b` is `Bytes::clone`. A GET hands the stored value to the reply frame with no copy, and one PUBLISH payload goes to N subscribers. This is the natural home of `*Frozen`. |
| `enum Frame` | `enum Frame { simple(text: String); failure(text: String); integer(n: Int); bulk(data: Bytes); null; array(items: List[Frame]) }` | Owned tree, no box (List holds the recursion). `error` is a keyword, so the variant is `failure`. |
| `frame::Error::{Incomplete, Other}` | incomplete is *absence*: `parse(src: ?String, pos: !Int) -> Frame?!Wire`; `error Wire { invalid(at: Int) }` | `pos` is a write view of the cursor (Rust's `Cursor`), moved past the frame only on success. `?? return none` inside match arms threads incompleteness out (probe `frame.rig`). |
| `Connection { stream, buffer: BytesMut }` | `obj Connection { stream: net.Stream; buf: String; pos: Int; out: String }` | Owned by the connection task. `read_frame(!@) -> Frame?!` parses in place (`parse(?@buf, !@pos)`: one field lent to read, one to write) and compacts with `@buf = String(@buf[@pos..])` only when it must read. `write_frame(!@, f: Frame)!` encodes into the reused `out` and writes once (Rust's `BufWriter`). |
| `Db { shared: Arc<Shared> }`, `Mutex<State>` | `*Actor[Db]` | `+db` per connection is `Db::clone`. Methods run one at a time; no lock to forget. `get` is `?@` (called bare, `db.get(k)`), `set`/`subscribe` are `!@` (`(!db).set(...)`). |
| `Entry { data: Bytes, expires_at: Option<Instant> }` | `obj Entry { data: Bytes; expires_at: Int? }` | Times are `time.since_start()` nanoseconds: an `Int` orders and needs no `Instant`. |
| `BTreeSet<(Instant, String)>` | `expirations: List[Expiry]`, `obj Expiry: Ord { at: Int; key: String }` with `order` reversed (latest first), `sort.lower_bound`/`sort.search` to insert and remove | Next to expire is the last element: peek `[len - 1]`, `(!v).pop()`. Probe `exp.rig`. |
| `pub_sub: HashMap<String, broadcast::Sender<Bytes>>` | `subs: Map[String, List[Sub]]`, `obj Sub { id: Int; inbox: *Chan[Msg] }` | One inbox per subscribing connection, registered under each channel. `subscribers(?@, ch) -> List[*Chan[Msg]]` hands back `+` handles; the connection sends outside the actor (§5, G7). |
| `broadcast::Receiver` per channel, `StreamMap` | one `*Chan[Msg](1024)` per connection; `enum Msg { message(channel: Bytes, data: Bytes) }` (with G6 closed: also `frame(f: Frame)` and `closed`) | The StreamMap dissolves: every channel feeds one inbox; the connection keeps a `Set[String]` of its channels and skips a message for one it has left (Rust drops the receiver). |
| `Notify` (`background_task`) | `wake: *Chan[Int](1)` plus `wake_pending: Bool` in the Db | `set` returns whether to wake; the connection sends. The flag means a wake is sent only when the channel is empty, so the send never waits: exactly `notify_one`'s stored permit. The purge task waits with `time.within(next - now, \|+wake\| (!wake).recv()!)` (probe K). |
| `purge_expired_tasks` + `DbDropGuard` + `shutdown: bool` | `sub purge_task(db: *Actor[Db], wake: *Chan[Int])!`, added to the server's `Tasks[Void!]` | Dropping the set cancels it with the connections. The guard, its `Drop`, and the `shutdown` flag all go. |
| `Semaphore(250)`, `OwnedSemaphorePermit` | `permits = *Chan[Int](MAX_CONNECTIONS)`, filled; `(!permits).recv()!` before `accept`; `defer release(+permits)` in `handle` | Probe `lim.rig` with 2. |
| `broadcast::Sender<()>` shutdown, `mpsc` completion, `Shutdown` | nothing: Ctrl-C cancels `main`; `serve` fails at `accept`; its `Tasks` drops, cancelling each connection at its next read and waiting for it | Probe `server.rig` + `hold.py`: exit 130, sockets closed, no leak. |
| `Command` + `Parse` | `enum Command { get(key: String); set(key: String, value: Bytes, expire: Int?); publish(channel: String, message: Bytes); subscribe(channels: List[String]); unsubscribe(channels: List[String]); ping(msg: Bytes?); unknown(name: String) }`; `obj Args { items: List[Frame]; at: Int }` with `next_string(!@) -> String!Proto`, `next_bytes`, `next_int`, `finish(?@)!Proto` | The verb is `enum Verb { get; set; publish; subscribe; unsubscribe; ping }` read with `Verb.from_text(lower(name))` (probe `verb.rig`), a closed set, so an enum, not symbols. |

### Error sets
- `error Wire { invalid(at: Int) }`: frame bytes that cannot be a
  frame.
- `error Proto { end; not_array; expected(at: Int); bad_option }`: a
  well-formed frame that is not a command (Rust's `ParseError`).
- `error Conn { reset }`: EOF partway through a frame.
- Plus `net.NetError` and `task.Stop`.
- `read_frame -> Frame?!` and the handler's `run -> Void!` fail with
  any of them. `handle` catches each one but `task.Stop.canceled`, logs
  it with `warn` (Rust's `error!`), and ends the connection:

```rig fragment
sub handle(id: Int, db: *Actor[Db], wake: *Chan[Int], stream: net.Stream, permits: *Chan[Int])!
  defer release(+permits)
  run(id, <db, <wake, <stream) catch |e|
    match e
      task.Stop.canceled => return e
      _ => warn("connection error:", e)
```

This keeps the server's `Tasks[Void!]` holding only live tasks: a set
of `Void!` tasks reaps those that ended well (probe reap).

### Commands
- **GET:** `db.get(?key)` gives `Bytes?`, `+e.data` from the actor.
  The reply is `Frame.bulk(data: <v)` or `Frame.null`.
- **SET key value [EX s | PX ms]:** `(!db).set(<key, <value, ttl)`
  gives the wake flag, then `!wake.send(1)!` and `+OK`. On overwrite,
  `set` removes the old `Expiry` (by `sort.search`), as Rust does.
- **PUBLISH:** `db.subscribers(?ch)`, then for each,
  `send_within(+s, Msg.message(...), time.MS)`. It replies with the
  subscriber count, as `broadcast::send` counts receivers.
- **SUBSCRIBE / UNSUBSCRIBE:** subscribe mode (§5, G6).
  `defer !db.unsubscribe_all(id)` cleans up on every exit, cancel
  included.
- **PING:** `+PONG`, or the message as bulk.
- **Unknown:** `-ERR unknown command 'name'`. In subscribe mode, any
  other command is unknown, as Rust's tests expect.

## 3. Sigils and forms: is mini-redis their natural home?

| Form | Use here | Home? |
|---|---|---|
| `*Actor` | `Db`; `*Actor[Client]` is the buffered client | **Yes, its central home** (both of the ledger's empty rows filled by one project) |
| `*Frozen` | `type Bytes = *Frozen[String]`: stored values, reply frames, published payloads | **Yes**, exactly Rust's `Bytes` |
| `T!E`, `e!`, `catch`, error sets with fields | `Frame?!Wire`, `Command!Proto`, `catch \|e\| match e`, `catch false`, `catch return` | **Yes** |
| `T?!` | `parse`, `read_frame`: incomplete or closed is absence, bad bytes are failure | Yes, defining |
| `f(x)&`, `Tasks` | one task per connection and the purge task in one `Tasks[Void!]` | Yes |
| `>t` | only in the tests and client examples; the server never waits, it cancels | weak |
| `*Chan` | inboxes, wake, permits | Yes, three uses |
| `task.select` | **none**: one inbox per connection replaces `select!` over StreamMap + socket + shutdown | not here; evidence that a single inbox dissolves most selects |
| `time.within` | purge sleep-or-wake, lag-dropping send | Yes |
| `<x`, `+x`, `?x`, `!x`, `@` | streams into tasks, `+db`, `+data`, `!pos`, `parse(?@buf, !@pos)` | everywhere |
| `defer` | `release(+permits)`, `unsubscribe_all(id)` | Yes: the only cleanup in the program |
| `drop(!@)` | none: `DbDropGuard` dissolves into the task set, and a permit can't be returned from `drop` (the send can fail) | no home; the forecast's guess is refuted |
| `~x`, `*w` | tried for the subscriber registry (auto-pruning dead inboxes); rejected: a `~Chan` cannot enter an actor (G15) | would be natural; blocked |
| enum names (`from_text`) | command verbs | Yes |
| symbols `:name` | none: the verb set is closed, so an enum is the right tool (STD says so) | no |
| `obj T: Ord` (own order) | `Expiry`, latest first | Yes, a real one |
| `keeps`, `from` | none (a free function's `from` is inferred) | no |
| `^T`, `*T`, `Cell`, `Table`, `*{A}`, `~{A}`, `once ?fun` | none | no |
| `match` with block arms as an expression, `?? return none` in an arm | `parse` | Yes |
| type alias | `Bytes` | Yes |

## 4. Shutdown, end to end

`sub main()!` listens, makes `db = *Actor(Db())` and `wake =
*Chan[Int](1)`, and calls `serve(<l, <db, <wake)!`. `serve` makes the
permits and `tasks = Tasks[Void!]()`, adds `purge_task(+db, +wake)&`,
and loops: take a permit, `accept`, and
`!tasks.add(handle(id, +db, +wake, <s, +permits)&)`. On Ctrl-C:

1. `main` is canceled, and `accept` (or the permit wait) fails with
   `Stop.canceled`.
2. `serve` unwinds and drops `tasks`, which cancels every connection at
   its next read and the purge task at its wait, then waits for each.
3. Each handler's `defer`s run (permit, unsubscribe), its `Connection`
   drops, and the socket closes.
4. `db` drops last, and the program exits 130.

Rust needs:
- `shutdown.rs` (49 lines);
- the `Shutdown` field in every handler;
- `select!` in `read_frame`'s loop;
- `notify_shutdown`, `shutdown_complete_tx`/`rx`;
- `DbDropGuard`.

Rig needs none of these.

A `Tasks[Void!]` dropped at the end of a function that can return
normally is rejected ("the tasks of `ts` can fail, and they are dropped
... without being waited for"). `serve` only ever leaves by failing, so
it is accepted. The same rule rejects a bare `purge = purge_task(...)&`
in `main`, which is why the purge task joins the set.

Test-harness note: a process started in the background by a
non-interactive shell inherits SIGINT ignored, and Rig keeps it so.
Scripts must reset it (`perl -e '$SIG{INT}="DEFAULT"; exec @ARGV'`) or
send SIGTERM (exit 143).

## 5. The gaps

### G6. No select on a socket, and no split stream. Blocking for subscribe mode.

A subscriber must wait on its socket (for UNSUBSCRIBE) and its inbox
(for messages) at once. Today the only form is polling, which the
probe ships:
- `time.within(POLL, recv)` on the inbox;
- then `time.within(POLL, read_frame)` on the socket.

A timed-out read leaves the stream and the buffer intact, and works
again. Measured with POLL = 2 ms (`idle.py`, release build, about 5 s):

| Idle subscribers | Server CPU |
|---|---|
| 0 | 0.01 s |
| 1 | 0.05 s, about 0.8% of a core |
| 10 | 0.09 s |

Each message, and each command in subscribe mode, waits up to 2 ms.
That is correct mini-redis behavior, but not the cost model Rig
promises, and a reference library should not teach polling.

**Smallest fix: `net.Stream.split(<@) -> (Reader, Writer)`.** In
`std/net.rig` that is about 15 lines: two objects over one fd, closed
when both drop. It also needs a runtime check that one poller
registration can hold a read waiter and a write waiter at once
(`accept` already lets several tasks wait on a listener).

With split, subscribe mode needs no select:
- a reader task parses frames and sends `Msg.frame(f)`, then
  `Msg.closed` at EOF, into the same inbox the publishers feed;
- the connection loops `while (!inbox).recv()! as m`.

The reader must never `close()` the inbox, because a later publisher
send would panic.

```rig pending
sub subscribed(id: Int, db: *Actor[Db], conn: Connection, first: List[String])!
  rd, wr = (<conn.stream).split()
  inbox = *Chan[Msg](1024)
  defer !db.unsubscribe_all(id)
  reader = pump(<rd, <conn.buf, +inbox)&
  ...
  while (!inbox).recv()! as m
    match <m
      .frame(f) => ...          # SUBSCRIBE, UNSUBSCRIBE, or unknown
      .message(channel: c, data: d) => ...
      .closed => return
```

An `on_read` arm for `task.select` would also close G6, but it needs
the scheduler to commit a socket read atomically with channel arms:
more work, and split already composes with what is built.

**Faithful with the workaround?** In protocol and results, yes. In cost,
no. **Default: close G6 (split) before subscribe mode lands.** Port the
rest now; land subscribe mode with polling only as a draft.

### G7. No `try_send`, no broadcast. Not blocking.

- `time.within(0, send)` fails even when there is room, because the
  deadline is checked first (probe `try.rig`), so a zero deadline is no
  `try_send`.
- **Publish:** `send_within(ch, m, time.MS)` (probe `weak.rig`: the
  first send succeeds, a send to a full inbox gives false after 1 ms).
  It drops the message for a subscriber that lags, as tokio's broadcast
  does (`RecvError::Lagged`, which mini-redis ignores). It runs
  **outside** the actor:
  - The Db hands back `+` handles.
  - A full inbox never stalls the Db.
  - It can't deadlock against a subscriber that is calling the Db.
    That deadlock would go unreported, because waits on channels are
    not followed.
  - The cost: a lagging subscriber delays its publisher by up to 1 ms
    per message.
- **Wake:** the `wake_pending` flag makes the capacity-1 send exact
  (§2), with no `try_send`.
- **Faithful:** yes.
- **Smallest fix:** `(!ch).try_send(<v) -> Msg?`, which gives the value
  back when the channel is full. Backlog.

### G8. No semaphore. Not blocking.

A filled `*Chan[Int](250)`: `recv` to take a permit, `send` to give it
back. `defer` can't hold a `catch`, so the give-back is
`sub release(p: *Chan[Int])` with `!p.send(1) catch return` (a
canceled handler at shutdown gives none back, which is harmless).
Probed with 2. Faithful. No fix needed.

### G9. No ordered map or heap. Not blocking.

The workaround is a sorted `List[Expiry]`, with `obj Expiry: Ord`
latest first, and `sort.lower_bound` / `sort.search`:
- **Same semantics** as `BTreeSet<(Instant, String)>`: exact removal on
  overwrite, and the earliest at the end.
- **Cost:** O(n) insert and remove (a memmove), against Rust's
  O(log n). That is fine at mini-redis scale.
- **Faithful:** yes. A `std` heap or ordered map would be a nice
  addition, but nothing waits on it.

### New findings

- **B-frozen-variant (bug, North Star 1).** An enum variant whose field
  is given an inline `*Frozen(...)` passes `rig check`, then Zig fails:
  `type '@typeInfo(Frame).union.tag_type.?' not a function`, because
  emit writes `Frame.bulk(rig.frozen(...))` as a call. The probe is
  `redis-probes/frozen-variant.rig`, with a copy in
  `port-probes/frozen-variant.rig`.
  - The same variant with `Int` or `String` fields runs.
  - Binding first (`d = *Frozen(<s)` then `Frame.bulk(data: <d)`)
    works: the port's `bulk(s)` helper.
  - Inside a `match` arm's value it also ran (`frame.rig`).

  Fix it first, from that case.
- **G15. A weak handle of a synchronized type cannot enter an actor.**
  `~inbox` (a `~Chan[Msg]`) is rejected: "a `~` handle whose count is
  not atomic". The weak registry is the natural form of broadcast's
  receiver count, with dead subscribers pruned by `*w` failing (it
  works outside an actor: `weak.rig` prints `gone`). The workaround is
  ids plus `defer unsubscribe_all`. Question for the owner: is `~` of
  `*Chan`/`*Actor`/`*Frozen` meant to be atomic? The design doc says
  `~rooms` exists for actors.
- **Papercuts:**
  - P9: the pattern binding `data` can't share a local's name, and
    `.message(channel, data: d)` mixes order and name, which is
    rejected.
  - P10: `match m` on a `?Msg` from `if got as m` can't take fields;
    write `if <got as m` and then `match <m`.
  - P11: `List` has no `retain` (Map does), so the unsubscribe walks
    the list with `swap_remove`.
  - P12: a `?Frame.null` argument must be written `?(Frame.null)`, so
    `write_frame` takes `Frame` by value.

## 6. Size (estimate, not measured)

The probe covers the server's core in 268 code lines. The Rust server
side is 1,203 code lines (server, db, connection, frame, parse,
shutdown, cmd, bin/server; no comments or blank lines). The full port,
with UNSUBSCRIBE, PING, `Args`, the client and the CLI, should land
near 550 to 650 lines against Rust's 1,900 or so without tests.

## 7. Decisions (defaults)

1. `type Bytes = *Frozen[String]` in `Frame.bulk`, `Entry.data` and
   messages. [yes]
2. The purge task joins the server's `Tasks[Void!]`. No guard, no
   `drop`, no shutdown flag. [yes]
3. G6: ask the owner for `net.Stream.split` (std plus a runtime check)
   before subscribe mode lands. Port the rest now; polling only in a
   draft. [ask; build split]
4. Publish sends outside the actor and drops for laggers after 1 ms.
   `try_send` goes to the backlog. [yes]
5. The subscriber registry is keyed by connection id, with
   `defer unsubscribe_all`. G15 (weak handles in actors) goes to the
   owner as a question. [yes / ask]
6. Expirations are a sorted `List[Expiry]` with `obj Expiry: Ord`. No
   std heap now. [yes]
7. The connection limit is a filled `*Chan[Int]` of permits. [yes]
8. `client.rig` is the one client. The buffered client is
   `*Actor[Client]`, with no file. [yes]
9. Fix B-frozen-variant first, from its probe, in its own worktree.
   [yes]
10. Layout: one directory, seven files, tests as `test` blocks. [yes]
