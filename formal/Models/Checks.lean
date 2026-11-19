/-
The model checks `lake build` runs, each with the counts it gave, so a
change to a model that changes what it explores shows here. A run that
breaks a rule prints the rule and the run that breaks it; here only its
first line is kept. About 30 seconds in all; `Deep.lean` has larger
runs, by hand.
-/
import Models.Ring
import Models.Sleep
import Models.Deque
import Models.FrameRecord
import Models.InlineCancel

open Models

/-! ## The ring -/

-- A ring of 4 (the overflow moves 2): the owner pushes 5 and pops twice,
-- in any order, while 2 thieves each steal once.
/-- info: ok: 630553 states, 1596330 steps, 1694 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Ring.system { size := 4, pushes := 5, pops := 2, steals := [1, 1] })).summary

-- A ring of 2 (the overflow moves 1): the owner pushes 4 and pops twice,
-- while one thief steals twice.
/-- info: ok: 25616 states, 48298 steps, 158 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Ring.system { size := 2, pushes := 4, pops := 2, steals := [2] })).summary

-- The check is not vacuous: a thief that claims with a plain store takes
-- a fiber the owner takes too.
/-- info: FAILED after 1519 states: a fiber was taken twice -/
#guard_msgs in
#eval IO.println (explore (Ring.system { size := 2, pushes := 4, pops := 2, steals := [2], blindSteal := true })).summary

-- `takeLast` and the `stealing` flag (#1157). The shape of the race: a
-- ring of 4, the owner pushes 3 and takes back the newest twice, while a
-- thief steals once.
/-- info: ok: 5496 states, 9738 steps, 85 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Ring.system { size := 4, pushes := 3, pops := 0, takes := 2, steals := [1] })).summary

-- A ring of 2: the owner pushes 3, pops once and takes back twice, in
-- any order, with the overflow, while a thief steals twice.
/-- info: ok: 58406 states, 111539 steps, 306 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Ring.system { size := 2, pushes := 3, pops := 1, takes := 2, steals := [2] })).summary

-- The code before #1157 takes a fiber twice: the thief sees A, B, X and
-- copies A and B; the owner takes back X, then B with no
-- compare-and-swap, since A is left; the thief's claim, which checks only
-- `head`, moves it past A and B.
/-- info: FAILED after 2936 states: a fiber was taken twice -/
#guard_msgs in
#eval IO.println (explore (Ring.system { size := 4, pushes := 3, pops := 0, takes := 2, steals := [1], flag := false })).summary

/-! ## The fork deque (free fork-join, before its code) -/

-- Sequentially consistent: a deque of 2, the maker pushes 3 forks (the
-- third may find it full) and joins each, its loop takes the newest
-- once, and 2 thieves steal once each.
/-- info: ok: 701808 states, 1721196 steps, 2202 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 3, steals := [1, 1], loops := 1 })).summary

-- With the maker's store buffer, drained in order (x86), and out of order
-- but for release stores (arm64): the design's orders hold.
/-- info: ok: 193177 states, 494136 steps, 963 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 3, steals := [1, 1], arch := .tso })).summary

/-- info: ok: 197401 states, 511024 steps, 963 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 3, steals := [1, 1], arch := .arm })).summary

-- On x86 the push needs no release: stores drain in order.
/-- info: ok: 193177 states, 494136 steps, 963 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 3, steals := [1, 1], arch := .tso, pushOrd := .rlx })).summary

-- Each order the design leans on is needed. The last fork taken with no
-- compare-and-swap, and a thief that claims with a plain store, take a
-- fork twice.
/-- info: FAILED after 95 states: a fork was taken twice -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 1, steals := [1], lastNoCas := true })).summary

/-- info: FAILED after 1243 states: a fork was taken twice -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 2, steals := [1, 1], blindSteal := true })).summary

-- The fence: with `popIf`'s store of `bottom` a release, on x86 the load
-- of `top` passes it. Forks 0 and 1 in the deque; the maker stores
-- `bottom = 1` into its buffer, reads `top = 0` and takes fork 1 with no
-- compare-and-swap; a thief, reading `bottom = 2` from memory, steals 0,
-- then 1.
/-- info: FAILED after 3395 states: a fork was taken twice -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 2, steals := [2], arch := .tso, popOrd := .rel })).summary

-- On arm64 the push's store of `bottom` needs its release: monotonic, it
-- reaches memory before the slot's, and a thief claims an empty slot.
/-- info: FAILED after 112 states: a thief claimed an empty slot -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 1, steals := [1], arch := .arm, pushOrd := .rlx })).summary

-- A thief that reads `bottom` before `top`: it reads `bottom = 2`; the
-- maker takes fork 1 with no compare-and-swap; another thief steals 0;
-- it reads `top = 1` and steals 1.
/-- info: FAILED after 8854 states: a fork was taken twice -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 2, steals := [1, 1], loadsSwapped := true })).summary

-- A thief that writes through the slot's pointer before its claim wins
-- writes into a record the maker ran inline and let go.
/-- info: FAILED after 155 states: fork 0's record written after it was let go (the stolen bit, before the claim) -/
#guard_msgs in
#eval IO.println (explore (Deque.system { size := 2, forks := 1, steals := [1], readThrough := true })).summary

/-! ## A record in its maker's frame -/

-- The fixed order: the thief's last access is `ended`; whoever reads it
-- takes the record off the isolate's list. With the maker panicking, and
-- with a panic elsewhere stopping the isolate while the maker lives.
/-- info: ok: 101 states, 188 steps, 5 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (FrameRecord.system { order := .fixed, otherPanic := true })).summary

-- Today's `Control.finish` (off the list, then the record's writes) is
-- sound while no maker panics, as for a heap record.
/-- info: ok: 83 states, 152 steps, 4 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (FrameRecord.system { order := .today, mayPanic := false, otherPanic := true })).summary

-- With a frame record it is not: the maker panics, the thief's remove
-- empties the list, the stopper gives the kept stack back, and the
-- thief's store of `done` writes into it.
/-- info: FAILED after 60 states: the thief's done's store after the record's memory was let go -/
#guard_msgs in
#eval IO.println (explore (FrameRecord.system { order := .today })).summary

-- Nor is the remove made last: the maker, alive, reads `ended`, its frame
-- is used again, and the thief's remove writes the record's links.
/-- info: FAILED after 61 states: the thief's the isolate's remove after the record's memory was let go -/
#guard_msgs in
#eval IO.println (explore (FrameRecord.system { order := .removeLast })).summary

-- Nor a stopper that notes the records listed and waits for their
-- `ended` after the list empties: the thief took the record off the list
-- first, so the maker's read of `ended` and its frame used again come
-- before the stopper's read.
/-- info: FAILED after 92 states: the stopper's read of ended after the record's memory was let go -/
#guard_msgs in
#eval IO.println (explore (FrameRecord.system { order := .snapshot, mayPanic := false, otherPanic := true })).summary

/-! ## A cancel of a task run inline -/

-- Two levels inline over the fiber's own task, three started in all (so
-- a frame is used again), two waits, one cancel of any level.
/-- info: ok: 4919 states, 8334 steps, 250 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (InlineCancel.system {})).summary

/-- info: ok: 18843 states, 31707 steps, 977 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (InlineCancel.system { depth := 3, starts := 4 })).summary

-- The bit set after the word is read; the bit and the wake sent to the
-- task's own `Fiber` (no `host`); a wait that reads only its own level's
-- flag: each loses a cancel of an outer level.
/-- info: FAILED after 2305 states: a cancel was lost: the fiber sleeps, the canceled level live -/
#guard_msgs in
#eval IO.println (explore (InlineCancel.system { bitAfterWord := true })).summary

/-- info: FAILED after 1406 states: a cancel was lost: the fiber sleeps, the canceled level live -/
#guard_msgs in
#eval IO.println (explore (InlineCancel.system { noHost := true })).summary

/-- info: FAILED after 1897 states: a cancel was lost: the fiber sleeps, the canceled level live -/
#guard_msgs in
#eval IO.println (explore (InlineCancel.system { noPassDown := true })).summary

-- A canceler that walks the chain itself reads a record a later fork
-- reused.
/-- info: FAILED after 1878 states: the canceler's walk reached a record a later fork reused -/
#guard_msgs in
#eval IO.println (explore (InlineCancel.system { cancelerWalks := true })).summary

/-! ## Sleeping and waking -/

-- Two workers, the fibers making two pieces of work into their rings.
/-- info: ok: 36488 states, 72103 steps, 71 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, ring := true })).summary

-- Three workers, the others asleep at first, the first fiber making one
-- piece of work into its ring.
/-- info: ok: 5137 states, 10081 steps, 21 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 3, budget := 1, ring := true, asleep := true, firstMakes := true })).summary

-- The pinned queue's `idle` handshake: two workers, two pieces of work
-- into a pinned queue, by a fiber (`wakeHome`) or the thread outside.
/-- info: ok: 159086 states, 448775 steps, 53 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, home := true, outsideHome := true })).summary

-- Three workers, the others asleep at first, the first fiber making two
-- pieces of work into the others' pinned queues.
/-- info: ok: 387366 states, 1085322 steps, 162 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 3, budget := 2, home := true, asleep := true, firstMakes := true })).summary

-- Work into the global queue, from the thread outside, as a blocking
-- call's end makes it. Without `relook`, a worker can sleep while it
-- waits: worker 0 searches and finds nothing; worker 1, seeing a worker
-- searching, sleeps without a last look; two pieces of work arrive, and
-- `notifyNew`, seeing worker 0 searching, wakes no one; worker 0 stops
-- searching, its last look before sleeping finds the work, and it takes
-- one piece and runs on, so the other waits in the global queue, with
-- worker 1 asleep, until worker 0's next yield check. Work it finds in
-- that last look is not taken while searching, so no `notify` follows.
/-- info: FAILED after 177396 states: a worker sleeps while the global queue has work -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, global := true })).summary

-- With a worker that finds work in its last look counting itself as
-- searching again (`relook`), as `sched.sleep` and Go's scheduler do,
-- it notifies once it takes one, and no worker sleeps while work waits.
/-- info: ok: 1092168 states, 3068838 steps, 145 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, global := true, relook := true })).summary

/-- info: ok: 18722 states, 45555 steps, 24 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 3, budget := 1, global := true, asleep := true, relook := true })).summary

-- The checks are not vacuous: a `sleep` with no last look, or a
-- `wakeHome` that never kicks, leaves a worker asleep beside work.
/-- info: FAILED after 2004 states: a worker sleeps while a ring has work to steal -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, ring := true, noLastLook := true })).summary

/-- info: FAILED after 18757 states: a worker sleeps while it has pinned work -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, home := true, outsideHome := true, noKick := true })).summary

-- The last searcher to find work wakes another only while other work
-- waits (`workPending`), and without that, with three workers: worker 1,
-- woken for a fiber in worker 0's ring, searches; worker 0's fiber makes
-- another, whose `notify`, seeing a worker searching, wakes no one;
-- worker 1 steals one and, waking none, runs on, as does worker 0, while
-- worker 2 sleeps beside the other.
/-- info: FAILED after 776 states: a worker sleeps while a ring has work to steal -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 3, budget := 2, ring := true, asleep := true, firstMakes := true, noPending := true })).summary

-- A thief that steals more than the fiber it runs keeps the rest in its
-- ring, which `workPending`, reading only the others', does not see:
-- `spread` wakes a worker for it as the thief switches to its fiber.
/-- info: ok: 113549 states, 228670 steps, 196 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 3, ring := true, relook := true })).summary

-- Without `spread`: worker 0's fiber makes three while worker 1
-- searches, so wakes no one; worker 1 steals two, worker 0 takes the
-- third and goes to sleep with no last look, since one searches; worker
-- 1, the last searcher, finds no other work waiting and runs one fiber
-- on, the other left in its ring.
/-- info: FAILED after 13329 states: a worker sleeps while a ring has work to steal -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 3, ring := true, relook := true, noSpread := true })).summary

-- Batches from the pollers. A fiber can wait in a slot that no last look
-- reads: worker 1's sleep puts one batch's first in its slot and goes
-- back to work, counted as searching, as worker 0 ends a search that
-- found nothing; at its turn to look at its poller, worker 1 puts the
-- next batch's first in a second slot and runs that one; its `spread`
-- wakes no one, since worker 0 still counts as searching; worker 0's
-- last look reads the rings and the global queue, all empty, and it
-- sleeps, while worker 1's fiber runs on.
/-- info: FAILED after 18076 states: a worker sleeps while a run-next slot has work to steal -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, batch := true, relook := true })).summary

-- The monitor's stop takes such a fiber on (in about 2 ms: two of its
-- 1 ms looks).
/-- info: ok: 80362 states, 158965 steps, 134 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, batch := true, relook := true, monitor := true })).summary

-- So would a last look that read the slots too, and nothing else
-- strands a batch's fibers: its rest in the ring is woken for by
-- `spread`, or seen by a last look.
/-- info: ok: 38781 states, 77322 steps, 66 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, batch := true, relook := true, lookSlots := true })).summary

-- Without `spread`, a batch's rest waits in the ring with every other
-- worker asleep.
/-- info: FAILED after 107 states: a worker sleeps while a ring has work to steal -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, batch := true, asleep := true, relook := true, lookSlots := true, noSpread := true })).summary

-- On the Mac, a worker whose fibers are short keeps the rest of a batch
-- of its own poller's events (`keep`): no worker is woken for it, steals
-- it, or counts it in a last look until its time passes, and then the
-- watcher takes it. No worker then sleeps for good while a ring holds
-- work, kept or not.
/-- info: ok: 57881 states, 116698 steps, 108 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, batch := true, relook := true, lookSlots := true, keep := true })).summary

-- With the others asleep at first, so the batch's holder runs on while
-- they sleep.
/-- info: ok: 37487 states, 73884 steps, 85 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, batch := true, asleep := true, relook := true, lookSlots := true, keep := true })).summary

-- Without the watcher's take, a batch kept past its time waits in the
-- ring of a worker whose fiber runs on, with every other worker asleep.
/-- info: FAILED after 184 states: a worker sleeps while a ring has work to steal -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, batch := true, asleep := true, relook := true, lookSlots := true, keep := true, noWatch := true })).summary
