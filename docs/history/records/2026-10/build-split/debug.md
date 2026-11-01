# Split debug builds: the measurement that set the rule (2026-11-01)

Queue row 23c, after the release study in [README.md](README.md).
It was measured before the compiler changed: the prototype
(`split.py`, `build.sh`) cut Trig main's emitted debug package (218,459
lines of program and std Zig, 26,649 of runtime). Then the compiler's own
split build was measured the same way.

## Trig's debug build (`-Odebug`), one unit against N

| | Mac (arm64, LLVM) | pup, 8 E-cores (Zig's x86 backend) |
|---|---|---|
| 1 unit | **291.5 s**, 9.5 GB, one thread | **17.1 s**, 1.0 GB, threaded (38 s of CPU) |
| 2 units | 109.1 s (units 56 and 107 s, link 1.6 s) | |
| 4 units | 61.9 s (units 32 to 60 s, link 1.6 s) | |
| 8 units | **31.9 s** (units 15 to 30 s, link 1.5 s), 9.9 GB summed | **21.2 s** (units 7.5 to 10.9 s, link 10.9 s), 11.6 GB summed |
| 10 units, the compiler's split | **30 s** of Zig (units 28 s, link 2 s) | |

- **The Mac:** the 8-unit build is 9.1 times faster. The binary prints
  the same as one unit's on mitt.
- **The compiler's 10-unit build:** the binary prints the same as one
  unit's on all six cli projects (`--noEmit`), on ts-pattern with 4
  checkers, and on zod3 with `--pretty`. It cuts 4,340 functions.
- **Load:** other sessions' builds loaded the Mac during these runs
  (load 8 to 30), so the times are rough; the ratios are far beyond that.
- **LLVM's cost grows faster than its module:** the 8 units retire
  1.43 T instructions in all, against 5.53 T for one unit, and 2 units
  already halve the CPU (160 s against 289 s).
- **The cut is unbalanced** (15 to 30 s at 8 units), so a cut by
  measured cost could bring the wall nearer 22 s.
- **pup:** 24% slower split. A unit compiles on one thread, and the
  link (the entry's `build-exe` compiling std again and linking 670 MB
  of objects) takes 10.9 s alone, two thirds of a one-unit build. No
  count of units wins there.
- **`-fno-llvm` on the Mac** (Zig's own arm64 backend) crashed after
  248 s at a 118 GB peak footprint.
- **A hello world** builds in 1.4 s, which bounds a unit's fixed cost.

## The rule (approved for the owner by Rig - Swiss)

1. **Split only when Zig builds with LLVM:** every debug build but
   x86-64's, and a release build only with `--units=N`.
2. **Threshold:** the program's own modules, std's not counted (Zig
   compiles only what the program uses of them), reach two chunks of
   9,000 lines, into one unit a chunk, up to the cores.
3. **std's process state is per unit:** a Linux split binary panicked
   in `std.Thread.spawn` until each unit took the entry's thread-local
   layout (`linux.tls.area_desc`) and auxiliary vector
   (`elf_aux_maybe`), which Zig's start code sets only in the
   executable's std. With that, the pup split binary prints the same as
   one unit's on mitt.

## Release builds on pup, built by the compiler

Trig main (`4bc7a9a`'s sources as of the Mac checkout), release
(`--release`), pup E-cores; then timed on a P-core (core 6) with
`time-ab.sh` (60 rounds on mitt, neverthrow, superstruct; 20 on zod3,
ts-pattern, tiny-invariant; arms shuffled each round, after a warm-up),
`--singleThreaded`.

- **Build:** 28.6 min as one unit (1,677 s of CPU, 10.3 GB), 3.1 min
  as 8 units (`--units=8`, 2.6 GB the largest process): about 9.3 times
  faster.
- **One unit, the branch against main:** the same instructions on every
  project (each arm's range overlaps main's to the last few thousand),
  and time within the A/A arm's spread (the branch 0.48% faster to
  0.18% slower, a byte-identical copy of main 0.15% faster to 0.52%
  slower). The cells, and the thread-locals' new order in the TLS
  block, cost nothing.
- **8 units against one:** 7.7% (mitt) to 14.1% (zod3) slower,
  ts-pattern 12.9%; 6.6 to 10.2% more instructions; about 4 MB more
  RSS. The output is the same on every project. A split release build
  suits a check of an A/B's outputs, not its timing.
- **The runtime benches** (`bench/tasks`, `actors`, `net`, `http`,
  rig-fast): the binaries main and the branch build disassemble the same
  but for one `cmp`/`je` written `test`/`jne`; two interleaved rounds
  moved both ways within each row's own spread.

## Gates

The full suite, `zig build test` on the Mac and on pup (debug, safe,
fast), `tools/emit-diff 43cdd0cc9` (every program module the same, Trig's
included; the runtime differs by the cells), the JSON and Map guards
(within 0.2%, or fewer instructions), Trig's light gate (GREEN, and
GREEN again with its debug Trig built as 8 units), and loco's light gate
(GREEN).
