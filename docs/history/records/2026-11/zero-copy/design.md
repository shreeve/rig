# Zero-copy libs: a List over embedded records (design, 2026-11-04)

The question (owner, 2026-11-04): can a List start as a view of a
program's static records (an `$embed`ded file) and copy only where it
is written, so Trig loads its pre-built lib trees
(`src/ast/prebuilt.rig`) without decoding them? The checker only reads
them, so it would rarely copy. The share was measured before any
design, because no design is worth more than the time it can save.
Design only: no compiler or runtime code changed. Scripts and raw
numbers are in [data/](data/); the perf files stay on pup in
`/zfs/rig-work/zero-copy/`.

## In short

1. **Loading the libs is a third of a small project's run and under
   half a percent of a large one's.** Trig's decode of its pre-built
   libs (`ast.decode_bound_file`, with the page faults it takes) is
   17-21M cycles a run wherever `lib.dom.d.ts` is loaded (7.95 MB of
   its 9 MB of trees): 34% of mitt's cycles at one checker, 21% of
   neverthrow's, 4.3% of tiny-invariant's, 2.5% of superstruct's (no
   dom), 2.3% of zod3's, and 0.38% of ts-pattern's (table, §1). It runs
   serially before checking starts.
2. **Adopting `extend_from_bytes` leaves most of it.** The ceiling of
   that adoption (`decode-zig`: the record, u32 and node loops made
   tight) saves 28-30M instructions but only 3-4M cycles, since those
   loops are bound by memory, not by instructions. What remains is 31%
   of mitt, 19% of neverthrow, 3.5% of tiny-invariant, 2.2% of
   superstruct, 1.8% of zod3, 0.32% of ts-pattern.
3. **Zero copy could save about half of what remains, at most.** It
   removes the copy of the large arrays and the fresh heap pages they
   are copied into (374 of decode's 518 page faults on mitt), and leaves the rest: interning the libs' names,
   renaming their symbols, and rebuilding their Maps, about 40% of the
   decode that remains, which no List design touches. Estimate: 13-17%
   of mitt's cycles, 9-12% of neverthrow's, about 2% of
   tiny-invariant's, under 1% of zod3's and superstruct's, 0.1-0.2% of
   ts-pattern's. These are estimates from shares and fault counts; a
   Zig ceiling decides (§4).
4. **Recommendation: no new type, no new name, no Core change.** Make
   `!xs.extend_from_bytes(s)` map the pages of a large embedded run
   privately (`MAP_PRIVATE`, the kernel copies a page on its first
   write) when the List is empty with no buffer, and copy otherwise
   (option C, §3). The List is an ordinary List: every read, write,
   push, and drop is the code it is today, and only freeing or growing
   a buffer of 64 KiB or more checks a table of mapped buffers. A
   copy-on-write List (option A) puts a test on every element write and
   an allocation behind `v[i] = x`; a read-only `Records[T]` type
   (option B) needs no ownership rule but cannot serve Trig, whose Ast
   holds Lists. Build it only after a hand-written Zig ceiling on Trig
   clears the speed bar on pup without slowing the large projects
   (decisions, §5).

## 1. The share today

pup, one E-core (15), `--checkers 1`, fewest user cycles of 5 runs,
Trig's two PGO builds in `/zfs/trig-pup/runs/` read-only: `dec-base`
(Trig main's decode, field by field) and `dec-new` (the same built
through `decode-zig`, the ceiling of adopting `extend_from_bytes`).
Decode's user cycles come from LBR call stacks on each project's
*empty twin*, its compiler options with `skipLibCheck` and one empty
file, where decode is about half the run (100 runs a profile; the
machine allows 1,000 samples a second). Decode's kernel cycles are its
page faults (counted by address and the function that took them) times
the twin's kernel cycles per fault, 14-18k, after start-up's 3.9M and
110 faults. Cycles in millions; on these cores 1M cycles is 0.26 ms.

| project | run | decode today (user + kernel) | share | run, new | decode, new | share | zero copy could save |
|---|---|---|---|---|---|---|---|
| mitt | 59.3 | 12.0 + 7.9 | 34% | 54.2 | 9.0 + 7.9 | 31% | 7-9 (13-17%) |
| neverthrow | 78.9 | 9.7 + 7.2 | 21% | 74.7 | 6.8 + 7.2 | 19% | 7-9 (9-12%) |
| tiny-invariant | 381.6 | 9.2 + 7.2 | 4.3% | 378.6 | 6.2 + 7.2 | 3.5% | 7-9 (about 2%) |
| superstruct | 154.2 | 2.6 + 1.3 | 2.5% | 151.7 | 2.0 + 1.3 | 2.2% | 0.5-1 (under 1%) |
| zod3 | 911.2 | 12.7 + 8.3 | 2.3% | 906.8 | 8.3 + 8.3 | 1.8% | 7-9 (under 1%) |
| ts-pattern | 5648.9 | 13.4 + 7.9 | 0.38% | 5645 | 9.9 + 7.9 | 0.32% | 7-9 (0.1-0.2%) |

- The decode of one lib set costs the same in every project that loads
  it, so the share falls as the project grows. tiny-invariant's run is
  large because it checks the libs themselves (no `skipLibCheck`).
- The kernel half is real work, not noise: decode takes 518 of mitt's
  1,257 faults, 374 of them on fresh heap pages for the arrays it fills
  and 143 on the executable's read-only pages it reads the trees from.
  Rig's allocator also fills some memory ahead (`MADV_POPULATE_WRITE`),
  which costs kernel time and counts no fault, so the kernel column is
  a floor-to-middle estimate, not a count.
- Sampling makes each user figure good to about a tenth of itself; the
  instruction counts are exact. Times on a P-core are §1a, if a slot
  allowed them before this record landed.

## 2. What the decode does

By emitted line, inside decode in the `dec-new` build (empty mitt):

- **The large arrays, copied as they are, about 40%:** node records
  (24 bytes each, the largest), the u32 lists (`words`, `facts`, the
  binding's `node_symbol`, `node_flow`, `node_locals`), node lists.
  Already loops at memory speed; `extend_from_bytes` makes them one
  `memcpy` each.
- **Arrays read field by field, about 22%:** list records, text
  records, flows, flow lists, symbols, comment directives. Most could
  become records for `extend_from_bytes` (ListRec's `missing: Bool` and
  NodeRec's `kind: Kind` cannot today, §5 decision 4); symbols cannot be
  copied as they are, since each one's name is renamed into the
  program's names.
- **Work no layout removes, about 11% plus its allocation:** interning
  the lib's names into the program's (`Names.intern`, by hash),
  renaming symbols' names, rebuilding each symbol table and the u32
  Maps entry by entry. Trig's own lever, not a List's: names interned
  once per lib set, or tables kept by lib-local names.

So zero copy can reach the first two groups and the heap pages they
fill; the third stays in every design.

## 3. Options

### A. A copy-on-write List

A List's buffer may point into static bytes, marked (for example a
capacity of 0 with a length above 0), and copies itself before its
first write.

- **Desugars into:** nothing visible; the List is unchanged in type.
- **Core:** no ownership rule changes, but its cost model does: an
  element write (`v[i] = x`, `!v[i]`, a `for !x in !v` loop, a write
  slice, `sort`, `swap`, `remove`) may allocate and copy megabytes and
  may run out of memory, where today it never allocates. That is a
  hidden allocation ("No hidden cost") behind the plainest write Rig
  has, and its cost depends on where the List's buffer came from (CORE
  §10: rules follow the type, never where the value came from).
- **Cost to every List:** a test on every write path that is not
  proven, and a new fact for emit, "this `items()` is written", at the
  twenty-odd sites that take a List's items, plus every runtime method
  that writes through `mem()`. Zig gives LLVM no type-based aliasing,
  so a store to an element can change the List's header as far as it
  knows: the test reloads in a loop of element stores rather than
  hoisting. The json, hash, and text guards would pay it.
- **Soundness:** a write path that misses the test writes the
  read-only segment (a crash) or, with the bytes in writable data, the
  shared copy every later load reads (silent corruption). That is a
  class with as many members as there are write paths.
- **Trig:** fits unchanged. **Verdict:** no.

### B. A read-only record type over a `Static`

`Records[T]` (name for illustration): a `Static` and a record type `T`,
read by value.

- **Desugars into:** an object holding a `Static`; `r.len` is
  `s.len / $size(T)`, `r[i]` is `s.read[T](i * $size(T))`, a slice
  slices the bytes, `for` reads each.
- **Core:** none. An object whose only part is a `Static` is plain by
  §1's rule ("an object's kind follows from its parts"), so it copies,
  carries no loan, and goes in a `Cell` or a closure as a `Static` does.
  It needs one language step: `read[T]` of a record `T`, deciding
  "record" by the fact `extend_from_bytes` already uses
  (`sema.bytesRecord`). It could live in std.
- **Cost to every List:** none; it is another type.
- **Trig:** does not fit. Trig's `Ast` holds `List[NodeRec]` and its
  other arrays for parsed files and libs alike, and the checker reads
  them by node on its hottest path. Holding a lib's arrays as
  `Records` means a sum of the two and a branch on every node read, or
  a second copy of every accessor; on ts-pattern that branch would cost
  more than the whole decode (0.38%). **Verdict:** not for this; a
  candidate for std when a program reads tables it never stores in a
  List.

### C. A List whose pages the kernel copies (recommended)

`!xs.extend_from_bytes(s)` keeps its meaning, append the records the
bytes hold as a copy, and gains a second way to make that copy: when
`xs` is empty with no buffer, `s` lies in the executable's own
file-backed pages (an `$embed`, or a literal), the run is at least 64
KiB, and the record type's layout is its bytes (`recordFlat`), the
runtime maps those pages of the executable file privately and points
the List at them. The kernel shares the page-cache pages until a page
is written, then copies that one page for this mapping alone.

- **Desugars into:** exactly what it means today,
  `xs = List(); !xs.extend_from_bytes(s)`. No new form; how the copy is
  made is the runtime's, as how a List grows is.
- **Core:** none. The List owns its elements, which no other value
  sees: each call maps its own pages, so a second List of the same file
  and the `Static` itself never see this List's writes. It moves, lends,
  and drops as any List. In a paragraph, for SPEC and STD rather than
  CORE: *"A large run of embedded bytes may be mapped rather than copied
  into an empty List: the pages are read from the program's file when
  first touched and copied when first written, so a table the program
  only reads costs no copy and no memory it does not touch."*
- **Cost to every List:** reads, writes, `push`, and `pop` are the
  code they are now: the buffer is ordinary memory with a capacity of
  the mapped length. Growing past it copies to the heap and unmaps, as
  growth copies today. `freeSlice` and `reallocSlice` of a buffer of 64
  KiB or more look up a small table of mapped buffers (usually empty,
  a few dozen for Trig) before calling the allocator; smaller buffers
  pay one comparison they can fold into the size test the allocator
  makes. The guards would show it; none of their Lists is mapped.
- **The take itself:** an `open` of `/proc/self/exe`, one `mmap` per
  array, a `close`: a few microseconds, against the milliseconds the
  copy costs. The file offset is the address's, through the program
  headers of the running image (ELF keeps them equal modulo the page
  size), so no registry of embeds is needed. Any failure (no
  `/proc/self/exe`, a sandbox, an unaligned start) copies, so the result
  never differs.
- **Alignment:** `$embed`'s bytes are aligned to 1 today; a List of
  `T` needs `T`'s. Emit would place each embed at 16 bytes. Measured on
  the Mac with an 8 MB file: an aligned `[n]u8 = @embedFile(p).*` costs
  1.5 s more to build and 430 MB more memory than the embed alone, so
  Trig's 13.5 MB would cost about 2.5 s and 730 MB; an assembler
  `.incbin` after `.balign 16` should cost nothing, to be measured.
- **Risks the ceiling must measure:** the mapped pages are 4 KiB file
  pages, where the heap may give the large arrays 2 MiB pages, so a
  checker that reads lib nodes all over `lib.dom.d.ts` may take more
  TLB misses (the scaling record found Trig's page walks at 4.1% of
  user cycles on ts-pattern already); and file-backed pages count in
  RSS while touched, though fewer heap pages should more than pay that.
- **Where:** Linux first, where Trig is timed. macOS copies until a
  Mach-O mapping is measured. Debug and sanitized builds copy, so the
  leak checker and `RIG_SANITIZE` see heap buffers; `release: true`
  cases test the mapped path.
- **Size:** runtime only, about 150 lines (program headers, the map,
  the table, free and grow routing), and emit's alignment of embeds;
  it can be cut out in one step, as `src/bolt.zig` can.
- **Trig:** fits unchanged once its generator writes binary files and
  its reader uses `$embed` and `extend_from_bytes`, which it plans
  anyway. Its FLIP encoding goes (a binary file has no escapes).

## 4. What decides it: a Zig ceiling first

The owner's rule for speed work is the fastest Zig first, then Rig made
to emit it. Before any Rig code:

1. Trig adopts `$embed` and `extend_from_bytes` for its lib trees (its
   own row). That is the base the ceiling is measured against, so the
   gain is zero copy's alone.
2. A hand edit of that build's emitted Zig, as `decode-zig` was: each
   array of 64 KiB or more mapped from `/proc/self/exe` with
   `MAP_PRIVATE`, the List pointed at it, its free skipped.
3. Timed on a pup P-core in a slot, 20 interleaved rounds, the six
   projects: user and kernel cycles, faults, dTLB misses, peak RSS.

It lands if it is more than 1.5% faster on the projects it targets
(mitt, neverthrow, tiny-invariant by the estimate) and no slower than
2% on zod3 and ts-pattern, where the TLB risk lives. Otherwise it is
recorded and dropped.

## 5. Decisions for the owner

1. **Direction:** zero copy as a second way `extend_from_bytes` makes
   its copy (C), with no new type or name and no CORE change; not a
   copy-on-write List (A), and `Records[T]` (B) not now. *Default: yes.*
2. **Gate:** build only after the Zig ceiling of §4 clears the bar on
   pup. *Default: yes.*
3. **Order:** Trig adopts `$embed` and `extend_from_bytes` first, and
   the ceiling is measured on top. *Default: yes.*
4. **Records with an enum or a `Bool`:** NodeRec's `kind` and
   `keyword` and ListRec's `missing` are not records today. (a) Trig
   stores numbers and converts at each read, a cost on the checker's
   hottest path; (b) `extend_from_bytes` admits them and checks each
   value, a pass that reads every page and so gives up the lazy pages;
   (c) admit them, and check an embedded file's values when the program
   is built (the build reads each file once already), a run-time `?String`
   checking as it copies. *Default: (c).* This is a rule of
   `extend_from_bytes`, so it is decided apart from zero copy.
5. **Where it maps:** Linux release builds; macOS, debug, and sanitized
   builds copy. *Default: yes.*
6. **Alignment of embeds:** every `$embed` held at 16 bytes, by an
   assembler `.incbin` if it measures free, else by an aligned constant
   (2.5 s and 730 MB more for Trig's build). *Default: `.incbin`.*

If the owner prefers an explicit form to an implicit second path, the
name is his; candidates, each a declaration, an error, and a sentence:

- `List(embed: "libs/dom.recs")`, as `List(capacity: n)` reads:
  `recs: List[NodeRec] = List(embed: "libs/dom.recs")`;
  "`List(embed:)`: \"libs/dom.recs\" is 1000 bytes, not a whole number
  of 24-byte `NodeRec`s"; "`List(embed: path)` makes a List of a file's
  records, read when they are first touched and copied where written."
- `List.mapped($embed("libs/dom.recs"))`;
  "`List.mapped`: `NodeRec` holds a `Bool`, which is only 0 or 1";
  "`List.mapped(s)` makes a List of the records in `s` without copying
  them."
- `!recs.extend_from_bytes(s)` alone (the default: no name at all).
