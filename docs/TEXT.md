# Text in Rig

How Rig stores, measures, and walks text: four units, each with one
name; one rule for how a measure is spelled; and the standard library
that follows from them. This page is the design. [SPEC,
Strings](../SPEC.md#strings) states what the language does, and
[STD](STD.md) lists each module's functions, and [TEXT-API](TEXT-API.md)
lists every name of the text API in one place, built and planned.

**Status.** Every layer below is built: a `String` holds UTF-8 bytes,
and `s.len`, `s[i]`, slicing, and `std.text` work on them; `std.utf8`,
`std.utf16`, and `std.unicode` read and write runes and units; and
`std.text`'s char tools read chars, on the Unicode grapheme tables.

## Four units, four words

| Word | What it is | Its Rig value |
|---|---|---|
| **byte** | 8 bits: what a `String` stores (UTF-8, by convention) | a `U8` |
| **rune** | one Unicode scalar value: a code point that is not a surrogate, 0 to 0xD7FF and 0xE000 to 0x10FFFF | an `Int` |
| **unit** | one UTF-16 code unit, what JavaScript's string length counts | an `Int` |
| **char** | what a reader sees as one character: a Unicode extended grapheme cluster | a `?String`, a short piece of the text |

**A char is a grapheme, and nothing else.** It is one character as a
person counts it, however many bytes it takes. Other languages spend the
word "char" on a byte (C, C++), a UTF-16 unit (Java, C#), or a code
point (Rust); Rig gives each of those its own word, so "char" can mean
what everyone means by "character".

A byte, a unit, and a rune are numbers. A char is not: one char can be
several runes (a letter and its accent, an emoji and its skin tone, a
family of five runes joined into one picture), so it is a piece of text,
a `?String` that views its bytes in the string it came from.

Each of these is one char:

| Text | Written as | Bytes | Runes | Units | Chars |
|---|---|---:|---:|---:|---:|
| `a` | U+0061 | 1 | 1 | 1 | 1 |
| `é` | U+00E9, one rune | 2 | 1 | 1 | 1 |
| `é` | `e` U+0065, then a combining acute U+0301 | 3 | 2 | 2 | 1 |
| `👋🏽` | waving hand U+1F44B, then skin tone U+1F3FD | 8 | 2 | 4 | 1 |
| `👨‍👩‍👧` | man, zero-width joiner, woman, joiner, girl | 18 | 5 | 8 | 1 |

The two `é`s look the same and are one char each, but take 2 and 3
bytes.

## Three measuring words

| Word | Means | Spelled | Cost |
|---|---|---|---|
| `len` | how many elements a container stores: bytes for a String, elements for a List | a field: `s.len`, `v.len` | stored, instant |
| `size` | how much space one thing takes, in its module's unit | `d.size`, `utf8.size(r)`, `utf8.rune_size(s, i)`, `utf16.size(r)` | instant |
| `count` | found by scanning; always names its unit | a call: `utf8.rune_count(s)`, `utf16.unit_count(s)`, `text.char_count(s)` | scans the text |

A field is known; a call does work. So bytes, which a string stores, are
`s.len`, and there is no `byte_count`; runes, units, and chars must be
counted, so each count is a call that says what it counts.
`text.count(s, pat)` is not a measure: it counts occurrences of a
pattern, as Go's `strings.Count` and Python's `str.count` do.

For `"👨‍👩‍👧"`:

```rig
use std.text
use std.utf8
use std.utf16

sub main()
  s = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}"
  print(s.len, text.char_count(s), utf8.rune_count(s), utf16.unit_count(s))
```

```output
18 1 5 8
```

## Bytes: the default

Every string operation works on bytes unless its name says otherwise:
`s.len`, `s[i]` (a `U8`), `s[a..b]`, `for b in s`, and
`s.read[U32, .little](i)`. They are what parsers, protocols, and
std.json need, they cost a bounds check and no more, and a `?String`
does not promise valid UTF-8, so a byte is the one unit that always
means what it says. A byte slice can cut through a rune or a char; when
that is not what you mean, use the char tools below, which say "char" in
their names.

```rig
sub main()
  s = "\u{e9}"
  print(s.len, s[0], s[1])
  print("e\u{301}".len, "\u{1f44b}\u{1f3fd}".len)
```

```output
2 195 169
3 8
```

A scanner that stops at a few bytes, a lexer at the end of a string or
a comment, asks `text.find_any[set](s, i)`: the first index at or after
`i` whose byte is one of `set`'s, or `none` when there is none, as
`find` gives; a scanner that runs to the end writes `?? s.len`. The set
is a compile-time string, so each set is its own instance, its bytes
constants in the code; it tests 16 bytes at a time, with one compare
for each byte of the set. An empty set holds no byte, so the result is
`none`, and an `i` outside `0..s.len` panics, as indexing does.

```rig
use std.text

STOPS = "\"\\\n"

sub main()
  s = "say \"hi\" \\ then"
  i = text.find_any[STOPS](s, 0) ?? s.len
  print(i, text.find_any[STOPS](s, i + 1) ?? s.len, text.find_any["#"](s, 0) ?? s.len, s.len)
  if text.find_any["!?"](s, 0) as k
    print("found at", k)
  else
    print("no ! or ?")
```

```output
4 7 15 15
no ! or ?
```

A run of bytes of one kind, an identifier or a number, ends where
`text.class_end(s, i, table, mask)` says: the first index at or after
`i` whose byte's class, `table[b]`, has no bit of `mask`, or `s.len`.
The caller's 256-entry table gives each byte its class bits, so one
table serves several kinds, and any set of bytes costs one load and one
test per byte. An `i` outside `0..s.len` panics, as indexing does.

```rig
use std.text

WORD: U8 = 1
DIGIT: U8 = 2

fun classes() -> [256]U8
  t: [256]U8 = [256 of 0]
  for b in 0..256
    t[b] |= WORD if (b >= 0x61 and b <= 0x7A) or b == 0x5F
    t[b] |= WORD | DIGIT if b >= 0x30 and b <= 0x39
  t

sub main()
  t = classes()
  s = "count_2 = 42;"
  print(text.class_end(s, 0, t, WORD), text.class_end(s, 10, t, DIGIT), text.class_end(s, 0, t, DIGIT))
```

```output
7 12 0
```

## Runes: `std.utf8`

Decoding and encoding UTF-8. Each function with a Go twin in
`unicode/utf8` matches it on every input, valid or not, so a Go port is
a rename.

| Rig | Returns | Go |
|---|---|---|
| `utf8.rune_after(s, i) -> Decoded` | the rune that starts at byte `i` | `DecodeRuneInString(s[i:])` |
| `utf8.rune_before(s, i) -> Decoded` | the rune that ends at byte `i` | `DecodeLastRuneInString(s[:i])` |
| `utf8.runes(s)` | each rune of `s`, a plain `Int`, in order | `for _, r := range s` |
| `utf8.rune_size(s, i) -> Int?` | the bytes of the valid rune at `i`, or `none` | |
| `utf8.size(r) -> Int?` | the bytes `r` takes in UTF-8, or `none` if `r` is not a rune | `RuneLen` |
| `utf8.rune_count(s) -> Int` | the runes in `s` | `RuneCountInString` |
| `utf8.is_valid(s) -> Bool` | whether `s` is well-formed UTF-8 | `ValidString` |
| `utf8.is_ascii(s) -> Bool` | whether every byte is below 0x80 | |
| `utf8.ascii_end(s, i) -> Int` | the first byte at or after `i` that is 0x80 or more, or `s.len`: where the run of ASCII from `i` ends | |
| `utf8.push_rune(!out, r)` | appends `r` as UTF-8 | `AppendRune` |
| `utf8.REPLACEMENT`, `utf8.RUNE_SELF` | 0xFFFD; 0x80, below which a byte is a whole rune | `RuneError`, `RuneSelf` |

`obj Decoded(rune: Int, size: Int)`: the rune, and the bytes it took
where it was read.

Think of `i` as a cursor between bytes: `rune_after(s, i)` reads the
rune just after it, `rune_before(s, i)` the rune just before it, and the
cursor moves by `d.size`:

```rig
use std.utf8

sub main()
  s = "h\u{e9}"
  d = utf8.rune_after(s, 1)
  print(d.rune, d.size)
  b = utf8.rune_before(s, s.len)
  print(b.rune, b.size)
```

```output
233 2
233 2
```

**Invalid input never stops a reader.** A byte that starts no valid
sequence reads as `Decoded(0xFFFD, 1)`, so a loop moves past one bad byte
at a time; reading at the end (`rune_after` at `s.len`, `rune_before` at
0) gives `Decoded(0xFFFD, 0)`. `runes` and `rune_count` count each such
byte as one rune. `push_rune` writes U+FFFD for a value that is not a
rune (a surrogate, a negative, or over 0x10FFFF). A byte index outside
`0..s.len` panics, as indexing does. All of this is Go's behavior.

## Units: `std.utf16`

UTF-16, for code that must agree with JavaScript and the languages built
on it: a TypeScript checker's positions and columns are UTF-16 units.

| Rig | Returns | Go |
|---|---|---|
| `utf16.size(r) -> Int?` | the units `r` takes (1 or 2), or `none` if `r` is not a rune | `utf16.RuneLen` |
| `utf16.unit_count(s) -> Int` | the UTF-16 units of the UTF-8 text `s`: JavaScript's `length` of the same text | |
| `utf16.byte_index(s, units) -> Int` | the byte where `units` units into `s` falls (a unit inside a pair lands after its rune), clamped to `0..s.len` | |
| `utf16.is_surrogate(u) -> Bool` | whether `0xD800 <= u < 0xE000` | `utf16.IsSurrogate` |
| `utf16.is_high_surrogate(u) -> Bool` | whether `0xD800 <= u < 0xDC00`, the first unit of a pair | |
| `utf16.is_low_surrogate(u) -> Bool` | whether `0xDC00 <= u < 0xE000`, the second unit of a pair | |
| `utf16.rune_from_pair(hi, lo) -> Int` | the rune a surrogate pair encodes, or U+FFFD if it is not one | `utf16.DecodeRune` |
| `utf16.pair_from_rune(r) -> Pair` | `Pair(hi, lo)`, or `Pair(0xFFFD, 0xFFFD)` if `r` needs no pair | `utf16.EncodeRune` |

Surrogates are units, never runes, so their parameters are named `u`,
`hi`, and `lo`. On invalid UTF-8, `unit_count` counts each bad byte as
one unit (U+FFFD), as Go does; a JavaScript decoder may merge a run of
bad bytes into one U+FFFD.

`byte_index` turns a JavaScript position back into a byte, and clamps:
a count of 0 or less gives 0, a count at or past `unit_count(s)` gives
`s.len`, so a stale or edited position never panics, and a count inside
a pair gives the byte after its rune:

```rig
use std.utf16

sub main()
  s = "a\u{1f600}b"
  print(s.len, utf16.unit_count(s))
  print(utf16.byte_index(s, -1), utf16.byte_index(s, 1), utf16.byte_index(s, 2), utf16.byte_index(s, 3), utf16.byte_index(s, 9))
  p = utf16.pair_from_rune(0x1f600)
  print(p.hi, p.lo, utf16.rune_from_pair(p.hi, p.lo))
```

```output
6 4
0 1 5 5 6
55357 56832 128512
```

## Rune properties: `std.unicode`

Facts about one rune, from the Unicode Character Database 15.1: whether
it may start or continue an identifier (`unicode.is_id_start(r)`,
`unicode.is_id_continue(r)`, UAX #31), and whether it is whitespace
(`unicode.is_space(r)`). Every table names its Unicode version.

```rig
use std.unicode

sub main()
  print(unicode.VERSION, unicode.is_id_start(0x4e2d), unicode.is_id_start(0x30), unicode.is_id_continue(0x30))
  print(unicode.is_space(0x3000), unicode.is_space(0xfeff))
```

```output
15.1.0 true false true
true false
```

## Chars: `std.text`

What a reader sees, by the rules of Unicode's text segmentation (UAX
#29), so char-correct code is one call, and its name says "char":

| Rig | Returns |
|---|---|
| `text.char_count(s) -> Int` | how many chars `s` holds |
| `text.chars(s)` | each char of `s`, in order, as a `?String` slice of `s` |
| `text.first_chars(s, n) -> ?String` | the first `n` chars of `s`, or all of `s` if it has fewer |
| `text.last_chars(s, n) -> ?String` | the last `n` chars of `s`, or all of `s` if it has fewer |
| `text.char_boundary(s, i) -> Int` | the char boundary at or before byte `i` |
| `text.char_width(c) -> Int` *(planned)* | the terminal columns one char `c` takes, 0, 1, or 2: by its East Asian Width (UAX #11), 2 for an emoji, 0 for a combining mark or a zero-width char |
| `text.width(s) -> Int` *(planned)* | the terminal columns `s` takes: `char_width` summed over its chars |

```rig
use std.text
use std.utf8

sub main()
  for c in text.chars("a\u{1f44b}\u{1f3fd}")
    print(c, c.len, utf8.rune_count(c))
  print(text.first_chars("h\u{e9}llo", 2))
```

```output
a 1 1
👋🏽 8 2
hé
```

```rig
use std.text

sub main()
  s = "e\u{301}\u{1f44b}\u{1f3fd}\r\n\u{1f1eb}\u{1f1f7}"
  print(s.len, text.char_count(s), text.last_chars(s, 1), text.char_boundary(s, 2))
```

```output
21 4 🇫🇷 0
```

**Invalid UTF-8 never stops a char tool.** Text that is not UTF-8 is
read as `std.utf8` reads it, which is Go's way: each byte that starts no
well-formed sequence is one rune, U+FFFD, of one byte, and a char like
any other (a combining mark after it joins it). So every byte is in
exactly one char, and the chars of `s` always tile it: their sizes add
up to `s.len`. A byte index outside `0..s.len`, or a negative count of
chars, panics.

Width is measured per char, never per rune: a family emoji is five
runes but one char two columns wide. An East Asian Ambiguous char counts
as 1, and a tab is not measured (it depends on where it lands). There is
no `rune_width`, `unit_width`, or `byte_width`: bytes and units are not
drawn, and summing per-rune widths is wrong for any char of several
runes.

`first_chars` is how to shorten text for a reader (a preview, a
280-character post); `s[0..n]` is how to take `n` bytes.
`char_boundary` is how to cut at a byte limit without breaking a char:
`s[0..text.char_boundary(s, 4096)]`. Each scans the text once; there is
no char-indexed substring, because finding the 500th char means
scanning from the start, and a loop of such calls would be quadratic. A
char boundary can move when Unicode adds a rule (as 15.1 did for Indic
scripts), so a char count depends on the Unicode version Rig ships.

## Choosing a unit

| To | Use |
|---|---|
| store, index, slice, parse, or send text | bytes: `s.len`, `s[i]`, `s[a..b]` |
| decode, encode, or check UTF-8 | runes: `std.utf8` |
| ask what a rune is (identifier, white space) | rune properties: `std.unicode` |
| agree with JavaScript positions | units: `std.utf16` |
| count, shorten, or walk what a reader sees | chars: `text.char_count`, `text.first_chars`, `text.chars` |

## Why it is built this way

**Bytes are stored; chars are read.** A String stores UTF-8: compact for
code and English, the same bytes a file or a socket holds, and stable.
Characters cannot be the storage unit: a char is 1 byte or 25, and
Unicode refines where one ends, so a string stored as chars would change
length when Rig's Unicode tables did. So a String is bytes, and chars are
the named way to read it.

**UTF-16 is history, not design.** Unicode 1.0 (1991) promised that 16
bits would hold every character, so systems built then (Windows NT,
Java, JavaScript, and later C#) made a 16-bit unit their "character".
Unicode outgrew 16 bits in 1996, and surrogate pairs were added: most
emoji take two units, so `"😀".length` is 2 in JavaScript. UTF-16 is
neither what the machine stores nor what a person sees, and Rig gives it
a module of its own for the code that must agree with it.

**A cost is visible.** A field is stored, and a call scans; every
measure that scans says so with parentheses and names its unit.

**One word, one meaning.** No word in this page means two things, and
nothing has two names.

## How other languages compare

| Language | Its everyday length counts | Its "char" is | Counting what a reader sees |
|---|---|---|---|
| Python | code points (`len`) | no char type | not in the standard library |
| JavaScript, TypeScript | UTF-16 units (`.length`) | no char type | `Intl.Segmenter` |
| Java, Kotlin | UTF-16 units | a UTF-16 unit | `BreakIterator` |
| C# | UTF-16 units (`Length`) | a UTF-16 unit | `StringInfo.LengthInTextElements` |
| C, C++ | bytes | a byte | not in the standard library |
| Go | bytes (`len`) | none; a `rune` is a code point | not in the standard library |
| Rust | bytes (`len()`) | a code point | not in the standard library |
| Zig | bytes (`.len`) | none (`u8`, `u21`) | not in the standard library |
| Ruby | code points (`length`) | none | `grapheme_clusters.size` |
| Swift | graphemes (`count`, which scans) | a grapheme (`Character`) | `count` |
| Rig | bytes, stored (`s.len`) | a grapheme (`char`) | `text.char_count(s)` |

Swift is the one language whose character means what Rig's char means;
it makes graphemes the default view, where Rig keeps bytes as the
default and makes chars the named one. Of the systems languages (C, C++,
Go, Rust, Zig), Rig is the one with chars in its standard library.
