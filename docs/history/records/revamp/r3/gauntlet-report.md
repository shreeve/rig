# Gauntlet report (2026-10-17)

PR: #301, https://github.com/shreeve/rig/pull/301 (draft; branch `gauntlet`;
commits 1af8411f2 and 511d34abe). Not merged.

## What changed

1. **Commits run nothing.** Nothing to remove: no `core.hooksPath`, only
   sample hooks, and nothing in the repo installs one.
2. **tools/check**
   - Every run includes the whole-program checks
     (`oracle classify vocab style`) along with the branch's ids, as one job.
     That adds about 13-15 s warm.
   - It runs on `cpuq run --local --cores 2-6`. A comment notes that
     `--local` goes once cpuq places hosts itself.
   - The rerun hints now give the same `cpuq run` form with
     `-j "$CPUQ_CORES"`. No `--cores 2` and no `-j 2` remain.
3. **Docs (HANDOFF.md, test/README.md)**
   - Both describe the tiers: tools/check on the Mac, tools/gate once per
     PR, and tools/deep when Steve asks.
   - A full suite never runs on the Mac. It goes to burst with
     `cpuq submit cpuq/suite.json`.
   - "cpuq run --cores 2" and "./test/run -j 2" are gone.
   - In gate.yml only a comment changed.
4. **tools/gate (T1)**
   - It refuses a draft PR and suggests `gh pr ready N`.
   - Path filter: if the PR touches none of src/, std/, rig.grammar, the
     build, the harness, cpuq/ or tools/gate, it says why and exits 0 with
     no post. A formal-only PR runs `lake build` locally and posts success.
   - Default is suite + corpus. The matrix runs only when the PR touches
     the ownership/emit/facts files or the matrix harness; the list is
     justified in a comment. `--matrix` forces it and `--no-matrix` skips it.
   - Before submitting, it cancels the older gates' live jobs for the same
     PR.
   - Push, commit-status and `--force` behavior are unchanged.
5. **tools/deep (T2, new)**
   - Runs only by hand, when Steve asks. Per the scope change there is no
     `--if-due`, timer or merge-count trigger.
   - Works in a clean ~/Data/Code/worktrees/rig/deep-main, reset hard to
     origin/main and cleaned.
   - Exits at once if main's SHA is unchanged since the last finished run;
     `--force` overrides.
   - Submits the suite, the corpus and the full matrix in parallel, with
     `--note "deep <sha>"`. json is skipped because no cpuq/json.json exists.
   - Posts `rig/deep` pending, then the final state. On a pass it moves the
     `deep-green` tag and pushes it.
   - On a failure it saves the logs and failing ids under
     `$(git-common-dir)/rig-deep/runs/<sha>/`.
   - `--bisect [SHA] [-- ID...]` runs a `git bisect --first-parent` from
     red to deep-green. Each step reruns only the failing ids
     (`cpuq submit cpuq/suite.json -- ids`) and failing matrix cells.
     Exit codes map as 0 good, 1/122/124 bad, anything else skip.
   - `--dry-run` works for both modes.
   - A mkdir lock with stale-pid takeover keeps two runs from overlapping.
   - It works in bash 3.2 and on Linux.

## Not done (out of scope)

- No GitHub branch rules or rulesets.
- gate.yml still doesn't block PRs. One option, mentioned only: while
  `rig/deep` is failure, gate.yml could fail PRs touching src/ unless they
  carry a `fix-main` label.

## Test results

- `tools/check 1`: 45 passed, 0 failed (after the final commit).
- Dry runs:
  - the tools/gate path filter (code, docs-only and formal-only branches);
  - tools/deep normal, `--bisect --dry-run` and `--if-due` (rejected, rc 2);
  - the SHA-unchanged exit.
- Real tools/gate on #301 (head 1af8411f2): PASS in 289 s, with no matrix
  because no matrix path was touched.
  - suite cd248f8f
  - corpus 4a712a46
  - required checks green
- Real tools/deep on main 98c4b4b26: PASS in 271 s.
  - suite b5a9ed00, corpus 46cf8ae2, matrix 448da379
  - The corpus and matrix were mostly carried over through `--delta` from
    #298's gate.
  - `rig/deep` success posted; `deep-green` pushed.
- The scope-change commit (511d34abe) only removes `--if-due`. Its rerun
  is `tools/check 1` plus the dry runs above.

## Decisions for Steve (defaults in brackets)

1. typecheck.zig stays out of the matrix path list because it changes too
   often. [keep out]
2. tools/deep uses the specs' `--delta`, where the design wanted no-delta.
   [keep]
3. The json tier is skipped until a cpuq/json.json exists. [skip]
4. tools/gate refuses draft PRs. [keep]
5. gate.yml blocks src/ PRs while main is red. [not now]
6. The AGENTS.md diff below lands after #299. [yes]

## AGENTS.md diff (against origin/agents-fast, #299)

```diff
--- AGENTS.299.md	2026-10-17 03:21:24.280624797 -0600
+++ AGENTS.proposed.md	2026-10-17 03:28:08.816075532 -0600
@@ -70,21 +70,31 @@
 ### Test in two steps
 
 **1. Smoke test on the Mac, while you work.** `tools/check N` runs the
-branch's own tests plus N% of the suite, chosen at random, on this Mac:
+whole-program checks (`oracle`, `classify`, `vocab`, `style`), the
+branch's own tests, and N% of the suite, chosen at random, on this Mac:
 `tools/check 1` is about 40 tests, `tools/check 5` about 200, and
 `tools/check 20` about 800. Use it as often as you like. A bug fix starts
 with a test that fails; `./test/run --delta <ids>` reruns just the tests
-you name.
-
-**2. Full test on burst, when we're happy.** `tools/gate` runs the whole
-suite, the corpus, and the matrix on burst against the pushed head and
-posts the result on the PR. Run it when Steve asks, or ask him first.
-If `main` ever fails, `git bisect run` with the failing test finds the
-commit, and the fix goes in on a new branch.
-
-**Nothing else runs unless Steve asks:** no full local suite, corpus,
-matrix, `./test/run json`, benchmark or check-speed guards, review
-agents, or expert panels.
+you name. A full suite never runs on the Mac: it runs on burst,
+`cpuq submit cpuq/suite.json`, and `cpuq submit cpuq/suite.json --
+<filters>` runs part of it there.
+
+**2. Full test on burst, when Steve asks.** `tools/gate` runs
+the suite and the corpus on burst against the pushed head and posts the
+result on the PR; it adds the matrix when the PR touches a classifier,
+the proofs, or emit, and skips a PR that touches nothing of `src/`,
+`std/`, `rig.grammar`, the build, or the harness. Run it when Steve asks,
+or ask him first. Merging `main` in again needs no new gate.
+
+**3. The deep gate on `main`.** `tools/deep` runs the suite, the corpus,
+and the full matrix against `main`'s head and moves the tag `deep-green`
+when they pass. Run it when Steve asks; nothing starts it on a schedule.
+When it fails, `tools/deep --bisect` finds the merge, and the fix goes
+in on a new branch.
+
+**Nothing else runs unless Steve asks:** no corpus or matrix on the Mac,
+no `./test/run json`, benchmark or check-speed guards, review agents, or
+expert panels.
 
 ### Spend tokens well
 
@@ -115,13 +125,15 @@
 tools/check 1                      # smoke test on the Mac: branch tests + 1% of the suite
 tools/check 5                      #   ... + 5%
 tools/check 20                     #   ... + 20%
-tools/gate                         # full test on burst: suite, corpus, matrix (when asked)
+tools/gate                         # full test on burst: suite, corpus, matrix by path (when asked)
+tools/deep                         # the deep gate on main: suite, corpus, full matrix (when asked)
 ```
 
 - **Nexus** is co-developed. `zig build` regenerates `src/parser.zig`
   with `../nexus/bin/nexus`, or another binary with `-Dnexus=PATH`.
-- **Shared machines:** heavy runs go through `cpuq run --cores 2 -- …`
-  with `-j "$CPUQ_CORES"`. Under load, rerun a timeout alone before
+- **Shared machines:** heavy runs on the Mac go through `cpuq run
+  --local --cores 2-6 -- …` with `-j "$CPUQ_CORES"`; full runs go to
+  burst with `cpuq submit`. Under load, rerun a timeout alone before
   trusting it.
 
 ## Map
```
