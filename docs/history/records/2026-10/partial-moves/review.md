# Partial moves: adversarial review of the build (2026-10-24)

A reviewer probed the compiler change (`partial-moves-compiler`) with 33
programs under `RIG_SANITIZE=1` and `RIG_LEAK_TRACE=1`, against the
approved text and the adversary's 13 holes.

## Holes found, both in the emitted drops, both fixed

1. **A parent and a child both moved out.** `rig.dropParts` stopped at
   the first path that matched, and when its flag was set dropped the
   whole subtree, ignoring the flags of paths below it. `x = <p.a.b;
   p.a = In(...); y = <p.a` freed `x`'s string at the refill. Fixed: a
   held path with moved paths below it is walked field by field.
2. **Fields Zig renames.** The drop compared Rig field names with the
   Zig struct's, and `writeZigIdent` renames some (`debug`, `main`,
   `std`, `self`, ...) to `debug'`, so the path never matched and the
   moved field was dropped again. Fixed: the paths are written in the
   Zig spelling.

Both are cases in test/rig/ownership-partial.rig.test ("partial nested
paths", "partial per path flow").

## Wrongly rejected

None found. Every exit (`!`, `?`, `break`, `continue`, `return`), loops
and labels, `p.a = f(<p.a)`, `p = x` while partly moved, owned bindings,
`<@a`, `once` closures, tasks, handle, box and optional fields, generic
fields at copy instances, and destructured locals ran clean.

## Nits, left for later

- Two messages still say a field can't move out of its parent: a bare
  tail `p.a` of a type with no clone (ownership, `reportAlias`), and
  `p.a.into()` with a `<@` method (typecheck), which could suggest
  `<p.a` and `(<p.a).into()`.
- `g(!p.a, <p.a.b)` reports two errors at one place.
- A `defer` registered after a move and before the refill is rejected
  where the oracle accepts it; plain names behave the same way.

The oracle itself was found to read all of `s` in `swap(!s.a, <s.b)`,
fixed in #668 ("swap reaches only the places it exchanges").
