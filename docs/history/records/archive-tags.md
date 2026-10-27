# Archive tags (2026-10-27)

Rig keeps work that did not land, but is worth reading again, as an
annotated tag `archive/<branch>` on GitHub rather than as a branch
(owner, 2026-10-26). Each tag's message names its PR and why it was
kept; this page says what each holds, what was decided, and where the
measurements are. A branch archived later adds its row here.

Read a tag with `git log main..archive/NAME` and `git diff
main...archive/NAME`; start work from one with `wt new NAME
archive/NAME`. An archive tag is deleted only on the owner's word.

## Map, table, and List speed

These were measured on Trig against the speed bar (AGENTS.md, "A speed
feature pays for its lines") and not taken. They are the reading list
for the hash map's next design.

| Tag | Commit | What it holds | Decision | PR | Records |
|---|---|---|---|---|---|
| `archive/map-stage` | `1b31b15c3` | A Map of plain keys and values keeps its entries in its slots (Swiss control bytes, at most 7/8 full); the write methods, iterators, and `take` stay inlined; a rebuild keeps the order in a List of its own; a probe's slot arithmetic wraps under its mask | Not taken: the shipping PGO build is 1.5% slower warm and 3.8% slower cold at four checkers on ts-pattern, zod3 uses 5% more memory with PGO, and bench/hash's large maps are slower | #702, closed; measured in #703 | [map-stage/build.md](2026-10/map-stage/build.md) |
| `archive/map-inline` | `d1293a142` | "The split": a key of plain data is probed inline and any other key by a call LLVM may inline, the Map trace finding Map and Set by their keys' plainness parameter | Not kept. The same hot path without the split landed as #710 (branch `map-inline-asis`): Map spills 412M to 47M instructions, 1.44-1.65% fewer instructions | none; #710 landed the alternative | [map-inline/README.md](2026-10/map-inline/README.md), "The split" |
| `archive/list-grow` | `b88612850` | A List's first buffer comes straight from the allocator, growth judges a small block's place inline, and `List.push` is inlined at every call | Not taken: 0.94% fewer instructions on ts-pattern on top of #696, under the 1% bar, with no change in time; two std.json programs slower (gsoc-2018 by placement, canada by the inlined push) | #697, closed; measured in #700 | [perf-stage/list-grow.md](2026-10/perf-stage/list-grow.md) |
| `archive/table-prefault` | `1db830905` | A large table faults in each 2 MiB stretch as a write first reaches it (probe arms 5 and 6) | Not taken: about 1% fewer cycles, peak memory higher; no arm more than 2% faster or 1% fewer instructions | none; measured in #699 | [table-prefault/README.md](2026-10/table-prefault/README.md) |
| `archive/table-prefault-arm6` | `a1792e500` | Arm 6 as it would land: pushes fault in a large table a huge page at a time | Not taken, as above; it passed the suite first | none; measured in #699 | [table-prefault/README.md](2026-10/table-prefault/README.md) |
| `archive/probe-sweep` | `967e3024c` | Unfinished work on `faultsAhead`, the probe behind the table prefault arms (one file) | Exploratory, never measured on its own | none | [prefault-lead/README.md](2026-10/prefault-lead/README.md) (the nearest) |
| `archive/hash-map-wip` | `d8748f82c` | hash.Map with one `U64` slot per entry and branchless slot shifts | Dropped: inserts and misses 15-26% slower at 1M keys | #311, closed; its numbers are there | [revamp/r3/hashmap-report.md](revamp/r3/hashmap-report.md) (the design) |

## Checks, scheduling, and checking

| Tag | Commit | What it holds | Decision | PR | Records |
|---|---|---|---|---|---|
| `archive/span-type` | `47b13a4f8` | `Span[n]`, a run of a table's slots viewed as a slice with no test, typed, lent, and emitted as a slice of a List is | Closed by the owner: within the noise on Trig (ts-pattern 0.7% slower to 0.2% faster), since the index tests it removes are predicted | #686, closed; measured in #690 | [perf-stage/proofs.md](2026-10/perf-stage/proofs.md) |
| `archive/proof-edges` | `f58847b40` | Facts on a guard's false edge (`return 0 if i >= s.len` proves `i < s.len` after it), and a proven offset converted by bit cast and truncation, leaving LLVM no assumption | Closed by the owner, with `span-type`: within the noise, 0.01-0.25% more instructions | #687, closed; measured in #690 | [perf-stage/proofs.md](2026-10/perf-stage/proofs.md) |
| `archive/inline-idle` | `fc347a174` | A bounded file call (stat, a directory's listing, a read or open of a regular file) runs on the calling worker when it has nothing else to run, rather than on the blocking pool | Closed by the owner: Trig's whole run and loco did not move, which does not pay for 736 lines | #689, closed; measured in #691 | [consolidation-2/inline-idle.md](2026-10/consolidation-2/inline-idle.md) |
| `archive/oraclegen` | `645140f94` | The oracle checks a generic body's type parameter values for the loans they carry; it found a fourth generic hole | Parked behind the design of loans carried by `T`, then archived and its PR closed (2026-10-16) | #216, closed | [ledger.md](ledger.md), 2026-10-14 to 16 |
| `archive/symbols-prototype` | `ba794b72c` | A prototype of `@name` labels and `:name` symbols, a design study not for merge | Both built afresh since: labels in #257, and `:name` symbols (src/symbols.zig) | none | [revamp/r3/proposal-symbols.md](revamp/r3/proposal-symbols.md) |
