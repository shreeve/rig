/-
λRig: a call checked against an API's clauses.

A call through a bound (`x.area()` on a `[T: Shape]`) is checked
against the API's declaration, and an implementation's `from` and
`keeps` may be narrower than the API's, compared by position, never
wider (SPEC, "APIs"). This file proves such a call sound for any
implementation within the clauses it was checked against, in two parts.

- **Loans** (`within_live`): over the machine's cells, an implementation
  within the API's clauses creates only loans the caller records, so
  every access the caller's record allows keeps each view it left
  behind live. This part has both clauses and any number of positions.
- **Programs** (`api_calls_run`): `Prog` adds calls to λRig, each
  checked by `checkCall` against its API's clauses alone. A program
  `checkP` accepts runs without a fault for any implementations within
  the clauses, by `accepts_runs`: running a call in place gives a
  program `check` accepts, with the type `checkCall` gave. Here a
  method's parameters and result are read views, so only `from` is in
  play: λRig stores no view anywhere a caller reaches, which `keeps`
  is about, and a view's type names one owner.
-/
import LambdaRig.Sound

namespace LambdaRig

/-! ## Clauses -/

/-- A method's clauses, as parameter positions (`0` is the first
parameter): `src` is `from`, the parameters its result may view, and
`keeps` the parameters whose views it may store where its caller
reaches. -/
structure Clauses where
  src : List Nat
  keeps : List Nat
  deriving DecidableEq, Repr

/-- `c` is within `d`: the same or narrower, by position, never wider. -/
def Clauses.Within (c d : Clauses) : Prop :=
  (∀ i ∈ c.src, i ∈ d.src) ∧ (∀ i ∈ c.keeps, i ∈ d.keeps)

theorem Clauses.Within.refl (c : Clauses) : c.Within c := ⟨fun _ h => h, fun _ h => h⟩

theorem Clauses.Within.trans {c d e : Clauses} (h1 : c.Within d) (h2 : d.Within e) : c.Within e :=
  ⟨fun i h => h2.1 i (h1.1 i h), fun i h => h2.2 i (h1.2 i h)⟩

/-- What an implementation leaves behind when it returns: the positions
of the arguments whose views its result holds, and of those whose views
it stored where its caller reaches. -/
structure Leaves where
  result : List Nat
  stored : List Nat

/-- The compiler's check of a body against its own clauses: its result
views only parameters its `from` names, and it stores only parameters
its `keeps` names. -/
def Leaves.Meets (lv : Leaves) (c : Clauses) : Prop :=
  (∀ i ∈ lv.result, i ∈ c.src) ∧ (∀ i ∈ lv.stored, i ∈ c.keeps)

/-- An implementation that meets its clauses, within the API's, meets
the API's. -/
theorem Leaves.Meets.within {lv : Leaves} {c d : Clauses} (hm : lv.Meets c) (hw : c.Within d) :
    lv.Meets d :=
  ⟨fun i h => hw.1 i (hm.1 i h), fun i h => hw.2 i (hm.2 i h)⟩

/-! ## Loans -/

/-- A loan lent to a call, by its view: the view's mode, the owner's
place it sees, and the loan's tag. -/
structure Loan where
  m : Mode
  l : Loc
  t : Tag

/-- The loans of the arguments at positions `ps`. -/
def Loan.at (args : List Loan) (ps : List Nat) : List Loan := ps.filterMap (args[·]?)

theorem Loan.at_mono {args : List Loan} {ps qs : List Nat} (h : ∀ i ∈ ps, i ∈ qs) :
    ∀ a ∈ Loan.at args ps, a ∈ Loan.at args qs := by
  intro a ha
  simp only [Loan.at, List.mem_filterMap] at ha ⊢
  obtain ⟨i, hi, he⟩ := ha
  exact ⟨i, h i hi, he⟩

theorem Loan.mem_at {args : List Loan} {ps : List Nat} {a : Loan} (h : a ∈ Loan.at args ps) :
    a ∈ args := by
  simp only [Loan.at, List.mem_filterMap] at h
  obtain ⟨i, -, he⟩ := h
  exact List.mem_of_getElem? he

/-- **Subsumption, for loans.** A call checked against the API's
clauses records the loans of the arguments its `from` names, kept while
the result lives, and of those its `keeps` names, kept while what the
call may store into lives. An implementation within those clauses
creates no loan outside them. -/
theorem records_created {api c : Clauses} {lv : Leaves} (hm : lv.Meets c) (hw : c.Within api)
    (args : List Loan) :
    (∀ a ∈ Loan.at args lv.result, a ∈ Loan.at args api.src) ∧
    (∀ a ∈ Loan.at args lv.stored, a ∈ Loan.at args api.keeps) :=
  have h := hm.within hw
  ⟨Loan.at_mono h.1, Loan.at_mono h.2⟩

/-- The machine's ways to touch a cell (LambdaRig/Machine.lean), by the
access each is: the owner reads or lends to read; the owner writes,
moves, drops, or lends to write; a write view writes through. -/
inductive Touch : Access → Cell → Cell → Prop
  | read (c : Cell) : Touch .read c c.ownerRead
  | lendRead (c : Cell) (t : Tag) : Touch .read c (c.lendRead t)
  | write (c : Cell) (v : Option Val) : Touch .write c (c.ownerWrite v)
  | lendWrite (c : Cell) (t : Tag) : Touch .write c (c.lendWrite t)
  | through (c : Cell) (v : Val) : Touch .through c (c.viewWrite v)

/-- A touch keeps every loan its access does not end. -/
theorem Touch.keeps {k : Access} {c c' : Cell} (h : Touch k c c') {m : Mode} {t : Tag}
    (hk : k.ends m = false) (hl : c.live m t = true) : c'.live m t = true := by
  cases h <;> cases m <;>
    simp_all [Access.ends, Cell.live, Cell.ownerRead, Cell.lendRead, Cell.viewWrite]

/-- An access to the place at `l` is allowed by a record of loans when
it ends none of them: `allows`, over the loans of a call. -/
def Allowed (rec : List Loan) (k : Access) (l : Loc) : Prop :=
  ∀ a ∈ rec, a.l = l → k.ends a.m = false

/-- What the caller may do while the record `rec` holds: touch places
by accesses it allows, and free places it records no loan on. -/
inductive After (rec : List Loan) : (Loc → Option Cell) → (Loc → Option Cell) → Prop
  | done (h : Loc → Option Cell) : After rec h h
  | touch {h h' : Loc → Option Cell} {l : Loc} {c c' : Cell} {k : Access} :
      h l = some c → Touch k c c' → Allowed rec k l → After rec (upd h l (some c')) h' →
      After rec h h'
  | free {h h' : Loc → Option Cell} {l : Loc} :
      Allowed rec .write l → After rec (upd h l none) h' → After rec h h'

/-- A loan is live: its owner's place is allocated and carries its tag. -/
def Loan.Live (h : Loc → Option Cell) (a : Loan) : Prop :=
  ∃ c, h a.l = some c ∧ c.live a.m a.t = true

/-- What the caller does while a record holds keeps every recorded loan live. -/
theorem After.live {rec : List Loan} {h h' : Loc → Option Cell} (hr : After rec h h') {a : Loan}
    (ha : a ∈ rec) (hl : a.Live h) : a.Live h' := by
  induction hr with
  | done => exact hl
  | @touch h h' l c c' k hc ht hal _ ih =>
    apply ih
    obtain ⟨c0, hc0, hlv⟩ := hl
    by_cases he : a.l = l
    · rw [he, hc] at hc0
      cases hc0
      exact ⟨c', by simp [he], ht.keeps (hal a ha he) hlv⟩
    · exact ⟨c0, by simp [upd_other _ _ he, hc0], hlv⟩
  | @free h h' l hal _ ih =>
    apply ih
    obtain ⟨c0, hc0, hlv⟩ := hl
    by_cases he : a.l = l
    · have := hal a ha he
      cases a.m <;> simp [Access.ends] at this
    · exact ⟨c0, by simp [upd_other _ _ he, hc0], hlv⟩

/-- **A call checked against wider clauses keeps every loan its
implementation creates.** The caller lent the call the live loans
`args` and checked it against the API's clauses `api`; the
implementation it runs meets clauses `c` within them and leaves `lv`
behind. Whatever the caller then does that the API's `from` allows,
every view the result holds is still live, and whatever it does that
the API's `keeps` allows, every view the call stored is. -/
theorem within_live {api c : Clauses} {lv : Leaves} (hm : lv.Meets c) (hw : c.Within api)
    {args : List Loan} {h : Loc → Option Cell} (hl : ∀ a ∈ args, a.Live h) :
    (∀ h', After (Loan.at args api.src) h h' → ∀ a ∈ Loan.at args lv.result, a.Live h') ∧
    (∀ h', After (Loan.at args api.keeps) h h' → ∀ a ∈ Loan.at args lv.stored, a.Live h') := by
  obtain ⟨hr, hs⟩ := records_created hm hw args
  exact ⟨fun _ hh a ha => hh.live (hr a ha) (hl a (Loan.mem_at ha)),
    fun _ hh a ha => hh.live (hs a ha) (hl a (Loan.mem_at ha))⟩

/-- The clauses are needed: a result that views an argument the API's
`from` does not name dies at a write the API allows. -/
theorem outside_dies :
    let args : List Loan := [⟨.read, 0, 0⟩, ⟨.read, 1, 1⟩]
    let h : Loc → Option Cell := fun l => some { val := some (.int 0), reads := [l], write := none }
    (∀ a ∈ args, a.Live h) ∧
    ∃ h', After (Loan.at args [0]) h h' ∧ ∃ a ∈ Loan.at args [1], ¬ a.Live h' := by
  refine ⟨by simp [Loan.Live, Cell.live], _, .touch (l := 1) rfl (.write _ none) ?_ (.done _),
    ⟨.read, 1, 1⟩, by simp [Loan.at], ?_⟩
  · simp [Allowed, Loan.at]
  · simp [Loan.Live, Cell.live, Cell.ownerWrite]

/-! ## Calls in λRig programs -/

/-- A read view. -/
def Ty.readView : Ty → Bool
  | .view .read _ => true
  | _ => false

/-- An implementation of a method whose parameters are read views: it
reads the parameters at `reads`, in order, and returns the one at `ret`. -/
structure Impl where
  clauses : Clauses
  reads : List Nat
  ret : Nat
  deriving Repr

/-- What it leaves behind: its result views the argument at `ret`. -/
def Impl.leaves (f : Impl) : Leaves := { result := [f.ret], stored := [] }

/-- The compiler's check of its body against its own clauses. -/
def Impl.Meets (f : Impl) : Prop := f.leaves.Meets f.clauses

/-- The body, given the arguments in its parameters' places. -/
def Impl.body (f : Impl) (args : List Var) : Expr :=
  f.reads.foldr (fun k b => match args[k]? with
    | some x => .seq (.out (.name x)) b
    | none => b) <|
  match args[f.ret]? with
  | some x => .name x
  | none => .lit 0

/-- Read each argument, as it is passed. -/
def passArgs (args : List Var) (b : Expr) : Expr := args.foldr (fun x b => .seq (.name x) b) b

/-- The call `f(args)`, run in place: each argument is read as it is
passed, then the body runs with the arguments in its parameters' places.
A read view is a value that copies, so this is what binding each
parameter to its argument does. -/
def Impl.inline (f : Impl) (args : List Var) : Expr := passArgs args (f.body args)

/-- The owner the argument at position `i` views, when it is a read view. -/
def argOwner (Γ : Ctx) (args : List Var) (i : Nat) : Option Var :=
  match args[i]? with
  | some x =>
    match Γ.lookup x with
    | some (.view .read y) => some y
    | _ => none
  | none => none

/-- A call `f(args)` checked against the API's clauses alone, never the
implementation: every argument is a read view that has not moved, and
the result views what the arguments its `from` names view. A view's
type names one owner, so those arguments view one. -/
def checkCall (Γ : Ctx) (moved : List Var) (api : Clauses) (args : List Var) : Option Ty := do
  guard (args.all fun x => !moved.contains x && (Γ.lookup x).any Ty.readView)
  let y ← match api.src with
    | i :: _ => argOwner Γ args i
    | [] => none
  guard (api.src.all fun i => argOwner Γ args i == some y)
  some (.view .read y)

/-- A program whose calls go through APIs. -/
inductive Prog where
  /-- An ordinary λRig program. -/
  | expr (e : Expr)
  /-- `x = e` followed by `rest`, the scope of `x`. -/
  | bind (x : Var) (e : Expr) (rest : Prog)
  /-- `r = f(args)` followed by `rest`, the scope of `r`: a call through
  an API whose method has the clauses `api`. `impl` is the
  implementation the call runs, which `checkP` never reads. -/
  | call (r : Var) (api : Clauses) (impl : Impl) (args : List Var) (rest : Prog)

/-- The λRig program that runs: each call in place. -/
def Prog.elab : Prog → Expr
  | .expr e => e
  | .bind x e rest => .letIn x e rest.elab
  | .call r _ f args rest => .letIn r (f.inline args) rest.elab

/-- The names a program uses; a call uses its arguments. -/
def Prog.fv : Prog → List Var
  | .expr e => LambdaRig.fv e
  | .bind x e rest => LambdaRig.fv e ++ rest.fv.filter (· ≠ x)
  | .call r _ _ args rest => args ++ rest.fv.filter (· ≠ r)

/-- `check`, with each call checked by `checkCall` against its API's
clauses. -/
def checkP (Γ : Ctx) (moved later : List Var) : Prog → Option (Ty × List Var)
  | .expr e => check Γ moved later e
  | .bind x e rest => do
    guard ((Γ.lookup x).isNone && !moved.contains x)
    let (τe, moved) ← check Γ moved (rest.fv.filter (· ≠ x) ++ later) e
    let (τ, moved) ← checkP ((x, τe) :: Γ) moved later rest
    guard (!τ.lentFrom x)
    some (τ, moved.filter (· ≠ x))
  | .call r api _ args rest => do
    guard ((Γ.lookup r).isNone && !moved.contains r)
    let τc ← checkCall Γ moved api args
    let (τ, moved) ← checkP ((r, τc) :: Γ) moved later rest
    guard (!τ.lentFrom r)
    some (τ, moved.filter (· ≠ r))

/-- `rig check` for a program with calls. -/
def acceptsP (p : Prog) : Bool := (checkP [] [] [] p).isSome

/-- Every call's implementation meets its own clauses, within its API's. -/
def Prog.Fits : Prog → Prop
  | .expr _ => True
  | .bind _ _ rest => rest.Fits
  | .call _ api f _ rest => f.Meets ∧ f.clauses.Within api ∧ rest.Fits

/-- A program with no calls. -/
def Prog.NoCalls : Prog → Prop
  | .expr _ => True
  | .bind _ _ rest => rest.NoCalls
  | .call .. => False

/-! ### `check` reads `later` as a set -/

theorem allows_later {Γ : Ctx} {y : Var} {k : Access} {L L' : List Var}
    (h : ∀ v, v ∈ L ↔ v ∈ L') : allows Γ y k L = allows Γ y k L' := by
  unfold allows
  congr 1
  funext p
  obtain ⟨v, τ⟩ := p
  cases τ <;> simp [h]

theorem check_later (e : Expr) : ∀ {Γ M L L'}, (∀ v, v ∈ L ↔ v ∈ L') →
    check Γ M L e = check Γ M L' e := by
  induction e with
  | lit => intros; rfl
  | name x | move x | drop x | clone x | lend _ x =>
    intro Γ M L L' h; simp only [check, allows_later h]
  | box e ih | out e ih => intro Γ M L L' h; simp only [check, ih h]
  | assign x e ih =>
    intro Γ M L L' h
    simp only [check, ih (L := x :: L) (L' := x :: L') (by simp [h]), allows_later h]
  | add a b iha ihb | seq a b iha ihb =>
    intro Γ M L L' h
    simp only [check, iha (L := fv b ++ L) (L' := fv b ++ L') (by simp [h]), ihb h]
  | letIn x e body ihe ihb =>
    intro Γ M L L' h
    simp only [check, ihe (L := (fv body).filter (· ≠ x) ++ L)
      (L' := (fv body).filter (· ≠ x) ++ L') (by simp [h]), ihb h]

theorem fv_passArgs (args : List Var) (b : Expr) : fv (passArgs args b) = args ++ fv b := by
  induction args with
  | nil => rfl
  | cons x xs ih => simp [passArgs, fv] at ih ⊢; exact ih

theorem fv_body (f : Impl) (args : List Var) : ∀ v ∈ fv (f.body args), v ∈ args := by
  unfold Impl.body
  induction f.reads with
  | nil =>
    simp only [List.foldr]
    cases h : args[f.ret]? with
    | none => simp [fv]
    | some x => simp [fv]; exact List.mem_of_getElem? h
  | cons k ks ih =>
    simp only [List.foldr]
    cases h : args[k]? with
    | none => exact ih
    | some x =>
      intro v hv
      simp only [fv, List.mem_append, List.mem_singleton] at hv
      rcases hv with rfl | hv
      · exact List.mem_of_getElem? h
      · exact ih v hv

theorem fv_inline (f : Impl) (args : List Var) (v : Var) : v ∈ fv (f.inline args) ↔ v ∈ args := by
  simp only [Impl.inline, fv_passArgs, List.mem_append]
  exact ⟨fun h => h.elim id (fv_body f args v), Or.inl⟩

theorem fv_elab (p : Prog) (v : Var) : v ∈ fv p.elab ↔ v ∈ p.fv := by
  induction p generalizing v with
  | expr e => rfl
  | bind x e rest ih => simp [Prog.elab, Prog.fv, fv, ih]
  | call r api f args rest ih => simp [Prog.elab, Prog.fv, fv, ih, fv_inline]

/-! ### The conservative extension -/

/-- On a program with no calls, `checkP` is `check` of the same program,
and so it accepts exactly what `check` does. -/
theorem checkP_noCalls (p : Prog) (hp : p.NoCalls) :
    ∀ {Γ M L}, checkP Γ M L p = check Γ M L p.elab := by
  induction p with
  | expr e => intros; rfl
  | bind x e rest ih =>
    intro Γ M L
    have hl := check_later (Γ := Γ) (M := M) e (L := (fv rest.elab).filter (· ≠ x) ++ L)
      (L' := rest.fv.filter (· ≠ x) ++ L) (by simp [fv_elab])
    simp only [checkP, Prog.elab, check, ih hp, hl]
  | call => exact hp.elim

theorem acceptsP_expr (e : Expr) : acceptsP (.expr e) = accepts e := rfl

/-! ### A call, run in place, checks with the type its API gives -/

theorem check_name_read {Γ : Ctx} {M L : List Var} {x y : Var} (hm : x ∉ M)
    (hx : Γ.lookup x = some (.view .read y)) : check Γ M L (.name x) = some (.view .read y, M) := by
  simp [check, hx, hm]

theorem check_out_name {Γ : Ctx} {M L : List Var} {x y : Var} (hm : x ∉ M)
    (hx : Γ.lookup x = some (.view .read y)) : check Γ M L (.out (.name x)) = some (.unit, M) := by
  simp [check, hx, hm, guard]

theorem check_seq_eq (Γ : Ctx) (M L : List Var) (a b : Expr) :
    check Γ M L (.seq a b) = (do let (_, moved) ← check Γ M (fv b ++ L) a; check Γ moved L b) := by
  simp only [check]

theorem readView_spec {o : Option Ty} (h : o.any Ty.readView = true) :
    ∃ y, o = some (.view .read y) := by
  cases o with
  | none => simp at h
  | some τ =>
    cases τ with
    | view m y => cases m <;> simp_all [Ty.readView]
    | _ => simp [Ty.readView] at h

theorem checkCall_spec {Γ : Ctx} {M : List Var} {api : Clauses} {args : List Var} {τ : Ty}
    (h : checkCall Γ M api args = some τ) :
    (∀ x ∈ args, x ∉ M ∧ ∃ y, Γ.lookup x = some (.view .read y)) ∧
    ∃ y, τ = .view .read y ∧ ∀ i ∈ api.src, argOwner Γ args i = some y := by
  simp only [checkCall] at h
  cases hs : api.src with
  | nil => simp [hs] at h
  | cons i is =>
    simp only [hs] at h
    cases ho : argOwner Γ args i with
    | none => simp [ho] at h
    | some y =>
      simp [ho] at h
      obtain ⟨ha, hall, rfl⟩ := h
      refine ⟨fun x hx => ⟨(ha x hx).1, readView_spec (ha x hx).2⟩, y, rfl, ?_⟩
      intro j hj
      simp only [List.mem_cons] at hj
      rcases hj with rfl | hj
      · exact ho
      · exact hall j hj

theorem check_passArgs {Γ : Ctx} {M : List Var} {τ : Ty} {b : Expr}
    (hb : ∀ L, check Γ M L b = some (τ, M)) :
    ∀ (xs : List Var), (∀ x ∈ xs, x ∉ M ∧ ∃ y, Γ.lookup x = some (.view .read y)) →
      ∀ L, check Γ M L (passArgs xs b) = some (τ, M) := by
  intro xs
  induction xs with
  | nil => intro _ L; exact hb L
  | cons x xs ih =>
    intro hx L
    obtain ⟨hm, y, hy⟩ := hx x (by simp)
    have := ih (fun z hz => hx z (by simp [hz]))
    simp only [passArgs, List.foldr] at this ⊢
    simp [check_seq_eq, check_name_read hm hy, this]

theorem check_body {Γ : Ctx} {M : List Var} {args : List Var} {y : Var} (f : Impl)
    (ha : ∀ x ∈ args, x ∉ M ∧ ∃ y, Γ.lookup x = some (.view .read y))
    (hr : argOwner Γ args f.ret = some y) :
    ∀ L, check Γ M L (f.body args) = some (.view .read y, M) := by
  unfold Impl.body
  induction f.reads with
  | nil =>
    intro L
    simp only [List.foldr]
    unfold argOwner at hr
    cases h : args[f.ret]? with
    | none => simp [h] at hr
    | some x =>
      simp only [h] at hr ⊢
      cases hx : Γ.lookup x with
      | none => simp [hx] at hr
      | some τx =>
        obtain ⟨hm, -⟩ := ha x (List.mem_of_getElem? h)
        cases τx with
        | view m y' => cases m <;> simp_all [check]
        | _ => simp [hx] at hr
  | cons k ks ih =>
    intro L
    simp only [List.foldr]
    cases h : args[k]? with
    | none => exact ih L
    | some x =>
      obtain ⟨hm, y', hy'⟩ := ha x (List.mem_of_getElem? h)
      simp [check_seq_eq, check_out_name hm hy', ih]

/-- **A call run in place checks with the type its API gave.** If
`checkCall` accepts `f(args)` against the API's clauses, giving `τ`, then
for an implementation that meets its own clauses, within the API's,
`check` accepts the call run in place, with type `τ`, moving nothing. -/
theorem inline_check {Γ : Ctx} {M L : List Var} {api : Clauses} {args : List Var} {τ : Ty}
    (f : Impl) (hm : f.Meets) (hw : f.clauses.Within api) (hc : checkCall Γ M api args = some τ) :
    check Γ M L (f.inline args) = some (τ, M) := by
  obtain ⟨ha, y, rfl, hy⟩ := checkCall_spec hc
  have hret : f.ret ∈ api.src := (hm.within hw).1 f.ret (by simp [Impl.leaves])
  exact check_passArgs (check_body f ha (hy f.ret hret)) args ha L

/-- **What the call returns fits the type its API gave.** Run in any
machine that matches the caller's scope, the implementation's body
returns a view of the owner `checkCall` named, with its loan live, and
the machine still matches the scope. -/
theorem call_fits {Γ : Ctx} {M L : List Var} {api : Clauses} {args : List Var} {τ : Ty}
    (f : Impl) (hm : f.Meets) (hw : f.clauses.Within api) (hc : checkCall Γ M api args = some τ)
    {σ β : Var → Loc} {s : Machine} (r : Rel Γ M (fv (f.inline args) ++ L) σ β s []) :
    ∃ v s' β', (eval (f.inline args)).run s = .ok (v, s') ∧ Rel Γ M L σ β' s' (owned v) ∧
      VFits Γ M σ β' s' τ v :=
  sound _ Γ M L τ M σ β s (inline_check f hm hw hc) r

theorem obind_congr {o : Option α} {f g : α → Option β} {r : β} (h : (o >>= f) = some r)
    (hfg : ∀ a, f a = some r → g a = some r) : (o >>= g) = some r := by
  cases o with
  | none => exact absurd h (by simp)
  | some a => exact hfg a h

theorem obind_src {o o' : Option α} {f : α → Option β} {r : β} (h : (o >>= f) = some r)
    (ho : ∀ a, o = some a → o' = some a) : (o' >>= f) = some r := by
  cases o with
  | none => exact absurd h (by simp)
  | some a => rw [ho a rfl]; exact h

/-- A program `checkP` accepts, whose calls run implementations within
their APIs' clauses, runs as one `check` accepts with the same type. -/
theorem checkP_elab (p : Prog) (hf : p.Fits) :
    ∀ {Γ M L r}, checkP Γ M L p = some r → check Γ M L p.elab = some r := by
  induction p with
  | expr e => intro _ _ _ _ h; exact h
  | bind x e rest ih =>
    intro Γ M L r hc
    have hl := check_later (Γ := Γ) (M := M) e (L := (fv rest.elab).filter (· ≠ x) ++ L)
      (L' := rest.fv.filter (· ≠ x) ++ L) (by simp [fv_elab])
    simp only [checkP] at hc
    simp only [Prog.elab, check, hl]
    refine obind_congr hc fun _ hc => ?_
    refine obind_congr hc fun _ hc => ?_
    exact obind_src hc fun _ h2 => ih hf h2
  | call r api f args rest ih =>
    intro Γ M L r' hc
    obtain ⟨hm, hw, hf⟩ := hf
    simp only [checkP] at hc
    simp only [Prog.elab, check]
    refine obind_congr hc fun _ hc => ?_
    cases h1 : checkCall Γ M api args with
    | none => rw [h1] at hc; exact absurd hc (by simp)
    | some τc =>
      rw [h1] at hc
      rw [inline_check f hm hw h1]
      show (check ((r, τc) :: Γ) M L rest.elab >>= _) = some r'
      exact obind_src (o := checkP ((r, τc) :: Γ) M L rest) hc fun _ h2 => ih hf h2

/-- **A program whose calls are checked against their APIs' clauses
runs without a fault, for any implementations within them.** `checkP`
reads each call's API, never its implementation; if it accepts the
program, and each implementation meets clauses within its API's, the
program runs to the end with no use after move or free, no view after
its loan ended, nothing stuck, and no leak (`accepts_runs`). -/
theorem api_calls_run (p : Prog) (h : acceptsP p = true) (hf : p.Fits) :
    ∃ out, run p.elab = .ok out := by
  obtain ⟨r, hc⟩ := Option.isSome_iff_exists.1 h
  exact accepts_runs p.elab (by simp [accepts, checkP_elab p hf hc])

-- The proofs assume nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.api_calls_run' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms api_calls_run

/-- info: 'LambdaRig.within_live' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms within_live

/-! ### Examples -/

namespace Calls

/-- `pick(a: ?Int, b: ?Int) -> ?Int from a`, a method of an API. -/
def pick : Clauses := { src := [0], keeps := [] }

/-- An implementation that reads `b` and returns `a`, `from a`. -/
def pickA : Impl := { clauses := { src := [0], keeps := [] }, reads := [1], ret := 0 }

/-- An implementation outside the API's clauses: it returns `b`, `from b`. -/
def pickB : Impl := { clauses := { src := [1], keeps := [] }, reads := [], ret := 1 }

/-- `a = 1`, `b = 2`, `ra = ?a`, `rb = ?b`, `r = pick(ra, rb)`, `b = 5`,
`print(r)`: the loan on `b` ends as the call returns, so `b` may be
written while `r` lives. -/
def writeAfterCall (f : Impl) : Prog :=
  .bind "a" (.lit 1) <| .bind "b" (.lit 2) <|
  .bind "ra" (.lend .read "a") <| .bind "rb" (.lend .read "b") <|
  .call "r" pick f ["ra", "rb"] <|
  .expr (.seq (.assign "b" (.lit 5)) (.out (.name "r")))

#guard acceptsP (writeAfterCall pickA)
#guard acceptsP (writeAfterCall pickB)

example : (writeAfterCall pickA).Fits := by
  simp [writeAfterCall, Prog.Fits, Impl.Meets, Impl.leaves, Leaves.Meets, Clauses.Within, pickA, pick]

example : ¬ pickB.clauses.Within pick := by simp [Clauses.Within, pickB, pick]

/-- info: LambdaRig.Outcome.ok [2, 1] -/
#guard_msgs in #eval run (writeAfterCall pickA).elab

-- An implementation outside the clauses ends in the fault they prevent.
/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.deadTag 4) -/
#guard_msgs in #eval run (writeAfterCall pickB).elab

/-- `pick2(a: ?Int, b: ?Int) -> ?Int from a, b`, with an implementation
narrower than it, `from b`: `a = 1`, `ra = ?a`, `rb = ?a`,
`r = pick2(ra, rb)`, `print(r)`. -/
def pick2 : Clauses := { src := [0, 1], keeps := [] }

def narrower : Prog :=
  .bind "a" (.lit 1) <|
  .bind "ra" (.lend .read "a") <| .bind "rb" (.lend .read "a") <|
  .call "r" pick2 pickB ["ra", "rb"] <|
  .expr (.out (.name "r"))

#guard acceptsP narrower

example : narrower.Fits := by
  simp [narrower, Prog.Fits, Impl.Meets, Impl.leaves, Leaves.Meets, Clauses.Within, pickB, pick2]

/-- info: LambdaRig.Outcome.ok [1] -/
#guard_msgs in #eval run narrower.elab

end Calls

end LambdaRig
