# Closures that capture a field path

Status: a design note for the owner. Nothing is built. Read on main
3e3a88b02.

## The problem

A capture names a local only. To lend a closure one field of an object,
the field is bound first:

```rig fragment
obj RenderState
  cache: Map[String, String]
  template: String

  fun render(!@, name: ?String) -> String
    t = ?@template
    +(!@cache).ensure_with(String(name), |?t, k| fill(t, k))
```

Capturing the whole object is rejected, rightly, since `@cache` is lent
to write: "cannot lend `state.cache` to write while a read loan on
`state` is live". Writing the field in the list is a parse error today:
`|?@template, k|` gives "unexpected `.`; expected `,` or `|`".

The extra line is the same kind of line as Rust's `&mut *guard`
reborrow, which the LWN article on "Beyond the &" names as a cost of
Rust's learning curve. It shows up exactly in the common `Map` entry
idiom (`ensure_with` from a method), and in any closure that reads one
field while another is being changed.

The inconsistency is the real point. In an expression a sigil already
reaches into a place (SYNTAX §11: `+p.a` clones the handle in a field,
`<p.f` takes an optional field, `?xs[0]` lends an element), and the
ownership checker already treats `p.a` and `p.b` as separate places
(CORE rule 5). Only the capture list stops at a name.

## What other languages do

- **Rust 2021** infers precise captures (RFC 2229): `|| s.template.len()`
  captures `&s.template` alone, with nothing written. Rig keeps captures
  explicit, so the path has to be written.
- **C++** init-captures name a new variable: `[&t = s.tmpl]`.
- **Swift** capture lists do the same: `[t = self.template]`.

Rig wants neither inference (captures stay visible) nor a new
`name = value` form inside the bars (punctuation doing a keyword's
job). Writing the place itself, with the sigil it would take in an
expression, needs neither.

## The rule

A capture is a sigil and a **place**: a local, `@`, or either followed by
`.field` steps. It means what the same sigil means in an expression,
evaluated where the closure is made, and inside the body the place
names the capture.

```rig pending
obj RenderState
  cache: Map[String, String]
  template: String

  fun render(!@, name: ?String) -> String
    +(!@cache).ensure_with(String(name), |?@template, k| fill(@template, k))
```

It desugars as `|!x|` already does (SPEC §11: "`|!x|` is `w = !x`
followed by `|<w|`"): `|?p.a, k| body` is `w = ?p.a` followed by
`|<w, k| body`, with `p.a` written for `w` in the body. The lend is
made at the closure literal, as every capture is, never hoisted out of
the statement, so a closure in a `while` condition lends its field per
evaluation, as it does now.

What follows:

- The loan is on the place `p.a` (CORE rule 5), lasting while the
  closure lives. `p.b` stays free to lend to write; `p` and `p.a` do
  not. The ownership checker already lends sub-paths
  (`lendVar(id, path, ...)` in `src/ownership.zig` takes the path).
- Inside the body, `p.a` and anything below it (`p.a.len`) reach the
  capture. `p` alone and its other fields do not: the closure captured
  `p.a`, not `p`.
- Each sigil works on a place exactly where the same expression does:
  `?p.a`, `!p.a`, `+p.a` (a copy, a clone of a handle, or a deep copy),
  `~p.h` (a weak handle of a handle in a field), `<p.f` (take an
  optional field, leaving `none`). One rule, no table of its own.
- An owned closure (`*|...|`) follows its existing rule: owners,
  handles, and plain data, never a view, so `*|+@limit|` works and
  `*|?@template|` is rejected as `*|?t|` is today.

## Decisions (default first)

1. **Allow a field path in a capture:** `|?p.a|`, `|?@template|`. [yes]
   Reason: a sigil already reaches into a place in an expression; the
   capture list is the one place it does not.
2. **The place names the capture in the body:** `@template`, `p.a.len`.
   [yes] Alternatives: a new name (`|t = ?@template|`, punctuation
   doing a keyword's job) [no]; the last step as a bare name
   (`template`, a name the reader never sees declared) [no].
3. **Which places:** a local or `@`, then `.field` steps. No index
   (`|?xs[i]|`), no call, no unwrap. [yes] Reason: `xs[i]` in the body
   would read as the live element while `i` was fixed at creation.
   Lend the element first: `x = ?xs[i]`, then `|?x|`.
4. **Which sigils:** each, where the same expression is allowed. [yes]
   Alternative: only `?` and `!`, the two the problem needs.
5. **Overlap:** two captures in one list where one holds the other are
   rejected (`|?p, !p.a|`); disjoint ones are fine
   (`|?@template, !@stats|`). [yes]
6. **CORE §7** changes one phrase: "A closure captures each name with a
   sigil" becomes "each name or field path". [the CORE process, kept
   small: one reviewer and your final pass, since the rule only lets an
   existing lend name a sub-place] Alternative: the full 4–7 expert
   round.

## Diagnostics

| Case | Message |
|---|---|
| the body uses the root | "the closure captured `@template`, not `@`: capture `?@cache` too, or `?@`" |
| the body uses another field | "the closure captured `p.a`, not `p.b`: capture `?p.b` too" |
| overlap in one list | "`p.a` is inside `p`, which this closure already captures" |
| an index or call | "a capture names a local or a field of one, not an element: lend it first, `x = ?xs[i]`, and capture `?x`" |
| outside conflicts | today's messages, with the place: "cannot lend `p.a` to write while a read loan on `p.a` is live" |

## Tests that define it (all fail today)

In `test/rig/closures.rig.test`:

- `render_page` from a method: `(!@cache).ensure_with(..., |?@template, k| fill(@template, k))`, twice, one entry
- a local path: `f = |?p.a| p.a.len`, then `!p.b.push(3)`, then `print(f(), p.b.len)` gives `0 1`
- `|!p.a|` writing through while `p.b` is read
- `|+p.n|` copies a field; `|~p.h|` holds a field's handle weakly; `|<p.f|` takes an optional field
- an owned closure `*|+@limit|` stored and called after the method returns
- rejections: the body uses `p`; the body uses `p.b`; `|?p, ?p.a|`;
  `|?xs[0]|`; `!p.a` while a `|?p.a|` closure is live; `*|?p.a|`
- the oracle: a grid row for a path capture in every mode, so its
  rejections match the compiler's

## Where it is built

| Pass | Change |
|---|---|
| `rig.grammar` | a `barent` takes a sigil and a place (`name` then `.name` steps); the `cap_*` nodes take a path. Nexus keeps a copy of the grammar: tell its session |
| `src/rig.zig` | the Parser wrapper's split of a bar list keeps the path |
| `src/resolve.zig` | in the body, a member chain that starts with a captured place resolves to the capture, and its root alone does not |
| `src/typecheck.zig` | `checkCapture`: the place's type, the sigil's rules, the task rules (SPEC §18) on that type |
| `src/ownership.zig` | `applyCapture`: `lendVar` with the path in place of `whole_path`; overlap in one list |
| `src/emit.zig` | `captureInfo` and `emitCaptureInit` initialize the environment's field from the place; the body's references are already the capture's |
| `test/oracle/` | the oracle learns the path capture from the CORE phrase |
| docs | SYNTAX §11's capture table, SPEC §11's table and an example, CORE §7's phrase, CHANGELOG |

About 2–3 days with the docs. It rejects nothing a release accepted, so
Trig needs no migration, and it changes no emitted code for closures
that capture names.

## Is it worth it?

The gain is one line where it appears, so the case rests on
consistency more than on lines saved: a sigil means one thing and
reaches into a place everywhere but here. It also lets Rig's version of
the article's example read as the Rust one does after a year of
language work, with the capture still visible in the bar list.

---
Approved by the owner on 2026-10-21: "Approve the six defaults in the closure field-path capture note."
