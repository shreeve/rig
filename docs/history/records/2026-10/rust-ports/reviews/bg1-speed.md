# Speed review: nbody, spectralnorm, mandelbrot, fannkuchredux (2026-10-29)

Rig main 1b2f4b59d (`bin/rig` of the production-agent worktree), Zig 0.17.0 and Rust
1.98.1, both LLVM 22.1.8. Rig `--release=fast`; Rust `rustc -C opt-level=3 -C
target-cpu=native` (rayon ones by cargo, LTO, one codegen unit, `panic = "abort"`).

**How measured.** Interleaved rounds, fastest of 5 to 9, with cycles and instructions
(`/usr/bin/time -l` on the Mac, `perf stat` on pup). The Mac (Apple M5) was shared with
another agent: load 2 to 24 during the runs, given on each table, so cycles are the number
to trust there, not wall time. pup (x86, Core Ultra 9 185H) was quiet (load 1 to 2) for the
nbody and fannkuch-plain rows, single runs pinned with `taskset -c 3`; another job raised it
to 7 to 10 during the fannkuch-fast rows. Scripts and binaries:
`/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-rig-production-agent-6dff9f/3f64bb60-d18e-40a4-bf7b-73ae5aadde91/scratchpad/bg1/`
(`tools/cyc.py`, `tools/pcyc.py`); on pup `/zfs/worktrees/rig-rust-ports/bg1/`. Rig on pup
is the emitted package (`RIG_OUT_DIR`) built there with `zig build-exe -Ofast
-fomit-frame-pointer`, as `rig build` does.

## 1. nbody-fast: 10% more cycles than rust-2

| Mac, n = 50M (load 2.1) | Gcycles | Ginstr |
|---|---:|---:|
| rust-2 | 3.84 | 11.2 |
| Rig nbody-fast.rig | 4.24 | 13.5 |
| Rig emit, magnitude pass two pairs at a time (`compare/zig/nbody/rig-mag2/`) | **3.91** | 12.0 |
| Zig ceiling, Rust's shape (`compare/zig/nbody/nbody-fast.zig`) | 3.78 | 10.6 |

| pup, n = 50M, core 3 (load 1.0) | wall | Gcycles |
|---|---:|---:|
| rust-2 | 1.25 s | 6.28 |
| Rig nbody-fast.rig | 1.42 s | 7.13 |
| Rig emit, magnitude pass two pairs at a time | **1.13 s** | 5.65 |

**Cause.** The magnitudes, `dt / (d2 * sqrt(d2))` for ten pairs, are the step's
long-latency work. The Rust stores Vec3 as three f64 and LLVM's SLP vectorizer pairs pairs:
its loop has 4 `fsqrt.2d` + 2 `fsqrt` and 4 `fdiv.2d` + 2 `fdiv`. The Rig port holds a
Vec3 in `Simd[Float, 4]`, so each pair's `d2` is a lane sum (`faddp`) and the magnitudes
stay scalar: 10 `fsqrt` + 10 `fdiv` per step (counted in the hot loop's disassembly), and
on x86 the same. Writing that one pass as `@Vector(2, f64)` over pairs (2h, 2h + 1) gives
one `@sqrt` and one `/` for two pairs and closes the gap on the Mac (within 2%) and makes
Rig 10% faster than Rust on pup.

Not the cause: the unused fourth lane, the 32-byte alignment, `rig.indexBelow`, the
run-time loops, `onOwnStack`, or the CPU model. Each was taken out of the emitted Zig in
turn with no gain (target `apple_m1`/`m4`/`m5` alike). A Rig variant with a three-Float
`obj Vec3` (`reviews/bg1-probes/nbf3.rig`) gets LLVM's pairing (4 `fsqrt.2d`) and Rust's
instruction count, yet runs at 4.25 Gcycles: the layout alone does not help; the pairing
of the division chain does.

**Fix: the compiler's std/Simd, then the port.** `Simd[Float, n]` lacks `/` and
`math.sqrt` (the speed expert's gap 4). With them the port's `pairwise` becomes:

```rig pending
type F64x2 = Simd[Float, 2]
  for h in 0..N_PAIRS / 2
    d2 = F64x2([squared_norm(diff[2 * h]), squared_norm(diff[2 * h + 1])])
    m = F64x2.splat(dt) / (d2 * math.sqrt(d2))
    mag[2 * h] = m[0]
    mag[2 * h + 1] = m[1]
```

Each op is one `@Vector` builtin in emit (sema's operator table and `std/math.rig`'s
`sqrt` taking a `Simd`). Nothing else in nbody-fast needs to change.

Aside: a three-f64 Zig ceiling matches Rust on the Mac but is 24% slower than Rust on pup,
and run-time loops in it cost 5% on the Mac and 2x on pup; Rig's `Simd[Float, 4]` layout is
the better one on x86. Not chased further.

## 2. fannkuchredux plain: 8% more cycles than rust-2

| Mac, n = 11 (load 4) | Gcycles | Ginstr |
|---|---:|---:|
| rust-2 | 6.30 | 11.8 |
| Rig fannkuchredux.rig | 6.82 | 17.6 |
| Rig, `rig.turn` made a no-op | 6.56 | 14.0 |
| Rig, `slices.reverse` → `std.mem.reverse` | 7.51 | 11.2 |
| Rig, reverse written as an unchecked swap loop, no tick in it | 6.33 | 11.5 |
| **port with a local `flip` (below)** | 6.43 | 17.9 |
| port `flip` + mirror index proven (`compare/zig/fannkuchredux/rig-flip-proven/`) | **6.37** | 14.8 |

| Mac, n = 12 (load 7 to 11) | wall | Gcycles |
|---|---:|---:|
| rust-2 | 5.30 s | 83.9 |
| Rig fannkuchredux.rig | 6.16 s | 90.6 |
| port `flip` | 5.78 s | 85.6 |
| port `flip` + mirror index proven | 5.58 s | 84.2 |

On pup (n = 12, four P-cores, load 1) there is no loss: rust-2 110.0 Gcycles, Rig 109.4;
the unchecked reverse 102.5 (7% fewer than Rust).

**Cause.** `slices.reverse` (std/slices.rig) is `while i < j: swap(xs, i, j)`, and
`rig.swap` casts and checks both indexes and tests `a == b`; the program makes tasks, so
the loop also ticks (`rig.turn`). The swap loop is 13 instructions a swap on arm64
(`cmn`/`b.eq`, `cmp`/`b.hs` on `j`, two loads, two stores, the tick's `subs`/`b.eq`, the
`i < j` compare) against Rust's 6 (`ldr ldr str str subs b.ne`). On the Mac's flip loop,
which is branchy and short (k ≤ 12), that is the 8%. `std.mem.reverse` is worse (vector
code for short runs).

**Fixes, ranked.**
1. **std** (`std/slices.rig`): write `reverse` as a counted loop over the first half with
   the mirror index, which the port can do today:
   ```rig
   sub flip(p: ![]Int)
     k = p.len
     for i in 0..k / 2
       t = p[i]
       p[i] = p[k - 1 - i]
       p[k - 1 - i] = t
   ```
   6% fewer cycles than the port now, 2% more than Rust (`reviews/bg1-probes/fk_flip.rig`).
   Every caller of `slices.reverse` gains; the port should not need its own.
2. **proofs** (src/proofs.zig): prove the mirror index `n - 1 - i` for `i` in `0..n / 2`
   (and `0..n`) with `n = xs.len`: one fewer compare and branch a swap; with it Rig is within 1% of Rust.
3. **The tick** (`rig.turn`) in a loop whose trip count is bounded by a slice's length
   costs 2 to 4% here. A loop over `0..xs.len` (or half of it) is finite and short;
   skipping its tick is the inlining/emit pass's call (the pass that places `turn`).
   Owner's call: it trades preemption latency for speed.

## 3. The builder's emit gaps

**Gap 1, a `fun` value is not specialized: confirmed, with a condition.** The builder's
probe p1 does not show it: `row` is `inline`, so after inlining `at` is a constant and
LLVM makes the call direct and inlines `a` (no `blr` in the binary). It shows when the
function taking the `fun` is a real function: `reviews/bg1-probes/p1b.rig`, where `mul(m:
fun(Int, Int) -> Float, n)` is called with two functions and passes `m` into a `par.map`
closure, emits `pub fn mul(m: *const fn (i64, i64) f64, ...)` and its hot loop is `blr x22`
per element, `a` not inlined. That is spectralnorm's 4x. **Compiler:** when every call
site passes a named top-level function (not a closure value), specialize: emit the
parameter as `comptime m: fn (i64, i64) f64`, one instance per function. The decision is
program-wide, so it belongs in src/inlining.zig (or symbols.zig), recorded as a fact emit
reads.

**Gap 3, a compile-time self-call: confirmed, cause narrowed.** `at[true]` calling
`at[false]` is emitted as `pub fn at(comptime transposed: bool, ...)` with `rig.tickCall()`
at its entry, because the cycle cutter sees `at → at`. LLVM inlines it anyway (no call in
the binary); the cost is the `tickCall`, a load of `sched.waiting` and a branch per call,
which also blocks LLVM's vectorizing of the four `at` calls in `pair`. Rebuilt
spectralnorm-fast with the self-call (`reviews/bg1-probes/sn_self.rig`, n = 5500, Mac load
12): 2.09 Gcycles, 13.4 Ginstr; the same emit with only `rig.tickCall();` deleted: 1.26 and
8.3, equal to the separate-function port. The builder's 1.7x is exactly the tick.
**Compiler:** src/inlining.zig's `cutCycles` should key the call graph by instance
(function plus compile-time arguments): `at[true] → at[false]` is no cycle, so `at` is
`inline` with no tick.

## 4. Fairness

| Benchmark | Same algorithm | Same output | Build care | Note |
|---|---|---|---|---|
| nbody, plain and fast | yes | yes (both 1000_out and 50M) | yes | Rust `native` resolves to `apple-m4`, Zig to `apple_m5`: no difference measured (both ways) |
| spectralnorm, plain and fast | yes | yes | yes | fast Rig allocates a List a product where Rust reuses `tmp` (against Rig) |
| mandelbrot, plain | yes (50 steps, test each, stop at 0xff) | md5 equal | yes | Rust as published uses `[f64; 8]` arrays and the loop vectorizer; Rig's `Simd[Float, 8]` + `bits()` is the gain, not a different algorithm |
| mandelbrot, fast | yes | md5 equal | yes | |
| fannkuch, plain | yes | yes | yes | Rust `i32`, Rig `Int` (builder: `I32` changed nothing) |
| fannkuch, fast | **no, on the Mac** | yes | yes | Rig follows rust-6 (shuffle masks); the Mac times it against rust-4 (scalar), since rust-6 is x86-only |

`-C codegen-units=1 -C panic=abort` on the crate-free Rust changed nothing (pup: nbody-fast
6.28 vs 6.32 Gcycles, fannkuch 110.3 vs 110.1).

fannkuch-fast against the same algorithm (rust-6, vendored rayon, pup): on all 22 cores
Rig is 16% slower in wall time (0.91 s against 0.79 s) with 7% more cycles; on six P-cores
it is within 3% (1.89 s against 1.83 s, equal cycles). In Rig's flip loop on x86 the lookup
adds `vpaddusb` before `vpshufb` (Rig's out-of-range-gives-0 rule), `p[head]` stores the
vector byte by byte, and a tick runs per flip: taking these out gave 3 to 6% fewer cycles
each, measured while pup's load rose to 9, so unconfirmed. The all-core gap looks like load
balance over P- and E-cores (132 unequal blocks; rayon steals), a lead for `par.map`, not
measured. The Mac row should say "against rust-4, another algorithm".

## 5. Decisions (defaults)

1. Add `/` and `math.sqrt` for `Simd[Float, n]` and rewrite nbody-fast's magnitude pass
   (10% on the Mac, 20% on pup). Default: yes, in the float-SIMD round the speed expert
   proposed.
2. Rewrite `std.slices.reverse` as a counted half loop with the mirror index; the plain
   port keeps `slices.reverse`. Default: yes, a std PR from a failing speed note.
3. Prove the mirror index `n - 1 - i` in src/proofs.zig. Default: yes, with 2.
4. Key `cutCycles` by compile-time instance (gap 3). Default: yes, small and measured (1.65x).
5. Specialize `fun` parameters passed only named functions (gap 1). Default: design note
   first (it touches inlining and closures); the port keeps its `[transposed: Bool]`.
6. Skip `rig.turn` in loops bounded by a slice length. Default: ask the owner (preemption).
7. The fannkuch-fast Mac row names rust-4 as another algorithm. Default: yes.
