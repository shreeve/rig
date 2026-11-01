# Where Trig stands against tsrs, with the lexer and the parser (2026-11-01)

The owner asked where Trig stands now. This is [tsrs-standing-5.md](tsrs-standing-5.md)'s measurement again, run after Trig's lexer (#230) and parser (#231) were shaped as tsrs's and after Rig's pool-yield (#819) and table address space (#832). Measurement only; no code changed. Scripts and raw output are in [tsrs-standing-6-data/](tsrs-standing-6-data/).

**In one line:** at the same thread count, Trig is slower than tsrs on every project: 12–35% at one checker and 20–43% at four. The small projects gained 2–8% since standing-5. ts-pattern did not move once runs are compared by huge-page mode, and that mode, not the code, moved Trig's peak memory.

## Method

As standing-5's, with these differences:
- **Trig.** Main `806e0a1` (the lexer and the parser) with PGO, built by Rig main `928b44bf2`:
  - `rig build --release --pgo`, trained by `tools/trig/bolt-train`;
  - through `slot.sh` on the E-core slots;
  - sha256 `2418210814619e09`;
  - [build.sh](tsrs-standing-6-data/build.sh) and [build-trig.sh](tsrs-standing-6-data/build-trig.sh), commits in [shas.txt](tsrs-standing-6-data/shas.txt).
- **tsrs.** Shipped 0.18.0 (sha256 `d0bd720c20e99007`), as standing-5.
- **Timing.** [time.sh](tsrs-standing-6-data/time.sh), 20 rotated rounds of the six projects:
  - one thread on P-core 6;
  - four on P-cores 0, 6, 8 and 10, siblings idle.
- **Conditions.** Release builds were paused throughout. Load was 2.4 to 6.5, higher than standing-5's 1.2 to 2.4, and the script waited 24 times for quiet cores.
- **Outputs.** All 480 runs printed tsrs1's bytes.

## Against tsrs at the same thread count

Wall median, Trig against tsrs on as many threads; every cell is in [times-summary.md](tsrs-standing-6-data/times-summary.md).

| project | tsrs1 | Trig, 1 checker | tsrs4 | Trig, 4 checkers |
|---|---:|---|---:|---|
| ts-pattern | 681.2 ms | 13.5% slower (12.3% by the fastest run) | 247.5 ms | 28.2% slower |
| zod3 | 121.2 ms | 25.0% slower | 70.0 ms | 43.3% slower |
| mitt | 18.7 ms | 22.4% slower | 21.7 ms | 32.3% slower |
| neverthrow | 19.6 ms | 28.1% slower | 24.0 ms | 20.4% slower |
| superstruct | 22.9 ms | 35.4% slower | 18.9 ms | 37.0% slower |
| tiny-invariant | 55.5 ms | 25.6% slower | 59.3 ms | 23.1% slower |

- **Against tsrs on one thread, at four checkers:** Trig is 53.4% faster on ts-pattern and 17.3% faster on zod3. It is slower on the four small projects, where four checkers cost more than they save, as in standing-5.
- **Peak RSS against tsrs:**
  - at one checker, 23% (superstruct) to 81% (neverthrow) more;
  - at four, 12% (superstruct) to 57% (zod3) more.
  - Trig's figures are its median runs, so they depend on the mode below.

## Peak memory by mode

Trig's peak RSS comes in two modes on ts-pattern and zod3, and the median is whichever mode most runs hit.
- **High mode:** the allocator's huge-page gate opened, because Linux had free 2 MiB blocks (`alloc.zig`'s `hugeFree`, read from `/proc/buddyinfo`), so its tables and segments were backed by huge pages.
- **Low mode:** the gate stayed shut.

Which mode a run gets depends on the machine's free memory at that moment, not on the code. Later standings should compare like with like, mode by mode. [modes.py](tsrs-standing-6-data/modes.py) splits each variant's runs at the largest gap above 3% ([modes.txt](tsrs-standing-6-data/modes.txt)).

| project | variant | standing-5: low runs, RSS, wall | standing-5: high runs, RSS, wall | standing-6: low runs, RSS, wall | standing-6: high runs, RSS, wall |
|---|---|---|---|---|---|
| ts-pattern | trig1 | 19, 246.9 MB, 789.9 ms | 1, 257.8 MB, 744.4 ms | 9, 248.3 MB, 803.7 ms | 11, 258.9 MB, 764.7 ms |
| ts-pattern | trig4 | 18, 276.6 MB, 326.6 ms | 2, 315.5 MB, 312.4 ms | 10, 278.8 MB, 325.9 ms | 10, 317.4 MB, 315.7 ms |
| zod3 | trig1 | 7, 77.3 MB, 154.2 ms | 13, 84.1 MB, 152.0 ms | 1, 77.3 MB, 148.2 ms | 19, 83.9 MB, 151.8 ms |
| zod3 | trig4 | 17, 111.6 MB, 100.8 ms | 3, 132.0 MB, 102.9 ms | 2, 114.3 MB, 99.4 ms | 18, 134.1 MB, 100.3 ms |

- **Huge pages cost memory and, on ts-pattern, buy time:**
  - at one checker, high-mode runs are 4.9% faster (764.7 against 803.7 ms) and hold 4.3% more memory;
  - at four, they are 3.1% faster and hold 13.8% more;
  - on zod3, the modes differ in memory, not in time.
- **What moved the medians since standing-5 was the mode, not the code.**
  - Zod3 at four hit the high mode in 18 runs of 20, against 3 in standing-5, so its median peak RSS rose 20% (111.6 to 134.1 MB).
  - ts-pattern hit it in 10 or 11 of 20, against 1 or 2, so its median looked faster than it was.
- **Like with like, the code did not move Trig's peak memory.**
  - zod3 at four, low mode, went from 111.6 to 114.3 MB. A bisect over non-PGO builds of Trig `2ba0719`, `aa3994b` and `806e0a1`, by Rig `1684f645a`, `95fffb6cf` (#832) and `928b44bf2`, found one step: 2.5 MB, the same at one checker and at four, between Rig `95fffb6cf` and `928b44bf2`.
  - That step follows the file, not the code. Copied to tmpfs, the two binaries measure the same: 80.4 MB at one checker and about 118 MB at four. A copy of the older binary rose to the newer one's number.
  - `/usr/bin/time`'s peak RSS counts the binary's text pages that are mapped resident: up to 17 MB of `.text`, and how much of it shows depends on the file's cache state, here ZFS against tmpfs. That moves peak RSS by 1 to 3 MB between builds, with the same fault count.
  - Later standings copy every binary to tmpfs before timing, so text pages count the same for each.
- **tsrs** is in one mode on every project at one thread, and in one mode or nearly so at four.

## Since standing-4 and standing-5

Trig against tsrs at the same thread count, by the wall median. For ts-pattern at one checker it is by the fastest run, because tsrs1's median spread widely in standing-5.

| project | 1 checker: standing-4 | 1 checker: standing-5 | 1 checker: standing-6 | 4 checkers: standing-5 | 4 checkers: standing-6 |
|---|---|---|---|---|---|
| ts-pattern | 18% slower | 15% slower | 12% slower | 31% slower (fastest) | 27% slower (fastest) |
| zod3 | 33% slower | 31% slower | 25% slower | 48% slower | 43% slower |
| mitt | 47% slower | 36% slower | 22% slower | 36% slower | 32% slower |
| neverthrow | 50% slower | 38% slower | 28% slower | 27% slower | 20% slower |
| superstruct | 42% slower | 42% slower | 35% slower | 44% slower | 37% slower |
| tiny-invariant | 36% slower | 31% slower | 26% slower | 28% slower | 23% slower |

- **The small projects really are faster.** Trig took 2.0% (tiny-invariant) to 8.4% (mitt) less time at one checker, in one memory mode both days, while tsrs's own times on them moved 2% or less. Rig's pool-yield (#819) explains most of it.
- **ts-pattern has not moved, like for like.**
  - At four checkers the low mode took 325.9 ms against 326.6.
  - At one, it took 803.7 against 789.9 ms, 1.7% more on a day when tsrs took up to 3% longer on zod3 and tiny-invariant.
  - Its better ratios come from the high mode's share of runs and from tsrs1's quieter median.
  - So the lexer and parser change shows no time on ts-pattern here, within this run's noise.
- **zod3** is 1.4% faster at one checker, in its high mode, and 2.5% faster at four.
- **standing-5's 8.5% on ts-pattern at four** was tsrs4's median at 300.3 ms, with a fastest of 238.2 ms. Today tsrs4 ran at 247.5 ms, with a fastest of 242.4. By the fastest runs the gap went from 31% to 27%.
- **Not yet in these numbers.** trig#232 makes the checkers and parses the bundled libs in tasks. On the same harness at four checkers it took 6–13% off the small projects (mitt, neverthrow, superstruct) and 1.5% off zod3.
