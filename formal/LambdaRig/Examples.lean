/-
λRig: programs and how each run ends, checked by `lake build`.

Each program is a Rig program from the Core, written in λRig. One that
`rig check` accepts runs to the end owning nothing; one it rejects
stops here at the broken promise the rejection prevents.
-/
import LambdaRig.Interp

namespace LambdaRig.Examples
open Expr

/-- `a ; b` -/
infixr:50 " ;; " => Expr.seq

/-- A box written through a write view, then read by its owner:
`v = ^1`, `w = !v`, `w = 5`, `print(v)`. -/
def writeThenRead : Expr :=
  letIn "v" (box (lit 1)) <|
  letIn "w" (lend .write "v") <|
  assign "w" (lit 5) ;; out (name "v")

/-- info: LambdaRig.Outcome.ok [5] -/
#guard_msgs in #eval run writeThenRead

/-- A clone is a new owner: `a = ^1`, `b = +a`, `w = !b`, `w = 2`, `print(a)`, `print(b)`. -/
def cloneIsNewOwner : Expr :=
  letIn "a" (box (lit 1)) <|
  letIn "b" (clone "a") <|
  letIn "w" (lend .write "b") <|
  assign "w" (lit 2) ;; out (name "a") ;; out (name "b")

/-- info: LambdaRig.Outcome.ok [1, 2] -/
#guard_msgs in #eval run cloneIsNewOwner

/-- Rejected: `v` used after it moved. `v = ^1`, `w = <v`, `print(v)`. -/
def useAfterMove : Expr :=
  letIn "v" (box (lit 1)) <|
  letIn "w" (move "v") <|
  out (name "v")

/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.moved "v") -/
#guard_msgs in #eval run useAfterMove

/-- Rejected (CORE, "Three words"): a write lend while a read loan is
live. `a = ?v`, `b = a`, `w = !v`, `w = 2`, `print(a)`. -/
def writeWhileRead : Expr :=
  letIn "v" (box (lit 1)) <|
  letIn "a" (lend .read "v") <|
  letIn "b" (name "a") <|
  letIn "w" (lend .write "v") <|
  assign "w" (lit 2) ;; out (name "a")

/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.deadTag 2) -/
#guard_msgs in #eval run writeWhileRead

/-- Rejected (sentence 5, numbers included): assigning `n` while a read
view of it is live. `n = 1`, `r = ?n`, `n = 2`, `print(r)`. -/
def assignWhileRead : Expr :=
  letIn "n" (lit 1) <|
  letIn "r" (lend .read "n") <|
  assign "n" (lit 2) ;; out (name "r")

/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.deadTag 1) -/
#guard_msgs in #eval run assignWhileRead

/-- Rejected: the owner reads while a write loan is live.
`n = 1`, `w = !n`, `print(n)`, `w = 3`. -/
def readWhileWrite : Expr :=
  letIn "n" (lit 1) <|
  letIn "w" (lend .write "n") <|
  out (name "n") ;; assign "w" (lit 3)

/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.deadTag 1) -/
#guard_msgs in #eval run readWhileWrite

/-- Rejected: a view outlives the box it sees. `b = ^1`, `r = ?b`, `<b`, `print(r)`. -/
def dropWhileRead : Expr :=
  letIn "b" (box (lit 1)) <|
  letIn "r" (lend .read "b") <|
  drop "b" ;; out (name "r")

/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.freed 0) -/
#guard_msgs in #eval run dropWhileRead

/-- Rejected: a view outlives the scope of the name it sees.
`r = (x = 7; ?x)`, `print(r)`. -/
def viewOutlivesScope : Expr :=
  letIn "r" (letIn "x" (lit 7) (lend .read "x")) <|
  out (name "r")

/-- info: LambdaRig.Outcome.fault (LambdaRig.Fault.freed 0) -/
#guard_msgs in #eval run viewOutlivesScope

/-- Read views copy and share one loan; each still reads after the other
is used (sentence 1). `n = 4`, `a = ?n`, `b = a`, `print(a + b)`. -/
def readViewsShare : Expr :=
  letIn "n" (lit 4) <|
  letIn "a" (lend .read "n") <|
  letIn "b" (name "a") <|
  out (add (name "a") (name "b"))

/-- info: LambdaRig.Outcome.ok [8] -/
#guard_msgs in #eval run readViewsShare

/-- Temporaries drop where their statement ends (sentence 3), so
`print(^3)` and a discarded `^4` leave nothing behind. -/
def temporariesDrop : Expr :=
  out (box (lit 3)) ;; box (lit 4) ;; out (lit 0)

/-- info: LambdaRig.Outcome.ok [3, 0] -/
#guard_msgs in #eval run temporariesDrop

end LambdaRig.Examples
