## Every arm

Medians. Peak RSS in MiB by the Table huge-page gate, as "runs: median", open / shut.

| project | arm | n | wall ms | fastest ms | user cycles M | user instr M | peak RSS MiB, all | open / shut | output |
|---|---|---:|---:|---:|---:|---:|---:|---|---|
| ts-pattern | trig1 | 15 | 704.1 | 681.2 | 3056.4 | 7686.1 | 222.1 | 7: 232.9 / 8: 222.1 | same, exit 2 |
| ts-pattern | aa1 | 15 | 708.7 | 683.5 | 3073.2 | 7686.1 | 222.1 | 6: 226.9 / 9: 222.1 | same, exit 2 |
| ts-pattern | ids1 | 15 | 719.0 | 694.9 | 3132.4 | 8029.5 | 222.5 | 6: 232.7 / 9: 222.5 | same, exit 2 |
| ts-pattern | tsrs1 | 15 | 636.6 | 627.4 | 2859.3 | 6903.5 | 165.5 | 7: 165.5 / 8: 165.5 | same, exit 2 |
| ts-pattern | tsrsg1 | 15 | 643.5 | 640.4 | 2878.4 | 7223.7 | 205.9 | 11: 205.9 / 4: 205.9 | same, exit 2 |
| ts-pattern | trig4 | 15 | 277.8 | 271.8 | 3272.6 | 8108.1 | 273.3 | 10: 275.3 / 5: 252.4 | same, exit 2 |
| ts-pattern | aa4 | 15 | 284.6 | 278.9 | 3306.3 | 8108.1 | 251.9 | 3: 251.2 / 12: 252.0 | same, exit 2 |
| ts-pattern | ids4 | 15 | 288.9 | 279.8 | 3357.9 | 8472.4 | 254.6 | 9: 275.4 / 6: 253.3 | same, exit 2 |
| ts-pattern | tsrs4 | 15 | 209.2 | 204.2 | 3043.2 | 7305.9 | 184.8 | 7: 184.8 / 8: 184.4 | same, exit 2 |
| ts-pattern | tsrsg4 | 15 | 238.8 | 234.9 | 3065.8 | 7671.1 | 231.9 | 8: 232.1 / 7: 231.9 | same, exit 2 |
| zod3 | trig1 | 15 | 132.9 | 129.3 | 542.1 | 1305.2 | 72.5 | 12: 72.5 / 3: 70.3 | same, exit 2 |
| zod3 | aa1 | 15 | 131.3 | 129.0 | 542.5 | 1305.2 | 72.5 | 13: 72.5 / 2: 70.3 | same, exit 2 |
| zod3 | ids1 | 15 | 134.1 | 131.5 | 555.3 | 1371.3 | 72.9 | 13: 72.9 / 2: 70.7 | same, exit 2 |
| zod3 | tsrs1 | 15 | 100.9 | 98.7 | 421.4 | 970.4 | 48.1 | 12: 48.1 / 3: 48.1 | same, exit 2 |
| zod3 | tsrsg1 | 15 | 114.0 | 111.9 | 480.1 | 1200.8 | 57.1 | 11: 57.1 / 4: 56.9 | same, exit 2 |
| zod3 | trig4 | 15 | 73.0 | 70.2 | 779.6 | 1813.7 | 104.7 | 13: 104.7 / 2: 104.5 | same, exit 2 |
| zod3 | aa4 | 15 | 73.9 | 71.3 | 780.9 | 1813.5 | 104.5 | 11: 104.6 / 4: 103.6 | same, exit 2 |
| zod3 | ids4 | 15 | 74.3 | 71.1 | 798.2 | 1911.0 | 105.2 | 11: 105.2 / 4: 105.0 | same, exit 2 |
| zod3 | tsrs4 | 15 | 51.1 | 48.7 | 619.7 | 1359.4 | 73.9 | 12: 74.9 / 3: 73.1 | same, exit 2 |
| zod3 | tsrsg4 | 15 | 64.6 | 63.1 | 699.7 | 1690.2 | 88.9 | 14: 88.7 / 1: 89.0 | same, exit 2 |
| mitt | trig1 | 60 | 16.3 | 15.1 | 49.8 | 142.9 | 29.8 | 60: 29.8 / 0: - | same, exit 2 |
| mitt | aa1 | 60 | 16.2 | 15.4 | 49.8 | 142.9 | 29.8 | 60: 29.8 / 0: - | same, exit 2 |
| mitt | ids1 | 60 | 16.4 | 15.4 | 49.8 | 143.8 | 30.2 | 60: 30.2 / 0: - | same, exit 2 |
| mitt | tsrs1 | 60 | 15.1 | 14.3 | 46.3 | 122.5 | 20.2 | 60: 20.2 / 0: - | same, exit 2 |
| mitt | tsrsg1 | 60 | 15.0 | 14.3 | 46.3 | 122.8 | 20.7 | 60: 20.7 / 0: - | same, exit 2 |
| mitt | trig4 | 60 | 18.6 | 16.7 | 67.3 | 166.0 | 36.7 | 60: 36.7 / 0: - | same, exit 2 |
| mitt | aa4 | 60 | 18.7 | 16.8 | 67.5 | 166.1 | 37.0 | 60: 37.0 / 0: - | same, exit 2 |
| mitt | ids4 | 60 | 18.7 | 16.8 | 68.5 | 167.5 | 36.9 | 60: 36.9 / 0: - | same, exit 2 |
| mitt | tsrs4 | 60 | 18.8 | 16.7 | 77.5 | 185.8 | 31.7 | 60: 31.7 / 0: - | same, exit 2 |
| mitt | tsrsg4 | 60 | 18.9 | 16.6 | 77.2 | 186.1 | 31.1 | 60: 31.1 / 0: - | same, exit 2 |
| neverthrow | trig1 | 60 | 18.7 | 17.6 | 59.9 | 154.4 | 30.0 | 60: 30.0 / 0: - | same, exit 2 |
| neverthrow | aa1 | 60 | 18.6 | 17.7 | 60.0 | 154.4 | 30.0 | 60: 30.0 / 0: - | same, exit 2 |
| neverthrow | ids1 | 60 | 18.9 | 17.7 | 60.3 | 156.4 | 30.4 | 60: 30.4 / 0: - | same, exit 2 |
| neverthrow | tsrs1 | 60 | 16.2 | 15.4 | 52.6 | 127.5 | 20.5 | 60: 20.5 / 0: - | same, exit 2 |
| neverthrow | tsrsg1 | 60 | 16.3 | 15.4 | 52.5 | 129.7 | 20.9 | 60: 20.9 / 0: - | same, exit 2 |
| neverthrow | trig4 | 60 | 19.9 | 18.2 | 81.2 | 192.8 | 35.6 | 60: 35.6 / 0: - | same, exit 2 |
| neverthrow | aa4 | 60 | 20.0 | 18.4 | 82.0 | 192.8 | 35.8 | 60: 35.8 / 0: - | same, exit 2 |
| neverthrow | ids4 | 60 | 20.1 | 18.4 | 82.5 | 196.4 | 35.7 | 60: 35.7 / 0: - | same, exit 2 |
| neverthrow | tsrs4 | 60 | 19.6 | 17.9 | 91.4 | 206.3 | 32.1 | 60: 32.1 / 0: - | same, exit 2 |
| neverthrow | tsrsg4 | 60 | 19.4 | 17.4 | 90.4 | 208.6 | 32.2 | 60: 32.2 / 0: - | same, exit 2 |
| superstruct | trig1 | 60 | 25.6 | 24.5 | 95.7 | 214.3 | 24.0 | 60: 24.0 / 0: - | same, exit 2 |
| superstruct | aa1 | 60 | 25.6 | 24.3 | 95.6 | 214.3 | 24.0 | 60: 24.0 / 0: - | same, exit 2 |
| superstruct | ids1 | 60 | 26.2 | 24.8 | 97.6 | 221.9 | 24.2 | 60: 24.2 / 0: - | same, exit 2 |
| superstruct | tsrs1 | 60 | 19.6 | 18.9 | 68.8 | 150.9 | 21.9 | 60: 21.9 / 0: - | same, exit 2 |
| superstruct | tsrsg1 | 60 | 19.6 | 18.7 | 68.4 | 154.0 | 22.1 | 60: 22.1 / 0: - | same, exit 2 |
| superstruct | trig4 | 60 | 16.9 | 15.8 | 132.5 | 256.3 | 30.7 | 60: 30.7 / 0: - | same, exit 2 |
| superstruct | aa4 | 60 | 17.5 | 15.5 | 131.5 | 256.3 | 30.7 | 60: 30.7 / 0: - | same, exit 2 |
| superstruct | ids4 | 60 | 17.8 | 15.8 | 135.3 | 266.7 | 30.9 | 60: 30.9 / 0: - | same, exit 2 |
| superstruct | tsrs4 | 60 | 15.6 | 12.8 | 94.1 | 175.1 | 30.3 | 60: 30.3 / 0: - | same, exit 2 |
| superstruct | tsrsg4 | 60 | 15.3 | 12.8 | 96.0 | 184.6 | 30.2 | 60: 30.2 / 0: - | same, exit 2 |
| tiny-invariant | trig1 | 15 | 56.5 | 55.1 | 221.4 | 717.4 | 45.9 | 15: 45.9 / 0: - | same, exit 2 |
| tiny-invariant | aa1 | 15 | 56.1 | 55.0 | 220.7 | 717.4 | 45.9 | 15: 45.9 / 0: - | same, exit 2 |
| tiny-invariant | ids1 | 15 | 57.9 | 56.1 | 226.9 | 753.6 | 46.1 | 15: 46.1 / 0: - | same, exit 2 |
| tiny-invariant | tsrs1 | 15 | 53.7 | 52.5 | 210.9 | 637.3 | 38.7 | 15: 38.7 / 0: - | same, exit 2 |
| tiny-invariant | tsrsg1 | 15 | 49.6 | 48.7 | 193.5 | 597.1 | 38.2 | 15: 38.2 / 0: - | same, exit 2 |
| tiny-invariant | trig4 | 15 | 59.5 | 57.0 | 240.6 | 745.4 | 52.8 | 15: 52.8 / 0: - | same, exit 2 |
| tiny-invariant | aa4 | 15 | 60.0 | 57.6 | 240.9 | 745.4 | 52.4 | 15: 52.4 / 0: - | same, exit 2 |
| tiny-invariant | ids4 | 15 | 61.3 | 58.1 | 248.6 | 782.5 | 53.5 | 15: 53.5 / 0: - | same, exit 2 |
| tiny-invariant | tsrs4 | 15 | 41.8 | 40.4 | 329.5 | 953.7 | 56.7 | 15: 56.7 / 0: - | same, exit 2 |
| tiny-invariant | tsrsg4 | 15 | 54.0 | 50.3 | 205.2 | 609.4 | 42.0 | 15: 42.0 / 0: - | same, exit 2 |

## Trig against tsrs, 1 checker

Trig main against tsrs as shipped and in Go's mode. Trig's peak RSS is the median of the gate state most of its runs had; tsrs's over all its runs.

| project | Trig ms | tsrs ms | tsrsg ms | wall vs tsrs | wall vs tsrsg | cycles vs tsrs | cycles vs tsrsg | Trig RSS (gate, runs) | tsrs RSS | tsrsg RSS | RSS vs tsrs | RSS vs tsrsg |
|---|---:|---:|---:|---|---|---|---|---|---:|---:|---|---|
| ts-pattern | 704.1 | 636.6 | 643.5 | 10.6% slower | 9.4% slower | 6.9% more | 6.2% more | 222.1 (shut, 8/15) | 165.5 | 205.9 | 34.2% more | 7.9% more |
| zod3 | 132.9 | 100.9 | 114.0 | 31.8% slower | 16.6% slower | 28.6% more | 12.9% more | 72.5 (open, 12/15) | 48.1 | 57.1 | 50.9% more | 27.1% more |
| mitt | 16.3 | 15.1 | 15.0 | 7.6% slower | 8.8% slower | 7.6% more | 7.6% more | 29.8 (open, 60/60) | 20.2 | 20.7 | 47.6% more | 43.7% more |
| neverthrow | 18.7 | 16.2 | 16.3 | 15.4% slower | 15.2% slower | 14.0% more | 14.2% more | 30.0 (open, 60/60) | 20.5 | 20.9 | 46.3% more | 43.7% more |
| superstruct | 25.6 | 19.6 | 19.6 | 30.6% slower | 30.7% slower | 39.1% more | 39.9% more | 24.0 (open, 60/60) | 21.9 | 22.1 | 9.7% more | 8.3% more |
| tiny-invariant | 56.5 | 53.7 | 49.6 | 5.1% slower | 13.8% slower | 5.0% more | 14.4% more | 45.9 (open, 15/15) | 38.7 | 38.2 | 18.7% more | 20.3% more |

## Trig against tsrs, 4 checkers

Trig main against tsrs as shipped and in Go's mode. Trig's peak RSS is the median of the gate state most of its runs had; tsrs's over all its runs.

| project | Trig ms | tsrs ms | tsrsg ms | wall vs tsrs | wall vs tsrsg | cycles vs tsrs | cycles vs tsrsg | Trig RSS (gate, runs) | tsrs RSS | tsrsg RSS | RSS vs tsrs | RSS vs tsrsg |
|---|---:|---:|---:|---|---|---|---|---|---:|---:|---|---|
| ts-pattern | 277.8 | 209.2 | 238.8 | 32.8% slower | 16.3% slower | 7.5% more | 6.7% more | 275.3 (open, 10/15) | 184.8 | 231.9 | 49.0% more | 18.7% more |
| zod3 | 73.0 | 51.1 | 64.6 | 42.9% slower | 13.0% slower | 25.8% more | 11.4% more | 104.7 (open, 13/15) | 73.9 | 88.9 | 41.7% more | 17.8% more |
| mitt | 18.6 | 18.8 | 18.9 | 1.3% faster | 2.0% faster | 13.1% fewer | 12.8% fewer | 36.7 (open, 60/60) | 31.7 | 31.1 | 15.9% more | 18.0% more |
| neverthrow | 19.9 | 19.6 | 19.4 | 1.8% slower | 2.7% slower | 11.2% fewer | 10.2% fewer | 35.6 (open, 60/60) | 32.1 | 32.2 | 10.7% more | 10.6% more |
| superstruct | 16.9 | 15.6 | 15.3 | 8.4% slower | 10.4% slower | 40.7% more | 38.0% more | 30.7 (open, 60/60) | 30.3 | 30.2 | 1.3% more | 1.7% more |
| tiny-invariant | 59.5 | 41.8 | 54.0 | 42.1% slower | 10.2% slower | 27.0% fewer | 17.2% more | 52.8 (open, 15/15) | 56.7 | 42.0 | 6.8% less | 25.9% more |

## CHECK_IDS: ids (true, standing-7's build) against trig (false)

| project | checkers | ids ms | vs trig: wall | cycles | instructions | RSS (same gate) | ids vs tsrs | ids vs tsrsg |
|---|---|---:|---|---|---|---|---|---|
| ts-pattern | 1 | 719.0 | 2.1% slower | 2.5% more | 4.5% more | 0.2% more (shut) | 13.0% slower | 11.7% slower |
| ts-pattern | 4 | 288.9 | 4.0% slower | 2.6% more | 4.5% more | the same (open) | 38.1% slower | 21.0% slower |
| zod3 | 1 | 134.1 | 0.9% slower | 2.4% more | 5.1% more | 0.6% more (open) | 33.0% slower | 17.6% slower |
| zod3 | 4 | 74.3 | 1.7% slower | 2.4% more | 5.4% more | 0.5% more (open) | 45.4% slower | 14.9% slower |
| mitt | 1 | 16.4 | 0.4% slower | 0.1% more | 0.7% more | 1.4% more (open) | 8.1% slower | 9.3% slower |
| mitt | 4 | 18.7 | 0.8% slower | 1.8% more | 0.9% more | 0.6% more (open) | 0.5% faster | 1.2% faster |
| neverthrow | 1 | 18.9 | 0.6% slower | 0.6% more | 1.3% more | 1.4% more (open) | 16.0% slower | 15.9% slower |
| neverthrow | 4 | 20.1 | 0.8% slower | 1.6% more | 1.8% more | 0.4% more (open) | 2.5% slower | 3.5% slower |
| superstruct | 1 | 26.2 | 2.1% slower | 2.0% more | 3.6% more | 0.9% more (open) | 33.3% slower | 33.5% slower |
| superstruct | 4 | 17.8 | 5.0% slower | 2.2% more | 4.1% more | 0.7% more (open) | 13.8% slower | 15.9% slower |
| tiny-invariant | 1 | 57.9 | 2.5% slower | 2.5% more | 5.0% more | 0.5% more (open) | 7.8% slower | 16.6% slower |
| tiny-invariant | 4 | 61.3 | 3.1% slower | 3.3% more | 5.0% more | 1.2% more (open) | 46.5% slower | 13.6% slower |

## A/A: the copy against Trig main

| project | checkers | wall | fastest | cycles | instructions |
|---|---|---|---|---|---|
| ts-pattern | 1 | 0.7% slower | 0.3% slower | 0.5% more | the same |
| ts-pattern | 4 | 2.5% slower | 2.6% slower | 1.0% more | the same |
| zod3 | 1 | 1.2% faster | 0.3% faster | 0.1% more | the same |
| zod3 | 4 | 1.2% slower | 1.7% slower | 0.2% more | the same |
| mitt | 1 | 0.9% faster | 1.8% slower | 0.1% fewer | the same |
| mitt | 4 | 0.5% slower | 0.4% slower | 0.3% more | 0.1% more |
| neverthrow | 1 | 0.8% faster | 0.3% slower | 0.2% more | the same |
| neverthrow | 4 | 0.6% slower | 0.9% slower | 0.9% more | the same |
| superstruct | 1 | 0.1% faster | 0.6% faster | 0.1% fewer | the same |
| superstruct | 4 | 3.4% slower | 1.7% faster | 0.7% fewer | the same |
| tiny-invariant | 1 | 0.6% faster | 0.3% faster | 0.3% fewer | the same |
| tiny-invariant | 4 | 0.9% slower | 1.1% slower | 0.1% more | the same |
