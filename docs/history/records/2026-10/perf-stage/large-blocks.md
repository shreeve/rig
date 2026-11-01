# Trig's large blocks: growth slack and how they grow (2026-11-01)

**Correction ([slack-sources.md](slack-sources.md)):** the residency
below was read by `mincore` after the zero scan had mapped the zero page
into every page it read, so it is overstated. Counted from
`/proc/self/pagemap`, ts-pattern's slack at the peak is 4.3 MiB, not 14.2.

Queue row 43, measured only; nothing was built. Its data is in
[large-blocks-data/](large-blocks-data/):

- [measure.patch](large-blocks-data/measure.patch): the measuring patch,
  against Rig `e9e482b12`, for measurement only. It adds to
  `RIG_HEAP_PROFILE=1` and counts in `alloc.zig`.
- [lg43-ts-pattern.txt](large-blocks-data/lg43-ts-pattern.txt) and
  [lg43-zod3.txt](large-blocks-data/lg43-zod3.txt): the raw output.

**Setup:** Trig main `806e0a1`, release, cross-built on the Mac for pup
(x86-64, `-mcpu=meteorlake`), run on a pup E-core at one checker
(`-p tsconfig.trig.json --noEmit --singleThreaded`).

## How it was measured

At each new heap peak (in 2% steps), every live block over `max_small`
(32 KiB) was examined:

- **Room:** the bytes asked, a List's or a Map's entry array's capacity.
- **Size:** the allocator's block size (`largeSize`).
- **Used:** how far into the block bytes are nonzero.
- **Final:** the most of the block ever used, read again when it was
  freed, or counted full if it grew again.
- **Resident:** its resident pages (`mincore`).

The used extent works because a block starts zeroed and a List writes
only up to its length. Fresh pages are zero; the patch zeroes a reused
kept block, whose pages are resident already, so zeroing them adds no
residency. Two caveats:

- A trailing element that is all zero bytes reads as unused, which
  understates the used part by under an element.
- Map index arrays (`u64`) are filled by hash, so their used extent means
  nothing. Count them as full.

## ts-pattern at its peak (116.0 MiB live)

**123 blocks, 80.1 MiB of room; 65.9 MiB ever used; 80.1 MiB resident.**
So 14.2 MiB (18% of the room) is growth slack, and all of it is
resident.

| Owner | Blocks | Room MiB | Used % | Slack MiB |
|---|---:|---:|---:|---:|
| `Ordered(InstantiationKey, u32)` entries | 1 | 16.00 | 80 | 3.15 |
| `Ordered(CacheKey, u32)` entries | 7 | 10.22 | 82 | 1.85 |
| `Ordered(CachedTypeKey, u32)` entries | 1 | 3.00 | 54 | 1.39 |
| `Map(u32, u32)` objects (the checker's `tabs` Lists) | 3 | 8.63 | 81 | 1.67 |
| `ast.NodeRec` | 38 | 6.00 | 79 | 1.27 |
| `checker.InferenceInfo` | 1 | 2.25 | 59 | 0.78 |
| `ast.SymbolRec` | 9 | 2.81 | 75 | 0.69 |
| `checker.InferenceContext` | 1 | 1.88 | 66 | 0.57 |
| `u32` Lists | 17 | 3.71 | 82 | 0.41 |
| text (`u8`) | 9 | 3.52 | 84 | 0.27 |
| `ast.ListRec`, `ast.TextRec`, `ast.FlowRec` | 9 | 1.80 | 57 to 65 | 0.71 |
| `checker.SymbolData` | 1 | 7.00 | 99 | 0.08 |
| Map indexes (`u64`) | 13 | 8.60 | (full) | 0 |

## zod3 at its peak (44.5 MiB live)

**102 blocks, 29.8 MiB of room; 23.8 MiB ever used; 29.9 MiB resident.**
So 6.0 MiB (20%) is slack, and all of it is resident. The largest are
`ast.NodeRec` (5.5 MiB, 80% used), `u32` Lists (4.2, 83%), text (3.9,
84%), `Map(u32, u32)` objects (2.8, 68%) and `ast.SymbolRec` (2.6, 78%).

## How growth moves them (ts-pattern; zod3 in brackets)

| Path | Count | MiB |
|---|---:|---:|
| New blocks mapped from the system | 112 (93) | 28.8 (17.5) |
| Requests served from kept blocks | 88 (56) | 6.7 (2.9) |
| Requests served from cold blocks | 0 (0) | |
| Grows by `mremap` | 98 (69) | 111.4 (28.5), sizes after |
| Grows copied into a kept block | 31 (15) | 5.0 (1.6) |
| Grows by plain copy (under `move_large`, 64 KiB) | 33 (28) | |
| Frees, all kept | 231 (164) | |
| Frees unmapped | 0 | |

So growth already costs little: most grows move pages with `mremap`, and
every freed block was kept and reused. No block was unmapped or cold.

## What it means

1. **The slack is about a fifth of the large blocks, and it costs RSS in
   full:** 14.2 MiB on ts-pattern and 6.0 on zod3, every slack page
   resident. The resident pages come from the allocator faulting pages in
   ahead (a new block's first three quarters, half of each growth), huge
   pages for blocks of 16 MiB or more, and kept blocks reused. They don't
   come from the Lists writing them.
2. **Half of ts-pattern's slack is three Map entry arrays**
   (instantiations, relation caches, cached types: 6.4 MiB), which
   double from one block. The AST and binder lists add about 2.7 MiB,
   spread over many per-file blocks.
3. **Levers, unmeasured:**
   - **Fault in ahead only what a List will use.** This could remove most
     of the 14 MiB of resident slack without changing any capacity. It
     trades against the speed faulting ahead won ([prefault-lead/](../prefault-lead/), alloc-seg-thp,
     alloc-grow), so it needs both measured.
   - **Grow a large block by 1.5 times, not 2.** That would cut the room
     left over by about a third, around 5 MiB on ts-pattern. It costs more
     grows, which `mremap` keeps cheap.
   - **Trig-side:** size the per-file AST lists from the parser's counts,
     or fit them after parsing.
4. **tsrs:** not measured. Its `Vec`s double the same way, so their
   slack is structurally the same, but its AST lives in a bump arena
   (128 MiB of huge pages), so the AST lists' share has no counterpart
   there. Getting its numbers would need an instrumented tsrs build.

The 57.9 MiB in codegen-gap §3 was an older Trig; at `806e0a1` the large
blocks at ts-pattern's peak are 80.1 MiB of a 116.0 MiB heap.
