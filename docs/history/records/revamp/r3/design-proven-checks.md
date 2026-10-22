# Design: checks the compiler proves away

Status: design only, nothing built. Base: main b124d5438, assuming the
`forcast` worktree's diff (emit-only, uncommitted) lands first. The
decisions the owner needs to make are listed in §12.

## 0. In one paragraph

A new pass, `src/proofs.zig`, runs after the ownership checker accepts a
module and walks each body in the order the emitted Zig runs. It tracks
three **value facts** about local `Int` bindings and slice views,
`nonneg(i)`, `below(i, k, b)` (`i + k <= b`), and `fits(s)`: a guard on
the path or a check that already ran establishes one, and any write the
source shows kills it. From them it records one **node fact**,
`provenOf(node)`, on each index, byte read or write, and `+`/`+=`: which
of the node's tests are known to pass. Emit reads it through
`facts.zig` and writes the operation without those tests. A debug build
still runs each omitted test as an assertion of the proof, so every
suite, corpus, and matrix run checks every proof it reaches. A test the
pass cannot prove stays, and Rig's guarantees do not change: a test is
omitted only where the program already made it on every path, and
nothing it tested has changed since.

## 1. What is emitted today, and what was measured

| Rig | Zig today | Tests made |
|---|---|---|
| `s[i]`, `s: ?String / []T / ![]T` | `rig.at(s, i)` = `items[index(i, items.len)]` | `i >= 0` (cast), `i < len`; Zig's own `items[...]` test follows, and LLVM drops it after `index` |
| `s.read[T, e](i)`, `!s.write[T, e](i, v)` | `rig.readInt` / `writeInt` → `byteOffset`, then `bytes[i..][0..n]` | `i >= 0`, `i <= len`, `len - i >= n` |
| `a[i]` (`[N]T`); `v[i]` (`List`) | `a[rig.index(i, N)]`; `v.at(i)` | `i >= 0`, `i < len` |
| `i + c`, `i += c` | Zig `+`, `+=` | overflow (safe and debug builds) |
| `s.len` | `rig.len(s.len)` = `@intCast` | `len <= Int.max`, which cannot fail |

The Trig profile (session 633b8e79, `scratchpad/profile/`) measured
bounds checks at 4–11% and overflow checks at 1–11%. Its `proven` patch
made the U64 reads in `skip_plain_ascii` and `skip_space` unchecked
pointer loads and turned the guard's `i + 8` into `i +% 8`; `proven2`
also made `rig.at(s, i)` unchecked in `skip_space`. Together: +2.3–7.1%.

**Not all of that patch is provable, and this design does not
reproduce the rest.** In `take_digits` and `skip_plain_ascii`, `i`
starts as the parameter `at`. The guard's `i + 8` can overflow: with
`at` near `Int.max` the source panics, while `i +% 8` wraps negative,
passes the guard, and the unchecked load reads out of bounds. And
`0 <= i` is never established: with `at = -5` the source panics in
`read`, where the patch read memory before the slice.

Both tests are provable in `skip_space` (§3.4), and in the canonical
SWAR loop that starts at `i = 0`. Code that starts at `at` gets them
once it tests `at` a single time on entry (round 2, §11).

## 2. The facts

### 2.1 Value facts (internal to the pass; emit never sees them)

Facts name bindings by `SymbolId`. Shadowing (`new i`) and
`for`/`as`/`match` bindings are distinct symbols.

| Fact | Meaning | Subjects |
|---|---|---|
| `nonneg(i)` | `0 <= i` | `i` is a local or parameter of type `Int`, declared in the body being walked: not a capture, a view (`!Int`), or a field |
| `below(i, k, b)` | `i + k <= b`, exactly | `i` as above; `k` a constant with `0 <= k <= 2^62`; `b` a bound |
| `fits(s)` | `s.len <= max_len = 2^62 - 1` | `s` names a `len(s)` bound |

A **bound** is `len(s)`, where `s` is a local or parameter of
slice-view type (`?String`, `[]T`, `![]T`; round 2 adds owned `String`,
`List[T]`, and `[N]T`), or `int(n)`, where `n` is a local or parameter
of type `Int` declared in the body. Module constants, `extern` data
(which may change behind Rig's back), fields, captures, and views are
never bounds. For each `(i, b)` the pass keeps only the largest `k`.

### 2.2 Node facts (recorded; emit reads them)

```zig
// sema.zig: one table, written only by proofs.zig
pub const Proven = packed struct(u8) {
    lower: bool = false,       // 0 <= index is known
    upper: bool = false,       // index + width <= len is known
    no_overflow: bool = false, // the `+` cannot overflow
    _: u5 = 0,
};
// facts.zig: a node fact, like lendOf or readsInPlace
pub fn provenOf(f: Facts, node: Sexp) Proven;
```

It is recorded on an `index` node (read or place), an `elemCall`
`read`/`write` callee, a `+`, and a `+=` `set`. A node with no entry is
`Proven{}` and keeps every test, the only way an incomplete pass can
fail. `rig check --facts=proofs` prints each as `L:C kind lower upper
no_overflow` for tests (§8.3).

### 2.3 Who decides

- **`src/proofs.zig` is the only writer of `Proven`.** `modules.zig`
  runs it after `own.check(m.ir)`, only on a `.checked` module, because
  its soundness relies on the ownership checker's acceptance (§4.1,
  point 3). It reads the facts table (`symbolOf`, `typeOf`,
  `elemCallOf`, `scopeOf`) and the write sites, and re-derives none.
- **Write sites are decided once, by the existing classifier.**
  Resolve and typecheck set `SymbolFlags.reassigned`/`.written` at
  every assignment, compound assignment, `!x` lend, field or element
  store, and `<x.f` take (`resolve.zig:406,428,449`,
  `typecheck.zig:4852`). Those flags already choose Zig `var` over
  `const` and gate the `const_ints` fold (`typecheck.zig:1039`). Each
  site also records `ctx.recordWrite(node, sym, kind)` (`assign`,
  `compound(op, rhs)`, `lend_write`, `elem_store`, `take`, `capture`),
  and the flags and the proof pass both read that record.
- **Emit reads `provenOf` at four sites (§6.1)** and decides nothing.

## 3. Proof patterns, round 1

Round 1 is the smallest set that covers the measured loops as far as
they can soundly be covered. Each rule is a positive list: a shape not
listed proves nothing.

### 3.1 What establishes a fact (gen)

**G1. A guard, on its true edge.** The guard is a `while` or `if`
condition part, each part of an `and` chain, or the left operand of an
`and` as its right operand sees it. The guard must have one of these
shapes, written either way round (`b > i`, `b >= i + k`):

| Guard | Gives |
|---|---|
| `i < b` | `below(i, 1, b)` |
| `i <= b` | `below(i, 0, b)` |
| `i + k < b` (or `k + i < b`) | `below(i, k + 1, b)` |
| `i + k <= b` (or `k + i <= b`) | `below(i, k, b)` |
| `i >= 0`, `0 <= i`, `i > 0`, `0 < i` | `nonneg(i)` |

`k` is an integer literal `>= 0`; `b` is written `s.len` or `n` for a
bound (a guard on `s.len` also gives `fits(s)`, G4). The `+` is checked
or itself proven `no_overflow`, both of which compute the exact sum;
`+%` never counts, since `i +% 8 <= n` says nothing about `i + 8`.
Nothing else gives a fact: not `or`, `not`, an `as` part, or a false
edge (round 2).

**G2. A check that ran.** Each statement below gives facts after it
runs. Its value must be exactly the form shown, at the top level: not
under a branch, a ternary, `catch`, `??`, or the right of `and`/`or`.
`T` must be concrete, not a type parameter.

| Statement | Gives |
|---|---|
| `x = s[i]` (a binding or an assignment) | `nonneg(i)`, `below(i, 1, len(s))` |
| `x = s.read[T, e](i)` | `nonneg(i)`, `below(i, size(T), len(s))` |
| `!s.write[T, e](i, v)` (expression statement) | `nonneg(i)`, `below(i, size(T), len(s))` |

Either the check passed or the program already panicked. The facts
are added before the statement's own store, so one that assigns `i`
(`i = s[i]`) keeps none of them.

**G3. A non-negative assignment.** `i = c` (a literal `c >= 0`),
`i = s.len`, or `i = j` with `nonneg(j)`, gives `nonneg(i)`. The
assignment is also a write, so it first kills `i`'s other facts (§4).

**G4. A length read.** Once `s.len` is evaluated on the path, `fits(s)`
holds: emit lowers it through `rig.len`, which round 1 makes test
`n <= max_len` (§6.3), so the margin is a test the program ran.

### 3.2 What a fact proves (uses)

In every row the index is a bare binding `i`. `s[i + 1]`, and `s[j]`
with `j = i`, prove nothing in round 1.

| Node | `lower` when | `upper` when |
|---|---|---|
| `s[i]`, a read or a place, where `s` is a slice-view bound | `nonneg(i)` | `below(i, k, len(s))` with `k >= 1` |
| `s.read[T, e](i)`, `!s.write[T, e](i, v)`, `T` concrete | `nonneg(i)` | `below(i, k, len(s))` with `k >= size(T)` |

`i + c` and `i += c` (`c` a literal, `0 < c <= 2^62`) are
`no_overflow` under `below(i, k, b)` with `k >= c`, any bound
(`i + c <= i + k <= b <= Int.max`), or under `below(i, k, len(s))` and
`fits(s)` with `c > k` (`i + c <= max_len + (c - k) <= Int.max`).

### 3.3 Transfer (a write that keeps a fact)

`i += c` and `i = i + c`, with `c` a literal `>= 0` and the `+` checked
or proven, keep `nonneg(i)`. The add either panics or gives
`i + c >= i >= 0`. Every other fact about `i` dies. `+%=` keeps nothing.

### 3.4 The measured loops under round 1

`skip_space(s: ?String, at: Int)`:

```text
while i < s.len                G1 below(i,1,len s); G4 fits(s)
  c = s[i]                     upper proven; lower kept (i = at); then G2 nonneg(i)
  if c == SPACE and i + 8 <= s.len and s.read[U64, .little](i) == SPACES
    #                 `i + 8`: below(i,1,len s) + fits(s) -> no_overflow
    #                 read: below(i,8,len s) + nonneg(i)  -> both proven
    i += 8                     below(i,8,len s) -> no_overflow
  else if c == SPACE or ...
    i += 1                     below(i,1,len s) from the while guard -> no_overflow
```

Every test in the loop goes except the sign test of `s[i]`, which needs
`nonneg(at)`. That is all of `proven2` except one compare.

`take_digits`, and `skip_plain_ascii`'s 8-byte loop, start at `i = at`:

```text
while i + 8 <= s.len           the guard's `+`: kept (at entry, i = at can overflow)
  d = s.read[U64, .little](i)  upper proven; lower kept
  i += 8                       no_overflow
while i < s.len and is_digit(s[i])     s[i]: upper proven; lower kept
  i += 1                       no_overflow
```

Here round 1 removes one of the read's two compares and the test on
`i += 8` (which LLVM often CSEs with the guard's `sadd.with.overflow`
already). The guard's overflow test and the read's sign test stay,
because both can fire. In the canonical `i = 0; while i + 8 <= s.len:
w = s.read[U64](i); i += 8`, G3 gives `nonneg(i)` and §3.3 keeps it
through the loop's only write (§4.3): the read and `i += 8` are fully
proven, and only the guard's own `+` waits for round 2's header facts.
The SIMD proposal's `blocks(N)` has this exact shape (§9.3).

## 4. Invalidation

### 4.1 Why Rig makes this tractable (Core citations)

The pass must see every point between a guard and a use where `i`,
`n`, or `s` could change. Rig's Core makes each such point visible:

1. **A binding's own value changes only by assigning it** (Core
   sentence 9). For `i` and `n` that is an assignment or compound
   assignment; for `s`, re-pointing the view (Core §6, "View places").
2. **Every other change is marked with `!`.** Core sentence 4: "`?`
   promises that nothing changes", and every write lend is written, "so
   every change is still marked by `!`". A callee changes `i` only
   through a written `!i`: an argument, `w = !i`, or a capture `|!i|`
   (Core §7).
3. **A write view made earlier cannot slip a change in.** Sentence 5
   allows read loans or one write loan, never both; sentence 6 makes a
   loan last until its view's last use. So a `w = !i` or `|!i|` made
   before the guard and used after it makes the guard's read of `i` a
   rejection. Probed on main: `bump = |!i| i += 1; if i < s.len: bump();
   s[i]` and `w = !i; if i < n: w = 5` both give "use of `i` while a
   write loan is live". In an accepted program, every write between
   guard and use is a lend or an assignment that lies between them.
4. **No write path hides in data.** "A write view is never stored
   inside a value" (Core §5, sentence 9), and an owned closure is a
   no-loan home; only a stack closure carries `!i`, and making one is
   the visible `!i` of point 2.
5. **Reads never write.** "A bare name or place only reads" (sentence
   1), and a call passes on only the loans its signature shows
   (sentence 7): `s.len`, `s[i]`, `print(i)`, and a call not given `!i`
   cannot change `i`.
6. **A view's length is part of its value.** A `?String`, `[]T`, or
   `![]T` is a pointer and a length; writing through a `![]T` changes
   elements, never the length, and the viewed storage cannot be freed
   or resized while the view's loan lives (sentences 5 and 6), which
   the use itself keeps live. So `len(s)` changes only when `s` is
   re-pointed.
7. **No mutable module state.** Module-level `K += 1` is rejected, and
   `extern` data is never a bound.

Zig gives a partial cross-check: a binding with no recorded write site
is emitted as a Zig `const`, so a missed write to it fails to compile.
§8.1 covers the rest.

### 4.2 Kill rules (a positive list of write sites, from `recordWrite`)

| Write site | Kills |
|---|---|
| `i = e` | every fact about `i`, and every `below(_, _, int(i))`; G3 may then gen |
| `i op= e`, unless it is the next row | every fact about `i` |
| `i += c` or `i = i + c`, `c` a literal `>= 0` | every fact about `i` except `nonneg(i)` (§3.3) |
| `!i` in any form (argument, binding, receiver, capture `\|!i\|`); `<i` | every fact about `i` |
| `s = e` (re-point), `<s` | `fits(s)`, and every `below(_, _, len(s))` |
| `!s`, `!s[..]`, `s[j] = x`, `!s.write`, where `s` is a slice view | nothing, because a view's length cannot change (§4.1, point 6). This matters: `!s.write[T](i, v)` must stay provable from facts established before it |
| a `raw` block, at its exit | every fact. Nothing inside `raw` is proven: raw is "the boundary of what the checker guarantees" (SPEC §15), and later raw pointers will alias |

Round 2's owned containers add one positive list of length-changing
writes, which kill `len(v)`: `!v` passed to any call other than the
length-keeping element calls (`read`, `write`, `copy`, `fill`, `swap`),
`w = !v`, `|!v|`, `<v`, and `v = e`.

### 4.3 Kills that depend on control flow

- **Loops (re-entry after a modification).** On entering a `while` or
  `for`, kill every fact about a binding with a write site anywhere in
  the loop: its condition parts, its body at any depth (closure
  literals included, since `|!i|` is a write), its `defer` and
  `errdefer` bodies, and its step. The one exception is `nonneg`,
  which survives `+= c` (§3.3). A fact from before the loop therefore
  survives only when nothing in the loop can change it, and round 1
  needs no fixpoint. Inside the body, facts come from the loop's own
  guard (run each iteration) and from G2 and G3.
- **The step**, and a `continue` to it, see the body's starting facts
  minus every kill in the body.
- **Joins** (`if`/`else`, `match`, ternary, `catch`, `??`, a labeled
  block, a loop and its `else`): afterwards the facts are those from
  before the construct, minus every kill inside it. Facts gained in a
  branch die at the join. False edges and noreturn branches come in
  round 2.
- **Jumps.** After `return`, `break`, `continue`, or the failing path
  of `e!` or `e?`, the rest of the block is unreachable.
- **Defers.** Leaving a scope, normally or by a jump, applies the kills
  of each `defer` registered in it at that exit (Core §7; the ownership
  checker's `runDefers` does the same). A defer that has not run yet
  kills nothing.
- **Closures.** A closure body, and a nested `fun`, start with no
  facts. A capture is never a subject or a bound.
- **Assignment order.** The value is walked first, then the target's
  indexes, then the store (INTERNALS, "Assignments"; Core §6). In
  `a[i] = next(!i)` the `!i` kills before the target index is reached.

## 5. The walk mirrors the emitted control flow

"The checker checks exactly what is emitted" binds this pass as it
binds the ownership checker. Loops are walked per INTERNALS "Loops"
(condition parts `else break`, the body's scope, the step placed by
`sema.stepReadsBinding`, `continue` to the step), iterator `for` loops
after `desugarIterLoops`, a range `for` as `var c = a; const e = b;
while c < e : c += 1`; an assignment's value before its target; `and`
and `or` left to right; a call's receiver, then arguments left to
right; defers at their scope's exits. A unit test walks every program
in `test/behavior/emit/` and checks that the pass visits leaves in the
order the emitted Zig has them, so the walk cannot drift silently (as
`facts.zig`'s import test guards emit's imports).

## 6. Emit and runtime

### 6.1 Emit (four sites)

(1) `emitIndex`, slice branch: `rig.at(s, i)` as today when
`Proven{}`, else `rig.atProven(s, i, .lower | .upper | .both)`, and
`elemPtr` likewise. (2) The `read`/`write` element calls: the same
trailing compile-time argument on `rig.readInt`/`writeInt`. (3)
`emitInfix` `+` with `no_overflow`: `rig.addProven(a, b)`. (4)
`emitCompound` `+=` on a name with `no_overflow`:
`i = rig.addProven(i, c);`, which reads `i` once, as `+=` does. Array
and List paths are unchanged in round 1; emit's
`isNonNegativeIntLiteral` shortcut stays until round 2 folds it into
`provenOf`.

### 6.2 Runtime

```zig
pub const Proven = enum { lower, upper, both };
pub inline fn atProven(items: anytype, i: Int, comptime p: Proven) Elem(...) {
    return items.ptr[provenIndex(i, items.len, 1, p)];
}
fn provenIndex(i: Int, count: usize, width: usize, comptime p: Proven) usize {
    @setRuntimeSafety(false);
    const lo = p != .upper; const hi = p != .lower; // which tests are known
    if (i < 0) if (!lo) indexPanic() else if (verify_proofs) proofPanic();
    const idx: usize = @intCast(i); // exact: 0 <= i <= count
    if (idx > count or count - idx < width) if (!hi) indexPanic() else if (verify_proofs) proofPanic();
    return idx;
}
pub inline fn addProven(a: Int, b: Int) Int {
    if (verify_proofs) _ = std.math.add(Int, a, b) catch proofPanic();
    @setRuntimeSafety(false);
    return a + b; // `add nsw`
}
const verify_proofs = builtin.optimize == .debug or build_options.verify_proofs;
fn proofPanic() noreturn { @panic("rig: a proven check failed (compiler bug)"); }
```

The helper indexes through `.ptr` because `items[idx]` carries Zig's
own test, which LLVM cannot remove without the fact. The add is
`add nsw` rather than `+%`, which gives LLVM's induction analysis the
no-wrap fact; `+%` would hide it. An unproven half panics with today's
message ("index out of bounds", "byte read out of range"). With both
tests proven, `readInt` loads `@as(*const [n]u8, @ptrCast(bytes.ptr +
i)).*` through today's `@Vector` bitcast. `verify_proofs` is on in
every debug build (`rig run`, `./test/run`, the corpus, the matrix),
and off under `--release` unless `RIG_VERIFY_PROOFS=1` turns it on for
the deep gate's release grids.

### 6.3 `rig.len`, and build modes

`len(n)` becomes `if (n > max_len) @panic("length out of range");
return @intCast(n);` with `max_len = 2^62 - 1`: one shift-and-test on
64-bit targets, the cost of the `@intCast` test it replaces, and
nothing on 32-bit ones. No target holds 2^62 bytes, so it cannot fail;
it makes `fits(s)` a test the program ran rather than an axiom.
(`String.length()` follows in round 2.) `--release` omits proven tests
and keeps all others; `--release=fast` keeps Rig's index tests minus
the proven ones; debug makes every test, the proven ones as
assertions. SPEC's sentence on indexing gains the qualifier in §10.3.

## 7. Soundness argument

**Claim.** If `provenOf(node)` marks a test as known, it passes on every
execution that reaches the node.

**Argument.** (1) *Every fact held at a point is true there.* Each is
true where made: G1 is the guard's meaning on its true edge (a checked
or proven `+` is the exact sum), G2 holds because the check passed or
the program stopped, G3 is arithmetic, G4 is the `rig.len` test. A fact
names only bindings, so only a write to one can falsify it, and every
write is seen: straight-line ones through `recordWrite` (§4.1, points
1–5), earlier iterations through the loop rule, other branches through
the join rule, deferred ones through the exit rule, `raw` through the
raw rule. An unseen write would need a write view made before the guard
and used after it, which the ownership checker rejects (§4.1, point 3);
the pass runs only on accepted modules. (2) *Each use is arithmetic*:
§3.2 states each inequality in `i64`, with `max_len = 2^62 - 1` and
`k, c <= 2^62`. (3) *The omitted test is the source's*: exactly what
`rig.at`, `byteOffset`, or Zig's `+` tests; the unproven half is still
made, with the same message, at the same point.

**Risks, in order.** (1) **The top risk: a write the classifier
misses, or a path the walk does not model**, from a future feature that
writes a binding without `recordWrite` or emits a loop desugaring or
exit the walk does not mirror. Defenses: positive lists (an unknown
shape proves nothing), the walk-order test (§5), the Zig `const`
cross-check, and above all the debug assertion (§8.1). (2) A wrapping
operator or a view read as a guard: excluded by the positive list
(§8.2 #9, #22). (3) The length bound: a check replaces an assumption
(§6.3).

## 8. Test plan

### 8.1 The dynamic oracle

Every proven test still runs in debug builds and panics with "rig: a
proven check failed (compiler bug)" if it would fail. That makes the
whole suite (2,626 tests, 6,021 corpus probes, 3,070 matrix programs) a
check of the proofs. "Runs clean" gains "and no proof assertion
fires", and `test/run` fails on that message even where a panic is
expected.

### 8.2 Adversarial programs (`test/behavior/proofs/`, each `# release` + `# expect-panic`)

Each must keep its test, panic with today's message in debug and in
`--release`, and be absent from `--facts=proofs`. Values are chosen so
that the use is out of range exactly when the mutation runs.

| # | Shape (guard / mutation / use) | Keeps |
|---|---|---|
| 1, 2 | `if i < s.len` / `i += 1` / `s[i]` (i = len-1); `if i < a.len` / `bump(!i)` / `a[i]` | upper |
| 3, 4 | `if i < a.len` / `a[i] = next(!i)`; `if i < s.len` / `f = \|!i\| i += 1; f()` / `s[i]` | upper |
| 5, 6 | inner block with `defer i += 1`, then `s[i]`; guard before a loop that does `s[i]` and `i += 1` | upper |
| 7, 8 | `s = t[..]` (shorter) after the guard; guard on `t.len`, use on shorter `s` | upper |
| 9 | `while i +% 8 <= s.len` / `s.read[U64](i)`, i = Int.max-3 | lower, upper |
| 10, 11 | `i = Int.max-3; while i + 8 <= s.len`; `i = -5;` same loop with `s.read[U64](i)` | guard overflow; lower |
| 12, 13 | `if i < s.len or flag` / `s[i]`; `if i < s.len` … `else` / `s[i]` | upper |
| 14, 15 | `new i = i + 1` / `s[i]`; `fun f[T]`, `if i + 4 <= s.len` / `s.read[T](i)` at U64 | upper |
| 16, 17 | `raw` block assigning `i`; `i = n = Int.max; if i <= n` / `i += 1` | upper; overflow |
| 18, 19 | `c = s[i]; i -= 1; s.read[U8](i)` (i = 0); `while i < n : i += 1` with body `i += 5; continue` | lower; step overflow |
| 20, 21 | `while i < s.len` … `else` / `s[i]`; `if i + 8 <= s.len` / `s.read[U128](i)` | upper |
| 22, 23 | `if self.i < s.len` / `(!self).bump()` / `s[self.i]`; a `match` arm writes `i`, `s[i]` after | upper |
| 24 | `n = s.len; if i < n` / `n -= 2` / `s[i]` | upper |

Each one has a **control twin** without the mutation. The twin runs
clean, prints its value, and is listed in `--facts=proofs`.

### 8.3 Shape checks

The contract is the dump: `test/cli/facts_proofs.sh` compares
`rig check --facts=proofs` line by line on `test/behavior/proofs/swar.rig`
(copies of `skip_space`, `take_digits`, `skip_plain_ascii`, and the
canonical `i = 0` loop, with expected output). `test/cli/emit_shapes.sh`
adds `forcast`-style checks: `rig.readInt(u64, s, i, .little, .both)`
and `rig.addProven(i, 8)` appear, and `rig.at(s, i)` remains where the
sign is unknown. `test/equiv.py` against the base compiler shows `emit`
and `pkg` differences only at proven nodes, none in `--facts=sema` or
`--facts=storage`.

### 8.4 The `proof.` grid in `test/matrix.py`

```text
GUARDS    while/if i < s.len | while/if i + 8 <= s.len | if 0 <= i and i < s.len | c = s[i]
          | s.len > i | negative: while i +% 8 <= s.len, if i < s.len or f
MUTATIONS none | i += 1 | i = i + 1 | i = s.len | bump(!i) | |!i| made and called | inner defer
          | a[i] = next(!i) | s = shorter[..] | one if branch | a match arm | enclosing loop
          | raw | new i | continue to a step that writes i
USES      s[i] | s[i] = x | s.read[U64](i) | !s.write[U32](i, v) | i + 1 | i += 1 | i + 8
PLACES    straight | nested if | right of `and` in the guard
```

Each cell sets `i` so that the use is in range exactly when the
mutation does not run. A `none` cell must run clean in debug (no proof assertion fires),
print the same in `--release`, and appear in `--facts=proofs` exactly
when the generator's own table says so. That table is a positive copy
of §3.2, so the doc and the pass cannot drift apart. Every mutation
cell must be unproven and panic with today's message, identically in
debug and `--release`. The full product is 9 × 15 × 7 × 3 = 2,835
cells; every (guard, mutation) pair with all uses at `straight`, plus
the other places for `none` only, is about 700, the fast gate's
targeted grid. The full grid runs in the deep gate.

### 8.5 Unit tests (`proofs.zig`)

The guard and kill tables row by row; each near-miss proves nothing
(`i - 1 < n`, `i < n + 0`, `i * 1 < n`, `+%`, a `U64` `i`, a capture, a
field); and the walk-order test (§5).

## 9. Interactions with work in flight

### 9.1 `forcast` (lands first)

`forcast` binds a `for` index as `@as(isize, @bitCast(counter))`. That
relies on Zig's counter staying below a length, which is at most
`maxInt(isize)`. It is a fact about how the loop is built, not a test
the source makes, so it remains an emit-local lowering. It touches
`bindLoopIndex`, and this design touches the index, element-call, and
`+`/`+=` paths, so the two do not conflict. This design rebases on it.

Round 2's `for` facts reuse forcast's argument. `for x, k in s`, with
`s` a slice-view bound, gives `nonneg(k)` and `below(k, 1, len(s))`
unless `s` is re-pointed in the loop. `for k in a..b` gives `nonneg(k)`
when `nonneg(a)`, and `below(k, 1, b)` when the loop does not write the
bound `b`. The range's emitted step `c += 1` becomes `rig.addProven`,
since `c < e` holds there by construction (Rig code cannot write the
hidden counter). `for c, k in s[i..]`, as in `skip_plain_ascii`, needs
the relational fact `i + k < s.len`, which is round 3.

### 9.2 Bit intrinsics and `<<%` (`bits`, not started)

Wrapping operators never make facts: `+%`, `-%`, `*%`, and the new
`<<%` are on no positive list, so a guard built with them proves
nothing (§8.2 #9); `<<%`'s amount test (below the width) is untouched.
Intrinsic results (`trailing_zeros`, `leading_zeros`, `count_ones`)
get no facts in rounds 1–2. Round 3 may add `range(x, lo, hi)`:
`x.leading_zeros()` is in `0..=W`, so `i + m.trailing_zeros() / 8`
cannot overflow under `below(i, 8, len(s))`, and `m << m.leading_zeros()`
loses no set bit (`@shlExact`'s exactness test can go), while its
amount test still needs `m != 0` (`clz(0) = W` must still panic).
Trig's +10.9% from `clz` on canada is the intrinsic's, not this
design's.

### 9.3 SIMD loads (`~/Data/Code/trig/docs/simd/PROPOSAL.md` §4.1)

- **`s.read[Simd[U8, N]](i)`** is the same `read` call with
  `size(T) = N`: U2 applies, and the proven load skips `byteOffset`.
- **`blocks(N)`** (`k = 0; while k + N <= bytes.len : k += N;
  v = bytes.read[Simd[U8, N]](k)`): round 1 proves the read (G3 +
  §3.3, G1) and the step; the guard's `k + N` waits for round 2. This
  holds only because `blocks` desugars into Rig IR the pass walks.
- **`read(at, pad: p)`** needs `nonneg(at)` and `below(at, 0, len)`;
  its in-range branch is `pad:`'s semantics, not a safety test, and
  with `below(at, N, len)` proven emit may write the direct load alone
  (round 2, with SIMD). Per-lane overflow is out of scope.

## 10. Doc text

### 10.1 INTERNALS: "Proven checks" (under Sema, after "Storage facts")

> A check is the test an operation makes before it acts (`s[i]`:
> `0 <= i`, `i < s.len`; `s.read[T, e](i)`: `0 <= i`,
> `i + @size(T) <= s.len`; `i + c`: the sum fits). The proof pass
> (`src/proofs.zig`), on a module the ownership checker accepted,
> records which of a node's tests already passed (`provenOf`): a guard
> or a check that ran made the same test on every path to it, and
> nothing it named was written between. It walks in emit's order
> ("Loops", "Assignments", defers at scope exits), reads typecheck's
> write sites (`recordWrite`), and its guards, checks, and uses are
> positive lists. As a desugaring:
>
> ```text
> s[i]   ==>  test 0 <= i unless lower is proven; test i < s.len unless upper is proven; s.ptr[i]
> i + c  ==>  test that i + c fits unless no_overflow is proven; i + c
> ```
>
> An omitted test is one the program already made, so the program means
> what it meant. A debug build still makes it, as an assertion ("a
> proven check failed"), so every test that runs checks the proofs it
> reaches.

### 10.2 CORE: a bullet for §9, "Inside the compiler" (needs owner approval)

> - **Per check, one fact:** whether an index, byte read, or integer
>   `+` is known to pass. It is, when a guard or check made the same
>   test on every path to it and nothing it tested was written in
>   between. A binding changes only where an assignment or a `!` says so
>   (sentences 4 and 9), so the compiler sees every write. *(planned)*

That is the only Core text. The rule decides which tests are written
out, not anything about ownership. It leans on Core sentences 1, 4, 5,
6, 7, and 9, and changes none of them.

### 10.3 SPEC

In §1, "Indexing and slicing stay checked in every mode" gains: "; a
test the compiler proves already passed (a guard or an earlier check
made it on every path, and nothing it tested changed since) is not
repeated."

In §2, add: "A length read as an `Int` is below 2^62; a longer one
panics (no target holds one)."

## 11. Rounds, effort, scope

**Round 1, `proven-checks`: about 4 agent-days, plus a review round.**

`recordWrite` with the flags derived from it (`--facts=sema`
unchanged as the guard), about 80 lines; `src/proofs.zig` with its unit
tests, about 700; the `Proven` table, `provenOf`, and `--facts=proofs`,
about 60; emit's four sites, about 60; the runtime helpers and
`rig.len`, about 90; tests (§8.2's 24 pairs, §8.3, the `proof.` grid),
about 600; the INTERNALS and SPEC text, and the CORE bullet once
approved.

**Round 2, `proven-checks-2`: about 4 agent-days.**

- **False edges, noreturn branches:** `return x if i >= n` leaves
  `below(i, 1, n)`; `return at if at < 0` leaves `nonneg(at)`.
- **Loop-header facts by fixpoint, with a shift rule:** under
  `below(i, k, b)`, `i += c` gives `below(i, k - c, b)`. The guard's own
  `i + 8` is then proven when entry and back edges both give
  `below(i, 0, len(s))`. `take_digits` and `skip_plain_ascii` then lose
  every test in their 8-byte loop, provided they test `at` once per
  call (e.g. `return at if at < 0 or at > s.len`): one test per call
  instead of per 8 bytes. **That line is Trig's to write; Rig cannot
  assume it.**
- **Equalities:** `n = s.len` lets `int(n)` stand for `len(s)` while
  neither is written (Trig's `plain` and `document` need it).
- `for` index and range facts (§9.1); owned `String`, `List[T]`, and
  `[N]T` as bounds (§4.2's length-changing list, emit's List and array
  paths); `i - c` under `i >= c`; `s[i + c]` under `below(i, k, len)`
  with `c < k`; `s[i..i + k]`; folding `isNonNegativeIntLiteral` into
  `provenOf`.

**Round 3, only if measurement asks for it:** fields such as
`self.pos` (killed by any `!self` call); relational facts, for
`for c, k in s[i..]`; bit-intrinsic ranges (§9.2); `pad:` direct
loads.

**Deliberately out of scope:**

- **Interprocedural facts:** a parameter starts with no facts.
- **Loop rotation, versioning, or hoisting checks:** heroics that move
  panics earlier or duplicate the guard, which emit must not do. LLVM
  may still do them, helped by `add nsw` and the `rig.len` bound.
- Merging `rig.index`'s two compares (measured −1 to −4%, `idx1`);
  `--release=fast` changes; unchecked `raw` indexing; tests on `*`,
  shifts, `/`, and conversions (except the range step and round 3's
  intrinsics); slicing tests until round 2; SIMD per-lane overflow.
- **Concurrency:** Rig has no threads; `*T` and `Cell` values are
  already excluded as bounds, and §4.1 must be revisited if threads
  arrive.

**Expected gain.** The measured +2.3–7.1% includes two tests that can
fire. Round 1 recovers `skip_space`'s share and the read's upper
compare elsewhere; round 2, with Trig's one entry test per helper, the
rest. Re-measure each round; do not quote the patch.

## 12. Owner decisions

1. The CORE bullet (§10.2).
2. The `rig.len` bound of `2^62 - 1` and its SPEC line (§6.3, §10.3).
   Without it, `skip_space`'s `i + 8` keeps its test, and the rest of
   the design is unaffected.
3. Whether proof assertions run in every debug build (this design's
   choice; a debug build then costs what it costs today) or only under
   `./test/run`.
4. Trig's entry test for round 2 (§11): a choice in Trig's source that
   the compiler will never assume.
