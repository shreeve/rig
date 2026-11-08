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

## To measure before building
- How often the monitor's signals end in a declined stop, on `bench/tasks` and Trig. That rate sets what the two switches cost.
- The switch-first room on each target, checked by a test that preempts a task whose stack has exactly `preempt_room` above its guard. On x86-64 that means AVX-512, on burst.
