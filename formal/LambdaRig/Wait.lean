/-
How a fiber waits, and how a waker or a cancel ends the wait: the
protocol of `sched.Wait` (src/sched.zig), as a machine of atomic steps.

A fiber begins a wait (`beginWait`), which numbers it with a new epoch
and leaves it "about to sleep". It then commits: it switches away, and
its worker marks it asleep (`fallAsleep`), unless a waker has ended the
wait first, when the worker queues it at once. It may also give the
wait up before committing, and begin another. A waker ends the wait of
one epoch (`interrupt`): about to sleep or asleep becomes woken, and a
waker that finds it asleep queues the fiber. A cancel is a waker that
ends only a wait begun as one a cancel may end. A fiber handed its
worker takes back the wait of the one that handed it over (`claim`),
running it at once, which counts as queueing it.

Each step is one atomic instruction on the wait's word (a
compare-and-swap, sequentially consistent), so any order of steps is a
run of the real protocol. What is proved, of every state reached:

- `one_waker`: at most one waker ends a wait;
- `queued_once`: the fiber is queued at most once for a wait;
- `woken_queued`: a wait that was ended, of a fiber that has switched
  away, has queued it: no wakeup is lost;
- `cancel_delivered`: a cancel that comes while the fiber sleeps in a
  wait a cancel may end queues it;
- `late_waker`: a waker of an earlier wait changes nothing.

The word itself is `pack` below: the epoch, the bit a cancel may end the
wait by, and the state, as `Wait.pack` lays them out; `unpack_epoch`,
`unpack_cancelable`, and `unpack_state` show the three never overlap.
test/cli/wait_sync.sh checks that these numbers, and the steps, match
src/sched.zig: a change to one fails it until the other follows.
-/

namespace LambdaRig.Wait

/-- The state of a wait, in its word: about to sleep, asleep, or woken. -/
inductive St where
  | about
  | asleep
  | woken
  deriving DecidableEq, Repr

/-! ## The word -/

/-- A state's number in the word (`Wait.about`, `Wait.asleep`,
`Wait.woken`). -/
def St.code : St → Nat
  | .about => 0
  | .asleep => 1
  | .woken => 2

/-- The bit set when a cancel may end the wait (`Wait.cancelable_bit`). -/
def cancelableBit : Nat := 4

/-- The bits of the state (`Wait.states`). -/
def stateMask : Nat := 3

/-- How far up the epoch sits (`Wait.pack`, `Wait.epochOf`). -/
def epochShift : Nat := 3

/-- `Wait.pack`. Its `<<` and `|` are a product and sums here, since the
parts never share a bit (`unpack_epoch`, `unpack_cancelable`,
`unpack_state`). -/
def pack (e : Nat) (c : Bool) (s : St) : Nat :=
  e * 2 ^ epochShift + (if c then cancelableBit else 0) + s.code

/-- The state's bits, then the cancel bit, then the epoch, each above
the last. -/
theorem layout : (∀ s : St, s.code ≤ stateMask) ∧ cancelableBit = stateMask + 1 ∧
    2 ^ epochShift = 2 * cancelableBit := by
  refine ⟨fun s => ?_, rfl, rfl⟩
  cases s <;> decide

/-- `Wait.epochOf`. -/
theorem unpack_epoch (e : Nat) (c : Bool) (s : St) : pack e c s / 2 ^ epochShift = e := by
  have := layout.1 s
  simp only [pack, epochShift, cancelableBit, stateMask] at *
  cases c <;> simp <;> omega

theorem unpack_cancelable (e : Nat) (c : Bool) (s : St) :
    pack e c s / cancelableBit % 2 = if c then 1 else 0 := by
  have := layout.1 s
  simp only [pack, epochShift, cancelableBit, stateMask] at *
  cases c <;> simp <;> omega

/-- `w & Wait.states`. -/
theorem unpack_state (e : Nat) (c : Bool) (s : St) : pack e c s % (stateMask + 1) = s.code := by
  have := layout.1 s
  simp only [pack, epochShift, cancelableBit, stateMask] at *
  cases c <;> simp <;> omega

theorem code_inj {s s' : St} (h : s.code = s'.code) : s = s' := by
  cases s <;> cases s' <;> first | rfl | (simp [St.code] at h)

/-- Two waits pack to one word only if they are one. -/
theorem pack_inj {e e' : Nat} {c c' : Bool} {s s' : St} (h : pack e c s = pack e' c' s') :
    e = e' ∧ c = c' ∧ s = s' := by
  refine ⟨?_, ?_, ?_⟩
  · rw [← unpack_epoch e c s, ← unpack_epoch e' c' s', h]
  · have h1 := unpack_cancelable e c s
    rw [h, unpack_cancelable] at h1
    cases c <;> cases c' <;> simp_all
  · apply code_inj
    rw [← unpack_state e c s, ← unpack_state e' c' s', h]

/-- A fiber's first word, 0, is epoch 0, about to sleep (`W.init`). -/
theorem init_word : pack 0 false .about = 0 := rfl

/-! ## The protocol -/

/-- Where the fiber is: running (before a wait, or after it went on),
waiting (a wait begun, not yet switched away), or away (switched away). -/
inductive Phase where
  | running
  | waiting
  | away
  deriving DecidableEq, Repr

/-- A fiber's wait, and two counts kept for the proof: how many wakers
ended the present wait, and how many times its fiber was queued for it. -/
structure W where
  epoch : Nat
  st : St
  cancelable : Bool
  phase : Phase
  wins : Nat
  queued : Nat
  deriving DecidableEq, Repr

/-- A fiber before its first wait. The word starts at epoch 0, about to
sleep, as `Wait.word`'s 0 does. -/
def W.init : W := ⟨0, .about, false, .running, 0, 0⟩

/-- `interrupt(f, e, cancel)`: end the wait `e`, if it is still on, and,
for a cancel, if a cancel may end it. A waker that finds the fiber
asleep queues it. -/
def W.interrupt (w : W) (e : Nat) (cancel : Bool) : W :=
  if e = w.epoch ∧ w.st ≠ .woken ∧ (cancel = false ∨ w.cancelable = true) then
    { w with st := .woken, wins := w.wins + 1,
             queued := w.queued + (if w.st = .asleep then 1 else 0) }
  else w

/-- One atomic step of the fiber, its worker, or a waker. -/
inductive Step : W → W → Prop where
  /-- `beginWait(cancelable)`: a new epoch, about to sleep. -/
  | begin (w : W) (c : Bool) (h : w.phase = .running) :
      Step w ⟨w.epoch + 1, .about, c, .waiting, 0, 0⟩
  /-- The fiber gives the wait up before it commits, as a wait that finds
  what it waits for does. -/
  | giveUp (w : W) (h : w.phase = .waiting) :
      Step w { w with phase := .running }
  /-- `fallAsleep`, once the fiber has switched away: asleep, unless a
  waker came first, when its worker queues it. -/
  | fallAsleep (w : W) (h : w.phase = .waiting) :
      Step w (if w.st = .about then { w with st := .asleep, phase := .away }
              else { w with phase := .away, queued := w.queued + 1 })
  /-- `interrupt`: a waker of epoch `e`, a cancel when `cancel`. -/
  | interrupt (w : W) (e : Nat) (cancel : Bool) : Step w (w.interrupt e cancel)
  /-- `claim`: the fiber handed its worker takes the wait back, asleep,
  and runs it at once. -/
  | claim (w : W) (e : Nat) (h : e = w.epoch ∧ w.st = .asleep) :
      Step w { w with st := .woken, wins := w.wins + 1, queued := w.queued + 1 }
  /-- The fiber, queued, runs again. -/
  | resume (w : W) (h : w.phase = .away ∧ w.queued ≥ 1) :
      Step w { w with phase := .running }

/-- The states some run reaches from `W.init`. -/
inductive Reach : W → Prop where
  | init : Reach W.init
  | step {w w' : W} : Reach w → Step w w' → Reach w'

/-- What holds of every state reached, by phase. -/
def Inv (w : W) : Prop :=
  match w.phase with
  | .running => w.st ≠ .asleep ∧ w.queued ≤ w.wins ∧
      ((w.st = .about ∧ w.wins = 0) ∨ (w.st = .woken ∧ w.wins = 1))
  | .waiting => w.queued = 0 ∧
      ((w.st = .about ∧ w.wins = 0) ∨ (w.st = .woken ∧ w.wins = 1))
  | .away => (w.st = .asleep ∧ w.wins = 0 ∧ w.queued = 0) ∨
      (w.st = .woken ∧ w.wins = 1 ∧ w.queued = 1)

theorem inv_init : Inv W.init := by
  simp [Inv, W.init]

theorem inv_interrupt (w : W) (e : Nat) (c : Bool) (h : Inv w) : Inv (w.interrupt e c) := by
  unfold W.interrupt
  split
  · rename_i hc
    obtain ⟨-, hst, -⟩ := hc
    rcases w with ⟨ep, st, ca, ph, wi, qu⟩
    cases ph <;> cases st <;> simp_all [Inv] <;> omega
  · exact h

theorem inv_step {w w' : W} (h : Inv w) (s : Step w w') : Inv w' := by
  rcases w with ⟨ep, st, ca, ph, wi, qu⟩
  cases s with
  | begin c hp => simp [Inv]
  | giveUp hp =>
    simp only at hp; subst hp
    simp only [Inv] at h ⊢
    rcases h with ⟨hq, ⟨hs, hw⟩ | ⟨hs, hw⟩⟩ <;> subst hs <;> simp_all
  | fallAsleep hp =>
    simp only at hp; subst hp
    simp only [Inv] at h
    rcases h with ⟨hq, ⟨hs, hw⟩ | ⟨hs, hw⟩⟩ <;> subst hs <;> simp_all [Inv]
  | interrupt e c => exact inv_interrupt _ e c h
  | claim e hc =>
    obtain ⟨-, hs⟩ := hc
    simp only at hs; subst hs
    cases ph <;> simp_all [Inv]
  | resume hr =>
    obtain ⟨hp, hq⟩ := hr
    simp only at hp hq; subst hp
    simp only [Inv] at h ⊢
    rcases h with ⟨hs, hw, hq'⟩ | ⟨hs, hw, hq'⟩
    · omega
    · subst hs; simp_all

theorem inv_reach {w : W} (h : Reach w) : Inv w := by
  induction h with
  | init => exact inv_init
  | step _ s ih => exact inv_step ih s

/-- At most one waker ends a wait. -/
theorem one_waker {w : W} (h : Reach w) : w.wins ≤ 1 := by
  have := inv_reach h
  unfold Inv at this
  split at this <;> omega

/-- The fiber is queued at most once for a wait. -/
theorem queued_once {w : W} (h : Reach w) : w.queued ≤ 1 := by
  have := inv_reach h
  unfold Inv at this
  split at this <;> omega

/-- No wakeup is lost: once the fiber has switched away, a wait a waker
ended has queued it. -/
theorem woken_queued {w : W} (h : Reach w) (ha : w.phase = .away) (hw : w.st = .woken) :
    w.queued = 1 := by
  have := inv_reach h
  simp only [Inv, ha] at this
  rcases this with ⟨hs, -, -⟩ | ⟨-, -, hq⟩
  · rw [hw] at hs; cases hs
  · exact hq

/-- A fiber switched away and not yet queued sleeps, and a cancel of its
present wait, which a cancel may end, queues it. -/
theorem cancel_delivered {w : W} (h : Reach w) (ha : w.phase = .away) (hq : w.queued = 0)
    (hc : w.cancelable = true) :
    w.st = .asleep ∧ (w.interrupt w.epoch true).queued = 1 ∧
      (w.interrupt w.epoch true).st = .woken := by
  have := inv_reach h
  simp only [Inv, ha] at this
  rcases this with ⟨hs, -, hq0⟩ | ⟨-, -, hq1⟩
  · refine ⟨hs, ?_, ?_⟩ <;> simp [W.interrupt, hs, hc, hq0]
  · omega

/-- A waker of an earlier wait changes nothing. -/
theorem late_waker (w : W) (e : Nat) (c : Bool) (h : e ≠ w.epoch) : w.interrupt e c = w := by
  simp [W.interrupt, h]

/-- A run: a cancelable wait, the fiber asleep, then a cancel, which
queues it. -/
example : Reach ⟨1, .woken, true, .away, 1, 1⟩ := by
  have h1 := Reach.step .init (Step.begin W.init true rfl)
  have h2 := Reach.step h1 (Step.fallAsleep _ rfl)
  have h3 := Reach.step h2 (Step.interrupt _ 1 true)
  simpa [W.init, W.interrupt] using h3

-- The proofs assume nothing beyond Lean's standard axioms.
/-- info: 'LambdaRig.Wait.one_waker' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms one_waker

/-- info: 'LambdaRig.Wait.woken_queued' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms woken_queued

/-- info: 'LambdaRig.Wait.cancel_delivered' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms cancel_delivered

end LambdaRig.Wait
