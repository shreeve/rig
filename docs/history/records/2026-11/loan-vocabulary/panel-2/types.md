# Panel 2: the type-systems reading

Role: ownership and aliasing (Rust's borrow checker, interior mutability,
Swift's exclusivity, Pony's capabilities, fractional permissions). Test
applied: does each word match the model's structure, so that no sentence
or message says something false about a case?

## Recommendation

Keep the approved scheme's words (**view**, **loan**, **exclusive**), but
shrink it to **two nouns and one adjective**, and fix two places where the
draft says something false:

1. **Two words, not three.** The preface table has two rows, *view* and
   *loan*. "Exclusive" is an adjective on loan, defined in one sentence
   under the table, not a third headword.
2. **"Loan" is always the genus.** "On loan" means *any* loan, everywhere.
   The draft's preface bullet ("While `x` is on loan, it may be read,
   copied, and loaned again") uses "on loan" for the *non*-exclusive kind,
   while the messages use it for any loan. That is one word for two ideas.
3. **"Change" must not be ruled out for a Cell on loan.** The draft makes
   "change" the verb for a `!` that meets a loan (decision 2), then says
   that while `x` is on loan it may not be "changed". `r = ?c` kept across
   `!c.set(5)` is accepted, so that sentence is false for every Cell.
4. **Sentence 5 keeps the old sentence's shape:** "A place has any number
   of loans, or one exclusive loan, never both." It is the old sentence
   with the adjectives corrected.
5. **Messages name only what blocks.** Every loan blocks change, assign,
   move and drop, so those messages say "on loan". Only an exclusive loan
   blocks a use, so only that message says "on exclusive loan". The note
   ("put on loan here" / "put on exclusive loan here") says which kind of
   loan it is. Today's "(or on exclusive loan)" variants are not false,
   but they teach the reader that plain "on loan" means the
   non-exclusive kind, which is the double duty in point 2.

Reject (b), the old read/write loan, and (c), naming views in the
messages. Reasons below.

## 1. Is the owner's unease right? How many concepts?

The unease is right about the draft's *presentation* and wrong about the
model's size. The model is two axes:

- **holder permission** (the view): may the holder change the value
  through it? `?` no, `!` yes;
- **owner restriction** (the loan): may the owner still read the place
  and loan it again? Yes (a loan), or no (an exclusive loan).

Only three of the four combinations exist, and a user meets two of them
almost all the time. A user needs **two concepts** (a view; the owner is
on loan while it lives) and **one fact** (a write view's loan is
exclusive, except for a value that changes only through its own calls).
"Four options" is what the draft's three-row table makes the reader
multiply out. The model never asks for it.

**Is the view/loan split needed apart from the Cell case?** Yes. It is
the real structure, and Rust has it too (a reference on the holder's
side, a loan on the owner's side; rustc and Polonius call the latter
"loans"). Three things in Rig need it whether or not Cell exists:

- **A loan outlives the view that made it.** After `r = head(!v)`, the
  write view ended at the call, and a read view carries the loan
  (`read_of_write` in `src/ownership.zig`). Rust keeps `v` mutably
  borrowed here; Rig downgrades the loan. You can only say that by
  naming the loan apart from the view.
- **Loans travel inside holders** (sentence 6: fields, closures, results,
  `keeps`). The thing that blocks the owner is often no view the user
  can see by name.
- **Some loans belong to no view of the place.** A `deref` loan sits on
  the binding `s` because of `!s.value`; a `reserved` loan is a write
  self that reads until the call starts; `held_read` and `place_hold`
  are holds the compiler makes on its own.

What Cell breaks is **naming a loan by its view's kind**. It does not
break the split.

## 2. The options

**What the checker actually represents.** `Loan.kind` is
`LoanKind = enum { read, write }`. `conflictingLoan` checks a read
access only against `.write` loans, and a write or a move against any
loan. For `!x`, `sema.loanOf` returns `.read` when `loanOfView` finds a
value that changes only through its own calls. So the checker's `.read`
already means *shared* and `.write` means *exclusive*. That is a
readers–writer lock, the same as Rust's shared and unique loans. The
enum is about the owner. Only its names (and PR 3's identifiers) borrow
the view's words.

**(a) Approved scheme.** The structure is right: the adjective sits on
the axis where Cell differs. Faults: the third headword, the genus/species
double duty, and the false "may not be changed" (above). With the fixes,
this scheme is (a′), my recommendation.

**(b) Old read/write loan, with #1101 as an exception.** "Read loan"
and "write loan" can be read two ways, and the old words fail both:

- *by the view that made it*: then `!c` on a Cell making a "read loan"
  is false, and the user is told "a read loan is live" about a line that
  says `!`;
- *by what the owner may still do*: then "read loan" fits a Cell, but
  "write loan" would mean the owner may still write, when in fact it may
  do nothing.

So no single reading makes both names true. This is the case where the
vocabulary itself says something false, and an exception paragraph
cannot fix that.

**(c) One kind of loan whose strength follows the view; the Cell
exception stated about the value; messages name views** ("cannot use `n`
while a write view of it is live"). This is the Rust way of handling Cell
(the reference is shared, and the *type* permits the change), and it
reads best for a newcomer, who can look for the `!` they wrote. It fails
the truth test in edge cases that are real:

- `deref` loans: `!s.value` loans `s`, and no "write view of `s`" exists.
- `reserved` self: it is a write view, but its loan does not yet block a
  read.
- Handle against value. I ran `~/Data/Code/rig/bin/rig` (#1191):

  ```rig
  c = *Cell(1)
  w: !Cell[Int] = !c
  print(c.get())   # rejected: "use of `c` while a write loan is live"
  print(w.get())
  ```

  The view's type is `!Cell[Int]`, yet the loan is exclusive, while
  `two(!c, !c)` and `!c.add((!c).swap(4))` are accepted. (A binding's
  `!c` appears to be recorded as the handle, `!*Cell`, by `synthLend` in
  `src/typecheck.zig`, not decided again as `lendView` decides an
  argument. It may be a separate defect against CORE §4, which says `c`
  of type `!Cell[Int]` behaves the same. Worth a separate check; it
  changes no vocabulary.)

  So you cannot always tell a loan's strength from the view's visible
  type. Only a word on the loan states it truthfully, and the note must
  carry it.

The value-side statement from (c) is still the right *explanation*, and
(a′) uses it: a write view of such a value changes what the handle
shares, not the place `x`. The value lives behind `*` and is never
replaced whole, so `x` needs only to stay put and alive, and that is
exactly what a non-exclusive loan asks of it. (In Swift's terms, `Atomic`
changes through a borrowing method; in Pony's, the place is held at most
as `box`, and change goes through the object's own behaviour; in
fractional terms, each such view takes a fraction of the place, and the
change is mediated by an invariant the type owns.)

**Why not "shared loan / exclusive loan"** (naming both kinds, Rust's
modern terms)? It would remove the unmarked term, but "shared" is `*`'s
word in Rig ("what you share with `*`"). The unmarked "loan" plus
"exclusive" is the right pair, as long as "loan" is always the genus.

## 3. The recommendation on three cases

Preface (two rows): **view**, what the holder gets, read or write;
**loan**, what the owner is left with while views live. Under the table:
"A loan is **exclusive** when the owner may not use the place at all. A
read view's loan never is; a write view's is, except of a value that
changes only through its own calls (sentence 9, §4)." The bullet becomes:
"While `x` is on loan, it may not be assigned, moved, dropped, or changed,
except by the own calls of a value that changes only through them. Unless
the loan is exclusive, `x` may still be read, copied and loaned again."

**`?v` then `!v.push(2)`** (sentence 5, with 6): "A place has any number
of loans, or one exclusive loan, never both."

    error: cannot change `v` while it is on loan
    note: `v` put on loan here

**`w = !n`, then a use of `n`** (sentence 5, and "a write view's loan is
exclusive"):

    error: cannot use `n` while it is on exclusive loan
    note: `n` put on exclusive loan here

**`!c.add((!c).swap(4))` on a Cell** (§4: "…so its loan is not
exclusive, and many write views of it may live at once"): accepted, with
no message. The neighbouring rejection, `r = ?c` then `c = *Cell(2)`:

    error: cannot reassign `c` while it is on loan
    note: `c` put on loan here

## 4. What would confuse

**A newcomer from Python or Ruby.** These languages have references but
no rule against aliasing and changing at once. So:

- Why does a read view stop me changing my own list? Sentence 5 needs one
  "because": a view would see the change, or would dangle.
- Why can a Cell change while it is on loan, when the text says a place
  on loan cannot change? Fix 3 answers this.
- "Exclusive" is plain English and lands well. "Live" in messages is
  jargon. The draft's PR 2 note ("`v` is still used here") is what makes
  "on loan" concrete.
- "Loan" as a verb sounds a little commercial to some ears, but costs
  nothing.

**A reader from Rust.**

- They will map `!T` to `&mut T` everywhere. A `!Cell` is Rust's
  `&Cell`, shared, and the draft's bridge sentence should say so in
  those words.
- They will be surprised that a `?Cell` cannot `set` (in Rust, a `&Cell`
  can). In Rig, `!` marks the change. The type does not permit it.
- They will expect `v` to stay mutably borrowed after `r = head(!v)`
  (Rust does not downgrade). Rig is more permissive here, and CORE should
  say so in one clause.
- "Loan" itself is familiar: it is what rustc calls a borrow internally.
- "Exclusive" matches the current Rust usage, "exclusive reference" for
  `&mut`.
