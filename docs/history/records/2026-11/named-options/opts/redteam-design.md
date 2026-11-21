# Red team: design coherence, edge cases, evolution, teaching, precedent

Read: REDTEAM.md, BRIEF.md, innovator.md, zig.md, rig.md, kwonly/PANEL.md and
designer.md; Rig main 75a6c7b5e: SPEC Functions (1595-1660) and Durations
(14899-14990), SYNTAX §11, `typecheck.zig` `stdArgChecks` (12505-12600),
`modules.zig` rewrite rounds (870-885), std/datetime signatures. Probes in
`red/` beside this file, run with `bin/rig run` (r1-r19).

## Verdict

**Sound with fixes.** I found no fatal hole in the core (the rule, punning,
struct update, groups, nominal spreads by rewrite). I found four serious
problems. Two are cases where the compiler accepts a program that is wrong, or
where the design's own claims are false (function values; evolving a shared
group). Two are holes in the forwarding story (an override that throws away
what the caller passed, and `f.Options` making a tower of incompatible types).
Each has a small fix, and two of the fixes cut code rather than add it. The
"two sentences" claim does not hold up: the honest count is about a dozen
rules (finding 11).

## Facts probed (today's compiler)

| Probe | Result | Why it matters |
|---|---|---|
| r9 `g = f; g(5, false)` | runs: options passed by position through a value | the rule's readability ends at every callback |
| r13 `g(1, 5, 2)` for `f(x, timeout = 30, retries = 3)` | `502`: order is all that binds | swapping two options of the same type goes unnoticed through a value |
| r15 two `Duration` options, `f("u", ms: 5)` | refused: "takes 2 durations" | a second `Duration` field breaks every unit-keyword caller |
| r16 `ms: Int = 1` beside a `Duration` | refused at the declaration | a group's `Duration` field can break a declaration elsewhere |
| r1 `Net(ms: 500)`, `Duration?` field | refused: no field `ms` | a constructor takes no duration forms; a call does |
| r2 obj field `f: fun(Int) -> Int` | works | a group *can* hold a function value; the trailing-closure question is not moot |
| r3 param default `= twice` | refused | an option is never a function |
| r4 `P(a: <p.a, n: <p.n)` | refused: "`<` on a copy" | the rewrite cannot put the spread's sigil on every field |
| r10 partial move from a type with `drop` | refused | struct update of such a type is always refused |
| r6 `obj R` (`n: Int = 3`), `R(5)` | works | a one-field object takes its field by position |
| r7 field default `1 + 2` | refused; field defaults allow `List()`, `[n of 0]`, `T()` | field defaults are a wider set than parameter defaults |
| r8 `w.d` = -0.5, `time.sleep(w.d)` | accepted; `x = -0.5; sleep(x)` refused | constant checks don't follow a value through a field |
| r12 `f(a:` newline `b)` | `a: b` | `name:` at the end of a line takes the next line as its value |
| r17 a view field outliving its source | refused | view fields in objects are already checked |

## Findings

### 1. Function values call options by position: the rule leaks, and a group's field order becomes its ABI (serious)

```rig
fun fetch(url: ?String, ..net: Net) -> Response!   # Net: retries: Int = 3, redirects: Int = 5
cb = fetch
cb(url, none, 2, 9)          # a flat type with no defaults: options by position (r9, r13)
```

rig.md: "a grouped function as a value has its flat type, defaults dropped, as
today." So (a) the rule "an option is given by name" turns into "options by
position" at every callback, the exact `connect(host, 30, true)` the rule was
adopted to forbid. (b) The order of `Net`'s fields becomes the positional
order of every function that uses it. Nothing else in Rig depends on field
order: constructors name their fields. So a maintainer who swaps `retries` and
`redirects` in `Net` silently swaps the arguments of every call through a
value. The program compiles and is wrong. The designer's evolution table
("reorder defaulted params: safe") is false through values even today (r13).
The innovator's table ("reorder: compatible, function values compatible") is
false under rig.md's flattening.

**Fix (v1):** taking a function that has options (inline or a group) as a
value is refused: "write a closure, `|u| fetch(u, retries: 2)`". The panel
measured no function-value sites, so this costs nothing to adopt. Function
types that keep options come later, as already planned. About 20 lines.

### 2. Adding a field to a shared group is not compatible (serious)

The evolution tables say "add an option with a default: compatible". For an
inline option that is true. For a group shared by many functions in many
modules, it is false in four ways:

```rig
obj Net
  timeout: Duration? = none
  connect_timeout: Duration? = none     # added
fetch(url, ms: 500)                     # was fine; now refused, two durations (r15)
fun poll(url: ?String, ms: Int = 10, ..net: Net)   # refused at the declaration (r16)
fun post(url: ?String, body: ?String, ..net: Net)  # refused if Net gains `body`
```

The ways: a name collision with a parameter or another group in any function
that uses the group; a second `Duration`, which removes the unit keywords
from every caller of every such function; a parameter named for a unit next
to a new `Duration` field; and the 64-bit `ParamMask`. The group's author
cannot see these functions. Python's PEP 692 `Unpack[TD]` has the same
overlap error.

**Fix:** (a) **unit keywords never fill a group field.** A group's `Duration`
field is given by its own name (`timeout: 0.5`, `timeout: d`), never `ms:`.
This removes failures 2 and 3. It removes rig.md's special case where a unit
keyword overrides a spread field. It also makes the call and the constructor
agree (r1: `Net(ms:)` is refused anyway). (b) The collision diagnostic names
the group field and the group's declaration, not only the function. (c) The
docs say plainly that a `pub` group's field names are API for every function
that uses it.

### 3. A forwarding wrapper can silently discard what the caller passed, and can't change a default (serious)

```rig
fun connect_safe(host: ?String, port: Int, ..o: connect.Options) -> Conn!
  connect(host, port, ..o, insecure: false)    # meant: "pin TLS on"
connect_safe(h, 1, insecure: true)             # accepted; the caller's true is ignored
```

Order is fixed: the spread first, then the overrides; a keyword before a
spread is "given twice". So JavaScript's `{timeout: 5, ...opts}` (the wrapper
sets a default and the caller wins) cannot be written. The override form
(`..o, k: v`) can be written, and when `o` is the function's own group
parameter it throws away a value the caller wrote explicitly. In addition,
`..o: connect.Options` grows the wrapper's public options whenever `connect`
gains one. A wrapper meant to restrict (pin TLS, cap retries) then exposes
the new knob. This is the pass-through opacity of Python's `**kwargs`, typed
but the same in effect.

**Fix:** refuse overriding a field of the function's own group parameter
inside its body: "`insecure` of `o` is given by your caller; overriding it
discards that. Declare the option yourself." A wrapper that pins or
re-defaults an option declares it inline and forwards the rest by hand. Leave
"a group with different defaults" for later, when a program needs it.

### 4. `f.Options` is defined three ways and makes towers of incompatible types (serious)

- innovator: only when every option is inline; zig: the inline options only;
  rig.md: **all** name-only parameters, inline and group fields together.
  The owner is approving decision 3 without one definition.
- Under rig.md, `fetch.Options` is a new nominal type with `Net`'s fields, so
  a `Net` value can't go to `fun f(..o: fetch.Options)`, nor a `fetch.Options`
  to `fun g(..n: Net)`. And `connect_logged.Options` (from `..o:
  connect.Options`) is not `connect.Options`. So `o =
  connect_logged.Options(timeout: 5)` can't be spread into `connect`. Each
  layer of wrapper adds another identical but incompatible type.
- Converting between them is unspecified (`fetch.Options(..net)`: is `Net` a
  "group" of a constructor?).

**Fix:** `f.Options` of a function whose name-only parameters are exactly one
group **is** that group's type, an alias, not a new type. Otherwise it is
synthesized as rig.md says. Better for v1: **defer `f.Options`**. Groups,
spreads, struct update and punning already give "build once, store, pass
whole, partly override, share" whenever the library declares a group, and
Trig's 650 `x: x` lines are construction, which punning covers. Deferring
saves about 250 lines and removes findings 3b and 4.

### 5. Constant checks lapse silently through a spread (minor)

`x = -0.5; time.sleep(x)` is refused; the same constant in a field is not
(r8). After the rewrite, `per: o.per` is a field read, so the negative-wait
check, the constant duration-sum overflow, and constant range checks all stop
applying. The run-time behavior is defined (a negative wait counts as zero),
so the program is not wrong. But rig.md's "ArgChecks get per-call precision
for free" is true only for the checks that count keywords. **Fix:** say so in
SPEC. Keep refusing `.Options` of an ArgCheck'd method.

### 6. A group and its constructor spell durations differently (minor)

`fetch(url, ms: 500)` fills `timeout`; `Net(ms: 500)` is refused (r1); after
`..n`, `ms:` overrides `timeout` only through a special case. Three spellings
for one field. Fixed by 2(a).

### 7. Rewrite details rig.md gets wrong (minor)

- "`<` on each field it takes" is refused for copy fields (r4). The rewrite
  must decide per field: `<` only on owners, plain reads for the rest. An
  error in a generated node needs the spread's span.
- Struct update of a type with a `drop` body is always refused (r10). The
  message should speak of the spread, not `swap(!p.a, v)`.
- Rust users will write the base last, `Point(x: 3, ..p)`. They get "given
  twice". That needs its own message: "a spread comes before the names that
  override it".
- `..<r, w: r.h` reads a field the spread has already moved (spread first).
  Rust evaluates the base last, so this works there. Refused loudly; not a
  bug, a surprise.
- A spread whose operand's type is a type parameter (`..o` with `o: T`) can't
  be rewritten per module. Refuse it.

### 8. A one-field options object brings back the bare positional option (minor)

`R(5)` works for a one-field object with a default (r6). So `scaled.Options(2)`
and a one-field group `Verbose(true)` give options by position, the bare
boolean the rule exists to remove. **Fix:** derived `Options` types and
objects used as groups take their fields by name only, or accept and document
the exception.

### 9. Punning (minor)

- `f(a:` newline `b)` means `a: b` today (r12), which is Ruby 3.1's trap: a
  punned `verbose:` with a forgotten comma swallows the next line. Since a
  positional argument can't follow a keyword, this only bites a forgotten
  colon or comma, but it is silent when the types agree. **Fix:** a keyword's
  value starts on its own line only when indented, or a pun requires `,` or
  `)` on the same line.
- `timeout:` picks up any binding: rename the local and a module constant or
  a function named `timeout` silently fills it. **Fix:** a pun names a local
  or a parameter only.

### 10. Group defaults are field defaults, not parameter defaults (minor)

Flattening makes parameters whose defaults follow the field rules (`[n of 0]`,
`T()`, `Cell(0)`; r7). A declared parameter can't have these (r3). Still
constants, so still sound; SPEC must say that a group's fields keep their
field defaults. Sharing defaults across functions is coupling: `fetch` and
`post` share `retries: Int = 3`, but a POST should not retry by default.
Guidance: give shared group fields `T? = none` and let each function choose.

### 11. Teaching: not two sentences (minor, but it's the pitch)

A newcomer must learn: options are named; positional arguments first; `..x:
T` at a declaration; `..v` at a call; overrides after it, never before; one
spread per group; nominal, so a field-identical type is refused; the operand
is a place (bind a made value first); the sigil on a spread (`..<p`, `..+p`);
groups hold no owners; `f.Options` and its refusals; how unit keywords and
groups interact; punning resolves bare only. That is a dozen rules, with `..`
now meaning range, open slice, range pattern, group, spread and struct update.
What each newcomer will get wrong:

| From | Writes | Gets |
|---|---|---|
| JS | `f(timeout: 5, ..o)`, `f(..a, ..b)` | "given twice" (wanted later-wins merge) |
| JS/TS | `..cfg` of a look-alike type | refused (nominal); must list fields |
| Rust | `Point(x: 3, ..p)`, `..Default()` | "given twice"; "bind it first" |
| Python | `f(h, 5)` for a defaulted `timeout` | refused, with a fix (good) |
| Zig | `f(h, .{ .timeout = 5 })` | refused; no anonymous literal |
| Swift | `cb = f; cb(h, timeout: 5)` | refused today; with fix 1, "write a closure" |
| Ruby | `f(x:)` | works (same as 3.1) |

### 12. Cost claims (minor)

"Nothing in ownership, storage or emit's call path" is plausible by the
rewrite. But emit changes in function prologues (the body-local group
struct, mangled flat parameter names, the `f.Options` type). LSP needs
signature help that expands groups, and rename across spreads. Round-2
diagnostics need span mapping. `trailingParam` needs the group exclusion (r2
shows a group can hold a `fun`). Expect 1.3-1.6k compiler lines, not 1.0k.
Zero run-time cost holds for the flat lowering. A large group has no
by-pointer form in v1 (`..o: ?T` is deferred), which is fine.

## Precedent check

| Failure | Repeated? |
|---|---|
| Ruby 2 hash/keyword ambiguity | No: `..` is written and spreads are nominal. Only finding 8 (positional one-field constructor) recalls it |
| Python `**kwargs` opacity | Partly, via `f.Options` forwarding (finding 3) |
| C# defaults baked into callers | Harmless under whole-program compilation; note it if separate compilation arrives |
| Scala `copy` bypassing a private constructor | Avoided ("only where the type could be constructed") |
| Scala/Swift eta-expansion dropping defaults (SE-0111) | **Yes**, finding 1: same cause, worse consequence, because Rig's rule says options are named |
| JS spread's silent coupling | Structural coupling avoided; the order is fixed one way, so `{default, ...user}` can't be written (finding 3) |

## What I would ship

v1: the base rule; punning (fix 9); struct update; groups with spreads of
group values (fix 2a); function values of option-taking functions refused (fix
1); overriding your own group's field refused (fix 3). Defer `f.Options` (fix
4) until a real wrapper needs it, and then define it as the group's alias
when there is exactly one group.
