# Soundness audit of #532-#547 (2026-10-22)

An independent review of the merged PRs #532-#547 against the North Star
and CORE, with probes run under `RIG_SANITIZE=1` on a Rig built from
main 9477f3e8d.

**Verdicts:** #535, #537, #538, #539, #540, #541 sound; #542 sound (about
50 probes, including every finding of its first review, rerun); #532's
compile-time functions sound; docs PRs (#533, #534, #543-#547) claim
only what holds.

**Defects found, fixed in the audit PR:**

- **D1 (critical, from #532):** a closure literal given to an actor
  method in a task call, `(!c).apply(|!total, x| ...)&`, was accepted,
  and its captures dangled (a segfault in `__rig_invoke`). The actor's
  argument check classified the literal as a function value while
  `crossCheck` classified it as a callable view: two classifiers for
  one fact. Now both use `crossingTypeOf`, and a closure literal given
  to an actor is rejected, as in 0.2.9.
- **D2 (medium, from #536):** a `Table` of an object with a method named
  `empty` failed in Zig: `table.defaultOf` read any `empty` decl as the
  default. The runtime's marker is `__rig_default`, a reserved name.
- **D3 (medium, from 0.2.9):** `h: *fun(Int) -> Int = *g` of a function
  checked and then failed in Zig; it is rejected, as `*g` alone was.
- **D4 (low, from #542):** SPEC §13 "Naming the error" and INTERNALS
  still said functions declare no error sets.

**Bends, not fixed:** `task.all`, `task.isolate` and `par.map` give any
error, so a function declaring `!E` cannot pass their failure on with
`!`; the hint "lend it to read: `?B.y`" leads to another error; a
generic body passing a method's failure on with `!` is wrongly
rejected, with `Int!!` in the message (pre-existing).
