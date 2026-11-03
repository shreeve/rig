# `$plain(T)` narrowing: review (panel step 4)

On 57b0360fe; probes in `probes-rev/` (`run.sh RIG`, sanitizer). Trig's Zig is `rig emit` of a trig@8989715 pack.

**Verdict: accept with fixes.** Every adversary hole is closed. The fixes are completeness and wording: a missing bit means `false`, and f₀ is always sound, so CORE §10's "second round" doesn't apply.

## 1. Holes

- **Closed:**
  - a02/a03: sema's `comptime` bit splits `Int`/`?Int` and `Static`/`?String`, and no Zig test is left.
  - a07: `T` keeps what it had and also copies. A copy of an `Entry[K, V]` under `Copy + Owned` already passes through requirements (r5).
  - `lower.zig`, `or`, and one meaning of plain (r3).
- **Size on Trig: none.** Trig has 113 `Map` and 9 `Set` Zig instances, and none takes `Static` or `?String`. Its source has no `Map[?…]`. Nothing splits, and Zig skips a comptime-false branch.
- **Nested generics: under-specified.** "Only generics that test `$plain` pay" is wrong. `fresh[Int]` and `fresh[?Int]` both emit `fresh(i64)` holding `Map(i64, V)` (r1). Every generic that makes a testing instance from its own parameters needs their bits, transitively: Trig's `OrderedMap` (9), `OrderedSet`, `MultiMap`, `Set[T]`, BFS; otherwise their maps stay dense.
- **Combining bits** is sound only as `isPlain` over the caller's bits. `Tag[String]` is plain because `T` is a phantom (r2), and `?T` is never plain.
- **Erased APIs: sound.** The table is built at the erasing site, from its Zig type (r4). With no defaults on the bit parameters, a forgotten bit is a Zig arity error, not a wrong answer.
- **Byte-identical Zig** holds by construction while std has no `$plain`, but it needs a gate (fix 5).

## 2. Fixes

1. **Thread bits.** In `expandInstantiations`, compute a fixed point over uses, erasures and witnesses. Print the bits in type expressions too (`OrderedMap(K, V, bk, bv)`), with no defaults. About +50 lines.
2. `plainOf(arg)` = `sema.isPlain(arg)`, with each caller parameter read as its bit. Test a phantom, a `unique` object, `?T`, `T?` and `Pair[T, Int]`.
3. Never feed the narrowed set to facts cached per `TypeId` (`typeInfo`), only to requirements and bounds. Test one `T` copied in the region and moved after it.
4. **Region:** the `and` chain of any condition that guards code: `if`, `elif`, `while`, a statement or arm guard, `a if c else b`, with parenthesized `and`s flattened. SPEC's "guard" covers arm guards too.
5. **Gate:** the `rig emit` package of the corpus and of Trig's pack is byte-identical before and after.
6. When `$plain(P[T])` doesn't narrow, the error suggests `$plain(K) and $plain(V)`.

Aside, a separate bug: `b: W[?Int] = fresh()` infers `W[Int]`.

## 3. SPEC paragraph

The draft's paragraph ends with an exception list ("Nothing else narrows: …") and isn't a desugaring. Proposed:

> `$plain(T)` is `true` where `T` is plain data (CORE §1): it copies, owns nothing, and views nothing, as a type that provides both `Copy` and `Owned` does. Each instance answers it when the program compiles, so a generic body that tests it is two bodies. Where `T` is a type parameter or an associated type, and `$plain(T)` is an operand of a condition's `and` chain, the instances where `T` is plain compile the body as written. In them, what runs only once the test has held (the operands after it and the code the condition guards) is checked with `T` as it is elsewhere, and also known to copy and to hold no loan. What that code needs of an instance is checked at those instances alone. Every other instance compiles the body without that code, as if the test were `false`.

The draft's copy-sentence fix and the Builtins entry stand.

## 4. Owner decisions

1. `$plain`, not `$copies`: **yes**. It's CORE's word and approved, and on Trig the split costs nothing.
2. Sema's `comptime` bit, `Static` plain: **yes, with fix 1**.
3. "`T` as elsewhere, also plain": **yes**.
4. Which conditions narrow: **every condition's `and` chain** (fix 4).
5. One meaning of plain: **yes**.
6. The copy sentence: **yes**.
7. The oracle change reaching `lower.zig`: **yes**.
8. No CORE change: **yes**.

## 5. Worth

**Yes.** 4.4% of ts-pattern's cycles is twice Trig's 2% bar, plus 34 MB less map memory, for about 540 lines with fix 1. It's reusable by any container. No language-free route matches it:

- **`Entry?` slots with `none`:** each slot grows by half (r6: 8→12 B and 16→24 B), which gives back most of the 103→69 MB.
- **A second map bounded by `Copy + Owned`:** no compiler change, but two maps against the one-map target, with an opt-in at each site, and wrappers stay dense.
