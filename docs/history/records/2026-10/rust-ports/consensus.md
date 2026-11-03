# The Rig reference library: the panel's consensus (2026-10-29)

Three experts, all probing `bin/rig` at main `1b2f4b59d`:
[expert-idiom.md](expert-idiom.md) (the full idiom map, the gaps with
their probes, the sigil forecast), [expert-speed.md](expert-speed.md)
(the hot loops, emit, and early timings), and
[expert-reader.md](expert-reader.md) (house style, measures, write-ups).
Probes are in `idiom-probes/` and `reader-probes/`; `sloc.py` counts lines.

## What the panel agrees on
- **Rig is already as fast as Rust on number and byte loops** (early
  M5 timings, fastest of 3, not yet interleaved):
  - mandelbrot 0.46 s against 0.46 s;
  - nbody 0.90 s against 0.90 s;
  - spectralnorm 0.35 s against 0.33 s;
  - fasta 1.83 s against 1.78 s;
  - knucleotide 1.03 s against 1.24 s, with 32% less memory.

  Bounds checks are proven away in these shapes, and `Simd` lowers to
  `@Vector`. Where Rig is slower, a library is missing, not the emit:
  - binarytrees with `^Node` is 4.7x slower than Rust with bumpalo, and
    a `List` pool matches it;
  - pidigits is 4.9x slower than GMP;
  - regex is absent.
- **The noisiest Rust disappears, not just shrinks.** Lifetimes,
  `as_ref().map(|n| &**n)`, `Rc::clone`, `.lock().unwrap()`, `Drop`
  impls for lists, and mini-redis's whole `shutdown.rs` all go:
  - Ctrl-C cancels `main`;
  - dropping the `Tasks` set cancels and waits for every connection.

  second.rs is 86 lines and 618 tokens in Rust, and its Rig probe is 40
  lines and 325 tokens.
- **The ownership map** (idiom §1):
  - `Option<Box<T>>` becomes `^T?`, and `take()` becomes `<@head`;
  - `Rc` becomes `*T`, and `Rc<RefCell>` becomes `*T` with `Cell` fields;
  - `Weak` becomes `~h` and `*w`;
  - `Arc` becomes `*Frozen[T]`, and `Arc<Mutex>` becomes `*Actor[T]`;
  - `Box<dyn A>` becomes `^{A}`;
  - `HitRecord<'a>` becomes `-> Hit? from @`;
  - knucleotide's `HashMap` becomes `Map[?String, Int]`, with keys that
    are zero-copy views into the input.

## Port plan
Ports go to `~/Data/Code/rig/compare/rig/`, in this order:

| Folder | Port |
|---|---|
| `too-many-lists/` | first to fifth and silly1/2, one file each, with each Rust test as a `test` block under its own name. fifth is a safe queue of `*Node` with `Cell` links (Rig has no raw pointers). `IterMut` is a recursive `each_mut`. silly2 is non-generic until B1 is fixed. |
| `benchmarksgame/` | for each benchmark, `name.rig` (the plainest Rust) and `name-fast.rig` (the fastest Rust the speed report picked), with one README for all ten. pidigits waits on `std.bigint`, and regexredux on a regex decision. |
| `ray-tracing/` | written from Shirley's book. `type Vec3 = Simd[Float, 4]`, materials as an enum held by value, `par.map` over rows. The README shows Rig only. |
| `mini-redis/` | `*Actor[Db]`, a task per connection in `Tasks`, Ctrl-C shutdown. Subscribe polls until a stream can be split. |

Each folder gets a README with:
- the numbers table: code lines and tokens without tests, a column with
  them, `--release` time on the Mac and pup with `--release=fast` as a
  second row, memory, and whether the output is identical;
- the hardest part side by side, from line ranges, through `excerpts.py`;
- the rows it adds to `ledger.md`, the sigil ledger.

## Gaps found (each with a probe in the reports)
| # | Gap | Cost | Route |
|---|---|---|---|
| B1 | generic `(?Frame[T])?` field: accepted, then Zig fails | breaks "accept means correct" | **Rig - Merges (fork) took it**, after errors-only |
| G2 | a write cursor can't advance in a loop (`cur = !node.next`); no `IterMut` | `IterMut` is recursive, so it overflows the stack at 1M nodes | CORE question for the owner |
| G13 | no fixed-decimal float printing (`{:.9}`) | nbody, spectralnorm and knucleotide can't print their output | std, small |
| G11 | `std.bigint` has no division or in-place small-integer operations, and every operation allocates | pidigits 4.9x slower | std PR, after a Zig ceiling |
| G12 | no regex | regexredux can't be ported | owner: `std.regex` or skip |
| arena | no arena or bump allocator; `^Node` under tasks reached 780 MB | binarytrees 4.7x slower in its plain form | `src/alloc.zig` look; `List` pool for now |
| G14 | float `Simd` has no `/`, `sqrt`, lane `sum` or int-to-float | small on the Mac, more on pup | one std round after the ports |
| G4 | no `Rc::try_unwrap`, and a value inside a `Cell` can't be viewed | the deque can peek or pop, not both | note for CORE |
| G6–G10 | no select on a socket or split stream, no broadcast or `try_send`, no semaphore, no ordered map or heap, `par.each` gives no index | mini-redis papercuts | backlog |
| diag | two suggestions are wrong: one repeats the input (`<s.drain()`), one doesn't compile (`?(?@head)?.elem`) | | small diagnostics PR |

## Sigil forecast (idiom §5)
These forms have a natural home:
- every lending and moving sigil;
- `^T?`, `*T`, `*Frozen`, `*Actor`, `Cell`, `~x`, and `*w`;
- `from` (the ray tracer's `Hit`);
- `^{A + Syncs}`;
- `once ?fun` (silly2's callback);
- `Simd` with `lookup` and `bits` (fannkuch, revcomp, mandelbrot);
- `f(x)&`, `Tasks`, `Chan`, `T!E`, `T?!`;
- compile-time tables (revcomp's `COMP`).

These have none expected in the four projects:
- `keeps`, symbols, `*{A}`, `~{A}`, `!{A}`;
- `|~x|` captures, `*fun`, `Signal`, `raw`, `unique` on user objects.

`Table`/`Slot` has only a weak home (knucleotide). The library's ledger
will confirm or refute each.
