# What pup must measure (x86-64 Linux)

The docs' Linux columns wait on these runs; until then they say so
rather than keep the fast-mode numbers of 2026-10-20. Each run is one
slot, opened as AGENTS.md's "Sharing pup" says, with no other holder in
`cpuq status`. Rig is the branch's commit (or main once it lands), built
in a private folder; the benches build Rig with `--release`.

```sh
# from a Trig checkout on the Mac:
tools/pup-rig COMMIT                 # prints PUP_RIG=/zfs/trig-pup/rig-<sha>/bin/rig
# on pup, in a checkout of the same COMMIT under /zfs (never /tmp):
export RIG=/zfs/trig-pup/rig-<sha>/bin/rig
D=/zfs/trig-pup/bench-remeasure-<sha>; mkdir -p $D/{tasks,actors,net,http,scale}
# builds, on E-cores, outside any slot:
taskset -c 12-19 bench/tasks/bench-tasks   --out $D/tasks  --build-only
taskset -c 12-19 bench/actors/bench-actors --out $D/actors --build-only
taskset -c 12-19 bench/net/bench-net       --out $D/net    --build-only
taskset -c 12-19 bench/http/bench-http     --out $D/http   --build-only
taskset -c 12-19 bench/tasks/bench-scale   --out $D/scale  --variants rig-safe,tokio,go --build-only
```

Then, one slot each (`tools/pup-slot open NN MINUTES board LABEL`), on
cores 0-11 as the 2026-11-09 PROGRESS rows were, every runtime on the
same cores in the same run:

| Row | Command | Fills |
|---|---|---|
| T | `taskset -c 0-11 bench/tasks/bench-tasks --out $D/tasks --time-only --reps 7` | benchmarks.md "Tasks", Linux table (spawn, chain, fanout, yield, hog, produce, memory); CONCURRENCY.md if a Linux table is added |
| M | `bench/tasks/bench-scale --out $D/scale --variants rig-safe,tokio,go --no-scale` | the 8.9 KiB (4.3 KiB page tables) Linux footprint of a sleeping task in benchmarks.md, CONCURRENCY.md, design/concurrency.md, learn/04, faq.md, post.md; Tokio's 388 B and Go's 2.9 KiB |
| A | `taskset -c 0-11 bench/actors/bench-actors --out $D/actors --time-only --reps 7` | benchmarks.md "Actor calls", the three Linux rows |
| N | `taskset -c 0-11 bench/net/bench-net --out $D/net --time-only --reps 3` | benchmarks.md "Networking", the three Linux rows; post.md's Linux connect figure |
| H1 | `taskset -c 0-11 bench/http/bench-http --out $D/http --time-only --reps 3 --idle 10000` | benchmarks.md "HTTP", the three Linux rows (req/s, p50, p99, resident per idle connection) |
| H2 | H1 three more times, each in its own slot, plus once unpinned (no `taskset`), and once with each server's CPU time: `/usr/bin/time -v` around each server in a copy of `bench-http` | whether Rig's lead over hyper on Linux holds across runs and core sets, and whether it is CPU per request or the load generator's share of the cores (inventory.md, "2.8×") |
| D | `python3 docs/history/records/2026-11/concurrency-bench-remeasure/idle_footprint.py 2000 $D/http/rig-safe $D/http/tokio $D/http/go` | an idle connection's footprint with page tables, the 9.2 KiB in benchmarks.md, faq.md, scheduler.md; and hyper's and Go's by the same count, so the comparison is like for like |
| F | `python3 docs/history/records/2026-11/concurrency-bench-remeasure/fork/run.py 20 RIG_FORK RAYON_FORK`, after `$RIG build --release -o $D/fork fork/fork.rig` and `cargo build --release` in `fork/rayon` | a Linux row for the fork-join numbers (psum, qsort against Rayon), if CONCURRENCY.md is to give one |

Report each run's raw output into this folder as `raw/*-pup.txt`, with
the slot's line (cores, free 2 MiB blocks, load), the commit, and the
Tokio version Cargo resolved (`misc/tokio` is a Mac clone).
