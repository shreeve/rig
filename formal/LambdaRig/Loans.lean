/-
CORE sentence 5, on the machine: a place has any number of read loans,
or one write loan, never both.

The first part is about one cell: each of the five ways to touch it
leaves it well formed, and the lends end the loans the Core says they
end. The second part lifts that to the whole machine: every cell of
every state the interpreter reaches is well formed.
-/
import LambdaRig.Interp

namespace LambdaRig

/-! ## One cell -/

theorem Cell.fresh_wf (v : Val) : (Cell.fresh v).WF := Or.inl rfl
theorem Cell.lendRead_wf (c : Cell) (t : Tag) : (c.lendRead t).WF := Or.inl rfl
theorem Cell.lendWrite_wf (c : Cell) (t : Tag) : (c.lendWrite t).WF := Or.inr rfl
theorem Cell.ownerRead_wf (c : Cell) : c.ownerRead.WF := Or.inl rfl
theorem Cell.ownerWrite_wf (c : Cell) (v : Option Val) : (c.ownerWrite v).WF := Or.inl rfl
theorem Cell.viewWrite_wf (c : Cell) (v : Val) : (c.viewWrite v).WF := Or.inr rfl

/-- `!x` ends every loan but its own. -/
theorem Cell.lendWrite_ends (c : Cell) (t t' : Tag) (h : t' ≠ t) :
    (c.lendWrite t).live .read t' = false ∧ (c.lendWrite t).live .write t' = false := by
  simp [Cell.lendWrite, Cell.live, Ne.symm h]

/-- `?x` ends a write loan and keeps every read loan. -/
theorem Cell.lendRead_ends (c : Cell) (t t' : Tag) :
    (c.lendRead t).live .write t' = false ∧
    (c.live .read t' = true → (c.lendRead t).live .read t' = true) := by
  refine ⟨by simp [Cell.lendRead, Cell.live], ?_⟩
  intro h
  simp_all [Cell.lendRead, Cell.live]

/-- Writing, moving out of, or dropping a place ends every loan on it. -/
theorem Cell.ownerWrite_ends (c : Cell) (v : Option Val) (m : Mode) (t : Tag) :
    (c.ownerWrite v).live m t = false := by
  cases m <;> simp [Cell.ownerWrite, Cell.live]

/-- A read by the owner ends a write loan. -/
theorem Cell.ownerRead_ends (c : Cell) (t : Tag) : c.ownerRead.live .write t = false := by
  simp [Cell.ownerRead, Cell.live]

/-! ## The whole machine -/

/-- Every cell of the machine is well formed. -/
def Machine.WF (s : Machine) : Prop := ∀ l c, s.heap l = some c → c.WF

/-- `m` keeps the machine well formed whenever it succeeds. -/
def Keeps (m : M α) : Prop :=
  ∀ s a s', s.WF → m.run s = .ok (a, s') → s'.WF

theorem Keeps.pure (a : α) : Keeps (Pure.pure a : M α) := by
  intro s b s' hs h
  simp only [StateT.run_pure] at h
  obtain ⟨-, rfl⟩ := h
  exact hs

theorem Keeps.throw (f : Fault) : Keeps (MonadExcept.throw f : M α) := by
  intro s a s' _ h
  simp [StateT.run] at h
  cases h

theorem Keeps.bind {m : M α} {k : α → M β} (hm : Keeps m) (hk : ∀ a, Keeps (k a)) :
    Keeps (m >>= k) := by
  intro s b s' hs h
  rw [StateT.run_bind] at h
  cases hr : m.run s with
  | error e => rw [hr] at h; cases h
  | ok r =>
    rw [hr] at h
    exact hk r.1 r.2 b s' (hm s r.1 r.2 hs hr) h

theorem Keeps.map {m : M α} (f : α → β) (hm : Keeps m) : Keeps (f <$> m) := by
  rw [map_eq_pure_bind]
  exact Keeps.bind hm fun _ => Keeps.pure _

theorem Keeps.get : Keeps (MonadState.get : M Machine) := by
  intro s a s' hs h
  simp only [StateT.run_get] at h
  obtain ⟨-, rfl⟩ := h
  exact hs

theorem Keeps.modify (f : Machine → Machine) (hf : ∀ s, s.WF → (f s).WF) :
    Keeps (_root_.modify f : M PUnit) := by
  intro s a s' hs h
  simp only [StateT.run_modify] at h
  obtain ⟨-, rfl⟩ := h
  exact hf s hs

theorem Keeps.fresh : Keeps fresh := by
  intro s a s' hs h
  simp only [LambdaRig.fresh, StateT.run_bind, StateT.run_get, pure_bind, StateT.run_set,
    StateT.run_pure] at h
  obtain ⟨-, rfl⟩ := h
  exact hs

/-- Replacing a cell with a well-formed one. -/
theorem Keeps.setCell (l : Loc) (c : Cell) (hc : c.WF) : Keeps (setCell l c) := by
  intro s a s' hs h
  simp only [LambdaRig.setCell, StateT.run_bind, StateT.run_get, pure_bind] at h
  split at h
  · simp only [StateT.run_set] at h
    obtain ⟨-, rfl⟩ := h
    intro l' c' hl
    simp only [upd] at hl
    split at hl
    · cases hl; exact hc
    · exact hs l' c' hl
  · simp [StateT.run] at h
    cases h

theorem Keeps.free (l : Loc) : Keeps (free l) := by
  intro s a s' hs h
  simp only [LambdaRig.free, StateT.run_bind, StateT.run_get, pure_bind] at h
  split at h
  · simp only [StateT.run_set] at h
    obtain ⟨-, rfl⟩ := h
    intro l' c' hl
    simp only [upd] at hl
    split at hl
    · cases hl
    · exact hs l' c' hl
  · simp [StateT.run] at h
    cases h

/- From here on `Keeps` is opaque, so the tactics below apply the lemmas
above instead of unfolding it. -/
attribute [irreducible] Keeps

/-- Apply the `Keeps` lemmas through a `do` block. -/
syntax "keeps" : tactic
macro_rules
  | `(tactic| keeps) => `(tactic| repeat' (first
      | intro _
      | assumption
      | exact Keeps.pure _
      | exact Keeps.throw _
      | exact Keeps.get
      | exact Keeps.fresh
      | exact Keeps.free _
      | exact Keeps.modify _ (fun _ h => h)
      | apply Keeps.map
      | apply Keeps.setCell
      | apply Keeps.bind
      | split
      | simp [Cell.WF, Cell.fresh, Cell.ownerRead, Cell.ownerWrite, Cell.lendRead,
          Cell.lendWrite, Cell.viewWrite] <;> done))

theorem Keeps.cell (l : Loc) : Keeps (cell l) := by unfold LambdaRig.cell; keeps

theorem Keeps.alloc (v : Val) : Keeps (alloc v) := by
  unfold LambdaRig.alloc
  apply Keeps.bind Keeps.fresh
  intro l
  apply Keeps.bind _ fun _ => Keeps.pure _
  apply Keeps.modify
  intro s hs l' c' hl
  simp only [upd] at hl
  split at hl
  · cases hl; exact Cell.fresh_wf v
  · exact hs l' c' hl

theorem Keeps.slotOf (x : Var) : Keeps (slotOf x) := by unfold LambdaRig.slotOf; keeps

theorem Keeps.dropVal (v : Val) : Keeps (dropVal v) := by
  unfold LambdaRig.dropVal; split <;> keeps

theorem Keeps.readBox (b : Loc) : Keeps (readBox b) := by
  unfold LambdaRig.readBox
  apply Keeps.bind (Keeps.cell b)
  keeps

theorem Keeps.seen (m : Mode) (l : Loc) (t : Tag) : Keeps (seen m l t) := by
  unfold LambdaRig.seen
  apply Keeps.bind (Keeps.cell l)
  keeps

theorem Keeps.deref (m : Mode) (l : Loc) (t : Tag) : Keeps (deref m l t) := by
  unfold LambdaRig.deref
  apply Keeps.bind (Keeps.seen m l t)
  intro v; split <;> first | exact Keeps.readBox _ | keeps

theorem Keeps.held (x : Var) : Keeps (held x) := by
  unfold LambdaRig.held
  apply Keeps.bind (Keeps.slotOf x); intro l
  apply Keeps.bind (Keeps.cell l)
  keeps


theorem Keeps.intOf (v : Val) : Keeps (intOf v) := by
  unfold LambdaRig.intOf; split <;> first | exact Keeps.deref _ _ _ | keeps

theorem Keeps.copyOf (v : Val) : Keeps (copyOf v) := by
  unfold LambdaRig.copyOf; split
  · keeps
  · apply Keeps.bind (Keeps.readBox _); intro n
    apply Keeps.bind (Keeps.alloc _); intro _
    exact Keeps.pure _
  · keeps

/-- `keeps`, also through the interpreter's helpers. -/
syntax "keeps_all" : tactic
macro_rules
  | `(tactic| keeps_all) => `(tactic| repeat' (first
      | intro _
      | assumption
      | exact Keeps.pure _
      | exact Keeps.throw _
      | exact Keeps.get
      | exact Keeps.fresh
      | exact Keeps.free _
      | exact Keeps.cell _
      | exact Keeps.alloc _
      | exact Keeps.slotOf _
      | exact Keeps.dropVal _
      | exact Keeps.deref _ _ _
      | exact Keeps.held _
      | exact Keeps.readBox _
      | exact Keeps.intOf _
      | exact Keeps.seen _ _ _
      | exact Keeps.copyOf _
      | exact Keeps.modify _ (fun _ h => h)
      | apply Keeps.map
      | apply Keeps.setCell
      | apply Keeps.bind
      | split
      | simp [Cell.WF, Cell.fresh, Cell.ownerRead, Cell.ownerWrite, Cell.lendRead,
          Cell.lendWrite, Cell.viewWrite] <;> done))

/-- The interpreter keeps every cell well formed: whatever a program
does, no place ever holds read loans and a write loan at once. -/
theorem Keeps.eval (e : Expr) : Keeps (eval e) := by
  induction e <;> unfold LambdaRig.eval <;> keeps_all

end LambdaRig
