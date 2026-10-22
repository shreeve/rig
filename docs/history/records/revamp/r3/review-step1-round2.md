# Review round 2: REVAMP-3 step 1 fixes (`r3-step1` HEAD `67f88767`)

Reviewer: the round-1 reviewer (`review-step1.md`). I built HEAD from
`git archive` in a scratch copy, together with `bin/rig-oracle`. Every
probe was run with `RIG_SANITIZE=1 bin/rig run`; for the new holes I
also checked base (`rig-485e`) and the round-1 commit (`b7ca0e90`). I
ran no suites (the machine load was 18–28) and modified no tracked
files.

Probes: the round-1 set (`probes/review-step1/*.rig`, with `Rng` changed
to `Random`) and 45 new ones in `probes/review-step1/round2/`
(`q*.rig`). `round2/round1-probes-at-HEAD.log` holds the round-1 set's
output at HEAD.

## Verdict

The round-1 instances are fixed, and M1, M2, the rename and the docs
are done well. **C1 and C2 are fixed for `for` headers only, not as a
class**:

- A read `match` on a part of a made value still writes into read-only
  memory (crash), and its payload view still escapes the temporary
  (dangling).
- The new "made source" rule in `for` treats every source that is not a
  named place as made. That includes `a if c else b`, `o ?? d`,
  `x catch d` and `o?` over named arrays, which are now silently copied:
  a unique value is duplicated and Cell or generator state is forked.
  The `o?` case worked correctly in round 1, so it is a regression.

These are soundness findings in the same class as round 1. By
AGENTS.md ("a second soundness round stops the feature"), the made
value / place classification of header subjects needs a redesign, not a
third patch.

| # | Sev | Status | Finding |
|---|---|---|---|
| R2-C1 | **Critical** | open, C1's class, since `8e84548b` | `match <part of a made value>` binds a Cell-holding payload as a view into the temporary. With a literal it writes into rodata (`Bus error`). |
| R2-C2 | **High (soundness)** | open, C2's class, since `8e84548b` | The same payload view escapes the `match`: `saved = c` keeps a pointer into the expired temporary. |
| R2-H1 | **High** | `o?` is a regression from `f278584b`; the branch forms date from `8e84548b` | `for k in (a if f else b)`, `o ?? d`, `x catch d`, `o?` copy a named unique array. Emit `rig.take`s the name, but the checker sees only a read, so the name stays usable. Cell and generator state forks. |
| R2-M1 | Medium | open, pre-existing | M2 is fixed one optional level deep only: `l: ((?P)?)? = r` still emits `r.*` and fails in Zig. |
| R2-M2 | Medium | documented, not fixed | A by-value Cell parameter: `c.hit()` and `bump(?c)` are accepted but `c.hits.set(v)` is not. SPEC now states this as an exception. A literal is accepted as a `[]Counter` argument while `?[literal]` is rejected. |
| R2-L1 | Low | new | `src/sema.zig:1730-1736`: `stdNameHint`'s doc comment was inserted inside `notPublic`'s, leaving `notPublic` undocumented and `stdNameHint`'s comment starting with `notPublic`'s first sentence. |

## Round-1 findings: status at HEAD

| Round 1 | Status | Evidence |
|---|---|---|
| C1 literal loop crash (`p17e`, `p17f`, `p42`, `p42c`, `p47`, `p47e`) | **fixed for `for` and `[]T` arguments** | all run: `1 6 7`, `a`, `0 1 / 1 6`, `ok`, `1`. Made arrays are taken into `var __rig_src_N`; a temporary array lent as a slice gets a `var` slot. Labels, `continue :outer`, `else`, value-position loops and `<k` out of a taken element all emit valid Zig (`q01`, `q02`, `q04`, `q05`, `q80`). |
| C2 loop view of a temporary escapes (`p32b`, `p32d`) | **fixed for `for`** | elements of a made array are now the binding's own. `saved = k` is a type error, and `saved = ?k` gives "`k` does not live long enough" (`q03`). |
| H1 generic and slice forks (`p38c`, `p47c`) | **fixed** | `p38c` → `1`, `p47c` → `2`. Nested generic paths `?h.arr[1]`, `?xs[1][0]`, `?xs[1].item` and `?s[1].item` reach in place (`q20`). Generic loop or payload copies now require `no_cell`, so `T = Counter` is rejected (`p37*`, `p38`, `p38b`): conservative and correct. |
| M1 `keptLikeOwner` split | **fixed** | `keptLikeOwner` is deleted; arrays, slices, discards and temporaries admit `Random`. Copy-out paths stay closed (`q07`: `b = a`, `a[0]`, `[n of]`, `get`, `==`). Loops over `![]Random` (`q71`) and element write and overwrite work. |
| M2 view lifted to optional | **fixed at one level** | `p33c`, `p34*` and `q30`–`q32` cover binding, assignment, argument, return, struct field, array literal, `??`, ternary, match arm and closure. Nested `((?P)?)?` still fails (R2-M1). |
| M3 by-value Cell param, stale messages | **messages fixed**; parameter rule documented as an exception (R2-M2) | `p49` message, "a field or element", `cell_place` text |
| L1–L7 | fixed | `no_move` rename, `move_unique_element.rig`, INTERNALS sentence, CORE §9 status, no-op drop documented, matrix `cell`/`unique` rows |
| `Rng` → `Random` | **complete** | No `Rng` remains in docs, std, tests, corpus or oracle differences except the deliberate hint. The hint fires for type, member, aliased module, optional, handle and array uses (`q40`). |

Round-1 probes at HEAD: no crash, no Zig compile error, no leak.

## R2-C1 (Critical): a read `match` on a part of a made value writes into rodata

**Where:** `src/typecheck.zig` (`checkMatch`, about :1830). A read subject
that is not `makesValue` but is rooted in a temporary (`H(...).e`,
`[...][0]`, `mkh().e`) stays in read mode, and its Cell-holding payload
becomes `?f.ty`. `src/emit.zig` `payloadAliases` then captures
`|*payload|` on the rvalue. `requireCellPlace` now accepts any
`.pattern` root (`f278584b`), so `.set` on such a payload passes too.

**Repro** (`round2/q09_match_temp_field.rig`; also `q14`, `q16`):

```rig
struct Counter
  hits: Cell[Int]

  sub hit(?self)
    self.hits.set(self.hits.get() + 1)

enum E
  a(c: Counter)
  b

struct H
  e: E

sub main()
  match H(e: E.a(c: Counter(hits: Cell(0)))).e
    .a(c) => c.hit()
    .b => pass
```

The emitted code is:

```zig
switch ((H{ .e = ... }).e) { .a => |*__rig_payload_1| { const c = &__rig_payload_1.c; c.hit(); } ...
```

It dies with `Bus error` in `Cell.set`. The same happens for
`match [E.a(...), E.b][0]` (`q14`) and for `.a(c) => c.hits.set(2)`
(`q16`). For a runtime temporary (`match mkh().e`) the write goes
through `@constCast` into a `const` temporary, which is illegal Zig even
though it happens to work. Base rejects all three; `b7ca0e90` already
crashed on them, and the round-1 fix did not reach `match`. The oracle
abstains ("a `Cell`").

## R2-C2 (High, soundness): that payload view escapes the temporary

**Repro** (`round2/q90_match_temp_escape.rig`; `q91` with
`match mk(7)[0]`):

```rig
fun mkh(n: Int) -> H
  H(e: E.a(c: Counter(hits: Cell(n))))

sub main()
  one = [Counter(hits: Cell(1))]
  saved = ?one[0]
  match mkh(7).e
    .a(c) => saved = c
    .b => pass
  print(saved.hits.get())
```

It is accepted and prints `7`. The emitted code is
`switch ((mkh(7)).e) { .a => |*p| { const c = &p.c; saved = c; } }`
followed by `saved.hits.get()`, a pointer into a temporary whose
lifetime has ended. `match ?mkh(7).e` is correctly rejected ("a borrow
of the temporary `mkh(7)` outlives its statement", `q92`). The bare read
form makes the same view and records no loan. This is round-1 C2's
class: a header binds a view into a made value without a loan.

**Fix for R2-C1 and R2-C2:** classify the subject once, the same way for
`for`, `match`, `if … as` and `while … as`. Either:

- a part of a made value is *taken* (the match consumes it, as
  `match make()` already does, with payloads owned and the made value in
  a `var`); or
- a view of it carries the hidden-temporary loan, exactly as
  `match ?mkh(7).e` does.

Add `q09`, `q14`, `q16`, `q90` and `q91` as tests, and a `match_subject`
context over `H(...).e` to `test/matrix.py`.

## R2-H1 (High): `for` over a branch, `??`, `catch` or `o?` of named arrays copies a unique value

**Where:** `src/typecheck.zig:1795` (`elementTypeForLoop`):

```zig
if (mode != .move and sema.isUnique(self.ctx, a.elem) and (peeled != source_ty or self.placeOf(source).named())) return ...borrow_read...
```

Everything that is not a named place falls through to "the binding's
own", so it is classified as made. That is a category defined as "not"
another, which AGENTS.md "One classifier per fact" rules out. The emit
side, `src/emit.zig` `emitFor`, wraps the source in
`var __rig_src = <source>`. For a branch over names it emits
`rig.take(&__rig_alive_a, a)`. The ownership checker treats the header
as a read, so `a` is not moved and stays usable.

**Repros:**

- `q50_branch_source.rig`: `for k in (a if f else b)` then `k.hit()`
  prints `0 0`. The change went to a copy, and `print(a[0]…)` after the
  "taken" `a` is accepted.
- `q53_nullish_source.rig` and `q52_catch_source.rig`:
  `for k in o ?? d` and `for k in two(9) catch d` print `9`. `d` was
  copied and the change lost.
- `q55_branch_rng.rig`: `for r in (a if f else b)` with `[2]Random`
  draws `465 110`, then `for r in !a` draws `465 110` again. The
  generator was duplicated, which is exactly what `unique` exists to
  prevent.
- `q56_propagate_source.rig`: `for k in o?` with a local
  `o: ([2]Counter)?` prints `0`. This is a **regression**: `b7ca0e90`
  printed `1` (in place).

None of these is memory-unsafe, because arrays never hold values that
need cleanup. But each accepted program copies a unique value and forks
its state, and emit moves a name that the checker still treats as live.
`match` already rejects every one of these subject forms ("a `match`
reads a place or takes a call's result; bind this `E` to a name first",
`q51`, `q58`, `q59`); `for` has no equivalent.

**Fix:** give `for` the positive classification `match` uses. A place,
or a view of one, is viewed. A value made by a call or literal is
taken. A branch, `??`, `catch` or `o?` whose type moves is rejected with
the `match` diagnostic, or is required to be written with `<` per
branch. Add `q50`, `q52`, `q53`, `q55` and `q56` as tests, and an
array-typed row with the `ternary`/`nullish`/`catch`/`optional` forms in
the `for_literal` matrix context.

## R2-M1 (Medium): a pointer view lifted two optional levels still dereferences

`emitBareAs` (`src/emit.zig:3213`) unwraps one optional. For
`l: ((?P)?)? = r` with `r = ?p`, it emits `const l: ??*const P = r.*;`,
which Zig rejects (`q34_lift_nested_optional.rig`). This
is pre-existing and rare. Fix: unwrap optionals repeatedly before
testing `isPtrBorrowTy`.

## R2-M2 (Medium): by-value Cell parameters and literal slices are exceptions, not rules

SPEC.md §10 now states that a by-value parameter "may be lent
(`bump(?c)`)" and its `?self` methods may change its Cell, "but `set`
and `replace` are not called on a Cell reached from the parameter
itself". That is an exception list next to Core sentence 9 ("a `Cell`
changes through any path"), and `cell_place` still says "A by-value
parameter … cannot be changed" (`p46`).

Similarly, `bump([Counter(...)])` with a `[]Counter` parameter is
accepted (a mutable slot is made, `q12`), while `bumpa(?[Counter(...)])`
and `bumpc(?Counter(...))` are rejected with "cannot borrow a temporary
that holds a Cell" (`q94`).

Neither is unsound. Each needs one rule (audit 1.7: a parameter root is
a Cell place for a value that moves; a lent temporary holding a Cell
either always gets a slot or is always rejected), not two documented
behaviors.

## Also checked, correct

- Made-array loops: `?two()` is taken, not lent (`q60`, `q61`).
  `!two()` and `![lit]` are rejected (`q95`). Labeled and value loops
  and `else` work. A taken element moved twice is rejected (`q05`).
- Temporaries' parts as receivers or lends (`H(...).c.hit()`,
  `bumpc(?H(...).c)`, `?H(...).arr[0]`) are copied into `var` slots and
  run (`q15`). `.set` on such a part is rejected.
- `match s[0]` over a `[]E` slice parameter changes the caller's
  element (`q10`).
- Branching lends: `!(a if f else b)` and `?(c if f else d)` are still
  rejected (`q08`) after M1 dropped the cleanup test at typecheck.zig
  :3632.
- Arrays and slices of `Random`: a write loop over `![]Random`, element
  overwrite, `!a[0].next()` and `swap` work. Copy-outs are rejected
  (`q06`, `q07`, `q70`, `q71`).
- The oracle reports no differences on any probe. It abstains
  ("unknown") on every program with a `Cell`, so it is no lens on this
  area yet.
