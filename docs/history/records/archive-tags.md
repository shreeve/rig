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
| `archive/masked-index-loops` | `bb901bbf1` | The masked-index proof (#729) plus Map, Set and Interner probes that count from the home slot, `(home +% d) & mask`, with no bounds test | Not taken with the proof: 1.15% fewer instructions on Trig (ts-pattern and zod3), time unchanged, but bench/hash's lat16 chain 20-50% slower on the Mac in each of six loop shapes; that row swings 1.4-3.9 ns between builds of the same source. The loops wait for the ordered Map's rewrite | #729 landed the proof alone | [hash-race/map-rewrite-plan.md](2026-10/hash-race/map-rewrite-plan.md) |
| `archive/std-hash` | `fc964bf5b` | std.hash: `hash.Map` and `hash.Set`, unordered, as a SwissTable (16-tag groups, at most 7/8 full, one inlined probe), slots holding the entry where key and value are plain, in-place growth by `mremap` for large tables, pair hashing in the runtime; its members, tests (test/rig/std-hash.rig.test), STD.md section and bench/hash rows | Archived for a rebuild on boost's FOA design (owner, 2026-10-27): on random keys its removes take 1.4-3.0x and its inserts 1.2-3.3x the fastest table's time; on Trig, ts-pattern within noise and zod3 1-2.5% slower with 10% more peak memory | #685, closed | [std-hash/plain-slots.md](2026-10/std-hash/plain-slots.md), [hash-race/](2026-10/hash-race/) |
| `archive/hash-map-wip` | `d8748f82c` | hash.Map with one `U64` slot per entry and branchless slot shifts | Dropped: inserts and misses 15-26% slower at 1M keys | #311, closed; its numbers are there | [revamp/r3/hashmap-report.md](revamp/r3/hashmap-report.md) (the design) |
| `archive/small-maps-pre` | `55a252725` | #758's first two designs: a small Map or Set as one block with no index up to 48 entries, then 64 bytes with a take that empties a table out of line | Rejected by the owner (2026-10-28): Map bench rows up to 70% slower on the Mac; the reworked 64-byte Map landed in #758 | #758, merged in its later form | [hash-race/small-maps.md](2026-10/hash-race/small-maps.md) |
| `archive/lazy-table` | `d5e670615` | A reserved Table on Linux and in leak-checked builds reserves at its first write: until then its slots read a shared read-only zero range sized to the widest table that asked; `push` compares `len` with a `lim` field, a slot write tests `lim` once, a never-written table's drop does nothing; 14 `fail` cases pin that no view lives across the first write | Not taken: Trig's phase B writes every Ast's table at birth, and with that deferred it still loses (1.8-24% slower on pup E-cores); Trig main pays 0.08-0.36% user instructions and up to 1.5% peak RSS for nothing | none (queue row 50) | [perf-stage/lazy-table.md](2026-10/perf-stage/lazy-table.md) |
| `archive/kernel-leads` | `20c5d3ab2` | Three kernel-time leads in `alloc.zig` as one measurement arm: a reserved Table asks for huge pages for its whole range, its first 2 MiB included; new and grown large blocks ask from 2 MiB, not 16; every heap faults its segments in ahead, its first included (each lead alone is a patch in the record) | Not taken: each raises Trig's peak RSS where it acts (lead 1 27-408%, lead 3 1.2-34%, lead 2 0.96% on ts-pattern), against the owner's rule of no speed for memory | none (queue row 44) | [perf-stage/kernel-leads.md](2026-10/perf-stage/kernel-leads.md) |
| `archive/string-inline` | `54f8f2ac3` | A String holds up to 23 bytes inline, its first byte `0x80 \| len`, the empty String inline, `String?` no larger | Archived (2026-10-29): random text keys 40-217% faster and ts-pattern 0.9% faster, but 16 short keys 18-23% slower and the `string intern` row 21% slower, which no Map row may be | #724, closed | the PR |
| `archive/table-arena` | `4f238f041` | Packed Tables: a Table's first 2 MiB in heap blocks, moved once into its reserved range when it spills; every slot read tests `i >= cap` | Not taken (2026-11-04): page walks 4.2-4.5% to 0.8-1.5% of user cycles, but 14-18% more instructions and 8-24% more peak memory, 6-12% slower on Trig; revisited by the panels of 2026-11-05 and dropped: no read path for a shared-page layout avoids the test, and on P-cores there is no walk saving to pay for it | none | [scaling/table-arena.md](2026-11/scaling/table-arena.md), [panels/table-arena/](2026-11/panels/table-arena/) |
| none (`table-color.diff` kept) | none | Colored Tables: Table k starts `k*37 mod 512` pages into its reserved range, so Table heads stop sharing one STLB set | Not taken (2026-11-02): on E-cores 76-85% fewer page walks and 2.1-4.6% fewer user cycles, on P-cores level against an A/A arm at one and four checkers; confirmed by the panels of 2026-11-05 | none | [perf-stage/stlb-aliasing.md](2026-10/perf-stage/stlb-aliasing.md), [panels/table-arena/critic.md](2026-11/panels/table-arena/critic.md) |

## Checks, scheduling, and checking

| Tag | Commit | What it holds | Decision | PR | Records |
|---|---|---|---|---|---|
| `archive/span-type` | `47b13a4f8` | `Span[n]`, a run of a table's slots viewed as a slice with no test, typed, lent, and emitted as a slice of a List is | Closed by the owner: within the noise on Trig (ts-pattern 0.7% slower to 0.2% faster), since the index tests it removes are predicted | #686, closed; measured in #690 | [perf-stage/proofs.md](2026-10/perf-stage/proofs.md) |
| `archive/proof-edges` | `f58847b40` | Facts on a guard's false edge (`return 0 if i >= s.len` proves `i < s.len` after it), and a proven offset converted by bit cast and truncation, leaving LLVM no assumption | Closed by the owner, with `span-type`: within the noise, 0.01-0.25% more instructions | #687, closed; measured in #690 | [perf-stage/proofs.md](2026-10/perf-stage/proofs.md) |
| `archive/inline-idle` | `fc347a174` | A bounded file call (stat, a directory's listing, a read or open of a regular file) runs on the calling worker when it has nothing else to run, rather than on the blocking pool | Closed by the owner: Trig's whole run and loco did not move, which does not pay for 736 lines | #689, closed; measured in #691 | [consolidation-2/inline-idle.md](2026-10/consolidation-2/inline-idle.md) |
| `archive/loop-tick` | `e62feea16` | A bounded loop in a program that makes tasks runs in strips of up to 1,024 turns with no yield check in a turn; the outermost loop checks between strips (`rig.stripTurn`), an inner loop counts its strip's turns in the outer count, and storage's `loop_turns` decides which loops do | Not taken (owner, 2026-10-31): Trig's ts-pattern 2.6% slower on pup (2.5% more cycles, 2.2% more instructions), zod3 2.1% slower; a study of cheaper checks found none both sound and cheaper, so the per-loop count stays | #782, closed | [sched-check/README.md](2026-10/sched-check/README.md) |
| `archive/loop-split` | `b26070087` | A counted range that always runs to its end, in a program that makes tasks, runs in blocks of the turns left before the next yield check, with one check at each block's end (`rig.turnStop`, `rig.turnEnd`); the count is exact, so seeded schedules are unchanged | Closed by the foreman under the speed rule (2026-11-05): bench/tasks' CPU loops 14-21% fewer cycles on the Mac, but on Trig, pup, 0.5-1.4% more instructions and wall time within noise; revisited by the panels of 2026-11-05 and dropped: the Mac's gain is LLVM's code for one arithmetic loop, not the yield check, and Trig with the split is 0.3-1.0% slower on the Mac too; signal preemption replaces it | #966, closed | [loop-split/README.md](2026-11/loop-split/README.md), [panels/loop-split/](2026-11/panels/loop-split/) |
| `archive/oraclegen` | `645140f94` | The oracle checks a generic body's type parameter values for the loans they carry; it found a fourth generic hole | Parked behind the design of loans carried by `T`, then archived and its PR closed (2026-10-16) | #216, closed | [ledger.md](ledger.md), 2026-10-14 to 16 |
| `archive/symbols-prototype` | `ba794b72c` | A prototype of `@name` labels and `:name` symbols, a design study not for merge | Both built afresh since: labels in #257, and `:name` symbols (src/symbols.zig) | none | [revamp/r3/proposal-symbols.md](revamp/r3/proposal-symbols.md) |
| `archive/table-ahead` | `091390361` | A reserved Table faults in the 64 KiB past each push with one `MADV_POPULATE_WRITE`, on Linux | Archived on the owner's approval: 65% fewer faults but 0.4% fewer cycles, since populating saves only the trap and the frontier check stopped `push` from inlining; huge pages for large tables are built instead | none | [perf-stage/fault-ahead/](2026-10/perf-stage/fault-ahead/README.md) |
| `archive/emit-inplace` | `1e3844fdd` | A payload taken out of an optional by value is copied once, from where it is (`storage.takeFrom`), not four times | Archived (2026-10-29), gates green: Trig's cycles within 0.7% either way, under the speed bar; to be measured stacked with others | #755, closed | in the tag: `perf-stage/payload-in-place.md` |
| `archive/mem-alloc-b` | `74c07e65a` | Memory PR B's B1 and B3: heaps share remote lists (a heap takes another's before each page it carves), large-block totals counted per heap in batches, and one large-block bound | Parked by the owner (2026-10-30) after three rounds: against main `600944974` on pup, kv with 64 KiB values 4-6% slower and xmalloc-test 10% slower, for about 45% and 85% less memory, sh8bench 17% faster; to return when cross-heap reuse is redesigned on its own. B2 landed as #788 | #785, closed | in the tag: CHANGELOG and HANDOFF entries, INTERNALS |
| `archive/rt-by-value` | `bc1080495` | An inlined function's object parameter or object result becomes a run-time value through a `var` in place, not through `rig.rt` | Not taken: Trig PGO 0.6-1.1% slower on ts-pattern and 1.7-2.2% slower on zod3 by user cycles, store-forward blocks 13% more on zod3; bench/hash level on pup | #816, closed | [perf-stage/codegen-gap.md](2026-10/perf-stage/codegen-gap.md), §6 |
| `archive/hash-int-spread` | `ed93b7b78` | The HashMap's integer hash multiplier a464, in place of 4b33 | Not taken (2026-11-01, overnight under the owner's delegation): a quiet pup rerun over four code layouts cleared its three RED rows, but remove rows are 6.9-9.3% slower at the median beyond about 2% noise, and the owner's exceptions covered only the Mac's int iterate and int1000 remove; no Map row may get slower | #802, closed | the #802 comments |
| `archive/list-push` | `fcdcef091` | `List.push` inline, reading its length once; `String.push` reading its length once (the json panel's item 3) | Not taken (2026-11-06): Trig at one and four checkers gained nothing (instructions level to 0.18% more, paired cycles within noise to 2.1% more), and std.json ran 3.0% slower on gsoc-2018 for 1.8% fewer instructions; Trig's binary 12.9 KB larger. A lightweight tag, not annotated | none (measured on its branch) | [json/list-push-2026-11-06.md](2026-11/json/list-push-2026-11-06.md) |
| `archive/preempt-std` | `54f73728f` | Option A of preemption by default: std.text's searches pay at their entry the yield check a signal left owed (`rig.owedAtEntry`, the process-wide count `sched.owing`) | Not taken (2026-11-06): it closes the gap as #994 (option B) does, a 20 ms sleeper beside a loop of searches woken at 20 ms, but costs 2-3 instructions per search in a build with the option (find 84.42 against 82.07, count 155.19 against 151.92) where B costs none. Kept as the fallback for code that cannot be placed in the program's section | none (never a PR) | [preempt/default-on-2026-11-06.md](2026-11/preempt/default-on-2026-11-06.md) |

## Tags of 2026-11-15 to 2026-11-20

The concurrency, fork-join, HTTP, spawn, and memory rounds of these days
archived their probes, timing arms, and attempts not taken as they went.
The branch cleanup of 2026-11-20 (owner: one `main` branch, every other
branch an archive tag or gone) gave the rest theirs. Each row gives the
tag's own message, or its commit's subject where the tag carries none.
The measurements are in that round's records (records/2026-11/:
`concurrency-*`, `hyper-*` and `mac-fewer-workers` for the HTTP and
sleep rounds, `psum-gap` and `free-fork-join` for fork-join, `spawn-1119`
for spawn and the Mac, `early-memory` for memory).

| Tag | Commit | Archived | What it holds |
|---|---|---|---|
| `archive/panic-cold` | `3f75989e7` | 2026-11-15 | runtime: a failed index and each of Zig's safety checks panic out of line |
| `archive/alloc-kept-age` | `4211977d8` | 2026-11-15 | records: pages the allocator keeps and does not use |
| `archive/alloc-first-seg` | `25bdbe470` | 2026-11-15 | alloc: a heap's first segment keeps small pages |
| `archive/hyper-steal-now` | `c7c8b186f` | 2026-11-16 | sched: probe arm, a worker takes another's run-next fiber at once (steal_next_after 0) |
| `archive/hyper-steal-1us` | `0e46d3605` | 2026-11-16 | sched: probe arm, a busy worker's run-next fiber waits 1 us before another takes it |
| `archive/hyper-steal-2us` | `2dd6fd595` | 2026-11-16 | sched: probe arm, a busy worker's run-next fiber waits 2 us before another takes it |
| `archive/hyper-steal-4us` | `c175d68c7` | 2026-11-16 | sched: probe arm, a busy worker's run-next fiber waits 4 us before another takes it |
| `archive/hyper-stack` | `6453c55bb` | 2026-11-16 | tasks: an isolate runs on the stack its worker kept from the last |
| `archive/hyper-deadline` | `208e0e919` | 2026-11-16 | net: a connection's deadline is one timer that moves only when it fires |
| `archive/hyper-headers` | `735c8a696` | 2026-11-16 | http: headers are parsed once, and an answer's head is written from text made once |
| `archive/hyper-search-stamp` | `6349f1e29` | 2026-11-16 | sched: a searcher takes a run-next fiber it has seen 3 µs by its own clock |
| `archive/hyper-search` | `5c14e07ae` | 2026-11-16 | sched: a searcher takes a run-next fiber still in its slot after 3 µs, however its owner switched |
| `archive/hyper-search-slack` | `ec2d2bdf5` | 2026-11-16 | sched: a worker's timed waits on Linux keep to their time, with 1 ns of slack |
| `archive/hyper-search-brief` | `b9d26e8fe` | 2026-11-16 | sched: a searcher's brief wait for a run-next fiber keeps to its time on Linux |
| `archive/hyper-search-fix` | `cb10c93c5` | 2026-11-16 | sched: a searcher takes a run-next fiber it has seen 3 µs, however often its owner switched |
| `archive/hyper-all` | `6dd724288` | 2026-11-16 | http: headers are parsed once, and an answer's head is written from text made once |
| `archive/hyper-parse` | `ee90434bc` | 2026-11-16 | http: a request's head is read in one pass |
| `archive/hyper-look` | `c955351b7` | 2026-11-16 | sched: a poller is skipped only while its worker is inside the kernel's wait |
| `archive/hyper-look0` | `971247345` | 2026-11-16 | sched: look_after is 0 µs, a timing arm |
| `archive/hyper-look250` | `e5d4d8bcf` | 2026-11-16 | sched: look_after is 250 µs, a timing arm |
| `archive/hyper-quiet` | `d994802af` | 2026-11-16 | sched: a switch that leaves work only in run-next slots kicks no searcher |
| `archive/hyper-connect` | `5f5f19b77` | 2026-11-16 | sched: a searcher sees a fiber put back in a run-next slot afresh |
| `archive/hyper-noindex` | `ccd7474d2` | 2026-11-16 | http: a request's head is read in one pass |
| `archive/hyper-noindex-look` | `41002bb5c` | 2026-11-16 | sched: the look tests stamp their looks ahead of the clock, so a loaded machine cannot fail them |
| `archive/hyper-noindex-precise` | `b6cfc37ee` | 2026-11-16 | sched: a searcher's wait for a stuck worker's run-next fiber keeps to its time on Linux |
| `archive/hyper-noindex-once` | `0ba467dc5` | 2026-11-16 | sched: a searcher waits once for a run-next fiber it noted |
| `archive/hyper-nofill` | `222d477e4` | 2026-11-16 | sched: a steal and a look at a poller fill no stack buffer first |
| `archive/hyper-ring` | `70c67f386` | 2026-11-16 | formal: the sleep model wakes as the scheduler does, with workPending, spread and the pollers' batches |
| `archive/hyper-nosearch` | `bdea1eb0d` | 2026-11-16 | http: transfer codings are named in any case, and empty lines before a request line are skipped |
| `archive/hyper-qos` | `7ab2bf7d3` | 2026-11-16 | sched: a sleeping worker looks at another's poller only while that one is stuck awake |
| `archive/sched-solo` | `26d178e46` | 2026-11-16 | sched: a sleeping worker looks at another's poller once its worker has left it unattended |
| `archive/sched-flush-s` | `895095f55` | 2026-11-16 | sched: a sleeping worker looks at another's poller once its worker has left it unattended |
| `archive/sched-accept` | `a71646a3c` | 2026-11-17 | sched: a sleeping worker looks at another's poller only once its worker has left it unattended |
| `archive/layout` | `e7d2128fb` | 2026-11-17 | sched: probe arm, two functions moved to the file's end (a layout control for timing, not for merge) |
| `archive/sched-batch-c2` | `4482fd87d` | 2026-11-17 | sched: the last searcher that woke no one looks again at its next switch |
| `archive/map-measure-wip` | `e77268df7` | 2026-11-17 | map-measure: uncommitted edits kept when the worktree was removed (archive only) |
| `archive/mem-census-wip` | `19a196060` | 2026-11-17 | mem-census: uncommitted edits kept when the worktree was removed (archive only) |
| `archive/sched-holder` | `e07c367e0` | 2026-11-17 | sched: a sleeping worker holds a busy worker's poller and rings its bell |
| `archive/layout2` | `b75cc1839` | 2026-11-17 | sched: probe arm, two functions moved to the file's end (a layout control for timing, not for merge) |
| `archive/sched-holder2` | `975d60ebf` | 2026-11-17 | sched: a worker that answers its bell arms its holder's watch at once, and only an idle worker holds |
| `archive/sched-holder2b` | `1f48e9bb7` | 2026-11-17 | sched: a holder rings only after the owner has been busy 20 µs (timing arm) |
| `archive/watch-d` | `0683d21ac` | 2026-11-17 | sched: the test of a watched worker asleep in its poller reads its pipe's result as a signed count |
| `archive/lay3` | `94194cd14` | 2026-11-17 | sched: probe arm, two functions moved to the file's end (a layout control for timing, not for merge) |
| `archive/watch-d2` | `daace2ebe` | 2026-11-17 | test: sched_stats's SIGTERM case ends main's own sleep, which the signal cancels |
| `archive/watch-d3` | `b26e6f536` | 2026-11-17 | sched: a watcher waking with work keeps the watch unless another owner is busy |
| `archive/120k-d4` | `6c0416f4f` | 2026-11-17 | sched: on Linux every worker sleeps in one epoll that nests every poller |
| `archive/shared-sleep` | `6c0416f4f` | 2026-11-17 | sched: on Linux every worker sleeps in one epoll that nests every poller |
| `archive/120k-lay` | `20aec4a2c` | 2026-11-17 | sched: probe arm, two functions moved to the file's end (a layout control for timing, not for merge) |
| `archive/120k-d4m` | `ba0281a69` | 2026-11-17 | sched: probe arm, the shared sleep of archive/shared-sleep on main (not for merge) |
| `archive/closed-c1` | `62144fdb3` | 2026-11-17 | probe arm, not for merge: closed-loop switches on the Mac (RIG_P_AGE, RIG_P_AGESTEAL, RIG_P_NOWRITE) over the mac-echo probe's |
| `archive/120k-d5` | `815d0ab1c` | 2026-11-17 | sched: probe arm, a notify with no worker in the shared epoll kicks a sleeper and rings no bell (not for merge) |
| `archive/closed-c2` | `9ccb0a7a3` | 2026-11-17 | probe arm, not for merge: efficiency-core rules, free helpers, a look by the owner's run time, and counters on SIGUSR1 |
| `archive/120k-gs` | `3eda58ef4` | 2026-11-17 | sched: probe arm, the direct shared epoll compiles for Linux (not for merge) |
| `archive/closed-c3` | `7bba55531` | 2026-11-17 | probe arm, not for merge: the rules hold only while the fibers of the workers that hold descriptors are short (RIG_P_R) |
| `archive/closed-final` | `c9b42cb9d` | 2026-11-17 | probe arm, not for merge: on the Mac a worker whose fibers are short keeps its events' work |
| `archive/120k-lend` | `bb58fc63c` | 2026-11-17 | sched: probe arm, a watch's nested poller is registered for the watch and removed with it (not for merge) |
| `archive/closed-final2` | `9969c559a` | 2026-11-17 | probe arm, not for merge: the watcher takes a batch kept past its time, and one load at a switch |
| `archive/closed-one` | `ada025290` | 2026-11-17 | probe arm, not for merge: the short-fiber rule with its stall guard, and every descriptor in worker 0's poller |
| `archive/120k-lend2` | `1603c5c81` | 2026-11-17 | sched: probe arm, a sleeper watches no poller for a while after its watch fires (not for merge) |
| `archive/tasks-spin` | `fb1948c58` | 2026-11-17 | sched: probe arm, a worker on a performance core spins 5 us for work before it sleeps (not for merge) |
| `archive/tasks-switches` | `664e78054` | 2026-11-17 | sched: probe switch RIG_P_PUSHCAP, a cap on the wakes of fibers pushed out of a run-next slot (not for merge) |
| `archive/fork-join-ring` | `f7895d3f0` | 2026-11-18 | probe: `>t` takes its task back from its worker's ring tail, not for merge |
| `archive/fork-bc` | `79cbc4fe8` | 2026-11-18 | probe: RIG_PROBE_RAW=1 hands clang Zig's unoptimized bitcode, so one pipeline runs, with the loop vectorizer |
| `archive/fork-qsort-ext` | `31f661b6c` | 2026-11-18 | fork record: qsort appends its halves with extend, as its Rayon twin does |
| `archive/fork-qsort-ipn` | `9c6ab14c3` | 2026-11-18 | std.sort: the integer partition swaps its pivot as a value and walks by pointer |
| `archive/fork-join-inline` | `2734c69c7` | 2026-11-18 | probe: count the yields a yield check makes to queued work (claimWaiting) |
| `archive/fork-fold` | `9217052e0` | 2026-11-18 | probe: fold a checked += over integers by vectors, exactly |
| `archive/fork-join-ring-tail` | `455ad60dd` | 2026-11-18 | probe: `>t` takes its task back from its worker's ring tail, not for merge |
| `archive/120k-l7` | `8ec62a7e7` | 2026-11-18 | 120k-l7: a sleeper polls a long-running worker's poller beside its own with one poll(2). Board AG (pup slot 550): 120k p50/p99/p99.9 17/58/75 against main's 23/63/89 and hyper's 17/56/89, no stalled rounds; mix 70,818 cycles a request against main's 66,523 (6.5% more) and hyper's 69,293. Dropped by the owner 2026-11-18: the mix cost outweighs the 120k gain. |
| `archive/seg-first-small` | `205d09c37` | 2026-11-18 | alloc: the test of a heap that does not fault in ahead takes half a segment before its first |
| `archive/zig-0171` | `53d983b53` | 2026-11-18 | toolchain: Zig 0.17.1 |
| `archive/fork-maker` | `4e9e6f076` | 2026-11-19 | sched: a fork waits behind its own maker only |
| `archive/spawn-search-once` | `f95c21aff` | 2026-11-19 | sched: a search waits once for every run-next slot it saw full |
| `archive/spawn-clock-look` | `d0995a086` | 2026-11-19 | sched: a search's wait reads the clock once every 16 pauses |
| `archive/spawn-clock-look-steal` | `f38e73737` | 2026-11-19 | sched: stealNext's wait reads the clock once every 16 pauses |
| `archive/elf-anchor` | `bf981bde5` | 2026-11-19 | runtime: the program's section starts on a 16 KiB boundary on Linux too |
| `archive/mac-connect-trims` | `edd13bce0` | 2026-11-19 | net: on the Mac a connection makes three system calls fewer to set up and close |
| `archive/ffj-deque` | `687b84112` | 2026-11-20 | Forks wait on a Chase-Lev deque of their worker's own (#1179, closed 2026-11-19): its fast path was unsound; the inline run (#1175) landed instead. |
| `archive/mac-esteal` | `d220c20c1` | 2026-11-20 | Mac efficiency-core stealing arms (2026-11-20): an E-core thief takes one task, or skips shallow rings; none reached base at 10 workers (108-111 vs 94 ns). |
| `archive/mac-hold` | `dde907515` | 2026-11-20 | Mac awake-worker hold (2026-11-20): helpers with short work keep the search count; lost: spawn at 10 workers 18-44% slower. records/2026-11/spawn-1119 and the round-031 queue. |
| `archive/pgo-novec` | `66232b59b` | 2026-11-20 | rig build --pgo compiles its profile build with LLVM's loop vectorizer off, as Zig 0.17 does (#1178): never measured on Trig's PGO build; closed 2026-11-20 in the branch cleanup, to revive with a Trig PGO A/B. |
| `archive/psum-handoff-pad` | `34545148d` | 2026-11-20 | Layout probe (2026-11-18): 96 bytes of never-run nops in the handoff (x86); records/2026-11/psum-gap. |
| `archive/psum-handoff-pad2` | `b0d4a96fa` | 2026-11-20 | Layout probe (2026-11-18): 96 never-run bytes in the handoff; records/2026-11/psum-gap. |
| `archive/psum-mem` | `fa7d173b0` | 2026-11-20 | psum-gap memory probe B (2026-11-18): a heap's first segment keeps small pages for its first 2 MiB; the idea landed as #1170. |
| `archive/psum-runtime-trace` | `2486d1a03` | 2026-11-20 | psum-gap runtime trace knobs (2026-11-18), RIG_X_WARMHEAP and others, for the first parallel pass; not for merge; records/2026-11/psum-gap. |
| `archive/psum-stack-both` | `644e8e694` | 2026-11-20 | psum-gap board arm (2026-11-18): main with the early-start and handoff changes together; measured in records/2026-11/psum-gap (stack-board.md), superseded by #1158/#1170. |
| `archive/psum-stack-hp` | `ea7217f22` | 2026-11-20 | psum-gap board arm (2026-11-18): main with seg-first-small (first 2 MiB small pages); measured in records/2026-11/psum-gap, superseded by #1170. |
| `archive/ring-steal-race-pad` | `fc71d5685` | 2026-11-20 | Layout probe (2026-11-18): 32 never-run bytes in the handoff, to test whether a psum gap was code placement; records/2026-11/psum-gap. |
| `archive/thp-size` | `350c0a007` | 2026-11-24 | RIG_HUGE_MIN_MB, where huge pages start (ce8f7f9ac), and the Table census (scratch); not taken, the owner kept 2 MiB; records/2026-11/thp-size. |
| `archive/map-trace` | `b104b1bc6` | 2026-11-24 | RIG_MAP_TRACE extended to walks, `at` and creation sites, and RIG_MAP_CENSUS (Maps and Sets alive by length); measurement for records/2026-11/map-replay. |
| `archive/map-replay` | `9312e3b62` | 2026-11-24 | bench/hash/replay: Trig's real map streams against hashbrown, indexmap and an 8-byte Map; no std Map change; records/2026-11/map-replay. |
| `archive/heap-census` | `0f044d51c` | 2026-11-24 | RIG_HEAP_RSS per-heap census, the per-heap huge-page knob RIG_HEAP_HUGE_MIN_MB, and the fragmentation ceilings RIG_SMALL_BORROW and 8-byte classes across 96-160 B; not taken; records/2026-11/alloc-frag. |
| `archive/phase-wide` | `e26d0196a` | 2026-11-24 | `task.widen()` and `task.narrow()` under RIG_WIDE=1 (archive/lower-workers' parking ported to main, heaps kept donors while parked) and test/cli/phase_wide.sh; race 754 a measured negative: summed wall level, check slower by what the front end gained, peak RSS 2.6-6.1% higher ([phase-workers/race-754.md](2026-11/phase-workers/race-754.md)) |
