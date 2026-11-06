# `rig check`'s instruction creep, bisected (2026-11-05)

On main cf6a362a6, `bench/check/guard.py` read about 1.9% more instructions than its committed `guard.txt` (2,130,157,291, from 13a173349 on 2026-11-03). This record bisects that creep along main's merges, on the Mac, and fixes what the bisect found.

## How it was measured

`/usr/bin/time -l`'s "instructions retired" counts the kernel's instructions too, and they vary with the machine's load. On one binary, the guard's median of 5 ranged from 1.1% to 1.9% over its baseline between runs; the minimum of 15 moved by up to 0.8%. So each comparison here was run interleaved: every binary once per round, 15 or 20 rounds, comparing the minimum, the first quartile, and the median. Each binary was `tools/baseline SHA`, a ReleaseSafe `zig build` at that commit, and the workload was `bench/check/gen.py`'s, as the guard runs it, through `tools/low`.

## Where the creep came from

Against 13a173349 (the guard's baseline commit), 20 interleaved rounds (median):

| commit | what | instructions |
|---|---|---|
| 13a173349 | the guard's baseline | level |
| 8031441f6 | #924, ternary | 0.1% more |
| 81456f497 | #937, pattern syntax | 0.1% more |
| 9820b59d2 | #941, emit's last live decisions recorded | 0.7% more |
| 27010375f | #949 | 0.8% more |
| cf6a362a6 | main, #970 | 0.8% more |

Within #937 to #941, 20 rounds against 81456f497: #938 and #939 are level (0.0%), and #941 adds 0.6%. Within #941, 15 rounds: f5f534ef4 (swap) adds 0.1%, and 249cd5002 adds 0.6% (storage: the decisions Facts still made live are recorded questions).

- **About 0.8% of the creep is in the code, and 0.6% of that is one commit.**
- **The rest is the machine:** 13a173349 itself now reads 0.1% to 1.3% over the number it wrote on 2026-11-03, depending on the Mac's load. On a quiet Mac, main reads about 0.8% over `guard.txt`, not 1.9%.

## What 249cd5002 costs, and what can be taken back

249cd5002 makes seven of emit's live decisions recorded questions, which the plan decides for every node of their kind and `verifyDecisions` asks again (`bind_hold` of every assignment, `compound_call`, `catch_all` of every arm, and the rest). That is North Star 4's "one classifier per fact", and its cost is the price of the rule: no part of it is redundant.

The fix below is not to that commit. It takes back an older redundancy of about the same size. Every expression has two recorded decisions, `hands` and `reaches_leaf`, since 6f7ffc87d and 5ed43d2b1 (2026-10-08). A timed build split `verifyDecisions`' time by question, on the workload:

| question | decisions | share of the verify |
|---|---|---|
| reaches_leaf | 173,412 | 41.9% |
| hands | 173,412 | 32.2% |
| set_order | 10,456 | 5.0% |
| lane_checked | 27,956 | 4.7% |
| hoists_args | 4,171 | 4.7% |
| bind_hold (249cd5002) | 9,206 | 2.1% |
| the other 16 | | 9.4% |

`reaches_leaf`'s decider computed `sema.handsOver` again, rather than reading the `hands` answer recorded beside it. So every expression ran `handsOver` four times: twice in the plan and twice in the verify.

## The fix

`decideReachesLeaf` reads `handsKind`, the recorded decision. That takes it from four runs to two, one in the plan and one in the verify. `hands` is still verified on its own, so the check loses nothing. 15 interleaved rounds against main: **0.6% fewer instructions** (minimum, first quartile, and median all agree). That takes main back to within 0.2% of the baseline commit: the fix pays for #941's questions.

Reading the recorded `hands` answer in four more places in storage.zig (`hasStorage`, `wholeStep`, `reachesPlace`, `decideDropsWhenTested`) measured level, so it was not kept.

## A larger cost, which is a policy question

`verifyDecisions` runs in every build, including the shipped `bin/rig`. A build that ran it only in self-checking builds (`-Dself-check`, which the test runner builds) checked the workload with **5.2% fewer instructions** than main. It is a check for compiler bugs, and the suite would still run it, but skipping it in a release build is not this record's to decide. It goes to the owner.
