# Panel brief: the keyword-only rule

Rig is a language that compiles to Zig 0.17. North Star: **a program the
compiler accepts is correct**, and **effects stay visible**. The repo is
`~/Data/Code/rig` (main e38454865): read `AGENTS.md`, SPEC's calls section
(search "A call passes arguments by position, by keyword, or both", and
"closure written as a call's last argument"), and `docs/SYNTAX.md` §11
(calls). Run programs with `~/Data/Code/rig/bin/rig run FILE`. Read only: don't
edit, commit or push.

## The proposal (the owner's idea)

> **A parameter that has a default value, other than the first parameter, can
> only be given by name at the call.** (A method's self doesn't count.)

```rig
fun scaled(n: Int, by: Int = 10) -> Int
scaled(3)          # ok
scaled(3, by: 2)   # ok
scaled(3, 2)       # refused: "write `by: 2`"
z.add(0.5)         # ok: the first parameter, even with a default
```

Today any parameter may be given by position or name. The aim: an optional
argument's meaning is always on the page at the call (`connect(host, timeout:
30, retry: true)`, never `connect(host, 30, true)`), so misplaced optional
arguments can't compile. It would also replace most of the datetime library's
special compiler checks (`dt.add(1, 2)` refused, a positional `with`), which
today work only for std, are refused in generic code, and can't protect user
code.

## What was measured (a temporary compiler patch, nothing committed)

In `/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/kwonly/`
(`calls.tsv`, `summary-raw.txt`, `std-decls.txt`, `raw.log`):
- **326 call sites (534 arguments)** would change: Rig's tests 223, Trig 52,
  loco 25, std 10, docs 9, tools 6, bench 1. No function-value cases; no calls
  in generic bodies (they pass every argument by position today, and none hit);
  API methods can't declare defaults today.
- All are in a trailing run of defaulted parameters, so a script inserts
  `name: ` mechanically.
- 174 of the 326 are `Time.new(hour, minute, second = 0, ns = 0)` and
  `DateTime.new(year, month, day, hour = 0, ...)`: `Time.new(8, 7, 3)` would
  become `Time.new(8, 7, second: 3)`. The proposed fix is to drop those defaults
  so every part is given in order, as Jiff's `time(h, m, s, ns)` does.
- Where the name helps: bare booleans (Trig's `Parser.new(..., false)`, loco's
  `kind(..., true, false, .rip)`); `base: 16`; 22 of Trig's 33 base arguments
  pass the default 10 and could be dropped.
- 29 std declarations have a defaulted non-first parameter.
- Emitted Zig is unchanged (arguments still go to Zig by position, defaults
  filled at the call), so no run-time cost.
- Earlier panel notes (`~/.../scratchpad/edges/call-syntax.md`,
  `ergonomics.md`, `rust-zig.md`) discussed a `;` marker instead of a rule; the
  owner preferred a rule with no new syntax.

## Questions

1. Is it good? Does it fit Rig's ethos (correctness, visible effects, small,
   no ceremony)? Is it clean, or brittle (e.g. adding a default to an existing
   parameter later breaks callers; a first parameter that later gains a default;
   evolution of library APIs; interaction with trailing closures, generics,
   APIs, function values, overloading-free design)?
2. How far is it from other languages? Rust (no named arguments), Zig (no named
   arguments; options structs `.{ .timeout = 30 }`), Swift (labels by default,
   `_` to opt out; Swift 1 and 2 exempted the first argument), Python
   (keyword-only after `*`), Kotlin and C# (named optional, never required),
   OCaml (`~label`), Ruby (keyword arguments), Dart (`{}` named). Is this "off
   the reservation" or in good company? Is it basically Swift?
3. Is the breaking change worth it, and how should it land (migration script,
   CHANGELOG "Upgrading", Trig and loco patches, one PR or staged with a
   warning first)?
4. The `Time.new`/`DateTime.new` question: drop their defaults, keep them
   (named form), or something better.
5. Your verdict: adopt, adopt with changes, or reject; and anything the owner
   should know.

Write your full report to your file in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/kwonly/`
(name given in your prompt). Return at most 400 words: your answers to 1 to 5.
