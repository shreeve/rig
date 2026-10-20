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

/-- info: ok: 7734406 states, 23289050 steps, 401 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system ring3) 30000000).summary

/-- info: ok: 1301655 states, 3796476 steps, 119 with no step enabled -/
#guard_msgs in
#eval IO.println (explore (Sleep.system every2) 30000000).summary
