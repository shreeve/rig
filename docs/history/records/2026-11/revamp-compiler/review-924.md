# Review: PR #924 (rv-ternary), a ternary's condition binds names

Verdict: nothing serious. No soundness, ownership, or meaning change found
in programs main accepts. Three small issues, all in programs main already
rejected.

Method: about 24 probes in $TMPDIR/r924, each run with main
(d4cbc8f58) and with the branch under RIG_SANITIZE=1. Emit compared where
main accepts. `swarm test/rig.rip types-optional` passes.

## What holds

- **Wider visibility (`Symbol.declaredAfter`).** Every `as` and pattern
  binding goes through `bindFresh`, which rejects a shadow of any visible
  local or module declaration. Typecheck enters each `as` scope after
  checking its value, as the resolver does. So the only code positioned
  before a binding in its own scope is the ternary's value. Checked: loops,
  chain `for`s, `match` arms and guards, `while` steps, closures, and module
  names (p19: emit identical to main). A binding is unbound in each of
  these places, as the rule requires:
  - the `else` value, including a nested ternary's `else` (p16)
  - after the expression and in a sibling ternary (p16)
  - an arm guard's body (p24)
  - a loop body after the expression (p24)
  - a `while` body whose condition holds the ternary (p24)
- **Ownership.** All of these behave correctly, sanitizer-clean:
  - drops of owned temporaries: `as _`; `as x, y`; a failed `and` part; a
    nested ternary; a ternary in a loop (p8)
  - moves out with `<r`, `<n`, and `<s matches` (p11, p23)
  - write and read views of the same place are rejected (p3)
  - a view of a temporary is rejected when it escapes by assignment, return,
    or closure (p4, p5, p10, p13, p14, p22)
  - a map loan stays live after the ternary (p7)
- **Lexer.** Token changes happen only on lines main rejected (`f(a if g()
  as a, b else 0)`, the same in a list, across a newline inside brackets).
  Block `if ... as a, b:` lines and guard lines are unchanged.

## Issues

1. **Low: a ternary in statement position is called a "postfix guard".**
   At src/typecheck.zig:2486-2489, `print(v) if get(1) as v else print(0)`
   is rejected with "a postfix guard binds no names". Main accepts
   `print(1) if c else print(2)`, so this form is a ternary with an `else`,
   not a guard. Probe p15.
   Fix: add `else_node == .nil` to the guard test, so the form binds as the
   rule says, with a case. Or, if the owner wants it rejected, give it its
   own message: "a ternary used as a statement binds no names; write an
   `if` block".

2. **Low (existing before this PR, now easier to reach): `as a, b` shadows
   an outer local silently.** The PR body notes this. src/rig.zig:4088
   makes each name a `.shadow` set, so src/resolve.zig:1146-1153 never calls
   `checkShadowing`. A ternary now makes this easy to write: with an outer
   `a = 50`, `x = a + b if pair(3) as a, b else a` prints `9 50`, so one
   expression uses `a` for two different values. Probes p20 and p21.
   Fix: call `checkShadowing(ir.Set.target(n), "result binding")` for each
   name in the `as_results` branch of `part`. This rejects programs main
   accepted, so it needs a note for Trig and an entry in the release notes.
   It can be a separate change.

3. **Nit: messages.**
   - `x = [a if g() as a, b if c else 0]`: main said "a postfix `if` guard
     must end a statement; write `a if c else b`". The branch says
     "unexpected `,`; expected `else` or `or`" (p17). `elseFollows`
     continues past the names and finds the second ternary's `else`. This
     is an edge case and either message rejects the line.
   - `print("big") if s matches .circle(r) and r > 2`: the statement never
     uses `r`, yet the message says "write an `if` block, whose body sees
     them" (p2). A plain `b = s matches .circle(r) and r > 2` is accepted.
     The message could instead say "a postfix guard's condition binds no
     names".
