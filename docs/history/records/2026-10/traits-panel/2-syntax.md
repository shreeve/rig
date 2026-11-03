# Traits panel 2: syntax, readability, teaching

Read against origin/main 59a8c9a18: mantras, DESIGN (sigil algebra, "Brackets for compile time",
"Per-instance checking"), QUICK, SYNTAX §3, §5 "Self sigils", §8, journeys 01 and 02, SPEC error
blocks, and `bin/rig check` output for today's generic and self-sigil errors.

## 0. What is a sigil here, and what is a word

Traits add **no new sigil**. Every mechanic a trait touches already has one: the self sigils
`?@ !@ <@` in trait methods, the view and handle sigils `? ! ^ * ~` in front of a trait object,
and the lends at calls. What traits add is vocabulary for contracts between libraries, which the
mantra gives to words:

| Form | Kind | Meaning |
|---|---|---|
| `trait`, `impl` | keyword (both reserved today) | declare a trait; declare a conformance the header cannot |
| `any` | contextual word, only right after `? ! ^ * ~` in a type | "some type that is `Shape`, known at run time" |
| `type Item` | existing keyword, new member position | an associated type |
| `X: Shape` | existing punctuation, from `name: Type` | "is a" (header, bound, supertrait, `impl`) |
| `A + B` | infix in a bound list only | "and also" |
| `Copy`, `Hash`, `Shape` | capitalized names, type namespace | library vocabulary, built-in or not |

A trait object deserves a word, not a sigil and not nothing. Not nothing: a bare `?Shape` reads as
a concrete type, and the cost (an indirect call that ends inlining) would sit where no mark is;
Rust paid for that and added `dyn`. Not a sigil: erasure is not an act on a value at a place, it
happens at an expected type, as a named `fun` becomes a `?fun` today with no mark. Of the words,
`any` beats `dyn` (jargon) and `Dyn[Shape]` (brackets would hand a trait to a type that has no
values of its own, and `?Dyn[Shape]` reads as a view of a `Dyn`). `?any Shape` reads aloud as
English: "a read view of any shape". Swift chose the same word. `m.any()` on masks is untouched,
since `any` is a word only after a view or handle sigil in a type.

## 1. The canonical surface

**A trait, with a default method and an associated type.** A member without a body is required;
with a body it is a default. `Self` is the conforming type, `@` its value, as in an `obj`.

```rig
pub trait Shape
  fun area(?@) -> Float

  fun describe(?@) -> String          # default
    String("a shape of area ", @area())

pub trait Source
  type Item

  fun next(!@) -> Item?
  fun remaining(?@) -> Int             # default
    0

trait Named: Print                     # supertrait
  fun name(?@) -> ?String from @
```

**Conformance: the header.** Both candidates were weighed. The header wins for a type's own
module: it is where a reader learns what a type is (`unique` already sits there), the methods stay
ordinary methods in or beside the body as SPEC §3 says, and it is shorter than Rust. Type members
come first, then fields, then methods.

```rig
pub obj Square: Shape + Print
  side: Float

  pub fun area(?@) -> Float
    @side * @side

obj Countdown: Source
  type Item = Int
  n: Int

  fun next(!@) -> Item?
    return none if @n == 0
    @n -= 1
    @n + 1
```

`obj Ticket unique: Print` keeps `unique` where SYNTAX puts it, right after the name.

**Conformance: `impl`, only where the header cannot say it.** Two cases, and each has a reason:
a type of another module or a built-in type, written in the trait's module; and a conformance that
holds only under a bound. It is spelled `impl Type: Trait`, the same `X: Trait` as the header and
the bound, not Rust's `impl Trait for Type`, whose `for` is Rig's loop word.

```rig
# in module shapes, which declares Shape
impl Int: Shape
  fun area(?@) -> Float
    Float(@ * @)

# in Wrap's module: Wrap[T] is a Shape when T is
impl Wrap[T: Shape]: Shape
  fun area(?@) -> Float
    @v.area()
```

An `impl` in the type's own module with no bound is rejected toward the header form, so each case
has one spelling.

**Visibility.** A method that meets a `pub` trait on a `pub` type is callable from other modules,
so it says `pub`, as DESIGN's "the `pub` surface is exactly what it spells out" requires. Leaving it
off is an error with the fix (below), not an inference.

**Bounded generics.** All bounds live in the brackets, since square brackets mean compile time;
there is no `where` clause after a header.

```rig
fun total[T: Shape](xs: ?List[T]) -> Float
  t = 0.0
  for x in xs
    t += x.area()
  t

sub show_all[T: Shape + Print](xs: ?List[T])
  for x in xs
    print(x, x.area())

fun largest[S: Source, S.Item: Ord](s: !S) -> S.Item?
  best = (!s).next()?
  while (!s).next() as x
    best = x if x > best else best
  best

obj Sorted[T: Ord]
  items: List[T]

  sub insert(!@, x: T)
    ...
```

`S.Item: Ord` is a bracket entry whose left side is a path, so it can never be read as a new
parameter. A method of `Sorted` written outside the body is `fun Sorted[T].insert`: the type's bound
holds for all its methods, and repeating it adds nothing, so it is rejected (the absorption law).

**A conditional method.** A bound in a method's type brackets means "only when":

```rig
obj Wrap[T]
  v: T

fun Wrap[T: Print].show(?@)
  print("wrapped", @v)
```

**Trait objects (a later phase).** Always behind a view or a handle; made at an expected type;
called like any method.

```rig
fun area_of(s: ?any Shape) -> Float
  s.area()

sub main()
  sq = Square(side: 2.0)
  print(area_of(sq))                   # lends `?any Shape`, unmarked like any read
  shapes: List[^any Shape] = List()
  !shapes.push(^Square(side: 3.0))
  !shapes.push(^Circle(r: 1.0))
  for s in ?shapes
    print(s.describe())
  jobs: List[^any Job + Sends] = List()   # crossing is a bound, not a trailing word
```

**Qualified call**, when two imported traits give one type the same name: `Shape.area(c)`, with
the self sigil written as at any call (`Shape.grow(!c, 2)`).

## 2. The errors a newcomer meets most

Written as SPEC error blocks read: the error line, then notes. Each names the fix.

The commonest of all, for a reader from Go, Java, or TypeScript:
```error
`Shape` is a trait, not a type: write `[T: Shape]` for one type known when compiling, or `?any Shape` for any type at run time
```

**Missing bound**, in the body and at the call:
```error
`T` has no method `area`: `total[T]` gives `T` no bound; write `[T: Shape]`, which declares `area`
```
```error
`total[Label]` cannot use `T = Label`: `total` needs `T: Shape`, and `Label` is not `Shape`; declare `obj Label: Shape`
```
```error
`hash.Map[Reading, Int]` cannot use `K = Reading`: `Map` needs `K: Hash`, and `Reading` is not `Hash`
field `value` is a `Float`, which `Hash` does not take; declare `fun hash(?@) -> U64` on `Reading`
```

**Missing method:**
```error
`Square` is declared `Shape` but has no method `area`; declare `fun area(?@) -> Float` in `Square`
`area` required here, by `Shape`
```

**Self sigil mismatch**, both directions (modes match exactly, panel 1's default):
```error
`Counter.next` takes `self` as `?@`, but `Source` declares `next(!@)`; a method meets its trait with the same self: write `fun next(!@) -> Item?`
`next` declared here, in `Source`
```
```error
`Counter.peek` takes `self` as `!@`, but `Source` declares `peek(?@)`, so a caller through `Source` only reads; keep the change out of `peek`, or declare `peek(!@)` in `Source`
```
```error
`Log.watch` keeps `s`, but `Watcher.watch` keeps nothing: a call through `Watcher` would end the loan on `s` while `Log` still views it; add `keeps s` to `Watcher.watch`
```

**Visibility:**
```error
`area` meets `pub trait Shape` on `pub obj Square`, so other modules call it: write `pub fun area`
```

**Object-unsafe method**, at the call through the object:
```error
`twin` cannot be called through `?any Shape`: it gives a `Self`, and `any Shape` does not say which type that is; call it where the type is known, as in `[T: Shape]`
```
```error
`scaled[U]` takes compile-time parameters, so it cannot be called through `^any Shape`; call it where the type is known, as in `[T: Shape]`
```
```error
`any Shape` has no size of its own: hold it in a view or a handle, `?any Shape` or `^any Shape`
```

**Coherence:**
```error
`impl geo.Circle: Shape` is in module `app`, but a conformance lives with its type or its trait: in `geo`, which declares `Circle`, or in `shapes`, which declares `Shape`; here, wrap it: `obj AppCircle: Shape` holding a `geo.Circle`
```
```error
`geo.Circle` is `Shape` twice: here, and on its header in `geo`; a type meets a trait once in a program, so remove this `impl`
`obj Circle: Shape` declared here
```
```error
`c.area()` could call `Shape.area` or `Region.area`, which both apply to `geo.Circle`; name the trait: `Shape.area(c)`
```

## 3. Journey 07, "Generics and compile time"

Assumed phase 1: built-in bounds derived from a type's parts, user traits with static dispatch,
header conformance, `impl` in the trait's module, defaults, supertraits, associated types,
conditional methods. No trait objects.

**Opening problem.** The largest item of a list, a function every reader has written. In C it is a
macro or a copy per type; Go once used `interface{}` and a cast; C++ templates check nothing until
a page of errors at the instance; Rust writes `fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T`.
Rig: one body, brackets, and a signature that says what `T` must do.

Sections, each opening on a whole program:
1. **One body, many types.** `max[T]`, inferred and explicit (`max[Float](1, 2)`). Runs.
2. **What the compiler makes.** `rig emit`: `fn max(comptime T: type, ...)`, one instance per type,
   no run-time cost. Runs.
3. **Values known when compiling.** `[n: Int]`, `Ring[T, n]`, `[mode: Mode]`, `$size(T)`. Runs.
4. **Saying what a type must do.** `sort.sort[T: Ord]`, `hash.Map[K: Hash, V]`. Runs; reject: a
   `Map` keyed by a type with a `Float` field (the error at the user's line).
5. **A trait of your own.** `Shape`, `obj Square: Shape`, `obj Circle: Shape`, `total[T: Shape]`.
   Runs; rejects: missing method; `Shape` used as a type.
6. **When a method does not match.** Rejects: `?@` against `!@`; a `keeps` the trait does not
   declare. Explains why exact modes keep calls reading the same.
7. **Defaults and building on another trait.** `describe` used and overridden; `trait Named: Print`.
   Runs.
8. **A type a trait names.** `Source`, `type Item`, `largest[S: Source, S.Item: Ord]`. Runs.
9. **Methods only some instances have.** `fun Wrap[T: Print].show`; `impl Wrap[T: Shape]: Shape`.
   Runs; reject: `.show()` on `Wrap[Socket]`.
10. **A trait for a type you did not write.** `impl Int: Shape` in the trait's module. Runs; rejects:
    the same `impl` in a third module; two traits' `area` on one type, then `Shape.area(c)`.
11. **What a call through a bound costs.** `rig emit` shows the witness call `W_T_Shape.area(x)`;
    `rig check --facts=sema` prints `dispatch ... static Shape.area on T`. Runs.
12. **Many kinds in one list, today.** An enum with payloads and one `match` per method; a
    struct of `*fun` fields. Runs.
13. Summary, What is not there yet, Where to go next (08 Tests; SPEC §3, §16; DESIGN).

Summary table rows: what brackets hold; what a bound promises; where a conformance is written;
what a body may call; what a call costs; where an error lands.

Summary rule:

**A generic signature says what its types must do; the body may use no more, and each call must
give no less.**

What is not there yet (phase 1 only):
- Trait objects, `?any Shape` and `^any Shape`: one list of open, cross-module kinds. Today, an enum
  or closures.
- Ordering and printing of your own: `Ord` and `Print` are derived, not written.
- An unbounded `[T]` is still checked per instance for built-in operations; requiring the bound,
  with `rig fix` to write it, is planned.
- Traits with parameters (`trait Into[T]`), associated constants, and bounds for task crossing.
- Generic closures, as before.

## 4. Panel 1's syntax recommendations, ranked

| Recommendation | Verdict |
|---|---|
| `trait Name`, indented members, `pub trait` | keep |
| `[T: Ord]`, `[T: Ord + Print]` | keep; `+` has no other infix meaning in a type |
| bound on a method's own parameter `fun map[U: Print]` | keep |
| conditional method `fun Wrap[T: Print].show` | keep; add: repeating a type's own bound is rejected |
| supertrait `trait Hash: Eq` | keep |
| associated types `type Item` / `type Item = Int` / `I.Item`, over generic traits | keep; `Item` bare inside the trait and the type |
| header conformance `obj Square: Shape` (types) | keep; several as `: A + B` |
| no call-site mark for a dynamic call (backend) | keep |
| the `dispatch` fact printed by `--facts=sema` (backend) | keep; journey 07 shows it |
| object made at an expected type by an ordinary lend (ownership) | keep |
| capitalized type parameters as a rule | keep |
| trait method headers restate `from` and `keeps` (ownership) | keep; an impl restates its full header |
| retroactive `impl Shape for geo.Circle` | change: `impl geo.Circle: Shape` |
| conditional conformance `obj Wrap[T]: Print where T: Print` | change: `impl Wrap[T: Print]: Print` |
| `where` for associated and compound bounds | change: in the brackets, `[S: Source, S.Item: Ord]`; no `where` |
| trait objects `?Tr`, `^Tr` bare (ownership) | change: `?any Tr`, `^any Tr` |
| `?dyn Shape` or `Dyn[Shape]` (backend) | change: `any` |
| `^(Tr + Owned)` (ownership), `^dyn Job moves` (backend) | change: `^any Job + Sends`; facts are bounds |
| marker names `Move` (types), `Moves` (ownership) | change: every `T` moves, so the task one is `Sends` (what `&` does) |
| `Shape.area(?c)` | change: `Shape.area(c)`, sigils as at any call |
| associated constant `SIZE: Int` in a trait | change: defer; `name: Type` is a field's form, decide with fields in traits |
| `impl Source for Buf` (ownership) | drop: the header form |
| `obj Circle impl Shape` (backend) | drop: `obj Circle: Shape` |
