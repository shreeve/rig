# std.json's whitespace skip: three tries, none taken (2026-11-05)

The first lead of the v0.3.1 speed work against yyjson, on the Mac. yyjson runs 11% faster than std.json by geomean ([standing-2026-11-05.md](standing-2026-11-05.md)). Both run at about the same IPC (6-8), but std.json retires 40% more instructions on twitter and citm_catalog:

| file | std.json instructions/byte | cycles/byte | IPC | yyjson instructions/byte | cycles/byte | IPC |
|---|---:|---:|---:|---:|---:|---:|
| twitter | 7.82 | 1.213 | 6.4 | 5.59 | 0.853 | 6.6 |
| twitterescaped | 9.25 | 1.349 | 6.9 | 7.94 | 1.085 | 7.3 |
| canada | 16.13 | 2.097 | 7.7 | 13.37 | 2.036 | 6.6 |
| citm_catalog | 8.00 | 1.025 | 7.8 | 5.61 | 0.789 | 7.1 |
| gsoc-2018 | 3.30 | 0.593 | 5.6 | 5.26 | 0.933 | 5.6 |
| github_events | 6.94 | 1.020 | 6.8 | 5.73 | 0.823 | 7.0 |

A line profile of citm_catalog (`bench/json/timers/lines.py`, new: Time Profiler samples charged to the emitted module's lines) puts 43% of its samples in `skip_space`. citm_catalog is 71% whitespace (twitter 27%, gsoc-2018 and github_events 19%, twitterescaped 0.6%, canada none).

Each try below is the Mac, Rig main cf6a362a6, `rig-safe`. Instructions are from `bench/json/guard.py`, against main's 7.81, 9.26, 16.12, 8.02, 3.30 and 6.95 per byte. Time is the fastest of 20 interleaved runs (`timers/time.py`), at a load of 4-9.

## 1. A 16-byte vector scan (`Simd[U8, 16]`, `.first()`)

The first byte is tested as before; a run goes 16 bytes at a time, and the block loop is a separate call (`called fun`). Inlined, it cost twitterescaped 4% more instructions.

- **Instructions:** 13% fewer on twitter, 2% on twitterescaped, 3% on canada, 23% on citm_catalog, 10% on gsoc-2018, and 18% on github_events.
- **Time:** much slower, as a call. citm_catalog went from 4116 to 2608 MB/s, twitter from 3599 to 2118, and github_events from 4093 to 2475. twitterescaped and canada were level. The inlined version was not timed.

## 2. SWAR: 8 bytes XORed with spaces, skipped by their trailing zeros

`i += 8 if x == 0 else Int(x.trailing_zeros() >> 3)`.

- **Instructions:** 11-18% fewer on the indented files.
- **Time:** citm_catalog went from 4028 to 2692 MB/s, twitter from 3451 to 2853, and github_events from 3995 to 3439. IPC fell from 7.7 to 4.6 on citm_catalog.

## 3. One 8-byte read, tested a byte at a time, unrolled

Each byte's test is a predicted branch, against a bit set of the four whitespace bytes.

- **Result:** 3-16% more instructions, and more cycles on every file.

## What it shows

- **On Apple's cores, main's byte loop is already the fast shape.** Its tests are branches the processor predicts and runs ahead of: `c > ' '`, then 8 spaces at once when they are spaces.
- **A computed advance is slower.** Taking the run's length from a vector mask or a count of trailing zeros puts a load-to-load dependency on every step: each next position waits for the last read. The processor can no longer run ahead, so IPC falls further than the instructions saved.
- **yyjson's loop has the same shape:** one table test and one branch per byte. It needs no bounds test, since its input ends in padding. So the whitespace is not where yyjson's lead is. The 40% more instructions are spread through the parser's work per token, which is the next lead.
- **x86 may differ,** where a vector compare's mask reaches a general register cheaply (`TIER`). Try 1 is to be timed on pup when it is reachable.
