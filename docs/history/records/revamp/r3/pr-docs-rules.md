State three rules a newcomer meets early

A newcomer review stumbled on three rules that the compiler already
enforces but the docs never stated plainly. Each is now stated once,
where a reader meets it, with a tested example. Docs only: no change
to `src/`, `docs/CORE.md`, or SPEC.

- **Prefix vs suffix sigils.** WELCOME's first section now says a
  prefix sigil is how you hold a value and a suffix `?`/`!` is control
  flow, that Rig has no `!` for "not", and how to read `S?!`, `?D?`,
  and `(?D)?`, with a runnable `!v.pop()` / `while not done` example.
  SYNTAX §5 cross-references it, and SYNTAX §7 adds the `S?!` and
  `(?S)?` reading. The WELCOME habit example now quotes the `not`
  diagnostic in full.
- **Closure bars.** SYNTAX's closure section and WELCOME's closure tour
  say a name with a sigil is a capture and a bare name a parameter,
  that captures come first, and that a parameter may not reuse a
  local's name, with a `rig reject` example quoting the compiler's
  error for `|n|` beside a local `n`.
- **No implicit shadowing.** WELCOME's "From Rust and Zig" states the
  principle (locals, closure parameters, generic parameters; `new`
  shadows on purpose; Zig has the same rule), points to SPEC §4, and
  rejects the `test/corpus/audit-emit-hh4.rig` program with its error.

Tests: `./test/run doc vocab`: 327 passed, 0 failed, 0 known, 4 pending
(the pending ones are CORE's existing examples).
