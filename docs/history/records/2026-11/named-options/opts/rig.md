# Options at the call: the Rig compiler review, and the committee's recommendation

Read: the brief; `innovator.md`, `zig.md` and their probes; Rig main 75a6c7b5e:
AGENTS.md (North Star), SPEC Functions (1595-1660), SYNTAX §11, CORE §2 and §5,
`typecheck.zig` `checkArgs` (12034-12310), `argViews` (12437), `trailingParam`
(12483), `stdArgChecks` (12505-12600), generic argument matching (13395-13425),
`sema.zig` `ArgSlot`/`DurationParts`/`ParamFill`/`CallParams` (3009-3200),
`ArgCheck` (12307-12350), `storage.zig` `callHoistsArgs` (334), `emit.zig`
`emitArgsFrom` (9868), `modules.zig` rewrite rounds (879); the commits that
built the duration parts (15d3041dc: 544 lines, 251 of them in typecheck) and
the trailing closure (0ab04eed3: 179 lines). Probes in `rig/` beside this file.

## 1. Facts probed (bin/rig, main)

| Probe | Result | What it settles |
|---|---|---|
| `p1` `f(b: x, a: bump(!x))` | prints `101001`; emit hoists `bump(&x)` into `__rig_arg_1_1` and passes it first | keywords out of order already keep evaluation order (storage `callHoistsArgs`) |
| `p2` `s: String = "hi"` | refused: a `String` default is a `Static` | **an option is never an owner**: defaults are literals or module constants |
| `p3` `w: !Int = 3` | refused | **an option is never a write view** |
| `p12` `g: (?fun(Int) -> Int)? = none` | refused: a callable view is held by no value | an option, or a field, never holds a callable view |
| `p5` default in an API method | refused: "a call through the API passes each argument" | APIs today exclude defaults on purpose |
| `p7` `d: T = 0` in a generic | refused | an inline option's type never needs `T` given a literal default |
| `p8` `f = connect; g("h", 1)` / `..x` | defaults dropped through a value; `..x` refused as an open range | `..` in an argument is free syntax |
| `p9` `d.round` as a value | refused: an ArgCheck'd method "must be called" | `round`/`floor`/`with`/`add` are never values |
| `p10` `P(a: <p.a, b: ..., n: p.n)` | builds; `p.b` drops at `p`'s drop point, after `q`'s | partial moves already give struct update with owners, no new drop |
| `p11` `fetch("u", Net(timeout: 5))` with `net: ?Net` | works today; emits a temporary and `&` | Zig's idiom by view already exists in Rig |

So two of the reports' worries are settled by the language as it is: options
hold no owners and no write views, ever (CORE §5 for fields; SPEC Functions for
defaults). A spread into a call can only copy plain data and read views. The
`!` and `<` effects a spread could hide do not exist for options.

## 2. What breaks in today's checks, and the structural finding

Both reports put the spread **in `checkArgs`**: a new way for one argument to
fill several parameters. That is the mirror of `ArgSlot.parts` (several
arguments, one parameter), and Rig's call machinery is keyed the other way:

- `ArgSlot` and `slotOf` map a parameter to one argument index; `ParamFill`
  and `CallParams` (`resultCarries`, `stores`, `keepsViewed`, `fillsOnce`,
  `paramName`, all by argument index) feed the ownership checker's loans
  (`ownership.zig` 5861, 6112); `storage.callHoistsArgs` orders by argument
  index; `emit.emitArgsFrom` writes one argument per slot.
- **Arguments are matched to parameters in three places**, not one:
  `checkArgs`, `argViews` (the ignored-`!` diagnostics), and generic inference
  (13395), each with its own copy of the trailing-closure rule
  (`trailingParam`, used in all three). North Star 4 ("one classifier per
  fact") is already stretched here; a fourth slot kind would have to be taught
  to all three, to the loans, to hoisting, and to emit.
- `stdArgChecks` reads the call's syntax: it counts keywords ("exactly one
  unit") and reads constants (an increment's range, divides-the-next). A spread
  carried as one argument is invisible to it. The innovator's `Step` group
  would let `t.round(..s)` through unchecked: a North Star 1 break. The Zig
  report saw that and proposed a blanket rule; it is too broad (a spread into
  `Date.add` is safe) and it misses that a derived `DateTime.round.Options`
  would be the same hole.

Estimated honestly, the reports' route touches typecheck, sema, storage,
ownership, emit, facts and the oracle's lowering; the duration parts, the
smaller mirror, took 544 lines. Their 1.1-1.3k totals are plausible only if
nothing goes wrong in the loans.

**The cheaper and safer route: a spread is a rewrite, not a slot.** Rig already
rewrites type-directed forms between checking rounds: a chain
(`xs.filter(f).count()`) and a `for` over an iterator are found by typecheck,
recorded, rewritten by the Parser (`desugarChains`, `desugarIterLoops`), and
the module is checked again (`modules.zig` 879). A spread fits exactly:

```rig
connect(host, 5432, ..o, retry: false)
# round 1 types `o` (connect.Options), checks the spread, records it;
# the Parser rewrites the call, at the spread's place, into
connect(host, 5432, timeout: o.timeout, retry: false)
# and round 2 checks an ordinary keyword call.

q = Point(..<p, name: n)
# becomes
q = Point(x: <p.x, y: <p.y, name: n)     # `<` on each field it takes
```

Then:

- **Nothing downstream changes.** `ArgSlot`, the loans, hoisting, emit, `argViews`
  and generic inference see keyword arguments, which they handle today.
- **Effects stay visible by construction.** Each field becomes a real node with
  the sigil written on the spread (`..<p` gives `<p.f` move nodes, `..+p`
  clones). No new ownership rule: the CORE §10 paragraph is "a spread is the
  keyword arguments `f: v.f` for each field not named after it, each with the
  spread's sigil". An overridden field is never read from `v`, so no hidden
  drop: it stays in `v` and drops at `v`'s drop point (probe `p10`).
- **Evaluation order is today's.** The fields stand at the spread's place in
  the written order; `..o, timeout: g(!o)` hoists as `p1` does.
- **ArgChecks get per-call precision for free.** `t.round(..s)` becomes six
  unit keywords and the existing "exactly one unit" check refuses it; `d.add(..p)`
  becomes calendar keywords and passes `calendar_add`. One extra diagnostic
  names the spread as the cause.
- **Restriction:** the operand is a place: a name or a field path, which
  "a field read never runs code" makes safe to read once per field. A made
  value (`..defaults()`, `..xs[next()]`) is refused in v1 with "bind it
  first"; that also keeps its `!` on its own line.
- **Cost:** a second check of the module, only when it has a spread, as with
  chains. Diagnostics in round 2 must carry the spread's span.

## 3. Groups: a spread at the declaration, flattened in the signature

Zig measured that a struct parameter is copied to the stack and passed by
pointer when not inlined (I accept the measurement; not re-run). The Zig
report fixes it in emit: lower a group flat. I would go one step further and
do it **in the signature**, in sema: `fun fetch(url: ?String, ..net: Net)` has
the function type of

```rig
fun fetch(url: ?String, timeout: Duration? = none, retries: Int = 3, follow: Bool = true)
```

whose group fields are name-only parameters, plus a body-only local `net: Net`
built from them where used whole (`net.timeout` is the parameter itself; the
field names do not enter the body's scope). So:

- `checkArgs`, the loans, emit of calls: unchanged; the checker checks exactly
  what is emitted (North Star 4); zero cost by construction; no thunk.
- `..` means one thing: at a parameter it spreads a type's fields into
  parameters; at an argument it spreads a value's fields into arguments.
- A field without a default is a **required name-only** argument: one flag in
  `ParamInfo` (the panel's open point 2).
- Collisions (two groups, or a group and a parameter, sharing a name) refused
  at the declaration. A `pub` function's group type must have `pub` fields.
- Groups hold values and read views only in v1 (Zig report): with no owners in
  a group, the body local needs no drop and a spread of a group never moves.
- The trailing closure never fills a group field (one condition in
  `trailingParam`); moot in v1 anyway, since a field cannot hold a callable
  view (`p12`).
- `ParamMask` is 64 bits; flattening spends bits per field. Fine in practice;
  refuse past 64 as today.

`f.Options` is then one rule for both reports' cases: **the object of all of
`f`'s name-only parameters**, inline options and group fields, in order. A
spread into `f` accepts a value of type `f.Options` or of one of `f`'s group
types, nominally. Refused: `.Options` of a function with none, of an ArgCheck'd
std method (never a value, `p9`), and of a function where an option's type
names a type parameter.

## 4. Interactions

- **Keyword-only rule:** a spread names its fields, so it counts as keywords.
  Order: positionals, then spreads, then keywords (which override), then a
  trailing closure. A field covered twice (two spreads, or a keyword before a
  spread) is "given twice".
- **Duration forms:** flattened group fields are parameters, so `info.durations`
  and the one-duration rule apply unchanged: `fetch(url, ms: 500)` fills
  `timeout` when it is the call's one `Duration`. After a spread, a unit
  keyword overrides that duration field (the rewrite drops `timeout:`); else
  the existing "one duration: not both" refusal would fire.
- **Generics:** inline options never need `T` (`p7`). A generic group
  (`..o: Opts[T]`) flattens per instance: deferred.
- **APIs:** defaults are refused in API methods today for a reason a group
  answers (the defaults live in the type both sides name), but conformance and
  table calls need work: deferred to a real API that wants it.
- **Function values:** a grouped function as a value has its flat type,
  defaults dropped, as today. Keeping keywords through a value (the
  innovator's 2.7) needs function types that carry a group and closures that
  take one (`|x, ..net|`), which neither report designs: deferred.
- **Punning** `name:` is bare only: a copy or a view. A bare owner in a
  constructor already needs `<` (CORE sentence 1), so `buf:` of a `List` is
  refused with "write `buf: <buf`": punning never hides a move.
- **Syntax:** `..x` in `( )` is a spread and `xs[..b]` in `[ ]` a range,
  told apart by the bracket, as Rust does.

## 5. Verdict on the two reports

- Innovator: the language design is right (nominal spread, spread then
  overrides, struct update, punning, groups). Wrong: `Step` as a group (breaks
  `round`'s compile-time check); groups as Zig struct parameters (copy, thunk);
  owners in groups with `..<v` for calls (options never own); function values
  with groups in v1.
- Zig report: right on flat lowering, no thunk, no owners in groups, `f.Options`
  always defined, and struct update by partial move. Too broad: "no spreads
  into ArgCheck'd calls" (the rewrite refuses exactly the unsafe ones). Both
  reports route the spread through `checkArgs`, which is the costly, risky
  part.

## 6. The datetime library

```rig
obj Period
  years: Int = 0
  months: Int = 0
  weeks: Int = 0
  days: Int = 0

pub fun add(?@, ..p: Period) -> Date                                # same flat signature as today
pub fun add(?@, d: time.Duration? = none, ..p: Period) -> DateTime
pub fun with(?@, ..date: DateFields, ..clock: ClockFields) -> DateTime!
pub fun round(?@, ns: Int? = none, ...)                              # unchanged: no group

monthly = Period(months: 1)
due = start.add(..monthly)
late = start.add(..monthly, days: 3)
q = t.round(minutes: 15)
```

Emitted Zig for `add` and `with` is unchanged (the flattened signature is
today's). `round`/`floor` keep inline units: "exactly one unit" is a
call-site check, and a stored step is a `Duration`.

## 7. Cost

| Piece | Where | Compiler lines | Tests and docs |
|---|---|---|---|
| punning | grammar, one diagnostic | ~30 | ~60 |
| spread and struct update | grammar; typecheck records (round 1); `Parser.desugarSpreads`; spans | ~350 | ~300 |
| `f.Options` | sema synthesizes an `obj`; `.Options` resolution; emit the type when named | ~250 | ~120 |
| groups | sema flattens signatures; body local and its emit; name-only required; collisions; `trailingParam`; LSP signature help | ~400 | ~250 |
| **v1** | | **~1.0k** | **~0.7k** |

Nothing in ownership, storage or emit's call path. Deferred pieces (function
values with options, API groups, view groups `..o: ?T`, generic groups, owners
in groups, spreads of made values) each cost a few hundred lines and wait for
a program that needs them.

Before any of it: the base rule (326 sites). Worth doing alongside, as a
refactor of its own: one argument-to-parameter matcher that `argViews` and
generic inference read, instead of three.

## 8. The committee's recommendation for the owner

**Design.** Options are named; `..` spreads. In a parameter list, `..net: Net`
makes `Net`'s fields the function's options; in a call or constructor, `..v`
passes `v`'s fields by name and names written after it override them; `name:`
alone is `name: name`.

```rig
fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Conn!
fun fetch(url: ?String, ..net: Net) -> Response!
fun connect_logged(host: ?String, port: Int, ..o: connect.Options) -> Conn!
  connect(host, port, ..o)
o = connect.Options(timeout: 5)
connect(host, 5432, ..o, retry: false)    # emits connect(host, 5432, o.timeout, false)
q = Point(..<p, x: 3)
Mapping(generated_position:, source_index:)
```

Decisions (approve the defaults):

1. **Adopt `..` for groups and spreads, plus punning**, on top of the base
   rule. Default: yes.
2. **Build a spread as a rewrite into keyword arguments** (the chains
   precedent) and a group as a flattened signature, not as new argument slots.
   Default: yes.
3. **v1:** punning, spread and struct update, `f.Options`, groups. **Later:**
   function values keeping options, API groups, view groups `..o: ?T`, generic
   groups. Default: yes.
4. **A spread's operand is a place** (a name or field path); bind a made value
   first. Default: yes.
5. **Spreads are nominal**: `v`'s type is `f.Options` or one of `f`'s group
   types. Default: yes.
6. **Groups hold values and read views, no owners**, in v1. Default: yes.
7. **Datetime:** `Period`, `DateFields`, `ClockFields` become groups;
   `round`/`floor` keep inline units. Default: yes.
