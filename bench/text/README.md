# Text search benchmark

Times std.text's `find` (`std/text.zig`) and holds it to what it has won.

```sh
zig build                                              # bin/rig
bench/text/guard.py                                    # the guard: no row more than 2% above guard.txt
tools/low bench/text/bench-text "$(tools/baseline origin/main)" bin/rig lib.dom.d.ts 9
```

## The guard

`guard.py` builds `guard.rig` with `rig build --release` and compares
each row's instructions retired per search with `guard.txt`, as
bench/hash's guard does; any row more than 2% above its baseline fails,
and `--update` writes a new one. The rows search a text of 1 MiB made
from a fixed list of words in the manner of lib.dom.d.ts:

| Row | Searches |
|---|---|
| `short` | a 3-byte needle in windows of 32 bytes, some hits and some misses |
| `line` | a newline from each line's start, through 4 KiB: the walk of `text.lines` |
| `medium-miss` | a 12-byte needle that is not there, in windows of 4 KiB |
| `long-1-miss`, `long-3-miss`, `long-12-miss`, `long-40-miss` | the whole text for a needle of 1, 3, 12, or 40 bytes that is not there |
| `long-hit` | the whole text for a needle at its end |
| `count` | `text.count` of a word over the whole text |

## The timing

`bench-text BASE NEW FILE ROUNDS` builds `time.rig` with two rigs and
runs them in turns, keeping each case's fastest time. A case searches a
window of FILE, the whole of it or 8 B to 4 KiB from its middle, for a
needle of 1, 3, 12, or 40 bytes cut from it at 1/16 of the way (early),
at 15/16 (late), or that late needle with a middle byte made 0x01
(miss), whose first and last bytes still meet candidates.

## Results

Apple M5, arm64, lib.dom.d.ts (2,399,570 bytes), `rig build --release`,
fastest of 9 runs in turns, std.text at main (Zig's `std.mem.find`)
against this search; other builds held the load average between 6 and
8, so the numbers are low and the ratios hold. Nanoseconds per search:

| text | needle | case | `std.mem.find` | this | change |
|---|---:|---|---:|---:|---|
| 2.4 MB | 1 B | miss | 49,816 | 29,987 | 66.1% faster |
| 2.4 MB | 3 B | miss | 2,979,208 | 72,134 | 4030% faster |
| 2.4 MB | 12 B | miss | 710,615 | 71,200 | 898% faster |
| 2.4 MB | 40 B | miss | 303,345 | 73,484 | 313% faster |
| 2.4 MB | 12 B | late | 24,588 | 2,491 | 887% faster |
| 4 KiB | 1 B | miss | 90.3 | 77.9 | 15.9% faster |
| 4 KiB | 3 B | miss | 5,156.8 | 133.0 | 3777% faster |
| 4 KiB | 12 B | miss | 1,400.0 | 134.0 | 945% faster |
| 4 KiB | 40 B | miss | 600.5 | 123.7 | 385% faster |
| 1 KiB | 12 B | early | 100.2 | 5.0 | 1914% faster |
| 64 B | 3 B | miss | 77.9 | 4.4 | 1675% faster |
| 32 B | 12 B | early | 5.2 | 3.1 | 67.9% faster |
| 16 B | 3 B | early | 3.6 | 2.2 | 62.2% faster |
| 8 B | 3 B | early | 2.2 | 1.7 | 34.6% faster |

No case of the 72 is slower. A needle of one byte searches its first
4 KiB by Zig's own `findScalar`, inline, as `std.mem.find` did, and the
guard's `line` row runs the same 48.80 instructions per search on both;
the early hits of one byte time faster here only because that code is
now inlined into the timing loop, where searches overlap.

x86-64 (pup, Core Ultra 9 185H, E-core 13, fastest of 5 runs in turns;
its lib.dom.d.ts is 2,349,483 bytes), the same cases, nanoseconds:

| text | needle | case | `std.mem.find` | this | change |
|---|---:|---|---:|---:|---|
| 2.3 MB | 1 B | miss | 56510.7 | 52112.0 | 8.4% faster |
| 2.3 MB | 3 B | miss | 4726779.4 | 155513.9 | 2939.5% faster |
| 2.3 MB | 12 B | miss | 846732.8 | 155429.3 | 444.8% faster |
| 2.3 MB | 40 B | miss | 336961.6 | 152495.4 | 121.0% faster |
| 2.3 MB | 12 B | late | 27971.1 | 5556.8 | 403.4% faster |
| 16 B | 3 B | early | 6.3 | 4.5 | 41.1% faster |
| 16 B | 12 B | early | 8.2 | 4.8 | 72.2% faster |
| 8 B | 3 B | early | 5.0 | 3.4 | 46.2% faster |

No case of the 72 is slower there either. On x86-64 a needle of one
byte is `findScalar` over the whole text, which a step of 64 bytes did
not beat, and the searches out of line return a plain index: an
optional came back through memory, its fields written apart and read
whole, which stalled every match on a failed store forward (a 3-byte
needle in 16 bytes had been 54% slower).

The search was first written in plain Zig 0.17 and timed against
`std.mem.find` (ReleaseSafe, the same cases): a miss of 3, 12, and 40
bytes over lib.dom.d.ts took 76 to 77 µs against 2.8 ms, 664 µs, and
297 µs, about 31 GB/s, and a miss of one byte 27 µs against 47 µs, 88
GB/s; no case of 8 B to 64 B was slower once a match at place 0 was
tested by itself and the search past the first places was moved out of
line.
