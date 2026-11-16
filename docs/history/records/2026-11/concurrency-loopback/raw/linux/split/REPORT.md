# rig#1105 split board (pup, 2026-11-16 06:52–07:00, board slot 269, QUIET honoured)

Arms: main ea3704772, aa (a copy of main's binary), read 39bfcff03 (the short read + its urgent-data fix), kick
f8e91fbed (the kick that stands), skip d52080637 (a worker going to sleep leaves recently taken pollers to their
worker), branch bfdf37fb5 (all three). bench/net pinned to 6,7 and on 0-11, 20 rounds; HTTP on 0-11, 7 rounds.
Medians, µs a trip.

| row | main | aa | read | kick | skip | branch |
|---|---:|---:|---:|---:|---:|---:|
| connect 6,7 | 29.05 | 28.89 | 28.95 | 28.37 | **31.56** | **31.20** |
| connect 0-11 | 26.57 | 26.47 | 26.40 | 26.27 | **29.41** | **28.76** |
| echo 6,7 | 3.75 | 3.75 | **3.50** | 3.77 | 3.76 | **3.52** |
| echo 0-11 | 1.11 | 1.12 | 1.09 | 1.10 | 1.16 | 1.14 |
| pingpong 6,7 | 5.17 | 5.15 | **4.83** | 5.22 | 5.14 | **4.91** |
| pingpong 0-11 | 5.50 | 5.44 | **5.11** | 5.50 | 5.41 | **5.14** |
| HTTP req/s 0-11 (median of 7) | 621k | 690k | 713k | 683k | **551k** | **572k** |
| HTTP p50 µs | 84 | 77 | 75 | 82 | **104** | **100** |

The skip alone costs connect 8.6% pinned and 10.7% on 0-11, and HTTP (lowest median, p50 104 µs; its best round,
622k, is under main's and aa's medians); the branch carries the same cost. The short read alone gives the gains:
echo 6.7% and pingpong 6.6% faster pinned, pingpong 7.1% on 0-11, connect and HTTP level or better. The kick alone is
level everywhere. HTTP's rounds are noisy on this machine (main and aa medians 11% apart), but skip and branch are the
lowest two arms by median and by best round.

Reading: drop the skip (00d2fb066) from #1105; read + kick keep the Linux gains with no row slower.
