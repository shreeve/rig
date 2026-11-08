/-
λRig: a statement's temporary, lent to a call.

CORE §3, "What counts as a temporary": "A value made where it is only
read has no name: a call's result, a constructor, `+x`, or a block or
`match` value. Its statement is its scope, so it is a *temporary*,
dropped when the statement ends ... A temporary may be lent to read or
to write (sentence 4), and a view of it may be used only within its
statement." A backtick template where a `?String` is expected is such a
temporary (docs/history/records/2026-11/templates-t1.md, "The place
decides").

`TProg` adds to the programs of Calls.lean a call whose first argument
is a temporary, `r = f(?e, args)` and `print(f(?e, args))`. `elab` runs
it as CORE says: the value `e` makes is held in a hidden place `h`, whose
scope is the statement and no more, and lent to read as the hidden view
`hv`; the place drops where the statement ends, before the rest of the
program. `checkT` reads the API's clauses, never the implementation, and
rejects a binding whose result views the temporary, since that view
would be used after its statement (`temp_from_rejected`: an API `from`
the temporary's position is rejected; its run ends at `freed`). A result
used within its statement may view it (`print(f(?e))`). If `checkT`
accepts a program, and every implementation meets clauses within its
API's, the program runs to the end without a fault (`temps_run`): every
view of a temporary dies by its statement's end, and the temporary is
dropped there, once.
-/
import LambdaRig.Mono

namespace LambdaRig

/-- A program whose calls may take a statement's temporary. -/
inductive TProg where
  /-- An ordinary λRig program. -/
  | expr (e : Expr)
  /-- `x = e` followed by `rest`, the scope of `x`. -/
  | bind (x : Var) (e : Expr) (rest : TProg)
  /-- `r = f(?e, args)` followed by `rest`, the scope of `r`: the value
  `e` makes is the statement's temporary, held in the hidden place `h`
  and lent to the call's first parameter as the hidden view `hv`. -/
  | callTemp (r : Var) (api : Clauses) (impl : Impl) (h hv : Var) (e : Expr) (args : List Var)
      (rest : TProg)
  /-- `print(f(?e, args))` followed by `rest`: the call's result is used
  within its statement. -/
  | printTemp (api : Clauses) (impl : Impl) (h hv : Var) (e : Expr) (args : List Var) (rest : TProg)

/-- The temporary `e` makes, held in `h` and lent to read as `hv` for
`use`, the rest of its statement: its statement is its scope. -/
def tempIn (h hv : Var) (e use : Expr) : Expr := .letIn h e (.letIn hv (.lend .read h) use)

/-- The λRig program that runs: each call in place, each temporary in a
scope that ends with its statement. -/
def TProg.elab : TProg → Expr
  | .expr e => e
  | .bind x e rest => .letIn x e rest.elab
  | .callTemp r _ f h hv e args rest => .letIn r (tempIn h hv e (f.inline (hv :: args))) rest.elab
  | .printTemp _ f h hv e args rest => .seq (tempIn h hv e (.out (f.inline (hv :: args)))) rest.elab

/-- The names a program uses; a call uses its arguments and what its
temporary is made from. -/
def TProg.fv : TProg → List Var
  | .expr e => LambdaRig.fv e
  | .bind x e rest => LambdaRig.fv e ++ rest.fv.filter (· ≠ x)
  | .callTemp r _ _ _ _ e args rest => LambdaRig.fv e ++ args ++ rest.fv.filter (· ≠ r)
  | .printTemp _ _ _ _ e args rest => LambdaRig.fv e ++ args ++ rest.fv

/-- `h` and `hv` are hidden: no name in scope is either, no type in scope
mentions either, neither has moved, they differ, and no argument is
either. A temporary has no name. -/
def hidden (Γ : Ctx) (moved : List Var) (h hv : Var) (args : List Var) : Bool :=
  (Γ.lookup h).isNone && (Γ.lookup hv).isNone && h != hv &&
  !moved.contains h && !moved.contains hv &&
  Γ.all (fun p => !p.2.lentFrom h && !p.2.lentFrom hv) &&
  !args.contains h && !args.contains hv

/-- `rig check` for a program whose calls may take a temporary. A call
is checked against its API's clauses alone. -/
def checkT (Γ : Ctx) (moved later : List Var) : TProg → Option (Ty × List Var)
  | .expr e => check Γ moved later e
  | .bind x e rest => do
    guard ((Γ.lookup x).isNone && !moved.contains x)
    let (τe, moved) ← check Γ moved (rest.fv.filter (· ≠ x) ++ later) e
    let (τ, moved) ← checkT ((x, τe) :: Γ) moved later rest
    guard (!τ.lentFrom x)
    some (τ, moved.filter (· ≠ x))
  | .callTemp r api _ h hv e args rest => do
    guard ((Γ.lookup r).isNone && !moved.contains r)
    guard (hidden Γ moved h hv args)
    let (τe, moved) ← check Γ moved (args ++ rest.fv.filter (· ≠ r) ++ later) e
    guard τe.owner
    let τc ← checkCall ((hv, .view .read h) :: (h, τe) :: Γ) moved api (hv :: args)
    -- CORE §3: "a view of it may be used only within its statement".
    guard (!τc.lentFrom h)
    let (τ, moved) ← checkT ((r, τc) :: Γ) moved later rest
    guard (!τ.lentFrom r)
    some (τ, moved.filter (· ≠ r))
  | .printTemp api _ h hv e args rest => do
    guard (hidden Γ moved h hv args)
    let (τe, moved) ← check Γ moved (args ++ rest.fv ++ later) e
    guard τe.owner
    let _ ← checkCall ((hv, .view .read h) :: (h, τe) :: Γ) moved api (hv :: args)
    checkT Γ moved later rest

def acceptsT (p : TProg) : Bool := (checkT [] [] [] p).isSome

/-- Every call's implementation meets its own clauses, within its API's. -/
def TProg.Fits : TProg → Prop
  | .expr _ => True
  | .bind _ _ rest => rest.Fits
  | .callTemp _ api f _ _ _ _ rest => f.Meets ∧ f.clauses.Within api ∧ rest.Fits
  | .printTemp api f _ _ _ _ rest => f.Meets ∧ f.clauses.Within api ∧ rest.Fits

/-! ## The names used -/

theorem fv_tempIn {h hv : Var} {e use : Expr} {v : Var} (hm : v ∈ fv (tempIn h hv e use)) :
    v ∈ fv e ∨ (v ∈ fv use ∧ v ≠ hv) := by
  simp only [tempIn, fv, List.mem_append, List.mem_filter, List.mem_cons, List.not_mem_nil,
    or_false, decide_eq_true_eq, ne_eq] at hm
  rcases hm with hm | ⟨rfl | ⟨hm, hne⟩, hne'⟩
  · exact Or.inl hm
  · exact absurd rfl hne'
  · exact Or.inr ⟨hm, hne⟩

theorem fv_inline_temp {f : Impl} {hv : Var} {args : List Var} {v : Var}
    (hm : v ∈ fv (f.inline (hv :: args))) (hne : v ≠ hv) : v ∈ args := by
  rcases List.mem_cons.1 ((fv_inline f _ v).1 hm) with rfl | h'
  · exact absurd rfl hne
  · exact h'

/-- What the program that runs uses, the program says it uses. -/
theorem fv_telab (p : TProg) (v : Var) : v ∈ fv p.elab → v ∈ p.fv := by
  induction p generalizing v with
  | expr e => exact id
  | bind x e rest ih =>
    intro hm
    simp only [TProg.elab, TProg.fv, fv, List.mem_append, List.mem_filter] at hm ⊢
    exact hm.imp id fun ⟨h1, h2⟩ => ⟨ih v h1, h2⟩
  | callTemp r api f h hv e args rest ih =>
    intro hm
    simp only [TProg.elab, TProg.fv, fv, List.mem_append, List.mem_filter] at hm ⊢
    rcases hm with hm | ⟨h1, h2⟩
    · rcases fv_tempIn hm with hm | ⟨hm, hne⟩
      · exact Or.inl (Or.inl hm)
      · exact Or.inl (Or.inr (fv_inline_temp hm hne))
    · exact Or.inr ⟨ih v h1, h2⟩
  | printTemp api f h hv e args rest ih =>
    intro hm
    simp only [TProg.elab, TProg.fv, fv, List.mem_append] at hm ⊢
    rcases hm with hm | hm
    · rcases fv_tempIn hm with hm | ⟨hm, hne⟩
      · exact Or.inl (Or.inl hm)
      · exact Or.inl (Or.inr (fv_inline_temp (by simpa [fv] using hm) hne))
    · exact Or.inr (ih v hm)

/-! ## A temporary, lent for its statement -/

theorem guard_some {p : Prop} [Decidable p] {u : Unit} : (guard p : Option Unit) = some u ↔ p := by
  by_cases h : p <;> simp [guard, h, failure]

theorem hidden_spec {Γ : Ctx} {M : List Var} {h hv : Var} {args : List Var}
    (hid : hidden Γ M h hv args = true) :
    Γ.lookup h = none ∧ Γ.lookup hv = none ∧ h ≠ hv ∧ h ∉ M ∧ hv ∉ M ∧
    (∀ p ∈ Γ, p.2.lentFrom h = false ∧ p.2.lentFrom hv = false) ∧ h ∉ args ∧ hv ∉ args := by
  simp only [hidden, Bool.and_eq_true, Option.isNone_iff_eq_none, bne_iff_ne, ne_eq,
    List.all_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true] at hid
  obtain ⟨⟨⟨⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩, h6⟩, h7⟩, h8⟩ := hid
  refine ⟨h1, h2, h3, by simpa using h4, by simpa using h5, fun p hp => ?_, by simpa using h7,
    by simpa using h8⟩
  have := h6 p hp
  simpa [Bool.and_eq_true] using this

/-- Nothing in scope views the temporary, so lending it is allowed. -/
theorem allows_hidden {Γ : Ctx} {h : Var} {τe : Ty} (ho : τe.owner = true)
    (hn : ∀ p ∈ Γ, p.2.lentFrom h = false) (k : Access) (L : List Var) :
    allows ((h, τe) :: Γ) h k L = true := by
  unfold allows
  rw [List.all_cons, Bool.and_eq_true]
  constructor
  · rcases Ty.owner_cases ho with rfl | rfl <;> rfl
  · refine List.all_eq_true.2 fun p hp => ?_
    obtain ⟨z, τ⟩ := p
    have := hn (z, τ) hp
    cases τ with
    | view m y => simp [Ty.lentFrom] at this; simp [this]
    | _ => rfl

theorem filter_ne_self {M : List Var} {x : Var} (h : x ∉ M) : M.filter (· ≠ x) = M := by
  rw [List.filter_eq_self]
  intro a ha
  simp only [ne_eq, decide_eq_true_eq]
  rintro rfl
  exact h ha

/-- **A temporary lent for its statement.** The value `e` makes, held in
the hidden `h` and lent to read as `hv` for `use`, the rest of its
statement, checks as `use` does, provided what `use` gives views neither:
the temporary drops where the statement ends, and with it every view of
it. -/
theorem check_tempIn {Γ : Ctx} {M L : List Var} {h hv : Var} {args : List Var} {e use : Expr}
    {τe τu : Ty} {M1 : List Var} (hid : hidden Γ M h hv args = true)
    (he : check Γ M ((fv (.letIn hv (.lend .read h) use)).filter (· ≠ h) ++ L) e = some (τe, M1))
    (ho : τe.owner = true)
    (hu : ∀ L', check ((hv, .view .read h) :: (h, τe) :: Γ) M1 L' use = some (τu, M1))
    (hτv : τu.lentFrom hv = false) (hτh : τu.lentFrom h = false) :
    check Γ M L (tempIn h hv e use) = some (τu, M1) := by
  obtain ⟨hhΓ, hvΓ, hne, hhM, hvM, hn, -, -⟩ := hidden_spec hid
  have hh1 : h ∉ M1 := check_fresh e he hhM hhΓ
  have hv1 : hv ∉ M1 := check_fresh e he hvM hvΓ
  have hvh : hv ≠ h := fun h' => hne h'.symm
  have hal := allows_hidden ho (fun p hp => (hn p hp).1)
  simp only [tempIn, check]
  rw [he]
  simp [lookup_cons_other hvh, hvΓ, hv1, hh1, hhΓ, hhM, ho, hal, hu, hτv, hτh,
    guard]
  intro a ha
  exact ⟨fun e => hh1 (e ▸ ha), fun e => hv1 (e ▸ ha)⟩

/-- What a call whose first argument is the temporary gives views
neither hidden name but, when the API's `from` names that argument, the
temporary. -/
theorem checkCall_temp {Γ : Ctx} {M : List Var} {api : Clauses} {h hv : Var} {τe : Ty}
    {args : List Var} {τc : Ty} (hid : ∀ p ∈ Γ, p.2.lentFrom h = false ∧ p.2.lentFrom hv = false)
    (hne : h ≠ hv) (hh : h ∉ args) (hhv : hv ∉ args)
    (hc : checkCall ((hv, .view .read h) :: (h, τe) :: Γ) M api (hv :: args) = some τc) :
    τc.lentFrom hv = false ∧ (0 ∈ api.src → τc.lentFrom h = true) := by
  obtain ⟨-, y, rfl, hy⟩ := checkCall_spec hc
  have hsrc : ∃ i, i ∈ api.src := by
    simp only [checkCall] at hc
    cases hs : api.src with
    | nil => simp [hs] at hc
    | cons i _ => exact ⟨i, by simp⟩
  obtain ⟨i, hi⟩ := hsrc
  refine ⟨?_, fun h0 => ?_⟩
  · have hyi := hy i hi
    unfold argOwner at hyi
    cases i with
    | zero =>
      simp at hyi
      subst hyi
      simp [Ty.lentFrom, hne]
    | succ j =>
      simp only [List.getElem?_cons_succ] at hyi
      cases hx : args[j]? with
      | none => simp [hx] at hyi
      | some x =>
        have hxm : x ∈ args := List.mem_of_getElem? hx
        have hxv : x ≠ hv := fun h' => hhv (h' ▸ hxm)
        have hxh : x ≠ h := fun h' => hh (h' ▸ hxm)
        simp only [hx, lookup_cons_other hxv, lookup_cons_other hxh] at hyi
        cases hl : Γ.lookup x with
        | none => simp [hl] at hyi
        | some τx =>
          have := (hid (x, τx) (mem_of_lookup hl)).2
          cases τx with
          | view m y' => cases m <;> simp_all [Ty.lentFrom]
          | _ => simp [hl] at hyi
  · have hy0 := hy 0 h0
    unfold argOwner at hy0
    simp at hy0
    subst hy0
    simp [Ty.lentFrom]

/-- A program `checkT` accepts, whose calls run implementations within
their APIs' clauses, runs as one `check` accepts with the same type. -/
theorem checkT_elab (p : TProg) (hf : p.Fits) :
    ∀ {Γ M L r}, checkT Γ M L p = some r → check Γ M L p.elab = some r := by
  induction p with
  | expr e => intro _ _ _ _ h; exact h
  | bind x e rest ih =>
    intro Γ M L r hc
    simp only [checkT] at hc
    simp only [TProg.elab, check]
    refine obind_congr hc fun _ hc => ?_
    refine obind_src (obind_congr hc fun p hp => ?_) fun p hp => check_mono e hp ?_
    · obtain ⟨τe, Me⟩ := p
      simp only at hp ⊢
      exact obind_src hp fun _ h2 => ih hf h2
    · intro v hv
      simp only [List.mem_append, List.mem_filter] at hv ⊢
      exact hv.imp (fun ⟨h1, h2⟩ => ⟨fv_telab rest v h1, h2⟩) id
  | callTemp r api f h hv e args rest ih =>
    intro Γ M L res hc
    obtain ⟨hm, hw, hf⟩ := hf
    simp only [checkT, Option.bind_eq_bind, Option.bind_eq_some_iff, guard_some, exists_const] at hc
    obtain ⟨hr, hid, ⟨τe, M1⟩, he, hc⟩ := hc
    simp only at hc
    obtain ⟨ho, τc, hcc, hlh, ⟨τ, M2⟩, hrest, hlr, hres⟩ := hc
    obtain ⟨hhΓ, hvΓ, hne, hhM, hvM, hn, hha, hva⟩ := hidden_spec hid
    have hct := checkCall_temp hn hne hha hva hcc
    have hlh' : τc.lentFrom h = false := by simpa using hlh
    have hue : ∀ L', check ((hv, .view .read h) :: (h, τe) :: Γ) M1 L' (f.inline (hv :: args)) =
        some (τc, M1) := fun L' => inline_check f hm hw hcc
    have he' := check_mono e he (L' := (fv (.letIn hv (.lend .read h) (f.inline (hv :: args)))).filter
      (· ≠ h) ++ ((fv rest.elab).filter (· ≠ r) ++ L)) (by
        intro v hv'
        simp only [List.mem_append, List.mem_filter] at hv' ⊢
        rcases hv' with ⟨hv', hvh⟩ | ⟨hv', hvr⟩ | hv'
        · left; left
          simp only [fv, List.mem_append, List.mem_filter, List.mem_cons, List.not_mem_nil,
            or_false, decide_eq_true_eq, ne_eq] at hv' hvh
          rcases hv' with rfl | ⟨hx, hne'⟩
          · exact absurd rfl hvh
          · exact fv_inline_temp hx hne'
        · exact Or.inl (Or.inr ⟨fv_telab rest v hv', hvr⟩)
        · exact Or.inr hv')
    have htmp := check_tempIn hid he' ho hue hct.1 hlh'
    simp only [TProg.elab, check]
    simp only [Option.bind_eq_bind, Option.bind_eq_some_iff, guard_some, exists_const]
    exact ⟨hr, ⟨τc, M1⟩, htmp, ⟨τ, M2⟩, ih hf hrest, hlr, hres⟩
  | printTemp api f h hv e args rest ih =>
    intro Γ M L res hc
    obtain ⟨hm, hw, hf⟩ := hf
    simp only [checkT, Option.bind_eq_bind, Option.bind_eq_some_iff, guard_some, exists_const] at hc
    obtain ⟨hid, ⟨τe, M1⟩, he, hc⟩ := hc
    simp only at hc
    obtain ⟨ho, τc, hcc, hrest⟩ := hc
    obtain ⟨-, y, rfl, -⟩ := checkCall_spec hcc
    have hue : ∀ L', check ((hv, .view .read h) :: (h, τe) :: Γ) M1 L' (.out (f.inline (hv :: args))) =
        some (.unit, M1) := fun L' => by
      simp [check, inline_check f hm hw hcc, guard]
    have he' := check_mono e he (L' := (fv (.letIn hv (.lend .read h) (.out (f.inline (hv :: args))))).filter
      (· ≠ h) ++ (fv rest.elab ++ L)) (by
        intro v hv'
        simp only [List.mem_append, List.mem_filter] at hv' ⊢
        rcases hv' with ⟨hv', hvh⟩ | hv' | hv'
        · left; left
          simp only [fv, List.mem_append, List.mem_filter, List.mem_cons, List.not_mem_nil,
            or_false, decide_eq_true_eq, ne_eq] at hv' hvh
          rcases hv' with rfl | ⟨hx, hne'⟩
          · exact absurd rfl hvh
          · exact fv_inline_temp hx hne'
        · exact Or.inl (Or.inr (fv_telab rest v hv'))
        · exact Or.inr hv')
    have htmp := check_tempIn hid he' ho hue rfl rfl
    simp only [TProg.elab]
    rw [check_seq_eq, htmp]
    exact ih hf hrest

/-- **A program whose calls take temporaries runs without a fault.** If
`checkT` accepts it, and every implementation meets clauses within its
API's, the program runs to the end with no use after move or free, no
view after its loan ended, nothing stuck, and no leak: each temporary is
dropped once, where its statement ends, and no view of it is used after
(`accepts_runs`). -/
theorem temps_run (p : TProg) (h : acceptsT p = true) (hf : p.Fits) :
    ∃ out, run p.elab = .ok out := by
  obtain ⟨r, hc⟩ := Option.isSome_iff_exists.1 h
  exact accepts_runs p.elab (by simp [accepts, checkT_elab p hf hc])

/-- **A view of a temporary outlives no statement.** A binding whose
call's API is `from` the temporary's position is rejected: its result
would view the temporary after the statement drops it (CORE §3, "a view
of it may be used only within its statement"; the error "a view of the
temporary ... outlives its statement"). -/
theorem temp_from_rejected {Γ : Ctx} {M L : List Var} {r : Var} {api : Clauses} {f : Impl}
    {h hv : Var} {e : Expr} {args : List Var} {rest : TProg} (h0 : 0 ∈ api.src) :
    checkT Γ M L (.callTemp r api f h hv e args rest) = none := by
  rw [Option.eq_none_iff_forall_ne_some]
  intro res hc
  simp only [checkT, Option.bind_eq_bind, Option.bind_eq_some_iff, guard_some, exists_const] at hc
  obtain ⟨-, hid, ⟨τe, M1⟩, -, hc⟩ := hc
  simp only at hc
  obtain ⟨ho, τc, hcc, hlh, -⟩ := hc
  obtain ⟨-, -, hne, -, -, hn, hha, hva⟩ := hidden_spec hid
  have := (checkCall_temp hn hne hha hva hcc).2 h0
  simp [this] at hlh

-- The proofs assume nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.temps_run' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in
#print axioms temps_run

/-! ### Examples -/

namespace Temps

/-- `pick(a: ?Int, b: ?Int) -> ?Int from b`, and `from a`. -/
def pickB : Clauses := { src := [1], keeps := [] }
def pickA : Clauses := { src := [0], keeps := [] }

/-- Implementations within them: read both, return the second, or the first. -/
def retB : Impl := { clauses := pickB, reads := [0, 1], ret := 1 }
def retA : Impl := { clauses := pickA, reads := [0, 1], ret := 0 }

/-- `a = 1`, `ra = ?a`, `r = pick(?^5, ra)`, `print(r)`: the temporary
`^5` is dropped where the call's statement ends, and `r` views `a`. -/
def viewsArg (api : Clauses) (f : Impl) : TProg :=
  .bind "a" (.lit 1) <| .bind "ra" (.lend .read "a") <|
  .callTemp "r" api f "%t" "%v" (.box (.lit 5)) ["ra"] <|
  .expr (.out (.name "r"))

#guard acceptsT (viewsArg pickB retB)

/-- info: LambdaRig.Outcome.ok [5, 1, 1] -/
#guard_msgs in #eval run (viewsArg pickB retB).elab

-- Rejected: with the API `from a`, `r` would view the temporary after
-- its statement.
#guard !acceptsT (viewsArg pickA retA)

-- Run all the same, the view is used after the temporary is freed.
/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.freed 4) -/
#guard_msgs in #eval run (viewsArg pickA retA).elab

/-- `a = 1`, `ra = ?a`, `print(pick(?^5, ra))`: a result that views the
temporary, used within its statement. -/
def usedWithin : TProg :=
  .bind "a" (.lit 1) <| .bind "ra" (.lend .read "a") <|
  .printTemp pickA retA "%t" "%v" (.box (.lit 5)) ["ra"] <|
  .expr (.lit 0)

#guard acceptsT usedWithin

/-- info: LambdaRig.Outcome.ok [5, 1, 5] -/
#guard_msgs in #eval run usedWithin.elab

example : (viewsArg pickB retB).Fits := by
  simp [viewsArg, TProg.Fits, Impl.Meets, Impl.leaves, Leaves.Meets, Clauses.Within, retB, pickB]

example : usedWithin.Fits := by
  simp [usedWithin, TProg.Fits, Impl.Meets, Impl.leaves, Leaves.Meets, Clauses.Within, retA, pickA]

end Temps

end LambdaRig
