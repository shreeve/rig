# Small stacks: a design for the panel (2026-11-07)

A draft for the small-stacks design round (ROADMAP, "Tasks as small and as cheap as the best runtimes'"). It builds on the measurements in [preempt-room.md](preempt-room.md). Nothing here is built.

## The problem, in numbers
A sleeping task takes 32.7 KiB on the Mac, half of it page tables, and 8.9 KiB on pup. Go's takes 2.9 KiB, Swift's 2.1 KiB and Tokio's 265 B. Its live stack is 544 B in bench/tasks, and 19 to 39 KiB in Trig's checkers.

Today every task's stack is its own 64 MiB reservation over a guard of at least 16 MiB (scheduler.md, "Stacks"). A sleeping task therefore holds a whole page, 16 KiB on the Mac, and a page-table page of its own, another 16 KiB. Releasing a task's stack pages costs TLB shootdowns: 855 to 3,270 a run of bench-scale's alloc as tasks, against 14 to 45 for `par.map`.

**The target:** under Go's 2.9 KiB per sleeping task on both machines, with no bench/tasks, bench/actors, bench/net, bench/http or Trig row slower.

## The constraints Rig puts on any design
1. **Stacks never move**, because loans point into them. So no copying: Go's answer to the cost of growing a stack is closed to Rig.
2. **Zig emits no stack probes on arm64**, so a frame larger than a guard can skip past it. Today's 16 MiB guards exist for that reason.
3. **Accept means correct.** A stack too small for a task is memory corruption, so any bound has to be proven or checked, never assumed.
4. **Preemption needs room** on the stack. That room is a constant only once switch-first lands (preempt-room.md), so switch-first comes first.

## The design
### 1. One mapping for many stacks
Stacks come from slabs in one large reserved region per size class, carved by each worker and kept between tasks, as today's free stacks are.
- **Page tables:** neighbouring stacks share their page-table pages, so a sleeping task holds a share of one, not a page-table page of its own.
- **Shootdowns:** a stack is reused, not unmapped, so ending a task flushes nobody's TLB.
- **Memory:** a free stack's dead pages are released in bulk, with `madvise(MADV_FREE)` per slab, when a worker's cache has been idle a while. That is the ROADMAP's cheap fix, landing on its own first.

### 2. Size classes from a bound proven on the linked executable
For each function a task may start with (`f()&`), the compiler records the stack it needs. That is a fact recorded once, as storage's are: emit only reads it.
- **What the bound is:** the largest sum of frames on any call path from `f`, with each frame read from the linked executable (`src/frames.zig`) and each runtime and std entry at its own measured bound.
- **When there is no bound:** a path through recursion, a call through a function value, an `extern` C call, or a frame over a limit makes the bound unknown.
- **The classes**, each including preemption's room and the switch frame:
  - **2 KiB:** the default; fits bench-style tasks, whose stack is 0.5 to 1.4 KiB.
  - **8 KiB**, and **32 KiB**.
  - **large:** today's reserved stack with its guard, for an unknown bound or one over 32 KiB.

  A spawn site takes the smallest class its bound fits.
- **The arithmetic:** on the Mac a 2 KiB class puts eight stacks on a 16 KiB page. A sleeping task then holds 2 KiB plus its record, about 2.3 KiB, under Go's 2.9. On pup's 4 KiB pages, two to a page.
- **x86-64 with AVX-512:** the room switch-first leaves is 3.4 KiB (preempt-room.md), which does not fit a 2 KiB class. There the trampoline would save only the general registers on the stack, about 200 bytes, and copy the vector state to a slot the worker draws from a pool once it is on its own stack. The slot is freed when the fiber resumes. That makes the room under 0.5 KiB on every target.

### 3. Growth for deep tasks: segments that never move
A task whose bound is unknown only because of recursion, Trig's checkers among them, could start small and grow, so it need not take the large class.
- **Where the checks go:** the compiler already picks one function on every cycle of calls for the yield checks (`inlining.Pass.cutCycles`). The same functions would check the stack.
  - At entry, such a function compares the stack pointer with its segment's limit, less the bound of its own acyclic part.
  - When short, it runs its body on a new segment: switch the stack pointer, call, switch back. The frames behind stay where they are.
- **Hot splits:** a call at a segment's edge that crosses on every turn of a loop made Go and Rust drop segmented stacks. Here a segment, once made, stays linked to its task until the task parks or ends. A crossing then costs a compare and two pointer moves, never an allocation, and a task holds at most one segment past the one it is using.
- **Which way to start:** this step is the most work of the five. The panel should decide between building it and sending recursive tasks to the large class. Trig's checkers, at 19 to 39 KiB live, cost one page and its page tables in the large class, where 8 or 32 KiB classes with segments would cost half or less.

### 4. Guards and overflow
- **Classed stacks have no guard pages:** a guard is a page apiece, which is what the classes exist to save. Safety comes from the bound being proven.
- **Checking that the bound holds:**
  - In safe and debug builds a canary word sits at each stack's low end; it is checked at every park and at the task's end, and a broken canary panics with the class and the function.
  - Under `RIG_SANITIZE=1`, every task takes the large class, so its guard catches an overflow where it happens.
  - A test (`test/cli/stack_bound.sh`) fills each classed stack with a pattern, runs the suite's programs, and checks that the high-water mark is under the class. It is the check that the bound is sound, as `frame_reach.sh` is for frames.
- **Segments:** each segment's limit check is the overflow check, and the last segment's end is the next segment's link, never memory another task owns.
- **Large class:** unchanged.

### 5. What changes
- **`src/sched.zig`:**
  - switch-first preemption (preempt-room.md);
  - classed stacks in `takeStack` and `releaseStack`;
  - the canary check at park;
  - segment switching (step 3).
- **`src/alloc.zig`:** none. Stacks keep their own region, apart from the heap, so a slab never mixes with heap pages.
- **The compiler:**
  - the bound as a recorded fact (`src/facts.zig`), read by emit at each `&`;
  - the stack checks at cycle entries, beside the yield checks.

## The order of PRs
1. Switch-first preemption, with the vector state moved off the stack where AVX-512 is on.
2. The cheap fixes: free stacks' dead pages released, and the deadlock walk's 15 KiB frame off task stacks.
3. One region per class, with every task still in the large class. Measures the page-table and shootdown gain alone.
4. Bounds and classes, with the canary and `stack_bound.sh`. This is where memory per task falls under the target.
5. Segments for recursive tasks, if the panel takes step 3.

Each PR passes the gates, with bench/tasks' memory row and no slower row.

## Tests
- **Seeded:** a task at exactly its class's bound; one that crosses a segment edge in a loop (the hot-split case); preemption at the bottom of a classed stack.
- **Stress:** 100,000 sleeping tasks of mixed classes, checked against the memory target. Tasks that end and start while others sleep, checked for stack reuse.
- **Sanitizer:** the suite under `RIG_SANITIZE=1` runs every task large and catches any overflow the bound missed.
- **The bound check** (`stack_bound.sh`) over the examples, the benches, and Trig's light gate.

## Alternatives rejected
1. **Copying stacks, as Go does.** Loans point into stacks, so moving one would need every pointer to it found and fixed, which needs a map of every frame's pointers. Rig keeps none.
2. **Stackless tasks, as Tokio's are.** They would bring back a second kind of function (`async`), which Rig's model rules out (concurrency.md, "One kind of function").
3. **A guard page under every small stack.** A page each, where the classes exist to save pages. With proven bounds the guard catches nothing the bound has not ruled out.
4. **Smaller pages.** arm64 macOS has 16 KiB pages and no smaller.
5. **A small stack for every task, overflow caught by a guard.** Zig's missing probes on arm64 make a guard unsafe for frames larger than it, and a fault is not a recovery.

## For the panel to decide
1. Segments (step 3) now, or recursive tasks in the large class first.
2. The class sizes: 2, 8 and 32 KiB, or others the measured depths suggest.
3. The vector state off the stack on AVX-512 machines, or a 4 KiB default class there.
4. Whether the canary costs anything measurable at park.
