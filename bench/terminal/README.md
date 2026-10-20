# Terminal benchmark

Times `std/terminal` against Ghostty's terminal (libghostty-vt, at the
commit `tools/terminal_ghostty.py` pins) and Dispatch's (Term, Paul
Miller's Swift port of Ghostty at the same commit) on generated program
output. It is not part of the test suite.

```sh
zig build                                   # bin/rig
bench/terminal/bench-terminal               # every corpus and variant
bench/terminal/bench-terminal --files tui --variants rig-fast,ghostty --reps 9
DISPATCH=~/src/dispatch bench/terminal/bench-terminal    # and Dispatch
GHOSTTY_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  bench/terminal/bench-terminal                           # and Ghostty's SIMD build
```

`bench/terminal/bench-terminal --help` lists the corpora, the variants,
and the options. Ghostty is built as `tools/terminal_ghostty.py` builds it:
it needs Ghostty's source (`$GHOSTTY`, or a clone) and Zig 0.16.0
(`$ZIG_GHOSTTY`, or mise's). Its module is built in ReleaseFast; a Zig
package that depends on Ghostty without naming an optimize mode gets its
Debug build, with Ghostty's slow safety checks, which runs a hundred times
slower. Dispatch is built from `$DISPATCH`, a Dispatch checkout: its Term
sources and `dispatch.swift` as one module, `swiftc -O -wmo`, with no
scrollback and mode 2027 off, as Ghostty starts (Dispatch's app turns it
on). `ghostty-simd` is Ghostty with its C++ SIMD paths (simdutf and
Highway). Zig 0.16's libc++ does not build against the macOS 27 SDK
(`INFINITY` is undeclared), and Zig asks `xcrun --sdk macosx` for the
SDK, ignoring `SDKROOT`; with `$GHOSTTY_SDK` set to an older SDK the
build runs with an `xcrun` that answers with it.

Each program feeds a whole corpus to new terminals, untimed setup aside,
and prints `<ns> <check>`. The check is a hash of the final screen and
cursor, the same `dump` the differential tests compare, so every run also
checks that std.terminal ends where Ghostty and Dispatch do on 16 MB of
input.

## Results

Apple M5, arm64, 120x40, fastest of interleaved runs, Ghostty without its
C++ SIMD paths. The machine was busy for the first two tables (load
average about 28, then about 55), so their numbers are low; variants ran
interleaved, so the ratios within a table hold.

2026-10-20, before std.terminal's fast paths (3 runs):

| corpus | rig-safe | rig-fast | ghostty | ghostty, 10 MB scrollback |
|---|---:|---:|---:|---:|
| text | 3.1 MB/s | 7.8 MB/s | 714.5 MB/s | 586.1 MB/s |
| scroll | 0.4 MB/s | 0.6 MB/s | 118.8 MB/s | 129.4 MB/s |
| sgr | 10.7 MB/s | 22.8 MB/s | 119.4 MB/s | 132.4 MB/s |
| tui | 108.8 MB/s | 133.6 MB/s | 139.3 MB/s | 143.1 MB/s |

2026-10-20, with cells packed in one list behind a row map (a scroll
moves map entries), printable runs found 16 bytes at a time and written
whole, and CR and LF outside the state machine (5 runs):

| corpus | rig-fast | rig-nocheck | ghostty | rig-fast / ghostty |
|---|---:|---:|---:|---:|
| text | 570.8 MB/s | 617.8 MB/s | 628.9 MB/s | 0.91 |
| scroll | 93.2 MB/s | 96.0 MB/s | 109.2 MB/s | 0.85 |
| sgr | 178.5 MB/s | 187.1 MB/s | 110.2 MB/s | 1.62 |
| tui | 226.3 MB/s | 249.1 MB/s | 138.2 MB/s | 1.64 |

Rig's bounds checks cost 3 to 10% (rig-nocheck). Ghostty's SIMD paths
would speed its text most; building them needs a Zig whose libc++ builds
against the macOS SDK, or a Linux machine.

2026-10-20, with wide runes and the Unicode 17 width table, Dispatch
added; a quieter machine (load average about 4; 5 runs):

| corpus | rig-safe | rig-fast | ghostty | ghostty, 10 MB scrollback | dispatch | rig-fast / ghostty |
|---|---:|---:|---:|---:|---:|---:|
| text | 592.2 MB/s | 782.5 MB/s | 1004.7 MB/s | 946.9 MB/s | 857.3 MB/s | 0.78 |
| scroll | 120.3 MB/s | 126.3 MB/s | 174.0 MB/s | 183.8 MB/s | 130.3 MB/s | 0.73 |
| sgr | 252.4 MB/s | 275.0 MB/s | 174.6 MB/s | 193.1 MB/s | 148.3 MB/s | 1.57 |
| tui | 302.7 MB/s | 332.0 MB/s | 203.1 MB/s | 202.5 MB/s | 166.7 MB/s | 1.63 |

A run just before wide runes, at a load average of about 6, gave
rig-fast / ghostty ratios of 0.79, 0.73, 1.64, and 1.71.

2026-10-20, Ghostty with its SIMD paths too, built against the macOS
26.5 SDK, and a utf8 corpus, two thirds of its bytes beyond ASCII (load
average about 2; 5 runs):

| corpus | rig-safe | rig-fast | ghostty | ghostty, 10 MB scrollback | ghostty, SIMD | dispatch | rig-fast / best Ghostty |
|---|---:|---:|---:|---:|---:|---:|---:|
| text | 611.2 MB/s | 803.8 MB/s | 1026.2 MB/s | 958.2 MB/s | 1014.9 MB/s | 867.0 MB/s | 0.78 |
| scroll | 124.7 MB/s | 132.2 MB/s | 177.6 MB/s | 187.7 MB/s | 174.9 MB/s | 132.7 MB/s | 0.70 |
| sgr | 253.9 MB/s | 275.2 MB/s | 174.8 MB/s | 194.3 MB/s | 176.3 MB/s | 149.0 MB/s | 1.42 |
| tui | 299.9 MB/s | 328.1 MB/s | 203.7 MB/s | 204.4 MB/s | 206.0 MB/s | 167.6 MB/s | 1.59 |
| utf8 | 213.7 MB/s | 221.9 MB/s | 263.9 MB/s | 259.1 MB/s | 346.8 MB/s | 225.9 MB/s | 0.64 |

On the ASCII corpora the SIMD paths change Ghostty's speed by no more
than the noise: its time goes to printing and scrolling. On utf8 they
make it 31% faster, decoding runs of runes at once (simdutf), where
std.terminal decodes a byte at a time through `utf8.Decoder` and looks
each rune's width up alone. The SIMD build answers every case of the
differential file as the plain one does.

2026-10-20, with UTF-8 decoded in runs (`print_utf8`) and its runes
written straight into their cells (load average about 4; 5 runs):

| corpus | rig-safe | rig-fast | ghostty | ghostty, 10 MB scrollback | ghostty, SIMD | dispatch | rig-fast / best Ghostty |
|---|---:|---:|---:|---:|---:|---:|---:|
| text | 593.4 MB/s | 775.5 MB/s | 998.9 MB/s | 916.5 MB/s | 994.8 MB/s | 852.8 MB/s | 0.78 |
| scroll | 119.9 MB/s | 128.0 MB/s | 172.5 MB/s | 183.4 MB/s | 172.4 MB/s | 127.1 MB/s | 0.70 |
| sgr | 250.0 MB/s | 272.0 MB/s | 171.4 MB/s | 183.7 MB/s | 171.4 MB/s | 140.5 MB/s | 1.48 |
| tui | 295.3 MB/s | 322.7 MB/s | 198.3 MB/s | 199.0 MB/s | 200.2 MB/s | 164.3 MB/s | 1.61 |
| utf8 | 360.5 MB/s | 389.8 MB/s | 257.7 MB/s | 250.3 MB/s | 336.2 MB/s | 219.9 MB/s | 1.16 |

utf8 went from 221.9 to 389.8 MB/s; the other corpora do not reach the
new path.

2026-10-20, with erasing that clears only the cells a row has written
(a row keeps how far it has been written, and an empty cell with no
background is 0, which is cleared at memset's speed), a full-screen
scroll that moves one entry of the row map, and CR LF taken at once
(load average about 4; 5 runs):

| corpus | rig-safe | rig-fast | ghostty | ghostty, 10 MB scrollback | ghostty, SIMD | dispatch | rig-fast / best Ghostty |
|---|---:|---:|---:|---:|---:|---:|---:|
| text | 825.5 MB/s | 1201.8 MB/s | 1006.9 MB/s | 940.4 MB/s | 1008.4 MB/s | 857.7 MB/s | 1.19 |
| scroll | 251.3 MB/s | 280.2 MB/s | 176.0 MB/s | 187.3 MB/s | 173.3 MB/s | 129.7 MB/s | 1.50 |
| sgr | 265.2 MB/s | 275.5 MB/s | 175.6 MB/s | 195.5 MB/s | 175.5 MB/s | 145.5 MB/s | 1.41 |
| tui | 309.3 MB/s | 320.1 MB/s | 184.7 MB/s | 177.4 MB/s | 180.6 MB/s | 147.4 MB/s | 1.73 |
| utf8 | 307.7 MB/s | 356.4 MB/s | 232.3 MB/s | 224.3 MB/s | 299.6 MB/s | 195.3 MB/s | 1.19 |

A scroll had cost 36 ns, three quarters of it filling the new row with
an erased cell: Zig's `@memset` of a U64 that is not 0 stores one cell
at a time. It now costs about 8 ns, where Ghostty's costs 18.

2026-10-20, with a CSI sequence read whole, a run of ASCII widened into
cells sixteen at a time (std/cells.zig) and scanned eight bytes at a
time, mode 2027 kept on the fast path, and styles found by key past 32;
two corpora added, utf8-2027 and rgb (truecolor). Other sessions' builds
held the load average between 8 and 28, so every number is low; the
variants ran interleaved, and the ratios hold (5 runs):

| corpus | rig-safe | rig-fast | ghostty | ghostty, 10 MB scrollback | ghostty, SIMD | dispatch | rig-fast / best Ghostty |
|---|---:|---:|---:|---:|---:|---:|---:|
| text | 1496.2 MB/s | 1489.1 MB/s | 865.9 MB/s | 819.0 MB/s | 840.5 MB/s | 759.4 MB/s | 1.72 |
| scroll | 247.8 MB/s | 262.7 MB/s | 158.0 MB/s | 156.6 MB/s | 154.4 MB/s | 113.5 MB/s | 1.66 |
| sgr | 279.8 MB/s | 310.9 MB/s | 157.7 MB/s | 173.7 MB/s | 157.6 MB/s | 135.6 MB/s | 1.79 |
| tui | 455.1 MB/s | 478.0 MB/s | 190.1 MB/s | 190.0 MB/s | 191.4 MB/s | 151.0 MB/s | 2.50 |
| utf8 | 327.2 MB/s | 365.4 MB/s | 244.5 MB/s | 239.2 MB/s | 318.2 MB/s | 208.2 MB/s | 1.15 |
| utf8-2027 | 261.3 MB/s | 294.5 MB/s | 238.5 MB/s | 230.9 MB/s | 308.2 MB/s | 200.2 MB/s | 0.96 |
| rgb | 280.0 MB/s | 306.0 MB/s | 219.7 MB/s | 161.6 MB/s | 213.6 MB/s | 190.3 MB/s | 1.39 |

Before this branch rgb ran at 0.4 MB/s: each SGR looked its pen up in a
list of styles that only grows. With mode 2027 on, UTF-8 is still a
little behind Ghostty's SIMD build, and ahead of its plain one.
