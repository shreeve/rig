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

On a shared timing machine (pup), build the two programs before the
quiet window and time only within it: `bench-text` builds both with
`rig build --release` first, and pinned to the one core being timed
those builds take most of a 15-minute window. A change to std alone
needs one rig for both, with `RIG_STD` set to each side's `std/`.

## Against memchr and Go

`bench-text --rivals RIG FILE ROUNDS` times std.text, built with
`--release`, against the memchr crate
(`rust/`: memchr 2.8.3, pinned by `Cargo.lock` and built offline from
the cargo cache) and Go's `bytes.Index` (`find.go`), on the same cases,
each program in turn, each case's fastest time kept. memchr runs twice:
`memmem::find`, which takes its needle at each call as `text.find` does,
and a `memmem::Finder` built once per case, outside the timed loop, its
best when one needle is searched for many times. Every program prints
where it found each needle, and the run stops if two disagree.

```sh
tools/low bench/text/bench-text --rivals bin/rig lib.dom.d.ts 20
```

The std.text column was measured in Zig's fast mode, which Rig no
longer builds; the rows wait to be measured again with `--release`.
Apple M5, lib.dom.d.ts (2,349,483 bytes), 20 rounds; nanoseconds per
search:

| text | needle | case | std.text | memchr | memchr Finder | Go |
|---|---:|---|---:|---:|---:|---:|
| 2.3 MB | 3 B | miss | 37,268 | 44,788 | 44,941 | 79,893 |
| 2.3 MB | 12 B | miss | 37,315 | 45,961 | 45,849 | 564,200 |
| 2.3 MB | 40 B | miss | 36,812 | 43,389 | 43,180 | 260,265 |
| 2.3 MB | 12 B | early | 2,599 | 3,379 | 3,435 | 37,532 |
| 2.3 MB | 1 B | miss | 19,864 | 19,764 | 19,547 | 21,930 |
| 4 KiB | 12 B | miss | 120.1 | 106.1 | 89.4 | 1,132.0 |
| 4 KiB | 40 B | miss | 121.9 | 294.9 | 86.6 | 4,794.5 |
| 4 KiB | 1 B | miss | 67.0 | 34.2 | 34.1 | 41.6 |
| 1 KiB | 3 B | miss | 21.8 | 25.3 | 21.0 | 363.0 |
| 64 B | 40 B | late | 2.9 | 233.1 | 14.8 | 21.4 |
| 64 B | 12 B | miss | 2.8 | 17.1 | 2.7 | 23.6 |
| 16 B | 3 B | miss | 1.4 | 6.0 | 5.7 | 5.9 |
| 16 B | 1 B | miss | 2.8 | 7.4 | 1.3 | 1.9 |

Over the whole text std.text is 17-30% faster than memchr for needles
of 3 to 40 bytes, and 1.3 to 17 times faster than Go; in texts of
8 to 64 bytes, for those needles, it leads or is within 6% of the Finder. It trails where
the Finder's work on the needle, done once, pays for itself (12 and 40
bytes in 1 to 4 KiB), and for one byte in 16 B to 4 KiB, where Zig's
`findScalar` searches and memchr is about twice as fast. Built with
`--release`, std.text was as fast as in Zig's fast mode: its search
functions leave out the checks their own tests prove
(`rig.proven_checks`), which cost it 12-44% in Zig's safe mode.

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
inlined into the timing loop, where searches overlap.

x86-64 (pup, Core Ultra 9 185H, P-core 6 with its sibling idle, fastest
of 9 runs in turns; its lib.dom.d.ts is 2,349,483 bytes), the same
cases, nanoseconds:

| text | needle | case | `std.mem.find` | this | change |
|---|---:|---|---:|---:|---|
| 2.3 MB | 1 B | miss | 39662.2 | 35534.8 | 11.6% faster |
| 2.3 MB | 3 B | miss | 2774208.9 | 100950.0 | 2648.1% faster |
| 2.3 MB | 12 B | miss | 731949.4 | 101518.5 | 621.0% faster |
| 2.3 MB | 40 B | miss | 349438.9 | 101977.1 | 242.7% faster |
| 2.3 MB | 12 B | late | 24131.0 | 3571.5 | 575.7% faster |
| 16 B | 3 B | early | 4.2 | 2.3 | 84.2% faster |
| 16 B | 12 B | early | 5.1 | 2.5 | 101.2% faster |
| 8 B | 3 B | early | 2.9 | 1.8 | 63.1% faster |

No case of the 72 is slower there either. On x86-64 a needle of one
byte is `findScalar` over the whole text, which a step of 64 bytes did
not beat, and the searches out of line return a plain index: an
optional came back through memory, its fields written apart and read
whole, which stalls every match on a failed store forward (a 3-byte
needle in 16 bytes is 54% slower that way).

The search is plain Zig 0.17, timed against `std.mem.find`
(ReleaseSafe, the same cases): a miss of 3, 12, and 40
bytes over lib.dom.d.ts took 76 to 77 µs against 2.8 ms, 664 µs, and
297 µs, about 31 GB/s, and a miss of one byte 27 µs against 47 µs, 88
GB/s; no case of 8 B to 64 B is slower, because a match at place 0 is
tested by itself and the search past the first places is out of line.
