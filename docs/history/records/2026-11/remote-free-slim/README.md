# Batched remote frees, slim (2026-11-27)

PR #1367, branch `remote-free-slim`. The algorithm of #1363
(`archive/remote-free-batch`), which the owner judged a better algorithm
worth landing but too large, in about half its code.

## The change

A block of at most 1 KiB (`out_class`) freed on a thread whose heap did
not make it waits in `Heap.outgoing[c]`, one slot per class, with other
blocks of the same heap. Up to 16 (`out_batch`) go onto the owner's
remote list with one compare-and-swap: when the slot is full, when a
block of another heap takes the slot, or when the thread trims
(`trimHeap`) or ends (`threadExit`). `freeSmall` does all of this
itself, with no `freeHere`. `pushRemote` is the one push of a linked
run, and the trim's own push of its free lists uses it too.

What it keeps from #1363:

- A batch never outlives its thread: `threadExit` flushes it.
- `h` is read in a frame that switches no fiber before `freeSmall`
  returns (`freeSlow`, `freeRecord`). The batch is `h`'s own, like its
  free list. A safe build's owner check covers the batch path, and the
  scheduler's test of fibers that move between threads runs it.
- A waiting block's page is not trimmed. Its block is on no list the
  owner walks, so the page never counts as wholly free.
- Publishing is unchanged: release on the push, acquire on the owner's
  swap.

What differs from #1363: there is one slot per class rather than 16
hashed slots, so `outSlot`, its comptime check and the `class` field are
gone. A sleeping worker's trim also flushes its batches, so a worker
that sleeps for a long time does not keep other heaps' blocks.

Lines in src/alloc.zig, net, against main (#1363's in brackets):

| | slim | #1363 |
|---|---|---|
| logic | 21 (35 added, 14 removed) | 45 |
| comments | 22 | 38 |
| tests | 108 | 137 |

The tests: the four-thread stress test from #1363 (no block handed out
twice), now with each thread freeing mostly one other heap's blocks. As
#1363 wrote it, three owners alternated within each class, a per-class
batch never filled, and a mutation that pushes a batch twice passed. Now
that mutation fails at once. Plus a batch test, single-threaded on test
heaps: a batch minus one block waits, the last block sends the batch,
and a block of another heap flushes the slot.

## Measurements (pup)

Trig at the same tree as /zfs/worktrees/l4b/main (symbols, no debug
info), built on burst at three Rigs: base ed1c50d2b (main before #1362
and #1358), slim 2f64bbe2a, and hash c9391e234. The hash arm is slim
with 16 hashed slots keyed by heap and class, the shape of #1363. The
three binaries print the same output on webpack c4.

### Remote compare-and-swaps (E-cores 12-19, 3 rounds, `cas-ecores.txt`)

Uprobes (`casprobe.sh`) sit on the link store just before each
compare-and-swap onto a remote list, in freeSlow, freeRecord*,
Heap.freeSmall and threadExit. Each probe is placed by file offset from
its function's own address range. The l4b probe script's counts (the CAS
lines in `pcore.sum`, and #1363's 92-97%) are not comparable, for three
reasons:

- It matched only indexed CAS forms, so it missed `freeRecord`'s
  constant-class pushes.
- On burst its `sym+off` probes resolved through debug lines into other
  functions, and the slim and hash binaries aborted.
- The probe after the CAS never fired on burst.

Medians:

| cell | base | slim | hash | slim fewer | hash fewer |
|---|---|---|---|---|---|
| webpack c4 | 310,273 | 75,858 | 58,793 | 75% | 81% |
| nuxt c4 | 298,932 | 121,987 | 110,715 | 59% | 63% |
| nuxt c8 | 321,597 | 119,062 | 107,725 | 63% | 66% |

The rest are blocks over 1 KiB, which go one at a time, batches cut
short, and flushes. Locked instructions in user mode
(`mem_uops_retired.lock_loads`) fall with them: webpack c4 from 438k to
2.3M (spin locks make base noisy) down to 184-213k, and nuxt c4 from
601-681k to 411-427k.

### Per class or hashed

One slot per class leaves 10% more compare-and-swaps than 16 hashed
slots on nuxt (c4 and c8) and 29% more on webpack c4. As reductions from
base, that is 59-75% against 63-81%: the per-class slot keeps all but 4
to 6 points of the hashed reduction. The hash costs about 8 more lines
of logic plus a comptime check. The per-class slot is kept.

### Time and memory (P-cores 0-11, one `cpuq drain`, 9 rounds stat, 3 rounds record, `pcore.sum`)

| cell | arm | CPU ms | allocator Gcycles | RSS MB |
|---|---|---|---|---|
| webpack c4 | base | 1495 | 0.213 | 346.7 |
| | slim | 1502 | 0.169 | 347.2 |
| | hash | 1509 | 0.180 | 343.4 |
| nuxt c4 | base | 1518 | 0.256 | 388.7 |
| | slim | 1525 | 0.256 | 386.7 |
| | hash | 1526 | 0.242 | 385.6 |
| nuxt c8 | base | 2141 | (no record) | 446.6 |
| | slim | 2133 | | 449.5 |
| | hash | 2133 | | 447.7 |

The allocator's own cycles on webpack c4 are 21% fewer, and on nuxt c4
they are level. CPU time and RSS are within noise.

## Gates

- `zig build test`: safe on the Mac at 2f64bbe2a; debug, safe and fast
  on pup at dd446a264 (merged with main).
- Stress test: 200 runs on the Mac and 50 on pup, 0 bad. The s.rig
  cross-task stress program: 50 runs on pup, 0 bad.
- Core suite on burst: 0 died at 2f64bbe2a and at dd446a264, apart from
  the known burst-only cli failures.
- Trig light gate on burst: GREEN (119 of 119) at both commits.
- loco light gate: GREEN at both commits.
- Guards at dd446a264, all within 2%:
  - json: at most 0.5% more
  - hash: at most 0.3% more
  - text: 0.0%
  - check: 5.8% fewer instructions than its baseline

  The check guard's pass-time gate flags `lower`. Main's own Rig, run
  the same way, flags it too (15.3 against 10.9 ms), and the compiler
  does not use alloc.zig (it uses `smp_allocator`).
