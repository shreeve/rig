# Waking a worker for a spawned task: design note

Rig - Merges, 2026-11-01. Approved by Rig - Swiss with the stress case added; reviewed by Rig - Rust and Rig - Rust (fork). Measurements: [startup-15-16.md](startup-15-16.md), "Sched-wake A/B" runs 1 and 2.

## What happens today

`spawn` hands the new fiber to `wake` (src/sched.zig), which puts it in the spawner's "run next" slot and wakes no worker. If the slot already held a fiber, that fiber moves to the ring and `notifyNew` may wake a sleeper. `waiting` is set, so another busy worker's yield check may claim it. The fiber spreads to another core only when:
- a second spawn pushes it out of the slot; or
- the spawner reaches a yield check: `tick` sees its own work and yields to the new fiber, the spawner is requeued (`wakeLast`, ring plus `notify`), and a woken worker takes the spawner; or
- a busy worker's yield check claims it (`claimWaiting`).

The doc comment on `wake` gives the reason: a spawner that goes on running usually stops soon, as one that sends and then waits does, so a worker woken for the fiber would mostly find it gone.

## What Trig's start shows

Trig's start spawns a few large tasks (the bundled libs parsed ahead, the checkers) and the spawner goes on with long serial work: the loader's walk, or making the next checker. For the last task spawned (or the only one), the spread waits for the spawner's first yield check. Then the spawner, not the new task, moves to another core, after a wake's latency, with its cache left behind.

## The change

Only `spawn` changes, only outside deterministic mode, and only for an unpinned fiber whose spawner runs on a worker that is not servicing:

```zig
fn wakeSpawned(f: *Fiber) void {
    if (deterministic or f.home != null) return wake(f);
    const w = me() orelse return wake(f);
    if (w.current == null or w.servicing) return wake(f);
    w.ring.push(f);
    notifyNew();
}
```

The new fiber goes to the spawner's ring, in `wakeLast`'s order (the ring's tail stored, then a notify).
- **`notifyNew`, not `notify`** (Rig - Rust): when every worker is busy, as at 4 checkers on 4 cores, `notify` does nothing. `notifyNew` then sets `waiting`, as today's `wake` does, so a busy worker's yield check can still claim the fiber. Otherwise it notifies.
  - Runs 1 and 2 measured `notify`, so they lacked this claim path.
- **No lost wake** (Rig - Rust): if no one is woken, the spawner's next yield check sees its own work and yields to the fiber, which is today's behavior.
- **The sleep protocol** (formal/Models/Sleep.lean) is unchanged: the change uses the ring and the notify as they are.
- **One core:** the worker count follows the affinity mask (`workerCount` uses `std.Thread.getCpuCount`, which reads `sched_getaffinity` on Linux). So `taskset -c 6` runs one worker, and no sleeper on the same core contends with the spawner. Rig - Rust's pinned `--singleThreaded` timing on core 3 (`abn.sh`) still runs, to rule out the blocking pool's threads.

- **Unchanged:**
  - message passing and actors (`wake` of an existing fiber);
  - local tasks;
  - deterministic schedules, so seeds replay the same;
  - the blocking pool (25g, a15297f4e).
- **What it costs:**
  - **Spawn, then wait at once** (`t = f()&; >t`): the fiber is in the ring rather than the slot, so the spawner's worker still runs it when the spawner stops, unless the woken worker steals it first. Either way it pays one `notify`: a futex wake when a worker sleeps, nothing when one searches.
  - **Waiting behind queued work** (Rust (fork)): the ring is first in, first out for its owner too (`Ring.pop` takes from `head`). So `>t` finds `t` behind whatever the ring already holds, not first, as it is from the slot.
  - **Spawn one, then block** (Rust (fork)), as in accept → spawn handler → accept. Today the handler waits in the slot and runs warm on the spawner's worker when accept parks, with no wake. With the change, each connection pays a futex wake while workers sleep, and often a move to another core, with the reply crossing cores.
  - **A burst of small spawns:** already wakes workers today from the second spawn on, so it changes only the first.
  - **Rows to watch:** `bench/net` and `bench/http` at 1 to 4 connections first, then `bench/tasks`' spawn-and-join rows, and `bench/actors` if an actor's start spawns.

## The variant, a second arm from the start

At a yield check, a spawned fiber still in the slot goes to the ring with a `notify`, instead of the spawner yielding to it. Reaching a yield check is the evidence that the spawner kept running. So the variant keeps spawn-then-wait and spawn-one-then-block at today's cost, keeps the spawner on its core, and moves the new fiber instead. It spreads from the first yield check rather than at spawn.

Which arm Trig should prefer depends on one count: the time from each spawn to the spawner's first yield check, in Trig's loader and checker pool. Measured first. Both arms run in every benchmark and Trig comparison (Rust (fork)'s review).

## Results so far

Trig, pup P-cores, 20 rotated rounds. Each figure is the mean over Trig main and fixes 1+2, which cancels a per-binary memory split. Wall median, outputs identical.

| project | run 1, Rig 1684f645a | run 2, Rig 95fffb6cf |
|---|---|---|
| superstruct | inconsistent | 3.7% faster |
| mitt | 2.9% faster | 3.5% faster |
| neverthrow | 3.4% faster | 2.5% faster |
| zod3 | 1.0% faster | 0.2% faster |
| ts-pattern | 0.1% slower | 0.7% slower |

## Plan

1. Rebase on Rig main (a15297f4e or newer).
2. On pup, in a quiet slot:
   - `zig build test` with `-Doptimize=debug`, `safe` and `fast`;
   - `bench/tasks`, `bench/actors`, `bench/net` and `bench/http`, plain against changed, interleaved.
   - Then the Mac rows of the same benches.
3. Concurrency cases under `seeds: 20` (the deterministic path is unchanged, so these should not move), and the full suite.
   - The seeded cases never run the new path, so it gets a stress case of its own on the real scheduler: many spawn-then-wait tasks across workers, some nested, some joining at once and some after work, under `RIG_SANITIZE=1`, run many times with a timeout.
   - The case must catch a lost wake: break the `notify` on purpose once, by dropping it, and show the case hangs or fails.
4. Trig's 2×2 again on the rebased Rig, at 1 and 4 checkers.
5. **Bar** (each arm against plain; gains need the 20 interleaved rounds with cycles backing them, and ts-pattern's 0.7% counts as level):
   - no benchmark row more than 2% slower;
   - Trig's small projects faster in both comparisons;
   - ts-pattern and zod3 no slower.
   The better arm that clears the bar goes to the owner as a scheduler PR, with the PROGRESS rows.

Pinned one-core check (Rig - Rust): pup:/zfs/trig-pup/trial/abn.sh N "PROJECTS" LABEL="env BIN" ... (core 3, --singleThreaded; fastest task-clock/cycles/instructions, median faults/RSS; abn-lex.sh adds project empty). Rotate by running twice with variants swapped, joined by ";". Builds: abbuild.sh NAME from trial/ab/NAME (RIGBIN=..., TRIG_RELEASE_SLOTS="12,13,14,15 16,17,18,19").
