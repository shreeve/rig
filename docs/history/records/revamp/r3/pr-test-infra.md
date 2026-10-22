## Speed up the test tooling (no compiler semantics change)

Eighteen commits, plus merges of main: 9e8ac153 (#58), then 28f20fc4
(#59, #60, #61):
- six for the speedups;
- six for the independent review's findings;
- one that keeps the started-file hook out of shipped programs;
- five for the re-review's findings and what its gates turned up.

Nothing in `src/ownership.zig`, typecheck, sema, or emit changes. `src/main.zig` (the CLI) changes where `rig run/build/test`
writes and builds the package and how `run`/`test` report a program that
never started. In a package `rig run` or `rig test` builds, whose root
declares `__rig_run_started`, `src/runtime.zig`'s `start` creates the
file named by `RIG_PROGRAM_STARTED`. A program `rig build` makes has no
such declaration and never mentions either variable. Every program is
still checked and run under the sanitizer, and Zig still checks every
input of a cached build.

1. **Keep every corpus program's build cache in a sampled run.** A run
   with no filter pruned the output of every test it did not list, and it
   lists only a 1-in-16 corpus sample, so it deleted the other 15/16 of
   the corpus caches and the gates' corpus run that followed was cold.
   The prune now keeps every test that exists. New `--prune` option
   (prune only), and `test/cli/test_prune.sh`, which fails without the fix.
2. **Discover tests in one find and awk pass.** Startup of every
   `./test/run` invocation, filtered or not: ~21 s -> ~1.5 s (Mac, under
   load). The test list is byte-identical, order included, to the old
   runner's for 16 filter sets: none, `corpus`, `oracle`, `doc`, `known`,
   `ownership`, `behavior/ownership`, `R11a`, `cli/test`, `unit`, `L12`,
   `doc/SPEC`, `examples hello`, `corpus oracle doc vocab`, `'' reject`,
   and `parser classify vocab`. The prune's keep-list is identical too.
3. **Build programs in a content-addressed store shared by worktrees.**
   With `RIG_BUILD_STORE=DIR`, `rig run/build/test` writes the package to
   `DIR/<hash>/package/` and builds with `DIR/<hash>/` as its Zig cache.
   The hash covers the Zig command (verb, mode, `-lc`, root, zig path) and
   every file's path and contents: the emitted modules, the std shims, and
   the runtime. Sanitize and leak-trace mode are part of the root module.
   The package sits inside the cache because Zig keys a cached build by
   its root's path relative to the cwd, unless that path is inside the
   cache. Placed this way, builds hit from any directory; measured, they
   missed when the package was outside the cache. A file whose contents
   are unchanged is not rewritten. `test/run` and `test/matrix.py` default
   the store to `rig-build-store` in the repo's git common dir.
   `RIG_BUILD_STORE=` turns it off. A full run (or `--prune`) removes
   entries unused for `RIG_BUILD_STORE_DAYS` (default 7).
   New `test/cli/build_store.sh` checks that:
   - two directories with one package share an entry;
   - a different module, sanitize, release, `test`, or `build` each get
     their own entry;
   - the entry's package equals what `rig emit` writes;
   - a changed store file is written back;
   - concurrent runs share an entry safely.
4. **Equivalence: cache the base, and compare the sanitized package.**
   - The base compiler's results (exit status and output hash) are
     cached in `rig-equiv-cache` in the git common dir. The key is the
     base binary's sha256, the section, the program's path, the relevant
     env, and the contents of the program and of every module beside it
     that any `use NAME` could read (present or absent).
   - New `pkg` section: the sha256 of the whole package that
     `RIG_SANITIZE=1 rig emit` writes (all modules, shims, and the
     runtime with its sanitizer).
   - The equivalence lists are identical: the old and new `equiv.py`
     both report the same 14 programs (8,311 compared, v0.2.1 vs this
     branch). A runtime-only change (a comment appended to
     `runtime.zig`) shows as `pkg` and nothing else.
5. **AGENTS.md (approved by the design owner):** one ownership branch
   per fact or classifier, with a combined-tree gate for the second to
   merge.
6. **`--shard I/N`** for `test/run` (hash of the test id; shard 1 also
   runs unit/parser/classify/vocab) and `test/matrix.py` (crc32 of the
   cell id). `test/cli/test_shard.sh` checks that the shards are
   disjoint and together cover the examples and a matrix slice.

7. **Fail a test whose program never ran** (review High-1). Before
   this, corpus and matrix ignored `rig run`'s status and passed any
   program whose stderr lacked a known bad pattern, including one that
   never started. The causes: Zig's `failed to execve`, an unusable store,
   a full disk, rig's own I/O errors.
   - `rig run` and `rig test` now exit with the program's status only
     once the program has started. The runtime's `start` creates the
     file `RIG_RUN_STARTED` names.
   - Any failure before that (rig's, Zig's, the store's, or starting
     the program) prints `rig: the program did not run` and exits 125.
   - test/run's behavior, example, known, doc-output and corpus runners,
     and matrix.py, require that file as positive evidence the program
     ran, whatever the status or output.
   - Also: a store entry whose manifests outlived its binaries (`h/`
     without `o/`) is healed (manifests dropped, built once more), and
     the failed-shim-build checks in `cli/std_shims.sh` now expect 125.
   - New `test/cli/not_run.sh` covers an unusable store, no Zig, a
     program's own 125, the healed entry, and test/run and matrix.py
     failing such programs. It fails with the old checkers.
8. **Prune store entries by renaming them into a trash first**
   (Medium-2). Each entry leaves the store in one step, and the trash,
   including what an interrupted prune left, is deleted after.
   `test_prune.sh` checks this.
9. **`cli/zig_cache.sh` runs its checks with the store off and on**
   (Medium-3). It also asserts which directory each mode built in.
10. **Lows:**
    - discovery follows symlinked directories (`find -L`), and a `find`
      error (an unreadable directory) stops the run; lists are unchanged
      for the 16 filter sets;
    - shard hashing runs under `LC_ALL=C` (bytes);
    - `matrix.py --oracle --shard` is refused (the coverage floor is for
      the whole set);
    - equiv caches no base result killed by a signal, and no failed
      result of an accepted-only section; an accepted program whose
      emit or pkg fails on either side is reported as `<section>(failed)`;
    - equiv's key includes the names that differ only in case from a
      missing `use` module.
11. **AGENTS.md:** the rule names `src/ownership.zig` or typecheck's
    classification of expressions, and "each later branch".
12. **Fail the classify and vocab checks when they cannot read** (the
    same "absence of a bad pattern = pass" shape: `grep` exiting 2, or
    no file list).
13. **Give only `rig run` and `rig test` packages the started-file
    hook.** The root module of those packages (and `rig test`'s driver)
    declares `__rig_run_started = "RIG_RUN_STARTED"`, and the runtime
    acts only when that declaration exists (comptime).
    - `rig build` and `rig emit` packages have no such declaration, so a
      shipped program never reads the variable and never creates a file.
    - The store key already separates the verbs.
    - `test/cli/not_run.sh` checks that:
      - a `rig build` executable contains no `RIG_RUN_STARTED`;
      - running it with the variable set creates no file;
      - the `rig emit` package and a `rig build` store entry have no
        hook.
    - The test fails on the previous runtime.

14. **Prove a run by a fresh started file rig creates once the program
    starts** (re-review Medium-1, Low-2, Low-4, Low-5, Low-6).
    - Each attempt gets a fresh path for the program to create
      (`RIG_PROGRAM_STARTED`). rig accepts only a regular file there.
    - A caller's `RIG_RUN_STARTED` handling:
      - rig deletes it first, and fails with 125 if it cannot (a
        directory there, for example);
      - rig keeps it out of the program's environment, so a nested
        `rig run` cannot touch it;
      - rig creates it only after the program has started.
    - test/run names it in the run's private results directory, where
      no test's output directory can sit. matrix.py names it in a
      private temp directory, with a uuid for each attempt.
    - Both treat a missing regular file, or rig's `rig: the program did
      not run` line, as not run.
    - The heal now fires when `o/` holds no executable named after the
      root, not only when `o/` is missing.
    - The not-run message now reads "and the program left no sign that
      it started".
15. **Fail known, pending, and signal-killed runs that prove nothing**
    (Low-8, Low-9).
    - A known bug that never ran is `fail`, not `known`.
    - `not_run` keeps a `rejected` reason only when stderr has a
      `.rig:L:C: error`, so a pending example that never ran fails.
    - Corpus and matrix fail a program a signal ended, unless it is a
      Rig panic.
      - The status alone cannot tell: `corpus/review-std-e_255` exits 255
        itself. So when a signal ends the program, `rig run` and `rig
        test` now say so: `rig: the program was killed by signal N`.
      - A Rig panic is an abort (signal 6) after its `panic:` report.
        Rig's bounds panics do abort, for example
        `corpus/review-seam2-r2-z14`.
16. **Prune the evidence files killed runs leave in the store** (Low-7):
    `.started/` files older than a day.
17. **Run one matrix at a time in a kept directory** (Low-2, an `flock`
    on `DIR/.matrix.lock`). This commit also adds
    `test/cli/not_run_evidence.sh`, which checks each fix above. Every
    one of its checks failed on the code before 14-17 (verified):
    - a directory at the caller's path;
    - a stale file after a failure;
    - two runs sharing one path;
    - the program's environment;
    - an entry whose binary is gone;
    - a corpus program behind a directory at the old path;
    - a corpus and a matrix program killed by SIGKILL (through a Zig
      wrapper);
    - the kept-directory lock;
    - a known bug and a pending example that never ran (in a scratch
      checkout of their own, with a Zig that builds nothing).

18. **Accept a build store that is a link to a directory.** pup's store
    is now a link to /zfs. `createDirPath` on a link reports `NotDir`,
    so rig now resolves the store's real path first and creates it only
    when it is not there. The prune's `find` uses `-H`.
    - The first pup run at b732aa7c showed this. Every program that runs
      failed as "the program did not run: cannot create RIG_BUILD_STORE
      ...: NotDir": suite 1280, corpus 2883, matrix 1453, odv 194. That
      is the new evidence rule doing its job: before this branch, those
      corpus and matrix programs would all have passed.
    - `build_store.sh` and `test_prune.sh` now cover a linked store.

Known false reds, not fixed (each is a false red, never a false green):
- **Re-review Low-3, prune race.** A prune in one worktree can move an
  entry away while another worktree builds in it, after `find` read its
  old `used`. That build fails as not run (125) once, and the next run
  rebuilds. It needs an entry unused for 7 days, used at the exact
  moment of another worktree's full-run prune. Fixing it needs a shared
  lock that rig and the prune both take. macOS has no `flock(1)`, so
  that is more than a few lines.
- **Re-review Low-5.** If the program cannot create its started file
  (an unwritable directory, a full disk), rig reports it did not run,
  though it did. The message now only says the program left no sign it
  started.
- **Re-review Low-7, partly.** Evidence files left by a killed `rig run`
  outside a store (`.started-*` in the output directory, by default
  `~/.cache/rig/<project>/`) are not pruned. They are empty files.
- **Re-review Low-4, cosmetic.** After a successful heal, Zig's own
  `failed to execve` line still shows above the program's output.
  Quieting it would mean buffering Zig's stderr.

Checked for the "no bad pattern = pass" shape:
- **Fixed:** check_behavior (behavior, examples, known, doc output and
  pending), check_corpus, matrix `run_one`.
- **Already safe:** check_torture (requires a `.rig:L:C` diagnostic);
  check_reject, check_accept, check_parse, check_facts and check_ir
  (exit status plus exact content); check_cli (the scripts'
  `expect_*`); check_oracle (exit status plus the coverage floor); unit
  (exit status); parser (`cmp`).
- **Fixed in 12:** classify and vocab.
- **equiv.py:**
  - equal outputs from the two compilers count as equivalent by
    design;
  - an accepted program's emit or pkg that fails on either side is now
    reported as `<section>(failed)`;
  - failures are not cached.

### Gates at the head (8671b11c: main 28f20fc4 merged)

The second merge had one conflict, in `test/matrix.py`'s docstring
(main's new `step.` cells), resolved by keeping both texts. The `step.`
cells now go through `--shard` too.

- **pup** (`pup-gates.sh`, `PUP_CORES=12`, `-j 12`, all green):

  | Gate | First run | Warm run |
  |---|---|---|
  | suite | 2743 passed, 4 pending, 206 s | same, 65 s |
  | corpus | 6731 passed, 354 s | same, 124 s |
  | matrix | 4899 programs, 0 failed, 223 s | same, 17 s |
  | unit | 124/126 (2 skipped), 8 s | same, 8 s |
  | odv | 329 passed, 4 pending, 10 s | same, 9 s |
  | **total** | **13.4 min** | **3.7 min** |

  `corpus/review-std-m5` passes on Linux. Main's #60 sends `%` through
  `rig.rem`, so `math.mod(Int.min, -1)` is 0 instead of a trap.
- **Mac**, through heavy.sh (`-j "$CPUQ_CORES"` = 2), all green:
  - `./test/run cli examples doc vocab classify parser unit oracle known
    behavior reject/ownership corpus/R11a` plus the new corpus probes
    since 9e8ac153 and `corpus/review-std-m5`: 2143 passed, 4 pending;
  - `test/matrix.py -k int. -k store. -k payload.`: 1329 programs, 0
    failed;
  - `-k step.`: 180 programs, 0 failed;
  - the full corpus: 6731 passed.

**The first run after this merges is cold.** The runtime changed (the
hook), so every package is new once, on every machine and in CI. From
then on the store makes runs warm, as the pup warm run shows (13.4 ->
3.7 min).

### Gates at 93411ac1 (main 9e8ac153 merged, before the re-review fixes)

The merge was clean. The 317 corpus probes main added all pass under
the started-file rule.

- **pup** (`pup-gates.sh`, `PUP_CORES=12`, cold, at `-j 12`):

  | Gate | Result | Time |
  |---|---|---|
  | suite | 2695 passed, 7 pending | 150 s |
  | corpus | 6349 passed | 288 s |
  | matrix | 3637 programs, 0 failed | 121 s |
  | unit | 124/126 (2 skipped) | 8 s |
  | odv | 325 passed, 7 pending | 9 s |

  pup-gates.sh was edited while it ran and stopped with a syntax error
  after the gates, so I fetched the logs by hand into
  `logs/test-infra/pup-merged.*`.
- **Mac**, through heavy.sh (`-j "$CPUQ_CORES"` = 5):
  - the 317 new corpus probes: 317 passed;
  - `cli examples doc vocab classify parser unit oracle
    behavior/ownership reject/ownership`: 1003 passed, 7 pending;
  - `test/matrix.py -k int. -k store. -k payload.`: 1197 programs, 0
    failed.

### Earlier gates (3bd38b1c, before the hook change and the merge)

- **pup** (`pup-gates.sh`, `PUP_CORES=12`, cold, because the runtime
  changed):
  - suite 2654 passed, 7 pending (166 s);
  - corpus 6032 passed (263 s);
  - matrix 3427 programs, 0 failed (115 s);
  - unit 124/126 (2 skipped);
  - odv 322 passed, 7 pending.
  - Afterwards `pup-gates.sh` removed the store (40 GB free).
- **Mac**, through heavy.sh (`-j "$CPUQ_CORES"` = 2):
  - `./test/run cli examples doc vocab classify parser unit oracle
    behavior corpus/R11a corpus/review-sc`: 1620 passed, 0 failed,
    7 pending;
  - `test/matrix.py -k int. -k store. -k payload.`: 1177 programs, 0
    failed.

The timings below were measured at 48e8ab77, before the review fixes.

### Measured

Mac, `-j 4` under cpuq, 1-minute load 7-12. "Cold" is a run with an
empty store, which does the same build work as running without the
store. "New branch" is a fresh worktree whose compiler changed (a
comment), with the store warm from another worktree.

| Mac, -j 4 | cold | new branch | re-run |
|---|---:|---:|---:|
| suite | 554 s | 96 s | 103 s |
| corpus | 897 s | 130 s | 148 s |
| matrix | 539 s | 43 s | 43 s |
| odv | | | 14 s |
| total | 33.2 min | 4.5 min | 5.1 min |

pup, `pup-gates.sh` with `PUP_CORES=12` (all four gates and odv, green):

| pup, -j 12 | first run | new branch | re-run |
|---|---:|---:|---:|
| suite | 140 s | 61 s | 58 s |
| corpus | 255 s | 114 s | 115 s |
| matrix | 122 s | 9 s | 9 s |
| unit | 9 s | 8 s | 7 s |
| odv | 7 s | 7 s | 8 s |
| total | 8.9 min | 3.3 min | 3.3 min |

Today, every pup run is a first run, because `pup-gates.sh` deletes the
caches afterwards. For comparison, main at `-j 4` (`pup-main.sum`):
suite 288 s, corpus 502 s, matrix 167 s.

- The new branch created 4 store entries (suite), 0 (corpus) and
  0 (matrix).
- Per-test results (`-v`) of the cold and the new-branch runs are
  identical for suite, corpus and matrix.
- Equivalence, Mac, `-j 4`: old `equiv.py` 248 s; new, first run 320 s
  (it adds the `pkg` section); new, rerun against the same base 169 s.

### Notes for operators

- The store holds the build products that used to live in each
  worktree's `.zig-cache/rig-test`. A full suite + corpus + matrix fills
  28 GB on the Mac and 51 GB on pup.
- `pup-gates.sh` ends with `rm -rf .zig-cache/rig-test .zig-cache/rig-matrix`.
  That no longer frees the space: the bulk now sits in
  `~/Data/Code/rig/.git/rig-build-store`, and pup had 42 GB free with it
  in place. I deleted pup's store after measuring. Before relying on it
  there, pup-gates.sh needs a store policy, for example
  `RIG_BUILD_STORE_DAYS=1 ./test/run --prune` after the gates, or a size
  cap.
- `gates.sh`'s separate corpus output directory is no longer needed
  (fix 1, and the store), but it is harmless.
- CI could cache `.git/rig-build-store` (actions/cache) to make CI runs
  warm. That is not done here.
