# Panel round 2: the one-armed match, the Swift view

Panelist: Swift. Checked against the worktree at `122d523bf` with
`bin/rig parse` and `bin/rig run` (`RIG_SANITIZE=1`, `RIG_OUT_DIR` a temp
dir). Probes are in the session scratchpad, `p2/`.

## What Swift learned

Swift has every form the brief asks about, and its users have opinions
about each:

```swift
if case .ready(let r?) = entry.state { retired.append(r.image) }   // one arm
guard case .ready(let r?) = entry.state else { return }            // one arm, early exit
switch entry.state {                                               // full, exhaustive
case let .ready(r?): retired.append(r.image)
default: break
}
if let r = maybe { ... }        // optional binding; `if let r` since 5.7 (SE-0345)
```

1. **`if case` reuses the switch's word, and is still Swift's most
   disliked syntax.** Reusing `case` did not make it read as "the same
   idea as `switch`". What hurts is the order and the `=`: the pattern
   comes first, the subject last, and `=` reads as assignment. People
   read `if case .ready(let r?) = state` right to left, and many write a
   `switch` with `default: break` rather than remember it. The lesson for
   Rig: the word matters less than **subject first, then the arm's
   pattern verbatim**.
2. **Two places for `let`** (`case let .ready(r?)` and `case .ready(let
   r?)`) is a choice nobody wanted. Swift needs `let` because a bare name
   in a Swift pattern is an *expression* (matched with `~=`). Rig's
   patterns bind a name by default, so they need no `let`: keep that.
3. **The `x?` pattern is the best-loved part.** `.ready(let r?)` tests
   the variant and the optional in one pattern, with one name. Without
   it Swift code nests `if case` and `if let`, or invents a throwaway
   name, which is exactly what Rig's `.ready(r) and <r as rendered` does.
4. **A pattern test is not an expression.** Swift still has no `x is
   case .ready`; it has been pitched on the forums more than once and not
   accepted as of Swift 6. Users write `if case ... { true } else { false
   }` or an `isReady` property per variant. (Round 1: the same gap is
   Rig's `filter(|e| e.value.state as .ready)`.)
5. **No alternatives in `if case`.** The comma in an `if` condition means
   *and*, so `if case .a, .b = x` is not allowed; one-arm tests of several
   variants need a `switch`. Rig's `as` has the same hole for a different
   reason: after `as`, a comma lists several results (SPEC "`as` with a
   pattern": "a comma after it does not list alternatives").
6. **The optional unwrap won by frequency.** `if case let x? = o` is
   legal and nobody writes it; `if let x = o`, then `if let x`, got the
   short form because it is used far more than enum tests.
7. **Ownership goes on the subject.** For noncopyable enums, Swift 6
   (SE-0432) made a `switch` borrow its subject by default and consume it
   when written `switch consume x`; the bindings take the subject's mode.
   No per-binding `consume`, `borrowing`, or (Rust's) `ref` is needed.
   This is already Rig's `match <e` rule.

## Rig data, measured

| Count (Trig `src/`, Rig `std/` and `examples/`) | |
|---|---|
| `match` statements in Trig | 834 |
| of them, one real arm plus `_ => pass` | 74 |
| of those 74, the arm lists alternatives (`.A, .B, ... =>`) | 41 |
| of those 74, the arm binds a payload | 24 |
| `x as .variant` pattern tests in Trig, std, examples | **0** |
| `if/while o as x` optional bindings in Trig | 2,149 |
| `x as .variant` in test/rig and the docs | 36 + a few docs (SPEC, SYNTAX, WELCOME, docs/design/as-patterns.md) |

Trig's authors are AIs writing Rig, the audience the owner cares about.
They never reached for the pattern-`as`; they wrote a full `match` with
`_ => pass` every time, which is Swift's `default: break` habit
exactly. The optional `as`, by contrast, is Trig's workhorse. More than
half the one-arm matches test several variants, which `as` cannot.

## 1. The ideal one-arm spelling

```rig pending
if <entry.state is .ready(rendered?)
  !@retired.push(<rendered.image)
```

Read aloud: "if the entry's state, moved, is ready with a rendered
result, push the rendered image, moved." It is the full match with
`match` deleted and `is` put between the subject and the arm:

```rig pending
match <entry.state
  .ready(rendered?) => !@retired.push(<rendered.image)
  _ => pass
```

Same subject, same sigil, same pattern text, so the one-arm form reads
as the same idea; that is what Swift's `if case` failed to do by putting
the pattern first.

**Must it say `match`?** No. Swift reused its arm word (`case`) and it
did not help; Trig never uses today's form although its pattern is
already a `match` arm's. A form with `match` in it puts two block words
on one line with nothing between subject and pattern (`if match
<entry.state .ready(rendered?)`) or gives `match` a second, Boolean
meaning. `is` says what the test asks in a word everyone knows. In Rig
it is free: Rig has no type test, so `is` has no other job, and C#
(`o is Ready r`) and Kotlin (`x is T` with a smart cast) already use it
for "test the shape, and bind".

Alternatives considered: `matches` (Rust's macro name, seven letters,
reads well but is longer than the idea), keeping `as` (zero uses in
Trig; reads as a cast in Swift, Rust, TypeScript, and C#).

Status today: `is` does not parse ("unexpected name `is`"), and
`.ready(rendered?)` does not parse ("unexpected `?`; expected `,` or
`)`").

## 2. Swiss's narration as Rig

"If the entry we just removed was ready and holds a rendered result,
move that result's image onto the retired list."

```rig pending
entry = !@entries.take(key) ?? break
@bytes -= entry.bytes
if <entry.state is .ready(rendered?)
  !@retired.push(<rendered.image)
```

Each clause of the sentence has one token: "the entry we just removed"
is `entry` after `take`; "was ready" is `is .ready`; "holds a rendered
result" is `(rendered?)`; "move that result's image" is
`<rendered.image`; "onto the retired list" is `!@retired.push`. The
positional binding is named for the field, so no throwaway name is
needed. (`.ready(rendered: r?)` also works for another name.)

Today's closest, which runs sanitizer-clean (probes `b`, `g`):

```rig
if <entry.state as .ready(r) and <r as rendered
  !@retired.push(<rendered.image)
```

It needs the throwaway `r`: reusing the field name is rejected
("optional binding `rendered` shadows the local `rendered`", probe `f`).
Two `<`, two `as` that mean different things (a variant test, then an
unwrap), and a name that exists for one word. This is the line the owner
did not understand, and I think the two meanings of `as` side by side
are most of why.

## 3. Nested patterns: yes, worth adding

This exact code is the case for them: the one-arm form drops from two
tests, two names, two `<`, and two `as` to one of each, and the full
`match` loses its nested `if`. Swift's experience is that `x?` inside a
pattern is the part people keep.

The grammar change, one line (today's `patom` slot takes only a name):

```text
patom = ... | "." name ["(" [(pattern | name ":" pattern), ...] ")"] | patom "?" | "none"
```

- A payload slot holds a pattern (one rule, so `.ready(_)`,
  `.code(200..300)`, `.wrap(.leaf(x))` all follow), never alternatives,
  which stay at the arm's top level.
- `p?` matches an optional that has a value, and the value matches `p`.
  It means what postfix `?` already means on a value: `x?` is "the value
  inside, or leave the function"; in a pattern `x?` is "the value
  inside, or no match". Same mark, same idea.
- `none` matches the absent optional, so `.ready(rendered?)`,
  `.ready(none)`, `.loading` is exhaustive. Today `none` is rejected as a
  pattern ("`none` is the absent optional and cannot be used as a name")
  and `match` on an optional is rejected ("cannot `match` on a value of
  type `Rendered?`", probe `e`).
- One spelling per idea: a top-level `if o is x?` is rejected toward
  `if o as x`, as Swift's `if case let x? = o` lost to `if let x = o`.
  `p?` is for slots and `match` arms.

The risk Swift users report: `rendered?` can be misread as "rendered,
which may be absent" (the type `Rendered?`). `none` as the sibling
pattern makes the meaning plain, and the diagnostic for a top-level
`x?` teaches it.

Zero cost: the pattern lowers to the tag compare, then the null check,
that today's nested `if`s make; storage and ownership see the same
bindings.

## 4. Where the moves go

One `<` on the subject, and `<` wherever a value then changes hands:

```rig pending
if <entry.state is .ready(rendered?)
  !@retired.push(<rendered.image)
```

- The subject's sigil decides every binding, as `match <e` does today
  and as Swift's `switch consume x` does: `<` owns them, none views them,
  `!` gives write views. No sigil inside a pattern (no `.ready(<r)`):
  Swift's two places for `let` and Rust's `ref`/`ref mut` are the
  per-binding choices to avoid.
- The second `<` stays: taking `image` out of `rendered` is its own
  transfer. Without it the checker says "`rendered.image` owns an
  `Image`... write `+rendered.image` to pass a clone" (probe `m`), which
  is right.
- Without `<` on the subject, the bindings are views and the image
  must be cloned, `+rendered.image`, as today (probe `i`).
- What the pattern leaves out, and a value that does not match, drop as
  SPEC already says for `<s as ...`: `.ready(none)` and `.loading` drop
  as the test fails.

Two marks, each where ownership moves, is visible without noise: the
subject's `<` says "this test consumes the state", the push's `<` says
"the image goes into the list".

## 5. What `as` becomes

**Keep `as` for naming; move pattern tests to `is`.** One word per idea:

- `as` names the value inside: `if o as x`, `while q.pop() as x`,
  `if f() as a, b`, and `use m as n`. Its meaning ("call it this") is
  the one Python's `with ... as` and `except E as e` taught; Trig uses it
  2,149 times.
- `is` tests a pattern and binds what the pattern names: `if s is
  .circle(r) and r > 10`, `while e is .item(x)`. With no names bound it
  is a `Bool` anywhere (`.filter(|e| e.value.state is .ready)`), which
  closes round 1's gap and Swift's missing `is case`.
- `is` takes alternatives (`if kind is .VariableStatement,
  .IfStatement`), which `as` cannot because its comma lists several
  results: 41 of Trig's 74 one-arm matches need this. A comma after `is`
  parses as a comma after `as` does today: alternatives in a condition,
  an argument separator inside a call's parentheses (`f(x as a, b)`
  parses as `(as x a), b`; checked with `rig parse`).
- Remove the pattern form of `as`. Migration: 36 lines in test/rig, the
  docs above, nothing in std, examples, or Trig. Reserving `is` renames
  one Trig local (`is = tree.index_signature_declaration(node)`,
  src/printer/printer.rig:1664); Trig gets the one-line note and script.

`guard case`: not needed. Swift uses it far less than `guard let`, and
Rig's `?? break` / `?? return` already covers the optional exit; a
binding-free `is` gives `if not (s is .ready)` for the rest.

## Probes

| Probe | Result |
|---|---|
| a: full `match <entry.state` with nested `if <r as rendered` | runs, `1 a`, sanitizer-clean |
| b: `if <entry.state as .ready(r) and <r as rendered`, `push(<rendered.image)` | runs, `1 a` |
| g: same with `.ready(rendered: r)` | runs |
| o: two nested `if`s | runs |
| c: `if <entry.state is .ready(rendered?)` | does not parse: "unexpected name `is`" |
| d: arm `.ready(rendered?) =>` | does not parse: "unexpected `?`; expected `,` or `)`" |
| e: `match <r` on `Rendered?` with `none =>` | rejected: `none` not a name; `match` on an optional rejected |
| f: `.ready(rendered) and <rendered as rendered` | rejected: shadows `rendered` |
| h, j: `<(<r ?? return).image` | rejected: moving a part out of a temporary |
| i: no `<` on the subject, `push(<rendered.image)` | rejected: `rendered` is a view |
| m: owned binding, `push(rendered.image)` | rejected: write `+` to clone |
| n: `b = s as .ready` | rejected: `as` only in an `if`/`while` condition |
| k: `f(x as a, b)` | parses as `(call f (as x a) b)` |
