# Review: branch `test-infra` (48e8ab77, 6 commits over main 0cbf7e7a)

Reviewer: independent. Worktree /Users/shreeve/Data/Code/rig-test-infra,
bin/rig rebuilt at HEAD (up to date). All experiments used private stores
and output dirs under the session scratchpad; the shared store was not
touched. No full suites were run.

## Verdict on the overriding question

**Yes, I found a way to get a false green, though not through a stale
cache hit.** The store key holds up: I found no pair of runs that differ in
an input and share an entry. What I did find is this. A corpus or matrix
program whose build or launch fails for an infrastructure reason is
reported as **passing without having run**. The branch adds new ways to
reach that state:

- a store entry with Zig's manifest but no binary, which a pruning `rm -rf`
  that is interrupted or races a build leaves behind;
- a store that cannot be written (wrong path, permissions, a full disk with
  a 28 to 51 GB store).

The checkers' root cause (exit status ignored, only known bad patterns
looked for) predates this branch. The branch is what makes it reachable in
normal operation (High-1, Medium-2). I also found one place where a test
now passes without testing what it names (Medium-3).

Not found: a stale Zig build reused from the store, a test dropped by the
new discovery on the current tree, a stale `--prune` output reused as a
result, a stale equiv base result that hides a real difference, or a shard
set that misses or duplicates a test.

---

## High-1: corpus and matrix pass a program that never ran (store failures make this reachable)

`check_corpus` (test/run) and `run_one` (test/matrix.py) ignore `rig run`'s
exit status. They fail only on `CORPUS_BAD_RE`/`BAD` patterns: leak, UAF,
`.zig:N:N: error`, segfault, and so on. A failure before the program
starts matches none of these:

- `zig run` printing `failed to execve with 'FileNotFound'`;
- rig's own `fatal("error: cannot create RIG_BUILD_STORE ...")`;
- `cannot write ...: NoSpaceLeft`;
- Zig I/O or lock errors.

Each of these counts as a pass.

**Repro A (poisoned entry, which is the state an interrupted or racing prune leaves; see Medium-2):**
```bash
cd /Users/shreeve/Data/Code/rig-test-infra
export RIG_BUILD_STORE=$SCRATCH/cstore RIG_TEST_OUT=$SCRATCH/cout
./test/run -v -j 2 corpus/R11a-d1s            # 1 passed (real run)
E=$(ls -d $RIG_BUILD_STORE/*/ | head -1); rm -rf $E/o
./test/run -v -j 2 corpus/R11a-d1s            # 1 passed  <-- program never ran
RIG_SANITIZE=1 bin/rig run test/corpus/R11a-d1s.rig
#  error: the following command failed to execve with 'FileNotFound': .../o/<digest>/__rig_main   rc=1
```
Observed: pass. Expected: fail ("program did not run").

**Repro B (unusable store):**
```bash
: > $SCRATCH/notadir
export RIG_BUILD_STORE=$SCRATCH/notadir/store RIG_TEST_OUT=$SCRATCH/cout2
./test/run -v -j 2 corpus/R11a-d1s corpus/R11a-q1l corpus/R11a-r3l examples/hello
#  pass corpus/R11a-d1s, pass corpus/R11a-q1l, pass corpus/R11a-r3l
#  FAIL examples/hello — error: cannot create RIG_BUILD_STORE ...: NotDir
python3 test/matrix.py -v -k int.print
#  "10 programs ...: 10 ran clean, 0 rejected, 0 failed"   <-- none ran
```

Why this matters now:

- `./test/run corpus` and `test/matrix.py` are separate gate invocations.
  A store fault during those runs, but not during the suite run, turns the
  gate green.
- The PR's own numbers make a full disk realistic. The store fills 28 GB on
  the Mac and 51 GB on pup, and pup had 42 GB free with the store in place.
  A `NoSpaceLeft` part-way through the corpus gate greens every program
  after that point. I inferred this from the code path (`writeFile` →
  `fatal`, and Zig's error text). I did not reproduce it, because doing so
  needs a full volume.
- The poisoned entry in Repro A is **persistent**: every use rewrites
  `used`, so the 7-day prune never removes it.

Suggested fix: make "the program did not start" a failure, decided in one
place.

- Best: `rig run` builds with `zig build-exe` into the entry (cached), then
  spawns the binary itself. On any failure before the program starts (rig
  I/O, a Zig error, a spawn error), it prints a fixed marker such as
  `rig: the program did not run: ...` and exits with a reserved status.
  `CORPUS_BAD_RE` and matrix `BAD` match that marker.
- Stopgap: add to both regexes
  `failed to execve|^error: cannot (write|create|find)|NoSpaceLeft|AccessDenied|FileNotFound|NotDir`.
- Add a CLI test that runs a corpus-style check and a matrix cell with
  `RIG_BUILD_STORE` pointing at a file, and expects a failure.

## Medium-2: store pruning is non-atomic and races concurrent builds

`test/run` prunes with
`find "$RIG_BUILD_STORE" -mindepth 2 -maxdepth 2 -name used -mtime +N | ... | xargs -0 rm -rf`.

- **Deletion order:** readdir order inside an entry is
  `z/ o/ h/ tmp/ used package/` (checked with `ls -f` on 5 entries). So
  `rm -rf` removes `o/` (the binaries) before `h/` (the manifests). An
  interrupt (Ctrl-C, a killed run) between the two leaves the exact state
  from Repro A.
- **Race:** another worktree can touch `used` and start Zig on the entry
  after `find` has selected it. Its Zig sees a manifest hit while `o/` is
  being removed. That is a transient execve failure, which counts as a
  corpus or matrix pass (High-1).
- **Effect elsewhere:** behavior tests see the same state as a false red
  (`exit 1: failed to execve`), and that red is persistent too.

Verified:
- `rm -rf $E/o` then `rig run` fails with execve FileNotFound, rc=1, every
  time.
- After also `rm -rf $E/h`, the program rebuilds and runs.
- An interrupted *build* (SIGKILL at 0.5 s, 1 s, 2 s and 3 s) never poisons
  an entry. Zig writes the manifest last.

Fix:
- Prune by atomic rename first:
  `mv "$entry" "$RIG_BUILD_STORE/.trash.$$.$RANDOM" && rm -rf` that path.
  The entry then disappears in one step, and a concurrent build recreates
  it from scratch.
- Optionally, in `storeEntry`, treat `h/` present with `o/` missing as
  "remove `h/`".
- Optionally, take an advisory lock (the `used` file with `flock`) during
  the prune check.

## Medium-3: `cli/zig_cache` no longer tests the default output-directory build

`test/run` exports `RIG_BUILD_STORE`. `test/cli/zig_cache.sh` exists to
catch two programs whose packages sit at the same relative `RIG_OUT_DIR`
running each other's cached executable. Its `rig run` and `rig test` calls
now build in the store, and never in `RIG_OUT_DIR`. That is the mode every
user gets by default.

```bash
export RIG_BUILD_STORE=$SCRATCH/zstore RIG_TEST_OUT=$SCRATCH/zout
./test/run -j 2 cli/zig_cache                  # 1 passed
ls $RIG_BUILD_STORE | wc -l                    # 5 entries
find $RIG_TEST_OUT/cli/zig_cache -name '*.zig' # nothing: RIG_OUT_DIR never used
```

- A regression in the non-store path (`outputDir` /
  `zig_cache = dir/.zig-cache`) would now pass the suite. The whole
  behavior suite runs only in store mode. Only `run.sh`'s concurrency block
  and one line of `std_os.sh` still build without the store.
- test/README.md, in this same branch, says "a script about the output
  directory sets `RIG_BUILD_STORE=` for those commands". `zig_cache.sh` is
  such a script and does not.

Fix: in `zig_cache.sh`, run the existing checks with `RIG_BUILD_STORE=`,
then once more with a store, since both modes must keep programs apart.
Consider also a small default-mode smoke test (no `RIG_OUT_DIR`, no store,
`XDG_CACHE_HOME` set) for run, build and test.

## Low-4: discovery drops tests under symlinked directories

`find` without `-L` does not descend into symlinked directories. The old
globs did. The `oracle/tests` and `oracle/corpus` sets still use globs, so
the two would also diverge.

Repro: a synthetic tree in `$SCRATCH/tree`, with the old and new discovery
code extracted verbatim and compared by `$SCRATCH/cmp.sh`. Names with
spaces, hidden files and directories, `_`-prefixed CLI scripts, a
directory named `x.rig`, a directory without `main.rig`, non-ASCII names,
file symlinks and nested directories all produced identical lists. The
lists differed only for:
```
< behavior/a/symdir      test/behavior/a/symdir      (symlinked test dir)
< behavior/symarea/t     test/behavior/symarea/t.rig (symlinked area)
< corpus/csym            test/corpus/csym
```

There are no symlinks in the repo today (`git ls-files -s | awk '$1==120000'`
is empty). On the real tree the lists are byte-identical for no filter,
`corpus`, `R11a known`, `behavior/own` and `''` (2333, 6032, 70, 204 and
8012 lines). `rig pending`/`reject` doc blocks and `known/` go through the
same `select_tests` and are unaffected.

Fix: use `find -L`, or make discovery fail when it meets a symlinked
directory, so a test is never dropped silently. Also drop `2>/dev/null` on
`find`, or check its status: an unreadable directory now vanishes without
a message.

## Low-5: equiv base cache: two small gaps in the key and in what it stores

The key is otherwise complete:
- the old binary's sha256, which covers the embedded std, shims and runtime;
- the section and its args, the program's path and contents, and
  `RIG_SANITIZE`, `RIG_LEAK_TRACE` and `RIG_STD` (a non-empty `RIG_STD`
  disables the cache);
- every module reachable through `use NAME`, transitively, present or
  absent (`use std.X` is embedded).

I probed it through `OldCache.key`. Adding or editing a transitively used
module changed the key, and an unrelated file did not.

The two gaps:

- **Case-variant files.** On case-insensitive APFS, `use Lib` reads
  `lib.rig` and fails with "module `Lib` is the file `lib.rig`". Without
  that file it fails with "cannot read module `Lib`". The key only hashes
  "Lib.rig missing", so creating or removing `lib.rig` does not change the
  key (shown: identical keys before and after). A stale old result then
  causes a spurious diff. It could only hide a difference if the new
  compiler happened to print the stale text. Fix: for a missing name, also
  hash any listing entry whose `casefold()` matches.
- **Transient crashes are cached.** Only rc == -1 (a timeout) is left out.
  A base compiler killed by a signal under memory pressure (rc < 0) is
  cached for good, which gives persistent spurious diffs. Fix: cache only
  when `rc >= 0`.

Cache file appends are single short `write`s with `O_APPEND`, and a
truncated line yields at worst a spurious diff, never a match.

## Low-6: `--shard` notes (the partition is correct)

- **Partition verified:** the full no-filter-plus-`''` list (8012 ids) split
  into 4 shards gives 2025, 1942, 1998 and 2047 ids, with no duplicates,
  and their union equals the list. Each shard keeps the normal exit status
  (exit 1 on any fail or fixed). The prune runs before the shard cut, so it
  uses the full keep-list. Whole-program checks run only in shard 1.
  A shard with nothing to run:
  - exits 2 when a non-kind filter was given;
  - exits 0 when the filters are only kinds, or there are none, and the
    other shards cover the tests.
- **Cross-machine claim:** test/README.md says "on one machine or
  several". The awk `ord[sprintf("%c", c)]` hash is the same across awks
  only for ASCII ids. With non-ASCII ids, macOS awk 20200816 in a UTF-8
  locale and gawk/mawk on Linux can disagree, so a test could land in no
  shard. No ids are non-ASCII today (checked). Fix: run the hash awk under
  `LC_ALL=C`, or hash with `cksum`.
- **Matrix `--oracle --shard`:** this trips the coverage floor (false red):
  `test/matrix.py --oracle --shard 1/4` gives "FAIL coverage: 4650 decided
  functions, below the floor of 15911". Reject `--shard` together with
  `--oracle`, or scale the floor.

## Low-7: AGENTS.md wording (b9f91169)

It says what was asked, clearly: "One branch at a time per fact or
classifier", two branches only if they touch different facts or
classifiers, and "the second to merge first passes the full gates on the
combined tree: main with the first merged, plus the second."

Two nits:
- The old rule named "`src/ownership.zig` or typecheck's classification of
  expressions". The new body says only "the ownership checker". Keep
  "or typecheck's classification" so the classifier half is not read
  narrowly.
- "The second to merge" would read better as "each later branch to merge",
  to cover three or more branches.

## Notes (no action needed, recorded for the gate owner)

- **Store key (bf9c0824) is sound.** The key is the hash of the emitted
  output plus the Zig command:
  - every package file's path and contents (each module, std Rig modules
    compiled in, the std Zig shims, the embedded runtime, the `rig test`
    driver);
  - the zig path, the verb (run or build-exe), `-O` mode, `-lc` and the
    root.

  Consequences:
  - `RIG_SANITIZE` and `RIG_LEAK_TRACE` change the root module's contents.
    Verified: plain, sanitize, leak-trace and both give 4 distinct entries.
  - A different `ZIG` path gives its own entry (verified).
  - `RIG_STD` changes the shim and module contents.
  - The rig binary itself is covered through its output: a compiler change
    that emits the same package correctly shares the entry.
  - Zig version, target, the lib dir and the std files are not in the key.
    Zig's own manifest checks them.
  - Program args and the runtime env are not inputs to the build.
  - The only getenv calls in src/ are ZIG, RIG_STD, RIG_BUILD_STORE,
    RIG_OUT_DIR, XDG_CACHE_HOME, HOME, RIG_LEAK_TRACE and RIG_SANITIZE.
  - `writePackage` rewrites any file that differs from what is emitted
    before Zig runs, so the package Zig sees always matches the key.
  - Concurrent writers write identical bytes atomically
    (`createFileAtomic`), and builds killed mid-way leave usable entries.
- **f679a392 and `--prune`:** kept directories hold only build caches. The
  worker empties each output directory (except `.zig-cache` and
  `programs/*/.zig-cache`) before every test. `.stdout` and `.stderr` are
  overwritten by redirection, and results go to a fresh `mktemp` WORK, so
  nothing kept is read as a result. `test_prune.sh` prunes only private
  stores.
- **Docs:** docs/INTERNALS.md and test/README.md still say `rig build`
  "caches nothing, so it compiles the package in full every time", while
  `build_store.sh` shows `rig build` getting its own store entry. Recheck
  that sentence for store mode.
