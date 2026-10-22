# Review of PR #102 (rules), c60184c3 - reviewer 1

About 110 probes, in scratchpad/p. Every accepted probe was run under RIG_SANITIZE=1 in debug and in `build --release`.

Verdict: no Critical, no soundness finding. One completeness gap (Minor).

## Rule 2 (print/Text implicit slices): sound
Rejected as expected: write in a later argument, a nested call, a closure call (`f()` with `|!v|`), a method `(!w).go()`, `print(?v[..], bump(!v))`. A closure `|?v|` that is live blocks a later `!v.push` (reads as a held loan). `defer print(v[..])` evaluates at scope exit and prints the final contents. `Text(v[..], "x")` copies, so a later push is fine.

## Rule 3 (dropTail): sound
- Last-line `<x` in `if`/`else` arms and `match` arms drops once: the checker and the emitted drop agree (outputs show one drop per object).
- Called twice (`twice(...)`, typed `f: sub(Int)`), generic `sub gen[T]`, `*||` owned closures (in a struct field and in a Vec): one drop per call, no leak.
- Nested closures work, as do `defer` in the closure and early `return`.
- `<` of a capture stays rejected: `<q`, `|<q|`, `*|<q|`, and the `|!q|` view capture.
- Double drop (`<q` twice) is rejected. An untyped closure's last line is still a value (a6).
- Value-statement forms (`q`, `-q`, `F(n: i)`) are rejected as "does nothing".

## Rule 1 (keptLends): complete except one hole
Rejected correctly: `??`/`catch` in a binding, a method-stored `put(head(v))`, `push`, array literal, a ternary, a typed binding, parentheses, and a captured-`+r` closure.

**Minor gap.** A lend kept through `??` or `catch` stays implicit when it goes into a constructor field or an array element (the same expression is rejected in a binding).
- `Holder(seen: headm(v) ?? ?v[..])` is accepted (e12).
- `Holder(seen: headf(v) catch ?v[..])` is accepted (f2).
- `[headm(v) ?? ?v[..]]` is accepted (f5).
- It is still memory-safe, because the loan stays live and a later `!v.push` is rejected (f1).
- The `push` form with `??` is caught (f3).
- Likely cause: `keptLends` does not look through `??`/`catch` when the sink is a constructor field or array element.

**Inconsistency, minor.** `f = |?v| head(v)` and `fun g(v: ?Vec[Int]) -> ([]Int)?: headm(v)` are accepted without `?`. Passing a view-typed name is not a place lend, so this fits the rule's text, but a closure's last value is described as checked. `Cell[[]Int]` is not allowed by the language, so the `!c.set(head(v))` route is moot.

## Rule 4: no regressions found
Accepted: a call's arguments across lines, `xs` followed by `[1]` on the next line (same as base), `(x)`, `[..]` after `=`, `=>`, `in`, `??`, `else`, `not`, a ternary. Rejected: `print (n)`, `g (3)`, `Vec [Int]`, `(x) [0]`, `a! (1)`. `x +` followed by an indented operand fails on base too.

## Rule 5
`_ = !v.pop()` and `_ = (!v).pop()` both accepted; `x = !v.pop()` is still rejected.
