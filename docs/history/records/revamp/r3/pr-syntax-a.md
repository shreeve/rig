## Summary
Three v0.3.0 syntax changes the design owner approved, all breaking, plus two doc items and a TODO file:

| Change | Old | New |
|---|---|---|
| A drop is a move to nowhere | `-x` alone on a line | `<x` alone on a line |
| Spacing reads one way | `a <b`, `a- 1`, `f() !`, `w . get()` were accepted | each is rejected, with the text to write |
| A multi-line closure body ends with its bracket on a line of its own | `print(x))` closed the call on the body's last line | `)` on the next line, at the indentation of the line that opened the call |

- **CORE sentence 2** is now headed "**2. `<x` moves, `+x` makes a new owner.** A statement `<x` moves `x` nowhere, so it drops now." The rest of the paragraph is unchanged.
- **CORE sentence 4** gets the owner's sentence, right after its bold sentence: "`?` promises that nothing changes except a field whose type is a `Cell`." SPEC §7 "Lending" states it and the exact rule.
- **The pairing of `?` and `!`**, four positions each, is in the README tour (its first subsection, with a run example), in WELCOME ("The central idea"), and as a rationale paragraph in DESIGN.
- **TODO.md** holds the agent tooling item, with a row in the AGENTS.md Map.

## 1. `<x` drops; `-x` only negates
- **What drops.** A statement `<e` moves `e` nowhere, so what it takes is dropped now:
  - `<x` drops the binding, with exactly the old `-x` rules: consumed on every path, rejected while lent, and so on;
  - `<s.f` and `<v[i]` take an optional field or element, leave `none`, and drop it;
  - `<mk()` drops the value `mk()` makes.
- **Where a value is used**, `<e` still moves it there: a `fun`'s or a closure's last line, a binding's, `return`'s, or `break`'s value, and the last line of a branch, arm, `catch` handler, labeled loop, `raw` block, or loop `else` whose value is used.
- **`-x` always negates.** A statement `-e` does nothing and is rejected. Where `e` owns or views something, the diagnostic gives the drop to write.

**Desugaring** (docs/INTERNALS.md, Parser wrapper). The lexer no longer has a `DROP_STMT` token. The grammar's `drop` kind is a `@wrapper` that the Parser wrapper builds, and it is the existing drop node:
- A statement `(move x)` of a name becomes `(drop x)`, keeping its node id. Typecheck, ownership, emit, storage, and the oracle read it exactly as they read `-x` before.
- `(move e)` of anything else becomes `(drop (move e))`, which every pass reads as `_ = <e`, through one discard path each:
  - typecheck's `checkDiscard`;
  - the ownership checker's discard binding in `walkDrop`;
  - emit's `emitDiscard`, factored out of `emitSet`;
  - the oracle's `dropStmt`, which takes the value as `_ = e` does.
- `valueTail` undoes the drop where the value is used.

**Diagnostics:**
```
this expression does nothing as a statement; to drop `v` now, write `<v`
this expression does nothing as a statement; `s.r` is dropped with what holds it, or replaced by assigning to it
this expression does nothing as a statement: `-f()` negates a value and discards it
`<n` drops nothing: `n` is plain data
a closure's last line is its value, so `<q` there is no drop, and this closure gives no value; to drop `q` here, write `_ = <q`
```

## 2. Spacing
- **The rules:**
  - An infix operator has the same spacing on both sides: arithmetic, comparisons, `??`, `..`, the bitwise operators, `=`, and the compound assignments.
  - A postfix `?` or `!` touches what it follows.
  - A member `.` touches both sides.
  - An enum literal's `.` touches its name.
  - A range's `..` with one bound touches it.
  - A prefix sigil touches its operand, as before.
- **Where it is checked.** The lexer records each violation (`Lexer.checkSpacing`). The label of a jump (`break :a !n`) ends no operand there. The Parser wrapper reports every violation, up to 32, once the source parses and the tree is rewritten, so a parse error or a type's detached sigil is still the one reported.
- **The hint** names the fix, and the prefix reading where there is one:
```
`a <b`: an operator has the same spacing on both sides; write `a < b` to compare, or `a, <b` to move `b` as a value of its own
`a< b`: an operator has the same spacing on both sides; write `a < b`
`0 ..a`: an operator has the same spacing on both sides; write `0..a` or `0 .. a`
`maybe(n) ?`: a postfix `?` touches what it follows; write `maybe(n)?`
a member `.` touches both sides; write `w.get()`
`.` touches the name after it; write `.green`
a range's `..` touches its only bound; write `a..`
`print` is called with parentheses: `print(-1)`
```

## 3. Multi-line closure bodies
- **The rule.** A closure body laid out below its bar list (a layout island) ends with the bracket around it alone at the start of a line, at the indentation of the line that opened the bracket. So the closure is the last thing the bracket holds, and the immediately-called form ends with a `)()` line.
- **What the lexer records:**
  - the bracket closing the island on the body's last line;
  - a closing line that starts with anything else (`, 3)`);
  - a closing bracket at another indentation.

  They are reported with the spacing violations.
- **Grammar conflicts:** none; the grammar has no `@conflicts`.
```
a closure body below its bar list ends with `)` on a line of its own: end this line before the `)`, and write `)` on the next line at the indentation of the line that opened it (column 3); a one-line body may instead follow the bar list on its line
a closure body below its bar list ends where the `)` around it stands alone at the start of a line, at the indentation of the line that opened it (column 3)
write this `)`, which ends a closure body below its bar list, at the indentation of the line that opened it (column 3)
```

## The rewrite
`.git/revamp/r3/syntax-a/rewrite.py` (`scan` / `apply`, `--only=spacing,drop,closure`) rewrites every tracked `.rig` file, every ```` ```rig ```` doc block, and the test/cli heredocs. It is idempotent: `scan` on the head reports 0 files.
- **drop.** It applies the old lexer's rule, minus the value tails the old parser read as negation. `verify_drop.py` checks this against the old compiler's `--facts` over all 4828 programs it accepts: 0 disagree.
  - 435 drops are rewritten.
  - 3 drops on a closure's last line were fixed by hand:
    - corpus R16-rs3;
    - reject `drop_captured_resource`;
    - reject `match_captured_payload_move`.

    A line after the drop keeps each probe's point.
  - 3 corpus probes about `-x` on a closure's last line are left as written; that `-x` now negates, and they run: audit-frontend-b3, review-sc3-nh5, review-sc3-nh6.
- **spacing.** It balances two lines, in SYNTAX.md and audit-fuzz-c-mut-c1a5565a76. The corpus probes whose point was the spacing stay as they were and are now rejections (`SPACING_KEEP`). `behavior/syntax/whitespace_insensitive.rig` keeps the forms still accepted, and `reject/syntax/unbalanced_spacing.rig` takes the rest (16 errors).
- **closure.** It inlines a one-line body that reads the same after its bar list; otherwise it puts the bracket on its own line. It also moves the `# error: L:C:` directives the new lines shift. The d04 loop-lowering probe passed its closure first (`run(|x| ..., 3)`), so it now passes keywords (`run(x: 3, f: |x| ...)`). Its output and oracle lines are unchanged.

## Commits (since main faceba15)
- 3842800b **Drop with a statement `<x`; a statement `-x` only negates** (compiler, grammar, oracle).
- a31342cf Rewrite drop statements `-x` as `<x` (rewrite.py).
- 52f85693 Write drops as `<x` in tests and docs. This commit also adds the closure-last-line hint.
- e203eb89 **Reject an operator spaced on one side only, a detached postfix, and a spaced member dot**.
- 1bf91475 Balance the spacing of operators in the tree (rewrite.py).
- 6277f00c Document the spacing rule and the pairing of `?` and `!`.
- 6803c0f6 **End a multi-line closure body with its bracket on a line of its own**.
- d12bd178 Lay out multi-line closure bodies with the bracket on its own line (rewrite.py).
- 8c4f2ebd Document the closing bracket of a multi-line closure body.
- 1fbba781 Say in CORE what `?` promises about a Cell.
- 6a8f6fc6 Add TODO.md with the agent tooling item.
- b6296ea1 Say `<x` for a drop in the runtime's comment. It changes the text of every package's runtime, and nothing else.
- 36faddef Report an operand's own error before a statement `-e`'s (found by equiv: `-x.abs()` lost its "no method `abs`").
- c755b7c0: merge main c7085d43 (#91, IDEAS.md). The merge was clean, and `rewrite.py scan` finds nothing in it.
- 5059854a **Empty an optional place a discarded take leaves, as a bound take does** (review round 1, High; main had the bug in `_ = <s.f`).
  - Class: emit re-derived "a move of a value that owns nothing is a copy" from syntax, in `emitDiscard`. So `<s.f` and `_ = <s.f` on an optional of a type with no drop glue (`Int?`, a plain struct's, `String?`) emitted `_ = &s.f;` and left the field set.
  - Fix: `emitDiscard` now reads the checker's fact for the move, `Facts.takes`, the one `x = <e` reads. A take keeps its `move` and is emitted as `rig.takeOut(&place)`; only a move the checker did not record as a take is discarded by address. There are no new imports, and the Pending budget is unchanged.
  - Siblings checked:
    - the discard path for each form: a statement `<P`, `_ = <P`, `defer <P`, and the bound `x = <P` as a control;
    - the places `P` covers: a local's field, a field through a `!S` parameter, a `!self` field, a Vec element, and a nested field;
    - in the targeted grid below, for each kind of optional: `Int?`, a plain struct's, `String?`, `Text?`, `Vec[Int]?`, a struct with a `drop` body, `*N?`, and `Box[N]?`;
    - by hand: header takes, `if <s.f as v`, `while <c.n as w`, and `<d.n ?? 0`, which already took through the fact.

    Elements were never affected: `.index` already went through the value path.
- 689d9ddc **Point the drop hints at what the code says** (review round 1, Lows 1, 3, 4, 5):
  - a `<q` in a branch that ends a no-value closure says so;
  - the spacing hint shows the left operand when it ends on the line before;
  - `-x` of a view parameter says a view parameter is not dropped, instead of suggesting `<x`;
  - a statement `<?a` or `<!a` is rejected: "moves a view nowhere, and a view owns nothing to drop".

## Tests
- `behavior/ownership/discard_take_plain_optional.rig` (`# release`) is the High's test, and failed before the fix. A statement `<P`, `_ = <P`, and `defer <P` of `Int?`, plain-struct, and `String?` fields each leave `none`: through the owner, a `!S` parameter, and a `!self` method, plus a Vec element.
- `behavior/ownership/drop_statement_takes.rig` covers each kind of drop and move:
  - drops: a binding, an optional field, a Vec element, a made value, a guarded drop, a statement match's arm;
  - moves where the value is used: a value `if`'s branches, a function's last line, a closure's last line.
- Reject tests:
  - `reject/syntax/minus_statement_drop_hint.rig` (6 errors) and `minus_statement_negates.rig` (9);
  - `drop_statement_plain_data.rig` (5), `drop_closure_last_line.rig` (2), and `drop_statement_lend.rig` (2);
  - `unbalanced_spacing.rig` (17) and `closure_body_close.rig` (5).
- Unit tests:
  - the lexer's spacing and closure layout records (`expectLayout`);
  - minus is never a drop;
  - the drop statements in the ownership and sema unit sources are rewritten.
- One change to a matrix template: the `drop` target act is `<v`.

## Verification
Gates on the head 689d9ddc (`--delta`, through cpuq via heavy.sh, one at a time):
- suite 2918 passed, 0 failed, 3 pending;
- corpus 7294 passed;
- matrix 5877 programs, 3213 ran clean, 2664 rejected, 0 failed (the same counts as on main);
- unit 135 passed, 1 skipped;
- the 5 oracle sets (lint, tests, corpus, docs, matrix) pass in the suite, at their coverage floors.

**Grid of discarded takes** (`.git/revamp/r3/syntax-a/grid_discard.py`): 160 cells, 0 bad. The cells cover:
- 8 kinds of optional place: `Int`, a plain struct, `String`, `Text`, `Vec[Int]`, a struct with a `drop` body, `*N`, and `Box[N]`;
- 5 paths: a local's field, a field through a `!S` parameter, a `!self` field, a Vec element, and a nested field;
- 4 forms: a statement `<P`, `_ = <P`, `defer <P`, and the bound `x = <P` as a control.

Each cell must print that the place is `none` afterwards. Each is built in debug and `--release` under `RIG_SANITIZE=1`, and `bin/rig-oracle -v` must reject no function.

## Equivalence
Both comparisons use a build of the head with main's `src/runtime.zig` (`rig-equiv`). That keeps b6296ea1's comment change in the runtime from showing in every package.

**`test/equiv.py` against main faceba15**, with the head 689d9ddc: 9751 programs, 435 differ.

One program both compilers accept differs in `emit` and `pkg`: corpus `review-take-p125`. It is the High's bug on main. Its `_ = <s.a` of an `Int?` field was `_ = &s.a;`, so the field kept its value; it is now `_ = rig.takeOut(&s.a);`, which empties the field. No other program both accept differs in `sema`, `storage`, `emit`, or `pkg`. The other differences:
- **382** (`normalize check facts`, or `parse normalize check facts`) are programs in the new syntax that main rejects:
  - a statement `<x`;
  - the corpus spacing probes, now rejected;
  - the new tests and doc examples.
- **22** (`parse` only) have a value-tail `-x`. Main's raw parse made it `(drop x)` and its rewrite made it `(neg x)`; the raw parse now gives `(neg x)` too, and the semantic IR is the same.
- **17** (`check facts`) are rejected by both with new wording (`<x drops nothing`, the `-e` statement messages), or have a module in the new syntax that main rejects.
- **9** (`facts` only) differ in node ids. A value-tail `<e` wrapped and unwrapped by the drop rewrite still takes one id from the counter, so later wrapper nodes' ids move by one. Spans and kinds are equal.
- **3** (`normalize` only) are two library modules and `:x <y`; both compilers reject them alike.
- **1** (`parse check facts`) is `minus_tail_not_number`.

**`compare_rewrite.py`** runs main's compiler on each original program against the new compiler on its rewritten form: 402 programs, the changed `.rig` files and doc blocks, 28 differ.
- **Every program both accept** emits identical Zig and an identical sanitized package, except two:
  - `whitespace_insensitive.rig`, rewritten by hand into a different program;
  - the d04 probe, whose closure is now passed by keyword. Only a hidden name, `__rig_arg_13_0` → `_1`, differs, since it numbers arguments in source order.
- **26 are rejected by both**, with the new wording:
  - 21 corpus probes, where `-x drops nothing` became `<x drops nothing`;
  - `detached_prefix_drop`, `minus_statement_negates`, `minus_tail_not_number`, and `print_bare_name`, each updated by hand above.
- **Doc blocks** are paired by the rewrite. 4 doc blocks have no pair: 2 SPEC examples and 1 SYNTAX example were replaced by hand, and README, WELCOME, and SYNTAX each have one new example.

## Decisions to confirm
The owner has not ruled on these. Review round 1 left Decision 4 for the owner. Each is built as described, the conservative choice.
1. **A closure's last line is its value**, as `<x` there always was, and so is the last line of a branch that ends the closure. So in a closure that gives no value, a `<x` there is no drop. It is rejected with the hint to write `_ = <q`. Making it a drop would need the closure's type in the parser, or a fact every pass reads.
2. **A line break before a member `.` inside brackets is allowed**, so a method chain may go on at the start of the next line. SYNTAX documents this, and `line_joining.rig` tests it. Spaces on one line are rejected (`w . get()`, `w .get()`).
3. **Not checked:**
   - a space before a call's or an index's bracket (`f (x)`, `xs [0]`), which SYNTAX documents as allowed;
   - `->`, `=>`, `:`, and `,`.

   `=` and the compound assignments are checked as infix operators (`x =1` is rejected).
4. **The Cell sentence names fields.** It says "a field whose type is a `Cell`". A bare `?Cell[T]`, an element whose type is a Cell, and a Cell behind a `*T` in the view also change. CORE has the owner's sentence verbatim, and SPEC §7 "Lending" states the full rule after it.

## Migration (v0.3.0 release notes)

| Old | New | What the compiler says about the old form |
|---|---|---|
| `-x` alone on a line (drop now) | `<x` | this expression does nothing as a statement; to drop `x` now, write `<x` |
| `-x` alone on a line, `x` plain data | (nothing to drop) | this expression does nothing as a statement: `-x` negates a value and discards it |
| `defer -x` | `defer <x` of a binding is rejected, as `defer -x` was: a `defer` body cannot move or drop a binding. `defer <s.f` and `defer <mk()` take and drop at the scope's end. | |
| `-x` as a closure's last line, in a closure that gives no value | `_ = <x`, or the drop before the last line | the `-x` line: this expression does nothing as a statement; to drop `x` now, write `<x`. Written `<x` there instead: a closure's last line is its value, so `<x` there is no drop, ... write `_ = <x` |
| `a <b`, `a -1`, `a +b`, `a *b` | `a < b` (or `a<b`), `a - 1`, ... | `a <b`: an operator has the same spacing on both sides; write `a < b` to compare, or `a, <b` to move `b` as a value of its own |
| `a< b`, `x =1`, `a?? b` | `a < b`, `x = 1`, `a ?? b` | an operator has the same spacing on both sides; write ... |
| a line inside brackets starting `-1` after a value (`f(a`⏎`-1)`) | `a - 1`, or `a, -1` | the same, at the `-` |
| `f() !`, `T ?`, `[] ?Int` | `f()!`, `T?`, `[]?Int` | a postfix `!` touches what it follows; write `f()!` |
| `w . get()`, `w .get()` | `w.get()` (a line break before `.` inside brackets is fine) | a member `.` touches both sides; write `w.get()` |
| `. red` | `.red` | `.` touches the name after it; write `.red` |
| `xs[a ..]`, `xs[.. b]`, `0 ..n` | `xs[a..]`, `xs[..b]`, `0..n` or `0 .. n` | a range's `..` touches its only bound; write `a..` |
| a closure body below its bar list whose last line ends the call: `print(x))` | `print(x)` then `)` alone on the next line, at the call line's indentation; or a one-line body on the bar list's line, `f(\|i\| print(i))` | a closure body below its bar list ends with `)` on a line of its own: ... |
| such a closure followed by more arguments (`f(\|x\|`⏎`  body`⏎`, 3)`) | the closure last (keyword arguments reorder), or bound to a name first | a closure body below its bar list ends where the `)` around it stands alone at the start of a line, ... |
| `(\|+n\|`⏎`  ...`⏎`  m + 1)()` | `(\|+n\|`⏎`  ...`⏎`  m + 1`⏎`)()` | the hanging-bracket error |

`.git/revamp/r3/syntax-a/rewrite.py apply` makes the drop, spacing, and closure rewrites in a checkout. It leaves programs whose point is the old form, and reports a drop on a closure's last line as `MANUAL`.
