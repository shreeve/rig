# tsrs memory census by kind of object

tsrs 0.18.0-ts7.1.0-dev.20260929 (source git 280b426b), on pup (x86-64 Linux), one thread
(`-p tsconfig.trig.json --noEmit --singleThreaded`, `RAYON_NUM_THREADS=1`, `taskset -c 12-19`), 2026-11-02.
Two modes: **shipped** (defaults: tsrs's checker assignment, lazy member tables, lazy .d.ts) and **go**
(`TSRS_LAZY_DTS=0 --checkerAssignment go --noLazyMembers`). Everything is measured at memsplit's `check end`,
the point where memory peaks. MiB = 2^20 bytes.

## Headline

- ts-pattern: VmHWM **161.2 MiB** shipped / **206.1 MiB** go. Of that, the census finds **138.6 / 190.4 MiB live**:
  arena 95.3 / 131.3 MiB + heap 43.4 / 59.0 MiB. The rest of the peak is arena slack and regions (5.3 / 1.5),
  heap retained but free (8.4 / 5.3) and file-backed pages (8.5, of which 4.3 is tsrs's own text).
- Largest kinds on ts-pattern (shipped): lists and maps 37.3 MiB (18.0 of them the checker's `CacheHashKey`
  instantiation caches on the heap, 7.2 `[P<Type>]` in the arena), types 35.4, symbols 15.0, links 12.0, symbol
  tables 11.6, mappers 8.2, signatures 7.8, AST 4.0, source text 3.5.
- go mode costs 52 MiB more on ts-pattern: symbols 15.0 -> 29.9, symbol tables 11.6 -> 32.5, links 12.0 -> 20.4,
  AST 4.0 -> 9.6, mappers 8.2 -> 12.1. Types, signatures and the caches barely move.
- zod3: VmHWM 44.5 / 57.9 MiB; live 31.8 / 46.1 MiB. empty: 16.0 / 20.3 MiB; live 7.4 / 11.1 MiB, of which
  2.9 MiB is the lib .d.ts text held on the heap.
- Every run's stdout+stderr and exit status equal tsc's (empty 0, zod3 2, ts-pattern 2), for the shipped binary
  and for the census build, both plain and with the census on. The census build reports the same Identifiers,
  Symbols, Types and Instantiations as the shipped binary in all six runs.

### Live MiB at `check end` by kind (arena + heap)

| kind | empty shipped | empty go | zod3 shipped | zod3 go | ts-pattern shipped | ts-pattern go |
|---|---:|---:|---:|---:|---:|---:|
| 1 AST nodes | 2.97 | 5.71 | 4.39 | 9.01 | 4.02 | 9.63 |
| 2 identifiers and text | 0.02 | 0.02 | 0.14 | 0.14 | 0.93 | 0.93 |
| 3 symbols | 0.57 | 1.20 | 2.89 | 6.35 | 14.97 | 29.89 |
| 4 symbol tables and members | 0.34 | 0.66 | 3.30 | 7.87 | 11.61 | 32.49 |
| 5 types | 0.01 | 0.01 | 6.18 | 5.96 | 35.38 | 34.05 |
| 6 signatures | 0.00 | 0.00 | 1.65 | 1.65 | 7.79 | 7.78 |
| 7 links and side tables | 0.24 | 0.24 | 2.73 | 4.32 | 11.98 | 20.41 |
| 8 source and lib file text | 2.91 | 2.91 | 3.41 | 3.41 | 3.46 | 3.46 |
| 9 lists and maps | 0.08 | 0.03 | 4.77 | 4.83 | 37.27 | 36.46 |
| 10a mappers | 0.00 | 0.00 | 1.42 | 1.52 | 8.22 | 12.10 |
| 10b inference | 0.00 | 0.00 | 0.08 | 0.08 | 1.95 | 1.95 |
| 10c flow nodes | 0.05 | 0.13 | 0.27 | 0.42 | 0.23 | 0.36 |
| 10d diagnostics | 0.00 | 0.00 | 0.11 | 0.11 | 0.35 | 0.33 |
| 10e node builder / printer | 0.00 | 0.00 | 0.04 | 0.04 | 0.09 | 0.09 |
| 10f other checker objects | 0.00 | 0.00 | 0.01 | 0.01 | 0.00 | 0.00 |
| 10g program, config, module resolution, other | 0.22 | 0.22 | 0.39 | 0.38 | 0.41 | 0.41 |
| **total** | **7.41** | **11.12** | **31.77** | **46.09** | **138.64** | **190.35** |

Kinds: AST = every node struct (`NodeAlloc<..>`, `NodeAllocRare<..>`, the 24-byte `Node` header of nodes
without data, `NodeList`, `ModifierList`, `LazyNodeList`, `[P<Node>]`, `SourceFile`) plus the parser's heap
(pragmas). Identifier nodes are counted in AST and shown again under 2; their text is not stored apart: a compact
`Identifier` (32 bytes) points into the source text by index, only `IdentifierWithText` (40) carries a
`PackedStr`. Symbols = `Symbol` (32) and its `SymbolTables` tail (24). Symbol tables = `SymbolTable` (24, arena)
plus its heap: `EntryVec` buffers of 8-byte `SymbolMapEntry`, the name index (`HashTable<u32>`) and
`Box<SymbolMapExtra>` of tables over 16 entries, plus `[P<Symbol>]` member lists in the arena. Types =
`TypeAlloc<..>` of every type kind, `StructuredMembers`, the `*Rare` tails, `IndexInfo`, `TypeAlias`,
`LazyMemberTable`. Links = the dense link tables (`[PSlot<..Links>]`, `IdGroup`, `ValueSymbolLinksTail`) in the
arena and the keyed `LinkStore` hash tables on the heap. Lists and maps = `[P<Type>]`, `[u32]`, `[u64]`,
arena-held `RefCell<HashMap>`s, and every checker hash table / vector on the heap, by allocating site.

## Peak RSS and its split

From the **shipped binary** (PGO+LTO+BOLT, uninstrumented): `TSRS_MEM_SPLIT=1` at `check end` (VmHWM is the
larger of the `check end` and `exit` readings); the file-backed split from the peak of `/proc/PID/smaps` sampled
every 2 ms (`smaps-peak.py`). MiB.

| project | mode | VmHWM | arena used | arena unused resident | arena other (regions, untouched) | heap live | heap retained (in pages / outside) | stacks | file-backed | of which tsrs text / rodata / data / shared libs | AnonHugePages (arena / heap) |
|---|---|---:|---:|---:|---:|---:|---|---:|---:|---|---|
| empty | shipped | 16.0 | 3.9 | 1.1 | 0.0 | 3.5 | 1.3 (0.9 / 0.4) | 0.1 | 6.0 | 3.4 / 1.7 / 0.0 / 2.4 | 4.0 / 0.0 |
| empty | go | 20.3 | 7.5 | 1.5 | 0.0 | 3.7 | 1.3 (0.9 / 0.4) | 0.1 | 6.2 | 3.2 / 1.7 / 0.0 / 2.4 | 8.0 / 0.0 |
| zod3 | shipped | 44.5 | 21.0 | 0.0 | 2.2 | 10.8 | 2.3 (1.4 / 0.9) | 0.1 | 8.0 | 4.2 / 1.7 / 0.0 / 2.4 | 20.0 / 0.0 |
| zod3 | go | 57.9 | 31.7 | 1.3 | 0.0 | 14.4 | 2.3 (1.6 / 0.7) | 0.1 | 7.9 | 4.2 / 1.7 / 0.0 / 2.4 | 32.0 / 0.0 |
| ts-pattern | shipped | 161.2 | 95.4 | 1.6 | 3.7 | 43.4 | 8.4 (1.7 / 6.7) | 0.2 | 8.5 | 4.3 / 1.7 / 0.0 / 2.4 | 96.0 / 0.0 |
| ts-pattern | go | 206.1 | 131.5 | 1.5 | 0.0 | 59.1 | 5.3 (1.0 / 4.3) | 0.2 | 8.5 | 4.3 / 1.7 / 0.0 / 2.4 | 132.0 / 0.0 |

- arena used = bytes below the bump fingers of the thread arenas (what the census attributes); arena unused
  resident = touched but never handed out; arena other = region chunks and rounding (`smaps` arena reservation
  Rss minus the two).
- heap live = mimalloc's live blocks (`mi_heap_visit_blocks`); heap retained = the rest of the anonymous non-arena
  Rss (freed blocks in mimalloc pages, then its segment metadata and other anonymous maps).
- AnonHugePages: the arena's chunks from 2 MiB on are THP-backed; the heap uses none (`no_thp` mimalloc feature).
- Lib file text: the shipped binary is built `noembed`, so the lib .d.ts files are read from disk next to the
  binary into heap buffers (kind 8), never mapped. Sizes of the program's files (`--listFiles`): empty 97 lib files
  2,989,557 B; zod3 92 lib 2,976,242 B + 85 project/node_modules files 491,769 B; ts-pattern 97 lib 2,989,557 B
  + 72 other 530,385 B.

## Per project and mode

Columns: count = live objects (arena) or live blocks (heap); bytes each = `size_of` / bytes actually taken in the
arena per object (the 8-byte rounding of `P` targets and alignment padding), or for slices the average slice size
(item size in brackets), or for heap rows the average usable block size (`mi_usable_size`); MiB = taken (arena)
or usable (heap) bytes. "arena (+region)" = mostly the thread arena, a little in regions (the lazy .d.ts
regions and scratch regions; under 0.1 MiB everywhere). Each kind shows its largest rows and the rest summed.

### empty, shipped mode

| kind | Rust type | store | count | bytes each | MiB |
|---|---|---|---:|---|---:|
| **1 AST nodes** | | arena + heap | 108,571 | | **2.97** |
| | `ast::NodeAlloc<identifier::Identifier>` | arena | 19,486 | 32 / 32 | 0.60 |
| | `ast::NodeAlloc<generated::ParameterDeclaration>` | arena | 4,931 | 48 / 48 | 0.23 |
| | `ast::Node` | arena | 9,524 | 24 / 24 | 0.22 |
| | `ast::NodeList` | arena | 11,002 | 16 / 18 | 0.19 |
| | `ast::NodeAlloc<generated::TypeReferenceNode>` | arena | 5,902 | 32 / 32 | 0.18 |
| | `lazylist::LazyNodeList` | arena | 2,583 | 72 / 72 | 0.18 |
| | `[ptr::P<ast::Node>]` | arena | 26,901 | 6 avg (4 per item) | 0.16 |
| | `ast::NodeAlloc<generated::PropertySignatureDeclaration>` | arena | 2,444 | 48 / 48 | 0.11 |
| | `ast::NodeAlloc<generated::InterfaceDeclaration>` | arena | 2,034 | 56 / 56 | 0.11 |
| | `ast::NodeAlloc<generated::MethodSignatureDeclaration>` | arena | 1,774 | 64 / 64 | 0.11 |
| | (71 more) | | 22,824 | | 0.89 |
| **2 identifiers and text** | | arena | 3,079 | | **0.02** |
| | `str` | arena | 1,425 | 7 avg | 0.01 |
| | (2 more) | | 1,654 | | 0.01 |
| | `ast::NodeAlloc<identifier::Identifier>` (counted in 1) | arena | 19,486 | 32 / 32 | (0.60) |
| | `ast::NodeAlloc<identifier::IdentifierWithText>` (counted in 1) | arena | 24 | 40 / 40 | (0.00) |
| **3 symbols** | | arena | 18,484 | | **0.57** |
| | `symbol::Symbol` | arena | 14,868 | 32 / 34 | 0.49 |
| | `symbol::SymbolTables` | arena | 3,616 | 24 / 24 | 0.08 |
| **4 symbol tables and members** | | arena + heap | 3,695 | | **0.34** |
| | symbol table entry buffers (`EntryVec`) | heap | 3,694 | 44 avg | 0.15 |
| | symbol table name indexes (hash tables) | heap | 81 | 1161 avg | 0.09 |
| | `symbol::SymbolTable` | arena | 3,695 | 24 / 25 | 0.09 |
| | (1 more) | | 81 | | 0.00 |
| **5 types** | | arena | 102 | | **0.01** |
| | (12 more) | | 102 | | 0.01 |
| **6 signatures** | | arena | 5 | | **0.00** |
| | (1 more) | | 5 | | 0.00 |
| **7 links and side tables** | | arena + heap | 5 | | **0.24** |
| | `[ptr::PSlot<types::SourceFileLinks>]` | arena | 1 | 155648 avg (152 per item) | 0.15 |
| | `[ptr::PSlot<types::ValueSymbolLinks>]` | arena | 1 | 65536 avg (16 per item) | 0.06 |
| | `[ptr::PSlot<types::ModuleSymbolLinks>]` | arena | 1 | 16384 avg (16 per item) | 0.02 |
| | (3 more) | | 10 | | 0.01 |
| **8 source and lib file text** | | heap |  | | **2.91** |
| | source file text (`Vec<u8>`/`String` from `read_file`) | heap | 98 | 31151 avg | 2.91 |
| **9 lists and maps** | | arena + heap | 20 | | **0.08** |
| | vec: <checker::Checker>::get_union_type_ex @ tsrs_checker/src/unioncache.rs:364 | heap | 1 | 49152 avg | 0.05 |
| | (19 more) | | 39 | | 0.03 |
| **10a mappers** | | arena | 11 | | **0.00** |
| | (2 more) | | 11 | | 0.00 |
| **10c flow nodes** | | arena | 2,850 | | **0.05** |
| | `flow::FlowNode` | arena | 2,850 | 16 / 19 | 0.05 |
| **10d diagnostics** | | heap |  | | **0.00** |
| | (1 more) | | 8 | | 0.00 |
| **10f other checker objects** | | arena | 11 | | **0.00** |
| | (3 more) | | 11 | | 0.00 |
| **10g program, config, module resolution, other** | | arena + heap | 250 | | **0.22** |
| | index map: enummaps::LIB_MAP::{closure#0} @ tsrs_tsoptions/src/enummaps.rs:17 | heap | 2 | 11520 avg | 0.02 |
| | hash table: cachedvfs::cachedvfs::from::<Arc<dyn vfs::FS>> @ tsrs_vfs/src/cachedvfs/cachedvfs.rs:16 | heap | 5 | 3584 avg | 0.02 |
| | hash table: command_line_options_to_map @ tsrs_tsoptions/src/tsconfigparsing.rs:900 | heap | 4 | 3952 avg | 0.02 |
| | hash table: clone @ tsrs_tsoptions/src/tsconfigparsing.rs:876 | heap | 1 | 14336 avg | 0.01 |
| | (113 more) | | 1,203 | | 0.16 |
| **total** | arena live 3.90 + heap live 3.51 | | | | **7.41** |

Arena: 137,083 live objects / 277,197 allocated (7.85 MiB allocated; given back: 0.00 MiB to free lists, 4.04 MiB by parser rewinds, 0.00 MiB with freed regions). Live bytes allocated before `parse end`: 3.04 MiB. Census live 4,092,372 B vs memsplit arena used 4,092,372 B (unattributed 0 B; free lists hold 0 B). Heap: 5,789 live blocks, 3.38 MiB requested / 3.51 MiB usable; 22,271 heap allocations (5.13 MiB) over the run.

### empty, go mode

| kind | Rust type | store | count | bytes each | MiB |
|---|---|---|---:|---|---:|
| **1 AST nodes** | | arena + heap | 221,205 | | **5.71** |
| | `ast::NodeAlloc<identifier::Identifier>` | arena | 46,400 | 32 / 32 | 1.42 |
| | `ast::Node` | arena | 23,318 | 24 / 24 | 0.53 |
| | `ast::NodeAlloc<generated::ParameterDeclaration>` | arena | 11,541 | 48 / 48 | 0.53 |
| | `ast::NodeAlloc<generated::TypeReferenceNode>` | arena | 16,779 | 32 / 32 | 0.51 |
| | `ast::NodeAlloc<generated::PropertySignatureDeclaration>` | arena | 9,173 | 48 / 48 | 0.42 |
| | `[ptr::P<ast::Node>]` | arena | 56,992 | 6 avg (4 per item) | 0.35 |
| | `ast::NodeList` | arena | 18,241 | 16 / 18 | 0.32 |
| | `ast::NodeAlloc<generated::MethodSignatureDeclaration>` | arena | 4,326 | 64 / 64 | 0.26 |
| | `ast::NodeAlloc<generated::LiteralTypeNode>` | arena | 5,319 | 32 / 32 | 0.16 |
| | `ast::ModifierList` | arena | 5,153 | 24 / 28 | 0.14 |
| | (71 more) | | 24,797 | | 1.07 |
| **2 identifiers and text** | | arena | 1,788 | | **0.02** |
| | (3 more) | | 1,788 | | 0.02 |
| | `ast::NodeAlloc<identifier::Identifier>` (counted in 1) | arena | 46,400 | 32 / 32 | (1.42) |
| | `ast::NodeAlloc<identifier::IdentifierWithText>` (counted in 1) | arena | 24 | 40 / 40 | (0.00) |
| **3 symbols** | | arena | 37,332 | | **1.20** |
| | `symbol::Symbol` | arena | 32,977 | 32 / 35 | 1.09 |
| | `symbol::SymbolTables` | arena | 4,355 | 24 / 24 | 0.10 |
| **4 symbol tables and members** | | arena + heap | 9,628 | | **0.66** |
| | symbol table entry buffers (`EntryVec`) | heap | 9,627 | 33 avg | 0.31 |
| | `symbol::SymbolTable` | arena | 9,628 | 24 / 26 | 0.24 |
| | symbol table name indexes (hash tables) | heap | 153 | 774 avg | 0.11 |
| | (1 more) | | 153 | | 0.01 |
| **5 types** | | arena | 102 | | **0.01** |
| | (12 more) | | 102 | | 0.01 |
| **6 signatures** | | arena | 5 | | **0.00** |
| | (1 more) | | 5 | | 0.00 |
| **7 links and side tables** | | arena + heap | 5 | | **0.24** |
| | `[ptr::PSlot<types::SourceFileLinks>]` | arena | 1 | 155648 avg (152 per item) | 0.15 |
| | `[ptr::PSlot<types::ValueSymbolLinks>]` | arena | 1 | 65536 avg (16 per item) | 0.06 |
| | `[ptr::PSlot<types::ModuleSymbolLinks>]` | arena | 1 | 16384 avg (16 per item) | 0.02 |
| | (3 more) | | 10 | | 0.01 |
| **8 source and lib file text** | | heap |  | | **2.91** |
| | source file text (`Vec<u8>`/`String` from `read_file`) | heap | 98 | 31151 avg | 2.91 |
| **9 lists and maps** | | arena + heap | 20 | | **0.03** |
| | (19 more) | | 39 | | 0.03 |
| **10a mappers** | | arena | 11 | | **0.00** |
| | (2 more) | | 11 | | 0.00 |
| **10c flow nodes** | | arena | 7,026 | | **0.13** |
| | `flow::FlowNode` | arena | 7,024 | 16 / 19 | 0.13 |
| | (1 more) | | 2 | | 0.00 |
| **10d diagnostics** | | heap |  | | **0.00** |
| | (1 more) | | 8 | | 0.00 |
| **10f other checker objects** | | arena | 11 | | **0.00** |
| | (3 more) | | 11 | | 0.00 |
| **10g program, config, module resolution, other** | | arena + heap | 250 | | **0.22** |
| | index map: enummaps::LIB_MAP::{closure#0} @ tsrs_tsoptions/src/enummaps.rs:17 | heap | 2 | 11520 avg | 0.02 |
| | hash table: cachedvfs::cachedvfs::from::<Arc<dyn vfs::FS>> @ tsrs_vfs/src/cachedvfs/cachedvfs.rs:16 | heap | 5 | 3584 avg | 0.02 |
| | hash table: command_line_options_to_map @ tsrs_tsoptions/src/tsconfigparsing.rs:900 | heap | 4 | 3952 avg | 0.02 |
| | hash table: clone @ tsrs_tsoptions/src/tsconfigparsing.rs:876 | heap | 1 | 14336 avg | 0.01 |
| | (112 more) | | 1,202 | | 0.16 |
| **total** | arena live 7.48 + heap live 3.64 | | | | **11.12** |

Arena: 277,383 live objects / 282,644 allocated (7.45 MiB allocated; given back: 0.00 MiB to free lists, 0.16 MiB by parser rewinds, 0.00 MiB with freed regions). Live bytes allocated before `parse end`: 7.04 MiB. Census live 7,844,624 B vs memsplit arena used 7,844,624 B (unattributed 0 B; free lists hold 0 B). Heap: 11,864 live blocks, 3.52 MiB requested / 3.64 MiB usable; 33,426 heap allocations (5.17 MiB) over the run.

### zod3, shipped mode

| kind | Rust type | store | count | bytes each | MiB |
|---|---|---|---:|---|---:|
| **1 AST nodes** | | arena + heap | 161,399 | | **4.39** |
| | `ast::NodeAlloc<identifier::Identifier>` | arena (+region) | 31,156 | 32 / 32 | 0.95 |
| | `ast::NodeList` | arena (+region) | 16,636 | 16 / 18 | 0.29 |
| | `ast::Node` | arena (+region) | 12,191 | 24 / 24 | 0.28 |
| | `ast::NodeAlloc<generated::ParameterDeclaration>` | arena (+region) | 5,517 | 48 / 48 | 0.25 |
| | `ast::NodeAlloc<generated::TypeReferenceNode>` | arena | 8,018 | 32 / 32 | 0.24 |
| | `[ptr::P<ast::Node>]` | arena (+region) | 39,824 | 6 avg (4 per item) | 0.23 |
| | `lazylist::LazyNodeList` | arena | 2,569 | 72 / 72 | 0.18 |
| | `ast::NodeAlloc<generated::PropertySignatureDeclaration>` | arena | 2,911 | 48 / 48 | 0.13 |
| | `ast::NodeAlloc<ast::SourceFile>` | arena | 178 | 720 / 725 | 0.12 |
| | `ast::NodeAlloc<generated::LiteralTypeNode>` | arena (+region) | 3,694 | 32 / 32 | 0.11 |
| | (123 more) | | 39,504 | | 1.59 |
| **2 identifiers and text** | | arena | 15,662 | | **0.14** |
| | `str` | arena (+region) | 13,886 | 10 avg | 0.13 |
| | (2 more) | | 1,776 | | 0.01 |
| | `ast::NodeAlloc<identifier::Identifier>` (counted in 1) | arena (+region) | 31,156 | 32 / 32 | (0.95) |
| | `ast::NodeAlloc<identifier::IdentifierWithText>` (counted in 1) | arena (+region) | 325 | 40 / 43 | (0.01) |
| **3 symbols** | | arena | 92,633 | | **2.89** |
| | `symbol::Symbol` | arena (+region) | 87,923 | 32 / 33 | 2.78 |
| | `symbol::SymbolTables` | arena (+region) | 4,710 | 24 / 25 | 0.11 |
| **4 symbol tables and members** | | arena + heap | 54,209 | | **3.30** |
| | symbol table entry buffers (`EntryVec`) | heap | 19,081 | 70 avg | 1.27 |
| | symbol table name indexes (hash tables) | heap | 1,593 | 705 avg | 1.07 |
| | `symbol::SymbolTable` | arena (+region) | 18,734 | 24 / 25 | 0.44 |
| | `[ptr::P<symbol::Symbol>]` | arena | 35,475 | 12 avg (4 per item) | 0.42 |
| | symbol table extras (`Box<SymbolMapExtra>`) | heap | 1,593 | 64 avg | 0.10 |
| **5 types** | | arena | 150,546 | | **6.18** |
| | `types::TypeAlloc<types::ObjectType>` | arena | 31,798 | 40 / 40 | 1.22 |
| | `types::TypeAlloc<types::TypeReference>` | arena | 21,587 | 48 / 50 | 1.03 |
| | `types::StructuredMembers` | arena | 32,802 | 32 / 32 | 1.01 |
| | `types::TypeAlloc<types::TypeParameter>` | arena | 11,191 | 56 / 56 | 0.60 |
| | `checker_09::LazyMemberTable` | arena | 5,721 | 80 / 80 | 0.44 |
| | `types::TypeAlloc<types::MappedType>` | arena | 6,164 | 72 / 72 | 0.42 |
| | `types::TypeAlloc<types::UnionType>` | arena | 8,659 | 48 / 50 | 0.41 |
| | `types::TypeAlloc<types::LiteralType>` | arena | 3,064 | 56 / 58 | 0.17 |
| | `types::TypeAlias` | arena | 8,019 | 16 / 19 | 0.14 |
| | `types::TypeAlloc<types::ConditionalType>` | arena | 2,074 | 72 / 72 | 0.14 |
| | (21 more) | | 19,467 | | 0.59 |
| **6 signatures** | | arena | 50,402 | | **1.65** |
| | `types::Signature` | arena | 28,801 | 56 / 56 | 1.54 |
| | `[ptr::P<types::Signature>]` | arena | 20,265 | 5 avg (4 per item) | 0.09 |
| | `types::SignatureRare` | arena | 1,330 | 16 / 16 | 0.02 |
| | (1 more) | | 6 | | 0.00 |
| **7 links and side tables** | | arena + heap | 2,274 | | **2.73** |
| | `[ptr::PSlot<types::ValueSymbolLinks>]` | arena | 18 | 65536 avg (16 per item) | 1.13 |
| | link stores (hash tables / vectors) | heap | 51 | 7953 avg | 0.39 |
| | `[ptr::PSlot<types::TypeNodeLinks>]` | arena | 8 | 24576 avg (24 per item) | 0.19 |
| | `[ptr::PSlot<types::SignatureLinks>]` | arena | 10 | 16384 avg (16 per item) | 0.16 |
| | `links::IdGroup` | arena | 591 | 264 / 264 | 0.15 |
| | `[ptr::PSlot<types::SourceFileLinks>]` | arena | 1 | 155648 avg (152 per item) | 0.15 |
| | `[ptr::PSlot<types::ContainingSymbolLinks>]` | arena | 1 | 98304 avg (96 per item) | 0.09 |
| | `[types::SymbolNodeLinks; 32]` | arena | 733 | 128 / 129 | 0.09 |
| | `[ptr::PSlot<types::MappedSymbolLinks>]` | arena | 6 | 8192 avg (8 per item) | 0.05 |
| | `[ptr::PSlot<types::DeferredSymbolLinks>]` | arena | 1 | 40960 avg (40 per item) | 0.04 |
| | (20 more) | | 905 | | 0.31 |
| **8 source and lib file text** | | heap |  | | **3.41** |
| | source file text (`Vec<u8>`/`String` from `read_file`) | heap | 177 | 20196 avg | 3.41 |
| **9 lists and maps** | | arena + heap | 103,471 | | **4.77** |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from instantiate_type_with_alias_worker | heap | 326 | 3944 avg | 1.23 |
| | `[ptr::P<types::Type>]` | arena | 100,448 | 8 avg (4 per item) | 0.76 |
| | hash table: <relater_types::Relation>::set @ tsrs_checker/src/relater_1.rs:72 | heap | 5 | 139264 avg | 0.66 |
| | hash table: insert<checker::CachedSignatureKey, ptr::P<types::Signature>> from get_erased_signature | heap | 1 | 262144 avg | 0.25 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_conditional_type_instantiation_ex | heap | 65 | 3968 avg | 0.25 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_union_type_from_sorted_list | heap | 1 | 196608 avg | 0.19 |
| | hash table: insert<checker::UnionOfUnionKey, ptr::P<types::Type>> from get_union_type_ex_uncached | heap | 1 | 196608 avg | 0.19 |
| | hash table: <types::ReferenceInstantiations>::add @ tsrs_checker/src/types.rs:2393 | heap | 174 | 1040 avg | 0.17 |
| | hash table: get_permissive_instantiation @ tsrs_checker/src/checker_12.rs:1643 | heap | 1 | 114688 avg | 0.11 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_intersection_type_worker | heap | 1 | 98304 avg | 0.09 |
| | (158 more) | | 4,684 | | 0.87 |
| **10a mappers** | | arena | 85,262 | | **1.42** |
| | `mapper::TypeMapper` | arena | 85,250 | 16 / 17 | 1.42 |
| | (1 more) | | 12 | | 0.00 |
| **10b inference** | | arena | 4,479 | | **0.08** |
| | `checker::InferenceContext` | arena | 634 | 48 / 50 | 0.03 |
| | `checker::InferenceInfo` | arena | 798 | 28 / 32 | 0.02 |
| | `RefCell<Vec<ptr::P<types::Type>>>` | arena | 424 | 32 / 32 | 0.01 |
| | `[ptr::P<checker::InferenceInfo>]` | arena | 2,530 | 4 avg (4 per item) | 0.01 |
| | (5 more) | | 93 | | 0.01 |
| **10c flow nodes** | | arena + heap | 6,925 | | **0.27** |
| | flow memo | heap | 1 | 163840 avg | 0.16 |
| | `flow::FlowNode` | arena (+region) | 6,161 | 16 / 18 | 0.11 |
| | (2 more) | | 764 | | 0.01 |
| **10d diagnostics** | | arena + heap | 498 | | **0.11** |
| | `diagnostic::Diagnostic` | arena | 417 | 152 / 153 | 0.06 |
| | diagnostics (heap) | heap | 990 | 48 avg | 0.05 |
| | (2 more) | | 81 | | 0.00 |
| **10e node builder / printer** | | arena | 190 | | **0.04** |
| | `nodebuilder_types::NodeBuilderContext` | arena | 87 | 440 / 440 | 0.04 |
| | (9 more) | | 103 | | 0.00 |
| **10f other checker objects** | | arena | 54 | | **0.01** |
| | (6 more) | | 54 | | 0.01 |
| **10g program, config, module resolution, other** | | arena + heap | 470 | | **0.39** |
| | `file_include::FileIncludeReason` | arena | 364 | 64 / 66 | 0.02 |
| | index map: enummaps::LIB_MAP::{closure#0} @ tsrs_tsoptions/src/enummaps.rs:17 | heap | 2 | 11520 avg | 0.02 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1088 | heap | 1 | 20480 avg | 0.02 |
| | hash table: cachedvfs::cachedvfs::from::<Arc<dyn vfs::FS>> @ tsrs_vfs/src/cachedvfs/cachedvfs.rs:16 | heap | 5 | 3584 avg | 0.02 |
| | hash table: <fileloader::fileLoader>::resolve_imports_and_module_augmentations @ tsrs_compiler/src/fileloader.rs:1631 | heap | 79 | 219 avg | 0.02 |
| | arc/rc: new<String> @ tsrs_core/src/tspath/path.rs:18 | heap | 185 | 87 avg | 0.02 |
| | hash table: command_line_options_to_map @ tsrs_tsoptions/src/tsconfigparsing.rs:900 | heap | 4 | 3952 avg | 0.02 |
| | hash table: clone @ tsrs_tsoptions/src/tsconfigparsing.rs:876 | heap | 1 | 14336 avg | 0.01 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1082 | heap | 1 | 14336 avg | 0.01 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1086 | heap | 1 | 14336 avg | 0.01 |
| | (135 more) | | 1,921 | | 0.22 |
| **total** | arena live 20.97 + heap live 10.80 | | | | **31.77** |

Arena: 728,474 live objects / 988,004 allocated (27.44 MiB allocated; given back: 0.65 MiB to free lists, 4.08 MiB by parser rewinds, 2.16 MiB with freed regions). Live bytes allocated before `parse end`: 4.65 MiB. Census live 21,990,188 B vs memsplit arena used 21,972,496 B (unattributed 9,017 B; free lists hold 856 B). Heap: 28,615 live blocks, 9.87 MiB requested / 10.80 MiB usable; 379,646 heap allocations (37.10 MiB) over the run.

### zod3, go mode

| kind | Rust type | store | count | bytes each | MiB |
|---|---|---|---:|---|---:|
| **1 AST nodes** | | arena + heap | 343,260 | | **9.01** |
| | `ast::NodeAlloc<identifier::Identifier>` | arena | 73,434 | 32 / 32 | 2.24 |
| | `ast::Node` | arena | 27,504 | 24 / 24 | 0.63 |
| | `ast::NodeList` | arena | 34,615 | 16 / 18 | 0.60 |
| | `ast::NodeAlloc<generated::TypeReferenceNode>` | arena | 19,242 | 32 / 32 | 0.59 |
| | `ast::NodeAlloc<generated::ParameterDeclaration>` | arena | 12,221 | 48 / 48 | 0.56 |
| | `[ptr::P<ast::Node>]` | arena | 82,652 | 6 avg (4 per item) | 0.48 |
| | `ast::NodeAlloc<generated::PropertySignatureDeclaration>` | arena | 9,731 | 48 / 48 | 0.45 |
| | `ast::NodeAlloc<generated::PropertyAccessExpression>` | arena | 8,805 | 40 / 40 | 0.34 |
| | `ast::NodeAlloc<generated::CallExpression>` | arena | 7,428 | 40 / 40 | 0.28 |
| | `ast::NodeAlloc<generated::MethodSignatureDeclaration>` | arena | 4,296 | 64 / 64 | 0.26 |
| | (124 more) | | 64,131 | | 2.58 |
| **2 identifiers and text** | | arena | 14,562 | | **0.14** |
| | `str` | arena | 13,618 | 10 avg | 0.13 |
| | (2 more) | | 944 | | 0.01 |
| | `ast::NodeAlloc<identifier::Identifier>` (counted in 1) | arena | 73,434 | 32 / 32 | (2.24) |
| | `ast::NodeAlloc<identifier::IdentifierWithText>` (counted in 1) | arena | 463 | 40 / 42 | (0.02) |
| **3 symbols** | | arena | 204,580 | | **6.35** |
| | `symbol::Symbol` | arena | 198,431 | 32 / 33 | 6.20 |
| | `symbol::SymbolTables` | arena | 6,149 | 24 / 24 | 0.14 |
| **4 symbol tables and members** | | arena + heap | 72,102 | | **7.87** |
| | symbol table entry buffers (`EntryVec`) | heap | 29,975 | 109 avg | 3.11 |
| | symbol table name indexes (hash tables) | heap | 5,690 | 473 avg | 2.56 |
| | `[ptr::P<symbol::Symbol>]` | arena | 40,012 | 28 avg (4 per item) | 1.08 |
| | `symbol::SymbolTable` | arena | 32,090 | 24 / 25 | 0.76 |
| | symbol table extras (`Box<SymbolMapExtra>`) | heap | 5,690 | 64 avg | 0.35 |
| **5 types** | | arena | 152,402 | | **5.96** |
| | `types::TypeAlloc<types::ObjectType>` | arena | 31,798 | 40 / 40 | 1.22 |
| | `types::StructuredMembers` | arena | 38,261 | 32 / 32 | 1.17 |
| | `types::TypeAlloc<types::TypeReference>` | arena | 21,587 | 48 / 50 | 1.03 |
| | `types::TypeAlloc<types::TypeParameter>` | arena | 11,191 | 56 / 56 | 0.60 |
| | `types::TypeAlloc<types::MappedType>` | arena | 6,164 | 72 / 72 | 0.42 |
| | `types::TypeAlloc<types::UnionType>` | arena | 8,720 | 48 / 50 | 0.42 |
| | `types::TypeAlloc<types::LiteralType>` | arena | 3,064 | 56 / 58 | 0.17 |
| | `types::TypeAlloc<types::ConditionalType>` | arena | 2,387 | 72 / 72 | 0.16 |
| | `types::TypeAlias` | arena | 8,019 | 16 / 19 | 0.14 |
| | `types::TypeAlloc<types::IntersectionType>` | arena | 2,840 | 48 / 50 | 0.14 |
| | (20 more) | | 18,371 | | 0.49 |
| **6 signatures** | | arena | 50,402 | | **1.65** |
| | `types::Signature` | arena | 28,801 | 56 / 56 | 1.54 |
| | `[ptr::P<types::Signature>]` | arena | 20,265 | 5 avg (4 per item) | 0.09 |
| | `types::SignatureRare` | arena | 1,330 | 16 / 16 | 0.02 |
| | (1 more) | | 6 | | 0.00 |
| **7 links and side tables** | | arena + heap | 4,585 | | **4.32** |
| | `[ptr::PSlot<types::ValueSymbolLinks>]` | arena | 40 | 65536 avg (16 per item) | 2.50 |
| | link stores (hash tables / vectors) | heap | 51 | 8016 avg | 0.39 |
| | `links::IdGroup` | arena | 1,280 | 264 / 264 | 0.32 |
| | `[ptr::PSlot<types::TypeNodeLinks>]` | arena | 8 | 24576 avg (24 per item) | 0.19 |
| | `[ptr::PSlot<types::SignatureLinks>]` | arena | 10 | 16384 avg (16 per item) | 0.16 |
| | `[ptr::PSlot<types::SourceFileLinks>]` | arena | 1 | 155648 avg (152 per item) | 0.15 |
| | `[ptr::PSlot<types::ContainingSymbolLinks>]` | arena | 1 | 98304 avg (96 per item) | 0.09 |
| | `[types::SymbolNodeLinks; 32]` | arena | 733 | 128 / 129 | 0.09 |
| | `types::ValueSymbolLinksTail` | arena | 2,460 | 24 / 24 | 0.06 |
| | `[ptr::PSlot<types::MappedSymbolLinks>]` | arena | 6 | 8192 avg (8 per item) | 0.05 |
| | (20 more) | | 46 | | 0.33 |
| **8 source and lib file text** | | heap |  | | **3.41** |
| | source file text (`Vec<u8>`/`String` from `read_file`) | heap | 177 | 20196 avg | 3.41 |
| **9 lists and maps** | | arena + heap | 106,958 | | **4.83** |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from instantiate_type_with_alias_worker | heap | 326 | 3943 avg | 1.23 |
| | `[ptr::P<types::Type>]` | arena | 103,934 | 8 avg (4 per item) | 0.82 |
| | hash table: <relater_types::Relation>::set @ tsrs_checker/src/relater_1.rs:72 | heap | 5 | 139264 avg | 0.66 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_union_type_from_sorted_list | heap | 1 | 393216 avg | 0.38 |
| | hash table: insert<checker::CachedSignatureKey, ptr::P<types::Signature>> from get_erased_signature | heap | 1 | 262144 avg | 0.25 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_conditional_type_instantiation_ex | heap | 65 | 3969 avg | 0.25 |
| | hash table: insert<checker::UnionOfUnionKey, ptr::P<types::Type>> from get_union_type_ex_uncached | heap | 1 | 196608 avg | 0.19 |
| | hash table: <types::ReferenceInstantiations>::add @ tsrs_checker/src/types.rs:2393 | heap | 174 | 1040 avg | 0.17 |
| | hash table: get_permissive_instantiation @ tsrs_checker/src/checker_12.rs:1643 | heap | 1 | 114688 avg | 0.11 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_intersection_type_worker | heap | 1 | 98304 avg | 0.09 |
| | (133 more) | | 4,407 | | 0.68 |
| **10a mappers** | | arena | 91,970 | | **1.52** |
| | `mapper::TypeMapper` | arena | 91,958 | 16 / 17 | 1.52 |
| | (1 more) | | 12 | | 0.00 |
| **10b inference** | | arena | 4,470 | | **0.08** |
| | `checker::InferenceContext` | arena | 634 | 48 / 50 | 0.03 |
| | `checker::InferenceInfo` | arena | 798 | 28 / 32 | 0.02 |
| | `RefCell<Vec<ptr::P<types::Type>>>` | arena | 424 | 32 / 32 | 0.01 |
| | `[ptr::P<checker::InferenceInfo>]` | arena | 2,521 | 4 avg (4 per item) | 0.01 |
| | (5 more) | | 93 | | 0.01 |
| **10c flow nodes** | | arena + heap | 15,686 | | **0.42** |
| | `flow::FlowNode` | arena | 14,221 | 16 / 18 | 0.25 |
| | flow memo | heap | 1 | 163840 avg | 0.16 |
| | `flow::FlowList` | arena | 1,462 | 8 / 8 | 0.01 |
| | (1 more) | | 3 | | 0.00 |
| **10d diagnostics** | | arena + heap | 477 | | **0.11** |
| | `diagnostic::Diagnostic` | arena | 396 | 152 / 153 | 0.06 |
| | diagnostics (heap) | heap | 990 | 48 avg | 0.05 |
| | (2 more) | | 81 | | 0.00 |
| **10e node builder / printer** | | arena | 190 | | **0.04** |
| | `nodebuilder_types::NodeBuilderContext` | arena | 87 | 440 / 440 | 0.04 |
| | (9 more) | | 103 | | 0.00 |
| **10f other checker objects** | | arena | 54 | | **0.01** |
| | (6 more) | | 54 | | 0.01 |
| **10g program, config, module resolution, other** | | arena + heap | 470 | | **0.38** |
| | `file_include::FileIncludeReason` | arena | 364 | 64 / 65 | 0.02 |
| | index map: enummaps::LIB_MAP::{closure#0} @ tsrs_tsoptions/src/enummaps.rs:17 | heap | 2 | 11520 avg | 0.02 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1088 | heap | 1 | 20480 avg | 0.02 |
| | hash table: cachedvfs::cachedvfs::from::<Arc<dyn vfs::FS>> @ tsrs_vfs/src/cachedvfs/cachedvfs.rs:16 | heap | 5 | 3584 avg | 0.02 |
| | hash table: <fileloader::fileLoader>::resolve_imports_and_module_augmentations @ tsrs_compiler/src/fileloader.rs:1631 | heap | 79 | 219 avg | 0.02 |
| | arc/rc: new<String> @ tsrs_core/src/tspath/path.rs:18 | heap | 185 | 88 avg | 0.02 |
| | hash table: command_line_options_to_map @ tsrs_tsoptions/src/tsconfigparsing.rs:900 | heap | 4 | 3952 avg | 0.02 |
| | hash table: clone @ tsrs_tsoptions/src/tsconfigparsing.rs:876 | heap | 1 | 14336 avg | 0.01 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1082 | heap | 1 | 14336 avg | 0.01 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1086 | heap | 1 | 14336 avg | 0.01 |
| | (128 more) | | 1,909 | | 0.21 |
| **total** | arena live 31.71 + heap live 14.38 | | | | **46.09** |

Arena: 1,062,168 live objects / 1,108,367 allocated (32.09 MiB allocated; given back: 0.70 MiB to free lists, 0.21 MiB by parser rewinds, 0.00 MiB with freed regions). Live bytes allocated before `parse end`: 10.78 MiB. Census live 33,253,316 B vs memsplit arena used 33,268,492 B (unattributed 15,176 B; free lists hold 864 B). Heap: 47,413 live blocks, 13.05 MiB requested / 14.38 MiB usable; 460,207 heap allocations (51.65 MiB) over the run.

### ts-pattern, shipped mode

| kind | Rust type | store | count | bytes each | MiB |
|---|---|---|---:|---|---:|
| **1 AST nodes** | | arena + heap | 166,207 | | **4.02** |
| | `ast::NodeAlloc<identifier::Identifier>` | arena (+region) | 26,091 | 32 / 32 | 0.80 |
| | `[ptr::P<ast::Node>]` | arena (+region) | 59,972 | 7 avg (4 per item) | 0.38 |
| | `ast::NodeAlloc<generated::TypeReferenceNode>` | arena (+region) | 9,107 | 32 / 32 | 0.28 |
| | `ast::Node` | arena (+region) | 11,623 | 24 / 24 | 0.27 |
| | `ast::NodeList` | arena (+region) | 14,516 | 16 / 18 | 0.25 |
| | `ast::NodeAlloc<generated::ParameterDeclaration>` | arena (+region) | 5,413 | 48 / 48 | 0.25 |
| | `lazylist::LazyNodeList` | arena | 2,582 | 72 / 72 | 0.18 |
| | `ast::NodeAlloc<generated::PropertySignatureDeclaration>` | arena (+region) | 2,935 | 48 / 48 | 0.13 |
| | `ast::NodeAlloc<generated::LiteralTypeNode>` | arena (+region) | 3,986 | 32 / 32 | 0.12 |
| | `ast::NodeAlloc<generated::MethodSignatureDeclaration>` | arena | 1,984 | 64 / 64 | 0.12 |
| | (108 more) | | 28,833 | | 1.24 |
| **2 identifiers and text** | | arena | 132,268 | | **0.93** |
| | `str` | arena (+region) | 130,228 | 7 avg | 0.88 |
| | `[&str]` | arena | 426 | 90 avg (16 per item) | 0.04 |
| | (1 more) | | 1,614 | | 0.01 |
| | `ast::NodeAlloc<identifier::Identifier>` (counted in 1) | arena (+region) | 26,091 | 32 / 32 | (0.80) |
| | `ast::NodeAlloc<identifier::IdentifierWithText>` (counted in 1) | arena | 402 | 40 / 42 | (0.02) |
| **3 symbols** | | arena | 476,381 | | **14.97** |
| | `symbol::Symbol` | arena (+region) | 469,663 | 32 / 33 | 14.81 |
| | `symbol::SymbolTables` | arena (+region) | 6,718 | 24 / 24 | 0.16 |
| **4 symbol tables and members** | | arena + heap | 232,098 | | **11.61** |
| | symbol table entry buffers (`EntryVec`) | heap | 79,393 | 59 avg | 4.43 |
| | symbol table name indexes (hash tables) | heap | 7,256 | 403 avg | 2.79 |
| | `[ptr::P<symbol::Symbol>]` | arena | 161,195 | 15 avg (4 per item) | 2.29 |
| | `symbol::SymbolTable` | arena (+region) | 70,903 | 24 / 24 | 1.65 |
| | symbol table extras (`Box<SymbolMapExtra>`) | heap | 7,256 | 64 avg | 0.44 |
| **5 types** | | arena | 840,638 | | **35.38** |
| | `types::TypeAlloc<types::ObjectType>` | arena | 156,170 | 40 / 40 | 6.02 |
| | `types::StructuredMembers` | arena | 153,862 | 32 / 32 | 4.75 |
| | `types::TypeAlloc<types::TypeParameter>` | arena | 80,316 | 56 / 56 | 4.29 |
| | `types::TypeAlloc<types::TypeReference>` | arena | 86,344 | 48 / 49 | 4.06 |
| | `types::TypeAlloc<types::ConditionalType>` | arena | 46,649 | 72 / 73 | 3.24 |
| | `types::TypeAlloc<types::IntersectionType>` | arena | 57,708 | 48 / 49 | 2.69 |
| | `checker_09::LazyMemberTable` | arena | 32,980 | 80 / 81 | 2.54 |
| | `types::TypeAlloc<types::MappedType>` | arena | 33,232 | 72 / 73 | 2.31 |
| | `types::TypeAlloc<types::UnionType>` | arena | 38,574 | 48 / 49 | 1.81 |
| | `types::UnionRare` | arena | 14,228 | 56 / 56 | 0.77 |
| | (20 more) | | 140,575 | | 2.89 |
| **6 signatures** | | arena | 236,820 | | **7.79** |
| | `types::Signature` | arena | 134,328 | 56 / 56 | 7.20 |
| | `[ptr::P<types::Signature>]` | arena | 92,022 | 5 avg (4 per item) | 0.42 |
| | `types::SignatureRare` | arena | 10,461 | 16 / 17 | 0.17 |
| | (1 more) | | 9 | | 0.00 |
| **7 links and side tables** | | arena + heap | 16,181 | | **11.98** |
| | `[ptr::PSlot<types::ValueSymbolLinks>]` | arena | 113 | 65536 avg (16 per item) | 7.06 |
| | link stores (hash tables / vectors) | heap | 51 | 36028 avg | 1.75 |
| | `links::IdGroup` | arena | 3,615 | 264 / 264 | 0.91 |
| | `[ptr::PSlot<types::MappedSymbolLinks>]` | arena | 87 | 8192 avg (8 per item) | 0.68 |
| | `[ptr::PSlot<types::TypeNodeLinks>]` | arena | 19 | 24576 avg (24 per item) | 0.45 |
| | `types::ValueSymbolLinksTail` | arena | 11,654 | 24 / 24 | 0.27 |
| | `[ptr::PSlot<types::DeferredSymbolLinks>]` | arena | 4 | 40960 avg (40 per item) | 0.16 |
| | `[ptr::PSlot<types::SourceFileLinks>]` | arena | 1 | 155648 avg (152 per item) | 0.15 |
| | `[ptr::PSlot<types::SignatureLinks>]` | arena | 8 | 16384 avg (16 per item) | 0.13 |
| | `[ptr::PSlot<types::ContainingSymbolLinks>]` | arena | 1 | 98304 avg (96 per item) | 0.09 |
| | (18 more) | | 679 | | 0.34 |
| **8 source and lib file text** | | heap |  | | **3.46** |
| | source file text (`Vec<u8>`/`String` from `read_file`) | heap | 169 | 21481 avg | 3.46 |
| **9 lists and maps** | | arena + heap | 757,231 | | **37.27** |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_object_type_instantiation | heap | 332 | 23993 avg | 7.60 |
| | `[ptr::P<types::Type>]` | arena | 719,298 | 11 avg (4 per item) | 7.22 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_conditional_type_instantiation_ex | heap | 232 | 27401 avg | 6.06 |
| | hash table: get_restrictive_instantiation @ tsrs_checker/src/checker_12.rs:1663 | heap | 1 | 3670016 avg | 3.50 |
| | hash table: <relater_types::Relation>::set @ tsrs_checker/src/relater_1.rs:72 | heap | 5 | 690176 avg | 3.29 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_intersection_type_worker | heap | 1 | 2883584 avg | 2.75 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_union_type_from_sorted_list | heap | 1 | 1441792 avg | 1.38 |
| | hash table: insert<checker::CachedSignatureKey, ptr::P<types::Signature>> from get_signature_instantiation | heap | 1 | 983040 avg | 0.94 |
| | hash table: insert<checker::UnionOfUnionKey, ptr::P<types::Type>> from get_union_type_ex_uncached | heap | 1 | 720896 avg | 0.69 |
| | hash table: insert<ptr::P<types::Type>, ptr::P<checker_09::LazyMemberTable>> from create_lazy_member_table | heap | 1 | 655360 avg | 0.62 |
| | (163 more) | | 54,379 | | 3.23 |
| **10a mappers** | | arena | 515,478 | | **8.22** |
| | `mapper::TypeMapper` | arena | 515,463 | 16 / 17 | 8.22 |
| | (1 more) | | 15 | | 0.00 |
| **10b inference** | | arena | 100,398 | | **1.95** |
| | `checker::InferenceContext` | arena | 14,845 | 48 / 49 | 0.69 |
| | `checker::InferenceInfo` | arena | 20,561 | 28 / 32 | 0.63 |
| | `RefCell<Vec<ptr::P<types::Type>>>` | arena | 11,133 | 32 / 32 | 0.34 |
| | `[ptr::P<checker::InferenceInfo>]` | arena | 53,751 | 5 avg (4 per item) | 0.28 |
| | (5 more) | | 108 | | 0.01 |
| **10c flow nodes** | | arena + heap | 3,963 | | **0.23** |
| | flow memo | heap | 2 | 82048 avg | 0.16 |
| | `flow::FlowNode` | arena (+region) | 3,910 | 16 / 18 | 0.07 |
| | (2 more) | | 53 | | 0.00 |
| **10d diagnostics** | | arena + heap | 1,698 | | **0.35** |
| | `diagnostic::Diagnostic` | arena | 1,446 | 152 / 153 | 0.21 |
| | diagnostics (heap) | heap | 2,679 | 53 avg | 0.13 |
| | (2 more) | | 252 | | 0.00 |
| **10e node builder / printer** | | arena | 453 | | **0.09** |
| | `nodebuilder_types::NodeBuilderContext` | arena | 205 | 440 / 441 | 0.09 |
| | (11 more) | | 248 | | 0.01 |
| **10f other checker objects** | | arena | 26 | | **0.00** |
| | (6 more) | | 26 | | 0.00 |
| **10g program, config, module resolution, other** | | arena + heap | 505 | | **0.41** |
| | `file_include::FileIncludeReason` | arena | 393 | 64 / 66 | 0.02 |
| | hash table: add_emit_flags @ tsrs_printer/src/emitcontext.rs:725 | heap | 1 | 24576 avg | 0.02 |
| | index map: enummaps::LIB_MAP::{closure#0} @ tsrs_tsoptions/src/enummaps.rs:17 | heap | 2 | 11520 avg | 0.02 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1088 | heap | 1 | 20480 avg | 0.02 |
| | hash table: cachedvfs::cachedvfs::from::<Arc<dyn vfs::FS>> @ tsrs_vfs/src/cachedvfs/cachedvfs.rs:16 | heap | 5 | 3584 avg | 0.02 |
| | hash table: command_line_options_to_map @ tsrs_tsoptions/src/tsconfigparsing.rs:900 | heap | 4 | 3952 avg | 0.02 |
| | arc/rc: new<String> @ tsrs_core/src/tspath/path.rs:18 | heap | 177 | 88 avg | 0.01 |
| | hash table: clone @ tsrs_tsoptions/src/tsconfigparsing.rs:876 | heap | 1 | 14336 avg | 0.01 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1082 | heap | 1 | 14336 avg | 0.01 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1086 | heap | 1 | 14336 avg | 0.01 |
| | (138 more) | | 2,273 | | 0.23 |
| **total** | arena live 95.30 + heap live 43.35 | | | | **138.64** |

Arena: 3,480,345 live objects / 4,997,426 allocated (124.69 MiB allocated; given back: 23.40 MiB to free lists, 3.98 MiB by parser rewinds, 3.56 MiB with freed regions). Live bytes allocated before `parse end`: 4.01 MiB. Census live 99,925,395 B vs memsplit arena used 99,994,820 B (unattributed 165,832 B; free lists hold 1,176 B). Heap: 117,016 live blocks, 39.43 MiB requested / 43.35 MiB usable; 2,092,610 heap allocations (166.05 MiB) over the run.

### ts-pattern, go mode

| kind | Rust type | store | count | bytes each | MiB |
|---|---|---|---:|---|---:|
| **1 AST nodes** | | arena + heap | 390,945 | | **9.63** |
| | `ast::NodeAlloc<identifier::Identifier>` | arena | 73,171 | 32 / 32 | 2.23 |
| | `ast::NodeAlloc<generated::TypeReferenceNode>` | arena | 23,412 | 32 / 32 | 0.71 |
| | `[ptr::P<ast::Node>]` | arena | 117,032 | 6 avg (4 per item) | 0.70 |
| | `ast::Node` | arena | 29,887 | 24 / 24 | 0.68 |
| | `ast::NodeList` | arena | 38,202 | 16 / 18 | 0.66 |
| | `ast::NodeAlloc<generated::ParameterDeclaration>` | arena | 12,784 | 48 / 48 | 0.59 |
| | `ast::NodeAlloc<generated::PropertySignatureDeclaration>` | arena | 11,980 | 48 / 48 | 0.55 |
| | `ast::NodeAlloc<generated::StringLiteral>` | arena | 7,443 | 40 / 40 | 0.28 |
| | `ast::NodeAlloc<generated::MethodSignatureDeclaration>` | arena | 4,367 | 64 / 64 | 0.27 |
| | `ast::NodeAlloc<generated::LiteralTypeNode>` | arena | 8,725 | 32 / 32 | 0.27 |
| | (114 more) | | 64,777 | | 2.69 |
| **2 identifiers and text** | | arena | 132,560 | | **0.93** |
| | `str` | arena | 131,450 | 7 avg | 0.89 |
| | `[&str]` | arena | 238 | 148 avg (16 per item) | 0.03 |
| | (1 more) | | 872 | | 0.00 |
| | `ast::NodeAlloc<identifier::Identifier>` (counted in 1) | arena | 73,171 | 32 / 32 | (2.23) |
| | `ast::NodeAlloc<identifier::IdentifierWithText>` (counted in 1) | arena | 421 | 40 / 42 | (0.02) |
| **3 symbols** | | arena | 963,679 | | **29.89** |
| | `symbol::Symbol` | arena | 953,721 | 32 / 33 | 29.66 |
| | `symbol::SymbolTables` | arena | 9,958 | 24 / 24 | 0.23 |
| **4 symbol tables and members** | | arena + heap | 301,808 | | **32.49** |
| | symbol table entry buffers (`EntryVec`) | heap | 113,037 | 118 avg | 12.71 |
| | symbol table name indexes (hash tables) | heap | 27,429 | 389 avg | 10.16 |
| | `[ptr::P<symbol::Symbol>]` | arena | 185,312 | 30 avg (4 per item) | 5.22 |
| | `symbol::SymbolTable` | arena | 116,496 | 24 / 25 | 2.73 |
| | symbol table extras (`Box<SymbolMapExtra>`) | heap | 27,429 | 64 avg | 1.67 |
| **5 types** | | arena | 858,747 | | **34.05** |
| | `types::TypeAlloc<types::ObjectType>` | arena | 156,174 | 40 / 40 | 6.01 |
| | `types::StructuredMembers` | arena | 183,532 | 32 / 32 | 5.66 |
| | `types::TypeAlloc<types::TypeParameter>` | arena | 80,316 | 56 / 56 | 4.29 |
| | `types::TypeAlloc<types::TypeReference>` | arena | 86,344 | 48 / 49 | 4.05 |
| | `types::TypeAlloc<types::ConditionalType>` | arena | 46,724 | 72 / 73 | 3.24 |
| | `types::TypeAlloc<types::IntersectionType>` | arena | 57,708 | 48 / 49 | 2.69 |
| | `types::TypeAlloc<types::MappedType>` | arena | 33,232 | 72 / 72 | 2.30 |
| | `types::TypeAlloc<types::UnionType>` | arena | 38,574 | 48 / 49 | 1.81 |
| | `types::TypeAlias` | arena | 45,744 | 16 / 18 | 0.77 |
| | `types::UnionRare` | arena | 14,234 | 56 / 56 | 0.76 |
| | (19 more) | | 116,165 | | 2.47 |
| **6 signatures** | | arena | 236,820 | | **7.78** |
| | `types::Signature` | arena | 134,328 | 56 / 56 | 7.19 |
| | `[ptr::P<types::Signature>]` | arena | 92,022 | 5 avg (4 per item) | 0.42 |
| | `types::SignatureRare` | arena | 10,461 | 16 / 17 | 0.17 |
| | (1 more) | | 9 | | 0.00 |
| **7 links and side tables** | | arena + heap | 47,830 | | **20.41** |
| | `[ptr::PSlot<types::ValueSymbolLinks>]` | arena | 223 | 65536 avg (16 per item) | 13.94 |
| | `links::IdGroup` | arena | 7,158 | 264 / 264 | 1.80 |
| | link stores (hash tables / vectors) | heap | 51 | 36440 avg | 1.77 |
| | `types::ValueSymbolLinksTail` | arena | 39,649 | 24 / 24 | 0.91 |
| | `[ptr::PSlot<types::MappedSymbolLinks>]` | arena | 88 | 8192 avg (8 per item) | 0.69 |
| | `[ptr::PSlot<types::TypeNodeLinks>]` | arena | 19 | 24576 avg (24 per item) | 0.45 |
| | `[ptr::PSlot<types::DeferredSymbolLinks>]` | arena | 4 | 40960 avg (40 per item) | 0.16 |
| | `[ptr::PSlot<types::SourceFileLinks>]` | arena | 1 | 155648 avg (152 per item) | 0.15 |
| | `[ptr::PSlot<types::SignatureLinks>]` | arena | 8 | 16384 avg (16 per item) | 0.13 |
| | `[ptr::PSlot<types::ContainingSymbolLinks>]` | arena | 1 | 98304 avg (96 per item) | 0.09 |
| | (18 more) | | 679 | | 0.34 |
| **8 source and lib file text** | | heap |  | | **3.46** |
| | source file text (`Vec<u8>`/`String` from `read_file`) | heap | 169 | 21481 avg | 3.46 |
| **9 lists and maps** | | arena + heap | 777,332 | | **36.46** |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from instantiate_type_with_alias_worker | heap | 391 | 20489 avg | 7.64 |
| | `[ptr::P<types::Type>]` | arena | 741,277 | 11 avg (4 per item) | 7.62 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_conditional_type_instantiation_ex | heap | 232 | 27400 avg | 6.06 |
| | hash table: get_restrictive_instantiation @ tsrs_checker/src/checker_12.rs:1663 | heap | 1 | 3670016 avg | 3.50 |
| | hash table: <relater_types::Relation>::set @ tsrs_checker/src/relater_1.rs:72 | heap | 5 | 690176 avg | 3.29 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_intersection_type_worker | heap | 1 | 2883584 avg | 2.75 |
| | hash table: insert<checker::CacheHashKey, ptr::P<types::Type>> from get_union_type_from_sorted_list | heap | 1 | 1441792 avg | 1.38 |
| | hash table: insert<checker::CachedSignatureKey, ptr::P<types::Signature>> from get_signature_instantiation | heap | 1 | 983040 avg | 0.94 |
| | hash table: insert<checker::UnionOfUnionKey, ptr::P<types::Type>> from get_union_type_ex_uncached | heap | 1 | 720896 avg | 0.69 |
| | hash table: <types::ReferenceInstantiations>::add @ tsrs_checker/src/types.rs:2393 | heap | 263 | 2431 avg | 0.61 |
| | (139 more) | | 49,211 | | 1.99 |
| **10a mappers** | | arena | 763,740 | | **12.10** |
| | `mapper::TypeMapper` | arena | 763,725 | 16 / 17 | 12.10 |
| | (1 more) | | 15 | | 0.00 |
| **10b inference** | | arena | 100,354 | | **1.95** |
| | `checker::InferenceContext` | arena | 14,845 | 48 / 49 | 0.69 |
| | `checker::InferenceInfo` | arena | 20,561 | 28 / 32 | 0.63 |
| | `RefCell<Vec<ptr::P<types::Type>>>` | arena | 11,133 | 32 / 32 | 0.34 |
| | `[ptr::P<checker::InferenceInfo>]` | arena | 53,707 | 5 avg (4 per item) | 0.28 |
| | (5 more) | | 108 | | 0.01 |
| **10c flow nodes** | | arena + heap | 11,451 | | **0.36** |
| | `flow::FlowNode` | arena | 11,357 | 16 / 19 | 0.20 |
| | flow memo | heap | 2 | 82048 avg | 0.16 |
| | (2 more) | | 94 | | 0.00 |
| **10d diagnostics** | | arena + heap | 1,595 | | **0.33** |
| | `diagnostic::Diagnostic` | arena | 1,343 | 152 / 153 | 0.20 |
| | diagnostics (heap) | heap | 2,679 | 53 avg | 0.13 |
| | (2 more) | | 252 | | 0.00 |
| **10e node builder / printer** | | arena | 453 | | **0.09** |
| | `nodebuilder_types::NodeBuilderContext` | arena | 205 | 440 / 441 | 0.09 |
| | (11 more) | | 248 | | 0.01 |
| **10f other checker objects** | | arena | 26 | | **0.00** |
| | (6 more) | | 26 | | 0.00 |
| **10g program, config, module resolution, other** | | arena + heap | 505 | | **0.41** |
| | `file_include::FileIncludeReason` | arena | 393 | 64 / 66 | 0.02 |
| | hash table: add_emit_flags @ tsrs_printer/src/emitcontext.rs:725 | heap | 1 | 24576 avg | 0.02 |
| | index map: enummaps::LIB_MAP::{closure#0} @ tsrs_tsoptions/src/enummaps.rs:17 | heap | 2 | 11520 avg | 0.02 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1088 | heap | 1 | 20480 avg | 0.02 |
| | hash table: cachedvfs::cachedvfs::from::<Arc<dyn vfs::FS>> @ tsrs_vfs/src/cachedvfs/cachedvfs.rs:16 | heap | 5 | 3584 avg | 0.02 |
| | hash table: command_line_options_to_map @ tsrs_tsoptions/src/tsconfigparsing.rs:900 | heap | 4 | 3952 avg | 0.02 |
| | arc/rc: new<String> @ tsrs_core/src/tspath/path.rs:18 | heap | 177 | 88 avg | 0.01 |
| | hash table: clone @ tsrs_tsoptions/src/tsconfigparsing.rs:876 | heap | 1 | 14336 avg | 0.01 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1082 | heap | 1 | 14336 avg | 0.01 |
| | hash table: get_processed_files @ tsrs_compiler/src/filesparser.rs:1086 | heap | 1 | 14336 avg | 0.01 |
| | (131 more) | | 2,261 | | 0.23 |
| **total** | arena live 131.32 + heap live 59.03 | | | | **190.35** |

Arena: 4,587,845 live objects / 5,843,748 allocated (153.29 MiB allocated; given back: 23.53 MiB to free lists, 0.20 MiB by parser rewinds, 0.00 MiB with freed regions). Live bytes allocated before `parse end`: 11.44 MiB. Census live 137,700,187 B vs memsplit arena used 137,912,880 B (unattributed 212,693 B; free lists hold 1,176 B). Heap: 188,025 live blocks, 53.44 MiB requested / 59.03 MiB usable; 2,357,757 heap allocations (227.35 MiB) over the run.

## size_of of the arena structs

Every type the arena allocated in any run (`size_of` / `align_of` recorded by the hook; the arena block is
`size_of` rounded to 8, `ptr::p_layout`), with its largest live total; those under 0.1 MiB are left out, except
the few named in the request. Pointers inside are 4-byte handles (`P<T>`, compressed pointers on unix).
Heap-side: `SymbolMap` is 24 bytes inside `SymbolTable`; `SymbolMapEntry` is 8 bytes; `EntryVec` is
{ptr, u32 len, u32 cap}.

| Rust type | size_of | align_of | arena block (8-aligned) | live MiB, largest run |
|---|---:|---:|---:|---:|
| `symbol::Symbol` | 32 | 8 | 32 | 29.66 |
| `mapper::TypeMapper` | 16 | 8 | 16 | 12.10 |
| `types::Signature` | 56 | 8 | 56 | 7.20 |
| `types::TypeAlloc<types::ObjectType>` | 40 | 8 | 40 | 6.02 |
| `types::StructuredMembers` | 32 | 8 | 32 | 5.66 |
| `types::TypeAlloc<types::TypeParameter>` | 56 | 8 | 56 | 4.29 |
| `types::TypeAlloc<types::TypeReference>` | 48 | 8 | 48 | 4.06 |
| `types::TypeAlloc<types::ConditionalType>` | 72 | 8 | 72 | 3.24 |
| `symbol::SymbolTable` | 24 | 8 | 24 | 2.73 |
| `types::TypeAlloc<types::IntersectionType>` | 48 | 8 | 48 | 2.69 |
| `checker_09::LazyMemberTable` | 80 | 8 | 80 | 2.54 |
| `types::TypeAlloc<types::MappedType>` | 72 | 8 | 72 | 2.31 |
| `ast::NodeAlloc<identifier::Identifier>` | 32 | 8 | 32 | 2.24 |
| `types::TypeAlloc<types::UnionType>` | 48 | 8 | 48 | 1.81 |
| `links::IdGroup` | 264 | 4 | 264 | 1.80 |
| `types::ValueSymbolLinksTail` | 24 | 4 | 24 | 0.91 |
| `types::UnionRare` | 56 | 8 | 56 | 0.77 |
| `types::TypeAlias` | 16 | 8 | 16 | 0.77 |
| `ast::NodeAlloc<generated::TypeReferenceNode>` | 32 | 8 | 32 | 0.71 |
| `checker::InferenceContext` | 48 | 8 | 48 | 0.69 |
| `ast::Node` | 24 | 8 | 24 | 0.68 |
| `ast::NodeList` | 16 | 8 | 16 | 0.66 |
| `checker::InferenceInfo` | 28 | 4 | 32 | 0.63 |
| `types::IndexInfo` | 40 | 8 | 40 | 0.62 |
| `ast::NodeAlloc<generated::ParameterDeclaration>` | 48 | 8 | 48 | 0.59 |
| `ast::NodeAlloc<generated::PropertySignatureDeclaration>` | 48 | 8 | 48 | 0.55 |
| `types::IndexInfosTail` | 16 | 8 | 16 | 0.45 |
| `types::IntersectionRare` | 24 | 8 | 24 | 0.39 |
| `RefCell<Vec<ptr::P<types::Type>>>` | 32 | 8 | 32 | 0.34 |
| `ast::NodeAlloc<generated::PropertyAccessExpression>` | 40 | 8 | 40 | 0.34 |
| `types::TypeSymbolAlias` | 8 | 4 | 8 | 0.32 |
| `ast::NodeAlloc<generated::StringLiteral>` | 40 | 8 | 40 | 0.28 |
| `ast::NodeAlloc<generated::CallExpression>` | 40 | 8 | 40 | 0.28 |
| `types::TypePredicate` | 40 | 8 | 40 | 0.28 |
| `ast::NodeAlloc<generated::MethodSignatureDeclaration>` | 64 | 8 | 64 | 0.27 |
| `ast::NodeAlloc<generated::LiteralTypeNode>` | 32 | 8 | 32 | 0.27 |
| `flow::FlowNode` | 16 | 4 | 16 | 0.25 |
| `symbol::SymbolTables` | 24 | 4 | 24 | 0.23 |
| `diagnostic::Diagnostic` | 152 | 8 | 152 | 0.21 |
| `ast::NodeAlloc<generated::NumericLiteral>` | 40 | 8 | 40 | 0.19 |
| `lazylist::LazyNodeList` | 72 | 8 | 72 | 0.18 |
| `ast::NodeAlloc<generated::ArrowFunction>` | 80 | 8 | 80 | 0.17 |
| `types::SignatureRare` | 16 | 4 | 16 | 0.17 |
| `types::TypeAlloc<types::LiteralType>` | 56 | 8 | 56 | 0.17 |
| `ast::ModifierList` | 24 | 8 | 24 | 0.15 |
| `ast::NodeAlloc<generated::UnionTypeNode>` | 32 | 8 | 32 | 0.13 |
| `ast::NodeAlloc<generated::PropertyAssignment>` | 48 | 8 | 48 | 0.13 |
| `ast::NodeAlloc<ast::SourceFile>` | 720 | 16 | 720 | 0.12 |
| `ast::NodeAlloc<generated::InterfaceDeclaration>` | 56 | 8 | 56 | 0.11 |
| `ast::NodeAlloc<generated::VariableDeclaration>` | 48 | 8 | 48 | 0.11 |
| `ast::NodeAlloc<generated::TypeAliasDeclaration>` | 64 | 8 | 64 | 0.11 |
| `flow::FlowList` | 8 | 4 | 8 | 0.01 |
| `checker::InferenceContextRare` | 56 | 8 | 56 | 0.00 |
| `mapper::RareTypeMapper` | 40 | 8 | 40 | 0.00 |

## Method and sources

- **Builds.** Shipped binary: `/zfs/trig-pup/tsrs-shipped/package/tsrs` (reports tsrs 0.18.0-ts7.1.0-dev.20260929).
  Census build: a copy of `/zfs/trig-pup/tsrs/src` (280b426b) with `tsrs-raw/pup-patch/tsrs-census.diff`
  applied (by `apply-patch.py`, which copies `census.rs` and `heapcensus.rs`), built with Cargo's `dev` profile
  as the repository defines it (opt-level 3, no LTO, 256 codegen units) and `debug-assertions` and
  `overflow-checks` off, line tables, no strip, `-C force-frame-pointers=yes`, `--features tsrs_cli/noembed`
  like the release (`pup-patch/build.sh`, through `slot.sh`). Not PGO/LTO/BOLT: struct sizes and object counts do
  not depend on them. Check: Identifiers / Symbols / Types / Instantiations from `--extendedDiagnostics` are
  identical between the shipped binary and the census build in all six runs (ts-pattern shipped 78,424 /
  480,145 / 506,488 / 3,634,342; go 78,424 / 953,714 / 506,567 / 3,638,700), and the census build's
  `TSRS_MEM_SPLIT` arena used equals the shipped binary's (ts-pattern 95.4 / 131.5 MiB).
- **Output check.** `run-shipped.sh` runs, per project and mode, a plain run (stdout+stderr and exit status
  compared with tsc 655f0268's), a `TSRS_MEM_SPLIT=1` run (census files and the split on stderr; its stdout and
  status also compared) and an `--extendedDiagnostics` run. All 24 comparisons matched (`shipped.log`,
  `census.log`).
- **Arena by type** (`census.rs`, hooks in `crates/tsrs_core/src/arena.rs` and `ptr.rs`). Every arena allocation
  path is hooked: `Arena::alloc_with<T>` (`P::new`, `P::new_scratch`, `ptr::alloc`), `alloc_slice_copy<T>`
  (`alloc_slice`, `alloc_slice_scratch`), `alloc_vec<T>`, `alloc_str` (as `str`), the free-list reuse paths of
  `P::new_recycled` and `alloc_slice_recycled`, and the three untyped `alloc_layout` callers (`PackedStr`'s long
  form, `alloc_slice_aligned4`, `ArenaStringBuilder`). Each records (address, requested bytes, padding taken,
  `type_name::<T>()`, store, sequence). Each event that makes arena memory dead records a kill range: a block
  pushed on a free list (`free_block`), a parser rewind (`rewind`), a freed region's chunks (`RegionInner::drop`).
  At `check end` an allocation is **live** when no later kill covers its address (a sweep over both lists sorted by
  address). So the tables count live objects at the peak, not everything allocated; each per-run paragraph
  gives allocated totals and what was given back. Reconciliation: census live bytes in thread arenas vs
  memsplit's arena used: empty and empty-go exact; zod3 9,017 / 15,176 B short; ts-pattern 165,832 / 212,693 B
  short (0.17% / 0.15%, unattributed; plus 1,176 B on free lists). Census bookkeeping lives on the heap with the
  heap census suspended.
- **Heap by allocating site** (`heapcensus.rs`, the binary's `#[global_allocator]` wrapping mimalloc). Every heap
  block alive at `check end` is kept with its requested size and a 28-frame stack (frame-pointer walk, bounded
  to the thread's stack); usable size from `mi_usable_size`. `heap-resolve.py` resolves the return addresses
  with `addr2line -f -C -i` (inlined frames expanded), names the site as the first tsrs frame, and the container
  (hash table, vec, box, string, index map) by the std/hashbrown frames under it; `*.heap.sites` are the full
  tables. Reconciliation: census heap usable vs the shipped binary's memsplit heap live: ts-pattern 43.35 vs
  43.4 MiB, go 59.03 vs 59.1; zod3 10.80 vs 10.8, 14.38 vs 14.4; empty 3.51 vs 3.5, 3.64 vs 3.7. Kinds for heap
  rows are by site file: `tsrs_ast/src/symbol.rs` -> symbol tables, `links.rs` -> links, `tsrs_vfs` `read_file`
  -> source text, `flowmemo.rs` -> flow, `diagnostic` -> diagnostics, parser/scanner -> AST, the rest of
  `tsrs_checker` -> lists and maps (packedmap/basedmap caches labelled by the checker function that filled them),
  everything else -> program/config/other.
- **RSS split.** The shipped binary's own `TSRS_MEM_SPLIT=1` report (`crates/tsrs_core/src/memsplit.rs`) at
  `check end` and `exit` (`shipped/*.memsplit`), and `smaps-peak.py` for the file-backed split (`smaps/*.smaps`).
- **Caveats.** Counts are of live objects at `check end`; 23 MiB of ts-pattern's arena allocations were freed to
  free lists and reused, 4 MiB rewound by speculative parses, 3.6 MiB freed with regions (shipped). Identifier
  text is the source text (kind 8), not separate strings. Kind boundaries are mine (`analyze.py`, `arena_kind` and
  `heap_kind`); every raw row is in the census files.

## Files (`tsrs-raw/`)

- `census/{project}.{mode}.arena`: arena census, one row per Rust type (allocated / live counts and bytes, live
  bytes allocated before `parse end`, live in regions, dead by cause).
- `census/{project}.{mode}.heap`: raw heap census (live blocks per stack, return addresses, the process maps);
  `.heap.sites`: resolved, by site.
- `census/*.memsplit`, `*.diag`, `*.out`, `*.status`: the census build's split (inflated heap: it holds the census
  bookkeeping), `--extendedDiagnostics`, outputs; `shipped/`: the same for the shipped binary, and tsc's outputs.
- `smaps/*.smaps`: peak smaps by mapping (shipped binary); `smaps/*.files`: `--listFiles`.
- `pup-patch/tsrs-census.diff`: the patch; `census.rs`, `heapcensus.rs`, `apply-patch.py`: its parts;
  `pup-patch/build.sh`, `build.log`; `run-shipped.sh`, `smaps-peak.py`, `pup-patch/smaps-go.sh`, `heap-resolve.py`,
  `analyze.py` (`python3 analyze.py tsrs-raw` regenerates the tables, `analyze.py tsrs-raw sizes` the size table).
