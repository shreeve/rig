# Review 2: branch `copies`, the fix commits

Reviewer: targeted adversarial re-review, 2026-10-06.
Worktree `/Users/shreeve/Data/Code/rig-copies`, head 4a59ae5b. Scope: the fix
commits 7b84177d (`??`/`catch` copy-out, fallible view returns), 99a3b8f4
(`checkStepUses` asks `mustTake`), 0f4d23c0 (`cloneable` of a write-view
holder), and the merge of main 9e8ac153 (dee8c5dc).

Builds compared: branch `bin/rig` and `bin/rig-oracle`, main
`/Users/shreeve/Data/Code/rig/bin/rig` (9e8ac153), the pre-fix branch
dee8c5dc (built in a temporary worktree, since removed), and
`while-step-hotfix` 4ff42874 (same).

Probes: `.git/revamp/r3/probes/review-copies-2/` (`q*.rig`, 96 programs),
plus a generated grid in `grid/` (224 programs: 4 types x 5 forms x 12
contexts; `gen.py`, `run_grid.sh`, results in `grid/grid.out`).
`run-probe.sh P...` runs a probe on branch, main, and the oracle.
Shorthand: `P=.git/revamp/r3/probes/review-copies-2`,
`run X` = `RIG_SANITIZE=1 /Users/shreeve/Data/Code/rig-copies/bin/rig run $P/X`.
No full suite was run. The grid and the acceptance comparison ran through
`heavy.sh`.

## Verdict

- **The fix commits add no soundness hole.** Every program I aimed at the new
  emit paths either ran sanitizer-clean with the right output or was
  rejected. Those paths are fallible and optional views returned through
  `!`, `?!`, `catch`, `catch |e|`, `catch |e| return e`, `??` chains,
  `?? return` and `?? break`. I also tried views of temporaries, views of
  block locals, generics, closures, methods, struct fields, `Vec`, arrays,
  `Cell`, and write views returned as read views. A view of a local cannot
  escape through the new return path: q01, q01b, q01c and q01d are all
  rejected with `cannot return a view of 'p'`.
- **M2 is fixed, and so is the rest of its class on main.** Main fails to
  compile every function that returns a pointer view through `T!` or `T?!`:
  by name, through `if`, `match`, `catch`, `??`, `get(..)!`, generic `?T`
  and `!T`, closures, nested `((?P)?)?!`, and `!Int`. Each of these runs
  correctly on the branch (q03*, q07c-e, q08b, q08e, q12a, q13*, q14*).
- **H1 is fixed only where the value itself is expected.** Where an optional
  of the value is expected (`c: P? = o ?? ?b`, `catch` into `P?`, a `P?`
  argument or field), the program is still accepted and its Zig does not
  compile: **H2 below (High)**. These are the 45 failures of the grid's 224
  programs, and the class's only remaining member.
- **M1 is fixed.** `checkStepUses` is now equivalent to main's. The C1 family
  is unchanged: still open on the branch exactly as on main, and closed by
  `while-step-hotfix` (verified).
- **L1 is fixed.** `+x` and `|+x|` of a write-view holder are now rejected in
  typecheck, with the Core's reason.
- **The merge dropped nothing.** Re-merging reproduces the merge commit's
  source files byte for byte. Main's tests and examples show no
  accept→reject change.
- **Oracle:** over all 320 probes there are 6 differences. Two are
  compiler-accepts / oracle-rejects (q10a, q10d). Both are the pre-existing
  C1 hole, identical on main, and fixed by the hotfix. The copies changes
  introduce none.

## High

### H2. `??` or `catch` whose value is a view, where an optional of that value is expected: accepted, but the Zig does not compile

- Probes:
  - `q09a-coalesce-copyout-into-optional.rig` (`f: P? = i ?? ?b`, with `i: (?P)?`)
  - `q09b-catch-copyout-into-optional.rig` (`o: P? = get(?a, true) catch ?b`)
  - `q09c-coalesce-copyout-optional-sites.rig` (a `P?` argument, a struct field, a function result)
  - `q09e-coalesce-none-into-optional.rig` (`?? none` and `catch none` into `P?`)
  - grid: every `*-typedopt`, `*-argopt` and `*-fieldopt` program for the types P, S (String holder) and V (`?Vec` holder), in all 5 forms (45 programs).
- Command: `run q09a-coalesce-copyout-into-optional.rig`.
- Observed (branch): accepted; Zig fails with
  `expected type '?__rig_main.P', found '*const __rig_main.P'  const f: ?P = (i orelse (&b).*);`
  and `(get(&a, true) catch (&b).*)`.
- Main rejects all of these (`type mismatch: expected P?, got ?P`). The
  pre-fix branch dee8c5dc already accepted the `??` forms with the same Zig
  failure, so 7b84177d did not cover this sibling of H1. The `catch` forms
  reach Zig only now, because M2 used to fail first.
- Expected: prints `1`. Core §4 copies out a view of a value that copies
  wherever the value is expected, and `P?` takes a `P`. Otherwise the
  program should be rejected.
- Root cause: `fallbackType` (typecheck.zig:3527-3533) widens the result to
  the expected optional when `compatible(inner, i)` holds. Since `compatible`
  now admits `copiedOut`, `inner = ?P` against `P` succeeds, and
  `synthCoalesce` and `synthCatch` return `P?` itself. The right operand is
  then checked against `P?` and copied out on its own (`(&b).*`). The
  `??`/`catch` node's type equals `expected`, so the `recordAdapted` that
  7b84177d added records nothing, and the left operand (`(?P)?`, or a
  `(?P)!` call) is never read through. This is one more `compatible` site
  that can succeed through `copiedOut` without recording the adaptation,
  the class the first review named.
- Likely fix: have `fallbackType` widen only when `meets(inner, i)`. The
  result then stays `?P` (or `(?P)?`), and the outer `recordAdapted` copies
  the whole `??`/`catch` out, as it does for `P` (`((i orelse &b)).*` lifts
  to `?P`). The pinning test should cover `?? ?b`, `?? none`, `catch ?b`,
  `catch none`, and a `P?` argument and field.
- Shared root with main: main has the same failure for a moved write view of
  an Int (`q09h-coalesce-moved-write-view-into-optional.rig`,
  `f: Int? = <i ?? none` with `i: (!Int)?`, Zig `expected '?i64', found '*i64'`
  on both). The branch widens it from `!Int` to every view that copies out.
  The `meets` fix covers both.
- Read views of an Int or plain enum are held by value, so those programs
  compile and print the right values (q09g; the grid's E rows).
- Not a soundness hole: Zig rejects the program, and the ownership side
  keeps the loans.

## Low

### L4. `catch` copies a view out after the handler block, so a handler-scoped temporary or local cannot be copied out, while `??` and `if` arms can (unclassified oracle differences)

- Probes:
  - `q05g-catch-copyout-handler-temp.rig` (`v: N = get(?a, false) catch ?N(s: "tmp", k: 7)`)
  - `q06a-catch-handler-block-local-copyout.rig` and `q06f-catch-handler-block-int-copyout.rig` (a handler block that ends in `?loc`)
- Observed: rejected (`a view of the temporary ... outlives its statement`,
  `` `loc` does not live long enough ``). The oracle reports
  `stricter ... prod=reject ref=accept`; these differences are not in
  `test/oracle/differences`.
- The siblings are accepted: `v: N = o ?? ?N(...)` (q05k), and
  `v: N = if c` with a block arm that ends in `?loc` (q06c, which prints
  `loc 3 99`). Emit copies an `if` arm out inside the arm
  (`break :blk (&loc).*`). For `catch`, the read is recorded on the `catch`
  node, so emit derefs after the handler's labeled block:
  `(get(..) catch |e| blk: { ...; break :blk &b; }).*`.
- Sound: the checker rejects exactly what emit would make dangle. But the
  rule a reader would guess ("copied out where the value is expected")
  holds for `??` and branch arms, and not for a `catch` handler. Either
  record the copy-out on the handler's leaf (and on the value side), as
  `unify` arms do, or classify these as compiler-stricter differences.

### L5 (pre-existing). `f(!vs) catch !vs` is rejected; the oracle accepts it

- Probe: `q07l-write-catch-same-owner.rig`. The rejection and the stricter
  difference are identical on main. The handler runs only after the call
  failed, so the first write loan is gone by then. Rust rejects the
  analogous `f(&mut v).unwrap_or(&mut v)`. This needs a classification, not
  a fix.

## Design notes

- The fallback of `catch`, and of `??` on a `(?P)?` left operand, must have
  the left side's view type: `get(?a) catch P(x: 9)` and
  `(opt(..) catch none) ?? P(x: 9)` are rejected with
  `expected ?P, got P` (q04a, q04b). Meanwhile `o ?? r` with `o: P?` and
  `r: ?P` copies out to `P` (q04j), and so does `r ?? P(...)` with `r: ?P?`
  (first review p45f). This is the same on main, so it is not a regression.
  It is one more boundary SPEC should state, or remove, alongside the
  `b = r` boundary from the first review.

## Per-commit findings

### 7b84177d: `??`/`catch` copy-out; fallible view returned as the pointer

- `emitReturnValue` now emits the pointer for any return type whose
  success value, under any number of optionals, is a pointer view. An
  error value stays bare.
- I checked that this matches what the checkers walk. M2's `r.*` came from
  `emitName`'s default dereference of a pointer local, not from a
  read-through fact: emit's `readsThrough` skips names, and `meets(?P, (?P)!)`
  holds, so `recordAdapted` records nothing. `want_ptr`/`ptr_tail`
  therefore overrides no fact the ownership checker relied on. Escapes are
  still caught (q01*), and loans still flow through `catch`, `!` and
  generic results (q02, q02b, q02d, q02e, q07b, q07h, q07i, q07k, q13a's
  `cannot lend 'a' to write while a read loan is live`).
- Forms that run correctly on the branch (all fail to compile on main):
  - return by name, `if` with an error leaf, and `match` with an error arm (q03d-f);
  - `catch` inside the function, and `catch |e| return e` (q03g, q03h);
  - `??` and `?? return` (q03i, q03j);
  - `(!Int)!`, `(?P)?!` and its propagation, and `(!P)?!` (q03k, q03m-o);
  - generic `(?T)!` at T = P, Int and `Vec[Int]`, and generic `(!T)!` (q07c, q07d);
  - closures in either nesting (q07e, q14a, q14b);
  - a view field of a holder (q12a), a write view returned as a read view (q13a, q13b);
  - `((?P)?)?!` (q08b), and errors from two error sets with `catch |e|` (q08e);
  - a `catch` handler block (q04f), `catch` then `??` (q04h), a `??` chain (q04i), `?? break` (q04k), `?? return` in a sub (q04l).
- Already correct on main: `(?Int)!` (by value, q03l) and methods
  (`?self` / `!self` returning `?self.p` / `!self.p`, q07f).
- Copy-out where `P` is expected is correct in all 174 accepted grid
  programs. The contexts are a typed binding, an argument, a struct field,
  a function result, `Vec.push`, an array literal, `Cell.set`, assignment,
  and a branch arm. The types are a plain struct, a String holder, a
  `?Vec` holder, and a plain enum. The forms are `??`, `catch`, a failing
  `catch`, `(opt catch ?b) ?? ?b`, and a `??` chain. Every output matches
  the expected value, and the oracle is silent on all 224 programs.
- A String holder copied out keeps the Text's loan
  (q05a, q05b: `cannot drop 't' while it is lent`). A copy taken before the
  holder is re-pointed keeps the old view (q05c). A view of a temporary in
  the call argument is copied out inside the statement (q05e), and kept
  past it only with a diagnostic (q05d, q05h, q05j).

### 99a3b8f4: `checkStepUses` asks `mustTake`

- Main's `cannotCopy` was `moves`-based. So the branch's
  `isReadOrWriteView` then `mustTake` makes the same decisions as main's
  `cannotCopy` then `isReadOrWriteView`: a view never moves, so swapping the
  two branches changes nothing. The `.depends` arm now requires `.copies`
  where main required `.no_move`. The two cannot differ at an instance,
  because a generic `T` may not hold a `?T`, `!T` or slice (q07a), so for an
  allowed `T`, "does not copy" coincides with "moves".
- Nothing new is admitted. Through the C1 hole, the step can still use a
  binding whose loan the body breaks, on branch and main alike:
  - `q10a-step-write-slice-holder-after-push.rig` (struct holding `![]Int`;
    the step writes through it after the body grew the Vec):
    `error: rig: use of freed memory` on both, and an oracle DIFF.
  - `q10d-step-write-view-text-holder.rig`: the oracle reports a DIFF.

  The `while-step-hotfix` binary rejects both
  (`use of 'v' while a write loan is live`,
  `cannot reassign 't' while it is lent`). It also still accepts the
  branch's new `copies_loop_step_write_view_holder.rig` (`15 3`), and
  rejects first-review p47 for the right reason
  (`cannot reassign 'n' while it is lent`). The two branches agree.

### 0f4d23c0: `cloneable` of a write-view holder is `.no`

- `+h`, `|+h|`, `|+o|` and `+o` are now rejected in typecheck for a
  write-view holder and for `(!Int)?` (the commit's reject test, q11a,
  q11c). `+w` and `+v` of a bare `!Int` and `!P` still copy the value
  (q11b: `1 2 2 5`). A holder of read views and a String still clones and
  captures (q11d; main rejected the capture).
- The `.no` arm's new first diagnostic only fires for a value with no drop
  glue that holds a write view. Owners holding a write view still get the
  general message. Ownership's `reportArmView` hint stops offering `+name`
  for such a binding, which is now correct. The emit callers never see `.no`.

### Merge dee8c5dc (main 9e8ac153 into copies)

- `git merge-tree --write-tree bc176613 9e8ac153` gives the same blobs as
  dee8c5dc for typecheck.zig, emit.zig, sema.zig, ownership.zig, rig.zig,
  storage.zig and resolve.zig. `git show --cc dee8c5dc -- src/` is empty;
  the only conflict was `test/oracle/coverage`.
- Main's additions call none of the helpers the copies side changed or
  removed: `cannotCopy`, `compatible`, `readValue`, `operandValue`,
  `holdsWriteView`, `payloadByAddress`, `readByAddress`, `fieldIsPointee`,
  `findMove`, `isClosureValue`, `satisfies`, `checkRequirements`,
  `copyable`, `isCopyElement`, `readsAsValue`. So no main-side call
  silently changed meaning.
- Acceptance comparison: I ran `rig check` with main's and the branch's
  binaries on all 8747 `.rig` files in main's `test/` and `examples/`.
  There are 0 accept→reject changes and 8 reject→accept changes: the copies
  feature's intended acceptances, such as `test/reject/ownership/write_view_copied.rig`
  and `test/corpus/r3-s36-*`. All 8 run sanitizer-clean, and the oracle is
  silent on them.

## Oracle summary

`bin/rig-oracle $P/*.rig $P/grid/*.rig`: 320 programs (q09h checked separately, no difference), 6 differences.

| Probe | Kind | Status |
|---|---|---|
| q10a, q10d | DIFF (prod accept, ref reject) | C1, pre-existing on main, fixed by while-step-hotfix |
| q05g, q06a, q06f | stricter | L4, new forms (main rejects them by type) |
| q07l | stricter | L5, pre-existing |

## Soundness: does any hole remain?

None that comes from the copies branch or its fix commits. The only
sanitizer failure I found (q10a) is C1. It is pre-existing, identical on
main, and closed by `while-step-hotfix`, which should land before or with
`copies`. The open accept-means-correct bug is H2, which Zig rejects at
compile time.
