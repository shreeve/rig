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

## The design today: scalar, one pass, a tape

`std/json.rig` is a single-pass, validating, iterative parser (an
explicit stack, so depth costs no machine stack) that builds a tape of
`Int` words, `payload * 16 + tag`. A string without escapes is not
copied: its entry points into the source, so a `Doc` keeps the source
lent, and Rig's types show it. Escaped strings are decoded into one
buffer. Integers that fit an `Int` are `Int`s; every other number is
the nearest `Float`: Clinger, then Eisel-Lemire with Rig's `U128`, then
`std.text.parse_float` for the rare undecided case or more than 19
digits. The Doc's lists are reused, so a warm parse allocates nothing.
Nothing is lazy: `parse` does all the work Zig's std.json does.

It is scalar, since Rig has no vectors, and safe: every read is
bounds-checked in `--release`. Its speed comes from the design:

- one pass with no token objects and no recursion;
- SWAR for the string scan, for runs of spaces, and for digits;
- non-ASCII text checked a run at a time, not one character per scan.

It runs at 0.9-3.7 GB/s, 1.5-7x Zig std.json's scanner building the
same tape (RESULTS.md).

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

Today there is one SWAR tier: U64 steps from the opening quote, which
end keys in one or two steps. At the first special byte the scan
stops; an escape or a run of UTF-8 is handled, and scanning resumes
right after it, never from the string's start. With vectors the tiers
become one or two U64 steps, then 32-byte vector steps continuing from
where SWAR stopped. Keys never reach the second tier; most value bytes
do.

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
scanning on small ones; measure both once Rig has vectors. The tape and
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

1. **SIMD vectors with a byte mask** (est. 2-4x overall). A vector of
   16, 32 or 64 bytes with lane-wise comparison and a reduction to a bit
   mask, lowered to NEON, SSE/AVX or WASM SIMD128, and to scalar code
   where there is none. It classifies a block of input in a few
   instructions: simdjson's structural index, sonic-rs's 64-byte
   whitespace bitmap, and 32-byte string scans. Long strings (86-95% of
   the string bytes of gsoc-2018 and github_events are in strings over
   32 bytes) gain most. The `simd` work measured a 16-lane string scan at
   +13% to +22% on gsoc-2018 (RESULTS.md, "SIMD, round 1").
2. **Block iteration with one check per block** (measured 1-11%). A safe
   `for block in bytes.blocks(16)` that hands out fixed-size views with
   one bounds check per block and a remainder for the tail. Removing
   every bounds check from the runtime in an experiment gained 11% on
   twitter, 10% on github_events and 6% on canada (`rig-fast` against
   `rig-nocheck`).
3. **Checks the compiler proves away** (measured up to 18%). An index
   already bounded by `while i < s.len` or `for k in 0..s.len` needs no
   check; neither does `i += 1` under `i < s.len`, nor
   `m << m.leading_zeros()`, which is checked today (3 instructions per
   number). Overflow checks cost 11% on canada and 18% on gsoc-2018
   (`rig-safe` against `rig-fast`). A padded buffer type, followed by N
   readable bytes, would also remove the tail loop of a block read.
4. **Cheap word appends.** Copying the text between escapes a word at a
   time, as sonic-rs does, did not pay yet:
   - each `push[U64]` is about 13 instructions and 4 branches, three of
     which cannot fire (a checked `capacity - len`, an overflow check on
     `len + n`, and the range check `writeInt` repeats); wrapping
     arithmetic and a store at `items.ptr + used` make it 8 and 1
     (measured: another 2.2 points on twitterescaped);
   - `len` lives in memory, so each push reloads what the last one stored;
   - a tail of 1 to 7 bytes takes up to three pushes: a byte count on
     `push`, or `!t.truncate(n)`, would allow "write 8, keep k";
   - `reserve` alone removes no check: a write checked once for a reserved
     window would allow the fused loop.
5. **Bits of a Float** (measured about 0%; clarity). Eisel-Lemire builds
   a Float from its bits through an `[8]U8` and `write`/`read`, which
   LLVM folds, so a direct conversion is for clarity.
6. **Large literals and embedding** (build). `@embed("file.json")` as a
   `Static`, or string literals longer than the lexer's 64 KB token. The
   benchmark and the test programs split a file into literals of 60 KB
   and join them at run time, and the tests stay under the 16 MiB source
   limit.
7. **Character literals** (clarity). `'"'`, `'\\'`, `'{'` as `U8` values:
   the parser names 19 byte constants and writes `match` arms as hex
   literals with no name.
8. **Errors that carry data** (API). A parse error is a kind and a byte
   offset, and Rig's errors carry no data, so `parse` returns a `Bool`
   and the `Doc` holds `error` and `error_pos`. The API changes to
   fallible `!` functions when errors can carry them.

Done, and no longer open: the bit methods (`leading_zeros`,
`trailing_zeros`, `count_ones`) and `x.not()`; `<<%`; wide reads as one
load (`read[U128, .little]`); inlined `List.push` and `String.push`,
`reserve`, `push[T, e]`, and the trimmed append paths; and inlining of
small functions.
