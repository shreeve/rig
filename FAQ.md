# FAQ

Short, honest answers, including to the skeptical questions. The
reasoning behind each is in [docs/DESIGN.md](docs/DESIGN.md); if you
are coming from another language, start with [WELCOME.md](WELCOME.md).

## Is everything reference-counted?

No. Numbers, strings, and structs, enums, and arrays made of them are
plain values (a struct holding a `Vec` owns it), and views (`?T`,
`!T`) are checked at compile time and cost nothing at run time. Counting happens only behind a shared handle `*T`, where
every count change is written (`*x`, `+x`, `<x`); a heap value with one
owner is a `Box[T]`, which counts nothing
([cost model](docs/DESIGN.md#cost-model)).

## Is Rig safe like Rust?

That is the goal: use after move, double free, use after free,
dangling views, and leaks in safe Rig are compiler bugs, and `raw`
blocks, `extern` calls, and the small runtime are the trust boundaries;
the one leak it does not prevent is a cycle of strong handles, as in
Rust and Swift. The guarantee is only as strong as the checker, which
is young: every feature is tested by programs run under a leak-checking
allocator, and Rig is not ready for production code.

## Why sigils? Aren't they cryptic?

Sigils are cryptic when they are arbitrary. Rig spends them only on
effects a reader should notice where they happen, each has one meaning,
and most lines have none ([why](docs/DESIGN.md#sigils-rather-than-keywords),
[the algebra](docs/DESIGN.md#the-sigil-algebra)).

## Why is `!` not logical negation?

Because prefix `!` lends to write (`!v.push(x)` marks that `push`
writes `v`), and a sigil has one meaning; negation is the word `not`.
Where the C, Rust, or Zig habit would change a program's meaning, it is
a compile error instead: `if !done`, `!q.is_empty()`, and a `!` call
returning a `Bool` that starts a condition or is an operand of `and`,
`or`, or `not` without parentheses
([receiver sigils](SPEC.md#structs), [operators](SPEC.md#operators)).
For the same reason, a comparison under `not` takes parentheses:
`not (a > b)`, never `not a > b`.

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

Put it in a `Cell` behind a shared handle: every holder can read and
replace the value, and nobody gets an exclusive reference that others
could invalidate.

```rig
sub main()
  hits: *Cell[Int] = *Cell(value: 0)
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

`x = e` binds or assigns, as in Python and Ruby, and `const x = e` binds
for good. What Rig forbids is silently reusing a visible name; write
`new x = e` to shadow on purpose ([more](docs/DESIGN.md#bindings)).

## Why isn't reactivity built into the language?

It doesn't need to be: shared and weak handles, `Cell`, owned closures,
`Vec`, and drop are what reactive libraries are made of, and a reactive
source with derived values is a page of Rig
([examples/memo_canary.rig](examples/memo_canary.rig)). `Signal` is the
one small reactive type in the runtime
([more](docs/DESIGN.md#substrate-not-a-reactive-framework)).

## Why no traits or interfaces?

Not yet: any design has to keep dispatch and ownership visible at call
sites and in the IR, and `trait`, `impl`, and `where` are reserved for
it. Until then, generics have no bounds: a generic body may do with `T`
whatever each instance supports, and each instance a program makes is
checked, with an error at the call and a note at the body line
([more](docs/DESIGN.md#per-instance-checking-instead-of-traits)).

## Why square brackets for generics?

Square brackets hold everything known at compile time, and parentheses
what is known when the program runs, so `Wrap[Int](v: 3)` names a type
and then builds a value, and `check[.strict](5)` passes a compile-time
value beside a run-time one. That is Zig's `comptime`, in the brackets
Go uses for its generics ([more](docs/DESIGN.md#brackets-for-compile-time)).

## Can I call C?

Yes: declare the function with `extern fun`, call it inside a `raw`
block, and wrap that in a safe Rig function so callers need no `raw`.
Only integers, floats, and `Bool` cross the boundary today
([SPEC §15](SPEC.md#15-raw-code-and-ffi)).

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
