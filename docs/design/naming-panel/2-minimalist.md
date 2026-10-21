# Naming panel 2: the minimalist's view (in the spirit of CoffeeScript)

Lens: say more with less. A form earns each word and each mark it carries;
what the shape of the code already says, the syntax should not say again.

## The finding that drives everything

Look at where the word actually appears in the approved design. In the
header, `obj Square: Shape`, it does not. In a bound, `[T: Shape]`, it does
not. In an object, `?{Shape}`, it does not. In the best error,
"`Label` is not `Shape`", it does not. The colon and the braces already
carry the idea. **The word lives in exactly one line of code, the
declaration, and in docs prose.** So pick the word that reads best as a
header and in a sentence, and spend no syntax on it anywhere else. The
one remaining place it leaks into code is `impl Int: Shape`, and that
line should lose its word too.

## Names, ranked

**1. `role`.** Four letters, plain English, no jargon, no history.

- Declaration: `role Shape`
- Taking it on: `obj Square: Shape + Print` (word-free)
- Bound: `fun total[T: Shape](...)` (word-free)
- Error: "`Label` is not `Shape`; declare `obj Label: Shape`" (word-free);
  where a noun is needed: "`Shape` is a role, not a type: write `[T: Shape]`
  or `?{Shape}`"
- Prose: "Square plays Shape", "Square takes on Shape", "a role's default method"
- Plural: roles. "Eq, Hash, and Ord are built-in roles."

It reads like a person describing a program: a Square plays the Shape
role. It promises behavior, not data, which is exactly the semantics.

**2. `trait`.** Already reserved, universally understood, and five letters.
Its only fault is that it is borrowed; since the word appears in one line,
borrowing costs little. Prose: "Square has the Shape trait"; plural traits.

**3. `face`.** "Interface" with the ceremony cut off. `face Shape`; prose
"Square wears the Shape face"; plural faces. Short and fresh, but the
prose is strained, which is why it ranks last.

## Syntax: what can still come out

The approved spelling is already lean. Four changes, each removing a word
or a rule.

1. **Required vs default: keep it as shape.** No body means required; a
   body means default. No `abstract`, no `default`, no `required`. This is
   the CoffeeScript ideal: indentation says it.
2. **Overriding a default: just write the method.** No `override` keyword.
   The exact-signature rule already catches a mistyped override.
3. **Drop `impl`.** The foreign-type case becomes a bare top-level line,
   the conformance alone, with its methods indented under it:

   ```
   Int: Shape
     fun area(?@) -> Float
       Float(@) * Float(@)

   Wrap[T: Shape]: Shape
     fun area(?@) -> Float
       @v.area()
   ```

   No top-level declaration starts with a capitalized type name today, and
   a constant always has `=`, so the line is unambiguous to the parser. It
   reads as the fact it states: Int is a Shape. It also matches the header
   `obj Square: Shape` minus the `obj` (we are not declaring Int), and the
   bound `[T: Shape]`. `impl` is an abbreviation of jargon. If the owner
   wants a leading word, `type Int: Shape` costs no new keyword and
   agrees with a role's own `type Item: Ord`. But I'd take the bare line.
4. **No `pub` echo on conforming methods.** A method that meets a `pub` role
   on a `pub` type is public because the role says so. The approved design
   demands the `pub` and errors with the fix. When the compiler knows the
   fix, it should not ask the user to write it.

Everything else stays: `+` to join roles (it has to be `+`, since `,`
separates bracket entries, and one spelling should serve headers and
bounds), `[T: Shape]` in brackets (compile time), `Shape.area(c)` to
disambiguate, and `{Shape}` behind a sigil, which is the best piece of
the design: two characters that say "dynamic, and it costs".

## Full sketch

```
pub role Shape
  fun area(?@) -> Float                  # no body: required
  sub describe(?@)                       # body: default
    print("area", @area())

role Named: Print                        # builds on another role
  fun name(?@) -> ?String from @

pub obj Square: Shape + Print
  side: Float
  fun area(?@) -> Float                  # public through the role: no `pub` echo
    @side * @side

obj Circle: Shape
  r: Float
  fun area(?@) -> Float
    3.0 * @r * @r
  sub describe(?@)                       # overrides the default, no keyword
    print("circle", @r)

Int: Shape                               # a type you do not own, in the role's module
  fun area(?@) -> Float
    Float(@) * Float(@)

Wrap[T: Shape]: Shape                    # holds only under a bound
  fun area(?@) -> Float
    @v.area()

fun total[T: Shape](xs: ?List[T]) -> Float
  t = 0.0
  for x in xs
    t += x.area()
  t

fun area_of(s: ?{Shape}) -> Float        # dynamic: the braces mark the cost
  s.area()

sub main()
  shapes: List[^{Shape}] = List()
  !shapes.push(^Square(side: 3.0))
  !shapes.push(^Circle(r: 1.0))
  for s in ?shapes
    s.describe()
```

## What I'd reject

- **No keyword at all** (`obj Shape` with bodiless methods): tempting, but an
  `obj` can be built, `Shape()`, and braces would then hold a type. One
  word at the declaration is cheap; ambiguity is not.
- **A bare role as a hidden type parameter** (`fun total(xs: ?List[Shape])`,
  Rust's `impl Trait`): it saves `[T: Shape]` but hides which arguments shape
  the code, breaking "square brackets mean compile time", and reads like a
  concrete type, the very reason bare `?Shape` lost to braces.
- **`,` between roles on a header**: lighter, but splits one idea into two
  spellings, since bounds need `+`.
- **`interface`, `protocol`, `contract`**: three syllables of ceremony for
  one line of code; each carries another language's baggage.
- **`ability`**: long, and reads oddly for Shape ("Square has the Shape ability").
- **`kind`**: reads beautifully ("a kind of Shape") but SPEC already spends
  "kinds of value" on plain data, handles, and unique objects.
- **`can`**: fine for `Print`, wrong for `Shape`.
- **`impl`**, and Rust's `impl Shape for Int`: an abbreviation, and `for` is
  Rig's loop word.
