# FAQ

Short, honest answers, including to the skeptical questions.

## Is everything reference-counted?

No. Most values are plain values: numbers, strings, structs, enums, and
arrays live on the stack and compile to the same Zig you would write by
hand. Borrows (`?T`, `!T`) are checked at compile time and cost nothing
at run time: a write borrow is a pointer, a read borrow an ordinary Zig
parameter. Reference counting happens only behind a shared handle
`*T`, which you ask for explicitly, and every count change is written
in the source: `*x` allocates, `+x` bumps, `-x` and scope exit release.
That is where a Zig programmer would hand-write a reference-counted box
anyway, except that Rig checks it.

The honest gap: there is no single-owner heap box yet, so a heap value
with one owner still pays for a count.

## Is Rig safe like Rust?

That is the goal, for the code it checks: moves, borrows, handles,
drops, closures, and containers are all tracked, and use after move,
double free, use after free, dangling borrows, and leaks in safe Rig are
treated as compiler bugs. `raw` blocks, `extern` calls, and the small
runtime are explicit trust boundaries. The one leak the compiler does
not prevent is a cycle of strong handles, as in Rust and Swift.

Rig is young, and the guarantee is only as strong as its checker. Every
feature is tested with programs that run under a leak-checking
allocator, and known bugs are kept as failing tests in `test/known/`.
It is not ready for production code.

## Why sigils? Aren't they cryptic?

Sigils are cryptic when they are arbitrary. Rig spends them only on
effects a reader should notice where they happen (moving, lending,
cloning, dropping, sharing, failing) and each has exactly one meaning.
There are few enough to learn in an afternoon, and most lines of Rig
have none. Keywords at every site (`move(x)`, `clone(x)`) would make
code longer without making it clearer. See
[docs/DESIGN.md](docs/DESIGN.md#the-sigil-algebra) for how they fit
together.

## Why indentation?

It is the lightest syntax for nested blocks, and every indented block
is one node in the IR. Tabs are rejected so a file has one reading, and
inside brackets newlines are free, so long calls wrap naturally. If
significant whitespace is a deal-breaker for you, Rig is not your
language; the trade is deliberate.

## Why compile to Zig instead of LLVM?

Zig already does code generation well: an optimizer, cross-compilation,
linking, and a C ABI. Its semantics fit Rig closely (`defer` is exactly
what automatic drop needs, and error unions, optionals, and `comptime`
match `T!`, `T?`, and `pre`). Emitting Zig source keeps Rig independent
of Zig's compiler internals at the cost of one extra compile step. A
custom backend is not a goal.

## Why no garbage collector?

A collector would hide the one effect systems programmers most need to
see, when memory is released, and it costs predictable latency.
Ownership, shared and weak handles, automatic drop, and `Cell` cover
what a managed heap usually covers. The answer is deliberately
absolute: if a feature needs a collector, the feature gets redesigned.

## Why don't cycles get collected?

Because nothing is collected. A cycle of strong `*T` handles keeps
itself alive and leaks, exactly as `Rc` does in Rust. Break cycles with
weak handles: a child holds its parent as `~T`, and a callback that
refers back to its owner captures it weakly (`|~owner|`).

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

Every sigil always succeeds. Upgrading a weak handle can fail, because
the value may be gone, so it is a method returning an optional:
`if w.upgrade() as h`. Sigils are total; operations that can fail are
methods.

## Why no `var` or `let`?

`x = e` binds a new name or assigns an existing one, as in Python and
Ruby, and `x =! e` makes a binding that never changes. What Rig forbids
is the usual accident of that style: a local may not silently reuse a
visible name. When you mean to shadow, write `new x = e`.

## Why isn't reactivity built into the language?

Because it doesn't need to be. Rig provides the pieces reactive
libraries are made of (shared handles, weak handles, `Cell`, owned
closures, `Vec`, drop), and a reactive source with derived values is a
page of ordinary Rig ([examples/memo_canary.rig](examples/memo_canary.rig)).
`Signal` is the one small reactive type in the runtime.

## Why no traits or interfaces?

Not yet. Traits bring a large design space (dispatch, coherence, trait
objects), and each choice interacts with ownership. Any design has to
keep ownership transfer visible at call sites and in the IR. Until
then, Rig has methods, generic types, enums, and `match`.

## Can I call C?

Yes, from inside a `raw` block: declare the function with
`extern fun`, and wrap it in a safe Rig function so callers need no
`raw`. Today only numbers and `Bool` cross the boundary.

## Why Nexus instead of another parser generator?

Rig's IR is a contract: every later pass, and any future tool, walks
the same S-expression tree. Nexus lets each grammar rule declare the
node it produces, so the grammar is the single source of truth for both
syntax and IR, with no hand-written parser and no AST translation
layer. It is a sibling project written in Zig, and its output is one
Zig file that could be vendored.

## Why another systems language?

Rig explores a point Rust and Zig don't occupy: Rust's ownership model
with a much smaller surface, effects visible at the call site, an IR
that tools can read, and Zig's backend. That can't be retrofitted onto
either language. For most production code today, Rust or Zig is the
right choice; they are mature, and Rig is not.

## How is AI used in this project?

AI assistants are used as design reviewers and as drafters of code,
tests, and documentation. What keeps that honest is the same thing that
keeps any contribution honest: the grammar must build with no
conflicts, the checkers must accept the program, the emitted Zig must
run leak-free, every example in the docs is executed, and a human
maintainer decides what lands. Rig is not an "AI language"; that tools
can read it well follows from its design. Judge the artifact: the
grammar, the tests, and the code.
