30 rounds kept of 32 run; every run's output identical to base's

| project | variant | wall fastest | wall median | vs base (median) | instructions (min) | vs base | cycles fastest | cycles median | vs base (median) | peak RSS median |
|---|---|---:|---:|---|---:|---|---:|---:|---|---:|
| empty | base | 19.55 ms | 21.59 ms |  | 0.2719G |  | 0.0645G | 0.0677G |  | 29.7 MB |
| empty | std | 19.55 ms | 21.34 ms | 1.20% faster | 0.2696G | 0.85% fewer | 0.0633G | 0.0680G | 0.33% more | 29.8 MB |
| empty | all | 19.61 ms | 21.34 ms | 1.18% faster | 0.2691G | 1.05% fewer | 0.0645G | 0.0674G | 0.45% fewer | 29.8 MB |
| empty | none | 19.56 ms | 21.20 ms | 1.86% faster | 0.2651G | 2.56% fewer | 0.0630G | 0.0667G | 1.52% fewer | 29.7 MB |
| mitt | base | 21.46 ms | 24.11 ms |  | 0.2945G |  | 0.0726G | 0.0770G |  | 32.8 MB |
| mitt | std | 21.66 ms | 23.88 ms | 0.98% faster | 0.2924G | 0.72% fewer | 0.0725G | 0.0774G | 0.57% more | 32.9 MB |
| mitt | all | 20.42 ms | 24.16 ms | 0.20% slower | 0.2910G | 1.19% fewer | 0.0720G | 0.0773G | 0.48% more | 32.8 MB |
| mitt | none | 21.17 ms | 23.68 ms | 1.83% faster | 0.2871G | 2.56% fewer | 0.0727G | 0.0757G | 1.68% fewer | 32.6 MB |
| ts-pattern | base | 563.01 ms | 612.09 ms |  | 9.6758G |  | 2.2210G | 2.3543G |  | 260.4 MB |
| ts-pattern | std | 568.03 ms | 621.90 ms | 1.60% slower | 9.6721G | 0.04% fewer | 2.2303G | 2.3741G | 0.84% more | 260.4 MB |
| ts-pattern | all | 554.86 ms | 612.06 ms | 0.01% faster | 9.6177G | 0.60% fewer | 2.2330G | 2.3602G | 0.25% more | 260.4 MB |
| ts-pattern | none | 561.16 ms | 596.72 ms | 2.58% faster | 9.4334G | 2.57% fewer | 2.2055G | 2.3409G | 0.57% fewer | 260.2 MB |
| zod3 | base | 117.76 ms | 130.93 ms |  | 1.8610G |  | 0.4501G | 0.4710G |  | 80.2 MB |
| zod3 | std | 115.64 ms | 126.17 ms | 3.77% faster | 1.8585G | 0.14% fewer | 0.4463G | 0.4707G | 0.07% fewer | 80.2 MB |
| zod3 | all | 114.93 ms | 121.26 ms | 7.97% faster | 1.8490G | 0.65% fewer | 0.4463G | 0.4711G | 0.03% more | 80.2 MB |
| zod3 | none | 109.52 ms | 126.10 ms | 3.83% faster | 1.8216G | 2.16% fewer | 0.4393G | 0.4695G | 0.31% fewer | 80.0 MB |
