# mini-redis in Rig: the panel's consensus (2026-10-29)

The three reports: [redis-design.md](redis-design.md), [redis-measure.md](redis-measure.md),
[redis-reader.md](redis-reader.md). Their probes are in `redis-probes/`,
`port-probes/redis-speed/` and `reader-probes/redis/`.

## Agreed (no decision needed)
- **Layout:** one directory, `compare/rig/mini-redis/`, with one file per Rust module:
  `frame`, `conn`, `db`, `cmd`, `server`, `client`, `cli`. `shutdown.rs` and the blocking
  client go away; the buffered client is `*Actor[Client]`.
- **Ownership:**
  - `type Bytes = *Frozen[String]`: a GET reply and a PUBLISH payload share the stored
    value.
  - `*Actor[Db]` replaces `Arc<Mutex<State>>`. The expirations are a sorted list, and the
    purge task is in the server's `Tasks`.
  - Shutdown is Ctrl-C cancelling `main` plus dropping `Tasks`.
  - The connection limit is a permit channel, with each permit given back by `defer`.
- **Expiry:** `get` checks `expires_at` itself, and the purge task only frees memory. The
  deterministic seeds found a race in upstream's purge-only expiry, which Tokio's paused clock
  hides; the README tells it.
- **Tests:** in `*_test.rig` files, under the Rust's test names. Sockets work under `rig test`
  (the seeds, the virtual clock, the sanitizer).
- **Line counts:** the headline is the server library without tracing (Rust 1,147 lines, 8,841
  tokens); clients, binaries and tests are separate rows.
- **Measuring:**
  - the load generator is `load.rs`; upstream mini-redis is the headline, with `tkv` (a plain
    Tokio server) as a control;
  - `--release` is the headline build, with `--release=fast` as a second row;
  - pup decides any gap under 10%.
- **The probe's numbers:**
  - one request at a time, a tie;
  - batched over 50 connections, 2.47M requests a second against tkv's 1.29M and
    mini-redis's 0.85M;
  - memory 3x Tokio's, which the memory panel is measuring.

## Owner decisions (defaults first)
1. **`net.Stream.split() -> (Reader, Writer)`, about 15 lines of std.** Without it a
   subscriber can't wait on its socket and its channel at once (G6), so subscribe mode polls:
   about 0.8% of a core for each idle subscriber, and up to 2 ms of added latency. With it, one
   inbox per connection replaces `select!`, and the Writer's `close()` gives the half-close one
   test needs. **[yes]**
2. **G15: an actor can't hold a weak `~Chan`.** That would let it drop dead subscribers on its
   own. The port keys subscribers by connection id and unsubscribes with `defer`, which works.
   **[no change now; recorded]**
3. **`try_send` (G7):** publish runs outside the actor and drops a message for a subscriber
   that stays full for 1 ms, as Tokio's broadcast drops messages for a subscriber that lags.
   **[the backlog]**

## Routed
- The `*Frozen(...)` variant bug went to Rig - Helper.
- Two misleading `catch` diagnostics go to the diagnostics PR.
- Backlog notes:
  - a failed task stays in `Tasks` until it is waited on;
  - an argument is rejected for reading what the same call lends to write.
