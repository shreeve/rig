# Row 25g: blocking calls stop on a cancel, a deadline, or an interrupt

## The bug
With no tasks the scheduler is off and `rig.blockingStop` runs its call on
`main`'s thread. `std/file.zig`'s `openAt` (and its write, rename, unlink,
rmdir loops) retry EINTR blindly, so a FIFO with no writer blocks forever:
SIGTERM's handler (no SA_RESTART off the scheduler) makes `open` fail with
EINTR, the loop retries, and `main` never reaches the cancel. A deadline
(`time.within`) has nothing at all to wake a blocked system call off the
scheduler. Probes on 09723b40e: both hang (killed by -9 after 2 s).

On the scheduler both already end right: the call runs on the blocking
pool and the waiting fiber stops on a cancel, a deadline, or the
interrupt's cancel of `main` (`sched.poolCall`, `stopReason`).

## What a stop is, today
- a cancel: `task().control.canceled` (a task's cancel; for `main`, the
  interrupt handler sets `main_control.canceled`, `rt.onInterrupt`);
- a deadline: `task().deadline` (`time.within`);
- a pending termination *is* `main`'s cancel: `failMain`/`endBy` end the
  program by the signal once the cancel leaves `main`. A `main` that
  cannot fail keeps the default action, which needs nothing.

## Design
1. **One helper**, `rt.checkStop() Stop!void` (tasks.zig, beside
   `canceledHere` and `pastDeadline`): fails with `Stop.canceled` or
   `Stop.timeout`, else returns so the caller retries. Every EINTR retry of
   a blocking call calls it: std/file.zig's loops, net.zig's (its private
   `stopped()` is this helper and goes), `tasks.sleepHere`, and
   `rt.blockingStop`'s start. On a pool thread `task()` is the thread's own
   state, with no control and no deadline, so the helper retries there, as
   now: the waiting fiber is what stops.
2. **std/file.zig's calls fail with `Error`** (`Stop || FileError`), as
   net.zig's `readLent` already does, so `pool`'s `try try` is unchanged.
   `absent` passes a Stop through. `readHere` opens with `openAt` and
   reads with its own loop, not Zig's `openFile`/`readStreaming`, which
   retry EINTR inside std.Io where no Rig check can run.
3. **A deadline off the scheduler** arms an alarm: `blockingStop`, with
   no scheduler and a deadline (and not deterministic, whose clock is
   virtual), sets `ITIMER_REAL` to fire SIGALRM at the deadline and every
   10 ms after, with a handler that does nothing, installed once without
   SA_RESTART; it disarms when the call returns. The blocked system call
   fails with EINTR, the helper sees the deadline, and the call fails with
   `Stop.timeout`. The repeat closes the race of a signal landing just
   before the call enters the kernel. Off the scheduler the program has one
   thread, so the process-wide signal lands on it.

4. **The pool (added in building).** A pool thread stuck in a left call
   kept a read's String, which the leak check reported. A waiter that
   leaves now cancels the call through the thread's `Waker` (a `Control`
   its task state points to, so `checkStop` needs no new load) and sends
   it SIGALRM. A call not yet started never starts. `rt.finish` waits up
   to 1 s for left calls to end before the leak check, waking them again
   every 1 ms (`settleLeftCalls`).

## Left alone
- `print`'s `writeAllTo`: not a waiting point and cannot fail; a full
  pipe drains or the second signal ends the program at once.
- HTTP `fill`/`linger`, `readMore`, `duplicate`, `connect`: non-blocking
  descriptors or calls that never wait long; they keep their loops but
  call the helper where they already checked.
- Zig std.Io calls in file.zig for stat, mkdir, realpath, directory
  entries: none waits on another process.
- `waitpid`: only a runtime unit test's; no Rig program reaches one.
## Tests
test/cli/blocking_cancel.sh: FIFO open with SIGTERM (143, defer runs) and
under `time.within` (Stop.timeout), each with no task and inside a task;
a pipe read under `time.within` with no task; accept under `time.within`.
