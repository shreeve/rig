# Panel 3 brief: read view, write view, read-only, off-limits

## Where the owner is

The owner wants Rig's ownership words to feel "totally normal and natural".
In his words: "If read views and write views make sense, that's a big win."
The words he is trying now:

- **read view** (`?T`) and **write view** (`!T`): what the holder gets.
- **read-only** and **off-limits**: what the owner's value is while views
  of it are in use.

He also asks: "Are you saying that read views can have ONLY ONE
additional qualifier (or not), and that write views can also have ONLY
ONE additional qualifier (or not)?"

Earlier rounds tried "read loan / write loan" (today's words, on `main`)
and then "loan / exclusive loan". Panel 2 (`../panel-2/`, read only after
forming your own view) agreed that loans should have no kinds, and that
the Cell case should be stated about the value.

## Rig, briefly

Rig compiles to Zig, with Rust-like ownership and sigils on the owner's
side. `?x` hands out a read view of `x`, and `!x` a write view. A view
lasts until its last use, not to the end of its scope. `*T` is a counted
shared handle. Rig never says "borrow". The owner's taste is short plain
words people already know, used for what they already mean, and one word
for each idea.

## The model as it stands (check every line)

1. While a **read view** of `x` is in use, `x` is **read-only**.
2. While a **write view** of `x` is in use, `x` is **off-limits**.
3. **Exception:** a write view of a value that changes only through its own
   calls (`Cell`, `Signal`, channel, actor, or an object holding a `Cell`,
   such as std's `shared.Map`) leaves `x` only **read-only**. Many write
   views of it may live at once: `!c.add((!c).swap(4))` is accepted.
4. **Read-only:** `x` may be read, copied, and given more read views. It
   may not be changed, assigned, moved or dropped.
5. **Off-limits:** `x` may not be used at all, not even read.
6. It is all by place: a view of `p.a` limits `p.a` and `p`, but not
   `p.b`.
7. `r = head(!v)`: `r` is a read view, so after the call `v` is read-only
   while `r` lives.
8. The messages would read "cannot change `v` while it is read-only" and
   "cannot use `n` while it is off-limits".

## Known wrinkles, for you to judge

- **A read-only Cell still changes.** With `r = ?c` alive, `!c.set(5)` is
  accepted. So is "read-only" false for a Cell? Would another statement of
  the exception be truer?
- **Is "loan" still needed?** Under this model a user may never need the
  word. CORE uses it as the compiler's record (a loan travels inside
  fields, closures and results, and outlives a view in the `head(!v)`
  case).
- **A possible bug:** `w: !Cell[Int] = !c` makes `c` off-limits, while
  `two(!c, !c)` does not.
- Rig's std has `Mutex`, `RwLock` and `lock()`, and tasks "block" on
  channels, which is why "locked" and "blocked" were set aside.

## Where to look

The worktree is `~/Data/Code/worktrees/rig/loan-vocab/`. Look at
`docs/CORE.md` (the preface, section 2's sentences 4 to 9, and section 4),
and `src/ownership.zig` (the `Loan` struct and the conflict messages). A
current compiler is at `~/Data/Code/rig/bin/rig`. Test files are under
`test/rig/` (for example `ownership-shared-lend.rig.test`). Do not edit any
file except your report.

## Your report

Write the full report to `panel-3/ROLE.md` beside this file. Return at most
400 words, verdict first, covering:

1. Is the model accurate, line by line? What is false or missing?
2. Do the four words feel normal and natural? If not, name the one change
   that would help most.
3. The owner's question about qualifiers, answered plainly.
4. The simplest picture: describe in words the one diagram you would draw
   to teach it.
