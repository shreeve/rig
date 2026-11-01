# A rotated order still favours some arms; a shuffled one does not (2026-11-01)

[README.md](README.md) found decisions timed with one variant first in every round, and rotated the first variant each round. Rotating isn't enough. The scripts list the arms in a fixed cycle, so the arm after the wrap (the first one-checker arm, after the four-checker arms or the wait for quiet cores) always runs on a core that has just done something else. The other arms never do. `time-ab.sh` shuffles the arms each round and warms the cores first. With it, two byte-identical copies of a binary land on both sides of the original. Scripts and data are in [data/harness/](data/harness/).

## The bias

A broad-corpus PGO comparison on pup ran Trig 806e0a1 (standing-6's PGO build), a byte-identical copy of it as an A/A arm, and two other builds. That was 8 arms in the order `s1 c1 a1 b1 s4 c4 a4 b4`, 20 rounds with the first arm rotated each round, one checker on P-core 6 and four on 0, 6, 8 and 10 ([rotated-time.sh](data/harness/rotated-time.sh), [rotated-times.txt](data/harness/rotated-times.txt)).

The copy (`c`) against the original (`s`), wall median ([rotated-aa.md](data/harness/rotated-aa.md)):

| project | 1 checker | 4 checkers |
|---|---|---|
| mitt | 5.8% faster | 2.4% faster |
| neverthrow | 4.6% faster | 0.4% slower |
| tiny-invariant | 3.7% faster | 1.2% faster |
| zod3 | 2.4% faster | 0.6% faster |
| superstruct | 1.9% faster | 5.0% faster |
| ts-pattern | 0.9% faster | 0.3% slower |

`s1` is the only one-checker arm that ever follows a four-checker run, or the wait for quiet cores. Its mitt runs took 22.6 ms after a four-checker run and 23.2 ms after the wait, against 21.3–21.5 ms for every other one-checker arm in either case. Neverthrow showed the same, as did tonight's two other rotated runs (the exit-fix and lib3 comparisons). So the arm listed first pays about 1–2 ms on a 25 ms project, or several percent, and on large projects much less.

**What it touched:**
- **Results with that arm as the base came out flattered for the others** on small projects at one checker: the exit fix's 9.9% on mitt (an E-core A/A control put it at 4.6%), lib3's small-project gains, and the sched-wake runs' one-checker numbers.
- **Standings put Trig first,** so Trig's one-checker small-project numbers against tsrs read slow by 1–2 ms in [tsrs-standing-5.md](../hash-race/tsrs-standing-5.md) and [tsrs-standing-6.md](../hash-race/tsrs-standing-6.md).
- **This audit's own re-times** ran mostly on zod3 and ts-pattern at four checkers, where the effect is 0–2%.

## The fix: time-ab.sh

[time-ab.sh](data/harness/time-ab.sh) takes a config that names the arms and their commands ([aa.conf](data/harness/aa.conf)). Each round:
1. it waits for quiet cores and for no Trig suite;
2. it runs the config's warm-up commands (one on core 6, one on 0, 6, 8 and 10) and discards them;
3. it runs every arm once, in an order shuffled by the round's number. The shuffle is seeded, so a rerun repeats it.

Each arm follows each other arm, and the warm-up, about equally often. It is installed on pup as `/zfs/trig-pup/trial/time-ab.sh`, beside `time-ab.example.conf`.

## The A/A test

Standing-6's Trig (`s`) and two byte-identical copies (`c`, `d`), at one checker and at four, six projects, 20 rounds, from tmpfs. That's 720 runs, all with the same output ([aa-times.txt](data/harness/aa-times.txt), [aa-summary.md](data/harness/aa-summary.md)).

| project | spread of c and d against s, wall median |
|---|---|
| ts-pattern | 0.0–0.9% |
| zod3 | 0.1–1.0% |
| tiny-invariant | 0.1–1.2% |
| superstruct | 0.1–2.0% |
| neverthrow | 0.2–1.9% |
| mitt | 0.8–3.7% |

The copies now fall on both sides of the original, and cycles stay within 1.7% everywhere. What remains on the 25 ms projects is noise, not position.

## The rules since

1. **Every Trig timing on pup uses time-ab.sh** or the same shuffle and warm-up.
2. **The 25 ms projects (mitt, neverthrow, superstruct) take 60 rounds,** which cuts the spread by about √3.
3. **Every A/B carries an A/A arm in the same run,** and a gain counts only above that run's A/A spread.
4. **Binaries run from tmpfs** (see [tsrs-standing-6.md](../hash-race/tsrs-standing-6.md)), and Trig's peak RSS is reported by huge-page mode.
