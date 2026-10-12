# JSON: measurements

The record of how `std/json.rig` was measured and tuned. The parser was
written in the Trig project before it moved into Rig's standard library,
so the earlier commit ids below (such as 7c3821b, 13899b9 and 686c5ae)
name that project's history, and a few drafts it mentions (the SIMD and
tiered scans) are not in this tree. `bench/json/README.md` says how to
rerun a measurement.

Machine: Apple silicon (aarch64), macOS, Zig 0.17.0, Rig 0.3.0. Every
timing is `bench/json/bench-json`: builds under `cpuq run --cores 2-6`, then
timing under `cpuq run --exclusive --cores 1`, each variant's runs
interleaved with the others' and the fastest of 7 to 9 kept. MB/s is
10^6 bytes per second. Runs on different days of the same build differ
by up to about 10%, so compare columns within one table.

## Correctness

``./test/run json``: **10,511 of 10,511 cases pass** (test/json/README.md):
181 cases in `cases.txt` (119 with an exact error kind and offset), 1298
block-edge string cases, 4192 edge cases for the other word-at-a-time
paths (UTF-8 runs, digit runs, escapes; 3768 with an exact error kind
and offset), 3543 string stops and 1053 whitespace runs at every offset
0..130 across 16- and 64-byte blocks, 31,987 numbers checked to the bit
in 84 arrays, 132 JSON_checker and fuzzer files (106 of them invalid),
7 depth cases, and 21 whole corpus files (17.8 MB), all sanitizer-clean.

## Rig against Zig's std.json

| file | bytes | rig-safe | rig-fast | zig-tape-safe | zig-tape-fast | zig-value-safe | zig-value-fast |
|---|---:|---:|---:|---:|---:|---:|---:|
| twitter | 631514 | 1824 | 1835 | 729 | 782 | 352 | 454 |
| canada | 2251051 | 879 | 974 | 450 | 564 | 208 | 283 |
| citm_catalog | 1727204 | 2393 | 2424 | 988 | 1250 | 480 | 709 |
| gsoc-2018 | 3327831 | 3687 | 4333 | 528 | 541 | 419 | 477 |
| github_events | 65132 | 2411 | 2366 | 794 | 900 | 405 | 508 |

The work each side does:

- **rig-safe** (`rig build --release`, Zig's safe mode, every bounds and
  overflow check kept) and **rig-fast** (`--release=fast`): `std/json.rig`
  validates the whole document, checks UTF-8, decodes every escape,
  converts every number exactly to an `Int` or the nearest `Float`, and
  builds the tape. The Doc's buffers are reused from parse to parse.
- **zig-tape**: `std.json.Scanner` builds the same tape (the harness
  checks the lengths agree): the same validation, UTF-8 checking,
  escape decoding into one buffer, and number conversion (`parseInt`,
  then `parseFloat`, as `std.json.Value` does). Buffers reused.
- **zig-value**: `std.json.parseFromSlice(std.json.Value)`, the usual
  std.json DOM, which also builds a hash map per object and allocates
  per parse. Shown for context, not like for like.

## What the checks cost

`rig-nocheck` is an experiment, never a build mode: rig-fast's emitted
Zig with the bounds checks in Rig's runtime (`index`, slice bounds,
`read`) removed, built `-OReleaseFast`.

| file | rig-safe | rig-fast | rig-nocheck | overflow checks | bounds checks | both |
|---|---:|---:|---:|---:|---:|---:|
| twitter | 1824 | 1835 | 2040 | 1% | 11% | 12% |
| canada | 879 | 974 | 1030 | 11% | 6% | 17% |
| citm_catalog | 2393 | 2424 | 2461 | 1% | 2% | 3% |
| gsoc-2018 | 3687 | 4333 | 4367 | 18% | 1% | 18% |
| github_events | 2411 | 2366 | 2606 | -2% | 10% | 8% |

(Each percentage is the speedup from removing those checks.)

## String scanning kernels

`SCAN` and the word types in `std/json.rig`, one build each (rig-safe):

| file | bytes (1) | U64 | I64 | U128 read | I128 read | U128 from two U64 reads |
|---|---:|---:|---:|---:|---:|---:|
| twitter | 1639 | 1676 | 1671 | 1410 | 1418 | 1504 |
| canada | 1091 | 1085 | 1082 | 1083 | 1092 | 1084 |
| citm_catalog | 2118 | 2131 | 2139 | 2032 | 2032 | 2074 |
| gsoc-2018 | 2030 | 4071 | 4072 | 3475 | 3513 | 4059 |
| github_events | 1756 | 2516 | 2503 | 2238 | 2247 | 2401 |

These kernels only test whether a block holds a special byte and then
search it a byte at a time. Finding the byte's position from the mask
(`first_marked64`, a stand-in for a count of trailing zeros) and
checking UTF-8 a run at a time then gave, against the U64 column:
gsoc-2018 +14%, github_events +14%, citm_catalog +5%, but twitter -11%:
its Japanese text sent every multi-byte character back through a
block read that failed at once. Checking UTF-8 a run at a time fixed
that (twitter 1810 in a later run; across runs, allow 10%). That is
the kernel `std/json.rig` keeps.

- **Signed or unsigned:** no difference beyond 1%. The kernel tests the
  top bit of every byte, not only the word's, so a sign test saves
  nothing, and the instructions are the same.
- **U128:** `read[U128]` assembles its 16 bytes almost one at a time
  (eleven `ldrb`, one `ldur` and shifts in the aarch64 code; see "Wide
  reads" below); two U64 reads recover most of the loss. Even then a
  U128 step is two 64-bit steps with carries, so it does not beat U64
  on a 64-bit machine.
- **Bytes against U64:** string-heavy files gain up to 2x (gsoc-2018).

## Other SWAR

- **Whitespace, 8 spaces at a time:** citm_catalog (indented with
  spaces) +25%, the others unchanged. Kept.
- **Digits, 8 at a time** (simdjson's `parse_eight_digits`): canada -4%
  in one run and +8% (fractions only) in another, the other files -6%
  to +2%: no gain beyond code-layout noise, with three bounds checks per
  8-byte read. Not kept.

## String lengths

`bench/json/json-string-stats.py`: raw bytes between the quotes.

| file | kind | count | <=16 | <=32 | <=64 | <=128 | mean | bytes in >32 | escaped | non-ASCII |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | keys | 13345 | 71% | 99% | 100% | 100% | 12.5 | 4% | 0.0% | 0.0% |
| twitter | values | 4754 | 51% | 69% | 82% | 94% | 42.5 | 82% | 6.6% | 15.9% |
| canada | keys | 8 | 100% | 100% | 100% | 100% | 6.6 | 0% | 0.0% | 0.0% |
| canada | values | 4 | 75% | 100% | 100% | 100% | 9.2 | 0% | 0.0% | 0.0% |
| citm_catalog | keys | 25869 | 96% | 100% | 100% | 100% | 7.9 | 0% | 0.0% | 0.0% |
| citm_catalog | values | 735 | 47% | 91% | 100% | 100% | 22.3 | 16% | 0.1% | 14.7% |
| gsoc-2018 | keys | 18960 | 93% | 100% | 100% | 100% | 7.0 | 0% | 0.0% | 0.0% |
| gsoc-2018 | values | 15168 | 30% | 61% | 70% | 84% | 186.6 | 95% | 11.3% | 0.0% |
| github_events | keys | 1139 | 97% | 100% | 100% | 100% | 6.9 | 0% | 0.0% | 0.0% |
| github_events | values | 752 | 23% | 45% | 83% | 93% | 50.6 | 86% | 0.7% | 0.3% |

## Other files

| file | rig-safe | rig-nocheck | zig-tape-fast |
|---|---:|---:|---:|
| twitterescaped (every non-ASCII character a `\u` escape) | 862 | 1044 | 541 |
| numbers | 1098 | 1278 | 650 |
| mesh | 901 | 1039 | 515 |

## Wide reads

`read[U128]` lowers to `std.mem.readInt(u128, bytes[i..][0..16])`,
which is `@bitCast` of a `[16]u8`. LLVM's SROA splits that array into
16 bytes whenever `i128` is not a native integer width, which is every
target: aarch64-macos, x86_64-linux (baseline and x86_64_v3) and
wasm32 (with and without simd128) all load it a byte at a time, in
ReleaseFast and ReleaseSafe alike. Loading through a `@Vector(16, u8)`
gives one `ldp` on aarch64, two `mov` on x86_64, two `i64.load` on
wasm32 and one `v128.load` with simd128; for 8 bytes and less it is
the same code as today. `writeInt` has the same fault (sixteen byte
inserts; `stp` through a vector).

An experiment, never a build mode: rig-safe's emitted Zig with
`readInt` loading through `@Vector(n, u8)`, built `-OReleaseSafe`
(`vec`). The U64 columns are the kept kernel (`SCAN = 8`); the U128
columns set `SCAN = 16`, and "U128 read" replaces its two U64 reads
with one `read[U128]`. A loaded machine, so compare within the table.

| file | U64 | U64, vec | U128 from two U64 reads | U128 read | U128 read, vec |
|---|---:|---:|---:|---:|---:|
| twitter | 1620 | 1603 | 1503 | 1366 | 1492 |
| canada | 780 | 840 | 789 | 837 | 812 |
| citm_catalog | 2100 | 2165 | 2123 | 2012 | 2179 |
| gsoc-2018 | 3667 | 3528 | 3362 | 2753 | 3505 |
| github_events | 2086 | 2110 | 1970 | 1638 | 1998 |

The vector lowering makes one U128 read as fast as two U64 reads
(+9% twitter, +27% gsoc-2018, +22% github_events against today's U128
read), and moves the U64 kernel only within noise (-4% to +8%). U64 is still
the kernel to keep.

## Against the fastest Zig and Rust parsers

`bench/json/bench-json`'s method, with the competitors' harnesses outside the
repo: each reads the file once, untimed, then times N complete parses.
Builds under `cpuq run --cores 2-6`; timing under `cpuq run --exclusive
--cores 1`, but exclusive runs are off on this machine, so the timing
ran as an ordinary one-core job beside others. Every variant's runs
interleaved, the fastest of 9 kept. A first session (fastest of 7) ran
7-10% slower across the board, with the same ratios.

| file | bytes | rig-safe | zig std.json tape | zimdjson | serde_json | simd-json tape | simd-json value | sonic-rs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | 631514 | 2135 | 971 | 3602 | 645 | 3435 | 1688 | - |
| canada | 2251051 | 1067 | 695 | 1319 | 664 | 1298 | 645 | - |
| citm_catalog | 1727204 | 2826 | 1565 | 3905 | 994 | 4036 | 1670 | - |
| gsoc-2018 | 3327831 | 4792 | 652 | 3800 | 1827 | 3849 | 2944 | - |
| github_events | 65132 | 2759 | 1067 | 3963 | 827 | 3663 | 2077 | - |

With sonic-rs and Rig's fast mode, from a later session at a load
average of 12-14 (so every column runs 15-30% slower than above; compare
within the table):

| file | bytes | rig-safe | rig-fast | zig std.json tape | zimdjson | serde_json | simd-json tape | sonic-rs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | 631514 | 1498 | 1493 | 711 | 3078 | 546 | 2519 | 1951 |
| canada | 2251051 | 657 | 753 | 451 | 766 | 448 | 797 | 1197 |
| citm_catalog | 1727204 | 1828 | 1857 | 993 | 2285 | 573 | 2272 | 2309 |
| gsoc-2018 | 3327831 | 2987 | 3304 | 444 | 2270 | 1046 | 2665 | 4698 |
| github_events | 65132 | 1978 | 2014 | 733 | 2660 | 561 | 2369 | 2560 |

- **sonic-rs** 0.5.10 (`from_slice::<sonic_rs::Value>`, default
  features, `target-cpu=native`, NEON): a full DOM, dropped inside the
  timed loop. Checked here: 3293 of 3293 generated floats exact (random
  doubles and halfway points), and a lone `"\ud800"`, `[1,]`, `012` and
  `1e400` rejected; invalid UTF-8 is rejected by default (`utf8_lossy`
  off). It keeps duplicate keys. It is the fastest parser measured on
  canada and gsoc-2018, where an earlier session without it had Rig
  ahead of every parser.
- **rig-fast** (`rig build --release=fast`) drops overflow and
  conversion checks, which makes an overflow undefined behavior; indexing
  stays checked. std.json is meant for `--release`, the safe mode.

Other builds, from the same session:

| file | zimdjson safe | zimdjson on-demand | serde_json float_roundtrip | simd-json tape, generic CPU | serde_json, generic CPU |
|---|---:|---:|---:|---:|---:|
| twitter | 3422 | 2117 | 637 | 3422 | 655 |
| canada | 1206 | 946 | 467 | 1290 | 667 |
| citm_catalog | 3827 | 2468 | 989 | 3995 | 994 |
| gsoc-2018 | 4053 | 3044 | 1803 | 3918 | 1851 |
| github_events | 3662 | 2307 | 826 | 3689 | 841 |

- **rig-safe** and **zig std.json tape** (`zig-tape-fast`) are built as
  in the first table: both scalar, and Rig with no `raw`.
- **zimdjson** (Zig, a simdjson port, NEON): its DOM parser,
  `-OReleaseFast`, one parser reused. It needed 13 small patches for Zig
  0.17 (removed `**`, `std.meta.Int`, `std.BoundedArray`, `@Type`, and
  renamed enums), none changing what the parser does. The input is
  read once into a buffer padded with 16 spaces, its vector width
  (`assume_padding`), as simdjson requires; the Rig parser needs no
  padding. It validates the
  whole document and its UTF-8, and converts numbers exactly (Clinger,
  Eisel-Lemire, then a big-integer fallback; overflow is an error). It
  does more string work than Rig: it copies every string, escaped or
  not, into its buffer. Integers beyond `u64` become the nearest f64.
  Depth limit 1024, as Rig's. The on-demand API with every value
  visited, every string and key unescaped and every number converted
  is slower than its DOM.
- **serde_json** 1.0.151: `from_slice::<Value>`, a DOM with a
  `BTreeMap` per object, allocated per parse (no reuse API). It
  validates everything and decodes every escape. **Its default float
  parsing is not correctly rounded** (`2.2250738585072011e-308` and a
  66-digit number come out wrong); `float_roundtrip` fixes that, at a
  cost on canada. Duplicate keys: the last wins.
- **simd-json** 0.18.1, default features (`swar-number-parsing`, no
  `approx-number-parsing`), NEON chosen at compile time, so
  target-cpu=native changes nothing. Floats are correctly rounded
  (Eisel-Lemire, then Rust's `parse::<f64>`); an integer beyond `u64`
  or `i64` is an error, not a float. It validates UTF-8 over the whole
  input. It parses in place and overwrites its input, so every parse
  first copies the input into a reused buffer, inside the timed loop:
  a copy runs at 69-95 GB/s here, about 5% of a parse. **tape**:
  `fill_tape` with reused `Buffers` and tape, the closest to Rig's.
  **value**: simd-json's `Value` parse with reused buffers, a DOM allocated per
  parse. It keeps duplicate keys, and accepts a lone high surrogate
  (`"\ud800"`) as U+0000, which Rig rejects.
- **sonic-rs** 0.5.10 is not measured: it needs `faststr` 0.2 (feature
  `serde`), which is not in the local cargo cache, and nothing is
  downloaded without the owner's permission. Every other dependency,
  `zmij` 1.0.23 included, resolves offline.
- Rust: rustc 1.98.1, `opt-level = 3`, fat LTO, one codegen unit,
  `-C target-cpu=native`, the system allocator; release builds keep
  bounds checks and drop overflow checks. The Zig builds use the
  native CPU and `smp_allocator`, as the Rig program does.

## Wide reads after Rig 12c5cef1

Rig #115 lowers `read[U128]` to one wide load. Every variant is rig-safe,
timed in one interleaved session at a load average of 4-5, fastest of 11:
`u64` is the U64 kernel (`SCAN = 8`, what `std/json.rig` ships), `two64`
the U128 kernel with two U64 reads, and `u128` the same kernel with one
`s.read[U128, .little](i)`, built by Rig before (5b148806) and after.

| file | u64 | two64 | u128, before | u128, after |
|---|---:|---:|---:|---:|
| twitter | 2060 | 1901 | 1791 | 1939 |
| canada | 1039 | 1033 | 1029 | 1039 |
| citm_catalog | 2792 | 2677 | 2575 | 2698 |
| gsoc-2018 | 4722 | 4535 | 3749 | 4622 |
| github_events | 2701 | 2581 | 2212 | 2560 |

One U128 read is now 0-23% faster than before and ties two U64 reads.
The U64 kernel stays fastest (2-6%), so `std/json.rig` keeps `SCAN = 8`.

## Parser changes

Changes to `std/json.rig` taken from the sonic-rs and simdjson studies,
one at a time, each kept only if it gained or was neutral and simpler.
Every one passes ``./test/run json`` (5894 of 5894, sanitizer-clean).
Variants are rig-safe builds of scratch copies (`src=NAME`), timed in
one interleaved session on one core. The machine was loaded (load
average 16-20) and exclusive runs are off, so besides wall time the
timer reads the cycles and instructions each run took (`/usr/bin/time
-l`): cycles exclude time descheduled, and they moved less from session
to session than MB/s. Cells are MB/s (fastest of 15) / bytes per
thousand cycles (fewest); compare within the table.

| file | before | UTF-8 | escapes | numbers | change |
|---|---:|---:|---:|---:|---:|
| twitter | 1618 / 465 | 1763 / 504 | 1765 / 500 | 1866 / 523 | +15% / +12% |
| twitterescaped | 801 / 230 | 799 / 231 | 1109 / 322 | 1204 / 336 | +50% / +46% |
| canada | 754 / 226 | 796 / 226 | 786 / 225 | 879 / 263 | +17% / +16% |
| citm_catalog | 2256 / 631 | 2238 / 623 | 2103 / 596 | 2209 / 628 | -2% / 0% |
| gsoc-2018 | 3622 / 1038 | 3325 / 1032 | 3921 / 1105 | 3574 / 1035 | -1% / 0% |
| github_events | 2196 / 608 | 2017 / 587 | 2118 / 589 | 1974 / 593 | -10% / -2% |

citm_catalog, gsoc-2018 and github_events have little non-ASCII text,
few escapes and few floats; their differences are noise. Rechecked at
21-25 runs: github_events 588 to 601 and citm_catalog 613 to 620 bytes
per thousand cycles, and gsoc-2018 from -1% to +1% in two sessions.

- **UTF-8: a 3-byte sequence from one U32 read** (`utf8_end3`). A
  first byte E1-EC or EE-EF with two continuation bytes is tested as
  `w & 0xC0C0F0 == 0x8080E0`; E0, ED and every other sequence go to
  `utf8_end`. twitter (CJK text) gains 7-11% in cycles over four
  sessions. Checking two 3-byte sequences per U64 read
  (`three_byte_pairs`, mask 0xC0C0F0C0C0F0) measured the same on
  twitter and 1-5% worse on the ASCII files; both together were worse
  than either. Kept the simpler U32 form:

  | file | before | U32 | pairs per U64 | both |
  |---|---:|---:|---:|---:|
  | twitter | 438 | 485 | 491 | 468 |
  | citm_catalog | 587 | 571 | 579 | 553 |
  | gsoc-2018 | 982 | 966 | 958 | 930 |
  | github_events | 585 | 575 | 555 | 553 |

  (bytes per thousand cycles)
- **Escapes: back to back, and hex by table.** After an escape, a
  backslash goes straight to the next escape, with no scan and no empty
  copy. `hex4` reads four entries of a 256-entry `HEX` table, -1 where a
  byte is not a hex digit, and ORs them shifted, so one sign test checks
  all four; the old loop now only finds the error's offset. twitterescaped
  827 to 1059 MB/s with the first, 1149 with both (twitter and gsoc-2018
  within noise). The copy between escapes is not fused with the scan:
  that needs word writes onto a `String` (DESIGN.md, "Open items").
- **Numbers: SWAR digits, and a branch-free `leading_zeros`.**
  `take_digits` reads a U64 and takes 8 digits, or the 1 to 7 that end
  the run, with simdjson's three-multiply reduction; only the last 7
  bytes of the input go a byte at a time. The 19-digit limit stays (a
  wrapping `U64` holds 19 digits exactly), so there is no cap at 17 as
  in sonic-rs. `leading_zeros` replaces its six-step halving loop with
  the exponent of the value converted to a Float, after clearing the bit
  below the top one so the conversion cannot round up. Separately, in
  one session (bytes per thousand cycles, canada): before 211, SWAR
  digits 230, the new `leading_zeros` 223, both 251; instructions per
  byte 29.9 to 26.4. With both, canada gains 5-17% across four
  sessions; twitter and citm_catalog move within noise. A first,
  correcting form of the Float trick measured the same and was replaced
  by the simpler one.
- **A real `clz`** (an experiment: `@clz` in the emitted Zig, built
  `-OReleaseSafe`): canada 253 to 279 bytes per thousand cycles, 873 to
  1004 MB/s. The Float conversion is on every number's critical path;
  the bit intrinsics (DESIGN.md, "Open items").
- **Floats: yyjson's one-multiply path, as sonic-rs takes it**
  (`normal_float_bits`). For `m` not 0 and -307 < q < 288 every result
  is normal, so after Clinger the parser skips Eisel-Lemire's subnormal,
  infinity, halfway and overflow branches: unless the top word's low 9
  bits are all zeros or all ones it rounds half up from the first
  product, adds the exponent so the hidden bit and a round up to 2^53
  carry into it, and otherwise takes the second product or hands the
  number to `eisel_lemire`. 91% of canada's numbers have 17 digits and
  take this path. Measured on Rig main 990221765, with the parser
  already on `x.leading_zeros()`, `x.trailing_zeros()` and `<<%`
  (`before`); cells are MB/s / bytes per thousand cycles /
  instructions per byte, fastest of 15 at a load average of 23-30:

  | file | before | float path | and guards |
  |---|---:|---:|---:|
  | twitter | 1982 / 569 / 12.17 | 2002 / 566 / 12.14 | 1943 / 560 / 12.20 |
  | twitterescaped | 1313 / 371 / 17.97 | 1199 / 365 / 17.96 | 1258 / 365 / 18.05 |
  | canada | 1111 / 324 / 21.08 | 1170 / 340 / 20.27 | 1194 / 351 / 20.55 |
  | citm_catalog | 2381 / 691 / 10.18 | 2385 / 692 / 10.14 | 2170 / 656 / 10.14 |
  | gsoc-2018 | 3732 / 1126 / 5.46 | 3943 / 1167 / 5.45 | 3904 / 1135 / 5.58 |
  | github_events | 2365 / 670 / 10.25 | 2324 / 672 / 10.25 | 2348 / 651 / 10.40 |

  The float path gains 3-6% on canada in cycles over three sessions
  (fastest of 15, 15 and 41), with 4% fewer instructions; the other
  files move within noise. With the guards too, canada moved -3% to +8%
  over four sessions. Beyond ``./test/run json``, 2.1 million generated
  numbers (ties near every power of two to 2^63, 15- to 19-digit
  numbers next to halfway points, exponents at the path's edges)
  matched Python bit for bit.
- **Entry guards** for checks the compiler proves away:
  `take_digits` and `skip_plain_ascii` return `at` when it is outside
  `0..s.len` (no digits, nothing skipped), and `skip_space` when it is
  negative; its loop already tests `i < s.len` before each read. The
  guards add 1-2% instructions (canada, gsoc-2018, github_events) and
  move cycles within noise. The full guard in `skip_space` stopped
  LLVM inlining it at its six call sites (canada 12% slower in cycles,
  10% more instructions, on the Rig before 990221765): comparing with
  `s.len` converts the length to an `Int` with a check and a panic
  path.
- **Not kept:** `m <<% lz` for the normalizing shift, which drops a
  check that cannot fail: 1% fewer instructions on canada, cycles +7%
  in one session and -3% in another.

Not changed:

- **Per-container dispatch** (separate object and array loops, or the
  container kind in a local): measured -4% to 0% in the profiling study;
  the cost at a separator is branch prediction, not the stack read.
- **Fewer tape pushes:** a float's 64 bits cannot share an entry with
  a 4-bit tag, so one push per float would need NaN-boxing, a new tape
  format and reader, against the gain Rig's inlined `List.push` will
  give every program (DESIGN.md, "Open items"). Reserving capacity up front
  does not apply: the Doc reuses its lists, so a warm parse never grows
  them.
- **SWAR whitespace and sonic-rs's non-space bitmap:** measured slower
  before (both); not tried again.


## Rig runtime and compiler rounds

Rig PRs measured on this parser before they merged: each branch
merged with main c81480105 in a scratch clone, rig-safe, fastest of 15
interleaved runs at a load average of 8-14. Cells are MB/s, with the
change in cycles per byte against main. A rerun of main's own binary
moved by up to 4%.

| file | main | rtfast (#121) | forcast (#120) |
|---|---:|---:|---:|
| twitter | 2082 | 2178 (+6.3%) | 2016 (-0.8%) |
| twitterescaped | 1293 | 1409 (+8.2%) | 1272 (-1.2%) |
| canada | 987 | 1031 (+5.6%) | 982 (0.0%) |
| citm_catalog | 2400 | 2596 (+8.5%) | 2393 (-0.3%) |
| gsoc-2018 | 4035 | 4490 (+9.4%) | 4132 (+0.7%) |
| github_events | 2420 | 2528 (+4.5%) | 2429 (+0.7%) |

- **rtfast** (inline `List.push` and `String.push`, `String.add` of one
  slice straight to the buffer, `String.clear` without a memset) gains on
  every file.
- **forcast** (no per-iteration index cast in `for c, k in ...`) is
  neutral here: the digit loop it was measured on is now a `while` loop.
- **The stack protector** costs nothing above noise once rtfast is in:
  rebuilding rtfast with `-fno-stack-protector` moved files by -2.8% to
  +1.5% in cycles, mean -0.3%.

## Where the parser stands

One interleaved session, every parser, fastest of 11 runs of about 400
ms at `cpuq --cores 1`, load average 10-12. MB/s.

- **json-start:** `std/json.rig` as first committed (7c3821b), built by
  Rig main c81480105.
- **json-now:** `std/json.rig` today, on Rig main d47fb6ac.
- **json-rtfast:** the same, on Rig main plus rtfast (#121).

All three are rig-safe: every bounds and overflow check kept.

| file | json-start | json-now | json-rtfast | zig std.json | zimdjson | serde_json | simd-json | sonic-rs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | 1582 | 1650 | 1788 | 734 | 2457 | 462 | 2511 | 2172 |
| twitterescaped | 789 | 1083 | 1184 | 539 | 1764 | 381 | 1009 | 2059 |
| canada | 763 | 842 | 909 | 500 | 892 | 512 | 925 | 1382 |
| citm_catalog | 2097 | 2009 | 2194 | 1129 | 2551 | 648 | 2723 | 2533 |
| gsoc-2018 | 3437 | 3549 | 3934 | 509 | 2713 | 1243 | 2845 | 5010 |
| github_events | 2039 | 1967 | 2267 | 792 | 2919 | 576 | 2667 | 2738 |

## SIMD, round 1 (Rig branch `simd`, before it merged)

The drafted scans, adapted to Rig's `Simd[T, n]` in 22 variants, all
passing 10,495 of 10,495 on Rig's `simd` branch (c94e359c3). Interleaved,
rig-safe, under heavy load (about ±7% in cycles), so instructions per
byte are the exact measure.

- **16-lane string scan: adopt.** gsoc-2018 +13% to +22% over five runs;
  3-20% fewer instructions per byte on every file (gsoc 4.34 against
  5.46). Elsewhere within noise. It is the `simd` draft (not in this tree), which
  becomes `std/json.rig` once Rig merges `simd`.
- **64-lane blocks: not yet.** `any()` over 64 lanes and `bits()`'s last
  step compile poorly on aarch64 (reported to Rig with fixes); 16 then 64
  lost 5-30%.
- **Vector whitespace: not yet.** Any vector code in `skip_space` makes
  LLVM outline it at its six call sites (+2.2 instructions per byte on
  canada). It waits for Rig's inlining round.
- **Tails.** The byte loop at the end of a document costs nothing
  measurable (at most about 60 bytes a parse). The owner's overlapping
  last read works in safe Rig and passes every test, with one subtlety:
  shift the word or mask down rather than mask off its low bytes, since a
  quote before the scan's start can carry into the next byte in SWAR.

### SIMD with the fixes, and with inlining (instructions per byte)

Rig `simd` 0cba49eb1 (with the `fmov` and `@select` mask fixes), and the
same merged with `inline` c793cbb39. Load was about 40, so these are
instructions retired per byte, which load does not change; every variant
passes 10,495 of 10,495. Geomean over the six files:

| variant | simd | simd + inline |
|---|---:|---:|
| scalar parser (3fc96ea) | +4.6% | +8.9% |
| 16-lane string scan (`json-simd.rig.draft`) | 0 | 0 |
| 16, then 64-lane `bits() != 0` blocks, scalar whitespace | -3.9% | -2.5% |
| the same, plus vector whitespace split into an inlined entry and an out-of-line run (`json-simd64.rig.draft`) | +0.6% | **-13.0%** |
| 64-lane `any()` before `bits()` | +7.1% | +10.3% |

Columns compare within one compiler; inlining also lowers every row by
7.5-25%. With both, the best variant runs 20% fewer instructions per byte
than the scalar parser: twitter -12%, citm -21%, gsoc -19%, github -21%
against the 16-lane scan, canada +2%.

- **Inlining is what makes vector whitespace pay**: without it, LLVM
  keeps the small entry out of line at six call sites (+12% on canada).
- **`any()` over 64 lanes** still compiles to four 16-lane bitmasks in a
  loop, because LLVM turns the `umaxv` form back into a bitcast; write
  `bits() != 0` until Rig calls the intrinsic directly.

### Rig #126 (checks the compiler proves away, round 1)

Parser 686c5ae on Rig main facc5e672 against #126 merged with that main;
instructions retired per byte (exact). Tests pass: 10,495 and 131.

| file | main | #126 | change |
|---|---:|---:|---:|
| twitter | 12.163 | 11.640 | -4.3% |
| twitterescaped | 16.699 | 15.852 | -5.1% |
| canada | 20.432 | 19.825 | -3.0% |
| citm_catalog | 10.080 | 9.793 | -2.8% |
| gsoc-2018 | 5.545 | 5.038 | -9.1% |
| github_events | 10.343 | 9.810 | -5.2% |

## Preview: Rig main plus proofs, inline and simd

All three in-flight Rig rounds merged in a scratch clone (main facc5e672
+ proofs 17a670f0b + inline c793cbb39 + simd 8891f1d74), before any of
them landed; proofs is since being redesigned for soundness, so its share
is provisional. Tests pass: 10,495 and 131. MB/s, best of two interleaved
sessions of 15 runs at load 10.5-13 (sessions differ by 4-6%).

| file | json start | json on main | **json on stack** | json SIMD (c2) on stack | Zig std.json | zimdjson | serde_json | simd-json | sonic-rs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | 1695 | 1901 | **2702** | 1756 | 762 | 3042 | 466 | 2542 | 2431 |
| twitterescaped | 803 | 1438 | **1876** | 1679 | 549 | 2023 | 377 | 1025 | 2042 |
| canada | 802 | 1155 | **1260** | 1226 | 499 | 931 | 490 | 959 | 1448 |
| citm_catalog | 2092 | 2360 | **2987** | 2137 | 1181 | 2677 | 702 | 3394 | 2739 |
| gsoc-2018 | 3705 | 4231 | **5197** | 4208 | 527 | 2845 | 1247 | 2785 | 5483 |
| github_events | 2105 | 2350 | **3444** | 2014 | 882 | 3238 | 641 | 2773 | 2800 |
| geomean | 1616 | 2049 | **2644** | 2008 | 697 | 2282 | 603 | 2008 | 2591 |

- **The scalar parser on the stack** matches sonic-rs overall (1.02x by
  geomean): ahead on twitter, citm and github_events, behind on
  twitterescaped (0.92), canada (0.87) and gsoc (0.95). It beats
  zimdjson on four files, simd-json on five, and every parser on
  github_events. Most of the gain is inlining.
- **The SIMD scan (c2) is slower in time** (0.78x of sonic-rs) although it
  retires 7-44% fewer instructions per byte on five files. Each string's
  end crosses from vector to integer registers twice (`umaxv` + `fmov`,
  then the bitmask + `fmov` + `ctz`), a long dependency chain the 8-byte
  SWAR scan does not have. Instruction counts alone misjudged it; the
  next step is a cheaper first-true-lane lowering (`shrn` nibble mask).

### Rig #125 (inlining), after its review fixes

Parser 686c5ae on Rig main facc5e672, on #125 before its fixes
(c793cbb39), and after (e91025da5, which reads inlined results through
`rig.rt`). Tests pass: 10,511 and 131. Fastest of 15 interleaved; load
rose to 38 during the run, so instructions are the steady measure.

| file | main MB/s | #125 MB/s | #125 cycles vs main | `rig.rt` (new vs old), instructions |
|---|---:|---:|---:|---:|
| twitter | 1965 | 2367 | +22% | +0.5% |
| twitterescaped | 1494 | 1805 | +23% | -0.9% |
| canada | 1176 | 1207 | +1% | -0.2% |
| citm_catalog | 2373 | 2840 | +20% | +0.1% |
| gsoc-2018 | 3906 | 4602 | +16% | +0.3% |
| github_events | 2329 | 2891 | +23% | +0.8% |

### Tiered string scan: 16 bytes of SWAR, then SIMD (the owner's design)

A string's first 16 bytes are scanned with U64 SWAR, as today; only a
longer string switches to 16-lane SIMD, its exit lowered to the nibble
mask (`shrn #4`, one `fmov`, `ctz >> 2`: the lowering Rig's `m.first()`
will have; measured here by patching the emitted Zig). Whitespace and
digits are unchanged. Tests pass (10,511) through the patched build; two
interleaved sessions, fastest of 15, load about 11; the noise floor is
about ±5%. Cycles against today's scalar parser:

| file | 16-lane SIMD, nibble exit | **tiered (16 SWAR, then SIMD)** | tiered, 32 SWAR |
|---|---:|---:|---:|
| twitter | -3%, -5% | -2%, -3% | -5%, -3% |
| twitterescaped | -5%, -7% | 0%, -2% | -2%, -1% |
| canada | +3%, -1% | +6%, -6% (noise) | +5%, -4% |
| citm_catalog | 0%, -1% | 0%, 0% | -1%, -1% |
| gsoc-2018 | +7%, +12% | **+17%, +13%** | +10%, +9% |
| github_events | +1%, -4% | +2%, +3% | 0%, -2% |

Tiered is the first SIMD scan that loses nowhere beyond noise and wins
clearly on long strings: SWAR handles the short strings most documents
are made of without touching the vector unit. It is
the tiered draft (not in this tree), which becomes `std/json.rig` once Rig ships
`Simd` and `m.first()`.

## Closing the canada and escape gaps

Changes to `std/json.rig`, each kept only if it passed the tests and won
in time over several interleaved sessions:

- **Two `\uXXXX` escapes at once:** decoding two three-byte characters
  back to back (escaped CJK text) in two pushes instead of four.
  twitterescaped +19% in cycles. Of its 31,818 `\u` escapes, 31,770 are
  three-byte characters and only 10 are surrogate pairs.
- **The digit loop's byte tail in its own function**, so `take_digits`
  inlines and `m` stays in a register: canada +5% cycles, -9%
  instructions.
- **Clinger's fast path chosen by digit count (15 or fewer)**, not by
  `m <= 2^53`: canada +6-7%.
- **The innermost container in a local `top`**, not
  `stack[stack.len - 1]`: -1% to -2% instructions everywhere.
- **`skip_space` returns at once on a byte above space:** +8% on canada
  and escaped text, -4% on citm.
- **`peek(src, i)`** (0 outside `src`) in the number scan, and **an
  escape lookup table**: +3% to +4.5%.

Tests: 10,511 of 10,511 (16 new cases for the paired escapes). On Rig
main 795bcd8e3, instructions per byte fall on every file: twitter -4%,
twitterescaped -18%, canada -11%, citm -3%, gsoc -1.5%, github -3%.

Against sonic-rs, on Rig main plus the proofs, inline and simd branches
(fastest of 21, interleaved, load 7-23; MB/s):

| file | std.json | sonic-rs | std.json / sonic |
|---|---:|---:|---:|
| twitter | 3234 | 2957 | 1.09 |
| twitterescaped | 2900 | 2655 | 1.09 |
| canada | 1922 | 1823 | 1.05 |
| citm_catalog | 3778 | 3544 | 1.07 |
| gsoc-2018 | 5973 | 6579 | 0.91 |
| github_events | 3786 | 3529 | 1.07 |

Over five sessions, twitterescaped ran 1.08-1.15x sonic-rs and canada
0.99-1.08x. gsoc-2018 is long strings, where the tiered SIMD scan
(+13% to +17%) is expected to close the gap once Rig ships `Simd` and
`m.first()`.

## Every parser, one quiet session

The quietest timing of the day (load 3.5-5). One interleaved session,
fastest of 15 runs of about 400 ms, `cpuq --cores 1`. MB/s.

- **json-start:** `std/json.rig` as first committed (7c3821b).
- **json-main:** today's `std/json.rig` (13899b9) on Rig main 795bcd8e3.
- **json-stack:** the same on Rig main plus proofs, inline and simd.

| file | json-start | **json-main** | **json-stack** | Zig std.json | zimdjson | serde_json | simd-json | sonic-rs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | 2135 | 3311 | 3386 | 974 | **3614** | 650 | 3466 | 3087 |
| twitterescaped | 1064 | **3079** | 3009 | 661 | 2772 | 549 | 1342 | 2735 |
| canada | 1070 | 1938 | **2035** | 714 | 1324 | 673 | 1314 | 2004 |
| citm_catalog | 2874 | 3758 | 3987 | 1562 | 3915 | 1010 | **4056** | 3769 |
| gsoc-2018 | 4889 | 6222 | 6412 | 659 | 3838 | 1859 | 3930 | **7215** |
| github_events | 2787 | 3865 | **4004** | 1062 | 3964 | 847 | 3686 | 3675 |
| **geomean** | 2137 | 3483 | **3585** | 892 | 3040 | 852 | 2666 | 3452 |

- **It beats sonic-rs overall:** 1.01x by geomean on Rig main, 1.04x
  on the stack. Per file on the stack: twitter 1.10, twitterescaped
  1.10, canada 1.02, citm 1.06, github 1.09, gsoc 0.89.
- **It is the fastest parser measured** on twitterescaped, canada and
  github_events, and highest by geomean.
- **Since the first commit:** +63% by geomean on Rig main (2137 to 3483).
- **Against the reference parsers:** 3.9x Zig's std.json and 4.1x
  serde_json.
- **gsoc-2018 is the one file left:** long strings, where the tiered
  SWAR-then-SIMD scan measured +13% to +17%.

## Every file ahead of sonic-rs: the tiered scan on today's parser

The tiered scan is the scalar parser with only `skip_plain_ascii`
replaced: 16 bytes of U64 SWAR, then a 16-lane SIMD loop with an
overlapping 16-byte tail. Measured before Rig had `m.first()`, its exit
used the nibble mask (`shrn #4`, one `fmov`, `ctz >> 2`), the lowering
`m.first()` now has, patched into the emitted Zig
(`bench/json/timers/nibble.py`). Built on Rig main plus proofs, inline
and simd. Tests: 10,511 of 10,511 through the patched build. Four
interleaved sessions at load 4-8, fastest of 15; MB/s, best across
sessions, with the ratio to sonic-rs:

| file | scalar parser | **tiered scan** | sonic-rs |
|---|---:|---:|---:|
| twitter | 3346 (1.10x) | 3229 (1.06x) | 3044 |
| twitterescaped | 2990 (1.10x) | 2871 (1.06x) | 2718 |
| canada | 2014 (1.03x) | 2012 (1.03x) | 1957 |
| citm_catalog | 3965 (1.07x) | 3961 (1.07x) | 3716 |
| gsoc-2018 | 6421 (0.91x) | **7195 (1.02x)** | 7078 |
| github_events | 3950 (1.08x) | 3970 (1.09x) | 3656 |

- **gsoc** gains 12% and passes sonic-rs, though thinly: the four
  sessions gave 1.01x, 0.98x, 1.02x and 1.02x.
- **The cost:** a steady 3-4% against the scalar parser on twitter and
  twitterescaped, both still ahead of sonic-rs.
- **Switching to SIMD after 8 bytes** is no better on gsoc. **A 32-lane
  middle loop** reaches 1.04x on gsoc but loses 7-9% on twitter.

## std.json on Rig main: the tiered scan with `m.first()`

`std/json.rig` as it lands: the tiered scan with Rig's own `m.first()`,
on Rig main d948f6af7, which does not have the proofs round (checks the
compiler proves away). The "SWAR only" column is the parser before the
tiered scan (54b834f20, `rig-safe@src=swar`). Every Rig build is
`--release`, the safe mode, with every check kept. One quiet session
(no other jobs, 1-minute load 2-3; `bench/json/timers/time.py`, fastest
of 15 interleaved runs of about 400 ms), Apple silicon, MB/s. Two
earlier sessions at a load of 4-6 agreed within 2%.

| file | **std.json** | SWAR only | sonic-rs | simd-json (tape) | serde_json | Zig std.json (tape, safe) |
|---|---:|---:|---:|---:|---:|---:|
| twitter | **3219** | 3291 | 3101 | 3465 | 665 | 876 |
| twitterescaped | **3029** | 3111 | 2815 | 1355 | 555 | 625 |
| canada | **1945** | 1948 | 2012 | 1320 | 676 | 573 |
| citm_catalog | **3757** | 3771 | 3776 | 4093 | 1012 | 1221 |
| gsoc-2018 | **7021** | 6308 | 7217 | 3931 | 1856 | 628 |
| github_events | **3945** | 3910 | 3739 | 3710 | 855 | 969 |

Against sonic-rs, std.json is:

| file | std.json against sonic-rs |
|---|---|
| twitter | 4% faster |
| twitterescaped | 8% faster |
| canada | 3% slower |
| citm_catalog | 1% slower |
| gsoc-2018 | 3% slower |
| github_events | 6% faster |

- **On main it beats sonic-rs on three of the six files** and is within
  3% on the rest. Trig measured every file ahead (the section above) on
  Rig main plus the proofs round, which is not on main: the checks it
  proves away cost about 11% on canada and 18% on gsoc-2018 ("What the
  checks cost").
- **The second tier pays where strings are long:** gsoc-2018 is 11%
  faster than SWAR only, github_events 1% faster. It costs 2% on
  twitter and 3% on twitterescaped, and is level on canada and
  citm_catalog.
- **Against the others:** 3.1-11x Zig's std.json (safe), 2.9-5.5x
  serde_json, and ahead of simd-json's tape on four of the six files.
