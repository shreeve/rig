# Rig mantras

Short phrases we steer by. Each is a lesson Rig has already paid for,
written down so the next decision costs less. When two choices both
work, the one a mantra favors wins. The rules they come from are in
[AGENTS.md](../AGENTS.md), [docs/CORE.md](CORE.md), and
[docs/DESIGN.md](DESIGN.md).

## How we choose

**It's better to dissolve a problem than to solve it.** A problem that cannot occur
beats a clever fix for it. Ownership makes a use-after-free impossible
instead of detecting it at run time; a write view is never stored, so
none can dangle; a result that may be missing is a `T?`, so no caller
can forget the missing case. If the fix needs a diagram, look for the
design where the problem has no place to happen.

**Concentrate the pain, distribute the glee.** Hard work done once, in
the compiler or the standard library, beats easy work done by every
user. A week spent making `rig check` reject a dangling view saves every
Rig programmer the night in a debugger; days spent shaving cycles off
`std.json` make every program that parses JSON faster for free.

**Center before edges.** Make the core sound and simple before adding
features at its edges. A feature built on a shaky center multiplies the
shake.

**Substrate in the language, libraries in userland.** The language gives
the pieces (ownership, vectors, closures); frameworks are built from
them, not built in.

**Shorter and plainer than idiomatic Rust.** That is the bar a new form
must clear ([IDEAS.md](../IDEAS.md)).

## How we build

**We test and verify everything we say.** A feature exists when a
program using it runs and prints the right thing, sanitizer-clean. A doc
claims nothing the suite does not check.

**Accept means correct.** If `rig check` accepts a program, it compiles,
runs, and does what the source says. Anything else is a Rig diagnostic,
never a Zig error.

**Fix the class, not the instance.** A bug is one member of a class;
name the class, check its siblings, and add the test that would catch
the next one.

**One classifier per fact.** Each fact about an expression is decided
once, by a positive list, and recorded. No pass re-derives it, and no
category is defined as "not" another.

**The checker checks exactly what is emitted.** Emit adds nothing the
checker did not walk: no hidden temporary, order, or drop.

**A second soundness round stops the feature.** Needing a second round
of soundness fixes means the design is wrong; redesign it rather than
patch it again.

**Land fast, release deep.** Each round passes a fast gate in minutes;
the deep gate runs on `main` twice a day.

**Rerun only what changed.** A rerun checks everything and runs only
what differs from a run that passed.

**Comments explain the code as it is.** History belongs in git.

## How the language reads

**Effects stay visible.** Every move, clone, allocation, failure, and
mutation shows at the place it happens, as a sigil or a call.

**No hidden cost.** No garbage collector, no hidden allocation, no hidden
reference counting, no silent control flow.

**A marker asks for speed, never for meaning.** `inline fun`,
`called fun`, and `rarely fun` change where the code lands, not what it
does; a program means the same with every marker removed.

**Square brackets after a name mean compile time.** `List[Int]`,
`push[U32, .big](x)`, `Simd[U8, 16]`; parentheses are run time.

**`@name(…)` asks the compiler about a type; `@name` alone is a
label.** The `(` touches the name. Each of Rig's `@` builtins (`@size`,
`@align`, `@name`, `@type`, `@variants`) is a question the compiler
answers when it compiles, at no cost when the program runs. Work done on
a value is a method or a function, never an `@`: so `x.hash()`, not
`@hash(x)`. (Zig's own builtins, inside `raw`, are Zig's.) A label,
`@outer for`, `break @outer`, names a statement and asks nothing.

**Name from the owner's side.** The owner lends; the compiler records a
loan; the receiver holds a view. The rules are the ownership model, and
the pass that enforces them is the ownership checker. Rust's single word
for all of these is never ours: in docs, code, commits, and proposals,
say "the ownership checker treats a loan of one field as a loan of the
whole value", not that the checker of that other name is too strict.

## How we name

**Actions are verbs.** `!v.push(x)`, `!v.insert(i, x)`, `!v.clear()`.

**Queries name their answer.** `v.len`, `v.get(i)`, `x.to_bits()`.

**A test reads as a question.** `text.is_digit(b)`, `q.is_empty()`.

**A method, when the value is the subject.** `x.to_bits()`, not a
builtin taking `x`.

**A stored size is `len`; a size you compute is `count`.** `s.len` is
bytes and instant; a count of runes must scan.

**The name says which end and which unit.** "Keep the first `n`" can be
read one way; a bare `drop(3)` leaves readers guessing which end.

**Avoid a word other languages disagree on.** `pop(3)` is the last three
in Ruby and index 3 in Python, so Rig doesn't use it.

**A char is what a reader sees.** In Rig a char is a grapheme, one
character as a person counts it, and nothing else: a byte is a byte, a
code point is a rune, and a UTF-16 code unit is a unit. Other languages
spend "char" on one of those; Rig gives each its own word, so "char" can
mean what everyone means by "character".

## How we measure

**Same speed or faster, or it doesn't swap.** Code the standard library
replaces (Trig's helpers, std.json's routines) moves only when std is at
least as fast, per function. "As fast" means within 2%: measured in a
quiet window, interleaved, fastest of N. Between two at parity, the
cleaner code or algorithm wins; a swap usually is the cleaner one, since
it removes a duplicate. A loss goes to the owner with its numbers and a
fix, never swapped in quietly. A new optimization lands only if it wins
by more than 2% on what it targets, with cycles backing the time, and
loses nothing beyond 2% elsewhere: a change within 2% is noise, and is
dropped.

**Measure time, not instruction counts.** Fewer instructions can run
slower; only time decides.

**Size a check by removing it.** A profiler's samples in a check include
the work around it; remove the check and count.

**Only interleaved timing judges a hot loop.** Moving code elsewhere can
shift a loop's speed by 5-7% on Apple cores.

**Say "N% faster" or "N% slower".** Never a bare plus or minus.
