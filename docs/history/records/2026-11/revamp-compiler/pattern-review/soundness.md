# Pattern rules: soundness review

Reviewer angle: soundness, ownership, "accept means correct".
Rig under test: `.git/rig-baseline/dd355f669…/rig` (main at #926). Citations are to
the docs at that commit (copies in `soundness/SPEC-base.md`, `matches-base.md`,
`CORE-base.md`). Probes: `soundness/p*.rig` and `soundness/forms/*.rig`; runner
`soundness/run.sh` (check, then debug, `--release`, `RIG_SANITIZE=1`, outputs compared).

## Verdict

The ownership model holds. I found no memory error: every probe that runs gives
identical output in debug, release, and sanitize, with no leak and no crash, and the
ownership checker rejects every misuse I tried. But "accept means correct" fails in
four places. Each is a binding alternatives list, or a `name?` inside one, that
`rig check` accepts and the emitted Zig does not compile. Two of them hit the most
natural uses of rule (4). One more, a drop-timing difference, breaks rule (5)'s
"same in `if` and `match`". Fix those four before freezing rule (4).

The eight scenarios in `shapes.rig` run identically in all three modes.

## Findings

### F1 (high): alternatives that cover every variant: Zig error
- Probes: `p31c_arm_cover_all.rig`, `p31i_match_cover_all_consume.rig`, `p31a_alts_cover_all.rig`, `p31e`.
- Code: `enum S { a(n: Int), b(n: Int) }`, `match s` / `.a(n), .b(n) => print(n)`.
  This is the textbook case for rule (4), and an exhaustive `match`.
- Observed: `rig check` accepts it. Zig fails with `unreachable else prong; all cases already handled`.
  The binding switch is `switch (tag) { .a => …, .b => …, else => unreachable }`.
  The same failure happens under `match <s` and in `if s matches (.a(n), .b(n))`.
- Expected: it runs. As an `if` or Bool test it either runs or is rejected the way a
  one-variant enum is.
- Citation: AGENTS North Star 1. SPEC §match (base l.6531) allows binding alternatives.
- Related (low): with no names bound, `if s matches (.a(_), .b)` and the Bool
  `s matches (.a, .b)` are rejected, but with "this arm never runs: the arms before it
  cover every value". That points at the hidden `_ => false` arm the lowering adds.
  The one-variant rule has a clear message ("`.only` is the only variant … always
  holds"); full-cover alternatives need the same.

### F2 (high): `name?` inside binding alternatives: Zig error
- Probes: `p11b`, `p11c_arm_mixed`, `p11e`, `p12a`, `p12b`, `p12c`, `p30b`, `p30c`, `p10a`, `p10b`.
- Code: `s matches (.a(t?), .b(t))` with `a(t: String?)` and `b(t: String)`. Also
  `(.a(t?), .b(t?))`, and the arm form `.a(t?), .b(t) =>`.
- Observed: the checker gives `t` the type `String`, but emit binds the field
  without unwrapping it: `const t = switch (s) { .a => s.a.t.bytes(), … }` on a
  `?String`. Zig rejects this for String, List, objects, Int arithmetic, and `!s`
  write views. `<s` works (`p30a`, `p12d`).
- `p11a` with `Int?` and `print(n)` happens to compile only because `print` takes a
  Zig `?i64`.
- Expected: `t` is the unwrapped value, as in the single-pattern `.a(t?)`, which works.
- Citation: North Star 1. SPEC §12, `name?` (base l.10891); rule (4).

### F3 (high): error alternatives that bind: accepted in `if`, `while`, ternary
- Probes: `forms/errbind_{if,while,tern}.rig`, `p28b`, `p28d`.
- Observed: `e matches (.bad(n), .worse(n))` in an `if`, `while`, or ternary
  condition passes `rig check`. Zig fails with `cannot capture tag of non-union type 'error{…}'`.
  The arm and Bool forms are rejected correctly: "alternatives of an error bind no names".
- Expected: the same rejection in every form.
- Citation: SPEC §match "Alternatives of an error bind none" (base l.6533); rule (5).

### F4 (high): an unread name in binding alternatives: Zig error
- Probes: `p22a`, `p22d`, `p22g_unused_arm_alt`, `p22i`, `p29a`, `p21b`.
- Observed: `if/while e matches (.left(v), .right(v))`, a ternary, or a `match` arm
  `.left(v), .right(v) => 1` with `v` unread passes check. Zig fails with
  `unused local constant`. Under `<s` (`p29d`) it compiles and runs.
- Only the Bool form rejects it: "`v` is bound but never read; write `(.left(_), .right(_))`".
- Single patterns are rejected correctly, except in a generic function (`p22c`,
  `p22e`): there an unread single binding is accepted (it compiles) and
  inconsistent (low).
- Citation: SPEC §12 "A name nothing reads is rejected, as anywhere" (base l.10857); North Star 1.

The common cause of F1 to F4 is probably the alternatives path (`altsProng`, the
alternatives check in `resolve.bindPattern`/typecheck). The one-arm `as_match`
lowering skips checks that the arm and Bool paths run, and emit's `inline` prong
assumes plain fields and a partial cover. A case per form (if, while, ternary,
Bool, arm) would catch the class.

### F5 (medium): `<s` with a pattern that binds nothing drops at the header, not the end of the block
- Probes: `p34_bare_vs_underscore.rig`, `p35_drop_timing.rig` (an object with a printing `drop`).
- Observed:
  - `if <s matches .a` and `if <s matches .a(_, _)` drop the whole value before the
    body runs. So do `(.a, .b)`, the ternary form, and `while`.
  - `match <s` / `.a(_, _) =>` drops it after the arm body.
  - With one name bound (`.a(x, _)`), the left-out fields drop after the body.
- Expected: the fields a pattern leaves out drop at the end of the block, in every form.
- Citation: SPEC §12 "Under `<s`, the fields a pattern leaves out drop at the end of
  the block" (base l.10868), "It is a `match` with that one arm" (l.10851);
  matches.md table (l.138, 143).
- Not a memory error, but drop order is observable through `drop(!@)` and through
  resources such as files and locks.

### F6 (low): `return v` of a read binding is rejected; the tail form is accepted
- Probes: `p19a`, `p19b`, `p19f`, `p19h`, and `p19c`, `p19d`, `p19e` for contrast.
- Observed: in `fun get(s: ?S) -> ?String from s`, `if s matches .t(v)` / `return v`
  is rejected with "cannot move out of `v`: it is a view of `s`". `v` as the last
  value, `return ?v`, and a ternary all work.
- Expected: a bare read view copies (CORE sentence 1, "copies plain data and read
  views"), so `return v` is the same as the tail form. At the least, the message
  should offer `return ?v`. The same holds for `match` arms, so it is not specific
  to `matches`.

### F7 (low): diagnostics that leak the lowering or misdirect
- A binding under `not`, `or`, or parentheses, then read later: "`n` is bound but
  never read; write `.a(_)`" (`p04a`, `p04b`, `p04c`, `p26*`). The program does read
  `n`; the problem is that `n` is not bound there. The rejection is correct; the
  text misleads.
- A Bool test of a one-variant enum (`forms/onevar_bool.rig`): "this arm never runs".
- An optional subject in a Bool (`forms/optsubj_bool.rig`): "cannot `match` on a value
  of type `E?`". The `if` form gives the good message ("take the value out first").
- `<s matches` on a view: the message says "`match <s` consumes…" (`p32a`).
- A name twice in one pattern, `.r(a, a)` (`p16e`): "shadows the local `a`" plus
  "never read". It should say "bound twice in one pattern".
- A nested pattern, `.w(.x(k))` (`p13*`): only a parse error ("unexpected `.`"). SPEC
  has no nested patterns. A message that offers `.w(i) and i matches .x(k)` would
  teach the rule.
- `.two(x?, _)` with `.two(none, y?)` (`p08d`): reports a miss of `.two(none, _)`.
  The real miss is `.two(none, none)`.

### F8 (low): docs
- matches.md "Later, not now" still lists coverage across `r?` and `none`. SPEC at
  the base says it is built, and `p08c` confirms it.

## The proposal: reject an all-`_` payload

Ownership is unaffected: `.r` and `.r(_, _)` emit the same test and, today, the
same drops (`p34`). If it lands, these must follow:
- The compiler's own advice suggests all-`_` forms: "write `.a(_)`" and "write
  `(.left(_), .right(_))`". It must suggest `.a` instead.
- SPEC l.10858 `ok = s matches .rect(_, _)`, `(.point, .rect(_, _))`, and SPEC §match
  `.circle(_), .square(_) =>` all change, as do matches.md's examples.
- `.r(h: _)` (accepted, `p16l`) is the same thing by name, and `.c()` on a unit
  variant (accepted, `p16g`) is its twin. Reject both with it.
- `_?` and `none` are tests, not wildcards, and must stay legal: `.o(_?)` is not `.o`.

## What holds (no finding)

- **Read bindings** of String, List, `^T`, an object with a String, and plain data:
  - Owners are views and plain data copies (`p01`).
  - Writes through them are rejected (`p02`).
  - Moving the subject, reassigning it, or lending it to write while a binding
    lives is rejected, also later in the same `and` chain (`p03`, `p05b`, `p09c`).
- **Escapes** into an outer local, a List, a `keeps` call, a closure, or a return
  from a local are rejected: "does not live long enough", "cannot return a view"
  (`p14*`, `p09g`, `p24*`).
- **`!s`**: write views change in place, also through alternatives, boxes,
  objects, and `v = none` (`p07`, `p10f`, `p33`). Reading `s` meanwhile is rejected
  (`p17a`). Moving out of a write view is rejected (`p32e`, `p32f`).
- **`<s`**:
  - The subject is moved, also in `else` (`p17j`) and across loop iterations
    unless reassigned (`p17h`, `p17i`).
  - Every left-out field drops exactly once, with no leak, including under
    alternatives with different positions and `name?`/`none` (`p06`, `p25`, `p23`).
- **Made values** (`mk() matches …`) own their fields. A view of them cannot escape
  (`p14c`, `p14d`, `p14f`, `p14g`), and `while next() matches .item(x)` drops each one (`p05d`, `p05e`, `p27`).
- **Scope**:
  - Names do not reach `else` (`p04d`), past a Bool statement (`p04e`), across
    `or` (`p04j`), or under `not` (`p26*`).
  - They flow through nested `and` (`p04h`) and into the value of a ternary
    (`p04f`, `p04g`, `p09*`).
  - A `while` step cannot read them (`p27a`).
  - Shadowing an outer local is rejected (`p05f`).
- **Rules 2 and 3**: a partial positional pattern, too many fields, an unknown
  field, a field named twice, mixing in order with by name, a duplicate arm, and a
  payload on a unit variant are each rejected, in every form (`p16*`, `forms/mixed_*`).
- **Coverage**: `.o(v?)` plus `.o(none)` covers `.o` (`p08c`). Either alone does not
  (`p08a`, `p08b`), and a guarded arm does not (`p08e`).
- **Same checks in every form**: the one-variant rule, the optional-subject rule,
  and `n?` on a field that is not optional are rejected in if, while, ternary,
  Bool, and arm (`forms/`). Only the message text differs (F7).
- **Other subjects**: a view parameter, a `^T` through `?b` and `!b`, a `*T` read,
  an object field (`o.state`, `!o.state`, `<o.state`, then use after move,
  rejected) all behave (`p18*`). So do text, integer, range, Bool, and symbol
  subjects (`p20*`), and errors in a `catch` without binding alternatives (`p28`).
