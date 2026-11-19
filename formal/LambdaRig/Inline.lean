/-
An inline run is a schedule (docs/history/records/2026-11/
free-fork-join/language.md §8, item 6).

Free fork-join runs a task on its waiter's stack (`runHere`) when the
waiter reaches `>t` before the task has started. The waiter is in no
wait while the task runs and takes no step until it ends, so the run is
one order of the task machine's steps (Tasks.lean): the task brought to
its waiter's core, its own steps there, its `finish`, and the waiter's
`wait`. What the machine guarantees of every state reached (TasksSound:
`no_orphans`, `main_last`, `confined`, `pin_kept`, `cancel_sticky`)
then holds of every state of an inline run, with no new proof: only the
stack is new, and the room rule covers it outside λRig.

The one step the machine must allow is the first. `inline_core`: a task
not yet pinned (a task that has not started is pinned only when it was
made local), held by a running waiter, is on the waiter's core or can
be moved there by a step. A local task already is: it and its holder
are pinned to one core (`LocalPinned`). `inline_reach`: the steps of
the run, from a state reached, reach states the guarantees cover.
-/
import LambdaRig.TasksSound

namespace LambdaRig.Tasks

/-- Zero or more steps of the task machine. -/
inductive Steps : State → State → Prop where
  | refl (s : State) : Steps s s
  | step {s s' s'' : State} : Step s s' → Steps s' s'' → Steps s s''

/-- The states an inline run passes through, from a state reached, are
reached: the run is a schedule of the machine. -/
theorem inline_reach {s s' : State} (h : Reach s) (hs : Steps s s') : Reach s' := by
  induction hs with
  | refl => exact h
  | step st _ ih => exact ih (.step h st)

/-- A task its running waiter holds, not yet pinned or made local, is on
the waiter's core after at most one step (`migrate`), still held by it
and not ended: where an inline run puts it. -/
theorem inline_core {s : State} (h : Reach s) {w c : Nat} {kw kc : Task}
    (hw : s.task w = some kw) (hc : s.task c = some kc) (hp : kc.holder = some w)
    (hl : kc.ended = false) (hu : kc.home = none ∨ kc.localSpawn = true) :
    ∃ s', Steps s s' ∧ Reach s' ∧ ∃ kc', s'.task c = some kc' ∧ kc'.core = kw.core ∧
      kc'.holder = some w ∧ kc'.ended = false := by
  have hI := inv_reach h
  by_cases hloc : kc.localSpawn = true
  · obtain ⟨p, hcp, hwp⟩ := hI.2.2.2.1 c kc hc hloc
    have hwh := hwp w kw hp hw
    refine ⟨s, .refl s, h, kc, hc, ?_, hp, hl⟩
    rw [hI.2.1 c kc p hc hcp, hI.2.1 w kw p hw hwh]
  · have hh : kc.home = none := by
      rcases hu with hu | hu
      · exact hu
      · exact absurd hu hloc
    have st := Step.migrate s c kc kw.core hc hl hh
    refine ⟨_, .step st (.refl _), .step h st, { kc with core := kw.core }, ?_, rfl, hp, hl⟩
    simp

end LambdaRig.Tasks
