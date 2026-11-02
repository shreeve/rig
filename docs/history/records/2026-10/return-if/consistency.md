# `return if`: consistency and least surprise

Rig at main (01b85979f). Probes in /private/tmp/claude-501/retif/.

## Survey: where `if` ends a statement

- Guards on simple statements (call, binding, assignment, drop, `return`, `break`, `continue`, `pass`): SPEC "Guards", SYNTAX "Guards". All one line.
- `x if c else y`: the ternary, one line.
- Arm guards `p if c =>`: one line; after `as`, none ("join with `and`").
- Only after `return`, `break`, and `break $label` does the lexer look at the next line (`blockFollows`). `continue if c` never does.

## Probes (main)

| Probe | Result |
|---|---|
| `return match x` with arms below | works |
| `return while …` / `break 5` / `else 0` | works |
| `return if x>0` / `"positive"`, no `else` | `if` used as a value requires an `else` |
| sub: `return if x<0` / `print("neg")` (a guard with a body, as a Ruby or Python writer means it) | two errors: needs an `else`; a `sub` returns no value |
| `continue if c` / deeper line | "unexpected indentation" |
| `x = 3 if c` / deeper; `return y if c` / deeper | "unexpected indentation" |
| `return (if c` / block `)` | parse error |
| `return if o as v` / `v` / `else` / `0` | works |
| fun `-> Int`: `return if x>0` / `2` at the same depth | guard; "`return` needs a value" |
| `y = for …` / `break if x>1` / `x*10` / `else` / `x` | prints 1: the `break` is unconditional |

The last probe and #871's own test `first_big` (`return if x < 0` / `-1` / `else` / `n += x; continue`) show the hazard. Whether `return` or `break` happens at all depends on the next line's indentation. `break if c` can mean "break only when c" or "always break, and maybe continue instead". No other Rig token changes meaning by the next line's indentation.

## Is `if` the odd one out?

No. `match` and `while` have no postfix meaning, so `return match` reads one way. `if` is the one block word that also ends statements. The simple rule is about the word: after a jump word, `if` is a guard, and a guard is one line. `return match` keeps working because nothing competes with it. The asymmetry is principled and fits one SPEC sentence.

SPEC "Block expressions" (which predates #871) lists "a `return` value"; it gains: right after a jump word, `if` is a guard.

## Answers

1. **Snippet.** It is rejected with a Rig error. Rig has no warnings. `return if x > 1` alone on its line, with no block below, stays a guard, unchanged. The tail-position form works without `return`, with the same output. Nothing v0.2.9 accepted is newly rejected: #871 is listed under Unreleased, and the only uses on main are its own five test cases and the SYNTAX example.
2. **Best form.** One token, one reading: `return if c`, `break if c`, and `continue if c` are always guards, and a guard opens no block. The diagnostic should cover the whole class, every guard followed by a deeper line, not only `return`/`break`. Today `continue`, assignments, and calls give "unexpected indentation". Message: "a guard `if` ends its statement and takes no block; put the jump in each branch, or bind the `if` (`v = if c` …)", with "drop `return`; the last expression is the value" when the guard is in tail position. Delete `blockFollows`.
3. **One-liners.** Yes, guards are one-liners, as ternaries and arm guards already are. Better: a jump word plus `if` always means a conditional jump, which humans and AIs can decide from the line itself; there is no `break` that continues; the lexer drops a lookahead; mistakes get a fix-it message. Worse: inside a loop, `return` is written in each branch, or a binding comes first. `return match` works but `return if` does not.
4. **Rules.** No rule against a needless trailing `return`. It is legal, explicit, harmless, and rejecting it adds a rule and breaks code. Default 2 is not a new restriction: it replaces a parse error with a clear one.

**Recommendation:** approve defaults 1, 3, and 4, and widen 2 to every guard followed by a deeper line.
