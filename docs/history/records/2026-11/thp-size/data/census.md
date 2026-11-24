# THP size: Table census (B) and the RIG_HUGE_MIN_MB knob (A), 2026-11-23

Scratch work; nothing lands. Rig branch `scratch/thp-size` (worktree ~/Data/Code/worktrees/rig/thp-size):

- `ce8f7f9ac` alloc: RIG_HUGE_MIN_MB (A, the knob; written to land later as its own PR)
- `88b7e55aa` table: RIG_TABLE_RSS=1 census (B, scratch only, never lands)
- `350c0a007` table: census prints base/len key=value (B, scratch)

Trig at d78aa3f3 (main, the same source as b1r: the release packs differ only in buildinfo's Rig sha).

## Gates

- `zig build test` (Mac): passed on the A-only tree (ce8f7f9ac), on A+B (88b7e55aa), and on 350c0a007.
- Core suite `tools/heavy --class correctness swarm test/rig.rip -w 4 -q` (Mac) on 88b7e55aa (A+B): 12,733 jobs, exit 0, no failures.
- Trig `swarm tests/trig.rip cli` on burst with Rig 350c0a007 (builds the release pack and checks 6 projects against tsc): 38/38 passed.
- Census functional test: a small Rig program (cross-built for Linux), on pup, at N=2/8/32: Table and region numbers check out (for example, a 24 MiB-touched Table at N=8 holds 16 MiB AnonHuge = 24 − 8).

## B: the census

`RIG_TABLE_RSS=1` (read once, the first time a Table is reserved, from the environment; Linux only). Each reserved Table is recorded as it is made: its base, length, element `@typeName`, `n`, and the thread that reserved it. Each Table is measured as it is dropped, or at exit (`os.exit`, or `main`'s `finish`). Output goes to stderr, one `key=value` line per Table, then one line per smaps mapping holding memory outside the Tables (`segment`/`other`, with base and len), then totals and VmHWM.

- **Rss** comes from `/proc/self/pagemap`: pages present and mapped exclusively. That leaves out the zero page, which a read of an unwritten slot maps.
- **AnonHuge** comes from `/proc/self/smaps`: the AnonHugePages of the mappings inside the Table's range. A Table's NOHUGEPAGE head splits its mapping from its neighbours'.
- **Cost when unset:** a one-byte test when a Table is made and when it is dropped, and one at exit. Nothing in hot paths.
- **Names:** the census records the element type and `n`. Fields are named offline by the order in which a thread reserves its Tables (names.py: `ids.*` x5 on the main thread, then `store.*` x47 and `checker.*` x6 per checker; 53 per checker thread, 58 when the main thread also checks). The compiler does not pass a field name: that would have meant an emit change.
- **Drops:** 159 of the 217 Tables are dropped before exit (each checker's store when it finishes). Those are measured as they drop, at their largest. So "all Tables" is a sum over lifetimes, not a single moment, while the "at exit" lines are a single moment.

Runs: pup, E-cores 12-19 under the ecores lock, slot guard, THP `madvise`/`madvise`, 690–1,150 free 2 MiB blocks. Binary: plain release with symbols, Rig 350c0a007, built on burst for Meteor Lake (`-mcpu=meteorlake`; the native burst build died with SIGILL on pup). sha256 5f9bee90…209b, at pup:/zfs/trig-pup/thp-size/trig-census. Command: `env -u TRIG_PREBUILT_LIBS RIG_TABLE_RSS=1 [RIG_HUGE_MIN_MB=N] taskset -c 12-19 trig --checkers 4 -p tsconfig.json --noEmit`, one run each.

### Findings

- **Compiler c4: no Table holds a huge page.** None grows past its first 2 MiB. All 217 Tables together hold 22.9 MiB Rss. The huge-page room is in the heap segments: 54 MiB AnonHuge of 87 MiB Rss at exit.
- **nuxt c4: Tables hold 66 MiB AnonHuge**, in five fields: store.value_symbol_links 32, store.types 14, ids.binder 12, store.type_lists 6, checker.syms 2. The other 48 fields hold none. Segments hold 190 MiB AnonHuge of 320 MiB Rss.
- **Segments are the main lever above one checker.** That is where most of THP's cost lies (Trig's prctl probe: Compiler c4 118 → 76 MiB, nuxt 501 → 442).

### Peak RSS by N (census binary, one run each; stdout identical across N)

| | N=2 | N=8 | N=32 |
|---|---:|---:|---:|
| Compiler c4 peak MiB | 120 | 109 | 89 |
| Compiler segments AnonHuge MiB (exit) | 54 | 46 | 14 |
| nuxt c4 peak MiB | 521 | 507 | 501 |
| nuxt segments AnonHuge MiB (exit) | 190 | 158 | 134 |
| nuxt Tables AnonHuge MiB (all) | 66 | 14 | 0 |

### compiler c4, N=2

peak RSS 120 MiB; threads reserving Tables: 5 (5, 53, 53, 53, 53 each); Tables: 217, 159 measured as dropped, the rest at exit

| Table | element, n | reserved MiB | count | Rss MiB | AnonHuge MiB |
|---|---|---:|---:|---:|---:|
| store.types | Type, 134217728 | 4608 | 4 | 2.7 | 0.0 |
| store.symbol_node_links | SymbolNodeLinks, 134217728 | 512 | 4 | 2.4 | 0.0 |
| store.value_symbol_links | ValueSymbolLinks, 134217728 | 2048 | 4 | 2.3 | 0.0 |
| store.type_node_links | TypeNodeLinks, 134217728 | 512 | 4 | 2.2 | 0.0 |
| store.signature_links | SignatureLinks, 134217728 | 512 | 4 | 2.2 | 0.0 |
| ids.binder | BinderSym, 134217728 | 4096 | 1 | 1.2 | 0.0 |
| store.signatures | Signature, 33554432 | 1152 | 4 | 1.0 | 0.0 |
| store.type_lists | u32, 536870912 | 2048 | 4 | 0.9 | 0.0 |
| store.literals | LiteralType, 67108864 | 1536 | 4 | 0.9 | 0.0 |
| checker.syms | CheckerSymbol, 67108864 | 1024 | 4 | 0.8 | 0.0 |
| store.mappers | TypeMapper, 16777216 | 256 | 4 | 0.7 | 0.0 |
| store.u32_lists | u32, 536870912 | 2048 | 4 | 0.6 | 0.0 |
| store.structured | StructuredType, 67108864 | 1024 | 4 | 0.5 | 0.0 |
| store.structured_extras | StructuredExtra, 67108864 | 1536 | 4 | 0.5 | 0.0 |
| 44 more fields, each under 0.5 MiB | | | 164 | 4.0 | 0.0 |
| **all Tables** | | | 217 | 22.9 | 0.0 |

- at exit, tablemaps: Rss 6.8 MiB, AnonHuge 0.0 MiB, 55 maps asking for huge pages
- at exit, segments: Rss 86.6 MiB, AnonHuge 54.0 MiB, 5 maps asking for huge pages
- at exit, other: Rss 10.2 MiB, AnonHuge 0.0 MiB, 0 maps asking for huge pages
- at exit, all: Rss 103.6 MiB, AnonHuge 54.0 MiB
  - segment map base=0x788bdb800000 len=4 MiB: Rss 4.0, AnonHuge 4.0, hg=1
  - segment map base=0x788bdc000000 len=60 MiB: Rss 29.5, AnonHuge 18.0, hg=1
  - segment map base=0x788be0000000 len=128 MiB: Rss 19.1, AnonHuge 8.0, hg=1
  - segment map base=0x788be8000000 len=36 MiB: Rss 5.8, AnonHuge 4.0, hg=1
  - segment map base=0x788bec000000 len=88 MiB: Rss 28.3, AnonHuge 20.0, hg=1

### nuxt c4, N=2

peak RSS 521 MiB; threads reserving Tables: 4 (58, 53, 53, 53 each); Tables: 217, 159 measured as dropped, the rest at exit

| Table | element, n | reserved MiB | count | Rss MiB | AnonHuge MiB |
|---|---|---:|---:|---:|---:|
| store.value_symbol_links | ValueSymbolLinks, 134217728 | 2048 | 4 | 34.7 | 32.0 |
| store.types | Type, 134217728 | 4608 | 4 | 22.0 | 14.0 |
| ids.binder | BinderSym, 134217728 | 4096 | 1 | 14.0 | 12.0 |
| store.type_lists | u32, 536870912 | 2048 | 4 | 13.1 | 6.0 |
| checker.syms | CheckerSymbol, 67108864 | 1024 | 4 | 8.8 | 2.0 |
| store.type_node_links | TypeNodeLinks, 134217728 | 512 | 4 | 6.4 | 0.0 |
| store.mappers | TypeMapper, 16777216 | 256 | 4 | 6.2 | 0.0 |
| store.symbol_node_links | SymbolNodeLinks, 134217728 | 512 | 4 | 6.2 | 0.0 |
| checker.symbol_data | SymbolData, 67108864 | 1792 | 4 | 5.6 | 0.0 |
| store.u32_lists | u32, 536870912 | 2048 | 4 | 4.7 | 0.0 |
| store.signature_links | SignatureLinks, 134217728 | 512 | 4 | 4.7 | 0.0 |
| store.structured | StructuredType, 67108864 | 1024 | 4 | 3.5 | 0.0 |
| store.signatures | Signature, 33554432 | 1152 | 4 | 2.9 | 0.0 |
| checker.tab_entries | TableEntry, 268435456 | 2048 | 4 | 2.8 | 0.0 |
| store.merged_symbols | u32, 134217728 | 512 | 4 | 2.2 | 0.0 |
| store.small_kinds | SmallKind, 67108864 | 2560 | 4 | 2.1 | 0.0 |
| checker.lazy_index | u32, 134217728 | 512 | 4 | 1.9 | 0.0 |
| checker.base_constraints | u32, 134217728 | 512 | 4 | 1.9 | 0.0 |
| store.union_or_intersection_extras | UnionOrIntersectionExtra, 67108864 | 2816 | 4 | 1.9 | 0.0 |
| store.value_symbol_extras | ValueSymbolExtra, 134217728 | 1536 | 4 | 1.7 | 0.0 |
| store.literals | LiteralType, 67108864 | 1536 | 4 | 1.6 | 0.0 |
| store.structured_extras | StructuredExtra, 67108864 | 1536 | 4 | 1.6 | 0.0 |
| store.symbol_reference_links | SymbolReferenceLinks, 134217728 | 512 | 4 | 1.6 | 0.0 |
| store.union_or_intersections | UnionOrIntersectionType, 67108864 | 768 | 4 | 1.5 | 0.0 |
| ids.tab_loc | TabLoc, 134217728 | 1536 | 1 | 1.4 | 0.0 |
| store.declared_type_links | DeclaredTypeLinks, 134217728 | 1024 | 4 | 1.4 | 0.0 |
| checker.tab_heads | TabHead, 67108864 | 768 | 4 | 1.4 | 0.0 |
| store.references | TypeReference, 67108864 | 1280 | 4 | 1.2 | 0.0 |
| store.type_parameters | TypeParameter, 67108864 | 1536 | 4 | 1.1 | 0.0 |
| store.signature_extras | SignatureExtra, 33554432 | 1024 | 4 | 1.1 | 0.0 |
| store.mapped_symbol_links | MappedSymbolLinks, 134217728 | 1024 | 4 | 1.0 | 0.0 |
| store.alias_symbol_links | AliasSymbolLinks, 134217728 | 1536 | 4 | 0.9 | 0.0 |
| store.members_links | MembersLinks, 134217728 | 512 | 4 | 0.9 | 0.0 |
| store.alias_targets | u32, 134217728 | 512 | 4 | 0.7 | 0.0 |
| store.type_aliases | TypeAlias, 2097152 | 24 | 4 | 0.6 | 0.0 |
| store.string_literal_types | u32, 134217728 | 512 | 4 | 0.6 | 0.0 |
| store.interfaces | InterfaceType, 67108864 | 4096 | 4 | 0.5 | 0.0 |
| store.structured_member_records | StructuredMembers, 67108864 | 512 | 4 | 0.5 | 0.0 |
| 20 more fields, each under 0.5 MiB | | | 71 | 3.4 | 0.0 |
| **all Tables** | | | 217 | 170.1 | 66.0 |

- at exit, tablemaps: Rss 59.1 MiB, AnonHuge 28.0 MiB, 55 maps asking for huge pages
- at exit, segments: Rss 319.8 MiB, AnonHuge 190.0 MiB, 5 maps asking for huge pages
- at exit, other: Rss 21.9 MiB, AnonHuge 0.0 MiB, 0 maps asking for huge pages
- at exit, all: Rss 400.9 MiB, AnonHuge 218.0 MiB
  - segment map base=0x74e9dc000000 len=116 MiB: Rss 85.6, AnonHuge 54.0, hg=1
  - segment map base=0x74e9e4000000 len=44 MiB: Rss 29.4, AnonHuge 22.0, hg=1
  - segment map base=0x74e9e8000000 len=96 MiB: Rss 40.3, AnonHuge 4.0, hg=1
  - segment map base=0x74e9ee000000 len=200 MiB: Rss 153.7, AnonHuge 106.0, hg=1
  - segment map base=0x74e9fc000000 len=40 MiB: Rss 10.8, AnonHuge 4.0, hg=1

### compiler c4, N=8

peak RSS 109 MiB; threads reserving Tables: 5 (5, 100, 6, 53, 53 each); Tables: 217, 159 measured as dropped, the rest at exit

| Table | element, n | reserved MiB | count | Rss MiB | AnonHuge MiB |
|---|---|---:|---:|---:|---:|
| store.types | Type, 134217728 | 4608 | 2 | 1.4 | 0.0 |
| ids.binder | BinderSym, 134217728 | 4096 | 1 | 1.2 | 0.0 |
| store.value_symbol_links | ValueSymbolLinks, 134217728 | 2048 | 2 | 1.2 | 0.0 |
| store.symbol_node_links | SymbolNodeLinks, 134217728 | 512 | 2 | 1.2 | 0.0 |
| store.signature_links | SignatureLinks, 134217728 | 512 | 2 | 1.1 | 0.0 |
| store.type_node_links | TypeNodeLinks, 134217728 | 512 | 2 | 1.1 | 0.0 |
| ?100#22 | SymbolNodeLinks, 134217728 | 512 | 1 | 0.7 | 0.0 |
| ?100#47 | Type, 134217728 | 4608 | 1 | 0.7 | 0.0 |
| ?100#21 | SignatureLinks, 134217728 | 512 | 1 | 0.7 | 0.0 |
| ?100#23 | TypeNodeLinks, 134217728 | 512 | 1 | 0.7 | 0.0 |
| ?100#0 | Type, 134217728 | 4608 | 1 | 0.6 | 0.0 |
| ?100#72 | ValueSymbolLinks, 134217728 | 2048 | 1 | 0.6 | 0.0 |
| ?100#25 | ValueSymbolLinks, 134217728 | 2048 | 1 | 0.5 | 0.0 |
| ?100#69 | SymbolNodeLinks, 134217728 | 512 | 1 | 0.5 | 0.0 |
| store.type_lists | u32, 536870912 | 2048 | 2 | 0.5 | 0.0 |
| store.signatures | Signature, 33554432 | 1152 | 2 | 0.5 | 0.0 |
| 148 more fields, each under 0.5 MiB | | | 194 | 9.8 | 0.0 |
| **all Tables** | | | 217 | 22.9 | 0.0 |

- at exit, tablemaps: Rss 6.8 MiB, AnonHuge 0.0 MiB, 51 maps asking for huge pages
- at exit, segments: Rss 73.1 MiB, AnonHuge 46.0 MiB, 4 maps asking for huge pages
- at exit, other: Rss 13.1 MiB, AnonHuge 0.0 MiB, 0 maps asking for huge pages
- at exit, all: Rss 93.0 MiB, AnonHuge 46.0 MiB
  - segment map base=0x728b5e000000 len=32 MiB: Rss 2.0, AnonHuge 2.0, hg=1
  - segment map base=0x728b60000000 len=24 MiB: Rss 7.7, AnonHuge 0.0, hg=0
  - segment map base=0x728b61800000 len=4 MiB: Rss 2.0, AnonHuge 2.0, hg=1
  - segment map base=0x728b62000000 len=192 MiB: Rss 36.8, AnonHuge 24.0, hg=1
  - segment map base=0x728b6e000000 len=32 MiB: Rss 1.4, AnonHuge 0.0, hg=0
  - segment map base=0x728b70000000 len=60 MiB: Rss 23.2, AnonHuge 18.0, hg=1

### nuxt c4, N=8

peak RSS 507 MiB; threads reserving Tables: 4 (58, 53, 53, 53 each); Tables: 217, 159 measured as dropped, the rest at exit

| Table | element, n | reserved MiB | count | Rss MiB | AnonHuge MiB |
|---|---|---:|---:|---:|---:|
| store.value_symbol_links | ValueSymbolLinks, 134217728 | 2048 | 4 | 22.0 | 8.0 |
| ids.binder | BinderSym, 134217728 | 4096 | 1 | 14.0 | 6.0 |
| store.types | Type, 134217728 | 4608 | 4 | 17.2 | 0.0 |
| store.type_lists | u32, 536870912 | 2048 | 4 | 10.9 | 0.0 |
| checker.syms | CheckerSymbol, 67108864 | 1024 | 4 | 6.8 | 0.0 |
| store.type_node_links | TypeNodeLinks, 134217728 | 512 | 4 | 6.4 | 0.0 |
| store.mappers | TypeMapper, 16777216 | 256 | 4 | 6.2 | 0.0 |
| store.symbol_node_links | SymbolNodeLinks, 134217728 | 512 | 4 | 6.2 | 0.0 |
| checker.symbol_data | SymbolData, 67108864 | 1792 | 4 | 5.6 | 0.0 |
| store.u32_lists | u32, 536870912 | 2048 | 4 | 4.7 | 0.0 |
| store.signature_links | SignatureLinks, 134217728 | 512 | 4 | 4.7 | 0.0 |
| store.structured | StructuredType, 67108864 | 1024 | 4 | 3.5 | 0.0 |
| store.signatures | Signature, 33554432 | 1152 | 4 | 2.9 | 0.0 |
| checker.tab_entries | TableEntry, 268435456 | 2048 | 4 | 2.8 | 0.0 |
| store.merged_symbols | u32, 134217728 | 512 | 4 | 2.2 | 0.0 |
| store.small_kinds | SmallKind, 67108864 | 2560 | 4 | 2.1 | 0.0 |
| checker.lazy_index | u32, 134217728 | 512 | 4 | 1.9 | 0.0 |
| checker.base_constraints | u32, 134217728 | 512 | 4 | 1.9 | 0.0 |
| store.union_or_intersection_extras | UnionOrIntersectionExtra, 67108864 | 2816 | 4 | 1.9 | 0.0 |
| store.value_symbol_extras | ValueSymbolExtra, 134217728 | 1536 | 4 | 1.7 | 0.0 |
| store.literals | LiteralType, 67108864 | 1536 | 4 | 1.6 | 0.0 |
| store.structured_extras | StructuredExtra, 67108864 | 1536 | 4 | 1.6 | 0.0 |
| store.symbol_reference_links | SymbolReferenceLinks, 134217728 | 512 | 4 | 1.6 | 0.0 |
| store.union_or_intersections | UnionOrIntersectionType, 67108864 | 768 | 4 | 1.5 | 0.0 |
| ids.tab_loc | TabLoc, 134217728 | 1536 | 1 | 1.4 | 0.0 |
| store.declared_type_links | DeclaredTypeLinks, 134217728 | 1024 | 4 | 1.4 | 0.0 |
| checker.tab_heads | TabHead, 67108864 | 768 | 4 | 1.4 | 0.0 |
| store.references | TypeReference, 67108864 | 1280 | 4 | 1.2 | 0.0 |
| store.type_parameters | TypeParameter, 67108864 | 1536 | 4 | 1.1 | 0.0 |
| store.signature_extras | SignatureExtra, 33554432 | 1024 | 4 | 1.1 | 0.0 |
| store.mapped_symbol_links | MappedSymbolLinks, 134217728 | 1024 | 4 | 1.0 | 0.0 |
| store.alias_symbol_links | AliasSymbolLinks, 134217728 | 1536 | 4 | 0.9 | 0.0 |
| store.members_links | MembersLinks, 134217728 | 512 | 4 | 0.9 | 0.0 |
| store.alias_targets | u32, 134217728 | 512 | 4 | 0.7 | 0.0 |
| store.type_aliases | TypeAlias, 2097152 | 24 | 4 | 0.6 | 0.0 |
| store.string_literal_types | u32, 134217728 | 512 | 4 | 0.6 | 0.0 |
| store.interfaces | InterfaceType, 67108864 | 4096 | 4 | 0.5 | 0.0 |
| store.structured_member_records | StructuredMembers, 67108864 | 512 | 4 | 0.5 | 0.0 |
| 20 more fields, each under 0.5 MiB | | | 71 | 3.4 | 0.0 |
| **all Tables** | | | 217 | 148.4 | 14.0 |

- at exit, tablemaps: Rss 52.6 MiB, AnonHuge 8.0 MiB, 51 maps asking for huge pages
- at exit, segments: Rss 320.7 MiB, AnonHuge 158.0 MiB, 5 maps asking for huge pages
- at exit, other: Rss 24.1 MiB, AnonHuge 0.0 MiB, 0 maps asking for huge pages
- at exit, all: Rss 397.3 MiB, AnonHuge 166.0 MiB
  - segment map base=0x7e3067400000 len=44 MiB: Rss 30.9, AnonHuge 0.0, hg=0
  - segment map base=0x7e306a000000 len=100 MiB: Rss 46.8, AnonHuge 12.0, hg=1
  - segment map base=0x7e3070400000 len=8 MiB: Rss 7.8, AnonHuge 0.0, hg=0
  - segment map base=0x7e3070c00000 len=4 MiB: Rss 3.8, AnonHuge 0.0, hg=1
  - segment map base=0x7e3072000000 len=36 MiB: Rss 19.2, AnonHuge 2.0, hg=1
  - segment map base=0x7e3074400000 len=28 MiB: Rss 7.8, AnonHuge 0.0, hg=0
  - segment map base=0x7e3076000000 len=32 MiB: Rss 15.6, AnonHuge 4.0, hg=1
  - segment map base=0x7e3078000000 len=32 MiB: Rss 3.9, AnonHuge 0.0, hg=0
  - segment map base=0x7e307a000000 len=244 MiB: Rss 184.8, AnonHuge 140.0, hg=1

### compiler c4, N=32

peak RSS 89 MiB; threads reserving Tables: 4 (58, 53, 53, 53 each); Tables: 217, 159 measured as dropped, the rest at exit

| Table | element, n | reserved MiB | count | Rss MiB | AnonHuge MiB |
|---|---|---:|---:|---:|---:|
| store.types | Type, 134217728 | 4608 | 4 | 2.7 | 0.0 |
| store.symbol_node_links | SymbolNodeLinks, 134217728 | 512 | 4 | 2.4 | 0.0 |
| store.value_symbol_links | ValueSymbolLinks, 134217728 | 2048 | 4 | 2.3 | 0.0 |
| store.type_node_links | TypeNodeLinks, 134217728 | 512 | 4 | 2.2 | 0.0 |
| store.signature_links | SignatureLinks, 134217728 | 512 | 4 | 2.2 | 0.0 |
| ids.binder | BinderSym, 134217728 | 4096 | 1 | 1.2 | 0.0 |
| store.signatures | Signature, 33554432 | 1152 | 4 | 1.0 | 0.0 |
| store.type_lists | u32, 536870912 | 2048 | 4 | 0.9 | 0.0 |
| store.literals | LiteralType, 67108864 | 1536 | 4 | 0.9 | 0.0 |
| checker.syms | CheckerSymbol, 67108864 | 1024 | 4 | 0.8 | 0.0 |
| store.mappers | TypeMapper, 16777216 | 256 | 4 | 0.7 | 0.0 |
| store.u32_lists | u32, 536870912 | 2048 | 4 | 0.6 | 0.0 |
| store.structured | StructuredType, 67108864 | 1024 | 4 | 0.5 | 0.0 |
| store.structured_extras | StructuredExtra, 67108864 | 1536 | 4 | 0.5 | 0.0 |
| 44 more fields, each under 0.5 MiB | | | 164 | 4.0 | 0.0 |
| **all Tables** | | | 217 | 22.9 | 0.0 |

- at exit, tablemaps: Rss 6.8 MiB, AnonHuge 0.0 MiB, 41 maps asking for huge pages
- at exit, segments: Rss 46.0 MiB, AnonHuge 14.0 MiB, 3 maps asking for huge pages
- at exit, other: Rss 19.0 MiB, AnonHuge 0.0 MiB, 0 maps asking for huge pages
- at exit, all: Rss 71.8 MiB, AnonHuge 14.0 MiB
  - segment map base=0x71ab38000000 len=32 MiB: Rss 3.7, AnonHuge 2.0, hg=1
  - segment map base=0x71ab3a000000 len=32 MiB: Rss 8.6, AnonHuge 0.0, hg=0
  - segment map base=0x71ab3c000000 len=128 MiB: Rss 13.6, AnonHuge 2.0, hg=1
  - segment map base=0x71ab44000000 len=32 MiB: Rss 0.9, AnonHuge 0.0, hg=0
  - segment map base=0x71ab46000000 len=96 MiB: Rss 19.2, AnonHuge 10.0, hg=1

### nuxt c4, N=32

peak RSS 501 MiB; threads reserving Tables: 4 (58, 53, 53, 53 each); Tables: 217, 159 measured as dropped, the rest at exit

| Table | element, n | reserved MiB | count | Rss MiB | AnonHuge MiB |
|---|---|---:|---:|---:|---:|
| store.types | Type, 134217728 | 4608 | 4 | 17.2 | 0.0 |
| store.value_symbol_links | ValueSymbolLinks, 134217728 | 2048 | 4 | 16.5 | 0.0 |
| ids.binder | BinderSym, 134217728 | 4096 | 1 | 13.9 | 0.0 |
| store.type_lists | u32, 536870912 | 2048 | 4 | 10.9 | 0.0 |
| checker.syms | CheckerSymbol, 67108864 | 1024 | 4 | 6.8 | 0.0 |
| store.type_node_links | TypeNodeLinks, 134217728 | 512 | 4 | 6.4 | 0.0 |
| store.mappers | TypeMapper, 16777216 | 256 | 4 | 6.2 | 0.0 |
| store.symbol_node_links | SymbolNodeLinks, 134217728 | 512 | 4 | 6.2 | 0.0 |
| checker.symbol_data | SymbolData, 67108864 | 1792 | 4 | 5.6 | 0.0 |
| store.u32_lists | u32, 536870912 | 2048 | 4 | 4.7 | 0.0 |
| store.signature_links | SignatureLinks, 134217728 | 512 | 4 | 4.7 | 0.0 |
| store.structured | StructuredType, 67108864 | 1024 | 4 | 3.5 | 0.0 |
| store.signatures | Signature, 33554432 | 1152 | 4 | 2.9 | 0.0 |
| checker.tab_entries | TableEntry, 268435456 | 2048 | 4 | 2.8 | 0.0 |
| store.merged_symbols | u32, 134217728 | 512 | 4 | 2.2 | 0.0 |
| store.small_kinds | SmallKind, 67108864 | 2560 | 4 | 2.1 | 0.0 |
| checker.lazy_index | u32, 134217728 | 512 | 4 | 1.9 | 0.0 |
| checker.base_constraints | u32, 134217728 | 512 | 4 | 1.9 | 0.0 |
| store.union_or_intersection_extras | UnionOrIntersectionExtra, 67108864 | 2816 | 4 | 1.9 | 0.0 |
| store.value_symbol_extras | ValueSymbolExtra, 134217728 | 1536 | 4 | 1.7 | 0.0 |
| store.literals | LiteralType, 67108864 | 1536 | 4 | 1.6 | 0.0 |
| store.structured_extras | StructuredExtra, 67108864 | 1536 | 4 | 1.6 | 0.0 |
| store.symbol_reference_links | SymbolReferenceLinks, 134217728 | 512 | 4 | 1.6 | 0.0 |
| store.union_or_intersections | UnionOrIntersectionType, 67108864 | 768 | 4 | 1.5 | 0.0 |
| ids.tab_loc | TabLoc, 134217728 | 1536 | 1 | 1.4 | 0.0 |
| store.declared_type_links | DeclaredTypeLinks, 134217728 | 1024 | 4 | 1.4 | 0.0 |
| checker.tab_heads | TabHead, 67108864 | 768 | 4 | 1.4 | 0.0 |
| store.references | TypeReference, 67108864 | 1280 | 4 | 1.2 | 0.0 |
| store.type_parameters | TypeParameter, 67108864 | 1536 | 4 | 1.1 | 0.0 |
| store.signature_extras | SignatureExtra, 33554432 | 1024 | 4 | 1.1 | 0.0 |
| store.mapped_symbol_links | MappedSymbolLinks, 134217728 | 1024 | 4 | 1.0 | 0.0 |
| store.alias_symbol_links | AliasSymbolLinks, 134217728 | 1536 | 4 | 0.9 | 0.0 |
| store.members_links | MembersLinks, 134217728 | 512 | 4 | 0.9 | 0.0 |
| store.alias_targets | u32, 134217728 | 512 | 4 | 0.7 | 0.0 |
| store.type_aliases | TypeAlias, 2097152 | 24 | 4 | 0.6 | 0.0 |
| store.string_literal_types | u32, 134217728 | 512 | 4 | 0.6 | 0.0 |
| store.interfaces | InterfaceType, 67108864 | 4096 | 4 | 0.5 | 0.0 |
| store.structured_member_records | StructuredMembers, 67108864 | 512 | 4 | 0.5 | 0.0 |
| 20 more fields, each under 0.5 MiB | | | 71 | 3.4 | 0.0 |
| **all Tables** | | | 217 | 142.9 | 0.0 |

- at exit, tablemaps: Rss 51.4 MiB, AnonHuge 0.0 MiB, 41 maps asking for huge pages
- at exit, segments: Rss 341.2 MiB, AnonHuge 134.0 MiB, 9 maps asking for huge pages
- at exit, other: Rss 24.3 MiB, AnonHuge 0.0 MiB, 0 maps asking for huge pages
- at exit, all: Rss 416.9 MiB, AnonHuge 134.0 MiB
  - segment map base=0x75ea30800000 len=56 MiB: Rss 31.0, AnonHuge 0.0, hg=0
  - segment map base=0x75ea34000000 len=96 MiB: Rss 60.8, AnonHuge 32.0, hg=1
  - segment map base=0x75ea3a000000 len=32 MiB: Rss 23.4, AnonHuge 0.0, hg=0
  - segment map base=0x75ea3c000000 len=96 MiB: Rss 45.1, AnonHuge 34.0, hg=1
  - segment map base=0x75ea42000000 len=32 MiB: Rss 3.9, AnonHuge 0.0, hg=0
  - segment map base=0x75ea44000000 len=64 MiB: Rss 37.8, AnonHuge 20.0, hg=1
  - segment map base=0x75ea48000000 len=60 MiB: Rss 58.9, AnonHuge 0.0, hg=0
  - segment map base=0x75ea4bc00000 len=4 MiB: Rss 4.0, AnonHuge 4.0, hg=1
  - segment map base=0x75ea4c000000 len=32 MiB: Rss 11.8, AnonHuge 0.0, hg=0
  - segment map base=0x75ea4e000000 len=36 MiB: Rss 8.0, AnonHuge 8.0, hg=1
  - segment map base=0x75ea50400000 len=4 MiB: Rss 3.9, AnonHuge 0.0, hg=0
  - segment map base=0x75ea50800000 len=4 MiB: Rss 4.0, AnonHuge 2.0, hg=1
  - segment map base=0x75ea50c00000 len=4 MiB: Rss 3.9, AnonHuge 0.0, hg=0
  - segment map base=0x75ea51000000 len=12 MiB: Rss 10.0, AnonHuge 10.0, hg=1
  - segment map base=0x75ea51c00000 len=4 MiB: Rss 3.5, AnonHuge 0.0, hg=0
  - segment map base=0x75ea52000000 len=16 MiB: Rss 16.0, AnonHuge 16.0, hg=1
  - segment map base=0x75ea53000000 len=8 MiB: Rss 7.2, AnonHuge 0.0, hg=0
  - segment map base=0x75ea53800000 len=12 MiB: Rss 8.0, AnonHuge 8.0, hg=1

## A: the knob

`RIG_HUGE_MIN_MB` (src/alloc.zig `huge_min`, `hugeMin`, `HugeMinMatch`):

- **How it's read:** once, with the THP mode (`readThpMode`), from `/proc/self/environ`. That works before `main` has its environment. The value is whole MiB, rounded up to whole 2 MiB pages, at least 2. Unset, or not a number, means 2 MiB, today's behaviour.
- **Where it applies:**
  - A reserved Table keeps small pages for its first `huge_min` bytes and asks for huge pages past that. Design A, "only pushed Tables ask", is not on main (383a1b2b5). The knob doesn't change which Tables ask, only where the ask starts, so it composes with Design A when that lands.
  - A heap's segment or span segment asks once the heap has taken more than `huge_min`, counting that segment. At 2 every segment asks, as today.
  - A large block asks when it is at least `huge_min` (today: 2 MiB). An mremap growth crossing `huge_min` asks the same way.
  - Below the size the range keeps small pages: nothing to ask under `madvise`, and MADV_NOHUGEPAGE under `always`.
- **Cost:** nothing per allocation. The checks sit where `ask` already ran (a new segment, a large map, an mremap, a Table reserve), and the threshold is a load in place of a constant.
- **Test:** `RIG_HUGE_MIN_MB is read whole MiB, in whole huge pages`, the parser fed whole and a byte at a time. The doc comment and docs/internals/INTERNALS.md say what it does and its default.

**Binary** (one, for the race; set N per arm with the env var): PGO+BOLT through Trig's pipeline on pup (release-slot on E-cores 12-19, 13 GB; `tools/trig/pgo --relocs`, then `tools/trig/bolt-apply`). Trig d78aa3f3, Rig ce8f7f9ac.

- pup:/zfs/trig-pup/thp-size/trig-knob-bolt (copy of runs/thp-size/.zig-cache/trig-tests/packs/trig-pgo/bin-bolt)
- sha256 b84853ebce3a01dbd42d44663b7c095c93a01300407825e963a89b796358f4c5
- PGO started 16:20, bin done about 17:33, the relocs link queued 40 min in release-slot, BOLT done 18:47.

**stdout:** main's b1r bin-bolt (sha256 d8c02087…ffec2) against the knob binary unset and at N=2, 8 and 32, on Compiler c4 and nuxt c4. All identical (`cmp`).

Peak RSS from those single runs (MiB):

| | main | knob unset | N=2 | N=8 | N=32 |
|---|---:|---:|---:|---:|---:|
| Compiler c4 | 121.2 | 123.0 | 121.0 | 94.2 | 84.3 |
| nuxt c4 | 497.2 | 494.4 | 494.5 | 477.0 | 471.4 |

**A/A instructions** (`perf stat -e instructions:u`, Compiler c4, 5 runs each, interleaved, E-cores, under the lock; cpu_atom counts):

- main: 1797996337 1798033932 1798062157 1797934944 1797983810 (median 1,797,996,337)
- knob unset: 1797974587 1797946788 1797490302 1797789632 1797972309 (median 1,797,946,788)
- Difference: −0.003% by median, −0.009% by mean. Within run-to-run spread, as expected from a binary PGO-trained separately.

## Couldn't do / caveats

- **No per-heap totals.** Segment VMAs merge across heaps, so the census gives per-mapping ranges (base, len, Rss, AnonHuge) in the segments' region instead.
- **One run per cell, wall not meaningful** (the PGO build shared the E-cores for some runs). The N=8/32 census ran after the PGO compile, with 690 free blocks. One earlier attempt, at 5 free blocks during the PGO build, was discarded, since a count that low shuts the huge-page gates.
- **Process slips on pup:**
  - My `tools/pup cli` runs on pup (15:08 and 15:57) held off slots 731 and 733; the coordinator stopped both.
  - I also started the PGO build at 16:10:57 on a go that was withdrawn, and stopped it at 16:11:13.
  - An early slot guard of mine self-matched `pgrep -f "pup-slot open"`; it now uses `[p]up-slot open`.

## Raw: per-Table address ranges (N=2)

Full raw stderr for every run: raw/n2, raw/n8, raw/n32 (`rig-table-rss:` lines). pup: /zfs/trig-pup/thp-size/census-n*/.

### compiler c4, N=2 (one line per Table: thread, field, base, reserved bytes, rss, anonhuge, dropped)

```
table tid=1932843 field=ids.sym_base base=0x78494c400000 reserved=2097152 rss=4096 anonhuge=0 dropped=0
table tid=1932843 field=ids.tab_base base=0x78494c600000 reserved=2097152 rss=4096 anonhuge=0 dropped=0
table tid=1932843 field=ids.binder base=0x78494c800000 reserved=4294967296 rss=1224704 anonhuge=0 dropped=0
table tid=1932843 field=ids.tab_loc base=0x784a4c800000 reserved=1610612736 rss=139264 anonhuge=0 dropped=0
table tid=1932843 field=ids.node_base base=0x784aac800000 reserved=2097152 rss=4096 anonhuge=0 dropped=0
table tid=1932845 field=store.types base=0x784aaca00000 reserved=4831838208 rss=659456 anonhuge=0 dropped=0
table tid=1932845 field=store.literals base=0x784f2ca00000 reserved=1610612736 rss=208896 anonhuge=0 dropped=0
table tid=1932846 field=store.types base=0x784bcca00000 reserved=4831838208 rss=724992 anonhuge=0 dropped=1
table tid=1932847 field=store.types base=0x784ceca00000 reserved=4831838208 rss=724992 anonhuge=0 dropped=1
table tid=1932849 field=store.types base=0x784e0ca00000 reserved=4831838208 rss=741376 anonhuge=0 dropped=1
table tid=1932845 field=store.structured base=0x784f8ca00000 reserved=1073741824 rss=118784 anonhuge=0 dropped=0
table tid=1932846 field=store.literals base=0x784fcca00000 reserved=1610612736 rss=253952 anonhuge=0 dropped=1
table tid=1932847 field=store.literals base=0x78502ca00000 reserved=1610612736 rss=241664 anonhuge=0 dropped=1
table tid=1932849 field=store.literals base=0x78508ca00000 reserved=1610612736 rss=208896 anonhuge=0 dropped=1
table tid=1932845 field=store.references base=0x7850eca00000 reserved=1342177280 rss=28672 anonhuge=0 dropped=0
table tid=1932846 field=store.structured base=0x78513ca00000 reserved=1073741824 rss=126976 anonhuge=0 dropped=1
table tid=1932847 field=store.structured base=0x78517ca00000 reserved=1073741824 rss=131072 anonhuge=0 dropped=1
table tid=1932849 field=store.structured base=0x7851bca00000 reserved=1073741824 rss=155648 anonhuge=0 dropped=1
table tid=1932845 field=store.interfaces base=0x7851fca00000 reserved=4294967296 rss=20480 anonhuge=0 dropped=0
table tid=1932846 field=store.references base=0x7852fca00000 reserved=1342177280 rss=36864 anonhuge=0 dropped=1
table tid=1932847 field=store.references base=0x78534ca00000 reserved=1342177280 rss=36864 anonhuge=0 dropped=1
table tid=1932849 field=store.references base=0x78539ca00000 reserved=1342177280 rss=36864 anonhuge=0 dropped=1
table tid=1932845 field=store.union_or_intersections base=0x7853eca00000 reserved=805306368 rss=20480 anonhuge=0 dropped=0
table tid=1932846 field=store.interfaces base=0x78541ca00000 reserved=4294967296 rss=28672 anonhuge=0 dropped=1
table tid=1932847 field=store.interfaces base=0x78551ca00000 reserved=4294967296 rss=28672 anonhuge=0 dropped=1
table tid=1932849 field=store.interfaces base=0x78561ca00000 reserved=4294967296 rss=28672 anonhuge=0 dropped=1
table tid=1932845 field=store.type_parameters base=0x78571ca00000 reserved=1610612736 rss=16384 anonhuge=0 dropped=0
table tid=1932846 field=store.union_or_intersections base=0x78577ca00000 reserved=805306368 rss=12288 anonhuge=0 dropped=1
table tid=1932847 field=store.union_or_intersections base=0x7857aca00000 reserved=805306368 rss=16384 anonhuge=0 dropped=1
table tid=1932849 field=store.union_or_intersections base=0x7857dca00000 reserved=805306368 rss=16384 anonhuge=0 dropped=1
table tid=1932845 field=store.small_kinds base=0x78580ca00000 reserved=2684354560 rss=8192 anonhuge=0 dropped=0
table tid=1932846 field=store.type_parameters base=0x7858aca00000 reserved=1610612736 rss=20480 anonhuge=0 dropped=1
table tid=1932847 field=store.type_parameters base=0x78590ca00000 reserved=1610612736 rss=20480 anonhuge=0 dropped=1
table tid=1932849 field=store.type_parameters base=0x78596ca00000 reserved=1610612736 rss=24576 anonhuge=0 dropped=1
table tid=1932845 field=store.signatures base=0x7859cca00000 reserved=1207959552 rss=229376 anonhuge=0 dropped=0
table tid=1932846 field=store.small_kinds base=0x785a14a00000 reserved=2684354560 rss=8192 anonhuge=0 dropped=1
table tid=1932847 field=store.small_kinds base=0x785ab4a00000 reserved=2684354560 rss=8192 anonhuge=0 dropped=1
table tid=1932849 field=store.small_kinds base=0x785b54a00000 reserved=2684354560 rss=8192 anonhuge=0 dropped=1
table tid=1932845 field=store.composites base=0x785bf4a00000 reserved=6291456 rss=4096 anonhuge=0 dropped=0
table tid=1932846 field=store.signatures base=0x785bf5000000 reserved=1207959552 rss=217088 anonhuge=0 dropped=1
table tid=1932847 field=store.signatures base=0x785c3d000000 reserved=1207959552 rss=253952 anonhuge=0 dropped=1
table tid=1932849 field=store.signatures base=0x785c85000000 reserved=1207959552 rss=311296 anonhuge=0 dropped=1
table tid=1932845 field=store.type_predicates base=0x785ccd000000 reserved=67108864 rss=8192 anonhuge=0 dropped=0
table tid=1932846 field=store.composites base=0x785cd1000000 reserved=6291456 rss=4096 anonhuge=0 dropped=1
table tid=1932847 field=store.composites base=0x785cd1600000 reserved=6291456 rss=0 anonhuge=0 dropped=1
table tid=1932849 field=store.composites base=0x785cd1c00000 reserved=6291456 rss=0 anonhuge=0 dropped=1
table tid=1932845 field=store.index_infos base=0x785cd2200000 reserved=268435456 rss=12288 anonhuge=0 dropped=0
table tid=1932846 field=store.type_predicates base=0x785ce2200000 reserved=67108864 rss=8192 anonhuge=0 dropped=1
table tid=1932847 field=store.type_predicates base=0x785ce6200000 reserved=67108864 rss=12288 anonhuge=0 dropped=1
table tid=1932849 field=store.type_predicates base=0x785cea200000 reserved=67108864 rss=16384 anonhuge=0 dropped=1
table tid=1932845 field=store.type_aliases base=0x785cee200000 reserved=25165824 rss=4096 anonhuge=0 dropped=0
table tid=1932846 field=store.index_infos base=0x785cefa00000 reserved=268435456 rss=16384 anonhuge=0 dropped=1
table tid=1932847 field=store.index_infos base=0x785cffa00000 reserved=268435456 rss=16384 anonhuge=0 dropped=1
table tid=1932849 field=store.index_infos base=0x785d0fa00000 reserved=268435456 rss=16384 anonhuge=0 dropped=1
table tid=1932845 field=store.mappers base=0x785d1fa00000 reserved=268435456 rss=131072 anonhuge=0 dropped=0
table tid=1932846 field=store.type_aliases base=0x785d2fa00000 reserved=25165824 rss=4096 anonhuge=0 dropped=1
table tid=1932847 field=store.type_aliases base=0x785d31200000 reserved=25165824 rss=4096 anonhuge=0 dropped=1
table tid=1932849 field=store.type_aliases base=0x785d32a00000 reserved=25165824 rss=4096 anonhuge=0 dropped=1
table tid=1932845 field=store.value_symbol_extras base=0x785d34200000 reserved=1610612736 rss=28672 anonhuge=0 dropped=0
table tid=1932846 field=store.mappers base=0x785d94200000 reserved=268435456 rss=188416 anonhuge=0 dropped=1
table tid=1932847 field=store.mappers base=0x785da4200000 reserved=268435456 rss=217088 anonhuge=0 dropped=1
table tid=1932849 field=store.mappers base=0x785db4200000 reserved=268435456 rss=245760 anonhuge=0 dropped=1
table tid=1932845 field=store.structured_extras base=0x785dc4200000 reserved=1610612736 rss=126976 anonhuge=0 dropped=0
table tid=1932846 field=store.value_symbol_extras base=0x785e24200000 reserved=1610612736 rss=20480 anonhuge=0 dropped=1
table tid=1932847 field=store.value_symbol_extras base=0x785e84200000 reserved=1610612736 rss=32768 anonhuge=0 dropped=1
table tid=1932849 field=store.value_symbol_extras base=0x785ee4200000 reserved=1610612736 rss=32768 anonhuge=0 dropped=1
table tid=1932845 field=store.union_or_intersection_extras base=0x785f44200000 reserved=2952790016 rss=24576 anonhuge=0 dropped=0
table tid=1932846 field=store.structured_extras base=0x785ff4200000 reserved=1610612736 rss=114688 anonhuge=0 dropped=1
table tid=1932847 field=store.structured_extras base=0x786054200000 reserved=1610612736 rss=126976 anonhuge=0 dropped=1
table tid=1932849 field=store.structured_extras base=0x7860b4200000 reserved=1610612736 rss=155648 anonhuge=0 dropped=1
table tid=1932845 field=store.signature_extras base=0x786114200000 reserved=1073741824 rss=90112 anonhuge=0 dropped=0
table tid=1932846 field=store.union_or_intersection_extras base=0x786154200000 reserved=2952790016 rss=16384 anonhuge=0 dropped=1
table tid=1932847 field=store.union_or_intersection_extras base=0x786204200000 reserved=2952790016 rss=20480 anonhuge=0 dropped=1
table tid=1932849 field=store.union_or_intersection_extras base=0x7862b4200000 reserved=2952790016 rss=20480 anonhuge=0 dropped=1
table tid=1932845 field=store.structured_member_records base=0x786364200000 reserved=536870912 rss=8192 anonhuge=0 dropped=0
table tid=1932846 field=store.signature_extras base=0x786384200000 reserved=1073741824 rss=81920 anonhuge=0 dropped=1
table tid=1932847 field=store.signature_extras base=0x7863c4200000 reserved=1073741824 rss=81920 anonhuge=0 dropped=1
table tid=1932849 field=store.signature_extras base=0x786404200000 reserved=1073741824 rss=106496 anonhuge=0 dropped=1
table tid=1932845 field=store.type_lists base=0x786444200000 reserved=2147483648 rss=274432 anonhuge=0 dropped=0
table tid=1932846 field=store.structured_member_records base=0x7864c4200000 reserved=536870912 rss=12288 anonhuge=0 dropped=1
table tid=1932847 field=store.structured_member_records base=0x7864e4200000 reserved=536870912 rss=12288 anonhuge=0 dropped=1
table tid=1932849 field=store.structured_member_records base=0x786504200000 reserved=536870912 rss=12288 anonhuge=0 dropped=1
table tid=1932845 field=store.u32_lists base=0x786524200000 reserved=2147483648 rss=131072 anonhuge=0 dropped=0
table tid=1932846 field=store.type_lists base=0x7865a4200000 reserved=2147483648 rss=167936 anonhuge=0 dropped=1
table tid=1932847 field=store.type_lists base=0x786624200000 reserved=2147483648 rss=176128 anonhuge=0 dropped=1
table tid=1932849 field=store.type_lists base=0x7866a4200000 reserved=2147483648 rss=372736 anonhuge=0 dropped=1
table tid=1932845 field=store.signature_links base=0x786724200000 reserved=536870912 rss=720896 anonhuge=0 dropped=0
table tid=1932846 field=store.u32_lists base=0x786744200000 reserved=2147483648 rss=135168 anonhuge=0 dropped=1
table tid=1932847 field=store.u32_lists base=0x7867c4200000 reserved=2147483648 rss=155648 anonhuge=0 dropped=1
table tid=1932849 field=store.u32_lists base=0x786844200000 reserved=2147483648 rss=167936 anonhuge=0 dropped=1
table tid=1932845 field=store.symbol_node_links base=0x7868c4200000 reserved=536870912 rss=761856 anonhuge=0 dropped=0
table tid=1932846 field=store.signature_links base=0x7868e4200000 reserved=536870912 rss=507904 anonhuge=0 dropped=1
table tid=1932847 field=store.signature_links base=0x786904200000 reserved=536870912 rss=491520 anonhuge=0 dropped=1
table tid=1932849 field=store.signature_links base=0x786924200000 reserved=536870912 rss=610304 anonhuge=0 dropped=1
table tid=1932845 field=store.type_node_links base=0x786944200000 reserved=536870912 rss=720896 anonhuge=0 dropped=0
table tid=1932846 field=store.symbol_node_links base=0x786964200000 reserved=536870912 rss=557056 anonhuge=0 dropped=1
table tid=1932847 field=store.symbol_node_links base=0x786984200000 reserved=536870912 rss=552960 anonhuge=0 dropped=1
table tid=1932849 field=store.symbol_node_links base=0x7869a4200000 reserved=536870912 rss=651264 anonhuge=0 dropped=1
table tid=1932845 field=store.symbol_reference_links base=0x7869c4200000 reserved=536870912 rss=65536 anonhuge=0 dropped=0
table tid=1932846 field=store.type_node_links base=0x7869e4200000 reserved=536870912 rss=507904 anonhuge=0 dropped=1
table tid=1932847 field=store.type_node_links base=0x786a04200000 reserved=536870912 rss=503808 anonhuge=0 dropped=1
table tid=1932849 field=store.type_node_links base=0x786a24200000 reserved=536870912 rss=610304 anonhuge=0 dropped=1
table tid=1932845 field=store.value_symbol_links base=0x786a44200000 reserved=2147483648 rss=557056 anonhuge=0 dropped=0
table tid=1932846 field=store.symbol_reference_links base=0x786ac4200000 reserved=536870912 rss=61440 anonhuge=0 dropped=1
table tid=1932847 field=store.symbol_reference_links base=0x786ae4200000 reserved=536870912 rss=61440 anonhuge=0 dropped=1
table tid=1932849 field=store.symbol_reference_links base=0x786b04200000 reserved=536870912 rss=69632 anonhuge=0 dropped=1
table tid=1932845 field=store.mapped_symbol_links base=0x786b24200000 reserved=1073741824 rss=24576 anonhuge=0 dropped=0
table tid=1932846 field=store.value_symbol_links base=0x786b64200000 reserved=2147483648 rss=557056 anonhuge=0 dropped=1
table tid=1932847 field=store.value_symbol_links base=0x786be4200000 reserved=2147483648 rss=585728 anonhuge=0 dropped=1
table tid=1932849 field=store.value_symbol_links base=0x786c64200000 reserved=2147483648 rss=663552 anonhuge=0 dropped=1
table tid=1932845 field=store.alias_symbol_links base=0x786ce4200000 reserved=1610612736 rss=0 anonhuge=0 dropped=0
table tid=1932846 field=store.mapped_symbol_links base=0x786d44200000 reserved=1073741824 rss=12288 anonhuge=0 dropped=1
table tid=1932847 field=store.mapped_symbol_links base=0x786d84200000 reserved=1073741824 rss=28672 anonhuge=0 dropped=1
table tid=1932849 field=store.mapped_symbol_links base=0x786dc4200000 reserved=1073741824 rss=32768 anonhuge=0 dropped=1
table tid=1932845 field=store.late_bound_links base=0x786e04200000 reserved=536870912 rss=4096 anonhuge=0 dropped=0
table tid=1932846 field=store.alias_symbol_links base=0x786e24200000 reserved=1610612736 rss=0 anonhuge=0 dropped=1
table tid=1932847 field=store.alias_symbol_links base=0x786e84200000 reserved=1610612736 rss=0 anonhuge=0 dropped=1
table tid=1932849 field=store.alias_symbol_links base=0x786ee4200000 reserved=1610612736 rss=0 anonhuge=0 dropped=1
table tid=1932845 field=store.declared_type_links base=0x786f44200000 reserved=1073741824 rss=53248 anonhuge=0 dropped=0
table tid=1932846 field=store.late_bound_links base=0x786f84200000 reserved=536870912 rss=4096 anonhuge=0 dropped=1
table tid=1932847 field=store.late_bound_links base=0x786fa4200000 reserved=536870912 rss=4096 anonhuge=0 dropped=1
table tid=1932849 field=store.late_bound_links base=0x786fc4200000 reserved=536870912 rss=4096 anonhuge=0 dropped=1
table tid=1932845 field=store.members_links base=0x786fe4200000 reserved=536870912 rss=20480 anonhuge=0 dropped=0
table tid=1932846 field=store.declared_type_links base=0x787004200000 reserved=1073741824 rss=69632 anonhuge=0 dropped=1
table tid=1932847 field=store.declared_type_links base=0x787044200000 reserved=1073741824 rss=61440 anonhuge=0 dropped=1
table tid=1932849 field=store.declared_type_links base=0x787084200000 reserved=1073741824 rss=65536 anonhuge=0 dropped=1
table tid=1932845 field=store.signature_links_pages base=0x7870c4200000 reserved=4194304 rss=16384 anonhuge=0 dropped=0
table tid=1932846 field=store.members_links base=0x7870c4600000 reserved=536870912 rss=36864 anonhuge=0 dropped=1
table tid=1932847 field=store.members_links base=0x7870e4600000 reserved=536870912 rss=28672 anonhuge=0 dropped=1
table tid=1932849 field=store.members_links base=0x787104600000 reserved=536870912 rss=28672 anonhuge=0 dropped=1
table tid=1932845 field=store.symbol_node_links_pages base=0x787124600000 reserved=4194304 rss=16384 anonhuge=0 dropped=0
table tid=1932846 field=store.signature_links_pages base=0x787124a00000 reserved=4194304 rss=16384 anonhuge=0 dropped=1
table tid=1932847 field=store.signature_links_pages base=0x787124e00000 reserved=4194304 rss=16384 anonhuge=0 dropped=1
table tid=1932849 field=store.signature_links_pages base=0x787125200000 reserved=4194304 rss=16384 anonhuge=0 dropped=1
table tid=1932845 field=store.type_node_links_pages base=0x787125600000 reserved=4194304 rss=16384 anonhuge=0 dropped=0
table tid=1932846 field=store.symbol_node_links_pages base=0x787125a00000 reserved=4194304 rss=16384 anonhuge=0 dropped=1
table tid=1932847 field=store.symbol_node_links_pages base=0x787125e00000 reserved=4194304 rss=16384 anonhuge=0 dropped=1
table tid=1932849 field=store.symbol_node_links_pages base=0x787126200000 reserved=4194304 rss=16384 anonhuge=0 dropped=1
table tid=1932845 field=store.symbol_reference_links_pages base=0x787126600000 reserved=16777216 rss=8192 anonhuge=0 dropped=0
table tid=1932846 field=store.type_node_links_pages base=0x787127600000 reserved=4194304 rss=16384 anonhuge=0 dropped=1
table tid=1932847 field=store.type_node_links_pages base=0x787127a00000 reserved=4194304 rss=16384 anonhuge=0 dropped=1
table tid=1932849 field=store.type_node_links_pages base=0x787127e00000 reserved=4194304 rss=16384 anonhuge=0 dropped=1
table tid=1932845 field=store.mapped_symbol_links_pages base=0x787128200000 reserved=16777216 rss=4096 anonhuge=0 dropped=0
table tid=1932846 field=store.symbol_reference_links_pages base=0x787129200000 reserved=16777216 rss=8192 anonhuge=0 dropped=1
table tid=1932847 field=store.symbol_reference_links_pages base=0x78712a200000 reserved=16777216 rss=8192 anonhuge=0 dropped=1
table tid=1932849 field=store.symbol_reference_links_pages base=0x78712b200000 reserved=16777216 rss=8192 anonhuge=0 dropped=1
table tid=1932845 field=store.alias_symbol_links_pages base=0x78712c200000 reserved=16777216 rss=0 anonhuge=0 dropped=0
table tid=1932846 field=store.mapped_symbol_links_pages base=0x78712d200000 reserved=16777216 rss=4096 anonhuge=0 dropped=1
table tid=1932847 field=store.mapped_symbol_links_pages base=0x78712e200000 reserved=16777216 rss=4096 anonhuge=0 dropped=1
table tid=1932849 field=store.mapped_symbol_links_pages base=0x78712f200000 reserved=16777216 rss=4096 anonhuge=0 dropped=1
table tid=1932845 field=store.late_bound_links_pages base=0x787130200000 reserved=16777216 rss=4096 anonhuge=0 dropped=0
table tid=1932846 field=store.alias_symbol_links_pages base=0x787131200000 reserved=16777216 rss=0 anonhuge=0 dropped=1
table tid=1932847 field=store.alias_symbol_links_pages base=0x787132200000 reserved=16777216 rss=0 anonhuge=0 dropped=1
table tid=1932849 field=store.alias_symbol_links_pages base=0x787133200000 reserved=16777216 rss=0 anonhuge=0 dropped=1
table tid=1932845 field=store.declared_type_links_pages base=0x787134200000 reserved=16777216 rss=8192 anonhuge=0 dropped=0
table tid=1932846 field=store.late_bound_links_pages base=0x787135200000 reserved=16777216 rss=4096 anonhuge=0 dropped=1
table tid=1932847 field=store.late_bound_links_pages base=0x787136200000 reserved=16777216 rss=4096 anonhuge=0 dropped=1
table tid=1932849 field=store.late_bound_links_pages base=0x787137200000 reserved=16777216 rss=4096 anonhuge=0 dropped=1
table tid=1932845 field=store.members_links_pages base=0x787138200000 reserved=16777216 rss=8192 anonhuge=0 dropped=0
table tid=1932846 field=store.declared_type_links_pages base=0x787139200000 reserved=16777216 rss=8192 anonhuge=0 dropped=1
table tid=1932847 field=store.declared_type_links_pages base=0x78713a200000 reserved=16777216 rss=8192 anonhuge=0 dropped=1
table tid=1932849 field=store.declared_type_links_pages base=0x78713b200000 reserved=16777216 rss=8192 anonhuge=0 dropped=1
table tid=1932845 field=store.merged_symbols base=0x78713c200000 reserved=536870912 rss=98304 anonhuge=0 dropped=0
table tid=1932846 field=store.members_links_pages base=0x78715c200000 reserved=16777216 rss=8192 anonhuge=0 dropped=1
table tid=1932847 field=store.members_links_pages base=0x78715d200000 reserved=16777216 rss=8192 anonhuge=0 dropped=1
table tid=1932849 field=store.members_links_pages base=0x78715e200000 reserved=16777216 rss=8192 anonhuge=0 dropped=1
table tid=1932845 field=store.alias_targets base=0x78715f200000 reserved=536870912 rss=0 anonhuge=0 dropped=0
table tid=1932846 field=store.merged_symbols base=0x78717f200000 reserved=536870912 rss=98304 anonhuge=0 dropped=1
table tid=1932847 field=store.merged_symbols base=0x78719f200000 reserved=536870912 rss=98304 anonhuge=0 dropped=1
table tid=1932849 field=store.merged_symbols base=0x7871bf200000 reserved=536870912 rss=98304 anonhuge=0 dropped=1
table tid=1932845 field=store.alias_targets_pages base=0x7871df200000 reserved=16777216 rss=0 anonhuge=0 dropped=0
table tid=1932846 field=store.alias_targets base=0x7871e0200000 reserved=536870912 rss=0 anonhuge=0 dropped=1
table tid=1932847 field=store.alias_targets base=0x787200200000 reserved=536870912 rss=0 anonhuge=0 dropped=1
table tid=1932849 field=store.alias_targets base=0x787220200000 reserved=536870912 rss=0 anonhuge=0 dropped=1
table tid=1932845 field=store.immediate_targets base=0x787240200000 reserved=536870912 rss=0 anonhuge=0 dropped=0
table tid=1932846 field=store.alias_targets_pages base=0x787260200000 reserved=16777216 rss=0 anonhuge=0 dropped=1
table tid=1932847 field=store.alias_targets_pages base=0x787261200000 reserved=16777216 rss=0 anonhuge=0 dropped=1
table tid=1932849 field=store.alias_targets_pages base=0x787262200000 reserved=16777216 rss=0 anonhuge=0 dropped=1
table tid=1932845 field=store.immediate_targets_pages base=0x787263200000 reserved=16777216 rss=0 anonhuge=0 dropped=0
table tid=1932846 field=store.immediate_targets base=0x787264200000 reserved=536870912 rss=0 anonhuge=0 dropped=1
table tid=1932847 field=store.immediate_targets base=0x787284200000 reserved=536870912 rss=0 anonhuge=0 dropped=1
table tid=1932849 field=store.immediate_targets base=0x7872a4200000 reserved=536870912 rss=0 anonhuge=0 dropped=1
table tid=1932845 field=store.string_literal_types base=0x7872c4200000 reserved=536870912 rss=28672 anonhuge=0 dropped=0
table tid=1932846 field=store.immediate_targets_pages base=0x7872e4200000 reserved=16777216 rss=0 anonhuge=0 dropped=1
table tid=1932847 field=store.immediate_targets_pages base=0x7872e5200000 reserved=16777216 rss=0 anonhuge=0 dropped=1
table tid=1932849 field=store.immediate_targets_pages base=0x7872e6200000 reserved=16777216 rss=0 anonhuge=0 dropped=1
table tid=1932845 field=store.string_literal_types_pages base=0x7872e7200000 reserved=16777216 rss=4096 anonhuge=0 dropped=0
table tid=1932846 field=store.string_literal_types base=0x7872e8200000 reserved=536870912 rss=28672 anonhuge=0 dropped=1
table tid=1932847 field=store.string_literal_types base=0x787308200000 reserved=536870912 rss=32768 anonhuge=0 dropped=1
table tid=1932849 field=store.string_literal_types base=0x787328200000 reserved=536870912 rss=32768 anonhuge=0 dropped=1
table tid=1932846 field=store.string_literal_types_pages base=0x787348200000 reserved=16777216 rss=4096 anonhuge=0 dropped=1
table tid=1932847 field=store.string_literal_types_pages base=0x787349200000 reserved=16777216 rss=4096 anonhuge=0 dropped=1
table tid=1932849 field=store.string_literal_types_pages base=0x78734a200000 reserved=16777216 rss=4096 anonhuge=0 dropped=1
table tid=1932845 field=checker.syms base=0x78734b200000 reserved=1073741824 rss=180224 anonhuge=0 dropped=0
table tid=1932845 field=checker.symbol_data base=0x78738b200000 reserved=1879048192 rss=94208 anonhuge=0 dropped=0
table tid=1932845 field=checker.lazy_index base=0x7873fb200000 reserved=536870912 rss=73728 anonhuge=0 dropped=0
table tid=1932845 field=checker.tab_heads base=0x78741b200000 reserved=805306368 rss=12288 anonhuge=0 dropped=0
table tid=1932845 field=checker.base_constraints base=0x78744b200000 reserved=536870912 rss=73728 anonhuge=0 dropped=0
table tid=1932846 field=checker.syms base=0x78746b200000 reserved=1073741824 rss=192512 anonhuge=0 dropped=1
table tid=1932847 field=checker.syms base=0x7874ab200000 reserved=1073741824 rss=237568 anonhuge=0 dropped=1
table tid=1932845 field=checker.tab_entries base=0x7874eb200000 reserved=2147483648 rss=24576 anonhuge=0 dropped=0
table tid=1932846 field=checker.symbol_data base=0x78756b200000 reserved=1879048192 rss=106496 anonhuge=0 dropped=1
table tid=1932849 field=checker.syms base=0x7875db200000 reserved=1073741824 rss=262144 anonhuge=0 dropped=1
table tid=1932847 field=checker.symbol_data base=0x78761b200000 reserved=1879048192 rss=110592 anonhuge=0 dropped=1
table tid=1932846 field=checker.lazy_index base=0x78768b200000 reserved=536870912 rss=81920 anonhuge=0 dropped=1
table tid=1932849 field=checker.symbol_data base=0x7876ab200000 reserved=1879048192 rss=114688 anonhuge=0 dropped=1
table tid=1932847 field=checker.lazy_index base=0x78771b200000 reserved=536870912 rss=81920 anonhuge=0 dropped=1
table tid=1932846 field=checker.tab_heads base=0x78773b200000 reserved=805306368 rss=16384 anonhuge=0 dropped=1
table tid=1932849 field=checker.lazy_index base=0x78776b200000 reserved=536870912 rss=86016 anonhuge=0 dropped=1
table tid=1932847 field=checker.tab_heads base=0x78778b200000 reserved=805306368 rss=12288 anonhuge=0 dropped=1
table tid=1932846 field=checker.base_constraints base=0x7877bb200000 reserved=536870912 rss=81920 anonhuge=0 dropped=1
table tid=1932849 field=checker.tab_heads base=0x7877db200000 reserved=805306368 rss=12288 anonhuge=0 dropped=1
table tid=1932847 field=checker.base_constraints base=0x78780b200000 reserved=536870912 rss=81920 anonhuge=0 dropped=1
table tid=1932846 field=checker.tab_entries base=0x78782b200000 reserved=2147483648 rss=36864 anonhuge=0 dropped=1
table tid=1932849 field=checker.base_constraints base=0x7878ab200000 reserved=536870912 rss=86016 anonhuge=0 dropped=1
table tid=1932847 field=checker.tab_entries base=0x7878cb200000 reserved=2147483648 rss=32768 anonhuge=0 dropped=1
table tid=1932849 field=checker.tab_entries base=0x78794b200000 reserved=2147483648 rss=32768 anonhuge=0 dropped=1
other base=0x1000000 len=18489344 rss=1822720 anonhuge=0 hg=0
other base=0x21a2000 len=13492224 rss=6139904 anonhuge=0 hg=0
other base=0x2e80000 len=4096 rss=4096 anonhuge=0 hg=0
other base=0x2e81000 len=24576 rss=12288 anonhuge=0 hg=0
other base=0x2e87000 len=360448 rss=57344 anonhuge=0 hg=0
other base=0x784941971000 len=1048576 rss=1048576 anonhuge=0 hg=0
other base=0x78894c6af000 len=94208 rss=49152 anonhuge=0 hg=0
other base=0x78894d6c6000 len=68157440 rss=69632 anonhuge=0 hg=0
other base=0x7889527c7000 len=68157440 rss=20480 anonhuge=0 hg=0
other base=0x78899d6d6000 len=180224 rss=139264 anonhuge=0 hg=0
other base=0x78899d783000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x78899e785000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x78899f787000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x7889a0789000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x7889a178b000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x7889a278d000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x7889a478e000 len=68157440 rss=135168 anonhuge=0 hg=0
other base=0x7889a988f000 len=68157440 rss=20480 anonhuge=0 hg=0
other base=0x7889f579e000 len=68157440 rss=73728 anonhuge=0 hg=0
other base=0x7889fa89f000 len=68157440 rss=118784 anonhuge=0 hg=0
other base=0x788a467ae000 len=68157440 rss=61440 anonhuge=0 hg=0
other base=0x788a4b8af000 len=68157440 rss=20480 anonhuge=0 hg=0
other base=0x788a977be000 len=68157440 rss=114688 anonhuge=0 hg=0
other base=0x788a9c8bf000 len=68157440 rss=110592 anonhuge=0 hg=0
other base=0x788ae87ce000 len=68157440 rss=69632 anonhuge=0 hg=0
other base=0x788b397de000 len=68157440 rss=73728 anonhuge=0 hg=0
other base=0x788b8a7ee000 len=68157440 rss=73728 anonhuge=0 hg=0
other base=0x788b8f8ef000 len=68157440 rss=20480 anonhuge=0 hg=0
other base=0x788bda7ff000 len=16781312 rss=8192 anonhuge=0 hg=0
segment base=0x788bdb800000 len=4194304 rss=4194304 anonhuge=4194304 hg=1
segment base=0x788bdc000000 len=62914560 rss=30941184 anonhuge=18874368 hg=1
segment base=0x788be0000000 len=134217728 rss=20000768 anonhuge=8388608 hg=1
segment base=0x788be8000000 len=37748736 rss=6066176 anonhuge=4194304 hg=1
segment base=0x788bec000000 len=92274688 rss=29650944 anonhuge=20971520 hg=1
other base=0x789bdbc06000 len=94208 rss=49152 anonhuge=0 hg=0
other base=0x789bdbc1d000 len=40960 rss=40960 anonhuge=0 hg=0
other base=0x789bdbc28000 len=86016 rss=24576 anonhuge=0 hg=0
other base=0x789bdbc3d000 len=1310720 rss=8192 anonhuge=0 hg=0
other base=0x789bdbd7d000 len=221184 rss=36864 anonhuge=0 hg=0
other base=0x789bdbdb3000 len=262144 rss=4096 anonhuge=0 hg=0
other base=0x78abdbdf3000 len=68157440 rss=192512 anonhuge=0 hg=0
other base=0x78abdfefa000 len=8192 rss=8192 anonhuge=0 hg=0
other base=0x7ffc4cd19000 len=135168 rss=8192 anonhuge=0 hg=0
```

### nuxt c4, N=2 (one line per Table: thread, field, base, reserved bytes, rss, anonhuge, dropped)

```
table tid=1932878 field=ids.sym_base base=0x74a74c200000 reserved=2097152 rss=16384 anonhuge=0 dropped=0
table tid=1932878 field=ids.tab_base base=0x74a74c400000 reserved=2097152 rss=16384 anonhuge=0 dropped=0
table tid=1932878 field=ids.binder base=0x74a74c600000 reserved=4294967296 rss=14680064 anonhuge=12582912 dropped=0
table tid=1932878 field=ids.tab_loc base=0x74a84c600000 reserved=1610612736 rss=1515520 anonhuge=0 dropped=0
table tid=1932878 field=ids.node_base base=0x74a8ac600000 reserved=2097152 rss=16384 anonhuge=0 dropped=0
table tid=1932876 field=store.types base=0x74a8ac800000 reserved=4831838208 rss=6291456 anonhuge=4194304 dropped=1
table tid=1932876 field=store.literals base=0x74a9cc800000 reserved=1610612736 rss=389120 anonhuge=0 dropped=1
table tid=1932876 field=store.structured base=0x74aa2c800000 reserved=1073741824 rss=987136 anonhuge=0 dropped=1
table tid=1932876 field=store.references base=0x74aa6c800000 reserved=1342177280 rss=274432 anonhuge=0 dropped=1
table tid=1932876 field=store.interfaces base=0x74aabc800000 reserved=4294967296 rss=143360 anonhuge=0 dropped=1
table tid=1932876 field=store.union_or_intersections base=0x74abbc800000 reserved=805306368 rss=385024 anonhuge=0 dropped=1
table tid=1932876 field=store.type_parameters base=0x74abec800000 reserved=1610612736 rss=299008 anonhuge=0 dropped=1
table tid=1932876 field=store.small_kinds base=0x74ac4c800000 reserved=2684354560 rss=671744 anonhuge=0 dropped=1
table tid=1932876 field=store.signatures base=0x74acec800000 reserved=1207959552 rss=811008 anonhuge=0 dropped=1
table tid=1932876 field=store.composites base=0x74ad34800000 reserved=6291456 rss=4096 anonhuge=0 dropped=1
table tid=1932876 field=store.type_predicates base=0x74ad34e00000 reserved=67108864 rss=8192 anonhuge=0 dropped=1
table tid=1932876 field=store.index_infos base=0x74ad38e00000 reserved=268435456 rss=98304 anonhuge=0 dropped=1
table tid=1932876 field=store.type_aliases base=0x74ad48e00000 reserved=25165824 rss=176128 anonhuge=0 dropped=1
table tid=1932876 field=store.mappers base=0x74ad4a600000 reserved=268435456 rss=1830912 anonhuge=0 dropped=1
table tid=1932876 field=store.value_symbol_extras base=0x74ad5a600000 reserved=1610612736 rss=466944 anonhuge=0 dropped=1
table tid=1932876 field=store.structured_extras base=0x74adba600000 reserved=1610612736 rss=466944 anonhuge=0 dropped=1
table tid=1932876 field=store.union_or_intersection_extras base=0x74ae1a600000 reserved=2952790016 rss=385024 anonhuge=0 dropped=1
table tid=1932876 field=store.signature_extras base=0x74aeca600000 reserved=1073741824 rss=286720 anonhuge=0 dropped=1
table tid=1932876 field=store.structured_member_records base=0x74af0a600000 reserved=536870912 rss=143360 anonhuge=0 dropped=1
table tid=1932880 field=store.types base=0x74af2a600000 reserved=4831838208 rss=6291456 anonhuge=4194304 dropped=0
table tid=1932876 field=store.type_lists base=0x74b04a600000 reserved=2147483648 rss=4194304 anonhuge=2097152 dropped=1
table tid=1932880 field=store.literals base=0x74b0ca600000 reserved=1610612736 rss=503808 anonhuge=0 dropped=0
table tid=1932876 field=store.u32_lists base=0x74b12a600000 reserved=2147483648 rss=1413120 anonhuge=0 dropped=1
table tid=1932880 field=store.structured base=0x74b1aa600000 reserved=1073741824 rss=974848 anonhuge=0 dropped=0
table tid=1932876 field=store.signature_links base=0x74b1ea600000 reserved=536870912 rss=1323008 anonhuge=0 dropped=1
table tid=1932880 field=store.references base=0x74b20a600000 reserved=1342177280 rss=339968 anonhuge=0 dropped=0
table tid=1932876 field=store.symbol_node_links base=0x74b25a600000 reserved=536870912 rss=1564672 anonhuge=0 dropped=1
table tid=1932880 field=store.interfaces base=0x74b27a600000 reserved=4294967296 rss=147456 anonhuge=0 dropped=0
table tid=1932876 field=store.type_node_links base=0x74b37a600000 reserved=536870912 rss=1695744 anonhuge=0 dropped=1
table tid=1932880 field=store.union_or_intersections base=0x74b39a600000 reserved=805306368 rss=491520 anonhuge=0 dropped=0
table tid=1932876 field=store.symbol_reference_links base=0x74b3ca600000 reserved=536870912 rss=507904 anonhuge=0 dropped=1
table tid=1932880 field=store.type_parameters base=0x74b3ea600000 reserved=1610612736 rss=344064 anonhuge=0 dropped=0
table tid=1932876 field=store.value_symbol_links base=0x74b44a600000 reserved=2147483648 rss=9179136 anonhuge=8388608 dropped=1
table tid=1932880 field=store.small_kinds base=0x74b4ca600000 reserved=2684354560 rss=630784 anonhuge=0 dropped=0
table tid=1932876 field=store.mapped_symbol_links base=0x74b56a600000 reserved=1073741824 rss=331776 anonhuge=0 dropped=1
table tid=1932880 field=store.signatures base=0x74b5aa600000 reserved=1207959552 rss=770048 anonhuge=0 dropped=0
table tid=1932876 field=store.alias_symbol_links base=0x74b5f2600000 reserved=1610612736 rss=327680 anonhuge=0 dropped=1
table tid=1932883 field=store.types base=0x74b652600000 reserved=4831838208 rss=4194304 anonhuge=2097152 dropped=1
table tid=1932880 field=store.composites base=0x74b772600000 reserved=6291456 rss=4096 anonhuge=0 dropped=0
table tid=1932876 field=store.late_bound_links base=0x74b772c00000 reserved=536870912 rss=12288 anonhuge=0 dropped=1
table tid=1932883 field=store.literals base=0x74b792c00000 reserved=1610612736 rss=303104 anonhuge=0 dropped=1
table tid=1932880 field=store.type_predicates base=0x74b7f2c00000 reserved=67108864 rss=12288 anonhuge=0 dropped=0
table tid=1932876 field=store.declared_type_links base=0x74b7f6c00000 reserved=1073741824 rss=385024 anonhuge=0 dropped=1
table tid=1932883 field=store.structured base=0x74b836c00000 reserved=1073741824 rss=729088 anonhuge=0 dropped=1
table tid=1932880 field=store.index_infos base=0x74b876c00000 reserved=268435456 rss=106496 anonhuge=0 dropped=0
table tid=1932876 field=store.members_links base=0x74b886c00000 reserved=536870912 rss=253952 anonhuge=0 dropped=1
table tid=1932883 field=store.references base=0x74b8a6c00000 reserved=1342177280 rss=241664 anonhuge=0 dropped=1
table tid=1932880 field=store.type_aliases base=0x74b8f6c00000 reserved=25165824 rss=237568 anonhuge=0 dropped=0
table tid=1932876 field=store.signature_links_pages base=0x74b8f8400000 reserved=4194304 rss=81920 anonhuge=0 dropped=1
table tid=1932883 field=store.interfaces base=0x74b8f8800000 reserved=4294967296 rss=122880 anonhuge=0 dropped=1
table tid=1932880 field=store.mappers base=0x74b9f8800000 reserved=268435456 rss=1814528 anonhuge=0 dropped=0
table tid=1932876 field=store.symbol_node_links_pages base=0x74ba08800000 reserved=4194304 rss=81920 anonhuge=0 dropped=1
table tid=1932883 field=store.union_or_intersections base=0x74ba08c00000 reserved=805306368 rss=196608 anonhuge=0 dropped=1
table tid=1932880 field=store.value_symbol_extras base=0x74ba38c00000 reserved=1610612736 rss=638976 anonhuge=0 dropped=0
table tid=1932876 field=store.type_node_links_pages base=0x74ba98c00000 reserved=4194304 rss=81920 anonhuge=0 dropped=1
table tid=1932883 field=store.type_parameters base=0x74ba99000000 reserved=1610612736 rss=176128 anonhuge=0 dropped=1
table tid=1932878 field=store.types base=0x74baf9000000 reserved=4831838208 rss=6291456 anonhuge=4194304 dropped=1
table tid=1932880 field=store.structured_extras base=0x74bc19000000 reserved=1610612736 rss=454656 anonhuge=0 dropped=0
table tid=1932876 field=store.symbol_reference_links_pages base=0x74bc79000000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932883 field=store.small_kinds base=0x74bc7a000000 reserved=2684354560 rss=299008 anonhuge=0 dropped=1
table tid=1932878 field=store.literals base=0x74bd1a000000 reserved=1610612736 rss=495616 anonhuge=0 dropped=1
table tid=1932880 field=store.union_or_intersection_extras base=0x74bd7a000000 reserved=2952790016 rss=589824 anonhuge=0 dropped=0
table tid=1932876 field=store.mapped_symbol_links_pages base=0x74be2a000000 reserved=16777216 rss=16384 anonhuge=0 dropped=1
table tid=1932883 field=store.signatures base=0x74be2b000000 reserved=1207959552 rss=626688 anonhuge=0 dropped=1
table tid=1932878 field=store.structured base=0x74be73000000 reserved=1073741824 rss=991232 anonhuge=0 dropped=1
table tid=1932880 field=store.signature_extras base=0x74beb3000000 reserved=1073741824 rss=274432 anonhuge=0 dropped=0
table tid=1932876 field=store.alias_symbol_links_pages base=0x74bef3000000 reserved=16777216 rss=53248 anonhuge=0 dropped=1
table tid=1932883 field=store.composites base=0x74bef4000000 reserved=6291456 rss=4096 anonhuge=0 dropped=1
table tid=1932878 field=store.references base=0x74bef4600000 reserved=1342177280 rss=356352 anonhuge=0 dropped=1
table tid=1932880 field=store.structured_member_records base=0x74bf44600000 reserved=536870912 rss=147456 anonhuge=0 dropped=0
table tid=1932876 field=store.late_bound_links_pages base=0x74bf64600000 reserved=16777216 rss=53248 anonhuge=0 dropped=1
table tid=1932883 field=store.type_predicates base=0x74bf65600000 reserved=67108864 rss=8192 anonhuge=0 dropped=1
table tid=1932878 field=store.interfaces base=0x74bf69600000 reserved=4294967296 rss=147456 anonhuge=0 dropped=1
table tid=1932880 field=store.type_lists base=0x74c069600000 reserved=2147483648 rss=4194304 anonhuge=2097152 dropped=0
table tid=1932876 field=store.declared_type_links_pages base=0x74c0e9600000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932883 field=store.index_infos base=0x74c0ea600000 reserved=268435456 rss=65536 anonhuge=0 dropped=1
table tid=1932878 field=store.union_or_intersections base=0x74c0fa600000 reserved=805306368 rss=475136 anonhuge=0 dropped=1
table tid=1932880 field=store.u32_lists base=0x74c12a600000 reserved=2147483648 rss=958464 anonhuge=0 dropped=0
table tid=1932876 field=store.members_links_pages base=0x74c1aa600000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932883 field=store.type_aliases base=0x74c1ab600000 reserved=25165824 rss=98304 anonhuge=0 dropped=1
table tid=1932878 field=store.type_parameters base=0x74c1ace00000 reserved=1610612736 rss=286720 anonhuge=0 dropped=1
table tid=1932880 field=store.signature_links base=0x74c20ce00000 reserved=536870912 rss=1269760 anonhuge=0 dropped=0
table tid=1932876 field=store.merged_symbols base=0x74c22ce00000 reserved=536870912 rss=569344 anonhuge=0 dropped=1
table tid=1932883 field=store.mappers base=0x74c24ce00000 reserved=268435456 rss=1028096 anonhuge=0 dropped=1
table tid=1932878 field=store.small_kinds base=0x74c25ce00000 reserved=2684354560 rss=634880 anonhuge=0 dropped=1
table tid=1932880 field=store.symbol_node_links base=0x74c2fce00000 reserved=536870912 rss=1814528 anonhuge=0 dropped=0
table tid=1932876 field=store.alias_targets base=0x74c31ce00000 reserved=536870912 rss=241664 anonhuge=0 dropped=1
table tid=1932883 field=store.value_symbol_extras base=0x74c33ce00000 reserved=1610612736 rss=163840 anonhuge=0 dropped=1
table tid=1932878 field=store.signatures base=0x74c39ce00000 reserved=1207959552 rss=782336 anonhuge=0 dropped=1
table tid=1932880 field=store.type_node_links base=0x74c3e4e00000 reserved=536870912 rss=1892352 anonhuge=0 dropped=0
table tid=1932876 field=store.alias_targets_pages base=0x74c404e00000 reserved=16777216 rss=69632 anonhuge=0 dropped=1
table tid=1932878 field=store.composites base=0x74c405e00000 reserved=6291456 rss=4096 anonhuge=0 dropped=1
table tid=1932883 field=store.structured_extras base=0x74c406400000 reserved=1610612736 rss=339968 anonhuge=0 dropped=1
table tid=1932880 field=store.symbol_reference_links base=0x74c466400000 reserved=536870912 rss=356352 anonhuge=0 dropped=0
table tid=1932876 field=store.immediate_targets base=0x74c486400000 reserved=536870912 rss=65536 anonhuge=0 dropped=1
table tid=1932878 field=store.type_predicates base=0x74c4a6400000 reserved=67108864 rss=8192 anonhuge=0 dropped=1
table tid=1932883 field=store.union_or_intersection_extras base=0x74c4aa400000 reserved=2952790016 rss=204800 anonhuge=0 dropped=1
table tid=1932880 field=store.value_symbol_links base=0x74c55a400000 reserved=2147483648 rss=9097216 anonhuge=8388608 dropped=0
table tid=1932876 field=store.immediate_targets_pages base=0x74c5da400000 reserved=16777216 rss=65536 anonhuge=0 dropped=1
table tid=1932878 field=store.index_infos base=0x74c5db400000 reserved=268435456 rss=106496 anonhuge=0 dropped=1
table tid=1932883 field=store.signature_extras base=0x74c5eb400000 reserved=1073741824 rss=253952 anonhuge=0 dropped=1
table tid=1932880 field=store.mapped_symbol_links base=0x74c62b400000 reserved=1073741824 rss=344064 anonhuge=0 dropped=0
table tid=1932876 field=store.string_literal_types base=0x74c66b400000 reserved=536870912 rss=155648 anonhuge=0 dropped=1
table tid=1932878 field=store.type_aliases base=0x74c68b400000 reserved=25165824 rss=163840 anonhuge=0 dropped=1
table tid=1932883 field=store.structured_member_records base=0x74c68cc00000 reserved=536870912 rss=98304 anonhuge=0 dropped=1
table tid=1932880 field=store.alias_symbol_links base=0x74c6acc00000 reserved=1610612736 rss=188416 anonhuge=0 dropped=0
table tid=1932876 field=store.string_literal_types_pages base=0x74c70cc00000 reserved=16777216 rss=16384 anonhuge=0 dropped=1
table tid=1932878 field=store.mappers base=0x74c70dc00000 reserved=268435456 rss=1814528 anonhuge=0 dropped=1
table tid=1932883 field=store.type_lists base=0x74c71dc00000 reserved=2147483648 rss=1105920 anonhuge=0 dropped=1
table tid=1932880 field=store.late_bound_links base=0x74c79dc00000 reserved=536870912 rss=12288 anonhuge=0 dropped=0
table tid=1932878 field=store.value_symbol_extras base=0x74c7bdc00000 reserved=1610612736 rss=503808 anonhuge=0 dropped=1
table tid=1932883 field=store.u32_lists base=0x74c81dc00000 reserved=2147483648 rss=1122304 anonhuge=0 dropped=1
table tid=1932880 field=store.declared_type_links base=0x74c89dc00000 reserved=1073741824 rss=393216 anonhuge=0 dropped=0
table tid=1932878 field=store.structured_extras base=0x74c8ddc00000 reserved=1610612736 rss=425984 anonhuge=0 dropped=1
table tid=1932883 field=store.signature_links base=0x74c93dc00000 reserved=536870912 rss=1077248 anonhuge=0 dropped=1
table tid=1932880 field=store.members_links base=0x74c95dc00000 reserved=536870912 rss=241664 anonhuge=0 dropped=0
table tid=1932878 field=store.union_or_intersection_extras base=0x74c97dc00000 reserved=2952790016 rss=786432 anonhuge=0 dropped=1
table tid=1932883 field=store.symbol_node_links base=0x74ca2dc00000 reserved=536870912 rss=1425408 anonhuge=0 dropped=1
table tid=1932880 field=store.signature_links_pages base=0x74ca4dc00000 reserved=4194304 rss=81920 anonhuge=0 dropped=0
table tid=1932878 field=store.signature_extras base=0x74ca4e000000 reserved=1073741824 rss=286720 anonhuge=0 dropped=1
table tid=1932876 field=checker.syms base=0x74ca8e000000 reserved=1073741824 rss=1900544 anonhuge=0 dropped=1
table tid=1932883 field=store.type_node_links base=0x74cace000000 reserved=536870912 rss=1445888 anonhuge=0 dropped=1
table tid=1932880 field=store.symbol_node_links_pages base=0x74caee000000 reserved=4194304 rss=81920 anonhuge=0 dropped=0
table tid=1932878 field=store.structured_member_records base=0x74caee400000 reserved=536870912 rss=147456 anonhuge=0 dropped=1
table tid=1932876 field=checker.symbol_data base=0x74cb0e400000 reserved=1879048192 rss=1527808 anonhuge=0 dropped=1
table tid=1932883 field=store.symbol_reference_links base=0x74cb7e400000 reserved=536870912 rss=499712 anonhuge=0 dropped=1
table tid=1932880 field=store.type_node_links_pages base=0x74cb9e400000 reserved=4194304 rss=81920 anonhuge=0 dropped=0
table tid=1932878 field=store.type_lists base=0x74cb9e800000 reserved=2147483648 rss=4194304 anonhuge=2097152 dropped=1
table tid=1932876 field=checker.lazy_index base=0x74cc1e800000 reserved=536870912 rss=520192 anonhuge=0 dropped=1
table tid=1932883 field=store.value_symbol_links base=0x74cc3e800000 reserved=2147483648 rss=9039872 anonhuge=8388608 dropped=1
table tid=1932880 field=store.symbol_reference_links_pages base=0x74ccbe800000 reserved=16777216 rss=61440 anonhuge=0 dropped=0
table tid=1932878 field=store.u32_lists base=0x74ccbf800000 reserved=2147483648 rss=1392640 anonhuge=0 dropped=1
table tid=1932876 field=checker.tab_heads base=0x74cd3f800000 reserved=805306368 rss=352256 anonhuge=0 dropped=1
table tid=1932883 field=store.mapped_symbol_links base=0x74cd6f800000 reserved=1073741824 rss=114688 anonhuge=0 dropped=1
table tid=1932880 field=store.mapped_symbol_links_pages base=0x74cdaf800000 reserved=16777216 rss=16384 anonhuge=0 dropped=0
table tid=1932878 field=store.signature_links base=0x74cdb0800000 reserved=536870912 rss=1216512 anonhuge=0 dropped=1
table tid=1932876 field=checker.base_constraints base=0x74cdd0800000 reserved=536870912 rss=520192 anonhuge=0 dropped=1
table tid=1932883 field=store.alias_symbol_links base=0x74cdf0800000 reserved=1610612736 rss=290816 anonhuge=0 dropped=1
table tid=1932880 field=store.alias_symbol_links_pages base=0x74ce50800000 reserved=16777216 rss=53248 anonhuge=0 dropped=0
table tid=1932878 field=store.symbol_node_links base=0x74ce51800000 reserved=536870912 rss=1646592 anonhuge=0 dropped=1
table tid=1932876 field=checker.tab_entries base=0x74ce71800000 reserved=2147483648 rss=729088 anonhuge=0 dropped=1
table tid=1932883 field=store.late_bound_links base=0x74cef1800000 reserved=536870912 rss=12288 anonhuge=0 dropped=1
table tid=1932880 field=store.late_bound_links_pages base=0x74cf11800000 reserved=16777216 rss=53248 anonhuge=0 dropped=0
table tid=1932878 field=store.type_node_links base=0x74cf12800000 reserved=536870912 rss=1675264 anonhuge=0 dropped=1
table tid=1932883 field=store.declared_type_links base=0x74cf32800000 reserved=1073741824 rss=356352 anonhuge=0 dropped=1
table tid=1932880 field=store.declared_type_links_pages base=0x74cf72800000 reserved=16777216 rss=61440 anonhuge=0 dropped=0
table tid=1932878 field=store.symbol_reference_links base=0x74cf73800000 reserved=536870912 rss=303104 anonhuge=0 dropped=1
table tid=1932883 field=store.members_links base=0x74cf93800000 reserved=536870912 rss=204800 anonhuge=0 dropped=1
table tid=1932880 field=store.members_links_pages base=0x74cfb3800000 reserved=16777216 rss=61440 anonhuge=0 dropped=0
table tid=1932878 field=store.value_symbol_links base=0x74cfb4800000 reserved=2147483648 rss=9035776 anonhuge=8388608 dropped=1
table tid=1932883 field=store.signature_links_pages base=0x74d034800000 reserved=4194304 rss=81920 anonhuge=0 dropped=1
table tid=1932880 field=store.merged_symbols base=0x74d034c00000 reserved=536870912 rss=569344 anonhuge=0 dropped=0
table tid=1932878 field=store.mapped_symbol_links base=0x74d054c00000 reserved=1073741824 rss=286720 anonhuge=0 dropped=1
table tid=1932883 field=store.symbol_node_links_pages base=0x74d094c00000 reserved=4194304 rss=81920 anonhuge=0 dropped=1
table tid=1932880 field=store.alias_targets base=0x74d095000000 reserved=536870912 rss=131072 anonhuge=0 dropped=0
table tid=1932878 field=store.alias_symbol_links base=0x74d0b5000000 reserved=1610612736 rss=176128 anonhuge=0 dropped=1
table tid=1932883 field=store.type_node_links_pages base=0x74d115000000 reserved=4194304 rss=81920 anonhuge=0 dropped=1
table tid=1932880 field=store.alias_targets_pages base=0x74d115400000 reserved=16777216 rss=65536 anonhuge=0 dropped=0
table tid=1932878 field=store.late_bound_links base=0x74d116400000 reserved=536870912 rss=12288 anonhuge=0 dropped=1
table tid=1932883 field=store.symbol_reference_links_pages base=0x74d136400000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932880 field=store.immediate_targets base=0x74d137400000 reserved=536870912 rss=73728 anonhuge=0 dropped=0
table tid=1932878 field=store.declared_type_links base=0x74d157400000 reserved=1073741824 rss=368640 anonhuge=0 dropped=1
table tid=1932883 field=store.mapped_symbol_links_pages base=0x74d197400000 reserved=16777216 rss=12288 anonhuge=0 dropped=1
table tid=1932880 field=store.immediate_targets_pages base=0x74d198400000 reserved=16777216 rss=65536 anonhuge=0 dropped=0
table tid=1932878 field=store.members_links base=0x74d199400000 reserved=536870912 rss=225280 anonhuge=0 dropped=1
table tid=1932883 field=store.alias_symbol_links_pages base=0x74d1b9400000 reserved=16777216 rss=53248 anonhuge=0 dropped=1
table tid=1932880 field=store.string_literal_types base=0x74d1ba400000 reserved=536870912 rss=172032 anonhuge=0 dropped=0
table tid=1932878 field=store.signature_links_pages base=0x74d1da400000 reserved=4194304 rss=81920 anonhuge=0 dropped=1
table tid=1932883 field=store.late_bound_links_pages base=0x74d1da800000 reserved=16777216 rss=53248 anonhuge=0 dropped=1
table tid=1932880 field=store.string_literal_types_pages base=0x74d1db800000 reserved=16777216 rss=16384 anonhuge=0 dropped=0
table tid=1932878 field=store.symbol_node_links_pages base=0x74d1dc800000 reserved=4194304 rss=81920 anonhuge=0 dropped=1
table tid=1932883 field=store.declared_type_links_pages base=0x74d1dcc00000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932878 field=store.type_node_links_pages base=0x74d1ddc00000 reserved=4194304 rss=81920 anonhuge=0 dropped=1
table tid=1932883 field=store.members_links_pages base=0x74d1de000000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932878 field=store.symbol_reference_links_pages base=0x74d1df000000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932883 field=store.merged_symbols base=0x74d1e0000000 reserved=536870912 rss=569344 anonhuge=0 dropped=1
table tid=1932878 field=store.mapped_symbol_links_pages base=0x74d200000000 reserved=16777216 rss=16384 anonhuge=0 dropped=1
table tid=1932883 field=store.alias_targets base=0x74d201000000 reserved=536870912 rss=225280 anonhuge=0 dropped=1
table tid=1932878 field=store.alias_symbol_links_pages base=0x74d221000000 reserved=16777216 rss=49152 anonhuge=0 dropped=1
table tid=1932883 field=store.alias_targets_pages base=0x74d222000000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932878 field=store.late_bound_links_pages base=0x74d223000000 reserved=16777216 rss=53248 anonhuge=0 dropped=1
table tid=1932883 field=store.immediate_targets base=0x74d224000000 reserved=536870912 rss=53248 anonhuge=0 dropped=1
table tid=1932880 field=checker.syms base=0x74d244000000 reserved=1073741824 rss=4194304 anonhuge=2097152 dropped=0
table tid=1932878 field=store.declared_type_links_pages base=0x74d284000000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932883 field=store.immediate_targets_pages base=0x74d285000000 reserved=16777216 rss=57344 anonhuge=0 dropped=1
table tid=1932880 field=checker.symbol_data base=0x74d286000000 reserved=1879048192 rss=1994752 anonhuge=0 dropped=0
table tid=1932878 field=store.members_links_pages base=0x74d2f6000000 reserved=16777216 rss=61440 anonhuge=0 dropped=1
table tid=1932883 field=store.string_literal_types base=0x74d2f7000000 reserved=536870912 rss=131072 anonhuge=0 dropped=1
table tid=1932880 field=checker.lazy_index base=0x74d317000000 reserved=536870912 rss=577536 anonhuge=0 dropped=0
table tid=1932878 field=store.merged_symbols base=0x74d337000000 reserved=536870912 rss=569344 anonhuge=0 dropped=1
table tid=1932883 field=store.string_literal_types_pages base=0x74d357000000 reserved=16777216 rss=16384 anonhuge=0 dropped=1
table tid=1932880 field=checker.tab_heads base=0x74d358000000 reserved=805306368 rss=368640 anonhuge=0 dropped=0
table tid=1932878 field=store.alias_targets base=0x74d388000000 reserved=536870912 rss=114688 anonhuge=0 dropped=1
table tid=1932880 field=checker.base_constraints base=0x74d3a8000000 reserved=536870912 rss=577536 anonhuge=0 dropped=0
table tid=1932878 field=store.alias_targets_pages base=0x74d3c8000000 reserved=16777216 rss=69632 anonhuge=0 dropped=1
table tid=1932880 field=checker.tab_entries base=0x74d3c9000000 reserved=2147483648 rss=880640 anonhuge=0 dropped=0
table tid=1932878 field=store.immediate_targets base=0x74d449000000 reserved=536870912 rss=61440 anonhuge=0 dropped=1
table tid=1932878 field=store.immediate_targets_pages base=0x74d469000000 reserved=16777216 rss=65536 anonhuge=0 dropped=1
table tid=1932878 field=store.string_literal_types base=0x74d46a000000 reserved=536870912 rss=172032 anonhuge=0 dropped=1
table tid=1932878 field=store.string_literal_types_pages base=0x74d48a000000 reserved=16777216 rss=16384 anonhuge=0 dropped=1
table tid=1932883 field=checker.syms base=0x74d48b000000 reserved=1073741824 rss=1142784 anonhuge=0 dropped=1
table tid=1932883 field=checker.symbol_data base=0x74d4cb000000 reserved=1879048192 rss=737280 anonhuge=0 dropped=1
table tid=1932883 field=checker.lazy_index base=0x74d53b000000 reserved=536870912 rss=344064 anonhuge=0 dropped=1
table tid=1932883 field=checker.tab_heads base=0x74d55b000000 reserved=805306368 rss=258048 anonhuge=0 dropped=1
table tid=1932883 field=checker.base_constraints base=0x74d58b000000 reserved=536870912 rss=344064 anonhuge=0 dropped=1
table tid=1932883 field=checker.tab_entries base=0x74d5ab000000 reserved=2147483648 rss=495616 anonhuge=0 dropped=1
table tid=1932878 field=checker.syms base=0x74d62b000000 reserved=1073741824 rss=1978368 anonhuge=0 dropped=1
table tid=1932878 field=checker.symbol_data base=0x74d66b000000 reserved=1879048192 rss=1654784 anonhuge=0 dropped=1
table tid=1932878 field=checker.lazy_index base=0x74d6db000000 reserved=536870912 rss=565248 anonhuge=0 dropped=1
table tid=1932878 field=checker.tab_heads base=0x74d6fb000000 reserved=805306368 rss=438272 anonhuge=0 dropped=1
table tid=1932878 field=checker.base_constraints base=0x74d72b000000 reserved=536870912 rss=565248 anonhuge=0 dropped=1
table tid=1932878 field=checker.tab_entries base=0x74d74b000000 reserved=2147483648 rss=802816 anonhuge=0 dropped=1
other base=0x1000000 len=18489344 rss=5603328 anonhuge=0 hg=0
other base=0x21a2000 len=13492224 rss=7507968 anonhuge=0 hg=0
other base=0x2e80000 len=4096 rss=4096 anonhuge=0 hg=0
other base=0x2e81000 len=24576 rss=12288 anonhuge=0 hg=0
other base=0x2e87000 len=360448 rss=53248 anonhuge=0 hg=0
other base=0x74e74c4e9000 len=1048576 rss=1048576 anonhuge=0 hg=0
other base=0x74e74c5f9000 len=94208 rss=94208 anonhuge=0 hg=0
other base=0x74e74c610000 len=94208 rss=94208 anonhuge=0 hg=0
other base=0x74e74c627000 len=180224 rss=180224 anonhuge=0 hg=0
other base=0x74e74c653000 len=462848 rss=360448 anonhuge=0 hg=0
other base=0x74e74c6c4000 len=462848 rss=28672 anonhuge=0 hg=0
other base=0x74e74c735000 len=466944 rss=434176 anonhuge=0 hg=0
other base=0x74e74c7a7000 len=77824 rss=73728 anonhuge=0 hg=0
other base=0x74e74c7ba000 len=299008 rss=299008 anonhuge=0 hg=0
other base=0x74e74c803000 len=909312 rss=888832 anonhuge=0 hg=0
other base=0x74e74c8e1000 len=925696 rss=897024 anonhuge=0 hg=0
other base=0x74e74c9c3000 len=1847296 rss=1810432 anonhuge=0 hg=0
other base=0x74e74cb86000 len=188416 rss=131072 anonhuge=0 hg=0
other base=0x74e74cbb4000 len=188416 rss=12288 anonhuge=0 hg=0
other base=0x74e74cbe2000 len=188416 rss=135168 anonhuge=0 hg=0
other base=0x74e74cc10000 len=126976 rss=118784 anonhuge=0 hg=0
other base=0x74e74cc2f000 len=364544 rss=303104 anonhuge=0 hg=0
other base=0x74e74cc88000 len=376832 rss=270336 anonhuge=0 hg=0
other base=0x74e74cce4000 len=745472 rss=688128 anonhuge=0 hg=0
other base=0x74e74dd9a000 len=68157440 rss=8192 anonhuge=0 hg=0
other base=0x74e752e9b000 len=68157440 rss=4096 anonhuge=0 hg=0
other base=0x74e79ddaa000 len=24576 rss=24576 anonhuge=0 hg=0
other base=0x74e79ddb0000 len=262144 rss=4096 anonhuge=0 hg=0
other base=0x74e79ddf1000 len=69632 rss=8192 anonhuge=0 hg=0
other base=0x74e79de02000 len=262144 rss=4096 anonhuge=0 hg=0
other base=0x74e79de43000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x74e79ee44000 len=262144 rss=4096 anonhuge=0 hg=0
other base=0x74e79ee85000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x74e79fe86000 len=262144 rss=4096 anonhuge=0 hg=0
other base=0x74e79fec7000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x74e7a0ec8000 len=262144 rss=4096 anonhuge=0 hg=0
other base=0x74e7a0f09000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x74e7a1f0a000 len=262144 rss=4096 anonhuge=0 hg=0
other base=0x74e7a1f4b000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x74e7a2f4d000 len=16781312 rss=8192 anonhuge=0 hg=0
other base=0x74e7a4f4e000 len=68157440 rss=184320 anonhuge=0 hg=0
other base=0x74e7aa04f000 len=68157440 rss=12288 anonhuge=0 hg=0
other base=0x74e7f5f5e000 len=68157440 rss=8192 anonhuge=0 hg=0
other base=0x74e7fb05f000 len=68157440 rss=4096 anonhuge=0 hg=0
other base=0x74e846f6e000 len=68157440 rss=94208 anonhuge=0 hg=0
other base=0x74e84c06f000 len=68157440 rss=4096 anonhuge=0 hg=0
other base=0x74e897f7e000 len=68157440 rss=147456 anonhuge=0 hg=0
other base=0x74e89d07f000 len=68157440 rss=28672 anonhuge=0 hg=0
other base=0x74e8e8f8e000 len=68157440 rss=8192 anonhuge=0 hg=0
other base=0x74e8ee08f000 len=68157440 rss=24576 anonhuge=0 hg=0
other base=0x74e939f9e000 len=68157440 rss=94208 anonhuge=0 hg=0
other base=0x74e93f09f000 len=68157440 rss=180224 anonhuge=0 hg=0
other base=0x74e98afae000 len=68157440 rss=98304 anonhuge=0 hg=0
other base=0x74e9900af000 len=68157440 rss=430080 anonhuge=0 hg=0
other base=0x74e9951b0000 len=68157440 rss=98304 anonhuge=0 hg=0
other base=0x74e99a2b1000 len=68157440 rss=98304 anonhuge=0 hg=0
other base=0x74e99f3b2000 len=68157440 rss=4096 anonhuge=0 hg=0
other base=0x74e9dafbe000 len=262144 rss=4096 anonhuge=0 hg=0
other base=0x74e9dafff000 len=16781312 rss=8192 anonhuge=0 hg=0
segment base=0x74e9dc000000 len=121634816 rss=89755648 anonhuge=56623104 hg=1
segment base=0x74e9e4000000 len=46137344 rss=30879744 anonhuge=23068672 hg=1
segment base=0x74e9e8000000 len=100663296 rss=42213376 anonhuge=4194304 hg=1
segment base=0x74e9ee000000 len=209715200 rss=161136640 anonhuge=111149056 hg=1
segment base=0x74e9fc000000 len=41943040 rss=11345920 anonhuge=4194304 hg=1
other base=0x74f9dc401000 len=253952 rss=69632 anonhuge=0 hg=0
other base=0x74f9dc43f000 len=262144 rss=4096 anonhuge=0 hg=0
other base=0x7509dc47f000 len=68157440 rss=200704 anonhuge=0 hg=0
other base=0x7509e0586000 len=8192 rss=8192 anonhuge=0 hg=0
other base=0x7ffcf3cd7000 len=135168 rss=12288 anonhuge=0 hg=0
```
