# Naming panel, seat 1: programmer happiness and least surprise

The test I bring: read the line aloud to an experienced programmer who has
never seen Rig. Do they smile, or do they look something up? The grammar
already has its best sentence: `obj Square: Shape` reads "Square is a
Shape", just as `x: Int` reads "x is an Int" and `[T: Shape]` reads "T is
a Shape". The colon is the word "is". Every choice below protects that
sentence.

## Top 3 names

### 1. `role`

| Where | Reads |
|---|---|
| declaration | `role Shape` |
| taking it on | `obj Square: Shape` ("Square is a Shape"; in prose, "Square plays the Shape role") |
| bound | `fun total[T: Shape](xs: ?List[T])` |
| error | "`Label` is not `Shape`: `total` needs `T: Shape`; declare `obj Label: Shape`" |
| docs | "Square plays Shape", "Shape is a role", "a role's default methods" |
| plural | roles: "Square plays two roles, Shape and Print" |

Why: an everyday word with one meaning, four letters, the same length as
`enum`. It names the relationship from the type's side, which is how a
reader thinks: a type *is* things and *plays* parts. Its precedent is
Raku, a language designed by a linguist, where roles mean exactly this
(no state, required plus default methods, composed onto a class). It has
no OOP baggage: nobody expects a role to have fields or a constructor. And
"plays" gives one verb that fits every role's name, nouns and short
capability names alike: "Square plays Shape", "Label does not play Hash".

### 2. `trait`

The least surprising word for an experienced reader, and not borrowed
from Rust alone: the 2003 Smalltalk paper that named traits defined them
as Rig does, stateless sets of required and provided methods. Reads
`trait Shape`, "Square has the Shape trait", "traits". Against it: the
owner wants Rig to say something of its own, and in Rust's shadow every
reader will assume Rust's rules (orphan rules, `impl` blocks, `dyn`),
which Rig changes. It is the safe fallback.

### 3. `ability`

`ability Shape`, "Square has the Shape ability", "abilities". It fits the
built-in ones best (Copy, Moves, Shares *are* abilities; Move the language
uses the word for exactly them) and fits defaults well: an ability you
gain, with skills that come with it. Against it: seven letters, and it
reads oddly for a role that is really a noun ("the Source ability").

## Syntax

### Keep
- `obj Square: Shape` on the header. The colon is "is"; nothing beats it.
- No body means required; a body means default. Ruby's lesson: the shape
  of the code says it, no `required` or `default` keyword.
- Overriding a default is just writing the method, with no `override`
  word. The exact-signature check already makes an accidental override
  impossible to get wrong silently.
- `?{Shape}`, `^{Shape}`, `*{Shape}`. Braces as "some member of the set"
  are delightful and cost nothing to learn.

### Change

1. **`and` instead of `+` between roles.** `obj Square: Shape and Print`,
   `[T: Ord and Print]`, `^{Job and Moves}`. Rig already says `and` for
   conjunction; a type position holds no expression, so there is no
   ambiguity; and `+` before a name already means "clone" to a Rig
   reader. "Square is a Shape and Print" is a sentence. "T is Ord and
   Print" is a sentence. `+` is only a Rust habit.

2. **`extend Int: Shape` instead of `impl Int: Shape`.** A plain verb, as
   Ruby's `include` and `extend` are, and as the mantra "actions are
   verbs" asks. It says what happens (you extend a type you do not own)
   instead of naming a compiler concept by an abbreviation. Swift writes
   the same thing `extension Int: Shape`, so it surprises no one. The
   bounded case reads `extend Wrap[T: Shape]: Shape`. `impl` leaves the
   reserved list.

3. **A default stays reachable from an override, by the role's name.**
   `Shape.describe(@)` calls the default, the same spelling Rig already
   uses to pick between two roles' methods (`Shape.area(c)`). This is
   Ruby's `super` without a new keyword or hidden lookup.

4. **Name roles so "X is not R" reads.** Guidance, not syntax: a role is
   named for what its members are, a noun (`Shape`, `Source`) or an
   adjective (`Owned`, Ruby's `Comparable`). The error template "`Label`
   is not `Shape`" then always reads. The built-ins keep their short
   names; the error for them may use "does not play `Hash`" if "is not
   `Hash`" reads badly.

5. **Define one method, get many.** Ruby's happiest idea is that
   `Comparable` gives six operators for one `<=>`, and `Enumerable` gives
   fifty methods for one `each`. Rig's `Ord` already does this with
   `order`. `Iter` should too: write `next`, get `map`, `filter`,
   `count`, `sum`, `any`, `all`, `find` as default methods built on it,
   so `for`-style helpers become `!it.count()` instead of free functions.
   This is where roles earn their keep in daily code.

6. **A method that meets a `pub` role on a `pub` type is public by
   meeting it.** Today forgetting `pub` is an error whose fix is always
   the same word. A rule whose fix is mechanical is ceremony; the role
   already decided the method is visible.

### Full sketch

```text
pub role Shape
  fun area(?@) -> Float                 # required: no body

  fun describe(?@) -> String            # default, built on area
    String("a shape of area ", @area())

pub role Named: Print                   # a role built on another
  fun name(?@) -> ?String from @

pub obj Square: Shape and Print
  side: Float

  fun area(?@) -> Float                 # public by meeting a pub role
    @side * @side

  fun describe(?@) -> String            # overrides; the default stays reachable
    String("square: ", Shape.describe(@))

extend Int: Shape                       # a type you do not own, in the role's module
  fun area(?@) -> Float
    Float(@ * @)

extend Wrap[T: Shape]: Shape            # holds only under a bound
  fun area(?@) -> Float
    @v.area()

fun total[T: Shape and Print](xs: ?List[T]) -> Float
  t = 0.0
  for x in xs
    t += x.area()
  t

fun area_of(s: ?{Shape}) -> Float       # any Shape at run time; braces mark the cost
  s.area()

jobs: List[^{Job and Moves}] = List()
```

## What I'd reject

- **`interface`**: nine letters and Java's baggage; readers expect no
  defaults and runtime casts.
- **`protocol`**: Swift's, long, and in everyday English a network or a
  diplomatic word.
- **`contract`**: promises runtime checks (Eiffel, D), which Rig does not
  do; misleads an experienced reader, the worst surprise.
- **`class`**: Haskell's meaning is exactly right and every other reader's
  meaning is exactly wrong.
- **`mixin`**: Ruby's own spirit, but it names the mechanism (copying code
  in), not the meaning, and reads wrongly for a role with no defaults and
  for `?{Mixin}` as a value.
- **`kind`**: "a kind of Shape" is lovely and Ruby has `kind_of?`, but
  Rig already spends "kind" on kinds of value (plain, unique, handle).
- **`impl`**: an abbreviation of a compiler concept; Rig's words are
  plain English.
- **A `where` clause, an `override` keyword, a `required` marker**: each
  says what the layout already says.
