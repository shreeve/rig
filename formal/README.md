# formal: λRig in Lean

This directory holds the machine-checked side of Rig: λRig, the core
calculus of the ownership model (docs/CORE.md), written in Lean 4, with
an interpreter, an ownership checker, and a proof that every program the
checker accepts runs without a fault. The plan it follows is
[FORMAL-RIG](../docs/FORMAL-RIG.md), "Assurance: four stages of proof";
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

`lake build` checks every proof and runs every example program. Every
warning is an error. Run it after changing `formal/`.

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
| `LambdaRig/Examples.lean` | Programs, whether the checker accepts each, and how each run ends |

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
AGENTS.md rule 3, "safe code cannot corrupt memory", for this slice. A
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

**`Examples.lean`**: eleven programs, each with whether `check` accepts
it and how its run ends. Four are accepted and end well; seven are
rejected, and each stops at the fault its rejection prevents.

## What is not proved

- **That `bin/rig` agrees with `check`.** `check` is written for
  λRig, not taken from `src/ownership.zig`. It is stricter than
  `rig check` in places: it rejects a bare name of a box, which Rig
  reads in place. The link
  is stage 3's validator, or running λRig beside the oracle (below).
- **That the emitted Zig does what λRig does.** Zig has no formal
  semantics; the test suite and the sanitizer stand in for it.
- **Anything outside the slice:** objects, optionals, `List`,
  functions, `*T`, `~T`, `Cell`, loops.

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
