# Preemption by default: the code a signal cannot stop (design, 2026-11-06)

Design only; the owner decides default-on, with pup's runs. Data: `owed-2026-11-06.md`, and below.

## The gap
A `RIG_PREEMPT=signal` handler stops a task only where its program counter is in the program's code section (`rig_text`). Two kinds of loop escape it:
- **Waiting points:** a loop that waits, such as one on `file.read`. #989 closed it: the yield check a signal leaves owed is paid at the next waiting point.
- **std's Zig code:** a loop of calls into std's Zig, which is outside the section. On main, a 20 ms sleeper beside one worker of `text.find` loops woke after 30 ms to 15.8 s on x86, and 99.9% of the signals were lost.

## B (lead): std's pure Zig in the program's section
In a build with the option, a pure std function has a twin with `linksection(rig.preempt_section)`, chosen at compile time:

```zig
pub const find = if (rig.preempt) findApart else findPlain;
```

A signal then stops the twin as it stops Rig code, with no check on any call. A build without the option compiles only the plain one, so it is the code it always was.

**Measured, x86, one worker, the sleeper's wake** (branch preempt-b):

| loop | main | B |
|---|---|---|
| `text.find` | 30 ms - 15.8 s | 20 ms, 0 of 3 signals lost |
| `text.count` | 20-314 ms | 20 ms, 0 lost |

**Eligible:** a function that takes no runtime lock, reads no thread-local or worker state, makes no scheduler call, and does not allocate. Code in the section may be stopped and resumed on another thread at any instruction.

**Enforced:** by `test/cli/preempt_section.sh`, which reads every instruction in the section of built programs: no thread-local read (`%fs:` or a TLVP relocation), no scheduler body, no uncounted lock, no use of x15.
- B's functions pass it.
- A function becomes eligible only by its twin, so the list is the source (`grep linksection std/`). The audit needs a program that calls each twin; std-text's search cases and the preempt cases do.

**The std Zig shims:**

| shim | functions | eligible | taken |
|---|---|---|---|
| text.zig | find, find_last, count, and the searches out of line | yes: pure loops over input | yes (B) |
| text.zig | parse_radix, parse_float | yes | not needed: short |
| char.zig | char_count, width, boundary_at, first/last_chars, char_step | yes: pure walks (its allocator is a test's) | candidates, if a loop of them is found to hold a worker |
| terminal.zig | widen | yes | a candidate |
| math.zig, crypto.zig, hint, target, *_tables | short or no loops | yes | not needed |
| file.zig, net (runtime), os.zig, time.zig, task.zig | system calls, the pool, the poller, the scheduler | no: they wait, and pay at their waiting point (#989) | no |
| http.zig | arg_of, header_of | no: they make a String (heap) | no |

**The runtime itself is not eligible.** That covers the allocator, Map and Set growth, List growth, the scheduler and the String builders: each holds the worker's heap or the scheduler's state.

## A (fallback): pay `owed` at a call's entry
This is what branch preempt-std built: the handler counts the workers that owe (`sched.owing`), and a function's entry pays when the count is not zero. It suits code that cannot be in the section but reaches safe points.

**Measured:** the same loops wake at 20 ms (x86 and the Mac). A build without the option is the same code as main (one md5 of `__text`, `--release` and `--release=fast`).

**Cost in a build with the option:** one load per call, plus a payment per owed signal.

**The cost of both, measured** (Mac, slot held, load 3-5): instructions per search of a 16-byte text, the least of 5 runs; the time is the fastest of 20 rounds.

| | find, --release | count, --release | find, --release=fast | count, --release=fast |
|---|---|---|---|---|
| main, the option | 82.07 | 151.92 | 81.03 | 119.97 |
| A, the option | 84.42 (2.9% more) | 155.19 (2.2% more) | 83.15 (2.6% more) | 123.41 (2.9% more) |
| B, the option | 82.29 | 151.98 | 80.16 | 119.60 |

- **Time:** 2.13-2.37 ns for `find` and 3.36-5.02 ns for `count` across all twelve programs, with no order between them beyond the run's spread.
- **Without the option:** A and B are each the same code as main, one md5 of `__text` in both modes.
- **In short:** A costs 2-3 instructions per call; B costs none.

## Uncovered, either way
- **The allocator and List growth, settled (built after B):**
  - After `allocSlow` returns, with its heap whole again, the allocator calls `sched.settleAt(@returnAddress())`. A List's growth, out of line (`growBy`, `growInline`), calls `settleAt(@returnAddress())` before it returns, so the inlined `push` holds no more code.
  - `settleAt` runs the owed yield check only when that address is in the program's code section, where a signal may stop the fiber at any instruction. So it is safe exactly where a signal already is. Elsewhere the caller may hold the worker's state, and nothing runs.
  - These are rare paths.
  - **Measured** (Mac, a 20 ms sleeper beside Lists of 2,000 Strings): 20-21 ms in every run, where main woke in 20-70 ms with four loops on two workers and 21-46 ms with two on one.
  - A build without the option is the same code as before (one md5 of `__text`, both modes).
  - **The cost with the option** (Mac, slot held, about 1,000 million instructions between the two runs counted):
    - A Int pushed into new Lists: 12.87 instructions against main's 12.71 (`--release=fast`: 11.56 against 11.42), 1.2-1.3% more.
    - A String made and pushed: 426.36 against 421.29 (361.50 against 356.62), 1.2-1.4% more.
    - Times are level (a push 0.42 ns on both).
  - `settleAt` first reads a process-wide count of the workers that owe (`sched.owing`). Reading the worker at every growth instead had cost 4.8% more instructions per push.
- **The other runtime loops** (Map growth, the String builders called out of line) still stop only where a signal lands in the program's code around them: late by a monitor period, never starved.
- **A single long call** in an ineligible function holds its worker for that call's length: one `file.read` of a huge file, which the pool takes, or one parse of a huge input.

## What the owner decides
1. Take B for std.text now (its PR), and add twins when a loop of a function is shown to hold its worker; or twin every eligible shim at once.
2. Keep A unbuilt, or take it for code that cannot be placed.
3. Default-on once B, the allocator's and List's settling, and pup's runs are in.
