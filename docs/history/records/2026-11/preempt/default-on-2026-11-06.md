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

**Cost in a build with the option:** one load per call, plus a payment per owed signal. Per-call cost on `text.find` and `count` of 16 bytes, instructions and time, A against B against main: *pending, the Mac slot at load < 3*.

## Uncovered, either way
- **The allocator and the other runtime loops:** a task stops only where a signal lands in the program's code around them. A List of 2,000 Strings wakes the sleeper in 20-50 ms: late by a monitor period, never starved.
- **Rig's recommendation:** pay `owed` at the allocator's slow-path exit, once its heap is consistent, and after a List grows: rare paths, so no measurable cost. This is not built or measured yet.
- **A single long call** in an ineligible function holds its worker for that call's length: one `file.read` of a huge file, which the pool takes, or one parse of a huge input.

## What the owner decides
1. Take B for std.text now (it is ready), and add twins when a loop of a function is shown to hold its worker; or twin every eligible shim at once.
2. Keep A unbuilt, or take it for code that cannot be placed.
3. Default-on once B, pup's runs and the allocator's exit are in.
