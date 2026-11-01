# Short text compares and appends, measured before building (2026-11-01)

**Question** (queue rows 38 and 39; Trig's NEEDS 65 and 66, from
trig#231's parser): would Trig clear its bar (more than 1.5% faster, or
at least 1% fewer instructions, peak RSS no higher) if

- **38:** `==` against a string literal compared the lengths inline, and
  a literal of at most 16 bytes its bytes inline, where today
  `rig.eql` reaches `std.mem.eql`, whose `eqlBytes` is out of line and
  tests the lengths inside the call (`make_identifier`'s
  `text == "await"`, on every identifier);
- **39:** `String.add` of at most 16 bytes moved them by inline loads
  and stores, where today `appendBytes` calls `memmove` for any length
  (each identifier's text copied into its tree's arena)?

Measured first, as a hand ceiling in the runtime; nothing built. The
patches, scripts and raw output are in [short-text-data/](short-text-data/).

**Answer: no.** Row 38 saves 0.6% of Trig's instructions on the empty
project and on mitt, and its time is level. Row 39 saves nothing: its
instructions are level or higher everywhere. Neither stacks to the bar,
with each other or with row 35's inline `slice`.

## The ceilings

- [eq-literal.patch](short-text-data/eq-literal.patch): in `eql`, a
  string beside a literal (a pointer to a sentinel-terminated byte array,
  whose length the type holds) goes to `eqlLit`: the lengths, then up to
  16 bytes as two loads per side that may overlap (`u64`, `u32` or `u16`)
  XORed together, longer literals to `std.mem.eql`.
- [short-add.patch](short-text-data/short-add.patch): in `appendBytes`,
  up to 16 bytes go through `moveShort`, two loads that may overlap
  (8 or 4 bytes) or three single bytes, all done before any store.

Both gave the right results for every length from 0 to 17 under
`RIG_SANITIZE=1` and in a release build.

## Measured

Trig parser-tsrs `af8d3a6` (trig#231), built `--release` with Rig
`a15297f4e` and with each ceiling; pup core 3 with its sibling idle,
`--singleThreaded`.

Five arms, 20 rotated rounds ([timeceil.sh](short-text-data/timeceil.sh),
[times-1.txt](short-text-data/times-1.txt)). Fastest task-clock, in ms:

| | base | 38 | 39 | 38+39 | 38+39+35 |
|---|---|---|---|---|---|
| empty | 17.31 | 17.04 | 17.22 | 17.40 | 17.56 |
| mitt | 20.06 | 19.50 | 19.67 | 19.79 | 19.78 |
| zod3 | 156.59 | 157.16 | 156.62 | 156.02 | 156.83 |

Row 38 on mitt read 2.8% faster, with 1.9% fewer instructions at the
median, while empty showed 0.4% more and zod3 none. A confirming run of
base against 38 alone, 30 alternating rounds
([confirm.sh](short-text-data/confirm.sh),
[times-2.txt](short-text-data/times-2.txt)), was level: empty 17.13 to
16.77 ms fastest and 17.93 to 17.89 median; mitt 19.23 to 19.13 fastest
and 19.79 to 19.93 median; median cycles 0.2% and 0.5% more.

**The P-core's instruction counts spread.** On core 3,
`cpu_core/instructions/u` of the same binary on the same project ranged
over about 9M in 30 runs (empty 177.8M to 186.7M, 5%), so a difference of
medians under that is not a finding, and the first run's 1.9% on mitt was
that spread. On an E-core, `cpu_atom/instructions/u` repeated to within
a few thousand ([instr-ecore.txt](short-text-data/instr-ecore.txt)):
row 38 saves 1.05M of 174.35M on empty (0.60%) and 1.14M of 191.11M on
mitt (0.60%). Count instructions for a ceiling on an E-core, and time it
on a P-core.

## Why so little

The literal compare runs once per identifier, and Zig's out-of-line
`eqlBytes` costs a call and a length test there; the instructions it
saves are real but a small part of parsing. The short copy replaces a
`memmove` call that is already short for a few bytes, and the inline
form's branches on the length take back what the call cost. Trig's NEEDS 66 ceiling skipped the copy
entirely (1.9% fewer instructions parsing the libs), which an inline
copy cannot approach; only not copying, a tree sharing its file's text
as tsrs does, would.
