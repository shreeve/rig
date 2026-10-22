# formal-methods

## Parity means
A Lean-checked theorem that every program the checker accepts, per instance, runs with no use after move or free, no change seen through a read view, no double drop, and no leak but `*T` cycles; plus a mechanical link to `bin/rig`, which RustBelt lacks.

## Must build
1. **λRig = the oracle's core** (test/oracle/core.zig) in Lean: objects, optionals, List as a primitive buffer, `^ * ~`, Cell, views, slices, paths, drop flags, defer, `e!`, first-order functions with `from`/`keeps`, `?fun`, loan-free `*fun`. Omit sugar, generics, modules, text. 2–3 PM.
2. **An instrumented interpreter** (Miri / Tree Borrows style): each view carries its loan's tag; writing the owner kills read tags; a dead tag is stuck. Run the whole suite, corpus and matrix in it. It catches what the sanitizer cannot: a read view seeing a change with nothing freed (Core s4). 3–5 PM.
3. **Soundness of λRig**: progress and preservation over that interpreter, Oxide-style (Weiss et al. 2019). 12–24 PM; leak freedom adds 3–6.
4. **Checker certificates**: ownership.zig exports per-function loan sets (`rig check --facts`); a Lean validator checks them against λRig's rules. 4–6 PM.
5. **Specs for std's Zig-backed primitives** (List, String, Map, `*`/`~`, Cell, Signal), each proved against a λRig model. 6–12 PM.

## Leave out, and it dissolves
- **User raw pointers.** Iris serves open-world unsafe code; with std the only unsafe code, stage 4 shrinks to item 5 (36–60 PM to 6–12). Users lose custom low-level containers; they use arenas with IDs.
- **Polymorphic ownership checking.** Keep per-instance checks after bounds (R2): no variance, no HRTB (#25860).
- **Guard-based scoped threads**: cycles leak, so joins never rely on drops (#24292).
- **Coroutine projections.** Define `yields !T` as a lent `?fun(!T)`; no new proof.

## Proof obligations
Stage 3: `from`/`keeps` summaries sound (s7, the crux); drop bodies read only held views (s6); no loan enters a no-loan home (s9); no self-view (§5); every scope exit reports its loans; proven checks hold.

## Disagreements
- A third *static* checker repeats two we have; make stage 2 dynamic.
- Iris is affine and cannot prove Rig's leak claim; use Iron (Bizjak et al., POPL 2019) or syntactic heap accounting.
- The proof is not "Might want" (RUST-TRIAGE): stage 2 is "Should add soon", and `noalias` waits for it, as it makes checker bugs miscompiles.
- emit.zig, runtime, Zig and LLVM stay trusted, checked by matching output against the interpreter.
