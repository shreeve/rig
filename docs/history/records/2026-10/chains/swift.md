# Chains as loops: the Swift seat (2026-11-03)

Lens: Swift's Sequence protocols, result builders, and SIL lowering. The question is how a
fused chain becomes a loop when the rewrite cannot write the type of the state that sits
before the loop.

All experiments ran on a `rig` built at `chains` HEAD (94873583e, via `tools/baseline HEAD`;
the `matches` worktree's `bin/rig` is gone). The scratch programs are in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-claude-rig-rig/879ee5e6-0761-4afa-90ec-4c26261f913b/scratchpad/swift/`.

## 0. Three facts the brief gets wrong (each verified)

1. **A closure bound to a local needs typed parameters.** `f = |x| x + 1` is rejected:
   "closure parameter `x` needs a type: annotate it (`|x: Int|`) or write the closure where
   its type is known" (`c.rig`). A closure literal called where it stands, `(|x| x + 1)(4)`,
   is rejected the same way (`c2.rig`). A bound closure that propagates failure also needs a
   written `fun(T) -> R!E` type (`e1.rig`). So option 1's claim, "only existing features",
   is false. Every stage closure needs the item type, whichever lowering we pick.
2. **`T` does not meet `none`.** `c = for x in xs / break x / else none` is rejected:
   "incompatible types `Int` and `none`" (`u2.rig`; `Checker.unify` meets `none` only with
   a type that is already `T?`). So `find` written as "a `for` value, `else none`" also
   needs a type, unless `unify` learns that `T` and `none` meet as `T?`.
3. **A List element cannot be the state.** In `for s in xs`, where `xs: List[String]`,
   writing `best = s`, `break s`, or `return s` is rejected: "bare use of loop view `s` ...
   would carry the viewed handle past the loop" (`ma.rig`, `fd.rig`). A Map's `items()`
   value can be the state (`state.rig` runs). So `min`, `max`, `min_by`, `max_by`, and `find`
   over a List, array, or slice of owner elements need a different shape: keep the
   *index* and form the view after the loop (`fi.rig` runs, and is clean under the sanitizer).

Two more facts shape the lowering:

4. **Move or copy must be written.** `best = v`, where `v` owns a String, is rejected: "write
   `<v` to move it" (`mv.rig`). `<` on a value that copies is also rejected (`hand.rig`). So
   the rewrite must know which items own, copy, or view. Only a type check gives that.
5. **Closure creation is an effect.** A closure literal inside the loop body is made once per
   item: `|+s, x|` clones `s` for every item, and `|<r, x|` moves `r` on the first item, so
   the second item is a use after move. Every closure must be made once, before the loop,
   as `reduce` makes its argument once.

Together, these mean the real problem is not only the state. It is **naming the item type at
each stage**: for closure parameters, state, and `collect`'s List. And the rewrite must also
know each stage's *ownership class*.

## 1. The lowering I would build

**One loop. Each closure is bound once before the loop. The rewrite names types with one
internal "stage type" form, which sema resolves to an ordinary TypeId.** No peeling.

The pieces:

- **Round 1: sema types the chain natively.** It classifies the chain (it needs the source's
  type for that anyway). It checks each stage closure with given parameter types, using
  `checkLambdaGiven(f, null, given, fails)`, the path generic calls use (`lentLambdaType`).
  It checks the consumer's needs (`Num` for `sum`, `Ord` for `min`/`min_by`, no view items
  for `collect`) and reports errors in chain terms. It records per stage only facts that
  survive rounds: bools and enums, never TypeIds. These are: does the item own, copy, view a
  slot, or view a value; does the closure fail; the integer type of a range.
  **Only a chain that checks clean is rewritten.** A chain with errors stays as written, and
  the final round reports it, so a user never sees an error about hidden code.
- **The rewrite** turns the chain into a `block` expression. A block is a value, and an
  outer `break` passes through it (verified: an `if` value block with locals and a `break`
  to the user's loop, `bl.rig`). The block holds:
  - The source, held: `h = ?xs` for a List, or the iterator, as `iterWhile` holds
    `?b.each()` today.
  - Each closure, bound to a hidden name. Its annotation is `(stage_fun ref fails)`.
  - The state, annotated `(item_type ref)`.
  - The loop, then the result.
- **Sema learns two internal type forms, resolved by one function**, `stageItem(ref)`.
  For a held source, it gives the type `for x in ref` binds (`loopElement`, the same
  classifier `checkFor` uses). For a stage closure, it gives the closure's result (its `ok`
  type if it fails).
  - `(item_type ref)` can go in any type position.
  - `(stage_fun ref fails)` goes only on a closure binding. It means
    `checkLambdaGiven(lambda, null, &.{stageItem(ref)}, fails)`.
  - Neither form can be parsed. Both resolve to existing TypeIds, so **emit, ownership,
    storage, and proofs change not at all**. Emit already writes local types from
    `symType(sym)` (`emitBind`), never from the type node's text. It even writes the
    prelude's `Item` as `__rig_m2_std_prelude.Item(...)`, which no source text could name.

How it scores on the brief's four tests:

- **Run time.** A bound closure is a Zig struct with a direct `__rig_invoke`; LLVM inlines
  it. I measured filter plus map plus sum over 20M `U64`, release, eight interleaved runs:
  the hand loop's fastest was 5682 µs and the bound closures' 5726 µs, within noise.
  The state is the hand loop's state.
- **What it adds.** The chain classifier and round-1 typing (needed by any lowering for
  classification, messages, and the ownership bools). Two resolver cases. The rewrite. Some
  `HiddenName`s.
- **Soundness.** The ownership checker sees the closures made once with their captures, the
  lends of the source, every move (`<v` written where round 1 says the item owns), and the
  state. That is exactly what runs.
- **Messages.** Type errors come from the chain itself, in round 1's terms. After the
  rewrite, only ownership can report, and it names hidden bindings. Their texts should read
  in a sentence ("filter closure", "min_by result"). Add a debug assertion: a sema
  diagnostic placed at a hidden leaf of a chain is a compiler bug.

**Why not peeling.** Peeling writes each stage twice. A closure literal cannot be written
twice: its leaves would share positions, and its captures would run twice. So peeling must
bind the closures, and binding them needs typed parameters, which is the same type-naming
form. Once that form exists, the state needs nothing more. Peeling would then only double
the stage code, need typed `0` and empty-List values for empty input, and still fail on
List elements (fact 3).

**Why not type text.** Sema can print a type, but not one that resolves in this module. The
prelude's `Item` lives behind `__rig_prelude`. A type from a module this one does not import
has no name here. And every leaf needs a source position nobody else holds. An internal
form resolved by the same sema cannot drift.

**Why not a native `chain` node through every pass.** Each pass would gain a second loop
form. That breaks one mechanism per idea and North Star 4.

**Why not std generic helpers.** Stages would have to compose closures inside a generic
body. And a generic body walking view items hits rule 4.

Swift precedent: result builders and derived conformances synthesize declarations whose
types the checker supplies, never a written `TypeRepr`. Swift does it with type variables;
Rig's equivalent is a type node only the compiler writes, resolved by the checker that
checks the result.

## 2. `trim`

The source:

```
oldest = ?@entries.items()
  .filter(|e| e.value.state matches .ready)
  .min_by(|e| e.value.touched) ?? break
```

**Rewritten.** «» marks a hidden leaf. The next round turns the `for` into the `while` that
`iterWhile` writes.

```
oldest = (block
  «for iterator» = ?@entries.items()
  «filter closure»: (stage_fun «for iterator» false) = |e| e.value.state matches .ready
  «min_by key»: (stage_fun «for iterator» false) = |e| e.value.touched
  «min_by result»: (item_type «for iterator»)? = none
  «min_by best key»: (item_type «min_by key»)? = none
  for «item» in !«for iterator»
    if not «filter closure»(«item»)
      continue
    «key» = «min_by key»(«item»)
    if «min_by best key» as «b» and not («key» < «b»)
      continue                       # strict <: the first item wins a tie
    «min_by result» = «item»          # an Item views the map; round 1 says "value view": no sigil
    «min_by best key» = «key»
  «min_by result») ?? break
```

I wrote the same program by hand, with the resolved types in place of the internal forms
(`lowered.rig`: `best: Item[?String, ?Entry]? = none`, `bk: Int? = none`, and closures
`|e: Item[?String, ?Entry]| ...`). It checks, runs (`2 1`, as the hand loop), and is clean
under `RIG_SANITIZE=1`. Emit writes:

```zig
var h = rig.rt(self.entries.items()); _ = &h;
var p = struct { pub fn __rig_invoke(__rig_self: *@This(), e: __rig_m2_std_prelude.Item([]const u8, *const Entry)) bool {
    _ = __rig_self; return switch (e.value.*.state) { .ready => true, else => false }; } }{}; _ = &p;
var k = struct { pub fn __rig_invoke(__rig_self: *@This(), e: __rig_m2_std_prelude.Item([]const u8, *const Entry)) i64 {
    _ = __rig_self; return e.value.*.touched; } }{}; _ = &k;
var best: rig.Opt(__rig_m2_std_prelude.Item([]const u8, *const Entry)) = rig.pack(..., null);
var bk: ?i64 = null;
while (true) {
    if (rig.some(h.next())) |e| {
        __rig_body_6: {
            if (!p.__rig_invoke(e)) break :__rig_body_6;
            const kv: i64 = k.__rig_invoke(e);
            if (bk) |b| { if (!(kv < b)) break :__rig_body_6; }
            best = rig.pack(rig.Opt(...), e);
            bk = kv;
        }
    } else break;
}
const oldest = (rig.some(best) orelse { break :__rig_while_2; });
var key = rig.String.of(.{ oldest.key });
```

**Against the hand loop** in `../brief.md`: it has the same single loop, the same `next()`,
and the same `?i64` key test. It has one difference, in the chain's favour. The hand loop
clones `+e.key` (an allocation) every time a new oldest is found. The chain holds a view and
clones once, after the loop. The two closure calls inline to the hand loop's code.

## 3. Traps

- **Iterator, List, and range sources.**
  - An iterator's item is a value (a Map's `Item` views the map). It may be the state, a
    `break` value, or the result.
  - A List, array, or slice of owner elements gives a slot view that may not leave its
    iteration (fact 3). So `min`, `max`, `min_by`, `max_by`, and `find` keep `«best index»:
    Int?` and give `?h[i]` after the loop (`fi.rig`). Plain elements copy, and use the
    iterator shape.
  - Cost: `min()`/`max()` without a key re-index the best per comparison, which adds a
    bounds check (`?h[b]`). `min_by` stores the key and does not.
  - Inconsistency for the owner: `!out.push(s)` of the same slot view into a `List[?String]`
    is accepted, and its loan is tracked (`lv.rig`, `lv2.rig`). Only a binding is refused.
    If a binding were allowed as push is, the index shape would go away.
  - A range cannot be held: "a range can only be used as a `for` loop source". So its
    closures cannot reference a hold. Round 1 records the range's integer type, and the
    rewrite writes it as a hidden type leaf, as `HiddenName.u8` does for byte strings. A
    range over a type parameter `T` (rare) needs a hold. Range values would dissolve this
    (§4).
- **`take` and `find` must not pull an extra item.** For an iterator source, the rewrite
  writes the `while` itself, with each `take`'s counter before the pull:
  `while «taken» < «n» and (!h).next() as «item»`. This handles `take(0)`, and `filter` then
  `take` counts the items that passed. `find`, `any`, and `all` `break` at the deciding item.
  `zip` pulls the left source, then the right. When the right side ends, one left item has
  been pulled and lost, as in Rust. Document it.
- **Closures with captures.** The closures are bound once, so the captures run once: `+n`
  clones once, `<r` moves once, `?n` and `!n` lend for the block, which ends with the
  statement. That is the `reduce` rule, and the ownership checker sees it as it is. Do not
  inline closure bodies. `return` inside a closure (legal: `d.rig`) would change meaning, and
  hoisting captures would rename the user's leaves.
- **Control flow in a chain's other arguments.** In `xs.take(k ?? break).sum()`, the `break`
  must still leave the user's loop. A `block` keeps it right. A `while true` wrapper would
  catch it.
- **`collect` of views.** `List[?String]` is a legal local, so nothing downstream rejects it.
  Round 1 must reject it with the design's fix (`.map(|s| +s)`). For owned items, `collect`
  writes `!out.push(<v)`, using round 1's ownership bool.
- **Failing closures.** `.sum()!` lowers each call as `f(x)!`, which passes the failure up as
  the user's `!` says. `.sum() catch d` has no boundary in a fused loop. With one failing
  stage, write `f(x) catch break d` (verified form, `e1.rig`), so `d` is evaluated only on
  failure. With several failing stages, `d` would be written twice: reject this with the loop
  as the fix, until a program needs it.
- **Hidden names must be distinct per stage** (two `filter`s). Use numbered texts. Each
  hidden leaf takes a free position inside its stage's method name.

## 4. For the owner (defaults first)

1. **The approved design's "nothing is new" understates it.** Chains need round-1 typing, the
   two internal type forms, and a second lowering shape for List elements. *Default: build it
   as in §1.*
2. **`T` meets `none` as `T?`** in loop and `if` values (`for ... break x / else none`). It is
   a small, user-visible fix, and it makes `find`'s lowering need no type. *Default: yes,
   as its own change.*
3. **Rust's `max_by_key` returns the last of equal maxima.** The design says "first item on
   ties" for both `min_by` and `max_by` (Swift and Python agree). A port from Rust could
   silently pick a different entry. *Default: keep "first", and say so in STD and
   MIGRATING.*
4. **Range values** (`r = 0..n`, as in Swift and Rust): this would remove the range special
   case. *Default: not now; use the primitive type leaf.*
5. **A loop slot view stored in a binding.** It is refused, while a push of the same view is
   accepted. *Default: keep the rule; use the index shape. Ask the ownership owner whether the
   two should agree.*
6. **`catch` on a chain with several failing stages.** *Default: reject, with the loop as the
   fix.*
