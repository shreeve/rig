# Rig text API: the owner's final, consolidated (2026-10-13, via Trig)

## text: whole strings (positions are byte indexes)
- Search: `find(s, pat) -> Int?`, `find_last(s, pat) -> Int?`, `find_any[set](s, i) -> Int?`, `class_end(s, i, table, mask) -> Int`, `contains(s, pat)`, `starts_with`, `ends_with`, `count(s, pat)`, `compare(a, b)`.
- Shape: `trim`/`trim_start`/`trim_end`, `strip_prefix`/`strip_suffix -> (?String)?`, `cut(s, sep) -> Cut?`, `split(s, sep) -> Parts`, `lines -> Lines`, `words -> Words`.
- Convert: `parse_int(s, base = 10) -> Int!`, `parse_float -> Float!`, `parse_bool -> Bool!`, `format_int(n, base = 10, upper = false) -> String`, `edit_distance(a, b, row, max: Int? = none) -> Int`.

## text: chars (a char is a grapheme)
`chars -> Chars`, `char_count`, `first_chars(s, n)`, `last_chars(s, n)`, `char_boundary(s, i)`, `width(s)`, `char_width(c)`.

## ascii: one byte
`is_digit(b)`, `is_alpha(b)`, `is_space(b)`, `to_upper(b)`, `to_lower(b)`; a pointer line to `utf8.is_ascii` / `utf8.ascii_end` for whole strings.

## utf8: bytes <-> runes
`rune_after(s, i)`, `rune_before(s, i) -> Decoded(rune, size)`, `runes -> Runes`, `rune_size(s, i) -> Int?`, `rune_count(s)`, `size(r) -> Int?`, `is_valid(s)`, `is_ascii(s)`, `ascii_end(s, i) -> Int`, `push_rune(!out, r)`, `REPLACEMENT`, `RUNE_SELF`.

## utf16: units <-> runes, JS positions
`size(r) -> Int?`, `unit_count(s)`, `byte_index(s, units)`, `is_surrogate(u)`, `is_high_surrogate(u)`, `is_low_surrogate(u)`, `rune_from_pair(hi, lo)` (U+FFFD on invalid), `pair_from_rune(r) -> Pair(hi, lo)`, `positions(s) -> Positions` with `.unit_index(bytes)` / `.byte_index(units)` (clamping as `byte_index`).

## unicode: one rune's properties
`is_space(r)`, `is_id_start(r)`, `is_id_continue(r)`, `VERSION`.

## slices
`find(xs, x) -> Int?`, `contains(xs, x)`, `reverse(xs)`.

## Rules
1. One kind per module: strings in text, a byte in ascii, a rune in unicode; utf8/utf16 are the encodings (decoding, encoding, checks, conversions).
2. String first. A byte position is `i`; a rune `r`; a code unit `u`; a char `c`; a count `n`. Unit converters name each side by its unit (`bytes`, `units`).
3. `len` is stored and free; `count` scans and names what it counts; `size` is the space one thing takes; `width` is screen columns.
4. A `find...` may fail, so it returns `Int?`; an `..._end` always lands somewhere, so it returns `Int`.
5. "find" is the verb, "index" the noun, "char" a grapheme; iterators are plural nouns; no sentinels.

Parked (no user): ByteSet, Two-Way find/count, more char fast paths. When a user appears: find_last 1-4-byte, Split per-part BMH, edit_distance decode-once, grapheme walk double probe.

Docs: strip_prefix(s, prefix) / strip_suffix(s, suffix); `Positions` is a lookup table, not an iterator; the one-off byte->unit conversion is `utf16.unit_count(s[..i])` (no module-level `utf16.unit_index`).
