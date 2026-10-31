# HTTP benchmark progress

Each row is one measurement of `bench/http/bench-http` (README.md):
requests per second and latency, best of 3, and memory per idle
connection. The reference rows are hyper's and Go's when the benchmark
began; Rig's are added as the runtime grows.

## arm64 (Mac, 10 cores, 5,000 idle connections)

| Date | Change | Variant | req/s | p50 | p99 | per idle conn |
|---|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 180339 | 346 us | 614 us | 18.6 KiB |
| 2026-10-20 | reference | go | 163675 | 366 us | 1071 us | 18.5 KiB |
| 2026-10-20 | #397: http.serve | rig-fast | 171062 | 365 us | 641 us | 32.6 KiB |
| 2026-10-20 | buffers held only per request | rig-fast | 191526 | 326 us | 597 us | 16.6 KiB |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 170966 | 366 us | 643 us | 16.6 KiB |
| 2026-10-21 | #535: interrupts cancel main | rig-fast | 168209 | 371 us | 649 us | 16.6 KiB |
| 2026-10-22 | main before #541, interleaved | rig-fast | 170635 | 362 us | 721 us | 16.6 KiB |
| 2026-10-22 | #541: a run-next fill wakes no worker | rig-fast | 168668 | 357 us | 930 us | 16.6 KiB |
| 2026-10-22 | main before #552, interleaved | rig-fast | 171811 | 363 us | 671 us | 16.6 KiB |
| 2026-10-22 | #552: each worker on cache lines of its own | rig-fast | 172733 | 360 us | 817 us | 16.6 KiB |
| 2026-10-23 | main before #581, interleaved | rig-fast | 180389 | 322 us | 1248 us | 16.6 KiB |
| 2026-10-23 | #581: a sleeping worker leaves the run-next notice set | rig-fast | 181146 | 295 us | 1797 us | 16.6 KiB |
| 2026-10-27 | main 54a7158b5 before #725, interleaved | rig-fast | 171133 | 365 us | 660 us | 16.6 KiB |
| 2026-10-27 | #725: a freed large block serves any request it fits | rig-fast | 175673 | 351 us | 659 us | 16.6 KiB |
| 2026-10-27 | main 967e1ac11 before #726, interleaved | rig-fast | 172223 | 363 us | 629 us | 16.6 KiB |
| 2026-10-27 | #726: huge pages for new blocks of 16 MiB or more (Linux only) | rig-fast | 174056 | 358 us | 603 us | 16.6 KiB |
| 2026-10-28 | main de6ef3e41 before #767, interleaved | rig-fast | 175431 | 359 us | 593 us | 16.6 KiB |
| 2026-10-28 | #767: a frozen value's allocation has no weak count | rig-fast | 172686 | 364 us | 585 us | 16.6 KiB |
| 2026-10-29 | main 277fba515 before #773, interleaved | rig-fast | 168572 | 362 us | 1022 us | 16.6 KiB |
| 2026-10-29 | #773: pointer-sized ^T? and ~T?, no dead drops, a cheaper last drop | rig-fast | 180629 | 259 us | 1761 us | 16.6 KiB |
| 2026-10-30 | main a8acfdc5c before #779, interleaved | rig-fast | 178763 | 326 us | 1239 us | 16.6 KiB |
| 2026-10-30 | #779: no read buffer held while waiting, untouched signal stacks and fresh stacks, TCP_NODELAY | rig-fast | 176453 | 281 us | 2331 us | 16.6 KiB |
| 2026-10-30 | main a8acfdc5c before #781 | rig-fast | 169803 | 367 us | 647 us | 16.6 KiB |
| 2026-10-30 | main a8acfdc5c before #781 | rig-safe | 172606 | 363 us | 652 us | 16.6 KiB |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-fast | 171895 | 362 us | 654 us | 16.6 KiB |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-safe | 167932 | 368 us | 850 us | 16.6 KiB |
| 2026-10-30 | main a8acfdc5c before #780, alternated | rig-fast | 171624 | 352 us | 984 us | 16.6 KiB |
| 2026-10-30 | #780: String and List appends grow by value | rig-fast | 175955 | 330 us | 1300 us | 16.6 KiB |

## x86-64 (pup, 22 cores, 10,000 idle connections)

| Date | Change | Variant | req/s | p50 | p99 | per idle conn |
|---|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 294609 | 162 us | 808 us | 10.8 KiB |
| 2026-10-20 | reference | go | 237436 | 153 us | 1439 us | 19.3 KiB |
| 2026-10-20 | #397: http.serve | rig-fast | 845844 | 51 us | 427 us | 16.6 KiB |
| 2026-10-20 | buffers held only per request | rig-fast | 205059 | 293 us | 471 us | 8.6 KiB |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 1124804 | 37 us | 402 us | 8.6 KiB |
| 2026-10-21 | #535: interrupts cancel main | rig-fast | 1010096 | 42 us | 286 us | 8.6 KiB |
| 2026-10-22 | main before #541, interleaved (pup cores 8,9) | rig-fast | 166171 | 237 us | 3542 us | 8.6 KiB |
| 2026-10-22 | #541: a run-next fill wakes no worker (pup cores 8,9) | rig-fast | 194189 | 198 us | 3512 us | 8.6 KiB |
| 2026-10-22 | main before #552, interleaved (pup cores 8,9) | rig-fast | 211565 | 177 us | 3424 us | 8.6 KiB |
| 2026-10-22 | #552: each worker on cache lines of its own (pup cores 8,9) | rig-fast | 211728 | 186 us | 3415 us | 8.6 KiB |
| 2026-10-23 | main before #581, interleaved (pup cores 8,9) | rig-fast | 197925 | 195 us | 3482 us | 8.6 KiB |
| 2026-10-23 | #581: a sleeping worker leaves the run-next notice set (pup cores 8,9) | rig-fast | 196492 | 202 us | 3445 us | 8.6 KiB |
| 2026-10-24 | main before #621, interleaved (pup cores 8,9) | rig-fast | 212312 | 189 us | 3396 us | 8.6 KiB |
| 2026-10-24 | #621: os.memory counts each allocation (pup cores 8,9) | rig-fast | 212726 | 183 us | 3412 us | 8.6 KiB |
| 2026-10-24 | main before #624, interleaved (pup cores 6,7) | rig-fast | 190539 | 206 us | 3476 us | 8.6 KiB |
| 2026-10-24 | #624: the blocking pool keeps a few threads busy (pup cores 6,7) | rig-fast | 192676 | 203 us | 3485 us | 8.6 KiB |
| 2026-10-25 | main before #677, interleaved (pup cores 6,7) | rig-fast | 186733 | 213 us | 3505 us | 8.6 KiB |
| 2026-10-25 | #677: fewer yield checks (pup cores 6,7) | rig-fast | 186094 | 208 us | 3502 us | 8.6 KiB |
| 2026-10-25 | main 99dcccf13 (before #677 and #683), interleaved (pup cores 6,7) | rig-fast | 196161 | 193 us | 3461 us | 8.6 KiB |
| 2026-10-25 | #683: the pool's spin lock waits by reading (pup cores 6,7) | rig-fast | 195093 | 215 us | 3482 us | 8.6 KiB |
| 2026-10-27 | main 54a7158b5 before #725, interleaved (pup cores 6,7) | rig-fast | 196316 | 201 us | 3448 us | 8.6 KiB |
| 2026-10-27 | #725: a freed large block serves any request it fits (pup cores 6,7) | rig-fast | 201191 | 198 us | 3434 us | 8.6 KiB |
| 2026-10-27 | main 967e1ac11 before #726, interleaved (pup cores 6,7) | rig-fast | 209739 | 179 us | 3391 us | 8.6 KiB |
| 2026-10-27 | #726: huge pages for new blocks of 16 MiB or more (pup cores 6,7) | rig-fast | 210404 | 177 us | 3381 us | 8.6 KiB |
| 2026-10-28 | main de6ef3e41 before #767, interleaved (pup core 6, server and load) | rig-fast | 148184 | 338 us | 2847 us | 8.6 KiB |
| 2026-10-28 | #767: a frozen value's allocation has no weak count (pup core 6, server and load) | rig-fast | 150723 | 334 us | 2732 us | 8.6 KiB |
| 2026-10-29 | main 277fba515 before #773, interleaved (pup core 6, server and load) | rig-fast | 125591 | 398 us | 2902 us | 8.6 KiB |
| 2026-10-29 | #773: pointer-sized ^T? and ~T?, no dead drops, a cheaper last drop (pup core 6, server and load) | rig-fast | 140740 | 346 us | 2865 us | 8.6 KiB |
| 2026-10-30 | main a8acfdc5c before #779, interleaved (pup core 8, server and load) | rig-fast | 146697 | 351 us | 2775 us | 8.6 KiB |
| 2026-10-30 | #779: no read buffer held while waiting, untouched signal stacks and fresh stacks, TCP_NODELAY (pup core 8, server and load) | rig-fast | 146440 | 325 us | 2808 us | 8.6 KiB |
| 2026-10-30 | main a8acfdc5c before #780, alternated (pup core 6, server and load) | rig-fast | 149799 | 343 us | 2742 us | 8.6 KiB |
| 2026-10-30 | #780: String and List appends grow by value (pup core 6, server and load) | rig-fast | 148588 | 353 us | 2757 us | 8.6 KiB |

The "buffers held only per request" rows (#402) ran on a build that
pinned every task to the worker that made it, a slip of #401 that #405
fixed: one core served every connection. Their memory stands; their
speed does not, and #405's rows are the measure. On the Mac one core
leaves the load generator, on the same machine, more of the others,
which is why that row reads faster.
| 2026-10-30 | main a8acfdc5c before #781 | rig-fast | 1026401 | 43 us | 287 us | 8.6 KiB |
| 2026-10-30 | main a8acfdc5c before #781 | rig-safe | 997282 | 38 us | 559 us | 8.6 KiB |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-fast | 1047411 | 39 us | 307 us | 8.6 KiB |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-safe | 936124 | 46 us | 324 us | 8.6 KiB |
| 2026-10-30 | main 344257fc0 before #783 (no idle run: the Mac busy with other sessions, its ports taken) | rig-fast | 157649 | 383 us | 1215 us |  |
| 2026-10-30 | main 344257fc0 before #783 (no idle run: the Mac busy with other sessions, its ports taken) | rig-safe | 158633 | 387 us | 905 us |  |
| 2026-10-30 | #783: a stream splits; an end wakes only its waits (no idle run, the Mac busy) | rig-fast | 159260 | 377 us | 1110 us |  |
| 2026-10-30 | #783: a stream splits; an end wakes only its waits (no idle run, the Mac busy) | rig-safe | 157041 | 379 us | 1156 us |  |
| 2026-10-30 | main 344257fc0 before #783, alternated (pup core 6) | rig-fast | 149186 | 339 us | 2750 us | 8.6 KiB |
| 2026-10-30 | #783: a stream splits; an end wakes only its waits (pup core 6) | rig-fast | 148130 | 342 us | 2746 us | 8.6 KiB |
| 2026-10-30 | main before #788, alternated (pup core 6) | rig-fast | 204149 | 189 us | 3421 us | 8.6 KiB |
| 2026-10-30 | #788: reads grow a String unfilled (pup core 6) | rig-fast | 203772 | 194 us | 3428 us | 8.6 KiB |
