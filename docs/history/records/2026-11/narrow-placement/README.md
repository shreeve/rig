# Narrow placement: where the workers go when a wide phase narrows, measured: a negative (2026-11-24)

Rig - Final, for Rig (foreman). This is a follow-on to race 754 ([phase-workers/race-754.md](../phase-workers/race-754.md)).
That race left W's check 0.3-0.9% slower than main's. Trig's measurement ([narrow-split.md](narrow-split.md)) traced
the loss to where the surviving workers sit after `task.narrow()`, and to frees landing in the parked heaps. Rig built
the two fixes Trig named as switches on a scratch build, and race 755 timed them. Nothing landed. The scratch is kept
as `archive/narrow-place`.

## 1. Three findings from the code

1. **No affinity anywhere.** The runtime calls `sched_getaffinity` only to count CPUs: `linuxFastCores` sizes the
   worker count, and `fastThreads` sizes the widen. Workers are plain threads that Linux places as it likes. The 754
   scratch's narrow keeps workers 0..n-1 by index and does not look at which CPUs they are on. So two survivors can
   share one P-core's sibling pair, and main's own unpinned workers can do the same.
2. **No spinning.** An idle worker makes one pass over the other rings (`stealNext` busy-waits 3 µs for a victim that
   holds a run-next fiber). It then blocks in its own poller with no timeout of its own. The exceptions are its
   earliest timer, one 10 ms trim wait if its heap grew, and the 1 ms watcher role while a busy worker holds
   descriptors. A parked worker blocks in its poller. Nothing keeps a sibling looking busy to the kernel's balancer,
   so the stacking is the kernel's choice: with each logical CPU running one task, it has nothing queued to pull.
3. **The donor-heap free path.** `free` takes its fast path only when the block's segment belongs to the running
   thread's heap. Otherwise `freeSlow` → `Heap.freeSmall` pushes the block onto the owner's `remote[c]` list with one
   CAS. A parked worker's heap is a donor. The survivors take one of its remote lists whole (`takeDonated`) only when
   their own free list, remote list and carve page are all empty. Blocks taken that way stay the donor's, so every
   later free of one goes back through `freeSlow` and a CAS. The parked heaps' lists become a pool that all the
   survivors cycle blocks through, which fits the tripled `freeSlow` Trig measured.

## 2. Trig's narrow-split (race 754's binary, nuxt and webpack at c4, 16 rounds an arm)

- **Stacking is bimodal.** When two checker threads land on one P-core's sibling pair, they stay there for the whole
  check (0-2 migrations), each at IPC 1.15-1.25 instead of 1.8-1.95. A stacked run costs 49.8 ms on nuxt and
  105.7 ms on webpack. In Trig's runs, 54% (nuxt) and 39% (webpack) of W's runs stacked, against 5% and 7% of M's:
  about 25 and 38 ms on the mean. Four busy threads on random distinct CPUs of twelve land on four cores with
  p = 0.485.
- **The race's medians did not show it.** Race 754 had 0 of 10 and 1 of 10 W runs stacked: about 0 on the median and
  5 ms on webpack's mean.
- **Heaps, in runs with no stacking.** `freeSlow` was 0.017 → 0.059 Gcycles (nuxt) and 0.032 → 0.076 (webpack);
  allocation rose 0.020 and 0.029. Snoop-forwarded loads doubled (160 K → 386 K on webpack) at an even rate through
  the check. The cycle estimate was 4.3 ms (nuxt) and 7.3 ms (webpack), against flat-run W − M measured at about 0
  and 3.6 ms (race 754: 2 and 11).
- **Cold caches about 0** (at most 0.6 ms). **The narrowing itself** costs about 1 ms between the bind's end and the
  check's start.
- **Trig's proposed fixes:** keep one survivor per physical core, by pinning or by choosing whom to park; and keep
  frees out of the parked heaps.

## 3. The scratch: rig d77e182d0 (on e26d0196a)

Three switches, read as the workers start. With all three unset, the code runs 754's paths.

| switch | what it does |
|---|---|
| `RIG_SPREAD=1` | `narrow` keeps worker 0, then one worker per physical core by the CPU each last ran on (`/proc/self/task/TID/stat`, field 39), lowest index first (`chooseKept`). |
| `RIG_PIN=1` | While the workers that run tasks are no more than the physical cores, each is pinned to its own core's sibling set, at start and after every widen and narrow (`place`). Past the core count, every worker is unpinned. Threads the runtime starts drop the pin they inherit. |
| `RIG_GIVE=1` | A parking worker gives its heap's small-block segments to the survivors' heaps (`seg.heap` rewritten), moves its remote lists' blocks to their new owners, and stops being a donor (`alloc.giveSegments`). A survivor's free of such a block then takes the fast path. |

Physical cores are the fast set (`/sys/devices/cpu_core/cpus`) within the process's start mask, grouped by
`thread_siblings_list`.

**Gates:**
- `test/cli/phase_wide.sh` runs every program 3 times under each arm. It checks that every widening arm widens and,
  on Linux, that a held program's two active workers are pinned to different cores. It passed on burst, the Mac and
  pup.
- The core suite passed on pup with the switches off and on, and on the Mac with them off. The failures in loaded
  runs passed alone; `stack_census`'s Linux failure predated the scratch and was fixed on main in #1250.

**Two bugs found by the gates before the race:**
- Threads the runtime starts inherited their starter's pin.
- Under `RIG_PIN=1`, the widen read a pinned thread's mask and never widened. It now reads the process's start mask.

## 4. Race 755

**Trig:** phase-wide-trig 995763d59, race 754's Trig (`task.widen()` before the load, `task.narrow()` after the
bind), built PGO+BOLT on d77e182d0. sha16 a93a258c52086912.

**Arms:**
- **M:** nothing set.
- **W:** `RIG_WIDE=1`.
- **S:** W + `RIG_SPREAD=1`.
- **P:** S + `RIG_PIN=1`.
- **F:** P + `RIG_GIVE=1`.
- **Q:** `RIG_PIN=1` alone: main's path with one worker pinned per physical core.

**The race:** 16 projects at c2, c4 and c8, 10 rounds after a warm-up, on pup's P-cores 0-11 in Rig's slot 755
(`race-755/slot-np.sh`). Outputs agree in every case. No switch acts at c1, so it was not run.

**Summed over the 16 projects** (medians of rounds 1-10; `race-755/table.py`):

| c | arm | summed wall (ratio to M) | parse+bind (ms) | check (ms) | peak RSS (ratio to M) |
|---|---|---:|---:|---:|---:|
| c2 | M | 13298 ms (1.000) | 1332 | 11292 | 1.000 |
| c2 | W | 13215 ms (0.994) | 1250 | 11298 | 1.055 |
| c2 | S | 13211 ms (0.993) | 1251 | 11292 | 1.056 |
| c2 | P | 13553 ms (1.019) | 1250 | 11622 | 1.056 |
| c2 | F | 13456 ms (1.012) | 1250 | 11519 | 1.059 |
| c2 | Q | 13501 ms (1.015) | 1322 | 11505 | 1.001 |
| c4 | M | 9036 ms (1.000) | 1328 | 7094 | 1.000 |
| c4 | W | 9095 ms (1.007) | 1252 | 7216 | 1.045 |
| c4 | S | 9056 ms (1.002) | 1254 | 7180 | 1.042 |
| c4 | P | 9115 ms (1.009) | 1251 | 7227 | 1.045 |
| c4 | F | 9071 ms (1.004) | 1254 | 7182 | 1.050 |
| c4 | Q | 9090 ms (1.006) | 1328 | 7146 | 1.002 |
| c8 | M | 8140 ms (1.000) | 1293 | 6224 | 1.000 |
| c8 | W | 8126 ms (0.998) | 1250 | 6243 | 1.019 |
| c8 | S | 8201 ms (1.008) | 1250 | 6309 | 1.021 |
| c8 | P | 8183 ms (1.005) | 1252 | 6307 | 1.019 |
| c8 | F | 8147 ms (1.001) | 1254 | 6270 | 1.025 |
| c8 | Q | 8145 ms (1.001) | 1296 | 6210 | 1.003 |

Rig's reading (median over rounds of the per-round ratio) gives the same picture within 0.4 points: W 0.991 / 1.007 /
0.998, S 0.992 / 1.003 / 1.011, P 1.017 / 1.010 / 1.003, F 1.008 / 1.008 / 1.003 and Q 1.014 / 1.010 / 1.003 at c2 /
c4 / c8. Trig's scoring of the same rows (score-np.py, the sum of each project's medians) matches the table above
to the third digit. Each project at c4, with nuxt's and webpack's check times round by round, is in `race-755/c4-projects.md`.
The raw rows are `race-755/runs`, copied from pup:/zfs/trig-pup/trial/np/races/board16.

## 5. Reading

- **No arm clears the bar.** Summed wall moves at most 1.9%, and that is slower (P at c2). No arm is faster than M by
  more than 0.7%.
- **Pinning costs about 1%.** Q, which is main's path pinned, is 1.5% slower at c2 and 0.6% slower at c4. P against S,
  the same spread with the pin added, is 2.6% slower at c2 and 0.7% slower at c4. The likely cause, not measured: a
  pinned worker cannot leave a core that another thread (the program's main thread, or the kernel's) also wants.
- **The stacking Trig saw does not show in race medians.** nuxt and webpack at c4 do not move in any arm. In W at c4,
  webpack's ten checks run 279-294 ms, where Trig's stacked runs took about 390-416. Across all 16 projects at c4,
  4 of W's 160 runs had a check more than 12% over M's median, against 2 of M's and none in S, P, F or Q. So spreading
  removes the rare stacked run, but it is too rare in the race to move a median. Why Trig's runs stacked 39-54% of the
  time was not found.
- **The check pays for a wide load even with spread and pin.** Trig's medians, in ms, as wall (parse+bind + check):

  | cell | M | W | S | P | F | Q |
  |---|---|---|---|---|---|---|
  | nuxt c4 | 355 (77+246) | 354 (69+254) | 355 (69+255) | 352 (69+251) | 353 (69+252) | 358 (78+251) |
  | nuxt c8 | 340 (73+235) | 333 (68+232) | 335 (70+232) | 336 (69+232) | 337 (70+234) | 334 (74+228) |
  | webpack c4 | 363 (57+278) | 368 (55+282) | 370 (54+285) | 370 (54+285) | 365 (55+276) | 364 (56+278) |

  Every wide arm cuts nuxt c4's front end by about 8 ms and gives back 5-9 ms in the check, S and P included. So the
  check's loss after a wide load is not only placement. Over all 16 projects the same holds: the wide arms' parse+bind
  is 74-82 ms lower than M's at c2 and c4, and their check 86-133 ms higher at c4.
- **Giving the heaps away helps a little and costs memory.** F is 0.4-0.7 points faster than P at every count, and its
  webpack check median is 276 ms against P's 285. Its peak RSS is 0.3-0.6 points above P's, and it never beats M.
- **Peak memory** is 2-6% higher in every wide arm, as in race 754. Q is level with M (0.1-0.3%).

## Decision

The race is filed as a measured negative. Pinning costs about 1%, the stacking Trig found does not show in race
medians, and the check gives back what a wide load gains whether or not the workers are spread. Main stays unpinned, and `task.widen()` stays parked (race 754). The scratch is tagged
`archive/narrow-place`: d77e182d0 holds the three switches and phase_wide.sh's arms and pin check. If wide phases are
revisited, start from its `RIG_GIVE` and `chooseKept`, beside task-chosen arenas.
