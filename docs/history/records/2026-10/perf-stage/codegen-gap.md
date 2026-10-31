# How much of Trig's gap to tsrs is Rig's code generation (2026-10-31)

**Question** (queue row 26, for the owner's goal: "find how to make Rig
and Trig use less cycles, perform faster, and consume less memory than
today. We want to match or beat tsrs"). Trig PGO takes 1.18× tsrs's time
on ts-pattern and 1.33× on zod3 ([tsrs-standing-4.md](../hash-race/tsrs-standing-4.md)).
How much of Trig's user-cycle gap is the code Rig emits, as against
Trig's algorithm and data, and what would close it? Measuring and design
only: no compiler change. Scripts, patches and raw output are in
[codegen-gap-data/](codegen-gap-data/).

**Answer.** Most of what Rig's code generation adds is its checks. With
every check gone (`nochk`), Trig PGO takes 5.9% fewer user cycles on
ts-pattern and 6.4% on zod3, and 10.8% and 13.4% fewer instructions:
**54% of ts-pattern's user-cycle gap to tsrs and 31% of zod3's**, and it
then runs fewer instructions than tsrs. Yield checks are 1-3% more
(#806, trig-zig-ceiling). Outside those two, the emitted code is what a
person would write: the hottest functions' samples sit on cache misses
after loads, not on Rig's instructions. The one new cost found is
**store forwarding**: Trig's loads are blocked 13.9M times a ts-pattern
run against tsrs's 6.2M, a third of them by `rig.rt` copies of small
objects written field by field and read whole, and a quarter by Map
inserts copying a 16-byte key. A hand ceiling that takes inline
functions' object parameters without `rig.rt`, with five loop and
inlining edits, is 1.1% fewer user cycles on ts-pattern and 0.2% on
zod3, under Trig's bar. The rest of the user-cycle gap is memory waits
(dTLB walks 3.3× tsrs's: Trig's data, and the huge pages rows 17 and 22
work on) and, on zod3, Trig's parse, bind and module resolution. Declaring Trig's caches `HashMap` makes it 12% larger
and no faster. **Peak memory** (1.22× and 1.44× tsrs): Trig holds less
non-zero data than tsrs at its peak (75% and 71% of it); its excess is
zero bytes, 66-69% of its memory against tsrs's 47-50%, in Table records
that fold Go's rarely set "extra" fields into every id. Rig adds no
padding, tags or headers there.

## Method

- **Builds.** Rig main `179c50afa` (main since then, to `3296a2feb`, changed
  only records, so its emit is main's), Trig `2ba0719`, its `src/` and
  `tools/trig` by `git archive`, `tools/trig/main.rig` as the root. Every
  arm is `rig build --release --pgo` trained by `tools/trig/bolt-train`, as
  Trig ships it, through `slot.sh` on the E-core slots (`mkpgo.sh`); an
  arm that edits the emitted Zig does it through `zigw`, which applies the
  arm's patch to the package Rig has just written, before the first `zig
  build-exe`, so each arm is trained on its own instrumented build
  ([trig-zig-ceiling.md](trig-zig-ceiling.md)'s method).
  - `main`: the PGO build row 21 made of main (`mem-both/packs/main-pgo`,
    sha256 `4828f5d64ba73b86`), by the same recipe.
  - `nochk`: every Rig check's panic unreachable (`indexPanic`,
    `slicePanic`, `lenPanic`, `bytesPanic`, `keepPanic`, `proofPanic`,
    `Table`'s `fullPanic`), built `--release=fast`, so Zig's own overflow
    and cast tests go as well (trig-zig-ceiling's `unchecked-main.patch`,
    which applies unchanged).
  - `tsrs`: shipped 0.18.0, Go mode, one thread, one checker.
- **The second round** was built on #810 (a lent `String` or `List` held
  in a local; branch head `d0af9f62a`, which differs from its merge
  `d6824e180` only in std/crypto), so that each change claims only its
  own gain (`builds2.sh`, `RIG=` in `mkpgo.sh`):
  - `main810`: #810's own PGO build of the same Trig by the same recipe
    (sha256 `13a7cc23a0b54faf`), copied;
  - `hand810`: the hand-written safe ceiling of the hottest code
    (`hand-se.patch` and `rtparam.py`):
    - **se1, se2, se4, se5** from trig-zig-ceiling, which apply unchanged:
      a signed index as one compare; `inference_type_mapper_map` and
      `function_mapper_map` kept out of `mapper_map`, so its frame is
      small; `find_active_mapper`'s List read once with no test per turn;
      `inference_type_mapper_map`'s invariant test hoisted;
    - **n1**, `mapper_map`'s array mapper: its sources read as one slice,
      the range tested once (`n1-mapper-array.patch`);
    - **rt-param**: an inline function's object parameter taken as it
      comes, `const n = __rig_in_n;`, not through `rig.rt` (2,385
      parameters, `rtparam.py`; §1's store-forward finding);
  - `hashmap810`: Trig's lookup-only caches declared `HashMap` instead of
    `Map` (`instantiations`, `relation_results`,
    `active_type_mappers_caches`, `cached_types`, and the eight other
    `CacheKey` caches; 16 lines of Trig in a copy; nothing iterates them),
    to measure the ordered Map's extra indirection on a hit.
  - A first `hand` with `rig.rt` made `inline` for every object (`rt-inline.patch`)
    was dropped: Zig's compile of Trig was still in its first stage after
    50 CPU minutes.
- **Profile** (`prof.sh`). Trig `main` on E-core 18, user cycles sampled
  every 3,000,017 (`cpu_atom/cycles/u`), 30 runs of ts-pattern (37,662
  samples) and 60 of zod3 (13,197), each sample charged to its innermost
  inline frame and to its outermost function (`attr.py`, from
  tsrs-standing), and read instruction by instruction with `hot.py`.
  E-cores are not the P-core the timing uses; shares, not times, are
  taken from them.
- **Timing** (`time-rot.sh`, standing-4's): 20 rounds, every arm once a
  round, the first arm rotated each round, ts-pattern then zod3, on one
  P-core with its sibling idle; user and kernel cycles, instructions,
  peak RSS; every arm's output compared with tsrs's.
- **Memory** (`zeros.py`): each program stopped (`SIGSTOP`) once its RSS
  passed 97% of its peak, and every resident page of its anonymous
  mappings read through `/proc/PID/pagemap` and `/proc/PID/mem`.

## 1. Where Trig's user cycles go

The 60% line is reached by 19 functions on ts-pattern and 34 on zod3, by
the symbol perf names. Under PGO those are large: `instantiate_type_with_alias`
alone is 12,045 instructions with what is inlined into it, and holds
19.2% of ts-pattern's samples. By the innermost inline frame, which says
whose code each sampled instruction is (`cats.py`):

| innermost code | ts-pattern | zod3 |
|---|---:|---:|
| Trig's own functions (checker, binder, parser, AST) | 45.5% | 49.2% |
| Map lookups and inserts (`ordered.zig`) | **19.3%** | 11.7% |
| Table reads and pushes (`table.zig`) | 11.1% | 6.5% |
| List element reads and pushes (`ListOf`) | 6.8% | 8.7% |
| index helpers (`index`, `indexBelow`, `okBelow`, `offset*`) | 5.2% | 5.4% |
| yield checks (`turn`, `tickCall`, the scheduler's flag) | 2.0% | 2.5% |
| allocator (`alloc`, `free`) | 2.6% | 2.3% |
| derived `==` on keys (`eqlAs`) | 1.7% | 0.7% |
| byte compares (`mem.eqlBytes`) | 0.9% | **5.5%** |
| `memcpy`, `memset`, `memmove` | 0.4% | 1.2% |
| enum conversion (`enums.fromInt`) | 0.6% | 0.3% |
| drops, clones, `String` | 0.2% | 0.4% |
| the blocking pool's thread (`sched.zig`) | 0.2% | 0.9% |
| other runtime | 3.6% | 4.8% |

Read instruction by instruction, the samples on Map, Table and List code
sit on the instruction after a load: the tag group's `vmovdqu`, the
entry's compare, a Table field's `mov`. They are those loads' cache
misses, charged by skid to the next instruction, as
[bounds-enum.md](bounds-enum.md) and [table-reads.md](table-reads.md)
found with precise events. The code around them is what a person would
write: a Table read is `mov base; shl; mov field`, a Map hit is a
broadcast, a compare, a `tzcnt`, an index load and a key compare. The
check helpers' samples are mostly the same misses, landing on the
`cmp; jae` that first uses a loaded index.

What the hottest code executes that hand-written Zig or Rust would not:

- **Index and overflow tests.** One `cmp; jae` per List read, `add; jb`
  per checked add, `cmp $0x7ffffff` per Table index from an `Int`. Their
  cost is measured whole by `nochk` (§2).
- **Yield checks.** A `dec; je` per loop turn and a flag load and test at
  the head of every function on the cycle cut (`mapper_map`,
  `get_normalized_type`): 2.0-2.5% of samples.
- **Large frames under PGO.** PGO inlines cold callees into hot
  recursive functions, so each call pays a large frame's prologue: 1,048
  bytes for `instantiate_type_with_alias`, 920 for `mapper_map`, 3,776
  for `structured_type_related_to`; a frame that holds `ymm` values is
  also realigned (`and $-32,%rsp`). Pushes, pops, the frame's `sub` and
  `ret` hold 5.8% of ts-pattern's samples and 4.9% of zod3's; in
  `mapper_map`, whose simple mappers do three loads of work, 17% of its
  samples.
- **Store forwarding.** Trig's loads are blocked by a store they overlap
  13.9M times a ts-pattern run against tsrs's 6.2M (E-core 18,
  `ld_blocks.store_forward`, the same count on two runs). Sampled
  precisely (`:upp`, 21,874 samples, [sfp.attr](codegen-gap-data/sfp.attr)):
  - **34% are `rig.rt` copies of small objects.** Emit passes every
    inline function's parameters and many call results through `rig.rt`,
    a generic identity function; for an object Zig gives it a temporary,
    written field by field and read whole: a `TypeList` or `NodeRef`
    (two `U32`s) stored as two 4-byte stores and loaded as one 8-byte
    load, which cannot forward (`node_id`'s argument in
    `get_type_from_type_node_worker`, 11.5% of all blocks; the
    `TypeList` `new_type_list` returns, in `instantiate_type_with_alias`,
    5.9%);
  - **23% are Map inserts:** `put` and `put_new` hand their key to
    `insertHashed` by value (ordered.zig:835, 866), a 16-byte `vmovdqu`
    of a `CacheKey` the caller wrote as two 8-byte stores;
  - 23% are `mem.eqlBytes` in Trig's path compares
    (`resolve_external_module`, `check_collisions_for_declaration_name`),
    and 4% `memcpy`.
- **Container headers reloaded.** A List's pointer and length, or a
  Table's base, read again from the lent `Checker` each turn:
  `find_active_mapper` reloads `active_mappers`' length and pointer every
  turn (se4); `mapper_map`'s array loop reloads `type_lists`' base after
  each index test, though nothing in the loop stores (loop-hoist.md's
  cause: the test leaves the loop and the load is not known
  dereferenceable). Such loads (55,652 List-header and 14,104
  Table-base load sites) hold 4.1% of ts-pattern's samples and 3.4% of
  zod3's, most of it their own misses (`hdr.py`). #810 holds a lent
  `String` or `List`'s header in a local; it leaves Trig's counts as they
  were (13.9M blocks, 7.95G instructions both before and after), since
  Trig's hot loops read the `Checker`'s containers, not a lent `String`.
- **Optionals with no niche.** An optional of an enum with payloads
  (`T?` of a Zig `union(enum)`) has no niche and writes its whole payload
  for `none`. Trig has two: `TypeComparer?` (a 12-byte union, the
  parameter of `compare_signatures_related_with` and two callees) and
  `CompilerOptionsValue?` (option parsing). No Table, List or Map holds
  one; every hot optional is an object or an id, which has a niche.
- **Not seen:** indirect calls (none in the hot path: 829 in the whole
  binary, a few in each of the top functions), drops and clones (0.2%),
  `String` copies in the hot path, optional unwraps through memory
  (table-reads.md's, gone), padding (Rig's objects are Zig `struct`s,
  which Zig lays out with no padding but alignment's).

## 2. The ceilings, timed

pup, P-core 6 with 7 idle, 20 rounds rotated, 07:37 to 07:40 on
2026-10-31, load 0.1-0.4, free 2 MiB blocks 33-65 (so the huge-page gate
was shut in every run, as in standing-4). Every run of every arm printed
tsrs's bytes. Medians ([summary-1.txt](codegen-gap-data/summary-1.txt)):

| ts-pattern | wall | user cycles | kernel cycles | instructions | peak RSS |
|---|---:|---:|---:|---:|---:|
| main | 758.9 ms | 3.230G | 346M | 7.960G | 246.9 MB |
| nochk | 720.3 ms | 3.041G | 340M | 7.101G | 249.7 MB |
| tsrs | 651.9 ms | 2.880G | 213M | 7.233G | 201.6 MB |

| zod3 | wall | user cycles | kernel cycles | instructions | peak RSS |
|---|---:|---:|---:|---:|---:|
| main | 153.3 ms | 0.608G | 94M | 1.404G | 77.2 MB |
| nochk | 145.7 ms | 0.569G | 95M | 1.216G | 79.3 MB |
| tsrs | 116.2 ms | 0.484G | 53M | 1.210G | 53.8 MB |

- **main against tsrs:** 1.16× the wall time and 1.12× the user cycles
  on ts-pattern; 1.32× and 1.26× on zod3. The user-cycle gap is 350M
  cycles on ts-pattern and 124M on zod3.
- **Checks are 54% of ts-pattern's user-cycle gap and 31% of zod3's.**
  With every check gone, Trig takes 5.9% and 6.4% fewer user cycles,
  10.8% and 13.4% fewer instructions, and 5.1% and 4.9% less time: 189M
  of 350M cycles, 39M of 124M. It then runs fewer instructions than tsrs
  on ts-pattern (7.10G against 7.23G) and as many on zod3, yet 5.6% and
  17.5% more user cycles: what is left of the gap is not instructions
  but waits (misses, TLB walks) and, on zod3, Trig's own extra work
  (parse, bind and module resolution, standing-4's rows 3 and 7). Peak
  RSS is 1.1% and 2.8% higher, the larger `-Ofast` text. trig-zig-ceiling
  found index and slice tests about three fifths of this class, and
  Zig's overflow and cast tests the rest; the split was not timed again.
- Against trig-zig-ceiling's (2026-10-27): the class was 6.5% and 8.3%
  of user cycles then, 5.9% and 6.4% now (#708's one-compare index and
  #761's unchecked runtime landed between).
- **Yield checks** were not built again here: #806's study measured 2.5%
  of Trig's instructions with no loop checks, its time within the Mac's
  noise; trig-zig-ceiling measured 1.4% and 2.9% of plain-build time.

**The second round**, 11:38 to 11:41, every output tsrs's
([summary-2.txt](codegen-gap-data/summary-2.txt)). Builds and Zig tests
ran on the E-cores through it (load 3.7-5; rule 4 allows them), and every
arm, tsrs too, took 13-17% more user cycles than at 07:37, so only the
ratios between arms in these rounds count:

| against `main810` | ts-pattern: user cycles / instructions / wall / peak RSS | zod3: the same |
|---|---|---|
| `hand810` | **1.1% fewer** / 0.6% fewer / 1.1% faster / 1.3% more | 0.2% fewer / 0.4% fewer / 0.3% faster / 3.4% more |
| `hashmap810` | 0.6% more / 2.5% more / 1.3% slower / **12.0% more** | 0.3% more / 0.6% more / 0.5% slower / **11.8% more** |
| `main810` / tsrs | 1.20× / 1.10× / 1.25× / 1.22× | 1.30× / 1.16× / 1.35× / 1.44× |

- **The hand ceiling is 1.1% and 0.2%**, under Trig's bar, as
  trig-zig-ceiling's safe edits were. Its store-forward part took 1.27M
  of the 13.9M blocks (9% fewer, E-core 19, three runs each): the
  parameters were the larger half of the `rig.rt` blocks; the call
  results (`rig.rt(self.new_type_list(...))`) and Map inserts were left
  ([sfh.attr](codegen-gap-data/sfh.attr)). Its peak RSS is higher by the
  same 1-3% as `nochk`'s, the larger text.
- **HashMap does not pay for Trig's caches.** Its hit makes two
  dependent loads where the ordered Map makes three, but its slots keep
  a 16-byte key's hash and fill to at most 0.875, so the caches take 12%
  more peak memory, 2.5% more instructions, and 9% more kernel cycles for
  their faults; the dTLB walks fall 10% and the time is no better. The
  ordered Map's layout is not what separates Trig from tsrs.

## 3. Peak memory

Each program stopped at 97% of its peak RSS, its anonymous memory read
page by page ([zeros-*.txt](codegen-gap-data/)):

| at the peak | Trig ts-pattern | tsrs ts-pattern | Trig zod3 | tsrs zod3 |
|---|---:|---:|---:|---:|
| RSS when stopped | 242.2 MiB | 195.7 MiB | 76.1 MiB | 52.8 MiB |
| anonymous memory present | 217.5 MiB | 187.6 MiB | 51.8 MiB | 44.5 MiB |
| of it Tables (Trig), the arena (tsrs) | 120.6 MiB | 123.5 MiB | 21.2 MiB | 28.0 MiB |
| of it the allocator's region (Trig), the heap (tsrs) | 39.0 MiB | 63.2 MiB | 17.9 MiB | 15.5 MiB |
| of it blocks mapped alone (Trig's large Lists) | 57.9 MiB | 0.9 MiB | 12.7 MiB | 1.0 MiB |
| bytes that are zero | **65.6%** | 46.8% | **69.3%** | 49.8% |
| bytes that are not zero | **74.8 MiB** | 99.8 MiB | **15.9 MiB** | 22.3 MiB |
| pages wholly zero | 5.3 MiB | 0.2 MiB | 4.0 MiB | 1.9 MiB |

Trig holds less information than tsrs at its peak (75% of tsrs's non-zero
bytes on ts-pattern, 71% on zod3) and more memory, all of the excess
zeros: 143 MiB against 88 on ts-pattern. Few pages are wholly zero, so
the prefaulting ahead of a Table's writes does not explain it; the zeros
sit inside records Trig has written. By Table (the reservations laid out
from the store's declaration order and each record's size; ts-pattern):

| Table | record | resident | zero bytes |
|---|---:|---:|---:|
| `value_symbol_links` | 24 B | 20.8 MiB | 76.5% |
| `mappers` | 16 B | 17.1 MiB | 58% |
| `structured` | 44 B | 15.3 MiB | **87%** |
| `types` | 32 B | 15.1 MiB | 73% |
| `type_lists` | 4 B | 12.5 MiB | 45% |
| `syms` | 12 B | 10.2 MiB | 51% |
| `signatures` (with its neighbours) | 64 B | 8.1 MiB | 73% |
| `sym_lists` | 4 B | 5.1 MiB | 27% |
| `union_or_intersections` | 52 B | 4.6 MiB | 89% |

These are Trig's records, laid out as Rig's objects are: Zig `struct`s of
`U32` fields with no padding. The zeros are fields a record rarely sets.
Go keeps those apart and allocates them when a symbol or signature needs
them (`valueSymbolExtra`, `signatureExtra`, the structured members a
plain object type never resolves); Trig folds them into one record per
id, so every record carries them. A `U32` zero field in a Table costs
what a Go pointer's `nil` does only where Go also keeps the field; where
Go keeps a separate extra, Trig pays for it on every id. That is Trig's
layout (below). Rig adds nothing here that a hand-written Zig port of the
same records would not: no padding, no tags (`?T` uses a niche), no
headers on Table records. The one Rig-side memory item is the allocator's
own (row 21).

The 57.9 MiB outside the Tables and the allocator's region on
ts-pattern are blocks too large for its segments, mapped one by one
(1-16 MiB each, which by size are Lists grown by doubling and moved by
`mremap`; not traced to their owners), with zero shares of 7-84%. tsrs
has almost no memory outside its arena and heap.

## 4. The changes, ranked

By measured or bounded gain per line of compiler or std change; "general"
helps every Rig program with the pattern, "Trig" only Trig.

| # | change | pass that owns it | gain on Trig | lines | reach |
|---|---|---|---|---|---|
| 1 | **Object values not through `rig.rt`**: bind an inline function's object parameters directly (`const n = __rig_in_n`) and return an inlined call's object result in place; keep `rt` for scalars, where it makes a constant's arithmetic checked at run time | emit (`emit.zig`, where it binds inline parameters and wraps call results) | measured with the hand edits: 1.1% fewer user cycles on ts-pattern, 0.2% on zod3, 9% fewer store-forward blocks; the call results left would about double the blocks removed (34% of all are `rt` copies) | ~10 | general: every program whose inline functions take or return small objects |
| 2 | **Map inserts take the key by address**: `put`, `put_new`, `replace` hand `&kk` to `insertHashed`, which copies the words it stores | std (`src/ordered.zig`, and `unordered.zig`'s same shape) | not timed; 23% of Trig's store-forward blocks | ~8 | general: every wide-key Map insert |
| 3 | **Checks a fact proves**: the loops of se4, se5 and n1 (a countdown from a length, an invariant test, a range read once), and a signed index as one compare (se1) | proofs (`src/proofs.zig`, with the ownership checker's no-write fact), emit | inside the hand ceiling (above); trig-zig-ceiling measured these 0.6% of instructions and nothing in time | 100+ | general |
| 4 | **The rest of the checks**: id lookups no proof reaches | language (index types: `Slot`, `Table`), then Trig moving its ids onto them | up to 5.9% and 6.4% of user cycles (`nochk`), the largest class; reachable share unknown (checks.md: most are ids read from memory) | large | general, then Trig |
| 5 | **Yield checks** | emit, runtime | 1-3% (#806, trig-zig-ceiling); #806 keeps the per-loop count for timers' sake | — | general |
| 6 | **Small frames for hot recursive functions** under PGO (se2: cold callees kept out of `mapper_map`) | inlining (`src/inlining.zig`) | inside the hand ceiling; prologues and epilogues are 5.8% of ts-pattern's samples, mostly not removable | ~20 | general |
| 7 | **Headers held across a loop** (#810's for lent Strings and Lists; `noalias` lends, row 28) | emit, storage | none on Trig: #810 left its counts unchanged; loop-hoist.md found `noalias` worth nothing here | — | general |
| 8 | **A niche for an optional of an enum with payloads** (a spare tag value; `nicheOf` has no `.union` case) | storage and emit | none on Trig (two such optionals, neither hot or stored) | ~30 | general (sanstun's `Event?`) |

Not changes: the ordered Map's extra indirection (HashMap is worse for
Trig, §2); drops, clones, `String` copies and indirect calls, absent from
the hot path; object padding, which Zig's layout already removes.

Rows 1 and 2 are the clear wins by gain per line, and both are general.
Neither clears Trig's bar alone on this evidence; row 1 complete (call
results too) and row 2 together are the candidates to build and time as
one change.

## 5. The checks, by kind

What the checks' 5.9% and 6.4% are made of, and how much of each the
proofs pass could take without a language change. Every conditional jump
in Trig PGO (#810's build) whose target reaches a panic within a few
instructions is a check, of the kind its panic names (`chk.py`: Rig's
`indexPanic`, `slicePanic` and the like are bounds; Zig's
`integerOverflow` overflow, `integerOutOfBounds` a cast, `unwrapNull` an
optional, `invalidEnumValue` and `corruptSwitch` a tag). Retired
instructions were sampled precisely on E-core 19 (`instructions/upp`,
23,858 samples on ts-pattern, 55,853 on zod3), and each check counted as
its jump and the instruction before it, which sets its flags. 137,795
check sites in the binary.

| kind | sites | ts-pattern | zod3 |
|---|---:|---:|---:|
| bounds (List, slice, Table index) | 77,477 | **6.10%** | **7.33%** |
| integer overflow | 28,722 | 1.94% | 1.90% |
| casts (`@intCast` range) | 25,449 | 0.49% | 0.84% |
| tags (enum value, switch) | 2,314 | 0.12% | 0.36% |
| a Table full | 1,086 | 0.19% | 0.18% |
| optionals (`.?`), errors | 323 | 0.00% | 0.00% |
| all checks | 137,795 | 9.32% | 10.74% |

Shares of retired instructions; `nochk` removed 10.8% and 13.4%. Bounds
are two thirds of the checks; optionals cost nothing, since Rig unwraps
by test, not by `.?`. (`mapper_kind`'s `enumFromInt(...) orelse
.Unknown`, 0.43% on ts-pattern, is Trig's code, not a check.)

Each check line, by what its index or operand is (`chkclass.py`, every
line with samples; [checks-lines-ts-pattern.txt](codegen-gap-data/checks-lines-ts-pattern.txt)):

| class | ts-pattern | zod3 | what removes it |
|---|---:|---:|---|
| bounds: an index read from memory (`sym_loc.at(s)`, `recs.at(n.id)`, `bindings[f].symbols[local_sym(s)]`, `syms.atInt(checker_symbol(s))`, `node_base.at(file - 1)`) | **3.10%** | **4.69%** | an index type (`Slot`, `Table`) and Trig's ids on it: a language change |
| bounds: a Table read at a list's start plus `k` (`type_at`, `sym_at`) | 0.99% | 0.40% | a span type (`Span[n]`, built and closed in #686): a language or std change |
| bounds: a countdown or loop index over the same List, or the side a proven test left (`find_active_mapper`, `sort`'s `j - 1`, `atProven`) | 0.72% | 0.39% | the proofs pass, with the no-write fact (se4) |
| bounds: the rest | 0.90% | 1.57% | not classed |
| overflow: an `Int` or a length stepped by a small constant (`instantiation_count += 1`, a Set's `len += 1`, `steps += 1`) | 0.64% | 0.46% | a rule the owner would decide: a counter stepped by a constant cannot reach 2^63 in a run |
| overflow: an id sum or difference Trig keeps in range (`node_base[f - 1] + id`, `(t - binder_tabs) - 1`) | 0.43% | 0.61% | Trig (a `node_base` with a slot at 0), or range facts no proof reaches |
| overflow: the rest | 0.80% | 0.74% | not classed |
| casts: a Table's length to `U32`, below its `n` | 0.07% | 0.02% | the proofs pass (the Table's `n` is a type fact) |
| casts: the rest (a slice's or List's length to `U32`) | 0.38% | 0.80% | range facts no proof reaches |

**So the proofs pass reaches little:** about 0.8% and 0.4% of
instructions (9% and 4% of the checks), 0.4% and 0.2% of user cycles at
`nochk`'s ratio of cycles to instructions. **An index type reaches the
most:** ids read from memory are a third of ts-pattern's check
instructions and 44% of zod3's (about 1.7% and 2.2% of user cycles at that
ratio), and the span reads add 0.99% and 0.40% of instructions. A
counter rule would take 0.64% and 0.46% more, with no syntax change but
an owner's decision. Item 4 of §4 is the one worth taking to the owner
as a language change.

Limits: E-core samples (Crestmont), shares of instructions, not cycles;
the classes come from the emitted Zig's text by pattern, and the
unclassed rows (1.7% and 2.3% of instructions) were not read.

## Trig-side findings

For Trig, which owns its algorithm and data:

- **Records with Go's extras folded in.** `value_symbol_links` (24
  bytes, three of its six fields Go's `valueSymbolExtra`), `signatures`
  (64 bytes, five fields `signatureExtra`), `structured` (44 bytes, 87%
  zero), `union_or_intersections` (52 bytes, 89% zero): a side Table for
  the rarely set fields, indexed from the record, would take most of the
  81 MiB of zeros in ts-pattern's Tables. This is where Trig's peak
  memory exceeds tsrs's.
- **Path compares.** `mem.eqlBytes` under `resolve_external_module`,
  `check_collisions_for_declaration_name` and the module-format lookups
  is 5.5% of zod3's user cycles and 23% of Trig's store-forward blocks
  (standing-4's row 7).
- **Keep `Map` for the caches.** `HashMap` costs 12% more peak memory
  and no time (§2).
- trig-zig-ceiling's findings stand: `find_active_mapper`'s search from
  the top on every instantiation, `node_base[f - 1]`'s sign test, the
  store's list builders one item at a time.

## Left out

- Per-function gains: the hand edits were timed together, since each
  PGO build takes about an hour; their E-core profiles, which share a cluster's L2 with
  the builds, differed by up to 8% in total cycles, too much to split them.
- The precise sampling, profiles and memory reads ran on E-cores
  (Crestmont), the timing on a P-core (Redwood Cove); the store-forward
  counts are E-core counts.
- Kernel time (standing-4's 25-31% of the gap) is rows 17, 20, 21 and 22's.
