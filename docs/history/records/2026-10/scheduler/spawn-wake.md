# Waking a worker for a spawned task (2026-11-01, closed)

Rig - Merges, 2026-11-01. Not landed: on the shuffled harness with an
A/A arm, the change is level with Rig's main on every project, at one
checker and at four.

## The question

`spawn` puts a new fiber in the spawner's "run next" slot and wakes no
worker (`wake`, src/sched.zig). The fiber spreads to another core only
when:
- a second spawn pushes it to the ring;
- the spawner reaches a yield check, which yields to it, and the spawner
  moves instead; or
- a busy worker's yield check claims it (`waiting`).

Trig's start spawns a few large tasks (the bundled libs parsed ahead,
then the checkers) while the spawner goes on with long serial work. So
for the last task spawned, the spread waits for the spawner's first
yield check.

## The change

[wakeSpawned.patch](spawn-wake-data/wakeSpawned.patch), 12 lines.

- **Which spawns:** outside deterministic mode, an unpinned fiber whose
  spawner runs on a worker that is not servicing.
- **What it does:** the fiber goes to the spawner's ring, and
  `notifyNew` either wakes a sleeper or, when every worker is busy, sets
  `waiting` for their yield checks.
- **Unchanged:** every other wake, local tasks, and seeded schedules.

## Earlier runs

The earlier runs used a rotated order, 20 rounds, and `notify` in place
of `notifyNew`:
- [run-1.md](spawn-wake-data/run-1.md), Rig 1684f645a;
- [run-2.md](spawn-wake-data/run-2.md), Rig 95fffb6cf.

At four checkers they showed the change about 3% faster on mitt,
neverthrow and superstruct, and level on zod3 and ts-pattern. That run
had no A/A arm. The harness record
([timing-audit/harness.md](../timing-audit/harness.md)) later found
that a rotated order alone makes a byte-identical copy up to 5.8%
faster on mitt.

## This run

- **Binaries:** Trig main e5627bf (parallel bind and exit after output
  in), built by Rig main 43e1f65f4 in three arms:
  - plain (p);
  - a byte-identical copy of plain (a, the A/A arm);
  - the change (w).

  All are plain release builds, cross-compiled on the Mac for pup with
  `-mcpu=meteorlake`. The emitted Zig is the same in each; only the
  runtime's `sched.zig` differs.
- **Timing:** pup, `time-ab.sh` ([wake.conf](spawn-wake-data/wake.conf)).
  - One checker on core 6, four on 0, 6, 8 and 10.
  - 60 shuffled rounds on mitt, neverthrow and superstruct, 20 on zod3,
    ts-pattern and tiny-invariant.
  - Binaries run from /tmp.
- **Outputs:** identical in every arm and round.

Data: [times.txt](spawn-wake-data/times.txt). Every arm against plain:
[table.md](spawn-wake-data/table.md).

### Four checkers, wall median against plain

| project | A/A copy | change |
|---|---|---|
| mitt | 0.2% faster | 1.9% faster |
| neverthrow | 0.1% slower | 0.1% faster |
| superstruct | 1.1% slower | 4.0% faster |
| zod3 | 0.1% slower | 0.1% faster |
| ts-pattern | 0.6% faster | 0.4% faster |
| tiny-invariant | 0.7% slower | 0.2% slower |

Paired by round (each arm's time over plain's in the same round), with
a bootstrap 95% interval on the median ratio:

| project | A/A copy | change |
|---|---|---|
| mitt | 0.6% slower [2.4% slower, 1.2% faster] | level [1.0% slower, 2.4% faster] |
| neverthrow | 0.4% faster [2.4% slower, 2.4% faster] | 0.4% faster [0.9% slower, 2.5% faster] |
| superstruct | 2.6% slower [6.7% slower, 1.3% faster] | 2.5% faster [1.2% slower, 6.2% faster] |
| zod3 | 0.5% faster [2.0% slower, 1.9% faster] | 0.1% faster [1.1% slower, 1.4% faster] |

- **Intervals:** every interval spans zero, and on superstruct the copy
  moves as far as the change does.
- **Cycles:** within 0.8% either way.
- **Peak RSS:** within 0.9%.
- **One checker:** level, within 1.0% on every project, the A/A arm
  as large.

## Decision

Closed. The change is not worth its costs:
- one `notify` per spawn-then-wait;
- a handler's first run moved off a warm core in accept, spawn, accept;
- the waiter finding its task behind the ring's other work.

The runtime benchmarks and the stress case it would have needed were
not run. The variant arm, which moves the slot's fiber at the first
yield check, was not built: the arm it would refine shows nothing to
refine.

A late start of the lib-parsing tasks at four checkers remains possible.
The way to see it is per-task timestamps (spawn, start, end, join) in
Trig's loader, not this A/B.
