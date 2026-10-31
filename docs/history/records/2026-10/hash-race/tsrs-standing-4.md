# Where Trig stands against tsrs, at Rig main af6e0e6bf (2026-10-30)

Step 1 of the owner's speed plan: how far is Trig's PGO build behind
shipped tsrs at one checker after the day's merges (#773 to #792), what
did Rig move since [tsrs-standing-3.md](tsrs-standing-3.md), and what is
left of the gap, by part and by who owns it. The method is standing-3's,
on all six of Trig's projects, with one fix to its timing (below).
Measurement only; no code changed. Scripts and raw output are in
[tsrs-standing-4-data/](tsrs-standing-4-data/).

## Method

- **Machine.** pup (Core Ultra 9 185H), every run on P-core 6 with its
  sibling 7 idle (`taskset -c 6`); `perf` itself and the profiles' `perf
  script` on the E-cores 12-19. Before each round `time.sh` waited until
  no other thread ran on core 6 or 7. Load 0.6 to 2.4.
- **Trig.** Main `2ba0719`, as in standing-3: Trig has not moved, so
  every change below is Rig's. Its `src/` and `tools/trig` by `git
  archive`, its projects copied beside them.
- **Variants** ([build.out](tsrs-standing-4-data/build.out)):
  - `af6-pgo`: Trig `2ba0719` by Rig main `af6e0e6bf`, `rig build
    --release --pgo` trained by `tools/trig/bolt-train`, through
    `slot.sh` on the E-core slots (`TRIG_RELEASE_SLOTS='12,13 14,15
    16,17'`), sha256 `c3f49d1f6cc11aae`;
  - `1b2-pgo`: standing-3's own binary, Trig `2ba0719` by `1b2f4b59d`,
    copied (sha256 `6525afb0a9813a45`, as standing-3's build.out);
  - `tsrs`: shipped 0.18.0, Go mode on one thread, as standing-3.
- **Timing.** One `perf stat` per run, standing-3's counters, peak RSS by
  `/usr/bin/time`, Linux's free 2 MiB blocks before each run. Every run
  of the 840 gave tsrs's bytes.
  - `times.txt`: 20 rounds of all six projects; `times-b.txt`: 20 more of
    ts-pattern and zod3. The variants in a fixed order.
  - `times-rot.txt`: 20 rounds of all six with the order rotated each
    round (`time-rot.sh`). **These are the numbers below.**
- **Diagnosis** (`diag.sh`, on `af6-pgo`): standing-3's, on core 6, with
  the sampled profiles, LBR stacks and fault runs taken on ts-pattern as
  well as zod3, 20 runs each.

## The timing fix: rotate the first variant

`time.sh`'s wait before each round leaves core 6 idle for about a
second, and its clock drops. The round's first run starts on the cold
core: on the 25 ms projects `af6-pgo`, first in every round, ran at 3.8
GHz against 4.4 for the others (cycles over CPU time,
[clock-fixed-order.txt](tsrs-standing-4-data/clock-fixed-order.txt)), so
it took 5-7% fewer user cycles and 3-10% more wall time than
`1b2-pgo`. On zod3 the cost was about 2%, on ts-pattern nothing. With the
order rotated every variant runs at the same clock
([clock-rotated.txt](tsrs-standing-4-data/clock-rotated.txt)).

standing-3 had the same bias: its Rig-main variant ran first in every
round, so its wall times on zod3 read a little slow; its cycles are
unaffected. Other harnesses: `rehash-counts-data/trigtime.sh` already
rotates; `census-time.py` and `census/trigtime.py` run in a fixed order
but never idle the core between runs, so they are exposed less, not
measured. A harness that waits for a quiet core before a round must
rotate its order.

## Trig against tsrs

Rotated rounds, 20 a variant, medians. standing-3's ratio is from
2026-10-29 (pup ran every variant faster that day: tsrs 2.9% on
ts-pattern), so only the same-day columns compare.

| project | Trig `af6` | Trig `1b2` | tsrs | `af6` / tsrs | `1b2` / tsrs | standing-3 | `af6` against `1b2` |
|---|---:|---:|---:|---:|---:|---:|---|
| ts-pattern | 760.1 ms | 769.8 ms | 645.9 ms | **1.18×** | 1.19× | 1.19× | 1.3% faster |
| zod3 | 153.6 ms | 155.0 ms | 115.2 ms | **1.33×** | 1.35× | 1.33× | 0.9% faster |
| tiny-invariant | 71.3 ms | 72.6 ms | 52.4 ms | 1.36× | 1.38× | | 1.7% faster |
| superstruct | 31.4 ms | 33.2 ms | 22.2 ms | 1.42× | 1.50× | | 5.3% faster |
| mitt | 25.9 ms | 27.2 ms | 17.6 ms | 1.47× | 1.54× | | 4.6% faster |
| neverthrow | 28.1 ms | 29.5 ms | 18.7 ms | 1.50× | 1.57× | | 4.7% faster |

The counts on the two large projects:

| | ts-pattern `af6` | `1b2` | tsrs | zod3 `af6` | `1b2` | tsrs |
|---|---:|---:|---:|---:|---:|---:|
| user cycles | 3.237G | 3.289G | 2.880G | 0.608G | 0.617G | 0.480G |
| kernel cycles | 340M | 338M | 173M | 97M | 96M | 53M |
| instructions | 7.965G | 7.982G | 7.233G | 1.406G | 1.413G | 1.210G |
| page faults | 40,245 | 40,415 | 17,792 | 9,920 | 10,061 | 5,415 |
| dTLB load walks | 2.00M | 2.01M | 0.60M | 201k | 212k | 55k |
| peak RSS | 249.9 MB | 247.9 MB | 202.1 MB | 79.9 MB | 77.9 MB | 53.9 MB |

- **What Rig moved since standing-3:** 1.6% fewer user cycles on
  ts-pattern, 1.5% on zod3, 1.4-4.8% on the small projects, and 0.2-2.1%
  fewer instructions (#773, #777, #780, #788 among them; not split by
  PR). Kernel cycles are level on the large projects and 1-11% fewer on
  the small ones, with 2-27% fewer page faults.
- **Peak memory rose:** 0.8% on ts-pattern, 2.4% on zod3, 3-8% (1.6 to
  2.4 MB) on the small projects, while their page faults fell. Not split by PR;
  fewer faults with more resident memory points to larger prefaulted
  runs.
- **The huge-page gate was shut for every run:** pup had 5 to 69 free 2
  MiB blocks against the gate's 128, so every Trig run here is
  standing-3's gate-shut mode (40,245 faults on ts-pattern). standing-3
  measured the gate-open runs 4.9% faster on ts-pattern.

## Where the gap is

Kernel and user cycles from the timing, split by the profiles (kernel
samples by kind; user by phase from `--extendedDiagnostics`, medians of
5; hot spots by LBR). Milliseconds are at each run's clock.

**zod3**, gap 38.4 ms:

| part | Trig | tsrs | gap |
|---|---:|---:|---:|
| user cycles | 0.608G | 0.480G | **28 ms (72%)** |
| of it, parse | 20 ms | 11 ms | 9 ms |
| of it, bind | 7 ms | 3 ms | 4 ms |
| of it, check | 114 ms | 91 ms | 23 ms (wall, with its kernel time) |
| kernel cycles | 97M (21 ms) | 53M (11.4 ms) | **9.5 ms (25%)** |
| of it, page faults | 56% (11.7 ms) | 84% (9.5 ms) | 2.2 ms |
| of it, `madvise` (prefaulting, huge-page advice) | 22% (4.6 ms) | none | 4.6 ms |
| of it, `munmap`, `mremap` | 9% (1.9 ms) | none | 1.9 ms |
| of it, the blocking pool (777 futex and 387 epoll calls against tsrs's 318 and none) | about 1 ms | | ~1 ms |

**ts-pattern**, gap 114 ms:

| part | Trig | tsrs | gap |
|---|---:|---:|---:|
| user cycles | 3.237G | 2.880G | **76 ms (66%)** |
| of it, parse and bind | 21 + 7 ms | 12 + 3 ms | 13 ms |
| of it, check | 702 ms | 621 ms | 81 ms (wall, with its kernel time) |
| kernel cycles | 340M (72 ms) | 173M (36 ms) | **35 ms (31%)** |
| of it, page faults | 56% (40 ms) | 93% (34 ms) | 6 ms |
| of it, `madvise` | 27% (20 ms) | none | **20 ms (17% of the gap)** |
| of it, `munmap`, `mremap` | 10% (7 ms) | none | 7 ms |

`madvise` is 258 calls a zod3 run: 167 `MADV_POPULATE_WRITE` (32.6 MiB),
48 `MADV_HUGEPAGE`, 43 `MADV_NOHUGEPAGE` ([mem-summary.txt](tsrs-standing-4-data/mem-summary.txt)).
tsrs makes 18.

The user side's hot spots, as inclusive shares of user cycles by LBR
([lbr-shares.txt](tsrs-standing-4-data/lbr-shares.txt)):

| | zod3 | ts-pattern | standing-3 (zod3) |
|---|---:|---:|---:|
| `instantiate_type_with_alias` | 19.5% | **68.7%** (18.3% its own) | |
| parse (`parse_source_file_worker`) | 10.1% | 1.6% | |
| `resolve_external_module` | 5.0% | 1.2% | 4.2% |
| bind | 4.3% | 0.9% | |
| `check_collisions_for_declaration_name` | 2.3% | 0.4% | 1.5% |
| `rig.alloc.alloc` and `free` | 2.3% | 2.2% | |
| `get_emit_module_format_of_file` | 0.9% | 0.0% | 1.5% |

`std.file.realpath`, run on the blocking pool's thread, takes 2.0 ms of
user time on zod3 by the sampled profile ([prof-summary.txt](tsrs-standing-4-data/prof-summary.txt)).
The fixed cost is standing-3's: the `empty` project (zod3's five
libraries) 26.6 ms against 15.5, 30.3 against 17.2 MB
([fixed-summary.txt](tsrs-standing-4-data/fixed-summary.txt)).

## The gap, ranked, and who owns it

Owners by standing-3's method: what Rig's compiler, runtime or std
decides is Rig's; what Trig's code decides is Trig's.

| lead | owner | ts-pattern | zod3 |
|---|---|---:|---:|
| 1. The check's own work: `instantiate_type_with_alias` and its callees at 69% of ts-pattern's user cycles, the relation and resolution code | Trig | **~63 ms of 76** | ~10 ms |
| 2. `madvise` prefaulting and huge-page advice: 258 calls a zod3 run, tsrs 18 | Rig (runtime allocator) | **20 ms (17%)** | 4.6 ms (12%) |
| 3. Parse and bind, 1.7× and 2.3× tsrs's; the five libraries every project parses (2.7× tsrs's symbols there) | Trig | 13 ms (11%) | **13 ms (34%)** |
| 4. Page faults beyond tsrs's, from 1.24-1.48× the footprint | Trig (data), Rig (Tables, prefault size) | 6 ms | 2.2 ms |
| 5. `munmap` and `mremap`: List growth and returned pages | Rig (allocator, List) | 7 ms | 1.9 ms |
| 6. The huge-page gate, shut at 5-69 free blocks | Rig | 4.9% when it opens (standing-3) | 1.5% (standing-3) |
| 7. Resolution hot spots: `resolve_external_module`, `check_collisions_for_declaration_name` | Trig | 11 ms | **9 ms (25%)** |
| 8. The allocator's own user time, `alloc` and `free` | Rig | 15 ms | 3 ms |
| 9. `std.file` through the blocking pool: `realpath` 2 ms of user time, 777 futex and 387 epoll calls | Rig (std.file) | not in the profile's top 40 | ~3 ms |
| 10. dTLB walks, 3.3-3.6× tsrs's | Rig (huge pages, layout) and Trig (data layout) | not split | not split |

Rows 1, 3 and 7 overlap with 4, 8 and 10: the page faults and the
allocator's time fall inside the phases.

- **Trig owns most of ts-pattern's gap** (row 1) and the head of zod3's
  (rows 3, 7).
- **Rig's largest lead is the kernel's memory work** (rows 2, 4, 5, 6):
  on ts-pattern `madvise` alone is 20 ms, as much as parse and bind; with
  `munmap`/`mremap` and the faults beyond tsrs's, 33 ms, 29% of the gap.
  Whether the prefaulted pages are ever touched was not measured.
- **Rig's user-side leads are small:** the allocator's 2.2% of user
  cycles, `realpath` and the blocking pool on zod3.
- **Peak memory** is 1.24× tsrs on ts-pattern, 1.48× on zod3 and 1.9× on
  the small projects, mostly the fixed cost of the libraries (Trig), and
  it rose since standing-3 on the small projects (row 4).

## Odd things

- ts-pattern's span from Trig's first write to its exit is 6.2 ms
  against tsrs's 1.6, but Trig writes its diagnostics as it formats them
  and tsrs once at the end (190 KB, one `write`), so the spans do not
  compare.
- The sampled profiles count fewer cycles than `perf stat` (49 samples
  of 10M on zod3 against 705M cycles), as in standing-3; their shares by
  kind and phase are what the tables use.
- `/usr/bin/time` measures `perf stat`'s child tree; perf itself peaks
  at about 17.5 MB, which the small projects' RSS clears.
