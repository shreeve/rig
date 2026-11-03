# `matches`: the owner's design (2026-11-02)

The owner chose it after three panel rounds (Rust, Ruby, Swift):

| Form | Example |
|---|---|
| one pattern (binds names only in if/while conditions) | `x matches .ready(r)` |
| one pattern, optional inside | `x matches .ready(rendered?)` |
| several alternatives | `x matches (.a, .b, .c)`; they may bind only if every one binds the same names with the same types: `x matches (.failed(c), .timed_out(c))` |
| full match, unchanged | `match x` / `.a, .b => ...` / `_ => pass` |

- `x matches P` is a Bool anywhere; one-arm form `if <entry.state matches .ready(rendered?)`.
- Alternatives: a parenthesized comma list after `matches` (space before the paren). Rig has no
  tuples, so it can't be read as one; it needs no special rule inside a call:
  `.filter(|e| e.value.state matches (.ready, .start, .frozen))`.
- No `|` in patterns. No nested alternatives (`.ready((.done, .cached))`): write
  `x matches .ready(s) and s matches (.done, .cached)`. Binding alternatives are allowed when every alternative binds the same names with the same
  types (owner, 2026-11-02, after `x matches (.failed(c), .timed_out(c))`); otherwise rejected
  naming the name or type that differs. The same holds in match arms: `.failed(c), .timed_out(c) => report(c)`. Each is rejected with the plain form in its message.
- Patterns gain `name?` (the optional's value, or no match) and `none`.
- `as` keeps naming only (`if o as x`); `x as .p` is rejected with "write `x matches .p`".
- One `<` on the subject sets every binding's mode; the owned-value diagnostic offers `<` before `+`.
- Negation follows the comparison rule: `not (x matches (.a, .b))`.
- Nothing existing changes except `x as .pattern` (about 36-87 lines of Rig tests and docs; 0 in Trig).

Build order: this pattern row first, then the approved fused iterator chains with `min_by(key)`,
`max_by(key)`.

## Edge rules from the panel's last check (all agreed)
1. `x matches .a, .b` (no parens): rejected outside brackets with "put alternatives in parentheses:
   `matches (.a, .b)`"; inside a call, a `matches` operand followed by `, .name` gets the same note.
2. A one-item list `(.a)` / `(.ready(r))`: rejected, "write `x matches .a`". Trailing comma allowed
   in a list of two or more; newlines inside the parens join (docs + a test).
3. `_` or a bare name, alone or in a list (`matches _`, `matches x`, `(.a, _)`, `(.a, n)`): rejected.
4. `matches(` with no space: rejected, "write `matches (`" (never lexed as a call).
5. `(.a, .b) =>` pasted into a match arm: rejected, "write `.a, .b =>`".
6. After `matches` the parser reads patterns, so the grammar's rejected-tuple form never fires there.
7. Names bound by `matches` flow right through `and` in any expression, so
   `x matches .ready(s) and s matches (.done, .cached)` works in a closure too (Trig has 9 such
   tests); elsewhere bindings are allowed only in if/while conditions.
8. A name bound in a Bool position and never used (`ok = x matches .a(r)`): rejected, "write `.a(_)`".
9. `not x matches (...)` means `not (x matches (...))`, as `not s == .ready` does; docs say so.
