| project | variant | runs | wall fastest | wall median | vs base (median) | instructions (min) | vs base | cycles fastest | cycles median | vs base (median) | peak RSS median |
|---|---|---:|---:|---:|---|---:|---|---:|---:|---|---:|
| empty | base | 10 | 31.27 ms | 33.02 ms |  | 0.1954G |  | 0.0744G | 0.0751G |  | 28.1 MB |
| empty | std | 10 | 31.09 ms | 32.84 ms | 0.54% faster | 0.1928G | 1.35% fewer | 0.0733G | 0.0740G | 1.41% fewer | 28.2 MB |
| empty | ver | 10 | 32.91 ms | 33.17 ms | 0.45% slower | 0.1969G | 0.78% more | 0.0740G | 0.0746G | 0.63% fewer | 29.9 MB |
| mitt | base | 10 | 36.67 ms | 37.87 ms |  | 0.2118G |  | 0.0867G | 0.0873G |  | 30.6 MB |
| mitt | std | 10 | 35.17 ms | 37.25 ms | 1.66% faster | 0.2092G | 1.22% fewer | 0.0848G | 0.0859G | 1.65% fewer | 30.7 MB |
| mitt | ver | 10 | 36.03 ms | 38.18 ms | 0.82% slower | 0.2133G | 0.71% more | 0.0864G | 0.0875G | 0.17% more | 32.6 MB |
| ts-pattern | base | 10 | 1498.54 ms | 1511.28 ms |  | 9.0474G |  | 4.9582G | 4.9735G |  | 245.8 MB |
| ts-pattern | std | 10 | 1490.28 ms | 1502.48 ms | 0.59% faster | 9.0438G | 0.04% fewer | 4.9190G | 4.9450G | 0.57% fewer | 245.7 MB |
| ts-pattern | ver | 10 | 1483.60 ms | 1500.12 ms | 0.74% faster | 9.0496G | 0.02% more | 4.9325G | 4.9481G | 0.51% fewer | 248.2 MB |
| zod3 | base | 10 | 295.96 ms | 299.03 ms |  | 1.6334G |  | 0.9145G | 0.9247G |  | 76.3 MB |
| zod3 | std | 10 | 292.01 ms | 301.79 ms | 0.92% slower | 1.6300G | 0.21% fewer | 0.9150G | 0.9219G | 0.30% fewer | 76.3 MB |
| zod3 | ver | 10 | 297.68 ms | 301.83 ms | 0.94% slower | 1.6354G | 0.13% more | 0.9215G | 0.9276G | 0.32% more | 78.7 MB |
