# Partial moves: adversary

Today `p` drops by one `defer rig.drop(&p)` behind one `__rig_alive_p` flag, at every exit. Flow, the oracle and λRig track whole vars only.

**Holes and restrictions**

1. **Branches, `!`, `break`.** `if c: <p.a` then exit: one defer covers paths in different states, so it leaks or double-frees. *Rule:* each moved path gets a runtime flag in `p`'s scope, cleared at the move. Then `Q(a: <p.a, b: f()!)` drops once.
2. **`p.a = x` after a maybe-move.** Drop if flagged, store, set the flag.
3. **`p = P(a: <p.b, b: <p.a)`.** The old `p` is dropped field by field, behind its flags.
4. **Whole uses read the hole:** `?p`, `!p`, a `?@` method, `f(<p)`, `+p`, `<p`, `return p`, a last value, `match p`, `swap(!p.a,…)`, a capture of `p`, `defer print(p)`. All are rejected.
5. **Nested `<p.a.b`.** `p.a.c` stays usable, `p.a` does not. `p.a = x` drops `p.a.c`. `p.a.b.z = x` is rejected.
6. **A drop body on the path.** In `<p.a.b`, `p.a`'s drop would read the hole. No type from the root to the moved field's parent may have one.
7. **`<p; p.a = x`.** This makes a live `p` with uninitialised fields. Rejected.
8. **Views, handles, containers:** `<w.a` (`w: !P`), `<@a` in `!@`/`drop`, `*T`, `*Frozen`, an `if o as x` subject, a `match p` payload (it must count against the root, not the alias), `<v[i].a`, `Table`, `error`. Rejected.
9. **`<b.a` with `b: ^T`.** The box frees and drops its contents as one step. Rejected in v1.
10. **Closures and defers.** Only an exactly-once closure may move a captured field, lowered as a parameter. `defer` and `errdefer` never move or re-init a part.
11. **Optional fields.** `<p.o` stays a take that leaves `none`, so `if p.o as x` stays sound.
12. **Generic `T`, tasks.** Safe: for a copy the flag is a no-op. `f(<p.a)&` is a plain move.
13. **Oracle.** C3 rejects every part move, and its emptiness is per var. If it is just relaxed, it agrees blindly. Give `flow.zig` and λRig per-path emptiness first, plus a sanitizer case program per hole.

**Minimal safe rule set**

- `<p.f` only on a field path from an owned local or owned parameter: no view, handle, box, element, optional value or capture on it, and no `drop` on it. The field's type moves.
- After a partial move, only live sub-paths are usable until every moved path is re-assigned whole, on every path.
- Each moved path has a runtime flag. Scope exit, `p.f = x` and `p = x` drop only flagged parts.
