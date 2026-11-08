/-
λRig: loans lent to a task, held for its whole life.

`t = g(?y)&` lends `y` to a task, which runs beside the statements that
follow it in `t`'s scope and is waited for where that scope ends
(docs/design/concurrency.md, "Loans and structure": "A task keeps the
loans of its arguments until it ends: `score(?d)&` lends `d` to read for
the task's whole life"; "A task's drop uses its loans ... `Task` counts
as having one"; "Dropping a set cancels every task first, then waits for
them all"). What the task does with its view, it may do at any moment
between the spawn and the wait, any number of times, or never, if it is
canceled first.

λRig runs one thing at a time, so a task is modelled by where its
action stands. `spawn` puts it at the end of the scope, where the task
is waited for: that is the program the checker reads, and the one that
keeps the task's view used for the whole scope (CORE sentence 6: a loan
lasts until the last use of every view that carries it, and a task's
drop is such a use). `spawnAt` puts it at the moments `runs` picks,
before any statement of the scope, after the last, at several, or at
none. The result, `spawn_any_moment`: if the checker accepts the task
waited for at its scope's end, it accepts it run at any moments, with
the same type and moves, so by `sound` the program runs without a fault
whichever moments the task runs at. No statement beside the task ends
its loan: none writes, moves, or drops an owner it reads, and none
touches an owner it writes.

The moments are the points between the statements of the task's scope,
each statement taken whole; the task's action is one read or one write
through its view. The step is `check_mono` (LambdaRig/Mono.lean): a
program `check` accepts with some names used later it accepts with
fewer, since `allows` only forbids.
-/
import LambdaRig.Mono

namespace LambdaRig

/-! ## A task beside its scope -/

/-- What a task does with the view it was lent, each time it runs: it
reads through a read view (`print(t)`) and writes through a write view
(`t = t + 1`). -/
def act : Mode → Var → Expr
  | .read, t => .out (.name t)
  | .write, t => .assign t (.add (.name t) (.lit 1))

/-- Statements in order, then `fin`. -/
def seqs : List Expr → Expr → Expr
  | [], fin => fin
  | s :: ss, fin => .seq s (seqs ss fin)

/-- The statements `ss`, with the task's action `a` before statement `i`
when `runs i`, and after the last when `runs ss.length`. -/
def weave (a : Expr) : List Expr → (Nat → Bool) → Expr
  | [], runs => if runs 0 then .seq a (.lit 0) else .lit 0
  | s :: ss, runs =>
    if runs 0 then .seq a (.seq s (weave a ss fun i => runs (i + 1)))
    else .seq s (weave a ss fun i => runs (i + 1))

/-- `t = g(?y)&` (or `g(!y)&`), then the statements `ss`, the rest of
`t`'s scope, where the task is waited for: the program the checker
reads, with the task's action after the last statement, since its drop
uses its loan (concurrency.md, "Loans and structure", rule 1). The
statements do not name the task's view: the handle `t` is not a view. -/
def spawn (t : Var) (m : Mode) (y : Var) (ss : List Expr) : Expr :=
  .letIn t (.lend m y) (seqs ss (.seq (act m t) (.lit 0)))

/-- The same task, run at the moments `runs` picks: any number of
times, at any statement, or never. -/
def spawnAt (t : Var) (m : Mode) (y : Var) (ss : List Expr) (runs : Nat → Bool) : Expr :=
  .letIn t (.lend m y) (weave (act m t) ss runs)

theorem fv_seqs (ss : List Expr) (fin : Expr) (v : Var) :
    v ∈ fv (seqs ss fin) ↔ (∃ s ∈ ss, v ∈ fv s) ∨ v ∈ fv fin := by
  induction ss with
  | nil => simp [seqs]
  | cons s ss ih => simp [seqs, fv, ih, or_assoc]

theorem fv_weave (a : Expr) (ss : List Expr) : ∀ (runs : Nat → Bool) (v : Var),
    v ∈ fv (weave a ss runs) → (∃ s ∈ ss, v ∈ fv s) ∨ v ∈ fv a := by
  induction ss with
  | nil =>
    intro runs v h
    simp only [weave] at h
    split at h <;> simp_all [fv]
  | cons s ss ih =>
    intro runs v h
    have hw : v ∈ fv (weave a ss fun i => runs (i + 1)) → (∃ s' ∈ s :: ss, v ∈ fv s') ∨ v ∈ fv a :=
      fun hv => (ih _ v hv).imp (fun ⟨s', hs', h'⟩ => ⟨s', List.mem_cons_of_mem _ hs', h'⟩) id
    simp only [weave] at h
    split at h
    · simp only [fv, List.mem_append] at h
      rcases h with h | h | h
      · exact Or.inr h
      · exact Or.inl ⟨s, by simp, h⟩
      · exact hw h
    · simp only [fv, List.mem_append] at h
      rcases h with h | h
      · exact Or.inl ⟨s, by simp, h⟩
      · exact hw h

/-- The checker's view of the statements beside a task: if it accepts
them with the task's action after the last, it accepts them with the
action at any moments, given that the action checks, moving nothing,
wherever the names used later are among `P`'s. -/
theorem weave_check {Γ : Ctx} {L : List Var} {a : Expr} {t : Var} {P : Var → Prop}
    (hact : ∀ M L0, t ∉ M → (∀ v ∈ L0, P v) → check Γ M L0 a = some (.unit, M)) :
    ∀ (ss : List Expr) (runs : Nat → Bool) {M r},
      (∀ v, v ∈ fv a ∨ (∃ s ∈ ss, v ∈ fv s) ∨ v ∈ L → P v) →
      (∀ s ∈ ss, t ∉ fv s) → t ∉ M →
      check Γ M L (seqs ss (.seq a (.lit 0))) = some r →
      check Γ M L (weave a ss runs) = some r := by
  intro ss
  induction ss with
  | nil =>
    intro runs M r hP _ htM h
    have ha := hact M L htM (fun v hv => hP v (Or.inr (Or.inr hv)))
    simp only [seqs, check_seq_eq, fv, List.nil_append, ha] at h
    simp only [weave]
    split
    · simp only [check_seq_eq, fv, List.nil_append, ha]; exact h
    · exact h
  | cons s ss ih =>
    intro runs M r hP hts htM h
    simp only [seqs, check_seq_eq] at h
    cases h1 : check Γ M (fv (seqs ss (.seq a (.lit 0))) ++ L) s with
    | none => rw [h1] at h; exact absurd h (by simp)
    | some p =>
      obtain ⟨τ1, M1⟩ := p
      rw [h1] at h
      have hM1 : t ∉ M1 := check_moved_fv s h1 htM (hts s (by simp))
      have ih' := ih (fun i => runs (i + 1)) (r := r)
        (fun v hv => hP v (by
          rcases hv with hv | ⟨s', hs', hv⟩ | hv
          · exact Or.inl hv
          · exact Or.inr (Or.inl ⟨s', List.mem_cons_of_mem _ hs', hv⟩)
          · exact Or.inr (Or.inr hv)))
        (fun s' hs' => hts s' (List.mem_cons_of_mem _ hs')) hM1 h
      have hs' : check Γ M (fv (weave a ss fun i => runs (i + 1)) ++ L) s = some (τ1, M1) := by
        refine check_mono s h1 fun v hv => ?_
        simp only [List.mem_append] at hv ⊢
        rcases hv with hv | hv
        · refine Or.inl ((fv_seqs _ _ v).2 ?_)
          rcases fv_weave a ss _ v hv with hv | hv
          · exact Or.inl hv
          · exact Or.inr (by simp [fv, hv])
        · exact Or.inr hv
      have hrest : check Γ M L (.seq s (weave a ss fun i => runs (i + 1))) = some r := by
        rw [check_seq_eq, hs']; exact ih'
      simp only [weave]
      split
      · rw [check_seq_eq, hact M _ htM ?_]
        · exact hrest
        · intro v hv
          simp only [fv, List.mem_append] at hv
          rcases hv with (hv | hv) | hv
          · exact hP v (Or.inr (Or.inl ⟨s, by simp, hv⟩))
          · rcases fv_weave a ss _ v hv with ⟨s', hs', hv⟩ | hv
            · exact hP v (Or.inr (Or.inl ⟨s', List.mem_cons_of_mem _ hs', hv⟩))
            · exact hP v (Or.inl hv)
          · exact hP v (Or.inr (Or.inr hv))
      · exact hrest

theorem check_letIn_eq (Γ : Ctx) (M L : List Var) (x : Var) (e body : Expr) :
    check Γ M L (.letIn x e body) = (do
      guard ((Γ.lookup x).isNone && !M.contains x)
      let (τe, moved) ← check Γ M ((fv body).filter (· ≠ x) ++ L) e
      let (τ, moved) ← check ((x, τe) :: Γ) moved L body
      guard (!τ.lentFrom x)
      some (τ, moved.filter (· ≠ x))) := by
  simp only [check]

/-- A write view's write through `y` is allowed beside a task holding
`!y` when no other view of `y` is used: the task's lend checked that. -/
theorem allows_through_task {Γ : Ctx} {y t : Var} {L0 Ls : List Var}
    (hw : allows Γ y .write Ls = true) (ht : Γ.lookup t = none)
    (hL : ∀ v ∈ L0, v = t ∨ v ∈ Ls) :
    allows ((t, .view .write y) :: Γ) y .through L0 = true := by
  unfold allows at hw ⊢
  rw [List.all_eq_true] at hw
  rw [List.all_cons, Bool.and_eq_true]
  refine ⟨by simp [Access.ends], List.all_eq_true.2 fun p hp => ?_⟩
  obtain ⟨z, τ⟩ := p
  have hz := hw (z, τ) hp
  cases τ with
  | view m' y' =>
    simp only at hz ⊢
    cases hy : (y' == y)
    · simp
    · cases hc : L0.contains z
      · simp
      · exfalso
        have hz0 : z ∈ L0 := by simpa using hc
        rcases hL z hz0 with rfl | hzs
        · exact not_mem_of_lookup_none ht hp
        · simp [hy, Access.ends] at hz
          exact hz hzs
  | _ => rfl

theorem check_seqs_fin {Γ : Ctx} {L : List Var} {fin : Expr} :
    ∀ (ss : List Expr) {M r}, check Γ M L (seqs ss fin) = some r → ∃ M', check Γ M' L fin = some r := by
  intro ss
  induction ss with
  | nil => intro M r h; exact ⟨M, h⟩
  | cons s ss ih =>
    intro M r h
    simp only [seqs, check_seq_eq] at h
    cases h1 : check Γ M (fv (seqs ss fin) ++ L) s with
    | none => rw [h1] at h; exact absurd h (by simp)
    | some p => rw [h1] at h; exact ih h

/-- **A task may run at any moment of its scope.** If the checker
accepts `t = g(?y)&` or `t = g(!y)&`, waited for where its scope ends,
it accepts the task run at any moments `runs` picks, with the same type
and moves. So no statement beside the task ends its loan: none writes,
moves, or drops `y` while a task reads it, and none touches `y` while a
task writes it (concurrency.md, "Loans and structure": "A task keeps
the loans of its arguments until it ends"). -/
theorem spawn_any_moment {Γ : Ctx} {M L : List Var} {t : Var} {m : Mode} {y : Var}
    {ss : List Expr} {r : Ty × List Var} (ht : ∀ s ∈ ss, t ∉ fv s)
    (h : check Γ M L (spawn t m y ss) = some r) (runs : Nat → Bool) :
    check Γ M L (spawnAt t m y ss runs) = some r := by
  let body := seqs ss (.seq (act m t) (.lit 0))
  let Ls := (fv body).filter (· ≠ t) ++ L
  have hsub : ∀ v ∈ (fv (weave (act m t) ss runs)).filter (· ≠ t) ++ L, v ∈ Ls := by
    intro v hv
    simp only [Ls, List.mem_append, List.mem_filter] at hv ⊢
    rcases hv with ⟨hv, hvt⟩ | hv
    · refine Or.inl ⟨(fv_seqs _ _ v).2 ?_, hvt⟩
      rcases fv_weave _ ss runs v hv with hv | hv
      · exact Or.inl hv
      · exact Or.inr (by simp [fv, hv])
    · exact Or.inr hv
  simp only [spawn, spawnAt] at h ⊢
  rw [check_letIn_eq] at h ⊢
  simp only [Option.bind_eq_bind, guard_bind_some] at h
  obtain ⟨hg, h⟩ := h
  simp only [Option.bind_eq_some_iff] at h
  obtain ⟨⟨τe, M1⟩, hl, h⟩ := h
  simp only at h
  obtain ⟨⟨τb, Mb⟩, hb, h⟩ := h
  simp only [Option.some.injEq] at h
  obtain ⟨_, hlt, rfl⟩ := h
  have hg' := hg
  simp only [Bool.and_eq_true, Option.isNone_iff_eq_none, Bool.not_eq_true'] at hg'
  obtain ⟨htΓ, htM⟩ := hg'
  have htM : t ∉ M := by simpa using htM
  have hl' := hl
  simp only [check] at hl'
  cases hy : Γ.lookup y with
  | none => simp [hy] at hl'
  | some τy =>
    simp [hy] at hl'
    obtain ⟨⟨hyM, hyo⟩, hall, rfl, rfl⟩ := hl'
    have hyt : y ≠ t := by rintro rfl; rw [htΓ] at hy; cases hy
    have hw := weave_check (Γ := (t, .view m y) :: Γ) (L := L) (a := act m t) (t := t)
      (P := fun v => v = t ∨ v ∈ Ls) ?_ ss runs (fun v hv => ?_) ht htM hb
    · rw [check_mono (.lend m y) hl hsub]
      simp [hw]
      refine ⟨⟨fun a b hab hta => not_mem_of_lookup_none (b := b) htΓ (by subst hta; exact hab), htM⟩, ?_⟩
      cases h' : τb.lentFrom t
      · rfl
      · simp [h', guard] at hlt
    · intro M0 L0 htM0 hL0
      cases m with
      | read =>
        simp [act, check, htM0, guard]
      | write =>
        obtain ⟨Mn, hfin⟩ := check_seqs_fin ss hb
        rw [check_seq_eq] at hfin
        have hyint : Γ.lookup y = some .int := by
          cases hf : check ((t, .view .write y) :: Γ) Mn (fv (Expr.lit 0) ++ L) (act .write t) with
          | none => rw [hf] at hfin; exact absurd hfin (by simp)
          | some _ =>
            simp only [act, check, lookup_cons_self] at hf
            rw [hy]
            cases τy with
            | int => rfl
            | box => simp [lookup_cons_other hyt, hy, guard, failure] at hf
            | _ => simp [Ty.owner] at hyo
        have hthr := allows_through_task (L0 := L0) hall htΓ hL0
        simp [act, check, lookup_cons_other hyt, hyint, htM0, hthr,
          Ty.readsInt, guard]
    · simp only [Ls, List.mem_append, List.mem_filter]
      rcases hv with hv | ⟨s, hs, hv⟩ | hv
      · left; cases m <;> simp [act, fv] at hv <;> exact hv
      · by_cases hvt : v = t
        · exact Or.inl hvt
        · exact Or.inr (Or.inl ⟨(fv_seqs _ _ v).2 (Or.inl ⟨s, hs, hv⟩), by simp [hvt]⟩)
      · exact Or.inr (Or.inr hv)

theorem fv_spawnAt {t : Var} {m : Mode} {y : Var} {ss : List Expr} {runs : Nat → Bool} (v : Var)
    (h : v ∈ fv (spawnAt t m y ss runs)) : v ∈ fv (spawn t m y ss) := by
  simp only [spawn, spawnAt, fv, List.mem_append, List.mem_filter] at h ⊢
  rcases h with h | ⟨h, ht⟩
  · exact Or.inl h
  · refine Or.inr ⟨(fv_seqs _ _ v).2 ?_, ht⟩
    rcases fv_weave _ ss runs v h with h | h
    · exact Or.inl h
    · exact Or.inr (by simp [fv, h])

/-- **A task's loan is live whenever it runs.** Run from any machine
that matches the checker's facts, a task the checker accepts, run at
any moments of its scope, runs without a fault, and leaves the facts
the checker gives its scope's end (`sound`). -/
theorem task_runs {Γ : Ctx} {M L : List Var} {t : Var} {m : Mode} {y : Var} {ss : List Expr}
    {τ : Ty} {M' : List Var} (ht : ∀ s ∈ ss, t ∉ fv s)
    (h : check Γ M L (spawn t m y ss) = some (τ, M')) (runs : Nat → Bool)
    {σ β : Var → Loc} {s : Machine} (r : Rel Γ M (fv (spawn t m y ss) ++ L) σ β s []) :
    ∃ v s' β', (eval (spawnAt t m y ss runs)).run s = .ok (v, s') ∧
      Rel Γ M' L σ β' s' (owned v) ∧ VFits Γ M' σ β' s' τ v :=
  sound _ Γ M L τ M' σ β s (spawn_any_moment ht h runs) (r.mono fun v hv => by
    simp only [List.mem_append] at hv ⊢
    exact hv.imp (fv_spawnAt v) id)

/-- The owner `y = e`, then a task given `?y` or `!y` and the statements
beside it: if the checker accepts it, it runs to the end without a
fault, whichever moments the task runs at. -/
theorem owner_task_runs {y t : Var} {e : Expr} {m : Mode} {ss : List Expr}
    (ht : ∀ s ∈ ss, t ∉ fv s) (h : accepts (.letIn y e (spawn t m y ss)) = true)
    (runs : Nat → Bool) : ∃ out, run (.letIn y e (spawnAt t m y ss runs)) = .ok out := by
  refine accepts_runs _ ?_
  obtain ⟨r, hc⟩ := Option.isSome_iff_exists.1 h
  simp only [accepts]
  refine Option.isSome_iff_exists.2 ⟨r, ?_⟩
  simp only [check] at hc ⊢
  refine obind_congr hc fun _ hc => ?_
  refine obind_src (obind_congr hc fun p hp => ?_) fun p hp => check_mono e hp ?_
  · obtain ⟨τe, Me⟩ := p
    simp only at hp ⊢
    exact obind_src hp fun _ h2 => spawn_any_moment ht h2 runs
  · intro v hv
    simp only [List.mem_append, List.mem_filter] at hv ⊢
    exact hv.imp (fun ⟨h1, h2⟩ => ⟨fv_spawnAt v h1, h2⟩) id

-- The proofs assume nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.task_runs' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms task_runs

/-- info: 'LambdaRig.owner_task_runs' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms owner_task_runs

/-! ### Examples -/

namespace TaskLoans
open Expr

/-- At every moment. -/
def always : Nat → Bool := fun _ => true

/-- `y = ^1`, `t = show(?y)&`, `print(?y)`: the owner reads beside a task
that reads. -/
def readBeside : Expr := letIn "y" (box (lit 1)) (spawn "t" .read "y" [out (lend .read "y")])

#guard accepts readBeside

/-- info: LambdaRig.Outcome.ok [1, 1, 1] -/
#guard_msgs in #eval run (letIn "y" (box (lit 1)) (spawnAt "t" .read "y" [out (lend .read "y")] always))

/-- Rejected: `y = 1`, `t = show(?y)&`, `y = 5`: the owner writes while
the task reads. -/
def writeBeside : Expr := letIn "y" (lit 1) (spawn "t" .read "y" [assign "y" (lit 5)])

#guard !accepts writeBeside

/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.deadTag 1) -/
#guard_msgs in #eval run writeBeside

/-- Rejected: `y = ^1`, `t = show(?y)&`, `<y`: the owner drops while the
task reads; the task outlives no frame it views. -/
def dropBeside : Expr := letIn "y" (box (lit 1)) (spawn "t" .read "y" [drop "y"])

#guard !accepts dropBeside

/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.deadTag 2) -/
#guard_msgs in #eval run dropBeside

/-- `y = 1`, `t = bump(!y)&`, waited for, then `print(y)`. -/
def writeThenRead : Expr := letIn "y" (lit 1) (seq (spawn "t" .write "y" []) (out (name "y")))

#guard accepts writeThenRead

/-- info: LambdaRig.Outcome.ok [2] -/
#guard_msgs in #eval run writeThenRead

/-- Rejected: `y = 1`, `t = bump(!y)&`, `print(y)`: the owner reads while
the task writes. -/
def readWhileWrite : Expr := letIn "y" (lit 1) (spawn "t" .write "y" [out (name "y")])

#guard !accepts readWhileWrite

/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.deadTag 1) -/
#guard_msgs in #eval run readWhileWrite

end TaskLoans

end LambdaRig
