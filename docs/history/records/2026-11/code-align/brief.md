# Aligning Rig's hot code: design round brief (2026-11-19)

The owner, 2026-11-19: "Yes, start it": a small design round on aligning Rig's hot code, alongside
the free fork-join work.

## The finding

[qsort-mac](../qsort-mac/README.md), "The layout outlier": fork.rig built with never-taken prints that
only grow `main` moves qsort and the sort functions after it (`main` sits first in the program's
section, `linksection(rig.preempt_section)` in a build preempted by signal). qsort's 358 instructions
are identical in all eight placements, yet main's placement (qsort at 0x10005bf10) is 15% slower at
1 worker and 6-10% slower at 10 than the seven others, and still 18% slower with the monitor held
off. AGENTS.md's Speed rules already warn that moving code shifts a hot loop by 5-7% on Apple cores.
Boards now build each Rig arm at two or three placements and report the median, which keeps a
row honest but makes no program faster.

## The question

Can Rig place its code so that no build lands on a bad placement, on the Mac (arm64, ld64) and Linux
(x86-64, Zig's linker or lld), at no cost to speed elsewhere (Trig, std.json, the guards) and at an
acceptable size? Zig 0.17 has no flag for LLVM's `-align-loops`. Candidate means, for the round to
judge (others welcome):
- `align(N)` on each emitted function (Zig's function alignment), for all of the program's functions
  or only hot or loop-holding ones (which a fact would have to name);
- the order of functions in the program's section (`linksection`), or a section per function and a
  link order;
- the loops themselves: padding a loop's head to a boundary by what emit writes, if Zig allows it;
- a post-link layout: `rig build --bolt` exists on Linux (src/bolt.zig); macOS has ld64's
  `-order_file`;
- a profile (`rig build --pgo`, Linux).

## Who answers what

- **Expert A, the measurement** (the only one who builds or times): what layout property explains
  the outlier (the loop head's offset within 32 or 64 bytes, a branch straddling a line, the
  instruction fetch or loop buffer of the M5's cores)? Which means removes it: function alignment at
  16, 32, 64 or 128 bytes; others the round can prototype by hand in the emitted Zig. Measure the
  eight placements of qsort-mac's shift/ programs under each, and the spread they leave; then the
  cost of the best: Trig on the Mac (one checker, as the light gate builds it), std.json's and the
  hash table's guard rows, binary size.
- **Expert B, the design**: where in the compiler each means lives (emit writes what a fact says,
  never a decision of its own), what Zig 0.17 and its linkers allow on both targets
  (/Users/shreeve/Data/Code/rig/ZIG-0.17.md; the installed std is the authority), its interplay with
  the preemption section and the split builds (src/units.zig, src/split.zig), with BOLT and PGO, and
  what stays the user's choice; then a recommended design and its tests.

## Rules (read /Users/shreeve/Data/Code/rig/AGENTS.md first)

- Write only in this record's folder in the worktree
  `/Users/shreeve/Data/Code/worktrees/rig/align-design/docs/history/records/2026-11/code-align/`
  (A: `probes/` and `raw/` too). No other file, worktree, or `~/Data/Code/rig`. No commits; the lead
  commits.
- Read code at origin/main (`git -C ~/Data/Code/rig show origin/main:PATH`).
- Expert A: builds through `/Users/shreeve/Data/Code/rig/tools/heavy`; every timed run inside
  `/Users/shreeve/Data/Code/rig/tools/mac-claim LABEL CMD` (at most 20 minutes; retry on exit 75); hold
  off while `~/Data/Code/mumps-compare/.mac-quiet` exists. Nothing on pup or burst: write a pup job if
  x86 needs one. Never pkill or killall.
- Measure honestly: interleaved, paired medians with quartiles, an A/A arm; "N% faster/slower".
- Other builders own src/sched.zig's monitor and spawn path, src/storage.zig's `task_record`, and
  src/alloc.zig: touch none of them even in probes' copies you commit.
- Timeless prose; Rig's vocabulary (tasks and cores, never threads for Rig's parallelism).

## Your report

To the lead: at most 400 words ending with your recommended defaults as a numbered list; the full
report in this folder as `measure.md` (A) or `design.md` (B). Stop after about 3 hours of work.
