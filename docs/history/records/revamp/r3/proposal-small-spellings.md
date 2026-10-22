# Proposal: small features Trig found, and how to spell them

For the design owner: Trig's NEEDS 17, 18, 19, 20, 22, 25, and 23/24, each built as a general feature. Probed on main at ad195ccff; no code changed. No item needs a grammar change: every recommended form parses today, and sema rejects it (for example, "no method `from_int` on type `Status`").

**One family, stated once.** Rig names the target first in a conversion: `I32(x)`. The new conversions keep that order, as type-level functions named for *how* they convert: `Status.from_int(n)`, `Float.from_bits(u)`, `I32.wrap(x)`. Reading a value's representation is a method, `f.to_bits()`, as `Int(st)` already reads an enum's value. `@` stays for questions about a type: `@variants(T)`.

## 1. An enum from its integer, and its list of variants (17)

**Capability.** Map an integer to the plain-enum variant with that value, or `none`, safely. Also list every variant as a constant. Today only `raw` `@fromBackingInt` does it, which blocks the catalog's `keyToMessage` and the SyntaxKind tables.

Lookup:
- **A. `Status.from_int(n) -> Status?` (recommended).** Target first. A missing code gives `none`, which composes with `??`; it is not a panic. It takes any integer type. Cost: it is the first built-in member of a user type, so a plain enum may not declare a variant or method named `from_int`. That is one rule, as `drop` is reserved in an `obj`; today such a method is accepted (probed).
- B. `enums.from_int[Status](n)` in a new `std.enums`: no reserved name, but its Rig body is a linear loop over `@variants(T)` until Zig-backed generics get bounds.
- C. `Status?(n)`, a conversion to an optional type that also makes `U8?(300)` `none`: general, but `?` after a name means "propagate none" everywhere else, and the rejected `O(5)` (`type O = Int?`) would become legal.

List:
- **A. `@variants(T)` (recommended):** a constant `[N]T` in declaration order, for a module constant, a `for`, or `.len`. It asks about a type, as `@size(T)` does.
- B. `Status.variants`, a type member like `U8.max`: it collides with a variant spelled `Status.variants`.
- C. `for s in Status`: you can iterate, but there is no value to store or count.

**Ownership/CORE:** none. **Lowering:** `std.enums.fromInt(Status, n)`, a switch; `@variants(Status)` is the literal `[.ok, .missing]`, built by sema. A payload enum gets the existing "variants with payloads" diagnostic. **Effort:** a day.

```rig
# test/behavior/types/enum_from_int.rig
enum Status
  ok = 200
  missing = 404

all = @variants(Status)

sub main()
  print(Status.from_int(404), Status.from_int(500), Status.from_int(U16(200)))
  for s in all
    print(s, Int(s))
  print(@variants(Status).len)

# expect:
# .missing none .ok
# .ok 200
# .missing 404
# 2
```
```rig
# test/reject/types/enum_from_int_rules.rig
enum Shape
  dot
  circle(r: Int)

enum Status
  ok = 200

  fun from_int(n: Int) -> Int
    n

sub main()
  print(@variants(Shape), Shape.from_int(0))

# error: 8:7: `from_int` is built into every plain enum
# error: 12:19: `@variants(T)` takes a plain enum; `Shape` has variants with payloads
# error: 12:35: `Shape` has variants with payloads, which have no integer value
```

## 2. A float's bits (18)

**Capability.** Read a float's IEEE bits as an unsigned integer of the same width, and turn such bits back into a float. jsnum goes through an 8-byte array today.

- **A. `f.to_bits()` and `Float.from_bits(u)` (recommended).** These are Rust's names, as Rig took `count_ones` and `swap_bytes`; the pair reads as one. `F32` goes with `U32`.
- B. `f.bits()`: `m.bits()` on a mask packs one bit per lane, which is a reduction. On a float it would be a reinterpretation: one name with two meanings, and no `from_` partner.
- C. `U64(f)`: that already converts by value (`2.5` becomes `2`).

**Ownership/CORE:** none. **Lowering:** `@as(u64, @bitCast(f))` and `@as(f64, @bitCast(u))`. The parameter is a `U64`, so `-1` is rejected as it is for any `U64`. **Effort:** half a day.

```rig
# test/behavior/types/float_bits.rig
sub main()
  x = 1.5
  b = x.to_bits()
  print(b, Float.from_bits(b), Float.from_bits(0x8000000000000000))
  y: F32 = 1.5
  print(y.to_bits(), F32.from_bits(0x3FC00000))

# expect:
# 4609434218613702656 1.5 -0.0
# 1069547520 1.5
```
```rig
# test/reject/types/float_bits_int.rig
sub main()
  n = 5
  print(n.to_bits(), Float.from_bits(-1))

# error: 3:11: type `Int` has no method `to_bits`
# error: 3:38: integer value `-1` does not fit in `U64`
```

## 3. Shortest round-trip digits (19)

**Capability.** For a finite float, the shortest decimal digits that read back exactly, and their decimal exponent. Rig computes these through Zig's Ryu to print a float, but doesn't expose them. jsnum parses them back out of `String(f)`, which writes 327 bytes for `5e-324`.

- **A. `math.shortest(f: Float) -> Decimal?` (recommended).** `pub obj Decimal` has `neg: Bool`, `digits: U64`, and `exp: Int`, with `|f| = digits * 10^exp`. `digits` has no trailing zero and is 0 for ±0; the result is `none` for NaN and ±inf. It allocates nothing. It is the primitive to build on: JS and Go write `1e+21`, Zig writes `1e21`, so formatting belongs above it.
- B. `text.push_float[.exponent](!s, f)`: exponent form, but in Zig's spelling, which matches neither JS nor Go. Leave it to std.text's string building (ROADMAP).
- C. A method, `f.decimal()`: it would need `Decimal` in the prelude, and std.math already holds the float functions.

**Ownership/CORE:** none. **Lowering:** a Zig-backed declaration in `std/math.zig` calling `std.fmt.float.binaryToDecimal(u64, bits, 52, 11, false, &Backend64_TablesFull)` (public in Zig 0.17), with trailing zeros stripped. **Effort:** half a day.

```rig
# test/behavior/std/math_shortest.rig
use std.math

fun zero() -> Float
  0.0

sub show(f: Float)
  if math.shortest(f) as d
    print(d.neg, d.digits, d.exp)
  else
    print("none")

sub main()
  show(5e-324)
  show(-0.1)
  show(1e21)
  show(123.45)
  show(0.0)
  show(1.0 / zero())

# expect:
# false 5 -324
# true 1 -1
# false 1 21
# false 12345 -2
# false 0 0
# none
```

## 4. A wrapping integer conversion (20)

**Capability.** Convert an integer to any integer type, keeping its value modulo 2^(the target's bit width), read in the target's signedness. This is Go's `int32(i)` and Rust's `as`. Today `I32(i)` panics when out of range.

- **A. `I32.wrap(x)` (recommended).** Target first, like `I32(x)`; SPEC already says `+%` "wraps". A saturating twin, `I32.clamp(x)`, can follow.
- B. `x.wrap[I32]()`, like `b.read[U64, .little](0)`: fits the bracket rule, but it is the only conversion with the target last.
- C. `I32%(x)`: `%` marks wrapping *operators*, and `Type%(` is a token form no reader would guess.

**Ownership/CORE:** none. **Lowering:** to a target no wider, `@truncate` then `@bitCast`; to a wider target, `@intCast` at the source's signedness, then `@bitCast`. A float argument is rejected. **Effort:** half a day.

```rig
# test/behavior/types/int_wrap.rig
sub main()
  big = 5000000000
  print(I32.wrap(big), U8.wrap(-1), U64.wrap(I32(-1)), I8.wrap(U8(200)), I32.wrap(Int.min))

# expect:
# 705032704 255 18446744073709551615 -56 0
```
```rig
# test/reject/types/int_wrap_float.rig
sub main()
  print(I32.wrap(2.5))

# error: 2:18: `I32.wrap(x)` takes an integer; convert a Float with `Int(x)` first
```

## 5. UTF-8 runes and Unicode white space in std.text (22)

**Capability.** Decode the code point at a byte offset, forward and backward, with Go's error contract: U+FFFD and size 1 for a bad byte, size 0 at the end. Iterate code points, and test Unicode White_Space. Trig has the decoder in four places (scanner, jsnum, semver, glob), and `text.trim` trims only ASCII.

- **A. `text.rune_at(s, i) -> Rune`, `text.rune_before(s, end) -> Rune`, `text.runes(s) -> Runes`, `text.is_space_rune(c: Int) -> Bool` (recommended).** `pub obj Rune` holds `code: Int` and `size: Int`, and `Runes` is an iterator like `Lines`. These are plain words like `find` and `cut`, and `_rune` keeps the code-point test apart from the byte test, `is_space(b: U8)`.
- B. Go's `decode_rune` and `decode_last_rune`: familiar to porters, but unlike any other std.text name.
- C. Only the iterator: the scanner needs random access.

**White space.** Recommended: `trim`, `trim_start`, `trim_end`, and `words` follow Unicode White_Space. Go's `TrimSpace` and `Fields`, Rust's `trim`, and Python's `strip` all do, and ASCII input keeps a fast path; this is the least surprise. The alternative, a separate `trim_unicode`, leaves two answers to "is this space?". `is_space(b)` stays the ASCII byte test. JS's `isStrWhiteSpace` is not White_Space (it adds U+FEFF and drops U+0085), so jsnum keeps its own predicate, which is correct.

**Ownership/CORE:** none. **Lowering:** Rig bodies in `std/text.rig`, ported once from Go's decoder; White_Space is one `match` of 25 code points. **Effort:** a day, with the overlong, surrogate, past-U+10FFFF, and cut-sequence cases each tested.

```rig
# test/behavior/std/text_runes.rig
use std.text

sub main()
  s = "a\u{e9}\u{20ac}\xff"
  i = 0
  while i < s.len
    r = text.rune_at(s, i)
    print(r.code, r.size)
    i += r.size
  print(text.rune_at(s, s.len).size, text.rune_before(s, 6).code)
  for r in text.runes("\u{e9}!")
    print(r.code)
  print(text.trim("\u{a0} x\u{3000}\n"), text.is_space_rune(0x2028), text.is_space_rune(0xFEFF))

# expect:
# 97 1
# 233 2
# 8364 3
# 65533 1
# 0 8364
# 233
# 33
# x true false
```

## 6. Assertions in `test` blocks (25)

**Capability.** A one-line check that stops the test when it fails, and prints the location, the source text, and both operands of a comparison. IDEAS.md and ROADMAP already list it; semver's tests count failures with a helper today.

- **A. `expect(cond)!` (recommended).** A builtin, special only as a direct call, like `print`. It fails with the built-in error `Expect.failed`, and the `!` shows the exit at the call site, as every other failure in Rig does. Without the `!`, the existing fallible-call rule rejects it. It works wherever a failure can pass up, so a test helper is an ordinary fallible function.
- B. `expect(a == b)`, IDEAS.md's sketch: shorter, but it leaves the block with nothing at the call to say so (silent control flow).
- C. `testing.equal(a, b)!` in std: a library, but it has no source text or location (Rig has no `@src`), and needs one function per comparison.

**Ownership/CORE.** Only as `print` does: each operand is read once, a fresh value is a statement temporary, and nothing moves. **Desugaring** (for INTERNALS), the form the checker walks: `l = ?a; r = ?b; if not (l OP r): report("f:l:c", "a OP b", l, r) to stderr; return Expect.failed`. A condition that is not a comparison reports only its text. **Effort:** one to two days, in a round of its own (it adds an ownership fact).

```sh
# test/cli/test_expect.sh
source "$ROOT/test/cli/_lib.sh"
cat >t.rig <<'EOF'
fun double(n: Int) -> Int
  n * 2

test "double"
  expect(double(2) == 4)!
  expect(String("a") == "a")!
  expect(double(3) == 7)!
  print("not reached")
EOF
out=$(rig test t.rig 2>&1); expect_rc $? 1 "failed expect"
expect_has "$out" 't.rig:7:3: expect failed: double(3) == 7 (6 == 7)' "report"
expect_has "$out" 'FAIL  test "double": Expect.failed' "verdict"
[[ $out != *"not reached"* ]] || fail "expect did not stop the test"
```
```rig
# test/reject/effects/expect_needs_bang.rig
test "t"
  expect(1 + 1 == 2)

# error: 2:3: fallible call to `expect` must be wrapped with `!` (propagate) or `catch` (handle)
```

## 7. Big integers and regular expressions (23, 24)

- **Big integers: yes, after Zig-backed owning types land** (ROADMAP, `obj X owns`). `std.bigint` would then wrap Zig's `std.math.big.int.Managed`, with method arithmetic (`a.add(b)`), in two or three days. jsnum's minimal one serves until then.
- **Regular expressions: not in std now.** Zig's std has none, so this means writing an RE2-style engine without backtracking in Rig. Trig needs seven patterns, all in semver and already hand-written. Revisit it as a userland package after modules at scale and closures as values (NEEDS 1 and 5), if the checker needs more.

## Decisions for the owner

1. New conversions name the target first, `T.how(x)`; reading a representation is a method. **Yes.**
2. Enum from integer: **`Status.from_int(n) -> Status?`**, with `from_int` reserved in plain enums. (Fallback: `enums.from_int[Status](n)`.)
3. The variant list: **`@variants(T)`**, a constant `[N]T`, plain enums only.
4. Float bits: **`f.to_bits()` and `Float.from_bits(u)`** (`F32`/`U32` too), not `f.bits()`.
5. Shortest digits: **`math.shortest(f) -> Decimal?`** (`neg`, `digits: U64`, `exp`). Exponent formatting waits for string building.
6. Wrapping conversion: **`I32.wrap(x)`**, integers only; `T.clamp(x)` is left for saturation.
7. UTF-8: **`text.rune_at`, `rune_before`, `runes`, `is_space_rune`, and `obj Rune(code, size)`**, with Go's error contract.
8. White space: **`trim`, `trim_start`, `trim_end`, and `words` use Unicode White_Space**; `is_space(b)` stays ASCII.
9. Assertions: **`expect(cond)!`**, failing with `Expect.failed`, allowed wherever a failure can pass up.
10. Big integers after Zig-backed owning types; regular expressions not in std now. **Yes.**
11. Order: **18, 20, 17, 19**, about two days together, unblocking jsnum and the catalog. Then 22, then 25 alone: it is the only item that touches the ownership checker.
