# The built-in Map on wide keys (2026-10-27)

**The question.** [tsrs-standing.md](tsrs-standing.md) found three Maps
with wide object keys taking 11.1% of Trig's user cycles on ts-pattern:
`CacheKey → u32` (two `U64`s), `InstantiationKey → u32` (an owner and a
`CacheKey`, three words), and `CachedTypeKey → u32` (an enum and a type
id). [table-reads.md](../perf-stage/table-reads.md) had seen a probe key
built on the stack and reloaded whole while the probe runs. Could a
lookup keep a small key in registers, or compare it whole, and make
Trig faster by the bar (AGENTS.md, "A speed feature pays for its
lines")?

**The answer.** The stall is not there. A lookup already holds a wide
key in registers, hashes it inline, and compares it word by word; the
hand-written Zig table it was built from is no faster on the same keys.
The cycles are the index's cache and TLB misses. One change pays: a
plain key of at most four words keeps no hash in its entry. Trig's peak
memory falls 3.1% on ts-pattern and 1.4% on zod3, with 0.3% and 0.2%
fewer instructions and its time within noise (below the speed bar). Data and scripts: [map-wide-keys-data/](map-wide-keys-data/).

## 1. What a lookup executes

Trig 403a823 built `--release` by Rig main 36422da59 (the build
tsrs-standing.md profiled), ts-pattern, `Checker.relation_get`
inlined into `is_type_related_to` (`objdump`):

```
mov   0x60(%rsp),%rax           ; the key's two words, from the caller's
mov   0x68(%rsp),%rsi           ;   slot: two 8-byte loads
...   xor, xor, mulx, xor       ; rig.hash: one folded multiply, inline
cmp   $0x40,%rdx ; jae panic    ; @intCast(shift) to u6, safe mode's test
shrx  %rdx,%rcx,%r9             ; the home group
prefetcht0 (%r11,%rdx,1)        ; its slots' line
vmovdqu (%r8,%r14,1),%xmm0      ; its 16 tags
vpcmpeqb, vpmovmskb, and        ; the tag's lanes
tzcnt ; mov (%r11,%r8,4),%r8d   ; a lane's entry index
cmp   %rcx,0x10(%rdx,%r15,1)    ; the stored hash
cmp   %rax,(%r15) ; cmp %rsi,0x8(%r15)   ; the key, word by word
```

No key is spilled and reloaded on this path; the key goes to the stack
only for the cold walk past the home group (`probePastHome`). Derived
`==` and `hash` are inline (`rt.eqlAs` field by field, `rt.hashAs`
through `wordCount` and `hashWords`). A Zig reproduction (`wk.rig`, keys
returned by a `called` function, as Trig's key builders are) compiles to
the same: the callee stores two words, the caller loads two words, and
8-byte loads of 8-byte stores forward.

Loads blocked by store forwarding, sampled precisely
(`ld_blocks.store_forward/upp`, every 2,003, one run, 6,879 samples):
13.5M in the run, 15.4% of them in every Map's code and 11.4% in the
three wide-key Maps, a third of those at the tag load. The largest
single sources are elsewhere: `get_relater`'s copies of an optional
`Relater` (`Niche.unwrap`, 32-byte `vmovups` of a value stored in parts,
6.7%) and `mem.swap` in `sort` (3.0%).

## 2. Where the cycles go

Twelve runs, user cycles sampled every 400,009 (`cycles/upp`, 122,299
samples), charged to the innermost inlined frame (`sym.py`, `agg.py`).
The same for L1, L2, and L3 load misses and for loads that missed the
second-level TLB:

| | all Maps | the three wide-key Maps | their tag loads | their slots prefetch |
|---|---:|---:|---:|---:|
| user cycles | 17.2% | 10.3% | 3.9% | 1.1% |
| L1 load misses | 20.0% | 11.5% | 10.0% | 0.5% |
| L2 load misses | 44.4% | 33.7% | 33.3% | 0.1% |
| L3 load misses | 38.9% | 24.5% | 14.6% | 0.1% |
| loads missing the STLB | 58.8% | 49.2% | 11.7% | 36.8% |
| loads blocked by store forwarding | 15.4% | 11.4% | 4.5% | 1.8% |

A third of all Trig's L2 load misses are these Maps' tag loads, and half
its STLB misses are their index: the tags (dense, 16 bytes a group) and
the slots (64 bytes a group, prefetched with the tags) sit in two arrays
of one block, so a lookup of a large index touches two pages. The entry
read (`keyMatch`, the stored hash) is 1.7% of cycles. The key's hash and
compare are a few instructions. tsrs pays the same kind of misses in its
own tables: Trig has 3.1M L2 load misses to its 2.9M (table-reads.md).

## 3. The ceiling: bench/hash's hand-written Zig table

bench/hash's `zig-ordered` (bench/hash/ordered.zig) is the hand-written
Zig the built-in Map was made from. Its rows on wide keys are new:
map.zig now times `pair` (two words, as `CacheKey`) and `triple` (three,
as `InstantiationKey`) on every Zig table, with Rig's hash of plain
words (`table_ctx.Words`), and map.rig times `triple` beside `pair`.
pup core 3, fastest of 5, ms for a million operations:

| | pair insert | pair hit | pair miss | triple insert | triple hit | triple miss |
|---|---:|---:|---:|---:|---:|---:|
| Zig, no hash kept, unchecked (the ceiling) | 19.42 | 7.71 | 4.41 | 22.34 | 10.58 | 6.78 |
| Zig, no hash kept, Rig's bounds tests | 20.22 | 8.62 | 4.59 | 22.71 | 10.49 | 6.91 |
| Zig, hash kept, unchecked | 20.89 | 8.87 | 4.53 | 22.62 | 11.20 | 6.87 |
| Zig, hash kept, Rig's bounds tests | 21.49 | 9.54 | 5.01 | 22.87 | 11.98 | 7.35 |
| Rig main (hash kept) | 27.61 | 8.81 | 4.26 | 31.02 | 11.25 | 6.37 |
| Rig, no hash kept (this change) | 25.98 | **6.91** | 4.25 | 28.62 | **10.42** | 6.43 |
| Rig, no hash kept, no slots prefetch | 23.83 | 8.33 | 3.84 | 25.87 | 11.33 | 6.02 |

Rig's lookups meet the ceiling: with no hash kept, a hit takes 6.91 ms
against the unchecked Zig's 7.71 on pairs and 10.42 against 10.58 on
triples, and a miss is within 4% of it or faster. Rig's lookups compile
to the hand-written table's instructions (§1), and Rig's allocator
serves the index from its size classes where map.zig's runs on libc's
`malloc`. Keeping no hash makes hits 22% faster on pairs and 7% on
triples in Rig, 13% and 6% in the Zig. **The gap left is the insert
row:** Rig's takes 25.98 ms against 19.42 (34% slower) on pairs, and
28.62 against 22.34 on triples. Each Rig `put` probes for the key and
then inserts it, both inline, as zig-ordered's does. Where the
difference lies is not measured here; the likely place is growth, an
index rebuilt into a block Rig's allocator hands out and `newIndex`
clears, where the Zig's comes zeroed from `calloc`. It is the next
requirement (§6); Trig's maps are read far more than grown
(tsrs-standing.md: `insertHashed` 0.97% of user cycles).

## 4. What was tried

**The index's two arrays made one** (an 80-byte group of tags and then
slots; or blocks of four groups, their tags' line then their four slot
lines), so a lookup's tags and slots share a page. bench/hash, pup core
3, fastest of 3 against main: lookups of absent keys 21-60% slower at
100,000 and 4,000,000 Int keys, hits from 5% faster to 17% slower. A probe that finds
no tag reads only the tags, and the dense tags array packs four groups'
tags in a line and a page holds 256 groups' tags; spread among the
slots, a page holds 51. Not taken. The STLB misses are for huge pages
to remove (alloc-seg-thp, in flight), not the layout.

**No hash kept in a plain key's entry** (taken). A key over 8 bytes kept
its 64-bit hash beside it, so a probe compared the hash before the key,
and a rebuild placed entries without hashing. For a plain key of at most
four words (`rt.wordCount`: integers of at most 64 bits, plain enums,
and `Bool`s, through nested objects, none with its own `==` or hash)
the hash is one or two folded multiplies and the compare as many loads
as the hash's, in the same line, so the hash is dropped: a `CacheKey`
entry is 24 bytes, not 32, and an `InstantiationKey` entry 32, not 40.
A key with a written `==` or `hash_into` still keeps its hash and still
has them called; what `==` and `.hash()` give is unchanged.

**The slots prefetch dropped** (measured, not taken). A miss reads only
the tags, and the prefetch of a slot line it never reads is 37% of
Trig's STLB misses. Without it, bench/hash's wide-key misses are 6-10%
faster and hits 9-20% slower (§3); Trig, on Rig 099c1bff3, 20 rounds:
0.8% fewer cycles than main on ts-pattern and zod3 by the median, 0.3%
fewer instructions, and peak memory 1.1% and 3.3% lower than with the
prefetch, the same in every run (a prefetch faults nothing in; why the
peak moves is not found). Under the speed bar, at the cost of every
large Map's hits; the peak is worth finding before it is taken.

**The shift held as a `u6`**, so safe mode's test of `@intCast(shift)`
(two instructions a lookup and an insert) is gone.

## 5. Trig

Trig 403a823, `--release`, built by Rig main 099c1bff3 and by each
variant on pup's slot 10,11; 20 rounds interleaved on core 8 (sibling 9
idle), medians; every run's output identical to main's.

Trig 403a823, `--release`, built by Rig main 7c2365522 and by this
branch (7c2365522 with the change) on pup's slot 10,11; 20 rounds
interleaved on core 8 (sibling 9 idle); every run's output identical to
main's ([times-7c2365522.txt](map-wide-keys-data/times-7c2365522.txt)):

| | ts-pattern main | branch | | zod3 main | branch | |
|---|---:|---:|---:|---:|---:|---:|
| wall, median | 906.3 ms | 907.3 ms | 0.1% slower | 178.0 ms | 176.2 ms | 1.0% faster |
| cycles, median | 3.903G | 3.921G | 0.5% more | 0.7235G | 0.7251G | 0.2% more |
| instructions, median | 9.280G | 9.253G | 0.29% fewer | 1.6783G | 1.6753G | 0.17% fewer |
| peak RSS | 280.4 MB | 271.8 MB | **3.1% lower** | 87.9 MB | 86.7 MB | **1.4% lower** |

Time is within noise, under the speed bar; the gain is memory. Earlier
rounds on Rig 099c1bff3 (the variants of §4, same method) agree:
[times-099c1bff3-summary.txt](map-wide-keys-data/times-099c1bff3-summary.txt).

## 6. What remains, as requirements

The lookup's code matches the ceiling's; what remains is memory:

1. **Huge pages for a large Map index** (alloc.zig, Rig - Merges'
   alloc-seg-thp): half Trig's STLB misses are these Maps' index; a
   2 MiB page holds 25,000 groups' tags and slots.
2. **Copies of optional values stored in parts** (`get_relater`'s
   `Niche(Relater).unwrap`, 6.7% of Trig's blocked loads): a value built
   field by field and copied whole, the class table-reads.md fixed for
   optional results; not a Map's.
3. The tag load's L2 misses are the hash's scatter, which any hash
   table pays; tsrs's count is within 7% of Trig's.
