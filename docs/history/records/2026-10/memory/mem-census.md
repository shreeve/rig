# Memory census: Trig against tsrs, by object kind (2026-11-02)

Asked by Rig - Swiss for the owner: Trig's peak RSS is still 38–61% over
shipped tsrs. Measure only; no change lands from this row.

- Trig main 16b97ae (worktree ~/Data/Code/worktrees/trig/main-16b97ae), 1 checker.
- tsrs 0.18.0 shipped (pup /zfs/trig-pup/tsrs-shipped) and Go mode
  (TSRS_LAZY_DTS=0 --noLazyMembers); source in pup /zfs/trig-pup/tsrs.
- Projects: empty, zod3, ts-pattern (pup /zfs/trig-pup/full/trig/misc/projects).

Per kind (AST node, identifier/text, symbol, symbol tables/members, type by
kind, signature, links/side tables, lib file text, lists/maps): count, bytes
each, MiB, both sides. Then: (1) more objects vs bigger objects; (2) the empty
project's 19.7 against 10.5 MiB heap; (3) the top three levers in MiB.

Results: below, by the builder.

## Status: stopped 2026-11-02 ~15:45 (moved to another session)

**Done: the tsrs side** (by kind, at `check end`, the peak), in [mem-census-tsrs.md](mem-census-tsrs.md); the patch, scripts and
tables in [mem-census-data/](mem-census-data/) (`pup-patch/tsrs-census.diff` is the census patch,
`analyze.py` regenerates the tables). The raw runs (`census/`, `shipped/`,
`smaps/`, 20 MB) are on pup in `/zfs/trig-pup/records-data/mem-census/tsrs-raw/`. Every run's output and exit status equal tsc's.

| tsrs, one thread | empty shipped / go | zod3 shipped / go | ts-pattern shipped / go |
|---|---|---|---|
| VmHWM MiB | 16.0 / 20.3 | 44.5 / 57.9 | 161.2 / 206.1 |
| live (arena + heap) MiB | 7.4 / 11.1 | 31.8 / 46.1 | 138.6 / 190.4 |
| arena used / heap live MiB | 3.9 / 3.5 (shipped) | 21.0 / 10.8 | 95.4 / 43.4 |
| file-backed MiB | 6.0 | 8.0 | 8.5 |

ts-pattern shipped by kind (MiB): lists and maps 37.3 (instantiation caches 18.0 on the heap,
`[P<Type>]` 7.2), types 35.4, symbols 15.0 (`Symbol` 32 B), links 12.0, symbol tables 11.6,
mappers 8.2 (`TypeMapper` 16 B), signatures 7.8, AST 4.0, source/lib text 3.5 (lib .d.ts read
into heap, 2.9 MiB on empty). Go mode adds 52 MiB: symbols +15, symbol tables +21, links +8,
AST +5.6, mappers +4. Methods: arena hook by Rust type (live, matches tsrs's arena-used figure),
counting global allocator with stacks resolved by addr2line (matches mimalloc's live figure),
`TSRS_MEM_SPLIT=1` and sampled smaps on the shipped binary for the RSS split.

**Not done:**
- **The Trig side: nothing measured.** No instrumented Trig copy was made. Ready inputs:
  Trig main 16b97ae in `~/Data/Code/worktrees/trig/main-16b97ae`; the field census generators
  `gen-census.py` and `gen-census2.py` and `build.sh` in Trig's
  `~/Data/Code/worktrees/trig/cache-memory/docs/research/19-table-memory-2026-11-01/data/`
  (written for baae9fe; to adapt, and to extend with types by kind, AST nodes, atoms and text);
  Rig's `RIG_HEAP_PROFILE=sites` (INTERNALS "defaultAllocator") for the heap by owner and site;
  the phase-timer patch [head-phases-data/timers.diff](../perf-stage/head-phases-data/timers.diff) for stage markers.
  Rig itself offers no live-heap-bytes query in a release build; a stage snapshot needs the heap
  profile build or /proc/self/smaps classified (Tables reservations, allocator segments, large blocks).
- **Heap by stage (the owner's addition): not done on either side.** tsrs's `--extendedDiagnostics`
  prints only a total ("Memory used"); `TSRS_MEM_SPLIT=1` on the shipped binary gives `parse end`
  (parsed and bound), `check end` and `exit`. The tsrs agent was asked to add load / bind /
  checker-creation snapshots to its copy and was stopped before patching: `/zfs/trig-pup/mem-census/src`
  on pup is a full, unpatched copy of tsrs 280b426b (411M, left in place; the earlier census build
  was deleted, its patch is `mem-census-data/pup-patch/tsrs-census.diff`). Stage points found in the code:
  load ends in `fileloader.rs`; binding is `bind_source_files` in `program.rs`.
- Questions 1-3 (more vs bigger objects, the empty project's heap, top levers): unanswered; they
  need the Trig side.

Reference figures for the new session: standing-7 peak RSS, Trig over shipped tsrs at one checker,
ts-pattern 37.8%, zod3 53.7%, mitt 60.7% (Rig `docs/history/records/2026-10/hash-race/tsrs-standing-7.md`);
tsc at the pin on pup: `/zfs/trig-cache/trig-tsc-build/655f0268afaa43cde07b65b39782688463a99517/tsc/tsc`.
