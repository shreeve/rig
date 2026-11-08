/-
λRig: fields of an owned object, and partial moves.

CORE §5, "A field of an owned object moves like a name": "A local or
parameter that owns an object acts as one name per field, and so on
down, unless a type on the way has a `drop` body. `<p.f` moves `p.f` as
`<x` moves `x`, and a field that copies takes no `<`. `p.f = x` makes a
local's field usable again. Where `p`'s scope ends, only the fields it
still holds drop. Until every moved field is assigned again on every
path, no use touches all of `p` except `p = x`." And sentence 3: "A
partly moved name drops only the fields it still holds."

An owned object is a tree: its leaves are owners of heap cells (a
`String`, a `List`) and plain data, its nodes objects of two fields,
each node marked when its type has a `drop` body. A program on one such
local is a list of uses (`p.f`, `?p.f`, `!p.f`, or `p` itself at the
empty path), moves out (`<p.f`, `<p`), and assignments (`p.f = x`,
`p = x`). The checker, `check`, keeps the local's type with each moved
field marked, which is the moved state per path. The machine runs the
program on the tree, each moved field left `gone`, and at the scope's
end drops the local and every value moved out of it, each by its new
owner; a `drop` body reads every field of its object.

`fields_run`: a program the checker accepts runs without a fault: no use
of a moved field, no cell freed twice, no `drop` body that finds a field
moved, and no cell left when the scope ends.
-/
import LambdaRig.Machine

namespace LambdaRig.Fields

/-- A path into an object: which field, `false` the first, at each node. -/
abbrev Path := List Bool

/-- An owned object's type, as the checker sees it, with each moved
field marked. -/
inductive A where
  /-- An owner of a heap cell: a `String`, a `List`. -/
  | own
  /-- Plain data, which copies. -/
  | plain
  /-- An object of two fields; `d` when its type has a `drop` body. -/
  | node (d : Bool) (l r : A)
  /-- A field moved out. -/
  | gone
  deriving DecidableEq, Repr

/-- An owned object at run time. -/
inductive O where
  | own (l : Loc)
  | plain (n : Int)
  | node (d : Bool) (l r : O)
  | gone
  deriving DecidableEq, Repr

def O.abs : O → A
  | .own _ => .own
  | .plain _ => .plain
  | .node d l r => .node d l.abs r.abs
  | .gone => .gone

/-! ## The checker -/

def A.get : A → Path → Option A
  | a, [] => some a
  | .node _ l _, false :: p => l.get p
  | .node _ _ r, true :: p => r.get p
  | _, _ :: _ => none

def A.set : A → Path → A → A
  | _, [], w => w
  | .node d l r, false :: p, w => .node d (l.set p w) r
  | .node d l r, true :: p, w => .node d l (r.set p w)
  | a, _ :: _, _ => a

/-- No field is moved out. -/
def A.whole : A → Bool
  | .gone => false
  | .node _ l r => l.whole && r.whole
  | _ => true

/-- Every object whose type has a `drop` body has every field. -/
def A.dropOk : A → Bool
  | .node d l r => (!d || (l.whole && r.whole)) && l.dropOk && r.dropOk
  | _ => true

/-- An object on the way to `p`, not `p` itself, has a `drop` body. -/
def A.dropAbove : A → Path → Bool
  | .node d l _, false :: p => d || l.dropAbove p
  | .node d _ r, true :: p => d || r.dropAbove p
  | _, _ => false

/-- What a program does with the local. -/
inductive Op where
  /-- `p.f`, `?p.f`, `!p.f`, or `p` itself: reads or lends the path. -/
  | use (p : Path)
  /-- `<p.f`, or `<p`: moves the path out to a new owner. -/
  | take (p : Path)
  /-- `p.f = x`, or `p = x`: drops what the path still holds, and puts
  a new value of type `s` there. -/
  | assign (p : Path) (s : A)

/-- One step of the checker. A use or a move touches its path, so no
field in it may be moved; a field that copies takes no `<`, and no field
of an object with a `drop` body moves; an assignment may refill a path
that is moved, or partly moved, but not one inside a moved field. -/
def step (a : A) : Op → Option A
  | .use p => match a.get p with
    | some b => if b.whole then some a else none
    | none => none
  | .take p => match a.get p with
    | some b => if b.whole && b != .plain && !a.dropAbove p then some (a.set p .gone) else none
    | none => none
  | .assign p s => match a.get p with
    | some _ => if s.whole then some (a.set p s) else none
    | none => none

/-- The checker, on a local of type `a`. -/
def check : A → List Op → Bool
  | _, [] => true
  | a, op :: ops => match step a op with
    | some a' => check a' ops
    | none => false

/-! ## The machine -/

inductive Fault where
  /-- A use of a moved field, or a `drop` body that finds one. -/
  | moved
  /-- A cell freed twice. -/
  | freed
  /-- A path into something that is not an object. -/
  | stuck
  /-- Cells left when the scope ends. -/
  | leak
  deriving DecidableEq, Repr

def O.cells : O → List Loc
  | .own l => [l]
  | .node _ l r => l.cells ++ r.cells
  | _ => []

def O.get : O → Path → Except Fault O
  | t, [] => .ok t
  | .node _ l _, false :: p => l.get p
  | .node _ _ r, true :: p => r.get p
  | .gone, _ :: _ => .error .moved
  | _, _ :: _ => .error .stuck

def O.set : O → Path → O → O
  | _, [], w => w
  | .node d l r, false :: p, w => .node d (l.set p w) r
  | .node d l r, true :: p, w => .node d l (r.set p w)
  | t, _ :: _, _ => t

/-- Drop a value: free each cell it still owns; a `drop` body reads
every field of its object first. `al` is the cells allocated. -/
def dropO : O → List Loc → Except Fault (List Loc)
  | .own l, al => if l ∈ al then .ok (al.erase l) else .error .freed
  | .plain _, al => .ok al
  | .gone, al => .ok al
  | .node d l r, al =>
    if d && !(l.abs.whole && r.abs.whole) then .error .moved
    else match dropO l al with
      | .ok al => dropO r al
      | .error e => .error e

def dropAll : List O → List Loc → Except Fault (List Loc)
  | [], al => .ok al
  | v :: vs, al => match dropO v al with
    | .ok al => dropAll vs al
    | .error e => .error e

/-- A new value of type `a`, its cells allocated from `n` on. -/
def fresh : A → Nat → O × Nat
  | .own, n => (.own n, n + 1)
  | .plain, n => (.plain 0, n)
  | .gone, n => (.gone, n)
  | .node d l r, n => (.node d (fresh l n).1 (fresh r (fresh l n).2).1, (fresh r (fresh l n).2).2)

/-- The machine: the local, the values moved out of it, held by their
new owners, the cells allocated, and the next free cell. -/
structure St where
  t : O
  taken : List O
  alloc : List Loc
  next : Nat

def runOp (s : St) : Op → Except Fault St
  | .use p => match s.t.get p with
    | .ok v => if v.abs.whole then .ok s else .error .moved
    | .error e => .error e
  | .take p => match s.t.get p with
    | .ok v => if v.abs.whole then .ok { s with t := s.t.set p .gone, taken := v :: s.taken }
      else .error .moved
    | .error e => .error e
  | .assign p a => match s.t.get p with
    | .ok old => match dropO old s.alloc with
      | .ok al =>
        .ok ⟨s.t.set p (fresh a s.next).1, s.taken, (fresh a s.next).1.cells ++ al, (fresh a s.next).2⟩
      | .error e => .error e
    | .error e => .error e

def runOps : St → List Op → Except Fault St
  | s, [] => .ok s
  | s, op :: ops => match runOp s op with
    | .ok s => runOps s ops
    | .error e => .error e

/-- Where the scope ends: the local drops what it still holds, each new
owner drops what it took, and no cell may be left. -/
def finish (s : St) : Except Fault Unit :=
  match dropO s.t s.alloc with
  | .ok al => match dropAll s.taken al with
    | .ok [] => .ok ()
    | .ok _ => .error .leak
    | .error e => .error e
  | .error e => .error e

/-- A local of type `a`, made new, then the program, then its scope's end. -/
def run (a : A) (ops : List Op) : Except Fault Unit :=
  let (t, n) := fresh a 0
  match runOps { t := t, taken := [], alloc := t.cells, next := n } ops with
  | .ok s => finish s
  | .error e => .error e

/-! ## What the checker's state says of the machine -/

theorem get_abs : ∀ (p : Path) (t : O) {b : A}, t.abs.get p = some b → ∃ v, t.get p = .ok v ∧ v.abs = b
  | [], t, b, h => ⟨t, by simp [O.get], by simpa [A.get] using h⟩
  | false :: p, .node _ l _, b, h => get_abs p l (by simpa [O.abs, A.get] using h)
  | true :: p, .node _ _ r, b, h => get_abs p r (by simpa [O.abs, A.get] using h)
  | _ :: _, .own _, _, h => by simp [O.abs, A.get] at h
  | _ :: _, .plain _, _, h => by simp [O.abs, A.get] at h
  | _ :: _, .gone, _, h => by simp [O.abs, A.get] at h

theorem set_abs : ∀ (p : Path) (t w : O), (t.set p w).abs = t.abs.set p w.abs
  | [], _, _ => by simp [O.set, A.set]
  | false :: p, .node d l r, w => by simp [O.set, O.abs, A.set, set_abs p l w]
  | true :: p, .node d l r, w => by simp [O.set, O.abs, A.set, set_abs p r w]
  | _ :: _, .own _, _ => by simp [O.set, O.abs, A.set]
  | _ :: _, .plain _, _ => by simp [O.set, O.abs, A.set]
  | _ :: _, .gone, _ => by simp [O.set, O.abs, A.set]

theorem whole_dropOk : ∀ (a : A), a.whole = true → a.dropOk = true
  | .node d l r, h => by
    simp only [A.whole, Bool.and_eq_true] at h
    simp [A.dropOk, h.1, h.2, whole_dropOk l h.1, whole_dropOk r h.2]
  | .own, _ | .plain, _ | .gone, _ => rfl

theorem get_dropOk : ∀ (p : Path) (a : A) {b : A}, a.get p = some b → a.dropOk = true →
    b.dropOk = true
  | [], a, b, h, hd => by simp [A.get] at h; exact h ▸ hd
  | false :: p, .node _ l _, b, h, hd => by
    simp only [A.dropOk, Bool.and_eq_true] at hd
    exact get_dropOk p l (by simpa [A.get] using h) hd.1.2
  | true :: p, .node _ _ r, b, h, hd => by
    simp only [A.dropOk, Bool.and_eq_true] at hd
    exact get_dropOk p r (by simpa [A.get] using h) hd.2
  | _ :: _, .own, _, h, _ | _ :: _, .plain, _, h, _ | _ :: _, .gone, _, h, _ => by
    simp [A.get] at h

theorem whole_set : ∀ (p : Path) (a w : A), a.whole = true → w.whole = true →
    (a.set p w).whole = true
  | [], _, _, _, hw => by simpa [A.set] using hw
  | false :: p, .node d l r, w, ha, hw => by
    simp only [A.whole, Bool.and_eq_true] at ha
    simp [A.set, A.whole, whole_set p l w ha.1 hw, ha.2]
  | true :: p, .node d l r, w, ha, hw => by
    simp only [A.whole, Bool.and_eq_true] at ha
    simp [A.set, A.whole, whole_set p r w ha.2 hw, ha.1]
  | _ :: _, .own, _, ha, _ | _ :: _, .plain, _, ha, _ | _ :: _, .gone, _, ha, _ => by
    simpa [A.set] using ha

/-- Putting a value at a path keeps every `drop` body's fields, when the
value has every field or no object above the path has a `drop` body. -/
theorem dropOk_set : ∀ (p : Path) (a w : A), a.dropOk = true → w.dropOk = true →
    (w.whole = true ∨ a.dropAbove p = false) → (a.set p w).dropOk = true
  | [], _, _, _, hw, _ => by simpa [A.set] using hw
  | false :: p, .node d l r, w, ha, hw, hc => by
    simp only [A.dropOk, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true'] at ha
    have hc' : w.whole = true ∨ l.dropAbove p = false := by
      rcases hc with h | h
      · exact Or.inl h
      · simp [A.dropAbove] at h; exact Or.inr h.2
    have hl := dropOk_set p l w ha.1.2 hw hc'
    simp only [A.set, A.dropOk, hl, ha.2, Bool.and_true, Bool.or_eq_true, Bool.not_eq_true',
      Bool.and_eq_true]
    rcases ha.1.1 with hd | hd
    · exact Or.inl hd
    · cases d with
      | false => exact Or.inl rfl
      | true =>
        rcases hc with h | h
        · exact Or.inr ⟨whole_set p l w hd.1 h, hd.2⟩
        · simp [A.dropAbove] at h
  | true :: p, .node d l r, w, ha, hw, hc => by
    simp only [A.dropOk, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true'] at ha
    have hc' : w.whole = true ∨ r.dropAbove p = false := by
      rcases hc with h | h
      · exact Or.inl h
      · simp [A.dropAbove] at h; exact Or.inr h.2
    have hr := dropOk_set p r w ha.2 hw hc'
    simp only [A.set, A.dropOk, hr, ha.1.2, Bool.and_true, Bool.or_eq_true, Bool.not_eq_true',
      Bool.and_eq_true]
    rcases ha.1.1 with hd | hd
    · exact Or.inl hd
    · cases d with
      | false => exact Or.inl rfl
      | true =>
        rcases hc with h | h
        · exact Or.inr ⟨hd.1, whole_set p r w hd.2 h⟩
        · simp [A.dropAbove] at h
  | _ :: _, .own, _, ha, _, _ | _ :: _, .plain, _, ha, _, _ | _ :: _, .gone, _, ha, _, _ => by
    simpa [A.set] using ha

/-! ## Cells -/

theorem perm_count {l₁ l₂ : List Loc} : l₁.Perm l₂ ↔ ∀ x, l₁.count x = l₂.count x :=
  List.perm_iff_count

/-- A path's value and the rest of the object own the object's cells. -/
theorem cells_set : ∀ (p : Path) (t : O) {v : O} (w : O), t.get p = .ok v →
    ∀ x, (t.set p w).cells.count x + v.cells.count x = t.cells.count x + w.cells.count x
  | [], t, v, w, h, x => by
    simp only [O.get, Except.ok.injEq] at h; subst h; simp [O.set]; omega
  | false :: p, .node d l r, v, w, h, x => by
    have := cells_set p l w h x
    simp only [O.set, O.cells, List.count_append]; omega
  | true :: p, .node d l r, v, w, h, x => by
    have := cells_set p r w h x
    simp only [O.set, O.cells, List.count_append]; omega
  | _ :: _, .own _, _, _, h, _ | _ :: _, .plain _, _, _, h, _ | _ :: _, .gone, _, _, h, _ => by
    simp [O.get] at h

/-- Dropping a value whose `drop` bodies find every field frees its
cells, once each. -/
theorem dropO_ok : ∀ (v : O) {al rest : List Loc}, v.abs.dropOk = true →
    al.Perm (v.cells ++ rest) → ∃ al', dropO v al = .ok al' ∧ al'.Perm rest
  | .own l, al, rest, _, hp => by
    have hl : l ∈ al := hp.symm.subset (by simp [O.cells])
    refine ⟨al.erase l, by simp [dropO, hl], ?_⟩
    have := hp.erase l
    simpa [O.cells] using this
  | .plain _, al, rest, _, hp => ⟨al, rfl, by simpa [O.cells] using hp⟩
  | .gone, al, rest, _, hp => ⟨al, rfl, by simpa [O.cells] using hp⟩
  | .node d l r, al, rest, hd, hp => by
    simp only [O.abs, A.dropOk, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true'] at hd
    obtain ⟨⟨hd0, hl⟩, hr⟩ := hd
    have hp' : al.Perm (l.cells ++ (r.cells ++ rest)) := by simpa [O.cells, List.append_assoc] using hp
    obtain ⟨al1, h1, hp1⟩ := dropO_ok l hl hp'
    obtain ⟨al2, h2, hp2⟩ := dropO_ok r hr hp1
    refine ⟨al2, ?_, hp2⟩
    have hg : (d && !(l.abs.whole && r.abs.whole)) = false := by
      rcases hd0 with h | h
      · simp [h]
      · simp [h.1, h.2]
    simp only [dropO, hg, Bool.false_eq_true, ite_false, h1, h2]

theorem dropAll_ok : ∀ (vs : List O) {al rest : List Loc}, (∀ v ∈ vs, v.abs.whole = true) →
    al.Perm (vs.flatMap O.cells ++ rest) → ∃ al', dropAll vs al = .ok al' ∧ al'.Perm rest
  | [], al, rest, _, hp => ⟨al, rfl, by simpa using hp⟩
  | v :: vs, al, rest, hw, hp => by
    have hp' : al.Perm (v.cells ++ (vs.flatMap O.cells ++ rest)) := by
      simpa [List.flatMap_cons, List.append_assoc] using hp
    obtain ⟨al1, h1, hp1⟩ := dropO_ok v (whole_dropOk _ (hw v (by simp))) hp'
    obtain ⟨al2, h2, hp2⟩ := dropAll_ok vs (fun v' hv' => hw v' (by simp [hv'])) hp1
    exact ⟨al2, by simp [dropAll, h1, h2], hp2⟩

theorem fresh_spec : ∀ (a : A) (n : Nat),
    (fresh a n).1.abs = a ∧ n ≤ (fresh a n).2 ∧
    (∀ l ∈ (fresh a n).1.cells, n ≤ l ∧ l < (fresh a n).2) ∧ (fresh a n).1.cells.Nodup
  | .own, n => by simp [fresh, O.abs, O.cells]
  | .plain, n => by simp [fresh, O.abs, O.cells]
  | .gone, n => by simp [fresh, O.abs, O.cells]
  | .node d l r, n => by
    obtain ⟨al, nl, cl, dl⟩ := fresh_spec l n
    obtain ⟨ar, nr, cr, dr⟩ := fresh_spec r (fresh l n).2
    refine ⟨by simp [fresh, O.abs, al, ar], by simp only [fresh]; omega, ?_, ?_⟩
    · intro x hx
      simp only [fresh, O.cells, List.mem_append] at hx
      rcases hx with hx | hx
      · obtain ⟨h1, h2⟩ := cl x hx
        exact ⟨h1, Nat.lt_of_lt_of_le h2 nr⟩
      · obtain ⟨h1, h2⟩ := cr x hx
        exact ⟨Nat.le_trans nl h1, h2⟩
    · simp only [fresh, O.cells]
      refine List.nodup_append.2 ⟨dl, dr, fun x hx y hy => ?_⟩
      exact Nat.ne_of_lt (Nat.lt_of_lt_of_le (cl x hx).2 (cr y hy).1)

/-! ## Soundness -/

/-- The machine is what the checker's state says: the local has type
`a` with its moved fields `gone`, every `drop` body would find its
fields, every value moved out is whole, and the cells allocated are
exactly, once each, those the local and the moved values still own. -/
structure Inv (a : A) (s : St) : Prop where
  abs : s.t.abs = a
  dropOk : a.dropOk = true
  taken : ∀ v ∈ s.taken, v.abs.whole = true
  cells : s.alloc.Perm (s.t.cells ++ s.taken.flatMap O.cells)
  nodup : s.alloc.Nodup
  bound : ∀ l ∈ s.alloc, l < s.next

theorem step_ok {a a' : A} {s : St} {op : Op} (hi : Inv a s) (hs : step a op = some a') :
    ∃ s', runOp s op = .ok s' ∧ Inv a' s' := by
  cases op with
  | use p =>
    simp only [step] at hs
    cases hb : a.get p with
    | none => simp [hb] at hs
    | some b =>
      simp only [hb] at hs
      split at hs
      · rename_i hw
        cases hs
        obtain ⟨v, hv, hva⟩ := get_abs p s.t (hi.abs ▸ hb)
        exact ⟨s, by simp [runOp, hv, hva, hw], hi⟩
      · simp at hs
  | take p =>
    simp only [step] at hs
    cases hb : a.get p with
    | none => simp [hb] at hs
    | some b =>
      simp only [hb] at hs
      split at hs
      · rename_i hw
        cases hs
        simp only [Bool.and_eq_true, Bool.not_eq_true'] at hw
        obtain ⟨⟨hw1, -⟩, hw3⟩ := hw
        obtain ⟨v, hv, hva⟩ := get_abs p s.t (hi.abs ▸ hb)
        refine ⟨{ s with t := s.t.set p .gone, taken := v :: s.taken },
          by simp [runOp, hv, hva, hw1], ?_⟩
        refine ⟨?_, ?_, ?_, ?_, hi.nodup, hi.bound⟩
        · simp [set_abs, hi.abs, O.abs]
        · exact dropOk_set p a .gone hi.dropOk rfl (Or.inr hw3)
        · intro v' hv'
          simp only [List.mem_cons] at hv'
          rcases hv' with rfl | hv'
          · rw [hva]; exact hw1
          · exact hi.taken v' hv'
        · refine hi.cells.trans (perm_count.2 fun x => ?_)
          have := cells_set p s.t .gone hv x
          simp only [List.count_append, List.flatMap_cons, O.cells, List.count_nil] at this ⊢
          omega
      · simp at hs
  | assign p a2 =>
    simp only [step] at hs
    cases hb : a.get p with
    | none => simp [hb] at hs
    | some b =>
      simp only [hb] at hs
      split at hs
      · rename_i hw
        cases hs
        obtain ⟨old, hold, hoa⟩ := get_abs p s.t (hi.abs ▸ hb)
        have hdo : old.abs.dropOk = true := hoa ▸ get_dropOk p a hb hi.dropOk
        have hp0 : s.alloc.Perm (old.cells ++ ((s.t.set p .gone).cells ++ s.taken.flatMap O.cells)) := by
          refine hi.cells.trans (perm_count.2 fun x => ?_)
          have := cells_set p s.t .gone hold x
          simp only [List.count_append, O.cells, List.count_nil] at this ⊢
          omega
        obtain ⟨al, hal, hpal⟩ := dropO_ok old hdo hp0
        obtain ⟨fa, fn, fc, fd⟩ := fresh_spec a2 s.next
        refine ⟨⟨s.t.set p (fresh a2 s.next).1, s.taken, (fresh a2 s.next).1.cells ++ al,
          (fresh a2 s.next).2⟩, by simp [runOp, hold, hal], ?_⟩
        have hsub : ∀ l ∈ al, l ∈ s.alloc := fun l hl =>
          hp0.symm.subset (List.mem_append_right _ (hpal.subset hl))
        refine ⟨?_, ?_, hi.taken, ?_, ?_, ?_⟩
        · simp [set_abs, hi.abs, fa]
        · exact dropOk_set p a a2 hi.dropOk (whole_dropOk _ hw) (Or.inl hw)
        · refine (List.Perm.append_left _ hpal).trans (perm_count.2 fun x => ?_)
          have h1 := cells_set p s.t (fresh a2 s.next).1 hold x
          have h2 := cells_set p s.t .gone hold x
          simp only [List.count_append, O.cells, List.count_nil] at h1 h2 ⊢
          omega
        · have hnd : al.Nodup := hpal.nodup_iff.2
            ((hp0.nodup_iff.1 hi.nodup).sublist (List.sublist_append_right _ _))
          refine List.nodup_append.2 ⟨fd, hnd, fun x hx y hy => ?_⟩
          exact (Nat.ne_of_lt (Nat.lt_of_lt_of_le (hi.bound y (hsub y hy)) (fc x hx).1)).symm
        · intro l hl
          simp only [List.mem_append] at hl
          rcases hl with hl | hl
          · exact (fc l hl).2
          · exact Nat.lt_of_lt_of_le (hi.bound l (hsub l hl)) fn
      · simp at hs

theorem runOps_ok : ∀ (ops : List Op) {a : A} {s : St}, Inv a s → check a ops = true →
    ∃ a' s', runOps s ops = .ok s' ∧ Inv a' s'
  | [], a, s, hi, _ => ⟨a, s, rfl, hi⟩
  | op :: ops, a, s, hi, hc => by
    simp only [check] at hc
    cases hs : step a op with
    | none => simp [hs] at hc
    | some a' =>
      simp only [hs] at hc
      obtain ⟨s', h1, hi'⟩ := step_ok hi hs
      obtain ⟨a'', s'', h2, hi''⟩ := runOps_ok ops hi' hc
      exact ⟨a'', s'', by simp [runOps, h1, h2], hi''⟩

/-- **A partly moved local runs without a fault.** If the checker
accepts a program on a local of a type with every field, then run from
a new value of that type to its scope's end it uses no moved field,
frees no cell twice, runs no `drop` body that finds a field moved, and
leaves no cell allocated: the local drops only the fields it still
holds, and every field moved out is dropped once, by its new owner. -/
theorem fields_run (a : A) (ha : a.whole = true) (ops : List Op) (hc : check a ops = true) :
    run a ops = .ok () := by
  obtain ⟨fa, -, fc, fd⟩ := fresh_spec a 0
  have hi : Inv a ⟨(fresh a 0).1, [], (fresh a 0).1.cells, (fresh a 0).2⟩ :=
    ⟨fa, whole_dropOk a ha, by simp, by simp, fd, fun l hl => (fc l hl).2⟩
  obtain ⟨a', s', hr, hi'⟩ := runOps_ok ops hi hc
  have hp : s'.alloc.Perm (s'.t.cells ++ (s'.taken.flatMap O.cells ++ [])) := by
    simpa using hi'.cells
  obtain ⟨al, h1, hp1⟩ := dropO_ok s'.t (hi'.abs ▸ hi'.dropOk) hp
  obtain ⟨al2, h2, hp2⟩ := dropAll_ok s'.taken hi'.taken hp1
  have : al2 = [] := List.Perm.eq_nil hp2
  subst this
  simp only [run]
  rw [hr]
  simp [finish, h1, h2]

-- The proof assumes nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.Fields.fields_run' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms fields_run

/-! ## Examples -/

/-- `obj Entry` with `key: String` and `value: String`. -/
def entry : A := .node false .own .own

/-- CORE §5: `v = <e.value`, `print(e.key, v)`, `e.value = String("w")`,
`value_of(<e)`. -/
def entryOps : List Op := [.take [true], .use [false], .assign [true] .own, .take []]

#guard check entry entryOps

/-- info: Except.ok () -/
#guard_msgs in #eval run entry entryOps

/-- Rejected: `v = <e.value`, `f = <e` ("`e` is partly moved"). -/
def partlyMoved : List Op := [.take [true], .take []]

#guard !check entry partlyMoved

/-- info: Except.error (LambdaRig.Fields.Fault.moved) -/
#guard_msgs in #eval run entry partlyMoved

-- Rejected: `v = <e.value`, `print(e.value)`.
#guard !check entry [.take [true], .use [true]]

/-- info: Except.error (LambdaRig.Fields.Fault.moved) -/
#guard_msgs in #eval run entry [.take [true], .use [true]]

/-- `obj File` with `name: String` and a `drop` body: `n = <f.name` is
rejected ("`File` has a `drop` body, which expects every field"). -/
def file : A := .node true .own .plain

#guard !check file [.take [false]]

/-- info: Except.error (LambdaRig.Fields.Fault.moved) -/
#guard_msgs in #eval run file [.take [false]]

end LambdaRig.Fields
