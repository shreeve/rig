# Gap map v2: Trig main against tsrs, by source function (2026-11-02)

Measured only. This replaces [gap-map.md](gap-map.md)'s family table, which grouped by
machine function and overstated instantiation by about 9 points.

**Setup**
- Trig main 16b97ae, built on pup by Rig 6750e8f (the pair the 12:26
  suite passed), against tsrs at /zfs/trig-pup/tsrs/bin/tsrs with
  `TSRS_LAZY_DTS=0 RAYON_NUM_THREADS=1 --checkerAssignment go --noLazyMembers`.
- One checker, pup E-core 13, perf on the other E-cores.
- Totals: the median of 5 `perf stat` runs of cpu_atom user cycles.
- Samples: `--call-graph lbr`, every 7M cycles; ts-pattern 12 runs and
  zod3 50 runs a binary.
- Families: item23's method (chains.py, fam2.py). Each sample is
  charged to the nearest named checker family on its inline chain and
  call stack.
- Script: `rec-v2.sh`. Tables: `fam2-v2.*.txt`. pup: `/tmp/gm2`.

**Totals:** user Mcycles a run.

| project | Trig | tsrs | gap |
|---|---:|---:|---:|
| ts-pattern | 4948 | 4540 | 8.2% of Trig |
| zod3 | 906 | 796 | 12.1% of Trig |

tsrs's ts-pattern total is 1.7% lower than item 23's 4618, with the same
binary and flags. The cause was not checked.

Sampling error on one family is about ±0.7% of Trig's cycles.

## Families 1% or more behind

| family | ts-pattern | zod3 | calls or cost per call |
|---|---:|---:|---|
| relations | 3.8% | 1.5% | cost per call: `relation_get`/`relation_set` 129 Mcycles, which tsrs inlines into `recursive_type_related_to`; `get_relation_key` 38 / 8.5. Item 21's u64 key was level |
| members/properties | 2.8% | 3.0% | cost per call for `is_static_private_identifier_property` (54 / 15) and `get_named_members` (161 / 131), whose counts match. `get_property_of_type_ex` + `get_apparent_type` (inclusive 228 / 27 and 163 / 23) is unknown: 8× inclusive suggests more calls, which needs a counter |
| types from nodes | 1.4% | 2.9% | cost per call: `type_node_links_outer_type_parameters` (a Map probe, 71 / 0) and `type_node_links_resolved_type` (28 / 0), item 23's lever 2; `get_type_of_parameter` 34 / 15 |
| checking/diagnostics | (0.5% ahead) | 5.4% | probably cost per call: `resolve_name_or_report_cannot_find` 28 / 0, with `check_identifier` inclusive 97 / 55. Name resolution per identifier; not counted |
| runtime/std, outside any family | 0.5% | 2.2% | cost per call (maps, hash, interner) in code with no named checker frame; not broken down further |
| flow/narrowing | (0.8% ahead) | 1.6% | probably calls: `narrow_type_by_binary_expression` inclusive 19 / 2 and `get_type_at_flow_assignment` 12 / 3. Needs counters |

Ahead of tsrs, or within the error:
- instantiate/mappers: 0.9% behind on ts-pattern, 3.2% ahead on zod3.
  Its calls match tsrs within 0.1% ([four-checkers/data/counts.md](four-checkers/data/counts.md)).
- inference, unions/intersections, lex, parse, bind, alloc.

The tables of top functions come from top.py, run on pup in /tmp/gm2.

## What came of it (2026-11-02, Rig - Rust)

- relations: closed level. A HashMap cache key and inline probe gave nothing; the
  probe path is only 0.4% behind. The rest is sort comparators (1.0%),
  is_related_to_ex, the Relater and get_relation_key (beat-tsrs item 24).
- Store-forward blocked loads: about 1 cycle each; the Relater ceiling removed
  38-49% of them for no cycles (item 26). Their classes on ts-pattern: the
  Relater `pop() ?? Relater()` copying 232 bytes four times 29%, small objects
  built field by field and read whole about 15%, small arguments in memory read
  whole at entry about 12%.
- compare_types counter (who sorts, how often, repeats): unfinished,
  ../ct-count-handoff.md.
- zod3 diagnostics, get_property_of_type_ex and narrowing counters: Merges' leads,
  ../merges-handoff.md.
