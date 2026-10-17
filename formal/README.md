# formal: λRig in Lean

This directory holds the machine-checked side of Rig: λRig, the core
calculus of the ownership model (docs/CORE.md), written in Lean 4,
with an interpreter for it and the proofs about it. The plan it follows
is [FORMAL-RIG](docs/FORMAL-RIG.md), "Assurance: four stages of proof";
this is the start of stage 2.

## Build

Lean comes from elan, which reads the version from `lean-toolchain`
(Lean 4.35.0). There are no other dependencies.

```bash
brew install elan-init
```

```bash
cd formal && lake build
```

`lake build` checks every proof and runs every example program. It
passes only if each proof is complete (no `sorry`) and each example
ends the way its `#guard_msgs` says.

## Layout

| File | What it holds |
|---|---|
| `LambdaRig/Syntax.lean` | Values and expressions; each constructor names the Rig form and the CORE sentence it stands for |
| `LambdaRig/Machine.lean` | Cells, the loans live on each, the five ways to touch a cell, and the faults |
| `LambdaRig/Interp.lean` | `eval`, an interpreter that tags every view with its loan, and `run` |
| `LambdaRig/Loans.lean` | CORE sentence 5 on the machine, for one cell and for every state `eval` reaches |
| `LambdaRig/Examples.lean` | Programs and how each run ends |

## What the first slice covers

One kind of owner, a box holding an Int (`^Int`), and plain Ints. Every
binding is a place, so a number can be lent too. The forms are a bare
name, `<x` as a value and as a statement, `+x`, `^e`, `?x`, `!x`,
assignment (through a write view, it writes what the view sees), `+`,
`print`, sequencing, and a scoped binding.

The interpreter checks nothing ahead of time. It runs a program and
stops at the first broken promise: a use after move or free, a view
used after its loan ended (`deadTag`), or a leak at the end. A view
carries the tag it was lent under; a cell keeps the tags still live on
it. A read by the owner ends a write loan, a write by the owner ends
every loan, and a write lend ends every other loan.

`Examples.lean` runs ten programs: four that end well, and six that
`rig check` rejects, each stopping at the fault its rejection prevents.

`Loans.lean` proves:

- each way to touch a cell leaves it with read loans or one write loan,
  never both, and the lends end the loans CORE says they end;
- `Keeps.eval`: for every expression, if `eval` succeeds from a machine
  whose cells are all well formed, every cell of the machine it ends in
  is well formed too.

That theorem is the easy half of sentence 5: the machine is built so
no step can break it. The hard half is stage 3: that a program `rig
check` accepts never stops with `deadTag`, `moved`, `freed`, or `leak`.

## Next

The slices, in order; each grows `Syntax`, `Interp`, and `Examples`
together, and keeps `Keeps.eval` proved:

1. Objects with fields, and paths into them.
2. Optionals and `e?`; `e!` and `defer`.
3. `List` as a primitive buffer, and slices.
4. First-order functions with `from` and `keeps`.
5. `Cell`, `*T`, and `~T`.
6. Loops, with fuel so `eval` stays total.

After those, the interpreter runs the suite, the corpus, and the matrix
beside `bin/rig-oracle`, and replaces it over time (FORMAL-RIG, decision
6). Whether stage 3 is done in Lean or in Rocq with Iris is decided when
it starts.
