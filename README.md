# Rig

A systems programming language with **Zig-level performance**,
**Rust-inspired ownership safety**, and a **small, expressive
surface syntax** — designed so the effects that matter for reliable
systems code are visible in the source and preserved as first-class
facts through the entire compiler pipeline.

## Thesis

Rig is built around two complementary invariants:

1. **Important effects are visible directly in the syntax.**
   Ownership transfer (`<x`), borrowing (`?x` / `!x`), cloning
   (`+x`), dropping (`-x`), shared / weak handles (`*x` / `~x`),
   failure propagation (`expr!`), compile-time specialization
   (`pre`), capture modes (`|+x|` / `|<x|` / `|~x|`), and the
   raw-escape boundary (`raw` block) are all spelled in the source.

2. **Visible source effects survive as visible semantic Tags
   through lowering.** The IR (`docs/SEMANTIC-SEXP.md`) carries
   each effect as a first-class node the checkers and emitter
   consume by name. Tools that read Rig's semantic IR see the
   same facts the compiler does, without speculation.

The combination — a small systems language where ownership,
mutation, failure, compile-time, capture, and unsafe boundaries
are all syntactic *and* semantic facts, lowered to a real Zig
backend — is what Rig is for.

## Pipeline

```
Rig source
  → Parser                 (rig.grammar + src/rig.zig)
  → semantic IR            (S-expressions; effects as first-class Tags)
  → effects checker        (src/effects.zig)
  → ownership checker      (src/ownership.zig)
  → Zig emitter            (src/emit.zig)
  → zig build              (Zig 0.16 toolchain)
```

Rig owns lexing, parsing, normalization, semantic checking, and
lowering. Zig owns the optimizer, codegen, linker, and platform
support.

## Status

V1 substrate is complete through Phase B (Layers 0–7 of the
substrate ladder in `docs/INFLUENCES.md` §1). The reactive
primitive `Signal(T)` ships with PB4-relaxed reentrancy semantics.
The reactive canary (`examples/reactive_canary.rig`) exercises the
full Cell + closure + Vec-iteration + Signal chain end-to-end.
**982 tests passing, 0 failing.**

See `HANDOFF.md` for current state and non-negotiable invariants,
`docs/ROADMAP.md` for milestone history, and `docs/CHECKLIST.md`
for per-milestone tracking.

## Quick example

```rig
sub main()
  count: *Cell(Int) = *Cell(value: 0)
  bump = |+count|
    count.set(count.get() + 1)
  bump()
  bump()
  print(count.get())                # 2
```

`*Cell(Int)` is a heap-allocated, reference-counted, interior-
mutable Int cell. `|+count| body` is a stack-local closure that
captures `count` by clone (the `+` makes the refcount bump
visible). The closure is invoked twice; auto-drop at scope exit
releases both references.

## Documentation

| File | Purpose |
|---|---|
| [`AGENTS.md`](AGENTS.md) | Compass for AI sessions working on Rig — read first |
| [`HANDOFF.md`](HANDOFF.md) | Current state, non-negotiable invariants, forward-arc menu |
| [`SPEC.md`](SPEC.md) | Language spec — the canonical reference for syntax and semantics |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Milestone history (M0 → PB4 done), V1.x tooling, forward arcs |
| [`docs/CHECKLIST.md`](docs/CHECKLIST.md) | Per-milestone implementation checklists |
| [`docs/SEMANTIC-SEXP.md`](docs/SEMANTIC-SEXP.md) | IR shape and the lowering invariant |
| [`docs/REACTIVITY-DESIGN.md`](docs/REACTIVITY-DESIGN.md) | Phase B design north star (`Cell` / `Memo` / `Effect`) |
| [`docs/INFLUENCES.md`](docs/INFLUENCES.md) | Design lineage, substrate ladder, and strategic rules |

## Building and running

```bash
zig build                                   # builds bin/rig
./test/run                                  # full test suite
bin/rig parse     examples/hello.rig        # raw S-expressions
bin/rig normalize examples/hello.rig        # semantic IR
bin/rig check     examples/hello.rig        # effects + ownership
bin/rig build     examples/hello.rig        # emit Zig
bin/rig run       examples/hello.rig        # build + execute
```

## Non-goals

- **LLVM backend** — Zig handles it.
- **Garbage collection** — ownership replaces it. (`docs/INFLUENCES.md` §10 rule 4: "No GC, ever.")
- **Macro system** — `pre` plus library design covers the V1 use cases.
- **Trait system V1** — deferred.
- **Marketing as "the AI language"** — Rig is a contract for human and tool consumption. The visible-effects thesis is what makes Rig useful to AI workflows; the language remains a systems language, not a generation target.

## Status of this repo

Rig is in active design and implementation. The substrate is
locked through Phase B; the next forward arcs are Steve-driven
and tracked in `HANDOFF.md` §13. Design checkpoints with GPT-5.5
(via the `user-ai` MCP) are part of the cadence — see
`docs/INFLUENCES.md` for the design conversation provenance.
