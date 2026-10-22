Rig 0.2.1 fixes memory-safety holes found in 0.2.0, and brings in three ownership rules the Core already implied. `rig check` accepted programs that then read freed memory or failed to compile. That breaks Rig's promise that safe code cannot corrupt memory. **Everyone on 0.2.0 should upgrade.**

## Fixed
- **A generic match copied a value out of something that isn't a place.** In a generic function, `match get(o)` with `.some(v) => v`, where `get` returns a view, freed the value twice when `T` owned memory (e.g. `Text`). The same held for branching subjects, fields and elements of calls, guarded and nested matches, and catch-all bindings. A catch-all copy also lost changes to a Cell inside it.
  - Such copies are now checked for every instance: they're accepted where `T` is plain data, and rejected otherwise.
  - Four related forms that also freed memory twice are closed: a `|<v|` capture, a nested `match <inner`, a returned write view, and `<v` in a closure.
- **A call held a write view and a read view of the same value:** `both(!b.firstw(), ?b)` was accepted. A write loan carried by any argument now lasts until the call returns.
- **`Box[*S]` and similar boxes of handles failed to compile in Zig.** Reads now work. Writes through a box of a handle are rejected, as they are through `*Box[S]`.
- **A generic `*T` or `~T` at a function type failed to compile in Zig.** It is now rejected, with a hint to use `T = *fun(...)`.
- **`x = *none` crashed the compiler.** It is now rejected where no `*(T?)` is expected, with a hint to write `none`.
- **The hint for `upgrade()` on a boxed weak handle repeated the rejected line.** It now suggests code that compiles.

**Programs 0.2.0 accepts that are now rejected:** the forms above where they were unsafe. Also `return v`, `<v` and `-v` of a payload of a match whose subject isn't a place, at any instance; a tail `v` still works.

## Changed: rules the Core already implied
- **A call that returns only a read view leaves its argument readable.** After `r = first(!v)`, `v` may be read, but not written, while `r` lives. In one statement too: `print(first(!v).n, v.len)` now works, unless the call may store the view.
- **Dropping a container of views isn't a use of them.** A Vec of views keeps its loans until its last use, not until it's dropped, unless dropping it runs a `drop` body.
- **A bare name or place only reads.** A write view of plain data held by a name, field or element reads the value it sees: `x = h.w` with `w: !Int` copies the Int. A call's `!T` result keeps the view.

No program 0.2.0 accepts is rejected by these three rules. They only accept more.

## Internal
- **The generated code now points at the subject of a `match`, `if … as`, `while … as` or `for` instead of copying it,** wherever the subject is a place. Generic payloads are bound in place. This changes no program's meaning; it prepares the next release to accept more programs (#53).

## Verification
- **Tests:** new reject and behavior tests for every form above. Matrix cells for generic payload copies, which v0.2.0 fails 45 times with uses of freed memory or double frees.
- **Gates:** the full suite, the reviewer corpus, the program matrix and the unit tests pass under the sanitizing allocator.
- **Reviews:** independent reviews of both changes found no remaining soundness issue.
- **CI:** passed on Linux and macOS.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #52 (rules), #53 (code generation), #54 (fixes), #55 (version).
