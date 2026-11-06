# Loop split, lens: the scheduler and signal preemption (2026-11-05)

Panel `loop-split`, lens `preemption`. Read-only. I read the records, origin/main at cf6a362a6, and `archive/loop-split`. I made no timing runs. The only things I ran were `rig check --tasks` and `rig emit` on Trig, loco and examples/, from scratch copies in `the panel's scratch folder (not kept)`.

## Summary

- In any one build, preemption and the split exclude each other. Under `rt.preempt`, `turn`, `turnTake` and `turnEnd` all return at compile time (runtime.zig:432-447; archive/loop-split's `turnTake`). The split collapses to one block, and LLVM deletes the dead counter. So a preempted build gets the split's arm64 gain on every loop, not only on counted ranges that run to their end. It also loses the check's memory-clobbering cold call, which the split keeps at each block's end.
- With preemption on by default and ported to arm64, the split's fallback population is close to empty:
  - local-task programs: none among the real programs;
  - debug builds and `rig test`: their speed does not count.
- I recommend: do not land the split. Keep its gain by porting preemption to arm64, and gate that port on one Mac measurement.

## 1. Where yield checks remain once preemption is on

Emit writes checks only into a program that makes tasks (`em.yield_checks = tasks`, main.zig:1916). Preemption removes them only when all of the following hold:
- the program makes tasks and makes no local task (main.zig:1901-1905);
- the target is Linux x86-64 with LLVM's backend (`preempt_built`, sched.zig:499);
- the root carries `__rig_preempt` (main.zig:1937, written only for module 0 and only when `!kind.batch`).

| Case | Where in the code | Real programs |
|---|---|---|
| A program that makes no task | main.zig:1916 | Has no checks either way. All 14 programs in examples/ (0 `rig.turn` sites). |
| macOS (arm64 and x86-64), Linux aarch64, Windows | sched.zig:499 | Every Mac build of Trig and loco. Linux aarch64 servers have the same arm64 chain cost the split targeted. |
| Linux x86-64 debug builds (Zig's own backend) | sched.zig:499-500, design.md Q6 | `rig run`'s default and Trig's sanitize/debug packs. Speed does not count here. |
| A program that makes a local task | main.zig:1901-1905, sema `Facts.local_tasks` | None. Trig: `rig check --tasks` lists none (a pack with a stubbed `libtrees`). loco: none. std: none (design.md). |
| `rig test` and seeded runs | design.md "Built (17a33377b)": `rig test` writes its own root | Tests only. |
| `rig batch` | main.zig:1934 (`!kind.batch`) | The test harness only. |

Sizes of the two real task programs:
- **Trig** makes tasks: 3,446 `rig.turn` sites and 392 `rig.tickCall` sites in its emitted package, with no local task.
- **loco** makes tasks (walk.rig:114-117, 433): 124 turn sites in loc.zig, 54 in the std modules it uses, and 3 tickCall sites, with no local task.

So on Linux x86-64 release builds, default-on preemption leaves no checks in any real program. On the Mac every check remains until the port lands. Mac is where loco (a CLI tool) and Trig's developers mostly run.

One gap is not a remaining check but matters. Rig code that the optimizer inlines into the runtime is outside `rig_text`, and with `rt.preempt` it also has no check. design.md lists it: a Map's hash or equality of a program's type in ordered.zig, iterator stages, `par`'s element functions. Such code can be neither checked nor stopped until it returns. Trig's share of it is small (88% of samples lie in the section). It is still a latency regression from today's checks.

## 2. The Mac port (arm64)

**Mechanism: signals, as on Linux.** Go has used SIGURG and `pthread_kill` on darwin since its async preemption. Rig's `signalThread` already calls `pthread_kill` when it links libc (sched.zig:842-850). The arm64 `ucontext` reader already exists: `DarwinContext`, runtime.zig:7595, with `pc` at 272 and `regs[31]` as sp.

**The arm64 problem.** No arm64 instruction branches to an address held in memory. The trampoline restores every register and then needs one free register to jump back to the interrupted PC. There are two honest answers:

1. **Reserve one register (Go's design).** Go's arm64 `asyncPreempt` ends `MOVD (RSP), R27; ... JMP (R27)`, because Go's compiler never allocates R27. Zig 0.17 exposes LLVM's `reserve_x9` to `reserve_x15` (lib/std/Target/aarch64.zig:155-179). A preempted build would pass `+reserve_x15`, and every instruction in `rig_text` then leaves x15 dead. It takes one signal per preemption.
   - Cost: one fewer caller-saved temporary in all code. It must be measured with preemption off.
   - x18 is not a candidate: Darwin reserves it and the kernel may zero it.
   - x16 and x17 cannot be reserved in LLVM.
2. **Use `brk` with a SIGTRAP handler (design.md's plan).** No register is reserved. The cost is two signals per preemption. Under lldb, `brk` raises EXC_BREAKPOINT at the Mach level, so every preemption stops the debugger. This only affects release builds run under a debugger.

I would build (1) and keep (2) as the fallback if the reserved register costs more than 0.5% on Trig.

**PAC.** Zig's macOS target is arm64, not arm64e, so the PCs in a signal context are unsigned and need no `ptrauth`. The trampoline resumes with `br`, not `retaa`, and saves and restores x30 untouched, so `pac-ret` code would be unaffected too. Only an arm64e target would need the kernel to sign the PC (`__darwin_arm_thread_state64_set_pc_fptr`); Rig has none.

**Mach `thread_suspend`, `thread_get_state`, `thread_set_state`, `thread_resume`.**
- It is feasible: as I recall, .NET's PAL on macOS and the Boehm and JSC collectors use it. I did not check that here.
- It only replaces delivery: the resume still needs the trampoline and its free register.
- It costs four Mach traps per preemption and blocks the monitor while they run.
- Apple's newer restrictions on `thread_set_state` apply to arm64e and to other tasks. I am not certain they spare all same-task arm64 uses, so the port should be preceded by a 50-line probe.
- Recommendation: signals first. Mach only if Darwin's signal latency is poor.

**Darwin traps to carry over:**
- A signal pending at thread exit: Go waits for its pending preemption signals before a thread exits on darwin, the same hazard design.md notes for `pthread_kill`.
- `getsectiondata` for the section's bounds: Zig's Mach-O linker defines no `section$start`.
- `poll(2)` cannot read a kqueue, so a worker with descriptors is signaled every period.
- TLV accesses: Darwin's thread-locals are reached by a call through a descriptor, and the call's result may stay in a register. The section audit must look for it, as it found `%fs` reads on x86.
- SVE and SME: decline, as `keeps_registers` already does (runtime.zig, after :460).
- On Linux aarch64: BTI, if the binary were ever marked for it.

**Size.** `preempt_built` gains aarch64 macOS and Linux. The work:
- the handler (only pc and sp differ by OS);
- the arm64 trampoline: x0-x17, x29, x30, NZCV, FPSR, FPCR and q0-q31, about 100 lines of assembly;
- `getsectiondata`, a portable `sleepNs`, the kqueue rule;
- the `-mcpu=...+reserve_x15` flag where `bin/rig` invokes Zig;
- a Mach-O variant of test/cli/preempt_section.sh.

That is roughly 250-400 lines and 2-4 days. Linux aarch64 shares the trampoline. I judge it feasible and honest: the same mechanism Go ships.

## 3. Can they work together?

**In one build: no.** The split is a no-op under preemption. If it were revived, emit should not split when `code_section` is set, and the decision belongs in storage, not emit. archive/loop-split decides it in emit (`leavesEarly`, `emitRangeFor`), which strains North Star 4.

**As the fallback for builds that keep checks: not worth its 102 lines once arm64 is ported.**
- Local-task programs: there are none.
- Debug builds and tests: their speed does not count.
- Windows and macOS x86-64: x86, where the split gained little (pup: Trig neutral, `even-tasks` cycles 2.7% more).
- Before the port, the split would be a Mac interim deleted months later. Its Trig effect on the Mac has never been measured.

**Making local-task programs preemptible.** Each option, and why I rejected it:
- *Preempt a pinned fiber and run only unpinned work.* This is the deleted hold. It is sound for counts but not live: starve.rig hangs.
- *Safe-point maps*, as Go's unsafe-point tables: not expressible through Zig 0.17 and LLVM.
- *Two copies of the code*, one with checks and one without: doubles the code size. No.
- *A flag polled at each turn, armed by the monitor,* replacing the count. The monitor now exists, which removes the flag's 2026-10-30 drawback (timers and pollers, sched-check §3). It stays a safe point, so it is sound for local tasks. But on Trig it measured neutral (0.2-0.3% fewer instructions), because its cold call still clobbers memory and blocks hoisting (sched-check §2). It recovered knucleotide-fast's 9% on the Mac. It is worth building only when a real local-task program shows the count's cost.
- *Change the promise.* Local tasks would take turns only at their waits, as tokio's `LocalSet` tasks do. The hold would come back and no checks would remain anywhere. This is a SPEC/CORE decision for the owner, and no program needs it today. My default: no.

## 4. Recommendation and order of work

Drop the split. Replace it with preemption everywhere it can run, and keep today's count checks where it can't (local tasks, debug builds, tests). Steps:

1. **The Mac ceiling, before any port. It settles the split's open question too.**
   - Trig's six projects and loco on the Mac, with three `bin/rig` arms built from a scratch copy:
     - base (main);
     - `archive/loop-split` merged into the same main;
     - a measure-only arm in which `turn` and `tickCall` return at compile time.
   - Run under `tools/low`, at one checker, 20 interleaved rounds, fastest-of-N with cycles. It needs the Mac quiet, and is not possible today.
   - Decision rule: if the ceiling clears the bar (more than 1.5% faster, or at least 1% fewer instructions), the port pays. If the split arm is at or near base, the split is closed on arm64 too.
2. **The woken-task latency, on x86.** It blocks default-on whatever happens to the split.
   - Today `hog` is 13.5 ms against 6.2 ms with checks. A woken task waits about two monitor periods of 50 µs, and the monitor wakes 20,000 times a second while work is queued.
   - Design: when a wake queues work for a worker that is running another fiber and no worker is idle, signal that worker at once. Keep one pending signal per worker. This replaces the 50 µs polling.
   - Measure, on pup in a slot: `hog`, `spawn`, `chain`, `yield`, the actors rows, and the monitor's own CPU time. Target: `hog` within 1.5 times off, and no row more than 2% slower than today's on-arm.
3. **The arm64 port, if step 1 clears.**
   - 3a: a probe of `pthread_kill` latency and PC rewriting on macOS.
   - 3b: the cost of `+reserve_x15` with preemption off, on Trig on the Mac. It must be within noise.
   - 3c: the port, then Trig on the Mac, on against off, 20 rounds, and bench/tasks (expected at least the split's 14-21% on its CPU loops).
   - 3d: the same trampoline on Linux aarch64.
4. **The section audit on Mach-O, then default-on,** as the owner's round lists. The question is whether default-on runs in `--release` only, with debug builds keeping their checks.
5. **Local tasks stay on counts.** Revisit the monitor-armed flag only if a real local-task program shows the count's cost.
