# Step 2 panel: soundness (expert 1), 2026-11-15

**Premise H**, for a value holding a Cell, which lives only behind a
handle (sentence 9):
- H1: it changes only by marked calls, each indivisible against every
  access through any handle (one atomic instruction across tasks; no
  yield or user code within one).
- H2: no view it gives out sees what a marked call changes, moves, or frees.
- H3: its box is freed only by the last strong handle.

**Simulation.** A write loan forbids beyond a read loan only reads of
the place (`?h`, `+h`, another marked call), each open today through
`h2 = +h`. So an accepted program runs as one routing each relaxed call
through a copy, accepted today (k05, m03, ch06; p4, p5, p15-p17 clean
under `RIG_SANITIZE=1`).

| Fault | Why not |
|---|---|
| use after free | H3; the read loan still bars moving, dropping, or rebinding the place while the call, task, or a result `from @` lives (p8, p9) |
| dangling view | H2: Cell contents only copied; plain and handle fields never change through a handle (p11, p14 rejected); Map entries never move |
| change under a read view | views see the handle or unchanging parts; a Cell reads by indivisible copy |
| double free, leak | no handle made or dropped; values move once |

**Checked:** Cell, Cell of a List, Signal, Chan (copies or moves only),
`shared.Map` (entries never move, freed at drop; p5 holds a view
across 50,000 puts). None breaks H.

## Open points

1. Yes, H2 is the premise; every std type meets it.
2. One duration, sentence 6: while a view taken through the place
   lives. An object's task holds self as one; an actor's message holds
   its own count. CORE says that, not a list.
3. Follow the self. A `!Cell[T]` or `!@` of a Cell-holding object
   reaches a value behind a handle that changes only its Cells; H holds
   (c18, k13 sound). Excluded: an owned self (p13), `!h` alone.

**Pre-existing bug:** `(!h).m()&` and `?h.m()&` through any handle pass
`rig check` and fail in Zig (`Counted(..)` has no member `m`): p1-p3,
p6, p7.

**Verdict: SOUND WITH CONDITIONS:** (a) every covered type meets H by declaration; (b) the loan starts before the arguments, lasting per sentence 6; (c) k10 waits for the method-task emit fix, one-task boxes' tasks stay pinned, Cell operations free of yields and preemption; (d) `!h` alone, rebinding, and drops of the place stay write.
