# Review: fold 0d9a73af, round 2 (argument evaluation order after the H1 fix)

Verdict: **no finding.** Argument evaluation is in written order everywhere I tried.

Probes: `.git/revamp/r3/review-fold-2-probes/` (about 85 programs, `run.sh` runs them).
Each accepted program ran under `RIG_SANITIZE=1` in debug and in `build --release`.
Every one was sanitizer-clean, and the printed order and values matched the written order.

Covered:
- Free functions, `sub`s, methods (a temporary receiver plus reordered arguments, `?self` and
  `!self`), struct and enum constructors, generic functions and generic structs, a
  closure call, nested reordered calls (inner before outer, left to right).
- Values: `grow(!t)` with `?t` as `String`, `?Text`, generic `?T`, `Static`; a slice `?v[0..1]`;
  `?t[2..5]`; a `?Text` of a Vec element; a field `?w.t`; `+t`, `<u`; defaults with and
  without `m:`.
- Pure candidates read before a writer written after them: Int local, `b.n`, `v[0]`, `t.len`,
  a `*Cell` `get()` through a second handle: all read before the write, as written.
  Written after the writer: they read the new value, as written.
- Arguments that are `a if c else b`, `??`, `catch`, `?`/`!` propagation, nested.
- Laziness: reordered calls on the right of `and`/`or`, in a ternary, a `??` or `catch`
  right side, a match arm, a loop condition, a `for` range: they run only when reached,
  and once per iteration.
- The reorder is hoisted into `__rig_arg_N_i` temporaries in written order
  (`w.two(__rig_arg_5_1, __rig_arg_5_0)`, with `grow` first).

Rejected by the checker, as expected (read loan live): `show(s: ?t, n: grow(!t))`,
`w.at(n: grow(!t))` with `w` viewing `t`, `const u = ?t` then `grow(!t)`, a write through
`?v[0]` of a Vec of Text.

Pure arguments: `isPureArg` keeps only literals, `const` names, pointer views without a lend
row, and moves of a name. `fixed` means `const`, so the `isPureArg(operand)` branch cannot
keep a mutable by-value view pure. Field reads, indexes, slices, and element views are
never pure. I found no wrongly pure argument.

Notes (not findings): `RIG_OUT_DIR` does not move the package cache (`~/.cache/rig`).
A `?Cell` / `?*Cell` argument is a pointer, so the callee reads it after later
arguments ran; that is the same in the checker and in emit.
