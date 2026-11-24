# Regions: brief for the end-state decision 2 discussion (2026-11-24)

For Rig. Read only; nothing is built. Sources:
- Trig's NEEDS 88 (origin/main) and Trig's rss-frag study (Trig notes, `rss-frag.md`);
- the Rig records alloc-frag and thp-size;
- `arenas-panel/SYNTHESIS.md` (#1215);
- `docs/CORE.md` (origin/main): sentences 5–7 and 9, and §5.

## (a) The case

**What dies together.** At the end of Trig's load, every busy small class (72–192 B) reaches its high-water mark at
once. The load's transients die by the peak, but blocks made beside them survive and pin their pages:
- Survivors: package directories, path ids, file names, the ASTs' fitted lists.
- Transients: path strings, resolver cache entries, the bind's fitted symbol lists, Binding boxes, package.json reads,
  parse task boxes.

The checkers then allocate in other classes, so those free blocks are never reused.

Free small blocks at the peak, after Trig #545 (rss-frag's heap model, checked against Rig's census to within 5% per
class):

| project | c1 | c4 |
|---|---:|---:|
| typeorm | 2.1 MiB (was 15.7) | 24.9 MiB at the end of the check (burst, 12 heaps; was 34.7) |
| date-fns | 1.3 MiB (was 4.5) | not modelled after #545 |
| Compiler | 0.7 MiB (none to speak of) | not lifetimes: the room is one 64 KiB page per class a small worker heap touches (NEEDS 87) |

**The ceiling against tsrs, typeorm.** Peak RSS, MiB. Trig is the plain post-#545 build on pup; tsrs is from R32 §4.
These are rough, mixed sources; experiment (e) gives the real figures.

| | c1 | c4 | c8 |
|---|---:|---:|---:|
| Trig | 205 | 234 | 276 |
| tsrs | 188 | 226 | 234 |
| Trig / tsrs today | 1.09 | 1.04 | 1.18 |
| Trig / tsrs, every free block reclaimed | 1.08 | ≈0.93–0.98 (pup has 6 heaps, burst 12; not measured at 6) | not modelled |

**Summed over the 16 projects** (race 753: 0.993 / 0.966 / 0.967 / 0.941 of tsrs at c1 / c2 / c4 / c8):
- At c1 the reach is under 0.1 of a point. The three projects modelled hold about 4 MiB free together, against about
  8.6 GB summed.
- At c4 and c8 it depends on how many of the other 13 projects look like typeorm, and we have no numbers for them. Each
  needs a heap-log run (≈1 burst-hour). The cheaper path is (e), which measures all 16 at once.

**So the case is per project at 4–8 checkers,** where typeorm stays above tsrs. The sum is already below tsrs.

## (b) What #1215's `Arena[T]` covers, and where it stops

**Covers.** A typed `*Arena[T]`:
- `!a.add(x)` moves a copying value in and gives a `?T from a`;
- `!a.copy(xs)` copies a slice in;
- no reset; one free when the last handle drops;
- the views it holds of itself are allowed (§5's exception).

**Stops at three places, and the load needs all three:**
1. **Values must copy, and must be finished when added.** The load's transients are growing `List`s (symbol lists,
   task queues), `Map` entries (resolver and existence caches) and owned `String`s. CORE's arena paragraph says data
   that changes while it lives stays in `List` or `Table` pools.
2. **Only `add` allocates in it.** A `List` or `Map` cannot keep its storage, or its growth, in an arena.
3. **Typed.** The load's transients are many types at once (strings, records, map slots).

So an arena of transients is not expressible today. A region, in the sense this brief uses, is memory where owners
(`List`, `Map`, `String`) can live and grow, and which frees whole.

## (c) Three shapes

**S1: a region block, set aside in #1215 on soundness.**

```text
r = *region.Region.new()
with !r
  paths: List[String] = List()       # its storage and every String in it come from r
  load(!paths)
# r drops after its last use; paths may not outlive the block
```

The error: `cannot move `paths` out of `with r`: it lives in `r``.

The problem SYNTHESIS gave still stands. An outer `List` that grows inside the block would point into `r` after it.
The fix is that growth follows the owner's memory, not the scope, which needs every block to know its region. A range
compare gives that, as with Tables. But "the same `List` means different things inside and outside" (CORE §10) is
not answered.

**S2: owners made by a region, limited by it** (`#1215` widened to growing collections).

```text
r = *region.Region.new()
paths = !r.list[String]()            # a List whose storage is in r: an owner, limited by r
!paths.push(!r.string(name))         # elements made in r too (stage 1: elements copy or come from r)
cache = !r.map[Key, Res]()
...
# r drops at its last use, after paths and cache
```

The error: `cannot drop `r` while `paths`, a List from `r`, is still in use`.

- A `List` made by `r` grows in `r`: the allocator finds `r` from the block's address range, so no `List` stores an
  allocator.
- Dropping it frees nothing, and dropping `r` frees all of it.

**S3: a placement hint, with no change to meaning** (NEEDS 88's "lifetime hint"; also covers "a task's heap dropped
whole").

```text
with transient                       # or: List[String].transient()
  load(!state)
```

- Allocations inside go to separate class pages on the same heap. Frees stay per block, as today.
- A page whose blocks are all free goes back to the segment for any class, and may be trimmed.

There is no error to write: a wrong hint can waste memory but can never be unsound. A survivor made under the hint just
pins a transient page.

## (d) Where each meets CORE

**S1.**
- It needs a new sentence. Values made in a block are limited by the block: a fourth kind of limit, beside views,
  owners that keep views, and tasks.
- §10's rule that meaning follows the type, not where a value was made, is broken.
- The debug trap: under `RIG_SANITIZE`, `r`'s range is unmapped at drop, so any access crashes.

**S2.**
- It fits sentences 6 and 7. A region-made owner holds an implicit view of `r`, so `r` stays limited until its last use,
  as "an owner that keeps one keeps the arena limited."
- A function returns one only `from r`.
- A task given one keeps `r` until `>t`.
- New ground:
  - an owner that lives in memory it does not own;
  - drop glue for elements that need a drop (stage 1 forbids them, as #1215 does);
  - the §5 self-view exception, widened to region owners that point at one another.
- The trap is the same as S1's: unmap or poison at drop, so a use after drop crashes at the access.

**S3.**
- No CORE change, and no new kind of limit; every free is still the owner's own.
- The risk is only the allocator's: page reuse across classes. That is a runtime invariant, so `RIG_SANITIZE` checks a
  page's class tag at each allocation.
- The debug aid is a report, not a trap: survivors in transient pages, by site, so Trig can see what it mis-hinted.

## (e) The cheapest experiment

Rig's guess, a scratch Rig that frees the load heap whole, cannot run as it stands. Survivors made during the load (file
names, path ids, AST lists) would dangle, so the run would crash or read garbage. Two steps, both scratch, neither
lands:

1. **A model run, no build.** Rerun rss-frag's heap-event model (burst, `~/cpuq/tmp/rfrag`) with the load-made sites
   that are dead by the peak placed in pages of their own. The result is the exact reach per class for typeorm,
   date-fns and Compiler at c1 and c4 (burst at 6 heaps, to match pup). About 2 hours. If typeorm c4 is under 3% of
   its peak, stop here.
2. **S3 as a scratch Rig.** A thread-local "transient" flag routes small allocations to a second set of class page
   heads on the heap. Frees are unchanged, and wholly free pages go back to the segment.
   - Trig flips the flag around its load jobs (the workers and the coordinator).
   - On pup, measure peak RSS on all 16 projects at c1, c4 and c8 against tsrs, with c1 instructions and md5 output.
   - About one day of builder time and one slot.
   - This is both the ceiling and a prototype of the only shape with no CORE change. If it reaches most of step 1's
     bound, S1 and S2 need not be discussed for this case. Their remaining case would be speed: per-pass temporaries
     freed in one step, which Trig's allocator share (equal to tsrs's) says is small today.

**Suggested default:** run step 1. Run step 2 if step 1 clears 3% on typeorm at c4. Bring S2 to the owner only if S3
falls well short.

---

## (f) Addendum, after pass A: the case moves to the program step (item 4, step 2)

**Pass A was negative.** Rig record region-lifetime (#1248): the load's lifetime gives no case.

**Trig's per-file last-read census** ("last-read-census.md" in Trig's notes, with tools and data in lastread-census/)
measured the other step. A file's tree, positions, text and binder records are released once no checker will read them
again. Ceiling, against race 753's tsrs (arm G):

| project | c1 MiB (share of Trig's peak) | c4 MiB (share) |
|---|---:|---:|
| typeorm | 68 (32%) | 37 (15%) |
| nuxt | 79 (24%) | 79 (19%) |
| webpack | 91 (26%) | 34 (9%) |
| supabase-studio | 299 (30%) | 79 (6%) |
| Compiler, Compiler-Unions | 5 (7%) | ~0 |

**Summed over the four large projects,** Trig/tsrs peak goes from 1.04 to 0.74 at c1 and from 0.99 to 0.89 at c4.
That is the largest memory lever measured so far.

**Unlike pass A, the peak really falls.** Today's peak is the run's end at c1 and 45–94% through the check at c4. The
load's end never becomes the new peak; the closest cell is typeorm c4, 5–27 MiB under.

**Where the bytes are.**
- The tree with its positions is 65–89% of the c1 reach.
- Most of it is in *imported* files (node_modules .d.ts files, and project sources other files import).
- Leaf files are only 6–33 MiB at c1.
- Bundled libs are ≤3 MiB, because they are read to the end.
- At supabase c4, text alone is 40 of 79 MiB.

**How it was checked.**
- The census builds print main's bytes in every run.
- A poison replay overwrote each file's records with 0xA5 at the first file boundary after its last read. All six
  projects still printed main's bytes, with zero touches of an overwritten record.
- Releasing at the bare last read broke text: the checker holds a view of a file's text across calls. So releases must
  wait for safe points at file boundaries.

**Soundness warning.** In the census's first validation pass, each file's records were released right after their
last read, touch by touch. Text broke: typeorm printed TS2307 errors for module names read as 0xA5 bytes, because the
checker keeps a view of a file's text across calls (`resolve_external_module` holds the name while it resolves). So a
release at the last read is unsound even when the read count says the data is dead. Releases are sound only at points
where no check holds a view, such as file boundaries. Any capability Rig builds must enforce that point, not trust a
count.

**Limits a discussion must keep in view (my reading).**
1. **It is an oracle ceiling.** The census frees each file at its reader's next file boundary after the last read that
   actually happened, which is known only afterwards. A real release must decide at run time that no later read can
   happen, for every input, not just these six.
   - For module leaf files whose own checker has finished, that is plausible. They are only 6–33 MiB at c1.
   - For imported .d.ts and sources, which hold most of the reach, nobody has proposed a rule yet. Reads arrive late,
     through types, symbols' declarations, type printing and diagnostics.
   - The reach of a sound rule is not measured. It lies between the leaf figure and the oracle figure.
2. **It assumes perfect reuse.** Pass A showed that splitting pages has a cost. About half the tree bytes sit in files
   with under 64 KiB of tree, sharing small-class pages. Reaching the ceiling needs item 5's contiguous per-file ranges
   or a per-file region.
3. **Rig would need two things:**
   - releasing part of a frozen program that checker tasks hold on read loans (sentences 6–7: a task keeps what it is
     lent until `>t`);
   - a debug build that traps on a read of a released record.
   This is under the owner's arena rule.
4. **Default mode must keep tsc's bytes.** tsrs ships leaf freeing only in `--fast`.

**The cheapest next measurement, read only.** Rerun the census model, in Trig's tools, with the realizable rule in
place of the oracle. Rule: a module file is released at the end of its own checker's check of it, if no file imports
it and it is not a global script. Add a second arm that also releases text and positions alone wherever the census
already shows them dead. That gives the floor of a sound rule next to the oracle ceiling, which the owner's discussion
needs before any language work.

## (g) Addendum: the sound floors (Trig's census rerun, last-read-census.md, "Sound floors")

**Verdict: neither floor is sound in Trig today.** Under the poison replay, both floors break typeorm, nuxt and
supabase-studio at c1, and supabase at c4; floor 2 also breaks typeorm at c4. The replay passes only where little or
nothing is released: webpack, at about 6 MiB, and Compiler and Compiler-Unions, whose files are all global scripts.

**The floors.**
- Floor 1 releases a module file that no file includes.
- Floor 2 releases a file once every checked file that can reach it, over the transitive include and import graph,
  has finished.
- Never released: libs, global scripts, files with augmentations or `declare global`, and files reached through
  `/// <reference>`.
- Released only at file boundaries.

**Three read paths break them:**
1. **Type printing.** `build_external_module_container_index` scans every external module's exports on its first use
   in each checker, so any module can be read after its last importer is done.
2. **Checker-wide caches carry types across unrelated files.** Two leaf test files that share no import still read
   each other's declarations: union properties' modifier flags, `symbol_sort_key` positions. No include graph can see
   this.
3. **Synthetic node ids read a file's node count.** This one is benign: keep the count.

**Reach if the paths were closed** (MiB off Trig's peak; Trig/tsrs, four large projects summed):

| count | now | oracle | floor 1 | floor 2 |
|---|---:|---:|---:|---:|
| c1 | 1.037 | 537, 0.741 | 85, 0.990 | 128, 0.967 |
| c4 | 0.986 | 246, 0.885 | 50, 0.965 | 74, 0.955 |
| c8 | 0.933 | 295, 0.831 | 51, 0.916 | 79, 0.906 |

**What a sound release would need from Trig, before any Rig capability helps:**
- the module-container index built per checker before any release, or a per-module export summary;
- per released declaration, a retained summary of what the caches read later (symbol and modifier flags, positions);
- node counts kept.

With those, the floors reach 7–15% of Trig's peak at c1 on typeorm and supabase, and 2–9% at c4. Today the sound reach
is webpack's few MiB.

**So the case for the owner** has three parts:
- an oracle ceiling of 26–30% at c1;
- a floor of 2–7 points of summed Trig/tsrs (c1 1.037 → 0.967–0.990; c4 and c8 2–3 points), reachable only after Trig adds declaration summaries;
- a Rig-side cost: releasing part of a frozen program under read loans, plus a debug trap.
