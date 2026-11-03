# Round 2 synthesis: the one-armed match (Swiss, 2026-11-02)

All three experts (Rust, Ruby, Swift) reached the same form independently:

    if <entry.state is .ready(rendered?)
      !@retired.push(<rendered.image)

and the full match it abbreviates:

    match <entry.state
      .ready(rendered?) => !@retired.push(<rendered.image)
      _ => pass

Same subject, same pattern, same body; `is` replaces `match` + `_ => pass`.

Decisions (defaults):
1. `is` tests a pattern: `x is P`. Bool anywhere when it binds nothing (covers filter's matches!);
   binds names only in if/while conditions. Alternative word: `matches`. Default `is`.
2. `as` keeps naming only (`if o as x`, several results, `use m as n`); `x as .p` rejected with
   "write `x is .p`". Migration: ~36-87 lines of Rig tests/docs, 0 in Trig (one Trig local named
   `is`, printer.rig:1664, renamed).
3. Nested patterns, staged: `name?` (the value inside, or no match) and `none` first, so `match` on
   an optional works and `rendered?` needs no second `as`; `.variant(...)` inside a payload later.
   Checker cost: nested exhaustiveness (Rust's matrix algorithm). Nexus grammar diff: no conflicts.
4. One `<` on the subject sets how every binding is held; no sigils inside patterns.
5. Diagnostic fix: when a binding is owned, offer `<` before `+`.

Build order (one language feature at a time): patterns (`is`, `?`, `none`) first, then the approved
fused iterator chains with `min_by(key)`, `max_by(key)`, using `is` in `filter`.

Reports: rust2.md, ruby2.md, swift2.md (+ rust2-grammar.diff, rust2-today.rig).
