# Review syntax-b, round 1 (PR #93, head 4d8cb4a8, base main 79768d0b)

Independent adversarial review. Both commits were built in fresh detached
worktrees (`zig build`, `zig build oracle`). Every accepted probe was run
under `RIG_SANITIZE=1` in debug and `--release`, and through
`bin/rig-oracle -v`. The probes are in `.git/revamp/r3/review-syntax-b-1-probes/`
(140 files): `s*` for rule 1, `w*` for rule 2, `d*` for `sema.undroppable`,
and `h*` for the slice-argument hints.

## Verdict

- **No regression.** I found nothing that main rejects and the head
  accepts wrongly, and nothing the head emits differently for a program
  both accept.
- **One soundness finding, C1, which main has too.** A slice of a
  *write view* of a Text is classified as a value, not as a lend of that
  view. Safe code that then writes through the view is a use-after-free.
  - The PR's new decider `sliceLendsObject` repeats this misclassification,
    so for these objects the bare slice argument is **not** lent the way
    `?xs[a..b]` is. The PR's proof of equivalence does not cover them,
    because the grid had a `?Text` parameter but no `!Text` one.
  - The fix is one line in that decider. With it, the full suite passes
    (2999 passed, 0 failed, 3 pending).
- **My recommendation:** fold the C1 fix into this PR, since the decider is
  this PR's own. Otherwise land the PR and fix C1 before the v0.3.0 tag
  (AGENTS: a soundness finding from either gate is fixed before the tag).
- **Rule 2, `sema.undroppable`, and the rewrite:** no findings.

---

## Critical

### C1. A slice of a write view of a Text does not lend it (pre-existing; repeated by `sliceLendsObject`)

`sliceLendsObject` (src/typecheck.zig) decides that the slice is a value
whenever the object's type is any view of a Text:

```zig
.text => !sema.isReadOrWriteView(self.ctx, obj_ty),
```

- **Where it is right:** for a `?Text`. The owner cannot change while the
  read view lives, so the String it gives is a value.
- **Where it is wrong:** for a `!Text`, a `!*Text`, a `!Box[Text]`, and a
  `!Text` field. The holder of the write view can still `add` to the Text
  or assign it, which frees the bytes the String views.
- **The written form is right:** `?t[1..]` lends `t`, and the checker
  rejects the later write.
- So the bare form is accepted where the written form is rejected. That
  breaks "accept means correct", and it breaks the PR's claim that "every
  accepted bare form emits the same Zig ... as its written form".

**Minimal program** (`s56_bang_text_word.rig`):

```rig
fun word(s: String) -> String
  s

sub f(t: !Text)
  s = word(t[1..])
  for _ in 0..50
    !t.add("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
  print(s)

sub main()
  t = Text("hello")
  f(!t)
```

- **Observed on the head:**
  - `rig check` accepts it.
  - Debug with `RIG_SANITIZE=1` stops with `error: rig: use of freed memory`, then `Bus error`.
  - `--release` prints garbage bytes.
  - `rig-oracle -v` says `prod=accept ref=accept`: the oracle misses it too.
- **Expected:** rejected, as the written form `word(?t[1..])` is:
  `cannot lend `t` to write while a read loan is live` (`s57`).
- **Main:** the same program has the same old syntax, since a slice of a
  view of a Text was already allowed bare. Main accepts it, with the same
  use-after-free, so this is pre-existing.

**The class: a slice of any write view of a Text.** Every probe below is
accepted on both main and the head and is a sanitizer use-after-free in
debug (garbage in `--release`). The written `?` form of each is rejected
on both.

| Probe | Object | Write through it |
|---|---|---|
| `s31`, `s56` | `!Text` parameter, argument slice | `!t.add(...)` |
| `s55` | `!Text` parameter, binding `s = t[1..]` | `!t.add(...)` |
| `s58` | local `w = !t` | `!w.add(...)` |
| `s61` | field `h.t: !Text` | `!h.t.add(...)` |
| `s90` | `!*Text` parameter | `h = *Text("other")` |
| `s91` | `!Box[Text]` parameter | `b = Box(Text("other"))` |
| `s92` | `!Text` parameter | `t = Text("other")` |

**Siblings checked, all correct:**
- a `?Text` local or parameter (`s80`);
- a `!String` (`s93`), which carries the Text's loan;
- a Text field reached through a `!B` (`s94`);
- a `![]T` (`s22`, `s81`);
- a `!Vec` parameter (`s16`, `s82`);
- returning a slice of a `!Text` to the caller (`s83`): the caller's loan
  holds.

**Fix (tried, not committed).** Lend unless the object is a *read* view:

```zig
.text => self.ctx.types.get(obj_ty) != .read_view,
```

- All nine probes are then rejected:
  - `s55`: "a slice of a Text views it; write `?t[1..]`";
  - the argument forms: by the loan.
- The full `./test/run` on the patched head: 2999 passed, 0 failed,
  3 pending.
- A regression test should cover `!Text`, `!*Text`, and `!Box[Text]`, each
  as a parameter, a local, and a field, each followed by `add` and by
  assignment, in both the argument and the binding form. The grid
  (`grid_slice.py`) needs a `!Text` slice kind.

## High

None.

## Medium

None.

## Low

None that are new in this PR. One note on behavior:

- **Note (by design, not a defect).** `f = |!v| !v.pop()` followed by a
  statement `f()` is now rejected with "write `(!v).pop()`" (`w05`). Main
  accepted it. This follows the PR's rule, under which a closure's
  expression body is its value whether or not the call's result is used.
  The migration table should list it beside "a `fun`'s or closure's last
  line".

---

## What I checked and found sound

### Rule 1: a slice argument is lent to read

Each of these is rejected by the right loan, on the right line, or runs
sanitizer-clean in debug and `--release`, and the oracle agrees.

- **The owner changed, moved, or dropped while the result lives.**
  - A generic `echo[T]` (`s01`).
  - A Vec dropped with `<v` (`s02`) or moved (`s03`).
  - A method returning its argument (`s06`).
  - A nested `keep(keep(v[..]))` (`s07`).
  - A closure returning its argument (`s08`).
  - A Text dropped (`s09`), or grown through a generic `id` (`s24`).
  - An optional `([]Int)?` result (`s10`) and an optional `String?`
    parameter (`s29`).
  - A struct wrapping the view (`s20`).
  - A `for` source (`s21`), an `if ... as` header (`s44`), and a kwarg
    (`s43`).
  - A generic two-argument `pick` (`s28`).
  - `std.text.split` and `strip_prefix` (`s49`, `s50`).
  - A slice of a `?[4]Int` parameter (`s54`), and a slice of a `[]Int`
    view (`s53`).
  - A slice of a nested Vec element (`s23`) and of a held `![]T` (`s22`).
  - A `!self` field (`s48`).
  - A view stored by `!vec.push` (`s33`), by a concrete `store` (`s35`),
    by a generic `store` (`s34`), and by a `!self` method into a field
    (`s97`, `s98`).
- **Evaluation order.**
  - `two(v[0..1], grow(!v))` is rejected (`s04`). The reverse order is
    accepted and correct (`s05`).
  - `g(!v, v[..])` is rejected (`s18`).
  - `!b.add_all(b.items[..])` is rejected (`s32`).
  - `g(v[..], <v)` and `g(b.items[..], <b)` are rejected (`s38`, `s39`).
  - A generic `both(v[..], !v)` is rejected (`s64`).
  - A bound that writes the owner, `v[0..grow(!v)]` or `v[grow(!v)..]`,
    is rejected: "cannot lend `v` to write in an index of a place it is
    lending" (`s84`, `s89`), the same as the written form (`s85`).
  - Disjoint `two(a[..2], !a[2..])` is rejected as one array (`s17`), the
    same as the written form.
- **Temporaries.**
  - A Vec temporary (`s11`), a struct's Vec and Text fields (`s40`), a
    Text temporary (`s41`), an array literal (`s100`), and an array of
    Texts (`s102`) all run clean.
  - Each is rejected when its view is bound or stored past the statement
    (`s12`, `s42`, `s88`, `s95`, `s96`, `s101`).
- **Closures.**
  - A `|?v|` capture works when used in turn (`s65`), and is rejected
    when live across a write (`s66`).
  - Returning a view of a `+`, `!`, or `<` capture is rejected (`s67`,
    `s69`, `s70`), the same as the written `?` form (`s68`).
- **Branches.**
  - `total((a if c else b)[..2])` is accepted, as the written form is on
    main and on the head (`s71`, `s77`). The PR's decision 3 reads as if
    this form is rejected; it applies only to a branch of names that must
    be moved.
  - Bound, it is rejected as a temporary (`s72`, `s76`).
  - `(?a if c else ?b)[..2]` carries both loans (`s73`).
  - A slice of a view-returning call carries the loan (`s74`, `s79`).
- **`defer`.** `defer print(total(v[..]))` followed by `<v` is rejected,
  as the written form is (`s86`, `s87`).
- **Not sliceable on either commit.** A `*Vec` (`s13`, `s14`) and a
  `Cell[Vec]` (`s15`).
- **`*Text` and `Box[Text]`.** Slicing these now lends the handle or box,
  and dropping it while the view lives is rejected (`s59`, `s60`). Main
  rejected the bare form with "write `?h[1..]`".
- **The forms that stay written.** A struct field `W(xs: a[..])` still
  draws "write `?a[..]`" (`s30`).
- **Hints.** The three rejection hints, for `![]T`, `Text`, and `Vec`
  parameters, are accurate, and the two that give a rewrite compile and
  run clean when followed (`h01`, `h02`).
- **Emit equivalence.** I compared six accepted bare probes (`s11`, `s27`,
  `s37`, `s40`, `s41`, `s65`) with their `?`-written forms on the head.
  The emitted Zig is identical, apart from the package path note.

### Rule 2: a write call whose value is used

- **Every used position is rejected with the right rewrite:**
  - a binding, a compound assignment, an element or field assignment
    (`w25`, `w26`);
  - a value `match` arm (`w27`), a `catch` handler (`w28`), the right
    side of `??` (`w29`, `w10`, `w17`);
  - a constructor field and a kwarg (`w30`);
  - an index and a range bound (`w31`), a comparison operand (`w32`);
  - a postfix-`if` condition (`w34`);
  - a `break` value (`w09`), a `fun`'s last line (`w08`), a closure body
    (`w14`), a `match` subject (`w12`), a `catch` value (`w13`), the
    operand of `?` (`w18`), `_ =` (`w20`), a chained receiver (`w23`),
    and `!vv[0].pop()` (`w22`).
- **Every discarded position is accepted in the short form:**
  - a statement with a postfix `if` (`w01`, `w35`);
  - statement `match` arms (`w02`, `w03`);
  - a `sub`'s last line (`w04`);
  - statement `if` branches (`w06`);
  - `defer` (`w07`);
  - a statement under `?` (`w19`), under `!` (`w36`), and under `catch`
    (`w13`, line 15).
- **The long form as a statement** is accepted (`w24`).
- **Unchanged from main.** Each of these emits identical Zig on main and
  the head, with identical sanitized output: `w01`–`w04`, `w06`, `w07`,
  `w16` (`while (!it).next() as x`), `w19`, `w24`, `w33`
  (`for x in (!c).next()`), `w35`, and `w36`.
- **Not changed by this PR.** `for x in !c.next()` still parses as a
  write loop and is rejected on both (`w11`); the hint now writes
  `(!receiver).next(...)`.

### `sema.undroppable` (L2)

These agree with main:
- `<x` of a loop element is rejected over a Vec of Texts: `for x in (v)`,
  `?v`, a `?` or `!` parameter, a field, and an element (`d01`–`d04`,
  `d11`, `d12`).
- `for x in <v` drops (`d05`).
- A generic instance at `Int` drops (`d15`), and the instance at `Text`
  is rejected by the generic rule first (`d13`, `d14`).
- A local inside a closure that shadows a capture drops (`d16`), as do a
  closure parameter (`d17`) and a closure's local (`d20`).
- A view parameter `w: ![]Int` is rejected (`d06`). A `[]Int` or `String`
  parameter's `<` is accepted, as on main.

The two changes from main are the ones intended:
- `<s` of a `|+s|` capture is rejected (`d18`). Main reported "use of `s`
  after drop" there.
- The `-x` hint over a loop element names the loop (`d09`).

I found no `<x` that is accepted where it must not drop. `forViewsSlot`
adds a `handsOver(source) == .place` test that the old `isResourceVec`
check did not have, but it runs only in the branch where `resolvePlace`
succeeded, and I found no source where the two disagree.

### The rewrite (c1bf4a7d)

- **The script.** It pairs the 561 removed and added lines of the diff.
- **Code lines.** In every pair of code, the two lines are equal once
  their parentheses are removed: the rewrite only inserts parentheses.
- **Directives.** The other 14 pairs are `# error: L:C:` directives
  whose column moved by the inserted parentheses.
- **The non-trivial pairs.** I read about 140 by hand: temporaries,
  branch receivers, chained calls, `catch`/`??`/`?`/`!` wrappers, `defer`,
  match arms, and nested calls. In each, the parentheses close exactly
  over the receiver (`!X` → `(!X)`), and the meaning is unchanged.
- **Statements.** The short forms that the rewrite turned long are each
  a `fun`'s last line (a value). Those that stayed short are discarded
  statements.

## Cleanup

Both worktrees were removed. Nothing was committed or pushed.
