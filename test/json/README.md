# JSON tests

`./test/run json` checks `std.json` (`std/json.rig`) against Python's
`json` module. `test/json/compare.py` does the work. Rig programs cannot
read files yet, so the inputs become generated Rig programs
(`driver.rig.tmpl`), each input one string literal in a table. Consecutive
groups share a program, since each program compiles the parser afresh; a
program holds at most 6000 inputs and stays under 16 MiB (Rig's largest
source file), counting the inputs as they are written in the program.
Each input is copied into a `String` before it is parsed. The programs
run under `rig run` with `RIG_SANITIZE=1`, so a leak or a use of freed
memory fails the group; a read past an input's end is stopped by Rig's
bounds checks (the sanitizer's guard page lies past the `String`'s
capacity, which is larger than the input).

```sh
./test/run json                  # every input of every group (10,511), whole
./test/run                       # the suite: a fixed, spread-out part of each group
./test/run json/floats           # one group, whole
test/json/compare.py --subset    # the part the suite takes, outside test/run
test/json/compare.py cases scan  # some groups, by hand
test/json/compare.py --only num- # cases whose name contains a string
JSON=path/to/json.rig test/json/compare.py   # another parser, such as an experiment
```

A run with filters takes every input of the groups it selects; a run
without takes the part `--subset` keeps (about a tenth of the inputs, in
every group), so the full suite stays quick. `./test/run json` is the full
check, run by the deep gate. `--delta` carries a group over when neither
the compiler, the cases, nor the data changed.

## Third-party data

The `checker` and `corpus` groups read files from other projects.
`tools/fetch-json-data.sh` downloads them into `test/json/data/`, which
git ignores, each pinned by commit and sha256; `data/README.md` says where
they come from and under what license. CI fetches them, and caches them by
the script's hash. The two groups read exactly the files the script
pins, and a group with no cases fails. Without the data those two
groups are skipped. The skip is noted on the run's output, in `-v`, and
in the summary's count of skipped groups. `JSON_REQUIRE_DATA=1` makes a
missing or changed file a failure instead. `./test/run` always checks
`std.json`. The `JSON` variable, which points `compare.py` at another
parser, does not reach it.

## Groups

| Group | Inputs | What decides the expectation |
|---|---|---|
| `cases` | `cases.txt`: 181 cases, 165 of them hand-written, many from serde_json's `tests/test.rs` | `ok` lines: Python; error lines: the exact kind and byte offset written there |
| `scan` | strings of each length to 33 with a quote, escape, control byte, or non-ASCII byte at the edges of the 8- and 16-byte blocks the string scan reads, at two alignments | Python; errors by kind and offset |
| `edges` | the other word-at-a-time paths at all 8 alignments: runs of 3-byte UTF-8 with another sequence, valid or not, at each place; digit runs of 1 to 25 digits, at the end of the input and before a byte just outside `0`-`9`; runs of escapes back to back, and a bad or missing hex digit at each place of a `\u` escape (4192 inputs, 3768 of them errors) | Python; errors by kind and offset |
| `blocks` | a quote, an escape, a control byte, and valid and invalid bytes of 0x80 or more at each offset 0 to 130 from where the string scan starts (a string's first byte, just after an escape, just after a UTF-8 run): through a 16-byte first step and two 64-byte blocks, with whole blocks after the stop and with the input ending at it, and every string as an object key too (3543 inputs, 3144 of them errors) | Python; errors by kind and offset |
| `spaces` | whitespace runs of 0 to 130 bytes, of each of the four whitespace bytes and mixed, everywhere the parser skips them; ended by a byte just outside the four (0x0B, 0x0C, 0x21, 0xA0, ...) in the middle of the input, and by the end of the input (1053 inputs, 786 of them errors) | Python; errors by kind and offset |
| `floats` | 31,987 numbers in 84 arrays (seeded, so the same each run): random doubles printed shortest, `%.17e`, `%.16e` and `%.15g`; exact halfway points between neighbouring doubles and 17- to 19-digit numbers next to them; random 1- to 19-digit decimals with exponents from -345 to 310; powers of ten; integers around 2^50 to 2^64 | Python |
| `checker` | `data/simd-json/{pass,fail,crash}` (JSON_checker and fuzzer inputs; 132 files) | Python |
| `deep` | nesting at, and one past, the depth limit of 1024 | Python, and the depth error's offset |
| `corpus` | every `.json` file in `data/simd-json` and `data/simdjson` (21 files, 17.8 MB) | Python |

## The canonical dump

The driver prints `=== NAME`, then one line per tape entry, in document
order:

| Line | Value |
|---|---|
| `null`, `true`, `false` | the literal |
| `i N` | an integer that fits an `Int` (I64) |
| `f BITS` | a Float, as the decimal value of its 64 bits |
| `s TEXT` | a string or an object key: its UTF-8 bytes, with `\` written `\\` and bytes below 0x20 and 0x7F written `\xHH` |
| `[`, `]`, `{`, `}` | an array or object opening or closing |
| `error KIND OFFSET` | the parse failed; `OFFSET` is a 0-based byte offset |

Floats compare by their bits, so the harness checks rounding to the
last bit and the sign of zero.

## The reference

`json.loads` with these rules, which are the parser's policy:

- The input must be UTF-8 (strict: no surrogates, no overlong forms).
- An integer literal (no `.` or exponent) that fits an `Int` is an
  `Int`. `-0` is the Float -0.0, as in simdjson, serde_json and Zig's
  std.json. Any other number is the nearest Float, and a number whose
  nearest Float is infinite is an error.
- `NaN`, `Infinity` and `-Infinity` are errors.
- A `\u` escape of a lone or unpaired surrogate is an error.
- Nesting deeper than 1024 is an error.
- Duplicate keys are kept, in order.

Where Python rejects an input, the parser must reject it too. Only the
`cases`, `scan`, `edges` and `deep` groups state the error kind and offset,
since Python's positions follow other conventions.

Error offsets point at the first byte that cannot be read: the
unexpected byte, the end of the input for `eof`, the first byte of an
invalid UTF-8 sequence, the backslash of an escape whose surrogate is
unpaired, the bad character of an escape, the first byte of a number
too large (`range`), and the bracket that opens level 1025 (`depth`).
