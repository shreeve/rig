# Options at the call: the innovator's report

Read: the brief; Rig main 75a6c7b5e: SPEC Functions (1595-1660), Objects
(2128-), APIs (3869-), Function types (11677-), Durations (14899-), SYNTAX
§11; `typecheck.zig` `checkArgs` (12030-); the kwonly panel (`designer.md`,
`practitioner.md`, `evangelist.md`, `summary-raw.txt`); std datetime and time
signatures. Probes in `inn/` beside this file, run with `bin/rig run` and
`bin/rig emit`.

Facts the design rests on (probed):

- A defaulted parameter is filled **at the call site** with plain Zig
  arguments: `connect("h", 1, timeout: 5)` emits `connect("h", 1, 5, true)`.
- A Rig object with field defaults emits a Zig struct with field defaults:
  `ConnectOpts(timeout: 9)` emits `ConnectOpts{ .timeout = 9 }`. Rig already
  has Zig's idiom, written `connect2(h, ConnectOpts(timeout: 9))`; what it
  lacks is spreading, overriding, and keyword calls that fill a struct.
- A function value drops defaults today: `f = connect; f("h", 1)` is refused
  ("expects 3 arguments, got 2").
- `..x` as an argument is free syntax: today it is refused with "a range needs
  a start; only a slice leaves a side open".
- There is no struct-update form today (`Point(..p, x: 3)` does not exist).
- Trig's 650 `x: x` lines: 383 of them are on lines with a constructor call,
  and most of the rest are fields of a multi-line constructor
  (`generated_position: generated_position,`). They are mostly **construction**,
  not option forwarding. An options value doesn't remove them; punning does.

## 1. The design in one block

```rig
# 1. Options are the parameters with defaults, given by name (the panel's rule).
fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Conn!

# 2. Together they form a value: connect.Options, an obj the compiler derives.
o = connect.Options(timeout: 5)
c = connect(host, 5432, ..o)              # spread: o's fields are the options
c = connect(host, 5432, ..o, retry: false) # a name after the spread overrides it

# 3. A group: a parameter written `..name: T` takes T's fields as options.
obj Net
  timeout: Duration? = none
  retries: Int = 3
  follow: Bool = true

fun fetch(url: ?String, ..net: Net) -> Response!
fun post(url: ?String, body: ?String, ..net: Net) -> Response!

fetch(url, retries: 5)                    # keywords fill the group
fetch(url, ..cfg.net, follow: false)      # stored value, overridden

# 4. Forwarding whole, typed: the wrapper's options ARE connect's.
fun connect_logged(host: ?String, port: Int, ..o: connect.Options) -> Conn!
  log("connect", host)
  connect(host, port, ..o)

# 5. Struct update on any constructor, same spelling.
q = Point(..p, x: 3)

# 6. Punning: `name:` alone is `name: name`.
Mapping(generated_position:, source_position:, source_index:)
```

Teaching, two sentences: **A parameter with a default is an option, given by
name, and a function's options together are a value (`f.Options`, or the type
of a `..name: T` parameter). `..v` in a call or constructor passes that
value's fields, and names written after it override them.**

## 2. Each idea, with cost and refusals

### 2.1 The base rule (adopted from the panel, unchanged)

Positional arguments first, then options by name, no first-parameter
exemption, a trailing closure fills the open function parameter by type. Cost
and migration as measured: 326 sites, emitted Zig unchanged. Everything
below is additive on top of it.

### 2.2 The spread `..v` with overrides

`f(a, ..v, k: x)`: `v`'s type must be **exactly** the type of one of `f`'s
option groups (its derived `f.Options`, or a declared `..name: T`). Each
field of `v` fills its option; a keyword written after the spread replaces
that one field.

Rules:

- **Nominal, never structural.** `..v` is accepted only where `v`'s type is
  the group's type. Ruby 2's pain came from a Hash silently becoming
  keywords and back (the 2.7 deprecation warnings, the 3.0 separation); the
  lesson is no implicit conversion between a value and keywords. Here the
  `..` is written and the type must match, so nothing converts by accident.
  Structural spread (JavaScript `{...a}`, matching by field names) would let a
  field named `retry` in an unrelated config flow into `connect`'s `retry`
  when either side gains a field: a silent change. Refused.
- **Order:** a spread comes before the keywords that override it, and a
  group takes at most one spread. That reads left to right ("these, but
  timeout 5"), matches JavaScript's later-wins and Rust's struct update
  without its "base last" oddity, and keeps the "a parameter is given twice"
  error for two keywords. Arguments are still evaluated in the order written:
  `v` once, at its place.
- **Ownership:** the spread reads each field as the path `v.f`, under the
  ordinary rules. Plain fields and read views (`?String`) copy. An owning
  field (a `String`, a `List`) makes `..v` refused unless written `..<v`
  (move the whole) or `..+v` (clone): the sigils Rig already has. An override
  that keeps an owning field of `v` needs the same sigil, since the rest is
  copied out of `v`. Objects never hold a write view, so neither does an
  options value.

Lowering, zero cost, one call:

```zig
// connect(host, 5432, ..o, retry: false), inline options:
connect(host, 5432, o.timeout, false)
// fetch(url, ..cfg.net, follow: false), a group:
fetch(url, .{ .timeout = cfg.net.timeout, .retries = cfg.net.retries, .follow = false })
```

Refuses: a misspelled override (`..o, timout: 5`: "`connect` has no option
`timout`"); a spread of another type (`..net` into `connect`: "`..net` is a
`Net`; `connect`'s options are `connect.Options`"); a spread after its
overrides; two spreads into one group; an owning field copied by a spread.

Cost: parser (a `..expr` argument, ~30 lines), `checkArgs` (route a spread to
its group, override bookkeeping, ~200), ownership (the spread as field paths,
~100), emit (field reads or a struct literal, ~80).

### 2.3 The derived type `f.Options`

For a function whose options are all inline, `f.Options` is an `obj` the
compiler derives: one field per defaulted parameter, same name, type and
default, in declaration order. It is an ordinary object: built
(`connect.Options(timeout: 5)`), stored in a field, returned, compared if its
fields compare, passed to any function that declares `..o: connect.Options`.
For a method it is named through the type, `DateTime.round.Options`; for a
generic function, through the instance, `parse[Int].Options`.

Why derive it rather than make authors declare one: forwarding then needs no
foresight from the library author. Any downstream wrapper can take "whatever
`connect` takes" and gains each new option `connect` adds without an edit.
That is TypeScript's `Parameters<typeof f>` and Zig's `std.meta.ArgsTuple`,
restricted to the options and given a real name. Python reached for this
(PEP 692, `**kwargs: Unpack[Movie]`) but makes you declare the `TypedDict`
first.

Restriction: `f.Options` exists only when `f`'s options are all inline. A
function that declares a group names that group's type instead (otherwise
the derived type has to nest groups, which isn't worth it).

Lowering: `pub const connect__Options = struct { timeout: i64 = 30, retry: bool = true };`
emitted only where the program names it.

Cost: sema (synthesize the object on first mention, resolve `.Options` on a
function or method name, ~150), emit (~40). Refuses `.Options` of a function
with no options ("`area` takes no options") or with a group.

### 2.4 Groups: `..name: T`

A parameter written `..net: Net` takes `Net`'s fields as options. At the call
they are given exactly as inline options are (by keyword, or by spread);
in the body, the group is one value, `net`, read as `net.timeout`.

What a group buys that inline options don't:

- **Sharing across functions.** `fetch`, `post` and `connect` all take
  `..net: Net`; one declaration, one doc comment, one place to add an
  option. A CLI parses flags once into a `Net` and passes `..net` to each.
- **Required name-only arguments** (the panel's open point 2). A field
  without a default is required: `obj CopyArgs` with `src`, `dst`
  and `overwrite: Bool = false`, then `fun copy(..a: CopyArgs)` is called
  `copy(src: x, dst: y)`, and `copy(x, y)` is refused. This is exactly how
  Zig gets required named arguments (a struct field with no default), with no
  new marker on parameters.
- **Several groups:** `fun with(?@, ..date: DateFields, ..clock: ClockFields)`.
  A keyword goes to the one group that has the name; a declaration whose
  groups, or a group and a parameter, share a name is refused.
- **A view group:** `..o: ?Net` takes the options as a read view, so a large
  options value is forwarded without a copy. Keywords build a temporary that
  the call views, as `.table(...)` written where a `?Val` goes already does.
  `..o: !T` is refused: options are inputs.

Keyword calls don't care whether an option is inline or in a group, so
**moving inline options into a group later is compatible for every keyword
caller**; only spreads of the old `f.Options` break, loudly.

Lowering: the group is one struct parameter, Zig's idiom exactly:

```zig
pub const Net = struct { timeout: ?Duration = null, retries: i64 = 3, follow: bool = true };
pub fn fetch(url: []const u8, net: Net) !Response { ... }
fetch(url, .{ .retries = 5 });
```

Zig passes a struct parameter by value or by const reference as it judges
best, and an inlined call scalarizes it, so it costs what the separate
arguments cost.

Cost: parser (`..name: T` in a parameter list, ~40), sema/typecheck (keyword
routing to groups, required fields, overlap check, ~250), emit (struct
literal at the call, ~60).

### 2.5 Struct update on constructors: `T(..v, f: x)`

A constructor is a call whose options are the fields, so the same spread
works: `Point(..p, x: 3)`, `connect.Options(..o, timeout: 5)`,
`Net(..defaults, retries: 0)`. This is Rust's `Point { x: 3, ..p }`, Kotlin's
`p.copy(x = 3)`, OCaml's `{ p with x = 3 }`, C#'s `p with { X = 3 }`, under
the same ownership rules as 2.2. It gives "partly overridden" for stored
options values, not only at calls. Visibility as any construction: only
where the type could be constructed.

Cost: nearly free once 2.2 exists (~60 in the constructor checker, ~30 emit).

### 2.6 Punning: `f(x:)`

`name:` followed by `,` or `)` means `name: name`. Ruby 3.1 (`f(x:)`), OCaml
(`~x`), Rust's field-init shorthand (`Point { x, y }`), JavaScript's `{x}`.
It works in calls and constructors alike. It is checked like anything else:
no binding of that name, or the wrong type, is refused.

It does not compete with options values: an options value forwards a whole
set; punning removes the repetition of building one from locals, and the
650 Trig lines are mostly construction, which only punning helps.

Cost: parser (~20 lines), a diagnostic. Refuses `x:` with no binding `x`.

### 2.7 Function values that keep their options

A function type may end with a group: `fun(?String, Int, ..Net) -> Response!`.
A call through such a value takes keywords and spreads, because **the names
live in the group's type, not in the parameter list**. That is the piece
Swift gave up (SE-0111 removed argument labels from function types, since
labels there are parameter names); a nominal group keeps names without
putting parameter names in types.

`connect` as a value has type `fun(?String, Int, ..connect.Options) -> Conn!`,
so `f = connect; f(h, 1)` now works with defaults, and `f(h, 1, timeout: 2)`
names its option. Two functions with inline options have different derived
types, so they don't fit one function type; the fix is a shared group, which
is the honest statement that they share options.

Lowering: the value's Zig type takes one struct
(`*const fn ([]const u8, i64, connect__Options) anyerror!Conn`). A function
with inline options, taken as a value, gets a generated thunk that unpacks
the struct; direct calls keep their flat arguments.

Cost: parser (`..T` in a function type, ~20), typecheck (calls through a
value with a group, ~80), emit (thunk, ~60). Breaking only for programs
that call a function value with positional options, which the base rule
already breaks.

## 3. Interactions

- **Generics:** a group may be a generic object, `..o: Opts[T]`. Not
  offered: a group generic over "whatever `F` takes" (`..o: F.Options` for a
  type parameter `F`). That is row polymorphism; leave it out.
- **APIs:** an API method takes options only through a named group,
  `fun render(?@, ..o: RenderOpts) -> String`. "A method meets its API
  exactly" then compares one type, and a call through a bound takes keywords
  and spreads. Inline defaults in an API method stay refused (comparing
  names and defaults per implementation is what a group already does).
- **Trailing closure:** the closure fills a function-typed parameter, never a
  group's field. `repeat(times: 2, ..o, |i| ...)` reads in order: operands,
  options, closure.
- **Effects and `!`:** a default is a literal or constant (a field default may
  also be an empty constructor, `List()`), so building an options value runs no
  code beyond the expressions written. A spread hides no call: `..defaults()!`
  shows its `!` where written.
- **Durations:** a group's fields are filled by the same rules as
  parameters, the duration forms included: `fetch(url, timeout: 0.5)`, and
  unit keywords (`fetch(url, ms: 500)`) only when the call's one `Duration`
  is that field. The duration forms are themselves, in effect, a built-in
  group whose fields add up; not proposed as a change.
- **Evolution:**

| Change | Keyword callers | Spreads / wrappers `..o: f.Options` | Function values |
|---|---|---|---|
| add an option with a default (inline or in a group) | compatible | compatible; the wrapper gains it | compatible |
| add a required group field | loud break | loud | loud |
| rename or remove an option | loud | loud | loud |
| reorder options | compatible | compatible | compatible |
| move inline options into a group | compatible | loud (`f.Options` gone) | loud |
| give a required parameter a default | **loud break** for positional callers | n/a | type changes |

The last row is the base rule's lasting cost and this design does not remove
it: making an operand an option changes how it is passed, in Zig too
(moving a parameter into the options struct). Names becoming API is likewise
inherent; groups make the API surface one declared type instead of scattered
parameter names.

## 4. The panel's open points

| Open point | Answer |
|---|---|
| wrappers repeat `timeout: timeout` | `..o: connect.Options` forwards the whole set, typed, and grows with `connect`; punning covers the rest (mostly construction) |
| a required argument can't be name-only | a group field without a default |
| defaulted names become API | still true; a group declares them in one place, shareable and documented |
| adding a default breaks positional callers | still true; inherent and loud |

## 5. The datetime library as the test case

```rig
obj Period                      # calendar units: Date.add, DateTime.add
  years: Int = 0
  months: Int = 0
  weeks: Int = 0
  days: Int = 0

obj DateFields                  # Date.with, DateTime.with
  year: Int? = none
  month: Int? = none
  day: Int? = none

obj ClockFields                 # Time.with, DateTime.with
  hour: Int? = none
  minute: Int? = none
  second: Int? = none
  ns: Int? = none

obj Step                        # round and floor on Duration, Instant, Time, DateTime
  ns: Int? = none
  us: Int? = none
  ms: Int? = none
  seconds: Int? = none
  minutes: Int? = none
  hours: Int? = none

pub fun add(?@, ..p: Period) -> Date
pub fun add(?@, duration: Duration? = none, ..p: Period) -> DateTime
pub fun with(?@, ..date: DateFields, ..clock: ClockFields) -> DateTime!
pub fun round(?@, days: Int? = none, ..s: Step) -> DateTime

monthly = Period(months: 1)
due = start.add(..monthly)
late = start.add(..monthly, days: 3)
soon = dt.add(hours: 36)               # duration forms, unchanged
noon = dt.with(hour: 12, minute: 0)
q = t.round(minutes: 15)
```

Every call the library has today reads the same. What changes: a billing
schedule can hold `Period` values in a table and apply them (`..row.period`),
which `add(months:, days:)` alone can't; eight copies of the six-unit
parameter list (std/time.rig, instant.rig, clock.rig, datetime.rig round and
floor) become one `Step`; `with`'s date and clock parts are one declaration
each. What does **not** change: "exactly one unit, an increment that divides
the next" for `round`, and "no duration units on a `Date`", are value checks,
not types; `ArgCheck` keeps them. No options design expresses "exactly one of
these fields" without an enum (`round(.minutes(15))`), and that reads worse.

## 6. What I'd leave out

- **Structural spread** (JavaScript): silent coupling when either side gains a
  field. Nominal only.
- **A dynamic or open bag** (Ruby `**opts`, Python `**kwargs` untyped): no
  unknown keys, ever.
- **Anonymous options literals** (Zig's `.{ .timeout = 30 }`, a target-typed
  `.(timeout: 30)`): keywords at the call already are the literal, and
  `connect.Options(...)` names it elsewhere. Not worth a new expression form.
- **Spreading `f.Options` of a function with groups** (nested derived types).
- **Generic "options of F"** (`..o: F.Options` over a type parameter).
- **Builders** (Rust's `ClientBuilder::new().timeout(5).build()`): struct
  update plus spreads give the same, typed, with no extra type and no
  runtime chain.
- **Binding group fields as bare locals** in the body (`timeout` instead of
  `net.timeout`): two names for one thing; the prefix says where it came from.

## 7. What it costs in all

| Area | Work | Rough size |
|---|---|---|
| parser | `..expr` argument, `..name: T` parameter, `..T` in a function type, punning | ~120 lines |
| typecheck (`checkArgs`, constructors) | route keywords and spreads to groups, overrides, required fields, overlap, function values with a group | ~600 |
| sema | derive `f.Options`, `.Options` on a function or method name, API rule | ~200 |
| ownership | a spread as field paths, `..<v`, `..+v`, a view group's temporary | ~150 |
| emit | flat arguments from a spread, struct literal for a group, thunk for a function value | ~200 |
| docs and tests | SPEC Functions/Objects/Function types, SYNTAX §11, a learn lesson; `test/rig` cases for each refusal | ~400 |

About 1.3k compiler lines, in stages that each stand alone: (1) base rule,
(2) spread + struct update + punning, (3) groups, (4) `f.Options`, (5) function
values with a group. Stages 2 and 3 together give the owner's "build once,
store, pass whole, partly override, share across functions" with a declared
`obj`. Stages 4 and 5 are the new ground (forwarding without the library's
foresight, options that survive as function values) and can wait for a real
wrapper or callback that needs them.
