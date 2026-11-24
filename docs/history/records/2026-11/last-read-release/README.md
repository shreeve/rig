# Releasing a file's front-end records during the check, measured: an oracle ceiling, no sound floor yet (2026-11-24)

Measured first, nothing built. The Trig session measured this, read only, at the request of Rig's region discussion.

**The question.** The region discussion (the end-state design's decision 2, approved by the owner on 2026-11-24) had
lost its first case: the load's lifetime (record region-lifetime). The second candidate was item 4's program step:
release a file's tree, positions, text and binder records during the check, once no checker will read them again.

**What was used.**
- Trig main 8ad4c8b9, Rig pin b4d9e7247.
- Census builds on burst, on scratch commits in Trig, local only.
- Trig's full write-up is data/census.md. The per-cell model reports are data/*.txt. The patches, hooks and model are
  in tools/.

## Result in one paragraph

**The ceiling is large.** An oracle that frees each file at its reader's next file boundary after its last actual read
takes 24–32% off Trig's peak at one checker on typeorm, nuxt, webpack and supabase-studio, and 6–19% at four. Summed,
Trig/tsrs goes from 1.037 to 0.741 at c1 and from 0.986 to 0.885 at c4. Unlike the load's lifetime, the peak really
falls, because it sits at the run's end (c1) or deep in the check (c4).

**No rule that decides at run time is sound in Trig today.** Two rules were tried:
- **floor 1:** a module file no file includes, released when its own check ends;
- **floor 2:** a file released once every checked file that can reach it over the transitive include graph has ended.

Both read poisoned records on typeorm, nuxt and supabase. Three read paths cause it.

**If Trig closed those paths,** the floors would reach 2–7 points of summed Trig/tsrs, where Trig is already level with
tsrs or below. Rig: parked. It is reported to the owner with no arena-rule discussion opened.

## 1. Method (data/census.md, "Method" and "Sound floors")

**Hooks.** All 731 functions in `ast.zig` that name a tree's private fields are hooked, plus the Binding and the binder
record readers. Each read is stamped on a check-progress clock, per thread, with RSS sampled every millisecond.

**The model.** RSS falls by the bytes freed, assuming perfect reuse:
- **The oracle** frees each (file, kind) at the next file-check start or end on each thread that read it, after its
  last read.
- **The floors** free at the point their rule allows, on the same runs' events, bytes and RSS curve.

**Never released:**
- bundled libs and global scripts;
- files with a module augmentation, `declare global`, an ambient module or `export as namespace`;
- files reached through `/// <reference>` or type directives;
- for floor 2, anything a pinned file reaches.

**Kept to the end:** the text of files with a diagnostic or a comment directive, files the report reads for line
maps, and the bind diagnostics.

**The poison replay.** Released tree, positions, text, names and Binding lists are overwritten with 0xA5, and every
hooked read of a released kind is trapped with its stack. A rule is sound on a run only if stdout equals main's and no
trapped read is anything but benign.

## 2. A soundness warning

The first validation released each record right after its last read. **Text broke:** typeorm printed TS2307 errors for
module names read as 0xA5 bytes, because the checker keeps a view of a file's text across calls
(`resolve_external_module` holds the name while it resolves).

So a release is sound only at points where no check holds a view, such as file boundaries. Any capability Rig built
for this would have to enforce such a point, not trust a read count. Every figure below uses file boundaries.

## 3. Reach: MiB off Trig's peak, with Trig/tsrs after

Trig's peak and tsrs's (arm G) are from race 753 on pup. Burst's peaks match pup's to about 2%.

| cell | Trig/tsrs now | oracle | floor 1 | floor 2 | replay floor 1 / floor 2 |
|---|---:|---:|---:|---:|---|
| typeorm c1 | 1.121 | 68.2 (0.765) | 32.8 (0.950) | 44.6 (0.888) | FAIL / FAIL |
| nuxt c1 | 1.060 | 79.0 (0.808) | 14.8 (1.013) | 30.6 (0.962) | FAIL / FAIL |
| webpack c1 | 1.102 | 90.6 (0.813) | 6.1 (1.083) | 9.4 (1.072) | pass / pass |
| supabase-studio c1 | 0.993 | 299.2 (0.692) | 31.4 (0.962) | 43.4 (0.950) | FAIL / FAIL |
| Compiler c1 | 1.173 | 5.2 (1.083) | 0 | 0 | pass / pass |
| typeorm c4 | 1.030 | 34.6 (0.884) | 18.9 (0.950) | 20.8 (0.942) | pass (fails at c1 on the same path) / FAIL |
| nuxt c4 | 0.993 | 88.1 (0.783) | 9.8 (0.970) | 19.0 (0.948) | released records read / released records read |
| webpack c4 | 0.916 | 36.4 (0.825) | 2.5 (0.910) | 3.0 (0.909) | pass / pass |
| supabase-studio c4 | 0.996 | 86.6 (0.933) | 19.1 (0.982) | 30.7 (0.974) | FAIL / FAIL |
| Compiler c4 | 1.315 | 0.1 | 0 | 0 | pass / pass |

c8 was modelled but not replayed (data/census.md). Compiler-Unions is like Compiler.

**Summed over the four large projects:**

| count | Trig/tsrs now | oracle | floor 1 | floor 2 |
|---|---:|---:|---:|---:|
| c1 | 1.037 | 537 MiB, 0.741 | 85 MiB, 0.990 | 128 MiB, 0.967 |
| c4 | 0.986 | 246 MiB, 0.885 | 50 MiB, 0.965 | 74 MiB, 0.955 |
| c8 | 0.933 | 295 MiB, 0.831 | 51 MiB, 0.916 | 79 MiB, 0.906 |

**Where the oracle's bytes are.** The tree and its positions are 65–89% of the c1 reach. Most of it is in imported
files: node_modules declaration files and imported project sources. Leaf project files give 6–33 MiB at c1. Bundled
libs give ≤3 MiB, because they are read to the end. At supabase c4, text alone is 40 of 87 MiB.

## 4. The read paths that make the floors unsound

1. **Type printing scans every module's exports.** `symbol_to_type_node → get_symbol_chain →
   get_alternative_containing_modules → build_external_module_container_index` walks the exports of every external
   module on its first use in each checker. So any module file can be read after its last importer is done.
2. **Checker-wide caches carry types between unrelated files.** Two leaf test files that share no import read each
   other's declarations: `create_union_or_intersection_property` reads modifier flags, `get_named_members` reads
   `symbol_sort_key` positions, `property_related_to` reads symbol flags. No include graph sees this.
3. **Synthetic node ids read a file's node count.** Benign: a real release would keep the count.

## 5. What would have to change, on Trig's side first

- **Path 1:** build each checker's module-container index before any release, or keep a per-module export summary
  that outlives it.
- **Path 2:** keep, per released declaration, what the caches read later (symbol flags, modifier flags, positions for
  ordering), or pin every file whose types entered a checker-wide cache.
- **Path 3:** keep node counts.
- **Layout:** about half the tree bytes are in files with under 64 KiB of tree, which share small-class pages. Reaching
  the floors needs contiguous per-file ranges (end-state item 5) or a per-file region.
- **On Rig's side,** only after all that: releasing part of a frozen program that checker tasks hold on read loans
  (CORE sentences 6–7), and a debug build that traps on a read of a released record.

## Decision

Rig: parked.
- Today's sound reach is a few MiB (webpack).
- After Trig's summary work, the floors give 2–7 points of summed Trig/tsrs at c1 and 2–3 at c4 and c8, where Trig is
  already level with tsrs or below. That does not justify opening the arena rule.
- Rig reports it to the owner with the ceiling and floors, defaulting to no discussion now.
- The three read paths go in Trig's NEEDS as Trig's to note. None of this becomes Rig work unless the owner reopens it.
