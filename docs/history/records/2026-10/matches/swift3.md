# Panel round 3: `matches`, the Swift view

Panelist: Swift. Trig at `1256d95` (`src/`, 308 `.rig` files, read-only),
Rig worktree at `122d523bf`. Counting scripts and probes are in the session
scratchpad, `p3/` (`count.py`, `chains.py`). Counts are of single logical
lines; a chain split over lines would be missed, and a search for `or`/`and`
at the start of a continuation line found none.

## What Swift learned

```swift
switch kind { case .a, .b: work(); default: break }   // comma alternatives
if case .ready(let r?) = entry.state { use(r) }        // one arm, no alternatives
if [.a, .b].contains(kind) { work() }                  // the popular idiom
if 200..<300 ~= code { ok() }                          // the matching operator
let ok = switch kind { case .a, .b: true; default: false }  // SE-0380, Swift 5.9
```

1. **Comma alternatives work only where something closes the list.** In
   `case .a, .b:` the keyword opens it and the colon ends it, so the comma
   has one owner. Rig's arm (`.a, .b =>`) is the same: line start to `=>`.
2. **Where the comma had another owner, Swift gave up alternatives.** In an
   `if` condition the comma means *and* (`if case .a = x, y > 0`), so
   `if case .a, .b = x` was never allowed, in ten years of the language. The
   workarounds people use instead are the next three items. This is the
   owner's question 1 exactly: inside a call, Rig's comma belongs to the
   call. A `matches` test has no closing token, so a comma after it can never
   tell where the list ends.
3. **`[.a, .b].contains(x)` won because brackets close the list.** It is the
   idiom Swift users reach for, though it reads subject-last, needs
   `Equatable` (no payload variants), and builds an array the optimizer must
   remove. Trig reinvented it: `tree.node_kind_is(container, [.MethodDeclaration, ...])`,
   9 calls, a loop over a slice.
4. **`~=` was not adopted by people.** It is what `switch` calls for an
   expression pattern, and it can be overloaded so libraries extend
   matching (regex literals in `case` use it). In ordinary code almost
   nobody writes `~=`: it reads pattern-first and is a symbol for a word.
   Lessons: a word (`matches`) beats a symbol, and patterns should not be
   user-extensible (a call hidden in a pattern is hidden control flow).
5. **Swift's own trap with alternatives:** in `case .a, .b where c:` the
   `where` applies to `.b` only. Every list form needs a plain rule for
   where the list ends and what a following clause covers.
6. **Binding alternatives** (`case .a(let x), .b(let x):`, same name and
   type in each) exist in Swift and are rare. Rig's "alternatives bind no
   names" costs nothing measurable (Trig cannot have any today); leave it.

## Question 2 first: are alternatives worth having? Yes.

| Trig `src/` | count |
|---|---|
| `x == .A or x == .B ...` on one subject, one line | **272** (about 214 two, 37 three, 10 four, 12 five or more; the two scripts differ by one) |
| of them, the subject is a call evaluated each time (`@kind(node) == .A or @kind(node) == .B`) | 42 |
| `x != .A and x != .B ...` | 44 |
| `match` statements | 834 |
| one real arm plus `_ => pass` | 74 |
| of those, the arm lists alternatives | 43 |
| of those, the arm binds a payload | 24 |
| `match` computing a Bool (`=> true`/`false`, `_ => false`/`true`) | 85 |
| of those, one real arm | 78 |
| of those, with 10 or more alternatives (up to 56) | 26 |
| calls of Trig's `node_kind_is(n, [.A, .B, ...])` | 9 |
| match arm lines that list alternatives today (`.A, .B =>`) | 248 (Rig std/tests/docs: about 166) |

Where the 272 chains sit:

| Context | count |
|---|---|
| `if`/`while` condition | 137 |
| a function's last expression | 47 |
| inside grouping parentheses (`(r.relation == .Subtype or r.relation == .StrictSubtype) and ...`) | 38 |
| assignment | 24 |
| `return` | 21 |
| postfix `if` | 2 |
| **where a comma belongs to something else** (two closures passed to `find_ancestor`, one named argument) | **3** |

So: tests of several variants are the *majority* use of a pattern test in
Trig (272 chains, plus 43 of 74 one-arm matches and 78 Bool matches), far
more than single-variant tests with bindings. Without alternatives
(option f), `matches` would do nothing for most of them that `==` does not
already do, and the 42 call subjects would keep being evaluated twice or
more. The comma clash itself is rare (3 of 272, about 1%), but rare is
where least surprise matters most: a reader meets it cold.

## Question 1: the separator

The problem is not parentheses; it is that the comma is a list separator
and `matches` has no closing token. Each option, in Swift's light:

- **(a) `(x matches .a, .b)`**: in Rig, `(a, b)` is a tuple today
  (`rig parse`: `(e == .ready, e == .start)` is `(tuple ...)`), so this
  needs "inside parentheses a comma after `matches` is not the tuple's":
  a special case, and it looks like a 2-tuple to every Swift, Rust, and
  Python reader.
- **(b) `matches(.a, .b)`**: after a name, `()` is a run-time call; this
  is the one place it would not be. Breaks Rig's bracket rule.
- **(c) `matches (.a, .b)`**: reads as a *tuple pattern* in Swift
  (`case (.a, .b):` matches a pair), Rust and Python. If Rig ever adds
  tuple patterns, it collides outright.
- **(d) `or`**: reads well alone (`matches .a or .b`), but `or` is Rig's
  Boolean operator. `x matches .a or .b and ok` reads to anyone as
  `(x matches .a) or (.b and ok)`, Swift's `where` trap again; and
  `x matches .a or done` needs a parse rule on what follows `or`. Also
  invites `x == .a or .b`, Python's best-known bug.
- **(e) `|`**: one separator that no list owns, so it works in every
  position with no rule about context: `if`, `filter`, call arguments,
  assignments, arms. The list visibly ends at `and`, `or`, `,`, `)`, or the
  line's end. It is what Rust (`A | B =>`, `matches!(x, A | B)`), Python 3.10
  (`case 1 | 2:`), OCaml, F# and Scala write, the languages whose pattern
  tests are expressions; the comma languages (Swift, Kotlin, Go, Java)
  only have it in delimited `case` lists. `|` as bitwise-or does not clash:
  a pattern is not an expression (Rust and Python have the same overlap and
  no complaints). The cost: `|e|` closures put three pipes on a line, as
  Rust's `filter(|e| matches!(e, A | B))` does daily.
- **(f) none**: see question 2.

**Recommendation: (e) `|`, in `matches` and in `match` arms both.** One
mechanism for "any of these patterns" everywhere, with no context rule.
Keeping the comma in arms and `|` in `matches` would be two spellings of
one idea. The migration is mechanical: 248 Trig arm lines and about 166 in
Rig (std, tests, docs), `, ` to ` | ` in an arm's head before `=>`, outside
a payload's parentheses (`.circle(_), .square(_)` becomes
`.circle(_) | .square(_)`). A script, a one-line note to Trig, release
notes. `.ready | .start =>` does not parse today ("unexpected `|`"), so
nothing changes meaning.

Precedence: `matches` sits with `==`; its pattern list binds tighter than
`and`/`or`; `not x matches .a | .b` is `not (x matches .a | .b)`, as
`not s == .ready` already parses as `not (s == .ready)`. That covers the 44
`!=` chains without a `not matches` form.

Fallback if the owner keeps the comma: comma everywhere plus (a), parens
around a test that lists alternatives inside brackets; 3 Trig sites, one
special rule, tuple look-alike. I would not ship (b), (c), or (d).

## Question 3: bindings? Yes, in conditions; tests elsewhere

Swift's experience: the reason `if case` exists is the binding one
(`if case .ready(let r?) = x`); the *test* is what Swift still lacks as an
expression (no `x is case .a`), which is why people write the Bool
`switch` and `contains`. Rig's plan gives both. Trig: 24 of the 74 one-arm
matches bind, and the `trim` example needs it. Keep round 2's rule: a
`matches` binds names only in an `if`/`while` condition; elsewhere it is a
Bool and binds nothing (a binding there is an error that suggests the `if`
form); alternatives bind nothing.

## The one spelling, shown

```rig pending
if <entry.state matches .ready(rendered?)                 # binds, moves
  !@retired.push(<rendered.image)

live = entries.filter(|e| e.value.state matches .ready | .start | .frozen)

while @token matches .CommaToken | .SemicolonToken        # tests
  (!@).next_token()

is_loop = @kind(n) matches .ForStatement | .ForInStatement | .ForOfStatement
```

And from Trig, before and after:

```rig fragment
found = tree.find_ancestor(p, |?tree, a| tree.kind(a) == .ModuleDeclaration or tree.kind(a) == .EnumDeclaration)
found = tree.find_ancestor(p, |?tree, a| tree.kind(a) matches .ModuleDeclaration | .EnumDeclaration)

else if (r.relation == .Subtype or r.relation == .StrictSubtype) and (!@).is_empty_object_type(target)
else if r.relation matches .Subtype | .StrictSubtype and (!@).is_empty_object_type(target)
```

The full match it abbreviates keeps the same pattern text:

```rig pending
match @kind(n)
  .ForStatement | .ForInStatement | .ForOfStatement => true
  _ => false
```

## Probes

| Probe | Result |
|---|---|
| `m = xs.filter(\|e\| (e == .ready, e == .start))` | parses as `(tuple ...)` |
| `b = not s == .ready` | `(not (== s ...))` |
| `k = 1 \| 2` | `(\| 1 2)`, bitwise |
| `f(x as a, b)` (round 2) | `(call f (as x a) b)`: in brackets, the comma is the call's |
| arm `.ready \| .start =>` | "unexpected `\|`" |
| `b = s matches .ready` | "unexpected name `matches`" |
