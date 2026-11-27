# par benchmarks

`workers.rig` times `par.workers` (SPEC §18, "Each element on several
tasks") against two hand-built forms of the same work: uneven items,
each checked by one of four states, as Trig's checkers check files.

```sh
cpuq run --label rig:build -- bin/rig build --release bench/par/workers.rig -o /tmp/workers
cpuq drain --all --label rig:bench-par -- /tmp/workers
```

| Form | How the items reach the states |
|---|---|
| `fixed` | each state's task takes a fixed quarter of the items, in program order, as a static assignment does |
| `chan` | the items, heaviest first, go into one `*Chan[Int]`; each state's task takes them until the channel is empty and gives back its state and its values, which the caller puts in item order |
| `workers` | `par.workers(!states, ?order, ...)` over the same order |

One item in twenty is heavy (about 60 units of work against 1 to 5),
and one in five among the first quarter, as a project's big files
cluster, so a fixed split gives one state far more than its share. The forms run interleaved, `REPS` times each, and the
fastest counts. Each prints `NAME MS CHECK [WORK...]`: the checks must
agree, and `WORK` is each state's share of the units in the last run.

## Results

| Machine | fixed | chan | workers |
|---|---|---|---|
| Mac (arm64, 10 cores), 2026-10-25 | 96.2 ms | 57.9 ms | 57.7 ms |
| pup (x86-64, `RIG_WORKERS=4`, CPUs 6-9), 2026-10-25 | 113.1 ms | 66.5 ms | 66.8 ms |

The fastest of three runs of the program, each the fastest of its nine
reps. A fixed split leaves one state 1,833 units against about 595 for
the others; pulling heaviest first gives each about 905, and the run
is about 40% faster. `workers` and the hand-built channel loop are
within 1% of each other on both machines, which is noise.

## cost.rig: `par.map` with and without `cost:`

`cost.rig` times `par.map` over 2,000 items of 1 to 5 units of work
each and six giants of 300 units, in three pairs of neighbours, as big
files sit together in one folder: the giants hold about a quarter of
the work. One worker per core.

```sh
cpuq run --label rig:build -- bin/rig build --release bench/par/cost.rig -o /tmp/cost
cpuq drain --all --label rig:bench-par -- /tmp/cost
```

| Form | How the items reach the tasks |
|---|---|
| `plain` | `par.map(?items, f)`: chunks of the same size, about eight for each task, in order |
| `cost` | `par.map(?items, f, cost: \|?weights, i\| weights[i])`: the costliest first, each task taking its share of the cost left |
| `listed` | the same costs given as a list, `cost: ?weights` |

The forms run interleaved, `REPS` times each, and the fastest counts.
Each prints `NAME US CHECK`; the checks must agree.

| Machine | plain | cost | listed |
|---|---|---|---|
| Mac (arm64, 10 cores), 2026-11-26 | 69.0 ms | 50.2 ms | 50.1 ms |

The fastest of three runs of the program, each the fastest of its 15
reps. Without `cost:`, a chunk of 25 items holds a pair of giants, and
the task that takes it ends last; with it, the six giants go out first,
one to a task, and the small items fill in around them: the loop takes
27% less time. Given as a closure or as a list, the costs time the
same, within noise.
