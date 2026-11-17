/-
How workers sleep and are woken (src/sched.zig, `loop`, `next`,
`search`, `workPending`, `spread`, `notify`, `notifyNew`, `sleep`,
`waitWoken`, `wakeHome`, `Batch`).

Workers run fibers, look for more (their run-next slots, their ring,
their pinned queue, the global queue, then, counted in `searching`,
stealing half of another ring, the global queue, and another worker's
slot), and sleep when they find none: listed in `sleepers`, then, after
a last look, in their poller until kicked. The last searcher to find a
fiber wakes another only when other work waits (`workPending`: the
global queue, another worker's ring or slots), and a worker about to
run a fiber wakes one when its own slots or ring still hold work and
none searches (`spread`), which covers what a thief stole beyond the
fiber it runs. A fiber that runs may make work: `wake` (into its
worker's ring, then `notifyNew`), `wakeLast` (into the ring, then
`notify`), or `wakeHome` (into another worker's pinned queue, kicking
that worker when its `idle` flag is set). A thread outside the workers
may make work too: into the global queue, then `notifyNew`, or into a
worker's pinned queue, as `wakeHome` does. A worker's poller may make
fibers ready, waking no one: as it sleeps (`serviceAll`, a wait in its
poller), one batch (`Batch`) for the whole sleep, its first into the
worker's slot and the rest into its ring; at its loop's turn to look
(`service`), a batch of its own; in the wait for a waker's kick after
a last look, each into a slot.

Each step is one atomic instruction of the Zig code, sequentially
consistent, as every one of these is there; a step under a spin lock
(`Sleepers`, `Global`) is one step, and a ring's push, pop and steal
are each one step (the ring's own protocol is `Ring.lean`). A fiber
that runs either ends or runs on forever, never yielding: the worst
case, where work in its worker's ring must be stolen.

Checked:
- no lost wakeup: in every state where no step is enabled, no worker
  waits in its poller while there is work it could take (in any ring,
  any slot, the global queue, or its own pinned queue);
- from every state reached, some run reaches such a state, so no worker
  loops for ever looking at work it cannot take;
- `searching` counts exactly the workers searching, and `sleepers`
  holds each worker at most once.
A fiber left in a slot while its worker runs another, with the
searcher that suppressed `spread`'s wake already past it, is seen by
no last look (`hasWork` reads no slot): only the monitor's stop
(`Config.monitor`) takes it on. Not modeled: a running fiber's fill of
its slot (covered by `waiting` and the yield checks), the slot's streak
limit and its 3 µs wait, timers apart from the poller's batches,
`stopping`, and which poller a look reads: a holder that takes a stuck
worker's events (`checkBell`) makes their fibers ready in its own batch,
as `events` lets any look do, and a holder's bell takes no event, so
whom it rings bounds latency, not a lost wake.
-/
import Models.Explore

namespace Models.Sleep

inductive Pc where
  /-- `next`: its slots (after `service` and the global queue, at the
  turn that looks at its poller), its ring, its pinned queue, the global
  queue. -/
  | slot | tick | lifo | ring | pinned | global
  /-- `search`: count itself as searching, then steal from each other
  worker's ring in turn, then the global queue, then each other worker's
  slot (`stealNext`). -/
  | search | count | steal (k : Nat) | stealGlobal | stealNext (k : Nat)
  /-- Found a fiber: stop searching; if it was the last, `notify` when
  `workPending` finds the global queue, or worker `k`'s ring or slot,
  holding work. -/
  | found | pendGlobal | pendRing (k : Nat) | pendSlot (k : Nat)
  /-- About to run it: `notify` when its own slot or ring holds work. -/
  | spread
  /-- Found none: stop searching, then sleep. -/
  | none
  /-- The fiber runs: it makes work, ends, or runs on. -/
  | run | spin
  /-- `sleep`: clear `woken`, set `idle`, list itself, look last. -/
  | clearWoken | setIdle | list | lookSearching | lookGlobal | lookRing (k : Nat)
  | remove | recount | unlist
  /-- The loop of `sleep`: `woken`, its own work, the poller. -/
  | checkWoken | own (k : Nat) | poll | after (k : Nat)
  /-- `waitWoken`. -/
  | waitWoken | waitPoll
  | leave
  /-- `notifyNew` and `notify`, then back to `ret`. -/
  | newSearching | newSleepers | nSearching | nSleepers | nPop | nCount (v : Nat) | nWoken (v : Nat)
  | nKick (v : Nat)
  /-- `wakeHome`: look at `idle` of `v`, then kick it. -/
  | homeIdle (v : Nat) | homeKick (v : Nat)
  | done
  deriving BEq, Hashable, Repr, Inhabited

/-- Where the fibers a poller makes ready go (`Batch`): with no batch
open, each to a slot; in one, the first to a slot and the rest to the
ring. -/
inductive Batch where
  | none | first | rest
  deriving BEq, Hashable, Repr, Inhabited

structure Worker where
  pc : Pc
  /-- Where `notify` goes back to. -/
  ret : Pc
  searching : Bool
  woken : Bool
  idle : Bool
  /-- A kick of its poller not yet taken by a poll. -/
  kicked : Bool
  /-- Fibers in its run-next slots. -/
  slot : Nat
  ring : Nat
  pinned : Nat
  batch : Batch
  /-- The worker it began stealing from. -/
  start : Nat
  /-- Its fiber may make work (with `Config.firstMakes`, only the first
  fiber of the first worker). -/
  maker : Bool
  deriving BEq, Hashable, Inhabited

instance : Repr Worker where
  reprPrec w _ := repr w.pc ++ (if w.searching then " searching" else "") ++
    (if w.woken then " woken" else "") ++ (if w.idle then " idle" else "") ++
    (if w.kicked then " kicked" else "") ++ s!" slot {w.slot} ring {w.ring} pinned {w.pinned}"

structure State where
  workers : List Worker
  searching : Nat
  sleepers : List Nat
  global : Nat
  /-- Work left to make, by fibers, pollers and the thread outside. -/
  budget : Nat
  /-- The thread outside the workers. -/
  outside : Pc
  deriving BEq, Hashable, Inhabited

instance : Repr State where
  reprPrec s _ := Std.Format.joinSep (s.workers.map repr) " | " ++
    s!" || searching {s.searching} sleepers {s.sleepers} global {s.global} budget {s.budget} outside " ++
    repr s.outside

/-- What a run may do: how many workers, how much work is made, and by
which ways. -/
structure Config where
  workers : Nat
  budget : Nat
  /-- Fibers make work into their ring (`wake`, `wakeLast`). -/
  ring : Bool := false
  /-- Fibers make work into another worker's pinned queue (`wakeHome`). -/
  home : Bool := false
  /-- The thread outside makes work into the global queue. -/
  global : Bool := false
  /-- The thread outside makes work into a pinned queue. -/
  outsideHome : Bool := false
  /-- A worker that finds work in its last look before sleeping counts
  itself as searching again, as `sleep` in src/sched.zig does. -/
  relook : Bool := false
  /-- Every worker but the first begins asleep in its poller, listed in
  `sleepers`, rather than looking for work. -/
  asleep : Bool := false
  /-- Only the first fiber, on the first worker, makes work. -/
  firstMakes : Bool := false
  /-- A worker's poller hands it batches of ready fibers. -/
  batch : Bool := false
  /-- The last look before sleeping reads every worker's slots too, which
  `sched.hasWork` does not. -/
  lookSlots : Bool := false
  /-- The monitor stops a fiber that runs on while its worker's slots or
  ring hold work. -/
  monitor : Bool := false
  /-- Broken on purpose, to show the checks find each: `sleep` skips its
  last look for work, `wakeHome` never kicks, a worker about to run a
  fiber never `spread`s, or the last searcher wakes none. -/
  noLastLook : Bool := false
  noKick : Bool := false
  noSpread : Bool := false
  noPending : Bool := false

def State.w (s : State) (i : Nat) : Worker := s.workers[i]!

def State.setW (s : State) (i : Nat) (f : Worker → Worker) : State :=
  { s with workers := s.workers.modify i f }

def State.go (s : State) (i : Nat) (pc : Pc) : State := s.setW i fun w => { w with pc }

/-- `notify`, called from `ret`. -/
def notify (s : State) (i : Nat) (ret : Pc) : State := s.setW i fun w => { w with pc := .nSearching, ret }

def notifyNew (s : State) (i : Nat) (ret : Pc) : State := s.setW i fun w => { w with pc := .newSearching, ret }

/-- Worker `i`'s poller makes `m` fibers ready, for each `m` the budget
allows, all queued with no `notify` (`wakeIn`): with no batch open, each
into a slot; in a batch, the first into a slot and the rest into the
ring. -/
def events (c : Config) (s : State) (i : Nat) (ret : Pc) : List State :=
  if !c.batch then [] else
  (List.range s.budget).map fun j =>
    let m := j + 1
    ({ s with budget := s.budget - m }.setW i fun w =>
      match w.batch with
      | .none => { w with slot := w.slot + m }
      | .first => { w with slot := w.slot + 1, ring := w.ring + (m - 1), batch := .rest }
      | .rest => { w with ring := w.ring + m }).go i ret

/-- `service` at the turn of `next` that looks at the poller: a batch of
its own. -/
def service (c : Config) (s : State) (i : Nat) : List State :=
  (events c (s.setW i fun w => { w with batch := .first }) i .tick).map fun s => s.setW i fun w => { w with batch := .none }

/-- Worker `i` begins the loop of `sleep`, a batch open. -/
def loopSleep (s : State) (i : Nat) : State := (s.setW i fun w => { w with batch := .first }).go i .checkWoken

/-- The look at worker `i`'s own slots in `next`. -/
def lifo (s : State) (i : Nat) : List State :=
  if (s.w i).slot > 0 then [(s.setW i fun w => { w with slot := w.slot - 1 }).go i .found] else [s.go i .ring]

/-- `spread`, as worker `i` switches to the fiber it found: `notify`
when its own slot or ring still holds work. -/
def spread (c : Config) (s : State) (i : Nat) : State :=
  let w := s.w i
  if (w.slot > 0 || w.ring > 0) && !c.noSpread then notify s i .run else s.go i .run

/-- The first other worker from `k` on, for `workPending`. -/
def nextOther (i k : Nat) : Nat := if k == i then k + 1 else k

/-- What the fiber running on worker `i` can do: end, run on for ever, or
make work. -/
def runs (c : Config) (s : State) (i : Nat) : List State :=
  let w := s.w i
  let others := (List.range c.workers).filter (· != i)
  [(s.setW i fun w => { w with maker := !c.firstMakes && w.maker }).go i .slot, s.go i .spin] ++
  (if s.budget == 0 || !w.maker then [] else
    let s' := { s with budget := s.budget - 1 }
    let mine := s'.setW i fun w => { w with ring := w.ring + 1 }
    (if c.ring then [notifyNew mine i .run, notify mine i .run] else []) ++
    if c.home then others.map fun v => (s'.setW v fun x => { x with pinned := x.pinned + 1 }).go i (.homeIdle v)
    else [])

/-- What thread `i` (a worker) can do. -/
def worker (c : Config) (s : State) (i : Nat) : List State :=
  let n := c.workers
  let w := s.w i
  let others := (List.range n).filter (· != i)
  match w.pc with
  | .slot => lifo s i ++ service c s i
  | .tick => if s.global > 0 then [{ s with global := s.global - 1 }.go i .found] else [s.go i .lifo]
  | .lifo => lifo s i
  | .ring => if w.ring > 0 then [(s.setW i fun w => { w with ring := w.ring - 1 }).go i .found] else [s.go i .pinned]
  | .pinned => if w.pinned > 0 then [(s.setW i fun w => { w with pinned := w.pinned - 1 }).go i .found] else [s.go i .global]
  | .global => if s.global > 0 then [{ s with global := s.global - 1 }.go i .found] else [s.go i .search]
  | .search =>
    if n < 2 then [s.go i .none]
    else if w.searching then others.map fun v => s.setW i fun w => { w with pc := .steal 0, start := v }
    else if 2 * s.searching >= n then [s.go i .none]
    else [s.go i .count]
  | .count =>
    others.map fun v => { s with searching := s.searching + 1 }.setW i fun w =>
      { w with pc := .steal 0, start := v, searching := true }
  | .steal k =>
    if k + 1 >= n then [s.go i .stealGlobal]
    else
      -- The others in turn from `start`.
      let v := others[(others.idxOf w.start + k) % others.length]!
      let r := (s.w v).ring
      if r > 0 then
        let m := r - r / 2
        [((s.setW v fun x => { x with ring := r - m }).setW i fun x => { x with ring := x.ring + (m - 1) }).go i .found]
      else [s.go i (.steal (k + 1))]
  | .stealGlobal => if s.global > 0 then [{ s with global := s.global - 1 }.go i .found] else [s.go i (.stealNext 0)]
  | .stealNext k =>
    if k + 1 >= n then [s.go i .none]
    else
      let v := others[(others.idxOf w.start + k) % others.length]!
      if (s.w v).slot > 0 then
        [((s.setW v fun x => { x with slot := x.slot - 1 })).go i .found]
      else [s.go i (.stealNext (k + 1))]
  | .found =>
    if w.searching then
      let s' := { s with searching := s.searching - 1 }.setW i fun w => { w with searching := false }
      [s'.go i (if s.searching == 1 && !c.noPending then .pendGlobal else .spread)]
    -- Nothing shared changes here: straight on to `spread`.
    else [spread c s i]
  -- workPending: the global queue, then each other worker's ring and slots
  | .pendGlobal => [if s.global > 0 then notify s i .spread else s.go i (.pendRing (nextOther i 0))]
  | .pendRing k =>
    if k >= n then [s.go i .spread]
    else [if (s.w k).ring > 0 then notify s i .spread else s.go i (.pendSlot k)]
  | .pendSlot k => [if (s.w k).slot > 0 then notify s i .spread else s.go i (.pendRing (nextOther i (k + 1)))]
  | .spread => [spread c s i]
  | .none =>
    if w.searching then
      [({ s with searching := s.searching - 1 }.setW i fun w => { w with searching := false }).go i .clearWoken]
    else [s.go i .clearWoken]
  | .run => runs c s i
  -- The monitor signals a worker whose fiber runs on while its own
  -- slots or ring hold work: the fiber stops and goes to the global
  -- queue (`afterPreempt`, `behind`), and `notify`.
  | .spin =>
    if c.monitor && (w.slot > 0 || w.ring > 0) then [notify { s with global := s.global + 1 } i .slot] else []
  | .homeIdle v => [s.go i (if (s.w v).idle && !c.noKick then .homeKick v else .run)]
  | .homeKick v => [(s.setW v fun x => { x with kicked := true }).go i .run]
  -- sleep
  | .clearWoken => [(s.setW i fun w => { w with woken := false }).go i .setIdle]
  | .setIdle => [(s.setW i fun w => { w with idle := true }).go i .list]
  | .list => [{ s with sleepers := i :: s.sleepers }.go i .lookSearching]
  | .lookSearching => [if s.searching != 0 || c.noLastLook then loopSleep s i else s.go i .lookGlobal]
  | .lookGlobal => [s.go i (if s.global != 0 then .remove else .lookRing 0)]
  -- `hasWork`: the global queue and every ring, not the slots
  | .lookRing k =>
    if k >= n then [loopSleep s i]
    else [s.go i (if (s.w k).ring != 0 || (c.lookSlots && (s.w k).slot != 0) then .remove else .lookRing (k + 1))]
  | .remove =>
    if s.sleepers.contains i then [{ s with sleepers := s.sleepers.erase i }.go i (if c.relook then .recount else .leave)]
    else [s.go i .waitWoken]
  -- With `relook`: a worker that found work in its last look counts
  -- itself as searching again, so finding it notifies.
  -- The loop of `sleep` found its own work: off the list, or wait for
  -- the kick of the waker that took it off.
  | .unlist =>
    if s.sleepers.contains i then [{ s with sleepers := s.sleepers.erase i }.go i .leave]
    else [s.go i .waitWoken]
  | .recount =>
    [({ s with searching := s.searching + 1 }.setW i fun w => { w with searching := true }).go i .leave]
  | .checkWoken => [s.go i (if w.woken then .leave else .own 0)]
  -- `serviceAll`, then `hasOwnWork`: its slots and ring (which only it
  -- fills), its pinned queue, the global queue
  | .own k =>
    let has := match k with | 0 => w.slot != 0 || w.ring != 0 | 1 => w.pinned != 0 | _ => s.global != 0
    (if has then [s.go i .unlist] else [s.go i (if k >= 2 then .poll else .own (k + 1))]) ++
    (if k == 0 then events c s i (.own 0) else [])
  -- Its poller: a kick, or events that make fibers ready (`sleepIn`).
  | .poll =>
    (if w.kicked then [(s.setW i fun w => { w with kicked := false }).go i (.after 0)] else []) ++
    events c s i (.after 0)
  | .after k =>
    let has := match k with | 0 => w.slot != 0 || w.ring != 0 | 1 => w.pinned != 0 | _ => s.global != 0
    if has then [s.go i .unlist] else [s.go i (if k >= 2 then .checkWoken else .after (k + 1))]
  | .waitWoken => [s.go i (if w.woken then .leave else .waitPoll)]
  | .waitPoll =>
    (if w.kicked then [(s.setW i fun w => { w with kicked := false }).go i .waitWoken] else []) ++
    events c s i .waitWoken
  | .leave => [(s.setW i fun w => { w with idle := false, batch := .none }).go i .slot]
  -- notifyNew: wake no one when no worker searches or sleeps
  | .newSearching => [s.go i (if s.searching != 0 then .nSearching else .newSleepers)]
  | .newSleepers => [s.go i (if s.sleepers.length == 0 then w.ret else .nSearching)]
  -- notify
  | .nSearching => [s.go i (if s.searching != 0 then w.ret else .nSleepers)]
  | .nSleepers => [s.go i (if s.sleepers.length == 0 then w.ret else .nPop)]
  | .nPop => match s.sleepers with
    | [] => [s.go i w.ret]
    | v :: rest => [{ s with sleepers := rest }.go i (.nCount v)]
  | .nCount v =>
    [({ s with searching := s.searching + 1 }.setW v fun x => { x with searching := true }).go i (.nWoken v)]
  | .nWoken v => [(s.setW v fun x => { x with woken := true }).go i (.nKick v)]
  | .nKick v => [(s.setW v fun x => { x with kicked := true }).go i w.ret]
  | _ => []

/-- What the thread outside the workers can do: make work into the
global queue, or into a worker's pinned queue, or stop. -/
def outside (c : Config) (s : State) : List State :=
  match s.outside with
  | .run =>
    { s with outside := .done } ::
    (if s.budget == 0 then [] else
      let s' := { s with budget := s.budget - 1 }
      (if c.global then [{ s' with global := s.global + 1, outside := .newSearching }] else []) ++
      if c.outsideHome then (List.range c.workers).map fun v =>
        { s'.setW v (fun x => { x with pinned := x.pinned + 1 }) with outside := .homeIdle v }
      else [])
  | .homeIdle v => [{ s with outside := if (s.w v).idle && !c.noKick then .homeKick v else .run }]
  | .homeKick v => [{ s.setW v (fun x => { x with kicked := true }) with outside := .run }]
  | .newSearching => [{ s with outside := if s.searching != 0 then .nSearching else .newSleepers }]
  | .newSleepers => [{ s with outside := if s.sleepers.length == 0 then .run else .nSearching }]
  | .nSearching => [{ s with outside := if s.searching != 0 then .run else .nSleepers }]
  | .nSleepers => [{ s with outside := if s.sleepers.length == 0 then .run else .nPop }]
  | .nPop => match s.sleepers with
    | [] => [{ s with outside := .run }]
    | v :: rest => [{ s with sleepers := rest, outside := .nCount v }]
  | .nCount v =>
    [{ { s with searching := s.searching + 1 }.setW v fun x => { x with searching := true } with outside := .nWoken v }]
  | .nWoken v => [{ s.setW v (fun x => { x with woken := true }) with outside := .nKick v }]
  | .nKick v => [{ s.setW v (fun x => { x with kicked := true }) with outside := .run }]
  | _ => []

def next (c : Config) (s : State) : Array State :=
  ((List.range c.workers).flatMap (worker c s) ++ (if c.global || c.outsideHome then outside c s else [])).toArray

def asleep (w : Worker) : Bool := (w.pc == .poll || w.pc == .waitPoll) && !w.kicked

def inv (n : Nat) (s : State) : Option String :=
  if s.searching != ((List.range n).filter fun i => (s.w i).searching).length then
    some "searching does not count the workers searching"
  else if s.sleepers.eraseDups.length != s.sleepers.length then some "a worker is listed twice"
  else none

def stuck (n : Nat) (s : State) : Option String :=
  let idle := (List.range n).filter fun i => asleep (s.w i)
  if idle.isEmpty then none
  else if s.global != 0 then some "a worker sleeps while the global queue has work"
  else if (List.range n).any fun i => (s.w i).ring != 0 then
    some "a worker sleeps while a ring has work to steal"
  else if idle.any fun i => (s.w i).pinned != 0 then some "a worker sleeps while it has pinned work"
  else if (List.range n).any fun i => (s.w i).slot != 0 then
    some "a worker sleeps while a run-next slot has work to steal"
  else none

def system (c : Config) : System State where
  init := {
    workers := (List.range c.workers).map fun i =>
      { pc := if i == 0 then .run else if c.asleep then .poll else .slot, ret := .run,
        searching := false, woken := false, idle := c.asleep && i != 0, kicked := false,
        slot := 0, ring := 0, batch := if c.asleep && i != 0 then .first else .none, pinned := 0, start := 0, maker := i == 0 || !c.firstMakes }
    searching := 0, sleepers := if c.asleep then (List.range c.workers).tail else [],
    global := 0, budget := c.budget, outside := .run }
  next := next c
  inv := inv c.workers
  stuck := stuck c.workers
  done := fun s => (next c s).isEmpty

end Models.Sleep
