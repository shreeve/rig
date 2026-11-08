# Preemption's room on a task's stack (2026-11-07)

A design note, the first step of the ROADMAP's "Tasks as small and as cheap as the best runtimes'". Nothing here is built.

## Today
The handler (`sched.onPreempt`) runs on the worker's alternate signal stack. It stops a fiber only when the fiber's stack has `preempt_room`, 32 KiB, above its guard; otherwise it declines, and the monitor signals again next period.

When it stops the fiber, it points the fiber's program counter at the trampoline. The trampoline runs on the fiber's own stack, in four steps:
1. It saves the registers a call may change:
   - **arm64:** 720 bytes, the integer and NEON registers.
   - **x86-64:** 152 bytes, then an `xsave` area sized for the CPU at start. That is about 1 KiB with AVX2, and 2,752 bytes with AVX-512.
2. It calls `preempted`, still on the fiber's stack.
3. `preempted` does the scheduler's work there: `serviceBusy` fires due timers, waking their fibers, and looks at the poller (a system call); then `takeWaiting`, `stealWaiting`, and `leftToIdle`.
4. Only then does `stopIn` switch to the worker's stack.

Step 3's depth has no small proven bound, which is why the room is 32 KiB.

**Why it matters:**
- **Now:** every task reserves 64 MiB of address space and commits pages only as it touches them, so the 32 KiB check fails only in deep recursion.
- **With small stacks:** the ROADMAP's slab stacks, sized by a bound proven on the linked executable, would have to add 32 KiB to every task's proven need. That defeats the memory goal of under 2.9 KiB a sleeping task, and a task whose stack had less room could never be stopped.

## The change proposed: switch first, then decide
The trampoline saves the registers and switches to the worker's stack at once. Everything else runs there.

- **On the fiber's stack:** the register save (above) and `switchTo`'s frame, which saves the callee-saved registers. Both sizes are fixed and known for the target.
- **On the worker's stack:** the trampoline sets `w.after` to a new `afterPreempt` and switches.
  - The worker runs `afterPreempt(f)`: `preempted`'s current body, unchanged.
  - If it decides to stop the fiber, `f` goes to the global queue, as `behind` puts it now.
  - If not (the work it was signaled for has gone), `f` runs next. Its next switch returns through the trampoline, which restores the registers.
- **What it costs:**
  - A declined stop now costs two switches, tens of nanoseconds each (`bench/tasks`' chain, a full round trip, is 44 ns on the Mac), where it cost none. The monitor signals only when work waits, so a decline is rare: a stop it was signaled for is usually taken.
  - A taken stop costs the same as now: one switch.

`preempt_room` then becomes a constant computed per target: the save area, the switch frame, the 128-byte red zone, and a margin of 256 bytes.
- **arm64:** about 1.2 KiB.
- **x86-64 with AVX-512:** about 3.4 KiB.
- **x86-64 with AVX2:** about 1.6 KiB.

A slab stack's size is then the program's proven bound plus that room. So preemption adds about 1 KiB to an arm64 task's stack where it added 32 KiB, which leaves the 2.9 KiB goal reachable for tasks whose own frames are small.

## Alternatives weighed
1. **Keep the interrupted state in the task's record:** the handler copies the registers and vector state out of the signal context into the record, and returns to a resume path on the worker's stack. It needs no room on the fiber's stack at all, but:
   - every task's record grows by up to 3 KiB, or the state needs a pool sized for the most fibers ever stopped at once;
   - resuming means restoring every register outside a signal return, as `sigreturn` does: more code, on both targets, for every resume.

   It is worth it only if the switch-first room proves too large for the slab sizes the bound gives. That is not expected, since the room is smaller than a page.
2. **Save only the vector state in use** (`xsavec`, or XINUSE from `xgetbv`). This shortens the save, but not the room, which must hold the largest save. It stays as a speed-up for the switch-first path if its saves show in profiles.
3. **No preemption on small stacks:** those tasks would keep their yield checks. This splits the one way to stop a long computation per target that the owner set (ROADMAP, "Concurrency"), so it is rejected.

## Measured (2026-11-07)
**Memory per sleeping task** (`bench/tasks/bench-scale`, the kernel's own count, reps 3; Swift is the new `bench/tasks/swift`, memory only):

| runtime | Mac (`footprint`) | of it, page tables | pup x86-64 (VmRSS + VmPTE) | of it, page tables |
|---|---|---|---|---|
| Rig | 32.7 KiB | 16.1 KiB | 8.9 KiB | 4.3 KiB |
| Tokio | 265 B | 0 | 386 B | 0 |
| Go | 2.9 KiB | 3 B | 2.8 KiB | 7 B |
| Swift | 2.1 KiB | 3 B | | |

On the Mac a sleeping task holds one 16 KiB stack page and one 16 KiB page-table page, since each stack is a mapping of its own.

**A parked task's live stack**, measured by a probe at `stopIn` (the distance from the stack's top to the frame there):
- **bench/tasks:** a sleeping task 544 B in a fast release build, 2,160 B in debug. Over the whole bench's 1.5 million parks, mean 612 B and max 1,424 B.
- **Trig 3ca350b**, release, preempted, at 4 checkers: ts-pattern's checker tasks park at a mean of 24 to 30 KiB and a max of 39 KiB, zod3's at about 19 KiB. At one checker nothing parks.

So stacks a few to a page fit tasks like bench/tasks' in under 1 KiB plus this room. Trig's checker tasks need growth by segments, or a larger class.

**Scaling** (bench-scale, main with yield checks, reps 3): Mac with any cores, pup on P-cores (6; 6,8; 0,6,8,10; then 8 with two siblings).
- **One worker, the CPU loops (even, skew, tree):**
  - Mac: Rig 203 to 215 ms; Go, Tokio and Rayon 157 to 163 ms.
  - pup: Rig 182 to 205 ms; Tokio and Rayon 176 to 180 ms; Go 157 to 160 ms.
  - The yield checks are much of the gap, as psum showed (records/2026-11/fork-join).
- **Speedup:** Mac at 10 workers, Rig 7.5 to 8.3 times. pup at 8 workers, 7.0 to 7.5 times, as Go's 7.5 and Tokio's 7.3 to 7.4.
- **alloc:** Rig is fastest at every count.
  - Mac at 1 worker: 266 ms, against 529 to 539. At 10 workers: 38 ms, against 136 to 303.
  - pup at 1 worker: 288 ms, against 509 to 729. At 8 workers: 49 ms, against 77 to 354.
- **TLB shootdowns:** run as tasks, alloc takes 855 to 3,270 of them on pup, where par.map takes 14 to 45. Those come from releasing task stacks' pages, a cost that stacks sharing one mapping and kept between tasks would also cut.

**Declined stops:** the monitor's "signaled" counts sends, and the kernel merges a SIGURG sent while one is pending, so the counts below are deliveries, from the probe.
- **bench/tasks:** 2 to 6% of the trampolines entered end without a stop.
- **Trig at 4 checkers:** 6 to 9 entries a run, 4 to 6 of them stopping; at one checker none.

Switch-first's two extra switches are paid that rarely.

## To measure before building
- The switch-first room on each target, checked by a test that preempts a task whose stack has exactly `preempt_room` above its guard. On x86-64 that means AVX-512, on burst.
