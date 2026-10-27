# Bounds tests and checked enum conversion in Trig (2026-10-26)

**Question.** Trig (fork)'s disassembly diff against tsrs (ts-pattern,
one thread, Trig PGO on Rig 9822afed9, tsrs PGO with symbols;
`pup:/zfs/trig-pup/trial/dis/REPORT.md`) charged two Rig patterns with
cycles tsrs does not pay: row 4, bounds tests (`heldIndex` 107M,
`index` 42M, `provenOffset` 13M: 217M cycles against tsrs's 39M), and
row 8, `std.enums.fromInt` (37M against 0). Earlier work had proven
tests away and saved nothing ([proofs.md](proofs.md)), so what in
these tests costs more than Rust's one compare and branch?

**Answer.** Almost nothing. Each test is the one compare and branch
Rust makes, with the length read from the same cache line as the
pointer, as a `Vec` field's is. The cycles the report puts on them are
sampling skid: the profile used plain `cycles/u` and `instructions/u`,
which charge a load's cache miss to the instructions that follow it,
and a test is usually the first instruction to use a loaded index. One
shape did cost an extra instruction: a signed index against a bound
known at compile time (a `Table`, an array, `Slot[n].of`) made a sign
test and a bound test. That is now one compare. Trig: 0.5% fewer
instructions on ts-pattern and 0.8-1.0% on zod3, times within the
noise: under the bar.

## 1. What a test executes (Trig PGO, pup, x86-64)

The hot sites, from the report's binary:

| site | instructions | Rust's |
|---|---|---|
| `List` element, signed index (`heldIndex`) | `cmp len(%r),%idx; jae panic`: one fused compare and branch, the length a load beside the pointer's | the same, for `v[i]` on a `Vec` field |
| `List` element, `U32` index (`heldIndex` falls back to `index`) | the same: the cast is a zero extension already made | the same |
| `Table[T, 1<<28]` element by a computed `Int` known non-negative (the array mapper's `start + k`) | `cmp $0x10000000,%r12; jae panic`: no load | none (a slice iterator) |
| `Table` element by a computed `Int` of unknown sign (`x - y - 1`, `get_type_of_symbol`, `set_structured_type_members`) | `add; js panic; cmp $0x4000000; jae panic`: **two tests** | one |
| Map `find`: `@table.at[i]`, then `@es[j]` | `cmp at.len; jae; mov es.len; mov at.ptr; mov at[i]; cmp es.len; jbe`: two tests, each one compare | none (hashbrown is unchecked) |
| `text.Interner.text`: `@ends[i - 1]`, then `@ends[i]` | two tests, and `ends.ptr` loaded twice | two tests |
| `TypeMapperKind.from_int(b >> 27) ?? .Unknown`, then `match` | `shr; dec; cmp $7; ja; jmp *table`: one compare, the conversion's and the jump table's range test merged | `jmp *table`: the enum's range is known from its type |

None reloads a length the loop already holds, widens the index first,
or sets up the panic on the hot path; the panic calls are out of line,
one block per function, shared by every test in it.

**Where the report's cycles come from.** At the hottest `heldIndex`
site (`instantiate_type_with_alias+0x7c45`, the Map's `@es[j]` after
`j = @table.at[i]`), the compare `cmp %rbp,%rcx` holds 31 cycle samples
and the load `mov (%rdx,%rbx,4),%ebp` before it none: the load misses,
and the sample lands on the first instruction waiting for it. Row 8 is
the same: at `mapper_map+0x3d` (`cmp $7`) the plain profile has 149
cycle and 181 instruction samples on one compare. With PEBS
(`cpu_core/cycles/upp`, 10 runs) the cycles move to the load of
`@store.mappers[x].b` (`mapper_map+0x30`, 46 samples) and with PDIST
(`instructions/uppp`) the seven instructions from the load to the
branch get 17-41 samples each, as instructions executed equally often
should. tsrs pays the same misses; its loads are charged to its own
functions. The 5.6× is the number of tests, not their cost: tsrs's
`P<T>` pointers and hashbrown make none where Trig's ids into Lists
and Tables make one.

**What the tests cost in all.** Under PEBS, 3.35% of ts-pattern's
instruction samples and 3.30% of its cycle samples fall on the compare
and branch of an index test (43,136 and 20,238 samples; 74,738 test
sites in the binary). The classes, by instruction samples:

| class | sites | instruction samples |
|---|---:|---:|
| compare against a length in memory | 26,102 | 568 |
| a second test beside another (Map `at` then `es`, `files[f-1]` then `recs[n]`, Interner) | 13,653 | 431 |
| compare against a constant (`Table`, arrays) | 3,404 | 124 |
| sign test after an add, then a constant bound (the two-test shape) | 2,181 | 132 |
| compare against a length in a register | 13,388 | 102 |

Only the two-test shape costs more than Rust's test. Removing every
test would save at most the 3.35%, which is the measured ceiling's
order ([checks.md](checks.md) §1, 5.9% on a plain build); a type or a
proof reaches only the tests it covers, as #686 and #687 found.

## 2. Row 8: the checked enum conversion

`rig.enumFromInt` is `std.enums.fromInt`, whose loop over the
variants LLVM folds into one range compare for a dense enum
(`kind_of` alone: `lsr; cmp $8; csel`). Trig's hot sites read the
integer from bits of a packed `U32` (`mapper_kind`: `b >> 27`, five
bits that may hold 9 to 31), so the test can fail and stays; no Trig
site converts an integer that came from the enum in the same body, so
a checker fact that the conversion cannot fail has nothing to apply
to. The three instructions per `mapper_map` call (about 15M calls on
ts-pattern, so about 45M instructions, 0.5%) are the `match`'s jump
table test merged with the conversion's: a probe that stores the kind
as its own enum field and matches it with `_ => pass` compiles to the
same `sub; cmp $7; b.hi`, since Zig gives LLVM no range for an enum it
loads. Nothing is changed here.

## 3. What changed

- `rig.indexBelow(i, n)` and `rig.offsetBelow(i, n)` (`src/runtime.zig`):
  an index against a bound `n` known at compile time, up to `2^63`, is
  one unsigned compare, since a negative `i` read as unsigned is at
  least `2^63`. Exact, with no assumption: the same test, in one
  instruction. `Table`'s `atInt`, `constSlotInt` and `slotInt`,
  `Slot[n].of`, a vector's lane, and an array's element (emit writes
  `rig.indexBelow` where it wrote `rig.index` with the array's length)
  use it. `rig.index` keeps the two tests for a count known only at run
  time; a held length takes `heldIndex`'s one compare, as before.
- `text.Interner.text` reads the end of its string first, so `ends` is
  reached through one pointer load (the second test stays: LLVM does
  not derive `i - 1 < len` from `i < len` and `i != 0`).

New cases: a `Table` read by a negative and by a too-large computed
`Int` panics in a release build; `Slot[n].of` of -1, `Int.min`, `n`
and a value past `2^62` is none in a release build; an array read by
-1 panics in a release build.

## 4. Trig numbers

Trig main `4e7d861`, `rig build --release --pgo` trained by
`tools/trig/bolt-train`, by Rig main `5a79e02f2` (base) and by this
branch (new). pup core 8 (9 idle), one checker, interleaved, order
reversed each round, fastest of 10; outputs byte-identical. pup was
running other agents' release builds on other cores (load 2.5-3).

| project | build | task-clock | wall | user cycles | instructions |
|---|---|---:|---:|---:|---:|
| ts-pattern, round 1 | base | 1,010.7 ms | 1,017.6 ms | 4,015.64M | 8,664.52M |
| | new | 1,011.8 ms | 1,019.6 ms | 3,999.31M | 8,623.33M |
| ts-pattern, round 2 | base | 969.5 ms | 976.8 ms | 3,925.39M | 8,668.01M |
| | new | 969.4 ms | 977.5 ms | 3,905.00M | 8,619.99M |
| zod3, round 1 | base | 189.3 ms | 192.5 ms | 720.05M | 1,513.21M |
| | new | 190.2 ms | 193.4 ms | 717.49M | 1,498.37M |
| zod3, round 2 | base | 182.7 ms | 185.7 ms | 699.32M | 1,513.11M |
| | new | 185.0 ms | 188.6 ms | 707.59M | 1,501.55M |

ts-pattern: 0.48% and 0.55% fewer instructions, 0.41% and 0.52% fewer
cycles, the same time. zod3: 0.98% and 0.76% fewer instructions,
cycles 0.36% fewer and 1.2% more, time within 1.3% either way. Under
the bar (more than 2% faster, or at least 1% fewer instructions).

BENCHES

## 5. What would reach the rest

The tests left are each one compare; what removes them is fewer
tests, not cheaper ones:

- **Map and Set probing** (row 1's family): `tags` and `at` as one
  allocation with one length removes the `at[i]` test, and an entry
  index only the Map makes removes `es[j]`'s ([checks.md](checks.md)
  §4.4, owner decision 5). Keeping tag and entry index in one word
  would also remove a dependent cache miss per lookup, which is worth
  more than either test.
- **Trig's `mapper_kind`**: the kind in its own byte would still take
  the jump table's test (§2), unless emit gave LLVM the enum's range,
  which Zig does not express for a load.
- **Ids as slots** ([checks.md](checks.md) §4.1): Trig's lookups by
  stored `U32` ids into Lists (`@program.bindings[f - 1].recs[n]`) are
  the largest class; typed as `Slot[n]` into a `Table` they make none.

## Files

Scripts on pup in `/zfs/worktrees/rig/bounds-enum/`: `buildtrig.sh`
(the PGO builds), `ab.sh` (the interleaved timing), `pprof.sh` (PEBS
profiles), `bench.sh` and `jsonab.sh` (std.json and bench/hash). The
census and site scripts are in `/zfs/trig-pup/trial/dis/`
(`census.py`, `sites.py`, `chains.py`), beside the report's.
