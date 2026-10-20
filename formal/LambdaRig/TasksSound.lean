/-
The task machine's guarantees (`Tasks.lean`): no task is orphaned, and a
value that stays on one thread is held only by tasks pinned to one core.
-/
import LambdaRig.Tasks

namespace LambdaRig.Tasks

@[simp] theorem set_task (s : State) (t : Nat) (k : Option Task) (x : Nat) :
    (s.set t k).task x = if x = t then k else s.task x := rfl
@[simp] theorem set_fresh (s : State) (t : Nat) (k : Option Task) :
    (s.set t k).fresh = s.fresh := rfl
@[simp] theorem add_task (s : State) (k : Task) (x : Nat) :
    (s.add k).task x = if x = s.fresh then some k else s.task x := rfl
@[simp] theorem add_fresh (s : State) (k : Task) : (s.add k).fresh = s.fresh + 1 := rfl

/-! ## Parents -/

/-- Every task but `main` has a parent, numbered below it, still
running; numbers from `fresh` on are free. -/
def Parents (s : State) : Prop :=
  s.task 0 ≠ none ∧
  (∀ x, s.fresh ≤ x → s.task x = none) ∧
  ∀ c kc, s.task c = some kc →
    (kc.parent = none ↔ c = 0) ∧
    ∀ p, kc.parent = some p → p < c ∧ ∃ kp, s.task p = some kp ∧ kp.ended = false

theorem parents_init : Parents State.init := by
  refine ⟨by simp [State.init], ?_, ?_⟩
  · intro x hx
    have : x ≠ 0 := by simp [State.init] at hx; omega
    simp [State.init, this]
  · intro c kc h
    by_cases hc : c = 0
    · subst hc
      simp [State.init] at h
      subst h
      simp [main]
    · simp [State.init, hc] at h

/-- A task recorded has a number below `fresh`. -/
theorem lt_fresh {s : State} (h : Parents s) {x : Nat} {k : Task} (hx : s.task x = some k) :
    x < s.fresh := by
  apply Nat.lt_of_not_le
  intro hle
  rw [h.2.1 x hle] at hx
  cases hx

theorem fresh_pos {s : State} (h : Parents s) : 0 < s.fresh := by
  obtain ⟨h0, hf, -⟩ := h
  apply Nat.lt_of_not_le
  intro hle
  exact h0 (hf 0 hle)

/-- A task that ended has no task of its own left. -/
theorem ended_childless {s : State} (h : Parents s) {c : Nat} {kc : Task}
    (hc : s.task c = some kc) (he : kc.ended = true) :
    ∀ x kx, s.task x = some kx → kx.parent ≠ some c := by
  intro x kx hx hp
  obtain ⟨-, kp, hkp, hl⟩ := (h.2.2 x kx hx).2 c hp
  rw [hc] at hkp
  cases hkp
  rw [he] at hl
  cases hl

theorem parents_add {s : State} (h : Parents s) (t : Nat) (k : Task) (ht : s.task t = some k)
    (hl : k.ended = false) (K : Task) (hK : K.parent = some t) : Parents (s.add K) := by
  have hpos := fresh_pos h
  have htf := lt_fresh h ht
  refine ⟨?_, ?_, ?_⟩
  · simp [show (0 : Nat) ≠ s.fresh by omega, h.1]
  · intro x hx
    simp at hx
    simp [show x ≠ s.fresh by omega, h.2.1 x (by omega)]
  · intro c kc hc
    simp at hc
    split at hc
    · rename_i hcf
      subst hcf
      cases hc
      refine ⟨by simp [hK]; omega, ?_⟩
      intro p hp
      rw [hK] at hp
      cases hp
      exact ⟨htf, k, by simp [show t ≠ s.fresh by omega, ht], hl⟩
    · obtain ⟨h1, h2⟩ := h.2.2 c kc hc
      refine ⟨h1, ?_⟩
      intro p hp
      obtain ⟨hpc, kp, hkp, hpl⟩ := h2 p hp
      exact ⟨hpc, kp, by simp [show p ≠ s.fresh by have := lt_fresh h hkp; omega, hkp], hpl⟩

/-- Replacing a task's record with one of the same parent, still
running, keeps `Parents`. -/
theorem parents_set {s : State} (h : Parents s) (t : Nat) (k k' : Task) (ht : s.task t = some k)
    (hp : k'.parent = k.parent) (hl : k'.ended = false) : Parents (s.set t (some k')) := by
  refine ⟨?_, ?_, ?_⟩
  · simp only [set_task]
    split
    · simp
    · exact h.1
  · intro x hx
    simp only [set_fresh] at hx
    have := h.2.1 x hx
    have hxt : x ≠ t := by intro e; subst e; rw [ht] at this; cases this
    simp [hxt, this]
  · intro c kc hc
    simp only [set_task] at hc
    split at hc
    · rename_i hct
      subst hct
      cases hc
      obtain ⟨h1, h2⟩ := h.2.2 c k ht
      refine ⟨by rw [hp]; exact h1, ?_⟩
      intro p hpp
      rw [hp] at hpp
      obtain ⟨hpc, kp, hkp, hpl⟩ := h2 p hpp
      refine ⟨hpc, ?_⟩
      by_cases hpt : p = c
      · omega
      · exact ⟨kp, by simp [hpt, hkp], hpl⟩
    · obtain ⟨h1, h2⟩ := h.2.2 c kc hc
      refine ⟨h1, ?_⟩
      intro p hpp
      obtain ⟨hpc, kp, hkp, hpl⟩ := h2 p hpp
      refine ⟨hpc, ?_⟩
      by_cases hpt : p = t
      · subst hpt
        exact ⟨k', by simp, hl⟩
      · exact ⟨kp, by simp [hpt, hkp], hpl⟩

theorem parents_step {s s' : State} (h : Parents s) (st : Step s s') : Parents s' := by
  cases st with
  | spawnFree t k c ht hl => exact parents_add h t k ht hl _ rfl
  | spawnLocal t k pass ht hl hp =>
    have h' := parents_set h t k { k with home := some k.core } ht rfl hl
    exact parents_add h' t { k with home := some k.core } (by simp) hl _ rfl
  | migrate t k c ht hl hh => exact parents_set h t k _ ht rfl hl
  | make t k v ht hl hv => exact parents_set h t k _ ht rfl hl
  | drop t k v ht hl => exact parents_set h t k _ ht rfl hl
  | cancel t k c kc ht hl hc hp =>
    -- The task canceled may have ended; its parent and `ended` stay.
    refine ⟨?_, ?_, ?_⟩
    · simp only [set_task]; split
      · simp
      · exact h.1
    · intro x hx
      have := h.2.1 x hx
      have hxc : x ≠ c := by intro e; subst e; rw [hc] at this; cases this
      simp [hxc, this]
    · intro x kx hx
      simp only [set_task] at hx
      split at hx
      · rename_i hxc
        subst hxc
        cases hx
        obtain ⟨h1, h2⟩ := h.2.2 x kc hc
        refine ⟨h1, ?_⟩
        intro p hpp
        obtain ⟨hpc, kp, hkp, hpl⟩ := h2 p hpp
        exact ⟨hpc, kp, by simp [show p ≠ x by omega, hkp], hpl⟩
      · obtain ⟨h1, h2⟩ := h.2.2 x kx hx
        refine ⟨h1, ?_⟩
        intro p hpp
        obtain ⟨hpc, kp, hkp, hpl⟩ := h2 p hpp
        by_cases hpc' : p = c
        · subst hpc'
          rw [hc] at hkp
          cases hkp
          exact ⟨hpc, { kc with canceled := true }, by simp, hpl⟩
        · exact ⟨hpc, kp, by simp [hpc', hkp], hpl⟩
  | finish t k keep ht hl hown hk =>
    refine ⟨?_, ?_, ?_⟩
    · simp only [set_task]; split
      · simp
      · exact h.1
    · intro x hx
      have := h.2.1 x hx
      have hxt : x ≠ t := by intro e; subst e; rw [ht] at this; cases this
      simp [hxt, this]
    · intro x kx hx
      simp only [set_task] at hx
      split at hx
      · rename_i hxt
        subst hxt
        cases hx
        obtain ⟨h1, h2⟩ := h.2.2 x k ht
        refine ⟨h1, ?_⟩
        intro p hpp
        obtain ⟨hpc, kp, hkp, hpl⟩ := h2 p hpp
        exact ⟨hpc, kp, by simp [show p ≠ x by omega, hkp], hpl⟩
      · obtain ⟨h1, h2⟩ := h.2.2 x kx hx
        refine ⟨h1, ?_⟩
        intro p hpp
        obtain ⟨hpc, kp, hkp, hpl⟩ := h2 p hpp
        have hpt : p ≠ t := by intro e; subst e; exact hown x kx hx hpp
        exact ⟨hpc, kp, by simp [hpt, hkp], hpl⟩
  | wait t k c kc ht hl hc hp he =>
    have htc : t < c := ((h.2.2 c kc hc).2 t hp).1
    have hc0 : c ≠ 0 := by
      intro e; have := (h.2.2 c kc hc).1; rw [hp] at this; simp_all
    have hnone := ended_childless h hc he
    refine ⟨?_, ?_, ?_⟩
    · simp only [set_task]
      rw [ite_eq_right_iff.mpr (fun e => absurd e.symm hc0)]
      split
      · simp
      · exact h.1
    · intro x hx
      have := h.2.1 x hx
      have hxt : x ≠ t := by intro e; subst e; rw [ht] at this; cases this
      simp [hxt, this]
    · intro x kx hx
      simp only [set_task] at hx
      split at hx
      · cases hx
      · rename_i hxc
        split at hx
        · rename_i hxt
          subst hxt
          cases hx
          obtain ⟨h1, h2⟩ := h.2.2 x k ht
          refine ⟨h1, ?_⟩
          intro p hpp
          obtain ⟨hpc, kp, hkp, hpl⟩ := h2 p hpp
          exact ⟨hpc, kp, by simp [show p ≠ c by omega, show p ≠ x by omega, hkp], hpl⟩
        · rename_i hxt
          obtain ⟨h1, h2⟩ := h.2.2 x kx hx
          refine ⟨h1, ?_⟩
          intro p hpp
          obtain ⟨hpc, kp, hkp, hpl⟩ := h2 p hpp
          have hpc' : p ≠ c := by intro e; subst e; exact hnone x kx hx hpp
          by_cases hpt : p = t
          · subst hpt
            exact ⟨hpc, { k with holds := fun v => k.holds v || kc.holds v }, by simp [hpc'], hl⟩
          · exact ⟨hpc, kp, by simp [hpc', hpt, hkp], hpl⟩

theorem parents_reach {s : State} (h : Reach s) : Parents s := by
  induction h with
  | init => exact parents_init
  | step _ st ih => exact parents_step ih st

/-- No task is orphaned: the parent of every task, which holds its
handle and waits for it, is running. So a task never runs, or waits to
be waited for, past the task that made it. -/
theorem no_orphans {s : State} (h : Reach s) {c : Nat} {kc : Task} (hc : s.task c = some kc)
    (h0 : c ≠ 0) : ∃ p kp, kc.parent = some p ∧ s.task p = some kp ∧ kp.ended = false := by
  have hp := parents_reach h
  obtain ⟨h1, h2⟩ := hp.2.2 c kc hc
  cases hpar : kc.parent with
  | none => exact absurd (h1.mp hpar) h0
  | some p =>
    obtain ⟨-, kp, hkp, hl⟩ := h2 p hpar
    exact ⟨p, kp, rfl, hkp, hl⟩

/-! ## Local descendants -/

/-- `LocalDesc` carries over to a state that keeps every local task's
record, with its parent. -/
theorem LocalDesc.mono {s s' : State}
    (hm : ∀ x kx, s.task x = some kx → kx.localSpawn = true →
      ∃ kx', s'.task x = some kx' ∧ kx'.parent = kx.parent ∧ kx'.localSpawn = true)
    {r x : Nat} (h : LocalDesc s r x) : LocalDesc s' r x := by
  induction h with
  | child hx hl hp =>
    obtain ⟨kx', h1, h2, h3⟩ := hm _ _ hx hl
    exact .child h1 h3 (h2 ▸ hp)
  | step _ hx hl hp ih =>
    obtain ⟨kx', h1, h2, h3⟩ := hm _ _ hx hl
    exact .step ih h1 h3 (h2 ▸ hp)

theorem LocalDesc.recorded {s : State} {r x : Nat} (h : LocalDesc s r x) :
    ∃ kx, s.task x = some kx := by
  cases h with
  | child hx => exact ⟨_, hx⟩
  | step _ hx => exact ⟨_, hx⟩

/-- A root has a task of its own. -/
theorem LocalDesc.has_child {s : State} {r x : Nat} (h : LocalDesc s r x) :
    ∃ y ky, s.task y = some ky ∧ ky.parent = some r := by
  induction h with
  | child hx _ hp => exact ⟨_, _, hx, hp⟩
  | step _ _ _ _ ih => exact ih

/-- The parent of a local descendant is the root or descends from it. -/
theorem LocalDesc.parent {s : State} {r x p : Nat} {kx : Task} (h : LocalDesc s r x)
    (hx : s.task x = some kx) (hp : kx.parent = some p) : p = r ∨ LocalDesc s r p := by
  cases h with
  | child hx' _ hp' =>
    rw [hx] at hx'; cases hx'
    rw [hp] at hp'; cases hp'
    exact .inl rfl
  | step hy hx' _ hp' =>
    rw [hx] at hx'; cases hx'
    rw [hp] at hp'; cases hp'
    exact .inr hy

theorem LocalDesc.lt {s : State} (hs : Parents s) {r x : Nat} (h : LocalDesc s r x) : r < x := by
  induction h with
  | child hx _ hp => exact ((hs.2.2 _ _ hx).2 _ hp).1
  | step _ hx _ hp ih => exact Nat.lt_trans ih ((hs.2.2 _ _ hx).2 _ hp).1

/-- Removing a task with no task of its own keeps every other
descendant. -/
theorem LocalDesc.remove {s s' : State} {c : Nat}
    (hc : ∀ y ky, s.task y = some ky → ky.parent ≠ some c)
    (hm : ∀ x kx, x ≠ c → s.task x = some kx → kx.localSpawn = true →
      ∃ kx', s'.task x = some kx' ∧ kx'.parent = kx.parent ∧ kx'.localSpawn = true)
    {r x : Nat} (h : LocalDesc s r x) (hxc : x ≠ c) : LocalDesc s' r x := by
  induction h with
  | child hx hl hp =>
    obtain ⟨kx', h1, h2, h3⟩ := hm _ _ hxc hx hl
    exact .child h1 h3 (h2 ▸ hp)
  | @step x y kx _ hx hl hp ih =>
    have hyc : y ≠ c := by intro e; subst e; exact hc _ _ hx hp
    obtain ⟨kx', h1, h2, h3⟩ := hm _ _ hxc hx hl
    exact .step (ih hyc) h1 h3 (h2 ▸ hp)

/-! ## Pins -/

/-- A pinned task runs on its pin's core. -/
def Pinned (s : State) : Prop :=
  ∀ x kx h, s.task x = some kx → kx.home = some h → kx.core = h

/-- A local descendant is pinned to its root's core. -/
def ChainPinned (s : State) : Prop :=
  ∀ r x, LocalDesc s r x → ∃ h kr kx, s.task r = some kr ∧ s.task x = some kx ∧
    kr.home = some h ∧ kx.home = some h

/-- The holders of a value that stays on one thread: none, or a root and
local descendants of it. -/
def Rooted (s : State) : Prop :=
  ∀ v, (∀ x kx, s.task x = some kx → kx.holds v = false) ∨
    ∃ r kr, s.task r = some kr ∧
      ∀ x kx, s.task x = some kx → kx.holds v = true → x = r ∨ LocalDesc s r x

def Inv (s : State) : Prop := Parents s ∧ Pinned s ∧ ChainPinned s ∧ Rooted s

/-- The record of `t` replaced by one with the same links, the same pin,
the same core if pinned, and no value it did not hold. -/
theorem rest_set {s : State} (_hP : Parents s) (hpin : Pinned s) (hch : ChainPinned s)
    (hr : Rooted s) {t : Nat} {k k' : Task} (ht : s.task t = some k)
    (hpar : k'.parent = k.parent) (hloc : k'.localSpawn = k.localSpawn) (hhome : k'.home = k.home)
    (hcore : k'.home = none ∨ k'.core = k.core)
    (hholds : ∀ v, k'.holds v = true →
      k.holds v = true ∨ ∀ x kx, s.task x = some kx → kx.holds v = false) :
    Pinned (s.set t (some k')) ∧ ChainPinned (s.set t (some k')) ∧ Rooted (s.set t (some k')) := by
  have fwd : ∀ x kx, s.task x = some kx → kx.localSpawn = true →
      ∃ kx', (s.set t (some k')).task x = some kx' ∧ kx'.parent = kx.parent ∧ kx'.localSpawn = true := by
    intro x kx hx hl
    by_cases hxt : x = t
    · subst hxt; rw [ht] at hx; cases hx
      exact ⟨k', by simp, hpar, hloc ▸ hl⟩
    · exact ⟨kx, by simp [hxt, hx], rfl, hl⟩
  have back : ∀ x kx, (s.set t (some k')).task x = some kx → kx.localSpawn = true →
      ∃ kx', s.task x = some kx' ∧ kx'.parent = kx.parent ∧ kx'.localSpawn = true := by
    intro x kx hx hl
    simp only [set_task] at hx
    split at hx
    · rename_i hxt; subst hxt; cases hx
      exact ⟨k, ht, hpar.symm, hloc ▸ hl⟩
    · exact ⟨kx, hx, rfl, hl⟩
  refine ⟨?_, ?_, ?_⟩
  · intro x kx h hx hh
    simp only [set_task] at hx
    split at hx
    · cases hx
      rcases hcore with hn | hc
      · rw [hn] at hh; cases hh
      · rw [hc]; rename_i hxt; subst hxt; exact hpin _ _ h ht (hhome ▸ hh)
    · exact hpin _ _ h hx hh
  · intro r x hd
    obtain ⟨h, kr, kx, hkr, hkx, hrh, hxh⟩ := hch r x (LocalDesc.mono back hd)
    refine ⟨h, ?_⟩
    have get : ∀ y ky, s.task y = some ky → ky.home = some h →
        ∃ ky', (s.set t (some k')).task y = some ky' ∧ ky'.home = some h := by
      intro y ky hy hyh
      by_cases hyt : y = t
      · subst hyt; rw [ht] at hy; cases hy
        exact ⟨k', by simp, hhome ▸ hyh⟩
      · exact ⟨ky, by simp [hyt, hy], hyh⟩
    obtain ⟨kr', h1, h2⟩ := get r kr hkr hrh
    obtain ⟨kx', h3, h4⟩ := get x kx hkx hxh
    exact ⟨kr', kx', h1, h3, h2, h4⟩
  · intro v
    by_cases hfree : ∀ x kx, s.task x = some kx → kx.holds v = false
    · -- No task held `v`: `t` alone may hold it now.
      right
      refine ⟨t, k', by simp, ?_⟩
      intro x kx hx hv
      simp only [set_task] at hx
      split at hx
      · rename_i hxt; exact .inl hxt
      · rw [hfree x kx hx] at hv; cases hv
    have hold : ∀ x kx, (s.set t (some k')).task x = some kx → kx.holds v = true →
        ∃ kx', s.task x = some kx' ∧ kx'.holds v = true := by
      intro x kx hx hv
      simp only [set_task] at hx
      split at hx
      · rename_i hxt; subst hxt; cases hx
        rcases hholds v hv with h | h
        · exact ⟨k, ht, h⟩
        · exact absurd h hfree
      · exact ⟨kx, hx, hv⟩
    rcases hr v with hn | ⟨r, kr, hkr, hall⟩
    · left
      intro x kx hx
      cases hv : kx.holds v
      · rfl
      · obtain ⟨kx', h1, h2⟩ := hold x kx hx hv
        rw [hn x kx' h1] at h2; cases h2
    · right
      have : ∃ kr', (s.set t (some k')).task r = some kr' := by
        by_cases hrt : r = t
        · exact ⟨k', by simp [hrt]⟩
        · exact ⟨kr, by simp [hrt, hkr]⟩
      obtain ⟨kr', hkr'⟩ := this
      refine ⟨r, kr', hkr', ?_⟩
      intro x kx hx hv
      obtain ⟨kx', h1, h2⟩ := hold x kx hx hv
      rcases hall x kx' h1 h2 with e | hd
      · exact .inl e
      · exact .inr (LocalDesc.mono fwd hd)

/-- `spawnFree`: a new task holding nothing, pinned nowhere. -/
theorem rest_spawnFree {s : State} (hP : Parents s) (hpin : Pinned s) (hch : ChainPinned s)
    (hr : Rooted s) (t c : Nat) :
    let s' := s.add ⟨some t, c, none, false, fun _ => false, false, false⟩
    Pinned s' ∧ ChainPinned s' ∧ Rooted s' := by
  intro s'
  have hfresh : s.task s.fresh = none := hP.2.1 _ (Nat.le_refl _)
  have fwd : ∀ x kx, s.task x = some kx → kx.localSpawn = true →
      ∃ kx', s'.task x = some kx' ∧ kx'.parent = kx.parent ∧ kx'.localSpawn = true := by
    intro x kx hx hl
    have : x ≠ s.fresh := by intro e; subst e; rw [hfresh] at hx; cases hx
    exact ⟨kx, by simp [s', this, hx], rfl, hl⟩
  have back : ∀ x kx, s'.task x = some kx → kx.localSpawn = true →
      ∃ kx', s.task x = some kx' ∧ kx'.parent = kx.parent ∧ kx'.localSpawn = true := by
    intro x kx hx hl
    simp only [s', add_task] at hx
    split at hx
    · cases hx; cases hl
    · exact ⟨kx, hx, rfl, hl⟩
  have keep : ∀ y ky, s.task y = some ky → s'.task y = some ky := by
    intro y ky hy
    have : y ≠ s.fresh := by intro e; subst e; rw [hfresh] at hy; cases hy
    simp [s', this, hy]
  refine ⟨?_, ?_, ?_⟩
  · intro x kx h hx hh
    simp only [s', add_task] at hx
    split at hx
    · cases hx; cases hh
    · exact hpin _ _ h hx hh
  · intro r x hd
    obtain ⟨h, kr, kx, hkr, hkx, hrh, hxh⟩ := hch r x (LocalDesc.mono back hd)
    exact ⟨h, kr, kx, keep _ _ hkr, keep _ _ hkx, hrh, hxh⟩
  · intro v
    rcases hr v with hn | ⟨r, kr, hkr, hall⟩
    · left
      intro x kx hx
      simp only [s', add_task] at hx
      split at hx
      · cases hx; rfl
      · exact hn x kx hx
    · right
      refine ⟨r, kr, keep _ _ hkr, ?_⟩
      intro x kx hx hv
      simp only [s', add_task] at hx
      split at hx
      · cases hx; cases hv
      · rcases hall x kx hx hv with e | hd
        · exact .inl e
        · exact .inr (LocalDesc.mono fwd hd)

/-- `spawnLocal`: a new local task pinned to its maker's core, the maker
pinned there too, and the new task holding some of its maker's values. -/
theorem rest_spawnLocal {s : State} (hP : Parents s) (hpin : Pinned s) (hch : ChainPinned s)
    (hr : Rooted s) {t : Nat} {k : Task} (pass : Nat → Bool) (ht : s.task t = some k)
    (hp : ∀ v, pass v = true → k.holds v = true) :
    let s' := (s.set t (some { k with home := some k.core })).add
      ⟨some t, k.core, some k.core, true, pass, false, false⟩
    Pinned s' ∧ ChainPinned s' ∧ Rooted s' := by
  intro s'
  have hfresh : s.task s.fresh = none := hP.2.1 _ (Nat.le_refl _)
  have htf : t ≠ s.fresh := by intro e; subst e; rw [hfresh] at ht; cases ht
  have hK : s'.task s.fresh = some ⟨some t, k.core, some k.core, true, pass, false, false⟩ := by
    simp [s']
  have hT : s'.task t = some { k with home := some k.core } := by simp [s', htf]
  have nf : ∀ x kx, s.task x = some kx → x ≠ s.fresh := by
    intro x kx hx e; subst e; rw [hfresh] at hx; cases hx
  have fwd : ∀ x kx, s.task x = some kx → kx.localSpawn = true →
      ∃ kx', s'.task x = some kx' ∧ kx'.parent = kx.parent ∧ kx'.localSpawn = true := by
    intro x kx hx hl
    by_cases hxt : x = t
    · subst hxt; rw [ht] at hx; cases hx
      exact ⟨{ k with home := some k.core }, by simp [s', htf], rfl, hl⟩
    · exact ⟨kx, by simp [s', nf x kx hx, hxt, hx], rfl, hl⟩
  -- What a local descendant in `s'` is in `s`.
  have desc : ∀ r x, LocalDesc s' r x →
      LocalDesc s r x ∨ (x = s.fresh ∧ (r = t ∨ LocalDesc s r t)) := by
    intro r x hd
    induction hd with
    | @child x kx hx hl hpar =>
      simp only [s', add_task, set_task] at hx
      split at hx
      · cases hx; rename_i hxf; cases hpar; exact .inr ⟨hxf, .inl rfl⟩
      · split at hx
        · cases hx; rename_i _ hxt; subst hxt; exact .inl (.child ht hl hpar)
        · exact .inl (.child hx hl hpar)
    | @step x y kx _ hx hl hpar ih =>
      simp only [s', add_task, set_task] at hx
      split at hx
      · cases hx; rename_i hxf; cases hpar
        rcases ih with h | ⟨hyf, -⟩
        · exact .inr ⟨hxf, .inr h⟩
        · exact absurd hyf htf
      · rename_i hxf
        have hrec : ∃ kx', s.task x = some kx' ∧ kx'.parent = some y ∧ kx'.localSpawn = true := by
          split at hx
          · cases hx; rename_i hxt; subst hxt; exact ⟨k, ht, hpar, hl⟩
          · exact ⟨kx, hx, hpar, hl⟩
        obtain ⟨kx', hx', hpar', hl'⟩ := hrec
        obtain ⟨-, ky, hky, -⟩ := (hP.2.2 x kx' hx').2 y hpar'
        rcases ih with h | ⟨hyf, -⟩
        · exact .inl (.step h hx' hl' hpar')
        · exact absurd hyf (nf y ky hky)
  refine ⟨?_, ?_, ?_⟩
  · intro x kx h hx hh
    simp only [s', add_task, set_task] at hx
    split at hx
    · cases hx; cases hh; rfl
    · split at hx
      · cases hx; cases hh; rfl
      · exact hpin _ _ h hx hh
  · -- A record of `s` keeps its pin in `s'`.
    have keep : ∀ y ky h, s.task y = some ky → ky.home = some h →
        ∃ ky', s'.task y = some ky' ∧ ky'.home = some h := by
      intro y ky h hy hyh
      by_cases hyt : y = t
      · subst hyt; rw [ht] at hy; cases hy
        have := hpin _ _ _ ht hyh
        exact ⟨{ k with home := some k.core }, by simp [s', htf], by simp [this]⟩
      · exact ⟨ky, by simp [s', nf y ky hy, hyt, hy], hyh⟩
    intro r x hd
    rcases desc r x hd with h | ⟨hxf, hrt | h⟩
    · obtain ⟨h, kr, kx, hkr, hkx, hrh, hxh⟩ := hch r x h
      obtain ⟨kr', h1, h2⟩ := keep r kr h hkr hrh
      obtain ⟨kx', h3, h4⟩ := keep x kx h hkx hxh
      exact ⟨h, kr', kx', h1, h3, h2, h4⟩
    · subst hxf; subst hrt
      exact ⟨k.core, _, _, hT, hK, rfl, rfl⟩
    · subst hxf
      obtain ⟨h, kr, kt, hkr, hkt, hrh, hth⟩ := hch r t h
      rw [ht] at hkt; cases hkt
      have hc := hpin _ _ _ ht hth
      obtain ⟨kr', h1, h2⟩ := keep r kr h hkr hrh
      exact ⟨h, kr', _, h1, hK, h2, by rw [hc]⟩
  · intro v
    rcases hr v with hn | ⟨r, kr, hkr, hall⟩
    · left
      intro x kx hx
      simp only [s', add_task, set_task] at hx
      split at hx
      · cases hx
        show pass v = false
        cases hv : pass v
        · rfl
        · have := hp v hv; rw [hn t k ht] at this; cases this
      · split at hx
        · cases hx; exact hn t k ht
        · exact hn x kx hx
    · right
      refine ⟨r, ?_⟩
      have hrf := nf r kr hkr
      by_cases hrt : r = t
      · subst hrt
        refine ⟨_, hT, ?_⟩
        intro x kx hx hv
        simp only [s', add_task, set_task] at hx
        split at hx
        · cases hx; rename_i hxf; subst hxf
          exact .inr (.child hK rfl rfl)
        · split at hx
          · rename_i _ hxt; exact .inl hxt
          · rcases hall x kx hx hv with e | hd
            · exact .inl e
            · exact .inr (LocalDesc.mono fwd hd)
      · refine ⟨kr, by simp [s', hrf, hrt, hkr], ?_⟩
        intro x kx hx hv
        simp only [s', add_task, set_task] at hx
        split at hx
        · cases hx; rename_i hxf; subst hxf
          rcases hall t k ht (hp v hv) with e | hd
          · exact absurd e.symm hrt
          · exact .inr (.step (LocalDesc.mono fwd hd) hK rfl rfl)
        · split at hx
          · cases hx; rename_i _ hxt; subst hxt
            rcases hall _ k ht hv with e | hd
            · exact .inl e
            · exact .inr (LocalDesc.mono fwd hd)
          · rcases hall x kx hx hv with e | hd
            · exact .inl e
            · exact .inr (LocalDesc.mono fwd hd)

/-- `wait`: the parent takes what the ended task held, and its record
goes. -/
theorem rest_wait {s : State} (hP : Parents s) (hpin : Pinned s) (hch : ChainPinned s)
    (hr : Rooted s) {t c : Nat} {k kc : Task} (ht : s.task t = some k)
    (hc : s.task c = some kc) (hp : kc.parent = some t) (he : kc.ended = true) :
    let s' := (s.set t (some { k with holds := fun v => k.holds v || kc.holds v })).set c none
    Pinned s' ∧ ChainPinned s' ∧ Rooted s' := by
  intro s'
  have htc : t ≠ c := by have := ((hP.2.2 c kc hc).2 t hp).1; omega
  have hnone := ended_childless hP hc he
  have hT : s'.task t = some { k with holds := fun v => k.holds v || kc.holds v } := by
    simp [s', htc]
  have same : ∀ x kx, x ≠ c → x ≠ t → s.task x = some kx → s'.task x = some kx := by
    intro x kx hxc hxt hx; simp [s', hxc, hxt, hx]
  have fwd : ∀ x kx, x ≠ c → s.task x = some kx → kx.localSpawn = true →
      ∃ kx', s'.task x = some kx' ∧ kx'.parent = kx.parent ∧ kx'.localSpawn = true := by
    intro x kx hxc hx hl
    by_cases hxt : x = t
    · subst hxt; rw [ht] at hx; cases hx; exact ⟨_, hT, rfl, hl⟩
    · exact ⟨kx, same x kx hxc hxt hx, rfl, hl⟩
  have back : ∀ x kx, s'.task x = some kx → kx.localSpawn = true →
      ∃ kx', s.task x = some kx' ∧ kx'.parent = kx.parent ∧ kx'.localSpawn = true := by
    intro x kx hx hl
    simp only [s', set_task] at hx
    split at hx
    · cases hx
    · split at hx
      · rename_i _ hxt; subst hxt; cases hx; exact ⟨k, ht, rfl, hl⟩
      · exact ⟨kx, hx, rfl, hl⟩
  -- A record of `s` other than `c` keeps its pin in `s'`.
  have keep : ∀ y ky h, y ≠ c → s.task y = some ky → ky.home = some h →
      ∃ ky', s'.task y = some ky' ∧ ky'.home = some h := by
    intro y ky h hyc hy hyh
    by_cases hyt : y = t
    · subst hyt; rw [ht] at hy; cases hy; exact ⟨_, hT, hyh⟩
    · exact ⟨ky, same y ky hyc hyt hy, hyh⟩
  -- `c` roots no one.
  have noroot : ∀ x, ¬ LocalDesc s c x := by
    intro x hd
    obtain ⟨y, ky, hy, hyp⟩ := hd.has_child
    exact hnone y ky hy hyp
  refine ⟨?_, ?_, ?_⟩
  · intro x kx h hx hh
    simp only [s', set_task] at hx
    split at hx
    · cases hx
    · split at hx
      · cases hx; exact hpin t k h ht hh
      · exact hpin _ _ h hx hh
  · intro r x hd
    have hd0 := LocalDesc.mono back hd
    obtain ⟨h, kr, kx, hkr, hkx, hrh, hxh⟩ := hch r x hd0
    have hrc : r ≠ c := by intro e; subst e; exact noroot x hd0
    have hxc : x ≠ c := by
      intro e; subst e
      obtain ⟨kx', hx'⟩ := hd.recorded
      simp [s'] at hx'
    obtain ⟨kr', h1, h2⟩ := keep r kr h hrc hkr hrh
    obtain ⟨kx', h3, h4⟩ := keep x kx h hxc hkx hxh
    exact ⟨h, kr', kx', h1, h3, h2, h4⟩
  · intro v
    -- Each holder in `s'` but `t` held `v` in `s`, and is not `c`.
    have hold : ∀ x kx, s'.task x = some kx → kx.holds v = true → x ≠ t →
        x ≠ c ∧ s.task x = some kx := by
      intro x kx hx hv hxt
      by_cases hxc : x = c
      · subst hxc; simp [s'] at hx
      · exact ⟨hxc, by simpa [s', hxc, hxt] using hx⟩
    cases hcv : kc.holds v with
    | true =>
      rcases hr v with hn | ⟨r, kr, hkr, hall⟩
      · rw [hn c kc hc] at hcv; cases hcv
      · rcases hall c kc hc hcv with hrc | hdc
        · -- `c` was the root: it held `v` alone, and now `t` does.
          subst hrc
          right
          refine ⟨t, _, hT, ?_⟩
          intro x kx hx hv
          by_cases hxt : x = t
          · exact .inl hxt
          · obtain ⟨hxc, hx'⟩ := hold x kx hx hv hxt
            rcases hall x kx hx' hv with e | hd
            · exact absurd e hxc
            · exact absurd hd (noroot x)
        · have hrc : r ≠ c := Nat.ne_of_lt (hdc.lt hP)
          have htr := hdc.parent hc hp
          right
          have : ∃ kr', s'.task r = some kr' := by
            by_cases hrt : r = t
            · subst hrt; exact ⟨_, hT⟩
            · exact ⟨kr, same r kr hrc hrt hkr⟩
          obtain ⟨kr', hkr'⟩ := this
          refine ⟨r, kr', hkr', ?_⟩
          intro x kx hx hv
          by_cases hxt : x = t
          · subst hxt
            rcases htr with e | hd
            · exact .inl e
            · exact .inr (LocalDesc.remove hnone fwd hd htc)
          · obtain ⟨hxc, hx'⟩ := hold x kx hx hv hxt
            rcases hall x kx hx' hv with e | hd
            · exact .inl e
            · exact .inr (LocalDesc.remove hnone fwd hd hxc)
    | false =>
      -- Nothing changes for `v` but that `c` goes.
      have hold' : ∀ x kx, s'.task x = some kx → kx.holds v = true →
          x ≠ c ∧ ∃ kx', s.task x = some kx' ∧ kx'.holds v = true := by
        intro x kx hx hv
        by_cases hxt : x = t
        · subst hxt
          rw [hT] at hx; cases hx
          simp [hcv] at hv
          exact ⟨htc, k, ht, hv⟩
        · obtain ⟨hxc, hx'⟩ := hold x kx hx hv hxt
          exact ⟨hxc, kx, hx', hv⟩
      rcases hr v with hn | ⟨r, kr, hkr, hall⟩
      · left
        intro x kx hx
        cases hv : kx.holds v
        · rfl
        · obtain ⟨-, kx', h1, h2⟩ := hold' x kx hx hv
          rw [hn x kx' h1] at h2; cases h2
      · by_cases hrc : r = c
        · subst hrc
          left
          intro x kx hx
          cases hv : kx.holds v
          · rfl
          · obtain ⟨hxc, kx', h1, h2⟩ := hold' x kx hx hv
            rcases hall x kx' h1 h2 with e | hd
            · exact absurd e hxc
            · exact absurd hd (noroot x)
        · right
          have : ∃ kr', s'.task r = some kr' := by
            by_cases hrt : r = t
            · subst hrt; exact ⟨_, hT⟩
            · exact ⟨kr, same r kr hrc hrt hkr⟩
          obtain ⟨kr', hkr'⟩ := this
          refine ⟨r, kr', hkr', ?_⟩
          intro x kx hx hv
          obtain ⟨hxc, kx', h1, h2⟩ := hold' x kx hx hv
          rcases hall x kx' h1 h2 with e | hd
          · exact .inl e
          · exact .inr (LocalDesc.remove hnone fwd hd hxc)

/-! ## Every state reached -/

theorem inv_init : Inv State.init := by
  refine ⟨parents_init, ?_, ?_, ?_⟩
  · intro x kx h hx hh
    by_cases hx0 : x = 0
    · subst hx0; simp [State.init] at hx; subst hx; simp [main] at hh
    · simp [State.init, hx0] at hx
  · intro r x hd
    obtain ⟨kx, hx⟩ := hd.recorded
    by_cases hx0 : x = 0
    · subst hx0
      cases hd with
      | child hx' hl => simp [State.init] at hx'; subst hx'; simp [main] at hl
      | step _ hx' hl => simp [State.init] at hx'; subst hx'; simp [main] at hl
    · simp [State.init, hx0] at hx
  · intro v
    left
    intro x kx hx
    by_cases hx0 : x = 0
    · subst hx0; simp [State.init] at hx; subst hx; rfl
    · simp [State.init, hx0] at hx

theorem inv_step {s s' : State} (h : Inv s) (st : Step s s') : Inv s' := by
  have hp' := parents_step h.1 st
  obtain ⟨hP, hpin, hch, hr⟩ := h
  refine ⟨hp', ?_⟩
  cases st with
  | spawnFree t k c ht hl => exact rest_spawnFree hP hpin hch hr t c
  | spawnLocal t k pass ht hl hp => exact rest_spawnLocal hP hpin hch hr pass ht hp
  | migrate t k c ht hl hh =>
    exact rest_set hP hpin hch hr ht rfl rfl rfl (.inl hh) (fun _ h => .inl h)
  | make t k v ht hl hv =>
    refine rest_set hP hpin hch hr ht rfl rfl rfl (.inr rfl) ?_
    intro u hu
    simp only [Bool.or_eq_true, decide_eq_true_eq] at hu
    rcases hu with hu | hu
    · exact .inl hu
    · subst hu; exact .inr hv
  | drop t k v ht hl =>
    refine rest_set hP hpin hch hr ht rfl rfl rfl (.inr rfl) ?_
    intro u hu
    simp only [Bool.and_eq_true] at hu
    exact .inl hu.1
  | cancel t k c kc ht hl hc hp =>
    exact rest_set hP hpin hch hr hc rfl rfl rfl (.inr rfl) (fun _ h => .inl h)
  | finish t k keep ht hl hown hk =>
    exact rest_set hP hpin hch hr ht rfl rfl rfl (.inr rfl) (fun v h => .inl (hk v h))
  | wait t k c kc ht hl hc hp he => exact rest_wait hP hpin hch hr ht hc hp he

theorem inv_reach {s : State} (h : Reach s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step _ st ih => exact inv_step ih st

/-- Two tasks that hold one value that stays on one thread are pinned to
one core and run there: no two cores ever touch it. With `pin_kept`,
they stay there. -/
theorem confined {s : State} (h : Reach s) {a b v : Nat} {ka kb : Task} (hab : a ≠ b)
    (ha : s.task a = some ka) (hb : s.task b = some kb)
    (hva : ka.holds v = true) (hvb : kb.holds v = true) :
    ∃ c, ka.home = some c ∧ kb.home = some c ∧ ka.core = c ∧ kb.core = c := by
  obtain ⟨-, hpin, hch, hr⟩ := inv_reach h
  -- The pin a root shares with a local descendant.
  have pinOf : ∀ r x kx, LocalDesc s r x → s.task x = some kx →
      ∃ c kr, s.task r = some kr ∧ kr.home = some c ∧ kx.home = some c := by
    intro r x kx hd hx
    obtain ⟨c, kr, kx', hkr, hkx, hrh, hxh⟩ := hch r x hd
    rw [hx] at hkx; cases hkx
    exact ⟨c, kr, hkr, hrh, hxh⟩
  rcases hr v with hn | ⟨r, kr, hkr, hall⟩
  · rw [hn a ka ha] at hva; cases hva
  · have both : ∃ c, ka.home = some c ∧ kb.home = some c := by
      rcases hall a ka ha hva with e | hda <;> rcases hall b kb hb hvb with e' | hdb
      · exact absurd (e.trans e'.symm) hab
      · subst e
        obtain ⟨c, kr', hkr', hrh, hbh⟩ := pinOf a b kb hdb hb
        rw [ha] at hkr'; cases hkr'
        exact ⟨c, hrh, hbh⟩
      · subst e'
        obtain ⟨c, kr', hkr', hrh, hah⟩ := pinOf b a ka hda ha
        rw [hb] at hkr'; cases hkr'
        exact ⟨c, hah, hrh⟩
      · obtain ⟨c, kr1, hkr1, hrh1, hah⟩ := pinOf r a ka hda ha
        obtain ⟨c', kr2, hkr2, hrh2, hbh⟩ := pinOf r b kb hdb hb
        rw [hkr1] at hkr2; cases hkr2
        rw [hrh1] at hrh2; cases hrh2
        exact ⟨c, hah, hbh⟩
    obtain ⟨c, hah, hbh⟩ := both
    exact ⟨c, hah, hbh, hpin a ka c ha hah, hpin b kb c hb hbh⟩

/-- What a step keeps of a task's record: its pin, once set, a cancel,
and its end. -/
theorem kept_step {s s' : State} (h : Inv s) (st : Step s s') {x : Nat} {k k' : Task}
    (hx : s.task x = some k) (hx' : s'.task x = some k') :
    (∀ c, k.home = some c → k'.home = some c) ∧ (k.canceled = true → k'.canceled = true) ∧
      (k.ended = true → k'.ended = true) := by
  have hfresh : s.task s.fresh = none := h.1.2.1 _ (Nat.le_refl _)
  have hxf : x ≠ s.fresh := by intro e; subst e; rw [hfresh] at hx; cases hx
  cases st with
  | spawnFree t k0 c ht hl =>
    simp [hxf, hx] at hx'; subst hx'; exact ⟨fun _ h => h, id, id⟩
  | spawnLocal t k0 pass ht hl hp =>
    by_cases hxt : x = t
    · subst hxt
      have e : some { k0 with home := some k0.core } = some k' := by
        rw [← hx']; simp [hxf]
      cases e
      rw [ht] at hx; cases hx
      refine ⟨fun c hc => ?_, id, id⟩
      simp [h.2.1 _ _ _ ht hc]
    · have e : s.task x = some k' := by rw [← hx']; simp [hxf, hxt]
      rw [hx] at e; cases e; exact ⟨fun _ h => h, id, id⟩
  | migrate t k0 c ht hl hh =>
    simp only [set_task] at hx'
    split at hx'
    · rename_i hxt; subst hxt; rw [ht] at hx; cases hx; cases hx'
      exact ⟨fun c hc => (by rw [hh] at hc; cases hc), id, id⟩
    · rw [hx] at hx'; cases hx'; exact ⟨fun _ h => h, id, id⟩
  | make t k0 v ht hl hv =>
    simp only [set_task] at hx'
    split at hx'
    · rename_i hxt; subst hxt; rw [ht] at hx; cases hx; cases hx'; exact ⟨fun _ h => h, id, id⟩
    · rw [hx] at hx'; cases hx'; exact ⟨fun _ h => h, id, id⟩
  | drop t k0 v ht hl =>
    simp only [set_task] at hx'
    split at hx'
    · rename_i hxt; subst hxt; rw [ht] at hx; cases hx; cases hx'; exact ⟨fun _ h => h, id, id⟩
    · rw [hx] at hx'; cases hx'; exact ⟨fun _ h => h, id, id⟩
  | cancel t k0 c kc ht hl hc hp =>
    simp only [set_task] at hx'
    split at hx'
    · rename_i hxc; subst hxc; rw [hc] at hx; cases hx; cases hx'
      exact ⟨fun _ h => h, fun _ => rfl, id⟩
    · rw [hx] at hx'; cases hx'; exact ⟨fun _ h => h, id, id⟩
  | finish t k0 keep ht hl hown hk =>
    simp only [set_task] at hx'
    split at hx'
    · rename_i hxt; subst hxt; rw [ht] at hx; cases hx; cases hx'
      exact ⟨fun _ h => h, id, fun _ => rfl⟩
    · rw [hx] at hx'; cases hx'; exact ⟨fun _ h => h, id, id⟩
  | wait t k0 c kc ht hl hc hp he =>
    simp only [set_task] at hx'
    split at hx'
    · cases hx'
    · split at hx'
      · rename_i _ hxt; subst hxt; rw [ht] at hx; cases hx; cases hx'; exact ⟨fun _ h => h, id, id⟩
      · rw [hx] at hx'; cases hx'; exact ⟨fun _ h => h, id, id⟩

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

/-! ## A run -/

/-- `main` makes value 7 (a `*T`), then a local task given a handle of
it: both hold it, pinned to core 0. -/
def mainMakes : State := State.init.set 0 (some { main with holds := fun u => decide (u = 7) })

def localTask : State :=
  (mainMakes.set 0 (some { main with holds := fun u => decide (u = 7), home := some 0 })).add
    ⟨some 0, 0, some 0, true, fun u => decide (u = 7), false, false⟩

theorem localTask_reach : Reach localTask := by
  have h1 : Reach mainMakes := by
    have := Step.make State.init 0 main 7 (by simp [State.init]) rfl (by
      intro x kx hx
      by_cases hx0 : x = 0
      · subst hx0; simp [State.init] at hx; subst hx; rfl
      · simp [State.init, hx0] at hx)
    simpa [mainMakes, main] using Reach.step .init this
  have h2 := Step.spawnLocal mainMakes 0 { main with holds := fun u => decide (u = 7) }
    (fun u => decide (u = 7)) (by simp [mainMakes]) rfl (fun _ h => h)
  simpa [localTask, mainMakes, main] using Reach.step h1 h2

-- The proofs assume nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.Tasks.no_orphans' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms no_orphans

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
