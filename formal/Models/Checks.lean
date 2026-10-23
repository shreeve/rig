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
/-- info: ok: 31500 states, 63594 steps, 58 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, ring := true })).summary

-- Three workers, the others asleep at first, the first fiber making one
-- piece of work into its ring.
/-- info: ok: 251576 states, 711064 steps, 105 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 3, budget := 1, ring := true, asleep := true, firstMakes := true })).summary

-- The pinned queue's `idle` handshake: two workers, two pieces of work
-- into a pinned queue, by a fiber (`wakeHome`) or the thread outside.
/-- info: ok: 135277 states, 382819 steps, 53 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, home := true, outsideHome := true })).summary

-- Three workers, the others asleep at first, the first fiber making two
-- pieces of work into the others' pinned queues.
/-- info: ok: 291511 states, 810198 steps, 162 with no step enabled -/
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
/-- info: FAILED after 117243 states: a worker sleeps while the global queue has work -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, global := true })).summary

-- With a worker that finds work in its last look counting itself as
-- searching again (`relook`), as `sched.sleep` and Go's scheduler do,
-- it notifies once it takes one, and no worker sleeps while work waits.
/-- info: ok: 623085 states, 1788286 steps, 74 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, global := true, relook := true })).summary

/-- info: ok: 740958 states, 2471269 steps, 117 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 3, budget := 1, global := true, asleep := true, relook := true })).summary

-- The checks are not vacuous: a `sleep` with no last look, or a
-- `wakeHome` that never kicks, leaves a worker asleep beside work.
/-- info: FAILED after 1618 states: a worker sleeps while a ring has work to steal -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, ring := true, noLastLook := true })).summary

/-- info: FAILED after 16928 states: a worker sleeps while it has pinned work -/
#guard_msgs in
#eval IO.println (explore (Sleep.system { workers := 2, budget := 2, home := true, outsideHome := true, noKick := true })).summary
