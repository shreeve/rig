# Keyword-only defaults: the language designer's report

Read: Rig main e38454865, SPEC "Functions" (lines 1595-1660), SYNTAX §11
"Calls", `src/sema.zig` `ArgCheck`/`stdArgCheck` (12305-12350), std declarations,
`calls.tsv`, `summary-raw.txt`, `std-decls.txt`, `patch.diff`. Probes in
`designer/` (`a.rig`, `b.rig`, `c.rig`), run with `bin/rig run`.

## Summary

The rule is good. It is the convention that nearly every language that has
named and default arguments ends up at, and Rig would make it a compile-time
rule instead of a lint. **But the first-parameter exemption is the weak part.**
It keeps the holes the rule is meant to close, so most of the datetime special
checks can't be removed after all. Drop the exemption: **"a parameter with a
default is given by name."** Verdict: **adopt, with changes.**

## 1. Is it good? Fit, cleanliness, brittleness

### Fit with the ethos

- *Correct if accepted:* a misplaced optional argument can't compile. Today
  `format_int(255, 16, true)` and a reordered `format_int(n, upper, base)`
  both compile and mean whatever the position says. Python 3.13 had to
  deprecate positional `count`/`flags` in `re.sub`/`re.split` for exactly this
  bug (`re.sub(p, r, s, re.I)` silently passed the flag as `count`).
- *Visible:* the option's meaning is on the page at the call.
- *Small:* no new syntax, one sentence in SPEC, and it removes compiler code
  (the std-only `ArgCheck` positional rules) instead of adding any.
- *No ceremony:* it costs a name only where a default exists, that is, only
  where the caller is choosing an option rather than giving the operand.

### The first-parameter exemption keeps the holes (measured)

Every datetime method whose positional form is a hazard has a defaulted
*first* parameter, so the exemption lets it through:

| Call | Under the exemption | Today |
|---|---|---|
| `date.add(1)` | years: 1 (most readers guess days) | refused by `calendar_add` |
| `dt.add(1)` | 1 *second* (the doc comment has to say "a bare number is seconds, never days") | allowed |
| `t.with(3)`, `d.with(2024)` | hour 3, year 2024 | refused by `by_name` |
| `dur.round(5)` | ns: 5 | refused by `unit_increment` |
| `text.CharBreak.new(true)` (std/terminal.rig:731), `term.dump(false)` | a bare boolean | allowed |

So under the owner's rule only `duration_add` (`dt.add(1, 2)`) becomes
redundant. `by_name`, `calendar_add`, and the "no positional" parts of the
round checks have to stay, still std-only and still refused in generic code.
The brief's motivation is mostly not met.

Without the exemption, all of those are refused by the general rule. What is
left of `ArgCheck` is *value* checks: exactly one unit, an increment that
divides the next unit, no duration units on a `Date`. Those are a different
matter.

The exemption costs almost nothing to drop. A grep of std, tests and docs
finds no positional `Map/Set/HashMap.new(n)`. The positional uses are
`CharBreak.new(true)`, which should be named anyway, and `dt.add(0.5)`,
which becomes `dt.add(seconds: 0.5)` (the unit keyword already fills the
`Duration` parameter) or `dt.add(d: span)`.

**Swift is the warning here.** Swift 1 and 2 left a method's first argument
unlabeled and labeled the rest, a holdover from Objective-C selectors.
SE-0046 (Swift 3) removed the asymmetry because a rule that depends on
position confused users and pushed the first argument's role into awkward
base names. A "first is special" exception that applies only to defaulted
parameters is the same kind of irregularity.

### Evolution (library APIs)

| Change to a declaration | Today | Proposed rule (no exemption) |
|---|---|---|
| Insert a new defaulted param before an existing one | **silently** shifts positional callers when the types match | safe |
| Reorder defaulted params | **silently** wrong when the types match | safe |
| Prepend a defaulted first param (with the exemption) | silent | silent with the exemption; safe without |
| Add a default to a required param | compatible | **breaks positional callers, loudly** (in Swift, Kotlin, C# and Python this is compatible) |
| Rename a defaulted param | breaks only callers who named it | breaks every caller who passes it: names become API |
| Remove a default | breaks callers who left it out | same |

The rule never changes a program's meaning silently. Every break is a compile
error with an exact fix. The real cost is the one row other languages don't
have: adding a default is a breaking change. Pre-1.0, with a mechanical fix,
that is acceptable. The owner should know it is permanent, though. After 1.0,
a std parameter that gains a default is a breaking release. So before landing,
review the 29 std names (`d`, `keep`, `selective`, `wait`, `parents`), since
they become contract.

### Interactions

- **Trailing closures.** Today the closure fills a *positional* slot unless it
  follows a keyword argument. So `repeat(|i| ...)` with `repeat(times: Int = 1,
  f: ?sub(Int))` fails ("expected `Int`, got `sub`"), and `each(3, |i| ...)`
  with a defaulted `step` before `f` fails too (probes `a.rig`, `c.rig`). Once
  defaulted parameters can't be filled by position, the coherent rule is that
  positional arguments fill the leading required parameters, and a last
  closure fills the open function parameter. That fixes this papercut, but
  only without the exemption (with it, `times` is still positional and the
  closure lands on it). Make the implementation count the trailing closure as
  filling by type, never by position.
- **A required parameter after a defaulted one** (`mid(a, b = 2, c)`): under
  the rule, `c` can only be given by name. Either say so in SPEC, or (better)
  refuse such a declaration unless the late parameter is function-typed (the
  closure's).
- **Function values:** function types carry no names or defaults (as in Swift
  SE-0111), so a call through a value passes everything by position. That is
  consistent: there is nothing to name. Zero cases measured.
- **Generics and APIs:** API methods can't declare defaults today. If they
  ever can, decide then that a defaulted parameter's name is part of the API
  signature and implementations must match it. This rule makes those names
  load-bearing.
- **No overloading:** labels never select an overload (unlike Swift, where
  `move(to:)` is part of the name). So this is purely a readability and safety
  rule, and simpler than Swift's.
- **What it does not cover:** required booleans. loco's `kind("\"", "\"",
  true, false, .rip)` gets only `interp: .rip`, and `escape` and `multiline`
  stay bare because they have no default. The brief slightly overstates this.
  The author's remedy is to give them defaults, which then forces names.

## 2. How far from other languages

It is in very good company. It is not off the reservation, and it is not
basically Swift.

- **OCaml:** optional arguments (`?x`) are labeled by construction and can
  never be passed by position. This is the exact precedent, with no
  exemption.
- **Zig:** the options-struct idiom (`.{ .timeout = 30 }`). Required
  arguments are positional, every defaulted field is named. Rig's rule is
  that idiom without the struct, and since Rig compiles to Zig it is a
  natural fit.
- **Rust:** no defaults; builders or `..Default::default()`. Optional settings
  are always named.
- **Dart:** optional parameters are `[]` positional or `{}` named. Effective
  Dart says to avoid positional booleans, and Flutter is named-optional
  throughout.
- **Python:** keyword-only after `*` is opt-in, but stdlib practice is
  converging there (`sorted(key=, reverse=)`, the 3.13 `re` deprecations).
- **Ruby 3:** separated keyword arguments from positional ones, a breaking
  change staged with 2.7 warnings.
- **Kotlin, C#:** named optional arguments are never required, but IDE
  inspections flag unnamed boolean literals. The community wants this; the
  language doesn't enforce it.
- **Swift:** labels on *all* parameters by default (`_` opts out), fixed
  order, labels part of the name. Rig's rule is narrower (only defaulted
  parameters), with free order and no overloading. It is closer to OCaml and
  Zig than to Swift.

## 3. Is the breaking change worth it, and how to land it

Yes. It is 326 call sites, all mechanical, and pre-1.0 (Unreleased already
carries an "Upgrading" section with migration scripts).

- The migrated form (named arguments) is **valid under today's compiler**. So
  there is no flag day and no warning stage, which Rig doesn't have anyway
  (it accepts or refuses).
  1. Patch Trig, loco, std, docs and tests to the named form first (each repo
     lands on its own).
  2. Land the rule, and in the same PR delete `by_name`, `calendar_add`'s
     positional part, `duration_add`, and the "no positional" parts of the
     round checks.
- `tools/migrate-kwonly.py` should be driven by the compiler's own diagnostics
  (file:line:col plus "write `by: 2`"). The callee is resolved by the
  compiler, not guessed by regex. No new compiler option is needed.
- Add a CHANGELOG Unreleased "Upgrading" entry and a section in
  MIGRATING-0.3.md. Update SPEC and SYNTAX §11: SYNTAX's own example
  `scaled(3, 2)` is shown as valid today and becomes a `reject` case.
- The error message should name the parameter and give the rewrite: "`by` has
  a default, so it is given by name: `scaled(3, by: 2)`".
- In the same PR, drop the defaults that pass the default value (22 of Trig's
  33 `base: 10`).

## 4. `Time.new` and `DateTime.new`

This is the one place where the rule's premise is weak. Hour, minute, second
and ns form a universal, magnitude-ordered sequence, so position does
carry meaning. That is why Python, Java's `LocalTime.of` overloads and JS
Temporal allow prefixes. The usage is real: `DateTime.new` is called with
3/4/5/6/7 arguments at 27/41/17/8/40 sites, and `Time.new` with 2/3/4 at
50/26/54.

The options:

- **Drop all the defaults (Jiff).** `DateTime.new(2024, 1, 31, 0, 0, 0, 0)` is
  seven bare integers, the very `connect(host, 30, true)` shape the rule is
  against, and a run of zeros is easy to misread. Not this.
- **Keep the defaults, named.** `Time.new(8, 7, second: 3)` is odd: minute
  bare, second named, though they are the same kind of thing.
- **Recommended: split along the type's own structure.**
  - `Time.new(hour, minute, second, ns = 0)`: second required, ns named. ns
    is rare and on a different scale, so `ns: 500` reads well.
    `Time.new(8, 7)` becomes `Time.new(8, 7, 0)`.
  - `DateTime.new(year, month, day, hour = 0, minute = 0, second = 0, ns =
    0)` keeps its defaults: the date is positional and the clock is named.
    `DateTime.new(2024, 3, 10, hour: 2, minute: 30)` mirrors `dt.with(hour:)`
    and the Date-plus-Time split. The 27 three-argument sites are unchanged.

No exception to the rule is needed.

## 5. Verdict

**Adopt, with changes:**

1. Drop the first-parameter exemption. Without it the rule really does replace
   the positional parts of the datetime checks, and it closes `date.add(1)`,
   `dt.add(1)`, `t.with(3)`, `dur.round(5)` and `CharBreak.new(true)`.
2. A trailing closure fills the open function parameter, never a defaulted
   slot (this fixes `repeat(|i| ...)`, which fails today).
3. Refuse, or document, a required non-function parameter after a defaulted
   one.
4. State that a defaulted parameter's name is API, including for future API
   methods with defaults.
5. Land it with the named form migrated first (valid today), then the rule,
   with the special-check deletions in the same PR.

The owner should know two things:

- After 1.0, adding a default to a parameter is a breaking change. This is
  the rule's one lasting cost, and its price for making insert and reorder
  safe.
- The rule doesn't touch required booleans.
