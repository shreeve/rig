# The design of Rig

This document explains why Rig looks the way it does. The rules
themselves are in [SPEC.md](../SPEC.md); the compiler is described in
[INTERNALS.md](INTERNALS.md).

## The idea

Most of what makes systems code hard to read is invisible: a value is
copied or moved, a buffer is borrowed or kept, a counter is bumped, an
error is thrown past you, a destructor runs. Rig's central rule is that
**an effect that matters is visible where it happens**, in a form short
enough that writing it is no burden:

```rig
struct Packet
  size: Int

  drop self: !Packet
    print("freed", self.size)

fun size_of(p: ?Packet) -> Int
  p.size

sub send(p: Packet)
  print("sending", p.size)

sub main()
  p = Packet(size: 512)
  print(size_of(?p))      # lent for reading; `p` is still ours
  send(<p)                # handed over; `p` is gone from here on
  print("done")
```

```output
512
sending 512
freed 512
done
```

Visibility is not the safety mechanism; the checkers are. Visibility is
what lets a person, or a tool, reason about a program locally, and it
keeps the checkers honest: every effect the checker reasons about is an
effect the reader can see. Rust achieves correctness through rigor; Rig
aims for rigor plus visibility.

## Principles

**Effects stay visible.** Moves, borrows, clones, drops, shared and
weak ownership, allocation, failure, mutation, capture modes,
compile-time parameters, and the unsafe boundary each have a marker.
There is no hidden refcount traffic, no implicit error propagation, and
no unmarked unsafe code. What stays implicit is cheap and cannot
surprise: copying plain data, reading through a shared handle, lending
a receiver to a `?self` method, and moving a local out with `return x`,
where its scope ends anyway. Writing through a receiver
(`(!v).push(x)`) or consuming it (`(<u).close()`) is always spelled out.

**Effects survive into the IR.** Every sigil becomes a named node in
the semantic IR (`(move x)`, `(read x)`, `(clone x)`, `(drop x)`,
`(propagate e)`, `(raw_block ...)`), and the checkers and emitter
consume those nodes by name. What the reader sees is exactly what the
compiler reasons about; nothing is recovered from comments,
conventions, or heuristics.

**Accept means correct.** If `rig check` accepts a program, the emitted
Zig compiles and does what the source says. A construct the compiler
cannot lower yet is rejected with a Rig diagnostic that says so, never
passed through to fail in Zig or silently dropped.

**Safe code cannot corrupt memory.** Use after move, double free, use
after free, dangling borrows, and leaks are compiler bugs in safe Rig.
Only code inside a `raw` block may break these guarantees. The one leak
the compiler does not prevent is a cycle of strong handles, as in Rust
and Swift; weak handles exist to break cycles.

**Substrate in the language, libraries in userland.** The language
provides ownership, handles, interior mutability, closures, containers,
and drop. Anything that can be built from those (a reactive framework,
an event bus, a cache) is a library. When a library cannot be written
cleanly, the language gains a general feature, never a special case.

**Unify effects rather than add features.** A feature earns its place
by making an existing effect explicit or by replacing several ad hoc
mechanisms with one. Closure literals lost their keyword because the
bar list already marked them; closure types became `fun(...)` and
`sub(...)` because function types already existed.

## The sigil algebra

Rig's sigils are not a list of abbreviations. They are a small algebra
over values and types, with a few laws that make them predictable.

### The operations

For a value `x` of type `T`:

| Expression | Type | Effect | Runtime cost |
|---|---|---|---|
| `<x` | `T` | ownership leaves `x` | none (a large value may be copied) |
| `?x` | `?T` | shared, read-only loan | none: checked statically |
| `!x` | `!T` | exclusive, writable loan | none: checked statically |
| `+x` | `T` | a new owner (`T` is Copy or a handle) | a count bump for a handle |
| `-x` | (statement) | release now | runs the drop glue |
| `*x` | `*T` | move into a new counted box | one allocation |
| `~x` | `~U` when `T` is `*U` | a non-owning handle | a weak-count bump |
| `%x` | `T` | raw access (inside `raw` only) | none |
| `e!` | `T` when `e : T!` | propagate failure | a branch |

Each operation has one meaning, becomes one IR node, and succeeds
whenever it type-checks. That is the first law.

**Totality.** A sigil never fails at run time; failure belongs to
methods. This is why the way back from a weak handle is a method:
`w.upgrade()` returns an optional `(*U)?`, because the value may be
gone. A sigil like `^w` was considered and rejected: it would be the
only partial sigil. The round trip is total going down (`~x`), fallible
coming up (`upgrade()`).

**Position picks the category; the symbol picks the family.** A prefix
`?` or `!` is always a borrow, in an expression and in a type alike:
`?x : ?T`, `!x : !T`. A suffix is never a borrow: suffix `?` belongs to
absence and suffix `!` to failure.

```text
?x   prefix, expression   read borrow
!x   prefix, expression   write borrow
?T   prefix, type         read-borrowed parameter or value
!T   prefix, type         write-borrowed parameter or value
T?   suffix, type         optional: T or none
T!   suffix, type         fallible: T or an error
e!   suffix, expression   propagate the failure of a T!
e?   suffix, expression   reserved: propagate the absence of a T?
```

The triangle came from a collision: an early design spelled fallible
returns `-> !User`, which clashed with the write borrow. Moving type
modifiers to suffix position made both families unambiguous. One
casualty is Ruby's `valid?` method names, which would collide with
`Bool?`; Rig writes `is_valid`.

**Composition.** Prefixes compose right to left and suffixes bind
tighter than prefixes, in types and in expressions:

| Form | Reads as |
|---|---|
| `*<o` | move `o`, then share it |
| `+p.a` | clone the handle held in field `a` |
| `?*Node` | a read borrow of a shared handle |
| `*User?` | a shared handle to an optional `User` |
| `(*User)?` | an optional shared handle (what `upgrade()` returns) |
| `*Cell(Vec(*sub()))` | a shared cell holding a list of owned closures |
| `(!v).push(x)` | write-borrow `v`, then call a writing method |

**Absorption.** Operations that would add nothing are rejected rather
than silently tolerated. Sharing a shared handle (`*x` when `x : *T`,
or the type `*(*T)`) would add a second count for nothing; `+x` is the
operation you want. A borrow of a borrow is the same borrow: forwarding
a `?B` parameter as `?b` passes a `?B`, not a `??B`. And a write loan
can always be read: a `!T` is accepted where a `?T` is expected.

**The same sigils, the same meanings, elsewhere.** A closure's bar list
reuses the expression sigils for captures (`|+x|` clones, `|<x|` moves,
`|~x|` holds weakly). A loop over owning elements borrows its source
(`for x in ?v`). Receivers are `?self` and `!self`, the only place a
sigil may prefix a parameter name. Move-assignment `a <- b` is `a = <b`.
The fixed binding `x =! e` is the one place `!` appears in an operator
that is not about borrowing or failure.

Here the algebra is at work in one small program:

```rig
struct Node
  id: Int

  drop self: !Node
    print("drop", self.id)

struct Owner
  node: *Node

fun id_of(n: ?*Node) -> Int
  n.id

sub main()
  o = Owner(node: *Node(id: 1))
  shared = *<o                 # move `o`, then share it: *Owner
  first = +shared.node         # clone the handle in a field: *Node
  print(id_of(?first))         # lend the handle: ?*Node
  w = ~first                   # weaken it: ~Node
  -first
  if w.upgrade() as n          # the way back is a method: (*Node)?
    print("alive", n.id)
```

```output
1
alive 1
drop 1
```

### Cost model

The costs are where the sigils are. Moves, borrows, and plain values
cost what they cost in Zig or C. Reference counting happens only behind
`*T`, and each count change is written: `*x` allocates, `+x` bumps,
`-x` and scope exit release. Borrows are never counted. Drop glue is
ordinary code the compiler generates, run at points you can see.

## Why these choices

### Sigils rather than keywords

Sigils are bad when they are arbitrary. Rig spends them only on effects
a reader should notice locally, keeps the set small and uniform, and
gives each exactly one meaning. The alternative, `move(x)`,
`borrow(x)`, `clone(x)` at every site, makes code longer without making
it clearer once the set is learned. Most Rig code carries no sigils; they
appear where the effect does. And because they appear at call sites,
not only in signatures, a reader sees whether a value is lent or handed
over without looking up the callee.

### Borrows without lifetimes

Rig follows the second-class-reference model of Swift, Hylo, and Mojo
rather than Rust's lifetime parameters. A borrow can live in a
parameter, a local, a struct field, or a function's result, and the
checker tracks where each one came from: a returned borrow borrows from
every borrowed argument of the call, and a struct holding a borrow
keeps its source borrowed. That rule is sound without annotations; the
price is that some programs Rust can express with explicit lifetimes
are rejected. Rig takes that trade for now and will revisit it when
real programs push against it.

### Explicit capture modes

A closure that stores a callback must say how it holds each value it
refers to. Without explicit modes, a closure could silently capture a
handle strongly and rebuild the very cycle a weak edge was meant to
break. So a capture always carries a sigil, and a bare name in a bar
list is always a parameter, never a capture: the spelling alone decides,
so adding a local elsewhere can never change a closure's meaning.

### Drop by guarded defers

Every owning binding is released at the end of its scope on every path:
early returns, `break`, `continue`, error propagation. Instead of a
control-flow pass that inserts a drop on every exit edge, the emitter
gives each owning binding a Zig `defer`, guarded by a flag when the
binding may be moved or dropped early. Zig's `defer` makes cleanup
path-sensitive and correctly ordered for free; the cost is one Boolean
per such binding, visible in the emitted code.

### Bindings

`x = e` binds or assigns, as in Python and Ruby, so there is no `var`
or `let`. What Rig forbids is the classic accident of that style:
implicit shadowing. A local may not reuse a visible name; `new x = e`
shadows on purpose. `x =! e` marks a binding that never changes.
Rig does not flip to immutable-by-default: the emitter already declares
every binding that is never reassigned as a Zig `const`, and visible
mutation is better expressed through types like `Cell` than through
binding syntax.

### `and`, `or`, `not`

Words read better than `&&` and `||`, and they free `!` for its two
jobs, borrowing and failure. The old spellings are rejected with a
pointer to the new ones.

### `raw` as a block

`raw` marks the audit boundary: raw access, unchecked Zig builtins, and
calls to C. It is block-only, so the boundary is a visible region, not
a modifier that can hide on a function. It is an audit boundary, not a
performance ceiling: the code inside is ordinary Zig.

### Zig as the target

Zig already solves code generation: an optimizer, cross-compilation,
linking, and a C ABI. Its semantics fit Rig closely: `defer` is exactly
what automatic drop needs, error unions are `T!`, optionals are `T?`,
`comptime` parameters are `pre`, and generic types are functions from
types to types. Emitting Zig source rather than Zig IR or LLVM IR keeps
Rig independent of backend internals, at the cost of one extra compile
step.

### No garbage collector

A collector would make the most important effect of all, when memory is
released, invisible, and it costs systems code predictable latency.
Reference counting where you ask for it, weak handles, automatic drop,
user `drop` bodies, and `Cell` cover the ground a managed heap usually
covers. The one thing a collector does better is cyclic structure,
which Rig handles with weak handles. The stance is absolute: a feature
that needs a collector is redesigned, not the language.

### Indentation

Indentation is the smallest syntax for nested blocks, and every
indented block maps directly to a `(block ...)` node. Tabs are rejected
so a file has one reading. Inside brackets, newlines are plain
whitespace, so long calls wrap naturally. The cost is that tools must
understand significant whitespace.

### Nexus and an S-expression IR

The grammar (`rig.grammar`) is written for Nexus, an LR parser
generator that emits one self-contained Zig file. Each grammar rule
declares the S-expression node it produces, so there is no hand-written
parser and no separate AST type: the grammar is the single source of
truth for both syntax and IR shape, and every later pass walks the same
tree by tag. The grammar has no LALR conflicts; the context-sensitive
decisions (the spacing rule, ternary versus guard, closure bars) are
made in a small lexer rewriter that can see spacing. Lisp's influence
on Rig is this IR, not its syntax.

### Substrate, not a reactive framework

Rust and Zig ship no reactivity in their standard libraries; Leptos and
friends are libraries over `Rc<RefCell<T>>` and closures. Rig takes the
same position, and used reactivity as a forcing function: a reactive
program had to compose from general pieces, and wherever it could not,
the language gained a general feature. The same pieces (a parent owning
children that refer back weakly, retained callbacks, shared mutable
cells, lists of handles) serve GUI trees, observers, caches, and graphs.
`Signal` is the one reactive primitive in the runtime, and it is
deliberately minimal.

## Influences

Rig is its own language. It borrows specific ideas where they serve its
goals, and says no where they don't.

| Source | Taken | Left behind |
|---|---|---|
| **Rust** | ownership, moves, the shared-or-exclusive borrow rule, `Rc`/`Weak` semantics, RAII drop in reverse field order, enums and `match`, errors as types, "a type with drop glue is not Copy" | lifetime syntax, traits (for now), heavy generic machinery, effects hidden in trait impls |
| **Zig** | the backend itself; `comptime` as `pre`; error unions; `defer`/`errdefer`; no GC; generic types as type functions | its async history as a cautionary tale; leaving aliasing and lifetimes to convention |
| **Python** | indentation, `and`/`or`/`not`, readable one-line calls, `print` with several values, bindings without declarations | dynamic typing, implicit shadowing |
| **Ruby** | paren-free calls, short keywords, readability first | `valid?` names, implicit mutation |
| **CoffeeScript, Rip** | the aesthetic; Rip (a CoffeeScript-style language by Rig's author) and Zag (its Zig-targeted sibling) supplied the indentation lexer and much of the surface | reactive operators in the core language |
| **Swift** | second-class borrows; `x?` optional propagation (reserved) | |
| **Hylo, Mojo** | borrows as parameter conventions rather than types with lifetimes; values first | |
| **Lisp** | S-expressions as the IR and a project contract | S-expression syntax; macros |

## Non-goals

- a garbage collector, ever
- a custom or LLVM backend: Zig does code generation
- a reactive framework in the language
- macros, until compile-time evaluation proves it needs them
- traits and interfaces, until a design keeps dispatch and ownership
  visible
- lifetime annotations, unless second-class borrows prove too weak
- marketing Rig as an AI language: that tools can read it well follows
  from its design, and is not the goal
