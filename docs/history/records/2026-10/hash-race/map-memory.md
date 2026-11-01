# Map memory against hashbrown (2026-11-01)

Queue row 42, measured only. Helper's census put Map storage at about 90
MiB of Trig's ts-pattern heap: is that Map's overhead or Trig's data?
The programs are [mapmem.rig](map-memory-data/mapmem.rig) and
[rust/src/main.rs](map-memory-data/rust/src/main.rs); their raw output is
[rig-dbg.txt](map-memory-data/rig-dbg.txt),
[rig-rel.txt](map-memory-data/rig-rel.txt) and
[rust.txt](map-memory-data/rust.txt), and the tables are in
[summary.txt](map-memory-data/summary.txt).

- **Setup:** pup, x86-64, run on an E-core. Rig main `143316ffb`;
  hashbrown 0.17.1 and indexmap 2.14.2 with foldhash, built `--release`.
- **What is counted:** bytes per entry for n entries put into a fresh
  table, including the table object itself (Rig's Map 64 B and HashMap
  48 B; hashbrown 40 B and indexmap 64 B).
- **Rig:** `os.memory().live`. A debug build counts the bytes asked
  for, as Rust's counting global allocator does; a release build counts
  the allocator's size classes, and those are the figures labelled
  "rel".
- **Shapes:** U32→U32, Int→Int, Int→64-byte object, and String→Int (the
  key's text included); every n from 0 to 64, then sizes just below and
  just past each growth, up to 1,048,577.

## Findings

1. **Map on Trig's own tables is within 11% of hashbrown and half of
   indexmap.** Trig's 118,931 `Map[U32, U32]` symbol tables, at the
   lengths [small-maps.md](small-maps.md)'s trace found, total:
   - Map 28.3 MiB
   - hashbrown 25.6 MiB
   - indexmap 57.8 MiB (the like-for-like ordered design)
   - Rig's HashMap 43.7 MiB

   So matching hashbrown byte for byte would save at most about 2.7 MiB
   on these tables.
2. **Up to 16 entries, Map is the smallest of the four.** It has no
   index then: U32→U32 at 16 entries is 12 B an entry, against 21.5 for
   hashbrown and 51 for indexmap. At 1 or 2 entries the object dominates,
   and Map's 64 B against hashbrown's 40 is the whole gap (96 against 92
   B at 1 entry).
3. **At 17 entries Map pays for its first index.** It builds 4 groups
   (320 B) and makes room for 32 entries: 37.6 B an entry, against 20.2
   for hashbrown. Trig's tables grow on to 32 and 41 entries, the peaks,
   where Map is 20.0 and 18.7 B an entry against 19.8 and 15.4. A
   smaller first index would help only tables that stop between 17 and
   26 entries, about 1,000 of Trig's.
4. **Large tables:** from 1,000 entries, per entry, ranging between
   just after and just before a growth:

   | Shape | Map | hashbrown | indexmap |
   |---|---|---|---|
   | U32→U32 | 17.0 to 26.0 B | 10.3 to 18.9 | 26.3 to 48.2 |
   | Int→Int | 26 to 42 B | 19 to 36 | 34 to 63 |

   Map's index costs 80 B a group of 15 lanes: 5.3 B a lane against
   hashbrown's 1 control byte. That is the price of keeping order with
   32-bit slots. Map is still 1.4 to 1.9 times smaller than indexmap.
5. **Text keys:** a Map entry also keeps the key's hash (8 B), so
   String→Int is 64.5 to 115 B an entry against hashbrown's 46 to 81.
   That is the only shape where Map loses to indexmap (59 to 104), by 9
   to 10%.
6. **Rig's HashMap is the outlier at small sizes.** Its first table
   holds 30 slots: one U32→U32 entry takes 328 B (hashbrown 92), and one
   Int→64-byte entry 2,208 B (hashbrown 348). From about 16 entries on
   it matches hashbrown. This doesn't touch Trig, whose tables are Maps,
   but any program with many small HashMaps pays it.
7. **Release size classes** add nothing to Map's rows of plain keys,
   and 5 to 15% to HashMap's small tables.

## What could be built (owner's rule: no Map row slower)

- **HashMap's first table at 1 group, or at 4 slots for small entries,
  as hashbrown does.** It is the largest ratio found (3.6 to 6.3 times
  at 1 to 4 entries). It needs bench/hash's small rows timed, since the
  first growths would move.
- **For Trig, nothing is large.** The whole gap to hashbrown on the
  symbol tables is about 2.7 MiB. Map's object is 24 B larger than
  hashbrown's (64 B against 40, the small tags inside it), and 24 B
  times 118,931 tables is 2.7 MiB: the object size alone accounts for
  the gap, and in total the rest of Map's storage matches hashbrown's.

Trig's Map storage outside `Map[U32, U32]` (`Map[U32, Int]`,
`Map[InferenceKey, I32]`) isn't measured here. Helper's census would say
which other shapes matter.
