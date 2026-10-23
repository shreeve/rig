# A smaller Map for many small ones (Trig NEEDS 58), 2026-10-23

Trig asked for a Map that costs tens of bytes and one allocation when
it is empty or small, as a general capability. This round measured
where a Map's memory goes, tried the cheapest change, and records what
the rest would take. Nothing landed in std.

## Where the memory goes

A Map's header is 104 bytes: its `len` and four Lists of 24 bytes each
(`es`, the entries; `hs`, their hashes, for keys over 8 bytes; and the
table's `tags` and `at`). Every Map carries all four, whether or not it
fills them. A Map holds its entries in one block, and past `SMALL` (8)
entries builds a table in two more: a tag byte and a 4-byte entry index
per slot, sized at most two fifths full when built and grown past four
fifths.

Trig's maps, on ts-pattern with one checker (pup, Rig 06b22a585, Trig
0bac3fa), from Trig:

| Entries at the end | Maps |
|---|---|
| 0 | 3,496 |
| 1-8 | 70,747 |
| 9-16 | 4,517 |
| 17-64 | 27,023 |
| over 64 | 323 |

That is 106,106 `Map[ast.Atom, Sym]` (4-byte keys and values, so no
stored hashes) holding 1,249,822 entries, in a run of 334 MiB peak RSS.

- **Entries:** 23.1 MiB live in 116,777 blocks: the data itself, plus
  the slack of a List that grows 4, 8, 16, 32.
- **Headers:** about 10.5 MiB (106,106 x 104 bytes).
- **Tables:** those of the 27,346 maps past 16 entries, about 64 slots
  each at 5 bytes a slot: about 8.6 MiB.

## Tried: a table only past 16 entries

A Map or Set of up to 16 entries compares its keys (or stored hashes)
in turn, and the first table, built past 16, is the size a Map that
built one past 8 would hold by then. The change is
[small16.patch](small16.patch). The harness is [gen.py](gen.py) and
[run.sh](run.sh): 100,000 maps of `k` entries, built and then each key
looked up 10 times, fastest of 7, interleaved.

On pup (core 6), main against the patch:

| Keys, entries | Build | Lookups | RSS |
|---|---|---|---|
| Int, 12 | 39% faster | 41% faster | 23% less |
| Int, 16 | 35% faster | 11% faster | 23% less |
| Int, 24 | 6.5% slower | same | same |
| Int, 32 | 3.9% slower | same | same |
| String, 12 | 20% faster | 6.3% slower | 12% less |
| String, 16 | 20% faster | 8.6% slower | 11% less |
| either, 4 or 64 | within 2% | within 2% | same |

The Mac agreed on the gains (its load was too high for the losses to be
read). Trig, built with the patch, fastest of 10 on pup, output
identical:

| Project | Time | Instructions | Peak RSS |
|---|---|---|---|
| ts-pattern | 1198 → 1195 ms | 13.49G → 13.51G | 334 → 335 MB |
| zod3 | 239 → 240 ms | 2.76G → 2.77G | 86 → 88 MB |
| tiny-invariant | 105 → 106 ms | 1.41G → 1.39G | 52 → 54 MB |

**Not landed.** Scanning up to 16 stored hashes is slower than a probe
on x86 for String keys, and a Map that grows past 16 builds more slowly
on its way there. Trig, whose maps are mostly 1-8 or past 16, gains
nothing measurable. It does not pay for its lines.

## What the rest would take

Each piece is in std alone (`std/__rig_builtin.rig`) and changes no
language rule. Estimated against Trig's numbers above:

- **The table behind a box:** a Map of `len`, `es`, `hs`, and a
  `^Table?` (an optional box takes 8 bytes), so a Map with no table
  pays no table header: 104 → 64 bytes, about 4 MiB for Trig (1.2%).
  Every lookup in a Map with a table then follows one more pointer;
  bench/hash's million-key rows judge that.
- **Narrow slot indexes:** a table of fewer than 65,536 slots indexes
  its entries in 2 bytes, not 4: about 3.3 MiB for Trig's 27,000
  mid-size maps (1%). This needs a table whose index width follows its
  size, two code paths in `find`, `place`, and `unlink`.
- **`hs` only where it is used:** a Map with keys of 8 bytes or fewer
  keeps a `hs` List it never fills, 24 bytes. Rig has no field whose
  presence a type parameter decides, so this rides with the box above,
  or waits for such a form.
- **Entry slack:** the List's growth, not the Map's; a Map built once
  could trim it, as a `shrink` would.

Together they come to about 7-10 MiB of Trig's 334 (2-3%), each adding
code a later change carries. Trig tried moving its read-only member
tables into an arena as spans, which took most of these maps off the
heap (ts-pattern 334 → 321 MB, 1% faster), but two smaller projects ran
1-2% slower, and the owner dropped it (shreeve/trig#188): the maps
above stand.

## Recommendation

Build the boxed table first, as one change: the header from 104 to 64
bytes, measured on bench/hash's million-key rows (the extra pointer a
lookup with a table follows) and on Trig's projects for time and peak
RSS. If it pays, the narrow slot indexes follow, on their own.
