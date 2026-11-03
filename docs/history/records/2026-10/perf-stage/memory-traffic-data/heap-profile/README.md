# Trig's memory against tsrs's, ts-pattern at one checker (2026-10-28)

The raw outputs are in `raw/`. An agent ran them and stopped at an API limit before writing this summary; the per-site profile (`RIG_HEAP_PROFILE=sites`) was built (`work/bin-sites`) but not run. The Trig build was a release build with `RIG_HEAP_PROFILE=1`, run on pup.

## Totals
| | Trig | tsrs |
|---|---|---|
| Allocations over the run | 3,431,616 (bpftrace on Trig's allocator) | 2.4 M blocks (mimalloc stats) |
| Bytes allocated over the run | 309 MB | 243 MiB from mimalloc, plus a bump arena of 128 MiB used |
| Grows of a block (`remap`/`resize`) | 375,741, adding 124 MB | n/a |
| Peak live heap | 133.3 MiB | 59.8 MiB |
| Other large storage at the peak | `Table` reservations, about 97 MiB resident, in 4 KiB pages (`tables-ts-pattern.txt`) | the arena, 128 MiB, all in AnonHugePages |
| Peak RSS | 279–309 MB (309 with the profiler) | 202 MiB |

So **Trig does not allocate several times what tsrs does.** It allocates about the same in total. Its peak footprint is larger, and the large stores sit in small pages where tsrs's are in huge pages. That last difference is what drives Trig's 2.3–2.7× page faults.

## Trig's peak heap by owner (top, of 133.3 MiB)
| MiB | share | owner |
|---:|---:|---|
| 20.00 | 15.0% | `Ordered(InstantiationKey, u32)` entries (one block) |
| 17.43 | 13.1% | `u64`, in 27,556 blocks averaging 663 B; most likely Map index arrays, which the sites run would confirm |
| 16.08 | 12.1% | `Map(u32, u32)`, 174 maps averaging 97 KB |
| 15.37 | 11.5% | `Ordered(u32, u32)` entries, in 116,704 small blocks averaging 138 B |
| 13.77 | 10.3% | `Ordered(CacheKey, u32)` entries |
| 7.05 | 5.3% | `u32`, 22,797 lists |
| 7.00 | 5.3% | `checker.SymbolData` |
| 6.96 | 5.2% | `ast.NodeRec` |
| 5.06 | 3.8% | text (`u8`) |
| 4.02 | 3.0% | `ast.SymbolRec` |

Map and Set storage is about 90 MiB, two thirds of the heap.

## Opportunities, by expected bytes
1. **Map storage (Rig - Swiss's area):**
   - entries without a stored hash for plain keys (#743);
   - tighter growth for the big single-block entry Lists, which double, so up to half of 20 MiB may be slack;
   - the 116,704 small `Ordered(u32, u32)` maps: a smaller first size, or an inline small form.
2. **`Table` storage in huge pages without the memory cost.** It measured 61% fewer faults and ts-pattern 3.3–3.9% faster, but 4–16% more RSS, from the partly filled last 2 MiB of each table (alloc-seg-thp's tbl arm). Rig-side; open.
3. **The `u64` and `u32` blocks:** run the sites profile to name their owners.
4. **Trig-side:** `SymbolData` and the AST records, compared field by field with tsrs's.
