/-
λRig: the syntax of the core calculus.

λRig keeps what the Core (docs/CORE.md) rules on and leaves out syntax,
generics, modules, and text. This first slice has one kind of owner, a
box holding an Int (`^Int`); every binding is a place in memory, so a
plain Int can be lent too (CORE sentence 5: "numbers included").
-/

namespace LambdaRig

abbrev Var := String
abbrev Loc := Nat
abbrev Tag := Nat

/-- What a view may do: `?` reads, `!` writes. -/
inductive Mode where
  | read
  | write
  deriving DecidableEq, Repr

/-- A value. A view carries the tag of the loan it was lent under. -/
inductive Val where
  | unit
  | int (n : Int)
  /-- `^Int`: the one owner of heap cell `l`. -/
  | box (l : Loc)
  /-- `?Int` or `!Int`: a view of cell `l`, lent under tag `t`. -/
  | view (m : Mode) (l : Loc) (t : Tag)
  deriving DecidableEq, Repr

/-- An expression. Each constructor names the Rig form it stands for. -/
inductive Expr where
  /-- `5` -/
  | lit (n : Int)
  /-- `x`: a bare name only reads (CORE sentence 1). -/
  | name (x : Var)
  /-- `<x` as a value: moves `x` (sentence 2). -/
  | move (x : Var)
  /-- `+x`: a new owner (sentence 2). -/
  | clone (x : Var)
  /-- `^e`: a new box. -/
  | box (e : Expr)
  /-- `?x` and `!x` (sentence 4). -/
  | lend (m : Mode) (x : Var)
  /-- `x = e`; through a write view, it writes what the view sees. -/
  | assign (x : Var) (e : Expr)
  /-- `<x` as a statement: drop now (sentence 2). -/
  | drop (x : Var)
  /-- `a + b` -/
  | add (a b : Expr)
  /-- `print(e)` -/
  | out (e : Expr)
  /-- Two statements in order; the first one's value drops where it ends (sentence 3). -/
  | seq (a b : Expr)
  /-- `x = e` followed by `body`, the scope of `x`; `x` drops where `body` ends (sentence 3). -/
  | letIn (x : Var) (e body : Expr)
  deriving Repr

end LambdaRig
