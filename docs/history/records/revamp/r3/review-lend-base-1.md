# Review: PR #90 `lend-base` (e73f7390 vs main faceba15)

Built both commits in fresh worktrees (`zig build`, `zig build oracle`).
Every accepted probe was run under `RIG_SANITIZE=1` in debug and
`--release`, and through `bin/rig-oracle`. The oracle reported 0
differences on every probe. No probe produced a sanitizer error, a leak,
or wrong output. Every accepted-but-wrong case is Zig that fails to
compile. `./test/run lend` passes on e73f7390 (139 passed).

Verdict: **not ready to land as is.** There is no memory-safety
finding. There are two accept-means-correct holes (H1, H2) that the
rule should close, because closing them is its stated purpose. Both are
partly regressions: forms #89 rejected are accepted again and now fail
in Zig.

---

## High

### H1. A lend wrapped in `<` slips past the decider: accepted, then the Zig fails to compile

`lendsPlace` only checks `handsOver(obj).kind == .lend`. A move of a
lend, `<(!p)`, classifies as `.made` (`shapeOf`: `.move => .made`), and
`pathHands` turns that into `.place` through the view's type. Emit then
writes the move's operand, `&p`, as the member or index base without
parentheses (`emitMemberBase.needs_parens` has no `.move`), so
`(<(!p)).x` becomes `&p.x`.

```rig
struct P
  x: Int
  o: Int?
  a: [2]Int

sub main()
  p = P(x: 1, o: 3, a: [1, 2])
  y = (<(!p)).x
  print(y)
```
- Observed on e73f7390: `rig check` accepts it. The Zig fails: `const y: i64 = &p.x;` ("expected type 'i64', found pointer").
- On faceba15 it was rejected (#89: "`<(!p)` here is read, not held … Write `p.x`").
- Expected: rejected like `(!p).x`, with the hint `y = p.x`.

The same class, with the result on each commit:

| Form | faceba15 | e73f7390 | Zig |
|---|---|---|---|
| `y = (<(!p)).x` | reject | **accept** | `&p.x` as i64 |
| `if (<(!p)).o as k` | reject | **accept** | `if (&p.o)` on `*?i64` |
| `show((<(!p)).v)` (`?Vec` param) | reject | **accept** | `show(&&p.v)` |
| `f = \|!p\| (<(!p)).x` (cl13) | reject | **accept** | runs, prints 1 |
| `print((<(!p)).x)`, `for x in (<(!p)).a` | reject | **accept** | runs correctly |
| `(<(!p)).x = 5`, `(<(!arr))[0] = 7`, `(<(!p)).a[1] += 4`, `(<(!p)).q.n = 3` | accept | accept | `&p.x = 5`: invalid assignment target |
| `(<(!p)).v[0] = 9` | accept | accept | `&p.v.slot(0).* = 9` |
| `y = <(<(!p)).o` | accept | accept | `rig.takeOut(&&p.o)` |
| `bump(!(<(!p)).x)` | accept | accept | `bump(&&p.x)` |
| `!(<(!p)).v.push(3)`, `(!(<(!p)).q).bump()` | accept | accept | `&p.v.push(3);` value ignored |
| `if !(<(!p)).o as k` | accept | accept | `if ((&&p.o).*)` |
| `w = !(<(!p)).q` then `w.n = 9` | accept | accept | `*const *Q` has no field access |
| `n = (<(?p)).a.len` | accept | accept | `rig.len(&p.a.len)` |

The same missing parentheses also hit a move of a branch used as a
base. This is the sibling of the e73f7390 fix: there `<` took an element
of a branch, and here a branch under `<` is the base.

| Form | both commits | Zig |
|---|---|---|
| `(<(!p if c else !q)).x = 5` | accept | `if (c) &p else &q.x = 5;` |
| `y = (<(?p if c else ?r)).x` | accept | `if (c) &p else &r.x` |
| `y = (<(?a if c else ?b))[1]`, `print(...)` | accept | `if (c) &a else &b[1]` |

Fix the class. Either `lendsPlace` looks through `<` (`<` of a lend
adds nothing over the lend), or typecheck rejects `<` of a value that
is no place. In either case `.move` belongs in `emitMemberBase`'s
parenthesized kinds. Add a test that covers the siblings: a base of
`<(!x)`, `<(?x)`, and `<(branch)`.

### H2. The rule never fires in a closure's value (expression body, or a block body's last value)

`lendBase` returns silently when the hint builder finds no edit:
`const own = fix.edit(obj) orelse return;`. `LendBaseFix.collect` does
not enter lambdas. A closure without a declared type types its
expression body, and its block body's last value, with `synthExpr`
(`checkLambdaGiven`, typecheck.zig ~9741-9764). There `self.stmt` is
still the statement that holds the lambda, so the path is never found
and nothing is reported. Every form the PR rejects is then accepted
inside `f = |...| <expr>`, and some of them miscompile.

```rig
struct P
  v: Vec[Int]

sub main()
  p = P(v: Vec())
  !p.v.push(4)
  f = |!p| (!p.v)[0]
  print(f())
```
- Observed on e73f7390: accepted. The Zig fails: `return &__rig_self.cap_p.v.at(0);` ("expected type 'i64', found pointer").
- On faceba15: rejected ("`!p.v` here is read, not held").
- Expected: `` `(!p.v)[0]`: write a lend on the whole path, not its base `` with the hint `f = |!p| p.v[0]`.

Others found this way:
- **Accepted on both, Zig fails:**
  - `f = |!p| twice(!(!p.v)[0])` gives `twice(&&…slot(0).*)`;
  - `f = |!p| twice(!(!p.a)[1])` and `f = |!p| bump(!(!(!p).v)[0])`.

  At statement level the PR rejects these, as it does `bump(!(!arr)[0])`.
- **Accepted again, rejected on faceba15, run correctly:**
  - `f = |!p| (!p).a[0] + 1`, `f = |!p| (!p).q.get()`;
  - `f = |!o| (!o)[0] ?? 0`, `f = |!p| (!p).o ?? 0`;
  - `f = |!p| print((!p.v)[0])` and the `(!arr)[1]`, `(!o)[0]`, `(!p.q).n` variants.
- **Accepted on both, run correctly:**
  - `f = |!o| <(!o)[0]`, `f = |!p| <(!p).o` (the reject test's `c = <(!p).o`);
  - `f = |!p| bump(!(!p).a[0])`, `f = |!arr| pick(!(!arr)[1])`.

A closure passed as an argument (`apply(|?p| (?p).a[1])`) is reported,
because its body goes through `checkTail`.

Fix: give a closure's value its own statement context, as `checkTail`
does. Never return without an error from `lendBase` once
`lendsPlace` holds: if no edit is found, fall back to a hint on the
bare path. Accept-means-correct needs the error, and the hint can be
worse.

---

## Medium

### M1. Reopened "ignored `!`" reads through a lend of a slice

#89 rejected a written `!` on a slice that is only read. The new rule
exempts every lend of a slice, and the deleted path machinery was the
only check left. Accepted on e73f7390, rejected on faceba15:
```rig
sub main()
  arr = [1, 2, 3]
  y = (!arr[..])[0]
  n = (!arr[..]).len
  print(y, n)
  if (!arr[..])[0] == 1
    print(1)
  match (!arr[..])[0]
    1 => print(1)
    _ => pass
  z = (!arr[..2])[1]
  print(z)
```
- Expected: rejected, as on main ("Write `arr[..][0]`", or better `arr[0]`).
- It runs correctly, so this is a visibility regression, not a safety one.

### M2. Reopened "ignored `!`" read through a function field indexed then called

`isCallee` cannot tell `(!t).ops[1](5)` (a field holding an array of
functions, indexed, then called) from `(!w).put[2](3)` (a method with a
compile-time argument), so the path is exempt.
```rig
fun double(n: Int) -> Int
  n * 2

struct Table
  ops: [2]fun(Int) -> Int

sub main()
  t = Table(ops: [double, double])
  print((!t).ops[1](5))
```
- On faceba15: rejected ("`(!t).ops` only reads the place it reaches").
- On e73f7390: accepted, prints 10.
- The PR says that "a field holding functions that is called keeps its own diagnostic". No such diagnostic exists: `(!s).f(1)`, `(?s).f(1)`, `(!o).k(4)` and `(?t).ops[j](5)` are accepted on both commits. Either the rule covers them, or the PR and SPEC say they are exempt.

### M3. Hints whose suggested code is rejected

Each suggestion below was compiled on its own.

1. **A shared handle.** The handle error is dropped as "inside the
   reported path", and the hint gives the form that the dropped error
   rejects.
   - `(!h).x = 5` with `h = *P(...)` gives the hint `h.x = 5`, which is rejected ("cannot assign through a shared handle"). Main reported the handle error.
   - The same holds for `(!h).v.push(4)` (hint `!h.v.push(4)`), `(?h).a[0] = 9` (hint `h.a[0] = 9`), and `(!h).q.bump()`.
2. **A binding of an owning field.** `x = (?p).items` (a `Vec` field)
   gives the hint `x = p.items`, which is rejected ("bare use of `Vec` …
   would copy"). The working form is `x = ?p.items`. "An assigned or
   read path goes bare" is wrong where the read value does not copy.
3. **A header over a temporary.** The "bind it to a name first" branch
   only applies when the path is assigned.
   - `for x in (!mk()).items` gives the hint `for x in !mk().items`, which is rejected ("must be a binding" and "would walk the temporary").
   - `match (!mk()).e` gives `match !mk().e`, which is rejected (the header binds a copy of a temporary).
   - `if (!mk()).o as k` gives `if !mk().o as k`, which is rejected the same way.
4. **A function's tail value.** `checkTail` makes the tail its own
   statement, so `bool_used` is false.
   - In `fun f(p: !P) -> Bool`, the body `(!p).s.insert(1)` gives the hint `!p.s.insert(1)`.
   - That hint is rejected: "a write call whose `Bool` value is used is written `(!p.s).insert(...)`". The right hint is `(!p.s).insert(1)`.

---

## Low

- **L1. Other diagnostics still suggest the rejected form.** The second
  error in the same program recommends a lend-base form that the new
  rule rejects:
  - `if (!p).o as k` / `k += 1`: "bind it with `!(!p).o as k`";
  - `for x in (!p).a` / `x += 1`: "loop with `for x in !(!p).a`";
  - `match (!p).e`: "match with `match !(!p).e`";
  - the slice rule's "write `?(!p.v)[0..1]`".

  These hints should print the rewritten subject (`!p.o`, `!p.a`, `!p.e`).
- **L2. A temporary's name can clash with a later declaration.**
  `(!mk()).x = 3` followed by `t = 4` gives the hint `t = mk()`, then
  `t.x = 3`. Applied, it makes the later `t = 4` assign an `Int` to a
  `P`. `lookupAt(scope, n, sp.start)` only sees earlier names; the
  statement-text check (`hasWord`) only looks at this statement.
- **L3. A fragment hint.** A lend base inside a multi-line value, for
  example a `match` arm block under `y = match x`, falls back to the
  path span. The hint is then `` `(!p.s)` ``, a fragment rather than a
  statement.
- **L4. A misleading message for a re-lend of a call's view.**
  `(!idw(!p)).x = 5`, where `idw` returns `!P`, is reported as "assign
  into a temporary, bind it to a name first". The value is a view, not
  a temporary, and `idw(!p).x = 5` works. The hint does compile.
- **L5. Notes can be dropped by a stale flag.** `note`/`noteAt` drop
  when `dropped_error` is set, and only `Checker.err`/`errAt` set it. A
  note after an error that a sema helper reports straight through
  `ctx.err` reads the last Checker error's flag. I found no case, but
  the flag would be safer reset per error, or passed explicitly.
- **L6. A hint can turn a read into a write.** `(?p).x = 5` used to
  report "cannot assign through a read view"; it now gives the hint
  `p.x = 5`. `(?p).s.insert(1)` gives `!p.s.insert(1)`. Both compile,
  but the hint silently turns the user's `?` into a write. Consider
  keeping the read-view error when the lend is `?` and the use writes.
- **L7. A branch read only stays accepted.**
  `y = (!p if c else !q).x` and `y = (!a if c else !b)[0]` are accepted
  on both commits. This is not reopened by this PR; it is noted for
  completeness.

---

## Checked and fine

- **Branches.**
  - Over write lends: `v[0] = 99`, `v[0] += 1`, `!(…).q.bump()`, `(!(…).q).bump()`, `!(…).o as k`, `<(…).o as k`, `y = <(…).o`, `.o = none`, `!(…).v.push`, `w = !(…).q`.
  - Over read lends: `.v.len`, `?(?…).v[..]`.
  - Loans are respected: `r = ?a[0..1]` then `(!a if c else !b)[0] = 5` is rejected.
- **Lends of slices.** `(!p.v[..])[0] = 9`, `(!p.v[1..])[0] += 1`, `(!p.a[..])[k] = 3`, `(!arr[k..])[0] *= 5`, and `(?p.v[..])[0]` followed by a push all run correctly. Loans are respected.
- **Receivers.** `(!p.s).insert`, `(!p.s).put[2](3)`, `(!p).pickw().n = 20`, `(!t.pickw()).b` all run correctly. A read method behind a written `!` (`(!p.q).get()`) is still rejected.
- **The emit fix in e73f7390.**
  - `<(!c if k else !d)[1]` is correct over arrays, over Vecs (`[1]`, `[i]`), and through fields (`[1].o`, `[1].os[1]`, `[i].os[i]`).
  - It is also correct through held views (`w1 if k else w2`), with `not k`, in `while … as` and `if … as`, and with `(!r[1] if k else !s[0]).os[0]`.
  - All of these are sanitizer-clean in debug and `--release`.
  - The sibling it misses, a branch under `<` used as a base, is in H1.
- **Hints from the PR's own tests.** Each rewrite was compiled and run, and each prints what the original intended: `if !p.o as k`, `while !p.o as k`, `match ?p.e`, `match !p.e`, `for x in !p.items`, `if <o[0] as m`, `print((!p.s).insert(1))`, `h = t.len`, `n = total(!arr[0..2])`, `c = <p.o`, `s = ?arr[0..1]`, `g = v.len`, `!qs[1].bump()`, `bump(!arr[0])`, and the temporary hints (`tmp = mkopt(5) ?? mk(6)` and the rest).
- **More hint rewrites I generated.** `(p).x = 5`, `n = !p.s.count()`, `b = !p.s.maybe()` (a `Bool?` result), `b = (!p.s).tryb()!`, `if (!p.s).insert(3)`, `b = (!p.s).insert(1) and (!p.s).insert(2)`, `not (!p.s).insert(1)`, `arr[p.a[0]] = 9`, `y = (a if c else b)[0]`.
- **Over-rejection.** I found no valid program without a plain alternative. Each newly rejected form I tried (on shared handles, slices held as `![]T`, a call's `!T`, closure arguments, `for x in (?p).a`) has a working plain form.
