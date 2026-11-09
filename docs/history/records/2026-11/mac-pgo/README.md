# Profile-guided optimization on the Mac (2026-11-09)

`rig build --release --pgo` on arm64 macOS. The design is
[design.md](design.md); the timing script is [time.py](time.py) and its
output [table.txt](table.txt).

**Measured.** Trig 242fb6f on Rig ec0a2a743 plus this change, plain build
against the profile build, trained by Trig's `tools/trig/bolt-train`
(mitt, neverthrow, superstruct, zod3). The three projects timed are not
in the training: tiny-invariant, ts-pattern, and dify's contracts, at 1,
4, and 8 checkers, with the bundled libs prebuilt and not. 20 rounds per
cell, three arms shuffled in each round (plain, a copy of plain, profile),
medians, on the Mac under its timing slot.

| Project | Faster, 1 / 4 / 8 checkers (libs off) | Instructions fewer | A/A |
|---|---|---|---|
| tiny-invariant | 11.5% / 8.6% / 6.1% | 13.3-19.5% | 1.0% at most |
| ts-pattern | 14.2% / 13.8% / 13.9% | 11.0-11.1% | 0.1% at most |
| contracts | 15.3% / 14.0% / 14.9% | 13.3-14.4% | 0.6% at most |

With the libs prebuilt: 5.3-15.4% faster. Output is byte-identical to the
plain build on all seven projects, 1, 2, 4, and 8 checkers, libs on and
off (56 comparisons).

**Memory.** Peak footprint is level to 2.7 MiB higher (at most 1.4%); the
executable is 1.2 MiB larger. The build itself peaks at 9.9 GB against
7.9 GB for the plain build, and took 15 minutes, on the Mac's 32 GB.

**Why Apple's `ld` links the instrumented build.** Raw profiles from any
program linked by Zig's Mach-O linker fail in Apple's llvm-profdata and in
LLVM 22's: "counter offset N is greater than the maximum counter offset".
The same object linked by Apple's `ld` merges. Plain C through `zig cc`
fails the same way, so the fault is that linker's. Zig's linker still
links the optimized build, which has no counters.
