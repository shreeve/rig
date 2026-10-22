## Summary
Two v0.3.0 rules the design owner approved, both touching how a lend is written, plus the three Lows from review round 2 of syntax-a, and the fix for review round 1's Critical (C1), which main has too: a slice of a write view of a Text lent nothing (§4).

| Change | Old | New |
|---|---|---|
| A slice is lent the way its name is | `total(w[1..3])` was rejected: "a slice of an array or Vec views it; write `?w[1..3]`" | `total(w[1..3])` is `total(?w[1..3])`, as `total(w)` is `total(?w)` |
| A write call whose value is used puts its `!` in parentheses | required only where a `Bool` value was used | required wherever the value is used, whatever its type: `x = (!v).pop()`, `while (!it).next() as x` |

- **CORE §4** says a slice goes unwritten as an argument where its name does. **CORE §8**'s bullet reads "A write call whose value is used".
- **README and WELCOME** say, beside the `?`/`!` table: a write call whose result is used goes in parentheses, `if (!set).insert(k)`, so its `!` never reads as "not".
- **ROADMAP, IDEAS §0.3, and rig-questions.md** state the iterator desugaring as `while (!it).next() as x`.

## 1. A slice argument is lent to read
- **The rule.** An argument written `xs[a..b]`, `xs[a..]`, or `xs[..]`, of an array, a Vec, a Text, or a `![]T` (also through a field or a `!` or `?` parameter), is `?xs[a..b]` where its parameter takes the read view that makes: a `[]T` or a String, or an optional of one. This covers functions, methods, nested calls, closures, and generic functions; a generic parameter is decided by what it is instantiated to, as for a bare name.
- **Everywhere else a slice is still written with its lend:** a binding, a field, a result, a constructor's field, `print`. Those diagnostics are unchanged.
- **Rejected with what to write:**
```
`zero` writes the elements of `a[1..]`, and a slice is lent to read unless it is written `!`; write `zero(!a[1..])`
`own` takes a `Vec[Int]`, which owns its elements, and `v[..]` only views `v`'s
`name` takes a `Text`, which owns its bytes, and `t[1..]` only views `t`'s; write `name(Text(?t[1..]))` to pass a copy
```
- **Desugaring** (docs/INTERNALS.md, "A read lend left unwritten"). An unmarked slice argument desugars to `?xs[a..b]`.
  - `synthSlice` types it as that lend. Whether a slice lends what it slices is one decider, `sliceLendsObject`; a slice of a String, a `[]T`, or a view of a Text is a value, as before.
  - The same branch of `lendView` that decides a bare name's implicit lend records it: `recordImplicitLend` and a `Lend` with `implicit` set and no rows, since the slice is the view already.
  - The ownership checker walks an implicit lend with no rows as `?e` (`walkImplicitLend` → `walkLend` → `walkElems`), exactly the walk of `?xs[a..b]`.
  - Emit writes it as it writes `?xs[a..b]`.
- **The proof that it is the same lend.** In the grid below, every accepted bare form emits the same Zig, and the same sanitized package, as its written `?` form.
- **The `?` already written stays.** SPEC says the `?` "may go unwritten" and states no preference, so no slice argument in the tree was changed.

## 2. A write call whose value is used
- **The rule.** The short form `!v.m(...)` stands only where the call's value is discarded: a statement, alone or under `!`, `?`, or `catch`. Anywhere else the value is used, and the call is written `(!v).m(...)`: a condition, an `as` header, an operand, a binding (`_ =` too), an argument, an array element, `return`, a function's or a closure's last line, a `match` subject, a value `if`'s branch, `??`, and a `catch` whose value is used.
- **The diagnostic** gives the call to write:
```
write `(!v).remove(0)`: a write call whose value is used puts its `!` in parentheses
```
- **One decider, widened.** `Checker.usesBoolValue` became `usesValue`: a value that is not `Void`, after unwrapping `T!`, and a call `isDiscardedCall` does not discard. No second check was added.
- **Every hint that writes a write call** now writes the form its use takes, through one helper, `writeCall`. Before, following some hints in a value position drew the new error. The hints covered:
  - `?v.pop()`;
  - `<v.pop()`;
  - `v.pop()` with no sigil (`(!receiver).pop(...)`);
  - a held write view's `w.pop()`;
  - a temporary's `mk().pop()`.

  `isDiscardedCall` compares receivers as expressions (`sameExpr`), so a bare name's statement call is seen as discarded.

## 3. Lows from review-syntax-a-2
- **L1.** The spacing hint skips a comment that ends the line before: `print(n # the count` ⏎ `-1)` now says `` `n -1` `` (`operandBefore`, `commentStart`).
- **L2.** Whether `<x` drops a binding is decided once, `sema.undroppable`:
  - a view parameter;
  - a closure's capture (`moveSource`'s `.capture`);
  - a `for` element that views a slot of the Vec it walks (`sema.forViewsSlot`, which typecheck marks on the element as `slot_view` and the ownership checker reads as its loop view).

  The ownership checker rejects `<x` by it. The type checker's hint for a statement `-x` offers `<x` only where it drops, and otherwise says why:
```
this expression does nothing as a statement: `-v` negates a value and discards it; a closure keeps what it captures for every call, so `v` is not dropped here
this expression does nothing as a statement: `-x` negates a value and discards it; `x` views an element the loop walks, which is dropped with what holds it
```
- **L3.** SPEC: a statement `<?x` or `<!x` "does nothing, and is rejected", and where the `-x` hint offers `<x`.

## 4. Review round 1: a slice of a write view of a Text (Critical, C1; main had it too)
- **The bug.** A slice of a write view of a Text (`t: !Text`, then `s = word(t[1..])` or `s = t[1..]`) was taken as a String value that lends nothing, because one decider, `sliceLendsObject`, called every view of a Text a value. A later `!t.add(...)` or `t = Text(...)` freed the bytes `s` still viewed: use of freed memory under the sanitizer, garbage in `--release`. The written form `?t[1..]` was rejected, as it should be. The oracle accepted the bad forms too.
- **The class:** "whether a slice lends what it slices", for every holder and every way of reaching it. `sliceLendsObject` is now a positive list, stated in its comment and in INTERNALS:
  - an array's or a Vec's elements, owned or through any view, box, or handle: lent;
  - a `![]T`'s elements: lent;
  - a Text's bytes, owned, boxed, behind a `*T`, or through a **write** view of any of these: lent, since the holder may add to the Text or replace it;
  - a Text's bytes through a **read** view (`?Text`, `?*Text`, `?Box[Text]`): not lent. The Text cannot change while that view's loan lives, and the String carries it;
  - what a String or a `[]T` views, written or not: not lent, since writing the String or the `[]T` itself frees nothing.
- **One decider for every path.** `sliceLendsObject` decides the bare argument, the binding (`s = t[1..]` is now "a slice of a Text views it; write `?t[1..]`"), a `for` source, and the written `?` form, which `synthSlice` serves for all of them. No other site decides it: the ownership checker walks a lent slice as `?xs[a..b]`, and an unlent one as a value that carries its object's loans.
- **The siblings checked:**
  - `!Text` as a parameter, a local, and a field holding `!Text`, with `!*Text` and `!Box[Text]`, each written through by `add` and by assignment;
  - a `?Text`, `?*Text`, `?Box[Text]`, or `!String` slice, which is still a value: `behavior/ownership/slice_of_text_view.rig`;
  - a Text field reached through a `!B`, which is owned: lent;
  - `![]T`, a `!Vec`, a `![N]T`, a `?[N]T`, and a `?Vec`: lent, as before;
  - `*Vec`, `*[N]T`, `Box[Vec]`, and `Box[String]` cannot be sliced, on main as here.
- **The oracle had the same gap**, and now matches. `bin/rig-oracle` lent a bare slice only of an owned place (`placeValue`). It now lends one reached through a write view too, except a slice of a String (`slicesString`), and rejects all nine probes with C4. No difference needed recording.
- **New behavior:** `s = w[1..]` and `for b in w[1..]` over a write view of a Text are rejected with "write `?w[1..]`", as for the Text itself. The bound form was the use-after-free; the `for` form was safe, but accepted only through the same misclassification.

## 5. Review round 2
The review found the C1 fix correct, and found no slice that `sliceLendsObject` misclassifies.
- **M1 (new in 81b97d2f): the oracle rejected correct programs.**
  - The oracle's `placeValue` lent every slice reached through a write view except a String's. The compiler, rightly, does not lend a read view held in a field or element so reached: `s = w.f[1..]; w.f = u` with `f: ?Text`, `?Box[Text]`, or `?*Text`, and the same through `w = !r` and a `!Vec[?Text]` element. Each would have failed any oracle run that met it (`prod=accept ref=reject`).
  - The fix: `slicesString` treats a read view like a String, since what it views cannot change while its loans live, and the slice carries them.
  - `behavior/ownership/slice_of_read_view_through_write.rig` (`# release`) holds the five programs, with `# oracle: ... accept` lines. The oracle before the fix rejects all five.
  - The C1 class is still rejected by the oracle.
- **L1: a slice of a view a call returns, as an argument.** `keep(get(!h)[1..])` said the temporary "outlives its statement, which drops it", which is wrong for a view. It now says: "a view reached through `get(!h)` outlives its statement, which holds `get(!h)`, itself a view, only while it runs; bind `get(!h)` to a name first" (`reject/ownership/slice_of_view_result.rig`). The bound form, `w = get(!h)` then `keep(w[1..])`, runs clean. Lending through the view to what it carries is left for the C2 round, as the reviewer suggests.
- **L2: a slice of a branch of write views.** `keep((a if c else b)[1..])` with `a`, `b`: `!Text` drew two "bare use of write view ... use `<a`" errors.
  - `lendTemp`, the one place that rejects lending a branching value a name may hold, now covers a write view as it does a value that moves.
  - Its hint writes the slice with each branch lent: "cannot lend `a if c else b`: it may be `a`, a value a name holds, which lending the branching value would copy; lend what each branch reaches instead (`(?a if c else ?b)[1..]`)" (`reject/types/slice_of_branch_write_views.rig`).
  - The hinted form runs clean (`behavior/ownership/slice_of_view_bound_first.rig`).
  - The same programs were rejected before, so nothing changes what is accepted.
- **Not done here: C2,** a loan of a `match !x` payload binding that does not lend the binding (main has it too). It gets its own round. Review 2's probes are not in the corpus yet: the C2 probes are use-after-free until that round lands, and that round adds them.

## The rewrite
`.git/revamp/r3/syntax-b/rewrite.py` (`scan` / `apply`) is driven by the new compiler's diagnostics: it puts the receiver each one names in parentheses. It reads:
- every tracked `.rig` program (a directory with `main.rig` is one);
- `std/` through a program that uses every module, with `RIG_STD`;
- every ```` ```rig ```` doc block, with the `file=` modules before it;
- the test/cli heredocs.

It moves the `# error: L:C:` directives an insertion shifts. Each `apply` reaches more: std's rewrite let the `std.random` programs typecheck, so it ran to a fixed point in three passes. `scan` on the head reports 0 files.

**Left as written (KEEP):** the programs whose point is the rule, and review round 1's probes, which the corpus keeps as written.
- reject tests `receiver_sigil_bool_result`, `receiver_sigil_bool_used`, `receiver_sigil_value_used`, `write_call_hint_value_used`;
- the doc examples whose error is the rule's;
- nine corpus probes of the Bool rule, which stay rejections with the new message: docs-probes-nb2, purity-designer-r13_bool_short, r3-s36-docs-p32, r3-s36-emit-s19, review-sc3-n2/n3/n4, review-seam2-q03_bool, syntax-review-symmetry-p_ptr_bool_write_call.

**Not reached by the compiler, so listed as `UNCHECKED`:**
- programs rejected before the type checker;
- prose, edited by hand (SPEC, SYNTAX, ROADMAP, IDEAS, INTERNALS, a std comment).

**Result:** 312 files, 561 lines:
- 175 corpus probes;
- tests;
- `std/random.rig`;
- `examples/generics.rig`;
- the doc examples in README, WELCOME, SPEC, SYNTAX, CORE, and STD.

The matrix's Cell-temporary value form `!t.bumpw()` became `(!t).bumpw()`.

## Commits (since main 79768d0b)
- 55d70acb **Lend a slice argument to read the way its name is** (compiler, tests, SPEC, SYNTAX, CORE, INTERNALS, the matrix family, two `ref-gap` lines in test/oracle/differences).
- c1bf4a7d Put the `!` of each write call whose value is used in parentheses (rewrite.py). The long form is valid on main, so this commit is green on its own.
- 92a4ccd9 **Put the `!` of a write call in parentheses wherever its value is used** (compiler, the rule's tests, the SPEC and CORE examples, the matrix template).
- ed833567 Document the parenthesized write call for every value.
- 4ae82202 Quote the operand, not a word of a comment, in the spacing hint (L1).
- a16d310d **Offer `<x` for a statement `-x` only where `<x` drops, by the rule that rejects it** (L2).
- d82dbbd3 Say in SPEC that a statement `<?x` is rejected, and where `-x` offers `<x` (L3).
- 4d8cb4a8 Write the long form in every write-call hint whose value is used.
- 81b97d2f **Lend a slice of a write view of a Text, as `?` does, in the compiler and the oracle** (review round 1, C1).
- f76a6bdb Add a matrix family of slices however their object is held.
- 15b151da Keep review 1's syntax-b probes in the corpus (159 probes).
- 16626db8 **Copy a slice of a read view reached through a write view in the oracle** (review round 2, M1).
- 5ba3b483 Say a view a statement holds is a view, not a temporary it drops (L1).
- d4da0283 Lend each branch of a sliced branch of write views, and say so (L2).

## Tests
- **Rule 1, behavior:** `behavior/ownership/slice_argument_lent.rig` (`# release`). It covers:
  - an array, a Vec, a Text, a nested field, a `!Vec` parameter, and a `![]T` parameter;
  - a `[]T`, a `([]Int)?`, a String, a `String?`, and a generic `[]T` and `T`;
  - a function, a method, a nested call, a closure, and a generic function;
  - a held result keeping the array lent until its last use.
- **Rule 1, reject:**
  - `reject/ownership/slice_argument_lend.rig` (4 errors, `# oracle: main reject C4`): the loan a slice argument makes, a later argument that writes it, and a temporary's slice outliving its statement;
  - `reject/types/slice_argument_needs_read_view.rig` (8 errors): the `!`, owned, and `?[]T` parameters, plus the binding, field, and result forms that stay written.
- **Rule 2:**
  - `behavior/types/receiver_sigil_value_used.rig` (`# release`): the long form in every value position, and the short form under `!`, `?`, and `catch`;
  - `reject/types/receiver_sigil_value_used.rig` (15 errors);
  - `reject/types/write_call_hint_value_used.rig` (7 errors);
  - the Bool tests, updated.
- **Lows:**
  - `reject/syntax/spacing_hint_after_comment.rig` (4);
  - `reject/syntax/minus_statement_view_hint.rig` (7);
  - `reject/ownership/drop_statement_undroppable.rig` (4).
- **C1:**
  - `reject/ownership/slice_of_write_view_text.rig` (8 errors, with `# oracle:` lines): `!Text` as a parameter, a local, and a field, `!*Text`, and `!Box[Text]`, each written through by `add` or by assignment while the argument slice is used;
  - `reject/types/slice_of_write_view_text_bound.rig` (5): the same holders, bound bare;
  - `behavior/ownership/slice_of_text_view.rig` (`# release`): slices of `?Text`, `?*Text`, `?Box[Text]`, and `!String`, which stay values, and a write view of a Text written again after its slice's last use.

  Both reject tests are accepted on the previous head, 4d8cb4a8, and on main.
- **Failing first:** each reject test fails on main. The rule-1 behavior test fails on main too; the rule-2 behavior test passes on main, since the long form was always valid.

## Verification
Gates on the head d4da0283 (`--delta`, through cpuq via heavy.sh, one at a time):
- suite: 3012 passed, 0 failed, 3 pending;
- corpus: 8547 passed;
- matrix: 6133 programs, 3322 ran clean, 2811 rejected, 0 failed.
  - The `slice_arg` family is 96 programs.
  - The `sliceview` family is 160 programs: 47 ran clean and 113 were rejected. It covers 10 holders (owned, `?`, `!`, `*T`, `!*T`, Box, `!Box`, a field, a field holding `!T`, a nested field) × array, Vec, Text, and String × an argument or a bare binding × the owner changed while the slice is used, or after. The oracle reports no difference over it;
- unit: 135 passed, 1 skipped (fresh cache dir);
- the oracle's five sets pass in the suite.

The grid and the equivalence run below were done on 15b151da. The three round-2 commits change only the oracle and two diagnostics. The second rejects with one error what was already rejected with three.

**Grid for rule 1** (`.git/revamp/r3/syntax-b/grid_slice.py`): 420 cells, 178 ran, 218 rejected, 24 not applicable (a closure cannot take a generic parameter), 0 bad. On 4d8cb4a8 the new `!Text` kind alone finds 10 bad cells.
- **Cells:**
  - 12 slice kinds: an array, a Vec, a Text, a String, a nested field, a `!Vec` parameter, a `?[4]Int` parameter, a `?Text` parameter, a `!Text`, a `!*Text`, and a `!Box[Text]` parameter, and a `![]T` parameter;
  - 7 parameter kinds: `[]T` or String, an optional of one, `?[]T` or `?String`, a generic `[]T`, a generic `T`, `![]T`, and an owned `Vec` or `Text`;
  - 5 contexts: a direct call, a method argument, a nested call, a closure call, and a generic function.
- **Each cell must:**
  - be accepted exactly where its written form is (except the write and owned parameters, which reject the bare form with their hint);
  - emit the same Zig and sanitized package as the written form;
  - run sanitizer-clean in debug and `--release`, printing the slice's value and then the change after the call;
  - have `bin/rig-oracle -v` reject no function the compiler accepts.

**`test/equiv.py` against main 79768d0b, on 15b151da:** 11028 programs, 165 differ. None differ in `storage`, `emit`, or `pkg`, so every program both accept emits identical Zig and an identical package.
- **Sema:** one program differs, the new `behavior/ownership/slice_of_text_view.rig`. Its two argument slices of a write view of a Text are now recorded as implicit lends, the fix, and its emitted Zig is identical.
- **Review probes:** 115 of the 159 differ.
  - 13 are now accepted: valid bare slice arguments.
  - 8 are now rejected for C1.
  - 22 are now rejected for rule 2.
  - The rest are rejected by both, with new wording.
- **The other 49** are the 47 below, plus the two new C1 reject tests.
- The 47 from before the fix are `check`/`facts` differences, except one `normalize`:
  - the 8 new tests;
  - 10 tests updated by hand with the new wording (the rule's tests, the value-aware hints, an IR snapshot's diagnostics);
  - 24 corpus probes:
    - rejected with the new wording;
    - `t-p4`, now rejected by the loan its slice argument makes instead of by "write `?v[..]`";
    - four lend-base probes whose path error now carries its rewrite, since the slice argument is no longer an error of its own: r10 and r11 compile with it; h04 and h05 pass to a `?[]Int`, so their rewrite draws the type mismatch the program already draws, at the same place, which the hints check allows;
  - 5 doc blocks: two new SPEC slice examples, a new SPEC reject example, and the SPEC and CORE examples of the rule's message.
- Only `slice_argument_lent` (new) and `receiver_sigil_value_used` (new) changed whether they are accepted.
- An earlier run found one emit difference: `behavior/types/text_views_as_strings.rig`, a String slice of a `?Text` call result as an argument, got a needless statement slot. The fix lends an argument slice only where it lends what it slices, and is folded into 55d70acb.

**`compare_rewrite.py`** compares main's compiler on each original against the new compiler on the head: 330 programs (the changed `.rig` files and paired doc blocks).
- 211 both accept, with identical emit and sanitized package;
- 110 both reject alike;
- 9 both reject with new wording: the rule's tests and the value-aware hints.

## Decisions to confirm
Each is built the conservative way.
1. **`?[]T` and `?String` parameters.** The brief lists "`?T` of one". A slice argument is accepted only where `?xs[a..b]` is, and main rejects `f(?w[1..3])` for `f(x: ?[]Int)` ("expected `?[]Int`, got `[]Int`"). So the bare form is rejected there too, with the same message. Accepting it would lend the slice value, a temporary, as `?[]T`: a new rule for the written form too.
2. **`print(w[1..3])` and `Text(t[1..])`** are arguments, but of built-ins with no declared parameter, which `lendView` never sees. They stay written: `print(?w[1..3])`.
3. **A slice of a branching value** is accepted or rejected exactly as its written form is. `total((a if c else b)[..2])` of arrays, which copy, is accepted (review probe s71). A branch whose leaves are names of Vecs or Texts is rejected, with the planned `?(a if c else b)` message.
4. **A capture is never dropped by `<x`.** `sema.undroppable` follows `moveSource`, so `<s` of a `|+s|` String capture, a no-op that main accepted, is rejected: "cannot drop captured `s`; the closure keeps what it captures for every call".
5. **`_ = !v.pop()` uses the value**, as it did for `Bool`, so it is written `_ = (!v).pop()`. The short form is a statement alone, or under `!`, `?`, or `catch`.

## Migration (v0.3.0 release notes)

| Old | New | What the compiler says about the old form |
|---|---|---|
| `x = !v.pop()`, `y = !v.remove(0)` | `x = (!v).pop()` | write `(!v).pop()`: a write call whose value is used puts its `!` in parentheses |
| `while !it.next() as x`, `if !q.pop() as t` | `while (!it).next() as x` | the same, with the call to write |
| `print(!c.next())`, `n = !c.next() + 1`, `[!c.next()]`, `!v.pop() ?? 0` | `print((!c).next())`, `(!c).next() + 1`, ... | the same |
| a `fun`'s or closure's last line `!self.items.pop()`, `return !c.next()`, `match !c.next()` | `(!self.items).pop()`, `return (!c).next()`, `match (!c).next()` | the same |
| `_ = !v.pop()` | `_ = (!v).pop()` | the same |
| `f = \|!v\| !v.pop()`, also when `f()` is called as a statement: a closure's expression body is its value | `f = \|!v\| (!v).pop()` | the same |
| `x = !mk().pop()` (a temporary) | `x = (!mk()).pop()` | the same |
| `!v.push(1)`, `!v.pop()`, `!v.pop()?`, `!c.take()!`, `!c.take() catch 0` as statements | unchanged | (accepted) |
| `total(?w[1..3])` | `total(w[1..3])` also works; both are valid | (accepted) |
| `zero(w[1..])` where `zero` takes `![]Int` | `zero(!w[1..])` | `zero` writes the elements of `w[1..]`, and a slice is lent to read unless it is written `!`; write `zero(!w[1..])` |
| `name(t[1..])` where `name` takes a `Text` | `name(Text(?t[1..]))` | `name` takes a `Text`, which owns its bytes, and `t[1..]` only views `t`'s; write `name(Text(?t[1..]))` to pass a copy |
| `<s` of a `\|+s\|` capture that copies | remove it: the closure keeps its captures | cannot drop captured `s`; the closure keeps what it captures for every call |
| `s = w[1..]`, `for b in w[1..]`, or `w[1..]` as a function's last value, with `w` a write view of a Text (`!Text`, `!*Text`, `!Box[Text]`; bound, the old form was a use-after-free) | `s = ?w[1..]`, `for b in ?w[1..]`; a bare argument `f(w[1..])` lends `w` | a slice of a Text views it; write `?w[1..]` |

`.git/revamp/r3/syntax-b/rewrite.py apply` makes the write-call rewrite in a checkout with the new compiler built (`bin/rig`): run it until it reports 0 files. It leaves programs whose point is the short form (KEEP), and lists as `UNCHECKED` the short forms the compiler did not reach.
