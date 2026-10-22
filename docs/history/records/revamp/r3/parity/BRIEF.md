# Parity panel brief: what Rig needs to be on par with Rust

The owner wants a document (docs/FORMAL-RIG.md) listing everything Rig
needs to stand on par with Rust, in two senses:

1. **Assurance**: Rust's ownership model has had ten years of expert attack
   and a machine-checked proof (RustBelt: lambda-Rust in Iris/Coq, semantic
   types, a lifetime logic, proofs that std libraries using `unsafe` are safe).
   What would make Rig's safety claim as trustworthy?
2. **Expressiveness**: what real programs (a tsc port, a GPUI-class
   graphical engine, servers) can Rust write that Rig cannot, structurally?

Key idea from the owner: Rig may **choose not to build** some Rust features,
esoteric or proof-hostile ones, and thereby **dissolve** the verification
problem instead of solving it. Every "leave out" needs a reason and a
statement of what users lose and how they cope.

## Read first (in ~/Data/Code/rig)
- docs/CORE.md (the ownership model; long, skim its structure, read what your area needs)
- docs/RUST-TRIAGE.md (the existing plan: take / leave, already sorted; build on it, do not repeat it)
- docs/BEYOND-RUST.md, docs/ROADMAP.md
- AGENTS.md (rules: accept means correct, effects visible, raw is narrow)
- Skim SPEC.md / docs/INTERNALS.md only where your area needs it (INTERNALS has the oracle, bin/rig-oracle, and the semantic IR).

Known structural gaps today: no traits/bounds/dyn dispatch (methods only in
the declaring module; generics checked per instance); a value never holds a
view of itself (graphs use `*T`/`~T` or arenas with IDs); coarse view
lifetimes (`from a`, `keeps`, no lifetime params, at most one write-view
result); escaping closures must be `*fun`; no raw pointers / C extern types /
global mutable state / custom allocators; `drop` only on non-generic objects;
no macros, derive, or comptime functions (comptime params are Int only); no
concurrency or async. Rig compiles to Zig 0.17, so Zig and Rig's runtime
are trusted code.

Current formalization idea (staged): (1) paper rules for the Core;
(2) an executable semantics in Lean 4 used as an oracle against the compiler;
(3) a soundness proof of a core calculus (lambda-Rig) in Lean;
(4) RustBelt-scale semantic proof covering `raw` libraries (Rocq+Iris, or iris-lean).

## Your output
Write **at most 400 words** to `.git/revamp/r3/parity/<your-key>.md`, under
these headings:
- **Parity means** (in your area, one or two sentences)
- **Must build** (ranked; each: what, why, rough size)
- **Leave out, and it dissolves** (each: the Rust feature, the proof or
  complexity it removes, what users lose, how they cope)
- **Proof obligations** (what a soundness proof in your area must show; which stage)
- **Disagreements** (where you think the current plan or RUST-TRIAGE is wrong)

Rules: do not edit any repository file other than your output file. Rig
vocabulary: never say "borrow" (say loan, lend, view); a Rig `obj` is an
"object", never a "struct". Be concrete; cite CORE.md sections or Rust issue
numbers when you rely on them. Your reply to me: at most 120 words, the
three points you most want in the final document.
