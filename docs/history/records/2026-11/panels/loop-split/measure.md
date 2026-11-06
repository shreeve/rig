# Loop split, lens: measurement. Does the Mac's gain reach Trig? (2026-11-05)

**Answer: no.** On the Mac (Apple M5, arm64), Trig built with the split runs 0.3-0.9% *more* cycles than base at one checker on all six projects, and 0.1-0.4% more instructions on five of them. The bench/tasks microbenchmark gain reproduces exactly (14-21% fewer cycles), so the build is right. The gain just isn't on Trig's hot path. It does not clear Trig's bar on either machine.

## What was built

| arm | Rig | how |
|---|---|---|
| base | `506a291a9` (main at #952, the merge base of `archive/loop-split` with origin/main, and the base of both pup records) | `tools/baseline` cache, already built (`.git/rig-baseline/506a291a9…/rig`) |
| split | `baab79318` (split2, the no-early-exit rule; `archive/loop-split` = `b26070087` adds only a record file on top) | `git archive` + `zig build` through `tools/heavy` |
| baseA | base's Trig binary, copied to another path | the A/A arm |

- **Trig:** `4aaedab`, the commit of the pup split2 record.
  - Trig origin/main (`6184626`) does not build with Rig `506a291a9`: `src/ast/ast.rig:78: unexpected name 'exact'` (it needs a newer Rig).
- **How Trig was built:** the release pack as `tests/lib.rip` builds it: `tools/trig/main.rig` beside links to `src/*`, then `tools/trig/gen-libtrees SRC rig build --release -o bin main.rig`.
  - There was no PGO: `tools/trig/pgo` is Linux-only.
  - Binaries: base 30,338,288 B, split 30,403,792 B (0.2% larger).
  - The split build emits 508 blocked ranges (`turnStop(` sites). 334 of them are in checker.zig, 37 in ast.zig, and 19 in transformers.zig.
- **Microbenchmarks:** origin/main's `bench/tasks/tasks.rig`, built `--release=fast` with each Rig.
- **Script:** `build-trig.sh`.

## Method

- **Projects:** the six projects were copied read-only from `~/Data/Code/trig/misc/projects`. Each ran `-p tsconfig.trig.json --noEmit` with `--singleThreaded` (one checker) or without it (tsc's default of 4 checkers).
- **Interleaving:** each round runs every project. The three arms run in a shuffled order for each project in each round.
- **Rounds:**
  - one checker: 30 rounds, run twice (13:08 and 13:10), 60 rounds in all;
  - all checkers: 20 rounds.
- **Counters:** `/usr/bin/time -l` gives usable counters on this macOS: `instructions retired`, `cycles elapsed` and `peak memory footprint`, summed over the whole process. xctrace was not needed. Wall time is a perf_counter around the process.
- **Priority:** everything ran through `tools/low`. `.mac-quiet` was absent.
- **Load:** the 1-minute load average was 4.2-5.7 during the Trig runs and 3.4-6.5 during the tasks runs. Two other sessions were building; the Mac has 10 cores (4 P and 6 E). Noise: in the A/A arm, the fastest wall differs by up to 3.1% and the minimum cycles by up to 2.4%. Instructions are stable to 0.03% at one checker.
- **Output:** for each project, stdout plus exit status had one digest across all three arms in all 900 runs. Exit status was 2 throughout, since the projects carry tsc diagnostics, as in the cli suite.

## Trig at one checker (60 interleaved rounds)

Pooled over both sessions. "Paired" means the median of the per-round ratio to base, the tightest estimate here.

| project | split: min instr vs base | split: paired cycles | A/A: paired cycles | split: paired wall | A/A: paired wall | peak footprint |
|---|---|---|---|---|---|---|
| mitt | 0.08% fewer | 0.34% more | 0.47% fewer | 0.87% slower | 0.20% slower | level |
| neverthrow | 0.15% more | 0.77% more | 0.46% fewer | 0.50% slower | 0.38% faster | level |
| tiny-invariant | 0.44% fewer | 0.27% more | 0.19% more | 0.33% slower | 0.35% slower | level |
| superstruct | 0.13% more | 0.86% more | 0.18% fewer | 0.40% slower | 0.74% faster | level |
| zod3 | 0.20% more | 0.66% more | 0.18% fewer | 0.58% slower | 0.30% faster | level |
| ts-pattern | 0.36% more | 0.82% more | level | 0.97% slower | 0.16% slower | level |

Absolute values for base:

| project | fastest wall | min cycles | instructions | peak footprint |
|---|---|---|---|---|
| mitt | 10.8 ms | 29M | 91M | 20 MiB |
| ts-pattern | 435-444 ms | 1,806-1,844M | 8,126M | 195 MiB |
| zod3 | 82 ms | 326M | 1,333M | 54 MiB |

- **Cycles:** every project shows more cycles with the split. Five of six also sit above the A/A arm's paired cycles. The A/A paired cycles span 0.47% fewer to 0.19% more; the split's span 0.27% to 0.86% more.
- **Instructions** have the same sign and roughly half the size of pup's record:
  - ts-pattern: 0.36% more on the Mac, 0.8% more on pup;
  - tiny-invariant: 0.44% fewer on the Mac, 0.4% fewer on pup.

## Trig at all checkers (default 4, 20 rounds)

- **Instructions:** between 0.40% fewer and 0.35% more.
- **Paired cycles:** between 0.3% fewer and 1.1% more. The A/A arm's span from 1.7% fewer to 0.2% more.
- **Wall:** wall times move by up to plus or minus 4% in both the split and A/A arms, so the noise swamps them.
- **Peak footprint** is within 1.3% (neverthrow 1.3% higher, superstruct 0.7% higher, others level or lower).
- Nothing here is a gain. Full table: `raw/paired.md`.

## bench/tasks on the same two Rigs (today, same machine state)

### The scale rows

Each row runs at `RIG_WORKERS=1` as `tasks scale NAME 1`, for 11 rounds, interleaved and shuffled, keeping the fastest. Cycles and instructions are for the whole process.

| bench | base cycles | split cycles | cycles | instructions | own-clock time |
|---|---|---|---|---|---|
| even-tasks | 930M | 740M | 20.4% fewer | 35.7% fewer | 20.7% faster |
| even-par | 892M | 708M | 20.6% fewer | 38.8% fewer | 20.8% faster |
| skew-tasks | 909M | 725M | 20.2% fewer | 36.2% fewer | 20.1% faster |
| skew-par | 879M | 696M | 20.9% fewer | 38.8% fewer | 21.2% faster |
| tree | 881M | 757M | 14.1% fewer | 33.1% fewer | 14.1% faster |
| alloc-tasks | 1143M | 1132M | 1.0% fewer | level | 1.5% faster |
| alloc-par | 1128M | 1136M | 0.8% more | level | 1.0% slower |

This matches #966's table almost to the megacycle (even-tasks 930M to 740M, there and here).

### The five timed benchmarks

These run at every worker. The figures are the fastest of 11 rounds, then of 15 more:

- **fanout:** 20% faster, then 19% faster (91.5 to 73.0 ms; 85.3 to 68.7 ms).
- **chain:** 4.5% faster in both sets.
- **yield:** level in both sets.
- **hog:** swung from 20% slower to 23% faster between the two sets.
- **spawn:** swung from 8% to 53% slower on the fastest run, with medians 2% slower.

hog and spawn are multi-worker latency rows on a loaded machine, and they are noise here. The PR's claims for them (hog 10% faster, spawn 7% faster) need a quiet Mac to confirm.

## Why the gain does not reach Trig

- **Where the gain is:** the microbenchmark gain comes from one shape, a long counted range whose body is a single arithmetic chain. There, the per-turn check makes LLVM add two adds to the chain (loop-disassembly.md).
- **What Trig's split ranges look like:** Trig's 508 split ranges are bodies that call, index and branch. Only their turn counter changes, and the ranges are short; the split2 record says the same about Trig's hot loops.
- **The net:** a block's start (`turnStop`: `turnsLeft`, a min against the count, a subtract) is paid once per range entry, and the per-turn decrement and test it removes were nearly free off the critical chain. On a short range that nets to slightly more work, which is what both machines show: about 0.2-0.4% more instructions and, on the Mac, about 0.3-0.9% more cycles.
- **arm64 is no exception:** the arm64-specific chain penalty does not appear in Trig's hot code, so arm64 brings no special gain here.

## Verdict against the bar

- The bar is: more than 1.5% faster, or at least 1% fewer instructions on one checker, with peak memory no higher.
- **On the Mac:** the best instruction delta is 0.44% fewer, on tiny-invariant. The wall and cycle deltas are 0.3-1.0% slower at one checker. Peak memory is level. **It fails the bar**, and the sign is the wrong one.
- **The open question for the owner** was whether an arm64-only gain counts. It is moot for Trig, because there is no arm64 gain on Trig. The gain is real for long counted arithmetic loops, which is bench/tasks' shape and not Trig's.

## What would change this

There is no design to pursue from this lens. A program dominated by long counted arithmetic ranges (numeric kernels, the par.map shape) would show the 14-21%. If the owner wants that, a narrower split could recover it:
- **The rule:** split only ranges whose body has no call that is not inlined and whose length is not known to be small.
- **Measuring it:** count, in the split build's emitted Zig, which of the 508 sites are on Trig's profile.

The first step would be a pup `perf` profile of split2 to find out whether any of those sites carry Trig's sample share at all. If none do, the narrower rule leaves Trig at base exactly and keeps the microbenchmark gain. That is a code-size and complexity question, not a speed one for Trig.

## Raw data

The raw data is in the panel's scratch folder (not kept)

| file | contents |
|---|---|
| `raw/trig1.csv`, `raw/trig1b.csv` | one checker. Columns: mode, round, project, arm, wall ms, cycles, instructions, max RSS, peak footprint, exit, output digest, load |
| `raw/trigN.csv` | all checkers, same columns |
| `raw/paired.md` | the paired and pooled tables |
| `raw/trig1.md` | the per-arm fastest-of table for the first session |
| `raw/tasks.csv`, `raw/tasks.md`, `raw/five.txt` | bench/tasks |
| `raw/*.load` | the load averages |
| scripts | `build-trig.sh`, `time-trig.py`, `time-tasks.py`, `summ.py`, `paired.py`, `summ-tasks.py` |
| builds | `trig-base`, `trig-split`, `tasks/tasks-{base,split}`, `split/bin/rig` |

## Follow-up: the ceiling of no yield checks on the Mac (owner-approved, 2026-11-05 evening)

This section asks whether porting signal preemption to the Mac would pay. It measures the ceiling: Trig with every yield check compiled out.

### The arm

- **nocheck:** Rig `506a291a9` exported to scratch (`nocheck/`), with one edit in `src/runtime.zig`:
  - `turn` (the per-loop check, line 433) and `tickCall` (the check at each function entry where a call cycle is cut, line 448) start with `if (true) return;`.
  - Every other check is kept: bounds, overflow and the rest.
  - In the built binary, `tickC` and `tickCallC` are gone: `nm` finds none, against four in base.
- **Trig:** `4aaedab`, the release pack built as before.
  - The binary is 29,877,152 B, 1.5% smaller than base's 30,338,288 B.
  - It contains 3,447 `rig.turn` sites and 392 `rig.tickCall` sites; the edit turns all of them into no-ops.
- **Other arms:** the base and A/A binaries are the same files as above.

### Machine state

- **The build:** the Mac slept (lid closed, battery at 2%) from 13:52 to 20:15, during the build.
- **The timing:** it ran 20:22-20:24, on AC power with Low Power Mode off and the battery charging.
- **Load:** 3.7-6.4.
- **Output:** every run printed identical output in all three arms; the digests match the earlier runs too.

### One checker (60 shuffled rounds; paired is the median of per-round ratios to base)

| project | nocheck: instructions | nocheck: paired cycles | A/A: paired cycles | nocheck: paired wall | A/A: paired wall | nocheck: pooled fastest wall | peak footprint |
|---|---|---|---|---|---|---|---|
| mitt | 2.17% fewer | 2.10% fewer | 0.56% fewer | 0.67% faster | 0.48% faster | 1.71% faster | level |
| neverthrow | 2.58% fewer | 2.45% fewer | 0.70% fewer | 0.74% faster | 0.54% faster | 2.12% faster | level (0.08%, as A/A) |
| tiny-invariant | 3.98% fewer | 2.64% fewer | 0.23% fewer | 2.50% faster | 0.31% faster | 0.41% faster | level |
| superstruct | 3.09% fewer | 1.92% fewer | 0.17% fewer | 1.08% faster | 0.38% faster | 0.63% faster | level |
| zod3 | 3.75% fewer | 2.07% fewer | 0.35% fewer | 1.78% faster | 0.29% faster | 1.11% faster | level |
| ts-pattern | 4.24% fewer | 2.43% fewer | 0.41% fewer | 1.77% faster | 0.39% faster | 2.23% faster | level |

- **Reading against the A/A arm:** the A/A arm drifts about 0.2-0.7% low in cycles. Measured against it, nocheck takes 1.5-2.4% fewer cycles.
- **Base's absolute values at one checker:**

| project | fastest wall | min cycles | instructions |
|---|---|---|---|
| ts-pattern | 422 ms | 1,793M | 8,125M |
| zod3 | 77.4 ms | 316M | 1,333M |

### All checkers (default 4, 20 rounds)

- **Instructions:** 2.5-4.3% fewer.
- **Paired cycles:** from 0.9% more (mitt) to 2.8% fewer (ts-pattern).
- **Paired wall:** ts-pattern 3.9% faster, the others 0.5-1.8% faster. The A/A arm's paired wall spans 0.9% faster to 2.2% slower.
- **Peak footprint:** level or lower (zod3 2.9% lower, ts-pattern 1.0% lower).

Raw data: `raw/nc1a.csv`, `raw/nc1b.csv`, `raw/ncN.csv` and `raw/nc-paired.md`.

### Against the bar

**The no-checks ceiling clears Trig's bar on arm64:**
- **Instructions:** at one checker, every project takes 2.2-4.2% fewer, against the 1% required.
- **Peak memory** is level.
- **Wall time:** taken alone, more than 1.5% faster holds only on ts-pattern, zod3 and tiny-invariant. Paired, those are 1.8%, 1.8% and 2.5% faster, over 60 interleaved rounds. The three small projects come in at 0.7-1.1% paired.

The size of the gain is close to what was recorded for pup (yield checks off, 0.6-3.6% faster).

This is a ceiling. Signal preemption keeps its own costs: the signal path, and `preempt_section`'s calls that are never inlined. So a port would bank only part of the ceiling's 1.5-2.5% in cycles. The pup preemption build, where it exists, measures what remains. The Mac port's worth is that share, and it needs that build ported before it can be measured.
