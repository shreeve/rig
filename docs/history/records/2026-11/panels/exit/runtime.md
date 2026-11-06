# Exit panel, runtime lens: what a Rig program does at its end, and what it could honestly skip

Read against Rig `origin/main` cf6a362a6 and Trig `origin/main` 6184626, plus Trig PR #277 (`checker-drop`). Trig's HANDOFF on that branch says the PR "landed by the owner's decision", but on GitHub it is still OPEN and unmerged, waiting for a light-gate rerun. I ran no timings. Every number below is from the records:

- exit-handoff.md;
- task-memory.md;
- table-vmas.md, "Today against Trig's drop";
- investigation.md §4.

## 1. What a Rig program does at its end today

**A `main` that returns.** The emitted wrapper is `src/emit.zig:1926-1943`, with the prologue at `:2112-2116`. `main`'s body runs on the runtime's stack (`rig.onOwnStack`, `src/runtime.zig:7256`). In a program that makes tasks, that stack is the scheduler's first fiber (`sched.runMain`, `src/sched.zig:2581`). In order:

1. **`main`'s own drops,** in reverse order (Zig `defer`s), then `defer rig.finish()`, which was armed first.
2. **`rig.finish`** (`runtime.zig:7855-7877`):
   - `sched.settleLeftCalls`, then the PGO profile and the Map trace, each only in builds that have them;
   - frees the argument list, then locks and flushes `print`'s buffer;
   - the heap profile, if built in;
   - `threaded.deinit()`, the `std.Io.Threaded` backend;
   - `reportLeaks`, which does something only in debug builds (`leak_checked = optimize == .debug`, `:5953`). The sanitizer is debug-only too (`:5955`).
3. **The fiber ends** (`Main.end`) and sets `stopping`. Worker 0's `loop` returns. Then `runMain` (`sched.zig:2615-2640`):
   - waits for `kicking`, then `pool.stop()`;
   - **joins every worker thread** (`:2618`);
   - `freeStacks` and `freeBlocks` for each worker;
   - clears the timers and closes the pollers;
   - frees the worker array.
4. **Zig's start code exits** with the status. Rig's release allocator (`src/alloc.zig`) has no shutdown at all:
   - "Segments are never returned to the system" (`:24`);
   - `threadExit` (`:1238`) runs only when a thread really ends.

**`os.exit(code)`** (`std/os.rig:71-76` → `rig.exitNow`, `runtime.zig:7839`):

- `lockOutput()` and `flush()`;
- then `endProcess` (`:7827`): the PGO profile in training builds only, then `_exit` where libc is linked (macOS) or `exit_group` (Linux, no libc).

So `os.exit` runs no drop, `defer`, free, leak check, worker join or atexit handler. The other threads die with the process. Its doc says exactly that.

**Trig's release build.** Trig's `sys.finish` (`tools/trig/main.rig:142-147`) writes the output, then calls `os.exit(status.code()) if not target.debug`. `execute` calls it before any of its own frames drop the System, the Program or the checkers. So **after its output is flushed, Trig's release build runs no user-space work**:

- no drops, no frees, no thread joins, no allocator teardown;
- the `exitNow` flush itself is a few µs.

The memory note is right, and so is investigation.md §4 ("ends by `os.exit` after its output (nothing is dropped)"). **The whole 17-29 ms exit is the kernel tearing down resident memory**, at about 0.1 ms per MiB (table-vmas.md):

- mappings cost about 1 ms of it at most;
- page tables cost under 1 ms.

PR #277's own A/B shows what is left with the drop, by the medians on E-cores:

| project | exit before | exit with the drop |
|---|---|---|
| ts-pattern, 1 checker | 19.8 ms | 19.7 ms |
| ts-pattern, 4 checkers | 29.6 ms | 19.5 ms |
| ts-pattern, 8 checkers | 32.5 ms | 22.1 ms |
| zod3, 4 checkers | 10.8 ms | 8.0 ms |
| zod3, 8 checkers | 13.9 ms | 9.0 ms |

tsrs's whole exit is 7-12 ms.

## 2. Can user-space exit work be cut honestly?

| Cut | Today | Sound? |
|---|---|---|
| Skip every drop and free once output is flushed | Done, by `os.exit`, written in the source (Trig does it) | Yes, because it is visible. Done silently, it is **not** sound in general: see below |
| Don't join worker threads | Done by `os.exit` (`exit_group` kills them); a returning `main` still joins (`sched.zig:2618`) | Yes: after `finish` nothing observable is left, except `RIG_SCHED_STATS`'s report, which is printed before the join |
| `_exit` at once | Done (`endProcess`) | Yes |

**Skipping drops silently at `main`'s end is observable in safe Rig:**

- a `drop` body runs code (SPEC §8: `print("closing", @fd)`);
- dropping a `Task` waits for it, or cancels it (SPEC 13168), and the task can still print or write;
- `File`'s drop closes its fd (`std/file.rig:138`);
- a drop body can read `os.memory()`.

The sound subset is values whose glue only frees memory. It needs a precise sibling of `sema.runsDropBody` (`sema.zig:13290`), which is conservative today: every hash table counts as running a body. The skip would also be off in programs that read `os.memory` (`alloc.zig`'s `counts`) and in debug builds.

That rule fits CORE in a paragraph, since it is as-if and not an ownership change. But it gains Trig **nothing**: Trig already exits through `os.exit`, and its checkers live in frames below `main`, not in `main`'s locals. So it is not a speed item. At most it would be ergonomics, for the owner, another day.

**Verdict on Q2:** there is no user-space exit work left in Trig to cut. A runtime idea that only skips something saves Trig 0 ms.

## 3. Releasing memory during the run

**What PR #277 leaves resident.** A checker dropped in its own task gives its Tables back (`table.zig:141` → `alloc.unreserveTable`, `MADV_DONTNEED`). Its heap keeps the rest:

- small blocks stay on free lists, with their pages resident;
- a busy heap's (`faultsAhead`) large blocks are kept resident within `keepBound` (`alloc.zig:404, 841-852`);
- segments stay mapped.

At about 0.1 ms per MiB, the leftover of the three dropped checkers at 4 checkers is roughly 30-50 MiB, about 3-6 ms. That is task-memory's inferred estimate, and nobody has measured it.

**A1. No new rule: an idle heap gives back its kept large blocks.** When a worker runs out of work and its heap holds many kept bytes, it decommits them (`decommit`, `alloc.zig:415`). The change is in alloc.zig and sched's idle path only. It is sound because the blocks are whole and free.

It cannot reach the small-block pages. Segments are carved bump-style (`Heap.newPage`, `:313`), and pages keep no live counts. Adding them would cost every free (task-memory.md).

- Ceiling: at most the large-block share of 3-6 ms at 4 checkers, so probably under the bar.

**A2. No new rule: reset a heap that holds nothing.** It would need per-heap live counts, which cost every alloc and free. It would also never fire in Trig: a dropped checker's worker heap still holds the diagnostics the task moved to `main`. **Drop it.**

**A3. NEEDS 73 as a rule: `task.arena(f)`.** Can the checker prove "never escapes"? **Yes, from the boundary's types, with no flow analysis.** That works because Rig's only ways out of a task are:

- its result;
- a write through a `!` view;
- a handle: shared, `*Frozen`, actor, `Chan`, `Cell` or `Task`;
- a task that outlives it;
- `raw`.

So `f` is legal when it meets the `task.isolate` closure rule (SPEC 13522: no write capture, and tasks end inside), and also:

- (a) everything `f` can reach through its inputs is plain data, or read views of types that reach no handle;
- (b) `f` takes no owned value moved in. Its drop would be skipped and its blocks live on another heap;
- (c) its result leaves only as `+f()`, cloned while the caller's heap is current.

The rule follows types, so it fits a CORE paragraph, but it is a **new rule (CORE §10, for the owner)**. Its costs:

- a heap switch on every fiber resume and pause (`sched.zig`);
- a clone of the result;
- a Trig restructure: each checker built inside its task from `?program`, not moved in.

What it would buy over #277: the drops' CPU (3-4 ms a checker, on idle cores, so not in the wall), plus the small-block leftover. So its wall ceiling is the same 3-6 ms at 4 checkers. That does not pay for a Core rule. **Drop it for now.**

## 4. What does attack the remaining exit: tearing memory down in parallel before `exit_group` (design B)

**The problem.** After #277, about 20 ms remains at 4-8 checkers. Most of it is the last checker and the program, which no mid-run release can touch.

**The teardown is serial today.** The last thread's `exit_mmap` frees every page on one core, before the parent's `wait` returns. Meanwhile the run's other cores are idle.

**The design.** The runtime frees those pages itself, in parallel, while the process is still alive:

- `exitNow` (and the end of a returning `main`, after `finish`) locks and flushes output as today;
- release builds on Linux only;
- only when the program has at least 2 workers and more than a threshold resident (say 32 MiB);
- **every other worker parked, and no blocking-pool call in flight.** This is required for soundness: a running task, or a pool `write`, must never see a zeroed page and write zeros to a file before the process dies. Otherwise it is a plain exit;
- a dying flag stops any fiber from resuming;
- the parked workers are woken with a teardown job. Each one `MADV_DONTNEED`s its slice of:
  - the segment region (`alloc.zig:862-913`, `region_next`);
  - the Tables' regions (`:959-1060`);
  - the heaps' kept large blocks;
  - every fiber stack except the caller's.
- `madvise` takes `mmap_lock` for reading, so the zaps run concurrently, where `munmap` would serialize;
- `main` waits, bounded, on a counter, then calls `exit_group`. The kernel is left only empty mappings, about 1 ms.

Live large blocks are mapped one by one and are not listed today. One list per heap, touched only on large allocs and frees, which are rare, would cover them. Or leave them out, and first measure their share.

**Is it honest?** Yes, by BRIEF's test. The work is not moved anywhere: the same process does it, on its own cores, before it ends. `time`, `getrusage`, `perf stat` and peak RSS all still count it. The caller waits for the real end, and no second process or reparenting is involved. It is exactly what the handoff was not: it shortens the teardown rather than hiding it.

**Code it touches:**

- `runtime.zig` `exitNow`/`endProcess` (`:7827-7844`), and the end of `runMain` (`sched.zig:2615`);
- sched's worker loop and park (`loop`, `:2727`; `sleepers`; `wakeWorker`, `:2928`);
- alloc.zig's range lists.

It is all behind one runtime function that can be cut out in one step, like `bolt.zig`, and no ownership or CORE change is needed.

**Gain.** Let `z` be the zappable share of what is resident (guessed at 0.7-0.9) and `s` the kernel's speedup over K cores (guessed at 1.5-3.5). Freeing pages takes the per-lruvec `lru_lock` and memcg uncharging, and the zappers send each other TLB shootdowns, so `s` is far from K. Gain = exit × z × (1 − 1/s) − about 0.3 ms:

| project | 4 checkers | 8 checkers |
|---|---|---|
| ts-pattern | 4.5-12.5 ms of 511, 0.9-2.5% | 4.4-16 ms of 440, 1.0-3.6% |
| zod3 | 2-5.5 ms of 127, 1.5-4.3% | 2.5-6.5 ms of 116, 2-5.6% |

At one checker, pinned to one core, the gain is zero, and the program must keep the plain exit.

The bar's instruction half is not met (it adds instructions). Its time half (more than 1.5%) is plausible, and peak memory is no higher.

**Risks:**

- The kernel scales badly on parallel frees (`lru_lock`, the zone lock), and that is the whole question.
- Shootdowns between the zappers: `tlb_gather` batches them, but they still cost.
- An `exitNow` from a task while others run must fall back to a plain exit (`os.exit`'s doc allows tasks to "end where they are"; they must not see zeroed memory).
- macOS is unknown. The design is Linux-first.

**The measurement that settles it (first step).** Extend `table-vmas-data/vmabench.zig`:

- map a 64 GiB reservation and write 150-230 MiB densely (Trig's shape, with 0 and with some free 2 MiB blocks);
- then K = 1, 2, 4, 8 threads `MADV_DONTNEED` equal slices, then `exit_group`;
- time it under `exitwatch`, from the start of the zaps to reaped, against a plain exit;
- 20 shuffled rounds on pup E-cores, in a slot.

If 4 threads do not cut the reaped time by at least 40%, drop B. If they do, build a runtime arm and A/B it on Trig's PGO build at 1, 4 and 8 checkers.

This needs pup, which is out of reach today. The OS panelist's kernel view decides whether it is worth the slot.

## Recommendation

1. **B, parallel teardown before `exit_group`: MEASURE FIRST,** with the microbench above. It is the only runtime design that reaches the ~20 ms left after #277, honestly.
2. **A1, an idle heap gives back its kept large blocks:** only if B fails. First measure the share: an env-gated print of `kept.bytes` per heap as its worker goes idle, on Trig's 4-checker run.
3. **A2:** DROP.
4. **A3, NEEDS 73's arena rule:** DROP for now. It costs a Core rule, for at most the same 3-6 ms ceiling as A1.
5. **Silent skipping of drops at `main`'s end:** DROP as a speed item, since Trig gains 0. `os.exit` is already the honest, visible form.
