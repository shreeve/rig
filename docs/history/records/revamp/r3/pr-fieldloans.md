Round A of the ownership work (Trig NEEDS 28, owner decisions 1a–1e): a
loan is on a **place**, a root binding and the fields after it, so
`p.a` and `p.b` are lent apart. Two places conflict when one path is a
prefix of the other.

## The rule as built

CORE sentence 5 and §5 get the approved text of proposal-field-loans §3,
word for word. The one change is that the status markers now say
*(built)* where the approved text said *planned*, as brief item 5 asks
(mark built honestly). The rule:

- A path goes on through an object's fields, through what the root's own
  write view sees (`self.a` in a `!self` method), and through a box.
- It stops at an element, a handle, a read view, or an optional's
  value. A path through a read-view field carries that view's loans, not
  the holder's (Trig's A.3).
- A use touches the path it names. `p`, `<p`, `p = x`, `(!p).m()`,
  `!p.m()`, and a closure capture touch all of `p`.
- A value never holds a view of itself (1c). A `!self` method's view
  result still lends all of `self` (1e). Field-precise re-pointing (n39)
  is not in this round (1d).

## The fact and its one classifier

- **The fact.** `resolvePlace` decides each place's path once, by a
  positive list (`extendsPath`). It is recorded on `Place.path` and
  `Loan.path`, as a number in a trie of fields (`Paths`). No pass reads
  a path from syntax.
- **Overlap.** Only `loanMatches` compares paths (`Paths.overlap`).
- **`swap`.** Its special case is gone: `disjointFields`, the second
  classifier that compared source text, is deleted, and `swap` falls
  under the general rule.
- **Diagnostics name both places**, with the note at the lend:
  `cannot lend `p` to write while a read loan on `p.name` is live`. A
  write call on the whole receiver while one of its fields is lent adds
  the idiom: "the call lends all of `self`: lend the fields it writes,
  `(!self.field).method(...)`, or make `m` a function of those fields".
- **The oracle reads no compiler classification** (its `lint` set
  forbids it), so it builds the same rule on its own, per proposal §6:
  - disjoint paths apply to every loan, and the `swap` group is gone;
  - its paths are cut at a handle or an optional's value;
  - a new rule, C9, says a value never holds a view of itself;
  - a loan on part of a write view's referent widens to the whole
    referent when the view is defined anew. Without this, the oracle
    compared paths of two different values (a loop's payload view) and
    lost the rejection of `review-box-p11`.

## Sibling sites and their verdicts

Every `conflicts`/`findLoan` caller now passes the path its use names.

- **Paths:** `lendVar` (lends, slices, captures), `walkTake`,
  `walkFieldAssign`, `checkReadable` (field reads, through
  `walkMember`/`takePlaceRead`), the write receiver's reservation,
  `place_hold`, and activation, `holdRead`/`holdBranchLeaf`,
  `walkIndicesHeld`, `receiverLeaves`, `for` sources, and `match`
  payloads (`Scrutinee.place`).
- **The whole var:** `moveVar`, `walkDrop`, `checkAssignable`/`reassign`,
  closure captures, and a receiver that is the name.
- **Unchanged:** liveness, `carry`, `isLent`, and what a var holds (per
  var).

Found while building it, each fixed as a class, with tests:

1. **`swap` stored the other place's lend, not its value**, so
   `swap(!p.a, !q)` with `q` viewing `p.s` hid a self-view. It now
   stores `takenValue` too (`field_self_view_through_swap`).
2. **A call stored "through" read-only arguments.** A `?String` read
   out of `self` carries the parameter's own write loan, and that was
   taken as a way into `self`. This was a false self-view in Trig's
   JSDoc parser (`!self.scanner.set_text(t)`). Now only a value that
   can write leads a call's stores.
   - The sibling, closure creation, had the same bug, and main already
     rejected `field_closure_read_capture_writes_nothing` through it.
     Both are fixed.
3. **The self-view check looked at direct loans only.** `|!w, ?r|`
   lends the var `r`, which views `p.b`. It now follows loans through
   what their vars hold, at both sites (`selfViewIn`), as the oracle's
   flow does. The oracle caught it.

A value whose type is not known counts as one that may write, so the
checker's own unit tests, which run without types, keep their stores.

## Tests

- **Trig's programs.** All 17 `accept/field_*` run sanitizer-clean;
  `field_swap_general` passed before and still does. All 19
  `reject/field_*` are rejected with the post-change diagnostics in
  their headers. The two E1 programs
  (`range_field_call_whole_receiver`, `whole_receiver_method_field_arg`)
  are reject tests showing the idiom note, since E1 was declined. E2's
  `method_view_result_path` is a `rig pending` example in SPEC, "Paths".
- **My own:** 5 run tests and 7 rejects:
  - self-views through a write argument, `replace`, `swap`, a write
    local, and a closure;
  - Trig's A.3 both ways;
  - `print(p.a, grow(!p.b))`, and `match !p.a` arms writing `p.b`.
- **Fail before, pass after.** 19 of the 22 run tests are rejected by
  main and all run clean here. All 27 new rejects give the expected
  diagnostic, against 3 on main.
- **Trig's `verdicts`** with this compiler gives all 39 A programs their
  post-A verdict: 17 accepted; 19 rejects and 3 beyond rejected.
- **Existing tests.** 15 reject tests changed wording only: each is
  still rejected at the same place, now naming both places.
  `field_loop_carried` stays rejected by loop liveness, not by field
  loans. The oracle shows it is sound (`prev` is re-pointed before its
  next use), so it is a classified `prod-strict` difference, and I
  corrected its header.
- **Corpus.** 20 probes the old rule rejected are now accepted, and
  each runs sanitizer-clean. A sweep of every behavior, example, known,
  and corpus program finds no new rejection.

## The grid

`field.` in test/matrix.py has 500 cells:

- **Places:** an object's field, a nested object's, a field through a
  read-view field, `self` in a `!self` method, and a box's field.
- **First loan:** read or write. **Second use:** a read lend, a write
  lend, a take, or an assignment, of a sibling, of the same field, or
  of the whole value.
- **Contexts:** straight line, a loop's back edge, and a closure
  capture. **Exits:** fall-through, return, break, continue, `!`, and a
  failing `if … as`.

The rule rejects 108 cells, and each must be rejected. Each of the
other 392 must run, sanitizer-clean, and print the output a small
simulator gives; straight-line cells also run with `--release`. The
oracle agrees on every cell.

## Gates

- Mac fast gate: build; `./test/run --delta` (3,755 passed; its one
  failure, a corpus rejection the oracle no longer makes, is fixed in
  f9a52f1); the oracle's tests, corpus, docs, and lint sets pass; unit
  tests pass; the `field.` grid's 500 cells, plus the other grids
  `-k field.` selects, pass (two cells that timed out across a quiet
  window's pause were rerun alone and pass).
- Full gates on pup at f9a52f1 (`GATES_DELTA=1`, 8 cores): suite 3,756
  passed, corpus 10,061 passed, matrix 11,857 programs with 0 failed,
  unit 172/175 (3 skipped), oracle, doc, and vocab 456 passed.
- Final gates on the tree merged with main after #215 (2f6151c, Mac,
  `-j 2`): suite 3,776 passed (with unit, oracle, doc, vocab), corpus
  10,091 passed (with the rev210 and rev215 probes), unit 174/176 (2
  skipped, fresh cache), Trig's gate at 7fe3284 18,568/18,568 with
  `rig check src/parser` clean. Matrix: run by cpuq at this head. The
  merge resolved two conflicts with #215 in src/ownership.zig,
  `walkTake` and `walkSwapCall`, each keeping the path-precise rule and
  #215's generic-T taint (see the merge commit).
- Gates on the tree merged with main after #206 (bd72d2d):
  suite 3,773 passed and corpus 10,080 passed (pup, `GATES_DELTA=1`, 8
  cores); unit 174/176 (2 skipped) and oracle/doc/vocab 460 passed (Mac);
  the matrix on burst, built cold, 21 cores, about 61 minutes: 11,881
  programs, 7,225 ran clean, 4,656 rejected, 0 failed.
- On the earlier tree merged with main (#208), 1104e68 (`GATES_DELTA=1`, 8
  cores): corpus, matrix, unit, and oracle/doc/vocab (459) pass. In the
  suite, 3,765 passed and two timing CLI tests failed under pup's load
  (load above 30): `cli/match_scale` (a time ratio) and
  `cli/results_cache` (a timeout). Rerun alone, both pass.
- Trig's gate on the merged tree: on Trig's `fieldloans` head 7fe3284,
  rebased on current Trig main, which also removes Trig's last NEEDS 28
  site (`sort_reparsed_clones(?self.ast, !self.reparsed_clones)`): this
  compiler gives 18,568/18,568, and `rig check src/parser` is clean,
  where main gives 25 loan-conflict errors. The earlier head is kept as
  the tag `gate-roundA-fieldloans` (bc3d044); on it, too, the gate was
  18,568/18,568 (tokens 131, ast 7, parser 21,
  parse-only 216, clean 1,792, all-ts 14,406, all-js 1,713, fixtures
  282). `rig check src/parser` is clean; main gives 24 errors. This also
  proves the idiom the note recommends (`new_identifier(!self.ast,
  !self.identifier_count, …, self.scanner.token_value)`).

## Measurements

Quiet Mac window, load 2.1 at the start and 2.7 at the end. Both trees
are built by this PR's compiler, base (Trig main 9425dfb) against A
(Trig `fieldloans` bc3d044), checker.ts (3.15 MB), 9 rounds of 30
parses, at `cpuq --cores 1`:

| Build | Fastest parse | Median of rounds | Cycles, 30 parses | Instructions | Peak memory |
|---|---:|---:|---:|---:|---:|
| Trig base | 19.46 ms | 19.57 ms | 2.627 G | 12.353 G | 25.2 MB |
| Trig with field loans | 17.23 ms | 17.48 ms | 2.365 G | 11.043 G | 27.8 MB |
| tsc's Go parser | 13.87 ms | 16.94 ms | 2.743 G | 13.387 G | 88.3 MB |

- **Speed.** A is **13% faster** (fastest parse) and 12% faster
  (median), with 10% fewer cycles and 11% fewer instructions. This
  replaces the experiment's numbers.
- **Peak memory.** At 1 parse it is equal (24.9 MB both). At the
  plateau of 120 parses it goes from 25.2 MB to 28.7 MB, 14% higher.
  Trig's 9425dfb shows why: with per-size-class counts, peak live bytes
  are identical in both builds at 1, 30 and 120 parses, and every size
  class peaks at the same live bytes. A only removes allocations
  (128,481 fewer per parse in the 2^8 class, the copied token values),
  so the rise is `smp_allocator` keeping freed pages across parses, not
  more demand and not a leak.
- **Checking time.** `rig check --time` on Trig's src/parser (base
  tree), main's compiler (11c79bc) against this PR's, interleaved, best
  of 6: the ownership phase went from 17.65 ms to 19.09 ms, +1.45 ms
  (8%), inside the 10% / 1.7 ms bound. That is the feature's own cost on
  unchanged source.

**Where the 1.45 ms went, and the fix.** Instructions retired by
`rig check src/parser`, a count load does not change, minimum of 6
interleaved runs:

| Compiler | Instructions | Over main |
|---|---:|---:|
| main | 2.6496 G | |
| PR as timed | 2.6784 G | +28.8 M |
| PR with path steps memoized | 2.6716 G | +22.1 M |
| PR as merged (memo, lazy read path, lazy self-view walk) | 2.6569 G | +7.3 M |

Most of the cost was paths no conflict needed:
- `walkMember` resolved every field read's path, and `resolvePlace`
  searched the object's fields by name at every step. A read now
  decides its path only where some write loan on its root is live
  (`checkReadable`), and each step's path is decided once per node
  (`Paths.steps`).
- The self-view walk copied its loan lists on every store; it now
  copies only where a loan leads on.

These change no verdict and no message: `rig check` prints the same
for all 13,231 programs (every test, example, corpus probe, and
`field.` cell). They remove about three quarters of the extra
instructions. Timed again after the change, in a second quiet window
(load 3.1 at the start, 2.7 at the end), 16 interleaved rounds, the
ownership phase is 17.85 ms (main) against **18.68 ms** (PR) at best,
**+0.83 ms (5%)**, and 18.42 against 19.20 ms by mean, +0.78 ms (4%).
The runs are noisy: main alone ranged over 17.8–19.5 ms.

## Known strictness

`(!p.a).add(p.q.s)` (the reviewer's f03) is rejected as a self-view,
"cannot let this call store a view of `p.q.s` in `p.a`", where `p.a`'s
type has a `?String` field, though `add` only copies its argument into
a String. A call may store any argument whose type could be held in
what it writes, so the checker cannot see the copy. Round B's `keeps`
clause lifts it.

## Owner wording

The CORE text is as approved, but for its status markers, now
*(built)*.
