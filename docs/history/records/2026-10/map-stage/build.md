# The Map stage, built and measured on real Trig (2026-10-26)

This builds [design.md](design.md)'s Candidate 2 as the replay
([replay.md](replay.md)) tuned it, on branch `map-stage`, and measures it
on Trig main by the bar of [bench-plan.md](bench-plan.md). The scripts are
in [build/](build/). Every raw run is in `build/runs-1` (the first build,
used to choose the split) and `build/runs-3` (the final build, map-stage
at 01fc95ba2).

## Verdict: measured, not taken

Rig (OG) decided it, with the coordinator, on 2026-10-26. #702 was
closed unmerged, and its branch, `map-stage`, stays pushed. The build
fails the bar of [bench-plan.md](bench-plan.md) on three counts:

- **The shipping PGO build is slower at four checkers.** ts-pattern's
  wall time is 1.5% slower warm and 3.8% slower cold, though it takes
  3.2-4.6% fewer cycles.
- **zod3 uses more memory.** Its peak RSS is 5.0% higher with PGO (88.3
  to 92.7 MB) and 2.5% higher in release, and its cycles are within
  noise.
- **Large maps regress.** bench/hash's million-key inserts are 70-96%
  slower (Int and pair keys), and the walk of a million Int keys is 10.7
  times as slow.

What did pay:

- **ts-pattern** takes 2.5-4.5% fewer cycles in release, with 5.4% less
  peak RSS at one checker.
- **Inlining the hot path** cut the Map's spills and reloads in Trig's
  PGO build from 426M to 82M instructions a run. That covers the lookup
  and an insert into a table with room, with growth out of line. It is
  the piece to be tried next on its own, over the dense layout.

## What was built

std/__rig_builtin.rig, in safe Rig, with `$plain(T)` narrowing (#701):

- **Entries in slots.** A Map whose key and value are both plain data,
  and whose `Pair(key, value)` takes at most 32 bytes (`packs`), keeps
  its entries in slots. So does a Set of plain keys of at most 32 bytes.
  Every method tests `$plain(K) and $plain(V) and packs[K, V]()` first.
  Each instance answers that test when it compiles, so an instance
  carries one layout.
- **The small path.** Up to 8 entries sit in order in `ps`, and a lookup
  compares keys with no hash. A take moves the later entries down.
- **The table.**
  - It has a power of two of slots, at least 32.
  - Its Swiss control bytes are 0 for free, `TAKEN`, or `tag_of` for
    full. The first 15 are repeated past the end, and a probe reads 16 at
    a time as `Simd[U8, 16]`.
  - It is at most 7/8 full, counting taken slots. It doubles, or is
    rebuilt at its size when half its entries are taken.
  - The order is `table.at`, a List of U32 slot numbers.
- **Presence in the control byte.** A slot is `Pair(key, value)`, with no
  `V?`. A free slot holds a copy of an entry, which the `$plain` test
  lets the body make, and nothing reads it.
- **The rebuild.** It fills the new slots and control bytes at once, then
  walks the old slots in memory order and keeps where each entry went.
  It rewrites the order through that, into a List with room for every
  entry until the next rebuild. Nothing stores a hash: each key is hashed
  again.
- **The hot path is inlined.** The lookup (`p_find`, `p_slot`) and an
  insert into a table with room (`p_add`, `p_place`) are inlined into the
  write that missed. Wrapping arithmetic keeps the probe's slot
  arithmetic free of overflow tests. The small path, the first table, and
  growth (`p_add_rest`, `p_build`, `p_rebuild`) stay out of line.
- **Every other Map and Set keeps today's dense entries and index,
  unchanged.** The write methods stay `inline` as before: `ensure`,
  `ensure_added`, `ensure_with`, `take`, `at`, and the iterators are
  marked.
- **The header** is 128 bytes: `len` and five Lists, with `ps` new.
- **The runtime and the trace.** The runtime's printer reads the slots
  in order (`SlotOrder`). The Map trace (`RIG_MAP_TRACE`) finds the Map
  by its plainness parameters and records `p_build` and `p_rebuild` as
  grows.

## Real Trig (final build)

These runs are on pup, Trig main 5abee7e, against Rig main 5a79e02f2:

- Each Trig was built by that Rig (`rig build --release`, and `--pgo`
  trained by `tools/trig/bolt-train`) through `slot.sh`.
- Runs were interleaved with the order rotated each round, and each
  figure is the fastest of 10.
- One checker ran on core 8 with sibling 9 idle. Four checkers ran on
  cores 6-9.
- Each run was measured by `perf stat` (user cycles and instructions,
  `duration_time`) and `/usr/bin/time` (peak RSS).
- **Cold** runs had `pollute` (build/pollute.zig) on E-core 12, streaming
  through 256 MiB so that the shared cache stays cold.
- Every output matched the base build's byte for byte.
- Other sessions' release builds ran on the release slots at times (load
  2-4), so a time difference under 2% is noise. The cycles' median pair
  is beside each figure.

| Project, checkers, cache | Time | Cycles (median pair) | Instructions | Peak RSS |
|---|---|---|---|---|
| ts-pattern, 1, warm | 0.3% faster | 3.0% fewer (2.4%) | 1.38% fewer | 312.0 to 295.1 MB, 5.4% lower |
| ts-pattern, 1, cold | 1.8% faster | 2.5% fewer (2.4%) | 1.41% fewer | 5.4% lower |
| ts-pattern, 4, warm | 3.0% faster | 3.4% fewer (3.6%) | 1.00% fewer | 363.0 to 360.1 MB, 0.8% lower |
| ts-pattern, 4, cold | 5.0% faster | 4.5% fewer (4.2%) | 1.00% fewer | 0.8% lower |
| zod3, 1, warm | 0.4% faster | 0.6% fewer (0.4%) | 0.39% more | 90.0 to 92.3 MB, 2.5% higher |
| zod3, 1, cold | 0.7% slower | 0.7% fewer (1.5%) | 0.19% more | 2.5% higher |
| zod3, 4, warm | 6.7% faster | 5.4% fewer (3.2%) | 0.27% more | 135.9 to 134.5 MB, 1.1% lower |
| zod3, 4, cold | 2.1% slower | 0.3% more (1.7%) | 0.28% more | 1.1% lower |

PGO, against main's PGO build:

| Project, checkers, cache | Time | Cycles (median pair) | Instructions | Peak RSS |
|---|---|---|---|---|
| ts-pattern, 1, warm | 2.5% faster | 2.9% fewer (2.2%) | 1.01% more | 310.2 to 296.1 MB, 4.5% lower |
| ts-pattern, 1, cold | 1.6% faster | 2.1% fewer (1.4%) | 1.00% more | 4.5% lower |
| ts-pattern, 4, warm | 1.5% slower | 3.2% fewer (2.3%) | 1.46% more | same |
| ts-pattern, 4, cold | 3.8% slower | 4.6% fewer (2.6%) | 1.46% more | same |
| zod3, 1, warm | 0.5% slower | 1.4% fewer (-0.2%) | 2.69% more | 88.3 to 92.7 MB, 5.0% higher |
| zod3, 1, cold | 2.1% faster | 1.6% fewer (1.4%) | 2.53% more | 5.0% higher |
| zod3, 4, warm | 0.5% faster | 4.4% fewer (1.1%) | 2.73% more | 0.5% higher |
| zod3, 4, cold | 0.7% faster | 1.5% fewer (1.3%) | 2.81% more | 0.6% higher |

The other light-gate projects ran at one checker, warm
(`runs-3/summary-other.txt`):

- **tiny-invariant:** 3.2% fewer cycles, and 5.7% less RSS.
- **mitt, neverthrow, superstruct:** within noise in time. Their RSS is
  0.6% lower to 1.5% higher (6.5-6.9% higher with PGO, a 2 MB step on
  26-36 MB).

## The hot path in Trig's PGO disassembly

The coordinator relayed Trig (fork)'s disassembly diff of the same day:
the Map family has 362M instructions of spills and reloads in
ts-pattern, `add_entry` is noinline, and the probe loop misses on its
tags. This build was measured by the same classifier,
`/zfs/trig-pup/trial/dis/whole.py`:

- the instructions sampled every 10M over 30 runs of ts-pattern at one
  checker;
- each sample charged to its innermost source line;
- a reload is a load from the stack and a spill a store to it.

Millions of instructions a run:

| Build | Map/Set | its reloads | its spills | `maskBitsCast` (the group compare, inlined) | hash mix |
|---|---:|---:|---:|---:|---:|
| main PGO | 953 | 225 | 201 | - | 189 |
| entries in slots, probe inlined (final2) | 722 | 44 | 22 | 277 | 152 |
| and the insert inlined (final3) | 673 | 66 | 16 | 266 | 138 |

- **Spills and reloads fell from 426M to 82M.** The probe loop of an
  inlined lookup (`table_get`'s, for one) keeps its state in registers.
  Only the yield check's call inside the loop saves and restores around
  itself (`rig.sched.tick`, which branch loop-hoist is working on).
- **Most of the `maskBitsCast` row is skid.** Its samples land on the
  `vpcmpeqb` after the group load that misses (byline.py), so they count
  the probe's misses, not its instructions.
- **Hash mix fell by 51M.** No key is hashed a second time between
  lookup and insert. Hashing itself was not changed.

## The split for small entries

The replay found U32 to U32 maps (Trig's symbol tables) slower in slots.
Three ways were built and timed on Trig release, at one checker, warm,
fastest of 10 (`runs-1/summary-other.txt`):

| Variant | ts-pattern | zod3 |
|---|---|---|
| a slot of 8 bytes or fewer dense until 64 entries, then moved into slots (`new64`) | 3.3% fewer cycles, RSS 0.9% lower | 1.6% fewer cycles, RSS 7.3% higher |
| such slots always dense (`newinf`) | 1.7% fewer cycles, RSS 0.8% lower | 0.0%, RSS 7.4% higher |
| every plain pair in slots from the start (`new0`) | **3.4% fewer cycles, RSS 5.4% lower** | **0.7% fewer cycles, RSS 2.7% higher** |

`new0` was faster and smaller on both projects, so it was built, and the
split was dropped.

## Also measured and not kept

| Variant | Result |
|---|---|
| The table rebuilt in place: the slots grown by `resize`, then rehashed by swaps, as hashbrown's `rehash_in_place` (no second buffer) | bench/hash's million-key inserts 154% slower than main, against 74% for the copying rebuild (a preview of 3 rounds); not kept |
| The probe called, not inlined (`called fun p_find`) | ts-pattern 0.4% fewer cycles than main, against 3.0% for the inlined probe; 2.4% more instructions |
| A smaller header, probed by its opposite: main's Map with 24 bytes more (`base-pad`) | ts-pattern 0.8% more RSS (2.3 MB) and 0.5% more cycles; zod3 0.3% more RSS. A header of 64 bytes would save about 1.5% of ts-pattern's RSS; it needs the table behind a box (a load on every probe) or a field whose type a compile-time function picks, which Rig does not have. Not built. |

## bench/hash and std.json (pup, core 8, fastest of 11)

bench/hash in Zig's safe mode, from `runs-3/summary-hash2.txt` (fast mode
in `summary-hash.txt` is alike):

| Row | The Map stage against main |
|---|---|
| Int, a million: insert, hit, miss, walk | 69.5% slower, 5.3% slower, 53.6% faster, 10.7 times as slow |
| pair, a million: insert, hit, miss | 95.7% slower, 28.4% slower, 45.0% faster |
| Int `ensure`, `ensure_with`, `edit` then `put`, on misses | 60-84% slower |
| on hits | 3.6-24.6% slower |
| small maps of 4 and 8 | 46.4% and 31.3% faster |
| String rows (dense) | within noise; insert 4.3% slower |

std.json, rig-safe and rig-fast, on six files: within noise. The emitted
Zig of every module is identical. Only `rig/runtime.zig`, whose printer
gained `SlotOrder`, differs, and twitter's program retires the same
instructions and cycles to well under 1%.

## Gates

- `tools/heavy swarm test/rig.rip all -q -w 3`: green, 10,628 jobs. The
  oracle files are unchanged.
- `zig build test` on pup: Debug, ReleaseSafe, and ReleaseFast all pass.
- loco's light gate: GREEN.
- `tools/emit-diff origin/main`: every program that names a Map or Set
  differs. #701 lowers each generic that builds a Map from a type
  parameter with plainness parameters (`Map(K, true, V, true)`), and the
  program-wide inliner moves with the Map's sizes. A program with no Map
  differs only in `rig/runtime.zig`.
- Trig's light gate was not run, since the change was not taken.
