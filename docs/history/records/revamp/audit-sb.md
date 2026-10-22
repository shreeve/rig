# Adversarial audit: `slices-bytes` (main..slices-bytes, 4 commits)

Reviewer R15. Built `bin/rig` as found on the branch (152468a). Scratch:
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R15/`
(`repro/` holds the minimal repro for every finding, `p/` about 250 probe
programs, `fuzz.py` and `sfuzz.py` the fuzzers). Every finding below ran
twice with the same output.

**Bottom line:** I found no memory corruption. No use-after-free,
dangling slice, out-of-bounds write, or leak in safe code, in Debug or
`--release=fast`. There is one soundness-invariant break: `fill` and
`copy` duplicate a value that holds a write borrow. That is the thing
`ys = xs` and `[n of x]` reject. The per-root loans contain it, and I
could not turn it into corruption. The worst usability bug is that
`!param.copy(?local[..])` is rejected, which blocks the main use of
`copy`.

## Findings

| # | Sev | Kind | Summary | Repro (`repro/`) | Suspected code |
|---|---|---|---|---|---|
| 1 | High | wrong accept (soundness invariant) | `!xs.fill(v)` and `!dst.copy(src)` copy elements that hold a **write borrow**, so two elements (or two roots) hold the same `![]T` / `!T` | `fill_dup_write_borrow.rig`, `copy_dup_write_borrow.rig` | `src/typecheck.zig:4759` (`elemsCall` checks only `ownsResource`) |
| 2 | High | wrong reject | `!s.copy(?c[..])` into a `!` parameter from a local: "cannot let this call store a borrow of `c` in `s`: `s` outlives it". The same happens for `![N]T` and `!Vec[T]` parameters and for reslices of them | `copy_into_param.rig` | `src/ownership.zig:2265-2273` (`walkCall` absorbs the arguments' loans into a write receiver) |
| 3 | Medium | wrong reject | after `!b.copy(?a[..])` (or `!w.copy`, `!b[..].copy`), `a` stays read-borrowed for **as long as `b` lives**: `a[0] = 9`, `!a.fill(..)`, and `!v.push(..)` are rejected afterwards | `copy_keeps_source_borrowed.rig` | same as #2 |
| 4 | Medium | wrong reject + bad diagnostic | a bare `![]T` passed where a `[]T` is expected takes a **write** loan: `sum2(w, w)` with two `[]Int` params is rejected with "cannot take a second write borrow on `w`"; after `r = id(w)`, a *read* `print(w[0])` is rejected | `write_slice_as_two_reads.rig`, `write_slice_as_read_then_read.rig` | `src/ownership.zig:1346` (`walkConsumed`: `isWriteBorrowPlace` → `walkBorrow(.write)` regardless of the parameter type) |
| 5 | Low | wrong reject | `xs[a..` + newline + `]` fails: "a range needs an end". SPEC's line-joining section says a newline inside `[ ]` is whitespace. It also adds a misleading note, "the `(` opened here is not closed" | `open_range_newline.rig` | `src/rig.zig:689` (`nextCat()` sees the newline, not `]`) |
| 6 | Low | wrong reject / gap | `read[T, e]` / `write[T, e]` with `T` a compile-time type parameter: "`read` reads an integer or float type; got `T`" (`e` as a parameter works) | `read_generic_type.rig` | `src/typecheck.zig` `bytesCall` (`num_ok` switch) |
| 7 | Low | bad diagnostic (ergonomics) | `!b[..1].copy([9])` → "expected `[]Int`, got `[1]Int`", with no hint of the fix (`?x[..]`) | `copy_array_source.rig` | `elemsCall` → `checkExpr(args[0], []T)` |
| 8 | Low | bad diagnostics | (a) `two(w, w)` with `y: []Int` says "second **write** borrow" (from #4); (b) `f = \|<w\| w` for a `![]Int` suggests `+w`, which is rejected for `![]T`; (c) `h.arr.fill(4)` through `*S` suggests `!h.arr.fill(...)`, which is also rejected; (d) `!a[..]` returned from a by-value `[N]T` param gives two errors, the second calling it "a read-borrowed parameter of plain data" (it says the same for a `Vec` / `<self`); (e) `for row in grid` while `!grid[0][..]` is live gives two errors for one conflict; (f) an inner-scope `w = !rs[..]; w[0] = R(s: ?loc[..])` says "`w` outlives it" when `w` does not (the root does) | `diag_*.rig`, `p/m6.rig`, `p/aa7.rig` | various |
| 9 | Info (pre-existing) | wrong reject | root cause of #2/#3 for user methods too: `p.set(?c[..])` with `p: !P` and a plain `P` (no borrow fields) is rejected, because the check asks `holdsBorrow(!P)` (always true) rather than `holdsBorrow(P)` | `preexisting_user_method_absorb.rig` | `src/ownership.zig:2268` |

### 1. `fill` / `copy` duplicate write borrows (High)

```rig
struct V
  s: ![]Int
sub main()
  a = [1, 2]
  b = [3, 4]
  c = [5, 6]
  vs = [V(s: !a[..]), V(s: !b[..])]
  !vs.fill(V(s: !c[..]))
  vs[0].s[0] = 9
  vs[1].s[0] = 10
  print(c)
```
Output: `[10, 6]`, exit 0. The one `!c[..]` is now held by two elements.
`ys = xs` ("would duplicate the write borrow it holds") and
`[2 of V(s: !c[..])]` ("`V` holds a borrow, and its element must be
plain data") both reject this. `!ys.copy(?xs[..])` does the same across
two roots (`copy_dup_write_borrow.rig`, accepted).

I tried hard to escalate this. I took a slice into a `Vec` buffer
through one copy and pushed through the other (`p/w1..w5`,
`p/aj1..aj3`). Every attempt was rejected, because the duplicates carry
the same loans: the fill stays under one root, and `copy` absorbs a
read loan on the source root into the destination. So there is no
corruption today, but the uniqueness of `!` is broken, and fix #2 must
not remove the absorb for these element types.

**Fix:** in `elemsCall`, reject `fill` and `copy` when
`sema.holdsBorrow(elem)` (mirroring `[n of x]` at
`typecheck.zig:3312`), or at least `holdsWriteBorrow(elem)`. `swap` is
fine.

### 2/3. `copy` treated as storing its argument (High / Medium)

`walkCall` absorbs the argument loans into the receiver when
`mayCarryBorrow(exprType(Member.object(callee)))`. For `!s.copy(..)`,
that object is `(write s)`, whose type is always a borrow type, so the
check is always true. Consequences:
- `u1`–`u4`: every `!param.copy(?local[..])`, into a `![]T`, `![N]T`, or
  `!Vec[T]` param, or a reslice of one, is rejected with "cannot let
  this call store a borrow of `c` in `s`". `fill` and `write` of plain
  values are unaffected.
- `h1`, `h2`, `h5`, `h8`, `h9`: after `!b.copy(?a[..])` in one scope,
  `a` cannot be written and `v` cannot be pushed for the rest of `b`'s
  life.
- In generic bodies it also adds a second, bogus error ("cannot let
  this call store a borrow of `y` in `a`", `p/t1.rig`).

**Fix:** when `sema.elemCallOf(callee)` is set and the element type does
not `holdsBorrow`, skip the `stored` absorption, so the argument
borrows end with the call. More generally, test `holdsBorrow` on the
receiver's pointee (`unwrapBorrows`), which also fixes #9. Keep the
absorption when the elements can hold a borrow (needed for #1's
containment and for `p/v4.rig`, which is correctly rejected).

### 4. A `![]T` lent as `[]T` takes a write loan (Medium)

`sum2(w, w)` with `fun sum2(x: []Int, y: []Int)` is rejected. So is
`r = id(w); print(w[0])`. `?w[..]` in place of `w` works (`p/am2.rig`),
which confirms that only the bare form is too strict. SPEC says a
`![]T` "is accepted wherever a `[]T` is expected". **Fix:** in
`walkConsumed`, when the parameter's type is a read slice (recorded by
the type checker as a coercion fact), call `walkBorrow(expr, .read)`.
The message then becomes "use of `w` while a write borrow is live" or
disappears.

### 5. Open range before a newline (Low)

```rig
  print(?a[1..
    ])
```
→ `5:13: error: a range needs an end ...` plus the note "the `(` opened
here is not closed". **Fix:** in the `.dotdot` rewrite, peek past
whitespace, newline, and comment tokens when inside brackets.

### 6. `read[T, e]` with a generic `T` (Low)

`e: Endian` as a compile-time parameter works (tested), but `T` does
not. SPEC does not promise a generic `T`, so this is a gap, not a lie.
**Fix:** accept a type variable and record a numeric requirement
checked at instantiation, or document the limit.

### 7. Ergonomics: should `copy` accept an array? Recommendation

Today no call anywhere coerces `[N]T` to `[]T`: `total(a)`,
`total([1, 2])`, and `total(?a)` are all "type mismatch" (`p/ad1.rig`).
So `copy` rejecting `[9]` is consistent, but the message gives no fix.
Recommended rule, language-wide rather than copy-only:
1. An **array literal or other temporary** `[N]T` is accepted where a
   `[]T` argument is expected. It borrows no named value, so nothing is
   hidden, and the temporary outlives the call. That makes
   `!b[..1].copy([9])` work.
2. `?a` of a **named** array is accepted as `?a[..]`. The `?` makes the
   borrow visible.
3. A bare named array (`copy(b)`) stays rejected, since it would borrow
   `b` unseen, but with a hint: "write `?b[..]`".

If the language rule is not wanted, at least add hint 3 to the mismatch
for `copy` (and for any `[]T` parameter). Related: `!b.copy("abc")` and
`?s[1..]` of a String into a `[]U8` are also mismatches (`p/z1`, `p/z2`),
so a String to `[]U8` view may be worth a rule too.

## Clean (probed, correct)

**Aliasing roots:** each of these is rejected with a correct `file:line:col` error:
- a write slice live while the root is read (`a.len`, `print(a)`),
  written (`a[0] =`), moved, dropped, reassigned, pushed, cleared,
  popped, or iterated;
- two write slices of one root;
- a slice of one field while another field is written (conservative
  per-root, never unsound);
- the same field sliced twice;
- `!b.go(!b.a[..])` (`!self` plus a `![]T` from the same object);
- `two(!a[0..2], !a[1..3])`, `two(!a[..2], ?a[1..])`, `two(w, w)`,
  `two(s, s)`, `two(w, !w[..])`;
- `!s[..2]` and `!s[1..3]` in one call;
- a reslice live while the parent is written;
- `?w[..]` live while `w` is written;
- `x = !w` then a write to `w`;
- `e = !w[0]` then a write to `w`;
- `for x in w` / `for x in !w` bodies that write `w`;
- a Vec element's array sliced twice;
- a Vec element's array sliced across a push.

**Lifetimes:** each of these is rejected:
- `!mk()[..]` (a temporary);
- `!s[..]` of a `[]T` param;
- `!a[..]` of a `?[N]T` or `[N]T` param, returned;
- a slice of a local returned directly, in a struct (`V(s: !a[..])`),
  or from a closure;
- `Vec[![]Int]`;
- `|+w|`;
- an owned closure capturing a write slice;
- a `|<w|` closure returning `!w[..]` (no double call);
- a slice of an inner-scope array or loop binding outliving it;
- stores of shorter-lived borrows through `w[0] =`, `!w.fill`,
  `!w.copy`, `for r in !rs[..]`, `!w[0]`, a callee, or `w[0].s =`;
- `defer w[0] = ..` with a later push, drop, or move of the root;
- slices through a `*S` (writes rejected, reads keep the handle from
  being reassigned).

**Reborrowing through calls:** `!tail(!a[..])[..1]`,
`?tail(!v[..])[..]`, `!mk(!a).s[..]`, and `ro(!v[..])` returning `[]T`
all keep the root's loan. The methods `!b.items()` / `!self.v[..]`
returning `![]T` also keep the loan. `Vec` reallocations are blocked in
every case. `(![]Int)?` params and returns, `if <o as s`, and
`if find(..) as t` work, and a bare `if w as s` is rejected as a
duplicate.

**Reslicing:** these panic in every mode, including
`--release=fast`: runtime out-of-range, reversed, and negative bounds;
`w[n(3)] = ..`; `w[n(-1)] = ..`; `inc(!w[n(5)])`; `!w[n(3)].bump()`;
and `!w[n(2)][..]`. Constant bounds are caught at compile time
(`!a[4..]`, `!a[..4]`, `!a[2..1]`, `!w[2..1]`). Empty buffers work: a
`[0]Int` or empty Vec with `[..]`, `[0..]`, `[..0]`, and `[0..0]`; an
empty Vec with `[1..]` panics. A quicksort with swap and open reslices,
and a mergesort with `!tmp[..m]`, `!tmp[m..]`, and `copy`, sort 2000
elements correctly in Debug and ReleaseFast.

**copy, fill, and swap:**
- rejected: `copy` from the same root (both directions, and via a
  reslice or `self` fields), and `copy` from a `*Cell` Vec;
- work: `swap(i, i)` (arrays and `![]T`), `swap` on `Vec[*Cell[Int]]`
  (leak-free), and array/Vec copies both ways (`p/g5`, but see #3);
- `fill` on a String or a String slice is rejected;
- a length mismatch panics in ReleaseFast;
- the two-phase forms `!a.fill(a[1])`, `!b.swap(b[1], b[3])`, and
  `!c.write[..](c[0], c[3])` are correct;
- generic `rev[T]`, `fillall[T]`, and `cp[T]` over `![]T` work,
  including across modules;
- `fillall` with `T = *Cell` is rejected.

**read and write:**
- rejected at compile time: constant offsets past the end, negative
  offsets, value literals that do not fit (`300` into `U8`, `-129` into
  `I8`, `1e300` into `F32`, `-1` into `U64`), non-numeric `T`,
  `U3`/`U128` (not Rig types), a runtime `Endian`, and wrong
  bracket/argument arity;
- runtime offsets near the end or negative panic in Debug and
  ReleaseFast ("byte read/write out of range");
- work: `U8`, `I8`, `I16`, `U16`, `I32`, `U32`, `I64`, `U64`, `F32`,
  `F64`, `Int`, and `Float`; reads from a String (in range, and out of
  range panics); `?self` / `!self` fields; `?[N]U8`, `[N]U8`,
  `![N]U8`, `?Vec[U8]`, and `!Vec[U8]` params; a `![]U8` view field;
  `Endian` in structs, Vecs, `match`, and optionals; and module
  constants and cross-module `Endian`;
- writes through `?View`, `*S`, fixed (`=!`) bindings, and module
  constants are rejected;
- a `.len` assignment on a write slice is rejected.

**Grammar fuzz:** I ran 1,200 random token lines over slices, `..`,
`of`, brackets, sigils, endian brackets, and methods, plus 750
structured programs (328 accepted, all then built and run leak-free).
Every run used `gtimeout 10` for check and 120 for run. There were no
crashes, hangs, missing diagnostics, or accept-but-Zig-fails. I also
hand-checked 37 edge cases (`a[..][..]`, `[1..]`, `[..]`, `a[..-1]`,
`a[1...]`, `a[.. ..]`, `a[0..1..2]`, `for i in 0..`, `a[..=2]`,
`a[true..]`, `a[..1.5]`): each gave one clear diagnostic, except #5.
