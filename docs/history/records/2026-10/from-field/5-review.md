# `from @field`: reviewer (expert 4)

The rules close H1–H6, with no new soundness hole in the rules.

## Holes

**G1 (high). A self that is itself a view.** SPEC's pending Scanner `number(!@)` calls `(!@).digits()` twice while `whole` lives. If rule 3's "self's loans" turns into a loan on `@` (or on `it` in `f(it: !Items[K, V])`), the second call conflicts and the motivating example stays rejected.
*Fix, rule 3:* "when self is a view, its loans are the loans that view carries, never a loan on the view."
*Tests:* that Scanner verbatim; `f(it: !Items[K, V])` holding two items.

**G2 (soundness). "Loans attach at the call" only holds if they are copied there.** Take `a = (!it).next()`, then a block with `m2 = Map(); it.map = ?m2`, then `print(a)`. This is sound only if `a`'s carry is copied at the call, not linked to `it`'s current carry (checker and oracle `resultCarry`).
*Tests:* that program runs; `it.map = ?m2; !m1.put(...)` while `a` lives is rejected.

**G3 (wrong error).** "returns a view of `@map` itself" contradicts §4: a read view of a read view is that view. `rest(?@) -> ?String from @text` returning `@text` is fine. *Fix:* drop that error.

**Checked, sound:**
- `!@` cannot write through a read-view field. Cells hand out no views.
- A replaced box `s.a` conflicts under rule 2 and is harmless under rule 3.
- Also sound: `(?T)?` fields, `Wrap[T]` (rule 2), closures, and `defer`.
- *Tests:* `a = (!m.items()).next()` used later passes; `(!mk()).word()` used later is rejected.

## Over-restrictive, later
A future `Take[I]{inner: I}` over `Items` fails `[I: Iter]` under rule 4; judge type-variable fields per instance. An owned-`String` lexer stays rejected (H1); that is intended, and `src: ?String` is the answer.

## Wording
- Rule 4: delete "write-view". §5 stores none.
- CORE: "(`!s`, `(!s).m()`, `<s`, `s = x`)" becomes "(`(!s).m()`, `!s.m()`, `<s`, `s = x`)", §5's list.
- CORE: "the result carries that view's loans and none on self" becomes "the result carries the loans self holds and none on self". (rule 3).
- CORE, last sentence: "The body is checked against the path: each view it returns comes from that path, a view a call through a bound returns included."

"A field declared as a read view" is the right line: it is declarative, and §5 rules out the rest.

## Verdict
**Accept with these edits;** test G1 and G2 before *(built)*.
