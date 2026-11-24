# Race 754: a worker count that widens for the front end, measured (2026-11-24)

The owner approved one measurement of [README.md](README.md)'s design ("Yes", 2026-11-24, through Rig). The result is
a negative: summed wall is level in every arm, and peak memory rises.

## The build

**Rig:** scratch commit e26d0196a, kept as the tag `archive/phase-wide`.
- **`task.widen()`** raises the workers to every hardware thread of the fast cores: 12 on pup's P-cores.
- **`task.narrow()`** goes back to the count before it.
  - The extra workers park: their queues move to the others, and they wait in their own poller.
  - Their heaps give back their free pages and stay donors while parked, so the heaps that go on take their free
    blocks, and blocks freed into them later.
- **Parking** is archive/lower-workers' design (W′), ported to main.
- **The switch:** both do nothing unless `RIG_WIDE=1`, so one binary runs every arm.
- **No sibling adoption:** the design's sibling adoption is the allocator's donation above, which W′ also had. No
  further memory mechanism was built.

**Gates on the scratch:**
- `test/cli/phase_wide.sh`: tasks, an actor, channels, timers, `par`, a narrow during a long loop, and 20 cycles, five
  runs each with the switch on.
- The core suite with the switch off and on: 12,744 jobs each, none died.

**Trig:** phase-wide-trig 995763d59, which is bind-in-load-2 (825fe139) with `task.widen()` before the load and
`task.narrow()` after the bind. So the whole front end, load and bind, runs wide. One PGO+BOLT binary; tsc's output
on all 64 corpus runs in every arm.

**Arms:**
- **M:** neither switch (main's path).
- **W:** `RIG_WIDE=1`.
- **X:** `RIG_WIDE=1` with `TRIG_BIND_IN_LOAD=1`.
- **B:** `TRIG_BIND_IN_LOAD=1`.

**The race:** 16 projects at c1, c2, c4 and c8, 10 rounds, on pup's P-cores 0-11 in Rig's slot (`race-754/slot-pw.sh`).
c1 is an A/A/A/A, since one worker never widens.

## Summed over the 16 projects (medians of rounds 1-10)

| c | arm | summed wall (ratio to M) | parse+bind (ms) | check (ms) | peak RSS (ratio to M) |
|---|---|---:|---:|---:|---:|
| c1 | M | 20571 ms (1.000) | 4395 | 15468 | 1.000 |
| c1 | W | 20556 ms (0.999) | 4392 | 15434 | 1.000 |
| c1 | X | 20596 ms (1.001) | 4392 | 15466 | 1.000 |
| c1 | B | 20544 ms (0.999) | 4386 | 15438 | 1.000 |
| c2 | M | 13143 ms (1.000) | 1340 | 11139 | 1.000 |
| c2 | W | 13167 ms (1.002) | 1250 | 11238 | 1.054 |
| c2 | X | 13141 ms (1.000) | 1236 | 11232 | 1.061 |
| c2 | B | 13181 ms (1.003) | 1314 | 11200 | 1.002 |
| c4 | M | 9044 ms (1.000) | 1334 | 7090 | 1.000 |
| c4 | W | 9004 ms (0.996) | 1252 | 7130 | 1.047 |
| c4 | X | 8993 ms (0.994) | 1234 | 7132 | 1.048 |
| c4 | B | 9001 ms (0.995) | 1310 | 7058 | 1.004 |
| c8 | M | 8027 ms (1.000) | 1291 | 6109 | 1.000 |
| c8 | W | 8005 ms (0.997) | 1252 | 6128 | 1.026 |
| c8 | X | 8014 ms (0.998) | 1240 | 6142 | 1.027 |
| c8 | B | 8008 ms (0.998) | 1276 | 6105 | 1.006 |

Each project at c4 is in `race-754/c4-projects.md`, and the raw rows are `race-754/runs`.

## Reading

- **The front end gains as measured before.** Parse and bind are 3-7% faster wide: 39 to 90 ms over the 16 projects,
  2.4 to 5.6 ms each.
- **The check gives back about as much.** It is 0.3-0.9% slower in W and X, against M on the same binary: for
  example nuxt c4 248 → 250 ms and webpack c4 276 → 288.
- **Summed wall moves 0.6% at most.** That is under the 1.5% bar, and B, which never widens, moves the same at
  c4 and c8.
- **Peak memory rises 2.6-6.1% at c2-c8 in the wide arms.** At c4: date-fns 15%, xstate-main 12%, typeorm 11%,
  nuxt and playwright 8%. B stays within 0.6%.
- **This is W′'s shape (slot 424) on today's main:** narrowing gives the front end's speed back in the check, and the
  load's data spread over twice the heaps raises the peak.
  - The donated free memory does not cancel that. The live data the check reads still sits in twice the heaps' pages.
  - Sibling adoption of half-used pages would not move live data either, so it was not built.
- **What could still change this** is allocation into an arena a task chooses, the lever the design note named:
  bindings made in the load kept apart from its transients. That is a different mechanism and needs its own design.

## Decision

The result is filed as a measured negative, and the scratch is kept as `archive/phase-wide`. If the idea is ever
revisited, it comes beside task-chosen arenas, as the owner said when parking it, and its name stays `task.widen()`.
