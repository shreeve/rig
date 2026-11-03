# Panel round 2, the Ruby view: the one-armed match

Probes are in
`/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/61e6bc21-7c82-43f3-8978-0dbbd8206817/scratchpad/ruby2/`
(`head.rig` plus one `*.body` per variant; run against this worktree's
`bin/rig` at 122d523bf, `RIG_SANITIZE=1`, `RIG_OUT_DIR` set to a temp
dir). `Image` has a `name: String` there, so it really moves. With an
`Image` of only `id: Int` every `<` is rejected ("it copies").

## What Ruby learned, briefly

```ruby
case entry.state
in Ready(rendered: Rendered => rendered) then retired << rendered.image
in _ then nil
end

retired << entry.state.rendered.image if entry.state in Ready(rendered: Rendered)   # one-liner, Bool
entry.state => Ready(rendered:)                                                      # one-liner, raises
if (rendered = entry.state.rendered) then retired << rendered.image end             # the old idiom
```

1. **The one-liner reuses the arm, not the header.** `case x / in P` becomes
   `x in P`. It does not say `case`. The pattern after `in` is copied
   unchanged from an arm, and that is why Rubyists read it as the same
   idea. The word that joins them matters much less than the pattern
   being the same.
2. **Ruby got the one-liner wrong twice.** In 2.7, `x in P` raised on no
   match. In 3.0 it became a Bool and `x => P` took over the raising.
   Both were experimental until 3.1. Lesson: settle up front what the
   one-liner returns and where its names live.
3. **Names leak, and modifier-`if` binds too late.** `x in P` binds into
   the enclosing scope even when the match fails. In
   `use(r) if x in Ready(rendered: r)`, Ruby reads `r` in the body as a
   method call (NameError), because the body is parsed first. Rig already
   avoids both: bindings live only in an `if`/`while` block, and a guard
   cannot bind (probe p5: "`as` binds only in the condition of an `if` or
   `while` block").
4. **Two match words is one too many.** `case/when` (`===`) next to
   `case/in` (patterns) is Ruby's most-asked pattern question. Rig has
   one `match`, and must keep a single mechanism.
5. **Nesting is the payoff, and also where it goes wrong.**
   `in {user: {role: :admin, name:}}` is why people use `case/in`. But the
   sublanguage grew `^pin`, `=> name`, `*rest`, `**nil`, find patterns, and
   `|`. Hardly anyone can read a deep Ruby pattern at a glance. Take
   nesting; leave the rest behind.
6. **`if (x = o)`** is how Ruby unwraps nil, with the name on the left.
   Ruby has to warn about `=` versus `==` in conditions, and RuboCop asks
   for parentheses. Rig's `if o as x` avoids that trap completely.

## Measured facts about Rig today

| Probe | Form | Result |
|---|---|---|
| t1 | full `match <entry.state` / `.ready(r)` / `if <r as rendered` / `_ => pass` | runs, `1 7 seven` |
| t2 | `if <entry.state as .ready(r) and <r as rendered` | runs |
| q3 | the same, as two nested `if`s | runs |
| q4 | `match` arm `.ready(r) if r != none` then `rendered = <r ?? return` | runs |
| q5 | `.ready(rendered: r)` by name | runs |
| q1 | `if entry.state as .ready` (bare, payload variant) | runs: a bare variant tests the tag |
| p6 | `if entry.state as .ready(r) and <r as rendered` | rejected: "write `match <entry.state` to take its fields" |
| p7 | `if <entry.state as .ready(r) and r as rendered` | rejected: "`rendered` is a view" |
| p5 | guard: `push(...) if <entry.state as .ready(r) ...` | rejected: `as` binds only in an `if`/`while` block |
| q2 | `ok = entry.state as .ready(_)` | rejected: same rule; no Bool form |
| p1, p4 | `if <entry.state is .ready(...)` | parse error: unexpected name `is` |
| p2, p3 | `.ready(rendered?)` in `match` or after `as` | parse error: unexpected `?` |
| p8 | `.ready(<r)` | parse error |

Today's one-arm form needs three `<` marks, and each one is required
(p6, p7). Each step of an `as` chain carries its own mode, so the chain
repeats the ownership story at every link.

Usage counts, from grep: Trig has **2,081** `if/while … as name`
(optional unwraps) and **0** `as .pattern`. Std, examples, and tests
together have 1,374 and 27. Trig has 854 `match` statements and 442
`_ => pass` arms. Pattern `as` is nearly unused; name `as` is everywhere.
The word `is` appears as a name only once, a local in Trig's
`printer.rig:1664`.

## 1. The ideal one-arm spelling

```rig
if <entry.state is .ready(rendered?)
  !@retired.push(<rendered.image)
```

**It need not say `match`.** Ruby's lesson is that the one-liner ties
back to the full form through its **pattern**, not its header. Put the
two side by side:

```rig
match <entry.state
  .ready(rendered?) => !@retired.push(<rendered.image)
  _ => pass
```

The subject is the same, sigil included. The pattern is the same text,
and so is the body. `match` becomes `if`, the line break and indent
become `is`, and `_ => pass` drops out. SPEC can say it in one line:
"`x is P` is `match x` with the one arm `P`, and its other values fall
to `else`." That is exactly the rule SPEC already states for `as`.

Why `is` and not `match`, `in`, or `as`:

- `if state match .ready(r)` puts a verb where English wants
  "matches". `matches` itself is a coined, eight-letter operator.
- Ruby's own `in` reads as membership to everyone coming from Python,
  which was a common complaint about Ruby 3. Rig also uses `in` for
  `for`, and may want `x in xs` someday.
- `as` reads as a rename or a cast in every language people know
  (`import a as b`, `x as i32`, SQL `AS`). `x as .ready(r)` looks like
  converting x into a ready. That is why the owner stumbles on it.
- `is` is the plain English question, "if the state is ready". C# uses
  `is` with full patterns (`state is Ready { Rendered: { } r }`), and
  Kotlin and Swift use `is` for tests. Rig has no identity operator, so
  `is` can never mean Python's identity.

## 2. Swiss's narration as code

> If the entry we just removed was ready and holds a rendered result,
> move that result's image onto the retired list.

```rig
entry = !@entries.take(key) ?? break          # the entry we just removed
@bytes -= entry.bytes
if <entry.state is .ready(rendered?)          # was ready and holds a rendered result
  !@retired.push(<rendered.image)             # move that result's image onto the retired list
```

Each clause of the sentence maps to one group of tokens: "was ready" is
`.ready`, "holds a rendered result" is `(rendered?)`, "move" is `<`,
"that result's image" is `rendered.image`, and "onto the retired list"
is `!@retired.push`. Nothing extra is written and nothing is hidden.
Ruby's best attempt, `retired << entry.state.rendered.image if
entry.state in Ready(rendered: Rendered)`, says the path twice and
hides that the image is shared.

Round 1's filter predicate gets the same word as a Bool:
`.filter(|e| e.value.state is .ready)`.

## 3. Nested patterns: yes, minimally

Without nesting, the second `as` (or a nested `if`) exists only to get
past an optional. It costs a binding (`r`), a link in the chain, and a
`<`. Swift writes the same pattern as `case .ready(let r?)`, and Rust
as `Ready(Some(r))`. The `?` suffix already means "the value inside,
or leave" in an expression (`x?` returns `none`). In a pattern it means
"the value inside, or this arm does not match". That is the same
meaning, so no new idea is introduced.

Grammar change in one line:

```
field := "_" | NAME | NAME "?" | "none" | "." NAME [ "(" field, … ")" ] | literal     # a variant's field is a pattern; NAME? matches a value, not none
```

Take nesting, `NAME?`, and `none` (needed so that `.ready(r?)`,
`.ready(none)`, and `.loading` can be exhaustive), and nothing else. Do
not take Ruby's pins, `=> name` rebinding, rest or find patterns, or
`|` (Rig's alternatives are `,`). Deep patterns are a readability trap
in Ruby, and one level of nesting covers almost every real case.

## 4. Where the moves go

**Twice: once on the subject and once at the use.** That is one fewer
than today, and both are load-bearing.

- `<entry.state` says "this test consumes the state". It is the same
  mark and place as `match <e` and `for <xs`. Under it, every name the
  pattern binds owns its part, nested ones included, so `rendered` owns
  the `Rendered`. A value that does not match drops before `else`
  (SPEC already says so for `as`).
- `<rendered.image` says where the part goes. The rest of `rendered`
  drops at the end of the block.
- No sigils inside patterns. `.ready(<r)` stays a parse error (p8):
  the subject's mode applies to the whole pattern, as it does in
  `match`. Today's middle `<r` exists only because the chain splits one
  match into two, and nesting removes it.

The read form needs no mark at all:
`if entry.state is .ready(rendered?)` then
`!@retired.push(+rendered.image)` (views, plus a visible clone).

## 5. What `as` becomes

**Keep it, for names only. `as` names a value, and `is` tests a
pattern.** Each word does one job.

- `if o as x`, `while (!q).pop() as x`, `if f() as a, b`: `as` stays,
  with all 2,081 uses in Trig unchanged. "Take the value as x" reads
  correctly when a name follows, and its name-on-the-right form avoids
  Ruby's `=`/`==` trap.
- `as .pattern` becomes `is .pattern`. That is 27 lines in tests and
  docs, a `sed`, and a one-line migration note for Trig, which has 0
  uses. The old form is rejected with "a pattern follows `is`: write
  `x is .ready(r)`".
- `x is P` with no bound names is a Bool anywhere (round 1's missing
  `matches!`). With bound names it is allowed only in an `if`/`while`
  condition, joined by `and` (Ruby's leak lesson). As with `as` today,
  it takes no guard and no alternatives: use `and`, or a `match`.
- With nesting, `if o is x?` would also unwrap an optional. Reject it
  with "write `if o as x`" so there is one spelling per idea.
  `NAME?` belongs inside a variant's fields only.

What parses or runs today: every probe listed as "runs" above, including
the full `match` and the bare `.ready` test (q1). Nothing proposed here
parses yet. `is` is "unexpected name", and `.ready(rendered?)` is
"unexpected `?`". Both need a grammar change, small ones: a keyword and
one field alternative. Sema needs to lower `is` exactly as it lowers
`as .pattern` today (`as_match`), recurse into the fields for nesting,
and allow the Bool form outside conditions.
