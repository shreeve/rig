# Option U timing (2026-10-22)

The errors-u build (5986a72a4) against main at its base (83f9e6c12),
each compiler building the same programs. MB/s or ms, the fastest of N
interleaved runs.

## std.json, both machines

The parser's hot functions (`document`, `escaped`, `utf8_text`,
`skip_plain_ascii`) sit at the same addresses in both builds.

| file | Mac safe main / U | Mac fast main / U | pup safe main / U | pup fast main / U |
|---|---|---|---|---|
| twitter | 3662 / 3676 | 3710 / 3693 | 3049 / 3053 | 3173 / 3172 |
| twitterescaped | 3194 / 3189 | 3265 / 3268 | 2430 / 2426 | 2672 / 2677 |
| canada | 2154 / 2147 | 2218 / 2236 | 1374 / 1375 | 1531 / 1530 |
| citm_catalog | 4348 / 4353 | 4405 / 4362 (1.0% slower) | 3076 / 3069 | 3029 / 3023 |
| gsoc-2018 | 8414 / 8434 | 8245 / 8230 | 5941 / 5998 | 6231 / 6220 |
| github_events | 4326 / 4332 | 4318 / 4315 | 3352 / 3356 | 3504 / 3490 |

The json instruction guard (bench/json/guard.py, Mac) gives U the
counts main gives, within 0.01% on every file. Both are above guard.txt
on twitterescaped (2.5%), so that baseline is older than main.

## Micro-benchmarks (Mac, fastest of 11; recreach of 31)

| case | safe U/main | fast U/main |
|---|---|---|
| `rec` (`T!` recursion) | 1.010, 0.990 | 1.018, 0.999 |
| `recfields` (fields declared, unrelated) | 0.982 | 0.998 |
| `recreach` (fields reach the slot) | 1.021, 0.968 | 1.008, 1.026 |
| `catchloop` | 1.008 | 1.000 |
| `fnval` (calls through `?fun -> T!`) | 0.996 | 0.999 |

Instructions retired are within 0.01% of main's in every case. The
prototype's 4.0% (safe) cost on `fnval` is gone: the slot has no bits
where no set has fields. `recreach` changes sign between runs, which is
code placement.
