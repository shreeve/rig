# The opcode study: which instructions std.json's speed needs

This study asks which instructions and lowerings would make `std/json.rig`
faster on Apple silicon and on x86, ranked by measured time. Each one has
to become a safe, portable Rig operation, with a fallback for targets that
lack the instruction, so the ranked list at the end names the operation
as well as the instruction.

The evidence comes from prototypes, not merged changes. A prototype is
rig-safe's emitted Zig with a hand patch that stands in for the lowering
or operation Rig would gain, or a change to `std/json.rig` in Rig source
where the language already has what it needs. No patch ships. Each one
only sizes what a feature would give.

## Method

- **Machines.**
  - The Mac: Apple M5, macOS.
  - pup: an Intel Core Ultra 9 185H (Meteor Lake; AVX2, BMI2, GFNI,
    PCLMULQDQ and AVX-VNNI, no AVX-512), Linux.
  - Both run Zig 0.17.0, and Rig main f09357281 builds `rig build
    --release` (Zig's safe mode, every check kept), for the native CPU.
- **Prototypes.** `bench/json/opcodes/` holds the tools, and their header
  comments say how to use them.
  - `build.py` emits each corpus file's program once and copies the
    package for each variant. It applies the variant's patches
    (`patches/*.py`, and `src/*.rig` for changes in Rig source), then
    runs the same `zig build-exe -Osafe` that rig runs.
  - The helper each patch uses picks its instruction by a comptime test
    of the target, as the Rig operation would (`patches/_common.py`). On
    NEON that is `tbl` and `ext`; on x86 it is `pshufb` and `palignr`;
    elsewhere it falls back to portable lanes.
- **Correctness.** Every variant timed here passes `test/json/compare.py`,
  all 10,511 inputs with the sanitizer on (`optest.sh`).
  - On pup the tests are built optimized (`OP_MODE=-Osafe`). An x86
    Debug build uses Zig's own backend, where the patches take their
    portable fallbacks, so only an optimized build runs `pshufb`.
  - A broken copy of the whitespace, UTF-8, escape-copy and digit
    patches (`patches/zz_*.py`) fails the tests. That shows the patched
    code decides the result.
- **Timing.** `optime.py` interleaves every variant and file and keeps
  each one's fastest of 15 runs of about 250 ms. It also reads the cycles
  of the same runs (`/usr/bin/time -l` on the Mac; `perf stat` on pup).
  Cycles exclude time the program was descheduled.
  - On the Mac, timing ran under `cpuq --cores 1` with Rig's other jobs
    paused. Jobs outside cpuq kept the load at 5-7.
  - On pup, timing ran under `cpuq run --exclusive`, pinned to a 5.1 GHz
    P core (`taskset -c 2`).
  - Every cell is the change against the landed parser (`base`) from
    the same run, written as time / cycles. The two agree within 1-2%
    everywhere, so the differences below are not load.
- **Profiles.** `profile.py` samples a run, with Instruments' Time
  Profiler on the Mac and `perf record` on pup. It charges each sample to
  the innermost std.json function in its inlined frames (`atos -i`,
  `addr2line -i`), so work inlined into `document` still lands in its
  own category.

The raw outputs are in `bench/json/opcodes/results/`.

## Where the time goes

Share of samples per category, `base` (std.json as landed). "Of which in
the runtime" is the share whose innermost frame is in Rig's runtime:
index and read bounds checks (`rig.at`, `index`, `byteOffset`,
`math.cast`) and `List.push`.

**Mac, time:**

| category | twitter | twitterescaped | canada | citm_catalog | gsoc-2018 | github_events |
|---|---:|---:|---:|---:|---:|---:|
| whitespace (`skip_space`) | 31.0% | 9.6% | 10.8% | **54.8%** | 20.1% | **37.0%** |
| string scan (`skip_plain_ascii`) | 26.1% | 25.7% | 3.8% | 10.5% | **51.3%** | 33.7% |
| UTF-8 (`plain`, `utf8_end3`) | 16.1% | 4.2% | 0.0% | 1.8% | 3.3% | 4.5% |
| escapes | 1.2% | **31.5%** | 0.0% | 0.0% | 6.8% | 1.1% |
| digits | 4.0% | 4.3% | **44.2%** | 11.1% | 0.0% | 2.9% |
| float conversion | 0.0% | 0.0% | 15.5% | 0.0% | 0.0% | 0.0% |
| string end, tape | 4.2% | 5.0% | 0.0% | 1.6% | 3.3% | 5.7% |
| structure (`document`, `key`, open, close) | 15.5% | 16.8% | 25.7% | 19.0% | 7.1% | 13.2% |
| other | 1.9% | 2.9% | 0.0% | 1.3% | 8.1% | 1.8% |
| of which in the runtime | 30.3% | 34.7% | 28.1% | 37.5% | 47.0% | 39.8% |

**pup, time:**

| category | twitter | twitterescaped | canada | citm_catalog | gsoc-2018 | github_events |
|---|---:|---:|---:|---:|---:|---:|
| whitespace | 28.2% | 7.9% | 7.4% | **42.2%** | 17.7% | 33.1% |
| string scan | 26.2% | 25.1% | 0.0% | 12.7% | **46.3%** | 32.8% |
| UTF-8 | 17.0% | 6.2% | 0.0% | 3.2% | 6.3% | 6.6% |
| escapes | 1.6% | **35.8%** | 0.0% | 0.0% | 9.3% | 1.4% |
| digits | 4.9% | 3.5% | **35.5%** | 13.1% | 0.0% | 3.0% |
| float conversion | 0.0% | 0.0% | 27.8% | 0.0% | 0.0% | 0.0% |
| string end, tape | 7.1% | 7.5% | 0.0% | 4.1% | 6.0% | 8.1% |
| structure | 14.0% | 12.7% | 29.1% | 22.9% | 7.6% | 13.9% |
| other | 1.1% | 1.3% | 0.2% | 1.7% | 6.9% | 1.1% |
| of which in the runtime | 25.3% | 29.5% | 28.7% | 28.7% | 35.1% | 27.0% |

**pup, instructions retired** (`perf record -e instructions:u`):

| category | twitter | twitterescaped | canada | citm_catalog | gsoc-2018 | github_events |
|---|---:|---:|---:|---:|---:|---:|
| whitespace | 25.1% | 3.2% | 2.0% | **40.2%** | 13.4% | 22.6% |
| string scan | 25.5% | 29.3% | 4.1% | 15.7% | **58.8%** | 41.4% |
| UTF-8 | 15.3% | 9.7% | 0.0% | 6.1% | 9.3% | 15.4% |
| escapes | 1.4% | 35.7% | 0.0% | 0.0% | 4.0% | 0.4% |
| digits | 2.5% | 3.1% | **54.9%** | 11.9% | 0.0% | 3.0% |
| float conversion | 0.0% | 0.0% | 24.5% | 0.0% | 0.0% | 0.0% |
| string end, tape | 3.4% | 6.7% | 0.0% | 3.2% | 4.3% | 5.5% |
| structure | 25.9% | 10.6% | 14.5% | 21.6% | 5.8% | 10.6% |
| of which in the runtime | 20.7% | 25.6% | 11.4% | 28.6% | 30.6% | 27.3% |

- **Whitespace and the string scan are most of the time** on every file
  but canada and twitterescaped. citm_catalog is 71% whitespace bytes,
  twitter 27%, and gsoc-2018 and github_events 19% each.
- **Bounds checks are the leaf of a quarter to nearly half of all
  samples.** The largest single site is `skip_space`'s `s[i]`, which
  checks every byte it reads. That is the proofs work, not an opcode,
  but it is the biggest instruction cost on x86 (RESULTS.md, pup: 37-80%
  more instructions per byte than sonic-rs on four files).
- **Float conversion is already the right instructions.**
  `normal_float_bits` compiles to `clz`, `umulh`, `mul`, and the
  exponent arithmetic, about 30 instructions in all. Its one extra cost
  is the `m << lz` overflow check, which the proofs round removes.
- **sonic-rs**, by contrast, is one function, `parse_object`, holding
  64-97% of its instructions under `perf`, plus a separate simdutf8 AVX2
  validation pass (4-12%). A symbol profile can't split it further.

## The candidates

One table per candidate. Cells are time / cycles against `base`, from
the same interleaved run.

### 1. Whitespace classified by a vector: compares or a nibble lookup

`ws_cmp` and `ws_tbl` keep an inlined entry that returns at once on a
byte above space. The rest of the run goes 16 bytes at a time, and the
first non-whitespace lane comes from `m.first()`.
- `ws_cmp` classifies with four compares.
- `ws_tbl` classifies with one nibble lookup and a compare. The table
  holds the one whitespace byte for each low nibble, so a lane is
  whitespace when it equals its entry: `tbl` + `cmeq`, or `pshufb` +
  `pcmpeqb`.
- `ws_all_*` keeps today's scalar loop and adds a 16-byte step taken
  only when `m.all()`, so the position advances by a constant.

Mac:

| file | `ws_cmp` | `ws_tbl` | `ws_all_tbl` |
|---|---|---|---|
| twitter | 34% slower / 35% slower | 34% slower / 34% slower | 9% slower / 9% slower |
| twitterescaped | 1% faster / 1% faster | 1% faster / 1% faster | 2% slower / 0% |
| canada | 5% faster / 5% faster | 5% faster / 5% faster | 0% / 0% |
| citm_catalog | 27% slower / 27% slower | 26% slower / 26% slower | 10% slower / 10% slower |
| gsoc-2018 | 23% slower / 24% slower | 23% slower / 24% slower | 7% slower / 8% slower |
| github_events | 35% slower / 35% slower | 35% slower / 35% slower | 13% slower / 13% slower |

pup:

| file | `ws_cmp` | `ws_tbl` | `ws_all_tbl` |
|---|---|---|---|
| twitter | 1% slower / 0% | 2% faster / 1% faster | 11% slower / 11% slower |
| twitterescaped | 3% faster / 3% faster | 4% faster / 3% faster | 1% slower / 2% slower |
| canada | 3% faster / 4% faster | 4% faster / 4% faster | 1% slower / 1% slower |
| citm_catalog | 12% faster / 13% faster | **20% faster / 21% faster** | 10% slower / 9% slower |
| gsoc-2018 | 2% slower / 1% slower | 1% slower / 0% | 7% slower / 6% slower |
| github_events | 3% faster / 3% faster | 5% faster / 4% faster | 13% slower / 12% slower |

- **The same Rig code is 20% faster on x86 and 26% slower on the Mac**
  (citm_catalog). On the Mac it runs 3-24% fewer instructions per byte
  and still loses. Each run's end is a data-dependent position: the next
  read waits on load, compare, `shrn`, `fmov`, `rbit` and `clz`. The
  scalar loop advances by constants under well-predicted branches, so
  the core runs ahead of it.
- **It is not a call.** No Mac or pup binary has an out-of-line call to
  a mask helper; LLVM inlined them all. On the Mac, inlining the vector
  run at every call site (`ws_cmp_in`, `ws_tbl_in`) is as slow: 35%
  slower on twitter and github_events, 28% on citm_catalog. On pup,
  forcing the helpers `inline` (`ws_cmp+inl`) measured the same as
  `ws_cmp`.
- **The lookup beats the compares on x86** (citm_catalog 20% against
  12% faster), where `pshufb` + `pcmpeqb` replaces four compares and
  three ORs, and ties on the Mac.
- **Only the run is the problem.** An out-of-line run with today's
  scalar loop (`ws_split`) already costs 5-10% on the Mac, but gains 8%
  on canada, whose `document` loop is smaller without it.

### 2. Whitespace from a bitmap kept between calls (sonic-rs)

A change to std.json in Rig source, with no patch: `src/wsbits*.rig`.
- It classifies 64 bytes once into a non-space bitmap (`Simd[U8, 64]`
  compares, then `bits()`), and keeps the bitmap and its offset in two
  `Doc` fields.
- Each call is then a shift and `trailing_zeros()` on a register, and
  only a call outside the cached block classifies a new one.
- `wsbits3` adds an inlined entry: a byte above space returns at once,
  and so does one space followed by a byte above space.
- `+wsb_tbl` classifies the 64 bytes with four nibble lookups (a patch,
  since Rig has no lookup yet).
- `wsbits4` finds a missed run with the scalar loop and classifies the
  block off that path.
- `+vread` loads the 64 bytes through a vector pointer (candidate 3).

Mac:

| file | `wsbits` | `wsbits3` | `wsbits3+wsb_tbl` | `wsbits4+wsb_tbl` |
|---|---|---|---|---|
| twitter | 14% slower / 14% slower | 8% slower / 9% slower | 2% slower / 2% slower | 2% slower / 2% slower |
| twitterescaped | 11% slower / 11% slower | 6% slower / 6% slower | 8% slower / 8% slower | 6% slower / 6% slower |
| canada | 6% slower / 5% slower | 5% faster / 5% faster | 6% faster / 6% faster | 7% faster / 7% faster |
| citm_catalog | 3% faster / 4% faster | 16% faster / 16% faster | **24% faster / 24% faster** | 2% faster / 2% faster |
| gsoc-2018 | 12% slower / 12% slower | 8% slower / 6% slower | 3% slower / 3% slower | 4% slower / 4% slower |
| github_events | 16% slower / 16% slower | 11% slower / 11% slower | 4% slower / 4% slower | 3% slower / 3% slower |

pup:

| file | `wsbits3` | `wsbits3+wsb_tbl` | `wsbits3+vread` | `wsbits3+wsb_tbl+vread` |
|---|---|---|---|---|
| twitter | 52% slower / 53% slower | 52% slower / 53% slower | 8% faster / 9% faster | **10% faster / 10% faster** |
| twitterescaped | 7% slower / 7% slower | 9% slower / 9% slower | 9% slower / 9% slower | 8% slower / 8% slower |
| canada | 4% faster / 5% faster | 4% faster / 4% faster | 5% faster / 5% faster | 4% faster / 4% faster |
| citm_catalog | 59% slower / 60% slower | 59% slower / 60% slower | 31% faster / 31% faster | **34% faster / 35% faster** |
| gsoc-2018 | 42% slower / 42% slower | 41% slower / 42% slower | 4% faster / 4% faster | 4% faster / 3% faster |
| github_events | 55% slower / 56% slower | 55% slower / 56% slower | 11% faster / 12% faster | **13% faster / 13% faster** |

- **On x86 the bitmap wins once the 64-byte read is one load.** Without
  that, the read is 58% of citm_catalog's samples (candidate 3), and the
  bitmap is 41-60% slower on four files. With it, the bitmap is 34%
  faster on citm_catalog, 13% on github_events, 10% on twitter, and 4%
  on gsoc-2018 and canada.
  - On x86 `bits()` of 64 lanes is two `vpmovmskb`, so a refill is
    cheap.
  - The lookup adds 2-3 points (citm_catalog 31% to 34% faster).

- **On the Mac the lookup is what makes the bitmap nearly pay.** Four
  `tbl` + `cmeq` per 16 bytes replace four compares and three ORs. That
  lifts citm_catalog from 16% to 24% faster and cuts the losses
  elsewhere to 2-8%.
- **What is left is the refill.** A call that leaves the cached block
  loads 64 bytes, classifies them, reduces the mask (`addp`) and stores
  it to `Doc`, all on that call's path. That happens after every long
  string, which is why gsoc-2018 and github_events lose.
  - Moving the bitmap lookup and refill into one shared out-of-line
    function, behind the inlined entry, was worse on every file in dev
    runs: twitter 6% slower, citm_catalog only 18% faster.
  - Finding a missed run with the scalar loop (`wsbits4`) gives up
    citm_catalog's gain.
- The cache lives in `Doc` fields, so every hit loads it and every
  refill stores it. Locals in `document` would keep it in registers, but
  `key` is a separate method, and Rig has no multiple results to hand
  the cache back.

### 3. Wide vector reads (a runtime lowering)

`vread` (a runtime patch): `rig.simdRead` loads a vector of 16 bytes or
more through an `*align(1) const @Vector(n, T)` pointer. Today it copies
a `[n]u8` and bit-casts it.
- On aarch64 both forms are one `ldr q` or `ldp q, q`.
- On x86 (AVX2), LLVM builds a 64-byte vector from the array a byte at a
  time on the stack: about 64 byte loads and byte stores, then two
  `vmovdqa` reloads that wait on the stores.
- The 16-byte reads std.json uses today are already one `vmovdqu`.

| file | `vread` pup | `ws_tbl+vread` pup | `wsbits3+wsb_tbl` pup | `wsbits3+wsb_tbl+vread` pup |
|---|---|---|---|---|
| twitter | 0% / 0% | 2% faster / 1% faster | 52% slower / 53% slower | 10% faster / 10% faster |
| twitterescaped | 0% / 0% | 3% faster / 3% faster | 9% slower / 9% slower | 8% slower / 8% slower |
| canada | 0% / 0% | 4% faster / 4% faster | 4% faster / 4% faster | 4% faster / 4% faster |
| citm_catalog | 0% / 0% | 21% faster / 21% faster | 59% slower / 60% slower | 34% faster / 35% faster |
| gsoc-2018 | 0% / 0% | 0% / 0% | 41% slower / 42% slower | 4% faster / 3% faster |
| github_events | 0% / 0% | 4% faster / 4% faster | 55% slower / 56% slower | 13% faster / 13% faster |

It changes nothing that std.json does today. It turns 64-byte block
code on x86 from a large loss into a gain: 94 points on citm_catalog's bitmap, from 59% slower to
34% faster. The xbench study's 32-lane scan reads `Simd[U8, 32]` through
the same path. That path was not disassembled here for 32 bytes.

### 4. UTF-8 a vector at a time (Keiser-Lemire)

`utf8_kl`: once `plain` meets a byte of 0x80 or more, the rest of the
string goes 16 bytes a step, with the previous block carried.
- Each step does three nibble lookups (`tbl` / `pshufb`) on the byte
  before each lane and on the lane itself.
- It forms the bytes 1, 2 and 3 places back with a concatenating shift
  (`ext` / `palignr`), and makes the 3- and 4-byte tests with two
  saturating subtracts (`uqsub` / `psubusb`).
- At the first quote, backslash or control byte, the lanes from it on
  are cleared, so a sequence cut short there is an error.
- An error, or the input's last 15 bytes, goes back to the scalar loop,
  which reports the exact offset.

| file | Mac | pup |
|---|---|---|
| twitter | **6% faster / 6% faster** | **7% faster / 7% faster** |
| twitterescaped | 0% / 3% faster | 2% slower / 2% slower |
| canada | 0% / 0% | 1% slower / 0% |
| citm_catalog | 0% / 0% | 1% slower / 1% slower |
| gsoc-2018 | 1% slower / 0% | 0% / 1% faster |
| github_events | 0% / 0% | 1% slower / 1% slower |

- It pays where the text is non-ASCII (twitter, 15% of bytes) and
  costs nothing above 2% elsewhere.
- The step advances by 16, a constant, and the error vector is tested
  only once, at the string's end, so no read waits on a crossing.
- An inlined copy (`utf8_kl_in`) measured the same or 1% worse.

### 5. Escapes: copy while scanning, and hex digits by lookup

- `esc_copy16`: in an escaped string, the text between escapes is
  stored into the `String`'s reserved room 16 bytes at a time as it is
  scanned, and its first k bytes are kept. Today the run is scanned
  first and then appended with `String.add`.
- `esc_copy8` does the same a U64 at a time, with the SWAR test.
- `esc_hex16b` decodes `\uXXXX\uXXXX` (escaped CJK) from one 16-byte
  read.
  - Two nibble lookups check the eight hex digits and give their
    values, and two more gather them in order.
  - A shift and an OR pair them, and one crossing yields both code
    points.
  - The input advances by 12, a constant.
- `esc_hex16` gathered with `@shuffle` into an 8-lane vector instead.
  LLVM lowered that to eight `mov.b` lane moves and three `umov`, and it
  was 4% slower on twitterescaped.

| file | `esc_copy16` Mac | pup | `esc_copy8` Mac | `esc_hex16b` Mac | pup |
|---|---|---|---|---|---|
| twitter | 0% / 0% | 1% faster / 1% faster | 1% faster / 1% faster | 1% faster / 0% | 2% faster / 2% faster |
| twitterescaped | 0% / 0% | 1% faster / 1% faster | 1% faster / 1% faster | **4% faster / 4% faster** | 2% faster / 2% faster |
| canada | 0% / 0% | 0% / 0% | 1% faster / 0% | 0% / 0% | 0% / 0% |
| citm_catalog | 0% / 0% | 0% / 0% | 0% / 0% | 0% / 0% | 1% slower / 1% slower |
| gsoc-2018 | **6% faster / 5% faster** | **5% faster / 5% faster** | 12% slower / 13% slower | 0% / 0% | 1% faster / 1% faster |
| github_events | 0% / 0% | 1% faster / 1% faster | 1% slower / 1% slower | 1% slower / 0% | 0% / 0% |

- **The 16-byte copy pays where escaped strings are long** (gsoc-2018,
  6% and 5% faster).
  - The 8-byte SWAR copy loses 12% there. Its exit is a `ctz` of a
    word built from the data, once every 8 bytes; the vector's exit
    comes once every 16.
  - The operation it needs is a String write window: store a whole
    block into reserved room and keep its first k bytes. It is the
    "cheap word appends" open item, `DESIGN.md` item 4.
- **The hex decoder gains 4% on the Mac and 2% on x86**, and only with
  the lookup as the gather.

### 6. Digits 16 at a time with SIMD

`dig16` reads 16 bytes, takes `d = v -% '0'`, and finds the first lane
with `d >= 10` (`m.first()`).
- A lookup with indexes `iota + k - 16` moves the k digits to the top
  lanes. Out-of-range lanes read 0, so they become leading zeros.
- The value comes from pairwise multiply-adds.
  - On x86 that is `pmaddubsw`, `pmaddwd`, `packusdw` and `pmaddwd`:
    the classic SSE4.1 16-digit parse.
  - On NEON it is widening multiplies and pairwise adds (`umull`,
    `usra`).
- `dig16_port` uses the portable chain on x86 too. `dig16_sat` tests
  digits with a saturating subtract instead of a compare.

| file | `dig16` Mac | pup | `dig16_port` pup | `dig16_sat` Mac | pup |
|---|---|---|---|---|---|
| twitter | 1% slower / 2% slower | 2% faster / 2% faster | 1% faster / 1% faster | 2% slower / 2% slower | 2% faster / 2% faster |
| twitterescaped | 2% slower / 2% slower | 0% / 0% | 2% slower / 2% slower | 2% slower / 2% slower | 0% / 0% |
| canada | **19% slower / 20% slower** | 4% slower / 4% slower | 11% slower / 11% slower | 19% slower / 20% slower | 4% slower / 4% slower |
| citm_catalog | 5% slower / 5% slower | 0% / 1% faster | 0% / 0% | 5% slower / 5% slower | 0% / 1% faster |
| gsoc-2018 | 1% slower / 1% slower | 1% faster / 2% faster | 0% / 1% faster | 1% slower / 1% slower | 2% faster / 3% faster |
| github_events | 3% slower / 3% slower | 0% / 0% | 1% slower / 1% slower | 3% slower / 4% slower | 0% / 0% |

- **SWAR's 8 digits stay.** On canada, where 91% of numbers have 17
  digits, SIMD is 19% slower on the Mac and 4% slower on x86, while
  retiring 8% fewer instructions.
  - The digit run's end comes from a vector-to-register crossing
    (`shrn`/`fmov` or `pmovmskb`), then a lookup indexed by it, then a
    multiply chain and a second crossing.
  - The SWAR word's `ctz` never leaves the general registers.
- `pmaddubsw` is worth 7 points on x86 over the portable chain (canada
  4% against 11% slower), but not enough to win.
- **AVX-VNNI (`vpdpbusd`) and `udot` don't fit decimal conversion.** They
  sum four byte products into each 32-bit lane, so four digits need a
  weight of 1000, which no 8-bit weight holds. Two-digit pairs fit
  (≤ 99), but then four pairs sum into one lane.
- **A saturating subtract changes nothing** against `v >= 10`. LLVM
  already lowers the unsigned compare well on both targets.
- The first copy of this patch used checked `*` and `+` on vectors. In
  safe mode each checked lane-wise operation adds a reduction and a
  crossing (`umaxp`, `fmov`, `tbnz`). Wrapping arithmetic removed them;
  the numbers above are with wrapping.

### 7. The string scan's classifier as a nibble lookup

`scan_tbl`: simdjson's two nibble lookups and an AND in place of
`(v == '"') | (v == '\\') | (v < 0x20) | (v >= 0x80)`, at the landed
width and SWAR stage (16 lanes, `TIER = 16`). The width and stage sweep
is the xbench study's (RESULTS.md, "Linux x86 (pup)").

| file | Mac | pup |
|---|---|---|
| twitter | 0% / 0% | 2% faster / 2% faster |
| twitterescaped | 1% slower / 1% slower | 0% / 1% slower |
| canada | 0% / 0% | 0% / 0% |
| citm_catalog | 1% slower / 1% slower | 1% slower / 1% slower |
| gsoc-2018 | 1% slower / 0% | 3% slower / 2% slower |
| github_events | 1% slower / 1% slower | 2% slower / 2% slower |

No gain. The compares are already five instructions: LLVM folds
`(v < 0x20) | (v >= 0x80)` into one signed compare. The lookup form is
six instructions.

### 8. Mask handling, BMI2, carry-less multiply

- **The mask's first lane** is already the best form on each target.
  - NEON uses `shrn #4` and `fmov` (`m.first()`).
  - x86 uses `pmovmskb` and `tzcnt`.
  - No binary has an out-of-line call to a mask helper (#140 makes them
    `inline` regardless).
- **`pext` / `pdep`:** nothing in std.json compresses a mask, so there
  is no site.
- **`pclmulqdq` / `pmull`:** only a two-stage, simdjson-style parser
  needs a carry-less multiply. Nothing here measured it.

### 9. Combined

The candidates that won, together. "sonic-rs" is sonic-rs 0.5.10
(`target-cpu=native`) in the same interleaved run. Its cells compare it
with `base`, and the last row compares each column with sonic-rs, by
geomean over the six files.

Mac:

| file | UTF-8 + escapes | bitmap (`wsbits3+wsb_tbl+vread`) | **all** | sonic-rs |
|---|---|---|---|---|
| twitter | 5% faster / 5% faster | 2% slower / 3% slower | 4% faster / 4% faster | 4% slower |
| twitterescaped | 6% faster / 6% faster | 6% slower / 6% slower | 2% faster / 2% faster | 6% slower |
| canada | 0% / 0% | 8% faster / 8% faster | 7% faster / 8% faster | 3% faster |
| citm_catalog | 0% / 1% faster | 26% faster / 26% faster | 26% faster / 27% faster | 2% faster |
| gsoc-2018 | 4% faster / 4% faster | 4% slower / 3% slower | 0% / 0% | 2% faster |
| github_events | 1% faster / 0% | 4% slower / 4% slower | 3% slower / 3% slower | 5% slower |
| geomean against `base` | 3% faster | 2% faster | **6% faster** | 1% slower |
| geomean against sonic-rs | 4% faster | 4% faster | **7% faster** | |

pup:

| file | UTF-8 + escapes | bitmap | `ws_tbl` + UTF-8 + escapes | **all** | sonic-rs |
|---|---|---|---|---|---|
| twitter | 8% faster / 8% faster | 9% faster / 10% faster | 11% faster / 11% faster | 21% faster / 21% faster | 24% faster |
| twitterescaped | 6% faster / 6% faster | 8% slower / 8% slower | 13% faster / 13% faster | 2% faster / 2% faster | 5% faster |
| canada | 1% faster / 1% faster | 4% faster / 4% faster | 4% faster / 4% faster | 4% faster / 4% faster | 11% faster |
| citm_catalog | 1% slower / 1% slower | 35% faster / 36% faster | 20% faster / 20% faster | 36% faster / 36% faster | 41% faster |
| gsoc-2018 | 7% faster / 7% faster | 3% faster / 3% faster | 7% faster / 6% faster | 10% faster / 10% faster | 13% faster |
| github_events | 0% / 0% | 14% faster / 14% faster | 4% faster / 4% faster | 15% faster / 15% faster | 42% faster |
| geomean against `base` | 3% faster | 9% faster | 10% faster | **14% faster** | 22% faster |
| geomean against sonic-rs | 15% slower | 11% slower | 10% slower | **6% slower** | |

- **All of it** is the bitmap with its lookup and the vector read, plus
  Keiser-Lemire UTF-8 and both escape changes. It runs 14% faster on pup
  and 6% faster on the Mac. That closes two thirds of the x86 gap to
  sonic-rs (18% slower to 6% slower), and puts std.json 7% ahead of it
  on the Mac.
- **What is left on x86** is mostly github_events (19% behind sonic-rs)
  and the instruction count. With everything, std.json still retires
  8.0 instructions per byte on github_events against sonic-rs's 5.4.
  The bounds checks are the leaf of 27% of github_events' instructions,
  and the proofs work, not an opcode, is what removes them.
- **The bitmap costs twitterescaped 6-8% on both machines.** That file
  is minified, so it hardly uses the bitmap, but on the Mac the
  bitmap's inlined call sites push `key` out of line. Wherever a bitmap lands, its refill path needs
  to stay small.

## What to build in Rig, ranked

Ranked by measured time. Each item is a safe, portable Rig operation
or lowering: std.json must not hold target-specific code, so every
instruction choice belongs to the compiler. Gains are geomeans over the
six files, then the best file, from the tables above.

1. **Wide vector reads as one load: a runtime lowering.**
   - **Operation:** `bytes.read[Simd[T, n]](at)`, unchanged.
   - **Lowering:** for n >= 16, load through an `align(1)` vector pointer
     instead of copying `[n]u8` and bit-casting.
   - **Fallback:** the same Zig on every target, already one load on
     aarch64 and WASM.
   - **Gain:** nothing on today's std.json, which reads 16 bytes at a
     time. It decides whether any 32- or 64-byte block code can pay on
     x86: the whitespace bitmap goes from 39% slower to 9% faster on pup
     by geomean (citm_catalog from 59% slower to 34% faster).
   - It is the cheapest item here, a few lines in `simdRead`, and it
     should land first.
2. **A byte lookup, `t.lookup(idx)`.**
   - **Instructions:** `tbl` on NEON, `pshufb` on x86 (SSSE3), `i8x16.swizzle`
     on WASM; a 16-entry table, with an index of 16 or more giving 0.
     Docs/simd/PROPOSAL.md section 2.5 specifies it.
   - **Fallback:** a lane loop.
   - **What it backs:**
     - The bitmap's 64-byte classify. Mac: 2% slower to 2% faster by
       geomean, citm_catalog 16% to 24% faster. pup: citm_catalog 31% to
       34% faster.
     - Keiser-Lemire UTF-8: twitter 6% faster on the Mac, 7% on pup.
     - The `\u` hex-pair decoder: twitterescaped 4% faster on the Mac,
       2% on pup.
     - Per-run whitespace on x86: citm_catalog 20% faster with the
       lookup against 12% with compares.
   - **Estimated gain:** with items 1, 3, 4 and the bitmap, most of the
     combined 6% (Mac) and 14% (pup).
3. **A concatenating shift and a saturating subtract on vectors.**
   - **Operations:** `a.join(b).shuffle(IDX)` with constant indexes
     (`ext` / `palignr`; LLVM folds the shuffle to one instruction on
     both targets), and `-|` on `Simd` (`uqsub` / `psubusb`).
   - **Fallback:** portable lanes; Zig lowers both everywhere.
   - **Gain:** together with item 2, they make Keiser-Lemire UTF-8
     possible: twitter 6% faster (Mac) and 7% (pup), and 1% or less
     either way elsewhere.
   - On its own, `-|` gains nothing: a digit test written with it
     measured the same as the compare.
4. **A String write window: store a block, keep k bytes.**
   - **Operation:** for example `!t.push[Simd[U8, 16]](v, keep: k)`:
     reserve 16 bytes, store all 16 with one unaligned store, and
     advance the length by k (`DESIGN.md`, open item 4).
   - **Fallback:** the same on every target.
   - **Gain:** copying the text between escapes while it is scanned is
     1% faster by geomean on both machines; gsoc-2018 is 6% faster on
     the Mac and 5% on pup. The same window with a U64 and SWAR is 12%
     slower on gsoc-2018.
5. **Byte shuffles lowered to one lookup.**
   - **Operation:** `v.shuffle(IDX)` on bytes, with constant indexes.
   - **Lowering:** when LLVM would otherwise take the vector apart lane
     by lane (narrowing gathers such as 16 lanes to 8 or 4), emit one
     `tbl` / `pshufb` with a constant index vector.
   - **Gain:** it decided the hex-pair decoder: 4% slower with
     `@shuffle`'s lane moves, 4% faster with lookups (twitterescaped,
     Mac).

### Not worth building for std.json

- **SIMD digit parsing** (`pmaddubsw`/`pmaddwd`, `umull`/`addp`, `udot`,
  AVX-VNNI `vpdpbusd`). It runs 19% slower on canada on the Mac and 4%
  slower on pup. SWAR's 8 digits stay. Dot-product instructions can't
  hold the weight 1000 that four digits need.
- **A lookup in the string scan's classifier.** It is within 1% by
  geomean on both machines (0% on the Mac, 1% slower on pup): the four
  compares are already five instructions.
- **Vector whitespace per run** (`m.first()` on each run). On pup it is
  5% faster by geomean (citm_catalog 20% faster). On the Mac it is 20%
  slower (citm_catalog 26% slower). std.json can't choose per target,
  and the bitmap wins on both, so the bitmap is the form to keep.
- **`pext`/`pdep`, carry-less multiply, `udot` elsewhere:** std.json has
  no site for them.
- **Float conversion:** it already compiles to `clz` and `umulh`. What
  is left there is the shift's overflow check, which is proofs work.

### For std.json itself (not Rig)

- **The sonic-rs whitespace bitmap** (`src/wsbits3.rig`) is the largest
  single win once items 1 and 2 exist: 9% faster on pup and 2% faster
  on the Mac by geomean, and citm_catalog 26% (Mac) and 35% (pup)
  faster. It is expressible in safe Rig today. Its open problems:
  - The cache lives in `Doc` fields. Without multiple results it can't
    stay in `document`'s registers across `key`.
  - On the Mac its call sites push `key` out of line, and it costs
    twitterescaped 6-8% on both machines.
- **Keiser-Lemire UTF-8 and the hex-pair decoder** become std.json
  changes once items 2 and 3 exist. The escape copy needs item 4.

### Not measured here

- **32- and 64-lane mask lowering on NEON** (`bits()`, `first()`). That
  belongs to the xbench string-scan study, which found a 32-lane scan
  62-66% slower than the 16-lane one on gsoc-2018 on the Mac. The x86
  cause above, 32- and 64-byte reads assembled a byte at a time, should
  be ruled out there first. The Mac's wide reads are single loads.

## Reproducing

The scripts and patches are in `bench/json/opcodes/`. The four whole-parser
whitespace variants (`src/wsbits*.rig`) and the raw timing data
(`results/*.json`) are kept at the git tag `study-opcodes-20261012`, not on
`main`: `git show study-opcodes-20261012:bench/json/opcodes/src/wsbits.rig`.
