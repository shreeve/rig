# Panel 3: the editor's report

Role: a plain-language editor and teacher of programming concepts (Go's
spec, Elm's guide; has taught Rust and Swift ownership). Question: can
the model be said in a few short true sentences, each word meaning one
thing, and is this the simplest structure?

## Verdict

Keep the four words. **read view**, **write view**, **read-only** and
**off-limits** are normal English, each means one thing, and together
they compress a table of "which view stops which action" into two
states a reader can hold in their head. The owner's side does need its
two words: naming the view instead ("while a read view of it is in
use") is longer, and makes the reader rebuild the table every time.

The model is right in substance but has three real faults and two
omissions:

1. **The exception is stated about the wrong thing.** Line 3 says many
   write views may live at once, but the compiler also accepts a write
   view while a read view lives (`r = ?c` then `!c.set(7)`), which
   line 4 forbids. State it once, about the value: *a write view of such
   a value limits `x` only as a read view does.* Then line 4 covers
   everything, with no second rule.
2. **"Read-only" is true of `c`, not of what `c` shares.** The owner of a
   `*Cell` owns a handle; handles only read (CORE sentence 8). Say so in
   one clause: *read-only holds `c` still, not what it shares.* The same
   fault is in CORE sentence 4 today: "`?` promises that nothing
   changes" is false for a Cell (`r = ?c; !c.set(3); print(r.get())`
   prints 3).
3. **The "possible bug" is misdescribed, and is not a loan bug.**
   `w: !Cell[Int] = !c` is accepted and leaves `c` read-only (tested:
   `print(c.get())` and a later `!w.set(3)` both run). What makes `c`
   off-limits is the untyped `w = !c`, which takes the first row of §4
   and lends the handle itself, `!*Cell[Int]`. That view can point `c`
   elsewhere (`w = !c; w = *Cell(9); print(c.get())` prints 9), so
   off-limits is correct. `two(!c, !c)` with `!*Cell` parameters is
   rejected too. The rough edge is which view an untyped binding picks,
   a design question for the owner, not a checker fault. The model must
   say it in a clause, or the Cell rule looks arbitrary.
4. **Omitted: how long "in use" lasts.** None of the eight lines says it.
   One sentence: a view is in use until its last use, wherever it went.
   With it, "loan" is no longer needed in the user's sentences.
5. **Omitted: line 7's condition.** `r = head(!v)` leaves `v` read-only
   only when the result holds no write view and the call keeps nothing.

Smaller: line 6 should say a view of `p.a` limits everything inside
`p.a` too (CORE sentence 5 does).

## 1. The model, line by line

Each line was tested against `~/Data/Code/rig/bin/rig` (files in the
session scratchpad; the programs are short enough to quote).

| Line | Verdict | Evidence |
|---|---|---|
| 1. read view, `x` read-only | True | `r = ?v; !v.push(1); print(r.len)` rejected; `print(?v); !v.push(1)` accepted (the view ended). |
| 2. write view, `x` off-limits | True | `w = !n; print(n)` rejected: "use of `n` while a write loan is live". |
| 3. the exception | True as far as it goes, but incomplete (fault 1) and its "only read-only" is literally false for the contents (fault 2) | `!c.add((!c).swap(4))` accepted, `c` ends at 5; `r = ?c; !c.set(7)` accepted. |
| 4. read-only | True, except that a read-only Cell takes write views (fault 1) | `<v` and `c = *Cell(2)` while viewed are rejected. |
| 5. off-limits | True | as line 2. |
| 6. by place | True, but say "and everything inside `p.a`" | `w = !p.a; print(p.b)` accepted, `print(p)` rejected. |
| 7. `head(!v)` | True with a condition (omission 5) | `r = headw(!v); print(v.len, r)` accepted; `!v.push(2)` before `r`'s last use rejected. |
| 8. messages | Good | Add the move and drop forms: "cannot move `c` while it is read-only". |

One message today shows why the new words help: moving `c` while
`w: !Cell[Int] = !c` lives gives "cannot move `c` while a read loan is
live", with the note "`c` lent to read here" pointing at a `!`. Under
the new words: "cannot move `c` while it is read-only", note "a write
view of a `Cell` leaves `c` read-only". The caret and the words agree.

## 2. Do the words feel normal?

Yes. "Read view" and "write view" say what the holder may do. "Read-only"
means exactly what every programmer expects: read yes, change no.
"Off-limits" is plain English for "don't touch", and it does not collide
with `Mutex`, `lock()` or "blocked".

The pair is not symmetric (a write view does not leave `x` "write-only"),
and that is a strength: it teaches the one idea at the heart of every
ownership model. Readers share; a writer has it to itself.

**The one change that would help most:** state the Cell exception about
the value and as a single sentence that refers back to the read rule
("limits `x` only as a read view does"), with "not what it shares". That
removes the only place where a word says something false.

"Loan" can leave the user's sentences and messages. A view in use is
the whole user-facing idea; the record that travels in fields, closures
and results is the compiler's, and belongs in CORE §9 and
`src/ownership.zig`. The sentence "a view is in use until its last use,
wherever it went: a field, a closure, a result" carries what users need
from it, `head(!v)` included, since the result is itself a view.

## 3. The owner's question about qualifiers

Asked: can read views have only one more qualifier (or none), and write
views likewise?

Plainly: **views have no qualifiers at all.** There is one read view and
one write view, never an "exclusive write view" and a "shared" one.
What varies is the owner, and the owner is in one of two states:

- A read view always leaves `x` read-only.
- A write view leaves `x` off-limits, except when what it views changes
  only by marked calls (a `Cell` and its kin); then it leaves `x`
  read-only.

So the owner's question has a yes in it, moved to the other side: each
view leaves the owner in one state, and the write view has one
exception, decided by the value's type, not by a kind of view.

## 4. The shortest complete statement, in CORE style

> `?x` gives a read view of `x`, and `!x` a write view. Through a read
> view you only read; through a write view you may also change.
>
> 1. A view is in use until its last use, wherever it went: a field, a
>    closure, a result.
> 2. While a read view of `x` is in use, `x` is **read-only**: it may be
>    read, copied, and given more read views, but not changed, assigned,
>    moved or dropped.
> 3. While a write view of `x` is in use, `x` is **off-limits**: it may
>    not be used at all.
> 4. A view of `p.a` limits `p.a`, everything inside it, and `p`, but not
>    `p.b`.
> 5. A result that holds no write view is a read view of what it came
>    from: after `r = head(!v)`, `v` is read-only while `r` is in use.
> 6. A shared value that changes only by marked calls (a `Cell`, a
>    `Signal`, a channel, an actor, or an object holding a `Cell`) is the
>    one exception: a write view of it limits `x` only as a read view
>    does. Read-only holds the handle `x` still, not what it shares. A
>    write view of the handle itself, `!*Cell[Int]`, can point `x`
>    elsewhere, so it leaves `x` off-limits.

Six numbered sentences and a lead, against the brief's eight; line 8
(messages) follows from the words and need not be a rule.

### The three cases

- **`?v` then `!v.push(1)`**, with the read view used afterward. By 2,
  `v` is read-only, and `!v` is a write view, which read-only does not
  allow: "cannot change `v` while it is read-only". If the read view is
  not used again (`print(?v)`), sentence 1 ends it and the push is
  accepted. Matches the compiler.
- **`w = !n` then `print(n)`**, with `w` used afterward. By 3, `n` is
  off-limits: "cannot use `n` while it is off-limits". Matches.
- **`!c.add((!c).swap(4))` on `c = *Cell(1)`.** By 6, the outer `!c`
  limits `c` as a read view does, so `c` is read-only. By 2, a read-only
  `c` may be given more read views, and by 6 the inner `(!c)` counts as
  one. Both calls change only the shared Cell, never the handle `c`.
  Accepted; `c` ends at 5. Matches.

## 5. The one diagram

A timeline, read top to bottom like code, one column per owner. Each
lend starts a shaded band on its owner's column, ending at the line of
the view's last use (an arrow from that line back to the band's end).
Two shades only: a light band labeled **read-only** (with a small key:
read yes, read view yes; change, assign, move, drop no) and a dark band
labeled **off-limits** (nothing). Three columns side by side show the
three cases: `v` with a light band from `?v` to `print(r.len)` and the
`!v.push` line crossing it marked with a cross; `n` with a dark band and
`print(n)` crossed; `c` with a light band that two `!c` arrows enter
without a cross, and a footnote "the handle stays still; the Cell
changes". The bands make the two facts that matter visible at once:
what the owner may do, and that it lasts until the last use, not to the
end of the block.

## Owner decisions

1. Keep read view, write view, read-only, off-limits. Default: yes.
2. Restate the exception about the value, "limits `x` only as a read
   view does", with "not what it shares". Default: yes, and fix CORE
   sentence 4's "`?` promises that nothing changes" to match.
3. Drop "loan" from user-facing sentences and messages; keep it in CORE
   §9 and the compiler. Default: yes.
4. Untyped `w = !c` on a `*Cell` lends the handle (`!*Cell`) and leaves
   `c` off-limits. Default: keep the behavior, and say it in the Cell
   sentence; reconsider only if users trip on it.
