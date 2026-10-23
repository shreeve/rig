# R4 timing 2: the fallback, `parse` a Bool and `load` beside it (2026-10-22)

**Old** is main's std/json.rig; **wrap** is R4's at d16df4887, which adds
`JsonError` and `load` and leaves `parse` as it was. Both are built by the
R4 compiler into bench/json/bench-json's program, which calls `parse`.
The hot functions (`document`, `escaped`, `utf8_text`,
`skip_plain_ascii`) sit at the same addresses in both binaries, on both
machines and in both modes. MB/s, the fastest of 25 interleaved runs.

## Mac (arm64, load about 5)

| file | safe old | safe wrap | fast old | fast wrap |
|---|---:|---:|---:|---:|
| twitter | 3609 | 3570 (1.1% slower) | 3613 | 3624 |
| twitterescaped | 3156 | 3153 | 3206 | 3212 |
| canada | 2118 | 2123 | 2206 | 2165 (1.9% slower) |
| citm_catalog | 4283 | 4236 (1.1% slower) | 4320 | 4279 (0.9% slower) |
| gsoc-2018 | 8337 | 8308 | 8184 | 8195 |
| github_events | 4244 | 4242 | 4215 | 4230 |

## pup (x86-64, load about 1)

| file | safe old | safe wrap | fast old | fast wrap |
|---|---:|---:|---:|---:|
| twitter | 2996 | 3002 | 3128 | 3126 |
| twitterescaped | 2389 | 2394 | 2636 | 2638 |
| canada | 1366 | 1363 | 1499 | 1484 (1.0% slower) |
| citm_catalog | 3032 | 3032 | 3003 | 2993 |
| gsoc-2018 | 5786 | 5823 | 6091 | 6085 |
| github_events | 3313 | 3313 | 3449 | 3448 |

## Verdict

Within the 2% gate on both machines. With the hot code at the same
addresses, the Mac's spread at load 5 is its noise.
