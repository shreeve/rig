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
| Pilot back: the var table | I | back | pilot-back | merged | #1256 | +20 |
| Back: `field_moves` into `Binding` | I | back | | next | | |
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

### 2026-11-25

- The back pilot landed (#1256): `storage.plan` keeps one var table
  that emit and the ownership checker read, in place of the storage
  map, `part_drops`, `Symbol.hold`, the lazily decided `drop_kind`, and
  the consumed set. Emit-diff identical on all 38 programs, Trig
  included; core suite 12,743 jobs, none died; the oracle unchanged;
  the check guard 0.1% fewer instructions; Trig's and loco's light
  gates GREEN.
- **The pilot's finding:** it was budgeted −500 source lines and landed
  +20. The table adds lines, and each of emit's 56 hidden-storage sites
  still writes its own Zig; the saving comes when emit prints vars
  from the table, the back track's printer step. A step's budget counts
  only the lines that step itself can delete.
- `emit-diff` compares Trig from a plain export (#1260), and a Trig it
  cannot compare fails the proof.
- The before state is race 761 (Trig's research 34): 16 projects, Trig
  over tsrs 0.889 / 0.923 / 0.933 / 0.917 at 1, 2, 4, and 8 checkers;
  race 760 was void (other projects' jobs ran during it), and board
  slots run inside `cpuq run --exclusive`.

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
