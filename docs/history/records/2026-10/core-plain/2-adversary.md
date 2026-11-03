# `$plain(T)` narrowing: adversary (panel step 2)

On 57b0360fe. Probes: `probes-adv/` (`run.sh RIG`, RIG_SANITIZE=1, output in `today.txt`); where the rule can't run, they hand-write f₁/f₀.

**Verdict:** the rule survives with fixes. Its soundness rests on the emitted `comptime rig.isPlain(T)`, and p16 checked only one of the Zig-type collisions. The test emitted for each instance must be Rig's answer.

## 1. HIGH: by-value views share a Zig instance with plain types (a01, a02, a05)

A read view of a scalar is lent as a copy (`lendByValue`). So `?Int`, `?Bool`, `?Float`, `?E`, `?Simd`, `?Slot[n]`, their optionals, and every type holding one by value emit as the plain type: `sz[?Int]` is `sz(i64, …)` and `Box[?Int]` is `Box(i64)` (a01). An iterator's item does too: `next(!@) -> (?Int)?` makes `rig.IterItem(I)` `i64` (a05). `isPlain(i64)` is true, but Rig says `?Int` is a view (`[T: Copy + Owned]` refuses it).

As a result:
- The block runs where the rule says it is absent.
- Requirements the block guards are never checked for that instance.
- `Owned` lets the view escape its loan. In a02, `hold[?Int](?n)` should print `none`; the Zig runs f₁ and prints `kept 3`, a view of `n` read after `n = 4`. It's memory-safe only because the lowering copies.
- Guarded calls make Zig instances sema never checked; recursion there can diverge in Zig.

`$name` already refuses `?Int` instances: p16's precedent shows the hazard.

**Fix (default):**
- Each tested parameter or associated type gets a `comptime` Bool that Rig computes at the instance, or from the caller's bits inside a generic.
- `f[Int]`/`f[?Int]` and `f[Static]`/`f[?String]` then become separate Zig instances.
- Decision 2 goes away: `$plain(Static)` is true everywhere (CORE §1), and the Map packs `Static` keys.

**Cheaper alternative:** refuse by-value-view instances where the body tests `$plain`, as `$name` refuses them. Decision 2 then also has to cover `Box[Static]` (= `Box([]const u8)`).

## 2. HIGH if built as written: `isPlain` must walk structs (a03)

`?{Shape}` is `rig.ApiView` (an address and a table), with no drop glue, and it can be a `T`. The design says `isPlain` is "false for slices and pointers", which read literally makes it plain. The block could keep the view in an owned closure after `q` drops: a use after drop.

**Fix:** with fix 1 no Zig test remains. Otherwise the test must reject any pointer, slice, `__rig_drop`, or `unique` at any depth, with a test on each runtime view struct.

## 3. MEDIUM: "added to T's bounds" makes a private T bounds-only (a07)

A bounded `T` "is checked against its bounds alone". `[T: Copy + Owned]` refuses `x < y`, which an unbounded private `T` passes. Read literally, the paragraph and the f₁ desugaring refuse ordering, arithmetic and `x.m()` inside the block though they pass outside it.

Write it as: "`T` is checked as before, and is known to copy and to hold no loan." Requirements recorded in the block must still be checked at live instances, and a test should show one failing there.

## 4. MEDIUM: the oracle needs `lower.zig`, not only `kinds.zig`

- `copiesNoT` sets `copies_t` on any copy of a `T`, the block's included. `genericCall` then abstains at every owner instance ("an owner whose body copies a `T`"). For the packed Map that's every `Map[String, _]`: a silent loss of coverage.
- `itemFinding` re-lowers the body at an instance whose item views its base. A copy in the block held past a base change becomes a finding where the compiler accepts, so the two disagree.

**Fix:** skip narrowed blocks for `copies_t` and `t_calls`, and in item mode. The compiler's per-instance item check (SPEC Generic bodies, "views that base only at an instance") must skip them too. About 100 lines, plus a corpus count of abstentions before and after.

## 5. LOW: the condition shapes are open (a08)

If `($plain(T) or c) and d` narrows, `dup[String]` copies a String: a double drop. Write "an operand of the condition's top-level `and` chain", the same for `a if c else b`, and say whether a postfix `if` counts.

## 6. LOW: "plain = Copy + Owned" is three sets today

A function value passes `Copy + Owned`, but `isPlainData` excludes it and Zig emits a pointer. `isPlainData` admits `?String`, which `Owned` refuses. Name one sema fact and require every emitted answer to be a subset of it.

## No hole found

- **Escapes** through an outer `T`, a `List[T]`, a field, a capture, an owned closure, `defer`, a return, or `break`/`continue`: a04 (f₁ at `Int`, f₀ at `String`) is sanitizer-clean. Drop flags are dynamic, so a move inside the block leaves a non-plain instance's flag set.
- **`and`:** later operands run only in plain instances.
- **`else`** and Static's f₀ are checked for every instance.
- **Tasks:** `Sends` still applies. A plain copy shares nothing, and so does a by-value view.
- **Decision 4** (a06): a read-view `T` already copies in `for x in ?v` and through `as`, and keeps its loans (`<s` is refused). It widens nothing. Keep "read view" out of the narrowing paragraph: a view is `Copy`, never `Owned`.

## Owner decisions, revised (defaults)

1. `$plain`, not `$copies`: yes.
2. Emit Rig's answer as a `comptime` Bool. This replaces "Static is `?String`": yes.
3. Word the block as "checked as before, known plain", not "bounds added": yes.
4. Fix the copy sentence: yes.
5. Extend the oracle change into `lower.zig`, about 100 lines: yes.
