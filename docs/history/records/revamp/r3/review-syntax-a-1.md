# Review: PR #92 `syntax-a` (head c755b7c0, base main c7085d43)

Independent adversarial review, round 1. I built both commits in fresh
detached worktrees (`zig build` and `zig build oracle`). I ran every
accepted probe under `RIG_SANITIZE=1` in debug and in `--release`, and
through `bin/rig-oracle -v`. The probes are in
`.git/revamp/r3/review-syntax-a-1-probes/`: `d*` cover the drop, `sp/s*`
the spacing, `cl/c*` the closure layout, and `k*` the Cell sentence.

## Verdict

**It is safe to land.** I found no Critical finding. I found no
double-drop, leak, use-after-free, or use wrongly accepted after `<x`, in
any of the contexts below. Every accepted probe runs sanitizer-clean in
debug and in release, and the oracle accepts it with no differences.

There is one accept-means-correct finding (High). A statement `<s.f`
on an optional field of a plain type does not take the field: the
field keeps its value. The bug was already on main, where `_ = <s.f`
does the same. This PR now documents `<s.f` as "take ... leaving
`none`", so the documented form hits the bug directly. It can be fixed
in this PR or right after it; it is not a memory-safety hole.

## Critical

None.

## High

### H1. `<s.f` on a plain optional field leaves the field set (main has the same bug in `_ = <s.f`)

Probe `d01_plain_opt_field.rig`:

```rig
struct S
  f: Int?

sub main()
  s = S(f: 5)
  <s.f
  print(s.f == none)
```

- **Observed:** prints `false`, in debug and release. The oracle accepts it.
- **Expected:** `true`. SPEC (the summary above "Drop"), the PR body,
  and `drop_statement_takes.rig` all say that `<s.f` takes an optional
  field and leaves `none`.

The emitted Zig is `_ = &s.f;`, so no take happens.

- **Main:** `_ = <s.f` gives the same output (`d01b_plain_opt_field_main.rig`
  on c7085d43).
- **In the same program:** `x = <s.f` emits `rig.takeOut(&s.f)` and does
  leave `none`.

So `<e` means two different things, depending on whether its value is
bound or discarded.

**Cause.** In `Emitter.emitDiscard` (src/emit.zig, factored out of
`emitSet`), a discarded value whose type has no drop kind goes to the
by-address path. That path strips `move`, reasoning that "a clone or
move of a value that owns nothing is a copy". A `move` of an optional
field is a take, not a copy. Elements are not affected: `.index` is
excluded from this path, so `<v[i]` on `Vec[Int?]` does leave `none`
(`d07_plain_opt_elem.rig`).

This is emit re-deriving a fact from syntax, against "one classifier
per fact". The take should come from the recorded fact, as the
binding path's `takeOut` does.

**Sibling forms with the same cause:**
- `<w.f` through a write-view parameter `w: !S`;
- a plain struct optional, `f: P?` (`d34_plain_struct_opt_field.rig`
  prints "still there 1");
- a view optional, `f: String?` (`d09_view_opt_field_b.rig` prints
  `false`).

**Not memory-unsafe.** I checked the view-holding variants. The loan
stays with the struct, not with the field, so dropping or mutating the
owner after `<s.f` is still rejected (`d08_view_opt_field.rig`,
`d33*_writeview_opt_field*.rig`). Owning, `*T`, and `~T` optional
fields take correctly (`d11`, `d51`).

## Medium

None.

## Low

### L1. `<q` in a branch on a no-value closure's last line is rejected with the last-line message

`valueTail` on a lambda reaches into the `if`/`match` that ends the
body. In a closure passed as `?sub(Bool)`, the `<q` in the branch is
reported as "a closure's last line is its value, so `<q` there is no
drop ... write `_ = <q`" (`d20_closure_last_if_branch.rig`,
`d21_closure_value_to_sub.rig`).

This is conservative, and it is sound. But the user wrote a drop
inside a branch, not on the closure's last line, so the message points
at the wrong thing. It extends Decision 1 to branches, which the PR
body does not mention.

### L2. CORE sentence 4 is narrower than the built rule

CORE now says that `?` promises "nothing changes except a field whose
type is a `Cell`". Both of these are accepted and run:
- `sub bump(c: ?Cell[Int])` calling `c.set(...)` (`k01`);
- `v[0].set(...)` through `?Vec[Cell[Int]]` (`k02`).

SPEC §7 states the broader rule, which does not follow from the CORE
sentence as CORE requires. The PR flags this as Decision 4; it needs
the owner's ruling.

### L3. The hint after a line break uses a placeholder for the left operand

`print(v.len` followed by `-1)` on the next line is reported as
"`a -1`: ... write `a - 1`" (`sp/s43.rig`). On one line it shows the
real operand, as in "`w.n <b`" (`sp/s58.rig`).

### L4. The `-x` hint on a view parameter leads to a second rejection

For a statement `-x` where `x: ?F`, the diagnostic says "to drop `x`
now, write `<x`". `<x` is then rejected: "cannot drop view parameter
`x`" (`d52*`).

### L5. A statement `<?a` or `<!a` is accepted and does nothing

These are accepted, as `_ = <?a` is on main (`d49`). A statement `<n`
of plain data is rejected as "drops nothing", but these do nothing
too and are not.

### L6. Two spacing forms are accepted, as the rule implies

`a<-b` reads as `a < -b` (`sp/s37`), and `a--b` as `a - -b`
(`sp/s27`). Both are balanced, so the rule accepts them. Only the
spaced `a <- b` is rejected, as SYNTAX shows. I note it, but it is not
a defect.

### L7. The migration table says a `defer` body cannot move or drop

Its line for `defer <x` says this. `defer <s.f` and `defer <mk()` are
accepted and run correctly (`d35`, `d36`, `d37`, `d40`), as
`defer _ = <s.f` already was on main. Moving `s` after
`defer <s.f` is rejected (`d38`, `d39`). The wording could say "a
binding" to be exact.

## What was checked and found correct

### The `<x` drop

Each case below is accepted and runs sanitizer-clean in debug and
release with the oracle in agreement, unless it says rejected:

- **Control flow:**
  - `break` and `continue`, labeled `continue :outer` across nested
    loops (`d02`);
  - `?? continue` (`d04`);
  - statement `match` arms, one-line and block (`d05`);
  - `catch` handlers, in value and statement position (`d03`; a
    handler's last-line `<b` correctly moves into the bound value);
  - a loop `else` in value position, and a labeled loop as a `fun`'s
    tail (`d26`);
  - a `raw` block as a statement and as a `fun`'s tail (`d29`);
  - a postfix guard `<b if c` (in the PR's test);
  - an `errdefer <a` of a binding, rejected as on main (`d47`).
- **Receivers:**
  - `<self` in a `<self` sub drops; in a `<self` fun it returns
    (`d06`);
  - `<self` in a drop body is rejected (`d31`);
  - `<self.g` in a drop body takes the field, and glue sees `none`
    (`d32`).
- **Storage:**
  - closure captures: dropping a capture inside a closure is rejected,
    as on main (`d16`);
  - `*T` and `~T` handles (`d14`, `d48`, `d51`);
  - a Cell (`d28`);
  - optionals (`d51`);
  - a field through `!S` (`d11`);
  - a Vec element (`d07`, `d37`);
  - a field of a temporary is rejected (`d13`);
  - a field through a shared handle is rejected (`d12`);
  - `for x in <v` and match-bound payloads (`d27`).
- **Generics:** generic `T`, as both a drop and a return (`d15`).
- **Values:**
  - the last line of a `sub` drops (`d23`);
  - in a `fun`, the tail `if` branches move (`d22`);
  - a closure's last line is its value (`d18`, `d46`);
  - in a no-value closure the last line is rejected with `_ = <q`
    (`d17`).
- **The checker and emit agree:**
  - `(drop (move e))` goes through `checkDiscard`, the `walkDrop`
    binding path (the same as `walkSet` for `_`; `useAfterValue` is a
    no-op for `_`), `emitDiscard`, and the oracle's `dropStmt`;
  - `<s.f?` is rejected, as `_ = <s.f?` is on main (`d30*`);
  - `while c : <x` is rejected (`d41`);
  - `f() catch <b` and `g() ?? <b` as statements are rejected as
    leaks (`d43`, `d44`);
  - an `if` with a block argument does not parse (`d45`).

### Spacing

These are accepted with the right meaning:
- the types `?T?`, `![]T`, `*fun(Int) -> Int`, `[] Int`;
- generics `[T]`;
- ranges `a..b`, `..n-1`, `a..`, `-2..0`, `?xs[0..n - 1]`;
- negation: `x = -1`, `a - -b`, `f(-x)`, `[-1, -a]`, `return -x`,
  `-1 =>` arm patterns;
- `e?.f`, `e!.f`, and `a ?? b` or `a??b`;
- `catch |_| -1`, and closures `|x| -x` and `|| -1`;
- `n: Int = -1` field and parameter defaults;
- `x *= -2`;
- `print(1,` followed by `-2)` on the next line, and multi-line arrays
  starting `-2,`;
- operators inside strings and comments;
- a line break before a member `.` inside brackets.

These are rejected with a correct hint:
- `a <b` and `a -b`, including split across lines inside brackets;
- `a !=5`, `x +=1`, `a >>1`, `a |-b`;
- `print(! n)`;
- `f() !`, `Int !`, `Int ?`;
- `w. get()`.

I found no valid program the rule rejects that has no spaced
alternative.

### Closure layout

- **Accepted:**
  - nested closures, where the inner `)` is the last thing in the
    outer body (`c01`, `c17`);
  - an immediately called closure, also as an argument and followed by
    `(4) + 1` (`c04`, `c14`, `c16`);
  - a closure in an `if` branch and in an `if` condition (`c05`,
    `c20`);
  - `))` and `)(3)))` closing nested calls (`c15`);
  - a trailing comment and blank line before `)` (`c22`);
  - `)` at the column of the line that opened the bracket, when the
    bar list is on a later line (`c18`).
- **Rejected:**
  - the hanging bracket (`c08`);
  - a `)` at the wrong column (`c09`, `c19`);
  - `, k: 3)` or `,` after the body (`c02`, `c12`);
  - tabs, which were already rejected (`c10`, `c11`).

### The rewrite

On 120 randomly sampled rewritten `.rig` files (behavior, examples,
corpus, reject), I ran main's `bin/rig emit` on the original against
the head's on the rewrite:
- the 53 that main accepts emit identical Zig;
- every rejected one is rejected by both with the same number of
  errors, and only the `-x` to `<x` wording differs.

The three corpus probes left with `-x` on a closure's last line
(audit-frontend-b3, review-sc3-nh5, review-sc3-nh6) now negate an
`Int` value, which is harmless.

### Gates spot-check

`./test/run -j 2 drop syntax/` on the head, through heavy.sh: 371
passed, 0 failed.
