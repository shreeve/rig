# The view vocabulary: what the owner has settled

2026-11-20, in conversation with the owner, after panels 2 and 3
(`panel-2/`, `panel-3/`). This replaces the loan / exclusive loan
vocabulary of `draft.md`, which is to be rewritten in these words.

## The words

- **place**: a variable, a field, or an element. It is what a sigil is
  put on. Places nest: `p.items[0]` is inside `p.items`, which is inside
  `p`.
- **read view** (`?T`) and **write view** (`!T`): what `?` and `!` make.
  A view has one property, read or write, and no other qualifier.
- **read-only**: the state every view leaves its place until the view's
  last use. It belongs to the place, never to the view. The place may be
  read, copied, and given views, but not changed, assigned, moved, or
  dropped.
- **unusable**: what a write view of an ordinary value leaves its place
  until the view's last use: it can't be used at all, not even read.
  SPEC already uses the word for a moved-from place ("unusable until
  reassigned"); this one comes back by itself.
- **cell** (lowercase): a `Cell`, or a value that holds one directly: a
  `Signal`, a channel, an actor, or an object with a `Cell` field (std's
  `shared.Map`). Defined once, in CORE §9. A cell lives only behind `*`,
  so its place always holds a handle (`c: *Cell[Int]`) or a view of one.
  It changes only through its own calls, each one complete step, so a
  write view of it leaves its place read-only, and many may be in use at
  once. An ordinary object with a handle field (`c: *Cell[Int]`), kept by
  value, is not a cell. Every `Cell` is a cell; not every cell is a
  `Cell`, as every `Int` is an integer.

## The rule

> - Any view leaves its place read-only until its last use.
> - A write view of an ordinary value goes further: its place is
>   unusable until the view's last use.

An ordinary value is anything that isn't a cell.

Every view needs its place to stay put, so every view leaves it
read-only. Only a write view of an ordinary value could also leave the
value half-changed while someone reads it, so only that view stops
reads too. A cell changes only by its own calls, each one complete step.

For a cell, read-only holds the handle still, so nobody may assign,
move, or drop it. The value itself still changes, but only
through its own calls (`!c.set(5)`). A write view of the handle itself,
which is what `w = !c` makes when no type is given (a `!*Cell`, which
can point `c` elsewhere), is an ordinary write view, so `c` is
unusable.

## What goes

- "lend", "lent", "read loan", "write loan" and "exclusive loan" leave
  the docs and the messages. "Loan" stays as the compiler's word for its
  record, and in CORE only where that record is meant.
- "Owner" keeps its one meaning, who moves and drops a value. It is not
  used for the viewed side.
- "Holder" is not needed: what the holder has is a view.
- "Callable" is not used for cells. It already means a function
  or closure value.

## Messages

Each message names the act at the caret and the view that blocks it,
because the reader's next question is why:

- cannot change `v` while a read view of it is still in use
- cannot use `n` while a write view of it is still in use
- cannot change `p` while a read view of `p.name` is still in use
- cannot reassign `c` while a write view of it is still in use (a Cell:
  true as written, so it needs no wording of its own)

The verbs are use, change, assign to, reassign, move and drop. A read
view blocks all but use, and a write view of an ordinary value blocks
use too. "Read-only" stays in the docs as the short name for what a read
view leaves, but no message needs it. Notes point at both ends of the
view: "a read view of `v` is made here" and "still used here". The
"still used here" note needs the checker to carry the site of the last
use (PR 2).

## Facts CORE must state (found by running the compiler, panel 3)

- An element is not a separate place for this rule: a view of `a[0]`
  limits all of `a`. A view of `p.a` leaves `p.b` free.
- `r = head(!v)` leaves `v` read-only only when the result keeps a view.
  A result that is copied out, such as an `Int`, leaves `v` free.
- A write view of the handle (`!*Cell`), an erased `!{A}`, or a generic
  `!T` is an ordinary write view.
- A method's write view of self starts when the call starts:
  `!v.push(v.len)` is accepted, `grow(!v, v.len)` is not.
- CORE sentence 4's "`?` promises that nothing changes" is false for a
  cell and needs the handle wording.
