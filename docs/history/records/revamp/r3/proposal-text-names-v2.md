# Proposal v2: the words and names for measuring text

**DECIDED 2026-10-13: a char IS a grapheme, and nothing else.** The four words are byte, rune, unit, char. `text.char_count(s)` counts chars; `text.chars(s)` iterates them. Wherever this file says grapheme/`grapheme_count`/`graphemes`, read char/`char_count`/`chars`. ALL DECIDED 2026-10-13: `rune_after` kept; decoding returns `Decoded(rune, size)` (multiple results later may replace it); `push_rune` writes U+FFFD for an invalid rune (Go). Char tools: `text.char_count`, `text.chars`, `text.first_chars`, `text.last_chars`, `text.char_boundary`. Canonical doc: docs/TEXT.md (PR #165).

v1 (proposal-text-names.md) after four independent reviews (consistency,
accuracy against Go/Node/Python, real-code fit for Trig and std.json, and a
devil's advocate). Changes from v1 are marked **(changed)**.

## Vocabulary

- **byte**: a `U8`; what a String stores (UTF-8 by convention).
- **rune**: a Unicode **scalar value**, 0 to 0xD7FF or 0xE000 to 0x10FFFF
  **(changed: surrogates are not runes)**. 1-4 bytes in UTF-8, 1-2 units in
  UTF-16. A rune is an `Int`.
- **unit**: one UTF-16 code unit (2 bytes). Surrogates are units, never runes.
- **grapheme**: a UAX #29 extended grapheme cluster (what Swift's `count`
  counts). Depends on the Unicode version.
- Never "char".

## The three measuring words

| Word | Meaning | Spelling |
|---|---|---|
| `len` | how many elements a container stores (bytes for a String, elements for a List or array) | stored: a field on built-in types (`s.len`, `v.len`); `len()` on a user type that keeps one |
| `size` | how much space ONE thing takes, in the unit its module names | `r.size`, `utf8.size(r)`, `utf8.rune_size(s, i)`, `utf16.size(r)` |
| `count` | computed by scanning; **always names its unit** **(changed)** | `utf8.rune_count(s)`, `utf16.unit_count(s)`, `text.grapheme_count(s)` |

Rule: the word says what is measured; parentheses say it is computed.
**(changed)** No bare `count` for a measure: `text.count(s, pat)` already
counts occurrences of a pattern (std/text.rig:187), as Go's
`strings.Count` and Python's `str.count` do, and stays. The owner's
`s.sep_count(sep)` is not needed.

## std.utf8

| Name | Returns | Go |
|---|---|---|
| `rune_after(s, i) -> Decoded` | the rune starting at byte `i`; `Decoded(0xFFFD, 1)` if invalid, `Decoded(0xFFFD, 0)` at `s.len` | `DecodeRuneInString` (exact) |
| `rune_before(s, i) -> Decoded` | the rune ending at byte `i`; `(0xFFFD, 1)` if none, `(0xFFFD, 0)` at 0 | `DecodeLastRuneInString` (exact) |
| `runes(s)` | iterates **runes (`Int`)** **(changed)**; an invalid byte gives 0xFFFD | `for _, r := range s` |
| `rune_size(s, i) -> Int?` | bytes in the valid rune at `i`, or `none` | |
| `size(r) -> Int?` | bytes `r` needs, or `none` for a negative, a surrogate, or > 0x10FFFF **(changed: negatives)** | `RuneLen` |
| `rune_count(s) -> Int` | runes; each invalid byte counts as one | `RuneCountInString` (exact) |
| `is_valid(s) -> Bool` **(new)** | `s` is well-formed UTF-8 | `ValidString` |
| `is_ascii(s) -> Bool` | every byte < 0x80 | |
| `push_rune(!out, r)` | appends `r`; **writes U+FFFD for an invalid `r`, no panic** **(changed)** | `AppendRune` (exact) |
| `REPLACEMENT`, `RUNE_SELF` **(new)** | 0xFFFD; 0x80 (bytes below it are whole runes) | `RuneError`, `RuneSelf` |

`obj Decoded(rune: Int, size: Int)` **(changed from `Rune(code, size)`)**:
`size` is the bytes it took in the source, so `Decoded(0xFFFD, 1).size` is 1
while `utf8.size(0xFFFD)` is 3, as in Go.
`rune_end` **(dropped)**: std.json keeps its own scan (`T?` measured free;
`rune_size`'s cost was its extra checks, which std.json's caller already
did).

## std.utf16 (new module)

| Name | Returns | Go |
|---|---|---|
| `size(r) -> Int?` | units `r` needs (1 or 2), or `none` | `utf16.RuneLen` |
| `unit_count(s) -> Int` | UTF-16 units of `s`; each invalid byte counts as one (U+FFFD), as tsc-go's `core.UTF16Len` | (JS `length` on valid text) |
| `byte_index(s, units) -> Int` **(new)** | the byte offset `units` units into `s` (a unit inside a pair lands after the rune), the inverse of `unit_count` | tsc's position loop |
| `is_surrogate(u) -> Bool` | `0xD800 <= u < 0xE000` | `IsSurrogate` |
| `rune_from_pair(hi, lo) -> Int` | the rune, or U+FFFD if not a valid pair (no panic) | `DecodeRune` (exact) |
| `pair_from_rune(r) -> Pair` **(new)** | `Pair(hi, lo)`, or `Pair(0xFFFD, 0xFFFD)` if `r` needs no pair | `EncodeRune` (exact) |

Parameters that are units are `u`, `hi`, `lo`; runes are `r`. Replaces
std.unicode's `is_high_surrogate`, `is_low_surrogate`,
`surrogate_pair_to_code_point`, and `utf16_len` (#161).

## std.unicode (properties) and std.text

- std.unicode: `is_id_start(r)`, `is_id_continue(r)`, `is_space_rune(r)`,
  later case mapping. Every table states its UCD version (15.1).
- std.text: `text.count(s, pat)` unchanged; `text.grapheme_count(s)` later
  (UAX #29 tables, ~10-20 KB, Unicode-version dependent).

## Stated explicitly (was ambiguous)

- `i` outside `0..s.len` panics, as indexing does; `i` inside a rune reads
  that byte as invalid: `Decoded(0xFFFD, 1)`.
- Invalid bytes: one U+FFFD per byte in `runes`, `rune_count`,
  `unit_count` (Go's rule). Node's JS decoder replaces a maximal invalid
  subpart with one U+FFFD, so on invalid input `unit_count` matches tsc-go,
  not Node. A UTF-8 BOM is text to these functions; stripping it is the
  caller's (tsc's lexer does).

## Elsewhere (separate fixes)

- std.json's `doc.size()` returns a stored count: rename to `doc.len()`
  (json.rig session).
- SPEC examples `fun size(s) = s.len` (SPEC.md:617, 4525) and
  `fun count(?self) = self.lines.len` (SPEC.md:4579) teach the wrong
  words: rename.
- `count_ones()` (verb-first, Rust's name) is the deliberate exception;
  RIG-MANTRAS says so.

## Disagreements the owner decides

1. Bare `s.count()` = graphemes (owner, v1) vs `text.grapheme_count(s)`
   (three reviewers). v2 takes the reviewers' side.
2. `rune_after` (owner's cursor reading) vs `rune_at` (the devil's
   advocate: a Python reader takes `i` as naming a byte). v2 keeps
   `rune_after`.
3. `Decoded(rune, size)` vs keeping `Rune(code, size)`. v2 renames.
4. `push_rune` on an invalid rune: Go's U+FFFD (v2) vs panic (v1).

## Char tools (owner approved 2026-10-13)

Built with `char_count` on the UAX #29 tables, so char-correct code is as
short as byte code, and bytes stay the fast default:

| Name | Returns |
|---|---|
| `text.char_count(s) -> Int` | how many chars `s` holds |
| `text.chars(s)` | iterates each char as a whole `?String` slice of `s` |
| `text.first_chars(s, n) -> ?String` | the first `n` chars of `s` (all of `s` if it has fewer) |
| `text.last_chars(s, n) -> ?String` | the last `n` chars of `s` (all of `s` if it has fewer) |
| `text.char_boundary(s, i) -> Int` | the char boundary at or before byte `i` (`i` itself on a boundary); `0 <= i <= s.len` |

And a compiler hint: `s.length`, `s.chars()` used as a count, `s.size()`,
`s.char_count()` (until method syntax) point to `s.len` and
`text.char_count(s)`.
