E = []
E.append((r'''| Form | Meaning |
|---|---|
| `x = e` | bind a new local `x`, or assign to the visible `x` (through it, when `x` is a write borrow) |
| `x: T = e` | bind with a type annotation |
| `x =! e`, `x: T =! e` | bind a fixed local, which cannot be reassigned |
| `new x = e` | bind a new `x` that shadows the visible one; `e` may read the old `x` |
| `x = <y` | move `y` into `x` (there is no `<-` operator) |
| `x += e` (`-=` `*=` `/=` `%=` `+%=` `-%=` `*%=` `<<=` `>>=` `&=` `\|=` `^=`) | compound assignment: `x = x op e`, with `x` evaluated once |
| `p.f = e`, `xs[i] = e` | assign a field or an element |
| `_ = e` | evaluate `e` and discard it; an owning value is dropped at once |

A compound assignment keeps its target's type:''', r'''The forms are in [SYNTAX §9](SYNTAX.md#9-bindings-and-assignment).
`x = e` binds a new local `x` when no `x` is visible, and otherwise
assigns the visible one: through it, when `x` holds a write borrow
([§8](#write-borrows)). `x =! e` binds a fixed local, which cannot be
reassigned. `_ = e` evaluates `e` and discards it, and an owning value
discarded so is dropped at once. A binding's type comes from its
annotation or its value.

A compound assignment `x op= e` is `x = x op e`, with `x` evaluated
once, and keeps its target's type:'''))
E.append((r'''A binding's type comes from its annotation or its value. Rig has no
`var`, `let`, or `const`: the compiler emits a Zig `const` unless the
binding is reassigned or written through.

There is no implicit shadowing.''', r'''There is no implicit shadowing.'''))
