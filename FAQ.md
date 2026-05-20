# FAQ

Honest answers to questions that come up about Rig — including the
skeptical ones. If a sharp question isn't answered here, open an issue.
The shape of this file: pointed questions on the left margin, paragraph
answers below. No marketing voice; if a tradeoff is real, it gets named.

---

## Performance: only refcounted types? What about plain pointers?

The premise that Rig has only refcounted types is wrong. Rig has four
families of value handles:

1. **Plain by-value types.** `Int`, `Float`, `User`, `Vec(T)`, etc. —
   stack-allocated, zero indirection, lowered to plain Zig structs and
   values. The same generated code Zig would produce.
2. **Borrows `?T` / `!T`.** Read and write borrows — compile-time-checked
   references that lower to plain Zig pointers (`*const T` / `*T`).
   No refcount, no runtime cost. Most function arguments are borrows.
3. **Shared handles `*T`.** *This* is the `Rc<T>` case. You opt into it
   only when you actually need shared ownership — typically for a graph
   of nodes, a subscriber list, or a captured closure. Every refcount
   bump is visible at the source as `+x`, so you can see the cost where
   you pay it.
4. **Weak handles `~T` and `RawPtr` / `raw` blocks** for FFI and escape
   hatches that bypass Rig's ownership rules entirely.

The borrow checker does the same job Rust's does: the *common* case of
passing data around is by borrow, which compiles to a plain pointer.
Refcounting only kicks in when you ask for shared ownership with `*T`
— exactly where a Zig programmer would manually build an `RcBox` or
pass an allocator-tracked handle, except Rig checks it at compile time.

So "Zig-level performance" applies to the by-value and borrow-checked
code, which is most of any program. Where Rig spends extra cycles is
where Zig would too — at *shared ownership boundaries* — and there the
comparison isn't `Rc` vs raw pointer; it's `Rc` vs whatever ad-hoc
lifetime tracking the Zig programmer writes by hand. Usually a wash on
cycles and a win on bug count.

The honest gap: Rig V1 doesn't ship a unique-owned heap type (no
`Box<T>` analog yet) — single-owner heap goes through `*T` and pays
one refcount field of overhead. That's a known V1 ergonomics hole, not
a hidden cost; it shows up in source as `*T` like everything else.

---

## What's the deal with AI? The Zig community is pretty hostile to it.

The concern is legitimate. Generated code can look plausible while
hallucinating APIs, missing invariants, or bypassing review.

The honest description of how this project uses AI: GPT-5.5 and
Claude are used both as design-review peers — the way a senior
language-design reviewer might be consulted over email — and as
code, commit-message, and documentation drafters. AI output gets
merged. This FAQ entry was drafted by an AI, reviewed and revised by
a human maintainer, then committed. That's representative.

What makes that workable rather than the slop pipeline you're
worried about:

- **Hard gates that don't care where an idea came from.** The
  grammar must parse at the reviewed conflict count. Sema, effects,
  and ownership checks must accept it. The Zig backend must emit
  working code. The test suite must pass (1145 tests, 0 failing).
  A human maintainer approves every milestone and every commit.
- **A public audit trail.** Every milestone has a retrospective in
  [`docs/ROADMAP.md`](docs/ROADMAP.md). Every design checkpoint with
  GPT-5.5 is referenced by conversation ID in
  [`docs/INFLUENCES.md`](docs/INFLUENCES.md) and
  [`HANDOFF.md`](HANDOFF.md). AI suggestions that got rejected or
  reversed are recorded too — read them.
- **The language itself is structured against hidden effects.**
  Moves, clones, drops, captures, raw escapes, and failure
  propagation are explicit in the source and in the semantic IR. A
  proposal that quietly leaks a resource or aliases a non-Copy
  value has fewer places to hide than the same proposal in C or
  vanilla Zig.

Rig is not marketed as an "AI language." That framing reverses
cause and effect: the visible-effects thesis was the goal; AI
legibility falls out of it.

Judge the artifact: read the code, tests, grammar, IR, and
retrospectives. If those don't hold up, the project doesn't hold up.

---

## Why target Zig instead of LLVM?

Three reasons:

1. **Zig already solves codegen.** The optimizer, register allocator,
   linker integration, cross-compilation, and platform support are all
   under active maintenance by people who do that for a living. Rig
   doesn't compete with that work; it uses it.
2. **Zig 0.16 is a fast moving target with clean semantics.** `comptime`
   covers most of the meta-programming use cases Rig's `pre` lowers to.
   `defer` matches Rig's auto-drop discipline cleanly. Error unions
   match `T!`. The impedance match across the lowering boundary is
   high.
3. **Substrate independence.** Targeting Zig source (not Zig IR or
   LLVM IR) means Rig is decoupled from the backend's release cadence
   — if Zig moves to a new internal IR, Rig keeps working. If LLVM
   changes its C++ ABI, Rig doesn't notice. The cost is one extra
   compile step; the gain is independence.

The non-goal is also explicit: Rig is not trying to be a fast-path
to a custom backend. If Rig ever needed one, the IR is already
S-expression-shaped and amenable to a different lowering, but that's
a problem for several years from now, not V1.

---

## Why no garbage collector?

Three sources combine to make GC the wrong answer for Rig:

1. **The substrate is built on visible ownership.** Refcounting is
   visible as `*T` and `+x`/`-x`; auto-drop is visible as scope-exit
   defer; user-defined `drop` is visible as `drop self: !Self`. A GC
   would invalidate that — collection becomes invisible, and the
   visible-effects thesis collapses.
2. **The target is systems code.** Predictable latency, no stop-the-
   world pauses, no hidden allocation tracing. The same reasons Rust
   and Zig don't ship a GC.
3. **The cost of avoiding GC has shipped.** Refcounting + weak
   references + auto-drop + user `drop` + `Cell` for interior
   mutation cover the use cases that drive most managed-heap demand.
   Persistent collections (Clojure-style) are the one case where GC
   would help, and that's tracked in
   [`docs/INFLUENCES.md`](docs/INFLUENCES.md) §6 as a real open
   question — but the answer there is more likely a carefully
   designed substrate (arena? region? dedicated allocator?) than a
   wholesale GC.

Rig does ship a small trusted runtime (`*T` / `~T` refcount,
`Cell`, `Vec`, `Closure`, `Signal`) — that's the cost of avoiding GC,
and it's documented in `src/runtime.zig`. The runtime does not
allocate on a managed heap, doesn't trace, and doesn't pause; it's
the smallest set of primitives the substrate ladder requires.

The position is from [`docs/INFLUENCES.md`](docs/INFLUENCES.md) §10,
rule 4: "No GC, ever." That's intentionally absolute. If the project
ever needs to revisit it, the conversation has to start from
"everything we've built assumes no GC; what would actually need to
change?" — not from "let's add one."

---

## Why use Nexus instead of an off-the-shelf parser generator?

The short answer: because Rig's IR is a project contract, and the
parser generator has to emit the IR shape declaratively. Most existing
generators don't.

The longer answer:

- Rig's grammar files declare both the surface syntax *and* the IR
  action: each rule emits a specific S-expression node by name. That's
  the contract every later phase walks. Hand-written parsers and
  most generator outputs don't preserve that shape — they emit an AST
  type tree that needs translation.
- Nexus already existed before Rig as a sibling project. Building
  Rig on top of Nexus was strictly less work than picking another
  generator and bridging it to a hand-rolled IR layer.
- The tooling stays in one language family. Rig is in Zig; Nexus is in
  Zig; the generated parser is Zig. No C++ parser-generator runtime to
  vendor and no separate AST-walker code generator.

The cost: one project depends on another. The mitigation: Nexus is
self-hosted (it parses its own grammar), under active development for
its own sake, and the generated parser is a single `.zig` file that
could be vendored if Nexus ever paused. The conflict count
(`@conflicts = 75`) is tracked explicitly so any grammar change that
shifts it gets inspected.

---

## Why build yet another systems language?

Rig explores a specific point in the design space that Rust and Zig
don't sit at: Rust-like ownership and borrow checking with a smaller,
sigil-shaped surface, paired with the IR-as-contract discipline that
lets tools read code without re-deriving intent — and a Zig backend
so the codegen and platform work doesn't have to be re-solved.

Could that point have been reached as a Rust dialect or a Zig patch?
Probably not. The surface and the IR shape are too central to both
languages to retrofit. Rig started as a question: *if you were
allowed to redesign the surface around ownership and effect visibility,
what would you keep and what would you cut?* The substrate ladder in
[`docs/INFLUENCES.md`](docs/INFLUENCES.md) is the answer to date.

That doesn't make Rig the right choice for every project. For most
production code today, Rust or Zig is the right answer because they
ship now. Rig is worth your time if the visible-effects thesis
matters to your codebase, your team, or your tools — and if it
doesn't, Rust and Zig are excellent.

---

## Why visible-effect sigils? Aren't sigils controversial?

Sigils are bad when they are arbitrary abbreviations. Rig uses
them only for effects the reader should notice locally — and the
set is small and uniform:

- `<x` move
- `?x` read borrow
- `!x` write borrow
- `+x` clone,
- `-x` drop
- `*x` shared
- `~x` weak
- `expr!` propagate
- `@x` pin (reserved)
- `%x` raw access.

Each one has one meaning. Each one shows up in the IR as a named
node. The alternative — words like `move`, `borrow`, `clone`,
`drop`, `propagate` at every site — produces longer code without
adding clarity once the reader has internalized the sigil set.

The bet is that systems programmers will internalize ten sigils
faster than they will write `clone(x)` ten thousand times.

---

## Why indentation-sensitive syntax?

Indentation-sensitive syntax is divisive — Python and CoffeeScript
fans love it; C-family programmers hate it. Rig picked indentation
because:

- It's the smallest surface for nested blocks. No `{ }` ceremony.
- It maps cleanly to S-expression structure (each indented block is
  a `(block ...)` form in the IR).
- The lexer's INDENT/OUTDENT tokens are a stable, well-understood
  pattern (inherited from Zag, the predecessor language).

The cost: editors and tools have to understand significant
whitespace. Most modern editors do; Rig's grammar is unambiguous
about indentation rules.

If indentation-sensitive syntax is a deal-breaker for you, Rig
isn't the right language for your codebase. Rig chooses that
tradeoff deliberately.

---

## Is Rig safe like Rust?

Rig is trying to make a Rust-class safety bargain for the subset it
checks: ownership, moves, borrows, refcounted handles, drops, raw
escape, and retained closures are all tracked by the front end before
lowering to Zig.

It is not Rust, and it is not production-ready. The guarantee is only
as strong as Rig's checker and the trusted runtime. `raw` blocks,
`extern` calls, and the generated runtime are explicit trust
boundaries. The position is "safe Rig unless you cross a marked raw
boundary" — not "everything that reaches Zig is magically safe."

---

## Why no traits or interfaces in V1?

Because the substrate has to ship first. Traits add an enormous
amount of surface area — coherence rules, dispatch, blanket impls,
trait objects — and every one of those decisions interacts with
ownership, effects, and lowering in ways that need a settled
substrate to reason about.

The V1 substrate is now settled (Layers 0–7.8 of the substrate
ladder in `docs/INFLUENCES.md`). Traits are a real candidate for
post-V1 work, but with two design constraints already in place:

1. Whatever the surface looks like, it has to preserve the
   visible-effects thesis. Trait method calls can't hide ownership
   transfers.
2. The IR has to gain a corresponding tag set so trait dispatch
   shows up in the IR tree the same way calls and method dispatch
   do today.

Until those are designed, Rig provides struct methods, generic
types, and pattern matching. That covers a lot of the use cases
people reach for traits for.

---

If you have a sharp question that isn't answered here, open an
issue on the repository. Skeptical questions are welcome — they
keep the design honest.
