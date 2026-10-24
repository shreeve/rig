/-
Tasks: erasing a type keeps what a crossing check reads.

An API object crosses tasks only by a bound it names (docs/CORE.md §4;
docs/design/apis.md, Stage 5): `Sends` and `Syncs`, in the braces or
the API, are facts of the hidden value, checked where it is erased; an
object without the bound a task needs goes to no task, a local one
included, at any depth; and no API object holds a task.

`CVal` is a value as a crossing check sees it: what it holds that stays
on one thread (the values of LambdaRig/Tasks.lean, numbered), the task
handles it holds, its parts, and the API objects in it. An object's
facts are its hidden value's (`holds_erase`, `tasks_erase`), so:

- a value that may not cross before erasure may not cross after, and
  one that may, may (`crosses_erase`); a spawn reads the same facts of
  the object as of the value (`spawn_erase`);
- an object whose bound was checked at erasure (`EraseOk`, the check
  `crossingBlocker` makes) holds nothing that stays on one thread and no
  task, so a free spawn may take it (`erase_sends`);
- an object whose braces and API name no bound is taken by no spawn
  (`bare_no_spawn`);
- every spawn of arguments a task holds is a step of the task machine
  (`spawn_step`), so after a spawn of erased values `confined` and
  `pin_kept` hold as before (`erase_confined`).

The task machine does not tell moving a value to another task from
sharing it with one, so `Sends` and `Syncs` are checked here as one
fact: the hidden value holds nothing that stays on one thread. That a
`*{A + Syncs}` holds only a frozen value, whose count is atomic, is the
same fact for its handle: a `*T` whose count is not atomic is a value
that stays on one thread.
-/
import LambdaRig.TasksSound

namespace LambdaRig.Tasks

/-- A bound an API object names for crossing tasks. -/
inductive Bound where
  | sends
  | syncs
  deriving DecidableEq, Repr

/-- A value, by what a crossing check reads of it. -/
inductive CVal where
  /-- Plain data, or a frozen value: it crosses. -/
  | plain
  /-- A value that stays on one thread: a `*T` whose count is not
  atomic, a Cell of more than one word, a Signal. -/
  | stays (n : Nat)
  /-- A `Task[T]`. -/
  | handle (t : Nat)
  /-- An object's fields, or a list's elements: values at any depth. -/
  | pair (a b : CVal)
  /-- An API object hiding `v`, with the bound its braces and API name. -/
  | obj (b : Option Bound) (v : CVal)
  deriving Repr

/-- The values that stay on one thread a value holds. -/
def CVal.holds : CVal → Nat → Bool
  | .stays n, u => decide (u = n)
  | .pair a b, u => a.holds u || b.holds u
  | .obj _ v, u => v.holds u
  | _, _ => false

/-- The task handles a value holds. -/
def CVal.tasks : CVal → List Nat
  | .handle t => [t]
  | .pair a b => a.tasks ++ b.tasks
  | .obj _ v => v.tasks
  | _ => []

/-- Is there an API object, at any depth, that names no bound? -/
def CVal.bare : CVal → Bool
  | .pair a b => a.bare || b.bare
  | .obj none _ => true
  | .obj (some _) v => v.bare
  | _ => false

/-- What `crossingBlocker` finds nothing in: no value that stays on one
thread, and no object without a bound. -/
def CVal.Clear (v : CVal) : Prop := (∀ u, v.holds u = false) ∧ v.bare = false

/-- The check at erasure: no API object holds a task, and a bound it
names holds of the hidden value. -/
def EraseOk (b : Option Bound) (v : CVal) : Prop := v.tasks = [] ∧ (b.isSome → v.Clear)

/-- **Erasing keeps `holds`.** -/
@[simp] theorem holds_erase (b : Option Bound) (v : CVal) : (CVal.obj b v).holds = v.holds := by
  funext u; rfl

/-- Erasing keeps the handles a value holds. -/
@[simp] theorem tasks_erase (b : Option Bound) (v : CVal) : (CVal.obj b v).tasks = v.tasks := rfl

/-- Erasing with a bound keeps whether an object without one is inside. -/
@[simp] theorem bare_erase (b : Bound) (v : CVal) : (CVal.obj (some b) v).bare = v.bare := rfl

@[simp] theorem bare_unbound (v : CVal) : (CVal.obj none v).bare = true := rfl

/-! ## Spawns -/

/-- The values that stay on one thread that a spawn's arguments hold. -/
def argsHold (args : List CVal) (u : Nat) : Bool := args.any (·.holds u)

/-- The task handles a spawn's arguments hold. -/
def argsTasks (args : List CVal) : List Nat := args.flatMap (·.tasks)

/-- Is an object without a bound among a spawn's arguments? -/
def argsBare (args : List CVal) : Bool := args.any (·.bare)

/-- A spawn's arguments cross cores: they hold no value that stays on
one thread and no handle of a local task. -/
def Crosses (s : State) (args : List CVal) : Prop :=
  (∀ u, argsHold args u = false) ∧
    ∀ x ∈ argsTasks args, ∀ kx, s.task x = some kx → kx.localSpawn = false

/-- Task `t`, whose record is `k`, holds what the arguments hold: the
values that stay on one thread, and the handles. -/
def Owns (s : State) (t : Nat) (k : Task) (args : List CVal) : Prop :=
  (∀ u, argsHold args u = true → k.holds u = true) ∧ Holds s t fun x => decide (x ∈ argsTasks args)

/-- `f(args)&` by task `t`: free, on any core, when the arguments cross;
otherwise local, pinned with its maker. Either way, an argument holding
an object without a bound goes to no task. -/
inductive Spawn (s : State) (t : Nat) (args : List CVal) : State → Prop where
  | free (k : Task) (c : Nat) : s.task t = some k → argsBare args = false → Crosses s args →
      Spawn s t args ((s.hand (fun x _ => decide (x ∈ argsTasks args)) s.fresh).add
        ⟨some t, c, none, false, fun _ => false, false, false⟩)
  | pinned (k : Task) : s.task t = some k → argsBare args = false →
      Spawn s t args (((s.set t (some { k with home := some k.core })).hand
        (fun x _ => decide (x ∈ argsTasks args)) s.fresh).add
        ⟨some t, k.core, some k.core, true, argsHold args, false, false⟩)

/-- Every spawn of arguments a running task holds is a step of the task
machine: `spawnFree` or `spawnLocal`. -/
theorem spawn_step {s s' : State} {t : Nat} {k : Task} {args : List CVal}
    (ht : s.task t = some k) (hl : k.ended = false) (ho : Owns s t k args)
    (hs : Spawn s t args s') : Step s s' := by
  cases hs with
  | free k' c ht' _ hc =>
    rw [ht] at ht'; cases ht'
    exact Step.spawnFree s t k c _ ht hl ho.2
      (fun x kx hx hsel => hc.2 x (by simpa using hsel) kx hx)
  | pinned k' ht' _ =>
    rw [ht] at ht'; cases ht'
    exact Step.spawnLocal s t k _ _ ht hl ho.2 ho.1

/-- An object whose braces and API name no bound goes to no task. -/
theorem bare_no_spawn {s s' : State} {t : Nat} {args : List CVal} (h : argsBare args = true) :
    ¬ Spawn s t args s' := by
  intro hs
  cases hs <;> simp_all

/-- A spawn reads its arguments only through what they hold. -/
theorem Spawn.congr {s s' : State} {t : Nat} {a a' : List CVal}
    (hh : argsHold a = argsHold a') (ht : argsTasks a = argsTasks a')
    (hb : argsBare a = argsBare a') (hs : Spawn s t a s') : Spawn s t a' s' := by
  cases hs with
  | free k c hk hb' hc =>
    rw [ht]
    exact .free k c hk (hb ▸ hb') ⟨hh ▸ hc.1, ht ▸ hc.2⟩
  | pinned k hk hb' =>
    rw [ht, hh]
    exact .pinned k hk (hb ▸ hb')

/-! ## Erasure -/

theorem argsHold_erase (pre post : List CVal) (b : Option Bound) (v : CVal) :
    argsHold (pre ++ .obj b v :: post) = argsHold (pre ++ v :: post) := by
  funext u; simp [argsHold]

theorem argsTasks_erase (pre post : List CVal) (b : Option Bound) (v : CVal) :
    argsTasks (pre ++ .obj b v :: post) = argsTasks (pre ++ v :: post) := by
  simp [argsTasks]

theorem argsBare_erase (pre post : List CVal) (b : Bound) (v : CVal) :
    argsBare (pre ++ .obj (some b) v :: post) = argsBare (pre ++ v :: post) := by
  simp [argsBare]

theorem argsBare_unbound (pre post : List CVal) (v : CVal) :
    argsBare (pre ++ .obj none v :: post) = true := by
  simp [argsBare]

/-- **A value that may not cross before erasure may not cross after**,
and one that may, may: crossing reads the same facts of the object as
of the value it hides. -/
theorem crosses_erase (s : State) (pre post : List CVal) (b : Option Bound) (v : CVal) :
    Crosses s (pre ++ .obj b v :: post) ↔ Crosses s (pre ++ v :: post) := by
  simp only [Crosses, argsHold_erase, argsTasks_erase]

/-- A task holds an object's facts exactly when it holds its value's. -/
theorem owns_erase (s : State) (t : Nat) (k : Task) (pre post : List CVal) (b : Option Bound)
    (v : CVal) : Owns s t k (pre ++ .obj b v :: post) ↔ Owns s t k (pre ++ v :: post) := by
  simp only [Owns, argsHold_erase, argsTasks_erase]

/-- A spawn of an object with a bound is a spawn of the value it hides:
the same step, to the same state. -/
theorem spawn_erase {s s' : State} {t : Nat} {pre post : List CVal} {b : Bound} {v : CVal} :
    Spawn s t (pre ++ .obj (some b) v :: post) s' ↔ Spawn s t (pre ++ v :: post) s' :=
  ⟨Spawn.congr (argsHold_erase ..) (argsTasks_erase ..) (argsBare_erase ..),
    Spawn.congr (argsHold_erase ..).symm (argsTasks_erase ..).symm (argsBare_erase ..).symm⟩

/-- **Checking the bound at erasure suffices.** An object whose bound
was checked where it was erased holds nothing that stays on one thread
and no task, so it crosses, and a free spawn may take it. -/
theorem erase_sends {b : Bound} {v : CVal} (h : EraseOk (some b) v) (s : State) :
    Crosses s [.obj (some b) v] ∧ argsBare [.obj (some b) v] = false := by
  obtain ⟨ht, hc⟩ := h
  obtain ⟨hh, hb⟩ := hc rfl
  refine ⟨⟨fun u => by simp [argsHold, hh], fun x hx => ?_⟩, by simp [argsBare, hb]⟩
  simp [argsTasks, ht] at hx

/-- **Erasure keeps what crossing checks, so `confined` still holds.**
A running task of a reached state spawns arguments it holds, one of them
an erased value: the object names a bound, the spawn is the one the
value itself would make, the state it reaches is reached, and in it
two tasks holding one value that stays on one thread are pinned to one
core and run there (`confined`); `pin_kept` holds from it on. -/
theorem erase_confined {s s' : State} (h : Reach s) {t : Nat} {k : Task}
    (ht : s.task t = some k) (hl : k.ended = false) {pre post : List CVal} {b : Option Bound}
    {v : CVal} (ho : Owns s t k (pre ++ v :: post)) (hs : Spawn s t (pre ++ .obj b v :: post) s') :
    b.isSome ∧ Spawn s t (pre ++ v :: post) s' ∧ Reach s' ∧
      ∀ {a c u : Nat} {ka kc : Task}, a ≠ c → s'.task a = some ka → s'.task c = some kc →
        ka.holds u = true → kc.holds u = true →
        ∃ n, ka.home = some n ∧ kc.home = some n ∧ ka.core = n ∧ kc.core = n := by
  cases b with
  | none => exact absurd hs (bare_no_spawn (argsBare_unbound pre post v))
  | some b =>
    have hv := spawn_erase.1 hs
    have hr : Reach s' := .step h (spawn_step ht hl ho hv)
    exact ⟨rfl, hv, hr, fun hac ha hc hua huc => confined hr hac ha hc hua huc⟩

-- The proofs assume nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.Tasks.erase_confined' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms erase_confined

/-- info: 'LambdaRig.Tasks.crosses_erase' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms crosses_erase

/-- info: 'LambdaRig.Tasks.erase_sends' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms erase_sends

/-! ## Examples -/

/-- `^{Job + Sends}` of plain data passes the check at erasure; one of a
`*T` whose count is not atomic does not. -/
example : EraseOk (some .sends) (.pair .plain .plain) := by
  simp [EraseOk, CVal.Clear, CVal.tasks, CVal.holds, CVal.bare]

example : ¬ EraseOk (some .sends) (.stays 7) := by
  simp [EraseOk, CVal.Clear, CVal.holds]

/-- No API object holds a task. -/
example : ¬ EraseOk none (.handle 1) := by simp [EraseOk, CVal.tasks]

/-- `main` gives a `^{Job + Sends}` to a free task: a reached state. -/
theorem sendsJob : ∃ s', Spawn State.init 0 [.obj (some .sends) .plain] s' ∧ Reach s' := by
  have hok : EraseOk (some .sends) CVal.plain := by
    simp [EraseOk, CVal.Clear, CVal.tasks, CVal.holds, CVal.bare]
  obtain ⟨hc, hb⟩ := erase_sends hok State.init
  have ht : State.init.task 0 = some main := rfl
  have hs := Spawn.free (args := [.obj (some .sends) .plain]) main 1 ht hb hc
  refine ⟨_, hs, .step .init (spawn_step ht rfl ⟨fun u h => ?_, fun x h => ?_⟩ hs)⟩
  · simp [argsHold, CVal.holds] at h
  · simp [argsTasks, CVal.tasks] at h

/-- `main` holds a `*T` (value 7) and erases it to a `^{Shape}`, naming
no bound: no spawn takes it, a local one included. -/
example (s' : State) : ¬ Spawn mainMakes 0 [.obj none (.stays 7)] s' :=
  bare_no_spawn (by simp [argsBare])

end LambdaRig.Tasks
