# Panel 2: the diagnostics writer

Role: a writer of compiler messages and their documentation (Elm's and
Rust's errors, Go's spec prose). The test is the error read at 2 a.m.:
does it say what went wrong in words the reader already has, and does it
point at what to change?

## Recommendation

**Name the view in the message, not the loan.** Every conflict reads

> cannot VERB `x`: a view of it is still in use

and says **write view** exactly when the blocking loan is exclusive
(that is always a write view of an ordinary value, so it is always
true). The note at the site says what view was made there, in the
user's own sigils: "a read view of `v` is made here", "`head(!v)` keeps
only a read view of `v` here". PR 2's note, "`a` is still used here",
then answers the head's "still in use" directly.

The user needs two ideas: **a view** (read `?` or write `!`, which they
wrote) and **in use** (until its last use, which they can see). The
Cell exception is a fact about the value: "a write view of a value that
changes only through its own calls limits its place only as a read view
does." "Loan" stays in CORE as the spec's noun for the compiler's record
(sentences 6 and 7 need a word for what a result carries), with no
adjective, no verb, and no appearance in any message. "Exclusive",
"loan" as a verb, "read loan" and "write loan" all go.

If the owner keeps the approved scheme, four changes make its messages
better (last section).

## 1. Is the owner's unease right?

Right that four is too many; wrong about where the four are. The user
never chooses among four things. They write two sigils. Whether the
owner's place is exclusively held is a consequence the compiler works
out, and only one of the 2x2's off-diagonal cells exists. The approved
scheme makes the user learn that consequence as a vocabulary word
("exclusive loan") because the messages are written from the owner's
side, which is the side the user is *not* looking at when the error
fires: they are looking at the line they just wrote, and the fix is
always to end some view sooner (or copy instead of view).

The old two-word scheme cannot come back: it is now false at the site.
On today's compiler (built from `main`), the Cell-holding object case:

```
w = (!h).cell()
h = *Hits(n: Cell(1))
```
```
error: cannot reassign `h` while it is lent
note: `h` lent to read here        <- under the `!` the user wrote
```

and the head case:

```
note: `v` lent to write here, and kept lent to read by a view that only reads it
```

The first contradicts the code on screen; the second is a tongue twister
that is trying to name a view ("a view that only reads it") through the
loan. Both are fixed by saying what the view is.

Is the view/loan split needed? In the compiler and in CORE's rules for
calls, yes: one loan rides on many views, a view can carry several
loans, and a copied-out `?Int` carries none (the earlier panel's reasons
for rejecting "view" *as a name for the loan*; I agree, and do not
propose that). In the messages, no: a message needs only "some view of
`x` is still in use", which is true in every one of those situations.

## 2. The options, fresh

| | (a) approved | (b) old + exception | (c) view-named (recommended) |
|---|---|---|---|
| words the user must learn | view, loan (verb and noun), exclusive | lend, view, read loan, write loan | view, in use |
| true after #1101 | yes | no: "read loan" about a `!`, "lent to read" under `!h` | yes |
| message head points at the fix | no: names the owner's state | partly | yes: names the thing to end |
| the Cell case | "its loan is not exclusive" (about the loan) | an exception in every passage that names a loan | "its write view limits the place as a read view does" (about the value) |
| English | "loaned as a read view" is stiff; "on exclusive loan" is not an idiom | fine | plain |
| Rust precedent | "borrowed"/"mutably borrowed" | same | "immutable borrow occurs here", "borrow later used here" (Rust's NLL notes name the reference, not the record) |

(a) is true and short, and far better than (b). Its weakness is that
"on loan" answers "what state is `x` in?" while the 2 a.m. reader is
asking "what do I have to stop doing?". "Exclusive" is a third concept
introduced only to explain why a read fails, and the draft spends it
even where it changes nothing (rows 2-4: "cannot drop `b` while it is
on exclusive loan" -- a drop is refused under any loan, so the adjective
tells the reader nothing they can act on).

(c) is the brief's "single kind of loan whose strength follows the
view": the strength is stated by the view's kind and, for Cells, by the
value. It is mechanical to emit: "write view" when the blocking loan is
exclusive, "view" otherwise. It never says "read view" in a head, so it
never says something false about a Cell's write view.

## 3. The three cases under (c)

**`?v` then `!v.push`**

CORE, sentence 5: *While a view of a place is in use, the place may be
read, copied and viewed again, but not changed, moved, or dropped; while
a write view of it is in use, it may not be used at all.* (A loan on a
place covers every place inside it, as today.)

```
error: cannot change `v`: a view of it is still in use
  !v.push(2)
  ^
note: a read view of `v` is made here
  a = ?v[..]
       ^
note: `a` is still used here            (PR 2)
  print(a, b)
        ^
```

**`w = !n` then a use of `n`**

Same sentence.

```
error: cannot use `n`: a write view of it is still in use
  print(n)
        ^
note: a write view of `n` is made here
  w = !n
       ^
```

**`!c.add((!c).swap(4))` on a Cell**

CORE, sentence 9 / §4: *A value that changes only through its own calls
-- a `Cell`, a `Signal`, a channel, an actor, or an object holding a
`Cell` -- lives only behind `*` and is never replaced whole, and each
call is one step. So a write view of it limits its place only as a read
view does: many may be in use at once.*

Accepted; no message. The nearest refusal, reassigning while one is in
use:

```
error: cannot reassign `c`: a view of it is still in use
note: a write view of `c` is made here
```

(Note "a view", not "a write view": this loan is not exclusive, so the
head stays neutral and true; the note still names the sigil written.)

## 4. The 18 messages under (c)

Counts are the draft's; my grep over `test/rig` gives the same order.

| # | Today | (c) |
|---|---|---|
| 1 | cannot lend `v` to write while a read loan is live | cannot change `v`: a view of it is still in use |
| 2 | cannot reassign `c` while it is lent | cannot reassign `c`: a [write] view of it is still in use |
| 3 | cannot drop `b` while it is lent | cannot drop `b`: a [write] view of it is still in use |
| 4 | cannot assign to `a[0]` while `a` is lent | cannot assign to `a[0]`: a [write] view of `a` is still in use |
| 5 | `(!p).x`: write a lend on the whole path, not its base | `(!p).x`: put `!` on the whole path, not its base: `p.x = 5` (name the sigil; "sigil" is our word, not the reader's) |
| 6 | cannot return a view of `user`, which this function was not lent | cannot return a view of `user`, which belongs to this function (the compiler already says "a parameter taken by value belongs to this function"; check the closure-environment case) |
| 7 | use of `n` while a write loan is live | cannot use `n`: a write view of it is still in use |
| 8 | cannot lend `v` to write while a write loan is live | cannot change `v`: a write view of it is still in use |
| 9 | cannot move `rc` while a read loan is live | cannot move `rc`: a view of it is still in use |
| 10 | cannot lend `p` to write while a read loan on `p.a` is live | cannot change `p`: a view of `p.a` is still in use |
| 11 | cannot lend `x`: it may be `a`, … lend each branch | cannot make a view of `x`: it may be `a`, a value a name holds, which viewing the branching value would copy; make the view in each branch: `…` |
| 12 | `!` lends `ok` to write and never negates | `!` makes a write view of `ok` and never negates: write `not ok()` |
| 13 | cannot lend to write through a read view `?P` | cannot make a write view through a read view `?P` (as the draft) |
| 14 | cannot lend `n` to read while a write loan is live | cannot use `n`: a write view of it is still in use |
| 15 | cannot lend constant `K` to write: … | cannot change constant `K`: … (as the draft) |
| 16 | cannot lend `x` to write while an earlier argument's read of it is in use | cannot change `x`: an earlier argument still reads it |
| 17 | method `push` needs `self` lent to write | method `push` needs a write view of `self`; write `!xs.push(1)` (as the draft) |
| 18 | … a write view, which is unique … | as the draft |

"[write]" appears when the blocking loan is exclusive. Notes:
"a read view of `v` is made here", "a write view of `v` is made here",
"`head(!v)` keeps only a read view of `v` here", "a write view of `c` is
made here, for `self`, which only reads `c` until the call starts",
"the task started here holds a view of `h`".

"Still in use" rather than "live": "live" is liveness jargon, and PR 2's
note ("is still used here") then answers the head in the same words. I
keep the draft's verb "change" for a `!` that meets a view: it names
what the program is trying to do.

CORE's preface becomes one rule instead of three words: *`?x` gives a
read view of `x`, and `!x` a write view. While any view of `x` is in
use, `x` cannot change; while a write view of it is in use, `x` cannot
be used at all. A view is in use until its last use.* Then the Cell
sentence, the Rust mapping (`?T` is `&T`; `!T` is `&mut T`, or `&Cell`
for a value that changes only through its own calls), and "borrow"
as today.

## 5. What confuses whom

**Python or Ruby.** "Loan" and "exclusive loan" are finance and
licensing words with no programming meaning they already hold; "on
exclusive loan" also suggests a contract with someone ("exclusive to
whom?"). "Loaned as a read view" reads as a calque. "Live" is jargon.
"View", by contrast, is theirs: Python's `dict.keys()` is a view, and
"dictionary changed size during iteration" is exactly sentence 5 caught
at run time. Rule (c) reads as that error moved to compile time. Ruby
readers know "frozen" -- avoid using it for "on loan", since Rig's
frozen values (`?f`) are a different thing.

**Rust.** Under (a), "exclusive" maps well to `&mut` ("exclusive
reference"), but "loan" is borrowck-internal (Polonius's word), and a
Rust reader will assume write view = exclusive and be surprised by the
Cell, then find the explanation stated about the loan. Under (c), "read
view"/"write view" map at once to `&`/`&mut`, the notes look like NLL's
("immutable borrow occurs here ... later used here"), and the Cell is
`&Cell` -- interior mutability, a fact about the type, which is where
Rust readers already keep it. The one trap in either scheme: `w = !c`
of a `*Cell` makes a write view of the *handle* (a `!*T`), which is
exclusive, so it is refused beside a read view while `!c.set(5)` is
not. That needs its own help line ("`!c` here is a write view of the
handle `c`, which may point it elsewhere; ..."), whatever the
vocabulary.

## 6. If the approved scheme stays

1. Say "exclusive" only where it is the reason: a use, a `?x`, or a
   Cell's `!x` refused. Rows 2-4 and 8 read "on loan" (Rust does the
   same: E0506 "because it is borrowed", E0503 "because it was mutably
   borrowed").
2. Row 6: "which belongs to this function", not "which is not on loan
   to this function".
3. Use "loan" only as the noun and "on loan"; for the act, "`?x` gives
   a read view" / "makes a write view" (the draft already does so in
   rows 12-13 and §4's column heads). "`v` is loaned as a read view" is
   the stiffest phrase in the draft.
4. Notes name the view made at the site ("`head(!v)` keeps only a read
   view of `v` here"), not "put on loan here", which repeats the head
   and explains nothing in exactly the two cases that reopened this.

## Process note

`bin/rig` in `~/Data/Code/rig` was from 2026-11-10, before #1101 (it
still refused `!c.add((!c).swap(4))`). `zig build` there rebuilt it from
`main` (it writes `bin/rig`, which is git-ignored); the messages quoted
above are from that build. No tracked file was changed.
