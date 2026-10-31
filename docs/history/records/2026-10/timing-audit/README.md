# The timing audit: decisions timed in a fixed order (2026-10-31)

Queue row 19. A harness that runs the same variant first in every round
gives that variant a core that idled, at a lower clock (3.8 GHz against
4.4 on pup), and costs it 2-10% of wall time on runs shorter than about
half a second (tsrs-standing-4). Every harness rotates the order since
#795. This audit lists the decisions that rest on a fixed order, ranks
how likely each is to flip ([data/candidates.md](data/candidates.md)),
and times the likeliest again on pup, with the order rotated.

**The answer.** No decision flips. Every change stays as it is. Three
recorded numbers are corrected:

| Change | Recorded | Re-timed, rotated | Decision |
|---|---|---|---|
| #678, a heap past two segments faults in ahead | zod3 4-6% faster | its own pair level on zod3; on today's main, ts-pattern at four checkers 3.4% faster | keep |
| #754, huge pages for large Tables | zod3 1.8% slower | zod3 1.1-1.4% slower, within the noise | keep |
| #674, the heap that does the work faults in ahead | zod3 4-7% faster, RSS 4-6% higher | on today's main, level on every project | keep |

## Method

- **Machine.** pup, one checker on core 6 with its sibling 7 idle, four
  checkers on cores 0, 5, 6 and 7. Each run had its own slot in pup's
  timing lane. Other builds ran only on the E-cores (12-19).
- **Harnesses.** Two, so a result does not rest on one:
  - `measure.py`: the order reversed every other round, 20 rounds;
    fastest and median wall, user and kernel cycles, instructions, page
    faults, dTLB misses, and peak RSS from `perf stat` and `wait4`.
  - `census-time.py`: the six projects, the first variant rotated each
    round, 20 rounds; median wall, user cycles, instructions, peak RSS.
- **The rule.** A change pays if zod3 or ts-pattern is more than 1.5%
  faster by the median, or user plus kernel cycles are at least 1%
  fewer (Trig's bar).
- **Outputs.** Each pair printed the same output on all six projects
  before it was timed.

## #678: keep

Trig `8e2f21f` built by #678's parent (`c2639a40f`) and its merge
(`f3dff92f3`), then Trig `2ba0719` built by main `179c50afa` against the
same main with `prefault_big` out of reach ([audit-678.sh](data/audit-678.sh)).

- **Its own pair** ([data/678-one.md](data/678-one.md),
  [678-four.md](data/678-four.md), [678-six.md](data/678-six.md)). zod3
  is level at one checker and at four, where the record had 4-6%
  faster. ts-pattern at four checkers is 0.4% faster by the median, with
  3.1% fewer user cycles and 5.1% more RSS. The recorded zod3 gain was
  the order.
- **On today's main** ([data/678m-one.md](data/678m-one.md),
  [678m-four.md](data/678m-four.md), [678m-six.md](data/678m-six.md)).
  With the rule, ts-pattern at four checkers is 3.4% faster by the
  median (2.4% by the fastest), with 24% fewer faults; peak RSS is
  2.7% higher on ts-pattern and 3.2% on zod3. At one checker it is
  level. Since
  #678, the Tables of several checkers fill their heaps past two
  segments, so the rule now pays where it did not when it landed.

## #754: keep, its zod3 cost corrected

The cached PGO builds of tsrs-standing-2, `2c01f07dd` and `773978d1d`,
run with `--singleThreaded` as that record ran them
([audit-754.sh](data/audit-754.sh), [data/754-one.md](data/754-one.md),
[754-six.md](data/754-six.md)).

- **zod3** is 1.1% slower by the median and 1.2% by the fastest
  (`measure.py`), 1.4% by the six-project median. User cycles are 0.2%
  more in one harness and 1.9% in the other, and instructions are
  level. Peak RSS is 7.9% higher, as recorded.
- **ts-pattern** is 1.8-2.3% faster, with 61% fewer faults and 24% fewer
  kernel cycles, for 4.1% more peak RSS.

The record's 1.8% had #754 first in every round. The cost is about 1%,
under the bar.

## #674: keep

Trig `2ba0719` built by main `179c50afa` against the same main with
`faultsAhead` reduced to `h.taken >= prefault_big`, so only #678's rule
remains ([audit-674.sh](data/audit-674.sh); the arm is `nolead` in
[audit-one.sh](data/audit-one.sh)). This tests whether `leads` still
pays on today's main. The record's own pair is not re-timed: the merge
commit carries nine other PRs, and the answer would not decide anything
now.

| project | checkers | wall median, without `leads` | user cycles, without `leads` |
|---|---|---|---|
| ts-pattern | 1 | 0.7% faster | 0.7% more |
| zod3 | 1 | 0.5% slower | 0.3% fewer |
| ts-pattern | 4 | 0.2% faster | 0.3% fewer |
| zod3 | 4 | level | 1.1% fewer |

([data/674m-one.md](data/674m-one.md), [674m-four.md](data/674m-four.md).)
Across the six projects ([data/674m-six.md](data/674m-six.md)) every row
is within 1.4% by wall and by user cycles, and faults are within 2%.
Nothing clears the bar either way.

- **Why it no longer pays.** `leads` decides only a heap's first two
  segments: past them, `prefault_big` faults in ahead anyway. Trig's
  heap passes two segments early in every run.
- **Memory.** Peak RSS is about 2 MB higher without `leads` on every
  project, at every checker count. #678's arm, which changes a different
  rule, shows the same difference against the same main build: 2.0 MB
  on ts-pattern and 1.9 MB on zod3 at one checker. So it is most likely
  a difference between builds, not either rule; it was not traced. The
  4-6% the record gave is not seen.
- **Removing it** would save no time and no measured memory. Its cost
  is code: `Heap.taken`'s program-wide total (`taken_all`) and `leads`.
  It stays.

## What was not re-timed

- **The censuses' "within 2%" calls** (candidates 4 and 9), timed with
  the reference first: their cycle counts already agree, and none
  decided a change.
- **#525** was replaced by #674, and #674's rule by today's pair above.
- **#782** was closed by the scheduler-check study (`archive/loop-tick`).
- **#514, #778** and the accepted costs of candidate 10: low, and no
  verdict could change the action taken.
