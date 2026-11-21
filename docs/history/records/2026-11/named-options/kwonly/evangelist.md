# Keyword-only defaults: the evangelist's report

Read: Rig main (now 75a6c7b5e, past the brief's e38454865), AGENTS.md,
docs/design/mantras.md, DESIGN.md, QUICK.md, FAQ.md, BEYOND-RUST.md,
docs/learn/, SPEC "Functions" and "Objects", SYNTAX §11, the std
declarations, `src/sema.zig` `ArgCheck`, and designer.md. Programs are in
`evangelist/` beside this file, run with today's `bin/rig run`
(`today.rig` and `named.rig` are one program written both ways; `p1` to
`p7` are edge probes).

## Summary

Adopt, without the first-parameter exemption. Taught as **"a default makes
a parameter an option, and an option is given by name,"** the rule is one
sentence with no exception. It matches what Rig already does for objects,
and it removes a std-only special case instead of adding one. With the
exemption it is a position rule that needs a footnote, and it leaves open
the very calls it was meant to close.

## How the two forms read (`today.rig` and `named.rig`, same output)

| Today (accepted) | Named form (valid today, required by the rule) |
|---|---|
| `connect("db.local", 30, true)` | `connect("db.local", timeout: 30, retry: true)` |
| `text.format_int(255, 16, true)` | `text.format_int(255, base: 16, upper: true)` |
| `excerpt(s, 9, false)` | `excerpt(s, width: 9, ellipsis: false)` |
| `Map[Static, Int].new(16)` | `Map[Static, Int].new(capacity: 16)` |
| `DateTime.new(2024, 3, 10, 14, 30)` | `DateTime.new(2024, 3, 10, hour: 14, minute: 30)` |
| `dt.add(0.5)`, `dt.add(90)` | `dt.add(seconds: 0.5)`, `dt.add(minutes: 1, seconds: 30)` |
| `Time.new(8, 7, 3, 500)` | `Time.new(8, 7, 3, ns: 500)` |

Every right-hand line reads better. The last row is the clearest case:
`Time.new(8, 7, 3, 500)` printed `08:07:03.0000005`. A reader who took
500 for milliseconds would have been wrong, and nothing on the left
says so. The cost is a few words, and they are words a reader wants
anyway. I found no line where the named form reads as ceremony.

## 1. Does it fit Rig?

**It fits the grain Rig already has.** Rig constructs objects by name, and
positions are allowed only where they can't mislead (`p7.rig`):

```
error: a type with more than one field sets them by name: `Point(x: ...)`
```

Patterns bind fields by name, and so do several results. Functions are the
one place where `f(3, 2, true)` still compiles. The rule brings calls into
line with construction. Since a defaulted field is always named in a
constructor, a defaulted parameter would now be named the same way.

**It is the mantras applied:**
- *Dissolve, don't solve.* A misplaced option stops being something to
  detect and can no longer be written.
- *The language gains a general feature, never a special case* (DESIGN,
  "Substrate"). Today `ArgCheck`'s `by_name`, `calendar_add` and
  `duration_add`, and the "no positional" parts of the round checks, are
  std-only, keyed on a module name and a method name, and refused in
  generic code. The rule turns them into one law for everyone. But that
  happens **only without the exemption** (below).
- *Names say what a value is.* An option's name is its meaning.
- *Shorter and plainer than idiomatic Rust.* Compare
  `Map.new(capacity: 16)` with `HashMap::with_capacity(16)`, or
  `dt.add(seconds: 0.5)` with Jiff's
  `dt.checked_add(SignedDuration::from_millis(500))`.

**It is easy to teach.** It fits the way Rig picks a form with a first
word (`fun` or `sub`, brackets or parentheses). The declaration decides:
a parameter is an operand (no default, passed by position) or an option
(a default, passed by name). docs/learn has no lesson on defaults or
keyword arguments today. This rule is a one-paragraph lesson for
00-welcome.

### The exemption: I side with the designer, for a teaching reason

The owner's form needs a footnote: "...except the first, not counting
self." That is Swift 1 and 2's rule, and SE-0046 removed it from Swift
because users couldn't predict it. It also leaves the holes open:

- `p1.rig`: `dt.add(1)` is accepted and means one *second*. The doc
  comment has to warn that "a bare number is seconds, never days".
  `date.add(1)` is refused today only by `calendar_add`.
- `p5.rig`: a user function made only of options,
  `window(width = 80, height = 24, ...)`, accepts `window(24)` and
  prints `24 24`. That is the `connect(host, 30, true)` shape again, just
  without the host. Option bags are exactly where the rule matters most,
  and the exemption exempts them.

**What dropping it costs, honestly.** The std declarations whose first
parameter has a default are:

- `capacity` on `Map`, `Set`, `HashMap`, `HashSet`, `shared.Map` and Trig's
  `HashSet`;
- `CharBreak.new(tailored)` and `term.dump(history)`;
- the datetime `add`, `with`, `round` and `floor` methods.

The positional uses I found are `Set.new(N)` in Trig
(src/core/nodemodules.rig:105, which the designer missed), three
`Map/HashMap/HashSet.new(5000000000)` in tests, `CharBreak.new(true)` in
std/terminal.rig:731, and about 18 `dt.add(n)` sites. That is a few dozen
mechanical edits, and each one reads better afterwards.

- `z.add(0.5)`: when `z` is a `DateTime`, this becomes
  `z.add(seconds: 0.5)`, which is better. When `z` is a `Time`, an
  `Instant`, a `Monotonic` or a `Duration`, `d` is required, so the call
  is unchanged.
- `Map.new(16)` becomes `Map.new(capacity: 16)`. That is clearer, and it
  is what Swift writes (`minimumCapacity:`).

**What will annoy people.** A Python habit,
`fun greet(name: Static = "world")` called as `greet("Ann")`, is refused.
That is the first thing a newcomer hits, so the diagnostic must teach and
not merely refuse: "`name` has a default, so it is an option, given by
name: `greet(name: "Ann")`. To pass it by position, remove the default."
Library authors will also find that an operand which "might as well
default" (`s.split(sep = " ")`) is better as two functions. That is
Rig's naming rule anyway ("the name says which end and which unit").

**If the owner wants to keep `Map.new(16)`,** a better exemption than
"first" is **"a function's only parameter"**. It mirrors the one-field
object (`Meters(3.5)`) and still closes every datetime hole, since those
methods all take several parameters. But it lets through
`CharBreak.new(true)`, `dump(false)` and `window(24)` once `window` has
one parameter, and it is still a footnote. My preference is no
exemption.

### Brittleness

- Adding a default to a parameter later breaks positional callers. The
  break is loud and comes with an exact fix. I count that as a feature:
  the parameter has changed from operand to option, and every caller
  hears about it. After 1.0 it is a breaking change, and the owner should
  know that.
- Defaulted names become API. Review the 29 plus the first-parameter
  names before landing. `d` in `DateTime.add(d: ...)` is weak:
  `dt.add(d: span)` reads badly. Either rely on unit keywords
  (`hours: 2`) or rename it (`by:`).
- A duration form's unit keyword (`seconds: 0.5`) must count as naming the
  `Duration` parameter. Say so in SPEC.
- `p6.rig`: `mid(a, b = 2, c)` is accepted today. Under the rule `c`
  could only be given by name. Refuse that declaration unless the late
  parameter takes a function (a trailing closure).
- `p3.rig`: `_: Bool = false` (SYNTAX §11's own example) is accepted
  today and can be passed as `_: true`. Under the rule that is the only
  way to pass it. Refuse a default on `_`, and fix the SYNTAX example.
- `p2.rig`: `repeat(|i| ...)` with `times = 1` fails today because the
  closure fills `times`. Under the rule a trailing closure should fill
  the open function parameter, never a defaulted one. That needs the
  no-exemption form.
- Function values carry no names, so calls through them stay positional
  (`p4.rig`: `g(3, 4)`). That is consistent. A generic body may already
  use keywords (`p4.rig`).

## 2. Company

It is in good company and not basically Swift. OCaml's `?opt` is labeled
with no exemption. Zig's options struct (`.{ .timeout = 30 }`) is the same
idea without the struct. Dart's `{}`, Python's `*` (stdlib practice
converging there), Ruby 3 keywords and Kotlin/C# lint culture all point
the same way. Swift labels everything; Rig labels only options and has no
overloading. The only Swift-like part is the exemption, and Swift dropped
that.

## 3. Landing

One PR, no warning stage. The named form is valid today, so:

1. Migrate std, tests, docs, Trig and loco first, each in its own repo,
   with a script driven by the compiler's diagnostics, not by regex.
2. Land the rule and delete the positional parts of `ArgCheck` in the same
   PR.

Add an "Upgrading" entry to the CHANGELOG and a section in
MIGRATING-0.3. SYNTAX §11's `scaled(3, 2)` becomes a reject case. Add the
lesson to docs/learn.

## 4. `Time.new` and `DateTime.new`

Split along the type's structure:

- `Time.new(hour, minute, second, ns = 0)`, so `Time.new(8, 7, 0)` and
  `Time.new(8, 7, 3, ns: 500)`. The `ns:` label fixes the real misreading
  shown above.
- `DateTime.new(year, month, day, hour = 0, ...)` keeps its defaults,
  named: `DateTime.new(2024, 3, 10, hour: 14, minute: 30)`. It mirrors
  `dt.with(hour:)`, and `date.at(Time.new(14, 30, 0)!)` exists for those
  who want positions.
- Not Jiff's "drop every default": seven bare integers is the shape the
  rule exists to stop.

## 5. Verdict

**Adopt, with changes:**

1. No first-parameter exemption. If one must stay, make it "the only
   parameter".
2. A diagnostic that teaches the operand/option split.
3. Refuse a default on `_`, and refuse a required parameter after a
   defaulted one (unless it takes a function).
4. A trailing closure fills the function parameter.
5. Review the defaulted names, which become API (rename `d`).
6. Delete `ArgCheck`'s positional checks in the same PR.
