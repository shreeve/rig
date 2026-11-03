# Beat-tsrs item 23: instantiation and members against tsrs (2026-11-02)

Measured only. This compares the gap map's binaries: Trig 07e4447 + #244
at /tmp/lp4/n, and tsrs 0.18.0 shipped (which has debug info).

**Setup**
- pup E-core 13, one checker, the gap map's flags.
- `perf record --call-graph lbr`, cycles every 7M. ts-pattern 12 runs
  and zod3 50 runs a binary: 7,609 / 7,260 and 5,524 / 5,209 samples.
- Mcycles are scaled to the gap map's perf stat totals.
- Scripts: `rec.sh`; `chains.py`, which gives each frame its inline
  chain through nm and addr2line, and each source function its crate
  from its file; `fam2.py`; `top.py`.
- Outputs: `fam2.txt` (in [instantiation-members-data/](instantiation-members-data/)); the
  `*.fam2.json` files are on pup in `/zfs/trig-pup/records-data/item23/`.

## 1. fam.py fixed; the families recomputed

With the crate rule ([gap-map.md](gap-map.md), "Correction"), the gaps by
**machine function** are:
- instantiate/mappers: 9.5% of Trig's cycles on ts-pattern, 2.5% on zod3;
- members/properties: 5.0% / 5.1%.

Machine functions still mislead, because the two builds inline
differently. tsrs's "ast" and "program" families absorb inlined checker
code (430 and 358 Mcycles of source-self on ts-pattern, against Trig's
125 and 14).

**By source function, nearest named family:** each sample walks out from
its leaf, through inline frames and the call stack, to the first frame
in a named checker family. Library code and inlined accessors then count
toward the family they serve, the same way in both builds.

| family | ts-pattern Trig / tsrs | gap, % of Trig | zod3 Trig / tsrs | gap, % of Trig |
|---|---:|---:|---:|---:|
| instantiate/mappers | 1718 / 1751 | **0.7% ahead** | 144 / 168 | **2.6% ahead** |
| members/properties | 877 / 725 | **3.1% behind** | 189 / 153 | **3.9% behind** |
| relations | 780 / 612 | 3.4% behind | 143 / 130 | 1.3% behind |
| inference | 306 / 228 | 1.6% behind | 27 / 28 | level |
| types from nodes | 393 / 328 | 1.3% behind | 82 / 63 | 2.0% behind |
| checking/diagnostics | 257 / 305 | 1.0% ahead | 142 / 109 | 3.6% behind |

Sampling error on a family's gap is about ±0.7% of Trig's cycles.

## 2. Calls: the same

The counting copies ([four-checkers/data/counts.md](four-checkers/data/counts.md), ts-pattern, one
checker) give Trig's calls and tsrs's, within 0.1% on most counters:

| counter | Trig | tsrs |
|---|---:|---:|
| instantiate_type_with_alias | 5,811,725 | 5,798,375 |
| active-cache hits | 380,161 | 380,171 |
| object instantiations (hits) | 825,302 (405,437) | 825,222 (405,439) |
| resolve_structured_type_members_worker | 177,413 | 177,365 |
| get_signatures_of_type | 679,305 | 682,904 |
| get_type_of_symbol | 1,576,273 | 1,575,540 |

No cache is missed and nothing is resolved again. The gaps are cost per
call, in a few functions.

## 3. Where the cost per call is (ts-pattern, Mcycles, Trig / tsrs)

**Members, per member:**
- `get_named_members` 163 / 130, which includes `sort_symbols_by_key`:
  each key reads `files[f - 1].ast.pos`.
- `is_static_private_identifier_property` 55 / 15. It is called for
  every property by `get_unmatched_properties_worker` and
  `add_inherited_members`, and makes 1.0% of all sampled calls. Each call
  goes symbol → value declaration → `files[f - 1].ast` → node kind,
  name kind, modifiers.
- `is_reserved_member_name` 25 / 2.5. Each call fetches the atom's text
  through `Checker.text`, which reads two interners and their `ends`.
- `is_named_member` 23 / 4.

Together: 266 / 151, which is +115 (2.3% of Trig). On zod3: 56.5 / 38,
which is +18.5 (2.0%).

**Outer type parameters in a Map:**
`get_object_type_instantiation` reads
`type_node_links_outer_type_parameters(declaration)` on each of its
825k calls. Since a5b38c9 (trig#233), that field lives in the ordered
Map `type_node_links_extras`, so each read is a probe at about 80 cycles.
- ts-pattern: 65.8 Mcycles inclusive (1.3%).
- zod3: 6.4 Mcycles (0.7%).
- tsrs has no such cost.

`type_node_links_resolved_type`, a Table read, adds 26.7 Mcycles of
cache misses on ts-pattern.

## Levers (Trig's code)

1. **Per-member checks, ts-pattern up to 2.3%, zod3 up to 2.0%.** Answer
   them from bits rather than text and the AST:
   - a reserved-name bit for each atom, set when it is interned;
   - a static-private bit for each symbol, set by the binder, or a test
     that the name starts with `#` before the declaration hop;
   - a sort key for each symbol made once, not per comparison.
   Estimated reach 1.5–2%.
2. **Outer type parameters out of the Map, ts-pattern 1.2%, zod3 0.6%.**
   Either keep the list in a lazily reserved `Table[TypeList, LINKS]`
   (untouched pages cost no memory), or cache it on the instantiated
   target's record.

   This partly reverses trig#233's memory cut, so it is a memory-for-speed
   question: measure peak RSS with it.

Relations (3.4% / 1.3%) are item 21. Inference (1.6% on ts-pattern) is
per-call.md's open lead.

## Lever (a) built and measured (2026-11-02)

- Branch member-bits, saved as [instantiation-members-data/member-bits.patch](instantiation-members-data/member-bits.patch): reserved and
  private bitsets on `ast.Names`, set in `intern`, read by
  `is_reserved_member_name` and by an early return in
  `is_static_private_identifier_property`.
- Output is identical on 7 projects at 1 and 4 checkers.
- Mac, 5 runs, instructions: ts-pattern 0.46% fewer, zod3 0.64% fewer,
  mitt 0.32% more. That is under the bar alone.
- Sort keys are already made once per sort, as tsrs does. Handed to Rig -
  Merges, who adds get_named_members' remaining costs.
- Lever (b)'s memory, a lazily reserved `Table[TypeList, LINKS]` arm
  (build `ob`, not kept):
  - peak memory: ts-pattern +0.9 / +2.2 MiB at 1 / 4 checkers, zod3
    +0.7 / +1.9 MiB;
  - 0.37% more instructions on ts-pattern; the speed is unmeasured on
    pup.
