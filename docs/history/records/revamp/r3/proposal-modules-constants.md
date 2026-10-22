# Proposal: modules at scale, and constant tables

For the design owner: Trig's NEEDS items 1 and 3, built as general features. Probed on main at 34ffed549; no code changed. In a multi-file test, `==> path <==` starts a file.

## Feature A: modules at scale

**Problem.** Today `use checker.binder` gives "`checker.binder` names no module: a dotted path names a module of the standard library"; `a` and `b` importing each other gives "cyclic import: `a` is still being loaded when `b` imports it"; and `fun Point.twice(?self) -> Int` gives "unexpected `.`".

Trig's evidence (04-rig-gaps §3): typescript-go's checker is one Go package of about 40 files of mutually recursive methods on one `Checker`, and ts-rust keeps that shape in one crate. Rig forces it into one file of more than 100K lines. **Go forbids cycles between packages, and Rust between crates.** Both get mutual recursion from one unit made of many files. typescript-go's package graph is acyclic, so a port that maps one package to one module needs no cycle *between* modules. It needs a module made of many files.

**Why cycles fail today.** The `.loading` guard in `resolveUse` is the symptom. The cause is that `sema.check` takes each import's finished `SemContext` (INTERNALS, Modules: "fully checked, ownership included, before any importer is checked"). It merges the imports' `reach`. `importType` copies `b.T` out of b's type store, and `b.N` comes from b's folded constants. Contents and sizes come from b's computed ones. A generic proxy copies the declaring module's requirements, which come from typecheck of its bodies, and its `plain_reqs`, which come from its ownership check. INTERNALS relies on this: "Import cycles are rejected, so a chain of proxies always ends."

So a cycle-safe order is more than "declarations, then bodies". It is five phases, run in lockstep over each strongly connected set of modules: (1) symbols; (2) declarations, with aliases and constants in dependency order across modules; (3) contents and sizes over the joint type graph; (4) typecheck of every body; (5) ownership, then instance expansion and the requirement checks. That splits `sema.check` and `ModuleGraph.check`, and reworks the hand-off between generics and ownership. It would take weeks, and it gives Trig nothing once a module can be a directory.

**Options (the recommendation is in bold).**

- *Unit of mutual recursion.* **A-dir: a directory is a module,** whose `.rig` files share one namespace, as a Go package's do: no new syntax, and sema's pipeline is untouched. A-cycle, cross-module cycles by the five phases: not now. A-part, a file listing its parts (`part "x.rig"`, as Rust's `mod x;`): rejected, since a directory listing already says it.
- *Paths.* **Absolute from the program root,** as `use foo` is today. Relative paths are rejected: one name would denote different files in different modules.
- *Methods outside the body.* **M-dot, `fun Point.norm(?self) -> Float`,** is declared as it is called (`Point.origin()`, `p.norm()`). M-extend, an `extend Point` block as in Swift, needs a new keyword and an indent level across 40 files. M-reopen, a second `obj Point`, means `obj` no longer says where the fields are. M-recv, `fun norm(self: ?Point)` as in Go, reads as a free function and loses `?self` / `!self`.
- *Where a method may live.* **Any file of the type's module, and no other module.** A Zig struct's declarations live in its body. An importer must see a closed set of members, and privacy is per module. Methods added from outside the module are what traits (NEEDS 2) are for.

**Syntax.** Each form below follows SYNTAX's rule, "after a name, `[]` is compile time and `()` is run time", and declarations mirror calls (`Scale.unit[6]()`).

```text
use   = "use" name ("." name)* ["as" name]        # was: ["std" "."] name
fun   = "fun" [owner "."] name [tparams] params "->" type [from] block
sub   = "sub" [owner "."] name [tparams] params ["!"] block
owner = name ["[" name, ... "]"] | name "." name   # the last parses only to be rejected
```

- **Imports.** `use checker.binder` binds `binder`, the last name, as `use std.os` binds `os`. Types stay two-part: `binder.Node`.
- **Generic types.** In `fun Wrap[T].map[U](?self, f: fun(T) -> U) -> Wrap[U]`, `[T]` repeats the type's parameter names exactly as the `obj` declares them (`Ring[T, n]` for `obj Ring[T, n: Int]`), and `[U]` is the method's own.
- **`pub` and `drop`.** `pub fun Point.norm` exports the method. `drop` stays inside the body, because a drop body decides the type's kind (CORE §1).
- **Grammar.** The new alternatives share the prefix `FUN name [tparams]` with today's and diverge at `.` or `(`, so they need no extra lookahead. `@schema` gains the roles `owner` and `owner_params`.

**Semantics and desugaring.**

1. *Paths.* `use a` names `<root>/a.rig` or the directory `<root>/a/`. It is an error if both exist. `use a.….z` names the directory `<root>/a/…/z/`. **Every `.rig` file in a subdirectory belongs to that directory's module.** So `checker/binder.rig` is part of `checker`, and a module beneath it is a directory such as `checker/binder/`. Each component is a Rig name, spelled as on disk (the realpath check, per component), not starting with `__rig`. The module emits to `a.….z.zig`. `use std.…` follows the same rule.
2. *Directory module.* It is the one-file module whose text is its files joined in byte order of their names, except that each file closes its own blocks and brackets, a diagnostic names the file it is in, and a `use` binds its name **in its own file only** (two files that bind one name to different modules are rejected). Private declarations are visible in every file of the module, as in Go.
3. *Constants in any order.* "Only earlier constants" would depend on file names. So in every module, a constant may name any constant of its module, constants fold in dependency order, and a constant that depends on itself is rejected. `ct_const_order.rig` and line 16 of `module_level_binding.rig` become accepted.
4. *A method outside the body.* In module M, where M declares `obj T[P]` or `enum T[P]`, `[pub] fun T[P].m[Q](r, ps) -> R` and its block are the same declaration without `T[P].`, appended as `T`'s last member. `pub` is kept, and `Self` is `T`.
5. A cross-module cycle stays an error, and its message gains a hint toward directory modules.

**Ownership: none of Feature A touches it.** An out-of-body method *is* the member it desugars to, so `?self`, `!self` and `<self` mean what they mean today. Paths, directories and per-file `use` are name resolution. **There is no CORE text.** SPEC §3 Constants and §14 change, as do SYNTAX §3, §8 and its grammar summary.

**What Zig gives.** Zig resolves declarations lazily and in any order, so a directory module emits as one Zig file with no ordering work, and an out-of-body method is emitted inside its struct. Zig accepts cyclic `@import`s, failing only on a real dependency loop, which Rig already rejects; so A-cycle, if ever built, needs no change to the emitted Zig. Zig has no `usingnamespace`, so one type cannot span Zig files.

**Tests.** The doc examples go in SPEC §14 and SYNTAX §8. Landed with them, `test/run` accepts `file=dir/name.rig`; its regex allows only `name.rig` today.

~~~markdown
```rig file=checker/expr.rig
pub obj Checker
  pub depth: Int

  pub fun expr(?self, n: Int) -> Int
    0 if n == 0 else self.stmt(n - 1)
```

```rig file=checker/stmt.rig
use checker.binder

pub fun Checker.stmt(?self, n: Int) -> Int
  binder.bump(self.expr(n))
```

```rig file=checker/binder/bump.rig
pub fun bump(n: Int) -> Int
  n + 1
```

```rig pending
use checker

sub main()
  print(checker.Checker(depth: 0).expr(3))
```

```output
3
```

```rig pending
obj Point
  x: Int
  y: Int

obj Wrap[T]
  v: T

fun Point.origin() -> Self
  Point(x: 0, y: 0)

sub Point.shift(!self, dx: Int)
  self.x += dx

fun Wrap[T].map[U](?self, f: fun(T) -> U) -> Wrap[U]
  Wrap(v: f(self.v))

fun double(n: Int) -> Int
  2 * n

sub main()
  p = Point.origin()
  !p.shift(3)
  print(p.x, Wrap(v: 4).map(double).v)
```

```output
3 8
```
~~~

The reject tests go in `test/reject/modules/`:

`method_owner/main.rig`, beside a `geo.rig` that declares `pub obj Point` with `pub x: Int`:

```rig
use geo

type P = Point

obj Point
  x: Int

obj Wrap[T]
  v: T

fun geo.Point.a(?self) -> Int
  1

fun Nope.b() -> Int
  1

fun P.c(?self) -> Int
  1

fun List.d(?self) -> Int
  1

fun Wrap.e(?self) -> T
  self.v

fun Point.x2(?self) -> Int
  1

fun Point.x2(?self) -> Int
  2

sub main()
  print(1)

# error: 11:5: methods of `geo.Point` are declared in module `geo`, which declares the type
# error: 14:5: `Nope` names no type declared in this module
# error: 17:5: `P` is an alias of `Point`; declare the method as `fun Point.c`
# error: 20:5: `List` is a built-in type; a method is declared on a type of this module
# error: 23:5: write `fun Wrap[T].e`: a method names its type's parameters as `obj Wrap[T]` declares them
# error: 29:11: duplicate member `x2` in `Point`
```

In each test below, `main.rig` imports the module under test and prints 1, unless the row says otherwise:

| Test | Files | `# error:` |
|---|---|---|
| `method_private` | `geo.rig`: `pub obj Point` and a non-`pub` `fun Point.norm(?self) -> Int`; main calls `geo.Point(x: 1).norm()` | `` method `norm` of `geo.Point` is private to module `geo` `` |
| `path_missing` | `use checker.nope` | `` 1:1: cannot read module `checker.nope`: no directory checker/nope/ `` |
| `path_part` | `checker/binder.rig`; `use checker.binder` | `` 1:1: `checker/binder.rig` is part of module `checker`; a module under `checker/` is a directory, such as `checker/binder/` `` |
| `path_ambiguous` | `checker.rig` and `checker/a.rig`; `use checker` | `` 1:1: module `checker` is both the file `checker.rig` and the directory `checker/`; keep one `` |
| `use_per_file` | `geo.rig`; `m/a.rig` does `use geo` and calls `geo.origin()`; `m/b.rig` calls `geo.origin()` at 2:3 without it | `` 2:3: `geo` is imported by another file of module `m`; add `use geo` to this file `` |
| `use_conflict` | `m/a.rig`: `use std.math as g`; `m/b.rig`: `use std.os as g` | `` two imports bind the name `g`; name one of them with `as` `` |
| `import_cycle_hint` | as `import_cycle/` | `` cyclic import: `a` is still being loaded when `b` imports it; modules may not import each other in a cycle: put the files that call each other in one module, a directory `` |

Also `test/reject/types/const_cycle.rig` (`A = B + 1`, `B = A * 2`, a `main`) expects ``1:5: constant `A` depends on itself (`A` → `B` → `A`)``, and `test/cli/module_dir_boundary.sh` checks that when `m/a.rig` ends inside `print((`, the unclosed bracket is reported at `m/a.rig:`, and nothing in `m/b.rig`.

**Plan.**

| File | Change | Effort |
|---|---|---|
| `rig.grammar` | `mpath` of any length; `owner` on `fun` and `sub`; `@schema` roles | S |
| `src/modules.zig` | a path names a file or a directory; the ambiguity, part-of and component checks; list a directory, sorted; join its files with a table of where each starts; output `a.b.zig`; the cycle hint | M |
| `src/rig.zig` | the lexer closes blocks and reports brackets at each file's end; `attachMethods`, a syntactic rewrite like `desugarIterLoops` | M |
| `src/diag.zig` | a module's `File` maps a position to (file, line) | S |
| `src/resolve.zig` | the owner diagnostics and the parameter-name check; the per-file `use` check in the one lookup of a module name; constants in dependency order | M |
| `test/run`, docs | `file=dir/x.rig`; SPEC, SYNTAX, INTERNALS (Modules, with the desugaring); ROADMAP's subdirectory line goes | S |

The work is about 1.5 to 2 weeks, in three rounds: paths with constant order, then methods, then directory modules. No round changes a soundness classifier, so the fast gate applies. The rounds can run in parallel with Feature B.

**Risks.**

- **Zig build time** for one Zig file per module: about 230K lines for Trig's checker. Measure it. If needed, emit each Rig file's free functions to its own Zig file, and alias them in the struct (`pub const m = @import(…).T_m;`).
- **Positions are `u32`** over the joined text, and the 16 MiB source limit applies per module. The checker is about 5 MB. The limit's message must say "module".
- **`bin/rig-oracle`** loads programs through `ModuleGraph`, so it sees the desugared tree. Verify that in round 3.
- **Order-free constants** change a rule: two of today's rejections become accepted programs.

**Decisions to confirm (A).**

1. A directory is a module, as a Go package is. Cross-module cycles stay an error, with a hint.
2. `use a` names `a.rig` or `a/`. `use a.….z` names the directory `a/…/z/`, and the last name is bound. Every `.rig` file in a subdirectory belongs to that directory's module.
3. A method outside the body is `fun T[P].m(...)`, with `T`'s parameter names as declared, in `T`'s module only. `drop` stays inside the body.
4. `use` binds per file. Private names are module-wide.
5. Constants fold in dependency order, with a cycle error, in every module.
6. Each module emits one Zig file.

## Feature B: constant tables

**Problem.** `pts = [Point(x: 1, y: 2)]`, `d = Diag(code: 1, msg: "x")`, and `v = Simd[U8, 4]([1, 2, 3, 4])` are all rejected with "a module-level constant needs a value known at compile time: a literal, `.variant`, an earlier constant, or operators, ternaries, and arrays over them". SPEC §18 lists the vector case as unsupported.

The cause is one positive list, `Checker.isConstExpr` in `typecheck.zig`. It holds literals, `comptime_known` names, operators, ternaries, and array literals and fills, and no constructor. No ownership rule forbids a table, and emit already writes `pub const C: T = e;`, which Zig evaluates at compile time.

A view of a constant already works: `fun all() -> []Static from static` returning `?names[..]` runs, because CORE sentence 7 counts a module constant as living for the whole program.

Trig needs a diagnostics catalog (about 2,000 entries of code, category, and text), keyword and character tables, and Unicode tables (8.5K lines in ts-rust).

**Options.**

- **B-plain (recommended):** any plain value made of literals, constants, and constructors of plain types.
- B-ctfe: compile-time functions (ROADMAP). It comes later, for computed tables; B-plain covers written and generated tables, which is Trig's need.
- B-lazy: owning constants built on first use. Rejected: it allocates without showing it, and needs a drop at exit.

**The rule.** A module constant is plain data whose type copies, made of compile-time parts. Its value is one of:

- a literal, `none`, `.variant`, a number type's limit, or a whole constant of this module or an imported one;
- integer or `Bool` operators and ternaries over those, folded and checked by sema as today;
- an array literal or fill of those;
- a constructor of an `obj`, or of an enum variant with a payload (generic instances included), whose arguments and used defaults are of those kinds;
- a vector made by `Simd[T, n].splat(x)` or `Simd[T, n](a)`, also through an alias.

Vector operators are excluded: Zig would compute the lanes at compile time, but Rig says an overflowing lane panics when the program runs.

Its *type* must copy (`sema.copies` is `.yes`) and hold no view. So no owner, handle, `unique` type, `?T`, `!T`, or slice. Text in a table is `Static`, which is plain. A `?String` field is rejected, with a hint to use `Static`.

Still rejected: function calls; a *part* of a constant inside a constant's value (`C[0].x`), since a constant names others only whole; function values; owning values.

Its size is bounded by `max_value_bytes` (8 MiB), as every type's is.

*Views: nothing new.* A read view of a constant, or of any part of it (`?T[..]`, `?T[i]`, a `for` over it), carries no loan and may be returned `from static` (sentence 7). Writing it, or lending it to write, is rejected already. A bare use copies it.

**Desugaring.** A use of `C = e` is `e`, written at that use. That is well defined because `e` is plain: it allocates nothing, holds no loan, and has no effect. The one addition is where it is kept: `?C`, `?C[i]` and `?C[a..b]` view one copy that lives for the whole program. That copy is sentence 7's module constant, which Zig keeps in read-only data.

**CORE text,** added to §1 after the vector paragraph:

> **A module constant is plain data that lives for the whole program.** Its type copies (§1), and its value is made of literals, other constants, and constructors of plain types. A bare use copies it; a read view of it, or of any part of it, carries no loan and may be returned `from static` (sentence 7). Nothing lends it to write, assigns it, moves it, or drops it. *(built for literals and arrays of them; planned for constructed values and vectors)*

**Tests.** These go in CORE §1 and SPEC §3 Constants, and the vector example goes in SPEC Vectors, replacing the §18 row:

~~~markdown
```rig pending
enum Kind
  fatal
  hint(level: Int)

obj Diag
  code: Int
  text: Static
  kind: Kind

DIAGS = [Diag(code: 1005, text: "expected", kind: .fatal), Diag(code: 2304, text: "cannot find name", kind: .hint(level: 2))]

fun all() -> []Diag from static
  ?DIAGS[..]

fun text_of(code: Int) -> Static
  for d in all()
    return d.text if d.code == code
  "unknown"

sub main()
  t = DIAGS
  print(text_of(2304), all().len, t[1].kind)
```

```output
cannot find name 2 .hint(level: 2)
```

```rig pending
type Block = Simd[U8, 4]

QUOTE = Block.splat(0x22)
STEP: Block = Block([1, 2, 3, 4])

sub main()
  v = Block([0x22, 0, 0x22, 1])
  print((v == QUOTE).bits(), v + STEP)
```

```output
5 [35, 2, 37, 5]
```
~~~

The reject tests are `test/reject/types/const_table.rig` and `const_table_write.rig`:

```rig
# A module constant is plain data that copies, made of compile-time
# parts.
obj Diag
  code: Int
  text: ?String

obj Bag
  items: List[Int] = List()

obj Ticket unique
  id: Int

obj P
  x: Int

type Block = Simd[U8, 4]

fun three() -> Int
  3

A = [Diag(code: 1, text: "a")]
B = Bag()
C = Ticket(id: 1)
D = P(x: three())
T = [P(x: 1), P(x: 2)]
E = T[0].x
F = Block.splat(200) + 1
G = Block.splat(300)
H = P(x: 9223372036854775807 + 1)

sub main()
  print(E)

# error: 21:5: a module constant holds plain data, and `Diag` holds a read view (`text: ?String`); text that lives for the whole program is `Static`
# error: 22:5: a module constant holds plain data, and `Bag` owns a `List[Int]` (`items`)
# error: 23:5: a module constant holds plain data that copies, and `Ticket` is `unique`
# error: 24:5: a module-level constant needs a value known at compile time
# error: 26:5: a module-level constant needs a value known at compile time
# error: 27:5: a module-level constant needs a value known at compile time
# error: 28:17: does not fit in `U8`
# error: 29:10: does not fit in `Int`
```

```rig
# A table is never written.
obj P
  x: Int

T = [P(x: 1)]

sub bump(n: !Int)
  n += 1

sub main()
  T[0].x = 2
  bump(!T[0].x)

# error: 11:3: cannot assign to constant `T`
# error: 12:8: cannot lend constant `T` to write
```

The value message becomes "… known at compile time: a literal, `.variant`, a constant, a constructor of plain data, or operators, ternaries, and arrays over them". It keeps today's prefix, which `module_level_binding.rig` matches. In `simd_forms.rig`, line 6 goes and the count becomes 5.

**A bug found while probing; fix it first.**

`big = [9223372036854775807, 1]` with `print(big[0] + 1)` passes `rig check`, then **Zig fails to compile it** (`overflow of integer type 'i64'`). That breaks rule 2. Emit writes `big[0] + 1` without `rig.rt`, so Zig folds the element at compile time. Tables would multiply this (`T[0].code + 1`).

*Class:* a part of a constant, read in arithmetic that sema does not fold. *Fix:* emit `rig.rt(…)` around the outermost place read of a constant, as in `rig.rt(big[0]) + 1`. Never wrap the whole constant, which in debug builds also avoids copying a table through `rig.rt(T)`. Do the same on the imported path, `isModuleValue`, which emits `rig.rt(lib.C)` today. *Rule:* a part of a constant is read at run time. Only a whole integer constant folds. *Test:* `test/cli/constant_part_overflow.sh` expects Rig's run-time overflow panic, not a Zig error, for an element, a field of a constructed constant, and an imported constant. *Siblings:* `-`, `*`, shifts, `neg`, conversions, and `match` guards.

**Plan.**

| File | Change | Effort |
|---|---|---|
| `src/typecheck.zig` | `isConstExpr` takes constructors (obj, variant, generic, `Simd`), checking arguments and used defaults recursively; the plain-and-copies check with its three messages; reject parts of constants | S–M |
| `src/emit.zig` | the `rig.rt` placement; confirm `emitConstructor` under `keep_comptime` calls no run-time-only helper | S |
| `src/sema.zig`, `src/ownership.zig` | none: `copies` is the type fact, and constants are already walked first and never lent to write | none |
| docs | CORE §1; SPEC §3 Constants, Static, Vectors, §18; ROADMAP's compile-time functions narrowed to computed tables | S |

The work is about 3 to 4 days, as one round after the hotfix above. `isConstExpr` classifies expressions, so the round runs the full matrix, and it does not overlap another round on typecheck's classification.

**Risks.**

- **A constructor emitted at module scope that calls a run-time-only helper** fails in Zig, not in Rig. The examples cover each constructor form. Add a constant context to `test/matrix.py`.
- **Large generated tables** cost Zig and Rig time. Measure the diagnostics catalog early.
- **A bare use copies the whole table.** That is correct, and the frame check counts it, but SPEC should point to `?T[..]` as the cheap form.

**Decisions to confirm (B).**

7. The rule is B-plain: values that copy, made of literals, whole constants, operators, arrays, and constructors.
8. Text in a table is `Static`. A `?String` field is rejected, with a hint.
9. A vector constant comes only from `.splat` or the array constructor, with no operators.
10. A part of a constant is read at run time. It never folds, and never appears inside another constant's value. The bug above is fixed first.
11. Owning constants and function values stay out of scope. Computed tables wait for compile-time functions.
