# The Map stage, bounded by Trig's trace (2026-10-25)

This is the bound that [bench-plan.md](bench-plan.md) asks for before anything
goes into std. Trig's real map operations on ts-pattern are replayed against
a copy of today's Map and against design.md's Candidate 2. Nothing is built
into std here. The harness and scripts are in [replay/](replay/), and every
raw run is in [replay/results/](replay/results/).

## Verdict

- **The candidate as design.md writes it saves about 1.0% of ts-pattern's
  cycles.** That is below the 2% bar. Its rebuild walks the order List, so
  each entry of a large table is a random read, and its first table has
  16 slots. With a warm cache it is 76M cycles slower than today.
- **With two fixes the replay calls for, it saves about 3.1%.** The fixes
  are a first table of 32 slots and a rebuild that walks the old slots in
  memory order. That is 145M of ts-pattern's 4,738M cycles.
- **Without the `V?` flag in the slot it saves about 3.7%** (176M), with
  presence kept in the control byte.
- These are interpolated (see "Share of ts-pattern" below). The replay
  brackets them: 1.0-1.9% when warm, 4.3-4.8% when every operation runs
  cold.
- **So the tuned candidate clears the bar, but not by much.** Its warm
  lower bound does not clear it. Its gain is about half of design.md's
  220-350M estimate. Real Trig decides (bench-plan gate 4), and the stage
  is worth building only with the two fixes and without the flag.

## How it was measured

- **Trace.** Rig at a06053e58 was built on pup. Trig main 676760a was
  built with `rig build --release` (Zig's safe mode) twice: once plain and
  once with `RIG_MAP_TRACE=1`. Each was run on a copy of
  misc/projects/ts-pattern with `-p tsconfig.trig.json --noEmit`, once
  with `--singleThreaded` and once with `--checkers 4`. In both runs the
  traced build's output matches the plain build's byte for byte.
- **Replay.** [replay/replay.zig](replay/replay.zig) is the harness. It
  reads the whole trace before the clock starts, then runs every record
  in the recorded order on per-map instances. It counts user cycles and
  instructions for the replay loop alone, with `perf_event_open`.
- **Checks.** Every result is checked against the trace's hit bit, and
  all runs had 0 mismatches. The harness recomputes every key's hash as
  `rig.hash` does, and every recomputed hash of a replayed key equals the trace's.
- **Allocator.** It allocates through Rig's release allocator
  (src/alloc.zig).
- **What it replays.** The ten busiest K/V types, 97.1% of the lookups,
  puts, and takes. Of the 103,657 grow records, every one came from a put
  that the replay makes itself, so none was replayed as an explicit
  rebuild.
- **Machine.** pup, core 8, with sibling 9 idle. No run was dropped for a
  busy sibling. Each figure is the fastest of 11 interleaved runs (7 in
  fast mode), with the order rotated each round, and the median of the
  paired per-round differences beside it.
- **`noop` is the harness's own cost.** It decodes each operation and
  builds and checks its key, but touches no map. "Less noop" is the
  design's own cost.
- **Cold cache.** `--pollute 65536` reads one line of a 64 MiB buffer
  before each operation, so every operation starts from a cold cache.
  This is the upper bound.
- **The Mac was not timed.** Its load was 27-60 throughout.

## The trace

At one checker there are 18,657,723 records over 212,294 maps on one
thread. At four checkers there are 19,530,317 records over 220,807 maps
on 5 threads. The trace carries the thread in every record and takes a
lock for each, so it is safe per thread. The mix at four checkers is the
same, with about 5% more operations.

| K/V type | maps | get | hit | put | new key | take | clear | K B | V B | largest | share |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Map CacheKey → U32 (relation and mapper caches) | 70 | 3,304,240 | 27.8% | 2,291,584 | 100% | 0 | 2,442,586 | 16 | 4 | 222,853 | 36.3% |
| Map U32 → U32 (symbol tables, `Atom → Sym`) | 118,944 | 2,486,301 | 45.2% | 1,301,031 | 99.8% | 14 | 205 | 4 | 4 | 2,335 | 24.6% |
| Map InstantiationKey → U32 | 1 | 1,210,060 | 65.3% | 420,969 | 100% | 0 | 0 | 24 | 4 | 420,969 | 10.6% |
| Map CachedTypeKey → U32 | 1 | 978,649 | 70.3% | 165,119 | 85.1% | 0 | 0 | 8 | 4 | 140,534 | 7.4% |
| Set CacheKey | 4 | 276,960 | 1.5% | 272,762 | 100% | 272,762 | 283,466 | 16 | 0 | 369 | 5.3% |
| Set U64 | 1 | 0 | - | 608,770 | 0.2% | 0 | 0 | 8 | 0 | 1,202 | 4.0% |
| Map U32 → Int | 17,858 | 251,679 | 9.8% | 251,744 | 90.2% | 0 | 0 | 4 | 8 | 130 | 3.3% |
| Map InferenceKey → I32 | 68,612 | 131,203 | 4.0% | 251,838 | 50.0% | 0 | 0 | 14 | 4 | 679 | 2.5% |
| Set U32 | 2,327 | 208,872 | 9.9% | 35,233 | 81.2% | 5,078 | 72 | 4 | 0 | 2,294 | 1.6% |
| Map U32 → MappedSymbolLinks | 1 | 73,560 | 99.9% | 161,426 | 55.8% | 0 | 0 | 4 | 8 | 90,020 | 1.5% |

Over all types: gets hit 42.1%, puts find their key 15.1%, and takes find
it 98.7%.

- **Symbol tables.** The largest length each one reaches: 1,746 stay
  empty, 84,830 reach 1-8, 4,832 reach 9-16, 27,169 reach 17-64, and 367
  go past 64.
- **The 70 CacheKey maps.** The relation caches are never cleared and
  include the 222,853-entry one. The pooled mapper caches account for the
  2.44M clears and the 32,420 grows: a cache refills past 8 entries, then
  clears.
- **Sizes and growth.** The full per-type list is in
  [c1.summary.txt](replay/results/c1.summary.txt) and
  [trace-stats-c1.txt](replay/results/trace-stats-c1.txt).

## Replay cycles

### The whole trace

pup, Zig safe mode, fastest of 11, all designs from one binary
([summary-2.txt](replay/results/summary-2.txt)):

| Design | Warm cycles | Cold cycles | Warm instr. | Peak MB | Warm vs today (median) | Cold vs today (median) |
|---|---:|---:|---:|---:|---:|---:|
| today | 977.1M | 2,375.1M | 2,056M | 103.0 | | |
| today without the flag (bitset) | 1,018.2M | - | 2,067M | 93.3 | +41.1M (+43.1M) | - |
| candidate as designed (`cand`) | 1,053.4M | 2,255.6M | 1,928M | 78.8 | +76.4M (+85.2M) | -119.5M (-33.1M) |
| candidate, no flag (`cand_nf`) | 993.8M | 2,245.5M | 1,884M | 68.3 | +16.7M (+40.2M) | -129.6M (-112.2M) |
| no flag, hash kept in the slot (`cand_nf_sh`) | 967.4M | 2,320.4M | 1,868M | 77.3 | -9.7M (+9.6M) | -54.7M (-19.6M) |
| no flag, each hash given (`cand_nf_ph`) | 947.9M | 2,253.8M | 1,726M | 68.3 | -29.1M (-14.6M) | -121.3M (-67.7M) |
| **tuned (`cand2`)** | 928.6M | 2,172.7M | 1,913M | 79.9 | **-48.5M (-27.0M)** | **-202.4M (-177.6M)** |
| **tuned, no flag (`cand_nf2`)** | 889.1M | 2,146.9M | 1,871M | 69.1 | **-87.9M (-92.0M)** | **-228.2M (-244.3M)** |
| noop (the loop) | 374.8M | 1,221.7M | 642M | 0 | | |

- **Fast mode** (warm, fastest of 7): today 1,007.4M, cand2 890.3M (117M
  fewer), and cand_nf2 903.8M (104M fewer).
- **Layout noise.** In a separate build of the same source
  ([summary-all.txt](replay/results/summary-all.txt), first campaign),
  today was 976.3M and cand_nf 967.9M. Changes of 10-40M between
  binaries are code layout, so only rows from the same binary are
  compared.

### Each hot type alone

cand_nf2 and cand2 against today, each type replayed alone, so the
columns do not add up to the whole-trace figures. Warm is the fastest of
11, cold the fastest of 7, less noop:

| Type | today, warm | cand_nf2, warm | cand2, warm | today, cold | cand_nf2, cold | cand2, cold |
|---|---:|---:|---:|---:|---:|---:|
| CacheKey → U32 (relation and mapper caches) | 168.4M | -8.0M | -13.5M | 388.0M | -79.3M | -72.9M |
| U32 → U32 (symbol tables) | 111.4M | **+5.2M** | **+14.1M** | 169.4M | **+18.4M** | **+21.9M** |
| InstantiationKey → U32 | 115.8M | -20.7M | -23.1M | 179.6M | -35.9M | -36.2M |
| CachedTypeKey → U32 | 50.5M | -5.9M | -5.0M | 70.7M | +0.5M | -0.1M |

From the first campaign, warm, alone, the untuned candidate (`cand_nf`)
against today: Set CacheKey -6.4M, U32 → Int +6.6M, InferenceKey → I32
-2.7M.

## Share of ts-pattern

- **Real Trig at one checker.** The plain release build on pup core 8,
  fastest of 11, takes **4,738.1M user cycles** and 10,542.7M
  instructions ([trig-perf-*.txt](replay/results/)). The 2% bar is 94.8M.
- **The replay has a warmer cache than Trig.** Trig does checker work
  between map operations.
- **Calibration.** Trig's own profile, taken the same day (the Trig
  session's gap report), puts the Map/Set family at 975M cycles. On the
  97.1% of operations replayed, that is 947M.
- **Where Trig sits.** Today's replay, less noop, costs 602M warm and
  1,153M cold. 947M lies 0.63 of the way from warm to cold. Each saving
  below is placed at that point:

| Design | Warm | Interpolated | Cold |
|---|---:|---:|---:|
| candidate as designed | +76M (slower) | -46M, **1.0%** | -120M, 2.5% |
| tuned, with the flag | -49M, 1.0% | -145M, **3.1%** | -202M, 4.3% |
| tuned, no flag | -88M, 1.9% | -176M, **3.7%** | -228M, 4.8% |

Two things limit the interpolation:

- **The copy of today is leaner than Rig's own emitted code.** It has
  fewer bounds tests and a direct key compare. Both designs are written
  equally lean, so the difference between them should hold, but the
  absolute costs are low.
- **The trace has no iteration in it**, so design.md's slower iteration
  of a huge packed map is not measured. Trig's hot caches are never
  iterated, but its symbol tables are, through members.

## Memory

Peak bytes of the maps' own buffers, from `--mem` runs
([mem.txt](replay/results/mem.txt), [mem2.txt](replay/results/mem2.txt)):

| Map | today | today, no flag | cand / cand2 | cand_nf / cand_nf2 |
|---|---:|---:|---:|---:|
| relation cache, CacheKey → U32, 222,853 entries | 11.0 MB | 11.0 | 7.5 | 7.5 |
| instantiation cache, InstantiationKey → U32, 420,969 entries | 31.5 MB | 31.5 | 19.1 | 19.1 |
| CachedTypeKey → U32, 140,534 entries | 6.8 MB | 5.8 | 5.4 | 4.3 |
| symbol tables, all 118,944 at their peak | 42.7 MB | 34.6 | 35.9 / 36.9 | 27.0 / 27.7 |
| every replayed map, at the peak | 103.0 MB | 93.3 | 78.8 / 79.9 | 68.3 / 69.1 |
| with the hash in the slot (`cand_nf_sh`) | | | | 77.3 (relation cache 9.6, instantiation cache 23.3) |

- **Big caches.** The two match design.md's arithmetic (7.6 and 19.4 MB).
- **Headers.** At the peak, 118,961 maps are live. At 104 bytes each that
  is 12.4 MB. The replayed candidate adds `used` and `slots`, 120 bytes
  each, 14.3 MB in all. Read `slots` from the control List's length to
  keep 104 bytes.
- **A smaller header for small maps.** One that holds `len`, the slot
  count, and one pointer to a block with the entries (or the table) and
  the order would be 24-32 bytes: 2.9-3.8 MB, which saves 8.6-9.5 MB. That
  is arithmetic; it is not built or timed here.

## The three questions from Trig's gap report

1. **The `V?` flag.**
   - *Packed layout.* With presence in the control byte, the tuned
     candidate is 39M cycles faster warm and 26M faster cold (about 0.7%
     of ts-pattern). Its peak memory is 10.8 MB lower: the symbol tables
     go from 36.9 to 27.7 MB, and CachedTypeKey from 5.4 to 4.3 MB.
   - *Dense layout.* Moving today's flag to a bitset saves 9.7 MB (the
     symbol tables go from 42.7 to 34.6 MB). It is 41M cycles slower in
     this replay, from the bitset test and layout, so in today's layout
     the flag is a memory win and not a speed win.
   - CacheKey and InstantiationKey entries round back up to 24 and 32
     bytes, so they gain nothing from it.
2. **Map headers.** See Memory above: 12.4 MB today. A 24-32-byte header
   for small maps would save 8.6-9.5 MB. Its speed is not measured.
3. **Rehashing already-hashed keys.**
   - *Stored hash.* Keeping the hash in the slot so that a rebuild hashes
     nothing gains 26M warm. It loses 75M cold, because 24-byte slots
     become 32-byte ones (the relation cache grows from 7.5 to 9.6 MB). It
     does not pay.
   - *Whole hash.* The bound on a whole hash (`cand_nf_ph`, every hash
     given) saves 46M against `cand_nf` warm and nothing cold (8M
     more): at most about 1% of ts-pattern.
   - *The other 92M.* The 92M in the gap report is mostly hashing done in
     the checker's own inlined code, outside the Map, which this replay
     cannot see.

## What the replay contradicts in design.md

- **§4, the rebuild.** "Walk `at` in order, move each live entry" makes
  a rebuild of a large table read its slots at random. As written, the
  candidate is slower than today when warm (+76M), and that cuts its
  share to 1.0%. Walking the old slots in memory order, keeping each new
  slot number in a remap array and then rewriting `at` through it, fixes
  this. On the whole trace the two fixes together turn +76M into -48M.
- **§2.4 and §4, a first table of 16 slots.** It rebuilds three times on
  the way to 64 entries. Starting at 32 slots helps the 27,169 symbol
  tables that reach 17-64 entries, and the pooled mapper caches.
- **§4, the symbol tables.** design.md has them neutral ("probe by
  group, in cache"). They are slower under every candidate: +5M to +14M
  warm and +18M to +22M cold. A packed probe touches a control line and a
  slot line where today's touches a tag line and an entry line, and the
  table rebuilds more often.
- **§6, the size of the gain.** design.md puts it at 220-350M (4-7%). The
  replay puts it at 145-176M (3.1-3.7%), and the two big caches give less
  than the 140-200M expected:
  - instantiation cache: -21M warm, -36M cold;
  - CacheKey maps: -8M to -14M warm, -73M to -79M cold.
- **§4, `V?` in the slot.** "A free slot holds a default key and `none`"
  keeps the flag, which costs 0.7% of cycles and 10.8 MB. The control
  byte already says whether a slot is full, so the slot needs no `V?`.
- **§2.4, `clear`.** This one the replay confirms: leaving the table's
  bytes alone on `clear` is right. A variant that keeps tables of up to
  256 slots through `clear` and zeroes their control bytes (`cand_nf3`)
  was slower in a single run (935M against 909M).

## Reproducing it

On pup, from a copy of Rig:

```sh
# Rig, then Trig plain and traced (a pack: tools/trig/main.rig beside links to trig/src/*)
NEXUS=/zfs/rig/nexus/bin/nexus sh /zfs/trig-pup/trial/slot.sh zig build -Dnexus=$NEXUS
(cd pack/src && RIG_MAP_TRACE=1 sh /zfs/trig-pup/trial/slot.sh $RIG build --release -o ../bin main.rig)
(cd copy/ts-pattern && RIG_MAP_TRACE_FILE=c1.bin ../../pack/bin -p tsconfig.trig.json --noEmit --singleThreaded)
python3 tools/map-trace.py c1.bin
python3 docs/history/records/2026-10/map-stage/replay/trace-stats.py c1.bin
sh docs/history/records/2026-10/map-stage/replay/build.sh
replay/bench.sh c1.bin replay/replay-safe 11 8 9 all today cand2 cand_nf2 noop > all.txt
replay/summarize.py all.txt
```

[campaign.sh](replay/campaign.sh) and [campaign2.sh](replay/campaign2.sh)
are the two runs whose numbers appear above. The traces themselves, about
0.9 GB each, stay on pup in /zfs/worktrees/rig/map-replay/.replay/traces.
