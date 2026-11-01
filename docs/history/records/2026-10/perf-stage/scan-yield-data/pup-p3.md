| project | variant | runs | wall fastest | wall median | vs base (median) | instructions (min) | vs base | cycles fastest | cycles median | vs base (median) | peak RSS median |
|---|---|---:|---:|---:|---|---:|---|---:|---:|---|---:|
| empty | base | 20 | 20.24 ms | 21.34 ms |  | 0.1962G |  | 0.0668G | 0.0699G |  | 28.1 MB |
| empty | std | 20 | 19.81 ms | 21.17 ms | 0.81% faster | 0.1928G | 1.77% fewer | 0.0666G | 0.0692G | 1.05% fewer | 28.2 MB |
| empty | ver | 20 | 20.79 ms | 21.73 ms | 1.85% slower | 0.1969G | 0.36% more | 0.0686G | 0.0715G | 2.23% more | 29.9 MB |
| mitt | base | 20 | 22.83 ms | 23.76 ms |  | 0.2118G |  | 0.0768G | 0.0788G |  | 30.6 MB |
| mitt | std | 20 | 22.54 ms | 23.97 ms | 0.88% slower | 0.2093G | 1.19% fewer | 0.0742G | 0.0790G | 0.20% more | 30.7 MB |
| mitt | ver | 20 | 23.33 ms | 24.02 ms | 1.12% slower | 0.2133G | 0.71% more | 0.0782G | 0.0797G | 1.19% more | 32.6 MB |
| ts-pattern | base | 20 | 823.34 ms | 831.35 ms |  | 9.0474G |  | 3.6883G | 3.7090G |  | 245.8 MB |
| ts-pattern | std | 20 | 823.84 ms | 829.59 ms | 0.21% faster | 9.0438G | 0.04% fewer | 3.6695G | 3.6927G | 0.44% fewer | 245.7 MB |
| ts-pattern | ver | 20 | 827.57 ms | 835.23 ms | 0.47% slower | 9.0512G | 0.04% more | 3.7017G | 3.7229G | 0.38% more | 248.2 MB |
| zod3 | base | 20 | 158.20 ms | 164.44 ms |  | 1.6351G |  | 0.6697G | 0.6859G |  | 76.3 MB |
| zod3 | std | 20 | 156.80 ms | 159.11 ms | 3.35% faster | 1.6300G | 0.31% fewer | 0.6658G | 0.6730G | 1.92% fewer | 76.3 MB |
| zod3 | ver | 20 | 157.80 ms | 160.10 ms | 2.71% faster | 1.6382G | 0.19% more | 0.6691G | 0.6804G | 0.80% fewer | 78.7 MB |
