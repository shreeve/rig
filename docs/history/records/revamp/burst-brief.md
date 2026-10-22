Machine rule for Rig agents (cpuq 0.22.1, 2026-10-15). The cpuq session owns how tests run; this brief follows its instructions.

**Heavy runs (matrix, full suite, corpus) go to burst through `cpuq submit`,** as a background command from your own worktree:
```
cpuq submit cpuq/suite.json  --note "#<PR> <branch>"
cpuq submit cpuq/corpus.json --note "#<PR> <branch>"
cpuq submit cpuq/matrix.json --note "#<PR> <branch>"
```
Options go before `--`; the job's own arguments (a test filter) go after it: `cpuq submit cpuq/suite.json --note "#236 hashfast" -- FILTER`. The last line of the output is the verdict.

The specs (`cpuq/*.json`, owned by the cpuq session; never edit them) set the labels, the cores, the packs (zig 0.17.0, nexus@latest), the shared caches, `--delta`, and the JSON test data. You don't build Nexus or pass `RIG_RESULTS_CACHE` yourself.

**Ad hoc runs on burst** (a probe batch, a single test file, anything no spec covers) use `cpuq run --spill-to burst --label rig:probe --note "#<PR> <branch>" --cores 2-8 -- sh -c 'export RIG_BUILD_STORE=$HOME/cpuq-spill/c/rig/rig-build-store; …'`. Always export that `RIG_BUILD_STORE` (the shared store the specs use): without it test/run builds its store inside the spilled copy's trimmed .git, and those grew 16–41 GB each. A spilled copy lives at ~/cpuq-spill/s/<worktree>-<hash>; use relative paths or `$NEXUS`. `cpuq clean` removes copies unused for 3 days (`cpuq clean --dry-run --host burst` shows what).

Rules:
- **The spec comes from your own worktree.** Never point at another checkout's path: `submit` ships the git top of the repo the spec sits in, so you'd test that checkout's code. If `cpuq/` is missing (#234 not yet merged), run `git checkout origin/cpuq-specs -- cpuq/` in your worktree; after #234 lands, `git merge origin/main` brings the same files.
- **Note:** always `--note "#<PR> <branch>"`, e.g. `--note "#236 hashfast"`. Open the PR as a draft (`gh pr create --draft`) before the first burst run, so every note carries its number. To fix a note on a running job: `cpuq note rig:suite "#236 hashfast" --host burst`, or the PID from `cpuq status --host burst` if several run.
- **Merge first:** merge origin/main into your worktree before submitting.
- **One burst run at a time per agent.** burst takes three at once, and its queue holds the rest.
- **On the Mac,** at `-j 2`, through `cpuq run --local --cores 2` (cpuq 0.26: a `cpuq run` without `--local` may spill to pup or burst, so anything whose output must land in your Mac worktree, such as `zig build` of bin/rig or Mac timing, needs `--local`; work that can run anywhere may use `--spill`): builds, single tests, vocab, style, unit (`zig build test`), and anything macOS-only. Never send macOS-only work to burst.
- **Progress and results:** `cpuq jobs`, `cpuq job last [--wait --max-wait S] [--tail N]`, `cpuq status --host burst`. To stop or pause your own job: `cpuq stop|pause|resume <PID> --host burst`, or `cpuq job ID --cancel`.
- **Report to me** any run that fails to start, prints NOT RUN, or exits 125.
- **Waiting:** every wait has a bound. Run `submit` as a background command and you'll be notified when it exits.
