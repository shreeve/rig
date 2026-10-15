# JSON benchmark

Builds and times `std/json.rig` against Zig's `std.json` and the fastest
JSON parsers in Zig and Rust. It is not part of the test suite or CI. The
measurements it made are in [docs/json/RESULTS.md](../../docs/json/RESULTS.md).

Every program reads one file, untimed, then parses it N times and prints
`<ns> <check>`. MB/s is bytes times N over the time, with MB = 10^6.

## Data

The corpus files are the third-party ones `./test/run json` reads. Fetch
them once from the repository root:

```sh
tools/fetch-json-data.sh        # into test/json/data/ (untracked)
```

## Rig and Zig variants: `bench-json`

```sh
zig build                                   # bin/rig
cpuq run --cores 2-6 --label rig:json -- bench/json/bench-json
```

That builds each variant and times them interleaved, keeping each one's
fastest run. The default variants are `rig-safe` (`rig build --release`,
Zig's safe mode, every check kept), `rig-fast`, and Zig's `std.json`
building the same tape or its `Value`, each in `-OReleaseSafe` and
`-OReleaseFast`. `bench/json/bench-json --help` lists the options, among
them `--files`, `--variants` (including `rig-safe@TIER=0`, which rewrites
a module constant of `std/json.rig`, and `rig-nocheck`, an experiment that
removes the runtime's bounds checks to size them), `--reps` and `--ms`.

For numbers that hold still, build once and time on a quiet machine:

```sh
D=$(mktemp -d)
cpuq run --cores 2-6 --label rig:json -- bench/json/bench-json --out $D --build-only
cpuq run --exclusive --cores 1 --label rig:json -- bench/json/bench-json --out $D --time-only --reps 15
```

Run without `cpuq`, it prints a note and runs anyway: the numbers are
then only as steady as the machine.

## The guard: `guard.py`

```sh
cpuq run --cores 2 --label rig:json -- bench/json/guard.py            # check
cpuq run --cores 2 --label rig:json -- bench/json/guard.py --update   # new baseline
```

The deep gate runs it on the Mac. It builds `rig-safe` for the six
corpus files and counts instructions retired per byte. These counts
don't move with the machine's load, so it can run on a busy machine.
Any file more than 2% above its baseline in `guard.txt` fails the guard.
A change meant to move the counts, such as a faster parser or a new Zig,
commits a new baseline with `--update`.

## The string-scan sweep: `xbench.sh`

`xbench.sh build|time|perf OUT` builds, times and counts the sweep of
`skip_plain_ascii` (SWAR stage of 16, 32 or 64 bytes or none, 16- or 32-lane
SIMD, `variants/simd32.py`) next to the competitors, on Linux or macOS;
`timers/perf.py` counts cycles and instructions per byte with Linux
`perf stat`, and `PIN=CPU` pins `timers/time.py` with `taskset`. Results:
the "Linux x86 (pup)" section of docs/json/RESULTS.md.

## Competitors

Each binary takes `FILE N`, like the Rig programs.

- `rust-bench/`: serde_json (default, and `float_roundtrip`), simd-json
  (tape and value) and sonic-rs (`Value`), at the crate versions
  their `Cargo.toml` files pin. `rust-bench/build.sh native|generic` builds
  all four crates (`native` is `-C target-cpu=native`; it needs `cargo`,
  and fetches crates on its first run). `rust-bench/smoke.sh` runs every
  binary on every corpus file for a rough MB/s.
- `zimdjson/`: zimdjson's DOM and on-demand parsers. `zimdjson/build.sh
  dom|od fast|safe` clones zimdjson at a pinned revision into
  `zimdjson/upstream`, applies `zig-0.17.patch` (to build on Zig 0.17),
  and builds `prog-dom-fast` and so on.
- `cbench/`: simdjson's DOM parser (C++) and yyjson (C), each at a pinned
  release. `cbench/build.sh` clones them into `cbench/upstream` and
  builds `prog-simdjson-dom` and `prog-yyjson` (`-O3 -DNDEBUG` for the
  native CPU; it needs `cc` and `c++`; GCC and Clang both build it). Both validate as std.json does
  (yyjson with every `YYJSON_DISABLE_*` switch off, read flags 0), reuse
  their buffers between runs, and are called from a separate translation
  unit, so neither is inlined into the benchmark's loop.

## Timers

These time `bench-json --out` builds and the competitors together:

| Script | What it does |
|---|---|
| `timers/time.py VARIANTS [REPS]` | interleaved MB/s, fastest of N; the variants are the `bench-json` ones plus the competitors (`serde_json`, `simd-json-tape`, `sonic-rs`, `zimdjson-dom-fast`, `simdjson-dom`, `yyjson`, ...). Set `BENCH_OUT` to the `--out` directory |
| `timers/timeall.py VARIANTS [REPS]` | the same over the five main corpus files |
| `timers/cyc.py DIR FILES VARIANTS` | wall time, cycles, and instructions of builds in `DIR`, from `/usr/bin/time -l` (macOS) |
| `timers/ins.py DIR FILES VARIANTS` | instructions retired per byte, exact under load: (instructions of N parses minus those of one) over (N - 1) and the file's size |
| `timers/ipc.py NAME=COMMAND ...` | instructions and cycles per byte, and IPC, for any parsers that take `[FILE] N`, std.json's builds and the competitors alike |
| `timers/nibble.py`, `timers/zigpatch.sh` | patch the emitted Zig to try a lowering (`RIG ZIG=timers/zigpatch.sh`, with `NIB_MODE`) before Rig ships it |

The instruction and cycle counters (`cyc.py`, `ins.py`, `ipc.py`) read
the counters `/usr/bin/time -l` prints on macOS, so they run there only.
Instructions per byte are the measure to trust when the machine is
loaded: wall time moves by 7% with the load and the cycle count by as
much as 16%, since it follows the core and the clock the program runs
on, while instructions do not. One run's instruction count can still be
off by several percent either way, so the tools take the median of 5.
Instructions are not time, though: a change can retire fewer and run
slower (docs/RIG-NOTES.md, entry 25), so a change to a hot loop is judged
by exclusive timing on both machines.

## Checks: `checks/`

What std.json's safety checks cost after the compiler has removed the
ones it proves. Both tools run on macOS; RESULTS.md, "Checks and IPC
after proofs2", has what they found.

```sh
D=$(mktemp -d)
RIG_OUT_DIR=$D/pkg bin/rig build --release -o $D/probe bench/json/checks/probe.rig
bench/json/checks/inventory.py $D/pkg __rig_std_json.zig       # each check left, per line, aarch64 and x86_64
cpuq run --cores 2 --label rig:json -- bench/json/checks/sizing.py $D/sz   # each class's cost
BENCH_OUT=$D/sz python3 bench/json/timers/time.py base,sread 15      # and in time
```

- `inventory.py PKG MODULE.zig [TARGET...]` builds an emitted package
  `-O ReleaseSafe` for each target, finds every branch into a panic
  block, and charges it through DWARF's inline chain to a line of the
  module. It names the runtime routine that made each check.
- `sizing.py OUT` builds the six corpus programs, then copies with one
  class of checks made unchecked, and counts instructions per byte. A
  check is made unchecked as a proof emits it, runtime safety off around
  the original expression, which keeps LLVM's no-overflow fact; wrapping
  `+%` loses it and adds instructions. Its patches match the emitted
  text, and one that matches nothing stops the run.

## Generators

- `gen-json-tables.py` prints the power-of-five table `std/json.rig`'s
  float parser uses (`--check` compares it with sonic-rs's).
- `json-string-stats.py` measures the length of strings in the corpus
  files, which sets the tiers of the string scan (docs/json/DESIGN.md).
