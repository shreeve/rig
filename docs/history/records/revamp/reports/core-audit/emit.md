# Core audit: failure, syntax outside the core, and emit honesty

Auditor 6 of 6. The scope is Core sentence 10, §7, open decisions 3, 5 and 6,
emit honesty, and the speed of `rig check`.

**Compilers used:**
- `main` at dd36c78: `bin/rig`, built 10-02 04:35.
- `text-core` at 59e7bed: exported with `git archive` and built in the
  scratchpad, because `../rig-text/bin/rig` predates its last commit. That
  branch has no `RIG_SANITIZE`.

**Probes:** `probes/emit/`. `run.sh` checks each probe. When the probe is
accepted, it then runs `RIG_SANITIZE=1 bin/rig run` and keeps `<probe>.out`.

---

## 1. Unsound and wrong-output probes, ranked

### U1 (critical, live on main): `print` copies a Cell-holding owner, then a later argument changes the Cell through a read borrow

**On main**, each of these is accepted and then crashes under the sanitizer
with `use of freed memory`:

| Probe | Source line | What the later argument does |
|---|---|---|
| `u01_cell_vec_print_grow.rig` | `print(c, grow(?c))`, with `c: Cell[Vec[Int]]` | `grow` pushes 1000 items through `?c`, so the Vec reallocates |
| `u02_struct_cell_vec_print.rig` | `print(s, grow(?s))`, where `s` holds a `Cell[Vec[Int]]` | the same, through a field |
| `u03_cell_vec_clear.rig` | `print(c, reset(?c))` | `c.set(Vec())` frees the old buffer |
| `u06_cell_box_print.rig` | `Cell[Box[Int]]` | `set` frees the old box |
| `u07_cell_shared_print.rig` | `Cell[*Vec[Int]]` | `set` drops the last strong handle |
| `u08_method_self_cell.rig` | `print(self.c, self.grow())` inside a `?self` method | the same, through `self` |

**On text-core**, the same programs are accepted, and it has no sanitizer:

- `text/t05_text_cell.rig`: `Text(c, grow(?c))` prints `Cell(value: [0])`
  where `[42]` is expected. It read freed memory.
- `text/t06_text_add_cell.rig`: `!t.add(c, reset(?c))` and `print(c, reset(?c))`
  print `-6148914691236517206` (`0xAA…`): poisoned freed memory.

**Mechanism.** The emitted code is `rig.print(.{ c, grow(&c) })`
(`emit.zig:4580` `emitPrint`; text-core `emit.zig:3862` for `Text.of` and
`add`). Zig copies `c`, the Cell and the Vec header inside it, into the tuple
before `grow` runs. `grow` then reallocates or frees the buffer through
`@constCast(&c)`, so the tuple prints a dangling header.

**Why the checker misses it.**
- `holdArgRead` (`ownership.zig:2636`) gives the root of an argument a *read*
  loan "until the call ends". Its comment says the call reads the value only
  after the later arguments run.
- A later `?c` is also a read borrow, so the two loans do not conflict.
- A Cell may change through a read borrow (Core sentence 9).

So the checker models "print reads `c` at the call" while the emitted code
reads `c` at the argument. This is the W3 class again: the checker and emit
disagree about evaluation order.

**Wrong output on plain data, the same mechanism.**
- `u05_cell_int_print.rig`: `print(k, bump(?k))`, with `k` holding a
  `Cell[Int]`. It prints `Cell(value: 1)`, although `bump` set the cell to 99
  before `print` ran.
- `u04_shared_cell_vec.rig`: the same shape through a `*Cell[Vec]` prints the
  *new* value, because the tuple holds the handle.
- So whether a Cell's change shows depends on the representation.

**Sibling sites I checked.** All are closed, by a sema rule or by a pointer
representation:
- `rig.lend` and `ReadBorrow` (a pointer for anything that holds a Cell);
- `if ?o as c` (`u11`, a pointer);
- closures `|?c|` (`c03`, a pointer);
- match and for bindings (a Cell can't be changed through them:
  "a loop or match binding (a copy)");
- array elements (arrays can't hold owners);
- `==` (a Cell holding a Vec has no `==`);
- hoisted call arguments (an owning by-value parameter needs `<x`).

The open sites are only the by-value tuples: `print`, `Text(...)` and
`!t.add(...)`.

**Fixes:**
- **(a) Emit, size S; preferred.** `print`, `Text.of` and `add` take every
  argument that reads a place which is not plain or Copy by address, as
  `rig.Ref(&c)`, and the runtime's `writeValue` dereferences it. Then
  `print` reads at the call, exactly what `holdArgRead` models. That makes
  `u01`–`u08` correct, and `u05` prints 99. This is step L1 of the lowering
  design below, done early.
- **(b) Checker, size S.** For an argument whose type holds a Cell that
  reaches an owner, `holdArgRead` records a hold that conflicts with any
  later borrow of the root, read borrows included. It rejects `u01`–`u08`
  but leaves `u05` as it is.
- **Matrix row to add:** form "a Cell-holding owner place" × context
  "`print`/`Text`/`add` argument followed by a call taking `?root`" × types
  `Cell[Vec]`, `Cell[Box]`, `Cell[*T]` and `Cell[Text]`.

No other probe of mine was unsound. Around 60 evaluation-order, drop-order,
re-evaluation and Cell probes were either rejected with a sensible message
or ran sanitizer-clean with the right output (section 4).

---

## 2. Gap table

The status column uses CORE.md's status words.

| Core rule | Status claimed | Actual behavior (probe) | Gap | Code location | Fix | Step |
|---|---|---|---|---|---|---|
| S10: every fallible call says what happens to its failure | built | Bare calls are rejected for functions, methods, generics, `?fun`, `*fun`, ternary branches and match subjects (`g01`, `g02`, `g09`, `g10`). `defer … catch` works (`g07`). | None for calls. But **`??` is not a failure handler** (`g11`), although S10 lists it. | `typecheck.zig:4400` `synthCall` | Doc: S10 should say "`!` or `catch`" | Core text |
| S10: failing is always written | mostly built, decision 3 open | Silent failure in **10 forms**: a bare error on the last line (`f01`), an error binding (`f02`), a ternary branch (`f04`), a match arm (`f07`), a closure with a fallible type, stack or owned (`f08`, `g04`), a tail `if` statement (`f16`), a call returning an error set (`f17`), `break E.bad` / `else` of a value loop (`f18`), a field of error type (`f19`), and the tail of `fun main -> Int!` (`f23`) | The decision 3 text names only "a bare error value or error binding on the last line". The real class is "any error-set value where `T!` is expected, other than `return`'s operand". | `typecheck.zig:7914`, the one line `compatible(.fallible)` accepting `isErrorValue` | **S**: accept an error value for `T!` only as the operand of `return` (prototyped, §3.1) | Decision 3 |
| S10: `return E.name` | built | `return e` with a binding (`f09`), and `return which(n)` | Allowed, and arguably written (the `return` is there). Say so. | `typecheck.zig:659` `checkReturn` | Doc | Decision 3 |
| S10 / failing `main` | built | `sub main` propagates with `!`. Leaving `main` prints `error: E.bad` after the drops and exits 1 (`f13`, `f22`, `f23`). `return E.bad` in a plain `sub main` is rejected, with a hint naming `sub main(...)!` (`f12`). | The hint shows `(...)`, which `main` never has | `typecheck.zig:678` | S (message) | Polish |
| S10 / error naming per module | built | Comparisons keep each set's identity (`mod/f20`: `liba.E.bad != libb.E.bad`). Printing shows `E.bad` for the root's error and for both modules' (`f20`, and `rig test` in `f21`). | As specified ("without the module", SPEC §17), but distinct errors print alike | `runtime.zig:1574` `errorShown` | Optional: show the module outside the root | Later |
| S10 / errdefer | built | `errdefer` and drops run, in the right order, on every silent-failure form (`h01`) | None | `emit.zig:1534` `markReturningBlocks` | n/a | n/a |
| §7 `-x` drops as a statement, negates as a value | built | Exact rule in §3.1. `-f()` and `-(…)`-with-effect as a statement are a negation discarded silently (`s23`). The same `-x` line drops in a statement branch or the tail of a `sub`, and negates in the tail of a `fun` or a value branch (`s05`, `s26`, `s32`). `-x` of an `Int` drops it, ending the name (`s07`, `s25`). | `-call()` as a statement should be rejected ("only a binding is dropped") to match `-p.f` | `typecheck.zig:625` `checkExprStmt` | S | §7 |
| §7 receiver-sigil rule | built | As documented (§3.2). Every non-receiver habit of `!` as "not" is rejected (`s01`, `s02`, `s27`, `s28`). | Only the `Bool` write call in value position (decision 6) | `typecheck.zig:6582` `checkReceiverSigil` | see decision 6 | Decision 6 |
| §7 `!` before a write call whose `Bool` result is used | open, decision 6 | Accepted in a binding, an argument, a `match` subject, an array element, a `==` in a binding, a ternary value, a closure body, and `return` (`s19`; corpus `review-sc3-n1`, `-n2`) | A C/JS reader reads `match !s.insert(1)` and `show(!s.insert(1))` as "not". `s19` prints `show false` where a C reader expects `true`. | `typecheck.zig:6597` (`startsNegationOperand`, `:1433`) | **S**: allow the short form only as a whole expression statement (prototyped) | Decision 6 |
| §7 `=!` | open, decision 5 | `ok =! done` is a fixed binding of `done`. A C reader reads it as `ok = !done` (`s18`, which prints `false`). A tight `x =!y` is rejected (`s16`); `=!` on a bound name is rejected (`s17`). | A silent habit trap, plus a fourth meaning of `!` | `rig.grammar:218,431-433,461-462`; `rig.zig:305,435,727,1236-1238` | S–M (§3.3) | Decision 5 |
| §7 labels | built | A label works on a loop, `match` or `raw`; `continue :outer` works (`s22`). Unlabeled `break` inside a `match` leaves the loop (`s14`). | A C habit (`break` leaves the `switch`) silently changes meaning. Rust and Python agree with Rig. | n/a | Doc line in WELCOME | Doc |
| §7 `catch` forms | built | `catch v`, `catch \|e\| …` (a block too), `catch return/break/continue` all work. `catch pass` is a parse error (`g08`). `e catch a if c else b` is `e catch (a if c else b)` (`s20` prints 3, where a Python-style grouping gives 5). | A precedence habit, documented in SYNTAX §6 | n/a | Doc example | Doc |
| §7 `pass` | built | Works as a statement, and is rejected as a value | None | n/a | n/a | n/a |
| §7 `??` | built | Binds tighter than `==`: `a ?? 1 == 5` is `(a ?? 1) == 5` (`s21`), as in Swift and unlike JS. It is not a failure handler (`g11`). | None (a JS reading is usually a type error) | n/a | n/a | n/a |
| §7 habits outside the list | n/a | `/` and `%` truncate as in C (`s11`: `-7 / 2 = -3`, `-7 % 3 = -1`), a silent change for Python readers. `u?.n` returns `none` from the *function* (`s13`: "after chain" is never printed), a silent change for Swift/Kotlin readers. `*x` on an `Int` silently makes a counted box (`s08`). `~x`, `\|\|`, `&x` and `!x` (as not) are rejected with hints (`s09`, `s10`, `s12`, `s01`). | Two silent traps (Python `/`/`%`, Swift `?.`) | n/a | Doc lines in WELCOME/FAQ | Doc |
| AGENTS "the checker checks exactly what is emitted" | rule | Hoisting, keyword reordering, receivers, assignments (#31), drop order on failure, guards and single evaluation all agree (§4). **Exception: the `print`/`Text`/`add` tuples (U1).** | W3 instance, live | `emit.zig:4580`; `ownership.zig:2636` | S now (U1a), then L1 | Now |
| §8 one classifier per fact | decided | Emit re-derives purity (`isPureArg`, `emit.zig:4267`, which uses `flags.fixed`), "acts" (`actsBeforeStore`, `:5538`) and "temporary" (`hoistsArgs`, `:4211`). The runtime and sema each decide copy-vs-pointer for `?T` (`runtime.zig:87` `ReadBorrow` vs `sema.readBorrowCopies`). | Facts settled twice | as listed | M | L0 |
| Accept means correct (reject side) | rule | `match !w[i]` with a literal arm is rejected: "expected `!Int`, got `Int`" (`o03`) | A false rejection | typecheck match patterns under a write subject | S | Polish |

---

## 3. Sentence 10 and §7 in detail

### 3.1 Every way a function fails or propagates (main)

| Form | Written? | Notes |
|---|---|---|
| `f()!` | yes | Allowed in a `T!` fun, a `sub f()!`, `sub main`, a `test`, and a closure whose type can fail. Rejected in `defer`, a `drop` body, and an infallible closure or function (`typecheck.zig:3053`). |
| `f() catch …` | yes | The handler may be a value, `\|e\|` plus a block, or a jump |
| `e?` | n/a | Propagates `none` only; on a fallible operand it is rejected with a hint |
| `??` | n/a | Not a failure handler: a fallible left side is rejected (`g11`) |
| `return E.x` | yes | |
| `return e` (a binding, call or field of error type) | yes (`return`) | `f09` |
| **error value in tail position** | **no** | `f01`, `f02`, `f17`, `f19`, `f23` |
| **error value as a branch or arm value in tail position** | **no** | `f04`, `f07`, `f16` |
| **`break E.x` / `else E.x` of a value loop in tail position** | **no** | `f18` |
| **closure body tail when its type can fail** | **no** | `f08`, `g04` (owned `*fun`) |
| `?? E.bad`, `catch E.other` | rejected | The fallback is typed `T`, not `T!` (`f05`, `f06`) |
| a caught `e` bare at the end of a handler | rejected | Typed `error` against `T` (`f03`) |
| generic `T!` with `T` an error set | rejected | `f11` |
| generic `-> Int!` returning a `T` | rejected | `f10` |
| failing `main` | yes | `error: E.name` on stderr, exit 1, after the drops (`f13`) |
| `rig test` | yes | `FAIL  test "name": Set.name`, then `N passed, M failed`, exit 1 (`f21`) |

**Decision 3 as one rule:** "an error value meets `T!` only as the operand of
`return`".
- **Prototype:** `probes/emit/proto-d3-d6.diff`, about 20 lines. It adds a flag
  set in `checkReturn` and in the closure `return`-site check, read by the
  `.fallible` arm of `compatible`.
- **Probes:** it rejects every silent form above (and `g04`) and keeps `f09` and
  `return E.x` working.
- **Suite impact**, from running `rig check` with stock and prototype on
  5371 `.rig` files and 148 doc examples
  (`proto-d3-d6-newly-rejected.txt`):
  - 2 behavior tests: `effects/errdefer_in_failing_value_block.rig` and
    `types/optional_fallback_from_context.rig`;
  - 9 corpus probes. They now reject, which is still a valid corpus outcome.
- **Docs:** 0 doc examples are affected. The prose to change is SPEC §13
  "Failing" ("a binding of an error set's type", and "including when the
  error is the final value of an `if` or `match` branch block") and SPEC's
  bare `.name` paragraph.
- **The message** needs a hint, `return E.bad`. The prototype prints only
  "type mismatch".

### 3.2 `-x`, receiver sigils, and `!` before a `Bool` call: exact rules today

**`-x`:**

| Position | Meaning |
|---|---|
| `-name` as a whole statement | drop the binding, of any type, a Copy `Int` included (`s07`, `s25`) |
| `-p.f` or `-v[i]` as a statement | rejected: "only a binding is dropped" |
| `-call()` as a statement | a negation, discarded silently (`s23`) |
| `(-x)` as a statement | rejected: "does nothing" (`s31`) |
| any value position | negation |

What counts as a statement depends on whether the line's value is used:
- the tail of a `fun` negates (`s05`);
- the tail of a `sub` drops (`s26`);
- a branch of a value-position `if` negates, and of a statement `if` drops
  (`s32`).

**Receiver sigils.** `?`, `!` or `<` directly before a place (a name, then
`.field` and `[index]` steps) followed by a method call applies to the
receiver. Any other prefix, or a sigil with no call after the place, applies
to the whole expression (`-a.len`, `+n.first()`, `*P.origin()`, `!x.v`,
`?xs[0]`). The exceptions are all rejections:
- `!` before a method that does not take `!self` ("for negation use `not`"
  when it returns `Bool`);
- `<` before a method that does not take `<self`;
- `?` before a method taking `!self` or `<self`;
- any sigil before a function with no receiver, or a field holding a function
  (`fieldCallSigil`, `typecheck.zig:6563`).

**The `Bool` rule today.** A short-form `!x.m()` whose value is `Bool` is
rejected only where it *starts* a condition or an operand of `and`, `or` or
`not`, including through `==` (`startsNegationOperand`, `typecheck.zig:1433`,
about 45 lines with the field and wrapper).

### 3.3 Decisions 5 and 6: what they change, and their exact size

**Decision 6: the long form wherever the `Bool` is used.**
- **Prototype:** in `checkReceiverSigil`, accept the short form only when the
  receiver sigil starts the whole expression statement (`stmt_expr`). That is
  2 changed lines. `negation_operand`, `checkBoolOperand`'s bookkeeping and
  `startsNegationOperand` (about 45 lines) can then be deleted.
- **Probes:** `s19` is rejected on all four lines.
- **Suite impact:**
  - 1 behavior test, `types/receiver_sigil_bool_value.rig`, whose `return`,
    bindings and `print` uses become `(!s).insert(...)`;
  - 5 corpus probes now reject (still a valid outcome): `docs-probes-nb`,
    `purity-principles-p18_notbang`, `review-sc3-n1`,
    `seams-surface-a01_bool_short`, `audit-fuzz-pf2-accepted-0bb6dd2b9b`;
  - 2 SPEC examples (`SPEC.md:829`, 3 lines; `:909`, 1 line), the SPEC
    prose at `:818-827`, and SYNTAX `:326-329`.
  - `test/reject/types/receiver_sigil_bool_result.rig` stays as it is.
- **Total:** S (half a day).
- **What it removes:** the context list (condition / `and` / `or` / `not` /
  `==` inside those), replaced by one sentence: "a write call's `Bool` is
  read only through `(!x).m()`".

**Decision 5: `=!`.** It is in 135 files:

| Area | Files | Lines |
|---|---|---|
| test/behavior | 14 | 19 |
| test/reject | 21 | 21 (several are about the token itself) |
| test/ir | 1 | 1 |
| test/corpus | 86 | 140 |
| SPEC | | 6 |
| SYNTAX | | 8 |
| WELCOME | | 2 |
| FAQ | | 1 |
| DESIGN | | 2 |
| INTERNALS | | 7 |

The compiler side is `rig.grammar` (8 occurrences: the token, 4 productions
and messages) and `src/rig.zig` (11: the `ambiguous_fixed` rewrite check and
the `let`/`var`/`const` hints). typecheck, resolve, sema and ownership only
read `flags.fixed`, and module constants are rewritten to `fixed` internally
(`rig.zig:1607`), so the concept stays.

- **Option "a word" (`fix x = e`): S–M.**
  - The grammar swaps the token for a keyword prefix on the binding rule.
  - The `x =!y` ambiguity check and its message go.
  - The rest is a mechanical rewrite of about 135 files:
    `(\w+)( *: *[^=]+)? =! ` → `fix \1\2 = `.
  - The word `fix` is unused as an identifier in .rig files.
  - It removes `!`'s fourth meaning and the C trap in `s18`.
- **Option "drop fixed bindings": M.** It is more than syntax:
  - compile-time arguments accept "a `=!` binding of a constant"
    (`typecheck.zig:792-795`, SPEC §16);
  - emit's purity test treats fixed locals as pure (`emit.zig:4274`), which
    avoids hoisting;
  - both would need "never reassigned" inference before the binding is
    typed.
  - It also loses a stated intent.
- **Lean:** the word.

---

## 4. Emit honesty: what emit adds, and whether the checker sees it

Each row is an emit mechanism, its checker counterpart, a probe, and the
result.

| Emit mechanism (main) | Checker model | Probe | Result |
|---|---|---|---|
| Call-argument hoisting (`hoistsArgs`, `emitHoistedCall`, `hoist`; `__rig_call_/arg_/live_`), keyword reordering, owned args dropped when a later arg leaves | Arguments walked in source order; `holdArgRead` for place reads | `o01`, `d01`, `d02`, `e06`, `e08`, `e11`, `e12` | Agrees: source order, and drops on failure last-made-first, before locals |
| Receiver hoisting (`hoistReceiver`, `__rig_recv_`) | A reservation read loan on the receiver root | `a03`, `o01` | Agrees: a write in the args is rejected |
| `print` / `Text.of` / `add` tuples (by-value copies) | `holdArgRead` read loan (read-at-call model) | `u01`–`u08`, `t05`, `t06` | **Disagree: U1** |
| Assignment order (`openAssign`, `hoistIndices`, `__rig_new_/ix_/slot_`, `actsBeforeStore`) | `walkFieldAssign`, `walkIndicesHeld` | `a01`, `a02`, `a04`, `a06`, `o02` | Agrees after #31. `a04` gives the specified bounds panic. |
| `replace`/`swap` (`rig.replace(&place, v)`) | `walkSwapCall` with write borrows | `a01`, `a02` | Rejected (conservative) |
| Index and slice (`v.at(i)`, `rig.at`, `rig.slice(items, a, b)`) | Root held while indexes are walked | `e04`, `u12` | Agrees (`v[grow(!v)]` reads after the call, through the receiver pointer) |
| Match subject (`evalSubject`, `__rig_subject_`, catch-all rereads, guarded `__rig_match_`) | One subject walk; guards over bindings | `o02` | Subject, guard and index evaluated once, in order |
| Value blocks / ternary / `??` / `catch` (`__rig_blk_`, `__rig_if_`, `orelse`, `catch`) | Per-form walkers | `o01`, `e01`, `e02` | Agrees. Main rejects ternaries and `??` over owners as temporaries (Core §3 "moves nothing" is not built on main). |
| `@constCast` (Cell `set`/`replace`, `emitCellPtr`; `emit.zig:3938,3968`) | Sema "a Cell needs a place" plus `holdsCellByValue` ⇒ `var` | `c01`–`c04` | Sound: every Cell lives in a `var` (a fixed binding, a fixed array, a closure env, a `?T` param from a caller's `var`). Same result in ReleaseFast. |
| `rig.lend` (copy plain `?T`; `emit.zig:2767,2974,4744`) | A borrow with loans | `c03`, `u11` | Sound: a copy only when no Cell is inside, and loans forbid writes while it lives. The copy-vs-pointer rule is decided twice (runtime `ReadBorrow`, `sema.readBorrowCopies`); a disagreement would fail the Zig compile, not run wrong. |
| `rig.takeOut` (`<p.f` of an optional, `emit.zig:3103`) | `takes` fact | none needed | Sound |
| `rig.keep` (text-core, `emit.zig:2777`: drop-if-live then store) | `stmt_drops` / `holdTemp` | `t04` | Agrees: per-statement and per-iteration drops in order, short circuit and ternary skip the unmade |
| Temporaries compared with `none` or a variant (`rig.isNone`, `isVariantDiscard`) | Consuming position | `d03` | Main rejects owning temporaries in borrowed subjects |
| Drop-before-store in a place assignment (`rig.drop(slot); slot.* = new`) | Drop at the assignment | reasoning | Safe: a drop body cannot reach a local container, `*T` contents are immutable, and `Cell.set` stores first |

**Re-evaluation.** I found none. Compound assignments, match subjects with
catch-all rereads, guards, `if … as`, and joined `while` conditions each
evaluate once (`o02`).

**Count of the separate "temporary / order" models today:**
- **emit:** about 15 kinds of hidden name (`__rig_call_`, `arg_`, `live_`,
  `recv_`, `new_`, `ix_`, `slot_`, `subject_`, `whole`, `payload`, `opt_`,
  `blk_`, `if_`, `match_`, `env_`, …); about 275 lines of call hoisting,
  about 120 of assignment order, and about 470 of match.
- **ownership:** 55 lines touch `temps` / `arg_read` / `place_hold` /
  reservations.
- **typecheck:** 29 references to `lent_temp` / `lent_borrow` /
  `through_temp` / `lendsCellTemp`. text-core adds `temp_slots`, `rig.keep`
  and `stmt_drops`.

---

## 5. The lowering boundary

**Principle.** Emit chooses *representation* (a Zig type, `const`/`var`,
pointer vs copy for a plain `?T`, `@constCast`, `defer`). It never chooses
*order, lifetime, or how many times*. Every decision about order, lifetime or
count moves into a **Lower** pass that runs after typecheck and before
ownership. Ownership and emit both consume the lowered body.

**The lowered body** is the IR the checker already understands, plus three
node kinds:
- `(hidden name origin)`: a binding whose name carries the source span, for
  diagnostics;
- `(drop name)` at a known point;
- `(seq stmts… value)`: a statement-scoped block with a value.

No new ownership rules are needed: each lowered form is an existing one.

### What moves from emit into Lower

| # | Emit decision today | Lowered form | Retires (emit / checker) | New | Removed | Fixes |
|---|---|---|---|---|---|---|
| L1 | Argument order and hoisting; receiver hoisting; `print`/`Text`/`add` tuples; keyword reordering; owned-arg drop on a later leave | `__a_k = <arg as the parameter takes it>` in source order. A read of a non-plain place becomes `?place`, so the callee or `print` reads it at the call. Owned args get the hidden binding's normal drop. | `hoistsArgs`, `emitHoistedCall`, `hoist`, `hoistReceiver`, `consumedTemporary`, `isPureArg` / `holdArgRead`, `place_hold`, reservations, `arg_read` | ~400 | ~450 | **U1**, `print(v, grow(!v))` class; one purity fact |
| L2 | Assignment order (`openAssign`, `hoistIndices`, `actsBeforeStore`) | `__new = value; __ix_k = idx…; place[__ix] = __new` | `openAssign`, `closeAssign`, `hoistIndices` / `walkIndicesHeld` | ~150 | ~200 | Makes #31 structural |
| L3 | Match subject and guards (`evalSubject`, `subjectRereadable`, guarded blocks) | `__s = ?/!/< subject`; a guarded arm becomes `if pattern(__s) and guard` in a labeled block | `evalSubject`, `emitGuardedMatch`, and the subject special cases in ownership | ~250 | ~350 | W2/W3 guard bugs (batch B) |
| L4 | Statement temporaries (text-core `temp_slots`, `rig.keep`, `stmt_drops`, `holdTemp`, `keepViewTemps`) | `__t = e` scoped to the statement, `(drop __t)` last-made-first on every exit | the three temporary models | ~600 | ~900 | The 8 text-core bug classes (root-cause §3.1) |
| L5 | Value sugar: ternary, `??`, `catch`, `e?`, `e!`, `if/while … as` (joined), value loops | `match` on tag plus labeled `seq`/`break` | per-construct walkers in both passes | ~1,500 | ~2,000 | Most W2 |
| L6 | `defer`/`errdefer` (`markReturningBlocks`, `runDefers` re-walks) | Explicit cleanups at each exit | `ret_block`, `markReturningBlocks`, `checkDeferBody` re-walks | ~300 | ~400 | review1 #5 class |
| L0 | (prerequisite) one fact per question: `ValueClass`, purity, "acts", the copy-vs-pointer rule for `?T` | facts in the table, read by Lower and emit | `isPureArg`, `actsBeforeStore`, `isPlace`, and emit's own `isOwnedValue` | ~300 | ~400 | §8 |

**What stays in emit, as representation only:**
- Zig types;
- `const` vs `var`;
- `rig.lend` (copy) vs pointer for a plain `?T`, read from one fact;
- `@constCast` for Cell methods, justified by the sema rule "a Cell has a
  place";
- `defer` guards and alive flags generated from Lower's drop list;
- closure environment layout.

### Order of work

1. **Now, S, about a day.** Fix U1 with emit fix (a): `print`, `Text.of` and
   `add` take place reads by `rig.Ref`. Add the matrix row and keep `u01`–`u08`
   and `t05`/`t06` in `test/corpus`. This is a one-site change in L1's
   direction.
2. **L0, M, 3–5 days.** Settle the facts once. It needs no change to the
   emitted shape.
3. **L1 and L2 together, M, about 1 week.** Calls and assignments become
   hidden bindings. `holdArgRead` and `openAssign` are deleted. The suite
   only compares stdout, so the shape change is safe to land behind the
   corpus and the sanitizer.
4. **L4, M–L, 1–2 weeks.** Land text-core's statement temporaries *as* L4
   instead of as a third model. This is where lowering pays most.
5. **L3, then L5, then L6, L, 3–4 weeks.** The surface stays frozen for
   ownership.

**Net code:** about flat to −700 lines through L4, and −1.5k to −2k after
L6.

**Speed cost:** one linear pass. At 48k lines, typecheck takes about 224 ms
CPU (Debug), so Lower should cost about 10–20% of that. That is small next to
the quadratic generic passes (§6).

---

## 6. Speed of `rig check`

**Method:**
- Scratch copy with per-phase timers (`probes/emit/speed/timer.patch`;
  `RIG_TIME=1`).
- Synthetic input from `speed/synth.py`: a 110-line unit repeated N times,
  with enums, matches, struct methods, a generic `Stack[T]`, generic
  `sort`/`map`/`max` with closures, borrows and moves.
- All sizes are accepted, and the run is leak-free.
- Times are CPU ms, the minimum of 2–3 runs, since the shared machine had a
  load of 2–8.

### Debug build (`zig build`), CPU ms

| Phase | 4.8k lines | 19.3k lines | 48.2k lines |
|---|---|---|---|
| Lex + parse | 17.5 | 69 | 175 |
| Rewrite | 2.9 | 11 | 30 |
| Resolve (symbols and declarations) | 11 | 44 | 104 |
| Typecheck | 22.5 | 90 | 224 |
| `check_frames` and unread locals | 4 | 16 | 47 |
| **`expandInstantiations`** | 1.3 | 19 | **122** |
| **`checkGenericInstantiations`** | 12.8 | 200 | **1224** |
| Ownership | 17 | 70 | 183 |
| **Total check** | 91 | 527 | **2127** |
| Emit | 22 | 90 | 230 |

### ReleaseFast build

| Size | Total check | Generic instantiations |
|---|---|---|
| 4.8k lines | 9.4 ms | |
| 19.3k lines | 54 ms | |
| 48k lines | 225 ms | 135 ms |

### Findings

- **Everything is linear except the two generic-instantiation passes, which
  are quadratic.** They roughly quadruple each time the input doubles. At
  48k lines they take **63%** of check time, in both builds.
- **The hot spot** is `checkInstanceSizes` (`typecheck.zig:8475`), about 53% of
  samples at 48k lines. Each type and function instance (457 + 1820) scans
  every `generic_frame` (2730) and calls `sema.usesParams` (`sema.zig:1817`),
  which recurses through `typeChildren`. That is about 6.2M calls.
- **The same pattern** appears in `expand` (`sema.zig:1599,1630`, over every
  generic use) and `checkSelfNesting` (`sema.zig:1570→1708`).
- **The fix, S–M:** index `generic_frames`, `generic_arrays`,
  `generic_uses` and `generic_fn_uses` by their owning generic declaration,
  so each instance visits only its own entries.
- **For comparison, the external Zig compile dominates every real run:**
  - `rig run` of 4.8k lines: 1.24 s cold, against 16 ms for rig itself in
    ReleaseFast;
  - `rig run` of 19k lines: 2.05 s cold;
  - `rig build --release` of 4.8k lines: 4.7 s.

---

## 7. Corrections to the Core

1. **S10, "`!`, `catch`, or `??`":** `??` does not handle failures (`g11`).
   Write "`!` or `catch` (whose handler may be a value, a named error, a
   block, or a jump)".
2. **S10 and decision 3, the scope of "a bare error value on the last line".**
   The silent forms are wider: branch and arm values, value-loop `break` and
   `else`, closure tails, tail `if` statements, and any error-typed
   expression (a call, a field, a binding) where `T!` is expected. State the
   rule as **"an error value meets `T!` only as the operand of `return`"**.
   It is one site (`compatible`), and it was prototyped and measured (§3.1).
   `return e` with a binding stays legal: the `return` is the writing.
3. **S10 status.** "Mostly built" is right for calls. For "failing is always
   written" it should read "**built for calls; open for values**".
4. **§7 `-x`.** The single rule has two exceptions to name or remove:
   - `-call()` as a statement is a discarded negation (`s23`); reject it like
     `-p.f`.
   - "statement" means the line's value is unused, so a `fun`'s tail
     negates and a `sub`'s tail drops (`s05` vs `s26`).
5. **§7 receiver sigils.** Accurate. Add "and no other prefix ever reaches
   the receiver".
6. **§7 add the habits that still change meaning silently,** or document them
   in WELCOME:
   - `ok =! done` (decision 5 removes it);
   - a write call's `Bool` used as a value (decision 6 removes it);
   - unlabeled `break` inside `match` leaving the loop (a C habit);
   - Python `/` and `%`;
   - Swift `u?.n`;
   - `e catch a if c else b` grouping.
7. **The AGENTS rule "the checker checks exactly what is emitted"** has one
   live violation: U1. The Core's "Only code inside `raw` may break these
   rules: built" is false until U1 is fixed.
8. **§3 "a `print` or `Text(...)` argument is only read".** On main, an owning
   ternary or `??` in a `print` argument is still rejected as a temporary
   (`e01`, `e02`). That part of §3 is decided, not built, on main.
9. **§8:** add "read borrow representation (copy vs pointer)" and
   "evaluation purity" to the per-expression facts. Emit and the runtime
   decide them today (§4).

---

## 8. Probe index (`probes/emit/`)

- **Unsound / wrong output:** `u01`–`u08`, `text/t05`, `text/t06`.
- **Failure:** `f01`–`f26`, `g01`–`g12`, `h01`, `mod/f20`–`f23`.
- **Syntax habits:** `s01`–`s32`.
- **Evaluation order, assignment, drops and re-evaluation:** `e01`–`e12`,
  `a01`–`a06`, `d01`–`d03`, `o01`–`o03`, `text/t01`–`t04`.
- **Cell and `@constCast`:** `c01`–`c04`.
- **Prototype for decisions 3 and 6:** `proto-d3-d6.diff`, with its measured
  impact in `proto-d3-d6-newly-rejected.txt`.
- **Speed:** `speed/` holds the timer patch, the generator, the bench script
  and the profile head.
