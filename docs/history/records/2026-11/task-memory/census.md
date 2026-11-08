# The stack census, first pass (2026-11-08)

Step 4 of the small-stacks order (the panel's revision of
[small-stacks.md](small-stacks.md)): a bound for each task's stack, read
from the final executable, failing closed (safety's R1). A measurement
only: nothing in the runtime uses it yet. The tool is
`tools/stack-census.py EXE`.

## What it does

- **Frames.** It follows the stack pointer through each function's whole
  body, along its branches, by a positive list of the instructions that
  may move it: on arm64, `sub`/`add sp`, pre- and post-indexed stores and
  loads, and `mov sp`/`sub sp` from a register holding sp; on x86-64,
  `push`, `pop`, `sub`/`add`/`lea`/`and rsp`, `leave`, and the probe's
  `sub rsp, rax`.
- **Fail-closed checks.**
  - Any other write to sp makes the function unknown.
  - So does a point reached at two depths. Compiled code keeps sp the same at each point, so this also catches the tool's own misreadings.
- **Bounds.**
  - A function's bound is the most of its own frame plus the red zone (128 bytes), or the stack at a call plus the callee's bound.
  - A cycle of calls makes it unknown.
  - A task's bound adds `fiberStartNaked` and `fiberMain` (24 + 16 bytes on x86-64, 0 + 32 on arm64).
- **Calls through registers** that the code itself set are followed:
  - a function's address made by `adrp`/`add`, `lea` or `mov eax, imm`;
  - macOS's thread-local getters, counted as an axiom of 256 bytes;
  - a global's function pointer, and a vtable that a global holds, by the global's value in the file;
  - x86-64 jump tables.
- **The two switch functions** (`switchNaked`, `switchStackNaked`) count only what they push before they leave the stack.
- **The stack probe** (`zig_probe_stack`) counts 16 bytes, since its caller reserves the frame itself.
- **Other calls through a vtable's slot** take every function at that slot or after in any run of function pointers in the data. That is sound over the data's vtables, and coarse. A call through a pointer with no slot takes every function whose address the program takes.
- **Calls out of the program** (libSystem's stubs) and into the panic path are listed, not counted. Safety's R3 and R5 move them onto the worker's stack.

## Results

### bench/tasks, release (`--release=fast`)

| task | Mac (arm64) | pup (x86-64) |
|---|---|---|
| spawn's tiny task | 656 B | 584 B |
| `nap` (sleeps) | 688 B | unknown: `std.time.sleep` through a pointer |
| `spin`, `even_chunk`, `skew_chunk` | 3,776 B | unknown |
| `yielder`, `alloc_chunk` | 3,872 B | unknown |
| `tree` | unknown: recursion | unknown |
| a closure's task (`FnRef`) | unknown: through a pointer | unknown |

7 of the 9 task types are bounded on the Mac, and 1 on pup.

The Mac's 3.7–3.9 KiB rows, and every unknown row on pup, come from one path: **a yield check services the poller on the task's own stack.**
- The path: `tick` → `Poller.poll` → `flushBeforeWait` → stdout's `Io.Writer.flush`, through its vtable.
- `Poller.poll`'s frame alone is 2,208 bytes on the Mac, more than a 2 KiB class.
- The writer is in `.bss`, set at run time, so its vtable is resolved only by slot. On x86-64, Writer's default methods then form a cycle under the slot rule (`defaultRebase`).

### Trig, release (pup, x86-64)

All 8 task types are unknown. Behind the pointers:
- **Frames:** up to 125 KiB in one frame (`CheckerPool.check_groups`), 72 KiB (`emit_declarations`) and 67 KiB (`new_program`).
- **Pointer calls:** the clock read through the vDSO pointer (`alloc.keptReading`), stdout's writer (`Io.Writer.writeAll`), and a channel's callback (`Chan.recv`).

Trig's checker tasks belong to the large class whatever the pointers resolve to.

### Debug builds

Every task type is unknown. The `std.Io` vtable calls in the allocator and the clock resolve by slot to `Io.Threaded`'s functions, among them `netLookup`'s recursion. Safety's Q2 expected debug builds to take larger classes; with this tool they take the large one.

## What the census says to do next

1. **Service the poller on the worker's stack.** A yield check that finds the poller due should stop first, as switch-first preemption does (#1020), and poll from the worker's stack.
   - **Mac:** with `--cold` naming `Poller.poll` (a what-if), bench/tasks' 3,776–3,872 B rows fall to 2,352–2,448 B.
   - **pup:** the same rows stay unknown, through `tick`'s other call through a pointer, `alloc.ask`'s, and `std.time.sleep`'s.
2. **Move cold paths to the worker's stack** (the panel's step 3): `print`'s formatting, `flushBeforeWait`, the clock's vDSO call, and the panic path.
3. **Vtables resolved by type (built, `type_vtables`).**
   - **The interface:** each call through a slot is named by the innermost inlined frame of its code that belongs to a std namespace with a `VTable` (`Io.Writer.flush` → `Io.Writer`), and its slot by that `VTable`'s fields, from Zig's std source.
   - **The vtables:** each vtable in the data is typed by its length, and by most of its functions being named for the fields (`heap.SmpAllocator.alloc` at `alloc`).
   - **Typed on bench/tasks:** in debug, 106 slots of `Io`, 17 of `Io.Writer`, 28 of `mem.Allocator` and 8 of `Io.Reader`. Trig, release on pup: 106, 19, 24 and 12.
   - **What stays unknown:** two recursions that type alone cannot break.
     - Writers that wrap writers recurse through `Io.Writer`'s own vtable (`defaultFlush` → `drain` → `Io.File.Writer.drain`).
     - Allocators that wrap allocators recurse through `mem.Allocator`'s (`heap.BufferFirstAllocator.free`).

   So item 2 is required, not optional: no task that writes output through a `Writer` has a bound while that code runs on its stack.
4. **`sched.sortStacks` (#1021) recurses** (merge sort, depth log2 n). It runs on the worker's stack, but the coarse pointer rule reaches it. An iterative sort removes the cycle.

The go/no-go for classes waits on items 1 and 2: without them, no Linux task in these programs has a bound.

## Second pass: the flushes on the worker's stack, and the vDSO measured (2026-11-08)

The changes measured:
- **The flushes:** `sched.onWorkerStack` (branch `worker-stack`) runs stdout's flushes and a panic's report on the worker's stack. The census counts only `onWorkerStack`'s own frame, since each call it makes runs on a worker's stack or outside any task.
- **The vDSO, measured per host (Rig's condition), failing closed:**
  - On Linux the census reads the host's vDSO image from `/proc/self/mem`.
  - It splits the image's unnamed functions at every call and outside jump.
  - It bounds `clock_gettime` by the same rules as the program.
  - An image it cannot read, or any frame in it it cannot account for, leaves every bound through the clock unknown.

| host | kernel | vDSO `clock_gettime` |
|---|---|---|
| pup (x86-64) | 7.0.0-38-generic | 200 B |
| the Mac (arm64) | none: the clock is a libSystem call, listed as foreign | |

bench/tasks, release, on pup:

| task | first pass | second pass |
|---|---|---|
| spawn's tiny task | 584 B | 584 B |
| `nap` | unknown | 616 B |
| `spin`, `even_chunk`, `skew_chunk` | unknown | 2,296 B |
| `yielder` | unknown | 2,344 B |
| `alloc_chunk` | unknown | unknown: a buffer-full drain inside `print`'s formatting (`Io.Writer.writeSplat`) |
| `tree` | unknown | unknown: recursion, and `clone` through a pointer |
| a closure's task | unknown | unknown: through a pointer |

So 6 of the 9 task types are bounded on pup, all of them by direct calls alone. The 2.3 KiB rows are the poller's service: `Poller.poll` is a 2,208 B frame, which item 1 moves.

## Running it

```sh
tools/stack-census.py EXE              # the table of task types, and the largest frames
tools/stack-census.py EXE --json F     # also every function's frame, to F
tools/stack-census.py EXE --cold RE    # what-if: functions matching RE run off the task's stack
```

It needs `llvm-objdump` (`/usr/lib/llvm-22/bin` on pup), and `atos` (macOS) or `llvm-symbolizer` (Linux) to name the tasks. bench/tasks takes under a second, and Trig about a minute.
