# Yield checks in scan loops bounded by their input (2026-10-31)

Queue row 36, beat-tsrs item 14. This is a record and a recommendation.
No compiler change was built.

**The question.** Rig - Rust's profile of Trig's lexer put about 1.9% of
the lexer's samples in the yield countdown inside tiny std scan loops,
such as `text.class_end` and `text.find_any`. A typical scan is a
`while i < s.len` loop over a slice that cannot grow in the loop, whose
body makes no call that could block or loop on its own. Is a loop
bounded by its input's length in this way a sound case to leave the
check out of?

**The answer.** The one form that keeps the scheduler's guarantee is a
loss. The form that gains changes the guarantee, and it gains only on
the two smallest projects.

- **The sound form, a loop copy chosen at entry ("ver"), is a loss**
  (section 2). A scan whose remaining length is under the count left
  runs a copy with no check; any other scan runs as now. This keeps
  today's behavior exactly. On pup's P-cores it takes 0.04-0.71% more
  instructions than main on every project. Its wall time is 0.5-1.9%
  slower on three projects and 2.7% faster on zod3, with 0.19% more
  instructions there. Its .text is 0.08% larger. On the Mac it also
  takes more instructions on three of four projects. Not recommended.
- **Skipping the check outright ("std") clears the instruction bar
  only on the empty project and mitt** (section 3). It saves 1.77% and
  1.19% of instructions there on pup, with peak RSS 0.1 MB higher and
  wall time within the noise (0.8% faster, 0.9% slower). On ts-pattern
  and zod3 it saves 0.04% and 0.31%. It holds a task's worker for a
  time that grows with the input, so it gives up a guarantee: the
  owner's call (section 4).
- **The scans' checks almost never fire.** Each call of `class_end` or
  `find_any` starts its own count at 1,024, and a token's scan is a few
  bytes long. What a check costs is a decrement and a branch per byte.
  An entry test costs about as much per call as those checks cost over
  a short scan.

## 1. Method

- **Rig** at main 95fffb6cf (worktree `scan-yield`). **Trig** at
  baae9fe, checked and emitted by that `bin/rig` as `rig build
  --release` does, with a stand-in `zig` that records its arguments
  (as trig-zig-ceiling's `emit.sh`). The emitted tree is `src/`, with
  `tools/trig/main.rig` as `src/main.rig`.
- **The arms.** Each arm is a plain build of its own copy of the emitted
  package, with `zig build-exe -Osafe -fomit-frame-pointer` as `rig
  build --release` runs it. No arm switches at run time. Taking a
  check out turns `rig.turn(&n)` into `rig.noTurn(&n)`, an inline
  function that does nothing.

| Arm | What changes from main's emit |
|---|---|
| base | nothing |
| std | the 47 covered checks in std's modules are taken out (`bigint` 15, `text` 12, `json` 10, `utf8` 7, `utf16` 3) |
| ver | the 44 outermost of those loops are each written twice, the copy chosen as the loop starts (section 2) |
| all | the 761 covered checks in all of Trig's modules and std's are taken out (Mac only) |
| none | every loop check is taken out; the checks at function entry stay (Mac only; sched-check's ceiling) |

- **Which checks a rule would cover** is decided by `classify.py`, a
  deliberately generous stand-in for the compiler's rule. A loop is
  covered when two things hold:
  - Its turns are bounded by a length fixed at entry. That is a Zig
    `for` (which reads its slice's length once), a range whose end is
    `rig.lenOf(x)`, or a `while` whose condition compares with
    `rig.lenOf(x)` and whose body does not assign `x`.
  - Each turn does constant work. Every call it makes, followed through
    the callee, reaches no uncovered loop, no cycle of calls, no
    scheduler call, and no Zig std call outside a short list of
    constant-time ones.

  A method call counts as covered when any function of its name is, so
  "all" covers more than a real rule could. The stand-in does not ask
  that the index rise on every turn, which section 4 needs.
- **Mac:** Apple M5, shared with other sessions, `.mac-quiet` absent.
  Builds ran through `tools/heavy` and runs through `tools/low`. Each
  run kept 30 rounds, under `LOAD_MAX=5`. The arms were interleaved,
  their order reversed each round, with one checker
  (`--singleThreaded`). The projects were the empty project (`export
  {}` with the tsconfig of pup's `/zfs/trig-cache/fe-proj/empty`),
  mitt, ts-pattern and zod3. Instructions retired and cycles come from
  `/usr/bin/time -l`.
- **pup:** the same packages were built on pup through slot.sh on the
  E-cores. Runs were rotated each round (`ecount.sh`), with user cycles
  and instructions from `perf stat`:
  - 10 rounds on E-core 19;
  - then 20 rounds on P-core 3 with its sibling 4 idle, in Swiss's
    slot (01:51-01:53, with builds paused).
- **Outputs.** In every arm and on both machines, each run's output and
  exit status matched the first run's, byte for byte.

## 2. The sound form: a loop copy chosen at entry

**What it is.** For each covered loop in std, outermost first,
`version.py` writes:

```zig
if (B < __rig_turns_N) { __rig_turns_N -= B; <the loop, no checks> }
else { <the loop as main emits it> }
```

B bounds the loop's turns from its length:
- a walk's slice length;
- a range's end less its start;
- a `while`'s `rig.lenOf(x)` less the index it compares.

The count starts at 1,024 when the loop is entered, so a short scan
takes the copy, and its count could never have reached zero there. In
a loop nested inside another, the remainder of the shared count
decides, and the copy charges its turns ahead. This is today's behavior
exactly, not just within the guarantee. The hand version leaves out the
turns of a compile-time loop nested in the scan (`find_any`'s tail), so
it measures what the test and the copy cost, not the exact threshold.

**What it costs.** pup P-core 3, 20 rounds (`data/pup-p3.md`):

| Project | Wall (median) | Instructions (min) | Cycles (median) | Peak RSS (median) |
|---|---|---|---|---|
| empty | 1.85% slower | 0.36% more | 2.23% more | 29.9 against 28.1 MB |
| mitt | 1.12% slower | 0.71% more | 1.19% more | 32.6 against 30.6 MB |
| ts-pattern | 0.47% slower | 0.04% more | 0.38% more | 248.2 against 245.8 MB |
| zod3 | 2.71% faster | 0.19% more | 0.80% fewer | 78.7 against 76.3 MB |

- **pup E-core 19, 10 rounds** (`data/pup-e3.md`): 0.02% to 0.78% more
  instructions on every project.
- **Mac, 30 rounds** (`data/mac-ver.md`): 0.40% more instructions on
  empty, 0.33% more on mitt, 0.14% fewer on ts-pattern and 0.09% more
  on zod3, with cycles level.
- **Binary size.**
  - pup: .text 11,280,825 bytes against 11,271,801 (9.0 KB, 0.08%
    larger); the file 125.74 MB against 125.67 MB (0.06%).
  - Mac: .text 6.7 KB (0.07%) larger.
- **Peak RSS.** ver's peak RSS on pup is 1.8-2.4 MB higher on every
  project. That is far more than its 9 KB of code, and its segments are
  laid out as base's are. It was not traced. ver loses on instructions
  regardless.

**Why it loses.** Most of these loops run a few turns per call. For a
`class_end` over an identifier, the test, the subtraction and the
second copy's layout cost about what the per-byte decrements did. PR
#782 found the same for ranges and walks: short loops counted ahead
with each turn of a long one counted made ts-pattern 0.9% slower.

## 3. The ceiling: no check at all in the covered loops

**pup P-core 3, 20 rounds** (`data/pup-p3.md`), std against base:

| Project | Wall (median) | Instructions (min) | Cycles (median) | Peak RSS (median) |
|---|---|---|---|---|
| empty | 0.81% faster | 1.77% fewer | 1.05% fewer | 28.2 against 28.1 MB |
| mitt | 0.88% slower | 1.19% fewer | 0.20% more | 30.7 against 30.6 MB |
| ts-pattern | 0.21% faster | 0.04% fewer | 0.44% fewer | 245.7 against 245.8 MB |
| zod3 | 3.35% faster | 0.31% fewer | 1.92% fewer | 76.3 MB both |

zod3's wall and cycles move far more than its instructions do. That
reads as code layout or noise, not the checks. pup E-core 19 agrees:
1.35% and 1.22% fewer instructions on empty and mitt, and 0.04% and
0.21% fewer on the large two.

**Mac, 30 rounds** (`data/mac-30.md`): instructions are the minimum,
cycles the median.

| Project | std | all | none |
|---|---|---|---|
| empty | 0.85% fewer instructions, 0.33% more cycles | 1.05% fewer, 0.45% fewer | 2.56% fewer, 1.52% fewer |
| mitt | 0.72% fewer, 0.57% more | 1.19% fewer, 0.48% more | 2.56% fewer, 1.68% fewer |
| ts-pattern | 0.04% fewer, 0.84% more | 0.60% fewer, 0.25% more | 2.57% fewer, 0.57% fewer |
| zod3 | 0.14% fewer, 0.07% fewer | 0.65% fewer, 0.03% more | 2.16% fewer, 0.31% fewer |

Wall time on the shared Mac moved by up to 8% between arms whose cycles
were level, so cycles are the measure there.

Three findings:

- **std's scans are most of the small projects' share and none of the
  large projects'.** The empty project and mitt spend most of their run
  lexing the default library's declarations. There, std's 47 checks are
  about a third of what all loop checks cost on the Mac (0.7-0.9% of
  2.6%; "none" was not built on pup). ts-pattern
  and zod3 check far more than they lex, and there the scans cost
  nothing measurable.
- **Saved instructions barely become cycles.** The count's decrement
  and branch fuse and predict, as sched-check section 1 found. Even
  "none", with every loop check gone, saves only 0.3-1.7% of cycles on
  the Mac.
- **The loops over a compile-time set already cost nothing.** `set16`
  and `set64` loop over `set`, a compile-time String, with a check per
  element and a count of their own. LLVM folds those checks away, since
  the count starts at 1,024 and the loop runs a known number of turns.
  Base's `find_any` instances keep only the outer step's one decrement
  per 16 bytes (disassembly of `find_any__func_883`).

## 4. What skipping the check outright gives up

**The guarantee today.** scheduler.md, "Yield checks": each outermost
loop of a function keeps a count that starts at 1,024 when the loop is
entered, and the loops inside it count it down too. So between two
checks a task runs at most:
- 1,024 turns of one loop nest;
- in each turn, at most one chain of calls that repeats no function;
- in each function of that chain, up to 1,023 turns of its own loops,
  since a function's count starts afresh on every call.

The work between two checks is therefore bounded by the program's text,
never by its input. That bound is why a task queued behind a busy loop
waits under 0.1 ms (`bench/tasks` `hog`). It is also why a busy worker
still fires its timers and polls its descriptors (`sched.serviceBusy`).

**What the rule as asked changes.** A loop bounded by `s.len` runs as
many turns as its input has bytes. Trig reads source files of any size.
A generated or minified JavaScript file of 50 MB, or a long base64
string inside one, is ordinary input. With no check:
- `class_end` over such a run, at about a byte a cycle, holds its
  worker for tens of milliseconds;
- so does `find_any` hunting a closing quote, at 16 bytes a turn.

For that long:
- the task queued behind it waits;
- a timer on that worker fires late (a 10 ms sleep);
- a socket registered with that worker waits.

So the bound between checks becomes the input's length, not the
program's text. Memory safety is untouched: the North Star's second
rule holds. The guarantee in scheduler.md would have to say "except in
a loop bounded by a length, whose turns do constant work", and
`hog`'s bound would hold only for inputs under about a kilobyte per
scan.

**Ctrl-C and cancellation.**
- **Cancellation is unchanged.** A check never delivers a cancel: a
  cancel lands at a fallible waiting point or at `task.check()!`, and a
  scan has neither. A canceled task finishes its scan today too.
- **Ctrl-C can wait for a scan to end.** An interrupt is delivered by
  whichever worker next services its poller (`sched.deliverInterrupt`),
  awake or woken by the handler's kick. A busy worker does that only at
  a loop's check. So with every worker inside an unchecked scan, Ctrl-C
  would wait for the first scan to end: the same input-sized delay. A
  second Ctrl-C still ends the process at once.
- **Deterministic runs** would offer the seed fewer yield points and
  move the virtual clock less. That changes which schedules a seed
  picks but no result, since a scan reads only a view no other task can
  write.

**What it would buy.** 1.77% and 1.19% fewer instructions on the empty
project and mitt, with no measured wall gain, and nothing on ts-pattern
or zod3.

**A sound form that keeps this gain does not exist among those
measured.**
- The entry copy (section 2) loses.
- Strips (PR #782) made ts-pattern 2.6% slower.
- A bound known at compile time keeps the guarantee, but LLVM already
  folds those checks (section 3), and sched-check section 6 found only
  about 1% of Trig's loops have a constant end.

## 5. If it were built: deciding it once

Either form would be one fact per loop. The pass that sees the loop's
shape and its calls' effects would make it and record it for emit, as
#782's `storage.LoopTurns` (`loop_turns`) did. The fact needs:
- **a shape from a positive list:**
  - a `while` whose condition's first conjunct is `i < s.len` or
    `i + k <= s.len`, where `i` is a local the loop writes only by
    `i += c` with `c >= 1` a constant, and `s` is a place the loop
    does not write;
  - a walk;
  - a range ending at a length;
- **a body whose calls are known not to wait, loop or recurse** (the
  inlining pass's call graph already finds cycles);
- **the bound**, for the entry copy.

Emit would read `loop_turns` and write either the copy or a loop with
no check. It would decide nothing. The ownership checker and the oracle
are not involved, since no check moves, lends or drops anything.

## Recommendation

**Keep the checks in scan loops, and close row 36 with this record.**
The sound form (ver) is a loss on every project on pup. The gain left
(std, 1.2-1.8% of the smallest projects' instructions and no wall time)
comes only from giving up the bound on the work between checks, and is
not worth that.

## Decisions for the owner

1. **Close row 36 and beat-tsrs item 14 with this record.** Default:
   yes.
2. **Keep the work between two checks bounded by the program, not by
   its input; no exemption for loops bounded by a length (section 4).**
   Default: yes.

## Files

Kept in `scan-yield-data/`:

- `classify.py`: the rule's stand-in. With `--apply std|all` it writes
  the arm.
- `version.py`: writes the "ver" arm.
- `classify-summary.txt`: the stand-in's counts, the reasons the other
  checks are not covered, and every covered std site.
- `mk-mac.sh`, `mk.sh`, `builds.txt`: the builds on the Mac and on pup,
  and their times.
- `time-mac.py`, `mac-30.md`, `mac-ver.md`: the Mac harness and its two
  summaries.
- `ecount.sh`, `summ-pup.py`, `pup-e3.md`, `pup-p3.md`: the pup harness,
  its summarizer, and the E-core and P-core summaries.

The emitted packages, the binaries and the raw runs are in the owner's
session folder: `~/Data/Code/Claude/rig/rig/scan-yield-study/` on the
Mac and `/zfs/worktrees/rig/scan-yield-study/` on pup.
