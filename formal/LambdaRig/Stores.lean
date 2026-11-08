/-
λRig: views kept and stored, over values.

`within_live` (Calls.lean) proves the clauses sound by argument
position: an implementation within the API's `from` and `keeps` leaves
views only of the arguments they name. This file proves it of values: a
value is plain, a view carrying its loan and seeing a value, or an
object (a List, an optional, a field's holder) of parts, at any depth,
and a body builds its result and what it stores from its arguments, by
reading parts of what they see.

CORE sentence 6: "A loan lasts until the last use of every view that
carries it, wherever that view went: a field, an array, an optional, a
closure, a result." Sentence 7: a result "carries the loans of the
arguments whose types could hold what it views, or, when the result
says `from a`, of `a` alone"; "A view reached through a read view that a
value holds carries that view's loans, not a loan on the holder"; and
what a call stores "in what a write view lent to it sees carries, in the
same way, the loans of the arguments whose types could hold it", which
`keeps` narrows. "A kept loan lasts while the holder is used." The
compiler checks each body against its signature ("a body that stores a
lent parameter, on any path ... names it in `keeps`"): `Body.Meets`.

The results:

- `carried_eval`: every loan a body's value carries, at any depth, is
  carried by an argument the body read (`B.src`);
- `body_records`: for a body within clauses within the API's, the loans
  its result carries are among those the caller records for `from`,
  and those of what it stores among those it records for `keeps`;
- `stores_live`: so after anything the caller does that its record
  allows (`After`), every loan the result carries, and every loan the
  holder it stored into carries, is still live;
- `part_read_view`: a read view reached through a view is that view,
  its own loans and not the holder's.
-/
import LambdaRig.Calls

namespace LambdaRig

/-! ## Values -/

/-- A value, as far as loans go. -/
inductive V where
  /-- Plain data. -/
  | int (n : Int)
  /-- A view of what lives for the whole program: a `Static`, a module
  constant. It carries no loan (sentence 7). -/
  | static
  /-- A view, carrying the loan `a`, of the value `seen` that its
  owner's place holds. -/
  | view (m : Mode) (a : Loan) (seen : V)
  /-- An object of two parts: a field's holder, a List, an optional.
  More parts nest. -/
  | node (l r : V)

/-- The loans a value carries: its views', and those of the views each
reaches, at any depth. -/
def V.carried : V → List Loan
  | .int _ | .static => []
  | .view _ a s => a :: s.carried
  | .node l r => l.carried ++ r.carried

/-- One part of a value, `d` choosing which: a part of an object held
by value, or a place inside what a view sees. A read view the object
holds is itself (CORE 7: "carries that view's loans, not a loan on the
holder"); plain data copies; any other place is seen through the view,
under its loan. -/
def V.part : V → Bool → V
  | .node l r, d => if d then r else l
  | .view m a (.node l r), d =>
    match (if d then r else l) with
    | .view .read a' s => .view .read a' s
    | .int n => .int n
    | .static => .static
    | p => .view m a p
  | _, _ => .int 0

theorem V.carried_part (v : V) (d : Bool) : ∀ a ∈ (v.part d).carried, a ∈ v.carried := by
  intro a ha
  cases v with
  | node l r => cases d <;> simp_all [V.part, V.carried]
  | view m b s =>
    cases s with
    | node l r =>
      simp only [V.part] at ha
      have hp : ∀ a ∈ (if d then r else l).carried, a ∈ (V.view m b (.node l r)).carried := by
        intro a h; cases d <;> simp_all [V.carried]
      revert ha
      split
      · intro ha; exact hp a (by rename_i h; rw [h]; exact ha)
      · simp [V.carried]
      · simp [V.carried]
      · intro ha
        simp only [V.carried, List.mem_cons] at ha
        rcases ha with rfl | ha
        · simp [V.carried]
        · exact hp a ha
    | _ => simp [V.part, V.carried] at ha
  | _ => simp [V.part, V.carried] at ha

/-- **A read view reached through a view is that view.** Reading a
part of what `?p` sees, when the part is a read view, gives that view,
which carries its own loans and not `p`'s (CORE 7). -/
theorem part_read_view (m : Mode) (a a' : Loan) (s l r : V) (d : Bool)
    (h : (if d then r else l) = .view .read a' s) :
    (V.view m a (.node l r)).part d = .view .read a' s := by
  simp only [V.part, h]

/-! ## Bodies -/

/-- A body's value: an argument, a literal, a `Static`, an object made
of two parts, or a part of a value. -/
inductive B where
  | arg (i : Nat)
  | lit (n : Int)
  | static
  | mk (l r : B)
  | part (b : B) (d : Bool)

/-- The arguments' values, by position. -/
def argv (args : List V) (i : Nat) : V := (args[i]?).getD (.int 0)

def B.eval (args : List V) : B → V
  | .arg i => argv args i
  | .lit n => .int n
  | .static => .static
  | .mk l r => .node (l.eval args) (r.eval args)
  | .part b d => (b.eval args).part d

/-- The parameters a body's value is built from: what the compiler reads
of a body to check it against `from` and `keeps`. -/
def B.src : B → List Nat
  | .arg i => [i]
  | .lit _ | .static => []
  | .mk l r => l.src ++ r.src
  | .part b _ => b.src

/-- **What a value is built from, it carries no more than.** -/
theorem carried_eval (args : List V) (b : B) :
    ∀ a ∈ (b.eval args).carried, ∃ i ∈ b.src, a ∈ (argv args i).carried := by
  induction b with
  | arg i => intro a ha; exact ⟨i, by simp [B.src], ha⟩
  | lit n => intro a ha; simp [B.eval, V.carried] at ha
  | static => intro a ha; simp [B.eval, V.carried] at ha
  | mk l r ihl ihr =>
    intro a ha
    simp only [B.eval, V.carried, List.mem_append] at ha
    rcases ha with ha | ha
    · obtain ⟨i, hi, h⟩ := ihl a ha
      exact ⟨i, by simp [B.src, hi], h⟩
    · obtain ⟨i, hi, h⟩ := ihr a ha
      exact ⟨i, by simp [B.src, hi], h⟩
  | part b d ih =>
    intro a ha
    exact ih a (V.carried_part _ d a ha)

/-- A body: its result, and the values it stores, each into what the
write view at some parameter sees, at some path. -/
structure Body where
  result : B
  stores : List (Nat × List Bool × B)

/-- The compiler's check of a body against its own clauses: its result
is built only from parameters its `from` names, and what it stores only
from parameters its `keeps` names. -/
def Body.Meets (f : Body) (c : Clauses) : Prop :=
  (∀ i ∈ f.result.src, i ∈ c.src) ∧ (∀ s ∈ f.stores, ∀ i ∈ s.2.2.src, i ∈ c.keeps)

/-- The loans a caller records for the parameters at `ps`: every loan
each argument carries. -/
def recOf (args : List V) (ps : List Nat) : List Loan := ps.flatMap fun i => (argv args i).carried

theorem mem_recOf {args : List V} {ps : List Nat} {a : Loan} {i : Nat} (hi : i ∈ ps)
    (ha : a ∈ (argv args i).carried) : a ∈ recOf args ps := by
  simp only [recOf, List.mem_flatMap]
  exact ⟨i, hi, ha⟩

/-- **Subsumption, over values.** A body within clauses within the
API's builds a result carrying only loans the caller records for the
API's `from`, and stores values carrying only loans it records for the
API's `keeps`. -/
theorem body_records {f : Body} {c api : Clauses} (hm : f.Meets c) (hw : c.Within api)
    (args : List V) :
    (∀ a ∈ (f.result.eval args).carried, a ∈ recOf args api.src) ∧
    (∀ s ∈ f.stores, ∀ a ∈ (s.2.2.eval args).carried, a ∈ recOf args api.keeps) := by
  refine ⟨fun a ha => ?_, fun s hs a ha => ?_⟩
  · obtain ⟨i, hi, h⟩ := carried_eval args _ a ha
    exact mem_recOf (hw.1 i (hm.1 i hi)) h
  · obtain ⟨i, hi, h⟩ := carried_eval args _ a ha
    exact mem_recOf (hw.2 i (hm.2 s hs i hi)) h

/-! ## Storing into a holder -/

/-- `v` with `w` stored at the path `p`: a field replaced, its old value
dropped. A path through a value with no parts stores at that value. -/
def V.setAt : V → List Bool → V → V
  | _, [], w => w
  | .node l r, d :: p, w => if d then .node l (r.setAt p w) else .node (l.setAt p w) r
  | _, _ :: _, w => w

theorem V.carried_setAt : ∀ (v : V) (p : List Bool) (w : V) (a : Loan),
    a ∈ (v.setAt p w).carried → a ∈ v.carried ∨ a ∈ w.carried
  | _, [], w, a, ha => Or.inr (by simpa [V.setAt] using ha)
  | .node l r, d :: p, w, a, ha => by
    cases d
    · simp only [V.setAt, Bool.false_eq_true, ite_false, V.carried, List.mem_append] at ha ⊢
      rcases ha with ha | ha
      · rcases V.carried_setAt l p w a ha with h | h
        · exact Or.inl (Or.inl h)
        · exact Or.inr h
      · exact Or.inl (Or.inr ha)
    · simp only [V.setAt, ite_true, V.carried, List.mem_append] at ha ⊢
      rcases ha with ha | ha
      · exact Or.inl (Or.inl ha)
      · rcases V.carried_setAt r p w a ha with h | h
        · exact Or.inl (Or.inr h)
        · exact Or.inr h
  | .int _, _ :: _, w, a, ha => Or.inr (by simpa [V.setAt] using ha)
  | .static, _ :: _, w, a, ha => Or.inr (by simpa [V.setAt] using ha)
  | .view _ _ _, _ :: _, w, a, ha => Or.inr (by simpa [V.setAt] using ha)

/-- A holder after a call's stores into it, at the parameter `j`. -/
def storeAll (args : List V) (j : Nat) (v : V) : List (Nat × List Bool × B) → V
  | [] => v
  | (k, p, b) :: ss => storeAll args j (if k = j then v.setAt p (b.eval args) else v) ss

theorem carried_storeAll (args : List V) (j : Nat) (ss : List (Nat × List Bool × B)) :
    ∀ (v : V), ∀ a ∈ (storeAll args j v ss).carried,
      a ∈ v.carried ∨ ∃ s ∈ ss, a ∈ (s.2.2.eval args).carried := by
  induction ss with
  | nil => intro v a ha; exact Or.inl ha
  | cons s ss ih =>
    obtain ⟨k, p, b⟩ := s
    intro v a ha
    simp only [storeAll] at ha
    rcases ih _ a ha with h | ⟨s', hs', h⟩
    · split at h
      · rcases V.carried_setAt v p _ a h with h | h
        · exact Or.inl h
        · exact Or.inr ⟨(k, p, b), by simp, h⟩
      · exact Or.inl h
    · exact Or.inr ⟨s', by simp [hs'], h⟩

/-- **Views stored and returned stay live while the caller's record
holds.** Every loan the arguments carry is live when the call is made,
and every loan the holder (what the write view at parameter `j` sees)
carries is live and among `rec`. After the call:

- whatever the caller does that the loans it records for the API's
  `from` allow keeps every loan the result carries live;
- whatever it does that `rec` and the loans it records for the API's
  `keeps` allow keeps every loan the holder now carries live: a kept
  loan lasts while the holder is used. -/
theorem stores_live {f : Body} {c api : Clauses} (hm : f.Meets c) (hw : c.Within api)
    {args : List V} {h : Loc → Option Cell}
    (hargs : ∀ i, ∀ a ∈ (argv args i).carried, a.Live h)
    {j : Nat} {v : V} {rec : List Loan} (hv : ∀ a ∈ v.carried, a ∈ rec ∧ a.Live h) :
    (∀ h', After (recOf args api.src) h h' → ∀ a ∈ (f.result.eval args).carried, a.Live h') ∧
    (∀ h', After (rec ++ recOf args api.keeps) h h' →
      ∀ a ∈ (storeAll args j v f.stores).carried, a.Live h') := by
  obtain ⟨hr, hs⟩ := body_records hm hw args
  refine ⟨fun h' hh a ha => hh.live (hr a ha) ?_, fun h' hh a ha => ?_⟩
  · obtain ⟨i, -, hi⟩ := carried_eval args _ a ha
    exact hargs i a hi
  · rcases carried_storeAll args j f.stores v a ha with h1 | ⟨s, hs', h1⟩
    · exact hh.live (List.mem_append_left _ (hv a h1).1) (hv a h1).2
    · refine hh.live (List.mem_append_right _ (hs s hs' a h1)) ?_
      obtain ⟨i, -, hi⟩ := carried_eval args _ a h1
      exact hargs i a hi

-- The proofs assume nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.stores_live' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms stores_live

/-! ### Examples -/

namespace Stores

/-- CORE sentence 7's `Cursor`: `next(!@)` returns `?@items[@i - 1]`,
where `items: ?List[Item]`. Self is a write view, under the loan `cur`,
of a cursor whose first field is a read view of the List, under `list`. -/
def cur : Loan := ⟨.write, 0, 0⟩
def list : Loan := ⟨.read, 1, 1⟩
def cursor : V := .view .write cur (.node (.view .read list (.node (.node (.int 1) (.int 0)) (.int 0))) (.int 0))

/-- `?@items[0]`: the first element of what `@items` sees. -/
def next : B := .part (.part (.arg 0) false) false

/-- The item views the List, not the cursor, which moves on. -/
example : (next.eval [cursor]).carried.map Loan.t = [1] := rfl

/-- `sub watch(!@, s: ?String) keeps s` meets its clauses when it stores
`s` into a field of self; a body that stores `s` with no `keeps` does not. -/
def watch : Body := { result := .lit 0, stores := [(0, [true], .arg 1)] }

example : watch.Meets { src := [], keeps := [1] } := by
  simp [watch, Body.Meets, B.src]

example : ¬ watch.Meets { src := [], keeps := [] } := by
  simp [watch, Body.Meets, B.src]

end Stores

end LambdaRig
