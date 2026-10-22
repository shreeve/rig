# REVAMP-3 review: HANDOFF step 2, "One classifier and one exit"

Reviewer: independent (wrote none of this code). Diff: `rig-r3-step2`,
`git diff 455944ab..8d16d4be` (14 commits). HEAD built in a scratch clone
(`zig build`, `zig build oracle`), plus a `-Doptimize=ReleaseSafe` build of
the same HEAD to see what a release compiler emits. Base for comparison:
`s2-bins/rig-base-455944ab`.

Probes (outside the repo):
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad/rev2probe/`
(`run1.sh f.rig`: base check, HEAD check, `RIG_SANITIZE=1 run`, oracle diff)
and `.../scratchpad/gen.py` (7 branching forms x ~50 contexts x 5 types
that `test/matrix.py` does not cover; results in `.../scratchpad/g1.out`,
`g2.out`).

## Summary

1. **Critical regression (B9): a closure whose return type is inferred
   records no `Use` for its tail.** `g = |s: Text| s` crashes the Debug
   compiler (`emit: no use is recorded`), and a release-built compiler
   emits a use of freed memory. The base compiled and ran it correctly.
   This is the "value position with no `Use`" the B9 inversion was meant
   to make impossible, and it is a soundness slip in the step-2 code.
2. **The release fallback of `takesTail` is "read", which is unsound.** A
   missing `Use` is caught only by a Debug panic; every gate runs a Debug
   compiler, so any sibling of item 1 ships as a use-after-free.
3. **Pre-existing (also on base), same class as F1/F2:** a branching
   value read in place as a `?self` receiver or an `==` operand is not
   held against a write lend later in the same call or expression
   (`(a if c else b).peek(!a)`, `(a if c else b) == grow(!a)`, and the
   place form `a == grow(!a)` for Text). Accepted; use of freed memory.
4. Statement temporaries: the silent removal kept in `releaseVarsFrom`
   removes only `temps` reservations (in-flight conflict markers), never a
   holder's loan; it cannot hide an accepted unsound program. Every sibling
   built (returned views of a local's field, of a temporary, arm bindings,
   guards, `while` headers, nested value blocks) is rejected, as on base.
5. `readLeaf`'s two subtleties survived (more-than-one-leaf in-place read;
   one temporary for an all-made branching value).
6. `exitTo`: every exit goes through it; defers, `Exit.goesOn`, and the
   order (escape, defers, report, capture) are preserved. No path found
   that drops a loan unreported.
7. Flips D9/D10/D11/B6 are sound in every probe, with right drop order
   under the sanitizer.
8. Docs: accurate except the *(built)* claim for "a view" (computed,
   consumed by nothing) and the INTERNALS sentence that every value
   position records a `Use`.


## Findings

### C1 (critical, regression of B9) A closure with an inferred result records no `Use` for its tail

- **Where:** `src/typecheck.zig:8098` (`} else try self.synthExpr(last);`)
  and `:8100` (`} else ret = try self.synthExpr(body);`) in
  `checkLambdaGiven`. A closure with no expected type infers its result
  by `synthExpr`, not `checkExpr`, so `recordUse` never runs on its tail.
  Emit then reaches `takesTail` (`src/emit.zig:3042-3050`) with
  `self.use == null`.
- **Effect:** the ownership checker walks the tail as the closure's
  returned value (`walkReturnValue`: the param is moved), but emit,
  having no `take`, reads the name in place, so the param's drop stays
  armed and the closure frees what it returns.
  - Debug compiler (every gate): `thread panic: emit: no use is recorded
    for the value whose tail is 's'`, from `rig run`/`build`/`emit`.
  - ReleaseSafe compiler (built from HEAD): the program is accepted and
    hits `rig: use of freed memory` under `RIG_SANITIZE=1`.
  - Base `455944ab`: compiles, prints the right value, sanitizer-clean.
- **Reproductions** (`rev2probe/`): all accepted by `rig check`; all
  panic in emit at HEAD; `c4`, `c6`, `c7`, `c9`, `g4`, `g6` under the
  release build: use of freed memory; all correct on base.
  ```rig
  sub main
    g = |s: Text| s                                   # c4
    print(g(Text("zz")))
  ```
  Also `|s: Text, c: Bool| s if c else Text("d")` (c6), a block body
  ending in `a` (g4), a body that is `match k` with `1 => a` (g6), a body with an early
  `return s` and a tail `s` (c7), a closure lent to a call (`apply(?g, …)`,
  c9), and the
  generator cells `*.lambda_tail` / `*.lambda_blk` for every owning type
  and form that the checker accepts.
- **Why the gates missed it:** no test or corpus program has an inferred
  closure returning an owned parameter; `test/matrix.py` has no closure
  context.
- **Fix:** record the take where the value leaves:
  `try self.recordUse(last, .take)` before `synthExpr(last)`, and
  `try self.recordUse(body, .take)` before `synthExpr(body)` (a closure's
  value is its result, as `checkReturn` already records). Class: "a
  value that leaves a body, checked by `synthExpr`". Sibling sites
  checked: function bodies (`checkBody` uses `checkExpr`: fine), closures
  with an expected type (`checkBody`: fine), `return` (fine), `break` and
  loop `else` (`loopValue`: fine), `raw` value blocks (`checkExpr`: fine),
  `catch` handler blocks and nested value blocks (parts inherit: fine).
  Tests: a behavior test with the four shapes above; add a
  `closure_tail` context to `test/matrix.py`.

### C2 (high) A missing `Use` is unsound outside Debug

- **Where:** `src/emit.zig:3046-3047`: in a non-Debug compiler a missing
  `Use` returns `false` (read in place).
- **Effect:** C1 is a use-after-free in any release-built `rig`. The
  Debug panic is the only guard, and no gate runs a release compiler. A
  read where the checker saw a take is never safe.
- **Fix:** make it a compile error in every build mode (an
  `unsupported`-style internal diagnostic at the node), not a Debug-only
  panic with a silent fallback. Then a sibling of C1 is a rejected
  program, not a miscompile (Rule 2).

### P1 (critical, pre-existing on base; F1/F2's class) A value read in place is not held against a later write lend in the same call or `==`

- **Where:** `src/ownership.zig:2912-2916` (`walkCall`): a `?self`
  receiver that is no place (`resolvePlace` is null for a branching
  value) is only `walk`ed; arguments get `holdArgRead`
  (`:3029-3039`, falling back to `holdBranchReads`), the receiver does
  not. The operands of `==`/`!=` are walked as an operator's children
  with no hold at all, place or branching.
- **Effect:** emit copies the value (`@as(P, (if (c) a else b)).peek(&a)`,
  `rig.Text.eql(a, grow(&a))`); the later `!a` grows `a`'s buffer; the
  copy reads freed memory.
- **Reproductions** (each accepted on base and HEAD, use of freed memory
  under the sanitizer on both):
  ```rig
  struct P
    v: Vec[Int]

    fun peek(?self, other: !P) -> Int
      for i in 0..100
        !other.v.push(i)
      self.v[0]

  fun mk(k: Int) -> P
    v: Vec[Int] = Vec()
    !v.push(k)
    P(v: <v)

  sub main
    a = mk(1)
    b = mk(2)
    c = true
    print((a if c else b).peek(!a))      # h1
  ```
  `print((a if c else b) == grow(!a))` with Text and
  `grow(t: !Text) -> Text` that appends 100 times (h9), and the place
  form `print(a == grow(!a))` (h12; the oracle flags it,
  `DIFF … prod=accept ref=reject C4 … cannot write a while a read loan of
  it is live`). Controls: the place receiver `a.peek(!a)` is rejected
  (h8); `print(a if c else b, grow(!a))` (Vec) and `print(a, grow(!a))`
  (Text) are rejected (h6, h15); `?a if c else ?b` as an argument is
  rejected (h3, h16).
- **Fix:** hold what a read reaches for the rest of the call or
  expression, as arguments are held: a `?self` receiver with no place
  gets `holdArgRead(obj)` before the arguments are walked, and each
  owning `==`/`!=` operand gets `holdArgRead` before the other operand
  is walked (one rule: "a read in place is held until its consumer
  runs"). Out of step 2's diff (base has it too), but it is the
  step-2 class (a read in place, Core §3; F1/F2's siblings), so it
  belongs in the step-2 follow-up or a hotfix like H. Add a matrix
  context "read, then a write lend in the same call" (`recv_read_then_write`,
  `eq_then_write`).

### Focus 1: statement temporaries

- **The kept silent removal** (`src/ownership.zig:780-788`,
  `releaseVarsFrom`) drops entries of `temps`, the statement's in-flight
  reservations (`addTemp`: a borrow being passed, a moved value's loans
  until the call ends, a place a receiver holds). A `temps` entry is never
  a holder: a value that survives carries its loans in a var's flow or in
  the `Value` the walk returns, and those are checked by
  `checkValueEscapesScope`, `reportHolder` and `dropStmtTemps`. Removing
  the entries is required, not just harmless: var ids are reused after
  `truncateVars`, so a stale entry would make a later var of the same
  statement look borrowed. Verdict: the silence cannot hide an accepted
  unsound program. (Low: say so in the comment at `:780`, "a `temps`
  entry reserves, it holds nothing past the statement", so the next
  reader does not try the assertion again.)
- **Siblings built, all rejected as on base:** a returned view of a
  local's field from an `if` branch (s1), of a temporary's field as a
  function's value (s2), a nested value block yielding a view of its own
  local (s3) or of a temporary (s4), a guard that stores a view of an
  arm's payload (s5), a `while` condition and body storing views of
  header temporaries (s6, s7), an `if … as` binding a view of a header
  temporary inside a value block (s8), an arm block storing a view of a
  temporary (s9).
- **`readLeaf`'s subtleties survived** (`src/typecheck.zig:3747-3772`):
  an in-place read is recorded only when `leaves.len > 1` (`print(o?)`
  records none); a branching value is split into leaves only when
  `handsOver` says `branches`, so an all-made one is one temporary at the
  branching node. `reads_made_branches_one_temporary.rig` pins both.
  One intended difference from base: `if` and `catch` leaves now go
  through `tailOf`, so a `catch |_|` handler block whose tail is a name is
  read in place (`print((f(c) catch |_| … b), a)`), where base rejected
  it. Sound under the sanitizer (m2); a wrong rejection made right.
- **One more behavior difference, harmless:** `readLeaf` no longer skips
  a lambda leaf (base: `leaf.isKind(.lambda)`); `handsOver` calls it
  made, so an owning closure read where it is made would get a temporary
  slot. No read context accepts a closure value (`print`, `==`, `+`,
  members), so it is unreachable today.

### Focus 2: B9's emit inversion

- Generator (`gen.py`: Text, Vec, a drop struct, Box,
  `*T`; ternary, ternary with a made branch, field ternary, `o?`, `??`,
  `catch`, nested) over contexts the matrix lacks: `*(E)`, array and
  constructor elements, typed and optional bindings, `Box(E)`, `break`
  values (plain and labeled), loop `else`, member and index reads,
  `print(E, E)`, `E == E`, `stmt if c`, `defer print(E)`, `assert`,
  `sink(E)`, kwargs, generic `gid(E)`, generic reads, closures (capture,
  inferred tail, block tail), `if`/`while`/guard conditions, nested value
  blocks, match arm tails, a match subject, `+E`, `_ = E`, `catch`
  handler blocks read and taken, `return` inside a branch. Runs:
  `g1.out` (1,155 programs: 191 clean, 964 rejected, 0 failures), `g3.out`
  (closure tails and value blocks, 210 programs: the 20 failures are all
  C1, the ternary forms of `lambda_tail`/`lambda_blk` for all five types;
  `catch` handler blocks, nested value blocks and match arm tails are
  clean), `g4.out` (conditions, guards, `break` values, loop `else`, match
  subjects, closures that read: 315 programs, 140 clean, 175 rejected, 0 failures). Every other cell is rejected
  or sanitizer-clean.
- Hand probes: `if (E) as v` and `while (E) as v` (take recorded;
  ownership rejects bare names), `*(E)` (rejected), `defer print(E)`,
  `!t.add(o ?? b)`, `Text(o ?? b)`, `replace`, generic `pick[T]` tails,
  `raw` function values: clean.
- Generic instances: a `Use` is keyed by node, so instances share it.
  Only `checkMatch` decides it by type (`take` when the subject cannot
  be copied), and then only for a `made` subject, which has no name
  leaves, so the shared fact never changes a take. Generic bodies cannot
  call methods on `T` (q1-q3), so receivers cannot differ by instance.

### Focus 3: `handsOver`

The positive list (`src/sema.zig`, `shapeOf`) is exhaustive with no
`else`, as planned. Checked kind by kind against the base classifiers:

- Names: a binding, param, capture, extern, function, or generic value
  parameter is `place`; a type or module name is `none`; an unresolved
  name is `place` (it was reported). Literals (both string forms,
  numbers, `true`/`false`) and `none` are `made`: this only changes
  emit's discard (`_ = 3` for `_ = &3`) and diagnostics' "copied from"
  notes.
- Paths: `Enum.variant`, `Type.m`, `module.name` are `place`; a path
  from a made or branching base of borrow type is `place` (it reaches
  storage elsewhere); otherwise `part_of_made`. `isTemporary`,
  `tempBase`, `lendTemp`, `resolvePlace` agree with base on every row.
- `match`, blocks, and value loops are `made`; `valueLeaves` stops at
  them (a read takes their value as one temporary). Name tails of a
  `match` in a read position are rejected by the ownership checker
  (m3), so the read-stops-at-`match` rule cannot read a name in place
  that a slot then drops.
- Low: `Hands.view` is computed and unit-tested but read by nothing
  (`grep` finds no consumer); CORE §9 lists "a view" among the *(built)*
  classifications. Either mark the flag *(planned)* or drop it until step
  3/6 consumes it.
- Low: `handsOver` recurses through `branches` on every call, and is
  called from ~57 sites, some of them inside recursions over the same
  tree (`movedTail`, `checkNoImplicitCopy`): quadratic in nesting depth.
  Harmless at today's sizes; memoize if step 3 adds callers.

### Focus 4: `exitTo`

- Every former `exitDefers`, `leaveTo`, and `capture` call now goes
  through `exitTo` (`capture` has no other caller); `Exit` and
  `Exit.goesOn` are unchanged (`src/ownership.zig:233-256`), and
  `exitTo` keeps `exitDefers`' order: defers, rewind where the path goes
  on, then report, then capture. `walkJump` keeps escape, defers,
  report.
- The new reports on `leave` (branches, `??`, `catch`, arms, joins, a
  written `defer`) and on a loop's failing condition and back edge can
  only add diagnostics: after `popScope` filters a branch's vars, the
  only loans `>= to.vars` left are on hidden statement temporaries, and
  liveness at `resume_at` (earlier than the statement's end) is a
  superset of liveness after it. The equivalence logs show no diagnostic
  change from it.
- The new reject tests (`defer_fallthrough_stores`, `nullish_continue_stores`,
  `catch_handler_break_stores`, `match_guard_stores_payload_loan`,
  `break_value_branch_leaves`) pass and each passed on base too, so they
  are regression tests, not fixes. No exit was found that drops a loan
  unreported.

### Focus 5: the flips

All sound under the sanitizer, with the right values and drop order:

- D9/D10: `match (mk(1) if c else <a)` with payload bindings, a payload
  moved out of an arm (`keep = <e`), and the untaken `<a` branch leaving
  `a` to its scope's drop (f2); `for` over made branches (the suite's
  `header_takes_made_branches`).
- D11: `+(a if c else b)` of `*N` (f3) and Text (`clone_reads_operand`).
- B6: `== none` and `!= .variant` of `a if c else mk()`, `s?`, `opt(c)?`,
  `(mk(true) if c else mk(false)) == none` (f4, f5): names read in place,
  made values dropped once.
- No other accepted program changed meaning: the final equivalence
  (`s2-bins/equiv-final.log`) differs in emit only for `_ = 3` and the new
  tests; `match +x` subjects are now taken rather than read as a header
  temporary, which changes when the clone is dropped, but no clonable
  type has an observable drop (`+` of a drop-glue struct is rejected).

### Focus 6: docs

- INTERNALS "What an expression hands over" and "Exits": accurate to the
  code (table rows, `resume_at` per exit, the hidden-var invariant
  `rewind` asserts). Two corrections:
  - `docs/INTERNALS.md:694-702`: the `Use` list says a context records
    `take` for "a binding, an argument, … `return`, a `break` value";
    add "a closure's value" once C1 is fixed, and state that a missing
    use is an error in every build (C2), not "an internal error in a
    Debug build".
  - `docs/CORE.md:733`: "a view" is *(built)* only as an unused flag
    (Focus 3).
- CORE §3 (`+e` reads; headers take values made there) and SPEC
  (`for` sources, `+e`, header takes) match the behavior probed; their
  examples run in the suite. CORE §9's per-path row *(built)* is true.

## Other notes (low)

- `src/typecheck.zig:3014`: the `==` path calls `readLeaf` only for an
  owning operand, so a non-owning branching operand records no `Use`.
  Harmless (its names have no drop flag, `takesTail` returns at
  `consumeFlag == null`), but it means "every value position records a
  use" holds only for owning values; say so where the INTERNALS text
  states the rule.
- `Facts.recordUse` overwrites silently (`gop.value_ptr.* = use`) while
  its comment says "a second record of the same use is no change". A
  second record of a *different* use is a classifier disagreement; a
  Debug assertion that the use is unchanged would catch the next one.
- Pre-existing, not step 2: `print(a.len + grow(!a))` (h13) prints 802,
  the length after `grow` ran, though `a.len` is written first; SPEC
  states left-to-right order only for call arguments (SPEC.md:2845).
  Worth a decision in SPEC; no memory error.
- The remaining syntactic kind tests (`emit.zig:3929` `@as` around a
  branching object, `emit.zig:1172` discards, `typecheck.zig:7256`) are
  Zig-typing or diagnostic choices, not hands-over classification; the
  `classify` lint is right not to flag them.
