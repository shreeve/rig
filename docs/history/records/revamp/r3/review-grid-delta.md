# Review: grid-delta (dc422902), can `--delta` give a false green?

Reviewer: one independent fast-gate reviewer. Scope: the results cache key in
`test/run` and `test/matrix.py`, and its record and carry-over paths.
Experiments ran in a detached worktree of dc422902, with a small checkout
built the way `test/cli/results_cache.sh` builds one: real `test/run`, real
`src/main.zig`, `bin/rig` a wrapper around the real compiler, and a no-op
`zig build`. `./test/run cli/results_cache` passes (26 s).

## Verdict

**There is no Critical or High finding.** In normal use, with nothing
changing during the run and no unusual environment, I found no input that
changes a verdict without changing the key. Each item on the reviewer list
was checked. The package listing really is the whole package: sibling
modules, directory modules, `std/*.rig` modules, the `std/*.zig` shims (by
content, including through `RIG_STD`), the runtime, and the sanitize and
leak-trace root flags. I confirmed this by editing a sibling module and a
std shim under `RIG_STD`; each changed the listing hash. Settings, Zig
(`zig env` also covers `ZIG_*` overrides and the OS version), the driver,
and the harness are in the base.

**False greens do remain, in three narrower classes.** Each is reproduced
below:

1. Something changes **while a run is in progress** (Medium). This is wider
   than the documented limit.
2. **Environment variables** that change a run's outcome are not in the key
   (Medium for `RIG_SANITIZE_BLOCKS` and the sanitizer's degraded mode, Low
   for variables the program itself reads).
3. **The effective time limit** depends on the test kind, but the key takes
   only the global one (Low, and contrived).

None of them can turn a change made on purpose into a false green when it
is committed and then run with `--delta` afterwards. All three are cheap to
close.

---

## Medium 1: inputs that change mid-run are recorded under the pre-change key

The PR documents only "a source file edited between the emit and the run".
The window is wider than that:

- `RESULTS_BASE` (the hash of `test/run` and `src/main.zig`) and `bin/rig`
  are fixed once, when the run starts.
- Every worker re-execs `$SELF`, so a changed `test/run` takes effect at
  once in every later test.
- `bin/rig` can be replaced by any `zig build` in the same worktree.
  `matrix.py` now runs one itself whenever the cache is on, including from
  inside the CLI tests.

So a `git switch`, `git stash`, rebase, or rebuild in a worktree during a
10 to 40 minute run is a problem. Every test that finishes afterwards
records a verdict that came from the new harness, driver, or compiler,
under a key that names the old ones. For the same reason, an edit that is
later reverted, during the seconds between the key's `rig emit` and
`rig run`'s own emit, records the reverted program as passing.

**Reproduction** (an edit saved between the key and the run; the stand-in
`bin/rig` copies the good file over the bad one just before `run`):

```
# co/test/behavior/a/edit.rig = bad.rig:  print(1 + 1)  / # expect: # 3
suite behavior/a/edit                 -> FAIL  (stdout differs)
echo swap > mode; suite behavior/a/edit  -> pass, records 8883dcd8...
: > mode; cp bad.rig co/test/behavior/a/edit.rig
suite --delta behavior/a/edit         -> pass — carried over   (rc 0)  FALSE GREEN
```

**Fix.** Make `record_pass` (and `Results.record`) re-verify before
writing:

- Snapshot the inputs fixed at start (hashes of `$SELF` and `src/main.zig`;
  `stat` of `bin/rig`: device, inode, size, mtime). Record nothing if any of
  them differ at record time.
- Recompute the key after the run (one more `rig emit` and the entry hash,
  only for tests that actually ran). Record only if it equals the key from
  before the run.

That leaves only a change that goes A, then B, then back to A, all within
one test's run. The fully closed form is for `rig run` to report what it
built. It already computes the store hash of the exact package plus the
Zig arguments in `storeEntry`; a `RIG_RUN_PACKAGE=<file>` it writes that
hash to would let the harness key on what actually ran. That needs a change
in `src/`, so it can come later.

## Medium 2: `RIG_SANITIZE_BLOCKS`, and the sanitizer's degraded mode, are not in the key

The runtime reads `RIG_SANITIZE_BLOCKS` (`src/runtime.zig`,
`Sanitizer.configure`). On Linux it also reads `/proc/sys/vm/max_map_count`.
Past that limit it prints `rig: sanitizer: mapping limit reached; further
allocations are not guarded` and hands blocks to `smp_allocator`, so a use
of freed memory is no longer caught. Neither `test/run` nor the matrix
fails a run on that note, and neither keys on the variable or the sysctl.
A run with the sanitizer degraded is therefore recorded under the same key
as a fully sanitized run, and later `--delta` runs carry it over. Before
this change, the same gap affected only that one run. The cache makes it
persist, and makes it apply to every worktree.

**Reproduction:**

```
RIG_SANITIZE_BLOCKS=0 suite corpus/alloc   -> pass (stderr: "mapping limit reached;
                                              further allocations are not guarded"),
                                              records b5b287f4...
suite --delta corpus/alloc                 -> pass — carried over
```

I did not have a program in safe Rig with a use of freed memory that only
the sanitizer catches, so I did not show a changed verdict end to end. The
key is identical with and without the variable, and the recorded run was
unguarded.

**Fix** (both are a few lines):

- (a) Never record a run whose stderr contains `rig: sanitizer: mapping
  limit reached`, in `test/run` (behavior and corpus) and in `run_built`.
- (b) Add `RIG_SANITIZE_BLOCKS` to `RESULTS_BASE` and `Results.base`.
  Better still, hash every `RIG_*` variable in the environment except
  `RIG_RESULTS_CACHE`, `RIG_BUILD_STORE`, `RIG_BUILD_STORE_DAYS`,
  `RIG_TEST_OUT`, and `RIG_OUT_DIR`, so that a future runtime knob is
  covered without anyone remembering to add it.

## Low 1: environment variables the program reads

`std.os.env` and `std.os.args` read the process environment, and the key
does not cover it. About 16 programs (2 behavior tests, the rest in the
corpus) call `os.env` or `os.args`. The behavior tests read names that are
meant to be unset (`RIG_STD_SURELY_UNSET_VARIABLE`,
`NO_SUCH_RIG_VARIABLE_X`), so in practice this does not bite. The class is
real, though:

```
behavior/a/env.rig: print(os.env("RIG_REVIEW_PROBE") ?? "unset")  # expect: unset
RIG_REVIEW_PROBE=x suite behavior/a/env          -> FAIL
suite behavior/a/env                             -> pass, recorded
RIG_REVIEW_PROBE=x suite --delta behavior/a/env  -> pass — carried over (rc 0)  FALSE GREEN
RIG_REVIEW_PROBE=x suite behavior/a/env          -> FAIL
```

**Fix.** Document it next to "Nondeterminism" in test/README.md. A blanket
hash of the environment would defeat the cache (`PWD`, `TMPDIR`, and so
on). Hashing `RIG_*`, as in Medium 2(b), covers the names the suite's own
tests read. Arguments and stdin are fixed: no args, and `</dev/null`.

## Low 2: the effective time limit is per kind, but the key has only the global one

`worker` raises `TIMEOUT` from a `# timeout:` line only for
`behavior|examples|known|cli`. Doc examples and behavior tests share the
contract `behavior`, and `RESULTS_BASE` holds the global `TIMEOUT`. So a doc
example whose extracted `main.rig` is byte-identical to a behavior test
gets that test's raised limit through the cache.

```
README.md ```rig block == test/behavior/a/slow.rig (both "# timeout: 60", sleep 4 s)
RIG_TEST_TIMEOUT=3 suite doc                  -> FAIL (timed out after 3s)
RIG_TEST_TIMEOUT=3 suite behavior/a/slow      -> pass, recorded
RIG_TEST_TIMEOUT=3 suite --delta doc          -> pass — carried over   FALSE GREEN
```

This is contrived: it needs identical bytes, and a `# timeout:` line in a
doc example. **Fix:** key on what the verdict actually used:
`carried_over "behavior $TIMEOUT" "$entry"` in `check_behavior` (the
worker's local `TIMEOUT`), or include the kind in the contract.

## Low 3: `-lc` is decided outside the package files

`rig run` adds `-lc` when `pkg.links_libc`. That flag comes from
`emit.zig`'s `links_libc` and is not written into any emitted file. Today
it is set exactly when `extern "c"` is emitted, so the package bytes
determine it. But an `emit.zig` regression that stops setting it would
leave every key unchanged and break the link on Linux. macOS always links
libSystem, so the Mac would not show it. **Fix:** include the Zig
arguments in what `rig emit` writes, for example a one-line `zig-args`
file in the package, or have the harness hash `rig emit`'s note of them.
This needs a change in `src/`, so it is fine as a follow-up.

## Low 4 (not soundness): CLI tests prune and fill the real shared cache

The CLI tests run the real `$ROOT/test/run`, and `ROOT/.git` exists, so
they use the shared `rig-results-cache`:

- `test_prune.sh` runs `--prune` with `RIG_BUILD_STORE_DAYS=3`, which prunes
  the real cache at 3 days instead of 7.
- `test_shard.sh` and `not_run_evidence.sh` record into the real cache.

Their records are legitimate: the real compiler, and any fake Zig is
named in the key. So this costs only cache hits. **Fix:** export
`RIG_RESULTS_CACHE=` (empty) in `test/cli/_lib.sh`, except in
`results_cache.sh`, which sets its own.

## Checked and found sound

- **Modules and std:** every module of the graph is emitted, and the shims
  are emitted by content. Confirmed by the edit experiments in the Verdict.
- **`rig emit` versus `rig run`:** both use `loadProject` and
  `emitPackage`. They differ only in the hook line, which comes from
  `main.zig` and is hashed, and in `declaresMain`, which depends on the
  root file (the entry) and on `main.zig`. Both commands get the same
  `RIG_SANITIZE`, and inherit the same `RIG_LEAK_TRACE`, `RIG_STD`, and
  `ZIG`. The matrix forces `RIG_SANITIZE=1` in both.
- **Other `src/` files** (`modules`, `sema`, `ownership`, `diag`, `rig`,
  `parser`) reach a run only through the emitted package or a rejection.
  Rig prints no warnings for accepted programs. `build.zig` passes only
  `version`. The build mode of `bin/rig` itself cannot change a verdict.
- **Release builds:** `# release` is in the entry, and `--release` is in the
  matrix key. The `-O` flag comes from `main.zig`. The target is in
  `zig env`.
- **Files read at run time:** std has no file I/O, programs get stdin from
  `/dev/null` and no arguments, and no test has a sidecar file.
- **A failing run never records:**
  - `record_pass` runs only when `ok -eq 0` and the test was not carried.
  - Known bugs and pending examples set `NO_CACHE`, and return before the
    record in any case.
  - A corpus rejection returns before a key exists.
  - The matrix records only when `why is None`, after the `--release` run
    as well.
  - I confirmed by experiment that a failed run left no record.
- **Exit codes:** a carried test is a `pass` line, and real failures still
  make the run exit 1. Confirmed: `--delta` with a failing test exited 1,
  with output `FAIL`. The `gates.sh` summary lines still parse.
- **Concurrency:**
  - A record is an empty file created after the verdict, so a partial
    record cannot exist.
  - Prune only deletes, which costs a rerun, never a false pass.
  - If prune deletes a record between `-f` and `touch`, the `touch`
    recreates a record that was valid.
  - The key's temporary directory is per run (`$RESULTS`) and per test
    `ID`.
  - Worktrees on different branches share records only when the harness,
    driver, Zig, settings, entry, and package are all byte-identical.
- **Matrix `VERDICT_CODE`** covers every function and constant that
  `run_one` and `run_built` reach: `tree_rss`, `run_capped`, `first_line`,
  `first_error`, `BAD`, `POS`, `CRASH`, and the `RUN_*` limits, which are
  set before `Results` is built. `--rig` turns the cache off. `zig build`
  runs first.
- **Pipeline failures:** `RESULTS_BASE` runs under `pipefail`, so a
  missing `src/main.zig` or a failing `zig env` turns the cache off.
- **Clock and randomness:** 2 behavior programs (`std/time.rig`,
  `std/random.rig`), 9 corpus programs, and the `docs/STD.md` examples use
  `time.now`, `sleep`, `unix_ns`, or `Random.new`. Every assertion holds
  whatever the clock or the seed: `d >= 1 and d <= 6`, `!r.next() > 0`
  (fails with probability 2^-64), and `took < 10 s`, which fails only under
  load. Corpus verdicts are about soundness, not output. They need no
  exclusion; the documented limit is accurate.

## Suggested order

Take Medium 1 (re-verify at record time) and Medium 2 (do not record a
degraded sanitizer; hash `RIG_*`) before merge; together they are about 20
lines in `test/run` and `matrix.py`, plus a case each in
`results_cache.sh`. Low 2 is a one-word change. Low 1 and Low 4 are
documentation and hygiene. Low 3 can wait for the next change to `src/`.
