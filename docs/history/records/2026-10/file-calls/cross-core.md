# Trig's file calls across cores on pup: under the bar (2026-10-31)

[zod3-file-calls.md](zod3-file-calls.md) found two things:
- Running Trig's metadata calls (`stat`, `read_dir`, `realpath`) on the
  calling thread, not the blocking pool, made zod3 2.2-2.9% faster on the
  Mac, unpinned.
- On pup, pinned to one core, the same change saved 0.4-0.9% of cycles.

Users run Trig unpinned, and the Mac's gain looked like the cost of
waking another core. So Rig - Swiss set a bar: if zod3 or mitt gains more
than 1.5% with no project slower, the change (inline only when the worker
is idle, no rescue) gets built.

**Answer:** it does not clear the bar, so the change is not built.
- On two physical P-cores, zod3 is 1.5% faster by the median, mitt 0.7%,
  and ts-pattern and neverthrow are 1.2% and 2.3% slower.
- Unpinned, zod3 is 0.5% faster and mitt 4.9% slower.

The kernel cycles saved are 2-6%, under 1 ms on zod3. They do not
reach wall time beyond the noise.

## Method

- **Builds:** the record's two PGO builds, `main` (sha256
  `8311f3f91fe96faa`) and `meta` (`5eebe3d827fb43eb`), of Trig `2ba0719`.
- **Harness:** [time-rot-2.sh](data/time-rot-2.sh), standing-4's harness
  with the cores as an argument. Each run went in turn, the first rotated
  every round, 20 rounds of each of the six projects. Both arms printed
  the same bytes on every project. pup was quiet apart from these runs,
  at load 0.3-0.7.
- **`6,8`:** Trig on two separate physical P-cores (pup's sibling pairs
  are (0,5) (1,2) (3,4) (6,7) (8,9) (10,11)). Each round waited until 6,
  7, 8 and 9 were idle, 04:42-04:46.
  - Raw: [pup-times-6-8.txt](data/pup-times-6-8.txt).
- **`all`:** Trig on every core, after `perf` itself ran on the E-cores.
  Each round waited until all twelve P-core threads were idle,
  04:46-05:02.
  - `perf`'s `cpu_core` counters miss what runs on an E-core, so cycles
    here count only the P-cores, and wall time is the measure.
  - Raw: [pup-times-all.txt](data/pup-times-all.txt).
- **Medians:** [pup-summary-2.txt](data/pup-summary-2.txt).

## Numbers

`meta` against `main`, wall time by median (and by minimum):

| project | 6,8 | unpinned |
|---|---:|---:|
| zod3 | **1.5% (2.3%) faster** | 0.5% (2.2%) faster |
| ts-pattern | 1.2% slower (0.1% faster) | 0.1% (0.9%) faster |
| tiny-invariant | 1.8% (2.8%) faster | 3.9% faster (1.3% slower) |
| superstruct | 1.3% slower (5.1% faster) | 2.9% slower (5.0% faster) |
| mitt | 0.7% (4.7%) faster | **4.9% (9.1%) slower** |
| neverthrow | 2.3% (5.0%) slower | 3.5% (5.7%) faster |

On 6,8, the counters:

| project | user cycles | kernel cycles |
|---|---:|---:|
| zod3 | 0.6% more | 4.3% fewer |
| ts-pattern | 1.3% more | 2.1% fewer |
| mitt | 0.2% more | 5.5% fewer |
| other three | 0.3% fewer to 0.7% more | 1.7-3.7% fewer |

## What the numbers say

- **On two cores, zod3's gain is at the bar, not over it.** Its 3.8M
  fewer kernel cycles are about 0.8 ms. The 2.3 ms of wall time it saves
  is the wake of the second core, which the pinned run of the record did
  not pay.
- **The small projects scatter by more than the change.** Their runs
  fall into two groups 3-4 ms apart, as in the record, in both arms. The
  unpinned medians favor either arm by 3-5%.
- **x86 does not repeat the Mac's 2-4%.** The Mac's gain is real there,
  but Trig's x86 runs, standing-4's measure against tsrs, do not show it.
- **What it would take:** a change that pays on the Mac but not on x86
  could still be wanted for the Mac. It would need the owner's judgment
  on a scheduler change for a Mac-only gain of 2-4% on two projects.
  inline-idle's lesson still holds: the hand-off is a few milliseconds of
  a run, and only the shortest runs feel it.
