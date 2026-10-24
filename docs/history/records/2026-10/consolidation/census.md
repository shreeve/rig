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
| 2026-10-23 night | e03bceffd, against 463de5898 | Mac | 0.5% slower to 0.5% faster | 0.2% slower to 0.3% faster | | | 0.6% slower, 0.1% slower | none |
| 2026-10-23 night | e03bceffd, against 463de5898 | pup | 1.1% slower to 0.2% faster | 0.6% slower to 0.2% faster | | | 0.5% slower, 0.5% slower | none |
| 2026-10-24 | 122597c52, against f55fe3d9a | Mac | twitter 5.7-6.9%, citm 5.4-7.8%, canada 4.3-5.7%, gsoc 2.6-3.6% slower; github 0.9-2.2% slower; twitterescaped 0.3-1.0% faster | within 0.7% (canada 5.3% slower in one run of four) | tasks spawn 35-51% slower; the rest within 2%, or noise (hog); http 1.4% faster | 0.9-1.7% slower (typecheck 3.9-4.5% slower) | 0.9% slower to 0.9% faster, 0.7% faster to 0.1% slower | safe: #617 (placement); canada also #619 (accepted); spawn: #621 |
| 2026-10-24 | 122597c52 | Mac | twitter 3.3-4.7%, citm 4.1-5.1%, gsoc 1.9-3.0%, canada 1.9-3.1% slower; github 1.7-4.9% faster | canada 2.7-3.7% slower (#538, accepted); rest 1.0% slower to 5.2% faster | tasks spawn 22-29% slower; actors spread 3.0% slower; the rest within 2%, or faster (yield, contend) | 2.5-3.0% slower | 4.1% faster, 1.0% slower | json safe: #617; spawn: #621 |
| 2026-10-24 | 122597c52, against f55fe3d9a | pup | canada 2.0% slower; rest 2.3-8.2% faster | canada 2.3% slower; rest 0.6% slower to 7.5% faster | within 2% (actors solo 1.2%, http 1.4% slower) | 1.0% slower (typecheck 3.1-3.5% slower) | 0.2% slower, 0.9% slower | typecheck: no one merge past 1.7% (#616) |
| 2026-10-24 | 122597c52 | pup | 1.0% slower to 1.8% faster | 0.0-19.9% faster | within 2%, or faster (pingpong 2.17x, http 7.0%) | 3.2% slower | 0.2% slower, 0.7% slower | check: a creep over both rounds, no merge past 1.3% |

The night rows time the round's merges alone: their reference is
463de5898, main before the round, which already holds #538, so #538's
cost is in neither column (speed-baseline.md, "After the night").

Watch: twitter, citm_catalog, and github_events on pup (R4's placement
swing); `rig check`'s storage pass (2% slower on both machines, at the
line); since 2026-10-24, its typecheck pass (3-4.5% slower than
f55fe3d9a, in steps) and the Mac's safe std.json builds (#617's
placement).

## After Stages 3 to 5 (2026-10-24)

Main at 122597c52 (#625) against f55fe3d9a (round 1's close, before
Stage 3) and ace79d579 (the reference), all three interleaved in one
run per measure. Method as above, with these differences:

- **Trig's source.** Main rejects Trig 6191efb since #607 (public
  generics state their bounds), and the older compilers reject the
  bounds, so main builds and checks a copy migrated by
  `tools/state-bounds.py` (51 type parameters in 5 files, bounds only)
  and the others the original. The three trig builds print the same
  output. `trigtime.py check` reaches each source through a two-line
  wrapper that changes directory and runs the compiler.
- **pup's cores.** The concurrent benchmarks ran on cores 6,7, not 8,9
  (8-11 may be in use elsewhere); json and Trig on core 6. Load was 0.2
  to 3.3 throughout, with no release build running and no full Trig
  run overlapping.
- **The Mac** was rarely quiet: other sessions' suites held its load
  at 7 to 130 for most of the day. Each job started only below 4, but
  the load rose during most runs (peaks of 6 to 58), so json, tasks and
  net were run three or four times; the ranges in the rows span those
  runs, which agree. Trig's projects were timed again twice at load 3.4
  to 3.6; those runs are the row's.

**std.json, pup.** Against f55fe3d9a, canada is 2.0% (safe) and 2.3%
(fast) slower: #619, candidate A, accepted. Every other file is faster
in safe builds (twitter 4.7%, twitterescaped 8.2%), so pup's safe builds
are back at the reference (1.0% slower to 1.8% faster).

**std.json, the Mac's safe builds: #617, placement.** Against
f55fe3d9a, twitter, citm_catalog, and gsoc-2018 are 2.6-7.8% slower in
safe builds (fast builds within 0.7%). Timed over the merges (rig-safe,
10 rounds each, MB/s):

| run | twitter | citm_catalog | gsoc-2018 |
|---|---|---|---|
| 1: f55fe3d9a, #613, #618, #619, main | 3720, 3667, 3660, 3653, 3458 | 4367, 4361, 4378, 4325, 4024 | 8461, 8499, 8465, 8536, 8244 |
| 2: #619, #620, **#617** | 3855, 3880, **3636** | 4580, 4573, **4245** | 9033, 9005, **8674** |
| 3: #619, #617, #621, #622, #624, main | 3646, 3420, 3429, 3416, 3423, 3437 | 4325, 4058, 4034, 4025, 4028, 4018 | 8502, 8176, 8171, 8177, 8179, 8184 |

Each step is within 2% but one: **#617 (f8366f090) is 5.7% (twitter),
7.3% (citm_catalog), and 4.0% (gsoc-2018) slower than #620**, its
parent. Canada's step is #619's (3.6% in run 1), accepted. #617
(time-since-start) adds one clock reading at `start` and one function
to the runtime; nothing in std.json's code changes. In the twitter
build `document`, `escaped`, and `skip_plain_ascii` each sit 60 bytes
later (0x41ebc → 0x41ef8), at the same size. This is the placement the
alignment trial above found: the Mac's safe builds move 2-8% when code
before std.json's hot functions moves. Not fixed here.

**tasks spawn, the Mac: #621.** Spawn is 35-51% slower than f55fe3d9a
on the Mac (about 150 → 245 ns per task) in every run, and 0.7% slower
on pup. Timed over the runtime merges (20 rounds, then 30 for the pair):
#618 and #617 at f55fe3d9a's time or faster; **#621 29f8cb5a8
(os.memory counters) 35.2% slower than #617**, and #622, #624, and main
the same as #621. Chain, fanout, and yield do not move. #621 counts
each allocation on its thread's heap and adds the counts to three
shared atomics every 64 KB or 1024 blocks; why that costs spawn a third
on the Mac's ten workers and nothing on pup's two cores was not
measured. #621's cost to Trig (0.5-0.8%, accepted) is a different
measure; this one is the owner's to weigh.

**`rig check --time` of Trig.** The total is within 2% of f55fe3d9a
(pup 1.0%, 0.3%, and 0.4% slower in three runs; the Mac 0.9% and 1.7%),
but the typecheck pass is 3.1-3.5% slower on pup and 3.9-4.5% on the
Mac. Timed on pup at the merges between them (10 rounds each, core 6),
it rose in steps none of which passes 2%: 1.1% by #606, 1.7% at
#616 (generic-task-closure), and 0.7% at #619/#620. Against the
reference the total is 3.2% slower; timed across round 1's merges too,
that is a creep with no step past 1.3% (ace79d579 5924 ms, c77a86b07
6002, e03bceffd 5999, #579 6041, #588 6070, f55fe3d9a 6101), mostly in
typecheck (891 → 938 ms) and storage (1840 → 1926 ms) before Stage 3.
Nothing was bisected to a single merge, because no merge is responsible
for more than 2%.
