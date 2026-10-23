# `from @field`: the final paragraph for the owner (panel of 4, accepted with the reviewer's edits)

CORE §2, sentence 7, after "…or, when the result says `from a`, of `a` alone.":

> A method's `from` may also name a path of self, as §5 defines one
> (`from @text`, `from @a.b`), whose type could hold what the result
> views. The result then carries the loans self holds and a loan on that
> path alone, not on all of self, so a use of self's other paths may go
> on while it lives; a use of all of self (`(!s).m()`, `!s.m()`, `<s`,
> `s = x`) still touches the path. When the path is a field declared as
> a read view (`?T`, `[]T`, `?String`, or an optional of one), the
> result carries the loans self holds and none on self, so self may be
> lent again, even to write, while the result lives; when self is itself
> a view, its loans are the loans that view carries. The body is checked
> against the path: each view it returns comes from that path, a view a
> call through a bound returns included. *(built)*

## Rules, as built (4-draft.md, with the reviewer's edits)
1. The path is a §5 path. A path through a read view is rejected with "write `from @map`".
2. **An owned path:** a loan on `self.p`, plus the loans self holds.
3. **A read-view field:** the loans self holds, copied at the call (G2), and none on self. When self is a view, those are that view's loans (G1).
4. **Rule 2 applies, never rule 3,** for handle, box, or type-variable fields.
5. **No write-set inference:** any use of all of self touches the path.
6. **The body:** a call through a bound is treated as viewing its receiver. A read view of a read-view field is that same view (G3: no error).
7. `from @map, k` combines; `from @, @text` is rejected.
8. **Through a bound:** narrower than the API's `from @`. An API names no fields.
9. **`[I: Iter]`** accepts an instance whose `next` names only read-view fields, or whose item reaches nothing.
10. **std:** `Items`, `Keys` and `Values` get `from @map`, and `Members` gets `from @set`. The failing case becomes a test. SPEC's pending Scanner becomes ordinary.

Must-pass tests before *(built)*:
- the Scanner verbatim, and `f(it: !Items)` holding two items (G1);
- the field pointed at a shorter-lived map after the call, and a `put` to the old map while an item lives, which is rejected (G2);
- `(!m.items()).next()` used later passes, and `(!mk()).word()` used later is rejected.

Panel reports: 1-core.md, 2-compiler.md, 3-adversary.md, 5-review.md (this folder).
