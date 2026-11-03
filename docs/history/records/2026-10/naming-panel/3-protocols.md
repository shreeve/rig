# Naming panel 3: the Swift view

Written in the spirit of the Swift language team's design philosophy (protocol-oriented programming,
the API Design Guidelines, and the lessons of `any`, PATs and retroactive conformance). Not a claim
to speak for any person.

## What Swift learned that matters here

1. **The existential must look different from the constraint.** For years Swift wrote `Shape` for
   both "some one type, known at compile time" and "any type, boxed, dispatched at run time". Users
   reached for the second by accident and paid for it. SE-0335 added `any` to repair that, years
   late. Rig's `{Shape}` behind a holding sigil solves this on day one. Keep it as it is.
2. **"Protocol with associated type" errors were the worst message Swift ever had.** The fix
   (SE-0309) was to allow every protocol as an existential and refuse only the members that cannot
   work. Rig's Stage 4 rule already does this. Swift then needed a way to name associated types on
   an existential, `any Collection<Int>` (SE-0346). Rig will need the same thing the day `^{Iter}`
   exists, so it should reserve the spelling now: `{Iter[Int]}`.
3. **A default must be a customization point, never a shadow.** A Swift method defined only in a
   protocol extension dispatches statically, so a type's "override" is ignored behind a generic.
   That is the most-cited trap in protocol-oriented programming. In Rig a default is a member of the
   role, so every default can be overridden. Keep it that way: helpers that must not be overridden
   are plain generic functions, not role members.
4. **Near-miss conformance is a silent bug.** A type's method with a slightly wrong signature
   leaves the default in use without any warning. Rig should make a method that has a default's name
   and any other signature an error, as Stage 2 already does for `eq` and `hash`.
5. **Retroactive conformance across modules breaks programs.** Swift allowed it anywhere, and
   SE-0364 had to add `@retroactive` warnings later. Rig's coherence rule (only in the type's module
   or the role's module) solves this. Keep it.
6. **Conformance reads as "is".** `struct Square: Shape` reads "Square is a Shape". The error
   template "`Label` is not `Shape`" depends on this, so the construct's word rarely appears in
   messages. What appears is the name of each role, so naming the instances matters more than naming
   the keyword.

## Top 3 names

### 1. `role`
- Declaration: `role Shape`
- Taking it on: `obj Square: Shape + Print`
- Bound: `fun total[T: Shape](xs: ?List[T])`
- Error: "`Label` is not `Shape`: declare `obj Label: Shape`". The keyword appears in only one
  message: "`Shape` is a role, not a type: write `[T: Shape]` or `?{Shape}`".
- Docs: "Square is a Shape"; "Square plays the Shape role"; "Shape's duties".
- Plural: roles.
- Why: four letters, plain English, a noun. Raku's `role` has this same design (required and default
  methods, no state, composed into a class), so the word already means this somewhere. A role
  carries duties as well as method names, and that suits Swift's point that a protocol has semantic
  requirements: `Hash` must agree with `Eq`, and `Ord` must be a total order.

### 2. `protocol`
- Declaration: `protocol Shape`. Bound and header as above.
- Error: "`Shape` is a protocol, not a type".
- Docs: "Square conforms to Shape". Plural: protocols.
- Why: it is exact, it carries the "requirements plus semantics" meaning, and Swift and Objective-C
  readers know it. Against it: eight letters among `obj`, `sub` and `fun`; a networking meaning; and
  it drags "conforms" into the prose.

### 3. `trait`
- Declaration: `trait Shape`. Error: "`Shape` is a trait, not a type". Docs: "Square has the Shape
  trait". Plural: traits.
- Why: honest and widely known from Rust, Scala and PHP. But it is the word Rig is trying to get
  past, and "a trait" suggests a single property more than a set of duties.

## Built-in names

Swift's guideline says nouns name what a thing is (`Collection`) and `-able`/`-ible` names a
capability (`Equatable`, `Hashable`). That is right for English but costly for Rig, which writes
`hash.Map[K: Hash, V]` often. The deeper lesson is that each family should follow one rule, and the
docs should state that rule:

- **Operations are named for the operation they grant, or for its method:** `Eq` (`eq`, `==`),
  `Hash` (`hash_into`, `.hash()`), `Ord` (`<`), `Print` (`print`), `Copy` (bare use), `Clone`
  (`+x`), `Iter` (`for`). Keep these. `Ord` is the one true abbreviation, but `Order` is already
  taken by the enum, and `Comparable` is too long.
- **Facts are named as what the type does or is:** `Owned`, `Moves`, `Shares`. Keep these as
  SPEC §18 has them. Swift's `Sendable` is the precedent for naming crossing, and Rig's words are
  better because they say which kind of crossing.
- **User roles are nouns** (`Shape`, `Job`, `Source`) or `-able` adjectives (`Drawable`), and never
  verbs.
- **Consequence for errors:** "`Label` is not `Hash`" reads badly. Errors about built-ins should
  name the missing operation instead: "`Label` has no `.hash()`: declare `obj Label: Hash`", and
  "`Job` does not move to another task". Errors about user roles keep "is not".

## Syntax sketch

```text
role Shape
  fun area(?@) -> Float                  # required: no body
  sub describe(?@)                       # default: a customization point, overridable
    print("area", @area())

role Named: Print                        # builds on another role
  fun name(?@) -> ?String from @

role Iter
  type Item                              # associated type, read I.Item
  fun next(!@) -> Item?

obj Square: Shape + Print                # the type's own module: on the header, as now
  side: Float
  fun area(?@) -> Float
    @side * @side
  sub describe(?@)                       # override: same name, same signature; a near-miss is an error
    print("square", @side)

extend Int: Shape                        # a type you do not own, in Shape's module
  fun area(?@) -> Float
    Float(@) * Float(@)

extend Wrap[T: Shape]: Shape             # holds only under a bound
  fun area(?@) -> Float
    @v.area()

fun total[T: Shape](xs: ?List[T]) -> Float
fun area_of(s: ?{Shape}) -> Float
shapes: List[^{Shape}]
jobs: List[^{Job + Moves}]
lines: ^{Iter[String]}                   # reserved now: an associated type pinned on an object (Swift SE-0346)
```

Changes, and why:

- **`impl Int: Shape` becomes `extend Int: Shape`.** `impl` is Rust's abbreviation, and Rig already
  replaces Rust's words (it says "lend", not "borrow"). `extend` says exactly what the reader needs:
  this type lives elsewhere and gains something here. It is Swift's word for the same act, and it
  covers the conditional case without a `where`.
- **Methods of an `extend` stay inside its indented block,** not written as `fun Int.area` at module
  level. They belong to the conformance, not to `Int` everywhere. Swift's extension methods on
  foreign types leak into every importer's namespace, and this avoids that.
- **No `override` keyword.** Exact matching plus a near-miss error catches the bug a keyword would
  catch, at less noise.
- **Keep `+` for composition and `{Shape}` for objects.** Both are already consistent with
  `{Job + Moves}`.
- **Leave room for opaque results.** Swift found `some Shape` essential once iterators and closures
  were chained, because it returns one hidden concrete type with no box. Rig does not need it yet,
  but it should never let a bare `Shape` in a type position mean anything, so that the spelling
  stays free.

## Rejected

- **`interface`:** long; it implies Java's structural or field-bearing contracts and Go's implicit
  conformance, which Rig rejects.
- **`contract`:** promises preconditions and postconditions (Eiffel, Solidity) that Rig does not
  check.
- **`ability`:** Move uses it for built-in markers, and "Shape is an ability" misreads a noun-like
  role.
- **`class` (Haskell's typeclass):** it collides with every OOP reader's meaning.
- **`impl`:** Rust jargon and an abbreviation; replaced by `extend` above.
- **`-able` for every built-in (`Equatable`, `Hashable`):** correct English, but too long for Rig's
  brackets. Fix the error text instead.
