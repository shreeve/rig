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
on).

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
