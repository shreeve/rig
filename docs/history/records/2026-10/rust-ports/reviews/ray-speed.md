# Speed review: Ray Tracing in One Weekend (2026-10-29)

Rig main 81a1ef486 (the baseline `rig` on the Mac; `/zfs/worktrees/rig-rust-ports/rig/bin/rig`
on pup), Zig 0.17.0; Rust 1.98 (`target-cpu=native`, LTO, one codegen unit, `panic =
"abort"`). 600 x 400, 50 samples, depth 50. Rig `--release=fast` unless marked safe.

**How measured.** Interleaved rounds, fastest of 3 to 7, cycles and instructions from
`/usr/bin/time -l` on the Mac (Apple M5, 10 cores; load 2 to 29 while timing, so cycles are
the number to trust) and `perf stat` on pup (x86 Core Ultra 9 185H, six threads on cores
0-5, `taskset`; another agent held cores 6-21). Ablations are the emitted Zig edited by hand
and rebuilt with `zig build-exe -Ofast -fomit-frame-pointer`, as `rig build` does. Probes,
diffs and raw runs: `reviews/ray-speed-probes/`; scratch binaries:
`/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-rig-production-agent-6dff9f/3f64bb60-d18e-40a4-bf7b-73ae5aadde91/scratchpad/ray/`;
on pup `/zfs/worktrees/rig-rust-ports/ray/`.

## 1. Fairness: fair, and if anything kind to the Rust

**f32 against f64.** Rig can do f32: `Simd[F32, 4]` takes `+ - *`, splats and lanes, and
`F32` scalars work. `std.math` has no `F32` functions (`sqrt`, `sin`, `cos` take `Float`), so
the variant writes `F32(math.sqrt(Float(x)))`; LLVM folds that to one `fsqrt s`. The f32
port (`ray-speed-probes/f32/`) looks the same (mean pixel 140.7 against 140.9) but is no
faster: 18% more cycles on the Mac in one run, 7% more on pup (228.5 against 212.9
Gcycles), because f32's cancellation on the radius-1000 ground sphere makes rays hit their
own surface: it traces 8% more rays (35.5M against 32.8M), the same cost a ray.

The other way round, the Rust built in f64 (`rust/build-f64.sh`, every `f32` made `f64`)
takes 8% fewer cycles than its own f32 on pup (340 against 368 Gcycles in the final run; 11%
in single runs) and 7% more on the Mac (134 against 126). So the f32 Rust is the Rust at its best on the Mac and not on
pup; the tables below show both, and the fair Rust row is the faster of the two.

The notes' guess that f32 explains the Rust image being 3% brighter (145 to 146 against 141)
is wrong: Rig in f32 gives 140.7. The difference is the edition (the Rust's older Lambertian
and glass) and its `u = (x + r) / nx`, not precision.

**The work.** Same scene shape (ground, 22 x 22 grid, three large; about 485 spheres), size,
samples and depth (50 bounces then black in both). Rays traced, counted by an instrumented
build of each (`ray-speed-probes/count/`, and a Rust copy with an atomic counter): Rig 32.8M,
Rust 32.0M (another run 31.6M): Rig does 2.5% more work. RNG: the Rust's `thread_rng`
(ChaCha12) is 0.5% of its profile on pup, Rig's splitmix64 too small to show; neither
matters. Rows: both split by row (rayon `into_par_iter` over 400 rows, `par.map` over 400
`Row`s). Output: both build the image in memory and print it at the end.

## 2. Where ray.rig's time goes

The sphere loop in `World.hit` is 97% of pup's `perf` samples; scatter, the camera ray, the
random vectors and the output are the other 3%. Everything is inlined into `draw_row`'s task
thunk, so the Mac's `sample` sees one function.

**The loop is what a Zig programmer would write** with `@Vector(4, f64)`: `a = dot(dir, dir)`
hoisted out of the loop, `oc` as two `fsub.2d`, each dot as two `fmul.2d`, `faddp`, `fadd`; a
miss is 26 instructions on arm64, 17 of them floating point, about 5.4 cycles a sphere (the
M5's four FP pipes are the limit). On x86 the dots are `vmulpd` on `ymm` then `vshufpd`,
`vextractf128` and two `vaddsd`; the lane-sum chain holds the hottest samples. A `@reduce`
would emit the same. Bounds checks are gone (safe mode: 420.6 against 420.4 Ginstr).

| Cost | Share | Fix | Where |
|---|---|---|---|
| `rig.turn` in the sphere loop: `subs`/`b.eq` a sphere, and since the tick may call out, the list's base pointer is reloaded each iteration | 15% of instructions (Mac 420 to 357 G, pup 422 to 374 G); 4% of cycles on the Mac (84.7 to 81.2), 3% on pup (212 to 205) | no tick in a loop bounded by a list's length whose body cannot loop or block (or tick the outer `for 0..DEPTH` instead) | compiler: the pass that places `turn` (bg1-speed's item 6, the owner's call: preemption latency) |
| `World.hit` computes `p`, `normal`, `front` for every closer hit (the book's way) | none: a two-phase search over packed centers (`ray-speed-probes/pack/`, the same image byte for byte) took 2 to 6% *more* cycles | none | |
| Sphere stride (112 bytes on arm64, 160 on x86: 77 KB, beyond pup's 48 KB L1) | none: packing cut pup's L1 misses from 225M to 6M and gained nothing | none | |
| `r * r` recomputed a sphere | 1 of 26 instructions | the book's form; storing `radius²` would be a port change outside the book | port (not worth it) |

Not measured: a three-`Float` `obj Vec3` in place of `Simd[Float, 4]` on x86 (bg1 found it
24% slower for nbody on pup).

## 3. ray-dyn: the table call, plus two costs Rust does not pay

Per sphere, ray-dyn runs a caller step (tick, load box and table, `blr`, load the result's
niche byte) and the entry (`Sphere.hit` inlined into `__rig_entry_hit`): 47.5 instructions a
sphere on the Mac (Rust f32: 43), 57 on pup (Rust f64: 50). The `Ray` goes by pointer (Zig
passes the 64-byte object by reference already); the `from @` view is a pointer into the
box, no copy. Rust's profile has the same shape: 66% in `Sphere::hit` through the vtable, 32%
in the caller. What Rig adds:

1. **The entry returns `Hit?` (88 bytes) by value, and a miss writes all of it.** `Niche.wrap`
   (src/runtime.zig) builds an `o` with undefined payload and stores the niche; LLVM merges
   the hit and miss returns, so a miss stores five junk payload words (two 32-byte `vmovapd`
   on x86) before the niche byte. In `--release` the undefined bytes become `0xaa` fills
   (`movi.16b #0xaa` four times), which is why ray-dyn-safe runs 34% more instructions than
   ray-dyn. Splitting `wrap`'s two returns changed nothing. The ceiling
   (`ray-speed-probes/emit/out-param-entry.diff`): the table entry takes `*const Ray` and a
   `*Hit`, writes it only on a hit, and returns `bool`. Same image; pup 400 to 344 Gcycles
   (14% fewer), the Mac 122 to 108 (11% fewer). **Emit** (src/emit.zig, the API table): an
   entry whose result is an optional object wider than a few words returns its flag and
   writes the payload through an out-parameter; the call site unwraps into a local.
2. **The tick** (as in ray.rig): pup 436 to 400 Gcycles (8%); nothing on the Mac.
3. Safe mode only: `@alignCast` in `erasedSelf` tests the erased pointer's alignment
   (`tst`/`b.ne`) on every call. Small; the runtime could trust a box it made.

With 1 and 2, ray-dyn on pup is 344 Gcycles against the Rust's 354 (f64) and 398 (f32) in
the same session, and in the final interleaved run 326 against 340 and 368: level with the
f64 Rust's `Box<dyn>` in wall time (17.82 s each). What remains, about 1.6x ray.rig, is the indirect call per sphere, which nothing can
inline and Rust pays too.

## 4. Times

**Mac** (M5, all 10 cores; 7 interleaved rounds; load 13.8 at the start, 29 at the end, so
wall times are rough and cycles the better guide). Wall is the fastest of 7; Gcycles and
Ginstr are the fewest of 7.

| Mac | Wall | CPU | Gcycles | Ginstr |
|---|---:|---:|---:|---:|
| Rust f32 (as published, system malloc) | 4.88 s | 41.0 s | 125.6 | 659 |
| Rust f32, mimalloc | 4.71 s | 40.0 s | 125.6 | 654 |
| Rust f64 (`rust/build-f64.sh`) | 5.15 s | 41.2 s | 133.9 | 663 |
| `ray.rig`, fast | **3.11 s** | 26.9 s | **84.8** | 420 |
| `ray.rig`, safe | 3.38 s | 26.5 s | 84.9 | 421 |
| `ray-dyn.rig`, fast | 4.97 s | 42.1 s | 123.3 | 756 |
| `ray-dyn.rig`, safe | 6.24 s | 52.0 s | 155.5 | 1,011 |

**pup** (x86, six threads on cores 0-5, `taskset`; 7 interleaved rounds; machine load 11.5
to 14.5 from the other agent on cores 6-21). Wall and CPU from `/usr/bin/time`, cycles and
instructions from `perf stat` (P-core counters).

| pup | Wall | CPU | Peak memory | Gcycles | Ginstr |
|---|---:|---:|---:|---:|---:|
| Rust f32 (system malloc) | 19.19 s | 95.2 s | 3.6 MB | 368 | 747 |
| Rust f32, mimalloc | 18.62 s | 97.6 s | 12.6 MB | 370 | 751 |
| Rust f64 | 17.82 s | 93.1 s | 3.5 MB | 340 | 775 |
| `ray.rig`, fast | **9.88 s** | 51.5 s | 7.6 MB | **199** | 422 |
| `ray.rig`, safe | 10.19 s | 51.5 s | 8.1 MB | 200 | 422 |
| `ray-dyn.rig`, fast | 21.60 s | 113.2 s | 7.9 MB | 404 | 901 |
| `ray-dyn.rig`, safe | 22.17 s | 116.2 s | 7.9 MB | 425 | 997 |
| ray-dyn emit, no tick + out-parameter entry (ceiling) | 17.82 s | 87.6 s | 8.0 MB | 326 | 678 |

`ray.rig` takes 36% less time than the Rust on the Mac (34% less than with mimalloc) and 45%
less than the faster Rust (f64) on pup. `ray-dyn.rig` is level with the Rust on the Mac
(within noise) and takes 21% more time than the f64 Rust on pup (13% more than f32); with
the two fixes of section 3 it ties the f64 Rust there. mimalloc changes nothing: neither
allocates in the loop.

## 5. Decisions (defaults)

1. Emit API-table entries with a large optional result through an out-parameter (11 to 14%
   on ray-dyn, more in safe mode). Default: yes, an emit change with a `code` test.
2. No `rig.turn` in a loop over a list's length whose body has no loop or call that can
   block (3 to 4% on ray.rig, 8% on ray-dyn on pup). Default: ask the owner, with bg1's item 6.
3. `F32` versions of `math.sqrt`, `sin`, `cos` (`abs` is already generic; today an `F32`
   program converts through `Float`, and LLVM folds `sqrt`). Default: not now; nothing here
   needs them, and the f32 port is slower for a reason that is not Rig's.
4. notes.md: correct the f32 guess for the brightness, and add the f64 Rust row. Default: yes,
   by the builder (results.md beside it holds the numbers).
