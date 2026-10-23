# R4 timing 1: std.json with `JsonError` against main's (2026-10-22)

**Old** is main's std/json.rig (`parse` answers a `Bool`, the error in
`doc.error` and `doc.error_pos`). **New** is R4's (`parse` fails with
`JsonError.bad(kind:, at:)`). Both are built by the R4 branch's compiler
into bench/json/bench-json's program, which gives `old` the same Zig main
gives it. The emitted parsers differ only in `parse`'s signature, its
failing tail, and the two reset stores it no longer makes; every function
keeps its inline marker. MB/s is the fastest of N interleaved runs of
about 400 ms. The Mac was not exclusive (load about 3); pup was at
load 0.7–1.0, on slot cores 10,11.

## Mac (arm64)

Run 1, fastest of 15:

| file | safe old | safe new | fast old | fast new |
|---|---:|---:|---:|---:|
| twitter | 3602 | 3593 | 3686 | 3588 (2.7% slower) |
| twitterescaped | 3163 | 3155 | 3232 | 3239 |
| canada | 2137 | 2106 (1.5% slower) | 2218 | 2235 |
| citm_catalog | 4302 | 4316 | 4340 | 4222 (2.7% slower) |
| gsoc-2018 | 8374 | 8326 | 8196 | 8174 |
| github_events | 4263 | 4211 (1.2% slower) | 4254 | 4194 (1.4% slower) |

Run 2, fastest of 25:

| file | fast old | fast new | safe old | safe new |
|---|---:|---:|---:|---:|
| twitter | 3723 | 3635 (2.4% slower) | 3684 | 3642 (1.1% slower) |
| twitterescaped | 3271 | 3271 | 3196 | 3190 |
| canada | 2220 | 2260 | 2153 | 2125 (1.3% slower) |
| citm_catalog | 4385 | 4289 (2.2% slower) | 4366 | 4342 |
| gsoc-2018 | 8303 | 8272 | 8446 | 8430 |
| github_events | 4293 | 4251 | 4312 | 4256 (1.3% slower) |

A/A, fastest of 25 (`old2` is a byte-identical copy of `old`):

| file | fast old | fast old2 | fast new |
|---|---:|---:|---:|
| twitter | 3669 | 3669 | 3619 (1.4% slower) |
| citm_catalog | 4355 | 4356 | 4238 (2.7% slower) |

With `parse`'s failing tail marked `rarely`, fastest of 25: twitter
3684 / 3607 / 3564 (old / new / rarely), citm_catalog 4377 / 4241 /
4206. It is no better.

## pup (x86-64), fastest of 25

| file | safe old | safe new | fast old | fast new |
|---|---:|---:|---:|---:|
| twitter | 3012 | 2944 (2.3% slower) | 3124 | 3137 |
| twitterescaped | 2424 | 2420 | 2647 | 2643 |
| canada | 1365 | 1358 | 1510 | 1538 (1.9% faster) |
| citm_catalog | 3059 | 3032 | 3000 | 3033 |
| gsoc-2018 | 5818 | 5814 | 6140 | 6122 |
| github_events | 3319 | 3357 | 3464 | 3620 (4.5% faster) |

## Verdict

Beyond the 2% rule on the Mac for `rig-fast` on twitter and
citm_catalog (2.1–3.1% slower in three runs, A/A at 0%), and on pup for
`rig-safe` on twitter (2.3%). The round stops here for Rig's call; it is
not landed.
