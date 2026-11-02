# Where Trig stands against tsrs, by the shuffled harness (2026-11-02)

This repeats [tsrs-standing-6.md](tsrs-standing-6.md)'s measurement with three changes. It runs on the shuffled harness ([../timing-audit/harness.md](../timing-audit/harness.md)). It times tsrs in both of its modes. And it adds a Trig that loads tsrs's lib files, for a like-for-like line. Measurement only; no code changed. Scripts and raw output are in [tsrs-standing-7-data/](tsrs-standing-7-data/).

**In one line:** Trig is slower than tsrs on every project, in either tsrs mode and at either checker count.
- Against Go's mode (standing-6's bar): 15–38% slower at one checker, 8–28% at four.
- Against tsrs as shipped: 13–39% slower at one checker, 7–63% at four. Shipped tsrs is faster than Go's mode on the large projects, most of all at four threads, and uses less memory.
- Trig's three extra lib files cost 2% or less, except 2.7% on superstruct at one checker. Without them ts-pattern at four is 8.0% slower, because the checker split changes.

## Trig against tsrs

Trig main against tsrs 0.18.0 as shipped (`tsrs`) and in Go's mode (`tsrsg`, `--checkerAssignment go --noLazyMembers`), at the same thread count. Each cell is a median: wall time, user cycles and peak RSS. All of Trig's peak RSS figures come from runs with the huge-page gate shut. That is every run on the 25 ms projects and 11 to 19 of 20 on the others ([below](#huge-pages)). tsrs's figures cover all its runs.

| project | checkers | Trig | tsrs | tsrsg | Trig against tsrs: wall, cycles, RSS | Trig against tsrsg: wall, cycles, RSS |
|---|---|---:|---:|---:|---|---|
| ts-pattern | 1 | 737.9 ms | 632.4 ms | 643.3 ms | 16.7% slower, 13.1% more, 37.8% more | 14.7% slower, 12.0% more, 10.8% more |
| ts-pattern | 4 | 300.1 ms | 207.6 ms | 237.7 ms | 44.5% slower, 13.6% more, 39.2% more | 26.2% slower, 12.3% more, 11.2% more |
| zod3 | 1 | 138.4 ms | 99.3 ms | 111.9 ms | 39.3% slower, 36.1% more, 53.7% more | 23.7% slower, 20.8% more, 29.4% more |
| zod3 | 4 | 82.1 ms | 50.4 ms | 64.2 ms | 62.9% slower, 34.0% more, 44.1% more | 27.8% slower, 17.8% more, 21.5% more |
| mitt | 1 | 17.4 ms | 14.7 ms | 14.5 ms | 18.4% slower, 15.7% more, 60.7% more | 19.5% slower, 15.7% more, 56.4% more |
| mitt | 4 | 20.1 ms | 18.8 ms | 18.7 ms | 6.8% slower, 13.2% fewer, 22.7% more | 7.9% slower, 12.5% fewer, 24.6% more |
| neverthrow | 1 | 19.7 ms | 15.8 ms | 15.7 ms | 24.6% slower, 21.1% more, 60.2% more | 25.6% slower, 21.3% more, 57.8% more |
| neverthrow | 4 | 21.6 ms | 19.3 ms | 19.5 ms | 11.7% slower, 5.5% fewer, 20.5% more | 10.6% slower, 5.1% fewer, 20.4% more |
| superstruct | 1 | 26.3 ms | 19.1 ms | 19.0 ms | 37.5% slower, 45.9% more, 10.8% more | 38.1% slower, 46.7% more, 9.5% more |
| superstruct | 4 | 17.5 ms | 15.4 ms | 15.1 ms | 13.5% slower, 40.9% more, 0.8% more | 16.0% slower, 38.5% more, 1.3% more |
| tiny-invariant | 1 | 60.0 ms | 53.2 ms | 49.3 ms | 12.8% slower, 13.4% more, 26.5% more | 21.9% slower, 23.9% more, 28.2% more |
| tiny-invariant | 4 | 62.9 ms | 40.9 ms | 53.2 ms | 53.8% slower, 21.2% fewer, 3.3% less | 18.2% slower, 25.5% more, 29.6% more |

- **Shipped tsrs against Go's mode.**
  - Shipped tsrs is faster on ts-pattern (1.7% at one thread, 12.7% at four) and zod3 (11.3% and 21.5%).
  - On tiny-invariant it is 7.9% slower at one thread but 23% faster at four, where it spends 59% more user cycles.
  - On the 25 ms projects the two modes measure the same within 2%.
  - Shipped tsrs holds less memory: 165.5 against 205.9 MiB on ts-pattern at one thread, and 48.0 against 57.1 MiB on zod3.
  - So the bar Trig is measured against moves most at four threads on the large projects. There Trig is 26–28% behind Go's mode and 45–63% behind shipped tsrs.
- **Small projects at four.** Trig spends fewer user cycles than tsrs on mitt and neverthrow, but its wall time is longer. On superstruct, Trig's peak RSS at four matches tsrs's.
- **Trig at four against tsrs on one thread:** Trig takes 52.5% less time on ts-pattern and 17.3% less on zod3 than shipped tsrs at one thread.

## Like for like: Trig without the three lib files

Trig's `lib.esnext.d.ts` references three files that tsrs 0.18.0's lacks: `esnext.iterator`, `esnext.modulesource` and `esnext.promise`. `nolib` is Trig main built without those references, so it loads tsrs's 92 lib files. Trig main loads 95.

| project | checkers | nolib | against Trig main: wall, cycles | against tsrsg: wall | against tsrs: wall |
|---|---|---:|---|---|---|
| ts-pattern | 1 | 734.8 ms | 0.4% faster, 0.4% fewer | 14.2% slower | 16.2% slower |
| ts-pattern | 4 | 324.2 ms | 8.0% slower, 0.8% more | 36.4% slower | 56.1% slower |
| zod3 | 1 | 138.7 ms | 0.2% slower, 0.4% more | 24.0% slower | 39.6% slower |
| zod3 | 4 | 80.6 ms | 1.8% faster, 0.3% more | 25.5% slower | 59.9% slower |
| mitt | 1 | 17.4 ms | 0.4% slower, 0.5% more | 20.0% slower | 18.8% slower |
| mitt | 4 | 20.4 ms | 1.2% slower, 0.9% more | 9.1% slower | 8.1% slower |
| neverthrow | 1 | 19.7 ms | the same, 0.3% more | 25.6% slower | 24.6% slower |
| neverthrow | 4 | 21.6 ms | 0.2% faster, 0.9% more | 10.4% slower | 11.5% slower |
| superstruct | 1 | 25.6 ms | 2.7% faster, 2.1% fewer | 34.4% slower | 33.8% slower |
| superstruct | 4 | 17.9 ms | 2.0% slower, 0.6% fewer | 18.3% slower | 15.8% slower |
| tiny-invariant | 1 | 59.9 ms | 0.2% faster, 1.3% fewer | 21.6% slower | 12.5% slower |
| tiny-invariant | 4 | 62.9 ms | the same, 0.3% fewer | 18.2% slower | 53.8% slower |

- **The three files cost little.** Every wall difference is 2% or less, except two:
  - superstruct at one checker, where `nolib` is 2.7% faster with 2.2% fewer instructions (225.4 against 230.5M);
  - ts-pattern at four.
  - Two of the small differences are above their A/A spread: zod3 at four (1.8% faster) and superstruct at four (2.0% slower). Neither has a matching change in cycles.
  - Peak RSS moves by about 1% or less, mostly lower.
- **ts-pattern at four is 8.0% slower without them, on the same work.** Its user cycles are within 0.8% of Trig main's. Go's split weighs every file, lib files included, so removing three moves the source files to other checkers. Here the move made the longest checker longer. The study of ts-pattern's checker 0 found the same effect against tsrs: given Trig's split, tsrs made Trig's calls to within 1%. So at four checkers, "the same libs" is not "the same split". Trig main's split is the better one here.
- **Like for like, against Go's mode,** Trig is 14–34% slower at one checker and 9–36% at four.

## Since standing-6

Standing-6's tsrs was Go's mode, so these ratios compare Trig with `tsrsg`. Both standings use wall medians at the same thread count.

| project | 1 checker: standing-6 | 1 checker: standing-7 | 4 checkers: standing-6 | 4 checkers: standing-7 |
|---|---|---|---|---|
| ts-pattern | 13.5% slower | 14.7% slower | 28.2% slower | 26.2% slower |
| zod3 | 25.0% slower | 23.7% slower | 43.3% slower | 27.8% slower |
| mitt | 22.4% slower | 19.5% slower | 32.3% slower | 7.9% slower |
| neverthrow | 28.1% slower | 25.6% slower | 20.4% slower | 10.6% slower |
| superstruct | 35.4% slower | 38.1% slower | 37.0% slower | 16.0% slower |
| tiny-invariant | 25.6% slower | 21.9% slower | 23.1% slower | 18.2% slower |

- **Only ratios compare across the two runs.** The same tsrs binary ran 5.6% faster on ts-pattern (681.2 to 643.3 ms) and 22% faster on mitt (18.7 to 14.5 ms) than in standing-6. That gain comes from the harness and the machine, not the code:
  - perf now runs pinned to the arm's cores, unscaled;
  - each round warms the cores first;
  - load was 0.2 to 0.7, against 2.4 to 6.5;
  - the runs waited for quiet cores twice, against 24 times.
  - Standing-6's one-checker numbers on the small projects were also biased against Trig by its place in each round (the harness record).
- **At four checkers, Trig closed most of the gap.** This is trig#232 (the checkers made and the bundled libs parsed in tasks) and trig#239 (each file bound in a task):
  - on zod3, from 43% to 28% slower;
  - on mitt, from 32% to 8%;
  - on superstruct, from 37% to 16%;
  - on neverthrow, from 20% to 11%.
- **At one checker, the ratios moved by 4 points or less, either way.** User cycles against tsrsg:
  - ts-pattern 11.9% more then, 12.0% more now;
  - zod3 22.6% and 20.8%;
  - tiny-invariant 25.7% and 23.9%.
  - The small projects' cycles moved more (mitt 30.4% to 15.7% more, neverthrow 30.6% to 21.3%). That comes from trig#238 (a release build ends after its output) and from perf now counting unscaled on the arm's own core (row 49). This run does not separate the two.
- **Trig's peak memory fell, gate shut against standing-6's low mode:**
  - ts-pattern 248.3 to 228.1 MiB at one checker (8.1% less) and 278.8 to 257.4 at four (7.7% less);
  - zod3 77.3 to 73.8 MiB (4.5% less) and 114.3 to 107.9 (5.6% less).
  - The binaries now run from tmpfs, against ZFS in standing-6. The same tsrs binary *rose* 2.0% on ts-pattern and 6.3% on zod3 under that change, so Trig's drop is not the file system's. This run does not say which change made it. The candidates are trig#233 (rarely set Table fields in side tables), trig#235, and Rig's changes since `928b44bf2`.

## Huge pages

The harness logs, for each run:
- the free 2 MiB blocks just before it starts (the gate is open above 64);
- the huge pages faulted in while it runs.

Medians by project, arm and gate are in [gate-summary-large.md](tsrs-standing-7-data/gate-summary-large.md) and [gate-summary-small.md](tsrs-standing-7-data/gate-summary-small.md).
- **The 25 ms projects** ran with the gate shut in all 1,800 runs.
- **On the others** the free count sat at 46–71, at the gate's edge, so "open" before a run often meant shut by the time a Table asked.
  - ts-pattern at one checker: Trig main's 8 open runs faulted 22 huge pages, as its shut runs did, and peaked at the same 228.1 MiB.
  - Only two cells show the high mode. Trig at four peaked at 280.7 MiB in its 9 open runs (50 huge pages), against 257.4 shut. `nolib` at one checker peaked at 237.8 MiB in 8 open runs, against 228.0.
  - zod3 and tiny-invariant show no difference between the two gate states.
- **So this standing's Trig memory is effectively the 4 KiB-page mode throughout,** and it compares with standing-6's low mode.

## A/A

The copy against Trig main, wall median: 0.1–0.9% on ts-pattern and zod3, up to 1.5% on the 25 ms projects (60 rounds), and 0.9% on tiny-invariant. Instructions are equal in every cell, and user cycles agree within 1.4%, except superstruct at four (2.6%). Differences under these figures are noise ([times-summary.md](tsrs-standing-7-data/times-summary.md), "A/A").

## Method

- **Trig.** Main `07e4447` (#240, parse pass 3; trig#241 was still open), PGO as standing-6:
  - `rig build --release --pgo`, trained by `tools/trig/bolt-train` on its own binary, through `slot.sh` on the E-core slots ([build.sh](tsrs-standing-7-data/build.sh));
  - Rig is the full suite's ReleaseSafe build of `e10087dd8`, whose sources match Rig main `5e2dd0d7a`'s (#866 changed records only);
  - sha256 `25b1a5c4ce1bcf11`; commits and hashes in [shas.txt](tsrs-standing-7-data/shas.txt), Trig's log in [trig-log.txt](tsrs-standing-7-data/trig-log.txt).
- **Trig without three lib files (`nolib`).** The same source and build, with the three references deleted from the embedded `lib.esnext.d.ts` (`src/bundled/embed_generated.rig`), as the lib3 comparison of 2026-11-01 did. It has its own PGO profile. sha256 `065748a90da1ffd6`.
  - On zod3, `--listFiles` shows 95 lib files for Trig main and 92 for `nolib`, the same 92 by name as tsrs's.
- **A/A (`aa`).** A byte-identical copy of Trig main's binary.
- **tsrs.** 0.18.0, `@tsrs/linux-x64-gnu@0.18.0-ts7.1.0-dev.20260929` from npm. The tarball's sha1 matches the registry's `67d15cd0`. Binary sha256 `d0bd720c20e99007`, as in standing-5 and 6. Its lib files sit beside it.
  - `tsrs`, as shipped: its default checker assignment and lazy members.
  - `tsrsg`, Go's mode: `--checkerAssignment go --noLazyMembers`, standing-6's flags.
  - Both with `RAYON_NUM_THREADS` set to the thread count.
- **Timing.** `/zfs/trig-pup/trial/time-ab.sh` with [s7.conf](tsrs-standing-7-data/s7.conf), run by [run.sh](tsrs-standing-7-data/run.sh), on 2026-11-02 00:18–00:30:
  - ten arms: each of the five at one checker (`--singleThreaded`, P-core 6) and at four (`--checkers 4`, P-cores 0, 6, 8 and 10, siblings idle);
  - each round waits for quiet cores and no Trig suite, runs a discarded warm-up on both core groups, then runs every arm once in a seeded shuffle;
  - 60 rounds on mitt, neverthrow and superstruct; 20 on ts-pattern, zod3 and tiny-invariant;
  - perf pinned to the arm's cores, `--no-scale`; every binary on tmpfs (`/tmp/s7`).
  - A first start was stopped after nine mitt rounds. The config's variable `g` (Go's flags) clashed with the `g` time-ab.sh sets to each run's gate, so `tsrsg` ran with a stray argument and failed. The variable was renamed to `GO` and the run started again from the beginning. A config for time-ab.sh must not use `e`, `f`, `g`, `h`, `t0` or `t1`.
- **Outputs.** Every arm printed tsc's stdout and exit status (2) on every project, against tsc at Trig's pin `655f0268` ([tsc-check.sh](tsrs-standing-7-data/tsc-check.sh), [tsc-check.txt](tsrs-standing-7-data/tsc-check.txt)). All 2,400 timed runs matched their arm's first output.
- **Tables.** [analyze.py](tsrs-standing-7-data/analyze.py) over [times-large.txt](tsrs-standing-7-data/times-large.txt) and [times-small.txt](tsrs-standing-7-data/times-small.txt); [times-summary.md](tsrs-standing-7-data/times-summary.md) has every arm.
