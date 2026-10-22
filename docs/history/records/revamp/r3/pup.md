# pup: the Linux test machine

pup is a Linux x86_64 machine (22 cores, Ubuntu, kernel 7.0) that runs
Rig's tests next to the Mac. It is someone's real machine: everything
lives in `~/.local` and `~/Data/Code`, nothing uses sudo, and no shell
profile was changed (the scripts put Zig on PATH themselves). Leave the
`~/Data/Code/duckdb*` directories alone.

## What is installed

| Path on pup | What |
|---|---|
| `~/.local/zig-0.17.0/` | Zig 0.17.0, the official x86_64-linux tarball, sha256 checked against ziglang.org's index (the Mac has 0.17.0 too). The older `~/.local/zig/zig-x86_64-linux-0.16.0` was already there and is not used. |
| `~/Data/Code/nexus/` | Nexus (GitHub main), built with `zig build -Doptimize=ReleaseSafe`; `bin/nexus` is 2.0.0. |
| `~/Data/Code/rig/` | Rig, cloned from GitHub; `main` is checked out. Remotes: `origin` (GitHub) and `mac` (the bare repo below). |
| `~/Data/Code/rig.git` | A bare repo the Mac pushes to (Mac remote `pup` = `ssh://pup/home/shreeve/Data/Code/rig.git`). |
| `~/Data/Code/rig-wt/<branch>/` | One worktree per branch run through `pup.sh`, sharing `~/Data/Code/rig`'s objects; `.logs/`, lock and pid files sit beside them. |
| `~/Data/Code/rig-bases/<sha12>/rig` | Base compilers built by `pup-base.sh`. |

cpuq was already installed (`~/.local/bin/cpuq`, budget 20 cores);
`cpuq status --host pup` shows pup's queue from the Mac.

## Scripts (on the Mac, in `.git/revamp/r3/`)

**`pup.sh <branch> <cmd...>`** pushes the branch's commit to pup, checks
it out (detached) in `~/Data/Code/rig-wt/<branch>`, and under cpuq
(`--cores 4-16 --priority high --label rig-pup:<branch>`) runs
`zig build` and then `<cmd>`, streaming the output. It exits with the
command's code; 125 means the push, checkout or build failed, 255 that
ssh failed. `<cmd>` is shell code for bash on pup, as with ssh, so
quote what pup should expand:

```bash
pup.sh my-branch ./test/run -j '"$CPUQ_CORES"' doc
pup.sh my-branch 'python3 test/matrix.py -j "$CPUQ_CORES"'
pup.sh --rm my-branch       # after merging: drop its pup worktree and branch
pup.sh --prune [branch]     # delete test outputs in the worktrees
```

Only committed work travels. Runs on one branch wait for each other.
Ctrl-C (or TERM) stops the job on pup. `PUP_CORES` (`4-16`, or a fixed
count) and `PUP_PRIORITY` (`normal`, as cpuq asks for bulk work) override the cpuq request.

**`pup-gates.sh <branch> <log-prefix>`** runs the four gates (suite,
corpus, matrix, `zig build test` with a fresh cache) and
`./test/run oracle doc vocab` on pup, one after another at
`-j $CPUQ_CORES`, and writes `<prefix>.sum .suite .corpus .matrix .unit
.odv` on the Mac. The `.sum` is gates.sh's, with each gate's time. It
exits 1 if a gate fails. It then deletes the worktree's test outputs
(`PUP_KEEP_CACHE=1` keeps them).

```bash
pup-gates.sh my-branch .git/revamp/r3/logs/my-branch-pup
```

**`pup-base.sh <commit>`** builds the compiler at any local commit on pup
(it does not need to be on GitHub or a branch) and prints its path, for
`test/equiv.py`:

```bash
base=$(pup-base.sh main)
pup.sh my-branch "python3 test/equiv.py $base bin/rig -j \"\$CPUQ_CORES\""
```

`pup-lib.sh` holds what the three share. pup's login shell is zsh, which
reads `$x:r` differently from bash, so the scripts never hand it shell
code: the script and each argument travel base64-encoded to bash.

## How Linux differs from the Mac

- **Backend.** On x86_64 Linux a debug build uses Zig's own x86_64
  backend and linker, not LLVM (the Mac, on aarch64, uses LLVM). That
  holds for `bin/rig` and for every test program the suite builds, so
  pup exercises a second code generator; CI's ubuntu runner does the
  same. Builds are fast (`zig build` of Rig in about 2 s) and debug
  executables are large (about 12 MB each).
- **Disk.** A suite + corpus run leaves about 40 GB of test executables
  in the worktree's `.zig-cache/rig-test` (the Mac's is about 14 GB).
  pup had 94 GB free. `pup-gates.sh` deletes them afterwards;
  `pup.sh` warns below 40 GB free and refuses below 15 GB.
- **Skips.** `zig build test` skips 2 tests on pup (124/126) and 1 on
  the Mac: the two stack-reserve tests run only on aarch64 (macOS and
  Linux). `test/cli/stack_guard.sh` passes without running anything
  off aarch64 macOS.
- **Load.** `./test/run -j 16` drives the load to about 50, since each
  test's Zig build uses several threads; cpuq's load valve then holds
  new jobs back until it drops.
- **cpuq right-sizes a range by the label's history.** A `--cores 4-16`
  request is capped near the median number of cores its label has
  used, so after small commands (`pup.sh b true`, a doc run) the next
  runs on that branch may be granted only 4. A fixed count is not
  right-sized: `PUP_CORES=16 pup-gates.sh ...` takes 16.

## Results on main (d3504c38, 2026-10-06)

All green, same counts as CI expects; every failure count is 0.

| Gate | -j 16 (setup run) | -j 4 (`pup-gates.sh`, `logs/pup-main.*`) |
|---|---|---|
| suite | 2650 passed, 7 pending, 175 s | 288 s |
| corpus | 6032 passed, 314 s | 502 s |
| matrix | 3427 programs: 1368 ran clean, 2059 rejected, 0 failed; 124 s | 167 s |
| `zig build test` (fresh cache) | 124/126 passed, 2 skipped; 8 s | 7 s |
| oracle doc vocab | | 322 passed, 7 pending, 41 s |

The whole `pup-gates.sh` run took 17 minutes at -j 4. An equivalence
run (`pup-base.sh e8e0fa87`, then `test/equiv.py` on main 0cbf7e7a at
-j 8) took 3.5 minutes: 8311 programs, 12 differ (the new tests and
probes of the commits in between).

## Sharing pup

Em runs timing-sensitive benchmarks on pup under the `pup-bench` cpuq lease. Rig runs its pup jobs under cpuq again (user decision, 2026-10-07, after a day outside it); cpuq holds them during exclusive timing windows, keeps the 6 GB floor and caps each job tree at 24 GB. Never run Rig work on pup outside pup.sh.

## cpuq 0.8 (2026-10-07)
Admission is by measured CPU use; `--cores` is optional (keep `-j "$CPUQ_CORES"`). From 0.8.1, pup has a 6 GB memory floor and a **24 GB per-job cap** (raised from 12 for our gates): a gates run is one job. cpuq will record per-job peak memory; if gates near 24 GB, split them into separate jobs rather than lowering PUP_CORES. Loop grids need headroom within that.
