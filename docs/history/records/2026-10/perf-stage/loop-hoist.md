# Table reads in loops, and what a yield check costs (2026-10-26)

**Question.** Trig (fork)'s disassembly report of 2026-10-26 (ts-pattern,
one checker, Trig PGO on Rig 9822afed9 against tsrs PGO) charged Rig's
patterns with about 870M of the 940M-cycle gap. Two of its rows were
this branch's:

- **Row 2, Table reads, 422M cycles:** the base load `&self.slots[i]`
  (table.zig:189) took 186M, reloaded on every access.
- **Row 5, yield checks, 122M cycles against tsrs's 0:** `turn` 86M,
  `tickCall` 18M, the flag load 18M. The report read the cold
  `sched.tick()` call in a loop as what blocks LLVM's loop-invariant
  code motion (LICM), so that `mapper_map`'s search loop takes 10
  instructions where the work needs about 5.

The owner: "We have to do what we can to match or beat tsrs", and
"think of ways to remove extra checking, while still informing LLVM
that loops or other code doesn't need to be checked".

**Answer.** The base is reloaded for a reason the report did not
see: the index test before the load leaves the loop, so the load is
not sure to run, and LLVM may not run it early, since Zig tells it
nothing about the pointer it loads from (no `dereferenceable`). With
no yield check at all the loop still reloads the base. Telling LLVM
that a lent container does not change (`noalias` on views) is worth
nothing on Trig today, and running a range loop's turns in runs with
no check is worse. What a yield check does cost is the registers its
call clobbers. Built: the check calls the scheduler through a function
that keeps every register, so a loop or a function with a check pays
for the count alone. Trig release, ts-pattern: 1.9% fewer instructions;
with PGO, as Trig ships, 0.8-0.9% fewer on ts-pattern and zod3, under
the bar of 1%, and time within the noise.

## 1. The search loop, and why the base is reloaded

`Checker.mapper_map`, the array mapper (Trig `src/checker/members.rig`):

```text
sources = (?@).mapper_sources(m)
for i in 0..sources.len()
  return (?@).type_at((?@).mapper_targets(m), i) if t == (?@).type_at(sources, i)
```

`type_at(?@, list, k)` is `@store.type_lists[Int(list.start) + k]`, a
read of `Table[TypeId, 1 << 28]` with an `Int` index, inlined. Release
build on Rig main (`5a79e02f2`), pup:

```
cmp  $0x10000000,%r12 ; jae panic     the index test: start + k < 2^28
mov  0x3b0(%rbx),%rcx                 the Table's base, from self
cmp  (%rcx,%r12,4),%r11d ; je found   the work
dec  %eax ; je tick                   the turn
dec  %r14 ; inc %r12 ; cmp ; jne      the loop
```

Three builds of that loop say what holds the load in it:

| build | the loop |
|---|---|
| main | as above: 11 instructions (the report's 10), the base reloaded |
| no turn counted at all (an experiment, `RIG_NO_TURNS`) | 9 instructions, the base **still reloaded** |
| `noalias` on every write-view parameter, `self` among them | 11, the base reloaded |

Small Zig loops of the same shape (an index test that panics, then a
load through a field of `self`, then the work) show both causes:

| the loop holds | `self` plain | `self` `noalias` |
|---|---|---|
| the index test and the yield call | reloaded | reloaded |
| the yield call, no index test | reloaded | **hoisted** |
| the index test, no call (turns run in runs) | reloaded | |
| neither (turns run in runs, no index test) | hoisted | |

LICM hoists a load only if it is sure to run once the loop is entered,
or is safe to run early. The index test's panic leaves the loop before
the load, so it is not sure to run; and it is safe to run early only
from a pointer LLVM knows is dereferenceable, which Zig never says of a
`*T` parameter. So the yield call is one cause, and the index test the
other: the five-instruction loop needs both gone.

## 2. Options measured on Trig

Trig main (`c75127e`), each built `rig build --release` by a variant of
Rig main; ts-pattern, `--singleThreaded`, pup core 8 (sibling 9 idle),
fastest of 5-7 runs interleaved, every build's output identical to
main's. pup had other sessions' release builds running on other cores:
read cycles within about 1% as noise.

| variant | instructions | cycles | reading |
|---|---:|---:|---|
| main | 10.111-10.115G | 4.49-4.59G | |
| `noalias` on write-view parameters (`sema.exclusiveParam`) | 0.2% fewer | 0.2% fewer, 1.0% more | nothing |
| `noalias` on read views too | 0.1% fewer | 0.5% more | nothing |
| range loops in runs: a run up to the next check, a loop with no check in it, counted at once after (`rig.turnStop`, `rig.turnsRan`) | **2.8% more** | 1.5% fewer | worse |
| range and slice loops in runs | **3.9% more** | 0.3% fewer | worse |
| (bound) no loop counts turns | 5.9% fewer | 2.1-4.1% fewer | |
| (bound) the count kept, no call | 1.8% fewer | 0.6% fewer | |
| (bound) the count kept, the call an `asm` that may write memory but no register | 1.9% fewer | 0.6-1.5% fewer | |
| **built: the call through a function that keeps every register** | **1.9% fewer** | 0.4% fewer | |

- **`noalias`.** Owner-approved as a queued round for write views
  (records/revamp/r3/brief-noalias.md), and FORMAL's plan holds it
  until stage 2. It needed `noalias` written in every function type as
  in each declaration, and a wrapper for each Zig-backed function with
  a write view, and still failed to compile where a generic's function
  type takes a concrete function. Trig gains nothing from it today,
  since the index tests keep the loads in the loops (section 1). It is
  the right tool for this loop once the index test is gone: then the
  yield call is the only thing between it and five instructions.
- **Runs of turns.** Each loop entry pays about ten instructions to
  set up a run and count it, and most of Trig's loops are short. The
  inner loop also starts at an opaque point, so LLVM loses what it knew
  of `start + k`: the overflow (`jo`) and sign (`js`) tests it had
  proven away came back into `mapper_map`'s loop (11 instructions).
- **The bounds.** Counting turns costs about 4% of the instructions and
  little time (a `dec` and a branch that fuse and predict); the call's
  clobbered registers cost the other 1.9%: a function whose only call
  is the cold tick saves and restores callee-saved registers on every
  call, and moves values around the call.

The patches of the measured variants are kept beside this record
([loop-hoist-data/](loop-hoist-data/)).

## 3. What was built

`rig.turn` (a loop's check) and `rig.tickCall` (a recursive function's
entry check) call the scheduler through `callKeeping(f)`, in an
optimized build for x86_64 (System V) or aarch64:

- An `asm volatile` steps over the red zone (128 bytes), keeps the link
  register on aarch64, and calls `Keeping(f).call`. Its clobbers are the
  flags and **memory**: LLVM still assumes the call reads and writes any
  memory, as it may, since other tasks run. Only which registers survive
  it changes. There is no assumption about memory to prove.
- `Keeping(f).call` is a naked function: it saves the integer registers
  a call may change (rax, rcx, rdx, rsi, rdi, r8-r11; x0-x17, and x18
  off Darwin), aligns the stack to 64 bytes, saves every vector register
  the target has (`xmm0-15`; `ymm0-15` with AVX; `zmm0-31` and `k0-7`
  with AVX-512; `q0-q31` on aarch64), calls `f`, and restores them.
- A debug build, Windows, a target with SVE or APX, and any other
  architecture call the scheduler plainly. Cross builds checked by
  disassembly: x86_64 baseline (Linux, macOS), `x86_64_v4` (`kmovq`),
  `knl` (`kmovw`), aarch64 generic (x18 kept), `neoverse_v1` (SVE: the
  plain call).

The hot loop is unchanged; the cold path no longer moves anything:

```
main                                   this branch
dec  %eax ; je tick                    dec  %esi ; je tick
...                                    ...
tick: mov %r11,%rbp                    tick: lea -0x80(%rsp),%rsp
      call rig.sched.tick                    call Keeping(tickC).call
      mov %rbp,%r11                          lea 0x80(%rsp),%rsp
```

A small function with a search loop shows what it was worth: on main it
saved and restored four registers on every call on x86_64 (six on
aarch64) for the sake of the tick; it now saves none.

## 4. Safety and tests

The change keeps the scheduler's semantics: the same checks, at the
same points, calling the same functions. The memory clobber stays, so
nothing LLVM may assume across a yield changed. Tests
(test/rig/concurrency-task.rig.test):

- `task loops over lent containers`: range loops over a List and a
  Table lent to seven tasks at once, past many yield checks, with
  `continue`, `return`, a loop value's `break` and `else`, a nested
  loop, U8 and negative bounds; under 20 seeds, and again built for
  release.
- `task loan holds across yields`: a task that writes a List another
  task's loop reads is rejected, as before.
- `task yield keeps registers`: nine tasks each hold eight integers,
  two floats, and a vector in registers across 50,000 turns, under 20
  seeds, built for release.

The suite's runner sets `RIG_SANITIZE=1`.

## 5. Trig with PGO, as it ships

Trig main (`c75127e`) built `rig build --release --pgo`, trained by
`tools/trig/bolt-train` as `tools/trig/pgo` does (mitt, neverthrow,
superstruct, zod3), once by Rig main and once by the branch, each with
its own profile. pup core 8, `--singleThreaded`, fastest of 10
interleaved, two passes; output and exit status identical on the six
cli projects (ts-pattern, zod3, tiny-invariant, mitt, neverthrow,
superstruct), for the PGO and the plain release builds alike.

| project | pass | main wall | branch | instructions | cycles |
|---|---|---:|---:|---:|---:|
| ts-pattern | 1 | 1012.5 ms | 0.5% faster | 0.9% fewer (8.667G to 8.592G) | 1.4% more |
| ts-pattern | 2 | 1031.8 ms | 1.2% slower | 0.9% fewer (8.667G to 8.588G) | 0.6% fewer |
| zod3 | 1 | 201.9 ms | 0.4% faster | 0.8% fewer | 0.9% fewer |
| zod3 | 2 | 211.1 ms | 1.5% faster | 0.9% fewer | 0.3% fewer |
| tiny-invariant | 1 | 97.2 ms | 1.5% faster | 0.4% fewer | 2.5% fewer |

`mapper_map` is 5.7% smaller (2,315 lines of disassembly to 2,184),
with the same search loop.

**Against the bar** (more than 2% faster, or at least 1% fewer
instructions): the plain release build clears it (1.9% fewer
instructions); the PGO build, as Trig ships, does not (0.8-0.9% fewer,
time within the noise). PGO's layout and register allocation likely
already keep most of the plain call's cost off the hot paths.

## 6. The benchmarks

- **std.json and bench/hash** make no tasks, so they have no checks:
  built by main and by this branch (pup, `--release` and
  `--release=fast`), the 12 std.json programs and both hash programs
  have the same machine code, instruction for instruction.
- **bench/tasks** (base and branch interleaved, fastest of 9 on the
  Mac and of 11 on pup, cores 6-9; both machines had other sessions'
  builds running). A whole `rig-fast` run on pup retires 4.8% fewer
  instructions (17.34G to 16.50G). The times move both ways by more
  than the change could: `yield` and `spawn` do not reach a turn's
  call more than once per 1,024 waits, and one binary's `yield` ranges
  over 18-22 ms from run to run.

| benchmark | pup fast | pup safe | Mac fast | Mac safe |
|---|---:|---:|---:|---:|
| spawn | 2.2% slower | 6.5% faster | 0.3% slower | 7.5% faster |
| chain | 1.3% faster | 0.4% faster | 0.5% faster | 1.4% faster |
| fanout | 1.9% slower | 0.9% faster | 6.2% faster | 2.1% slower |
| yield | 6.8% slower | 0.6% slower | 1.2% slower | 2.8% faster |
| hog | 4.7% faster | 5.1% faster | 4.8% slower | 3.6% slower |

## 7. What would make the loop five instructions

1. **The index test gone.** `start + k` against `2^28` for every `k`
   below a list's count: a range proof from the list's construction
   (row 4, the bounds work), or Trig reading the list as a slice once
   (`type_list_items`) and walking it, which has no test per element and
   keeps the base and length in registers. Trig owns that choice.
2. **Then the yield call:** with the test gone, `noalias` on `!@` lets
   LLVM hoist the base past the call (section 1), at no cost elsewhere
   (section 2). It waits on its own soundness round (the r3 brief, and
   FORMAL's stage 2).
