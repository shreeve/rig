I found where the 20–30 minutes go. On every pull request, CI reruns the same 4,202-test suite that burst has already passed. It runs on four 4-vCPU runners with no reuse of earlier results, and each shard compiles the compiler two or three times before any test starts. Shard 1 of PR #273 shows it.

# Rig CI forensic report

Evidence: runs 38949720611 (PR #273), 38945930668, 38941659902, 38935539225, 38934724410, 38930678987, 38930303574, 38926849191, 38926403391, 38923294812, 38922074159 and the cancelled 38951029435. That is 43 Ubuntu and 20 macOS shard-jobs, pulled from `gh api …/jobs` step timestamps and full logs. Local numbers come from `cpuq jobs --all` and `cpuq history` (Mac and pup). **M** = measured, **E** = estimate.

## A. Current state: PR #273 critical path (run 38949720611, shard 1, job 117137756722)

| Operation | Time (M) | % of 1,699 s | What it does / why it takes this long | Needed? |
|---|---|---|---|---|
| Queue (job created → started) | 3 s | 0.2 | Hosted runner pickup. Range over all runs: 2–30 s. | – |
| Set up job, checkout Rig | 3 s | 0.2 | Depth-1 fetch of the merge ref | yes |
| setup-zig | 9 s | 0.5 | Tarball from cache (0.6 s), xz extract (4.0 s), restore of the 304 MB Zig cache saved by main run 38945930668 (~4 s) | yes |
| Nexus: checkout, find commit, restore | 3 s | 0.2 | Cache hit. Build Nexus was skipped. | yes |
| **Build Rig** (`zig build`, shards.yml:65-66) | **236 s** | **13.9** | Full ReleaseSafe compile of the compiler, *without* `-Dself-check`. Its output is thrown away, see next row. | **no** |
| JSON data, core dumps | 1 s | 0.1 | Cache hit; "153 files present and verified" | yes |
| **test/run's own build** ("building rig" 18:49:20 → "running" 18:53:32) | **252 s** | **14.8** | `zig build -Dself-check=true` (test/run:818) recompiles the compiler because the options differ. Then `zig build oracle` (test/run:1368) compiles the compiler again as bin/rig-oracle. The two run one after the other, and each compile uses about one core (cpuq ACTIVE 1.0). | one build is |
| **Test execution** (1,145 tests, `-j 4`) | **1,177 s** | **69.3** | About 700 program tests, each a cold `zig run` (the build store starts empty). Shard 1 also compiles and runs the unit tests in the background (test/run:1185). | duplicate of burst |
| Post steps | 5 s | 0.3 | setup-zig save fails: "Unable to reserve cache … another job may be creating this cache" | – |
| Aggregator `test (ubuntu-latest)` (test.yml:38-44) | 5 s | 0.3 | Created at +1,693 s, runs `test success = success` | trivial |
| Auto-merge | 15 s | – | Check done 19:13:21, merged 19:13:36 | – |

- **Other shards in the same run:**

  | Shard | Build Rig | test/run build | Tests | Job time |
  |---|---|---|---|---|
  | 2 | 87 s | 165 s | 446 s | 724 s |
  | 3 | 189 s | 204 s | 607 s | 1,032 s |
  | 4 | 242 s | 253 s | 1,004 s | 1,532 s |

- **Last 8 completed PR runs:** 24.6–29.7 min wall.
- **Main pushes:** 28.3–38.8 min wall, which includes 296–458 s spent queued behind the previous main run. The `concurrency` setting at test.yml:16-18 serializes main runs.
- **Runner-minutes:** a PR run uses about 83 min. A main push uses about 179 min (73 on Ubuntu, 106 on macOS). That is about 262 min per merged PR.

## B. Top 10 bottlenecks (by wall-clock cost)

1. **CI duplicates burst.** CI's four shards ran 1,145 + 949 + 984 + 1,124 = **4,202 tests**. Burst's #273 suite (job 76a478d9) ran **"running 4202 tests"**, the same tests, on the same Linux, Zig 0.17.0 and latest Nexus, on a tree with main merged in. Burst also runs the corpus (10,937 tests) and the matrix (16,239 programs), which CI never runs.
   - Going by job-record ages (E: the age is when the job was submitted), burst's suite, corpus and matrix were green at about:

     | PR | Burst green | CI finished | Merged |
     |---|---|---|---|
     | #258 | 15:22 | 15:42 | 15:44 |
     | #265 | 15:59 | 16:12 | 16:13 |
     | #270 | 16:31 | 16:44 | 16:47 |
     | #273 (suite only) | ~18:58 | 19:13 | 19:13 |

   - So **CI adds about 13–20 min after the work is already verified.**
2. **Test execution with nothing reused:** 446–1,445 s per shard (M).
   - CI sets no `RIG_*` location variables, so test/run puts the build store and results cache in `rig/.git/` (test/run:791-815). Both start empty and are thrown away after every run. `--delta` is never passed.
   - Restoring the results cache would not help anyway. Its key hashes `zig env` (test/run:833), which includes the Zig executable's path, and setup-zig unpacks Zig under a random `_temp/<uuid>/` each run. The key also hashes the timeout, which is 300 in CI and 120 on burst.
3. **test/run's serial compiler builds:** 165–253 s per shard (M).
4. **The discarded Build Rig step:** 77–250 s per shard, median 217 s across 42 Ubuntu jobs (M).
5. **Shard imbalance.**
   - The hash split ignores how long tests take, and shard 1 also carries unit, classify, vocab and style (test/run:890-892).
   - On "slow" runners, shard 1's Test step took 1,248–1,445 s (n=10). Other shards on slow runners averaged 912–1,126 s.
   - On #273 the slowest shard's tests ran 368 s longer than the mean (M).
   - test/run sorts the longest tests first using `.zig-cache/rig-test/.durations` (test/run:1391). In CI that file lives in the checkout, outside the cached directory, so it is always empty. The ordering then falls back to "cli tests first".
6. **Runner speed lottery** (M).
   - Within a single run, Build Rig took 87 s on one shard and 242 s on another (#273), and 80/77 s vs 223/235 s in 38945930668.
   - Tests track it: runners with a fast build averaged 675–836 s of tests; runners with a slow build averaged 912–1,372 s.
   - The logs don't print the CPU model or nproc, so I can't confirm the cause. It is consistent with mixed hardware SKUs.
7. **The unit-test compile on shard 1** (`zig build test -Dself-check=true`, a ReleaseSafe compile of the whole compiler) competes with the tests on 4 vCPU. Its cost is not separable in the logs (E: about 4 core-minutes).
8. **The Zig cache resets to empty, and the cache quota is over its limit.**
   - The setup-zig key is per run (`…--<run_id>-1`). Only the first shard to finish can save it; every other shard logs "Unable to reserve cache".
   - Above 2 GB the cache is wiped and saved empty. Main run 38913923442 logged "Cache directory reached 2335349338 bytes … clearing cache" and left a 0 MB main cache, so following runs restored nothing and the size climbed again from 73 MB.
   - The repo holds **10.79 GB of caches, above the 10 GB limit**. Most are PR-scoped (`refs/pull/N/merge`, 74–445 MB each) and no other ref can read them, so main's caches get evicted.
   - The Zig cache only helps when `src/` didn't change. Then Build Rig takes 0–4 s (38922074159 shard 3; 38923294812 macOS) instead of 80–250 s.
9. **Main runs serialized** by the concurrency group: queued 296, 318 and 458 s (M). This doesn't block merging, but it delays main's result and the macOS signal.
10. **Fixed per-job overhead:** 15–30 s on Ubuntu and 40–60 s on macOS (setup-zig 23–36 s, post-save 11–23 s). When Nexus main changes, all 4 (or 8) shards each rebuild Nexus: 37–157 s each (run 38902390423).

**Other findings:**
- **The one CI failure in this window was flaky** (main run 38926403391): `cli/match_scale — 4000 arms took 0.664s … more than 8 times as long`. It is a timing-sensitive test failing on a loaded 4-vCPU runner, not a bug.
- **The comment at test.yml:26-28 is wrong.** It says every PR's fast gate "already runs on an Apple Silicon Mac". burst-brief.md sends the suite to burst (Linux); the Mac runs only builds, single tests, vocab, style and unit. A full macOS suite runs per merge only in post-merge CI, plus the deep gate.
- **Burst builds the compiler twice too.** cpuq/suite.json's setup runs `zig build`, then test/run runs `zig build -Dself-check=true`.
- **Ubuntu on main is 100% redundant.** PR #273's tested merge ref cc06ca4 and main's merge commit dc3ea3a have the **same tree** (6e45c84). The post-merge Ubuntu run retests identical bytes.

## C. Proposed optimizations

| # | Exact change | Saving | Confidence | Downsides | Complexity |
|---|---|---|---|---|---|
| 1 | Burst gate posts its result to GitHub as the merge check (see D) | 13–20 min per merge (M from timeline); about 156 Ubuntu runner-min per merge | high | Needs Steve's ruleset decision or a dispatch workflow. Fork PRs need another path. | medium |
| 2 | shards.yml:66 → `zig build -Dself-check=true`, so test/run's build hits the cache. Same fix in cpuq/suite.json setup (owned by the cpuq session). | 77–250 s per shard; 236 s on #273's critical path (M) | high | none | trivial |
| 3 | Build rig and the oracle in one invocation so they compile in parallel (e.g. `zig build -Dself-check=true install oracle`; test/run then finds both cached) | ~80–120 s (E) | medium | Builds the oracle with self-check on (today test/run:1368 builds it without), which needs checking | low |
| 4 | In CI, set `RIG_RESULTS_CACHE=` (empty) | 2 `rig emit` + hashing per passing program; under 1 min per shard (E) | medium | none | trivial |
| 5 | Move unit (and the whole-program checks) to their own parallel job; balance shards by `.durations` from the last main run (needs `--shard` to read durations) | shard 1 from 1,177 s toward the ~809 s mean: ~6 min (E) | medium | test/run code change | medium |
| 6 | Skip Ubuntu on `push` to main (keep macOS), or skip it only when a passing PR run with the same tree exists | 73 runner-min per merge; ends the 5–8 min main queue (M) | high | Loses the post-merge Ubuntu run, which the deep gate already covers | trivial |
| 7 | Fix setup-zig caching: save only on main (`use-cache` / key input; verify which inputs v2 supports), raise `cache-size-limit` or prune; stop PR-scoped saves | 80–250 s ×2 per shard on PRs that don't touch `src/` (M ranges) | medium | Reading setup-zig v2's options is needed | low |
| 8 | 8 Ubuntu shards instead of 4 | ~5–9 min (E). The ~8 min of fixed per-shard compile on slow runners stays. | medium | More concurrent jobs (free plan: 20, macOS 5) | trivial |
| 9 | Print `nproc; lscpu` in each shard | turns finding 6 into a measurement | – | none | trivial |

Options 2–9 together would take hosted CI to about 12–15 min (E). Only option 1 removes the duplicate.

## D. Fastest architecture

**Edit and check on the Mac (M5, 10 cores):**
- `zig build` takes 37–60 s (M, cpuq rig:build); pup takes 71–86 s.
- Run targeted tests through `cpuq run`.

**Gate on burst (`cpuq submit`):**
- Suite `--delta` on burst: job wall 5m12s–16m26s (median about 12 min). test/run's own time: 309–842 s with ~1,900–1,970 carried over, 408–762 s cold (M).
- Corpus `--delta`: 15–25 s warm, 4m45s–6m19s cold (M).
- Matrix `--delta`: 17–21 s warm, 33–47 min cold (M).

**Publish the verdict.** On PASS, the gate wrapper posts `POST /repos/shreeve/rig/statuses/<head-sha>` with context `rig/gate`, and the tree hash in the description. Then the PR merges within seconds. Two ways to make that the required check:

- **(i) Steve changes ruleset 24043005.** Its required contexts are `test (ubuntu-latest)` and `test (macos-latest)` with `integration_id: 15368`, which is GitHub Actions. A status posted with a token comes from no app, so it does **not** satisfy that rule today. Requiring context `rig/gate` from any source would. Only users with write access, today just `shreeve`, can post statuses, so a fork can't fake it.
- **(ii) No ruleset change.** The gate fires `workflow_dispatch` on the branch. A ~5 s Actions job named `test (ubuntu-latest)` checks for a successful `rig/gate` status by `shreeve` on that SHA, and a matching `test (macos-latest)` job does the same. Both checks then come from integration 15368.

**macOS:**
- Run the suite on the Mac per PR, if wanted; it isn't run there today.
- Or keep macOS hosted CI on main only, after the merge.

**Fork PRs:**
- Keep hosted shards.yml behind `if: github.event.pull_request.head.repo.fork`, or run it by hand.

**Self-hosted runners (B): not recommended.**
- shreeve is a personal account, so there are no runner groups to restrict which workflows may use a runner.
- `pull_request` runs the workflow YAML from the PR itself.
- The fork-approval policy is `first_time_contributors`, so returning contributors run without approval.
- A persistent runner on pup or burst would get `--delta` and the store (CI ≈ 5–13 min), but it would still duplicate the gate and expose the machines to code from PRs.

**Releases (D):** v0.2.5–v0.2.9 have **0 assets**. `zig build -Dtarget=… --release=safe` cross-compiles from the Mac, then `gh release create vX dist/*`.

**Dropping Actions entirely (E):** practical for Steve's own PRs under (i). It loses the clean-room cold run and the fork path, so keep shards.yml as a manual/nightly workflow.

## E. Target performance (E, from measured parts)

| Case | Today | Achievable | Assumptions |
|---|---|---|---|
| Small change, no `src/` change | 25–30 min | 2–6 min | burst suite `--delta` with the double build fixed; status posted at once |
| Normal compiler commit | 25–30 min CI after a 10–13 min burst gate | 10–13 min total | CI removed from the merge path |
| Soundness-classifier change | same, plus matrix | 35–50 min | cold matrix on burst dominates (M 33–47 min) |
| Clean build | 77–250 s on CI | 37–60 s on the Mac, 71–86 s on pup (M) | |
| Release build | none published | ~2–5 min | ~1 min per target compile (E) |

## F. Action plan, in order

1. **Now, trivial:**
   - shards.yml:66 → `zig build -Dself-check=true` (−236 s on the #273 critical path).
   - `RIG_RESULTS_CACHE: ""` in the Test env.
   - Print `nproc`/`lscpu`.
   - Ask the cpuq session to fix the same double build in cpuq/suite.json.
2. **Drop Ubuntu from `push` runs** (test.yml:21-24 gets `if: github.event_name != 'push'`); keep macOS.
3. **Gate-status bridge:**
   - A cpuq wrapper posts `rig/gate` on PASS.
   - Add a dispatch-verifier workflow (option ii), or Steve changes the ruleset (option i).
   - Run hosted shards only for forks or by hand.
4. **Stop PR-scoped Zig cache saves** (and the 2 GB wipe): the repo is over its 10 GB cache limit.
5. **For whatever hosted CI remains:** build rig and the oracle in parallel, give unit its own job, balance shards by durations.
6. **Publish release assets** from the Mac with `gh release create`.

**What stops Steve's goal today:**
- Ruleset 24043005 accepts only GitHub Actions (integration 15368) for the two required checks.
- Nothing posts burst's verdict to GitHub.
- shards.yml always runs a cold, full suite.
- Results-cache keys can't move between machines (Zig path and timeout in the key).

**Evidence I couldn't get:**
- Runner CPU and nproc (not in the logs). The macOS runner's 3 cores is GitHub's documented spec, not measured.
- How test/run's 252 s splits between the self-check build and the oracle build (no timestamps between them).
- Per-test durations on burst.
- Exact burst timestamps: I inferred them from job-record ages.
- Whether burst tested exactly cc06ca4's tree: the cpuq digest can't be checked.

I changed nothing. My working data is in `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad/ci/` (job JSON, shard logs, `burst-jobs.txt`).