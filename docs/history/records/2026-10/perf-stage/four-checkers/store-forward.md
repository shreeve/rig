# Store-forward blocks: where Trig's land (2026-11-01)

Measured only; nothing was built. ts-pattern, one checker
(`--singleThreaded`), pup P-core 6. Trig is `/tmp/uc/m`: Trig fb60a18
built by pup's Rig caa6f8560, `CHECK_IDS = false`, release. tsrs is the
source build `/zfs/trig-pup/tsrs/bin/tsrs` in Go mode, `--noLazyMembers`.

## Counts (perf stat, 3 rotated rounds)

| | Trig | tsrs | Trig / tsrs |
|---|---:|---:|---:|
| ts-pattern blocked loads (`ld_blocks.store_forward`) | 12.7M | 5.2M | 2.45 |
| zod3 blocked loads | 2.25M | 1.05M | 2.14 |
| ts-pattern loads retired | 2,369M | 1,935M | 1.22 |
| ts-pattern stores retired | 1,109M | 1,109M | 1.00 |
| ts-pattern user cycles | 4,070M | 3,600–4,010M (pup loaded) | |

The 13.9M of morning-1031 was an older Trig; memory-traffic.md
(2026-10-28) had 13.5M, and its Relater experiment base 17.7M.

## Method

Two samplings, 16 runs each:

- **Skid sampling** (`ld_blocks.store_forward`, period 12007, LBR call
  chains): 11,197 Trig samples, 5,938 tsrs. The event is not PEBS on
  these cores, so each sample lands a few instructions after the
  blocked load. This gives shares by function, and call chains.
- **Exact sampling** (`perf mem record -U -t load --ldlat 8`): PEBS
  load-latency records carry `BLK Data` when a store could not forward
  to the load. 692 of 16,341 sampled loads were blocked. These give the
  exact load instruction; each site's disassembly gives the store it
  waited on.

Both are throttled at about 1,000 samples a second; the throttle is by
time, so it should not bias where samples land.

## The four patterns (ts-pattern)

Share of Trig's blocked loads, exact sampling (skid sampling in
brackets, where it differs):

| pattern | share | blocked loads | what |
|---|---:|---:|---|
| A. two-u32 object read through a pointer | 34% (21%) | 2.7–4.3M | written with two 4-byte stores, read with one 8-byte load |
| B. 16-byte Map key copied through a temporary | 21% (14–22%) | 1.8–2.7M | written as two 8-byte stores, copied with one 16-byte load |
| C. Relater pool copies | 22% (12%) | 1.5–2.8M | the Relater copied out of the pool, through an optional and `rig.rt` |
| D. insertion sort's swap | 6% (3.6%) | 0.5–0.8M | a swap's wide load overlapping the previous swap's store |
| other | 17% | | scattered, no site over 1.3% |

### A. Two-u32 objects through a pointer (34%)

Zig passes a non-packed object by reference. An 8-byte object of two
u32 fields (a node reference, a list's start and length) lives in
memory between calls: the writer stores each field (4 bytes, 4 bytes),
and LLVM merges the reader's two field loads into one 8-byte load,
which cannot be forwarded from two stores.

- The top site: `get_implied_constraint` builds a node in its frame
  (`mov [rsp+0x20],eax; mov [rsp+0x24],edx`), passes `&[rsp+0x20]`
  to itself recursively, which hands the pointer through
  `get_type_from_type_node_worker`'s tail call to
  `get_type_from_type_reference`, whose first load is
  `mov rcx,[rsi]` (8 bytes; `shr 32` splits it). 460 of 963 skid
  samples at that load come through this one chain.
- Others: `get_conditional_flow_type_of_type` (`mov rdx,[rdx]`),
  `instantiate_types` (`mov rbx,[rax]`), `get_conditional_type_instantiation_of`,
  `get_type_from_type_node_worker` (`[r13]`).

### B. 16-byte keys copied through a temporary (21%)

A key function returns its 16-byte key through memory as two 8-byte
stores (`get_type_items_instantiation_key`: `mov [rbx],rax;
mov [rbx+8],rdx`). The caller then copies it to the Map's argument
temporary with one `vmovdqu xmm0,[rsp+0x108]`, which spans both
stores. Reading the key straight from where it was written (8 bytes at
a time) would forward: `get_relation_key`'s key, read as two 8-byte
loads at `[rsp+0x50]`, does not block.

Sites: `Map(InstantiationKey).get` in `instantiate_type_worker` and
`get_conditional_type_instantiation_of`; `Map(CacheKey).put` in
`instantiate_type_with_alias` and `relation_set`; `Set(CacheKey).add`
in `recursive_type_related_to`.

### C. The Relater pool (22%)

`get_relater` is `(!@free_relaters).pop() ?? Relater()`: the Relater
is copied out of the List into an optional, out of it (`Niche.unwrap`),
and once more through `rig.rt` in `check_type_related_to_ex_output`.
The copies are 32-byte moves at offsets that straddle the previous
copy's stores (a load at `[rsp+0x41d]` after stores at `0x400` and
`0x3e0`). memory-traffic.md's experiment 3 (Relater in place) measured
this site at 4.97M blocks and 2.0% of user cycles on 2026-10-28; emit
changes since have taken it to 1.5–2.8M. tsrs passes a 4-byte handle.

### D. Insertion sort's swap (6%)

`__rig_std_sort.insertion` swaps neighbours with one wide load and one
wide store of the pair (`vpermpd ymm0,[r13]` for 16-byte elements in
`sort_symbols_by_key`; `vmovq xmm0,[rbp]` for u32 pairs in
`add_types_to_union`). The next step's load at `j-1` half-overlaps the
store just made at `j`, so every step of the inner loop blocks.

## What a block costs

memory-traffic.md's experiment 3 removed 4.97M blocks and 0.4% of
instructions (the copies) and saved 2.0% of user cycles: about 18
cycles a block, copies included. Take 12–18 cycles. Trig's excess over
tsrs (7.5M) is then 90–135M cycles, 2.2–3.3% of ts-pattern's user
cycles: the ceiling for this whole row.

## Fixes, with estimates (ts-pattern, one checker, user cycles; upper bounds)

| # | fix | where | estimate | risk and history |
|---|---|---|---:|---|
| A | Hold an object of two u32 (≤ 8 bytes, integer fields, no field lent) as one u64 in Zig: `packed struct(u64)`, passed in a register, stored and loaded whole | Rig: emit, a storage fact | 1.0–1.9% | a representation change: field views must be excluded, and access becomes shifts. #816 (rt-by-value) attacked copies of this class another way and made Trig 1.1% slower; this removes the pointer, not a temporary. Zig ceiling first |
| B | Map `get`/`put`/`add` take the key by address (`*const K`) and hash and compare it in place | Rig: std (`ordered.zig`, prelude) | 0.5–1.2% | key by address was part of #816 and never timed alone; the volatile two-word copy (beat-tsrs 12) made Trig 2.0–2.7% slower |
| C | Relaters used in place: a pool indexed by depth, lent as `!@relaters[i]`, as tsrs's handle | Trig: relater.rig (emit's experiment 3 is the Rig-side alternative) | 0.4–1.2% | measured once at 2.0% when the site was 3× larger |
| D | Insertion sort that holds the element and shifts, never swaps | Rig: std sort | 0.1–0.3% | small and local |

None overlaps another, so A to C together bound at about 2–4%, within
the 2.2–3.3% ceiling above. Each should start as a Zig ceiling (one
hand-edited build, arms switched at run time) timed in a slot with an
A/A arm, before any compiler change.

## Data (pup, `/zfs/worktrees/rig-rust-ports/sf/`)

`counts.sh`, `rec.sh`, `cmds.sh`; `trig.ts-pattern.N.data`,
`tsrs.ts-pattern.N.data` (skid, LBR), `lat.N.data` (exact);
`trig.dis` (disassembly), `trig.allip`/`trig.sym` (skid by address),
`lat.blkall`/`lat.sym`/`lat.ins` (exact). Classifiers `cls.py` and
`pcls.py` beside them.

tsrs's own blocks: 28% in `CacheHashKey::hash_128`, 15% in
`instantiate_type_with_alias_worker`, 5% in `Relation::lookup`.

## Ceilings timed (2026-11-02, 00:30–00:52)

Plain binaries, each hand-edited from the base package (Rig caa6f8560,
Trig fb60a18) and cross-built on the Mac (`sf-ceiling/`: `arms.py`,
`arm_p.py`, `fixes.py`, `mk.sh`). base's `.text` is byte-identical to
pup's own build, and `a` is a copy of base (A/A). pup, time-ab.sh
(`sf/all.conf`), 60 rounds, P-core 6 or cores 0,6,8,10. Every arm's
output is base's on all six projects. Paired median time per round
(rounds faster of 60), user cycles and instructions by median:

- **B** (Map `put`/`add`/`replace`/`ensure` probe the key in place; the
  instantiation key inline): blocks 1% fewer. LLVM still copies the
  keys (the inlined key function is where its 1.1% fewer instructions
  on ts-pattern come from). Time level everywhere. **Drop** the Map
  half; the inline is the size rule's call, not this row's.
- **C** (Relaters in place): blocks 19% fewer, ts-pattern 0.36% faster
  at 1 checker (36/60) and 0.42% at 4, zod3 0.77% and 0.66%: real but
  under Trig's bar. **Not worth its lines alone.**
- **p** (NodeRef, `ast.Node` and the five span types held as one word,
  `packed-small-objects.md`): blocks 45% fewer (12.6M to 6.94M; tsrs
  5.2M). One hand fix: `NodeRef.is_none` takes self by value. No field
  of these types is lent as a place anywhere in Trig.

| p against base | time (paired median) | rounds faster | user cycles | instructions | peak RSS |
|---|---:|---:|---:|---:|---:|
| ts-pattern, 1 checker | 1.57% faster | 51/60 | 1.56% fewer | 1.06% fewer | 227.0 → 226.7 MiB |
| ts-pattern, 4 | 1.05% faster | 43/60 | 1.18% fewer | 1.04% fewer | 253.8 → 253.6 |
| zod3, 1 | 1.62% faster | 50/60 | 1.92% fewer | 1.40% fewer | 73.2 → 73.0 |
| zod3, 4 | 1.66% faster | 48/60 | 2.13% fewer | 1.22% fewer | 104.9 → 104.6 |
| mitt, 1 / 4 | 2.37% / 2.62% faster | 45 / 46 | 4.66% / 4.35% fewer | 2.51% / 2.34% fewer | level |
| neverthrow, 1 / 4 | 3.23% / 1.26% faster | 44 / 35 | 4.20% / 3.47% fewer | 2.49% / 2.21% fewer | level |
| superstruct, 1 / 4 | 1.07% faster / 0.40% slower | 42 / 29 | 1.69% / 0.79% fewer | 1.37% / 1.30% fewer | level |
| tiny-invariant, 1 / 4 | 0.62% / 1.75% faster | 36 / 41 | 1.77% / 1.82% fewer | 1.22% / 1.21% fewer | level |

The A/A arm moved 0.16–1.18% by paired median (ts-pattern 0.16% at 1,
0.97% at 4). p is at least 1% fewer instructions on every project and
checker count, with time no worse beyond the A/A spread (superstruct
at 4 is 0.40% slower, A/A 0.34%). That clears Trig's bar ("≥1% fewer
instructions, time no worse") everywhere, with no memory cost. The
packed types are only seven of about 40 that qualify.

## The small leads stacked (2026-11-02, 03:25): under the bar, not timed

One hand ceiling, `sf-ceiling/stack.py`, from the same base package:
- **C:** Relaters in place, as above;
- **S:** the two union sorts (`add_types_to_union` and the
  `get_union_type_of` site) with a compile-time comparator,
  `std.sort.pdq` over `compare_types`, in place of `sort_by` through a
  `FnRef` (tsrs's same-flags fast path was left out: its rules in
  Trig were not clear enough to copy by hand);
- **L:** the checker's plain-data Lists with hot id reads (`types`,
  `inferences`) read unchecked, as a phase A move to Tables would make
  them.

Plain binaries; every arm's output is base's on all six projects.
Counts on pup E-core 14 (`perf stat --no-scale`), median of 5 rotated
rounds, one checker:

| arm | ts-pattern instructions / cycles fewer | zod3 instructions / cycles fewer |
|---|---:|---:|
| stack (C+S+L) | 0.09% / 0.90% | 0.39% / 0.65% |
| without C | 0.24% more / 0.19% more | 0.10% more / 0.57% more |
| without S | 0.32% / 0.68% | 0.49% / 0.76% |
| without L | 0.09% / 0.08% | 0.39% / 0.78% |

- **C** carries nearly all of the stack.
- **S costs instructions:** `pdq` does more work than Rig's insertion
  pass on the short arrays unions sort. The indirect call it removes
  was not the cost (as with the parser's direct calls in item 1).
- **L** adds nothing measurable.

The stack promises neither 1% fewer instructions nor 1.5% fewer
cycles, so it is not timed. C alone stays the one lead here, already
timed at 0.36–0.99%.
