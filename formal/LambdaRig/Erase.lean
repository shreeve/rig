/-
λRig: an API object hides its value's type, never its loans.

`?{A}`, `!{A}`, and `^{A}` hold a value of some type that provides `A`
(docs/CORE.md §4; docs/design/apis.md, Stage 4). The object carries
every loan the value carried, and only its methods reach the value.
This file proves that erasing a type keeps its loans, in three parts.

- **Types** (`erase_loans`, `allows_loans`): an object's type, as the
  checker sees it, is its kind and its loans, and the checker's rule for
  every access to an owner reads each name's loans alone. So any type
  that carries the object's loans gets the verdicts the erased type got
  (`allows_erase`).
- **Values** (`erase_live`): erasing evaluates as its operand, and the
  object's value carries a live loan on each owner its type's loans
  name.
- **Programs** (`erased_runs`): `EProg` adds erasure to the programs of
  LambdaRig/Calls.lean, `r: ?{A} = x`, `r: !{A} = <x`, `r: ^{A} = <x`,
  with the object's type rebuilt from its kind and loans alone and the
  object reached only through calls checked against an API's clauses. A
  program `checkE` accepts runs without a fault, by `api_calls_run`'s
  argument; a program without erasure checks as `checkP` checks it
  (`checkE_lift`), so the extension is conservative.
-/
import LambdaRig.Calls

namespace LambdaRig

/-! ## Erased types -/

/-- The kind of an API object: `?{A}` or `!{A}`, a view, or `^{A}`, a box. -/
inductive ObjKind where
  | view (m : Mode)
  | box
  deriving DecidableEq, Repr

/-- The loans a value of type `τ` carries, each by its mode and the
owner it is on: a view carries its own; an Int or a box, none. -/
def Ty.loans : Ty → List (Mode × Var)
  | .view m y => [(m, y)]
  | _ => []

/-- The type of an API object, as the checker sees it: its kind and its
loans, and nothing of the type it hides. -/
structure OTy where
  kind : ObjKind
  loans : List (Mode × Var)
  deriving DecidableEq, Repr

/-- Erasing a type: a view or a box becomes an object of its kind,
carrying its loans. -/
def Ty.erase : Ty → Option OTy
  | .view m y => some ⟨.view m, [(m, y)]⟩
  | .box => some ⟨.box, []⟩
  | _ => none

/-- The type the checker tracks for an object, rebuilt from its kind and
its loans alone. -/
def OTy.ty (o : OTy) : Option Ty :=
  match o.kind, o.loans with
  | .view m, [(m', y)] => if m = m' then some (.view m y) else none
  | .box, [] => some .box
  | _, _ => none

/-- **Erasing a type keeps its loans.** -/
theorem erase_loans {τ : Ty} {o : OTy} (h : τ.erase = some o) : o.loans = τ.loans := by
  cases τ <;> simp [Ty.erase] at h <;> subst h <;> rfl

/-- What the checker rebuilds from an object's kind and loans is the
type erased: in λRig a view's type is its loan, and a box holds an Int. -/
theorem erase_ty {τ : Ty} {o : OTy} (h : τ.erase = some o) : o.ty = some τ := by
  cases τ <;> simp [Ty.erase] at h <;> subst h <;> simp [OTy.ty]

/-- `allows`, reading each name's loans alone. -/
def allowsLoans (Δ : List (Var × List (Mode × Var))) (y : Var) (k : Access) (later : List Var) :
    Bool :=
  Δ.all fun p => p.2.all fun l => !(l.2 == y && later.contains p.1 && k.ends l.1)

/-- The checker's rule for an access to an owner reads only the loans
of the names in scope, never the types they hide. -/
theorem allows_loans (Γ : Ctx) (y : Var) (k : Access) (L : List Var) :
    allows Γ y k L = allowsLoans (Γ.map fun p => (p.1, p.2.loans)) y k L := by
  induction Γ with
  | nil => rfl
  | cons p Γ ih =>
    obtain ⟨v, τ⟩ := p
    simp only [allows, allowsLoans, List.all_cons, List.map_cons] at ih ⊢
    rw [ih]
    cases τ <;> simp [Ty.loans]

/-- **The checker's verdicts do not weaken when a type is erased.** A
name whose type is erased, then given any type carrying the object's
loans, is allowed exactly the accesses it was. -/
theorem allows_erase {Γ : Ctx} {x : Var} {τ τ' : Ty} {o : OTy} (he : τ.erase = some o)
    (h : τ'.loans = o.loans) (y : Var) (k : Access) (L : List Var) :
    allows ((x, τ) :: Γ) y k L = allows ((x, τ') :: Γ) y k L := by
  rw [allows_loans, allows_loans]
  simp [h, erase_loans he]

/-! ## Erasing a value -/

/-- The erasure, run: a read view copies, as a bare name does; a write
view or a box moves into the object, which keeps its box. -/
def ObjKind.operand : ObjKind → Var → Expr
  | .view .read, x => .name x
  | _, x => .move x

theorem fv_operand (k : ObjKind) (x : Var) : fv (k.operand x) = [x] := by
  cases k with
  | view m => cases m <;> rfl
  | box => rfl

/-- The type `check` gives the erasure run is the type erased. -/
theorem operand_check {Γ : Ctx} {M L M1 : List Var} {x : Var} {τx τ0 : Ty} {o : OTy}
    {k : ObjKind} (hx : Γ.lookup x = some τx) (he : τx.erase = some o) (hk : o.kind = k)
    (hc : check Γ M L (k.operand x) = some (τ0, M1)) : τ0 = τx := by
  cases τx with
  | view m y =>
    simp [Ty.erase] at he; subst he; subst hk
    cases m <;> simp [ObjKind.operand, check, hx] at hc
    · exact hc.2.1.symm
    · exact hc.2.2.1.symm
  | box =>
    simp [Ty.erase] at he; subst he; subst hk
    simp [ObjKind.operand, check, hx] at hc; exact hc.2.2.1.symm
  | _ => simp [Ty.erase] at he

/-- **The object carries every loan the value carried, live.** Run in
any machine that matches the scope, erasing `x` gives a value that
holds, for each loan of the object's type, a view of that owner whose
loan is live; the machine still matches the scope. -/
theorem erase_live {Γ : Ctx} {M L M1 : List Var} {x : Var} {τx τ0 : Ty} {o : OTy} {k : ObjKind}
    (hx : Γ.lookup x = some τx) (he : τx.erase = some o) (hk : o.kind = k)
    (hc : check Γ M L (k.operand x) = some (τ0, M1))
    {σ β : Var → Loc} {s : Machine} (r : Rel Γ M (fv (k.operand x) ++ L) σ β s []) :
    ∃ v s' β', (eval (k.operand x)).run s = .ok (v, s') ∧ Rel Γ M1 L σ β' s' (owned v) ∧
      ∀ m y, (m, y) ∈ o.loans →
        ∃ t, v = .view m (σ y) t ∧ ∃ c, s'.heap (σ y) = some c ∧ c.live m t = true := by
  obtain ⟨v, s', β', hrun, r', hf⟩ := sound _ Γ M L τ0 M1 σ β s hc r
  refine ⟨v, s', β', hrun, r', fun m y hl => ?_⟩
  rw [erase_loans he] at hl
  have h0 := operand_check hx he hk hc
  subst h0
  cases τ0 with
  | view m' y' =>
    simp [Ty.loans] at hl
    obtain ⟨rfl, rfl⟩ := hl
    obtain ⟨t, hv, -, -, hlive⟩ := hf
    exact ⟨t, hv, hlive⟩
  | _ => simp [Ty.loans] at hl

/-! ## Programs with erasure -/

/-- A program with calls through APIs and API objects. -/
inductive EProg where
  | expr (e : Expr)
  | bind (x : Var) (e : Expr) (rest : EProg)
  | call (r : Var) (api : Clauses) (impl : Impl) (args : List Var) (rest : EProg)
  /-- `r: ?{A} = x`, `r: !{A} = <x`, or `r: ^{A} = <x`, by `k`, followed
  by `rest`, the scope of `r`. -/
  | erase (r : Var) (k : ObjKind) (x : Var) (rest : EProg)

/-- The λRig program that runs: each call in place, each erasure as its
operand. -/
def EProg.elab : EProg → Expr
  | .expr e => e
  | .bind x e rest => .letIn x e rest.elab
  | .call r _ f args rest => .letIn r (f.inline args) rest.elab
  | .erase r k x rest => .letIn r (k.operand x) rest.elab

/-- The names a program uses. -/
def EProg.fv : EProg → List Var
  | .expr e => LambdaRig.fv e
  | .bind x e rest => LambdaRig.fv e ++ rest.fv.filter (· ≠ x)
  | .call r _ _ args rest => args ++ rest.fv.filter (· ≠ r)
  | .erase r _ x rest => x :: rest.fv.filter (· ≠ r)

/-- `e` names none of `objs`: only a method reaches an object's value,
so nothing reads, assigns, or moves it in place. -/
def Expr.avoids (e : Expr) (objs : List Var) : Bool := (fv e).all fun v => !objs.contains v

/-- `checkP`, with erasure: the object's type is rebuilt from its kind
and loans alone, and the names in `objs`, the objects in scope, are
reached only by calls checked against their APIs' clauses. -/
def checkE (Γ : Ctx) (moved later objs : List Var) : EProg → Option (Ty × List Var)
  | .expr e => do
    guard (e.avoids objs)
    check Γ moved later e
  | .bind x e rest => do
    guard (e.avoids objs)
    guard ((Γ.lookup x).isNone && !moved.contains x)
    let (τe, moved) ← check Γ moved (rest.fv.filter (· ≠ x) ++ later) e
    let (τ, moved) ← checkE ((x, τe) :: Γ) moved later objs rest
    guard (!τ.lentFrom x)
    some (τ, moved.filter (· ≠ x))
  | .call r api _ args rest => do
    guard ((Γ.lookup r).isNone && !moved.contains r)
    let τc ← checkCall Γ moved api args
    let (τ, moved) ← checkE ((r, τc) :: Γ) moved later objs rest
    guard (!τ.lentFrom r)
    some (τ, moved.filter (· ≠ r))
  | .erase r k x rest => do
    guard ((Γ.lookup r).isNone && !moved.contains r)
    let τx ← Γ.lookup x
    let o ← τx.erase
    guard (o.kind == k)
    let (_, moved) ← check Γ moved (rest.fv.filter (· ≠ r) ++ later) (k.operand x)
    let τo ← o.ty
    let (τ, moved) ← checkE ((r, τo) :: Γ) moved later (r :: objs) rest
    guard (!τ.lentFrom r)
    some (τ, moved.filter (· ≠ r))

/-- `rig check` for a program with API objects. -/
def acceptsE (p : EProg) : Bool := (checkE [] [] [] [] p).isSome

/-- Every call's implementation meets its own clauses, within its API's. -/
def EProg.Fits : EProg → Prop
  | .expr _ => True
  | .bind _ _ rest => rest.Fits
  | .call _ api f _ rest => f.Meets ∧ f.clauses.Within api ∧ rest.Fits
  | .erase _ _ _ rest => rest.Fits

theorem fv_elabE (p : EProg) (v : Var) : v ∈ fv p.elab ↔ v ∈ p.fv := by
  induction p generalizing v with
  | expr e => rfl
  | bind x e rest ih => simp [EProg.elab, EProg.fv, fv, ih]
  | call r api f args rest ih => simp [EProg.elab, EProg.fv, fv, ih, fv_inline]
  | erase r k x rest ih => simp [EProg.elab, EProg.fv, fv, ih, fv_operand]

theorem guard_then {c : Bool} {x : Option α} {r : α}
    (h : (do guard (c = true); x) = some r) : x = some r := by
  cases c
  · exact absurd h (by simp [guard, failure])
  · simpa [guard] using h

theorem guard_bind {c : Bool} {x : Option α} {r : α}
    (h : ((guard (c = true) : Option Unit).bind fun _ => x) = some r) : x = some r := by
  cases c
  · exact absurd h (by simp [guard, failure])
  · simpa [guard] using h

/-! ### The conservative extension -/

/-- A program of LambdaRig/Calls.lean, with no erasure. -/
def Prog.lift : Prog → EProg
  | .expr e => .expr e
  | .bind x e rest => .bind x e rest.lift
  | .call r api f args rest => .call r api f args rest.lift

theorem Prog.fv_lift (p : Prog) : p.lift.fv = p.fv := by
  induction p with
  | expr e => rfl
  | bind x e rest ih => simp [Prog.lift, EProg.fv, Prog.fv, ih]
  | call r api f args rest ih => simp [Prog.lift, EProg.fv, Prog.fv, ih]

theorem Prog.elab_lift (p : Prog) : p.lift.elab = p.elab := by
  induction p with
  | expr e => rfl
  | bind x e rest ih => simp [Prog.lift, EProg.elab, Prog.elab, ih]
  | call r api f args rest ih => simp [Prog.lift, EProg.elab, Prog.elab, ih]

theorem Expr.avoids_nil (e : Expr) : e.avoids [] = true := by simp [Expr.avoids]

/-- **A program without erasure checks as before.** `checkE` with no
object in scope is `checkP`, so it accepts exactly what `checkP` does,
and on a program with no calls, what `check` does (`checkP_noCalls`). -/
theorem checkE_lift (p : Prog) : ∀ {Γ M L}, checkE Γ M L [] p.lift = checkP Γ M L p := by
  induction p with
  | expr e => intros; simp [Prog.lift, checkE, checkP, Expr.avoids_nil, guard]
  | bind x e rest ih =>
    intro Γ M L
    simp only [Prog.lift, checkE, checkP, Prog.fv_lift, ih, Expr.avoids_nil]
    simp [guard]
  | call r api f args rest ih =>
    intro Γ M L
    simp only [Prog.lift, checkE, checkP, ih]

theorem acceptsE_lift (p : Prog) : acceptsE p.lift = acceptsP p := by
  simp [acceptsE, acceptsP, checkE_lift]

/-! ### Programs with erasure run as `check` accepts them -/

/-- A program `checkE` accepts, whose calls run implementations within
their APIs' clauses, runs as one `check` accepts with the same type: an
object's type, rebuilt from its loans, is the type `check` gives the
erasure run. -/
theorem checkE_elab (p : EProg) (hf : p.Fits) :
    ∀ {Γ M L objs r}, checkE Γ M L objs p = some r → check Γ M L p.elab = some r := by
  induction p with
  | expr e => intro _ _ _ _ _ h; exact guard_then h
  | bind x e rest ih =>
    intro Γ M L objs r hc
    have hl := check_later (Γ := Γ) (M := M) e (L := (fv rest.elab).filter (· ≠ x) ++ L)
      (L' := rest.fv.filter (· ≠ x) ++ L) (by simp [fv_elabE])
    simp only [checkE] at hc
    replace hc := guard_then hc
    simp only [EProg.elab, check, hl]
    refine obind_congr hc fun _ hc => ?_
    refine obind_congr hc fun _ hc => ?_
    exact obind_src hc fun _ h2 => ih hf h2
  | call r api f args rest ih =>
    intro Γ M L objs r' hc
    obtain ⟨hm, hw, hf⟩ := hf
    simp only [checkE] at hc
    simp only [EProg.elab, check]
    refine obind_congr hc fun _ hc => ?_
    cases h1 : checkCall Γ M api args with
    | none => rw [h1] at hc; exact absurd hc (by simp)
    | some τc =>
      rw [h1] at hc
      rw [inline_check f hm hw h1]
      show (check ((r, τc) :: Γ) M L rest.elab >>= _) = some r'
      exact obind_src (o := checkE ((r, τc) :: Γ) M L objs rest) hc fun _ h2 => ih hf h2
  | erase r k x rest ih =>
    intro Γ M L objs r' hc
    have hl := check_later (Γ := Γ) (M := M) (k.operand x)
      (L := (fv rest.elab).filter (· ≠ r) ++ L) (L' := rest.fv.filter (· ≠ r) ++ L)
      (by simp [fv_elabE])
    simp only [checkE] at hc
    simp only [EProg.elab, check, hl]
    refine obind_congr hc fun _ hc => ?_
    cases hx : Γ.lookup x with
    | none => rw [hx] at hc; exact absurd hc (by simp)
    | some τx =>
      cases he : τx.erase with
      | none => simp [hx, he] at hc
      | some o =>
        simp only [hx, he, Option.bind_eq_bind, Option.bind_some] at hc
        by_cases hk : o.kind ≠ k
        · exact absurd hc (by simp [hk, guard, failure])
        simp only [ne_eq, Decidable.not_not] at hk
        replace hc := guard_bind hc
        cases h1 : check Γ M (rest.fv.filter (· ≠ r) ++ L) (k.operand x) with
        | none => rw [h1] at hc; exact absurd hc (by simp)
        | some p1 =>
          obtain ⟨τ0, M1⟩ := p1
          rw [h1] at hc
          have h0 := operand_check hx he hk h1
          subst h0
          simp only [Option.bind_some, erase_ty he] at hc
          simp only [Option.bind_eq_bind, Option.bind_some]
          exact obind_src hc fun _ h2 => ih hf h2

/-- **A program with API objects runs without a fault.** If `checkE`
accepts a program, and each call's implementation meets clauses within
its API's, the program runs to the end with no use after move or free,
no view after its loan ended, nothing stuck, and no leak: an object
carries its value's loans, so the checker holds them as it held the
value's (`accepts_runs`). -/
theorem erased_runs (p : EProg) (h : acceptsE p = true) (hf : p.Fits) :
    ∃ out, run p.elab = .ok out := by
  obtain ⟨r, hc⟩ := Option.isSome_iff_exists.1 h
  exact accepts_runs p.elab (by simp [accepts, checkE_elab p hf hc])

-- The proofs assume nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.erased_runs' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms erased_runs

/-- info: 'LambdaRig.erase_live' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms erase_live

/-- info: 'LambdaRig.allows_erase' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms allows_erase

/-- info: 'LambdaRig.checkE_lift' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms checkE_lift

/-! ### Examples -/

namespace Erase

/-- `area(s: ?{Shape}) -> ?Int from s`, a method of an API. -/
def area : Clauses := { src := [0], keeps := [] }

/-- An implementation that reads `s` and returns it. -/
def areaImpl : Impl := { clauses := area, reads := [0], ret := 0 }

/-- `v = 3`, `rv = ?v`, `s: ?{Shape} = rv`, `a = area(s)`, then `tail`. -/
def shape (tail : EProg) : EProg :=
  .bind "v" (.lit 3) <| .bind "rv" (.lend .read "v") <| .erase "s" (.view .read) "rv" tail

/-- `print(area(s))`, then `v = 4`: the loans of `s` end at its last use. -/
def areaOf : EProg :=
  shape <| .call "a" area areaImpl ["s"] <|
  .expr (.seq (.out (.name "a")) (.assign "v" (.lit 4)))

#guard acceptsE areaOf

example : areaOf.Fits := by
  simp [areaOf, shape, EProg.Fits, Impl.Meets, Impl.leaves, Leaves.Meets, Clauses.Within,
    areaImpl, area]

/-- info: LambdaRig.Outcome.ok [3, 3] -/
#guard_msgs in #eval run areaOf.elab

/-- `v = 4` while `s` is used later: the object carries the read loan on
`v`, so the checker rejects the write (CORE §4's second example). -/
def writeWhileErased : EProg :=
  shape <| .bind "u" (.assign "v" (.lit 4)) <| .call "a" area areaImpl ["s"] <|
  .expr (.out (.name "a"))

#guard !acceptsE writeWhileErased

-- Run all the same, it stops at the fault the rejection prevents.
/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.deadTag 1) -/
#guard_msgs in #eval run writeWhileErased.elab

-- `print(s)`: only a method reaches an object's value.
#guard !acceptsE (shape (.expr (.out (.name "s"))))

/-- `b = ^2`, `o: ^{Shape} = <b`: the object keeps the box, and drops it
once, at the end of its scope; `b` has moved. -/
def boxed : EProg := .bind "b" (.box (.lit 2)) <| .erase "o" .box "b" <| .expr (.lit 0)

#guard acceptsE boxed
#guard !acceptsE (.bind "b" (.box (.lit 2)) <| .erase "o" .box "b" <| .expr (.drop "b"))

/-- info: LambdaRig.Outcome.ok [] -/
#guard_msgs in #eval run boxed.elab

end Erase

end LambdaRig
