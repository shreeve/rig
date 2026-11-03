# Per-call gap: unions, intersections, inference (2026-11-02)

Item 16a's question: why Trig builds unions 180% and intersections 95%
more expensively per call than tsrs, and inference about 2×
(inclusive.md, LBR stacks). Measured only; counts and samples, no
timing.

## Method

- ts-pattern, one checker (`--singleThreaded`). Cycles sampled on E-core
  14 (`cpu_atom/cycles/u`, period 3,000,017), 10 runs each:
  - Trig without the union cache (`/tmp/uc/m`, Trig fb60a18) and with it
    (`/tmp/uc/u`, trig#242);
  - tsrs local (`/tmp/selfp/tsrs`, `--noLazyMembers`, Go assignment).
- Each sample is attributed through its whole inline chain
  (`addr2line -i`). tsrs is position-independent, so each run's
  addresses are rebased by its own text mapping first.
- Groups, by any frame in the chain: union construction (`get_union_type_*`,
  `add_types_to_union`, `get_union_type_from_sorted_list`,
  `remove_*`, the front cache), with `compare_types` split out wherever
  it appears; intersection construction; inference (by outer
  function).
- Callers of `compare_types`: LBR call stacks on P-core 6, 6 runs of
  `u`, 60 samples in `compare_types`.
- Data and scripts (`u.py`, `cmp.py`): pup `/zfs/worktrees/rig-rust-ports/pc/`.

Union call counts are equal (Trig 153,506 calls of two or more inputs,
tsrs 156,389; union.md), so samples compare per call directly.

## Samples (10 runs each; Trig 13,929 or 13,988 in all, tsrs 12,493)

| | Trig | Trig with union cache | tsrs | Trig with cache / tsrs |
|---|---:|---:|---:|---:|
| union construction, `compare_types` apart | 281 | 239 | 212 | 1.13 |
| `compare_types`, every caller | 162 | 147 | 45 | 3.3 |
| intersection construction | 157 | 165 | 75 | 2.2 |
| inference (outer function) | 350 | 352 | 209 | 1.7 |

As shares of each program's cycles: union 2.02%, 1.71% and 1.70%;
`compare_types` 1.16%, 1.05% and 0.36%; intersection 1.13%, 1.18% and
0.60%; inference 2.51%, 2.52% and 1.67%.

## Findings

1. **Unions are level per call once the front cache is in.** The 180%
   was inclusive (LBR stacks charge callees, `compare_types` among
   them) and without tsrs's cache, which answers 73% of calls. With
   trig#242, union construction itself is 13% above tsrs (27 samples,
   0.19% of cycles). The cache's probe costs about what it saves, which
   is why trig#242 saved instructions and no time.
2. **`compare_types` is the union gap that remains: 3.3× tsrs, 0.73% of
   cycles.** Its callers (60 LBR samples):
   - **half from the union worker's sort.** `sort.sort_by(!types,
     |?@, a, b| @compare_types(a, b) < 0)` takes the comparator as a
     run-time `FnRef`, so each comparison is an indirect call through a
     thunk, and `compare_types` cannot inline its first tests (`t1 ==
     t2`, the flag order) into the sort. tsrs's sort takes a generic
     closure (inlined), and tsrs has `compare_types_same_flags`, a fast
     path for two types of equal flags;
   - 23% from `compare_types` recursing (`compare_type_lists`,
     `compare_type_mappers`);
   - 18% from `type_related_to_some_type` (`contains_type`'s binary
     search on a union's members).
3. **Intersections: the same calls, twice the cost.** Counts are
   identical (union.md: 213k against 216k calls, table hits
   55,895 against 58,505). The excess is the probe of the
   `intersection_types` Ordered map: a large intern table whose tag
   group misses (union.md's self time). 0.64% of cycles.
4. **Inference: 1.7× by outer function, 1.0% of cycles,** not yet broken
   down. union.md found its own code level in self time (2.5% against
   2.2%), so the excess is what inference inlines: instantiation and
   mapper calls (inflation.md's `instantiate_type_with_alias` and
   `mapper_map`).

## Fixes and reach (ts-pattern, one checker, cycles; upper bounds)

| fix | where | reach |
|---|---|---:|
| A sort whose comparator is known at compile time, inlined (a closure literal handed to `sort_by` instantiated, not passed as `FnRef`), plus tsrs's same-flags fast path in `compare_types` | Rig std sort and emit; Trig `utilities.rig` | 0.3–0.5% |
| The intersection intern probe (Map layout, or tsrs's packed slot for intern tables) | Rig Map, or Trig | up to 0.6% |
| Inference: break down by inlined callee first | measurement | up to 1.0% |
| The union cache (trig#242) stacked with the sort fix | Trig | 0.2% |

Together about 2.1–2.3% of cycles, of Trig's 12% more cycles than
tsrs here.

## Inference by inlined callee (same samples, `u` against tsrs)

Inference (samples whose outer function is an `infer_*`,
`get_inferred_type` or `create_inference*`) is 353 samples in Trig and
209 in tsrs, 144 more (1.03% of Trig's cycles).

By outer function: `infer_from_types` with `infer_from_object_types`
177 against tsrs's 100 (tsrs inlines the second into the first);
`get_inferred_type` 50 against 53 (level); `infer_types` 41 against
20; `infer_type_arguments`, `infer_to_conditional_type`,
`infer_from_matching_types`, `infer_from_index_types` 45 against
about 11.

By innermost frame, Trig's 353:
- inference's own lines 166 (tsrs 203, with its table reads inlined
  as plain pointer loads, so they leave no frame);
- Table reads 58 (`Table.at`/`constSlot`: a type record by id, with
  its bounds check);
- checks and runtime 31: yield checks (`turn`) 10, proven-offset
  helpers 9, `FnRef` thunks 6, `heldBytes` 4, and others;
- small type predicates 40 (`type_target`, `is_literal_type`,
  `interface_type_parameters`, `is_tuple_type`, ...). These are
  inlined (emitted `inline fn`); the samples are their lines inside
  inference, not calls;
- Map probes 19, List pushes 13.

**Reading:** inference has no algorithmic excess of its own. Its own
lines plus table reads (224) are near tsrs's 203. The excess is the
general code-generation cost: id lookups with bounds checks, yield
checks, and indirect calls. (The predicates are inlined: see
inline-preds.md.) That is
codegen-gap's class (checks 5.9% of all cycles) and typed table ids
(beat-tsrs item 5), not an inference fix. **Reach:** no inference-only
fix. Typed ids and packed objects cover it, about 0.5–0.7% of cycles
here, inside their own estimates.
