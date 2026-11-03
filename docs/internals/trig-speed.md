# Trig against tsrs: the brief for a speed session

Trig, the TypeScript checker written in Rig, races tsrs, a Rust port of
tsgo. This page is what a fresh session needs before it measures
anything: the goal, the bar, what is already known, where things are,
and what not to measure again. Where Trig stands today, and the leads in
order, are in [HANDOFF.md](../../HANDOFF.md) ("Next, in order").

## The goal and the bar

- **Make Trig faster than tsrs.** Speed comes first. Memory counts only
  where it buys speed.
- **A change lands** when it is more than 1.5% faster, or runs 1% or
  more fewer single-thread instructions, with peak memory no higher.
  A gain of 1.5-2% needs 20 interleaved rounds (AGENTS.md, "A speed
  feature pays for its lines").
- **The bar is tsrs 0.18.0 as shipped.** Its like-for-like line is
  "Go mode": `TSRS_LAZY_DTS=0 --checkerAssignment go --noLazyMembers`.
- **The standings** are the `tsrs-standing-N.md` records in
  [hash-race/](../history/records/2026-10/hash-race/); the newest is
  the current one.

## What is known (measured; do not measure again)

1. **Trig does the same work as tsrs in Go mode,** object for object:
   on ts-pattern, 954,642 symbols against 953,714, and the same
   instantiations ([mem-walk.md](../history/records/2026-10/memory/mem-walk.md)).
   Shipped tsrs skips work: lazy member tables, lazy binding of `.d.ts`
   files, and its own checker assignment. That is its largest lead
   ([next-win-ranking.md](../history/records/2026-10/perf-stage/next-win-ranking.md)).
   Skipping the tables alone, without doing what tsrs does in their
   place, measured slower, so a port measures tsrs's switches one by one
   first.
2. **Checker cycles by family:** relations, members and properties, and
   types from nodes lead the gap; name resolution and flow match tsrs in
   calls and lose on cost per call. The relation cache's path is level
   with tsrs
   ([gap-map-v2.md](../history/records/2026-10/perf-stage/gap-map-v2.md),
   [instantiation-members.md](../history/records/2026-10/perf-stage/instantiation-members.md),
   [map-hash-calls.md](../history/records/2026-10/perf-stage/map-hash-calls.md)).
3. **Extra calls:** `get_property_of_type_ex` runs 1.8-2.25 times
   tsrs's calls, cause not yet found; count it by call site
   ([four-checkers/](../history/records/2026-10/perf-stage/four-checkers/)).
4. **The head** (wall less check): load and bind run behind tsrs at one
   checker, and further behind at four, partly from each file call's hop
   to the blocking pool
   ([head-phases.md](../history/records/2026-10/perf-stage/head-phases.md),
   [load-phase.md](../history/records/2026-10/perf-stage/load-phase.md)).
5. **Memory by kind:** against Go mode, Trig's caches are larger and it
   keeps more mappers; its symbols are smaller. Page faults are a real
   cost ([mem-census.md](../history/records/2026-10/memory/mem-census.md),
   [mem-walk.md](../history/records/2026-10/memory/mem-walk.md)).

## Where things are

- **Trig:** `~/Data/Code/trig`, the owner's checkout, never edited;
  worktrees in `~/Data/Code/worktrees/trig/`. Its gate is `tools/light`
  before any merge (AGENTS.md, step 6).
- **tsrs:** source on pup in `/zfs/trig-pup/tsrs/src`; the shipped
  binary is `/zfs/trig-pup/tsrs-shipped/package/tsrs`.
- **Projects:** `pup:/zfs/trig-pup/full/trig/misc/projects/`
  (ts-pattern, zod3, mitt, neverthrow, superstruct, tiny-invariant).
- **Timing:** Trig's `tools/cli/bench`, its PGO build `tools/trig/pgo`,
  and on pup `/zfs/trig-pup/trial/time-ab.sh` (a seeded shuffle each
  round). Time on pup's P-cores; run everything else on E-cores 12-19.
  Release builds go through `sh /zfs/trig-pup/trial/slot.sh`. pup's
  `/tmp` is a shared 16 GB tmpfs, so binaries live on `/zfs`.
- **Data a record cites but does not keep** is on pup in
  `/zfs/trig-pup/records-data/`.

## Do not redo

Each of these was measured and closed:

- Allocator and memory micro-slices, each 0.3-6 MiB: prefault
  ([prefault-lead/](../history/records/2026-10/prefault-lead/),
  [fault-used.md](../history/records/2026-10/perf-stage/fault-used.md)),
  table coloring
  ([stlb-aliasing.md](../history/records/2026-10/perf-stage/stlb-aliasing.md)),
  large-block slack
  ([large-blocks.md](../history/records/2026-10/perf-stage/large-blocks.md)),
  and heap overhead
  ([heap-residency.md](../history/records/2026-10/memory/heap-residency.md)).
- Store-forward stalls: removing 38-49% of them saved 0.1-0.7% of
  cycles
  ([four-checkers/store-forward.md](../history/records/2026-10/perf-stage/four-checkers/store-forward.md)).
- Map calls out of line, which were accounting
  ([map-hash-calls.md](../history/records/2026-10/perf-stage/map-hash-calls.md)).
- Loop bounds checks
  ([loop-hoist.md](../history/records/2026-10/perf-stage/loop-hoist.md),
  [codegen-gap.md](../history/records/2026-10/perf-stage/codegen-gap.md)).
- Profile-guided optimization trained on a broad corpus, which was
  slower ([timing-audit/harness.md](../history/records/2026-10/timing-audit/harness.md)).
- The relation cache's key and path, sparse links tables, re-checked
  optionals and tags, and parse-time atoms; the
  [records' index](../history/records/INDEX.md) has each.
