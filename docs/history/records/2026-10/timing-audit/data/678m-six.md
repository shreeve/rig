| project | build | wall | user cycles | instructions | peak RSS | wall vs main | cycles vs main | RSS vs main |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern | main | 0.922 s | 3.894G | 9.523G | 270.4 MB |  |  |  |
| ts-pattern | nopf | 0.919 s | 3.899G | 9.523G | 272.3 MB | 0.4% faster | 0.1% slower | 0.7% more |
| zod3 | main | 0.236 s | 0.927G | 2.229G | 107.4 MB |  |  |  |
| zod3 | nopf | 0.236 s | 0.925G | 2.229G | 109.3 MB | 0.2% slower | 0.1% faster | 1.8% more |
| mitt | main | 0.034 s | 0.084G | 0.229G | 33.1 MB |  |  |  |
| mitt | nopf | 0.034 s | 0.086G | 0.229G | 34.7 MB | 0.7% faster | 2.0% slower | 4.9% more |
| neverthrow | main | 0.038 s | 0.104G | 0.263G | 34.7 MB |  |  |  |
| neverthrow | nopf | 0.039 s | 0.105G | 0.263G | 36.4 MB | 0.5% slower | 0.7% slower | 4.9% more |
| superstruct | main | 0.046 s | 0.137G | 0.306G | 27.9 MB |  |  |  |
| superstruct | nopf | 0.046 s | 0.138G | 0.306G | 29.4 MB | 0.1% slower | 1.0% slower | 5.4% more |
| tiny-invariant | main | 0.087 s | 0.301G | 0.933G | 52.9 MB |  |  |  |
| tiny-invariant | nopf | 0.087 s | 0.304G | 0.933G | 54.6 MB | 0.4% slower | 1.1% slower | 3.2% more |
