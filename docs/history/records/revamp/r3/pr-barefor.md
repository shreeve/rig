# Bare `for`

`for xs` is `for _ in xs`: no loop variable, any source (range, slice, list,
made iterator, `for !it`). `it` is an ordinary name.

- rig.grammar: second `for` alternative leaves `var` empty (role now `leaf?`).
  LALR(1): no conflicts (`in` follows no expression).
- src/rig.zig: `Parser.bareFor` fills the empty var with a hidden `_` leaf at the
  `for` keyword, so typecheck, ownership and emit see the existing node.
  `for *x in` hint moved to the `in` token (a bare `for *x` now parses up to it).
- Docs: INTERNALS (Bare `for`), SYNTAX, SPEC.
- Tests: behavior/syntax/for_bare (range, list, read, made, `for !it`, `for <it`,
  nesting, break/continue, label, else, loop value, old forms; release too);
  reject/ownership/for_bare_iterator_not_writable (same hints, `for _ in` spelled).
- Gates: suite, corpus, matrix --delta green; equiv vs base differs only on
  for_ptr_binding_reserved (diagnostic position) and the new SYNTAX doc block.
- parser.zig regenerated; PR #110 still OPEN, so not yet deleted.
