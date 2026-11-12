# Shared map benchmarks

`shared.rig` times `shared.Map` ([STD](../../docs/STD.md#stdshared))
against the shapes that held a map several tasks write before it: a
`Map` in each of 64 actors, a key's hash picking one, and one `Map`
behind one actor; and, for lookups alone, one `Map` lent to every task
to read, the floor no shared map beats. It is not part of the test
suite or CI.

```sh
bench/shared/bench-shared                       # builds with bin/rig, 7 rounds
D=$(mktemp -d)
bin/rig build --release=fast bench/shared/shared.rig -o $D/shared
tools/mac-claim shared-map bench/shared/bench-shared --exe $D/shared --rounds 9
```

On pup, in a quiet slot, the build on E-cores and the runs on P-cores:

```sh
taskset -c 12-19 bin/rig build --release=fast bench/shared/shared.rig -o /zfs/trig-pup/tmp/shared
bench/shared/bench-shared --exe /zfs/trig-pup/tmp/shared --rounds 9 --pin "taskset -c 0-11"
```

## The benchmarks

The keys are 100,000 paths, `/repo/node_modules/pkgN/package.json`, to
an `Int`. Each run is one shape, one phase, and one task count (1, 6,
12; `task.workers` as many), and prints `SHAPE PHASE TASKS NS CHECK`;
the checks of the shapes must agree.

| Phase | What it does | Per |
|---|---|---|
| `insert` | an empty map takes the 100,000 keys, each task its share | put |
| `hit` | a full map is asked 2,000,000 times, keys drawn uniformly | lookup |
| `mixed` | an empty map is asked 2,000,000 times, keys drawn uniformly from the 100,000, each put on its first ask: 95% of the asks hit | lookup |

`mixed` is the cache a loader keeps: a miss is resolved and put, every
later ask for the key a hit. It is the measurement of
frontend-answers' Question 2, whose `shards` row it repeats. A put
clones the key in every shape. A lookup through an actor copies the
value out; one through a `shared.Map` views it in place.

The driver runs every shape, phase, and count once a round, in an order
shuffled for the round, and reports the median of the rounds: the wall
time, and the CPU time of one operation (wall times tasks over the
operations).

## Results

Mac (M5, 4 fast and 6 slow cores), 2026-11-11, branch `concurrent-map`,
9 rounds under `tools/mac-claim`. Milliseconds of wall time, and in
parentheses nanoseconds of CPU an operation. 12 tasks is more than the
cores.

| Phase | Tasks | shared.Map | 64 actor shards | one actor | Map lent to read |
|---|---|---|---|---|---|
| insert | 1 | 5.3 (53) | 4.9 (49) | 3.1 (31) | |
| insert | 6 | 3.8 (230) | 4.2 (250) | 9.0 (542) | |
| insert | 12 | 3.5 (425) | 4.2 (510) | 18.7 (2,248) | |
| hit | 1 | 39.1 (20) | 103.5 (52) | 59.9 (30) | 34.3 (17) |
| hit | 6 | 12.2 (37) | 36.1 (108) | 116.2 (349) | 10.2 (31) |
| hit | 12 | 9.9 (60) | 33.8 (203) | 333.9 (2,003) | 8.0 (48) |
| mixed | 1 | 48.4 (24) | 108.5 (54) | 63.9 (32) | |
| mixed | 6 | 15.3 (46) | 39.5 (118) | 118.7 (356) | |
| mixed | 12 | 13.1 (79) | 37.9 (227) | 325.5 (1,953) | |

A lookup in a `shared.Map` costs within 14% of a plain `Map`'s on one
task and within 20% on six, and 2.6 to 3 times less wall time than the
actor shards on six; a put costs what a shard's does. One actor gets
slower with each task added, since every call takes it.
