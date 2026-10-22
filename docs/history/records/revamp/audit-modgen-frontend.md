# Audit: generics across modules (grammar, checker, diagnostics, docs)

Branch `modules-generics`. Scope: `git diff main..modules-generics`. Tool: the existing `bin/rig`.
Repros are in `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R11b/repro/<ID>/`. Run each with `cd <dir> && bin/rig check main.rig` or `bin/rig run main.rig`. Every finding was reproduced twice.

A prototype of the F1 and F2 fixes is in `.../R11b/rigcopy` (`src/sema.zig`). It was built in scratch. With it, the full suite passes (1355/0/0), all F1 repros run, and the five true self-nesting cases below are still rejected.

## Findings

| ID | Sev | Summary | Repro |
|---|---|---|---|
| F1 | **High** | The declaration-time self-nesting check rejects valid programs. It fires on a generic method whose own type parameter appears in an instance of its type, as in `zip[U] -> List[Pair[T, U]]`. It also fires on a private type with such a method that a `pub` generic uses. Removing `pub` makes the same code compile and run. | `F1a_pub_zip_single`, `F1b_private_type_method`, `F1d_lib_zip`; control: `F1c_control_no_pub` |
| F2 | Medium | `checkSelfNesting` is cubic for chains of `pub` generics. With n = 200/400/800 chained `pub fun f_i[T]`, `rig check lib.rig` takes 0.13/0.86/6.6 s on an unloaded machine. The same library with one `pub` takes 0.07 s. | `F2_selfnesting_cubic` (`gen.py N`) |
| F3 | Low | A method instance reached through a chain is named as the module's function when a module-level function has the same name. It prints `lib.conv[Bool]` for `Wrap.conv[U]`, but `lib.conv` is a non-generic `fun conv(n: Int)`. | `F3_method_named_as_function` |
| F4 | Low | Instance names are inconsistent: `conv[Bool]` and `make[String]` for `lib.Wrap[Int].make("s")`, `` `max` takes compile-time parameters `` for `lib.max`, and `` `Plain.sq` `` for `lib.Plain.sq`. Elsewhere the code prints `lib.max[Int]`, `lib.Wrap.conv2`, and `lib.twice[Res]`. | `F4_bare_names` |
| F5 | Low (tests/docs) | Two claims have no test. (a) SPEC §4 and INTERNALS say generic methods of a `pub` type are checked for self-nesting at declaration, but no test covers a generic method; `pub_generic_type_self_nesting` uses a non-generic method. (b) Only one note's file name is checked (`diagnostics.sh`: a one-hop requirement note in `lib.rig`). The runner strips paths, so `# error: 2:3:` in `foreign_chain_requirement` cannot tell `util.rig` from `lib.rig` or `main.rig`. The same holds for ownership copy notes, foreign "declared here" / "field declared here" notes, and the array and frame notes. | `F5_untested_generic_method_self_nesting` (behaves correctly) |

### F1: false positive in `checkSelfNesting` (High)

`F1a_pub_zip_single/main.rig` is a single file:
```
pub struct List[T]
  items: Vec[T]
  fun zip[U](?self, other: ?List[U]) -> List[Pair[T, U]]
    ...
```
Output:
```
main.rig:8:7: error: `zip[U]` leads to ever deeper instances of generic types (through `List[Pair[T, U]]`); a generic type's body cannot nest itself in its own type arguments
  fun zip[U](?self, other: ?List[U]) -> List[Pair[T, U]]
      ^
```
Without `pub` (`F1c_control_no_pub`), `l.zip(?m)` runs and prints `2 b`.

The same library imported (`F1d_lib_zip`) fails in `lib.rig:8:7`, so no importer can use it.

`F1b` has a private `Wrap[T]` with `fun tag[U](?self, u: U) -> Wrap[Pair[T, U]]`, used by `pub fun make[T]`. Output:
```
lib.rig:11:9: error: `make[T]` leads to ever deeper instances of generic types (through `Wrap[Pair[T, U]]`); ...
```
`make` does not nest itself.

**Suspected code:** `src/sema.zig:1340` `expand`, lines 1350 and 1370. In the real expansion, a use that still holds a type variable after substitution is skipped (`has_type_var`); these are the method-local parameters such as `U`. In `reached` mode every use is followed, so each `List[X]` re-expands `zip`'s `List[Pair[T, U]]` with `T := X`, and the depth grows until it passes 24.

**Fix, prototyped and suite-green:** in `reached` mode, skip a use (function-use arguments or type use) that mentions a type or integer parameter not in `item.subst.params`. This is `usesOnlyParams`, the exact analogue of the `has_type_var` skip. Seeds of generic methods include their own parameters, so real self-nesting is still caught: `f[Wrap[T]]` through a private `g`, `Wrap[Wrap[T]]` in a method, `nest[Wrap[U]]` on a public generic or non-generic type, and `f` through `Hidden[T].m`.

### F2: cubic declaration check (Medium)

Each `pub` seed `f_i[T_i]` reaches `f_{i-1}[T_i]`, ..., `f_0[T_i]`. These are distinct from the other seeds only by the name of the type variable, so there are about n²/2 items, and each scans every use.

**Fix, prototyped:** in `reached` mode, when an instance's arguments are distinct bare type or integer variables (a renaming), replace them with the callee's own parameters before `r.fns.getOrPut` (`src/sema.zig:1362`). A renaming expands to the same depths. With this, n = 800 takes 0.08 s, and the suite still passes.

Importers are not affected: each module's expansion cost matches a local program's. With 400 fns × 8 types, that is about 0.18 s per importing module, linear in the number of modules.

### F3 and F4: naming

`src/sema.zig:2628` qualifies a use when `lookupInScopeOnly(module_scope, use.name)` finds a `.function`. That test is true for a method that shares a function's name.

**Fix:** record on the use whether it calls a module-level function, or its owner type, and qualify with that. Methods could print as `lib.Wrap.conv[Bool]`.

For F4, `typecheck.zig:1573` prints the bare `name`; pass the qualified callee text instead. Method instances (`FnInstance.name`) carry no owner.

## Pre-existing issues reached through the new forms (not regressions)

Each of these reproduces with local types too.

| ID | Summary | Repro |
|---|---|---|
| P1 | In a parenthesised type, `lib.Wrap [Int]` (spaced) says "a call inside parentheses needs its own parentheses: `Wrap(...)`", which is the wrong fix (`src/rig.zig:1220` `parenFreeCallHint`). In a body annotation it is a bare "unexpected `[`". `lib.lib2.Wrap[Int]` in a type says only "unexpected `.`", with no hint that a qualified type names one module. | `P1_spaced_bracket_type` |
| P2 | `lib.P(x: 1)` and `lib.IntWrap(v: 4)` (foreign aliases) say only "`lib.IntWrap` cannot be called" (`typecheck.zig:4613/4626`). A local alias says to construct the aliased type. | `P2_foreign_alias_call` |
| P3 | `w.conv2` hints "name it through its type: `lib.Wrap.conv2`", and that code is then rejected ("method of a generic type must be called") (`typecheck.zig:2431`). The inference hint hardcodes `x:` (`typecheck.zig:4546`), so `y = lib.Wrap(1)` suggests `x: lib.Wrap[...] = ...`. That hint is also given for `lib.Wrap.empty2[Int]()`, whose result is not a `lib.Wrap`. | `P3_hint_suggests_rejected_code` |
| P4 | `x = lib.Wrap [Int](v: 1)` gives three errors (a cannot-infer error, "`Int` is a type", and "`[Int]` ... cannot be called"). This is the paren-free call parse. | `cases/` in scratch |
| P5 | Errors print out of source order: instance errors come after body errors, and type roots before function roots. The "made by" note is missing when the root is a type or a function made through a generic type (`lib.boxed` → `util.Box2[String]`), and for all ownership instance errors. | `cases/req2`, `cases/ownchain` |
| P6 | A type-annotation instance points at the name (`lib.Wrap[Bool]` → col of `Wrap`). An expression instance (`lib.W[Bool](...)`) points at `lib`. | `cases/multi`, `cases/madeby_type` |
| P7 | A shadowed module name (`lib = S(...)` or parameter `lib`) cascades. The shadowing error is followed by "`lib` is not a module" and "no method `Wrap` on type `S`". | `cases/shadow2`, `cases/shadow3` |

## Attacks that came up clean

**Grammar**
- `lib.Wrap[Int]` works in every type position, and the program runs with correct output: parameters, fields, returns, `?T`/`!T` borrows, optional `T?`, `*T`, `[2]lib.Wrap[Int]` arrays, `Vec[...]`, `Cell[...]` (same rules as local), local aliases, `fun(lib.Wrap[Int]) -> Int`, a nested `lib.Wrap[lib.Wrap[Int]]`, and `lib.Wrap[?Int]`.
- These give one clear error each: a bare `lib.Wrap` ("requires type arguments; write `lib.Wrap[T]`"), `lib.Wrap[]`, `lib.Wrap[3]`, `lib.Pt[Int]`, `lib.max[Int]` as a type, `lib.Nope`, `nolib.Wrap`, `main.Wrap`, `lib.if[...]`, `lib.[Int]`, `lib..Wrap`, and unbalanced brackets.
- `lib.Wrap[Int,]` is accepted, as `Wrap[Int,]` is locally.
- `nexus` regenerates `src/parser.zig` byte-identically with no conflicts. The IR is `(generic_inst (member lib Wrap) Int)`. `--facts` and `normalize` work.
- A local generic named like a module is a duplicate-declaration error.
- A local `Wrap` next to `lib.Wrap` works.

**Fuzzing**
- About 3,000 mutants of the 16 new or changed multi-module tests (brackets, dots, names, `pub` toggles, token swaps, 1–3 edits each, `gtimeout 10`). All accepted mutants were also run.
- There were 0 crashes, 0 hangs, 0 diagnostics without a location, and no accepted mutant that failed to build or leaked.
- Every cascade found with single edits is a general pre-existing behavior (for example `none = ...`, or an unbound `T` after renaming a parameter), none of it specific to this branch.

**Visibility**
- A private generic function or type named from outside is rejected with "not public" at each spelling (`lib.hid`, `lib.hid[Int]`, `lib.Hidden[Int]` in a type, and `lib.Hidden.get`).
- These work: a private generic's value through a public result (fields and generic methods, `c.get[Int](4)`), a public generic calling a private helper (whose failures are reported with "made by"), and a generic method of a private type reached through a public type.
- A `pub type H = Hidden[Int]` alias makes a private instance nameable. This is consistent with non-generic aliases and SPEC §15.

**Inference and hints**
- These all work: the expected type (`z: U8`), literal defaults (`lib.max(1, 2.5)` gives `2.5`), a conflict ("conflicting types for `T`"), and an out-of-range `U8` literal.
- Every hint pasted as suggested compiles and runs: `lib.empty[Int]()`, `lib.zeros[3]()`, `lib.pick[Int, Int](1)`, `lib.Wrap[Int].none()`, `lib.Wrap[Int?](v: none)`, `w.conv2[Int]()`, and `lib.Wrap[Int].empty2[Int]()`.
- Integer inference from foreign `[n]T` works: `lib.sum`, `lib.lens(r.items)`, `lib.cap_of(?r)` with `Ring[T, n]`, `r.grow([7, 8])` (a method's `m`), `s: lib.Ring[Int, 5] = lib.mk()`, and `lib.mk[0]()`.
- Default parameters of foreign generic functions and methods read the library's source correctly.

**Diagnostics**
- Notes land in the right file at the right line and column. This holds for the requirement notes (one hop and through a chain into `util.rig`), ownership copy and element notes (through a chain), `` `lib.Wrap` declared here ``, "field `v` declared here", and the variant notes. It also holds for "the array is made here" (`lib.zeros[2000000]`) and "`frame` is declared here".
- Paths print correctly relative to the working directory or as absolute paths.
- `test/cli/diagnostics.sh` checks the printed `lib.rig:2:8:   note:` (one case only; see F5).
- The same failing foreign instance gives one error per module. Two call sites in one module give one error, and modules `a` and `b` give one each. Main is skipped when its dependencies fail.
- "made by" works through chains of functions (`util.hid[Bool]` is made by `lib.thrice[Bool]`) and from a type root (`lib.helper[Bool]` is made by `lib.Wrap[Bool]`).
- Mismatches print `a.Wrap[Int]` against `b.Wrap[Int]` against `Wrap[Int]` distinctly.
- A library's error stops its importers from being checked (no cascade).

**Self-nesting (no false negatives found)**
- These are all reported at the declaration: mutual recursion through a private generic, a non-generic method building `Wrap[Wrap[T]]`, a generic method on a public generic type or a public non-generic type calling itself nested, recursion through a private type's method, and nesting through a foreign proxy (`f(util.Box2(v: x))`).
- These are all accepted and run: non-nesting recursion (`countdown`), mutual recursion (`ping`/`pong`), argument swaps (`swap[A, B]` → `Pair[B, A]`), `map[U] -> List[U]`, and a one-shot `Wrap[Wrap[U]]`.

**Performance**
- A library of 200 generic functions and 200 generic constructors used from 20 modules × 100 call sites × 8 types checks in 1.75 s.
- Importer cost is linear in the number of modules. `importParam` is O(params × foreign list size) per importer, and each entry is copied once (`imported_entries`).
- There is no quadratic import behaviour beyond `generic_uses` deduplication (`indexOfScalar`), which is negligible at these sizes.
- The only superlinear cost is F2.

**Emit**
- A type reached only transitively emits `@import("lib.zig").Wrap(i64)` (checked in `c.zig`).
- Recursive foreign generic types (`next: (*Node[T])?`) terminate and run.

**Docs**
- SPEC §4, §15, §17, and §19; SYNTAX §14 Limits and §23; DESIGN; INTERNALS; and ROADMAP were read. Each behavioural claim was checked with a program.
- `./test/run modules` (75) and `./test/run doc/` (210) are green.
- No tracked file still says generics cannot cross modules. The only "across module boundaries" left is the "not public" message.
- No `Box` identifier remains in any tracked file.
- Untested claims are listed in F5.
