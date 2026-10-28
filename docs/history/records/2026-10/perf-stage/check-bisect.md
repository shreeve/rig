# Which of Trig's checks cost its time (2026-10-28)

**Question.** #753 (trig-zig-ceiling.md) measured that Trig's emitted
Zig with every check removed is 6.6% faster on ts-pattern and 9.2% on
zod3 (plain release builds), index and slice tests about three fifths
of it; but the subsets tried before (`Span[n]` and the false-edge proofs,
proofs.md; the typed2 stand-in, checks.md §4.1) gained little. Where
does the 6-9% come from: a few hot sites, the code size and register
pressure of all the checks together, the loads a check holds back, or
something else? Which sites carry it, and what is the cheapest Rig-side
form that would remove each group soundly?

**Answer.** The gain is **diffuse**, and it is **code size and
instructions, not alignment luck and not a few hot sites**. Every kind
of check and every group costs time in proportion to what it removes:
time is 0.5 to 0.7 of the instructions removed, for every kind and
every group, and the kinds and the groups each add up to the whole to
within half a percent of the instructions. No group of sites holds more
than about 2.5% of the instructions. Trig's code is front-end bound
(half its uops from the legacy decoders, 6-8% of its cycles in i-cache
stalls), so a check's bytes cost as well as its two instructions: the
L1i misses fall with the code removed, executed or not. The layout
lottery is real and as large as most groups: three builds that change
no check read from 1.3% slower to 0.7% faster. Ranked, by instructions
on ts-pattern and zod3 (plain builds, 20 rounds):

1. **List index tests, 4.6% and 6.3% of the instructions, 2.8-3.3% and
   3.0-4.5% faster** (PGO: 3.1% and 3.9%), of which: the checker's
   small id and record accessors (`Ids`, symbol tables, links) 1.6% and
   2.2%; the AST's `recs[n.id]` reads, 1.1% and 2.3% (4% of the code);
   the rest of the checker's bodies about 1%; everything else 0.4%.
   The two first together: 2.0% and 2.5% faster plain, **2.3% and 3.6%
   faster with PGO, 2.8% and 4.7% fewer instructions**.
2. **Zig's overflow tests, 1.9% and 2.3%; 1.3-1.6% and 0.6-2.1%
   faster** (PGO: 1.5% and none). By where they are written, a fifth of
   all of Zig's tests are in the checker's functions and a third in the
   runtime's own Zig (1.7% and 1.3% of the instructions, 1.2% and 1.0%
   faster).
3. Below the lottery: a Table's integer index (1.3%, 0.8%), Zig's own
   index and other tests (1.3%, 1.6%), `@intCast` (0.7%, 1.0%), slice
   bounds, unwraps and `unreachable`, a Table's full test.

The cheapest form for the two largest groups is the index type Rig
already has, `Table` and `Slot`, with Trig's id stores and node records
moved onto it: Trig-side, no Rig build, and together they clear Trig's
bar. The one group a Rig change alone could take is the runtime's own
Zig, by writing its hot helpers' proven arithmetic unchecked: 1.7% and
1.3% fewer instructions, over the instruction bar, under the time bar.
Nothing here lands in #755's files.

Measurement only: no compiler change. The scaffolding, the variants'
recipe, the scripts, and every round's raw output are in
[check-bisect-data/](check-bisect-data/).

## Method

- **Sources.** Rig `773978d1d` (#754, Table huge pages), built in a
  clone of its own on pup. Trig `403a823`, its `src/` and `tools/trig`
  by `git archive` from pup's full checkout, `tools/trig/main.rig` as the
  root, as #753 built it; ts-pattern and zod3 copied out of that checkout.
- **The package.** `rig build --release` with a stand-in `ZIG` that only
  records its arguments writes the emitted package (`emit.sh`). Each
  variant is that package with one change, compiled on its own as
  `rig build --release` does, `zig build-exe -Osafe -fomit-frame-pointer`
  on `__rig_main.zig` (`mk.sh`), the cache removed before and after: no
  variant shares a binary with another.
- **The scaffolding** (`ceil.py`). Every check is gated by its kind, at
  compile time:
  - Rig's own checks, in the package's `rig/runtime.zig` and
    `rig/table.zig`: each panic call goes through an inline gate
    (`indexPanicK("li")` and the like); a kind that is off makes the
    failure `unreachable` with runtime safety off, so LLVM assumes the
    test passes and drops it, as #753's patches did.
  - Zig's own safety tests: the root's `panic` namespace, which Zig
    0.17 calls for every safety check by kind (`integerOverflow`,
    `integerOutOfBounds`, `unwrapNull`, `outOfBounds`, and so on), gets
    each handler from `std.debug.FullPanic` when its kind is on and an
    `unreachable` one when it is off.
  - A group: in the functions of the group, the List index and slice
    calls (`.at`, `.constSlot`, `.slot`, the `Proven` and `If` forms,
    `rig.at`, `rig.slice`, `rig.indexBelow`, ...) are renamed to twins of
    kind `gli` (`gsl`, and `gti` for a Table's integer index), which
    have the same bodies; turning `gli` off removes the List index
    tests written in those functions alone, wherever they are inlined.
    A Zig group puts `@setRuntimeSafety(false)` at the top of each of its
    functions instead, which turns off every one of Zig's tests written
    there.
  With every kind on, the scaffolding emits what main emits: Zig analyzes
  only what is referenced, so the twins are not compiled, and each gate
  folds to the original call. The scaffolded build with every kind on
  (`base`) has main's instructions, in a `.text` of the same size; the disassemblies differ only in the names of the
  anonymous constants a few instructions load (`base-vs-main.txt`).
- **Kinds.** `li`, an index test of a List, a slice, a string, or an
  array (`rig.index`, `List.at`, `indexBelow`); `ti`, a Table's test of
  an integer index (`t[i]` with an `Int`); `sl`, slice bounds; `ov`,
  Zig's overflow tests (`+`, `-`, `*`, `@shlExact`); `cast`, `@intCast`
  and float-to-integer range tests; `zsafe`, optional and error unwrap,
  enum conversion, corrupt switch, and `unreachable`; `full`, a Table's
  full test on push; `zrest`, Zig's own index and slice tests and the
  rest of Zig's (division, shifts, alignment, lengths); `all`, every
  kind, also `len`, `bytes`, and `keep` (built `-Osafe`, unlike #753's
  `-Ofast`).
- **Groups** (`mkgroups.py`, `g-*.json`), by the function a check is
  written in: **checker**, every function of `checker.zig` but the
  store's; **store**, the functions of `store_generated.rig` (276);
  **members**, those of `members.rig`; **acc**, the checker's small
  inline accessors (the inline functions of ten lines or fewer that
  make a check, 501 of them, `Ids` and the symbol, link, and record
  accessors among them); **ast**, `ast.zig`, `parser.zig`, `lexer.zig`;
  **other**, every other emitted module (`core`, `compiler`,
  `declarations`, `transformers`, std, ...). Map and Set are the
  runtime's Zig (`rig/ordered.zig`, `rig/unordered.zig`), which makes no
  Rig index test; the binder is 0.5% of the time (profile, below).
- **Null variants.** To size the layout lottery, two builds change no
  check: `null1` and `null2` add a never-called function of 1040 and
  2056 bytes of padding to the runtime, which moves the checker's hot
  code by 32 bytes; and `li-store` turned out to be a third, since the
  store's functions make no List index test (their reads are Table
  slots, and their integer reads are `ti`).
- **Timing** (`time.sh`, `summ.py`). pup, `taskset -c 6` with sibling 7
  idle; the variants interleaved in each round, their order rotated each
  round, ts-pattern then zod3, one checker, `--noEmit --singleThreaded`.
  Wall time is perf's `duration_time`; cycles user and total (user and
  kernel), and user instructions, from `cpu_core`; a round waits while
  Trig's full suite runs or another process uses core 6 or 7. "Faster"
  and "fewer" are the median over rounds of each round's ratio to main,
  with the 25th to 75th percentile of the wall ratio. 10 rounds to
  screen, 20 for every group reported at 0.5% or more. Every variant's
  output was compared with main's, byte for byte, in every round: all
  identical.
- **Counters** (`ctr.sh`, `ctrsum.py`). The front end's: L1i misses
  (`frontend_retired.l1i_miss`), iTLB misses
  (`frontend_retired.itlb_miss`), i-cache stall cycles
  (`icache_data.stalls`, `icache_tag.stalls`), uops from the decoders and
  from the uop cache (`idq.mite_uops`, `idq.dsb_uops`), branches and
  branch misses; in four sets so that none is multiplexed, three rounds.
- **Profile** (`grp.py`). 16 runs each of main, li, and all, user cycles
  every 4,000,037, attributed by symbol to the groups.
- **PGO** (`mkpgo.sh`, `zigw`). `rig build --release --pgo` as Trig
  ships it, trained by Trig's `tools/trig/bolt-train` (mitt,
  neverthrow, superstruct, zod3: so zod3 is trained on, ts-pattern not),
  with `ceil.py`'s variant made of the package Rig has just written,
  before the first `zig build-exe` reads it.
- **Machine.** Builds on cores 0,5 through
  `/zfs/trig-pup/trial/slot.sh`. `TRIG_RELEASE_SLOTS` was
  `"0,5 0,5 0,5"` rather than `0,5`: a slot's lock is named by its
  position in the list, so a lone `0,5` takes the lock every `10,11`
  build takes and waited behind other sessions' builds; three entries let a build take
  whichever lock is free, still only on cores 0,5, one build at a time.
  Load average 2.2 at the start (05:33), 1.1 to 2.6 through the night,
  7.8 once while Trig's full suite ran (08:05-08:30, when the runner
  waited), 1.0 at the end (13:54).

## The layout lottery

Three builds change no check: `null1` and `null2` (padding that moves
the hot checker code by 32 bytes) and `li-store` (no List test in the
store's functions). Over four 20-round runs they read from 1.31% slower
to 0.65% faster, in wall time and in total cycles alike, with exactly
main's instructions. So **a single plain build of any change can read
about 1.3% faster or slower than it is by where its code falls**, and a
group whose gain is under that is not told apart from its layout by
timing. Its instructions are: they are the same in every round and do
not move with layout (the nulls run main's count to 0.01%). Their L1i
misses do not move either (within 1.4%), while their uop-cache switches
move by 2.3%. This is the effect #747's two arms met.

## Kinds

Plain release builds, each against main in the same rounds, 20 rounds.
Where a kind ran in more than one 20-round run, each is given.

| kind removed | ts-pattern: faster / fewer total cycles / fewer instructions | zod3: faster / fewer total cycles / fewer instructions | `.text` | confirmed |
|---|---|---|---:|---|
| every check (`all`) | 5.95% / 5.75% / 10.96% | 7.54% / 7.60% / 13.27% | 12.2% smaller | yes |
| List, slice, string, array index (`li`) | 3.31%, 2.76% / 3.16%, 3.01% / 4.62% | 2.97%, 4.51% / 3.06%, 4.28% / 6.26% | 5.7% smaller | yes |
| Zig's overflow tests (`ov`) | 1.43%, 1.59%, 1.25% / 1.37%, 1.61%, 1.26% / 1.87% | 0.63%, 2.12%, 1.16% / 0.45%, 1.79%, 1.32% / 2.29% | 2.6% smaller | yes on ts-pattern; on zod3 in two runs of three |
| Table index by an integer (`ti`) | 0.83%, 1.11%, 0.49% / 0.83%, 1.27%, 0.39% / 1.29% | 0.50%, 1.07%, 0.42% / 0.58%, 1.33%, 0.23% / 0.78% | 0.26% smaller | no: within the lottery |
| slice bounds (`sl`) | 0.39%, 0.60% / 0.52%, 0.73% / 0.29% | 0.45%, 0.23% / 0.69%, 0.04% / 0.59% | 0.19% smaller | no |
| `@intCast` (`cast`) | 0.07% slower / 0.15% / 0.72% | 0.69% / 0.62% / 1.03% | 2.3% smaller | no |
| unwrap, enum, `unreachable` (`zsafe`) | 0.39% slower / 0.42% more / 0.20% | 0.02% / 0.43% more / 0.45% | 0.28% smaller | no |
| a Table's full test (`full`) | user cycles 0.02% / 0.18% (r20f) | 0.25% / 0.08% / 0.13% | 0.10% smaller | no |
| Zig's own index tests and the rest (`zrest`) | user cycles 0.63% / 1.34% (r20f) | 1.19% / 0.18% / 1.63% | 0.37% larger | no |

r20f, where full and zrest ran, met the kernel's noise on ts-pattern
(see "Machine state"), so for them ts-pattern's user cycles and
instructions are given. "Confirmed" is the coordinator's test: two
builds made apart, the variant and main, 20 interleaved rounds, at least
0.5% by wall time and by total cycles on both projects. Every output was
main's, byte for byte.

Read from these:

- **The kinds add up.** By instructions, li, ov, ti, sl, cast and zsafe
  together are 8.99% on ts-pattern and 11.40% on zod3, of all's 10.96%
  and 13.27%; with full and zrest, 10.51% and 13.16%. What every check
  costs together is the sum of what each kind costs alone, to within
  half a percent of the instructions. By time on ts-pattern the single
  kinds sum to about what all gives (5.7% against 5.8-6.0% by total cycles); on
  zod3 they come to 5.1% of all's 7.6%.
- **Time follows instructions.** Over all the variants a check's time
  is 0.5 to 0.7 of its instructions: `all` 5.75% of cycles for 10.96%
  of instructions, li 3.0-3.2% for 4.62%, ov 1.4-1.6% for 1.87%.
  No kind gains more time than its instructions predict, beyond the
  lottery.

## The List index tests, by group

`li` is the largest kind, so it was bisected by where the test is
written (`gli` in the groups' functions alone). 20 rounds, every group
in the same rounds (r20c); `acc` and `ast` again with `accast` (r20g):

| group | sites | ts-pattern: faster / fewer total cycles / fewer instructions | zod3: faster / fewer total cycles / fewer instructions | `.text` | confirmed |
|---|---:|---|---|---:|---|
| all of `li` | | 2.76% / 3.01% / 4.62% | 4.51% / 4.28% / 6.26% | 5.7% smaller | yes |
| checker, but the store | 2,547 | 1.75% / 1.77% / 3.14% | 2.25% / 2.21% / 3.35% | 1.3% smaller | yes |
| of it, the checker's small inline accessors (`acc`) | 788 | 1.05%, 1.56% / 0.65%, 1.83% / 1.57% | 2.24%, 1.54% / 2.34%, 0.94% / 2.19% | 0.77% smaller | yes |
| of it, `members.rig` | 191 | 0.18% / 0.05% / 0.57% | 0.66% / 0.51% / 0.23% | 0.01% larger | no |
| of it, the rest of the checker (by difference) | about 1,570 | / / about 1.0% | / / about 0.9% | | |
| AST, parser, lexer (`ast`) | 1,626 | 0.96%, 0.78% / 1.18%, 0.82% / 1.11% | 1.26%, 1.36% / 1.17%, 1.49% / 2.35% | 4.0% smaller | yes, within the lottery |
| `acc` and `ast` together (`accast`) | 2,414 | 2.02% / 2.02% / 2.67% | 2.51% / 2.44% / 4.48% | 4.8% smaller | yes |
| every other module (`other`) | 1,880 | 0.54% / 0.54% / 0.42% | 0.18% slower / 0.32% more / 0.41% | 0.39% smaller | no |
| the store | 271 | 0.33% slower / 0.28% more / 0.00% | 0.04% slower / 0.18% more / 0.00% | same | a null: no List test |

The groups add up too: checker, ast and other are 4.67% of
instructions on ts-pattern against li's 4.62%, and 6.11% on zod3 against
6.26%; by time on ts-pattern 3.25% against 2.76-3.31%.

- **No few hot sites.** The largest group with a clear gain, the
  accessors, is 788 sites in 501 functions, `Ids.sym_file_of`,
  `local_sym`, `node_id`, `sym`, `tab`, the link and record accessors
  (`signature_links`, `members_links`, ...), the symbol tables
  (`@syms[...]`, `@symbol_data[...]`): inline functions inlined into
  every checker function that reads an id. `members.rig`, 41% of the
  profile's cycles (`instantiate_type_worker`, `mapper_map`), carries
  0.57% of the instructions and no time beyond the lottery:
  `instantiate_type_worker` itself writes no List index at all; what
  its profile loses in `li` is its inlined accessors'.
- **The AST's tests are code size more than work.** `ast` removes 1.1%
  of ts-pattern's instructions but 4.0% of the program's code: `recs[n.id]`
  in `kind`, `flags`, `pos`, `parent`, inlined at thousands of call sites.
  Its L1i misses fall 5.1% (ts-pattern) and 7.3% (zod3).

The profile (`profile-groups.txt`, ts-pattern, by enclosing symbol)
agrees: 87% of the cycles are in the checker's functions, and so is
all of li's saving (4.0 points, against 3.8 in all; the other groups'
small changes are noise), with the runtime (allocator, scheduler) 4.6%,
the AST 2.6%, Map and Set's own runtime functions 2.0%, the binder
0.5%. Map and Set's lookups are inlined into their callers and make no
Rig index test (they are the runtime's Zig); their Zig tests are in
`ov` and `zrest`.

## Zig's own tests, by group

Zig's overflow test is the second kind, so Zig's safety was turned off
(`@setRuntimeSafety(false)`, all of Zig's kinds at once) in a group's
functions alone. 20 rounds (r20e). This run met the kernel's noise (see
"Machine state"): ts-pattern's wall time and total cycles moved by up to
4% a round, so the user cycles and instructions are the measure here.

| Zig's tests off in | ts-pattern: fewer user cycles / fewer instructions | zod3: faster / fewer total cycles / fewer user cycles / fewer instructions | confirmed |
|---|---|---|---|
| everywhere, overflow only (`ov`) | 1.62% / 1.87% | 2.19% / 2.01% / 2.12% / 2.29% | see Kinds |
| the checker's functions, every Zig kind | 0.03% more / 0.96% | 0.93% / 0.95% / 1.09% / 0.87% | no |
| the checker's small accessors | 0.14% more / 0.15% | 1.52% / 1.60% / 1.42% / 0.14% | no: 0.14% of the instructions, within the lottery |
| Map and Set (`rig/ordered.zig`, `rig/unordered.zig`) | 0.65% / 0.32% (r20h); 0.22% / 0.32% (r20g) | 0.40% slower / 0.52% more / 0.51% more / 0.26% (r20h) | no |
| the rest of the runtime (`runtime.zig`, `alloc.zig`, `table.zig`, `sched.zig`, `tasks.zig`, `net.zig`) | 1.14% / 1.66%; faster 1.15%, total cycles 1.20% (r20h) | 0.95% / 0.92% / 1.07% / 1.34% | yes |

r20h ran after the kernel's noise had passed. So Zig's tests (`ov`, `cast`,
`zsafe` and `zrest`: 4.1% and 5.4% of the instructions by kind) are
written about a fifth in the checker's own functions (counters, `n + 1`,
id arithmetic, `@intCast` of ids: 0.96% and 0.87%), a third to two
fifths in the runtime's own Zig (1.66% and 1.34%), and the rest in the
other modules and std; Map and Set's own Zig holds 0.3%. The runtime's
share was not bisected further: what it holds is the inline helpers
inlined into every caller (List's push and growth, `rig.at`'s slice
index after `index`, the casts in `Table` and `Slot`, String's
builders), and the allocator's and the scheduler's fast paths.

## Is it layout?

Not in the sense of alignment luck: the nulls show that luck is up to
1.3% per build, in either direction, and the kinds' and groups' gains
follow their instructions, not the lottery. But in the sense of
**code size, partly**. The front end's counters (three rounds, four
event sets, `ctr/`; unmarked changes are fewer):

| counter, against main | li | all | checker | acc | ast | other | null1 |
|---|---|---|---|---|---|---|---|
| instructions, ts-pattern / zod3 | 4.6% / 6.3% fewer | 11.0% / 13.3% fewer | 3.1% / 3.4% fewer | 1.6% / 2.2% fewer | 1.1% / 2.3% fewer | 0.4% / 0.4% fewer | same |
| branches retired | 9.6% / 13.0% fewer | 22.0% / 26.5% fewer | 6.9% / 7.0% | 3.4% / 4.5% | 2.1% / 5.0% | 0.6% / 0.7% | same |
| L1i misses | 12.7% / 15.1% fewer | 22.4% / 24.9% fewer | 5.7% / 11.2% | 3.5% / 5.3% | 5.1% / 7.3% | 4.4% / 3.8% | 0.0% / 1.4% fewer |
| iTLB misses | 17.1% / 15.6% fewer | 28.7% / 32.7% fewer | 2.7% / 11.2% | 0.7% more / 3.0% | 2.8% more / 5.9% | 3.3% / 4.0% | 2.7% / 1.7% more |
| uops from the decoders (MITE) | 3.8% / 5.5% fewer | 9.6% / 12.2% fewer | 0.4% more / 0.7% | 0.2% more / 1.7% | 1.3% more / 0.5% | 0.1% / 0.2% | 0.8% / 0.6% more |
| branch misses | 2.1% / 2.9% fewer | 3.1% / 4.5% fewer | 0.5% / 1.2% | 0.3% / 0.6% | 1.0% / 0.7% | 0.1% / 0.1% | same |

Trig's code is large for the front end: 11.9 MB of `.text`, half of its
uops from the legacy decoders rather than the uop cache, and 6-8% of
its cycles in i-cache data stalls (`icache_data.stalls`). Every check
is a compare, a branch and a call to a panic function, about twelve
bytes, and the 122,000 of them (checks.md's census) are 12% of the
code. Removing a group removes its instructions and its bytes both,
and L1i misses fall with the bytes in every group, executed or not
(`other`, 0.4% of the instructions, cuts 4% of the L1i misses). The
i-cache stall cycles that fall with them are about a fifth of li's
gain on zod3 (7 of 35 million cycles); the rest is the instructions and
uops themselves, which a front-end-bound program pays for in decode
bandwidth. The branch misses are not where the cost is: every check is
predicted (2-4% fewer misses for 10-26% fewer branches).

So the gain is **diffuse**: in proportion to the checks removed,
executed and written, everywhere, with no site group above about 2% of
the instructions and no group that gains more than its share. It
appears whole only with all checks gone because it is the sum of
122,000 small costs, not because the checks interact: the kinds and the
groups each add up.

## PGO

Built as Trig ships, `--release --pgo` (each variant trained on its own
instrumented build), 20 rounds against PGO main in the same rounds
(pgo2, after the kernel's noise had passed):

| PGO build | ts-pattern: faster (IQR) / fewer total cycles / fewer user cycles / fewer instructions | zod3, trained on: the same |
|---|---|---|
| main (835.5 ms, 159.0 ms) | | |
| `li` | 3.09% (1.49 to 5.01) / 3.18% / 3.28% / 5.09% | 3.91% (2.27 to 5.63) / 3.63% / 4.14% / 6.61% |
| `accast`, the accessors and the AST | 2.27% (-1.50 to 3.33) / 2.25% / 2.50% / 2.76% | 3.63% (0.82 to 4.99) / 4.21% / 4.62% / 4.65% |
| `ov` | 1.50% (0.17 to 3.85) / 1.69% / 2.10% / 2.21% | 0.02% slower / 0.51% / 1.28% / 1.76% |

The plain builds' gains hold under PGO: li's is as large (3.1% and 3.9%
faster against 2.8-3.3% and 3.0-4.5%), with more of its instructions
(5.1% and 6.6%), and accast's is 2.3% and 3.6%: what PGO lays out by
profile does not take the checks' cost away. An earlier PGO run (pgo1,
during the kernel's noise) read li at 1.61% and 3.10% faster, 3.22% and
3.37% fewer user cycles: the same in user cycles.

## The cheapest Rig-side form for each group of 0.5% or more

Each group that removes at least 0.5% of the instructions or the time,
with the form that would remove it soundly and what it is worth. None
of them is a change to the compiler's passes, and none lands in
`src/storage.zig`, `src/emit.zig`, or `List.popAt` (#755's draft).

1. **The checker's accessors (`acc`): 1.6% and 2.2% fewer
   instructions, 1.1% and 2.2% faster.** `Ids.sym_loc[s]`,
   `node_base[f - 1]`, `sym_base[f]`, `tab_loc[t]`, the symbol tables
   and the link accessors, Lists indexed by ids that one append-only
   store makes. **An index type, Trig-side**: those Lists as
   `Table[T, n]` and the ids as `Slot[n]` (built, #536), as checks.md
   §4.1 ("more stores on slots") planned; an id read back from a `U32`
   word is tested once where it is decoded (`Slot[n].of(w)`). Rig has
   what this needs. The one-compare signed index (#753's item 4) takes
   only the signed sites among them (`node_base[f - 1]`), already
   measured there at 0.3% and 0.4% of the instructions.
2. **The AST's record reads (`ast`): 1.1% and 2.4% fewer instructions,
   1.0% and 1.3% faster, 4.0% of the code.** `recs[n.id]` in `kind`,
   `flags`, `pos`, `parent`, and the parser's and lexer's own lists.
   **An index type, Trig-side**: the node records in a `Table`, per
   program or per file, and `Node.id` a `Slot` (checks.md §4.1; its
   `NodeRec` needs field defaults for the zero rule, and a table past
   the made fill's 64 MiB is reserved, not made).
3. **Groups 1 and 2 together (`accast`)**: plain, 2.0% and 2.5% faster,
   2.0% and 2.4% fewer total cycles, 2.7% and 4.5% fewer instructions;
   with PGO, 2.3% and 3.6% faster, 2.8% and 4.7% fewer instructions.
   This is checks.md's typed2 stand-in again, which measured 1.3% and
   3.8% faster on pup.
4. **The rest of the checker's List tests: about 1.0% and 0.9% of the
   instructions, about 0.7% of the time**, in 1,570 sites of ordinary
   function bodies (`members.rig`'s 191 are 0.6% and 0.2% of the
   instructions and no time). A **proof** reaches the loop indexes among
   them, and proofs.md found such proofs worth nothing measurable; under
   the lottery, not worth a form.
5. **Zig's overflow tests (`ov`): 1.9% and 2.3% fewer instructions,
   1.3-1.6% faster on ts-pattern and 0.6-2.1% on zod3.** About half
   are written in the checker (0.96% and 0.87% of the instructions with all
   of Zig's kinds): Trig's counters and id arithmetic, which **Trig**
   can write wrapping (`+%`) where its stores bound them, or which a
   **recorded fact** could prove: a `Slot[n]` is below `n`, so a slot
   plus a small constant fits its integer (`src/proofs.zig`, as §4.2's
   `fits` facts for lengths, which that record put at 0.2-0.4%). The
   rest is in the runtime, and that share is Rig's alone: see 6.
6. **Zig's tests in the runtime's own Zig: 1.7% and 1.3% fewer
   instructions, 1.2% and 1.0% faster** (all of Zig's kinds off in
   `rig/runtime.zig`, `alloc.zig`, `table.zig`, `sched.zig`, `tasks.zig`,
   `net.zig`). **A runtime edit, class (a)**: the hot inline helpers'
   arithmetic and casts written where the runtime's own invariants
   already prove them (`len <= buf.len`, `len < max_len`, a slot below
   `n`) under `@setRuntimeSafety(false)` or with wrapping operators, as
   `provenOffset` and `List.push` already are; each such block is an
   argument to review, not a fact the checker records. It is the one
   group a Rig change alone could take, and it clears the instruction
   bar on both projects (1.66% and 1.34%), though not the time bar
   (1.15% and 0.95%); not built with PGO.
7. **Below the lottery, not confirmed:** a Table's integer index (`ti`,
   1.3% and 0.8% of the instructions, 0.9% of them the store's span
   reads `type_lists[start + k]`, which `Span[n]` took and gained
   nothing for, proofs.md), `@intCast` (0.7% and 1.0%), Zig's own index
   and other tests (`zrest`, 1.3% and 1.6%), slice bounds, unwraps,
   `unreachable`, and a Table's full test (each under 0.6%).

**Against Trig's bar** (more than 1.5% faster, or at least 1% fewer
instructions): groups 1 and 2 each clear it by instructions alone (1.6%
and 1.1% on ts-pattern, more on zod3), and together they clear it by
time too: 2.3% and 3.6% faster with PGO, 2.8% and 4.7% fewer
instructions. Both are Trig's move onto Rig's existing `Table` and
`Slot`, not a Rig build. Of what Rig could build, only the runtime's own
Zig (6) clears the instruction bar (1.7% and 1.3%), and not the time
bar. Overflow (5) clears it only as a whole kind; the share a recorded
fact could take is under the bar on its own.

## Machine state

From about 10:40 to 13:00 pup's memory was fragmented by other
sessions' builds (no free 2 MiB blocks in `/proc/buddyinfo`), and the
kernel's share of ts-pattern's cycles rose from 0.26G a run to a median
of 1.7G (up to 3.3G): Table huge pages (#754) fault, and compact, in the
kernel. User cycles and instructions did not move (main 4.3-4.5G user
cycles throughout). The runs in that window are pgo0, pgo1, r20e and
r20f; for them the user cycles and instructions are the measure, and
ts-pattern's wall times there are not used. A runner that judges by
total cycles on pup should check the kernel's share against a quiet
baseline first.

Builds took 13 minutes plain and 23 minutes with PGO; 31 in all
(`builds.txt`), with other sessions' builds alongside.
