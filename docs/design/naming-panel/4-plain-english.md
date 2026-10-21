# Naming panel, seat 4: the plain-English critic

Lens: read each word aloud, in an error message, and in a teaching sentence; keep one meaning per word
and one word per meaning.

## 1. The name: `role`, confirmed

Ten sentences:

1. Declaration: `role Shape`. Short, a noun, the same length as `enum`.
2. Header: `pub obj Ticket unique: Print + Eq + Hash`. The word does not appear; the colon carries it.
3. Bound: `fun total[T: Shape](xs: ?List[T])`. The word does not appear either.
4. Error: "`total` needs `T: Shape`, and `Label` does not play `Shape`; declare `obj Label: Shape`."
5. Error: "`Shape` is a role, not a type: write `[T: Shape]` or `?{Shape}`."
6. Error: "`Square` plays `Shape` but has no `area`: write `fun area(?@) -> Float`."
7. Error: "`extend` needs a role: write `extend Int: Shape`; another module's type gains methods only
   through a role."
8. Error (built-in): "`Label` cannot be hashed: `hash.Map` needs `K: Hash`; declare `obj Label: Hash`."
9. Docs: "Square plays Shape and Print." "Eq, Hash, Ord, Copy and Moves are built-in roles."
10. Teaching: "A role is a named set of methods a type promises to have. Some come with a body, a
    default, which the type may replace. A type plays a role by naming it on its header."

Every sentence reads. "Play a role" is a fixed English idiom, so the verb comes free with the noun,
which no rival offers (`trait` has no verb; "conforms to a protocol" is two words of jargon).

Two costs to state now:

- **Make `role` (and `extend`) position keywords, like `obj`**: keywords only at the start of a
  declaration, before a type's name. `role` is a common local and field name in application code
  (`user.role`, a `role` parameter), and `extend` is a common method name. Reserving them outright
  would cost both.
- **One meaning in the docs.** `docs/internals/INTERNALS.md` already uses "roles" for the slots of a
  grammar node. Reword those ("fields" or "slots") so "role" means one thing in Rig's prose.

## Decisions

| # | Question | Pick | Reason |
|---|---|---|---|
| 1 | Name | `role` | Reads in every sentence above; brings its own verb. |
| 2 | Joining | `+` | `and` brings in `or` and `not`, which readers would expect to work in types, and puts an expression keyword into type positions; `+` keeps a list such as `Print + Eq + Hash` together as one entry, in headers, bounds, braces and messages. |
| 3 | A type you do not own | `extend Int: Shape` | A plain verb that gives the act a name for prose and errors ("an extension"); a bare `Int: Shape` line has no word to name it in an error and reads like a stray type annotation. |
| 4 | `pub` on methods that meet a role | Must write `pub` (as approved) on the header form; no `pub` inside an `extend` | The body is where a reader looks for a type's API, and dropping `: Shape` from a header must not quietly make methods private. An extension's methods are the role's, reachable only where the role is. |
| 5 | Calling a default from an override | Nothing, for now | `Shape.area(c)` already means "c's own `area` for Shape", which is the override; using the same spelling for the default's body would give one form two meanings. If it is wanted later, it needs a spelling of its own. |
| 6 | Defaults are members, always overridable | Adopt, with the near-miss error | It is already the design. A same-named method with another signature must be an error, never a silent shadow. |
| 7 | Built-in names and their errors | Keep the names; adopt operation-named errors, worded as what cannot be done | "`Label` has no `.hash()`" is false when `Label` has an ordinary method named `hash`. Say "cannot be hashed / compared with `==` / ordered / printed / copied / cloned / moved to another task / shared between tasks". |
| 8 | `Iter` defaults (map, filter, count, sum...) | Later, as one std decision | `map` and `filter` must return adapter types, which needs opaque results Rig lacks; move `count` and `sum` with them so the family follows one rule. |
| 9 | `{Iter[...]}` reserved; a bare role name means nothing in types | Adopt, spelled by name: `{Iter[Item: Int]}` | The positional `Iter[Int]` would clash with roles that take parameters (`Into[T]`, deferred). The named form reads with the colon as "is" ("Item is Int"), as in `[S.Item: Ord]`. |
| 10 | Verb in prose | "plays" | Works for nouns, adjectives and built-ins alike ("Label plays Hash"); "is" fails for adjectives without an article, and "has" fails for nouns. Informal "Square is a Shape" stays fine for noun roles. |

## Final sketch

```text
pub role Shape
  fun area(?@) -> Float                 # no body: required
  sub describe(?@)                      # a body: a default, which a type may replace
    print("area", @area())

pub role Named: Print                   # builds on another role
  fun name(?@) -> ?String from @

pub role Iter
  type Item                             # read I.Item
  fun next(!@) -> Item?

pub obj Square: Shape + Print           # the type's own module: on the header
  side: Float
  pub fun area(?@) -> Float             # pub, as approved
    @side * @side
  pub sub describe(?@)                  # replaces the default; another signature is an error
    print("square", @side)

extend Int: Shape                       # a type you do not own, in Shape's module
  fun area(?@) -> Float                 # the role's method; no pub
    Float(@) * Float(@)

extend Wrap[T: Shape]: Shape            # holds only under a bound
  fun area(?@) -> Float
    @v.area()

fun total[T: Shape + Print](xs: ?List[T]) -> Float
  t = 0.0
  for x in xs
    t += x.area()
  t

fun area_of(s: ?{Shape}) -> Float       # any Shape at run time; the braces mark the cost
  s.area()

jobs: List[^{Job + Moves}]
lines: ^{Iter[Item: String]}            # reserved now; a bare `Shape` in a type stays an error
```

Keyword changes: `role` and `extend` become position keywords; `impl` and `trait` leave the "held for
later" list (or stay reserved only to give the error "write `role`" / "write `extend`").
