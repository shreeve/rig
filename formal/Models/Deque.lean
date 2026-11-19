/-
The fork deque of a worker (`Forks`, docs/history/records/2026-11/
free-fork-join/runtime.md §3), as designed, before its Zig is written:
a Chase-Lev deque of forks. Its owner pushes at `bottom` and takes
from `bottom`; thieves take the oldest at `top`, one at a time, by a
compare-and-swap of `top`.

- `push(f)`: `b = bottom`, `t = top`; full (`b - t == size`), the fork
  goes to the slots and the ring instead (here: taken at once by that
  path); else `slots[b] = f` (monotonic), `bottom = b + 1` (release).
- `popIf(f)`, at `f`'s join: `b = bottom - 1`; a slot there that is not
  `f` returns false untouched; else `bottom = b` (seq_cst), `t = top`
  (seq_cst); `t < b` takes it; `t == b` races the thieves by a
  compare-and-swap of `top` and puts `bottom` back; `t > b` puts it back
  and takes nothing.
- `popNewest()`, the worker's loop when the maker parked: the same for
  whatever is newest; the fork then runs as a fiber.
- `steal()`: `t = top`, `b = bottom` (seq_cst each); if `t < b`,
  `x = slots[t]`, the pointer only, never read through, then a
  compare-and-swap of `top`; `x` is the thief's only if it won. The
  winner adopts the fork (a write into its record: `TaskState.stolen`),
  runs it, and ends it (`Done`'s `ended`, its last write).

The maker is the owner: it pushes forks and joins them newest first,
each by `popIf`. A fork it took it runs inline; else it waits for the
record's `ended`. Either way it then lets the record go (its frame is
used again). Only the owner writes the slots, so a `popIf` that takes
takes the fork it named.

Checked: no fork is taken twice (two of the owner's join, its loop, a
thief, and the overflow); no thief takes an empty slot; `top` passes
`bottom`, as the owner sees it, only while the owner's take has moved
`bottom` back, and by one; no write into a record after the owner let
it go, so a stolen fork's record outlives the thief's last write; and
once all are done, every fork was taken once, ended, and let go.

Memory orders. `Arch.sc` runs every step sequentially consistent.
`Arch.tso` (x86) and `Arch.arm` (arm64) give the owner a store buffer:
its stores wait there, it reads its own newest, and they reach memory
in a step of their own, in order on x86 and, on arm64, in any order but
that a release store waits for every earlier store and two stores to
one place keep their order. A seq_cst store, and the owner's
compare-and-swap, first drain the buffer (on x86 the one `xchg`; on
arm64 `stlr` then the `ldar` of `top`, which ARMv8 orders, modeled as
the stronger drain). The thieves store nothing but by compare-and-swap.
Loads are not reordered here: the design's are seq_cst (`ldar` on
arm64, ordered after one another), and `loadsSwapped` shows a thief
needs its two in order. So the model shows, within its bounds, that
the push's release store suffices on both and its monotonic slot store
needs it on arm64, and that the pop's seq_cst store, the one full
fence of an unstolen fork and join, is needed: made release, the load
of `top` passes it and a fork is taken twice.

Seeded failures (`Checks.lean` keeps each as a check that must fail):
`lastNoCas`, the last fork taken with no compare-and-swap; `blindSteal`,
a thief that claims with a plain store; `popOrd := .rel` under
`Arch.tso`, the fence missing; `pushOrd := .rlx` under `Arch.arm`;
`loadsSwapped`, a thief that reads `bottom` before `top`; `readThrough`,
a thief that writes into the record it read before its claim won.
Not modeled: the wake check after a push, the monitor, and the stolen
fork's run beyond its first and last writes into the record.
-/
import Models.Explore

namespace Models.Deque

inductive Arch where
  | sc | tso | arm
  deriving BEq, Repr

/-- The order of one of the owner's stores. -/
inductive Order where
  | rlx | rel | sc
  deriving BEq, Repr

inductive Loc where
  | bottom
  | slot (i : Nat)
  deriving BEq, Hashable, Repr, Inhabited

structure Pending where
  loc : Loc
  val : Nat
  rel : Bool
  deriving BEq, Hashable, Repr, Inhabited

structure Thief where
  pc : Nat
  t : Nat
  b : Nat
  x : Option Nat
  tries : Nat
  deriving BEq, Hashable, Repr, Inhabited

structure State where
  top : Nat
  bottom : Nat
  slots : List (Option Nat)
  /-- The owner's stores not yet in memory, oldest first. -/
  buf : List Pending
  /-- The owner: where it is, the `bottom` and `top` it read, the fork it
  names, whether it won the last one, how many forks it pushed and loop
  takes it tried, and the forks it has yet to join, newest last. -/
  pc : Nat
  ob : Nat
  ot : Nat
  of : Nat
  won : Bool
  pushed : Nat
  loops : Nat
  open_ : List Nat
  thieves : List Thief
  /-- Of each fork: how many took it, whether it ended, whether its
  record was let go. -/
  taken : List Nat
  ended : List Bool
  released : List Bool
  bad : Option String
  deriving BEq, Hashable, Repr, Inhabited

structure Config where
  size : Nat
  forks : Nat
  steals : List Nat
  /-- Takes the owner's loop tries (`popNewest`). -/
  loops : Nat := 0
  arch : Arch := .sc
  pushOrd : Order := .rel
  popOrd : Order := .sc
  /-- Broken on purpose. -/
  lastNoCas : Bool := false
  blindSteal : Bool := false
  loadsSwapped : Bool := false
  readThrough : Bool := false

def take (s : State) (g : Nat) : State := { s with taken := s.taken.modify g (· + 1) }

/-- A write into fork `g`'s record. -/
def touch (s : State) (g : Nat) (what : String) : State :=
  if s.released[g]! && s.bad.isNone then
    { s with bad := some s!"fork {g}'s record written after it was let go ({what})" }
  else s

def write (s : State) (l : Loc) (v : Nat) : State :=
  match l with
  | .bottom => { s with bottom := v }
  | .slot i => { s with slots := s.slots.set i (some v) }

/-- The owner's store: into memory, or into its buffer; a seq_cst store
waits for the buffer to drain (`none`: not enabled yet). -/
def store (c : Config) (s : State) (l : Loc) (v : Nat) (o : Order) : Option State :=
  if c.arch == .sc then some (write s l v)
  else if o == .sc then (if s.buf.isEmpty then some (write s l v) else none)
  else some { s with buf := s.buf ++ [⟨l, v, o == .rel⟩] }

/-- The owner reads its own newest store to `bottom`, else memory. -/
def ownBottom (s : State) : Nat :=
  match s.buf.reverse.find? (·.loc == .bottom) with
  | some p => p.val
  | none => s.bottom

def ownSlot (c : Config) (s : State) (i : Nat) : Option Nat :=
  match s.buf.reverse.find? (·.loc == .slot (i % c.size)) with
  | some p => some p.val
  | none => (s.slots[i % c.size]?).join

def memSlot (c : Config) (s : State) (i : Nat) : Option Nat := (s.slots[i % c.size]?).join

/-- A buffered store reaching memory. -/
def flushes (c : Config) (s : State) : List State :=
  let commit (i : Nat) : State :=
    let p := s.buf[i]!
    { write s p.loc p.val with buf := s.buf.eraseIdx i }
  match c.arch with
  | .sc => []
  | .tso => if s.buf.isEmpty then [] else [commit 0]
  | .arm => (List.range s.buf.length).filterMap fun i =>
      let p := s.buf[i]!
      let earlier := s.buf.take i
      if (i == 0 || !p.rel) && earlier.all (·.loc != p.loc) then some (commit i) else none

def done1 (s : State) : State :=
  { s with pc := 0, released := s.released.set s.of true, open_ := s.open_.dropLast }

def owner (c : Config) (s : State) : List State :=
  let opt (o : Option State) : List State := o.toList
  match s.pc with
  | 0 => (if s.pushed < c.forks then [{ s with pc := 1, of := s.pushed }] else []) ++
      (if !s.open_.isEmpty then [{ s with pc := 10, of := s.open_.getLast! }] else []) ++
      (if s.loops < c.loops then [{ s with pc := 20 }] else []) ++
      (if s.pushed == c.forks && s.open_.isEmpty && s.loops == c.loops then [{ s with pc := 99 }] else [])
  -- push(f): `b = bottom`, `t = top`; full goes to the ring's path
  | 1 => [{ s with pc := 2, ob := ownBottom s }]
  | 2 => if s.ob - s.top ≥ c.size then
           [{ take s s.of with pc := 0, ended := s.ended.set s.of true, pushed := s.pushed + 1,
                               open_ := s.open_ ++ [s.of] }]
         else [{ s with pc := 3, ot := s.top }]
  -- `slots[b] = f`, `bottom = b + 1`
  | 3 => opt ((store c s (.slot (s.ob % c.size)) s.of .rlx).map ({ · with pc := 4 }))
  | 4 => opt ((store c s .bottom (s.ob + 1) c.pushOrd).map
           fun s' => { s' with pc := 0, pushed := s.pushed + 1, open_ := s.open_ ++ [s.of] })
  -- popIf(f): `b = bottom - 1`, its slot not `f` returns false untouched
  | 10 => let b' := ownBottom s
          if b' == 0 || ownSlot c s (b' - 1) != some s.of then [{ s with pc := 30 }]
          else [{ s with pc := 11, ob := b' - 1, won := false }]
  -- `bottom = b`, `t = top`
  | 11 => opt ((store c s .bottom s.ob c.popOrd).map ({ · with pc := 12 }))
  | 12 => if s.top < s.ob then [{ take s s.of with pc := 15, ot := s.top, won := true }]
          else if s.top == s.ob then
            (if c.lastNoCas then [{ take s s.of with pc := 15, ot := s.top, won := true }]
             else [{ s with pc := 13, ot := s.top }])
          else [{ s with pc := 14, ot := s.top }]
  -- the last: race the thieves for it
  | 13 => if !s.buf.isEmpty then []
          else if s.top == s.ot then [{ take s s.of with pc := 14, top := s.ot + 1, won := true }]
          else [{ s with pc := 14 }]
  -- put `bottom` back
  | 14 => opt ((store c s .bottom (s.ob + 1) c.popOrd).map
            fun s' => { s' with pc := if s.won then 15 else 30 })
  -- run it inline, end it, let the record go
  | 15 => [{ s with pc := 16, ended := s.ended.set s.of true }]
  | 16 => [done1 s]
  -- not taken here: wait for its `ended`, then let the record go
  | 30 => if s.ended[s.of]! then [done1 s] else []
  -- popNewest(): the same for whatever is newest, run as a fiber
  | 20 => let b' := ownBottom s
          match (if b' == 0 then none else ownSlot c s (b' - 1)) with
          | none => [{ s with pc := 0, loops := s.loops + 1 }]
          | some g => [{ s with pc := 21, ob := b' - 1, of := g, won := false }]
  | 21 => opt ((store c s .bottom s.ob c.popOrd).map ({ · with pc := 22 }))
  | 22 => if s.top < s.ob then [{ take s s.of with pc := 25, ot := s.top, won := true }]
          else if s.top == s.ob then
            (if c.lastNoCas then [{ take s s.of with pc := 25, ot := s.top, won := true }]
             else [{ s with pc := 23, ot := s.top }])
          else [{ s with pc := 24, ot := s.top }]
  | 23 => if !s.buf.isEmpty then []
          else if s.top == s.ot then [{ take s s.of with pc := 24, top := s.ot + 1, won := true }]
          else [{ s with pc := 24 }]
  | 24 => opt ((store c s .bottom (s.ob + 1) c.popOrd).map
            fun s' => if s.won then { s' with pc := 25 } else { s' with pc := 0, loops := s.loops + 1 })
  | 25 => [{ s with pc := 0, loops := s.loops + 1, ended := s.ended.set s.of true }]
  | _ => []

def thief (c : Config) (s : State) (k : Nat) (th : Thief) : List State :=
  let set (th' : Thief) (s' : State := s) : State := { s' with thieves := s.thieves.set k th' }
  match th.pc with
  | 0 => if th.tries > 0 then [set { th with pc := 1, tries := th.tries - 1 }] else [set { th with pc := 99 }]
  -- `t = top`, `b = bottom` (swapped, broken on purpose)
  | 1 => if c.loadsSwapped then [set { th with pc := 2, b := s.bottom }] else [set { th with pc := 2, t := s.top }]
  | 2 =>
    let th' := if c.loadsSwapped then { th with t := s.top } else { th with b := s.bottom }
    if th'.t < th'.b then [set { th' with pc := 3 }] else [set { th' with pc := 0 }]
  -- `x = slots[t]`: the pointer only (`readThrough` writes through it)
  | 3 =>
    let x := memSlot c s th.t
    let s' := match x, c.readThrough with
      | some g, true => touch s g "the stolen bit, before the claim"
      | _, _ => s
    [set { th with pc := 4, x } s']
  -- claim it
  | 4 => if s.top == th.t || c.blindSteal then
           match th.x with
           | some g => [set { th with pc := 5 } { take s g with top := th.t + 1 }]
           | none => [set { th with pc := 0 } { s with top := th.t + 1, bad := some "a thief claimed an empty slot" }]
         else [set { th with pc := 0 }]
  -- adopt it (`TaskState.stolen`), run it, end it (`ended`, the last write)
  | 5 => [set { th with pc := 6 } (touch s th.x.get! "the stolen bit")]
  | 6 => let g := th.x.get!
         [set { th with pc := 0 } { touch s g "ended" with ended := s.ended.set g true }]
  | _ => []

def next (c : Config) (s : State) : Array State :=
  let ts := (List.range s.thieves.length).flatMap fun k => thief c s k s.thieves[k]!
  (owner c s ++ flushes c s ++ ts).toArray

/-- The owner's pcs while its take has moved `bottom` back. -/
def backPcs : List Nat := [12, 13, 14, 22, 23, 24]

def inv (_ : Config) (s : State) : Option String :=
  let b := ownBottom s
  if let some e := s.bad then some e
  else if s.taken.any (· > 1) then some "a fork was taken twice"
  else if s.top > b + 1 || (s.top > b && !backPcs.contains s.pc) then some "top passed bottom"
  else none

def stuck (c : Config) (s : State) : Option String :=
  if (List.range c.forks).all (fun g => s.taken[g]! == 1 && s.ended[g]! && s.released[g]!) && s.buf.isEmpty then none
  else some "a fork was not taken once, ended and let go"

def done (s : State) : Bool := s.pc == 99 && s.buf.isEmpty && s.thieves.all (·.pc == 99)

def system (c : Config) : System State where
  init := { top := 0, bottom := 0, slots := List.replicate c.size none, buf := [],
            pc := 0, ob := 0, ot := 0, of := 0, won := false, pushed := 0, loops := 0, open_ := [],
            thieves := c.steals.map fun n => ⟨0, 0, 0, none, n⟩,
            taken := List.replicate c.forks 0, ended := List.replicate c.forks false,
            released := List.replicate c.forks false, bad := none }
  next := next c
  inv := inv c
  stuck := stuck c
  done := done

end Models.Deque
