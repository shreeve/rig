# Crystal 1.23.0-dev, reviewed through Swift and API design

Reviewer's lens: Swift (value and reference types, protocols with
associated types, optionals, payload enums, ARC, structured concurrency,
actors, argument labels). Paths are relative to
`~/Data/Code/rig/misc/crystal/`. Rig facts are from `origin/main`
(QUICK, SYNTAX, SPEC, apis.md, concurrency.md, mantras.md).

## 1. Scores

| Area | Score | Why |
|---|---|---|
| Syntax | 7 | Ruby-pretty and short to read, but it has several spellings for each idea (`do...end` and `{}`, `case/when` and `case/in`, `&.x` and `{ \|x\| x.x }`), and optional parentheses make a bare name a call or a variable depending on what is in scope. |
| Operators | 6 | Rich and overloadable, with wrapping `&+` and floor division `//` done well, but `\|\|` doubles as nil-coalescing by truthiness, `===` is a hidden case-equality hook, and `!` is both `not` and a suffix on method names. |
| Type system | 7 | Whole-program inference of unions with flow typing is a real achievement, but it costs compile time, puts errors far from their cause, and cannot narrow fields: the compiler's own source has 213 `not_nil!` calls. |
| Object system | 6 | `class` against `struct` is Swift's split, but without Swift's `mutating`; mutable structs copy silently (src/struct.cr:13-36), and inheritance, reopening, and `method_missing` make every type open. |
| Grammar | 5 | A 6,621-line hand-written parser full of context (spacing decides `foo -1`, `a ?b : c`, and whether `x` is a call); macros are interleaved with the syntax, even inside `def` signatures (src/concurrent.cr:79). |
| Concurrency | 5 | Fibers need no colored functions, which is right, but `spawn` is unstructured: it returns no handle to join, an exception in a fiber is printed and lost (src/fiber.cr:160-164), and a block captures loop variables by reference (src/concurrent.cr:96-118). |
| Channels | 7 | A small, clean API with a `select` statement and a rendezvous default (src/channel.cr:83), let down by two receive methods (`receive` raises, `receive?` returns nil) and the documented nil ambiguity of `Channel(T?)` (src/channel.cr:22). |
| API design | 7 | Humane and consistent: predicates end in `?`, `[]?` is the non-raising index, `to_s(io)` is the zero-allocation overload, and `step(*, to limit, by step)` reads as prose; but overloading by block and no-block doubles each method (src/object.cr:553-591). |
| Standard library | 8 | Broad, documented with runnable examples in every doc comment, and well layered (`Comparable` and `Enumerable` give many methods from one). |

## 2. Area by area

### Object system

- **class against struct** (src/struct.cr, src/reference.cr). A
  `struct` is a value and a `class` a reference, chosen once at the
  declaration, as in Swift. Swift adds `mutating` so a method that
  changes a value type says so. Crystal does not, and its own docs
  warn that passing a mutable struct passes a copy, so the change is
  lost (src/struct.cr:13-36). Rig dissolves this: an `obj` is a value,
  and a write is lent at the place it happens (`!p.shift(1)`), so
  the copy that loses a change cannot be written by accident.
- **Equality.** `Reference#==` is identity (src/reference.cr:60-67),
  `Struct#==` compares fields (src/struct.cr:66), and `same?` tests
  identity (src/reference.cr:71). The same `==` means two things by the
  type's kind. Rig's `==` is by fields, or the type's own `eq` through
  `Eq` on its header (SPEC, "Own meanings"). It gives handles no `==`
  at all (SPEC:5425), which is cleaner.
- **Inheritance and abstract classes.** `abstract def` is checked
  against every implementor (src/compiler/crystal/semantic/abstract_def_checker.cr:1-25),
  as Swift checks protocol conformance. But types are open:
  exhaustiveness skips virtual types "because these can be extended"
  (src/compiler/crystal/semantic/exhaustiveness_checker.cr:24). A
  hierarchy costs the `match` checks that payload enums give for free.
- **Modules as mixins.** `include Comparable(self)` (src/enum.cr:104)
  gives `<`, `<=`, and the rest from `<=>`. This is Swift's
  protocol-extension defaults. Rig already has it: `api` with default
  methods, and `Ord` giving every comparison from `order`.
- **Operator overloading.** Any type may define the operators in
  src/compiler/crystal/syntax/parser.cr:3686-3692: arithmetic, `[]`,
  `[]=`, `[]?`, `<=>`, `===`, `=~`. `Time::Span#+` (src/time/span.cr:313)
  is the good use. `===` and `=~` are the bad one: hooks that `case`
  calls invisibly.

### Overloading and named arguments

- **Overloading by type restriction.** The compiler orders overloads by
  "strictness" (src/compiler/crystal/semantic/restrictions.cr:3-20). The
  ordering is still being redesigned behind
  `-Dpreview_overload_order` (restrictions.cr:70), and its comments
  note that a simpler rule "would break transitivity"
  (restrictions.cr:78). This is Swift's overload-resolution problem,
  and Swift's type checker has the same exponential reputation. Rig is
  right to have one function per name, with polymorphism through APIs.
- **External and internal names.** `def send(message, to addr : Address)`
  (src/socket.cr:302) and `delegate(*methods, to object)`
  (src/object.cr:553) are Swift's argument labels. The parser enforces
  that the two names differ (src/compiler/crystal/syntax/parser.cr:4189-4190)
  and that external names are unique (parser.cr:4042-4043). A bare `*`
  makes what follows keyword-only: `step(*, to limit = nil, by step,
  exclusive : Bool = false)` (src/steppable.cr:32, src/number.cr:155).
  The keyword-only marker matters more than the label split: it is what
  stops `step(10, 2, true)`.
- `def initialize(@name, @age)` assigns fields from parameters. Rig's
  constructors by field name already do this.

### Tuples and named tuples

`{1, "hello"}` and `{name: "Crystal", year: 2011}` are stack values
with types per position or key (src/tuple.cr:1-70,
src/named_tuple.cr:1-60), and "the preferred way to return fixed-size
multiple return values" (src/tuple.cr:56). They carry splats and
`**options`, and so macros. Rig chose differently: several results are
bound by name and "never form a value: a group of values kept past its
statement is an object". That is the better rule for a language without
macros. A named tuple is an anonymous object Rig would have to name,
print, compare, and own.

### Enums and `@[Flags]`

- Crystal enums are integers only, with no payloads. Payloads come
  from unions of types (Swift's payload enums are better, and Rig has
  them).
- `@[Flags]` (src/enum.cr:27-37) makes values powers of two, adds
  `None` and `All`, defines `|`, `&`, `^`, and `~` (src/enum.cr:296-320),
  `includes?` (src/enum.cr:352), iteration over the set members
  (src/enum.cr:379), and printing as `Read | Write`. It is excellent to
  use. But the set and the member are one type, so a `case` on a Flags
  enum can never be exhaustive
  (src/compiler/crystal/semantic/exhaustiveness_checker.cr:169).
- `Color.new(10)` makes an enum value that is no member
  (src/enum.cr:50-55). Rig's `from_int` returning `T?` is right.
- Each member gets a question method, `color.red?` (src/enum.cr:59-70).
  This is clever, but it is a second way to write `== .red`.

### Nil, `try`, `not_nil!`, `||`

- `T?` is `T | Nil`, narrowed by `if x`, `if x = expr`, `is_a?`, and
  `.nil?` (src/compiler/crystal/semantic/filters.cr). The narrowing works
  on locals but not on fields or method results, so code falls back on
  `not_nil!` (src/object.cr:422). Its own docs call it "a code smell"
  and "a last resort" (src/object.cr:414-421), yet the compiler uses it
  213 times and `.try &.` 463 times.
- `ARGV[0]?.try &.downcase` (src/object.cr:389-393) is Swift's `?.`
  chaining as a library method. It is neat.
- `a || b` is both boolean or and nil-coalescing, by truthiness: `nil`
  and `false` are both falsy, so `flag || default` is wrong when `flag`
  is `false`. Rig separates `or` from `??`, which is right.

### Annotations

Five in the stdlib: `Deprecated`, `Flags`, `Link`, `Experimental`, and
`TargetFeature` (src/annotations.cr:29-134). User annotations are read
by macros. `@[Deprecated("Use #write_string instead.")]`
(src/io.cr:495) appears in 78 stdlib files and drives the compiler's
warnings (src/compiler/crystal/semantic/warnings.cr:8-14). It is
well done, but Rig has no warnings by design (see section 4).

### API naming in the stdlib

Ruby's vocabulary: `each`, `map`, `select`, `includes?`, `empty?`,
`to_s`, `inspect`, `receive?`. It is consistent and short. Suffix
punctuation carries meaning: `?` is a predicate or nil-returning, `!`
raises or mutates. Rig spends `?` and `!` on lending, so it rightly
uses `is_empty()` and visible sigils instead. `to_s(io : IO)` beside
`to_s : String` is the same idea as Rig's `print(?@, out: !Printer)`.

### Readability of the code as written

The stdlib reads very well. The compiler reads less well: the 6,621-line
parser threads flags such as `@stop_on_do` and `@def_nest`
(parser.cr:3694-3700), dispatches on node class by overloading, and
falls back on `raise "BUG: called ..."` (restrictions.cr:42-44) for
the overloads no one wrote. Macros inside signatures, such as the
version-gated `@[Deprecated]` in `spawn`'s header
(src/concurrent.cr:79), are hard to read. The specs are thorough and
well named (spec/compiler/semantic/*_spec.cr, for example
`external_internal_spec.cr` and `def_overload_spec.cr`).

### Fibers against Swift's async/await

- **Coloring.** Crystal has no colors, as Rig does not: any function may
  block on I/O, and the scheduler switches fibers. Swift colors with
  `async`, and every caller pays `await`. On this, Crystal and Rig are
  right.
- **Structure.** Swift's `async let` and task groups are structured:
  child tasks end with their scope, and errors and cancellation flow
  to the parent. Crystal's `spawn` is fire-and-forget. A result comes
  back only through a `Channel`, joining needs a `WaitGroup`
  (src/wait_group.cr), there is no cancellation, and an exception is
  printed to stderr (src/fiber.cr:160-164).
- **Capture.** `spawn { print(i) }` in a loop prints `55555`, because
  the block captures `i` by reference; `spawn print(i)` is a macro that
  evaluates the arguments first and prints `01234`
  (src/concurrent.cr:96-118). Rig's `f(x)&` evaluates its arguments
  at dispatch, and its closures name each capture's mode, so the
  footgun cannot be written.
- **Isolation.** Crystal is moving toward execution contexts:
  Concurrent, Parallel, and Isolated (src/fiber/execution_context.cr:1-50),
  but nothing like Swift's `Sendable` or actor isolation checks what
  crosses. Rig's `Sends` and `Syncs` facts and `*Actor` are already
  ahead.

Rig's model (structured `f()&` and `>t`, a task dropped is canceled and
waited for, panics reaching the waiter, `Sends` and `Syncs`) has
Swift's structure without Swift's coloring. Crystal has nothing to
teach Rig here beyond confirming the choice.

## 3. Ideas worth taking, ranked

### 1. A set of enum flags: `Bits[E]` (name is the owner's call)

**Crystal** (src/enum.cr:27-37, 296-320, 352, 379):

```crystal
@[Flags]
enum IOMode
  Read
  Write
  Async
end
mode = IOMode::Read | IOMode::Async
mode.read?             # true
mode.includes?(IOMode::Write)  # false
mode.to_s              # "Read | Async"
mode.each { |m| ... }
```

**Rig has it?** No. Neither SPEC nor STD has a flag set. Trig writes
flags by hand: `ENTITY_SYMBOL: U64 = 1 << 32`
(trig/src/checker/aliases.rig:22), and 2,503 lines of the form
`flags & ast.NODE_FLAGS_AMBIENT != 0` across Trig's sources. These are
unchecked: any `U32` mixes with any other set's bits, and nothing
prints their names.

**Rig form.** Keep the enum a plain enum, and make the set its own
built-in plain type, so `match` on the enum stays exhaustive. This
avoids Crystal's problem at exhaustiveness_checker.cr:169.

```rig pending
enum Access
  read
  write
  exec

sub main()
  a: Bits[Access] = Bits(.read, .write)
  !a.add(.exec)
  !a.remove(.read)
  print(a.has(.write), a.len, a)        # true 2 Bits(.write, .exec)
  b = a | Bits(.read)
  for m in b
    print(m)
  print(U32(b), Bits[Access].all() == b)
```

- **Representation.** The narrowest unsigned integer that has a bit
  for each variant: bit `i` is the variant's declaration index, or its
  value when the enum gives explicit values and they are below 64.
  `Bits[E].from_int(n)` gives `none` for unknown bits, for C and wire
  formats.
- **Operators** are `|`, `&`, `.not()` within the variant set, `==`,
  and `Hash`, as on an integer. Changes are `!a.add(x)` and
  `!a.remove(x)`.
- **Name candidates:** `Bits[E]` (short, but beside `m.bits()` on a
  mask), `Flags[E]` (the word people know), or `EnumSet[E]`. Don't
  make it `Set[E]`, since `Set` is owning and this would be plain.

**Guarantees kept?** Yes. It is plain data, held in one integer, with
no allocation or drop. Every operation is a visible call or operator
on a built-in type, as on `Simd`, and `match` on `E` stays exhaustive.

### 2. Options are passed by name

**Crystal.** `def step(*, to limit = nil, by step, exclusive : Bool = false)`
(src/steppable.cr:32). The bare `*` makes every later parameter
keyword-only, so `1.step(to: 10, by: 2)` reads as prose, and
`step(10, 2, true)` is rejected. Swift gets the same with required
labels.

**Rig has it?** Partly. Keywords are allowed but never required, so
`scaled(3, 2)` passes the defaulted `by` by position (SPEC:1446). Rig's
own std shows the boolean trap: `format_int(n: Int, base: Int = 10,
upper: Bool = false)` (STD.md:2397) accepts `format_int(255, 16,
true)`.

**Rig form:** a rule, with no new punctuation (Rig's taste rules out
Crystal's `*`). A parameter with a default is passed by name.

```rig pending
fun format_int(n: Int, base: Int = 10, upper: Bool = false) -> String
  ...
s = format_int(255, base: 16, upper: true)   # ok
t = format_int(255, 16, true)                # rejected
```

The error would read: `` `base` has a default, so it is passed by name: `format_int(255, base: 16)` ``.

A narrower fallback is "a `Bool` argument is passed by name". The
default proposed is the wider rule: it is one rule, and it is what
Python's keyword-only parameters and Swift's labels converge on.

**Guarantees kept?** Yes; it is a call-site check. It rejects programs
a release accepted (SPEC's own `scaled(3, 2)` example among them), so
it needs a migration script and a note to Trig first.

### 3. Arithmetic operators for plain objects, through own meanings

**Crystal.** `def +(other : self) : Time::Span` (src/time/span.cr:313);
any type may define `+ - * / % [] <=>`
(src/compiler/crystal/syntax/parser.cr:3686).

**Rig has it?** No. "Arithmetic needs numeric operands of one type"
(SPEC §5, "Operators"), and std uses methods: `t.add(ms: 40)` for
`Instant` (STD.md:772). But Rig already routes `==` to `eq` and `<` to
`order` through APIs named on the header (SPEC, "Own meanings"), so
the mechanism exists.

**Rig form:** extend the own-meanings table, and allow it only on
plain objects.

```rig pending
obj Vec2: Add + Sub
  x: Float
  y: Float

  fun add(?@, other: ?Self) -> Self
    Vec2(x: @x + other.x, y: @y + other.y)

  fun sub(?@, other: ?Self) -> Self
    Vec2(x: @x - other.x, y: @y - other.y)

sub main()
  print(Vec2(x: 1, y: 2) + Vec2(x: 3, y: 4))
```

**Guarantees kept?** Only with the limit to plain objects. A plain
value owns nothing, so `+` can hide no allocation and no drop. That
rules out BigInt and String, whose `+` would allocate, which keeps
"no hidden allocation". The call is as visible as `==`'s call to `eq`
already is. No new operators may be declared (Swift's custom operators
are a mistake for Rig), and there is no `===` or `=~`. This is the
owner's call, since it touches "effects stay visible". Default: yes,
for `+ - *` and unary `-` on plain objects only.

### 4. Forward an API to a field

**Crystal.** `delegate downcase, gsub, empty?, to: @string`
(src/object.cr:553). Take this, not `forward_missing_to`
(src/object.cr:677).

**Rig has it?** No; a wrapper writes each forwarding method by hand.

**Rig form:** the forwarding is named by the API, so the set of
methods is closed and checked. Name candidates are `by`, `through`,
and `via`.

```rig pending
obj Counted: Writer by @out
  out: File
  n: Int = 0
```

Every `Writer` method the body does not write becomes `@out.m(...)`,
with self's sigil passed through: `!c.write(s)` lends `c`, which lends
`@out`.

**Guarantees kept?** Yes. The generated methods are ordinary methods
that every checker walks, and each loan is the field's, already
modelled by `from @field`. It is lower value than ideas 1-3; wait for
a second real wrapper in std or Trig.

### 5. Identity of handles

**Crystal.** `same?(other : Reference)` (src/reference.cr:71); Swift
has `===`.

**Rig has it?** No, deliberately: a handle has no `==` (SPEC:5425).
But "is this the same shared object" has a use, such as removing one
observer from a `List[*Obs]`, or detecting the same node in a graph.

**Rig form:** a named method, never an operator: `a.is_same(?b)` for
`*T` and `~T`. Name candidates: `is_same`, `same_as`, `is`.

**Guarantees kept?** Yes. It reads two addresses, and changes and
counts nothing.

### 6. A rendezvous channel, `*Chan[T](0)`

**Crystal.** `def initialize(@capacity = 0)` (src/channel.cr:83). A
send completes only when a receiver takes it.

**Rig has it?** No: `n` is at least one (SPEC §18, "Channels").

**Guarantees kept?** Yes. Low priority: it is a handoff point, a pure
library change in std's channel. It is worth measuring only if a Trig
or bench workload wants one.

## 4. What Rig should not take

- **Unions with flow typing, and untyped parameters** (whole-program
  inference, src/compiler/crystal/semantic/main_visitor.cr). Errors
  land far from their cause, compiles slow down, and fields cannot be
  narrowed, hence 213 `not_nil!` in the compiler itself. Rig's payload
  enums, `T?`, and typed parameters are the Swift answer, and better.
- **`not_nil!`, truthy `||`, and `try` as a method**
  (src/object.cr:391, 422). `not_nil!` is a hidden panic. Rig's `??`,
  `a?`, `if o as x`, and `v if o as x else none` already cover every
  case `try` does, and keep `or` for `Bool`.
- **Overloading by type** (src/compiler/crystal/semantic/restrictions.cr:3-20, 70, 78).
  Its ordering is still being redesigned and hard to keep transitive.
  Rig's one function per name, with APIs for polymorphism, is simpler.
- **External and internal names** (src/compiler/crystal/syntax/parser.cr:4153-4192).
  Two names per parameter break "one word per idea". Idea 2 gives the
  call-site clarity that labels exist for.
- **Inheritance, abstract classes, reopening a type, `method_missing`,
  `forward_missing_to`** (src/object.cr:677). Open types defeat
  exhaustiveness (exhaustiveness_checker.cr:24) and make a call's
  target unknowable from its line. Rig's `api`, `add` in the API's
  module, and payload enums are enough.
- **Value or reference chosen at the declaration** (src/struct.cr:13-36).
  Rig's per-use sigils (`^`, `*`, `!`) dissolve the copy that loses a
  change.
- **Tuples, named tuples, and splats** (src/tuple.cr,
  src/named_tuple.cr). Rig's rule, that a group of values kept past its
  statement is an object, is cleaner without macros.
- **`@[Deprecated]` and annotations in general**
  (src/annotations.cr:29). Rig is errors-only (the owner's decision of
  2026-10-27), and its path for a changed API is a rejection with a
  migration script. General annotations exist for macros, which Rig
  does not have.
- **Two forms of `case`** (`when` and `in`, parser.cr:2885-2900), and
  `===` as a hidden match hook. Rig's one `match`, always exhaustive, is
  better.
- **`?` and `!` in method names, and question methods on enums**
  (src/enum.cr:59-70). Rig spends those sigils on lending, and `==
  .red` or `matches .red` already says it.
- **Enum values that are no member** (`Color.new(10)`, src/enum.cr:50-55).
- **Unstructured `spawn`** (src/concurrent.cr:79, src/fiber.cr:160-164).
  It loses exceptions and has no join, no result, and no cancellation;
  Rig's tasks are already structured.
- **Swift's `async`/`await`.** Crystal is right not to color
  functions, and so is Rig (SPEC §19 already rejects `async` and
  `await` with a pointer to `&` and `>t`).
