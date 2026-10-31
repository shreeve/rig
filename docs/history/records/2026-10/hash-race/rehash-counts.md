# HashMap's growth by lane counts on x86-64 (2026-10-30)

**Question.** A HashMap growth moved each entry by `emplace`, which loads
the new group's control bytes to find a free lane, right after the
entry before it stored a tag byte there. On x86-64 a 16-byte load over a
pending 1-byte store cannot take its value from the store and waits for
it to commit. How much does that cost, and can growth avoid it without
costing any bench/hash row?

**Answer.** On x86-64, yes: a growth to twice the groups places each
entry at home in old group `g` at the next free lane of new group `2g`
or `2g + 1`, kept as a count, read once for `g`. Every growing insert
row on pup is 5-36% faster and none is slower. On arm64 no loop tried
avoided the wait without costing the M5's random-key inserts, so arm64
keeps `emplace`, chosen at compile time, and its machine code is main's.

## The cost (pup)

Every `ld_blocks.store_forward` sample of an insert-only run is in
`Unordered.rehash`. A model of the waits (rh.py: an entry placed in the
group the entry before it filled) matches the counted blocks a key: 0.08,
0.50 and 0.29 at 100,000 keys and 0.54, 0.26 and 0.90 at 1M for three
hash multipliers, against 0.10, 0.49, 0.30 and 0.52, 0.24, 0.80
measured (perf.txt). With one multiplier the stall made int100000
insert 12% slower.

## The change

`moveDoubled`, for x86-64 (groups of 16 bytes) when the new table has
twice the groups: for each old group `g` it counts the lanes `2g` and
`2g + 1` already hold, then places each entry homed to one of them at
that count, with no load of the group, and adds one. An entry that
overflowed in the old table, or whose new group is full, is placed by
`emplace`, and the counts follow it. Every other growth, and arm64,
place every entry by `emplace` as before. A new unit test grows tables
of dense keys and of multiples of 2^32, which crowd so entries overflow
before each growth, checking `verify` after every growth and every key
after.

## Timing

Main `344257fc0` against the change, its emit with only `unordered.zig`
different (build.sh), layout protocol: 4 layouts an arm (0, 5, 13 and 29
nops in a cold function), 7 interleaved rounds on P-core 6, fastest of
7 a layout; a row is slower when the change's fastest layout is more
than 2% over main's slowest.

**pup** (tp-x1.txt): no row slower; 26 faster, all but rnd1000 remove
(11%) inserts that grow: golden-stride Int keys 7-36% (int1000 insert 36%, int insert
26%), random Int keys 8-26% (rnd1000 insert 26%), text 5-30%, big values
6-30%, pairs 28%, triples 12%, ensure and edit_put misses 5-29%. The
largest median above main is big16 hit, 17%, a lookup row the change
does not run, with one layout within 1.2% of main's; the same x86 code
measured 1.3% slower and 4.6% faster on it in two earlier runs
(tp-pup-y1.txt, and w1 in the multiplier record).

**Trig on pup** (trig-x1.txt; trigbuild.sh, trigtime.sh): Trig `2ba0719`
PGO-built by each Rig, one checker, 20 interleaved rounds on P-core 1:
ts-pattern 0.1% slower by the median wall time (user cycles 0.05%),
zod3 0.8% slower (user cycles 0.6%), instructions and peak RSS level,
outputs identical to the reference. Each build's PGO profile is trained
on its own.

**Mac** (tp-mac-1.txt): the arm64 bench binary's machine code is main's,
instruction for instruction, addresses aside; one run, no row slower or
faster.

## What arm64 tried

With the counts on arm64 too (`f7f02ddf4`), the M5's golden-key inserts
were 10-21% faster but random-key inserts 4-6% slower in two runs
(tp-mac-y1.txt, y2). Golden keys fill one group many entries in a row,
so each load waits on the store before it in a chain; random keys
alternate between `2g` and `2g + 1`, so the waits are short and the M5
hides them, and anything a loop adds an entry shows. A byte scan for the
lane, the pair's control words in registers, and keeping the last two
groups' lanes with a spare group loaded in their place cost its
random-key inserts 20-52%, 13-16% and 8-27% (the record
`hash-int-spread.md`, on branch `hash-int-spread`).
