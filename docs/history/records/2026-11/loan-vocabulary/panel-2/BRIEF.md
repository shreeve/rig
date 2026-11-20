# Panel brief: the ownership vocabulary, reviewed again with fresh eyes

## The owner's question, in his words

> We are going from this: "read loan and write loan" to this: "read view or
> write view from a loan or exclusive loan". We have split our read/write
> concept into two: a view and a loan. And the view can be read/write and
> the loan can be exclusive or not. There is a certain clean simplicity in
> the original two options, but I feel a little uneasy in our new four
> options. The goal is semantic and mental clarity.

The vocabulary was approved before. The owner asks for a fresh review, and
any of it may change: keep the approved words, go back to the old ones, or
choose something else.

## Rig, briefly

Rig compiles to Zig and has Rust-like ownership, with sigils at the owner's
side: `?x` hands out a read view (type `?T`), and `!x` hands out a write
view (type `!T`). `*T` is a counted shared handle and `^T` a box. A view
lasts until its last use. Rig never says "borrow". The owner's taste is
short plain words people already know, used for what they already mean,
and one word for each idea.

## The words today (on `main`)

- **lend** (the act: `?x` lends to read, `!x` lends to write)
- **view** (what the holder gets)
- **loan** (the compiler's record on the owner), named **read loan** or
  **write loan**.
- A place has any number of read loans, or one write loan, never both.
- The errors read like: "cannot lend `v` to write while a read loan is
  live", "use of `n` while a write loan is live", "cannot reassign `c`
  while it is lent".

## Why it was reopened: where view and loan stopped matching

Before #1101, read view meant read loan and write view meant write loan,
one to one. Two rules broke that:

1. **#1101.** `!c` of a value that changes only through its own atomic
   calls, such as a `Cell`, `Signal`, channel, actor, or an object holding
   a `Cell` (std's `shared.Map`), gives a write view that puts only a
   *read* loan on `c`. Many write views of it may then live at once:
   `!c.add((!c).swap(4))` is accepted, and `r = ?c` kept across
   `!c.set(5)` is accepted. Such a value lives only behind `*` and is never
   replaced whole.
2. **A result holding no write view.** After `r = head(!v)`, `r` is a read
   view, and `v` keeps a read loan: readable, not writable.

Since then, today's prose has said things like "`!x` puts a write loan on
`x`, and only a read loan when what it lends is a write view of a value
that changes by a marked call", and the error says "read loan" about a `!`.

Which combinations occur:

| View | Loan on the owner | Occurs? |
|---|---|---|
| read | many allowed (today "read loan") | yes: `?x`, `head(!v)`'s result |
| write | only one (today "write loan") | yes: `!x` of an ordinary value |
| write | many allowed | yes: `!c` of a Cell and the like (#1101) |
| read | only one | no rule makes it |

## The approved replacement (2026-11-16)

- **view**: the holder's side, read or write.
- **loan** (noun and verb): the owner's side; "loan" replaces lend.
- **exclusive loan**: the place's only loan; other loans have no adjective.
- The errors read "cannot VERB `x` while it is on [exclusive] loan".

The full draft, with CORE's sentences and 18 messages old and new, is in
`../draft.md`. Earlier panel reports are in
`~/Library/Application Support/Claude/side-session-notes/local_652501f4-3dd9-4f9e-a4e8-c5f90bff5ca8/loan-vocab/`
(`proposal.md`, `designer.md`, `rust.md`, `zig.md`, `HANDOFF.md`). Read
them only after forming your own view. The whole ownership model is
`docs/CORE.md` in the worktree `~/Data/Code/worktrees/rig/loan-vocab/`.

## What each expert answers

1. Is the owner's unease right? How many concepts does a user really need
   to hold: two, three, or four? Is the view/loan split needed, or does it
   only serve the Cell exception?
2. Name the best option, considered fresh. Include at least: (a) the
   approved scheme; (b) the old read/write loan with the #1101 case
   explained as an exception; (c) something simpler you would propose
   instead, for example a single kind of loan whose strength follows the
   view, with the Cell exception stated about the value rather than the
   loan.
3. For your recommendation, show it on three cases: `?v` then `!v.push`;
   `w = !n` then a use of `n`; and `!c.add((!c).swap(4))` on a Cell. For
   each, give the CORE sentence and the error message.
4. Name what would confuse a newcomer from Python or Ruby, and a reader
   coming from Rust.

Write your full report to `panel-2/ROLE.md`, beside this file, and return a
summary of at most 400 words: your recommendation first, then the reasons.
Do not edit any other file.
