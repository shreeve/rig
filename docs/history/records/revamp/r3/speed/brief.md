# Brief: how do we iterate on Rig much faster?

**The problem.** The remaining road to v0.3.0 is 10 steps, estimated at about 20 agent-days, or "a week or two" of wall-clock time. The owner wants a much faster way to iterate. Find concretely where the time goes and how to cut it. Don't lower the safety bar: sanitizer-clean, the independent oracle, equivalence checks, independent reviews, and AGENTS.md's rules. Change how it's met.

**The current process,** per round:
1. An implementer agent builds on its own branch and worktree, test-first.
2. Equivalence: `test/equiv.py <base-binary> bin/rig` over ~8,300 programs (parse/normalize/check/facts/sema/storage/emit).
3. Four gates via `r3/gates.sh` under `r3/heavy.sh` (cpuq with 2–4 cores):
   - `./test/run` (suite, ~2,650 tests);
   - `./test/run corpus` (~6,000 programs; ~25–30 min);
   - `test/matrix.py` (~3,400 programs);
   - `zig build test`.
4. `./test/run oracle doc vocab`.
5. An independent adversarial reviewer agent writes probes. If it finds something, the implementer fixes it, the gates run again, and a round-2 review follows (AGENTS: a second soundness round stops the feature).
6. PR, then GitHub CI (Linux and macOS), then merge, then cleanup.
7. Rule: only one branch at a time may touch src/ownership.zig or typecheck classification ("one ownership branch at a time").

**The remaining queue:**
1. seam 2 redesign (`!` on temporaries; in progress)
2. the "copies" fact
3. B4b (lift header-temp and arm-local payload rules)
4. seam 3 (views in Box/generic T)
5. Static (text stage 1)
6. the fold (text stage 2)
7. Box → `^T`
8. Vec → List
9. Text/String rename (text stage 3)
10. docs and final review

**Evidence to read:**
- **Ledger:** /Users/shreeve/Data/Code/rig/.git/revamp/ledger.md, with timestamped entries; the post-v0.2.0 part is near the end, but earlier REVAMP-3 entries show the same pattern.
- **Logs:** /Users/shreeve/Data/Code/rig/.git/revamp/r3/logs/ (gates `.sum` files with durations; equivalence logs).
- **Process scripts:** r3/gates.sh, r3/heavy.sh, test/run, test/matrix.py, test/equiv.py, test/oracle/.
- **CI:** .github/workflows/.
- **Plans and reviews:** r3/open-items.md, r3/rig-questions.md, and the review reports (r3/review-*.md).
- **The machine:** the Mac has 10 cores (8-core cpuq budget shared with other projects); see `cpuq status` and `cpuq history`. The owner has mentioned a second machine, "pup", and cpuq's roadmap mentions running jobs there.

**Repo:** /Users/shreeve/Data/Code/rig (main). READ-ONLY: don't edit or commit.

**Output:**
- Write /Users/shreeve/Data/Code/rig/.git/revamp/r3/speed/<your-name>.md.
- Final message: at most one page, with concrete changes, each with an estimated time saved and its risk, ranked by payoff.
