# Map's hot path inlined on the dense layout (2026-10-26)

Branch `map-inline`. It keeps today's layout: dense entries, stored
hashes, and the `Table` of tags and entry indexes. It changes only how
Map's and Set's code is cut into functions (std/__rig_builtin.rig).
The owner decides whether it lands: it misses the bar's letter on RSS
and on two bench/hash rows (Verdict). The scripts are in
[build/](build/), and every raw run is in `build/runs/res1` (first
campaign, spills, scoreboard, bench/hash) and `build/runs/res3` (the
PGO builds timed again on a quiet pup).

## Verdict

- **Spills and reloads in the Map's code fell from 412M to 47M
  instructions a run** in Trig's PGO build on ts-pattern (whole.py, as
  #702 counted its 426M to 82M). The Map/Set family went from 995M
  instructions to 707M.
- **The shipping PGO build retires 1.44-1.65% fewer instructions** on
  ts-pattern and zod3, at one and four checkers, warm and cold. On a
  quiet pup it is 0.6-6.9% faster in wall time in all eight
  configurations, with 0.6-3.0% fewer cycles. Trig (fork)'s scoreboard
  method gives 1.0-2.9% faster.
- **It does not clear "more than 2% faster"** except at four checkers,
  cold (ts-pattern 6.9%, zod3 2.4%). It clears "at least 1% fewer
  instructions with time no worse".
- **Peak RSS is 0.1-0.3% higher (0.3-0.6 MB).** The anonymous memory is
  the same; the text the binary maps grows by 0.2-0.3 MB, since the PGO
  build's text is 669 KB (4.0%) larger, and page faults are equal. By
  the bar's letter, RSS is higher.
- **bench/hash:** in Zig's fast mode no row is slower beyond noise. In
  safe mode, String `ensure` on hits is 8.7% slower and `ensure_with` on
  hits 10.1% slower, in both runs and by the median. The rest are faster
  or within noise: Int inserts 8%, misses 12%, small maps 29-44%.
- **std.json is unchanged:** its program's package (every module and the
  runtime) is byte-identical, since it uses no Map.

## What is built

- **`find` is `inline`**, in Map and Set, so a lookup's probe is part of
  the method that runs it, with its state in the caller's registers.
- **`insert` is `inline`**: an insert into room the Map has is a push of
  the entry, a push of its hash, and a free slot, with no call and no
  copy of the key into one. `add_entry` (Map) and `add_new` (Set),
  marked `called`, are gone; `replace`, `put_new`, and `Set.add` call
  `insert`. `ensure`'s and `ensure_with`'s `add_new` and `add_made`
  stay `rarely`.
- **Growth stays out of line and cold:** `grow` is `rarely`, so
  `noinline` with the cold hint; `compact` and `rebuild` are reached
  only through it, `reserve`, and `retain`.
- The growth test's sums use wrapping operators (`+%`, `*%`), since a
  table's length counts bytes in memory, and the insert reads the new
  entry's index before the push, not as `es.len - 1`.
- **The probe keeps its two passes** (from the slot `h` names to the
  end, then from the start), each a loop whose test is the bounds test.
  One loop that wraps (`i = 0 if i == ts.len`) was built first
  (f4a471003) and dropped before measuring: on x86 it took 12
  instructions a step against 10, since LLVM kept both the wrap's
  compare and the loop's.
- test/cli/inline.sh says the new shape: an inlined write holds only
  the table's probes (`find`, `Table.free_slot`), and `grow` is
  `noinline`.

## Builds measured

| Name | Rig | Note |
|---|---|---|
| base, base-pgo | main 5a79e02f2 | |
| new, new-pgo | map-inline 87c3885e0 (rebased as d40485db0 on ad3a8ea52, the std identical) | |
| newb, newb-pgo | 87c3885e0 with `find` left unmarked (LLVM decides), `insert` inlined | a probe of code size |

Trig main c75127e, `tools/trig/main.rig`, each built through `slot.sh`:
`rig build --release`, and `--pgo` trained by `tools/trig/bolt-train`.
Every output matched the base build's byte for byte.

## Method

- pup; one checker on core 8 with sibling 9 idle, four on cores 6-9.
- Fastest of 10, interleaved, the order rotated each round (`trigbench.sh`);
  `perf stat` user cycles and instructions, `/usr/bin/time` peak RSS.
- Cold runs had `pollute` streaming 256 MiB on E-core 12.
- `quiet.sh` held each step until pup ran no build (`release-slot`,
  `zig build`, `rig build`, `zig cc`); `runs/res1/quiet.log` has the waits.
- The first campaign (`res1`) ran while wall times were about twice
  the cycles' worth (ts-pattern at one checker 2.1 s, against 1.2 s at
  17:00 and 0.9 s in `res3`), so its times are noisy and its cycles and
  instructions are the figures to read. `res3` ran on a quiet pup.

## Trig, PGO (quiet pup, `res3`)

| Project, checkers, cache | Time | Cycles (median pair) | Instructions | Peak RSS |
|---|---|---|---|---|
| ts-pattern, 1, warm | 0.6% faster | 0.6% fewer (0.5%) | 1.63% fewer | 296.3 to 296.6 MB, 0.1% higher |
| ts-pattern, 1, cold | 0.8% faster | 0.8% fewer (0.7%) | 1.58% fewer | 0.1% higher |
| ts-pattern, 4, warm | 1.4% faster | 1.0% fewer (0.7%) | 1.59% fewer | 339.4 to 340.0 MB, 0.2% higher |
| ts-pattern, 4, cold | 6.9% faster | 2.7% fewer (1.7%) | 1.60% fewer | 0.1% higher |
| zod3, 1, warm | 1.7% faster | 1.7% fewer (1.6%) | 1.65% fewer | 88.9 to 89.2 MB, 0.3% higher |
| zod3, 1, cold | 1.2% faster | 1.4% fewer (0.4%) | 1.44% fewer | 0.3% higher |
| zod3, 4, warm | 1.6% faster | 3.0% fewer (0.8%) | 1.63% fewer | 135.0 to 135.2 MB, 0.2% higher |
| zod3, 4, cold | 2.4% faster | 2.1% fewer (1.3%) | 1.63% fewer | 0.2% higher |

The first campaign's PGO rows (`res1`, noisy times) agree on
instructions (1.20-1.65% fewer) and cycles at one checker (0.3-1.9%
fewer); its four-checker times ranged from 6.7% faster to 4.2% slower.

`newb-pgo` (find unmarked) retires 1.42-1.82% fewer instructions with
times alike, but its RSS is 1.0-2.7% higher, so it was dropped.

## Trig (fork)'s scoreboard method (`score-mi.sh`)

`/zfs/trig-pup/trial/score2.sh`'s method unchanged (each variant once a
round, interleaved, 10 rounds; fastest wall time, its instructions,
median peak RSS and faults), with main's PGO build against map-inline's,
one checker on core 8 (not 3) and four on cores 6-9 (not 0-11):

| Project, checkers | Wall | Instructions | RSS (MB, median) | Faults (median) |
|---|---|---|---|---|
| ts-pattern, 1 | 912.4 to 903.3 ms, 1.0% faster | 8.69G to 8.54G | 296 to 296 | 41,041 to 41,045 |
| ts-pattern, 4 | 502.1 to 496.0 ms, 1.2% faster | 9.13G to 8.99G | 339 to 339 | 48,957 to 48,961 |
| zod3, 1 | 189.1 to 185.8 ms, 1.7% faster | 1.52G to 1.51G | 88 to 89 | 9,832 to 9,831 |
| zod3, 4 | 153.8 to 149.3 ms, 2.9% faster | 2.08G to 2.05G | 134 to 135 | 19,225 to 19,223 |

The two harnesses agree on instructions and on direction. The
scoreboard ran in the noisier window, between `res1` and `res3`.

Peak RSS split (`rsssplit.sh`, `/proc` sampled every 2 ms, 3 runs):
ts-pattern anonymous 292.2-292.9 MB against 292.1-292.4, file-backed
10.3 MB against 10.6; zod3 anonymous 80.4-81.0 against 80.3-80.5,
file-backed 10.2 against 10.4.

## Trig, release (`res1`, noisy times)

| Project, checkers, cache | Time | Cycles (median pair) | Instructions | Peak RSS |
|---|---|---|---|---|
| ts-pattern, 1, warm | 1.9% faster | 2.2% fewer (1.5%) | 3.53% fewer | 295.4 to 295.6 MB, 0.1% higher |
| ts-pattern, 1, cold | 2.2% faster | 2.1% fewer (0.9%) | 3.50% fewer | 0.1% higher |
| ts-pattern, 4, warm | 3.7% faster | 0.3% fewer (0.9%) | 3.49% fewer | 0.1% lower |
| ts-pattern, 4, cold | noise (32.8% slower) | 1.0% more (1.3% fewer) | 3.49% fewer | 0.3% higher |
| zod3, 1, warm | 1.9% faster | 0.2% fewer (1.6%) | 2.99% fewer | 88.4 to 88.7 MB, 0.3% higher |
| zod3, 1, cold | 1.9% faster | 2.1% fewer (1.1%) | 3.01% fewer | 0.3% higher |
| zod3, 4, warm | 8.9% faster | 3.7% more (3.2% fewer) | 3.39% fewer | 0.1% higher |
| zod3, 4, cold | 6.1% slower | 3.9% more (4.0% fewer) | 3.28% fewer | 0.1% higher |

Release text grows from 15.83 MB to 16.45 MB (3.9%).

## Spills in the PGO build (ts-pattern, one checker)

`perf record` of user instructions every 10M over 30 runs on core 8,
then Trig (fork)'s `/zfs/trig-pup/trial/dis/whole.py` (a reload a load
from the stack, a spill a store to it; each sample charged to its
innermost source line), runtime functions named from map-inline's
`src/`. Millions of instructions a run:

| Build | Map/Set | reloads | spills | callee saves | callee restores |
|---|---:|---:|---:|---:|---:|
| main PGO | 995 | 222 | 190 | 39 | 14 |
| map-inline PGO | 707 | 37 | 10 | 5 | 2 |

`spills.py` (map-stage's counter, by source file): spills 190 to 10,
reloads 38 to 23, pushes 39 to 5. Most of what is left is the yield
check's cold `rig.sched.tick` call inside the probe loops, the
loop-hoist branch's subject.

## bench/hash (pup, core 8, fastest of 21)

| Row | Safe mode | Fast mode |
|---|---|---|
| Int: insert, hit, miss | 8.0%, 4.2%, 12.2% faster | 4.3%, 8.3%, 1.0% faster |
| Int walk | 1.5% slower | noise (main has 2 runs of 21 at 0.92 ms, both builds otherwise 1.6 ms) |
| String: insert, hit, miss | 8.9% faster, same, 2.4% faster | 6.0%, 12.4%, 3.9% faster |
| pair: insert, hit, miss | 6.5%, 10.3%, 8.0% faster | 4.4%, 6.8%, 7.6% faster |
| small maps of 4 and 8 | 43.7% and 29.4% faster | 42.0% and 25.6% faster |
| Int `ensure`, `ensure_with`, `edit` then `put` | 5.1-12.2% faster | 2.8-8.6% faster |
| String `ensure`-hit, `ensure_with`-hit | **8.7% and 10.1% slower** | 3.6% and 2.3% faster |
| String `edit_put`-hit | 0.4% faster | 1.7% slower |

A first run of 11 rounds (`hash.txt`) agrees, String `ensure`-hit 6.7%
slower in safe mode.

**Why the two String rows are slower.** In x86 code built from the
same Zig on the Mac, the String compare is a call (`mem.eqlBytes`) in
main too. The bench's Map is a local, which LLVM splits into values once
`find` is inlined. Across the probe's two calls (`hashBytes` and
`eqlBytes`), LLVM copies about eight of its fields to new stack slots
for each lookup and reloads them around each compare.
`string_ensure` has 228 stack operands against main's 108. A plain key
(Int, pair, Trig's keys) makes no such call, so its probe keeps its
state in registers.

A candidate, not committed: `find` probes inline only where
`$plain(K)`, and calls `find_far`, a copy of the probe left to LLVM as
main's `find` is, for other keys. `string_ensure` then compiles to
main's code exactly, and the plain keys' code to map-inline's. It is not
yet timed on pup.

## Gates

- `tools/heavy swarm test/rig.rip all -q -w 3`: green, 10,589 jobs; the
  oracle files unchanged.
- `zig build test` on pup: Debug, ReleaseSafe, and ReleaseFast pass.
- loco's light gate: GREEN (122 runs, 0 differ).
- `tools/emit-diff origin/main`: 6 of 30 programs differ, in
  `__rig_std___rig_builtin.zig` (examples/sets, examples/word_count,
  bench/hash, bench/terminal, the std program, Trig); also std.terminal,
  and 14 of Trig's modules, as the program-wide inliner's choices move
  with the Map's sizes. std.json's program is identical.
- Trig's light gate is the lead's.
