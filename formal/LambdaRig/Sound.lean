/-
λRig: the soundness theorem.

`accepts_runs`: a program `rig check` accepts runs to the end without a
fault. It never uses a name after it moved or a cell after it was freed,
never uses a view after its loan ended, never gets stuck, and ends owning
nothing. The proof is by induction on the program (`sound`), one case per
form (LambdaRig/Steps.lean, and `let` here).
-/
import LambdaRig.Steps

namespace LambdaRig

/-- The checker moves out only names in scope. -/
theorem check_fresh (e : Expr) : ∀ {Γ M L τ M' z}, check Γ M L e = some (τ, M') →
    z ∉ M → Γ.lookup z = none → z ∉ M' := by
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
      have hzx : z ≠ x := by rintro rfl; rw [hz] at hx; cases hx
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
      have := ih h1 hzm hz
      simp_all
  | assign x e ih =>
    intro Γ M L τ M' z hc hzm hz
    simp only [check] at hc
    cases h1 : check Γ M (x :: L) e with
    | none => simp [h1] at hc
    | some p =>
      obtain ⟨τ1, M1⟩ := p
      have := ih h1 hzm hz
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
    cases h1 : check Γ M (fv b ++ L) a with
    | none => simp [h1] at hc
    | some p =>
      obtain ⟨τ1, M1⟩ := p
      simp only [h1] at hc
      have h1' := iha h1 hzm hz
      cases h2 : check Γ M1 L b with
      | none => simp [h2] at hc
      | some q =>
        obtain ⟨τ2, M2⟩ := q
        have := ihb h2 h1' hz
        simp [h2] at hc
        simp_all
  | letIn x e body ihe ihb =>
    intro Γ M L τ M' z hc hzm hz
    simp only [check] at hc
    cases h1 : check Γ M ((fv body).filter (fun z => !decide (z = x)) ++ L) e with
    | none => simp [h1] at hc
    | some p =>
      obtain ⟨τ1, M1⟩ := p
      have h1' := ihe h1 hzm hz
      cases h2 : check ((x, τ1) :: Γ) M1 L body with
      | none => simp [h1, h2] at hc
      | some q =>
        obtain ⟨τ2, M2⟩ := q
        simp [h1, h2] at hc
        obtain ⟨-, -, -, rfl⟩ := hc
        by_cases hzx : z = x
        · simp [hzx]
        · have := ihb h2 h1' (by rw [lookup_cons_other hzx]; exact hz)
          simp [this]

theorem lookup_none_of {Γ : Ctx} {x : Var} (h : ∀ a b, (a, b) ∈ Γ → ¬x = a) : Γ.lookup x = none := by
  cases hx : Γ.lookup x with
  | none => rfl
  | some τ => exact absurd rfl (h x τ (mem_of_lookup hx))

/-- Leaving a `let` frees `x`'s place, then drops what it held; the value
in hand, no view of `x`, keeps its type. -/
theorem Rel.leave {Γ x τe M L σ β s w τ l c} (r : Rel ((x, τe) :: Γ) M L (reboxed σ x l) β s (owned w))
    (hf : VFits ((x, τe) :: Γ) M (reboxed σ x l) β s τ w) (hτ : τ.lentFrom x = false)
    (hxΓ : Γ.lookup x = none)
    (hctx : ∀ z m y, Γ.lookup z = some (.view m y) → ∃ τ, Γ.lookup y = some τ ∧ τ.owner = true)
    (hc : s.heap l = some c) {s0 : Machine} (h0 : s0.heap = upd s.heap l none)
    (he0 : ∀ z τ, Γ.lookup z = some τ → s0.env z = some (σ z)) (hn0 : s.next ≤ s0.next) :
    ∃ s', (∀ o, c.val = some o → (dropVal o).run s0 = .ok ((), s')) ∧ (c.val = none → s' = s0) ∧
      Rel Γ (M.filter (· ≠ x)) L σ β s' (owned w) ∧ VFits Γ (M.filter (· ≠ x)) σ β s' τ w := by
  have r0 := r.unscope hxΓ hctx hc h0 he0 hn0
  have hcx : s.heap (reboxed σ x l x) = some c := by rw [reboxed_self]; exact hc
  -- The cells the value in hand needs are neither x's place nor x's box.
  have hkeep : ∀ b, (b ∈ owned w ∨ ∃ m y, τ = .view m y ∧ b = σ y) →
      b ≠ l ∧ ∀ b' ∈ ownedIn c.val, b ≠ b' := by
    intro b hb
    rcases hb with hb | ⟨m, y, rfl, rfl⟩
    · obtain ⟨h1, h2⟩ := r.ex_sep b hb
      refine ⟨fun h => h1 x τe lookup_cons_self (by rw [reboxed_self]; exact h.symm), fun b' hb' => ?_⟩
      obtain ⟨hxm, rfl, rfl⟩ := r.slot_owned lookup_cons_self hcx hb'
      exact fun h => h2 x lookup_cons_self hxm h.symm
    · have hyx : y ≠ x := by simpa [Ty.lentFrom] using hτ
      obtain ⟨t, -, hym, ⟨τy, hy, -⟩, -⟩ := hf
      refine ⟨fun h => hyx (r.slot_inj y x τy τe hy lookup_cons_self
        (by rw [reboxed_other hyx, reboxed_self]; exact h)), fun b' hb' => ?_⟩
      obtain ⟨hxm, rfl, rfl⟩ := r.slot_owned lookup_cons_self hcx hb'
      exact fun h => r.box_slot x y τy lookup_cons_self hxm hy (by rw [reboxed_other hyx]; exact h.symm)
  have hf0 := hf.unscope hτ
  have hs0 : ∀ b, (b ∈ owned w ∨ ∃ m y, τ = .view m y ∧ b = σ y) → s0.heap b = s.heap b :=
    fun b hb => by rw [h0, upd_other _ _ (hkeep b hb).1]
  have hfit0 : VFits Γ (M.filter (· ≠ x)) σ β s0 τ w :=
    hf0.heap (fun b hb => hs0 b (Or.inl hb)) (fun m y hτy => hs0 _ (Or.inr ⟨m, y, hτy, rfl⟩))
  cases hcv : c.val with
  | none =>
    refine ⟨s0, by simp, fun _ => rfl, ?_, hfit0⟩
    have := r0; rw [hcv] at this; exact this
  | some o =>
    cases o with
    | box b =>
      have hb : b ∈ ownedIn c.val := by simp [hcv, ownedIn, owned]
      obtain ⟨hxm, hτe, hbx⟩ := r.slot_owned lookup_cons_self hcx hb
      subst hτe
      obtain ⟨cb, n, hcb, -⟩ := r.boxes x lookup_cons_self hxm
      have hbl : b ≠ l := by
        have := r.box_slot x x .box lookup_cons_self hxm lookup_cons_self
        rw [reboxed_self] at this; rw [hbx]; exact this
      have hcb0 : s0.heap b = some cb := by rw [h0, upd_other _ _ hbl, hbx]; exact hcb
      refine ⟨{ s0 with heap := upd s0.heap b none }, fun o ho => ?_, (fun h => by cases h), ?_, ?_⟩
      · cases ho; simp only [dropVal]; exact run_free hcb0
      · have := r0; rw [hcv] at this; exact (this : Rel _ _ _ _ _ _ (b :: owned w)).freeEx
      · refine hfit0.heap (fun b' hb' => ?_) (fun m y hτy => ?_)
        · exact upd_other _ _ ((hkeep b' (Or.inl hb')).2 b hb)
        · exact upd_other _ _ ((hkeep _ (Or.inr ⟨m, y, hτy, rfl⟩)).2 b hb)
    | _ =>
      refine ⟨s0, fun o ho => ?_, (fun h => by cases h), ?_, hfit0⟩
      · cases ho; exact rfl
      · have := r0; rw [hcv] at this; exact this

theorem sound_letIn (x : Var) (e body : Expr) (ihe : Sound e) (ihb : Sound body) :
    Sound (.letIn x e body) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases h1 : check Γ M ((fv body).filter (fun z => !decide (z = x)) ++ L) e with
  | none => simp [h1] at hc
  | some p =>
    obtain ⟨τe, Me⟩ := p
    cases h2 : check ((x, τe) :: Γ) Me L body with
    | none => simp [h1, h2] at hc
    | some q =>
      obtain ⟨τb, Mb⟩ := q
      simp [h1, h2] at hc
      obtain ⟨⟨hxΓ', hxM⟩, hτ, rfl, rfl⟩ := hc
      have hxΓ := lookup_none_of hxΓ'
      have rIH : Rel Γ M (fv e ++ ((fv body).filter (fun z => !decide (z = x)) ++ L)) σ β s [] :=
        r.mono (fun z hz => by simp [fv] at hz ⊢; exact hz)
      obtain ⟨v, s1, β1, hrun1, r1, hf1⟩ := ihe Γ M _ _ _ σ β s h1 rIH
      have hxMe : x ∉ Me := check_fresh e h1 hxM hxΓ
      have r2 := r1.bind hf1 hxΓ hxMe (Live := fv body ++ L)
        (fun z hz hzx => by rcases List.mem_append.1 hz with h | h <;> simp [h, hzx])
      obtain ⟨w, s3, β3, hrun2, r3, hf3⟩ := ihb _ _ _ _ _ _ _ _ h2 r2
      obtain ⟨c, hc3, -⟩ := r3.slot x τe lookup_cons_self
      rw [reboxed_self] at hc3
      obtain ⟨s4, hdrop, hnone, r4, hf4⟩ := r3.leave hf3 hτ hxΓ r.ctx hc3
        (s0 := { s3 with env := s1.env, heap := upd s3.heap s1.next none }) rfl
        (fun z τz hz => r1.env z τz hz) (Nat.le_refl _)
      rw [filter_not_eq]
      refine ⟨w, s4, β3, ?_, r4, hf4⟩
      simp only [eval, StateT.run_bind, hrun1, except_ok_bind, run_alloc]
      simp only [StateT.run_map, StateT.run_get, StateT.run_modify, except_ok_bind, except_ok_map,
        except_pure, hrun2]
      simp only [run_cell (s := { heap := s3.heap, env := s1.env, next := s3.next, out := s3.out }) hc3,
        except_ok_bind, run_free (s := { heap := s3.heap, env := s1.env, next := s3.next, out := s3.out }) hc3]
      cases hcv : c.val with
      | none => rw [hnone hcv]; rfl
      | some o => simp only [StateT.run_bind, hdrop o hcv, except_ok_bind]; rfl

/-- Every program the checker accepts, in any scope that matches the
machine, runs without a fault. -/
theorem sound (e : Expr) : Sound e := by
  induction e with
  | lit n => exact sound_lit n
  | name x => exact sound_name x
  | move x => exact sound_move x
  | clone x => exact sound_clone x
  | box e ih => exact sound_box e ih
  | lend m x => exact sound_lend m x
  | assign x e ih => exact sound_assign x e ih
  | drop x => exact sound_drop x
  | add a b iha ihb => exact sound_add a b iha ihb
  | out e ih => exact sound_out e ih
  | seq a b iha ihb => exact sound_seq a b iha ihb
  | letIn x e body ihe ihb => exact sound_letIn x e body ihe ihb

/-- The empty machine matches the empty scope. -/
theorem Rel.empty (L : List Var) : Rel [] [] L (fun _ => 0) (fun _ => 0) {} [] where
  env := by simp
  slot := by simp
  boxes := by simp
  ctx := by simp
  views := by simp
  slot_inj := by simp
  box_slot := by simp
  box_inj := by simp
  ex_sep := by simp
  dom := by simp
  bound := by simp

/-- **Soundness.** A program `rig check` accepts runs to the end without
a fault: no use after move or free, no view after its loan ended, nothing
stuck, and no leak. -/
theorem accepts_runs (e : Expr) (h : accepts e = true) : ∃ out, run e = .ok out := by
  obtain ⟨⟨τ, M'⟩, hc⟩ := Option.isSome_iff_exists.1 h
  obtain ⟨v, s1, β1, hrun, r1, hf⟩ := sound e [] [] [] τ M' _ _ {} hc (Rel.empty _)
  obtain ⟨s2, hdrop, r2, -⟩ := r1.dropHand hf
  have hempty : ∀ l, s2.heap l = none := fun l => by
    cases hl : s2.heap l with
    | none => rfl
    | some c => rcases r2.dom l c hl with ⟨_, _, h, _⟩ | ⟨_, h, _⟩ | h <;> simp at h
  refine ⟨s2.out.reverse, ?_⟩
  simp only [run, StateT.run_bind, hrun, except_ok_bind, hdrop]
  simp [hempty]

-- The proof assumes nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.accepts_runs' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms accepts_runs

end LambdaRig
