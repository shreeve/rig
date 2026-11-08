# Amplifying λRig, round two: stores, fields, and agreement with bin/rig

2026-11-07. Round two of [formal-amp.md](formal-amp.md): gaps 3 and 4 of
its map, and a research note on testing that `bin/rig`'s checker agrees
with λRig's.

## Which first

Gap 3 (views kept and stored) went first: a wrong `keeps` or `from`
check leaves a view of freed memory in the caller, across a call
boundary, where neither the oracle's per-function walk nor a test that
misses the call sees it. Gap 4 (partial moves) is a double free or a
use after move, which the oracle tracks per path and the sanitizer
catches in every case run. Both fit.

## What was built

- `LambdaRig/Stores.lean`: values with views at any depth (`V`), bodies
  built from their arguments (`B`, `Body`), and the compiler's body
  check (`Body.Meets`). `carried_eval`, `body_records`, `stores_live`:
  the loans a result or a holder carries after a call are among those
  the caller records for `from` and `keeps`, and so stay live under
  anything the record allows. `part_read_view`: a read view reached
  through a view carries its own loans (CORE 7). Examples: CORE's
  `Cursor`, and `watch(!@, s) keeps s`.
- `LambdaRig/Fields.lean`: an owned object as a tree, the per-path moved
  state as the checker's type with moved fields marked, and a machine
  that drops what a partly moved local still holds and what each new
  owner took. `fields_run`: an accepted program uses no moved field,
  frees no cell twice, runs no `drop` body that finds a field moved, and
  leaks nothing. Examples: CORE's `Entry`, `<e` while partly moved, a use
  after `<e.value`, and `<f.name` under a `drop` body.

No `sorry` or axiom was added, and no existing statement was changed.
CORE's text and the proofs agree on every rule modeled. The limits are in
formal/README.md, "What is not proved".

## Research: does bin/rig's checker agree with λRig's?

λRig's `check` and `run` are ordinary Lean functions: `lake` compiles
them to native code, so no extraction is needed. `#eval` costs about a
second of elaboration per program; one compiled executable that reads
many programs per process costs microseconds each.

Steps:

1. **An exporter** in `bin/rig-oracle` (it already links the compiler as
   a library, `src/lib.zig`): walk the normalized IR of a function and
   print it as an S-expression of λRig's forms when it stays within the
   slice (Ints, `^Int` boxes, names, `<x`, `+x`, `?x`, `!x`, assignment,
   `print`, sequence, scoped bindings, and later Temps and TaskLoans
   forms), or print `outside` and why. It is the trusted part, so it
   stays syntactic: about 300 lines of Zig.
2. **`lake exe lrig`**: a Lean `main` that parses each S-expression into
   `Expr`, prints `accepts` and `run`'s outcome. About 150 lines.
3. **A differential script** in `test/cli`, run by the suite: for every
   program in the corpus (test/rig cases, doc examples, examples/, the
   oracle's corpus), export it, run `lrig`, and compare with `bin/rig
   check`. Four outcomes: both agree (pass); `bin/rig` accepts and
   λRig's `run` faults (a soundness bug: fail loudly); `bin/rig` accepts
   and λRig rejects but runs clean (λRig stricter, as with a bare name
   of a box: recorded in an allowlist, like `test/oracle/differences`);
   `bin/rig` rejects and λRig accepts (`bin/rig` stricter: logged). It
   must stay under a minute.
4. **A generator** of random programs in the slice, printed as Rig
   source, run both ways in the same script with a fixed seed: the
   torture input's role, for ownership.
5. **Coverage grows with λRig**: each slice of formal/README.md's "Next"
   widens what the exporter accepts.

Cost: about four days of an agent's work: the exporter two, `lrig` and
the script one, the generator one. At first the slice covers a few
percent of the corpus, mostly test cases written for ownership; the
generator supplies the volume. The risk is the exporter's fidelity: a
mistranslation hides a disagreement, so it maps forms one to one and
rejects anything else.
