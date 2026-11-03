# Panel 3: adversarial soundness

Probes are in the panel scratch folder `adversarial/`.
All ran with `RIG_WORKERS=8 RIG_SANITIZE=1`.

## Findings, most severe first

1. **A closure literal lent to a task outlives its captures.**
   `t = apply(3, |+k, x| x + k)&`, with `f: ?fun(Int) -> Int`, passes
   `rig check`. Emit builds the captures in a block that ends before the
   task runs. `l2_closure_literal_dangling.rig` panics with
   "integer overflow" in all 3 runs; without the sanitizer it is right
   only by luck. The task keeps no loan for the captures either: in
   `l1`, `|!total|` writes while `main` writes, and it segfaulted at
   0xaaaa.... `crossCheck` treats the literal as a function *given*, but
   SPEC rejects a function *lent*.
2. **A task's result is never checked to move.** In `d1_result_smuggle.rig`,
   a free task gives `+n` to a local task, which is pinned to that
   worker, then returns `n` with that task's `Task[Int]`. `main`, on
   another core, clones `n` as the local task does. Of 6 runs, 5 reported
   "memory leak detected" and 1 "use of freed memory". `par.map` and
   actor calls check their results; `taskOf` does not.
3. **A full mailbox on one's own actor hangs.** In `h2_mailbox_self.rig`,
   a method makes 3 `me.get()&` calls on its own actor, whose mailbox
   holds 2. It hangs, though SPEC promises a panic.
4. **A deadlock on channels alone hangs.** In `h3`, `main` waits on
   `recv` of a channel only it holds. SPEC does not cover it.

These held: actor arguments, results, values and `supervised`
captures; `par` and `http.serve` captures; generic and enum wrappers;
loans through tasks returned or sent; `select` (`g1`, `g2`); drops of sets
and canceled tasks (no leaks); deadlock stress with no false positives
(`n1`); and 17 `>t` forms.

I could not show this one: a task that panics under an isolate frees its
stack while a child still reads its frame (`p1`-`p3` found no
corruption).

## Decisions for the owner

1. Reject a closure literal lent to a task, as `?f` already is.
   Default: reject.
2. Require a task's result to move unless the task is local, using
   `par.map`'s check. Default: yes.
3. Count a wait for a mailbox slot in deadlock detection. Default: yes.
4. Report "every task waits and nothing can wake one". Default: in
   debug and `rig test` builds only.
5. Keep a panicked task's stack until its isolate has waited for every
   task under it. Default: yes, as a precaution.
