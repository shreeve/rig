# timeline: where the wall-clock time goes

Window: round C launch (10-05 21:19 MDT) to the seam 2 redesign launch
(10-06 11:19), 840 minutes. Sources: ledger timestamps; birth and
modification times of every log in `r3/logs/{c-rules,b4a,hotfix7,seam2}`;
the `.sum` durations; `cpuq history --json` (covers 23:31 onward); `gh pr view`
and `gh run view` for PRs #52-#57 (UTC converted to MDT, -6h). All numbers
are minutes of wall-clock time unless marked otherwise.

## 1. The critical path

Round C, the v0.2.1 hotfix, and seam 2 all touch ownership, so they ran as a
chain. B4a (emit only) ran beside them.

```
21:19 ── round C ─────────────── 02:07 merged (#52)
           (B4a 23:09 ─────────────────── 03:57 merged (#53), off-path)
           (hotfix7 00:15 ─ built 02:03, review 02:48)
02:07 ── hotfix7 tail: rebase, regate, CI ── 04:12 merged (#54)
04:16 ── seam 2 ─────────────── 07:10 stopped (2nd soundness round)
07:10 ── v0.2.2 class fixes ─── 08:49 merged (#56)
08:49 ── nothing runs ────────── 11:19 seam 2 redesign starts
```

Critical path, 840 minutes, by bucket:

| Bucket | Min | Share |
|---|---:|---:|
| Gates and equivalence (wall, on path) | 355 | 42% |
| ... of which corpus runs alone | 222 | 26% |
| Idle / lead lag (nobody acting) | 173 | 21% |
| Implementing (agent writing code and tests) | 110 | 13% |
| GitHub CI (PR to merge) | 84 | 10% |
| Review (adversarial reviewer running) | 63 | 7.5% |
| Waiting for cores (cpuq queue) | 20 | 2.4% |
| PR prep / recording | 12 | 1.4% |
| Slack / unattributed | ~23 | 3% |

The time is dominated by gate wall time (above all the corpus) and by
idle time between steps. Review itself is cheap; what costs is the full
regate after every fix. Core contention is a small bucket: across all 60
rig cpuq jobs in the window the total queue wait was 38 minutes, 20 of
them one wait. Contention mainly hurts through grant size: the same
corpus takes 13-15 minutes at 4 cores and 25-30 at 2.

## 2. Per-round split

### Round C (#52): 21:19 -> 02:07 merged, 288 min
| Phase | Span | Impl | Gates+equiv | Other |
|---|---|---:|---:|---|
| Build C1-C3 | 21:19-22:55 (96) | 23.5 | 72.5 | |
| Review 1 | 22:55-23:24 | | | review 29 |
| Rework 1 (user: seam1, #4, L1-L4) | 23:24-00:47 (83) | 21 | 41.2 | **20.4 cpuq wait** (d3 suite) |
| Rework 2 (user revised seam1) | 00:47-01:19 (32) | 7 | 25.1 | |
| Review 2 | 01:19-01:25 | | | review 6 |
| Record, PR | 01:25-01:37 | | | 12 |
| CI | 01:37-02:07 | | | CI 30 (macOS test 27.5) |
| **Total** | 288 | **51.5** | **138.8** | review 35, CI 30, PR 12, wait 20 |

The gates in round C: 5 corpus runs (85.6 min: c1 14.2, c2 14.6, final 19.0,
final2 19.3, final3 18.5); 9 suite runs (27 min); 3 matrix runs (10.1); 3
equiv runs (15.5). Two of the corpus runs (c1, c2: 28.8 min) were per-commit,
and each was followed by another full gate. 115 minutes (rework 1 and 2)
came from design decisions that changed after launch, not from review.

### B4a (#53): 23:09 -> 03:57 merged, 288 min (off the critical path)
| Phase | Span | Min |
|---|---|---:|
| Implement | 23:09-23:27 | 18 |
| equiv x2, odv, experiment, full gates (suite cold 6.7) | 23:27-00:14 | 47 |
| **Waiting for the lead to launch review** | 00:15-01:39 | **84** |
| Review 1 | 01:39-01:59 | 20 |
| Fixes: impl 11.7, equiv 9.4 + gates 34.4 at 2 cores (corpus 29.5) | 01:59-02:55 | 56 |
| Review 2 | 02:55-03:00 | 5 |
| Merge main, re-equiv, suite, odv, corpus 19.5 | 03:00-03:29 | 29 |
| CI | 03:29-03:57 | 28 |

Implementing 30, gates and equiv 119, review 25, waiting 84, CI 28. Three
corpus runs (62.4 min), four equiv runs.

### Hotfix7 / v0.2.1 (#54): 00:15 -> 04:12 merged, 237 min
| Phase | Span | Min |
|---|---|---:|
| Implement (incl. 5 min targeted tests) | 00:15-01:05 | 50 |
| equiv (5.2 cpuq wait + 9.7 at 2 cores), equiv2, gates (suite cold 7.9, corpus 17.4, matrix cold 8.5), odv | 01:05-02:03 | 58 |
| Review (reviewer reran equiv twice: 24.2 + 7.3) | 02:03-02:48 | 45 |
| Lead noticed #52 merged 19 min late | 02:07-02:26 | 19 |
| Rebased gates, **corpus killed after 27.7 min** at 0.2 cores used | 02:27-02:59 | 32 |
| Full gates again at 2 cores (corpus 28.2), odv, equiv vs v0.2.0, equiv vs main | 03:01-03:48 | 47 |
| CI (lead's own combined-tree suite, 8.3, ran beside it) | 03:48-04:12 | 24 |
| Release 0.2.1 PR CI; release tagged 71 min after merge | 04:15-05:55 | (off path) |

Three corpus runs (one killed): 73 min; five equiv runs plus two by the
reviewer.

### Seam 2: 04:16 -> 07:10 stopped, 174 min
| Phase | Span | Min |
|---|---|---:|
| Implement (incl. ~5 min targeted runs) | 04:16-04:47 | 31 |
| equiv, odv, gates at 2 cores (suite cold 11.0, corpus 25.4, matrix cold 13.3); **the suite failed one test at minute 11 but corpus and matrix ran on for 39 min**; then suite+odv+equiv again | 04:47-05:55 | 68 |
| Review 1 | 05:55-06:09 | 14 |
| Fixes: impl 15; gates at 2 cores (corpus 26.7) 31.7; odv+equiv 7.3; hotfix-branch suite+equiv 13.6 beside it | 06:09-07:04 | 55 |
| Review 2 -> STOP; hotfix-branch gates killed after 6 min | 07:04-07:10 | 6 |

### v0.2.2 (#56): 07:10 -> 08:49 merged, 99 min
| Phase | Span | Min |
|---|---|---:|
| Class fixes: impl ~8, gates at 4 cores 27.8 (corpus 14.7, matrix 6.6) incl. odv+equiv | 07:10-07:46 | 36 |
| Review | 07:46-07:54 | 8 |
| Fold M1 + SPEC wording: impl ~4, full gates again 20.5 (corpus 14.4) | 07:54-08:19 | 25 |
| CI (macOS test 24.1, ubuntu 8.2) | 08:19-08:49 | 30 |
| **Idle: merge not noticed until 11:12; next round 11:19** | 08:49-11:19 | **150** |

## 3. Findings

### F1. The corpus is cold on every gate run, because the suite deletes its cache (largest gate cost)
`test/run` keeps each corpus program's Zig build cache so that "a later run
rebuilds only the programs whose emitted Zig changed" (test/run:276-279).
But a run with no filters (the suite) samples 1 corpus program in 16, and
its cleanup (test/run:838-861) deletes the output directories of every test
not in its list. Unsampled corpus programs count as "gone", so their caches
are deleted. `gates.sh` always runs the suite first and the corpus second,
so **every corpus gate in this window started 15/16 cold**.

Measured (scratch RIG_TEST_OUT, corpus/R3c1, 66 programs, -j 2):
cold 72 s, warm 22 s and 19 s, of which ~17 s is fixed `test/run` startup.
So warm is ~2 s for 66 programs, against ~55 s cold. A single accepted
program: `rig run` 1.1 s cold, 0.05 s warm. A different rig binary with
identical emit still hits the cache (rig-v021 then rig-v022 on one outdir:
1.04 s, then 0.05 s). Extrapolated, a warm full corpus is ~3-4 min at -j 2,
against the observed 13-30 min. The prune is confirmed by experiment
(section 5): after a full suite, 33 of 34 warm corpus caches were gone.

16 corpus runs in the window took ~300 min of wall time, 222 of them on the
critical path. A warm corpus would cut that to ~60 min.

### F2. Fresh worktrees start every cache cold
Each round gets a new worktree, so `.zig-cache/rig-test` and the matrix
`--keep` directory start empty. The first suite of a round took 400-660 s
(b4a 6.7, hotfix7 7.9, seam2 11.0 min) against 92-230 s warm. The first
matrix took 8-13 min against 0.5-1 min warm. That is ~15-20 min per round.
The Zig cache keys on the absolute path of the emitted package, which lives
in the output directory, not in the worktree. So a stable output directory
reused across worktrees (for example `RIG_TEST_OUT=~/.cache/rig-test/slotN`,
`--keep ~/.cache/rig-matrix/slotN`) hits across branches. I verified that a
copied cache at a new path does not hit (1.15 s), so the path must stay the
same.

### F3. Gates are rerun many times per round
| Round | Full gate sets | Extra corpus | Extra suites | equiv (impl+reviewer) |
|---|---:|---:|---:|---:|
| Round C | 3 | 2 (per commit) | 6 | 3 + 0 |
| B4a | 2 + merge regate | - | 1 | 4 + 0 |
| Hotfix7 | 2 + 1 killed | - | 1 (lead's combined tree) | 4 + 2 |
| Seam2 + v0.2.2 | 4 + 1 killed | - | 2 | 6 + 1 |

The duplications:
- **Per-commit corpus** (round C c1 and c2: 29 min), then the final gate
  reran everything.
- **The full regate after a small review fold-in** (v0.2.2 f gates, 20.5 min
  for M1 and SPEC wording; round C final3, 21 min for a rule rewording).
- **The regate after a merge of main** (B4a 27 min; hotfix7 32 min killed,
  then 32 min of gates and 14 min of equiv). The lead's combined-tree check
  (8 min) duplicated what CI was already running.
- **No fail-fast:** seam2's suite failed at minute 11 and gates ran 39 more
  minutes before the rerun.
- **The reviewer reruns equiv on the same commit** (review-hotfix7: 24 + 7
  min; review-seam2: 5 min). The run is deterministic, so a second copy adds
  no independence.
- **equiv recomputes the base binary's output every time,** although the
  base (rig-v020/v021/v022) is fixed for the whole round. That is half of
  every equiv run (4-10 min a run, 3-7 runs a round).
- Corpus reruns when only diagnostics change: corpus rejections check only
  file:line:col, and the emit is unchanged, so with F1 fixed these become
  free automatically.

I found no full gate rerun after a doc-only change in this window. Doc
changes went through `oracle doc vocab` (~0.5 min plus ~17 s startup).

### F4. Idle and lead attention is the second-largest bucket (173 on path, 84+71 off path)
- 08:49-11:19: #56 merged, and nothing ran for 150 min (user asleep;
  the lead was not woken by the merge).
- 00:15-01:39: B4a sat green for 84 min, waiting for a review launch while
  the lead ran design threads with the user (holding-rule, text-rule).
- 02:07-02:26: the round C merge was noticed 19 min late. That delayed the
  hotfix7 rebase.
- v0.2.1 was tagged 71 min after its release PR merged (off path).

### F5. CI is ~25-30 min per PR, gated by the macOS runner
The macOS `Test` step takes 22-28 min (ubuntu 6-11) and runs only the suite.
Every ownership PR waits for it, and so does every release PR (another
~28 min, plus a post-merge main run). On the path: 84 min across 3 PRs. The
next ownership round cannot start until the merge.

### F6. Serialization is real but mostly costs through regates
The one-ownership-branch rule chained round C, then hotfix7, then seam 2.
Hotfix7 overlapped round C, but after #52 merged it paid a rebase, a
killed corpus, and a full regate: ~80 min between review clean (02:48) and
PR (03:48). With warm caches (F1, F2) a post-rebase regate is ~8-10 min.

### F7. Redesign cycles from late decisions
Round C's two reworks (115 min, 40% of the round) came from decisions that
changed after launch (seam1 twice, #4 added). Seam 2's second soundness
round cost the whole round (174 min) plus v0.2.2 (99).

## 4. Ranked savings

Savings are per round (one ownership round with one review-fix cycle,
about the shape of hotfix7 or seam2), then over the 9 remaining rounds.

| # | Change | Saves / round | Risk |
|---|---|---|---|
| 1 | **Fix the corpus cache prune.** A no-filter run should not delete `corpus/*` directories whose program still exists in `test/corpus/` (or the corpus should get its own output root). Corpus 13-30 -> ~3-5 min. | **35-60** (2-3 corpus runs a round) | Very low: only the cache changes; every program is still checked and run under the sanitizer. |
| 2 | **Auto-wake and auto-chain.** Watch PRs (`gh pr checks --watch` or Monitor) and wake the lead on merge; the next round's brief is ready before the merge; the implementer's "gates green" launches the reviewer without the lead. | **30-150** (150 overnight, 84 for B4a, 19 for round C) | None for safety. |
| 3 | **Stable cache slots shared across worktrees** (`RIG_TEST_OUT` and matrix `--keep` under `~/.cache/rig-*/slotN`, one per concurrent worktree; the existing lock enforces one run per slot). | **15-20** (first suite cold 7-11 -> 2; first matrix 8-13 -> 1) | Low: worst case a cache miss. Needs one slot per concurrent run. |
| 4 | **Start the review when the suite is green, beside corpus/matrix/equiv,** not after them. | **20-45** | Low: if a late gate fails, the fix is re-reviewed anyway. |
| 5 | **Fail fast and gate once per state:** stop `gates.sh` at the first failing gate; per commit, run only the targeted tests and the suite; run the full gates once per review handoff and once before PR. A fold-in of lows and docs gets suite + odv + a corpus that, once warm, costs minutes. | **15-40** | Low. The full set still runs on the final tree. |
| 6 | **Cache the base binary's equiv output** (keyed by base sha256, program sha, and section), and **the reviewer reads the implementer's equiv log** (checking the commit and binary hash) instead of rerunning it. | **10-35** (half of 3-7 equiv runs; reviewer reruns of 5-31) | Low: the run is deterministic, and the reviewer still writes its own probes. |
| 7 | **Stack the next ownership round on the open PR head** instead of waiting for merge plus CI; rebase after the merge (typically clean). | **25-30** (the CI wait per PR) | Low-medium: if the PR changes during CI, the next round rebases. The one-branch rule still holds for *merging*. |
| 8 | **Speed up macOS CI:** cache `.zig-cache/rig-test` (after #1) and the Zig global cache across runs; skip the release-PR CI (version-only change, already proven by main's push run) or tag main directly. | **10-20** on path; ~30 off path per release | Low. |
| 9 | **Freeze design decisions before launch** (batch questions to the user; no mid-round scope adds). | 0-115 (round C lost 115) | None. |
| 10 | Prefer a 4-core grant for the corpus (or run it on pup). After #1 and #3 this matters little. | 0-15 | None. |

Combined, for a typical round with one fix cycle: ~3.5-4.5 h becomes about
1.5-2 h of wall time (implement 40-60, warm gates ~10 per pass, review with
overlap 20-40, CI 25 overlapped by stacking). The overnight idle bucket (#2)
is on top of that. Over the 9 remaining rounds, #1 + #3 + #5 + #6 alone
save roughly 9-15 hours of wall time. #2 and #7 together remove another
~1-3 hours per night of autonomous running.

## 5. Experiment: does the suite prune the corpus cache?

The answer is in the code. In test/run:838-861 the cleanup's `keep` holds
only the listed tests, and `corpus` is only in `dir` as a prefix, so
`corpus/<unsampled>` falls through to `gone` and is deleted with `rm -rf`.
The empirical check (scratch RIG_TEST_OUT, under cpuq):
warm corpus/R3c1 (34 cached program directories) -> full suite -> count the
directories left, then re-time corpus/R3c1.

**Result: confirmed.** Before the suite, 34 corpus/R3c1 directories held
warm caches, all created at 11:26. After a full `./test/run -j 2`, which
passed 2650 tests in 1808 s, a cold start under load 10-14, the rerun of
corpus/R3c1 found only 1 of the 34 caches (the one program in the suite's
1-in-16 sample, still dated 11:26). The other 33 were rebuilt from scratch
(created 11:59:17-11:59:25), and the rerun took 37 s instead of 19-22 s
warm.

The same run is a second data point for F2: a cold suite in a fresh output
directory took 30 min at -j 2 under load, against 2-4 min warm.
