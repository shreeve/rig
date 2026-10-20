/-
The ring of a worker's ready fibers (src/sched.zig, `Ring`): its owner
pushes at `tail` and pops at `head`; thieves steal half of it
(`stealFrom`); a push to a full ring hands its older half to the global
queue. Each step below is one atomic load, store, or compare-and-swap
of `head`, `tail`, or a slot, as the Zig code makes them.

Checked: no fiber is taken twice (by a pop, a steal, or the overflow to
the global queue), `head` never passes `tail` nor falls `size` behind
it, and once every thread is done, every fiber pushed was taken once or
is still in the ring, once. Counters do not wrap (a u32 would, after
2^32 pushes).
-/
import Models.Explore

namespace Models.Ring

structure Thief where
  pc : Nat
  h : Nat
  t : Nat
  n : Nat
  buf : List Nat
  tries : Nat
  deriving BEq, Hashable, Repr, Inhabited

structure State where
  head : Nat
  tail : Nat
  slots : List (Option Nat)
  /-- The owner: where it is, what it loaded, the fiber it pushes or
  popped, and how many it has pushed and popped. -/
  pc : Nat
  oh : Nat
  ot : Nat
  oi : Nat
  of : Nat
  pushed : Nat
  pops : Nat
  thieves : List Thief
  /-- How many times each fiber was taken. -/
  taken : List Nat
  deriving BEq, Hashable, Repr, Inhabited

structure Bounds where
  /-- The ring's size; the overflow moves half. -/
  size : Nat
  /-- Fibers the owner pushes, and pops it tries. -/
  pushes : Nat
  pops : Nat
  /-- Steals each thief tries (a compare-and-swap that fails retries
  without counting). -/
  steals : List Nat
  /-- Broken on purpose, to show the check finds it: a thief moves
  `head` with a plain store, not a compare-and-swap. -/
  blindSteal : Bool := false

def take (s : State) (g : Nat) : State :=
  { s with taken := s.taken.modify g (· + 1) }

def slot (s : State) (b : Bounds) (i : Nat) : Option Nat := (s.slots[i % b.size]?).join

def owner (b : Bounds) (s : State) : List State :=
  let half := b.size / 2
  match s.pc with
  -- Push the next fiber, or pop, while there are any to.
  | 0 => (if s.pushed < b.pushes then [{ s with pc := 1, of := s.pushed }] else []) ++
      (if s.pops < b.pops then [{ s with pc := 10 }] else []) ++
      (if s.pushed == b.pushes && s.pops == b.pops then [{ s with pc := 99 }] else [])
  -- push: `t = tail`, `h = head`
  | 1 => [{ s with pc := 2, ot := s.tail }]
  | 2 => [{ s with pc := 3, oh := s.head }]
  | 3 => if s.ot - s.oh < b.size then
           [{ s with pc := 4, slots := s.slots.set (s.ot % b.size) (some s.of) }]
         else [{ s with pc := 5 }]
  | 4 => [{ s with pc := 0, tail := s.ot + 1, pushed := s.pushed + 1 }]
  -- full: claim the older half, then hand it and the new fiber over
  | 5 => if s.head == s.oh then [{ take s s.of with pc := 6, head := s.oh + half, oi := 0 }]
         else [{ s with pc := 1 }]
  | 6 => if s.oi < half then
           match slot s b (s.oh + s.oi) with
           | some g => [{ take s g with oi := s.oi + 1 }]
           | none => [{ s with pc := 98 }]
         else [{ s with pc := 0, pushed := s.pushed + 1 }]
  -- pop: `h = head`, `t = tail`, the slot, then claim it
  | 10 => [{ s with pc := 11, oh := s.head }]
  | 11 => if s.oh == s.tail then [{ s with pc := 0, pops := s.pops + 1 }]
          else [{ s with pc := 12, ot := s.tail }]
  | 12 => match slot s b s.oh with
          | some g => [{ s with pc := 13, of := g }]
          | none => [{ s with pc := 98 }]
  | 13 => if s.head == s.oh then [{ take s s.of with pc := 0, head := s.oh + 1, pops := s.pops + 1 }]
          else [{ s with pc := 10 }]
  | _ => []

def thief (b : Bounds) (s : State) (k : Nat) (th : Thief) : List State :=
  let set (th' : Thief) (s' : State := s) : State := { s' with thieves := s.thieves.set k th' }
  match th.pc with
  | 0 => if th.tries > 0 then [set { th with pc := 1, tries := th.tries - 1 }] else [set { th with pc := 99 }]
  -- `h = head`, `t = tail`
  | 1 => [set { th with pc := 2, h := s.head }]
  | 2 =>
    let avail := s.tail - th.h
    if avail == 0 || avail > b.size then [set { th with pc := 0 }]
    else [set { th with pc := 3, t := s.tail, n := avail - avail / 2, buf := [] }]
  -- copy the fibers it would take, one slot a step
  | 3 => if th.buf.length < th.n then
           match slot s b (th.h + th.buf.length) with
           | some g => [set { th with buf := th.buf ++ [g] }]
           | none => [set { th with pc := 0 }]
         else [set { th with pc := 4 }]
  -- claim them by moving `head` past them
  | 4 => if s.head == th.h || b.blindSteal then
           [set { th with pc := 0 } (th.buf.foldl take { s with head := th.h + th.n })]
         else [set { th with pc := 1 }]
  | _ => []

def next (b : Bounds) (s : State) : Array State :=
  let ts := (List.range s.thieves.length).flatMap fun k => thief b s k s.thieves[k]!
  (owner b s ++ ts).toArray

/-- The fibers in the ring: those from `head` to `tail`. -/
def inRing (b : Bounds) (s : State) : List Nat :=
  (List.range (s.tail - s.head)).filterMap fun i => slot s b (s.head + i)

def inv (b : Bounds) (s : State) : Option String :=
  if s.pc == 98 then some "a slot claimed is empty"
  else if s.taken.any (· > 1) then some "a fiber was taken twice"
  else if s.head > s.tail then some "head passed tail"
  else if s.tail - s.head > b.size then some "the ring holds more than its size"
  else none

def stuck (b : Bounds) (s : State) : Option String :=
  let left := inRing b s
  if (List.range s.pushed).all fun g => s.taken[g]! + left.count g == 1 then none
  else some "a fiber pushed was lost or kept twice"

def done (s : State) : Bool := s.pc == 99 && s.thieves.all (·.pc == 99)

def system (b : Bounds) : System State where
  init := { head := 0, tail := 0, slots := List.replicate b.size none, pc := 0, oh := 0, ot := 0,
            oi := 0, of := 0, pushed := 0, pops := 0,
            thieves := b.steals.map fun n => ⟨0, 0, 0, 0, [], n⟩,
            taken := List.replicate b.pushes 0 }
  next := next b
  inv := inv b
  stuck := stuck b
  done := done

end Models.Ring
