/-
lrig: λRig's checker and machine, run on programs bin/rig-oracle exports.

    rig-oracle --lambda PROGRAM... | lrig

Each line of the input is `name<TAB>verdict<TAB>program`, where the
verdict is bin/rig's and the program an S-expression of λRig's forms
(test/oracle/lambda.zig writes them). lrig writes each line back with
two more fields: whether `accepts` accepts the program, and how `run`
ends it, `ok` or the fault. A line whose program is not an S-expression
of the forms (one the exporter left out, `outside ...`) is written back
unchanged. test/cli/agree.sh compares the fields.
-/
import LambdaRig.Check

open LambdaRig

namespace LRig

inductive S where
  | atom (s : String)
  | list (xs : List S)

partial def tokens (cs : List Char) (cur : String) (acc : Array String) : Array String :=
  let flush := if cur.isEmpty then acc else acc.push cur
  match cs with
  | [] => flush
  | c :: rest =>
    if c == '(' || c == ')' then tokens rest "" (flush.push (String.singleton c))
    else if c == ' ' then tokens rest "" flush
    else tokens rest (cur.push c) acc

partial def parse (ts : List String) : Option (S × List String) :=
  match ts with
  | "(" :: rest =>
    let rec items (ts : List String) (acc : Array S) : Option (S × List String) :=
      match ts with
      | ")" :: rest => some (.list acc.toList, rest)
      | [] => none
      | _ => do
        let (x, rest) ← parse ts
        items rest (acc.push x)
    items rest #[]
  | ")" :: _ => none
  | t :: rest => some (.atom t, rest)
  | [] => none

def mode : String → Option Mode
  | "read" => some .read
  | "write" => some .write
  | _ => none

partial def toExpr : S → Option Expr
  | .list [.atom "lit", .atom n] => (String.toInt? n).map .lit
  | .list [.atom "name", .atom x] => some (.name x)
  | .list [.atom "move", .atom x] => some (.move x)
  | .list [.atom "clone", .atom x] => some (.clone x)
  | .list [.atom "box", e] => (toExpr e).map .box
  | .list [.atom "lend", .atom m, .atom x] => (mode m).map (fun m => .lend m x)
  | .list [.atom "assign", .atom x, e] => (toExpr e).map (.assign x)
  | .list [.atom "drop", .atom x] => some (.drop x)
  | .list [.atom "add", a, b] => do some (.add (← toExpr a) (← toExpr b))
  | .list [.atom "out", e] => (toExpr e).map .out
  | .list [.atom "seq", a, b] => do some (.seq (← toExpr a) (← toExpr b))
  | .list [.atom "let", .atom x, e, b] => do some (.letIn x (← toExpr e) (← toExpr b))
  | _ => none

def fault : Fault → String
  | .unbound x => s!"unbound {x}"
  | .moved x => s!"moved {x}"
  | .freed l => s!"freed {l}"
  | .deadTag t => s!"deadTag {t}"
  | .leak _ => "leak"
  | .stuck w => s!"stuck {w}"

def judge (src : String) : Option (Bool × String) := do
  let (s, rest) ← parse (tokens src.toList "" #[]).toList
  guard rest.isEmpty
  let e ← toExpr s
  let outcome := match run e with
    | .ok _ => "ok"
    | .fault f => fault f
  some (accepts e, outcome)

end LRig

partial def loop (stdin : IO.FS.Stream) (stdout : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then return
  let line := (line.dropEndWhile (fun c => c == '\n' || c == '\r')).toString
  match line.splitOn "\t" with
  | [name, verdict, prog] =>
    match LRig.judge prog with
    | some (acc, outcome) =>
      stdout.putStrLn s!"{name}\t{verdict}\t{prog}\t{if acc then "accept" else "reject"}\t{outcome}"
    | none => stdout.putStrLn line
  | _ => stdout.putStrLn line
  loop stdin stdout

def main : IO Unit := do
  loop (← IO.getStdin) (← IO.getStdout)
