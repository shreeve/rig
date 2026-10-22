# Review: one-decider-2 at 173b6a6e (base main 53cbff4f)

Fast-gate independent review. Worktrees: branch at
`scratchpad/od2-review`, base at `scratchpad/od2-base`, both built with
`zig build` (and `zig build oracle` on the branch).

## Verdict

**No Critical or High findings.** No program I ran changed behavior,
and I found no soundness hole. Every claim I could test held. The
findings are hardening notes, all Low.

## 1. Byte-identity (verified)

`test/equiv.py base new` through `heavy.sh` (cpuq), run twice: cached
at `-j 5`, then `--no-cache` at `-j 6`.

- Result: **9,721 programs, 0 differ**, on every section: parse,
  normalize, check, facts, sema, storage, emit, and pkg (the sanitized
  package hash).
- Accept/reject, diagnostics, every facts dump, and the emitted Zig are
  identical.

A note so nobody repeats my scare: the scratchpad held an `equiv-keep/`
directory from a 2026-10-07 session, with files that differ. They are
stale, not from this run. The fresh `--keep` directory stayed empty.

## 2. Order hazards (none found that change behavior)

- **Drift becomes a panic, not a miscompile.** A decision recorded early
  is recomputed by `verifyDecisions` at the end of the plan, which seals
  the record afterwards.
  - The plan runs unconditionally after typecheck, so an early record
    that drifted would abort the compiler.
  - Erroneous programs hit this check too. A broken generic program with
    guarded arms, unknown variants, undefined names, a `for` over a call
    view, and `as` produced the same 9 diagnostics on both compilers,
    with no panic.
- **Decisions asked after the seal are not an error by themselves.**
  - After the seal, `decide` recomputes the answer and skips the record.
  - Only emit's `Facts` reads (`need(...)`) turn a missing record into
    "internal error: a decision no checker made".
  - The plan's `walk` visits every child of every node (`rig.children`
    is `items[1..]`), so every tree node emit can reach gets its
    per-node answers. I checked each emit site against what the plan
    asks:
    - `isPureArg` for assigned values and indexes is asked inside
      `plan.openAssign`/`indexOf`, and emit's owning-place path uses
      `openNewValue` instead.
    - `headerPoints` is asked for every `headerSubject` and a move's
      operand.
    - `subjectHold` asks `headerPoints(value)` itself.
    - `catchAllCaptured` and `bindsByAddress` are asked for every arm,
      guarded arms included.
- **Probes**, each run under `RIG_SANITIZE=1` on both compilers. All
  outputs are identical, with no internal error and no leak:
  - `m1/`, two modules:
    - a generic enum and a generic struct from `lib`;
    - a generic guarded match, `?self` methods returning `(?T)?`, and a
      nested match with guards in both levels;
    - `match mk(i)` with guarded arms and a catch-all;
    - `for x in ?q` with `if ?x as y`, and `while !q.pop() as y`;
    - `print` of views (`?b.name`, `b.items[0]`, `b.first()`).
  - `m2/`, defaults across modules: a hoisted call
    (`maybe(i-1) ?? continue` after an owned `Text(...)` argument) to a
    lib function with defaults, a local function with defaults, and a
    `!self` method with a default.
  - `t1.rig`:
    - a closure whose body matches a made value;
    - a generic `Box2[T].show` printing `?self.v`;
    - a `defer` whose call lends a temporary into a match function;
    - `for x in <v`;
    - a `test` block with a match, run with `rig test`.
  - `f1.rig`: `for` over branching sources. Both compilers reject it
    identically.
- **One thing I could not make diverge.** `readBinding`'s unification
  loosens the rule for a payload whose binding is `?F`. That is a read
  view of a non-copy field, matched in place. The old rule
  (`catchAllByAddress(f.ty, true)`) still pushed a `no_cell` generic
  requirement there. The new one (`bindsByAddress`) skips it, because
  the binding is a pointer.
  - The new rule is the correct one: there is no copy, so nothing
    forks.
  - Equiv shows no corpus program reaches the difference.
  - My two probes (`p1.rig`, `p2.rig`: `Vec[T]` and `P[T]` payload
    fields with `T = C` holding a Cell) were accepted and ran the same
    on both compilers.
  - The PR's "changed no accepted or rejected program" holds for the
    corpus. In principle the rule is a loosening, and it is sound.

## 3. The isNone drop (no mismatch that matters)

`n1.rig` and `n2.rig`, both under `RIG_SANITIZE=1` in debug and run as
`--release`. The output is identical on both compilers and between
debug and release, and the drop counts are exact. `n1.rig` covers:

- `w.upgrade() != none` and `== none`, with `none` on either side;
- `and`/`or` short-circuit;
- as call arguments;
- a `while` condition (4 drops for 4 tests);
- a `match` subject;
- `mke(1) == .b` and `.b == mke(1)` (`isVariantDiscard`);
- after `-h`.

Emit drops the operand at the test, earlier than the ownership checker
models. The checker treats it as a temporary read in place, alive to the
end of the statement. Its window is therefore a superset of the real
lifetime, so the checker is conservative, not unsound:

- Nothing can name the operand afterwards.
- `decideDropsWhenTested` excludes `dropsTemp`, so there is no second
  drop.
- Any loan the operand carries is held longer than needed, never
  shorter. In `n2.rig`, `G` holds `!Vec[Int]` and its `drop` pushes
  through it:
  - `print(mkg(!v) != none, v.len)` is **rejected** ("use of `v` while a
    write loan is live"). That is the conservative side.
  - `ok = mkg(!v) != none; print(ok, v.len, v)` runs clean:
    `true 1 [9]`.

The checker could be made exact later, as the PR says, but there is no
double drop, leak, or use after drop.

## 4. Enforcement (verified by mutation)

`zig build test --cache-dir "$(mktemp -d)"` through `heavy.sh`, each
mutation reverted after:

- Adding `@import("sema.zig")` to emit.zig fails "emit reads the
  checkers' decisions only through Facts": "emit.zig imports sema.zig,
  which only facts.zig may" (131 pass, 1 fail).
- Adding an 8th `Pending` method used by emit fails the same test at
  `decls.len <= pending_budget` (131 pass, 1 fail).

## 5. Oracle

`bin/rig-oracle` on all probes (`n1`, `n2`, `t1`, `p1`, `p2`, `m1`,
`m2`, `e1`): **0 differences**. For `n2`: 3 functions decided, 2
accepted, 1 rejected, matching `rig`.

## Findings

### Low 1. Facts passthroughs are not budgeted

The guard covers imports and `Pending` only. A new
`pub fn x(f: Facts, ...) { return storage.x(f.c(), ...); }` on `Facts`
lets emit make a node decision outside the budget, and no test notices.

`Facts` already has node-level passthroughs of this kind:

- `receiverWrites`, `lentLiteral`, `lambdaYields`, `isNoneLeaf`;
- `textCall`, `isPrintCall`, `firstStmtTemp`, `stmtTemps`.

Most are syntax- or type-level, so this is a review-discipline gap, not
a bug. Suggestion: list the allowed node-level passthroughs in the test,
the way `allowed` lists imports.

### Low 2. Emit still re-derives a variant of `holds_view`

In `emitMatch`'s plain-switch path (src/emit.zig:2522):

```zig
const by_ptr = !(try self.hasStorage(subject)) and self.isPtrViewExpr(subject);
```

Here `subject` is `lentPlace(Match.subject)`. The recorded `holds_view`
uses `Match.subject` itself, and `held_view` from the record is in scope
a few lines above.

- The two answers can differ only for `match ?call()` / `match !call()`
  of a call returning a pointer-held view.
- This is unchanged from base (byte-identical), so it is not a
  regression.
- It is a second classifier for a recorded fact and a candidate for the
  next stage.

### Low 3. `check` is about 30% slower on the largest program

`test/corpus/fix11-cli/lib.rig` (6,395 lines), `rig check`, 3 runs each:

| Compiler | Time |
|---|---|
| base | 0.18–0.19 s |
| branch | 0.24–0.25 s |

The likely cause is `hands` and `reaches_leaf` decided for every
expression and then all recomputed by `verifyDecisions`. This is not a
correctness issue. If it matters, the verification could sample, or run
only under a debug flag. (I did not profile.)

### Low 4. `decisionKey` collision argument

For an unnumbered list node, `decisionKey` keys by
`items.ptr | 1 << 33`. Two live nodes whose item pointers differ only in
bit 33 would share a key. In practice that cannot happen: they would
have to sit 8 GiB apart in one arena. The `decision()` identity panic
also catches it for lists.

Leaves share keys by source position, as all leaf facts do. So
duplicated leaves from a rewrite share answers, which matches how every
other leaf fact behaves.

## Summary

- **Behavior changed for any program?** No. Equiv shows 0 differ out of
  9,721, cached and uncached, and all probes are identical on both
  compilers.
- **Soundness hole?** None found:
  - the isNone drop is conservative in the checker;
  - the for-consumes checker change only makes the checker walk what
    emit does;
  - the `readBinding` unification is a sound loosening that no program
    reaches.
- **Recommendation:** land. Consider Low 1 (passthrough budget) and
  Low 2 (`by_ptr`) for stage 3.
