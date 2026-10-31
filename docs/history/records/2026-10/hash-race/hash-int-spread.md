# HashMap's integer multiplier, searched again (2026-10-30)

**Question.** HashMap hashes an integer key by one multiply, and main's
multiplier `0x4b33a62ed433d4a3` crowds dense and strided keys (4,096
keys 0 to 4,095 walk 5 to 7 groups past home). The first candidate,
`0x6f95cb49323931f1`, spreads every such case but lost two bench/hash
rows on pup: int100000 insert by 12% and rnd1000 miss by 6.6%. The
owner's rule for a Map or Set change: every bench/hash row within 2% of
main or better, on both machines. Is there a multiplier that spreads the dense keys and loses no
row?

**Answer.** `0xa46445d6b41313ff` (a464), with two Mac rows slower that
the owner accepted: int iterate at 1M keys by 7.0-7.5% and int1000
remove by 9.0-9.7%. No odd multiplier found loses no row: every one
measured is slower than main on the Mac's int iterate, where main's
spread is the easiest for the M5 to predict, and a walk built to ignore
the spread was slower still (the last sections). The rounds that led
there follow in order.

## Why each losing row lost

**int100000 insert (x86): the rehash's store-to-load stalls.** Every
`ld_blocks.store_forward` sample of the insert-only probe is in
`Unordered.rehash`, which places each entry by loading its new group's 16
control bytes right after the placement before it stored a tag byte
there. A 16-byte load that overlaps a pending 1-byte store cannot be
forwarded and waits for the store to commit. Old group `g`'s entries go
to new groups `2g` and `2g+1` by one more hash bit, so the hazard is the
chance that consecutive entries of a group share that bit. A model of it
(`hash-int-spread-data/rh.py`, K1: an entry placed in the group the
entry before it filled) predicts the measured blocks per insert:

| | main | 6f95 | f560 |
|---|---|---|---|
| 100,000 keys: model | 0.078 | 0.504 | 0.287 |
| 100,000 keys: measured | 0.10 | 0.49 | 0.30 |
| 1M keys: model | 0.535 | 0.257 | 0.903 |
| 1M keys: measured | 0.52 | 0.24 | 0.80 |

Main's 0.078 at 100,000 keys is luck: its golden-stride keys alternate
that bit. 6f95 stalls on half its entries and spends 20M more cycles over
4M inserts (perf.txt).

**rnd1000 miss: a lottery on one key set.** The row's 1,000 random keys
(`scatter(0..999)`) and misses (`scatter(8M + i)`) are fixed. Main's tags
give that set 0.019 false tag matches a miss, its best: over 20 other key
sets (`probe.rig`'s `rndmiss` mode) main averages 0.030 and 6f95 0.031.
Timed on pup over those 20 sets (rndmiss-pup.txt), the bench's set is
main's fastest of all, 7.2% ahead of 6f95; on the others 6f95 is from
5.7% faster to 4.8% slower, 0.6% slower on average. The row was not
changed.

**f560's int miss (35% slower in the bench, 14% in the probe) is a
different feature.** At 1M keys f560's tags and probes are main's (no
false matches, one group a miss), so it is the order the misses walk the
2 MB of control bytes. Its insert-side feature is separate: K1 at 1M
0.903 against main's 0.535, the int insert row 4% slower.

## The search

`hash-int-spread-data/sim.c` models the table exactly (groups, the
sentinel lane, overflow bits, quadratic probe, growth, the walk order)
and scores each multiplier against main on features each validated
against pup:
- spread: the dense-key unit test's 17 strides × 15 sizes, both widths;
- rehash K1 at each int row's size (the inserts);
- insert-path collisions at 16 keys (int16 insert and remove, #758);
- false tag matches, groups probed, and displaced keys on each random
  row's fixed key set, misses and hits (random rows: 34a4's rnd24 hit
  41% slower from one key displaced past the sentinel lane, a case the
  first model missed);
- false tag matches on the golden-stride int rows (69a7: int1000 miss
  75% slower at 1.51 matches a miss);
- walk predictability, an occupancy predictor of the last 2 groups at
  100,000 keys and 12 at 1,000 (correlation 0.79 with int100000 iterate
  over 17 multipliers).

Structure (golden-stride features) comes from `G × mul`, the lottery
(random rows, other strides) from `mul`, so the search fixed the high
bits of `G × mul` from 23 structural bases and varied its low 22 bits:
4 of 96M variants pass every feature (v2-all.txt).

## Timing (layout protocol, 4 layouts an arm, fastest of N)

**pup** (tp-pup-r1.txt, 7 rounds): a1b9, b54f and fb59 no row slower;
bc61 int4000000 miss 2.4× slower. Every finalist is 16-20% faster on
int100000 hit and miss. A second run (r2) under other sessions' load
flagged rows that no multiplier touches (triple miss), so it is not
used.

**Mac** (tp-mac-m1.txt to m3, M5, loaded): every finalist loses a row
in two runs: fb59 int1000 insert 15% and int insert 8-14%; bc61
int100000 insert 12-13%; a1b9 int4000000 miss 36-42%; b54f int4000000
miss 49% (one run). An A/A copy of main moved 4-16% on single rows in
m2, so a row counts only when it is slower in two runs.

## What it would take

The insert rows on both machines turn on the same hazard. A rehash
that finds the free lane by byte loads (rehash-bytescan.diff) removes
it, and the multiplier nearly stops mattering to them: golden-key and
pair inserts 7-34% faster on pup (r3) and 11-29% on the Mac (m3) for
every multiplier, fb59 within 3% of main's multiplier on each such row
and 7-9% ahead at 1,000 and 100,000 keys. But its per-lane loop makes
random-key inserts 8-16% slower on pup and 20-52% on the Mac, and text
and big-value inserts 13-41% slower on the Mac. Tracking the last two
groups (rehash-tracked.diff, its divisions by the group width and its
branches on every entry) was worse: on pup golden-key inserts 10-16%
faster and random-key inserts 10-24% slower (r4), on the Mac every
insert row 10-90% slower (m4).

So: a rehash that keeps the vector load but never loads a group it just
stored into, as its own change: walking old group `g`, keep the next free
lane of `2g` and `2g+1` in two registers, read once per old group, and
send only overflowed entries the general way. Measured on both machines,
it should keep most of the golden-key gain without the random-key loss,
and leave the multiplier to be chosen on the lottery and walk features
alone, where fb59 already loses nothing on pup.

## The register design, built and timed (2026-10-30)

Built as the owner asked (`f7f02ddf4` on branch `rehash-lanes`, local,
rehash-lanes.diff): a growth to twice the groups reads, for each old
group `g`, how many lanes new groups `2g` and `2g + 1` already hold,
places each entry homed to them at the next lane with no load of its
group, and sends an entry that overflowed, or whose group is full, to
`emplace`, the counts following it. A new unit test grows tables of
dense keys and of multiples of 2^32 (both crowd, so entries overflow
before each growth) and checks `verify` after every growth and every key
after; the Mac's unit tests pass. Bench checksums match main's on both
machines. Timed against main `a8acfdc5c`, layout protocol, main's emit
with only `unordered.zig` changed (buildY.sh):

- **pup** (tp-pup-y1.txt, 7 rounds): no row slower. Every insert row
  that grows is faster: golden keys 9-36% (int1000 insert 36%), random
  keys 9-23% (rnd1000 23%), text 5-24%, big values 6-28%, pairs 24%,
  triples 11%, ensure and edit_put misses 20-27%.
- **Mac** (tp-mac-y1.txt, y2, two runs, load 3): golden keys 10-21%
  faster (int1000 and int100000 insert 20-21%, int insert 10-11%), text,
  big and pair rows level or faster, but **random-key inserts 4-6%
  slower in both runs**: rnd1000, rnd1500, rnd100000, rnd150000 and
  rnd4000000 insert.

The arm64 loop is branch-free on its fast path (rehash-aa-arm.s: `csel`,
`cinc`, `ccmp`), so the loss is not a mispredicted select. Two costs the
old loop did not have remain: a load and count of the two new groups for
every old group, about 5.6 entries apart at growth, and a branch to
`emplace` that random keys take unpredictably, 9.3% of entries on arm64
groups of 7 (old-overflowed entries and full new groups; 6.5% on x86,
none for golden keys; slow.py). On pup the stall the old loop paid was
large enough to cover both; on the Mac, where random keys gain least
from avoiding it, they are not covered.

The multiplier on top of it, fb59 (tp-pup-y1.txt, y1, y2): on pup
int1000 hit 5.6% slower (4.0% and 5.2% in r1 and r2), on the Mac
int100000 miss 6-9% slower in both runs, so fb59 is out as well.

**Next design, not built:** keep the pair's control words in registers.
For old group `g`, compute each entry's new home and tag, set its tag
into the even or odd word at its count's lane (a shift and an or, no
memory), place its element, and store each word once when `g` is done.
That removes the per-entry tag store and the reads of the pair (the
words start from the pair's current bytes only when an earlier entry
overflowed into them, which a bit kept for the pair shows), and leaves
overflowed and full-group entries to a second pass over the old group
after its two stores, so the hot loop has no branch to `emplace` at all.

## The register-word design, built and timed (2026-10-30)

`75352a3a6` on `rehash-lanes` (rehash-words.diff): for each old group
the pair's two control words are read once, each entry's tag is set into
its word by a shift and an or, the words are stored once, and an entry
that overflowed or whose group is full writes its element aside and is
placed by `emplace` after the stores. Unit tests pass on both machines,
bench checksums match main's. Timed against main and `f7f02ddf4` (the
lane counts), the same protocol (tp-pup-w1.txt, tp-mac-w1.txt, w2):

| insert row | pup counts | pup words | Mac counts (2 runs) | Mac words (2 runs) |
|---|---|---|---|---|
| int1000 | 0.651 | 0.985 | 0.795, 0.798 | 1.000, 1.002 |
| int100000 | 0.807 | **1.142** | 0.798, 0.802 | 1.021, 1.012 |
| int (1M) | 0.767 | 0.961 | 0.882, 0.883 | **1.139, 1.115** |
| rnd1000 | 0.765 | 1.032 | **1.051, 1.045** | **1.132, 1.127** |
| rnd100000 | 0.820 | 1.027 | **1.059, 1.058** | **1.162, 1.159** |
| rnd150000 | 0.785 | 1.019 | **1.046, 1.046** | **1.137, 1.135** |

The words lose what the counts won and more, on both machines. The
compiler keeps the pair's two words in one vector register and builds
each tag's place in it with moves from the integer registers, a
shift and a blend (rehash-ww-arm.s: `dup`, `ushll`, `shl`, `cmlt`, two
`mov.d`, `bsl`, `orr` an entry, against the counts' `csel`, `cinc` and one
`strb`), and the element is stored through a selected address, the
entry's slot or the aside slot. That costs more an entry than the stall
it removes. (In w1, pup flagged int100000 hit and rnd24 miss for the
counts, rows a rehash does not run and whose tables are the same; y1,
quieter, flagged nothing.)

**Why the Mac's random inserts resist.** Three rehashes that never load
a group just written cost the Mac's random-key inserts 20-52% (byte
scan), 4-6% (counts) and 13-16% (words), while golden keys gain 11-29%
(byte scan) and 20% (counts). Golden keys fill one group many entries in
a row, so each load waits on the store before it, a chain; random keys
alternate between `2g` and `2g + 1` at random, so a wait rarely meets
the next and the Mac's out-of-order core hides it. On the Mac the old
loop's stall is therefore cheap for random keys, and any rehash must add
almost nothing an entry to break even there. On pup the stall is dear
for both, which is why the counts win every row there.

**Can a rehash fix the stall without costing the Mac's random inserts?**
Two ways remain, neither built:
1. **Counts on x86 only.** `f7f02ddf4`'s loop where groups are 16 bytes,
   the old loop on arm64 (a comptime switch on `group8`): on pup it lost
   no row in y1 and won 9-36% on every growing insert row, and on the
   Mac the code is main's. The Mac keeps its golden-key stall.
2. **The address, not the lane.** Keep the old loop, plus the last
   placement's group and lane in registers: when an entry's group is
   that group, load the group from a spare word instead, so the load
   overlaps no store, and take the lane after the last one by a select.
   About three instructions an entry and no read per old group; whether
   that is little enough for the Mac's random keys has to be measured.

## The x86-only counts (PR #786) and address-select (2026-10-30)

**#786** (`b6bfb0697`, from main `344257fc0`): `f7f02ddf4`'s counts where
groups are 16 bytes, the old placement on arm64, chosen at compile time
(`!group8`). Its arm64 machine code is main's, instruction for
instruction (the whole bench binary, addresses aside), and a Mac run
found no row slower or faster (tp-mac-1.txt). Its pup bench/hash and
Trig timings wait on its slot in the pup lane.

**Address-select** (`860e00631`, local, rehash-addr.diff), one loop for
both machines: the last two placements' groups and lanes kept; an entry
homed to one of them takes the lane after it and loads a spare group,
any other loads its own; only a full group goes to `emplace`. Mac, two
runs (tp-mac-as1.txt, as2): golden keys 3.5-10% faster, but random-key
inserts 8-27% slower (rnd1000 to rnd150000 22-27%), text, big-value,
pair and triple inserts 4-15% slower. The compiler turned the choice
between the kept lane and the loaded one into a branch on whether the
entry's group is kept (rehash-addr-arm.s: `tbz w22`), which random keys
take half the time at random. Not timed on pup: it already loses the
Mac's rows, so it cannot be the one loop.

Every loop that avoids the load has now cost the Mac's random-key
inserts: byte scan 20-52%, counts 4-6%, words 13-16%, address-select
22-27%. The counts, branch-free and the cheapest, still lost; the old
loop's waits are short for random keys on the M5, and nothing tried adds
less than they cost. So the x86-only counts are the rehash change.

## Round 3, on main af6e0e6bf (2026-10-30)

With #786 (lane counts on x86) and #791 (ensure checks home first) on
main, the x86 rehash stall no longer depends on the multiplier, so the
search (round3/sim.c) drops the x86 rehash features and adds: no
golden-stride key displaced from its group at 16, 1,000 and 100,000 keys
on either width (fb59's int1000 hit). 80 structural bases, 2M low-bit
variants each, give 9 multipliers that match or beat main on every
modeled feature (round3/vall.txt). An extra filter for arm64's growth
(its waits, the last two placements' groups, no more than main's) left
none, and it had not predicted bc61's Mac rows, so it was dropped.

**Mac screen** (round3/screen-mac.txt, the probe, one layout, 5 rounds):
every finalist is 6-16% faster on insert-only at 1,000 keys, but every
one is slower than main on int iterate at 1M keys (5-22%), and
int1000 miss and rnd16 miss (3-9%, a one-layout reading). Three
shortlisted for the layout protocol: 83ae (`0x83aee5b3a6acd5bc`), 6b72
(`0x6b7268d855d0d2de`), b186 (`0xb186d05e15ee47ea`).

**Mac, layout protocol, two runs** (round3/tp-mac-f1.txt, f2): each
loses a row in both runs.

| row | 83ae | 6b72 | b186 |
|---|---|---|---|
| int iterate (1M golden keys) | **1.069, 1.063** | **1.062, 1.054** | 1.035, 1.019 |
| int4000000 iterate | 0.981, 0.998 | **1.102, 1.106** | 1.083, 1.059 |
| int4000000 miss | 0.980, 1.042 | 1.023, 1.066 | **1.167, 1.189** |
| rnd1000 miss | 1.027, 1.045 | 1.013, 1.067 | **1.079, 1.096** |
| rnd1500 hit | 0.957, 0.948 | **1.103, 1.065** | 0.943, 0.917 |

pup was not timed: the Mac already rules each out.

**Why.** The Mac's int iterate row walks a 1M-key table of 262,144 groups
of 7, about 3.8 entries a group, so a branch ends every group's loop and
its cost is how well the M5 predicts the occupancies. All 14
multipliers measured on it across rounds 2 and 3 are slower than main,
by 2-22%. No occupancy predictor of 1 to 12 groups' context tracks it
(correlation 0.46 at best, round3/wk1m.txt), so the search cannot aim
at it. Main sits at a lucky end of that row as it does on rnd1000 miss,
and the other losses (int4000000 miss and iterate, rnd1500 hit) differ
by multiplier without a modeled cause.

**knucleotide-fast** (round3/knucleotide.txt): every new multiplier
makes the port's `mix` unneeded. Without it main takes 1.551 s and the
four multipliers 0.529-0.545 s, faster than main with `mix`, 0.576 s.

**Even candidates.** The low-bit variation built each candidate as
`ginv × (base × G ^ c)`, and an odd `c` flips bit 0, so half its
candidates were even, which no multiplier may be: an even multiplier
drops the key's top bits (under a multiple of 4, 1 and 1 + 2^62 hash
alike). Even, and so out whatever their timing: round 2's a1b9
(`0xa1b9b543bccba13c`), and round 3's 6b72, 7a86, 83ae, 8472, af52 and
b186. Odd: round 2's b54f, bc61 and fb59, round 3's dc4d, deb5 and f06a.
A unit test now asks that `int_mul` be odd, and the search varies only
bits 1 to 21.

**Odd only.** The same 80 bases varied in bits 1 to 21 give 9 odd
multipliers that match or beat main on every modeled feature
(round3/vall-odd.txt), dc4d, deb5 and f06a among them. The Mac screen
(round3/screen-odd.txt) kept a464 (`0xa46445d6b41313ff`), 1f41
(`0x1f41e7925f8cf96d`) and d183 (`0xd183db478d104653`); the others lost
int insert by 12-23% or insert-only at 4M by 18-29%. Two runs of the
layout protocol, the arms' order rotated each round (round3/tp-mac-o1.txt,
o2):

| row | a464 | 1f41 | d183 |
|---|---|---|---|
| int iterate | **1.070**, 1.075 | **1.102**, 1.082 | **1.160, 1.194** |
| int1000 remove | 1.090, **1.097** | **1.159**, 1.038 | 0.993, 0.979 |
| int4000000 insert | 1.044, 1.039 | 0.985, 0.981 | **1.116, 1.137** |
| rnd1500 hit | 0.929, 0.950 | **1.045**, 1.066 | 0.961, 0.999 |

None loses only int iterate by 7% or less: a464, the nearest, loses int
iterate by 7.0-7.5% and int1000 remove by 9.0-9.7%.

## Iteration that ignores the spread: a ceiling (2026-10-31)

The Mac's int iterate row is where main's multiplier is luckiest, so the
owner asked first for a walk whose cost does not depend on how a
multiplier spreads entries. The walk (`next_slot`) leaves its loop at
the end of every group, about 3.8 entries apart at 1M keys on arm64,
and that exit is the branch the M5 predicts better for main's
occupancies than for any other multiplier's.

**Ceiling tried** (iterate/walk-window.diff): the full lanes of 8 groups
(4 on x86) packed into one word, a bit a lane, so slot `at * NL + ctz`
and one exit a window of about 30 entries in place of one a group.
Unit tests pass. Mac, the probe, 7 rounds, main's `unordered.zig` (M)
against it (W), under main's multiplier and six odd candidates, time
over main's walk under main's multiplier (iterate/ceiling-mac.txt):

| | 4b33 | a464 | 1f41 | d183 | dc4d | deb5 | f06a |
|---|---|---|---|---|---|---|---|
| int iterate, M | 1.000 | 1.112 | 1.105 | 1.201 | 1.119 | 1.068 | 1.193 |
| int iterate, W | 1.595 | 1.723 | 1.603 | 1.671 | 1.620 | 1.583 | 1.708 |
| walk 1M, M | 1.000 | 1.067 | 1.030 | 1.114 | 1.052 | 1.015 | 1.126 |
| walk 1M, W | 1.503 | 1.580 | 1.542 | 1.586 | 1.432 | 1.524 | 1.589 |

The window is 43-72% slower under every multiplier: main's walk costs
about 2.5 cycles an entry, and packing 8 groups' lanes (a load, a
compare, a multiply and a shift each) costs more than the exits it
saves. Nor does it level the multipliers: under the window they still
spread over 1.43-1.72, so the cost that differs is not only the group's
exit but how predictable any data-dependent exit is under each
spread. A walk that takes no branch on where entries are would have to
run its body for every slot, which a `for` over a HashMap cannot.

## Chosen (2026-10-31)

The owner accepted a464: first "I think we should accept it because it
has this one slowdown, but in other areas MASSIVE improvements" (for the
int iterate exception), then "Approve the defaults" (widening it to a464's
two Mac rows, int iterate up to 7.5% and int1000 remove up to 9.7%).
knucleotide-fast without its `mix` (round3/knucleotide-a464.txt, fastest
of 5 interleaved on the Mac): main 1.553 s, a464 0.517 s; with `mix`, main 0.547 s and a464
0.533 s.

**pup** (round3/tp-pup-a464.txt; main `36be46744`'s emit, 7 rounds, arm
order rotated): three rows slower by the protocol, in all four layouts:
int4000000 hit 7.3%, rnd150000 hit 8.6%, rnd1000 miss 5.0%; int100000 hit
and miss 15-21% faster. The owner's exception covers the Mac only.
