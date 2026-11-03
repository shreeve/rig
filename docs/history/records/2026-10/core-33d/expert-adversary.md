# Row 33D, draft 1: the adversary's review (programs)

Against main ad5d9b043 (`~/Data/Code/worktrees/rig/core-33d-read/bin/{rig,rig-oracle}`), every
program run with `RIG_SANITIZE=1`. Programs: `/private/tmp/claude-501/adv33d/` (`m/` main's own
bugs, `h/` emit's late reads, `g/` loops and guards, `p/` t05, `q/` operators, `e/` emit order).
Each one, with main's and the oracle's verdict, is in the appendix.

The rule is not built, so "draft" below is a prediction from its clauses read literally. Where
the draft would accept a program main rejects, I took the emitted Zig of the accepted sibling
(the same program with the view taken of a second list `u`), changed only `&u` to `&v` in the
binding's line, and ran that Zig with the program's own runtime and the sanitizer on. The rest of
the emitted file is unchanged, so this is the program emit would build if the checker accepted it.

## Verdict

The direction is right, and CORE and the oracle agree with it. But the draft's premise, "where
emit reads is the point", is not what emit does in three places, and in one of them main is
already unsound today. Read literally, the draft accepts six programs that read freed memory:
the h-group of section 2 (five shapes, demonstrated) and the `for` source of section 3
(demonstrated). Main has a seventh family it accepts today (section 1). Two of the draft's claims
are wrong: what keeps t05 rejected, and how many `eq` lines it gains.

## 1. Main is unsound today: a branch before its condition (m/)

`walkIf` walks a condition as its own statement (`walkStmt(cond)`). `holderLive` then measures
liveness from the condition's first position. A use in the then-branch lies *before* the
condition in the source, so it counts as behind, but it runs after the condition. All of these
are accepted by main, read freed memory under the sanitizer, and are rejected by the oracle
(`DIFF ... prod=accept ref=reject C4`):

| Program | Shape |
|---|---|
| `tern2` | `r = ?v[0]` then `print(r.n if bump(!v) > 0 else 0)` |
| `tern3` | `x = r.n if bump(!v) > 0 else 0` |
| `tern4` | `x = r if bump(!v) > 0 else Item(n: 5)` |
| `sif` | `print(r.n) if bump(!v) > 0` (a guard, SYNTAX "Guards") |
| `ret` | `return r.n if bump(!v) > 0`, and `n = r.n if bump(!v) > 0` |
| `mv` | `print(r.n) if take(<v) > 0`: a move, not a write |
| `tern1` | `w = !a` then `print(w + 0 if poke(!a) > 0 else 0)`: prints 101, not 1 |

The same is true at dcf3c146d (2026-10-25), 1986bcd44, and 928b44bf2: it is old, not 33C's.
No case in the suite has this shape (an oracle DIFF fails the run), which is why it was missed.

For the draft: its "set of walked positions" fixes this only if the set belongs to the whole
statement. As written ("within the statement being walked ... or it has a use after the
statement"), the statement being walked is the condition, and the then-branch's use is neither in
it nor after it. So the draft keeps accepting these. Its claim "nothing accepted today is
rejected" must also change: these must become rejected, and the release notes list them.

## 2. Emit reads a "pure" argument late (h/): wrong acceptances

`storage.isPureArg` calls a fixed local (`x =! e`) pure: "reads nothing a later argument could
change". That holds only while the binding's loan lasts the statement. Emit then reads a pure
operand at the call or the store, after operands that come later in the source:

- **Keyword arguments in another order** (`hoistsArgs` sees one non-pure argument, so it does not
  hoist): `f(b: r, a: bump(!v))` emits `f(bump(&v), r.*)`.
- **A hoisted call** (`emitHoistedCall` skips pure arguments): an owned argument before one that
  can leave (`g(String("x"), r, bump(!v)!)`), or a closure literal lent to the call
  (`apply(r, |x| x + 1, bump(!v))`), emits `__rig_arg_2 = bump(&v); ... g(..., r.*, __rig_arg_2)`.
- **An assignment** (`openAssign` does not hoist a pure value): `xs[bump(!v)] = r` emits
  `{ const ix = bump(&v); xs.slot(ix).* = r.*; }`, and `xs[bump(!v)] += w` the same.

With `r =! ?v[0]` (`v: List[Item]`) or `w =! !v[0]` (`v: List[Int]`), the draft reads `r` "as its
value" (a plain object copied, or a scalar), so it is used where it stands. The checker walks it
first, it is dead, and the later `!v` is allowed. Emit reads `r.*` after `bump` has grown `v`:

| Program | Main | Oracle | Draft | Emitted, run |
|---|---|---|---|---|
| `h1_kw` `print(f(b: r, a: bump(!v)))` | reject | accept | accept | use of freed memory at `r.*` |
| `h2_own` `print(g(String("x"), r, bump(!v)!))` | reject | accept | accept | use of freed memory |
| `h4_set` `xs[bump(!v)] = r` | reject | accept | accept | use of freed memory |
| `h5_lam` `print(apply(r, \|x\| x + 1, bump(!v)))` | reject | accept | accept | use of freed memory |
| `h6_wint` `w =! !v[0]; print(f(b: w, a: bump(!v)))` | reject | accept | accept | use of freed memory |
| `h8_comp` `xs[bump(!v)] += w` | reject | accept | accept (same emit path) | same shape as h4 |

The oracle accepts all of them, as it accepts the `arg_then_write` matrix: it is no guard here.
Siblings that are safe: a constructor keeps source order (`Pair{ .b = r.*, .a = bump(&v) }`,
`h3`); a temporary receiver held in a slot does not hoist (`h7`); results are hoisted with no pure
skip; array literals skip pure elements, but no owning element type copies from a view.

Side finding, also on main: `h1_nf_ok` (`r = ?u[0]`, not fixed, `f(b: r, a: bump(!v))`) emits
`const __rig_arg_5_0: *const Item = r.*;` and fails in Zig (North Star 1).

## 3. A `for` source is used by every iteration (g/)

The draft puts "a for's held copy" under (C): "used by its header ... then only by its drop", and
its consumption rule shrinks a node's loans to what its value carries. A loop over a view reads
the source on every iteration; Zig's `for (r.*.items()) |x|` captures the slice once. Today the
header's loans are kept to the end of the `for` statement, which includes its body.

- `for1b`: `for x in all(?v)` (`all` returns its `?List[Item]`), body `k = x.n` then 64 pushes.
  The element `x` is dead before the push. If the header's loans are carried only by `x`, or end
  with the header, the draft accepts. The emitted loop reads freed memory on the next iteration.
- `for3`: `r = ?v; for x in r`, the same body. If header uses count once, before the loop (which
  t05 needs, section 4), `r` is dead at the body and the same read of freed memory follows.

Main and the oracle reject both ("carried by the `for` source").

## 4. The draft's claims

- **t05.** The draft's probe `p/t05.rig` is not the difference line's program (no branch, no write
  in the body); it is accepted on main already. The real one (`t05r`) and a form with no branch
  and no held copy (`t05s`, `for x in a.arr`) are rejected the same way. The reason is the loop
  rule: `ctx.start` is the `for` node's first position, so `a`'s use in the header counts as a use
  in the loop. Copied out first (`arr = a.arr`, `t05c`), it runs. So (C) does not gain t05. A
  rule that does must say a `for` header runs once, before the loop (a `while` condition and step
  do not: `t05w` must stay rejected), and section 3 must hold at the same time.
- **The eight `eq` lines.** By the draft's own clause, "a view of a plain object, array, or
  optional is kept as a view, so `==` reads it at the operator", `w` in `plain.eq.write_view` and
  `array.eq.write_view` (and their `destructure_write` lines) is used until `==` yields, after `a`
  is read: rejected. The draft gains 4 lines, not 8.
- **d3's reason.** Emit copies a plain object or array at the operand: `rig.eql(r.*, bump(&a))`,
  `rig.eql(w.*, a)` (`q/d3s`, `q/eqp`). Zig copies there too, also at -O ReleaseFast
  (`z/elide.zig`). So d3 is safe if accepted. What `==` reads in place is a `?String` or a List,
  which emit passes as a slice or a pointer: `rig.eql(z, ...)`. The classifier the draft wants is
  "emit dereferences at the operand" (`sema.copies` of the pointee, minus views that stay
  pointers), not `readsAsValue`. Today it is only stricter. It matters for the gain count above,
  and for d3, which could become an accepting test.
- **Match guards.** `guard1`: an earlier arm's guard writes `v`, and a later arm binds the payload.
  Emit runs every guard while it picks an arm, then binds the payload in the arm's body. The held
  subject must count the later arms' patterns and the chosen body as later uses. Main and the
  oracle reject it, and it must stay rejected.
- **Safe forms checked.** `!v.push(r)` with `r = ?v[0]` (`pp`, at 1 to 64 elements, across each
  growth): emit copies `r.*` before the call, and the run is clean. `ternary`, `??`, `catch`, `e!`,
  `e?`, `String(...)`, and `print` all evaluate in source order (`e/ord.rig`). An assignment's value
  goes before its target (`e/tgt*.rig`).

## Fixes the draft needs

1. **Name emit's read points as facts the checker reads, and adopt them.** A pure argument
   (`isPureArg`) that emit reads at the call (a reordered or hoisted call) is used until the call
   starts. An assignment's pure value is used until the store. Or, simpler and closer to CORE:
   make `isPureArg` false for a name that reads through a view held as a pointer, so emit
   evaluates it in turn. That changes emit, so `tools/emit-diff` will not be identical, and the
   json and hash guards apply.
2. **Unwalked uses are counted per outermost statement,** across headers walked as statements
   (`walkStmt(cond)` in `walkIf`, guards). This is a bug fix on main that should land first and
   on its own, with the `m/` cases. Then "nothing accepted today is rejected" becomes "these
   unsound programs become rejected".
3. **A `for` source's loans last the whole loop,** whatever carries them (a place source's hidden
   var, a call result's loans, a view binding read in the header). Drop "a for's held copy" from
   (C), or restrict (C) to a copy that carries no loans. Gaining t05 needs a separate clause: a
   `for` header runs once, before the loop, and a `while` condition and step do not.
4. **A held subject is used through every later arm's guard and pattern, and the chosen arm's
   body,** in emit's order of selection and then the body.
5. **Correct the gains:** t05 is not gained by (C), and the `eq` lines are 4 unless the operand
   classifier follows emit (fix 6).
6. **The operand classifier is "emit dereferences here"** (`copies` of the pointee, never a
   `?String`, a slice, or a List). Then d3 and the plain/array `eq` lines are accepted, safely.
7. **The oracle**: it accepts every h-program. Teaching it §6 does not catch them, because CORE
   says the argument is read where it stands. The guard is fix 1, and sanitizer runs of the h-cases.
8. **Structural temps** (`held_read`, `place_hold`, `reserved`) end when their reader finishes
   (the call or the operator), never when the argument node finishes.

## Proposed tests

**Must be rejected** (`fail`): h1_kw, h2_own, h4_set, h5_lam, h6_wint, h8_comp; tern1 to tern4,
sif, ret (both functions), mv; for1b, for3, for2; guard1; t05w; a2, b2, d1; `z == mk(!t)` with
`z = ?t` (a `?String`); `print(w.items, bump(!v))` with `w = !v[0]` and a List field.

**Must be accepted and run clean** (`test`): b1, c1, c2, c3, write_result_whole,
match_arm_writes, int and simd `eq.write_view`/`destructure_write`, review-results-v07;
`!v.push(r)` with `r = ?v[0]` at a growth point (`pp`); `print(firstw(!v).n, v.len)`; with fix 6,
d3 and the plain/array `eq` lines; with fix 3's clause, t05r and t05s.

## Appendix: programs, main, oracle, prediction

Main is `rig run` with `RIG_SANITIZE=1`; oracle is `rig-oracle --sema -v`, the `main` line. "Draft"
is the prediction. "Patched emit" is the sibling's Zig with `&u` changed to `&v`, run.

| Program | Main | Oracle | Draft | Note |
|---|---|---|---|---|
| m/tern1 | accept, prints 101 | reject C4 | accept (as written) | wrong value |
| m/tern2 | accept, use of freed memory | reject C4 | accept (as written) | main bug |
| m/tern3 | accept, use of freed memory | reject C4 | accept (as written) | main bug |
| m/tern4 | accept, use of freed memory | reject C4 | accept (as written) | main bug |
| m/sif | accept, use of freed memory | reject C4 | accept (as written) | main bug |
| m/ret | accept, use of freed memory | reject C4 (`f` and `main`) | accept (as written) | main bug |
| m/mv | accept, use of freed memory | reject C4 (move) | accept (as written) | main bug |
| h/h1_kw | reject | accept | accept | patched emit: use of freed memory |
| h/h2_own | reject | accept | accept | patched emit: use of freed memory |
| h/h3_ctor | reject | reject C4 | accept | emit in source order: safe |
| h/h4_set | reject | accept | accept | patched emit: use of freed memory |
| h/h5_lam | reject | accept | accept | patched emit: use of freed memory |
| h/h6_wint | reject | accept | accept | patched emit: use of freed memory |
| h/h7_recv | reject | accept | accept | slot receiver, no hoist: safe |
| h/h8_comp | reject | accept | accept | same emit as h4 |
| h/h1_nf_ok | accept, Zig type error | accept | (same) | emit bug, North Star 1 |
| h/push_own | reject | accept | accept | `pp`: clean at every growth |
| g/for1, for1b | reject | reject C4 (for source) | accept if header loans end | patched for1b: use of freed memory |
| g/for2, for3 | reject | reject C4 (for source) | accept if header uses go before the loop | patched for3: use of freed memory |
| g/guard1 | reject | reject C4 | must stay rejected (fix 4) | |
| g/guard2 | accept | accept | accept | emit order of selection |
| p/t05r (the line) | reject | accept | reject (loop rule) | draft says "probably" accepted |
| p/t05s | reject | accept | reject | no branch, no held copy |
| p/t05c | accept | accept | accept | copied out first |
| p/t05w | reject | reject C4 | reject | `while` condition |
| q/d3s, q/eqp | accept | accept | accept | `rig.eql(r.*, ...)`: copy at the operand |
| e/ord, e/tgt, e/tgt2 | accept | accept (tgt2 unknown) | accept | emit order matches walk |
| draft p/b2, d1, a2 | reject | b2 and d1 reject; a2 accept | reject | as the draft says |
| draft p/b1, c1, c2, c3, d2 | reject | accept | accept | safe: read before the call starts |

### Program text

#### m/tern1.rig

```rig fragment
fun poke(a: !Int) -> Int
  a += 100
  a

sub main()
  a = 1
  w = !a
  print(w + 0 if poke(!a) > 0 else 0)
```

#### m/tern2.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  v.len

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  r = ?v[0]
  print(r.n if bump(!v) > 0 else 0)
```

#### m/tern3.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  v.len

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  r = ?v[0]
  x = r.n if bump(!v) > 0 else 0
  print(x)
```

#### m/tern4.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  v.len

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  r = ?v[0]
  y = r.n
  print(y)
  x = r if bump(!v) > 0 else Item(n: 5)
  print(x)
```

#### m/sif.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  v.len

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  r = ?v[0]
  print(r.n) if bump(!v) > 0
```

#### m/ret.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  v.len

fun f(v: !List[Item]) -> Int
  r = ?v[0]
  return r.n if bump(!v) > 0
  0

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  n = 0
  r = ?v[0]
  n = r.n if bump(!v) > 0
  print(n, f(!v))
```

#### m/mv.rig

```rig fragment
obj Item
  n: Int

fun take(v: List[Item]) -> Int
  v.len

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  r = ?v[0]
  print(r.n) if take(<v) > 0
```

#### h/h1_kw.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  0

fun f(a: Int, b: Item) -> Int
  a + b.n

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  r =! ?v[0]
  print(f(b: r, a: bump(!v)))
```

#### h/h1_nf_ok.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  0

fun f(a: Int, b: Item) -> Int
  a + b.n

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  u: List[Item] = List()
  !u.push(Item(n: 1))
  r = ?u[0]
  print(f(b: r, a: bump(!v)))
```

#### h/h2_own.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int!
  for _ in 0..64
    !v.push(Item(n: 2))
  0

fun g(s: String, b: Item, n: Int) -> Int
  s.len + b.n + n

sub main()!
  v: List[Item] = List()
  !v.push(Item(n: 1))
  r =! ?v[0]
  print(g(String("x"), r, bump(!v)!))
```

#### h/h3_ctor.rig

```rig fragment
obj Item
  n: Int

obj Pair
  a: Int
  b: Item

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  0

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  r =! ?v[0]
  p = Pair(b: r, a: bump(!v))
  print(p)
```

#### h/h4_set.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  0

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  xs: List[Item] = List()
  !xs.push(Item(n: 0))
  r =! ?v[0]
  xs[bump(!v)] = r
  print(xs[0])
```

#### h/h5_lam.rig

```rig fragment
obj Item
  n: Int

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  0

fun apply(it: Item, f: ?fun(Int) -> Int, n: Int) -> Int
  f(it.n) + n

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  r =! ?v[0]
  print(apply(r, |x| x + 1, bump(!v)))
```

#### h/h6_wint.rig

```rig fragment
fun bump(v: !List[Int]) -> Int
  for _ in 0..64
    !v.push(2)
  0

fun f(a: Int, b: Int) -> Int
  a + b

sub main()
  v: List[Int] = List()
  !v.push(1)
  w =! !v[0]
  print(f(b: w, a: bump(!v)))
```

#### h/h7_recv.rig

```rig fragment
obj Item
  n: Int

obj Acc
  t: Int

  fun add(!@, it: Item, n: Int) -> Int
    @t += it.n + n
    @t

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  0

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  u: List[Item] = List()
  !u.push(Item(n: 1))
  r =! ?v[0]
  print((!Acc(t: 0)).add(r, bump(!v)))
```

#### h/h8_comp.rig

```rig fragment
fun bump(v: !List[Int]) -> Int
  for _ in 0..64
    !v.push(2)
  0

sub main()
  v: List[Int] = List()
  !v.push(1)
  u: List[Int] = List()
  !u.push(7)
  xs: List[Int] = List()
  !xs.push(0)
  w =! !v[0]
  xs[bump(!v)] += w
  print(xs[0])
```

#### h/pp_n8_push_own.rig

```rig fragment
obj Item
  n: Int
  m: Int

sub main()
  v: List[Item] = List()
  for i in 0..64
    !v.push(Item(n: i, m: 2))
  u: List[Item] = List()
  !u.push(Item(n: 1, m: 2))
  r = ?u[0]
  !v.push(r)
  print(v.len, v[64])
```

#### g/for1b.rig

```rig fragment
obj Item
  n: Int

fun all(v: ?List[Item]) -> ?List[Item]
  v

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  !v.push(Item(n: 2))
  u: List[Item] = List()
  !u.push(Item(n: 1))
  !u.push(Item(n: 2))
  for x in all(?v)
    k = x.n
    for _ in 0..64
      !v.push(Item(n: k))
  print(v.len)
```

#### g/for3.rig

```rig fragment
obj Item
  n: Int

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  !v.push(Item(n: 2))
  u: List[Item] = List()
  !u.push(Item(n: 1))
  !u.push(Item(n: 2))
  r = ?v
  for x in r
    k = x.n
    for _ in 0..64
      !v.push(Item(n: k))
  print(v.len)
```

#### g/guard1.rig

```rig fragment
obj Item
  n: Int

enum Res
  found(it: ?Item)
  missing

fun find(v: ?List[Item]) -> Res
  if v.len == 0
    return Res.missing
  Res.found(it: ?v[0])

fun bump(v: !List[Item]) -> Int
  for _ in 0..64
    !v.push(Item(n: 2))
  v.len

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  match find(?v)
    .found(_) if bump(!v) < 0 => print("a")
    .found(it) => print(it.n)
    .missing => print("none")
```

#### p/t05r.rig

```rig fragment
obj A3
  arr: [3]Int

sub main()
  xs: List[A3] = List()
  !xs.push(A3(arr: [1, 2, 3]))
  ys: List[A3] = List()
  !ys.push(A3(arr: [4, 5, 6]))
  a = !xs[0]
  b = !ys[0]
  c = true
  n = 0
  for x in (a if c else b).arr
    for _ in 0..100
      !xs.push(A3(arr: [0, 0, 0]))
    n += x
  print(n)
```

#### p/t05s.rig

```rig fragment
obj A3
  arr: [3]Int

sub main()
  xs: List[A3] = List()
  !xs.push(A3(arr: [1, 2, 3]))
  a = !xs[0]
  n = 0
  for x in a.arr
    for _ in 0..100
      !xs.push(A3(arr: [0, 0, 0]))
    n += x
  print(n)
```

#### p/t05c.rig

```rig fragment
obj A3
  arr: [3]Int

sub main()
  xs: List[A3] = List()
  !xs.push(A3(arr: [1, 2, 3]))
  a = !xs[0]
  n = 0
  arr = a.arr
  for x in arr
    for _ in 0..100
      !xs.push(A3(arr: [0, 0, 0]))
    n += x
  print(n)
```

#### p/t05w.rig

```rig fragment
obj A3
  arr: [3]Int

sub main()
  xs: List[A3] = List()
  !xs.push(A3(arr: [1, 2, 3]))
  a = !xs[0]
  n = 0
  i = 0
  while i < a.arr[0]
    !xs.push(A3(arr: [0, 0, 0]))
    i += 1
  print(n)
```

#### q/d3s.rig

```rig fragment
fun bump(a: ![3]Int) -> [3]Int
  a[0] = 9
  [1, 2, 3]

obj P
  v: Int

fun bumpp(a: !P) -> P
  a.v = 9
  P(v: 1)

sub main()
  a = [1, 2, 3]
  b = [1, 2, 3]
  r = ?b
  print(r == bump(!a))
  p = P(v: 1)
  q = P(v: 1)
  s = ?q
  print(s == bumpp(!p))
  t = String("ab")
  z = ?t
  print(z == String("ab"))
```

#### z/elide.zig (Zig copies a struct at the operand, before a later call)

```zig
const std = @import("std");
const Item = struct { a: [6]i64 };
const Box = struct { it: Item, n: i64 };
noinline fn bump(p: *Box) i64 { p.it.a[0] = 99; return 1; }
inline fn bumpi(p: *Box) i64 { p.it.a[0] = 77; return 1; }
fn show(t: anytype) void { std.debug.print("{d} {d}\n", .{ t[0].a[0], t[1] }); }
pub fn main() void {
    var b = Box{ .it = .{ .a = .{ 1, 2, 3, 4, 5, 6 } }, .n = 0 };
    const r = &b;
    show(.{ r.it, bump(&b) });
    b.it.a[0] = 1;
    show(.{ r.it, bumpi(&b) });
    b.it.a[0] = 1;
    const s = .{ r.*, bumpi(&b) };
    std.debug.print("{d}\n", .{s[0].it.a[0]});
}
```
