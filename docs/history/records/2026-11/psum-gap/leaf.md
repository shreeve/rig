# psum gap, the leaf (2026-11-18)

Worktree `~/Data/Code/worktrees/rig/psum-leaf` (from origin/main 3ffd5672d), branch `psum-leaf`,
draft PR https://github.com/shreeve/rig/pull/1151 (commits 05c7c7710, ab5359c6a, c4f72cafa).
pup slots 560-569 (ab, quiet honoured every time); Mac claims `leaf-sep`, `leaf-shapes`, `leaf-sep2`.
pup outputs: /zfs/trig-pup/psum-gap/leaf/ (`*.json` per board, programs, `mb/` microbenches).
Mac scratch: /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/45a7b8df-588d-46f9-ab76-f1ed2a2c6a62/scratchpad/leaf/.

## 1. Answer

The one-worker gap has three parts, in different places on the two machines.

| part | pup (x86-64) | Mac (M5) | owner |
|---|---|---|---|
| leaf loop shape (`rig.fold`'s 16 x 16-byte vectors a turn) | **~2 ms of 2.4** (fixed here) | none (no shape is faster) | leaf (me) |
| traversal order: fork.rig spawns the LEFT half, so at 1 worker the leaves run right to left | ~0.7 ms | **~1.2 ms of 1.5** | the program / lead |
| preemption monitor waking every 50 us while a ring holds work | ~0.4 ms (3%) | ~0.1 ms (2-3%) | sched expert |

Per-fork cost (spawn + ring join) is small at 1 worker: Rig with GRAIN 2^20 (31 forks) still paid ~1 ms
on pup before the fix, all of it leaf shape + monitor.

## 2. The leaf, disassembled

- Rig (`seq_sum`/`psum` leaf -> `rig.fold(.add_wrap, ...)`, inline): 4 accumulators, 16 vectors of
  16 bytes a turn (256 B), `__rig_preempt = true` so `rig.turn`/`tickCall` compile to nothing (no yield
  check in the loop); one redundant bounds check a turn (`i+32 <= len`, a cmp/ja, free). arm64: 8 `ldp q`
  + 16 `add.2d` a turn. x86 (pup, `-mcpu=native`, AVX2): 16 `vpaddq xmm, xmm, [mem]`; LLVM schedules
  the loads out of address order (0x00,0x20,0x30,0x40,...,0x10,0x50,0x90,0xd0).
- Rayon twin: arm64 2 `ldp q` + 4 `add.2d` (64 B a turn); x86 baseline SSE2 (no target-cpu): 2
  accumulators, 2 `movdqu`+`paddq` (32 B a turn); with `-C target-cpu=native`: 4 ymm accumulators,
  128 B a turn.
- **Target-CPU parity:** Rig builds `-mcpu=native` (Zig's default; AVX2 on pup), the twin baseline
  x86-64 (SSE2). So the board favoured Rig in features, and Rig still lost. Rayon built native is
  1-2% faster than baseline on psum (11.68-11.94 vs 11.88-12.11 ms): memory bound, width barely matters
  to Rust's shape.

## 3. Separating the leaf from the rest (1 worker, warm = 2nd/3rd call in the process)

pup, P-core 6, medians of 15 (sep-pup1/2/3/5.json), ms:

| program | psum | its seq over all 2^25 |
|---|---:|---:|
| Rayon twin | 11.88-12.11 | 11.70-11.78 |
| Rayon twin, join reversed (right half first) | 12.87-13.07 | 11.40-11.62 |
| Rig fork.rig (spawn left) | 14.07-14.34 | 11.65-11.79 |
| Rig, spawn right (Rayon's order) | 13.27-13.31 | 11.65 |
| same, `RIG_PREEMPT_WAIT_US=10000` | 12.80 | 11.65 |
| Rig GRAIN 2^20 (31 forks), quiet monitor | 12.47 | 11.65 |
| Rig plain recursion, no `&`, no tasks | 12.43-12.47 | 11.75 |

Leaf alone (s3, Rust `seq`): level, 11.77 vs 11.75 warm, 12.03 vs 11.37 cold. But the leaf at
8,192-element granularity was not: plain recursion with no tasks cost 0.7 ms over one whole fold.
perf stat (E-core): Rig psum process 1,352-1,390 context switches against 1 for the no-task program;
`RIG_PREEMPT_WAIT_US=10000` cuts them to 113 (the board's `taskset -c 6` puts the monitor thread on
the worker's core). 87 preemption signals (tgkill) a run.

Mac (sep1/sep-mac2.json, 10-12 rounds): Rig seq 3.52-3.66 vs Rust 3.57-3.64 (level); Rig psum 5.05-5.25
vs Rayon 3.61-3.68; Rig spawn-right 3.83 (p3r), with quiet monitor 3.71-3.75; plain recursion 3.55
(no cost). So on the Mac the leaf is level and the order is the gap.

## 4. Why the leaf shape: Zig microbench (pup, mb/mb3.zig, mb4.zig)

256 MB of i64 from mmap, runtime length, warm, medians of 10 (ms). `LxR` = 4 sums of L-lane vectors,
R rounds a turn (rig.fold today = 2x4).

| shape | whole | leaves of 8,192 |
|---|---:|---:|
| 2x4 (rig.fold, 16 x 16 B) | 13.13-13.36 | 13.31-13.50 |
| 2x2 | 13.0 | 12.9-13.1 |
| 2x1 (Rust's) | 11.65-11.77 | 11.90-11.92 |
| 4x1 (Rust AVX2) | 11.65-11.82 | 11.78-11.91 |
| 4x2 | 11.42-11.60 | 11.40-11.58 |
| **4x4 (this change: 16 x 32 B)** | 11.28-11.61 | 11.34-11.63 |
| 8x1 | 11.12-11.22 | 11.23-11.31 |

Huge pages (MADV_HUGEPAGE) change nothing. The unrolled 16-byte shapes (2x2, 2x4) are 12-15% slower
from memory on this core; every 32-byte shape and Rust's un-unrolled 16-byte one run at full speed.
I did not pin down the microarchitectural cause (candidates: the L1/L2 prefetchers' view of the
out-of-order 16-byte load stream). On the Mac (mb2, claim leaf-shapes) every shape is level.
Rig's whole-array `seq` escaped it only because LLVM unrolled that call 2x with a known length.

## 5. The fix (PR #1151)

`foldLanes(T)`: the widest vector the target adds, at most 32 bytes (`std.simd.suggestVectorLength`,
floor 16 B). Sixteen vectors a turn kept, so the checked-`+` bound per turn amortizes as before
(c = 16 x lanes; c*m still fits i128). arm64 code identical (disassembly diff empty). Emit, storage,
facts untouched: the decision is still the recorded `fold`; only the runtime's loop body differs.

Final board (pup slot 569, fork.rig, 1 worker, 20 rounds, paired): A/A 0.994 [0.948-1.070];
**branch 0.860 [0.829-0.886], 20 of 20**: 14.32 -> 12.37 ms; Rayon 11.97 (Rig was 20% slower,
now 3.3% slower). qsort 0.996 (A/A 1.000). 12 workers: 5.91 -> 5.72, paired 0.964 [0.901-1.137],
A/A 1.029: inside noise; Rayon 4.62 (Rig 24% slower: not the leaf).
With Rayon's traversal order (spawn right) the branch is faster than Rayon at 1 worker: 11.67 vs
12.09-12.20 warm.

Sums bench (pup, before -> after): hot checked Int 8.21 -> 3.50, hot `+%=` 2.08 -> 1.52, hot `^=`
2.10 -> 1.52, hot I32 2.71 -> 1.55, memory checked 13.29 -> 12.10, memory `+%=` 17.29 -> 14.76,
memory `^=` 17.26 -> 14.62. bench/tasks/actors/net at 12 workers: within A/A.

Tests: runtime fold test extended to lengths 1,100 (two byte turns at 512); passes on pup
Debug/ReleaseSafe/ReleaseFast (`zig test src/runtime.zig --test-filter fold`; pup's checkout has no
Nexus for `zig build test`), and `zig build test` debug/safe/fast on the Mac. emit-loop fold bombs
resized to reach a whole 32-byte turn; the five fold cases run on pup debug and release as expected.
Trig light gate GREEN (162 s). Not run: loco gate (arm64 unchanged), guards (unchanged by
construction: std/Trig emit no folds), core suite green on the Mac (12,140 jobs, none died).

## 6. For the others

- **Sched expert:** the slice monitor (`watchSlices`, sched.zig) wakes every `RIG_PREEMPT_WAIT_US`
  (50 us) whenever a worker's ring holds work, which psum's always does, and signals the worker
  when one fiber ran two periods with work queued (87 signals a run). At 1 worker pinned to one core
  that is ~1,300 context switches a run and 0.35-0.45 ms (3%) on pup, ~2-3% on the Mac. A fork-join
  ring of the running fiber's own children perhaps should not count as "work waiting".
- **Lead / program:** fork.rig spawns `psum(left)&` and computes the right half itself; rayon::join
  runs its FIRST closure (left) here and offers the second. The faithful Rig twin is
  `b = psum(xs[mid..])&; a = psum(xs[..mid]); a +% >b`. With help-first tasks the current order
  walks leaves right to left at 1 worker, which costs 0.7 ms on pup and 1.2 ms on the Mac (Rayon
  itself loses 1.0-1.2 ms on pup when its join is reversed). Changing the record's program is the
  lead's call.
- **Memory expert:** huge pages made no difference to the leaf microbench; the memory-bound rows here
  are shape-limited, not TLB-limited.
- Not done: a tail stage for short folds (on x86 a fold of fewer than 64 Ints is now all scalar,
  was < 32); AVX-512 capped at 32 B untested (no machine).
