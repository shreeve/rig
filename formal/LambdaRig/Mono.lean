/-
λRig: what `check` needs of the names used later, and what it moves.

`check_mono`: a program `check` accepts with some names used after it,
it accepts with fewer, with the same type and moves, since `allows` only
forbids an access while a view is used later. `check_moved_fv`: a name a
program does not use, it does not move. LambdaRig/TaskLoans.lean and
LambdaRig/Temps.lean build on both.
-/
import LambdaRig.Calls

namespace LambdaRig

/-! ## Fewer names used later forbid less -/

theorem allows_mono {Γ : Ctx} {y : Var} {k : Access} {L L' : List Var}
    (h : allows Γ y k L = true) (hs : ∀ v ∈ L', v ∈ L) : allows Γ y k L' = true := by
  unfold allows at h ⊢
  rw [List.all_eq_true] at h ⊢
  intro p hp
  have hp' := h p hp
  obtain ⟨v, τ⟩ := p
  cases τ with
  | view m y' =>
    cases h2 : L'.contains v
    · have h4 : v ∉ L' := by simpa using h2
      simp [h4]
    · have h3 : L.contains v = true := by
        simp only [List.contains_iff_mem] at h2 ⊢; exact hs v h2
      simp only [h3, h2] at hp' ⊢
      exact hp'
  | _ => rfl

/-- **Fewer names used later forbid less.** A program `check` accepts
with the names `L` used after it, it accepts, with the same type and
moves, with any names `L'` among them. -/
theorem check_mono (e : Expr) : ∀ {Γ M L L' r}, check Γ M L e = some r → (∀ v ∈ L', v ∈ L) →
    check Γ M L' e = some r := by
  induction e with
  | lit => intro _ _ _ _ _ h _; exact h
  | name x | move x | drop x | clone x =>
    intro Γ M L L' r h hs
    have k1 := allows_mono (Γ := Γ) (y := x) (k := .read) (L' := L') (L := L)
    have k2 := allows_mono (Γ := Γ) (y := x) (k := .write) (L' := L') (L := L)
    cases hx : Γ.lookup x with
    | none => simp [check, hx] at h
    | some τx =>
      cases ha : allows Γ x .read L <;> cases hb : allows Γ x .write L <;>
        cases τx with
        | view m y => cases m <;> simp_all [check]
        | _ => simp_all [check]
  | lend m x =>
    intro Γ M L L' r h hs
    have k1 := allows_mono (Γ := Γ) (y := x) (k := .read) (L' := L') (L := L)
    have k2 := allows_mono (Γ := Γ) (y := x) (k := .write) (L' := L') (L := L)
    cases hx : Γ.lookup x with
    | none => simp [check, hx] at h
    | some τx =>
      cases ha : allows Γ x .read L <;> cases hb : allows Γ x .write L <;>
        cases m <;> simp_all [check]
  | box e ih | out e ih =>
    intro Γ M L L' r h hs
    simp only [check] at h ⊢
    exact obind_src h fun a ha => ih ha hs
  | assign x e ih =>
    intro Γ M L L' r h hs
    have key : ∀ y k, allows Γ y k L = true → allows Γ y k L' = true :=
      fun _ _ hy => allows_mono hy hs
    simp only [check] at h ⊢
    refine obind_src (obind_congr h fun a ha => ?_) fun a ha => ih ha (by simpa using fun v hv => Or.inr (hs v hv))
    obtain ⟨τe, M1⟩ := a
    cases hx : Γ.lookup x with
    | none => simp [hx] at ha
    | some τx =>
      cases τx with
      | view m y => cases m <;> simp_all
      | _ => simp_all
  | add a b iha ihb | seq a b iha ihb =>
    intro Γ M L L' r h hs
    simp only [check] at h ⊢
    refine obind_src (obind_congr h fun p hp => ?_) fun p hp => iha hp (by
      intro v hv; simp only [List.mem_append] at hv ⊢; exact hv.imp id (hs v))
    obtain ⟨τa, M1⟩ := p
    try simp only at hp ⊢
    cases hb : check Γ M1 L b with
    | none => rw [hb] at hp; exact absurd hp (by simp)
    | some q => rw [hb] at hp; rw [ihb hb hs]; exact hp
  | letIn x e body ihe ihb =>
    intro Γ M L L' r h hs
    simp only [check] at h ⊢
    refine obind_congr h fun _ h => ?_
    refine obind_src (obind_congr h fun p hp => ?_) fun p hp => ihe hp (by
      intro v hv; simp only [List.mem_append] at hv ⊢; exact hv.imp id (hs v))
    obtain ⟨τe, M1⟩ := p
    try simp only at hp ⊢
    exact obind_src hp fun q hq => ihb hq hs

/-- Equal sets of names used later give the same check. -/
theorem check_mono_iff {e : Expr} {Γ M L L' r} (hs : ∀ v ∈ L', v ∈ L) (hs' : ∀ v ∈ L, v ∈ L') :
    check Γ M L e = some r ↔ check Γ M L' e = some r :=
  ⟨fun h => check_mono e h hs, fun h => check_mono e h hs'⟩

/-- A name an expression does not use is not moved by it. -/
theorem check_moved_fv (e : Expr) : ∀ {Γ M L τ M' z}, check Γ M L e = some (τ, M') →
    z ∉ M → z ∉ fv e → z ∉ M' := by
  induction e with
  | lit n => intro Γ M L τ M' z hc hzm _; simp [check] at hc; rw [← hc.2]; exact hzm
  | name x =>
    intro Γ M L τ M' z hc hzm _
    simp only [check] at hc
    cases hx : Γ.lookup x with
    | none => simp [hx] at hc
    | some τx =>
      cases τx with
      | view m y => cases m <;> simp [hx] at hc <;> simp_all
      | _ => simp [hx] at hc <;> simp_all
  | move x | drop x =>
    intro Γ M L τ M' z hc hzm hz
    simp only [check] at hc
    cases hx : Γ.lookup x with
    | none => simp [hx] at hc
    | some τx =>
      simp [hx] at hc
      obtain ⟨-, -, -, rfl⟩ := hc
      have hzx : z ≠ x := by rintro rfl; simp [fv] at hz
      simp [hzx, hzm]
  | clone x =>
    intro Γ M L τ M' z hc hzm _
    simp only [check] at hc
    cases hx : Γ.lookup x with
    | none => simp [hx] at hc
    | some τx =>
      cases τx with
      | view m y => simp [hx] at hc; cases hy : Γ.lookup y <;> simp_all
      | _ => simp [hx] at hc; simp_all
  | lend m x =>
    intro Γ M L τ M' z hc hzm _
    simp only [check] at hc
    cases hx : Γ.lookup x with
    | none => simp [hx] at hc
    | some τx => simp [hx] at hc; simp_all
  | box e ih | out e ih =>
    intro Γ M L τ M' z hc hzm hz
    simp only [check] at hc
    cases h1 : check Γ M L e with
    | none => simp [h1] at hc
    | some p =>
      obtain ⟨τ1, M1⟩ := p
      simp [h1] at hc
      have := ih h1 hzm (by simpa [fv] using hz)
      simp_all
  | assign x e ih =>
    intro Γ M L τ M' z hc hzm hz
    simp only [check] at hc
    cases h1 : check Γ M (x :: L) e with
    | none => simp [h1] at hc
    | some p =>
      obtain ⟨τ1, M1⟩ := p
      have := ih h1 hzm (by simp [fv] at hz; exact hz.2)
      simp only [h1] at hc
      cases hx : Γ.lookup x with
      | none => simp [hx] at hc
      | some τx =>
        cases τx with
        | view m y => cases m <;> simp [hx] at hc <;> simp_all
        | int | box =>
          simp [hx] at hc
          obtain ⟨-, -, rfl⟩ := hc
          simp [this]
        | unit => simp [hx] at hc
  | add a b iha ihb | seq a b iha ihb =>
    intro Γ M L τ M' z hc hzm hz
    simp only [check] at hc
    simp only [fv, List.mem_append, not_or] at hz
    cases h1 : check Γ M (fv b ++ L) a with
    | none => simp [h1] at hc
    | some p =>
      obtain ⟨τ1, M1⟩ := p
      simp only [h1] at hc
      have h1' := iha h1 hzm hz.1
      cases h2 : check Γ M1 L b with
      | none => simp [h2] at hc
      | some q =>
        obtain ⟨τ2, M2⟩ := q
        have := ihb h2 h1' hz.2
        simp [h2] at hc
        simp_all
  | letIn x e body ihe ihb =>
    intro Γ M L τ M' z hc hzm hz
    simp only [check] at hc
    simp only [fv, List.mem_append, not_or, List.mem_filter] at hz
    cases h1 : check Γ M ((fv body).filter (fun z => !decide (z = x)) ++ L) e with
    | none => simp [h1] at hc
    | some p =>
      obtain ⟨τ1, M1⟩ := p
      have h1' := ihe h1 hzm hz.1
      cases h2 : check ((x, τ1) :: Γ) M1 L body with
      | none => simp [h1, h2] at hc
      | some q =>
        obtain ⟨τ2, M2⟩ := q
        simp [h1, h2] at hc
        obtain ⟨-, -, -, rfl⟩ := hc
        by_cases hzx : z = x
        · simp [hzx]
        · have := ihb h2 h1' (fun hb => hz.2 ⟨hb, by simp [hzx]⟩)
          simp [this]

theorem not_mem_of_lookup_none {Γ : List (Var × β)} {x : Var} {b : β} (h : Γ.lookup x = none) :
    (x, b) ∉ Γ := by
  revert h
  induction Γ with
  | nil => simp
  | cons p Γ ih =>
    obtain ⟨y, c⟩ := p
    intro h hm
    by_cases hxy : x = y
    · subst hxy; simp [List.lookup] at h
    · rw [lookup_cons_other hxy] at h
      rcases List.mem_cons.1 hm with he | he
      · cases he; exact hxy rfl
      · exact ih h he

end LambdaRig
