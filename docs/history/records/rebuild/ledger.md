# The rebuild ledger

The running state of the rebuild ([rebuild.md](../../../internals/rebuild.md),
[architecture.md](../../../internals/architecture.md)). The lead keeps
it: builders report, and the lead records each step as it is claimed and
as it lands. Newest entries first.

## Base

- Rig: tag `revamp-base`, commit 645996606.
- Trig: tag `trig-revamp-base`, commit f876e4b2, pinned to `revamp-base`.
- Baseline record: `docs/history/records/2026-11/revamp-base/` (in progress).

## Steps

| Step | Kind | Track | Builder | State | PR | Net source lines |
|---|---|---|---|---|---|---:|
| Pilot front F1: the recorder's trail | I | front | pilot-front | claimed | | |
| Pilot front F2: byte literals at the site | I | front | pilot-front | claimed | | |
| Pilot front F3: iterator loops at the `for` | I | front | pilot-front | claimed | | |
| Pilot back: the var table | I | back | pilot-back | claimed | | |
| LLVM bitcode measurement | experiment | side | llvm-probe | claimed | | |

## Line scoreboard

Lines at `revamp-base`, now, and the budget (architecture.md, "Line
budgets"). Updated as steps land.

| Pass | revamp-base | Now | Budget |
|---|---:|---:|---:|
| front end | about 9,100 | | 7,000 |
| modules and driver | 1,172 | | 950 |
| declare | about 6,700 | | 4,800 |
| types | about 9,000 | | 6,000 |
| recorder | about 4,700 | | 1,200 |
| elaborate and its splits | about 28,300 | | 19,000 |
| cteval | 2,175 | | 2,000 |
| LIR | 0 | | 1,000 |
| lower (storage at base) | 2,774 | | 6,000 |
| ownership | 9,768 | | 6,000 |
| proofs | 2,930 | | 2,000 |
| decide | about 2,500 | | 2,000 |
| print and type layout | 14,192 | | 8,000 |

## Entries

### 2026-11-24

- The owner approved rebuild.md (#1252), the baseline tag, and
  architecture.md with its four defaults (#1254): two pilots in
  parallel, sema once in elaborate, and the LLVM bitcode measurement
  as a side experiment.
- Pilots claimed: front (F1–F3) and back (the var table), on disjoint
  files. The LLVM bitcode measurement claimed as a side experiment.
- Baseline: the full suite at `revamp-base` passed 12,783 of 12,783 on
  burst. Trig's light gate is GREEN. The pup timing of the build, the
  check, and the benches, and Trig's race, are still running.
