# Panel: std.json as an algorithm, against yyjson and simdjson (tape/DOM view)

Mac, Rig main cf6a362a6, `rig-safe`. Instruction counts only, through `tools/low`:
(N=41 - N=1)/40 parses, median of 3 (`tape/ins.sh`). No timing was done.
Scripts and raw output are in `panel/tape/`: `tokens.py`/`tokens.txt` (token classes),
`minify.py`, `ins-min.txt` (full vs minified), `synth.py`/`synth/`/`synth.txt`
(per-class costs), `mkvar.py`/`v/` (variants), `runvars.sh`/`vars.txt` (variant counts).

## 1. Token counts per class

| | twitter | citm_catalog | github_events | gsoc-2018 | canada |
|---|---:|---:|---:|---:|---:|
| bytes | 631,514 | 1,727,204 | 65,132 | 3,327,831 | 2,251,051 |
| tokens (values + keys) | 28,005 | 72,344 | 2,330 | 37,921 | 167,187 |
| keys | 13,345 | 25,869 | 1,139 | 18,960 | 8 |
| keys <= 16 bytes | 9,527 | 24,960 | 1,100 | 17,696 | 8 |
| string values | 4,754 | 735 | 752 | 15,168 | 4 |
| string values > 32 bytes | 1,465 | 67 | 417 | 5,901 | 0 |
| ints | 2,108 | 14,392 (13,485 of 9+ digits) | 149 | 0 | 46 |
| floats | 1 | 0 | 0 | 0 | 111,080 |
| true/false/null | 4,737 | 1,263 | 88 | 0 | 0 |
| objects / arrays | 1,264 / 1,050 | 10,937 / 10,451 (8,695 empty) | 180 / 19 | 3,793 / 0 | 4 / 56,045 |
| whitespace bytes | 164,608 (26%) | 1,226,905 (71%) | 11,803 (18%) | 254,065 (8%) | 24 |
| whitespace runs | 28,826 | 76,337 | 2,526 | 41,713 | 18 |
| runs after `:` (all one space) | 13,345 | 25,869 | 1,139 | 18,960 | 6 |
| runs after `,` or an open bracket (newline + indentation) | 13,913 | 37,777 | 1,190 | 18,960 | 7 |
| tape words written | 30,319 (1.08/token) | 93,732 (1.30/token) | 2,529 | 41,714 | 223,236 |

The tape is already the lean one: about 1.1-1.3 words of 8 bytes per token. yyjson writes 16 bytes
per value, and simdjson 1-2 tape words plus a string-buffer copy. The tape layout is not where
the instructions go.

## 2. Instructions per parse: full against minified (whitespace removed)

| file | std.json | yyjson | simdjson | std.json/token | yyjson/token |
|---|---:|---:|---:|---:|---:|
| twitter | 4,925,950 | 3,532,197 | 3,781,774 | 176 | 126 |
| twitter, minified | 3,575,138 | 3,031,607 | 3,393,939 | 128 | 108 |
| citm_catalog | 13,799,858 | 9,698,250 | 9,530,969 | 191 | 134 |
| citm_catalog, minified | 8,019,104 | 5,509,189 | 6,626,280 | 111 | 76 |
| github_events | 453,948 | 379,418 | 357,082 | 195 | 163 |
| github_events, minified | 307,867 | 356,561 | 332,574 | 132 | 153 |

Whitespace costs std.json 1.35M instructions on twitter (47 per run, 8.2 per whitespace byte)
against yyjson's 0.50M (17 per run). Split of the gap to yyjson:

| file | gap | whitespace part | everything else |
|---|---:|---:|---:|
| twitter | 1.39M | 0.85M (61%) | 0.54M (39%) |
| citm_catalog | 4.10M | 1.59M (39%) | 2.51M (61%) |
| github_events | 0.07M | 0.12M (more than all of it) | -0.05M (std.json 14% ahead) |

This contradicts the conclusion of skip-space-2026-11-05.md that "the whitespace is not where
yyjson's lead is". In instructions, most of twitter's gap and all of github_events' is whitespace.
The difference is not the skipper. yyjson's pretty reader (`read_root_pretty`) folds whitespace into
the separators: it tests `,\n` as one 16-bit compare, `: ` as one, a newline straight after an open
bracket, and then the indentation two spaces at a time (`byte_match_2(cur, "  ")`, unrolled 16
times). Every step is a constant advance behind a predicted branch, which is the shape the record
found fast on Apple cores, and there is no bounds test because the input is padded.
std.json makes a general `skip_space` call at each of these points. It handles the indentation
left after the last 8 spaces one byte at a time, with a failed U64 compare on each byte, and makes
two calls around every `:`.

## 3. Cost per token class (synthetic minified files, 50,000 elements each)

Instructions per element, including the comma and the dispatch:

| element | std.json | yyjson | simdjson | std.json more |
|---|---:|---:|---:|---:|
| `null,` | 62 | 46 | 62 | +16 |
| `[],` | 115 | 85 | 66 | +30 |
| `123,` | 146 | 80 | 120 | +66 |
| `123456789,` | 177 | 123 | 168 | +54 |
| `12.345678,` | 215 | 155 | 199 | +60 |
| `-12.345678901234567,` | 266 | 224 | 253 | +42 |
| `"k0000001":1,` (key + int) | 260 | 144 | 196 | +116, about +50 for the key and `:` |
| `{"a":1},` | 359 | 176 | 263 | +183 |
| `"0123456789",` | 123 | 113 | 115 | +9 |
| `"<60 bytes>",` | 175 | 326 | 262 | std.json 46% fewer |
| `\n    123,` (pretty) | 241 | 89 | 131 | +152: +86 of it is the indentation |
| `\n  "k0000001": 1,` (pretty) | 333 | 153 | 206 | +180 |

The model fits the minified files. On citm the remainder is 25,869 keys × about 50 = 1.29M, plus
14,392 ints × about 55 = 0.79M, plus 21,388 opens and closes × about 15 = 0.32M. That makes 2.40M
of the measured 2.51M. String values are at parity when short and far ahead when long: the tiered
scan is right. The excess is in the **fixed cost per token**: keys, numbers and containers.

## 4. Variants measured (instructions per parse; each includes the ones before it)

- v1, colon fusion: after a key, `:` or `: ` is taken directly, with no `skip_space` before or after.
- v2, indentation fusion: after `,` or an open bracket, a newline, then spaces 8 at a time, then
  2 at a time, then `skip_space`.
- v3, a short path for integers of 1 to 17 digits (no `.`, `e` or leading zero, not `-0`): it
  pushes `v*16+T_INT` with no range test, and floats continue in `number_rest`.

| file | base | v1 | v1+v2 | v1+v2+v3 |
|---|---:|---:|---:|---:|
| twitter | 4,935,388 | 4,753,453 (3.7% fewer) | 4,323,996 (12.4% fewer) | 4,379,635 |
| citm_catalog | 13,825,870 | 13,683,152 (1.0% fewer) | 11,143,160 (19.4% fewer) | 11,302,301 |
| github_events | 437,568 | 427,801 | 372,895 (14.8% fewer) | 381,939 |
| gsoc-2018 | 10,995,381 | 10,790,133 | 10,020,406 (8.9% fewer) | 10,110,271 |
| canada | 36,375,619 | 36,157,072 | 36,944,506 (1.6% more) | 39,192,052 (7.7% more) |
| twitterescaped (minified) | 5,196,396 | 5,339,718 (2.8% more) | 5,429,673 (4.5% more) | 5,468,412 |
| key8 (minified) | 13,007,039 | 13,448,406 (3.4% more) | 13,699,586 | 13,902,118 |
| int3 (minified) | 7,302,532 | 7,151,054 | 7,322,759 | 7,898,595 (7.9% more) |

Every variant's tape length matched the base on every file.
- **v2 closes most of the whitespace gap:** 44% of twitter's whole gap to yyjson, 65% of
  citm_catalog's, and all of github_events'. With it, std.json retires 22% more instructions than
  yyjson on twitter and 15% more on citm_catalog, down from 40% and 43%.
- **v1 and v3 are inconclusive, not negative.** v1 pushed `Doc.key` out of line: `nm` shows a new
  `_json.Doc.key` symbol, so every key pays a call and spills the parser's state. That is why the
  minified files got worse. v3's int path went up 12 instructions per number, with no saving visible,
  for the same reason. The parser's speed rests on LLVM inlining one large `document`, and any
  added path changes those decisions. This is the codegen panelist's domain, but it shapes the
  algorithm too (item 4 below).

## 5. Ranked changes

Each item gives its expected share of the instruction gap to yyjson on twitter and citm_catalog,
and whether it keeps full validation.

1. **Fold whitespace into the separators, as yyjson's pretty reader does** (`,` then newline
   then indentation, an open bracket then newline, `: `), with constant-step tests and the
   general `skip_space` as the fallback.
   - Expected share: measured at 44% of twitter's gap and 65% of citm_catalog's, all of
     github_events', and 8.9% fewer instructions on gsoc-2018. It cost 1.6% on canada and
     2-4% on minified files through inlining side effects.
   - Confidence: high for instructions, medium for time. It is not a computed advance, but it
     must be timed (time.py, 20 rounds) before it lands, given the record.
   - Validation: all kept. It only consumes bytes that are whitespace and falls back on anything else.
2. **A key path built for keys.** 71-97% of keys are 16 bytes or less: run the first SWAR tier
   inline in the state loop and call `skip_plain_ascii` only past it. Take `:`/`: ` directly. Drop
   the re-tests std.json repeats: `at >= len`, the `"` re-read, `i >= 0`.
   - Expected share: keys cost about 50 more instructions each than yyjson's, which is
     1.29M = 31% of citm_catalog's gap and up to about 0.5M = 35% of twitter's.
   - Confidence: medium; the first try lost to inlining.
   - Validation: all kept.
3. **A short integer path.** Up to 17 digits, end with one table test for `.`/`e`/`E` (yyjson's
   `digi_is_fp`), and drop the `m <= max` and 59-bit range tests, which 17 digits make unneeded.
   For 1-8 digits, a byte loop beats SWAR's ctz, `POW10[k]` load, variable shift and three
   multiplies. Floats continue from the integer's state and do not re-parse.
   - Expected share: about 55-65 instructions per number, which is 0.8M = 19% of citm_catalog's
     gap and 9% of twitter's.
   - Confidence: medium-low; v3 is inconclusive.
   - Validation: all kept.
4. **An explicit state machine:** states for an object key, an object value's end and an array
   value's end, as yyjson's labels are. `in_object`, `top < 0` and `i >= n` are then not re-derived
   after every value. Each state's helpers stay small enough that inlining stays stable, which is
   what items 2 and 3 need.
   - Expected share: the containers' +30 per open and close pair is about 8% of citm_catalog's
     gap; the rest of its value is enabling items 2 and 3.
   - Confidence: medium.
   - Validation: all kept.
5. **Tape writes:** a write cursor kept in registers (open item 4), and tag packing with `|` and
   wrapping shifts over checked `*16+tag`, after the length checks already bound the payload.
   - Expected share: about 3-6 instructions per token, about 5-7% of the gap.
   - Confidence: medium. It overlaps the codegen panel.
   - Validation: all kept; the bounds are tested before packing.
6. **A simdjson stage 1 is not the Mac lever.** simdjson DOM retires more instructions than yyjson
   on twitter (5.98 against 5.59 per byte) and runs slower on the Mac. Item 1 already removes most
   of what stage 1 would remove (whitespace), and std.json already beats both on long strings.

Keeping the stop-at-end bounds model rather than padding the input costs a test or two per step.
That is a small part of the gap; padding would mean copying the input, as yyjson does.
