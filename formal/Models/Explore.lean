/-
An explicit-state model checker: every state a system of atomic steps
reaches from its first, breadth first.

A system gives its first state, every step enabled in a state (one per
thread that can take one, each an atomic instruction), what must hold
of every state reached, what must hold of a state where no step is
enabled (a thread that waits in a poller, for a kick no one will send,
takes none), and the states that count as done. `explore` reports the
states and steps seen, the states with no step enabled, and the first
state that breaks a rule, with the run that reaches it. It also checks
that from every state reached, some run reaches a state that is done,
so no run is stuck in a loop it cannot leave.

It runs when `lake build` elaborates the models (`#eval`), not as a
proof: it checks the models within their bounds, and says nothing past
them, nor of orderings weaker than sequentially consistent.
-/
import Std.Data.HashMap

namespace Models

structure System (σ : Type) where
  init : σ
  next : σ → Array σ
  /-- Of every state reached: `some` names what broke. -/
  inv : σ → Option String
  /-- Of a state where no step is enabled. -/
  stuck : σ → Option String
  /-- The states that count as done: every state reached must be able
  to reach one. -/
  done : σ → Bool

structure Report where
  states : Nat
  steps : Nat
  stuck : Nat
  /-- The first rule broken, with the run that reaches it. -/
  error : Option String
  deriving Repr

def Report.ok (r : Report) : Bool := r.error.isNone

instance : ToString Report where
  toString r := match r.error with
    | none => s!"ok: {r.states} states, {r.steps} steps, {r.stuck} with no step enabled"
    | some e => s!"FAILED after {r.states} states: {e}"

/-- The run from the first state to state `i`, through `parent`. -/
partial def trace [Inhabited σ] [Repr σ] (states : Array σ) (parent : Array Nat) (i : Nat) : List String :=
  let s := states[i]!
  let here := reprStr s
  if i == 0 then [here] else trace states parent parent[i]! ++ [here]

/-- The report's first line: its counts, or the rule broken. -/
def Report.summary (r : Report) : String := ((toString r).splitOn "\n").head!

def explore [Inhabited σ] [BEq σ] [Hashable σ] [Repr σ] (sys : System σ) (limit : Nat := 5000000) : Report := Id.run do
  let mut index : Std.HashMap σ Nat := {}
  let mut states : Array σ := #[sys.init]
  let mut parent : Array Nat := #[0]
  let mut succ : Array (Array Nat) := #[]
  index := index.insert sys.init 0
  let mut steps := 0
  let mut stuck := 0
  let mut i := 0
  while i < states.size do
    let s := states[i]!
    if let some e := sys.inv s then
      return { states := states.size, steps, stuck,
               error := some (e ++ "\n  " ++ String.intercalate "\n  " (trace states parent i)) }
    let ns := sys.next s
    if ns.isEmpty then
      stuck := stuck + 1
      if let some e := sys.stuck s then
        return { states := states.size, steps, stuck,
                 error := some (e ++ "\n  " ++ String.intercalate "\n  " (trace states parent i)) }
    let mut out : Array Nat := #[]
    for n in ns do
      steps := steps + 1
      match index.get? n with
      | some j => out := out.push j
      | none =>
        let j := states.size
        index := index.insert n j
        states := states.push n
        parent := parent.push i
        out := out.push j
    succ := succ.push out
    if states.size > limit then
      return { states := states.size, steps, stuck, error := some "too many states" }
    i := i + 1
  -- Every state can reach one that is done: search back from those.
  let mut pred : Array (Array Nat) := Array.replicate states.size #[]
  for h : a in [0:succ.size] do
    for b in succ[a] do
      pred := pred.modify b (·.push a)
  let mut can : Array Bool := states.map sys.done
  let mut work : Array Nat := #[]
  for h : a in [0:states.size] do
    if can[a]! then work := work.push a
  while !work.isEmpty do
    let b := work.back!
    work := work.pop
    for a in pred[b]! do
      if !can[a]! then
        can := can.set! a true
        work := work.push a
  for h : a in [0:states.size] do
    if !can[a]! then
      return { states := states.size, steps, stuck,
               error := some ("no run from here is done\n  " ++
                 String.intercalate "\n  " (trace states parent a)) }
  return { states := states.size, steps, stuck, error := none }

end Models
