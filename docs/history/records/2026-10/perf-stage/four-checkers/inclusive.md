# Checker 0, inclusive per-call map: Trig against tsrs (2026-11-01)

Follow-up to `checker0.md`. Two questions:
- Where does Trig's per-call excess on ts-pattern's heaviest checker
  concentrate?
- How much of it sits in ordered-Map operations (the relation cache,
  `instantiations`, the active-mapper caches), as against the algorithms
  around them?

Measurement only: no tracked checkout was edited. Scratch:
- [data/](data/): `patch2.py`, `cgana.py`, `incl_table.py`,
  `incl_table.txt` and `trig-assign.txt`; the counts `ts4b.out` and
  `tsrs4f.out` are on pup in `/zfs/trig-pup/records-data/four-checkers/ck0/`.
- pup: `/zfs/worktrees/rig/four-checkers/ck0/`: `cg/` (LBR recordings,
  chains, leaf files), `asg/` and `asg2/` (assignment runs).

## First, a correction: the two tools split the files differently

`inflation.md` and `checker0.md` compared Trig's heaviest checker with
tsrs's under `--checkerAssignment go`, assuming both made Go's split. They
don't:
- Trig's program has 172 files and tsrs 0.18.0's has 169. Trig bundles
  three lib files tsrs doesn't: `lib.esnext.iterator.d.ts`,
  `lib.esnext.promise.d.ts` and `lib.esnext.modulesource.d.ts`.
- Go's split weighs every file, so the source files land on different
  checkers.
- Per-thread counters (tsrs's counting copy now counts per thread) show
  tsrs's own checker 0 making 6% fewer instantiation calls, 13% fewer
  `is_related_to` calls and 9% fewer `get_type_of_symbol` calls than
  Trig's.

tsrs can take a file of assignments (`--checkerAssignment file:PATH`).
Given Trig's split (`trig-assign.txt`, mapped by file name):
- **Counts.** tsrs's checker 0 makes Trig's checker 0's calls to within 1%
  on every counter. Outputs are identical.
- **Instructions.** Shipped tsrs's heaviest checker executes 2.75G
  instructions with Trig's split, against 2.45G with its own.

With the same files, Trig PGO's checker 0 executes about 10% more
instructions than shipped tsrs's, not 26%. Ranks 2-4 are about 10% more
too. **The checker-0-specific excess in `checker0.md` was the split, not
code.**

What the split costs tsrs in wall time is small. Check time at four
checkers on E-cores 16-19, 8 alternated rounds, medians:

| | Check time |
|---|---:|
| Trig PGO | 535.5 ms |
| tsrs shipped, its own split | 438.5 ms |
| tsrs shipped, Trig's split | 446 ms |

With the same files, per-thread user cycles (sampled) for checkers 2-4
are 15% more for Trig than for shipped tsrs. Checker 0 is about 13% more
after taking out Trig's head and tail on that thread. So Trig's gap at
four is its general single-thread gap, spread evenly over the checkers,
plus 1.7% for the split.

## Method

- **Builds.**
  - Trig plain (`trig-plain-x86`, no PGO).
  - Trig PGO (standing-6 `trig/bin`).
  - tsrs local: 0.18.0, fat LTO, no PGO or BOLT, with symbols and
    debug info.
  - tsrs shipped is stripped, so it gives only totals.
- **Runs.** ts-pattern at four checkers on E-cores 16-19, with Trig's
  split for tsrs. 6 runs per binary, `perf record --call-graph lbr`,
  sampling user cycles and user instructions.
- **Attribution.** Checker 0 is the thread with the most instructions,
  and for Trig only its checking window counts. Inline frames come from
  `perf script`. A sample counts once toward each operation present in
  its chain.
- **Hash-table time** is a sample whose leaf instruction lies in
  hash-table source: for Trig `ordered.zig` or `unordered.zig`; for tsrs
  hashbrown, `packedmap.rs`, `basedmap.rs`, rustc-hash, indexmap or SSE2
  intrinsics. The leaf source comes from `--full-source-path`. Each such
  sample is owned by the relation cache when a relation-cache frame is
  near the leaf, else by the nearest operation in the chain.
- **Call counts** for the per-call figures come from the counting copies:
  Trig's checker 0, and tsrs's checker 0 under Trig's split.
- **Scaling.** Sampled totals are scaled to exact `perf stat` totals of
  the same binary and command. About 1,000 cycle samples and 1,300
  instruction samples per binary land on checker 0. A 50% share is good to
  about ±3%; a 5% share to about ±20%.

### Limits of the inclusive numbers

- **LBR keeps the innermost 32 calls only.** Operations near the root of
  deep relation and instantiation recursion lose samples, and lose them
  differently in each build, since each build inlines different calls.
- **Tail calls leave no frame.** tsrs's `get_type_of_symbol` shows 5M
  inclusive cycles against Trig's 609M, which can only be a missing frame.
  `get_type_of_symbol` is therefore not comparable.
- **`TypeMapper::map` can't be told from iterator `map` frames** in tsrs's
  inline names, so `mapper_map` is not compared.
- **Property lookup** is counted through different entry points in the two
  tools (Trig counts 2.2 times as many calls to its `get_property_of_type_ex`),
  so only inclusive totals are given for it.

## Inclusive cost per call on checker 0 (E-cores, same files)

| operation | calls, Trig / tsrs | Trig PGO cycles/call | Trig plain cycles/call | tsrs local cycles/call | Trig PGO against tsrs | Trig PGO inclusive | tsrs inclusive |
|---|---|---:|---:|---:|---:|---:|---:|
| checker 0, all | | | | | 5% fewer | 1,555M | 1,633M |
| relations (is_related_to, structured…) | 316,005 / 316,983 | 2,775 | 2,413 | 2,812 | 1% fewer | 877M | 891M |
| relation cache lookup | 281,978 / 284,087 | 182 | 213 | 150 | 22% more | 51M | 43M |
| instantiate_type_with_alias | 2,604,114 / 2,599,706 | 447 | 448 | 419 | 7% more | 1,164M | 1,090M |
| object / conditional / reference instantiation (`instantiations` map) | 591,126 / 591,064 | 1,880 | 1,846 | 1,775 | 6% more | 1,111M | 1,049M |
| resolve_structured_type_members (unresolved) | 63,485 / 63,437 | 3,453 | 3,925 | 4,477 | 23% fewer | 219M | 284M |
| get_signatures_of_type | 226,804 / 226,596 | 193 | 179 | 258 | 25% fewer | 44M | 58M |
| infer_types | 27,749 / 27,749 | 7,354 | 4,706 | 3,582 | 105% more | 204M | 99M |
| infer_from_types | 105,965 / 108,343 | 2,368 | 1,544 | 1,252 | 89% more | 251M | 136M |
| resolved signatures (resolve_call…) | | | | | 92% more (inclusive) | 236M | 123M |
| property lookup | | | | | 10% more (inclusive) | 128M | 117M |
| union construction (get_union_type_ex) | 83,653 / 85,942 | 1,337 | 754 | 477 | 180% more | 112M | 41M |
| intersection construction | 110,281 / 112,268 | 493 | 463 | 253 | 95% more | 54M | 28M |

Inclusive figures overlap: relations contain instantiation and the
reverse. Instructions per call are in `incl_table.txt`.

## Hash-table time on checker 0

Share of checker 0's samples with the leaf in hash-table code, and its
owners (cycles):

| | share of cycles | share of instructions | about | owners (share of checker 0's cycles) |
|---|---:|---:|---:|---|
| Trig PGO | 11.1% | 7.3% | 173M cycles | object/conditional/reference instantiation (`instantiations`) 3.8%; relation cache 2.0%; instantiate_type_with_alias (active-mapper caches) 1.4%; property lookup 1.1%; resolve members 0.8%; intersection 0.7% |
| Trig plain | 6.8% | 4.7% | 113M cycles | `instantiations` 1.8%; active-mapper caches 1.4%; relation cache 1.3%; property lookup 0.9% |
| tsrs local | 12.1% | 9.8% | 198M cycles | object/conditional/reference instantiation 5.4%; instantiation 2.0%; relation cache 1.4%; resolve members 1.0%; relations 1.0% |

Trig's ordered maps take about 170M cycles on checker 0, about 11% of it
in the PGO build. tsrs's unordered tables take as much or more (198M, 12%)
on the same calls. The three maps the question names take 7.2 points:
`instantiations` 3.8, the relation cache 2.0 and the active-mapper caches
1.4.

## Answers

1. **Where the per-call excess concentrates** (Trig PGO against tsrs local,
   same files and calls):
   - About level: relations (1% fewer per call), instantiation (6-7%
     more), relation cache (22% more per call, but only 8M cycles in all).
   - Trig is cheaper: member resolution (23% fewer) and signature lookup
     (25% fewer).
   - The excess concentrates in **inference**: `infer_types` 7.4K against
     3.6K cycles per call, `infer_from_types` 2.4K against 1.3K, about 115M
     cycles more inclusive.
   - And in **type construction**: unions 1.3K against 0.5K cycles per
     call, intersections 0.5K against 0.25K, about 100M cycles more.
     Resolved signatures show 113M more inclusive, overlapping inference.
   - Those three overlap: about 200-250M cycles of excess, which other
     areas offset.
   - Caveat: these are mid-level operations, open to the LBR-depth and
     tail-call limits above. Confirm with counted inclusive work before
     designing.
   - Against shipped tsrs, every checker is about 13-15% slower. That is
     uniform, and is the general single-thread gap (tsrs's PGO, BOLT and
     code), not a checker-0 effect.
2. **The ordered-Map share.** At most about 11% of checker 0's cycles
   (about 7% for the three named maps), and tsrs spends the same share in
   its own tables.
   - Replacing those three maps with packed HashMaps could save a fraction
     of 7%. If they became twice as fast: about 3.5% of checker 0, about
     8 ms of the check at four on P-cores and about 3% at one.
   - **Part 3 is not worth designing on this evidence.** A cheap A/B on
     the relation cache alone (the only map whose per-call cost exceeds
     tsrs's) would settle it.
3. **Next lead.**
   - Count the inference path (`infer_from_types` steps, `infer_types`
     candidates, the inference memo's replays) and the union path
     (`get_union_type_ex`: the input sizes, `remove_subtypes` and literal
     reduction calls, and cache hits for the origin and union keys) in
     both counting copies. These are the two places where Trig's
     inclusive cost per call is about twice tsrs's.
   - The split difference (three newer lib files) costs Trig 1.7% of check
     time at four.
