# Places and views: CORE's sentences and the commonest messages, old and new

2026-11-20. Step 1 of the vocabulary change, rewritten in the words the
owner settled after panels 2 to 4 (`decisions.md`, beside this file).
This file is for the owner's read before anything lands. It changes
wording only: no program is accepted or rejected differently, and the
emitted Zig does not change.

The words:

- A **place** is a variable, a field, or an element: what `?` or `!` is
  put on.
- A **read view** is what `?x` makes, and a **write view** what `!x`
  makes. A view has no other qualifier.
- Any view leaves its place **read-only** until its last use: the place
  may be read, copied, and given more views, but not changed, assigned,
  moved, or dropped.
- A write view of an ordinary value goes further: its place is
  **unusable** until the view's last use. It comes back by itself, which
  is how it differs from a move.
- A **cell** is a `Cell`, or a value that holds one directly: a `Signal`,
  a channel, an actor, or an object with a `Cell` field. An ordinary
  value is anything that isn't a cell.
- Lend, lent, read loan, write loan and exclusive loan leave the docs and
  the messages. "Loan" stays as the compiler's word for its record, and
  in CORE only where that record is meant. "Owner" keeps its one
  meaning: who moves and drops a value.
- Messages name the act at the caret and the view that blocks it.

Below, each passage shows CORE's text today, then the new text. Text
that does not change is left out ("…").

## The "Three words" preface, rewritten whole as "Places and views"

**Today:**

> **Three words.** *You lend a view; the compiler remembers the loan.*
>
> The sigil is written on the owner's side. In `print(?v)` and
> `grow(!v)`, the `?` or `!` sits on `v`, the owner, exactly where the
> owner hands something over. So the verb belongs to the owner: `v`
> **lends**. Each of the three words belongs to one side of that
> hand-over, and means one thing only:
>
> | Word | What it is | Which side | Where you see it |
> |---|---|---|---|
> | **lend** | the act | the owner's | the sigil: `?x` lends to read, `!x` lends to write |
> | **view** | the value handed over | it travels with the holder: copied, returned, stored | a value of type `?T`, `!T`, `[]T`, or `![]T` (the read view of text is `?String`) |
> | **loan** | the record | it stays with the owner, and limits the owner until every view is done | in the compiler, and in its error messages |
>
> - To **lend** `x` is to let someone use it without taking it. […]
> - A **view** is what they get. […]
> - A **loan** is the compiler's record that views of `x` exist. […]
>
> One lend makes one loan, which any number of views may carry:
>
> *(example)* ``cannot lend `v` to write while a read loan is live``
>
> The lend is on line 4 (`?v[..]`). The loan stays with `v` while the
> views `a` and `b` are still used below, so `!v.push(2)` is rejected.
> *Borrow*, the word Rust uses, names the same event from the callee's
> side; Rig names everything from the side the sigil is on.

**New:**

> **Places and views.** *A sigil on a place makes a view, and the place
> is limited until the view's last use.*
>
> In `print(?v)` and `grow(!v)`, the `?` or `!` sits on `v`, the
> **place**: a variable, a field, or an element. What it makes is a
> **view**, a value of type `?T`, `!T`, `[]T`, or `![]T` (the read view
> of text is `?String`), which may be copied, returned, and stored.
>
> | `?x` makes | `!x` makes |
> |---|---|
> | a **read view**: its holder reads through it | a **write view**: its holder may also change through it |
>
> - Any view leaves its place **read-only** until its last use: the
>   place may be read, copied, and given more views, but not changed,
>   assigned, moved, or dropped.
> - A write view of an ordinary value goes further: its place is
>   **unusable** until the view's last use, as after a move, except that
>   it comes back by itself.
>
> A **cell** (sentence 9) is not ordinary: it changes only through its
> own calls, so a write view of it leaves its place read-only. Copying a
> read view copies the view, not what it views. A view costs nothing at
> run time: what it leaves its place is checked by the compiler alone.
> In Rust's terms, a read view is a `&T`, and a write view of an
> ordinary value is a `&mut T`.
>
> *(same example)* ``cannot change `v` while a read view of it is still in use``
>
> `?v[..]` on line 4 makes a read view, and `b = a` copies it. `v` stays
> read-only while `a` and `b` are still used below, so `!v.push(2)` is
> rejected. *Borrow*, the word Rust uses, names the same event from the
> callee's side; Rig names everything from the side the sigil is on.

## §2, sentences 4 to 9

**Sentence 4, today:**

> **4. `?x` lends `x` to read, and `!x` lends it to write, as whichever
> view the context expects** ([§4](#4-one-lend-table)). `?` promises
> that nothing changes. A read lend may go unwritten where its view
> lasts only for the use: […]. A lend is written wherever its view may
> outlast its statement: when it is kept in a binding or a field, kept
> by the call it is lent to (`!p.watch(?t)`), […]. So is every write
> lend. […] `!` lends any value to write, named or temporary:
> `!mk().pop()` lends the value `mk()` makes, […]. A written `!` must
> lend to write: […] Write `x` to copy it, `?x` to lend it to read, or
> `!T` in the type to keep the write view.

**New:**

> **4. `?x` makes a read view of the place `x`, and `!x` a write view,
> whichever the context expects** ([§4](#4-one-view-table)). Nothing
> changes what a read view sees while it is in use, except a cell's own
> calls (sentence 9). A `?` may go unwritten where its view lasts only
> for the use: […]. The sigil is written wherever its view may outlast
> its statement: when it is kept in a binding or a field, kept by the
> call it is passed to (`!p.watch(?t)`), […]. So is every `!`. […] `!`
> makes a write view of any value, named or temporary: `!mk().pop()`
> makes one of the value `mk()` makes, […]. A written `!` must make a
> write view: […] Write `x` to copy it, `?x` to make a read view, or
> `!T` in the type to keep the write view.

**Sentence 5, today:**

> **5. A place has any number of read loans, or one write loan, never
> both.** A loan on a place covers every place inside it, so two places
> conflict when one holds the other: `p` and `p.a`, `p.a` and `p.a.b`,
> but not `p.a` and `p.b`. This holds for every type, numbers included.

**New:**

> **5. Any view leaves its place read-only until its last use, and a
> write view of an ordinary value leaves it unusable.** Read-only: the
> place may be read, copied, and given more views, but not changed,
> assigned, moved, or dropped. Unusable: it may not be used at all. A
> cell is not ordinary (sentence 9). A view of a place covers every
> place inside it, so two places conflict when one holds the other: `p`
> and `p.a`, `p.a` and `p.a.b`, but not `p.a` and `p.b`. An element is
> not told apart from its array or List: a view of `a[0]` covers all of
> `a`. This holds for every type, numbers included.

**Sentence 6, today:**

> **6. A loan lasts until the last use of every view that carries it,**
> wherever that view went: […]. Dropping a value uses the views it
> holds only when its drop runs a `drop` body, which could read them, so
> a `List[[]Int]`'s loans end at its last use, not where it is dropped.

**New:**

> **6. A place stays read-only or unusable until the last use of every
> view of it,** wherever that view went: […]. Dropping a value uses the
> views it holds only when its drop runs a `drop` body, which could read
> them, so the views a `List[[]Int]` holds end at its last use, not
> where it is dropped.

**Sentence 7, today** (the passages that change):

> A function returns a view only of what it was lent, […]. Its result
> carries the loans of the arguments whose types could hold what it
> views, or, when the result says `from a`, of `a` alone. […] so self
> may be lent again, even to write, while the result lives; […] A result
> that holds no write view carries its loans as read loans, even one of
> an argument lent to write, whose write lend then ends as the call
> returns unless the call keeps it: after `head(!v)`, […] `v` may be
> read, but not written, while the result lives. […] What a call stores
> in what a write view lent to it sees carries, in the same way, the
> loans of the arguments whose types could hold it; for a lent parameter
> (a view, an optional of one, or self), […] A kept loan lasts while the
> holder is used, though the holder's own write lend ends as the call
> returns; a lend the call does not keep lasts no longer than the call
> and its result. […] a body that stores a lent parameter, on any path,
> […] names it in `keeps`.

**New:**

> A function returns a view only of what was passed to it as a view,
> […]. Its result counts as a view of each argument whose type could
> hold what it views, or, when the result says `from a`, of `a` alone.
> […] so self may be given another view, even a write view, while the
> result lives; […] A result that holds no write view counts as a read
> view, even of an argument passed as a write view, whose write view
> then ends as the call returns unless the call keeps it: after
> `head(!v)`, […] `v` is read-only, not unusable, while the result
> lives. […] What a call stores through a write view passed to it
> counts, in the same way, as a view of each argument whose type could
> hold it; for a view parameter (a view, an optional of one, or self),
> […] A kept view lasts while the holder is used, though the write view
> of the holder ends as the call returns; a view the call does not keep
> lasts no longer than the call and its result. […] a body that stores
> a view parameter, on any path, […] names it in `keeps`.

**Sentence 8:** no lend or lent, and no change.

**Sentence 9, today** (the passages that change):

> **9. Shared storage.** You change what you were lent with `!`, or
> what you share with `*`. A name's own value changes by assigning it.
> What you share changes only by a marked call, `!c.set(5)`: a `Cell`,
> a `Signal`, a channel, an actor (SPEC §18), or a value that holds a
> `Cell`, and §4 says what the call lends. […] and `?f` lends the frozen
> value as a `?T`.

**New:**

> **9. Shared storage and cells.** You change what a write view sees
> with `!`. A name's own value changes by assigning it. What you share
> through `*` changes only by a marked call, `!c.set(5)`, and only a
> **cell** has such calls: a `Cell`, or a value that holds one directly,
> which is a `Signal`, a channel, an actor (SPEC §18), or an object with
> a `Cell` field. A cell changes only through its own calls, each one
> complete step, so a write view of it leaves its place read-only, not
> unusable, and many views of it may be in use at once (§4). […] and
> `?f` makes a read view of the frozen value, a `?T`.

## §4: the title, and the rule for a cell

The title "One lend table" becomes **"One view table"**. In the table,
the column heads "`?x` lends" and "`!x` lends" become "`?x` makes" and
"`!x` makes", and "(lent on)" becomes "(passed on)".

**The rule, today:**

> `!x` puts a write loan on `x`, and only a read loan when what it lends
> is a write view of a value that changes by a marked call (sentence 9),
> by a marked call or alone: `!c.set(5)`, […]. Such a value lives only
> behind `*`. It is never replaced whole (`swap` exchanges none: a
> Cell's own `!c.swap(v)` does, in one step), and every view it gives out
> lasts while it lives, which each such type, std's `shared.Map` among
> them, meets by its declaration. So many write views of it may live at
> once, each changing only what every handle shares, while `x` stays put
> and keeps the value alive. […] The loan is judged by the concrete type
> of the value lent from, not by the view it becomes: `!h` of a `*Hits`
> lent where a `!{A}` goes lends `h` to read. A value whose type is an
> API object `{A}` or a type parameter is no such value, so two `!{A}`
> lends of one owned value, or of a `!{A}` parameter, are two write
> loans, and `!s` of a `*{A}` lends only the handle. `!h` that lends the
> handle itself, a `!*T` the callee may point elsewhere, puts a write
> loan on `h`, […]

**New:**

> `!x` leaves `x` unusable, except where it makes a write view of a
> cell (sentence 9), by a marked call or alone: `!c.set(5)`, […]. A cell
> lives only behind `*`, so its place holds a handle. It is never
> replaced whole (`swap` exchanges none: a Cell's own `!c.swap(v)` does,
> in one step), and nothing it hands out can dangle: every view it gives
> out lasts while it lives, which each such type, std's `shared.Map`
> among them, meets by its declaration. So a write view of it leaves
> the handle only read-only, and many may be in use at once, each
> changing only what every handle shares, while the handle stays put and
> keeps the cell alive. Each call is one step; two calls are two steps,
> and another task may act between them. […] What a write view leaves
> its place is judged by the concrete type of the value it sees, not by
> the view it becomes: `!h` of a `*Hits` passed where a `!{A}` goes
> leaves `h` read-only. A value whose type is an API object `{A}` or a
> type parameter is no cell, so two `!{A}` of one owned value, or of a
> `!{A}` parameter, are two ordinary write views, and `!s` of a `*{A}`
> makes a write view only of the handle. `!h` that makes a write view of
> the handle itself, a `!*T` the callee may point elsewhere, leaves `h`
> unusable, and so does `w = !c` with no type written, where `c` can be
> assigned: write `w: !Cell[Int] = !c` for a write view of the cell. […]
>
> No call ever gives a write view into the value a `Cell` holds, as
> Rust's `get_mut` would: what `r = head(!v)` leaves of `v`, read-only
> but not unusable, relies on it.

## The commonest messages

These are ranked by how many expected errors in the tests and the docs
carry each message today. Each conflict now reads "cannot VERB `x` while
a read view (or write view) of it is still in use". The verb names what
was written at the caret: use, change, assign to, reassign, move, or
drop. The view is named by the sigil written, not by the compiler's
record, which for a cell's `!c` is a read loan.

| # | Count | Today | New |
|---|---|---|---|
| 1 | 473 | cannot lend `v` to write while a read loan is live | cannot change `v` while a read view of it is still in use |
| 2 | 188 | cannot reassign `c` while it is lent | cannot reassign `c` while a read view of it is still in use *(or a write view)* |
| 3 | 165 | cannot drop `b` while it is lent | cannot drop `b` while a read view of it is still in use *(or a write view)* |
| 4 | 99 | cannot assign to `a[0]` while `a` is lent | cannot assign to `a[0]` while a read view of `a` is still in use *(or a write view)* |
| 5 | 82 | `(!p).x`: write a lend on the whole path, not its base: `p.x = 5` | `(!p).x`: put the sigil on the whole path, not its base: `p.x = 5` |
| 6 | 73 | cannot return a view of `user`, which this function was not lent | cannot return a view of `user`, which belongs to this function |
| 7 | 71 | use of `n` while a write loan is live | cannot use `n` while a write view of it is still in use |
| 8 | 67 | cannot lend `v` to write while a write loan is live | cannot change `v` while a write view of it is still in use |
| 9 | 33 | cannot move `rc` while a read loan is live | cannot move `rc` while a read view of it is still in use |
| 10 | 28 | cannot lend `p` to write while a read loan on `p.a` is live | cannot change `p` while a read view of `p.a` is still in use |
| 11 | 27 | cannot lend `x`: it may be `a`, a value a name holds, which lending the branching value would copy; lend each branch: `…` | cannot make a view of `x`: it may be `a`, a value a name holds, which a view of the branching value would copy; put the sigil on each branch: `…` |
| 12 | 26 | `!` lends `ok` to write and never negates: write `not ok()` | `!` makes a write view of `ok` and never negates: write `not ok()` |
| 13 | 23 | cannot lend to write through a read view `?P` | cannot make a write view through a read view `?P` |
| 14 | 22 | cannot lend `n` to read while a write loan is live | cannot use `n` while a write view of it is still in use |
| 15 | 19 | cannot lend constant `K` to write: it lives for the whole program and never changes; bind its value to a name first | cannot change constant `K`: it lives for the whole program and never changes; bind its value to a name first |
| 16 | 19 | cannot lend `x` to write while an earlier argument's read of it is in use | cannot change `x` while an earlier argument's read of it is still in use |
| 17 | 13 | method `push` needs `self` lent to write; write `!xs.push(1)` | method `push` needs a write view of `self`; write `!xs.push(1)` |
| 18 | 6 | bare use of write view `v` in binding would copy a write view, which is unique; use `<v` to move it | bare use of write view `v` in binding would copy it, and a write view never copies; use `<v` to move it |

The note under a conflict changes the same way: "`v` lent to read here"
and "`v` lent to write here" become "a read view of `v` is made here"
and "a write view of `v` is made here", by the sigil written. The other
notes follow (for example, "a write view of `v` is made here, as
`self`, which is read until the call starts").

For a cell, every message is true as written: "cannot reassign `c`
while a write view of it is still in use". Where `!c` makes a write view
of the handle, the act is named as such: "cannot make a write view of
the handle `c` while …", since "cannot change `c`" would read false
beside an accepted `!c.set(5)`.

## What PR 1 changes, and what waits

- **PR 1, wording.** CORE, SPEC, every doc (CONCURRENCY, learn/, SYNTAX,
  QUICK, STD, internals), AGENTS.md's "One vocabulary" rule and North
  Star 4, the diagnostics' text (the 18 above, the notes, and the nine
  other messages panel 4 found still saying lend or loan), the tests'
  expected text, and a test that no diagnostic says lend, lent, "read
  loan" or "write loan". The compiler's record of each view also
  carries the sigil written, so a message can name the view truly for a
  cell; that field is read only by the messages. A one-line note goes
  to Trig about the new message text. `tools/emit-diff` shows the same
  Zig, and the oracle's rejections change only where a doc example's
  text does, since their keys hash that text.
- **PR 2, the notes.** Every conflict ends with "still used here" at the
  view's last use (for a task, at its `>t`), beside "a read view of `v`
  is made here". A drop at a scope's end says "`c` is dropped here, at
  the end of its scope, while a read view of it is still in use". Both
  need the checker to carry sites it does not carry today.
- **PR 3, identifiers.** The compiler's names and comments (`read_loan`,
  `write_loan`, `lendsToWrite`, `__rig_lent_*` and the like) are renamed
  mechanically.
- **Later, separate fixes** panel 4 found, each its own PR: count
  `Signal` as a cell (a `Signal` by value is accepted as a parameter or
  element today); accept a `!Chan[T]` as a select arm; refuse
  `?Actor[T]` and `!Actor[T]` as types, which have no methods.

## Decisions for the owner (default first)

1. Approve the "Places and views" preface, sentences 4 to 9, and the §4
   rule as written above? *(yes)*
2. Row 6: "which belongs to this function", the phrase the compiler
   already uses for a parameter taken by value? *(yes)*
3. PR 1 adds the sigil written to the compiler's record of each view,
   read only by the messages, so a cell's `!c` is called a write view?
   *(yes)*
4. Keep `w = !c` with no type as a write view of the handle, with the
   §4 sentence above? *(yes)*
5. The three compiler fixes (Signal, `!Chan` in a select, `?Actor`) as
   separate PRs after PR 3? *(yes)*
