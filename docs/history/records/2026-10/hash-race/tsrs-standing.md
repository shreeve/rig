# Where Trig stands against tsrs, with the built-in Map (2026-10-27)

The question: with the built-in Map and Set on Rig main (#735, #736),
how far is Trig behind tsrs at one checker, what did each step give,
and which lever comes next? On 2026-10-26 Trig's PGO build took 893.5
ms on ts-pattern against tsrs's 664.7 (1.34×, fastest of 10; Trig's
docs/RESULTS.md, "the scoreboard with PGO").

Measurement only; no code changed. Scripts and raw output are in
[tsrs-standing-data/](tsrs-standing-data/).

## Method

- **Machine.** pup (Core Ultra 9 185H). Every run on P-core 8, its
  sibling 9 idle (`taskset -c 8`). Other sessions built on slot 0,5 and
  timed on core 6 throughout; load average 1.8 to 2.4.
- **Trig.** Main `403a823`, its `src/` taken by `git archive` so that
  the cron's checkout cannot move under the builds, with
  `tools/trig/main.rig` as the root.
- **Rigs.** Each built on pup in its own clone, as `tools/pup-rig` does
  but outside `/zfs/trig-pup/rig-next` (which other sessions' light
  gates use) and on slot 10,11 alone:
  - main `36422da59` (#736, the Map's table a compiler built-in);
  - `f7edd5cb5` (#735, the Map rewritten in Rig on zig-ordered's design);
  - `a38ff34b7`, main before #735. Main's first-parent history puts
    #733 (`alloc-peak`, the allocator's settled peak and kept large
    blocks) between it and #735, so the second step below is #733 and
    #735 together.
- **Builds.** Each Trig built through `/zfs/trig-pup/trial/slot.sh`
  with `TRIG_RELEASE_SLOTS='10,11'`: plain `rig build --release` by
  each Rig, and `--release --pgo` by main's, trained by
  `tools/trig/bolt-train` (mitt, neverthrow, superstruct, zod3), as
  `tools/trig/pgo` builds it. The PGO build is the one raced against
  tsrs (Trig's HANDOFF: the build for benchmarks); the steps are
  compared on plain builds, as Trig's A/Bs are.
- **tsrs.** The shipped 0.18.0 (`/zfs/trig-pup/tsrs-shipped/package/tsrs`:
  PGO, fat LTO, BOLT), and its source build (`/zfs/trig-pup/tsrs/bin/tsrs`)
  beside it, both in Go mode on one thread:
  `RAYON_NUM_THREADS=1 tsrs -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers`.
  Trig: `trig -p tsconfig.trig.json --noEmit --singleThreaded`.
- **Timing** (`time.sh`). 20 rounds, the six variants interleaved in
  each, ts-pattern then zod3. Wall time is perf's `duration_time`;
  cycles and instructions are `cpu_core/*/u`. Peak RSS is
  `/usr/bin/time`'s. Each Trig's output matched the plain main build's
  byte for byte in every round (the PGO build's first round has no
  earlier output to compare against).
- **Kernel time** (`sys.sh`). 10 more rounds of the PGO build and
  shipped tsrs, interleaved: `user_time`, `system_time`, kernel cycles,
  page faults, dTLB misses, all from `perf stat`.
- **Huge pages** (`huge.sh`). Three runs per variant, with
  `/proc/PID/smaps_rollup` read about every 10 ms from E-core 12; each
  line is the sample with the largest Rss, and its AnonHugePages. THP is
  `madvise` on pup.
- **Profile** (`prof.sh`, `attr.py`, `group.py`). User cycles sampled
  every 4,000,037 (perf's 1 kHz cap on pup), 40 runs of the PGO build
  (29,006 samples) and 20 of the plain one (16,797). Each sampled
  address is symbolized with its inline chain (`llvm-symbolizer
  --inlines`) and charged to its innermost frame: the source line the
  instruction came from, inlined or not. So a List read inlined into the
  checker is charged to `runtime.zig`'s `ListOf.at`, not to the checker.

## Trig against tsrs

ts-pattern, 20 rounds:

| | wall median | wall fastest | cycles | instructions | peak RSS |
|---|---:|---:|---:|---:|---:|
| Trig PGO, Rig main | 891.9 ms | 805.9 ms | 3.787G | 8.204G | 275 MB |
| Trig plain, Rig main | 994.7 ms | 914.8 ms | 4.313G | 9.281G | 274 MB |
| tsrs shipped | 691.0 ms | 661.4 ms | 3.070G | 7.229G | 202 MB |
| tsrs source build | 817.2 ms | 791.5 ms | 3.675G | 8.139G | 205 MB |

zod3, 20 rounds:

| | wall median | wall fastest | cycles | instructions | peak RSS |
|---|---:|---:|---:|---:|---:|
| Trig PGO, Rig main | 159.7 ms | 153.7 ms | 0.628G | 1.440G | 87 MB |
| Trig plain, Rig main | 179.4 ms | 175.6 ms | 0.728G | 1.678G | 86 MB |
| tsrs shipped | 117.0 ms | 115.2 ms | 0.486G | 1.206G | 54 MB |
| tsrs source build | 145.8 ms | 142.0 ms | 0.628G | 1.402G | 55 MB |

Trig PGO against shipped tsrs:

| | ts-pattern | zod3 |
|---|---:|---:|
| wall, median | **1.29×** | **1.37×** |
| wall, fastest | 1.22× | 1.33× |
| cycles | 1.23× | 1.29× |
| instructions | 1.13× | 1.19× |
| peak RSS | 1.37× | 1.62× |
| page faults (`sys.sh`) | 2.27× | 1.79× |

The fastest PGO run (805.9 ms) is one round whose cycles fell to 3.38G
against 3.63G to 3.90G in the others; the next fastest is 852 ms
(1.26× tsrs's 677). Judge by the median: **1.29× on ts-pattern** (1.34×
on 2026-10-26, by the fastest), **1.37× on zod3** (1.39×). Trig main
moved too since then (#222 and later), so the change is not Rig's
alone; the steps below are.

The plain build against tsrs's source build (neither with PGO): 1.22×
on ts-pattern, 1.23× on zod3.

## Each step, plain builds, same day

| ts-pattern | a38ff34b7 (before #735) | f7edd5cb5 (#733, #735) | 36422da59 (#736) |
|---|---:|---:|---:|
| wall median | 1,067.6 ms | 1,022.9 ms | 994.7 ms |
| cycles | 4.618G | 4.433G | 4.313G |
| instructions | 9.473G | 9.493G | 9.281G |
| peak RSS | 296 MB | 272 MB | 274 MB |

| zod3 | a38ff34b7 | f7edd5cb5 | 36422da59 |
|---|---:|---:|---:|
| wall median | 190.2 ms | 183.2 ms | 179.4 ms |
| cycles | 0.776G | 0.745G | 0.728G |
| instructions | 1.708G | 1.731G | 1.678G |
| peak RSS | 89 MB | 87 MB | 86 MB |

- **#733 with #735:** 4.2% faster on ts-pattern (4.0% fewer cycles,
  0.2% more instructions, 8% less peak memory), 3.7% faster on zod3
  (4.0% fewer cycles, 1.4% more instructions).
- **#736:** 2.8% faster on ts-pattern (2.7% fewer cycles, 2.2% fewer
  instructions), 2.1% faster on zod3 (2.2% fewer cycles, 3.1% fewer
  instructions), peak memory within 0.6%. map-builtin.md measured 2.9%
  and 3.6% fewer cycles.
- **Together:** 6.8% faster on ts-pattern (6.6% fewer cycles), 5.7% on
  zod3 (6.1% fewer cycles), and 7.5% and 3.4% less peak memory.
- **PGO on main:** 10.3% faster than the plain build on ts-pattern
  (11.6% fewer instructions), 11.0% on zod3.

## The kernel's part of the gap

`sys.sh`, medians of 10 interleaved rounds:

| | wall | user | system | kernel cycles | page faults | dTLB misses |
|---|---:|---:|---:|---:|---:|---:|
| ts-pattern, Trig PGO | 842.8 ms | 749.8 ms | 87.5 ms | 365M | 40,340 | 2.04M |
| ts-pattern, tsrs | 678.9 ms | 633.4 ms | 44.5 ms | 166M | 17,807 | 0.63M |
| zod3, Trig PGO | 167.2 ms | 142.0 ms | 24.0 ms | 98M | 9,688 | 0.21M |
| zod3, tsrs | 122.3 ms | 107.5 ms | 14.1 ms | 53M | 5,410 | 0.06M |

On ts-pattern the wall gap in these rounds is 164 ms: 116 ms of user
time and 43 ms of system time. A quarter of the gap is the kernel,
mostly page faults: Trig takes 2.3× tsrs's faults and 3.2× its dTLB
misses. The cause shows in the huge pages (`huge.sh`, the sample of
largest Rss):

| | ts-pattern Rss | in huge pages | zod3 Rss | in huge pages |
|---|---:|---:|---:|---:|
| Trig PGO, Rig main | 278 MB | 6 MB (2%) | 87-89 MB | 0 |
| Trig plain, Rig main | 280 MB | 8 MB (3%) | 87-88 MB | 0 |
| Trig plain, f7edd5cb5 | 278 MB | 12-25 MB (4-9%) | 87-88 MB | 0 |
| Trig plain, a38ff34b7 | 303 MB | 6 MB (2%) | 89-92 MB | 0 |
| tsrs shipped | 204-207 MB | 129-131 MB (63%) | 52-55 MB | 27-29 MB (52%) |

tsrs gets most of its heap in 2 MB pages; Trig gets almost none.
Rig's allocator advises huge pages only for a new large block of 16
MiB or more ([alloc-thp16/](../alloc-thp16/README.md)); #725 measured
advising every block of 2 MiB or more and left it out because it raised
Trig's peak memory ([alloc-large/](../alloc-large/README.md)). A table
of plain data (`table.zig`, "Reserved") is mapped with
`MADV_NOHUGEPAGE`, its pages faulted as they are touched.

## Where Trig's user cycles go

ts-pattern, the PGO build, by the innermost frame of each sample
(`groups.txt`; the plain build's in brackets):

| side | group | share of user cycles |
|---|---|---:|
| Trig | the checker (checker.zig) | 38.5% (44.7%) |
| Trig | ast, lexer, parser, binder, the rest | 3.0% (3.9%) |
| Rig | Map/Set: ordered.zig and its hashing | **18.8%** (17.9%) |
| Rig | Table reads and pushes (table.zig) | **11.7%** (11.3%) |
| Rig | List operations (`ListOf` at, push, mem, pop, grow) | **9.1%** (7.0%) |
| Rig | index and range checks (`index`, `indexBelow`, `okBelow`, `offsetIf`, `math.cast`) | 3.9% (3.7%) |
| Rig | other runtime (`lend`, `rt`, niches, drops) | 3.0% (2.8%) |
| Rig | the allocator (alloc.zig) | 3.0% (2.8%) |
| Rig | yield checks (`turn`, `tickCall`'s load of `sched.waiting`) | 2.6% (2.0%) |
| Rig | String and text (std.text, `mem.eqlBytes`) | 2.5% (1.3%) |
| Rig | enum from integer (`std.enums.fromInt`, almost all in `mapper_map`) | 1.1% (0.1%) |
| Rig | memcpy, memset, stack probes | 1.0% (0.9%) |
| Rig | the interner (std.text `Interner`) | 0.4% (0.4%) |
| Rig | sort, prelude, other std | 0.6% (0.8%) |
| | unsymbolized | 0.8% (0.7%) |

**Rig's code takes 57.7% of the PGO build's user cycles, Trig's 41.5%**
(plain: 50.7% and 48.6%). PGO shrinks Trig's own code more than
Rig's. Trig's own code at 41.5% of 3.787G is 1,572M cycles, close to
the 1,466M against tsrs's 1,396M that Trig (fork)'s disassembly diff
found on 2026-10-26.

The top 25 symbols by self share are in `main-pgo.attr`
("innermost function"). The top ten: `Table(Type).constSlot` 2.44%,
`mapper_map` 1.90%, `Ordered(InstantiationKey, u32).findIndexed`
1.77%, `Ordered(CacheKey, u32).findIndexed` 1.59%,
`instantiate_type_with_alias` 1.55%, `Table(Type).at` 1.45%,
`Ordered(CacheKey, u32).matchAll` 1.39%, `ListOf(NodeRec).at` 1.31%,
`mem.eqlBytes` 1.27%, `alloc.alloc` 1.16%.

Inside the groups:

- **Map/Set, 18.8%.** By operation: `findIndexed` 4.95%, `matchAll`
  4.08% (the key compares of a group's tag matches), `entryOf` 1.20%,
  `insertHashed` 0.97%, `findHashed` 0.80%, `writeLane` 0.73%. By map:
  `CacheKey → u32` 5.6%, `InstantiationKey → u32` 4.0%, `u32 → u32`
  2.4%, `CachedTypeKey → u32` 1.5%. The three maps with wide keys take
  11.1%: the lookups of a key built on the stack, which
  perf-stage/table-reads.md found reloaded whole while the probe runs
  (loads blocked by store forwarding, 12.3M against tsrs's 5.6M).
- **Table, 11.7%.** `constSlot` 5.5% and `at` 4.4%; `Table(Type)`
  alone 4.4%. table-reads.md showed a read is one field load and
  0.37 loads of the table's base: these cycles are data latency, the
  dependent load from a type's header to its per-kind record, which is
  Trig's layout. Rig's part is the base reloaded after a store, 1.4% of
  instructions there.
- **List, 9.1%,** and its index checks, 3.9%: `at` 2.4%, `push` 1.9%,
  `memConst` and `mem` 1.9%, `pop` 0.5%, `grow` 0.35%.

## The levers, by measured share

Rig's, on ts-pattern with the PGO build:

1. **Map/Set lookups with wide keys: 11.1% of user cycles** (18.8% for
   all of Map/Set). The probe and key compare of `CacheKey`,
   `InstantiationKey`, and `CachedTypeKey` maps. The stall measured
   before is a key built on the stack and reloaded during the probe;
   a lookup that keeps a small key in registers, or compares it whole,
   aims at it.
2. **Memory: a quarter of the wall gap is the kernel** (43 of 164 ms):
   2.3× the page faults and 3.2× the dTLB misses, with 2-9% of Trig's
   heap in huge pages against 63% of tsrs's. The lever is how the heap
   and the tables get their pages (`alloc.zig`'s 16 MiB threshold,
   `table.zig`'s `MADV_NOHUGEPAGE`), under the bar #725 set: Trig's
   peak memory, already 1.37× tsrs's, may not rise.
3. **List operations and index checks: 13.0%.** Push, read, and the
   bounds and sign tests, which bounds-enum.md and table-reads.md
   counted at one compare each; their count is the gap.
4. **Table reads: 11.7%,** most of it Trig's layout (a lever for
   Trig), about 1.4% of instructions Rig's (base reloads).
5. **Smaller, each under 3.1%:** other runtime 3.0%, the allocator's
   own code 3.0%, yield checks 2.6%, String and text 2.5%, enum from
   integer 1.1% (`std.enums.fromInt`, one function; a dense enum
   needs only a compare), memcpy 1.0%, the interner 0.4%.

Trig's: the checker's own code at 41.5%, near tsrs's by the earlier
diff, and the type-data layout behind the Table reads.
