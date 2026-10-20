# Terminal benchmark

Times `std/terminal` against Ghostty's terminal (libghostty-vt, at the
commit `tools/terminal_ghostty.py` pins) and Dispatch's (Term, Paul
Miller's Swift port of Ghostty at the same commit) on generated program
output. It is not part of the test suite.

```sh
zig build                                   # bin/rig
bench/terminal/bench-terminal               # every corpus and variant
bench/terminal/bench-terminal --files tui --variants rig-fast,ghostty --reps 9
DISPATCH=/path/to/dispatch bench/terminal/bench-terminal  # and Dispatch
GHOSTTY_SDK=/path/to/an/older/MacOSX.sdk \
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

Apple M5, arm64, 120x40, fastest of 5 interleaved runs; `ghostty` is
Ghostty without its C++ SIMD paths, `ghostty, SIMD` with them. Other
builds held the machine's load average between 8 and 28, so every number
is low; the variants ran interleaved, so the ratios hold.

| corpus | rig-safe | rig-fast | ghostty | ghostty, 10 MB scrollback | ghostty, SIMD | dispatch | rig-fast / best Ghostty |
|---|---:|---:|---:|---:|---:|---:|---:|
| text | 1496.2 MB/s | 1489.1 MB/s | 865.9 MB/s | 819.0 MB/s | 840.5 MB/s | 759.4 MB/s | 1.72 |
| scroll | 247.8 MB/s | 262.7 MB/s | 158.0 MB/s | 156.6 MB/s | 154.4 MB/s | 113.5 MB/s | 1.66 |
| sgr | 279.8 MB/s | 310.9 MB/s | 157.7 MB/s | 173.7 MB/s | 157.6 MB/s | 135.6 MB/s | 1.79 |
| tui | 455.1 MB/s | 478.0 MB/s | 190.1 MB/s | 190.0 MB/s | 191.4 MB/s | 151.0 MB/s | 2.50 |
| utf8 | 327.2 MB/s | 365.4 MB/s | 244.5 MB/s | 239.2 MB/s | 318.2 MB/s | 208.2 MB/s | 1.15 |
| utf8-2027 | 261.3 MB/s | 294.5 MB/s | 238.5 MB/s | 230.9 MB/s | 308.2 MB/s | 200.2 MB/s | 0.96 |
| rgb | 280.0 MB/s | 306.0 MB/s | 219.7 MB/s | 161.6 MB/s | 213.6 MB/s | 190.3 MB/s | 1.39 |

The last column is rig-fast over the faster Ghostty build. Rig is
ahead on every corpus but `utf8-2027`, the corpus with mode 2027 on,
where it is a little behind Ghostty's SIMD build and ahead of its plain
one. Ghostty's SIMD paths change its speed on the ASCII corpora by no
more than the noise; on `utf8` they decode runs of runes at once
(simdutf), where std.terminal decodes runs of UTF-8 itself
(`print_utf8`) and writes the runes straight into their cells.

Two costs shaped the cell writes. A scroll once cost most of its time
filling the new row with an erased cell: Zig's `@memset` of a U64 that
is not 0 stores one cell at a time, so an empty cell with no background
is 0, which is cleared at memset's speed, and a full-screen scroll moves
one entry of the row map. And each SGR once looked its pen up in a list
of styles that only grows, which made `rgb` (truecolor) crawl; styles
past 32 are found by key.
