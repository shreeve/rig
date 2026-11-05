# Packed Tables: Tables of zeros held in the heap until they outgrow a huge page (2026-11-04)

Fix 1 of [investigation.md](investigation.md): Trig's Tables, 43 a
checker, each reserved at its largest size with its first 2 MiB on small
pages in a mapping of its own, cost it page faults, page walks, TLB
shootdowns and exit time that grow with checkers. The foreman's go
(the owner's of 2026-11-04 for allocator and arena work): prototype a
denser placement on branch `table-arena`, landing only if Trig's timing
clears the bar, with peak memory no higher.

## Soundness: no rule changes

A table that moves when it grows is sound under the Core as it stands.
CORE §5, "Tables": a slot is a place of the table, like a List's
element; it is read in place, lent with `?t[s]` or `!t[s]`, and assigned;
`!t.push(x)` lends the table to write; and "no rule here changes for it".
A slot's view is a loan on the table, so no write to the table, a push
or an assignment of any slot, happens while one is live (CORE's own
rejected example: `a = ?t[s]` then `!t.push(2)`). Emit reaches a written
slot with `slot` and every other with `constSlot` or `at`
(`Facts.isTableWrite`), so only a write can grow a table. `table.zig`'s
Committed mode, built for targets without lazily zeroed pages and run
by `test/cli/table_reserve.sh` under `RIG_TABLE_FALLBACK`, already
moves a table on a write. The packed mode is that mode with a bound:
CORE needs no change.

## The design

`table.zig`, a Table of zeros on a target with lazily zeroed pages:

- **Packed.** It starts holding nothing (`cap` 0). A write at or past
  `cap` grows it into a heap block of at least twice `cap` (64 slots
  first), zeroed, copying what it held (`grow`); a read past `cap` reads
  a zero `T` and grows nothing. The small tables of one thread share the
  heap's pages (huge where the heap asks for them) instead of each taking
  pages, a page of page table, and a mapping of its own.
- **Spilled.** A table whose `n` slots take more than `pack_bytes` (one
  huge page, 2 MiB) moves once, for good, into its reserved range
  (`spill`, `cap` = `n`) on the write that would take it past 2 MiB, or
  on one that jumps past twice `cap` and a page more. One that filled its
  2 MiB asks for huge pages from its first byte (`reserveTable`'s new
  `dense`), since its first huge page is full; one that jumped keeps
  today's small-page head, since it is sparse.
- Debug builds take the same path, through the leak-checked allocator,
  so the suite's leak checks and `RIG_SANITIZE` see the heap blocks. A
  table of zero-sized slots stays reserved, as before.

The cost is one compare on each slot read and write (`i >= cap`), the
copies as a table doubles (at most twice its final size, up to 2 MiB),
and one copy of up to 2 MiB when it spills.

## Measured: slower, and more memory

Trig's PGO build (the Trig tree of
[investigation.md](investigation.md), built by `tools/trig/pgo` with Rig
3fe58d632 and this branch's `table.zig` and `alloc.zig` copied over the
program's runtime before each compile, [arena-zig](arena-data/arena-zig);
sha256 `b514a72cb5380cd6`) against the same build without them
(`e4e3e99e0efdba59`). pup E-cores as in the investigation, 20 shuffled
rounds in one timing slot (20:36-20:38; 1 free 2 MiB block after
compaction, so neither build got huge pages for new ranges). Every run
printed tsc's output ([ab-summary.md](arena-data/ab-summary.md)):

| | C | wall, fastest | user+kernel cycles | user instructions | page walks, % of user cycles | page faults | peak RSS |
|---|---:|---|---|---|---|---|---|
| ts-pattern | 1 | 1,215.8 → 1,328.0 ms, 9.2% slower | 9.3% more | 17.8% more | 4.48 → 1.47 | 31.9K → 30.7K | 204 → 221 MiB, 8.2% more |
| | 4 | 514.5 → 572.9, 11.3% slower | 10.8% more | 17.7% more | 4.24 → 0.78 | 40.0K → 35.3K | 229 → 274, 19.7% more |
| | 8 | 444.3 → 477.8, 7.5% slower | 11.4% more | 17.6% more | 4.29 → 0.75 | 47.3K → 38.8K | 248 → 306, 23.7% more |
| zod3 | 1 | 212.7 → 225.6, 6.1% slower | 8.7% more | 14.4% more | 2.95 → 0.50 | 6.5K → 5.0K | 71 → 80, 12.8% more |
| | 4 | 125.2 → 139.7, 11.7% slower | 10.8% more | 15.2% more | 3.59 → 0.62 | 15.0K → 12.0K | 95 → 112, 17.4% more |
| | 8 | 113.9 → 124.9, 9.6% slower | 10.8% more | 15.6% more | 4.31 → 0.93 | 21.4K → 19.1K | 113 → 138, 22.4% more |

Near the end of a run and at exit ([shape.txt](arena-data/shape.txt),
[exit.txt](arena-data/exit.txt), same slot conditions, ts-pattern at
eight): page tables 3.4 → 1.3 MiB, mappings 480 → 516 (with the gate
shut neither build splits its Tables' region much), exit 30.8 → 38.1 ms
by the median, TLB flushes 19.5K → 15.7K a run.

- **What it wins is what the investigation predicted:** page walks fall
  from 4.2-4.5% of user cycles to 0.8-1.5% on ts-pattern (3.0-3.5 points),
  and page tables to a third.
- **What it costs is more.** Every slot read now tests `i >= cap`, and
  Trig reads Tables everywhere: user instructions rise 14-18% at every
  checker count, spread over the whole checker rather than in any one
  function ([instructions.txt](arena-data/instructions.txt)). The heap
  blocks are zeroed whole and grow by doubling, so what was 4 KiB pages
  touched only where written is now every slot up to `cap`: peak memory
  8-24% higher, and the exit tears down more of it.
- **Faults barely move** (4-18% fewer): the heap's segments and large
  blocks fault too, on small pages when no huge ones are free.

So the packed mode does not clear the bar: 6-12% slower, with peak memory
higher. It is not taken.

## What this leaves

- **A table's density cannot come without a test on every read.** A
  table whose reads need no test has to keep every slot it may read at a
  fixed address, which is a reservation of all `n`; packing many tables'
  slots onto shared pages means a read past what is held must be caught,
  and on Trig that test costs several times what the page walks do
  (10-11% more cycles against 3-3.5 points of page walks saved).
  The variants considered and set aside for that reason: a packed head
  with a reserved tail (a test on each read), and moving only on writes
  while reads stay untested (unsound: a read past the block).
- **Denser Tables are Trig's to choose:** fewer, larger Tables a checker,
  or ids numbered so each checker writes its Tables from the front, would
  touch fewer pages and page tables with no change to how a Table is
  read.
- **The exit (investigation, fix 2)** has no cost on any access and a
  ceiling of 13-18 ms on ts-pattern at four and eight checkers; it is the
  next Rig-side candidate, after the owner's call.

## Method

- The arena arm was built on pup's E-cores (`TRIG_RELEASE_SLOTS="12,13,14,15 16,17,18,19"`)
  through Trig's `tools/release-slot`, in `/zfs/rig-work/scaling/trig-arena`
  (a copy of the Trig tree the base was built from), 19:44-20:35.
- Timing: [ab.sh](arena-data/ab.sh) in [slotab.sh](arena-data/slotab.sh),
  `cpuq` clear and no Trig timing running; summary by
  [abtab.py](arena-data/abtab.py) from [ab.txt](arena-data/ab.txt).
  Shapes and exits: [shape.sh](arena-data/shape.sh) in a second slot.
- The branch's core suite passed on the Mac (11,462 cases), with new
  cases in `test/rig/table.rig.test` for a packed table that grows past
  2 MiB, one written far past what it holds, a read past what it holds,
  and many small packed tables, each in debug and release builds.
