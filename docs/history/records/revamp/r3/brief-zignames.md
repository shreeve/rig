# Queued round: names that collide in emitted Zig (found by #247's review, 2026-10-16)

All "accept means correct" (rule 2) violations on main: `rig check` accepts, then Zig fails or prints wrong. Probes: scratchpad/review/ (from the enumnone review). Fix the class: one place decides how a Rig name becomes a Zig name, used everywhere, and no runtime hook keyed by a user-choosable name.
1. Locals/params named like an escaped method (`var`, `fn`, `u8`, `rig`, `std`, `panic`, `__rig*`) → "shadows declaration": src/emit.zig:1012-1015 `nameTaken` compares raw vs escaped.
2. Root names Zig's std reads via `@hasDecl(root, …)`: `debug`, `os`, `std_options`, `std_options_*` (and WinMain/wWinMain/DllMain/EfiMain on those targets): `emitter_names` in src/rig.zig:524. Emit root declarations so none can be a std hook (rename or a namespace).
3. `cloneWeak` user method hijacks `+x`: src/runtime.zig:662 should test the `__rig_weak` marker (line 605). Audit every runtime `@hasDecl` for user-choosable names.
4. `_` as a plain-enum variant or a generic type parameter: `writeZigIdent` (src/rig.zig:549) writes `_` bare.
5. A module or `use … as` alias named `none` → `null`: src/emit.zig:3844 `emitName`.
6. print/String(x)/@variants show internal suffixes (`rig'`): runtime.zig:3525/3538/3559 should strip as `rigTypeName` does.
Also: `extern fun panic()` would link `panic'` (extern names must not be escaped, or must be rejected); `.pp(new: x)` pattern rejected though SYNTAX allows keyword payload field names.
Gates: build, suite, corpus, matrix if typecheck changes, equivalence (emit diffs only in renamed identifiers), a sweep test over ~85 reserved names × use sites (the review's generator), one adversarial review.
