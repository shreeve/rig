# A lent String's header, and the store-forwarding stall of #780 (2026-10-31)

**Question.** Queue row 28. After #780 (424e3dc70, String and List appends
grow by value), coreutils' `basenc --base16` encode took 257 ms of user time
on the Mac where 234111d61 took 134. Rig - Rust (fork)'s bisect named the
cause: in `bits_encode`'s pair-table loop, which appends to a lent
`out: !String`, each iteration loads the String's length and capacity with
one 16-byte `ldp`, right after the previous iteration's 8-byte store of the
length, and Apple cores do not forward that store to the wider load. On
pup's x86 the same commit made the loop 12% faster, since x86 reloads the
length alone. The method is the owner's: the Zig ceiling first. Two arms
were asked for: (a) the lent header passed as a `noalias` pointer, so LLVM
may keep it in registers; (b) the header held in a local around the loop
and written back after it; and, as a comparison, a narrower fix inside
#780's runtime code.

**Answer.** (b) wins and (a) does nothing. With the header held in a local,
the loop keeps the length, capacity and pointer in registers and stores
nothing but the bytes: 83 ms of user time against main's 218 and the
pre-#780 build's 119, so 62% less than main and 30% less than before #780
(Mac, fastest of 15, rotated). `noalias` leaves the loop exactly as it was
(230 ms): LLVM still reloads the header each iteration, because Zig gives
a pointer no `dereferenceable` or `writable`, so the loads cannot run
before the loop's index tests and the stores cannot be gathered after
it (as `perf-stage/loop-hoist.md` found for Table reads). Neither narrow
fix in the runtime helps: two separate loads of length and capacity pair
again, this time as pointer and length (218 ms), and storing capacity
beside length every append so that an `stp` feeds the `ldp` is slower
(237 ms). On Trig, holding every lent String and List header (219
functions) and the 30 loops that append to one field of self is within
the noise on the Mac (0.2% fewer cycles on ts-pattern, 0.1% on zod3), as
are row 26's two arms. x86, where row 26 counted Trig's store-forward
blocks, waits for a pup slot. The design for (b) is below, for Rig -
Swiss's decision before anything is built in emit.

## 1. The loop

`src/uu/base32/base_common.rig` of the port (`~/Data/Code/rig/compare/rig/coreutils`):

```text
sub bits_encode(format: Format, input: ?String, out: !String)
  ...
    while i + 4 <= input.len
      w = pairs[Int(input[i])] << 48 | pairs[Int(input[i + 1])] << 32 | pairs[Int(input[i + 2])] << 16 | pairs[Int(input[i + 3])]
      !out.push[U64, .big](w)
      i += 4
```

`out` is emitted as `out: *rig.String`, and the push inlines
`String.pushInt`: read `items.len` and `capacity`, grow when short, store
the 8 bytes, store the new length. A Zig String is `std.ArrayList(u8)`, its
pointer, length and capacity at 0, 8 and 16, so the two reads are adjacent
and LLVM's AArch64 load/store optimizer pairs them. The store of 8 bytes
through `*align(1) u64` may alias the header (Zig gives LLVM no type-based
alias information), so each iteration reloads it.

Main (7e932e66d), the loop's header traffic:

```text
str   x8, [x0, x25]        ; the 8 bytes
add   x8, x25, #0x8
str   x8, [x26]            ; length, 8 bytes, at out+8
...
ldp   x25, x1, [x19, #0x8] ; length and capacity, 16 bytes, at out+8: the stall
ldr   x0, [x19]
```

The build before #780 (f880d1062) read them through two base registers,
which LLVM does not pair:

```text
ldr   x8, [sp, #0x38]
ldr   x20, [x8]            ; length
ldr   x8, [x26]            ; capacity
```

So #780 did not add the reload; it changed which registers LLVM chose, and
the reload it had always done became a paired one. The same port's source
from before the `io` switch, built by both compilers, gives 134 and 257 ms
(the bisect's numbers); main's own runtime with #780's String change
undone (`growList` back to `self.grow`) still pairs the loads and runs as
slowly as main (220 ms), which confirms the pairing is incidental to the
code around the loop.

## 2. The arms

Each arm is main's emitted package of the current port, hand-edited, built
as `rig build --release` builds it (`zig build-exe -Osafe
-fomit-frame-pointer`). Input: 192 MiB of `0xA5`, `coreutils basenc
--base16 FILE > /dev/null`. Mac, 15 rounds, arms rotated each round, user
time by `wait4`; every arm's output is identical.

| arm | edit | user, fastest | user, median | wall, fastest |
|---|---|---|---|---|
| pre-#780 | the old source built by f880d1062 | 119.2 ms | 121.7 | 133.8 |
| main | none | 218.2 | 220.9 | 232.1 |
| (a) noalias | `noalias out: *rig.String` | 229.6 | 229.9 | 243.3 |
| (b) loop hold | `{ var h = out.*; defer out.* = h; <the loop on h> }` | 82.8 | 88.5 | 95.9 |
| (b) function hold | the whole body on a local copy, written back by `defer` | 96.5 | 99.1 | 111.0 |
| split | capacity read by a monotonic atomic load, so it does not pair | 218.3 | 221.1 | 231.7 |
| stp | capacity stored beside length on every append | 236.6 | 238.1 | 249.9 |

The function hold was timed in a second, louder session against the loop
hold (both 96.5 ms there, main 245.2, pre-#780 134.7): the two are the
same. The split arm moves the pairing rather than removing it: LLVM pairs
pointer and length instead (`ldp x0, x25, [x19]`), which the length store
blocks just the same. A runtime-only fix would have to defeat LLVM's
pairing at every append, which is what Rig - Swiss called fragile; and
on x86, where the stall does not exist, the reload is still a load and a
store per append, which only (b) removes.

The loop hold's loop has no header access at all; the header is written
back with two `stp` after the loop. It is faster than the pre-#780 build
because that build still loaded and stored the length on every append.

## 3. Trig

Trig 2ba0719, built by main, `--singleThreaded`, Mac, rotated, fastest of
20 (ts-pattern) and 30 (zod3) by cycles and instructions from `time -l`;
every arm's output identical to the base's.

| arm | ts-pattern cycles | instructions | zod3 cycles | instructions |
|---|---|---|---|---|
| base | 2.2254G | 9.6899G | 0.4338G | 1.8754G |
| hold | 0.17% fewer | 0.08% more | 0.07% fewer | 0.16% more |
| rtval | 0.52% more | 0.20% more | 0.14% more | 0.32% more |
| keyk | 0.22% fewer | the same | 0.43% fewer | 0.02% more |

- **hold** is (b) applied as emit would: 219 functions lent a String or a
  List (`*rig.String`, `*rig.List(..)` parameters, inline ones included)
  hold the header for the whole body, and the 30 loops whose body reaches
  one field of self only through appends (`new_type_list` and its seven
  siblings, `conditional_flow_steps`, the pseudo-node builders) hold that
  field around the loop. Trig's hot loops call out (most are lent self),
  so few qualify, and none is hot enough to show.
- **rtval** is row 26's arm (1) in its runtime form: `rig.rt` of a struct
  of 16 bytes or less made an inline copy into a `var`, so no call and no
  temporary carries a `TypeList` or `NodeRef`. Row 26 counted these copies
  as 34% of Trig's x86 store-forward blocks; on the Mac they cost nothing
  measurable. Its other half, self by value for small objects, needs emit.
- **keyk** is row 26's arm (2): `put` and `put_new` in `ordered.zig` insert
  the key parameter `k` rather than `kk`, its copy lent to the hash and the
  probe, so the insert reads no key from the stack that two 8-byte stores
  just wrote. Within the noise on the Mac.

All three are for pup's `ld_blocks.store_forward` and cycles, which
`trig-kit.tgz` (below) measures; a keyk change also needs bench/hash's
guard, as it touches the Map.

## 4. The design for (b): a lent header held in a local

**What.** Where a function is lent a String, or a List with no inline room,
to write, emit copies the header (pointer, length, capacity) into a local
at the start of the body, binds the parameter's name to that local's
address, and writes the header back by `defer`:

```zig
pub fn bits_encode(format: Format, input: []const u8, __rig_lent_out: *rig.String) void {
    var __rig_held_out = __rig_lent_out.*;
    defer __rig_lent_out.* = __rig_held_out;
    const out = &__rig_held_out;
    ...
```

Every use in the body already goes through `out`, so nothing else in
emit changes; the local's address escapes only into the calls the body
makes, and since #780 the growth functions take the buffer by value, so
LLVM keeps the header in registers wherever the appends inline. A loop
hold is the same at a loop's scope; the measurements give no reason to
prefer it for parameters, and the function hold needs no knowledge of
where the loops are.

**Soundness against CORE.**

1. *One write loan* (§2, sentence 5). While the call runs, the caller's
   place is lent to write to it, and no other loan of that place, or of a
   place holding it or held by it, is live. So no other parameter, capture
   or result views the header: from entry to exit it is read and written
   only through the parameter. A local copy written back at every exit
   cannot be told apart.
2. *Nothing else reaches it.* Module-level names are constants; a `*T`
   lends nothing of its value to write (§4's table), and a `Cell` holds no
   String or List by value, so shared storage cannot reach a lent header.
   Other tasks cannot reach it either: a task lent the place would hold a
   loan the call's own loan excludes.
3. *Lending on.* A call in the body lent `!out` or `?out` gets the local's
   address or a view of its bytes. Its loan ends before the body's next
   use of `out` (sentence 6), so before the `defer`. A task started in the
   body and lent `out` must be waited for, as any loan holder is, before
   the call returns; to keep the argument short, the first version holds
   no header that is lent to a task, a closure, or a `raw` block.
4. *Results.* A function whose result is, or carries, the write or read
   view of the whole parameter (`-> !String` lent on) would return the
   local's address; such a function holds nothing. A view of the bytes
   (`?String`, `[]T`) points at the buffer, not the header, and is fine.
5. *Exits.* `defer` runs on every return, failure (`e!`) and `break` out of
   the body. A panic runs no `defer`, and need not: a panic stops at `main`
   (the program ends), at `task.isolate` (nothing outside it may be lent
   into it to write, so the stale header is in what the panic abandons), or
   at an actor (its state, which the header would belong to, is abandoned,
   never dropped). The leak checker, which marks what a panic's frames
   still hold as left rather than leaked (`leaveFrames` scans the stack
   from the panicking frame up), sees the grown buffer in the held local:
   only debug builds check leaks (`leak_checked`), and a debug build keeps
   every local in its stack slot. Checked by hand: `test/rig/
   concurrency-isolate.rig.test`'s "isolate leaves a lent String it grew",
   with `fill`'s header held, reports the same 2 allocations (52,629
   bytes) left by the panic as main, and no leak.
6. *Inline room.* A List with inline room keeps its first elements in the
   header itself (`mem()` points into the List), so holding it would copy
   those elements in and out; such Lists are not held. Map and Set headers
   are left for a second step, after their own ceiling.

The checker needs no new rule: no program is accepted or rejected that was
not before, and the oracle, which checks ownership, is untouched
(`test/oracle/rejections`, `differences` and `coverage` unchanged). Emit's
output changes only for functions lent a String or List.

**Where emit marks it, and the fact it reads.** One storage fact, decided
in `src/storage.zig` (hidden storage emit makes) and read through
`src/facts.zig`: `held_header` on a parameter, set when

- the parameter's type is a write view of a `String`, or of a `List` with
  no inline room, lent by pointer (`facts.zig`'s `.write_view => .pointer`);
- the function is not an `extern zig` shim, and its body has no `raw`
  block;
- no task, closure capture or `raw` block in the body is lent the
  parameter, and the result type carries no view of the whole header.

Emit reads the fact in two places: `emitParam` names the parameter
`__rig_lent_NAME`, and `bindParamLocal`, in the prologue, writes the copy,
the `defer` and the binding (for an inline function, where the parameter
is `__rig_in_NAME` and bound by `rig.rt`, the copy replaces that binding).
`--facts=storage` prints it. A self field held around a loop (`@items`
in a `!@` method) is a second step: it needs the loop's calls known not to
be lent self or a place holding the field, which is a fact about the
loop, not the parameter.

**Tests.** `code` cases for a held `!String` and `!List` parameter and for
each exclusion (inline room, `raw`, a task lent it, a `-> !String` result);
`test` cases that grow the held header past a reallocation and read it in
the caller, through a failure (`e!`) exit, a loop `break`, and a callee
lent it on; the isolate case above, which passes on main and must pass
with the hold.

**Expected gain.** basenc's loop 62% less user time on the Mac than main
(x86 to be measured; it removes a load and a store per append there too).
Trig on the Mac: under the noise, so its case rests on x86 and on programs
that append in loops through a lent String or List, as the coreutils port
does. The std.json guard and the Rust ports' benches would show the
rest.

## 5. x86, and the build

**x86.** pup, core 6 with its sibling idle, the basenc kit built on the
E-cores, 30 rounds rotated: main 116.4 ms of user time by the median
(107.8 fastest), the loop hold 116.9 (101.7), the function hold 116.4
(108.6), the build before #780 154.2 (135.7); wall time 144-146 ms for all
three of main and the holds. So on x86 the hold is level with main and
keeps #780's gain (the build before #780 against #780 itself, 12%, from
the first round's 144.4 against 127.9 fastest). Rig - Swiss approved (b)
as the design on that result.

**Built.** As section 4 says, with one change of form: the hold is a
storage fact like the others, `held_header` (Zig name `__rig_header_NAME`,
by copy, for the block), recorded on the parameter's name by
`storage.planHeldHeaders`, so `--facts=storage` prints it and emit names
the local through `hiddenStorage`. A parameter is held only when the body
uses it inside a loop, so a function that appends once pays no copy. The
port built by the branch: basenc 81.4 ms of user time on the Mac, the
ceiling's 81.7 (main 216.6). Trig built by the branch, against main's
build of the same Trig (Mac, 20 and 30 rounds rotated): ts-pattern 0.56%
fewer cycles and 0.06% more instructions, zod3 0.29% more cycles and
0.07% more instructions, within the noise; peak memory the same. std.json's
guard: 0.1-1.2% fewer instructions on all six files. bench/hash's guard:
every row within 0.1%.

## 6. Left

- Trig's speed on pup with the branch, through Rig - Helper's pup slot.
  The three Trig ceiling arms of section 3 (`trig-kit.tgz`, in
  `~/Data/Code/Claude/rig/rig/store-forward/` with the basenc kit and
  the disassemblies) are deferred: row 26 builds its own x86 arms of
  rtval and keyk.
- A self field held around a loop, in a `!@` method (section 4), is a
  second step.
