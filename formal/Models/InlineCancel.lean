/-
A cancel of a task run inline (docs/history/records/2026-11/
free-fork-join/runtime.md §2, "Cancel: a fiber bit and the parent
links"), before the Zig is written.

One physical fiber runs a chain: level 0 is its own task; level i + 1
is a task that level i's join runs inline on the same stack (`runHere`),
whose record lies in level i's frame and whose `Fiber.host` names the
physical fiber. Each level's task has its cancel flag
(`Control.canceled`). The fiber's steps: start a level (a fork joined
inline: its maker writes the record, the flag cleared, `host` set), end
the innermost level (its record let go, so a later fork may use the
frame again), and wait at the innermost level in a wait a cancel may
end: `beginWait`, then, while a level runs inline and
`Fiber.cancel_below` is set, `passCancelDown` (clear the bit, then from
the outermost level in, cancel each level whose waiter is canceled),
then the innermost level's own flag, then commit and sleep. A woken
wait begins again.

A canceler (a task's isolate stopping, `Isolate.stop`) cancels one
level's task: under the isolate's lock, which keeps that task's record
listed and so its frame live (FrameRecord.lean), it sets the flag,
reads `host`, sets the bit on that fiber, and reads its wait word,
ending a wait a cancel may end (`interruptForCancel`). Each step is one
sequentially consistent access, as the design's are (the canceler
stores the flag, then the bit, then reads the word; the waiter begins
its wait, then reads the bit and its flag), so any order of steps is a
run. The wait word is Wait.lean's, reduced to its states.

Checked:
- no lost cancel: a cancel of any live level never leaves the fiber
  asleep (no step enabled, the canceled level still live);
- a wait given up for a cancel finds that level's task and every one
  inside it canceled;
- no thread but the fiber reads a level's record but the canceled
  task's, which the lock keeps: no access to a record after its frame
  was used again by a later fork.

Bounds: levels up to `depth` inline over the fiber's own task, `starts`
levels started in all (so a frame is used again), `waits` waits, one
cancel. Seeded failures: `bitAfterWord` (the bit set after the word is
read), `noHost` (the bit and the wake sent to the inline task's own
`Fiber`, never run), `noPassDown` (a wait that reads only its own
level's flag), each a lost cancel; and `cancelerWalks` (the canceler
walks the chain itself, setting the flags below, the chain-wide design
the 11-15 semantics round rejected), which reads a record a later fork
reused.
-/
import Models.Explore

namespace Models.InlineCancel

structure Config where
  depth : Nat := 2
  starts : Nat := 3
  waits : Nat := 2
  /-- Broken on purpose. -/
  bitAfterWord : Bool := false
  noHost : Bool := false
  noPassDown : Bool := false
  cancelerWalks : Bool := false

/-- The wait word: none, about to sleep, asleep, woken. -/
abbrev none_ : Nat := 0
abbrev about : Nat := 1
abbrev asleep : Nat := 2
abbrev woken : Nat := 3

structure State where
  live : Nat
  /-- Of each level: its record's generation (a new fork in its frame
  makes a new one) and its task's cancel flag. -/
  gen : List Nat
  flags : List Bool
  bit : Bool
  word : Nat
  /-- The fiber: 0 runs, 1 began a wait, 2 clears the bit, 3 passes the
  cancel to level `fi`, 4 reads its flag, 5 commits, 6 asleep, 99 done. -/
  fpc : Nat
  fi : Nat
  starts : Nat
  waits : Nat
  /-- The canceler: 0 before, 1 the flag, 2 `host`, 3 and 4 the bit and
  the word, 5 lets the lock go, 6 and 7 the walk, 99 done. -/
  cpc : Nat
  ck : Nat
  cgen : Nat
  cj : Nat
  cjgen : Nat
  /-- The level whose record the canceler's lock keeps. -/
  pinned : Option Nat
  bad : Option String
  deriving BEq, Hashable, Repr, Inhabited

def fiber (c : Config) (s : State) : List State :=
  match s.fpc with
  | 0 =>
    (if s.live < c.depth && s.starts < c.starts then
       let i := s.live + 1
       -- `waitInto`'s first `canceledHere()`: a canceled waiter cancels
       -- the task before it runs it
       [{ s with live := i, gen := s.gen.modify i (· + 1), flags := s.flags.set i s.flags[s.live]!,
                 starts := s.starts + 1 }]
     else []) ++
    (if s.live ≥ 1 && s.pinned != some s.live then [{ s with live := s.live - 1 }] else []) ++
    (if s.waits < c.waits then [{ s with fpc := 1, word := about, waits := s.waits + 1 }] else []) ++
    (if s.live == 0 then [{ s with fpc := 99 }] else [])
  -- the bit, while a level runs inline
  | 1 => if s.bit && s.live ≥ 1 && !c.noPassDown then [{ s with fpc := 2 }] else [{ s with fpc := 4 }]
  | 2 => [{ s with fpc := 3, bit := false, fi := 1 }]
  | 3 =>
    let f := s.flags[s.fi]! || s.flags[s.fi - 1]!
    [{ s with fpc := if s.fi ≥ s.live then 4 else 3, fi := s.fi + 1, flags := s.flags.set s.fi f }]
  -- its own level's flag: give the wait up for the cancel
  | 4 => if s.flags[s.live]! then
           let below := (List.range (s.live + 1)).all fun i => i < s.ck || s.flags[i]!
           let s' := if s.cpc ≥ 2 && s.gen[s.ck]! == s.cgen && s.ck ≤ s.live && !below && s.bad.isNone then
             { s with bad := some "a wait given up for a cancel left a level inside the canceled one uncanceled" } else s
           [{ s' with fpc := 0, word := none_ }]
         else [{ s with fpc := 5 }]
  -- commit, or, woken first, begin again
  | 5 => if s.word == about then [{ s with fpc := 6, word := asleep }]
         else [{ s with fpc := 1, word := about }]
  | 6 => if s.word == woken then [{ s with fpc := 1, word := about }] else []
  | _ => []

/-- A canceler's access of level `k`'s record. -/
def touch (s : State) (k g : Nat) (what : String) : State :=
  if (k > s.live || s.gen[k]! != g) && s.bad.isNone then
    { s with bad := some s!"the canceler's {what} reached a record a later fork reused" }
  else s

def canceler (c : Config) (s : State) : List State :=
  let word (s : State) : State :=
    if !c.noHost && (s.word == about || s.word == asleep) then { s with word := woken } else s
  let bit (s : State) : State := if c.noHost then s else { s with bit := true }
  match s.cpc with
  | 0 => (List.range (s.live + 1)).map fun k =>
      { s with cpc := 1, ck := k, cgen := s.gen[k]!, pinned := if k ≥ 1 then some k else none }
  | 1 => [{ touch s s.ck s.cgen "flag" with cpc := 2, flags := s.flags.set s.ck true }]
  | 2 => [{ touch s s.ck s.cgen "read of host" with cpc := 3 }]
  | 3 => [{ (if c.bitAfterWord then word s else bit s) with cpc := 4 }]
  | 4 => [{ (if c.bitAfterWord then bit s else word s) with cpc := 5 }]
  | 5 => [{ s with cpc := if c.cancelerWalks then 6 else 99, pinned := none }]
  -- the chain-wide walk: `inline_top`, then each record's parent link
  | 6 => if s.live ≤ s.ck then [{ s with cpc := 99 }]
         else [{ s with cpc := 7, cj := s.live, cjgen := s.gen[s.live]! }]
  | 7 =>
    let s1 := touch s s.cj s.cjgen "walk"
    let s2 := { s1 with flags := s1.flags.set s.cj true }
    if s.cj - 1 ≤ s.ck then [{ s2 with cpc := 99 }]
    else [{ s2 with cj := s.cj - 1, cjgen := s.gen[s.cj - 1]! }]
  | _ => []

def next (c : Config) (s : State) : Array State := (fiber c s ++ canceler c s).toArray

/-- A cancel delivered, of a level still live. -/
def pending (s : State) : Bool := s.cpc == 99 && s.ck ≤ s.live && s.gen[s.ck]! == s.cgen

def inv (s : State) : Option String := s.bad

def stuck (s : State) : Option String :=
  if s.fpc == 6 && pending s then some "a cancel was lost: the fiber sleeps, the canceled level live" else none

def done (s : State) : Bool := s.cpc == 99 && (s.fpc == 99 || (s.fpc == 6 && !pending s))

def system (c : Config) : System State where
  init := { live := 0, gen := List.replicate (c.depth + 1) 0, flags := List.replicate (c.depth + 1) false,
            bit := false, word := none_, fpc := 0, fi := 0, starts := 0, waits := 0,
            cpc := 0, ck := 0, cgen := 0, cj := 0, cjgen := 0, pinned := none, bad := none }
  next := next c
  inv := inv
  stuck := stuck
  done := done

end Models.InlineCancel
