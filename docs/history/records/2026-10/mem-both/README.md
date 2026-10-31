# Memory and speed both: row 21's Zig ceiling, round 1 (2026-10-31)

The owner's words: "We need BOTH the SPEED and the MEMORY wins". The goal is #785's memory cut
(tag `archive/mem-alloc-b`) with every row, and Trig's time and RSS, within 2% of main.

**Verdict after four rounds (40 pairs pooled): arm a cuts kv 64 KiB's memory from 61 to 40 MB and xmalloc-test's from 275 to 80 MB. xmalloc-test is level and sh8bench faster, Trig is level, and kv 64 KiB is 1.5% slower by the median (the arm faster in 11 of 40 pairs): a small, real cost at the bar's edge.** Round 3 alone showed kv 64 KiB 2.3% and xmalloc-test 5.7% slower. Round 2 (quiet, 10 rounds) found arms a and ac within 2% of main on every row by the median. Round 1's verdict was that no arm is shown to meet the bar, and none is shown to miss it. On pup the
harness's spread between rounds is 3-12% on rows an arm does not touch. For example, arm a
changes only large blocks, yet its kv 32 B median is 10.8% below main's. That spread is wider
than the 2% bar, so four rounds cannot settle 2% either way. The memory cuts are clear:

- **Arm a** has the best kv 64 KiB memory: a median of 30 MB against main's 74. Its kv 64 KiB
  speed is level by median (0.6%) and 2.8% slower by best.
- **Arm ac** has the best xmalloc-test memory: 57 MB against 283, with xmalloc 3.4-4.2% faster.
  Its kv 64 KiB is 1.7-1.9% slower, and its kvP16 is 2.5-5.7% slower; ac changes only kv's small
  blocks there.

## The arms

Every arm is main's `src/alloc.zig` (179c50afa) with one change, made by `harness/mkarm.py`. Each
arm is its own plain build; none is switched by an environment variable.

A heap is *busy* when it faults in ahead (`faultsAhead`): it leads the heaps, or it has taken two
segments from the system. A busy heap keeps main's rule, so Trig's checker heaps take main's path
in every arm. Row 17 found that on Trig `trimKept` and `freeLarge` never unmap, so `keepBound`
never binds there. No arm returns pages under a bound tighter than `keepBound` on a busy heap, and
Trig's hot path is unchanged.

| Arm | What a heap that is not busy does with a large block it frees |
|---|---|
| main | keeps it resident, up to `keepBound` (its settled peak and 16 MiB) |
| a | keeps it resident up to 1 MiB. Past that, its pages after the header go back to the system (`MADV_DONTNEED` on Linux, `MADV_FREE_REUSABLE` on macOS), and the block stays on the heap's own cold list. A request takes a resident block first, then a cold one (its pages fault in afresh), then new pages. There is no cross-heap pool, and the virtual bound stays `keepBound` |
| af | a, with `MADV_FREE` on Linux |
| b | keeps it resident up to 1 MiB plus a 512 KiB chunk. Past that, it moves blocks down to 1 MiB into one program-wide pool (spin lock, 8 MiB cap, the excess unmapped). A heap tries its own blocks, then the pool, before new pages, and takes up to a chunk of the same bucket at once. The fast paths take no lock |
| b2c | b with a 512 KiB resident bound, 256 KiB chunks and a 4 MiB cap, plus c |
| c | small blocks: a heap with no block of a class left takes another heap's remote list before each page it carves (#785's step 2, `takeRemote`) |
| ac, bc | a or b, plus c |

Arm b cannot take only blocks idle longer than some N: per-heap lists are LIFO, and finding the
oldest block needs an age list. A heap's excess over its resident bound is the part of a random
walk that sits idle, so b moves that.

## Why main holds what it holds (probe counts, Mac)

kv with 64 KiB values (Mac, 10 workers, 3 s) behaves as follows on main:

- 99.95% of large requests are served from the heap's own kept blocks: 1,048,004 of 1,048,577.
- 572 blocks are mapped in all, and none is ever unmapped.
- Each heap's kept bytes follow a random walk that grows with run time, toward its 16 MiB
  bound, so the memory comes from per-heap caches, not from churn.

xmalloc-test's batch is 32,776 bytes, a large block (36 KiB with the shim's header). Releaser
threads free batches and never allocate, so each keeps 16 MiB of them. That is most of main's
283 MB. The memory is the large-block bound's, not the small blocks'.

## Round 1 on pup (03:29-03:50, 4 rounds, the first arm rotated each round)

Harness: `harness/`, a copy of #779's (kv.rig, load.rs, hold.rs) with #785's exact commands, which
#785's builder supplied:

- The server runs unpinned with 22 workers, after `ulimit -n 20000`.
- `hold N 3`, then `load 127.0.0.1:PORT N P 3 [KEYS VLEN]` on cores 6-11,20,21.
- RSS is the most VmRSS of 25 samples taken 0.1 s apart during the load.
- Rows: kv64k `50 1 3 100 65536`, kv32 `50 1 3`, kv32c1000 `1000 1 3`, kvP16 `50 16 3`.
- mimalloc-bench runs through each arm's `LD_PRELOAD` shim on cores 0-11,20,21:
  - xmalloc-test `-w 16 -t 5 -s 64`, measured by its rtime;
  - sh8bench `32`, measured by /usr/bin/time, which reports in 10 ms steps.

Raw rows: [pup-round1.txt](pup-round1.txt); every arm and row: [pup-round1-summary.txt](pup-round1-summary.txt).

Best of 4 and median of 4 against main (req/s, or the time for xmalloc and sh8bench), and the
median peak RSS:

| Row | main | a | ac | b2c | b | bc | c |
|---|---|---|---|---|---|---|---|
| kv64k best | 257k | 2.8% slower | 1.7% slower | 3.3% slower | 2.0% slower | 8.7% slower | 4.6% slower |
| kv64k median | 238k | 0.6% slower | 1.9% slower | 1.4% slower | 8.0% slower | 3.3% slower | 3.5% slower |
| kv64k RSS | 74 MB | **30** | 46 | 51 | 42 | 51 | 72 |
| kv32 best / median | 957k / 878k | 0.4% faster / 10.8% slower | 3.3% / 2.3% slower | 3.3% slower / 3.3% faster | 2.3% slower / 1.6% faster | 1.0% slower / 2.0% faster | 1.8% slower / 2.5% faster |
| kv32c1000 best / median | 774k / 694k | 3.8% slower / 2.9% faster | 0.8% slower / 2.5% faster | 1.0% slower / 3.3% faster | 0.4% faster / level | 2.5% / 6.2% slower | 1.2% / 0.5% slower |
| kvP16 best / median | 1.81M / 1.68M | 4.1% / 12.6% slower | 5.7% / 2.5% slower | 2.2% / 2.1% slower | 0.6% slower / 1.0% faster | 2.8% slower / 2.3% faster | 1.3% slower / 3.5% faster |
| xmalloc best / median | 0.953 / 1.006 | 9.2% faster / 6.2% slower | 4.2% / 3.4% faster | 2.8% / 4.4% faster | 1.1% slower / 0.6% faster | 6.2% / 7.2% slower | 12.4% / 1.3% faster |
| xmalloc RSS | 283 MB | 86 | **57** | 65 | 132 | 77 | 250 |
| sh8bench best / median | 0.71 / 0.755 s | 10.9% / 4.9% faster | 1.4% / 2.7% faster | 4.1% / 3.8% slower | 2.9% faster / 3.2% slower | 4.1% / 3.2% slower | 6.0% / 7.1% faster |
| sh8bench RSS | 331 MB | 308 | 306 | 286 | 323 | 299 | 318 |

kv32, kv32c1000 and kvP16 hold no large blocks: they read into a 16 KiB small block. So a and b
leave those rows' code as main's, and their 3-13% swings there are the harness's noise. Round 1's
first pass (main, then a) ran with something else on pup: a's kv32 there was 297k against 839k
in the same round. Load reaches about 130 during kv32c1000, whose load generator runs 1,000
threads.

**MADV_FREE** (arm af, smoke on the E-cores) leaves RSS where main's is: xmalloc-test 289 MB,
against 93 for a with `MADV_DONTNEED`. Linux counts lazily freed pages as resident until memory is
short, so af's memory gain shows only under pressure. Go returned to `MADV_DONTNEED` for this
reason. Arm a uses `DONTNEED`.

**Mac** (10 workers, load 5-15 from other sessions' suites, 3 rounds): too noisy for speed (rows
an arm does not touch moved 1-11%). kv64k peak RSS: main 40-45 MB, b2c 29-41, c 32-53, a 49-57.
Mac's kv64k memory varied from 40 to 85 MB between runs of main itself.

**Trig** is not timed in round 1. Its release builds waited while Trig's suite needed pup's
memory, and only main's PGO build exists (`packs/main-pgo` on pup). Every arm leaves a busy
heap on main's path, so Trig's checker changes only in code layout:

- a adds an empty cold-list check before mapping;
- b adds a test of the pool's byte count before mapping;
- c adds one heap-list walk per page carved, with one heap on one checker.

## Round 2 on pup (quiet, 10:46-11:09, 10 rounds, the first arm rotated each round)

pup was quiet: every other job was paused. The harness was round 1's, with arms main, a, ac and
b2c. Every arm, main included, is built on Rig 179c50afa. Main moved since (#810), but the
comparison stays on one base.

Raw rows: [pup-round2.txt](pup-round2.txt); summary: [pup-round2-summary.txt](pup-round2-summary.txt).

Median of 10 against main (best of 10 in brackets), and median peak RSS:

| Row | main | a | ac | b2c |
|---|---|---|---|---|
| kv64k | 248k req/s, 60 MB | 0.2% slower (0.5%), **39 MB** | 1.5% slower (1.4%), **38 MB** | 0.4% faster (0.2% slower), 62 MB |
| kv32 | 934k | 0.3% faster (1.0% slower) | level (1.1% slower) | level (2.4% slower) |
| kv32c1000 | 760k | 1.2% slower (1.0% faster) | 0.3% slower (0.9% faster) | level (0.8% slower) |
| kvP16 | 1.61M | 2.1% faster (6.0% slower) | 2.0% faster (8.6% slower) | 0.7% faster (9.8% slower) |
| xmalloc | 0.950, 273 MB | 0.4% faster (1.7% slower), **78 MB** | 6.4% faster (6.8%), **62 MB** | 5.9% faster (11.8%), 66 MB |
| sh8bench | 0.705 s, 319 MB | 9.3% faster (3.4%), 322 MB | 0.7% faster (3.4%), 298 MB | **9.6% slower** (level), 286 MB |

- **a and ac stay within 2% of main on every row by the median.** kvP16's best-of-10 gap comes
  from one run of main's at 1.90M req/s, against its median of 1.61M. Main's second best,
  1.79M, is 1.8% above a's best. kvP16 holds no large blocks, so neither arm changes its code.
- **b2c misses the bar:** sh8bench is 9.6% slower by the median.
- **Memory:** kv64k's RSS is 39 MB with a (30-71 MB) and 38 MB with ac (30-46 MB), against main's
  60 MB (51-72 MB). xmalloc-test's is 78 and 62 MB against 273 MB. #785 reached 31-33 MB and
  38-53 MB, so a keeps about two thirds of #785's kv cut, and ac a little more on xmalloc-test.

## Round 3 on pup (quiet, 13:24-13:36): Trig, and the PR on its own base

The PR (#815, arm a ported to main 144f70057, head 05f201c42) is timed against main 144f70057;
Trig's arm a and main are both on 179c50afa. Raw: [pup-trig.txt](pup-trig.txt),
[pup-round3.txt](pup-round3.txt), [pup-bench.txt](pup-bench.txt). Summaries are in the
`-summary.txt` files beside them.

**Trig** (PGO, one checker, core 3 with its sibling idle, 21 rounds rotated):

| Project | main median | a, best / median |
|---|---|---|
| ts-pattern | 730.7 ms | level / 0.4% slower |
| zod3 | 149.2 ms | 0.3% / 0.5% slower |
| mitt, neverthrow, superstruct, tiny-invariant | 28-72 ms | 4.4% slower to 2.3% faster |

The four small projects take 25-70 ms each, where a run's spread is 10%.

Peak RSS was 2.1-2.9 MB higher for a on every project and every run. With both executables
copied fresh, so both are wholly in the page cache, it is equal (ts-pattern 255.87 MB against
255.87, superstruct 25.5 against 25.7). The difference was the executable's pages, not the
allocator. Trig's heaps take main's path in every arm.

**kv 64 KiB and xmalloc-test on the new base** (10 rounds rotated, median; best in brackets):

| Row | main 144f70057 | PR |
|---|---|---|
| kv64k | 254k req/s, 59 MB | **2.3% slower** (2.4%), 44 MB |
| xmalloc | 0.903, 271 MB | **5.7% slower** (10.0%), 78 MB |
| sh8bench | 0.700 s | 3.4% slower (1.7% faster) |

Round by round, the PR's xmalloc-test was slower in 8 of the 10 pairs. Round 2 had the same
code level, at 0.2% and 0.4%. Rounds 2 and 3 disagree by more than the bar.

**The runtime benches** (pup core 6, two passes alternated): tasks, actors, net and http are
level: fanout 593.3-593.6 ms against 593.8-594.1, pingpong 4.80-4.86 us against 4.83-4.84, and
http 146.6-148.3k req/s against 143.2-145.5k.

**Verdict after three rounds:** arm a cuts memory as measured, but it is not shown within 2%:
- kv 64 KiB: 0.2% slower in round 2 and 2.3% slower in round 3;
- xmalloc-test: 0.4% faster in round 2 and 5.7% slower in round 3.

A heap that crosses its 1 MiB bound pays a `madvise` on the free, and later page faults on the
reuse, where main reuses resident pages. Round 3 is the likelier measure of that cost.

## Round 4 on pup (quiet, 14:33-14:41): the decider, four builds interleaved

The four builds were interleaved over 10 rounds: main and a at 179c50afa, and main and the PR at
144f70057. Raw rows: [pup-round4.txt](pup-round4.txt). The pooled ratios of rounds 2-4 are in
[pooled-summary.txt](pooled-summary.txt).

**No merge is involved.**
- xmalloc-test's shim compiles alloc.zig alone, and main's alloc.zig is byte-identical at both
  bases.
- kv's own emitted Zig is identical at both bases too.
- The PR against a, paired, is 0.993 on kv 64 KiB.

The noise floor shows in the identical code: main at 144f70057 against main at 179c50afa
measured 0.978 on kv 64 KiB and 0.981 on xmalloc-test by the median. Single pairs ranged from
0.75 to 1.55.

**Pooled, 40 pairs** (a's code against main's in the same round; above 1 is faster):

| Row | median | geomean | arm faster | peak RSS, arm / main |
|---|---|---|---|---|
| kv64k | 0.985 | 0.967 | 11 of 40 | 40 / 61 MB |
| xmalloc | 0.981 | 0.984 | 18 of 40 | 80 / 275 MB |
| sh8bench | 1.016 | 1.041 | 28 of 40 | 323 / 321 MB |

xmalloc-test is level, within the noise floor, and sh8bench is faster. kv 64 KiB is slower, by
1.5% by the median, and the arm is faster in only 11 of 40 pairs. The cost is real and on the
edge of the bar. The likely mechanism is the 1 MiB bound: a heap whose kept bytes cross it pays a
`madvise` on the free, then zero-fill faults on the block's reuse.

## Round 5 on pup (quiet, 14:58-15:11): targeted variants for kv's large-block path

Swiss asked for one round on kv's cost. The Mac showed kv level by cycles, because macOS's
`MADV_FREE_REUSABLE` is lazy, so the round ran on pup. Four variants of the PR's alloc.zig
([variants/](variants/)) ran against main 144f70057 and the PR, for 10 rounds. Raw rows:
[pup-round5.txt](pup-round5.txt).

kv 64 KiB, paired against main in the same round (above 1 is faster), with the median peak RSS:

| Build | median | geomean | faster in | RSS |
|---|---|---|---|---|
| main 144f70057 | (249k req/s) | | | 56 MB |
| PR (1 MiB resident) | 0.989 | 0.958 | 3 of 10 | 34 MB |
| r2 (2 MiB) | 0.965 | 0.946 | 1 of 10 | 39 MB |
| r4 (4 MiB) | 0.915 | 0.915 | 1 of 10 | 46 MB |
| lifo (keep the newest, give back the oldest) | 0.951 | 0.938 | 1 of 10 | 47 MB |
| hyst (give back past 2 MiB, down to 1 MiB) | 0.957 | 0.939 | 2 of 10 | 38 MB |

No variant brings kv within 1%. A larger bound or LIFO order is slower, not faster, so the cost
is not the number of `madvise` calls at the bound. xmalloc-test was 0.955-0.989 for all of them
(r4 0.915), and sh8bench 0.986-1.042.

## The trade (for the owner)

Arm a, PR #815:
- kv with 64 KiB values on 22 workers: 34-40 MB rather than 56-61 MB (about 34% less), for
  1.1-1.5% fewer requests a second by the median of 50 pairs, 3.3-4.2% by the geomean.
- xmalloc-test: 80 MB rather than 275 MB (71% less), level within the noise floor.
- sh8bench: level to 1.6% faster.
- Trig's time and memory, and every other bench, unchanged.

The brief's bar is "nothing slower", so the work stops here.

## Next (superseded by the trade above)

1. Build Trig PGO for arm a on the E-cores, and time ts-pattern and zod3 against main's build
   (`harness/trigtime.sh`, core 3, about 10 minutes). Default: yes, with a only.
2. If Trig is within 2% with RSS no higher, Rig builds arm a as a PR on current main, with the
   full gates. Default: a over ac, because a has no cross-heap list walk, kv64k is 0.2% slower
   against ac's 1.5%, and its memory differs from ac's only on xmalloc-test (78 MB against 62).
3. ac's per-page remote walk (c) waits as its own row, since its gain is xmalloc's 16 MB.
   Default: backlog.

Prototypes and builds on pup: /zfs/worktrees/rig/mem-both (rig-ARM, kv-ARM, shim/ARM,
packs/main-pgo).
