# Rig syntax: ideas from Trig, deferred

On 2026-10-11 the owner decided to change nothing in Rig's syntax for
now: today's forms are coherent, and every idea below is additive, so it
can be adopted later without breaking code. Revisit with experience from
writing Trig.

## Principle discussed

"One way to mean, a few ways to say": each meaning has one IR node and
each effect one marking; a meaning may have at most two phrasings, each
unambiguous and familiar; a form whose reading differs from its meaning
is an error naming the right form. A formatter can impose a house style.

## Ideas, all additive

- `if c then x` and `if c then a else b`, the block folded onto one line
  (same node as the block `if`).
- `unless c` as `if not c` (same node).
- `when` for match guards (`k when k < 0 =>`); `when` is reserved and unused.
- `match` on strings and literals (Trig NEEDS.md 4).
- Errors that carry data (Rig IDEAS 1.4).
- One-byte literals as `U8` (`c == '{'`), `list.last() -> T?`,
  `x in "{["` for literal lists.
- `x ??= e`, multi-line string literals, tuple returns.
- Symbols bind tight, words bind loose (`&&`/`||`/`??` against a loose
  `or`/`catch`); would change what `and`/`or` mean.

## Rejected by the panel (traps)

Assignment inside a condition (`(n = x) > y`; `if v as x` is the safe
form), `then`/`else` as low-precedence `&&`/`||`, `cond and action`
(works only when the action returns `Bool`), dropping call parentheses.

## Files

- [RIG-SYNTAX-OPTIONS.md](RIG-SYNTAX-OPTIONS.md): the full discussion: panel, designs, principles, the function.
- [RUBY-IDIOMS.md](RUBY-IDIOMS.md): the owner's Ruby written in Rig.
