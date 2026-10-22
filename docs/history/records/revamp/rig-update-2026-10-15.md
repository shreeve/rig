Rig update for everyone writing Rig (2026-10-15), from the Rig foreman. Each item says whether it's on main, merging, or not built yet.

1. **"object", not "struct"** — on main (#222).
   - A Rig `obj` type is an object. Say "struct" only for Zig, C or Rust; Zig code and text about the emitted Zig keep "struct".
   - SPEC's section and anchor are now "Objects" / `#objects` (links to `#structs` are stale).
   - Nine compiler messages changed wording. For example: "`drop` bodies are only for non-generic objects", "an object is declared with `obj`: `obj Foo`", "… or an object that holds one". Update any test pinned to the old text.
   - New prominent rule, in CORE §1, README, QUICK, WELCOME and SPEC: **an object is a value; `^` puts it on the heap and `*` shares it.** `b = a` copies a plain object and moves an owning one.

2. **`*w` upgrades a weak handle; `w.upgrade()` goes away** — owner-approved, being built (branch `weakstar`), not on main yet.
   - `if *w as p` upgrades: `p` is a new `*T` while the value lives, `none` after. `w` stays usable.
   - `if *<w as p` upgrades and ends `w` (`<` means move).
   - `*~T` (a shared handle holding a weak one) becomes rejected, like `^~T` and `**T`.
   - Propagating "gone" is `(*w)?`, because `*w?` parses as `*(w?)`.
   - In a generic body, `*x` on a `T` keeps its share meaning; the body never quietly upgrades.
   - When it lands, `w.upgrade()` is a compile error pointing at `*w`, and the compiler's own uses are migrated. Your code needs `.upgrade()` → `*w`. An object's own method named `upgrade` is unaffected.
   - CORE sentence 8 (approved): "`~h` holds the counted value weakly, and `*w` is the way back: a new handle while the value lives, `none` after."

3. **cpuq and machines**
   - The cpuq session is in charge of how Rig's tests are run and watched: machines, cores, watchdogs, caching. Ask it, don't redesign it.
   - For Rig's own rounds right now, the owner says: run on the Mac directly, `-j 2`, an explicit `zig build -j2`, and add `# cpuq: skip` to heavy commands (the hook's escape).
   - Matrix runs for Rig go through cpuq by message ("matrix: <worktree>, PR #N"), as a `--delta` run against a shared warm cache on burst.
   - Coming: `cpuq cap` (0.17), then `cpuq submit SPEC.json` (0.18), which will replace hand-written run lines.
   - pup was emptied; burst was rebuilt with a 250 GB spill disk.
   - test/matrix.py's memory watchdog no longer runs `ps` over the whole machine (#225, on main).

4. **Other language changes**
   - On main:
     - `std.target` with `target.arch` (#208), a question the compiler asks about the target, not an `@` builtin.
     - `--release=fast` also drops vector overflow checks (#202).
     - Handles have no `==` (rule B): `*T` and `~T` don't compare; compare what they view with `?a == ?b`.
     - A for loop's method-call source is lent by the receiver-sigil rule, and a held iterator keeps its loans (#206).
     - Generic bodies: a `T` variable's loans count, and so does every result that holds a `T` (#215). Some generic code that leaked a loan through a `T` result is now rejected.
   - Merging, CI pending: **Map/Set** (#212) — `Map[K, V]`, `Set[T]`, `x.hash()`, `std/hash.rig`, insertion order.
   - Gated, merging soon:
     - **Disjoint field loans** (#210): `?p.a` and `!p.b` can be live at once; loans are tracked by field path.
     - **Index evaluation order** (#220): `v[0][grow(!v)]`, an index that writes the root of a place it reads past storage it could free, is now rejected. In-root shapes such as `vs[grow(!vs)]`, `p.v[grow(!p)]`, arrays and slices stay accepted.
     - **Function markers** (#224): `inline fun`, `called fun`, `rarely fun`, written before `fun`/`sub` (after `pub`). They are contextual keywords, so they still work as ordinary names elsewhere.
   - Decided, not built:
     - **Generic loans, option (b):** a generic body is checked once, as if each type parameter were an object that owns a resource and holds read views. A rule broken only by loans that values of type parameters carry becomes a per-instance requirement, checked at each instance's types. CORE text approved; the round runs after the landing.
     - **`keeps s`** (round B): built and parked behind it.
