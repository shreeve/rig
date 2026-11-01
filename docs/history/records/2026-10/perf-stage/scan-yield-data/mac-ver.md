30 rounds kept of 33 run; every run's output identical to base's

| project | variant | wall fastest | wall median | vs base (median) | instructions (min) | vs base | cycles fastest | cycles median | vs base (median) | peak RSS median |
|---|---|---:|---:|---|---:|---|---:|---:|---|---:|
| empty | base | 18.01 ms | 19.93 ms |  | 0.2721G |  | 0.0620G | 0.0660G |  | 29.7 MB |
| empty | std | 17.89 ms | 19.66 ms | 1.37% faster | 0.2699G | 0.81% fewer | 0.0620G | 0.0662G | 0.31% more | 29.8 MB |
| empty | ver | 17.92 ms | 19.80 ms | 0.66% faster | 0.2732G | 0.40% more | 0.0625G | 0.0662G | 0.26% more | 29.9 MB |
| mitt | base | 19.83 ms | 21.69 ms |  | 0.2948G |  | 0.0703G | 0.0744G |  | 32.8 MB |
| mitt | std | 19.93 ms | 21.87 ms | 0.83% slower | 0.2923G | 0.84% fewer | 0.0702G | 0.0741G | 0.40% fewer | 32.9 MB |
| mitt | ver | 20.04 ms | 22.01 ms | 1.48% slower | 0.2958G | 0.33% more | 0.0699G | 0.0745G | 0.22% more | 32.8 MB |
| ts-pattern | base | 498.09 ms | 559.48 ms |  | 9.6707G |  | 2.0965G | 2.2466G |  | 260.4 MB |
| ts-pattern | std | 492.25 ms | 550.42 ms | 1.65% faster | 9.6558G | 0.15% fewer | 2.0745G | 2.2311G | 0.69% fewer | 260.4 MB |
| ts-pattern | ver | 495.73 ms | 547.96 ms | 2.10% faster | 9.6575G | 0.14% fewer | 2.0883G | 2.2289G | 0.79% fewer | 260.5 MB |
| zod3 | base | 103.61 ms | 114.54 ms |  | 1.8599G |  | 0.4216G | 0.4479G |  | 80.2 MB |
| zod3 | std | 103.56 ms | 115.16 ms | 0.54% slower | 1.8569G | 0.17% fewer | 0.4221G | 0.4519G | 0.88% more | 80.2 MB |
| zod3 | ver | 104.73 ms | 115.70 ms | 1.01% slower | 1.8616G | 0.09% more | 0.4267G | 0.4533G | 1.21% more | 80.3 MB |
