# Keyword-only defaults: the practitioner's report

I write Rust, Zig, Swift and Go every week, and I read this as someone who
would write Rig every day. I read the brief, SPEC "Functions" and
"Durations", SYNTAX §11, the std declarations, `summary-raw.txt`,
`designer.md` and `evangelist.md`. The programs are in `practitioner/`,
next to this file. Each one is written both ways and run with today's
`~/Data/Code/rig/bin/rig run`:

| File | What it is |
|---|---|
| `client_v1.rig`, `client_v2.rig` | an HTTP-ish `request(url, timeout: Duration? = none, retries = 3, follow = true)`, then v2 of the library inserts a parameter |
| `cli_pos.rig`, `cli_named.rig` | a hexdump-style CLI: an all-options `opts(...)`, `format_int`, `parse_int` |
| `dates_today.rig`, `dates_named.rig` | a billing schedule: `DateTime.new`, `add`, `Time.new`, a `Duration` value |

`rig-kw` only logs; it does not enforce the rule. So the refused forms
below are inferred from the rule as worded, and I didn't run them. Every
named form I show compiles and runs today, with the same output.

## What the programs showed

**1. Silent breakage when a library evolves (`client_v1` to `client_v2`).**
v2 inserts `connect: Int = 5` before `retries`. The positional caller
`request("/a", 30, 2)` still compiles. Its `2` now lands on `connect`, and
`retries` goes back to 3 without any notice:

```
/a timeout 30s connect 2 retries 3 follow true   # positional caller, wrong
/a timeout 30s connect 5 retries 2 follow true   # named caller, right
```

This is the bug I have actually shipped in Python and Kotlin. Rust, Go and
Zig dodge it only by breaking every caller on any signature change, or by
pushing options into a struct. Under the rule, adding or reordering
options is always safe. That is the property Zig's `.{ .timeout = 30 }`
and Rust's `..Default::default()` give, without declaring a struct. To me
this matters more than readability.

**2. A swapped argument compiles.** `request("/b", 2, 30)` gives a 2 s
timeout and 30 retries, because a bare number fills a `Duration` as
seconds. Under the rule it is refused.

**3. Positional calls make you restate defaults.** To reach `dry_run`, I
had to write `opts(8, 16, false, true, true)`, repeating `base` 16 and
`color` true. A restated default pins the old value: if the library later
changes its default, this caller silently keeps the old one. Trig's 22
`base: 10` arguments are the same thing. The named form
`opts(width: 8, dry_run: true)` says only what differs.

**4. The first-parameter exemption keeps a real bug.** `start.add(30)` on
a `DateTime` printed `09:30:30`, which is 30 *seconds*. Anyone who meant
days gets no warning. `d` is `add`'s first parameter and has a default,
so the owner's wording still accepts this call. Without the exemption it
is refused, and `start.add(days: 30)` printed `2024-03-01T09:30:00`. In
the same way `Time.new(8, 7, 3, 500)` printed `.0000005`: 500 ns, not
500 ms. `ns: 500` fixes that.

**5. All-options functions are where the exemption hurts most.** With
`opts(width = 16, base = 16, ...)`, the exemption accepts `opts(8)`. It
also turns prepending a new first option into a silent shift for every
`opts(8)` caller. That is example 1 again, through the exemption.

## Where it annoys me (the real costs)

- **A `Duration` value given to `DateTime.add` needs `d:`.**
  `start.add(d: grace)`, while `Time`, `Instant`, `Monotonic` and
  `Duration` all take `x.add(grace)`, because their `d` is required. I
  switch between these types all day, and this inconsistency would trip
  me weekly. Unit keywords cover literals (`add(hours: 36)`), so only a
  `Duration` *value* pays. It is the only place in my three programs
  where the named form read worse. Fix: rename `d` before names become
  API (`by:`?), or accept `d:`. I would **not** add a "`Duration` value by
  position" exemption yet, because it is a second, type-based rule.
- **A unit keyword hides the option's name.** `request(url, seconds: 30)`
  satisfies the rule, but the reader no longer sees `timeout`. `timeout:
  30` works today. Recommend it in the docs for user functions whose
  `Duration` is an option, not the operand.
- **Forwarding stutters.** A wrapper must write
  `request(url, timeout: timeout, retries: retries)`. This already exists:
  `x: x` appears 650 times in `trig/src` and 42 times in std. OCaml (`~x`)
  and Ruby 3.1 (`f(x:)`) added punning because their labels are
  mandatory. It is not needed now, but expect the request.
- **Enum literals are redundant.** `Logger.new(level: .debug)` and loco's
  `interp: .rip`. Swift lives with this. It costs a little and is never
  wrong.
- **Adding a default to a required parameter breaks callers.** That is
  the same as in Zig (moving a field into the options struct) and in Go
  and Rust (any signature change). It is fine for me. Swift, Kotlin and
  Python users will be surprised.
- **Named arguments don't replace an options object.** A CLI that parses
  flags once and hands them to several functions still wants `obj Opts`.
  Zig's `.{}` can be built once and passed along; keyword arguments can't
  be. They complement each other, and Rig needs no change.

Code review is the strongest argument: a GitHub diff has no
rust-analyzer or IntelliJ inlay hints. `connect(host, 30, true)` is
unreadable in review in every language that allows it. This rule puts the
hint in the source.

## Answers

1. **Good.** It fits Rig: refused, not linted; no new syntax; it deletes
   std-only checks. Its brittleness is all loud, and the silent kinds go
   away. Interactions are clean if a trailing closure fills the open
   function parameter by type (`repeat(|i| ...)` fails today).
   Function values stay positional, which is correct.
2. **Good company.** It is not Swift: only options are labeled, and
   labels never select an overload. It is OCaml's `?opt`, or Zig's
   options struct without the struct. A Go, Rust or Zig programmer gets
   options that evolve safely. A Swift programmer gets fewer labels than
   at home.
3. **Worth it.** It is 326 mechanical sites, and the named form is valid
   today. Migrate std, tests, docs, Trig and loco first, then land the
   rule and the `ArgCheck` deletions in one PR. No warning stage is
   needed. Add a CHANGELOG "Upgrading" note, driven by the compiler's
   diagnostics.
4. **`Time.new(hour, minute, second, ns = 0)`, and `DateTime.new` with a
   positional date and a named clock** (`DateTime.new(2024, 3, 10, hour:
   14, minute: 30)`). I agree with the panel's shape, but for a different
   reason. Nobody confuses hour with minute. The datetime bugs I have seen
   are units (`add(30)`, ns read as ms) and month/day order. The rule
   fixes the first two, and nothing fixes month/day. The clock parts are
   named because they are skippable options, not because naming them
   catches a bug. The mixed spelling, `Time.new(14, 30, 0)` against
   `hour: 14`, is a small blemish worth accepting. Don't drop every
   default: seven bare ints is `connect(host, 30, true)` again.
5. **Adopt, without the first-parameter exemption.** I reached this from
   examples 4 and 5, independently of the other two panelists. I would
   also reject the evangelist's "only parameter" fallback (`term.dump(false)`).
   The owner should know:
   - `dt.add(d: span)` is the one daily papercut, so rename `d` now.
   - Defaulted names become API.
   - Unit keywords can hide an option's name.
