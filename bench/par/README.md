# par benchmarks

`workers.rig` times `par.workers` (SPEC §18, "Each element on several
tasks") against two hand-built forms of the same work: uneven items,
each checked by one of four states, as Trig's checkers check files.

```sh
tools/low bin/rig build --release=fast bench/par/workers.rig -o /tmp/workers
tools/low /tmp/workers
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
