# Panels of 2026-11-05: three skipped speed ideas, revisited honestly

The owner asked for three panels of three experts. Each panel reviews one idea that showed a large gain overnight but was stopped by a specific problem. The question for every panel: **is there a clean, honest way to keep the gain without the problem?** "No" is an acceptable answer, if the evidence supports it.

## Ground rules (bind every expert)

- **Honesty first.** Rig's North Star (AGENTS.md, "The North Star") does not bend:
  - accept means correct;
  - safe code cannot corrupt memory;
  - effects stay visible;
  - emit decides nothing that the checkers didn't record as a fact.
- **No cheating.** Nothing that only moves a cost out of the measured window, games a benchmark, or makes timing tools report something untrue. A gain must be real for the person running the program.
- **The speed bar** (AGENTS.md, "A speed feature pays for its lines"): on Trig, more than 1.5% faster, or at least 1% fewer instructions on one checker, with peak memory no higher. A gain of 1.5-2% counts only over 20 interleaved rounds.
- **Read-only on the repos.**
  - Never edit, branch or commit in ~/Data/Code/rig, ~/Data/Code/trig or ~/Data/Code/loc.
  - Read with `git show origin/main:PATH` and `git show archive/TAG`, or with plain reads.
  - Scratch work goes in your own folder under the panel's scratch folder (not kept)
- **pup (the x86 Linux machine) is out of reach today:** the owner is on a plane. Use the recorded pup numbers. Mac measurements are allowed only if your lens says so, always through `tools/low` from a scratch copy (for example `git -C ~/Data/Code/rig worktree add` is NOT allowed; use `git archive origin/main | tar -x -C DIR` instead). Check ~/Data/Code/mumps-compare/.mac-quiet first, and hold off while it exists. Two other sessions are building on the Mac, so Mac timing is noisy: report fastest-of-N, interleaved, with cycles.
- **Prior attempts:** read docs/history/records/archive-tags.md first, so you don't re-propose something already tried and closed. If you build on a closed idea, say what is different.
- **Vocabulary:**
  - lend, view and loan, never "borrow";
  - a Rig `obj` is an "object", never a "struct";
  - `@` is "self";
  - say "N% faster/slower", never bare +/- percentages.

## Output

1. **The full report** goes to docs/history/records/2026-11/panels/<panel>/<lens>.md.
   - Concrete designs, with the code paths they touch (file:line).
   - What each design would gain, as a number or a range with its basis, and what it costs.
   - The risks.
   - The measurement that would settle it, with its first step.
2. **Your reply to the foreman:** at most 400 words, ending with your verdict, one of PURSUE (with the design), MEASURE FIRST (with the measurement), or DROP (with the reason).
