# mini-redis: gaps and asks for Rig - Helper (2026-10-30)

From the mini-redis port (`~/Data/Code/rig/compare/rig/mini-redis/`) and its two reviews
(`reviews/redis-idiom.md`, `reviews/redis-speed.md`). Every probe is in `port-probes/` and
fails on main 71bbc1820.

## Bugs and gaps
1. **`redis-actor-cross-module/` (a valid program rejected):** an actor of an object from
   another module finds none of its `pub` methods (`actorCall`, `src/typecheck.zig`). It forced
   the port into one directory module.
2. **`redis-actor-bare-read-arg.rig`:** through an actor, a bare read argument `a.get(k)` is
   rejected with a misleading "keeps `k` lent". On a plain object the same call is accepted.
3. **`redis-actor-param-lend.rig`:** passing an actor handle down without cloning needs
   `!*Actor[T]` and a rebinding (`new db = <db`), and the error points the wrong way.
4. **`redis-optional-variant-eq.rig`:** `t == Tree.leaf` works, but the same test on a `Tree?`
   is rejected (N1's class, for enums).
5. **`redis-frozen-field-compare.rig`:** a `*Frozen[String]` field can't be compared with a
   literal.
6. **`redis-list-of-owners.rig`:** no literal builds a `List` of owned values (Rust's `vec![]`).
7. **`redis-text-lower.rig`:** `std.text` has no way to lower-case a String.
8. **`redis-send-after-close.rig`:** a send on a closed `Chan` panics. For `split()`, the reader
   task ends subscribe mode with a `closed` message, not by closing the inbox; decide whether
   send-after-close should panic.
9. **`redis-void-catch-if.rig`:** the misleading `catch` diagnostic (reader's N3) holds in the
   block form too. For the diagnostics PR.

## Speed asks (`reviews/redis-speed.md`, "Asks")
1. **`TCP_NODELAY` on Rig's TCP sockets.** Two lines in `src/net.zig` (accept and connect):
   50 connections x 16 pipelined commands go from 19.7k to 1.45M req/s on pup. Ceiling:
   `reviews/redis-speed-probes/ablations/nodelay.diff`. **Owner's decision pending:** on by
   default (Go's way, the reviewer's default) or a `Stream` option.
2. **`String(s)` of one view: one allocation and one copy,** not two copies through a writer.
   A nine-line patch: 16% fewer instructions per request.
3. **`*Frozen[String]` as one block** (count, length, bytes, like `Arc<str>`): one allocation
   per bulk string, not two. Unmeasured; about 2% of samples.
