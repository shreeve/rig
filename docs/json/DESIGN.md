# JSON parser design

## How the references parse

- **simdjson** (and its ports **simd-json**, Rust, and **zimdjson**,
  Zig) works in two stages. Stage 1 classifies 64-byte blocks with SIMD
  into bit masks: quotes, backslashes, structural characters, and
  whitespace. Escaped quotes come from runs of odd backslashes, string
  interiors from a prefix XOR of the quote mask (a carry-less multiply),
  and UTF-8 is validated in the same pass by table lookups
  (Keiser-Lemire). The output is an index of every structural
  position. Stage 2 walks that index with a state machine and writes a
  **tape**: 64-bit words of a type tag and a payload, strings copied
  and unescaped into a string buffer, numbers in the next word.
- **sonic-rs** has no index: one pass, with SIMD where it pays. It skips
  whitespace with a 64-byte non-space bitmap kept between calls, finds
  a string's end 16 or 32 bytes at a time, unescapes in place, and
  reads 8 digits at a time by SWAR. It builds a **DOM** in arena-like
  node storage, and also offers **lazy** values that skip unread parts.
- **serde_json** is scalar recursive descent into typed values or a
  `Value` **DOM**. It finds a string's end by SWAR (Mycroft's test, 8
  bytes at a time) and keeps unescaped strings as views of the input. Its input is already UTF-8 (`&str`) or is checked once at
  the end. Floats are correctly rounded only with `float_roundtrip`.
- **Zig std.json** is a byte-at-a-time state machine (`Scanner`) that
  can stream. A bit stack tracks nesting, UTF-8 is checked inside the
  state machine, and tokens are slices of the input, with escapes as
  partial strings. `Value` is a **DOM** with a hash map per object.

**Numbers.** All the exact parsers use Clinger's fast path (a mantissa
and a power of ten both exact as doubles) and then Eisel-Lemire: one
64×64→128-bit multiply by a 128-bit truncation of 5^q from a table of
651 entries, with a big-decimal fallback when the product cannot
decide the rounding. **Strings** are unescaped by copying the runs
between escapes and decoding `\uXXXX`, pairing surrogates. UTF-8 is
checked per sequence (scalar) or per block (SIMD lookup).

## The design today: one pass, a tape

`std/json.rig` is a single-pass, validating, iterative parser that
builds a tape of `Int` words, `payload * 16 + tag`. A string without
escapes is not copied: its entry points into the source, so a `Doc`
keeps the source lent, and Rig's types show it. Nesting costs no machine
stack and no other list: an open array's or object's tape entry holds
the entry of the one around it until it closes. Escaped strings are
decoded into one buffer. Integers that fit an `Int` are `Int`s; every
other number is the nearest `Float`: Clinger, then Eisel-Lemire with
Rig's `U128`, then `std.text.parse_float` for the rare undecided case or
more than 19 digits. Each parse reuses the Doc's lists, so a parse
allocates only when a list must grow.
Nothing is lazy: `parse` does all the work Zig's std.json does.

It is safe Rig, with no `raw`: every read is bounds-checked in
`--release`. Its speed comes from the design:

- one pass with no token objects and no recursion;
- a tiered string scan: SWAR for a string's first 16 bytes, then
  16-byte `Simd[U8, 16]` steps;
- SWAR for runs of spaces and for digits;
- non-ASCII text checked a run at a time, not one character per scan.

It runs at 1.9-7.0 GB/s on the six standard files, 3.1-11x Zig's
std.json building the same tape (RESULTS.md, "std.json on Rig main").

## SWAR as a first-class option

SWAR loads 8 or 16 bytes into a `U64` or `U128` and tests them at once:
"has zero byte" is `(x - 0x01..) & ~x & 0x80..`, "has byte c" applies it
to `x ^ c*0x01..`, and "has byte less than n" subtracts `n*0x01..`.
Rig's wrapping arithmetic and bit operators express all of it safely.

**Where SWAR beats vectors:** short strings (most keys), the first
block of any scan, whitespace and digit runs, and small documents: no
setup, no vector-to-mask transfer, and it runs anywhere, WASM without
SIMD128 included.

**Where vectors should win:** long strings (82-95% of the string bytes
in twitter, gsoc-2018 and github_events are in strings over 32 bytes),
and simdjson's stage 1 on big files, which classifies 64 bytes per
step.

**Measured** (RESULTS.md): the U64 string scan is up to 2x the
byte-at-a-time one (gsoc-2018). U128 is slower today, since `read[U128]`
loads its 16 bytes one at a time on every target; two U64 reads fix that,
but a 128-bit step is still two 64-bit steps on a 64-bit machine.
Signed and unsigned words measured the same (within 1%): the kernel
tests every byte's top bit, so a sign test saves nothing. Taking the first special byte's position
from the mask (a count of trailing zeros, now `m.trailing_zeros() >> 3`)
gained up to 14%. Spaces 8 at a time gained 25% on citm_catalog. Digits
8 at a time first gained nothing, with a byte loop for a run's last 1
to 7 digits; read as sonic-rs reads them, the last ones from the same
word, they gain about 10% on canada (RESULTS.md, "Parser changes").

## Tiered string scanning

The tiers come from the data, not from guesses (`bench/json/json-string-stats.py`):

- **Keys:** 71-97% are at most 16 bytes, and 99-100% at most 32.
- **Values:** only 23-51% are at most 16 bytes, but most string bytes
  are in values over 32 bytes.

`skip_plain_ascii` has two tiers. The first is two U64 steps from where
the scan starts (`TIER = 16` bytes), which end most keys. The second
goes on 16 bytes at a time as a `Simd[U8, 16]`, and `m.first()` finds
the first special lane. Fewer than 16 bytes from the end of the input,
it reads the last 16 bytes again and drops the lanes it has already
seen, so no read passes the end and the input needs no padding. At the
first special byte the scan stops; an escape or a run of UTF-8 is
handled, and scanning resumes right after it, never from the string's
start. Non-ASCII text is checked 16 bytes at a time up to the string's
next stop, by Keiser-Lemire's table lookups (simdjson's lookup4), in a
method kept out of line, since most strings never reach it. Near the
end of the input, or when a block shows an error, it checks a sequence
at a time from the text's first non-ASCII byte, which gives the
error's offset. Keys rarely reach the second tier; most value bytes do.

Measured (RESULTS.md): the second tier gains 12% on gsoc-2018, whose
strings are long, and costs 3-4% on twitter and twitterescaped, whose
values are short. Switching after 8 bytes is no better, and a 32-lane
second tier loses 7-9% on twitter.

## A structural index against tiered scanning

JSON has no row delimiter to `indexOf`, as CSV has: a document may sit
on one line. Its analog is simdjson's stage 1, one wide pass that
indexes every `{ } [ ] : , "` outside strings, then a second pass over
the index.

- **The index** does uniform, branch-free work per 64 bytes and
  validates UTF-8 in bulk. But it touches every byte twice and stores
  an index (4 bytes per structural character), and needs vectors and
  a carry-less multiply to pay.
- **Tiered scanning** touches each byte once, wastes nothing on short
  tokens, and fits SWAR. But its branches depend on the data.

Expect the index to win on large, string-heavy documents and tiered
scanning on small ones; measure both. The tape and
stage 2 here serve either.

## The design for later

With the open items below, the parser becomes:

- a SIMD stage 1 (or tiered vector scans), checking UTF-8 in bulk;
- the same stage 2 and tape;
- SWAR kept for short tokens and WASM without SIMD.

Rig already has the `U128` Eisel-Lemire needs. Arenas would matter for
a DOM, not for this reused tape.

## Open items

What the parser would still gain from Rig, each a general, safe
capability that needs no `raw` and no unchecked indexing. Gains are
measured where a number is given (RESULTS.md) and estimated from the
references' published designs where marked. In order of expected gain:

1. **SIMD beyond the string scan** (est. up to 2x overall). Rig has
   `Simd[T, n]` with lane-wise comparison, bit masks and `m.first()`,
   and the string scan uses it. Still to try with it: sonic-rs's
   64-byte whitespace bitmap, and simdjson's structural index, which
   also needs a carry-less multiply for the prefix XOR of the quote
   mask. The byte lookup it needs (`t.lookup(v)`) now checks UTF-8.
2. **Block iteration with one check per block** (measured 1-11%). A safe
   `for block in bytes.blocks(16)` that hands out fixed-size views with
   one bounds check per block and a remainder for the tail. Removing
   every bounds check from the runtime in an experiment gained 11% on
   twitter, 10% on github_events and 6% on canada (`rig-fast` against
   `rig-nocheck`).
3. **Checks the compiler proves away** (mostly done). Indexes and reads
   bounded by a loop's condition, `+` under such a bound, and the string
   scan's 16-byte reads are proven, with no check (#138, #149). The
   checks left cost 4-9% of instructions together and no net time on the
   Mac: removing them made canada 6% faster and four files 3-9% slower
   (RESULTS.md, "Checks and IPC after proofs2"). Still checked: `m <<
   m.leading_zeros()`, a read after an early-return guard, and `i >= 0`
   for a position a call returned (docs/RIG-NOTES.md, entries 10 and
   20).
4. **Cheap block appends to a List.** The text between escapes is
   copied 16 bytes at a time as it is scanned, with `String`'s
   `!t.push(v, keep: k)` (#150). Tape entries are pushed one at a time,
   and `document` keeps the tape's length and capacity in memory, so
   each push reloads them; a `List` write window (reserve n, write
   through a cursor) would keep them in registers (docs/RIG-NOTES.md,
   entry 8).
5. **Embedding a file** (build). `@embed("file.json")` as a `Static`.
   A string literal may be of any length (#168), so the benchmark and
   the tests write each input as one literal, but a program is at most
   16 MiB of source, so the tests spread their inputs over several
   programs.
6. **Multiple results** (clarity). A function returns one value, so
   `take_digits` hands back the digits' value through an out-parameter,
   which stays in a register only when the call is inlined. The byte
   loop is split off into `take_last_digits` so that `take_digits` is
   small enough to inline.
7. **An enum variant's name as text** (clarity). `error_name` spells
   out each `Error` variant's name in a `match`.
8. **Character literals** (clarity). `'"'`, `'\\'`, `'{'` as `U8` values:
   the parser names 19 byte constants and writes `match` arms as hex
   literals with no name.
9. **Errors that carry data** (API). A parse error is a kind and a byte
   offset, and Rig's errors carry no data, so `parse` returns a `Bool`
   and the `Doc` holds `error` and `error_pos`. The API changes to
   fallible `!` functions when errors can carry them.

The final API is the design owner's decision, and is not settled:
`parse` and the readers as fallible `!` functions, errors that carry
their offset, and `!` or `T?` in place of the `-1` that the parser's
internal steps return on an error. A `T?` costs nothing here: with
`utf8_end` and `utf8_end3` returning `Int?` in place of `-1`, and no
other change, instructions per byte stayed within 1% on all six corpus
files. Until then `std.json` is experimental.

Done, and no longer open: a Float from its bits (`Float.from_bits`); the
bit methods (`leading_zeros`, `trailing_zeros`, `count_ones`) and
`x.not()`; `<<%`; wide reads as one load (`read[U128, .little]`);
inlined `List.push` and `String.push`, `reserve`, `push[T, e]`, and the
trimmed append paths; and inlining of small functions.
