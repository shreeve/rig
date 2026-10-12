# Portable SIMD vectors for Rig

Status: approved by the owner, with the decisions in [README.md](README.md). It is written against `main` at
`8119e590`, and it assumes the `notwide` branch (`x.not()`, and a
`@Vector`-based `readInt`). Every Zig behavior it relies on was checked
with Zig 0.17.0. The programs are in `zig/` next to this file (see
the appendix).

## 0. The recommendation in brief

- **The type.** `Simd[T, n]`: `n` lanes of a number or `Bool` `T`, with
  `n` a power of two from 2 to 64. It lowers to `@Vector(n, T)`. A
  **mask** is `Simd[Bool, n]`, which is what a comparison returns. There
  is one type constructor, and it needs no grammar change: it is spelled
  like any generic instance (`Ring[Int, 4]`).
- **The block size.** The canonical block is `Simd[U8, 64]`, whose mask
  `bits()` gives a `U64`. Docs and examples use 64. Lane counts 16 and 32
  are legal too, since x86 already wins at 16.
- **Operators.** Every operator that takes numbers takes vectors, lane
  by lane. Arithmetic and bitwise operators give a vector, and
  comparisons give a mask. A scalar of the lane type, or a literal,
  stands for every lane (`v < 0x20`).
- **Safety.** Overflow follows the scalar rule: `+`, `-`, and `*` panic
  when any lane overflows, in debug and `--release` (Zig ReleaseSafe
  checks every lane; measured). `+%`, `-%`, and `*%` wrap lane by lane.
  A load is bounds-checked once per block. A `pad:` read defines the
  bytes past the end, so the last partial block needs no scalar tail.
- **Ownership.** A vector is plain data, one value like an `Int`. Its
  lanes are values, not places, as an Int's bits are. The Core gains no
  exception, and the ownership checker gains no rule: every fact about a
  vector comes from the type facts it already reads.
- **Methods, not `@` builtins.** Rig's `@` builtins are about types
  (`@size(T)`, `@name(T)`), and Zig's value builtins (`@splat`,
  `@select`, `@reduce`) stay raw-only. So vector operations are
  operators and methods, like `x.not()` and `bytes.read[T, e](at)`.
- **Portability.** Rig promises the meaning, not the instructions. With
  no SIMD (WASM MVP), Zig lowers every operation to scalar code with the
  same results and the same panics. Verified under wasmtime.
- **Effort.** About 12 agent-days, in three rounds (§5.9).

---

## 1. The type

### 1.1 Spelling

| Option | Example | For | Against |
|---|---|---|---|
| **`Simd[T, n]`** (recommended) | `Simd[U8, 64]`, `Simd[Bool, 64]` | One constructor for every lane type and count. Generic over `n` like `[n]T` (`fun f[n: Int](v: Simd[U8, n])`). The same shape as Rust's `Simd<u8, 64>` and Mojo's `SIMD[DType.uint8, 64]`, so a newcomer guesses it. It parses today as a generic instance. | An acronym, where Rig's built-in names are words (`List`, `Cell`, `Endian`). |
| `Lanes[T, n]` | `Lanes[U8, 64]` | A plain English word, in the house style. Same machinery as `Simd`. | Few readers would guess what it is. "Lanes" is jargon too, just less well known. |
| `U8x16`-style names | `U8x64`, `F32x4`, `Boolx64` | Short, and close to `U8`, `I128` (the name parser would grow a suffix). | Not generic over `n`: there is no `U8x[n]`. It adds an open-ended family of reserved names. Masks read badly (`Boolx64`). Aliases recover the shortness anyway (`type Block = Simd[U8, 64]`). |
| `[16]U8` with lane-wise ops | `a + b` on arrays | No new type. | `==` on arrays already means whole-value equality and returns a `Bool`, so making it lane-wise would change accepted programs. `+` on an array would hide a loop. Arrays hold anything, align to 1, and index at run time, while vectors do none of these. And the cost model (one register vs. memory) would be invisible. |
| `Vector[T, n]` | | The word the hardware vendors use. | `Vec` was just renamed `List` to avoid exactly this collision with growable vectors (C++, Rust). |

**Recommendation:** `Simd[T, n]`, with `Lanes` as the owner's
alternative if a word is preferred (only the name changes). Programs are
expected to alias it: `type Block = Simd[U8, 64]`, `type Mask = Simd[Bool, 64]`.

`Simd` becomes a reserved built-in name, like `List` and `Endian`. No
`.rig` or `.md` file in the repository uses it.

### 1.2 Lanes and counts

- **Lane type `T`:** any integer type (`I8`…`I128`, `U8`…`U128`), `F32`,
  `F64`, or `Bool`. The rule is the same as for a number, so there is no
  exception list. 128-bit lanes are legal and slow, as `U128` is.
- **Lane count `n`:** a compile-time integer (a literal, a constant, or
  a compile-time parameter, as for `[n]T`). It must be a power of two
  from 2 to 64; a constant one outside that range is rejected
  (`Simd[U8, 48]`: "a lane count is a power of two from 2 to 64"), and a
  compile-time parameter is checked at each instance, as an array
  length is. 64 is the cap so that every mask fits a `U64` (§2.3), and a
  power of two so that every count maps to whole registers on every
  target. (A three-lane `vec3` is a struct, as it is in most SIMD
  libraries.)
- `@size(Simd[U8, 64])` is 64, and `@size(Simd[Bool, 64])` is 8: the
  sizes are Zig's own.

### 1.3 Masks

A mask is `Simd[Bool, n]`. There is no separate `Mask` type. Zig's
`@Vector(n, bool)` is exactly that, and one constructor keeps one rule:
"a comparison of two `Simd[T, n]` is a `Simd[Bool, n]`". The bitwise
operators and `.not()` combine masks (§2.2). `and`, `or`, and `not` take
a single `Bool`, as everywhere else.

### 1.4 Block size

These are static instruction counts, not timings (Zig 0.17,
ReleaseSafe). The kernel tests whether each byte is `"`, `\`, below
0x20, or 0x80 or more, and gives the bit mask (`zig/mask*.zig`,
`neon*.zig`, `swar.zig`):

| Kernel, per call | aarch64 NEON | x86-64 SSE2 | x86-64 AVX2 | wasm simd128 |
|---|---:|---:|---:|---:|
| SWAR, `U64`, 8 bytes | 20 | | | |
| SWAR, `U128`, 16 bytes | 63 | | | |
| `Simd[U8, 16]` → `U16` | 20 | 15 | 12 | 14 |
| `Simd[U8, 64]` → `U64`, plain `@bitCast` | 54 | 51 | 26 | **511** |
| `Simd[U8, 64]` → `U64`, Rig's `maskBits` | **40** | 51 | 26 | **81** |

On NEON, LLVM's default lowering of a 64-lane mask spends about 5
instructions per 16 lanes. The runtime's `maskBits` uses simdjson's
reduction (four `and` with lane weights, four `addp`, one `fmov`): 9
instructions for all 64 lanes, so the whole 64-byte kernel is about 0.6
instructions per byte, against 2.5 for SWAR on `U64`. On WASM, a 64-lane
bitcast is legalized lane by lane (511 instructions); building it from
four 16-lane `i8x16.bitmask`s gives 81. Both are runtime choices behind
one Rig operation, `m.bits()`, so the program never changes.

**So:** the block a program should use is `Simd[U8, 64]`, and
`bytes.blocks(64)` yields it (§2.8). Smaller counts stay legal for data
that comes in smaller units (`Simd[F32, 4]`, `Simd[U32, 8]`).

---

## 2. Operations

In the tables below, `V` is `Simd[T, n]` and `M` is `Simd[Bool, n]`.

### 2.1 Construction

| Rig | Meaning | Zig emitted |
|---|---|---|
| `Simd[U8, 16].splat(x)` | every lane `x` (a `U8`, or a literal that fits) | `@as(@Vector(16, u8), @splat(x))` |
| `Simd[U8, 4]([1, 2, 3, 4])` | from an array of exactly `n` lanes. A type called on a value converts it, as `U8(x)` does. | `@as(@Vector(4, u8), arr)` |
| `Simd[U16, 16](v)` | lane by lane conversion from another `Simd[_, 16]`, checked like `U16(x)` (§2.6) | `@as(@Vector(16, u16), @intCast(v))` (or `@floatFromInt`, `@trunc`, `@floatCast`) |
| `bytes.read[Simd[U8, 64]](at)` | the 64 bytes from `at`. The byte order may be left out where it cannot matter: lanes of one byte | `rig.simdRead(@Vector(64, u8), bytes, at, .little)` |
| `bytes.read[Simd[U32, 4], .big](at)` | four `U32`s from `at`, each in byte order `e`; lane `i` is the `U32` at `at + 4 * i` | `rig.simdRead(@Vector(4, u32), bytes, at, .big)` (one load, then `@byteSwap` per lane when `e` is not native) |
| `bytes.read[Simd[U8, 64]](at, pad: 0x20)` | the same, but the bytes past the end read as `pad`, so only `0 <= at <= len` must hold (§4.1) | `rig.simdReadPadded(...)` |
| `!bytes.write[Simd[U8, 16]](at, v)` | stores the lanes | `rig.simdWrite(...)` (one unaligned store) |
| `for v, k in bytes.blocks(64)` | each full block as a `Simd[U8, 64]`, with its offset `k` (§2.8) | a `while` over `rig.simdRead` |

`read` and `write` are today's methods on bytes. A `Simd` of numbers
joins the `T`s they take ("an integer or float type, or a `Simd` of
them"), so a vector load needs no new method. `pad:` works for every
`T`, scalars included, which also covers the tails of the SWAR code
being written now.

### 2.2 Operators: one rule

> **On a `Simd`, an operator works lane by lane.** Arithmetic and
> bitwise operators give a `Simd` of the same type. A comparison gives
> a mask. Each lane follows the scalar rule for its type: `+` panics on
> overflow, `+%` wraps, `/` by zero panics. A scalar operand of the lane
> type, or a literal that fits it, stands for every lane, on either
> side.

| Operators | Lane types | Result | Zig |
|---|---|---|---|
| `+` `-` `*` `/` `%`, `-v` | numbers | `V` | `a + b`, `@divTrunc(a, b)`, `rig.rem(a, b)` (vector-aware), each checked per lane |
| `+%` `-%` `*%` (and `+%=` …) | integers | `V` | `a +% b` |
| `&` `|` `^` | integers, `Bool` (masks) | `V` / `M` | `a & b` |
| `<<` `>>` | integers; the amount is an integer, or a `Simd` of integers of the same `n` | `V` | `rig.shl(V, a, k)`, `rig.shr(V, a, k)` (§4.3) |
| `==` `!=` | any | `M` | `a == b` |
| `<` `<=` `>` `>=` | numbers | `M` | `a < b` |
| `x.not()` | integers: every bit; `Bool`: every lane | `V` / `M` | `~a`, `!m` (`notwide`'s `x.not()`, lane by lane) |

The compound assignments follow (`v += 1`, `m |= v == QUOTE`).

A scalar operand stands for every lane (`v < 0x20`, `v == QUOTE`,
`v >> 4`). This is the literal rule ("a literal takes the type its
context expects") carried one step further: the context is a `Simd`,
and its lanes give the type. A scalar variable must be exactly the lane
type, since there are no implicit numeric conversions. Typecheck records
the operand as a **splat** fact, and emit writes
`@as(V, @splat(x))` there (Zig itself never splats implicitly).

Precedence is unchanged, and it is Python's: `|`, `^`, and `&` bind
tighter than comparisons, so masks are combined in parentheses:
`(v == QUOTE) | (v == BACKSLASH)`. Without them it does not compile
(comparisons do not chain), so nothing is silently misread.

### 2.3 Masks

| Rig | Meaning | Zig |
|---|---|---|
| `m.bits()` | a `U64`, whose bit `i` is lane `i`, for every `n` (the higher bits are 0) | `rig.maskBits(n, m)`: `@bitCast` widened, or the per-target reduction of §1.4 |
| `m.any()`, `m.all()` | `Bool` | `@reduce(.Or, m)`, `@reduce(.And, m)` |
| `m.select(a, b)` | lane `i` is `a`'s where `m` is true, else `b`'s; `a`, `b` are `Simd[T, n]` or splatted scalars | `@select(T, m, a, b)` |
| `m.not()`, `m & k`, `m | k`, `m ^ k` | combine masks | `!m`, `m & k`, … |

`bits()` is always a `U64`, as Rust's `to_bitmask()` is a `u64`. That
gives a generic body over `n` one result type, and a 16-lane mask's
`U64` costs nothing extra. It composes directly with the planned bit
intrinsics: `m.bits().trailing_zeros()` is the first set lane, and
`m.bits().count_ones()` counts them, so masks need no `count()` or
`first()` of their own.

A mask is not a `Bool`. `if m` is rejected with
"`m` is a `Simd[Bool, 16]`, not a `Bool`: write `m.any()` or `m.all()`".
`m and k` and `not m` are rejected with hints for `m & k` and
`m.not()`. A ternary on a mask (`a if m else b`) is rejected with a hint
for `m.select(a, b)`, since a ternary runs one side and a select reads
both.

### 2.4 Reductions and lane-wise extremes

| Rig | Meaning | Zig |
|---|---|---|
| `v.sum()` | the lane-type sum, which **panics on overflow** as `+` does | `rig.simdSum(v)`: widen, `@reduce(.Add)`, `@intCast` (64-bit lanes: a checked fold) |
| `v.min()`, `v.max()` | the least or greatest lane | `@reduce(.Min, v)`, `@reduce(.Max, v)` |
| `v.min(w)`, `v.max(w)` | lane by lane | `@min(v, w)`, `@max(v, w)` |

Zig's `@reduce(.Add)` **wraps silently even in ReleaseSafe**: 200 + 100
+ 1 + 1 gave 46 (`zig/safe.zig`, `reduce`). So `sum()` must not be a
bare `@reduce`. The widened form costs 3–4 instructions more than the
wrapping one (`cost.zig`: 18 vs. 15 on aarch64). Float sums add the
lanes in order 0..n-1, so the result is deterministic.

### 2.5 Lanes, shuffles, and lookups

| Rig | Meaning | Zig |
|---|---|---|
| `v[i]` | lane `i` as a value; `i` is any integer, checked (a constant one at compile time) | `v[i]` for a constant `i`; `rig.lane(v, i)` otherwise (Zig cannot index a vector at run time: it goes through `[n]T`) |
| `v.with(i, x)` | a copy of `v` whose lane `i` is `x` | `rig.withLane(v, i, x)` |
| `v.array()` | the lanes as a `[n]T` | `@as([n]T, v)` |
| `v.shuffle(IDX)` | lane `j` is `v[IDX[j]]`, where `IDX` is a constant `[k]Int` of indexes below `n`, checked at compile time; the result is a `Simd[T, k]` | `@shuffle(T, v, undefined, idx)` |
| `a.join(b)` | `a`'s lanes then `b`'s: a `Simd[T, 2n]` (so a two-source shuffle is `a.join(b).shuffle(IDX)`, which LLVM folds) | `@shuffle(T, a, b, …)` |
| `t.lookup(idx)` | `t` is a `Simd[U8, 16]` table and `idx` a `Simd[U8, m]` (`m` a multiple of 16); lane `i` is `t[idx[i]]`, or 0 when `idx[i] >= 16` | `rig.lookup16(m, t, idx)`: NEON `tbl`, x86 `pshufb` (SSSE3, with the high bit set for indexes of 16 or more), WASM `i8x16.swizzle`, else a scalar loop |

`lookup` is what simdjson-style classification needs (§8.3). Its
semantics (out of range gives 0) are the ones all three instructions
share once the runtime masks `pshufb`'s low-nibble quirk.
`zig/lookup.zig` checks it on NEON, WASM simd128, and the WASM MVP
scalar fallback against a Python reference.

### 2.6 Conversions

- **Lane type:** `Simd[U16, 16](v)` converts lane by lane, with the
  scalar rules: a value that does not fit panics (Zig's vector
  `@intCast` checks each lane; measured), floats truncate toward zero,
  and `F32(x)` rounds.
- **To and from arrays:** `Simd[T, n](arr)` and `v.array()`.
- **To and from bytes:** `read` and `write` (§2.1). A raw reinterpretation
  (`Simd[U8, 16]` as `Simd[U64, 2]`) is not proposed: a `write` then a
  `read` says the same thing, and a `bitcast` method is an open question
  (§9).

### 2.7 Equality of values that hold a vector

`==` on a `Simd` is lane-wise. A struct, enum, or array that holds a
`Simd` therefore has no `==`: "`==` is not defined for `Lexer`: field
`lookahead` is a `Simd[U8, 16]`, whose `==` compares lane by lane;
compare `(a.lookahead == b.lookahead).all()`". This follows the existing
rule ("a type that holds one of these has no `==`, and the diagnostic
names the field"), with one more entry in its list.

### 2.8 Composition with the work in flight

- **`x.not()`** (`notwide`): the same method, lane by lane. The
  `ElemCall` `.not` fact grows a vector case, or the vector calls get
  their own fact (§5.3).
- **`@Vector`-based `readInt`** (`notwide`): `simdRead` uses the same
  `byteOffset` check and the same one-load pattern, through an `align(1)`
  pointer. The Zig guide's advice ("a 64-byte vector load is fastest
  through a pointer") holds.
- **`bytes.blocks(N)`**: this design asks that it yield `Simd[U8, N]`
  values and the offset (not the block number) as the second binding,
  and take `pad:` to include the last partial block. As a desugaring:

  ```
  for v, k in bytes.blocks(N)            for v, k in bytes.blocks(N, pad: p)
  ≡ k = 0                                ≡ k = 0
    while k + N <= bytes.len : k += N      while k < bytes.len : k += N
      v = bytes.read[Simd[U8, N]](k)         v = bytes.read[Simd[U8, N]](k, pad: p)
      body                                   body
  ```

  The source is read in place for the loop (a header subject, Core
  sentence 1). Each `v` is plain data and carries no loan, and the
  checker walks exactly this `while` (as IDEAS §0.3 does for iterators).
- **Bit intrinsics:** `bits()` returns a `U64`, so `trailing_zeros`,
  `leading_zeros`, and `count_ones` apply unchanged. This design assumes
  they are methods returning `Int` (`m.bits().trailing_zeros()`); if they
  become `@` builtins, the samples change spelling only.

---

## 3. The Core paragraph

Proposed for `docs/CORE.md` §1, after the kinds table; the table's
plain row gains `Simd[T, n]` as an example:

> **A vector is plain data, one value like an `Int`.** A `Simd[T, n]`
> holds `n` lanes of a number or `Bool`, so it owns nothing and views
> nothing: a bare use copies it, it carries no loan, and nothing moves,
> clones, or drops it but the rules of whatever holds it. Its lanes are
> parts of its value, not places, as an Int's bits are: `v[i]` reads a
> lane, and no lane is assigned, lent, or taken (`v.with(i, x)` makes
> the changed copy). `v` itself is a place like any other binding,
> field, or element, lent with `?v` and `!v`. Reading a vector out of
> bytes copies them, so the vector keeps no loan on what it was read
> from. *(planned)*

It needs no exception. Every case below follows from the kinds table
(§1) and sentence 1, through the facts the compiler already computes
from a type (`sema.holds`: `plain`, no `glue`, no `views`, not `unique`):

| Case | What happens | Why nothing new is needed |
|---|---|---|
| **A field** (`struct Lexer` with `ahead: Simd[U8, 16]`) | The struct stays plain if its other parts are. `l.ahead = l.ahead + 1` stores, `!l.ahead` lends the field, and `f(l.ahead)` copies. | "A struct's kind follows from its parts." |
| **In a List** (`List[Simd[U8, 64]]`) | `!xs.push(v)` copies `v` in, `xs[i]` copies a vector out, `!xs[i]` lends one element to write, and `for v in xs` binds copies. | A List holds any value; a plain element copies. Alignment comes from the element type (the runtime's `realloc` of `[]T` respects `@alignOf`; the sanitizer is tested with 64-byte alignment). |
| **A lend** (`?v`, `!v`, a `?Simd[U8, 16]` parameter) | A read view of a vector reads as its value in an operator, as a read view of an `Int` does. `!v` lets a callee assign the whole vector. | `sema.readsAsValue` gains the vector type (§5.2): one positive entry in the one classifier for that fact. |
| **Read from `?String` bytes** (`s.read[Simd[U8, 64]](i)`) | The result is a fresh plain value. `s` is read for the call only, and a `String` behind `s` may be changed right after. | Call origins: "a call's result carries the loans of the arguments whose types could hold what it views". A `Simd` holds no view, so it carries none, exactly as `s.read[U64, .little](i)` today. |

The one place lanes differ from array elements is that a lane is never
a place. That follows from "a vector is one value", not from a special
case: `v[i]` is listed with operator results in `handsOver`'s `made`
kind, by its type (§5.2). So `v[i] = x`, `!v[i]`, `?v[i]`, and `<v[i]`
are rejected by the rules that already reject them for any made value:
"a lane of `v` is a value, not a place: write `v = v.with(i, x)`".

---

## 4. Safety

### 4.1 Bounds on loads

- **Per load:** `bytes.read[Simd[U8, N]](at)` checks
  `0 <= at` and `at + N <= len` once, in every build mode, as `read`
  does today: one compare and branch per 64 bytes. A constant offset
  into an array is checked at compile time.
- **`pad:`:** `read[…](at, pad: p)` requires only `0 <= at <= len`.
  Lanes past the end are `p`. The runtime loads the whole block directly
  when it is in range, and otherwise copies the tail into a `p`-filled
  stack block (`simdReadPadded`, prototyped in `zig/proto.zig`). A
  scanner then needs no scalar tail loop, and no lane ever holds bytes
  it was not given.
- **`blocks(N)`:** the desugaring of §2.8 keeps every read in range by
  construction. LLVM removes the redundant check, since `k + N <= len`
  is the loop condition. A checker-proved bound elimination is the
  general improvement this would ride on, if LLVM ever misses one.
- **A padded buffer** (simdjson's 64 bytes of slack after the input)
  would let the last block load straight from the allocation. Rig can
  get this later as an invisible optimization of `pad:` reads from a
  `String` or `List[U8]` whose capacity covers the block. The runtime
  must then keep that slack initialized, so that no lane depends on
  freed or undefined bytes. It is not part of the semantics.

### 4.2 Per-lane overflow

**Decision: the scalar rule, per lane.** `+`, `-`, `*`, unary `-`,
`/`, `%`, and conversions panic when any lane overflows, divides by
zero, or does not fit. `+%`, `-%`, and `*%` wrap.

This is what Zig does for vectors, measured with Zig 0.17
(`zig/ovf.zig`, `safe.zig`):

| Operation | Debug | ReleaseSafe (`rig build --release`) | ReleaseFast |
|---|---|---|---|
| `a + b` where a lane overflows | panic "integer overflow" | panic | wraps (Rig never builds this mode) |
| `@shlExact` losing bits in a lane | panic | panic | |
| `@intCast` to a narrower lane type | panic | panic | |
| `@divTrunc` by a zero lane | panic | panic | |
| `@reduce(.Add)` overflowing | **wraps** | **wraps** | wraps |

`rig build --release` passes `-Osafe` (`src/main.zig`), so the checks
hold in release, as for scalars. A checked `u8x16` add costs a compare,
a horizontal max, and a branch: 12 instructions vs. 8 wrapping on
aarch64. A scanner uses comparisons and bitwise operators, which never
check, and arithmetic tricks are written with `-%` as they are on
scalars (the SWAR code already does). The one Zig gap, `@reduce(.Add)`,
is closed by lowering `sum()` through `rig.simdSum` (§2.4).

Requiring `+%` for every vector add would be a second arithmetic rule
for the same lane values, and it would make the safe operator the
surprising one. So it is rejected.

### 4.3 Shifts

The scalar rule applies per lane. An amount may be any integer type, or
a `Simd` of integers with the same `n`, which shifts each lane by its
own amount.

- An amount must be below the lane width. A constant one is rejected
  ("shift amount `9` is out of range for `U8` (0..7)"), and a run-time
  one panics when any lane's is not. Zig's vector `@intCast` to
  `@Vector(n, u3)` does this; measured.
- A left shift that loses a set bit (or the sign) in any lane panics,
  with `@shlExact` on the vector; measured. `>>` is logical for unsigned
  lanes and arithmetic for signed ones, as for scalars.
- SIMD nibble code wants a lossy left shift often. Today it is written
  `(v & 0x0F) << 4`, as on scalars. A wrapping `<<%` for scalars and
  vectors together is an open question (§9), not part of this design.

---

## 5. Implementation plan

No grammar change. `Simd[U8, 64]` is a `generic_inst` in a type and an
`inst` in an expression (`Simd[U8, 64].splat(x)`, `Simd[U8, 4](arr)`,
`s.read[Simd[U8, 64]](i)`). Nexus and the Nexus mirror of `rig.grammar`
are untouched.

### 5.1 Types: `src/sema.zig`, `src/resolve.zig`

- `sema.Type` gains `simd: SimdType`, with `SimdType = struct { elem:
  TypeId, len: TypeId }`, where `len` is a `ct_value` or a `ct_param`
  exactly as in `ArrayType`. Interning, hashing, and equality are
  structural through `inline else`.
- `resolve.registerBuiltins` registers `Simd` as a `generic_type` with
  one type parameter and one `Int` value parameter, so `instTarget`,
  `checkInstArgs`, compile-time argument checking, and generic
  substitution treat it like `Ring[T, n: Int]`. `instanceOf` maps its
  instance to `.simd` rather than to `parameterized_nominal`. It needs
  `addGeneric` to take a value parameter (small). It is reserved like
  `Endian`.
- `builtinElementError` (or its `Simd` twin) checks the lane type (a
  number or `Bool`) and the count (a power of two, 2..64). A
  compile-time parameter count is checked per instance, through the path
  array lengths use.
- The sites that switch on `.array` (23 in `sema`, 21 in `typecheck`, 7
  in `emit`, 2 each in `ownership` and `storage`, 1 in `resolve`) each
  get a `.simd` case or are shown to fall through correctly. The
  important ones:
  - `holdsIn` / `computeTypeInfo`: `.simd` → `.{ .plain = true }`.
    Every ownership fact (`copies`, `moves`, `isPlainData`,
    `readByAddress`, `dropRunsBody`, `isUnique`) then answers "plain"
    with no further change.
  - `minBytes` / `byteSizes`: Zig's `@sizeOf` (for `Bool` lanes, the
    packed size: `n / 8` rounded up to a power of two, at least 1).
  - `formatType` / `@name`: `Simd[U8, 16]`. `substituteType`,
    `importType`, `containsTypeVar`, and `heldTypeVars`, as for arrays.
  - `EquatableWalk.step`: `.simd` held in a declaration → a new
    `NotEquatable.Why.lanes` (§2.7). A bare `Simd` compared is the
    lane-wise operator, not this walk.

### 5.2 Facts and classifiers

Each of these is one positive entry in an existing classifier, decided
by type, or one new fact recorded where typecheck decides it. No pass
re-derives anything from syntax.

| Fact or classifier | Change |
|---|---|
| `sema.isScalar(ty)` (new; replaces `ownership.isScalar`'s private test) | `isCopyPrimitive(ty) or ty is .simd`. A vector is a by-value receiver and a by-value operand, so a method call on it never takes its address. `isCtValueType` keeps `isCopyPrimitive`: a vector is not a compile-time argument. |
| `sema.readsAsValue` | `isScalar or isPlainEnum`, so an operator reads a `?Simd` as its value, as it does a `?Int`. |
| `sema.handsOver` | An `index` whose object's type is a `Simd` is `made` (a lane is an operator-like result), listed beside "an operator's result". This is the only classifier change that touches ownership. It goes through the one-branch-at-a-time rule, and the `classify` test keeps it the only classifier. |
| `Question.splat` (new node fact) | Recorded by typecheck on a scalar operand of a lane-wise operator or of `select`, holding the `Simd` type it fills. Emit reads it through `facts.splatOf(node)`. |
| `SimdCall` (new call fact, beside `ElemCall`) | `{ op: SimdOp, vec: TypeId, … }` with `SimdOp = { splat, from_array, convert, array, bits, any, all, select, sum, min, max, min_lanes, max_lanes, lane, with, shuffle, join, lookup, not }`, recorded by `Checker.simdCall`. Emit's `emitSimdCall` switches on it. `facts.Pending` does not grow. |
| `ElemCall` (`read`/`write`) | `num` may be a `.simd`, with `pad` recorded when given. |

### 5.3 Type checking: `src/typecheck.zig`

- **Operators:** `numericOperands`, `synthShift`/`checkShiftAmount`,
  `synthOrdering`, the equality path, and the bitwise path get one shared
  helper, `simdOperands(e, op, req)`. It accepts two operands of the
  same `Simd`, or one `Simd` and one scalar of its lane type (or a
  literal, checked to fit the lane type and recorded as a splat). It
  returns the `Simd`, or the mask type for comparisons. It applies the
  scalar `Requirement` to the lane type, so the existing messages
  ("operator `+%` requires integer operands; got `Simd[F32, 4]`")
  follow. A literal shift amount is checked against the lane width.
- **Diagnostics for masks:** in `checkCondition` (a mask as a `Bool`),
  `and`/`or`, `not`, and the ternary condition, each with its hint
  (§2.3).
- **Methods:** `Checker.simdCall`, called in `synthMethodCall` beside
  `elemsCall`, `stringCall`, and `notCall`, types each method of §2 and
  records `SimdCall`. The static `Simd[T, n].splat(x)` and the
  conversion call `Simd[T, n](x)` go through the type-call path
  (`Point.origin()`, `U8(x)`).
- **Bytes:** `bytesCall` takes a `Simd` `T` (number lanes only), takes
  one bracket argument when `T`'s lanes are one byte (the single-argument
  bracket form is read as compile-time arguments, as for
  `s.times[5]()`), and takes the `pad:` keyword. `checkOffsetArg` uses
  `@size(T)`.
- **Lanes:** `synthIndex` on a `Simd` gives the lane type, and checks a
  constant index against `n`. The place checks (assignment target,
  `?`/`!`/`<` of a lane) get the lane hint.
- **Generics:** `Requirement` gains nothing. A generic `T` instantiated
  with a `Simd` meets `.copies`. Arithmetic in a generic body over a
  `T` that is a `Simd` is checked per instance like any other `T`,
  except where a body's literal would need a splat. That instance is
  rejected for now, as a float `T` meeting `1 / 2` is; it can be relaxed
  later.

### 5.4 Ownership: `src/ownership.zig`, `src/storage.zig`

Nothing new beyond `isScalar`. The forms the emitter produces are an
operator on values, a call of a runtime function with by-value
arguments, and a read of bytes through the existing `read` call. Each is
a form the checker already walks: "the checker checks exactly what is
emitted" holds because emit adds no temporary, address, or evaluation
order. `@as(V, @splat(x))` is an rvalue whose address is never taken,
so it needs no storage fact.

`test/oracle/lower.zig` (the reference checker) learns `Simd` as plain,
as `notwide` taught it `x.not()`.

### 5.5 Emit: `src/emit.zig`

- `emitTypeTy`: `.simd` → `@Vector(n, T)` (`bool` for `Bool`).
- `emitExpr`: an operand with a splat fact is written
  `@as(V, @splat(e))`. `emitInfix` writes `==` and `<` on vectors as
  Zig's operators: `comparesStructurally` and `orderOperator` must say no
  for `.simd`. `+%` and the shifts use `writeAsOpen(V)` as they do now,
  with the shift going through `rig.shl`/`rig.shr` for vectors. `/` and
  `%` go through `emitDivision`'s vector-aware `rig.div`/`rig.rem`.
- `emitSimdCall`: one switch over `SimdOp`, mapping to the Zig of §2.
- `emitElemCall` (`read`/`write`): `rig.simdRead`/`simdReadPadded`/
  `simdWrite` when `num` is a `Simd`.
- `print`: a vector prints as its array does (`[1, 2, 3, 4]`), and a
  mask as `[true, false, …]`. This happens in the runtime's printer
  (`@typeInfo(T) == .vector` → coerce to an array).

### 5.6 Runtime: `src/runtime.zig`

| Helper | Lowering |
|---|---|
| `simdRead(V, bytes, at, e)` | `byteOffset` check, one load through `*align(1) const V`, `@byteSwap` per lane when `e` is not native and lanes are wider than a byte |
| `simdReadPadded(V, bytes, at, e, pad)` | in range: `simdRead`; else a `pad`-filled `[size]u8`, `@memcpy` of the tail, then cast |
| `simdWrite(V, bytes, at, v, e)` | one store through `*align(1) V` |
| `maskBits(n, m) u64` | aarch64+NEON, `n == 64` (and 32): `and` with lane weights, `addp` tree through `@extern("llvm.aarch64.neon.addp.v16i8")`. WASM, `n > 16`: 16-lane pieces through `i8x16.bitmask`. Otherwise: `@bitCast`, widened |
| `simdSum(v)` | widen to the next lane width, `@reduce(.Add)`, `@intCast` (panics like `+`); 64- and 128-bit lanes: a fold with `@addWithOverflow` |
| `lookup16(m, t, idx)` | NEON `tbl1`, SSSE3 `pshufb` (index ≥ 16 → high bit), WASM `swizzle`, else a scalar loop (`zig/lookup.zig`) |
| `lane(v, i)`, `withLane(v, i, x)` | via `[n]T`, with `index()`'s bounds check |
| `shl`, `shr`, `div`, `rem` | the scalar helpers made vector-aware (`rem`'s `b == -1` rule through `@select`) |

The target-specific paths are Zig behind one Rig meaning. Each must
agree with the generic `@bitCast` or loop path, and a runtime unit test
checks that on random inputs (the runtime's tests run on every target
CI builds).

### 5.7 Tests

- **Behavior** (`test/behavior/types/simd_*.rig`): construction (splat,
  array, conversion), every operator with each operand shape, masks
  (`bits`, `any`, `all`, `select`, `not`), reductions, lanes
  (`v[i]`, `with`, `array`), shuffle, join, lookup, bytes (`read` with
  and without `pad:`, `write`, `.big` lanes), a vector in a struct, in a
  List, behind `?` and `!` parameters, in a `Cell` and an owned closure
  (plain data goes there), generic over `n`, `@size`/`@name`, and
  `print`.
- **Runtime panics** (`test/behavior/runtime/`): a lane overflowing `+`,
  `*`, and a conversion; a lane's shift losing bits; a run-time shift
  amount out of range; a lane divided by zero; `sum()` overflowing; a
  read out of range, with and without `pad:`; a run-time lane index out
  of range. Each runs in debug and `--release`.
- **Rejects** (`test/reject/types/simd_*.rig`): lane count (48, 128,
  0), lane type (`?String`, a struct), mixed `Simd` types, a scalar of
  another type, a literal that does not fit the lane, a mask as a
  condition, `and`/`or`/`not` on masks, a ternary on a mask, lane
  assignment and lane lends, a constant lane index out of range, a
  constant shift amount out of range, `==` on a struct holding a `Simd`,
  `read` of a `Simd[Bool, n]`, a missing byte order for wide lanes, a
  constant offset past an array's end, and `shuffle` with a non-constant
  or out-of-range index.
- **Doc examples:** SPEC's new "Vectors" section after "Bytes", with
  `rig` and `rig reject` examples. CORE's paragraph enters as a
  `rig pending` example, which turns into an ordinary one in the round
  that builds it (AGENTS rule 1).
- **Matrix** (`test/matrix.py`):
  - `TYPES` gains `simd` (`Simd[U8, 4]`, `mk="Simd[U8, 4].splat(U8(n))"`,
    `ctor="Simd[U8, 4]([1, 2, 3, 4])"`), so every form × context cell
    (place, field, ternary, optional, `match`, move, clone, read/write
    view × print, binding, field store, list push, return, element
    assign, …) runs for a vector. The `eq` context prints a mask.
  - A new family, `lanes.`, is a differential grid. Each cell writes
    the vector expression and the same expression lane by lane on
    scalars, and requires equal output, or a panic in both. Its axes:
    - operator (the 24 of §2.2 and §2.4);
    - operand shape: vector·vector, vector·scalar, scalar·vector,
      vector·literal, `?vector`·vector;
    - lane type: `U8`, `I8`, `U16`, `I32`, `U64`, `I64`, `F32`, `F64`,
      `Bool`;
    - count: 2, 16, 64;
    - values: an edge set per type (0, 1, -1, min, max) that puts an
      overflowing lane in a different position each time;
    - build: debug and `--release`.

    Pruned to valid type × operator pairs, with values pairwise, this
    is about 1,500 programs.
  - When Rig gains a target flag, the `lanes.` grid also runs under
    wasmtime, built for `-mcpu=mvp` and `simd128`.
- **Oracle:** the `lanes.` and `simd` cells join the oracle's sets. Its
  coverage floors rise.

### 5.8 Docs

- SPEC: §2 gets "Vectors" (type, lanes, masks, operators, methods,
  bytes, safety), §5 Operators gets one paragraph ("On a `Simd`, an
  operator works lane by lane"), and §18 gets anything deferred.
- SYNTAX §3 gets `Simd` among the reserved names, and §7 a row in the
  types table.
- CORE §1 gets the paragraph (§3 above). It needs the owner's approval
  as a Core wording change.
- INTERNALS: "Vectors", a desugaring table (each Rig operation → the
  Zig of §2) and why the checker's walk is unchanged (§5.4), plus the
  facts of §5.2 in "The facts table".
- QUICK: one line. ROADMAP: remove nothing (vectors are not listed
  there); IDEAS: none.

### 5.9 Effort (agent-days, gates included)

| Round | Contents | Effort |
|---|---|---:|
| **1. The scanner's needs** | type and resolve (1.5); operators and splat (1.5); construction, `array`, `v[i]`, masks (`bits`, `any`, `all`, `select`, `not`) (1); bytes `read`/`write` with `pad:` (0.5); emit and runtime, with `maskBits`' per-target paths (1); docs, behavior and reject tests, and the matrix `TYPES` entry (1) | **6.5** |
| **2. The rest of the surface** | reductions with checked `sum`; lane-wise `min`/`max`; conversions; `with`, `shuffle`, `join`, `lookup` (with its per-target paths); struct `==` rejection; generic-over-`n` polish | **4** |
| **3. Integration** | `blocks(N)` yielding vectors (with the blocks round), the `lanes.` grid, oracle coverage, release notes | **2** |
| | **Total** | **≈ 12.5** |

Round 1 changes `handsOver` and `readsAsValue`, so it lands alone, per
the one-branch-at-a-time rule. Rounds 2 and 3 touch neither.

---

## 6. WASM and portability

**What Rig promises:** a `Simd` operation means the same thing on every
target: the same lanes, the same mask bits, and the same panics. How
fast it is depends on the target. Rig never promises a SIMD instruction.

- **No SIMD at all** (WASM MVP, or a CPU without NEON or SSE): Zig
  legalizes `@Vector` operations to scalar code. The runtime's
  target-specific paths are each guarded by a feature test
  (`featureSetHas(.neon)`, `.simd128`, `.ssse3`), with a portable path
  otherwise. `zig/proto.zig` (the 64-byte scan) and `lookup.zig` print
  identical results natively, on `wasm32-wasi -mcpu=mvp`, and on
  `-mcpu=generic+simd128` under wasmtime.
- **WASM simd128:** 16-lane operations are native (14 instructions for
  the 16-byte kernel). For 64 lanes the runtime builds masks from 16-lane
  pieces (81 instructions, against 511 for a plain bitcast). A program
  for WASM is the same program; `Simd[U8, 64]` costs four `v128`s per
  step.
- **Release builds** are ReleaseSafe on every target, so the checks of
  §4 are the same everywhere.
- **What could differ:** float sums and min/max with NaN would differ if
  the runtime let LLVM reassociate. It does not: `sum()` on floats adds
  in lane order, and `min`/`max` follow Zig's `@min`/`@max` NaN rule
  (the other operand), as the scalar `min`/`max` would.
- Rig has no target flag yet (`rig build` builds for the host). WASM is
  planned, and the `lanes.` grid is ready to run there when the
  flag lands.

---

## 7. Alternatives

**A. Named types, `U8x16` and friends.** It is shortest for fixed code,
and it needs only the sized-type name parser. It fails on generics
(`fun f[n: Int]` cannot name `U8x[n]`), on masks (`Boolx64`), and on the
house rule that one rule covers analogous forms: `[n]T` is generic over
`n`, so the vector should be too. The aliases `Simd` invites
(`type Block = Simd[U8, 64]`) give the same brevity where it matters.

**B. Lane-wise operations on arrays (`[16]U8`).** It has no new type and
no new name, but it changes the meaning of accepted programs (`==` on
arrays returns a `Bool` today) and hides the cost model (a register
vs. memory, aligned vs. not). Lanes would be places, which arrays need
and vectors cannot honor in Zig (no run-time index, and no pointer to a
lane). It contradicts "no hidden" effects, so it is rejected.

**C. A standard library module with methods only** (`use std.simd`;
`a.add(b)`, `a.eq(b)`, a Zig-backed `copy` type). This puts the least
in the compiler, but Zig-backed types do not exist yet (ROADMAP), there
are no traits for operators, and `(v.eq(QUOTE)).or(v.eq(BACKSLASH))`
loses the bar (IDEAS §0, "shorter and plainer than Rust"). It would also
still need compiler help for `read` and `bits()`.

**D. No vector type: SWAR on `U128` plus bit intrinsics.** This is
being built anyway, it composes, and it is enough for 8 and 16 bytes.
It is 4× more instructions per byte than a 64-byte vector on NEON
(§1.4), it cannot do lane-wise compares below 0x20 without carries
across bytes (the carry trick marks only the first byte), and it cannot
do table lookups. It complements vectors rather than replacing them.

**Recommendation:** the built-in `Simd[T, n]` of this design, with
lane-wise operators, masks as `Simd[Bool, n]`, `bits()` as a `U64`, and
the 64-byte block as the documented default. Ship round 1 first: it is
exactly what a scanner and the JSON benchmark need.

---

## 8. Sample programs (proposed syntax)

These are written as the SPEC's examples would be. Their outputs were
computed from the same logic in Zig and Python (§ appendix).

### 8.1 A 16-byte quote/backslash scan

```text
QUOTE: U8 = 0x22
BACKSLASH: U8 = 0x5C

# The index of the first `"` or `\` from `at` on, or `s.len`. The last
# block reads 0 past the end, which matches neither.
fun find_quote(s: ?String, at: Int) -> Int
  i = at
  while i < s.len : i += 16
    v = s.read[Simd[U8, 16]](i, pad: 0)
    hits = (v == QUOTE) | (v == BACKSLASH)
    return i + hits.bits().trailing_zeros() if hits.any()
  s.len

sub main()
  s = 'say "hi" \ there'
  print(find_quote(s, 0), find_quote(s, 5), find_quote(s, 8))
```

```output
4 7 9
```

### 8.2 The first special byte, 64 at a time

The JSON benchmark's `skip_plain_ascii` (today about 40 lines of SWAR
with `special128` and `first_marked128`) becomes:

```text
type Block = Simd[U8, 64]

QUOTE: U8 = 0x22
BACKSLASH: U8 = 0x5C

# The index of the first byte from `at` on that is a quote, a backslash,
# a control byte, or 0x80 or more; `s.len` when there is none. Past the
# end, a block reads spaces, which are none of those.
fun skip_plain_ascii(s: ?String, at: Int) -> Int
  i = at
  while i < s.len : i += 64
    v = s.read[Block](i, pad: 0x20)
    special = (v == QUOTE) | (v == BACKSLASH) | (v < 0x20) | (v >= 0x80)
    bits = special.bits()
    return i + bits.trailing_zeros() if bits != 0
  s.len

sub main()
  t = "  key: \"va\\lue\" \x01 tail that runs on past sixty four bytes of plain ascii text"
  print(skip_plain_ascii(t, 0), skip_plain_ascii(t, 8), skip_plain_ascii(t, 11), skip_plain_ascii(t, 16), skip_plain_ascii(t, 18))
```

```output
7 10 14 16 77
```

With `blocks` (§2.8) the loop reads:

```text
fun skip_plain_ascii(s: ?String, at: Int) -> Int
  for v, k in s[at..].blocks(64, pad: 0x20)
    bits = ((v == QUOTE) | (v == BACKSLASH) | (v < 0x20) | (v >= 0x80)).bits()
    return at + k + bits.trailing_zeros() if bits != 0
  s.len
```

### 8.3 Whitespace classification

The plain version uses compares:

```text
fun spaces(v: Simd[U8, 64]) -> U64
  ((v == 0x20) | (v == 0x09) | (v == 0x0A) | (v == 0x0D)).bits()
```

simdjson's version classifies every byte with one table lookup per
nibble. In `kinds`, bits 0x18 mark whitespace and bits 0x07 the
structural bytes `, : [ ] { }`. The tables were checked exhaustively
over all 256 bytes, and the program's output is from the Zig prototype
(`zig/lookup.zig`):

```text
struct Classes
  space: U64    # bit i: byte i is a space, a tab, CR, or LF
  ops: U64      # bit i: byte i is one of , : [ ] { }

fun classify(v: Simd[U8, 64]) -> Classes
  low = Simd[U8, 16]([16, 0, 0, 0, 0, 0, 0, 0, 0, 8, 10, 4, 1, 12, 0, 0])
  high = Simd[U8, 16]([8, 0, 17, 2, 0, 4, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0])
  kinds = low.lookup(v & 0x0F) & high.lookup(v >> 4)
  Classes(space: ((kinds & 0x18) != 0).bits(), ops: ((kinds & 0x07) != 0).bits())

sub main()
  s = "{\"a\": [1, 2],\t\"b\":\r\n {}}   xyz  0123456789abcdefghijklmnopqrstuv"
  c = classify(s.read[Simd[U8, 64]](0))
  print(c.space, c.ops)
```

```output
3340509728 14817617
```

(These are `0xc71c2220` and `0xe21951`.)

---

## 9. Open questions for the owner

1. **The name:** `Simd[T, n]` (recommended: the Rust and Mojo
   precedent), or the plain word `Lanes[T, n]`?
2. **Lane-wise comparisons:** `==` and `<` on vectors give masks
   (recommended, as in Zig, GLSL, and numpy), or methods (`v.eq(w)`, as
   in Rust, whose `==` must return `bool`)? With masks, a struct holding
   a `Simd` has no `==` (§2.7).
3. **Implicit splat** of a scalar operand of the lane type
   (recommended), or `Simd[U8, 64].splat(q)` written every time?
4. **Omitting the byte order** for one-byte lanes (`read[Block](i)`):
   accept, and allow `read[U8](i)` for symmetry? Or always write
   `.little`?
5. **`pad:` on `read`,** for scalars too, as the general answer to tails?
6. **Lane writes:** `v.with(i, x)` only (recommended: lanes are not
   places), or allow `v[i] = x` as sugar for `v = v.with(i, x)`?
7. **`bits()` always `U64`** (recommended), or the smallest `UN` that
   holds `n`?
8. **Lane counts:** powers of two from 2 to 64 (recommended), or any
   `n` (a 3-lane `vec3`), with `bits()` still a `U64`?
9. **A wrapping left shift `<<%`** for scalars and vectors together: now,
   later, or never?
10. **`min`/`max` by arity:** `v.min()` reduces and `v.min(w)` works
    lane by lane. Is one name with two arities acceptable, or should one
    be renamed?
11. **`blocks(N)`:** its second binding is the byte offset (recommended)
    or the block number? Does it take `pad:`?
12. **Constants:** may a module-level constant hold a `Simd` built from
    literals (`LOW = Simd[U8, 16]([...])`), which Zig folds at compile
    time? The samples build their tables inside the function to avoid
    the question.
13. **Scheduling:** vectors are a new language feature, out of scope
    under the feature freeze (HANDOFF). They are on the path of the
    JSON parser ("safe SIMD vectors" in the performance rule), so they belong after
    v0.3.0, or need the owner's exception.
14. **The bit intrinsics' spelling:** this design assumes methods
    (`x.trailing_zeros()` → `Int`). If they become `@` builtins, only
    the samples change.

---

## Appendix: what was measured, and where

All of these are in `zig/` (Zig 0.17.0, aarch64-macos host;
cross-compiled to x86-64 and wasm32, with WASM run under wasmtime).

| File | Shows |
|---|---|
| `ovf.zig` | Vector `+` overflow panics in Debug and ReleaseSafe, and wraps in ReleaseFast |
| `safe.zig` | Vector `@shlExact`, shift-amount `@intCast`, narrowing `@intCast`, and division by zero panic per lane in ReleaseSafe; `@reduce(.Add)` wraps (46); `!` on a bool vector works |
| `ops.zig` | compare → `@bitCast` to `u16` and `@ctz`; `@reduce`, `@select`, `@shuffle`, vector shifts, `+%`, `@min`, and `|` on bool vectors |
| `mask.zig`, `mask4.zig`, `mask5.zig` | mask instruction counts per target; the WASM fixes for 64 lanes |
| `neon2.zig`, `neon3.zig`, `chk2.zig` | the `addp` mask reduction: 40 instructions for the 64-byte kernel on NEON, with the same mask as `@bitCast` |
| `swar.zig` | the SWAR kernels' counts (20 for `U64`, 63 for `U128`) |
| `cost.zig` | checked vs. wrapping add, and checked vs. wrapping sum |
| `sz.zig` | `@sizeOf` and `@alignOf` of vectors (`@Vector(64, bool)` is 8 bytes) |
| `proto.zig` | the Zig §8.2 would emit, with `simdReadPadded` and `maskBits`; the same output natively and on WASM MVP and simd128 |
| `lookup.zig` | `lookup16` on NEON `tbl`, WASM `swizzle`, and the scalar fallback; the same masks as a Python reference |
