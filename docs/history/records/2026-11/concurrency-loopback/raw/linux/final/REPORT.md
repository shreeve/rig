# rig#1105 confirm board on Linux: final runtime a0375e5fa (short read + standing kick; skip reverted)
pup, 2026-11-16 07:09–07:14, board slot 268, QUIET honoured. main ea3704772, aa (a copy of main's binary), final.
Medians; net µs a trip (20 rounds), tasks ms (20 rounds, pinned), HTTP req/s (9 rounds, 0-11).

| row | main | aa | final | final against main |
|---|---:|---:|---:|---|
| echo 6,7 | 3.76 | 3.75 | 3.54 | 5.9% faster |
| pingpong 6,7 | 5.16 | 5.18 | 4.92 | 4.7% faster |
| connect 6,7 | 28.88 | 28.97 | 28.42 | 1.6% faster (level) |
| echo 0-11 | 1.13 | 1.13 | 1.08 | 4.4% faster |
| pingpong 0-11 | 5.43 | 5.45 | 5.18 | 4.6% faster |
| connect 0-11 | 26.31 | 26.39 | 26.18 | level |
| tasks: spawn, chain, fanout, yield, produce, hog | 8.28, 1.020, 281.7, 31.98, 6.49, 0.018 | 8.21, 1.021, 280.9, 31.88, 6.50, 0.017 | 8.37, 1.023, 281.3, 31.76, 6.49, 0.017 | 1.1% slower (aa 0.9% faster: inside the 2% spread), level, level, 0.7% faster, level, level |
| HTTP | 695,808 | 696,462 | 702,677 | 1.0% more (level); p99 276 → 261 µs |

The record's Linux bar holds: echo and pingpong faster, connect and spawn level, HTTP at least level. With the skip
reverted no row is slower beyond the A/A spread. Gates at a0375e5fa: burst `zig build test` debug/safe/fast, Trig light
119/119, loco GREEN.
