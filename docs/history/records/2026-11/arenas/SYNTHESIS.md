# Arenas: synthesis and decisions (2026-11-21)

The owner's question: Rig has no arena, but it could, since it compiles to Zig; how
would a language that never speaks of allocation gain one? A panel of three answered,
read only: ownership and soundness ([ownership.md](ownership.md)), runtime and Zig emit
([runtime.md](runtime.md)), language design and prior art ([design.md](design.md)), from
[brief.md](brief.md). Their probes are in `probes-*/`.

## The answer

An arena is **a value the program holds, not an allocator it names**. Nothing about
allocation is written; what is written is where values go and how long they live, as for
everything else in Rig.

```text
use std.arena

obj Node
  left: (?Node)?
  right: (?Node)?

fun make(a: !*arena.Arena[Node], d: Int) -> ?Node from a
  if d == 0
    return !a.add(Node(left: none, right: none))
  l = make(!a, d - 1)
  r = make(!a, d - 1)
  !a.add(Node(left: l, right: r))

sub main()
  a = arena.Arena[Node].new()
  print(check(make(!a, 21)))
  # a's last handle drops here: every node freed in one step
```

- `!a.add(x)` moves `x` into memory that never moves and gives a read view `?T` from `a`.
- An arena is a cell (CORE sentence 9), so a write view of it leaves its place read-only:
  adds go on while earlier views are in use. A value that holds a cell lives only behind
  `*`, so an arena is `*Arena[T]`, as `std.shared.Map` is `*shared.Map[K, V]`
  (std/shared.rig:28-35), the precedent for memory that grows without moving.
- Escape is CORE sentences 5 to 7, with no lifetimes and no new kind of value: a function
  returns arena views only `from` an arena passed in; an owner that keeps one keeps the
  arena limited; a task that reads one keeps the arena from dropping until `>t`.
- `T` copies (CORE §1): plain data and read views. Nothing in an arena needs a drop, so
  dropping it is one free.
- No call empties an arena: a marked call is accepted while its views live, so a
  `!a.reset()` would leave them dangling. An arena is emptied by dropping or reassigning
  it, which sentence 5 refuses while its views live.

The one rule CORE changes: CORE §5 says "a value never holds a view of itself". An
arena's values may view one another, and the arena keeps those views. All three experts
named this the risk: wrong one way, every linked structure is rejected; wrong the other,
a dangling view is accepted. It is built first, with cases both ways in the reference
checker and the Lean model.

Implementation (runtime.md): arena memory in an address range of its own, as Tables'
is, so a free of arena memory is a range compare that does nothing, and no List or box
stores an allocator; drop glue that only frees memory is skipped; under `RIG_SANITIZE` a
use after the arena drops crashes at the access.

## Set aside, and why

- **Inferred regions (ML Kit).** Where memory is freed would change with edits far away,
  against "the costs are where the sigils are" (DESIGN.md:250); CORE §10 makes rules
  follow a value's type, not where it came from; in a loop it can turn steady memory into
  memory that only grows.
- **A block that makes an arena current (Odin, Jai, Go's arenas).** The runtime expert's
  first choice, refused by the other two on soundness: an outer `List` that first grows
  inside the block points into freed memory after it, and the same `List` would mean
  different things inside and outside (CORE §10). Go shelved its arenas in 2023 because
  they spread into every API; Rust's `allocator_api` has stayed unstable for years.
- **A new sigil.** `!` marks the add, `?T` from `a` the tie, the handle's scope end the
  release.

## Corrected evidence

The fast binarytrees port reuses one pool (`!pool.keep(0)`, binarytrees-fast.rig:40), so
after its first tree it allocates nothing per node and an arena gains it nothing; its 6%
gap on pup has another cause. The gap an arena answers is the plain port's: on the Mac,
Rig's plain `--release` takes 877 ms against 408 ms for Rust's plain port, which uses
typed-arena (compare/rig/benchmarksgame/results.md:161-172, in the owner's comparison
folder, which is kept beside the checkout and not in the repository). The runtime expert estimates
the plain port with an arena at 0.35 to 0.45 s, an estimate, not a measurement.

## The owner's decisions (2026-11-21)

Approved as proposed:

1. An `Arena[T]` value with `!a.add(x)` giving a `?T` from `a`; inferred regions and a
   block that makes an arena current, set aside.
2. First stage: only types that copy, so nothing in an arena needs a drop; slices of `T`
   copied in (`!a.copy(xs)`). Values whose drop must run wait for a program that needs
   them.
3. Typed `Arena[T]` first; an arena of several types waits for a program. The name is
   `Arena`, the owner's choice over `Region`: it is Rust's `typed_arena::Arena<T>`, whose
   `alloc(x)` gives `&T`, and "region" means a lifetime to a Rust reader
   (BEYOND-RUST.md:45). Std's `Arena` shares a name with Trig's `pub obj Arena[T]`
   (src/core/arena.rig:60, the port of tsc's index-based arena); one is renamed, or std's
   stays out of the prelude.
4. The CORE paragraph written now, planned, with a pending example; the self-view rule
   built first, with cases both ways; Trig's share of cycles in the allocator and drop
   glue, and of data that dies together, measured before the type is built.
5. docs/IDEAS.md's entry moved to the ROADMAP, citing the plain port.

One change from what the synthesis first said: it gave the arena as an owned value,
`a = Arena[Node]()`, with `*Arena` only for sharing, and `<a.reset()` to empty one. CORE
sentence 9 puts every value that holds a cell behind `*`, and a reset call is unsound,
so the CORE paragraph and the ROADMAP say `*Arena` and no reset; the owner confirms this
on the PR that records it.

## Open risks

- The self-view rule (above).
- `keeps` on std's `add` is trusted, not checked (`marked_externs`), so the std
  implementation is itself a proof obligation, with a sanitizer test that changes places
  outside while arena views live.
- Arena values are read views, so an arena holds graphs finished before they go in; data
  that changes while it lives stays in `List` or `Table` pools.
- A view is 8 bytes where Trig's ids are 4, so arenas will not replace Trig's id-based
  tables for data shared across files; their likely win in Trig is per-pass temporaries.
