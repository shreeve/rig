# The speed census

The owner's rule (2026-10-22): nothing late may slow earlier work. After
each batch of merges, and on demand, main is timed against the
reference, ace79d579 (main before 2026-10-21), on both machines,
interleaved. Anything slower beyond 2% is bisected before more lands.
speed-baseline.md has the method and the first full run's numbers; each
later run adds a row here.

## How to run one

On the Mac, from worktrees of the reference and of main, each with
`bin/rig` built and the json corpus in `bench/json/check/data`:

```sh
C=docs/history/records/2026-10/consolidation/census
OUT=$HOME/somewhere/census                     # absolute
tools/heavy $C/census.py build $OUT ref=$REF_TREE cur=$MAIN_TREE
tools/low $C/census.py time $OUT json 10 ref cur
for b in tasks:30 actors:30 net:30 http:6; do tools/low $C/census.py time $OUT ${b%:*} ${b#*:} ref cur; done
tools/low $C/trigtime.py run 10 ~/Data/Code/trig/misc/projects ref=$TRIG_REF cur=$TRIG_MAIN
tools/low $C/trigtime.py check 10 $TRIG_SRC ref=$REF_TREE/bin/rig cur=$MAIN_TREE/bin/rig
```

On pup, the same from `git archive` copies, every build through
`sh /zfs/trig-pup/trial/slot.sh` with 12 GB available, `PATH` holding
Go (`~/.local/go/bin`), json and Trig under `taskset -c 6`, the
concurrent benchmarks under `taskset -c 8,9`. Trig 6191efb is the Trig
both compilers build (speed-baseline.md, "Trig"); a Trig release build
is `rig build --release -o trig src/main.rig` in a copy of its `src/`
with `tools/trig/main.rig` as `src/main.rig`.

## Rows

Each cell is main against the reference: the files or benchmarks past
2% slower by name, else the range. "Trig check" is `rig check --time`'s
total; "Trig run" is ts-pattern and zod3.

| Date | main | Machine | std.json safe | std.json fast | tasks, actors, net, http | Trig check | Trig run | Bisected |
|---|---|---|---|---|---|---|---|---|
| 2026-10-22 | before #565 | Mac | 1-4% faster | 1-4% faster; canada 1.8% slower | | | | |
| 2026-10-23 | c77a86b07 | Mac | 0.2-4.5% faster | canada 2.7% slower; rest 0.7% slower to 4.6% faster | within 2%, or faster (spawn, yield, hog, pingpong) | 0.3% faster | 6.6% faster, 0.1% faster | canada fast: #538 |
| 2026-10-23 | c77a86b07 | pup | twitter 5.6%, twitterescaped 6.3%, citm 2.7%, gsoc 2.3%, github 2.4% slower; canada 2.7% faster | 2.3-14.8% faster | within 2%, or faster (spawn, pingpong 2.17x, http 5.6%) | 0.8% slower | 1.0% faster, 1.4% faster | safe: #538, and R4's accepted shift on twitter |

Watch: twitter, citm_catalog, and github_events on pup (R4's placement
swing); `rig check`'s storage pass (2% slower on both machines, at the
line).
