# Terminal benchmark

Times `std/terminal` against Ghostty's terminal (libghostty-vt, at the
commit `tools/terminal_ghostty.py` pins) on generated program output. It
is not part of the test suite.

```sh
zig build                                   # bin/rig
bench/terminal/bench-terminal               # every corpus and variant
bench/terminal/bench-terminal --files tui --variants rig-fast,ghostty --reps 9
```

`bench/terminal/bench-terminal --help` lists the corpora, the variants,
and the options. Ghostty is built as `tools/terminal_ghostty.py` builds it:
it needs Ghostty's source (`$GHOSTTY`, or a clone) and Zig 0.16.0
(`$ZIG_GHOSTTY`, or mise's). Its module is built in ReleaseFast; a Zig
package that depends on Ghostty without naming an optimize mode gets its
Debug build, with Ghostty's slow safety checks, which runs a hundred times
slower.

Each program feeds a whole corpus to new terminals, untimed setup aside,
and prints `<ns> <check>`. The check is a hash of the final screen and
cursor, the same `dump` the differential tests compare, so every run also
checks that std.terminal ends where Ghostty does on 16 MB of input.

## Baseline

2026-10-20, Apple M5, arm64, 120x40, fastest of 3 interleaved runs,
before any of std.terminal's fast paths; Ghostty without its C++ SIMD
paths. The machine was busy (load average about 28), so every number is
low; the variants ran interleaved, so their ratios hold.

| corpus | rig-safe | rig-fast | ghostty | ghostty, 10 MB scrollback |
|---|---:|---:|---:|---:|
| text | 3.1 MB/s | 7.8 MB/s | 714.5 MB/s | 586.1 MB/s |
| scroll | 0.4 MB/s | 0.6 MB/s | 118.8 MB/s | 129.4 MB/s |
| sgr | 10.7 MB/s | 22.8 MB/s | 119.4 MB/s | 132.4 MB/s |
| tui | 108.8 MB/s | 133.6 MB/s | 139.3 MB/s | 143.1 MB/s |

std.terminal matches Ghostty where little scrolls (tui) and falls behind
as scrolling grows, because each scroll copies the whole screen; the
row map that makes a scroll a rotation of row indices comes next.
