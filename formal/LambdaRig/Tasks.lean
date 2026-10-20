/-
Tasks: who holds each task's handle, the cores tasks run on, and the
values that stay on one thread (docs/CONCURRENCY.md, "Local tasks").

A machine of tasks, each with its parent (the task that made it and
holds its handle, which waits for it), the core it runs on, the core it
is pinned to if any (`sched.pinHere`), whether it was made a local task,
the values it holds that stay on one thread (a `*T` whose count is not
atomic, a Cell of more than one word, a Signal), and whether it ended
and was canceled. The steps are what a running program does to them:

- `spawnFree`: `f(x)&` whose arguments cross cores (`sema.crossingBlocker`
  finds nothing), so it is given no value that stays on one thread, and
  runs on any core;
- `spawnLocal`: `f(x)&` given values that stay on one thread, some of
  those its maker holds (a `+h` passed makes another holder): the task
  and its maker are pinned to the maker's core (`Task.spawnLocal`);
- `migrate`: a worker steals a task that is not pinned;
- `make` and `drop`: a task makes such a value, or drops its handle;
- `cancel`: the parent cancels its task;
- `finish`: a task ends, having waited for every task it made, keeping
  what its result holds;
- `wait`: the parent takes the result of a task that ended, and its
  record is freed.

What is proved, of every state reached (`TasksSound.lean`):

- `no_orphans`: the parent of every task is running, so no task is
  left running, or unwaited, past the task that holds its handle;
- `confined`: two tasks that hold one value that stays on one thread
  are both pinned to one core and run there, so no two cores touch it;
- `pin_kept`: a pinned task stays on its core from then on;
- `cancel_sticky`: a cancel is never taken back.

Not modeled yet: a task's handle handed to another task (`Task[T]`
given as an argument or a result), `Tasks` sets, actors, and channels;
the crossing rule says which of their contents cross, and the next
slice adds them.
-/

namespace LambdaRig.Tasks

/-- A task. Tasks, cores, and values that stay on one thread are
numbered. -/
structure Task where
  parent : Option Nat
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

inductive Step : State → State → Prop where
  | spawnFree (s : State) (t : Nat) (k : Task) (c : Nat)
      (ht : s.task t = some k) (hl : k.ended = false) :
      Step s (s.add ⟨some t, c, none, false, fun _ => false, false, false⟩)
  | spawnLocal (s : State) (t : Nat) (k : Task) (pass : Nat → Bool)
      (ht : s.task t = some k) (hl : k.ended = false)
      (hp : ∀ v, pass v = true → k.holds v = true) :
      Step s ((s.set t (some { k with home := some k.core })).add
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
      (hc : s.task c = some kc) (hp : kc.parent = some t) :
      Step s (s.set c (some { kc with canceled := true }))
  | finish (s : State) (t : Nat) (k : Task) (keep : Nat → Bool)
      (ht : s.task t = some k) (hl : k.ended = false)
      (hown : ∀ c kc, s.task c = some kc → kc.parent ≠ some t)
      (hk : ∀ v, keep v = true → k.holds v = true) :
      Step s (s.set t (some { k with ended := true, holds := keep }))
  | wait (s : State) (t : Nat) (k : Task) (c : Nat) (kc : Task)
      (ht : s.task t = some k) (hl : k.ended = false)
      (hc : s.task c = some kc) (hp : kc.parent = some t) (he : kc.ended = true) :
      Step s ((s.set t (some { k with holds := fun v => k.holds v || kc.holds v })).set c none)

/-- The states some run reaches from `State.init`. -/
inductive Reach : State → Prop where
  | init : Reach State.init
  | step {s s' : State} : Reach s → Step s s' → Reach s'

/-- `x` descends from `r` through tasks each made local: its parent is
`r`, or descends from `r` so. -/
inductive LocalDesc (s : State) (r : Nat) : Nat → Prop where
  | child {x : Nat} {kx : Task} : s.task x = some kx → kx.localSpawn = true →
      kx.parent = some r → LocalDesc s r x
  | step {x y : Nat} {kx : Task} : LocalDesc s r y → s.task x = some kx →
      kx.localSpawn = true → kx.parent = some y → LocalDesc s r x

end LambdaRig.Tasks
