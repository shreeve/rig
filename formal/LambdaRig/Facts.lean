/-
λRig: what the checker's facts say of a running machine.

`Rel Γ M L σ β s ex` says the machine `s` is what the checker believes at
one point of a program: each name in `Γ` lives at `σ`, each box an owner
holds is at `β`, the names in `M` have moved out, every view used in `L`
carries a live loan, no two owners share a cell, and the only other cells
are `ex`, which the value in hand owns. LambdaRig/Sound.lean proves that
each step the checker accepts keeps it.
-/
import LambdaRig.Check

namespace LambdaRig

/-! ## Except and lookups -/

@[simp] theorem except_pure (a : α) : (pure a : Except ε α) = .ok a := rfl
@[simp] theorem except_ok_bind (a : α) (f : α → Except ε β) : (Except.ok a >>= f) = f a := rfl
@[simp] theorem except_ok_map (a : α) (f : α → β) : (f <$> (Except.ok a : Except ε α)) = .ok (f a) := rfl
@[simp] theorem except_error_bind (e : ε) (f : α → Except ε β) :
    (Except.error e >>= f) = Except.error e := rfl

theorem mem_of_lookup {Γ : List (Var × β)} {x : Var} {b : β} (h : Γ.lookup x = some b) : (x, b) ∈ Γ := by
  induction Γ with
  | nil => simp at h
  | cons p Γ ih =>
    obtain ⟨y, c⟩ := p
    by_cases hxy : x = y
    · subst hxy; simp [List.lookup] at h; subst h; simp
    · have hb : (x == y) = false := by simp [hxy]
      have : List.lookup x ((y, c) :: Γ) = List.lookup x Γ := by simp [List.lookup, hb]
      rw [this] at h; exact List.mem_cons_of_mem _ (ih h)

theorem allows_spec {Γ : Ctx} {y k L} (h : allows Γ y k L = true) {z m}
    (hz : Γ.lookup z = some (.view m y)) (hl : z ∈ L) : k.ends m = false := by
  unfold allows at h
  have := List.all_eq_true.1 h _ (mem_of_lookup hz)
  simp at this
  rcases this with h1 | h1
  · exact absurd hl h1
  · exact h1


theorem lookup_cons_other {Γ : List (Var × β)} {x y : Var} {b : β} (h : y ≠ x) :
    List.lookup y ((x, b) :: Γ) = List.lookup y Γ := by
  have hb : (y == x) = false := by simp [h]
  simp [List.lookup, hb]

theorem lookup_cons_self {Γ : List (Var × β)} {x : Var} {b : β} :
    List.lookup x ((x, b) :: Γ) = some b := by simp [List.lookup]

/-- What `x`'s place holds, by its type: nothing once it moved out. -/
def Shape (M : List Var) (x : Var) (τ : Ty) (bx : Loc) (v : Option Val) : Prop :=
  if x ∈ M then v = none else
  match τ with
  | .unit => v = some .unit
  | .int => ∃ n, v = some (.int n)
  | .box => v = some (.box bx)
  | .view m _ => ∃ b t, v = some (.view m b t)

/-- The cells a value owns. -/
def owned : Val → List Loc
  | .box b => [b]
  | _ => []

/-- A value fits its type. A view's loan is live. -/
def VFits (Γ : Ctx) (M : List Var) (σ _β : Var → Loc) (s : Machine) : Ty → Val → Prop
  | .unit, v => v = .unit
  | .int, v => ∃ n, v = .int n
  | .box, v => ∃ b c n, v = .box b ∧ s.heap b = some c ∧ c.val = some (.int n)
  | .view m y, v => ∃ t, v = .view m (σ y) t ∧ y ∉ M ∧
      (∃ τ, Γ.lookup y = some τ ∧ τ.owner = true) ∧
      ∃ c, s.heap (σ y) = some c ∧ c.live m t = true

/-- The machine `s` is what the checker's facts say: the names in `Γ`
live at `σ`, the boxes their owners hold are at `β`, the views used in
`Live` see live loans on their owners' places, no two owners share a cell, and the only other
cells are `ex`, owned by the value in hand. -/
structure Rel (Γ : Ctx) (M Live : List Var) (σ β : Var → Loc) (s : Machine) (ex : List Loc) : Prop where
  env : ∀ x τ, Γ.lookup x = some τ → s.env x = some (σ x)
  slot : ∀ x τ, Γ.lookup x = some τ → ∃ c, s.heap (σ x) = some c ∧ Shape M x τ (β x) c.val
  boxes : ∀ x, Γ.lookup x = some .box → x ∉ M → ∃ c n, s.heap (β x) = some c ∧ c.val = some (.int n)
  ctx : ∀ x m y, Γ.lookup x = some (.view m y) → ∃ τ, Γ.lookup y = some τ ∧ τ.owner = true
  views : ∀ x m y c b t, Γ.lookup x = some (.view m y) → x ∉ M → x ∈ Live →
    s.heap (σ x) = some c → c.val = some (.view m b t) →
    y ∉ M ∧ b = σ y ∧ ∃ cb, s.heap b = some cb ∧ cb.live m t = true
  slot_inj : ∀ x y τ τ', Γ.lookup x = some τ → Γ.lookup y = some τ' → σ x = σ y → x = y
  box_slot : ∀ x y τ, Γ.lookup x = some .box → x ∉ M → Γ.lookup y = some τ → β x ≠ σ y
  box_inj : ∀ x y, Γ.lookup x = some .box → x ∉ M → Γ.lookup y = some .box → y ∉ M →
    β x = β y → x = y
  ex_sep : ∀ l ∈ ex, (∀ x τ, Γ.lookup x = some τ → σ x ≠ l) ∧
    (∀ x, Γ.lookup x = some .box → x ∉ M → β x ≠ l)
  dom : ∀ l c, s.heap l = some c → (∃ x τ, Γ.lookup x = some τ ∧ σ x = l) ∨
    (∃ x, Γ.lookup x = some .box ∧ x ∉ M ∧ β x = l) ∨ l ∈ ex
  bound : ∀ l c, s.heap l = some c → l < s.next

theorem Rel.mono {Γ M Live Live' σ β s ex} (r : Rel Γ M Live σ β s ex) (h : ∀ x, x ∈ Live' → x ∈ Live) :
    Rel Γ M Live' σ β s ex :=
  { r with views := fun x m y c b t h1 h2 h3 => r.views x m y c b t h1 h2 (h x h3) }

theorem Ty.owner_cases {τ : Ty} (h : τ.owner = true) : τ = .int ∨ τ = .box := by
  cases τ <;> simp_all [Ty.owner]

/-- Touching the loans on an owner's place, keeping a value of its type
there, keeps the facts, as long as every view used later keeps its loan. -/
theorem Rel.touch {Γ M Live σ β s ex} (r : Rel Γ M Live σ β s ex) {y τ}
    (hy : Γ.lookup y = some τ) (ho : τ.owner = true) {c c' : Cell} (hc : s.heap (σ y) = some c)
    (hval : Shape M y τ (β y) c'.val)
    (hloan : ∀ z m, Γ.lookup z = some (.view m y) → z ∈ Live → z ∉ M →
      ∀ t, c.live m t = true → c'.live m t = true) :
    Rel Γ M Live σ β { s with heap := upd s.heap (σ y) (some c') } ex where
  env := r.env
  slot x τx hx := by
    by_cases he : σ x = σ y
    · have := r.slot_inj x y τx τ hx hy he
      subst this; rw [hx] at hy; cases hy
      exact ⟨c', by simp, hval⟩
    · simpa [upd_other _ _ he] using r.slot x τx hx
  boxes x hx hxm := by
    have he : β x ≠ σ y := r.box_slot x y τ hx hxm hy
    simpa [upd_other _ _ he] using r.boxes x hx hxm
  ctx := r.ctx
  views x m y' c0 b t hx hxm hxl hc0 hv := by
    have hne : σ x ≠ σ y := by
      intro he
      have := r.slot_inj x y _ τ hx hy he
      subst this; rw [hx] at hy; cases hy; simp [Ty.owner] at ho
    simp only [upd_other _ _ hne] at hc0
    obtain ⟨hy'm, hb, cb, hcb, hl⟩ := r.views x m y' c0 b t hx hxm hxl hc0 hv
    refine ⟨hy'm, hb, ?_⟩
    by_cases he : b = σ y
    · obtain ⟨τ', hy', -⟩ := r.ctx x m y' hx
      have := r.slot_inj y' y τ' τ hy' hy (hb.symm.trans he)
      subst this
      rw [he] at hcb; rw [hc] at hcb; cases hcb
      exact ⟨c', by simp [he], hloan x m hx hxl hxm t hl⟩
    · exact ⟨cb, by simpa [upd_other _ _ he] using hcb, hl⟩
  slot_inj := r.slot_inj
  box_slot := r.box_slot
  box_inj := r.box_inj
  ex_sep := r.ex_sep
  dom l c'' hl := by
    by_cases he : l = σ y
    · exact Or.inl ⟨y, τ, hy, he.symm⟩
    · exact r.dom l c'' (by simpa [upd_other _ _ he] using hl)
  bound l c'' hl := by
    by_cases he : l = σ y
    · subst he; exact r.bound _ c hc
    · exact r.bound l c'' (by simpa [upd_other _ _ he] using hl)

/-! ## Each step of the machine, run -/

theorem run_cell {s : Machine} {l c} (h : s.heap l = some c) : (cell l).run s = .ok (c, s) := by
  simp [cell, h]

theorem run_setCell {s : Machine} {l c0} (c : Cell) (h : s.heap l = some c0) :
    (setCell l c).run s = .ok ((), { s with heap := upd s.heap l (some c) }) := by
  simp [setCell, h]

theorem run_free {s : Machine} {l c0} (h : s.heap l = some c0) :
    (free l).run s = .ok ((), { s with heap := upd s.heap l none }) := by
  simp [free, h]

theorem run_fresh (s : Machine) : fresh.run s = .ok (s.next, { s with next := s.next + 1 }) := by
  simp [fresh]

theorem run_alloc (s : Machine) (v : Val) :
    (alloc v).run s = .ok (s.next,
      { s with next := s.next + 1, heap := upd s.heap s.next (some (Cell.fresh v)) }) := by
  simp [alloc, fresh]

theorem run_held {s : Machine} {x l c v} (he : s.env x = some l) (hh : s.heap l = some c)
    (hv : c.val = some v) : (held x).run s = .ok ((l, c, v), s) := by
  simp [held, slotOf, cell, he, hh, hv]

theorem run_readBox {s : Machine} {b c n} (hh : s.heap b = some c) (hv : c.val = some (.int n)) :
    (readBox b).run s = .ok (n, s) := by
  simp [readBox, cell, hh, hv]

theorem run_seen {s : Machine} {m l t c v} (hh : s.heap l = some c) (hl : c.live m t = true)
    (hv : c.val = some v) : (seen m l t).run s = .ok (v, s) := by
  simp [seen, cell, hh, hl, hv]

/-- What a live view of a live owner sees: the Int the owner holds, or
the box it holds, which holds an Int. -/
theorem Rel.seen {Γ M Live σ β s ex} (r : Rel Γ M Live σ β s ex) {y τ}
    (hy : Γ.lookup y = some τ) (ho : τ.owner = true) (hm : y ∉ M) {m t c}
    (hc : s.heap (σ y) = some c) (hl : c.live m t = true) :
    (τ = .int ∧ ∃ n, (seen m (σ y) t).run s = .ok (.int n, s)) ∨
    (τ = .box ∧ (seen m (σ y) t).run s = .ok (.box (β y), s) ∧
      ∃ cb n, s.heap (β y) = some cb ∧ cb.val = some (.int n)) := by
  obtain ⟨c', hc', hs⟩ := r.slot y τ hy
  rw [hc] at hc'; cases hc'
  rcases Ty.owner_cases ho with rfl | rfl
  · simp only [Shape, hm, ite_false] at hs
    obtain ⟨n, hn⟩ := hs
    exact Or.inl ⟨rfl, n, run_seen hc hl hn⟩
  · simp only [Shape, hm, ite_false] at hs
    exact Or.inr ⟨rfl, run_seen hc hl hs, r.boxes y hy hm⟩

/-- A live view of a live owner reads an Int. -/
theorem Rel.deref {Γ M Live σ β s ex} (r : Rel Γ M Live σ β s ex) {y τ}
    (hy : Γ.lookup y = some τ) (ho : τ.owner = true) (hm : y ∉ M) {m t c}
    (hc : s.heap (σ y) = some c) (hl : c.live m t = true) :
    ∃ n, (deref m (σ y) t).run s = .ok (n, s) := by
  rcases r.seen hy ho hm hc hl with ⟨-, n, h⟩ | ⟨-, h, cb, n, hcb, hn⟩
  · exact ⟨n, by simp only [LambdaRig.deref, StateT.run_bind, h, except_ok_bind]; rfl⟩
  · exact ⟨n, by simp only [LambdaRig.deref, StateT.run_bind, h, except_ok_bind, run_readBox hcb hn]⟩

end LambdaRig
