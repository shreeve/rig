# Idiom and beauty review: Benchmarks Game, batch 1 (2026-10-29)

nbody, spectralnorm, mandelbrot, fannkuchredux, each `{name}.rig` and `{name}-fast.rig`, read
beside the Rust each follows. `bin/rig` at main `1b2f4b59d`.

**How each change was probed.** The file was copied to a temp dir and changed there, then built
`--release=fast`. Its output had to be byte-identical to the Benchmarks Game `*_out` at the small
size (nbody 1000, spectralnorm 100, mandelbrot 200, fannkuch 7) and to the current port's output
at a medium size (5,000,000 / 3000 / 4000 / 10). It also had to run clean under
`RIG_SANITIZE=1 rig run` at the small size. Times are the fastest of 3 to 5 interleaved runs on a
Mac at load 9 to 12, so treat them as rough. No change made a file slower. Every changed file is
in `reviews/bg1-idiom-probes/{name}/`. Nothing under `compare/` was edited.

The ports are already good Rig: `?bodies[i + 1..]` for Rust's `bodies.clone()` walk, the
`[transposed: Bool]` flag where Rust monomorphizes a closure, `(rr + ii > 4.0).bits()`, the
`lookup` permutations, and `Tasks` with `>parts` are the right forms. The findings below are
small.

## Ranked

1. **nbody.rig: `bi`/`bj` in the pair loop, as in the Rust.** (probed)
2. **fannkuchredux-fast.rig: the 34 lines of mask tables become two compile-time functions.**
   (probed)
3. **All 8: header in house style** (what it is, then `# Ports …` with the authors). (probed)
4. **spectralnorm.rig: the copy loop becomes one `copy`.** (probed)
5. **fannkuchredux.rig: `Perm.new` inside the object, and `pp = @p`.** (probed)
6. **mandelbrot, both: `file.write("/dev/stdout", image)!`.** (probed)
7. **nbody, both: `math.PI`. nbody-fast: `N_PAIRS` computed from `N_BODIES`.** (probed)
8. Optional: **fannkuchredux-fast: drop `if head > 0`.** (probed)

## nbody.rig

**1. The pair loop names its two bodies, as the Rust does.** (probed: identical; 1.41 s against
1.48 s at 50M)
```
before:                                        after:
  for i in 0..5                                  for i in 0..5
    for j in i + 1..5                              bi = bodies[i]
      dx = bodies[i].x - bodies[j].x               for bj in !bodies[i + 1..]
      ...                                            dx = bi.x - bj.x
      massj_mag = bodies[j].mass * mag               ...
      bodies[i].vx -= dx * massj_mag                 massj_mag = bj.mass * mag
      ...                                            bi.vx -= dx * massj_mag
      bodies[j].vx += dx * massi_mag                 ...
    bodies[i].x += dt * bodies[i].vx                 bj.vx += dx * massi_mag
    ...                                            bi.x += dt * bi.vx
                                                   ...
                                                   bodies[i] = bi
```
Why: 22 `bodies[i]`/`bodies[j]` index expressions become `bi`/`bj`. The loop now reads line for
line like the Rust and like the port's own `energy` (`for bj in ?bodies[i + 1..]`). It shows
`for x in !slice`. Body `i` is plain data, so it is copied out and written back once.
(`bi = !bodies[i]` together with `!bodies[i + 1..]` is rejected as two write loans, correctly.)
It costs one line.

**2. `SOLAR_MASS = 4.0 * math.PI * math.PI`, with no local `PI`.** (probed: identical output)
Why: take std's word. `math.PI` is the same f64. It also applies to nbody-fast.

**3. Header, and drop "(A module constant holds no object yet.)".** (probed)
```
# The Computer Language Benchmarks Game: n-body, the Jovian planets around the Sun. A body is
# seven Floats, and each step visits each pair once.
# Ports benchmarksgame/sources/nbody/nbody.rust (TeXitoi).
```
Why: house style §3. "the plainest Rust" is a comparison with Rust, and notes.md already says it.
"yet" is not timeless, and the module-constant gap is already in notes.md.

## nbody-fast.rig

**4. `N_PAIRS` computed as the Rust computes it, and `[N_BODIES]Planet`.** (probed: identical
output; the emitted Zig differs only in constant names)
```
N_BODIES = 5
N_PAIRS = N_BODIES * (N_BODIES - 1) / 2
```
Why: `N_PAIRS = 10` is a magic number. The derivation says why it is 10, and `0..N_BODIES`
replaces the bare `5`s in `advance`.

**5. `math.PI`, as in (2), and the header.** (probed)

Tried and rejected: `for d, p in diff` renamed `for d, k in diff` collides with the counter `k`
(the rejection is "binding `k` shadows the local `k`", which is right), so `p` stays.

## spectralnorm.rig

**6. The chunk copy is one `copy`.** (probed: identical; 0.20 s for both at 5500)
```
before:                         after:
  for chunk in ?chunks            for chunk in ?chunks
    for x in chunk                  !out[k..k + chunk.len].copy(chunk)
      out[k] = x                    k += chunk.len
      k += 1
```
Why: it says "copy this chunk there" in one line instead of three. `copy(chunk)` checks
(`chunk[..]` alone is rejected with a hint to write `?chunk[..]`, but the bare binding is enough).

**7. `rows = List[Float](capacity: end - start)` in `mult`.** (probed, same time)
Why: the row count is known, and Rust writes into a slice of that length. It is small.

**8. Header.** (probed)
```
# The Computer Language Benchmarks Game: spectral-norm, the spectral norm of an n-by-n matrix
# by the power method. Each product is cut into four chunks, a task for each.
# Ports benchmarksgame/sources/spectralnorm/spectralnorm.rust-3 (TeXitoi, Tung Duong).
```

## spectralnorm-fast.rig

**9. Header** in the same form, naming rust-5 (Cristi Cobzarenco, Andre Bogus). (probed) I found
nothing else worth changing. The `div` and `sum` helpers and their "yet" comments belong to the
routed Simd gap.

## mandelbrot.rig and mandelbrot-fast.rig

**10. One call writes the image.** (probed in both: identical at 200 and 4000, piped and
redirected to a file, and the 16000 md5 `8c2ed888…` matches; same time)
```
before:                                  after:
  out = file.create("/dev/stdout")!        file.write("/dev/stdout", image)!
  (!out).write(image)!
```
Why: std's one-call form, as the idiom map's knucleotide uses. The handle was never used again.

**11. Headers.** (probed) The plain port says "the Mandelbrot set as a PBM bitmap…" and then
`# Ports …mandelbrot.rust (Matt Watson, TeXitoi).` The fast port moves its five authors to the
`# Ports` lines.

## fannkuchredux.rig

**12. `Perm.new(n)` as a method of `Perm`, first, where Rust's `impl` has it.** (probed)
```
obj Perm
  ...
  fun new(n: Int) -> Perm
    fact = [16 of 1]
    for i in 1..n + 1
      fact[i] = fact[i - 1] * i
    Perm(fact: fact, n: n)
```
`perm = Perm.new(n)` replaces the free `new_perm(n)`. Why: house style folds an `impl` into its
type, and a `fun new` is right when it computes something (it computes `fact`). std does the same
(`Random.new()`, `Terminal.new(…)`).

**13. `pp = @p` replaces `pp = [16 of 0]` and a two-line copy loop.** (probed)
```
before:                           after:
    pp = [16 of 0]                    ...
    ...                               pp = @p
      for j in 0..i + 1
        pp[j] = @p[j]
```
Why: `get` runs once a task, so copying all 16 elements costs nothing, and "pp is a copy of p"
reads at a glance. 2 lines fewer.

**14. Header.** (probed)

## fannkuchredux-fast.rig

**15. The masks are made by compile-time functions.** (probed: the emitted `REVERSE` and
`ROTATE` constants are byte-identical to the literal tables; output identical; 3.58 s against
3.84 s at n = 12 under load)
```rig fragment
# Masks for `lookup`, as arrays: a module constant holds a vector, not an array of them.
# `p.lookup(Perm(REVERSE[k]))` reverses the first `k + 1` lanes of `p`.
fun reverse_masks[n: Int] -> [n][n]U8
  masks = [n of [n of U8(0)]]
  for k in 0..n
    for i in 0..n
      masks[k][i] = U8(k - i if i <= k else i)
  masks

# `p.lookup(Perm(ROTATE[k]))` rotates the first `k + 1` lanes of `p` left by one.
fun rotate_masks[n: Int] -> [n][n]U8
  masks = [n of [n of U8(0)]]
  for k in 0..n
    for i in 0..n
      masks[k][i] = U8(i + 1 if i < k else 0 if i == k else i)
  masks

REVERSE = reverse_masks[16]
ROTATE = rotate_masks[16]
```
Why: 34 lines of numbers become 18 lines that say what each mask is. This is the natural home of
compile-time functions that the idiom map forecast (§3, "fannkuch masks"). The tables are still
literals in the Zig. The file goes from 114 lines to 95.

**16. Header.** (probed) It drops "(`tbl` on ARM, `pshufb` on x86, where the Rust needs x86
intrinsics)", a comparison with Rust that notes.md already makes.

**17. (Optional) Drop `if head > 0`.** (probed:
`bg1-idiom-probes/fannkuchredux/fannkuchredux-fast-nohead.rig`; identical; 3.69 s against
4.04 s at n = 12 under load)
When `head` is 0 the `while` does not run, `flips` stays 0, and both updates change nothing, so
the guard and one indent level can go. rust-6 keeps the guard, so this strays from the Rust's
shape, not its result. The speed reviewer should confirm the time on a quiet machine before
taking it.

## New findings

- **A compile-time-function constant is read through `rig.rt(…)`, where a literal one is not.**
  The constant is emitted the same, but the use is
  `rig.lookup(p, rig.rt(@as(@Vector(16, u8), rig.rt(ROTATE)[i])))` against
  `… ROTATE[i] …`. No time difference showed. It is worth a look by whoever owns `rt` in emit,
  since `rt` returns a 256-byte array by value. It is not a gap.
- No new language gaps. Integers have no `reverse_bits` (probed: "type `U8` has no method `reverse_bits`"); with one, mandelbrot.rig could keep
  Rust's lane order and reverse the byte. It is not needed, since loading the lanes reversed is
  as clear.
