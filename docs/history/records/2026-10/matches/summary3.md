# Round 3 synthesis: `matches` (Swiss, 2026-11-02)

Rust and Swift: `|` between alternatives, in `matches` and in match arms. Ruby: keep the comma, parens
inside calls. Swiss sides with `|` everywhere (one spelling, no position rule, nested patterns work).

Trig counts (three independent counts agree): 1,877 hand-written arms, 217-758 list alternatives;
~272-277 `x == .A or x == .B` chains (42-51 re-run a call per test), 43-44 `!=`/`and` chains;
74 one-arm `_ => pass` matches (43 list alternatives, 23-24 bind a payload); 3 sites where a comma
would belong to a surrounding call. So alternatives are the common case; bindings are needed.

Ship:
    if <entry.state matches .ready(rendered?)
      !@retired.push(<rendered.image)
    live = entries.filter(|e| e.value.state matches .ready | .start | .frozen)
    while @token matches .CommaToken | .SemicolonToken
    is_loop = @kind(n) matches .ForStatement | .ForInStatement | .ForOfStatement
    match kind
      .JS | .JSX => ...
      _ => pass

Decisions (defaults):
1. `x matches P`: a Bool anywhere; binds names only in if/while conditions (flowing right through
   `and`); alternatives bind none. Negation follows Rig's comparison rule: `not (x matches .a | .b)`.
2. `|` separates alternatives in `matches` and in match arms; the comma form is rejected with a fix;
   a migration script rewrites arm heads (~250 Trig lines, ~170-245 Rig lines); Trig gets the
   one-line note and script before merge (rejects programs a release accepted).
3. Patterns: nested `name?` and `none` now; `.variant(...)` nested later; `|` nests (`.ready(.done | .cached)`).
4. `as` keeps naming only; `x as .p` rejected with "write `x matches .p`".
5. One `<` on the subject sets every binding's mode; diagnostics offer `<` before `+`.
Build order: patterns (1-5) as one language row, then the approved fused iterator chains with
`min_by(key)`/`max_by(key)`.
Reports: rust3.md, ruby3.md, swift3.md.
