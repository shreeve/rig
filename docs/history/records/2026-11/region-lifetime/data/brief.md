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
