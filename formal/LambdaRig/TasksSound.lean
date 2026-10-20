/-
The task machine's guarantees (`Tasks.lean`): every task is held by a
running task, directly or through results not yet taken, and a value
that stays on one thread is held only by tasks pinned to one core.
-/
import LambdaRig.Tasks

namespace LambdaRig.Tasks

/-! ## Chains of holders

Over a map from each task to its holder, apart from any state. -/

/-- `x`'s chain of holders reaches `main` in `n` links. -/
inductive Up (h : Nat → Option Nat) : Nat → Nat → Prop where
  | main : Up h 0 0
  | link {x p n : Nat} : h x = some p → Up h p n → Up h x (n + 1)

/-- `a` is on `b`'s chain of holders, or is `b`. -/
inductive Reaches (h : Nat → Option Nat) (a : Nat) : Nat → Prop where
  | refl : Reaches h a a
  | link {b p : Nat} : h b = some p → Reaches h a p → Reaches h a b

theorem Up.unique {h : Nat → Option Nat} (h0 : h 0 = none) {x n m : Nat}
    (hn : Up h x n) (hm : Up h x m) : n = m := by
  induction hn generalizing m with
  | main =>
    cases hm with
    | main => rfl
    | link hx => rw [h0] at hx; cases hx
  | link hx _ ih =>
    cases hm with
    | main => rw [h0] at hx; cases hx
    | link hx' hp' =>
      rw [hx] at hx'; cases hx'
      rw [ih hp']

/-- A task on `b`'s chain is no further from `main`. -/
theorem Reaches.up {h : Nat → Option Nat} (h0 : h 0 = none) {a b : Nat} (hr : Reaches h a b) :
    ∀ {n}, Up h b n → ∃ m, m ≤ n ∧ Up h a m := by
  induction hr with
  | refl => intro n hn; exact ⟨n, Nat.le_refl _, hn⟩
  | link hb _ ih =>
    intro n hn
    cases hn with
    | main => rw [h0] at hb; cases hb
    | link hb' hp =>
      rw [hb] at hb'; cases hb'
      obtain ⟨m, hm, hu⟩ := ih hp
      exact ⟨m, by omega, hu⟩

/-- No chain of holders that reaches `main` comes back to where it
started. -/
theorem no_cycle {h : Nat → Option Nat} (h0 : h 0 = none) {x t n : Nat} (hu : Up h x n)
    (hx : h x = some t) (hr : Reaches h x t) : False := by
  cases hu with
  | main => rw [h0] at hx; cases hx
  | @link _ p n' hx' hp =>
    rw [hx] at hx'; cases hx'
    obtain ⟨m, hm, hu'⟩ := hr.up h0 hp
    have := Up.unique h0 hu' (.link hx hp)
    omega

/-- A spawn: the new task `f` is held by `t`, and holds what `sel`
picks, which `t` held. -/
theorem up_spawn {h : Nat → Option Nat} (h0 : h 0 = none) {f t mt : Nat} {sel : Nat → Bool}
    (hf : h f = none) (hf0 : f ≠ 0) (hs : ∀ x, sel x = true → h x = some t) (ht : Up h t mt) :
    let h' := fun x => if x = f then some t else if sel x then some f else h x
    ∀ y n, Up h y n → ∃ m, Up h' y m := by
  intro h'
  have nf : ∀ {y n}, Up h y n → y ≠ f := by
    intro y n hu e; subst e
    cases hu with
    | main => exact hf0 rfl
    | link hx => rw [hf] at hx; cases hx
  have avoid : ∀ {y n}, Up h y n → (∀ z, Reaches h z y → sel z = false) → Up h' y n := by
    intro y n hu
    induction hu with
    | main => intro _; exact .main
    | @link y p n hy hp ih =>
      intro hz
      have hyf := nf (.link hy hp)
      have hsy := hz y .refl
      refine .link (by simp [h', hyf, hsy, hy]) (ih fun z hr => hz z (.link hy hr))
  have ht' : Up h' t mt := by
    refine avoid ht fun z hr => ?_
    cases hsz : sel z
    · rfl
    · exact (no_cycle h0 (.link (hs z hsz) ht) (hs z hsz) hr).elim
  have hfu : Up h' f (mt + 1) := .link (by simp [h']) ht'
  intro y n hu
  induction hu with
  | main => exact ⟨0, .main⟩
  | @link y p n hy hp ih =>
    have hyf := nf (.link hy hp)
    obtain ⟨m, hm⟩ := ih
    cases hsy : sel y
    · exact ⟨m + 1, .link (by simp [h', hyf, hsy, hy]) hm⟩
    · exact ⟨mt + 2, .link (by simp [h', hyf, hsy]) hfu⟩

/-- A wait: `t` takes the handles `c` held, and `c` goes. -/
theorem up_wait {h : Nat → Option Nat} (h0 : h 0 = none) {c t nc : Nat}
    (hc : h c = some t) (hu : Up h c nc) :
    let h' := fun x => if x = c then none else if h x = some c then some t else h x
    ∀ y n, Up h y n → y ≠ c → ∃ m, Up h' y m := by
  intro h'
  have avoid : ∀ {y n}, Up h y n → (∀ z, Reaches h z y → z ≠ c) → Up h' y n := by
    intro y n hu
    induction hu with
    | main => intro _; exact .main
    | @link y p n hy hp ih =>
      intro hz
      have hyc := hz y .refl
      have hpc : p ≠ c := hz p (.link hy .refl)
      refine .link (by simp [h', hyc, hy, hpc]) (ih fun z hr => hz z (.link hy hr))
  have ht : ∃ mt, Up h' t mt := by
    have hu0 := hu
    cases hu0 with
    | main => rw [h0] at hc; cases hc
    | link hc' ht =>
      rw [hc] at hc'; cases hc'
      exact ⟨_, avoid ht fun z hr e => by subst e; exact no_cycle h0 hu hc hr⟩
  obtain ⟨mt, ht⟩ := ht
  intro y n hu
  induction hu with
  | main => intro _; exact ⟨0, .main⟩
  | @link y p n hy hp ih =>
    intro hyc
    by_cases hpc : p = c
    · subst hpc; exact ⟨mt + 1, .link (by simp [h', hyc, hy]) ht⟩
    · obtain ⟨m, hm⟩ := ih hpc
      exact ⟨m + 1, .link (by simp [h', hyc, hy, hpc]) hm⟩


/-- Some task other than `main` exists on a chain only if some task is
held by `main`. -/
theorem Up.held_by_main {h : Nat → Option Nat} {y n : Nat} (hu : Up h y n) (hy : y ≠ 0) :
    ∃ z, h z = some 0 := by
  induction hu with
  | main => exact absurd rfl hy
  | @link y p n hy' _ ih =>
    by_cases hp : p = 0
    · subst hp; exact ⟨y, hy'⟩
    · exact ih hp

/-! ## States -/

@[simp] theorem set_task (s : State) (t : Nat) (k : Option Task) (x : Nat) :
    (s.set t k).task x = if x = t then k else s.task x := rfl
@[simp] theorem set_fresh (s : State) (t : Nat) (k : Option Task) :
    (s.set t k).fresh = s.fresh := rfl
@[simp] theorem add_task (s : State) (k : Task) (x : Nat) :
    (s.add k).task x = if x = s.fresh then some k else s.task x := rfl
@[simp] theorem add_fresh (s : State) (k : Task) : (s.add k).fresh = s.fresh + 1 := rfl
@[simp] theorem hand_fresh (s : State) (sel : Nat → Task → Bool) (n : Nat) :
    (s.hand sel n).fresh = s.fresh := rfl

theorem hand_task (s : State) (sel : Nat → Task → Bool) (n x : Nat) :
    (s.hand sel n).task x =
      (s.task x).map fun k => if sel x k then { k with holder := some n } else k := rfl

/-- What a record of `s.hand` is: the record of `s`, its holder perhaps
changed. -/
theorem hand_some {s : State} {sel : Nat → Task → Bool} {n x : Nat} {k' : Task}
    (hx : (s.hand sel n).task x = some k') :
    ∃ k, s.task x = some k ∧ k'.home = k.home ∧ k'.core = k.core ∧
      k'.localSpawn = k.localSpawn ∧ k'.holds = k.holds ∧ k'.ended = k.ended ∧
      k'.canceled = k.canceled ∧ k'.holder = (if sel x k then some n else k.holder) := by
  rw [hand_task] at hx
  cases h : s.task x with
  | none => rw [h] at hx; cases hx
  | some k =>
    rw [h] at hx
    simp only [Option.map_some, Option.some.injEq] at hx
    subst hx
    refine ⟨k, rfl, ?_⟩
    split <;> simp

theorem hand_of {s : State} {sel : Nat → Task → Bool} {n x : Nat} {k : Task}
    (hx : s.task x = some k) :
    ∃ k', (s.hand sel n).task x = some k' ∧ k'.home = k.home ∧ k'.core = k.core ∧
      k'.localSpawn = k.localSpawn ∧ k'.holds = k.holds ∧ k'.ended = k.ended ∧
      k'.canceled = k.canceled ∧ k'.holder = (if sel x k then some n else k.holder) := by
  refine ⟨_, by rw [hand_task, hx]; rfl, ?_⟩
  split <;> simp_all

theorem hol_of {s : State} {x : Nat} {k : Task} (hx : s.task x = some k) : s.hol x = k.holder := by
  simp [State.hol, hx]

theorem hol_some {s : State} {x p : Nat} (hx : s.hol x = some p) :
    ∃ k, s.task x = some k ∧ k.holder = some p := by
  unfold State.hol at hx
  cases h : s.task x with
  | none => rw [h] at hx; cases hx
  | some k => rw [h] at hx; exact ⟨k, rfl, hx⟩

theorem hol_set (s : State) (t : Nat) (k : Task) :
    (s.set t (some k)).hol = fun x => if x = t then k.holder else s.hol x := by
  funext x; by_cases h : x = t <;> simp [State.hol, h]

theorem hol_add (s : State) (k : Task) :
    (s.add k).hol = fun x => if x = s.fresh then k.holder else s.hol x := by
  funext x; by_cases h : x = s.fresh <;> simp [State.hol, h]

theorem hol_none (s : State) (c : Nat) :
    (s.set c none).hol = fun x => if x = c then none else s.hol x := by
  funext x; by_cases h : x = c <;> simp [State.hol, h]

theorem hol_hand (s : State) (sel : Nat → Task → Bool) (n : Nat) :
    (s.hand sel n).hol = fun x => (s.task x).bind fun k => if sel x k then some n else k.holder := by
  funext x
  unfold State.hol
  rw [hand_task]
  cases s.task x with
  | none => rfl
  | some k => simp only [Option.map_some, Option.bind_some]; split <;> rfl

/-! ## The invariant -/

/-- `main` is recorded and held by no task, numbers from `fresh` on are
free, every task's chain of holders reaches `main`, and once `main` has
ended no other task is left. -/
def Links (s : State) : Prop :=
  (∃ k0, s.task 0 = some k0 ∧ k0.holder = none) ∧
  (∀ x, s.fresh ≤ x → s.task x = none) ∧
  (∀ x kx, s.task x = some kx → ∃ n, Up s.hol x n) ∧
  (∀ k0, s.task 0 = some k0 → k0.ended = true → ∀ x kx, s.task x = some kx → x = 0)

/-- A pinned task runs on its pin's core. -/
def Pinned (s : State) : Prop :=
  ∀ x kx h, s.task x = some kx → kx.home = some h → kx.core = h

/-- Two tasks that hold one value that stays on one thread are pinned to
one core. -/
def Shared (s : State) : Prop :=
  ∀ v a b ka kb, a ≠ b → s.task a = some ka → s.task b = some kb →
    ka.holds v = true → kb.holds v = true → ∃ h, ka.home = some h ∧ kb.home = some h

/-- A local task is pinned, and its holder is pinned to the same core. -/
def LocalPinned (s : State) : Prop :=
  ∀ c kc, s.task c = some kc → kc.localSpawn = true → ∃ h, kc.home = some h ∧
    ∀ p kp, kc.holder = some p → s.task p = some kp → kp.home = some h

/-- The result of a task that is not local crosses: it holds no value
that stays on one thread and no handle of a local task. -/
def FreeResult (s : State) : Prop :=
  ∀ c kc, s.task c = some kc → kc.ended = true → kc.localSpawn = false →
    (∀ v, kc.holds v = false) ∧ ∀ x kx, s.task x = some kx → kx.holder = some c → kx.localSpawn = false

def Inv (s : State) : Prop := Links s ∧ Pinned s ∧ Shared s ∧ LocalPinned s ∧ FreeResult s

theorem Links.hol0 {s : State} (h : Links s) : s.hol 0 = none := by
  obtain ⟨k0, h0, hn⟩ := h.1
  rw [hol_of h0, hn]

theorem Links.fresh_none {s : State} (h : Links s) : s.task s.fresh = none := h.2.1 _ (Nat.le_refl _)

theorem Links.ne_fresh {s : State} (h : Links s) {x : Nat} {k : Task} (hx : s.task x = some k) :
    x ≠ s.fresh := by
  intro e; subst e; rw [h.fresh_none] at hx; cases hx

theorem Links.fresh_ne0 {s : State} (h : Links s) : s.fresh ≠ 0 := by
  intro e
  obtain ⟨k0, h0, -⟩ := h.1
  have := h.ne_fresh h0
  exact this e.symm

/-- No task holds its own handle. -/
theorem Links.not_self {s : State} (h : Links s) {x : Nat} {k : Task} (hx : s.task x = some k) :
    k.holder ≠ some x := by
  intro e
  obtain ⟨n, hu⟩ := h.2.2.1 x k hx
  exact no_cycle h.hol0 hu (by rw [hol_of hx, e]) .refl

/-- A task's holder is recorded. -/
theorem Links.holder_recorded {s : State} (h : Links s) {c p : Nat} {kc : Task}
    (hc : s.task c = some kc) (hp : kc.holder = some p) : ∃ kp, s.task p = some kp := by
  obtain ⟨n, hu⟩ := h.2.2.1 c kc hc
  cases hu with
  | main =>
    obtain ⟨k0, h0, hn⟩ := h.1
    rw [hc] at h0; cases h0; rw [hn] at hp; cases hp
  | link hx hp' =>
    rw [hol_of hc, hp] at hx; cases hx
    cases hp' with
    | main => exact ⟨_, h.1.choose_spec.1⟩
    | link hx' _ => obtain ⟨kp, hkp, -⟩ := hol_some hx'; exact ⟨kp, hkp⟩

/-- If `main` holds no handle, `main` is the only task. -/
theorem Links.alone {s : State} (h : Links s)
    (hm : ∀ x kx, s.task x = some kx → kx.holder ≠ some 0) :
    ∀ x kx, s.task x = some kx → x = 0 := by
  intro x kx hx
  by_cases hx0 : x = 0
  · exact hx0
  · obtain ⟨n, hu⟩ := h.2.2.1 x kx hx
    obtain ⟨z, hz⟩ := hu.held_by_main hx0
    obtain ⟨kz, hkz, hzh⟩ := hol_some hz
    exact absurd hzh (hm z kz hkz)


/-! ## Steps that change one record -/

/-- The record of `t` replaced by one with the same holder, pin, and
locality, the same core if pinned, and no value it did not hold but
one no task held. -/
theorem inv_set {s : State} (hI : Inv s) {t : Nat} {k k' : Task} (ht : s.task t = some k)
    (hhol : k'.holder = k.holder) (hhome : k'.home = k.home) (hloc : k'.localSpawn = k.localSpawn)
    (hcore : k'.home = none ∨ k'.core = k.core)
    (hholds : ∀ v, k'.holds v = true →
      k.holds v = true ∨ ∀ x kx, s.task x = some kx → kx.holds v = false)
    (hmain : t = 0 → k'.ended = true → ∀ x kx, s.task x = some kx → x = 0)
    (hfr : k'.ended = true → k'.localSpawn = false → (∀ v, k'.holds v = false) ∧
      ∀ x kx, s.task x = some kx → kx.holder = some t → kx.localSpawn = false) :
    Inv (s.set t (some k')) := by
  obtain ⟨hL, hP, hS, hLP, hF⟩ := hI
  have hhol' : (s.set t (some k')).hol = s.hol := by
    rw [hol_set]; funext x; by_cases hx : x = t
    · subst hx; simp [hhol, hol_of ht]
    · simp [hx]
  -- A record of the new state, as one of the old.
  have back : ∀ x kx, (s.set t (some k')).task x = some kx →
      (x = t ∧ kx = k') ∨ (x ≠ t ∧ s.task x = some kx) := by
    intro x kx hx
    simp only [set_task] at hx
    split at hx
    · cases hx; exact .inl ⟨by assumption, rfl⟩
    · exact .inr ⟨by assumption, hx⟩
  refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_, ?_, ?_, ?_⟩
  · obtain ⟨k0, h0, hn⟩ := hL.1
    by_cases h0t : (0 : Nat) = t
    · subst h0t; rw [ht] at h0; cases h0
      exact ⟨k', by simp, by rw [hhol, hn]⟩
    · exact ⟨k0, by simp [h0t, h0], hn⟩
  · intro x hx
    have := hL.2.1 x hx
    have hxt : x ≠ t := by intro e; subst e; rw [ht] at this; cases this
    simp [hxt, this]
  · intro x kx hx
    rw [hhol']
    rcases back x kx hx with ⟨e, -⟩ | ⟨-, hx⟩
    · subst e; exact hL.2.2.1 _ _ ht
    · exact hL.2.2.1 _ _ hx
  · intro k0 h0 he x kx hx
    rcases back 0 k0 h0 with ⟨e, e'⟩ | ⟨h0t, h0'⟩
    · subst e'
      have hall := hmain e.symm he
      rcases back x kx hx with ⟨e2, -⟩ | ⟨-, hx'⟩
      · rw [e2, e]
      · exact hall x kx hx'
    · have hall := hL.2.2.2 k0 h0' he
      rcases back x kx hx with ⟨e2, -⟩ | ⟨-, hx'⟩
      · subst e2; exact hall _ _ ht
      · exact hall x kx hx'
  · intro x kx h hx hh
    rcases back x kx hx with ⟨e, e'⟩ | ⟨-, hx'⟩
    · subst e e'
      rcases hcore with hn | hc
      · rw [hn] at hh; cases hh
      · rw [hc]; exact hP _ _ h ht (hhome ▸ hh)
    · exact hP _ _ h hx' hh
  · intro v a b ka kb hab ha hb hva hvb
    -- Each holder of `v` in the new state held it before, unless `v` was free.
    by_cases hfree : ∀ x kx, s.task x = some kx → kx.holds v = false
    · exfalso
      rcases back a ka ha with ⟨ea, e'⟩ | ⟨hat, ha'⟩ <;>
        rcases back b kb hb with ⟨eb, e''⟩ | ⟨hbt, hb'⟩
      · exact hab (ea.trans eb.symm)
      · rw [hfree b kb hb'] at hvb; cases hvb
      · rw [hfree a ka ha'] at hva; cases hva
      · rw [hfree a ka ha'] at hva; cases hva
    · have old : ∀ x kx, (s.set t (some k')).task x = some kx → kx.holds v = true →
          ∃ kx0, s.task x = some kx0 ∧ kx0.holds v = true ∧ kx0.home = kx.home := by
        intro x kx hx hv
        rcases back x kx hx with ⟨e, e'⟩ | ⟨-, hx'⟩
        · subst e e'
          rcases hholds v hv with h | h
          · exact ⟨k, ht, h, hhome.symm⟩
          · exact absurd h hfree
        · exact ⟨kx, hx', hv, rfl⟩
      obtain ⟨ka0, ha0, hva0, hah⟩ := old a ka ha hva
      obtain ⟨kb0, hb0, hvb0, hbh⟩ := old b kb hb hvb
      obtain ⟨h, h1, h2⟩ := hS v a b ka0 kb0 hab ha0 hb0 hva0 hvb0
      exact ⟨h, hah ▸ h1, hbh ▸ h2⟩
  · intro c kc hc hl
    have homeOf : ∀ p kp, (s.set t (some k')).task p = some kp →
        ∃ kp0, s.task p = some kp0 ∧ kp0.home = kp.home := by
      intro p kp hp
      rcases back p kp hp with ⟨e, e'⟩ | ⟨-, hp'⟩
      · subst e e'; exact ⟨k, ht, hhome.symm⟩
      · exact ⟨kp, hp', rfl⟩
    have core : ∀ kc0, s.task c = some kc0 → kc0.holder = kc.holder → kc0.home = kc.home →
        kc0.localSpawn = true → ∃ h, kc.home = some h ∧
          ∀ p kp, kc.holder = some p → (s.set t (some k')).task p = some kp → kp.home = some h := by
      intro kc0 hc0 e1 e2 e3
      obtain ⟨h, hh, hall⟩ := hLP c kc0 hc0 e3
      refine ⟨h, e2 ▸ hh, fun p kp hp hkp => ?_⟩
      obtain ⟨kp0, hkp0, e⟩ := homeOf p kp hkp
      exact e ▸ hall p kp0 (e1 ▸ hp) hkp0
    rcases back c kc hc with ⟨e, e'⟩ | ⟨-, hc'⟩
    · subst e e'; exact core k ht hhol.symm hhome.symm (hloc ▸ hl)
    · exact core kc hc' rfl rfl hl
  · intro c kc hc he hl
    have later : ∀ c', (∀ x kx, s.task x = some kx → kx.holder = some c' → kx.localSpawn = false) →
        ∀ x kx, (s.set t (some k')).task x = some kx → kx.holder = some c' → kx.localSpawn = false := by
      intro c' hall x kx hx hp
      rcases back x kx hx with ⟨e, e'⟩ | ⟨-, hx'⟩
      · subst e e'; rw [hloc]; exact hall _ _ ht (hhol ▸ hp)
      · exact hall x kx hx' hp
    rcases back c kc hc with ⟨e, e'⟩ | ⟨-, hc'⟩
    · subst e e'
      obtain ⟨h1, h2⟩ := hfr he hl
      exact ⟨h1, later _ h2⟩
    · obtain ⟨h1, h2⟩ := hF c kc hc' he hl
      exact ⟨h1, later _ h2⟩


/-- Pinning a task to the core it runs on. -/
theorem inv_pin {s : State} (hI : Inv s) {t : Nat} {k : Task} (ht : s.task t = some k) :
    Inv (s.set t (some { k with home := some k.core })) := by
  obtain ⟨hL, hP, hS, hLP, hF⟩ := hI
  have hpin : ∀ h, k.home = some h → k.core = h := fun h hh => hP t k h ht hh
  -- Every record but `t`'s stays; `t`'s home is its core, or was already.
  have back : ∀ x kx, (s.set t (some { k with home := some k.core })).task x = some kx →
      ∃ kx0, s.task x = some kx0 ∧ kx.holder = kx0.holder ∧ kx.localSpawn = kx0.localSpawn ∧
        kx.holds = kx0.holds ∧ kx.ended = kx0.ended ∧ kx.core = kx0.core ∧
        (∀ h, kx0.home = some h → kx.home = some h) ∧ (kx.home = kx0.home ∨ x = t) := by
    intro x kx hx
    simp only [set_task] at hx
    split at hx
    · rename_i hxt; subst hxt; cases hx
      exact ⟨k, ht, rfl, rfl, rfl, rfl, rfl, fun h hh => by simp [hpin h hh], .inr rfl⟩
    · exact ⟨kx, hx, rfl, rfl, rfl, rfl, rfl, fun _ h => h, .inl rfl⟩
  have fwd : ∀ x kx, s.task x = some kx → ∃ kx', (s.set t (some { k with home := some k.core })).task x = some kx' ∧
      kx'.holder = kx.holder ∧ (∀ h, kx.home = some h → kx'.home = some h) := by
    intro x kx hx
    by_cases hxt : x = t
    · subst hxt; rw [ht] at hx; cases hx
      exact ⟨{ k with home := some k.core }, by simp, rfl, fun h hh => by simp [hpin h hh]⟩
    · exact ⟨kx, by simp [hxt, hx], rfl, fun _ h => h⟩
  have hhol : (s.set t (some { k with home := some k.core })).hol = s.hol := by
    rw [hol_set]; funext x; by_cases hx : x = t
    · subst hx; simp [hol_of ht]
    · simp [hx]
  refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_, ?_, ?_, ?_⟩
  · obtain ⟨k0, h0, hn⟩ := hL.1
    obtain ⟨k0', h0', e, -⟩ := fwd 0 k0 h0
    exact ⟨k0', h0', e ▸ hn⟩
  · intro x hx
    have := hL.2.1 x hx
    have hxt : x ≠ t := by intro e; subst e; rw [ht] at this; cases this
    simp [hxt, this]
  · intro x kx hx
    rw [hhol]
    obtain ⟨kx0, hx0, -⟩ := back x kx hx
    exact hL.2.2.1 _ _ hx0
  · intro k0 h0 he x kx hx
    obtain ⟨k00, h00, -, -, -, e, -⟩ := back 0 k0 h0
    obtain ⟨kx0, hx0, -⟩ := back x kx hx
    exact hL.2.2.2 k00 h00 (e ▸ he) x kx0 hx0
  · intro x kx h hx hh
    obtain ⟨kx0, hx0, -, -, -, -, hc, -, hhome⟩ := back x kx hx
    rcases hhome with e | e
    · rw [hc]; exact hP x kx0 h hx0 (e ▸ hh)
    · subst e
      simp only [set_task, ite_true, Option.some.injEq] at hx
      subst hx; simp at hh; exact hh
  · intro v a b ka kb hab ha hb hva hvb
    obtain ⟨ka0, ha0, -, -, eva, -, -, hma, -⟩ := back a ka ha
    obtain ⟨kb0, hb0, -, -, evb, -, -, hmb, -⟩ := back b kb hb
    obtain ⟨h, h1, h2⟩ := hS v a b ka0 kb0 hab ha0 hb0 (eva ▸ hva) (evb ▸ hvb)
    exact ⟨h, hma h h1, hmb h h2⟩
  · intro c kc hc hl
    obtain ⟨kc0, hc0, ehol, eloc, -, -, -, hmc, -⟩ := back c kc hc
    obtain ⟨h, hh, hall⟩ := hLP c kc0 hc0 (eloc ▸ hl)
    refine ⟨h, hmc h hh, fun p kp hp hkp => ?_⟩
    obtain ⟨kp0, hp0, -, -, -, -, -, hmp, hpe⟩ := back p kp hkp
    rcases hpe with e | e
    · rw [e]; exact hall p kp0 (ehol ▸ hp) hp0
    · exact hmp h (hall p kp0 (ehol ▸ hp) hp0)
  · intro c kc hc he hl
    obtain ⟨kc0, hc0, -, eloc, eh, ee, -⟩ := back c kc hc
    obtain ⟨h1, h2⟩ := hF c kc0 hc0 (ee ▸ he) (eloc ▸ hl)
    refine ⟨fun v => eh ▸ h1 v, fun x kx hx hp => ?_⟩
    obtain ⟨kx0, hx0, ehx, elx, -⟩ := back x kx hx
    exact elx ▸ h2 x kx0 hx0 (ehx ▸ hp)


/-! ## Spawns -/

/-- A spawn by `t`: a new task `K`, held by `t`, holding some values `t`
holds (only if both are pinned to one core) and the handles `sel` picks. -/
theorem inv_spawn {s : State} (hI : Inv s) {t : Nat} {k : Task} (ht : s.task t = some k)
    (hl : k.ended = false) {sel : Nat → Bool} (hs : Holds s t sel) {K : Task}
    (hKh : K.holder = some t) (hKe : K.ended = false)
    (hKpin : ∀ h, K.home = some h → K.core = h)
    (hKholds : ∀ v, K.holds v = true → k.holds v = true ∧ ∃ h, k.home = some h ∧ K.home = some h)
    (hKloc : K.localSpawn = true → ∃ h, K.home = some h ∧ k.home = some h)
    (hsel : ∀ x kx, s.task x = some kx → sel x = true → kx.localSpawn = true → K.home = k.home) :
    Inv ((s.hand (fun x _ => sel x) s.fresh).add K) := by
  obtain ⟨hL, hP, hS, hLP, hF⟩ := hI
  have hft := hL.ne_fresh ht
  -- What a record of the new state is.
  have back : ∀ x kx, ((s.hand (fun x _ => sel x) s.fresh).add K).task x = some kx →
      (x = s.fresh ∧ kx = K) ∨ (x ≠ s.fresh ∧ ∃ k0, s.task x = some k0 ∧ kx.home = k0.home ∧
        kx.core = k0.core ∧ kx.localSpawn = k0.localSpawn ∧ kx.holds = k0.holds ∧
        kx.ended = k0.ended ∧ kx.holder = (if sel x then some s.fresh else k0.holder)) := by
    intro x kx hx
    by_cases hxf : x = s.fresh
    · simp only [add_task, hand_fresh, hxf, ite_true, Option.some.injEq] at hx
      exact .inl ⟨hxf, hx.symm⟩
    · simp only [add_task, hand_fresh, hxf, ite_false] at hx
      obtain ⟨k0, h0, e1, e2, e3, e4, e5, -, e7⟩ := hand_some hx
      exact .inr ⟨hxf, k0, h0, e1, e2, e3, e4, e5, e7⟩
  have fwd : ∀ x k0, s.task x = some k0 → ∃ kx, ((s.hand (fun x _ => sel x) s.fresh).add K).task x = some kx ∧
      kx.home = k0.home ∧ kx.core = k0.core ∧ kx.localSpawn = k0.localSpawn ∧ kx.holds = k0.holds ∧
      kx.ended = k0.ended ∧ kx.holder = (if sel x then some s.fresh else k0.holder) := by
    intro x k0 h0
    obtain ⟨kx, hx, e1, e2, e3, e4, e5, -, e7⟩ := hand_of (sel := fun x _ => sel x) (n := s.fresh) h0
    exact ⟨kx, by simp [hL.ne_fresh h0, hx], e1, e2, e3, e4, e5, e7⟩
  have hhol : ((s.hand (fun x _ => sel x) s.fresh).add K).hol =
      fun x => if x = s.fresh then some t else if sel x then some s.fresh else s.hol x := by
    rw [hol_add, hol_hand, hKh]
    funext x
    by_cases hxf : x = s.fresh
    · simp [hxf]
    · simp only [hxf, ite_false]
      cases hsx : sel x
      · cases h : s.task x <;> simp [State.hol, h, hxf]
      · obtain ⟨kx, hx, -⟩ := hs x hsx
        simp [hx, hxf]
  refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_, ?_, ?_, ?_⟩
  · obtain ⟨k0, h0, hn⟩ := hL.1
    obtain ⟨k0', h0', -, -, -, -, -, e⟩ := fwd 0 k0 h0
    refine ⟨k0', h0', ?_⟩
    rw [e]
    cases hs0 : sel 0
    · simpa using hn
    · obtain ⟨kx, hx, hh⟩ := hs 0 hs0
      rw [h0] at hx; cases hx; rw [hn] at hh; cases hh
  · intro x hx
    simp only [add_fresh, hand_fresh] at hx
    have hxf : x ≠ s.fresh := by omega
    simp [hxf, hand_task, hL.2.1 x (by omega)]
  · rw [hhol]
    obtain ⟨mt, hmt⟩ := hL.2.2.1 t k ht
    have hs' : ∀ x, sel x = true → s.hol x = some t := by
      intro x hx; obtain ⟨kx, h1, h2⟩ := hs x hx; rw [hol_of h1, h2]
    have hup := up_spawn hL.hol0 (by unfold State.hol; rw [hL.fresh_none]; rfl) hL.fresh_ne0 hs' hmt
    intro x kx hx
    rcases back x kx hx with ⟨e, -⟩ | ⟨-, k0, h0, -⟩
    · subst e
      obtain ⟨m, hm⟩ := hup _ _ hmt
      exact ⟨m + 1, .link (by simp) hm⟩
    · obtain ⟨n, hn⟩ := hL.2.2.1 x k0 h0
      exact hup _ _ hn
  · intro k0 h0 he x kx hx
    rcases back 0 k0 h0 with ⟨e, -⟩ | ⟨-, k00, h00, -, -, -, -, ee, -⟩
    · exact absurd e.symm hL.fresh_ne0
    · have := hL.2.2.2 k00 h00 (ee ▸ he) t k ht
      subst this; rw [h00] at ht; cases ht; rw [ee] at he; rw [he] at hl; cases hl
  · intro x kx h hx hh
    rcases back x kx hx with ⟨-, e⟩ | ⟨-, k0, h0, e1, e2, -⟩
    · subst e; exact hKpin h hh
    · rw [e2]; exact hP x k0 h h0 (e1 ▸ hh)
  · -- A holder `b` of a value `K` holds shares a core with `K`.
    have withK : ∀ v b kb, b ≠ s.fresh → ((s.hand (fun x _ => sel x) s.fresh).add K).task b = some kb →
        K.holds v = true → kb.holds v = true → ∃ h, K.home = some h ∧ kb.home = some h := by
      intro v b kb hbf hb hvK hvb
      obtain ⟨hkv, h, hkh, hKh'⟩ := hKholds v hvK
      rcases back b kb hb with ⟨e, -⟩ | ⟨-, kb0, hb0, e1, -, -, e4, -⟩
      · exact absurd e hbf
      · by_cases hbt : b = t
        · subst hbt; rw [ht] at hb0; cases hb0
          exact ⟨h, hKh', e1 ▸ hkh⟩
        · obtain ⟨h', h1, h2⟩ := hS v t b k kb0 (Ne.symm hbt) ht hb0 hkv (e4 ▸ hvb)
          rw [hkh] at h1; cases h1
          exact ⟨h, hKh', e1 ▸ h2⟩
    intro v a b ka kb hab ha hb hva hvb
    rcases back a ka ha with ⟨ea, e⟩ | ⟨haf, ka0, ha0, ea1, -, -, ea4, -⟩
    · subst e; exact withK v b kb (ea ▸ Ne.symm hab) hb hva hvb
    · rcases back b kb hb with ⟨eb, e⟩ | ⟨hbf, kb0, hb0, eb1, -, -, eb4, -⟩
      · subst e
        obtain ⟨h, h1, h2⟩ := withK v a ka haf ha hvb hva
        exact ⟨h, h2, h1⟩
      · obtain ⟨h, h1, h2⟩ := hS v a b ka0 kb0 hab ha0 hb0 (ea4 ▸ hva) (eb4 ▸ hvb)
        exact ⟨h, ea1 ▸ h1, eb1 ▸ h2⟩
  · intro c kc hc hlc
    -- The home of a holder, as the new state has it.
    have homeOf : ∀ p kp, ((s.hand (fun x _ => sel x) s.fresh).add K).task p = some kp →
        (p = s.fresh ∧ kp = K) ∨ ∃ kp0, s.task p = some kp0 ∧ kp.home = kp0.home := by
      intro p kp hp
      rcases back p kp hp with ⟨e, e'⟩ | ⟨-, kp0, hp0, e1, -⟩
      · exact .inl ⟨e, e'⟩
      · exact .inr ⟨kp0, hp0, e1⟩
    rcases back c kc hc with ⟨-, e⟩ | ⟨hcf, kc0, hc0, e1, -, e3, -, -, e7⟩
    · subst e
      obtain ⟨h, hKh', hkh⟩ := hKloc hlc
      refine ⟨h, hKh', fun p kp hp hkp => ?_⟩
      rw [hKh] at hp; cases hp
      rcases homeOf t kp hkp with ⟨e, -⟩ | ⟨kp0, hp0, ee⟩
      · exact absurd e hft
      · rw [ht] at hp0; cases hp0; rw [ee]; exact hkh
    · obtain ⟨h, hh, hall⟩ := hLP c kc0 hc0 (e3 ▸ hlc)
      refine ⟨h, e1 ▸ hh, fun p kp hp hkp => ?_⟩
      rw [e7] at hp
      cases hsc : sel c
      · rw [hsc] at hp; simp only [Bool.false_eq_true, ite_false] at hp
        rcases homeOf p kp hkp with ⟨e, -⟩ | ⟨kp0, hp0, ee⟩
        · subst e
          obtain ⟨kp', hkp'⟩ := hL.holder_recorded hc0 hp
          rw [hL.fresh_none] at hkp'; cases hkp'
        · rw [ee]; exact hall p kp0 hp hp0
      · rw [hsc] at hp; simp only [ite_true] at hp; cases hp
        rcases homeOf s.fresh kp hkp with ⟨-, e⟩ | ⟨kp0, hp0, -⟩
        · subst e
          obtain ⟨kx, hx, hxh⟩ := hs c hsc
          rw [hc0] at hx; cases hx
          rw [hsel c kc0 hc0 hsc (e3 ▸ hlc)]
          exact hall t k hxh ht
        · rw [hL.fresh_none] at hp0; cases hp0
  · intro c kc hc he hlc
    rcases back c kc hc with ⟨-, e⟩ | ⟨hcf, kc0, hc0, -, -, e3, e4, e5, -⟩
    · subst e; rw [hKe] at he; cases he
    · obtain ⟨h1, h2⟩ := hF c kc0 hc0 (e5 ▸ he) (e3 ▸ hlc)
      refine ⟨fun v => e4 ▸ h1 v, fun x kx hx hp => ?_⟩
      rcases back x kx hx with ⟨-, e⟩ | ⟨-, kx0, hx0, -, -, f3, -, -, f7⟩
      · subst e; rw [hKh] at hp; cases hp
        rw [hc0] at ht; cases ht; rw [e5] at he; rw [he] at hl; cases hl
      · rw [f7] at hp
        cases hsx : sel x
        · rw [hsx] at hp; simp only [Bool.false_eq_true, ite_false] at hp
          exact f3 ▸ h2 x kx0 hx0 hp
        · rw [hsx] at hp; simp only [ite_true, Option.some.injEq] at hp
          exact absurd hp.symm hcf


/-! ## Waits -/

/-- A wait by `t` for `c`, which ended: `t` takes the values and the
handles `c` held, and `c`'s record goes. -/
theorem inv_wait {s : State} (hI : Inv s) {t c : Nat} {k kc : Task} (ht : s.task t = some k)
    (hl : k.ended = false) (hc : s.task c = some kc) (hp : kc.holder = some t)
    (he : kc.ended = true) :
    Inv (((s.set t (some { k with holds := fun v => k.holds v || kc.holds v })).hand
      (heldBy c) t).set c none) := by
  obtain ⟨hL, hP, hS, hLP, hF⟩ := hI
  have htc : t ≠ c := by intro e; subst e; rw [ht] at hc; cases hc; rw [hl] at he; cases he
  obtain ⟨nc, hnc⟩ := hL.2.2.1 c kc hc
  have hcs : s.hol c = some t := by rw [hol_of hc, hp]
  -- `t` is not held by `c`.
  have htn : k.holder ≠ some c := by
    intro e
    exact no_cycle hL.hol0 hnc hcs (.link (by rw [hol_of ht, e]) .refl)
  let s' := ((s.set t (some { k with holds := fun v => k.holds v || kc.holds v })).hand
      (heldBy c) t).set c none
  -- What a record of the new state is.
  have back : ∀ x kx, s'.task x = some kx → x ≠ c ∧ ∃ k0, s.task x = some k0 ∧
      kx.home = k0.home ∧ kx.core = k0.core ∧ kx.localSpawn = k0.localSpawn ∧
      kx.ended = k0.ended ∧ kx.holder = (if k0.holder = some c then some t else k0.holder) ∧
      (x = t → ∀ v, kx.holds v = (k.holds v || kc.holds v)) ∧ (x ≠ t → kx.holds = k0.holds) := by
    intro x kx hx
    by_cases hxc : x = c
    · simp [s', hxc] at hx
    · simp only [s', set_task, hxc, ite_false] at hx
      obtain ⟨k1, h1, e1, e2, e3, e4, e5, -, e7⟩ := hand_some hx
      refine ⟨hxc, ?_⟩
      simp only [set_task] at h1
      by_cases hxt : x = t
      · subst hxt
        simp only [ite_true, Option.some.injEq] at h1
        subst h1
        refine ⟨k, ht, e1, e2, e3, e5, ?_, fun _ v => by rw [e4], fun h => absurd rfl h⟩
        rw [e7]; simp [heldBy, htn]
      · simp only [hxt, ite_false] at h1
        refine ⟨k1, h1, e1, e2, e3, e5, ?_, fun h => absurd h hxt, fun _ => e4⟩
        rw [e7]; by_cases hh : k1.holder = some c <;> simp [heldBy, hh]
  have fwd : ∀ x k0, x ≠ c → s.task x = some k0 → ∃ kx, s'.task x = some kx := by
    intro x k0 hxc hx
    have : s'.task x ≠ none := by
      by_cases hxt : x = t
      · subst hxt; simp [s', hxc, hand_task]
      · simp [s', hxc, hxt, hand_task, hx]
    exact Option.ne_none_iff_exists'.mp this
  have hhol : s'.hol = fun x => if x = c then none else if s.hol x = some c then some t else s.hol x := by
    simp only [s', hol_none, hol_hand]
    funext x
    by_cases hxc : x = c
    · simp [hxc]
    · simp only [hxc, ite_false, set_task]
      by_cases hxt : x = t
      · subst hxt; simp [heldBy, hol_of ht, htn]
      · simp only [hxt, ite_false]
        cases h : s.task x with
        | none => simp [State.hol, h]
        | some kx => by_cases hh : kx.holder = some c <;> simp [heldBy, State.hol, h, hh]
  refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_, ?_, ?_, ?_⟩
  · obtain ⟨k0, h0, hn⟩ := hL.1
    have h0c : (0 : Nat) ≠ c := by intro e; subst e; rw [h0] at hc; cases hc; rw [hn] at hp; cases hp
    obtain ⟨k0', h0'⟩ := fwd 0 k0 h0c h0
    obtain ⟨-, k00, h00, -, -, -, -, e, -⟩ := back 0 k0' h0'
    rw [h0] at h00; cases h00
    exact ⟨k0', h0', by rw [e, hn]; rfl⟩
  · intro x hx
    have := hL.2.1 x hx
    have hxt : x ≠ t := by intro e; subst e; rw [ht] at this; cases this
    by_cases hxc : x = c
    · simp [hxc]
    · simp [hxc, hxt, hand_task, this]
  · rw [hhol]
    intro x kx hx
    obtain ⟨hxc, k0, h0, -⟩ := back x kx hx
    obtain ⟨n, hn⟩ := hL.2.2.1 x k0 h0
    exact up_wait hL.hol0 hcs hnc _ _ hn hxc
  · intro k0 h0 he0 x kx hx
    obtain ⟨-, k00, h00, -, -, -, ee, -⟩ := back 0 k0 h0
    have hall := hL.2.2.2 k00 h00 (ee ▸ he0)
    exact absurd ((hall t k ht).trans (hall c kc hc).symm) htc
  · intro x kx h hx hh
    obtain ⟨-, k0, h0, e1, e2, -⟩ := back x kx hx
    rw [e2]; exact hP x k0 h h0 (e1 ▸ hh)
  · -- `t` shares a core with every other holder of what it took.
    have withT : ∀ v b kb, b ≠ t → b ≠ c → s.task b = some kb → kc.holds v = true →
        kb.holds v = true → ∃ h, k.home = some h ∧ kb.home = some h := by
      intro v b kb hbt hbc hb hvc hvb
      obtain ⟨h, h1, h2⟩ := hS v c b kc kb (Ne.symm hbc) hc hb hvc hvb
      cases hloc : kc.localSpawn
      · rw [(hF c kc hc he hloc).1 v] at hvc; cases hvc
      · obtain ⟨h', hh', hall⟩ := hLP c kc hc hloc
        rw [h1] at hh'; cases hh'
        exact ⟨h, hall t k hp ht, h2⟩
    have pair : ∀ v a b ka kb, a ≠ b → s'.task a = some ka → s'.task b = some kb →
        ka.holds v = true → kb.holds v = true → a = t → ∃ h, ka.home = some h ∧ kb.home = some h := by
      intro v a b ka kb hab ha hb hva hvb hat
      subst hat
      obtain ⟨-, ka0, ha0, ea1, -, -, -, -, ea8, -⟩ := back a ka ha
      rw [ht] at ha0; cases ha0
      obtain ⟨hbc, kb0, hb0, eb1, -, -, -, -, -, eb9⟩ := back b kb hb
      have hvb0 := eb9 (Ne.symm hab) ▸ hvb
      rw [ea8 rfl v] at hva
      rw [ea1, eb1]
      cases hkv : k.holds v
      · rw [hkv, Bool.false_or] at hva
        exact withT v b kb0 (Ne.symm hab) hbc hb0 hva hvb0
      · exact hS v a b k kb0 hab ht hb0 hkv hvb0
    intro v a b ka kb hab ha hb hva hvb
    by_cases hat : a = t
    · exact pair v a b ka kb hab ha hb hva hvb hat
    · by_cases hbt : b = t
      · obtain ⟨h, h1, h2⟩ := pair v b a kb ka (Ne.symm hab) hb ha hvb hva hbt
        exact ⟨h, h2, h1⟩
      · obtain ⟨-, ka0, ha0, ea1, -, -, -, -, -, ea9⟩ := back a ka ha
        obtain ⟨-, kb0, hb0, eb1, -, -, -, -, -, eb9⟩ := back b kb hb
        obtain ⟨h, h1, h2⟩ := hS v a b ka0 kb0 hab ha0 hb0 (ea9 hat ▸ hva) (eb9 hbt ▸ hvb)
        exact ⟨h, ea1 ▸ h1, eb1 ▸ h2⟩
  · intro x kx hx hlx
    obtain ⟨hxc, k0, h0, e1, -, e3, -, e6, -⟩ := back x kx hx
    obtain ⟨h, hh, hall⟩ := hLP x k0 h0 (e3 ▸ hlx)
    refine ⟨h, e1 ▸ hh, fun p kp hpp hkp => ?_⟩
    obtain ⟨-, kp0, hp0, ep1, -⟩ := back p kp hkp
    rw [ep1]
    rw [e6] at hpp
    by_cases hxh : k0.holder = some c
    · simp only [hxh, ite_true, Option.some.injEq] at hpp; subst hpp
      rw [ht] at hp0; cases hp0
      -- `c` held a local task's handle, so `c` is local, and pinned with `t`.
      have hcl : kc.localSpawn = true := by
        cases hcl : kc.localSpawn
        · have := (hF c kc hc he hcl).2 x k0 h0 hxh; rw [e3] at hlx; rw [this] at hlx; cases hlx
        · rfl
      obtain ⟨h', hh', hall'⟩ := hLP c kc hc hcl
      rw [hall c kc hxh hc] at hh'; cases hh'
      exact hall' t k hp ht
    · simp only [hxh, ite_false] at hpp
      exact hall p kp0 hpp hp0
  · intro x kx hx hex hlx
    obtain ⟨hxc, k0, h0, -, -, e3, e5, -, -, e9⟩ := back x kx hx
    have hxt : x ≠ t := by intro e; subst e; rw [ht] at h0; cases h0; rw [e5, hl] at hex; cases hex
    obtain ⟨h1, h2⟩ := hF x k0 h0 (e5 ▸ hex) (e3 ▸ hlx)
    refine ⟨fun v => by rw [e9 hxt]; exact h1 v, fun y ky hy hyp => ?_⟩
    obtain ⟨-, ky0, hy0, -, -, f3, -, f6, -⟩ := back y ky hy
    rw [f6] at hyp
    by_cases hyh : ky0.holder = some c
    · simp only [hyh, ite_true, Option.some.injEq] at hyp; exact absurd hyp.symm hxt
    · simp only [hyh, ite_false] at hyp; exact f3 ▸ h2 y ky0 hy0 hyp


/-! ## Every state reached -/

theorem inv_init : Inv State.init := by
  have only0 : ∀ x kx, State.init.task x = some kx → x = 0 ∧ kx = main := by
    intro x kx hx
    by_cases hx0 : x = 0
    · subst hx0; simp [State.init] at hx; exact ⟨rfl, hx.symm⟩
    · simp [State.init, hx0] at hx
  refine ⟨⟨⟨main, by simp [State.init], rfl⟩, ?_, ?_, ?_⟩, ?_, ?_, ?_, ?_⟩
  · intro x hx
    have : x ≠ 0 := by simp [State.init] at hx; omega
    simp [State.init, this]
  · intro x kx hx
    obtain ⟨e, -⟩ := only0 x kx hx
    subst e; exact ⟨0, .main⟩
  · intro k0 h0 he
    obtain ⟨-, e⟩ := only0 0 k0 h0
    subst e; cases he
  · intro x kx h hx hh
    obtain ⟨-, e⟩ := only0 x kx hx
    subst e; cases hh
  · intro v a b ka kb hab ha hb
    obtain ⟨ea, -⟩ := only0 a ka ha
    obtain ⟨eb, -⟩ := only0 b kb hb
    exact absurd (ea.trans eb.symm) hab
  · intro c kc hc hl
    obtain ⟨-, e⟩ := only0 c kc hc
    subst e; cases hl
  · intro c kc hc he
    obtain ⟨-, e⟩ := only0 c kc hc
    subst e; cases he

theorem inv_step {s s' : State} (hI : Inv s) (st : Step s s') : Inv s' := by
  cases st with
  | spawnFree t k c sel ht hl hs hx =>
    refine inv_spawn hI ht hl hs rfl rfl (fun _ h => by cases h) (fun _ h => by cases h)
      (fun h => by cases h) (fun x kx hx' hsx hlx => ?_)
    rw [hx x kx hx' hsx] at hlx; cases hlx
  | spawnLocal t k pass sel ht hl hs hp =>
    have hI1 := inv_pin hI ht
    have ht1 : (s.set t (some { k with home := some k.core })).task t =
        some { k with home := some k.core } := by simp
    have hs1 : Holds (s.set t (some { k with home := some k.core })) t sel := by
      intro x hx
      obtain ⟨kx, h1, h2⟩ := hs x hx
      by_cases hxt : x = t
      · subst hxt; rw [ht] at h1; cases h1
        exact ⟨_, ht1, h2⟩
      · exact ⟨kx, by simp [hxt, h1], h2⟩
    exact inv_spawn hI1 ht1 hl hs1 rfl rfl (fun _ h => by cases h; rfl)
      (fun v hv => ⟨hp v hv, k.core, rfl, rfl⟩) (fun _ => ⟨k.core, rfl, rfl⟩)
      (fun _ _ _ _ _ => rfl)
  | migrate t k c ht hl hh =>
    exact inv_set hI ht rfl rfl rfl (.inl hh) (fun _ h => .inl h)
      (fun _ he => by simp [hl] at he) (fun he => by simp [hl] at he)
  | make t k v ht hl hv =>
    refine inv_set hI ht rfl rfl rfl (.inr rfl) ?_
      (fun _ he => by simp [hl] at he) (fun he => by simp [hl] at he)
    intro u hu
    simp only [Bool.or_eq_true, decide_eq_true_eq] at hu
    rcases hu with hu | hu
    · exact .inl hu
    · subst hu; exact .inr hv
  | drop t k v ht hl =>
    refine inv_set hI ht rfl rfl rfl (.inr rfl) ?_
      (fun _ he => by simp [hl] at he) (fun he => by simp [hl] at he)
    intro u hu
    simp only [Bool.and_eq_true] at hu
    exact .inl hu.1
  | cancel t k c kc ht hl hc hp =>
    exact inv_set hI hc rfl rfl rfl (.inr rfl) (fun _ h => .inl h)
      (fun _ he => hI.1.2.2.2 kc (by rename_i e; exact e ▸ hc) he)
      (fun he hlc => hI.2.2.2.2 c kc hc he hlc)
  | finish t k keep ht hl hk hfree hmain =>
    exact inv_set hI ht rfl rfl rfl (.inr rfl) (fun v h => .inl (hk v h))
      (fun h0 _ => by subst h0; exact hI.1.alone (hmain rfl)) (fun _ hlt => hfree hlt)
  | wait t k c kc ht hl hc hp he => exact inv_wait hI ht hl hc hp he

theorem inv_reach {s : State} (h : Reach s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step _ st ih => exact inv_step ih st

/-- No task is orphaned: every task but `main` is held by a running
task, or by the result of an ended task held so in turn. The holder
waits for it, or hands its handle on, so a task never runs, or waits to
be waited for, with no running task answerable for it. -/
theorem no_orphans {s : State} (h : Reach s) {c : Nat} {kc : Task} (hc : s.task c = some kc)
    (h0 : c ≠ 0) : Held s c := by
  have hL := (inv_reach h).1
  obtain ⟨n, hu⟩ := hL.2.2.1 c kc hc
  induction hu generalizing kc with
  | main => exact absurd rfl h0
  | @link x p n hx _ ih =>
    obtain ⟨kx, hkx, hxp⟩ := hol_some hx
    rw [hc] at hkx; cases hkx
    obtain ⟨kp, hkp⟩ := hL.holder_recorded hc hxp
    cases hpe : kp.ended
    · exact .running hc hxp hkp hpe
    · have hp0 : p ≠ 0 := by
        intro e; subst e
        exact h0 (hL.2.2.2 kp hkp hpe x kc hc)
      exact .result hc hxp hkp hpe (ih hkp hp0)

/-- Once `main` has ended, it is the only task. -/
theorem main_last {s : State} (h : Reach s) {k0 : Task} (h0 : s.task 0 = some k0)
    (he : k0.ended = true) : ∀ x kx, s.task x = some kx → x = 0 :=
  (inv_reach h).1.2.2.2 k0 h0 he

/-- Two tasks that hold one value that stays on one thread are pinned to
one core and run there: no two cores ever touch it. With `pin_kept`,
they stay there. -/
theorem confined {s : State} (h : Reach s) {a b v : Nat} {ka kb : Task} (hab : a ≠ b)
    (ha : s.task a = some ka) (hb : s.task b = some kb)
    (hva : ka.holds v = true) (hvb : kb.holds v = true) :
    ∃ c, ka.home = some c ∧ kb.home = some c ∧ ka.core = c ∧ kb.core = c := by
  obtain ⟨-, hP, hS, -⟩ := inv_reach h
  obtain ⟨c, h1, h2⟩ := hS v a b ka kb hab ha hb hva hvb
  exact ⟨c, h1, h2, hP a ka c ha h1, hP b kb c hb h2⟩

/-- A record replaced by `set` is the new one, or the old. -/
theorem set_some {s : State} {t x : Nat} {k k' kx : Task} (hx : s.task x = some k)
    (hx' : (s.set t (some k')).task x = some kx) : (x = t ∧ kx = k') ∨ kx = k := by
  simp only [set_task] at hx'
  split at hx'
  · cases hx'; exact .inl ⟨by assumption, rfl⟩
  · rw [hx] at hx'; cases hx'; exact .inr rfl

/-- What a step keeps of a task's record: its pin, once set, a cancel,
and its end. -/
theorem kept_step {s s' : State} (h : Inv s) (st : Step s s') {x : Nat} {k k' : Task}
    (hx : s.task x = some k) (hx' : s'.task x = some k') :
    (∀ c, k.home = some c → k'.home = some c) ∧ (k.canceled = true → k'.canceled = true) ∧
      (k.ended = true → k'.ended = true) := by
  have hxf := h.1.ne_fresh hx
  -- The fields kept by `hand`.
  have viaHand : ∀ {s0 : State} {sel n} (k0 : Task), s0.task x = some k0 →
      (s0.hand sel n).task x = some k' →
      (∀ c, k0.home = some c → k'.home = some c) ∧ (k0.canceled = true → k'.canceled = true) ∧
        (k0.ended = true → k'.ended = true) := by
    intro s0 sel n k0 h0 h1
    obtain ⟨k1, h2, e1, -, -, -, e5, e6, -⟩ := hand_some h1
    rw [h0] at h2; cases h2
    exact ⟨fun c hc => by rw [e1, hc], fun hc => by rw [e6, hc], fun he => by rw [e5, he]⟩
  cases st with
  | spawnFree t k0 c sel ht hl hs hx2 =>
    simp only [add_task, hand_fresh, hxf, ite_false] at hx'
    exact viaHand k hx hx'
  | spawnLocal t k0 pass sel ht hl hs hp =>
    simp only [add_task, hand_fresh, set_fresh, hxf, ite_false] at hx'
    by_cases hxt : x = t
    · subst hxt; rw [ht] at hx; cases hx
      obtain ⟨e1, e2, e3⟩ := viaHand { k with home := some k.core } (by simp) hx'
      refine ⟨fun c hh => e1 c ?_, e2, e3⟩
      simp [h.2.1 _ _ _ ht hh]
    · exact viaHand k (by simp [hxt, hx]) hx'
  | migrate t k0 c ht hl hh =>
    rcases set_some hx hx' with ⟨e, e'⟩ | e
    · subst e e'; rw [ht] at hx; cases hx
      exact ⟨fun c hc => (by rw [hh] at hc; cases hc), id, id⟩
    · subst e; exact ⟨fun _ h => h, id, id⟩
  | make t k0 v ht hl hv =>
    rcases set_some hx hx' with ⟨e, e'⟩ | e
    · subst e e'; rw [ht] at hx; cases hx; exact ⟨fun _ h => h, id, id⟩
    · subst e; exact ⟨fun _ h => h, id, id⟩
  | drop t k0 v ht hl =>
    rcases set_some hx hx' with ⟨e, e'⟩ | e
    · subst e e'; rw [ht] at hx; cases hx; exact ⟨fun _ h => h, id, id⟩
    · subst e; exact ⟨fun _ h => h, id, id⟩
  | cancel t k0 c kc ht hl hc hp =>
    rcases set_some hx hx' with ⟨e, e'⟩ | e
    · subst e e'; rw [hc] at hx; cases hx; exact ⟨fun _ h => h, fun _ => rfl, id⟩
    · subst e; exact ⟨fun _ h => h, id, id⟩
  | finish t k0 keep ht hl hk hfree hmain =>
    rcases set_some hx hx' with ⟨e, e'⟩ | e
    · subst e e'; rw [ht] at hx; cases hx; exact ⟨fun _ h => h, id, fun _ => rfl⟩
    · subst e; exact ⟨fun _ h => h, id, id⟩
  | wait t k0 c kc ht hl hc hp he =>
    by_cases hxc : x = c
    · subst hxc; simp at hx'
    · simp only [set_task, hxc, ite_false] at hx'
      by_cases hxt : x = t
      · subst hxt; rw [ht] at hx; cases hx
        exact viaHand { k with holds := fun v => k.holds v || kc.holds v } (by simp) hx'
      · exact viaHand k (by simp [hxt, hx]) hx'

/-- A pinned task stays on its pin's core from then on. -/
theorem pin_kept {s s' : State} (h : Reach s) (st : Step s s') {x c : Nat} {k k' : Task}
    (hx : s.task x = some k) (hh : k.home = some c) (hx' : s'.task x = some k') :
    k'.home = some c ∧ k'.core = c := by
  have hk := (kept_step (inv_reach h) st hx hx').1 c hh
  exact ⟨hk, (inv_reach (.step h st)).2.1 x k' c hx' hk⟩

/-- A cancel is never taken back: a task canceled stays canceled. -/
theorem cancel_sticky {s s' : State} (h : Reach s) (st : Step s s') {x : Nat} {k k' : Task}
    (hx : s.task x = some k) (hc : k.canceled = true) (hx' : s'.task x = some k') :
    k'.canceled = true :=
  (kept_step (inv_reach h) st hx hx').2.1 hc

end LambdaRig.Tasks

namespace LambdaRig.Tasks

/-! ## Runs -/

/-- `main` makes value 7 (a `*T`), then a local task given a handle of
it: both hold it, pinned to core 0. -/
def mainMakes : State := State.init.set 0 (some { main with holds := fun u => decide (u = 7) })

def localTask : State :=
  ((mainMakes.set 0 (some { main with holds := fun u => decide (u = 7), home := some 0 })).hand
    (fun _ _ => false) 1).add ⟨some 0, 0, some 0, true, fun u => decide (u = 7), false, false⟩

theorem localTask_reach : Reach localTask := by
  have h1 : Reach mainMakes := by
    have := Step.make State.init 0 main 7 (by simp [State.init]) rfl (by
      intro x kx hx
      by_cases hx0 : x = 0
      · subst hx0; simp [State.init] at hx; subst hx; rfl
      · simp [State.init, hx0] at hx)
    simpa [mainMakes, main] using Reach.step .init this
  exact Reach.step h1 (Step.spawnLocal mainMakes 0 { main with holds := fun u => decide (u = 7) }
    (fun u => decide (u = 7)) (fun _ => false) (by simp [mainMakes]) rfl
    (fun _ h => by cases h) (fun _ h => h))

theorem localTask_shared : (localTask.task 0).map (Task.holds · 7) = some true ∧
    (localTask.task 1).map (Task.holds · 7) = some true := by
  decide

/-- A task returns the handle of a task it made, which is still running,
and its holder takes it (`Task[T]` returned): `main` makes task 1, which
makes task 2 and ends, holding 2's handle in its result; `main` waits
for 1 and holds 2. Then `main` hands 2 to a new task 3 (`Task[T]` as an
argument). -/
def task1 : Task := ⟨some 0, 0, none, false, fun _ => false, false, false⟩
def task2 : Task := ⟨some 1, 0, none, false, fun _ => false, false, false⟩

def made1 : State := (State.init.hand (fun _ _ => false) 1).add task1
def made2 : State := (made1.hand (fun _ _ => false) 2).add task2
def ended1 : State := made2.set 1 (some { task1 with ended := true, holds := fun _ => false })
def waited1 : State :=
  ((ended1.set 0 (some { main with holds := fun v => main.holds v || false })).hand (heldBy 1) 0).set 1 none
def handed2 : State :=
  (waited1.hand (fun x _ => decide (x = 2)) 3).add ⟨some 0, 0, none, false, fun _ => false, false, false⟩

theorem handed2_reach : Reach handed2 := by
  have r1 : Reach made1 :=
    .step .init (Step.spawnFree State.init 0 main 0 (fun _ => false) (by simp [State.init]) rfl
      (fun _ h => by cases h) (fun _ _ _ h => by cases h))
  have r2 : Reach made2 :=
    .step r1 (Step.spawnFree made1 1 task1 0 (fun _ => false) rfl rfl
      (fun _ h => by cases h) (fun _ _ _ h => by cases h))
  have r3 : Reach ended1 := by
    refine .step r2 (Step.finish made2 1 task1 (fun _ => false) rfl rfl
      (fun _ h => by cases h) (fun _ => ⟨fun _ => rfl, ?_⟩) (fun h => by cases h))
    intro x kx hx _
    by_cases h2 : x = 2
    · subst h2; rw [show made2.task 2 = some task2 from rfl] at hx; cases hx; rfl
    · by_cases h1 : x = 1
      · subst h1; rw [show made2.task 1 = some task1 from rfl] at hx; cases hx; rfl
      · by_cases h0 : x = 0
        · subst h0; rw [show made2.task 0 = some main from rfl] at hx; cases hx; rfl
        · simp [made2, made1, State.init, hand_task, h0, h1, h2] at hx
  have r4 : Reach waited1 :=
    .step r3 (Step.wait ended1 0 main 1 { task1 with ended := true, holds := fun _ => false }
      rfl rfl rfl rfl rfl)
  exact .step r4 (Step.spawnFree waited1 0 { main with holds := fun v => main.holds v || false } 0
    (fun x => decide (x = 2)) rfl rfl
    (fun x hx => by
      simp only [decide_eq_true_eq] at hx; subst hx
      exact ⟨{ task2 with holder := some 0 }, rfl, rfl⟩)
    (fun x kx hx hs => by
      simp only [decide_eq_true_eq] at hs; subst hs
      rw [show waited1.task 2 = some { task2 with holder := some 0 } from rfl] at hx
      cases hx; rfl))

/-- Task 2 outlived its maker: held by task 1's result once 1 ended,
then by `main`, then by task 3. -/
theorem handed2_holders : ended1.hol 2 = some 1 ∧ (ended1.task 1).map Task.ended = some true ∧
    waited1.hol 2 = some 0 ∧ handed2.hol 2 = some 3 := by
  decide

-- The proofs assume nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.Tasks.no_orphans' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms no_orphans

/-- info: 'LambdaRig.Tasks.main_last' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms main_last

/-- info: 'LambdaRig.Tasks.confined' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms confined

/-- info: 'LambdaRig.Tasks.pin_kept' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms pin_kept

/-- info: 'LambdaRig.Tasks.cancel_sticky' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms cancel_sticky

end LambdaRig.Tasks
