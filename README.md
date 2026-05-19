# Rig

Rig is a systems language that compiles to Zig while keeping
important effects visible in the source. Moves, borrows, clones,
drops, shared ownership, failure propagation, compile-time
execution, closure captures, and raw escape boundaries all have
explicit forms — and the semantic IR preserves them as first-class
nodes through checking and lowering. The aim is small, readable
code with Rust-like resource discipline: when ownership moves,
failure propagates, or mutation happens, you can see it where it
happens.

> **Status: pre-release compiler prototype.** Rig has a working V1
> ownership / resource substrate and synchronous reactive canaries.
> A standard library, async, structured concurrency, package
> ergonomics, and full FFI ergonomics are still in progress. **1125
> tests passing, 0 failing** on `main` as of M30. Expect breaking
> changes.

## Examples

Three short programs, each a little richer than the one before.

### A first taste

```rig
sub main()
  print "hello, rig"
```

Blocks are indented, not braced. `sub` is a routine; `print`
doesn't need parens when there's one argument. Most Rig code looks
roughly like this — no sigils in sight.

### A function and a borrow

```rig
struct User
  name: String

fun label(user: ?User) -> String
  user.name

sub main()
  u = User(name: "Ada")
  print(label(?u))
```

Output: `Ada`

`fun` is a function that returns a value; `sub` doesn't. The `?`
in `?User` says `label` only borrows the user for reading — it
can't change `u` or take ownership of it. The same `?` shows up
at the call site too, so the caller can see that `u` is loaned,
not handed over.

### Resources and cleanup

```rig
struct Owner
  cell: *Cell(Int)

  drop self: !Owner
    print(self.cell.get())

sub main()
  c: *Cell(Int) = *Cell(value: 42)
  o: Owner = Owner(cell: <c)
  print(0)
```

Output:

```
0
42
```

`*Cell(Int)` is a shared, counted handle to an `Int` — the `*`
marks shared ownership in the type. `<c` moves the handle into
the new `Owner`; after that line, `c` is gone, and the compiler
will tell you if you try to use it. `drop self: !Owner` is your
cleanup code — it runs automatically when an `Owner` falls out of
scope, and the `!` gives the body exclusive access to the value.
When `main` returns, Rig runs your `drop` first (printing `42`,
the cell's value at that moment), then releases the `*Cell`
handle. No GC, no finalizer queue — just lexical scope and
visible effects.

## Why Rig exists

- **Rust** proved that ownership can work as a mainstream systems
  discipline, but many effects are visible primarily in signatures
  and trait implementations rather than locally at the call site.
- **Zig** provides low-level control and excellent compilation,
  but it intentionally leaves aliasing and lifetime discipline to
  programmer convention.
- **Reactive and dynamic languages** are expressive about state
  change and dependency tracking, but they hide mutation, lifetime,
  and scheduling under runtime machinery.

Rig's bet: **make the effects that matter cheap to write and hard
to miss.** The checker enforces them. The IR preserves them. The
Zig backend lowers them.

## The two invariants

Everything in Rig follows from two design rules:

1. **Important effects are visible directly in the syntax.** No
   inferred ownership transfers, no hidden refcount bumps, no
   silent compile-time evaluation, no unmarked raw regions. Each
   effect has a short marker — usually a sigil, sometimes a small
   keyword.

2. **Visible source effects survive as visible semantic Tags through
   lowering.** The semantic IR (a normalized S-expression tree
   documented in [`docs/IR.md`](docs/IR.md))
   carries each effect as a first-class node that the checkers and
   emitter consume by name. Tools that read the IR see the same facts
   the compiler does, without speculation.

These two rules are what [`AGENTS.md`](AGENTS.md) calls "the thesis." Every
language feature is graded against them.

## Visible effects

Ownership sigils. Most add no runtime ownership bookkeeping;
checking is static. Reference-count allocation and bumps only
appear when you opt into shared ownership with `*T` / `*x` and
explicit clones. The default idiom — owned values, borrows, and
explicit moves — has the same cost shape as Rust/Zig: large value
moves may still copy bits, but there is no hidden lifetime runtime.

| Syntax | Meaning | Runtime cost | Rust analog |
|---|---|---|---|
| `<x` | move (transfer of ownership) | no ownership bookkeeping; value move may copy bits | move / `std::move` |
| `?x` / `?T` | read borrow | no runtime bookkeeping; statically checked | `&T` |
| `!x` / `!T` | write borrow | no runtime bookkeeping; statically checked | `&mut T` |
| `+x` | clone | type-defined; refcount bump for shared handles; no clone glue for `Copy` | `Clone::clone` |
| `-x` | drop now (early release) | runs destructor / drop glue immediately | `drop(x)` |
| `*x` / `*T` | shared `Rc` construction / type | allocation on construction; explicit `+` clones bump the non-atomic V1 refcount | `Rc::new` / `.clone()` |
| `~x` / `~T` | weak handle construction / type | weak-count bump on construction / clone | `Rc::downgrade` |
| `%x` (in `raw`) | raw pointer access | no ownership bookkeeping; safety is inside the raw boundary | `*const T` / `*mut T` |

Other visible effects — control flow, compile-time, captures, and
the audit boundary:

| Syntax | Meaning |
|---|---|
| `expr!` | propagate failure (postfix `!` on a `T!` type) |
| `pre` | compile-time execution / specialization |
| `\|+x\| body` / `\|<x\| body` / `\|~x\| body` | closure capturing `x` by clone / move / weak |
| `raw` block | unsafe escape boundary (block-only); guards `%x` and unaudited builtins / extern calls |

Each effect is enforced by the ownership checker, the effects
checker, or both, and appears in the IR as an explicit node —
`(move src)`, `(clone src)`, `(drop x)`, `(propagate expr)`,
`(raw_block body)` — that downstream tools can read without re-
deriving intent. Borrows and moves lower to plain Zig; the safety
is in the checker, not the codegen. Refcounted handles compile to
a small `RcBox(T)` / `WeakHandle(T)` runtime; everything else goes
straight to Zig's optimizer.

## Pipeline

```
Rig source
  → Nexus-generated parser     (rig.grammar → src/parser.zig)
  → semantic IR                (S-expressions; effects as first-class Tags)
  → semantic checks            (types/sema, effects, ownership)
  → Zig emitter                (src/emit.zig)
  → zig build                  (Zig 0.16 toolchain)
  → native binary
```

Rig owns lexing, parsing, normalization, semantic checking, and
lowering. Zig owns the optimizer, codegen, linker, and platform
support. Rig does not compete with Zig's backend; it uses it.

## Reactive substrate

Rig's substrate is strong enough to implement reactive systems
without a garbage collector and without language-level reactivity
built in. The reactive canaries are ordinary Rig code built from
lower-level primitives:

- `Cell(T)` for interior mutation (typically held as `*Cell(T)` when shared),
- `*T` / `~T` for shared / weak ownership graphs,
- `*Closure()` for retained zero-argument subscriber callbacks,
- `Vec(*Closure())` for subscriber lists,
- user-defined `drop self: !Self` for resource cleanup,
- multi-capture closures (`|+a, +b| body`) for cross-source
  dependencies.

Working canary (compiles and runs today; full source in
[`examples/m28_multi_capture_cascade.rig`](examples/m28_multi_capture_cascade.rig),
including the `IntSource` definition):

```rig
sub main()
  count = IntSource.new(0)
  total = IntSource.new(0)

  body_a: *Closure() = *Closure(|+count, +total|
    total.set(count.get() * 10))
  count.subscribe(+body_a)

  body_b: *Closure() = *Closure(|+total| print(total.get()))
  total.subscribe(+body_b)

  count.set(1)         # total becomes 10, prints 10
  count.set(7)         # total becomes 70, prints 70
  print(total.get())   # 70
```

The `count → total → print` cascade is not a special language
feature — it is ordinary Rig code built from `Cell(T)`, `*Closure()`,
`Vec(*Closure())`, multi-capture closures, and structural drop glue.

The Phase B reactive design is sketched in
[`docs/REACTIVITY.md`](docs/REACTIVITY.md).

## Powered by Nexus

The parser is generated by [Nexus](https://github.com/shreeve/nexus), a
sister project — a self-hosting LR parser generator that emits a single
self-contained Zig module from a `.grammar` file. The grammar is the
source of truth for both syntax and IR shape:

```
# rig.grammar (excerpt)
fun_type = FUN "(" L(type) ")" type    → (fun_type 3 5)
         | FUN "(" ")" type             → (fun_type _ 4)
```

Each grammar rule emits an explicit S-expression node, and the
emitted shape is what the rest of the compiler walks. There is no
hand-written parser, no parser runtime dependency, and no separate
AST type definition. For syntax-level changes, the first step is
usually a grammar edit plus sema and emit arms — not a hand-rolled
parser change.

This matters for two reasons:

- **The grammar stays honest.** Conflict count is tracked
  explicitly with `@conflicts = 75`; any grammar edit that drifts
  the count gets inspected.
- **The IR stays first-class.** The Zig side of the compiler reads
  `(fun_type ...)`, `(lambda captures params returns body)`,
  `(call callee args...)` etc. directly — the same tree future
  tools (linters, doc generators, semantic exporters, editor
  integrations) can consume without reimplementing the parser.

## What works today

Implemented and tested end-to-end:

- Static types, generics, generic enums, pattern matching.
- Ownership / borrow checking (moves, borrows, clones, drops) and
  auto-drop on scope exit via compiler-inserted defer guards.
- Reference-counted shared handles (`*T` ≈ `Rc<T>`) and weak handles
  (`~T` ≈ `Weak<T>`) with `upgrade()`.
- Interior mutability via `Cell(T)`, including `Cell` over non-Copy
  resource `T` with `replace` / drop-old-on-set semantics.
- Closures with explicit capture modes — both stack-local non-escaping
  and heap-owned `*Closure()` (zero-arg) — with multi-capture support.
- Resource-aware `Vec(T)` with iteration via `for x in ?vec` /
  `for x in <vec`.
- User-defined `drop self: !Self` with auto-generated structural drop
  glue; any type with drop glue is non-Copy by sema rule.
- Compile-time execution via `pre`. Failure propagation (`expr!` on
  `T!`) and option types (`T?`). `raw INDENT body OUTDENT` escape
  blocks. `extern` FFI declarations callable only from `raw` context.
- Reactive substrate (`Signal(T)` + a userland `IntSource` library
  running the multi-capture cascade canary).
- Cross-module sema honesty: `pub` is real; cross-module signature
  imports carry the same checked contracts as same-file.
- Zig 0.16 emission and `zig build` integration.

In progress / deferred:

- Real standard library (V1 ships with a small trusted runtime, not
  a stdlib).
- Body-less `extern fun` / `extern sub` declarations for ergonomic
  FFI; closures with arguments (`Closure1(T)`, `Closure2(A, B)`).
- Async, structured concurrency, executor (Layers 8–9 of the
  substrate ladder; intentionally deferred until the substrate is
  mature enough to support them safely).
- Trait / interface system; persistent collections; mature
  module/package model.
- Stable semantic export (`rig sema --json`) for tooling, not yet
  scheduled.

## Influences

Rig is its own language, but it borrows specific patterns from each
of these:

| Influence | What Rig takes |
|---|---|
| **Rust** | Ownership system, sigil-based borrow modes, `enum`/`match`, fallibility-as-effect, resource cleanup discipline, the lesson that "any type with drop glue is non-Copy." |
| **Zig** | The backend itself (Rig lowers to Zig 0.16). Compile-time execution (`comptime` → `pre`), error unions, no garbage collector, low-level pragmatism. |
| **Rip** | A CoffeeScript-to-JS sister project. Reactive ergonomics (`:=` / `~>`) deferred to a Phase C surface; Rig currently implements the lower-level substrate that future Rip-style sugar would lower into. |
| **Ruby** | Readability-first surface: paren-less calls (`puts "hi"`, `f arg1, arg2`), indentation-aware blocks, short keywords (`fun`, `sub`, `pre`, `raw`, `new`, `pub`). |
| **Lisp** | Not the syntax — the IR. Rig's normalized semantic representation is S-expression-shaped, and that shape is treated as a project contract: every grammar action emits a specific node, and every later phase walks the tree by tag. |

The Rust and Zig influences are deepest. Rip's contribution is
forward-looking. Ruby is aesthetic. Lisp's influence is structural:
the semantic IR is S-expression shaped, which keeps compiler phases
and tooling aligned.

## Build and run

```bash
zig build                                   # build bin/rig (Zig 0.16)
zig build test                              # Zig unit tests
./test/run                                  # full Rig test suite

bin/rig parse     examples/hello.rig        # raw S-expressions
bin/rig normalize examples/hello.rig        # normalized semantic IR
bin/rig check     examples/hello.rig        # effects + ownership + types
bin/rig build     examples/hello.rig        # emit Zig source
bin/rig run       examples/hello.rig        # build + zig run
```

Nexus must be built first:

```bash
(cd ../nexus && zig build -Doptimize=ReleaseSafe)
zig build parser                            # regenerate src/parser.zig
```

## Repository map

```
rig.grammar              surface syntax + IR action declarations
src/
  rig.zig                lexer, Tag enum, KeywordId, hand-written rewrites
  parser.zig             generated by Nexus from rig.grammar
  modules.zig            module loading, cross-module signature import
  types.zig              symbol resolution + type checker + sema walks
  effects.zig            fallibility / raw-context / extern-call enforcement
  ownership.zig          move / borrow / clone / drop / capture checking
  emit.zig               Zig backend
  runtime.zig            small trusted runtime (Rc, Weak, Cell, Vec, Closure, Signal)
  main.zig               CLI entry (parse / normalize / check / build / run)
docs/
  ROADMAP.md             milestone history (M0 → M30)
  CHECKLIST.md           per-milestone implementation tracking
  IR.md       IR shape and the lowering invariant
  REACTIVITY.md   Phase B reactive substrate design
  INFLUENCES.md          design lineage and the substrate ladder
examples/                runnable Rig programs (~226 fixtures)
test/                    test harness, golden files, module tests
SPEC.md                  language specification
HANDOFF.md               session state, non-negotiable invariants, forward arcs
AGENTS.md                compass for AI sessions working on Rig
FAQ.md                   common questions and pointed skeptical ones
```

For deeper reading: [`SPEC.md`](SPEC.md) (canonical syntax / semantics
reference), [`docs/IR.md`](docs/IR.md) (IR shape),
[`docs/INFLUENCES.md`](docs/INFLUENCES.md) (design lineage and the
substrate ladder), [`HANDOFF.md`](HANDOFF.md) (current state and
forward arcs), [`docs/ROADMAP.md`](docs/ROADMAP.md) (milestone
history), [`FAQ.md`](FAQ.md) (skeptical questions answered honestly).

## Roadmap

**Near-term** (no schedule; driven by what the substrate proves it needs):

- A polished userland `rig-reactive` library on top of the v0 canary.
- A small stdlib seed (`String` polish, basic IO, allocator surface).
- Body-less `extern fun` / `extern sub` for FFI ergonomics.
- `Closure1(T)` / `Closure2(A, B)` for callbacks that take arguments.

**Longer-term:**

- Structured concurrency.
- Async / poll-based futures (Layer 9 of the substrate ladder).
- A stable AI-consumable semantic export (`rig sema --json`).
- Persistent collections (Clojure-style, but without GC).

The full forward-arc menu lives in [`HANDOFF.md`](HANDOFF.md) §13. The
substrate ladder that orders this work is in
[`docs/INFLUENCES.md`](docs/INFLUENCES.md) §1.

## Non-goals

- **LLVM backend** — Zig handles it.
- **Garbage collection** — ownership replaces it.
- **Macro system in V1** — `pre` plus library design covers the
  current use cases.
- **Trait / interface system in V1** — deferred until concrete use
  cases force the design.
- **Marketing as "the AI language."** Rig's visible-effects design
  makes it easier for tools, including AI assistants, to read and
  reason about code. That is a byproduct of designing a serious
  systems language for humans — not the goal.

## Caveats

Rig is in active design and implementation; surface and semantics are
expected to change. The substrate is locked through Phase B (Layer 7
of the substrate ladder) plus the cross-cutting Drop / Cell-non-Copy
work (Layers 7.5–7.8); above that line, things may move. Read
[`SPEC.md`](SPEC.md) and [`HANDOFF.md`](HANDOFF.md) before depending
on anything.

## Notes

Development notes, including design discussions with AI assistants,
live in [`docs/INFLUENCES.md`](docs/INFLUENCES.md) and
[`HANDOFF.md`](HANDOFF.md).
