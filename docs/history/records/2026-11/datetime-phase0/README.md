# Datetime phase 0: measured before building (2026-11-20)

Phase 0 of the datetime design measures what the design leaves to a
measurement, and builds the tools the later phases test against. It
changes nothing a program can see. The design is the owner's final
brief (v3, 2026-11-17).

| Part | What it holds | Record |
|---|---|---|
| `bench/duration/` | `Duration` in two layouts, timed call by call | [bench.md](bench.md) |
| `tools/jiff-oracle/` | Jiff 1.0.0's answers to generated cases, from its bundled 2026f data | [oracle.md](oracle.md) |
| `tools/gen-tzdb.py` | the zone tables, generated and checked against Jiff's bundle | [tzdb.md](tzdb.md) |

## The numbers

- **`Duration`'s layout** (Mac, ReleaseSafe, fastest of 20 interleaved
  rounds, three boards). Layout A, whole seconds and nanoseconds in 16
  bytes, against layout B, one `Int` of nanoseconds, in nanoseconds a
  call:
  - `elapsed()`: A costs about 1.9 more, on a call of about 13.
  - `since`: 0.3 more.
  - A deadline's `add` and compare: 0.1 more.
  - `sleep(0)`: 0.1 to 0.3 more.
  - `within`, and `select` with an `after` arm: no difference beyond
    noise.
  - The `elapsed()` difference is unexplained, since the same conversion
    costs 0.3 in `since`; code placement alone moves a loop that size by
    about 0.8. `bench/tasks`, `actors`, `net`, and `http` are recorded as
    phase 1's baseline.
- **The zone tables**: 110,979 bytes in a compact layout (transitions
  as one `u32` each, types shared, 598 names sharing 345 zones), against
  207,040 in Jiff's bundle. A program that uses a zone grows by 115,776
  bytes, and its build takes 0.07 s longer (2.1%). All 598 names agree
  with the bundle's zone files at 3,991,798 instants.
- **The oracle**: pinned to Jiff, `jiff-core`, and `jiff-tzdb` 1.0.0,
  with the bundle proven to be the only zone data it reads (a fake
  `TZDIR` and `TZ` change none of 7,218 answers). Its generators write
  1,669,949 cases, the same bytes every run, answered in 2.9 s.

## The owner's decision

One `Int` of nanoseconds, as Go's `time.Duration` (the owner, 2026-11-20:
"One Int, saturate like Go"). Its range is ±292 years. `since` between
values farther apart, and `i.unix()` outside the years 1677 to 2262,
saturate at the largest or smallest `Duration`, as Go's `Sub` does, and
`i.unix_s()` gives Unix seconds exactly at any instant. The design's
§5.1, §6.6, §7.3, and §7.8 say so.
