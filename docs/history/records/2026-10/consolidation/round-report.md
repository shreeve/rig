# The consolidation round: what it did (2026-10-23)

The round of [PLAN.md](PLAN.md), run overnight under Rig (OG)'s
supervision, with the owner's authority while he slept. No language
feature was added; Stage 3's phases of APIs landed beside it,
Rig (OG)'s, through the same gates. Main has no `known: true` case.

## Landed

| PR | Track | What it does now |
|---|---|---|
| #571 | 3 | the guides cover this period's features (README, WELCOME, QUICK, SPEC §19, Learn 03/04, STD, ROADMAP, INTERNALS) |
| #573 | 1 | one classifier says what a function value is where a call runs it (`Checker.fnArg`); `http.serve` and `task.isolate`/`supervise` holes closed |
| #574 | 1 | a lend of a branch is decided again where it is reported; self-check builds refuse an accepted module typed `invalid` with no error; two siblings (a kept view's mark, a trial take's table write) |
| #575 | 2 | a generic call infers `n` from a `Slot[n]` argument |
| #576 | 2 | `match_scale` counts the fastest of three interleaved runs |
| #577, #582 | 6 | the speed baseline and census, the length-range experiment as a patch |
| #580 | 1 | an assignment's write through a view and an element's copy are recorded facts (`Pending` 3 → 1) |
| #585 | 2 | a wait fails with the set its work declares (`task.all`, `par.map`/`each`, `isolate`/`supervise`) |
| #587 | 1, 2, 3 | gate 3: the `Int!!` fix, `*Frozen` orders, one plain-enum classifier, the roadmap's open forms, nine backlog fixes (#583), the generic-ordering leak (#586), a lost wakeup and its sibling (#581), an error code widening to its union |
| #591 | 1, 2 | gate 4, with Stage 3 phase 2 (#584): a `keeps` method on an owned `T` refused (a view escaping a generic body), a read view copies a view (a generic `?T` of an optional view), errors compared with members, three accept-then-fail bugs (#589: lane methods through a call's write view, the deeper-instances message, objects nested by value) |
| #593 | 1 | how a binding or hidden storage holds a value that moves is recorded; `Pending` is gone, so emit decides nothing itself (emit byte-identical over 10,140 programs) |
| #597 | 4 | a run fails when it leaves a file in the checkout; the committed `json_tour.rig.debug/` tree removed |
| #588, #594 | | Stage 3 phases 3 and 4 (Rig (OG)'s), gate 6 |
| #595 | 2, 4 | gate 5: the scheduler's heap test waits for a move; `rig check --tasks` gets a directory-module case (#590); bench/net waits for free local ports (#592) |

## Measured

- The baseline against ace79d579 (main before 2026-10-21), on both
  machines ([speed-baseline.md](speed-baseline.md)): one regression past
  2%, #538, parked for the owner.
- Gates 2 to 4: tasks, actors, net, and http within 2% on pup, within
  the Mac's noise; `rig check` of Trig 0.95% slower, noise.
- After the night ([census.md](census.md)): main against the pre-round
  main 463de5898, std.json safe and fast and Trig's ts-pattern and zod3,
  each within 2% on both machines (the most, 1.1% on pup's
  github_events, safe).
- Trig's full suites on main e03bceffd: green, 1,375 jobs, and Trig's
  output matches tsc on 12,892 of 12,892.

## Stopped and redone

Two fixes had a second round of soundness findings in review, and were
stopped and redone narrower, as the rule asks:

- a declared set fitting a generic body that takes any error: held for
  Stage 3's bounds ([generic-sets-review.md](generic-sets-review.md));
- an error member widening to its union: only between sets without
  fields.

## Left

- The oracle's model of the hidden `E?` (track 2's R3-3 piece), not
  started.
- The owner's decisions (Rig (OG) holds the merged list): #538 and the
  json guard; a discarded result; a handle parameter lent by a capture;
  `Moves`/`Shares` naming; a `NetError` member for "no local port
  free".
- pup's memory rule is in Trig's `tools/release-slot` (shreeve/trig#185,
  tested on pup, light gate green), waiting on the owner: he earlier
  asked for 10 GB with three slots, and the rule asks 12 GB
  ([pup-slot-memory.md](pup-slot-memory.md)).
- `arg_types` is keyed by node, so a closure body checked again with
  other parameter types can reject a valid program; never unsound.
