# Inlining ray_color: what x86 and arm64 do with it (2026-10-30)

A study for the backlog entry from #777 ("a generic function is inlined by
the size rule"), which recorded ray-dyn at 6% more cycles on pup and 3%
fewer on the Mac once the size rule inlined `ray_color`. Measuring only:
no compiler change. Raw data beside this file.

## Summary

1. **#777 does not change ray-dyn's machine code.** Without the `inline`
   mark, the rig before #777 emits `ray_color` and `draw_row` as plain Zig
   `fn`s, and LLVM inlines both into the row task's thunk anyway. After
   #777 Zig inlines them (`inline fn`). Built from either emit, the hot
   function is the same instruction for instruction on both machines,
   apart from register names, spill-slot offsets, and one 16-byte pad.
2. **On x86 placement makes no difference.** All six arms are within 0.6%
   of each other on pup (core 6, one worker), at 50 samples and at the
   PR's 10. The PR's 36.6 against 38.8 billion cycles does not reproduce:
   here the two are 40.84 and 40.93. Nor does the frontend matter: the DSB
   delivers 99.9% of uops in every arm, and aligning the hot entry and
   thunk to 64 bytes changes nothing.
3. **On arm64 keeping `ray_color` out of line is better.** With
   `noinline` on `ray_color`, ray-dyn runs 6.2% fewer instructions and
   2.2% fewer cycles (5 rounds, under load). The merged function leaves no
   callee-saved FP register for a loop invariant, so World.hit's loop
   rebuilds the constant `0.001` in every iteration, 5 instructions
   around each indirect call. x86-64's SysV saves no XMM register across a
   call, so both forms reload it there, and outlining gains nothing.

## The arms

Each arm is the Zig a rig emits for ray-dyn.rig (600×400, 50 samples,
depth 50), with at most one line changed by hand, built by `zig build-exe
-Osafe -fomit-frame-pointer` as `rig build --release` does. Every arm
writes the same image.

| Arm | Source | `ray_color` | `draw_row` |
|---|---|---|---|
| A | rig before #777 (4e88cbdfa), `inline` mark kept | `inline fn` | `fn` (LLVM inlines it) |
| B | rig after #777 (06d90366c), mark or none (the same emit) | `inline fn` | `inline fn` |
| G | rig before #777, no mark: the PR's "main" (the rig before the PR, 4068c4798, emits the same) | `fn` (LLVM inlines it) | `fn` (LLVM inlines it) |
| F | B, `ray_color` made `noinline` | out of line | `inline fn` |
| D | B, `draw_row` made `noinline` | `inline fn` | out of line |
| G64, B64 | G and B, with the API table's `hit` entry and FnRef's thunk `align(64)` | as G, B | as G, B |
| G10, B10 | G and B at 10 samples, the PR's pup setting | as G, B | as G, B |

A and B differ in `draw_row` and in `math.abs`, but compile to the same
code at the same addresses on both machines; only Zig's instance numbers
in symbol names differ.

## pup (x86-64, Core Ultra 9 185H)

Core 6, sibling 7 idle, `RIG_WORKERS=1`, 4 interleaved rounds (5 for
G10, B10), built on pup with `-mcpu=native`. Fewest cycles, in billions:

| Arm | Cycles | Instructions | DSB uops | MITE uops |
|---|---:|---:|---:|---:|
| G | 203.72 | 996.13 | 1079.5 | 0.89 |
| G64 | 203.81 | 996.22 | 1079.4 | 1.09 |
| B64 | 204.26 | 996.15 | 1080.1 | 0.87 |
| B | 204.44 | 996.21 | 1080.1 | 0.95 |
| D | 204.64 | 1012.08 | 1096.7 | 0.97 |
| F | 204.96 | 996.42 | 1081.1 | 1.00 |
| G10 | 40.84 | 199.50 | | |
| B10 | 40.93 | 199.50 | | |

The widest gap, F against G, is 0.6%, under the 2% a single comparison
can show. Outlining `draw_row` (D) costs 1.6% more instructions and no
cycles.

## Mac (arm64, Apple M5)

Through `tools/low`, `RIG_WORKERS=1`, 5 interleaved rounds, load 4.8 to
12 (round 5 under the heaviest). Fewest cycles and instructions, in
billions:

| Arm | Cycles | Instructions | Fastest wall |
|---|---:|---:|---:|
| F | **113.70** | **947.97** | 28.36 s |
| D | 114.45 | 947.22 | 28.88 s |
| G64 | 116.08 | 1010.91 | 30.02 s |
| A | 116.09 | 1010.91 | 29.07 s |
| B | 116.13 | 1010.91 | 28.97 s |
| G | 116.27 | 1010.90 | 28.52 s |
| B64 | 116.40 | 1010.94 | 29.76 s |

The four inlined arms tie, as their code does. F takes 2.2% fewer cycles
than G and D 1.6% fewer, both with 6.2% fewer instructions. Wall time,
under this load, shows F only 0.6% faster, so the cycle gain needs 20
quiet interleaved rounds before it counts (AGENTS, "Speed").

## Why arm64 gains and x86 does not

`hit-loop.txt` has the loop over the world's objects in G and F, on both
machines. Each iteration makes one indirect call, `o.vt.hit(o.ptr, r, lo,
closest)`, with `lo` the constant 0.001.

- **arm64, G:** `lo` has no register to stay in across the call. The
  function holds every loop of the row (pixels, samples, bounces,
  objects), and their live FP values fill the eight callee-saved
  registers, d8 to d15. So each iteration rebuilds `lo` with `mov`, three
  `movk` and an `fmov`, and its loop is 19 instructions.
- **arm64, F:** `ray_color` holds only the bounce and object loops. `lo`
  stays in d8 and `hi` in d9, and the loop is 15 instructions. Four fewer
  instructions for each of the scene's several hundred objects, each
  bounce, are the 6.2%.
- **x86-64, both:** SysV preserves no XMM register across a call, so both
  load `lo` from memory before each call (`vmovsd` from the constant
  pool), and both get the hit back through memory. Their loops are the same
  length. The PR's measurement aside, nothing in the code makes the
  inlined form slower on x86. The register file is the only difference,
  and it favors outlining only where FP registers are callee-saved.

## Recommendation for the size rule

1. **Correct the backlog entry.** The inlined `ray_color` costs nothing on
   x86. #777 changed no machine code for ray-dyn, and the PR's two
   numbers on each machine did not come from the code: the pup "6% more"
   and the Mac "3% fewer" both measured identical programs.
2. **The weight worth considering is register pressure across a call
   that stays a call, not size, call depth, or alignment.** The case: a
   function whose loop makes a call that is never inlined (through an API
   table, a `rarely` function, a closure), inlined into a caller with
   loops of its own. On arm64 the merged function runs out of
   callee-saved registers, and the inner loop pays for it each iteration.
   A rule could keep such a function out of line, as `noinline`. A plain
   `fn` is not enough: G shows LLVM inlining it anyway.
3. **Don't build it yet.** The evidence is one program and 5 rounds under
   load, with a 2.2% cycle gain on one machine and a 0.6% loss within
   noise on the other. Before building it:
   - run 20 quiet interleaved rounds of G against F on the Mac;
   - find how many functions the rule would move out of line in Trig, and
     measure ts-pattern both ways against Trig's bar (more than 1.5%
     faster, or 1% fewer instructions on one checker).

   It is a candidate only if both hold.

Not studied here: Trig's 200 KB higher peak memory in #777, which the
backlog puts to larger frames.

## Files

- `mac-rounds.txt`: every Mac run (round, arm, wall, cycles, instructions, peak RSS).
- `pup-rounds.txt`: every pup run, summarized; `pup-perf.txt`: the raw `perf stat` output.
- `hit-loop.txt`: World.hit's loop in G and F, arm64 and x86-64.
