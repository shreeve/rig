E = []
E.append((r'''From lowest to highest precedence:

| Operators | Notes |
|---|---|
| `a if c else b`, `e catch f` | ternary and error fallback; right-nested (`e catch return v` and `a ?? return v` take a jump at this level) |
| `or` | Bool; short-circuit |
| `and` | Bool; short-circuit |
| `not` | Bool |
| `==` `!=` `<` `>` `<=` `>=` | not chainable |
| `??` | optional fallback; right-associative |
| `..` | half-open range: a `for` source, a match pattern, or a slice's index, where a side may be open ([§3](#slices)) |
| `\|` | bitwise or |
| `^` | bitwise xor |
| `&` | bitwise and |
| `<<` `>>` | shifts |
| `+` `-` `+%` `-%` | |
| `*` `/` `%` `*%` | |
| `-x` and the ownership sigils | prefix |
| `f(x)` `a[i]` `a.b` `e!` | postfix: call, index, member, propagate |

Postfixes bind tighter than prefixes, so `-a.len` is `-(a.len)` and
`+n.first()` clones the result. The one exception is a receiver sigil:
`?`, `!`, or `<` before a place followed by a method call applies to
the place, `!v.push(x)` is `(!v).push(x)` and `!v.put[2](x)` is
`(!v).put[2](x)` ([§4](#structs)). A call of a field holding functions
(`!p.f()`, `!p.fs[0]()`) has no receiver, so a sigil there is rejected.
''', r'''The operators and their precedence are in
[SYNTAX §6](SYNTAX.md#6-operators-and-precedence). A receiver sigil
applies to a method's receiver ([§4](#structs)); a call of a field
holding functions (`!p.f()`, `!p.fs[0]()`) has no receiver, so a sigil
there is rejected.
'''))
E.append((r'''sub main
  a = Point(x: 1, y: 2)
  b = Point(x: 1, y: 2)
  s: Shape = .dot(at: a)
  found: Point? = none
  print(a == b, s == .dot(at: Point(x: 2, y: 1)), found == none, [a] == [b])
  print("abc" < "abd", "ab" < "abc", "b" <= "a")
```

```output
true false true true
true true false
```''', r'''sub main
  a = Point(x: 1, y: 2)
  b = Point(x: 1, y: 2)
  s: Shape = .dot(at: a)
  found: Point? = none
  maybe: Point? = b
  print(a == b, s == .dot(at: Point(x: 2, y: 1)), found == none, [a] == [b], a == maybe)
  print("abc" < "abd", "ab" < "abc", "b" <= "a", "Zoo" < "apple")
```

```output
true false true true true
true true false true
```'''))
E.append((r'''`and`, `or`, and `not` take `Bool`s; `not` binds looser than comparisons,
so `not a == b` is `not (a == b)`. The spellings `&&` and `||` are
rejected with a hint.''', r'''`and`, `or`, and `not` take `Bool`s, and `and` and `or` short-circuit:
the right side runs only when the left does not decide. The spellings
`&&` and `||` are rejected with a hint.'''))
