# Temporaries in Rig: one rule

Question: what is the cleanest rule for values that have no name
(temporaries)? It should be easy to explain, easy to check, and hard to
get wrong.

Method: I read AGENTS.md, docs/DESIGN.md, and SPEC §7 (Temporaries) and
§10 (Text) on `text-core`. I read the temporary code in `typecheck.zig`,
`ownership.zig`, `emit.zig`, and `runtime.zig`, built the branch, and ran
probes. The probes are in `scratchpad/seams/temps/`: `five.rig`,
`e1.rig` to `e5.rig`, `p.rig`, `p2.rig`, and `m1.rig` (run against
main). No repository was edited.

---

## 1. What the branch does today

### The rule (SPEC §7 "Temporaries")

The section has about 19 sentences in two paragraphs, plus lists of
exceptions. It says three things:

1. **Freshness.** A value is a temporary only if it is "fresh":
   - a call's result, `*x`, `+x`, `<x`, or a literal;
   - or an `if`, `match`, `??`, `catch`, block, `e!`, or `e?` whose
     branches are all fresh.

   Anything else with an owner, such as `o?` or `a if c else b`, is
   rejected wherever it is only read.
2. **Lifetime.** A fresh value that is only read lives until the end of
   its statement. The places where a value counts as only read are
   listed: a `print` or `Text` argument, an `==` operand, a `match`
   subject, a field or element read, or `?`.
3. **Header extension.** Temporaries made in an `if`, `match`, or `for`
   header live through the whole statement. Temporaries in a `while`
   header live for one pass.

### The machinery

- **typecheck.zig**
  - `handsOverFresh`: the whitelist predicate. It covers 10 node kinds
    and has 11 call sites.
  - `rejectNotFresh`, `readTemp`/`synthReadTemp`, `lendTemp`, and
    `rejectResourceTemporary` (9 sites).
  - `through_temp`, `synthPath`, and `checkPartOfTemp`, for reading part
    of a temporary.
  - A separate "take the whole value" path for `??`.
  - `recordCellTemp`.
  - In total, about 8 places record temporaries and about 12 functions
    decide.
- **ownership.zig**
  - One hidden variable per temporary (`holdTemp`), named by its source
    text. It is dropped by `dropStmtTemps` at the end of the statement.
  - `reportTempOutlived`, `isStmtTemp`, and `keepViewTemps`.
  - A check at if-joins for loans on statement temporaries.
  - Per-pass drops in `loopIteration`.
  - A `match` subject held as a hidden variable.
- **emit.zig and runtime.zig**
  - Before each statement: a slot, a live flag, and a `defer` for each
    temporary (`emitTempSlots`).
  - `rig.keep(&slot, &flag, value).*` wherever the temporary appears.
  - Drops after the statement, last made first.
  - A `resets` label so a `while` condition drops the previous pass's
    slots.
  - `rig.keep` itself also drops a value that is still live from an
    earlier pass.

The temporary work adds roughly 450 net lines of source across six
commits, plus about 830 lines of tests.

### What the probes found (all runs are leak-checked)

**All five target lines work** (`five.rig`):
- `print(Text("a", n))`
- `text.trim(?Text(" a ")) == "a"`
- `if text.cut(?Text("k=", n), "=") as kv`
- `d = maybe(0) ?? Text("default")`
- `print(mkv()[i])`

**Conditional temporaries and failure paths are handled** (`e1.rig`,
`e2.rig`, `e3.rig`). This covers temporaries in ternary branches, in
`and`/`or`, inside `defer`, in `+=`, in match guards, in closures, in
loop values, and in returns from inside an `if … as` body. A view of a
header temporary pushed into an outer `Vec` is rejected with a clear
error (`e4.rig`). I found nothing unsound.

**The seams the user is feeling:**

1. **A read-only method call on a temporary is rejected, but a field
   read is accepted.**
   - `print(mk(5).get())` fails with "this `B` is a temporary that owns
     a resource … bind it to a name first".
   - `print(mk(5).n)` works.
   - `count(?make())` works but `make().count()` does not. The SPEC
     even has a reject example for this.
2. **Plain reads of names fail with "is not a fresh value".** Each of
   these is a harmless read of a name:
   - `print(a if c else b)`
   - `print(Text("x") if c else a)`
   - `print(o?)`, `print(o?.len)`, `print(o? == "hi")`, `print(o?[0])`,
     `print(text.trim(?o?))`
   - `print(o ?? a)`

   `test/reject/ownership/not_fresh_owner_read.rig` asserts 8 such
   errors. The whitelist design forces this: a name is only safe as
   "not a temporary", so every compound form that might contain a name
   has to be rejected.
3. **Temporaries in a condition live longer than in Rust, and longer
   than the SPEC says** (`e5.rig`):

   ```
   if mk(1).n == 1          →   then-body
     print("then-body")          drop 1
   while mk(10+i).n < 12     →   while-body 0
     print("while-body", i)      drop 10 ...
   ```

   Rust treats the condition of `if` and `while`, a match guard, and
   each operand of `&&`/`||` as its own temporary scope. There, `mk(1)`
   is dropped before the body runs. Only `if let`, `while let`, and
   `match` scrutinees are extended in Rust. Even those are being pulled
   back: the 2024 edition drops `if let` temporaries before `else`, and
   the `significant_drop_in_scrutinee` lint exists because the extension
   caused deadlocks. The SPEC's "As in Rust" claim is wrong for plain
   conditions. Rig extends further than Rust does.
4. **Only tests use borrows of temporaries.** No example, no `std`
   module, and none of WELCOME, SYNTAX, or DESIGN uses a borrow of a
   temporary (`?Call(...)`) or header extension. The one doc use is
   `print(Text("bye ", name).len)` in WELCOME.md. Header extension
   appears only in tests written for it:
   - `temporary_views_in_statement.rig`
   - `borrowed_temporary_lives_for_statement.rig`
   - `cell_in_literal_field.rig`
   - `temporary_field_read.rig`

### Where the four review rounds found bugs

| Bug class | Root cause |
|---|---|
| Views escaping through `if … as` bodies | Header extension |
| Branch joins losing loans | Header extension (checking temporary loans at if-joins) |
| Moving arms of `match` on a temporary | The match *reads* a temporary instead of *taking* it |
| Drop order on failure paths | Inherent to any rule that allows several temporaries per statement plus `!`/`?? return` |
| Ternaries over names counted as temporaries | The freshness classification of compound forms |
| `o?` counted as fresh | The freshness classification |
| `??` consuming names | The freshness classification, plus `??` choosing "take whole" in a read position |

Six of the seven classes come from three design choices:
- deciding freshness over *compound* expressions;
- extending lifetimes through bodies;
- having `match` read a temporary.

None of the six comes from the core idea, "an unnamed value lives until
the end of its statement". That core (a hidden variable in the checker;
a slot and flag in emit) has held up in every round.

---

## 2. The designs

The five target lines, used as rows in the tables:
1. `print(Text("a", n))`
2. `text.trim(?Text(" a ")) == "a"`
3. `if text.cut(?Text(..), "=") as kv`
4. `maybe() ?? default`
5. `mkv()[i]`

### A. Keep the current Rust-style rule

- **User-visible rules:** about 19 sentences, plus two lists of
  exceptions. A Python or Ruby newcomer understands the first sentence
  ("dropped at the end of the statement"). They will not understand
  "fresh", why `print(a if c else b)` or `print(o?.len)` fails, or why
  `mk().get()` fails when `mk().n` works.
- **Checker complexity:**
  - typecheck: about 12 functions over 8 read sites; freshness has
    10 node kinds.
  - ownership: 6 paths (statement drop, if-join check, per-pass loop
    drop, match hidden subject, `keepViewTemps`, `reportTempOutlived`).
  - emit: 6 paths (slots, `keep`, statement drops, value-body slots,
    block-tail slots, `while` resets).
- **Bug surface:** all seven classes are possible. They are fixed
  today, but each new form (a new operator, a new header kind) has to
  be added correctly to the freshness predicate and to the extension
  logic.
- **Expressiveness:** all five lines work. Line 4 in a read position
  fails when the fallback is a name (`print(o ?? d)`).
- **Migration:** none.

### B. Pure desugaring into named bindings before checking

The idea: rewrite `print(Text("a", n))` into
`{ __t1 = Text("a", n); print(?__t1) }`, so the checker only ever sees
names. That is attractive, and it is how the SPEC should *explain*
temporaries. As a compiler pass, though, it gets these things wrong
unless it restructures control flow:

- **Evaluation order.** In `print(next(), Text("u", next()))`, hoisting
  the `Text` runs the second `next()` first. The fix is to hoist every
  earlier sibling along the path to the statement root: receivers,
  earlier arguments, left operands, and the place in `a[f()] = …`. That
  means inserting `<` moves and naming borrows (`__a = !v`), which can
  change what is accepted.
- **Short-circuit `and`/`or`.** In `ready and starts_with(?Text(read()!), "go")`,
  hoisting runs `read()!`, allocates, and may fail even when `ready` is
  false. The fix is to rewrite the expression into a nested `if` with a
  branch-local binding. The temporary then dies at the end of the
  branch, not the statement.
- **Ternaries.** `print(trim(?Text(a)) if c else "none")` either
  evaluates `Text(a)` eagerly, or needs a binding that is created
  conditionally and a borrow through it. Rig has no named form for
  that; it is exactly the slot and flag the emitter already uses. With
  branch-local bindings, the view cannot leave the branch, so the line
  is rejected.
- **`??` and `catch`.** The fallback and the handler are lazy. The whole
  `a ?? b` can be hoisted, but a temporary *inside* the fallback cannot.
- **`else if` chains.** A later header is evaluated only if the earlier
  ones fail. The rewrite must nest each one into the `else` block.
- **`while` headers.** Hoisting evaluates the header once. The rewrite
  must turn the loop into `while true` with `if … else break`, and then
  rebuild the step (`: step`), `continue`, `while … else`, and loop
  values (`break v`, the `else` value). Diagnostics then refer to
  synthesized `break`s.
- **Match guards.** A guard runs only when its pattern matches, and a
  failed guard falls through to the next arm. That cannot be expressed
  as a block around the arm.
- **`defer`.** Hoisting `defer print(mk().n)` evaluates `mk()` when the
  `defer` is registered, not when the scope ends. The binding has to go
  inside the deferred body.
- **Closures and a `while` step.** Each needs its own statement scope.
- **Types are needed.** To know what owns a resource, the pass must run
  after typecheck. Otherwise it hoists every call result, which rewrites
  all emitted code and needs care in generics.

The alternative is to hoist everything and fix the order afterwards,
which is ANF (a-normal form). ANF is a large new pass: about 15 forms,
each with its own scoping rule.

Summary for B:
- **User-visible rules:** about the same as the recommended design (F,
  below), plus caveats wherever the desugaring is not literal.
- **Checker complexity:** ownership needs no change. typecheck still
  needs the classification, since the pass must know what to hoist.
  emit needs almost no change but must handle the synthesized forms.
  The new pass adds a large amount of new work.
- **Bug surface:** rules out, by construction, views escaping `if … as`
  bodies, match moves, branch joins, and failure-path drop order (names
  get these right already). The ternary, `o?`, and `??` classes become
  *wrong diagnostics* rather than unsoundness: hoisting `a if c else b`
  gives `__t = a if c else b`, which the checker rejects as a bare
  owner. B adds a new class of its own: **silently changing evaluation
  order or laziness**. That breaks "no silent control flow", and no
  checker can catch it.
- **Expressiveness:** lines 1, 2, 3, and 5 work. Line 4 works in a
  binding; in a read position, a named fallback is rejected.
  Conditional views are lost.
- **Migration:** large.

**Main point about B:** the branch already does B *inside the ownership
checker*. `holdTemp` creates a hidden variable named after the source
text, and every rule for names applies to it. Meanwhile the emitter
keeps source order by placing `rig.keep` inline. A separate desugaring
pass would add an ANF rewrite to remove very little.

### C. Temporaries only as direct arguments of calls and `print`, dropped after the call

- **User-visible rules:** about 3 sentences: "An unnamed value may be
  passed to a call or `print`; it is dropped when that call returns,
  and the call's result may not borrow it." A newcomer understands
  this, but is surprised that `print(trim(?Text(x)))` fails: "I'm just
  printing it."
- **Checker complexity:**
  - typecheck: one test at arguments ("is this argument a call result?").
    Main's existing "the result keeps no borrow" check is reused.
  - ownership: the loan ends with the call.
  - emit: a labeled Zig block with a `defer` around the call. The
    call's earlier arguments must also be bound to keep evaluation
    order. There are no statement slots and no flags.
  - About 3 paths in total.
- **Bug surface:** rules out every class except failure-path drop order
  in the call's local block, and Zig's `defer` handles that
  structurally. It is essentially main's rule plus owning arguments.
- **Expressiveness:**
  - Line 1 works.
  - Line 2 fails, because `trim`'s result borrows the argument.
  - Line 3 fails.
  - Line 4 works in a binding and fails as a `print` argument.
  - Line 5 fails, unless C is widened so the "operation" includes field
    and element reads. That widened version (C′) gets line 5.
- **Migration:** moderate. Undo most of the branch and keep the Text
  work.

### D. The strict rule plus targeted conveniences

Keep main's "bind it first". Make `Text(...)` directly inside `print`
format in place, or add a `print` that writes no separators.

- **User-visible rules:** main's 2 or 3 sentences, plus a special case.
- **Checker complexity:** about 2 paths. There is no temporary lifetime
  at all.
- **Bug surface:** none of the seven classes can occur.
- **Expressiveness:**
  - Line 1 works, through the special case.
  - Lines 2, 3, and 5 fail. `mk().len`, `mkv()[i]`, `f(?g())`, and
    `trim(?read()!) == "q"` all need a name.
  - Line 4 works in a binding only if the branch's `??` change is kept.
    Main rejects `x = opt(0) ?? mk(3)` (probe `m1.rig`).
- **Conflict with the design principles:** a `Text` that behaves
  differently inside `print` is "a special case" (DESIGN: "the language
  gains a general feature, never a special case").
- **Migration:** revert. Most of the temporary tests are lost.

### E. Other options

- **An arena per statement.** Rejected. Drop bodies such as a `File`'s
  must still run. A value moved out of the statement would sit in the
  arena. And it is a hidden allocation strategy.
- **Formatting `Text(...)` in `print` without allocating.** Good, but as
  an **optimization** of whatever rule is chosen, not as the rule. Text
  has no user-visible drop, so skipping the allocation cannot be
  observed.
- **Requiring `?` on every read of a new value** (`print(?Text(..))`,
  `(?mk()).len`). This is more visible but noisy, and removes none of
  the machinery.
- **Rust's actual rule.** Temporary scopes would be: the statement, the
  condition, each branch of an `if`, each match arm, and each operand
  of `and`/`or`. Some conditional temporaries become impossible, but
  the rule takes about 7 kinds of scope to explain, and the emitter
  still needs drop flags for failure paths. No better than F.
- **F: statement temporaries decided by position, with headers as
  statements.** Recommended; described below. This is the C++
  "full-expression" rule: a temporary is destroyed at the end of the
  full expression, and the condition of `if` or `while` is a full
  expression of its own. C++ has used it for decades; its one footgun,
  dangling references, is what Rig's checker already prevents.

---

## 3. Comparison

Lines 1 to 5 are the target lines listed in section 2.

| | A (current) | B (desugar) | C (call args) | D (strict+) | **F (recommended)** |
|---|---|---|---|---|---|
| SPEC sentences | ~19 plus exception lists | ~7 plus caveats | ~3 | ~3 plus a special case | **~6** |
| A newcomer gets it | first sentence only | mostly | yes, but chaining surprises | yes, but it's strict | **yes: "unnamed values last until the end of the line; a condition is its own line"** |
| typecheck paths | ~12 functions over 8 sites | same, plus a new pass | 1 | 1 | **1 function plus the read sites** |
| ownership paths | 6 | 0 (plus a large pass) | 1 | 0 | **3, all existing** |
| emit paths | 6 | about 0 | 2 | 1 | **4 (resets removed)** |
| Bug classes ruled out by construction | 0 of 7 | 4 of 7, adds order bugs | 6 of 7 | 7 of 7 | **6 of 7 (failure drop order remains; it is solved and tested)** |
| 1 | yes | yes | yes | yes (special case) | **yes** |
| 2 | yes | yes | no | no | **yes** |
| 3 | yes | yes | no | no | **no: bind first** |
| 4 in a binding | yes | yes | yes | only with the `??` fix | **yes** |
| 4 in a read (`print(o ?? d)`) | no | no | no | no | **yes** |
| 5 | yes | yes | no (C′: yes) | no | **yes** |
| `mk().get()` | **no** | yes | yes | no | **yes** |
| `print(a if c else b)`, `print(o?.len)` | **no** | no | n/a | n/a | **yes** |
| Migration | none | large | moderate | revert | **moderate (~2 days)** |

---

## 4. Recommendation: F, "the statement is the scope of an unnamed value"

### Are Rust-style temporaries worth their cost in Rig?

**The core is worth it. The extensions are not.**

"An unnamed value is dropped at the end of its statement" is the rule a
Python or Ruby programmer already assumes. It lets these just work:
- `print(Text(..))`
- `mk().len` and `mkv()[i]`
- `f(?g())`
- `trim(?read()!) == "q"`

It also fits the model Rig already has: a named value's scope is its
block, so an unnamed value's scope is its statement. It costs about 250
lines, and it has been sound through every review.

Three things on the branch are not worth their cost:
- **Classifying compound expressions as "fresh."** This causes three
  bug classes and the "not a fresh value" errors on harmless reads.
- **Extending lifetimes through bodies.** This causes two bug classes,
  the per-pass loop code, the checks at if-joins, and drop timing later
  than Rust's. It is used only by tests.
- **A `match` that reads a temporary.** This causes one bug class.
  `for` over a call result, and `if call() as x`, already *take* the
  value.

### The SPEC wording (replaces the prose of §7 "Temporaries")

> An expression either **takes** its value (a binding, an argument to a
> parameter that owns it, `return`, a field or element it is stored in,
> `<`) or only **reads** it (a `print` or `Text(...)` argument, an `==`
> operand, `?e`, a `?self` receiver, the value a field or element is
> read from). Reading never moves a name, whatever form reads it:
> `print(a if c else b)`, `print(o?.len)`, and `print(o ?? d)` move
> nothing. A value made where it is only read (a call's result, a block
> or `match` value, `+x`, `*x`) has no name, so its statement is its
> scope: it is a **temporary**, dropped when the statement ends, the
> last made first, also when the statement fails or leaves early. A
> borrow of a temporary, or a view made from one, may be used only in
> its statement. An `if` or `while` condition, a guard, and the subject
> of a `match` or `for` are statements of their own, so their
> temporaries are dropped before the body runs. A call's result that
> `if … as`, `while … as`, `match`, or `for` binds is taken, as `<e`
> would take it.

That is 6 sentences, with no lists of exceptions. The existing rules
still apply around it: a bare owner must be moved with `<`, and
`_ = e` discards a value.

Two examples to go with it:

```rig
print(Text("n=", n))                    # dropped after the print
print(text.trim(?read()!) == "quit")    # the view is used within its statement
line = read()!                          # to keep a view past the line, name the value
if text.cut(?line, "=") as kv
  print(kv.before)
```

```rig reject
if text.cut(?Text("k=v"), "=") as kv    # the header is its own statement
  print(kv.before)
```
```error
a borrow of the temporary `Text("k=v")` outlives its statement, which drops it; bind the value to a name first
```

### Why this rules out the bug classes by construction

- **Freshness is never asked of a compound form.** In a read position,
  the forms `a if c else b`, `a ?? b`, `a catch b`, `e!`, and `e?` pass
  the read on to their operands. The *leaves* decide:
  - a place (a name, or a field or element path) is read where it is,
    and nothing is dropped;
  - anything else that owns a resource is a temporary.

  A name can only become a temporary through a visible sigil (`<x`,
  `+x`, `*x`). This rules out the ternary, `o?`, and `??`-consumes-name
  classes.
- **Blocks and `match` values count as new values.** Their inner value
  is taken out of their scope, as a returned value is, so a block-local
  or arm-local name there must be `<t`. This closes the one trap that
  passing the read through would open, a block-local name read after
  its block ends.
- **Headers are statements.** The `as` binding is checked at the header
  boundary by the same `dropStmtTemps` path as `r = ?S(n: 1)`. Nothing
  borrowed from a temporary reaches a body. This rules out the if-body
  escape and branch-join classes.
- **A `match` on a call's result takes it**, exactly as `match <e`
  already does (`match <mko()` is accepted today, probe `p2.rig`). Arms
  own their payloads, so the named rules apply. This rules out the
  match-move class.
- **Failure-path drop order** is the one class that remains. It is
  inherent whenever a statement can make more than one temporary and
  also fail. It is solved already: slots are declared in the order the
  values are made, and the `defer`s drop them last first. The tests
  cover it.

### Implementation sketch (starting from `text-core`)

**typecheck.zig**

1. Add `reading: bool` to the Checker, set at the existing read sites:
   - `print`, `Text`, and `add` arguments (about line 4895);
   - `==` (about 2868);
   - `?e` (`synthBorrow`/`lendTemp`);
   - a field's object (about 3597) and an element's object (about 4290
     and 4303);
   - and, new, a `?self` receiver (about 6306, where
     `rejectResourceTemporary` currently fires).
2. Write one function, `readLeaf(e, ty)`:
   - for `if` (inline ternary), `??`, `catch`, `propagate`, and
     `propagate_none`: recurse into the value operands;
   - for a place path: if its base is not a place, `readLeaf(base)`,
     which reads through the temporary; otherwise do nothing;
   - for anything else with drop glue: `recordTempDrop(e)`.
3. Delete:
   - `handsOverFresh` and `rejectNotFresh`;
   - the `takes_whole` path in `??` (in a read, `??` never consumes;
     where a value is taken, the ordinary bare-owner rule covers it);
   - `through_temp`, `synthPath`, and `checkPartOfTemp`. When a value is
     taken, an owning field of a temporary is rejected by one check.
4. A `match` subject that is a new value is checked as `match <e`.
   Header conditions change nothing in typecheck.

Net effect: about 150 lines removed and 60 added. Freshness becomes a
closed switch over 5 kinds that pass the read through, plus a leaf
test. The leaf test fails safe: an unknown kind either becomes a
dropped temporary or is rejected, and never makes a name into a
temporary.

**ownership.zig**

1. Keep `holdTemp`, `dropStmtTemps`, `stmt_drops`, and
   `reportTempOutlived`. This is B, already inside the checker.
2. Walk `if`/`while` conditions, guards, and `match`/`for` subjects
   through `walkStmtValue`, so they are statement boundaries.
3. Delete:
   - the per-pass drops in `loopIteration` (`drops`, `body_end`);
   - the statement-temporary check at joins added in c30c385;
   - the case that holds a `match` subject in a hidden variable.

About 50 lines removed.

**emit.zig and runtime.zig**

1. Keep `emitTempSlots`, `rig.keep`, the flags, and `writeTempDrop`.
   Flags are still needed for temporaries under `and`, `or`, `?:`,
   `??`, and `catch`, and for failures that happen before a slot is
   filled.
2. Emit each header as a labeled block that owns its slots:
   - `if (c: { <slots>; const v = <cond>; <drops>; break :c v; }) |x| …`
   - the same for `while` (Zig evaluates it on every pass) and for guards.

   Zig's `defer` inside the block drops on `try` failure as well. Check
   that `?? continue` in a `while` header still lowers correctly inside
   the block.
3. Delete the `resets` label machinery, and the branch in `rig.keep`
   that drops a value still live from an earlier pass.
4. Emit a `match` over a new value as `match <e` is emitted.
5. Optional (option E): when `Text(...)` is a direct `print` argument,
   format it in place without allocating.

**Tests and docs**

- Tests to rewrite so they bind first, or to turn into reject tests:
  - `temporary_views_in_statement.rig` (the `if … as` and `while … as`
    lines);
  - `borrowed_temporary_lives_for_statement.rig` (`if ?opt(3) as p`
    becomes `if opt(3) as p`);
  - `cell_in_literal_field.rig` (`if ?mk().o as p`);
  - `temporary_field_read.rig` (`for n in ?mv()` becomes
    `for n in mv()`).
- Tests that become accepted behavior tests:
  - `not_fresh_owner_read.rig` (all 8 errors become reads);
  - `temporary_branch_names_owner.rig`;
  - `fallback_not_fresh.rig`;
  - `temporary_match_moves_payload.rig` (the move is now allowed).
- Reject tests whose header errors come from the new rule:
  - `if_header_view_escapes.rig`;
  - `if_value_header_view_escapes.rig`;
  - `while_header_view_one_error.rig`.
- Add behavior tests:
  - `e5.rig`: the condition's temporary is dropped before the body;
  - `print(mk().get())`.
- Update the text in SPEC §7 and §10, WELCOME ("dropped when its
  statement ends" stays true), and the `dropsTemp` row of the
  INTERNALS table.

### What F gives up, stated plainly

- **Line 3**, `if text.cut(?Text(..), "=") as kv`, and the same form for
  `while` and for `for` over a borrowed call result, now need one extra
  line to bind the value first. Nothing outside the tests uses this.
  C++ makes the same trade and, unlike Rig, dangles silently. If real
  code later shows a need, the smallest extension to add is Rust 2024's:
  an `if … as` header's temporaries live through its then-block only.
  Add it as its own feature, with its own tests.
- **Drop timing moves earlier** for temporaries in conditions. This
  matches Rust and C++, and matches what a reader expects.
