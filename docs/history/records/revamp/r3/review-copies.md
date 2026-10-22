# Review: branch `copies` (one "copies" fact)

Reviewer: independent adversarial review, 2026-10-06.
Worktree `/Users/shreeve/Data/Code/rig-copies`, 6 commits on main 0cbf7e7a
(bc176613 at the tip). Built with `zig build` (bin/rig, bin/rig-oracle).
v0.2.2 comparisons use `.git/revamp/r3/rig-v022`.
Probes: `.git/revamp/r3/probes/review-copies/` (88 programs). Every probe
was run with `RIG_SANITIZE=1 bin/rig run P` and with `bin/rig-oracle P`.
No full suite, corpus, or matrix run (per instructions).

Shorthand below: `P=.git/revamp/r3/probes/review-copies`,
`run X` = `RIG_SANITIZE=1 /Users/shreeve/Data/Code/rig-copies/bin/rig run $P/X`.

## Verdict

- **The branch introduces no soundness hole that I could find.** Every
  newly accepted form I aimed at a type that secretly holds a view, a
  write view, a String, a Cell, a `*T`/`~T`, a Box, an owner or a unique
  type (nested in structs, arrays, optionals, enum payloads, generic
  instances) was either rejected or ran sanitizer-clean with the right
  output. The v0.2.2 hole (`r ?? W(...)`, `r?`) is closed, and its
  siblings are rejected too.
- **One Critical soundness hole exists, but it is pre-existing** (live in
  v0.2.2 and on the branch): a `while c as h: step` whose step uses `h`
  does not keep `h`'s loans live through the body. Use of freed memory
  under the sanitizer, and the oracle rejects it (compiler-accepts /
  oracle-rejects: a hard-gate difference). It touches this branch only
  in that `checkStepUses` now asks `copies`.
- **One High accept-means-correct bug is new on the branch:** a `??`
  whose result is a view (`(?P)?` left operand) is accepted where a `P`
  is expected, and the emitted Zig does not compile.
- One unlisted accepted→rejected regression with a wrong diagnostic
  (Medium), plus Low findings and design notes below.

## Critical

### C1. `while c as h: step` — the step's use of `h` does not keep `h`'s loans live (pre-existing; oracle DIFF)

- Probes: `p49-while-step-uses-slice-holder-after-push.rig` (struct holding
  `[]Int`), `p49b-while-step-uses-slice-after-push.rig` (binding is a
  bare `[]Int`), `p49d-while-step-text-holder.rig` (struct holding a
  `String`, reads freed bytes), `p49g-while-joined-step.rig` (joined
  condition `as h and ...`).
- Command: `run p49-while-step-uses-slice-holder-after-push.rig`;
  `bin/rig-oracle $P/p49*.rig`.
- Observed (branch and v0.2.2 alike): accepted;
  `error: rig: use of freed memory ... in main: while (mk(&v)) |h| : ({ k += rig.at(h.s, 0); })`.
  Oracle: `DIFF ... prod=accept ref=reject C4 16:6 cannot write 'v' while a read loan of it is live (L2, carried by 'h'#7)`.
- Expected: `!v.push(2)` in the body is rejected (`h`, used by the step
  after the body, still views `v`).
- Root cause: the step runs after the body but is written before it, and
  the step's use of a binding the condition declares is not counted as a
  later use when the body is walked (the loan ends at the last use the
  checker sees, which is earlier in source). Outer names are handled by
  the loop fixpoint (`p49c`, `p49f` are correctly rejected); `defer`
  reads are handled (`p50`, `p50b`). Only condition bindings leak.
- Typecheck's `checkStepUses` (typecheck.zig ~1474) only stops a step
  from using a `?T`/`!T` binding (`isReadOrWriteView`) or one that does
  not copy (`cannotCopy`); a slice, a `String`, or a struct holding
  either copies and is not a `?T`/`!T`, so it passes. This is a
  re-derived list ("is a view") where the fact needed is "may carry a
  loan" (`mayHoldView`), but the real fix belongs in ownership: the
  step's uses must extend the loans of the condition's bindings through
  the body, as the oracle models it.
- Not introduced by this branch, but it is a live hard-gate hole and
  `test/matrix.py` evidently does not generate a step that uses a
  condition binding. Fix-the-class siblings to cover: a step using a
  binding of `if`-joined conditions, `while ... as x and ... as y`, and a
  binding of a write-view holder (C1 is why `p47` below was accepted by
  v0.2.2 while assigning `n` under a live write view).

## High

### H1. `??` with a view result, where a value is expected: accepted, Zig does not compile (new on branch)

- Probe: `p51-coalesce-view-result-copy-out.rig`
  (`o: (?P)?`, `c: P = o ?? ?b`, and `fun pick(o: (?P)?, r: ?P) -> P  o ?? r`).
- Command: `run p51-coalesce-view-result-copy-out.rig`.
- Observed: `rig check` accepts; Zig fails:
  `error: expected type '__rig_main.P', found '*const __rig_main.P'  const c: P = (o orelse &b);`.
- Expected: runs and prints `1 2 3` (Core §4: a view of a value that
  copies is copied out where the value is expected), or is rejected.
- v0.2.2: rejected (`type mismatch: expected P, got ?P`). The same shape
  with `?Int` (`p51b`) runs on both, because a `?Int` is held by value
  (`lendByValue`) so no dereference is needed.
- Root cause: `compatible` now admits a copy-out (`copiedOut`), but the
  `??`/`catch` arm of the context-typed forms (typecheck.zig ~7928-7931)
  only checks `compatible(ty, expected)` and never calls
  `recordAdapted`, so no read-through is recorded on the `??` node and
  emit passes the pointer. Every `compatible` site that can succeed
  through `copiedOut` must record the adaptation; the others I checked
  (`checkExpr` ~7585, branch/match/block arms via `unify`, returns,
  arguments, fields, array elements, `Cell.set`, `Vec.push`, owned
  closure arguments, `[n of x]` and `fill` with a typed target; probes
  `p24`, `p53`, `p59`) do. The `.share` site (~7906) and the cast site
  (~8416) cannot meet a view. `catch` has the same gap but every
  function returning `(?P)!` already fails (M2), so only `??` is
  reachable today.
- The ownership side is conservative here (no read recorded, so `c`
  keeps the loan on `a`), so this is not a soundness hole.

## Medium

### M1. Loop step using a write-view holder: accepted→rejected with a false diagnostic (new on branch, not in the PR's equivalence list)

- Probe: `p47-while-step-write-view-holder.rig`.
- Command: `run p47-while-step-write-view-holder.rig`; compare
  `RIG_SANITIZE=1 .git/revamp/r3/rig-v022 run $P/p47-...rig`.
- Observed: branch rejects with
  `the loop step cannot use 'h': the body owns this 'W', which ends with the body before the step runs`.
  v0.2.2 accepts and prints `0 0 1 2 / 3 4`.
- `W` holds a write view and owns nothing, so "the body owns this `W`"
  is false. `checkStepUses` asks `cannotCopy` (now `copies`) a question
  about ownership (`moves`), the same mix-up the PR fixed for `match` in
  bc176613 (`mustTake`). The PR's claim "the only accepted→rejected
  programs are the two hole probes" does not hold for this shape (pup's
  corpus has none).
- Note that v0.2.2's acceptance of p47 was itself only possible because
  of C1 (`n = k` assigns `n` while `h`'s write view is live through the
  step). So rejecting it is the right outcome; the diagnostic and the
  classifier are not. With C1 fixed in ownership, this site should ask
  `mustTake` (moves) for "the body owns it", and the view case should
  be decided by "may carry a loan".

### M2. Returning a `?P` into a `(?P)!` emits `r.*` (pre-existing; accept means correct)

- Probe: `p52b-return-view-into-fallible.rig` (also explicit `return r`).
- Command: `run p52b-return-view-into-fallible.rig`.
- Observed (branch and v0.2.2): accepted; Zig fails
  `expected type 'anyerror!*const __rig_main.P', found '__rig_main.P'  return r.*;`.
- Expected: returns the view. A read-through fact is recorded on `r`
  although `?P` meets `(?P)!` as itself; I did not pin down which
  `readThrough` caller records it. Not introduced by the branch, but it
  blocks every `catch` of a fallible view, and with H1 fixed the `catch`
  copy-out path will need a test.

## Low

### L1. `|+h|` of a value holding a write view passes typecheck; only ownership rejects it

- Probes: `p11c-clone-capture-write-view-holder-read.rig`, `p14`, `p16`,
  `p17` (optional, generic struct, array).
- Observed: typecheck accepts (`cloneCapture` → `sema.cloneable(W) == .copy`),
  ownership rejects `cannot clone 'h': it holds a write view`. v0.2.2
  rejected these in typecheck with the `|+x|` diagnostic.
- `cloneable` answers `.copy` for a struct holding a write view
  (asserted by the sema unit test, `w ... .clone = .copy`), contrary to
  Core sentence 2 ("one holding a write view has none") and to
  `deepCloneable`, which refuses `info.views.write`. Soundness rests on
  the ownership backstop. `cloneCapture`'s non-view arm should answer
  `.copy` only when `copies` is `yes` (and `cloneable`'s `.copy` should
  require `copies`), so the one fact decides it and the diagnostic is
  the type checker's.
- The oracle accepts these (`stricter ... prod=reject ref=accept`): its
  model does not treat a duplicated write view as a conflict unless the
  two holders' uses interleave. Worth classifying.

### L2. Reading a field of `r ?? W(...)` is now rejected (unlisted accepted→rejected)

- Probe: `p60-coalesce-write-view-holder-field-read.rig`
  (`print((r ?? W(w: !b)).w.len)` with `r: ?W?`).
- Observed: branch rejects (`a view cannot give up the write view inside it`);
  v0.2.2 accepts and prints `1`.
- Defensible: it is exactly how an owner already behaves
  (`print((r ?? Vec()).len)` is rejected by v0.2.2), and the write
  through the same temporary was never allowed. But it is another
  accepted→rejected program the PR's equivalence claim does not list.

### L3. Bare write view as a struct field value is rejected (pre-existing, unclassified oracle difference)

- Probes: `p25-write-view-struct-literal-field.rig` (`Q(p: w, o: w)`,
  `w: !P`), `p25b` (same with `!Int`).
- Observed: `cannot lend 'w' to write while a write loan is live` at the
  second field; oracle `stricter ... prod=reject ref=accept`, not in
  `test/oracle/differences`. Core sentence 1 says a bare write view of a
  value that copies reads the value; a constructor field treats it as a
  write lend. Same on v0.2.2.

## Design notes (POLS, the kept boundary)

`x = r` with `r: ?P` stays a `?P` (and keeps the loan), while every
neighbouring form copies the `P` out:

| Form | Result | Probe |
|---|---|---|
| `b = r` | `?P`, `a` stays lent | p45 |
| `b = r if c else p` | `P` copy | p45b |
| `b = w` (`w: !P`) | `P` copy | p45c |
| `b = o ?? P(...)` (`o: ?P?` view) | `P` copy | p45f |
| `id(?n)` / `id(?a)` | `Int` / rejected (`T = ?P`) | p45d |
| `r == P(x: 1)` | compares values | p45e |

I could not break anything with the boundary (the binding is an ordinary
view, and its loan is tracked), but adding an `else` arm, or making the
view a write view, changes the binding's type and its loans. The single
rule a reader would guess is "a bare read of a view of a value that
copies gives the value" (Core sentence 1 already says so for write
views). If the owner keeps the boundary, SPEC should state the one
sentence that distinguishes `b = r` from `b = r if c else p`.

Also: `[3 of r]` with `r: ?P` gives `[3]?P` (views, carrying the loan),
while `b: [3]P = [3 of r]` copies. Consistent with the boundary, worth one
line in SPEC §5.

## What I checked and found sound

Each with the probe that shows it; all rejected where a loan or the
write-view rule must reject, and sanitizer-clean with correct output
where accepted.

- Copy out of a read view, struct holding `?Vec`: typed binding (p02),
  branch (p18, p18ok), `??` in a function and a local (p19, p20 + ok),
  array of views (p21 + ok), result through a function, holder re-pointed
  (p22 + ok), String holder with the Text dropped (p23).
- Copy out at emit sites (p24): struct literal fields (value, optional,
  array), `Vec.push`, `Cell.set`, typed array literal, optional binding,
  owned-closure argument, `[n of r]` typed, `fill`, call argument, result
  lifted to optional. Branches/match/function arms (p53), view-or-optional
  branch (p59).
- Bare write view read as its value, holder of `?Vec` (p03).
- Write-view holder `W` through a read view, at every site: `x = r[0]`,
  `x: W = r[0]`, argument, struct field, array literal, `Vec.push`, both
  branch forms, `[2 of r[0]]`, `r ?? W(...)` as argument/field/array/result,
  `r?` (checked with throwaway variants of p27; all rejected), field of a
  read or write view (p27, p28), return of a view's field (p29), generic
  copy (p26, p30), match payload (p15), `|+x|` of W in optional, enum,
  generic struct, array (p14-p17, rejected by ownership; see L1).
- `fill`/`copy`/`[n of x]` with read-view elements: owner mutated (p06,
  p07, p08), stored through a write-slice parameter past the source's
  scope (p39, p40), local scope (p41, p42), String views of a dropped
  Text (p43), returned (p44), view of a temporary (p54, p56), closure
  element (p55).
- `|+x|` deep clone: Vec of Text returned in an owned closure, cloned,
  dropped unused, called many times, handles dropped before the call
  (p05); failing call between capture and use, closure built from a
  parameter view and outliving the source (p34); through read and write
  views of Vec, `(*N)?`, Box, array of Text, `Text?`, a struct of Text
  and Vec of handles (p31); enum with owning payloads, Box, struct, owned
  closure cloned and dropped (p62); clone of a Vec of slices keeps the
  slices' loan, not the holder's (p32, p32ok); Vec of Strings keeps the
  Text's loan (p33); String holder through a view (p04); copy through
  views keeps no loan on the owner (p57, p58, p58b).
- Owned closures with plain data: String-holding struct stored into a
  captured Cell (p01, p37, p37b: rejected), result viewing its own
  capture (p09), result carrying the argument's loan (p35, p36), large
  nested structs/arrays/optionals through the erased call (p38).
- Generic `Requirement.copies` instances: plain struct with String,
  array, optional, nested optional, `|+x|` of `T`, `[n of x]`, `fill`,
  `??` (p46).
- Oracle over all 88 probes: 8 differences, of which the only
  compiler-accepts/oracle-rejects ones are C1 (p49, p49b, p49d). The
  rest are compiler-stricter (L1, L3).

## Duplication sites checked against the one fact

| Site | Decides by | Note |
|---|---|---|
| bare binding `x = w` / `x = h.w` / `x = ws[i]` | `copiedThrough` (`bindingValue`) | read view keeps `readValue` (boundary) |
| copy out where a value is expected | `copiedOut` / `recordAdapted` | gap at `??`/`catch` (H1) |
| `readsThroughWriteView` (ownership) | `copiedThrough` | ok |
| `[n of x]`, `fill`, `copy` | `cannotCopy` (`copies`) | ok |
| `Cell.get`, `Vec.get`, sequence `get`, Cell's Vec reads | `cannotCopy` | ok |
| `??`, `?`, `if ... as` through a view | `cannotCopy` | ok; p60 (L2) |
| `|+x|` | `cloneCapture` → `cloneable` | `cloneable(W) == .copy` (L1) |
| `+x` | `cloneable` | same as L1, ownership backstop (p12) |
| generic copy | `Requirement.copies` | ok |
| match made subject | `mustTake` (moves) | ok after bc176613 |
| loop step binding | `cannotCopy` | should be moves + may-carry-loan (M1, C1) |
| `for` element, match payload, header `viewed`/`held` | `copies` | renamed only; ok |
| emit `elemInPlace`, storage `payloadByAddress` | `copies` | renamed only |
| Cell/Signal element, owned closure params/results | `isPlainData` | ok |
| drop of plain data, header copy, `armsBind` | `isPlainData` + `mayHoldView` | unchanged |
| struct literal field from a bare write view | ownership write lend | L3 (pre-existing) |
| return into `(?P)!` | a read-through recorded somewhere | M2 (pre-existing) |
| `defer` reads | loop/scope liveness | ok (p50, p50b) |
