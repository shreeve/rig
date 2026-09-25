# FAQ

Short, honest answers, including to the skeptical questions. The
reasoning behind each is in [docs/DESIGN.md](docs/DESIGN.md).

## Is everything reference-counted?

No. Numbers, strings, structs, enums, and arrays are plain values, and
borrows (`?T`, `!T`) are checked at compile time and cost nothing at
run time. Counting happens only behind a shared handle `*T`, and every
count change is written in the source: `*x` allocates, `+x` bumps, `-x`
and scope exit release ([cost model](docs/DESIGN.md#cost-model)). The
honest gap: there is no single-owner heap box yet, so a heap value with
one owner still pays for a count.

## Is Rig safe like Rust?

That is the goal for the code it checks: use after move, double free,
use after free, dangling borrows, and leaks in safe Rig are treated as
compiler bugs, and `raw` blocks, `extern` calls, and the small runtime
are the explicit trust boundaries. The one leak the compiler does not
prevent is a cycle of strong handles, as in Rust and Swift. Rig is
young and its guarantee is only as strong as its checker: every feature
is tested with programs that run under a leak-checking allocator, known
bugs are kept as failing tests in `test/known/`, and it is not ready
for production code.

## Why sigils? Aren't they cryptic?

Sigils are cryptic when they are arbitrary. Rig spends them only on
effects a reader should notice where they happen, each has one meaning,
and most lines have none ([why](docs/DESIGN.md#sigils-rather-than-keywords),
[the algebra](docs/DESIGN.md#the-sigil-algebra)).

## Why indentation?

It is the lightest syntax for nested blocks, and each block is one IR
node; tabs in indentation are rejected so a file has one reading
([more](docs/DESIGN.md#indentation)). If significant whitespace is a
deal-breaker, Rig is not your language.

## Why compile to Zig instead of LLVM?

Zig already provides an optimizer, cross-compilation, linking, and a C
ABI, and its `defer`, error unions, optionals, and `comptime` match
what Rig needs ([more](docs/DESIGN.md#zig-as-the-target)). A custom
backend is not a goal.

## Why no garbage collector?

A collector would hide when memory is released, the effect systems
programmers most need to see. The stance is absolute: a feature that
needs a collector is redesigned
([more](docs/DESIGN.md#no-garbage-collector)).

## Why don't cycles get collected?

Because nothing is collected: a cycle of strong `*T` handles leaks, as
`Rc` does in Rust. Break it with a weak handle: a child holds its
parent as `~T`, and a callback that refers back to its owner captures
it weakly (`|~owner|`).

## How do I share mutable state?

Put it in a `Cell` behind a shared handle. Every holder can read and
replace the value; nobody gets an exclusive reference that others could
invalidate.

```rig
sub main()
  hits: *Cell(Int) = *Cell(value: 0)
  record = |+hits| hits.set(hits.get() + 1)
  record()
  record()
  print(hits.get())
```

```output
2
```

## Why is `upgrade` a method and not a sigil?

Every sigil always succeeds, and upgrading a weak handle can fail,
because the value may be gone. So it is a method returning an optional:
`if w.upgrade() as h` ([totality](docs/DESIGN.md#the-operations)).

## Why no `var` or `let`?

`x = e` binds or assigns, as in Python and Ruby, and `x =! e` binds for
good. What Rig forbids is silently reusing a visible name; write
`new x = e` to shadow on purpose ([more](docs/DESIGN.md#bindings)).

## Why isn't reactivity built into the language?

It doesn't need to be: shared and weak handles, `Cell`, owned closures,
`Vec`, and drop are what reactive libraries are made of, and a reactive
source with derived values is a page of Rig
([examples/memo_canary.rig](examples/memo_canary.rig)). `Signal` is the
one small reactive type in the runtime
([more](docs/DESIGN.md#substrate-not-a-reactive-framework)).

## Why no traits or interfaces?

Not yet. Traits bring a large design space (dispatch, coherence, trait
objects), and any design has to keep ownership visible at call sites
and in the IR. Until then, Rig has methods, generic types, enums, and
`match`.

## Can I call C?

Yes: declare the function with `extern fun`, call it inside a `raw`
block, and wrap that in a safe Rig function so callers need no `raw`.
Only integers, floats, and `Bool` cross the boundary today
([SPEC §16](SPEC.md#16-raw-code-and-ffi)).

## Why Nexus instead of another parser generator?

Each grammar rule declares the IR node it produces, so the grammar is
the single source of truth for syntax and IR, with no hand-written
parser and no AST layer ([more](docs/DESIGN.md#nexus-and-an-s-expression-ir)).

## Why another systems language?

Rig explores a point Rust and Zig don't occupy: Rust's ownership model
with a much smaller surface, effects visible at the call site, an IR
tools can read, and Zig's backend. For most production code today,
Rust or Zig is the right choice; they are mature, and Rig is not.

## How is AI used in this project?

AI assistants review designs and draft code, tests, and documentation.
What keeps that honest is what keeps any contribution honest: the
grammar builds with no conflicts, the checkers accept the program, the
emitted Zig runs leak-free, every example in the docs is executed, and
a human maintainer decides what lands. Judge the artifact: the grammar,
the tests, and the code.
