/-
λRig: each expression the checker accepts keeps the facts.

One theorem per form, `sound_<form>`, states that `Sound` holds for it,
given that it holds for the parts. `let` and the induction that joins the
forms are in LambdaRig/Sound.lean.
-/
import LambdaRig.Facts

namespace LambdaRig

@[simp] theorem guard_bind_some {p : Prop} [Decidable p] {f : Unit → Option α} {a : α} :
    ((guard p : Option Unit).bind f = some a) ↔ p ∧ f () = some a := by
  by_cases h : p
  · simp [guard, h]
  · simp only [guard, h, ite_false, iff_false, false_and]
    show ¬ (none : Option Unit).bind f = some a
    simp

/-- A read by the owner keeps every read loan. -/
theorem ownerRead_keeps {c : Cell} {m t} (hm : Access.read.ends m = false) (h : c.live m t = true) :
    c.ownerRead.live m t = true := by
  cases m <;> simp_all [Access.ends, Cell.live, Cell.ownerRead]

/-- The facts depend on the heap, the environment, and a bound on what is allocated. -/
theorem Rel.congr {Γ M Live σ β s ex} (r : Rel Γ M Live σ β s ex) {s' : Machine}
    (hh : s'.heap = s.heap) (he : s'.env = s.env) (hn : s.next ≤ s'.next) :
    Rel Γ M Live σ β s' ex where
  env x τ h := he ▸ r.env x τ h
  slot x τ h := hh ▸ r.slot x τ h
  boxes x h hm := hh ▸ r.boxes x h hm
  ctx := r.ctx
  views x m y c b t h1 h2 h3 h4 h5 := hh ▸ r.views x m y c b t h1 h2 h3 (hh ▸ h4) h5
  slot_inj := r.slot_inj
  box_slot := r.box_slot
  box_inj := r.box_inj
  ex_sep := r.ex_sep
  dom l c h := r.dom l c (hh ▸ h)
  bound l c h := Nat.lt_of_lt_of_le (r.bound l c (hh ▸ h)) hn

theorem Rel.next_free {Γ M Live σ β s ex} (r : Rel Γ M Live σ β s ex) : s.heap s.next = none := by
  cases h : s.heap s.next with
  | none => rfl
  | some c => exact absurd (r.bound _ c h) (Nat.lt_irrefl _)

theorem Rel.ne_next {Γ M Live σ β s ex} (r : Rel Γ M Live σ β s ex) {l c}
    (h : s.heap l = some c) : l ≠ s.next := Nat.ne_of_lt (r.bound l c h)

/-- A new box, in hand: the one cell the value owns. -/
theorem Rel.alloc {Γ M Live σ β s} (r : Rel Γ M Live σ β s []) (n : Int) :
    Rel Γ M Live σ β
      { s with next := s.next + 1, heap := upd s.heap s.next (some (Cell.fresh (.int n))) }
      [s.next] where
  env := r.env
  slot x τ h := by
    obtain ⟨c, hc, hs⟩ := r.slot x τ h
    exact ⟨c, by simp [upd_other _ _ (r.ne_next hc), hc], hs⟩
  boxes x h hm := by
    obtain ⟨c, n, hc, hv⟩ := r.boxes x h hm
    exact ⟨c, n, by simp [upd_other _ _ (r.ne_next hc), hc], hv⟩
  ctx := r.ctx
  views x m y c b t h1 h2 h3 h4 h5 := by
    obtain ⟨c0, hc0, -⟩ := r.slot x _ h1
    simp [upd_other _ _ (r.ne_next hc0), hc0] at h4
    subst h4
    obtain ⟨hy, hb, cb, hcb, hl⟩ := r.views x m y c0 b t h1 h2 h3 hc0 h5
    exact ⟨hy, hb, cb, by simp [upd_other _ _ (r.ne_next hcb), hcb], hl⟩
  slot_inj := r.slot_inj
  box_slot := r.box_slot
  box_inj := r.box_inj
  ex_sep l hl := by
    simp at hl; subst hl
    refine ⟨fun x τ h => ?_, fun x h hm => ?_⟩
    · obtain ⟨c, hc, -⟩ := r.slot x τ h; exact r.ne_next hc
    · obtain ⟨c, n, hc, -⟩ := r.boxes x h hm; exact r.ne_next hc
  dom l c h := by
    by_cases he : l = s.next
    · exact Or.inr (Or.inr (by simp [he]))
    · simp [upd_other _ _ he] at h
      rcases r.dom l c h with h | h | h
      · exact Or.inl h
      · exact Or.inr (Or.inl h)
      · simp at h
  bound l c h := by
    by_cases he : l = s.next
    · simp [he]
    · simp [upd_other _ _ he] at h
      exact Nat.lt_succ_of_lt (r.bound l c h)

/-- What the theorem promises for one expression. -/
def Sound (e : Expr) : Prop :=
  ∀ Γ M L τ M' σ β s, check Γ M L e = some (τ, M') → Rel Γ M (fv e ++ L) σ β s [] →
    ∃ v s' β', (eval e).run s = .ok (v, s') ∧ Rel Γ M' L σ β' s' (owned v) ∧
      VFits Γ M' σ β' s' τ v

theorem sound_name (x : Var) : Sound (.name x) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases hx : Γ.lookup x with
  | none => simp [hx] at hc
  | some τx =>
    simp [hx] at hc
    obtain ⟨hm, hc⟩ := hc
    have he := r.env x τx hx
    obtain ⟨c, hh, hs⟩ := r.slot x τx hx
    have rL := r.mono (Live' := L) (fun _ h => List.mem_append_right _ h)
    cases τx with
    | int =>
      simp at hc
      obtain ⟨ha, rfl, rfl⟩ := hc
      simp [Shape, hm] at hs
      obtain ⟨n, hv⟩ := hs
      refine ⟨.int n, { s with heap := upd s.heap (σ x) (some c.ownerRead) }, β, ?_, ?_, ⟨n, rfl⟩⟩
      · simp only [eval, StateT.run_bind, run_held he hh hv, except_ok_bind, run_setCell _ hh]
        rfl
      · exact rL.touch hx rfl hh (c' := c.ownerRead) (by simp [Shape, hm, Cell.ownerRead, hv])
          (fun z m hz hzl _ t hl => ownerRead_keeps (allows_spec ha hz hzl) hl)
    | box => simp at hc
    | view m y =>
      simp [Shape, hm] at hs
      obtain ⟨b, t, hv⟩ := hs
      obtain ⟨hym, rfl, cb, hcb, hl⟩ :=
        r.views x m y c b t hx hm (List.mem_append_left _ (by simp [fv])) hh hv
      obtain ⟨τy, hy, ho⟩ := r.ctx x m y hx
      obtain ⟨n, hn⟩ := r.deref hy ho hym hcb hl
      cases m with
      | read =>
        simp at hc
        obtain ⟨rfl, rfl⟩ := hc
        refine ⟨.view .read (σ y) t, s, β, ?_, rL, ⟨t, rfl, hym, ⟨τy, hy, ho⟩, cb, hcb, hl⟩⟩
        simp only [eval, StateT.run_bind, run_held he hh hv, except_ok_bind, hn]
        rfl
      | write =>
        simp at hc
        obtain ⟨-, rfl, rfl⟩ := hc
        refine ⟨.int n, s, β, ?_, rL, ⟨n, rfl⟩⟩
        simp only [eval, StateT.run_bind, run_held he hh hv, except_ok_bind, hn]
        rfl
    | unit =>
      simp at hc
      obtain ⟨rfl, rfl⟩ := hc
      simp [Shape, hm] at hs
      refine ⟨.unit, s, β, ?_, rL, rfl⟩
      simp only [eval, StateT.run_bind, run_held he hh hs, except_ok_bind]
      rfl

theorem sound_lit (n : Int) : Sound (.lit n) := by
  intro Γ M L τ M' σ β s hc r
  simp [check] at hc
  obtain ⟨rfl, rfl⟩ := hc
  exact ⟨.int n, s, β, rfl, r.mono (fun _ h => by simpa [fv] using h), ⟨n, rfl⟩⟩

/-- The loan kind `!x` or `?x` needs. -/
def lendAccess : Mode → Access
  | .read => .read
  | .write => .write

/-- The cell after `?x` or `!x`. -/
def Cell.lend (c : Cell) : Mode → Tag → Cell
  | .read, t => c.lendRead t
  | .write, t => c.lendWrite t

theorem lend_keeps {c : Cell} {m m' : Mode} {t t' : Tag}
    (he : (lendAccess m).ends m' = false) (h : c.live m' t' = true) :
    (c.lend m t).live m' t' = true := by
  cases m <;> cases m' <;> simp_all [lendAccess, Access.ends, Cell.live, Cell.lend, Cell.lendRead]

theorem lend_live (c : Cell) (m : Mode) (t : Tag) : (c.lend m t).live m t = true := by
  cases m <;> simp [Cell.live, Cell.lend, Cell.lendRead, Cell.lendWrite]

theorem lend_val (c : Cell) (m : Mode) (t : Tag) : (c.lend m t).val = c.val := by
  cases m <;> rfl

theorem lend_match (c : Cell) (m : Mode) (t : Tag) :
    (match m with | .read => c.lendRead t | .write => c.lendWrite t) = c.lend m t := by
  cases m <;> rfl

theorem access_match (m : Mode) :
    (match m with | .read => Access.read | .write => Access.write) = lendAccess m := by
  cases m <;> rfl

theorem sound_lend (m : Mode) (x : Var) : Sound (.lend m x) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases hx : Γ.lookup x with
  | none => simp [hx] at hc
  | some τx =>
    simp [hx] at hc
    obtain ⟨⟨hm, ho⟩, ha, rfl, rfl⟩ := hc
    have he := r.env x τx hx
    obtain ⟨c, hh, hs⟩ := r.slot x τx hx
    have rL := r.mono (Live' := L) (fun _ h => List.mem_append_right _ h)
    have r1 := rL.congr (s' := { s with next := s.next + 1 }) rfl rfl (Nat.le_succ _)
    have r2 := r1.touch hx ho hh (c' := c.lend m s.next) (by rw [lend_val]; exact hs)
      (fun z m' hz hzl _ t hl => lend_keeps (access_match m ▸ allows_spec ha hz hzl) hl)
    refine ⟨.view m (σ x) s.next, _, β, ?_, r2,
      ⟨s.next, rfl, hm, ⟨τx, hx, ho⟩, c.lend m s.next, by simp, lend_live _ _ _⟩⟩
    rcases Ty.owner_cases ho with rfl | rfl
    · simp [Shape, hm] at hs
      obtain ⟨k, hk⟩ := hs
      simp only [eval, StateT.run_bind, run_held he hh hk, except_ok_bind]
      simp [setCell, hh, run_fresh]; cases m <;> rfl
    · simp [Shape, hm] at hs
      simp only [eval, StateT.run_bind, run_held he hh hs, except_ok_bind]
      simp [setCell, hh, run_fresh]; cases m <;> rfl

/-- Moving the value out of `x` leaves its place empty and puts what it
owns in hand, as long as no view of `x` is used later. -/
theorem Rel.moveOut {Γ M L σ β s ex} (r : Rel Γ M L σ β s ex) {x τx c v}
    (hx : Γ.lookup x = some τx) (hxm : x ∉ M) (hh : s.heap (σ x) = some c) (hv : c.val = some v)
    (hno : ∀ z m, Γ.lookup z = some (.view m x) → z ∈ L → False) :
    Rel Γ (x :: M) L σ β { s with heap := upd s.heap (σ x) (some (c.ownerWrite none)) } (owned v ++ ex) where
  env := r.env
  slot z τ hz := by
    by_cases hzx : z = x
    · subst hzx; exact ⟨c.ownerWrite none, by simp, by simp [Shape, Cell.ownerWrite]⟩
    · have hne : σ z ≠ σ x := fun h => hzx (r.slot_inj z x τ τx hz hx h)
      obtain ⟨c0, hc0, hs⟩ := r.slot z τ hz
      exact ⟨c0, by simp [upd_other _ _ hne, hc0], by simpa [Shape, hzx] using hs⟩
  boxes z hz hzm := by
    simp at hzm
    have hne : β z ≠ σ x := r.box_slot z x _ hz hzm.2 hx
    simpa [upd_other _ _ hne] using r.boxes z hz hzm.2
  ctx := r.ctx
  views z m y c0 b t hz hzm hzl hc0 hv0 := by
    simp at hzm
    have hne : σ z ≠ σ x := fun h => hzm.1 (r.slot_inj z x _ τx hz hx h)
    simp only [upd_other _ _ hne] at hc0
    obtain ⟨hym, hb, cb, hcb, hl⟩ := r.views z m y c0 b t hz hzm.2 hzl hc0 hv0
    have hyx : y ≠ x := by rintro rfl; exact hno z m hz hzl
    obtain ⟨τy, hy, -⟩ := r.ctx z m y hz
    have hbx : b ≠ σ x := fun h => hyx (r.slot_inj y x τy τx hy hx (hb.symm.trans h))
    exact ⟨by simp [hyx, hym], hb, cb, by simp [upd_other _ _ hbx, hcb], hl⟩
  slot_inj := r.slot_inj
  box_slot z y τ hz hzm hy := r.box_slot z y τ hz (by simp at hzm; exact hzm.2) hy
  box_inj z y hz hzm hy hym := r.box_inj z y hz (by simp at hzm; exact hzm.2) hy (by simp at hym; exact hym.2)
  ex_sep l hl := by
    rcases List.mem_append.1 hl with hl | hl
    · obtain ⟨c1, hc1, hs⟩ := r.slot x τx hx
      rw [hh] at hc1; cases hc1
      cases v with
      | box b =>
        simp [owned] at hl; subst hl
        cases τx <;> simp [Shape, hxm, hv] at hs
        subst hs
        exact ⟨fun z τ hz h => r.box_slot x z τ hx hxm hz h.symm,
          fun z hz hzm h => by simp at hzm; exact hzm.1 (r.box_inj z x hz hzm.2 hx hxm h)⟩
      | _ => simp [owned] at hl
    · obtain ⟨h1, h2⟩ := r.ex_sep l hl
      exact ⟨h1, fun z hz hzm => h2 z hz (by simp at hzm; exact hzm.2)⟩
  dom l c' hl := by
    by_cases he : l = σ x
    · exact Or.inl ⟨x, τx, hx, he.symm⟩
    · simp only [upd_other _ _ he] at hl
      rcases r.dom l c' hl with h | ⟨z, hz, hzm, hb⟩ | h
      · exact Or.inl h
      · by_cases hzx : z = x
        · subst hzx
          obtain ⟨c1, hc1, hs⟩ := r.slot z _ hz
          rw [hh] at hc1; cases hc1
          simp [Shape, hzm, hv] at hs
          subst hs; simp [owned, hb]
        · exact Or.inr (Or.inl ⟨z, hz, by simp [hzx, hzm], hb⟩)
      · exact Or.inr (Or.inr (List.mem_append_right _ h))
  bound l c' hl := by
    by_cases he : l = σ x
    · subst he; exact r.bound _ c hh
    · exact r.bound l c' (by simpa [upd_other _ _ he] using hl)

/-- Freeing a cell the value in hand owns. -/
theorem Rel.freeEx {Γ M L σ β s b ex} (r : Rel Γ M L σ β s (b :: ex)) :
    Rel Γ M L σ β { s with heap := upd s.heap b none } ex where
  env := r.env
  slot z τ hz := by
    have hne : σ z ≠ b := (r.ex_sep b (by simp)).1 z τ hz
    simpa [upd_other _ _ hne] using r.slot z τ hz
  boxes z hz hzm := by
    have hne : β z ≠ b := (r.ex_sep b (by simp)).2 z hz hzm
    simpa [upd_other _ _ hne] using r.boxes z hz hzm
  ctx := r.ctx
  views z m y c0 b' t hz hzm hzl hc0 hv0 := by
    have hne : σ z ≠ b := (r.ex_sep b (by simp)).1 z _ hz
    simp only [upd_other _ _ hne] at hc0
    obtain ⟨hym, hb, cb, hcb, hl⟩ := r.views z m y c0 b' t hz hzm hzl hc0 hv0
    obtain ⟨τy, hy, -⟩ := r.ctx z m y hz
    have hbb : b' ≠ b := by rw [hb]; exact (r.ex_sep b (by simp)).1 y _ hy
    exact ⟨hym, hb, cb, by simp [upd_other _ _ hbb, hcb], hl⟩
  slot_inj := r.slot_inj
  box_slot := r.box_slot
  box_inj := r.box_inj
  ex_sep l hl := r.ex_sep l (List.mem_cons_of_mem _ hl)
  dom l c' hl := by
    by_cases he : l = b
    · subst he; simp at hl
    · simp only [upd_other _ _ he] at hl
      rcases r.dom l c' hl with h | h | h
      · exact Or.inl h
      · exact Or.inr (Or.inl h)
      · simp [he] at h; exact Or.inr (Or.inr h)
  bound l c' hl := by
    by_cases he : l = b
    · subst he; simp at hl
    · exact r.bound l c' (by simpa [upd_other _ _ he] using hl)

/-- A name the checker lets move or drop has no view used later. -/
theorem Rel.noViews {Γ M Live σ β s ex} (r : Rel Γ M Live σ β s ex) {x τ L}
    (hx : Γ.lookup x = some τ) (h : (!τ.owner || allows Γ x .write L) = true) :
    ∀ z m, Γ.lookup z = some (.view m x) → z ∈ L → False := by
  intro z m hz hzl
  cases ho : τ.owner
  · obtain ⟨τ', hy, ho'⟩ := r.ctx z m x hz
    rw [hx] at hy; cases hy; simp [ho] at ho'
  · simp [ho] at h
    have := allows_spec h hz hzl
    simp [Access.ends] at this

/-- What a name holds fits its type, read before it moves. -/
theorem Rel.heldFits {Γ M L σ β s ex} (r : Rel Γ M L σ β s ex) {x τ c v}
    (hx : Γ.lookup x = some τ) (hxm : x ∉ M) (hxl : x ∈ L) (hh : s.heap (σ x) = some c)
    (hv : c.val = some v) {s' : Machine} (hne : ∀ l, l ≠ σ x → s'.heap l = s.heap l) :
    VFits Γ (x :: M) σ β s' τ v := by
  obtain ⟨c1, hc1, hs⟩ := r.slot x τ hx
  rw [hh] at hc1; cases hc1
  cases τ with
  | unit => simp [Shape, hxm, hv] at hs; exact hs
  | int => simp [Shape, hxm, hv] at hs; exact hs
  | box =>
    simp [Shape, hxm, hv] at hs; subst hs
    obtain ⟨cb, n, hcb, hn⟩ := r.boxes x hx hxm
    exact ⟨β x, cb, n, rfl, by rw [hne _ (r.box_slot x x _ hx hxm hx)]; exact hcb, hn⟩
  | view m y =>
    simp [Shape, hxm, hv] at hs
    obtain ⟨b, t, rfl⟩ := hs
    obtain ⟨hym, rfl, cb, hcb, hl⟩ := r.views x m y c b t hx hxm hxl hh hv
    obtain ⟨τy, hy, ho⟩ := r.ctx x m y hx
    have hyx : y ≠ x := by rintro rfl; rw [hx] at hy; cases hy; simp [Ty.owner] at ho
    have hbx : σ y ≠ σ x := fun h => hyx (r.slot_inj y x τy _ hy hx h)
    exact ⟨t, rfl, by simp [hyx, hym], ⟨τy, hy, ho⟩, cb, by rw [hne _ hbx]; exact hcb, hl⟩

theorem sound_move (x : Var) : Sound (.move x) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases hx : Γ.lookup x with
  | none => simp [hx] at hc
  | some τx =>
    simp [hx] at hc
    obtain ⟨hm, ha, rfl, rfl⟩ := hc
    have he := r.env x τx hx
    obtain ⟨c, hh, hs⟩ := r.slot x τx hx
    obtain ⟨v, hv⟩ : ∃ v, c.val = some v := by
      cases τx <;> simp [Shape, hm] at hs
      all_goals first | exact ⟨_, hs⟩ | (obtain ⟨_, h⟩ := hs; exact ⟨_, h⟩) | (obtain ⟨_, _, h⟩ := hs; exact ⟨_, h⟩)
    have rL := r.mono (Live' := L) (fun _ h => List.mem_append_right _ h)
    refine ⟨v, { s with heap := upd s.heap (σ x) (some (c.ownerWrite none)) }, β, ?_,
      List.append_nil (owned v) ▸ rL.moveOut hx hm hh hv (r.noViews hx (by simpa using ha)),
      r.heldFits hx hm (by simp [fv]) hh hv (fun l h => by simp [upd_other _ _ h])⟩
    simp only [eval, StateT.run_bind, run_held he hh hv, except_ok_bind, run_setCell _ hh]
    rfl

theorem sound_drop (x : Var) : Sound (.drop x) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases hx : Γ.lookup x with
  | none => simp [hx] at hc
  | some τx =>
    simp [hx] at hc
    obtain ⟨hm, ha, rfl, rfl⟩ := hc
    have he := r.env x τx hx
    obtain ⟨c, hh, hs⟩ := r.slot x τx hx
    obtain ⟨v, hv⟩ : ∃ v, c.val = some v := by
      cases τx <;> simp [Shape, hm] at hs
      all_goals first | exact ⟨_, hs⟩ | (obtain ⟨_, h⟩ := hs; exact ⟨_, h⟩) | (obtain ⟨_, _, h⟩ := hs; exact ⟨_, h⟩)
    have rL := r.mono (Live' := L) (fun _ h => List.mem_append_right _ h)
    have r1 := List.append_nil (owned v) ▸ rL.moveOut hx hm hh hv (r.noViews hx (by simpa using ha))
    have hf := r.heldFits hx hm (by simp [fv]) hh hv
      (s' := { s with heap := upd s.heap (σ x) (some (c.ownerWrite none)) })
      (fun l h => by simp [upd_other _ _ h])
    cases v with
    | box b =>
      obtain ⟨cb, hcb⟩ : ∃ cb, (upd s.heap (σ x) (some (c.ownerWrite none))) b = some cb := by
        cases τx <;> simp [VFits] at hf
        obtain ⟨cb, hcb, -⟩ := hf
        exact ⟨cb, hcb⟩
      refine ⟨.unit, _, β, ?_, r1.freeEx, rfl⟩
      simp only [eval, StateT.run_bind, run_held he hh hv, except_ok_bind, run_setCell _ hh]
      simp only [dropVal, run_free (s := { s with heap := upd s.heap (σ x) (some (c.ownerWrite none)) }) hcb]
      rfl
    | _ =>
      refine ⟨.unit, _, β, ?_, r1, rfl⟩
      simp only [eval, StateT.run_bind, run_held he hh hv, except_ok_bind, run_setCell _ hh]
      rfl

theorem sound_clone (x : Var) : Sound (.clone x) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases hx : Γ.lookup x with
  | none => simp [hx] at hc
  | some τx =>
    simp [hx] at hc
    obtain ⟨hm, hc⟩ := hc
    have he := r.env x τx hx
    obtain ⟨c, hh, hs⟩ := r.slot x τx hx
    have rL := r.mono (Live' := L) (fun _ h => List.mem_append_right _ h)
    cases τx with
    | int =>
      simp at hc
      obtain ⟨ha, rfl, rfl⟩ := hc
      simp [Shape, hm] at hs
      obtain ⟨n, hv⟩ := hs
      refine ⟨.int n, { s with heap := upd s.heap (σ x) (some c.ownerRead) }, β, ?_, ?_, ⟨n, rfl⟩⟩
      · simp only [eval, StateT.run_bind, run_held he hh hv, except_ok_bind, run_setCell _ hh]
        rfl
      · exact rL.touch hx rfl hh (c' := c.ownerRead) (by simp [Shape, hm, Cell.ownerRead, hv])
          (fun z m hz hzl _ t hl => ownerRead_keeps (allows_spec ha hz hzl) hl)
    | box =>
      simp at hc
      obtain ⟨ha, rfl, rfl⟩ := hc
      simp [Shape, hm] at hs
      obtain ⟨cb, n, hb, hn⟩ := r.boxes x hx hm
      have r1 := rL.touch hx rfl hh (c' := c.ownerRead) (by simp [Shape, hm, Cell.ownerRead, hs])
        (fun z m hz hzl _ t hl => ownerRead_keeps (allows_spec ha hz hzl) hl)
      have hbx : β x ≠ σ x := r.box_slot x x _ hx hm hx
      refine ⟨.box _, _, β, ?_, r1.alloc n, ⟨_, Cell.fresh (.int n), n, rfl, by simp, rfl⟩⟩
      simp only [eval, StateT.run_bind, run_held he hh hs, except_ok_bind, run_setCell _ hh]
      simp only [copyOf, StateT.run_bind,
        run_readBox (s := { s with heap := upd s.heap (σ x) (some c.ownerRead) }) (b := β x)
          (by simp [upd_other _ _ hbx, hb]) hn, except_ok_bind, run_alloc]
      rfl
    | view m y =>
      simp [Shape, hm] at hs
      obtain ⟨b, t, hv⟩ := hs
      obtain ⟨hym, rfl, cb, hcb, hl⟩ :=
        r.views x m y c b t hx hm (List.mem_append_left _ (by simp [fv])) hh hv
      obtain ⟨τy, hy, ho⟩ := r.ctx x m y hx
      simp [hy, ho] at hc
      obtain ⟨rfl, rfl⟩ := hc
      rcases r.seen hy ho hym hcb hl with ⟨rfl, n, hn⟩ | ⟨rfl, hn, cb', k, hcb', hk⟩
      · refine ⟨.int n, s, β, ?_, rL, ⟨n, rfl⟩⟩
        simp only [eval, StateT.run_bind, run_held he hh hv, except_ok_bind, hn]
        rfl
      · refine ⟨.box _, _, β, ?_, rL.alloc k, ⟨_, Cell.fresh (.int k), k, rfl, by simp, rfl⟩⟩
        simp only [eval, StateT.run_bind, run_held he hh hv, except_ok_bind, hn, copyOf,
          run_readBox hcb' hk, run_alloc]
        rfl
    | unit =>
      simp at hc
      obtain ⟨rfl, rfl⟩ := hc
      simp [Shape, hm] at hs
      refine ⟨.unit, s, β, ?_, rL, rfl⟩
      simp only [eval, StateT.run_bind, run_held he hh hs, except_ok_bind]
      rfl

/-- A cell the value in hand owns can change freely. -/
theorem Rel.setEx {Γ M L σ β s ex} (r : Rel Γ M L σ β s ex) {l c} (hl : l ∈ ex)
    (hc : s.heap l = some c) (c' : Cell) :
    Rel Γ M L σ β { s with heap := upd s.heap l (some c') } ex where
  env := r.env
  slot z τ hz := by
    have hne : σ z ≠ l := (r.ex_sep l hl).1 z τ hz
    simpa [upd_other _ _ hne] using r.slot z τ hz
  boxes z hz hzm := by
    have hne : β z ≠ l := (r.ex_sep l hl).2 z hz hzm
    simpa [upd_other _ _ hne] using r.boxes z hz hzm
  ctx := r.ctx
  views z m y c0 b' t hz hzm hzl hc0 hv0 := by
    have hne : σ z ≠ l := (r.ex_sep l hl).1 z _ hz
    simp only [upd_other _ _ hne] at hc0
    obtain ⟨hym, hb, cb, hcb, hlv⟩ := r.views z m y c0 b' t hz hzm hzl hc0 hv0
    obtain ⟨τy, hy, -⟩ := r.ctx z m y hz
    have hbb : b' ≠ l := by rw [hb]; exact (r.ex_sep l hl).1 y _ hy
    exact ⟨hym, hb, cb, by simp [upd_other _ _ hbb, hcb], hlv⟩
  slot_inj := r.slot_inj
  box_slot := r.box_slot
  box_inj := r.box_inj
  ex_sep := r.ex_sep
  dom l' c'' hl' := by
    by_cases he : l' = l
    · subst he; exact Or.inr (Or.inr hl)
    · exact r.dom l' c'' (by simpa [upd_other _ _ he] using hl')
  bound l' c'' hl' := by
    by_cases he : l' = l
    · subst he; exact r.bound _ c hc
    · exact r.bound l' c'' (by simpa [upd_other _ _ he] using hl')

theorem sound_box (e : Expr) (ih : Sound e) : Sound (.box e) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases h1 : check Γ M L e with
  | none => simp [h1] at hc
  | some p =>
    obtain ⟨τ1, M1⟩ := p
    simp [h1] at hc
    obtain ⟨rfl, rfl, rfl⟩ := hc
    obtain ⟨v, s1, β1, hrun, r1, ⟨n, rfl⟩⟩ := ih Γ M L _ _ σ β s h1 (by simpa [fv] using r)
    refine ⟨.box s1.next, _, β1, ?_, r1.alloc n, ⟨_, Cell.fresh (.int n), n, rfl, by simp, rfl⟩⟩
    simp only [eval, StateT.run_bind, hrun, except_ok_bind, run_alloc]
    rfl

theorem sound_out (e : Expr) (ih : Sound e) : Sound (.out e) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases h1 : check Γ M L e with
  | none => simp [h1] at hc
  | some p =>
    obtain ⟨τ1, M1⟩ := p
    simp [h1] at hc
    obtain ⟨hk, rfl, rfl⟩ := hc
    obtain ⟨v, s1, β1, hrun, r1, hf⟩ := ih Γ M L _ _ σ β s h1 (by simpa [fv] using r)
    cases τ1 with
    | int =>
      obtain ⟨n, rfl⟩ := hf
      refine ⟨.unit, { s1 with out := n :: s1.out }, β1, ?_, r1.congr rfl rfl (Nat.le_refl _), rfl⟩
      simp only [eval, StateT.run_bind, hrun, except_ok_bind]
      rfl
    | view m y =>
      obtain ⟨t, rfl, hym, ⟨τy, hy, ho⟩, cb, hcb, hl⟩ := hf
      obtain ⟨n, hn⟩ := r1.deref hy ho hym hcb hl
      refine ⟨.unit, { s1 with out := n :: s1.out }, β1, ?_, r1.congr rfl rfl (Nat.le_refl _), rfl⟩
      simp only [eval, StateT.run_bind, hrun, except_ok_bind]
      simp [hn]
    | box =>
      obtain ⟨b, cb, n, rfl, hcb, hn⟩ := hf
      refine ⟨.unit, { s1 with heap := upd s1.heap b none, out := n :: s1.out },
        β1, ?_, (r1 : Rel _ _ _ _ _ _ [b]).freeEx.congr rfl rfl (Nat.le_refl _), rfl⟩
      simp only [eval, StateT.run_bind, hrun, except_ok_bind]
      simp [run_readBox hcb hn, run_free hcb]
    | unit => simp at hk

/-- Dropping the value in hand frees what it owns. -/
theorem Rel.dropHand {Γ M L σ β s τ v} (r : Rel Γ M L σ β s (owned v)) (hf : VFits Γ M σ β s τ v) :
    ∃ s', (dropVal v).run s = .ok ((), s') ∧ Rel Γ M L σ β s' [] ∧ s'.next = s.next := by
  cases v with
  | box b =>
    obtain ⟨cb, hcb⟩ : ∃ cb, s.heap b = some cb := by
      cases τ <;> simp [VFits] at hf
      obtain ⟨cb, hcb, -⟩ := hf
      exact ⟨cb, hcb⟩
    exact ⟨_, by simp only [dropVal, run_free hcb], r.freeEx, rfl⟩
  | _ => exact ⟨s, rfl, r, rfl⟩

theorem Rel.intOf {Γ M L σ β s ex τ v} (r : Rel Γ M L σ β s ex) (hf : VFits Γ M σ β s τ v)
    (hk : τ.readsInt Γ = true) : ∃ n, (intOf v).run s = .ok (n, s) ∧ owned v = [] := by
  cases τ with
  | int => obtain ⟨n, rfl⟩ := hf; exact ⟨n, rfl, rfl⟩
  | view m y =>
    obtain ⟨t, rfl, hym, ⟨τy, hy, ho⟩, cb, hcb, hl⟩ := hf
    obtain ⟨n, hn⟩ := r.deref hy ho hym hcb hl
    exact ⟨n, by simp only [LambdaRig.intOf]; exact hn, rfl⟩
  | _ => simp [Ty.readsInt] at hk

theorem sound_seq (a b : Expr) (iha : Sound a) (ihb : Sound b) : Sound (.seq a b) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases h1 : check Γ M (fv b ++ L) a with
  | none => simp [h1] at hc
  | some p =>
    obtain ⟨τ1, M1⟩ := p
    simp [h1] at hc
    obtain ⟨va, s1, β1, hrun1, r1, hf1⟩ := iha Γ M _ _ _ σ β s h1 (by simpa [fv] using r)
    obtain ⟨s2, hrun2, r2, -⟩ := r1.dropHand hf1
    obtain ⟨vb, s3, β3, hrun3, r3, hf3⟩ := ihb Γ M1 L τ M' σ β1 s2 hc r2
    refine ⟨vb, s3, β3, ?_, r3, hf3⟩
    simp only [eval, StateT.run_bind, hrun1, except_ok_bind, hrun2, hrun3]

theorem sound_add (a b : Expr) (iha : Sound a) (ihb : Sound b) : Sound (.add a b) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases h1 : check Γ M (fv b ++ L) a with
  | none => simp [h1] at hc
  | some p =>
    obtain ⟨τ1, M1⟩ := p
    simp [h1] at hc
    obtain ⟨hk1, hc⟩ := hc
    cases h2 : check Γ M1 L b with
    | none => simp [h2] at hc
    | some q =>
      obtain ⟨τ2, M2⟩ := q
      simp [h2] at hc
      obtain ⟨hk2, rfl, rfl⟩ := hc
      obtain ⟨va, s1, β1, hrun1, r1, hf1⟩ := iha Γ M _ _ _ σ β s h1 (by simpa [fv] using r)
      obtain ⟨m, hm, ho1⟩ := r1.intOf hf1 hk1
      rw [ho1] at r1
      obtain ⟨vb, s2, β2, hrun2, r2, hf2⟩ := ihb Γ M1 L _ _ σ β1 s1 h2 r1
      obtain ⟨n, hn, ho2⟩ := r2.intOf hf2 hk2
      rw [ho2] at r2
      refine ⟨.int (m + n), s2, β2, ?_, r2, ⟨_, rfl⟩⟩
      simp only [eval, StateT.run_bind, hrun1, except_ok_bind, hm, hrun2, hn]
      rfl

theorem upd_upd [DecidableEq α] (f : α → Option β) (a : α) (b c : Option β) :
    upd (upd f a b) a c = upd f a c := by
  funext a'; by_cases h : a' = a <;> simp [upd, h]

theorem upd_comm [DecidableEq α] (f : α → Option β) {a a' : α} (b c : Option β) (h : a ≠ a') :
    upd (upd f a b) a' c = upd (upd f a' c) a b := by
  funext z; by_cases h1 : z = a <;> by_cases h2 : z = a' <;> simp_all [upd]

/-- `β` with `x`'s box now at `b`. -/
def reboxed (β : Var → Loc) (x : Var) (b : Loc) : Var → Loc := fun z => if z = x then b else β z

theorem reboxed_other {β : Var → Loc} {x z b} (h : z ≠ x) : reboxed β x b z = β z := by
  simp [reboxed, h]

theorem reboxed_self {β : Var → Loc} {x b} : reboxed β x b x = b := by
  simp [reboxed]

theorem reboxed_same (β : Var → Loc) (x : Var) : reboxed β x (β x) = β := by
  funext z; by_cases h : z = x <;> simp [reboxed, h]

theorem mem_filter_ne {M : List Var} {x z : Var} : z ∈ M.filter (· ≠ x) ↔ z ∈ M ∧ z ≠ x := by
  simp

/-- Storing a value of the owner's type in an owner that moved out:
the owner holds it again, and a box in hand becomes the owner's box. -/
theorem Rel.storeIn {Γ M L σ β s} {x τx c w} (r : Rel Γ M L σ β s (owned w))
    (hx : Γ.lookup x = some τx) (hxm : x ∈ M) (hh : s.heap (σ x) = some c)
    (hno : ∀ z m, Γ.lookup z = some (.view m x) → z ∈ L → False)
    (hw : (τx = .int ∧ ∃ n, w = .int n) ∨
      (τx = .box ∧ ∃ b cb n, w = .box b ∧ s.heap b = some cb ∧ cb.val = some (.int n))) :
    Rel Γ (M.filter (· ≠ x)) L σ (reboxed β x (match w with | .box b => b | _ => β x))
      { s with heap := upd s.heap (σ x) (some (c.ownerWrite (some w))) } [] := by
  have ne_of_ty : ∀ z τ, Γ.lookup z = some τ → τ ≠ τx → z ≠ x := by
    rintro z τ hz hne rfl; rw [hx] at hz; cases hz; exact hne rfl
  have hslot : ∀ z τ, Γ.lookup z = some τ → z ≠ x → σ z ≠ σ x :=
    fun z τ hz hzx h => hzx (r.slot_inj z x τ τx hz hx h)
  rcases hw with ⟨rfl, n, rfl⟩ | ⟨rfl, b, cb, n, rfl, hcb, hn⟩
  · simp only [reboxed_same]
    exact {
      env := r.env
      slot := fun z τ hz => by
        by_cases hzx : z = x
        · subst hzx; rw [hx] at hz; cases hz
          exact ⟨c.ownerWrite (some (.int n)), by simp, by simp [Shape, Cell.ownerWrite]⟩
        · obtain ⟨c0, hc0, hs⟩ := r.slot z τ hz
          exact ⟨c0, by simp [upd_other _ _ (hslot z τ hz hzx), hc0], by simpa [Shape, hzx] using hs⟩
      boxes := fun z hz hzm => by
        have hzx := ne_of_ty z _ hz (by simp)
        have hzm' : z ∉ M := by simpa [hzx] using hzm
        simpa [upd_other _ _ (r.box_slot z x _ hz hzm' hx)] using r.boxes z hz hzm'
      ctx := r.ctx
      views := fun z m y c0 b t hz hzm hzl hc0 hv0 => by
        have hzx := ne_of_ty z _ hz (by simp)
        have hzm' : z ∉ M := by simpa [hzx] using hzm
        simp only [upd_other _ _ (hslot z _ hz hzx)] at hc0
        obtain ⟨hym, hb, cb, hcb, hl⟩ := r.views z m y c0 b t hz hzm' hzl hc0 hv0
        have hyx : y ≠ x := by rintro rfl; exact hno z m hz hzl
        obtain ⟨τy, hy, -⟩ := r.ctx z m y hz
        have hbx : b ≠ σ x := fun h => hyx (r.slot_inj y x τy _ hy hx (hb.symm.trans h))
        exact ⟨by simp [hym], hb, cb, by simp [upd_other _ _ hbx, hcb], hl⟩
      slot_inj := r.slot_inj
      box_slot := fun z y τ hz hzm hy => by
        have hzx := ne_of_ty z _ hz (by simp)
        exact r.box_slot z y τ hz (by simpa [hzx] using hzm) hy
      box_inj := fun z y hz hzm hy hym => by
        have hzx := ne_of_ty z _ hz (by simp)
        have hyx := ne_of_ty y _ hy (by simp)
        exact r.box_inj z y hz (by simpa [hzx] using hzm) hy (by simpa [hyx] using hym)
      ex_sep := by simp
      dom := fun l c' hl => by
        by_cases he : l = σ x
        · exact Or.inl ⟨x, _, hx, he.symm⟩
        · simp only [upd_other _ _ he] at hl
          rcases r.dom l c' hl with h | ⟨z, hz, hzm, hb⟩ | h
          · exact Or.inl h
          · exact Or.inr (Or.inl ⟨z, hz, by simp [hzm], hb⟩)
          · simp [owned] at h
      bound := fun l c' hl => by
        by_cases he : l = σ x
        · subst he; exact r.bound _ c hh
        · exact r.bound l c' (by simpa [upd_other _ _ he] using hl) }
  · have hbsep := r.ex_sep b (by simp [owned])
    have hbx : b ≠ σ x := fun h => hbsep.1 x _ hx h.symm
    exact {
      env := r.env
      slot := fun z τ hz => by
        by_cases hzx : z = x
        · subst hzx; rw [hx] at hz; cases hz
          exact ⟨c.ownerWrite (some (.box b)), by simp, by simp [Shape, Cell.ownerWrite, reboxed_self]⟩
        · obtain ⟨c0, hc0, hs⟩ := r.slot z τ hz
          exact ⟨c0, by simp [upd_other _ _ (hslot z τ hz hzx), hc0],
            by simpa [Shape, hzx, reboxed_other hzx] using hs⟩
      boxes := fun z hz hzm => by
        by_cases hzx : z = x
        · subst hzx
          exact ⟨cb, n, by simp [reboxed_self, upd_other _ _ hbx, hcb], hn⟩
        · have hzm' : z ∉ M := by simpa [hzx] using hzm
          simpa [reboxed_other hzx, upd_other _ _ (r.box_slot z x _ hz hzm' hx)] using r.boxes z hz hzm'
      ctx := r.ctx
      views := fun z m y c0 b' t hz hzm hzl hc0 hv0 => by
        have hzx := ne_of_ty z _ hz (by simp)
        have hzm' : z ∉ M := by simpa [hzx] using hzm
        simp only [upd_other _ _ (hslot z _ hz hzx)] at hc0
        obtain ⟨hym, hb, cb', hcb', hl⟩ := r.views z m y c0 b' t hz hzm' hzl hc0 hv0
        have hyx : y ≠ x := by rintro rfl; exact hno z m hz hzl
        obtain ⟨τy, hy, -⟩ := r.ctx z m y hz
        have hbx' : b' ≠ σ x := fun h => hyx (r.slot_inj y x τy _ hy hx (hb.symm.trans h))
        exact ⟨by simp [hym], hb, cb',
          by simp [upd_other _ _ hbx', hcb'], hl⟩
      slot_inj := r.slot_inj
      box_slot := fun z y τ hz hzm hy => by
        by_cases hzx : z = x
        · subst hzx; rw [reboxed_self]; exact fun h => hbsep.1 y τ hy h.symm
        · rw [reboxed_other hzx]; exact r.box_slot z y τ hz (by simpa [hzx] using hzm) hy
      box_inj := fun z y hz hzm hy hym => by
        by_cases hzx : z = x <;> by_cases hyx : y = x
        · exact fun _ => hzx.trans hyx.symm
        · subst hzx
          have hym' : y ∉ M := by simpa [hyx] using hym
          rw [reboxed_self, reboxed_other hyx]
          exact fun h => absurd h.symm (hbsep.2 y hy hym')
        · subst hyx
          have hzm' : z ∉ M := by simpa [hzx] using hzm
          rw [reboxed_self, reboxed_other hzx]
          exact fun h => absurd h (hbsep.2 z hz hzm')
        · rw [reboxed_other hzx, reboxed_other hyx]
          exact r.box_inj z y hz (by simpa [hzx] using hzm) hy (by simpa [hyx] using hym)
      ex_sep := by simp
      dom := fun l c' hl => by
        by_cases he : l = σ x
        · exact Or.inl ⟨x, _, hx, he.symm⟩
        · simp only [upd_other _ _ he] at hl
          rcases r.dom l c' hl with h | ⟨z, hz, hzm, hb⟩ | h
          · exact Or.inl h
          · have hzx : z ≠ x := by rintro rfl; exact hzm hxm
            exact Or.inr (Or.inl ⟨z, hz, by simp [hzm], by rw [reboxed_other hzx]; exact hb⟩)
          · simp [owned] at h; subst h
            exact Or.inr (Or.inl ⟨x, hx, by simp, reboxed_self⟩)
      bound := fun l c' hl => by
        by_cases he : l = σ x
        · subst he; exact r.bound _ c hh
        · exact r.bound l c' (by simpa [upd_other _ _ he] using hl) }

/-- A write view's write keeps its own loan. -/
theorem filter_not_eq (M : List Var) (x : Var) :
    M.filter (fun z => !decide (z = x)) = M.filter (· ≠ x) := by
  simp only [ne_eq, decide_not]

theorem viewWrite_keeps {c : Cell} {m t v} (hm : Access.through.ends m = false) (h : c.live m t = true) :
    (c.viewWrite v).live m t = true := by
  cases m <;> simp_all [Access.ends, Cell.live, Cell.viewWrite]

/-- Storing the box in hand through a write view of a box's owner: the
owner holds the new box, and its old box is in hand. -/
theorem Rel.swapBox {Γ M L σ β s b} (r : Rel Γ M L σ β s [b]) {y}
    (hy : Γ.lookup y = some .box) (hym : y ∉ M) {c c' : Cell} (hc : s.heap (σ y) = some c)
    (hval : c'.val = some (.box b)) {cb n} (hcb : s.heap b = some cb) (hn : cb.val = some (.int n))
    (hloan : ∀ z m, Γ.lookup z = some (.view m y) → z ∈ L → z ∉ M →
      ∀ t, c.live m t = true → c'.live m t = true) :
    Rel Γ M L σ (reboxed β y b) { s with heap := upd s.heap (σ y) (some c') } [β y] where
  env := r.env
  slot x τx hx := by
    by_cases hxy : x = y
    · subst hxy; rw [hx] at hy; cases hy
      exact ⟨c', by simp, by simp [Shape, hym, hval, reboxed_self]⟩
    · have hne : σ x ≠ σ y := fun h => hxy (r.slot_inj x y τx _ hx hy h)
      obtain ⟨c0, hc0, hs⟩ := r.slot x τx hx
      exact ⟨c0, by simp [upd_other _ _ hne, hc0], by rw [reboxed_other hxy]; exact hs⟩
  boxes x hx hxm := by
    by_cases hxy : x = y
    · subst hxy
      have hbs : b ≠ σ x := fun h => (r.ex_sep b (by simp)).1 x _ hx h.symm
      exact ⟨cb, n, by simp [reboxed_self, upd_other _ _ hbs, hcb], hn⟩
    · have hne : β x ≠ σ y := r.box_slot x y _ hx hxm hy
      rw [reboxed_other hxy]
      simpa [upd_other _ _ hne] using r.boxes x hx hxm
  ctx := r.ctx
  views x m y' c0 b' t hx hxm hxl hc0 hv := by
    have hne : σ x ≠ σ y := by
      intro he
      have := r.slot_inj x y _ _ hx hy he
      subst this; rw [hx] at hy; cases hy
    simp only [upd_other _ _ hne] at hc0
    obtain ⟨hy'm, hb, cb0, hcb0, hl⟩ := r.views x m y' c0 b' t hx hxm hxl hc0 hv
    refine ⟨hy'm, hb, ?_⟩
    by_cases he : b' = σ y
    · obtain ⟨τ', hy', -⟩ := r.ctx x m y' hx
      have := r.slot_inj y' y τ' _ hy' hy (hb.symm.trans he)
      subst this
      rw [he, hc] at hcb0; cases hcb0
      exact ⟨c', by simp [he], hloan x m hx hxl hxm t hl⟩
    · exact ⟨cb0, by simpa [upd_other _ _ he] using hcb0, hl⟩
  slot_inj := r.slot_inj
  box_slot x w τ hx hxm hw := by
    by_cases hxy : x = y
    · subst hxy; rw [reboxed_self]; exact fun h => (r.ex_sep b (by simp)).1 w τ hw h.symm
    · rw [reboxed_other hxy]; exact r.box_slot x w τ hx hxm hw
  box_inj x w hx hxm hw hwm := by
    have hsep := (r.ex_sep b (by simp)).2
    by_cases hxy : x = y <;> by_cases hwy : w = y
    · exact fun _ => hxy.trans hwy.symm
    · subst hxy; rw [reboxed_self, reboxed_other hwy]
      exact fun h => absurd h.symm (hsep w hw hwm)
    · subst hwy; rw [reboxed_self, reboxed_other hxy]
      exact fun h => absurd h (hsep x hx hxm)
    · rw [reboxed_other hxy, reboxed_other hwy]; exact r.box_inj x w hx hxm hw hwm
  ex_sep l hl := by
    simp at hl; subst hl
    refine ⟨fun x τ hx h => r.box_slot y x τ hy hym hx h.symm, fun x hx hxm => ?_⟩
    by_cases hxy : x = y
    · subst hxy; rw [reboxed_self]; exact fun h => (r.ex_sep b (by simp)).2 x hx hxm h.symm
    · rw [reboxed_other hxy]; exact fun h => hxy (r.box_inj x y hx hxm hy hym h)
  dom l c'' hl := by
    by_cases he : l = σ y
    · exact Or.inl ⟨y, _, hy, he.symm⟩
    · simp only [upd_other _ _ he] at hl
      rcases r.dom l c'' hl with h | ⟨x, hx, hxm, hxl⟩ | h
      · exact Or.inl h
      · by_cases hxy : x = y
        · subst hxy; exact Or.inr (Or.inr (by simp [hxl]))
        · exact Or.inr (Or.inl ⟨x, hx, hxm, by rw [reboxed_other hxy]; exact hxl⟩)
      · simp at h; subst h
        exact Or.inr (Or.inl ⟨y, hy, hym, reboxed_self⟩)
  bound l c'' hl := by
    by_cases he : l = σ y
    · subst he; exact r.bound _ c hc
    · exact r.bound l c'' (by simpa [upd_other _ _ he] using hl)

theorem sound_assign (x : Var) (e : Expr) (ih : Sound e) : Sound (.assign x e) := by
  intro Γ M L τ M' σ β s hc r
  simp only [check] at hc
  cases h1 : check Γ M (x :: L) e with
  | none => simp [h1] at hc
  | some p =>
    obtain ⟨τe, Me⟩ := p
    simp only [h1] at hc
    cases hx : Γ.lookup x with
    | none => simp [hx] at hc
    | some τx =>
      have rIH : Rel Γ M (fv e ++ x :: L) σ β s [] :=
        r.mono (fun z hz => by simp [fv] at hz ⊢; rcases hz with h | h | h <;> simp [h])
      obtain ⟨v, s1, β1, hrun, r1, hf⟩ := ih Γ M (x :: L) _ _ σ β s h1 rIH
      have he := r1.env x τx hx
      obtain ⟨c, hh, hs⟩ := r1.slot x τx hx
      have rL := r1.mono (Live' := L) (fun _ h => List.mem_cons_of_mem _ h)
      cases τx with
      | int =>
        simp [hx] at hc
        obtain ⟨⟨rfl, ha⟩, rfl, rfl⟩ := hc
        obtain ⟨n, rfl⟩ := hf
        have hno := r.noViews hx (L := L) (by simp [Ty.owner, ha])
        rw [filter_not_eq]
        by_cases hxm : x ∈ Me
        · simp [Shape, hxm] at hs
          have r2 := rL.storeIn hx hxm hh hno (Or.inl ⟨rfl, n, rfl⟩)
          refine ⟨.unit, _, _, ?_, r2, rfl⟩
          simp only [eval, StateT.run_bind, hrun, except_ok_bind]
          simp [slotOf, cell, he, hh, hs, setCell]
        · simp [Shape, hxm] at hs
          obtain ⟨k, hv⟩ := hs
          have r2 := rL.moveOut hx hxm hh hv hno
          have r3 := (r2 : Rel Γ (x :: Me) L σ β1 _ (owned (Val.int n))).storeIn (c := c.ownerWrite none) hx (by simp) (by simp)
            hno (Or.inl ⟨rfl, n, rfl⟩)
          have hM : (x :: Me).filter (· ≠ x) = Me.filter (· ≠ x) := by simp
          rw [hM] at r3
          refine ⟨.unit, { s1 with heap := upd s1.heap (σ x) (some (c.ownerWrite (some (.int n)))) }, _, ?_,
            r3.congr (by simp only [upd_upd]; rfl) rfl (Nat.le_refl _), rfl⟩
          simp only [eval, StateT.run_bind, hrun, except_ok_bind]
          simp [slotOf, cell, he, hh, hv, setCell, dropVal]
      | box =>
        simp [hx] at hc
        obtain ⟨⟨rfl, ha⟩, rfl, rfl⟩ := hc
        obtain ⟨b, cb, n, rfl, hcb, hn⟩ := hf
        have hno := r.noViews hx (L := L) (by simp [Ty.owner, ha])
        rw [filter_not_eq]
        have hbsep := r1.ex_sep b (by simp [owned])
        by_cases hxm : x ∈ Me
        · simp [Shape, hxm] at hs
          have r2 := rL.storeIn hx hxm hh hno (Or.inr ⟨rfl, b, cb, n, rfl, hcb, hn⟩)
          refine ⟨.unit, _, _, ?_, r2, rfl⟩
          simp only [eval, StateT.run_bind, hrun, except_ok_bind]
          simp [slotOf, cell, he, hh, hs, setCell]
        · simp [Shape, hxm] at hs
          obtain ⟨c0, k, hc0, hk⟩ := r1.boxes x hx hxm
          have hb0 : β1 x ≠ σ x := r1.box_slot x x _ hx hxm hx
          have hbb0 : b ≠ β1 x := fun h => hbsep.2 x hx hxm h.symm
          have hbx : b ≠ σ x := fun h => hbsep.1 x _ hx h.symm
          have r2 := rL.moveOut hx hxm hh hs hno
          have r3 := (r2 : Rel Γ (x :: Me) L σ β1 _ (β1 x :: owned (Val.box b))).freeEx
          have r4 := (r3 : Rel Γ (x :: Me) L σ β1 _ (owned (Val.box b))).storeIn (c := c.ownerWrite none) hx (by simp)
            (by simp [upd_other _ _ hb0.symm]) hno
            (Or.inr ⟨rfl, b, cb, n, rfl, by simp [upd_other _ _ hbb0, upd_other _ _ hbx, hcb], hn⟩)
          have hM : (x :: Me).filter (· ≠ x) = Me.filter (· ≠ x) := by simp
          rw [hM] at r4
          refine ⟨.unit,
            { s1 with heap := upd (upd s1.heap (σ x) (some (c.ownerWrite (some (.box b))))) (β1 x) none }, _, ?_,
            r4.congr (by simp only [upd_comm _ _ _ hb0, upd_upd]; rfl) rfl (Nat.le_refl _), rfl⟩
          simp only [eval, StateT.run_bind, hrun, except_ok_bind]
          simp [slotOf, cell, he, hh, hs, setCell, dropVal, free, upd_other _ _ hb0, hc0]
      | view m y =>
        cases m with
        | read => simp [hx] at hc
        | write =>
          simp [hx] at hc
          obtain ⟨⟨⟨hτe, hxm⟩, ha⟩, rfl, rfl⟩ := hc
          simp [Shape, hxm] at hs
          obtain ⟨b, t, hv⟩ := hs
          obtain ⟨hym, rfl, cb, hcb, hl⟩ := r1.views x .write y c b t hx hxm (by simp) hh hv
          obtain ⟨τy, hy, ho⟩ := r1.ctx x .write y hx
          rw [hτe] at hy; cases hy
          obtain ⟨c2, hc2, hs2⟩ := r1.slot y τe hτe
          rw [hcb] at hc2; cases hc2
          rcases Ty.owner_cases ho with rfl | rfl
          · obtain ⟨n, rfl⟩ := hf
            simp [Shape, hym] at hs2
            obtain ⟨k, hk⟩ := hs2
            have r2 := rL.touch hτe rfl hcb (c' := cb.viewWrite (.int n))
              (by simp [Shape, hym, Cell.viewWrite])
              (fun z m' hz hzl _ t' hl' => viewWrite_keeps (allows_spec ha hz hzl) hl')
            refine ⟨.unit, _, β1, ?_, r2, rfl⟩
            simp only [eval, StateT.run_bind, hrun, except_ok_bind]
            simp [slotOf, cell, he, hh, hv, hcb, hl, setCell, hk, dropVal]
          · obtain ⟨b', cb', n, rfl, hcb', hn⟩ := hf
            simp [Shape, hym] at hs2
            have hb0 : β1 y ≠ σ y := r1.box_slot y y _ hτe hym hτe
            obtain ⟨c0, k, hc0, -⟩ := r1.boxes y hτe hym
            have r2 := (rL : Rel Γ Me L σ β1 s1 [b']).swapBox hτe hym hcb
              (c' := cb.viewWrite (.box b')) (by simp [Cell.viewWrite]) hcb' hn
              (fun z m' hz hzl _ t' hl' => viewWrite_keeps (allows_spec ha hz hzl) hl')
            refine ⟨.unit, _, _, ?_, r2.freeEx, rfl⟩
            simp only [eval, StateT.run_bind, hrun, except_ok_bind]
            simp [slotOf, cell, he, hh, hv, hcb, hl, setCell, hs2, dropVal, free, upd_other _ _ hb0, hc0]
      | unit => simp [hx] at hc

/-- The box a value owns, or `d`. -/
def boxOr (v : Val) (d : Loc) : Loc :=
  match v with
  | .box b => b
  | _ => d

/-- A value's type says whether it is a box. -/
theorem VFits.box_iff {Γ M σ β s τ v} (hf : VFits Γ M σ β s τ v) {b} (hv : v = .box b) : τ = .box := by
  subst hv; cases τ <;> simp [VFits] at hf ⊢

/-- A `let` binds the value in hand to a new name in a new place. -/
theorem Rel.bind {Γ Me Lb σ β s x τe v} (r : Rel Γ Me Lb σ β s (owned v))
    (hf : VFits Γ Me σ β s τe v) (hxΓ : Γ.lookup x = none) (hxM : x ∉ Me)
    {Live : List Var} (hLive : ∀ z ∈ Live, z ≠ x → z ∈ Lb) :
    Rel ((x, τe) :: Γ) Me Live (reboxed σ x s.next) (reboxed β x (boxOr v (β x)))
      { s with next := s.next + 1, heap := upd s.heap s.next (some (Cell.fresh v)),
               env := upd s.env x (some s.next) } [] := by
  have hne : ∀ z τ, Γ.lookup z = some τ → z ≠ x := by
    rintro z τ hz rfl; rw [hxΓ] at hz; cases hz
  have hσ : ∀ z τ, Γ.lookup z = some τ → σ z ≠ s.next := fun z τ hz => by
    obtain ⟨c, hc, -⟩ := r.slot z τ hz; exact r.ne_next hc
  have hβ : ∀ z, Γ.lookup z = some .box → z ∉ Me → β z ≠ s.next := fun z hz hzm => by
    obtain ⟨c, n, hc, -⟩ := r.boxes z hz hzm; exact r.ne_next hc
  have hvbox : ∀ b, v = .box b → τe = .box ∧ (∃ cb n, s.heap b = some cb ∧ cb.val = some (.int n)) ∧
      b ≠ s.next ∧ (∀ z τ, Γ.lookup z = some τ → σ z ≠ b) ∧
      (∀ z, Γ.lookup z = some .box → z ∉ Me → β z ≠ b) := by
    rintro b rfl
    have hτ := hf.box_iff rfl; subst hτ
    obtain ⟨b', cb, n, hb', hcb, hn⟩ := hf
    cases hb'
    exact ⟨rfl, ⟨cb, n, hcb, hn⟩, r.ne_next hcb, (r.ex_sep b (by simp [owned])).1,
      (r.ex_sep b (by simp [owned])).2⟩
  exact {
    env := fun z τ hz => by
      by_cases hzx : z = x
      · subst hzx; simp [reboxed_self]
      · simp [upd_other _ _ hzx, reboxed_other hzx]
        rw [lookup_cons_other hzx] at hz; exact r.env z τ hz
    slot := fun z τ hz => by
      by_cases hzx : z = x
      · subst hzx; rw [lookup_cons_self] at hz; cases hz
        refine ⟨Cell.fresh v, by simp [reboxed_self], ?_⟩
        simp only [Shape, hxM, ite_false, Cell.fresh, reboxed_self]
        cases τe with
        | unit => exact congrArg some hf
        | int => obtain ⟨n, rfl⟩ := hf; exact ⟨n, rfl⟩
        | box => obtain ⟨b, cb, n, rfl, -⟩ := hf; rfl
        | view m y => obtain ⟨t, rfl, -⟩ := hf; exact ⟨_, t, rfl⟩
      · rw [lookup_cons_other hzx] at hz
        obtain ⟨c, hc, hs⟩ := r.slot z τ hz
        exact ⟨c, by simp [reboxed_other hzx, upd_other _ _ (hσ z τ hz), hc],
          by rw [reboxed_other hzx]; exact hs⟩
    boxes := fun z hz hzm => by
      by_cases hzx : z = x
      · subst hzx; rw [lookup_cons_self] at hz; cases hz
        obtain ⟨b, cb, n, rfl, hcb, hn⟩ := hf
        obtain ⟨-, -, hbn, -⟩ := hvbox b rfl
        exact ⟨cb, n, by simp [reboxed_self, boxOr, upd_other _ _ hbn, hcb], hn⟩
      · rw [lookup_cons_other hzx] at hz
        obtain ⟨c, n, hc, hn⟩ := r.boxes z hz hzm
        exact ⟨c, n, by simp [reboxed_other hzx, upd_other _ _ (hβ z hz hzm), hc], hn⟩
    ctx := fun z m y hz => by
      by_cases hzx : z = x
      · subst hzx; rw [lookup_cons_self] at hz; cases hz
        obtain ⟨t, -, -, ⟨τy, hy, ho⟩, -⟩ := hf
        exact ⟨τy, by rw [lookup_cons_other (hne y τy hy)]; exact hy, ho⟩
      · rw [lookup_cons_other hzx] at hz
        obtain ⟨τy, hy, ho⟩ := r.ctx z m y hz
        exact ⟨τy, by rw [lookup_cons_other (hne y τy hy)]; exact hy, ho⟩
    views := fun z m y c b t hz hzm hzl hc hv => by
      by_cases hzx : z = x
      · subst hzx; rw [lookup_cons_self] at hz; cases hz
        simp [reboxed_self] at hc; subst hc
        simp [Cell.fresh] at hv; subst hv
        obtain ⟨t', hv', hym, ⟨τy, hy, -⟩, cb, hcb, hl⟩ := hf
        cases hv'
        exact ⟨hym, (reboxed_other (hne y τy hy)).symm, cb,
          by simp [upd_other _ _ (hσ y τy hy), hcb], hl⟩
      · rw [lookup_cons_other hzx] at hz
        simp [reboxed_other hzx, upd_other _ _ (hσ z _ hz)] at hc
        obtain ⟨hym, hb, cb, hcb, hl⟩ := r.views z m y c b t hz hzm (hLive z hzl hzx) hc hv
        obtain ⟨τy, hy, -⟩ := r.ctx z m y hz
        exact ⟨hym, by rw [reboxed_other (hne y τy hy)]; exact hb, cb,
          by simp [upd_other _ _ (r.ne_next hcb), hcb], hl⟩
    slot_inj := fun z w τ τ' hz hw h => by
      by_cases hzx : z = x <;> by_cases hwx : w = x
      · rw [hzx, hwx]
      · subst hzx; rw [lookup_cons_other hwx] at hw
        simp [reboxed_self, reboxed_other hwx] at h
        exact absurd h.symm (hσ w τ' hw)
      · subst hwx; rw [lookup_cons_other hzx] at hz
        simp [reboxed_self, reboxed_other hzx] at h
        exact absurd h (hσ z τ hz)
      · rw [lookup_cons_other hzx] at hz; rw [lookup_cons_other hwx] at hw
        simp [reboxed_other hzx, reboxed_other hwx] at h
        exact r.slot_inj z w τ τ' hz hw h
    box_slot := fun z w τ hz hzm hw => by
      by_cases hzx : z = x <;> by_cases hwx : w = x
      · subst hzx; subst hwx; rw [lookup_cons_self] at hz; cases hz
        obtain ⟨b, cb, n, rfl, -⟩ := hf
        obtain ⟨-, -, hbn, -⟩ := hvbox b rfl
        simp [reboxed_self, boxOr]; exact hbn
      · subst hzx; rw [lookup_cons_self] at hz; cases hz; rw [lookup_cons_other hwx] at hw
        obtain ⟨b, cb, n, rfl, -⟩ := hf
        obtain ⟨-, -, -, hσb, -⟩ := hvbox b rfl
        simp [reboxed_self, reboxed_other hwx, boxOr]; exact fun h => hσb w τ hw h.symm
      · subst hwx; rw [lookup_cons_other hzx] at hz
        simp [reboxed_self, reboxed_other hzx]; exact hβ z hz hzm
      · rw [lookup_cons_other hzx] at hz; rw [lookup_cons_other hwx] at hw
        simp [reboxed_other hzx, reboxed_other hwx]; exact r.box_slot z w τ hz hzm hw
    box_inj := fun z w hz hzm hw hwm h => by
      by_cases hzx : z = x <;> by_cases hwx : w = x
      · rw [hzx, hwx]
      · subst hzx; rw [lookup_cons_self] at hz; cases hz; rw [lookup_cons_other hwx] at hw
        obtain ⟨b, cb, n, rfl, -⟩ := hf
        obtain ⟨-, -, -, -, hβb⟩ := hvbox b rfl
        simp [reboxed_self, reboxed_other hwx, boxOr] at h
        exact absurd h.symm (hβb w hw hwm)
      · subst hwx; rw [lookup_cons_self] at hw; cases hw; rw [lookup_cons_other hzx] at hz
        obtain ⟨b, cb, n, rfl, -⟩ := hf
        obtain ⟨-, -, -, -, hβb⟩ := hvbox b rfl
        simp [reboxed_self, reboxed_other hzx, boxOr] at h
        exact absurd h (hβb z hz hzm)
      · rw [lookup_cons_other hzx] at hz; rw [lookup_cons_other hwx] at hw
        simp [reboxed_other hzx, reboxed_other hwx] at h
        exact r.box_inj z w hz hzm hw hwm h
    ex_sep := by simp
    dom := fun l c hl => by
      by_cases hln : l = s.next
      · exact Or.inl ⟨x, τe, lookup_cons_self, by simp [reboxed_self, hln]⟩
      · simp only [upd_other _ _ hln] at hl
        rcases r.dom l c hl with ⟨z, τ, hz, hzl⟩ | ⟨z, hz, hzm, hzl⟩ | hl'
        · have hzx := hne z τ hz
          exact Or.inl ⟨z, τ, by rw [lookup_cons_other hzx]; exact hz, by rw [reboxed_other hzx]; exact hzl⟩
        · have hzx := hne z _ hz
          exact Or.inr (Or.inl ⟨z, by rw [lookup_cons_other hzx]; exact hz, hzm,
            by rw [reboxed_other hzx]; exact hzl⟩)
        · cases v with
          | box b =>
            simp [owned] at hl'; subst hl'
            obtain ⟨hτ, -⟩ := hvbox l rfl; subst hτ
            exact Or.inr (Or.inl ⟨x, lookup_cons_self, hxM, by simp [reboxed_self, boxOr]⟩)
          | _ => simp [owned] at hl'
    bound := fun l c hl => by
      by_cases hln : l = s.next
      · subst hln; exact Nat.lt_succ_self _
      · simp only [upd_other _ _ hln] at hl
        exact Nat.lt_succ_of_lt (r.bound l c hl) }

/-- The cells a place's value owns. -/
def ownedIn : Option Val → List Loc
  | some v => owned v
  | none => []

/-- The only cell a name's own place can own is the box the name holds. -/
theorem Rel.slot_owned {Γ M L σ β s ex x τ c} (r : Rel Γ M L σ β s ex) (hx : Γ.lookup x = some τ)
    (hc : s.heap (σ x) = some c) {b} (hb : b ∈ ownedIn c.val) : x ∉ M ∧ τ = .box ∧ b = β x := by
  obtain ⟨c', hc', hsh⟩ := r.slot x τ hx
  rw [hc] at hc'; injection hc' with h; subst h
  by_cases hxm : x ∈ M
  · simp [Shape, hxm] at hsh; simp [hsh, ownedIn] at hb
  · simp only [Shape, hxm, ite_false] at hsh
    cases τ with
    | box => simp [hsh, ownedIn, owned] at hb; exact ⟨hxm, rfl, hb⟩
    | unit => simp [hsh, ownedIn, owned] at hb
    | int => obtain ⟨n, hn⟩ := hsh; simp [hn, ownedIn, owned] at hb
    | view m y => obtain ⟨b', t, hv⟩ := hsh; simp [hv, ownedIn, owned] at hb

/-- Leaving a `let`: `x` leaves scope and its place is freed; the box it
held, if any, joins the cells in hand. -/
theorem Rel.unscope {Γ x τe M L σ β s w l c} (r : Rel ((x, τe) :: Γ) M L (reboxed σ x l) β s (owned w))
    (hxΓ : Γ.lookup x = none)
    (hctx : ∀ z m y, Γ.lookup z = some (.view m y) → ∃ τ, Γ.lookup y = some τ ∧ τ.owner = true)
    (hc : s.heap l = some c) {s0 : Machine} (h0 : s0.heap = upd s.heap l none)
    (he0 : ∀ z τ, Γ.lookup z = some τ → s0.env z = some (σ z)) (hn0 : s.next ≤ s0.next) :
    Rel Γ (M.filter (· ≠ x)) L σ β s0 (ownedIn c.val ++ owned w) := by
  have hne : ∀ z τ, Γ.lookup z = some τ → z ≠ x := by
    rintro z τ hz rfl; rw [hxΓ] at hz; cases hz
  have hlk : ∀ z τ, Γ.lookup z = some τ → ((x, τe) :: Γ).lookup z = some τ := fun z τ hz => by
    rw [lookup_cons_other (hne z τ hz)]; exact hz
  have hσ : ∀ z, z ≠ x → reboxed σ x l z = σ z := fun z hzx => reboxed_other hzx
  have hmem : ∀ z, z ≠ x → (z ∈ M.filter (· ≠ x) ↔ z ∈ M) := fun z hzx => by simp [hzx]
  have hσl : ∀ z τ, Γ.lookup z = some τ → σ z ≠ l := fun z τ hz h =>
    hne z τ hz (r.slot_inj z x τ τe (hlk z τ hz) lookup_cons_self
      (by rw [hσ z (hne z τ hz), reboxed_self]; exact h))
  have hβl : ∀ z, Γ.lookup z = some .box → z ∉ M → β z ≠ l := fun z hz hzm => by
    have := r.box_slot z x τe (hlk z _ hz) hzm lookup_cons_self; rwa [reboxed_self] at this
  have hcx : s.heap (reboxed σ x l x) = some c := by rw [reboxed_self]; exact hc
  have hll : ∀ l' c', s0.heap l' = some c' → l' ≠ l ∧ s.heap l' = some c' := fun l' c' h => by
    have hl' : l' ≠ l := by rintro rfl; simp [h0] at h
    rw [h0, upd_other _ _ hl'] at h; exact ⟨hl', h⟩
  exact {
    env := he0
    slot := fun z τ hz => by
      have hzx := hne z τ hz
      obtain ⟨c', hc', hs⟩ := r.slot z τ (hlk z τ hz)
      rw [hσ z hzx] at hc'
      refine ⟨c', by rw [h0, upd_other _ _ (hσl z τ hz)]; exact hc', ?_⟩
      simp only [Shape, hmem z hzx] at hs ⊢; exact hs
    boxes := fun z hz hzm => by
      have hzm' : z ∉ M := by rwa [hmem z (hne z _ hz)] at hzm
      obtain ⟨c', n, hc', hn⟩ := r.boxes z (hlk z _ hz) hzm'
      exact ⟨c', n, by rw [h0, upd_other _ _ (hβl z hz hzm')]; exact hc', hn⟩
    ctx := hctx
    views := fun z m y c' b t hz hzm hzl hc' hv => by
      have hzx := hne z _ hz
      have hzm' : z ∉ M := by rwa [hmem z hzx] at hzm
      rw [h0, upd_other _ _ (hσl z _ hz)] at hc'
      obtain ⟨hym, hb, cb, hcb, hl⟩ :=
        r.views z m y c' b t (hlk z _ hz) hzm' hzl (by rw [hσ z hzx]; exact hc') hv
      obtain ⟨τy, hy, -⟩ := hctx z m y hz
      rw [hσ y (hne y τy hy)] at hb
      have hbl : b ≠ l := hb ▸ hσl y τy hy
      exact ⟨by rw [hmem y (hne y τy hy)]; exact hym, hb, cb,
        by rw [h0, upd_other _ _ hbl]; exact hcb, hl⟩
    slot_inj := fun z w τ τ' hz hw h => r.slot_inj z w τ τ' (hlk z τ hz) (hlk w τ' hw)
      (by rw [hσ z (hne z τ hz), hσ w (hne w τ' hw)]; exact h)
    box_slot := fun z w τ hz hzm hw => by
      have hzm' : z ∉ M := by rwa [hmem z (hne z _ hz)] at hzm
      have := r.box_slot z w τ (hlk z _ hz) hzm' (hlk w τ hw)
      rwa [hσ w (hne w τ hw)] at this
    box_inj := fun z w hz hzm hw hwm h => r.box_inj z w (hlk z _ hz)
      (by rwa [hmem z (hne z _ hz)] at hzm) (hlk w _ hw) (by rwa [hmem w (hne w _ hw)] at hwm) h
    ex_sep := fun l' hl' => by
      rcases List.mem_append.1 hl' with hx | hw
      · obtain ⟨hxm, hτe, rfl⟩ := r.slot_owned lookup_cons_self hcx hx
        subst hτe
        refine ⟨fun z τ hz => ?_, fun z hz hzm => ?_⟩
        · have := r.box_slot x z τ lookup_cons_self hxm (hlk z τ hz)
          rw [hσ z (hne z τ hz)] at this; exact fun h => this h.symm
        · exact fun h => hne z _ hz (r.box_inj z x (hlk z _ hz)
            (by rwa [hmem z (hne z _ hz)] at hzm) lookup_cons_self hxm h)
      · obtain ⟨h1, h2⟩ := r.ex_sep l' hw
        exact ⟨fun z τ hz => by have := h1 z τ (hlk z τ hz); rwa [hσ z (hne z τ hz)] at this,
          fun z hz hzm => h2 z (hlk z _ hz) (by rwa [hmem z (hne z _ hz)] at hzm)⟩
    dom := fun l' c' hl' => by
      obtain ⟨hl'l, hl'⟩ := hll l' c' hl'
      rcases r.dom l' c' hl' with ⟨z, τ, hz, hzl⟩ | ⟨z, hz, hzm, hzl⟩ | hl''
      · by_cases hzx : z = x
        · rw [hzx, reboxed_self] at hzl; exact absurd hzl.symm hl'l
        · rw [lookup_cons_other hzx] at hz; rw [hσ z hzx] at hzl; exact Or.inl ⟨z, τ, hz, hzl⟩
      · by_cases hzx : z = x
        · rw [hzx] at hz hzm hzl
          rw [lookup_cons_self] at hz; cases hz
          obtain ⟨c'', hc'', hsh⟩ := r.slot x .box lookup_cons_self
          rw [hcx] at hc''; injection hc'' with h; subst h
          simp only [Shape, hzm, ite_false] at hsh
          exact Or.inr (Or.inr (List.mem_append_left _ (by simp [hsh, ownedIn, owned, hzl])))
        · rw [lookup_cons_other hzx] at hz
          exact Or.inr (Or.inl ⟨z, hz, by rwa [hmem z hzx], hzl⟩)
      · exact Or.inr (Or.inr (List.mem_append_right _ hl''))
    bound := fun l' c' hl' => Nat.lt_of_lt_of_le (r.bound l' c' (hll l' c' hl').2) hn0 }

/-- A value keeps its type when the names around it leave scope, as long
as it is no view of them. -/
theorem VFits.unscope {Γ x τe M σ β s τ w l} (hf : VFits ((x, τe) :: Γ) M (reboxed σ x l) β s τ w)
    (hτ : τ.lentFrom x = false) : VFits Γ (M.filter (· ≠ x)) σ β s τ w := by
  cases τ with
  | view m y =>
    have hyx : y ≠ x := by simpa [Ty.lentFrom] using hτ
    obtain ⟨t, hv, hym, ⟨τy, hy, ho⟩, cb, hcb, hl⟩ := hf
    rw [lookup_cons_other hyx] at hy
    rw [reboxed_other hyx] at hv hcb
    exact ⟨t, hv, fun h => hym (List.mem_filter.1 h).1, ⟨τy, hy, ho⟩, cb, hcb, hl⟩
  | _ => exact hf

/-- A value keeps its type while the cells it needs stay as they are. -/
theorem VFits.heap {Γ M σ β s τ v} (hf : VFits Γ M σ β s τ v) {s' : Machine}
    (h1 : ∀ b ∈ owned v, s'.heap b = s.heap b)
    (h2 : ∀ m y, τ = .view m y → s'.heap (σ y) = s.heap (σ y)) :
    VFits Γ M σ β s' τ v := by
  cases τ with
  | box =>
    obtain ⟨b, cb, n, rfl, hcb, hn⟩ := hf
    exact ⟨b, cb, n, rfl, by rw [h1 b (by simp [owned])]; exact hcb, hn⟩
  | view m y =>
    obtain ⟨t, hv, hym, hc, cb, hcb, hl⟩ := hf
    exact ⟨t, hv, hym, hc, cb, by rw [h2 m y rfl]; exact hcb, hl⟩
  | _ => exact hf

end LambdaRig
