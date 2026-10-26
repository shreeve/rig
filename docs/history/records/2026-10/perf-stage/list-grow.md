# List growth on Trig (2026-10-25)

Trig's breakdown of its gap to tsrs (ts-pattern, one checker, Trig
`676760a` on Rig `6c3f35b78`) put "List push, grow and copy" at 319M
cycles against tsrs's 48M, and 579M instructions against 58M. This
record says where that goes, what was built and measured (#697,
closed; the code stays on branch `list-grow`), and what is left for
Trig.

Scripts and data are in [list-grow-data/](list-grow-data/): `abk.sh`
(the interleaved timing), `build.sh` (Rig, then Trig release, on pup's
slots), `fam.py` (runtime lines by the runtime function they are in),
`listprof.patch` and `sym.sh` (the counting build and its symbolizer),
`sites.txt` (the sites, symbolized), `bench.sh`, `jsonab.sh` and
`sum.py` (bench/hash and std.json) with their logs.

## Where the 319M goes

Profile: Trig's release build on Rig main, ts-pattern
`--singleThreaded` on pup core 8, 40 runs at perf's 1 kHz cap (about
48K samples per event), each runtime line put under the runtime
function it is in (`fam.py`). Shares of the whole run:

| Part of the "List" family | cycles | instructions | what it is |
|---|---:|---:|---|
| `push`'s lines, inlined into its callers | 2.34% | 3.32% | the compare, store and length write of each push |
| `mem` / `memConst` lines, inlined | 0.89% | 1.47% | loads of a List's buffer by `at`, `slot`, `items` |
| `copiedOut`, inlined | 0.47% | 0.91% | `a ?? b` copying a value out (0.74% of the instructions in `get_property_of_type_ex`); not a List |
| `compiler_rt` memcpy | 0.92% | 0.90% | every copy Zig makes a call of; growth is part |
| `compiler_rt` memset | 0.18% | 0.01% | `List.filled` (the Map's tag and index tables) and Table growth; List growth writes no zeros |
| `grow` (all element types) | 0.56% | 0.79% | the out-of-line growth |
| `reallocSlice`, `resize`, `remap` | 0.58% | 0.87% | the allocator calls a growth makes |
| `clear`, `pop`, `__rig_drop` | 0.71% | 0.88% | |

About 3.7% of the cycles (push, buffer loads, `copiedOut`) is code
inlined into Trig's checker functions. tsrs's breakdown counts its own
inlined `Vec::push` and slice loads under its checker functions, so
the 48M it shows is its memmove and `RawVec` symbols alone; the 6.6×
compares Trig's inlined code plus its calls with tsrs's calls only.

The four questions:

1. **Growth policy:** a List doubles from 4 (`@max(want, 4, 2 *
   len)`), as `Vec` does from 4 for elements up to 1 KiB, and grows by
   `reallocSlice`, which asks the allocator to keep the block in place
   before it moves it. A small block (up to 32 KiB) keeps its place
   only within its size class, and the classes are powers of two and
   four steps between, so a doubling List of 4-, 8-, 12-, 16- or
   24-byte elements always lands on a class exactly and never stays: as
   with `Vec` on mimalloc, each small growth is an allocation, a copy
   and a free. A block of 1 MiB or more grows by `mremap`.
2. **Element copies:** a growth copies the old buffer with one
   `@memcpy`, never element by element. `List.clone` of plain elements
   pushes them one by one; a `@memcpy` there was built (`v3` below) and
   measured slower, since most clones Trig makes hold one to three
   elements and a call to `compiler_rt`'s memcpy costs more than three
   stores.
3. **Per-push overhead:** none beyond `Vec`'s. `push` is inlined:
   compare the length with the buffer's, call `grow` (out of line) if
   equal, store, write the length. The List is `{buf, len}` inside its
   owner, with no header to reach through, and a push makes no yield
   check. A List local to a loop keeps its length in a register.
4. **Lists made and dropped:** a counting build (`listprof.patch`)
   counted, over one ts-pattern check:
   - 4.06M growths: **3.22M first buffers** and 0.84M regrowths, which
     copied 250 MB (an upper bound; blocks of 1 MiB or more move by
     `mremap`);
   - 3.46M Lists dropped holding a buffer, of which 288K hold no
     element, 1.32M one, 1.25M two or three, 238K four to seven: 83%
     hold three or fewer, and 83% have the first capacity, 4.

   So the cost is the number of short-lived Lists: each first buffer
   is a `grow`, an `alloc` (22 instructions) and later a `free` (27).

## What was built

Four builds of Rig main `b77ffb199`, Trig `676760a` built release by
each (`build.sh`):

- **v1:** `grow` takes a List's first buffer from `allocSlice`, not
  through `reallocSlice`.
- **v2:** v1, and `reallocSlice` judges inline whether a small block
  keeps its place (`alloc.smallInPlace`), calling `remap` only for two
  large blocks: item 2 of [alloc-fast](../alloc-fast/), which saved
  0.35% alone.
- **v3:** v2, and `List.clone` copies plain elements with one
  `@memcpy`.
- **v4:** v2, and a push's first buffer is four slots, a size known
  at compile time in `grow`, so `allocSlice`'s size checks fold away.
- **v5 (#697):** v4, and `push` is `inline`: LLVM had left it a call
  in std.json's parser (`ListOf(i64,0).push`, 4 to 6% of the parse),
  and in a few places in Trig.

## Trig on pup

`abk.sh`: `trig -p tsconfig.trig.json --noEmit --singleThreaded`, core
8 (9 idle), builds interleaved with the order reversed every other
round, fastest task-clock, fewest user cycles and instructions of 10,
median page faults, fewest kernel cycles. Outputs byte-identical to
base in every set. Pup ran other sessions' release builds on its slots
(load about 3).

ts-pattern, instructions (M):

| set | base | v1 | v2 | v3 | v4 |
|---|---:|---:|---:|---:|---:|
| 1 | 10,542.6 | 10,518.7 | | | |
| 2 | 10,543.1 | 10,512.9 | 10,457.0 | | |
| 3 | 10,544.2 | | 10,455.7 | 10,477.3 | |
| 4 | 10,546.8 | | 10,455.6 | | 10,424.7 |
| 5 | 10,543.9 | | | | 10,425.2 |

v4 runs 1.13 to 1.16% fewer instructions than base; v3's `@memcpy`
clone runs 22M more than v2.

The last two sets in full:

| project | build | task-clock | user cycles | instructions | kernel cycles | page faults |
|---|---|---:|---:|---:|---:|---:|
| ts-pattern (4) | base | 1,217.4 ms | 4,855.4M | 10,546.8M | 417.7M | 42,681 |
| | v2 | 1,201.4 ms | 4,838.1M | 10,455.6M | 402.5M | 42,681 |
| | v4 | 1,193.1 ms | 4,792.0M | 10,424.7M | 402.3M | 42,682 |
| ts-pattern (5) | base | 1,266.2 ms | 4,953.5M | 10,543.9M | 418.2M | 42,682 |
| | v4 | 1,243.4 ms | 4,949.9M | 10,425.2M | 424.3M | 42,682 |
| zod3 | base | 232.8 ms | 859.9M | 1,908.4M | 103.3M | 9,148 |
| | v4 | 231.1 ms | 864.5M | 1,895.5M | 103.6M | 9,151 |

v4: ts-pattern 1.1% fewer instructions, zod3 0.7%; time 0.7 to 2.0%
faster and user cycles 0.1 to 1.3% fewer on ts-pattern, within the
run-to-run spread; page faults and kernel cycles unchanged, since a
large block grows as before.

v5, in a sixth set at load 4 to 6 (too loaded for its times): ts-pattern
10,544.5M, 10,421.0M and 10,416.7M instructions for base, v4 and v5;
zod3 1,911.7M, 1,891.8M and 1,892.2M. Inlining `push` everywhere moves
Trig's instructions by less than 0.05% and makes its binary 2% larger
(104.1 MB against 102.0 MB).

## Page faults

Trig (fork) found 24% of ts-pattern's page faults at `push`'s store,
first writing freshly grown memory, mostly large blocks, and 1.5 to
7.6% more in growth's memcpy. v4 changes neither: a small block's
growth already moves to a new block (v4 only skips asking), and a large
one is grown as before (`remap`: in place within its bucket, `mremap`
from 1 MiB, otherwise a new block from the heap's kept large blocks
or the system). The faults are the first write of each new page, as a
`Vec` would take; Trig is moving its append-only arenas to Tables. The
memset is not List growth: List growth writes no zeros, and the
copy is of the old buffer, which a push's growth has full.

## Benchmarks

**std.json, instructions** (pup, each `prog 2000` or `prog 1000` under
perf stat): v4 runs exactly what base runs, within 2K instructions of
billions, in every program, since its parse loop never grows a List
and std.json's code is unchanged. v5 against base:

| file | rig-safe | rig-fast |
|---|---:|---:|
| twitter | 4.2% fewer | 4.5% fewer |
| twitterescaped | 3.9% fewer | 4.2% fewer |
| canada | 0.6% fewer | 2.6% more |
| citm_catalog | 2.8% fewer | 4.1% fewer |
| gsoc-2018 | 2.4% fewer | 2.0% fewer |
| github_events | 3.7% fewer | 3.8% fewer |

**std.json, time on the Mac** (`tools/low`, load 2.5 to 4, builds
interleaved, MB/s best of 9 rounds of 5; `json-mac-3.log`):

| file | base | v4 | v5 | v4 vs base | v5 vs base |
|---|---:|---:|---:|---|---|
| twitter | 3628 / 3701 | 3644 / 3681 | 3736 / 3785 | 0.4% faster / 0.5% slower | 3.0% / 2.3% faster |
| twitterescaped | 3245 / 3273 | 3237 / 3261 | 3273 / 3302 | 0.2% / 0.4% slower | 0.9% / 0.9% faster |
| canada | 2083 / 2232 | 2090 / 2221 | 2089 / 2240 | 0.3% faster / 0.5% slower | 0.3% / 0.4% faster |
| citm_catalog | 4339 / 4360 | 4385 / 4322 | 4401 / 4541 | 1.1% faster / 0.9% slower | 1.4% / 4.2% faster |
| gsoc-2018 | 8515 / 8297 | 8442 / 8301 | 8547 / 8329 | 0.9% slower / same | 0.4% / 0.4% faster |
| github_events | 4313 / 4299 | 4277 / 4308 | 4413 / 4323 | 0.8% slower / 0.2% faster | 2.3% / 0.6% faster |

(rig-safe / rig-fast.) Two earlier sets of v4 alone (`bench-mac-1.log`,
`json-mac-2.log`) read it 0.1 to 1.6% slower on most files, with the
same instructions as base: placement, not work.

**std.json, time on pup** (`jsonab.sh`: each program, `prog 300`,
interleaved on core 8, fastest task-clock and fewest user cycles;
`json-pup.txt`). Pup ran other sessions' builds throughout (load 2 to
4), and sets 1 and 2 (base and v4) and 4 (all three) are the readable
ones. In time, v4 against base read twitterescaped rig-safe 3.4%,
4.3% and 5.0% slower in the three sets and the rest within 2.7%: the
same instructions, with the parser's functions moved by 0x120 bytes
(`json.Doc.document` from 16 to 48 bytes past a 64-byte line). v5 in
set 4: twitter 0.2% / 4.4% faster, twitterescaped 2.1% / 3.0% faster,
citm_catalog 2.9% / 4.5% faster, github_events 7.4% / 1.4% faster,
canada 2.3% slower / 0.3% slower, gsoc-2018 0.5% / 0.3% slower. A
focused set of 25 rounds of canada and gsoc-2018 read v5 against
base: canada 0.4% slower / 2.6% faster, gsoc-2018 1.5% / 1.3% slower
(v4 1.4% / 1.8% slower), the gsoc-2018 parse running 2% fewer
instructions.

**bench/hash** runs 0.6% (rig-safe) and 0.8% (rig-fast) more
instructions with v4 or v5, every run the same: the program's setup,
which formats its million String keys (`String.addValueOf`, whose
inlining of the writer's `alignBufferOptions` changes with
`reallocSlice`'s size), not its timed Map operations. Times, best of 6
interleaved rounds on the Mac (`bench-mac-1.log`), move both ways by up
to 5% on the int and pair rows and 13% on the string rows from run to
run; pup's rounds (load 4 to 6) were unreadable.

## What is left for Trig

The sites that make the most first buffers (`sites.txt`, function and
line in the generated Zig; counts over one ts-pattern check):

| site | first buffers | note |
|---|---:|---|
| `context_inferences` (from `inference_type_mapper_map` / `mapper_map`) | 326K | clones a stored `List[U32]` to read it; dropped at length 2. A view would make none |
| `table_entries` | 120K (296K growths) | regrows; 19 MB copied |
| `Map(u32, ThisAssignmentDeclarationKind)` entries (`add_entry`) | 117K (235K growths) | one small Map made per call |
| `type_list_items` (from `create_union_or_intersection_property`, `instantiate_type_worker`, `create_type_reference_ex`, `get_intersection_type`, `get_type_with_this_argument`, `some_property_reduces_to_never`) | 113K + 79K + 62K + 31K + 27K + 23K | |
| `add_mapped_members_for_key_type` | 97K | |
| `type_parameter_contains_reference` closure | 92K | dropped at length 1 |
| `infer_types` | 82K, and four Lists of 69K each | dropped at length 0 or 1 |
| `invoke_once` | 2 × 69K | |
| `Map(InferenceKey, i32)` entries | 69K | |
| `get_type_from_inference` | 69K | |
| `get_cross_product_intersections` | 68K | |
| `new_inference_context` (from `get_conditional_type`) | 68K | |
| `sort_symbols_by_key` | 65K (173K growths) | 23 MB copied; could size its List first |
| `context_inferences` (from `get_conditional_type`) | 62K | |
| `add_declaration` (from `add_mapped_member_for_key_type`) | 60K | |
| `get_named_members` | 4 sites, 26K to 60K each, 2 to 3 growths per List | could size its Lists first |
| `get_resolved_base_constraint` | 52K + 29K | |

Each first buffer is about 75 instructions (grow, alloc, free) with
its pushes on top: the 3.22M are about 240M instructions, 2.3% of the
run. A List that holds four or fewer, `List[T, inline: 4]`, a scratch
List reused across calls, or a view where a clone is only read, makes
none.

## On main after #696 (2026-10-26)

Rebased onto `91802aaf5` (#696: `copiedOut` inline, optional results
bound in place). Pup with no release build running, load 1 to 1.5,
core 8 (9 idle), interleaved, fastest of 10:

| project | build | task-clock | user cycles | instructions | page faults |
|---|---|---:|---:|---:|---:|
| ts-pattern | main | 1,047.2 ms | 4,511.1M | 10,097.1M | 42,681 |
| | branch | 1,049.1 ms | 4,516.4M | 10,001.8M | 42,682 |
| zod3 | main | 195.2 ms | 824.0M | 1,826.7M | 9,148 |
| | branch | 191.5 ms | 807.7M | 1,816.9M | 9,148 |

On top of #696 the branch saves 0.94% of ts-pattern's instructions
(0.95% in a second count, 10,101.1M to 10,004.4M) and 0.54% of zod3's,
under the 1% bar; times are the same.

std.json, the same conditions, 25 rounds for the four cases that read
slower in 10 (`jsonab2.sh`), against main: twitter, twitterescaped,
citm_catalog and github_events rig-fast 1.3 to 3.7% faster; canada
rig-fast 1.3% faster; gsoc-2018 rig-safe 1.2% faster, github_events
rig-safe 3.7% faster; **gsoc-2018 rig-fast 1.0% slower** (cycles 1.7%
more, instructions 2.05% fewer) and **canada rig-safe 2.0% slower**
(cycles 2.4% more, instructions 0.14% more). The Mac at load 1.7 to 2.6
reads the branch faster on all 12 (0.2 to 7.7%, `json-mac-4`).

Each loser has one cause, found by building the two commits apart
(`g2`, the growth change alone; `p2`, the inlined `push` alone):

| case | g2 | p2 |
|---|---|---|
| gsoc-2018 rig-fast | 1.6% slower, cycles 2.5% more, same instructions | 0.4% slower |
| canada rig-safe | same | 2.3% slower, cycles 2.3% more |

gsoc-2018's is placement: the growth change alone runs the same
instructions and moves the parser's functions. canada's is the inlined
`push`: `json.Doc.document` grows from 0x1dbe to 0x1e9b bytes and its
number loop is scheduled differently. A cold hint on `push`'s growth
branch (`@branchHint(.cold)`), inlined or not, changes no instruction.

## Verdict

Closed (#697, 2026-10-26). On top of #696 the change saves 0.94% of
ts-pattern's instructions, under the 1% bar, with no time it moves, and
std.json, which is never to be slower, has two programs slower on an
exclusive pup: gsoc-2018 rig-fast by placement and canada rig-safe by
the inlined `push`. v1 to v3 were not kept either. What stands is the
finding: Rig's List already grows as Rust's `Vec` does, and the cost
Trig's breakdown charged to it is inlined push and load code plus the
3.22M short-lived Lists of the sites above, which are Trig's to remove.
