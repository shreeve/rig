# Review of rig#1152 (psum-handoff, 3029cea57): memory orderings in `handoff`

Verdict on the PR's change: **SOUND.** Separately, a pre-existing bug (from
#1147, unchanged here) in the ring path `handoff` relies on: **UNSOUND**,
a task can run twice. Details below.

## 1. The protocol, as changed

Waiter W runs on worker thread T1. Task fiber F, record `h`.

| step | who | access | before | after |
|---|---|---|---|---|
| B  `beginPlainWait` | W, T1 | `W.word := about(e)` store | seq_cst (xchg) | release |
| T  take F | W, T1 | slot CAS / ring tail store + head load | seq_cst | seq_cst (unchanged) |
| D1 | W, T1 | `h.done.waiter := W` | seq_cst | relaxed |
| D2 | W, T1 | `h.done.epoch := e` | seq_cst | relaxed |
| D3 | W, T1 | `h.done.status := waited` | seq_cst | release |
| H  | W, T1 | `F.handoff = W`, `handoff_epoch = e` (plain) | | |
| switch to F on T1 | | | | |
| M  `fiberMain` | F, T1 | load + CAS `W.word` about(e) -> asleep(e) | seq_cst | seq_cst |
| then either: | | | | |
| C  `claim` (F never stopped) | F, T1 | CAS `W.word` asleep(e) -> woken(e) | seq_cst | seq_cst |
| E  after switch back | W, T1 | `h.done.status := ended` | seq_cst | release |
| or (F stopped: `stopIn` nulls `F.handoff`): | | | | |
| U  `finishIn` | worker T2 that ends F | swap status->ending; load waiter, epoch; `interruptIn(W,e)` CAS; store ended | seq_cst | seq_cst |

Readers of what changed:
- `W.word`: only RMWs decide anything (`interruptIn`, `claim`, `fiberMain`'s CAS);
  the plain loads in `interruptForCancelIn` and `Deadline.come` only pick an epoch
  for an RMW. No one but `h.done.epoch` carries `e` off T1, and that is read only
  in U.
- `done.waiter/epoch/status`: U (another thread), W itself (`isDone`, select
  `watch`/`unwatch`), and the deadlock walk (`over()`, status >= ending).

## 2. Why the weaker orders hold

- **No Dekker pattern exists on the changed path.** The Dekker shape in the wait
  protocol is "fiber stores word, then loads a condition / cancel flag; waker
  stores condition, then RMWs word". In `beginWait` that condition is the cancel
  flag (kept seq_cst, and the cancelable path still uses `beginWait(true)`). In the
  plain path W loads no condition after B: the completion it waits for cannot have
  happened, because W itself is about to take the not-yet-started F (T). If the take
  fails, W returns to `Done.waitIn`, which starts a fresh seq_cst `beginWait`
  (epoch e+1); epoch e was never published, so the stale about(e) is harmless.
- **Single-location coherence is all the word needs.** Every waker step on `W.word`
  is an RMW, which reads the mo-latest value: a late waker of epoch e-1 sees e and
  gives up, or it precedes B in mo and B overwrites (the same as with seq_cst; the
  store's order never decided that race). `fiberMain` and `claim` run on T1 after
  B (or after an hb chain from it), so read-after-write coherence gives them B.
- **The end record reaches U by happens-before twice over.** (a) F can end on T2
  only after it stopped on T1: `stopIn` -> T1's `fallAsleep` CAS (seq_cst RMW) or a
  ring/global push (release) -> waker CAS / thief acquire on T2. D1-D3 are sequenced
  before that, so U's swap cannot precede D3 in mo, and reads `waited`.
  (b) Independently, U's swap (acq) reading D3 (release) synchronizes-with it, so
  U's loads of waiter/epoch see D1/D2. No lost wake-up.
- **E (ended, release)** is written in the claim path only, where F never stopped:
  everything ran on T1, no `finishIn` touches `h`, and the result F wrote is
  sequenced before. The only cross-thread reader is the deadlock walk's
  `over()`, a heuristic re-validated by `holds()`; a later-visible `ended` is
  indistinguishable from the walk having read a moment earlier.
- **x86-TSO:** release store = `mov`. The only new freedom is store->load
  reordering. Loads after B: lifo slots (monotonic, then a locked CAS) or ring
  tail/slot (then an `xchg` tail store); after D3: `spread`'s loads. `spread`'s
  Dekker is "slot swap vs `waiting` flag", neither of which B/D1-D3 is part of.
  **ARMv8:** both orders compile to `stlr` here (the PR says Mac timing is
  unchanged), and nothing reads with `ldapr`/plain loads expecting SC.
- **Frames/stacks:** unchanged. W's frame (holding nothing the record points to
  besides `W` itself) is reused only after W reads `ended`, which U stores last.

Nit: Wait.lean's header still says every step is a seq_cst CAS. Its proofs remain
valid (they are about one location, where coherence gives a total order), but the
sentence should say so: "each step is one access to the word, and all accesses to
one atomic location are totally ordered (coherence), so any order of steps is a run".
The `beginPlainWait` comment's justification is right.

## 3. Coverage

- `formal/LambdaRig/Wait.lean`: models only `W.word` as an SC interleaving; the `begin`
  step with `c = false` matches `beginPlainWait`. It cannot see orderings at all,
  nor the Done record, so it neither covers nor contradicts the change.
- `test/cli/wait_sync.sh`: a text check that `beginPlainWait` exists, increments the
  epoch, and packs `false`/`about`. It does not check orders (deliberately, since it
  accepts release) and does not look at `handoff` or `Done`.
- The relevant runtime test is the unit test "a task waited for as soon as it is made
  runs by handoff, and one that stops on the way still ends" (4 workers, `yield`
  in a third of the leaves, so F is stolen and ends on another thread: path U).
  It covers the `.next` path only, not `.ring`.
- `seeds:` runs are deterministic schedules: they explore switch-point
  interleavings, not hardware reorderings, so they can only cover paths. A litmus
  for this change would need W's D1-D3 and U on different cores with no hb chain,
  which the code makes impossible; there is nothing a litmus would find.

## 4. Pre-existing bug (from #1147): `Ring.takeLast` vs batch `stealFrom`

`stealFrom` reads `victim.head` h and `victim.tail` t, copies n = ceil((t-h)/2)
slots, then claims them with CAS head h -> h+n. The CAS validates head only, not
that the tail is still past h+n. `takeLast` takes without a CAS whenever
`left = last - h != 0`. So the owner can take two (or more) from the tail while
a thief is stalled between its copy and its CAS, and the newest moves down into
the thief's range:

```
ring [A, B, X], head 0, tail 3
thief: h=0, t=3, avail 3, n=2, copies A, B; stalls (OS preemption)
owner: takeLast(X): tail 2, head 0, left 2 -> takes X, runs it (its subtree nets 0)
owner: takeLast(B): tail 1, head 0, left 1 -> takes B, runs it
thief: CAS head 0 -> 2 succeeds; runs A and B
```

B runs twice (two fibers on one stack/frame, `Done` finished twice, record freed
under a runner); the ring ends with head 2 > tail 1, so `push` sees
`t -% h = 2^32-1 >= size`, takes the "full" path and unwraps null slots. Checked
with a direct model of the two functions (scratch `ring.py`). Reachable from
plain Rig: make 7+ tasks and join them newest-first (3+ spill to the ring), or a
deep psum recursion, whose left halves sit in the ring and are joined innermost
first. The window is one thief's copy-to-CAS, so it needs a descheduled thief
(oversubscription, pup under load); rare, real.

The doc on `takeLast` ("it reaches the newest only when it sees one alone") is
true of the newest at the thief's look, not at its CAS. Go's batch `runqsteal`
is safe only because Go's owner never pops from the tail.

Fix options (owner's/author's call): Tokio's packed head (steal-head, real-head in
one word: a thief first publishes the range it is stealing, and `takeLast` refuses
(returns false, so the waiter waits the usual way) when `last` falls inside an
in-flight steal); or thieves steal one at a time (classic Chase-Lev, where the
owner's CAS on `left == 0` suffices). Note a CAS of head h -> h by the owner would
not help: it does not stop a thief's later h -> h+n.

Tests to add:
1. Unit test with the steal split at a hook (a test-only stall between copy and
   CAS, or a factored `stealCopy`/`stealClaim`), replaying the trace above:
   must not hand B to both. Deterministic, and fails today.
2. A stress unit test: 4+ workers, a fiber that makes 8 tasks and joins them
   newest-first, 100k rounds, with thieves forced to yield (`std.Thread.yield`)
   between copy and CAS in test builds; assert each task ran once (a per-task
   counter) and the ring's `tail -% head <= size` after each round.

---

## 5. Review of the fix, rig#1157 (ring-steal-race, e145c3c41): SOUND

Protocol. Owner `takeLast`: `tail := last` (sc); load `stealing` (sc); if held,
`tail := t` (sc), false. Otherwise as before. Thief `stealFrom`: early look
(acquire, no decision but "empty"); CAS `stealing` 0->1 (sc), else null; then
load head (sc), load tail (sc), copy, CAS head (acq_rel), publish own tail;
`stealing := 0` (release, by `defer`, after the claim and the own-tail store).

**Dekker (owner: store tail, load flag; thief: RMW flag, load tail).** All four
are seq_cst, so they lie in S. Split on which flag value the owner reads:
- 1: it leaves the fiber. Safe.
- the 0 that a later thief T' will overwrite (initial, or an earlier release):
  the owner's load is coherence-ordered before T's CAS, so it precedes it in S
  (C++20 [atomics.order]); thus `tail := last` <S T'.CAS <S T'.load tail, and T'
  reads `last` or a later tail. With tail `last`, T' sees avail = last - h and
  takes ceil(avail/2) < avail for avail >= 2, never index `last`; at avail 1 it
  takes index last-1, while the owner either takes `last` without a CAS
  (left 1) or, having read the new head, CASes it (left 0). A later tail is the
  owner's own restore (only after it has settled the head by CAS, the classic
  one-element race) or a push, whose slot T' then reads through the tail's
  release/acquire.
- the 0 a thief T released: the owner's sc load is an acquire, so T's claim
  happens-before the owner's head load; `left` counts T's claim, and an index T
  claimed gives `left` > size, so the owner restores and returns false.
x86: the owner's tail store is `xchg`, the thief's CAS `lock cmpxchg`, both
full fences. ARMv8: `stlr` then `ldar` is ordered (RCsc), and so is
`casal`/`stlxr` then `ldar`. No reordering breaks it.

**Two thieves:** the flag CAS excludes the second, which returns null. **A lost
claim** (owner `pop` or the "full" path moved head) loops, re-reading head and
tail while still holding the flag. **Emptied ring / null slot:** returns null;
`defer` releases the flag on every exit.

**Sleep and wake:** no sleep decision reads the flag. `hasWork` and
`workPending` read head and tail (`isEmpty`), so a searcher that found the flag
held and gave up still sees the ring non-empty in the last searcher's check
(or the flag holder, a searcher itself, finds work and wakes another). Nothing
is stranded; at worst a wake is spent while a thief holds the flag.

**"Full" path:** with head <= tail <= head + size again an invariant (the
owner can no longer take below a thief's claim), `push`'s `t -% h` is sane; its
CAS of head races the thief's head CAS, and the loser re-reads.

**Holding the flag:** the thief never switches inside `stealFrom`; `search`
runs on the worker's own context, and `stealWaiting` in a fiber's yield check
does not park. The owner never waits on the flag, so no deadlock, and a stalled
thief costs the owner only the usual wait.

**The new unit test replays the trace.** Thief pauses after copying A, B
(n = 2) and before its CAS; the owner calls `takeLast(X)` then `takeLast(B)`.
With the flag removed: X taken (tail 2), B taken (left 1), thief's CAS 0->2
succeeds, the thief's ring holds B, so `took_b and thief_b` fails, and so does
`tail -% head <= size` (1 - 2). With the fix: `takeLast(X)` sees the flag and
restores; `takeLast(B)` fails at once (the tail slot is still X). It is
deterministic (main spins on `reached`). Nit: assert `!took_x` too, so a
regression that lets X through is named. The two eight-worker Rig stress
cases are unlikely to hit a copy-to-claim stall; the unit test is the guard.

**Composes with #1152.** A `takeLast` that leaves the fiber returns false
before `handoff` writes the end record; the waiter's word holds about(e), never
published, and `Done.waitIn` begins epoch e+1 with seq_cst and records itself
by a seq_cst CAS, the ordinary path. Nothing in #1152 depends on `takeLast`
succeeding.

Optional speed note, not soundness: while the flag is held the owner could
still take when `last - head >= size / 2`, since a thief's claim is at most
ceil(size/2) from the head it CASes; not needed for fork-join's short rings.
