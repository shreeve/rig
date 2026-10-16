# To do

Work that is decided but not started. Where Rig stands, and the work in
progress, is in [HANDOFF.md](HANDOFF.md).

## After v0.3.0's in-flight work

The in-flight list is in HANDOFF.md, "What comes next". Decided, not
started:

- SIMD: `pad:` reads and `blocks(N)`.
- A String API for part-word appends and windowed writes.
- Several results, after v1 (SPEC "Several results"):
  - small results in registers: pack results of up to two words of
    integers, `Bool`s, and pointers into a `u128`, which Zig's default
    calling convention returns in registers where it returns a tuple
    or an object through memory; it serves objects too, and lands only
    if it passes the speed rule;
  - `from` per result, so a write view and a read view may come from
    different parameters whose types could both hold either, and
    several write views a function proves disjoint (sentence 5);
  - a `catch` or `??` fallback that gives every result (`catch 0, 0`);
  - `for k, v in it` over an iterator whose `next` gives several
    results, decided with iterators as values;
  - `ResultBound` per result, so a proven bound on a result reaches the
    name that takes it (`src/proofs.zig`).
- Inlining a generic type's small methods. Rig never emits a generic
  type's methods `inline` (`src/inlining.zig`), and LLVM leaves
  `std.hash`'s `Map.ensure` and `Map.ensure_with` out of line, so on a
  key already there they lose to `edit` then `put`, which inlines: on
  Int keys, 1M operations, `ensure` 39% slower and `ensure_with` 31%
  slower; on new keys `ensure` is 6% faster and `ensure_with` 0.2%
  slower (Mac, off-window, best of 7).
- Every copy out of a view in a generic body takes the per-instance
  `copies` requirement, as `Cell.get` and a `??` through a view of an
  optional do: today a view read where its `T` is expected (`p` in
  `fun copy[T](p: ?T) -> T`, `v` of `if m.get(k) as v`) and
  `m.get(k) ?? d` are rejected outright, as `T` may not copy in every
  instance.
- A generic body's own holding of a `T` (`h = *<x`, `List[*T]`, a call
  passing `<x` to `*T`) at an instance whose `T` is held (`T = ~U`
  makes `*~U`): rejected per instance, with the generic per-instance
  requirements round (option (b)). SPEC "Box" shows it as pending.
- Destination-passing for values over about 64 KiB: emit passes,
  returns, and copies none by value through a Zig temporary, and lowers
  a `defer` or inlined body that declares one to a single call. A
  frame's real size is then bounded by construction; today it is a
  measured bound, `sema.reach_factor` (4) times its reach, which
  `test/cli/frame_reach.sh` checks, and a form Zig copies that reach
  does not model could exceed it. Two did in #230's review, both fixed:
  a payload part a `match <e` arm drops, passed by value at each exit
  (`test/corpus/rev230-discard-exits.rig`); and the same at 12,000
  exits, whose 48 GB frame made Zig's aarch64 build fail with `fixup
  value out of range` (`test/cli/discard_build.sh`; a frame over 4 GiB
  draws Zig's warning, and one that large fails to build).
  With it, build debug programs for x86_64 with `-fllvm`, as aarch64's
  are.
- The reference checker (`bin/rig-oracle`) takes memory quadratic in
  the exits of one `match` arm. For an arm `.one(_, n)` of `match <e`
  with that many `return ... if ...` lines, its peak resident memory:

  | Exits | Peak memory |
  |---|---|
  | 50 | 6.7 MB |
  | 100 | 10 MB |
  | 200 | 24 MB |
  | 400 | 74 MB |
  | 12,000 | 52 GiB (`--set corpus`, measured on Linux) |

  At 12,000 exits it took down a 7 GB CI runner, so that program is a
  CLI test (`test/cli/discard_build.sh`), which the checker never sees,
  rather than a corpus probe. Make it linear, then the program can
  return to the corpus.
- Switching to Nexus's `Span.text`.
- `text.ByteSet`, a byte set built once when the program runs and
  searched with `set.find(s, at)`: the run-time sibling of
  `text.find_any[set]`. Built when a port needs a set known only at run
  time; none does yet.
- Big integers in the standard library, to replace Trig's own: arbitrary
  precision, enough for JavaScript number and BigInt work (Trig's jsnum
  uses them in 3 places). Trig's version passes all 32,076 of its test
  cases; the std one must pass the same cases and be as fast before Trig
  swaps.
- `std.hash` with 4-byte stored hashes (an entry's hash takes 8 bytes
  today): the tag from the stored bits up to 2^25 slots, and from the
  top of the whole hash, recomputed from the keys, past that. It
  matched the 8-byte version's speed; it saves 4 bytes an entry.
- A built-in generic named through a module agrees on both sides: as
  an expression, `lib.List[Int].filled(2, 3)` reaches the local `List`,
  while as a type, `lib.List[String]` is reported as "`lib.List` is not
  public".
- Generic inference looks through a box as a method call does: with
  `bx: ^List[P]`, `first(?bx)` (`first[T](xs: ?List[T])`) is a type
  mismatch, though `first[P](?bx)` is accepted.
- An unwrap of an optional that traps when it is `none`. `std.hash`'s
  `Map.ensure` reaches its value, which is never `none` there, with a
  `while true` whose only exit is a `return`; the unwrap would replace it.
- A deep clone of a type parameter's value in a generic body (`+k` of a
  `?K` where `K` owns text). With it, `Map.ensure`, `Map.put_new`, and
  `Set.add` take a `?K` and copy the key only when it is stored (owner
  approved); today they take an owned `K`.

## Agent tooling

- `rig check --json`, with machine-applicable fixes. Many diagnostics
  already name the fix, such as "write `rd(?n)`"; the JSON gives each
  fix as an edit to apply.
- A formatter that writes the canonical style.
- Later, `rig explain` and a language server.
