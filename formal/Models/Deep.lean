/-
Larger runs of the models, by hand (`lake build Models.Deep`, a few
minutes and 8 GB): `lake build` runs `Checks.lean` only.
-/
import Models.Sleep

open Models

-- Three workers, the first making two fibers into its ring.
def ring3 : Sleep.Config := { workers := 3, budget := 2, ring := true, asleep := true, firstMakes := true }

-- Two workers, every way of making work, two pieces of it.
def every2 : Sleep.Config :=
  { workers := 2, budget := 2, ring := true, home := true, global := true, outsideHome := true, relook := true }

-- The same with the pollers' batches too, and the monitor.
def batches2 : Sleep.Config := { every2 with batch := true, monitor := true }

-- Three workers, the others asleep, two pieces from pollers, with a
-- last look that reads the slots (with the monitor instead, past 30
-- million states).
def batches3 : Sleep.Config :=
  { workers := 3, budget := 2, batch := true, asleep := true, relook := true, lookSlots := true }

/-- info: ok: 3593823 states, 10610794 steps, 375 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system ring3) 30000000).summary

/-- info: ok: 1919333 states, 5473026 steps, 217 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system every2) 30000000).summary

/-- info: ok: 3800847 states, 10728319 steps, 488 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system batches2) 30000000).summary

/-- info: ok: 5918074 states, 17691824 steps, 631 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system batches3) 30000000).summary
