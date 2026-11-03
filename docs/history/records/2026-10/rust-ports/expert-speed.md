# Speed expert: Rust hot paths and what Rig emits (2026-10-29)

Rig main at 1b2f4b59d, `bin/rig` freshly built. Apple M5, 10 cores, load 2.6 to 5.
Rust 1.98.1, `rustc -C opt-level=3 -C target-cpu=native`; Rig `rig build --release=fast`
unless noted. Times are the fastest of 3 runs of `/usr/bin/time`, run one after
another (A, B, A, B), not 20 interleaved rounds, so a gap under about 5% is noise.
Probes and binaries: `/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-rig-production-agent-6dff9f/3f64bb60-d18e-40a4-bf7b-73ae5aadde91/scratchpad/p/`.

## 1. What I measured

| Kernel (probe) | Rust | Rig | Result |
|---|---|---|---|
| mandelbrot `mbrot8`, 8000², 1 thread (`mandel.rig`) | `[f64; 8]` arrays, as in mandelbrot.rust: 0.66 s | `Simd[Float, 8]`, `(rr + ii > 4.0).bits()`: 0.53 s | Rig takes 20% less time |
| mandelbrot, full program, 16000², all cores (`mpar.rig`) | mandelbrot.rust, 20 threads: 0.46 to 0.49 s, 3.7 s CPU | `par.map` over rows: 0.46 to 0.52 s, 3.1 s CPU | same bytes (md5 equal), same time |
| binarytrees, 1 thread, 67M nodes (`bt.rig`, `bt_pool.rig`) | `Box<Node>` 1.27 s; `Vec` arena 0.17 s | `^Node` 0.57 s; `List[Node]` pool 0.17 s | `^Node` beats macOS malloc 2x; the pool equals Rust's arena |
| binarytrees 21, all cores (`btpar.rig`, `btbox.rig`, `btpool.rig`) | binarytrees.rust-5 (bumpalo + rayon): 0.24 to 0.29 s, 1.9 s CPU, 250 to 365 MB | `^Node` + a task a depth: 1.13 s, 7.0 s CPU; `^Node` + nested `par.map`: 1.14 s, 7.9 s CPU, 500 to 780 MB; pool + nested `par.map`: 0.23 to 0.24 s, 1.7 s CPU, 170 to 330 MB | same output; `^Node` 4.7x slower, pool matches |
| knucleotide count, k = 12 and 18 over 20M random bases (`kn.rig`) | std `HashMap`: 2.04 s, 1109 MB; with an Fx hasher: 1.24 s | `HashMap[U64, Int]` + `ensure(k, 0) += 1`: 1.03 s, 755 MB | Rig 17% less time than Fx, 32% less memory |
| pidigits 10000 (`pi.rig`) | pidigits.rust-2 (GMP by FFI): 0.48 s | `std.bigint`, a digit by estimate and fix: 2.36 s | Rig 4.9x slower; at 2000 digits 0.05 against 0.12 s |
| fasta, sections TWO and THREE, n = 25M (`fa.rig`) | fasta.rust-6: 1.78 s | 1.83 s | same bytes; within noise |
| spectralnorm 5500, 1 thread (`sn.rig`, `sn2.rig`) | scalar 0.63 s; two lanes `[f64; 2]` 0.33 s | scalar 0.63 s; two accumulators 0.35 s | parity; the gain is ILP, both scalar `fdiv` |
| nbody 50M (`nb.rig`) | nbody.rust 1.43 s; rust-2 0.90 s; rust-3 0.93 s; rust-5/7/9 are x86-only | 0.90 s | parity with the best portable Rust |
| reverse complement, 240 MB, no newlines (`rc.rig`) | scalar in-place table loop: 0.12 s | `s.read[B16]`, two `lookup`s, `!out.push(v, keep: 16)`: 0.07 s | Rig faster (Rust may auto-vectorize less here) |

Conclusion: for numeric and byte kernels Rig emits what a Zig programmer writes
and runs at Rust's speed or better. The losses are where Rig lacks a library
(bigints with in-place small-int ops, an arena, regex), not in emit.

## 2. The emit, kernel by kernel

- **Proofs work on the shapes ports use.** `for x, j in v` is Zig's `for (items, 0..)`;
  `for i in 0..out.len` then `v[j]` under `0..v.len` is `atProven(j, .both)`; the
  two-accumulator `while j + 1 < v.len : j += 2` gives `atProven` and `addProven`.
  `rig.rt` is an identity function, free in release.
- **Left behind (one compare each, outside the hottest loops):** `[5]Body` indexed by
  `0..5` loops is `rig.indexBelow(i, 5)` (LLVM folds it once it unrolls);
  `tab[i - 1]` under `for i in 1..tab.len` is an unproven `rig.at`; a countdown
  `while i >= 0 : i -= 1` proves only `.lower`; fannkuch's `rev[first]`, with `first` a
  lane value, keeps `indexBelow(first, 16)` where Rust writes `get_unchecked`.
- **`Simd`:** `Simd[Float, 8]` lowers to `@Vector(8, f64)`, compares to `rig.mask`,
  `.bits()` to `rig.maskBits`. `t.lookup(idx)` is `tbl` on ARM and `pshufb` on x86, so
  fannkuch's flip (`perm.lookup(REV[k])`) and revcomp's complement-and-reverse are
  portable, where fannkuchredux.rust-6 and revcomp.rust use x86 intrinsics.
  `bits()` puts lane 0 in bit 0; PBM wants it in bit 7, so build lanes right to left.
- **Allocation:** `^Node(...)` is `rig.Box(Node).init`, one allocation from the
  per-thread release heap; nothing hidden elsewhere. `String(a, b)` and
  `!s.add(...)` format in place.
- **Output:** `print` writes into one 8 KiB buffer, locking only once tasks run.
- **Trap for porters:** `key << 2` on a `U64` emits `@shlExact`: it panics in safe
  builds and is undefined in fast ones when bits fall off. Hash rolling and
  xorshift must write `<<%`.

## 3. The Rust version to port, per benchmark

"Fastest" is from the sources' crates and intrinsics, not from the Benchmarks Game
site (not checked); x86-only versions cannot be timed on the Mac.

| Benchmark | Port (fast) | Plain twin | Crates and intrinsics | Hot loop |
|---|---|---|---|---|
| binarytrees | rust-5 | rust (1) | bumpalo, rayon; rust-1 typed-arena (not cached) | alloc + recursive check |
| fannkuchredux | rust-6 (x86 `pshufb`; Rig's `lookup` is the portable twin); rust-5 to time on the Mac | rust-2 | rayon | prefix flips of a 16-byte permutation |
| fasta | rust-5 (num_cpus, threads), rust-7 x86 SSE | rust-6 | num_cpus, spin | LCG + cumulative lookup, 60-byte lines |
| knucleotide | rust-3 (hashbrown) | rust (1) | hashbrown; others fnv, fxhash, futures | rolling 2-bit key, map increment |
| mandelbrot | rust-6 (f64x2 + rayon) or rust-4 | rust (1, threads) | rayon | 8-lane escape loop |
| nbody | rust-2 (portable, fastest on the Mac); rust-7/9 x86 rsqrt on pup | rust (1) | none; rust-5/7/9 `std::arch::x86_64` | 10 pair interactions with sqrt |
| pidigits | rust-2 (GMP by FFI, no crate) | rust-2 | libgmp; rust-4 rug (not cached) | spigot: mul_ui, addmul, tdiv_q |
| regexredux | rust-6 (regex + rayon) | rust-2 | regex | 9 counts, 5 replacements |
| revcomp | rust-2 (rayon) | rust-3 | rayon; rust-1 memchr + SSSE3 | complement table + reverse |
| spectralnorm | rust (1) or -2 (own f64x2 + threads) | rust-3 | none; rust-6 x86 | `x / a(i, j)` sums |

## 4. Tasks in place of threads

`par.map(?xs, |?v, x| ...)` with a captured read view, and tasks given
`?seq` (`count(?seq, k)&`, then `>t`), both checked and ran.
A List of tasks is waited with `for t in <tasks` and `>t` (not `for t in !tasks`).

| Benchmark | Split |
|---|---|
| binarytrees | `par.map` over depths, nested `par.map` over chunks of the iterations, each chunk with its own pool reset by `!pool.keep(0)` (measured: matches rust-5) |
| fannkuchredux | `par.map` over the n (or n(n-1)) starting rotations; sum the checksums, max the flips |
| fasta | LCG stays serial; Rust-5's split (draw a block, convert in parallel) via `par.map` over blocks; low value |
| knucleotide | one task per frame size k, each `count(?seq, k)&` |
| mandelbrot | `par.map` over rows (measured) |
| nbody, pidigits | serial |
| regexredux | one task per pattern |
| revcomp | one task per sequence, or per chunk of one |
| spectralnorm | `par.map` over row indexes with `?v` captured, 40 times |

## 5. Gaps, ranked by the speed they cost

1. **Arena for `^` trees** (binarytrees: idiomatic `^Node` 4.7x slower than rust-5).
   The `List[Node]` pool with `I32` indexes matches Rust, but it is not the
   `^Node` form the Idiom expert will want, and the Benchmarks Game counts only a
   library arena. Also: `^Node` under tasks costs 13 ns a node against 8.5 ns on one
   thread, and RSS grew to 780 MB, which looks like frees landing on other threads'
   heaps: worth a look at `src/alloc.zig`. No Zig ceiling needed: the pool probe
   already is one.
2. **`std.bigint` with in-place and small-int ops** (pidigits: 4.9x slower than GMP).
   No division (`tdiv_q`), no `mul_int`/`add_mul_int`, and every op allocates. A Zig
   ceiling (`std.math.big.int.Managed`) would show how much is allocation and how
   much is limb code.
3. **No regex** (regexredux cannot be ported as written). A std.regex is a new
   module outside the ROADMAP: the owner's call. Options: skip regexredux, or write
   the 9 patterns as hand matchers (not the benchmark's rules).
4. **Float vectors stop at `+ - *`.** No `/`, `sqrt`, `rsqrt`, lane sum, FMA, int-to-float
   lane conversion, or float shuffle. spectralnorm's f64x2 division and nbody's
   SIMD versions cannot be written; with Zig 0.17's loop vectorizer off
   (docs/internals/zig-0.17.md §16) no plain loop becomes vector either. Measured
   cost today is small on the Mac (scalar Rig matched the best portable Rust), larger
   on pup against rust-7/9's `rsqrt`. Each op is a small `@Vector` builtin.
5. **Bytes in and out.** No stdin or raw-stdout API: `file.read("/dev/stdin")` and
   `file.create("/dev/stdout")` work (verified on macOS, to a pipe and a file; Linux
   unverified). `print` always adds a newline, so PBM output needs the file route.
   A `String` cannot be written in place (`!s.write[...]` and `!s[..]` are refused),
   and nothing moves bytes between `String` and `List[U8]` in bulk ("write the bytes
   one by one", 1.6 ns a byte). Streaming into a new String with
   `push(v, keep: 16)` avoids it for revcomp.
6. **Fixed-decimal float formatting** (`{:.9}`, `{:.3}`): none; nbody, spectralnorm,
   knucleotide must hand-write it. Correctness, not speed.
7. **No operator methods**: Vec3 math is `a.plus(b).times(k)`, inlined and free;
   `type Vec3 = Simd[Float, 4]` gives `+ - *` but no dot without a lane sum.

Not gaps: wrapping (`+% *% <<%`), `U32`/`I32`/`U64` widths, `math.sqrt` (`@sqrt`),
`std.random` (splitmix64, `fork` per task), `HashMap` speed, buffered `print`.

## 6. Ray tracer and mini-redis

- **Ray tracer:** the hot path is sphere intersection over the world (a
  discriminant and a sqrt a sphere a ray) and material scatter. Rig has no `dyn`, so
  hittables and materials become enums matched in place: static dispatch, likely
  faster than Rust's `Box<dyn>`/`Arc<dyn>` vtables. Vec3 as an object with inlined
  methods costs nothing; rows split with `par.map`, a `random.Random` forked per
  row. Expect parity.
- **mini-redis:** the hot path is frame parsing plus a socket read and write a
  command. Rig's loopback round trips equal Tokio's (docs/launch/benchmarks.md);
  the `Map` behind `Arc<Mutex>` becomes an actor holding the `Map`, 5 ns a call solo
  and 31 ns contended on the M5 against Tokio's 135 and 269 ns actors. Copies where
  Rust shares `Bytes` slices are the likely cost; small next to the system calls.

## 7. How to measure

- Rust: `rustc -C opt-level=3 -C target-cpu=native` for crate-free files; for crates a
  cargo project, `--offline`, `RUSTFLAGS="-C target-cpu=native"`, release with
  `lto = true, codegen-units = 1, panic = "abort"`. Cached: bumpalo, rayon, regex,
  hashbrown, fnv, indexmap, memchr, num_cpus, crossbeam-utils, futures, itertools,
  generic-array, num-traits, libc, tokio, bytes, tracing. Not cached: typed-arena,
  toolshed, rug, numeric-array, futures-cpupool, fxhash, scoped_threadpool,
  tokio-threadpool. libgmp is in /opt/homebrew/lib (`-L /opt/homebrew/lib -l gmp`).
- Rig: `bin/rig build --release=fast -o X prog.rig` (as `bench/` does), and
  `--release` as a second row; it compiles in full each time.
- Sizes (the Benchmarks Game's): binarytrees 21, fannkuchredux 12, fasta 25000000,
  knucleotide and revcomp on fasta 25000000's output, mandelbrot 16000, nbody 50000000,
  pidigits 10000, regexredux on fasta 5000000's output, spectralnorm 5500. On the M5
  with all cores these run 0.2 to 2.5 s.
- `hyperfine` is not installed (`brew install hyperfine`); else a shell loop: same
  output checked by `cmp`/md5 first, then 20 interleaved rounds, fastest of each,
  CPU time with `/usr/bin/time -l`, and the load checked (`uptime`) before.
- arm64 on the Mac, x86 on pup (which also builds rust-5/7/9 and fannkuch rust-6).

## 8. Decisions (with defaults)

1. binarytrees: port the `List[Node]` pool as the fast version and `^Node` as the
   plain one, and record the 4.7x as an arena gap. Default: yes.
2. pidigits: port on `std.bigint`, adding in-place small-int ops and a quotient to
   std as its own PR from a failing case. Default: yes, after a Zig ceiling.
3. regexredux: skip until the owner decides on a std.regex. Default: skip.
4. Float `Simd`: propose `/`, `sqrt`, lane `sum`, and int-to-float conversion as one
   SIMD round. Default: propose after the ports, with spectralnorm and nbody as the
   cases.
5. stdin/stdout: ports use `/dev/stdin` and `/dev/stdout`; propose `os.stdin()`/
   `os.stdout()` or a bulk `String`/`List[U8]` move later. Default: use the paths now.
6. Look at `src/alloc.zig` for cross-thread frees under `^Node` with tasks. Default:
   a short probe by the allocator's owner, not a port blocker.
