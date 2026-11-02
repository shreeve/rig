# `return if c` with a block (2026-11-02)

SPEC's "Block expressions" let an `if` be "a `return` value", while
`return if c` followed by a deeper branch failed as "unexpected
indentation". Asked which SPEC meant, the owner said "Yes, parse it", and
#871 (queue row 62) made the lexer read an `if` right after `return` or
`break` as a block when a deeper line follows it.

Looking at the result, the owner saw two problems:
- in a function's tail the `return` is redundant, since a function's
  value is its last expression;
- `return if x > 0` means two things, depending on the line below it.

A panel of three reviewed four defaults:
- [consistency.md](consistency.md): Rig's own consistency, with probes;
- [implementation.md](implementation.md): where the error goes, what the
  change costs, and counts of real code;
- [prior-art.md](prior-art.md): other languages.

All three recommended the defaults, and the owner approved them ("Approve
the defaults"):

1. After `return` or `break`, an `if` is always a guard.
2. A guard followed by a deeper line is rejected at the guard's `if`,
   with the fix.
3. SPEC and SYNTAX say a guard takes no block. `return match` keeps its
   arms below, because `match` has no guard form.
4. No rule against a needless `return` at the end of a function.

#872 (queue row 64) built them, and #871 never shipped in a release.

The panel found that #871 had caused two problems of its own:
- a guard whose condition continued on a deeper `.` line was read as a
  block;
- one line's indentation decided whether a `break` or `return` happened
  at all.

Counts at the time:
- Trig had 164 jump guards, none followed by a block;
- loc, std and the examples had none either;
- a needless final `return` appeared about twice in Trig.
