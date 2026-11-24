# What Trig's safety checks cost, and what could remove them (2026-11-23 to 24)

Measured first, nothing built. Every number comes from builds of Trig made for the purpose; none of them landed.

## The ceiling: what every check costs ([ceiling.md](ceiling.md))

Trig faeb512b was built three ways from Rig 383a1b2b5:
- **checked:** the release build.
- **zigfast:** `-Ofast`, so Zig's own overflow, conversion and slice checks are off.
- **ceiling:** also Rig's index, slice and length panics as `unreachable`.

All three print identical output. On the Mac at c1, removing every check gives:

| run | fewer instructions | fewer cycles |
|---|---:|---:|
| Compiler, --noCheck / full | 13.1% / 12.4% | 6.4% / 7.5% |
| webpack, --noCheck / full | 10.9% / 11.9% | 5.0% / 6.8% |
| supabase-studio, --noCheck / full | 7.3% / 8.7% | 2.6% / 3.1% |

Rig's own index, slice and length checks cost about three to four times what Zig's checks cost:
- Rig's: 1 to 8% of cycles.
- Zig's: 1 to 2%.

The checks are well predicted, so they cost about half as much in cycles as in instructions.

## Which checks four proof rules would remove: webpack --noCheck ([census-nocheck.md](census-nocheck.md))

Method:
- Every branch to a panic is tied to its source line by its inline chain.
- Each branch is weighted by its function's samples per instruction.
- Each site is classified by the proof rule that would remove it, and the top 120 sites were read by hand.

Shares of the checks that run (the census's "live" share), front end only:

| rule | share of live checks | ~% of cycles |
|---|---:|---:|
| (a) narrowing to 32 bits | 8.5% | 0.42% |
| (b) runs of adjacent indexes through a helper | 9.0% | 0.45% |
| (c) facts about self's fields between methods | 11.8% | 0.59% |
| (d) handle ids into grow-only Lists | 30.7% | 1.53% |
| (d) with the record invariant (d-rec) | 39.1% | 1.95% |

The rest is the runtime and Zig std (10%), parameter positions (6.5%) and std's own parameter indexes.

Rules (a) to (c) each need compiler work first, called S1 in the census:
- facts about an `Int` field of self;
- kills by field rather than by the whole binding;
- a write summary for each method.

The owner held (a) to (c) on these numbers.

## (d): index checks on Trig's per-node Lists ([d-design.md](d-design.md))

The rule asked for holds for one List value, but Trig's ids cross List values. So no sound List rule exists. The
sound form is `Table` with `Slot` ids, which Rig already has, with no test on a slot read. The note proposes:
- no new language rule;
- a store per owner of many files, not per file, since every Table touched takes at least a page;
- Trig to measure it.

STD.md's "Table and Slot" teaches the pattern (#1231).

## The same census on full runs ([full-run.md](full-run.md))

Builds and method:
- Trig ec477026 was built twice from Rig b4d9e7247: checked, and the ceiling patch.
- Mac Time Profiler traces covered webpack, typeorm, Compiler and Compiler-Unions at c1.
- pup used perf with the PGO build from slot 739.

On full runs, checks cost 4.7–5.7% of cycles. Counted within the check phase alone (full minus noCheck), they cost
5.3–8.3%.

Two artifacts:
- Trig's `CHECK_IDS`, on in a plain release build and off in race builds, was 11–14% of the Mac's live checks. It is
  left out of the numbers.
- That artifact exposed a Rig gap: `rig.lenOf` of a `Table` made a length test, since fixed (#1239).

The ranking differs from --noCheck, and the Mac and pup agree. Shares of live checks:

| kind | share of live checks | ~% of cycles |
|---|---:|---:|
| handle reads into the AST node store (`Ast.kind`, `parent`, `flags`, `pos`, `nodes`), which a Table store covers | 20–27% | 1.0–1.5% |
| other handle ids (id arithmetic) | 10–14% | 0.5–0.65% |
| inside a node record (offset or slice) | 10–13% | 0.5–0.75% |
| the runtime and Zig std | 8–14% | |
| List and slice indexes in checker code | 9–10% | |
| checker conversions and overflow outside relation code | 7–9% | |
| (a) to (c) | 6–10% | 0.3–0.55% |
| conversions in relation code | 1–2.5% | |
| std Map, Set and Ordered (counted inside the rows above) | 2–3.5% | |

So the check phase does hold most of the cost in a few kinds, but those are handle reads, not (a) to (c). On full
runs the three held rules are worth less than on --noCheck. The lever is Trig's AST store as one Table per program.

## Rust's integer model as a scratch build ([intmodel.md](intmodel.md))

Asked for the owner's question. His decision (2026-11-24): keep the checks, so overflow and conversion checks stay in
release builds. The build:
- Emitted code wraps on `+ - *`, negation and `<<`.
- Conversions truncate or sign-extend, as Rust's `as` does.
- Bounds, slice, length, division and shift-amount checks stay, as do the runtime's own traps.

The work found three places where Rig's proof pass omitted a bounds test by relying on an overflow trap, all off in
that build:
- `i += c` keeping `0 <= i`;
- `Int(U64)` taken as non-negative;
- a guard `i + k < b` taken as a bound.

With wrapping, each could have let a needed bounds test go. formal/ models unbounded `Int`s, so no proof there rests on
a trap.

The core suite under the build:
- 104 cases that expect an overflow panic run on.
- `cli.fault_signal`'s infinite recursion becomes a loop that never ends, so any rerun needs a per-process timeout.
- `cli.preempt_cover` exposed a latent scheduler bug on main: an actor's method inlined outside the preemptible
  section. It is fixed, with a static check for the class (#1242).

Trig's PGO race of the build against main goes to the owner through Rig.

## Files

- **Notes:** [ceiling.md](ceiling.md), [census-nocheck.md](census-nocheck.md), [d-design.md](d-design.md),
  [full-run.md](full-run.md), [intmodel.md](intmodel.md).
- **`patches/`:** `ceiling.patch` and `zigfast.patch` (the ceiling's two Rig arms), and `intmodel.patch` (the
  integer-model scratch).
- **`data/`:** the cycle boards (`runs*.tsv`, `sum-*.md`), the census tables (`report-nocheck.md`, `static.md`,
  `ordering.md`, `kinds-full.md`, `kinds-pup.md`, `table-full.md`, `top-sites-full.txt`), the panic-branch counts,
  the proof dumps, and the integer model's changed bombs (`changed-bombs.tsv`).
- **`tools/`:** the builds (`build.sh`, `build3.sh`), the boards (`measure*.py`, `summary.py`), the traces (`record*.sh`,
  `leaf.py`, `leaf2.py`), and the census pipeline:
  - `panics.py`, `sites.py`, `sites_x86.py`, `sitetext.py`, `classify.py`, `kinds2.py`, `report.py`, `agg.py`,
    `rigloc.py`;
  - `weighted.py`, `hot.py`, `groups.py`, `srccount.py`, `static_census.py`.
- **Not kept:** the raw traces and per-branch site tables (about 160 MB) and the builds.
