# The text API

Every public name in Rig's text modules, with its signature, in one
list: the owner's final API (2026-10-13). The design, the four units,
and the reasons are in [TEXT.md](TEXT.md); each module's full reference
is in [STD.md](STD.md). A name marked *(planned)* is decided and not
built yet: it names the round that builds it, and nothing here claims it
works until that round lands.

## Rules

1. **One kind of thing per module:** whole strings in `text`, one byte
   in `ascii`, one rune's properties in `unicode`; `utf8` and `utf16`
   are the encodings (decoding, encoding, checks, and conversions).
2. **The string comes first.** A byte position is `i`, a rune `r`, a
   UTF-16 code unit `u`, a char `c`, a count `n`. A converter between
   units names each side by its unit (`bytes`, `units`).
3. **The measuring words:** `len` is stored and free; `count` scans and
   names what it counts; `size` is the space one thing takes; `width` is
   screen columns.
4. **A `find…` may fail, so it returns `Int?`; an `…_end` always lands
   somewhere, so it returns `Int`** (`s.len` when the run reaches the
   end).
5. **"find" is the verb, "index" the noun, and "char" a grapheme.**
   Iterators are plural nouns. No sentinel values.

## text: whole strings

Every position is a byte index.

| Name | Status |
|---|---|
| `find(s, pat) -> Int?`, `find_last(s, pat) -> Int?` | built |
| `find_any[set](s, i) -> Int?` | *(planned: #186)* |
| `class_end(s, i, table, mask) -> Int` | *(planned: #186)* |
| `contains(s, pat)`, `starts_with(s, prefix)`, `ends_with(s, suffix)` | built |
| `count(s, pat) -> Int`: occurrences of `pat` | built |
| `compare(a, b)` | built |
| `trim`, `trim_start`, `trim_end` | built |
| `strip_prefix(s, prefix) -> (?String)?`, `strip_suffix(s, suffix) -> (?String)?` | built |
| `cut(s, sep) -> Cut?` | built |
| `split(s, sep) -> Parts` | built as `Split`; `Parts` *(planned: textapi2)* |
| `lines(s) -> Lines`, `words(s) -> Words` | built |
| `parse_int(s, base = 10) -> Int!`, `parse_float(s) -> Float!`, `parse_bool(s) -> Bool!` | built |
| `format_int(n, base = 10, upper = false) -> String` | built |
| `edit_distance(a, b, row, max: Int? = none) -> Int` | built with `max: Int = -1`; `Int?` *(planned: textapi2)* |

## text: chars

A char is a grapheme: what a reader sees as one character.

| Name | Status |
|---|---|
| `chars(s) -> Chars` | built |
| `char_count(s) -> Int` | built |
| `first_chars(s, n) -> ?String`, `last_chars(s, n) -> ?String` | built |
| `char_boundary(s, i) -> Int` | built |
| `width(s) -> Int`, `char_width(c) -> Int`: screen columns | *(planned: width round)* |

## ascii: one byte

| Name | Status |
|---|---|
| `is_digit(b)`, `is_alpha(b)`, `is_space(b)`, `to_upper(b)`, `to_lower(b)` | in `text` today; `ascii` *(planned: textapi2)* |

Whole-string ASCII checks are `utf8.is_ascii(s)` and `utf8.ascii_end(s, i)`.

## utf8: bytes and runes

| Name | Status |
|---|---|
| `rune_after(s, i) -> Decoded`, `rune_before(s, i) -> Decoded`; `Decoded(rune, size)` | built |
| `runes(s) -> Runes` | built |
| `rune_size(s, i) -> Int?` | built |
| `rune_count(s) -> Int` | built |
| `size(r) -> Int?` | built |
| `is_valid(s)`, `is_ascii(s)` | built |
| `ascii_end(s, i) -> Int` | built |
| `push_rune(!out, r)` | built |
| `REPLACEMENT`, `RUNE_SELF` | built |

## utf16: units and JavaScript positions

| Name | Status |
|---|---|
| `size(r) -> Int?` | built |
| `unit_count(s) -> Int` | built |
| `byte_index(s, units) -> Int` | built |
| `is_surrogate(u)` | built |
| `is_high_surrogate(u)`, `is_low_surrogate(u)` | built |
| `rune_from_pair(hi, lo) -> Int` (U+FFFD for an invalid pair) | built |
| `pair_from_rune(r) -> Pair`; `Pair(hi, lo)` | built |
| `positions(s) -> Positions`, a lookup table (not an iterator), with `.unit_index(bytes)` and `.byte_index(units)`, clamping as `byte_index` does | *(planned: positions round)* |

There is no module-level `unit_index(s, bytes)`: the one-off form is
`utf16.unit_count(s[..i])`.

## unicode: one rune's properties

| Name | Status |
|---|---|
| `is_space(r)` | built as `is_space_rune`; `is_space` *(planned: #186)* |
| `is_id_start(r)`, `is_id_continue(r)` | built |
| `VERSION` | built |

## slices

| Name | Status |
|---|---|
| `find(xs, x) -> Int?` | built as `index_of`; `find` *(planned: textapi2)* |
| `contains(xs, x)`, `reverse(xs)` | built |

## Not planned yet

Parked until a program needs them: `text.ByteSet`, a Two-Way
`find`/`count`, and more char fast paths. Recorded to fix when a user
appears: `find_last` for 1–4-byte patterns, `Split`'s per-part search
table, `edit_distance` decoding once, and the grapheme walk's double
probe.
