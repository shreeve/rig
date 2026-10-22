# Why Rig's recent work keeps producing soundness bugs, and how to stop it

Read-only diagnosis, 2026-09-30. Nothing in either checkout was edited. All
probe programs and sweep outputs are in this directory (`seams/`).

## 0. The short version

- **The bugs are not random.** Almost every one of them comes from one of
  three weak spots in how the compiler is built. The same kinds of bug come
  back days apart in new clothes. That is the signature of a design gap, not
  of careless coding.
- **The three weak spots:**
  - **W1. Every part of the compiler decides for itself what kind of value
    an expression is.** The kinds are: a named place, a fresh value nobody
    owns yet, a borrow, or a view. Each part decides by looking at the
    syntax, often by elimination ("not a name, so it must be a temporary").
  - **W2. Control flow is coded by hand for each construct.** `if`,
    `if … as`, `match` with guards, `??`, `catch`, `while … as`, `for`,
    `defer` and the rest each have their own code. The basic "save the state
    and return to it" step quietly throws away borrows instead of reporting
    them. Each construct must remember to check first, and some forget.
  - **W3. The checker and the emitter each build their own picture of the
    program.** The ownership checker reasons about the source tree. The
    emitter then writes a different program: it adds temporaries, picks the
    evaluation order, adds drops and re-evaluates expressions. It also
    settles for itself what a name like `X.name` means. Nothing checks that
    the two pictures agree.
- **I found a live memory-safety hole on `main` today, in the W3 class.**
  `v[0] = grow(!v)` and `b.xs[0] = mk(!b)` are accepted. The emitted Zig
  takes a pointer to the element first and runs the call second. If the
  call reallocates or frees the buffer, the store lands in freed memory.
  The Debug run reports nothing: no panic, no leak, only a wrong value.
  This is the sibling of `print(v, grow(!v), v)`, which was fixed on 09-29
  for call arguments only.
- **The test oracle cannot see this kind of bug.** Debug runs catch leaks
  and double frees. They do not catch reads or writes to freed memory,
  because freed memory is neither poisoned nor unmapped. "Runs clean under
  the checking allocator" therefore does not mean "memory-safe".
- **What would make these bug classes impossible, not just rarer:** lower
  the program to a small core before checking. A temporary becomes a named
  hidden binding. Evaluation order becomes explicit statements. `??`, `?`,
  `if … as`, guards and ternaries become a few core forms. Then the
  ownership checker checks exactly the program the emitter writes. Every
  one of the eight bugs in the "temporaries dropped at statement end"
  feature would have been rejected by rules the checker already had
  (§3.1).
- **Is it coming apart? No, but its safety now rests on reviewer stamina.**
  - Fixes stick: 1,046 old probe programs gave 0 unsound results, and main
    has 0 known bugs with CI green.
  - Consolidations have worked.
  - But code grew 73% in 7 days, and each ownership-touching feature needs
    2–4 review rounds.
  - Bug classes recur within days, and the one live hole I found is
    invisible to the test oracle.

---

## 1. What I looked at

- **Docs:** AGENTS.md, docs/DESIGN.md, and docs/INTERNALS.md (Pipeline,
  Sema, the facts table, Ownership, Emit).
- **The ledger:** `.git/revamp/ledger.md`, all of it. This includes
  REVAMP-2, POST-REVAMP and STDLIB PHASE.
- **The audits:** the critical and high rows of all 23 `audit-*.md` files,
  and in full `audit-ownership.md`, `audit-typecheck.md` and
  `audit-tests.md` (all from REVAMP-2).
- **The text-core branch:** its 15 commits (`origin/main..text-core`), with
  the full diffs of:
  - `77cc5a5`, the feature;
  - `d66d8f0`, `c30c385` and `59e7bed`, the fix rounds;
  - `729e692` on main, the `print(v, grow(!v), v)` fix.
- **The code:**
  - on `main`: `ownership.zig`, `typecheck.zig` and `emit.zig`;
  - on `text-core`: the classification, temporary and join code.
- **Probe sweeps.** I exported both branches with `git archive` into
  `seams/main` and `seams/text` and built them there, so the checkouts
  stayed untouched. `seams/one.sh` sorts each probe into one of these:
  - rejected;
  - runs clean;
  - panic;
  - leak;
  - Zig compile error;
  - internal error.
  I also scanned the output of every accepted run for garbage values
  (`0xAA` bytes, `-6148914691236517206`).

| Sweep | Compiler | Programs | Result |
|---|---|---|---|
| review-text, -text2, -text3, -text4 | text-core HEAD | 584 | 476 rejected, 106 ran clean, 1 intended bounds panic (`review-text3/g2.rig` indexes past the end on purpose), 1 not classified (my script hit a bash error on it). **0 unsound among the 583 classified.** |
| audit-ownership, audit-typecheck, review-revamp-checkers, review-lang4, review-place (top level) | main | 462 | 281 rejected, 181 ran clean. **0 unsound.** |
| My targeted temporary probes (`seams/probes/p*.rig`) | text-core | 20 | Correct, or rejected with a sensible message. One conservative false rejection: `(a if c else mk()).v.len` (p17). |
| My evaluation-order probes (`seams/mprobes/m*.rig`) | main and text-core | 13 | **3 accept a write to freed memory** (m08, m09, m13); see §2.4. |

---

## 2. Root causes

### 2.1 W1: each consumer classifies expressions by syntax, often by negation

The ownership rules depend on one question: *what does this expression hand
over?* It can be a place a name owns, a fresh owned value, a borrow, or a
view of something. There is no single answer to that question in the
compiler:

- **typecheck.zig uses `isPlaceExpr(e)`,** which is true for a name,
  `a.f`, `a[i]`, `?x` or `!x`. Until 09-30, "is a temporary" meant
  `!isPlaceExpr(e)`. So anything *not* on that four-item list counted as a
  fresh temporary. That included:
  - `a if c else b`;
  - `o?`;
  - `x ?? y`;
  - a block value;
  - a `match` whose arms name owners.
  Each of these can hand over an owner that a name still holds. Treating it
  as a temporary moves the owner into a slot that gets dropped, so it is
  freed twice.
- **Six `!isPlaceExpr(...)` "temporary" checks remain on text-core,** at
  typecheck.zig:1468, 3201, 3592, 4275, 4298 and 4396. They are now safe
  only because each one then passes through `readTemp` → `rejectNotFresh`.
- **Both files re-derive place facts.** typecheck.zig had about 13
  overlapping place and writability predicates. #27 (place-access) merged
  them into `Place` + `requireAccess`, and that held. ownership.zig still
  has its own `resolvePlace`, `movedTail`, `readsValue`, `readsPlainValue`,
  `isWriteBorrowPlace`, `isValueExpr` and `tailOf`.
- **Consumers keep their own special paths.** `print`, Cells ("hold no
  borrows"), element methods (`copy`/`fill`), `==` operands, `for` sources
  and `match` subjects each have one. A new fact, such as "this is a view of
  a temporary", has to be threaded into every one of them by hand. The Cell
  store bug and the variant-literal `==` bug are this.

**It keeps coming back.** The same class was found, patched in one place,
and found again:

- **09-27, take review:** `<(a if c else b)` and `<o?` were double drops.
  They were patched in ownership's `movedTail`.
- **09-28, typecheck audit TC1:** `<o ?? return` was a double drop, because
  `takes_whole = !isPlaceExpr(left)`. It was patched in `synthCoalesce`.
  The same auditor wrote: *"A single `ownsValue(expr, ty)` predicate ('this
  node hands over an owned value, not a borrow of one') … would close that
  class."* It was not built.
- **09-29/30, text-core rounds 2–3:** ternaries over names, `o?` and `??`
  consuming names came back as temporaries. The fix that held (`c30c385`)
  is `handsOverFresh`, which is that same predicate. It is a positive list,
  and anything not on it is "not fresh".

### 2.2 W2: control flow is coded per construct, and saving state forgets silently

- **ownership.zig has no control-flow graph.** It walks the tree, and each
  construct hand-codes its own branch, join and loop logic out of `here`,
  `leave`, `capture`, `join`, `joinAt`, `leaveTo`, `rewind` and `apply`.
  These are about 55 calls across 13 functions: `walkMatch` 8, `walkLoop`
  8, `walkIfBinding` 6, `walkIf` 4, `loopIteration` 4, `walkNullish` 3,
  `walkCatch` 3, and so on.
- **`defer` and `errdefer` are separate again:** their bodies are walked
  once more at each exit (`runDefers`, `checkDeferBody`).
- **The basic step forgets silently.** `capture()` (ownership.zig:853 on
  main) calls `filterLoansBelow`. That silently drops any loan on a
  variable of a scope being left. Reporting those loans is the caller's
  job (`leaveTo`, `popScope`). Every path that forgot to report first was a
  use-after-free:
  - own C1 (09-28): `?? return` made the rest of the block unreachable, so
    it went **unchecked**;
  - own C2 (09-28): the failing part of a joined `as` condition;
  - own C3 (09-28): the state after a failing guard was lost;
  - text-core round 3: branch joins silently discarded loans. This was
    fixed by adding temporary-only reporting *inside* `capture()`
    (`c30c385`). Other loans are still filtered silently.
- **The audit's structural fix was only partly applied.** audit-ownership
  (09-28) proposed a single `leavePath` that always reports before it
  captures. Commit `253ce3e` merged `captureBelow` into `capture`, but the
  "capture never forgets" rule was not made the only way in.

### 2.3 W3: the checker and the emitter each build their own picture of the program

The ownership checker reasons about the **source tree**. The emitter writes
a **different program**:

- it hoists arguments and receivers into temporaries (`hoisted`,
  `emitHoistedCall`, `hoistReceiver`);
- it keeps statement temporaries in slots (`temp_slots`, `rig.keep`, which
  are new on text-core);
- it relies on Zig's own lifetime for `&temp` when a temporary array is
  lent as a slice;
- it chooses the evaluation order: Zig's order, left to right, with an
  assignment's target address taken *before* the right-hand side runs;
- it re-evaluates a guarded match's subject (batch B C1/C2).

There are also **three separate models of "a temporary"**:

- typecheck: `lent_borrow`, `lent_temp`, `through_temp`, `readTemp`,
  `lendTemp`, `rejectResourceTemporary`, `recordTempDrop`;
- ownership: `temps`, `stmt_drops`, hidden vars, `holdTemp`,
  `dropStmtTemps`, `keepViewTemps`, `holdArgRead`;
- emit: `hoisted`, `temp_slots`, `emitTempSlots`, `hasTemps`, and
  `writeTempDrop` with its own drop order.

Any place where these pictures differ is a place where "accepted" does not
mean "correct":

- `print(v, grow(!v), v)` (09-29): the checker treated the first `v` as an
  instant read. Zig copies the Vec header into the argument tuple *before*
  `grow` reallocates. The fix, `holdArgRead`, covers call arguments only.
- RF1 (a moved borrow's loans end early within a call) and RF3 (a temporary
  receiver leaks on a failing argument).
- The batch B guarded-match subject was re-evaluated.
- T1 (09-28): a borrow of a temporary struct was stored and outlived it.
- text-core:
  - the drop order on failure paths was wrong;
  - an `if … as` header temporary lived through the body in emit but not in
    the checker's scope model;
  - `for x in <temp>` lost its loans;
  - `match` on a temporary with moving arms freed the payload twice.
- Name meaning: `X.name` can be a variant, an error member, a module
  constant or a module member. typecheck and emit each decided which one
  it was, so `lib.CONST` of an error-set type was typed as the constant and
  emitted as an error.

### 2.4 A live W3 hole on main today

`seams/mprobes/m08.rig`, `m09.rig` and `m13.rig`. All are accepted by
`main` and by `text-core`, and all run with no panic and no leak report:

```rig
fun grow(v: !Vec[Int]) -> Int      # pushes 100 items (reallocates), returns 5
...
  v[0] = grow(!v)
  print("v[0] is", v[0], "expected 5")      # prints 7: the 5 went into the freed buffer
```

```rig
fun mk(b: !B) -> Int               # replaces b.xs with an empty Vec (frees the old buffer)
...
  b.xs[0] = mk(!b)                  # emitted: b.xs.slot(0).* = mk(&b);
  print(b.xs.len)                   # 0; the store wrote into freed memory
```

`m09`: `v[0].total += spill(!v)` prints 10 where 11 is expected, the same
way.

- **Why it happens:** the emitter writes `place.* = call(&owner)`. Zig
  computes the address first and runs the call second.
- **Why the checker misses it:** it walks the right-hand side, where
  `!v` is fine, and then the assignment. It never sees that the target's
  address was already taken.
- **Why the tests miss it:** the Debug allocator (runtime.zig:1051–1133)
  records addresses for leak and double-free checks. It neither poisons nor
  unmaps freed memory, so a write-after-free is silent.
- **The fix:** either evaluate the right-hand side into a temporary first,
  which is Rust's order and gives a bounds panic in m13, or hold a write
  loan on the target's root across the right-hand side. A structural
  lowering (§3, option a) makes the order explicit and removes the whole
  class.

### 2.5 Classification of every bug named in the brief, and the audit history

**Classes:**

- **W1:** classification of expressions.
- **W2:** control flow and joins.
- **W3:** the checker's and the emitter's pictures differ, including facts
  settled twice.
- **F:** feature design, where the rule itself is hard to check.
- **Process:** contributing in every row below. Each was fixed instance by
  instance, and most classes had been named before.

| # | Bug | Primary | Mechanism |
|---|---|---|---|
| 1 | Views escaping through `if … as` bodies | W3 | The header temporary's lifetime was defined separately in typecheck, ownership (`stmt_drops`) and emit (`temp_slots`), and the three disagreed about a compound statement. |
| 2 | `match` on a temporary with moving arms | W1 | The subject was classified "read temporary, dropped at end" while its arms moved the payload out. |
| 3 | Wrong drop order on failure paths | W3 | emit's slot `defer`s, hoisted temporaries and binding drops each have their own order, and the checker has no model of it. |
| 4 | Ternaries over names treated as temporaries | W1 | `!isPlaceExpr`. |
| 5 | Cell element stores | W1 | The Cell/Vec store path is a separate consumer that lacked the view-of-temporary handling. |
| 6 | `o?` treated as fresh | W1 | `!isPlaceExpr`. |
| 7 | `??` consuming names | W1 | `takes_whole = !isPlaceExpr(left)`; this is TC1 of 09-28 again. |
| 8 | Branch joins silently discarding loans | W2 | `capture()` filters silently; this is own C2/C3 of 09-28 again. |
| 9 | `print(v, grow(!v), v)` | W3 | Evaluation order and representation differ from the checker's model. The sibling is still open (§2.4). |
| 10 | `for x in <temp>` losing loans | W3 | A hidden source var modeled apart from the temporary it holds. |
| 11 | `defer` stores outliving their values | W2 | Deferred bodies are walked again at each exit on their own path. |
| 12 | Errors across sets | F | The language promises per-set error identity, but Zig's `anyerror` merges by name, so the representation needed a design decision. |
| 13 | `lib.CONST` of an error type | W3 | typecheck and emit each settled what `X.name` means. |
| 14 | `v[0] = grow(!v)` (new, §2.4) | W3 | The assignment target's address is taken before the right-hand side runs. |

**Critical and high soundness findings from the audits since 09-25 that I
could classify from the reports** (not an exhaustive census):

- **W1 (13):**
  - brackets OWN F1 and F2;
  - closure-args C1, whose callee forms each have their own path;
  - slices-bytes #1, fill/copy on a separate path;
  - cmp #1 and #2, a variant literal on a separate `==` path;
  - TC1, TC2 and TC4;
  - box C1 and C2;
  - revamp-1 review1 #1 and #2;
  - take's `<(a if c else b)` / `<o?`.
- **W2 (6):** own C1, C2 and C3, RF2, the batch B guard that writes its
  subject, and review1 #5 (defer).
- **W3 (6):** RF1, RF3, sema C1 (`Cell` sized as 8 bytes by sema, inline by
  the runtime), tests T1, and batch B C1 and C2 (re-evaluation).
- **F (1):** closure-args C2 (closure parameters' borrows stored through a
  write capture).

**Totals (40 bugs):**

| Class | Count | Share |
|---|---|---|
| W1 | 18 | 45% |
| W3 | 12 | 30% |
| W2 | 8 | 20% |
| F | 2 | 5% |

About 90% trace to the three structural weaknesses. Feature design is the
main cause in only 2 of 40, though it contributes in about 6 more:

- statement-end temporaries add a new lifetime category;
- `??` with a jump;
- `if … as` on borrowed optionals;
- closures with borrow parameters.

**Process is a contributing cause in all of them.** At least 6 of the 8
text-core bugs were members of a class already found and named 1–3 days
earlier (rows 4, 6, 7 → take/TC1; row 8 → own C2/C3; row 5 → O5; row 3 →
RF3). In each case the earlier fix was for the instance, and the
recommended class-wide helper (`ownsValue`, `leavePath`) was deferred or
only partly applied.

### 2.6 How the text-core feature went, as a case study

- **The user's decision:** 2026-09-29 ("an owning temporary that is only
  read … is dropped at the end of its statement").
- **The timeline:**
  - feature commit `77cc5a5` at 22:35;
  - fixes at 22:49, 23:14, 23:25, 00:05 and 00:37;
  - four review rounds in about two hours.
- **How the feature was built:**
  - **Typecheck** decides "this node is a dropped temporary" by calling
    `recordTempDrop` from about 10 call sites: `readTemp`, `lendTemp`, the
    member, index and slice paths, `synthBorrow`, the comparison operands
    and the match subject.
  - **Ownership** adds hidden vars (`holdTemp`, `dropStmtTemps`) and scans
    every flow for loans on them.
  - **Emit** adds a third mechanism (`temp_slots`, `rig.keep`, per-`while`
    reset lists) beside the existing `hoisted` one.
- **How the review rounds went:** every round found new instances. Round 2
  is when the drop order, owner branches and Cell Vec stores were found and
  patched one by one. Rounds 3 and 4 went into the predicate and the joins.
  The fix that held (`handsOverFresh`) is the class-level fix the audit had
  asked for two days earlier.
- **The branch is not wrong today.** HEAD passes all 584 of its own review
  probes and my 20 targeted ones. The problem is what it took to get there,
  and that the same structure is waiting for the next feature.

---

## 3. Structural fixes

### 3.1 Why lowering is the fix that makes these bugs impossible

Write the statement-end temporary rule as a desugaring into forms the
checker already understands:

```
print(f(?Text("x")))    ≡    __t = Text("x")           # a hidden binding, named after its source text
                             print(f(?__t))
                             -__t                      # dropped at the statement's end (reverse order)
```

Then run each text-core bug through the checker's *existing* rules:

| Bug | After desugaring | Existing rule that rejects it |
|---|---|---|
| 1 `if ?Text(..) as s` body stores `s` outward | `__t = Text(..); if ?__t as s …; -__t` | "`__t` does not live long enough" at the drop |
| 2 `match mk()` with an arm moving the payload | `__t = mk(); match ?__t …` | moving a payload out of a match that reads its subject |
| 3 drop order on failure | hidden bindings drop like any binding (reverse, guarded `defer`) | the existing drop and `defer` machinery |
| 4 `a if c else b` as a temporary | `__t = a if c else b` | a consuming position needs `<a` or `+a` |
| 5 Cell element store of a view | `c[i] = ?__t[..]` | Cells hold no borrows |
| 6 `o?` as fresh | `__t = o?` | the `<o?` move-out rule (`movedTail`) |
| 7 `x ?? y` consuming names | `__t = x ?? y` | as for row 4 |
| 8 joins discard loans | `__t` is an ordinary var of the statement's scope | scope-exit reporting in `popScope` and `leaveTo` |

The same lowering fixes the evaluation-order family:

- `print(v, grow(!v), v)` becomes `__a = ?v; __b = grow(!v)`. The write
  borrow now conflicts with a live read, a plain rule, and `holdArgRead` is
  no longer needed.
- `v[0] = grow(!v)` becomes `__r = grow(!v); v[0] = __r`: correct and safe.

The emitter then prints the lowered program, so the checker has checked
exactly what runs.

### 3.2 The four candidate fixes, weighed

Sizes are rough estimates in hand-written lines, against today's 30.9k
(text-core).

#### (a) Lower to a small structured core before checking and emitting

**What it is.** A pass after typecheck turns each function body into a
**structured** core. It cannot be a flat control-flow graph, because Zig
has no `goto`, while Zig's labeled blocks, `break`-with-value, `if`,
`while` and `switch` can express everything below. The core has:

- **Named statement-scoped bindings for every intermediate value** that is
  owning, borrowed-from, or read after a later side effect, with explicit
  left-to-right evaluation.
- **Explicit drops.**
- **About eight value forms:** `let`/`set`, `call`, `borrow`/`move`/`clone`
  of a place, `if`, labeled `block` with `break` value, `loop`, `match` on
  a tag with bindings, and `return`.
- **Sugar lowered into those forms:**
  - `??`, `e?`, `e!` and `catch` become a match on a tag plus a labeled
    `break`;
  - ternaries become `if`;
  - `if … as` and `while … as`, including joined conditions, become nested
    `match` plus labeled blocks;
  - guards become an arm body that falls through to a labeled "next arm";
  - `defer`/`errdefer` become explicit cleanups at each exit, or one scope
    form with ordered cleanups.

Ownership and emit both consume the core. Diagnostics keep source spans,
because each hidden binding carries its origin (holdTemp already names
them by span text).

**What it removes:**

- **W3 structurally:** one picture of the program, and one notion of a
  temporary.
- **Most of W2:** a handful of forms instead of about 40.
- **Much of W1:** after lowering, a value is a binding or a place, and the
  forms that caused trouble (ternary, `o?`, `??`, block values, match
  values) no longer reach the checker.

**Staging.** Each stage lands on its own and is proven by the suite and the
fuzzer (d):

| Stage | Change | New lines | Removed lines | Time | Risk |
|---|---|---|---|---|---|
| A1 | Temporaries and evaluation order become hidden bindings plus drops. This deletes `temp_slots`, `hoisted`, `stmt_drops`, `holdArgRead`, `lent_temp`/`through_temp` and arg-read loans. | ~1,000–1,500 | ~800–1,200 | 1–2 weeks | medium |
| A2 | Desugar `??`, `?`, `!`, `catch`, ternary, `if/while … as` (joined too) and guards into the core forms. The per-construct walkers in ownership and emit shrink to the core set. | ~1,500–2,500 | ~2,000–3,000 | 2–3 weeks | medium-high: the whole emitted shape changes, though tests compare only stdout |
| A3 | `defer`/`errdefer` as explicit cleanups. This retires `runDefers`/`checkDeferBody` re-walks and `ret_block`. | ~300 | ~400 | 3–5 days | medium |

- **Total:** 4–6 focused weeks.
- **Net code:** about flat to −2k.
- **Rule while it happens:** no new ownership-affecting language features
  land during A1–A2.

#### (b) One source of truth per fact

**What it is.**

- **A `ValueClass` fact per expression,** computed once in typecheck by a
  **positive** list and recorded in the facts table: `place{root, path,
  access}`, `fresh_owned`, `borrow{kind, of}`, `view_of{temp|place}` or
  `copy`. `handsOverFresh` plus `Place` are its seeds.
- **A `disposition` fact** for every owning value in value position:
  bound, moved into X, returned, stored, dropped at statement end, or
  consumed by a call.
- **Ownership and emit read these facts and never inspect syntax to
  classify.** A lint in `test/run` enforces it: no `isPlaceExpr`, and no
  `.kind()` switch on value forms outside the walker dispatch and the
  classifier.
- **The same rule for names:** one resolution of `X.name`, whose kind every
  pass reads.

**What it makes impossible:** W1 as a class. A new syntactic form has one
place to be classified, and an unlisted form is "not fresh", so it is
rejected, not freed twice.

**Size and risk:** +300–500 / −400–600 lines, 3–5 days, low-medium risk.
It is also the natural first step toward (a).

#### (c) An invariant checker and a checked emit contract

**What it is.**

- **A fact verifier** (`rig check --verify`, always on in `./test/run`)
  that, after sema, checks consistency:
  - every owning value in value position has exactly one disposition;
  - no node is both `takes` and `dropsTemp`;
  - `readsThrough` only on borrow-typed nodes;
  - every `dropsTemp` node lies in exactly one statement;
  - `ValueClass` agrees with the type (a `fresh_owned` node has drop
    glue).
- **An emit contract:** emit asserts the facts it relies on, instead of
  deriving them.
- **Most valuable: a sanitizing allocator for Debug test runs** (§2.4).
  One mode gives every allocation its own pages and never reuses
  addresses. On free it poisons the memory and marks the pages
  `PROT_NONE`. Any read or write after free then crashes at the spot, in
  the style of Electric Fence or ASan's quarantine.

**Size and risk:**

- verifier ~300–600 lines, low risk;
- sanitizer ~100–200 lines in runtime.zig plus a `RIG_SANITIZE=1` switch
  in `test/run`, low risk. It is slower, so run it nightly or for the
  ownership and std test areas.

**What it gives:** it **detects** instead of prevents. But without the
sanitizer the suite literally cannot see use-after-free, so this should
come first.

#### (d) A generative and differential soundness fuzzer on every change

**What it is.**

- **A kept corpus.** The ~60k probe programs reviewers wrote sit in
  `/private/tmp` scratchpads. The ledger already records one scratchpad
  being wiped. Deduplicate them into `test/corpus/`, with the oracle
  "rejected, or runs with the right exit status, no leak, no Zig error,
  clean under the sanitizer". Run a sample per PR and all of it nightly.
- **A form × context × type matrix,** which is exactly where the text-core
  bugs were:
  - **Forms (about 13):** name, field, call, ternary, `??`, `o?`, `e!`,
    block, match, `<x`, `+x`, `*x`, `?x[..]`.
  - **Contexts (about 15):** `print` argument, `?`-lent argument, binding,
    field store, return, `match` subject, `for` source, `if`/`while … as`
    header, `==` operand, Cell store, Vec push, closure capture, `defer`
    body, assignment target and value, compound assignment.
  - **Types (about 8):** Copy, Vec, Text, String view, Box, `*T`, struct
    holding a Vec, optionals of these.
  - About 1.5k small programs. Same oracle.
- **A mutation fuzzer over accepted tests:**
  - wrap a sub-expression in a ternary, `??`, `o?`, a block, a match or an
    `if … as`;
  - move a use after a write borrow;
  - duplicate a move;
  - put a reallocating call on the right of an element assignment.
  Each mutant must be rejected or run clean.
- **Differential:** Debug and ReleaseSafe outputs must agree.

**Size and risk:** ~1–2k lines of harness, in Python or bash, outside the
compiler. Zero compiler risk. Per-PR sample about 5–10 min at `-j6`; full
nightly.

**What it gives:** it detects. The matrix would have found at least 6 of
the 8 text-core bugs *before* the first review, and the §2.4 hole
directly.

### 3.3 Recommended order

1. **This week: the sanitizing allocator and the corpus** (c-sanitizer,
   d-corpus). Also fix the §2.4 hole: evaluate an element assignment's
   right-hand side first, then store. This makes the oracle honest and
   captures what the reviews already paid for.
2. **Next: `ValueClass` and `disposition` facts, and the lint** (b).
   Retire the six `!isPlaceExpr` sites and ownership's own classifiers.
   Add the matrix generator (d-matrix).
3. **Then: the fact verifier** (c).
4. **Then: A1** (temporaries and evaluation order as hidden bindings),
   **A2** (sugar), **A3** (defers). Language surface frozen while this
   happens.

---

## 4. Process fixes

### 4.1 Sequencing implementation and review

The current loop is: implement, review, patch the instances, review again,
and repeat 2–4 times.

**Proposed loop:**

1. **Design as a desugaring.** Write the feature as a table from surface
   form to core form (§3.1). If it cannot be written that way, it needs a
   new core form and a written checker rule saying which invariant it
   keeps.
2. **Tests first,** as AGENTS.md already says. Generate the form × context
   × type matrix rows the feature touches, before writing code.
3. **Implement.**
4. **Run the corpus, the matrix and the sanitizer.** All must be green.
5. **One independent adversarial review.**
6. **If the review finds a critical, stop patching.** Run a root-cause
   pass first:
   - which predicate or path was wrong;
   - list its sibling sites (grep, matrix);
   - fix the class;
   - add a matrix or mutation test that would find a sibling.
   Only then run the next review.
7. **Do not re-review within hours of a fix round.** Four rounds in two
   hours measured patch speed, not soundness.

**Parallel branches:**

- Only one branch at a time may change the classification or temporary
  code in typecheck.zig, or anything in ownership.zig.
- Two feature branches merged by agents through typecheck conflicts is how
  facts end up settled twice.
- The file-ownership split used in REVAMP-2 worked. Keep it.

### 4.2 Invariants to add to AGENTS.md (suggested wording)

> 8. **One classifier.** Whether an expression is a place, a fresh owned
>    value, a borrow, or a view is decided once, by a positive list, and
>    recorded as a fact. Ownership and emit never re-derive it from syntax,
>    and no category is defined as the complement of another.
> 9. **The checker checks what is emitted.** Emit may not add a
>    temporary, change evaluation order, re-evaluate an expression, or
>    place a drop that the ownership checker did not see as a binding in
>    the IR it walked. The meaning of a name (`X.name`) is resolved once.
> 10. **Leaving never forgets.** Every path that leaves a scope (a jump, a
>     failing condition or guard, an error) reports the loans it discards.
>     Capturing state never drops a loan silently.
> 11. **Features are desugarings.** A feature that changes ownership or
>     lifetimes states its desugaring into existing forms in INTERNALS; its
>     checker rule is the one that desugaring implies.
> 12. **Fix the class.** A soundness fix names its class, lists the sibling
>     sites it checked, and adds a matrix or mutation test that would catch
>     a sibling.
> 13. **Probes are kept, and the oracle sees freed memory.** Every
>     reviewer probe goes into `test/corpus`. "Runs clean" means no leak
>     *and* no use-after-free under the sanitizing allocator.

Also amend Rule 1: "no leaks under the checking allocator" should become
"no leaks and no use of freed memory under the sanitizing allocator".

### 4.3 What must hold before a feature lands

- **An ownership-affecting feature:**
  - its desugaring is written in the PR, and in INTERNALS;
  - its matrix rows exist and pass;
  - the corpus, matrix and a mutation campaign (for example 2,000 mutants)
    give 0 unsound accepts under the sanitizer;
  - one review has 0 criticals, or the root-cause pass of §4.1 is done.
- **A size tripwire:** a feature adding more than about 300 lines to
  ownership.zig or typecheck.zig gets a design check that asks "what would
  make this smaller, or a desugaring?".
- **Any feature:** `./test/run` green (as today), and no new `!isPlaceExpr`
  or syntax-shape classification (the lint).

---

## 5. Is the codebase coming apart?

### 5.1 Growth

Hand-written lines in the seven main compiler files:

| Snapshot | ownership | typecheck | emit | sema | resolve | runtime | rig | Total | Test `.rig` files |
|---|---|---|---|---|---|---|---|---|---|
| 206ea77 (09-23, revamp-1 base) | 3,451 | 3,985 | 3,724 | 2,666 | 1,595 | 1,097 | 1,310 | 17,828 | 771 |
| bb8f608 (09-25, brackets) | 3,672 | 5,584 | 3,975 | 3,226 | 1,721 | 1,370 | 1,661 | 21,209 | 1,132 |
| 3bbf7d6 (09-26, read-borrow repr) | 3,924 | 7,229 | 4,396 | 4,287 | 2,199 | 1,719 | 1,908 | 25,662 | 1,347 |
| 5f2bdbc (09-28, revamp-2 base) | 4,194 | 8,169 | 5,367 | 4,560 | 2,266 | 1,807 | 2,039 | 28,402 | 1,472 |
| main (09-29) | 4,387 | 8,778 | 5,471 | 4,801 | 2,372 | 1,917 | 2,152 | 29,878 | 1,697 |
| text-core (09-30) | 4,659 | 9,051 | 5,690 | 4,894 | 2,384 | 2,081 | 2,152 | 30,911 | 1,756 |

- **Total code:** +73% in 7 days.
- **typecheck.zig:** ×2.3, now 9k lines. It is where classification
  lives.
- **Tests:** also ×2.3. The test suite has grown as fast as the code,
  which is healthy.
- **ownership.zig:** grew more slowly (+35%). Its complexity grew through
  special paths more than through lines.
- **Commit rate:** 999 commits in total. About 840 of them since 09-22,
  including 270 on 09-25 and 163 on 09-28.

### 5.2 Bug rate per feature

Critical memory-safety or accept-means-correct findings at a feature's
first adversarial review:

| Feature (review) | Criticals / highs at first review | Rounds |
|---|---|---|
| Brackets and generic fns (C) | 2 critical ownership + several emit | 1 fix round |
| ct-sizes | stack-guard hole + 1 high | 2 |
| cmp-foundations | 2 critical + 1 high | 1 |
| slices-bytes | 2 high | 1 |
| closure-args | 2 critical UAF + 3 high | 1 |
| Box[T] | 1 critical UAF (+1 pre-existing) + 6 high | 1 |
| take | 0 new (2 pre-existing double drops) | 1 |
| batch B (sc4) | 3 critical + 1 high | 1 |
| REVAMP-2 audits (whole compiler) | 7 critical memory-safety (own C1–C3, TC1, TC2, sema C1, T1) | 1 |
| Statement-end temporaries (text-core) | about 8 across 4 rounds | 4 |

- **Features that don't touch ownership** (the syntax cleanups, modules,
  generics across modules) produce accept-means-correct Zig errors, but
  almost no memory bugs.
- **Features that do touch ownership** produce 1–3 memory-safety criticals
  each at first review, and the most recent one produced about 8. **The
  rate per feature is not falling.** Each new feature meets more existing
  special paths (Cells, views, `if … as`, guards, loops, `defer`), so the
  number of interactions grows faster than the feature count.

### 5.3 Is main sound today?

- **For:**
  - CI is green with required checks;
  - `test/known` is empty;
  - 462 probes from the REVAMP-2 ownership and typecheck audits and the
    checker, lang-4 and place reviews give 0 panics, 0 leaks, 0 Zig errors
    and 0 garbage outputs;
  - consolidations have held (Place/requireAccess in #27, one constant
    evaluator, `handsOverFresh` on text-core).
- **Against:**
  - **one live hole:** a write to freed memory through an element
    assignment whose right-hand side reallocates or frees the owner (§2.4:
    m08, m09, m13);
  - the Debug oracle cannot see this class, so the suite passing says
    nothing about it;
  - the six negative "temporary" checks on text-core and the silent filter
    in `capture()` are places where the next feature will find the next
    instance.

### 5.4 Verdict

**Not coming apart, but running hot, with rising marginal cost.**

- **What is healthy:**
  - fixes stick;
  - tests keep pace with the code;
  - the architecture already has the right seam, a single facts table
    passes read;
  - when the team did consolidate (Place, handsOverFresh), the bug class
    closed.
- **What is not:**
  - soundness is being bought with review rounds, not structure;
  - the same classes recur within days;
  - three passes each keep their own model of temporaries and evaluation
    order;
  - the test oracle is blind to use-after-free.
- **The debt is concentrated and fixable:**
  - three weaknesses;
  - about 40 bugs traced to them;
  - a staged plan of 1 week for the oracle and corpus, about 1 week for the
    single classifier, and 4–6 weeks for lowering.

---

## Appendix: files

- Sweeps:
  - `seams/text-sweep.tsv` (584 review-text probes on text-core);
  - `seams/main-sweep.tsv` (462 older probes on main);
  - `seams/text-ok-out.txt` and `seams/main-ok-out.txt` (outputs of the
    accepted runs, scanned for garbage values).
- Classifier: `seams/one.sh BIN file.rig`.
- New hole: `seams/mprobes/m08.rig`, `m09.rig`, `m13.rig` (emitted as
  `v.slot(0).* = grow(&v)` and `b.xs.slot(0).* = mk(&b)`).
- Targeted temporary probes: `seams/probes/p01–p20.rig`.
- Built compilers: `seams/main/bin/rig` and `seams/text/bin/rig`, exported
  with `git archive`, so the checkouts were not touched.
- Key code:
  - main `src/ownership.zig:853` (`capture`, which filters silently);
  - text-core `src/typecheck.zig:3524` (`handsOverFresh`) and the six
    `!isPlaceExpr` sites listed in §2.1;
  - `src/runtime.zig:1051` (the Debug allocator: no poisoning or
    unmapping);
  - `src/emit.zig` (`temp_slots` beside `hoisted`).
