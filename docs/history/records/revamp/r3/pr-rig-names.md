# `@name(T)` returns Rig's names

`@name(T)` now returns the type's name as Rig writes it, the exact
spelling Rig's diagnostics print, instead of the name the emitted Zig
gives it. `@name(Vec[Int])`, rejected before, works, and so does every
type argument an expression can spell (`?Point`, `Int?`, `*Node`,
`g.Wrap[Int]`); `@size` and `@align` take them too.

Decided in rig-questions.md, "`@name(T)` returns Rig's names".

## Behavior change

| Program | Before | After |
|---|---|---|
| `@name(Int)`, `@name(I64)` | `i64` | `Int` |
| `@name(Bool)` | `bool` | `Bool` |
| `@name(Float)` | `f64` | `Float` |
| `@name(U8)` | `u8` | `U8` |
| `@name(String)` | `[]const u8` | `String` |
| `@name(@type(x))`, `x: I16` | `i16` | `I16` |
| `@name(Point)` | `__rig_main.Point` | `Point` |
| `@name(geo.Point)` | `geo.Point` | `geo.Point` (`g.Point` after `use geo as g`) |
| `@name(Vec[Int])` | rejected: `unsupported type expression` | `Vec[Int]` |
| `@name(Int?)`, `@name(?Point)`, `@name(*Node)` | rejected | `Int?`, `?Point`, `*Node` |
| `name[Pair[Int, Text]]()`, with `fun name[T]() -> String: @name(T)` | `__rig_main.Pair(i64,rig.runtime.Text)` | `Pair[Int, Text]` |
| `@typeName(Bool)` inside `raw` (Zig's builtin) | `bool` | `bool` (unchanged: Zig's name) |

A diagnostic that names another module's generic type through an
aliased import now names it as written: after `use geo as g`,
`g.Wrap[Int]` (was `geo.Wrap[Int]`, the module's own name). The proxy
of a generic type was named by its module's name, while the printer
named every other imported type by the import's name; `@name` needs the
one rule, so the proxy is now named by the printer.

## Decisions

- **Aliases.** `type Byte = U8` gives `U8`: an alias is the type it
  names, as in diagnostics, and a type parameter cannot tell them apart.
- **Other modules' types** are qualified the way the module where
  `@name` is written names that module: `geo.Point`, `g.Point` after
  `use geo as g`, and a module reached only through an import by its
  own name. In a generic body that is the generic's module, so
  `geo.name[geo.Point]()` is `Point`. The root module's types are bare
  everywhere (no other module can name them).
- **Zig's `@typeName`** inside `raw` keeps Zig's meaning. SPEC says so.

## How

1. **A type known where `@name` is written**: emit writes the string
   from sema's type printer (`formatTypeMarked`, no mark).
2. **A type that holds a type parameter**: the printer writes the type
   with each type parameter marked; emit writes that spelling as a
   comptime concatenation, each parameter named per instance by
   `rig.typeName(T, __rig_names)`. So `@name(T?)`, `@name(Self)` in a
   generic type, and `@name(@type(x))` keep their own structure exactly,
   and only the instances go through the runtime.

No Rig type name is written anywhere but sema's printer (so the v0.3.0
renames need one change):

- Emit writes into every struct, enum, and union
  `pub const __rig_name = .{ .module = "geo", .name = .{ "Point" } };`,
  a generic type's spelling at its parameters
  (`.{ "Pair[", A, ", ", B, "]" }`), from the printer. This replaces the
  generic head's `_ = T;` discards (and `mentions`/`namesSelf`, which
  only computed them): the name constant names every parameter.
- A module with such a `@name` gets a table `__rig_names`, from the
  printer: its module, what each import qualifies types with, every
  built-in type (`resolve.builtinTypes`, from the same tables
  `resolveType` reads) with its Zig type and name, `Endian`, and each of
  the runtime's generic types (`Vec`, `Cell`, `Box`, `Signal`) with its
  spelling, an index per argument.
- `rig.typeName` (runtime) holds no name. It looks the instance up in
  the table or reads its `__rig_name`, and otherwise follows the Zig
  type's shape as the printer spells it: optional, error union, array,
  function (`fun(...) -> R`, `sub(...)`, `sub(...)!`), `*T` and `~T`
  (with the printer's parentheses), closures, and an error set by its
  errors' names (`mod.Set.err`). The runtime's generic types declare
  their arguments (`__rig_args`), `WeakHandle` its target (`__rig_weak`),
  `Closure` its function type (`__rig_fn`). A type parameter's instance
  holds no view or slice (the checker rejects one where a generic body
  uses it), so those shapes never reach the runtime.

The printer became a small `TypePrinter` (unchanged output but for the
proxy fix above) so that one switch serves the plain spelling, the
marked one, and a built-in type that is not interned in the module.

## Tests

- `test/behavior/types/type_names/`: every built-in type, `Endian`,
  user structs and enums, an error set, another module's struct, error
  set, and generic type (through an aliased import), user generics with
  type and value parameters, the runtime's four generic types, nested
  generics, optionals (`(Int?)?`), handles (`*Point?`, `*(Int?)`,
  `~Point?`), arrays, and function and closure types, each named where
  written and through a type parameter; the program checks the two
  agree and the expected output pins them. Also `@name(Self)` in a
  generic type, `@name(?T)`, a generic of another module naming types,
  and the view and slice shapes written directly.
- `test/cli/type_names.sh`: the name constant and the table are
  emitted, and `src/runtime.zig`'s type-name code contains no string
  literal of any name the table holds (checked to fail when one is
  added).
- `rig_builtins`, `builtin_type_args`, and SPEC §5 Builtins updated to
  Rig's names; SPEC gains an example of a generic `@name`.
- `test/reject/modules/aliased_generic_type_name/`: after `use geo as
  g`, a diagnostic names `g.Wrap[Int]` beside `g.Point`. The proxy of
  another module's generic type is now named by the printer
  (`importSymbol`), so every message that names it agrees.
- docs/INTERNALS.md: the runtime table's `typeName` row.

## Verification

- Mac, `./test/run` through heavy.sh: 2822 passed, 0 failed, 4 pending.
- pup, pup-gates at 234034bc (PUP_CORES=12): suite 2822 passed; corpus
  6930 passed; matrix 5230 programs, 0 failed; unit 127/129 (2
  skipped); oracle/doc/vocab 338 passed. All gates exit 0.
- `test/equiv.py` against main (c1ed3fd9), on pup: 9315 programs.
  `parse`, `normalize`, `facts=sema`, and `facts=storage` are identical
  for every program. `check`/`facts` differ only for the three new
  programs main rejects (`type_names`, `aliased_generic_type_name`, the
  new SPEC example). `emit` differs for 2616 programs and `pkg` for all
  (the runtime changed), as expected: every emitted struct, enum, and
  union now carries `__rig_name`, and a generic type's head lost its
  `_ = T;` discards. To show that is all, a scratch script compared
  every program's emitted Zig (every module) from both compilers with
  `__rig_name` lines, `__rig_names` tables, and generic-head discards
  removed: only 6 differ, each a program that uses `@name` or
  `@typeName` (`rig_builtins`, `builtin_type_args`, `type_names`, the
  two SPEC examples) or the new reject test.
