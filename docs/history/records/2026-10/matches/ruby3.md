# Panel round 3, the Ruby view: `matches`, alternatives, bindings

Scripts and probes are in
`/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/61e6bc21-7c82-43f3-8978-0dbbd8206817/scratchpad/ruby3/`
(`scan.py` reads every `match` in Trig, `chains.py` finds `x == .A or x == .B`
chains). Trig at 1256d95, read only. Ruby facts were checked with ruby 4.0.9.

## What Ruby learned about alternatives

1. **Ruby has two spellings of "any of these", and that costs it.**
   `case/when` uses commas (`when :ready, :start`). `case/in` uses `|`
   (`in :ready | :start`), because in `in` a comma already meant an array
   pattern. The trap is real and silent. The same list moved from `when`
   to `in` changes meaning:

   ```ruby
   case 2; when 1, 2 then :yes; end   # => :yes
   case 2; in 1, 2 then :yes; end     # NoMatchingPatternError: 2 does not respond to #deconstruct
   ```

   `in 1, 2` means `in [1, 2]`. Rig must never let the comma in
   `matches` mean something other than the comma in a `match` arm.

2. **The comma list is the form people use.** In Ruby's own stdlib,
   188 of 1,892 `when` lines (10%) list alternatives with commas. In the
   installed gems it is 495 of 3,431 (14%). `case/in` is rare (77 lines
   in the gems), and only 14 of those use `|`. Rubyists reach for the
   comma; `|` is the price `in` paid for its arrays.

3. **The one-liner does not fit in an argument list, even in Ruby.**
   `p(1 in Integer)` is a syntax error ("unexpected 'in'; expected a `)`").
   Ruby makes you write `p((1 in Integer))`, with or without alternatives.
   Inside a block it works: `xs.select { |e| e in :ready | :start }`,
   because a block body is a statement list, not an argument. Rig's
   one-line closure body *is* inside the argument list, so Rig meets the
   same wall Ruby did. Ruby's answer was the extra parentheses.

4. **`include?` is the idiom Ruby uses when patterns don't fit, and it
   is the wrong model for Rig.** `%i[ready start frozen].include?(state)`
   appears 135 times in the installed stdlib and gems. It reads
   backwards (the set first, the subject last). It builds an array (recent
   Ruby optimizes a literal one away), and it compares with `==` one by
   one. Rails added `state.in?(:ready, :start)` only to put the subject
   first. Rig gets subject-first, no array, and a single evaluation for
   free if `x matches .a, .b` lowers to one Zig `switch` prong
   (`.a, .b => true`). Do not add `x in [...]` or `[...].contains(x)` as
   a second way.

5. **Ruby forbids names in alternatives.** `in [x] | [x, _]` is a
   SyntaxError ("variable capture in alternative pattern"). Rig's rule,
   "an alternative list binds no names", is the same rule and needs no
   change.

## 2. The count: are alternatives needed? Yes, they are the main case

Trig has **834** `match` statements with 3,856 arms. **758 arms (20%)**
list alternatives: 287 have 2, 144 have 3, and 327 have 4 or more
(101 have 10 or more).

These are the places `matches` would replace today's code:

| Shape in Trig today | Sites | With alternatives |
|---|---|---|
| Bool match: one `=> true` arm, `_ => false` | 75 | 71 (56 with 4+) |
| One real arm and `_ => pass` | 74 | 43 |
| `x == .A or x == .B ...`, same subject | 277 | all (218 of length 2, 37 of 3, 22 of 4+) |
| `x != .A and x != .B ...`, same subject | 43 | all |
| either chain where the subject is a call, e.g. `tree.kind(n)` | 51 | evaluated again for each test |
| a test inside a closure (`\|a\| k == .A or k == .B`) | 3 | 3 |
| `match` inside a closure | 0 | 0 |

So about **430 sites** would use `matches` with alternatives. Only about
**35** would use it with a single pattern, and 24 of those bind a name. Option (f), dropping
alternatives, would turn every row above into
`x matches .A or x matches .B`, which is today's chain again with a
longer word. Alternatives are what makes `matches` worth having.

The closure case that started this question is the **rarest** one: 3
sites. Whatever it costs should fall on that case and leave the 400+
statement and assignment sites alone.

## 1. The spelling inside a call

**Keep the comma, the same comma as a match arm. Inside brackets, the
comma belongs to the bracket, so a test with alternatives there is
wrapped in parentheses: option (a).**

```rig
live = entries.filter(|e| (e.value.state matches .ready, .start, .frozen))
```

Why (a):

- **It adds no new rule.** Parentheses already group an expression, and
  inside brackets a comma already separates items. Python has the same
  rule for generator expressions (`f((x for x in y), 1)`), and Ruby is
  stricter: it requires `p((x in P))` even with a single pattern.
- **One spelling of the list everywhere.** `.ready, .start, .frozen` is
  the same text in an arm, after `matches` in an `if`, and inside the
  parentheses. This is Ruby's lesson 1, applied.
- **A block closure avoids the parentheses entirely.** SYNTAX §2 already
  lets a closure's body sit below its bar list inside a bracket:

  ```rig
  live = entries.filter(|e|
    e.value.state matches .ready, .start, .frozen
  )
  ```

- **Long lists get line joining for free.** Inside parentheses a newline
  is whitespace, so a ten-variant predicate can wrap without `\`.

To keep it from surprising anyone, a `matches` directly followed by a
comma inside a bracket is **rejected, never guessed**. `f(x matches .a, .b)`
could mean either one test or two arguments, so the error offers both
readings: "inside a call, put the test in parentheses:
`(x matches .a, .b)`, or `(x matches .a), .b` if `.b` is the next
argument". This is the rule Python uses for an unparenthesized generator
expression.

The other options, and why not:

- **(b) `matches(.a, .b)`** breaks Rig's rule that a name followed by
  `()` is a run-time call. It reads as a function named `matches`, and
  readers will look for one.
- **(c) `matches (.a, .b)`** gives the list a second spelling (with
  parentheses here, without them in arms). It also looks like a tuple or
  group pattern, which is a word Rig may want later.
- **(d) `or` between alternatives** collides with Boolean `or`. A bare
  name is a pattern in Rig (a constant, or a new binding), so
  `if x matches .a or done` has two readings. Ruby avoided `or` in
  patterns for the same reason: `x in A or B` is `(x in A) or B`.
- **(e) `|`** is Ruby's choice, and Ruby made it only because the comma
  was taken. In Rig it would be a second alternative spelling unless all
  758 arms changed. It reads as bitwise or (`FLAG_A | FLAG_B`, which Trig
  writes constantly). It also puts bars next to a closure's bar list:
  `|e| e.s matches .a | .b | .c`.
- **(f) no alternatives**: the counts above rule it out.

Two smaller rules follow Rig's existing grammar:

- **Precedence.** `matches` sits with the comparisons and does not chain.
  So `not` needs parentheses, as it already does for `==`:
  `if not (kind matches .A, .B)`. That covers the 43 `!=` chains. Do not
  add a `!matches`.
- **No guard on `matches`.** `p if cond` after an expression would collide
  with the ternary `a if c else b`. Write `and` instead:
  `if x matches .ready(r) and r > 3`.

## 3. Bindings: yes, in `if`/`while` conditions only

Keep binding patterns. In Trig, **24 of the 74** one-arm `_ => pass`
matches bind a payload, for example `match value` / `.Text(path)` in
`tsoptions/parsinghelpers.rig:108`, or `.Table(m)` at `:152`. The `trim`
case binds `rendered`. In Ruby the binding one-liner is the reason
people use the feature: `if config in {db: {user:}}`. A bare tag test is
just `==` with a nicer list.

The places a binding can appear stay as round 2 set them:

- `x matches P` that binds names is allowed only in an `if`/`while`
  condition, and its names live in that block. This avoids Ruby's leak,
  where a failed `in` still binds into the enclosing scope.
- With no bound names it is a Bool anywhere: in closures, assignments,
  arguments, and function bodies.
- An alternative list binds nothing (Ruby's rule 5).
- `as` keeps naming an optional (`if o as x`, 2,081 uses in Trig).

## The one spelling to ship, shown four ways

```rig
# if, binding a value
if <entry.state matches .ready(rendered?)
  !@retired.push(<rendered.image)

# filter, three alternatives: parentheses inside the call
live = entries.filter(|e| (e.value.state matches .ready, .start, .frozen))

# while
while @token matches .CommaToken, .SemicolonToken
  @next_token()

# assignment (Trig, estransforms_taggedtemplate.rig:139, from an `==` chain)
is_last = kind matches .NoSubstitutionTemplateLiteral, .TemplateTail
```

A Bool `match` collapses in the same way (Trig, `checker/expressions.rig:198`):

```rig
fun can_have_statements(tree: ?ast.Ast, n: ast.Node) -> Bool
  tree.kind(n) matches .SourceFile, .Block, .ModuleBlock, .CaseClause, .DefaultClause
```

## What runs today

At 122d523bf (`p1.rig`, under `RIG_SANITIZE=1`), both of today's
closure forms run and print `2 2`: the `or` chain
`|s| s == .ready or s == .start or s == .frozen`, and a block closure
that holds `match s` / `.ready, .start, .frozen => true` / `_ => false`.
`|s| s matches .ready, .start, .frozen` gives a parse error, "unexpected
name `matches`" (`p2.rig`), as expected before the grammar change.
