# psum gap: the fork-join machinery and the first parallel pass (runtime expert)

Working notes, then the report at the end. Everything here lives in
`/Users/shreeve/Data/Code/Claude/rig/rig/psum-gap/runtime/` (programs, drivers, raw boards) and on pup in
`/zfs/trig-pup/psum-gap/runtime/`. Probe branch (never to merge): `psum-runtime-trace` (scratch per-pass
counters and start-up knobs in src/sched.zig; the scripts that write them are `runtime/tools/*.py`).

## The probe program

`split.rig` and its Rayon twin `rayon/` (Rayon 1.12, LTO, one codegen unit, as the record's): build the
2^25 Ints, then in one process: `seqsum` (the leaf loop over all 256 MB, no forks), `psum1` (the first
parallel pass: cold), `psum2`, `psum3` (warm), and `nil1-3`: the same tree of 4,096 leaves over the same
slices, each leaf giving its length (fork-join alone, no memory). `splitR.rig` / `rayonR/` swap which half
runs inline (see below). `splitX.rig` adds `task.workers(63)` marks around each pass for the instrumented
build, and `PRE=1` makes a task at `main`'s start (workers started early).

## Finding 1: the twins walk memory in opposite orders (most of the 1-worker gap)

`a = psum(?left)&; b = psum(xs[mid..]); >a` forks the LEFT half and computes the RIGHT inline;
`rayon::join(|| psum(l), || psum(r))` runs the LEFT inline and offers the right. At one worker Rig
therefore sums the 4,096 leaves from the top address down (each leaf forward), Rayon from the bottom up.
The like-for-like Rayon twin of fork.rig is `join(|| psum(r), || psum(l))` (rayonR); the like-for-like
Rig twin of the Rayon program forks the right half (rigR).

Board B1 (Mac M5, 20 rounds, medians ms) and P1 (pup, slot 570, 20 rounds):

| machine, cfg | row | rig | rigR | rayon | rayonR |
|---|---|---|---|---|---|
| Mac, 1 | psum3 | 4.980 | 3.837 | 3.651 | 4.775 |
| Mac, 1 | nil | 0.256 | 0.253 | 0.042 | 0.043 |
| Mac, 10 | psum1 | 2.251 | 2.337 | 2.205 | 2.152 |
| Mac, 10 | psum3 | 2.138 | 2.153 | 2.067 | 2.118 |
| pup, 1 | seqsum | 11.884 | 11.863 | 11.348 | 11.339 |
| pup, 1 | psum3 | 13.968 | 13.406 | 12.184 | 13.262 |
| pup, 1 | nil | 0.358 | 0.362 | 0.057 | 0.057 |
| pup, 12 | psum1 | 6.383 | 6.193 | 4.303 | 4.558 |
| pup, 12 | psum3 | 3.243 | 3.135 | 3.089 | 3.157 |

- Mac, 1 worker: the walk is 23% of Rig's psum (4.98 → 3.84); Rayon walking Rig's way loses 24-31%
  (3.65 → 4.78). Like for like, Rig trails Rayon by 5% (rigR 3.84 vs 3.65, rig 4.98 vs rayonR 4.78), and
  that is the per-join cost (nil: 0.21 ms of fork-join machinery over Rayon's).
- pup, 1 worker: the walk is 4% for Rig (13.97 → 13.41), 9% for Rayon. Like for like the gap is
  0.7 ms (rig 13.97 vs rayonR 13.26) = the leaf (seqsum 0.53 ms slower: the leaf expert's) + the
  per-join cost (nil 0.30 ms).
- All workers: the walk barely matters (Mac rigR 1-4% slower, pup 3-4% faster).

The order is the program's choice, not the runtime's: `&` offers its call for stealing and the maker
goes on, so the half written on the task is the one a single worker reaches last. A runtime that ran the
task first (child-first, Cilk's work-first) would make the record's program walk forward, but it
changes what `&` does (documented: the maker runs on), so it is the owner's call, not built.

## Finding 2: per join, Rig pays 60-86 ns where Rayon pays 10-15 (the 1-worker machinery)

`nil` (4,095 joins, no memory) at one worker: Mac 0.256 ms against Rayon's 0.042 (60 ns a join against
10); pup 0.358 against 0.057 (86 ns against 14). Counts per pass (instrumented build, both machines):
4,095 spawns, ~3,830 handoffs from a slot, ~170-250 from the ring, 0 parks at one worker; at all
workers 60-170 parks, 70-120 steals, 7-22 slot steals, ~4,000 stacks from the free list.

perf of a 400-pass `nil` loop at one worker on pup (`J2`): `Header.waitEndApart` (the handoff, inlined)
30%, `fiberMain` 8%, `wakeIn` 7%, `Full.start` 5%, `me` (not inlined) 4%, `spawnApart` 4%,
`fiberStartNaked` 3%, `endStack` 3%. In `waitEndApart` the samples sit on its locked instructions: the
waiter's wait word (`beginWait`, xchg 11%), the slot take (lock cmpxchg 9%), the three `Done` stores
before the switch (xchg 10%, 11%, 7%) and the status store after (xchg 8%). On x86 every seq_cst store is
an `xchg`, a full fence.

Built as a probe (`tools/relax.py`, commit 148feaeaa on the probe branch): the handoff's waiter word is
stored with release when no cancel can end the wait (no flag is read after it, so no store-load fence is
needed), the `Done` waiter and epoch monotonic and its status release (read only along the chain that
hands the task's fiber to another worker, or by the waiter itself on this thread), the status `ended`
release. The read-modify-writes that race (the slot take, the waiter's marking in `fiberMain`, `claim`)
keep seq_cst.

| pup, one worker, `nil` x 400 (8 runs each, interleaved, slot 577) | ms | ns a join |
|---|---|---|
| probe base (cae60ac91) | 140.7-143.6, median 141.0 | 86 |
| relaxed handoff stores (148feaeaa) | 115.1-117.3, median 116.5 | 71 |

17% less a join on x86. On the Mac (AArch64 stores seq_cst and release alike as `stlr`) nothing
changes (105.9-107.9 against 106.1-107.8 ms). For psum it is ~0.06 ms at one worker on pup (0.4%).

## Finding 3: the cold first pass on pup is starvation, not slow leaves

pup, 12 workers, psum1 against psum3 (warm): Rig 6.3-6.6 ms against 3.2-3.4; Rayon 4.3 against 3.1.
Rig pays ~3 ms for the first pass, Rayon ~1.2 (of which ~0.8 is its 11 thread spawns before the work).

Thread start is slow on pup: a Zig `std.Thread.spawn` costs its spawner 55-90 µs (clone 30-40 µs of it),
so 11 in a row take 0.75-0.94 ms (`ceil/spawn.zig`, J5); a binary tree of spawns starts the last at
~0.5 ms. In Rig the first pass starts worker 1, which maps every worker's first 16 stacks (11 x 17 system
calls) and then spawns the rest while the work runs: workers 2-11 first run at 0.75 / 1.3 / 3.0 ms
(first / middle / last, medians of 10, J4/J6).

Start-up arms (instrumented build, env knobs; `arms.py`, medians; Mac 15 rounds M2/M3, pup 10-12 rounds
J4/J6; "first run" = when the first / middle / last of workers 1..n-1 first ran a fiber in psum1):

| arm | Mac psum1 | Mac first run µs | pup psum1 | pup first run µs |
|---|---|---|---|---|
| base (as built: worker 1 maps all, then spawns) | 2.234-2.261 | 186 / 243 / 273 | 6.33-6.55 | 737 / 1321 / 3000 |
| worker 1 spawns first, each maps its own | 2.361 | 114 / 280 / 388 | 6.36 | 468 / 1219 / 2933 |
| no stacks mapped ahead | 2.330 | 69 / 152 / 334 | 6.29 | 271 / 651 / 2164 |
| `main` spawns all (Rayon's way) | 2.423 | 232 / 263 / 311 | 7.39 | 859 / 925 / 1962 |
| tree: worker i starts 2i and 2i+1 (maps their stacks on macOS only) | 2.252 | 153 / 273 / 349 | 6.54 | 315 / 878 / 1994 |
| PRE: a task at `main`'s start (workers up 0.3 s early) | 2.082 | 19 / 89 / 141 | 5.60-5.92 | 21-24 / 361 / 571-590 |
| warm psum3 (base) | 2.03-2.08 | 10 / 41 / 139 | 3.20-3.35 | 9 / 44 / 213 |

Starting the threads sooner barely moves pup's psum1: the tree starts them 1 ms sooner and the pass is
no faster, and with every worker up 0.3 s before (PRE) the pass still takes 5.6-6.0 ms against 3.2.

Leaf time (`leaft.rig`: each leaf times itself; J7, 8 runs, medians): the leaves' summed time is the
same in the cold pass as in warm ones (pass 1 38.5 ms cold, 36.8 PRE; warm 35-42), while the wall time
is twice as long (6.5 / 6.0 against 3.2). The leaves are not slower: the workers sit idle. Average
parallelism in the cold pass is ~6 of 12 (36.8 / 6.0), warm ~11 (35.3 / 3.16).

### What the idle workers wait for: their heaps' first huge page, and thread start

Run under `nothp` (`ceil/nothp.zig`: `prctl(PR_SET_THP_DISABLE)`, a per-process setting, then exec), and
with a probe knob that has each worker take its heap's first segment (allocate and free one record) as
its thread starts, before it looks for work (`RIG_X_WARMHEAP`, commit 2486d1a03). pup, 12 workers,
12 rounds (J9; J8 agrees), medians ms; Rayon in the same slot psum1 4.26-5.07, median 4.32:

| arm | psum1 | psum2 | psum3 | first run µs (first / mid / last) |
|---|---|---|---|---|
| base | 6.502 | 3.479 | 3.174 | 759 / 1607 / 3007 |
| heap warmed as each worker starts (lazy start) | 6.280 | 3.452 | 3.305 | 1104 / 2518 / 3790 |
| tree start + warmed heap | 6.616 | 3.363 | 3.177 | 613 / 1997 / 3161 |
| THP off (`nothp`) | 5.003 | 3.562 | 3.222 | 760 / 1051 / 1794 |
| PRE (workers up early) + THP off | 4.216 | 3.518 | 3.241 | 115 / 399 / 554 |
| **PRE + heap warmed as each worker starts** | **3.871** | 3.371 | 3.204 | 27 / 265 / 585 |

- Each worker's heap asks for huge pages for its first segment (`alloc.zig`, `mapSegment`), so its first
  task record faults in and zeroes 2 MiB. In the first pass that happens on each worker as it takes its
  first stolen subtree, while eleven other cores stream memory: 0.4-0.9 ms a worker (warming at thread
  start moves the first runs 350-900 µs later), and the stolen subtree, a quarter or an eighth of the
  array, waits behind it with nothing in the worker's ring yet for others to take. With THP off the
  pass is 1.5 ms faster (6.50 → 5.00) and warm passes are unchanged (3.17 → 3.22).
- Thread start is the other ~0.8 ms (THP off: lazy 5.00 against workers up early 4.22). Starting
  sooner within the first pass does not help: the tree starts the last worker 1 ms sooner and psum1 is
  no faster.
- With both off the pass (workers up early, heap warmed at their start) psum1 is **3.87 ms, 10% faster
  than Rayon's 4.32**, 0.67 ms over warm where Rayon's is 1.2.

The heap's first segment is the memory expert's code (allocator, huge pages): what to change there
(small pages for a heap's first segment, or its first fault taken before the worker takes work) is
theirs. What only the runtime can do is the start: workers that start before the first `&` (the
startup record's fix 1, documented behavior, the owner's call) and fault their heap then.

## Finding 4: the Mac is already close, cold and warm

Mac, 10 workers, same program (B1, M2, M3): psum1 2.23-2.26, psum3 2.03-2.14; Rayon psum1 2.21, psum3
2.07. The first pass costs Rig 0.19 ms over warm against Rayon's 0.11-0.14, and starting the workers
early (PRE) takes psum1 to 2.08 (7% faster). Tree start, spawning first, no premapping, and `main`
spawning all are level or slower on the Mac (its spawns cost 7 µs; mapping during the ramp is what
costs there, the startup record's finding). Waking two workers where one is woken (`RIG_X_FAN`: a
searcher that finds work wakes two, so idle workers wake in a tree) is level on both machines (Mac psum3
2.010 against 2.030; pup no better); not pursued.

The record's own board (fork.rig, one psum per process, no seqsum before it) trails Rayon by 5-7% on
the Mac at 10 workers; in split.rig, with a sequential pass over the data first, Rig's psum1 is within
2% of Rayon's. What differs is the first touch of data written moments before (fork.rig's psum reads the
array right after building it); not chased further.

## Built: the handoff's stores without a fence (draft PR #1152)

Branch `psum-handoff` (ddaaeef99 + 3029cea57), from origin/main d62fe2d33. src/sched.zig: `handoff()` and a
new `beginPlainWait` (the only lines touched; nothing else in sched.zig moves); test/cli/wait_sync.sh
and a comment in formal/LambdaRig/Wait.lean list it as the `begin` step with `c` false; CHANGELOG.
pup, against main d62fe2d33 with an A/A copy (J10 slot 570, J11 slot 571, 20 rounds; tasks 10):

| row | handoff / main | A/A |
|---|---|---|
| nil x 400, 1 worker | 0.834 (138.3 → 115.3 ms; 86 → 71 ns a join) | |
| bench/tasks chain / spawn / fanout / yield / hog / produce, 12 | 0.804 / 0.980 / 1.005 / 1.046 / 0.869 / 1.015 | 0.935 / 0.994 / 0.998 / 1.029 / 1.101 / 1.018 |
| fork psum 1 / 12 | 0.996, 0.998 / 1.002, 0.974 | 0.996, 1.000 / 1.016, 0.967 |
| fork qsort 1 / 12 | 1.041, 1.031 / 1.039, 0.998 | 1.011, 0.997 / 1.030, 0.988 |
| layout control (+96 never-run bytes, qsort back at main's offset mod 128): qsort 1 / 12, psum 1 / 12 | 1.008 / 0.990, 0.996 / 0.959 | |

Against Rayon (J10): psum 1 worker Rig 14.27 against 11.92 (20% slower), 12 workers 6.16 against 4.72
(30% slower): the change does not move psum; its gaps are findings 1-3. Mac: AArch64 emits the same
`stlr` for both orders, so the build is level by construction (nil 106 ms both).

Gates: Mac `zig build test`, Mac core suite (12,141 jobs; `cli.wait_sync` caught the new function,
fixed in 3029cea57, rerun green). pup `zig build test` in three modes (debug, safe, fast): pass. Not run: actors, net,
http, the guards, Trig's and loco's light gates, a second reader for the orderings.

Quiet-check notes: slots 574 and 571 recorded other sessions' builds on E-cores 12-19 (a `zig
build-exe` from psum-gap/leaf, a `zig test -Ofast`); timed work ran on P-cores 0-11.

## Decisions for the owner (defaults first)

1. **Workers start before the first `&`, and each faults its heap's first segment as it starts**
   (startup record's fix 1 plus the heap): pup psum1 6.50 → 3.87 ms, 10% faster than Rayon's 4.32
   (prewarm, J9); Mac psum1 2.23 → 2.08 (PRE, M3). Documented behavior changes ("a program that makes none
   starts no workers"); cost: ~0.1 ms of thread start at program start and 2 MiB a worker on Linux.
   Default: approve, limited to programs whose compiled code can make a task (option a of that record).
2. **Like-for-like twins in bench/fork**: Rayon's twin runs the same half inline as the Rig program
   (`join(|| psum(r), || psum(l))`), or the Rig program forks the right half. Default: change the Rig
   program to fork the right half (the Rayon and Cilk idiom: the half offered for stealing is the one
   reached last), and say in docs/CONCURRENCY.md's fork-join example that the forked half is the later
   one. Mac 1-worker psum then trails Rayon 5%, not 36%.
3. **Child-first `&`** (run the task at once, offer the maker's continuation): makes either order walk
   forward; changes what `&` means and every program's interleaving. Default: no.
4. For the memory expert, not the owner: a heap's first segment on huge pages costs the cold pass
   ~1.5 ms on pup (THP off: 6.50 → 5.00, warm level). Default: their call (small pages for a heap's first
   segment, or its first fault taken before the worker takes work).

## Left open

- The warm gap at 12 workers on pup is 3-5% (psum3 3.17-3.30 against Rayon 3.07-3.13); the ramp from a
  sleeping pool is 150-300 µs to the last worker. Waking in a tree (`RIG_X_FAN`) did not help.
- The preemption monitor stops 20-55 fibers in some warm 12-worker passes on pup (`preempted` per pass):
  slot handoffs keep a fork-join on the waiter's count, and its slots hold work at two looks. No
  measurable cost here; fork-join-2's mode 2/3 question for the owner covers it.
- Per join, Rig still pays 71 ns on x86 against Rayon's 14: a record allocated and freed, a stack taken
  and a switch each way, a slot swap and take. Rayon's jobs live on the stack and run inline; that is the
  free fork-join design round (the record of fork-join direction), not this change.
