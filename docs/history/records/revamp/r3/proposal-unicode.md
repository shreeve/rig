# Proposal: std.unicode, and the text helpers Trig asked for (NEEDS 22 follow-on)

For the design owner. Status: proposal; no code changed. Builds on the
approved runes round (`proposal-small-spellings.md` item 22: `text.rune_at`,
`rune_before`, `runes`, `is_space_rune(c: Int)`, `obj Rune(code, size)`,
Unicode trim). Every name below takes a code point as an `Int`, as
`is_space_rune` does, and is a plain function in a module (SYNTAX: value
operations are functions or methods; nothing here is a sigil).

## 0. Recommendation

1. **`std.unicode`** (new): `VERSION`, `is_id_start(c)`, `is_id_continue(c)`,
   `is_high_surrogate(c)`, `is_low_surrogate(c)`, `surrogate_pair_to_code_point(hi, lo)`,
   `utf16_len(c)`. Later, phase 3: `lower(s)`, `upper(s)`, `simple_fold(c)`.
2. **`std.text`** (existing): `parse_int(s, base: Int = 10)`,
   `format_int(n, base: Int = 10, upper: Bool = false) -> String`, and
   `edit_distance(a, b, !row, max: Int = -1) -> Int`.
3. Tables: a Python generator (`tools/gen-unicode.py`) reads a pinned UCD
   directory and writes `std/unicode_tables.zig`, checked in, reached through
   `extern zig`. Two-level bitmap lookup with an ASCII fast path.
4. `is_space_rune` stays in `std.text` (already approved there); `std.unicode`
   is for properties of code points that no `text` function needs.

## 1. Evidence (tsc Go scanner, `misc/TypeScript/tsc/internal`, non-test)

| Need | Calls in tsc | Notes |
|---|---|---|
| `IsIdentifierStart/Part` | 28 | tables in `identifier_parts_generated.go`: ~620 + ~720 ranges, Unicode 15.1.0, 32 KB of Go |
| high/low surrogate tests | 12 | plus 11 `utf16.` calls, 19 decode/pair sites |
| `strconv.Parse/FormatInt/Uint` | 31 | printer uses base 16 (upper), scanner base 8 |
| `strings.ToLower/ToUpper` | 53 / 10 | mostly ASCII file names and keywords; `ToLowerJS` has Final_Sigma |
| Levenshtein | 13 refs, one algorithm | **weighted**, see 4 |

## 2. std.unicode: identifier classes

```rig
use std.unicode

sub main()
  print(unicode.is_id_start(0x61), unicode.is_id_start(0x30), unicode.is_id_continue(0x30))
  print(unicode.is_id_start(0x2118), unicode.is_id_start(0xB7), unicode.is_id_continue(0xB7))
  print(unicode.is_id_start(0x2E2F), unicode.is_id_continue(0x200C), unicode.is_id_start(0x4E00))
  print(unicode.VERSION)
```

```output
true false true
true false true
false false true
15.1.0
```

Definition: UAX #31 default: `ID_Start` and `ID_Continue`, which the UCD
already derives with `Other_ID_Start` (U+2118, U+212E, U+309B-309C, U+1885-1886)
and `Other_ID_Continue` (U+00B7, U+0387, U+1369-1371, U+19DA) included.
`ID_Continue` contains `ID_Start`. Language additions (`$`, `_`, ZWNJ, ZWJ for
JS) are the lexer's: std does not add them, and says so in its comment.
`XID_*` (NFKC-closed) is not offered until asked for.

**Version.** `pub VERSION: Static`. Options: (a) pin 15.1.0, tsc's, so Trig's
baselines agree character for character, and bump by regenerating (a diff test
shows which ranges changed); (b) track the latest (16.0 today). Recommended
(a) for the first drop, then a bump per Rig release, always named in `VERSION`
and in `docs/STD.md`. A general std is allowed to be one release old; a lexer
accepting a character `tsc` rejects is a worse surprise.

**Tables: where they live.** Constant tables of structs are rejected today
(`proposal-modules-constants.md`, Feature B), but `[N]U32` of literals already
folds. Options:

- A. Generated `.rig` with `[N]U32` constants. Pure Rig, sanitizer-checked, but
  it waits on nothing for ints; large literal arrays are slow to type check
  (measure: ~2K numbers, fine) and the emitted Zig is the same.
- **B. Generated `std/unicode_tables.zig` behind `extern zig` (recommended).**
  The mechanism std.text and std.math use today. The generated file is data
  only; the lookup is 10 lines of Zig; the Rig API is final either way, so a
  move to A later is invisible.
- C. Derive the tables at build time from UCD: rejected; the build must not
  fetch or need Python (Nexus is the only build dependency).

The generator is checked in at `tools/gen-unicode.py` with the pinned
`UnicodeData`-derived files named in its header (`DerivedCoreProperties.txt`
for ID_*, `SpecialCasing.txt` and `CaseFolding.txt` in phase 3). It takes the
UCD directory as an argument and downloads nothing. A test regenerates into a
temp dir and diffs against the checked-in file (skipped when no UCD path is
given, run in the deep gate with `RIG_UCD=dir`).

**Size and speed.** Options:

- Range table with binary search (Go's model): ~1,340 ranges, 8 bytes each
  = ~11 KB; about 10 compares per non-ASCII lookup.
- **Two-level bitmap (recommended):** a 4352-entry `U8` stage-1 index over
  256-code-point blocks, plus unique 32-byte bit blocks; both properties share
  one index with 2 bits per code point. Estimate 8-12 KB total, two loads, no
  branches. The generator prints the true size; the estimate is not measured.
  Both forms need an ASCII fast path (`c < 128`: two compares), which serves
  nearly every call from a lexer.

If the two-level table turns out larger than 16 KB, fall back to ranges: the
API does not change.

## 3. UTF-16 and radix

```rig
use std.unicode
use std.text

sub main()
  print(unicode.is_high_surrogate(0xD83D), unicode.is_low_surrogate(0xDE00))
  print(unicode.surrogate_pair_to_code_point(0xD83D, 0xDE00) == 0x1F600)
  print(unicode.utf16_len(0x1F600), unicode.utf16_len(0xFFFF), unicode.utf16_len(0x61))
  print(text.parse_int("ff", 16)!, text.parse_int("-101", 2)!, text.parse_int("zz", 36)!)
  print(text.parse_int("12", 2) catch -1)
  print(text.format_int(255, 16), text.format_int(255, 16, upper: true), text.format_int(-8, 8))
```

```output
true true
true
2 1 1
255 -5 1295
-1
ff FF -10
```

- `is_high_surrogate(c)` is `0xD800 <= c < 0xDC00`; `is_low_surrogate(c)` is
  `0xDC00 <= c < 0xE000`. `surrogate_pair_to_code_point(hi, lo)` is
  `(hi - 0xD800) * 0x400 + (lo - 0xDC00) + 0x10000`, and panics when either is
  not in its range (a wrong pair is a caller bug, as `math.clamp(hi < lo)`).
  `utf16_len(c)` is 2 for `c >= 0x10000`, else 1 (a lone surrogate is one
  unit), and panics outside `0..=0x10FFFF`.
- `rune_at` never yields a surrogate (it gives U+FFFD, Go's contract), so
  these are for code that handles UTF-16 from elsewhere or Trig's own lone
  surrogate encoding. Their module is `std.unicode`, not `text`, because
  `text` is bytes, and code units are not bytes.
- **Radix.** `std.text` has base 10 only. Options: A. a default parameter,
  `parse_int(s, base: Int = 10)` (recommended; SYNTAX allows defaults, the call
  `parse_int(s)` is unchanged, same errors, no prefix, no `_`, bases 2 to 36,
  other bases panic); B. a new `parse_radix`. A leaves one name. Formatting is
  new: `format_int` returns an owned `String`, so its allocation is in its
  type. Lowercase by default (`upper: true` for tsc's printer). Unsigned
  values above `Int.max` are not covered; `parse_uint` waits for a consumer.
  Not in `std.math`: it is about text.

## 4. Edit distance

`text.edit_distance(a: ?String, b: ?String, !row: List[Int], max: Int = -1) -> Int`

Levenshtein over **runes** (an invalid byte is one rune, as `rune_at`), insert,
delete, substitute at cost 1. With `max >= 0` it stops early and returns
`max + 1` when the distance exceeds `max`, which is what suggestion code
wants. The caller supplies the scratch `row`, grown by the call: the loop that
compares one name with hundreds of candidates reuses it, and no allocation is
hidden. (An allocating one-shot would be `edit_distance(a, b)` returning an
`Int` while quietly calling the allocator; rejected by Rule 4's spirit.)

**Finding:** tsc's `GetSpellingSuggestion` does not use plain Levenshtein: a
substitution costs 0.1 when the two characters differ only in case and 2
otherwise, indels cost 1, distances are floats, and the bound is
`0.4 * len + 1`. That is a tuned heuristic, not a library function. Std offers
the plain one (Go has none, Rust's `strsim`, Python's `Levenshtein`, and
`difflib` are the models); Trig keeps its 40-line weighted loop. Option C:
`edit_distance` with a `Costs` obj. Rejected: the knobs exist for one caller.

```rig
use std.text

sub main()
  row: List[Int] = List()
  print(text.edit_distance("kitten", "sitting", !row), text.edit_distance("", "abc", !row))
  print(text.edit_distance("\u{e9}a", "ea", !row), text.edit_distance("kitten", "sitting", !row, max: 2))
```

```output
3 3
1 3
```

## 5. Full case mapping (phase 3; low priority)

`unicode.lower(s: ?String) -> String`, `unicode.upper(s)`, locale-free: simple
mappings from `UnicodeData`, special mappings from `SpecialCasing` (U+00DF to
`SS`, U+0130), and Final_Sigma (U+03A3 lowercases to U+03C2 at a word end,
needing Cased and Case_Ignorable) in `lower` only. ~1,400 entries each way,
~25 KB with the generator. Also `simple_fold(c)`, the case-fold orbit, which
`std.regex` `(?i)` needs for non-ASCII. It returns an owned `String`, so the
allocation shows.

**When:** after `std.regex` phase 1, or the first time Trig needs exact
`String.prototype.toLowerCase` (evaluator, language service). Until then
`text.to_lower(b: U8)` and ASCII keyword lowering cover tsc's 63 call sites,
nearly all of which lower file names and keywords. Do not build it speculatively.

## 6. Failing tests (all new, `test/behavior/std/`)

| File | Proves |
|---|---|
| `unicode_ids.rig` | the section 2 program; also all 128 ASCII values against Python's `str.isidentifier` minus `_` rules, a generated list |
| `unicode_ids_table.rig` | every start/continue boundary from the generator's ranges (first, last, first-1, last+1), 2 per range, generated |
| `unicode_surrogates.rig` | section 3 surrogates, plus the panic cases in `test/panic/` |
| `text_radix.rig` | sec 3 radix, overflow in base 2 (`ParseError.overflow`), `Int.min` round trip in 2, 8, 16, 36, bases 1 and 37 panic |
| `text_edit_distance.rig` | sec 4, empty strings, `max` early exit equal to the full answer clipped, reuse of `row` across calls |
| `test/cli/unicode_tables_fresh.sh` | the generator reproduces the checked-in file |
| docs | each program above as a ```` ```rig ```` with its output in `docs/STD.md` |

## 7. Effort

| Piece | Time |
|---|---|
| Generator, tables, id functions, VERSION, tests | 1.5 days |
| Surrogates | 0.25 day |
| Radix parse/format | 0.5 day |
| Edit distance | 0.5 day |
| Docs | 0.5 day |
| **Phases 1 and 2 total** | **about 3 days**, no soundness classifier touched: fast gate |
| Case mapping (phase 3) | 2 to 3 days (generator extension, Final_Sigma, differential test against Python and Go) |

## 8. Decisions for the owner

1. Unicode version: pin 15.1.0 for Trig parity (recommended), or the latest?
2. Tables as generated Zig behind `extern zig` now (recommended), or wait for
   constant tables and generate Rig?
3. Two-level bitmap (recommended) or range table with binary search?
4. `std.unicode` as a separate module (recommended) or fold everything into `std.text`?
5. Radix as the default parameter `parse_int(s, base: Int = 10)` (recommended) or `parse_radix`?
6. `format_int` returning an owned `String` with `upper:` (recommended).
7. `edit_distance` takes a caller scratch `!row` (recommended) or hides its allocation?
8. Edit distance counts runes (recommended) or bytes? Trig keeps its weighted variant itself?
9. `utf16_len` and the pair function panic on out-of-range input (recommended), or return a sentinel?
10. Case mapping: defer to phase 3 (recommended), or build with this round?
11. Offer `XID_*` and general categories (`\pL`) now? Recommended: no, only when regex phase 3 needs them.
