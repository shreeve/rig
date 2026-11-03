# Rig's server memory: the allocator and the memory map

Allocator and memory-map expert, 2026-10-29. Probe: `port-probes/redis-speed/kv.rig`
(a task per connection, the store a `*Actor[Db]`), load `load.rs` (SET/GET over 10,000
keys, 32 B values, P=1 unless said). Rig main `8c8f05319` (`rig 0.2.9`), `--release`
(safe) unless said. Variants were built from a copy of the emitted package
(`RIG_OUT_DIR`), patched, and compiled with `zig build-exe` on each machine; the
checkout was not touched. Scripts, diffs and raw runs: `reviews/mem-alloc-probes/`.
Mac: M5, 10 cores, 16 KiB pages, load 5 (other work). pup: 22 cores, 4 KiB pages, THP
`madvise`, 22 workers by default. RSS figures are `ps`/`VmRSS` mid-load. They vary by
up to 30% between runs where blocks pile up on free lists (the scheduler decides
which worker frees what). Timing here is only a check that nothing got slower, not a
measurement.

## 1. Reproduction

RSS mid-load, MB (Mac):

| C | Rig `--release` | Rig `--release=fast` | tkv | mini-redis |
|---|---|---|---|---|
| idle | 5.2 | 5.2 | 2.1 | 3.4 |
| 1 | 8.1 | 7.7 | 4.6 | 6.4 |
| 50 | 20–28 | 16 | 5.2–5.6 | 6.6–7.2 |
| 200 | 36–70 | 31–33 | 8.8 | 9.0–9.3 |

pup (22 workers): idle 7.5, C=1 9.7, C=50 22–37, C=200 50–63; tkv 3.3 / 5.2 / 5.7 / 7.0.
**The gap is not a fixed cost: it grows with workers × connections.** Varying the
workers at C=50 (Mac): W=1 7.9 MB, W=2 11.0, W=4 15.0–15.5, W=10 26.6–28.1, so about
2.2 MB per worker.

## 2. Where the bytes are (C=50, Mac, main, 20.3 MB dirty)

| What | MB | Cause |
|---|---|---|
| allocator segments | 10.1 (17.4 in a worse run) | 10 heaps × 1 segment. Carved 14.3 MB: **free lists 7.4, remote lists 5.0, live small 1.8**; Map table 1.4 live + 1.3 kept |
| task stacks | 3.6 | 191 stacks reserved for 50 tasks (chunks of 16 per worker); every one has its top page touched by the `FreeStack` link (16 KiB), and the 50 in use have 2 pages |
| `malloc` (dyld TLS) | 3.2 | Zig's `signal_stack_size` default, a 256 KiB **threadlocal** array: dyld callocs each thread's TLS (`malloc_history`: 272 KiB per thread) |
| small mmaps | 2.4 | runtime records through `std.heap.smp_allocator` (a 64 KiB slab per class per thread), heaps, the workers array |
| binary, dylib data | 0.6 | |
| page tables (footprint only) | 3.2 | one 16 KiB table page per touched 64 MiB stack |

pup, same load, 25.6 MB: segments 16.0, **thread TLS 5.5** (21 threads × 264 KiB: Zig's
own thread spawn zero-fills the TLS block, signal stack included), task stacks 2.1
(321 stacks: 270 hold one page for the link, 50 in use hold 20 KiB), other 1.5. At idle,
5.5 of pup's 7.5 MB is TLS signal stacks and 1.0 is the main heap's prefault.

Why the segments grow: each read makes a new 28 KiB block. `buf = String(?buf[pos..])`
then `read(!buf, 16384)`, and `ArrayList`'s 1.5× growth from 0 overshoots 16 KiB to the
28 KiB class. The task then resumes on another worker and frees the block there, onto
the owner's remote list. An owner takes back its remote list only when its own list
runs dry. Another heap can neither see nor use those blocks, so every heap carves
pages for the most buffers it ever had out at once: about **heaps × connections ×
28 KiB**. That is 10 × 50 × 28 K = 14 MB, the carved figure measured.

`--release` (safe) makes every byte of it resident. Zig's `Allocator.alloc` and
`free` `@memset` the whole block to `undefined` (0xAA) in safe modes, so a 28 KiB
buffer that holds 60 bytes is fully touched twice per read. Task stacks are also
deeper in safe builds: 20 KiB on pup against 8 KiB in fast, from undefined locals
being filled.

## 3. One change at a time (variants stack in this order)

RSS mid-load, MB:

| Variant | Mac C=1 | Mac C=50 | Mac C=200 | pup idle | pup C=1 | pup C=50 | pup C=200 |
|---|---|---|---|---|---|---|---|
| main | 8.1 | 20–26 | 52–70 | 7.5 | 9.7 | 22–37 | 50–63 |
| +steal remote lists before carving | 8.1 | 14.0 | 23.6–24.2 | 7.5 | 9.7 | 12.7 | 20.6–20.8 |
| +no TLS signal stack | 5.2 | 11.1 | 21.0 | 1.9 | 4.1 | 7.6 | 15.0–15.6 |
| +fresh stacks left untouched | 4.8 | 8.9–9.2 | 18.9–19.2 | 1.9 | 4.0 | 6.4 | 13.6 |
| +no prefault/huge advice (Linux only) | | | | 0.9 | 2.3 | 5.7 | 13.1–13.4 |
| same, `--release=fast` | 4.5 | 7.7 | 14.8–15.2 | | | 3.4 | 5.1–5.3 |
| tkv | 4.6 | 5.2 | 8.8 | 3.3 | 5.2 | 5.6 | 7.0 |

Controls:
- The program-side fix alone, `!buf.clear()` when the read is consumed (`kv2.rig`),
  gives Mac 14.0 / 23.6 and pup 12.7 / 20.0 at C=50 / 200. That is the same as the
  steal variant, so stealing makes the allocator robust to the churn by itself.
- With all fixes, workers stop mattering: W=1 7.1, W=4 8.5, W=10 9.2 MB (Mac, C=50).
- Speed of steal against main, best of 3 interleaved rounds (Mac, noisy), req/s:
  C=50 P=16 2.10M vs 2.01M; C=8 P=16 1.75M vs 1.58M; C=50 P=1 160k vs 154k.
  Not slower.

Large values (64 KiB, 100 keys, C=50, Mac): fixed Rig 44–58 MB under load and **62–78 MB
after it**, tkv 21 MB. Of that, 57–59 MB is freed large blocks held in the heaps'
caches. `keepBound` lets each heap keep `keep_large` = 16 MiB beyond its settled peak,
which comes to 160 MiB over 10 heaps. Per-heap `large_live` also drifts upward when a
block is freed on a heap other than the one that allocated it (`-|=` saturates on the
freeing heap). RSS rises *after* load in safe builds because `free` memsets blocks
that were never touched.

## 4. Recommendations, ranked by MB saved per unit of risk

1. **Steal another heap's remote list before carving a page.** Saves 6–12 MB at C=50
   and 28–46 MB at C=200 on both machines.
   - Where: `alloc.zig`, `Heap.alloc`, before `newPage`, plus a registry of heaps
     filled in `newHeap`. About 25 lines (`alloc-instr-steal.diff`, `stealRemote`).
   - Cost: none on the fast paths. The carve path makes one atomic load per heap
     per 64 KiB page.
   - Effect: the heaps carve a new page only when no remote list in the program
     holds a block of that class.
   - Trig: its remote lists are mostly empty, so behaviour should be the same, but
     it needs Trig's light gate and a timing round before it lands.
2. **Signal stack out of TLS.** Saves 264–272 KiB per thread: 2.7–3.0 MB on the Mac,
   5.5 MB on pup (it grows with the core count), and is idle's whole gap to tkv.
   - Where: not alloc.zig. The root's `std_options.signal_stack_size = null` (emit),
     and `attachSignalStack`/`workerMain` `mmap` their own `NORESERVE` alternate
     stack, faulted only when a signal runs on it. About 15 lines.
   - Cost: none.
   - Trig-safe.
   - Measured with `null` (no alternate stack). A 64 KiB TLS stack saves 2.1 of the
     3 MB.
3. **Leave fresh stacks untouched.** Saves 1.8–2.2 MB RSS and about 3.7 MB footprint
   (page tables) on the Mac at C=50; 1.2 MB on pup.
   - Where: `sched.zig` `takeStack`. Keep a chunk's unused stacks as a bump range on
     the worker instead of linking each one through its top page. About 10 lines
     (`sched-fresh-stacks.diff`).
   - Cost: none; fewer faults.
   - Trig-safe.
4. **Skip the safe-mode 0xAA fill in the runtime's containers.** Saves 2.3–8 MB at
   C=50 to 200 (pup C=200: 13.2 down to 5.2) and halves stack pages per task. It is
   also a CPU win: two 28 KiB memsets per read.
   - Where: `runtime.zig`'s String and List growth. Call `rawAlloc`/`rawRemap`/
     `rawFree` instead of `std.ArrayList` through `Allocator.alloc`/`free`, and size
     a read's reserve exactly (16 KiB, not 28 KiB).
   - Trig: faster if Trig times safe builds, unchanged if it times fast ones.
   - This changes what `--release` promises about undefined bytes, so it is the
     owner's call.
5. **Bound the large-block cache program-wide, and fix `large_live` for cross-heap
   frees.** Saves about 50 MB at 64 KiB values; nothing at 32 B.
   - Where: `keepBound`/`freeLarge`. Count kept bytes in one atomic against a single
     `keep_large` floor, or decommit kept blocks past a resident floor
     (`MADV_DONTNEED`; `MADV_FREE_REUSABLE` on macOS).
   - Trig risk: medium. The cache exists for Trig's rebuilt tables, so measure Trig's
     time and peak first.
6. **Prefault only from `prefault_big`, not for a heap that merely leads at start.**
   Saves 1.0–1.7 MB on pup (Linux only).
   - Trig risk: low but nonzero (about 2,000 extra faults in its first 8 MiB), so
     measure it.

With 1–3: Mac C=50 9 MB (tkv 5.2, mini-redis 7), pup C=50 6.4 MB (tkv 5.6). With 4 as well,
pup C=50 3.4 and C=200 5.2 MB, below tkv. What remains on the Mac is a task's two
16 KiB stack pages against a Tokio future's few hundred bytes (C=200: 6.4 MB of
stacks), and about 2 MB of `smp_allocator` slabs per process. Those belong to the
runtime's angle.
