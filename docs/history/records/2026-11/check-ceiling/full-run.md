# Census of Trig's checks on full c1 runs (check phase included), 2026-11-24

Rig - Final, for Rig (foreman). Measurement only. This repeats census-nocheck.md (webpack --noCheck, the front end only) on
full runs, where the checker takes most of the cycles.

## Builds and method

- **Mac:**
  - Trig ec477026 (main) built twice from Rig b4d9e7247 (Trig's pin, the same `src` as main 91b4381b5).
  - `checked` is the plain release build. `ceiling` is the same Rig with ceiling.patch (Zig `-Ofast`, and Rig's
    index, slice and length panics `unreachable`).
  - Both print byte-identical output on every run.
  - Time Profiler traces of `checked`: 12 runs each of Compiler and Compiler-Unions, 6 each of webpack and typeorm.
- **pup:** perf (`cycles:u`, 4 kHz) on E-core 18, 6 runs each of webpack, typeorm and Compiler. The binary is the PGO
  build from slot 739 (Trig 3dd367cb on Rig b4d9e7247), taken before BOLT because that copy keeps its DWARF. BOLT
  moves code but keeps the same checks.
- **Pipeline, as in census-nocheck.md:**
  - Every conditional branch to a panic is tied to its inline chain (atos on the Mac; addr2line on pup, through the
    x86 port `tools/sites_x86.py`).
  - Each branch is weighted by its function's self samples over the function's instructions.
  - The sites are classified by `tools/classify.py`, then by the kinds Rig asked for (`tools/kinds2.py`).
  - I read the top 130 sites by hand (`data/top-sites-full.txt`, 59% of the weight).
- **New tool:** `tools/leaf2.py` resolves the leaf frames xctrace left as bare addresses in `__rig_text` (55–84% of
  the samples) by each trace's load address. Without it the profile would cover 10–23% of the samples.
- **Artifact removed: Trig's `CHECK_IDS`.** A plain `rig build --release` of Trig keeps `CHECK_IDS = true`
  (src/checks/checks.rig), while tools/trig/pgo and tools/trig/bolt build with it false. With it true, each id lookup
  also runs `check_id(i, rig.lenOf(table))`, and `rig.lenOf` of a `Table` makes a length test (`lenHeld` knows Lists
  and slices, not `__rig_table`). That was 11–14% of the Mac's live checks, and none on pup. It is left out below, and
  each run's cost is reduced by its share.

## The measured cost of all checks (Mac, cycles, fastest of 5, checked vs ceiling)

| run | noCheck | full | check phase alone (full − noCheck) | full, without CHECK_IDS |
|---|---:|---:|---:|---:|
| webpack | 4.2% | 5.8% | 6.4% | 5.1% |
| typeorm | 5.4% | 5.4% | 5.3% | 4.8% |
| Compiler | 3.6% | 6.5% | 8.3% | 5.7% |
| Compiler-Unions | 5.9% | 5.5% | 5.4% | 4.7% |

## By kind (share of live check branches, and ~% of c1 cycles)

| kind | Mac webpack | Mac typeorm | Mac Compiler | Mac C-Unions | pup webpack | pup typeorm | pup Compiler |
|---|---:|---:|---:|---:|---:|---:|---:|
| H1 handle id, a Table store covers | 23.6% (1.21) | 23.2% (1.11) | 26.6% (1.53) | 22.7% (1.07) | 22.2% (1.13) | 20.4% (0.98) | 23.6% (1.36) |
| H1 handle id, other List (id arithmetic) | 11.6% (0.59) | 10.1% (0.49) | 11.4% (0.65) | 14.1% (0.66) | 9.5% (0.48) | 9.8% (0.47) | 10.2% (0.59) |
| H3 inside a node record (offset, slice) | 10.1% (0.52) | 10.1% (0.49) | 10.7% (0.61) | 9.7% (0.46) | 12.8% (0.65) | 12.0% (0.58) | 13.3% (0.76) |
| L List/slice index in checker code | 9.0% (0.46) | 9.1% (0.44) | 9.2% (0.53) | 9.4% (0.44) | 9.0% (0.46) | 8.8% (0.42) | 10.2% (0.59) |
| C conversions/overflow in checker, not relation | 9.1% (0.46) | 8.7% (0.42) | 9.4% (0.54) | 8.8% (0.41) | 6.7% (0.35) | 7.1% (0.34) | 6.6% (0.38) |
| R conversions/overflow in relation code | 1.0% (0.05) | 1.0% (0.05) | 0.8% (0.05) | 2.5% (0.12) | 1.9% (0.10) | 1.9% (0.09) | 1.6% (0.09) |
| Z runtime and Zig std | 12.3% (0.63) | 14.2% (0.68) | 8.4% (0.48) | 9.9% (0.46) | 10.0% (0.51) | 12.4% (0.60) | 8.4% (0.48) |
| (a)–(c) kinds: a, b+, c2n/r/p, hash | 7.8% (0.40) | 8.5% (0.41) | 9.4% (0.54) | 6.1% (0.29) | 9.8% (0.50) | 9.4% (0.45) | 9.6% (0.55) |
| a+ parameter positions | 1.7% (0.09) | 1.7% (0.08) | 1.6% (0.09) | 1.3% (0.06) | 1.7% (0.09) | 1.4% (0.07) | 1.3% (0.07) |
| other front-end: e, std text/utf8, data, ctr | 6.2% (0.32) | 6.1% (0.29) | 4.9% (0.28) | 7.3% (0.34) | 7.7% (0.39) | 6.5% (0.31) | 6.0% (0.35) |
| other shapes (ast, lexer, parser) | 7.6% (0.39) | 7.2% (0.35) | 7.6% (0.44) | 8.3% (0.39) | 8.9% (0.45) | 10.1% (0.48) | 9.0% (0.52) |

- **std Map, Set and Ordered** (a branch whose innermost frame is in the tables' code; these are counted inside the
  rows above, under their callers): 1.8–3.0% of all check branches on the Mac and 3.1–3.5% on pup, about 0.13–0.18%
  of cycles. They are mostly Zig overflow and conversion checks inside the tables.
- pup's cycle column uses the Mac's measured cost, since there is no pup ceiling build.

## What it says

1. **The ranking differs from --noCheck, and Mac and pup agree.**
   - On full runs, handle ids (H1 and H3) are 44–49% of the live checks, about 2.2–2.8% of cycles.
   - The (a)–(c) kinds are 6–10%, about 0.3–0.55% of cycles. On webpack --noCheck they were 29% (about 1.5% of
     front-end cycles).
2. **The few kinds that hold the cost are handle reads into the AST's node store, called from the checker.**
   - Sites: `Ast.kind` (`recs.at(n.id).kind`, 5.5% of all branches alone), `Ast.parent`, `Ast.flags`, `Ast.pos`
     (`locs.at(n.id)`), `Ast.nodes` (`lists.at(l.id)`), `is_identifier`, `modifiers_to_flags`.
   - A `Table` store with `Slot` ids covers these (H1, "covers"): 20–27%, about 1.0–1.5% of cycles.
   - The record reads (`word_node`: `words.at(recs[n].data + off)`, list slices) need the record invariant as well
     (H3, 10–13%).
   - The AST is one store per file, and every Table takes at least a page, so that store would have to be one per
     program, not per file.
3. **Integer conversions in relation code are small: 1–2.5%,** about 0.05–0.12% of cycles. The checker's other
   conversions and overflow checks are 7–9%, mostly `flow_memo_effect_sum` and `union_front_state` (sums of counters).
4. **The runtime and Zig std are 8–14%:** wyhash reads, `rig.slice`, `Table.push`, `Layout.home`'s shift amount.

## Rig-side notes, outside the rules

- **`rig.lenOf` of a `Table` makes a test.** A Table never holds more than its `n` slots, so `lenHeld` could accept
  `__rig_table` (a one-line change). It matters only to code that reads a Table's length in hot code; Trig's race
  builds do not.

Files:
- `data/kinds-full.md`, `data/kinds-pup.md`: every row per run, with the top sites per kind.
- `data/table-full.md`, `data/top-sites-full.txt`.
- `data/runs-full.tsv`: the cycle rows.
- `tools/leaf2.py`, `tools/sites_x86.py`, `tools/kinds2.py`, `tools/measure2.py`.
- The raw traces and per-branch site tables (about 160 MB, Mac and pup) were not kept.
