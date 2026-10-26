# Table and List reads inside Trig (2026-10-25)

**Question.** Trig (fork)'s gap breakdown (ts-pattern, one thread, Trig
676760a on Rig 6c3f35b78) charged Rig's inlined helpers with 405M cycles
of `Table` reads, about 130M of `List.at`/`slot`, 109M of bounds and
overflow tests and 31M of casts, out of Trig's 4.88G. Why does a read
cost that, and what can Rig take out?

**Answer.** A `Table` read is already the bare load. A `List` read adds
only a sign test where the index is signed. The cycles charged to those
lines are the element loads' cache misses, which tsrs pays as well,
inside its own functions. Two real costs sat beside the reads:

- every `?T` result of an inlined call made a stack round trip through
  `rig.rt` whose load could not be forwarded (an *optional unwrap*);
- the sign test.

Taking out both, and keeping `rarely` functions out of line as SPEC
says, gives Trig 1.5% fewer instructions and 1.2-2.2% fewer cycles on
ts-pattern, with the same output on all six projects.

## 1. What a read executes (pup, x86-64, Trig built `--release`)

Measured with merged `perf record` runs (pup caps samples at 1000/s, so
25 runs of about 1.2K each), mapped by `addr2line -i` to the innermost
inlined line, and checked against the disassembly. Scripts:
`/zfs/trig-pup/trial/tr/` on pup (`prof.sh`, `profd.sh`, `an*.py`,
`ctx.py`, `ab.sh`, `build.sh`).

**`t[s]`, `Table[T, n]` read with a `Slot[n]`** (`table.zig` `at`,
`constSlot`), for example `type_flags(t)`:

```
mov  0x140(%rdi),%rax        ; the table's `slots` from the Store, inside Checker
shl  $5,%rbx                 ; s * @sizeOf(Type)
movzwl 0x2(%rax,%rbx),%ecx   ; the field
```

Per read, on average: 1 field load, 0.37 loads of `slots` (LLVM reuses
it between reads with no store between), and 0.28 address computations.

What a read does **not** do:

- no index or generation test (the slot type proves it);
- no header, then chunks, then slot: the slots are one mapping, and
  `slots` sits in the `Store` inline in `Checker`;
- no optional unwrap;
- no copy of the element: LLVM narrows `at(s).field` to the field's
  load, and no `vmovups`/`memcpy` sits on a read path;
- no yield;
- no cast.

The `slots` load almost never misses: it is 0.5% of L1 misses, against
15.9% for the element loads. tsrs reads through arena pointers
(`P<Type>`), one load; a `Vec` read would add a length load and a test.

**`v[i]`, `List[T]` with an `Int` index** (`ListOf.at`, `indexOf`):

```
test %r15,%r15 ; js  panic   ; i >= 0  (std.math.cast in rt.index)
cmp  0x60(%rsi),%r15 ; jae panic   ; i < len
mov  0x50(%rsi),%r8          ; buf.ptr
mov  (%r8,%r15,4),%r8d       ; the element
```

The bounds test is 2.6% of instructions. The sign test is about 0.5%,
only where LLVM cannot prove `i >= 0`; Rust's `usize` index has no sign
test. An index built as `Int(list.start) + k` also has an overflow test
(`jo`, 0.3% of all instructions), which Rig specifies.

**Where the cycles are.** The lines charged to `table.zig` take 9.1% of
cycles and 8.4% of instructions: no more stalled than the average
instruction. The cycles that land on a test (`cmp` after a load) are
skid from the load before it. By L1 misses (`mem_load_retired.l1_miss`):

| reads | share of L1 misses |
|---|---:|
| `List(u32)` reads (about 7 points in `Map` probes' index tables) | 12.5% |
| `Type` | 4.2% |
| `List(ast.NodeRec)` | 3.6% |
| `List(Loc)`, `TypeMapper`, `ValueSymbolLinks` | 2.4%, 1.8%, 1.8% |
| per-kind type tables (`StructuredType`, `ConditionalType`, ...) | about 5% |

That is data latency, a matter of layout. tsrs keeps a type's data
right after its 24-byte header in one allocation. Trig keeps the header
in `types` and the data in a per-kind table reached through
`types[t].data`: a dependent second load, on another cache line. That
lever is Trig's.

Whole run, ts-pattern, core 8 (`perf stat`):

| | Trig | tsrs shipped |
|---|---:|---:|
| L1 load misses | 38.9M | 32.0M |
| L2 load misses | 3.1M | 2.9M |
| L3 load misses | 0.89M | 0.53M |
| dTLB walks (cycles) | 1.73M (99.5M) | 0.66M (34.9M) |
| loads blocked by store forwarding | **18.6M** | **5.6M** |

Huge pages were measured before and not taken
([consolidation-2/hugepages.md](../consolidation-2/hugepages.md)).

## 2. The class found: optionals through `rig.rt`

Every call that may reach an inlined function is emitted
`rig.rt(f(x))`, so that Zig cannot fold its result at compile time
(INTERNALS, "Inlining"). `rig.rt` is a function, and Zig passes an
optional to a function through memory.

An inlined `Map.get` gives `?u32` either as a copy written field by
field (a 4-byte payload store, then a 1-byte flag store) or as Zig's
constant `null`. LLVM merges the two into a load of a selected pointer,
and that 8-byte load cannot be forwarded from the two narrower stores.
`rig.copiedOut` (`m.get(k) ?? 0`), also a function, made a second round
trip. `table_get`, as built on main:

```
mov  %ecx,-0x4c(%rbp)        ; payload
movb $0x1,-0x48(%rbp)        ; flag
lea  -0x4c(%rbp),%rdx        ; or $0x114a020, the constant null
mov  (%rdx),%rdx             ; blocked: waits for both stores
bt   $0x20,%rdx
... the same again for copiedOut
```

A Zig reproduction (an inlined `get`, `rt`, `copiedOut`, `orelse`)
showed one round trip per non-inline helper that takes the optional, and
none when there is no such helper.

**Fix 1: an inline `rig.rt` (taken back).** `rig.rt` inline, through a
`var`. On Trig it gave 0.7% fewer instructions and 36% fewer blocked
loads, but Trig's debug build took 526 s against 122 s, with 31K
`rig.rt` sites.

**Fix 2 (kept): the emitter makes such a result a run-time value in
place.** In `emitCallDirect`, an optional or fallible result becomes
`(__rig_rt_N: { var __rig_v_N = f(x); _ = &__rig_v_N; break :__rig_rt_N
__rig_v_N; })`. A `var` is a run-time value, as `rig.rt`'s result is, so
the purpose holds. `rig.copiedOut` is `inline`. Trig's debug build took
118 s against 122 s. Its release build on pup took 6 min 44 s against
7 min 4 s.

## 3. The sign test folded into the bounds test

`heldIndex(i, count)`: for a signed `i` of at most 64 bits, `@as(u64,
@bitCast(i)) >= count` is exactly `i < 0 or i >= count` whenever `count
< 2^63`. A held length is at most `max_len = 2^62 - 1`: `allocSlice`
and `reallocSlice` refuse more, a zero-bit List stops there
(`ListOf.grow`), and no target addresses `2^62` bytes. This is the
existing `heldLen` fact, asserted in debug builds. It is used by:

- `ListOf.indexOf` (`at`, `slot`, `constSlot`);
- `ListOf.get`;
- `rig.at` and `rig.elemPtr` for slices of elements of at least a byte
  (`lenHeld`).

The panic is the same. Arrays, and tables, whose `n` is a constant LLVM
folds already, are unchanged.

## 4. `rarely` is `noinline`

After fix 3, a `rarely` function's body (`Int(s[i]) + 1` in
`test/cli/markers.sh`'s parser) was small enough for LLVM to inline it,
in spite of the `cold` attribute. SPEC says such a function "stays out
of line, as `called` keeps it". Emit now writes it `noinline fn`, as it
writes a `called` one. `tools/markers.py` and the tests it writes say
so.

## Numbers

Trig 676760a (src and tools/trig/main.rig, from
`/zfs/trig-pup/trial/ab/main`), built `rig build --release` with each
Rig on pup's release slots. Every run used `--singleThreaded`, core 8
(sibling 9 idle), and ran interleaved: fastest of 10 for task-clock,
user cycles and user instructions, the median for blocked loads (`sf`,
`ld_blocks.store_forward`) and faults. Other agents' builds were running
on the slots' cores, so task-clock moves between rounds; instructions do
not. Every arm prints byte-identical output on all six projects.

| arm | Rig | what |
|---|---|---|
| base | a06053e58 | main |
| a | 94b018d7c | inline `rt` and `copiedOut` (fix 1) |
| b | 22bf02111 | a + `heldIndex` |
| c | bdf86715a | fix 2 in place of fix 1, + `heldIndex` |
| d | 980dbdc05 | c + `rarely` `noinline`: the PR |

ts-pattern, three rounds:

| round | arm | task-clock ms | cycles | instructions | sf | faults |
|---|---|---:|---:|---:|---:|---:|
| 1 | base | 1167.8 | 4.6541G | 10.5443G | 18.71M | 42,681 |
| 1 | a | 1166.0 | 4.6327G | 10.4689G | 12.03M | 42,679 |
| 2 | base | 1211.6 | 4.7883G | 10.5406G | 18.71M | 42,681 |
| 2 | b | 1183.7 | 4.7016G | 10.3871G | 12.32M | 42,679 |
| 2 | c | 1180.5 | 4.6873G | 10.3821G | 12.33M | 42,679 |
| 3 | base | 1188.9 | 4.6998G | 10.5444G | 18.75M | 42,681 |
| 3 | c | 1167.4 | 4.5955G | 10.3855G | 12.32M | 42,679 |
| 3 | d | 1165.0 | 4.6417G | 10.3821G | 12.30M | 42,679 |

So, against main:

- fix 1 alone: 0.7% fewer instructions;
- `heldIndex` alone: 0.8% fewer (b against a);
- the PR (d): 1.54% fewer instructions, 1.2% fewer cycles and 2.0%
  faster by task-clock in round 3 (c: 2.2% fewer cycles, 1.8% faster);
- blocked loads: 34% fewer.

The other projects, base against d:

| project | task-clock ms | cycles | instructions | sf |
|---|---|---|---|---|
| zod3 (10 runs) | 221.7 / 221.0 | 0.8261G / 0.8232G | 1.9118G / 1.8833G (1.49% fewer) | 3.15M / 2.02M |
| mitt (5) | 29.5 / 29.4 | 0.0943G / 0.0922G | 0.2493G / 0.2434G | 0.08M / 0.07M |
| neverthrow (5) | 33.9 / 33.9 | 0.1050G / 0.1063G | 0.2623G / 0.2601G | 0.12M / 0.09M |
| superstruct (5) | 41.3 / 41.0 | 0.1385G / 0.1372G | 0.3053G / 0.2990G | 0.36M / 0.26M |
| tiny-invariant (5) | 107.0 / 99.9 | 0.3704G / 0.3614G | 1.0460G / 1.0212G | 1.48M / 0.53M |

## What is left, and whose it is

- **Loads blocked by store forwarding: 12.3M against tsrs's 5.6M.**
  About a quarter of what remains is in `Map.find`, where a key built on
  the stack is reloaded whole while the probe runs. That code belongs to
  the Map/Set stage, and this PR leaves it alone. Some is `memcpy` in
  List growth. The rest is non-inline runtime helpers that take a small
  aggregate by value (`rig.take`, `rig.eql` on optionals), not chased
  here.
- **Data layout is Trig's:**
  - a type's data sits one dependent load from its header, in another
    table;
  - `StructuredType` is 44 bytes, so some records straddle two cache
    lines.
- **`slots` reloads after stores**, 1.4% of instructions, are L1 hits.
  Zig emits no type-based alias information that would let LLVM keep
  them in registers.
