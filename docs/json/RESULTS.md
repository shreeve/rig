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

**Which harness.** Every table before "The honest harness" (at the end)
times a driver that calls `parse` once, so LLVM inlined the whole parser
into the benchmark's `main` and kept the Doc's fields in registers. A
program that parses from more than one place does not get that, and on
the Mac std.json is 3-12% slower without it. Those tables flatter
std.json by that much against parsers whose code stays out of line;
compare across them only by the ratios within one table.

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

## Linux x86 (pup), and the string-scan sweep

Machine: pup, an Intel Core Ultra 9 185H (22 threads, AVX2 and BMI2, no
AVX-512), Linux, Zig 0.17.0. Rig is main at f09357281 plus the bench
tooling of this branch; sonic-rs 0.5.10, simd-json and serde_json are built
`-C target-cpu=native`. Timing: `bench/json/xbench.sh time`, run under
`cpuq run --exclusive` (the window's other load was 0.2 CPUs), pinned to one
P core with `taskset`, interleaved, the fastest of 15 runs of about 400 ms.
The Mac numbers are from the same script, at a load of about 3
(`--exclusive` is off on the Mac), fastest of 15. Every figure is
std.json (`rig build --release`, every check kept) against sonic-rs
on that machine, as "faster" or "slower" than sonic-rs's MB/s.

### Every parser, pup

The landed scan (a 16-byte SWAR stage, then 16-lane SIMD), MB/s, and
against sonic-rs:

| file | std.json | sonic-rs | simd-json (tape) | zimdjson (DOM, fast) | serde_json | Zig std.json (tape, safe) | Zig std.json (tape, fast) |
|---|---:|---:|---:|---:|---:|---:|---:|
| twitter | 2193 (19% slower) | 2701 | 2445 (9% slower) | 4254 (57% faster) | 375 (86% slower) | 681 (75% slower) | 790 (71% slower) |
| twitterescaped | 2057 (4% slower) | 2153 | 1417 (34% slower) | 2835 (32% faster) | 325 (85% slower) | 468 (78% slower) | 555 (74% slower) |
| canada | 1252 (11% slower) | 1404 | 1084 (23% slower) | 940 (33% slower) | 345 (75% slower) | 388 (72% slower) | 523 (63% slower) |
| citm_catalog | 2490 (29% slower) | 3484 | 2575 (26% slower) | 4461 (28% faster) | 676 (81% slower) | 742 (79% slower) | 1022 (71% slower) |
| gsoc-2018 | 4457 (12% slower) | 5089 | 3484 (32% slower) | 5344 (5% faster) | 1166 (77% slower) | 435 (91% slower) | 433 (91% slower) |
| github_events | 2633 (30% slower) | 3769 | 2735 (27% slower) | 4921 (31% faster) | 423 (89% slower) | 617 (84% slower) | 727 (81% slower) |

std.json is 18% slower than sonic-rs by geomean on pup (4% to 30% slower
file by file), where on the Mac it is 1% faster. zimdjson, which uses AVX2
for its structural pass, is the fastest here (5% to 57% faster than
sonic-rs on five files; 33% slower on canada). Zig's own std.json is 63% to 91% slower.

### Cycles and instructions per byte, pup

`perf stat` on the P core (`xbench.sh perf`; cycles and instructions of N
parses minus one, over N - 1 and the file's size, the least of 3). These
don't depend on load.

| file | rig-safe cycles/byte | sonic-rs | rig-safe instructions/byte | sonic-rs | rig-safe IPC | sonic-rs |
|---|---:|---:|---:|---:|---:|---:|
| twitter | 2.173 | 1.779 | 10.965 | 7.973 | 5.05 | 4.48 |
| twitterescaped | 2.264 | 2.160 | 12.358 | 10.553 | 5.46 | 4.89 |
| canada | 3.727 | 3.365 | 19.230 | 16.103 | 5.16 | 4.78 |
| citm_catalog | 1.981 | 1.426 | 10.263 | 6.370 | 5.18 | 4.47 |
| gsoc-2018 | 1.029 | 0.995 | 4.639 | 2.577 | 4.51 | 2.59 |
| github_events | 1.747 | 1.225 | 9.627 | 5.528 | 5.51 | 4.51 |

The gap is instructions: std.json retires 37% to 80% more per byte than
sonic-rs on twitter, citm_catalog, gsoc-2018 and github_events (37%, 61%,
80%, 74%), and only its higher IPC (about 5 against 4.5) hides some of it;
it takes 22%, 39%, 3% and 43% more cycles on those four. On canada and
twitterescaped, where numbers and escapes dominate, it retires 19% and 17%
more and takes 11% and 5% more cycles.

### The string-scan sweep

Bench-only variants of `skip_plain_ascii`: the SWAR stage is `TIER` bytes
(16 landed), then 16-lane or 32-lane SIMD blocks (`bench/json/variants/simd32.py`
rewrites `std/json.rig`; `std/json.rig` itself is unchanged). "SWAR only" is
`TIER = 10^9`: the SIMD loop never runs. The 32-lane rows read the last 32
bytes again at the end of the document, as the 16-lane ones read 16.

String lengths by file (`json-string-stats.py`, from "String lengths"
above): keys are 7 to 12 bytes long and 71% to 100% fit in 16 bytes in every
file; the bytes are in the values. twitter's values average 42 bytes (82% of
the string bytes are in values over 32), gsoc-2018's 187 bytes (95%),
github_events' 51 (86%), citm_catalog's 22 (16%); canada has 12 strings in
all, and twitterescaped's strings are mostly `\u` escapes, which end the scan
at once.

Pup, against sonic-rs:

| variant | twitter | twitterescaped | canada | citm_catalog | gsoc-2018 | github_events | geomean |
|---|---|---|---|---|---|---|---|
| SWAR 16, 16-lane | 19% slower | 4% slower | 11% slower | 29% slower | 12% slower | 30% slower | 18% slower |
| SWAR 32, 16-lane | 19% slower | 5% slower | 11% slower | 29% slower | 13% slower | 31% slower | 19% slower |
| SWAR 64, 16-lane | 19% slower | 5% slower | 11% slower | 29% slower | 16% slower | 32% slower | 19% slower |
| SWAR only, (16-lane tail) | 19% slower | 5% slower | 12% slower | 30% slower | 26% slower | 34% slower | 22% slower |
| SWAR 16, 32-lane | 16% slower | 5% slower | 11% slower | 32% slower | 4% slower | 33% slower | 18% slower |
| SWAR 32, 32-lane | 17% slower | 5% slower | 11% slower | 32% slower | 7% slower | 33% slower | 18% slower |
| SWAR 64, 32-lane | 18% slower | 5% slower | 11% slower | 32% slower | 11% slower | 36% slower | 20% slower |
| SWAR only, (32-lane tail) | 17% slower | 5% slower | 11% slower | 32% slower | 26% slower | 37% slower | 22% slower |
| SWAR 16, 16-lane inlined maskFirst | 19% slower | 4% slower | 11% slower | 29% slower | 12% slower | 30% slower | 18% slower |
| SWAR 16, 32-lane inlined maskFirst | 16% slower | 5% slower | 11% slower | 32% slower | 4% slower | 32% slower | 17% slower |
| SWAR 64, 32-lane inlined maskFirst | 18% slower | 5% slower | 11% slower | 32% slower | 11% slower | 36% slower | 20% slower |

Mac (Apple silicon), against sonic-rs, load about 3:

| variant | twitter | twitterescaped | canada | citm_catalog | gsoc-2018 | github_events | geomean |
|---|---|---|---|---|---|---|---|
| SWAR 16, 16-lane | 4% faster | 7% faster | 4% slower | 2% slower | 3% slower | 6% faster | 1% faster |
| SWAR 32, 16-lane | 4% faster | 9% faster | 4% slower | 2% slower | 3% slower | 3% faster | 1% faster |
| SWAR 64, 16-lane | 5% faster | 9% faster | 3% slower | 2% slower | 6% slower | 3% faster | 1% faster |
| SWAR only, (16-lane tail) | 4% faster | 9% faster | 3% slower | 1% slower | 19% slower | 1% faster | 2% slower |
| SWAR 16, 32-lane | 33% slower | 33% slower | 3% slower | 8% slower | 66% slower | 46% slower | 35% slower |
| SWAR 32, 32-lane | 10% slower | 9% slower | 4% slower | 5% slower | 62% slower | 39% slower | 25% slower |
| SWAR 64, 32-lane | 3% slower | 1% slower | 4% slower | 5% slower | 58% slower | 20% slower | 18% slower |
| SWAR only, (32-lane tail) | 1% slower | 2% faster | 4% slower | 5% slower | 23% slower | 3% slower | 6% slower |

#### Reading the sweep

- **The SWAR stage's length barely matters.** On both machines 16, 32 and 64
  are within 1% to 3% of each other by geomean, and 16 is best or tied
  except on twitter and twitterescaped on the Mac (64 is 1% better, which is
  noise). Only gsoc-2018 (long strings) and github_events move: SWAR 64
  costs gsoc-2018 3% (Mac) to 4% (pup) and github_events 2% to 3%. Dropping
  SIMD altogether (SWAR only) costs gsoc-2018 about 15% on both machines
  and github_events about 5%.
- **Best variant, Mac:** SWAR 16 with 16-lane blocks, the landed one (1%
  faster than sonic-rs by geomean; SWAR 32 and 64 tie it within 1%).
- **Best variant, pup:** SWAR 16 with 16-lane blocks and SWAR 16 with 32-lane
  blocks tie (18% slower than sonic-rs by geomean, a 0.6% difference, which
  is noise). 32 lanes gain 10% on gsoc-2018 (4% slower than sonic-rs against
  12%) and 4% on twitter, and lose 5% on citm_catalog and 4% on github_events.
  So 32-byte blocks do not win on x86 either, except on long-string files.

#### The 32-lane loss on the Mac is Rig's lowering, not the lane count

On aarch64 the 32-lane rows are 18% to 35% slower than sonic-rs (gsoc-2018
58% to 66% slower). The emitted assembly for the 32-lane exit shows why:
the compares and ORs are two `q` registers, but `rig.maskFirst` is not
inlined (`_rig.runtime.maskFirst__func_875`; nothing marks it `noinline`, so
it is LLVM's size heuristic), and its `@Vector(32, bool)` argument crosses
the call as about 56 `umov`, `mov.s` and stack-store lane moves per 32-byte
block. The 16-lane form is inlined and is not affected. With `maskFirst`
declared `pub inline fn` in the emitted runtime (`rig-safeinl`, an experiment,
never a build mode), the 32-lane rows recover:

| variant | twitter | twitterescaped | canada | citm_catalog | gsoc-2018 | github_events | geomean |
|---|---|---|---|---|---|---|---|
| SWAR 16, 16-lane | 4% faster | 9% faster | 1% slower | 1% slower | 2% slower | 6% faster | 2% faster |
| SWAR 16, 16-lane inlined maskFirst | 4% faster | 9% faster | 0% slower | 2% slower | 3% slower | 5% faster | 2% faster |
| SWAR 16, 32-lane inlined maskFirst | 0% slower | 4% faster | 3% slower | 2% slower | 1% faster | 2% faster | 0% faster |
| SWAR 64, 32-lane inlined maskFirst | 1% faster | 9% faster | 1% slower | 2% slower | 4% slower | 1% faster | 0% faster |

(That Mac run began at a load of about 10, so its cells are noisier than the
table above; the 16-lane rows in it agree with the table above within 2%.)
So a 32-lane mask on NEON needs `maskFirst` inlined to be usable, and then
ties the 16-lane scan without beating it. On pup inlining changes nothing (the `inlined
maskFirst` rows above equal the plain ones within 2%); its assembly was not read.

## With proofs2 (Rig main at 2cc2008e6)

The same measurement as "Linux x86 (pup)" above, repeated on main after #138
(proofs2) landed: `bench/json/timers/time.py` on a `rig build --release`
std.json with the landed scan (a 16-byte SWAR stage, 16-lane blocks),
interleaved, the fastest of 15 runs of about 400 ms, each parser against
sonic-rs 0.5.10 on the same machine. The last column is the earlier
table's landed-scan row, the same comparison at f09357281, before #138.
MB/s is 10^6 bytes per second. The geomean is of the six files' ratios.
The two measurements are from different sessions, so allow a few percent
between them.

### Mac (Apple silicon)

The load was 4.5 to 5, a little over the target of 4 (the other Mac jobs
were held; `--exclusive` is off on the Mac).

| file | std.json | sonic-rs | simd-json (tape) | zimdjson (DOM) | std.json vs sonic-rs | simd-json vs sonic-rs | zimdjson vs sonic-rs | std.json vs sonic-rs before #138 |
|---|---:|---:|---:|---:|---|---|---|---|
| twitter | 3359 | 3152 | 3501 | 3641 | 7% faster | 11% faster | 16% faster | 4% faster |
| twitterescaped | 3142 | 2836 | 1371 | 2787 | 11% faster | 52% slower | 2% slower | 7% faster |
| canada | 2027 | 2019 | 1331 | 1339 | 0% faster | 34% slower | 34% slower | 4% slower |
| citm_catalog | 4111 | 3815 | 4125 | 3966 | 8% faster | 8% faster | 4% faster | 2% slower |
| gsoc-2018 | 7547 | 7258 | 3963 | 3875 | 4% faster | 45% slower | 47% slower | 3% slower |
| github_events | 4076 | 3761 | 3737 | 4009 | 8% faster | 1% slower | 7% faster | 6% faster |
| geomean | | | | | 6% faster | | | 1% faster |

Cycles of std.json, from `cyc.py` (wall MB/s, bytes per kilocycle,
instructions per byte; `cyc.py` reads macOS's `time -l`, so sonic-rs, which
it cannot run, has no cycle count here):

| file | MB/s | bytes per kilocycle | instructions/byte |
|---|---:|---:|---:|
| twitter | 3310 | 768 | 8.77 |
| twitterescaped | 3140 | 726 | 9.94 |
| canada | 2030 | 474 | 16.80 |
| citm_catalog | 4062 | 951 | 8.06 |
| gsoc-2018 | 7522 | 1769 | 3.66 |
| github_events | 3979 | 930 | 7.28 |

### pup (Intel Core Ultra 9 185H, x86_64)

Timed under `cpuq run --exclusive`, pinned to a P core; the `perf stat`
counts are on the same core.

| file | std.json | sonic-rs | simd-json (tape) | zimdjson (DOM) | std.json vs sonic-rs | simd-json vs sonic-rs | zimdjson vs sonic-rs | std.json vs sonic-rs before #138 |
|---|---:|---:|---:|---:|---|---|---|---|
| twitter | 2521 | 2698 | 2447 | 4235 | 7% slower | 9% slower | 57% faster | 19% slower |
| twitterescaped | 2317 | 2143 | 1423 | 2807 | 8% faster | 34% slower | 31% faster | 4% slower |
| canada | 1312 | 1386 | 1068 | 926 | 5% slower | 23% slower | 33% slower | 11% slower |
| citm_catalog | 2895 | 3481 | 2554 | 4429 | 17% slower | 27% slower | 27% faster | 29% slower |
| gsoc-2018 | 5055 | 5112 | 3481 | 5410 | 1% slower | 32% slower | 6% faster | 12% slower |
| github_events | 3068 | 3800 | 2726 | 4828 | 19% slower | 28% slower | 27% faster | 30% slower |
| geomean | | | | | 7% slower | | | 18% slower |

Cycles and instructions per byte (`perf stat`; these don't depend on load):

| file | std.json cycles/byte | sonic-rs | std.json vs sonic-rs | std.json instructions/byte | sonic-rs | std.json vs sonic-rs |
|---|---:|---:|---|---:|---:|---|
| twitter | 1.856 | 1.678 | 11% more cycles | 9.69 | 7.89 | 23% more |
| twitterescaped | 1.995 | 2.099 | 5% fewer cycles | 10.93 | 10.48 | 4% more |
| canada | 3.503 | 3.380 | 4% more cycles | 17.81 | 16.35 | 9% more |
| citm_catalog | 1.547 | 1.344 | 15% more cycles | 8.48 | 6.50 | 30% more |
| gsoc-2018 | 0.904 | 0.981 | 8% fewer cycles | 4.04 | 2.59 | 56% more |
| github_events | 1.462 | 1.305 | 12% more cycles | 8.10 | 5.70 | 42% more |

## Checks and IPC after proofs2 (Rig main at 34ffed549)

What is left of std.json's safety checks once the compiler has removed
the ones it proves, what each class costs, and how std.json's instruction
counts and IPC compare with sonic-rs's on each architecture. Rig main
34ffed549 has proofs2 (#138) and wide vector reads (#141), and not proven
Simd reads. The tools are in `bench/json/checks/` and
`bench/json/timers/ipc.py` (bench/json/README.md, "Checks").

### The checks left

`checks/inventory.py` on `checks/probe.rig`: every branch into a panic
block, charged through DWARF's inline chain to a line of std.json. 95
checks are left on aarch64 and 85 on x86_64. By class, on aarch64:

| class | sites | where |
|---|---:|---|
| reads not proven (`rig.at`, `readInt`, `simdRead`, `slice`) | about 40 | `literal` (10), `utf8_end`, `key`, `plain`, `escaped`, `document`, `hex_value`, the string scan's loop |
| position arithmetic (`i + 16 <= len`, `i + k`, `i - first`) | about 15 | the string scan, `take_digits`, `number`, `utf8_end` |
| a List's length as an `Int` (`rig.len`) | about 11 | `size`, `open`, `close`, `add_float`, `add_int` |
| the tape entries' arithmetic (`len * 16 + tag`) | about 9 | `close`, `add_float`, `add_int`, `add_string` |
| List `slot` and `pop`, narrowing casts | about 8 | `close`, `push_utf8` |
| `m << m.leading_zeros()` | 3 | `eisel_lemire`, `normal_float_bits` |

- **`document` reads each value's first byte with a check.** It
  tests `i < n` first, but `i >= 0` comes back from `skip_space`, and
  the proof does not cross the call. `key` reads its `"` and `:` the
  same way.
- **The string scan's 16-byte read is checked in its loop.** proofs2
  proves `i + 16 <= s.len` from the loop's condition and makes proven
  forms of `at` and `readInt`, but `simdRead` has none. The loop body is
  20 instructions per 16 bytes on both architectures. 5 of them are the
  read's check, and 2 more keep the counters it tests.

### What each class costs

`checks/sizing.py`: each class made unchecked in a copy of rig-safe's
emitted Zig, as a proof would emit it (runtime safety off around the
original expression, which keeps LLVM's no-overflow fact). Instructions
retired per byte on the Mac, the median of 5 runs (the count does not
depend on load, but one run can be off by several percent either way);
"all" is every class but `sread`:

| file | base | len | tape | pos | idx | shl | sread | all |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | 8.78 | 8.67 (1.3% fewer) | 8.88 (1.1% more) | 8.77 (0.2% fewer) | 8.64 (1.6% fewer) | 8.79 (0.1% more) | 8.65 (1.5% fewer) | 8.37 (4.7% fewer) |
| twitterescaped | 9.94 | 9.89 (0.5% fewer) | 9.80 (1.4% fewer) | 10.07 (1.3% more) | 9.51 (4.3% fewer) | 9.94 (the same) | 9.81 (1.3% fewer) | 9.47 (4.7% fewer) |
| canada | 16.82 | 16.48 (2.0% fewer) | 16.75 (0.4% fewer) | 16.47 (2.1% fewer) | 16.31 (3.0% fewer) | 16.91 (0.5% more) | 16.81 (0.1% fewer) | 15.54 (7.6% fewer) |
| citm_catalog | 8.09 | 8.06 (0.3% fewer) | 8.21 (1.6% more) | 8.16 (1.0% more) | 7.88 (2.5% fewer) | 8.10 (0.1% more) | 8.03 (0.7% fewer) | 7.76 (4.0% fewer) |
| gsoc-2018 | 3.66 | 3.65 (0.4% fewer) | 3.68 (0.6% more) | 3.58 (2.2% fewer) | 3.64 (0.5% fewer) | 3.69 (0.9% more) | 3.34 (8.7% fewer) | 3.36 (8.3% fewer) |
| github_events | 7.28 | 7.20 (1.1% fewer) | 7.34 (0.9% more) | 7.41 (1.9% more) | 7.18 (1.4% fewer) | 7.28 (the same) | 7.05 (3.1% fewer) | 6.83 (6.2% fewer) |

- **The string scan's read (`sread`) is the one that matters.** On its own
  it saves 9% of gsoc-2018's instructions, as much as every other class
  together, and 3% of github_events'.
- **The rest save 4-9% of instructions together, and none more than 4%
  alone.** Some classes alone add instructions, since the code LLVM lays
  out and inlines changes with them.

In time (Mac, interleaved, fastest of 15 at a load of 3; MB/s):

| file | base | `sread` | all but `sread` | sonic-rs |
|---|---:|---:|---:|---:|
| twitter | 3356 | 3354 | 3194 | 3124 |
| twitterescaped | 3149 | 3160 | 3096 | 2819 |
| canada | 2024 | 2026 | 2145 | 2024 |
| citm_catalog | 4086 | 4082 | 3705 | 3813 |
| gsoc-2018 | 7618 | 8048 | 7413 | 7257 |
| github_events | 4051 | 4098 | 3836 | 3763 |

- **A proven `simdRead` makes gsoc-2018 6% faster** and github_events 1%
  faster, and changes nothing elsewhere.
- **Removing every other check is slower on four files** (citm_catalog
  9%, github_events and twitter 5%, gsoc-2018 3%), and faster only on
  canada (6%). The checks that never fail cost Apple's wide core little;
  the layout and inlining that change with them cost more.
- **Wrapping arithmetic is not an unchecked add.** Removing the position
  checks by writing `+%` for `+` added 1-2.5% of instructions: a checked
  add leaves LLVM the fact that it did not overflow, and `+%` loses it.

### IPC against sonic-rs, Mac

`timers/ipc.py`, the same builds (sonic-rs 0.5.10 and simd-json,
`target-cpu=native`), the median of 5. The instruction counts hold from
run to run; the cycle counts, and so IPC, move with the load (a load of
about 3), so take IPC as a comparison within one run and time from the
interleaved table above:

| file | std.json instructions/byte | IPC | sonic-rs instructions/byte | IPC | simd-json instructions/byte | IPC |
|---|---:|---:|---:|---:|---:|---:|
| twitter | 8.77 | 6.2 | 8.66 | 5.3 | 8.03 | 4.8 |
| twitterescaped | 9.94 | 5.9 | 10.52 | 5.7 | 13.01 | 3.8 |
| canada | 16.81 | 7.1 | 15.76 | 6.1 | 18.05 | 4.8 |
| citm_catalog | 8.06 | 6.2 | 7.20 | 5.4 | 7.34 | 5.3 |
| gsoc-2018 | 3.66 | 6.3 | 3.35 | 4.9 | 5.35 | 4.0 |
| github_events | 7.28 | 6.1 | 6.41 | 5.5 | 7.46 | 5.8 |

On the Mac std.json retires 6% fewer to 14% more instructions than
sonic-rs, at a higher IPC on every file: it does about as much work and
does it faster, which is why it leads sonic-rs in time there.

### The same parsers on each architecture

Instructions per byte on the Mac (above) and on pup (`perf stat`, "With
proofs2" above, on 2cc2008e6, whose std.json code is the same):

| file | std.json, x86_64 against aarch64 | sonic-rs, x86_64 against aarch64 | std.json against sonic-rs, aarch64 | x86_64 |
|---|---|---|---|---|
| twitter | 10% more | 9% fewer | 2% more | 23% more |
| twitterescaped | 10% more | the same | 6% fewer | 4% more |
| canada | 6% more | 4% more | 7% more | 9% more |
| citm_catalog | 5% more | 10% fewer | 12% more | 30% more |
| gsoc-2018 | 10% more | 22% fewer | 10% more | 56% more |
| github_events | 11% more | 11% fewer | 14% more | 42% more |

- **sonic-rs retires fewer instructions on x86_64 than on aarch64**, up to
  22% fewer on gsoc-2018: with AVX2 it reads 32 bytes a step, against 16
  with NEON. std.json reads 16 on both.
- **std.json retires 5-11% more on x86_64.** Its hot loops compile to the
  same steps on both (the string scan: 21 instructions on x86_64, 20 on
  aarch64), so the difference is elsewhere: x86_64's two-operand
  instructions and 16 general registers against aarch64's 31 are the
  likely cause, not yet shown by a profile.
- **So the x86_64 gap is two things.** On gsoc-2018 it is width: a
  32-lane scan gains 10% there on pup ("The string-scan sweep"). On
  citm_catalog and github_events it is whitespace, where a prototype of
  sonic-rs's whitespace bitmap, kept between calls, measured 13% to 34%
  faster on pup.

## After proven Simd reads and block copies (Rig main at f026d177e)

Rig main f026d177e adds proven Simd reads (#149), which take the bounds
check out of the string scan's loop, and the String write window
`push(v, keep: k)` (#150), which copies the text between escapes 16
bytes at a time as it is scanned. The Mac (Apple M5), a quiet window at
a 1-minute load of 2.6-2.9, fastest of 15 interleaved runs of about
400 ms; MB/s, every Rig check kept:

| file | std.json | sonic-rs | std.json against sonic-rs | simd-json (tape) | serde_json | Zig std.json (tape, safe) |
|---|---:|---:|---|---:|---:|---:|
| twitter | 3304 | 3078 | 7% faster | 3442 | 653 | 865 |
| twitterescaped | 3188 | 2792 | 14% faster | 1340 | 543 | 623 |
| canada | 2003 | 1984 | within noise (1% faster) | 1307 | 672 | 565 |
| citm_catalog | 4034 | 3752 | 8% faster | 4030 | 1005 | 1217 |
| gsoc-2018 | 8166 | 7149 | 14% faster | 3885 | 1833 | 618 |
| github_events | 4080 | 3725 | 10% faster | 3691 | 837 | 962 |
| geomean | | | 9% faster | | | |

- **On the Mac std.json leads sonic-rs on five files and ties it on
  canada**, 9% faster by geomean (1% faster before proofs2, #138, and 6% after it).
- **simd-json's tape parser leads std.json on twitter** (4% faster) and
  ties it on citm_catalog.
- **Nesting without a separate list.** The same run timed the parser
  with its `stack` list dropped, an open array's or object's tape entry
  holding the entry of the one around it until it closes: within noise
  on every file (citm_catalog 2% faster, the rest within 1%), with 1.5%
  fewer instructions on canada, citm_catalog and twitterescaped. It is
  kept for the simpler `Doc` (one list fewer to grow).

## The float conversion inlined (Rig main at 598a244e0)

`normal_float_bits`, the one-multiply Eisel-Lemire that converts every
number of 16 to 19 digits, was a call from `number` on every such float:
its body was over the inliner's size. Its rare path, the next 64 bits
of 5^q when the top word cannot decide the rounding, moved into a small
`settle_hi`, and the rest now inlines. Instructions per byte
(bench/json/guard.txt): canada 3.4% fewer, the other files the same. The Mac, fastest of 15
interleaved runs at a 1-minute load of 3.3-4 (another project's job ran
on 2 cores); MB/s:

| file | std.json | float inlined | sonic-rs | float inlined against sonic-rs |
|---|---:|---:|---:|---|
| twitter | 3348 | 3294 | 3096 | 6% faster |
| twitterescaped | 3188 | 3213 | 2792 | 15% faster |
| canada | 2039 | 2095 | 1998 | 5% faster |
| citm_catalog | 4096 | 4110 | 3764 | 9% faster |
| gsoc-2018 | 8260 | 8222 | 7213 | 14% faster |
| github_events | 4084 | 4114 | 3746 | 10% faster |

- **canada is 2.7% faster**, and the other files move within noise:
  canada goes from within noise of sonic-rs (2% faster) to 5% faster,
  so std.json leads sonic-rs on all six files on the Mac by more than
  noise.
- **The same run timed main under the `inlinect` compiler** (#154, which
  inlines instances of functions with compile-time parameters): within
  noise on every file, and the guard's counts unchanged.
- **A specialized `document[dense: Bool]`** (the whitespace bitmap in the
  dense instance only) made citm_catalog 11% faster under it but canada
  10% slower: the generic `document` counted both instances' calls
  against the inliner's per-function cap, which then out-lined
  `Doc.number`. docs/RIG-NOTES.md, entry 6.

## Linux x86 (pup), after the float conversion (Rig main at 646b4c9c5)

pup (Intel Core Ultra 9 185H, AVX2), `cpuq run --exclusive`, pinned to a
P core (`taskset -c 2`), fastest of 15 interleaved runs of about 400 ms;
MB/s. The build is std.json with #149, #150, #160 and #167, the Rust
parsers at `target-cpu=native`:

| file | std.json | sonic-rs | std.json against sonic-rs | simd-json (tape) | serde_json | Zig std.json (tape, safe) |
|---|---:|---:|---|---:|---:|---:|
| twitter | 2609 | 2746 | 5% slower | 2475 | 380 | 692 |
| twitterescaped | 2406 | 2185 | 10% faster | 1448 | 333 | 476 |
| canada | 1370 | 1434 | 4% slower | 1124 | 349 | 398 |
| citm_catalog | 2907 | 3543 | 18% slower | 2592 | 691 | 753 |
| gsoc-2018 | 5685 | 5144 | 11% faster | 3494 | 1176 | 445 |
| github_events | 3194 | 3870 | 17% slower | 2764 | 428 | 631 |
| geomean | | | 5% slower | | | |

Cycles and instructions per byte (`perf stat`, the same core):

| file | std.json cycles/byte | sonic-rs | std.json instructions/byte | sonic-rs | std.json IPC | sonic-rs |
|---|---:|---:|---:|---:|---:|---:|
| twitter | 1.816 | 1.748 | 9.30 | 7.99 | 5.12 | 4.57 |
| twitterescaped | 1.922 | 2.161 | 10.27 | 10.47 | 5.34 | 4.84 |
| canada | 3.427 | 3.340 | 17.05 | 16.13 | 4.98 | 4.83 |
| citm_catalog | 1.616 | 1.298 | 8.72 | 6.29 | 5.39 | 4.84 |
| gsoc-2018 | 0.806 | 0.966 | 3.78 | 2.51 | 4.69 | 2.60 |
| github_events | 1.457 | 1.256 | 8.03 | 5.39 | 5.51 | 4.30 |

- **5% slower than sonic-rs by geomean** (7% after proofs2, 18% before),
  and faster than simd-json on every file. gsoc-2018 went from 1%
  slower to 11% faster.
- **The gap is instructions.** std.json runs at a higher IPC on every
  file but retires 39% more instructions per byte on citm_catalog and
  49% more on github_events. Those two files are where a whitespace
  bitmap kept between calls applies (a prototype measured citm_catalog
  21% faster and github_events 5% faster on pup), and a vector UTF-8
  check.

## One literal per file in the benchmark (the harness, not the parser)

With string literals of any length (#168), `bench/json/bench-json`
writes each corpus file as one literal, copied into a `String` once at
start-up, in place of 60 KB literals joined in a loop. std.json's code
and the bytes it parses are unchanged, and the same functions stay out
of line, yet instructions per byte moved, both ways
(bench/json/guard.py): canada 9% fewer, citm_catalog 7% fewer, twitter
3% fewer, twitterescaped 2% fewer, gsoc-2018 1% fewer, and github_events
10% more. `parse` has one call site, so LLVM inlines the parser into the
benchmark's `main`, and the code around that call changes how it
allocates registers and lays out the parser's loops. The guard's
baseline (`bench/json/guard.txt`) was regenerated with this harness;
counts and times before it compare only with each other.

In time (the Mac, one interleaved run at a load of 3.9-5.2, fastest of
15; MB/s), the one-literal harness against the chunked one, the same
compiler and parser:

| file | chunked | one literal | one literal against chunked |
|---|---:|---:|---|
| twitter | 2986 | 3178 | 6% faster |
| twitterescaped | 2960 | 2992 | within noise |
| canada | 1956 | 2070 | 6% faster |
| citm_catalog | 3736 | 4212 | 13% faster |
| gsoc-2018 | 7533 | 7758 | 3% faster |
| github_events | 3756 | 3659 | 3% slower |

The same run timed Rig's removal of the inliner's call cap (#154's
follow-up) on today's parser: within noise. A `document` specialized
for dense whitespace still lost `Doc.number`'s inlining under it, for
the reason docs/RIG-NOTES.md, entry 6, gives.

## UTF-8 checked 16 bytes at a time (Rig main at 995ad18d2)

A string's non-ASCII text is checked a block at a time with SIMD round
2's `t.lookup(v)`, `cur.lag[k](prev)` and `-|` (Keiser-Lemire's lookups,
as simdjson's lookup4), up to the string's next quote, backslash, or
control byte; the sequence-at-a-time check runs only near the end of
the input or to place an error. Results are unchanged: all 10,511
inputs of `./test/run json`, and 864 strings that put each valid and
invalid sequence around the block edges
(test/behavior/std/json_utf8_blocks.rig), whose expected errors come
from Python's decoder. A string whose stop lies in the input's last 15
bytes, past the last block the loop can read, resumes the
sequence-at-a-time check at that block, not at the text's start: a 3 MB
top-level string parses 2.2x as fast as on main (0.10 s against 0.22 s
for 400 parses), where checking it again from its start had made it 90%
slower.

Instructions per byte (bench/json/guard.py, median of 5), main against
the branch:

| file | main | UTF-8 blocks | change |
|---|---:|---:|---|
| twitter | 8.41 | 7.48 | 11% fewer |
| twitterescaped | 9.29 | 9.18 | 1% fewer |
| canada | 14.64 | 14.01 | 4% fewer |
| citm_catalog | 7.43 | 7.31 | 2% fewer |
| gsoc-2018 | 3.43 | 3.40 | 1% fewer |
| github_events | 7.80 | 6.70 | 14% fewer |

Inlined into `document`, the same block loop took 6-17% more
instructions on five of the files, twitterescaped's 17% among them,
which holds no non-ASCII byte; it is a separate method, `utf8_text`,
which the inliner leaves as a call (docs/RIG-NOTES.md, entry 7).
canada holds no non-ASCII byte and github_events 4, so their change
is not the check: it is the code around the string scan, where
`document` no longer holds the sequence-at-a-time loop either. twitter
(95,406 non-ASCII bytes) is where the check itself runs.

In time (the Mac, a quiet window at a load of 3.8, fastest of 15
interleaved runs; MB/s):

| file | main | UTF-8 blocks | sonic-rs | against main | against sonic-rs |
|---|---:|---:|---:|---|---|
| twitter | 3383 | 3680 | 3074 | 9% faster | 20% faster |
| twitterescaped | 3222 | 3252 | 2793 | within noise | 16% faster |
| canada | 2250 | 2247 | 2003 | within noise | 12% faster |
| citm_catalog | 4506 | 4570 | 3748 | within noise | 22% faster |
| gsoc-2018 | 8288 | 8430 | 7139 | within noise | 18% faster |
| github_events | 4037 | 4383 | 3718 | 9% faster | 18% faster |

Every parser in one session (the Mac, load 2.7-3.3, one core, fastest
of 15 interleaved runs; MB/s). The Rust parsers are built for the
native CPU; zimdjson (a Zig port of simdjson) is its DOM parser in
ReleaseFast; std.json is in Zig's safe mode, every check kept:

| file | std.json | std.json on main | sonic-rs | simd-json (tape) | zimdjson (DOM, fast) | serde_json | Zig std.json (tape, safe) |
|---|---:|---:|---:|---:|---:|---:|---:|
| twitter | **3642** | 3362 | 3082 | 3437 | 3612 | 656 | 874 |
| twitterescaped | **3259** | 3220 | 2781 | 1341 | 2765 | 549 | 620 |
| canada | **2266** | 2243 | 2010 | 1307 | 1324 | 672 | 573 |
| citm_catalog | **4615** | 4549 | 3777 | 4065 | 3933 | 1009 | 1211 |
| gsoc-2018 | **8423** | 8345 | 7208 | 3902 | 3850 | 1850 | 621 |
| github_events | **4338** | 4010 | 3714 | 3688 | 3984 | 852 | 956 |
| geomean | **4069** | 3932 | 3469 | 2658 | 3045 | 853 | 779 |

std.json is the fastest on every file but twitter, where it and
zimdjson are within noise. By geomean it is 17% faster than sonic-rs,
34% faster than zimdjson, 53% faster than simd-json, 4.8x serde_json,
and 5.2x Zig's std.json.

On x86 (pup, Intel Core Ultra 9 185H, AVX2; `cpuq run --exclusive`,
pinned to a P core with `taskset -c 2`, fastest of 15 interleaved runs
of about 400 ms; MB/s; instructions and cycles per byte from `perf
stat`), the branch as first committed (0934fa9c5, before the tail fix,
which left the Mac's instruction counts unchanged):

| file | std.json | std.json on main | sonic-rs | against main | against sonic-rs | instructions/byte, against main |
|---|---:|---:|---:|---|---|---|
| twitter | 2970 | 2719 | 2765 | 9% faster | 7% faster | 8.00 vs 8.57, 7% fewer |
| twitterescaped | 2511 | 2507 | 2203 | within noise | 14% faster | 10.17 vs 9.64, 5% more |
| canada | 1407 | 1432 | 1440 | within noise | within noise | 16.90 vs 16.62, 2% more |
| citm_catalog | 3155 | 3152 | 3566 | within noise | 12% slower | 7.61 vs 8.00, 5% fewer |
| gsoc-2018 | 5933 | 6074 | 5273 | 2% slower | 13% faster | 3.69 vs 3.50, 5% more |
| github_events | 3444 | 3389 | 3903 | within noise | 12% slower | 7.20 vs 7.13, 1% more |
| geomean | 2963 | 2930 | 2938 | 1% faster | 1% faster | |

On x86 std.json now leads sonic-rs by geomean, by 1%; main was within
noise of it in the same run. twitter gains as on the Mac; the layout
gains the Mac showed on canada and github_events do not carry over, and
twitterescaped and gsoc-2018, whose strings hold no non-ASCII text, run
5% more instructions: the code around the string scan changed, not the
check. citm_catalog and github_events remain 12% behind sonic-rs, which
retires 18-24% fewer instructions per byte on them.

## A vector whitespace skip: fewer instructions, slower

`skip_space` (std/json.rig) goes a byte at a time, or 8 spaces at a time
with one U64 compare. A variant read 16 bytes when 16 were left, and
returned the first lane that is not whitespace:

```
v = s.read[Simd[U8, 16]](i)
ws = WS.lookup(v & 0x0F) == v     # WS: 0x20, 0x09, 0x0A, 0x0D by low nibble
if ws.not().first() as k
  return i + k
i += 16
```

Its results were the same as main's (11,987,148 direct comparisons, and
test/behavior/std/json_space_blocks.rig). Instructions per byte fell,
and time rose:

| file | instructions (Mac) | time (Mac, MB/s, main → variant) | cycles (x86) | IPC (x86, main → variant) |
|---|---|---|---|---|
| twitter | 18% fewer | 3652 → 2195, 40% slower | 13% more | 4.91 → 3.66 |
| twitterescaped | within noise | within noise | 9% fewer | 5.22 → 5.67 |
| canada | within noise | within noise | 3% fewer | 4.97 → 4.95 |
| citm_catalog | 29% fewer | 4617 → 2736, 41% slower | within noise | 5.12 → 3.81 |
| gsoc-2018 | 12% fewer | 8466 → 5754, 32% slower | 9% more | 4.44 → 3.63 |
| github_events | 20% fewer | 4346 → 2568, 41% slower | 11% more | 5.20 → 3.74 |

The Mac: one quiet window, fastest of 15 interleaved runs (a compare-based
classify, `(v == SPACE) | (v == LF) | ...`, was as slow). x86: pup, `perf
stat` on a P core, 2 cores held, not exclusive.

The byte loop is branchy: the predictor guesses where a run of
whitespace ends, so the next token's loads start before the run is
checked. The vector skip computes that position from data, so every
token waits on a load, the classify, a move of the mask to a register,
and a count. sonic-rs keeps that chain short by classifying 64 bytes
once and keeping the bitmap in a register, so a skip is a shift and a
count: the whitespace bitmap above (the wsspec prototype), which waits
on Rig's inlining of single-call functions. The instruction guard
(`bench/json/guard.py`) would have passed this variant
(docs/RIG-NOTES.md, entry 25).

## The honest harness

`bench/json/bench-json`'s driver calls `parse` twice: once on `[0]` at
start-up, then in the timed loop. With one call, LLVM inlines the whole
parser into the benchmark's `main` and keeps the Doc's fields in
registers; with two, `document` stays a function and reaches the Doc
through `self`, as in a program that parses from more than one place.
The guard (`bench/json/guard.py`) was re-baselined on this driver.

Rig main of 2026-10-13, on the Mac, one quiet window, fastest of 15
interleaved runs; MB/s:

| file | one call (inlined) | two calls (honest) | honest against inlined | instructions/byte, honest against inlined |
|---|---:|---:|---|---|
| twitter | 3664 | 3422 | 7% slower | 18% more |
| twitterescaped | 3266 | 3057 | 6% slower | 14% more |
| canada | 2244 | 2077 | 7% slower | 12% more |
| citm_catalog | 4673 | 4131 | 12% slower | 12% more |
| gsoc-2018 | 8493 | 8242 | 3% slower | 7% more |
| github_events | 4293 | 4098 | 5% slower | 10% more |

The likely cause is docs/RIG-NOTES.md, entry 8: through `self`, every
push to the tape loads its length and capacity and stores the length
back.

Every parser on the honest harness (the Mac, Rig main at f42512ebb, a
quiet window at a load of 3.3-7.7 falling, one core, fastest of 15
interleaved runs; MB/s). The Rust parsers are built for the native CPU
and their parsing functions are separate symbols in their binaries;
zimdjson is its DOM parser in ReleaseFast, whose `dom.Parser` is a
separate symbol too; std.json is in Zig's safe mode, every check kept:

| file | std.json | sonic-rs | simd-json (tape) | zimdjson (DOM, fast) | serde_json | Zig std.json (tape, safe) |
|---|---:|---:|---:|---:|---:|---:|
| twitter | 3419 | 3078 | 3440 | **3584** | 654 | 867 |
| twitterescaped | **3056** | 2769 | 1336 | 2753 | 545 | 619 |
| canada | **2078** | 1994 | 1303 | 1316 | 670 | 570 |
| citm_catalog | **4125** | 3764 | 4027 | 3894 | 1008 | 1210 |
| gsoc-2018 | **8264** | 7139 | 3881 | 3825 | 1845 | 617 |
| github_events | **4066** | 3673 | 3669 | 3947 | 839 | 954 |
| geomean | **3800** | 3447 | 2646 | 3023 | 848 | 776 |

std.json is the fastest on five files: ahead of the next parser by 16%
on gsoc-2018, 10% on twitterescaped, 4% on canada, 3% on github_events,
and 2% on citm_catalog. On twitter zimdjson is 5% faster and simd-json
ties. By geomean std.json is 10% faster than sonic-rs, 26% faster than
zimdjson, 44% faster than simd-json, 4.5x serde_json, and 4.9x Zig's
std.json. On the inlined harness the same geomean was 17% ahead of
sonic-rs ("UTF-8 checked 16 bytes at a time").

## Against C and C++: simdjson and yyjson

The C and C++ parsers most often named as the fastest, built by
`bench/json/cbench/build.sh`: simdjson v3.10.1's DOM parser and yyjson
0.10.0, `-O3 -DNDEBUG` for the native CPU. Both validate fully. yyjson
runs with every `YYJSON_DISABLE_*` switch off and read flags 0, so UTF-8
validation, standard JSON only and exact float conversion are all on. On
the 132 JSON_checker and fuzzer files it agrees with Python's strict
parser on 112. In all 20 others it is stricter: it rejects lone
surrogate escapes (19) and a number that overflows to infinity (1),
which Python and std.json accept. Each reuses its buffers between runs,
as std.json reuses its tape, and yyjson also copies the input into its
own buffer on every parse. std.json runs in Zig's safe mode, every check
kept; the C and C++ parsers have no such checks.

The Mac, the honest harness (Rig main at f42512ebb with #204's driver), a quiet
window at a load of 2.9-3.3, one core, fastest of 15 interleaved runs;
MB/s:

| file | std.json | yyjson | simdjson (DOM) | zimdjson (DOM, fast) | sonic-rs |
|---|---:|---:|---:|---:|---:|
| twitter | 3402 | **5181** | 4463 | 3592 | 3065 |
| twitterescaped | 3064 | **4045** | 1729 | 2754 | 2773 |
| canada | 2075 | **2123** | 1743 | 1317 | 1991 |
| citm_catalog | 4160 | **5518** | 5196 | 3896 | 3744 |
| gsoc-2018 | **8269** | 4745 | 5416 | 3820 | 7161 |
| github_events | 4099 | **5276** | 4790 | 3948 | 3672 |
| geomean | 3808 | **4280** | 3492 | 3025 | 3443 |

yyjson is the fastest parser measured: 11% faster than std.json by
geomean, 1.3x to 1.5x on twitter, citm_catalog and github_events, and
within 2% on canada. std.json is 1.7x yyjson on gsoc-2018, whose long
strings its SIMD scan takes 16 bytes at a time. std.json is 9% faster
than simdjson's DOM parser by geomean, though simdjson leads on twitter,
citm_catalog and github_events. (simdjson's On-Demand API, which walked
every value in the same harness, was slower than its DOM parser on every
file, 3173 by geomean, and is not kept.)

The first answers are Rig's: keeping the parser's state in registers
(the List growth round, `noalias` for write views, and a local tape in
`document`; docs/RIG-NOTES.md, entry 8), worth up to 12% on citm_catalog
by the honest harness's own measure ("The honest harness").

## SIMD first on x86, and the tape in a local

`TIER = 0 if target.arch == .x86_64 else 16` (`use std.target`): on
x86_64, `skip_plain_ascii` starts with 16-lane SIMD, where a compare's
mask reaches a general register cheaply; on arm64 it keeps its 16 bytes
of SWAR first (TIER=0 there was 5-9% slower on three files). The Mac's
code is unchanged.

x86: burst (a cloud VM, AMD EPYC, 48 cores with SMT), the honest
harness, `cpuq run --exclusive` holding the machine, pinned to CPU 2
with its SMT sibling idle, fastest of 15 interleaved runs; MB/s. Each
change is against main's `json.rig` built with the same compiler:

| file | main | TIER by target | against main |
|---|---:|---:|---|
| twitter | 2639 | 2797 | 6.0% faster |
| twitterescaped | 2145 | 2189 | 2.1% faster |
| canada | 1370 | 1370 | within noise |
| citm_catalog | 3314 | 3350 | 1.1% faster |
| gsoc-2018 | 6281 | 6522 | 3.8% faster |
| github_events | 3107 | 3389 | 9.1% faster |

The same run timed `document` holding the tape in a local while it
parses (taken out with `replace(!self.tape, List())` and put back on
every way out), so its length and capacity could stay in registers. On
the Mac that was up to 3.5% faster (twitter 3.5%, citm_catalog 3.3%),
none slower; on x86 it is 6.5% slower on citm_catalog, 4.8% on
gsoc-2018 and 3.0% on github_events, and 5.2% faster on twitterescaped.
It does not land. x86
has 16 general registers to arm64's 31, and keeping the tape's pointer,
length and capacity in them spills other values in `document`. A
change that keeps values in registers is timed on both machines.

### A number's first digits a byte at a time

`number` reads integer digits 8 at a time (`take_digits`), which
computes where the digits end from data. A variant read the first 4
integer digits a byte at a time, with branches the predictor learns, and
went on 8 at a time after that. On the Mac (Rig main at 29b1d6b7d, one
quiet window, fastest of 15 interleaved runs) it was 5.2% faster on
canada (2073 to 2181 MB/s), whose integer parts are 1 to 3 digits, and
2.6% slower on citm_catalog (4087 to 3982), whose integers run to about
9 digits; the other four files were 0.8% to 1.3% slower. On x86, on top
of the tape held in a local, it was 10.8% faster on canada. It misses
the speed rule on citm_catalog and does not land; it can come back if
something else removes its cost on long integers. Reading every integer
digit a byte at a time, uncapped, was worse: citm_catalog 4.7% slower.

## Every parser on x86

The honest harness on x86: pup (Intel Core Ultra 9 185H, AVX2), under
cpuq's `pup-bench` lease, pinned to one P core (`taskset -c 2`), fastest
of 15 interleaved runs of about 400 ms; MB/s. Rig main at f95ea861d. The
C, C++ and Rust parsers are built for the native CPU, zimdjson is its DOM
parser in ReleaseFast, and std.json is in Zig's safe mode, every check
kept:

| file | std.json | yyjson | simdjson (DOM) | sonic-rs | zimdjson (DOM, fast) | simd-json (tape) | Zig std.json (tape, safe) |
|---|---:|---:|---:|---:|---:|---:|---:|
| twitter | 2770 | 3771 | **4751** | 2661 | 4226 | 2402 | 675 |
| twitterescaped | 2232 | 2624 | 2098 | 2129 | **2823** | 1391 | 464 |
| canada | 1289 | 1392 | **1442** | 1365 | 929 | 1069 | 386 |
| citm_catalog | 2922 | 3607 | **5192** | 3401 | 4415 | 2484 | 737 |
| gsoc-2018 | **5781** | 3198 | 5718 | 5005 | 5361 | 3243 | 427 |
| github_events | 3238 | 3941 | **5533** | 3766 | 4890 | 2690 | 619 |
| geomean | 2754 | 2925 | **3649** | 2813 | 3296 | 2064 | 535 |

On x86 simdjson is the fastest parser measured: 25% ahead of std.json by
geomean, where on the Mac std.json is 9% ahead of it ("Against C and
C++"). zimdjson, a port of simdjson's design, is 16% ahead, yyjson 6%,
and sonic-rs within 2%. std.json leads only gsoc-2018, and stays 33%
ahead of simd-json and 5.1x Zig's std.json. simdjson first indexes every
structural character of each 64-byte block with SIMD (on x86, 32-byte
AVX2 vectors), then walks the index; std.json scans tokens one after
another. That index is docs/json/DESIGN.md's first open item, which also
needs a carry-less multiply from Rig to find the bytes inside strings.

The x86 checks in "SIMD first on x86, and the tape in a local" and "A
number's first digits a byte at a time" ran on burst, a shared cloud VM
that cpuq reserves for throughput, not timing: read them as indicative.
x86 timing runs on pup under the `pup-bench` lease.

## One read for a plain string

`Doc.string` decides the common case, an ASCII string that ends at its
closing quote, with one guarded read of the next 16 bytes. Every other
string moves into a new inline `string_rest`; `plain` is unchanged. This
removes `plain`'s second read of the stop byte, which was 8.1% of
twitter's instructions in a pup perf profile of main at 11f1e3bf6.

The honest harness, against main, MB/s.

Mac (Apple silicon), in a cpuq exclusive window:

| file | main | one read | change |
|---|---:|---:|---|
| twitter | 3393 | 3512 | 3.5% faster |
| twitterescaped | 3051 | 3166 | 3.8% faster |
| canada | 2063 | 2082 | 0.9% faster |
| citm_catalog | 4178 | 4150 | 0.7% slower |
| gsoc-2018 | 8233 | 8310 | 0.9% faster |
| github_events | 4069 | 4124 | 1.4% faster |

pup (Intel Core Ultra 9 185H, x86_64), under `cpuq lease pup-bench
--exclusive`, with 2.6 CPUs of outside work:

| file | main | one read | change |
|---|---:|---:|---|
| twitter | 2756 | 2875 | 4.3% faster |
| twitterescaped | 2209 | 2380 | 7.7% faster |
| canada | 1287 | 1310 | 1.8% faster |
| citm_catalog | 2900 | 2988 | 3.0% faster |
| gsoc-2018 | 5775 | 5734 | 0.7% slower |
| github_events | 3220 | 3361 | 4.4% faster |

Instructions retired, in the same runs: twitter and twitterescaped 7.6%
to 7.7% fewer, github_events 3.9%, citm_catalog 2.1%, gsoc-2018 1.7%,
canada level. `bench/json/guard.py` on the Mac (`rig-safe`, per byte)
counts twitter 8.6418 to 7.8445 (9.2% fewer), twitterescaped 10.2310 to
9.3549 (8.6%), canada 16.0315 to 15.9260 (0.7%), citm_catalog 8.1676 to
7.9841 (2.2%), gsoc-2018 3.5823 to 3.4543 (3.6%), github_events 7.3151 to
7.0332 (3.9%); `guard.txt` holds the new baseline.

It passes the speed rule on both machines: the two slower results (Mac
citm_catalog, x86 gsoc-2018) are each 0.7% slower, and each of those
files is faster on the other machine. A review compared main and the
branch on 65,285 generated inputs (truncations, substitutions, strings padded across the
8- and 16-byte boundaries, and 60,000 mutants) under `RIG_SANITIZE=1`:
the output was byte-identical.
