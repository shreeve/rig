/-
λRig: the ownership checker.

This is `rig check` for λRig: it reads a program once, ahead of time,
and accepts it or not. It tracks the type of every name in scope, which
names have moved out, and which views are still used later; a loan lasts
until the last use of every view carrying it (CORE sentence 6).
LambdaRig/Sound.lean proves that a program it accepts runs to the end
without a fault and owns nothing when it ends.
-/
import LambdaRig.Interp

namespace LambdaRig

/-- The type of a value. A view's type names the owner it was lent from. -/
inductive Ty where
  | unit
  | int
  | box
  /-- A view lent from the owner named `y`: `?Int` or `!Int` if `y` holds
  an Int, `?^Int` or `!^Int` if it holds a box. It sees `y`'s place. -/
  | view (m : Mode) (y : Var)
  deriving DecidableEq, Repr

/-- An owner: a name whose place can be lent. -/
def Ty.owner : Ty → Bool
  | .int | .box => true
  | _ => false

/-- The names in scope, innermost first, with their types. -/
abbrev Ctx := List (Var × Ty)

/-- The names an expression uses. -/
def fv : Expr → List Var
  | .lit _ => []
  | .name x | .move x | .clone x | .lend _ x | .drop x => [x]
  | .assign x e => x :: fv e
  | .box e | .out e => fv e
  | .add a b | .seq a b => fv a ++ fv b
  | .letIn x e body => fv e ++ (fv body).filter (· ≠ x)

/-- How an access touches an owner's place. -/
inductive Access where
  /-- The owner reads it, or lends it to read: write loans end. -/
  | read
  /-- The owner writes, moves, drops, or lends it to write: every loan ends. -/
  | write
  /-- A write view writes through: read loans end. -/
  | through
  deriving DecidableEq, Repr

/-- Does an access end a loan of mode `m`? -/
def Access.ends : Access → Mode → Bool
  | .read, m => m == .write
  | .write, _ => true
  | .through, m => m == .read

/-- An access to `y` is allowed when no view of `y` whose loan it would
end is used later (sentences 5 and 6). -/
def allows (Γ : Ctx) (y : Var) (k : Access) (later : List Var) : Bool :=
  Γ.all fun
    | (v, .view m y') => !(y' == y && later.contains v && k.ends m)
    | _ => true

/-- Is this a view lent from `x`? -/
def Ty.lentFrom : Ty → Var → Bool
  | .view _ y, x => y == x
  | _, _ => false

/-- A value `+` reads an Int from: a number or a view of one. -/
def Ty.readsInt (Γ : Ctx) : Ty → Bool
  | .int => true
  | .view _ y => Γ.lookup y == some .int
  | _ => false

/-- Check `e` in scope `Γ`, where the names in `moved` have moved out
and the names in `later` are used after `e`. It returns the type of `e`
and the names moved out once it ends. -/
def check (Γ : Ctx) (moved : List Var) (later : List Var) : Expr → Option (Ty × List Var)
  | .lit _ => some (.int, moved)
  | .name x => do
    let τ ← Γ.lookup x
    guard (!moved.contains x)
    match τ with
    | .int => do guard (allows Γ x .read later); some (.int, moved)
    | .view .read y => some (.view .read y, moved)
    | .view .write y => do guard (Γ.lookup y == some .int); some (.int, moved)
    | .unit => some (.unit, moved)
    -- A box is not copied by a bare name: it moves, clones, or lends.
    | .box => none
  | .move x => do
    let τ ← Γ.lookup x
    guard (!moved.contains x)
    guard (!τ.owner || allows Γ x .write later)
    some (τ, x :: moved)
  | .clone x => do
    let τ ← Γ.lookup x
    guard (!moved.contains x)
    match τ with
    | .int => do guard (allows Γ x .read later); some (.int, moved)
    | .box => do guard (allows Γ x .read later); some (.box, moved)
    -- `+v` through a view clones what the view sees.
    | .view _ y => do
      let τy ← Γ.lookup y
      guard τy.owner
      some (τy, moved)
    | .unit => some (.unit, moved)
  | .box e => do
    let (τ, moved) ← check Γ moved later e
    guard (τ == .int)
    some (.box, moved)
  | .lend m x => do
    let τ ← Γ.lookup x
    guard (!moved.contains x && τ.owner)
    guard (allows Γ x (match m with | .read => .read | .write => .write) later)
    some (.view m x, moved)
  | .assign x e => do
    let (τe, moved) ← check Γ moved (x :: later) e
    let τ ← Γ.lookup x
    match τ with
    | .int | .box => do
      guard (τe == τ && allows Γ x .write later)
      some (.unit, moved.filter (· ≠ x))
    | .view .write y => do
      guard (Γ.lookup y == some τe && !moved.contains x && allows Γ y .through later)
      some (.unit, moved)
    | _ => none
  | .drop x => do
    let τ ← Γ.lookup x
    guard (!moved.contains x)
    guard (!τ.owner || allows Γ x .write later)
    some (.unit, x :: moved)
  | .add a b => do
    let (τa, moved) ← check Γ moved (fv b ++ later) a
    guard (τa.readsInt Γ)
    let (τb, moved) ← check Γ moved later b
    guard (τb.readsInt Γ)
    some (.int, moved)
  | .out e => do
    let (τ, moved) ← check Γ moved later e
    guard (τ != .unit)
    some (.unit, moved)
  | .seq a b => do
    let (_, moved) ← check Γ moved (fv b ++ later) a
    check Γ moved later b
  | .letIn x e body => do
    guard ((Γ.lookup x).isNone && !moved.contains x)
    let (τe, moved) ← check Γ moved ((fv body).filter (· ≠ x) ++ later) e
    let (τ, moved) ← check ((x, τe) :: Γ) moved later body
    guard (!τ.lentFrom x)
    some (τ, moved.filter (· ≠ x))

/-- `rig check` for a whole program. -/
def accepts (e : Expr) : Bool := (check [] [] [] e).isSome

end LambdaRig
