# Cold paths off task stacks: the design (2026-11-08)

The panel's step 3, item (b) of the census ([census.md](census.md)): the code that keeps a task's stack bound unknown, or large, run on the worker's stack instead. A design for review; nothing is built.

## The primitive: `sched.onWorkerStack(f, args)`

This is Go's `systemstack`. It calls `f(args)` with the stack pointer below the point where the worker switched to the running fiber (`w.sp`), which stays unused while the fiber runs. `walkFrom` already does this (#1021).

**Its rules, each a check or a proof obligation:**
1. **No preemption while it runs.** It holds off stops (`holdOff`). A signal stop on the worker's stack would save a fiber context inside the worker's own frames.
2. **No park, yield or task switch in `f`.** A switch would save the fiber's sp on the worker's stack, and the worker's loop would then reuse that region. `f` must be runtime code that waits on nothing: no lock that parks, no I/O through the blocking pool.
   - Safe builds count it in a per-worker flag that every switch checks, and panic with the function's name.
3. **A panic in `f`** goes back to the fiber's stack first, then panics there.
   - The handler sees the worker's flag, restores the fiber's sp saved by the switch, and calls the panic's continuation (`tasks.panicked`) on the fiber's stack. Everything below `w.sp` is scratch, so nothing is lost.
   - Without this, `abandon` would switch away from inside the worker's own stack.
4. **Nested calls** run in place: the flag says the code is already on the worker's stack.
5. **Off a worker** (main before the scheduler starts, a pool thread, a test) it calls `f` directly.

**Its cost:** a flag write, two stack-pointer moves, and `holdOff`/`holdOn`. A few nanoseconds; it goes on cold paths only.

## What moves, and what does not

| path | moves? | why |
|---|---|---|
| the poller's service in a yield check (`tick` → `Poller.poll`, a 2,208 B frame, and its `flushBeforeWait`) | yes, though better by stopping first (switch-first, #1020's way) | waits on nothing (a poll of 0) |
| `flushBeforeWait`, `flushQuietly`, `print`'s final flush of stdout | yes: the drain, under the output lock it already takes or tries | `write(2)` on this thread, which never parks |
| the panic report (`panicWith`, `reportPanic`, `rendered_stack` of 4 KiB) | yes: the report only; `tasks.panicked` stays on the fiber's stack | formatting the message runs the user's `print` methods: see below |
| `print`'s formatting of the user's values | **no** | it runs the user's `print` methods, which may wait on a task, park, or panic. Rule 2 forbids that |
| the clock through the vDSO (`clock_gettime`) | **no** for now: an axiom, checked per machine | it is hot (timers, `alloc.readNow`), and the switch would cost a fifth of a read. Linux's vDSO uses a few hundred bytes. The census can disassemble the running kernel's vDSO image and prove the axiom on each host |
| libSystem calls (macOS) | later, per call, after the census lists them per task | most are syscall wrappers with small frames. A blanket rule would put a switch on every `write` |

## What this leaves for the census

1. **Writer recursion through the vtable stays unknown** wherever formatting runs on the task's stack. Bounding it needs a fact the code holds: the stdout writer's vtable is Rig's own, fixed at start. Two ways to give the census that fact:
   - Rig's stdout writer gets a vtable in a section the census reads as a fact (`rig_vtables`); or
   - `print` of a type whose formatting needs no user code formats into a fixed buffer, and its flush is the cold path.

   **Default:** the first, as its own step after this one.
2. **A user's `print` method on a task** keeps the task's bound to whatever that method's code bounds to, which is correct.

## Order of PRs
1. `onWorkerStack`, with rules 1–5 and tests:
   - a panic inside it;
   - a park inside it, caught in a safe build;
   - nesting;
   - off a worker.
2. The flushes and the panic report through it. The poller's service waits for #1020, and goes through a stop, as preemption does.
3. The census reruns. The vDSO axiom gets its check (`stack-census.py --vdso`).

Each is measured: bench/tasks, bench/actors and bench/http rows, and the json/hash/text guards, since `print` is on every row's path.
