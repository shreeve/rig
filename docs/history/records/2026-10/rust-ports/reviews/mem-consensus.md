# Rig's server memory: the panel's combined fix list (2026-10-29)

Three experts: [mem-alloc.md](mem-alloc.md) (the allocator, measured),
[mem-runtime.md](mem-runtime.md) (the runtime, measured, with a prototype patch) and
[mem-outside.md](mem-outside.md) (how Tokio, Go, Java and Erlang keep servers small; read, not
measured).

**The cause:** under load, Rig's memory grows with workers × connections. It is not a fixed
overhead.
- Each read makes a fresh 24–28 KiB buffer and holds it while the task waits.
- The task often resumes on another worker and frees the buffer there. The block goes on its
  owner's remote list, which no other heap reuses, so every heap grows to its own worst case.
- Safe builds fill every block, so all of it stays resident.
- Every thread has a zero-filled 256 KiB signal stack.
- A blocking call's 15.5 KB frame touches a second stack page.

## The fixes, in two PRs

**PR A, the runtime** (src/net.zig, src/sched.zig, src/runtime.zig, src/main.zig):

| Fix | Saves | Cost |
|---|---|---|
| A1. Read into the worker's block when the String has no room; keep only the bytes that came | about 6 MB at 50 connections (Mac), about 50 MB at 1,000 (pup) | one copy of the bytes read; the 16 KB row needs a quiet re-time |
| A2. The signal stack as a lazily faulted mapping, not thread-local; the blocking pool's threads too | 256–290 KiB a thread: 3 MB Mac, 5.6 MB pup | none |
| A3. The deadlock walk in `sched.block` moved to its own `noinline` function | one stack page a blocked task: about 16 MB at 1,000 (Mac) | none |
| A4. Fresh stacks left untouched until used (`takeStack`) | 1.2–2.2 MB, plus 3.7 MB of page tables (Mac) | none |

**PR B, the allocator** (src/alloc.zig, plus the runtime's String and List):

| Fix | Saves | Cost |
|---|---|---|
| B1. Before carving a page, take another heap's remote list for that class | 6–12 MB at 50 connections, 28–46 at 200 | fast paths untouched |
| B2. No safe-mode fill in the runtime's own String and List growth; reserve 16 KiB, not 28 | 2.3–8 MB (pup at 200 connections: 13.2 → 5.2) | faster: two fewer 28 KiB memsets a read |
| B3. The large-block cache bounded program-wide, with its live count fixed for a block freed on another heap | about 50 MB with 64 KiB values | small; measure first |

B1 is also the fix mimalloc-bench pointed at for cross-thread frees (sh8bench, part of
xmalloc-test). B3 is malloc-large's.

**Measured with the prototypes** (A1–A3; or B1–B4 from the allocator expert's stack):

| | Today | After | tkv (Tokio) |
|---|---:|---:|---:|
| Mac, 50 connections, under load | 17.9–20 MB | 8.4–9 MB | 5.2–5.3 MB |
| Mac, 1,000 connections | 86 MB | 26 MB | 25.6 MB |
| pup, 50 connections (22 workers) | 14.5 MB | 3.4–5.7 MB | 5.6–6.3 MB |
| pup, 1,000 connections | 72 MB | 9.0 MB | 19.8 MB |

With both PRs, Rig's server is at Tokio's memory or below. On the Mac it stays a few MB above,
for one 16 KiB stack page per live task, which is Rig's floor: Tokio's futures keep no stack.

**Later:**
- give idle pages back to the OS after a delay, as mimalloc and Go do (the outside view's
  fix 2);
- release ended stacks' pages when a worker sleeps;
- move task records off Zig's allocator;
- start workers lazily.

None needs a CORE or language change.

**Gates:**
- PR A: bench/net, bench/http, bench/actors and bench/tasks on both machines, and Trig's light
  gate. Trig uses no sockets, so A2 only lowers its peak memory.
- PR B: Trig's speed bar, std.json's guard and bench/hash's guard, plus mimalloc-bench rerun
  for sh8bench, xmalloc-test and malloc-large.
