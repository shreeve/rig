# What pup must measure (x86-64 Linux)

The docs' Linux columns wait on these runs; until then they give no
Linux figure rather than keep the fast-mode numbers of 2026-10-20. Each
row is one slot, opened as AGENTS.md's "Sharing pup" says, with no other
holder in `cpuq status`. Rig is whatever commit `COMMIT` names (main
once this record's step 2 lands), built in a private folder; the
benches build Rig with `--release`.

## Setup, outside any slot

```sh
# from a Trig checkout on the Mac:
tools/pup-rig $COMMIT                # prints PUP_RIG=/zfs/trig-pup/rig-<sha>/bin/rig
# on pup:
export COMMIT=<sha>                  # the commit under test
SHA=$(git rev-parse --short=9 $COMMIT)
W=/zfs/trig-pup/bench-remeasure-$SHA
git -C /zfs/worktrees/rig fetch -q origin && git -C /zfs/worktrees/rig worktree add --detach $W/rig $COMMIT
cd $W/rig
export RIG=/zfs/trig-pup/rig-$SHA/bin/rig PYTHONUNBUFFERED=1
D=$W/build; mkdir -p $D/{tasks,actors,net,http,scale,fork}
O=docs/history/records/2026-11/concurrency-bench-remeasure/raw; mkdir -p $O
F=docs/history/records/2026-11/concurrency-bench-remeasure/fork
# builds, on E-cores:
taskset -c 12-19 bench/tasks/bench-tasks   --out $D/tasks  --build-only
taskset -c 12-19 bench/actors/bench-actors --out $D/actors --build-only
taskset -c 12-19 bench/net/bench-net       --out $D/net    --build-only
taskset -c 12-19 bench/http/bench-http     --out $D/http   --build-only
taskset -c 12-19 bench/tasks/bench-scale   --out $D/scale  --variants rig-safe,tokio,go --build-only
taskset -c 12-19 $RIG build --release -o $D/fork/rig-safe $F/fork.rig
(cd $F/rayon && taskset -c 12-19 cargo build --release -q --target-dir $D/fork/cargo) && cp $D/fork/cargo/release/fork-rayon $D/fork/rayon
```

## The rows

Each command runs in its own slot (`tools/pup-slot open NN MINUTES board
LABEL`), on cores 0-11 as the 2026-11-09 PROGRESS rows were, every
runtime on the same cores in the same run. The bench scripts print their
table only at the end, so each command runs one interleaved round per
invocation and appends it to `$O/<row>-pup.txt` as it ends: a slot that
times out keeps every round it finished, and the row's figure is the
fastest of each benchmark over the file's rounds. In the Markdown
source, a command's `\|` is a plain pipe.

| Row | Command | Fills | Minutes | From |
|---|---|---|---|---|
| T | `(git log -1 --format='%h %ci'; for i in $(seq 7); do taskset -c 0-11 bench/tasks/bench-tasks --out $D/tasks --time-only --reps 1; done) 2>&1 \| tee -a $O/T-pup.txt` | benchmarks.md "Tasks", Linux (spawn, chain, fanout, yield, hog, produce, memory) | 8 | Mac: 7 rounds in about 2 min; pup's `fanout` and `hog` run as long as the Mac's; 4× |
| M | `(git log -1 --format='%h %ci'; bench/tasks/bench-scale --out $D/scale --variants rig-safe,tokio,go --no-scale) 2>&1 \| tee -a $O/M-pup.txt` | a sleeping task's footprint on Linux, with page tables (benchmarks.md, CONCURRENCY.md, faq.md, post.md, learn/04, scheduler.md) | 5 | Mac: 49 s; 6× |
| A | `(git log -1 --format='%h %ci'; for i in $(seq 7); do taskset -c 0-11 bench/actors/bench-actors --out $D/actors --time-only --reps 1; done) 2>&1 \| tee -a $O/A-pup.txt` | benchmarks.md "Actor calls", Linux | 5 | Mac: under 1 min for 7 rounds; pup's per-call times 1.5-3× the Mac's in PROGRESS; 5× |
| N | `(git log -1 --format='%h %ci'; for i in $(seq 7); do taskset -c 0-11 bench/net/bench-net --out $D/net --time-only --reps 1; done) 2>&1 \| tee -a $O/N-pup.txt` | benchmarks.md "Networking", Linux | 10 | Mac: 54 s for 7 rounds; Linux holds TIME_WAIT 60 s and the driver waits for ports, so up to one wait a round |
| H1 | `(git log -1 --format='%h %ci'; for i in $(seq 3); do taskset -c 0-11 bench/http/bench-http --out $D/http --time-only --reps 1 --idle 10000; done) 2>&1 \| tee -a $O/H1-pup.txt` | benchmarks.md "HTTP", Linux (req/s, p50, p99, resident per idle connection) | 8 | Mac: about 35 s a round with 5,000 idle; 10,000 idle on pup, each round's idle run its own; 4× |
| H2 | H1 three more times, each in its own slot, writing `H2a`-`H2c`; once unpinned (no `taskset`), `H2u`; and once with each run's CPU time per request, `bench/http/bench-http-cputime` with H1's options (it adds a `cpu <variant> server <us/req> load <us/req> rps <n>` line per run on standard error, from /proc on Linux), `H2t` | whether Rig's lead over hyper on Linux holds across runs and core sets, and whether it is CPU per request or the load generator's share of the cores (inventory.md, "2.8×") | 8 each | as H1 |
| D | `(git log -1 --format='%h %ci'; python3 docs/history/records/2026-11/concurrency-bench-remeasure/idle_footprint.py 2000 $D/http/rig-safe $D/http/tokio $D/http/go) 2>&1 \| tee -a $O/D-pup.txt` | an idle connection's footprint with page tables for all three servers (benchmarks.md, faq.md, CONCURRENCY.md, scheduler.md) | 5 | Mac: 36 s; prints a line per server as each ends; 8× |
| F | `(git log -1 --format='%h %ci'; python3 $F/run.py 20 $D/fork/rig-safe $D/fork/rayon) 2>&1 \| tee -a $O/F-pup.txt` | a Linux row for fork-join against Rayon (benchmarks.md, CONCURRENCY.md) | 5 | Mac: 35 s for 20 rounds; prints each round as it ends; 8× |

No 2026-11-09 pup PROGRESS row records a wall time (they give time per
operation), so every Minutes figure is the Mac's wall time from this
record's `raw/` files, scaled by the factor in its row: at least 4×, and
never under 5 minutes.

Report each file with the slot's line (cores, free 2 MiB blocks, load)
and the Tokio version Cargo resolved (`misc/tokio` is a Mac clone).
