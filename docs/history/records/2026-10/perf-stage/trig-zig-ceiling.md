# The speed ceiling of Trig's emitted Zig (2026-10-27)

**Question.** The owner's method, 2026-10-27: "if we have a super quick
Zig version (step 1) then we should spend all our energy trying to
match that in Rig (step 2). So that we have a clear line to getting the
optimization to Rig code." Then: "And Trig". This is step 1 for Trig:
take the Zig that Rig emits for Trig, tune its hottest functions by hand
into the fastest Zig that keeps Rig's checks (the **safe ceiling**), and
the same with the checks removed (the **unchecked ceiling**). Measure
both against main and tsrs, and list what Rig's compiler would have to
emit to reach them, ranked by measured gain.

**Answer.** Rig's emitted Zig for Trig's hottest functions is already within
about 1% of the fastest safe Zig these hand edits reach without changing
Trig's algorithm or data layout. Six hand edits made the plain build
0.6% faster on ts-pattern and 2.1% on zod3, with 1.2% and 0.6% fewer
instructions. Built with PGO, as Trig ships, they are within the noise
(0.5% slower and 0.4% faster). What separates Rig's code from its
ceiling is its checks. With every check removed, Trig PGO is 5.5% faster
on ts-pattern and 7.5% on zod3, with 13-15% fewer instructions. That
takes it from 1.21× tsrs to 1.14× on ts-pattern, and from 1.34× to
1.24× on zod3. Index tests are about three fifths of it: 4.2% and 5.6%
on the plain build. Yield checks are worth 1.4% and 2.9%. The rest of the
distance to tsrs is outside the emitted Zig: the wide-key maps, page
faults and huge pages (tsrs-standing.md), and Trig's data layout. Of the
six edits, partial inlining of `instantiate_type` made Trig 0.9% slower.
Trig's list builders, done in bulk, made it 0.4-1.1% faster with 1-2%
less peak memory: that one is for Trig.

Measurement and hand edits only; no compiler change. The scripts, the
hand-edited Zig as patches against the emitted package, and the raw
output are in [trig-zig-ceiling-data/](trig-zig-ceiling-data/).

## Method

- **Sources.** Rig main `099c1bff3` (#738). Main moved to `7c2365522`
  (#741, an ownership rule for generic bodies, emit unaffected) during the
  job; every number here is for `099c1bff3`. Trig main `403a823`, its
  `src/` and `tools/trig` taken by `git archive` from pup's full checkout,
  `tools/trig/main.rig` as the root, as tsrs-standing.md built it.
  Main later moved to `4d80efe17` (#740, huge pages) and `4d3fe513f`
  (#744, #746); the baseline stays `099c1bff3` throughout, so #740's
  huge pages are in none of these numbers.
- **The package.** `rig build --release` with `RIG_OUT_DIR` and a
  stand-in `ZIG` that only records its arguments writes the emitted
  package (49 files, 19 MB) and stops (`emit.sh`). The same package came
  out on the Mac and on pup, byte for byte. It is kept under git
  (the first commit is the package as emitted), and each hand edit is one
  commit. `mk.sh` compiles a package as `rig build --release` does,
  `zig build-exe -Osafe -fomit-frame-pointer` on `__rig_main.zig`
  (`-Ofast` for the unchecked variants), through
  `/zfs/trig-pup/trial/slot.sh` on slot 10,11. One build takes 12 to 18
  minutes. `bin/rig` was copied from a clean build of `099c1bff3` already
  on pup (`alloc-seg-thp/rig-main`), not built again.
- **PGO.** `mkpgo.sh` runs `rig build --release --pgo` as Trig's
  shipped build does (trained by `tools/trig/bolt-train`) with `ZIG` set
  to `zigw`, which applies a variant's patch to the package Rig has just
  written before the first `zig build-exe` reads it. So each PGO variant
  is trained on its own instrumented build.
- **Timing** (`time.sh`, `summ.py`). pup, `taskset -c 8` with sibling 9
  idle; the variants and shipped tsrs (Go mode, one thread, as
  tsrs-standing.md ran it) interleaved in each round, ts-pattern then
  zod3, one checker. Wall time is perf's `duration_time`, cycles and
  instructions `cpu_core/*/u`, peak RSS `/usr/bin/time`'s. A round waits
  while Trig's full suite runs or another process uses core 8. The
  final 20 rounds ran from 04:33 to 04:38 on 2026-10-28, with Rig -
  Merges building on slot 0,5 and timing one checker on core 6, load
  average 0.8. The PGO builds shared slot 10,11 with other jobs and took
  41 to 75 minutes each. Every
  variant's output was compared with main's in every round.
- **Profile** (`prof.sh`, `hot.py`). 20 runs of the plain main build,
  user cycles every 4,000,037 (18,061 samples), attributed by the
  innermost inline frame (tsrs-standing.md's `attr.py`), and `hot.py`,
  which prints a function's disassembly with each instruction's samples
  and inline frame.

## What the hottest code executes

The plain build's profile (`main-rel.attr`) matches tsrs-standing.md's:
flat, its top function 2.55% (`mapper_map`). Read instruction by
instruction (`hot.py`), the hottest functions' Zig is already close to
what a person would write:

- **`mapper_map`** (5.2% with what is inlined into it): the samples sit
  on the load of the mapper's record (`mov 0x4(%rcx,%rax,1)`, a cache
  miss, and the instruction after it), the kind's dispatch, and the
  prologue. The kind's conversion (`std.enums.fromInt`) is one compare
  merged with the `match`'s, as bounds-enum.md found. The `Array` and
  `Deferred` loops, which a hoist would help, hold no samples.
- **`instantiate_type_with_alias`** and **`could_contain_type_variables`**:
  the load of the type's flags (a miss) and the test after it.
- **Checks.** Each is one fused compare and branch. Where a sample
  lands on one, it is the miss of the load before it, as bounds-enum.md
  showed with PEBS. The exceptions are loops whose test cannot leave
  them: `find_active_mapper` (0.17% on its index test, 0.08% on its
  yield count) and `inference_type_mapper_map`.
- **Pushes, 2.95%**, the largest Rig-side share outside the maps: the
  store's list builders (`table_entries`, `new_type_list`,
  `type_list_items`, `new_sym_list`), `put_relater`, and the
  instantiation stack.
- **Yield checks:** `turn` 0.99% (in `mapper_map`, `table_entries`,
  `find_active_mapper`, `new_type_list`), `tickCall` 0.39%, and the
  scheduler flag's load 0.53%.

## The hand edits

Each edit is a patch in the data directory against the package as
emitted. The safe ceiling is all six; the unchecked ceiling is all six
with every check's panic unreachable, built `-Ofast`.

Each entry gives what Rig emitted, what the ceiling has, the pass
that would have to change, and the class: **(a)** emit or runtime
alone; **(b)** needs a proof or a recorded fact; **(c)** needs a
language feature; **(d)** Trig-side.

**se1, a signed index as one compare** (`se1-index.patch`, runtime,
class **(a)**). `rig.index(i, count)` tests `0 <= i` (`std.math.cast`)
and `i < count`: two branches where an `Int` index is not known to be
non-negative. `Ids.node_id`'s `@node_base[Int(n.file) - 1]` compiles to
`sub $1; jb` and later `cmp; jae`. Ceiling: `u64(i) >= count`, one
compare, correct since every count is a length below 2^63. This is
#696's change, reverted by 5918c45ee because std.json's twitter ran
3.5-3.8% more instructions per byte; it is here to measure what it is
worth to Trig.

**se2, the cold mapper kinds out of `mapper_map`**
(`se2-mapper-outline.patch`, inlining, class **(a)**). LLVM inlines
`inference_type_mapper_map` and `function_mapper_map`, with their loops,
into `mapper_map`, which recurses for every `Merged` and `Composite`
mapper. So each call, even a `Simple` one, saves six registers and
makes a 168-byte frame: the prologue's eleven instructions hold 109
of mapper_map's 880 samples in tsrs-standing.md's plain profile. Ceiling: both `noinline`.

**se3, `instantiate_type`'s early exits at the call**
(`se3-instantiate-inline.patch`, inlining, class **(a)**).
`instantiate_type` (100 call sites) calls
`instantiate_type_with_alias`, a frame of 12,500 instructions under
PGO. Its first tests return `t` for a type that cannot hold a type
variable, and they touch nothing but the type's flags. Ceiling:
`instantiate_type` inline, with those tests (`t == 0`, `m == 0`, no type
variables and no alias) before the call: partial inlining.

**se4, `find_active_mapper`'s loop** (`se4-active-mappers.patch`,
proofs, class **(b)**). `i` starts at `@active_mappers.len` and counts
down, and nothing in the loop writes the List (the function holds `?@`).
Rig emits `self.active_mappers.at(i)` each turn: a reload of the length
and the buffer from `self` and a bound test. Ceiling: the List's items
read once, `items[i]` with no test. Two facts: the loop does not write
the List (the ownership checker's: it is read through a view for the
whole loop), and `0 <= i < len` (a proof from the countdown, given the
first).

**se5, `inference_type_mapper_map`'s loop** (`se5-inference-loop.patch`,
proofs and storage, class **(b)**). Each turn re-tests the context index
`n` against `@inference_contexts.len` (loop-invariant: `cmp
%r14,0x3aa0(%rbx); jbe` at the top of the loop), reloads the context's
inferences, and reloads `@inference_infos`'s base and length. Nothing
writes them before the loop returns. Ceiling: the context's index tested
once, its inferences walked as a slice with no test, and the infos'
items read once, so each turn makes only the test that `inference <
infos.len`. The fact needed is the same as se4's: no write to the
containers in the loop, which the ownership checker knows; then the
invariant test is hoisted, and the slices are made once (storage).

**se6, the store's list builders in bulk** (`se6-bulk-lists.patch`,
Trig-side with a std part, class **(d)**). Trig's generated store
(`store_generated.rig`) builds and reads its eight list kinds
(`TypeList`, `SymList`, and so on) one element at a time:
`new_type_list` pushes each item onto a Table (`!@store.type_lists.push(x)`:
a full test, a slot address, a store, and a length store per item, and a
yield count), and `type_list_items` grows an empty List by doubling, an
index test and a push per item. Pushes take 2.95% of the plain build's
samples, these builders 0.65% of them. Ceiling: a Table `appendSlice`,
with one test that the items fit and one `@memcpy`, and a `constRange`
read of `lo..lo + count` with one test, copied by `List.fromSlice` into
a List of exactly its length. Trig can make the List of the right size
now (`List(capacity: n)`); the bulk Table operations are std's to add,
as `Span[n]` had them (proofs.md).

**The unchecked variants.** Every Rig check's panic (`indexPanic`,
`slicePanic`, `lenPanic`, `bytesPanic`, `keepPanic`, `proofPanic`, and
`Table`'s `fullPanic`) becomes `unreachable` and the package is built
`-Ofast`, so Zig's overflow and cast checks go too, and LLVM may assume
each test passes (`unchecked-main.patch`, and `unchecked.patch` on top
of the safe edits). `unchecked-index-main.patch` does it for the index
and slice tests alone, built `-Osafe`, keeping every other check. And
`noyield.patch` makes `turn` and `tickCall` do nothing: not a safety
check but Rig's scheduling, measured for its share.

## Results

20 rounds, interleaved, every variant's output identical to main's in
every round (`times.txt`, `summary.txt`). "Faster" is the wall median.

**The ceilings, as Trig ships (PGO), against tsrs:**

| | ts-pattern wall | vs tsrs | cycles | instructions | peak RSS | zod3 wall | vs tsrs | cycles | instructions | peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main, PGO | 782.5 ms | 1.21× | 3.341G | 8.197G | 272 MB | 154.3 ms | 1.34× | 0.616G | 1.435G | 84 MB |
| safe ceiling, PGO | 786.8 ms | 1.22× | 3.352G | 8.107G | 275 MB | 153.7 ms | 1.34× | 0.615G | 1.427G | 87 MB |
| unchecked ceiling, PGO | 739.8 ms | **1.14×** | 3.125G | 7.111G | 274 MB | 142.8 ms | **1.24×** | 0.565G | 1.215G | 87 MB |
| tsrs shipped | 646.5 ms | | 2.890G | 7.228G | 202 MB | 115.0 ms | | 0.483G | 1.206G | 54 MB |

Against PGO main: the safe ceiling is 0.55% slower on ts-pattern (1.1%
fewer instructions) and 0.42% faster on zod3 (0.6% fewer). The unchecked
ceiling is 5.5% faster on ts-pattern (6.5% fewer cycles, 13.3% fewer
instructions) and 7.5% faster on zod3 (8.3% fewer cycles, 15.4% fewer
instructions). With every check gone, Trig runs fewer instructions than
tsrs on ts-pattern (7.11G against 7.23G) and about as many on zod3; the
cycles left (8% and 17% more than tsrs's) are not instructions run but
waits: misses, faults, and the kernel's share tsrs-standing.md measured.

PGO main is 1.21× tsrs here against tsrs-standing.md's 1.29×: a
quieter machine (load 0.8 against 1.8-2.4) and Rig's commits since
`36422da59`. The ratios between variants, all timed in the same rounds,
are what this record measures.

**Every variant, plain release builds** (no PGO; each against main):

| variant | ts-pattern: faster / fewer cycles / fewer instructions | zod3: faster / fewer cycles / fewer instructions | peak RSS ts-pattern, zod3 |
|---|---|---|---|
| main (898.7 ms, 177.8 ms) | | | 274, 86 MB |
| safe ceiling (se1-se6) | 0.61% / 0.39% / 1.22% | 2.13% / 0.33% / 0.58% | 271, 84 MB |
| unchecked ceiling (safe, no checks) | 6.13% / 6.57% / 11.75% | 9.39% / 9.09% / 13.70% | 269, 83 MB |
| no checks, on main | 6.63% / 6.62% / 11.18% | 9.20% / 9.32% / 13.70% | 271, 85 MB |
| no index or slice tests, on main | 4.15% / 4.14% / 6.49% | 5.64% / 5.06% / 7.98% | 271, 83 MB |
| no yield checks, on main | 1.38% / 1.48% / 4.00% | 2.86% / 1.74% / 3.35% | 274, 85 MB |
| se1 alone | 0.58% / 0.25% / 0.32% | 1.31% / 0.10% / 0.39% | 274, 86 MB |
| se3 alone | **0.86% slower** / 1.04% more / 0.21% more | 0.17% / 0.79% more / 0.38% more | 274, 86 MB |
| se6 alone | 0.43% / 0.15% / 0.48% | 1.11% / 0.18% more / 0.32% | 271, 84 MB |

Read from these:

- **The safe edits are worth little, and less under PGO.** By
  instructions, se2, se4, and se5 together are the safe ceiling's 1.22%
  less se1's 0.32%, se6's 0.48%, and se3's 0.21% more: about 0.6% on
  ts-pattern and 0.25% on zod3. With the checks gone, the safe edits add
  nothing more (the unchecked ceiling against no checks on main is within
  0.5%).
- **Checks are the ceiling.** Index and slice tests alone are 58% of the
  instructions all checks cost on ts-pattern and three fifths of the time;
  the rest (overflow, casts, Zig's own tests, a table's full test) is
  about 2.5% of time and 4.7% of instructions. That split matches
  checks.md's of 2026-10-24 (7.4% for all checks, 5.9% for index tests).
- **Yield checks** run 4.0% and 3.4% of the instructions for 1.4% and
  2.9% of the time.

## What Rig would have to emit, ranked

By measured gain on the plain build (ts-pattern, zod3), each a ceiling:
what a pass would win if it took the whole class. Items that need a proof
or a recorded fact are marked **(b)**: Rig - Merges takes those up next.

1. **Index tests: up to 4.2% and 5.6% faster, 6.5% and 8.0% fewer
   instructions** (index and slice tests unreachable, `-Osafe`).
   **(b)** for the tests a proof can reach: a loop index against a length
   nothing in the loop writes, a countdown from a length (se4), a test
   that does not change in a loop (se5). Those are the only kind this
   edit set could remove by hand, and they are small here (below). Most
   of the 4-5.6% is lookups by ids read from memory (checks.md, §1),
   which no proof covers; for those it is **(c)**, an index type (`Slot`
   and `Table`, as Trig's stores already use), and Trig's move onto
   it **(d)**. proofs.md found that removing the tests a proof could
   reach saved nothing, since they are predicted; the 4-5.6% here is the
   cost of all of them together, what they hold in registers and code
   size included.
2. **Every other check: about 2.5% and 3.6% faster, 4.7% and 5.7% fewer
   instructions** (no checks, less index tests only): overflow tests on
   `+` and `-`, `@intCast`, Zig's own tests, a table's full test.
   **(b)**: range facts that make the arithmetic exact. For example,
   `node_id`'s `@node_base[f - 1] + n.node.id` is an add Trig knows stays
   under 2^27, but Rig cannot know it.
3. **Yield checks: 1.4% and 2.9% faster, 4.0% and 3.4% fewer
   instructions** (`turn` and `tickCall` doing nothing). Not a safety
   check but the scheduler's due. **(a)**, inlining and runtime: fewer
   call sites that check (`cutCycles`), and fewer turn counts in short
   loops. loop-hoist.md measured the counted runs worse; the share is
   here for whoever takes it next.
4. **A signed index as one compare (se1): 0.6% and 1.3% faster, 0.3%
   and 0.4% fewer instructions.** **(a)**, runtime. Built as #696 and
   reverted (5918c45ee) because std.json ran 3.5-3.8% more instructions
   per byte. To keep it for Trig, emit would choose the one-compare form
   per site, for a List indexed by an `Int` that is not known
   non-negative, and keep the two-test form where std.json's loops
   need it: also **(a)**, in emit.
5. **The store's list builders in bulk (se6): 0.4% and 1.1% faster,
   0.5% and 0.3% fewer instructions, 1-2% less peak memory.** **(d)**,
   Trig-side: `List(capacity: n)` for the lists it copies out, which Trig
   can write now, with std's Table range read and bulk push (as
   `Span[n]` had them) for the copy itself.
6. **The rest of the safe edits (se2, se4, se5): about 0.6% and 0.25%
   fewer instructions together**, not timed apart. se2 is **(a)**,
   inlining: keep a function's cold, loop-holding callees out of a
   recursive hot one. se4 and se5 are **(b)**: the fact that a loop does
   not write the containers it reads through a view (the ownership
   checker has it), from which an invariant test is hoisted and the
   container's items read once (storage).
7. **Partial inlining of `instantiate_type` (se3): 0.9% slower** on
   ts-pattern, more cycles and instructions on both: copying its exits
   into 100 callers costs more than the call they save. Not a
   requirement.

## Trig-side findings

For Trig's session, which owns its code's performance:

- **The store's list builders** (`store_generated.rig`): `*_list_items`
  grows an empty List by doubling to copy a known count, and
  `new_*_list` pushes one item at a time. A List made with
  `List(capacity: Int(list.count))` saves the regrowth now; a bulk copy
  waits on std (item 5). Measured: 0.4-1.1% faster, 1-2% less peak memory.
- **`Ids.node_id`** (0.50%, and inlined into every link lookup):
  `@node_base[Int(n.file) - 1] + n.node.id` makes a sign test, a bound
  test, an overflow test, and the link table's range test. A `node_base`
  with a slot at index 0 would drop the `- 1` and its sign test.
- **`mapper_map`'s samples are its record's cache miss**: the load of
  `@store.mappers[m]` and the instruction after it, then the kind's
  dispatch. The kind is packed into the top five bits of the record's
  `b` word, so every call loads and shifts `b` before it can branch.
  That is Trig's layout to weigh, not Rig's.
- **`find_active_mapper`** searches `@active_mappers` from the top on
  every instantiation (0.48%, with its yield count). A depth kept with
  each mapper, or a map from mapper to depth, would make that search
  O(1).

## Left out

- **The wide-key maps** (`Ordered(CacheKey…)`, `InstantiationKey`,
  `CachedTypeKey`): another builder owns them now. They are 11.1% of the
  PGO build's user cycles (tsrs-standing.md).
- **The u32 → u32 maps and the rest of `ordered.zig`**: the design raced
  in bench/hash two days ago (hash-race/); not tuned again here.
- **The allocator's fast path inlined into its callers.** `alloc` and
  `free` are `noinline` so that the thread's heap is read in their own
  frame, never one a caller keeps across a fiber switch (alloc.zig, "The
  fast paths"). An inlined path would need a read of `my_heap` that LLVM
  may not move across a call, which Zig cannot say; not a hand edit to
  make blind. Its share: `alloc` 1.08%, `free` 0.65%.
- **Huge pages and the kernel's quarter of the gap**: #740 (huge pages)
  landed after the baseline and is in none of these numbers.
