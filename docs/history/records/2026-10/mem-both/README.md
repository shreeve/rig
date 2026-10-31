# Memory and speed both: row 21's Zig ceiling, round 1 (2026-10-31)

The owner's words: "We need BOTH the SPEED and the MEMORY wins". The goal is #785's memory cut
(tag `archive/mem-alloc-b`) with every row, and Trig's time and RSS, within 2% of main.

**Round 1's verdict: no arm is shown to meet the bar, and none is shown to miss it.** On pup the
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

## Next (round 2, for Rig - Swiss to schedule)

1. Time main, a, ac and b2c only, 10 rounds rotated (about 25 minutes), so a median of 10 can
   resolve 2%. Default: yes.
2. Build Trig PGO for a and ac on the E-cores when release builds are allowed, and time ts-pattern
   and zod3 against main's build (`harness/trigtime.sh`, core 3, about 10 minutes). Default: yes.
3. The arm to build into a PR, if round 2 shows it within 2%: ac if xmalloc's memory counts, a
   if only kv's does. Default: ac. It has 46 MB on kv64k and 57 MB on xmalloc-test, against #785's
   31-33 and 38-53, and it has no lock and no shared pool.

Prototypes and builds on pup: /zfs/worktrees/rig/mem-both (rig-ARM, kv-ARM, shim/ARM,
packs/main-pgo).
