# Amplifying λRig: the gap map, temporaries, and task loans

2026-11-07. The owner asked for more confidence in the ownership model
from `formal/`. This note maps what CORE and the concurrency proof
obligations claim against what `formal/` proves, ranks the gaps by the
risk that a compiler bug there is a memory-safety bug (North Star 2)
with no proof behind it, and records what was built for the top two.

## What formal/ held before

No `sorry`, `axiom`, or `admit` anywhere; every theorem's axioms pinned
to Lean's three by `#guard_msgs`. Proved: `accepts_runs` (CORE
sentences 1 to 6 over Ints and boxes), calls checked against an API's
`from` (`api_calls_run`, `within_live` at the level of cells), API
objects (`erased_runs`), the wait word (`Wait.lean`), the task machine
of handles, pins, and values that stay on one thread (`no_orphans`,
`confined`, `main_last`), crossing (`erase_confined`), and model checks
of the ring and of sleeping workers. Assumed throughout: that `bin/rig`
agrees with λRig's `check`, and that the emitted Zig does what λRig
does.

## The gap map, by risk

1. **Loans lent to a task** (concurrency.md, "Loans and structure",
   rules 1 and 5; obligations 1 to 3). The task machine had handles but
   no loans, and λRig no tasks: nothing proved that an owner lent to a
   running task is not written, moved, or dropped until the task is
   waited for. A bug there is a data race or a use after free across
   cores. Built here, in part.
2. **Statement temporaries lent for a call** (CORE §3; templates T1,
   PR #1014, where a template at a `?String` parameter is one). λRig
   lent only names, and Calls.lean's arguments were names: nothing proved
   that every view of a temporary dies by its statement's end. A bug is
   a view of freed stack or heap. Built here, in part.
3. **Views kept and stored** (CORE sentences 6 and 7, §5): write views
   passed to calls, `keeps`, views held in fields and containers, a
   loan lasting to a `drop` body. `within_live` covers the clauses over
   cells only; λRig stores no view anywhere a caller reaches.
4. **Fields and partial moves** (CORE §5, sentence 3): a field moved out
   of an owned object, the drop of the fields still held. Covered by the
   oracle and the sanitizer, by no proof.
5. **Shared homes, counted handles, and drop order** (sentences 8 and 9,
   §7; concurrency rules 2 and 3, obligation 2): `Cell`, `*T`, `~T`,
   `defer`, and the rule that no shared home holds a loan, which is what
   makes a value carrying a loan impossible to leak.

Outside the ranking, and larger than all five: the link from
`src/ownership.zig` to λRig's `check`, and from emit to λRig's `eval`.

## What was built

- `LambdaRig/Mono.lean`: `check_mono` (fewer names used later forbid
  less: same type and moves), `check_mono_iff`, `check_moved_fv`.
- `LambdaRig/Temps.lean`: `TProg`, a call whose first argument is a
  statement's temporary, elaborated with the temporary's scope ending
  with its statement (`tempIn`); `checkT`, which reads the API's clauses
  alone. `temps_run`: accepted programs run without a fault.
  `temp_from_rejected`: a binding whose API is `from` the temporary is
  rejected; run anyway, it stops at `freed`. A result used within its
  statement may view the temporary, and runs.
- `LambdaRig/TaskLoans.lean`: `spawn` (a task given `?y` or `!y`,
  waited for at its scope's end, the program the checker reads) and
  `spawnAt` (the same task acting at any moments between the scope's
  statements, several or none). `spawn_any_moment`: `check` accepts
  every `spawnAt` it accepts the `spawn` of, with the same type and
  moves. `task_runs` and `owner_task_runs`: so each runs without a fault.
  Examples: the owner writing, dropping, or reading beside a task whose
  loan forbids it is rejected, and each run stops at `deadTag`.

No statement was weakened, and no `sorry` or axiom was added. CORE's
text and the proofs agree on every rule modeled.

## What is left

Of the two gaps built: a temporary lent to write or kept by a call, a
header's temporaries; a task that moves (returned `from`, held in a
`Tasks` set), several loans per task, drop and `defer` order at a
scope's end, a panic's boundary, interleaving within a statement, and a
theorem that a read task sees one value at every moment. Gaps 3 to 5
wait for λRig's next slices (formal/README.md, "Next": objects, then
functions with `from` and `keeps`, then `Cell`, `*T`, `~T`).
