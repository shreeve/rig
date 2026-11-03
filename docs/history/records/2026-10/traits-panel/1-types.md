# Panel 1, types and generics: what traits are and how bounds read

## Where Rig is, in one fact

Today a generic body may apply only built-in operations to a `T`: arithmetic, ordering, `==`, `.hash()`,
printing, copying, moving. Calling any method is rejected (checked with `bin/rig check`):

```
error: a generic parameter `T` has no methods; generic bodies can only move, copy, and compare `T` values
```

So "per-instance checking" is a Zig-style model for a fixed set of operators only. The gap traits fill is not
mainly better errors: without them, no generic body can call a user's method. Three other facts sharpen it:
- SPEC §5: an instance whose type declares its own `hash` is rejected in a generic body, since the body calls
  the built-in one. A type cannot both customize `hash` and be a `hash.Map` key.
- DESIGN names the cost itself: the recorded requirements are an unwritten contract, and a library that
  starts using a new operation on `T` breaks its importers.
- ROADMAP: Zig-backed generic declarations have no body to infer from, so they need declared bounds.

## Q1. Traits, or bounds alone?

- **A. Extend duck typing to methods** (Zig, C++ templates). A body may call `x.area()`, checked per instance.
  Nothing to declare, but signatures still say nothing, errors land at the instance, and two types whose
  `area` means different things satisfy it by accident. It deepens the unwritten contract.
- **B. Bounds as named method sets** (C++ concepts, Go constraint interfaces). A name for a list of
  signatures, with no declared conformance.
- **C. Traits**: a named set of methods, associated types and default methods, with declared conformance,
  and a body checked once against its bounds.

What bounds buy: (1) errors at the signature and the call ("`Point` is not `Hash`, which `Map` needs for
`K`"), (2) the signature is the documentation and the contract across modules, (3) a generic body checked once
in full, so a library author sees a break before any importer does, and (4) a Zig-backed declaration can state
what it needs. Lowering does not change: a bounded `T` is still a `comptime T: type`, one instance per type,
and `x.area()` emits a direct call to `Point.area`. Dispatch stays static and visible in the IR.

**Default: C, static dispatch only.** Trait objects (`dyn`) stay out. Owned closures already cover the
dynamic case, and a later panel can revisit them.

## Q2. Structural or nominal; where an implementation lives

- **A. Structural everywhere** (Go). Any type with the methods satisfies the trait. There is nothing to write,
  but it allows accidental conformance, gives default methods and associated types no home, and makes a
  mismatch in a self sigil (`?@` against `!@`) a confusing "does not satisfy".
- **B. Nominal everywhere** (Rust, Haskell). Every conformance is written, including `==` and printing. The
  intent is explicit, but it is heavy for what the compiler already knows from a type's parts.
- **C. Split along the mantra.** *Sigils are mechanics, words are libraries.* Capabilities the language itself
  defines (`==`, copy, move, share, clone, print, hash, `for`) are **facts the compiler derives** from the
  type, as kinds are today, and each has a built-in trait name. Library and user traits are **nominal**, with
  conformance declared.

**Default: C.** For declared conformance, follow Swift: write it on the type's header, and the methods are the
type's ordinary methods, in its body or beside it, exactly as today:

```rig
trait Shape
  fun area(?@) -> Float
  fun describe(?@) -> String          # a default method
    String("shape of area ", @area())

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side
```

**Where an implementation lives: the type's module or the trait's module, nowhere else.** This is Rust's
orphan rule without its extra cases, and it extends the rule SPEC §3 already states ("methods a type gains
from elsewhere are what traits are for"). In the type's module, the header says `: Shape`. In the trait's
module, a retroactive block adds the conformance to a foreign or built-in type:

```rig
impl Shape for geo.Circle
  fun area(?@) -> Float
    3.14159 * @r * @r
```

Coherence follows: at most one implementation of a trait for a type in the whole program, so each is found in
one of two known places. A retroactive method is callable as `c.area()` only in modules that import the
trait's module. If two imported traits give one type the same method name, the call is rejected with a hint
to write `Shape.area(?c)`. One namespace of methods per type, which is Swift's choice, keeps `p.m()` meaning
one thing. A type cannot satisfy two traits that require one name with different signatures, and is rejected
where it declares them.

The method signature must match the trait's exactly, self sigil included. `from` and `keeps` are part of the
signature: an implementation may keep less than the trait declares, never more. Panel 2 owns the details.

## Q3. Syntax

| Form | Default |
|---|---|
| declaration | `trait Name` with indented members; `pub trait` to export |
| one bound | `fun max[T: Ord](a: T, b: T) -> T` |
| several bounds | `[T: Ord + Print]` (`+` in a type position has no other meaning; a comma would split parameters) |
| bound on a method's own parameter | `fun map[U: Print](?@, f: fun(T) -> U) -> Wrap[U]` |
| conditional method | `fun Wrap[T: Print].show(?@)`: it exists only when `T` is `Print`, written the way methods outside the body already name the type's parameters |
| conditional conformance | `obj Wrap[T]: Print where T: Print` |
| supertrait | `trait Hash: Eq` |
| associated type | `type Item` in the trait, `type Item = Int` in the implementing type; read as `I.Item` |
| associated constant | `SIZE: Int` in the trait; second phase |
| `where` | only for bounds an inline bound cannot write: on an associated type or a compound type (`where I.Item: Ord`) |

Several bounds, alternative: `[T: Ord, T: Print]`, or `where` for everything (Rust's long form). `+` is
shorter and reads as "and also". `&` (Swift, TypeScript) collides with task start.

`[n: Int]` against `[T: Ord]`: ROADMAP already decides this by what the name after `:` denotes, a type or a
trait. Traits share the type namespace, so the compiler can always tell. For readers, an option is to make the
existing case convention a rule: a type parameter is capitalized, a value parameter is not. **Default: adopt
the rule**, since it costs nothing in today's code.

Associated types, or a generic trait (`trait Iter[T]`)? A generic trait needs a second parameter at every use
(`fun sum[I: Iter[T], T]`) and lets one type be `Iter[Int]` and `Iter[String]` at once. An associated type
reads as `fun sum[I: Iter](it: !I) -> I.Item`. **Default: associated types**, with trait parameters
(`trait Into[T]`) allowed too, since the brackets fall out of §16.

## Q4. Built-in capabilities as traits

Each built-in capability gets a name a bound can use. Each is derived from the type's parts, as `==` and
`.hash()` are today:

| Trait | Means | Derived when | Hand-written? |
|---|---|---|---|
| `Copy` | a bare name copies | plain data | no (an ownership fact) |
| `Clone` | `+x` | the type has a clone today | no |
| `Move`, `Share` | may cross to a task | the task table | no |
| `Eq` | `==`, `!=` | `==` compares it today | yes: a declared `eq` replaces the derived one |
| `Hash: Eq` | `.hash()` | as today | yes: a declared `hash` replaces it, and **a generic body calls that one**, which fixes the SPEC §5 rejection |
| `Ord: Eq` | `<` and its kin | numbers, plain enums, text | second phase: user order via `fun order(?@, other: ?Self) -> Order` |
| `Print` | `print` | every printable type | second phase: user formatting |
| `Num` | arithmetic and literals beside a `T` | numbers | no |
| `Iter` | `for x in !it`; `type Item` | the type declares `next(!@) -> Item?` | it *is* the declaration |

There is no `Drop` trait. A `drop` body decides a type's kind, and a bound on it means nothing; Rust's
experience says the same. An unbounded `T` keeps today's meaning: it may own a resource, so it moves and
drops, and is never copied.

std requirements, default yes: `hash.Map[K: Hash, V]`, `hash.Set[K: Hash]`, `sort.sort[T: Ord]`,
`sort.search[T: Ord]`, while `sort_by` stays unbounded. That is "concentrate the pain": the error moves from a
note deep in `std/hash.rig` to `Map[Reading, Int]` at the user's line.

## Q5. Migration

- **A. Keep both.** Unbounded `T` stays per-instance checked for built-in operations, and bounds are needed
  only for methods. Nothing breaks, but there are two models forever, and the unwritten contract remains.
- **B. Hard switch.** Every operation on `T` must be named by a bound. This is clean, but it breaks every
  generic at once.
- **C. Staged switch, mechanized.** The compiler already records exactly what each body does with `T`, so it
  can write the bounds. Phase 1: traits land, and method calls need a bound (nothing breaks, since such calls
  are rejected today). Phase 2: an unbounded use of a built-in operation becomes an error whose fix-it names
  the bound (`fun max[T]` → `fun max[T: Ord]`), and `rig fix` applies the fix-its across a tree, std first.
  Phase 3: per-instance checking retires from DESIGN, SPEC §3 and §16, FAQ and WELCOME.

**Default: C.** One residue stays an instance check: whether a literal fits each instance's `T` (`x * 300`
with `T = U8`). `Num` says arithmetic is allowed, not each type's range. Either keep that check, reported as
today, or require `T(300)`. Default: keep it, as the one documented instance check.

## Summary of defaults

1. Traits, not only bounds or duck typing; static dispatch only, no trait objects for now.
2. Built-in capabilities are derived traits; library and user traits are nominal.
3. Conformance is written on the type's header, with ordinary methods; a retroactive `impl T for X` is allowed
   only in the trait's module, and there is one implementation per program.
4. Syntax: `[T: A + B]`, `trait X: Super`, default methods, associated types, `where` only for associated or
   compound bounds, and conditional methods `fun Wrap[T: Print].show`.
5. The names are `Copy`, `Clone`, `Move`, `Share`, `Eq`, `Hash`, `Ord`, `Print`, `Num` and `Iter`; there is
   no `Drop`; user `eq` and `hash` now; user `Ord` and `Print` in a second phase.
6. std bounds `hash.Map` and `hash.Set` keys with `Hash`, and `sort` and `search` with `Ord`.
7. Migration is staged and mechanized from the recorded requirements; literal range stays the one instance
   check.
8. Make the case convention a rule: capitalized type parameters, lowercase value parameters.
