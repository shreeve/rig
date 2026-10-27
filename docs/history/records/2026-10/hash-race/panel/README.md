# Hash race panel (2026-10-27)

Three experts judged the second round's numbers and said how Rig's
maps take first place. They wrote:
[hardware.md](hardware.md) on what the CPU rewards,
[design.md](design.md) on the tables, and
[compiler.md](compiler.md) on what Rig must emit.
They read the one-round Mac data
([mac-v2-one-round.txt](mac-v2-one-round.txt)), pup's first round, and
the earlier [design study](../design-study.md). The owner's plan
(2026-10-27):
- build the winners in Zig first, by any technique Zig offers;
- preserve safety where possible;
- then make Rig emit that Zig.

## What the three agree on

- **The unordered `HashMap`** takes boost's layout: groups of 15 tags and
  an overflow byte, metadata apart from slots, and a one-byte erase with
  no tombstones. The design changes boost in five places:
  - a 3-instruction group scan on arm64;
  - no element prefetch for large values;
  - a rehash forced by churn sizes the table to at most 0.6 full;
  - keys kept apart from values over 32 bytes;
  - a one-pass insert.
- **The ordered `Map`** keeps dense entries in insertion order, 16 bytes
  for `Map[Int, Int]` with no `V?`. Its index is split:
  - 16 bytes of tags a group;
  - a separate line of 32-bit entry indexes.

  A take clears a tag and sets a gone bit, never shifting or rehashing,
  and compaction runs only at growth.
- **What an ordered map cannot do.** It waits on memory twice for a hit
  out of cache, so it cannot win hits or the latency chain from 100k keys
  up: about 1.5-1.8x the best flat map. The `HashMap` carries those rows.
  The ordered Map should lead ordered maps on them and can win misses, which
  read only the tags.
- **Neither hash is the bottleneck;** the tables are.
- **Rig's emitted Map today** probes a byte at a time, chases three
  Lists, and repeats bounds and `V?` tests: 18 instructions an entry to
  iterate. Its ownership machinery leaves no instructions.
- **What Rig needs, in order, all safe by construction:**
  1. a per-target walk of a mask's lanes;
  2. a proof that `e & (len - 1)` is in range;
  3. `prefetch`;
  4. a way to make `n` nones of an owning optional, and zeroed blocks.

  `rarely` already gives a branch hint, and owning entries already have
  a niche.
- **Fairness, fixed in this round:** every contestant now builds for the
  CPU it runs on (Rig and Zig already did). The earlier rounds' C++ and
  Rust ran on a baseline instruction set.

## Findings to keep

- Zig's own `std.HashMap` collapses under churn: 91 µs a step at 100,000
  keys against hashbrown's 7.5 ns. Zig's std says so at `rehash`.
- At 16 and 1,000 keys the latency chain favours scalar probing (Zig
  4.31 ns, Rig 4.58) over every SIMD-group table (6.7-8.2): the main
  risk to the `HashMap` taking every row.
- Rig's table grows four times over, so its load swings from 0.29 to
  0.76.
- Rig's text miss at 100,000 keys is 69.65 ns, 60 ns more than its table
  explains. It needs a profile.
- Rig's 4M insert win on pup comes from its allocator faulting pages in
  ahead, not from its table.

## The owner's decisions

The owner approved every default as written (2026-10-27): "Approve
the panel's defaults."

1. Rig's place in a row is its faster map's, and each family also leads
   its own class. *Yes.*
2. The ordered Map leads ordered maps on out-of-cache hits and the 4M
   chain, and the `HashMap` takes first place there. *Accept.*
3. If no design wins the 16- and 1,000-key latency rows without losing
   a hit row, concede them to Zig and record it. *Yes.*
4. A take drops its key at once, not at the next compaction. *Yes.*
5. Entry indexes are 32 bits, so a Map traps past 2^32 - 1 entries.
   *Yes.*
6. Compact only when the entry array is full and a quarter gone, when
   the index grows, or when a take empties the Map. *Yes.*
7. Inside the tables, hash an integer key with one multiply, and leave
   `.hash()` as it is. *Only if over 2% faster on the small rows, with
   nothing slower.*
8. A foldhash-style text hash up to 32 bytes, which changes `.hash()`
   for text. *Yes, if measured faster.*
9. Names:
   - a mask's lanes: `for k in m.lanes()`;
   - prefetch: `xs.prefetch(i)`, read only;
   - a branch hint: `rarely`, as now;
   - nones: `List.filled(n, none)`, checked against CORE §10 first.
10. The entry index read from the index keeps its bounds test. A `raw`
    unchecked read only if the "Rig-shaped" Zig variant (the prototype
    with Rig's tests put back) shows the test costs over 2%.
11. Huge pages for blocks of 2 MiB or more, from Rig's allocator on
    Linux. *Decided apart, after Trig's peak memory is measured; the race
    also reruns its 4M rows with glibc's huge pages for C++ and Rust.*
12. The bar for a map-only feature: bench/hash's rows against the Zig
    prototype, with Trig and std.json no slower. *Yes.*
