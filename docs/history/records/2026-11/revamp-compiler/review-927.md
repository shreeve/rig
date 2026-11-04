# Review of PR #927 (rv-own): ownership fixes for short-circuits and condition parts

Probes are in $TMPDIR/r927 (/var/folders/bf/z51x2wd97wj4790j65nw71_40000gn/T/r927). `run.sh` runs main's rig, the branch's rig
(and `RIG_SANITIZE=1 rig run` when it accepts), and `bin/rig-oracle -v` on each.
I ran `swarm test/rig.rip ownership-move` and `ownership-write`, and both are green.

**Verdict:** O1, O2 and O3 are sound, and I found no false rejection from the join.
One bound in O7 is hit by a realistic program (issue 1), so this PR rejects
a program that main accepted and CORE allows.

## (1) Short-circuit and condition shapes: none missed

Main accepts each of these and the branch rejects it. The oracle agrees on every one
(`cannot drop a while it is lent`, C4):

- p01: nested `yes() and (no() and take(<g))`
- p02: `not (no() and take(<g))`
- p03: `matches` with a binding, then `and take(<g)`
- p04: `matches ... and n > 0 and take(<g)`
- p11: `no() and e matches .a(n) and take(<g)`
- p05: a postfix guard `print(1) if no() and take(<g)`
- p07: `catch` inside an `and`
- p08: a non-binding `while no() and take(<g)` with `break`
- p09: a non-binding ternary
- p10: `o as x and no() and take(<g)`
- p16: `no() and (yes() or take(<g))`
- p17: `no() and take(<g) or yes()`

These are rejected the same on both rigs:

- p14, p19: loops whose condition moves (use after move)
- p18: a match guard (typecheck rejects it)
- p12: closures in a condition (the capture rules decide; the oracle answers unknown)

Chained comparisons do not parse.

## (2) Wrongly rejected programs: none found

All of these are accepted by both rigs, agree with the oracle, and run clean
under the sanitizer:

- q01: moved on the right side and not used after
- q02, q03, q13: moved, then reassigned
- q06: moved in a `while` binding part, then reassigned in the body
- q07: `(no() and take(<g)) or take(<h)`
- q11: an `else if` with `<b as` and `<c as`
- q12: a binding ternary with a move
- q05, q10, r04: `Map.get`/`edit`/`take` binding chains, with a `for` and a `while`
- r01, r02: temporaries and views in the right side, then `<b` and `!b.push` after
- r03: `e!` in the right side, `?` in the left, and `?? break` in a condition

## (3) O3 guard: sound

`lentFrom(depth)` reads `loan_counts`. Every write to a flow goes through
`addVar`, `replaceFlow` or `truncateVars`, and each of these keeps the
counts. `reportDropped` runs before `rewind` or truncation. So any loan it could
report has a root in `[depth, vars.len)`, which is counted.
The check also looks at flows at or above `depth`, so it can only answer "lent" too
often, never too rarely. I found no report it skips.

## (4) Bounds

### Issue 1 (MEDIUM, false rejection): the `selfViewIn` cap counts breadth, not depth

- **Where:** ownership.zig:6462
- **Probe** ($TMPDIR/r927/b65.rig): 65 locals `gK = G(items: ?base[..])`, then
  `!l.push(?gK)` for each.
- **Main:** accepts.
- **Branch:** rejects, with one "this store is too complex for the ownership
  checker; split it into smaller functions" error for each push after the
  64th (b63: 0 errors, b64: 0, b65: 1, b66: 2).
- **Oracle:** `stricter ... prod=reject ref=accept`.

The count is distinct holders that can be reached, not the length of a chain.
Straight-line code reaches it easily: generated code, tests, a large `main`.
Telling the user to split the function is a poor fix for code like this.

**Fix:** remove the cap. `seen` removes duplicates and can never grow past
`vars.len`, so the walk always ends, and the cap only limits cost. To keep the
walk linear, make `seen` a bitset or set over var ids instead of
`findScalar` on a list. Add b65 as a `test` case.
The same push walks about 64 holders per store, which is quadratic over a
function. Worth a timing check once the cap is gone.

### Issue 2 (LOW): `checkMethodCalls` can reject at exactly 16 rounds

- **Where:** ownership.zig:1187 and 1230

If the 16th round adds a requirement, the function rejects, even when a 17th
round would add nothing and the check would have converged. The error is
conservative, so this is not a soundness problem. Optional fix: run one more
round and reject only when that round still changes something. I could not
build a program that reaches 16 rounds.

### The other two bounds are fine

`absorbLoans` (`through.len > 16`) and `genericStoreIn` (depth 16) are depth
bounds along chains of write views. Only an artificial program like the PR's own case reaches them.

## Nits

None in the code. The new header comment, `walkConditionParts`' doc comment and
the `Iteration.exit` slice all read correctly.
