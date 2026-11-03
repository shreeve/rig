# Row 23c: split builds, the measurement that decides it (2026-11-01)

Rig - Rust (fork). This was measured before any compiler change. The
cut was made by the build-split-study prototype (`split.py`, `build.sh`)
on the emitted debug package of Trig main: 218,459 lines of program
and std Zig, plus 26,649 lines of runtime.

## Trig's debug build (`-Odebug`), one unit against N

| | Mac (M-series, LLVM) | pup, 8 E-cores (Zig's x86 backend) |
|---|---|---|
| 1 unit | **291.5 s**, 9.5 GB, one thread | **17.1 s**, 1.0 GB, threaded (38 s CPU) |
| 2 units | 109.1 s (units 56 and 107 s, link 1.6) | |
| 4 units | 61.9 s (units 32 to 60 s, link 1.6) | |
| 8 units | **31.9 s** (units 15 to 30 s, link 1.5), 9.9 GB summed | **21.2 s** (units 7.5 to 10.9 s, link 10.9), 11.6 GB summed |

Notes on the table:

- **Mac at 8 units:** 9.1 times faster. The binary runs, and its output
  on mitt is identical to one unit's.
- **The Mac's load:** 8 to 30 during these runs (other sessions' builds
  through heavy), so its times are rough. The ratios are far beyond that
  noise.
- **LLVM's cost grows faster than the code:** the 8 units retire 1.43 T
  instructions in all, against 5.53 T for one unit. Two units already
  halve the CPU (160 s against 289).
- **The cut is unbalanced** (15 to 30 s at 8 units). A cut balanced by
  size would bring the 8-unit build toward 22 s.
- **pup at 8 units:** 24% slower. Each unit runs single-threaded, and the
  link (the entry's `build-exe`, which compiles std again and links
  670 MB of objects) takes 10.9 s alone, two thirds of a one-unit
  build. No unit count wins there.
- **`-fno-llvm` on the Mac** (Zig's own aarch64 backend): crashed after
  248 s with a 118 GB peak footprint. It is not an option.
- **Hello-world** debug build: 1.4 s, which bounds a unit's fixed cost.

## What it means for the design

1. **Split only when Zig builds with LLVM.** Today that is every
   aarch64 debug build and every release build. x86-64 debug builds use
   Zig's own backend, which is threaded and fast, and stay one unit.
   `--units N` overrides either way.
2. **Threshold:** split once the emitted program (not counting the
   runtime) reaches 20k lines, into N = min(cores, lines / 10k) units.
   A unit's fixed cost is about 1.4 s, and its own code costs about
   1 s per 1k lines on the Mac. To be checked on one mid-size program
   while building.
3. **The cut is balanced by emitted size**, not by function count.
4. **std's process state is per unit:** a Linux split binary panics in
   `std.Thread.spawn`, because `linux.tls.area_desc` is set only in the
   entry's copy of std. Any split on Linux (release `--units N` on pup)
   needs std's start-up state shared too: TLS area, environ, argv, and
   debug info. The Mac did not hit it because there std's threads go
   through libc.
