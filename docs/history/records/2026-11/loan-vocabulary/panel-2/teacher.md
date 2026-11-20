# The ownership vocabulary: a teacher's review

Role: language designer and teacher of ownership models (Rust, Swift,
Pony) to programmers coming from Python and Ruby. Judged by what a
learner can hold in their head, and whether each word means one thing.

Read: BRIEF.md, ../draft.md, docs/CORE.md (preface, §2 sentences 4 to 9,
§4) in the loan-vocab worktree, then the earlier panel reports. Checked
on a compiler built from the worktree (main at 41d245dff; the bin/rig in
~/Data/Code/rig predates #1101 and still rejects the Cell case).

## Recommendation

**Keep the holder/owner cut, but give the owner's side one word with no
kinds.** A learner holds three terms: **read view**, **write view**, and
**on loan**. Drop "exclusive loan" as a term. The extra shut-out is a
property of a write view, stated once, with the Cell exception stated
about the value. Errors name the cause the programmer wrote:

- an act any view blocks (change, assign, reassign, move, drop):
  "cannot VERB `x` while it is on loan";
- an act only a write view blocks (use, read, view again):
  "cannot use `x` while a write view of it is in use".

The note names the view that was made: "`x` loaned here as a read
view" or "`x` loaned here as a write view". Both are always true,
including for `!c` of a Cell, which today's note calls "lent to read".

This is option (c) of the brief, and it is a small amendment to the
approved scheme, not a rewrite: the draft already says, in substance,
"a read view's loan is never exclusive; a write view's loan is
exclusive, except for a value that changes only through its own
calls". That sentence is a rule about views. It does not need a second
noun.

## 1. Is the owner's unease right?

Yes, and it points at the right spot. The approved scheme is correct,
but it presents as two independent axes (read/write view, exclusive or
not loan), which invites a 2x2 grid in the learner's head. The grid has
a hole (no read view with an exclusive loan), and of the three filled
cells one occurs only for a small class of values. A learner who builds
the grid will look for the fourth cell and for when the third one
happens. Axes that are not independent should not be taught as axes.

How many concepts does a user need? **Two, plus one exception:**

1. A view: what you get from `?x` (read) or `!x` (write).
2. While any view of `x` is in use, `x` is on loan: it may be read and
   viewed again, but not changed, assigned, moved, or dropped. A write
   view goes further: while it is in use, `x` may not be used at all
   except through it.
3. Exception, about the value: a value that changes only through its
   own calls (Cell, Signal, channel, actor, an object holding a Cell)
   lives behind `*`, is never replaced whole, and hands out nothing that
   can dangle; so its write views shut nothing out.

Is the view/loan split needed? The split between **holder** and
**owner** is needed, and not only for the Cell: the sigil sits on the
owner, the type on the holder, views travel (copied, returned, stored
in a field) while the restriction stays with the owner, and errors land
at the owner. One loan, many views is real (`a = ?v[..]; b = a`). What
only serves the Cell exception and `head(!v)` is **kinds of loan**. Drop
the kinds and the split costs one word.

## 2. The options, considered fresh

**(a) The approved scheme** (view; loan; exclusive loan). Correct and
consistent; the earlier panel's Rust and Zig readers liked "exclusive".
Teaching costs:

- Four terms where three do. "Exclusive" must be learned as a separate
  concept, then mapped back to what the learner wrote: "on exclusive
  loan? Why? Oh, the `!n` on line 3." The error makes the learner do a
  translation the compiler could have done.
- CORE has to say "a write view is not always exclusive", a sentence
  that sets off the question "then when?" before the learner knows what
  a Cell is.
- "While `x` is on loan it may be ... loaned again, though not
  exclusively": two clauses of jargon to say "you can make more read
  views".
- Swift and Rust, cited in favour of "exclusive", attach exclusivity to
  the access or reference (the holder's side): "modification requires
  exclusive access", "exclusive reference". Neither shows users an
  owner-side "exclusive loan". Putting the adjective on the write view
  matches them better than putting it on the loan.

**(b) The old read loan / write loan, with #1101 as an exception.**
Rejected. The words promise a one-to-one match with the views and break
it at exactly the point a learner looks: the compiler today prints, at
the caret of a `!c`:

```
g.rig:4:3: error: cannot reassign `c` while it is lent
g.rig:3:20:   note: `c` lent to read here
  w: !Cell[Int] = !c
                   ^
```

A `!` labelled "read" is the worst kind of message for a learner: the
text contradicts the code under the caret. And "cannot lend `c` to
write while a read loan is live", rejected for `!c` of an ordinary
value, is accepted for a Cell, so the learner sees the rule broken
without a word for why. Explaining it as an exception in CORE does not
fix the message.

**(c) One kind of loan; the strength follows the view; the Cell
exception stated about the value.** Recommended. Three terms; every
message true as printed; the Cell case never produces a contradictory
message, because the "write view" message fires only when a write view
actually shuts the owner out. `head(!v)` falls out with no special
term: the holder ends with a read view, so `v` is held as a read view
holds it.

**Considered and set aside: views only, no "loan".** "cannot change `v`
while it is viewed". One noun is tempting, but CORE needs a word for
what a non-view holding views does to the owner (`g = Guard(items:
?a[..])` keeps `a` on loan while `g` is used; a result "carries the
loans of the arguments"), and "on loan" next to change/move/drop reads
as plain English. Keep it.

**On "on loan" and the library picture.** A book on loan is out of the
house: the owner cannot read it either. That picture fits "cannot
change/move/drop while it is on loan" well and fits "you may still read
it" poorly. Scheme (a) puts "on loan" beside "use" ("cannot use `n`
while it is on exclusive loan"), where the picture works against it.
Scheme (c) never pairs "on loan" with use; the use message names the
write view instead.

**The verb.** Keep "loan" as noun and verb (one word family), but let
prose mostly say what the sigil gives: "`?x` gives a read view of `x`".
A learner needs the noun state ("on loan") far more than a verb.

## 3. The recommendation on the three cases

**Case 1: `?v` then `!v.push`.**

CORE sentence 5:

> **5. While any view of a place is in use, the place is on loan: it may
> be read and viewed again, but not changed, assigned, moved, or
> dropped. While a write view of it is in use, it may not be used at
> all except through that view.** A value that changes only through its
> own calls is the exception (sentence 9, §4). A loan on a place covers
> every place inside it, so two places conflict when one holds the
> other: `p` and `p.a`, but not `p.a` and `p.b`.

```
error: cannot change `v` while it is on loan
  !v.push(2)
  ^
note: `v` loaned here as a read view
  r = ?v
       ^
```

(PR 2's "`r` is still used here" note fits unchanged.)

**Case 2: `w = !n`, then a use of `n`.**

Same sentence 5, second half. The act (a read) is one a read view would
allow, so the message names the write view:

```
error: cannot use `n` while a write view of it is in use
  print(n)
        ^
note: `n` loaned here as a write view
  w = !n
       ^
```

**Case 3: `!c.add((!c).swap(4))` on a Cell.** Accepted; no message.

CORE §4:

> `!x` gives a write view, and a write view shuts its owner out
> (sentence 5), except a write view of a value that changes only
> through its own calls (sentence 9): a `Cell`, a `Signal`, a channel,
> an actor, or an object that holds a `Cell`. Such a value lives only
> behind `*`, is never replaced whole, and nothing it hands out can
> dangle, so a call through it changes what every handle shares while
> `x` itself stays put. Its write views shut nothing out: many may be in
> use at once, and `x` may be read and viewed while they are. So
> `!c.add((!c).swap(4))` is accepted, and so is `r = ?c` kept across
> `!c.set(7)`. Each call is one step; two calls are two steps. Which
> case applies is judged by the concrete type of the value, not the view
> it becomes; `!c` where a `!*T` goes is a write view of the handle
> itself, which shuts `c` out.

If the learner then reassigns `c` while a Cell's write view lives:

```
error: cannot reassign `c` while it is on loan
note: `c` loaned here as a write view
```

True as printed, unlike today's "lent to read here".

### What changes in the draft's messages

Rows 1, 5, 6, 9 to 13 and 15 to 18 stand as drafted. Rows 2 to 4 drop
"*(or on exclusive loan)*": assign, reassign and drop are blocked by
any loan, so the adjective adds nothing; the note says which view.
Row 8 becomes plain "cannot change `v` while it is on loan" (note: "as
a write view"). Rows 7 and 14 become "cannot use `n` while a write view
of it is in use". Notes: "put on loan here" / "put on exclusive loan
here" become "loaned here as a read view" / "loaned here as a write
view"; "kept lent to read by a view that only reads it" becomes "`v`
loaned here; the result keeps only a read view of it". Two message
shapes in all, chosen by the act: the weakest thing that blocks it is
what the message names. The test bans "read loan", "write loan" and
"exclusive loan" in diagnostics.

"In use" rather than "live": it pairs with "last use" in sentence 6,
already appears in row 16 ("an earlier argument's read of it is in
use"), and is a phrase a Python programmer already owns.

## 4. What confuses whom

**Newcomer from Python or Ruby.**

- Ownership at all: in Python, `r = v` and `v.append(2)` coexist
  freely. The first rejection must say what to do, and "while it is on
  loan" plus a note at the view is the right shape; "exclusive" adds a
  second idea at the worst moment.
- Last use, not scope: "the loan lasts until the view's last use" is
  surprising both ways (it ends earlier than they expect, and a kept
  result extends it). PR 2's "still used here" note is the most useful
  teaching change on the table.
- `?` reads as optional (TypeScript, Kotlin, Swift) or predicate (Ruby
  `empty?`), not "read". `!` helps Ruby people (`sort!` mutates in
  place) and fits "write".
- The Cell case is the one that feels natural to them (shared mutable
  state, as in Python); the ordinary rule is the strange one. So teach
  the ordinary rule clearly and the Cell as "this works like you are
  used to, and here is why it is safe". Stating it about the value does
  that; stating it about the loan makes it a vocabulary puzzle.
- "Exclusive" suggests locks and threads; they will ask whether a loan
  costs anything at run time. Say once that a loan exists only in the
  compiler (the draft does).
- "Loan" as a verb is fine in American English, slightly off in
  British; "loaned" where they expect "lent". Minor.

**Reader from Rust.**

- Will map `?T` to `&T` and `!T` to `&mut T`, then be surprised that
  `!c` of a Cell is not unique. Tell them directly, once: Rig's `!`
  marks change, not uniqueness; `&mut`'s uniqueness is Rig's write view
  of an ordinary value, and a Cell's `set` is Rust's `&self` method
  marked with `!`. This is the dual of Rust's own lesson that `&` means
  shared, not immutable.
- "Loan" is Rust's compiler word (NLL, Polonius), with kinds shared and
  mutable, so a Rust reader may assume Rig's loans have kinds too.
  Scheme (c) tells them plainly they do not: the restriction follows
  the view.
- "Exclusive" is the word Rust readers would find most familiar
  (scheme (a)'s one real advantage for them). Scheme (c) still uses
  the idea in prose ("a write view shuts its owner out"), so nothing is
  lost but the noun phrase.
- Two-phase self (`!v.push(v.len)`, "read until the call starts")
  matches Rust's two-phase borrows; the note "loaned here as a write
  view, as `self`, which is read until the call starts" says it without
  a loan kind.
- `head(!v)` leaving `v` readable is stricter-than-Rust-feeling but
  explained by the result's type: the result is a read view, so `v` is
  held as by a read view.

## Decisions for the owner (default first)

1. Keep view (read/write) and "on loan"; drop "exclusive loan" as a
   term, and state the write view's shut-out in sentence 5, with the
   Cell exception about the value. *(yes)*
2. Two message shapes, chosen by the act: "cannot VERB `x` while it is
   on loan" and "cannot use `x` while a write view of it is in use".
   *(yes)*
3. Notes name the view made: "`x` loaned here as a read view / as a
   write view". *(yes)*
4. Say "in use" rather than "live" in messages. *(yes)*
5. Everything else in the draft (rows 1, 5, 6, 9 to 13, 15 to 18; the
   §4 title and column heads; PR 2 and PR 3 plans) stands. *(yes)*
