# Row 33D: a statement's loans end at their last use (handoff)

Rig language analysis, 2026-11-01. Follows 33C (`views-of`, what a value's loans name), which must
be merged first; start from main after it. The owner accepted this row in the compiler review
(2026-10-31, decision 4: "end statement-long loans at their last use, which CORE allows and the
oracle accepts"). It's an ownership change: one in flight at a time (queue.md).

## The rule, already in CORE

CORE sentence 6 (*built*): "A loan lasts until the last use of every view that carries it." The
compiler keeps every loan a statement takes and doesn't store in a var until the statement ends:
`Checker.temps` (ownership.zig:749), cleared only by `walkStmt` (about line 2551). Two narrower
exits exist: `endWriteLends` (3413), where a call whose result only reads ends its arguments'
write lends, and `keepViewTemps` (3425), where a view result keeps only its own loans. So the
compiler is stricter than CORE, and the oracle, which lowers to explicit temporaries
(`test/oracle/lower.zig`) and runs liveness (`flow.zig`), accepts more. **CORE doesn't change.**
CORE §3 stays as it is: an owning temporary still drops at its statement's end, and a view of a
temporary is still used only within its statement.

## What changes

A loan in `temps` ends when the value carrying it is last used: when its parent consumes it (an
operator, a call's return, a field read that copies out, a comparison) and the parent's value
doesn't carry it on. A loan the result carries moves up to the result, as `keepViewTemps` already
does for a view. The generalization is one rule at each consumption point, not a third exit.

The rule keeps these:
- **An earlier argument's read keeps its owner lent until the call returns** (Core §6), because
  its last use is the call. The `*.arg_then_write.*` lines in `test/oracle/differences` are
  `ref-gap`, the compiler right: they must stay rejected.
- **What a callee stores** (`stored`, `keeps`) lasts as it does now.
- **An owning temporary whose drop runs a `drop` body** keeps its views lent to the statement's
  end (sentence 6, `dropStmtTemps`). Header temporaries end with the header, and 33C's self-check
  assertion in `walkFor` (`headerTempLoan`) must still hold.

## Expected gains, from test/oracle/differences (prod-strict)

- `call_write_lend_kept.rig` `match_arm_writes` and `write_result_whole` (2);
- `*.eq.write_view` and `*.eq.destructure_write`, `print(w == a)` (8);
- `review-results-v07` `v, s = mk(?s)`, a result's loan kept to the statement's end (1);
- `review-header-paths-1-t05`, a branch's write views kept through a loop that never reads them
  (1, maybe: check it).

When the oracle reports one as FIXED, delete its line. Don't touch `*.discard.*`: that's
`_ = w` not reading, which is a different rule.

## Emit

Nothing new to decide: loans are the checker's alone. Check that emitted Zig evaluates operands in
the order the checker walks them (`tools/emit-diff` should show emit identical). Also check that
no newly accepted program reads through a view after a later write in the same expression. Run
each newly accepted case under `RIG_SANITIZE=1` (the runner does).

## Tests

- Each FIXED differences line becomes an accepting `test` in `test/rig/ownership-*.rig.test`.
- Guards that stay rejected: an earlier argument's read then a write lend in a later argument; a
  stored lend; a `drop`-body temporary's views written in its statement; a view of a temporary used
  past its statement.
- `seeds:` isn't needed (no concurrency). Fix the class: try each consumption form (operator,
  call, method, field copy-out, `??`, `catch`, branch).

## Process

1. Draft (half a page): the consumption points, and where `temps` entries record the node that
   carries them. Two reviewers (soundness; adversarial programs, as for 33C, whose reports are in
   `core-33c/`), then code.
2. Worktree `wt new last-use`. `NEXUS=~/Data/Code/nexus/bin/nexus` if the build can't find it.
3. Gates: `swarm test/rig.rip all -q -w 6` (self-check on), `zig build test`,
   `tools/emit-diff BASE`, loco's light gate, Trig's light gate (waived if Trig's emit is
   identical), and json and hash guards only if emit changes. Then basecheck, and "ready #N SHA"
   to Rig - Swiss.
4. Docs: CORE needs nothing new (check §3 and sentence 6's examples still read true). Add a
   CHANGELOG entry that says which programs are now accepted, and update HANDOFF.

Size: about 100–200 lines in ownership.zig, about 12 differences lines removed, and about 12–16
cases. Risk is moderate: every statement's loans move. A wrong early end accepts a program that
corrupts memory, and that's the danger the oracle and the sanitizer exist to catch.
