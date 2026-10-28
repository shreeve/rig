# Closing the gaps to the Zig prototypes (2026-10-27)

The built-in tables run the Zig prototypes' own code (#736, #738), so a
row where `Map` trails `zig-ordered` or `HashMap` trails `zig-hash` is a
cost at the table's edges. The owner asked for every gap closed: the bar
is within 3% of the prototype on every bench/hash row, or faster. This
page finds each gap's cause, fixes it where it lives, and names what
remains. Times are ns an operation, fastest of 5 (`bench-hash`); the Mac
rows ran through `tools/low`, pup's on core 1 with its sibling idle.
Raw output: [table-gaps-data/](table-gaps-data/).

## 1. Text keys: `String(...)` grew its buffer

Run on Rig's allocator (`zig-hash:rig`, `zig-ordered:rig`), the prototypes
were as fast as on malloc or faster, so the allocator was not the text
gap; a HashMap hashed with Wyhash, the prototype's hash, was slower than
with its own, so the hash was not either. The keys were: map.zig formats
each text on the stack and allocates it once, as `format!` does, while
`String("key", n)` appended its pieces to an empty String, whose buffer
grew as it wrote, so each key took several allocations and sat apart from
the next with spare room. `String.of` now writes text of up to 256 bytes
on the stack and allocates it once at its length. Mac, HashMap against
`zig-hash`:

| row | before | after | zig-hash |
|---|---:|---:|---:|
| str16 insert | 13.80 | 10.78 | 7.48 |
| str16 remove | 20.51 | 7.38 | 8.93 |
| str1000 remove | 19.81 | 10.59 | 12.75 |
| str100000 hit | 16.06 | 6.63 | 5.72 |
| str100000 remove | 33.73 | 24.85 | 26.52 |
| str1000000 hit | 31.62 | 28.09 | 24.82 |
| str1000000 insert | 32.12 | 26.12 | 15.48 |

The `string` rows, which only Rig runs, look keys up in the order they
were put, which the ordered Map reads from cache and a hash table cannot:
`Map` leads `HashMap` there by design, not by a defect.

## 2. HashMap: slot prefetch and walks

A `String` key's slot (key, value, hash) is 40 bytes, the prototype's
text slot 32, and the table prefetched slots only up to 32: it now does
up to 40, 4-9% on large text hits on the Mac. A HashMap walk was Rig
code in the prelude doing checked arithmetic on its `Int` fields and
reloading the table through `self.map.*.t` every step; the table's
`next_slot` now does the step in the runtime. pup, HashMap iterate:

| row | before | after | zig-hash |
|---|---:|---:|---:|
| int16 | 0.65 | 0.56 | 0.66 |
| rnd1000 | 0.61 | 0.54 | 0.54 |
| rnd100000 | 1.02 | 0.93 | 0.86 |
| rnd150000 | 1.33 | 1.18 | 1.12 |
| big100000 | 1.43 | 1.28 | 1.29 |

## 3. Inserts: the allocator

A Map's rebuilt index cleared its slots and its tags; a slot is read only
where its tag is set, so only the tags are cleared now (a fifth of the
bytes; no change measured). Skipping the clear for fresh pages from the
system (the prototype's `calloc`) measured as nothing and was not kept.
What remains on inserts is the allocator: pup, ms a run, the prototype on
malloc and on Rig's `alloc.zig`:

| row | Map | zig-ordered | zig-ordered:rig |
|---|---:|---:|---:|
| int100000 insert | 2.89 | 2.40 | 2.86 |
| big100000 insert | 5.86 | 4.60 | 7.01 |
| big16 insert | 3.13 | 2.11 | 3.01 |

The same table on `alloc.zig` is as slow as the Map, so glibc grows
these blocks faster, likely in place where `alloc.zig` copies across a
size class or under `move_large`. Growing in place is the allocator's
work (worktree alloc-grow); at 4,000,000 keys `alloc.zig` already wins
(HashMap int4000000 insert 23 against `zig-hash`'s 35).

## 4. Where it stands

Rows more than 3% behind the prototype, of 104. The Mac's are main
against this branch's first fix (section 1); pup was first measured
with that fix in, so its counts are the branch's alone:

| | main | branch |
|---|---:|---:|
| HashMap, Mac | 53 | 49 |
| Map, Mac | 31 | 22 |
| HashMap, pup | | 14 |
| Map, pup | | 25 |

Across all 104 rows on pup the Map takes 0.969 of `zig-ordered`'s time
(geometric mean). The Mac's counts include its code-layout noise of a
few percent (docs/history/rig-notes.md). What remains:

- inserts that grow blocks of 100,000-150,000 keys and 64-byte values
  (section 3), the allocator's;
- 64-byte values in 16-key HashMaps (insert 1.4, remove 1.2), where a
  value is copied through the prelude's wrapper; not yet diagnosed;
- a few rows at 100,000-150,000 keys (removes, hits) that moved by 10-30%
  between runs on a pup shared with other builds; the Map's 25 rows on pup
  are from such a run, and are to be judged again on a quiet machine.
