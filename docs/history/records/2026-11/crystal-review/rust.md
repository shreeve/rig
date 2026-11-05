# Crystal (1.23.0-dev) through a Rust and soundness lens, for Rig

Paths are relative to `~/Data/Code/rig/misc/crystal/`. Rig facts are from
`origin/main` (SPEC.md, docs/QUICK.md, docs/design/concurrency.md, docs/STD.md).

## Area by area

### Flow typing, unions, whole-program inference

Crystal's best idea is in `src/compiler/crystal/semantic/filters.cr`. A
condition yields `TypeFilters` (truthy, `is_a?`, `responds_to?`, `nil?`,
and, or, not; filters.cr:32-367). `visit(If)` applies the filter to the
then branch and its negation to the else branch (main_visitor.cr:1989-2047),
and `merge_if_vars` joins the branches, dropping one that ends in
`return`/`break`/a `NoReturn` call (main_visitor.cr:2049-2070). `&&` and
`||` compose filters, including variables assigned in the right operand
(main_visitor.cr:2022-2040). `NoReturn` is removed from unions
(type_merge.cr:47). It reads like Ruby and checks like Kotlin.

The limits are the soundness lesson. Narrowing applies to locals only:
reading an instance variable records no filter (main_visitor.cr:653-660),
because any call, or another fiber, may change `@x` between test and use.
So the idiom is `if x = @x`, a rebinding: what Rig's `if ?@f as x` already
is, except that Rig's loan genuinely freezes the field for the block, so
Rig is sound where Crystal has to give up.

Inference is whole-program and observer-based: every node binds to its
dependencies and re-types when they widen (bindings.cr:86-143, the
`TypeFilteredNode` observer at filters.cr:2-24). A method has no type until
called; its instantiation per argument tuple is the monomorphization. Cost:
no separate compilation, compile time grows with the program, and a call
added in file A can widen an instance variable's union in file B (the
`freeze_type` trace at bindings.cr:113-132 exists to explain such errors).
Instance variable types are guessed from assignments
(type_guess_visitor.cr:1-3), and a field turns nilable because `self` was
used before it was assigned in `initialize` (main_visitor.cr:863-875,
explained by `NilReason`, exception.cr:233-234). Sound, but the type of a
field depends on statement order in a constructor: action at a distance.

### Exceptions against Result

`Exception` carries `message`, `cause`, and a backtrace
(exception.cr:14-37). Any call may raise; nothing in a signature says so.
`ensure` cannot `return` or `break` (main_visitor.cr:1834, 2370), a good
rule. The `[]?` / `not_nil!` convention (object.cr:422-436, nil.cr:109) is
a light Option on top of exceptions. Against Result: invisible failure
paths, no exhaustive handling, and the compiler cannot tell which calls
can fail. Rig's `T!`/`f()!`/`catch` is strictly better on visibility. The
one thing Crystal has that Rig lacks is the trace: where a failure started.

### Generics

`Array(T)`, `forall U` free variables (enumerable.cr:654), restrictions
like `x : Int32` that select overloads. Unconstrained: a generic body is
checked per instantiation (C++ templates, not Rust traits), so an error
appears at the use, deep in the instance. Abstract defs are checked
against implementors (abstract_def_checker.cr:1-26), which is the closest
thing to a trait bound, but a type parameter cannot be bounded by one.
Rig's `[T: Shape]` checks the body once against the bound; keep it.

### Structs and classes; value and reference

`struct` is a value, `class` a GC'd reference (struct.cr:1-12). The split
is honest about cost, but a mutable struct passed to a method is silently
a copy, and the write is lost (struct.cr:13-40 documents the footgun as
the intended behavior). Rig already dissolves this: a write is `!x`, so a
write to a copy cannot be written by accident.

### Modules and abstract defs against traits

Modules are mixins (`include Enumerable(T)`), and that is where Crystal
shines: implement `abstract def each(& : T ->)` (enumerable.cr:43) and get
some hundred methods (`each_cons` 321, `each_slice` 407, `find` 540,
`group_by` 654, `partition` 1497, `sum` 1845). They are fast because every
block passed to a yielding method is inlined (`recursive block expansion`
is rejected, call.cr:453), and a block may `return` from the enclosing
method (`find`, enumerable.cr:540-545) or `break` out of the call
(main_visitor.cr:2374-2379). Against traits: no coherence, open classes,
reopenable everything, no bounds on type parameters, overloading by
restriction. Ergonomic, not principled.

### Concurrency and data races

The runtime is good engineering. `Fiber::ExecutionContext` has three kinds
(execution_context.cr:31-60): `Concurrent` (one thread at a time, cheap
primitives), `Parallel` (work stealing, resizable), `Isolated` (a fiber
owns a thread, for GUI loops or blocking work). The language knows none of
it. There is no Send or Sync: any object reachable from two fibers in a
`Parallel` context is raced. The spawn docs show the capture trap,
`spawn { print(i) }` printing `55555` (concurrent.cr:99-123), because a
closured local is shared by reference. `Sync::Exclusive(T)` is a
Mutex<T>, but its guarantees are comments: the value "mustn't be retained"
after `lock` (sync/exclusive.cr:66-68), and `get` "breaks the mutual
exclusion guarantee" (sync/exclusive.cr:93-96), plus `unsafe_get`/
`unsafe_set` (110-118). A Rust `MutexGuard` lifetime, or Rig's
second-class views, make exactly these rules checkable.

### Channels

Go's design: unbuffered or buffered (`Channel.new(capacity)`, channel.cr:83),
`close` idempotent with a `Bool` result (108-123), `receive` raises on
close, `receive?` gives `nil` (203-214), `select` and `receive_first`
(channel.cr:314-327, channel/select.cr:51-69). The doc admits the hole
that `Channel(Nil)` or `Channel(Int32?)` cannot tell `nil` from closed
(channel.cr:21-24), since Crystal unions flatten `T?` of a nilable `T`.
Rig's nested optionals (`(Int?)?`, SPEC "Optionals") already avoid it.

### Pattern matching and `case`/`in`

`case ... in` is exhaustive, `case ... when` is not (cleanup_transformer.cr:203).
Exhaustiveness covers union members, enum members, and `Bool`, and tuples
of them (exhaustiveness_checker.cr:1-165); abstract types are devirtualized
into their concrete subtypes (184-189), sound only because the program is
whole. There is no destructuring of fields and no payload enums: sum types
are unions of `record` structs. `@[Flags]` enums cannot be proven
exhaustive (167-170). Rig's `match` with patterns that bind by name, and
always exhaustive, is ahead.

### Soundness holes found

1. **Data races corrupt memory.** A union is a type id beside a value
   (codegen/unions.cr:1-12); two threads writing one variable can tear it,
   and a reader then dispatches on the wrong type id: type confusion, not
   just a wrong number. Array/Hash resizing under a race is the same class.
2. **No unsafe boundary.** `pointerof`, `Pointer`, `uninitialized`
   (used by the stdlib itself, channel.cr:60-63), and `unsafe_as`
   (object.cr:521) work anywhere.
3. **Dangling views of stack values.** `StaticArray#to_slice` returns a
   `Slice` pointing into a value that lives on the stack
   (static_array.cr:360-371); return it from a method and it dangles. No
   lifetime, no error.
4. **Lock escapes.** `Sync::Exclusive` retained values (above).
5. **Silent lost writes** on mutable structs (struct.cr:13-40); not memory
   unsafety, but "accept means correct" fails.
6. **Non-exhaustive `case/when`** turns its type nilable instead of
   failing.

Nil safety itself is sound: `Nil` is a type, and `not_nil!` raises.

### Could Crystal's ergonomics live with ownership?

Most of it, yes, and Rig is the evidence: `if o as x`, `?? return`,
`matches`, `?` and `!`. Flow narrowing of a *local* option is compatible
with ownership (Rust's `if let`, Rig's `as`). Narrowing a *place* needs
the place frozen for the narrowed span, which is a loan, which Rig has.
Inline blocks with non-local control flow are not only compatible, they
are easier with ownership than iterators: the yielded view lives only
inside the inlined body, so it needs no lifetime and no iterator object
holding a loan. What does not fit is the whole-program inference, the
implicit union widening, and exceptions.

## Scores

| Area | Score | Why |
|---|---|---|
| Syntax | 8 | Ruby's readability with types, `&.method` and blocks; `end` noise and many spellings of one thing. |
| Operators | 7 | Overflow raises, wrapping `&+` is explicit, `//` floors; `===` case equality and overloadable everything hide meaning. |
| Type system | 6 | Flow typing and unions are superb; whole-program inference costs modularity, compile time, and errors far from their cause. |
| Object system | 6 | Honest value/reference split and checked abstract defs, but open classes, silent struct copies, no bounded generics. |
| Grammar | 5 | Ruby's context-sensitive grammar (`foo -1`, `foo [1]`, macros), a hand parser; hard to tool. |
| Concurrency | 5 | Execution contexts are a fine runtime (Concurrent/Parallel/Isolated), with no race prevention at all. |
| Channels | 7 | Go's channels with `select` and clean close; `Channel(T?)` cannot tell nil from closed. |
| Error handling | 5 | Exceptions with cause and backtrace and a sane `ensure`; every failure path invisible. |
| Safety | 4 | Nil-safe and GC'd, but races tear unions, pointers need no marker, stack slices dangle. |

## Ideas for Rig, ranked

### 1. A failure's trace in debug builds

Crystal: `ex.inspect_with_backtrace` prints where it was raised and its
`cause` chain (exception.cr:19-66).

Rig today: a failure leaving `main` prints `error: E.name` and exits 1
(SPEC §13, "f()! propagates it"); only a panic shows a stack trace (SPEC
§17). No return trace anywhere in SPEC or src.

Rig form: no syntax. In a debug build, the failure prints the `f()!` sites
it passed through:

```
error: Io.not_found
  at config.rig:12:9   text = fs.read(path)!
  at main.rig:4:3      cfg = load(args)!
```

Zig keeps an error return trace for `try` in debug and safe builds already,
so emit gets it nearly free if each `f()!` lowers to `try` (or records its
site). Guarantees: kept; nothing changes meaning, and release builds pay
nothing. Effects stay visible, more so. Tests that assert stderr would
need the trace omitted or matched.

### 2. Inline yielding functions: internal iteration with `break` and `return`

Crystal (enumerable.cr:540-545):

```crystal
def find(if_none = nil, & : T ->)
  each do |elem|
    return elem if yield elem
  end
  if_none
end
```

Every yielding call is inlined (call.cr:453), so `each` costs a loop, and
`return` in the block leaves the enclosing method. One `each` gives a
module some hundred methods.

Rig today: `for` over iterators (an iterator object), and chains, a fixed,
compiler-built set of stages and consumers (SPEC §6 "Chains"). `return`
in a closure leaves the closure (SPEC §11). `yield` is reserved (SPEC §19).
A user cannot write a new chain stage, or walk a tree without writing an
iterator object with its own state.

Rig form (a sketch for a design round):

```rig pending
fun leaves(?@) yields ?Leaf
  for k in ?@kids
    if k matches .leaf(l)
      yield ?l
    else
      yield from ?k.leaves()   # rejected: a yield function cannot recurse

fun first_hot(t: ?Tree) -> ?Leaf? from t
  for l in t.leaves()          # the body is inlined at each `yield`
    return l if l.hot
  none
```

Guarantees: the yielded view lives only within the inlined body, so it is
second-class by construction and needs no `from`/`keeps`; the checker
checks the inlined code, which is what emit writes ("checker checks what is
emitted"). `break`/`return`/`continue` in the body are ordinary visible
jumps. Recursion is rejected, as Crystal rejects it. It would let std carry
chain stages as library code ("substrate in the language, libraries in
userland"). Cost: code size, a body copied per `yield` site. This is a new
language feature, so it goes to the owner, after the one in flight.

### 3. Flag sets of an enum

Crystal: `@[Flags] enum Perm; Read; Write; end`, `p = Perm::Read | Perm::Write`,
`p.read?`, with an exhaustiveness note that flags cannot be matched
exhaustively (exhaustiveness_checker.cr:167-170).

Rig today: no enum set in SPEC or STD; STD's own example keeps `flags: U32`
by hand (docs/STD.md:2127-2137), and Trig ports TypeScript's many flag
enums as raw integers.

Rig form: a std type, `Flags[E]` over a plain enum, one bit per variant:

```rig pending
enum Perm
  read
  write
  run

sub main()
  p: Flags[Perm] = Flags(.read, .write)
  print(p.has(.read), (p | Flags(.run)).count)
```

Guarantees: kept; plain data, copies, checked width (`$variants(E).len` at
most 64). It is std, not language: a new std module outside the ROADMAP
goes to the owner first.

### 4. (Owner's call) A lock whose view cannot escape

Crystal's `Sync::Exclusive#lock` says in a comment what Rig could check:
"The value mustn't be retained" (sync/exclusive.cr:66), and its `get`
breaks exclusion (93-96).

Rig form: `*Locked(List[Job]())`, `!jobs.lock(|!list| !list.push(<j))`;
the closure's `!List[Job]` is second-class, so retaining it is already a
rejection, and there is no `get`. Rig's stance is that programmers never
write locks (concurrency.md, "What a programmer never writes"), and actors
cover shared mutable state, so this is listed only to show that the
Crystal hole does not exist for Rig if a lock is ever wanted, for example
for a multi-word Cell shared across cores without an actor's hop.

### Already in Rig (not proposed)

- Narrowing an option by binding: `if o as x`, `if ?@f as x`, joined with `and`.
- Let-else via `?? return` / `catch break`, and `panic(...)` as an expression in place of `not_nil!`.
- `[]?` style: `get` gives `T?`, `xs[i]` panics.
- Arguments evaluated at dispatch: `f(i)&` (the `spawn print(i)` lesson).
- Nested optionals, so a `Chan[Int?]` tells a `none` value from closed.
- Exhaustive `match` with messages naming what is missing.
- A dedicated thread for the main thread or a GUI loop: the main-thread
  actor is in the approved v0.3.1 concurrency plan.

## What Rig should not take

1. **Whole-program inference of signatures and fields.** It kills separate
   compilation and incremental checking, makes compile time superlinear,
   and lets a call in one module change a field's type in another. Rig's
   checks must stay modular for `rig check` speed and for its LSP.
2. **Implicit unions from flow** (`x = cond ? 1 : "a"` makes
   `Int32 | String`, type_merge.cr). A value whose type silently widens
   hides a tag, a size, and a branch; Rig's enums with payloads say it.
3. **Truthiness narrowing of places** (`if @x`). Even Crystal does not do it
   for fields. With write views it is sound only while a loan freezes the
   place, which is what `if ?@f as x` already says. Two mechanisms for one
   idea break "one word, one mechanism".
4. **Exceptions.** Invisible failure paths contradict "effects stay
   visible" and make exhaustive handling impossible.
5. **Silent copies of mutable values** (struct.cr:13-40). Rig's `!` already
   makes the lost write unwritable.
6. **Open classes, overloading by type restriction, and macros that write
   methods** (`record`, `getter`, `property`). Each hides code or dispatch
   from the reader; `add Int: Shape` in the API's module is the coherent
   form.
7. **Unmarked pointers and `uninitialized`.** Everything of that kind stays
   in `raw`.
8. **Structured concurrency without Send/Sync.** Crystal's execution
   contexts are a good scheduler design to study, but the lesson of
   codegen/unions.cr is that without "what may cross" in the type system
   a race is a memory corruption, not a wrong answer.
