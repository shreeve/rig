/-
λRig: the machine an interpreter runs on.

Every place is a cell. A cell records the tags of the loans that are
live on it: any number of read tags, or one write tag, never both
(CORE sentence 5). The five ways to touch a cell below each keep that
true, and `Cell.WF` states it; LambdaRig/Loans.lean proves it.
-/
import LambdaRig.Syntax

namespace LambdaRig

/-- A place in memory, with the loans live on it. -/
structure Cell where
  /-- `none` once the value has moved out. -/
  val   : Option Val
  /-- Tags of live read loans. -/
  reads : List Tag
  /-- Tag of the live write loan. -/
  write : Option Tag
  deriving DecidableEq, Repr

/-- Read loans or one write loan, never both (CORE sentence 5). -/
def Cell.WF (c : Cell) : Prop := c.write = none ∨ c.reads = []

/-- A fresh cell holds no loans. -/
def Cell.fresh (v : Val) : Cell := { val := some v, reads := [], write := none }

/-- `?x`: a new read loan ends any write loan. -/
def Cell.lendRead (c : Cell) (t : Tag) : Cell := { c with write := none, reads := t :: c.reads }

/-- `!x`: a new write loan ends every other loan. -/
def Cell.lendWrite (c : Cell) (t : Tag) : Cell := { c with write := some t, reads := [] }

/-- The owner reads its own place: that ends a write loan, since a write
view may no longer assume nothing else sees the value. -/
def Cell.ownerRead (c : Cell) : Cell := { c with write := none }

/-- The owner writes, moves out of, or drops its place: that ends every loan. -/
def Cell.ownerWrite (_c : Cell) (v : Option Val) : Cell := { val := v, reads := [], write := none }

/-- A write view writes what it sees: the write loan stays, read loans end. -/
def Cell.viewWrite (c : Cell) (v : Val) : Cell := { c with val := some v, reads := [] }

/-- Is a view's tag still live on this cell? -/
def Cell.live (c : Cell) : Mode → Tag → Bool
  | .read,  t => c.reads.contains t
  | .write, t => c.write == some t

/-- Why a run stopped. Every fault but `stuck` is a broken safety promise;
`stuck` is a program no type checker would accept. -/
inductive Fault where
  | unbound (x : Var)
  /-- Use after move. -/
  | moved (x : Var)
  /-- Use after free, or a double free. -/
  | freed (l : Loc)
  /-- A view used after its loan ended: the view would see a change. -/
  | deadTag (t : Tag)
  /-- Cells still allocated when the program ends. -/
  | leak (ls : List Loc)
  | stuck (what : String)
  deriving DecidableEq, Repr

structure Machine where
  heap : List (Loc × Cell) := []
  env  : List (Var × Loc) := []
  /-- The next fresh location or tag. -/
  next : Nat := 0
  /-- What `print` printed, newest first. -/
  out  : List Int := []
  deriving Repr

abbrev M := StateT Machine (Except Fault)

def fresh : M Nat := do
  let s ← get
  set { s with next := s.next + 1 }
  pure s.next

def cell (l : Loc) : M Cell := do
  match (← get).heap.lookup l with
  | some c => pure c
  | none => throw (.freed l)

/-- Replace the cell at `l`, which must be allocated. -/
def setCell (l : Loc) (c : Cell) : M Unit := do
  let s ← get
  match s.heap.lookup l with
  | some _ => set { s with heap := s.heap.map fun (p : Loc × Cell) => if p.1 = l then (l, c) else p }
  | none => throw (.freed l)

def alloc (v : Val) : M Loc := do
  let l ← fresh
  modify fun s => { s with heap := (l, Cell.fresh v) :: s.heap }
  pure l

def free (l : Loc) : M Unit := do
  let s ← get
  match s.heap.lookup l with
  | some _ => set { s with heap := s.heap.filter fun (p : Loc × Cell) => p.1 != l }
  | none => throw (.freed l)

def slotOf (x : Var) : M Loc := do
  match (← get).env.lookup x with
  | some l => pure l
  | none => throw (.unbound x)

/-- Drop a value no place holds any more: a box frees what it owns. -/
def dropVal : Val → M Unit
  | .box b => free b
  | _ => pure ()

/-- Read an Int through a view, if its loan is still live. -/
def deref (m : Mode) (l : Loc) (t : Tag) : M Int := do
  let c ← cell l
  unless c.live m t do throw (.deadTag t)
  match c.val with
  | some (.int n) => pure n
  | _ => throw (.stuck "a view of something that is not an Int")

end LambdaRig
