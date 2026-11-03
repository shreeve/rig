# Where Trig stands against tsrs after packed small objects (2026-11-02)

This repeats [tsrs-standing-7.md](tsrs-standing-7.md) on Trig main a4827df and Rig main 1a980833b. Since standing-7, Trig has merged trig#241 and #243–#248, and Rig has merged #873 (packed small objects). It also adds an arm for the id checks standing-7's Trig had. Measurement only; no code changed. Scripts and raw output are in [tsrs-standing-8-data/](tsrs-standing-8-data/).

**In one line:** Trig is still slower than shipped tsrs on every project at one checker, but the gap shrank by a third to a half:
- **ts-pattern:** 10.6% slower at one checker (standing-7: 16.7%) and 32.8% at four (44.5%).
- **zod3:** 31.8% (39.3%) and 42.9% (62.9%).
- **Small projects at one checker:** 5–31% slower. At four checkers Trig beats tsrs on mitt.
- Part of the change is the build, not the code. Standing-7's Trig was built with the id checks on (`CHECK_IDS`), which cost 0.4–5% (below). With them on, ts-pattern is 13.0% slower than shipped tsrs.

## Trig against tsrs

Trig main against tsrs 0.18.0 as shipped (`tsrs`) and in Go's mode (`tsrsg`, `--checkerAssignment go --noLazyMembers`), at the same thread count. Each cell is a median of wall time; the RSS column is Trig's peak RSS over shipped tsrs's.

| project | checkers | Trig | tsrs | tsrsg | against tsrs: standing-7 | against tsrs: now | against tsrsg: standing-7 | against tsrsg: now | Trig RSS over tsrs |
|---|---|---:|---:|---:|---|---|---|---|---|
| ts-pattern | 1 | 704.1 ms | 636.6 ms | 643.5 ms | 16.7% slower | **10.6% slower** | 14.7% slower | **9.4% slower** | 34.2% more |
| ts-pattern | 4 | 277.8 ms | 209.2 ms | 238.8 ms | 44.5% slower | **32.8% slower** | 26.2% slower | **16.3% slower** | 49.0% more |
| zod3 | 1 | 132.9 ms | 100.9 ms | 114.0 ms | 39.3% slower | **31.8% slower** | 23.7% slower | **16.6% slower** | 50.9% more |
| zod3 | 4 | 73.0 ms | 51.1 ms | 64.6 ms | 62.9% slower | **42.9% slower** | 27.8% slower | **13.0% slower** | 41.7% more |
| mitt | 1 | 16.3 ms | 15.1 ms | 15.0 ms | 18.4% slower | **7.6% slower** | 19.5% slower | **8.8% slower** | 47.6% more |
| mitt | 4 | 18.6 ms | 18.8 ms | 18.9 ms | 6.8% slower | **1.3% faster** | 7.9% slower | **2.0% faster** | 15.9% more |
| neverthrow | 1 | 18.7 ms | 16.2 ms | 16.3 ms | 24.6% slower | **15.4% slower** | 25.6% slower | **15.2% slower** | 46.3% more |
| neverthrow | 4 | 19.9 ms | 19.6 ms | 19.4 ms | 11.7% slower | **1.8% slower** | 10.6% slower | **2.7% slower** | 10.7% more |
| superstruct | 1 | 25.6 ms | 19.6 ms | 19.6 ms | 37.5% slower | **30.6% slower** | 38.1% slower | **30.7% slower** | 9.7% more |
| superstruct | 4 | 16.9 ms | 15.6 ms | 15.3 ms | 13.5% slower | **8.4% slower** | 16.0% slower | **10.4% slower** | 1.3% more |
| tiny-invariant | 1 | 56.5 ms | 53.7 ms | 49.6 ms | 12.8% slower | **5.1% slower** | 21.9% slower | **13.8% slower** | 18.7% more |
| tiny-invariant | 4 | 59.5 ms | 41.8 ms | 54.0 ms | 53.8% slower | **42.1% slower** | 18.2% slower | **10.2% slower** | 6.8% less |

- **User cycles.** Trig spends more user cycles than shipped tsrs on every large project: 6.9% more on ts-pattern and 28.6% on zod3 at one checker. On mitt and neverthrow at four checkers it spends 11–13% fewer, and on tiny-invariant at four 27% fewer. Tables for every arm are in [times-summary.md](tsrs-standing-8-data/times-summary.md).
- **tsrs held still.** The same tsrs binary measured within 1.6% of standing-7 on the large projects: ts-pattern 632.4 to 636.6 ms, zod3 99.3 to 100.9. So the ratios compare across the two runs.
- **Shipped tsrs against Go's mode** is as in standing-7. Shipped is 1.1% faster on ts-pattern at one thread and 12.4% at four; on zod3 it is 11.5% and 20.9% faster. Its peak RSS is 165.5 against 205.9 MiB on ts-pattern.
- **Peak memory.** On ts-pattern with the huge-page gate shut, Trig peaked at 222.1 MiB, against standing-7's 228.1. Trig is still 34–51% over shipped tsrs on the large projects. Against Go's mode it is 7.9% over on ts-pattern and 27.1% on zod3: most of the gap to shipped tsrs is tsrs's lazy member tables, which Trig does not have.

## The id checks (`CHECK_IDS`)

`src/checks/checks.rig` sets `CHECK_IDS = true` in the source. `tools/trig/pgo` (the benchmark's PGO build) sets it false in its own copy. Standing-7's `build.sh` copied the source as is, so standing-7's Trig ran with the id checks on. Here `trig` is built as `tools/trig/pgo` builds it, and `ids` is the same build with the checks on.

| project | checkers | ids against trig: wall | cycles | instructions |
|---|---|---|---|---|
| ts-pattern | 1 | 2.1% slower | 2.5% more | 4.5% more |
| ts-pattern | 4 | 4.0% slower | 2.6% more | 4.5% more |
| zod3 | 1 | 0.9% slower | 2.4% more | 5.1% more |
| zod3 | 4 | 1.7% slower | 2.4% more | 5.4% more |
| mitt, neverthrow | 1 and 4 | 0.4–0.8% slower | 0.1–1.8% more | 0.7–1.8% more |
| superstruct | 1 and 4 | 2.1% and 5.0% slower | 2.0–2.2% more | 3.6–4.1% more |
| tiny-invariant | 1 and 4 | 2.5% and 3.1% slower | 2.5–3.3% more | 5.0% more |

So like for like with standing-7's build (`ids`), Trig is 13.0% slower than shipped tsrs on ts-pattern at one checker and 38.1% at four. On zod3 it is 33.0% and 45.4%. Every later standing should build as `tools/trig/pgo` does.

## A/A

The copy against Trig main, wall median: within 1.2% at one checker on every project. At four checkers it is within 1.2% except ts-pattern (2.5%) and superstruct (3.4%; the fastest runs differ by 1.7% the other way). Those two are spreads of 15 and 60 rounds on four cores. Instructions are equal everywhere (0.1% on mitt at four), and cycles agree within 1.0%. Wall differences under these figures are noise.

## Method

- **Trig.** Main a4827df (after trig#241, #243–#248), PGO as `tools/trig/pgo` builds it:
  - `rig build --release --pgo`, trained by `tools/trig/bolt-train` on its own binary, with `CHECK_IDS = false` in its copy of `src/checks/checks.rig`;
  - `ids`: the same with `CHECK_IDS = true`, as standing-7 built it;
  - built side by side through `slot.sh` on the E-core release slots, [build2.sh](tsrs-standing-8-data/build2.sh).
- **Rig.** Main 1a980833b, which includes #873, built ReleaseSafe for this run in its own folder ([build.sh](tsrs-standing-8-data/build.sh); its Trig half was stopped and replaced by build2.sh).
- **A/A (`aa`).** A byte-identical copy of `trig`.
- **tsrs.** 0.18.0 from npm, the same binary as standing-5 to 7 (sha256 `d0bd720c20e99007`). It runs as shipped (`tsrs`) and in Go's mode (`tsrsg`), both with `RAYON_NUM_THREADS` set to the thread count. Hashes are in [shas.txt](tsrs-standing-8-data/shas.txt).
- **Timing.** `/zfs/trig-pup/trial/time-ab.sh` with [s8.conf](tsrs-standing-8-data/s8.conf), on 2026-11-02:
  - ten arms: each of the five at one checker (P-core 6) and at four (P-cores 0, 6, 8 and 10);
  - shuffled rounds, a warm-up per round, perf pinned and unscaled, binaries copied to tmpfs, as standing-7.
  - The owner's rule is that no check runs over ten minutes, so the run was split into two timing slots, each under a hard 9.5-minute cap ([slot.sh](tsrs-standing-8-data/slot.sh)):
    - 15 rounds of the large projects, 20:47–20:50;
    - 60 rounds of the small ones, 20:50–20:53.
    - Standing-7 ran 20 rounds of the large projects; this run's spreads are in the A/A section.
  - Load was 1.4 to 2.3.
- **Outputs.** Every arm printed tsc's stdout and exit status (2) on every project, against tsc at Trig's pin 655f0268 ([tsc-check.sh](tsrs-standing-8-data/tsc-check.sh), [tsc-check.txt](tsrs-standing-8-data/tsc-check.txt)). All 2,250 timed runs matched their arm's first output.
- **Huge pages.** Medians by gate state are in [gate-summary-large.md](tsrs-standing-8-data/gate-summary-large.md) and [gate-summary-small.md](tsrs-standing-8-data/gate-summary-small.md).
  - The free count before the large slot was 15 2 MiB blocks after compaction, and 187 before the small one.
  - The gate was open in most runs of the small projects and of zod3, and in about half of ts-pattern's.
  - Trig's RSS above is the median of each cell's majority gate state, as in standing-7.
- **Tables.** [analyze.py](tsrs-standing-8-data/analyze.py) over [times-large.txt](tsrs-standing-8-data/times-large.txt) and [times-small.txt](tsrs-standing-8-data/times-small.txt) gives [times-summary.md](tsrs-standing-8-data/times-summary.md).
