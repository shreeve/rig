/-
Tasks: who holds each task's handle, the cores tasks run on, and the
values that stay on one thread (docs/CONCURRENCY.md, "Local tasks").

A machine of tasks, each with its holder (the task whose record holds
its handle, and which waits for it), the core it runs on, the core it is
pinned to if any (`sched.pinHere`), whether it was made a local task,
the values it holds that stay on one thread (a `*T` whose count is not
atomic, a Cell of more than one word, a Signal), and whether it ended
and was canceled. A task holds the handles of the tasks whose holder it
is; once it ends, what it holds is its result. The steps are what a
running program does to them:

- `spawnFree`: `f(x)&` whose arguments cross cores (`sema.crossingBlocker`
  finds nothing), so it is given no value that stays on one thread, and
  only handles of tasks that are not local, and runs on any core;
- `spawnLocal`: `f(x)&` given values that stay on one thread, some of
  those its maker holds (a `+h` passed makes another holder), or the
  handle of a local task: the task and its maker are pinned to the
  maker's core (`Task.spawnLocal`);
- a spawn may be given handles its maker holds (`Task[T]` as an
  argument), which the new task then holds;
- `migrate`: a worker steals a task that is not pinned;
- `make` and `drop`: a task makes such a value, or drops it;
- `cancel`: the holder cancels the task;
- `finish`: a task ends, keeping what its result holds. Handles it held
  stay in its result (`Task[T]` returned); one it does not return it
  waits for first, as a dropped handle cancels and waits. A task that
  is not local returns only what crosses: no value that stays on one
  thread, and no handle of a local task (a local task's result need not
  cross, so neither does its handle). That is the rule that a task's
  result moves unless the task is local. `main` returns no handle;
- `wait`: the holder takes the result of a task that ended: the values
  and the handles it held. Its record is freed.

What is proved, of every state reached (`TasksSound.lean`):

- `no_orphans`: every task but `main` is held by a running task, or by
  the result of an ended one that is itself held so, so no task is left
  running, or unwaited, with no running task answerable for it;
- `main_last`: once `main` has ended, no other task is left;
- `confined`: two tasks that hold one value that stays on one thread
  are both pinned to one core and run there, so no two cores touch it;
- `pin_kept`: a pinned task stays on its core from then on;
- `cancel_sticky`: a cancel is never taken back.

Not modeled yet: `Tasks` sets, actors, and channels; the crossing rule
says which of their contents cross, and the next slice adds them.
-/

namespace LambdaRig.Tasks

/-- A task. Tasks, cores, and values that stay on one thread are
numbered. -/
structure Task where
  holder : Option Nat
  core : Nat
  home : Option Nat
  localSpawn : Bool
  holds : Nat → Bool
  ended : Bool
  canceled : Bool

structure State where
  task : Nat → Option Task
  /-- Every task's number is below it. -/
  fresh : Nat

/-- `main`, task 0, on core 0, holding nothing. -/
def main : Task := ⟨none, 0, none, false, fun _ => false, false, false⟩

def State.init : State := ⟨fun t => if t = 0 then some main else none, 1⟩

/-- `s` with the record of `t` replaced by `k`. -/
def State.set (s : State) (t : Nat) (k : Option Task) : State :=
  { s with task := fun x => if x = t then k else s.task x }

/-- `s` with a new task, `k`, numbered `s.fresh`. -/
def State.add (s : State) (k : Task) : State :=
  { task := fun x => if x = s.fresh then some k else s.task x, fresh := s.fresh + 1 }

/-- `s` with the handle of every task `sel` picks held by `n`. -/
def State.hand (s : State) (sel : Nat → Task → Bool) (n : Nat) : State :=
  { s with task := fun x => (s.task x).map fun k => if sel x k then { k with holder := some n } else k }

/-- `t` holds the handle of each task `sel` picks. -/
def Holds (s : State) (t : Nat) (sel : Nat → Bool) : Prop :=
  ∀ x, sel x = true → ∃ kx, s.task x = some kx ∧ kx.holder = some t

/-- The handles held by `c`. -/
def heldBy (c : Nat) : Nat → Task → Bool := fun _ k => decide (k.holder = some c)

inductive Step : State → State → Prop where
  | spawnFree (s : State) (t : Nat) (k : Task) (c : Nat) (sel : Nat → Bool)
      (ht : s.task t = some k) (hl : k.ended = false) (hs : Holds s t sel)
      (hx : ∀ x kx, s.task x = some kx → sel x = true → kx.localSpawn = false) :
      Step s ((s.hand (fun x _ => sel x) s.fresh).add
        ⟨some t, c, none, false, fun _ => false, false, false⟩)
  | spawnLocal (s : State) (t : Nat) (k : Task) (pass : Nat → Bool) (sel : Nat → Bool)
      (ht : s.task t = some k) (hl : k.ended = false) (hs : Holds s t sel)
      (hp : ∀ v, pass v = true → k.holds v = true) :
      Step s (((s.set t (some { k with home := some k.core })).hand (fun x _ => sel x) s.fresh).add
        ⟨some t, k.core, some k.core, true, pass, false, false⟩)
  | migrate (s : State) (t : Nat) (k : Task) (c : Nat)
      (ht : s.task t = some k) (hl : k.ended = false) (hh : k.home = none) :
      Step s (s.set t (some { k with core := c }))
  | make (s : State) (t : Nat) (k : Task) (v : Nat)
      (ht : s.task t = some k) (hl : k.ended = false)
      (hv : ∀ x kx, s.task x = some kx → kx.holds v = false) :
      Step s (s.set t (some { k with holds := fun u => k.holds u || decide (u = v) }))
  | drop (s : State) (t : Nat) (k : Task) (v : Nat)
      (ht : s.task t = some k) (hl : k.ended = false) :
      Step s (s.set t (some { k with holds := fun u => k.holds u && !decide (u = v) }))
  | cancel (s : State) (t : Nat) (k : Task) (c : Nat) (kc : Task)
      (ht : s.task t = some k) (hl : k.ended = false)
      (hc : s.task c = some kc) (hp : kc.holder = some t) :
      Step s (s.set c (some { kc with canceled := true }))
  | finish (s : State) (t : Nat) (k : Task) (keep : Nat → Bool)
      (ht : s.task t = some k) (hl : k.ended = false)
      (hk : ∀ v, keep v = true → k.holds v = true)
      (hfree : k.localSpawn = false → (∀ v, keep v = false) ∧
        ∀ x kx, s.task x = some kx → kx.holder = some t → kx.localSpawn = false)
      (hmain : t = 0 → ∀ x kx, s.task x = some kx → kx.holder ≠ some t) :
      Step s (s.set t (some { k with ended := true, holds := keep }))
  | wait (s : State) (t : Nat) (k : Task) (c : Nat) (kc : Task)
      (ht : s.task t = some k) (hl : k.ended = false)
      (hc : s.task c = some kc) (hp : kc.holder = some t) (he : kc.ended = true) :
      Step s (((s.set t (some { k with holds := fun v => k.holds v || kc.holds v })).hand
        (heldBy c) t).set c none)

/-- The states some run reaches from `State.init`. -/
inductive Reach : State → Prop where
  | init : Reach State.init
  | step {s s' : State} : Reach s → Step s s' → Reach s'

/-- The holder of each task recorded. -/
def State.hol (s : State) (x : Nat) : Option Nat := (s.task x).bind (·.holder)

/-- `x` is held by a running task, or by the result of an ended task
held so in turn. -/
inductive Held (s : State) : Nat → Prop where
  | running {x p : Nat} {kx kp : Task} : s.task x = some kx → kx.holder = some p →
      s.task p = some kp → kp.ended = false → Held s x
  | result {x p : Nat} {kx kp : Task} : s.task x = some kx → kx.holder = some p →
      s.task p = some kp → kp.ended = true → Held s p → Held s x

end LambdaRig.Tasks
