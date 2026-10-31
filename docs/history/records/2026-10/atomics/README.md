# Atomics without orderings (2026-10-30)

A design note, not yet approved. Rust offers five memory orderings on
every atomic and leaves the choice to the programmer. Rig offers one,
sequentially consistent. This note measures what that choice costs, and
proposes built-in forms for the cases where Rust programmers reach for a
weaker ordering. Each form is held to the speed of a hand-tuned Zig ceiling,
and none needs an ordering in the program's source. The measurements are in
[measurements.md](measurements.md).

## Rig today

- **The operations.** A `Cell` of one word (`Int`, `Bool`, `Float`, or an
  enum without data), in a program that makes tasks, does every operation
  as one atomic instruction at `.seq_cst`: `get`, `set`, `swap`,
  `compare_swap`, `add`, `sub` (src/runtime.zig, `Cell`; SPEC §Cell,
  "Across tasks"). Anywhere else a Cell is plain memory.
- **No data races.** Safe code cannot race. Only synchronized types cross
  cores: a one-word Cell, a `Chan`, an `Actor`, and a frozen value.
- **The runtime's own counts.** A shared handle's counts are atomic for
  those types, with `.monotonic` increments and `.acq_rel` decrements, as
  Rust's `Arc` does. That choice is the runtime's, and never the program's.

## What seq_cst costs (Apple M5; x86-64 from its instructions)

- **Nothing against acquire, release or acq_rel.**
  - A store is `stlr` at both seq_cst and release.
  - A read-modify-write is `ldaddal`/`casal`/`swpal` at both seq_cst and
    acq_rel.
  - Loads at seq_cst (`ldar`) and acquire (`ldapr`) ran at the same speed in
    every test: alone, after a store, contended, and in a compare-and-swap
    loop.
  - On x86-64 the only difference is the seq_cst store, `xchg` where the
    others get `mov`. That was read from the compiled code, not timed.
- **Against relaxed, ordering of any kind costs in four places:**
  1. **A tight loop of loads:** 2.6× slower one-threaded, and 2.5× slower
     contended.
  2. **Stores to a contended word:** 3.4× slower.
  3. **Reading many slots while writers add to them:** 15× slower.
  4. **The first load of a compare-and-swap loop:** 2.4× slower
     one-threaded.

  Contended adds, counters and false sharing are bound by the cache line.
  There, seq_cst and relaxed are within noise of each other.

So the question is not seq_cst against acquire and release, which cost the
same. It is ordered against relaxed. Places 3 and 4 move inside built-in
forms below. Places 1 and 2 are what remains.

## The forms

Each form is one runtime piece behind one method or type. Rig code stays
seq_cst, while the runtime uses the cheapest correct instructions inside the
form. Speeds are from measurements.md, measured as Zig and Rust on the M5.

1. **A cache line of its own for every Cell that crosses cores.**
   - **The finding.** A `*Cell[Int]` is a 24-byte allocation (two counts and
     the value). Cells made one after another sit side by side, so several
     share a cache line.
   - **Measured.**
     - Rig, four tasks each adding to its own Cell: 4–10× slower than the
       same Cells 168 bytes apart.
     - Zig and Rust, adjacent words against 128-byte-aligned ones: 8× slower
       at 2 threads, 29× at 4.
   - **The fix.** A synchronized Cell's allocation is aligned and padded to
     128 bytes (crossbeam's `CachePadded` width on arm64 and x86-64). That
     is 104 more bytes per Cell that crosses cores, and only in programs
     that make tasks. Other `*T` keep their size.
   - **Status.** Queued as cell-pad (row 9), not yet built. It is runtime
     only, with no change to the language.
2. **`(!c).update(f)`:** change a Cell's value by a function, at once.
   - **What it replaces.** A `get` and `compare_swap` loop, and Rust's
     `fetch_update`.
   - **Why the retries are safe.** `f` is a `fun`, which has no side
     effects, so retrying it is invisible to the program.
   - **How it reads.** The first guess is a relaxed load, and the
     compare-and-swap checks it, so the operation is still one seq_cst
     read-modify-write.
   - **Measured.**
     - One thread: 507M updates a second, against 212M for Rig's loop today
       and 213M for Rust's `fetch_update(AcqRel, Acquire)`: 2.4× faster.
     - Contended: the same as both.
   - **Cost to build.** A Cell method, with sema's check that `f` is a `fun`.
3. **A per-core counter:** a counter many tasks add to.
   - **What it replaces.** A shared Cell's `add`, and Rust's
     `fetch_add(Relaxed)`.
   - **How it works.** It holds one padded slot per worker. An add touches
     only its own worker's slot, and a read sums the slots with relaxed
     loads. A sum of slots is never an instant's snapshot, which the method's
     name and docs say.
   - **Measured, 8 threads.**
     - Adds: 4,392M a second, against 50M for one word at either ordering,
       so 88× faster.
     - A read: 13 ns. Summing the same slots with ordered loads takes 202 ns.
   - **Cost to build.** A runtime type that knows the worker count, and a
     new std or built-in type, whose name is the owner's to choose.
4. **`c.wait_until(f)`:** wait until a Cell's value passes `f`.
   - **What it replaces.** Spinning on `get`, and Rust's spin loops,
     `park`/`unpark`, or a Condvar.
   - **How it works.** It spins briefly, then parks the task (not the
     thread) until a change to the Cell wakes it.
   - **Measured, with threads.**
     - Spinning: wakes in 83 ns, at 100% of a core.
     - A futex: wakes in 2.5–7 µs, at 0.5–1% of a core.
   - **Cost to build.** A wait list per Cell that has waiters, kept by the
     scheduler (src/sched.zig). Parking a task, not a thread, still has to
     be measured.
5. **A snapshot Cell:** many readers of a value a rare writer replaces
   (configuration, a routing table).
   - **What it replaces.** Rust's `RwLock<Arc<T>>`, `Mutex<Arc<T>>`, or the
     arc-swap crate.
   - **How it works.** A read marks the worker's own slot, loads the
     pointer, reads, and unmarks. A swap waits for the slots that were
     marked before it frees the old value. The scheme needs exactly
     seq_cst's store-then-load order.
   - **Measured, 8 readers.**
     - The seq_cst ceiling: 13,070M reads a second, equal to an unsound
       release/acquire version.
     - The fence form Rust code would use: 2.0× slower.
     - Rust's std forms: `Mutex<Arc>` 61M, `RwLock<Arc>` 2.8M.
     - arc-swap was not measured, because downloading crates was not
       approved.
   - **Cost to build.** Per-worker slots in the runtime, and a type over
     `*Frozen[T]`. This is the largest of the five, and the one most in need
     of a soundness review.

## What stays out, and what it leaves

- **No orderings in the language.** The forms cover what the measurements
  found worth having:
  - sharing a counter (form 3);
  - changing by a function (form 2);
  - waiting (form 4);
  - publishing a value (form 5);
  - keeping cores off each other's lines (form 1).
- **What Rust keeps over Rig.** Relaxed loads in a tight loop (2.6×) and
  relaxed stores to a contended word (3.4×). A flag polled in a hot loop is
  that case, and so is a statistic read where staleness is fine. Form 4
  takes the polling; form 3 takes most statistics.
- **Arbitrary lock-free algorithms** written by the program (queues, epoch
  schemes) stay out of safe Rig. They belong in the runtime, which Rig
  ships, or in `raw` code.

## Not measured yet

- **x86-64 timing,** on pup, after the queue's timing lane frees.
- **arc-swap,** whose crate needs the owner's approval to download.
- **Parking a task,** as against a thread, which the scheduler decides.

## Order of building, if approved

1. **Form 1, cell-pad:** queued as row 9, after #785.
2. **Form 2, `update(f)`:** a method, with the largest one-thread gain for
   the least code.
3. **Form 3, the per-core counter:** a new type, once its name is chosen.
4. **Form 4, `wait_until`:** with the scheduler's owner.
5. **Form 5, the snapshot Cell:** a design round with an adversarial review
   first.

Each form is measured on pup and the Mac, as a Zig ceiling and as Rig's
emitted code, before it lands.
