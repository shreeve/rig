/-
λRig: an interpreter that tags every view with its loan.

It checks nothing statically. It runs a program and stops at the first
broken promise: a use after move or free, a view used after its loan
ended, or a leak. A program `rig check` accepts must never stop here
with anything but `stuck`; that is what stage 3 proves, and what this
interpreter tests until then (docs/FORMAL-RIG.md, stage 2).
-/
import LambdaRig.Machine

namespace LambdaRig

/-- The value `x` holds, failing if it moved out. -/
def held (x : Var) : M (Loc × Cell × Val) := do
  let l ← slotOf x
  let c ← cell l
  match c.val with
  | some v => pure (l, c, v)
  | none => throw (.moved x)

/-- The owner reads the Int in a box in place. -/
def readBox (b : Loc) : M Int := do
  let c ← cell b
  setCell b c.ownerRead
  match c.val with
  | some (.int n) => pure n
  | _ => throw (.stuck "a box that holds no Int")

/-- The Int a value stands for: a number, or what a live view sees. -/
def intOf : Val → M Int
  | .int n => pure n
  | .view m b t => deref m b t
  | _ => throw (.stuck "a value that is not an Int")

def eval : Expr → M Val
  | .lit n => pure (.int n)
  | .name x => do
    let (l, c, v) ← held x
    match v with
    | .int n => setCell l c.ownerRead; pure (.int n)
    | .box b => return .int (← readBox b)
    | .view .read b t => let _ ← deref .read b t; pure v
    | .view .write b t => return .int (← deref .write b t)
    | .unit => pure .unit
  | .move x => do
    let (l, c, v) ← held x
    setCell l (c.ownerWrite none)
    pure v
  | .clone x => do
    let (l, c, v) ← held x
    match v with
    | .int n => setCell l c.ownerRead; pure (.int n)
    | .box b => return .box (← alloc (.int (← readBox b)))
    | .view .read b t => let _ ← deref .read b t; pure v
    | .view .write b t => return .int (← deref .write b t)
    | .unit => pure .unit
  | .box e => do
    match ← eval e with
    | .int n => return .box (← alloc (.int n))
    | _ => throw (.stuck "a box of something that is not an Int")
  | .lend m x => do
    let (l, _, v) ← held x
    let target ← match v with
      | .int _ => pure l
      | .box b => pure b
      | _ => throw (.stuck "lending on a view")
    let c ← cell target
    let t ← fresh
    setCell target (match m with | .read => c.lendRead t | .write => c.lendWrite t)
    pure (.view m target t)
  | .assign x e => do
    let v ← eval e
    let l ← slotOf x
    let c ← cell l
    match c.val with
    | some (.view .write b t) =>
      let cb ← cell b
      unless cb.live .write t do throw (.deadTag t)
      setCell b (cb.viewWrite v)
    | some (.view .read _ _) => throw (.stuck "assigning through a read view")
    | old =>
      setCell l (c.ownerWrite (some v))
      if let some o := old then dropVal o
    pure .unit
  | .drop x => do
    let (l, c, v) ← held x
    setCell l (c.ownerWrite none)
    dropVal v
    pure .unit
  | .add a b => do
    let m ← intOf (← eval a)
    let n ← intOf (← eval b)
    pure (.int (m + n))
  | .out e => do
    let n ← match ← eval e with
      | .int n => pure n
      | .view m b t => deref m b t
      | .box b => do let n ← readBox b; free b; pure n
      | .unit => throw (.stuck "printing nothing")
    modify fun s => { s with out := n :: s.out }
    pure .unit
  | .seq a b => do
    dropVal (← eval a)
    eval b
  | .letIn x e body => do
    let v ← eval e
    let l ← alloc v
    let env ← (·.env) <$> get
    modify fun s => { s with env := (x, l) :: env }
    let r ← eval body
    modify fun s => { s with env := env }
    let c ← cell l
    free l
    if let some o := c.val then dropVal o
    pure r

/-- How a run ended, with what it printed in order. -/
inductive Outcome where
  | ok (out : List Int)
  | fault (f : Fault)
  deriving DecidableEq, Repr

/-- Run a program from an empty machine; it must end owning nothing. -/
def run (e : Expr) : Outcome :=
  let prog : M Unit := do
    dropVal (← eval e)
    let s ← get
    unless s.heap.isEmpty do throw (.leak (s.heap.map (·.1)))
  match prog.run {} with
  | .ok ((), s) => .ok s.out.reverse
  | .error f => .fault f

end LambdaRig
