# Review: PR #307 (stack-overflow-139), overflow handler

Scope: `git diff origin/main...HEAD -- src/runtime.zig docs/INTERNALS.md test/`
(onOverflow, installOverflowHandler, INTERNALS "The message.", the comment in
stack_overflow_recursion.rig). Read against Zig 0.17.0's installed std
(`std/debug.zig` handleSegfaultPosix / defaultHandleSegfault, `std/process.zig`
abort).

## Verdict

Nothing blocks merging. The design is sound. Every finding below is low
severity, or was already true before this PR.

## What I verified

**Handler order with the sanitizer.** `onOwnStack` calls
`installOverflowHandler` before it switches stacks. `rig.start`, which
installs `Sanitizer.installHandler`, runs inside `__rig_run_main` on the new
stack, so it runs later. The chain is therefore: sanitizer `onFault` (front),
then `onOverflow`, then Zig's `handleSegfaultPosix`. So `overflow_previous`
really is Zig's handler, as the docs say, even under RIG_SANITIZE=1.

- Guard fault under the sanitizer. `onFault` puts `onOverflow` back, sees the
  address isn't its own, and returns. The access faults again, into
  `onOverflow` (SA_NODEFER), which runs the guard path.
- Sanitizer-owned fault. `onFault` puts `onOverflow` back, prints its message,
  and returns. The access faults again into `onOverflow`, which takes the
  outside-the-guard path: it puts Zig's handler back and returns, and the
  access faults into Zig's handler for the trace. This is the same as before
  the PR.

**Calling Zig's handler directly is valid.**
- `handleSegfaultPosix` is `noreturn`. It never calls `resetSegfaultHandler`
  and never re-raises.
- It takes the fault address from `info` and starts the trace walk from `ctx`
  (the faulting PC and SP). So calling it from inside `onOverflow` gives the
  same trace as entering it from the kernel. Only `onOverflow`'s small frame
  is added to the alternate stack's use.
- Its only dependence on SA_RESETHAND is implicit. When the kernel enters it
  without SA_NODEFER, SIGSEGV is blocked. A synchronous fault while SIGSEGV is
  blocked is forced to SIG_DFL by the Linux kernel (force_sig_fault), and the
  program dies with status 139. That is exactly the bug.
- With the direct call, the disposition stays `onOverflow` and SIGSEGV is
  unblocked (SA_NODEFER). A nested fault from SIGSEGV or SIGBUS re-enters
  `onOverflow`, sees `overflow_handling`, and aborts.
- Zig's own "aborting due to recursive panic" path (`panic_stage`) is skipped.
  That is harmless.
- `std.process.abort` without libc on Linux raises SIGABRT, whose default
  action ends the program with 134. With libc it calls `abort(3)`.

**macOS aarch64, measured with this branch's bin/rig.** On macOS a guard
fault arrives as SIGBUS. `onOverflow` handles both SIGSEGV and SIGBUS.

| Test | Debug | `--release` |
|---|---|---|
| stack_overflow_recursion | 134, message and full trace (24.7k lines), "before" flushed | 134, message only |
| stack_overflow_frame | 134, message and trace | exits 0 (frame is small in release; the test has no `# release`) |

Both rows are the same with RIG_SANITIZE=0 and RIG_SANITIZE=1.

**Fault outside the guard.** I tested a raw `strlen(8)`.
- Debug, sanitizer on or off: 134, and Zig's "Segmentation fault at address
  0x8" with its trace.
- `--release`: identical to main's build.

Linux x86_64 isn't reproducible here. The burst suite covers it, because
`dive`'s 8 KB frame calls `zig_probe_stack` there and the test runs in debug.

**The flag bits.** `@intFromPtr(prev) > 1` excludes SIG_DFL (0) and SIG_IGN
(1) on both OSes. `handler` is an `extern union`, so reading `.sigaction` is
defined.

## Findings (all low)

1. **Test comment is wrong.** `stack_overflow_recursion.rig` says "so the
   test builds release only". `# release` means the test is *also* built with
   `--release` (test/README.md:103); it still runs in debug, which is the mode
   this PR fixes. The intended meaning seems to be "`--release`, not
   `--release=fast`". Suggested wording: "so the test is also built with
   `--release`, never `--release=fast`."
2. **`overflow_handling` is a plain `bool`.** Re-entry correctness depends on
   the store reaching memory before a later fault. Today it does: the store is
   followed by calls through function pointers (the writer's drain, Zig's
   handler) and by `write`, which is a libc call or a syscall asm with a
   memory clobber. A future refactor that inlines everything could in
   principle sink the store, and a nested fault would then miss the flag and
   recurse. Hardening: `@atomicStore(bool, &overflow_handling, true,
   .seq_cst)` and an atomic load, or `std.atomic.Value(bool)`. Not required.
3. **The comment and docs are narrower than the code.**
   - The comment says "A fault inside the handler that prints the trace". The
     check fires on any fault after the flag is set, including one inside
     `flushQuietly` or `write`. Such a fault now aborts before the message is
     written (still 134, but no "stack overflow" line).
   - INTERNALS no longer mentions the outside-the-guard path ("restores the
     handlers it replaced and returns"). It also leaves out the fallback that
     aborts when the previous handler isn't a SA_SIGINFO handler or Zig's
     segfault handler is disabled.

   Nothing stated is false. Optionally add one clause to each.
4. **Threads (latent; no Rig threads today).** The runtime and std have no
   `Thread.spawn`, and `Io.Threaded` is used single-threaded. If threads
   arrive:
   - Thread B's fault while thread A is in the debug trace path aborts at
     once and truncates A's trace. This is benign.
   - Thread B's unrelated fault puts Zig's handler back for the whole
     process. If A overflows in that window, A goes straight to Zig's handler
     and can die by 139 again on x86_64 Linux.

   Both cases are already dying, so neither misreports a healthy program.
5. **A second install would hang (already true before this PR).** If
   `installOverflowHandler` ran twice in one process, `overflow_previous`
   would hold `onOverflow` itself. A fault outside the guard would then put
   `onOverflow` back and return, forever. In a debug guard fault, the call to
   the previous handler would abort before the trace. Today `onOwnStack` runs
   once per process (main or `runTests`; the unit test at runtime.zig:5142
   once), so this can't happen. A one-line guard or assert would close it.
6. **Output lost on a fault outside the guard (already true before this
   PR).** That path doesn't flush `print`'s buffer: "before" was lost in the
   raw strlen(8) run.

## Async-signal-safety

- `onOverflow`'s own work is AS-safe: `sigaction`, `write`, `abort`, and
  reading globals.
- `flushQuietly` (re-entering the stdout writer) and Zig's trace walk are not
  AS-safe. Both were already used this way before this PR. With the flag set
  first, a fault in either now ends with 134 instead of 139, an improvement.
- A deadlock in Zig's `lockStderr` (if the overflow hit while stderr was
  locked) is Zig's own existing behaviour and is unchanged.
