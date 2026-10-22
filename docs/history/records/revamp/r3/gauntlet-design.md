# Test strategy and merge queue: Rig's gauntlet (expert report, 2026-10-17)

Read-only review. Sources: rig `tools/gate`, `tools/check`, `.github/workflows/{gate,test,shards}.yml`,
`cpuq/{suite,corpus,matrix}.json`, `test/run`, `test/matrix.py`, `test/README.md`, `AGENTS.md`,
`HANDOFF.md`, git log, `gh pr list`, 346 rig:* job records in `~/.local/state/cpuq/jobs`
(10-15 10:38 to 10-17 01:18), the Mac history in this directory.

## What the data says

**Cadence.** About 30 PRs in 19 hours, merged 1 to 60 minutes after they open, one merger
(Steve). About a third are docs-only (`formal/`, FORMAL-RIG, ROADMAP, README). PRs get main merged
in again and again ("Merge remote-tracking branch 'origin/main' into std-bigint" five times), and
every push used to need a new gate: #287 was gated 5 times, #285 3 times.

**What each burst job finds (36 h):**

| job | runs | burst-hours | FAIL | timeout | what failures it caught that the suite didn't |
|---|---|---|---|---|---|
| suite | 170 | ~29 | 54 | 0 | (it is the signal) |
| corpus | 81 | ~6 | **0** | 0 | none |
| matrix | 91 | **~38** | **1** | 4 | about one in 36 h |

The matrix is the biggest single cost and the slowest phase of every gate (median 30 min against
the suite's 10), and it found almost nothing at PR time. The corpus never failed. In practice the
per-PR gauntlet is "the suite, plus 20 to 80 minutes of near-certain PASS".

**The 54 suite FAILs, sorted by cause** (from each job's tail.log):

| cause | jobs | examples | is it the PR's code? |
|---|---|---|---|
| Infrastructure / setup / flaky | ~22 | `ln: ... Already exists` and `curl (23)` in `setup` (4 jobs failing in 2 to 7 s); JSON_REQUIRE_DATA missing (7, 10-15, fixed since); `cli/results_cache timed out after 120s` (6); "the test runner died" (4 jobs); `cli/test_prune` (2); `no_crash_report` timeouts; stack_overflow exit 139 vs 134 | no |
| Bookkeeping: `oracle/* UNLISTED ... add to test/oracle/rejections` | 11 | an agent adds a corpus or reject test and forgets the list | yes, but a seconds-long local check finds it |
| Real regressions | ~21 | changed diagnostic wording (`reject/*`, `doc/SPEC/L3738`), Zig compile errors in emitted code, `unit`, `classify`, `cli/lsp` | yes |

So roughly 40% of FAILs are noise, and 20% are deterministic mistakes the agent could catch
locally in seconds. Only about 40% needed burst at all. A failing suite run takes a **median 10.4
minutes**, as long as a passing one: the suite fails late, because `test/run` starts the longest
tests first, and a setup failure is reported as FAIL (cpuq's `submit.zig:1375` joins setup and run
as `{setup} && {run}`). `result.json` has `failures: []` for every Rig job because the specs set no
`report`, so cpuq cannot tell a flake from a regression, and neither can a rerun policy.

**Where the 45 to 90 minutes come from.** The Rig docs contradict each other:
- `AGENTS.md` "Test fast" says nothing heavy runs unless Steve asks, but its Workflow block lists
  `./test/run -j 2` and "heavy runs go through `cpuq run --cores 2`".
- `HANDOFF.md` "The fast gate, per round" says to run **`./test/run --delta`** (the full suite) every
  round, and "Full runs go to pup".
- `tools/check` hard-codes `cpuq run --local --cores 2`.

An agent that follows HANDOFF runs the full suite on the Mac at -j 2. The Mac history shows
`./test/run --delta -j 2` taking **41 min** (examples:delta 0.69 h, intelligent-gates 0.64 h), the
same work burst does in 5 to 10. Then `tools/gate` runs in the foreground (median 13 min, p90 41 min,
because the matrix is in it), and a failure starts the cycle again. 41 + 13 to 41 + a rerun is
exactly the 45 to 90 minutes Steve sees.

**What protects main today.** Since #294, nothing at PR time unless someone asks. On main:
`test.yml`'s nightly cold run on GitHub's runners (the suite only, in shards; no corpus, no matrix,
no JSON-full, no guards). The "deep gate on main about twice a day" in HANDOFF.md, gate.yml,
tools/gate and test/README.md **does not exist as code**: no script, no schedule, and `tools/gate`
refuses main. The docs promise a safety net that isn't there.

## 1. The tiers

| tier | when | where | what | budget | who triggers |
|---|---|---|---|---|---|
| **T0 inner loop** | every edit/commit | Mac, `cpuq run --cores 1-2` (spill allowed) | `zig build`; the branch's own tests and the ones near the change (`./test/run --delta <ids>`, `tools/check`'s phase 1); the cheap whole-program checks always: `oracle`, `style`, `classify`, `vocab` | under 3 min | the agent, always |
| **T1 PR check** | once per PR, when ready to merge, **and only if risky** | burst, `tools/gate --no-matrix` | suite `--delta` + corpus; the matrix only with `-k` for the forms the PR touches, or the full matrix when the PR changes a soundness classifier, proofs or emit (a path list in tools/gate) | ~10 min | the agent, by rule: PRs that touch `src/`, `std/`, `rig.grammar`, `test/run`, `test/matrix.py`. Docs-only PRs skip it (doc examples are T0 via tools/check) |
| **T2 batch gate ("deep gate", merge train)** | on main, when main has moved since the last deep run: every 4 to 6 h, or after about 6 merges, whichever first; plus by hand | burst, from a clean main checkout | suite with no `--delta` (refreshes the cache honestly), corpus, **full matrix** (`--deep` weekly), `./test/run json`, equivalence against the last deep run | 30 to 45 min, nobody waits on it | a timer, and Steve's "run the gauntlet now" (`tools/deep`) |
| **T3 nightly** | once a day | GitHub cold shards (exists) + Mac `--exclusive` | cold suite on Ubuntu and macOS (catches cache bugs and macOS-only issues); JSON benchmark and check-speed guards (they need quiet time) | unbounded | cron |
| **T4 release** | a tag | | a green T2 on the exact SHA | | Steve |

**The matrix belongs in T2.** At PR time it's opt-in by path, or one targeted grid slice
(`matrix.py -k FORM --delta`), never the full 30 to 90 minutes. 1 FAIL in 91 runs doesn't pay for
38 burst-hours, or for the 20 to 80 minutes it adds to every gate.

## 2. How agents should test while they work

1. **Say it one way, in AGENTS.md, and delete the contradictions.** HANDOFF's "fast gate per round:
   `./test/run --delta`" becomes "`tools/check 5`". The Workflow block drops `./test/run -j 2` and
   `--cores 2` and says: a full suite never runs on the Mac; it runs on burst via
   `cpuq submit cpuq/suite.json` (about 5 to 10 min), and only at T1.
2. **Targeted runs by default.** `./test/run --delta <ids>` (substring filters: `reject/ownership`,
   `doc/SPEC`, `cli/lsp`), plus the cheap invariant checks every time. Add `oracle` to `tools/check`'s
   always-run set: it would have caught 11 of the 54 burst FAILs in seconds.
3. **A wider look goes to burst, filtered.** `cpuq submit cpuq/suite.json -- reject behavior/types`
   passes the filter through `"$@"`, so an agent unsure about a compiler change gets a 2 to 5 minute
   answer on burst instead of a 40-minute one on the Mac.
4. **Don't push to see.** Run T1 once, when the PR is done, not per push. Merging main into the
   branch doesn't need a new gate: T2 covers how merged PRs interact.
5. **Run `tools/gate` in the background** (`--no-wait`) and keep working. The agent's turn shouldn't
   block for 13 to 45 minutes.

## 3. Is #294's opt-in enough?

No. Opt-in is right (it removes the per-commit cost), but it took away the only systematic run of
the corpus and the matrix, and the deep gate it relies on hasn't been built. Without T2, main is
protected only by the nightly cold run, which never runs the matrix.

A **batched, post-merge gate** fits this repo better than a pre-merge merge queue (GitHub merge
queue or bors):
- There is one merger, many low-risk PRs, and merges are often minutes apart. A pre-merge queue
  serializes Steve behind 30-minute runs, the thing he is complaining about. GitHub's merge queue
  also needs the required checks to run on `merge_group` events, and nothing on GitHub can reach
  burst.
- Post-merge batching ("optimistic merge train") gives most of the protection: every merged PR
  is tested within hours, in combination with the others, and a red run blames a short range.

Design:
- **`tools/deep` (Rig):** run from a dedicated clean main worktree (for example
  `~/Data/Code/rig-main`, `git reset --hard origin/main`). It submits suite, corpus, matrix and json
  with `--note "deep <sha>"` and posts the commit status `rig/deep` on the main SHA. When it passes,
  it moves a `deep-green` tag. If main's SHA hasn't changed since the last deep run, it exits right
  away (cpuq already attaches a resubmit of the same code to the running job).
- **Trigger:** a launchd timer on the Mac (cpuq owns the host plumbing) every 4 h while main has
  moved. Steve runs `tools/deep` by hand for "the gauntlet now". Optionally also after the 6th
  merge since the last deep run.
- **When it's red:** gate.yml reads `rig/deep` on main's head. While main is red, PRs touching
  `src/` fail their check unless they carry a `fix-main` label, which stops the stacking of more
  breakage. Docs PRs keep merging.
- **Bisect:** test merged PRs, not commits: `git bisect start --first-parent <red> deep-green`, then
  `git bisect run` a script that submits **only the failing test ids**
  (`cpuq submit cpuq/suite.json -- <ids>`, or `matrix.py -k <cell>`). The results cache makes each
  step take about a minute. With about 6 PRs in a batch that's 3 steps, under 10 minutes. Then revert
  that PR or fix forward (AGENTS.md already says "fix it forward"). Whoever runs `tools/deep`, or a
  Rig agent Steve names, owns the bisect.
- **Phase 2 (optional, bors-style batches before merge):** `tools/gate --batch 301 302 303` merges
  several PR heads onto main in a temporary branch, gates once, and posts `rig/gate` success on every
  head. "Gate these four together" costs one run, not four.

## 4. The 54 failures out of 169

A 32% FAIL rate with about 40% of it noise makes the gauntlet's verdict untrustworthy. Agents learn
to resubmit ("under load, rerun a timeout alone before trusting it" is literally in AGENTS.md), and
every resubmit costs another 10 minutes. Changes:
1. **A setup failure isn't a FAIL** (cpuq): exit through a distinct verdict (SETUP FAILED, mapped
   to tools/gate's `error`), not 1. Then 4 FAILs in 2 to 7 s stop looking like code.
2. **Structured failures** (Rig plus cpuq): `test/run` writes `test/results.jsonl` and the specs
   set `"report"`, so `result.json` lists failing ids. That gives cpuq and the gate a quarantine
   list (tests that failed and then passed on the same digest), and a bisect script its ids.
3. **Fix the known flakes** (Rig): `cli/results_cache` and `no_crash_report` hit 120 s under
   32-way load, so give them `# timeout:` or run them in a serial group; find "the test runner
   died" (4 jobs); make the setup's `ln -s` idempotent (`ln -sfn`, since `[ -e ]` is false for a
   dangling link); make `test_prune` deterministic.
4. **Fail fast** (Rig): `test/run --gate` runs the cheap, deterministic kinds first (oracle, style,
   classify, vocab, reject, ir, doc), stops on the first failure, and only then runs the long
   programs. A failing gate then ends in about 1 to 2 minutes, not 10.
5. **No blind reruns:** retry a FAIL once automatically only when every failing id is on the
   quarantine list. Anything else is a real failure, and goes back to the agent with the ids.

## Top recommendations

1. **Rig, `AGENTS.md` + `HANDOFF.md` + `tools/check`:** one testing rule. T0 is targeted plus
   `oracle`/`style`/`classify`/`vocab`; the full suite never runs on the Mac. HANDOFF's "fast gate:
   `./test/run --delta`" becomes `tools/check`. Biggest win: it removes the 41-minute local runs.
2. **Rig, `tools/gate`:** `--no-matrix` becomes the default. The matrix runs at PR time only on a
   path list (classifiers, proofs, emit) or as `-k` slices. Docs-only PRs aren't gated.
3. **Rig (`tools/deep`, a `rig/deep` check in gate.yml) + cpuq (launchd trigger on the Mac):**
   build the deep gate the docs already promise: batched on main every ~4 h when main has moved,
   plus Steve by hand, first-parent bisect on failing ids, and src/ PRs blocked while main is red.
4. **cpuq, `src/submit.zig`:** a setup failure gets its own verdict. With Rig: a `report` in the
   specs so `result.json` names the failing tests (needed for quarantine and bisect).
5. **Rig, `test/run`:** a fail-fast gate order with the cheap deterministic checks first, and fixes
   for the timeouts and runner deaths in `cli/results_cache`, `no_crash_report` and `test_prune`,
   and for the `ln` in suite.json's setup.
