# Benchmarks Game, second four (fasta, revcomp, knucleotide, binarytrees): speed review

Rig main `1b2f4b59d`, Apple M5, Rust 1.98.1. **Every timing here is rough.** The Mac was
shared throughout: `uptime` load 4 to 14 during the runs (each table gives its own). Times are
the fastest of 5 to 11 interleaved rounds (`bg2-speed-probes/bench.py`: fork, `wait4`, stdout to
`/dev/null`), on fasta 25,000,000's output (243 MB, md5 `fd55b9e8…`). Every variant was checked
to print the same bytes as the original before it was timed. Variants of Rig's runtime were
built from `rig build --release=fast`'s emitted package with `zig build-exe -Ofast
-fomit-frame-pointer`, as rig builds it. Probes, patches, and timings:
[hash-race/small-table-data/](../../hash-race/small-table-data/), where
`bg2-speed-probes/` below is kept. The Zig ceiling: `~/Data/Code/rig/compare/zig/revcomp/ceiling.zig`.

Already routed, not reported again as new: S1 (HashMap dense-key hashing), S2 (file.write in
programs with tasks; refined in finding 2), String not writable in place, no arena.

## Findings, ranked by the time they win

### 1. A push loop keeps the String's length in memory (runtime; new)

`String.push`, `reserve`, and `pushKeep` call `self.grow(n)`, a `noinline` function that takes
the String's address. So the String local escapes, and LLVM keeps `len` and `capacity` on the
stack: every byte pushed loads `len`, stores the byte, and stores `len + 1` back. That is a
store-to-load chain through memory on every iteration (revcomp plain's loop:
`ldp x8, x9, [sp, #0x30]` … `str x8, [sp, #0x30]` per byte).

The fix is to grow by value: `l = growBy(l, n)`, with `noinline fn growBy(ArrayList(u8), usize)
ArrayList(u8)`. Then `&out` never escapes, and the fields stay in registers (x23 to x25 in the
patched loop). The patch is `bg2-speed-probes/byval.py`, about 15 lines.

| | before | grow by value |
|---|---:|---:|
| revcomp plain (task per sequence), load 7 | 307 ms, 0.56 s CPU | 176 ms, 0.30 s CPU (43% less time) |
| revcomp plain, cut into blocks (finding 3) | 128 ms, 0.61 s CPU | 95 ms, 0.37 s CPU |
| revcomp fast | 68.6 ms, 0.15 s CPU | 65.8 ms, 0.12 s CPU |
| fasta, fasta-fast, knucleotide-fast | | within noise |

**`List.push` has the same shape.** A `List[U8]` fill loop does `ldr x9, [sp, #16]; add; str
x19, [sp, #16]` per element (0.62 ns a push). Fix the class: `List.grow` and the other String
appends should take and return their buffer by value, so no owner's address passes to an
out-of-line call. This belongs to `src/runtime.zig`, and needs the suite and the json and hash
guards. HashMap's table header is reloaded from the stack on each count too (finding 5); that
may be the same cause, but it is not measured.

### 2. `File.write` in a program with tasks copies its bytes (runtime; refines S2)

`net.fileWrite` runs on the blocking pool through `rig.blockingStop`, and `sched.poolCall`'s
`ownArgs` dupes every `[]const u8` argument so that a canceled waiter can go on. revcomp writes
243 MB, so it is copied a third time. The write-size probe (`wsize.rig`, 1000 writes to
`/dev/null` in a program with one task) shows the cost:

| bytes a write | 1 | 4 KB | 64 KB | 250 KB | 1 MB |
|---|---:|---:|---:|---:|---:|
| as built | 10 µs | 10 µs | 21 µs | 36 µs | 100 µs |
| no copy | 11 µs | 11 µs | 11 µs | 11 µs | 11 µs |

**So S2 is two costs:** a pool round trip of about 10 µs, and a copy of about 90 µs a MB.
S2's "20 µs a write" was measured at 250 KB, where the copy is most of it. In revcomp-fast the
write phase takes 17 ms, and 3.6 ms without the copy. The whole program goes from 68.6 to
52.3 ms (24% less time).

Fix, in `src/sched.zig` and `src/net.zig`. Choices for the owner:
- (a) A write of an owned String hands the buffer to the pool call, which frees it. The sigil
  already says so: `(!f).write(<part)`. A `?String` still copies.
- (b) No copy when the waiter cannot stop: the fiber has no deadline and cannot be canceled.
- (c) No copy for a regular file or `/dev/null`, whose write cannot block for long, so a
  canceled waiter can wait for it.

(a) is the one that fits Rig's ownership rules.

### 3. revcomp plain is not split the way rust-3 is (port; fairness)

rust-3 forks each sequence in halves with `rayon::join` down to 16 KB, on every core, in place.
The Rig plain port runs a task per sequence, so its time is the longest sequence (125M bases)
on one core. The notes say halving "has no plain Rig form" because joining halves copies, but
it needs no joining. The fast port's `blocks` list of line ranges under `par.map`, with the
plain byte loop through the `[256]U8` table, is still plain Rig (`rc-plain-blocks.rig`):

| load 7 | Rust (rust-3) | Rig plain | Rig blocks | Rig blocks, findings 1 and 2 |
|---|---:|---:|---:|---:|
| revcomp plain | 62.5 ms | 306.9 ms | 127.6 ms | 77.6 ms |

Recommend the blocks version as the plain port. The gap left (78 against 63 ms) is the second
copy (finding 4) and a `k / LINE` division per byte, which a loop over each line's two runs
removes.

### 4. The second copy: what an in-place String write would win (std)

Zig ceiling (`compare/zig/revcomp/ceiling.zig`): reverse and complement 243 MB, 16 bytes at a
time with two `tbl`s, then one write. The read is the same in every mode (19 to 22 ms).

| Mode | 10 threads | 1 thread |
|---|---:|---:|
| in place (the Rust ports) | 3.9 ms | 7.7 ms |
| into a second, fresh buffer (the Rig ports) | 9.4 ms | 20.5 ms |
| second buffer, pages touched first | 5.3 ms, plus 8.3 ms to touch the pages | |

The second copy costs about 5.5 ms on 10 threads, mostly page faults. Add about 3 of revcomp
fast's 6 ms of frees, and 243 MB of RSS (Rig 498 MB against Rust's 125 MB).

**The gap, decomposed.** revcomp fast is 68.6 ms against Rust's 41.7 ms (load 6):
- the write's copy (finding 2): 16 ms;
- grow by value (finding 1): about 4 ms;
- left, at 48.4 ms: the second copy (about 8 ms), and 256 pool round trips (3.6 ms, S2's
  per-call part), less Rig's faster single read (21 against 25 ms).

**The smallest std addition is `!s.write[T](at, v)` on a String.** `List[U8]` already has it;
it is the mirror of the `s.read[Bytes](at)` the port uses. It lets the port swap from both ends
in place, as rust does. Rig already emits that kernel at the ceiling's speed: `inplace.rig` on a
243 MB `List[U8]` runs in 6.7 ms on one thread, against the ceiling's 7.7. A serial in-place
port then projects to about 21 + 8 ms plus one write, under Rust's 37 ms (rust runs in
parallel). Running it in parallel in place also needs disjoint write slices lent to tasks
(spectralnorm's gap).

If a String must not be written in place, the alternative is a zero-copy move each way between
`String` and `List[U8]` (two functions; names are the owner's call). No Zig ceiling was needed
for the kernel: the emit is already there.

### 5. knucleotide-fast: main's two short counts are the critical path (std; S1 family)

Timed inside both programs (load 8 to 14):

| | read and encode | k = 1 | k = 2 | the five tasks |
|---|---:|---:|---:|---|
| Rig | 22 + 100 ms | 290 ms | 255 ms | done before main |
| Rust (rust-3) | 120 ms | 256 ms | 190 ms | done before main |

Single-threaded (`kn12.rig`, `rust-kn12.rs`, fastest of 8, load 8.5):

| | k = 1 | k = 2 | k = 4 |
|---|---:|---:|---:|
| Rig | 196 ms | 223 ms | 213 ms |
| Rust | 184 ms | 178 ms | 180 ms |

Rig takes 7%, 25%, and 18% more time per count on a 4- to 256-key table. That is all of the
16% gap.

The loop is about 35 instructions a count, against about 25 for hashbrown's. The extras are:
- the table's groups pointer and shift reloaded from the stack on every count;
- a tag-class table load;
- the `mix` (the S1 workaround);
- a `rig.turn` tick.

Dropping HashMap.ensure's `self.len = self.t.count()` store changed nothing (measured). The fix
is std's, in the S1 investigation (`src/unordered.zig` and std/prelude.rig's `HashMap`), and
may share finding 1's cause. No fair port fix: the rules need a hash table, and rust-3 counts
k = 1 and k = 2 on the main thread too.

## Fairness

- **fasta:** same algorithm and same bytes. Plain Rust is built with `rustc -C opt-level=3`
  (16 codegen units, unwinding), while the cargo builds use `codegen-units = 1`,
  `panic = "abort"`, and LTO. With `-C codegen-units=1 -C panic=abort`, plain Rust took
  2.28 s against 2.38 s (load 12, about 4%). Rig plain took 2.21 s and fast 0.82 s, against
  Rust fast's 1.02 s. Build `fasta.rs` and `knucleotide.rs` with the same care.
- **revcomp:** same output. The plain split differs (finding 3). The fast Rust runs its scalar
  fallback on arm64 (SSSE3 only), in place; Rig's is vector code: fine, and noted.
- **knucleotide plain:** the Rust copies a `Vec<u8>` key at every position (`.to_vec()`
  before `entry`) and hashes it with SipHash. mimalloc alone takes it from 6.27 to 3.74 s, and
  an LTO build takes it to 5.74 s. So Rig's 4.7x is mostly the key copy and the hasher, not the
  counting. That is fair as each language's plain idiom (Rig's view keys are the point), but
  the notes should say why.
- **knucleotide fast:** same algorithm. Rig holds the whole input while it encodes
  (384 MB against Rust's 137 MB).
- **binarytrees plain:** the Rust uses typed-arena, and Rig boxes each node. That is not the
  same allocation work; it is the routed no-arena gap.
- **binarytrees fast:** same work. The List pool matches bumpalo.

## Rust rows: typed-arena and mimalloc (load 7 to 14)

| | Rust, system malloc | Rust, mimalloc | Rig `--release=fast` |
|---|---:|---:|---:|
| binarytrees 21 plain (typed-arena) | 0.46 s, 3.1 s CPU, 203 MB | 0.41 s, 2.8 s CPU, 261 MB | 1.21 s, 7.1 s CPU, 346 MB |
| binarytrees 21 fast (rust-5) | 0.28 s, 2.1 s CPU, 390 MB | 0.23 s, 1.8 s CPU, 528 MB | 0.23 s, 1.8 s CPU, 342 MB |
| knucleotide plain | 6.27 s (5.74 LTO), 33 s CPU | 3.74 s, 18 s CPU | 1.28 s, 5.7 s CPU, 510 MB |
| knucleotide fast | 0.56 s, 2.0 s CPU, 141 MB | 0.59 s, 2.0 s CPU | 0.67 s, 2.4 s CPU, 384 MB |

The plain binarytrees in Rig takes 2.6x the time of the arena Rust. The fast port ties rust-5
with mimalloc. mimalloc does not help knucleotide fast, which allocates little.

**Added to `compare/rig/` (rust only):** for `binarytrees/rust/` and `knucleotide/rust/`, each
got a `plain-mi/` and a `fast-mi/` cargo project, whose `main.rs` sets
`#[global_allocator] static M: mimalloc::MiMalloc` and `include!`s the original source
unchanged. Each also got `build-mi.sh`, which builds `*-mi` and `*-fast-mi` offline. typed-arena
is now in cargo's cache, so `build.sh plain` works offline too. All four binaries print the
reference bytes.

## Decisions (defaults)

1. Runtime: grow by value in String's appends and in `List.push`/`reserve` (finding 1).
   Default: yes, as its own PR with the suite and the json and hash guards.
2. File write without a copy: (a) `write(<s)` hands over an owned String. Default: (a); the
   owner names it.
3. revcomp plain: replace the task-per-sequence port with the blocks version. Default: yes.
4. `!s.write[T](at, v)` on String. Default: propose it, with revcomp as the case.
5. Build `fasta.rs` and `knucleotide.rs` with `-C codegen-units=1 -C panic=abort`.
   Default: yes.
