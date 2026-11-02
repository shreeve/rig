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

RESULTS
