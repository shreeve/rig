# Re-review: `ignored-bang` at a4325ccb (merges main 1d356a09)

Reviewer: independent fast-gate re-review. New code read:
`git diff 293a3098 a4325ccb -- src test` (38429070 + a4325ccb).
Worktree built at a4325ccb (`zig build`, `zig build oracle`); main is
`/Users/shreeve/Data/Code/rig/bin/rig` at 1d356a09. New probes:
`.git/revamp/r3/probes/review-ignored-bang-2/` (74 files). Runner per
probe: main `rig check`, branch `rig check`, and when the branch accepts,
`RIG_SANITIZE=1 timeout 20 rig run` (debug) plus `rig build --release`
run under `RIG_SANITIZE=1 timeout 20`; then `bin/rig-oracle`.
Unit tests (`zig build test`, fresh cache): pass.

## Verdict

**No memory-soundness hole found.** Every accepted probe runs
sanitizer-clean in debug and `--release`. Every loop-held write view
keeps its loan: any use, write, move, drop, or second lend of the lent
name while the binding lives is rejected. A view that would outlive
what it lends is rejected too. The first review's High 1 and High 2 are
fixed. One class remains where a written `!x` is still read silently,
so the "one decider" claim and the CORE/SPEC sentence still overclaim
(High 1 below). It miscompiles nothing: the value read is a copy, and
the `!` is ignored.

## Findings

### High 1: a written `!x` that is a leaf of a branching value or loop, read as a value, is accepted silently

The `!` is ignored, which CORE §4 (a509c939) and SPEC "Lending" now say
is rejected "anywhere else (… an operand, … `print`)". Main accepts all
of these too. On the branch:

| Probe | Form | Observed |
|---|---|---|
| `c16_if_two_lends_print.rig` | `print(!n if c else !m)`, `k = (!n if c else !m) + 1` | accepted, prints `2`, `3` |
| `c15_if_held_mixed_reads.rig` | `print(w if c else !m)`, `(w if c else !m) + 1` (`w = !n`) | lines 10–11 accepted; only `f(w if c else !m)` (line 12) is rejected |
| `c11_if_held_view_mixed.rig` | `a = w if c else !m`, then `a += 10` | accepted, `m` stays 2 (prints `2 12`) |
| `c12_loop_call_and_lend.rig` | loop with `break w if …` and `break !m`, `a += 10` | accepted, `m` stays 2 (prints `1 2 12`) |
| `c01_loop_leaf_mixed_if.rig` | `a = if c` / view loop `break !n` / `else m` | accepted, prints `1 11`: `!n` ignored. Compare `a = !n if c else m`, which is rejected (`r12`) |
| `c14_match_arm_loop_mixed.rig` | the same with `match` arms | accepted, prints `1 11` |

- Expected: rejected with the existing diagnostic on the `!n`/`!m`
  leaf, as `!n + 1`, `print(!n)` and `a = !n if c else m` are.
- Root cause: `writtenWriteLend` only recognizes `!x` and `<!x` *at the
  node being read*. When `readOf` reads a composite (`hands().kind ==
  .branches` for `if`/`match`/`??`, or a loop, which `sema.handsOver`
  calls `.made`), it returns null, and `recordRead` marks the whole
  value. Leaves get their own decision only when an expected type flows
  down, or when unify adapts a leaf whose type differs (that is why
  `!n if c else m` is caught and `!n if c else !m` is not). For a loop
  leaf (`c01`), unify does adapt it, but `writtenWriteLend(loop)` is
  null, so the `break !n` inside is never seen.
- Fix (one place): in `writeLendRead`, for a value that branches or
  loops, decide each value leaf (`sema.valueLeaves`, plus a loop's break
  values and its `else` value) the way a direct `!x` is decided. Best
  done with Medium 2's fix, so the walk uses the same classification as
  everything else.
- Test to add: a reject case for each of the rows above, in
  `ignored_write_lend_read.rig`.

### Medium 1: a loop value's meaning changes silently for programs main accepts

- Probe: `h01_silent_meaning_change.rig`: `l = while true` /
  `break slot(!n)` (`slot(a: !Int) -> !Int`), `l += 5`, `print(l)`,
  `print(n)`.
  - main prints `6` `1`: `l` is a copy.
  - The branch prints `6` `6`: `l` holds the view and writes `n`.
- This is the intended rule, and SPEC's old sentence ("a loop's value
  of type `!Int` binds the value it reaches") is replaced. But an
  accepted program changes behavior with no diagnostic. The branch
  itself had to re-expect
  `test/behavior/ownership/write_view_result_binding_holds_view.rig`
  (`12 0 1` → `1 0`).
- Reach: `rig emit` with main and with the branch over every file both
  accept (test/behavior, test/corpus, examples, both probe dirs: 8741
  files) gives **0 differences**, so nothing in the tree changes
  meaning. Worth a line in the release notes.

### Medium 2: two classifiers still disagree on what a loop hands over

- `sema.handsOver` calls a loop's value `.made`, but an `if` with lend
  leaves is `.branches`. Typecheck now has a third, checker-local answer:
  `view_loops`, read by `yieldsWriteViewIn`. This is not a recorded fact,
  so ownership and emit cannot read it.
- AGENTS "one classifier per fact" wants one answer. That answer is
  also what High 1's fix needs: a loop value classified like a branching
  value, with its break and `else` values as its parts.

### Low 1: a written `!x` reached through, not read whole, is accepted with its `!` ignored

- Probes: `d02_read.rig` `(!p).x`, `d03_read.rig` `(!arr)[0]`,
  `d04_read.rig` `(!s).len`. All accepted on main and the branch, and
  all print correct values.
- `!arr[0]` read as a value is rejected (`d25`), but `(!arr)[0]` is
  not. These go through `reachThrough` (`.reach`), which by design skips
  the decider.
- CORE's "an index" wording covers `!arr[0]` but arguably not these.
  Either state the exclusion or decide `.reach` when the reached place
  is then only read. Design note, not a bug.
- `(!p).sum()` with `?self` (`d16`) is the documented narrowing
  exception, so it is fine.

### Low 2: the oracle gap on loop-carried loans now covers ordinary scalar code

- On all 100 probes (74 new and 26 from the first review), the oracle's
  only differences are 23 `stricter` (prod rejects, ref accepts). All
  are loans carried by break values, plus the closure and field variants
  of them. There are no `looser` differences, and prod's rejection was
  correct in every case.
- Before this branch, only non-copy loop views (`r23`) hit the gap.
  Now every `a = while … break !n` does, so the reference checker cannot
  confirm any loop-held loan. This is the known gap and not a prod
  soundness issue, but it should be on the oracle backlog.

### Low 3: hint nits (most of the first review's Low 1 is fixed)

- Fixed: `!!n` → `f(n)`, `pair(n, m)`, `math.max` says `!T`, `Cell(!n)`
  no longer offers `Cell[!Int]`, and `l01` reports once.
- Remaining:
  - `G(r: !n)` for a generic `G` with methods says "the field's type
    must be `!Int`" (`r04:36`). The field is `T`, and `G[!Int]` cannot
    be made.
  - `G(r: G(r: !n))` says "the type here must be `!Int`" (`r01:43`).
  - Both are cosmetic.

## Hunt results by item

1. **Loop keeps the view.** All of these are rejected, each correctly:
   - **Use while the view lives** (use, write, reassign, second lend,
     move, drop):
     - `a01` read `n`
     - `a05` reassign `n`
     - `a02`/`a03` two breaks to `!n`/`!m`: `a` holds both loans, and
       using either name is rejected
     - `a04` `for … else !m`, then `m += 1`
     - `a13` nested value loop
     - `b02` labeled `break :outer !n` inside an untyped `if`
     - `b05` inside a closure with `|!n|`
     - `g02` two view loops of `n`
     - `b10` `-v`, `b11` `<v`
     - `b12`/`b13` field `!s.x`: a sibling write or a move of `s`
   - **Vec elements:**
     - `a08` `break !v[0]` then `!v.push(2)`
     - `b08` `for x in !v` / `break !x`, then `push`
     - `b06e` `for x in !arr` / `break <x`, then `arr[0] = 5`
   - **Lifetime** (rejected as "does not live long enough" or "cannot
     return a view"):
     - `a06` loop-body local
     - `b20` local of an inner block
     - `g01` local of an `if` block around a view loop
     - `a16` function returning a loop view of a local
   - **Accepted and correct** (sanitizer-clean in debug and release):

     | Probe | Prints |
     |---|---|
     | `a09` | `11 2` |
     | `a12` | `11` |
     | `a17` | `11` |
     | `b01` | `11 2` |
     | `b03` | `11` |
     | `b04` | `11` |
     | `b18` (rebinding `a` to a second view loop) | `11 102` |
     | `b19` | `11 21 31` |
     | `c03` | `11 2` |
     | `c04` | `111 2` |
     | `g04` | `13` |
     | `b06c` | `1 12 3` |
     | `b06d` | `1 12 3` |
     | `r10` | `101 2` |
     | `r11` | `101 2` |

   - **Loan ends with `a`:** `n` is usable after `a`'s last use (`a09`,
     `b19`, `r10`, `r11`, and the suite's `write_lend_kept`).
   - **Labeled loops:** a loop value cannot carry a label as a binding
     right-hand side (`a = :outer while` is a parse error). The labeled
     path is reached through an `if` branch (`b01`/`b02`) and works.
   - **Mixed loops:** `b09` (`break x`, a held view) reads a copy, by
     Core sentence 1. `c05` (`break (!n if c else m)`) and `c07` (typed)
     are rejected. The mixed held-view-plus-lend loop (`c12`) is High 1.
   - **Pre-existing, not this branch:**
     - `for x in !arr` / `break !x` is rejected as "`x` does not live
       long enough" (`b06`/`b07`), while `break <x` works (`b06d`).
     - A closure whose tail is a view of a `|!n|` capture is rejected
       (`c09`, `c13`).
2. **First review's probes** (all 26 re-run):
   - High 1 is fixed:
     - `r07` is rejected, but only because it reads `n` while `a`
       lives.
     - `r10`/`r11` are accepted and the writes reach `n`.
   - High 2 is fixed: `r17`/`r18` are rejected with "`?` lends it on to
     read. Write `?n`".
   - Design-note forms are now rejected with good hints:
     - `r15`, `r16`, `r19`: operators, index, range, `print`, `+!n`,
       `<!n`, `-!n`
     - `r02`/`r03`: a struct that copies, inferred
     - `d05`–`d25`:
       - `Float(!n)`, `!n == !i`, `!f * 2.0`, `<<`, `%`
       - range bound, `defer print(!n)`, `!o ?? 3`
       - `print(!s)`, `print(!p)`, `q: P = !p`, `!arr[0]`
   - Valid forms `v01`/`v02` and the narrowing case `d01` still run
     correctly.
3. **One decider:**
   - Confirmed: `ctx.recordRead(` appears once in typecheck, in
     `readOf`, which asks `writeLendRead` for `.slot`/`.value`/
     `.lent_to_read`. emit, ownership, storage and resolve only read the
     fact. `recordReadInPlace` is a different fact (a branch read where
     a name holds it). Emit's other deref (a `match` subject's hidden
     storage, `emit.zig:2661`) dereferences by type and does not decide
     a read. `match !n` with a binding arm (`e01`) binds the view.
   - Gap: the decider's input classifier misses written leaves of
     composites (High 1). The `.reach` path skips the decider by design
     (Low 1).
4. **Over-rejection sweep:**
   - Ran `rig check` with main and the branch over all 9820 `.rig` files
     under test/, examples/ and std/ (branch tree).
   - Newly rejected:
     - `test/reject/ownership/ignored_write_lend.rig` (intended)
     - Six corpus probes, each this round's shape. Corpus allows
       rejection.
       - `r3-review1-p40_generic_wview`
       - `r3-review1-p40b_generic_wview2`
       - `review-step1-p40_generic_wview`
       - `review-step1-p40b_generic_wview2`
       - `review-lang4-g3`
       - **New since the first review:**
         `audit-fuzz-pf2-accepted-09732fa32c.rig:18`, for
         `print(!x == 6)`: "only its `Int` is read here. Write `x`"
   - Newly accepted: `write_lend_kept.rig` and
     `write_view_result_binding_holds_view.rig`. These are the branch's
     edited versions; main rejects their new loop lines.
   - No example or std file changes either way.
5. **Oracle:** run on every probe. 23 `stricter`, all loop- or
   break-carried loans; 0 `looser` and 0 others. The 7 changed and new
   suite files have no differences.

## Commands

```
P=.git/revamp/r3/probes/review-ignored-bang-2
W=<worktree>/bin/rig
$W check $P/c16_if_two_lends_print.rig          # accepted (High 1)
RIG_SANITIZE=1 $W run $P/c16_if_two_lends_print.rig   # 2 / 3
RIG_SANITIZE=1 bin/rig run $P/h01_silent_meaning_change.rig  # main: 6 1
RIG_SANITIZE=1 $W run $P/h01_silent_meaning_change.rig       # branch: 6 6
```

## Note: main moved during this review

main is now 53cbff4f, after `one-decider` (#87) merged. That branch
changes typecheck's read decisions (`bf094123`: an optional reached
through a field's view is read once). `bin/rig` in the main checkout was
rebuilt at 21:24, near the end of this review. So the sweep's main
column, `h01`, and the main column of every High 1 and Low 1 probe were
re-confirmed with a true 1d356a09 build
(`scratchpad/ib/base-wt/bin/rig`): the results are identical.
Under AGENTS "one branch at a time per fact or classifier", this branch
must pass the full gates again on 53cbff4f with it merged before it
lands. `readOf`/`writeLendRead` and #87's decisions touch the same
read fact.
