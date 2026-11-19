/-
The ring of a worker's ready fibers (src/sched.zig, `Ring`): its owner
pushes at `tail` and pops at `head`; for a fork-join it takes back the
newest from `tail` (`takeLast`); thieves steal half of it, rounded up
(`stealFrom`); a push to a full ring hands its older half to the global
queue. Each step below is one atomic load, store, or compare-and-swap
of `head`, `tail`, `stealing`, or a slot, as the Zig code makes them.

`takeLast` names the fiber in the newest slot, moves `tail` back, reads
`stealing` and, while a thief holds it, puts `tail` back and leaves the
fiber; else it reads `head`, takes the fiber with no compare-and-swap
when others are left, and races the thieves with a compare-and-swap of
`head` when it was the last. A thief looks at the ring (`tail`, then
`head`), takes `stealing` by compare-and-swap, reads `head` and `tail`,
copies the fibers it would take, one slot a step, claims them with a
compare-and-swap of `head`, and lets `stealing` go.

`Bounds.flag := false` is the code before #1157: no `stealing`, no
look before it, and a `takeLast` that never reads a flag. Its thief
claims by checking only `head`, so an owner that took back two fibers
from `tail` meanwhile, the second one with no compare-and-swap, runs
a fiber the thief also claims. `Checks.lean` finds that run.

Checked: no fiber is taken twice (by a pop, a take back, a steal, or
the overflow to the global queue); `head` never passes `tail` except
while the owner's `takeLast` has moved `tail` back and not yet put it
back, and then by at most one; the ring never holds more than its size;
and once every thread is done, every fiber pushed was taken once or is
still in the ring, once. Counters do not wrap (a u32 would, after 2^32
pushes). Every step is sequentially consistent: the accesses #1157's
argument rests on (the owner's store of `tail` and read of `stealing`,
the thief's take of `stealing` and read of `tail`) are `.seq_cst` in
the Zig; the ring's other loads, acquire and monotonic, are not checked
weaker here.
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
  /-- 1 while a thief copies from the ring and claims what it copied. -/
  stealing : Bool
  /-- The owner: where it is, what it loaded, the fiber it pushes, popped
  or takes back, and how many it has pushed, popped and taken back. -/
  pc : Nat
  oh : Nat
  ot : Nat
  oi : Nat
  of : Nat
  pushed : Nat
  pops : Nat
  took : Nat
  thieves : List Thief
  /-- How many times each fiber was taken. -/
  taken : List Nat
  deriving BEq, Hashable, Repr, Inhabited

structure Bounds where
  /-- The ring's size; the overflow moves half. -/
  size : Nat
  /-- Fibers the owner pushes, pops it tries, and take backs it tries. -/
  pushes : Nat
  pops : Nat
  takes : Nat := 0
  /-- Steals each thief tries (a compare-and-swap of `head` that fails
  retries without counting). -/
  steals : List Nat
  /-- The `stealing` flag of #1157; false is the code before it. -/
  flag : Bool := true
  /-- Broken on purpose, to show the check finds it: a thief moves
  `head` with a plain store, not a compare-and-swap. -/
  blindSteal : Bool := false

def take (s : State) (g : Nat) : State :=
  { s with taken := s.taken.modify g (· + 1) }

def slot (s : State) (b : Bounds) (i : Nat) : Option Nat := (s.slots[i % b.size]?).join

/-- The owner's pcs while `takeLast` has moved `tail` back. -/
def backPcs : List Nat := [22, 23, 24, 25]

def owner (b : Bounds) (s : State) : List State :=
  let half := b.size / 2
  match s.pc with
  -- Push the next fiber, pop, or take back the newest, while there are
  -- any to.
  | 0 => (if s.pushed < b.pushes then [{ s with pc := 1, of := s.pushed }] else []) ++
      (if s.pops < b.pops then [{ s with pc := 10 }] else []) ++
      (if s.took < b.takes then [{ s with pc := 20 }] else []) ++
      (if s.pushed == b.pushes && s.pops == b.pops && s.took == b.takes then [{ s with pc := 99 }] else [])
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
  -- takeLast(f): `t = tail` and the newest slot, which names `f` (only
  -- the owner writes either); a slot never written names none.
  | 20 => if s.tail == 0 then [{ s with pc := 0, took := s.took + 1 }]
          else match slot s b (s.tail - 1) with
            | some g => [{ s with pc := 21, ot := s.tail, of := g }]
            | none => [{ s with pc := 0, took := s.took + 1 }]
  -- `tail = t - 1`
  | 21 => [{ s with pc := if b.flag then 22 else 23, tail := s.ot - 1 }]
  -- a thief holds `stealing`: put `tail` back, leave the fiber
  | 22 => if s.stealing then [{ s with pc := 0, tail := s.ot, took := s.took + 1 }]
          else [{ s with pc := 23 }]
  -- `h = head`: others left, take it; the last, race for it; none, leave it
  | 23 =>
    let left : Int := (s.ot : Int) - 1 - (s.head : Int)
    if 0 < left && left ≤ b.size then
      [{ take s s.of with pc := 0, oh := s.head, took := s.took + 1 }]
    else if left == 0 then [{ s with pc := 24, oh := s.head }]
    else [{ s with pc := 25, oh := s.head }]
  | 24 => if s.head == s.oh then [{ take s s.of with pc := 25, head := s.oh + 1 }]
          else [{ s with pc := 25 }]
  -- `tail = t`
  | 25 => [{ s with pc := 0, tail := s.ot, took := s.took + 1 }]
  | _ => []

def thief (b : Bounds) (s : State) (k : Nat) (th : Thief) : List State :=
  let set (th' : Thief) (s' : State := s) : State := { s' with thieves := s.thieves.set k th' }
  -- Let `stealing` go (the `defer`), when it holds it.
  let leave : Nat := if b.flag then 9 else 0
  match th.pc with
  | 0 => if th.tries > 0 then [set { th with pc := if b.flag then 1 else 4, tries := th.tries - 1 }]
         else [set { th with pc := 99 }]
  -- the look: `tail`, then `head`; empty, or seen torn, gives up
  | 1 => [set { th with pc := 2, t := s.tail }]
  | 2 =>
    let avail := th.t - s.head
    if avail == 0 || avail > b.size then [set { th with pc := 0 }]
    else [set { th with pc := 3 }]
  -- take `stealing`, or give up while another thief holds it
  | 3 => if s.stealing then [set { th with pc := 0 }]
         else [set { th with pc := 4 } { s with stealing := true }]
  -- `h = head`, `t = tail`
  | 4 => [set { th with pc := 5, h := s.head }]
  | 5 =>
    let avail := s.tail - th.h
    if avail == 0 || avail > b.size then [set { th with pc := leave }]
    else [set { th with pc := 6, t := s.tail, n := avail - avail / 2, buf := [] }]
  -- copy the fibers it would take, one slot a step
  | 6 => if th.buf.length < th.n then
           match slot s b (th.h + th.buf.length) with
           | some g => [set { th with buf := th.buf ++ [g] }]
           | none => [set { th with pc := leave }]
         else [set { th with pc := 7 }]
  -- claim them by moving `head` past them; a lost race reads again
  | 7 => if s.head == th.h || b.blindSteal then
           [set { th with pc := leave } (th.buf.foldl take { s with head := th.h + th.n })]
         else [set { th with pc := 4 }]
  | 9 => [set { th with pc := 0 } { s with stealing := false }]
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
  else if s.head > s.tail + 1 || (s.head > s.tail && !backPcs.contains s.pc) then some "head passed tail"
  else if s.tail - s.head > b.size then some "the ring holds more than its size"
  else none

def stuck (b : Bounds) (s : State) : Option String :=
  let left := inRing b s
  if (List.range s.pushed).all fun g => s.taken[g]! + left.count g == 1 then none
  else some "a fiber pushed was lost or kept twice"

def done (s : State) : Bool := s.pc == 99 && s.thieves.all (·.pc == 99)

def system (b : Bounds) : System State where
  init := { head := 0, tail := 0, slots := List.replicate b.size none, stealing := false,
            pc := 0, oh := 0, ot := 0, oi := 0, of := 0, pushed := 0, pops := 0, took := 0,
            thieves := b.steals.map fun n => ⟨0, 0, 0, 0, [], n⟩,
            taken := List.replicate b.pushes 0 }
  next := next b
  inv := inv b
  stuck := stuck b
  done := done

end Models.Ring
