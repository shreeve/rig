# A program built by profile tears down at exit (2026-11-09)

The fixed-cost panel found that Trig built by `--pgo` on the Mac had no `sched.tearDown`. `exitNow` skipped the teardown when `pgo` was set, meaning the build that trains, but both links of a `--pgo` build share one bitcode, so the optimized build skipped it too. Its exit then freed the program's page tables on one core, as before the parallel teardown (`2026-11/exit/`). Linux has no teardown in any build, so it was not affected.

**The fix:** `exitNow` writes the profile first, a no-op in the optimized build, and then both builds tear down. `test/cli/exit_teardown.sh` builds a program of tasks by profile on the Mac and checks that the training run and the optimized run both tear down, and that the profile was written. It failed on main.

**Measured** on the Mac, with the timing slot claimed: Trig 8637963, PGO-built with Rig at main 6c35d5839 and with the fix. Each arm was trained by `tools/trig/bolt-train` on its own. 20 rounds per cell, with main, a copy of main (A/A) and the fix shuffled in each round, medians. Raw table: [table.txt](table.txt); script: [time.py](time.py).

- **4 and 8 checkers on the small projects:** 1.3–15.2% faster. Examples:
  - superstruct at 8 checkers, 15.2% and 14.8% faster (libs off and on);
  - mitt at 8 checkers, 6.7% and 10.0%;
  - neverthrow at 4 checkers with libs on, 13.1%.
- **1 checker:** level. One worker has nothing to tear down. The cells range from 2.5% slower to 2.2% faster, against an A/A of up to 2.1%; the arms' separately trained profiles are a likely part of that.
- **zod3 and ts-pattern:** level within their A/A, which reaches 4–5% on the noisiest cells.
