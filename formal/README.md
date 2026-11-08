# formal: λRig in Lean

This directory holds the machine-checked side of Rig: λRig, the core
calculus of the ownership model (docs/CORE.md), written in Lean 4, with
an interpreter, an ownership checker, and a proof that every program the
checker accepts runs without a fault. The plan it follows is
[FORMAL-RIG](../docs/design/formal-plan.md), "Assurance: four stages of proof";
this is the first slice of stages 2 and 3.

## Build

Lean comes from elan, which reads the version from `lean-toolchain`
(Lean 4.35.0). There are no other dependencies.

```bash
brew install elan-init
```

```bash
cd formal && lake build
```

`lake build` checks every proof, runs every example program, and runs
the model checks of the runtime (`Models/Checks.lean`, about 30
seconds, rerun only when a model changes). Every warning is an error.
Run it after changing `formal/`. `lake build Models.Deep` runs larger
model checks, by hand: several minutes and 8 GB.

## Layout

| File | What it holds |
|---|---|
| `LambdaRig/Syntax.lean` | Values and expressions; each constructor names the Rig form it stands for |
| `LambdaRig/Machine.lean` | Cells, the loans live on each, the ways to touch a cell, and the faults |
| `LambdaRig/Interp.lean` | `eval`, an interpreter that tags every view with its loan and checks the tag on each use, and `run` |
| `LambdaRig/Loans.lean` | CORE sentence 5 for one cell, and `Keeps.eval` for the whole machine |
| `LambdaRig/Check.lean` | `check`, the ownership checker: the types, what has moved, and which views are used later |
| `LambdaRig/Facts.lean` | `Rel`, what the checker's facts say of a running machine |
| `LambdaRig/Steps.lean` | One theorem per form: each step the checker accepts keeps `Rel` |
| `LambdaRig/Sound.lean` | `sound`, the induction over programs, and `accepts_runs` |
| `LambdaRig/Calls.lean` | Calls checked against an API's `from` and `keeps`, and why they are sound for any implementation within them |
| `LambdaRig/Erase.lean` | API objects: erasing a type keeps its loans, and programs whose objects only calls reach |
| `LambdaRig/Examples.lean` | Programs, whether the checker accepts each, and how each run ends |
| `LambdaRig/Mono.lean` | `check_mono`: fewer names used later forbid less; `check_moved_fv`: a name a program does not use, it does not move |
| `LambdaRig/Temps.lean` | A statement's temporary lent to a call: its views die by the statement's end |
| `LambdaRig/TaskLoans.lean` | A task given `?y` or `!y`: its loan holds at whatever moments it runs, until it is waited for |
| `LambdaRig/Stores.lean` | Views kept and stored, over values: what a result and a holder carry, at any depth |
| `LambdaRig/Fields.lean` | An owned object's fields, partial moves, and the drop of the fields still held |
| `LambdaRig/Wait.lean` | The wait protocol of `sched.Wait`, as atomic steps, and what it guarantees a waker and a cancel |
| `LambdaRig/Tasks.lean` | The task machine: who holds each handle, cores, pins, and the values that stay on one thread |
| `LambdaRig/TasksSound.lean` | Its invariant, kept by every step, and what follows from it |
| `LambdaRig/Crossing.lean` | API objects crossing tasks: erasing keeps what a crossing check reads |
| `LRig.lean` | `lrig`, an executable of λRig's `check` and `run`, for the agreement test |
| `Models/Explore.lean` | An explicit-state model checker: every state a system of atomic steps reaches |
| `Models/Ring.lean` | A worker's ring of ready fibers: push, pop, steal, and the overflow |
| `Models/Sleep.lean` | How workers search, sleep, and are woken: `searching`, `sleepers`, `notify`, and the pinned queue's `idle` flag |
| `Models/Checks.lean` | The model checks `lake build` runs, with the counts each gave |
| `Models/Deep.lean` | Larger model checks, by hand |

## What the first slice covers

Plain Ints and one kind of owner, a box holding an Int (`^Int`). Every
binding is a place, so a number can be lent too. The forms are a bare
name, `<x` as a value and as a statement, `+x`, `^e`, `?x`, `!x`,
assignment (to an owner, or through a write view), `+`, `print`,
sequencing, and a scoped binding.

A view sees its owner's place, as in `bin/rig`: `?v` of a box reads the
box `v` holds now, and assigning `^5` through `w = !v` puts a new box in
`v` and drops the old one. The interpreter checks nothing ahead of
time. It runs a program and stops at the first broken promise: a use
after move or free, a view used after its loan ended (`deadTag`), a
step with no meaning (`stuck`), or a leak at the end.

## What is proved

**`accepts_runs`** (Sound.lean): if `check` accepts a program, `run`
ends without a fault and the heap is empty. That is the λRig form of
AGENTS.md rule 2, "safe code cannot corrupt memory", for this slice. A
`#guard_msgs` keeps its axioms to Lean's standard three (`propext`,
`Classical.choice`, `Quot.sound`), so no step is assumed.

It covers these CORE sentences, each by the fault it rules out:

| CORE sentence | Fault ruled out | Examples |
|---|---|---|
| 1. A bare name only reads | `stuck` | `readViewsShare` is accepted |
| 2. `<x` moves, `+x` makes a new owner | `moved`, `freed` | `useAfterMove`; `cloneIsNewOwner` is accepted |
| 3. Drop points | `leak`, `freed` | `viewOutlivesScope`; `temporariesDrop` is accepted |
| 4. `?x` and `!x` lend | `deadTag` | `writeWhileRead` |
| 5. Read loans or one write loan | `deadTag` | `assignWhileRead`, `readWhileWrite` |
| 6. A loan lasts until the last use of its views | `deadTag`, `freed` | `dropWhileRead`, `moveWhileRead` |

**`Keeps.eval`** (Loans.lean): every cell of every state `eval` reaches
holds read loans or one write loan, never both. This holds by
construction: every way the interpreter touches a cell builds a cell
of that shape. It shows the machine models sentence 5 the way CORE
states it. It says nothing about the checker; `accepts_runs` does.

**Calls through an API** (Calls.lean). A call through a bound is
checked against the API's clauses, and an implementation's `from` and
`keeps` may be narrower, by position, never wider (SPEC, "APIs";
docs/design/apis.md, Stage 3). Clauses are lists of parameter
positions, and `Within` says one is the same as another or narrower.
Two results:

- **`within_live`**, for loans: the caller records the loans of the
  arguments the API's `from` names, kept while the result lives, and of
  those its `keeps` names, kept while what the call stored into lives.
  An implementation that meets clauses within the API's leaves views
  only of those arguments (`records_created`), so after anything the
  caller does that its record allows (the machine's ways to touch a
  cell, by the access each is, and frees), every view the result holds
  and every view the call stored is still live. `outside_dies` shows the
  clauses are needed: a result viewing an argument the API's `from` does
  not name dies at a write the caller is allowed. This part covers both
  clauses and any number of positions, over the machine's cells; it
  does not run programs.
- **`api_calls_run`**, for programs: `Prog` is λRig with calls, `r =
  f(args)`, each checked by `checkCall` against its API's clauses alone,
  never the implementation; `elab` runs each call in place. If `checkP`
  accepts a program and every implementation meets clauses within its
  API's (`Fits`), the program runs to the end without a fault, by
  `accepts_runs`. The step is `inline_check`: the call run in place is
  accepted by `check` with the very type `checkCall` gave from the
  API's `from`, so `call_fits` gives what `sound` gives, a result that
  views the owner the caller recorded, with its loan live. On a program
  with no calls `checkP` is `check` (`checkP_noCalls`), so the extension
  is conservative. Its `#guard_msgs` keeps the axioms to Lean's three.

The examples call `pick(a: ?Int, b: ?Int) -> ?Int from a`, then write
`b` while the result lives: an implementation `from a` that reads `b`
and returns `a` runs to the end, and one `from b`, outside the API's
clauses, which `checkP` accepts all the same, stops at `deadTag`. A
third calls an API `from a, b` with an implementation `from b`.

**API objects** (Erase.lean). `?{A}`, `!{A}`, and `^{A}` hide their
value's type, never its loans (CORE §4; docs/design/apis.md, Stage 4).
An object's type, as the checker sees it, is its kind and its loans
(`OTy`), and erasing a type keeps them (`erase_loans`). Three results:

- **`allows_erase`**, for the checker: the rule for an access to an
  owner reads only the loans of the names in scope (`allows_loans`), so
  a name given any type that carries an object's loans is allowed
  exactly the accesses its erased type was.
- **`erase_live`**, for values: erasing evaluates as its operand (a read
  view copies; a write view or a box moves into the object), and the
  object's value holds, for each loan its type carries, a view of that
  owner whose loan is live.
- **`erased_runs`**, for programs: `EProg` is the programs of Calls.lean
  with erasure, `r: ?{A} = x`, `r: !{A} = <x`, and `r: ^{A} = <x`.
  `checkE` gives the object the type rebuilt from its kind and loans
  alone, and lets only calls, checked against their API's clauses,
  reach it: no expression names an object, so nothing reads, assigns
  through, or moves it in place. If `checkE` accepts a program and every
  implementation meets clauses within its API's, the program runs to the
  end without a fault, by `accepts_runs`. The step is `checkE_elab`: the
  type rebuilt from the loans is the type `check` gives the erasure run
  (`operand_check`). On a program without erasure `checkE` is `checkP`
  (`checkE_lift`), so the extension is conservative.

`#guard_msgs` pins each one's axioms: Lean's three for `erased_runs` and
`erase_live`, and `propext` and `Quot.sound` alone for `allows_erase`
and `checkE_lift`. The examples call `area` through a `?{Shape}` and
run; write the owner while the object is used later, which `checkE`
rejects and which, run all the same, stops at `deadTag`; print an object
in place, which it rejects; and move a box into a `^{Shape}`, which
keeps it and drops it once.

**Statement temporaries** (Temps.lean). CORE §3: a value made where it
is only read is a temporary, "dropped when the statement ends", and "a
view of it may be used only within its statement"; a backtick template
where a `?String` goes is one. `TProg` adds to Calls.lean's programs a
call whose first argument is a temporary, `r = f(?e, args)` and
`print(f(?e, args))`. `elab` runs it as CORE says: `e`'s value is held
in a hidden place whose scope is the statement alone (`tempIn`), lent to
read as a hidden view, and dropped before the next statement. `checkT`
reads only the API's clauses. Two results:

- **`temps_run`**: if `checkT` accepts a program and every
  implementation meets clauses within its API's, the program runs to
  the end without a fault, by `accepts_runs`: each temporary is dropped
  once, where its statement ends, and no view of it is used after. The
  step is `check_tempIn`: the temporary's scope checks as its use does,
  when what the use gives views neither hidden name.
- **`temp_from_rejected`**: a binding whose call's API is `from` the
  temporary's position is rejected, since its result would view the
  temporary after the statement ("a view of the temporary ... outlives
  its statement").

The examples: `r = pick(?^5, ra)` with `pick` `from` its second
parameter runs; with `pick` `from` the first it is rejected, and run all
the same it stops at `freed`; `print(pick(?^5, ra))` `from` the first,
the result used within its statement, runs. `#guard_msgs` pins
`temps_run`'s axioms to Lean's three.

**Views kept and stored, over values** (Stores.lean). `within_live`
proves `from` and `keeps` by argument position; this proves them of
values. A value `V` is plain, a `Static`, a view carrying its loan and
seeing a value, or an object of parts (a field's holder, a List, an
optional) at any depth; it carries the loans of every view it holds or
reaches (CORE 6: "wherever that view went: a field, an array, an
optional, a closure, a result"). A body `B` builds a value from its
arguments, from literals, and by reading a part of a value, where a read
view an object holds is itself, carrying its own loans and not the
holder's (CORE 7; `part_read_view`). A `Body` is a result and the values
it stores, each at a path in what a write view parameter sees, checked
against its clauses by the parameters each is built from
(`Body.Meets`, the compiler's body check). The results:

- **`carried_eval`**: every loan a body's value carries is carried by
  an argument the body read;
- **`body_records`**: for a body within clauses within the API's, the
  loans its result carries are among those the caller records for the
  API's `from`, and those of what it stores among those for `keeps`;
- **`stores_live`**: so whatever the caller then does that its record
  allows (`After`, Calls.lean) keeps every loan the result carries live,
  and every loan the holder it stored into carries: a kept loan lasts
  while the holder is used.

The examples are CORE's `Cursor`, whose `next` hands out a view carrying
the List's loan and not the cursor's, and `watch(!@, s) keeps s`, whose
store of `s` meets `keeps s` and not an empty `keeps`. `stores_live` is
pinned to Lean's three axioms.

**Fields and partial moves** (Fields.lean). CORE §5, "A field of an
owned object moves like a name", and sentence 3, "A partly moved name
drops only the fields it still holds". An owned object is a tree of
owners of heap cells, plain data, and objects of two fields, each
marked when its type has a `drop` body. A program on one local is uses
(`p.f`, `?p.f`, `!p.f`, or all of `p`), moves out (`<p.f`, `<p`), and
assignments (`p.f = x`, `p = x`). `check` keeps the local's type with
each moved field marked, the moved state per path: a use or a move
touches its path, so nothing in it may be moved; a field that copies
takes no `<`; no field of an object with a `drop` body moves; and an
assignment refills a moved or partly moved path, not one inside a moved
field. The machine runs the program on the tree, a moved field left
`gone`, and where the scope ends drops the local and each value moved
out, by its new owner; a `drop` body reads every field.

- **`fields_run`**: a program `check` accepts runs without a fault: no
  use of a moved field, no cell freed twice, no `drop` body that finds a
  field moved, and no cell left. The invariant `Inv` says the cells
  allocated are, once each, those the local and the moved values own;
  `cells_set` and `dropO_ok` carry it through a move and an assignment.

The examples are CORE's `Entry` (`<e.value`, `e.key`, `e.value = ...`,
`<e`), which runs; `<e` while `e.value` is moved, and a use of `e.value`
after it moved, which are rejected and stop at `moved`; and `<f.name` of
a `File` with a `drop` body, rejected, whose drop finds the field moved.
`fields_run` is pinned to Lean's three axioms.

**Loans lent to a task** (TaskLoans.lean). concurrency.md, "Loans and
structure": "A task keeps the loans of its arguments until it ends", and
a task's drop uses its loans, so a task is waited for before its scope
ends. `spawn t m y ss` is `t = g(?y)&` (or `g(!y)&`) with the
statements `ss` beside it: the task's action, a read or a write through
its view, stands after the last statement, where the task is waited
for, which is the program the checker reads. `spawnAt t m y ss runs` is
the same task run at the moments `runs` picks: before any statement,
after the last, at several, or at none, as a task canceled before it
ran. Three results:

- **`spawn_any_moment`**: if `check` accepts `spawn`, it accepts
  `spawnAt` for every `runs`, with the same type and moves. So no
  statement beside a task ends its loan: none writes, moves, or drops
  `y` while a task reads it, and none touches `y` while a task writes
  it. The step is `weave_check`, over `check_mono`;
- **`task_runs`**: from any machine the checker's facts match, the task
  run at any moments runs without a fault (`sound`);
- **`owner_task_runs`**: a program `y = e` then such a task, accepted,
  runs to the end without a fault whichever moments the task runs at.

The moments are the points between the scope's statements, each
statement taken whole, and a task holds one loan. The examples: a read
task beside the owner's own read, run at every moment, ends well; the
owner writing, or dropping, beside a read task, and reading beside a
write task, are rejected, and each run stops at `deadTag`; a write task
waited for before the owner reads ends well. `#guard_msgs` pins
`task_runs` and `owner_task_runs` to Lean's three.

**`Examples.lean`**: eleven programs, each with whether `check` accepts
it and how its run ends. Four are accepted and end well; seven are
rejected, and each stops at the fault its rejection prevents.

## Tasks and waits

The first slice of the concurrency model's proofs (docs/design/concurrency.md,
"Proof obligations"), over machines of their own rather than λRig's
expressions, since the runtime, not the expression, decides these.

**`Wait.lean`** models one fiber's wait word (src/sched.zig, `Wait`):
`beginWait`, giving the wait up, `fallAsleep`, `interrupt` by a waker
or a cancel, `claim` by a fiber handed the worker, and resuming. Each
step is one sequentially consistent instruction, so any order of steps
is a run. Of every state reached:

- `one_waker`: at most one waker ends a wait;
- `queued_once`: the fiber is queued at most once for it;
- `woken_queued`: once the fiber has switched away, a wait that was
  ended has queued it, so no wakeup is lost;
- `cancel_delivered`: a cancel that comes while the fiber sleeps in a
  wait a cancel may end queues it;
- `late_waker`: a waker of an earlier wait changes nothing.

It also gives the word's layout (`pack`: the epoch, the bit a cancel
may end the wait by, the state) and proves its parts never overlap
(`unpack_epoch`, `unpack_cancelable`, `unpack_state`, `pack_inj`).
`test/cli/wait_sync.sh`, in the suite, keeps the model and the Zig in
step: it checks that the numbers match `Wait`'s constants, that the
functions of src/sched.zig that touch a wait's word are exactly the
ones it maps to Lean steps, and that each step's lines (the checks and
the compare-and-swap) are still in both. A change to either side fails
it until the other, and its table, follow.

**`Tasks.lean`** models tasks: each with its holder (the task whose
record holds its handle), its core, its pin, whether it was made local,
the values it holds that stay on one thread, and whether it ended or
was canceled. A task holds the handles of the tasks it is the holder
of, and once it ends, what it holds is its result. Its steps are a free
spawn (given nothing that stays on one thread, and only handles of
tasks that are not local), a local spawn (pinning the task and its
maker to the maker's core), either spawn given handles its maker holds
(`Task[T]` as an argument), a worker stealing a task that is not
pinned, making and dropping such a value, cancel by the holder, finish,
and wait (the holder takes the values and the handles the task held,
so a `Task[T]` comes back through a result). A task ends keeping its
handles in its result; one it does not return it waits for first, as a
dropped handle cancels and waits.

`finish` models the rule that a task's result moves unless the task is
local (`sema`, the check `par.map` makes): a task that is not local
returns no value that stays on one thread and no handle of a local
task, since a local task's result need not cross and so neither does
its handle. `confined` needs it: without it, a free task could share a
value with a local task and return it, with that task's handle, to a
task on another core (a probe of the concurrency panel, in
[its adversarial report](../docs/history/records/2026-10/concurrency-panel/3-adversarial.md)).

**`TasksSound.lean`** proves one invariant kept by every step: every
task's chain of holders reaches `main` (so none loops), once `main` has
ended no other task is left, a pinned task runs on its pin's core, two
holders of one value are pinned to one core, a local task's holder is
pinned with it, and an ended task that is not local holds nothing that
does not cross. Of every state reached:

- `no_orphans`: every task but `main` is held by a running task, or by
  the result of an ended task held so in turn, so no task runs, or
  waits to be waited for, with no running task answerable for it;
- `main_last`: once `main` has ended, it is the only task;
- `confined`: two tasks holding one such value are pinned to one core
  and run there, so no two cores touch it;
- `pin_kept`: a pinned task stays on its core from then on;
- `cancel_sticky`: a cancel is never taken back.

Two runs show the invariant is not vacuous: `localTask_reach` reaches a
state with two holders of one value, and `handed2_reach` the shape of
a probe of the concurrency panel
([its formal report](../docs/history/records/2026-10/concurrency-panel/5-formal.md)): task 1 makes task 2 and ends while 2 runs,
holding 2's handle in its result; `main` waits for 1 and takes 2, then
hands 2 to a new task 3.

**`Crossing.lean`** proves Stage 5's crossing obligations
(docs/design/apis.md): an API object crosses tasks only by a bound it
names, `Sends` or `Syncs`, a fact of the hidden value checked where it
is erased. `CVal` is a value as a crossing check sees it: the values
that stay on one thread it holds, its task handles, its parts at any
depth, and the API objects in it, each with the bound it names. An
object's facts are its hidden value's (`holds_erase`, `tasks_erase`).
`Spawn` is `f(args)&`: free when the arguments cross (`Crosses`, what
`crossingBlocker` checks), local otherwise, and never with an object
naming no bound among them. Of these:

- `crosses_erase`: a value that may not cross before erasure may not
  cross after, and one that may, may; `spawn_erase`: a spawn of an
  object with a bound is the spawn of the value it hides, to the same
  state;
- `erase_sends`: an object whose bound was checked at erasure
  (`EraseOk`) holds nothing that stays on one thread and no task, so a
  free spawn may take it, and checking the bound there suffices;
- `bare_no_spawn`: an object naming no bound goes to no task, a local
  one included, at any depth;
- `spawn_step`: a spawn of arguments a running task holds is a step of
  the task machine, `spawnFree` or `spawnLocal`;
- `erase_confined`: after a spawn of an erased value from a reached
  state, the object names a bound, the state is reached, and `confined`
  holds in it, as `pin_kept` does from it on.

`sendsJob` reaches a state where `main` gives a `^{Job + Sends}` to a
free task. `#guard_msgs` pins the axioms: Lean's three for
`erase_confined`, `propext` and `Quot.sound` for `crosses_erase` and
`erase_sends`.

Not yet: `Tasks` sets, actors and channels (whose contents the crossing
rule restricts), that dropping a handle cancels and waits (the model
has a task wait before it ends instead), the deadlock walk, and
unwinding to a boundary. The task machine carries no loans; the loans a
task holds are proved over λRig, in TaskLoans.lean, for a task waited
for at its scope's end.

## Model checks of the runtime

The scheduler's handshakes are checked by exploring every
interleaving of their atomic steps, within bounds, before more of them
are proved by hand. No TLA+ or GenMC is installed here (and no Java),
so `Models/Explore.lean` is a small explicit-state checker in Lean,
compiled (`precompileModules`) and run while `lake build` elaborates
`Models/Checks.lean`. It is a check, not a proof: it covers each model
within its bounds, and every step is sequentially consistent, so it
says nothing of weaker orderings (the ring's acquire and monotonic
loads, or a Dekker handshake whose loads are not `.seq_cst`; those need
GenMC or herd7). Of every state reached it checks the model's rules;
of every state where no step is enabled (a worker waiting in its
poller for a kick no one sends) it checks that nothing is lost; and it
checks that from every state some run reaches such a state, so no
thread loops for ever.

**`Ring.lean`** (src/sched.zig, `Ring`): the owner pushes and pops,
thieves steal half (copy, then compare-and-swap `head`), and a push to
a full ring hands the older half to the global queue; each load,
store, and compare-and-swap of `head`, `tail`, or a slot is a step.
Checked: no fiber is taken twice, `head` stays within `size` behind
`tail`, and when all are done every fiber pushed was taken once or is
still in the ring once. Bounds: a ring of 4 with 5 pushes, 2 pops, and
2 thieves stealing once each (515,484 states), and a ring of 2 with 4
pushes, 2 pops, and a thief stealing twice. Counters do not wrap.

**`Sleep.lean`** (`loop`, `next`, `search`, `notify`, `notifyNew`,
`sleep`, `waitWoken`, `wakeHome`): workers take work from their ring,
their pinned queue, and the global queue, then search (counted in
`searching`, at most half of them), and sleep: clear `woken`, set
`idle`, list themselves in `sleepers`, look once more for work unless a
worker searches, then wait in the poller. Fibers make work into their
ring (`wake`, `wakeLast`) or another worker's pinned queue
(`wakeHome`); a thread outside makes work into the global queue or a
pinned queue. A fiber may run on for ever, never yielding: the worst
case, where its worker's ring must be stolen. Checked: `searching`
counts the workers searching, `sleepers` lists none twice, and no
worker waits in its poller while there is work it could take. Bounds:
2 workers with 2 pieces of work, made each way; 3 workers, the others
asleep at first, with 1 piece into a ring, 2 into pinned queues, or 1
into the global queue. `Deep.lean` runs 3 workers with 2 pieces into a
ring (7,734,406 states), and 2 workers making work every way at once,
with `relook` (1,301,655 states). Three workers with 2 pieces into the
global queue pass 30 million states, too many to finish.

The pinned queue's `idle` handshake holds (as the panel found by
reading). So does the `searching`/`sleepers` handshake for work made
into a ring. Work made into the global queue (a blocking call's end,
or a thread outside the workers) needs one more step, which
`src/sched.zig` takes (`sleep`) and the model calls `relook`: a worker
that finds work in its last look before sleeping counts itself as
searching again, as Go's scheduler does. Without it, work can wait
while a worker sleeps:

1. Worker 0 searches and finds nothing.
2. Worker 1 sees a worker searching and sleeps without a last look.
3. Two pieces of work arrive. `notifyNew` sees worker 0 searching and
   wakes no one.
4. Worker 0 stops searching. Its last look before sleeping finds the
   work, and it takes one piece and runs on.
5. The other piece waits in the global queue, with worker 1 asleep,
   until worker 0's next yield check.

Work found in that last look is not taken while searching, so no
`notify` follows. With `relook`, taking it while counted as searching
notifies, and the check passes. `Checks.lean` pins both: the check
without `relook` fails with this trace, and the checks with it pass.

Each check is shown not to be vacuous by breaking the protocol on
purpose: a thief that claims with a plain store takes a fiber twice, a
`sleep` with no last look leaves a ring's work, and a `wakeHome` that
never kicks leaves pinned work.

Not modeled: the run-next slot, timers, the poller's events, `waiting`
and the yield checks, `stopping`, and the blocking pool. A fiber in a
busy worker's run-next slot wakes no worker: its maker's next yield
check hands it on, a recursive one only through `waiting`, so a check
or a sleeper that clears `waiting` sets it again while another
worker's slot holds a fiber (`takeWaiting`; docs/internals/scheduler.md,
"Yield checks"). That handshake is checked by unit tests in
`src/sched.zig`, not here.

## Agreement with bin/rig

`test/cli/agree.sh`, in the suite, runs bin/rig's checker and λRig's
side by side. `rig-oracle --lambda` (test/oracle/lambda.zig) writes each
program λRig can express (one `sub main()` of bindings, assignments,
`<x`, and `print`, over integers, names, `<x`, `+x`, `^e`, `?x`, `!x`,
and `+`) as λRig's forms, with the compiler's verdict on it, and says
why it leaves each other program out. `lrig` (LRig.lean, built by `lake
build`) runs `accepts` and `run` on each. A program the compiler accepts
whose λRig run faults always fails the test; one the two checkers
decide differently fails unless `test/oracle/agreement` lists it with
its kind and class. The corpus is the cases of test/rig and examples/.
On 2026-11-07, 22 programs were in scope, 20 decided alike, 2 rejected
by the compiler alone for rules λRig does not have (an unread local,
`none` as a name), none rejected by λRig alone, and none unsound.

## What is not proved

- **That `bin/rig` agrees with `check`.** `check` is written for
  λRig, not taken from `src/ownership.zig`. It is stricter than
  `rig check` in places: it rejects a bare name of a box, which Rig
  reads in place. The agreement test (below) checks the two on every
  program of the corpus λRig can express; it tests, it does not prove,
  and the exporter that writes Rig as λRig is trusted. The proved link
  is stage 3's validator.
- **That the emitted Zig does what λRig does.** Zig has no formal
  semantics; the test suite and the sanitizer stand in for it.
- **Anything outside the slice:** objects, optionals, `List`,
  functions, `*T`, `~T`, `Cell`, loops.
- **Temporaries beyond Temps.lean.** A temporary is lent to read, as
  the first argument of one call; one lent to write (`!mk().pop()`), a
  temporary a call keeps (`!p.watch(?t)`, which needs stores, Next, 4),
  a header's temporaries, and the drop order of several in one statement
  are not modeled. That `src/storage.zig` gives each temporary the
  statement's scope is the compiler's part, held by the suite.
- **Tasks beyond TaskLoans.lean.** A task holds one loan, of an owner in
  scope, and is waited for where its scope ends; it moves nowhere. A
  task returned with `from`, held in a `Tasks` set, or given a
  temporary (rejected by the compiler: "a task cannot keep it"), the
  order of drops and `defer`s at a scope's end (rule 2), a panic's
  boundary (rule 4), and interleaving within a statement are not
  modeled. That a read task sees one value whichever moment it runs is
  not proved as such: it follows from the loan staying live, since every
  way the machine changes a cell's value ends its read loans
  (Machine.lean), but no theorem states it.
- **Calls beyond the slice (docs/design/apis.md, Stage 3).** In
  `api_calls_run`, a method's parameters and result are read views and
  its body reads parameters and returns one; there are no write views,
  owners passed by value, or bodies of their own. `keeps` is proved
  for loans (`within_live`) and over values (`stores_live`), not for
  λRig programs, since λRig stores no view where a caller reaches it. A view's type names one owner, so `checkCall`
  accepts a `from` of several positions only when their arguments view
  one owner; `within_live` has no such limit. A call runs in place, as
  inlining runs it, which is what binding each read-view parameter to
  its argument does; a callee checked once, in a scope of its own, needs
  functions in λRig (Next, 4).
- **API objects beyond the slice (docs/design/apis.md, Stage 4).** A
  λRig box holds only an Int, so a `^{A}` carries no loans, and that a
  box of erased type keeps its loans to its drop is proved only of boxes
  that carry none; a box of views, whose drop reads its loans, needs
  objects in λRig (Next, 1). A view's type names its owner, not what the
  owner holds, so erasing a view hides nothing `check` read, and
  `OTy.ty` rebuilds the type erased; an object hiding a type the checker
  reads also waits for objects. A call takes an object as a read view,
  as Calls.lean's calls do, so calls through a `!{A}` or a `^{A}`, and a
  `<@` method ending the box, are not modeled. A dynamic call is checked
  as a static one is, against the API's clauses, since `checkCall` never
  reads the implementation. The copy of an erased view of plain data, a
  local of the erasing block, is not modeled.
- **Crossing beyond the task machine (docs/design/apis.md, Stage 5).**
  `CVal` abstracts a value to what a crossing check reads; it is not
  λRig's `Val`, and that `sema.crossingBlocker` computes `Crosses` and
  `EraseOk` is assumed, the compiler's part, held by the suite. The task
  machine does not tell moving a value to another task from sharing it,
  so `Sends` and `Syncs` are one fact here: the hidden value holds
  nothing that stays on one thread. That a `*{A + Syncs}` holds only a
  frozen value is that fact for its handle, since a `*T` whose count is
  not atomic stays on one thread; atomic counts themselves, and a
  `*{A}` carrying its value's loans to its last count, are not modeled,
  since λRig has no counted handles (Next, 5).
- **Partial moves beyond Fields.lean.** Fields.lean has one local,
  not λRig's expressions: it has no loans on paths (`?p.a` beside `!p.b`,
  CORE sentence 5's places), no optional field taken to `none`, no
  parameter or capture, no branches (a field moved on one path and not
  another), and objects of two fields, nested for more. The oracle
  (`test/oracle/flow.zig`) tracks these per path, and the sanitizer runs
  each case.
- **Stores beyond Stores.lean.** A `V` may hold a write view in a part,
  which CORE forbids ("Write views are not stored"); the results hold
  without that rule, which they do not use. A view's write lend ending
  as the call returns, the caller recording a write loan as a read one
  (sentence 7), a value never holding a view of itself, and a call
  through a function value (whose type names no `keeps`) are not
  modeled.
- **Bounds (docs/design/apis.md, Stage 2).** A body may copy a type
  parameter bounded `Copy`, so a proof that generic bodies keep the
  Core needs `Copy` to hold only of the kinds that copy: plain data and
  read views (Core §1), never an owner or a write view. The obligation
  is recorded here and not yet proved; it joins λRig once type
  parameters do.

## Next

The slices, in order; each grows `Syntax`, `Interp`, `Check`, and
`Examples` together, and keeps `accepts_runs` and `Keeps.eval` proved:

1. Objects with fields, and paths into them.
2. Optionals and `e?`; `e!` and `defer`.
3. `List` as a primitive buffer, and slices.
4. First-order functions with `from` and `keeps`.
5. `Cell`, `*T`, and `~T`.
6. Loops, with fuel so `eval` stays total.

After those, the interpreter runs the suite, the corpus, and the matrix
beside `bin/rig-oracle`, and replaces it over time (FORMAL-RIG, decision
6). Functions with `from` and `keeps`, and `*T` with `Cell`, likely need
separation logic; whether that part is done in Lean or in Rocq with
Iris is decided when it starts.
