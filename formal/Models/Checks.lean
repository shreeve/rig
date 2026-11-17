/-
The model checks `lake build` runs, each with the counts it gave, so a
change to a model that changes what it explores shows here. A run that
breaks a rule prints the rule and the run that breaks it; here only its
first line is kept. About 30 seconds in all; `Deep.lean` has larger
runs, by hand.
-/
import Models.Ring
import Models.Sleep

open Models

/-! ## The ring -/

-- A ring of 4 (the overflow moves 2): the owner pushes 5 and pops twice,
-- in any order, while 2 thieves each steal once.
/-- info: ok: 515484 states, 1318383 steps, 1013 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Ring.system { size := 4, pushes := 5, pops := 2, steals := [1, 1] })).summary

-- A ring of 2 (the overflow moves 1): the owner pushes 4 and pops twice,
-- while one thief steals twice.
/-- info: ok: 15685 states, 28986 steps, 129 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Ring.system { size := 2, pushes := 4, pops := 2, steals := [2] })).summary

-- The check is not vacuous: a thief that claims with a plain store takes
-- a fiber the owner takes too.
/-- info: FAILED after 737 states: a fiber was taken twice -/
#guard_msgs in
#eval IO.println (explore (Ring.system { size := 2, pushes := 4, pops := 2, steals := [2], blindSteal := true })).summary

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
