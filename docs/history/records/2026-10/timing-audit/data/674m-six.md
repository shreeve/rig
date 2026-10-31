| project | build | wall | user cycles | instructions | peak RSS | wall vs main | cycles vs main | RSS vs main |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern | main | 1.038 s | 4.208G | 9.523G | 270.4 MB |  |  |  |
| ts-pattern | nolead | 1.042 s | 4.211G | 9.522G | 272.5 MB | 0.4% slower | 0.1% slower | 0.8% more |
| zod3 | main | 0.266 s | 1.003G | 2.230G | 107.4 MB |  |  |  |
| zod3 | nolead | 0.263 s | 0.989G | 2.229G | 109.4 MB | 1.4% faster | 1.4% faster | 1.9% more |
| mitt | main | 0.037 s | 0.086G | 0.229G | 33.1 MB |  |  |  |
| mitt | nolead | 0.038 s | 0.087G | 0.229G | 35.1 MB | 1.1% slower | 0.4% slower | 6.1% more |
| neverthrow | main | 0.043 s | 0.108G | 0.263G | 34.7 MB |  |  |  |
| neverthrow | nolead | 0.043 s | 0.108G | 0.263G | 36.5 MB | 0.0% slower | 0.1% slower | 5.1% more |
| superstruct | main | 0.050 s | 0.144G | 0.306G | 27.9 MB |  |  |  |
| superstruct | nolead | 0.051 s | 0.146G | 0.306G | 29.8 MB | 1.3% slower | 1.2% slower | 6.8% more |
| tiny-invariant | main | 0.096 s | 0.321G | 0.933G | 52.9 MB |  |  |  |
| tiny-invariant | nolead | 0.097 s | 0.323G | 0.933G | 54.9 MB | 1.2% slower | 0.5% slower | 3.7% more |
