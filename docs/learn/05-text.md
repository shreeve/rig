# Text done right: bytes stored, characters read

Here is one character, a family of three, in Python:

```python
s = "👨‍👩‍👧"
print(len(s))   # 5
```

Python says 5. JavaScript's `s.length` says 8, Rust's `s.len()` says 18,
and Swift's `s.count` says 1. Nobody is wrong. Each language counted a
different thing and gave it the same name, "length". Python counted code
points, JavaScript UTF-16 units, Rust bytes, and Swift what a reader
sees. A bug follows the day a program counts one thing and slices by
another: a name cut in half in a database column, a cursor that lands
inside an emoji, a table that does not line up.

Rig gives each of the four things its own word, and makes each
measure say which one it takes. This chapter measures that one family
four ways, then uses the words: to own, view, and build text, to cut
it safely, to search and split it, and to line it up on a terminal.

Every program here runs with `bin/rig run FILE.rig`.

## One family, four numbers

The family is three people joined by two invisible joiners, so it is
five Unicode code points. Here is each count, with its unit in the call:

```rig
use std.text
use std.utf8
use std.utf16

sub main()
  family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}"
  print(family)
  print("bytes", family.len)
  print("runes", utf8.rune_count(family))
  print("units", utf16.unit_count(family))
  print("chars", text.char_count(family))
```

```output
👨‍👩‍👧
bytes 18
runes 5
units 8
chars 1
```

`\u{...}` writes a code point in a string. Each number is one of four
**units**, and each unit has one word:

| Unit | What it is | Where you meet it | Rig value |
|---|---|---|---|
| **byte** | 8 bits: what a `String` stores, as UTF-8 | files, sockets, `len` in Rust and Go | `U8` |
| **rune** | one Unicode code point (a scalar value) | Python's `len`, Rust's `char` | `Int` |
| **unit** | one UTF-16 code unit | JavaScript's `length`, Java, C# | `Int` |
| **char** | one character as a reader counts it | Swift's `Character` | a piece of text |

A **char** is a grapheme: a letter with its accent, an emoji with its
skin tone, a family. Other languages spend the word "char" on a byte, a
UTF-16 unit, or a code point. Rig spends it on what everyone means by
"character", and uses the other three words for the other three things.

## A field is known, a call does work

The four numbers have two spellings. Bytes are `family.len`, a field.
Runes, units, and chars are calls, and each names its unit. The
difference is cost. A `String` stores its length in bytes, so `len` is
instant. Nothing stores the other counts, so each one scans the text.
A call tells you that, and the compiler holds the line:

```rig reject
sub main()
  s = "abc"
  print(s.len())
```

```error
no method `len` on type `Static`; `len` is a field: write `s.len`
```

There is a third measuring word, `size`, for how much space one thing
takes: `utf8.size(r)` is the bytes a rune needs. So `len` is a stored
count of elements, `count` is found by scanning, and `size` is the
space of one thing. No word means two things.

## Text that owns, views, and lasts

Text has three types. A `String` **owns** its bytes on the heap and
frees them when it drops. A `?String` is a **view** of bytes someone
else owns. A `Static` is text that lives for the whole program: a
string literal is one.

```rig
use std.text

fun shout(s: ?String) -> String
  out = String()
  for b in s
    !out.push(text.to_upper(b))
  out

sub main()
  name = String("ada")
  !name.add(" lovelace", 1815)
  loud = shout(name)
  tag = "x"
  print(name, loud, tag)
  t = String("n=", 42, " ok=", true)
  print(t, t.len)
```

```output
ada lovelace1815 ADA LOVELACE1815 x
n=42 ok=true 12
```

`String(a, b, ...)` builds a String from any values, written as `print`
writes them, with no separators. `!name.add(...)` appends the same way,
and the `!` marks the change, as it does everywhere. `!out.push(b)`
appends one byte. `shout` takes a `?String`, so it reads `name` without
copying it, and a literal or a `String` both fit. It returns a `String`
because it built text of its own, and the owner of the result frees it.

You may have noticed what is missing. Rig has no `+` on text, and no
string interpolation:

```rig reject
sub main()
  a = "foo"
  b = "bar"
  print(a + b)
```

```error
Rig has no `+` on text: build it with `String(a, b)` or `!t.add(...)`
```

A `+` that allocates reads like arithmetic and hides a cost, which
grows quadratically when it sits in a loop. `String(a, b)` and `!t.add` allocate in
sight, and the String that results has an owner.

A view follows the rules from the chapter on ownership. It carries a
loan on the String it came from, so that String cannot change while the
view lives:

```rig reject
sub main()
  name = String("Ada")
  first = ?name[..1]
  !name.add(" Lovelace")
  print(first)
```

```error
cannot lend `name` to write while a read loan is live
```

A `Static` carries no loan, because the program never frees its bytes.
That is why it can go where views cannot, in an object's field that
outlives the call. The compiler will not turn a view into a `Static`,
since a view may point into a String:

```rig reject
use std.text

obj Tag
  label: Static

sub main()
  name = String("Ada")
  u = Tag(label: text.trim(?name))
  print(u.label)
```

```error
type mismatch: expected `Static`, got `?String`
```

Where text is only read, declare `?String`, which takes a `Static` too.

## Bytes are the default

Every operation on text counts bytes unless its name says otherwise:
`s.len`, `s[i]` (a `U8`), `s[a..b]`, and `for b in s`. They cost a
bounds check and nothing more, and a byte is the one unit that always
means what it says, since a `?String` does not promise valid UTF-8.
Parsers, protocols, and file formats work in bytes.

The price is that a byte slice can cut through a character. Here is a
preview of a post, cut at three bytes:

```rig
use std.text
use std.utf8

sub main()
  post = "na\u{ef}ve caf\u{e9}"
  cut = post[..3]
  print(post.len, cut.len, utf8.is_valid(cut))
  safe = post[..text.char_boundary(post, 3)]
  print(safe, safe.len, utf8.is_valid(safe))
  print(text.first_chars(post, 3), text.char_count(post))
```

```output
12 3 false
na 2 true
naï 10
```

The `ï` takes two bytes, and `post[..3]` kept one of them, so `cut` is
not valid UTF-8. `text.char_boundary(post, 3)` moves back to the start
of the char that byte 3 is inside, here 2, so `safe` ends cleanly.
`text.first_chars(post, 3)` takes three chars, not bytes. Use
`char_boundary` to cut at a byte limit, such as a 4,096-byte column,
and `first_chars` to shorten text for a reader.

## Chars: what a reader sees

The char tools follow Unicode's rules for where one character ends,
which are in UAX #29. `text.chars(s)` walks them, and each char is a
`?String` viewing its bytes in `s`, so it has a `len` like any text:

```rig
use std.text
use std.utf8

sub main()
  word = "cafe\u{301}-\u{1f44b}\u{1f3fd}"
  print(word, word.len, utf8.rune_count(word), text.char_count(word))
  for c in text.chars(word)
    print(c, c.len)
  print(text.first_chars(word, 4), text.last_chars(word, 1))
```

```output
café-👋🏽 15 8 6
c 1
a 1
f 1
é 3
- 1
👋🏽 8
café 👋🏽
```

The `é` is an `e` and a combining accent: two runes, three bytes, one
char. The waving hand and its skin tone are two runes and eight bytes,
also one char. A char can be one byte or twenty-five.

There is no `text.char_at(s, 500)`. Finding the 500th char means
scanning from the start, and a loop of such calls would be quadratic.
The tools read from the start (`chars`, `char_count`, `first_chars`),
or back from the end (`last_chars`, `char_boundary`), and each makes one
pass.

Two strings can look the same and still not be equal:

```rig
use std.text

sub main()
  same = "\u{e9}" == "e\u{301}"
  print(same, text.char_count("\u{e9}"), text.char_count("e\u{301}"))
```

```output
false 1 1
```

`==` compares bytes, and these two spellings of `é` are different
bytes. Both are one char. A byte compare is the fast answer, and a
program that needs the reader's answer must normalize first (see "What
is not there yet").

A String that is not UTF-8 never stops a char tool. Each byte that
starts no valid sequence is one rune, U+FFFD, and one char of its own,
as in Go. So the chars of any text tile it: their sizes add up to
`s.len`.

## Runes and units

`std.utf8` reads and writes runes. A rune is a plain `Int`, and `size`
is how many bytes it takes:

```rig
use std.utf8

sub main()
  s = "h\u{e9}\u{1f600}"
  for r in utf8.runes(s)
    print(r, utf8.size(r))
  d = utf8.rune_after(s, 1)
  print(d.rune, d.size, utf8.rune_after(s, 1 + d.size).size)
  bad = "a\xffb"
  print(utf8.is_valid(s), utf8.is_valid(bad), utf8.rune_count(bad), utf8.rune_after(bad, 1).rune)
```

```output
104 1
233 2
128512 4
233 2 4
true false 3 65533
```

`rune_after(s, i)` reads the rune that starts at byte `i` and returns
a `Decoded`, which holds the `rune` and the `size` in bytes it took.
Add the size to `i` to step to the next one. Invalid input never stops
a reader: the stray `\xff` reads as U+FFFD (65533), one byte wide, so a
loop moves past it. `utf8.is_valid` asks whether the text is well
formed.

Facts about one rune live in `std.unicode`:

```rig
use std.unicode

sub main()
  print(unicode.width(0x4e2d), unicode.width(0x301), unicode.width(0x61))
  print(unicode.is_space(0x3000), unicode.is_id_start(0x4e2d), unicode.is_id_start(0x30))
```

```output
2 0 1
true true false
```

A Chinese character is 2 columns wide, a combining accent is 0, and a
letter is 1. The ideographic space U+3000 is white space, a Chinese
character may start an identifier, and a digit may not. The `text.width`
below is built from the first of these.

`std.utf16` exists for one job: to agree with code that counts UTF-16
units. A JavaScript editor or a TypeScript checker reports a column in
units, and the program holding the UTF-8 bytes must translate:

```rig
use std.text
use std.utf16

sub main()
  line = "\u{1f600} price: 5"
  at = utf16.byte_index(line, 3)
  print(line.len, utf16.unit_count(line), at)
  print(line[at..])
  start = text.find(line, "price") ?? 0
  print(start, utf16.unit_count(line[..start]))
```

```output
13 11 5
price: 5
5 3
```

The emoji is four bytes and two units, so unit column 3 is byte 5.
`byte_index` goes from a JavaScript position to a byte and clamps a
stale one instead of panicking. `unit_count(line[..start])` goes back
the other way. Nothing in Rig stores UTF-16; the module is a bridge.

## Searching and splitting

`std.text` finds, cuts, and splits, and everything it returns is a view
of the text it was given. Indexes are bytes, and white space and case
are ASCII's. UTF-8 makes that safe: every byte of a multi-byte rune is
128 or more, so an ASCII separator never hides inside one.

A word counter needs three of these. It folds case, turns everything
that is not part of a word into a space, and splits on white space:

```rig
use std.hash
use std.text

fun fold(s: ?String) -> String
  out = String()
  for b in s
    if text.is_alpha(b) or b == 0x27 or b >= 0x80
      !out.push(text.to_lower(b))
    else
      !out.push(0x20)
  out

sub main()
  line = "The cat sat. The CAT, the Dog; don't stop, the cat!"
  low = fold(line)
  seen = hash.Map[?String, Int].new()
  for w in text.words(?low)
    n = (!seen).ensure(w, 0)
    n += 1
  for e in ?seen.items()
    print(e.key, e.value)
```

```output
the 4
cat 3
sat 1
dog 1
don't 1
stop 1
```

`fold` keeps ASCII letters, the apostrophe, and every byte of 128 or
more (so words in other scripts stay whole), lowercases the ASCII
letters, and replaces the rest with a space. `text.words(?low)` yields
each nonempty run between spaces, as views into `low`. `ensure(w, 0)`
puts a zero under an unseen word and lends the count to write, so one line
counts every word. The map holds views, which is why `low` must outlive
`seen`, and the compiler checks it. It lists words in the order they
first appeared.

The same `fold` makes a case-insensitive search. Fold both sides, then
ask whether one contains the other:

```rig
use std.text

fun fold(s: ?String) -> String
  out = String()
  for b in s
    if text.is_alpha(b) or b == 0x27 or b >= 0x80
      !out.push(text.to_lower(b))
    else
      !out.push(0x20)
  out

fun has_word(hay: ?String, needle: ?String) -> Bool
  text.contains(fold(hay), fold(needle))

sub main()
  print(has_word("Hello, World", "WORLD"), has_word("Caf\u{c9}", "caf\u{e9}"))
```

```output
true false
```

The first search finds `WORLD` in `Hello, World`. The second does not
find `café` in `CafÉ`, because `to_lower` changes ASCII letters only. A
byte table cannot know that `É` and `é` are one letter in two cases.
That needs Unicode's case data, which Rig does not ship.

Other finders are the same shape. `text.find` and `find_last` return an
`Int?`, `cut` splits around the first separator, `split` and `lines`
walk the parts, and `trim` takes ASCII white space off both ends.

## Width on a terminal

A terminal draws a char in 0, 1, or 2 columns. A combining accent takes
none, a Chinese character takes two, and an emoji sequence takes two
however many runes it has. Padding by bytes or by runes is wrong for
all of them. `text.width(s)` sums the width of each char, as a terminal
does:

```rig
use std.text

fun pad_bytes(name: ?String, cols: Int) -> String
  out = String(name)
  for 0..(cols - name.len)
    !out.push(0x20)
  out

fun pad(name: ?String, cols: Int) -> String
  out = String(name)
  for 0..(cols - text.width(name))
    !out.push(0x20)
  out

sub main()
  names = ["Ada", "Jos\u{e9}", "Zoe\u{308}", "\u{674e}\u{96f7}", "Ana \u{1f469}\u{1f3fd}\u{200d}\u{1f4bb}"]
  for n in names
    print(pad_bytes(n, 12), "|", text.width(n), n.len)
  for n in names
    print(pad(n, 12), "|")
```

```output
Ada          | 3 3
José        | 4 5
Zoë        | 3 5
李雷       | 4 6
Ana 👩🏽‍💻 | 6 19
Ada          |
José         |
Zoë          |
李雷         |
Ana 👩🏽‍💻       |
```

In a terminal that draws wide characters, the bars of the first
column wander left wherever a name holds more bytes than columns, and
the bars of the second line up. `José` is 5 bytes in 4 columns. `Zoë`
spells its accent as a separate rune, so it is 5 bytes in 3 columns,
and `Ana` with a woman technologist after it is 19 bytes in 6. `text.char_width(c)`
is one char's width. A tab is not measured, since its width depends on
where it lands, and an East Asian Ambiguous character counts as 1.

## Choosing a unit

| To | Use |
|---|---|
| store, index, slice, parse, or send text | bytes: `s.len`, `s[i]`, `s[a..b]` |
| decode, encode, or check UTF-8 | runes: `std.utf8` |
| ask what a rune is: white space, identifier, width | `std.unicode` |
| agree with JavaScript positions | units: `std.utf16` |
| count, shorten, or walk what a reader sees | chars: `text.char_count`, `first_chars`, `chars` |
| line text up on a terminal | `text.width` |

**Bytes are stored; chars are read. A field is known, a call scans,
and every count names its unit.**

A String stores UTF-8 because it is compact, the same bytes a file or
socket holds, and stable. Characters cannot be the storage unit, since
a char is 1 byte or 25, and a stored string would change length when
Unicode's tables did. UTF-16 is history: systems built when 16 bits
were thought enough kept it, so Rig gives it a module for code that must
agree and no more.

## Names that are values

Not every word in a program is text. A shape's kind, an option's key,
or a header's name is a name the program compares and passes around,
and never slices or prints by the byte. Rig writes one as a symbol, a
`:` touching the name:

```rig
fun area(shape: Symbol, w: Int, h: Int) -> Int
  match shape
    :rect => w * h
    :triangle => w * h / 2
    _ => 0

sub main()
  print(area(:rect, 3, 4), area(:triangle, 3, 4), area(:circle, 3, 4))
  s = :content-type
  print(s, s.text, s.text.len)
  print(Symbol.from_text("rect") == :rect, Symbol.from_text("hexagon"))
```

```output
12 6 0
:content-type content-type 12
true none
```

`:rect` is a value of type `Symbol`. It costs what an `Int` costs: it is
copied, holds no bytes of its own, and is compared in one step, not byte
by byte. `==` and `!=` are its only comparisons, and `s.text` gives its
name as a `Static`. A symbol is never declared first: every symbol the
program writes, in any module, is one of its values.
`Symbol.from_text` turns text read at run time into the symbol with
that name, or `none` when the program writes no such symbol.

Because any name is a symbol, a `match` on one cannot list them all,
and must say what happens to the rest:

```rig reject
fun area(shape: Symbol, w: Int, h: Int) -> Int
  match shape
    :rect => w * h
    :triangle => w * h / 2

sub main()
  print(area(:rect, 3, 4))
```

```error
`match` on a `Symbol` is not exhaustive without `_ =>`: a symbol's values are every symbol the program writes
```

The same openness makes a misspelled symbol just another symbol:
`:rcet` would fall to `_ =>`. When the names form a closed set and a
typo should stop the build, declare an enum instead. Its variants are
written with `.`, and only those it lists exist:

```rig reject
enum Shape
  rect
  triangle

fun area(shape: Shape, w: Int, h: Int) -> Int
  match shape
    .rect => w * h
    .triangle => w * h / 2

sub main()
  print(area(.rect, 3, 4), area(.rcet, 3, 4))
```

```error
no variant `rcet` on enum `Shape`
```

A symbol is a plain value, so it is a good key. A `hash.Map[Symbol,
Int]` holds options by name with no strings to allocate or compare:

```rig
use std.hash

sub main()
  opts: hash.Map[Symbol, Int] = hash.Map()
  !opts.put(:width, 80)
  !opts.put(:height, 24)
  print(opts.get(:width) ?? 0, opts.get(:depth) ?? 0, opts.len)
```

```output
80 0 2
```

| A name that | Write |
|---|---|
| is text to read, print, slice, or build | a `String`, or a `Static` literal |
| belongs to an open set: tags, keys, header names | a symbol, `:width` |
| belongs to a closed set, where a typo is a bug | an enum variant, `.width` |

**Text is bytes; a symbol is a name; an enum is a list you declare.**

## What is not there yet

- No Unicode case mapping. `to_upper` and `to_lower` change ASCII only,
  and `text.compare` orders by bytes.
- No normalization. `é` as one rune and as two are different strings,
  as the program above showed.
- White space for `trim`, `words`, and `lines` is ASCII's. The Unicode
  white-space test is `unicode.is_space(r)`, per rune.
- No locale-aware sorting, no right-to-left layout, and no char-indexed
  substring.

## Where to go next

- [The standard library: a tool in an afternoon](06-stdlib.md) builds a command-line tool from `std.os`, `std.file`,
  `std.json`, and `std.net`, using the text words from this chapter.
- [Errors and optionals](03-errors.md) covers `Int?` and `Int!`, which
  `text.find` and `text.parse_int` return.
- [TEXT.md](../TEXT.md) is the design: the names, the Go equivalents of
  each `std.utf8` function, and how other languages compare.
- [STD.md](../STD.md#stdtext) lists every `std.text` function, and
  [SPEC.md](../../SPEC.md#strings) states what the language does with
  strings.
