# Loop split, codegen lens (arm64 and x86-64), 2026-11-05

Scratch work, all reproducible: `the panel's scratch folder (not kept)`
- `shapes.zig`: six loop shapes for `spin`, a short search (`find`) and a sum, with the check's cold path written as the same asm call site as `callKeeping`.
- `arm.s` and `x86.s`: their disassembly (arm64 `apple_m4`, x86-64 `meteorlake`).
- `bench.zig`, `run.sh`, `raw.txt`: the short-search harness.
- `arm-*/`: bench/tasks as `rig build --release=fast` emits it (main cf6a362a6), with only `spin`'s loop edited. `run2.sh` and `raw2.txt` hold the runs.

Mac M5. The load was 10-13 from other sessions, and `.mac-quiet` was absent. Every run went through `tools/low`. The tables give the fewest cycles of 7 interleaved, shuffled rounds, from `/usr/bin/time -l` over the whole process.

## 1. Why the per-turn check "costs" 14-21% on arm64: it mostly doesn't

The cost isn't the check. It comes from LLVM's code for the `nsw` recurrence `total = (total + i*7) % 1000003`. In `--release=fast`, Rig's `+` and `*` lower to Zig's unchecked operators, which carry `nsw`; SPEC §1 makes overflow undefined there. With `nsw`, LLVM rewrites `7i` as `(i<<3) - i` and moves both halves onto the chain that `total` carries from turn to turn:

- plain loop, no check: `sub x14,x14,x9 ; add x14,x14,x9,lsl #3 ; umulh ; sub ; add ; lsr ; msub`, 7 steps (`arm.s`, `spin_none`);
- inside a block's inner loop: LSR keeps `7i` as its own induction value (`add x14,x14,#7`), so the chain is `add ; smulh ; add ; asr ; add ; msub`, 6 steps. That is Rust's code. Rust wraps, so it has no `nsw`.

The test, in the real emitted program: keep main's per-turn check and change only the body to wrapping arithmetic (`+%`, `*%`). `RIG_WORKERS=1 tasks scale even-par 1`:

| arm | instructions | cycles |
|---|---|---|
| base (main) | 980.0M | 873.7M |
| no check, `nsw` body | 779.9M | 817.9M |
| **check on every turn, wrapping body** | 723.9M | **712.0M** |
| no check, wrapping body | 590.2M | 711.7M |
| split (block form, `nsw` body) | 598.1M | 712.2M |
| Rust (record, mac-2026-11-04) | 584M | 707M |

With a 6-step chain, the per-turn check costs 134M instructions and zero cycles. The core runs `subs`/`b.eq` beside the chain, so they don't wait on it. The record's own disassembly note says the countdown "costs almost nothing". Of base's gap to Rust:
- about a third is the check's branch, which makes LLVM rotate the loop in this context (874M to 818M with the check deleted);
- the rest is the `nsw` strength reduction.

The block form happens to fix both, which is why it looked like a check cost. `even-tasks` shows the same: the wrapping body with checks (770.0M) equals the split (767.0M). The rest of its gap to 713M is the yield itself, as the record says.

**It isn't arm64-specific either.** The x86-64 code of the same loop puts `lea (rdx,r10,8) ; sub r10` on the chain as well (`x86.s`, `spin_main`). On pup the split took 13% fewer cycles on `even-par` and 17% fewer on `alloc-par` (trig-pup-2026-11-05.md). The README's "dependency chain on arm64; on x86 a fused dec" contrast rests on the `-tasks` rows, which that record itself says measured the build sharing the machine. On both targets the per-turn check is one fused compare-and-branch off the chain.

So the 14-21% is a property of one benchmark kernel, a loop-carried arithmetic recurrence with an induction term, and not of the yield check. Trig's hot loops are searches and pointer walks, not such recurrences. That explains why the gain never showed on Trig.

## 2. Loop shapes for short loops

The harness (`find`, a search of an array of 1-16 keys that returns at its match, called 100M times; the match moves through every position, then one miss, so the average is 1, 2.8, 4.9 and 8.9 turns). The figures are extra instructions per call over the same loop with no check (`find_none`), arm64:

| shape | 1 key | 4 keys | 8 keys | 16 keys | cycles against none |
|---|---|---|---|---|---|
| main (`subs`+`b.eq` per turn) | 2.5 | 5.2 | 9.1 | 17.1 | 3-13% more |
| **guard** (entry test `end-i < 1024`: a copy with no check; else today's loop) | 3.5 | 3.8 | 3.9 | 4.0 | 0-6% more |
| aligned blocks, one copy, no count (outermost only) | 10.0 | 8.8 | 8.5 | 8.2 | 9-36% more |
| mark (compare `i` with the next check's index) | 3.5 | 6.2 | 10.1 | 18.1 | like main |

On `spin` (200M turns): the guard is like main (2630M cycles; the long copy runs), aligned and split take 2236M, and mark takes 2634M.

The questions' shapes:
- **Split only when n >= 1,024 at entry, by a run-time guard.** This is the only shape cheaper than main on short loops: one compare and branch at entry (about 1 instruction more than main at 1 turn, even at 2, and 2 fewer per turn after). It is exact when the loop's count is its own:
  - An outermost loop starts its count at `tick_turns` (src/emit.zig:4047-4052), so a loop of fewer than 1,024 turns can never reach a check.
  - Any early exit is free there, since the count is dead after the loop.
  - An inner loop shares its outer loop's count. Its guard would compare `left < n.*` and subtract the turns run on every exit that stays in the function, which adds bookkeeping.

  The cost is a second copy of every guarded body. #966's profile already saw "LLVM inlined differently around the bigger loop bodies"; a full copy is a bigger version of the same risk.
- **A cheaper per-turn check (down-counter, fused compare, `subs`+`b.ne`).** There is nothing to gain. Today's check is already one fused `subs w,#1 ; b.eq` (`arm.s`, `find_main`), and the "mark" form is no cheaper. Per §1, the check's cycle cost is about zero once the chain is short.
- **Hoist to the back edge for non-leaf loops.** The check is already on the back edge: Zig's `while` continue expression (src/emit.zig:4116-4121, 4157). Only Zig's own `for` checks at the top (`top_turn`, emit.zig:4109). This shape has no lever.

**Estimate for Trig's short searches.** `mapper_map` runs 1 to a few turns. At 2-3 turns, the guard saves 1-3 instructions per entry against main's 4.5-6.5, so it recovers 20-45% of the loop check's cost. The upper bound for all checks is the signal arm (trig-pup-2026-11-05.md): 1.0-3.9% fewer instructions, including the function-entry `tickCall`. If loop checks are about half of that, the guard is worth roughly 0.2-0.8% of instructions. That is under the 1% bar before the duplicated bodies cost anything.

## 3. A per-target choice

It isn't needed and it isn't simpler. The effect isn't per-target (§1): x86 shows the same chain and the same gain on `-par` rows. A per-target loop shape would be honest only as a recorded fact, for example a `loop_shape` decided in src/storage.zig with the target as an input once std.target exists (queue row 32). That is two shapes to test forever, for a gain that sits in one kind of kernel.

Separately, any rebuild must move archive/loop-split's decisions out of emit. `leavesEarly` and `short` are decided in `emitRangeFor` (archive emit.zig:4465-4475, 4512). That breaks North Star 4. archive/loop-tick put its rule in storage (`loop_turns`), which is the right place.

## 4. What I would build, and what settles it

I would build nothing from the split. Its benchmark gain is real but comes from `nsw` codegen in one kind of loop. The check stays, and the split's gain on Trig is bounded at about zero (pup split2: 0.5-1.4% more instructions).

What the evidence does point to, outside this panel's question:
1. **The `nsw` recurrence shape** is a general codegen question: does Rig's fast-mode `nsw` ever cost more than it buys? Wrapping is a valid refinement of undefined overflow, but it gives up `nsw`'s proofs elsewhere (trip counts, address math). It is a Zig-ceiling study of its own, not a loop-split item, and nothing suggests it touches Trig.
2. **The guard,** only if the owner wants the question closed. The first step is a count, not a timing run:
   - Counters in Trig's emitted Zig, in the manner of the trig-tsrs call-count scripts, record entries and turns per `rig.turn` site on ts-pattern.
   - From them: the average turns per entry of outermost range loops and those loops' share of instructions.
   - The guard can reach 1% only if those loops average 4 or more turns and their turns are 0.5% or more of Trig's instructions. Otherwise drop it without building.

**Prediction for the Mac Trig run** (base against archive/loop-split, another panelist's job): no gain beyond noise, and a small rise in instructions as on pup. The arm64 gain lives in recurrences Trig doesn't have.

## Risks in this report

- The search harness is a stand-in for `mapper_map`: no inlining into a bigger function, and synthetic data. Its instruction counts are firm; its cycles are rough under load 10-13.
- The `even-par` arms are hand-edited emitted Zig, built with the flags `rig build --release=fast` uses (`-Ofast -fomit-frame-pointer -fno-stack-protector`). All arms print the same check value (77050).
