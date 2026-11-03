# Union, intersection and inference: counted (2026-11-01)

Follow-up to `inclusive.md`, which found Trig's cost per call against
tsrs at 180% more for union construction, 95% more for intersections and
about 2× for inference, from LBR stacks. Measured only; nothing was built.

## Method

- **Self time.** ts-pattern at one checker, `--singleThreaded`, E-core 14:
  - Trig plain (`ck0/trig-plain`, Trig 806e0a1);
  - tsrs local (0.18.0, fat LTO, symbols), with `--noLazyMembers`.

  16 runs each, cycles and instructions sampled at 8M (the kernel caps
  sampling at 1,000/s). Self time has no LBR-depth or tail-call limit.
- **Counts.** Counters in both counting copies at one checker:
  - Trig: patched in its emitted Zig (`uck/patch_uck.py`, from `ck0/out`).
  - tsrs: CK0 indices 83–99 (`uck/patch_uck_tsrs.py`), built on pup in
    `/zfs/worktrees/rig-rust-ports/uck`.
- **tsrs's own caches.** Shipped tsrs, ts-pattern at one checker,
  instructions, once with each `TSRS_*` cache switch off.

## What tsrs's own caches are worth on ts-pattern (shipped, one checker)

| switch off | instructions, change from default |
|---|---:|
| `TSRS_UNION_CACHE` (union front cache) | +56.1M (0.8%) |
| `TSRS_INFER_MEMO` (generic-call inference memo) | +3.2M (0.05%) |
| `TSRS_IA_MEMO`, `TSRS_FLOW_MEMO` | about 0 |
| `TSRS_LAZY_MEMBERS` | +269M (3.9%) |

## Self time (share of cycles, one checker)

| path | Trig | tsrs |
|---|---:|---:|
| union construction | 3.3% | 2.1% |
| …of which `compare_types` | 0.91% | 0.15% |
| intersection construction | 1.4% | 0.8% |
| inference | 2.5% | 2.2% |

- **Inference is about level** in its own code. Its "2×" inclusive cost is
  the unions and intersections it calls, plus LBR attribution.
- **The intern tables.** Half of `get_intersection_type_ex`'s cycles, and
  over half of `get_union_type_from_sorted_list`'s, are the probe of the
  `intersection_types` / `union_types` Ordered map. The hot line is the
  tag-group load, a cache miss.

## Counts (ts-pattern, one checker)

Trig checks three more lib files, so expect 1–2% more calls.

| count | Trig | tsrs |
|---|---:|---:|
| `get_union_type_ex` calls | 253,781 | 257,557 |
| …with 2+ inputs | 153,506 | 156,389 |
| …front cache hits | – | 111,166 (73%) |
| union-of-union lookups / hits | 24,158 / 16,605 | 9,001 / 1,448 |
| union worker calls | 136,901 | 43,775 |
| comparisons while ordering a union | 934,324 | 383,488 |
| …per ordering call | 8.1 | 8.8 |
| `union_types` lookups / hits | 86,499 / 56,117 | 38,479 / 8,196 |
| `remove_subtypes` calls | 931 | 521 |
| `compare_types` calls, all | 1,616,596 | 592,826 |
| intersection calls | 213,401 | 216,223 |
| intersection table lookups / hits | 116,764 / 55,895 | 119,350 / 58,505 |
| intersection set size, sum | 241,668 | 246,840 |

## Cause

- **Unions: extra work.** tsrs answers 73% of union calls from its front
  cache, so Trig runs 3.1× the worker calls:
  - 2.4× the comparisons while ordering;
  - 2.2× the `union_types` probes;
  - and the other worker calls to `compare_types`: binary-search inserts
    for origins, and literal reduction.

  tsrs's run merging, credited to TypeScript's `perf/checker-speedups-v3`,
  saves nothing here: it makes as many comparisons per call as Trig's
  full sort.
- **Intersections: costlier work.** The counts are identical. The extra
  cycles are the probe of the intersection intern table, a miss on the
  Ordered map's tag group.
- **Inference:** no fix of its own (see self time). tsrs's inference memo
  is worth 0.05% on ts-pattern.

## Fix shape (for the owner)

1. **Port tsrs's union front cache to Trig, exactly** (`unioncache.rs`;
   notes/perf-union-inference.md).
   - **Probe:** before any other work, `get_union_type_ex` with 2+ inputs
     and no origin probes a direct-mapped table: 2^10 slots per checker,
     about 40 KB.
   - **Key:** the inputs in order, the reduction, and an alias's symbol and
     type arguments; at most 8 words.
   - **Store** a miss's answer only if the call:
     - created no type, or only the union it returns;
     - instantiated nothing;
     - took neither impure reduction (string literals matched by templates,
       or constrained type variables);
     - and did not return `errorType`.

     Under those conditions a hit is the uncached answer.
   - **Shadow mode** recomputes at each hit and panics on a difference,
     for Trig's suites.
   - **Files:** constructors.rig (`get_union_type_ex`, the two impure
     reductions) and a Checker field. None of Helper's caches.
   - **Expected:** worker calls on ts-pattern fall from about 137k to about
     44k. Estimate: about 1.5% fewer cycles at one checker. tsrs measured
     0.8% fewer instructions for itself, and Trig's uncached path costs
     about twice tsrs's per call. Measure with time-ab.sh and an A/A arm.
2. **Not now:**
   - run merging, which saves no comparisons on ts-pattern;
   - an inline fast path in `compare_types`, since its calls fall about
     2.4× with item 1. Re-measure after 1.
3. **Intersections:** no Trig-side change. The gap, about 0.6% of cycles,
   is the Ordered map's probe on a large intern table. That is a Map
   layout question, to raise with whoever owns Map speed.

Scratch:
- Mac: `scratchpad/uck/` of Rig - Rust (fork): patches, the build, `trig-uck.txt`.
- pup: `/tmp/selfp` (profiles) and `/zfs/worktrees/rig-rust-ports/uck`.

## Lead: what tsrs's lazy members do that Trig's port did not

Shipped tsrs, ts-pattern, one checker, instructions, one switch off at a
time:

| switch off | change from default |
|---|---:|
| `TSRS_LAZY_MEMBERS` (all of it) | +269M (3.9%) |
| `TSRS_LAZY_TUPLES` (L1, tuple references lazy too) | +357M (5.2%) |
| `TSRS_LAZY_COND_MAPPER` (L5) | +23M |
| `TSRS_LAZY_PROP_CACHE` (L6) | +21M |
| `TSRS_LAZY_EMPTY`, `TSRS_LAZY_INFERENCE_MAPPERS` | +3M each |
| `TSRS_LAZY_UNMATCHED` (L10) | −255M (fewer with it off) |

- **tsrs's switch is more than Trig's port.** It covers #64475
  (classes and interfaces), #64526 (`keyof` mapped types) and follow-ups
  L1, L5, L6, L10 and others (tsrs notes/mem-lazy.md). Trig's removed
  port (docs/research/12-lazy-members, trig#172/#173) was #64475 alone,
  and it measured ts-pattern 0.7% slower. Trig already has L5, as its own
  divergence.
- **L1 is the piece that matters on ts-pattern.** tsrs's notes say most of
  the members it makes are tuples' `Array<E>` base: about 40 members,
  rebuilt for each tuple. L1 is a one-line condition change on top of
  #64475. With L1 off and the rest on, tsrs runs more instructions than
  with everything off.
- **The lead:** #64475 with L1, and perhaps L10 for the cases it helps,
  measured on ts-pattern. Restoring lazy members is the owner's call; he
  removed them on 2026-10-21. These are counts of instructions, not time.
