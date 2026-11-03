# Panel 5: formal methods

## Findings

1. **A lost cancel in `sched.waitReady`** (src/sched.zig:823-829). The
   cancel flag is read before `beginWait`, never after. A cancel landing
   between is lost, and a read on an idle socket with no deadline hangs.
   `Header.waitEnd` re-checks (line 1841). Found by reading.
2. **The cancel Dekker is not sequentially consistent.** `canceledHere`
   (src/tasks.zig:2008) loads `.acquire`. Zig 0.17 on this Mac emits
   `stlr` then `ldaprb`, which may pass each other, so fiber and canceler
   can both miss, at four waiting points. Wait.lean assumes SC steps and
   cannot see this.
3. **`no_orphans` holds by fiat.** `parent` is fixed at spawn, and
   `finish` requires no children. Handles move (test "task moved into a
   task"). Probe `ret.rig` prints 16: the maker ended while its child
   ran. Restate the invariant over the handle's holder. Nothing proves
   that dropping a handle cancels and waits.
4. **Wait.lean proves the word, not the protocol.** `cancel_delivered`
   is nearly definitional. Unmodeled: how a waker learns the fiber and
   epoch (`Header` status, `Registration.Waiter`, `Wakeup`, `Sel`, the
   pool), which is where wakeups get lost. Unverified suspicion:
   `Waiter.wakeIt` can touch a freed fiber.
5. The pinned queue's idle-flag handshake is sound.

## Order and cost

Model-check the runtime first, about 2 weeks:
- TLA+ for the Ring steal, sleep and notify liveness, and wait
  publication;
- GenMC or herd7 for handshakes with mixed orderings, which TLA+ misses
  (finding 2);
- Lean `decide` over bounded epochs.

Then the Lean obligations:
- 5 at every waiting point (1 week);
- 3 with handle transfer (2 weeks);
- 4 (2 weeks);
- 2 (3 weeks);
- 1, in separation logic (2 or more months);
- 6, in Iris (several months).

## Against drift

- Export the Lean step tables as JSON, and replay them in `zig test`
  against `interrupt`, `claim`, and `fallAsleep`.
- Lint that every `beginWait(true)` is followed by a cancel check.
- Place comptime yield points at each atomic, and explore them under
  deterministic seeds, as loom does.
- Run a Lean port of `blockerIn` beside `sema`.

## Decisions for the owner

1. In `waitReady`, re-check the cancel flag after `beginWait`. *Yes.*
2. Make `canceledHere` `.seq_cst`, and audit similar handshakes. *Yes.*
3. Restate `no_orphans` over the handle's holder. *Yes.*
4. Model-check the runtime before more hand proofs. *Yes.*
5. Add the Lean-to-Zig step-table test. *Yes.*
