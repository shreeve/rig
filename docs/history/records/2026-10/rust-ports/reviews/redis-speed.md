# Speed review: mini-redis (2026-10-30)

Rig main 71bbc1820 built on pup; the port as the builder left it (`v0`), and once the idiom
review's tree (`idiom`). Upstream mini-redis 0.4.1 with LTO and one codegen unit,
`target-cpu=native`, tracing on; `tkv` the plain Tokio control. Load: `load.rs` (SET and GET
alternating, 10,000 keys, 32-byte values). pup, x86 Core Ultra 9 185H. Probes, variants, scripts,
profiles and raw runs: `reviews/redis-speed-probes/` (`runs/`, `ablations/`, one directory per
variant, `*.diff` for each port change). pup scratch is removed.

**How measured.** Main table: server on P-cores 0,5,1,2,3,4 (`RIG_WORKERS=6`; Tokio follows
the mask), load on 6-11; 3 s a case, 5 interleaved rounds, best of 5. Other agents' release builds
started on cores 0,5 / 1,2 / 10,11 during rounds 3 to 5; rounds 1 and 2 were quiet and hold every
best. Later runs moved off the release slots: server 3,4,6,7 (4 workers), load 8,9,12-19. Pup
stayed loaded (load 6 to 11), so req/s differences under about 8% there are noise, and the
per-command changes are judged by **user instructions per request** (`perf stat -e
instructions:u` on the server ÷ requests, 3 rounds, steady to 0.1%), cycles as a noisy second.

## 1. Numbers

### As shipped (best of 5, req/s; peak RSS over the run)

| C:P | port `--release` | port `--release=fast` | mini-redis | tkv |
|---|---:|---:|---:|---:|
| 1:1 | 103,252 | 107,490 | 104,163 | 102,972 |
| 50:1 | 822,153 | 822,814 | 760,336 | 814,564 |
| 1:16 | **396** | 395 | **395** | 1,187,363 |
| 50:16 | **19,707** | 19,730 | **19,722** | 3,433,380 |
| peak RSS | 7.9-8.6 MB | 6.9-7.6 MB | 6.4-6.9 MB | 5.1-5.4 MB |

**Pipelined, the port and upstream both stall 40 ms a batch on Linux.** Both write a reply frame
at a time on a socket without `TCP_NODELAY`; Nagle holds the second small write until the
client's delayed ACK (p50 41 ms). The Mac probe did not show it (macOS acks differently, and the
probe wrote once per read). tkv writes once per read and never stalls. One request at a time all
four tie; at 50 connections unpipelined the port is 8% faster than mini-redis (both quiet rounds)
and level with tkv, which is about where the load client tops out.

### With `TCP_NODELAY` on the server's sockets (Rig: 2 lines in `src/net.zig`'s `acceptOne`; mini-redis: `socket.set_nodelay(true)`)

| C:P | port | port fast | mini-redis | tkv |
|---|---:|---:|---:|---:|
| 1:16 | 311,563 | 312,596 | 304,354 | 1,187,363 |
| 50:16 | 1,446,194 | 1,459,188 | 1,404,444 | 3,433,380 |
| 50:1 | 813,645 | 813,757 | 757,558 | 814,564 |

The port and upstream are level pipelined (3% apart, within the noise), both bound by a `write(2)`
a reply: per request the server runs 18,170 kernel instructions against 3,341 of its own. Per
request the port runs **26% fewer user instructions than mini-redis** (3,341 against 4,520), at
about 1,500-1,700 user cycles against 2,550.

### Writing once per read (the `batch` row: `write_frame` encodes, `flush` writes before the next socket read; both sides batch)

| C:P | port | port fast | tkv |
|---|---:|---:|---:|
| 1:16 | 1,023,182 | 1,027,771 | 1,187,363 |
| 50:16 | **4,086,894** | **4,295,704** | 3,433,380 |

Batched over 50 connections the port is 19% faster than tkv (25% with `--release=fast`), as the
Mac probe found (there 2.47M against 1.29M). On one connection tkv is 16% faster: per request tkv
runs 1,735 user instructions and 626-730 cycles; the port 3,270 and 1,290-1,480. The batch
variant also never stalls on the shipped Rig (no `TCP_NODELAY`): 2.54M at 50:16 against tkv 2.95M
on a busier pup, 4 workers.

**The idiom tree** is the same speed: 3,324 user instructions a request against 3,341, 1:16 req/s
within noise.

**Memory** (6 workers, 50 connections): the port 7.9-8.6 MB, fast 6.9-7.6, mini-redis 6.4-6.9, tkv
5.1-5.4. The port's own buffers are about 8 KiB a connection (`buf`, `out`), 0.4 MB of it; the rest
is what memory PR A and B target (the panel's prototypes reached 3.4-5.7 MB at 50 connections on
pup). Nothing for the port to change; rerun this row when PR A lands.

## 2. Where the time goes

Profile of the batch variant at 1:16 (`perf record`, 4 workers): 53% kernel, 47% the server.
Shares of all server samples:

| Cost | Share | Who can remove it |
|---|---:|---|
| Kernel: read, write, epoll | 53% batched; 85% of instructions with a write per frame | the port's flush per frame (upstream's choice); std: `TCP_NODELAY` |
| `parse` building the Frame tree: a `List` per command, two allocations per bulk string (its `String` and the `*Frozen` box), Frame copies | 11% | runtime (one-block frozen text, unmeasured); upstream builds the same tree |
| `String(s)` copying through `std.Io.Writer` into a 256-byte stack buffer, then a second copy | 7% | runtime (measured below) |
| Drops: the Frame list, frozen boxes, frees | 5% | follows the allocations |
| `from_frame`, `lower`, name match | 4.5% | port (name copy, measured) |
| `text.parse_int` | 4% | nothing: a decimal fast path saved no instructions (3,288 against 3,270) |
| Scheduler: poll, loop, steal, task start | 5% | none found |
| Allocator | 2.5% | follows the allocations |
| Actor call (`invoke`) and the key's hash | 2% | none: the uncontended call runs inline |

At 50:16 batched, **31% of samples are `claimSpinning`**: callers spinning on the one Db actor
that every connection shares. Spinning less is slower (spins 4 → 1: 2.88M; none: 2.31M; against
3.71M), so the spin is right and the cost is the single store, as mini-redis's own `Mutex` is.
Fewer `pause`s per spin (32 → 4) made no difference. A sharded store (one actor for each of N key
ranges) is the remedy; it is a port design change away from upstream, not measured.

Bounds checks: `line`'s `src[i]` and `src[i + 1]` are unproven (`--facts=proofs` proves only
`lower`'s index), since `pos` is not known to be non-negative. `--release=fast` runs 13% fewer user
instructions (2,898 against 3,341) and no more requests.

## 3. Port changes

| Change | User instructions a request | req/s | Verdict |
|---|---|---|---|
| **Name as a view**: `Args.next_text` returns `(?String) from @items`; `lower(!args.next_text()!)`, and `next_string` is `String(!@next_text()!)` | 6% fewer (3,341 → 3,147 per frame; 3,270 → 3,071 batched) | within noise | **adopt**: no copy made just to be lowered, and one more method that reads plainly. `proposed-names.diff`, against the idiom tree; 16 tests pass on 3 seeds |
| GET's key shares the frame's bytes: `get(key: Bytes)`, `next_bytes()` | 3% more on top (3,047 per frame; 2,969 batched with names) | within noise | optional: GET and SET then hold their keys differently. `keyshare.diff` |
| **Flush once per read** (`flush` in `read_frame` before it waits; subscribe mode flushes after each write) | n/a | 2.8× at 50:16 with `TCP_NODELAY`; 129× on the shipped Rig | the batched row only, as the fairness rule says; upstream flushes per frame. `batch.diff` |

None changes the headline row: with a write per frame the port's own code is 15% of the server's
instructions.

## 4. Runtime and std asks, each with its ceiling

1. **`TCP_NODELAY` on Rig's TCP sockets** (`src/net.zig`, accept and connect). Without it any
   program that writes a reply in pieces stalls 40 ms on Linux: the port goes from 19,707 to
   1,446,194 req/s at 50:16, and 396 to 311,563 at 1:16. Go sets it on every TCP connection; Tokio
   leaves it to the program, and Rig has no way to set it. Ceiling: `ablations/nodelay.diff`, two
   lines. Owner decision: on by default (Go's way, default) or a `Stream` option. Gates: bench/net
   and bench/http on both machines.
2. **`String(s)` of one view: one allocation and one copy.** Today `String.of` writes every piece
   through a `std.Io.Writer` into a stack buffer, then allocates and copies again. Ceiling
   (`ablations/ofdupe.diff`, 9 lines in `ofPieces`): **16% fewer user instructions a request**
   (3,270 → 2,761) and 11% fewer user cycles (fastest of 3, a loaded pup). It reaches every
   program that copies text. The same for several pieces that are all text: add the lengths, one
   allocation, one copy each.
3. **`*Frozen[String]` in one block** (count, length and bytes, as Rust's `Arc<str>`), so
   `*Frozen(String(s))` allocates once. Two allocations per bulk string become one: about 2.5 fewer
   allocations and frees a request here. Unmeasured; `frozen` and `dropLast` are 2% of samples, with
   a share of `alloc` and `free` (4%).
4. **Kernel work per request** is 11% above tkv's when batched (1,849 against 1,667 instructions):
   unexplained; strace is not allowed on pup. Worth a look at the read and re-arm path in
   `src/net.zig` when PR A touches it.

Not asks: `parse_int` (no gain); the actor's spin (right as it is).
