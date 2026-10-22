# Rig today: the de-facto standard library, and what blocks a real one

Repo `/Users/shreeve/Data/Code/rig`, `main` at `5a40305`. Everything below was read from source or
confirmed by a probe in `scratchpad/stdlib/rig/` (probe file names are given as `[gN]`).
Line counts are for the functions that exist only for a built-in. They also count the
scattered one-line `if sym == ctx.vec_sym_id` checks, measured by grep.

---

## 1. Inventory of the built-in library surface

Rig has no library written in Rig. Its whole "standard library" is:

- **(a)** four built-in generic types and one enum, registered as symbols in every module scope
  (`resolve.registerBuiltins`);
- **(b)** methods that have no symbol, special-cased by name in typecheck and emit;
- **(c)** three free functions that user code can hide (`print`, `replace`, `swap`);
- **(d)** language-level operations on primitives;
- **(e)** the Zig `@builtins`;
- **(f)** `src/runtime.zig` (1811 lines, including ~390 lines of unit tests), written verbatim into
  every package as `rig/runtime.zig`.

### 1.1 Built-in generic types (symbols with registered method fields)

| Type | Member (signature as registered or checked) | Implemented in | Compiler cost |
|---|---|---|---|
| **`Vec[T]`** | `Vec()` typed by context; `Vec[T]()`; `Vec(capacity: n)` | typecheck `checkVecConstruction` (23 lines; kwarg-only) and a special error for a bare `Vec()`; emit `emitVecConstruction` (10) → `rig.Vec(T).empty` / `.initCapacity(n)` | ~35 |
| | `push(!self, x: T)` | registered field `.write`; ordinary method path; runtime `Vec.push` | 1 registration line |
| | `pop(!self) -> T?` | registered; runtime `Vec.pop` | 1 |
| | `clear(!self)` | registered; runtime `Vec.clear` | 1 |
| | `get(?self, i: Int) -> T?` | registered, plus a typecheck special case that rejects it for an owning `T` | 1 + ~6 |
| | `v.len` (field, `Int`) | typecheck `.len` handling; emit `hasLen` → `rig.len(v.len)` | shared with arrays, slices and String |
| | `v[i]`, `v[i] = x`, `v[i].f = x` (Copy `T` only) | typecheck index path; runtime `at` / `slot` / `constSlot` | index machinery |
| | `?v[a..b]`, `!v[a..b]` (plain-data `T` only) | slice machinery; runtime `slice` / `sliceMut` / `items()` | shared |
| | `for x in ?v / !v / <v` | loop machinery; ownership `isResourceVec` (borrowed slot); runtime `IntoIter` | shared |
| | `!v.copy/fill/swap`, `v.read/!v.write[T,e]` | element methods, see 1.2 | shared |
| | Element rule: Copy, plain data, `*T`, `~T` or `Box[T]` only | resolve `builtinElementError` (9) | |
| | **Vec total** | ~77 Vec-specific lines across resolve, sema, typecheck, ownership and emit; runtime `Vec` is 115 lines | |
| **`Cell[T]`** | `Cell(v)` | ordinary generic construction; emit `rig.Cell(T){.value=v}` | |
| | `get(?self) -> T` (plain `T` only) | registered, plus a typecheck check that rejects it when `T` owns | 1 + ~5 |
| | `set(?self, v: T)` | registered `.read`, plus a typecheck `requireAccess(.set_cell)`; emit `@constCast(&c).set(v)` | 1 + ~25 |
| | `replace(?self, v: T) -> T` | as for `set` | 1 |
| | For a `Cell[Vec[E]]`: `push`, `pop`, `clear`, `len`, `c[i]`, `c[i] = x`, `get(i)`. These are **not** registered; they are a hard-coded forwarding table | typecheck `cellVecCall` (33), `cellVecElement` (9), `cell_vec_elem` place tracking; emit `vecPush`/`vecPop`/`vecClear`/`vecGet` name table (16), `emitCellPtr` (11), `isCellVecTy` (7); runtime `Cell.vec*` (7 methods) | ~100 |
| | Rule: `T` is Copy, plain, or has drop glue; a Cell must be in mutable storage | resolve (3), typecheck `requireCellPlace` (15), sema `holdsCell` / contents | |
| | **Cell total** | ~63 lines of Cell-specific references; runtime `Cell` is 75 lines | |
| **`Box[T]`** | `Box(v)` | emit `emitBoxConstruction` (8) → `rig.Box(T).init(v)` | |
| | `<b.unbox() -> T` | registered `.value`; emit `emitUnboxed` (9) | |
| | `b.f` and `b.m()` reach the boxed value; `?b` / `!b` lend the value; `match ?b` | sema `boxedType` / `boxedNominal` / `unwrapAccess`; typecheck `boxLent` (18) | |
| | **Box total** | ~55 Box-specific lines; runtime `Box` is 50 lines (with the drop queue) | |
| **`Signal[T]`** | `*Signal(v)`; a stack Signal is rejected | typecheck `stack_signal`; emit `emitSignalConstruction` (8) | |
| | `get(?self) -> T`, `set(?self, v: T)`, `subscribe(?self, cb: *sub())` | registered; runtime `Signal` (60 lines; reentrant `set` is queued) | |
| | **Signal total** | ~42 lines of references | |
| **`Endian`** | `.little`, `.big` | resolve registers it as an enum (14 lines); sema `importType` maps each module's copy; runtime `Endian` | ~21 refs |

### 1.2 Built-in methods with no symbol (hard-coded by name)

| Member | Receivers | Where | Cost |
|---|---|---|---|
| `!xs.copy(src: []T)`, `!xs.fill(v: T)`, `!xs.swap(i, j)` | `![]T`, arrays, `Vec` | sema `ElemOp` / `ElemCall` (12); typecheck `elemsCall` (60), `writesElements` (21), `checkIndexArg` (9); ownership `storesNothing` (5); emit `emitElemCall` (30), `emitElems` (16); runtime `copy` / `fill` / `swap` (~20) | ~170 |
| `bytes.read[T, e](at) -> T`, `!bytes.write[T, e](at, v)` | `[]U8`, `![]U8`, `[N]U8`, `Vec[U8]`, String (read only) | typecheck `bytesCall` (35), `checkOffsetArg` (16); emit (in `emitElemCall`); runtime `readInt`, `writeInt`, `byteOffset`, `zigEndian` (~35) | ~90 |
| `xs.get(i) -> T?` | array, slice, String (as `U8?`) | typecheck `sequenceGet` (21); emit → `rig.elementAt` (~7); runtime `elementAt` (~10) | ~40 |
| `.len` | array, slice, String, Vec, `Cell[Vec]` | typecheck (~5 sites), emit `hasLen` (7) and a `Cell[Vec]` case | ~20 |
| `w.upgrade() -> *T?` | `~T` | typecheck inline in `synthMemberCall` (22); runtime `WeakHandle.upgrade` | ~30 |
| `T.min`, `T.max` | numeric types and their aliases | sema `intRange` (~15); typecheck `typeMember` and `floatLimit` (~25); emit (~10, floats become `std.math.floatMax`) | ~50 |

### 1.3 Free functions (special only while no declaration hides the name)

| Function | Signature | Where | Cost |
|---|---|---|---|
| `print(a, b, ...)` | any number of values, space-separated, **always followed by a newline**, stdout only; no kwargs; rejects `[]U8` | typecheck `checkPrint` (30), `holdsByteSlice` (22); ownership `isPrint` (~6); emit `emitPrint` (12), `isPrintCall` (4); runtime `print`, `writeValue`, `writeFields`, `writeList`, `stdout`, `flush`, `isString`, `rigTypeName` (~130) | ~200 |
| `replace(!place, v) -> T` | write-borrowed place, returns the old value | typecheck `checkReplace` / `swapPlace` (23); ownership `swapBuiltin` and `walkSwapCall` (~60); emit `emitSwapCall` / `builtinCall` (16); runtime `replace` | ~100, shared with `swap` |
| `swap(!a, !b)` | two places of one type | as above; runtime `swapPlaces` | shared |
| Name-hiding rule | `sema.isBuiltinCallName`, plus separate `symbolOf(callee) == null` checks in typecheck, ownership and emit | 4 places | |

### 1.4 Language-level operations on primitives (not methods)

- **Numeric types.** `Int` (=`I64`), `Float` (=`F64`), `I8`–`I128`, `U8`–`U128`, `F32`, `Bool`, `Void`.
- **Conversions.** `I32(x)`, `Float(n)` and so on are checked: a panic at run time, or a compile-time
  error for a constant. Also through an alias. Cost: typecheck `checkConversion` (31) and `aliasCall`;
  emit `emitConversion` (40); runtime `notNan`.
- **Arithmetic.** Checked `+ - * / %`; wrapping `+% -% *%` (and `op=`); `& | ^ << >>`.
  There is **no unary bitwise NOT** [g12].
- **String** is a `[]const u8` view and a Copy value. It supports:
  - `.len`, `s[i]` → `U8`, `s.get(i)` → `U8?`, `s[a..b]`, `for b in s`;
  - `==` / `!=` by content and `< <= > >=` by bytes (runtime `eql`, `compare`);
  - `read[T, e]`.

  There is **no other String operation**: no concat, find, split, trim, parse, int-to-text, or
  bytes→String [g9, g9b, g9d].
- **Handles.** `*x` (runtime `rcNew`), `+h` (`cloneStrong` / `cloneOptional`), `~h` (`weakRef`),
  `-x` (`drop`), `<x` (`take`).
- **Equality and ordering** on generic `T` are allowed and checked per instance (runtime `eql`,
  `compare`, `div`).

### 1.5 `@builtins`

- **Safe anywhere:** `@sizeOf`, `@alignOf`, `@typeName`, and `@TypeOf` (only inside those three).
- **Only inside `raw`:** `@bitCast`, `@intCast`, `@floatCast`, `@truncate`, `@intFromFloat`,
  `@floatFromInt`, `@enumFromInt`. All of these are number↔number only.
- **Where:** a hard-coded enum in typecheck `Builtin`, with `synthBuiltin` (58), `castProblem` (27)
  and `builtinTypeArg` (20).
- **Side finding:** `@sizeOf(Box[Node])` is rejected with "unsupported type expression". A generic
  instance only works through a `type` alias or `@TypeOf` [g8].

### 1.6 FFI

- **`extern fun` / `extern sub` / `extern name: T`** take only integers, floats and `Bool`.
  They are callable only inside `raw` and emitted as `extern "c" fn ...` with `-lc`.
- **Works:** `abs`, `getpid`, `sqrt` and `exit` [g7b, g20, g25c].
- **Rejected:** `String`, `[]U8` and `*U8` [g6, g7].

### 1.7 What is *not* there at all

- **Input.** No stdin, files, argv, env, time or random.
- **Output beyond `print`.** No stderr, no way to print without a newline, no printing of bytes.
- **Failure and exit.** No `panic`, `assert` or `unreachable` [g25]. No exit status, except
  `extern exit` in raw.
- **Vec operations.** No `insert`, `remove`, `sort`, `capacity`, `contains`, `reserve` or
  `truncate` [g23].
- **Text and hashing.** No heap text type, no hashing, no maps or sets, no formatting to a string.

---

## 2. How built-ins are wired, end to end

### `!v.push(x)` on a `Vec[Int]` [wire.rig]

1. **Parse.** `(call (member (write v) push) x)`. Nothing is built-in at this stage.
2. **Resolve.** `registerBuiltins` has already put `Vec` into the module scope. It is a
   `generic_type` symbol with type param `T` and a `fields` array holding
   `push: fun(!Vec[T], T)`, with `receiver = .write` and `decl_pos = builtin_decl_pos`.
   `ctx.vec_sym_id` is recorded for all later identity checks.
   `builtinElementError` validates `T` whenever `Vec[X]` is resolved.
3. **Typecheck** (`synthMemberCall`) walks a chain of hard-coded special cases before the generic path:
   - `elemsCall` handles `copy/fill/swap/read/write`;
   - `upgrade`;
   - `type_var` is rejected;
   - `cellVecCall` handles a `Cell[Vec]`;
   - `sequenceGet` handles `get` on arrays, slices and Strings.

   Only then does `findMethod` find the registered `push` field. From there it is the **same path
   as a user generic method**:
   - `checkReceiverSigil` / `checkReceiverMode` require `!v`;
   - `instantiateCall` substitutes `T = Int`;
   - `checkArgs` checks `x` against `Int`.

   Cell's `set`/`replace`/`get` and Vec's `get` add small inline checks keyed on
   `resolved.nominal_sym`.
4. **Ownership.** The checker reads the callee's function type and receiver mode, as for any
   method:
   - `!v` is a write borrow for the call;
   - a by-value `T` parameter moves an owning argument, so `<x` or `+x` is required.

   Vec-specific code covers only the loops (`isResourceVec`: borrowed slots), diagnostics naming
   (`builtinName`) and the kinds of owning values.
5. **Emit.** `emitCallDirect` walks its own chain of special cases:
   - `print`;
   - `replace/swap`;
   - numeric conversion;
   - alias construction;
   - Vec, Box or Signal construction;
   - FnRef / closure calls;
   - the `Cell[Vec]` name table;
   - sequence `get`;
   - Cell `set/replace`, emitted as `@constCast`.

   A plain `v.push(3)` falls through to the generic `emitExpr(callee)(args)` and becomes
   **`v.push(3);`**, a direct Zig method call on `rig.Vec(i64)`. The type is spelled `rig.Vec(i64)`
   because `emitTypeTy` maps built-in symbols to `rig.*`.
6. **Runtime.** `rig.Vec(T).push` reserves (`realloc` through `defaultAllocator`, which is
   leak-checked in Debug) and stores. Drop glue is `rig.drop(&v)` → `dropElement` →
   `Vec.__rig_drop`.

### What adding one built-in costs

- **Cheap case: a method that fits an ordinary signature** (`Vec.insert(!self, i: Int, x: T)`):
  - one `method(...)` line in `registerBuiltins`, plus updating the resolve unit test's field
    count (it asserts `4`);
  - ~8 lines in `runtime.zig`, plus a runtime unit test;
  - a row in the SPEC §10 table, a doc example with output (Rule 1), and a behavior test;
  - zero lines in typecheck, ownership or emit, **provided** the runtime's Zig method has the same
    name and accepts the emitted argument types. For example, the index arrives as `i64`, so the
    runtime must call `index()`.
- **Expensive case: anything outside that pattern.** Each costs 50–200 lines spread over 3–5
  files, with matching special cases in typecheck, ownership and emit that must agree:
  - a method on a type with no symbol (String, slices, arrays): everything `elemsCall` and
    `sequenceGet` do by hand;
  - a method with compile-time arguments (`read[T, e]`);
  - a method whose ownership is not "by value in, by value out", such as lending an element as
    `?T` or `!T`, or `Cell[Vec]` forwarding;
  - a free function (`print`, `replace`);
  - a constructor with kwargs (`Vec(capacity:)`);
  - an element rule (`builtinElementError`).

### Does this approach scale to a real standard library?

No.

- **What does scale.** The generic-symbol mechanism (register fields, get instantiation, arg
  checking, receiver modes and ownership for free) is sound. It would scale for container methods
  with ordinary signatures.
- **What does not scale:**
  - Every API is hand-typed in Zig inside the compiler, twice: as a `TypeId` signature in
    `resolve.zig` and as an implementation in `runtime.zig`. It bypasses the checkers entirely.
    INTERNALS calls the runtime "trusted code … kept small and reviewed".
  - A standard library of strings, I/O, maps and formatting would grow that trusted, unchecked
    surface by 10–50×.
  - Anything with interesting ownership lands in the special-case chains of `synthMemberCall` and
    `emitCallDirect`, which already have ~10 name-keyed branches each.
- **The scalable shape:**
  - keep a *small* substrate in the compiler: `Vec`, `Box`, `Cell`, handles, bytes, a few
    intrinsics for OS I/O and allocation;
  - write everything else in Rig modules, checked by the same checkers as user code;
  - that needs the language gaps in §4 closed, and a module path for `std` (§3).

---

## 3. Shipping options

### How `use` works today (`src/modules.zig`)

- **Grammar.** `use NAME`, a single identifier. There is no `std.text`, no `as`, no `pub use`
  [g19, g19b, g19c].
- **Resolution.** `resolveUse` reads `<root dir>/NAME.rig`; the real basename must match exactly.
  `by_name` dedups by bare name, so a name denotes one file for the whole program.
- **Emission.**
  - Each module emits to a flat `<name>.zig` in one package dir;
  - the root emits to `__rig_main.zig`;
  - the runtime is written to `rig/runtime.zig` from `emit.runtime_source = @embedFile("runtime.zig")`
    (`main.emitPackage`);
  - importers write `const io = @import("io.zig");`.
- **Reserved names.** The `__rig` prefix is reserved for module names.
- **Checking.** Each module is fully parsed and checked on every compile. A module whose import
  fails is not checked.

### Option A: Rig sources embedded in the binary

This is the same mechanism the runtime already uses: a `std/*.rig` tree in the repo, embedded by
`build.zig` as a name→source table.

- **Pros:**
  - one self-contained binary;
  - the std is version-locked to the compiler and runtime it was tested with;
  - hermetic builds;
  - `./test/run` exercises exactly what ships;
  - no install layout.
- **Cons:**
  - changing std requires rebuilding `rig`;
  - users can't open the source unless the CLI exposes it (`rig std path|dump`);
  - diagnostics need a virtual path (`<std>/text.rig`);
  - an LSP needs the same virtual FS.

### Option B: a `std/` directory found next to the binary

Located at `bin/../lib/rig/std/` via `std.process.executablePath`, with a `$RIG_STD` override, as
Zig does with `lib/` and `--zig-lib-dir`.

- **Pros:**
  - real files for diagnostics, the editor and go-to-definition;
  - editable without rebuilding.
- **Cons:**
  - install and relocation logic;
  - version skew between binary and std;
  - `bin/rig` in the repo would need to find `../std` in dev.

### Option C: hybrid (recommended)

- Keep sources in `std/` in the repo.
- Embed them in the binary as the default, so one file just works.
- Let `RIG_STD=/path` (or `--std-dir`) override for std development.
- Add `rig std` to print or extract the location.
- Show diagnostics under `std/<mod>.rig`.

This matches how the runtime is shipped and keeps Rule 1: the suite runs the embedded copy.

### `use std.text` vs `use text`

Recommend **`use std.text`**, bound locally as `text` (the last component), with `std` a reserved
first component.

- **Against flat `use text`:**
  - today a name denotes one file *for the whole program*, so a user `text.rig` would collide with
    std's `text.rig`;
  - it would force a shadowing rule and silent behavior changes when std adds a module.
- **For a qualified path:**
  - it is unambiguous;
  - it grows into the roadmap's open question, "modules in subdirectories" (`use net.http` →
    `net/http.rig`).

### What `modules.zig` (and the grammar and emitter) would need

1. **Grammar** (`rig.grammar`, regenerate parser): `use NAME(.NAME)*`, optionally `as ALIAS`.
   The IR `use` node gets a path list plus an optional alias.
2. **`resolveUse`:**
   - when the first component is `std`, read from the embedded table, or from `$RIG_STD`;
   - otherwise join the components as subdirectories of the root dir;
   - keep the exact-basename check.
3. **Module identity:**
   - `Module.name` becomes the qualified name (`std.text`), and `by_name` is keyed by it;
   - `Import.local_name` is the alias or last component. The data structure already separates
     `local_name` from `target`;
   - two imports whose local names collide in one module must be an error.
4. **Emission.** `out_basename` must be unique and legal:
   - use a mangled name (`std.text` → `__rig_std_text.zig` under the reserved prefix) or a
     `std/text.zig` subdirectory;
   - the emitter's `@import("…")` must use it, and `module_names` maps local name → file.
5. **`pub use` re-export** is *optional*. It is needed only if std wants a facade (`std.io`
   re-exporting `std.fs.File`). It needs sema to forward another module's `pub` members through
   `ImportEntry`. Avoid it at first.
6. **A bridge from Rig std to the Zig runtime.** Today Rig code can reach Zig only through
   `extern "c"`, and only with numbers. A std module needs either:
   - FFI with slices and pointers (roadmap: `[]U8` → ptr+len), or
   - a privileged intrinsic form allowed only in std modules (e.g. `extern "rig" fun write(fd: I32, b: []U8)`),
     lowering to a `rig.*` runtime call. The runtime then provides a thin OS layer (write, read,
     open, args, env, clock) and nothing more.
7. **Cost control.**
   - Std modules are parsed and checked on every compile, and generic bodies are checked per
     instance. That is fine while std is small.
   - Later: cache checked std modules, or check only the modules actually `use`d, which is
     already what happens.

---

## 4. Language gaps that block writing the standard library in Rig

Every item was verified by a probe.

| # | Gap | Probe result | What it blocks | Workaround |
|---|---|---|---|---|
| **1** | **No string building.** No `+`/concat, no bytes→String, no int/float→text, no interpolation. `String` is only a view of literals or of slices of them | `a + "cd"`: "operator `+` requires numeric operands; got `String`" [g9]. `s: String = ?buf[..]`: "expected `String`, got `[]U8`" [g9b]. `@bitCast` to String is rejected [g9d]. `"x = {x}"` is a plain literal [g9c] | All of `text`/strings; formatting; `to_string`; paths; parsers that return text; error messages; line-oriented I/O. A `Text` type is also owning, so it runs into gap 5 | None in safe or raw Rig: a runtime String cannot be produced at all |
| **2** | **C FFI only for integers, floats and `Bool`; no raw pointers** | `extern fun write(fd: I32, buf: []U8, n: U64)`, `puts(s: String)` and `malloc -> *U8` are all rejected: "only integers, floats, and Bool cross the C boundary" [g6, g7]. `abs`, `getpid`, `sqrt` and `exit` work [g7b, g20, g25c] | All I/O (files, stdin, stdout bytes, sockets), argv and env, time structs, OS APIs, and any allocator or low-level container. Every such API must be hand-built into `runtime.zig` and the compiler | Math (libm) and scalar syscalls only |
| **3** | **No methods or fields on a generic `T`** (no traits or bounds) | "a generic parameter `T` has no methods" and "… has no fields" [g1]. `U64(k)` for `k: T` is rejected [g15]. `==`, `<`, `+` on `T` do work, checked per instance [g14b] | `HashMap[K,V]` and `Set[T]` (no generic hash), generic `Display`/format, sort-by-key, iterator adapters over user iterators, and any "protocol" (`Reader`/`Writer`) | Pass explicit `?fun(K) -> U64` dictionaries; this works, including in generic methods [g18]. Clunky for every call site |
| **4** | **Cannot index or lend elements of a Vec of owning values**, and a generic container cannot lend `?T` for an owning `T` | `xs[0]` and `?xs[0]` on `Vec[*N]`: "indexing a `Vec[*N]` would copy an owning element out" [g2]; the same for `Vec[Box[N]]` [g2b]. `replace(!v[0], …)` is rejected [g24]. `List[T].at(?self,i) -> ?T` works for plain `T` but rejects the `List[*P]` instance [g22, g22b] | Random access into any container of resources: a map with owning values (`get(k) -> ?V`), graphs, arenas, slot maps, `Vec[Text]` lookups | Scan with `for x in ?v`; `swap` plus `pop` to take out (user-written `insert_at`/`remove_at` work [g24]); no in-place replace |
| **5** | **`Vec[Vec[T]]`, and Vec of owning structs, rejected; no arrays of owning values** | `Vec[Vec[Int]]` and `Vec[Row]` (with Row holding a Vec): "`Vec[T]` requires `T` to be a Copy type … or a box" [g3, g3b] | Nested collections: hash buckets, adjacency lists, `Vec[Text]`, `Vec[File]`, `Vec[Map]`. This becomes critical the moment `Text` exists | `Vec[Box[T]]` works [g3b, g3c], at one extra allocation and one pointer hop per element |
| **6** | **`drop` bodies only on non-generic structs** | "`drop` bodies are only for non-generic structs, not generic structs" and "… not enums" [g13, g13b] | Generic RAII wrappers (`Guard[T]`, `Pool[T]`, `Arena[T]`, a `Mutex[T]` later) and resource enums. Collections built on `Vec`/`Box` get drop glue automatically, so this bites mainly once raw memory (gap 2) exists | A non-generic wrapper per concrete type |
| **7** | **Typed error sets missing; error names are global; errors carry no payload** | `-> Int!ParseError` does not parse [g5]. `io.IoError.eof == parse.ParseError.eof` is true across modules [g5]. A caught `err` has type `error` and cannot be bound to `A` [g5b]. `error E` with `bad(pos: Int)`: "only enums declare payload variants" [g5c] | Precise std error APIs. Two std modules that both say `.eof` or `.not_found` are indistinguishable, and there is no errno, byte position or path in an error | Return an enum result or `T?`, plus a separate out-parameter for details |
| **8** | **`print` always adds a newline; stdout only; kwargs rejected; `[]U8` rejected** | "`print` takes no keyword arguments" [g10] | Prompts, progress output, building a line from pieces, stderr diagnostics, binary output | None (subsumed by gaps 1 and 2) |
| **9** | **A `*T` does not lend as `?T`** (a Box does) | `peek(?h)` with `h: *U`: "expected `?U`, got `?*U`"; `peek(h)` fails the same way [g4]. `?Box[U]` → `?U` works [g4c]. Methods and fields through `*T` work [g4b] | Library functions taking `?T` cannot be called with handles, so APIs are duplicated (`?T` and `?*T`) or forced into methods | Methods on the type; a separate `?*T` overload |
| **10** | **`Box[T]?` is 16 bytes** (`*T?` is 8) | `@sizeOf(Box[Node]) = 8`, `Box[Node]? = 16`, `*Node? = 8`; a `Node{k, next: Box[Node]?}` is 24 bytes [g8]. Cause: `rig.Box` is a struct wrapping `*T`, and Zig's `?struct` doesn't get the null-pointer niche | Performance of linked lists and trees (+8 bytes per link). Not a functional blocker | Emit `Box` as a bare `*T`, or emit `?*T` for an optional Box |
| **11** | **No char or byte literal** | `'a'` is a raw String [g11, g11c]. `"a"[0]` is not a compile-time constant [g16], so it cannot be a module constant or a match pattern | Lexers, parsers and text utilities have to write `97 =>` in `match` | Integer codes; `"a"[0]` at run time |
| **12** | **No bitwise NOT** | `~x` is the weak-handle sigil: "`~` weak reference requires a shared handle" [g12] | Bit manipulation (masks, hashing, bitsets). Ergonomic only | `x ^ U8.max` for unsigned, `x ^ -1` for signed [g12b, g12c] |

### Ranked by how much of a standard library each blocks

1. **No string building (1)**
   - blocks the entire `text` / `fmt` area and all textual I/O;
   - there is no workaround at all.
2. **FFI limited to scalars, with no raw pointers (2)**
   - blocks all I/O, OS, env, time and allocators;
   - without it every such API must be compiler- or runtime-resident, which is exactly the
     non-scalable path;
   - a narrower fix is enough to unblock I/O: `[]U8` → ptr+len (already settled on the roadmap),
     or std-only runtime intrinsics.
3. **No containers of owning values in place: gaps (4) and (5) together**
   - blocks every non-trivial collection that holds resources: maps with owning values,
     `Vec[Text]`, nested Vecs;
   - the roadmap has already settled that owning elements are lent as `?v[i]` and `!v[i]`;
   - `Vec[Box[T]]` is a costly partial workaround.
4. **No methods on `T` / traits (3)**
   - blocks generic hashing, formatting and protocols;
   - explicit closure dictionaries are a working but clunky fallback, so HashMap is *writable*,
     just not nicely.
5. **`print`: no newline control, no stderr, no bytes (8)**
   - largely disappears once 1 and 2 land (write through a std `io` module).
6. **Error sets (7)**
   - global names and no payloads make std error APIs imprecise and collision-prone;
   - they don't stop code from being written.
7. **Generic and enum `drop` (6)**
   - matters once raw memory exists; minor before that.
8. **`*T` not lending as `?T` (9)**
   - API duplication, and a friction tax on every std function.
9. **Char or byte literal (11)**
   - ergonomics for parsing code.
10. **`Box[T]?` size (10)**
    - performance only.
11. **Bitwise NOT (12)**
    - trivial workaround.

### Smaller gaps noticed while probing

- **No `panic` / `assert` / `unreachable`** in safe code [g25, g25b]. A std needs a way to signal a
  broken invariant, and `rig test` has no assertions yet (roadmap).
- **`@sizeOf(Vec[Int])` / `@sizeOf(Box[T])`** give "unsupported type expression" [g8].
- **Module constants hold only compile-time values**, and there is no module-level state. That is
  fine for Rig style but rules out, for example, a global RNG.
- **Owned closures (`*fun`) take and return only Copy values**, which limits callback registries
  holding resources.
- **Vec has no `insert`/`remove`/`sort`/`capacity`/`contains`** [g23]. The first two *can* be
  written in Rig with `swap`, `push` and `pop`, even for owning `T` [g24]. `sort` can be written for
  plain `T` (see `examples/sort.rig` / the quicksort in SPEC §2).
- **What already works well for std authors:**
  - generic structs over `Vec[T]` (`Stack[T]` with push/pop/len works for `T = Int` and
    `T = *N`) [g14];
  - generic free functions with `==`/`<` [g14b];
  - the iterator convention `while !it.next() as x` [g21];
  - wrapping arithmetic `+% *%` for hashing [g17];
  - `read`/`write[T, e]` for binary formats;
  - `extern` visible only through `pub` wrappers, which is the right encapsulation for a std over C.
