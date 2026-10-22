# Table/Slot build: details

Worktree `~/Data/Code/worktrees/rig/table-slot`, branch `table-slot`, from
main 3e3a88b02. Design: `A-typed-ids.md`, option B, with the owner's
defaults, and the review's nine holes (`review-table/HOLES.md`).

## What was built

- **Types.** `Slot[n]` is a type of its own kind, `Type.slot` (operand: the
  count, `ct_value` or `ct_param`), made by `resolve.slotInstance`.
  `Table[T, n]` is a built-in generic instance (`table_sym_id`, args
  `[T, n]`) with one member, `push(!@, T) -> Slot[n]`. Neither name is
  reserved: a module's own `Table`/`Slot` hides the built-in one (Trig's
  `collections.Slot[K, V]`, std's private `Table` in `__rig_builtin.rig`,
  and several tests declare such names).
- **Slot.** Plain data: `holdsIn` plain, `isCopyPrimitive`,
  `copiedByReadView`, `ordLack`, equatable and hashable by the existing
  walk. Not numeric: no arithmetic, `+%=`, ranges, lanes, `bytes.read`,
  or conversion to it. `Slot[n](x)` and an alias call `TypeId(x)` are
  rejected; `Slot[n].of(i) -> Slot[n]?` (an `ElemCall` `.from_int` whose
  `num` is the slot type, lowered to `rig.slotOf(n, i)`); `Int(s)` and any
  integer conversion. A literal meets a slot and is checked below `n` at
  every coercion site (`checkLiteralFits`, `holdsInt`, `recordAdaptedType`,
  the literal fast path); where `n` is a parameter a literal is rejected.
  A compile-time value parameter of slot type is checked the same way.
- **Table typing.** `t[s]` (`Checker.tableIndex`): a slot of the table's own
  `n` is a place with no test; an integer is tested `0 <= i < n`; a slot of
  another `n` is a type mismatch. `len`, `for x in t / ?t / !t` (0..len; a
  loop that takes slots, `<t`, is rejected), `Table()` by context or
  brackets (no arguments), no slicing, no clone, no field default.
- **Element rule** (`resolve.tableElementError`, at each written instance
  and each generic instantiation): `1 <= n <= 2^63-1`; no view; a default;
  `sema.tableFill`: `.zeros` reserves up to 64 TiB, `.made` up to 64 MiB,
  otherwise rejected. `n * size` is computed in u128, saturating.
- **Zero rule** (`sema.tableFill`, `declFill`): structural and
  conservative. Zeros: Int (any width), Bool, Slot, plain enums whose
  default variant has value 0, objects whose every field is one of those
  with a zero default as written (`0`, `false`, `.V` with value 0, `T()`
  of a zero object, `[n of 0]`), owning nothing, not unique. Never a
  float, an optional, a type-parameter field, a payload enum. Emit writes
  `pub const __rig_zeros = true;` into each such object; the runtime's
  `fillsWithZeros` mirrors the rule for Zig types (ints, bools, and that
  decl), so a generic body's `Table[T, n]` follows its instance.
- **Runtime** (`src/table.zig`, imported by runtime.zig in one block, and
  written beside it): `Table(T, n)` with `slots: [*]T` (never null),
  `len: u64`. Reserved: its own `mmap(NORESERVE)` + `MADV_NOHUGEPAGE` on
  Linux, unmapped on drop; a refused mapping panics ("the system refused
  to reserve N bytes ... (ulimit -v, or strict overcommit)"). Made: heap,
  every slot `T()`, all `n` dropped. Committed (wasm32/Windows, or
  `RIG_TABLE_FALLBACK=1` at build): holds a zeroed prefix; reads past it
  give a static zero `T` and never grow; writes grow it (saturating
  arithmetic). Debug builds: each reservation holds a 1-byte token from
  the leak checker's allocator, so a leaked table is reported.
- **Lowering.** `t[s]` -> `t.at(s)` / `t.constSlot(s).*` / `t.slot(s).*`,
  each `&slots[s]` with no test (debug asserts `s < n` as a proven test
  does; `RIG_NO_PROOFS=1` emits `atInt`, the real test). `t[i]` ->
  `t.atInt(i)` etc. `Table()` -> `rig.Table(T, n).init()`. `Slot[n]` ->
  `rig.SlotOf(n)` (u8/u16/u32/u64).
- **Ownership.** A table is an owner (glue, `isHeapBuiltin`); its slots are
  places behind it (`ownership.holdsElems` for `readsAfterIndex` and
  `inVarStorage`). `push` is a write call, so a live `?t[s]` forbids it.
  Tasks: a table moves into a task; read views share when `T` shares.

## Deviations from the design, and why

1. **`Table()` is no field default** (H1). A Zig field default is a
   comptime constant and an mmap cannot run there; lazy mapping would put
   a test back on every access. So `types: Table[Type, TYPES] = Table()`
   is rejected; a store builds its tables where it is made
   (`Store(types: Table())`). Trig's `Store.new` must do this.
2. **Floats are not zeros** (H2, coordinator's rule), so a record with a
   Float field is made eagerly.
3. **`(!t).push(x)`** when the slot is used, as for every write call whose
   value is used; `!t.push(x)` as a statement.
4. **Runtime names** `rig.SlotOf`/`rig.slotOf` (a runtime test declares a
   local `Slot`).
5. **The fallback lowering is built**, selected at build time per target,
   and forced by `RIG_TABLE_FALLBACK` for testing.
6. Emitted Zig calls `t.at(s)` rather than spelling `t.slots[s]`; the
   runtime method is `&self.slots[s]` through the many-pointer, inlined.

## Tests

`test/rig/table.rig.test`: 42 cases (18 test, 2 bomb, 20 fail, 2 code), each of
section 6 plus one or more per review hole: field default (H1),
non-zero element defaults read back correctly (H2), every literal
coercion site (H3), alias call, integer, `+%=`, `bytes.read` (H3), `n = 0`
through a generic instance and a literal with symbolic `n` (H4), no clone
(H7), a task under `seeds: 20`, a sanitized String table writing past
`len`. `test/cli/table_reserve.sh`: 22 tables of 2 GiB with one slot each
written stay under 64 MiB RSS; the same program under
`RIG_TABLE_FALLBACK=1`; `RIG_NO_PROOFS` emits the test. Docs: SPEC
"Table", CORE §5 "Tables", STD "Table and Slot", SYNTAX, ROADMAP,
INTERNALS "Tables" and the runtime table. Two new oracle rejections (the
oracle rejects the push-while-viewed programs, as the compiler does).

## Mac address space

64 GiB reservations on macOS (arm64, this Mac): at least 1,984 and fewer
than 2,048 succeeded before one was refused, so about 124-128 TiB of user address space, as on x86-64
Linux. Trig's estimate (20-40 GiB a checker, 22 checkers, under 1 TiB)
fits a hundred times over. A refused reservation panics with the message
above.

## For Trig's migration

- `Type()` must be all zeros: give `TypeKind` a zero variant (`None = 0`)
  and default `kind` to it. Otherwise `Table[Type, 1 << 26]` is made
  eagerly and rejected (2 GiB past 64 MiB), with a diagnostic naming it.
  Same for every record and link record: no Float or optional fields.
- No `= Table()` field defaults: build every table in `Store.new`.
- `TypeId(x)` no longer converts; ids enter with `TypeId.of(i)` (an alias
  of `Slot[N]` takes `.of`); `Int(t)`/`U32(t)` give the number; literal
  defaults (`mapped: TypeId = 0`) stay.
- `@store.types[Int(t)]` becomes `@store.types[t]`; minting becomes
  `(!@store.types).push(Type(...))`.
- Link pages: `Table[XLinks, N]` with zero-default `XLinks`; `has` tests the
  record against its zero.

## Suite and timing

- `swarm test/rig.rip all`: green, 9,593 jobs (core, CLI with
  `cli.table_reserve`, probes, doc, oracle).
- `rig check --time` on Trig's checker bench tree (tools/checker/bench.rig
  with src/), release builds, interleaved, fastest of 10 on a loaded Mac
  (load 7-12): 3,336 ms before, 3,382 ms after, 1.4% slower, within the
  2% noise; no pass changed shape.
