# Rig Roadmap (V1)

A new systems language that transpiles to Zig.

## Mission

Build the language we'd want to write systems code in: **Zig-fast, Rust-safe, Ruby-elegant**, with explicit ownership, visible effects, and a Lisp-clean intermediate representation.

## Architecture

```
Rig source
  → Nexus parser           (rig.grammar + src/rig.zig)
  → raw S-expressions
  → semantic normalization (src/normalize.zig)
  → ownership checking     (src/ownership.zig)
  → Zig emission           (src/emit.zig)
  → zig build              (Zig 0.16 backend)
```

Rig owns ownership analysis, semantic normalization, and lowering.
Zig owns the optimizer, codegen, linker, and platform support.

## Milestones

### M0 — Parser online
- `rig.grammar`, `src/rig.zig`, `build.zig` written.
- `bin/rig parse examples/hello.rig` emits raw S-expression.
- Golden snapshots locked for hello + the 6 SPEC §V1 test cases.
- Spacing-sensitivity goldens for sigils.
- **Done:** parser conflict count ≤ 25 (Zag is 19; budget +6 for sigils + bindings).

### M1 — Semantic normalizer
- `src/normalize.zig`: raw Sexp → semantic IR per SPEC §"Semantic IR Nodes".
- `docs/SEMANTIC-SEXP.md` documents the IR.
- Golden snapshots in `test/golden/semantic_sexp/`.
- **Done:** every example normalizes to a stable, hand-readable IR.

### M2 — Ownership checker
- `src/ownership.zig`: implements SPEC §"Ownership Checker V1" + §"V1 Test Cases".
- Errors are source-pointed and sigil-aware.
- **Done:** every SPEC V1 test case passes/fails as specified.

### M3 — Zig emitter
- `src/emit.zig`: semantic IR → Zig 0.16 source (Juicy Main, `std.Io`, packed `PROT`, no `GeneralPurposeAllocator`).
- Boring lowering first; clever later.
- Golden snapshots in `test/golden/emitted_zig/`.
- **Done:** emitted Zig passes `zig ast-check` for every example.

### M4 — `rig` binary
- `rig parse | normalize | check | build | run` all functional.
- `examples/hello.rig` compiles and runs end-to-end.
- **Done:** `bin/rig run examples/hello.rig` prints "hello".

## Beyond V1 (deferred per SPEC §V2/V3)

Async, advanced shared ownership, allocator traits, reflection, full trait/interface system, advanced lifetime inference, richer pre-metaprogramming.

Parsed-but-lightly-enforced for V1: shared, weak, pin, unsafe/raw.

## Non-goals

- LLVM backend (Zig handles it)
- Garbage collection (ownership instead)
- Macro system (favor `pre` + library design)
- Trait system V1 (deferred)
