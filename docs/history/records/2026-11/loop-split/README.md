# Counted loops in blocks: built, measured, not taken (2026-11-05)

Step 3 of the concurrency plan the owner approved on 2026-11-04: a counted range `for i in a..b` runs in blocks of the turns left before the next yield check, a plain inner loop, then one check, in place of a check on every turn. The code is at the tag `archive/loop-split` (#966, closed). The foreman closed it under the speed rule (AGENTS.md, "A speed feature pays for its lines").

## The ceiling

In #962's record ([taskbench/loop-disassembly.md](../taskbench/loop-disassembly.md)):
- On arm64, a check on every turn makes LLVM put two extra adds on the chain each of `spin`'s turns waits on, which costs 27% of its cycles.
- In hand-written Zig, the block form reaches 1.01 times Rust's cycles.
- A time-measured slice was measured and rejected ([taskbench/slice-ceiling.md](../taskbench/slice-ceiling.md)).

## What was built

`emitRangeFor` splits a range whose body holds no loop, which may not leave it early, and whose length is not a constant of at most 1,024. Its runtime helpers are `rig.turnStop`, `rig.turnEnd` and `rig.turnsLeft`. The count of turns is exact, so every seeded schedule is unchanged: [sched-probe.rig](sched-probe.rig) prints the same under seeds 1 to 20 as main's rig, and differs under all 20 when a first design's refund was stubbed out.

## What it measured

- **On the Mac,** against main: bench/tasks' CPU benchmarks take 14-21% fewer cycles, `even` through `par.map` matches Rust's loop (1.00x), and `fanout` is 18% faster.
- **On Trig, pup, the first design** (every inner range split): 1.7-3.0% more instructions and up to 2.7% slower ([trig-pup-2026-11-05.md](trig-pup-2026-11-05.md)). The profile put the cost in short searches, Trig's `mapper_map` above all ([profile-2026-11-05.md](profile-2026-11-05.md)).
- **On Trig, pup, the no-early-exit rule:** 0.5-1.4% more instructions on five projects, and wall time within noise ([trig-pup-split2-2026-11-05.md](trig-pup-split2-2026-11-05.md)). It is below the bar, since Trig has few long counted loops.

## An earlier attempt

`archive/loop-tick` (#782, owner 2026-10-31) ran bounded loops in strips of 1,024 turns as well, and was not taken for the same reason: ts-pattern 2.6% slower on pup. It was not found before this round began. This round adds:
- the arm64 disassembly of the cost;
- an exact count;
- the rule that leaves searches exactly as they were, which takes the Trig cost from 2.6-3.0% down to 0.5-1.4% more instructions, but not to a gain.

## Open, for the owner

Should a gain on arm64 alone count? The chain problem is arm64's: on x86 a check on every turn is a `dec` fused with its jump, and the block form gains less. Trig has not been timed on the Mac with the split. A run of Trig's six projects on the Mac, base against `archive/loop-split`, would settle whether the arm64 gain reaches a real program.
