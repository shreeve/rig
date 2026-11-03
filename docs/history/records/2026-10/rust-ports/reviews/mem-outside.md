# Rig server memory: the outside view

Expert on other runtimes, 2026-10-29. Sources: Rig's `docs/internals/scheduler.md`,
`docs/design/concurrency.md`, the headers and stack/heap code of `src/alloc.zig` and
`src/sched.zig`, `redis-measure.md`, and the probe `kv.rig`. Facts about other runtimes come
from what I already know, not from pages fetched today. Every saving below is an estimate. The
two experts measuring the allocator and the runtime should replace these estimates with numbers.

## What Rig does today (read from the source)

- **Task stacks.** Each one reserves 64 MiB of address space under a guard of 16 MiB or more.
  Pages are committed lazily, so small initial stacks, guard pages, and lazy commit are
  **already the model**. A task that is asleep holds at least one OS page: 16 KiB on the Mac,
  4 KiB on Linux. A stack keeps every page its fiber ever touched. Nothing is given back with
  madvise, either while the task is parked or while the stack sits on the worker's free list
  (up to 64 free stacks per worker; `releaseStack` only unmaps beyond that).
- **Heaps.** There is one per worker: 4 MiB segments, 64 KiB pages with one size class per
  page, and blocks carved lazily (`carve`). Pages never go back to their segment and segments
  never go back to the OS. Each heap keeps freed large blocks up to its settled peak plus
  `keep_large` = 16 MiB.
- **Workers.** There is one per core, which is 10 on the M5. Tokio also runs 10 workers, but
  over one shared malloc. Rig runs 10 heaps, each with its own floor and its own retention.
- **The probe.** It reads with `read(!buf, 16384)` and rebuilds `buf` after every read. Each
  connection therefore holds a buffer of 16 KiB or more across idle waits. mini-redis holds a
  4 KiB `BytesMut` and an 8 KiB `BufWriter`.
- **Per connection.** 50 connections at roughly 16–48 KiB of stack plus 16–32 KiB of buffer
  come to only 1.6–4 MB. Most of the gap of 12–14 MB is therefore **fixed overhead** (heaps ×
  workers, retention), not overhead per connection.

## How the others stay small

| Runtime | What an idle connection costs | Mechanism |
|---|---|---|
| Tokio | a task of a few hundred bytes plus the user's buffers (mini-redis: 4 KiB `BytesMut`, 8 KiB `BufWriter`) | stackless futures sized at compile time; the worker's stack is shared; system malloc (on macOS, libmalloc magazines plus a nano zone, freeing with `MADV_FREE_REUSABLE`) |
| Go | about 2–4 KiB (a 2 KiB stack plus the `g`) | stacks start at 2 KiB (sized adaptively since 1.19) and grow by copying; the GC shrinks a stack that uses under 1/4 of its size; per-P mcache spans of 8 KiB; a background scavenger returns pages (`MADV_DONTNEED`/`MADV_FREE`); one netpoller |
| Java virtual threads | hundreds of bytes to a few KiB | when parked, frames are copied to heap "stack chunks" and copied back lazily, with a return barrier |
| Erlang | about 2.7 KiB (338 words) | the heap and stack share one block, grown and compacted by copying GC; `hibernate` shrinks an idle process to a minimum |
| mimalloc | | thread heaps like Rig's, but an empty page returns to its segment, and free pages are purged after `purge_delay` (10 ms in v2) with `MADV_FREE`/`MADV_FREE_REUSABLE` or decommit; abandoned segments are reclaimed |
| jemalloc | | `dirty_decay_ms` = 10 s, decay over time, optional background thread; 4 arenas per CPU is its known RSS cost |
| glibc | | an arena per thread, up to 8 per core: the classic cause of bloated RSS, fixed with `MALLOC_ARENA_MAX=2`. Rig's heap per worker is the same shape. |

**These do not fit Rig.** Go's copied stacks, Java's heap chunks, and Erlang's copying all
**move frames**, and Rig's loans point into stacks ("Stacks never move"). Stackless futures are
a language change: function colouring, or a CPS lowering of every function that waits.
Segmented stacks have the hot-split problem, and Zig emits no stack probes on aarch64. Every
one of these would be a CORE or language change. None is needed.

## Recommendations, ranked by memory saved in a server with many idle connections

All of these are runtime or std changes. **None needs CORE or the language.**

1. **No buffer held across an idle wait.** This is what io_uring's provided-buffer rings,
   Netty's pooled buffers, and Rig's own HTTP server (`takeBlock`/`giveBlock`) already do.
   - **Design:** give `std.net` a read that, once the socket is readable, lends a 16 KiB block
     from the worker for the task to parse in place. Only the leftover partial frame is copied
     into an owned String. The new method's name is the owner's call.
   - **Saves:** 16–32 KiB per idle connection, which is 160–320 MB at 10k connections and
     about 1 MB at 50.
   - **Speed:** neutral or better, because the block stays hot in cache.
   - **Port fairness, now:** the port should read 4 KiB, as mini-redis does.
2. **Return idle allocator memory after a delay.** This is mimalloc's purge, jemalloc's decay,
   and Go's scavenger.
   - **Design:** keep a used count per 64 KiB page. Give an empty page back to its segment so
     any class can reuse it. After about 10–100 ms, purge free pages: `MADV_DONTNEED` on Linux,
     `MADV_FREE_REUSABLE` (with `REUSE` on reuse) on macOS. Decay the kept large blocks over
     time instead of holding them up to peak + 16 MiB. Release empty segments.
   - **Saves:** probably most of the fixed gap in RSS at rest after a burst (several MB per
     busy heap).
   - **Caveat:** it barely moves **peak** RSS under steady load, which is what `time -l`
     reports.
   - **Cost:** medium complexity in `alloc.zig`. The delay keeps it off the hot path. The
     std.json and hash guards must still hold.
3. **Fewer heaps touched.** This is the glibc arena lesson.
   - **Design:** start workers on demand: a worker starts only when the queues back up, much
     as Go starts Ms. A 50-connection server would then touch the heaps it needs, not 10. As a
     simpler alternative, cap the default at the number of performance cores.
   - **Saves:** the per-heap floor times the idle workers. Measure it first: run the probe
     under `RIG_WORKERS` set to 1, 2, 4, and 10 and record RSS.
   - **Cost:** low. Full-load throughput is unchanged once the workers have spun up.
4. **Trim stacks (Rig's form of Go's shrink-at-GC and Erlang's `hibernate`).**
   - **Design:** when a task has been parked longer than about 50 ms, the worker madvises the
     touched pages below the task's saved SP. When a stack goes on the free list, release
     everything but its top page. This needs a high-water mark, or a bounded range of about
     1 MiB below SP.
   - **Saves:** (touched depth − 1 page) per idle task. That is 16–160 KiB on the Mac for a
     task that once went deep, and a little on Linux.
   - **Cost:** one syscall per long park, plus about 1 µs per page refaulted when the task
     wakes. Hot connections pay nothing.
5. **Last: per-entry stack size from frame analysis.** The size of the reservation never
   reaches RSS, because commit is lazy. The only gain is sub-page stacks packed into one page,
   which is safe only with a *proven* bound covering the runtime's frames and the Zig library's
   frames, and no recursion. Rig does not prove that today, and an overflow there corrupts
   memory (North Star 2).
   - **Saves:** about 12 KiB per task on the Mac and about 1 KiB on Linux.
   - **Cost:** high.

## Measure on the right machine

The Mac's 16 KiB pages make each Rig task cost four times what it costs on Linux; Tokio's
malloc does not care about page size. Rerun the C sweep on pup before reading anything into a
per-connection gap. On macOS, `ru_maxrss` counts pages freed with `MADV_FREE` until the system
reclaims them, so also report `phys_footprint` (from `footprint` or `vmmap --summary`).
