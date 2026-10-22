# Owner brief: field loans, `keeps`, the `replace` fix, std.regex

2026-10-13. Sources: `proposal-field-loans.md`, `proposal-call-stores.md`
(with its Appendix A), `proposal-regex.md`, `docs/CORE.md`, and Trig's
NEEDS.md items 11, 24, and 28. Every "rejected today" below was rechecked
today with `bin/rig check` on main's binary (built Oct 13, 09:01).
Estimates are marked *est.*

## Decisions at a glance

| # | Decision | Recommend |
|---|---|---|
| 1a | Field loans: approve the CORE text in §1 below | Yes |
| 1b | A box's fields are separate places (`b.a`, `b.n` disjoint for `b: ^T`) | Yes |
| 1c | CORE says "a value never holds a view of itself" (Rust instead allows it and forbids the move) | Yes |
| 1d | Field-precise re-pointing (n39) gets its own later round, though HANDOFF says "with" | Yes |
| 1e | A `!self` method's view result still lends all of `self` this round (`from self.text` waits for path tokens) | Yes |
| 2a | A lent parameter is kept only when the signature names it (option b) | Yes |
| 2b | Spelling | `keeps s` clause |
| 2c | By-value parameters keep today's type rule | Yes |
| 2d | Function values keep by type until function types get clauses | Yes |
| 2e | An argument the callee keeps needs a written `?` at the call | Yes, same round |
| 2f | Approve the CORE sentence 7 text in §2 | Yes |
| 3 | Land the `replace` fix now, as its own hotfix | Yes, first |
| 4a | std.regex now (a) or after traits and Map/Set (b) | (b) |
| 4b | When it comes: wrap Nexis's engine instead of writing one in Rig | Wrap |
| 4c | Its syntax: RE2's (Go's), not Java's | RE2 |

Order: the `replace` hotfix, then field loans and `keeps`. The two
proposals change different facts, so they may run side by side; the
second to land passes the full gates on the combined tree. Besides
modules, these two are the largest blockers left before Trig's binder.
Go's `Binder` struct holds the `file` it reads beside the binding state it
writes (`binder/binder.go`), so the port runs into both.

---

## 1. Disjoint field loans (NEEDS 28)

**The problem.** A loan today covers a whole variable. Lending `self.a`
lends all of `self`, so no other field can be read, written, or lent while
the loan lives. Trig pays one String copy per identifier and literal.

```rig
obj Arena
  names: List[String]

  sub mk(!self, t: ?String)
    !self.names.push(String(t))

obj Parser
  a: Arena
  t: String

  sub step(!self)
    (!self.a).mk(self.t)   # cannot lend `self` to write while a read loan is live
```

Trig's lexer hits the same rule: `t = ?self.text[0..2]` then
`self.flags |= 1` gives "cannot assign to `self.flags` while `self` is
lent" (`trig/docs/lexer/repros/field-loans.rig`).

**Trig's evidence.** `src/parser.rig:313` returns `+self.scanner.token_value`,
a copy made only to end the loan on the parser. RESULTS.md measures the parse
of `checker.ts` as 29% slower than Go (24.9 ms against 19.3 ms) and names
this copy as part of the gap. That figure was measured on the earlier
scanner. The lexer also cannot own its text, because any slice of the text
lends the whole scanner.

**CORE wording proposed.** Sentence 5's heading and first line become:

> **5. A place has any number of read loans, or one write loan, never
> both.** A loan on a place covers every place inside it, so two
> places conflict when one holds the other: `p` and `p.a`, `p.a` and
> `p.a.b`, but not `p.a` and `p.b`. This holds for every type, numbers
> included. *(built;* for fields, *planned.)*

§5 gains, after the list of what a place is:

> **A field is a place of its own.** A path is a name and the fields
> after it, through what a write view the name holds sees, and through
> a box. It stops at an element, a handle, or an optional's value, and
> the loan is on the path so far: `?v[i]` and `!v[j]` are both loans on
> `v`, and `?h.f` with `h: *T` is a loan on `h`. A use touches the path
> it names: `?p.a`, `!p.a`, `<p.a`, `p.a = x`, `(!p.a).m()`, and
> `swap(!p.a, !p.b)` touch `p.a` (and `p.b`); `p`, `<p`, `p = x`,
> `(!p).m()`, and `!p.m()` touch all of `p`. A value never holds a view
> of itself: storing in a part of `p` a value that carries a loan on a
> part of `p` is rejected. *(planned)*

**The desugaring.** For loans, a struct variable is a group of
variables, one per field, nested. Using `p` as a whole uses every
variable in the group. `(!self.a).mk(self.t)` becomes
`w = !self.a; t = ?self.t; w.mk(t)`: a write loan on one variable and a read
loan on another, which sentence 5 already allows. The emitted Zig does not
change. Emit adds no temporary, order, or drop.

**Before and after.**

```rig
# Before (runs today): copy, so that no loan on `self` is live
  sub step(!self)
    v = +self.t
    (!self.a).mk(v)

# After: no copy
  sub step(!self)
    (!self.a).mk(self.t)
```

`swap(!p.a, !p.b)` loses its special case (`disjointFields`, a second,
syntactic place classifier) and falls under the general rule.

**What stays conservative.** Elements (`v[i]` and `v[j]` still overlap,
because an index is a run-time value; `!v.swap(i, j)` is the form to use).
Handles (`?h.a` with `h: *T` is a loan on `h`). A method on the whole receiver
(`!self` lends all of it, and so does the view it returns). Self-views
(`p.a = ?p.b` stays rejected). What a variable holds stays per variable
(n39), and `carry` is still judged by the variable's type. A path longer than
the interner's bound (about 8 steps) is cut, which only adds conflicts.

**Decisions:** 1a–1e above. 1c is today's behavior, which whole-variable
loans gave for free. With paths it has to be stated: without it,
`(!p.a).keep(?p.b)` could leave `p.a` viewing bytes that `p.b = ...` frees.

**Effort and order.** One round: `Loan` gains a path, one overlap function,
about twenty conflict sites in `src/ownership.zig`, the self-view check, the
`swap` deletion, three oracle sites and one new check, CORE, SPEC, and
INTERNALS, about ten reject tests and eight run tests, and a new `field.`
grid. It changes a soundness classifier, so it runs the full matrix and the
oracle gate. *Est.* about a week of work, plus gates and review. #159 and
#156, which the proposal waited on, have merged. It still waits for #151
(open; typecheck classification and the oracle's `lower.zig`).
#166 (closures, open) edits `src/ownership.zig` next to `conflicts`. It adds
no classifier, but whichever of the two lands second rebases and passes the
full gates on the combined tree.

---

## 2. `keeps s`: a call that reads an argument without keeping it (NEEDS 11)

**The problem.** A `!self` method of a struct that holds a view counts each
lent argument as stored in `self`, judged only by the types: a `?String`
"could" be stored in a struct that holds a `?String`. Nothing narrows that.
So a method that only reads its argument is treated as a setter.

```rig
obj Parser
  src: ?String
  errors: Int

  sub note(!self, msg: ?String)
    if msg.len > self.src.len
      self.errors += 1

  sub check(!self)
    suggestion = String("did you mean x?")
    !self.note(?suggestion)  # cannot let this call store a view of `suggestion` in `self`: `self` outlives it
```

**Trig's evidence.** The lexer folded Go's separate `regExpParser` into the
scanner as the field `s.rx`, with its methods as functions of the scanner
(`docs/lexer/COMPARE.md`). A parser beside the scanner was rejected, and so
were the other shapes: `replace` (§3) and an owned text (§1). Helpers return
owned Strings where Go returns slices. `repros/view-field-store.rig` rejects
both `!self.add_to(!out)` and `!c.run(!self)`. Neither call stores anything.

**CORE wording proposed.** Added to sentence 7, after "of `a` alone.":

> A call keeps only what its signature shows. A value passed to it by
> value is the callee's, which may keep it, and its loans, wherever its
> type fits. A view lent to it (a `?T`, `!T`, `[]T`, `![]T`, `?String`,
> an optional of one, or a `?self` or `!self` receiver) it keeps only
> when the signature names that parameter in `keeps` (`sub watch(!self,
> s: ?String) keeps s`): it may store what the view sees in what its
> write receiver and write arguments lead to, and the loan lasts while
> that holder is used. Any other lend ends when the call returns. A
> function called as a value keeps what its type could hold, since a
> type names no `keeps`. The compiler checks each body against its
> `keeps`. *(planned)*

If 2e is approved, sentence 4's list of written lends gains "and a lend to
a parameter the callee keeps (`!p.watch(?t)`)".

**The desugaring.** Nothing new is added, as with `from`: `f(e1, ..., en)` is
still `t1 = e1; ...; tn = en; f(t1, ..., tn)`. Only the set of stored
arguments changes, from "every lent argument whose type fits" to "the lent
arguments `keeps` names, plus by-value arguments by type". The body check
that already exists rejects a store the signature does not show, and its
note says how to fix it: "say so: `keeps s`".

**Before and after.**

```rig
# Before (runs today): take the argument owned, so nothing is lent
  sub note(!self, msg: String)
  ...
    !self.note(<suggestion)

# After: lend it; `note` keeps nothing
  sub note(!self, msg: ?String)
  ...
    !self.note(?suggestion)

# After: a setter must now say that it keeps its argument
  sub set_src(!self, s: ?String) keeps s
    self.src = s
```

**What stays conservative.** By-value parameters keep the type rule (pushing
a `Token` that holds a `?String` needs nothing written). Function values keep
everything their type allows. Built-in generics' methods keep every argument.
`keeps s` does not name the target the view is stored in.

**Spelling options.**

1. A clause, like `from`: `sub watch(!self, s: ?String) keeps s`.
2. A word on the parameter: `sub watch(!self, keep s: ?String)`.
3. Naming the target too: `sub watch(!self, s: ?String into self)`.

**Recommend 1.** It is the same mechanism as `from`. It is a contextual word,
as `from` is, and it names the receiver `self` the way `from self` does.

**The case against the pick.** For the spelling: the fact is about one
parameter, so option 2 puts it where the reader looks, and option 3 is the
most precise (it is what Rust's named lifetime says). Option 1 adds a second
trailing clause and puts the name away from its parameter. For option (b)
itself: it breaks code. Every function that stores a lent parameter is
rejected until it says `keeps`, and how many there are is unknown until the
first build. It has two defaults: a lent parameter is not kept, but a
by-value one is. It is post-freeze churn for one consumer. Option (a)
(today's rule, plus a clause that narrows it) breaks nothing. Its cost is an
annotation on the common case, and a rejection that newcomers meet first.

**Effort and order.** A small checker round: grammar, resolve,
`declOrigins`, `checkOrigins`, the oracle, and the docs (CORE, SPEC, SYNTAX,
INTERNALS). The migration of std and the examples is unmeasured. `stores` is
an ownership fact, so the round runs the full matrix. *Est.* 3–5 days plus
the migration. It waits for #158 (modules, open), which rewrites the
`fun`/`sub` schema lines that the clause sits on, and for #151 (open). #159
has merged, and its `isViewType` (`src/ownership.zig`) moves to sema as the
one "lent parameter" classifier.

---

## 3. The `replace` fix (call-stores Appendix A)

**What is wrong.** `replace(!s, v)` hands back the old value, which it owns.
The checker treats that result as a view of `s`, because `walkSwapCall`
carries the `!s` loan by type reach. So `s` stays lent to read while the
result lives:

```rig
obj Scanner
  text: ?String
  value: String

sub main()
  src = "abc"
  s = Scanner(text: ?src, value: String())
  taken = replace(!s, Scanner(text: "", value: String()))
  _ = replace(!s, <taken)  # cannot lend `s` to write while a read loan is live
  print(s.text)
```

It happens only when the struct also owns a String. Trig's
`repros/replace-view.rig` hits it, which is why the scanner could not be
moved out and given back.

**The fix.** Treat `replace(!p, v)` as `t = <p; p = v`. The result carries
what `p`'s value held, as `walkTake` already does for `<p.f`, and no loan on
`p`. The class is "a value moved out of a place, treated as a view of it",
and its siblings (`walkTake`, built-in method results, `<b.unbox()`,
`match <x`) are listed in the appendix.

**Independent of 1 and 2.** Yes. The place is all of `s`, so field paths
neither explain the bug nor fix it, and `keeps` does not apply (a result is
not a store). It does touch the same function (`walkSwapCall`) that field
loans rewrites, so land it first.

**Size.** One function plus four tests: the program above, Trig's repro, a
place through a write-view local, and a reject proving the place is write-lent
during the call. It edits `src/ownership.zig`, so it runs the full matrix.
*Est.* under a day of work, plus gates.

**Ready to build?** The design is complete: cause, fix, class, siblings, and
tests. **It is not built.** There is no branch or PR for it, and the program
above is still rejected today. It needs only your yes (3).

---

## 4. std.regex timing

**Nexis's engine** (`nexis/src/regex.zig`, 2,518 lines, plus
`regex_tables.zig` with 642 lines, on Zig 0.17 as Rig is):

- **Syntax:** Java's `java.util.regex`, minus every construct that needs
  backtracking. Back-references, look-around, atomic groups, and possessive
  quantifiers are refused when the pattern compiles, with a sentence naming
  them.
- **Features:** numbered and named `(?<name>...)` captures; classes with
  ranges, negation, nesting, and `&&`; POSIX `\p{Alpha}`; general categories
  `\p{Lu}`; anchors `^ $ \A \z \Z \b \B \G`; flags `i d m s u x`, inline and
  scoped; lazy quantifiers; UTF-8 code points; and `(?iu)` Unicode case
  folding from Java's tables. It has no scripts or blocks.
- **Engine:** a Pike VM (a Thompson NFA with per-thread capture slots,
  leftmost-first). One search is linear in the input, O(n·m·k). A find-all
  loop can be quadratic, the same bound as RE2 and Rust (REGEX.md §3.5).
  Compile limits: 10,000 instructions, 2^20 slot words, and nesting 250. It
  has literal, prefix, and first-byte prefilters.
- **Tested:** a differential corpus of 9,000 random and about 150
  hand-written cases against Java (REGEX.md §7).
- **Zig API:** `compile(arena, src, flags)` returns a `Program` or a
  `SyntaxError` with its message and offset. `Vm.init(gpa, prog, groups)`,
  `vm.exec(hay, from, last_end, whole)`, `vm.group(g)`, `Finder.find()`, and
  `Program.groupIndex(name)`. About 260 lines are Nexis heap glue
  (`make`, `MatcherBox`) to cut.

**Go uses RE2 syntax, and the two differ.** One difference is visible: tsc's
`{(\d+)}` is a syntax error in Java syntax ("Illegal repetition",
regex.zig:933), because Go reads a stray `{` as a literal. `(?P<name>...)` and
`(?U)` are refused. Other differences are **silent**:

- without `(?m)`, `$` also matches before a final line terminator, so semver's
  `^...$` would accept `"1.2.3\n"`;
- `.` also excludes `\r`, U+0085, U+2028, and U+2029;
- `(?i)` folds ASCII only;
- `\s` includes `\x0B`;
- `\v` is a class, where Go's is the vertical-tab character;
- `[[:alpha:]]` is the set of the characters `:alph`.

**Trig's users.**

- Go's semver compiles 11 fixed patterns (`version.go`, `version_range.go`).
  NEEDS 24 counts seven. Trig's `src/semver.rig` hand-writes each one as a
  matcher, and passes Go's tests and 214 tsc cases.
- `diagnostics.go:127` uses `{(\d+)}` for `Format`, through
  `ReplaceAllStringFunc`, which needs closures. Trig has not ported `Format`
  yet.
- `modulespecifiers/util.go:116` compiles the user's auto-import exclude
  patterns at run time, in a map cache cleared past 1,000 entries. This is
  language-service code, and its cache needs Map.

**Option (a): a minimal std.regex soon, wrapping Nexis through `extern zig`.**
API sketch, following RIG-MANTRAS and TEXT-API's rules (#188):

```text
regex.compile(pat: ?String) -> Regex!            # regex.Error: syntax, unsupported, too_big
r.is_match(s: ?String) -> Bool                   # anywhere in s, as Go's MatchString
r.find(s: ?String) -> Int?                       # start of the leftmost match, as text.find
r.captures(s: ?String) -> Captures? from s       # c.get(i) -> (?String)?, c.len; group 0 is the match
later: r.matches(s) (an iterator: a plural noun), replace_all, split
```

This departs from the sketch I was given in two places. `find` returns
`Int?` (TEXT-API rule 4), so the match itself comes from `captures`. And the
test is `is_match`, not `matches`: Java's `matches` tests the whole string
while Go's `MatchString` searches, which is a word other languages disagree
on, and TEXT-API keeps plural nouns for iterators. A `Regex` is owned and
immutable, and it is matched through `?r`. Results view `s`, as
`text.cut`'s do. Errors carry no data yet (NEEDS 7), so the error's sentence
and offset are lost.

**One unknown.** No `extern zig` function today allocates, takes a write
view, or returns an owned value. Every std shim takes numbers or read views
and returns numbers, views, or `Static`. A `Regex` must own its compiled
program, which means Rig-owned bytes that a shim fills, and each match needs
O(m·k) scratch. That boundary is the first thing to prove, and the main risk
in the estimate. *Est.* 3–5 days for `compile`, `is_match`, `find`, and
`captures` with Java syntax. An RE2 dialect switch in the parser, with a Go
differential corpus, is *est.* 2–4 days more.

**Option (b): after traits and Map/Set.** This is weeks away: #158 (modules)
and #166 (closures) are still open, and traits/Map is still a proposal. It is
the decision already recorded in NEEDS 24 ("Approved: a linear-time
`std.regex`, after traits"). `proposal-regex.md` planned a new engine written
in Rig, *est.* 2.5 weeks there. Wrapping Nexis would make (b) cheaper too.

**The cost of (a).** A few days of the Rig session plus a review, taken from
landing modules and closures, from traits and Map/Set, from the ownership
lane (§3, §1, §2), and from the text-API rounds (#186, #188). Nothing in Trig
waits on regex: semver works, `Format` can loop over `{`, and the exclude
patterns belong to the language service.

**Recommendation: (b).** The ownership lane is what Trig's binder needs
next, and regex unblocks nothing in Trig today. Its value now would be
general value to Rig, which is real but can wait weeks. When it comes, wrap
Nexis's engine (4b) rather than write one: it is built, linear-time, and
tested. Give it RE2 syntax (4c), so that a Go port is a rename, as TEXT.md
promises for `std.utf8`, and the silent differences above cannot bite.
