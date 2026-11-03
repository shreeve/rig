# Checker 0 on ts-pattern: why Trig's heaviest checker does more work than tsrs's (2026-11-01)

Follow-up to `inflation.md`. There, Trig's heaviest checker at four checkers
executed 26% more instructions than tsrs's, mostly in
`instantiate_type_with_alias` and `mapper_map`. This report asks why: more
calls, or costlier ones.

Measurement only: no repository was edited, committed or pushed. Scratch
and data:
- [data/](data/): `patch_trig.py`, `patch_tsrs.py` and `counts.md`; the
  counting outputs `ts1.out`, `ts4.out`, `tsrs1.out` and `tsrs4.out` are
  on pup in `/zfs/trig-pup/records-data/four-checkers/ck0/`.
- pup: `/zfs/worktrees/rig/four-checkers/ck0/`: profiles `pgo4.*`,
  `plain4.*`, `tsrssym4.*` and `tsrssym1.*`, and the scripts `ck0syms.py`,
  `groups.py`, `cmp3.py`, `other.py` and `ranks2.py`.

## Builds used

| name | what | where |
|---|---|---|
| Trig PGO | standing-6's `trig/bin` (Trig 806e0a1, PGO by Rig 928b44bf2), the benchmark binary | pup |
| Trig plain | the same source, emitted by Rig 928b44bf2 and compiled `-Osafe` for meteorlake, as `rig build --release` does, with no PGO | `ck0/plain/trig-plain-x86`, copied to pup |
| Trig counting | the same source with counters (`patch_trig.py`), native release build on the Mac | `ck0/trig-ck` |
| tsrs shipped | 0.18.0 from npm: fat LTO, PGO trained on the conformance suite plus xstate and webpack, then BOLT (`notes/perf-pgo.md`, `release.yml`) | pup |
| tsrs local | the same 0.18.0 source, release profile (fat LTO, one codegen unit), no PGO or BOLT, with symbols | pup `/zfs/trig-pup/tsrs/bin/tsrs` (built Oct 20) |
| tsrs counting | the same source with the same counters (`patch_tsrs.py`), `dev` profile | pup `ck0/tsrs-target/debug/tsrs` |

The counting builds print the same diagnostics as the shipped binaries (checked
for tsrs; Trig's counters only add `CK0` lines). Trig plain prints Trig
PGO's bytes. Profiles ran on E-cores 16-19 (four checkers) or 18 (one), 8
runs each, and recorded user instructions and user cycles. Sampled shares
are scaled to each binary's exact `perf stat` totals. **E-core cycle
numbers are relative.**

## 1. Checker 0's files

Go's split at four checkers, printed by the counting build (`CK0FILE`
lines in `ts4.out`), gives checker 0 sixteen checked files:
- `src/types/ExtractPreciseValue.ts`, `src/types/FindSelected.ts`,
  `src/is-matching.ts`, `src/patterns.ts`;
- tests `chainable`, `distribute-unions`, `find-selected`, `is-matching`,
  `large-exhaustive`, `primitive-values`, `primitive-with-overload`,
  `real-world`, `type-error-messages`, `type-is-matching`, `when`;
- `tests/types-catalog/definition.ts`.

Checkers 1, 2 and 3 check 27, 18 and 11 files.

Checker 0 holds ts-pattern's type-level code and the tests that use it the
hardest. It makes 54% of all `mapper_map` calls (8.5M of 15.8M) and 43% of
all instantiation calls (2.6M of 6.0M), against a quarter of the files.
That is why those two functions dominate it. It is a property of the
program and of Go's split, not of Trig.

Isolating those files in their own tsconfig was not useful: their imports
pull in most of `src/`, which would also be checked. So checker 0 is
measured as the heaviest thread of a four-checker run, inside its checking
window.

## 2. Trig makes the same calls as tsrs

Same counters in both, whole ts-pattern (`counts.md` has every row):

| counter | Trig, 1 checker | tsrs, 1 checker |
|---|---:|---:|
| instantiate_type_with_alias calls | 5,811,725 | 5,798,375 |
| … returns, no type variables | 1,774,926 | 1,774,871 |
| … active-mapper cache hits | 380,161 | 380,171 |
| … misses, new mapper pushed | 1,713,801 | 1,713,592 |
| … misses, active mapper | 1,925,107 | 1,925,108 |
| find_active_mapper steps | 10,627,253 | 10,627,155 |
| entries cleared at pop | 1,750,218 | 1,750,219 |
| mapper_map Simple / Array / Merged | 4,735,938 / 5,108,376 / 2,064,772 | 4,735,830 / 5,107,941 / 2,064,768 |
| Array mapper sources scanned | 24,997,871 | 24,996,233 |
| object instantiation hits / misses | 405,437 / 202,584 | 405,439 / 202,502 |
| conditional instantiation lookups / hits | 307,257 / 154,281 | 307,257 / 154,281 |
| type reference lookups / hits | 290,352 / 228,018 | 290,381 / 228,144 |
| instantiate_types calls / elements | 638,070 / 1,174,879 | 638,057 / 1,174,854 |

Every path, cache hit rate, mapper chain and stack walk matches within
0.03%. There are two exceptions, both cheap:
- 13K more calls with no mapper, each of which returns at once.
- 430K fewer Composite `mapper_map` calls. Trig's conditional path maps
  through `composite_mapper_map` without calling `mapper_map`.

**Trig makes no extra calls.** No cache is missing, none is keyed
differently in effect, and no mapper is built where tsrs's is lazy. The
difference is the cost of each call.

## 3. Where checker 0's cost differs

Checker 0, inside its checking window, at four checkers (E-cores, 8 runs
each):

| | instructions | user cycles |
|---|---:|---:|
| Trig plain | 3.44G | 1.75G |
| Trig PGO | 3.02G | 1.57G |
| tsrs local (no PGO or BOLT) | 2.80G | 1.61G |
| tsrs shipped (PGO and BOLT; `inflation.md`) | about 2.48G | about 1.35G |

Checkers 2-4 together, for comparison: Trig plain 5.74G instructions and
3.66G cycles; tsrs local 5.62G and 3.63G (2% and 1% more). Trig PGO 5.11G
and 3.35G; tsrs shipped 4.98G and 3.13G (3% and 7% more).

The 16% more cycles Trig spends on checker 0 than shipped tsrs has two parts:
1. **Code, about 8.5%, and only on checker 0.** With neither side built
   with PGO, Trig's checker 0 executes 23% more instructions and takes 8.5%
   more cycles than tsrs's. Its other three checkers are level with tsrs's
   (1% more cycles).
2. **Build, about 7%, on every checker.** tsrs's release pipeline takes
   16.4% off its checker 0's cycles and 13.7% off the others'. Trig's PGO
   takes 10.5% off checker 0 and 9% off the whole program. Trig trains on
   mitt, neverthrow, superstruct and zod3, three times each, with
   ts-pattern held out, and has no BOLT step. tsrs trains on its whole
   conformance suite plus two large projects, then applies BOLT.

The two multiply: 1.085 × 0.895/0.836 = 1.16.

### Code: which groups (checker 0, cycles)

| group | Trig plain | Trig PGO | tsrs local |
|---|---:|---:|---:|
| instantiation (incl. inlined maps and keys) + hash tables | 480M | 459M | 473M |
| mappers | 126M | 119M | 140M |
| relations | 191M | 201M | 159M |
| type construction (conditional, intersection, normalize…) | 167M | 188M | 148M |
| inference | 48M | 73M | 26M |
| other (type nodes, generic flags, names…) | 330M | 211M | 208M |
| members, symbols, properties | 297M | 248M | 307M |
| allocation and copies | 46M | 37M | 84M |
| flow | 64M | 30M | 68M |

Groups are by function name. Inlining differs between builds, so
neighbouring groups trade samples.

- **Instantiation and mappers cost the same cycles as tsrs's**, although
  Trig executes more instructions there (788M against tsrs's roughly 600M
  for the same calls on checker 0, at higher IPC). Per call, `mapper_map`
  is 45 instructions in Trig and 47 in tsrs local. The lead was the right
  place to look, but these functions are hot because checker 0 does most
  of the instantiating. Trig does not do it worse.
- **Relations, inference and type construction carry the excess:** about
  130M cycles on checker 0 in the PGO build (8% of it). Concrete
  differences found by reading both:
  - **Recursion identities.** Trig's `is_deeply_nested_type`
    (relater.rig:73) is Go's: every walk calls
    `get_recursion_identity_target` and `has_matching_recursion_identity`
    again for each stack entry. tsrs (`relater_1.rs`,
    `is_deeply_nested_on_stack`) keeps each relater-stack entry's identity
    key once computed and compares words. On checker 0 those three Trig
    functions take 57M instructions and 31M cycles (2% of its cycles).
  - **The relation cache.** Trig keeps `relation_results:
    List[Map[CacheKey, U32]]`: insertion-ordered maps with a 16-byte key,
    an entry array and a tag index. tsrs's `Relation.pairs` is a hashbrown
    `HashTable<u64>` that packs the pair key and the result into one 8-byte
    slot. Ordered-map code inside `is_related_to_ex` is 1.7% of checker 0's
    cycles.
  - **Inference.** `infer_from_object_types` takes 39M cycles (84M
    instructions) on checker 0, against single-digit millions for tsrs's
    `invoke_once::<infer_from_object_types>`. That was not counted, so
    whether Trig makes more calls here is unknown.
- **Hash tables in the instantiation path.** Trig keeps one program-wide
  insertion-ordered `instantiations: Map[InstantiationKey, TypeId]` (158K
  entries on checker 0, 421K at one checker) plus a `has_instantiations`
  set. tsrs keeps a table per target: interface instantiations keyed by
  the type-argument slice, and per-target `PackedMap`s. Trig's
  active-mapper caches are ordered Maps whose `clear` at each of 1.7M pops
  also frees the index. Ordered-map code is 5.8% of checker 0's cycles,
  inside the instantiation blob. The instantiation group already matches
  tsrs's cycles, so the gain from changing this is probably small.

## Fix sketch and reach (ts-pattern; P-core ms scaled from E-core ratios)

The check at four is set by checker 0: 249 ms for Trig against 210 for
tsrs (audit).

1. **Build: give Trig's PGO tsrs's breadth, and stack BOLT on it.** Owner:
   Trig, `tools/trig/bolt-train` and `tools/trig/pgo`; Rig's
   `rig build --pgo` and `--bolt` already exist.
   - Train on Trig's checker conformance corpus (as tsrs trains on its
     suite) plus generic-heavy projects outside the benchmark set (immer
     and dify are in `misc/projects`), then lay the binary out with BOLT.
   - Reach if Trig's gain on checker 0 rose from 10.5% to tsrs's 16%:
     about 6% of checker 0, about 15 ms at four. Assuming the same gain
     across the program at one checker, about 40 ms of the 683 ms check.
   - Confidence: medium that the build gap is real (both sides measured
     with and without), low on how much better training recovers.
   - Cheapest test: a PGO build that includes ts-pattern in training. Its
     in-sample result is an upper bound.
2. **Code on checker 0's kind of work (Trig's checker).**
   - Keep each relater-stack entry's recursion identity, as tsrs does:
     about 2% of checker 0, about 5 ms at four, about 1% at one.
   - Count `infer_from_object_types` calls in both, as here, before
     changing anything: up to about 2% of checker 0.
   - Move the hot caches that nothing reads in order to `HashMap` or a
     packed u64 table: the relation results, `instantiations`, the
     active-mapper caches. Up to 2-3% of checker 0, about 5-7 ms at four.
     This needs an A/B; bench/hash's guard shows HashMap only modestly
     cheaper per operation (pair-hit 43 against 56 instructions).
   - Together, about 5-6% of checker 0: about 12-15 ms at four, about 3% at
     one.
3. **Nothing to fix in instantiation logic.** Calls, cache hit rates and
   mapper chains are tsrs's exactly.

Total reach of 1 and 2: about 25-30 ms of the 39 ms check gap at four. The
rest is the per-checker kernel work in `inflation.md`.

## Follow-up (Rig - Merges, 2026-11-01): part 1, recursion identities kept per stack entry

Built and measured; not worth taking. Trig a8f30d8 with each relater and inference stack entry's recursion identity kept once computed (`is_deeply_nested_on`, a `RecursionEntry` list beside each stack, reused only while the stack holds the same type). Outputs were identical on all six projects at 1 and 4 checkers. On ts-pattern at one checker, native Mac release, fewest of 5 interleaved runs: 9.645G against 9.649G instructions (0.04% more), cycles within noise. Recomputing an identity costs about what keeping it does, so the change is dropped. Patch: four-checkers/recid/recid.patch.

## Follow-up: part 2, infer_from_object_types call counts

Counting copies on ts-pattern at one checker (Trig 806e0a1 on the Mac; tsrs 0.18.0 dev build on pup):

| counter | Trig | tsrs |
|---|---:|---:|
| invoke_once calls | 131,203 | 119,162 |
| visited hits | 5,284 | 6,111 |
| infer_from_object_types calls | 92,531 | 96,473 |

Trig makes 4% fewer calls to infer_from_object_types. tsrs keys `visited` by source and target only, while Trig keys it as Go does (with priority and variance), so tsrs gets slightly more hits. Calls are not the cause. The 39M cycles against tsrs's few million is self time, and the two compilers inline different callees into it (Trig inlines its property and signature inference), so self time doesn't compare. An inclusive comparison, with call graphs on both, would be the next step if it's worth one.

## Queued: the program's `files` store (from Rig - Helper, 2026-11-01)

`files` is a `List[File]` in src/compiler/program.rig, indexed by `NodeRef.file - 1`, and read at 1,393 of the 2,110 hot id sites in Trig's emitted code. Helper's typed-id builder leaves it out and will send its ceiling share (arm `hotF` against `hotA`). A File owns memory, so a `Table[File, n]` would construct all n slots at the start; a separate index table, or bounded ids, may suit it better. Design only once the ceiling share is in.
Helper's ceiling for `files` (Mac, Trig e62ec3c, unchecked arms, one checker): on top of phase A's hot stores it adds only 0.15% fewer instructions on ts-pattern and 0.39% on zod3. That's under the bar despite its 1,393 sites, so it's not designed. Dropped.
