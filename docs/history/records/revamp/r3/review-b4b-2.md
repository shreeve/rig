# Review: B4b part 2 (ddefa968, "Let a read match's payload views outlive the arm where the match reads in place")

Reviewer: independent fast-gate review, soundness and accept-means-correct only.
Diff reviewed: `git diff d9225c3c ddefa968` (src/storage.zig `catchAllByAddress`,
typecheck `arm_local`, emit `emitCapture`, ownership comment, oracle arm-local rule removed).
Worktree: ddefa968, `zig build` + `zig build oracle`. Probes: `.git/revamp/r3/probes/review-b4b-2/`
(`run.sh <probe>` runs: branch check, main check, oracle, `RIG_SANITIZE=1` debug run, `--release` run).

**Verdict: soundness holes remain. Two, both generic-only, both regressions against main
(main rejects every probe below with the arm-local diagnostic).** Do not merge as is.

---

## Critical

### C1. A generic branching subject over places is "in place" for typecheck but not for ownership (guarded: a copy; unguarded: no loan)

Probes:
- `p69_generic_branch_guarded.rig` (guarded, use of poisoned/freed storage)
- `p63_generic_branch_of_places.rig`, `p64_generic_branch_reassign.rig`,
  `p65_generic_branch_text.rig`, `p66_generic_branch_uaf.rig`,
  `p67_generic_branch_scope.rig`, `p70_generic_branch_catchall.rig` (unguarded: missing loan)

Shape (generic body, `Opt[T]` moves `depends`):

```rig
match o1 if clobber(0) > 5 else o2
  .some(x) if clobber(2) > 100 => print(x)
  .some(x) => saved = ?x
  .nothing => pass
print(saved)
```

Observed (p69, `RIG_SANITIZE=1 bin/rig run`): accepted; prints
`Pt(x: -6148914691236517206, y: -6148914691236517206)` (0xAA poison), then for `T = Text`
panics (`programmer bug caused syscall error: INVAL`, signal 6). Expected: rejected (main
rejects: "a view of `x` does not outlive the `match`"). The oracle reports
`DIFF ... prod=accept ref=reject C5 ... x does not live long enough`.

Emitted Zig (p69): `var __rig_subject_5: Opt(T) = if (clobber(0) > 5) o1 else o2;` then
`const x = &__rig_subject_5.some.v; saved = rig.lend(x);`: the view points into the match
block's copy, which is poisoned at block exit.

Unguarded (p64/p66/p67/p70): emit writes `switch (if (c) o1 else o2) { .some => |*p| ... }`; Zig
propagates the ref into the `if`, so the payload pointer is o1's or o2's own. But ownership
binds the payload with `info.root == null` and `loans = scrut_value.loans`, and the branch reads
`o1`/`o2` as copies (moves `depends`), so no loan on `o1`/`o2` is recorded:
- p64: `o2 = Opt.some(v: <c)` after the match is accepted; `saved` (a read view) then prints the
  new value `Pt(x: 5, y: 6)` (a read view sees a mutation, Core violation).
- p66: `o2 = Opt[T].nothing` accepted; `saved` reads the dropped Text's slot: prints empty
  instead of the text.
- p67: o1/o2 live in an inner block; `saved` is used after the block ends: accepted, prints
  empty (view of dead storage).

Root cause: `storage.reachesPlace` treats an `if` whose leaves are bare places as reaching a place
(`.branches` case), so `matchesInPlace` is true and typecheck sets `arm_local = false`. But:
(a) `storage.subjectHold` for that subject is `.copy` (no storage, not a pointer view, no
temporaries), so a guarded match switches on a copy; (b) the ownership checker treats the
subject as a value read (copies), not a place, so no loan reaches the leaves. typecheck's guard
against this, "a `match` reads a place or takes a call's result; bind this `E` to a name first",
fires only for `sema.moves(...) == .yes`; a generic `T` (`moves == .depends`) slips past.
Non-generic forms are rejected by that diagnostic (p61, p62) or carry their loans through the
`?` lends (p11, p12, p71–p73 behave).

Class: "matchesInPlace has a false positive where emit or ownership does not match the place".
Siblings checked: field of a branching value (`(h1 if c else h2).o`, generic, p74: arm-local, so OK),
branching over `?` lends (p11, p12, p73: OK), Box (p77), Vec element with header temp (p75, p76),
optional subjects (p10*: rejected upstream), held header (p13: rejected).

Fix direction (pick one, one classifier): make the branching rejection `moves != .no`, or have
`reachesPlace`'s `.branches` case require each leaf to be a pointer view (a lend) rather than a
bare place, so `matchesInPlace` agrees with `subjectHold` and with ownership. Add p63/p66/p69 as
reject tests.

## High

### H1. A guarded generic match's catch-all is bound as a copy, but typecheck says it is by address

Probes: `p78_generic_guarded_catchall.rig`, `p81_generic_guarded_catchall_slot.rig`,
`p82_generic_guarded_catchall_cell.rig` (evidence that sema itself knows it copies).

```rig
sub g[T](a: T)
  o = Opt.some(v: <a)
  z = Opt[T].nothing
  saved = ?z
  match o
    .nothing if clobber(2) > 100 => pass
    x => saved = ?x
  print(saved)
```

Observed: accepted (main rejects). Emitted Zig:
`1 => { const x = o; saved = rig.lend(&x); }`: a pointer to an arm-scoped `const` copy escapes
the arm. That is undefined behavior in Zig. Debug and release happen to print the right value
in every layout I tried (stack-slot reuse not triggered, p81), so no crash is observed.
Expected: `x` bound `&o` (in place), or the binding stays arm-local.

Further evidence: with `T = Counter` (holds a Cell), p82 is rejected by the generic requirement
"`g[Counter]` cannot use `T = Counter`: the generic body copies into a match binding a value
that holds a `T`" at that same `x =>` arm. So sema's requirement check knows the guarded
catch-all copies, while typecheck's `arm_view` decision (`!storage.catchAllByAddress(scrutinee,
true)`) says it is captured by address.

Root cause: `storage.catchAllByAddress` is consulted only by `emitCapture` (the unguarded
`switch` path). The guarded path (`emitGuardedMatch` → `armBindings` / `guardBindings` →
`wholeExpr`) re-derives "by address" as `writes or isPtrViewTy(t)` and copies a generic
`T`-holding value. typecheck and emit do not consult the same function for every catch-all shape:
- generic, unguarded: emit `|*x|` (catchAllByAddress), typecheck by-address. Agree (p31 runs).
- generic, guarded: emit copy (wholeExpr), typecheck by-address. **Disagree.**
- non-generic: binding type is the read view `?E` (isPtrViewTy), both by address. Agree (p35).
- write match: `wholeAlias(&place)`, typecheck sets no `arm_view` for write mode. Unchanged.

Fix direction: `wholeExpr` takes `storage.catchAllByAddress(t, info.in_place)` (one fact for
both emit paths), declaring the local with `payloadPointee` as `emitCapture` does.

## Medium

None beyond the above.

## Low (over-rejection, all also rejected on main; no soundness impact)

- `p22_store_vec_ok.rig`: `for e in es` / `match e` / `!views.push(?r)`, then reading `views`:
  rejected "`e` does not live long enough" (oracle: `stricter ... prod=reject ref=accept`). The
  same shape with `saved = ?r` (p20 without the push) is accepted, so the loan stored by `push`
  stays rooted on the loop binding.
- `p24_nested_match_ok.rig`: returning a view from `match r.i` nested in `.a(r)`: rejected "`r`
  does not live long enough" (oracle: stricter). This is the documented `match i` case
  (`p25_nested_on_binding.rig`, rejected as the brief says), and it also covers a field of the
  binding.
- `p43_write_view_local_repoint_ok.rig`: `w = !e1; match w ... saved = ?r; w = !e2`:
  re-pointing `w` is rejected "cannot reassign `w` while it is lent". A read-view local re-points
  fine (p04).

## What holds (accepted programs sanitizer-clean in debug and release, rejects correct)

- Owner changed after the match is rejected: Vec push (p01, p07, p20, p76), reassign (p03, p05,
  p12, p23, p30, p40, p41, p73), move (p26), drop (p17), Box reassign (p14, p77), element replace
  (p15), handle reassign or drop (p16, p17), header-made value (p13), inner-scope owner (p21).
- Escapes into the real place run correctly: Vec element by index (p02), view-local subject
  re-pointed (p04), break out of a loop (p06), returned from a function, guarded (p08), branching
  over `?` lends (p11), handle with a clone kept (p18), multi-field guarded (p27), generic local
  payload and catch-all, unguarded (p31), field of a call's view, guarded (p60, which holds
  `&(get(&h)).e`), field of a branching view, guarded and not (p72), generic Vec element with a
  header temporary (p75). Cell holder payload views (p50: plain, guarded, Box, header temp,
  returned) change the subject's own Cell (prints 5..9).
- Closures: borrowed captures cannot escape; an owned closure `*|+r|` clones (p45).
- Optional subjects (`h.e?`, `h.e ?? made`) are rejected before this change applies (p10*).

## Over-rejection sweep (item 4)

`rig check` with main's `bin/rig` and the branch's over every `.rig` in test/, examples/, std/
(9739 files): **no file rejected by the branch and accepted by main.** 104 files the branch accepts
and main rejects (part 1 and part 2 lifts). Of those, I ran the 46 match-payload-related corpus
probes under `RIG_SANITIZE=1` (debug) and `--release`: all exit 0, the two modes give the same
output, and the output matches `# expect:` where the probe has one.

## Oracle (item 5)

With its arm-local rule gone, the oracle still flags C1 where it decides the function: p63, p64,
p65, p67, p69 are `DIFF prod=accept ref=reject` (C5, "x does not live long enough"). It does not
decide p66 or p70 ("unknown"). It cannot see H1 (p78, p81): that is an emit-level copy, and its
model treats the binding as in place, as typecheck does. Its "stricter" reports (p22, p24, p25)
are the Low over-rejections above.

## Commands

```bash
cd .git/revamp/r3/probes/review-b4b-2
./run.sh p69_generic_branch_guarded.rig p66_generic_branch_uaf.rig p67_generic_branch_scope.rig p78_generic_guarded_catchall.rig
# emitted Zig
bin/rig emit .../p69_generic_branch_guarded.rig   # var __rig_subject_N: Opt(T) = if (...) o1 else o2;
bin/rig emit .../p78_generic_guarded_catchall.rig # const x = o; saved = rig.lend(&x);
```
