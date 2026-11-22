# Named options, groups and spreads: the design

This is the design of how a Rig call gives a function's options: by name,
one at a time, or whole from a stored value. The rule of section 1 is
built, and its examples are ordinary ones; groups, spreads, object update
and the shorthand are not yet, and every example of what they add is a
`rig pending` block, which becomes an ordinary example when its rule is
built. Each decision the owner made is
tagged **[Owner, 2026-11-22]**; an untagged rule follows from those or is
forced by Rig. A panel of three wrote the reports behind the keyword rule,
a committee of three the reports behind groups and spreads, and two red
teams attacked the result; they are kept in
[named-options/](../history/records/2026-11/named-options/README.md). Where
a report and this page differ, this page holds.

```rig pending
obj Net
  timeout: Int = 30
  retries: Int = 3

obj Config
  name: Static
  net: Net

fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Int
  port + timeout

sub fetch(url: ?String, ..net: Net)
  print(url, net.timeout, net.retries)

sub main()
  print(connect("db", 5432, timeout: 5))   # an option is given by name
  cfg = Config(name: "prod", net: Net(retries: 5))
  fetch("a", retries: 9)                   # a group's fields, by name
  fetch("b", ..cfg.net)                    # or a stored value, whole
  fetch("c", retries: 1, ..cfg.net)        # named fields win
  retries = 7
  fetch("d", retries:)                     # `retries:` is `retries: retries`
  n = Net(timeout: 2, ..cfg.net)           # object update
  print(n.timeout, n.retries)
```

```output
5437
a 30 9
b 30 5
c 30 1
d 30 7
2 5
```

## Why

Were any parameter given by position or by name,
`connect(host, 5432, 30, true)` would compile and say nothing about what
`30` and `true` are, and a library that inserts a defaulted parameter before
another of the same type would silently shift every positional caller.
A reordered `format_int(n, upper, base)` would compile when the types
agree. Checks of std's own calls (`dt.add(1, 2)` refused, `with` by name)
would work only for std and could not protect a user's functions.

The rule below makes a misplaced option impossible to write. Groups and
spreads then give what Zig's options struct gives, an options value that is
built once, stored, passed whole, partly overridden, and shared by several
functions, with every name and type checked at compile time and the same
plain call underneath.

## 1. The rule

**[Owner, 2026-11-22]** Required values come first, by position. A
parameter with a default is an **option**, and an option is given by name.
A trailing closure fills its callback parameter. There is no exemption for
the first parameter. A method's self is never an option.

```rig
fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Int
  port + timeout

sub main()
  print(connect("db", 5432))
  print(connect("db", 5432, timeout: 5))
  print(connect("db", 5432, retry: false, timeout: 1))
```

```output
5462
5437
5433
```

The rule refuses the positional form:

```rig reject
use std.time

fun connect(host: ?String, port: Int, timeout: Int = 30) -> Int
  port + timeout

fun area(width: Int = 80, height: Int = 24) -> Int
  width * height

sub wait_for(url: ?String, timeout: time.Duration? = none)
  print(url)

sub main()
  print(connect("db", 5432, 5))
  print(area(24))
  wait_for("u", 0.5)
```

```error
`timeout` has a default, so it is an option, given by name: `timeout: 5`
`width` has a default, so it is an option, given by name: `width: 24`
`timeout` has a default, so it is an option, given by name: `timeout: 0.5`
```

The message teaches the split: a parameter without a default is an operand,
passed by position; one with a default is an option, passed by name. Its
full text ends "to pass it by position, remove its default", since that is
the other way out. Options may be given in any order, after the positional
arguments, as keywords may be today.

**No first-parameter exemption.** `area(24)` above is refused although
`width` is the first parameter. An exemption would keep open the calls the
rule exists to close: `dt.add(1)` (one second, where most readers guess a
day), `t.with(3)`, `dur.round(5)`, `CharBreak.new(true)`, and a function
made only of options, where `area(24)` means a width. Swift 1 and 2 left a
method's first argument unlabeled and Swift 3 removed the asymmetry
(SE-0046), because users could not predict it.

### Edge rules

- **No default on `_`.** An option is given by name, and `_` has none.
- **A required parameter after an option** is refused unless it takes a
  function (`fun`, `sub`, `?fun`, `?sub`), the parameter a trailing closure
  fills. Any other could only be given by name, which a required parameter
  never is.
- **A unit keyword names the duration option.** `ms:`, `seconds:` and the
  other unit keywords fill a function's one `Duration` parameter
  (docs/design/datetime.md, 5.1), so `wait_for("u", ms: 500)` gives the
  option `timeout` by name. The reader then sees the unit, not the option's
  name; for a user function whose `Duration` is an option rather than the
  operand, the docs recommend its own name, `timeout: 0.5`.
- **A trailing closure fills the callback parameter**, the open parameter
  whose type is a function, whether or not any keyword comes before it. So
  `repeat(|i| ...)` never lands on `repeat`'s first parameter.

```rig reject
fun scaled(n: Int, by: Int = 10, _: Bool = false) -> Int
  n * by

fun mid(a: Int, b: Int = 2, c: Int) -> Int
  a + b + c

sub main()
  print(scaled(3, by: 2), mid(1, c: 3))
```

```error
`_` cannot have a default: an option is given by name, and `_` has none
`c` has no default but follows the option `b`, so it could only be given by name: move it before `b`, or give it a default
```

```rig
use std.time

sub repeat(times: Int = 1, f: ?sub(Int))
  for i in 0..times
    f(i)

sub each(n: Int, step: Int = 1, f: ?sub(Int))
  i = 0
  while i < n
    f(i)
    i += step

sub wait_for(url: ?String, timeout: time.Duration? = none)
  print(url)

sub main()
  repeat(|i| print("once", i))
  repeat(times: 2, |i| print("twice", i))
  each(3, |i| print("each", i))
  wait_for("u", ms: 500)
```

```output
once 0
twice 0
twice 1
each 0
each 1
each 2
u
```

## 2. Groups

**[Owner, 2026-11-22]** An object type written as a parameter
`..net: Net` makes its fields name-only options of the function: a
**group**. The body sees one value, `net`, of type `Net`; the field names do
not enter the body's scope (`net.timeout`, never `timeout`).

```rig pending
obj Net
  timeout: Int = 30
  retries: Int = 3
  follow: Bool = true

sub fetch(url: ?String, ..net: Net)
  print(url, net.timeout, net.retries, net.follow)

sub main()
  fetch("a")
  fetch("b", retries: 5)
  fetch("c", follow: false, timeout: 2)
```

```output
a 30 3 true
b 30 5 true
c 2 3 false
```

- **The compiler rewrites the signature into plain parameters.** `fetch`
  has the parameters of `fun fetch(url: ?String, timeout: Int = 30,
  retries: Int = 3, follow: Bool = true)`, each field name-only. A call gives
  them exactly as it gives inline options. The body's `net` is built from
  those parameters where the body uses it whole; reading `net.timeout` reads
  the parameter.
- **A group shares options among functions.** `fetch`, `post` and
  `connect` may all take `..net: Net`: one declaration, one doc comment, one
  place to add an option. A function may have inline options and several
  groups (`fun add(?@, duration: Duration? = none, ..p: Period)`).
- **A field without a default is a required name-only argument.** This is
  how a function asks for a required argument by name, as a Zig options
  struct does with a field that has no default, with no new marker on
  parameters.
- **Collisions are refused at the declaration:** two groups, or a group and
  a parameter, that share a name. The message names the group's field and
  its declaration, since the group's author cannot see every function that
  uses it.
- **A group's fields keep their field defaults.** A group holds plain data
  (section 4), so its defaults are literals, module constants, `[n of x]`,
  or `T()` of a plain object: none runs code or allocates, and each is
  filled at the call, as a parameter default is.
- **Declaration order.** The required positional parameters come first,
  then the options and groups, in any order, then a callback parameter,
  which may follow them (section 1).
- **A trailing closure never fills a group's field.**
- A `pub` function's group type has `pub` fields.

```rig pending
obj CopyArgs
  src: Static
  dst: Static
  overwrite: Bool = false

sub copy(..a: CopyArgs)
  print(a.src, "->", a.dst, a.overwrite)

sub main()
  copy(src: "a.txt", dst: "b.txt")
  copy(dst: "c.txt", src: "a.txt", overwrite: true)
```

```output
a.txt -> b.txt false
a.txt -> c.txt true
```

```rig pending
use std.time

obj Net
  timeout: time.Duration? = none
  retries: Int = 3

obj Req
  body: ?String
  retries: Int = 0

obj CopyArgs
  src: Static
  dst: Static

sub fetch(url: ?String, ..net: Net)
  print(url)

sub post(url: ?String, retries: Int = 0, ..net: Net)
  print(url)

sub send(..r: Req)
  print(r.retries)

sub copy(..a: CopyArgs)
  print(a.src)

sub main()
  fetch("u", ms: 500)
  copy("a.txt", dst: "b.txt")
```

```error
`retries` is both a parameter of `post` and a field of its group `net`, a `Net`
group `r` of `send` is a `Req`, which holds `body: ?String`, a view; a group holds plain data
`ms:` cannot fill `timeout`, a field of group `net`: give it by name, `timeout: time.duration(ms: 500)`
`src` is a field of group `a` of `copy`, so it is given by name: `src: "a.txt"`
```

## 3. Spreads

**[Owner, 2026-11-22]** `..v` in a call supplies the fields of a stored
value `v` to the group of its type.

```rig pending
obj Net
  timeout: Int = 30
  retries: Int = 3

obj Config
  name: Static
  net: Net

sub fetch(url: ?String, ..net: Net)
  print(url, net.timeout, net.retries)

sub main()
  cfg = Config(name: "prod", net: Net(retries: 5))
  fetch("a", ..cfg.net)
  fetch("b", ..cfg.net, retries: 9)
  fetch("c", timeout: 1, ..cfg.net)
```

```output
a 30 5
b 30 9
c 1 5
```

- **Nominal.** `v`'s type is the group's type exactly. A value of another
  type with the same fields is refused, and so is any conversion between a
  value and keywords that is not written: when either side gains a field,
  nothing flows into the other unseen.
- **A value is complete.** Making a `Net` fills every default
  **[Owner, 2026-11-22]**, so a spread supplies every field, and a field
  added to `Net` later never leaves a spread short.
- **Named fields win, in any order.** A field named beside a spread, before
  it or after it, is given by that name, and the spread supplies the rest.
  An overridden field is never read from `v`.
- **One spread per group.** Two spreads that fill one group are refused, so
  no rule of "the later wins" between spreads is needed.
- **The operand is a place:** a name or a field path (`..cfg.net`), whose
  type is a group's type, not an optional and not a type parameter. A field
  read never runs code, so reading a place once per field is safe; a made
  value (`..defaults()`) is bound to a name first, which also keeps its `!`
  on its own line.
- **Evaluation order.** Arguments are evaluated in the order written. A
  spread reads the fields it supplies at its own place, in their declared
  order. With a write view among the arguments, the order is visible, and it
  is the one written: **[Owner, 2026-11-22]** targeted tests check it.

```rig pending
obj Net
  timeout: Int = 30
  retries: Int = 3

sub connect(host: ?String, port: Int, ..net: Net)
  print(host, port, net.timeout, net.retries)

fun longer(o: !Net) -> Int
  o.timeout += 10
  o.retries + 1

sub main()
  o = Net(timeout: 5)
  connect("db", 5432, ..o, retries: longer(!o))
  connect("db", 5432, retries: longer(!o), ..o)
```

```output
db 5432 5 4
db 5432 25 4
```

In the first call the spread reads `o.timeout` (5) before `longer` writes
it; in the second, `longer` runs first and the spread reads 25. Each reads
`o.retries` never, since `retries` is named.

```rig pending
obj Net
  timeout: Int = 30
  retries: Int = 3

obj Retry
  timeout: Int = 30
  retries: Int = 3

sub fetch(url: ?String, ..net: Net)
  print(url, net.retries)

sub fetch_once(url: ?String, ..net: Net)
  fetch(url, ..net, retries: 0)

fun defaults() -> Net
  Net(retries: 1)

sub main()
  n = Net()
  r = Retry()
  fetch("a", ..r)
  fetch("b", ..n, ..n)
  fetch("c", ..defaults())
  fetch_once("d", retries: 5)
```

```error
`retries` of `net` is given by the caller of `fetch_once`; overriding it here discards that: declare `retries` as an option of `fetch_once`
`..r` is a `Retry`, but group `net` of `fetch` is a `Net`: a spread passes a value of the group's own type
group `net` of `fetch` is filled by two spreads
a spread passes a name or a field: bind `defaults()` to a name first
```

### Object update

**[Owner, 2026-11-22]** The same spread updates an object:
`Point(x: 3, ..p)` is a copy of `p` with `x` set, under the same rules
(nominal, complete, named fields win in any order, one spread, a place).

```rig pending
obj Point
  x: Int
  y: Int
  z: Int = 0

sub main()
  p = Point(x: 1, y: 2, z: 3)
  q = Point(x: 9, ..p)
  r = Point(..p, y: 8)
  print(q.x, q.y, q.z, r.x, r.y, r.z, p.x)
```

```output
9 2 3 1 8 3 1
```

Object update is allowed only where the type could be constructed. It is
Rust's `Point { x: 3, ..p }`, OCaml's `{ p with x = 3 }`, Kotlin's
`p.copy(x = 3)`, and C#'s `p with { X = 3 }`.

### The shorthand

**[Owner, 2026-11-22]** `name:` alone means `name: name`, in a call and in
a constructor. It is a shorthand only when `,` or `)` follows it on the
same line; `name:` at the end of a line takes the next line as its value,
as it does today.

```rig pending
obj Point
  x: Int
  y: Int

sub fetch(url: ?String, retries: Int = 3)
  print(url, retries)

sub main()
  x = 1
  y = 2
  p = Point(x:, y:)
  retries = 7
  fetch("a", retries:)
  print(p.x, p.y)
```

```output
a 7
1 2
```

- It names a local or a parameter only, never a module constant or a
  function, so renaming a local cannot make `timeout:` pick up something
  else of that name.
- It never hides a move: an owner given to a parameter that takes one still
  needs `<` (`buf: <buf`), so a bare `buf:` of a `List` is refused with
  "write `buf: <buf`", as `buf: buf` is today.
- It covers forwarding (`connect(host, timeout:, retry:)`) and, more often,
  construction: of the 650 `x: x` lines in Trig, most build an object.

```rig pending
obj Doc
  name: String
  pages: Int

timeout = 30

sub fetch(url: ?String, timeout: Int = 5)
  print(url, timeout)

sub main()
  d = Doc(name: String("a"), pages: 1)
  e = Doc(pages: 2, ..d)
  fetch("u", timeout:)
  print(e.pages)
```

```error
object update copies plain data, and `Doc` holds `name: String`, which owns: write its fields
`timeout:` alone needs a local or a parameter named `timeout`
```

## 4. The limits of v1

Each limit can be lifted later without breaking a program that compiles
under it.

- **Groups and object update hold plain data only** **[Owner,
  2026-11-22]**: no owners and no read views (SPEC, "plain data": numbers,
  `Bool`, plain enums, `Static`, `Symbol`, vectors, and objects, arrays and
  optionals of them). A spread then copies, never moves or clones, and an
  override drops nothing. *Why:* a group flattened into parameters
  misaligns the declaration side of the ownership checker, storage and emit,
  which index the function type's parameter bits by the written parameter
  list, and `from net` or `keeps net` has no meaning while `net` is a body
  local; object update of an owner needs a sigil per field, `<` only on the
  fields that move. **[Owner, 2026-11-22]** This limit is lifted in the
  next step after v1, before any other deferred item (section 11).
- **A function with options is not a value** **[Owner, 2026-11-22]**:
  write a closure. *Why:* today a function taken as a value is called with
  every argument by position, options included (`g = connect; g(h, 1, 5)`),
  which is the call the rule forbids. Through a group it would be worse: the
  order of `Net`'s fields, which means nothing anywhere else, would become
  the positional order of every function that uses it, and swapping two
  `Int` fields would silently swap arguments. No function value with
  defaults exists in the measured code.
- **Unit keywords never fill a group's field** **[Owner, 2026-11-22]**. A
  group's `Duration` field is given by its own name. *Why:* a unit keyword
  fills a function's one `Duration`, so a second `Duration` field added to a
  shared group would take the unit keywords from every caller of every
  function that uses it, and a parameter named for a unit beside a new
  `Duration` field would break a declaration elsewhere.
- **A wrapper cannot override a field of its own group** **[Owner,
  2026-11-22]**. A spread of the function's own group parameter has no
  field named beside it, in a call or an object update. *Why:* the caller
  may have given that field explicitly, and the override would discard it
  without a word. A wrapper that pins an option or changes its default
  declares it as its own option and forwards the rest by hand.
- **No spread into a call whose arguments are checked at compile time**
  **[Owner, 2026-11-22]**: `round` and `floor` keep their unit keywords
  inline and declare no group. *Why:* their check counts the call's
  keywords ("exactly one unit") and reads its constants (an increment that
  divides the next unit); a stored value gives it nothing to count, so a
  `Step` group would let a wrong increment through. Value checks of
  constants lapse through a spread in the same way (a negative wait is a
  field read, not a constant), which is harmless where the run time defines
  the result, and a spread's fields are never constant arguments, so a maker
  given a spread keeps its `!` (docs/design/datetime.md, 10.6).
- **Deferred, each to IDEAS until a program needs it:** `f.Options` (a
  function's options as a type), groups in APIs, function values that keep
  their options, generic groups (`..o: Opts[T]`), and groups passed by
  pointer (`..o: ?Net`).

```rig pending
fun connect(host: ?String, port: Int, timeout: Int = 30) -> Int
  port + timeout

sub main()
  g = connect
  print(g("h", 1, 5))
```

```error
`connect` has options, so it is not a value: write a closure
```

The closure names the options it gives:

```rig
fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Int
  port + timeout

fun twice_each(f: ?fun(?String, Int) -> Int) -> Int
  f("a", 1) + f("b", 2)

sub main()
  print(twice_each(|h, p| connect(h, p, timeout: 5)))
```

```output
13
```

## 5. Performance

**[Owner, 2026-11-22]** The language promises **no run-time lookup or
machinery: every call lowers to the code one would write by hand**, a plain
call with its arguments, defaults filled at the call as constants. How a
group is passed is the compiler's measured choice, not a language rule.

What the compiler does, as measured:

- **The rule changes nothing emitted.** Arguments already reach Zig by
  position with defaults filled at the call, so the Zig of a program that
  passes the rule is byte-identical before and after it.
- **A spread is field reads as arguments:**

```zig
// fetch("b", ..cfg.net, retries: 9)
fetch("b", cfg.net.timeout, 9);
```

- **Groups start as separate arguments.** Built with Zig 0.17.0 in
  ReleaseFast, `noinline`, with run-time values, for aarch64-macos and
  x86_64-linux:

| Call | aarch64 | x86-64 |
|---|---|---|
| separate arguments, in registers | a bare tail jump | `jmp` |
| separate arguments from a stored value | 3 load pairs, a tail jump, no frame | 5 loads, 1 spill, a call |
| one 40-byte struct, from keywords | a 64-byte frame, 3 stores, a pointer, `bl` | a 48-byte frame, 5 stores, `lea`, a call |
| one 40-byte struct, from a stored value | a frame and a 40-byte copy | a frame and a 40-byte copy |

  Zig's own calling convention passes a large struct as a caller-owned copy
  and a pointer, so separate arguments are the cheaper default. A group of
  more than about eight register-sized fields spills to the stack, as the
  struct's copy would (a `Duration` takes two registers); passing such a
  group by pointer is the deferred `..o: ?Net`.
- **The body's group value** is built from the parameters only where the
  body uses it whole; Zig's scalar replacement makes even that free.
- **Compile time:** a module with a spread is checked a second time after
  the rewrite, as a module with an iterator chain is; std/json.rig (65 KB)
  typechecks in about 4 ms.

## 6. Function types

**[Owner, 2026-11-22]** Decided now, though v1 refuses a function with
options as a value:

- **A function type never carries inline options**, their names or their
  defaults, as Swift's function types carry no argument labels since
  SE-0111. A call through a value never gives an option by position. A
  function with inline options becomes a value only through a closure, or
  after its options move into a group.
- **When function values keep options, they keep them through groups.** A
  function type may then name a group, `fun(?String, ..Net) -> Int`, whose
  names live in the nominal type `Net`, not in a parameter list. A function
  fits such a type when its positional parameters and result match and its
  groups are exactly the type's groups, by type. A call through the value
  takes keywords and spreads for the group and fills the omitted fields
  from `Net`'s defaults at the call, as a direct call does: still no
  run-time machinery, and no thunk, since a direct call and a call through
  a value pass the group the same way.
- **Compatibility is source compatibility, on recompile.** Adding a field
  with a default to `Net` changes no function type's identity, so every
  program that holds such a value still compiles. It changes the emitted
  Zig signature, so it is not a stable binary interface; Rig compiles whole
  programs, and a future form of separate compilation would have to decide
  that again.

Lifting the v1 limit needs: `..T` in a function type; a closure that takes
a group (`|u, ..net|`); the call through a value routed through the same
argument matcher as a direct call; and the value's Zig type emitted with the
group's fields as its parameters.

## 7. Evolution

What a library may change, and what its callers see:

| Change | Callers |
|---|---|
| Add an option with a default, inline or as a group's field | compatible: keyword callers are untouched, and a spread's value fills the new field's default |
| Reorder options, or a group's fields | compatible: nothing is given by position |
| Move inline options into a group | compatible for every keyword caller |
| Change a default | compatible: callers get the new default when they are compiled, since defaults are filled at the call |
| Give a required parameter a default | **breaks** positional callers, loudly; the parameter has become an option |
| Remove a default, or add a required field to a group | **breaks** callers that left it out, loudly |
| Rename or remove an option or a group's field | **breaks** callers that name it, loudly |
| Add a field whose name a function using the group already has, as a parameter or in another group | **breaks** that function's declaration, loudly, naming the group's field |

No change alters a program's meaning without a refusal, which is what the
rule buys: today inserting or reordering defaulted parameters silently
shifts positional callers. The lasting cost is the row other languages do
not have: in Swift, Kotlin, C# and Python, giving a parameter a default is
compatible; here it changes how the parameter is passed, as moving a
parameter into a Zig options struct does.

**Names are API.** An option's name, and each field name of a `pub` group,
are part of every function that takes them. std's 29 declarations with a
defaulted parameter are reviewed when the rule lands; `DateTime.add`'s `d`
becomes `duration` (section 9). Shared groups couple their functions'
defaults too (`fetch` and `post` sharing `retries: Int = 3`, though a POST
should not retry by default); a shared field that each function should
choose for itself is better as `T? = none`.

## 8. Teaching

In two sentences: **a parameter with a default is an option, given by
name, after the positional arguments. `..name: T` makes an object's fields
a function's options, and `..v` passes a stored value's fields, with any
field named beside it winning.**

That is the pitch, not the whole. Honestly listed, a programmer learns:

1. Required parameters come first and are given by position.
2. A parameter with a default is an option, given by name, in any order.
3. A trailing closure fills the callback parameter.
4. A unit keyword (`ms:`, `hours:`) names the one `Duration` option.
5. `..name: T` in a parameter list makes `T`'s fields name-only options; the
   body sees `name`.
6. A group's field without a default is a required name-only argument.
7. `..v` passes a value's fields to the group of exactly its type.
8. A field named beside a spread wins, before it or after it; one spread
   fills a group.
9. A spread's operand is a name or a field path.
10. `T(x: 1, ..v)` is a copy of `v` with `x` set.
11. `name:` before `,` or `)` on its line means `name: name`, for a local
    or a parameter.
12. The v1 limits: plain data only in groups and object update; a function
    with options is not a value; no unit keyword fills a group's field; a
    wrapper does not override its own group's fields; no spread into
    `round` or `floor`.

`..` then means a range, an open slice, a range pattern, a group, and a
spread; the bracket and the position tell them apart (`xs[..b]` in
brackets, `..net: T` in a parameter list, `..v` in a call's parentheses).

What newcomers will write, and what they get:

| From | Writes | Gets |
|---|---|---|
| Python | `f(h, 5)` for a defaulted `timeout` | refused, with the fix |
| JavaScript | `f(..a, ..b)` to merge | "filled by two spreads" |
| JavaScript, TypeScript | `..cfg` of a look-alike type | refused: spreads are nominal |
| Rust | `Point(x: 3, ..p)` | accepted |
| Rust | `..Default()` | "bind it to a name first" |
| Zig | `f(h, .{ .timeout = 5 })` | refused: keywords are the literal |
| Swift | `cb = f` for an `f` with options | "write a closure" |
| Ruby | `f(x:)` | accepted, as in Ruby 3.1 |

## 9. Datetime as the test case

The datetime library is where the old positional checks live, and where the
design is tried:

- **The makers.** **[Owner, 2026-11-22]** `Time.new(hour, minute, second,
  ns: 0)`: the second is required and `ns` an option, so
  `Time.new(8, 7, 3, ns: 500)` says nanoseconds where `Time.new(8, 7, 3,
  500)` read as milliseconds to some. `DateTime.new(year, month, day,
  hour:, minute:, second:, ns:)`: the date by position and the clock by
  name, each part of the clock defaulting to 0, as `dt.with(hour:)` names
  it. Dropping every default (Jiff's `time(h, m, s, ns)`) was rejected:
  seven bare integers is the shape the rule exists to stop.
- **`DateTime.add`'s duration is named `duration`** **[Owner,
  2026-11-22]**: `dt.add(duration: span)`, `dt.add(hours: 36)` with a unit,
  never `dt.add(1)`. `d:` read badly once the name became API.
- **Groups.** `Period` (`years`, `months`, `weeks`, `days`, each `= 0`) for
  `Date.add` and `DateTime.add`; `DateFields` (`year`, `month`, `day`, each
  `Int? = none`) and `ClockFields` (`hour`, `minute`, `second`, `ns`) for
  `with`. Their flat signatures are today's, so their emitted Zig is
  unchanged, and a program can now hold a period in a table and apply it.
- **`round` and `floor` keep their units inline** and declare no group
  (section 4).
- **What the rule deletes:** `ArgCheck`'s `by_name` and `duration_add`, the
  positional part of `calendar_add`, and the "no positional argument" part
  of the round checks. The increment checks of `round` and `floor` stay:
  they check values, not positions.

```rig pending
use std.datetime

sub main()!
  start = datetime.DateTime.parse("2027-01-31T09:00:00")!
  monthly = datetime.Period(months: 1)
  print(start.add(..monthly)!)
  print(start.add(..monthly, days: 3)!)
  print(start.add(hours: 36)!)
  print(start.with(hour: 12, minute: 0)!)
```

```output
2027-02-28T09:00:00
2027-03-03T09:00:00
2027-02-01T21:00:00
2027-01-31T12:00:00
```

```rig reject
use std.datetime

sub main()!
  start = datetime.DateTime.parse("2027-01-31T09:00:00")!
  print(start.add(1)!)
```

```error
`duration` has a default, so it is an option, given by name: `duration: 1`
```

## 10. Precedent

| Language | What it has | What Rig takes or avoids |
|---|---|---|
| OCaml | optional arguments `?x` are labeled and never positional; `~x` punning; `{ r with x = 1 }` | the rule exactly, with no exemption; the shorthand; object update |
| Zig | options structs, `f(a, .{ .timeout = 30 })`; a field without a default is required | options as a value, required named fields; not the struct's calling convention, measured to cost a frame and a copy (section 5), nor the anonymous literal, since keywords already are one |
| Swift | labels on every parameter; Swift 1 and 2 exempted the first (SE-0046 removed it); labels left function types (SE-0111); default arguments made by generator functions | avoids the first-argument asymmetry; avoids defaults dropped silently through a value by refusing the value; labels only on options, and they never select an overload |
| Ruby | keyword arguments; Ruby 3 separated them from a trailing hash after 2.7's warnings; Ruby 3.1's `f(x:)`, where a forgotten comma takes the next line | the shorthand, ended on its line; nothing converts between a value and keywords unless `..` is written |
| Python | keyword-only parameters after `*`; `re.sub(p, r, s, re.I)` passing a flag as `count`, deprecated in 3.13; `**kwargs`, opaque; PEP 692's `Unpack[TD]` with the same overlap error as a group collision | keyword-only options, enforced; no open bag; typed groups whose collisions name the field |
| JavaScript | options objects and `{ ...defaults, ...opts }`, later wins, matched by name | spreads that are nominal, so a field named alike in an unrelated object never flows in; named fields win in any order instead of a later-wins merge |
| Kotlin | named optional arguments, never required; a `$default` method with a bitmask, a branch per option at run time; `copy` | object update; defaults filled at the call as constants, with no run-time mask |
| C# | optional parameters whose defaults are baked into callers; `with` expressions | object update; the baking is harmless while Rig compiles whole programs (section 6) |
| Rust | no named arguments; builders; `S { x: 3, ..base }`, `..Default::default()` | struct update, named fields in any order; no builder type, no run-time chain |

## 11. Build plan and cost

The changes land in this order, each with its docs (SPEC Functions,
Objects and Function types, SYNTAX §11, a lesson in docs/learn), its tests,
and a CHANGELOG entry; the first rejects programs a release accepts, so it
comes with an "Upgrading" entry, a migration script, and a patch and a
one-line note for Trig and loco.

1. **The keyword rule** *(built)*, about 250 compiler lines. 326 call sites change
   (534 arguments): Rig's tests 223, Trig 52, loco 25, std 10, docs 9,
   tools 6, bench 1, all in a trailing run of defaulted parameters, 174 of
   them the datetime makers'. The named form is valid today, so the
   migration goes first: a script driven by the compiler's own diagnostics
   (each names the parameter and the rewrite), never by regular
   expressions, writes the named form in std, tests, docs, Trig and loco;
   then the rule lands, with the edge rules, the trailing closure that fills
   its callback, the deletions from `ArgCheck`, std's reviewed names, and
   the datetime makers and `duration` of section 9. Emitted Zig is
   unchanged.
2. **Groups, spreads, object update and the shorthand**, about 1.4k to 1.8k
   compiler lines, built as a rewrite of the call and of the signature in
   the tree, not as new kinds of argument slot: the module is typed, each
   spread and group is recorded, the Parser wrapper rewrites the call into
   keyword arguments and the signature into name-only parameters, and the
   module is checked again, as iterator chains are. Every pass after the
   rewrite then sees keyword calls and plain parameters, which it handles
   today. The code red team's findings are constraints on it:
   - A spread's synthesized nodes need a leaf whose text is any field name,
     declared in any module: the hidden names are a fixed enum of 256 ids
     and `leafText` reads only them or the source. Budget a synthesized-name
     leaf kind (a per-module name table, positions from `hiddenPos`, one
     position per leaf), or carry the spread as its own node the matcher
     expands.
   - A group is rewritten in the tree's signature, into one name-only
     parameter node per field and a real body binding, not only in sema's
     function type: the declaration side of ownership (`paramBit(i)`
     against the i-th written parameter), storage (`planHeldHeaders`) and
     emit's parameter walks index the written list.
   - The first check accepts a spread quietly and gives the call no type,
     as a chain's is given today; the second check's messages carry the
     spread's span and name the spread.
   - The trailing-closure rule has three copies (argument checking,
     `argViews`, generic inference), each of which learns that a closure
     never fills a group's field; one argument matcher that all three read
     is worth building first.
   - Field defaults differ from parameter defaults (`T()`, `[n of x]`):
     the flattened parameter is filled by the field's rule.
   - `ParamMask` has 64 bits and a parameter past bit 63 is "in every
     set"; flattening spends bits per field.
   - The language server's signature help shows a group's fields, and a
     rename follows spreads and the shorthand.
3. **Owners and read views in groups and object update** **[Owner,
   2026-11-22]**, the first step after v1, before any other deferred item.
   It needs the ownership, storage and emit work the code red team
   described: parameter bits per written position, so that a group's
   fields have their own bits on the declaration side, and `from net` and
   `keeps net` for a group that holds read views. Object update of owners
   puts `<` only on the fields that move and copies the rest; a type with a
   `drop` body is updated only by `..+p` or a whole move; and since a spread
   is evaluated where it is written, `P(n: size(?p), ..<p)` reads `p`
   before the spread takes its fields.

The other deferred items wait in IDEAS for a program that needs them.
