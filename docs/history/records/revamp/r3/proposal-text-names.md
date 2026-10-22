# Proposal: the words and names for measuring text in Rig

Status: about to be agreed by the owner (2026-10-13). Reviewers stress-test
it before he says yes.

## Vocabulary (settled)

- **byte**: 8 bits, a `U8`. What a `String` stores (UTF-8 by convention).
- **rune**: one Unicode code point, a character's number, 0 to 0x10FFFF.
  1-4 bytes in UTF-8, 1-2 units in UTF-16.
- **unit**: one UTF-16 code unit, 2 bytes. JavaScript's string length
  counts these.
- **grapheme**: what a reader sees as one character (UAX #29 extended
  grapheme cluster); 1 or more runes.
- Never "char".

## The three measuring words

| Word | Meaning | Cost | Spelling | Examples |
|---|---|---|---|---|
| `len` | how many units the container stores: bytes for a String, elements for a List or array | stored, instant | a field, no parentheses | `s.len`, `v.len` |
| `size` | how much space ONE thing takes | instant | a field or a function of one thing | `Rune.size`, `utf8.rune_size(s, i)`, `utf8.size(r)`, `utf16.size(r)` |
| `count` | computed by scanning | scans | a call, with parentheses | `s.count()` (graphemes), `utf8.rune_count(s)`, `utf16.unit_count(s)`, `s.sep_count(sep)` |

Rule for count: a bare `count()` on a string counts graphemes, Swift-style
(what a reader sees). Any other count names its unit.

## Modules and functions

### std.utf8 (encoding to and from UTF-8 bytes)

| Name | Signature | Returns | Go |
|---|---|---|---|
| `rune_after` | `(s: ?String, i: Int) -> Rune` | the rune starting at byte `i`; `Rune(0xFFFD, 1)` for invalid or truncated bytes, `Rune(0xFFFD, 0)` at `i == s.len` | `DecodeRuneInString(s[i:])` |
| `rune_before` | `(s: ?String, i: Int) -> Rune` | the rune ending at byte `i`; `Rune(0xFFFD, 1)` if none valid ends there, `Rune(0xFFFD, 0)` at `i == 0` | `DecodeLastRuneInString(s[:i])` |
| `runes` | `(s: ?String) -> Runes` | iterates `Rune`s: `for r in utf8.runes(s)` | `for _, r := range s` |
| `rune_size` | `(s: ?String, i: Int) -> Int?` | bytes in the valid rune at `i` (1-4), or `none` if invalid | (`DecodeRune` width, with validity) |
| `size` | `(r: Int) -> Int?` | bytes `r` needs in UTF-8 (1-4), or `none` for a surrogate or > 0x10FFFF | `RuneLen` (Go returns -1) |
| `rune_count` | `(s: ?String) -> Int` | runes in `s` (an invalid byte counts as one) | `RuneCountInString` |
| `is_ascii` | `(s: ?String) -> Bool` | every byte < 0x80 | (none) |
| `push_rune` | `(out: !String, r: Int)` | appends `r` as UTF-8; panics on a surrogate or > 0x10FFFF | `AppendRune` |
| `rune_end` | `(s: ?String, i: Int) -> Int?` | proposed zero-cost scanner helper: where the valid rune at a non-ASCII lead byte `i` ends, or `none` | (std.json's `utf8_end`) |

`obj Rune(code: Int, size: Int)`. Rune parameters are named `r`.

### std.utf16 (proposed new module: UTF-16 units)

| Name | Signature | Returns | Go / JS |
|---|---|---|---|
| `size` | `(r: Int) -> Int?` | units `r` needs (1 or 2), or `none` if not encodable | Go `utf16.RuneLen` |
| `unit_count` | `(s: ?String) -> Int` | UTF-16 units of the UTF-8 text `s` | JS `s.length` |
| `is_surrogate` | `(r: Int) -> Bool` | `0xD800 <= r < 0xE000` | Go `utf16.IsSurrogate` |
| `rune_from_pair` | `(hi: Int, lo: Int) -> Int` | the rune a surrogate pair encodes, or U+FFFD if not a valid pair (no panic) | Go `utf16.DecodeRune` |

Today these live in std.unicode (#161) as `is_high_surrogate`,
`is_low_surrogate`, `surrogate_pair_to_code_point` (panics on an invalid
pair) and `utf16_len(c)`; they would move here and be renamed.

### std.unicode (properties only)

Identifier classes (`is_id_start(r)`, `is_id_continue(r)`, UCD 15.1),
whitespace (`is_space_rune(r)`), later case mapping. Grapheme breaking
(UAX #29) for `s.count()` comes later.

### On String / std.text

- `s.len`: bytes, stored.
- `s.count()`: graphemes (later; needs UAX #29 tables).
- `s.sep_count(sep)`: occurrences of a separator (owner's choice, so bare
  `count` stays free).

## Worked example

For `s = "h😀"` (bytes 68 F0 9F 98 80):

| Expression | Answer | Counts |
|---|---|---|
| `s.len` | 5 | bytes, stored |
| `s.count()` | 2 | graphemes |
| `utf8.rune_count(s)` | 2 | runes |
| `utf16.unit_count(s)` | 3 | UTF-16 units (JS `length`) |
| `utf8.size(128512)` | 4 | bytes for one rune |
| `utf16.size(128512)` | 2 | units for one rune |
| `utf8.rune_after(s, 1)` | `Rune(code: 128512, size: 4)` | |

## Open, undecided

`width` vs `display_width` (terminal columns), `is_empty()`.

## Constraints

- Rig's naming rules (docs/RIG-MANTRAS.md on branch `mantras`, PR #164):
  actions are verbs; queries name their answer; a test reads as a
  question; avoid words other languages disagree on; the name says which
  end and which unit; say rune, never char.
- Same speed or faster than the code it replaces (Trig's, std.json's).
- Trig ports Go's utf8/utf16/unicode packages and tsc (JS positions are
  UTF-16 units). Go ports should be mechanical.
- `T?` in place of a -1 sentinel measured free in std.json's hot loop.
