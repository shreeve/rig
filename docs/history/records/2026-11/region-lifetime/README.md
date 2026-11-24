# Regions for the load's lifetime, modelled: a measured negative (2026-11-24)

Measured first, nothing built.

**The question.** The owner approved Trig's end-state design (2026-11-24). Its decision 2 opened a full discussion,
under the arena rule, of a region capability beyond `Arena[T]` (#1215) for Trig's NEEDS 88: a place for the load's
short-lived blocks, freed whole. The brief for that discussion (data/brief.md) set three shapes and a stop rule:
- **S1:** a `with r` block.
- **S2:** owners made by a region.
- **S3:** a placement hint.
- **Stop rule:** a heap model first. If perfect lifetime separation saves less than 3% of typeorm's peak at four
  checkers, stop before any language or runtime work.

**What was used.** Trig main 8ad4c8b9 (Rig pin b4d9e7247) and tsrs 0.23.0. Every output was identical between the two.

## Result in one paragraph

The stop rule fired. On typeorm at four checkers, Trig's peak is 240.9 MiB, so the bar was 7.2 MiB. Ideal separation
(every block the load makes that is dead by the peak placed on pages of its own) changes the peak by **−7.5 MiB**
counting whole pages: it *raises* it. Counting only the bytes each page has carved, it saves at most +5.9 MiB. That is
−3.1% or +2.4%.

**Why.** At c4 and c8, Trig's peak is at or near the end of the load, where every transient block is still live.
Separating them frees the space at the end of the check that Trig's rss-frag study found (155.6 → 140.0 MiB on typeorm
c4). But each heap and class then holds a second open page, and transients and survivors stop sharing free slots, so
the load's end rises from 144.5 to 159.7 MiB and becomes the new peak.

**The hint is worse than no hint.** A real hint (S3: everything made during the load on separate pages) loses memory in
every cell, because survivors made in the load pin the transient pages. No hint at all, with wholly free pages going to
any class, saves more than ideal separation in most c4 and c8 cells, but still only **2.0%** of typeorm c4.

So the load gives no case for regions, and the discussion's case is withdrawn.

## 1. The model (harness/hpage.cc, extending Trig's rss-frag model)

**The log.** A heap-event log comes from the scratch event-log Rig (heapmiss's patch on the pin, with the allocating
thread's id). It records a 40-byte record per block made, moved or freed, with its site.

**How the allocator is modelled.**
- A heap is a thread. Each class carves 64 KiB pages, and its free list is last-in-first-out and taken before carving.
- A page whose blocks are all free goes to its heap's pool, which any class takes from before carving.
- The footprint is the small classes' segment bytes plus the live large bytes, counted three ways:
  - `page`: whole pages, pool pages given back. This is the realistic count for Rig, which asks for huge pages for
    segments and prefaults pages after a class's first.
  - `keep`: pool pages kept resident.
  - `touch`: carved bytes rounded to 4 KiB, an optimistic bound.

**Arms.**
- **M:** today's allocator.
- **Mp:** M plus the pool.
- **I:** Mp, with load-made blocks dead by M's peak on transient pages.
- **P:** Mp, with every load-made block on transient pages.
- **Pm:** P, with normal requests allowed to take transient free blocks after the load.
- **I2, P2:** I and P with the window ending at the bind.

**The load window** is set from site names, not event counts (harness/marks.sh): from the first block under
`process_all_program_files` to the last block made by a `FileLoader` site.

**Validation.** M's free blocks at the live peak are 2.09 MiB on typeorm c1 and 1.32 on date-fns c1. Trig's rss-frag
study had 2.1 and 1.3.

**Runs.** Burst ran 9 heap-log runs at once, typeorm, date-fns and Compiler at c1, c4 and c8. Each run had its own six
CPUs, so six heaps at c4 and c8, as on pup. Each took 1–5 s.

**RSS** is `/usr/bin/time` on the same CPU sets, median of three, with tsrs in its exact mode (`--checkerAssignment go
--noLazyMembers`). Its default mode was within 3.2 MiB of that in every cell.

## 2. Results (MiB; data/summary.txt, data/cells/*/m.arms)

Save is M's peak minus the arm's peak, under `page` unless marked. Ratio is (Trig − save) / tsrs.

| cell | Trig | tsrs | I | I touch | P | Mp | ratio now | with I | with Mp |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typeorm c1 | 221.0 | 191.6 | 1.75 | 1.53 | −3.88 | 0.50 | 1.153 | 1.144 | 1.151 |
| **typeorm c4** | 240.9 | 224.5 | **−7.53** | 5.85 | −16.12 | 4.88 | 1.073 | 1.107 | 1.051 |
| typeorm c8 | 285.6 | 235.6 | 0.53 | 9.59 | −19.88 | 2.69 | 1.212 | 1.210 | 1.201 |
| date-fns c1 | 159.7 | 140.8 | 1.25 | 1.05 | −3.44 | 0.31 | 1.134 | 1.125 | 1.132 |
| date-fns c4 | 200.2 | 161.8 | −8.16 | 3.40 | −13.22 | 1.56 | 1.238 | 1.288 | 1.228 |
| date-fns c8 | 217.5 | 178.5 | −10.87 | 3.65 | −19.06 | 3.88 | 1.219 | 1.280 | 1.197 |
| Compiler c1 | 73.2 | 51.0 | −1.37 | 0.21 | −2.94 | 0.38 | 1.435 | 1.462 | 1.427 |
| Compiler c4 | 119.2 | 68.0 | 0.63 | 1.13 | −6.54 | 5.84 | 1.753 | 1.744 | 1.667 |
| Compiler c8 | 128.4 | 75.6 | 1.44 | 0.93 | −8.76 | 3.24 | 1.698 | 1.679 | 1.655 |

- **I2 equals I**, and P2 is no better than P except on typeorm c4 (−12.3 against −16.1). Pm is less bad than P, but
  negative wherever P is.
- **These ratios are burst's plain builds, not a race.** Pup's races are the standing figures.
- **Compiler's gap to tsrs** is per-heap carved room and huge pages on small worker heaps (Trig's NEEDS 87), not
  lifetimes. No arm here touches it.

## 3. Caveats

- The model's heap is a thread id. Every run kept the same six threads (one at c1) for its whole life.
- A free from another heap counts at once.
- Large blocks count as live bytes; spans' kept and cold memory is not modelled. The large term is the same in every
  arm, so it moves only where the maximum falls.

## Decision

Rig: stop.
- The load lifetime is not a case for regions. S1, S2 and S3 stay unbuilt, and the S3 scratch build is not taken to the
  owner.
- Trig's end-state item 4, step 1, is a measured negative.
- The one thing left is NEEDS 88's other half: wholly free pages going back to any class on each heap (Mp). It is under
  3% at its best cell (typeorm c4, 2.0%), and stays a note in NEEDS 88.
- The program step of item 4 (releasing a leaf file's tree once no checker reads it) is a separate question. Trig's
  per-file last-read census measures it.
