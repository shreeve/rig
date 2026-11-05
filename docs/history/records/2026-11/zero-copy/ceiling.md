# Zero-copy libs: the Zig ceiling, and what was built (2026-11-05)

The design's decision 2 ([design.md](design.md), §4): build option C
only if a hand-written Zig ceiling on Trig is more than 1.5% faster on
its targets and no project more than 2% slower. It cleared the bar, and
was built (#968). Scripts, the timing config, and raw runs are in
[data/ceiling/](data/ceiling/).

## How

Trig's libs-embed pack (its lib trees as `$embed` files read by
`extend_from_bytes`), Rig 27010375f, every arm a release PGO build by
one profile (dec-new's), through a `ZIG` wrapper that patches the
emitted Zig ([zcwrap](data/ceiling/zcwrap), [build-arms.sh](data/ceiling/build-arms.sh)):

- a0: as built; a0b the same binary, the A/A arm.
- a1: decision 4 and Trig's bulk reads, copied: embeds at 16 bytes,
  NodeRec in declaration order (`extern`, `Kind` as `enum(u16)`) read
  by one `extend_from_bytes`, node lists likewise.
- a2: a1 with option C, its free and grow tests in the runtime's
  `freeSlice` and `reallocSlice`.
- a3: a1 with option C, the tests out of line in alloc.zig's `freeSlow`
  and `remap`.

pup core 3 (core 4 idle), a copy of time-ab.sh watching cores 3 and 4
([config.sh](data/ceiling/config.sh)), 40 interleaved rounds of the six
projects at one checker.

## A profile artifact

a2 ran 8% more user instructions on ts-pattern than a1, and 3.5 to 9.6%
more cycles on the four larger projects ([summary-a2.txt](data/ceiling/summary-a2.txt)).
clang left 1,991 of its functions out of the profile, against 524 for
a0 and 654 for a1: every function that inlines `freeSlice` or
`reallocSlice` changed. Moved out of line, a3 left 656. The built
change keeps the tests there.

## Result: a3 against a1

Medians, user plus kernel cycles in millions, and RssAnon at peak in
MiB (`/proc/PID/status` polled, the sample of highest VmRSS, median of
5, E-core 15, [rss.py](data/ceiling/rss.py)):

| project | a1 cycles | a3 cycles | fewer | a1 anon | a3 anon |
|---|---|---|---|---|---|
| mitt | 41.6 | 34.4 | 17.3% | 16.3 | 11.0 |
| neverthrow | 54.4 | 46.5 | 14.5% | 16.7 | 11.3 |
| tiny-invariant | 242.4 | 235.5 | 2.8% | 32.6 | 27.3 |
| superstruct | 96.5 | 95.2 | 1.3% | 12.5 | 12.1 |
| zod3 | 544.6 | 528.9 | 2.9% | 51.0 | 45.6 |
| ts-pattern | 3259.3 | 3231.0 | 0.9% | 183.8 | 178.4 |

None slower; the A/A arms agreed within 1.8%. Against a0, Trig as it
was, mitt ran 20.7% fewer cycles. Peak RSS by `/usr/bin/time` showed
superstruct 2.1 MiB higher in that run, with 2 to 5 free 2 MiB blocks
on the machine; at peak by `/proc`, its anonymous and total memory are
both lower.

## Built

- #953: `$embed` at 16 bytes (`.incbin`), and its records may hold
  `Bool`s and enums, checked when the file is read.
- #963: on Mach-O an embed's symbol is local, not a weak definition,
  which marked the executable as binding weak symbols, about 9 million
  instructions a launch (mitt 89.3M against 99.1M); and #958's
  declared-order layout of every record went back out, measured as no
  cost.
- #967: `obj Name exact`, the only objects made from bytes.
- #968: option C, Linux release builds. Trig - Helper's A/B, each arm on
  its own profile: mitt 13.6% faster, neverthrow 12.4%, zod3 2.7%,
  superstruct 0.5% slower, anonymous memory lower on all six.
