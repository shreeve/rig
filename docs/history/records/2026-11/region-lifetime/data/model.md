# Region model, pass A (region brief §(e) step 1), 2026-11-24

**Verdict: STOP.** At typeorm c4 the ideal hint (I) saves −7.5 MiB at the peak with whole pages and +5.9 MiB at best
with lazily touched pages. Trig's peak there is 240.9 MiB, so that is −3.1% or +2.4%, both under 3%.

## What was run
- Trig main 8ad4c8b9 (#547, Rig pin b4d9e7247), in a worktree of burst's trig-main (now removed).
- **Heap-log build.** The tid event-log Rig was rebuilt in its own dir: heapmiss's runtime-new.zig plus rigtid's three
  sed lines. The build is rfrag's build-hlog-tid.sh with RIG re-pointed.
- **Plain build.** `setup1123/build.sh`: meteorlake, 32 units, stripped.
- **tsrs.** 0.23.0 from the shipped tgz. Its sha256 (4bb990f7…) matches pup's `/zfs/trig-pup/tsrs-0.23.0/package/tsrs`.
- **Runs.** 9 heap-log runs at once, one per project × count. Each ran in its own cpuq job on its own 6 CPUs
  (taskset 42-47, 48-53, … 90-95). Every run gave 6 thread ids at c4/c8 (6 heaps) and 1 at c1.
- **Speed.** Each run took 1–5 s and each log 27–291 MB, so no sampling was needed. Outputs were the same as
  rss-frag's (md5 a4c9486a, d41d8cd9, b7148b1e).
- **RSS.** The 9 cells ran at once, on the same 6-CPU sets: 3 rounds × (Trig, tsrs exact, tsrs default). Peak RSS is
  `/usr/bin/time %M`. Every output was identical between Trig and tsrs.

## The model (`region-model/hpage.cc`, extends hfragh)
**Heaps and pages.** A heap is a thread id. Each class carves 64 KiB pages, its free list is LIFO, and the free list
is taken before carving. A block's heap is the heap of the thread that made it, as in hfragh.

**Pool.** A page whose blocks are all free goes to its heap's pool, and any class takes from the pool before carving.
The model unlinks the page's blocks from its free list lazily, by generation.

**Footprint.** F(t) is the small classes' segment bytes plus the live large bytes.
- `page`: (pages carved − pages in the pools) × 64 KiB, as the brief specified.
- `keep`: pages carved, with pool pages kept resident and reused.
- `touch`: each page's carved bytes rounded up to 4 KiB. This is an optimistic bound: no prefault and no huge pages.

`page` is the realistic accounting for Rig here. burst's THP is `madvise`, and Rig asks for huge pages for segments
and prefaults pages after a class's first, so a carved page is resident.

The saving is M's peak F minus the arm's peak F. Each arm's peak is wherever its own maximum falls.

**Arms.**
- **M:** today's allocator.
- **Mp:** M plus the pool.
- **I:** Mp, plus a block goes to its class's transient pages if it was made during the load and is dead by M's peak.
  Transient free blocks serve only transient requests.
- **P:** Mp, plus every block made during the load, by any thread, goes to transient pages.
- **Pm:** P, but after the load a normal request may take a transient free block before carving.
- **I2, P2:** I and P with the load ending at the bind's end instead.

**Load window.** It is set from the site names (hsym.py), not by event count:
- start: the first block made by a site with `process_all_program_files` in its frames;
- end: the last block made by any `FileLoader.*` site, which includes the walk (`collect_file`);
- end2: the last block made by a bind site.

On typeorm c1 the window is 401412..2691601, and the walk is 2670889..2691220 (rss-frag had 2.605M on 5061f67b). The
checker's first block is at 2938068. Every cell's markers are in `*/marks`.

**Validation.** M's free blocks at the live peak, computed as HWM − live, are 2.09 MiB for typeorm c1 (rss-frag: 2.1)
and 1.32 for date-fns c1 (rss-frag: 1.3).

## Results (MiB; `region-model/summary.txt`)
| cell | Trig | tsrs | I page | I touch | P page | P touch | Mp page | ratio now | with I page / touch | with P page |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typeorm c1 | 221.0 | 191.6 | 1.75 | 1.53 | −3.88 | −2.31 | 0.50 | 1.153 | 1.144 / 1.145 | 1.174 |
| typeorm c4 | 240.9 | 224.5 | −7.53 | 5.85 | −16.12 | −5.91 | 4.88 | 1.073 | 1.107 / 1.047 | 1.145 |
| typeorm c8 | 285.6 | 235.6 | 0.53 | 9.59 | −19.88 | −9.03 | 2.69 | 1.212 | 1.210 / 1.172 | 1.297 |
| date-fns c1 | 159.7 | 140.8 | 1.25 | 1.05 | −3.44 | −2.05 | 0.31 | 1.134 | 1.125 / 1.126 | 1.158 |
| date-fns c4 | 200.2 | 161.8 | −8.16 | 3.40 | −13.22 | −2.48 | 1.56 | 1.238 | 1.288 / 1.217 | 1.319 |
| date-fns c8 | 217.5 | 178.5 | −10.87 | 3.65 | −19.06 | −6.74 | 3.88 | 1.219 | 1.280 / 1.198 | 1.325 |
| Compiler c1 | 73.2 | 51.0 | −1.37 | 0.21 | −2.94 | −0.24 | 0.38 | 1.435 | 1.462 / 1.431 | 1.492 |
| Compiler c4 | 119.2 | 68.0 | 0.63 | 1.13 | −6.54 | 0.48 | 5.84 | 1.753 | 1.744 / 1.736 | 1.849 |
| Compiler c8 | 128.4 | 75.6 | 1.44 | 0.93 | −8.76 | −0.30 | 3.24 | 1.698 | 1.679 / 1.686 | 1.814 |

- tsrs in the table is exact (`--checkerAssignment go --noLazyMembers`). tsrs default is within 3.2 MiB of it in every
  cell.
- Ratio = (Trig − saving) / tsrs.
- I2 is the same as I. P2 is at least as bad as P everywhere except typeorm c4, where P2 is −12.3 and P is −16.1.
- Pm is less bad than P, but still negative wherever P is.

## Why
1. **The c4/c8 peak is the load's end.** It is, or is nearly, where every transient is still live:
   - date-fns c4 and Compiler c4/c8: M's peak is at the load's end.
   - typeorm c4: F at the load's end is 144.5, against 155.6 at the end of the check.

   So separating transients cannot lower the peak. The free blocks rss-frag found at the end of the check are real
   (at typeorm c4, I cuts F at M's peak from 155.6 to 140.0). But the peak then moves to the load's end, which I
   raises from 144.5 to 159.7.
2. **Splitting costs pages.** Each heap × class gets a second open page. Transient and survivor blocks can no longer
   reuse each other's free slots during the load. With 6 heaps that costs more than it frees. With lazily touched
   pages the cost is small, so I is positive under `touch`, but it is under 3% everywhere (at most 9.6 MiB, typeorm c8,
   3.4%).
3. **P is worse in every cell.** Survivors made during the load (file names, path ids, AST lists, package directories)
   pin the transient pages. Survivors do not die, so P's extra pages stay to the end.
4. **Mp, the pool alone with no hint, does better than I in most c4/c8 cells.** It saves 4.9 MiB at typeorm c4, 5.8 at
   Compiler c4 and 3.9 at date-fns c8, all under `page`. That is NEEDS 88's other half: wholly free pages back to any
   class on each heap. Rig's per-class intrusive free lists would need per-page free counts and unlinking (trimIdle
   already counts per page). Even Mp is under 3% of typeorm c4 (2.0%).

## Caveats
- The model's heap is the thread id. Rig hands a heap from an ended thread to the next one that starts, but every run
  kept the same 6 or 1 thread ids for its whole life.
- Remote frees count as free at once (hfragh does the same).
- Large blocks count as live bytes, and spans' kept and cold memory is not modelled. The large term is the same in
  every arm, so it only moves where the maximum falls.
- RSS on burst is not pup's; burst's notes say no timing there, and this was RSS only. Trig's c4/c8 swings up to 10 MiB
  between rounds.

## Files (`~/Data/Code/Claude/rig/rig/endstate/region-model/`)
- `summary.txt` and `rss.tsv` (every RSS row).
- One dir per cell, each with:
  - `m.arms`: every arm under `page`, `keep` and `touch`, and F at the load's start and end, the bind's end, M's peak
    and the live peak;
  - `m.cls`: pages in use by class at M's peak;
  - `marks`, `model.txt` and `err`.
- The scripts: `hpage.cc`, `hmark.cc`, `marks.sh`, `model.sh`, `hlrun.sh`, `rss.sh`, `setup.sh` and
  `build-hlog-tid.sh`.
- The burst dir `~/cpuq/tmp/regionmodel` and its trig worktree are removed, and no rig:regionmodel job is running.
