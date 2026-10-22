# rust-soundness

## Parity means
RustBelt proves λRust, a model with explicit lifetimes, sound, and proves models of Arc, Rc, Cell, Mutex and the like semantically well typed. Nobody has proved that rustc matches λRust, and LLVM is trusted; the rest is belief, backed by Miri. For Rig, parity means three things: a proved λRig, a lemma for every Zig-backed declaration, and evidence that links the compiler to λRig.

## Must build
1. **Check each program against λRig** (large). The compiler or the oracle prints the core with explicit loan ends, and a small checker written in Lean validates it. Rust has no such link.
2. **Semantic specs for runtime.zig and std/*.zig** (medium per type). They are Rig's `unsafe` standard library. #41622, the MutexGuard Sync bug, was in this layer.
3. **Two thread facts** (small, before concurrency). "May move across threads" (Send) and "may be read from two threads" (Sync) are separate facts. Each Zig-backed type declares both.
4. **An aliasing model, like Tree Borrows, before `noalias`** (medium). Otherwise LLVM's `noalias` miscompiles (#54878) become Rig's bugs.

## Leave out, and it dissolves
- **Lifetime parameters, variance, and higher-ranked bounds** (#25860, #84591). The proof needs no lifetime inclusion. Users use `from` and `keeps`.
- **Specialization** (#40582). Users lose some fast paths.
- **dyn over traits with associated types or generic methods** (#57893). Trait values (R3) take only traits that are object-safe by their shape.
- **Pin and self-views** (#66544). Users use arenas and IDs.
- **#[may_dangle]**. "Drop reads views" is transitive through List, optionals, `*T` (probed). A Zig container that hid its T would repeat the PhantomData bug.

## Proof obligations
- Stage 3: progress and preservation, over loan sets, `from`, `keeps`, closure captures, and Cell only behind `*`. Generics are checked per instance, so no polymorphism is needed.
- Stage 4: Iris is affine, so the proof shows no undefined behavior and no use-after-free, not leak freedom.

## Disagreements
- RUST-TRIAGE says concurrency needs no Send or Sync. It needs both facts, though not as traits. Deriving them from parts alone caused #41622.
- "Leaks are compiler bugs" is tested, not proved. `*T` cycles leak (#24292), so scoped threads must join through a closure, never through a guard's drop.
- Yielding projections and async make self-referential frames. Forbid loans across a suspension, or keep frames in boxes that never move.
- `noalias` waits for must-build 4.
