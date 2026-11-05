# The no-early-exit rule on Trig (2026-11-05)

Branch loop-split at baab79318, where only a range that always runs to its end is split (profile-2026-11-05.md), against main 506a291a9. Trig 4aaedab, release builds on pup, `time-ab.sh`, 20 rounds in shuffled order, `taskset -c 3 ... --checkers 1`, core 4 idle, 03:55-04:21.

- **Arms:** base (main), split2 (the branch), and split2b (the same binary, the A/A arm).
- **Caveat:** two PGO release builds of Trig's ran on cores 1 and 11 throughout.

| project | arm | gate | runs | wall ms | cycles/u M | instr/u M | rss MiB | free 2M | thp |
|---|---|---|---|---|---|---|---|---|---|
| mitt | base | shut | 20 | 10.69 | 25.26 | 51.71 | 37.39 | 1 | 0 |
| mitt | split2 | shut | 20 | 10.65 | 25.23 | 52.43 | 37.41 | 1 | 0 |
| mitt | split2b | shut | 20 | 10.80 | 25.50 | 52.43 | 37.41 | 1 | 0 |
| neverthrow | base | shut | 20 | 13.90 | 39.76 | 73.94 | 36.97 | 1 | 0 |
| neverthrow | split2 | shut | 20 | 13.80 | 40.37 | 74.82 | 37.18 | 1 | 0 |
| neverthrow | split2b | shut | 20 | 14.11 | 41.15 | 74.82 | 37.18 | 1 | 0 |
| zod3 | base | shut | 20 | 131.92 | 571.16 | 1313.77 | 70.94 | 1 | 0 |
| zod3 | split2 | shut | 20 | 133.55 | 579.45 | 1323.09 | 71.14 | 1 | 0 |
| zod3 | split2b | shut | 20 | 132.41 | 575.16 | 1323.09 | 71.14 | 1 | 0 |
| ts-pattern | base | shut | 20 | 768.82 | 3475.85 | 8419.35 | 204.18 | 1 | 0 |
| ts-pattern | split2 | shut | 20 | 773.64 | 3491.97 | 8485.52 | 204.19 | 1 | 0 |
| ts-pattern | split2b | shut | 20 | 774.06 | 3501.28 | 8485.52 | 204.19 | 1 | 0 |
| superstruct | base | shut | 20 | 23.33 | 91.73 | 205.89 | 24.60 | 1 | 0 |
| superstruct | split2 | shut | 20 | 23.31 | 91.98 | 206.97 | 24.80 | 1 | 0 |
| superstruct | split2b | shut | 20 | 23.19 | 91.96 | 206.97 | 24.80 | 1 | 0 |
| tiny-invariant | base | shut | 20 | 55.66 | 225.94 | 709.37 | 53.66 | 1 | 0 |
| tiny-invariant | split2 | shut | 20 | 56.48 | 231.04 | 706.30 | 53.69 | 1 | 0 |
| tiny-invariant | split2b | shut | 20 | 56.68 | 233.10 | 706.30 | 53.69 | 1 | 0 |

## What it shows

- **The rule removes most of the first design's cost:** the instruction increase falls from 1.7-3.0% to 0.5-1.4% on five projects, and tiny-invariant takes 0.4% fewer. ts-pattern is 8,419M to 8,486M (0.8% more), against 3.0% more before.
- **It does not gain on Trig:** wall times are within plus or minus 1.5% of base, inside the spread between split2 and its A/A arm (up to 2.2% on neverthrow). Trig's hot loops are short and leave early, so they keep their checks, and Trig has few long counted loops that would run in blocks.
- **It does not clear Trig's bar** (more than 1.5% faster, or at least 1% fewer instructions on one checker).

The gain stays where the record shows it: long counted loops on arm64. bench/tasks' CPU benchmarks take 14-21% fewer cycles on the Mac and match Rust's loop; on x86 a check on every turn is cheaper, and the split gains less.
