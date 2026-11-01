# A Table that reserves at its first write: built, measured, stopped (2026-11-01)

Queue row 50. Trig's phase B of typed ids (Trig research 21, branch
`typed-ids-b` at `ee409cb`) gives each Ast a `Table[NodeRec, 2^22]`, a
96 MiB reservation. A run makes 256 to 2,047 Asts, most of them
placeholders, and on both machines the reservations cost more than the
untested lookups save. Research 21 asked Rig for a Table that holds no
reservation until it is written.

**Answer: built and correct, but it does not pay, so it is not merged.**
The code is kept as tag `archive/lazy-table` (`d5e670615`).
- Phase B's Asts all write their table at birth: `Ast.new()` pushes a
  nil NodeRec (src/ast/ast.rig:172). So a lazy Table changes nothing for
  `ee409cb` as it stands (`pblazy` against `pbbase`, below).
- In a measurement arm whose Ast pushes its nil record with its first
  node (`pbdefer`), laziness removes about half of phase B's kernel cost.
  Phase B still loses to Trig main by 1.8–24% of wall time on pup and
  1.2–84% of instructions on the Mac. The Asts that do hold nodes still
  each reserve, fault and give back a table.
- On Trig main, where every table is written, the lazy Table costs a
  little: on pup 0.08–0.36% more user instructions and up to 1.5% more
  peak RSS. That is within the A/A spread for time, but it is a cost
  with no gain.

## The design as built

All of it is in `src/table.zig` and `src/alloc.zig` (`tableZeros`), on
the archive tag. It applies to reserved tables only (plain data whose
`T()` is zero bytes); made and committed tables are unchanged.

- **The zero range.** An unwritten table's `slots` points into one
  read-only, `MAP_NORESERVE` mapping that every unwritten table shares,
  so a read of any slot reads zeros with no test.
  - The first version mapped 256 GiB, a region's width, once. That cost
    Trig main 0.2–0.8% of its instructions on the Mac, because macOS
    charges for mapping and tearing down a range by its width. A micro
    test measured about 1.5M instructions more for 256 GiB than for
    1 GiB.
  - So the range is mapped at the first table's width, rounded up to a
    power of two and at least 64 MiB. A wider table maps a wider range,
    and the narrower one stays for the tables that point into it.
  - After that change Trig main's instructions on the Mac are within the
    A/A spread (-0.3% to +0.27%).
- **`push`** compares `len` with a field `lim`, which is 0 until the
  table reserves and `n` after. A compare with a load in place of an
  immediate keeps the instruction count of the compare with `n`.
  - At the limit, a cold block either reserves or panics full. The
    reservation is a `noinline` cold function that takes no `self` and
    returns the range, and the block stores `slots` and `lim`.
  - A first cut passed `self` to a cold `pushPast`. LLVM then kept `len`
    in memory in a tight loop, and lost its proof that a fresh table
    pushed 1,000 times is never full. With `self` out of the call, the
    loop compiles to main's code (disassembled on arm64 at
    `--release=fast`).
  - A tight push loop, stack-held and object-held
    ([pushloop.rig](lazy-table-data/pushloop.rig),
    [micro-pushloop.txt](lazy-table-data/micro-pushloop.txt)), runs
    within 0.2% of main's instructions and 1.2% of its cycles.
- **A write through a slot** (`slot()`) tests `lim == 0` once, cold.
  Reads (`at`, `constSlot`) make no test.
- **Drop.** A table never written does nothing.
- **Leak tokens.** In leak-checked builds the leak token is taken when
  the range is reserved.
- **Which builds are lazy.** Linux and leak-checked builds only. macOS
  has no shared zero page: each page of the zero range read commits a
  page of its own, so a table read before its first write holds those
  pages twice. On Trig main that raised the Mac's peak RSS by up to 1%,
  so a release build on macOS reserves as the table is made.

## Views across the first write

The first write moves `slots` from the zero range to the table's own
range. The design is sound only if no view of the table, or of a slot,
lives across a write.
- On `origin/main` (`cce83d2aa`), the ownership checker rejects every
  such form tried:
  - a slot view, a field view and a table view, each across a `push` and
    across `t[s] = x`;
  - a slot and a table lent to one call;
  - a `for` over `?t` that pushes;
  - a view returned `from` a function;
  - a view held in an object or in a closure;
  - a slot of a table held in an object;
  - two write views of slots of one table.
- The archive tag keeps the 14 forms as `fail` cases in
  `test/rig/table.rig.test` (the oracle rejects each too; 14 lines in
  `test/oracle/rejections`).
- A committed table already moves `slots` in `grow`, so the rule was
  already load-bearing.
- Raw code that keeps a pointer from before the first write reads stale
  zeros, and a write through it faults on the read-only range.

**Same-statement temporaries.** These are the places emit takes a
`slot()` pointer to in a statement that also reserves:
- `t[0].x = Int((!t).push(r))`;
- `t[0] = R(x: Int((!t).push(r)))`;
- `t[(!t).push(r)].y = 1`;
- `t[0].x += f(!t)` with `f` writing the table;
- `t[0] = R(x: f(!t), y: t[1].x)`.

Each is accepted and correct under `RIG_SANITIZE`. Emit evaluates the
value into a `__rig_new_N` temporary, or the index into `__rig_ix_N`,
before it takes the slot pointer, as CORE §6's evaluation order has it.
So the reservation always happens before the pointer is taken. They are
`test` cases on the tag. `swap(!t[0], !t[1])` is rejected (its message
suggests `!t.swap(0, 1)`, which a Table does not have; noted for the
diagnostics backlog).

## Measurements

Arms, all release builds as `rig build --release` makes them
([emit.sh](lazy-table-data/emit.sh), [mk.sh](lazy-table-data/mk.sh),
[builds.txt](lazy-table-data/builds.txt)), with `CHECK_IDS` off:

| Arm | Trig | Rig |
|---|---|---|
| `mainbase` | main `a1cd16c` (its src the same as `4bc7a9a`) | main `cce83d2aa` |
| `mainbase2` | a byte-identical copy of `mainbase` (A/A) | |
| `mainlazy`, `mainlazy2` | main | lazy, with a 256 GiB zero range, then sized to need |
| `pbbase` | `ee409cb` | main |
| `pblazy` | `ee409cb` | lazy (256 GiB) |
| `pbdefer`, `pbdefer2` | `ee409cb`, the nil record pushed with an Ast's first node ([pbdefer.diff](lazy-table-data/pbdefer.diff)); a measurement arm only, in which an Ast with no node reads its nil record as zeros, which the output check covers | lazy, 256 GiB then sized |

Every arm printed the same bytes and exit status as `mainbase` on
every project.

### The Mac, one checker

Setup:
- [bench.py](lazy-table-data/bench.py) with arms in an order shuffled
  each round, through `tools/low`;
- 60 rounds of `empty`, mitt, neverthrow and superstruct, and 20 of
  ts-pattern and zod3;
- this `empty` is one `export {}` file with the default libs, so it
  parses about as much as superstruct.

Results are in [mac-c1.txt](lazy-table-data/mac-c1.txt), and with the
sized range in [mac-c1-zero-sized.txt](lazy-table-data/mac-c1-zero-sized.txt).
Instructions retired, minimum against `mainbase`:

| Arm | empty | mitt | neverthrow | superstruct | ts-pattern | zod3 |
|---|---:|---:|---:|---:|---:|---:|
| mainbase2 (A/A) | 0.04% more | 0.06% more | 0.13% more | 0.03% fewer | 0.06% more | 0.06% fewer |
| mainlazy (256 GiB) | 0.37% more | 0.75% more | 0.66% more | 0.70% more | 0.17% fewer | 0.18% more |
| mainlazy2 (sized) | 0.19% more | 0.07% fewer | 0.14% fewer | 0.05% fewer | 0.30% fewer | 0.08% more |
| pbbase | 119% more | 47% more | 16% more | 175% more | 3.5% more | 14% more |
| pblazy | 121% more | 48% more | 18% more | 178% more | 3.6% more | 15% more |
| pbdefer2 | 58% more | 14% more | 7.4% more | 82% more | 1.5% more | 5.8% more |

Peak RSS:
- mainlazy2 is 0.2–1.0% higher (the zero range's read pages, above);
- every pb arm is 1–98% higher (98% on `empty` and 87% on superstruct).

### pup, E-core 13, one checker

Setup:
- the arms were cross-built on the Mac for pup's target;
- [ecore.sh](lazy-table-data/ecore.sh): `taskset -c 13 perf stat
  --no-scale` with the program, `cpu_atom` events;
- arms shuffled per round, 7 rounds of the four small projects and 5 of
  ts-pattern and zod3, outside Trig's suite.

Medians against `mainbase` are in
[pup-ecore-summary.txt](lazy-table-data/pup-ecore-summary.txt), with raw
lines in [pup-ecore.txt](lazy-table-data/pup-ecore.txt). Wall time and
kernel instructions:

| Arm | empty | mitt | neverthrow | superstruct | ts-pattern | zod3 |
|---|---:|---:|---:|---:|---:|---:|
| mainbase2 wall (A/A) | 1.4% slower | 2.0% faster | 3.5% slower | 1.8% slower | 3.2% faster | 0.9% faster |
| mainlazy2 wall | 0.5% faster | 3.0% slower | 4.9% slower | 5.0% slower | 0.9% slower | 0.4% slower |
| pbbase wall | 39% slower | 3.9% slower | 5.9% slower | 45% slower | 1.3% slower | 3.1% slower |
| pbdefer2 wall | 21% slower | 0.6% faster | 7.6% slower | 24% slower | 2.1% slower | 1.8% slower |
| pbbase kernel instructions | 205% more | 20% more | 12% more | 198% more | 6.5% more | 16% more |
| pbdefer2 kernel instructions | 101% more | 4.5% more | 6.0% more | 92% more | 3.5% more | 6.0% more |
| pbdefer2 user instructions | 1.7% more | 3.8% more | 3.6% more | 1.7% more | 0.7% more | 1.7% more |
| mainlazy2 user instructions | 0.15% more | 0.08% more | 0.10% more | 0.23% more | 0.18% more | 0.36% more |
| mainlazy2 peak RSS | 0.57% more | 1.5% more | 0.30% more | 0.39% more | 0.12% more | 0.39% more |

So by the rule set for this row, P-core timing was not asked for:
`pbdefer2` loses outside the A/A spread on four of six projects, and is
level only on mitt's wall time.

## For Trig

This is the finding only, since Trig owns its performance. Every
phase-B Ast writes its table as it is made, because `Ast.new()` pushes
a nil NodeRec (src/ast/ast.rig:172). So placeholders and never-written
Asts each cost a reservation, a fault and a giveback, lazy Table or
not. With the nil push moved to an Ast's first node, a lazy Table halves
phase B's kernel cost on pup. What is left is the Asts that hold nodes,
each with a table of its own: 3.5–101% more kernel instructions than
main, and 0.7–3.8% more user instructions. Phase B pays only if those
Asts stop owning a table each.

## What else this showed

- **macOS read faults commit memory.** On macOS a read fault on a
  private anonymous mapping commits a page. Reading 1 GiB of a
  read-only range raised peak RSS by 1 GiB, in 65,536 faults. Linux
  maps its zero page.
- **macOS charges by width.** macOS charges for a mapping by its width
  even when nothing is touched, about 6K instructions per GiB between
  1 GiB and 256 GiB.
- **The swap message.** It suggests a `swap` method to a Table, which
  has none.
