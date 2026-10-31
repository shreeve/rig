| project | variant | wall (fastest of 30) | against base | instructions | cycles (of fastest) | peak RSS |
|---|---|---:|---|---:|---:|---:|
| ts-pattern | base | 545.8 ms |  | 9.716G () | 2.268G | 260 MB |
| ts-pattern | mainrig | 530.3 ms | 2.9% faster | 9.690G (0.3% fewer) | 2.221G | 260 MB |
| ts-pattern | none | 528.9 ms | 3.2% faster | 9.459G (2.7% fewer) | 2.214G | 260 MB |
| ts-pattern | flag | 531.8 ms | 2.6% faster | 9.668G (0.5% fewer) | 2.221G | 261 MB |
| ts-pattern | callfree | 536.9 ms | 1.7% faster | 9.580G (1.4% fewer) | 2.244G | 260 MB |
| ts-pattern | entry-noloops | 538.8 ms | 1.3% faster | 9.906G (2.0% more) | 2.251G | 261 MB |
| ts-pattern | entry-callfree | 545.2 ms | 0.1% faster | 10.030G (3.2% more) | 2.281G | 261 MB |
| zod3 | base | 112.4 ms |  | 1.876G () | 0.454G | 80 MB |
| zod3 | mainrig | 113.3 ms | 0.8% slower | 1.875G (0.1% fewer) | 0.457G | 80 MB |
| zod3 | none | 111.9 ms | 0.4% faster | 1.843G (1.8% fewer) | 0.452G | 80 MB |
| zod3 | flag | 112.6 ms | 0.2% slower | 1.879G (0.2% more) | 0.458G | 80 MB |
| zod3 | callfree | 113.1 ms | 0.6% slower | 1.865G (0.6% fewer) | 0.458G | 80 MB |
| zod3 | entry-noloops | 113.9 ms | 1.3% slower | 1.935G (3.1% more) | 0.460G | 80 MB |
| zod3 | entry-callfree | 114.8 ms | 2.1% slower | 1.957G (4.3% more) | 0.464G | 80 MB |
