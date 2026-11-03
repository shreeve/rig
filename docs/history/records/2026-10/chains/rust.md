# Chain panel: the Rust view (how a fused chain becomes a loop)

Everything here was run with a `bin/rig` I built from main at 94873583e (#883, `matches`
merged; the `matches` worktree was removed mid-session) in my scratch directory
`/private/tmp/claude-501/-Users-shreeve-Data-Code-claude-rig-rig/879ee5e6-0761-4afa-90ec-4c26261f913b/scratchpad/chains/`.
The files there: `hand.rig` (today's trim), `native.rig` (one loop, typed state), `peel.rig`,
`bound.rig`, `lowered.rig` (the lowering I recommend, written by hand), `gen.rig` (generic
helper), `bench2.rig` / `bench3.rig` (slice benchmarks), `mapbench.rig` (trim-shaped Map
benchmark), `e*.rig` (probes). All trim variants print `2 100 4 / k0 / load`, and
`lowered.rig` runs clean under `RIG_SANITIZE=1`.

## 0. Two premises in the brief are false today

1. **"Closures may be bound to locals (`f = |x| x + 1`)."** They can't, unless the parameters
   are typed:

   ```
   e9.rig:2:8: error: closure parameter `x` needs a type: annotate it (`|x: Int|`) or write
   the closure where its type is known (`f: fun(Int) -> Int = |x| ...`)
   ```

   Routing it through a generic to type it is refused too ("this call's result may hold the
   callable it is lent"). So option 1 (peel), "each closure bound once to a hidden name", hits
   the same wall as the state: the rewrite has to write the item type into the closure's
   parameter. Peeling without binding means writing each closure body twice, and one node may
   not appear twice. A deep copy would need fresh positions whose text reads the same, which
   the leaf model (text = the source at `pos`) can't do. **Peel is not buildable from
   existing features.**
2. **"`find` needs no declared type (`break item`, `else none`)."** A loop's `break x` and
   `else none` don't meet: `error: incompatible types 'Int' and 'none'` (an `if` gives the
   same error). It works only when the loop's binding is annotated: `r: Int? = for ...` runs
   (`e11.rig`).

So every consumer except `count`/`any`/`all`/`reduce` needs a type the rewrite writes, and so
does every stage, because its closure is bound with a typed parameter. The question isn't
peel against a type node. **The type node is needed in every case. What's left to choose is
its shape and, per consumer, the loop shape.**

## 1. What I would build

**A rewrite-only type form that names the type of a hidden binding already in scope, and
closures bound once to hidden names. `sum`/`count`/`any`/`all`/`find`/`collect`/`reduce`
lower to one loop, and `min`/`max`/`min_by`/`max_by` to a peeled loop.**

### The type form: `h.Item` and `f.Result`, backward references only

Rig already parses `I.Item` in type position as `(member I Item)`, and
`TypeResolver.assocMember` (resolve.zig ~4380) resolves it when `I` is a generic parameter.
Extend that one function: when the object leaf is a **hidden leaf** naming a local,

- `h.Item` is what `for x in h` binds (`sema.iterItem` for an iterator; the element for a
  List, array, or slice, lent `?T` for owner elements; the integer for a range);
- `f.Result` is the return type of the closure bound to `f`.

Why this shape:

- **Backward references only.** `h` and `f` are declared before the annotation, so
  `checkSet` (typecheck.zig ~1752, `r.resolveType(type_node)`) resolves it on the spot from
  `sym.ty`. There is no inference variable, no forward reference, no type text, and nothing
  carried from round 1 to round 2. The round-1 TypeIds can die, because round 2 recomputes
  the same types from the same bindings.
- **No new `Type`, no emit change.** `emitBind` writes a binding's Zig type from sema's TypeId
  (`emitTypeTy(ty)`) and only checks that an annotation exists (emit.zig ~3020). Ownership,
  storage, and proofs read sema's types, so they see `best: Item[?String, ?Entry]?` exactly
  as if a person had written it. Only `rig normalize` needs to print the resolved spelling.
- **Unwritable by programs.** A program can't spell a hidden leaf, so Rig gains no `typeof`.
- **What later changes carry:** about 30 lines in `assocMember`, plus two hidden member names
  (`Item` can reuse a hidden text; `Result` is new). Any future type kind costs it nothing.

The rejected alternatives:

- **Type text appended to the source.** Many types have no spelling in the module: a type
  from a module it doesn't import by name, `__rig_prelude` types, closure results. Positions
  past the source break `leafText` and diagnostics.
- **Portable TypeId keys.** TypeIds hold SymbolIds (`nominal: SymbolId`), which die with the
  round too. That means a serializer over every `Type` variant, maintained forever.
- **An inference variable for a hidden `best = none`** (Rust's way). It depends on the order
  of statements in a single-pass bidirectional checker, and `if best == none or k < low`
  reads it before any assignment.
- **A native chain node.** Every pass would learn it, which breaks North Star 4's economy.
- **Generic std consumers** (`gen.rig`). They run only with `[I.Item: Copy, K: Copy + Ord]`
  and a spurious `keeps key`, which shuts out owned items such as `map(|s| +s)`. Calls go
  through `rig.FnRef`, and the body is full of `defer rig.drop` noise. The design avoided
  generic bodies over view items on purpose.

### Bound closures cost nothing

A bound closure is emitted as a zero-size `struct { fn __rig_invoke }` and called directly
(`s1.__rig_invoke(x)`). It has no `FnRef` and no indirection (see `bound.zig`), so LLVM
inlines it as it inlines a Rust closure's `call_mut`. A capture lend ends at its last use:
`n += 1` after a loop that used `|?n, x|` is accepted (`e13.rig`), so a hidden binding gives
no false conflicts. Binding also keeps closure semantics exactly (`return`, `x?`, captures),
which inlining the body would not.

### Peel the min/max family, because Rust does and it measures

Rust's `min_by_key` is `map(key).min_by(cmp)`, and `min_by` is `reduce`, which is
`let first = self.next()?; Some(self.fold(first, f))`. That is a peel, and `Vec::from_iter`
(`SpecFromIterNested`) peels too. I measured 20M `U64`s with `filter(...).min_by(...)` in
`rig build --release`, best of 7:

| Body | one loop, optional state | one loop, the hand loop's `best == none or` | peeled |
|---|---|---|---|
| `% 3`, `% 1000003` | 44.3 ms | 45.1 ms | **38.3 ms** (1.16x) |
| `& 1`, `& 0xFFFFF` | 51.0 ms | 50.4 ms | **14.3 ms** (3.5x) |

The steady-state loop has no "first yet?" test, so LLVM can if-convert the filter and the
compare into selects. In the one-loop forms the filter stays a branch, and on random data it
mispredicts. On the trim-shaped Map (300k entries, pointer-chasing), all three are equal
(about 245 µs; `mapbench.rig`). So trim is as fast as its hand loop either way, and the peel
matters for tight loops. `sum`, `count`, `any`, `all`, `find`, and `collect` need no peel:
the typed zero, the typed `none`, or the typed empty `List()` declares the state (`out: List[T]
= List()` works, `e11.rig`).

## 2. `trim`: what the rewrite writes, and the Zig

Source:

```rig
oldest = ?@entries.items()
  .filter(|e| e.value.state matches .ready)
  .min_by(|e| e.value.touched) ?? break
```

Rewritten (hidden names written here as `h s1 s2 r`; `lowered.rig` runs it with `h.Item`
spelled `Item[?String, ?Entry]`):

```rig
h = ?@entries.items()                 # the existing hidden "for iterator" hold
s1 = |e: h.Item| e.value.state matches .ready
s2 = |e: h.Item| e.value.touched
r: h.Item? = while (!h).next() as x   # loop 1 = find the first that passes
  if s1(x)
    new best = x
    new low = s2(x)                   # the key's type is inferred: no node needed
    while (!h).next() as y            # loop 2 continues the same iterator
      if s1(y)
        k = s2(y)
        if k < low                    # strict: the first on ties
          best = y
          low = k
    break best
else
  none
oldest = r ?? break
```

Emitted (`lowered.zig`): `var h = rig.rt(self.entries.items())`, then two zero-size closure
structs, then `const r: rig.Opt(Item([]const u8, *const Entry)) = @as(..., __rig_loop_4: {
while (true) { if (rig.some(h.next())) |x| { if (s1.__rig_invoke(x)) { var best = x; var low:
i64 = s2.__rig_invoke(x); while (true) { if (rig.some(h.next())) |y| { if (s1.__rig_invoke(y))
{ const k: i64 = s2.__rig_invoke(y); if (k < low) { best = y; low = k; } } } else break; }
break :__rig_loop_4 rig.pack(..., best); } } else break; } break :__rig_loop_4
rig.pack(..., null); })`.

Against the hand loop it is the same `items().next()` walk and the same `switch` on `state`.
It holds the best item as a pointer pair rather than calling `rig.String.of` at every new
minimum (the hand loop clones the key each time; the chain clones once, in `+oldest.key`).
The ownership checker sees `best = y` keep `@entries` lent until `+oldest.key`, so `take`
must come after the clone, and it does.

## 3. Traps

- **Sources.** Loop 2 differs by source:
  - an iterator continues `!h`;
  - a List, array, slice, or `?String` uses `for x, i in h` and then `for y in ?h[i + 1..]`
    (measured in `bench2.rig`);
  - a range can't be bound ("only valid as a `for` source"), so hold its end in a hidden
    binding and continue `x + 1..e` (for a stepped range, `x + step`).

  Hold every source in `h` exactly once, so `h.Item` has something to name and no source
  expression is written twice.
- **How far `take` and `find` pull.** Rust's `Take::next` checks `n != 0` before calling the
  inner `next`. Lower `take(n)` as `while t < n and (!h).next() as x`: the count is tested
  before the pull, so `take(0)` pulls nothing and `filter(f).take(2)` calls `f` no more
  after the second hit. In a List `for`, break right after the n-th item and guard `n > 0`.
  `find`, `any`, and `all` break right after the deciding item (that's `try_fold`).
  `(!it).take(2).collect()` must leave `it` just past item 2; test it.
  - `zip` pulls `a` and then `b`, so when `b` ends one item of `a` is spent. That is Rust's
    general `Zip`; document it.
  - `skip` after `map` calls `f` on skipped items, as Rust's default `nth` does.
  - The peel shares the `take`/`skip` counters between both loops.
- **Captures.** Bind each closure once, before the loop:
  - `|+n|` must clone once, not once per item, so never re-create a closure inside the loop;
  - `|<r|` moves into the hidden binding. Wrap the lowering in a block that ends with the
    statement, or the move capture drops at scope end rather than statement end;
  - `|?n|` and `|!n|` are checked as closures, with lends ending at last use (verified).
- **`collect` of views.** Reject `List[?T]` in round 1 with the design's message
  (`.map(|s| +s)`). When the chain has no `filter`/`skip`, reserve `h.len` (or `min(n,
  len)` under `take`). That is Rust's `TrustedLen` path: one allocation and no growth checks.
- **Failing closures.** With `chain()!`, write `s1(x)!` inside the loop, which ends at the
  first failure as `reduce` does. With `chain() catch |e| d`, a `!` inside the loop would
  leave the *function*, not the chain. The rewrite has to route the failure to the handler,
  for example `v = s1(x) catch |e2| (failed = e2; break)` with a hidden `failed: error? =
  none`, then the handler after the loop. Test this before claiming it.
- **Position and hoisting.** `a and xs.any(f)` or `d ?? xs.sum()` must not run the loop
  eagerly. Hoist the chain only when it is the statement's value or the leftmost operand
  that always runs, as in trim. Anywhere else the loop stays in place. Emit already writes a
  loop as `@as(T, label: {...})`, but sema and the IR have never seen a loop nested in an
  operator, so check that first.
- **Hidden names and positions.** A chain needs several distinct hidden texts (source, stage
  k, result, counters), and each hidden leaf needs a unique position. The freed method-name
  and punctuation positions of each stage can be used, or `padLambda`'s past-the-end
  positions with a `pad_homes` entry.
- **Errors in user terms.** `modules.check` keeps only the last round's diagnostics. So sema
  records a chain fact only for a chain that checks clean in round 1: stage arity, `Ord`
  keys, `Num` items for `sum`, `collect` of views, not a value. A bad chain stays unrewritten
  and round 2 reports the same user-terms error. Any round-2 diagnostic at a hidden position
  is a compiler bug; assert on it.

## 4. Back to the owner

1. **The peel default rests on two false premises** (section 0). Closures need typed
   parameters, and `break x` / `else none` don't meet. Every lowering needs the type form.
   Approve it as the one compiler addition: `h.Item` / `f.Result`, rewrite-only.
2. **Peel min/max/min_by/max_by; one loop for the rest.** It measured 1.16x to 3.5x faster
   than one loop on slices, and it is Rust's own `reduce`. It is even with the hand loop on
   trim.
3. **Ties.** The design says "first on ties" for both. Rust returns the **last** maximum for
   `max`, `max_by`, and `max_by_key` (`cmp::max_by` takes `v2` on `Equal`), and the first
   minimum. Python, Swift, Kotlin, and C++ return the first. Keeping "first" is defensible,
   but it is a silent difference for code ported from tsrs, so state it in SPEC and grep
   Trig's ports for `max_by`.
4. **`sum` of an empty chain.** The design says "a number, as `xs.sum()` and `iter.count`
   give" (Rust: `0`), but `std.iter.sum` returns `I.Item?`. Pick one rule, or name the
   difference.
5. **`collect` capacity.** Reserving `len` for a chain with no filter is free speed that
   Rust takes. Add it to the design.
