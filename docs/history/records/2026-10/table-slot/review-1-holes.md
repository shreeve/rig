# Table/Slot: holes for the builder (adversarial review of A-typed-ids.md, option B)

Probes are in `review-table/p/`. Ranked by severity. Each is a way that
`t[s]` without a test could reach memory outside the table, or read an
invalid value.

## H1 (high). When is the reservation made? Zig field defaults are comptime

The design's own example, `types: Table[Type, TYPES] = Table()`, is an
object field default. Rig lowers field defaults to Zig struct defaults,
which Zig evaluates at comptime (`p/d2.rig`, emitted:
`a: rig.List(i64) = rig.List(i64).empty`, `s: S = S{}`). An mmap cannot
run there. That leaves two ways out:

- **Lazy mapping** (`slots` null or dangling until the first push). Then
  `t[s]` on a table that was never pushed (indexed by another table's
  Slot) reads or writes `base + s*size` with no mapping. For a large `s`,
  that can land in mapped memory. This is exactly the test the design
  removes. It also collides with the optional niche: `nicheOf` uses a
  non-null pointer field as `Table?`'s none, so a null "unmapped" Table
  inside an optional reads as `none`.
- **Run-time construction at every site that makes a default.** That
  covers `T()`, `S()`, a nested default (`W.s: S = S{}`), `Opt` packing,
  and generic `T()`. It is an emit change across all of these.

Either the design names the second way, or every lazy access tests for
the mapping.

## H2 (high). "Default is all zero bytes" must come from the real lowering

An optional of an object uses a niche (`runtime.zig` `Opt`/`nicheOf`),
and its none is not zero.

- **Verified** (`p/zz/t.zig`, against the emitted runtime): `P` holds an
  enum `K` whose values are `a = 1, b = 2` (Trig's `TypeKind` starts at
  `Intrinsic = 1`). A field `p: P? = none` is stored as the niche value
  3. Zero bytes decode as `some(P{k: tag 0})`, an invalid enum value. A
  `match` on that value is undefined behavior in ReleaseFast (a jump
  table indexed out of range).
- **Also unsafe as lazy tables:**
  - an enum default whose value is not 0;
  - a named none other than 0 (`none id == 5`);
  - a float default of `-0.0` (bits are not zero, though it compares
    equal to 0.0);
  - a plain Zig `?T` field (its layout is unspecified).
- **Rule:** decide zero-ness structurally and conservatively. Allow ints,
  floats whose default is `+0.0`, `Bool`, `Slot`, enums whose default
  variant has the value 0, and arrays and objects of these. Never allow
  an optional or a payload enum.

## H3 (high). Slot needs its own type kind, and the literal check must learn it

- **If Slot is an `.int` with a bound:** every int path mints an
  unchecked Slot.
  - An alias conversion, `TypeId(x)`, and `TypeId.max`
    (`typecheck.numberType`, through `sema.isNumeric`).
  - The result or parameter of a compile-time function, and a
    compile-time value parameter (`f[9]` checked only against the Zig
    width).
  - `bytes.read[T, e]` with `T` a type parameter, `Simd[T, n]`, and
    `T.wrap`.
  - Arithmetic, `+%=`, and `Slot(enum)`.
  - The extern boundary, and named-none fields.
- **If Slot is its own kind:** `checkLiteralFits` (`typecheck.zig:15161`)
  returns early for anything that is not `.int` or `.float`. If int
  literals become assignable to Slot, `s: Slot[8] = 200` is accepted and
  emits a `u8` 200. Zig catches only values above 255. Extend that
  function, including its `.not_constant` branch
  (`s: Slot[8] = 200 if c else r`).
- **Test:** every coercion site in `p/lit.rig` (default, `??`, `if`,
  `match`, payload, array, fill, List), with a Slot in place of the U8.

## H4 (medium). Instance ranges for `n`

- Generic types accept `n = 0`, `-1`, and `cnt[3] = -7` (`p/g5.rig`,
  `p/ct3.rig`), unless the body uses `n` as an array length (`p/g6.rig`
  shows that per-instance check).
- `Slot`/`Table` need their own per-instance record: `1 <= n`, and
  `n * $size(T)` neither overflows nor passes a bound on address space.
- A literal used as a `Slot[n]` in a generic body, where `n` is symbolic,
  must be rejected or checked per instance. A constant index into `[n]T`
  is deferred to a run-time test today (`p/g1.rig`), and a Slot has no
  test to defer to.

## H5 (medium). Reserve with a dedicated mmap, never through `alloc.zig`

These paths break the zero invariant or commit memory:

- `allocLarge` reuses cached large blocks (`keep_large`) without zeroing
  them.
- `allocLarge` prefaults three quarters of a block (`MADV_POPULATE_WRITE`).
- The debug allocator fills memory with 0xaa.

Stale bytes put Slot fields of `n` or more inside records, and
`t2[t1[s].id]` then reads out of range. Prefaulting commits gigabytes.
The "small" lowering must `@memset` its block to zero.

## H6 (medium, design text). Strict overcommit and `RLIMIT_AS` are host settings, not targets

A build-time choice of lowering cannot fall back on such a host.

- Under `ulimit -v 8000000`, one 40 GiB reservation fails at the first
  table (measured on pup).
- `Table()` must panic with a clear message. It must never return a
  smaller table.

## H7 (low to medium). Owning tables: drop, clone, leak tracking

- **Drop:** it must cover all `n` slots, not `len`, because `t[s] = x`
  writes past `len`. List's drop glue stops at `len`.
- **Clone:** define `+t` over all `n` slots, or reject it. Copying a lazy
  table touches every page.
- **Leak tracking:** raw mmaps are invisible to `RIG_SANITIZE` and
  `RIG_LEAK_TRACE`, so a leaked Table is never reported. Register
  reservations in debug builds.

## H8 (low). `len` width when `n == 2^32`

The design says "`u64` when `n > 2^32`". At `n == 2^32`, a `u32` `len`
cannot hold `n`, so the last push overflows. It should read `>=`.

## H9 (low, fallback lowering only)

- No read may materialize a slot: not `?t[s]`, not `for`, and not a
  shared `?t` read across tasks.
- The growth arithmetic must be checked on a 32-bit `usize`.
- A foreign `s` that is large makes a write allocate up to `s`.
