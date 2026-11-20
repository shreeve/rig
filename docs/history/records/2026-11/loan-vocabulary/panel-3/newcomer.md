# Panel 3, newcomer (Python and Ruby, no Rust): read view, write view, read-only, off-limits

Read cold: BRIEF.md and docs/learn/01-sigils.md. I did not run the compiler.

## Verdict

"Read view" and "write view" are good. "Read-only" is good but the
wrong claim for a Cell. "Off-limits" is vivid but too vague to act on
as an error message. The words are not the biggest problem: the
messages name a state, and a newcomer asks who put it there.
The one change that helps most: **messages should name the view that
causes the limit** ("cannot change `v` while `first` is reading it"),
not the state ("while it is read-only").

## My explanation to a colleague, after one reading

"`?x` gives you a window onto x that you can only look through. `!x`
gives a window you can write through. Like a numpy view or a
memoryview, it is the same data, not a copy. While a window is open,
the owner is restricted. If someone is only looking, the owner can look
too but can't change x. If someone is writing, the owner can't touch x
at all, not even to read. Windows close at their last use. Many
look-windows are fine; only one write-window. Cells are the exception:
you can have lots of write windows, because a Cell protects itself.
Everything is per field: viewing `p.a` leaves `p.b` free."

## Where my explanation is wrong or shaky against the model

1. **"Read-only" means immutable to me.** In Python it is a
   `@property` with no setter or a read-only memoryview. In Ruby it is
   `freeze`. Both are a permanent property of the object. I would first
   hear "x became frozen", then learn it is temporary, then be fine.
   Mild: "while" in the message fixes it.
2. **I would say "while the view's scope is open".** Rig ends at the
   last use. A Python or Ruby reader thinks of names and scope (`del`,
   block end). The write-up must say "last use" early, and show a
   program that is accepted for that reason.
3. **"Off-limits to whom?"** I pictured it as "nobody can touch x,
   including the holder of the write view". Wrong: the holder writes
   through the view all the time. The model line 2 says "x may not be
   used"; the real rule is "x, by its own name". Say "off-limits except
   through the view".
4. **Line 7 (`r = head(!v)`) surprised me.** I passed `!v`, so I
   expected v off-limits for as long as `r` lives. The model says only
   read-only. Reason (the result is a read view) is sound, but the
   sentence "a write view in, a read view out" must be taught or I will
   guess wrong. "Off-limits" during the call, "read-only" afterwards,
   is a state that changes mid-statement and I would not predict it.
5. **The Cell exception contradicts my own explanation.** I told my
   colleague "read-only means no changes", then `!c.set(5)` is accepted
   while `r = ?c` is alive. I would call that a bug. The wording
   "read-only" is false for a Cell. Truer statement: "x may not be
   *replaced, moved or dropped*, only changed by its own calls." That is
   a different idea, not a weaker read-only. A newcomer can hold it as
   "a Cell changes itself; the rule is about the owner replacing it".
   Suggested phrase for the Cell case: **"fixed in place"** (it may not
   be reassigned, moved or dropped; its contents may change). Or make
   the exception about the value: "a Cell lets any number of views
   change it; the owner still can't reassign or drop it".
6. **"Read, copied, given more read views."** "Copied" is risky: for a
   `List` a copy is `+x` and costs memory. Python and Ruby copy by
   reference, so I would assume `y = x` copies freely. Say "read" and
   "viewed", and leave copy to the plain-data case.
7. **By place (line 6).** Natural to me from attributes (`p.a`).
   "limits `p`" is unclear: limits what? I read it as "p as a whole
   cannot be moved or passed", which is right, but I need one example.
8. **Possible bug (`w: !Cell[Int] = !c` makes `c` off-limits; `two(!c,
   !c)` does not).** A newcomer who read "Cells allow many write views"
   would write the first form and be refused. The rule I was taught
   differs depending on whether the view is stored. If that is the
   model, it needs a sentence; if not, it is a bug.

## The four words, one by one

- **read view / write view**: good. "View" is already known from
  numpy, database views, `memoryview`, and Ruby's `Enumerator::Lazy`
  windows: "same data, no copy". "Read" and "write" are the exact
  verbs. Wrong guess to expect: that many write views can coexist
  (numpy, memoryview allow it). The one-writer rule must be loud.
- **read-only**: natural for the owner when views are reading. Fails
  only for the Cell case (item 5).
- **off-limits**: natural English, game and signage. But it says nothing
  about cause or remedy. Python and Ruby have no word for it. It is
  better than "locked" (Mutex) and "blocked" (channels), as the brief
  says. Alternative that says more: "in use for writing". I would keep
  "off-limits" in the docs and not in the messages.
- **loan**: I never needed it. "Lend" in the sigils chapter reads fine
  ("`?orders` lends `orders` to read"), but the learner then has two
  vocabularies (lend/loan and view). Keep "loan" for the compiler, as
  CORE does.

## Messages

- "cannot change `v` while it is read-only" trips me: "I did not make
  it read-only." Better: "cannot change `v`: `first` (line 3) is still
  reading it".
- "cannot use `n` while it is off-limits": "use" is vague (read? pass?
  print?). Better: "cannot read `n`: `w` (line 5) can still write it".
- Add the remedy where there is one: "last use of `first` is on line 6".

## The owner's qualifier question, plainly

Neither kind of view carries a qualifier. A view is just read or write,
and that is all it is. The limit is a state of the owner's value, and
it is set by the view kind: read view makes it read-only, write view
makes it off-limits. The only variation is the Cell exception, where a
write view leaves it read-only (or "fixed in place"), and there it is a
property of the value, not of the view. So: one kind per view, one
state per kind, plus one exception chosen by the type of the value. I
would tell the owner "no, views have no qualifiers; the value does".

## The simplest picture

One picture of a single variable x as a box on a table, with a time
line under it running left to right. A view is a bar drawn from where
it is made to its last use. Two rows for x. Row one: a blue bar (read
view) sits over x; above the bar the owner's hand is drawn reading but
with "change" crossed out, and the label says "read-only". Row two: an
orange bar (write view); the owner's hand is crossed out entirely, and
the label says "off-limits"; the view's own hand writes through the
bar. Next to it a smaller third row for a Cell: the orange bar is
shown stacked many times, with the label "changes itself, many
writers", and a note "owner may not replace or drop it". Bars end at
last use, not at the end of the block, and that gap is shaded and
labelled "free again".
