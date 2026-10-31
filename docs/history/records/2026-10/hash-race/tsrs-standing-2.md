# Where Trig stands against tsrs, after the memory round (2026-10-28)

The question: with #740 (huge pages for busy heaps), #743 (no stored
hash for small plain Map keys), #746 (`String(...)` allocated once;
HashMap walks by `next_slot`), #749 (faster allocator growth) and #754
(huge pages for Tables past 2 MiB) on Rig main, how far is Trig's PGO
build behind shipped tsrs at one checker, and what did #754 give under
PGO? The method is [tsrs-standing.md](tsrs-standing.md)'s, one day
later. Measurement only; no code changed. Scripts and raw output are in
[tsrs-standing-2-data/](tsrs-standing-2-data/).

## Method

- **Machine.** pup (Core Ultra 9 185H). Every run on P-core 1, its
  sibling 2 idle (`taskset -c 1`); before each round `time.sh` waited
  until no other thread ran on core 1 or 2 (it waited three times, a
  minute in all). Other sessions built on release slot 10,11 and timed
  on cores 3, 6 and 8 throughout; load average 1.5 to 3.0.
- **Trig.** Main `403a823`, as on 2026-10-27 (Trig main has not moved),
  its `src/` and `tools/trig` taken by `git archive` and its projects
  copied beside them, so the cron's checkout cannot move under the
  builds or the timing. `tools/trig/main.rig` is the root.
- **Rigs.** Each in its own clone under `/zfs/worktrees/rig/tsrs-standing-2`,
  built with `zig build` on cores 1,2:
  - main `773978d1d` (#754);
  - `2c01f07dd` (#749), main before #754. The two differ in `src/` and
    `std/` by #754 alone (#751 and #752 between them are records and
    bench data), so this step is #754.
  - `36422da59`, the 2026-10-27 record's main. Its PGO build was cached:
    the same binary (sha256 `dab6b92c...`) timed again.
- **Builds.** Each Trig built through `/zfs/trig-pup/trial/slot.sh`
  with `TRIG_RELEASE_SLOTS='10,11'`, `rig build --release --pgo` trained
  by `tools/trig/bolt-train` (mitt, neverthrow, superstruct, zod3), as
  `tools/trig/pgo` builds it and Trig ships. No plain builds this time.
- **tsrs.** The shipped 0.18.0 (PGO, fat LTO, BOLT) and its source
  build, Go mode on one thread:
  `RAYON_NUM_THREADS=1 tsrs -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers`.
  Trig: `trig -p tsconfig.trig.json --noEmit --singleThreaded`.
- **Timing** (`time.sh`). 20 rounds, the five variants interleaved in
  each, ts-pattern then zod3; then all of it again (`times-b.txt`), to
  see whether #754's step on zod3 held. One `perf stat` per run gives
  wall time (`duration_time`), `user_time`, `system_time`, user and
  kernel cycles (`cpu_core/cycles/u`, `/k`), user instructions and page
  faults; peak RSS is `/usr/bin/time`'s. A round 0, not counted, kept
  each project's reference output; every Trig run matched Trig's
  reference byte for byte and every tsrs run tsrs's, in all 80 rounds,
  and Trig's reference and tsrs's are the same bytes.

## Trig against tsrs

Both passes together, 40 rounds a variant (each pass alone is in
`times-summary.txt` and `times-b-summary.txt`):

ts-pattern:

| | wall median | wall fastest | user | system | user cycles | kernel cycles | instructions | page faults | peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Trig PGO, `773978d1d` | 811.3 ms | 765.4 ms | 756.9 ms | 56.5 ms | 3.610G | 246M | 8.166G | 15,542 | 272 MB |
| Trig PGO, `2c01f07dd` | 843.2 ms | 796.0 ms | 764.0 ms | 78.1 ms | 3.661G | 352M | 8.163G | 40,248 | 262 MB |
| Trig PGO, `36422da59` | 868.1 ms | 798.2 ms | 781.1 ms | 86.5 ms | 3.712G | 375M | 8.202G | 40,343 | 271 MB |
| tsrs shipped | 681.6 ms | 655.8 ms | 641.7 ms | 40.9 ms | 3.042G | 174M | 7.227G | 17,798 | 202 MB |
| tsrs source build | 813.0 ms | 781.6 ms | 775.4 ms | 39.5 ms | 3.672G | 178M | 8.134G | 17,689 | 205 MB |

zod3:

| | wall median | wall fastest | user | system | user cycles | kernel cycles | instructions | page faults | peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Trig PGO, `773978d1d` | 160.0 ms | 154.7 ms | 136.6 ms | 24.6 ms | 0.648G | 94M | 1.440G | 8,062 | 91 MB |
| Trig PGO, `2c01f07dd` | 157.2 ms | 150.4 ms | 134.7 ms | 23.0 ms | 0.647G | 97M | 1.437G | 9,784 | 85 MB |
| Trig PGO, `36422da59` | 158.3 ms | 153.8 ms | 131.6 ms | 25.1 ms | 0.644G | 104M | 1.438G | 9,689 | 84 MB |
| tsrs shipped | 116.6 ms | 113.7 ms | 102.0 ms | 14.1 ms | 0.490G | 56M | 1.206G | 5,414 | 54 MB |
| tsrs source build | 143.4 ms | 140.4 ms | 131.5 ms | 12.0 ms | 0.629G | 51M | 1.403G | 4,647 | 55 MB |

Trig PGO on main (`773978d1d`) against shipped tsrs:

| | ts-pattern | zod3 |
|---|---:|---:|
| wall, median | **1.19×** (1.16×, 1.20× by pass) | **1.37×** (1.39×, 1.37×) |
| wall, fastest | 1.17× (1.17×, 1.20×) | 1.36× (1.35×, 1.36×) |
| user time | 1.18× | 1.34× |
| system time | 1.38× | 1.74× |
| user cycles | 1.19× | 1.32× |
| kernel cycles | 1.41× | 1.67× |
| instructions | 1.13× | 1.19× |
| page faults | **0.87×** | 1.49× |
| peak RSS | 1.35× | 1.68× |

On 2026-10-27 the same comparison gave 1.29× and 1.37× by the median.
The 2026-10-27 build, timed again today beside the others, gives 1.27×
and 1.36×, so the two days agree and the change on ts-pattern is the
Rig commits between. On ts-pattern Trig now takes fewer page faults
than tsrs; on zod3 nothing moved.

## Each step, PGO builds, same day

| ts-pattern | `36422da59` → `2c01f07dd` (#740 to #749) | `2c01f07dd` → `773978d1d` (#754) | together |
|---|---:|---:|---:|
| wall median | 2.9% faster | **3.8% faster** | 6.6% faster |
| wall fastest | 0.3% faster | 3.8% faster | 4.1% faster |
| user cycles | 1.4% fewer | 1.4% fewer | 2.7% fewer |
| kernel cycles | 5.9% fewer | 30% fewer | 34% fewer |
| instructions | 0.5% fewer | same | 0.4% fewer |
| page faults | same | 61% fewer | 61% fewer |
| peak RSS | 3.4% less | **4.0% more** | 0.5% more |

| zod3 | #740 to #749 | #754 | together |
|---|---:|---:|---:|
| wall median | 0.7% faster | **1.8% slower** | 1.1% slower |
| wall fastest | 2.2% faster | 2.9% slower | 0.6% slower |
| user cycles | 0.6% more | 0.1% more | 0.7% more |
| kernel cycles | 7.4% fewer | 2.7% fewer | 9.9% fewer |
| instructions | same | 0.2% more | 0.1% more |
| page faults | 1.0% more | 18% fewer | 17% fewer |
| peak RSS | 0.9% more | **7.5% more** | 8.4% more |

- **#754 on ts-pattern:** 3.8% faster by the median in both passes
  (3.4% and 3.8%), almost all of it the kernel: system time 28% less,
  kernel cycles 30% fewer, page faults 40,248 to 15,542. User cycles
  1.4% fewer (TLB misses, the likely cause, were not counted here). Peak memory 4.0% higher.
- **#754 on zod3:** 1.8% slower by the median (1.9% and 2.2% by pass),
  at the edge of the noise, with user cycles and instructions unchanged,
  kernel cycles 2.7% fewer, and peak memory 7.5% higher (84.5 to 90.8
  MB). zod3's Tables are small, so a Table that crosses 2 MiB likely
  commits a huge page it does not fill. zod3 runs about 160 ms, so its
  user and system times move by the kernel's ticks; its cycles are the
  better guide, and they show no loss.
  Timed again with the order rotated (2026-10-31), #754 is 1.1-1.4%
  slower on zod3, within the noise ([timing-audit](../timing-audit/README.md)).
- **#740 to #749 together:** 2.9% faster on ts-pattern by the median
  (0.3% by the fastest), 1.4% fewer user cycles, 3.4% less peak memory;
  on zod3 within the noise.
- **Peak memory.** #725 left out huge pages for blocks of 2 MiB and up
  because they raised Trig's peak memory ([alloc-large/](../alloc-large/README.md)),
  and tsrs-standing.md held the memory lever to that bar. #754 raises
  peak RSS 4.0% on ts-pattern and 7.5% on zod3, against the run before
  it.
