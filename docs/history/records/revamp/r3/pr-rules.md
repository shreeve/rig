## Summary
Five owner-approved v0.3.0 rules.

| Change | Old | New |
|---|---|---|
| Lasting borrows are written | `r = head(v)`, `xs = b.all()` | `r = head(?v)`, `xs = ?b.all()`; `print(head(v).len)` stays implicit |
| `print`/`Text` read implicitly | slices needed `?` | `print(w[1..3])`, `Text(t[1..])` |
| A no-value closure's last line is a statement | `<x` rejected there | `<x` drops; a value there "does nothing" |
| No space before a call's or index's bracket | `f (x)`, `xs [0)` accepted | rejected: write `f(x)` |
| `_ =` discards | `_ = (!v).pop()` required | `_ = !v.pop()` |

## Deciders
1. **Lasting lend** (`Checker.keptLends`, typecheck): after a binding, assignment, return, function's or closure's last value is checked without error, its leaves (`yieldedLeaves`) holding a view are walked through members, indexes and calls: a call whose result carries an argument or receiver (`CallParams.resultCarries`, `resultCarriesReceiver`; constructors carry all) that was lent implicitly (`Lend.implicit` on a place; an unsigiled owner receiver) is reported with the call to write. Reported once per call.
2. **print/Text**: `checkFormatArgs` makes each argument a view argument, so a slice is lent as `?xs[a..b]` (`recordImplicitLend`); the ownership checker walks it as that lend (`walkImplicitLend`), so `print(v[..], (!v).pop())` is rejected.
3. **Closure**: `checkLambdaGiven` calls `Parser.dropTail` on the body when the expected type returns nothing; the tail `(move e)` becomes `(drop ...)` before any pass reads it.
4. **Spacing**: lexer `call_bracket` layout (after a value, whitespace before `(`/`[` on the same line).
5. **`_ =`**: `checkSet` sets `discarded` to the value, so `isDiscardedCall` (via `usesValue`) sees it.

## Fallout
`.git/revamp/r3/rules/rewrite.py scan|apply` (diagnostic-driven, re-runnable, run until 0 files) rewrote 231 files/blocks: about 70 programs gained a `?`, `whitespace_insensitive` and two SYNTAX examples lost their spaces before brackets, `_ = (!x).m()` and print/Text `?slice` were made short. Tests changed by hand: `receiver_sigil_*_used` (the `_ =` cases are valid), `drop_closure_last_line` became behavior `closure_no_value_tail` plus reject `untyped_closure_last_line`, two oracle rejection entries each added for 3 programs. New tests: `spaced_call_bracket`, `lasting_lend_written`, `closure_no_value_expression`, `print_slice_loan`, behavior `lasting_lend_forms`, `discard_write_call`.

## Gates (head see push)
Suite 3139+ passed, 0 failed; corpus 9725/9725; matrix 6418 programs, 0 failed; oracle, doc, vocab pass; unit passes; parser check passes (merged f355d95a, Nexus 2.2.0).
**equiv against e45cb494:** 12266 programs, 48 differ, all in `check`/`check --facts` (rewritten programs' positions and uses, new rejections); none in `storage`, `sema`, `emit` or `pkg`.

## Decisions to confirm
1. **CORE sentence 4** text changed: a read lend is also written when a call's result keeps it and is stored (binding, field, return); `print`/`Text` read their arguments implicitly. Rules 3-5 are not stated in CORE.
2. **A return counts**: `fun f(b: ?B) -> []Int: head(?b.items[..])` needs the `?` though the loan roots in a view parameter.
3. **Stores are covered** (owner follow-up): an argument of a call whose origins say it may store it (`CallParams.stores`), a constructor's field and an array literal element, go through the same `keptLends`: `!xs.push(head(v))` needs `head(?v)` ("keeps `v` lent in what `push` stores"). The tree needed no rewrite.
4. The print-slice `?` removal was applied outside reject tests; `print(?w[1..3])` remains valid.
5. A closure's tail drop rewrites the tree after parsing (`Parser.dropTail`, one typed rewrite).

## Migration (v0.3.0 release notes)
| Old | New | Compiler says |
|---|---|---|
| `r = head(v)` | `r = head(?v)` | `head(v)` keeps `v` lent while `r` lives; write `head(?v)` |
| `xs = b.all()` | `xs = ?b.all()` | same |
| `return head(b.items[..])` | `return head(?b.items[..])` | keeps ... lent in the value it returns |
| `!xs.push(head(v))` | `!xs.push(head(?v))` | `head(v)` keeps `v` lent in what `push` stores; write `head(?v)` |
| `f (x)`, `xs [0]` | `f(x)`, `xs[0]` | write `f(x)` |
| `_ = (!v).pop()` | `_ = !v.pop()` (both valid) | (accepted) |
| `each(\|i\| _ = <q)` in a no-value closure | `<q` | (accepted) |
