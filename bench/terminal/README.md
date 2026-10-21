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

Apple M5, arm64, 120x40, fastest of 7 interleaved runs. `rig-safe` and
`rig-fast` keep std.terminal's default history, 10,000 rows (about
9.6 MB at 120 columns); `ghostty, 10 MB scrollback` keeps Ghostty's
default, about as much. `ghostty` is Ghostty without its C++ SIMD paths
or scrollback, `ghostty, SIMD` with those paths. Other builds held the
machine's load average between 18 and 23, so every number is low; the
variants ran interleaved, so the ratios hold.

| corpus | rig-safe | rig-fast | rig-fast, no scrollback | ghostty | ghostty, 10 MB scrollback | ghostty, SIMD | dispatch | rig-fast / best Ghostty |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| text | 1143.9 MB/s | 1196.7 MB/s | 1499.5 MB/s | 872.8 MB/s | 772.9 MB/s | 863.8 MB/s | 742.5 MB/s | 1.37 |
| scroll | 203.3 MB/s | 214.7 MB/s | 238.5 MB/s | 151.3 MB/s | 156.7 MB/s | 153.0 MB/s | 115.0 MB/s | 1.37 |
| sgr | 257.3 MB/s | 278.6 MB/s | 288.4 MB/s | 160.0 MB/s | 167.4 MB/s | 149.7 MB/s | 126.3 MB/s | 1.66 |
| tui | 353.3 MB/s | 351.7 MB/s | 357.2 MB/s | 149.2 MB/s | 153.1 MB/s | 157.8 MB/s | 121.3 MB/s | 2.23 |
| utf8 | 214.3 MB/s | 250.3 MB/s | 261.4 MB/s | 191.4 MB/s | 183.2 MB/s | 221.4 MB/s | 150.6 MB/s | 1.13 |
| utf8-2027 | 191.4 MB/s | 228.6 MB/s | 229.4 MB/s | 167.4 MB/s | 164.0 MB/s | 224.7 MB/s | 145.1 MB/s | 1.02 |
| rgb | 193.6 MB/s | 218.5 MB/s | 216.7 MB/s | 175.0 MB/s | 131.4 MB/s | 169.3 MB/s | 142.2 MB/s | 1.25 |

The last column is rig-fast, with its history, over the fastest Ghostty
build, with or without history. Rig is ahead on every corpus; on
`utf8-2027`, the corpus with mode 2027 on, it is about even with
Ghostty's SIMD build. Ghostty's SIMD paths change its speed on the ASCII
corpora by no more than the noise; on `utf8` they decode runs of runes
at once (simdutf), where std.terminal decodes runs of UTF-8 itself
(`print_utf8`) and writes the runes straight into their cells.

History costs most on `text`, where nearly every line scrolls a row into
it: each benchmark run is a new terminal, so the history's 9.6 MB is new
memory, touched for the first time. A terminal that lives on reuses its
oldest rows, and a scroll moves row numbers, not cells. Its first row of
history reserves room for the rest at once (up to 65,536 rows), so the
cells grow without being copied; growing them a row at a time cost
`text` a third of its speed.

Two costs shaped the cell writes. A scroll once cost most of its time
filling the new row with an erased cell: Zig's `@memset` of a U64 that
is not 0 stores one cell at a time, so an empty cell with no background
is 0, which is cleared at memset's speed, and a full-screen scroll moves
one entry of the row map. And each SGR once looked its pen up in a list
of styles that only grows, which made `rgb` (truecolor) crawl; styles
past 32 are found by key.
