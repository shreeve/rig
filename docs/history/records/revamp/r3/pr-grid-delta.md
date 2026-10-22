# Rerun only what changed: `--delta` and a results cache

`./test/run --delta` and `test/matrix.py --delta` still check every
program. They skip the run of any program whose run already passed with
the same inputs. A no-change gate run on the Mac drops from about 11
minutes warm (39 minutes cold) to 3.2 minutes. A diagnostic-only change
takes 4 minutes. A change to emitted code reruns only the programs whose
package changed.

## How it works

Each passing run is recorded in a **results cache**. The default
location is `rig-results-cache` in the git common directory, next to
the build store, so every worktree shares it; `RIG_RESULTS_CACHE`
overrides it. A record is an empty file named by a key. The key is a
sha256 of everything the run's verdict depends on:

- **The package.** Every file `RIG_SANITIZE=1 rig emit` writes, with its
  path and contents: each module, the std shims, and the runtime. This
  is the same per-file listing equiv.py's `pkg` section uses. The
  package `rig run` builds is this one plus one line, which names the
  start hook and is written by `src/main.zig`.
- **The entry file**, which carries the program and its directives:
  `# expect:`, `# expect-panic:`, `# release`, `# timeout:`. For a
  matrix program, the key instead takes the expected output and the
  `--release` flag.
- **The harness.** For test/run this is the whole script. For the matrix
  it is the source of the functions that run and judge a program
  (`VERDICT_CODE`) and the `BAD`/`POS`/`CRASH` patterns. Adding a matrix
  axis therefore does not invalidate the cache.
- **The driver**, `src/main.zig`, which covers how rig runs the program
  and decides that it started. bin/rig is always built from it first:
  test/run already does this, and matrix.py now runs `zig build` when
  the cache is on.
- **Zig.** The output of `zig env` (version, lib/std dir, target) and the
  `ZIG` path.
- **libc.** Whether Zig links the package with libc (`-lc`). This is in
  no package file, so `rig emit` now notes it: the one line of `src/`
  this PR changes.
- **Settings.** Every `RIG_` variable except those that name a place
  (`RIG_RESULTS_CACHE`, `RIG_BUILD_STORE`, `RIG_BUILD_STORE_DAYS`,
  `RIG_TEST_OUT`, `RIG_OUT_DIR`). This covers `RIG_SANITIZE` and its
  knobs such as `RIG_SANITIZE_BLOCKS`, `RIG_LEAK_TRACE`, `RIG_STD`, and
  any `RIG_` variable a program reads. The key also takes the time limit
  the test's own verdict used (`"behavior $TIMEOUT"`), and for the
  matrix `--timeout` and `--mem`.

A run is recorded only if all of these hold:

- **It passed** (a failing run records nothing).
- **The sanitizer guarded every allocation.** A run that printed
  `rig: sanitizer: mapping limit reached` passes but is not recorded.
- **Nothing its key names changed while it ran.** After the run, the key
  is computed again and must be the same. `test/run`, `src/main.zig`, and
  `bin/rig` (its device, inode, size, and mtime, since a `zig build`
  replaces it) must also be the ones the run started with.

Every run records its passes; only a `--delta` run reads the cache. A
carried-over test passes with "carried over" as its reason, and the
summary reports the count, e.g. `2842 passed (1353 carried over)`.

What `--delta` covers:

- **Cached:** behavior tests, examples, doc examples with output,
  corpus programs and matrix programs.
- **Always run:** rejections, IR snapshots, torture, CLI scripts, the
  whole-program checks and the oracle.
- **Never cached:** known bugs and pending examples, whose verdicts are
  inverted.

A failing run records nothing. A full run with no filter prunes records
untouched for `RIG_BUILD_STORE_DAYS`; a hit touches its record.
`--rig OTHER` neither reads nor writes the cache, since that compiler's
driver is unknown.

### Why it is sound

A carried-over pass stands for one passing run of the same package,
built by the same Zig, run by the same driver and judged by the same
harness against the same expectation. The cases that matter:

- **The runtime changes:** every package changes, so everything reruns.
- **`rig run`'s own logic changes** (the started evidence, signal
  reporting): `src/main.zig` changes, so everything reruns.
- **test/run or the matrix's verdict code changes:** everything in that
  runner reruns.
- **A check verdict changes:** the check always runs. A program that is
  now rejected has no key (`rig emit` fails), so it takes the normal
  path and its rejection is reported as before.

Nothing about a base commit is trusted. The cache holds only passes,
each written by a run that actually executed the program, under a key
that names every input.

### Residual limits (documented in test/README.md)

- **Nondeterminism.** A program whose output depends on the clock,
  randomness, or the machine is carried over on the strength of a
  single passing run.
- **Other environment variables.** A program that reads a variable not
  named `RIG_` (through `os.env`) is carried over the same way. Hashing
  the whole environment (`PWD`, `TMPDIR`, ...) would mean no record ever
  matched.
- **An edit made and undone during one run.** A file changed to B and
  back to A while a single program runs still records A's key. Closing
  this needs `rig run` to report the hash of what it built, which is a
  later change to `src/`.

### Review fixes (review-grid-delta.md)

Each fix has a case in `test/cli/results_cache.sh`, and each case was
mutation-checked: removing the fix fails it.

- **Medium 1: an input changes during a run.** The key is recomputed
  after the run, and the fixed inputs are rechecked: `test/run`,
  `src/main.zig`, and bin/rig's identity. For the matrix the fixed inputs
  are `src/main.zig` and `bin/rig`, since its verdict code is already in
  memory. Covered cases:
  - the program is saved over just before the run and then restored;
  - `bin/rig` is replaced during the run;
  - `test/run` is edited during the run;
  - the same three in the matrix.
- **Medium 2: the sanitizer stops guarding.** A run past the mapping
  limit is never recorded, in `test/run` (behavior and corpus) or in the
  matrix. Every non-location `RIG_` variable is now in the key. Covered
  cases: an unguarded run is not recorded, and `RIG_SANITIZE_BLOCKS` or
  any other `RIG_` variable changes the key.
- **Low 1: environment variables a program reads.** `RIG_` variables are
  in the key; others are documented as a limit.
- **Low 2: one time limit for doc examples and behavior tests.** The
  contract now includes the time limit the test itself used. Covered
  case: a doc example byte-identical to a behavior test that raises its
  own limit is not carried over.
- **Low 3: `-lc`.** `rig emit` prints `note: Zig links it with libc
  (-lc)`, and both keys hash it. Covered case: a stand-in compiler whose
  emit hides the note fails the libc test instead of carrying it over.
- **Low 4: CLI tests used the shared cache.** `test/cli/_lib.sh` exports
  `RIG_RESULTS_CACHE=` (empty), so CLI tests neither fill nor prune the
  shared cache; `results_cache.sh` checks this.

AGENTS.md's "Rerun only what changed" rule (from #77) now names
`--delta` and points to test/README.md's section.

## Safety test

`test/cli/results_cache.sh` covers the false-green class from #63's
review. It builds a small checkout containing test/run, `src/main.zig`,
one behavior test and one corpus program. Its `bin/rig` is a stand-in
compiler: the real one, made to emit a changed runtime or to make every
program it runs fail. The test then checks that a `--delta` run reports
FAIL, and never carries a pass over, after each of these changes:

- the expected output (and that adding `# release` is not carried over);
- the runtime: a compiler whose emitted runtime differs and whose
  programs leak, for both behavior and corpus;
- the driver, `src/main.zig`, with the same package;
- the harness, test/run;
- the Zig path;
- `RIG_SANITIZE`;
- the time limit.

The test also checks:

- an unchanged test is carried over, so the failures above are not
  vacuous;
- a run without `--delta` carries nothing over;
- a failing run records nothing;
- prune removes old records;
- `test/matrix.py`'s keys change with the expected output, `--release`,
  the runtime, and the verdict code.

I mutation-checked the test. Dropping the entry-file hash from the key
fails it at "changed expectation"; dropping `src/main.zig` fails it at
"another driver".

## Measurements (Mac, main's tree, `heavy.sh gates.sh`, `-j` from cpuq)

The Mac was shared with other projects throughout; the 1-minute load
was 9 to 26. Times are wall-clock seconds.

| run | suite | corpus | matrix | unit | total |
|---|---|---|---|---|---|
| baseline, main b0f156c9, no cache code (store partly cold), -j 6 | 80 | 1123 | 1138 | 8 | **39 min** |
| fill: full run, records passes (store warm), -j 5 | 246 | 225 | 160 | 13 | **10.7 min** |
| no change, `--delta`, -j 6 | 70 | 88 | 24 | 10 | **3.2 min** |
| emit change (a comment before every `while` loop), `--delta`, -j 6 | 142 | 259 | 606 | 15 | **17 min** |
| ownership message reworded, `--delta`, -j 5 | 99 | 102 | 27 | 10 | **4.0 min** |

How much each run reran:

- **No change:** 1353 of the suite's program runs were carried over, as
  were 3295 corpus programs and all 2607 matrix programs that run. What
  remains is checking (about 1500 suite tests, 7040 corpus checks,
  5333 matrix checks), the CLI scripts and the unit tests.
- **Emit change:** the change touched 185 suite programs, 407 corpus
  programs and 521 matrix programs. Every one was rebuilt cold and run,
  in debug and with `--release` for the matrix, while the other 6000 or
  so were carried over. Under a load of 20 to 26 most of the time went
  to cold Zig builds. A change confined to emitted code costs only what
  it touches. A runtime change still costs a full cold run, by design.
- **Diagnostic change:** every package is unchanged, so no program ran.

**At the head, debd2458** (main c0b21e50 merged in, review fixes
applied), `GATES_DELTA=1`. where.sh chose the Mac: pup had 8 GB
available, under the 12 GB floor. cpuq granted only `-j 2`, under a load
of 14 to 27. The key's format, test/run, and `src/main.zig` had all
changed, so every earlier record was unused and nothing was carried
over, except corpus programs the suite's corpus sample had just
recorded.

| suite | corpus | matrix | unit |
|---|---|---|---|
| 432 s, 2852 passed (0 carried over), 4 pending | 738 s, 7084 passed (278 carried over) | 449 s, 5453 programs: 2643 ran clean, 2810 rejected, 0 failed | 13 s, 128/129 (1 skipped) |

All gates are green. This run also filled the cache for the next round.

Logs: `.git/revamp/r3/logs/grid-delta/{base0,fill,nochange,emitchange,diagchange,head}.*`.

The emit and diagnostic changes were applied uncommitted in a scratch
worktree and then reverted. They are not part of this branch.

## Outside the repository

- `.git/revamp/r3/where.sh` prints `pup` or `mac`. It prints `pup` when
  pup answers within 15 s, has no exclusive cpuq holder or waiter
  (leases included), has normal memory pressure, and has at least
  `WHERE_MIN_GB` (default 12) GB of memory available. Otherwise it
  prints `mac`, and the reason goes to stderr. I tested it live (pup was
  held exclusively by emdb-wave3, so it answered `mac`), against an
  unreachable host, and with a fake ssh for the free, low-memory and
  exclusive-waiter cases.
- `gates.sh` and `pup-gates.sh` now take `GATES_DELTA=1`, which passes
  `--delta` to the suite, corpus and matrix. `gates.sh` also records each
  gate's time in the summary, as `pup-gates.sh` already did.

## Not changed

- `src/` changes by one line: the `-lc` note from `rig emit`.
- The merge bar is unchanged: the full gates still run at a PR head, and
  those runs fill the cache for the next round.
