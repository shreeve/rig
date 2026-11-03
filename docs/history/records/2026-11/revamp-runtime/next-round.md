# Revamp of the runtime and std: round 3, ready to start

Rounds 1 and 2 landed (#902-#907; ledger.md beside this file). What is
left from the audits needs timing on pup, so each item lands as its own
PR with numbers. Every finding below is cited, with its probe, in
audit-concurrency.md, audit-std.md, or review-904.md.

## Items, in order

1. **C8: file I/O without `lent`** (src/net.zig 429-741, src/sched.zig
   1806-1842). Each `File.read`, `write`, and `sync` copies its
   descriptor (`fcntl(DUPFD_CLOEXEC)` and `close`), takes a process-wide
   SpinLock with a map put and remove, and makes a pool round trip. One
   `io.copy` block, from file to file, makes 2 allocations and 3 copies
   of 64 KiB. The fix passes an owned `Fd` and String by value as
   pool-call arguments. Measure `io.copy` and Trig's file reads, Mac and
   pup.
2. **C14: one completion primitive.** `Header` and `Message` are the
   same one-shot completion, and `Wakeup`, `Sel`, and the pool call
   repeat one handshake. That is about 60 lines, and it touches the
   task-join hot path, so time bench/tasks spawn and chain on pup
   (P-core 6, alternated against main), as #904 was timed.
3. **C10: accept's poller.** A hand-written server registers every
   accepted socket with the acceptor's worker's poller, while
   `http.serve` registers each in its connection's task. Register on
   the first `EAGAIN` instead, and measure on bench/net and bench/http
   on pup. bench/http cannot run back to back on the Mac, which runs
   out of ephemeral ports.
4. **C12:** `ownArgs`'s compile-time guard recurses into struct, array,
   and union fields.
5. **C16:** about 40 lines of std shims that only forward one call each
   (std/net.zig, task.zig, time.zig), once `rig.expectShim` accepts an
   alias. C15's emit half belongs here too: emit calls `xInto(...,
   rig.no_slot)` directly, and the 11 `x` wrappers go.
6. **Left from the reviews:** R5 of review-904 (several tasks on one
   listener may lose an edge; reasoned, not reproduced in 900 rounds),
   R6 (a full mailbox's slot is freed after the caller wakes, which
   costs a sleep and a wake), and an actor runner that panics does not
   wait for the tasks its method started (concurrency.md, *planned*).
   Also S22 (`ensure_with` and `ensure_by` hash a new key twice; this
   needs a table method declared in `resolve.registerTable`) and S23
   (the shared iterator cursor; generic code cannot call the built-in
   tables' methods).

## How it was run

- One worktree and draft PR per item (`wt new NAME`). Implementers on
  Opus, at most 3 at a time.
- The lead runs the guards (`bench/{json,hash,text}/guard.py`) on each
  branch head, every time. A late commit once made Map's text-hit row
  58% worse.
- An independent Opus reviewer reads each concurrency PR.
- pup: `tools/pup-rig SHA`, then `PUP_RIG=... tools/light` from a Trig
  checkout. `zig build test` in debug, safe, and fast with
  `-Dnexus=$HOME/Data/Code/nexus/bin/nexus` on E-cores 12-19. Benches
  are built on E-cores first, then timed in a slot (`/tmp/open-slot.sh
  NN MIN`) on P-core 6, alternated.
- Close a slot with `rm -f /tmp/slot-active` and a kill of its guard by
  pid. A `pkill -f` whose pattern appears in its own ssh command kills
  that command.

## Decisions waiting for the owner

owner-decisions.md beside this file lists 12, each with a default.
