# Hash race panel: what Rig's compiler must gain (2026-10-27)

The compiler member of the three-person panel. The owner's plan: build
the two winning maps first as hand-written Zig (an insertion-ordered
`Map`, an unordered `HashMap`), then teach Rig to emit that Zig from
`std/__rig_builtin.rig` and a std module. This report is the second
half: where today's emitted Zig differs from a hand-written map, what
each technique needs, and a work order.

Everything below was read from the worktree `hash-bench-2` at
`20584636c`, or built there: `bin/rig emit bench/hash/map.rig`, and two
probes built with `rig build --release=fast` under `tools/low` and
disassembled for arm64 (Apple M-series). No benchmark was run. Numbers
about speed are the panel's Mac reading
(`mac-v2-one-round-podium.txt`), random keys (`rnd`), ns per operation.

## 0. Two corrections to the design study

The study's §4.3 lists seven needs. Two are partly built already:

- **A branch hint inside a function exists.** `rarely`, alone as the
  first line of a branch of `if` or `match`, a `catch` handler, or a
  loop's body, marks that block cold (SPEC "Rarely", SYNTAX:749). Emit
  writes `rig.cold()`, which is `@branchHint(.cold)` inlined into the
  branch (`src/emit.zig:2616`, `src/runtime.zig:3989`). Confirmed: a
  `rarely` inside a `while m != 0` body emits `rig.cold();` as its first
  statement. What is missing is only a weaker hint (`.unlikely`), for a
  branch taken a few percent of the time, where `.cold` can move the
  block too far away.
- **Owning entries already have a niche.** An optional of an object the
  emitter writes takes its `none` from a field's niche (`rig.Opt`,
  `src/runtime.zig:618`), and a String's buffer pointer is one. Measured
  with `$size`: `B[String, Int]` is 40 bytes and `B[String, Int]?` is
  40; `B[Int, Int]` is 16 and `B[Int, Int]?` is 24. So `Bucket[K, V]?`
  and `Entry[K, V]?` cost nothing for any owning key or value (String,
  List, box, handle: each holds a pointer). Only plain entries pay for
  `?`, and they need no `?`: a tag byte or a bitset says what is free.

## 1. Where the emitted Zig differs from a hand-written map

### 1.1 The hit path, as emitted

`Map.find`'s table probe (`__rig_std___rig_builtin.zig:486-503`):

```zig
const ts = rig.slice(self.table.tags.items(), 0, null);
...
while (true) {
    if (!((0 <= i) and (i < rig.lenOf(ts)))) break;
    {
        const t: u8 = rig.atProven(ts, i, .both);      // proven by the loop guard
        if (t == 0) return null;
        if (t == tag) {
            const j: i64 = @as(i64, @intCast(@as(u32, self.table.at.at(i))));   // tested
            if (rig.eql(self.es.constSlot(j).*.key, rig.viewed(K, k))) return j; // tested
        }
        i = rig.addProven(i, 1);
    }
}
```

and `get` on top of it (`:120-127`):

```zig
if (self.find(k, rig.hash(rig.viewed(K, k)))) |j| {
    return (if (rig.somePtr(&(self.es.constSlot(j).*.value))) |p| rig.lend(p) else null);
}
```

What `Map[Int, Int].get` in a loop becomes on arm64, per tag that
matches (`called fun hits`, `--release=fast`):

```
ldrb  w3, [x12, x4]        ; tags[i]
cbz   w3, miss             ; free slot ends the probe
cmp   w3, w2 ; b.ne next   ; tag compare
ldr   x3, [x8, #0x60]      ; at.len, reloaded from the Map
cmp   x4, x3 ; b.hs panic  ; at[i] bounds test
ldr   x3, [x8, #0x50]      ; at.ptr, reloaded
ldr   w3, [x3, x4, lsl #2] ; at[i]          (second dependent load)
ldr   x5, [x8, #0x18]      ; es.len, reloaded
cmp   x5, x3 ; b.ls panic  ; es[j] bounds test
ldr   x5, [x8, #0x8]       ; es.ptr, reloaded
umull x6, w3, w16          ; j * 24         (a 24-byte Entry)
ldr   x6, [x5, x6]         ; es[j].key      (third dependent load)
cmp   x6, x17 ; b.ne next
...
ldrb  w2, [x17, #0x10]     ; the V? flag of es[j].value
tbz   w2, #0, miss         ; the V? test
ldr   x17, [x17, #0x8]     ; the value
```

The probe loop is also emitted twice (the `for _ in 0..2` wrap), and a
step that does not match is a byte load, two compares and two branches.
Against a hand-written map, the differences are:

1. **Scalar byte probing.** One tag per step, a branch per tag that
   mispredicts at random, and a miss runs to a free byte in a table 40%
   to 80% full. A hand-written map compares 16 tags at once. This is the
   largest cost: a miss at 100k keys takes 9.89 ns against ankerl's 1.83
   (5.4 times as long); a String miss at 100k 69.65 against 5.12 (13.6
   times), since each of the 1-in-128 false tag matches compares a
   String, a load from another line.
2. **Three dependent Lists.** `tags[i]`, then `at[i]`, then `es[j]`,
   each its own allocation: three waits on memory where a flat map has
   one and ankerl's merged block two. A hit at 100k keys is 5.66 ns
   against hashbrown's 1.68 (3.4 times).
3. **List headers reloaded from the Map.** `len` and `ptr` of `at` and
   `es` are loaded again on every candidate, because they are reached
   through `self` and the loads sit behind a branch, where LLVM does not
   hoist them. Hand-written Zig takes `self.x.items` into a local once.
   Rig can say this today: `es = ?@es[..]` at the top of `find`, as its
   small path already does.
4. **Two bounds tests a candidate.** `at[i]` (the slot from the linear
   probe is not tied to `at.len`) and `es[j]` (an index read from
   memory). Both are predicted compares beside the load they guard.
5. **The `V?` test on a hit.** The index never names a taken entry
   (`take` unlinks its slot), so the test always passes, but the
   compiler cannot know it. It also makes the entry 24 bytes, so `j * 24`
   is a multiply where 16 would fold into the address.
6. **Insert probes twice.** `replace` calls `find`, misses, and then
   `insert` calls `table.place`, whose `free_slot` scans again from the
   home slot. A hand-written map keeps the free slot the miss stopped at.

What is not a difference: the ownership machinery. `rig.rt`,
`__rig_alive_*` flags, `rig.take`, `rig.keep`, and the `defer` drops of
`Int` temporaries leave no instruction in the disassembly. `List.push`
is inlined, with only its `grow` out of line. The Int hash is the folded
multiply a hand-written map would use (`mul`, `eor`, `mul`, `umulh`,
`eor`).

### 1.2 Iteration

`Items.next` (`:985-1000`) reads `@map.es[j]` twice through
`constSlot` and tests the value's `?`. On arm64 each element of
`for e in ?m.items()` is 18 instructions, scalar: the loop test, a
redundant bounds test (`cmp x9, x10; b.hs panic`, the field
`next_at` carries no proof to `j`), a reload of `es.ptr`, the `V?`
byte and its branch, then the add. indexmap walks 1k entries at
0.08 ns each, vectorized; the Map takes 0.47 (5.9 times). Writing
`j = @next_at` first and testing `j < es.len` lets the proof pass take
the bounds test; dropping `V?` for plain entries removes the branch; both
are needed before LLVM can vectorize the walk.

### 1.3 A group probe in Rig today

A toy probe written as std.hash wrote one, with `ctrl.read[Group](pos)`,
`(g == tag).bits()`, and `at[(pos +% m.trailing_zeros()) & mask]`:

```zig
const pos: i64 = @as(i64, @bitCast(@as(u64, h))) & mask;
const g = rig.simdRead(@Vector(16, u8), ctrl, pos, rig.Endian.little);  // tested
var m: u64 = rig.maskBits(rig.mask(g == rig.rt(@as(@Vector(16, u8), @splat(tag)))));
while (true) : ({ m &= m - 1; }) {
    if (!(m != 0)) break;
    const i: i64 = (@as(i64, pos) +% @as(i64, @ctz(@as(u64, m)))) & mask;
    const j: i64 = @as(i64, @intCast(@as(u32, rig.at(at, i))));           // tested
    if (self.keys.atProven(j, .lower) == k) return j;                      // upper tested
}
```

Its arm64 code: the group read keeps `sub; cmp #0xf; b.ls bytesPanic`;
`bits()` of 16 lanes is `and` with a constant, `ext`, `zip1`, `addv.8h`,
`fmov`, `and #0xffff`, and a constant-pool load (simd-lowering.md §3);
LLVM removed the `at[i]` test itself here, because `at` was a local
slice and `mask` its `len - 1`, but kept the `keys[j]` test. The nibble
form (`cmeq`, `shrn`, `fmov`) is reached only through `m.first()`
(`src/runtime.zig:4697`), which finds one lane, not each.

## 2. Each technique, and its status

(i) expressible and safe today; (ii) safe once a proof, type, or std
primitive is added; (iii) `raw` only.

| Technique | Status | What is needed, and where |
|---|---|---|
| Group scan by compare and movemask, per target | **(ii)** | `m.lanes()`: the true lanes of a mask, in order, as `Int`s. A runtime iterator (`rig.MaskLanes`) whose bits are the target's cheapest form: `pmovmskb` on x86 and WASM's `i8x16.bitmask` (stride 1); on NEON for 16 lanes the nibble mask `& 0x1111_1111_1111_1111` (stride 4: `cmeq`, `shrn`, `fmov`), lane `= ctz >> 2`, step `bits &= bits - 1`. Sema: a member of `Simd[Bool, n]` beside `first` (typecheck's Simd member table); emit: one call; runtime: beside `maskFirst`. Plain values only: no ownership rule. A proof fact gives the loop's `k` the range `0 <= k < n`, so `[n]T` indexed by it needs no test (§2.1). |
| Prefetch | **(ii)** | `xs.prefetch(i)` on a List and a slice: Zig's `@prefetch` of element `i` when `0 <= i < xs.len`, nothing otherwise, never a panic, so it means nothing and cannot touch memory outside the List. A `?@` method: the read view lasts the call, no loan after. Its range test is an index test the proof pass records like any other, so a masked `i` makes it free. Sema member table, emit, `rig.prefetch` in the runtime. |
| Branch hints inside a function | **(i)**, with a gap | `rarely` in a branch is built (`.cold`). The gap is a weaker hint: `.unlikely` for a branch that runs a few percent of the time (the candidate whose key differs, the walk past the home group). Either `rarely` in a branch lowers to `.unlikely` and stays `.cold` as a function's first line, or a second word (naming question 3). One line in emit; measure first. |
| Masked power-of-two index | **(ii)** | Two facts in `src/proofs.zig`, both on its positive list: (a) `n = s.len -% 1` (or `- 1`) makes `below(n, 1, len(s))`, which holds even for an empty `s` (`-1 + 1 <= 0`); (b) an index or offset written `e & m`, with `nonneg(m)` and `below(m, k, b)` at the unit's entry, is `0 <= e & m` and `(e & m) + k <= b`, proved at the site. Sound for any `m >= 0`: no power of two is needed for safety, only for the hash's spread. Because the shape is proved where it is written, it holds inside a probe loop that rewrites `pos`, with no loop guard: `mask` is not written in the loop, so its facts survive the join. High-bit positions (`h >> shift`) stay unproved; write `Int.wrap(h >> 32) & mask`. |
| Padded control bytes for unaligned group reads | **(i)**, proved by the row above | A `List[U8]` of `n + 16` bytes and `ctrl.read[Group](pos & mask)`, one unaligned load on every target (simd-lowering.md §1). The read's test goes once `mask + 16 <= ctrl.len` is a fact (one guard a call) and the masked shape is proved. For the ordered design, a `Block` object with `fp: [16]U8` read by `b.fp.read[Group](0)` works today (built and run: `Block` is 88 bytes), and its test is against a constant 16, which LLVM folds. |
| Slot or entry indexes typed so no test is needed | slot **(ii)**, entry **(iii)** | A slot index is a masked hash: the row above. An entry index is data read from memory (`idx[k]`), whose bound is an invariant of the Map's own code (every index below `es.len`), which no type Rig has can carry: `Slot[n]` needs a compile-time `n` and a table that never shrinks. Dropping that test would need a new `raw` builtin (none exists; `raw` today allows only casts, SPEC §15). Recommended: keep the test. It is a predicted compare off the critical path, and archive/span-type and archive/proof-edges measured such tests as noise on Trig. The Zig prototype should measure it (§3, step 0). |
| Niche or plain-slot layout for owning keys | **(i)** | Owning: `Bucket[K, V]?` and `Entry[K, V]?` take the niche (§0). Plain: a free slot holds a copy (`List.filled(n, filler)`, as #685 did), and the tag says what is free. Two gaps: a List of `n` nones of an owning optional cannot be made at once (`List.filled(n, none)` is rejected: "a `String?` owns a resource, so it cannot be copied"), so a table of owning slots is made by a loop of pushes; and a generic object cannot pick a field's type by `$plain`, so a Map that is plain in one instance and owning in another holds both Lists, one always empty (std.hash's `ps` and `slots`, 24 bytes of empty header a Map). Both are owner decisions (§4). |
| Zeroed or huge-page allocation | **(ii)**, runtime only | `List.filled(n, x)` allocates and `@memset`s (`src/runtime.zig:3148`). When `x`'s bytes are all zero, a block fresh from `mmap` is already zero: `allocZeroed` in `src/alloc.zig` skips the store for a fresh large block and `memset`s a reused one. Huge pages: `madvise(MADV_HUGEPAGE)` for large blocks on Linux, also in `alloc.zig`. No language change; `Table[T, n]` already reserves zero pages, the precedent. archive/table-prefault was not taken on Trig (peak memory higher), so huge pages go to the owner. |
| A stored hash beside entries | **(i)** | Today a parallel `List[U64]` (`hs`), kept for keys over 8 bytes; a `hash` field in `Entry` chosen the same way works as well. One gap is in the code, not the compiler: a table probe compares the key on a tag match without first comparing the stored hash, which a String miss pays (§1.1). |

### 2.1 What CORE says about each

None of the (ii) items changes an ownership rule:

- `m.lanes()`, `prefetch`, the proof facts, zeroed blocks, and huge
  pages touch no value's ownership. The proofs rest on the Core as the
  pass already does (a binding changes only where an assignment or a `!`
  says so).
- `prefetch` is an ordinary `?@` call; effects stay visible because it
  has none a program can observe.
- Making `n` nones of an owning optional desugars to `n` pushes of
  `none`, each owning nothing. As a new member it fits CORE §5 as
  written. As `List.filled(n, none)` it is an exception to "the element
  must copy" keyed to the literal, which CORE §10 ("its rules follow the
  value's type, never where the value came from") argues against unless
  `none` is given a type of its own that copies, as a text literal is a
  `Static`. Either way it goes to the owner as a one-paragraph check.

Two candidates were considered and set aside, because each would change
an ownership rule: a "slot the tag says is free" that holds no value
(a place with nothing in it), and an unchecked index outside `raw`. The
niche makes the first unnecessary; the second breaks North Star 2.

## 3. Work order

Smallest first. Each step lands alone, with its test, and is measured
on bench/hash against the Zig prototype, interleaved, fastest of N, Mac
and pup.

0. **Rig-shaped Zig, before any compiler work.** Ask the prototype
   builders for one variant of each Zig map with Rig's retained tests
   put back by hand: a bounds test on every entry index, a range test
   on every prefetch, and (for the owning-key variant) the `?` test on
   each slot. The gap between it and the prototype is what proofs or
   `raw` could ever buy. If it is under 2% on every row, the entry-index
   test stays and step 2's scope shrinks. Test: the bench rows.
1. **`.unlikely` for `rarely` in a branch** (`src/emit.zig:2616`,
   `rig.unlikely` in the runtime). Test: a `code` case that a branch
   starting with `rarely` emits `@branchHint(.unlikely)`, and one that a
   function's emits `.cold`; Trig light gate, since every `rarely`
   branch in std and Trig changes. Land only if the probe or Trig shows
   it; otherwise drop.
2. **The masked-index proof** (`src/proofs.zig`: the `s.len -% 1` fact
   and the `e & m` shape). Tests in the proofs area: `code` cases that
   `ts[(h +% d) & mask]` emits `atProven(..., .both)` and
   `ctrl.read[Group](pos & mask)` emits `simdReadProven` under
   `mask + 16 <= ctrl.len`, inside a loop that rewrites `pos`; a `bomb`
   case that a mask taken from a different List keeps its test and
   panics; `swarm test/rig.rip proofs`; a debug run, which asserts every
   proof.
3. **`xs.prefetch(i)`** on List and slice. Tests: a `test` case that an
   out-of-range `i`, negative and past `len`, does nothing and exits
   clean; a `code` case for `@prefetch`; a `code` case that a masked `i`
   emits no range test (uses step 2); a doc example in SPEC §10 (List).
4. **`m.lanes()`** with the lane-range fact. Tests: `test` cases giving
   the true lanes of 8-, 16-, 32-, and 64-lane masks, including none and
   all; a `code` case for the runtime call; the instruction counts on
   arm64 (`cmeq`, `shrn`, `fmov`, then `rbit`/`clz`) and x86-64 v1 and
   v3 (`pcmpeqb`, `pmovmskb`, `tzcnt`) added to simd-lowering.md from
   the docs/history/simd-zig harness; a `code` case that `idx[k]` for
   `idx: [16]U32` and `k` from a 16-lane mask's `lanes()` is proven.
5. **Owning slots made at once, and zeroed blocks.** The member chosen
   in §4 (default `List.filled(n, none)`), and `allocZeroed` in
   `src/alloc.zig` for a fill whose bytes are zero. Tests: a `test` case
   making `List[String?]` of 4 nones and dropping it clean under
   `RIG_SANITIZE=1`; a `fail` case for an owning non-optional fill; a
   `zig build test` unit test that a fresh large block skips the
   `memset`; std.json's guard (std.json fills Lists).
6. **The ordered Map, rewritten in Rig** (design study §4.1) on steps 2
   to 5, changing only `std/__rig_builtin.rig`: `Block` objects
   (`fp: [16]U8`, `ofw: [8]U8`, `idx: [16]U32`) in one List; plain
   entries with a `gone` bitset and owning entries as `Entry?`; slices
   taken once at the top of each hot method; `find` handing back the
   free slot it stopped at; `Items.next` testing a local `j`. Tests: the
   Map and Set areas, doc examples, the oracle's coverage, a `code` case
   that `Map[Int, Int].get` emits no `rig.somePtr`, Trig's light gate,
   loco's, std.json's guard; then bench/hash against the prototype, row
   by row.
7. **The unordered map** in its std module (study §4.2), on the same
   primitives, from #685's members and tests.
8. **Huge pages**, if the owner agrees: Linux, large blocks, measured on
   Trig's peak memory and bench/hash 4M rows.
9. **Only if step 6 measures it:** a field type chosen by `$plain`, in
   place of the two-List layout.

Within 2% of the prototype is reachable on every row only if step 0
says the retained tests cost under 2%. Two things the emitted Zig will
still do that hand-written Zig need not: test each entry index read from
the index, and (owning maps) test each slot's niche word. Both are
predicted compares on a line already loaded.

## 4. Naming and design questions for the owner

Each with candidates and a default; the default is first.

1. **The true lanes of a mask.**
   - `for k in m.lanes()`: "a mask's true lanes"; error: "`lanes` takes
     a mask, `Simd[Bool, n]`; got `Simd[U8, 16]`".
   - `for k in m.indexes()`.
   - `for k in m.ones()`.
   Default `lanes`, the word SPEC already uses for a vector's parts.
2. **Prefetch.**
   - `xs.prefetch(i)`: "fetch element `i` into the cache ahead of its
     read; nothing when `i` is out of range".
   - `xs.warm(i)`.
   - `xs.prefetch(i, write: true)` beside the first, for the rehash's
     stores.
   Default `xs.prefetch(i)` alone, read intent; the write form only if
   the prototype's rehash measures it.
3. **A weaker branch hint.**
   - `rarely` alone, `.unlikely` in a branch and `.cold` as a function's
     first line.
   - `rarely` stays `.cold` everywhere, nothing added.
   - `rarely` (`.unlikely`) and `cold` (`.cold`), two words.
   Default the first: one word, its strength following where it stands.
4. **`n` nones of an owning optional.**
   - `List.filled(n, none)`: reads plainly; needs `none` treated as a
     value that copies (CORE §10 check).
   - `List[T?].nones(n)`.
   - `List[T?](size: n)`.
   Default `List.filled(n, none)`, with the CORE paragraph written first.
5. **Plain and owning layouts in one generic object.** Default: two
   Lists, one always empty, as std.hash had; build a field type chosen by
   `$plain` only if step 6 measures the 24 bytes or the duplicated code.
6. **The entry-index test.** Default: keep it, safe in every mode; a
   `raw` unchecked index only if step 0 shows it over 2% and the owner
   wants that trade.
7. **Which bar a map-only compiler feature clears.** The speed bar is
   Trig's, and Trig did not move for archive/span-type or
   archive/proof-edges. Default: bench/hash rows against the prototype,
   with no Trig or std.json regression, since first place is the goal.
