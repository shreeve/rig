## Every arm

Medians. Peak RSS in MiB by the Table huge-page gate, as "runs: median", open / shut.

| project | arm | n | wall ms | fastest ms | user cycles M | user instr M | peak RSS MiB, all | open / shut | output |
|---|---|---:|---:|---:|---:|---:|---:|---|---|
| ts-pattern | trig1 | 20 | 737.9 | 715.3 | 3224.3 | 8203.0 | 228.1 | 8: 228.1 / 12: 228.1 | same, exit 2 |
| ts-pattern | aa1 | 20 | 738.6 | 713.1 | 3224.2 | 8203.0 | 228.1 | 2: 233.5 / 18: 228.1 | same, exit 2 |
| ts-pattern | nolib1 | 20 | 734.8 | 710.4 | 3210.1 | 8201.7 | 228.0 | 8: 237.8 / 12: 228.0 | same, exit 2 |
| ts-pattern | tsrs1 | 20 | 632.4 | 625.9 | 2850.0 | 6903.5 | 165.5 | 4: 165.5 / 16: 165.5 | same, exit 2 |
| ts-pattern | tsrsg1 | 20 | 643.3 | 638.6 | 2878.0 | 7223.7 | 205.9 | 10: 206.0 / 10: 205.9 | same, exit 2 |
| ts-pattern | trig4 | 20 | 300.1 | 291.8 | 3435.8 | 8655.2 | 257.6 | 9: 280.7 / 11: 257.4 | same, exit 2 |
| ts-pattern | aa4 | 20 | 302.7 | 294.4 | 3446.6 | 8655.2 | 257.4 | 4: 257.6 / 16: 257.4 | same, exit 2 |
| ts-pattern | nolib4 | 20 | 324.2 | 313.9 | 3462.5 | 8673.3 | 258.9 | 9: 260.6 / 11: 258.7 | same, exit 2 |
| ts-pattern | tsrs4 | 20 | 207.6 | 202.9 | 3024.2 | 7305.5 | 184.9 | 4: 184.6 / 16: 184.9 | same, exit 2 |
| ts-pattern | tsrsg4 | 20 | 237.7 | 231.2 | 3060.1 | 7670.4 | 231.6 | 8: 231.9 / 12: 231.2 | same, exit 2 |
| zod3 | trig1 | 20 | 138.4 | 135.4 | 575.5 | 1412.7 | 73.8 | 3: 73.8 / 17: 73.8 | same, exit 2 |
| zod3 | aa1 | 20 | 138.5 | 136.2 | 576.0 | 1412.7 | 73.8 | 2: 73.8 / 18: 73.8 | same, exit 2 |
| zod3 | nolib1 | 20 | 138.7 | 136.1 | 577.9 | 1412.1 | 73.6 | 4: 73.6 / 16: 73.6 | same, exit 2 |
| zod3 | tsrs1 | 20 | 99.3 | 98.4 | 422.8 | 970.4 | 48.0 | 4: 48.0 / 16: 48.0 | same, exit 2 |
| zod3 | tsrsg1 | 20 | 111.9 | 110.6 | 476.5 | 1200.8 | 57.1 | 3: 57.0 / 17: 57.1 | same, exit 2 |
| zod3 | trig4 | 20 | 82.1 | 78.6 | 819.3 | 1962.2 | 107.8 | 1: 107.4 / 19: 107.9 | same, exit 2 |
| zod3 | aa4 | 20 | 82.4 | 78.2 | 822.3 | 1962.3 | 107.5 | 4: 107.4 / 16: 107.6 | same, exit 2 |
| zod3 | nolib4 | 20 | 80.6 | 78.1 | 821.9 | 1950.1 | 106.9 | 4: 105.9 / 16: 106.9 | same, exit 2 |
| zod3 | tsrs4 | 20 | 50.4 | 48.3 | 611.6 | 1360.3 | 74.9 | 2: 75.1 / 18: 74.8 | same, exit 2 |
| zod3 | tsrsg4 | 20 | 64.2 | 60.9 | 695.6 | 1690.1 | 88.8 | 5: 88.7 / 15: 88.9 | same, exit 2 |
| mitt | trig1 | 60 | 17.4 | 16.4 | 53.6 | 151.1 | 32.4 | 0: - / 60: 32.4 | same, exit 2 |
| mitt | aa1 | 60 | 17.5 | 16.5 | 53.5 | 151.1 | 32.4 | 0: - / 60: 32.4 | same, exit 2 |
| mitt | nolib1 | 60 | 17.4 | 16.5 | 53.8 | 151.1 | 32.2 | 0: - / 60: 32.2 | same, exit 2 |
| mitt | tsrs1 | 60 | 14.7 | 14.0 | 46.3 | 122.5 | 20.2 | 0: - / 60: 20.2 | same, exit 2 |
| mitt | tsrsg1 | 60 | 14.5 | 14.0 | 46.3 | 122.8 | 20.7 | 0: - / 60: 20.7 | same, exit 2 |
| mitt | trig4 | 60 | 20.1 | 18.7 | 67.4 | 173.3 | 38.8 | 0: - / 60: 38.8 | same, exit 2 |
| mitt | aa4 | 60 | 20.4 | 18.4 | 68.0 | 173.4 | 38.5 | 0: - / 60: 38.5 | same, exit 2 |
| mitt | nolib4 | 60 | 20.4 | 18.4 | 68.0 | 173.2 | 38.8 | 0: - / 60: 38.8 | same, exit 2 |
| mitt | tsrs4 | 60 | 18.8 | 17.0 | 77.7 | 185.9 | 31.6 | 0: - / 60: 31.6 | same, exit 2 |
| mitt | tsrsg4 | 60 | 18.7 | 17.4 | 77.0 | 186.0 | 31.2 | 0: - / 60: 31.2 | same, exit 2 |
| neverthrow | trig1 | 60 | 19.7 | 18.7 | 63.7 | 163.6 | 32.9 | 0: - / 60: 32.9 | same, exit 2 |
| neverthrow | aa1 | 60 | 19.6 | 19.0 | 63.7 | 163.6 | 32.9 | 0: - / 60: 32.9 | same, exit 2 |
| neverthrow | nolib1 | 60 | 19.7 | 19.0 | 63.8 | 163.6 | 32.5 | 0: - / 60: 32.5 | same, exit 2 |
| neverthrow | tsrs1 | 60 | 15.8 | 15.3 | 52.6 | 127.5 | 20.5 | 0: - / 60: 20.5 | same, exit 2 |
| neverthrow | tsrsg1 | 60 | 15.7 | 15.1 | 52.5 | 129.7 | 20.8 | 0: - / 60: 20.8 | same, exit 2 |
| neverthrow | trig4 | 60 | 21.6 | 19.8 | 85.5 | 204.2 | 38.7 | 0: - / 60: 38.7 | same, exit 2 |
| neverthrow | aa4 | 60 | 21.5 | 20.1 | 85.8 | 204.2 | 38.4 | 0: - / 60: 38.4 | same, exit 2 |
| neverthrow | nolib4 | 60 | 21.6 | 19.8 | 86.3 | 204.1 | 38.3 | 0: - / 60: 38.3 | same, exit 2 |
| neverthrow | tsrs4 | 60 | 19.3 | 17.8 | 90.5 | 206.3 | 32.1 | 0: - / 60: 32.1 | same, exit 2 |
| neverthrow | tsrsg4 | 60 | 19.5 | 17.7 | 90.1 | 208.6 | 32.1 | 0: - / 60: 32.1 | same, exit 2 |
| superstruct | trig1 | 60 | 26.3 | 25.1 | 100.5 | 230.5 | 24.2 | 0: - / 60: 24.2 | same, exit 2 |
| superstruct | aa1 | 60 | 26.2 | 25.3 | 100.6 | 230.5 | 24.2 | 0: - / 60: 24.2 | same, exit 2 |
| superstruct | nolib1 | 60 | 25.6 | 24.6 | 98.4 | 225.4 | 24.0 | 0: - / 60: 24.0 | same, exit 2 |
| superstruct | tsrs1 | 60 | 19.1 | 18.5 | 68.9 | 150.9 | 21.9 | 0: - / 60: 21.9 | same, exit 2 |
| superstruct | tsrsg1 | 60 | 19.0 | 18.4 | 68.5 | 154.0 | 22.1 | 0: - / 60: 22.1 | same, exit 2 |
| superstruct | trig4 | 60 | 17.5 | 15.9 | 133.2 | 274.4 | 30.5 | 0: - / 60: 30.5 | same, exit 2 |
| superstruct | aa4 | 60 | 17.8 | 15.6 | 136.7 | 274.4 | 30.8 | 0: - / 60: 30.8 | same, exit 2 |
| superstruct | nolib4 | 60 | 17.9 | 15.8 | 132.4 | 268.5 | 30.2 | 0: - / 60: 30.2 | same, exit 2 |
| superstruct | tsrs4 | 60 | 15.4 | 13.1 | 94.5 | 175.1 | 30.3 | 0: - / 60: 30.3 | same, exit 2 |
| superstruct | tsrsg4 | 60 | 15.1 | 12.9 | 96.2 | 184.6 | 30.1 | 0: - / 60: 30.1 | same, exit 2 |
| tiny-invariant | trig1 | 20 | 60.0 | 59.2 | 239.9 | 788.1 | 48.9 | 2: 48.9 / 18: 48.9 | same, exit 2 |
| tiny-invariant | aa1 | 20 | 59.5 | 58.5 | 236.5 | 788.1 | 48.9 | 6: 48.9 / 14: 48.9 | same, exit 2 |
| tiny-invariant | nolib1 | 20 | 59.9 | 58.2 | 236.8 | 788.3 | 48.7 | 7: 48.7 / 13: 48.7 | same, exit 2 |
| tiny-invariant | tsrs1 | 20 | 53.2 | 51.8 | 211.7 | 637.3 | 38.6 | 5: 38.6 / 15: 38.6 | same, exit 2 |
| tiny-invariant | tsrsg1 | 20 | 49.3 | 48.1 | 193.6 | 597.1 | 38.1 | 3: 38.2 / 17: 38.1 | same, exit 2 |
| tiny-invariant | trig4 | 20 | 62.9 | 60.5 | 258.3 | 817.2 | 55.0 | 3: 54.8 / 17: 55.0 | same, exit 2 |
| tiny-invariant | aa4 | 20 | 63.4 | 58.2 | 258.3 | 817.3 | 54.9 | 4: 55.1 / 16: 54.9 | same, exit 2 |
| tiny-invariant | nolib4 | 20 | 62.9 | 60.5 | 257.4 | 817.6 | 55.4 | 3: 55.0 / 17: 55.6 | same, exit 2 |
| tiny-invariant | tsrs4 | 20 | 40.9 | 39.7 | 327.7 | 953.9 | 56.9 | 2: 56.8 / 18: 57.0 | same, exit 2 |
| tiny-invariant | tsrsg4 | 20 | 53.2 | 51.0 | 205.8 | 609.3 | 42.5 | 7: 43.1 / 13: 42.1 | same, exit 2 |

## Trig against tsrs, 1 checker

Trig main against tsrs as shipped and in Go's mode. Trig's peak RSS is the median of the gate state most of its runs had; tsrs's over all its runs.

| project | Trig ms | tsrs ms | tsrsg ms | wall vs tsrs | wall vs tsrsg | cycles vs tsrs | cycles vs tsrsg | Trig RSS (gate, runs) | tsrs RSS | tsrsg RSS | RSS vs tsrs | RSS vs tsrsg |
|---|---:|---:|---:|---|---|---|---|---|---:|---:|---|---|
| ts-pattern | 737.9 | 632.4 | 643.3 | 16.7% slower | 14.7% slower | 13.1% more | 12.0% more | 228.1 (shut, 12/20) | 165.5 | 205.9 | 37.8% more | 10.8% more |
| zod3 | 138.4 | 99.3 | 111.9 | 39.3% slower | 23.7% slower | 36.1% more | 20.8% more | 73.8 (shut, 17/20) | 48.0 | 57.1 | 53.7% more | 29.4% more |
| mitt | 17.4 | 14.7 | 14.5 | 18.4% slower | 19.5% slower | 15.7% more | 15.7% more | 32.4 (shut, 60/60) | 20.2 | 20.7 | 60.7% more | 56.4% more |
| neverthrow | 19.7 | 15.8 | 15.7 | 24.6% slower | 25.6% slower | 21.1% more | 21.3% more | 32.9 (shut, 60/60) | 20.5 | 20.8 | 60.2% more | 57.8% more |
| superstruct | 26.3 | 19.1 | 19.0 | 37.5% slower | 38.1% slower | 45.9% more | 46.7% more | 24.2 (shut, 60/60) | 21.9 | 22.1 | 10.8% more | 9.5% more |
| tiny-invariant | 60.0 | 53.2 | 49.3 | 12.8% slower | 21.9% slower | 13.4% more | 23.9% more | 48.9 (shut, 18/20) | 38.6 | 38.1 | 26.5% more | 28.2% more |

## Trig against tsrs, 4 checkers

Trig main against tsrs as shipped and in Go's mode. Trig's peak RSS is the median of the gate state most of its runs had; tsrs's over all its runs.

| project | Trig ms | tsrs ms | tsrsg ms | wall vs tsrs | wall vs tsrsg | cycles vs tsrs | cycles vs tsrsg | Trig RSS (gate, runs) | tsrs RSS | tsrsg RSS | RSS vs tsrs | RSS vs tsrsg |
|---|---:|---:|---:|---|---|---|---|---|---:|---:|---|---|
| ts-pattern | 300.1 | 207.6 | 237.7 | 44.5% slower | 26.2% slower | 13.6% more | 12.3% more | 257.4 (shut, 11/20) | 184.9 | 231.6 | 39.2% more | 11.2% more |
| zod3 | 82.1 | 50.4 | 64.2 | 62.9% slower | 27.8% slower | 34.0% more | 17.8% more | 107.9 (shut, 19/20) | 74.9 | 88.8 | 44.1% more | 21.5% more |
| mitt | 20.1 | 18.8 | 18.7 | 6.8% slower | 7.9% slower | 13.2% fewer | 12.5% fewer | 38.8 (shut, 60/60) | 31.6 | 31.2 | 22.7% more | 24.6% more |
| neverthrow | 21.6 | 19.3 | 19.5 | 11.7% slower | 10.6% slower | 5.5% fewer | 5.1% fewer | 38.7 (shut, 60/60) | 32.1 | 32.1 | 20.5% more | 20.4% more |
| superstruct | 17.5 | 15.4 | 15.1 | 13.5% slower | 16.0% slower | 40.9% more | 38.5% more | 30.5 (shut, 60/60) | 30.3 | 30.1 | 0.8% more | 1.3% more |
| tiny-invariant | 62.9 | 40.9 | 53.2 | 53.8% slower | 18.2% slower | 21.2% fewer | 25.5% more | 55.0 (shut, 17/20) | 56.9 | 42.5 | 3.3% less | 29.6% more |

## Like for like: Trig without the three lib files

| project | checkers | nolib ms | vs Trig main | vs tsrsg | vs tsrs | cycles vs Trig main | cycles vs tsrsg | RSS vs Trig main (same gate) |
|---|---|---:|---|---|---|---|---|---|
| ts-pattern | 1 | 734.8 | 0.4% faster | 14.2% slower | 16.2% slower | 0.4% fewer | 11.5% more | 0.1% less (shut) |
| ts-pattern | 4 | 324.2 | 8.0% slower | 36.4% slower | 56.1% slower | 0.8% more | 13.1% more | 0.5% more (shut) |
| zod3 | 1 | 138.7 | 0.2% slower | 24.0% slower | 39.6% slower | 0.4% more | 21.3% more | 0.3% less (shut) |
| zod3 | 4 | 80.6 | 1.8% faster | 25.5% slower | 59.9% slower | 0.3% more | 18.2% more | 0.9% less (shut) |
| mitt | 1 | 17.4 | 0.4% slower | 20.0% slower | 18.8% slower | 0.5% more | 16.3% more | 0.5% less (shut) |
| mitt | 4 | 20.4 | 1.2% slower | 9.1% slower | 8.1% slower | 0.9% more | 11.7% fewer | the same (shut) |
| neverthrow | 1 | 19.7 | the same | 25.6% slower | 24.6% slower | 0.3% more | 21.6% more | 1.0% less (shut) |
| neverthrow | 4 | 21.6 | 0.2% faster | 10.4% slower | 11.5% slower | 0.9% more | 4.3% fewer | 1.1% less (shut) |
| superstruct | 1 | 25.6 | 2.7% faster | 34.4% slower | 33.8% slower | 2.1% fewer | 43.6% more | 0.9% less (shut) |
| superstruct | 4 | 17.9 | 2.0% slower | 18.3% slower | 15.8% slower | 0.6% fewer | 37.7% more | 1.1% less (shut) |
| tiny-invariant | 1 | 59.9 | 0.2% faster | 21.6% slower | 12.5% slower | 1.3% fewer | 22.3% more | 0.3% less (shut) |
| tiny-invariant | 4 | 62.9 | the same | 18.2% slower | 53.8% slower | 0.3% fewer | 25.1% more | 1.0% more (shut) |

## A/A: the copy against Trig main

| project | checkers | wall | fastest | cycles | instructions |
|---|---|---|---|---|---|
| ts-pattern | 1 | 0.1% slower | 0.3% faster | the same | the same |
| ts-pattern | 4 | 0.9% slower | 0.9% slower | 0.3% more | the same |
| zod3 | 1 | 0.1% slower | 0.6% slower | 0.1% more | the same |
| zod3 | 4 | 0.4% slower | 0.6% faster | 0.4% more | the same |
| mitt | 1 | 0.6% slower | 0.3% slower | 0.2% fewer | the same |
| mitt | 4 | 1.2% slower | 2.0% faster | 0.8% more | the same |
| neverthrow | 1 | 0.6% faster | 1.5% slower | 0.1% more | the same |
| neverthrow | 4 | 0.3% faster | 1.4% slower | 0.3% more | the same |
| superstruct | 1 | 0.2% faster | 0.9% slower | 0.1% more | the same |
| superstruct | 4 | 1.5% slower | 1.5% faster | 2.6% more | the same |
| tiny-invariant | 1 | 0.9% faster | 1.2% faster | 1.4% fewer | the same |
| tiny-invariant | 4 | 0.7% slower | 3.8% faster | the same | the same |
