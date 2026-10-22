# Review: B4b part 1 (2d47a2db, d9225c3c)

Reviewer: fast-gate independent reviewer. Tree: `b4b` at d9225c3c, base
main 62d0e0b5. Worktree built fresh (`zig build`, `zig build oracle`).
Probes: `.git/revamp/r3/probes/review-b4b-1/` (`run.sh` runs each probe:
check under new and main, `RIG_SANITIZE=1` debug run and `--release`
build+run, each `timeout 20`, then `bin/rig-oracle`).

## Verdict

**No soundness hole found.** Every probe the new compiler accepts runs
sanitizer-clean in debug and release with the right output, and every
probe whose binding would outlive or be invalidated by what it points at
is rejected. Accept-means-correct holds for everything I tried. Full
suite on d9225c3c: `2861 passed, 0 failed, 0 known, 4 pending`.

No Critical, High or Medium findings. Two Low findings.

## What I hunted, and the result

### 1. Accepted headers whose pointer could outlive its target

`storage.headerPoints` gates the new acceptance. It points only when the
path's base has no statement temp (`startsOutsideHeader`). For a
branching subject, it also needs every non-jump leaf to reach such a
place. I tried to get a pointer into the header block's storage:

| Probe | Shape | Result |
|---|---|---|
| p30, p31, p32 | base is a view a call returns of a plain-data rvalue `look(?P(..)).xs[idx(?Text)]`, read/as/write | rejected (plain lend temps count as statement temps) |
| p33, p34 | base is a `?self` view of a made plain receiver `mk(k).items()[idx(?Text)]` | rejected |
| p35 | view of a *named* plain struct `look(?p).xs[idx(?Text)]`, read and write, with stack clobber | accepted; emits `&(look(&p)).xs[...]` (a pointer); correct and clean |
| p36 | generic view return `first[T](?vv)[idx(?Text)]`, T non-scalar and Text | accepted; `rig.ReadView(T)` is a pointer for every indexable T (`copiedByReadView` is only true for scalars); clean |
| p23 | `!get(!h).es[idx(..)]`, `look(?h).es[idx(..)]` | accepted, clean, correct |
| p24 | the same, with an index that grows the owner | rejected (write loan live) |
| p20, p21, p22 | index grows the outer Vec while `vv[0]` is already found | rejected ("place is found up to each index before the index runs"), both with and without a temp |
| p25, p26 | `if` with a made leaf; `??` subject | rejected (`branches` only for `if`, and leaves must all reach places) |
| p60 | `if` subjects: temp in the condition, nested `if` leaves, read leaves; all four branch outcomes | accepted, correct, clean |
| p27, p28 | `for` over an element of a made value | rejected (pre-existing diagnostics) |
| p40 | generic bodies: read match, write `as`, read `as`, `while as` through a temp index, T=Int and T=Text | accepted where expected, clean. Generic arm-local and copy-of-T rules still apply. |
| p61 | an effectful index (Cell counter) in a write catch-all, a guarded write match, a guarded read match, and `while … as` | the index is evaluated exactly once per header evaluation |
| p66 | `?` / `!` propagation out of the function inside a pointing header's index | leak-free; correct |
| p67, p73 | nested pointing headers; an element of a slice whose bounds make a temp | clean, correct |
| p53, p54 | a handle element; an optional element then an inner write match | clean |

### 2. The subject's loan is held through the body while emit points

Each of these is rejected at the right spot: p01, p02, p03, p07, p08,
p10, p42, p43, p46, p55, p56, p63 and p65. The bodies push to the owner,
move it, assign the element, drop it, replace a handle element, let the
binding escape to an outer name and then grow the owner, or return the
binding and then grow the owner. Programs that use the binding first and
mutate afterwards are accepted and run clean (p09 `while` with pushes
after use, p44 move then break, p45 element reassigned after use, p41
re-pointing the view the `while` goes through). The loan model matches
what emit does.

### 3. Vec-element write match (2d47a2db)

- p04, p05, p17, p18: an arm pushes to the same Vec (or, for `vv[0][i]`,
  to the outer or the inner Vec) and then writes the payload. All are
  rejected (main rejects them too).
- p06: the arm writes first and then pushes. Accepted, clean, correct.
- p11: `![]E` slice elements, `!first(!v)[i]`, and array slices. Accepted
  and correct. **Main fails to compile this program** ("cannot assign to
  constant"), so the fix is real.
- p12 (value position, guarded), p14 (generic), p15 (`Vec[Box[E]]`), p16
  (write catch-all assigning the whole element), p62 (Vec through
  `if !o as v`, and a `!H` parameter's field): all clean and correct.
- p13: a guard that grows the Vec is rejected ("a guard cannot change the
  value being matched").
- p50, p51, p52: Text and `Cell[Vec]` elements are rejected before
  reaching this path.

`throughElement` plus `handsOver == .place` is reached only when the
header has no temps (otherwise `headerPoints` takes the earlier branch).
`emitSubjectPtr` with no temps opens no block. I found no subject on
this branch whose address is not a real place.

### 4. Over-rejection versus main

I ran `rig check` on every `.rig` under `test/`, `examples/` and `std/`
(9674 files) with both binaries (`probes/review-b4b-1/overrej.txt`).
**0 files that main accepts are rejected by the new compiler.** 51 files
are newly accepted: the 3 new behavior tests and 48 corpus probes. I ran
all 51 in debug+sanitize, release and the oracle
(`probes/review-b4b-1/runnew.txt`). All exit 0 with no oracle difference,
and every "Expected:" stated in a probe's comment matches: a07 `7 7`, a08
`7 7`, a27/a27b `8 8`, and the computed values for r15 `322`, r25 `641`
and c11 `1 [42]`.

### 5. Oracle

`bin/rig-oracle` (built from d9225c3c) shows 0 differences on every
probe except p73, p76 and p77 (see L2, which predates this round). The
lower.zig change (a catch-all over a lent Box sees the boxed value) is
narrow. I checked it does not hide a production hole: p70, p71 and p72
let a plain-data catch-all view of a Box element escape and then replace
the Box. Production and the oracle both reject all three.

## Findings

### L1 (Low): stale comments in newly accepted corpus probes

Some corpus probes now accepted and run-clean still say they must be
rejected or that they fail:
- `test/corpus/review-step45-r2-a14_while_for_forms_rejected.rig` says
  "each must be rejected".
- `test/corpus/review-step10-a38_match_box_hdrtemp_noescape.rig` says
  "the Zig does not compile".
- `review-step10-a07_..._loop_wrong.rig` and `a08_..._loop_wrong.rig`
  describe the old copy behaviour.

The runs are correct. Only the comments disagree with the code
(AGENTS.md rule 7). The fix is to say what the probe now checks. Corpus
probes carry no `# expect:`, so for a07, a08, a27 and a27b the stated
expected output is not machine-checked. Consider adding `# expect:` to
those four now that they run, since their whole point was wrong output.

### L2 (Low, pre-existing, not introduced here): oracle false positive on an element of a parenthesized slice

`if (?v[i..2])[1] as t` over `Vec[Text?]` (p76, no temp, accepted by
main and the new compiler) gets this from the oracle:
`DIFF ... prod=accept ref=reject C2 a bare (?v[i..2])[1] owns a resource and would be copied`.
The base oracle built at 62d0e0b5 reports the same difference. (The
`bin/rig-oracle` in the main checkout is older: it abstains on p76, so
that binary is stale.) Production is right here: it emits
`&rig.elemPtr(rig.slice(...), 1).*` with a `|*opt|` capture, a view in
place, and the program runs clean. The oracle's lowering does not treat
an element of a parenthesized read slice as a place an `as` header
views. It is not a soundness hole, but such a probe in the corpus would
fail the oracle gate. Probes: p73, p76, p77.

## Commands

```
W=<worktree>; probes/review-b4b-1/run.sh pNN_*.rig
RIG_SANITIZE=1 timeout 20 $W/bin/rig run F
timeout 60 $W/bin/rig build --release -o /tmp/p F && timeout 20 /tmp/p
$W/bin/rig-oracle F
heavy.sh overrej.sh  (rig check, new vs main, all of test/ examples/ std/)
heavy.sh runnew.sh   (the 51 newly accepted, debug+release+oracle)
heavy.sh ./test/run -j 2   -> 2861 passed, 0 failed, 4 pending
```
