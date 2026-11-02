# `return if` with a block: implementation, diagnostic, real code

Reviewer lens: implementation, diagnostic, impact. Rig at main 01b85979f; pre-#871 Rig is the cached baseline 6750e8fe8 (#871's first parent).

## What the pre-#871 error was (run, not guessed)

`$OLD run a.rig` on the `sign` snippet:

    a.rig:3:5: error: unexpected indentation; expected end of input, the end of the line or the end of the block

It came from `Parser.diagnostic`'s `.indent => "unexpected indentation"` arm (src/rig.zig:2728) plus the expected-token hint. `return if x > 1` alone has always been a guard and still is, in both builds.

## A regression #871 brought in

`blockFollows` counts a deeper `.` continuation line as a block, so a guard whose condition goes on to a deeper line now becomes a block `if`:

    sub f(xs: ?List[Int])
      return if xs
        .len > 1

Old: a guard (accepted). New: "type mismatch: expected `Bool`" plus "`.len` is an enum variant". The undo fixes it; it should get a case. It also gives worse errors when an indent is a mistake (`return if x > 1` + deeper `print(..)` now says "type mismatch … `if` used as a value requires an `else` branch").

## Where the diagnostic goes

Not in the lexer. Undo returns `classifyKeyword` to one fact (after a jump, `if` is a guard) and deletes `blockFollows`. That is about 40 lines of lookahead run on every `return if`/`break if`, with no new lexer state. The parse already fails at the `.indent`, so make the `.indent` arm `self.guardBlock(tok) orelse "unexpected indentation"`. The helper, about 15 lines in the style of `afterAsPattern`/`bareResults` (source scan, runs only on failure), checks whether the previous content line starts with `return|break|continue|pass` (plus an optional `$label`) then `if`, and reports at that `if`:

- `` `return if c` is a guard and takes no block; write `return` in each branch, or leave it out where the `if` is the function's last expression ``
- `` `break if c` is a guard and takes no block; write `break` in each branch ``
- `continue`/`pass`: `` `continue if c` is a guard and takes no block; write `if c` with `continue` at the end of its block ``

## Counts (`tools/count.py` in /private/tmp/claude-501/retif; regex over `.rig`/`.rig.test`)

| | jump guards `return/break if c` | with a deeper block | `return x if c` | funs | needless single-value tail `return x` |
|---|---|---|---|---|---|
| Trig | 164 (99 return, 65 break) | **0** | 1,810 | 8,604 | **2** (+53 `return a, b`, 2 errors) |
| loc | 10 | 0 | 89 | 116 | 1 (+3 results) |
| std | 43 | 0 | 151 | 304 | ~2 (+5 results, 2 errors) |
| examples | 0 | 0 | 0 | 23 | 0 |
| tests | 95 | 5 (all #871's own case) | 2,706 | 14,816 | 88 (+66 results, 88 errors) |

`return match` with a block: Trig 0, tests 9. Dot-continued guards: 0 anywhere.

A tail `a, b` and a tail error value are *rejected* today ("results are written `return x, true`"; "an error value meets `Int!Bad` only as the operand of `return`"). So a rule against a needless tail `return` would need two exemptions, which is irregular, for about 2 lines in Trig. (4) is right.

## Size of the undo

- src/rig.zig: about −48 (field `after_break_label`, its assignment, two `classifyKeyword` lines, `blockFollows`), about +18 (helper and arm). Lexer unit cases at about 5074–5078: the `return if c\n  a\nelse…`, blank/comment, `break`, and `break $a` lines expect `.post_if` (or go). Keep `return if c\nb` and `continue if c\n  a`.
- test/rig/syntax-misc.rig.test "return if block" (77 lines): replace with `fail` cases for return, break and `break $a`, each with the message; a test that a dot-continued guard is a guard; and the positive cases rewritten as tail `if` (no `return`). Keep "return if guard".
- SYNTAX "Guards": replace #871's 28 lines with one sentence, and a ```` rig reject ```` + ```` error ```` example, or the tail-`if` form. SPEC: in Block expressions, drop the sentence #871 added; in Guards, add "a guard ends its statement; nothing deeper follows it". CHANGELOG: delete #871's bullet (Unreleased, never shipped); add the diagnostic.
- test/matrix.py: one line in `program()`'s list branch: `block = "E" if returns and form[0].startswith("if ") else ctx["block"]`. The `*.return.if_as` and `tail_{if,nested}_result_*.call` cells then put the `if` as the function's tail. Without it they are rejected again. The new message does not match `MALFORMED`, so they would silently count as "rejected by a rule": a trap. Cell names do not change, so the 15 `test/oracle/rejections` lines #871 added should stay; a matrix run confirms it. `KNOWN_MALFORMED` is not restored.
- Gates: compiler change, so Trig and loco light gates and json/hash guards. Trig and loc have no uses, so expect no change.
