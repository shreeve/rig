# Ctrl-C: an interrupt cancels `main`

## What is already decided

docs/design/concurrency.md, "The program's end waits for its tasks": "An interrupt (SIGINT) cancels `main`."
SPEC §18 already leans on it ("an interrupt may still cancel `main`, so a program may wait on a channel for
nothing but that"). The runtime does not build it: `src/runtime.zig` installs handlers for SEGV and BUS only.

## The rule

An interrupt is a cancel request sent to `main`'s task. Nothing new appears in the language or std.

- `main` fails with `task.Stop.canceled` at its next fallible waiting point (`task.check()`, `time.sleep`,
  a wait on a task that can fail, `accept`, `read`, `write`, a channel wait).
- From there everything is Rig's ordinary cancellation: `defer`s and drops run, the tasks `main` owns are
  canceled and waited for, and every socket and file closes as its owner drops.
- A program opts in by being able to fail. A `main` that cannot fail (`sub main()` with no `!`, which never
  propagates) cannot be canceled, by the existing rule that only a task that can fail is canceled, so an
  interrupt there keeps the operating system's default: the process ends at once, exit status 130.

## Details to decide (defaults in brackets)

1. **Signals:** SIGINT and SIGTERM both cancel `main` [yes: servers are stopped with SIGTERM by systemd and
   containers]. SIGHUP and the rest keep their default [yes].
2. **A second interrupt** while the first cancel is still unwinding ends the process at once, status 130
   [yes: a program stuck in a loop with no waiting point can always be stopped].
3. **Exit status:** a `main` that fails with `Stop.canceled` because of an interrupt prints nothing (not
   `error: Stop.canceled`) and exits 130 (128 + SIGINT, 143 for SIGTERM), as shells expect [yes]. A `main`
   that catches the cancel and returns keeps its own status.
4. **Delivery:** the handler only sets an atomic flag and wakes the scheduler (the poller's wake-up path, or
   a self-pipe in a program without tasks); the cancel itself happens on a normal thread, never inside the
   handler [the only safe way].
5. **Blocking calls in a program without tasks:** the handler is installed without `SA_RESTART`, so a
   blocking `read`, `accept` or `sleep` returns `EINTR`, which the runtime turns into `Stop.canceled` at
   that waiting point [yes].
6. **Tests:** deterministic runs (`rig test`) cannot receive a real signal; a CLI script sends `kill -INT`
   to a running program and checks its drops ran and its status is 130 [yes]. A test-only way to inject
   an interrupt into a seeded run is a later addition [later].
7. **No signal API in std for now** [yes]. A program that wants to handle other signals (SIGHUP to reload)
   gets a channel of signals later, when one needs it, as its own std design.
8. **Windows** (a console control handler) when Rig targets Windows [later].

## Cost and size

One handler, one flag, and the wake-up path the scheduler already has: a runtime change of perhaps 100-200
lines plus tests. It is a runtime change, so it is checked on pup (unit tests in three modes and the four
concurrency benchmarks) and built by Trig before it lands.

## What it gives mini-redis

The listener loop `c = l.accept()!` fails with `Stop.canceled` on Ctrl-C, `run` returns, and `main` cancels
and waits for every connection task it owns; each connection's socket closes as it drops. Tokio's version
needs `tokio::signal::ctrl_c()`, a `broadcast` shutdown channel, a `select!` in every connection, and an
`mpsc` sender held by each task so the server can wait for them. Rig's needs none of it.


---
Approved by the owner on 2026-10-21, in his words: "Approve the defaults in §15 of the errors SPEC and in the Ctrl-C proposal."
