I've built the CI redesign and opened it as PR #277, marked ready and not merged. The demo worked: once burst passes, both required checks go green about 10 seconds after `rig/gate` is posted, and every forgery attempt failed. But #277 cannot produce its own required checks, so Steve has to choose a landing path (first item under "Decisions for Steve").

One fact changed the demo plan. Since 2025-12-08, `pull_request_target` always runs the default branch's copy of the workflow ([GitHub changelog](https://github.blog/changelog/2025-11-07-actions-pull_request_target-and-environment-branch-protections-changes/)). So a scratch base branch in shreeve/rig can't host the verifier: PR #278 into `gate-demo-base` got no gate run. With Steve's OK, I ran the demo in **shreeve/rig-gate-demo**. It is now public and has a copy of ruleset 24043005, which is enforced. Its content is the #277 tree plus one doc line, and the nightly schedule is removed. Its PR #1 is left open in the CLEAN state. The repo is still there for Steve to delete. #278 is closed and its branches are deleted.

## What I built (all in #277)
- **`tools/gate`** (231 lines, runs on the Mac's bash 3.2):
  - **Refuses** unless the worktree is clean, nothing ignored would ship (line 73), HEAD is the pushed PR head and contains the base (line 100), and `tools/gate` and `cpuq/` are unchanged unless `--allow-gate-changes` is given.
  - **Tests:** submits suite, corpus and matrix (line 123) and cancels the rest on the first failure.
  - **Posts** `rig/gate` on the exact SHA (line 109): success carries the tree and job ids; a test failure posts `failure`; an infrastructure verdict posts `error`.
  - **Then** re-runs the PR's gate run (line 212), waits for both checks, and prints each phase's time.
  - `GATE_REMOTE` picks the remote; the `gh` credential never leaves the Mac.
- **`.github/workflows/gate.yml`** (the verifier):
  - Runs on `pull_request_target`, checks out nothing, and its token can only read statuses.
  - Passes only if the newest `rig/gate` on the head is success, posted by the hard-coded `TRUSTED: shreeve` (line 52).
  - Its jobs are named `test (ubuntu-latest)` and `test (macos-latest)` for internal PRs, with a different name for forks, and run with `fail-fast: false`.
- **`test.yml`** (the cold pipeline): triggers are fork PRs, nightly at 09:17 UTC, and manual; the push-to-main trigger is gone. Its jobs carry the required names only for fork PRs.
- **`shards.yml`:**
  - One `zig build -Dself-check=true install oracle`.
  - setup-zig's own caching is off (`use-cache: false`); caches are restored with explicit steps and saved only by non-PR runs on main, under content keys.
  - Prints nproc and lscpu; sets `RIG_RESULTS_CACHE=""`.
- **`test/run`:**
  - The oracle now builds with `-Dself-check=true` (line 1370), so one build makes both binaries. On the corpus oracle set (13,862 programs) the verdicts were identical and CPU time 4% higher.
  - A json group's cache key now includes Python's version.
- **`test/cli/results_cache.sh`** and docs: new cache cases; test/README.md gets "The merge gate and CI"; AGENTS.md gets a "How merging works" section, a Workflow line and Map rows.

## Demo timeline (rig-gate-demo PR #1)

| Run | Push → verifier fails | corpus | suite | matrix | status → green | Push → green |
|---|---|---|---|---|---|---|
| Warm (doc-only change) | 3 s to start, 8 s to finish, PR BLOCKED | 76 s | 307 s | 20 s | 2 s re-run + 11 s, PR CLEAN | **7 min 19 s** |
| Run 1 (my test/run change invalidated the suite and corpus cache) | — | 381 s | 568 s | 1,433 s | 13 s | 40 min |
| Run 2 (a cpuq upgrade invalidated the matrix cache) | — | 24 s | 260 s | 2,189 s | 12 s | 41.5 min |

- **Jobs run one at a time:** cpuq does not run one worktree's jobs at once; it reports "waiting for its copy", so gate time is the sum of the three jobs.
- **#277 itself:** I ran `tools/gate --no-matrix --allow-gate-changes` on its head 75eaab7. The suite passed (job ee7e5487), and so did the corpus (job 25adff57). That left a real `rig/gate` success status on that commit; since then I've pushed two commits that change only how tools/gate finds the gate run and the json key. That run also found a bug when no gate workflow exists on main yet, which is now fixed and tested.

## Security

| Threat | Why it fails | How it was shown |
|---|---|---|
| No status on the head | Verifier fails: "waiting for rig/gate from burst" | Run 38964939378 |
| Status on an older SHA (push after the gate) | Status is bound to its SHA | Same run, on the new head 54f93b8 |
| PR edits gate.yml to always pass | GitHub runs main's copy | Run 38969972136 printed main's error, not the forged echo |
| PR adds its own workflow reporting `test (…)` success | A failing check of the same name still blocks, even when the forged success finishes later | PR state BLOCKED with both present |
| Success posted by an untrusted login | Creator check; only users with write access can post statuses at all | Main set to trust a fake login: "posted by shreeve, who is not trusted" |
| Verifier can't run at all | Fails closed | While the repo was private, billing stopped the jobs and they reported failure |
| Branch edits `tools/gate` or `cpuq/` specs | Refused without `--allow-gate-changes` | — |
| Stray or ignored files would be tested | Refused | — |
| Reaching credentials | No secrets anywhere; no PR code is checked out | — |
| Skipped required check | Skipped jobs show their name expression unevaluated, never a required name | Check-run lists on #278 and demo PR #1 |
| Fork PR | Not testable (no second account) | Reasoning from the `if` conditions |

On forks: they are still forgeable exactly as today, because their own YAML can name jobs `test (…)`. Only Steve merging guards that.

## Cache invalidation (`--delta`)
Every run re-runs `rig check` and `rig emit`; the key is the emitted package, so a compiler change either changes a package or cannot change a run. Each row was tested in `results_cache.sh` and with the real compiler in a scratch copy (E1–E10).

| Change | In key? | Result |
|---|---|---|
| emit.zig changes emitted Zig | via package | not carried, both behavior tests FAIL |
| Diagnostic text only | correctly no | runs carried, rejection FAILS |
| runtime.zig | via package | FAIL with a behavior change; re-runs with a comment |
| std/math.rig | via package | only the program using it re-runs, and FAILS |
| std/math.zig shim | via package | re-runs |
| rig.grammar or Nexus | via package | a comment carries over correctly; check and emit run fresh |
| Zig version (same path, or other path) | `zig env` and `ZIG` | not carried |
| `# expect`, `# expect-panic`, `# error:` | entry file / never cached | FAIL |
| test/run itself | yes | not carried |
| Python (json groups) | **was missing; added** | carried only when unchanged |

## Cold pipeline (manual run 38960265391, Ubuntu + macOS, about 30 min wall)
- **Compile before tests, per Ubuntu shard:** 154–282 s, down from 252–495 s on #273.
- **test/run's own build:** 1–2 s on Ubuntu (17 s on macOS), down from 165–253 s.
- **Slowest Ubuntu shard:** 1,209 s vs 1,699 s, though runner speed varies.
- **Runners:** Ubuntu mixes AMD EPYC 9V45 and 7763 at 4 vCPU; macOS is an M1 with 3 cores. I didn't balance shards by duration; it isn't cheap.

## For the cpuq session
1. A worktree's jobs run one after another on its copy; running them concurrently would cut gate time to roughly the slowest job.
2. `test/matrix.py`'s key includes the cpuq version (`CAP_MODE`), so every cpuq release turns the next matrix into a cold run (24–36 min, seen twice). A cap protocol version would avoid that.
3. Suite setup could run `zig build -Dself-check=true install oracle` so the oracle compiles in parallel (needs #277).
4. Putting the shipped snapshot's git HEAD, tree and a clean flag in `cpuq job --json` would let the gate bind verdicts from cpuq's own record.
5. About 60 s of setup per job: the corpus job took 76 s for 14 s of tests.
6. The gate submits three jobs at once, against the "one burst run per agent" rule; please confirm that's fine.

## Decisions for Steve
1. **Landing #277:** it needs one of two paths.
   - Merge a small PR adding only gate.yml first; the old pipeline gives that PR its checks, and #277 then lands through tools/gate. I can open it.
   - Or make a one-time ruleset change.
2. **Is the matrix always required?** I recommend yes: it costs 20 s warm, and runs cold only when emitted code changes or cpuq is upgraded. `--no-matrix` exists and is recorded in the status; the verifier could also refuse such a status.
3. **Up-to-date branches:** the ruleset doesn't require branches to be up to date, so the merge result can differ from the tested head if main moves after the gate. Turning that on would make them identical.
4. **Fork PRs:** since a failing check blocks regardless of other successes, the verifier could require `rig/gate` on forks too, with Steve gating them by hand. That would make forks unforgeable.
5. **Behavior changes he should know about:**
   - Every push shows failing checks (and their notifications) until the gate passes.
   - A re-run uses the verifier as main held it when the original run started.
   - macOS is now tested nightly only, not per merge.
6. **Clean-up:** delete shreeve/rig-gate-demo. Old PR-scoped caches (10.79 GB in all) will age out after 7 days, or can be deleted now.

Everything is in `/Users/shreeve/Data/Code/rig/.claude/worktrees/agent-a9f0b185d001a0104` on branch `gatebridge`; the main files are `tools/gate` and `.github/workflows/{gate,test,shards}.yml`. Logs and experiment output are in `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad/gate/` (`run1.log`–`run3.log`, `run277.log`, `exp.log`).