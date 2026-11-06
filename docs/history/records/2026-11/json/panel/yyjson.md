# Where std.json's extra instructions go, against yyjson 0.10.0 (Mac, 2026-11-05)

The panel's yyjson reader expert. Every number here is instructions retired (`/usr/bin/time -l`, through `tools/low`), the median of 3 of (N parses - 1 parse) / (N - 1). No time was measured. std.json is `rig-safe` from main cf6a362a6 (`std/json.rig` from the json-031 worktree); yyjson is `bench/json/cbench/prog-yyjson` (`-O3 -mcpu=native`, read flags 0, the pool allocator).

All the inputs, programs, and scripts are in `panel/yyjson/`:
- `tools/gen.py` and `tools/mk.py` write the synthetic inputs and build std.json programs that embed them.
- `tools/meas.py` measures std.json against yyjson; `tools/vmeas.py` measures a variant against main.
- `tools/census.py` counts token classes; `tools/model.py` predicts a file's gap from the per-token gaps.
- `var/v*.rig` are the variants; `meas-syn.txt`, `meas-corpus.txt` and `meas-variants.txt` are the raw results.
- `document.dis` and `yy.dis` are the disassembly of the two parsers.

## 1. The split that matters: formatting against tokens

I minified twitter, citm_catalog, and github_events (Python's `json.dumps` with `separators=(',',':')`), built std.json on each, and measured both parsers on both forms. Instructions per parse:

| file | std.json pretty | yyjson pretty | gap | std.json minified | yyjson minified | gap | gap from formatting |
|---|---:|---:|---:|---:|---:|---:|---:|
| twitter | 4.93M | 3.53M | 1.40M | 3.57M | 3.03M | 0.54M | **0.86M (61%)** |
| citm_catalog | 13.82M | 9.71M | 4.10M | 8.02M | 5.50M | 2.52M | **1.58M (39%)** |
| github_events | 0.45M | 0.37M | 0.08M | 0.31M | 0.33M | -0.03M | **all of it** |

- **std.json's formatting cost:** 8.3 instructions per whitespace byte on twitter and 4.7 on citm_catalog. yyjson spends 3.0 and 3.4.
- **On minified github_events std.json retires fewer instructions than yyjson,** and on minified twitter only 18% more (40% on pretty).
- **This corrects skip-space-2026-11-05.md,** which says the whitespace is not where yyjson's lead is. In instructions, formatting is the largest single part of the gap on both pretty files.

### Why yyjson is cheaper here

yyjson's pretty reader (`read_root_pretty`) does not use a general whitespace skip on its common path. It guesses the layout from where it is in the grammar:
- after a value, `byte_match_2(cur, ",\n")`;
- after a key, `byte_match_2(cur, ": ")`;
- after an opening bracket, `if (*cur == '\n') cur++`;
- indentation, `byte_match_2(cur, "  ")`, unrolled 16 times: one 2-byte load, a compare, and a branch per two spaces, always a fixed advance.

Its general loop, `while (char_is_space(*++cur))`, is the fallback only.

std.json's path is costlier in four places:
- It calls `skip_space` four times per object member, even when there is no whitespace. Each call costs about 6 instructions: the `at < 0` test, `i < len`, the load, and `c > ' '`.
- A run of 1 to 7 spaces costs about 19 instructions a byte (document.dis, 0x10003f174). The 8-space test (`i + 8 <= len`, a load, a compare) is tried and fails on every byte, and then the four-way whitespace compare runs.
- After `,` and `:`, a test for a line ending (`\n`) and a run of spaces comes only after the generic test.
- Twitter and github_events are indented by 2: most runs are under 8 bytes.

### The ruled-out skips do not cover this

None of the three ruled-out tries is this mechanism. yyjson's keeps the property the record found essential: branches that predict well and a constant advance, with no load-to-load dependency.

Whether it wins in time is untested, and I did not test it, as briefed. I list it because it is where the instructions are.

## 2. The per-token gap, from synthetic files

Each file is an array (or object) of 50,000 copies of one token, minified unless marked `_p` (pretty, 2-space indentation). The gap is std.json minus yyjson, in instructions per element, separator included.

| element | std.json | yyjson | gap |
|---|---:|---:|---:|
| `true` | 61.0 | 50.8 | +10 |
| `null` | 62.2 | 46.1 | +16 |
| int, 1 digit | 144.0 | 68.5 | **+76** |
| int, 3 digits | 146.2 | 80.1 | **+66** |
| int, 9 digits | 177.1 | 123.0 | **+54** |
| int, 18 digits | 208.2 | 188.6 | +20 |
| float `ddd.ddd` | 217.6 | 139.8 | **+78** |
| `""` | 105.2 | 70.7 | +34 |
| 8-byte string | 123.0 | 105.0 | +18 |
| 16-byte string | 145.5 | 140.9 | +5 |
| 40-byte string | 158.3 | 241.5 | **-83** (std.json ahead) |
| `[]` | 115.2 | 85.0 | +30 |
| `{}` | 115.3 | 71.9 | +43 |
| `[1]` | 261.0 | 124.2 | +137 |
| `{"a":1}` | 360.0 | 175.6 | +184 |
| member `"k0000000":1` | 260.8 | 143.6 | +117 |
| member `"k0000000":true` | 176.7 | 130.2 | +46 |
| `true`, pretty | 114.3 | 58.3 | +56 (formatting +46) |
| member, pretty | 333.7 | 154.0 | +180 (formatting +63) |

These are additive enough to predict the minified files (`model.py`). citm_catalog's predicted gap is 2.74M against 2.52M measured, which is 9% off. Its token gap splits:

| class | predicted gap | share |
|---|---:|---:|
| keys | 0.94M | 34% |
| integers | 0.78M | 28% |
| objects | 0.65M | 24% |
| arrays | 0.37M | 14% |

Strings and literals are about 0 on citm_catalog.

twitter's prediction is 0.30M against 0.54M measured:

| class | predicted gap |
|---|---:|
| keys | +0.34M |
| integers | +0.13M |
| objects and arrays | +0.12M |
| literals | +0.06M |
| string values | **-0.35M** (std.json ahead: long strings, vector scan) |

The unexplained 0.24M is most likely the non-ASCII strings (755 strings, a CJK path through `utf8_text`) and twitter's 312 escaped strings, which the synthetic files do not have.

Shares of the whole pretty-file gap, then, for twitter / citm_catalog:

| class | twitter | citm_catalog |
|---|---:|---:|
| formatting | 61% | 39% |
| keys | about 24% | 23% |
| containers | about 8% | 25% |
| integers | about 9% | 19% |
| literals | about 4% | 0% |
| string values | about -25% | 0% |
| unexplained (non-ASCII and escapes) | about 17% | — |

## 3. Each class: what yyjson does and what std.json does

### Structure (containers, the value loop)

**yyjson** is a goto state machine:
- Being inside an object or an array is the program counter (`obj_val_end` against `arr_val_end`), never a test.
- `val_incr` is one pointer add and one compare against `val_end`. The values after keys are not even checked (`val++`), with 2 slots of padding.
- A container saves its count in its parent's tag and links to the parent by an offset. Its input is padded with 4 zero bytes, so no read tests for the end.

**std.json** decides the same things with data:
- After every value it tests `top < 0` and `i >= n`, then computes `in_object = top & 1` and selects `closing`. That is about 5 to 8 instructions a value: about 0.15M on twitter and 0.4M on citm_catalog, by count × cost.
- In safe mode, `open`, `close`, `add_string` and `add_int` check their tape arithmetic for overflow:
  - `top * 16`, `len * 2`, and `len * 16` each become add, shift right, compare, branch;
  - `start * 16` becomes shift right by 59 and a branch;
  - `(offset << 27) + n` becomes a shift-exact check.

  None of these can overflow: the tape is at most `MAX_INPUT` entries.

**Measured, variant V4** (`var/v4.rig`: the same arithmetic written with `*%` and `+%`, same tape, same results):

| input | change |
|---|---|
| per empty container | -13 instructions (`[]` and `{}` both 11% fewer) |
| `{"a":1}` | 4.8% fewer |
| citm_catalog | 2.4% fewer |
| citm_catalog minified | 4.4% fewer |
| twitter | 1.4% fewer |
| twitter minified | 2.3% fewer |

That closes about 8% of citm_catalog's gap and 5% of twitter's. This is **codegen overhead**: the checks would go if the compiler knew `tape.len <= MAX_INPUT`, or knew that a List's length is below 2^60.

**Tape writes.** Each `push` loads `buf.len`, `len` and `buf.ptr`, compares, and stores. It then **reloads `len` after the store** (`str x8, [x0, x1, lsl #3]; ldr x8, [x19, #0x20]`), because the i64 store might alias the Doc. Then it adds and stores `len` again. That is about 9 instructions, plus 2 constants (`SPACES`, 10) that are rebuilt after every push, because the `growBy` call on the cold path clobbers their registers. yyjson's write is about 5 (add, compare, branch, two stores).

That is 5 to 6 extra per tape entry: about 0.17M on twitter (12% of the gap) and 0.45M on citm_catalog (11%).

main.rig's own comment points the same way: when the Doc's fields stay in registers, std.json is 7% faster. This is **codegen**: keep `len` and `ptr` in locals across the loop, and give the grow path its own cold call that saves its registers. It is an estimate from the disassembly, not measured.

### Keys

**yyjson** spends about 20 instructions plus 3 a byte on a key:
- one `*cur == '"'` test;
- a byte-at-a-time scan unrolled 16 times, each byte a load, a table load, and a bit test;
- the tag, two stores, and a 0 byte written at the closing quote;
- `byte_match_2(": ")`.

**std.json:**
- calls `key()`, which tests `at >= len` and `src[at] != '"'`, which the dispatch already knew;
- calls `skip_plain_ascii` out of line: arguments, `stp`/`ldp`/`ret`, the `at < 0` and `at > len` tests again, an overflow test `adds`/`b.vs` on `at + 16`, and six instructions building its constants on every call;
- reads the stop byte again to see whether it is `"`;
- tests `n > MAX_STRING`, then pushes;
- calls `skip_space(end)`, tests `i >= len` and `!= ':'`, and calls `skip_space(i + 1)`.

The key-only overhead, separate from the scan, measures about 18 instructions (the 8-byte-key member minus the 8-byte string minus `true`). The fixed cost of a string is about 34 (`""`).

**Measured, variant V1** (`var/v1.rig`): two SWAR words inline in `scan_string`, avoiding the call for strings under 16 bytes. **It is worse**:

| input | change |
|---|---|
| 16-byte strings | 46% more |
| 8-byte-key member | 28% more |
| twitter | 10.6% more |
| citm_catalog | 0.3% fewer |

Inlining more scan code into the huge `document` function costs more than the call it saves; the disassembly shows the constants and registers rebuilt. So the out-of-line call is not the lever.

**What would help:** stop re-deriving what the caller knows.
- Pass the stop byte back from the scan (or end the scan only on `"`), so the caller does not read it again.
- Drop `key`'s tests that the dispatch already made.
- Test `src[end] == ':'` (and `": "`) before calling `skip_space`.

Expected about 10 to 15 instructions per key: 0.2M on twitter and 0.35M on citm_catalog, 9 to 14% of the gap. That is an **algorithm** change (std.json source), not measured.

### String values

std.json is **ahead** on strings of 16 bytes or more: one 16-byte vector step against yyjson's 3 instructions a byte. It is behind by its fixed cost of about 34 instructions on short strings (the same overhead as keys). On twitter, string values are 0.35M in std.json's favor. Leave the scan alone; trim the fixed cost as for keys.

### Numbers

**yyjson** reads the sign, then up to 19 digits a byte at a time, unrolled, with the digit test fused into the multiply-add. At the first non-digit, one table lookup (`digi_is_fp`) asks whether it is `.`, `e`, or `E`. If not, it writes the integer. There are no range tests for under 19 digits and no bounds tests (padding).

**std.json** does all of this for a 1-digit integer, about 145 instructions where yyjson spends about 68:
- tests `peek` for `-`;
- runs SWAR `take_digits` for any number of digits. On a short number, its partial word costs about 24 instructions: `ctz`, the `POW10_U64` load, a variable shift with its range check, and three multiplies. It rebuilds 5 constants inside the loop, with no register left for them;
- runs two overflow tests;
- runs the leading-zero test;
- runs two more `peek`s, each with its own bounds test (`.`, then `e`);
- tests `is_float` and `digits <= 19`, then `-0`, `m <= Int.max`, and `add_int`'s range test;
- pushes.

**Measured, variant V2** (`var/v2.rig`): after the integer digits, read the stop byte once; if it is not `.`, `e`, or `E` and there are 17 digits or fewer, push the entry directly.

| input | change | per element |
|---|---|---|
| 1-digit and 9-digit ints | 12.6% and 10.2% fewer | about -18 |
| 18-digit ints | 3.8% more | +8 |
| floats | 7.9% more | +17, the extra test |
| citm_catalog minified | 3.4% fewer | -0.27M per parse: about 7% of citm_catalog's gap |
| twitter minified | 1.1% fewer | |

Placing the test so it costs floats nothing would make it a clean win, for example by branching on the stop byte that `take_digits` saw.

**V2b** (V2 plus a byte loop for the first 4 digits): 28% fewer on 1-digit ints, but 10% more on 18-digit ints, and only 0.4% fewer on citm_catalog. Its ids have 9 digits, so the loop did not pay; not recommended.

These are **algorithm** changes. The constants rebuilt in the loop are **codegen**: register pressure in one giant function.

### Literals

The gap is 10 to 16 per literal: the dispatch's compare tree plus the push. std.json's literal match is already one 4-byte compare, like yyjson's `byte_match_4`.

**Dispatch.** std.json reaches a string through a compare tree on `c`: `{` or `[`, then `<= 'e'`, then `"`, about 9 instructions after the `i < n` tests. yyjson tests `"` first in the value position and goes straight to `{` and `[` in the key position. Ordering the tests by frequency (strings first in a value position) is worth 3 to 5 a value, about 0.1M on twitter and 0.3M on citm_catalog. Estimated only.

## 4. Ranked list of changes

| # | change | share of the gap (twitter / citm_catalog) | confidence | kind |
|---|---|---|---|---|
| 1 | Layout-predicted separators: `,\n`, `: `, a `\n` after `{` and `[`, and a 2-byte `"  "` test unrolled for indentation; no `skip_space` call when the next byte is the expected token | up to 61% / 39% (the measured formatting share); a realistic win is half that | High where the instructions are; **time unknown**, and in the ruled-out area | algorithm |
| 2 | Tape writes in registers: `len` and `ptr` held across the loop, no reload after a store, the grow path cold | about 12% / 11% | Medium (from the disassembly; the main.rig comment agrees) | codegen |
| 3 | Fixed cost of keys and short strings: the stop byte handed back, `key`'s repeated tests dropped, `:` tested first | about 9% / 14% | Medium (estimated; V1 showed that inlining the scan is not the way) | algorithm |
| 4 | Structure from the program counter: object and array states as separate loops, no `top & 1`, `closing`, or `top < 0` per value | about 10% / 10% | Medium-low (estimated) | algorithm |
| 5 | Tape arithmetic without overflow checks (V4) | 5% / 8% | **High, measured** | codegen (range facts), or `*%` in the source as a stopgap |
| 6 | Integer fast exit (V2), placed so floats pay nothing | 3% / 7% | **High, measured** (floats need re-placing) | algorithm |
| 7 | Value dispatch ordered by frequency | about 4% / 4% | Low-medium | algorithm |

Not recommended:
- V1, the inline string scan: 10.6% worse on twitter.
- V2b, a byte loop for the first digits: a loss on citm_catalog's 9-digit ids.
