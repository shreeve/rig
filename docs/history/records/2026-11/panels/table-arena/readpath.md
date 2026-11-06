# Packed Tables: the read path (panel table-arena, lens readpath)

Expert lens: `src/table.zig`, how emit reaches a slot (`src/emit.zig`),
and `src/proofs.zig`. Everything here was read on origin/main
`cf6a362a6` and the tag `archive/table-arena` (`4f238f041`, base
`11df1f2c1`; `src/table.zig` is unchanged on main since that base). The
probes were built on the Mac through `tools/low` in
`the panel's scratch folder (not kept)`.
Trig was not timed.

## 1. The base cost, and what the packed build added

### How emit reaches a slot

`emitIndex` (src/emit.zig:7477-7491) writes `t.at(s)` for a copied read,
`t.constSlot(s).*` for a read in place, and `t.slot(s).*` for a write
(`Facts.isTableWrite`). A `Slot[n]` index needs no test, since its type
bounds it (`offset`, src/table.zig:219, asserts that only in debug
builds). An integer index goes through `index` (one `indexBelow` test
against `n`).

- On main, a reserved Table's `constSlot` (src/table.zig:230) is
  `&self.slots[i]`, and so is `slot` (:237).
- In the archive, a packed Table's `constSlot` (archive table.zig:267)
  is `if (i >= self.cap) return &zero; return &self.slots[i];`.
- In the archive, `slot` (:274) is `if (i >= self.cap) self.grow(i)`.
  `grow` (:306) is `noinline` and `.cold`, and it returns.

### The probe

The probe is a Rig program (`t.rig`) shaped like Trig's store
(`store_generated.rig`). It holds `Table[Type, 1 << 27]`, with a 28-byte
`Type` of U32 fields and `Slot` fields, and `Table[Literal, 1 << 26]`.
Its methods are written as Trig's accessors are:

- `literal_fresh` is `@store.literals[@store.types[t].data].fresh`;
- `flags` reads one field;
- `chase` is a pointer chase through `base`;
- `set_fresh` writes one field of a slot.

It was emitted with `bin/rig build --release=fast`. The emitted
`__rig_main.zig` then got export wrappers (`probes.zig`), and was compiled
`-O ReleaseFast` three times:

- A, with main's `table.zig`;
- B, with the archive's `table.zig`;
- C, with my branchless variant (below).

Each was built for arm64 (the Mac's CPU) and for x86-64 Linux
(`-mcpu x86_64_v3`, as pup would run it). The counts are of instructions
in each export, and the hot path is read by hand.

| probe | arm64 A | arm64 B | arm64 C | x86 A | x86 B | x86 C |
|---|---:|---:|---:|---:|---:|---:|
| `flags`: one read | 8 | 15 | 11 | 10 | 13 | 13 |
| `literal_fresh`: two chained reads | 11 | 27 | 15 | 14 | 27 | 20 |
| `set_fresh`: a read and a field write | 11 | 33 | 29 | 14 | 36 | 36 |
| `push` | 20 | 36 | 36 | 18 | 38 | 38 |
| `push` twice, values used after | | | | 37 | | 70 (C plus an out-of-line slow push) |

### Per read, on the hot path

- **arm64.** A takes 4 instructions: `ldr base; mov #28; umull; ldr`.
  B adds 5:
  - a zero-extension;
  - `ldr cap`;
  - `cmp`;
  - `b.ls`;
  - an unconditional `b` around the arm that loads `&zero` (`adrp+add`).

  So every read takes one taken branch, plus the conditional one.
- **x86-64.** A is about 6 instructions (`*28` is a chain of `lea`).
  B adds 3: `mov eax,&zero; cmp [rdi+16],rcx; jbe`. The record's
  14-18% was measured on pup, which is this column.

### Per write

The write is where the cost doubles. A returning call on the hot path
defeats LLVM's shrink-wrapping:

- B's `push` on x86 saves and restores rbp, r15, r14, r12 and rbx on
  every call: 12 instructions more on a 13-instruction path.
- arm64 saves three register pairs.
- `set_fresh` goes 11 to 33 on arm64.

That cost is on every `push`, every `t[s] = x`, every `t[s].f = x` and
every `!t[s]`, wherever LLVM cannot keep the call out of the hot path.

### Loops

B also defeated loop unrolling and loop-invariant code motion:

- In the read-only loops (`p_sum`, `p_chase`), A hoists `slots` out of
  the loop and unrolls it 4x: about 4.75 instructions per element on
  arm64.
- B keeps the loop rolled and reloads `slots` in each iteration, since
  the load sits under the branch: 11 per element with two branches, or
  9 per step in `chase`.

Nothing vectorizes in either build, since slot reads are gathers.
Rig's own inlining decisions (`src/inlining.zig`) do not see
`table.zig`, so they did not change. LLVM's view of `push` (a `pub fn`,
not `inline`) doubled in size, so it may inline it less often. That
cannot be counted without Trig's object.

### Why one compare cost 14-18%

It is not one compare. It is 3 (x86) to 5 (arm64) instructions on every
read, a frame on every write, and lost unrolling in read loops.

Trig's checker is made of store accessors, often two chained Table
reads each. At about 4 instructions a read, 3 more per read is a 14-18%
rise if roughly one instruction in 30 is part of a Table read. That fits
`instructions.txt`: the rise is spread over every checker function, with
no hot spot.

## 2. A read path with no added cost

### (a) Swap the base pointer on spill

The swap itself is free: reads already load `slots` every time.

- No TBAA is emitted, so any store kills the cached load anyway, and
  today's codegen is unchanged.
- The soundness question is settled (section 3).

But a swap alone does not remove the test. A read without a test needs
`slots + i*size` to be readable for every `i < n`, and to read zero
where never written.

- A heap block of `cap` slots is followed by other heap data.
- So a packed head always needs a test on reads past `cap`, or reads
  junk.
- The only test-free layout is an `n`-slot address range per Table,
  which is what main has.

The swap is useful only for a move between two full-size ranges, for
example into a range with a different huge-page policy. That is the
memory expert's lane, and its read cost is zero.

### (b) Reserve from the start, the dense part simply its first pages

This is main's design today. It has no test.

- Its density is fixed by Trig's numbering. Link tables are written "by
  symbol or program-wide node id", sparse: 1.7 GiB touched to hold
  220 MiB, as investigation.md §3 found.
- Its page-walk cost comes from 43 heads per checker on 4 KiB pages.
- Neither is a read-path question. Two Tables cannot share a TLB entry
  or a page-table page without overlapping address ranges.

### (c) Prove the test away in proofs.zig

This route goes nowhere.

- proofs.zig tracks facts about bindings within a function: `below`,
  `nonneg`, `upto`.
- `i < cap(t)` depends on which slots *this* table has been written at.
- A `Slot[n]` is shared by every Table of `n`: `TypeId` indexes `types`,
  `lazy_index` and the `OBJECTS` tables through `data`.
- Trig's slots reach a read through fields loaded from other Tables, so
  no local fact names them.
- At best this proves the read right after a `push` of the same table, a
  sliver of the reads.

### (d) The cheapest test I could write, measured (variant C)

The design:

- A packed block holds `cap + 1` slots, and slot `cap` is always zero.
- A never-written table points at a static one-slot zero.
- A read is `&slots[@min(i, cap)]`: branchless (`umin`, or
  `cmp`/`cmovb`). Both loads are unconditional, so LICM hoists them.
- A write still tests `i >= cap` and grows.

The measured result:

- Reads: 3 more instructions on both machines. That could be 2 with a
  32-bit `cap`, which drops the zero-extension.
- Loops: unrolling and hoisting come back, at 1 instruction per element
  in read loops (`p_sum` C: hoisted, unrolled 4x).
- Writes are unchanged from B: the frame is still there.
- An out-of-line slow `push` (store and `len += 1` inside the cold call)
  still needs a frame once inlined. `push` twice: 37 to 70.
- Zig 0.17 offers no `preserve_most` calling convention (lib/std/lang.zig
  lists only `*_preserve_none`), so `grow` cannot be made cheap to call.

On x86, where the bar is judged, C's read costs what B's did.

### What it would gain

- The packed layout saved 3.0-3.5 points of page walks. Every packed
  read path costs more than that.
- B spent 10-11% more cycles in all.
- C would cut the arm64 read part by about half and the x86 read part by
  almost nothing.
- The write frames and the 8-24% more peak memory are unchanged (the
  memory cost is the layout's).
- My estimate for C on pup is 12-16% more user instructions and 5-9%
  slower. That is still far from the bar.

## 3. Soundness: what moving a Table's storage needs

Nothing new from the ownership checker. CORE §5, "Tables" (docs/CORE.md:1795):

- a slot is a place like a List's element, lent with `?t[s]` or `!t[s]`;
- `!t.push(x)` lends the table to write;
- the rejected example is a `?t[s]` live across a push.

It does not say in so many words that assigning another slot ends
a slot's views. It says "`t[s]` is the element `s` of an array of `n`
elements the table owns", and the checker treats any slot loan as a
loan on the whole table. Checked with `bin/rig check` (probes in
`sound/`):

| case | result |
|---|---|
| `v = ?t[a]`; `t[b] = …`; use `v` (s1) | rejected: cannot assign to `t[b]` while `t` is lent |
| `bump(!t[a], !t)` (s2) | rejected: write loan live |
| `for p in ?t` with `!t.push` in the body (s5) | rejected |
| view returned from a call, then push (s6) | rejected |
| `w = !t[a]`; `t[b].x = 3`; use `w` (s7) | rejected |
| `w = !t[a]`; `w.y = Int(!t.push(…))` (s9) | rejected |
| `… = Int(!t.push(…)) + p.x` with `p = ?t[a]` (s11) | rejected |
| `t[a].y = grow(!t)` and `t[a].y = Int(!t.push(…))` (s3, s4) | accepted, and sound: emit evaluates the right side into `__rig_new_1` before `t.slot(a)` (CORE §6, "Evaluation order", CORE.md:1829) |
| `t[a].y = p.x + Int(!t.push(…))` (s8) | accepted, and sound: `p.x` is loaded before the push (Zig evaluates operands left to right), and `p`'s loan ends there |

Main's Committed mode (`RIG_TABLE_FALLBACK`, the mode for wasm and
Windows) already moves a Table on a write. So a move is sound under CORE
as it stands, as the record says.

There is one gap, which is a question of coverage, not of soundness:

- `test/cli/table_reserve.sh` runs a single program under the fallback.
- `test/rig/table.rig.test`, run under `RIG_TABLE_FALLBACK=1
  RIG_SANITIZE=1`, would pin the moving path for every case. It is
  worth adding on its own, since wasm and Windows ship that path.
- If a moving design is ever built, CORE §5 should also say outright
  that writing any slot ends the table's views, as a push does, with
  `fail` cases s1, s7 and s9.

## 4. My design, and the verdict

No read-path design keeps the gain.

- Reads are already minimal on main: a base load, the index arithmetic,
  and a load, with no test, because the `Slot[n]` type bounds the index.
- Any layout that puts two Tables' slots on one page must test every
  read and every write, and that test costs more than the page walks it
  saves:
  - at least 2-3 instructions a read on both machines;
  - a doubled write path, from the frame a returning grow call forces;
  - plus the memory of zeroed doubling blocks.
- The cheapest form (C) was measured above and does not get near the
  bar on x86.

What remains for the gain keeps test-free reads, and lies outside this
lens:

- **For the memory expert:** one `n`-slot range per Table, with its
  placement or huge-page policy changed.
  - A move between two full ranges (the base swap of section 2a) costs
    nothing on reads and is sound under CORE §5.
  - It needs only a cold test where a write crosses a boundary.
  - Note table-ahead's lesson: a frontier test in `push` alone stopped
    `push` inlining.
- **For Trig:** denser numbering of its sparse link tables, or fewer,
  merged Tables a checker.

Files a C build would have touched: `src/table.zig` (`constSlot`, `slot`,
`grow`, `spill`, `__rig_drop`, `init`) and `src/alloc.zig`
(`reserveTable`'s `dense`). Emit, sema and proofs would not change.

**Verdict: DROP**, for the packed read path. A shared-page layout needs
a test on every read and write. The cheapest test measured is 3
instructions a read on x86, the machine the bar is judged on, the same
as the archive's, and writes still double. That costs several times the
3-3.5 points of page walks it saves.
