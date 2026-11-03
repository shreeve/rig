# Chains as loops: the Zig view (2026-11-03)

Lens: the Zig the compiler should emit, what LLVM makes of it, and how little the emitter and
checkers must learn. Every claim below was checked against `src/` at `0829b8877` (the `chains`
worktree) and against programs built with a private copy of that commit (the `matches` worktree
was gone when I started, so I built `bin/rig` from a `git archive` copy in my scratch directory).
The programs are in `zig-files/` next to this file.

## 1. What I would build

**A peeled loop for `min max min_by max_by`, a single loop for every other consumer, and one
rewrite-only type node, `(item_type NAME)`, to type the closures and the state.**

Option 1 (peel) is the right *shape* for the min family and the wrong *typing strategy*.
Option 2 (a type node) is the right typing strategy. They are not rivals: build both, as one
rewrite.

### Finding A: the peel does not use only existing features

A stage closure bound once to a hidden name, as the peel needs (each stage is called from two
loops), does not type today:

```
p1.rig:23:13: error: closure parameter `e` needs a type: annotate it (`|e: Int|`) or write the
closure where its type is known (`f: fun(Int) -> Int = |e| ...`)
```

A closure gets parameter types only from a call it is passed to (`lentLambdaType`,
`armResult`) or from an annotation; a binding gives none (`typecheck.zig:18926`). So the peel needs
the item type too, for the closures. Every option needs sema to learn something.

### Finding B: `find` does not type today either

The brief says `find` needs no declared type ("a `for` value: `break item`, `else none`"). It
does not:

```
p1.rig:30:9: error: incompatible types `Item[?String, ?Entry]` and `none`
clo.rig:13:5: error: incompatible types `U64` and `none`        # even in a fun returning U64?
t1.rig:5:5:  error: incompatible types `Int` and `none`          # `if c` / `x` / `else` / `none`
```

`unify` (`typecheck.zig:18453`) lets `none` meet an optional, not a `T`. Nor does `List()` take
its type from a sibling `break` (`t3.rig`, `t4.rig`). It does take it through `??`:
`<o ?? List()` types (`t5.rig`).

### Finding C: which loop LLVM gets matters more than closures

All built with `rig build --release`, Apple Silicon, each variant in its own program, fastest of
15 rounds of 20 scans. "min_by" is the `trim` scan: filter `.ready`, min by `touched`,
200,000-entry Map; and an Int version over a 1M-element List.

| min_by lowering | Map items | Int List |
|---|---|---|
| hand loop as Rig teaches it (`if oldest == none or k < touched`, clone per new min) | 2.51 ms | 44.8 ms |
| single loop, closures bound, `best: T?`, `bk: K?` (`if bk as b and not (k < b)`) | 4.35 ms | 15.9 ms |
| single loop, `best == none or k < bk ?? k` | 2.42 ms | 44.1 ms |
| single loop with a typed dummy key (`bk: Int = 0`; not writable for a general K) | 2.34 ms | n/a |
| **peel** (first passing item starts the state; second loop has no "first?" test) | **2.41 ms** | **12.6 ms** |

The single loop swings 1.8x to 3.5x with how LLVM reads the "is this the first?" test: when the
flag and the comparison meet in one Bool, LLVM if-converts the update into a `cset/and/tst` +
four `csel` chain carried around the loop (seen in the disassembly of `chain_min` and of
`i_hand`). The peeled loop carries only `best` and `bk`; its update is `cmp; csel; smin` on the
Int List and a predicted branch on the Map. It was the fastest or tied in every shape I tried.
Rust does the same: `min_by_key` is `map` + `reduce`, and `reduce` is `next()` then `fold`.

Closures cost nothing: a bound closure is emitted as a zero-size (or capture-field) `struct` whose
`__rig_invoke` is called directly; the hot loops above contain no call but the Map's own
`live_from`/`gone_from`. The single typed loop with closures equals the hand loop to the
microsecond on `sum` (9.46 vs 9.43 ms; the peel's 6.45 ms there is block layout, not structure:
same instructions, fewer taken branches).

`min()` on a plain Int List: single 8.72 ms, peel 8.69 ms (a tie). So: peel the min family, where
it removes a loop-carried flag; do not peel the rest, where it only doubles code.

### Why the type node, and how small it is

- **Emit learns nothing.** `emitBind` writes a local's type from `symType(sym)`, the type sema
  settled; it reads the annotation node only to ask whether there is one (`emit.zig:3017`).
- **Ownership learns nothing.** It never reads `Set.type` (only `emit`, `resolve`, `rig`, and
  `typecheck` do), so a type node is invisible to it, to storage, and to proofs.
- **Sema learns one case** in `resolveType` (`resolve.zig:3864`): `(item_type NAME)` looks up a
  hidden binding already declared and gives: for a held source, the type `for x in NAME` binds
  (the code that types a `for` variable already computes it); for a bound closure, its result
  type (the `ok` type when it can fail); for a held range bound, its own type. About 20 lines.
- **The grammar learns one `@wrapper` kind**, as `as_match` and `result_part` are: a node only the
  Parser wrapper builds.
- **The rewrite** holds the source and binds each closure *before* the loop anyway: that is what
  makes `|+n|` copy once, `|<r|` move once, and `|?n|`/`|!n|` lend for the statement, as the
  design says. The type node only names what those bindings already are.

Then every consumer is a typed declaration plus a loop the checkers already know:
`acc: (item_type m1) = 0`, `found: (item_type h)? = none`, `out: List[(item_type m1)] = List()`,
`first: (item_type h)? = for ... break x else none`.

### Runner-up: deferred closure typing

A hidden-bound closure typed at its first call (`checkLambdaGiven` with the argument types, at the
call), plus `none` meeting `T` as `T?` in `unify`, plus a std `list_of[T](x: T) -> List[T]` for a
peeled `collect`. It adds no IR kind, but it moves where a closure body is checked (captures
looked up from a saved scope), and it forces a peel on `sum`, `find`, and `collect` too, so the
rewrite grows more templates. I would not.

### Rejected

- **A native chain node**: every checker would learn a second loop. North Star 4 says no.
- **Type text from round 1**: `tyName` prints `Item[?String, ?Entry]`, which a program may
  shadow, and a type reached only through a call's result may have no name in this module at all.
- **Std generic helpers**: a generic body walking view items is the rule-4 problem the design
  already ruled out, and `reduce` today goes through `rig.FnRef`, a fat pointer LLVM must see
  through.

## 2. `trim`, lowered

Source (approved form, with `matches`):

```
oldest = ?@entries.items()
  .filter(|e| e.value.state matches .ready(_))
  .min_by(|e| e.value.touched) ?? break
key = +oldest.key
```

The rewrite replaces the chain, in place, with a loop value (hidden names shown as `‹...›`;
each is a `HiddenName` leaf at a position the consumed text `.filter`/`.min_by` frees):

```
oldest = (while true
  new ‹chain source› = ?@entries.items()
  new ‹stage 1› = |e: (item_type ‹chain source›)| e.value.state matches .ready(_)
  new ‹stage 2› = |e: (item_type ‹chain source›)| e.value.touched
  ‹chain first›: (item_type ‹chain source›)? = for ‹chain item› in !‹chain source›
    if ‹stage 1›(‹chain item›)
      break ‹chain item›
  else
    none
  new ‹chain best› = ‹chain first› ?? break none
  new ‹chain key› = ‹stage 2›(‹chain best›)
  for ‹chain item› in !‹chain source›
    if ‹stage 1›(‹chain item›)
      new ‹k› = ‹stage 2›(‹chain item›)
      if ‹k› < ‹chain key›                # strict: first on ties
        ‹chain best› = ‹chain item›
        ‹chain key› = ‹k›
  ‹chain first› = ‹chain best›
  break ‹chain first›) ?? break
```

Both `for`s are then the `while (!h).next() as x` that `iterWhile` already makes. Written out
by hand with the types spelled (`zig-files/peel.rig`), it runs (`2 60 4`, as the hand loop) and
ownership accepts `key = +oldest.key` then `!@entries.take(key)`: `oldest` is an `Item` that views
`@entries` (`Items.next` is `from @map`, not from the iterator), so it outlives the hidden source.

The Zig emit writes for it (from `rig emit peel.rig`, trimmed):

```zig
const oldest = @as(rig.Opt(prelude.Item([]const u8, *const Entry)), __rig_loop_4: {
    while (true) {
        var h = rig.rt(self.entries.items());
        var f1 = struct { pub fn __rig_invoke(_: *@This(), e: Item) bool {
            return switch (e.value.*.state) { .ready => true, else => false }; } }{};
        var k1 = struct { pub fn __rig_invoke(_: *@This(), e: Item) i64 {
            return e.value.*.touched; } }{};
        const first = @as(rig.Opt(Item), __rig_loop_7: {
            while (true) {
                if (rig.some(h.next())) |e| {
                    if (f1.__rig_invoke(e)) break :__rig_loop_7 rig.pack(rig.Opt(Item), e);
                } else break;
            }
            break :__rig_loop_7 rig.pack(rig.Opt(Item), null);
        });
        const b0 = rig.some(first) orelse break :__rig_loop_4 rig.pack(rig.Opt(Item), null);
        var best = b0;
        var bk: i64 = k1.__rig_invoke(b0);
        while (true) {
            if (rig.some(h.next())) |e| {
                if (f1.__rig_invoke(e)) {
                    const k: i64 = k1.__rig_invoke(e);
                    if (k < bk) { best = e; bk = k; }
                }
            } else break;
        }
        break :__rig_loop_4 rig.pack(rig.Opt(Item), best);
    }
});
const o = rig.some(oldest) orelse break :__rig_while_2;
var key = rig.String.of(.{ o.key });
```

Against the hand loop: the hand loop clones `e.key` on **every new minimum** (`rig.String.of` +
`rig.drop` inside the loop), so its cost grows with the number of improvements (all n when the
map is in falling `touched` order); the chain keeps two pointers and clones once after the scan.
Measured on random order, 2.41 ms vs 2.51 ms; the gap only widens in the bad order. Code size:
the peeled function is about 140 instructions against 58 for the single loop, because the Map's
`next` is inlined twice. That is the price Rust pays too.

## 3. The traps

**Sources.**
- *Iterator* (a made value such as `?m.items()`, or `(!it)`): hold it once (`iterWhile`'s
  `.made`/`.lent`/`.place` cases), and continue it with `for x in !h`. Never call `next()` after
  it gave `none`: the peel leaves at `first ?? break none` before the second loop (a user
  iterator need not be fused).
- *List, array, slice*: do not wrap them in an iterator (the design measured adapter `next` at
  +26%). Peel by index: `for x, i in xs` breaks at the first passing item, the second loop is
  `for x in xs[i + 1..]`, which Zig emits as a plain slice loop. Hold `?xs` when the source is not
  a plain place, so it is evaluated once.
- *Range*: `a..b` is not a value ("a range `a..b` can only be used as a `for` loop source"), so it
  cannot be held. Hold the bounds (`lo = a`, `hi = b`, in that order, once), loop `lo..hi`, then
  `i + 1..hi`; `(item_type lo)` gives the item type. An endless `a..` continues as `i + 1..`.
- *String*: continuing "from index i + 1" is wrong if `i` counts characters and slicing counts
  bytes. Peel a string through its iterator, or do not peel it (the single loop with a typed
  `best: (item_type h)? = none` is correct, only sometimes slower).
- *zip's second source*: evaluated once, after the first; pulled only when the first gave an item
  that passed the stages before `zip`.

**Pulling no item too many.** `take(n)` delivers its n-th item and then stops before the next
`next()`: the counter is tested after the consumer runs, and `take(0)` runs nothing (`while
taken < n and (!h).next() as x`, not a `for` header that pulls first). Its counter spans both
loops of a peel. `find`, `any`, `all` break at once. `skip(n)` drops passing items, after the
stages before it, as Rust's does.

**Closures with captures.** Bind each once, before the loop, in source order after the source;
never inline a body (that would copy `|+n|` per item, re-move `|<r|`, and let the `for` body write
what `|?n|` reads). Bound, the ownership checker sees exactly the design's rule: `xs.map(|!xs, x|
...)` conflicts with the held `?xs`. Two call sites in a peel call the same closure value, so each
item still passes each stage once. Hidden names resolve by text, so each stage needs its own
`HiddenName` (`chain stage 1`, `chain stage 2`, ...), and each use its own position.

**`collect` of views.** Round 1 rejects a view item in the user's terms, with the fix
(`.map(|s| +s)`), before any rewrite; a made value moves into the List (`!out.push(<y)`). The
same check must stop `min_by` keeping an item that views *the iterator* (a user iterator whose
`next` is `from @`): the lowered `best` would outlive the hidden source, and the ownership error
would name `chain source`.

**Failing closures.** `‹stage›(x)!` propagates to the enclosing function: right for `chain!`.
`chain catch |e| h` has no target in place: the handler would be written once per fallible call
site (twice per stage in a peel), and one IR node may not appear twice. Zig has the construct
(`blk: { f() catch |e| break :blk h(e); }`), Rig's IR does not.

**In place, not hoisted.** A chain in a `while` condition, after `and`/`or`, in one branch, or in
a closure must be re-run where it stands: the lowering is a loop *value* in the chain's slot,
never statements hoisted before the statement. Emit already writes a loop value as an
`@as(T, label: { ... })` expression, which Zig accepts anywhere; whether sema and ownership accept
a `while` node in every expression slot (the grammar never puts one there) must be tested first.

**Messages.** Round 1 must report everything a user can get wrong (arity after `enumerate`/`zip`,
a non-Bool `filter`, a key that is not `Ord`, view items to `collect`) in the chain's words,
because any round-2 error names hidden bindings.

## 4. For the owner

1. **The peel is not free of new sema**: a closure bound to a local needs parameter types. Choose
   the type node (my recommendation) or deferred closure typing.
2. **`find` as designed does not type**: `break item` / `else none` is rejected today, and so is
   `if c` / `x` / `else` / `none`. The type node lets the rewrite avoid it, but "`none` meets `T`
   as `T?`" is a two-line `unify` change that fixes a user-visible wart. Default: adopt it.
3. **"A fused chain is the loop, so it costs what the loop costs"** needs a rider: the obvious
   one-loop `min_by` is 1.8x to 3.5x slower than the peeled loop, and the hand loop Rig teaches
   today (`if oldest == none or ...`) is the slow shape. Lower the min family by peeling; the
   chain then beats the hand loop.
4. **`max_by` first on ties** differs from Rust's `max_by_key` (last on ties; `min_by_key` is
   first). AIs trained on Rust will expect last. One character in the lowering (`>` vs `>=`).
   Default: keep first on ties, and say so in STD.
5. **`catch` on a chain** with failing closures needs a fallible block in the IR. Default: ship
   `!` only; reject `catch` with "bind the chain's result in a function that fails".
6. **Loop values in any expression slot** must be accepted by sema and ownership before chains in
   conditions or operands can work. Default: test it first; if it fails, v1 rejects chains there.
