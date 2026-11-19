/-
A task record in its maker's frame, and who may let it go
(docs/history/records/2026-11/free-fork-join/language.md §8, "Unsound
as written"), before the Zig is written. The parties:

- the maker: it forks a task whose record lies in its frame, listed in
  its isolate's list (`Control.made`), and runs on; then it joins the
  task (claiming it to run inline, else waiting for `Done`'s `ended`),
  after which its frame is used again, and it ends (off the list); or it
  panics first, and its stack is kept by the isolate (`Isolate.kept`);
- a thief that took the fork: it runs it, then its last accesses of the
  record, as `Control.finish` and the worker's end of the fiber make
  them: the isolate's `remove` (the record's list links, and the
  isolate), `done`'s store, `wakeup`'s load, `endStack`'s read of the
  record's `Fiber`, `Done.finish`'s `ending` and `ended`;
- the isolate's stopper (`Isolate.stop`, then `giveBack` in
  `isolateWith`): once a panic reached the isolate, it cancels every
  task listed, waits until none is, gives back the stacks it kept,
  which another task may take at once, and returns, its record gone.

Each step is one access, or one step under the isolate's lock.

Checked: no access to the record after its memory was let go (the
maker's frame used again, or the kept stack given back), and none to
the isolate after the stopper returned; and every run ends.

The orders (`Order`):
- `today`: `Control.finish` as it is (tasks.zig): off the isolate's
  list first, then the record's last writes. A heap record is not let
  go by the isolate, so this is sound for it; for a frame record whose
  maker panicked, the stopper gives the stack back between the thief's
  `remove` and its later writes. It must fail.
- `removeLast`: the remove moved after `Done`'s last store, the first
  fix language.md offers. When the maker lives, it reads `ended`, its
  frame is used again, and the thief's remove then writes the record's
  list links, and, once the isolate's caller returns, the isolate. It
  must fail too.
- `snapshot`: the stopper notes the records listed when it stops and,
  once the list is empty, waits for each one's `ended`, the thief
  keeping today's order. When a panic elsewhere stops the isolate while
  the maker lives, the maker reads `ended` and its frame is used again
  before the stopper reads the record. It must fail.
- `fixed`: the thief's last access of a frame record is `ended`; it
  never touches the list or the isolate. Whoever reads `ended` takes the
  record off the isolate's list, under its lock: the maker at its join,
  or, once a panic stopped the isolate, the stopper, which reads the
  record only while it is listed. A record listed is one whose frame is
  live (its maker's, or a stack the isolate keeps), so the release, the
  waiter's read of `ended` or the stopper's give-back, comes after the
  record's last access. It must pass.

Bounds: one maker, one fork, one thief, one isolate; the maker may
panic before its join (`mayPanic`), and a panic elsewhere may stop the
isolate while the maker lives (`otherPanic`). How the stopper learns of
an end it waits for (a wake, or a poll) is not modeled: its wait is a
step enabled once the end is there.
-/
import Models.Explore

namespace Models.FrameRecord

inductive Order where
  | today | removeLast | snapshot | fixed
  deriving BEq, Repr

structure Config where
  order : Order
  mayPanic : Bool := true
  otherPanic : Bool := false

/-- The thief's accesses of the record, in its order. -/
inductive Act where
  | remove | done | wakeup | endStack | ending | ended
  deriving BEq, Repr, Inhabited

def acts : Order → List Act
  | .removeLast => [.done, .wakeup, .endStack, .ending, .ended, .remove]
  | .fixed => [.done, .wakeup, .endStack, .ending, .ended]
  | _ => [.remove, .done, .wakeup, .endStack, .ending, .ended]

def Act.name : Act → String
  | .remove => "the isolate's remove"
  | .done => "done's store"
  | .wakeup => "wakeup's load"
  | .endStack => "endStack's read of its Fiber"
  | .ending => "Done's ending"
  | .ended => "Done's ended"

structure State where
  /-- The maker: 0 forked, 1 joins, 2 runs it inline, 4 waits for
  `ended`, 5 takes it off the list, 6 its frame used again, 7 ends, 8
  ended, 9 panicked. -/
  mp : Nat
  /-- The thief: 0 before its claim, 1 + i at its i-th access, 99 done. -/
  th : Nat
  /-- The stopper: 0 before a stop, 1 waiting, 5 waiting for the noted
  record's `ended`, 2 gives back, 3 returns, 99 returned. -/
  st : Nat
  claimed : Bool
  byThief : Bool
  /-- The record, and the maker's own task, in the isolate's list. -/
  listed : Bool
  mListed : Bool
  ended : Bool
  stopping : Bool
  kept : Bool
  noted : Bool
  /-- The record's memory let go; the isolate gone. -/
  gone : Bool
  isoGone : Bool
  bad : Option String
  deriving BEq, Hashable, Repr, Inhabited

/-- An access of the record. -/
def touch (s : State) (who : String) : State :=
  if s.gone && s.bad.isNone then { s with bad := some s!"{who} after the record's memory was let go" } else s

def touchIso (s : State) (who : String) : State :=
  if s.isoGone && s.bad.isNone then { s with bad := some s!"{who} after the isolate was gone" } else s

def maker (c : Config) (s : State) : List State :=
  match s.mp with
  | 0 => [{ s with mp := 1 }] ++
      (if c.mayPanic then [{ s with mp := 9, kept := true, mListed := false }] else [])
  -- claim it to run inline, else wait for its end
  | 1 => if s.claimed then [{ s with mp := 4 }] else [{ s with mp := 2, claimed := true }]
  -- run inline: its `Control.finish` and end, by the maker, in its own frame
  | 2 => [{ s with mp := 6, listed := false, ended := true }]
  | 4 => if s.ended then [{ touch s "the maker's read of ended" with mp := if c.order == .fixed then 5 else 6 }] else []
  | 5 => [{ touch (touchIso s "the maker's remove") "the maker's remove" with mp := 6, listed := false }]
  | 6 => [{ s with mp := 7, gone := true }]
  | 7 => [{ touchIso s "the maker's own end" with mp := 8, mListed := false }]
  | _ => []

def thief (c : Config) (s : State) : List State :=
  let steps := acts c.order
  if s.th == 0 then
    if !s.claimed then [{ s with th := 1, claimed := true, byThief := true }]
    else if !s.byThief then [{ s with th := 99 }] else []
  else if s.th ≤ steps.length then
    let a := steps[s.th - 1]!
    let who := s!"the thief's {a.name}"
    let s1 := touch s who
    let s2 := match a with
      | .remove => { touchIso s1 who with listed := false }
      | .ended => { s1 with ended := true }
      | _ => s1
    [{ s2 with th := if s.th == steps.length then 99 else s.th + 1 }]
  else []

def stopper (c : Config) (s : State) : List State :=
  match s.st with
  | 0 =>
    let stop : State :=
      let s1 := if s.listed then touch s "the stopper's cancel" else s
      { s1 with st := 1, stopping := true, noted := c.order == .snapshot && s.listed }
    (if s.mp == 9 then [stop] else []) ++
    (if c.otherPanic && s.mp != 9 then [stop] else []) ++
    (if s.mp == 8 then [{ s with st := 3 }] else [])
  | 1 =>
    (if c.order == .fixed && s.listed && s.ended then
       [{ touch s "the stopper's remove" with listed := false }] else []) ++
    (if !s.listed && !s.mListed then [{ s with st := if s.noted then 5 else 2 }] else [])
  | 5 => if s.ended then [{ touch s "the stopper's read of ended" with st := 2 }] else []
  | 2 => [{ s with st := 3, gone := s.gone || s.kept }]
  | 3 => [{ s with st := 99, isoGone := true }]
  | _ => []

def next (c : Config) (s : State) : Array State :=
  (maker c s ++ thief c s ++ stopper c s).toArray

def inv (s : State) : Option String := s.bad

def done (s : State) : Bool := (s.mp == 8 || s.mp == 9) && s.th == 99 && s.st == 99

def system (c : Config) : System State where
  init := { mp := 0, th := 0, st := 0, claimed := false, byThief := false, listed := true,
            mListed := true, ended := false, stopping := false, kept := false, noted := false,
            gone := false, isoGone := false, bad := none }
  next := next c
  inv := inv
  stuck := fun _ => none
  done := done

end Models.FrameRecord
