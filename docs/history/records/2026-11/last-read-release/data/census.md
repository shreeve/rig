# Last-read census: how far releasing front-end records during the check could lower the peak (2026-11-24)

Measure only (DESIGN.md default 3; items 4 and 5). Nothing lands, nothing in Rig changed. Scratch branch
`scratch/lastread` (73bc36fe, 2570d4f0, then 8ef2cb46 and d1b7a5a5 for the floors; local only, not pushed) in `~/Data/Code/worktrees/trig/lastread`, on main
8ad4c8b9, Rig pin b4d9e7247. Runs on burst (`cpuq run --label trig:lastread`), no pup. Tools and data:
`lastread-census/` beside this file (`tools/`, `data/`).

## Answer

**c1: the ceiling is 24-32% of Trig's peak on the four large projects; c4: 6-19%.** Compiler and Compiler-Unions:
7% at c1, nothing at c4. It is a ceiling (perfect reuse, a file freed whole at its reader's next file boundary).

| cell | Trig peak, pup (B, race 753) | ceiling MiB | % of Trig's peak | % of tsrs's peak | Trig/tsrs now | after |
|---|---:|---:|---:|---:|---:|---:|
| typeorm c1 | 214.5 | 68.2 | 31.8 | 35.7 | 1.121 | 0.765 |
| nuxt c1 | 331.6 | 78.8 | 23.8 | 25.2 | 1.060 | 0.808 |
| webpack c1 | 345.5 | 90.5 | 26.2 | 28.9 | 1.102 | 0.814 |
| supabase-studio c1 | 987.8 | 299.0 | 30.3 | 30.1 | 0.993 | 0.693 |
| Compiler c1 | 67.8 | 5.2 | 7.7 | 9.0 | 1.173 | 1.083 |
| Compiler-Unions c1 | 67.9 | 4.9 | 7.2 | 8.3 | 1.151 | 1.068 |
| typeorm c4 | 244.1 | 36.9 (27.5-38.8) | 15.1 | 15.6 | 1.030 | 0.874 |
| nuxt c4 | 417.2 | 79.0 (73.7-102.3) | 18.9 | 18.8 | 0.993 | 0.805 |
| webpack c4 | 366.3 | 34.1 (17.2-44.3) | 9.3 | 8.5 | 0.916 | 0.831 |
| supabase-studio c4 | 1368.8 | 79.1 (78.7-85.6) | 5.8 | 5.8 | 0.996 | 0.939 |
| Compiler c4 | 106.1 | 0.3 | 0.3 | 0.4 | 1.315 | 1.311 |
| Compiler-Unions c4 | 104.6 | 0.5 | 0.5 | 0.6 | 1.239 | 1.234 |

- Ceilings are burst MiB (c1 one run, deterministic; c4 the median of 3 runs, range in brackets). Burst's peaks
  match pup's within ~2%: c1 213.4 / 328.0 / 339.6 / 989.6 MiB against pup's 214.5 / 331.6 / 345.5 / 987.8.
- tsrs is race 753's arm G (b545.runs, median rss_kb of 11): c1 191.3 / 312.8 / 313.4 / 994.4 / 57.8 / 59.0, c4
  237.0 / 420.1 / 399.8 / 1374.2 / 80.7 / 84.4 MiB. "After" = (Trig's pup peak - ceiling) / tsrs's.
- Four large projects summed: c1 536.5 of 1879.4 MiB (28.5%; Trig/tsrs 1.037 -> 0.741); c4 229.1 of 2396.4 MiB
  (9.6%; 0.986 -> 0.891).

**Worth an owner discussion: yes.** It is the largest memory lever measured so far, far past the 6-10% bar at c1 and
at or past it at c4 on typeorm and nuxt. What it needs is in "What a release capability would need" below.

## When the peak happens, and whether the load's end becomes the new peak

| cell | peak today | new peak, with release | load-end level | new peak above the load end |
|---|---|---|---:|---:|
| typeorm c1 | 213.4, end of run | 145.1, 69% through the check | 135.2 | +9.9 |
| nuxt c1 | 328.0, end of run | 249.2, 33% | 221.1 | +28.1 |
| webpack c1 | 339.6, end of run | 249.0, 61% | 181.5 | +67.5 |
| supabase c1 | 989.6, end of run | 690.6, 80% | 603.9 | +86.7 |
| Compiler c1 / CU c1 | 66.2 / 66.6, end | 61.1 / 61.7, 81% / 87% | 48.8 / 42.6 | +12.3 / +19.1 |
| typeorm c4 (3 runs) | 235-244, 56-80% | 198-214, 27-35% | 187-193 | +5 to +27 |
| nuxt c4 | 415-459, 70-94% | 336-357, 26-85% | 306-313 | +30 to +44 |
| webpack c4 | 357-391, 45-86% | 340-346, 43-74% | 233-239 | +105 to +108 |
| supabase c4 | 1333-1363, 66-79% | 1253-1277, 66-79% | 741-753 | +500 to +524 |
| Compiler c4 / CU c4 | 101-113 / 105-111, 53-82% | the same (-0.1 to -0.5) | 83-90 / 83-86 | +17 to +24 |

- **Every cell's peak today is inside or after the check, never at the load's end**, so releasing during the check
  can lower it in every cell. At c1 the peak is the run's end: nothing is let go, and the checker grows to the end.
  At c4 it is inside the check (45-94% through), where the four checkers are at their largest, before they drop.
- **The load-end level never becomes the new peak.** The closest are typeorm c4 (5-27 MiB under the new peak) and
  typeorm c1 (10 MiB). There, the rest of the reach is the load end's (Rig 2's region model: typeorm c4's
  small-class load end), not the check's. Compiler and Compiler-Unions at c4: the peak is in the check but nothing
  is free yet (every file is a global script that some checker reads until near its end).
- RSS is sampled every 1 ms from the program's start (statm), so "load-end level" is the most RSS before the census
  mark (the program made, before the checkers).

## What is releasable, by kind, category and leaf

Front-end bytes held today (MiB, at the load's end; the same at every count):

| project | files | tree | positions | text | names (per file) | binding | program binder records | total | program names (not per file) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typeorm | 3575 | 41.4 | 10.2 | 13.2 | 0.7 | 7.4 | 6.3 | 79.3 | 2.1 |
| nuxt | 3705 | 76.2 | 19.4 | 24.7 | 1.5 | 14.6 | 15.3 | 151.7 | 4.7 |
| webpack | 1607 | 71.6 | 18.2 | 20.3 | 1.3 | 14.1 | 11.2 | 136.7 | 3.9 |
| supabase-studio | 12546 | 204.2 | 50.9 | 70.6 | 4.9 | 38.5 | 43.2 | 412.2 | 12.6 |
| Compiler | 53 | 13.5 | 3.4 | 4.8 | 0.1 | 3.1 | 1.3 | 26.3 | 0.9 |
| Compiler-Unions | 48 | 12.4 | 3.2 | 4.4 | 0.1 | 2.8 | 1.2 | 24.1 | 0.7 |

The tree is half of it (50-52%), text 15-17%, positions 12-13%, the binder 17-20%, names about 1%. The program's
interned names are one table for the whole program, not per file, so they are left out.

**Ceilings if only part were released** (MiB, the same model; parts don't add up, since the peak moves):

| cell | all | tree+pos | text | binder | leaf files | imported files | leaf project sources | bundled libs | node_modules .d.ts | project sources |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typeorm c1 | 68.2 | 47.1 | 12.4 | 12.5 | 39.6 | 32.6 | 32.8 | 0.7 | 11.7 | 58.6 |
| nuxt c1 | 78.8 | 70.2 | 22.0 | 25.2 | 21.1 | 76.3 | 14.9 | 0.7 | 77.5 | 31.2 |
| webpack c1 | 90.5 | 71.0 | 12.8 | 20.3 | 18.5 | 82.4 | 6.3 | 3.1 | 20.4 | 79.9 |
| supabase c1 | 299.0 | 194.4 | 68.4 | 75.8 | 56.0 | 281.6 | 31.4 | 1.1 | 195.0 | 139.6 |
| typeorm c4 (3 runs) | 27.5-38.8 | 19.1-28.9 | 8.6-9.6 | 7.9-9.0 | 15.5-25.5 | 18.1-21.7 | 12.0-19.6 | 0.2-0.4 | 9.2-10.1 | 22.3-29.9 |
| nuxt c4 | 73.7-102.3 | 61.3-68.2 | 16.9-20.3 | 19.4-23.5 | 15.8-18.3 | 71.0-88.8 | 12.0-12.8 | 0.2 | 73.0-81.4 | 22.3-28.2 |
| webpack c4 | 17.2-44.3 | 12.1-30.8 | 3.5-8.9 | 3.3-16.7 | 3.1-12.5 | 14.5-37.8 | 0.8-2.6 | 0.2-0.4 | 5.8-18.2 | 13.0-32.9 |
| supabase c4 | 78.7-85.6 | 32.3-35.6 | 40.1-43.5 | 3.4-3.5 | 19.8-22.3 | 58.6-63.6 | 2.7-4.8 | 0.3 | 47.8-48.8 | 30.6-36.5 |
| Compiler c1 / CU c1 | 5.2 / 4.9 | 2.9 / 2.9 | 2.0 / 1.6 | 1.6 / 1.2 | all leaf | - | 5.1 / 4.8 | 0.3 | - | 5.1 / 4.8 |

- **The tree (with its positions) dominates at c1 and on nuxt/typeorm at c4.** At supabase c4 text (40) and
  positions (26-29) carry it: some checker reads nearly every tree until late, but the text and positions much
  less. So text alone, kept in pages the kernel can take back (item 4), reaches 12-68 MiB at c1 and 4-43 at c4.
- **Leaf project files are a minority** of the reach: 6-33 MiB at c1, 1-20 at c4. Most of it is in imported files:
  node_modules declaration files (nuxt, supabase) and imported project sources (webpack, typeorm).
- **Bundled lib .d.ts files are not releasable** (at most 3 MiB): the checker reads them to the end.
- **When things become free** (MiB freed by 0 / 25 / 50 / 75 / 100% of the check pass; c1 and c4 run 1):
  typeorm 2.4 / 10.7 / 30.7 / 49.2 / 79.3 and 2.4 / 13.4 / 41.8 / 58.3 / 79.3; nuxt 9.8 / 13.7 / 78.5 / 90.2 / 151.7
  and 9.8 / 12.1 / 79.3 / 109.2 / 151.8; webpack 0 / 6.5 / 15.9 / 56.4 / 130.6 and 0 / 4.6 / 8.8 / 46.6 / 130.7;
  supabase 29.1 / 139.8 / 186.8 / 234.7 / 412.2 and 29.1 / 43.3 / 60.9 / 84.1 / 412.4. The 0% column is files no
  check reads at all; what is left at 100% is read in the report (the text of files with diagnostics: webpack 6.2,
  Compiler and CU 2.9 MiB).

## Method

**Hooks (scratch commits on main 8ad4c8b9, `tools/census2.patch`).**
- `debug.lr_touch(file, kinds)`, `lr_event`, `lr_bytes`: empty Rig subs. The census build's Zig fills them in.
- `Ast.census`: the file's index plus one, set when the program is made (`Program.census_report`, called in
  tsc.rig after `names.fit()`), with each file's bytes by kind and a line per file: lib, declaration, import targets
  (`resolution_files`), name.
- **Tree, positions, text, names:** `tools/lastread-zig` (a `ZIG` for `rig build`, modeled on ledger-zig) patches
  `ast.zig`. Every function with an Ast or File parameter that names a tree's own fields (`recs`, `words`, `lists`,
  `list_nodes`, `texts`, `text_lists`, `facts` = tree; `locs` = positions; `text_bytes` = text; `name_ids`,
  `text_atoms` = names) notes those kinds for that tree at its entry: 731 functions. The fields are private to the
  `ast` module, and no generated file but ast.zig names them (checked), so every read goes through a hooked
  function. Five functions name them with no tree parameter: constructors and the prebuilt encode/decode (load and
  build time).
- **Binding:** the checker's 41 reads of `program.bindings[f]` go through `Program.binding_at(f)`, which notes the
  read; also the printer's name generator.
- **Program binder records:** `Ids.binder_sym`, `binder_tab`, `tab_file_of`, `local_tab` note the record's file.
- **Bind diagnostics apart:** the program reads every file's bind diagnostics after the pass. That is noted as a
  kind of its own (64) and kept out of "binding", since it is a list apart from the symbols, tables and flow nodes.
- **Clock:** a ticker thread keeps an epoch (1024 ns units) and samples RSS every 1 ms. A touch stores the epoch for
  (file, kind), globally and per thread (`tools/lr3.zig`). Events mark the census (the load's end), the pool, the
  pass, each file's check start/end with its thread, and the report.
- **Bytes:** each list at its length × its record's size (project files' lists are fitted, so length = capacity);
  a Map at 16 B an entry; the program's BinderSym (32 B) and TabLoc records for the file's id range.

**Model (`tools/lrana.py --safe`).** Each (file, kind) is freed at its reader's next safe point: for each thread that
read it, the next file-check start or end on that thread after its last read (none: at the read), the latest over
threads; or at the load's end if no check reads it. RSS falls by the bytes freed (perfect reuse):
new(t) = RSS(t) - freed(t). The peak today is the most RSS sampled; the ceiling is that minus the most new(t).
Release at the bare last read gives the same at c1 and up to 10 MiB more at c4 (nuxt 89.1 against 79.0).

**Why safe points.** A first validation pass freed each record right after its last read, touch by touch: text
broke (typeorm printed TS2307 errors for module names read as 0xA5 bytes). The checker holds a view of a file's text across calls
(`resolve_external_module` keeps the module name it was given while it resolves). A release must therefore wait for
a point where no check holds a view, such as the end of a file's check.

**Exactness.** The census builds' stdout equals main's on all six projects at c1 and c4, in every run (cen, cen2,
cen3 × 3, and both validation passes).

**Validation of the hooks** (`tools/poison.sh`, the poison build `tools/lastread-zig-p` + `lrp.zig`, c1):
- Pass 1 records each (file, kind)'s last touch number.
- Pass 2 replays and overwrites the file's tree, positions, text and names with 0xA5 at the first file-check
  boundary after that number, libs included.
- All six projects print main's bytes: typeorm, nuxt, webpack, supabase-studio, Compiler, Compiler-Unions.
- 0 touches of an overwritten record. Releases done: 14289 of 14300, 14819 of 14820, 6157 of 6428, 50182 of 50184,
  199 of 212, 178 of 192. The rest are read at the end or in the report.
- A read the hooks missed would have read 0xA5 bytes, an invalid Kind in a ReleaseSafe build.
- The binder's records were not overwritten (no pointer from Zig). Their hooks are by construction: every checker
  read goes through `binding_at` or `Ids`.

**Runs.**
- One-unit native builds (a split build would give each unit its own copy of the census state).
- c1: `--singleThreaded` on one core and its sibling. c4: `--checkers 4` on 6 cores and their siblings (pup's six
  P-cores: 4 checker threads, 6 workers).
- The instrumented runs are 1.2-1.6× slower. c4's interleaving is timing-dependent, hence 3 runs.
- Main's own burst runs (3 each) are in `data/base-rss-kb.txt`.

## What a release capability would need (for the owner's discussion)
1. **A way to release part of a frozen program that checker tasks hold on read loans**, at safe points (file
   boundaries), with proof that no later read exists. The census shows views held across calls, so the release
   cannot be per read. At c4 it is the latest reader's boundary.
2. **Page-granular layout.** About half the tree bytes are in files whose tree is 64 KiB or more (typeorm 44%,
   nuxt 64%, webpack 78%, supabase 47%). Small files' lists share small-class pages, so reaching the ceiling needs
   item 5's contiguous per-file ranges or a per-file region. The program's BinderSym/TabLoc ranges are contiguous
   by file, in program order.
3. **The cheapest first step is text** (and positions) at c4, through file pages or a separate store: supabase c4
   text alone is 40 of 79 MiB.
4. Bind diagnostics and the text of files with diagnostics outlive the check. They are small, but must stay.

## Files
- `lastread-census/tools/`:
  - the Rig patch (`census2.patch`), lastread-zig, lr.zig / lr3.zig (per thread), lastread-zig-p / lrp.zig (poison);
  - lrana.py (model; `SUMMARY`, `SUBSETS` and `RELEASED` lines), mkpoison.py;
  - run-lr.sh, build-lr.sh, mktree.sh, batch1.sh (cen2), batch3.sh (cen3 × 3), batch-base.sh, poison.sh, poison2.sh.
- `lastread-census/data/`:
  - per cell: `*.txt` (the model's report), `*.curve.tsv` (RSS, new and freed by time);
  - `*.files.tsv.gz`: per file its category, importers, own check end, bytes by kind, last read by kind (ms since the
    check pass began; the "load" mark for none) and the files each checker was checking at its last tree read;
  - c1 is cen2; c4 is cen3 run 1 (curves and reports for all 3).
- burst `~/cpuq/tmp/lastread`:
  - the binaries `base/trig` (main), `cen2/trig`, `cen3/trig`, `cenp/trig`;
  - raw stderr in `runs/` (44 MB) and the tools.
  - Build outputs and trees are removed.

## Sound floors (2026-11-24, for Rig via Rig 2)

**Verdict: neither floor is sound in Trig today.** Under the poison replay, both floors break typeorm, nuxt and
supabase-studio at c1, and supabase at c4; floor 2 also breaks typeorm at c4. Three read paths cause it (below). The
replay passes for webpack, where floor 1 is worth at most 6 MiB, and for Compiler/CU, where nothing is releasable
(every file is a global script). The MiB below are what the floors would reach if those read paths were closed.

### The three columns (MiB off Trig's peak; Trig/tsrs peak after release, race 753 arms B and G)

| cell | Trig peak (pup) | Trig/tsrs now | oracle | floor 1 (leaf) | floor 2 (importers done) | replay floor 1 / floor 2 |
|---|---:|---:|---:|---:|---:|---|
| typeorm c1 | 214.5 | 1.121 | 68.2 (0.765) | 32.8 (0.950) | 44.6 (0.888) | FAIL / FAIL |
| nuxt c1 | 331.6 | 1.060 | 79.0 (0.808) | 14.8 (1.013) | 30.6 (0.962) | FAIL / FAIL |
| webpack c1 | 345.5 | 1.102 | 90.6 (0.813) | 6.1 (1.083) | 9.4 (1.072) | pass / pass |
| supabase-studio c1 | 987.8 | 0.993 | 299.2 (0.692) | 31.4 (0.962) | 43.4 (0.950) | FAIL / FAIL |
| Compiler c1 | 67.8 | 1.173 | 5.2 (1.083) | 0 (1.173) | 0 (1.173) | pass / pass |
| Compiler-Unions c1 | 67.9 | 1.151 | 5.0 (1.066) | 0 (1.151) | 0 (1.151) | pass / pass |
| typeorm c4 | 244.1 | 1.030 | 34.6 (0.884) | 18.9 (0.950) | 20.8 (0.942) | pass* / FAIL |
| nuxt c4 | 417.2 | 0.993 | 88.1 (0.783) | 9.8 (0.970) | 19.0 (0.948) | same bytes, reads seen / same bytes, reads seen |
| webpack c4 | 366.3 | 0.916 | 36.4 (0.825) | 2.5 (0.910) | 3.0 (0.909) | pass / pass |
| supabase-studio c4 | 1368.8 | 0.996 | 86.6 (0.933) | 19.1 (0.982) | 30.7 (0.974) | FAIL / FAIL |
| Compiler c4 | 106.1 | 1.315 | 0.1 (1.314) | 0 (1.315) | 0 (1.315) | pass / pass |
| Compiler-Unions c4 | 104.6 | 1.239 | 0.5 (1.233) | 0 (1.239) | 0 (1.239) | pass / pass |
| typeorm c8 | 283.7 | 1.148 | 52.4 (0.936) | 30.9 (1.023) | 40.6 (0.983) | not replayed |
| nuxt c8 | 493.8 | 1.055 | 15.0 (1.023) | 7.5 (1.039) | 16.2 (1.020) | not replayed |
| webpack c8 | 428.0 | 0.928 | 42.6 (0.836) | 2.7 (0.922) | 2.8 (0.922) | not replayed |
| supabase-studio c8 | 1478.3 | 0.870 | 184.5 (0.762) | 9.6 (0.864) | 19.6 (0.859) | not replayed |
| Compiler c8 | 135.3 | 1.488 | 1.5 (1.472) | 0 (1.488) | 0 (1.488) | not replayed |
| Compiler-Unions c8 | 130.9 | 1.405 | 1.5 (1.388) | 0 (1.405) | 0 (1.405) | not replayed |

- Four large projects summed:

  | count | Trig/tsrs now | oracle | floor 1 | floor 2 |
  |---|---:|---:|---:|---:|
  | c1 | 1.037 | 537 MiB, 0.741 | 85 MiB, 0.990 | 128 MiB, 0.967 |
  | c4 | 0.986 | 246 MiB, 0.885 | 50 MiB, 0.965 | 74 MiB, 0.955 |
  | c8 | 0.933 | 295 MiB, 0.831 | 51 MiB, 0.916 | 79 MiB, 0.906 |

- **Pass** means stdout equals main's under the poison and every trapped read is benign: only the synthetic-node
  path, which reads a List's length, and the length survives the overwrite.
  - \* typeorm floor 1 at c4 passed in this run, but it fails at c1 on the same read path, so it is not sound.
  - nuxt c4 printed main's bytes, but the traps caught reads of released records (79 and 4,593), so it is not sound.
- **Where the MiB come from.** Burst runs of the cen4 build (8ad4c8b9 + scratch commits through d1b7a5a5; tools/census3.patch). c1 is one run; c4 and c8 are the median of 3.
  - The oracle is the model above (per-thread safe points).
  - The floors use `tools/floors.py model`: the same event-driven release as the replay, on the same runs' events,
    bytes and RSS curve.
- **nuxt c8: the oracle is below floor 2.** The oracle counts reads of a file's node count (synthetic node ids) as
  tree reads, which keeps nuxt's declaration files alive near the end. The floors ignore them. Counted as metadata,
  the oracle would be higher.

### The floors as implemented
- **Graph.** Every file's include reasons (import, `/// <reference path>`, type and lib reference directives, from
  the loader's `file_include_reasons`) plus its module resolutions. Reach is transitive: floor 2 works on
  strongly connected components with counters (`tools/floors.py`, `lrf.zig`).
  - It costs O(files + edges), built after the load. Supabase: 10,569 components, 44,039 edges, seconds in Python
    and nothing measurable in the replay. So floor 2 was not dropped.
- **Pinned, never released** (typeorm 142 files, nuxt 246, webpack 213, supabase 599, Compiler/CU all):
  - bundled libs; global scripts (neither ES nor CommonJS module);
  - files with a module augmentation, `declare global`, an ambient module declaration, or `export as namespace`;
  - files included by a `/// <reference path>`, a type reference directive or the automatic type directives.
- **Floor 2 never releases what a pinned file reaches.** A global script can carry a module's types to every file.
  That keeps most declaration files: floor 2 releases nuxt 1,317 of 3,705 files (33.9 of 151.7 MiB) and supabase
  1,279 of 12,546 (57.2 of 412 MiB) by the end.
- **Floor 1:** a checked module file that no file includes and that isn't pinned (typeorm 1,087 files, nuxt 411,
  webpack 144, supabase 781).
- **Release point.** A file is done when its diagnostics have been taken: at its checker's next file check, the
  checker's end, or the pass's end. A group is released when its last reaching checked file is done.
- **Kept to the end:**
  - the text of files whose text is read after every check has ended: files with a diagnostic, files whose
    diagnostics pass through comment directives (`get_diagnostics_with_preceding_directives`), and the files the
    report reads for line maps;
  - the bind diagnostics.
- **Replay** (`lrf.zig`, `LR_FLOOR=table`, cen5: frame pointers and debug info; `tools/floorrun.sh`):
  - The released tree, positions, text, names and Binding lists are overwritten with 0xA5. The Binding's
    diagnostics and Map are not.
  - Any hooked read of a released kind is trapped with its stack, the program binder records included (trap
    only). `tools/viol.py` symbolizes the stacks; results are in `data/floor-replays.txt` and `data/violall.txt`.

### The read paths that break the floors
1. **Type printing scans every module's exports.** When a symbol is written into a type node (diagnostics,
   declaration serialization), the chain `symbol_to_type_node -> get_symbol_chain -> get_containers_of_symbol ->
   get_alternative_containing_modules -> build_external_module_container_index` walks the exports of every external
   module in the program, on first use in each checker. It reads `get_exports_of_symbol`, `symbol_exports` through
   the Binding, `node_symbol` of declarations, and `get_merged_symbol`. So any module file, leaf or not, can be read
   after its last importer is done.
   - Examples: nuxt's eslint.config.mjs read while checking packages/nuxt/src/core/nuxt.ts; supabase's
     instrumentation.ts and @next/bundle-analyzer read while checking CodeEditor.tsx.
   - This path breaks floor 2 on supabase and floor 1 on nuxt and supabase.
2. **Types carried across unrelated files by the checker's shared caches.**
   - A leaf test file's object-literal and union types come back while another leaf file is checked; the two
     share no import. typeorm: query-builders.test.ts read while checking issue-2251.test.ts. nuxt:
     nuxt-link-ssr.test.ts read while checking route-rules.test.ts.
   - The readers: `create_union_or_intersection_property` (modifier and readonly flags of the declarations), then
     `get_named_members -> symbol_sort_key` (declaration positions), then `property_related_to -> symbol_flags`.
   - Reach over the include graph cannot see this. It breaks both floors on typeorm, nuxt and supabase.
3. **Synthetic node ids read a file's node count** (`new_synthetic_node -> Ast.node_count`). Benign: it reads the
   List's length, which a real release would keep in the File. It is most of the trapped reads on nuxt (132,466 at
   c1 under floor 2).

### What a sound floor would need (for Rig's case to the owner)
- **Path 1.** Build each checker's module-container index before any release, or keep a per-module export summary
  that outlives the release.
- **Path 2.** Keep, per released declaration, what the checker's caches read later: symbol flags, modifier flags,
  positions for ordering. That is a declaration summary retained per file, not the whole tree. Or pin every file
  whose types have entered a checker-wide cache.
- **Path 3.** Keep node counts.
- Until those exist, the sound reach measured here is webpack's few MiB. The floors' MiB above are what these two
  rules would give once the paths are closed: 7-15% of Trig's peak at c1 on typeorm and supabase, 2-9% at c4.
