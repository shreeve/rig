# Front-end audit (revamp, base 5f2bdbc)

Scope, read in full: `src/rig.zig` (2039 lines), `rig.grammar` (886), `src/diag.zig`
(291), `src/modules.zig` (332), `src/main.zig` (465), `build.zig` (87). `src/parser.zig`
(generated) was only consulted for its public API. No tracked file was modified.
Baseline `./test/run` at 5f2bdbc: 1671 passed, 0 failed.

Probes live in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/audit-frontend/`
(`p.sh NAME 'source' [cmd]` writes `NAME.rig` and runs `bin/rig`). Grammar experiments are in
`g/` (run through Nexus 1.0.0, which fails on any undeclared conflict; I checked that it does
by adding a deliberate conflict, `g/bad.grammar`). There are three scratch builds: `exp/`
(half-measure), `exp2/` (merged position tokens, see F3) and `exp3/` (the F1 fix).

## Findings

Severity: critical = memory corruption or silent miscompile of accepted input; high =
accept-means-correct violation; medium = a valid program rejected, a misleading diagnostic,
or large needless complexity; low = polish, dead code, docs.

No critical or high findings: I found no input that the front end accepts with the wrong
meaning. Every bug below makes the compiler reject a valid program or print a misleading
diagnostic.

| ID | file:line | category | sev | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| F1 | src/rig.zig:1463-1491, 1717-1737 | bug / incomplete | medium | `valueTail` (the rule that a `-name` line whose value is used means negation) does not reach a `break` value or a loop's `else` block. So `-y` there is read as a drop, and a valid program is rejected with a confusing type error. | `b1`: `x = while true / break match y / 3 => -y / _ => 0` gives "incompatible types `Void` and `Int`". `c1`/`c2`: a loop's `else\n  -y` gives the same error. `return match …` works (`b5`). | In `rewrite`, add `.@"break" => valueTail(ir.Break.value(out), false)` (a break value is always used, per SPEC "Loops as values"). In `valueTail`, add `.@"while"`/`.@"for" => valueTail(else block)`. Verified in `exp3/`: b1 gives -3, c1 gives 0, c2 gives -3. | +4 (+2 behavior tests) | low |
| F2 | src/rig.zig:686-713, 836-862 | bug / fragile heuristic | medium | The heuristic for a sigil after a literal's or type's `]` scans raw text (`closed_literal`, `indexes`, `typeFollowsBracket`, `startsType`). It does not know about strings or comments. It is also whitespace-sensitive, which contradicts the rule stated at rig.zig:286 ("Whitespace inside an expression never picks a form"). And `startsType` does not include `(`, so a parenthesized element type cannot follow a type sigil. | `a4`: `[3][0]*a` gives "unexpected `*`", but `[3][0] * a` runs (6). `e3`: `[]?(Int?)` gives "unexpected `?`". `e1`/`e2`: `[2]*(Int?)` and `[]*(Int?)` give "unexpected `*`", although rig.grammar:559-564 says a handle to an optional is written `*(User?)` and element types take the full type syntax. | Remove the heuristic entirely (F3). No local patch is clean: adding `(` to `startsType` breaks `[1,2][0]*(3)`. | −40 (with F3) | medium |
| F3 | rig.grammar:159-176, 382-388, 486, 580-597; src/rig.zig:683-746 | needless complexity (leftover of paren-free calls) | medium | Paren-free calls are gone (commit 1a14187), so juxtaposition no longer exists. The LR parser can now tell prefix from infix and call from grouping by its own state. With all of these merged into their base tokens, the grammar is **LALR(1) conflict-free** (Nexus 1.0.0: 648 states, no conflicts): LPAREN_CALL, LBRACKET_INDEX, DOT_LIT, MINUS_PREFIX, MOVE_PFX, CLONE_PFX, SHARE_PFX, READ_PFX/SUFFIX_Q and WRITE_PFX/SUFFIX_BANG. With them merged, `inner` becomes `type`, `lparen` becomes `"("`, and the `tatom LPAREN_CALL` alternative goes away. The lexer still needs its classification internally (the touch rule, DROP_STMT, `if`/`of`/`..`/`??` flavours, bar lists), but it no longer has to guess types after `]`. | `g/vall.grammar` generates cleanly. `exp2/` is that grammar plus the lexer mapping its categories back to base tokens and the F2 heuristic deleted. Its suite result: **1665/1671 pass**, including every behavior, example, doc, IR and torture test. The 6 failures are 5 reject tests whose *hints* key on the old categories (`for *x`, `sub()?`, `error E[T]`, `struct W(T)`, `Vec(Int)`) and the lexer unit test. Both are expected: the hints need to read the lexer's internal category (`lexer.last_cat`) instead of `current.cat`. F2's repros all pass. BAR_CAPTURE also merges without conflict (`g/w1`), but the lexer needs bars for layout islands, so merging it gains nothing. KWARG_NAME, NULLISH_JUMP, DOTDOT_OPEN, the `if` flavours and DROP_STMT do conflict when merged (`g/w2`-`w6`); keep those. | Merge the tokens as above, and delete `closed_literal`, `indexes`, `typeFollowsBracket` and `startsType`. `next()` maps internal categories to the grammar's tokens, and the diagnostic hints read `lexer.last_cat`. Documents to update: INTERNALS token table, rig.grammar header 24-37, rig.zig 285-316. | grammar −30, rig.zig −40 +15 | medium (hint plumbing, `@display` expected-set text changes) |
| F4 | src/rig.zig:985-991 | bug / inconsistency | medium | `nextIsJump` (which decides NULLISH_JUMP) looks ahead with a raw probe. It does not skip line breaks inside brackets, `\` continuations, or comments. `nextJoinedCat` (rig.zig:971-982, used for `..`) does. So a jump fallback that is valid on one line is rejected when the line breaks inside brackets. | `d6`: `f(a ?? \` followed by `return 3)` gives "unexpected keyword `return`", plus a false note that the `(` is not closed. | Build `nextIsJump` on a shared "next joined token" probe (have `nextJoinedCat` return the Token). | ±0 | low |
| F5 | src/rig.zig:759-766, 799-806, 952-957 | bug / duplication | medium | The lexer reads a statement label as a value. After `:name`, `if` becomes POST_IF, `-` becomes infix, and `(`/`[` become call/index. Separately, "statement start" is defined three different ways: `atStatementStart`; the `defer`/`errdefer`/`=>` list in `classifyMinus`; and the `new` check, which misses `=>`. | `k2`: `:a if x > 0` gives "a postfix `if` guard must end a statement". `k3`: `:a -x` gives "unexpected `-`". | Use one `stmtStart()` that covers NEWLINE/INDENT/OUTDENT/EOF, `=>`, `defer`/`errdefer`, and the name right after a statement-initial `:` (track `after_label`). Use it in all three places. | +4 −4 | low |
| F6 | src/rig.zig:1213-1221 | diagnostics | medium | `unclosedBracket` states as fact that "the `(` opened here is not closed" for any parse error inside a bracket opened on an earlier line, even when that bracket closes later on the error's own line. Its own doc comment says only "may be". | `f1`: `print(max(1,` / `2 3))` gives "unexpected `3`" plus the note "the `(` opened here is not closed". `d6`: same false note. | Add the note only when that bracket never closes before the error line ends (scan for the matching close). Otherwise say "is it closed?". | +6 | low |
| F7 | src/rig.zig:1394-1430 | fragility / needless complexity | low | `expectedHint` prints the generated parser's error into a 4 KiB buffer, then re-parses the text by splitting on `", "` and `" or "`. But `BaseParser.expected(state)` and `symbolText(sym)` are public (parser.zig:2033-2042). The `@errors` name "an assignment or a call" (rig.grammar:412) gets split into two names, which skews the `max_expected = 3` cap. | Code at rig.zig:1398-1419. The `k1` output happens to read correctly only because the split pieces rejoin with " or ". | Iterate `BaseParser.expected(self.base.failure.?.state)`, dedupe by `symbolText`, and join. | −12 | low |
| F8 | rig.grammar:654-665 | dead duplication | low | `tail` and `rhs` are now identical (`expr \| cclosure`). They only differed by `cmd`, which was removed in 1a14187. | `g/v9.grammar` merges them with no conflicts. | Replace `rhs` with `tail` in the 7 uses, drop the `rhs` rule, its `@errors` entry, and the comment line at 656. | −4 | low |
| F9 | rig.grammar:528-546; src/rig.zig:1520-1535 | duplication | low | `pubmem` repeats 8 alternatives of `member` only so that `pub` parses on each of them. | `PUB decl:member` is conflict-free (`g/v9.grammar`). | Replace `pubmem` with `member`. `pubMembers` then also rejects a nested `pub` and receiver-sigil fields (`.pub`, `.read`, `.write`, `.move`). | −10 +2 | low |
| F10 | src/rig.zig:836-838, 864 | stale comment | low | `charAfter`'s doc line ("The character right after `tok`…") sits on top of `typeFollowsBracket`, and `charAfter` itself (864) has no doc. It was left behind by a move. | Lines 836-839. | Move the line to 864. | 0 | none |
| F11 | src/rig.zig:683-691 | stale / duplicated comment | low | Two comments in a row say the same thing. The first (683-685, "A sigil after a literal's or type's `]` starts its element type") is no longer true since 30b1de5; the second corrects it. | Lines 683-691. | Delete 684-685, or both with F3. | −2 | none |
| F12 | src/rig.zig:341-343, 623-626 | dead code / stale comment | low | `in_members` counts a `type` line, but a `type` line can never open a block: the parse fails at the INDENT first. The comment's "or generic type" also no longer describes anything (generics use `struct`/`enum`). | `j1`: `type Foo\n  fun: Int` fails at the INDENT with the struct hint. | Drop `.type` and "or generic type". | −1 | none |
| F13 | src/rig.zig:1261-1267 | clarity | low | `kw[0] == 'e' or kw[1] == 't'` is a cryptic way to test for `enum`/`struct`. | Line 1267. | Compare with `std.mem.eql`, or loop over `{"struct","enum"}` only. | 0 | none |
| F14 | src/rig.zig:1291-1300 | leftover / special case | low | `printHint` is a migration hint from paren-free calls, and it covers only `print`: `foo "x"` gets no hint. | Lines 1292-1300, and the reject test at 6:9. | Generalize: when a name is directly followed by an operand start on the same line, say "a call takes parentheses: `name(...)`". | +2 | low |
| F15 | src/rig.zig:1527 | clarity | low | `inner.kind() orelse .variant` treats a bare-name member as a `variant` without saying so. | Line 1527. | Switch on the leaf case explicitly. | +1 | none |
| F16 | src/rig.zig:1496-1515 (with sema) | diagnostics | low | Module-level `K = 1` is rewritten to `(set fixed)`. A later `K += 2` then gets a second, cascade error whose note says `K` "was bound here with `=!`", which is not what the source says. | `h4`. `h5`: `new K = 1` cascades into "used before it has a value". | After the "module-level binding is a constant" error, suppress the reassignment error, or word the note "is a module-level constant". | +3 | low |
| F17 | src/rig.zig:1623-1643 | limit that changes meaning | low | `receiverSigil` gives up past 256 postfix links (`max_spine`) and keeps the sigil outside the chain, which means something else. | Line 1643: `if (n == spine.len …) return node`. | Use an ArrayList, or reject "chain too long". | +2 | low |
| F18 | rig.grammar:433; SPEC.md:2384-2386 | grammar broader than SPEC | low | `":" label stmt` accepts a label on any statement. `:a x = 1` and `:a print(1)` are accepted, and emit drops the label without a word. The SPEC names only loops, `match` and `raw`. | `h8` runs, `h10` emit shows no label. | Restrict the grammar to `while`/`for`/`match`/`raw` (and `if` if intended; see LANGUAGE QUESTIONS), or have sema reject an unused label. | ±2 | low |
| F19 | src/rig.zig:1166-1190 | diagnostics | low | `T??` and `x??` lex as the `??` operator and get a bare "unexpected `??`", while `Int? ?` is accepted. This is the same token-boundary trap as `=!`, but without the hint. `?? continue :outer` gives a bare "unexpected `:`". | `d2`, `d9`, `d7`, `l1`. | Add hints: "`??` is the fallback operator; an optional of an optional is `(T?)?`" and "a jump after `??` takes no label". | +6 | none |
| F20 | src/main.zig:209-231; src/rig.zig:1167-1171 | duplication / inconsistency | low | `rig tokens` prints the lexer's generic message, while `rig check` prints the Parser wrapper's specialised one (`semicolonMessage`, `detachedPrefix`). The two commands disagree on the same input. | `g1`: tokens prints "unexpected `;`"; check prints "…Rig ends a statement at the end of its line…". | Move both message builders into `Lexer` (they need only the source and lexer state) and have `diagnostic()` call them. | ±0 | low |
| F21 | src/modules.zig:26, 325; src/main.zig:433-437 | duplication | low | The "16 MiB" text duplicates `max_source_bytes`. `writeFile` prints `@errorName(err)` instead of the reader-friendly `modules.fileError`. | Lines cited. | Format the size from the constant; use `fileError` (or a writer twin of it). | ±0 | none |
| F22 | src/modules.zig:198-205 | leak on OOM path | low | In `add`, `p` has no errdefer, and the `ctx` errdefer destroys without calling `deinit`. | Lines 200-205. | Add errdefers. | +2 | none |
| F23 | src/diag.zig:77 | silent fallback | low | A `module` index out of range quietly prints the position against the home file, which would be the wrong file. | Line 77. | `std.debug.assert(d.module <= modules.len)`. | 0 | none |
| F24 | docs/INTERNALS.md:1049 | stale doc | low | The Nexus note's example `L(expr) "," cmd` names `cmd`, which no longer exists. | Line 1049. | Use `callargs "," cclosure` (rig.grammar:841). | 0 | none |
| F25 | src/main.zig:307 | diagnostics consistency | low | "no `sub main()` to run" prints `path:1:1` with no source excerpt, unlike every other diagnostic. It also says `sub main()` while `declaresMain` accepts `fun main` too. | Lines 307, 374-382. | Route it through `diag.write`. | +2 | none |
| F26 | src/modules.zig:170-176 | duplicate diagnostic | low | An unreadable module is re-read and reported again at each `use` of it. | `f2` without m2.rig: two identical "cannot read module" errors. | Cache failed names in `by_name` (a sentinel id). | +4 | low |
| F27 | src/rig.zig:1105-1153 | limit | low | `max_tree_depth = 1000` also rejects a long left-associative chain (a sum of 1000 terms), because depth runs along the left spine. This is a safeguard against stack exhaustion, but its message says the "expression is nested too deeply". | Code. | Keep it, but say "too long or too deeply nested". | 0 | none |

## Restrictions stated in scope

| rule | where | serves North Star? | recommendation |
|---|---|---|---|
| No tabs in indentation; a dedent must land on an enclosing column; the first line is not indented | rig.zig:265-271, 605, 636-641, 561-568 | Safeguard: layout stays unambiguous | Keep |
| A prefix sigil touches its operand | rig.zig:310-311, 740-746 | Serves it: no spacing reads as another form (`a <- b`) | Keep. Note the exceptions: `. red` is accepted as `.red` (`f3`) and `@ sizeOf(Int)` as a builtin (`f4`); see LANGUAGE QUESTIONS |
| `=!` may not touch its operand | rig.zig:313-315, 731-732 | Safeguard (a real two-way token boundary) | Keep |
| `&&`, `\|\|`, `**` and `;` rejected with a hint | rig.zig:404-406, 416, 724-730 | Readability restriction with good hints | Keep |
| Pin sigil `@x` reserved | rig.zig:441, 822-829 | Reservation | Keep |
| Every keyword reserved; `new` only at statement start; `try`, `zig`, `async`, `await`, `const`, `impl`, `trait`, `when`, `where`, `yield` reserved but unused | rig.zig:148-193; rig.grammar:83-95 | Mostly future-proofing; it costs user names such as `when` and `const` | Owner's call (LANGUAGE QUESTIONS) |
| A keyword is a name only after `.`, before `:` in `( )`, and in member lists | rig.zig:781-794 | Safeguard | Keep. `.type` in `in_members` is dead (F12) |
| `-name` as a whole statement is a drop, otherwise negation | rig.zig:307-308, 796-820, 1714-1737 | Serves it (visible drop) | Keep, but finish the value-position cases (F1) |
| Captures come before parameters in a bar list | rig.zig:1704 | Readability restriction | Keep |
| A module-level binding is a constant; `=!` there is rejected | rig.zig:1493-1515 | The `=!` rejection is purely stylistic ("would say nothing more") | Keep for one spelling, but fix the cascade (F16) |
| `pub` not allowed on a drop body or an enum variant | rig.zig:1529-1530 | Safeguard with a message | Keep |
| Tree depth ≤ 1000; ≤ 64 blocks; ≤ 512 brackets; ≤ 32 islands; token ≤ 65535 bytes; source ≤ 16 MiB | rig.zig:384-386, 1105-1107; modules.zig:26 | Safeguards (stack, u16 token length). The 64 KiB cap also applies to string literals | Keep. Reword the depth message (F27); document the string-literal cap |
| One directory per program; a module name equals its real file name exactly (no symlink alias, exact case) | modules.zig:7-12, 177-182 | Serves "one name, one file", and emit relies on it | Keep. Flat layout is a LANGUAGE QUESTION |
| `__rig*` module names reserved | modules.zig:28-31, 166-169 | Safeguard | Keep |
| A module whose import failed is not checked | modules.zig:14-17, 149-152 | Diagnostic policy (no cascades) | Keep |
| CLI: the input ends in `.rig`; `-o` may not end in `.rig`; `--release`/`-o`/`--facts` only for their commands | main.zig:170-181 | Safeguards | Keep |
| A jump after `??`/`catch` takes no label | rig.grammar:681-688; SPEC.md:4208 | No: this is a grammar artifact (a `:` might start a `while` step) | LANGUAGE QUESTION. At least add the hint (F19) |
| A function type takes no suffix (parenthesize it) | rig.grammar:559-576; rig.zig:1352-1377 | Stratification, with a hint | Keep |
| Decimal numbers have no leading zero; radix prefixes are lowercase; strings hold no control characters | rig.grammar:197-211 | Safeguards against octal confusion and invisible characters | Keep |
| Named payload patterns (`.rect(w: a)`) are reserved | rig.grammar:762-769 | Reservation | Keep |
| A type alias takes no type parameters | rig.zig:1251-1257 | Restriction | Owner's call |
| Only the first syntax error per module is reported | rig.zig:1119-1123 (no `@repair`) | Neutral. Nexus `parseTolerant` exists (parser.zig:1451) | Keep for the CLI; revisit for an editor or LSP |

## LANGUAGE QUESTIONS (for the owner; not proposed as fixes)

1. **Labels on any statement.** The grammar and sema (typecheck.zig:547-557, a labeled
   block) accept a label on any statement, but the SPEC lists only loops, `match` and `raw`.
   Should `:a if c` be a labeled block (then fix F5), or should labels be limited to the
   SPEC's list (F18)?
2. **Labeled jumps after `??`/`catch`.** Should `x ?? continue :outer` be allowed? The lexer
   could mark a `:name` after `break`/`continue` as a label outside a `while` header.
3. **The touch rule for `.` and `@`.** `.` (enum literal) and `@` (builtin) start operands
   by position too, yet `. red` and `@ sizeOf(…)` are accepted. Should the touch rule cover
   them?
4. **`T??`.** Should a nested optional have a `??`-free spelling hint only (F19), or should
   `??` directly after a value and before a non-operand lex as two suffixes?
5. **Reserved but unused keywords.** Is reserving `when`, `where`, `const`, `yield` and
   `trait` still wanted?
6. **Modules in subdirectories.** Should the flat, one-directory module layout stay?

## Biggest simplification

The lexer's position classification was built for a grammar with paren-free calls, where
juxtaposition made `f (x)` and `a -b` ambiguous. That grammar is gone, and Nexus now shows the
grammar is LALR(1) conflict-free with all eleven call, index, enum-literal, prefix and suffix
tokens merged into their base tokens. Letting the parser decide position by its own state
removes the lexer's weakest part: the text-scanning `closed_literal`/`typeFollowsBracket`/
`startsType` heuristic, which is whitespace-sensitive and makes `[3][0]*a` and
`[]?(Int?)` impossible to write. It also collapses `inner`, `lparen` and a `tatom`
alternative, and removes eleven tokens and their `@display` entries. A scratch build of
exactly this passed 1665 of 1671 tests; the only failures were five hint-text checks and the
lexer unit test, which need the hints to read the lexer's internal category. Together with
merging `tail`/`rhs` and `pubmem`/`member`, and replacing the text round-trip in
`expectedHint`, the front end would shrink by about 100 lines while fixing F2.
