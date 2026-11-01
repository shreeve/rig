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
