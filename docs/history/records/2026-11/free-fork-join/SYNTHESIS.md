# Free fork-join, the build round: synthesis (2026-11-18)

Three experts on Opus 5.5 wrote to [brief.md](brief.md):
- [ceiling.md](ceiling.md): a hand-written Zig fork-join, timed on the Mac against Rig and Rayon,
  with Rig's costs put back one at a time (programs in `ceil/`, samples in `raw/`);
- [runtime.md](runtime.md): how it is built on today's scheduler;
- [language.md](language.md): what the checkers record, what SPEC and CORE say, and a soundness
  review of runtime.md.

## What the round found

- **Psum at 12 workers is decided by the first pass, not by forks.** The board times one psum a
  process, so a worker's start and its heap's first huge page fall inside it. #1158 (workers start
  as `main` starts) and #1156 (a heap's first 2 MiB on small pages) remove those. With the early
  start alone, Rig's one-pass psum at 10 workers already beats Rayon on the Mac: 2.452 ms against
  2.542, paired 0.970 [0.910-1.000]. Warm passes at 10 workers: the ceiling 2.048, Rig 2.121, Rayon
  2.160. On pup, a probe with both effects removed ran the first pass in 3.87 ms against Rayon's
  4.32. The ceiling expert puts Rig beating Rayon on pup's 12-worker board at about 75%, once both
  land. On pup the ceiling itself runs that pass in 3.94 ms against Rayon's 4.61, with its workers
  started before it (ceiling.md, "The pup board"); Rig at main took 6.09.
- **Per join:** the ceiling pays 3.7 ns, Rayon 9.9, Rig 67.6 (`nil`, 1 worker, warm). A stack and
  two switches are 20.5 ns of Rig's excess, its sequentially consistent stores 8.2, a heap record
  0.9, the monitor's count 0.8; about 40 ns more is Rig's task path itself. At 1 worker that is 7%
  of psum, the whole warm gap to the ceiling; at 10 workers about 1%, inside the A/A spread.
- **The preemption monitor is the largest single cost at 1 worker.** While a ring holds work it
  wakes every 50 µs, about 5 µs a wake-up on macOS, and stops the fiber. With its wait at 10 ms,
  fork.rig's qsort at 1 worker runs 15% faster (136.3 ms against 161.5), level with the same
  program written with no task, and psum 4% faster. At 10 workers it changes nothing.
- **Recursion is solved without a depth proof.** A task runs on its waiter's stack only when the
  room left there is at least what its own stack would give it: its proven depth when the compiler
  proves one, else a whole task's stack. A task's stack reserves 1 MiB of address space past
  `main`'s 64 MiB, so a waiter that has used no more than that inlines any fork, recursive or not.
  psum's inline chain is about 12 KB, qsort's about 11 KB. Both experts reached this rule
  separately.
- **The queue is a separate Chase-Lev deque of forks per worker,** not the ring: the ring's push
  must fence for the sleep handshake, its thieves take half, and the monitor counts it. An unstolen
  fork and its join cost one full fence against today's five, with no allocation, stack or switch.
  Forks count for the 10 ms slice but not the 50 µs two-look rule.
- **Soundness, as reviewed.**
  - Agreed: one fiber with the task's state swapped in; panics passed on a level at a time, with no
    catch point; cancels through a fiber bit and parent links.
  - Unsound as first written: `Control.finish` takes a task off its isolate's list before its last
    writes into the record. With a frame record, a stolen fork whose maker panicked could write into
    a stack already given to another task. The release must be the record's last access.
  - Owed before code: `runHere` reads its worker again after the call; the deque's arm64 orders
    are stated in the model; a Lean model of the record's lifetime; a lemma that an inline run is a
    schedule of the existing semantics.
  - A gap: no Lean model covers `Ring.takeLast` or the `stealing` flag, where the #1157 race lived.
- **An existing bug of the same class, fixed on its own:** an idle actor's method ran inline with a
  quarter of the caller's stack left, so a method recursing past 16 MiB overflowed only when it found
  the actor idle. The same room rule fixes it (branch `actor-room`).
- **What changes for a program:** nothing it writes. SPEC §18 says a task's stack is "at least as
  large as `main`'s" and when a task runs inline. CORE does not change; the oracle learns nothing,
  since no program is accepted or rejected differently.
- **Open, not this round's:** on the Mac, both Rig and Rayon read their input 0.4 ms (10 workers)
  to 2.5-3.5 ms (1 worker) slower in a process's first pass, and so does fork.rig with no task;
  one board later it was gone.

## The decisions (defaults)

The owner approved these on 2026-11-18 ("Approve the defaults").

1. Land #1156 and #1158 first; they decide the 12-worker board. The Rig session runs
   `ceil/pup-job.sh` with the early-start Rig, then with main once both land.
2. Land the actor room fix (`actor-room`) on its own, ahead of the feature. It also brings the
   1 MiB of extra stack address space the inline rule needs.
3. The Lean models before code: Ring with `takeLast` and the `stealing` flag (checking #1157 after the
   fact), a Deque model with arm64 orders, Sleep with forks, the record's lifetime, and the cancel
   bit.
4. Build in this order, each its own PR, measured, revertible, and level on bench/tasks, actors,
   net, http, Trig, loco and the guards: the monitor (forks out of the two-look rule, in the slice);
   the record in the frame, with the isolate's release made last; the inline run on today's queue;
   the Chase-Lev deque.
5. SPEC §18: "at least as large as `main`'s" and the inline clause; CORE unchanged; the oracle
   unchanged.
6. qsort at 1 worker joins the fork board, where the monitor's cost shows.
7. The Mac's first-pass input effect goes to the memory side as its own open finding.
