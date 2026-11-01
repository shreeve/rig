# Typed table ids, measured before designing (2026-11-01)

**Question** (the beat-tsrs list, item 1): `push` on an append-only
table would return an id type tied to that table, so a lookup by such an
id is in range by construction and makes no test. codegen-gap §5 put the
lookups by ids read from memory at 3.1% of ts-pattern's retired
instructions and 4.7% of zod3's, and span reads at 1.0% and 0.4%; but
proof-pass found that removing proven checks cut instructions and not
cycles. Do the cycles move? Measured as a hand ceiling on Trig's emitted
Zig, before any design round; nothing built. Scripts, the site list and
raw output are in [typed-ids-ceiling-data/](typed-ids-ceiling-data/).

**Answer: yes, the cycles move, and with span reads item 1 clears
Trig's bar on both projects.** On pup (one checker, 20 rotated rounds,
plain release builds), taking out the test of every lookup by an id read
from memory and of every span read (`idspan`) makes Trig **2.66% faster
on ts-pattern and 3.34% on zod3**, with 2.68% and 3.78% fewer total
cycles, 5.29% and 6.74% fewer instructions, and peak RSS level. The ids
alone (`ids`) are 1.17% faster on ts-pattern and 2.59% on zod3 (1.21%
and 2.96% fewer total cycles; 4.44% and 6.06% fewer instructions): over
the instruction bar on both, over the time bar on zod3 only, and on
ts-pattern inside the 1.3% a build's layout can move it (check-bisect's
lottery). Unlike items 2 and 3, a handful of loop tests that were
predicted branches beside their loads, the ids' tests are written in
accessors inlined at thousands of call sites, so their instructions and
bytes cost a front-end-bound program whether or not they fail (`.text`
3.3% smaller, 3.9% with spans).

**Hot sites and the long tail.** The sites codegen-gap's samples named
(`hot`: the program's `files` by a node's file, the AST's `recs[n.id]`,
the binder's `bindings` and `symbols`, `symbol_data`, Ids' location
tables, the checker's `syms`) carry 83% of the ids' instructions on
ts-pattern (3.69% of 4.44%) and 86% on zod3 (5.20% of 6.06%); by time,
all of ts-pattern's (1.22% faster against `ids`' 1.17%) and about half of
zod3's (1.43% against 2.59%), each within one build's lottery. The long tail, 1,336 more id sites, is
0.75% and 0.86% of the instructions. The span reads add 0.85% and 0.68%
of the instructions and 1.5 and 0.8 points of time; the store's
`type_lists[list.start + k]` was the hottest single check line in
codegen-gap's sample. Against codegen-gap's 3.1% and 4.7% (and 1.0% and 0.4% for
spans), the measured reach is larger, since a removed test is more than
its compare and branch (the sign test, the cast, the panic's block), and
this classifier takes every id site, not only the sampled lines.

## What was removed

Every checked lookup in the emitted package (`List.at`, `slot`,
`constSlot` and their `Proven` forms; `rig.at` and `rig.elemPtr` on a
slice; a `Table`'s `atInt`, `slotInt`, `constSlotInt`), 5,036 call
sites, was put in a class by the text of its index
([ceil.py](typed-ids-ceiling-data/ceil.py), every site and its class in
[sites.txt](typed-ids-ceiling-data/sites.txt)):

| class | sites | what it is |
|---|---:|---|
| id | 3,349 | an index read from memory: a field (`n.id`, `x.file`), a call's result (`self.checker_symbol(s)`, `self.ids.local_sym(s)`), a U32 widened to `Int`, an id-typed parameter or `var`, an element capture, a `const` bound to one of these; or one of these less 1 (`file - 1`) |
| Int parameter | 372 | an `Int` parameter: an id as often as an index (`task`, `ci`, `index`); only the 142 at hot sites were taken |
| span | 41 | a start read from memory plus an offset, in the AST and the checker: `type_lists.atInt(list.start + k)` and its five siblings, `words.at(recs.at(n.id).data + off)`, `words.at(d + i)`; and the Interner's `text`, a slice from `ends[i - 1]` to `ends[i]` |
| other | 1,275 | a loop counter (an `Int` `var`, an index capture), arithmetic on locals (`i + 1`, `lo + hi`), a length, a literal, and text positions (the lexer's `pos + offset`) |

The id class counts every lookup by an id, also a `Table`'s `t[slot]`,
which makes no test already; the binary decides what was removed.
The arms, each the package `rig build --release` wrote with one edit:

- `base`: unedited.
- `hot`: the id sites codegen-gap's samples named: Ids' `sym_loc`,
  `tab_loc`, `node_base`, `sym_base`, `tab_base`; the checker's `syms` by
  `checker_symbol`; the binder's `bindings` and `symbols` by a symbol's
  file and local index; the program's `files` by a node's file;
  `symbol_data`; the AST's `recs[n.id]`; the Interner's `ends` by an
  atom. 2,155 sites.
- `ids`: every id site, `hot` included. 3,491 sites.
- `idspan`: `ids`, and the span reads. 3,532 sites.

An unchecked lookup reads the element through the List's (slice's,
Table's) pointer with no compare, as a `Table`'s slot read does
(`atU`, `slotU`, `constSlotU`, `atIntU`; checks.md's stand-in form); no
fact reaches LLVM (no `unreachable`, which would tell LLVM more than a
typed id does). A half-proven `atProven(i, .lower)` at an id site is
made `.both`.

| | `.text` | against `base` |
|---|---:|---|
| `base` | 11,271,801 | |
| `hot` | 10,962,009 | 2.7% smaller |
| `ids` | 10,899,689 | 3.3% smaller |
| `idspan` | 10,830,297 | 3.9% smaller |

## Method

- **Sources.** Rig `95fffb6cf` (origin/main), built in the worktree.
  Trig main `baae9fe`, its `src/` and `tools/trig` by `git archive`,
  `tools/trig/main.rig` as the root. `rig build --release` with a
  stand-in `ZIG` that records its arguments wrote the package (49 files,
  19 MB), as check-bisect's `emit.sh` did.
- **Builds** ([mk.sh](typed-ids-ceiling-data/mk.sh),
  [builds.txt](typed-ids-ceiling-data/builds.txt)): each arm compiled on
  its own as `rig build --release` does, `zig build-exe -Osafe
  -fomit-frame-pointer` on `__rig_main.zig`, a fresh cache each, one at a
  time through `tools/heavy` on the Mac; no environment-switched arm.
  pup's binaries were cross-built on the Mac for pup's native target,
  named (`-target x86_64-linux.7.0...7.0-gnu.2.43 -mcpu=meteorlake`,
  pup's `zig targets` native entry): a Rig example built so on the Mac
  and natively on pup has a byte-identical `.text` (only debug paths
  differ), so no pup release slot was used.
- **pup** ([time.sh](typed-ids-ceiling-data/time.sh),
  [summ.py](typed-ids-ceiling-data/summ.py)): x86, P-core 8 with
  its sibling 9 idle (`taskset -c 8`), the four arms interleaved in each
  round and their order rotated each round, ts-pattern then zod3, one
  checker (`--noEmit --singleThreaded`), 20 rounds, 01:34:53 to
  01:36:22 on 2026-11-01, load 1.6-2.9. Wall time is perf's
  `duration_time`; user and total (user and kernel) cycles and user
  instructions from `cpu_core`; peak RSS from `/usr/bin/time`. "Faster"
  and "fewer" are the median over rounds of each round's ratio to
  `base`, with the 25th to 75th percentile of the wall ratio. The rest of
  pup was quiet: other sessions' builds paused, Trig's 00:00 suite over;
  one job not ours ran alongside, a Nexus benchmark pinned to core 3. The
  kernel's share was steady (0.34G cycles a ts-pattern run, 0.09G a zod3
  run, in every arm).
- **The Mac** ([bench.py](typed-ids-ceiling-data/bench.py), proof-pass's):
  arm64, the same arms built natively, 20 then 60 rounds, every arm once
  a round, the first arm rotated each round, `/usr/bin/time -l`'s cycles
  and instructions, at `nice 19` through `tools/low`, load 4.4-5.4.
- **Correctness.** Every run of every arm, on both machines, printed
  `base`'s output byte for byte (stdout and stderr on pup, stdout and
  the exit status on the Mac), and every pup run exited 2, as `base`
  does (the projects' test files lack their runner's types).

## Numbers

pup, 20 rounds ([times-pup.txt](typed-ids-ceiling-data/times-pup.txt),
[summary-pup.txt](typed-ids-ceiling-data/summary-pup.txt)), against
`base` (863.5 ms and 167.9 ms, 4.084G and 0.785G total cycles, 9.050G
and 1.637G instructions, 245.8 MB and 76.3 MB):

| arm | ts-pattern: faster (IQR) / fewer total cycles / fewer user cycles / fewer instructions | zod3: the same |
|---|---|---|
| `hot` | 1.22% (0.48 to 1.79) / 1.26% / 1.43% / 3.69% | 1.43% (0.12 to 2.90) / 2.02% / 2.52% / 5.20% |
| `ids` | 1.17% (0.27 to 1.88) / 1.21% / 1.42% / 4.44% | 2.59% (1.51 to 3.78) / 2.96% / 3.20% / 6.06% |
| `idspan` | **2.66% (1.97 to 3.15) / 2.68% / 3.31% / 5.29%** | **3.34% (2.56 to 5.33) / 3.78% / 4.45% / 6.74%** |

Peak RSS was level in every arm (245.3-245.8 MB, 76.2-76.3 MB).

The Mac, 60 rounds ([times-mac-2.txt](typed-ids-ceiling-data/times-mac-2.txt)),
medians against `base`:

| arm | ts-pattern instructions | ts-pattern cycles | zod3 instructions | zod3 cycles | peak RSS |
|---|---|---|---|---|---|
| `hot` | 3.54% fewer | 1.80% fewer | 5.03% fewer | 2.36% fewer | the same |
| `ids` | 4.25% fewer | 1.79% fewer | 5.85% fewer | 2.04% fewer | the same |
| `idspan` | 5.95% fewer | 2.85% fewer | 7.13% fewer | 3.96% fewer | the same |

The first Mac run (20 rounds, [times-mac-1.txt](typed-ids-ceiling-data/times-mac-1.txt))
read the same instructions and cycles from 0.1% more to 1.7% fewer on
ts-pattern and 3.4-4.6% fewer on zod3.

Read from these:

- **Against the bar** (more than 1.5% faster, or at least 1% fewer
  instructions, peak RSS no higher): every arm clears it by
  instructions on both projects. By time, `idspan` clears it on both,
  outside the layout lottery's 1.3% and with its interquartile range
  above 1.5% on both; `ids` clears it on zod3 only.
- **Cycles follow instructions** at 0.3-0.5 of them for the ids and 0.5-0.6
  with spans, as check-bisect found of every group of checks (0.5 to
  0.7), and unlike proof-pass's loop tests (none). What the ids remove
  is code the front end decodes at every inlined accessor.
- **The Mac agrees**: 1.8% and 2.0% fewer cycles for `ids`, 2.9% and
  4.0% for `idspan`, with instructions within 0.7 points of pup's.
- **One build each.** A single build can read about 1.3% either way by
  layout (check-bisect's nulls); `hot` and `ids` reading alike on
  ts-pattern though `ids` removes 0.75% more instructions is that
  noise. The `idspan` result is twice the lottery on ts-pattern and
  2.5 times it on zod3.
- Plain release builds, not PGO; check-bisect found PGO keeps the
  checks' gain (its `accast`, the accessors and the AST: 2.3% and 3.6%
  faster with PGO against 2.0% and 2.5% plain).

## What it says for the design

- The reach is in the ids that one append-only store makes and that
  every accessor reads: node records by `n.id`, files by a node's file
  (with Trig's `file - 1`, which a table with a slot at 0 removes),
  binder symbols by file and local index, symbol data, Ids' location
  tables, the checker's symbol table. A typed id that reaches these
  takes most of item 1 (83-86% of its instructions); the tail adds
  little.
- Span reads are worth having in the same change: they are more than
  half of `idspan`'s time on ts-pattern (1.5 of 2.66 points).
  `Span[n]` alone (#686, proofs.md) read within the noise; here, on top
  of the ids, the spans add 1.5 and 0.8 points.
- `Table` and `Slot` exist; check-bisect's reading stands that much of
  this is also reachable by Trig moving its id stores onto them. What
  the language design adds is ids tied to their table (not any table of
  the same `n`) and spans, which the owner decides.
