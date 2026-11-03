# Panel C: #688 CORE text and oracle agreement

PR head 9ea69ee13 (param-opt-move), worktree ~/Data/Code/worktrees/rig/panel688c.
Probes: C-probes/*.rig; before.txt (bin/rig of main checkout, Oct 24) and after.txt (PR head, compiler + oracle -v).

## Runs
- `swarm test/rig.rip ownership-partial ownership-misc-1 doc-SPEC doc-CORE oracle -w 4`: 904 jobs, none died.
  So the SPEC example runs and prints `2`, the 10 new rejections lines hold, and coverage holds.

## Wording finding: "can be assigned" draws the wrong line
The line the compiler draws is whether the *field* can be written, not whether the *binding* can be reassigned.
- Loop binding (`for x in <v`) and `as` binding (`if <o as s`) cannot be reassigned. The compiler says
  "loop and pattern bindings are immutable", and SPEC 7045 lists a loop binding with parameters and fixed bindings.
  Yet `<x.tags` and `<s.tags` still take, leaving `none` (loop.rig, loopseen.rig, asb.rig print `0 true`),
  and `x.tags = none` is accepted (loopfield.rig, asfield.rig).
- Parameter, capture, and `=!` local: `p.tags = ...` is rejected (paramreassign.rig, fixedfieldassign.rig).
  These are exactly the bindings where, before the PR, the take was rejected ("cannot take parameter/captured/fixed binding").
- In CORE alone the sentence is consistent: CORE §6 says only parameters and fixed bindings may not be reassigned,
  so in CORE's own terms a loop binding is assignable. But SPEC's parenthetical and the CHANGELOG headline
  ("a binding that cannot be assigned") take in loop and pattern bindings, and those keep the take.
- Replacing the list with "a binding that cannot be assigned" alone would be less true, not more.
  The general clause should name the real criterion (whether `p.f = x` could assign the field), with the list kept.

Proposed CORE:
> An optional field is taken, leaving `none`, where `p.f = x` could assign it; of a parameter, a capture, or a `=!` local, where it could not, it moves like any other field.

This ties back to the paragraph's own "`p.f = x` makes a local's field usable again".

SPEC's rationale "nothing could see that `none`" is weak: a later read *could* have seen it. The real reason is that a take
writes `none`, and such a binding's fields cannot be written. sema's comment says it right ("nothing could write the field").
Proposed SPEC:
> Of a binding whose fields cannot be assigned (a parameter, a capture, or a `=!` local), a take could not write that `none`, so an optional field moves like any other, and the binding stays partly moved.

CHANGELOG headline: change "a binding that cannot be assigned" the same way ("whose fields cannot be assigned").
The body is right, and "Only programs rejected before are accepted" holds: `=!`/param takes were rejected before (before.txt).

## Oracle vs compiler
- Oracle `unassignable` = param | capture | fixed local, not pattern- or as-bound; also `via == .own`, `!handle`, `!copies`.
  The sentence alone yields that (with "owned object" from the paragraph). The `!pattern_bound and !as_bound` guards
  are not derivable from CORE. They look dead: `if f() as a, b` names are assignable (asresassign.rig). They do no harm.
- Compiler `fixedOwner` also excludes read-only (imported) fields, a type's named-none field, slice/string_view steps,
  and access through shared. Where those apply, the compiler keeps the take (and rejects it) and the oracle may move it.
  That gives only compiler-rejects differences, never an unsound accept. Not probed (read-only fields need two modules).
- Probes agree on every function: nested `<o.inner.tags` (accept), box param (C3), read view (rejected),
  once vs many-call capture (B3), `=!` reuse after move (C1), multi-result `a, b =! two()` (moves), defer reading another field (accept).

## Verdict
The code and the oracle are correct, and they agree. Fix the wording before merge (CORE optional, SPEC + CHANGELOG recommended).
