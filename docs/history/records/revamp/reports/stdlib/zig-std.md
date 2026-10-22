# Backing Rig's standard library with Zig 0.16 std

Scope: how a Rig standard library can be implemented on Zig 0.16's
`std`, which binding mechanism to use, a hand-built prototype that
proves the recommended one, and the compiler changes it needs.

Sources read: `AGENTS.md`, `WELCOME.md`, `SPEC.md` §2, §7, §10, §13–15,
`docs/INTERNALS.md` (Modules, Generics, Emit, Runtime),
`docs/zig-0.16.md`, `src/runtime.zig`, and emitted packages. The Zig std
facts come from the 0.16.0 sources at
`~/.local/share/mise/installs/zig/0.16.0/lib/std`. Every claim marked
✔ was confirmed with a `zig test` or a built program; the survey's test
files are in `scratchpad/stdlib/survey/`.

Prototype: `scratchpad/stdlib/zig/`. Run `./run.sh` there to reproduce
it.

---

## 0. Summary

- **Recommendation: (b), Zig-backed declarations ("zig extern").** A Rig
  module declares an API with full Rig ownership types but no bodies. A
  shipped `.zig` shim implements it on Zig std and the Rig runtime.
  - The emitter aliases each declaration to the shim and writes a
    compile-time check that the shim's Zig type is exactly what the Rig
    signature lowers to.
  - Callers get full ownership checking from the Rig signature, because
    the existing checker already works from signatures alone: moves,
    borrows, returned borrows, and drop glue.
  - Keep (a), hard-coded built-ins, for the substrate the checker must
    understand specially: `Cell`, `Vec`, `Box`, `Signal`, and handles.
  - Use (c), pure Rig, for the layers above the shims: helpers written
    in Rig over Zig-backed primitives, in the same modules.
- **The prototype works.**
  - A Rig program was emitted by `bin/rig emit`. Stand-in declarations
    were hand-replaced by shims:
    - `rig/std/text.zig`: `Text`, `Lines`, `trim`, `split`,
      `parse_int`, `read_file`, `read_line`.
    - `rig/std/map.zig`: `Map(K, V)` over `std.HashMapUnmanaged`,
      `sorted_keys`, and `sort_by` with a Rig closure.
    - `rig/std/os.zig`: `args`, `env`.
    - `rig/std/boundary.zig`: the signature and kind checks.
  - It builds and runs in Debug with Rig's leak checker (exit 0, no
    leaks) and in ReleaseSafe, with identical output.
  - Six deliberately broken shims are caught:
    - three leaks, found by the leak checker (exit 1);
    - a parameter type mismatch, an undeclared error name, and a
      type-kind mismatch, each a compile error from the boundary checks.
- **The key soundness finding.** A Zig-backed generic has no Rig body,
  so the checker cannot infer its type-parameter requirements.
  - The prototype shows the danger: `Map[Int, *Node].get` copies a
    handle out of the map. `rig check` accepts it, and the program has a
    use-after-free that nothing detects.
  - Zig-backed declarations must therefore **declare** their
    requirements (`K: hash`, `V: plain` on `get`), and the checker must
    enforce them per method.
- **Language gaps the stdlib exposes:**
  - **`String` is a Copy, static byte slice.** No dynamic text can ever
    be a `String`. Owned text must be a new owning type (`Text`).
  - **Its borrowed view needs a printable text-view type.** The
    prototype uses `[]U8`, which `print` rejects.
  - **`Vec` cannot hold an owning struct**, so a list of owned texts
    must be `Vec[Box[Text]]`.
  - **A `?K` parameter makes callers write `?w`**, even for Copy values,
    and a literal cannot be lent at all (`first(?"a")` is rejected).
  - **Zig 0.16 has no global argv.** The emitted `main` must take
    `std.process.Init.Minimal`.

---

## 1. Constraints from today's Rig

These facts shape every choice below.

| Fact | Where | Consequence for a stdlib |
|---|---|---|
| `String` is `[]const u8`, a **Copy** value (SPEC §2). Only literals, slices of Strings, and process-lifetime bytes (argv, environment) are Strings | SPEC §2 | A String can never point into memory that is freed, so a function may return a `String` only if its bytes live for the whole process. `trim(String) -> String` and `split(String, String) -> Vec[String]` are safe. Anything from a file, stdin, formatting, or JSON is not |
| Owned bytes today are `Vec[U8]`. A view is `?v[..]`, a `[]U8` borrow | SPEC §2 Slices | A view is tracked by the borrow checker, but `print` rejects a value holding `[]U8` (SPEC §17) |
| Vec elements are Copy values, plain data, handles, or boxes; an owning struct is rejected | SPEC §10 | `Vec[Text]` is illegal; use `Vec[Box[Text]]` or `Vec[*Text]` |
| Borrows are second-class. A function may return a borrow only of what its caller lent, and "the result then borrows from every borrowed argument of the call" | SPEC §7 | **Signatures alone give full borrow checking of a body-less function.** A Zig-backed `fun view(?self) -> []U8` is checked exactly like a Rig one |
| `T!` lowers to `anyerror!T`. Errors are identified by name only, and `catch \|e\|` may match any name some visible error set declares | SPEC §13 | A shim may fail only with names the Rig module declares, or Rig code cannot match them |
| One allocator, `rig.defaultAllocator()`. Debug builds use `LeakChecker` over `smp_allocator` (optionally `DebugAllocator`); release builds use `smp_allocator`. Allocation failure panics. No container stores an allocator | runtime.zig:1037 | Shims reach it with the same call, so the leak checker sees their allocations too. `error.OutOfMemory` becomes a panic, never a Rig error |
| Drop glue dispatches on `@hasDecl(T, "__rig_drop")` (`needsDrop`, `dropElement`); `print` calls `__rig_print`; `ReadBorrow(T)` chooses a copy or a `*const T` | runtime.zig:40–135, 1386 | **A shim type joins drop glue, `print`, and generic borrows just by declaring these hooks.** No runtime change is needed |
| Emitted `main` is `pub fn main() void` (or `anyerror!void`). The runtime's Io is `std.Io.Threaded.global_single_threaded.io()`, whose allocator is `failing` | runtime.zig:1205 | Enough for files, stdio, clocks, and entropy, but not argv or process spawning (§2.6) |
| Generic types are Zig type functions and generic functions take `comptime T: type` first. Zig memoizes instances | INTERNALS Emit | A shim `Map(K, V)` instantiates exactly as a Rig generic does |
| Generic requirements are *inferred from bodies* (`generic_requirements`: arithmetic, `==`, ordering, `plain`, …) and checked per instance | INTERNALS Generics | A body-less generic has no requirements unless they are declared (§4.3) |

### The boundary type map (confirmed by emitting)

The table below is what `bin/rig emit` produces today. It is the
calling convention a shim must follow.

| Rig | Zig at the boundary | Notes |
|---|---|---|
| `Int`, `Float`, `U8`…, `Bool` | `i64`, `f64`, `u8`…, `bool` | `rig.len(usize)` turns a length into `Int` |
| `String` | `[]const u8` | Static or process-lifetime bytes only |
| `[]T` / `![]T` | `[]const T` / `[]T` | A read or write borrow; plain-data `T` only |
| `x: T`, owning `T`, by value | `T` | **The callee owns it.** Emitted Rig bodies do `var k = arg; defer rig.drop(&k)`, so a shim must store it or `rig.drop` it exactly once |
| `?T` | a copy for scalars and views (number, `Bool`, plain enum, error, slice, function, optionals of those); `*const T` otherwise; `rig.ReadBorrow(T)` in generic code | Read through `rig.borrowed(T, b)` |
| `!T`, `!self` | `*T` | |
| `?self` | `*const Self` | Even for small structs |
| `T?` | `?T` | |
| `T!`, fallible `sub` | `anyerror!T`, `anyerror!void` | A shim may return a narrower `E!T` (§3.2) |
| `Text?!` | `anyerror!?Text` | |
| `Vec[T]`, `Box[T]`, `Cell[T]` | `rig.Vec(T)`, `rig.Box(T)`, `rig.Cell(T)` | |
| `*T`, `~T` | `*rig.RcBox(T)`, `rig.WeakHandle(T)` | |
| `?fun(A, B) -> R` | `rig.FnRef(&.{ A, B }, R)` | Call with `f.call(.{ a, b })` |
| `*fun(A) -> R` | `*rig.RcBox(rig.Closure(&.{ A }, R))` | Call with `c.value.invoke(.{ a })` |
| `error E` | `pub const E = error{ ... }` | |
| `Map[K, V]` (generic type) | `Map(K', V')` | Methods keep the receiver first; a generic function's type arguments come first: `sorted_keys([]const u8, i64, &m)` |

---

## 2. Survey: Zig 0.16 std for each stdlib area

Each subsection gives the Zig 0.16 backing for one area and how it maps
to Rig.

Convention across 0.16: **containers are unmanaged.** You initialize
with `.empty` (not `.{}`) and pass the allocator to every call that
allocates and to `deinit`. The managed forms that survive are:

- `std.array_list.Managed`, deprecated;
- the `HashMap` / `AutoHashMap` / `StringHashMap` wrappers, still
  present and not deprecated.

Rig should use the unmanaged forms with `rig.defaultAllocator()` and
never store the allocator. That matches runtime.zig, where no box, Vec,
or closure stores one.

### 2.1 Growable arrays

| Rig feature | Zig 0.16 backing | Allocator, errors | Gotchas |
|---|---|---|---|
| `Vec[T]` (today) | `rig.Vec(T)` (own buffer, `realloc`) | global; OOM panics | Could be rebuilt on `std.ArrayList(T)`, but Rig's Vec has element-drop semantics (drops in reverse, `IntoIter`) that ArrayList lacks. **Keep `rig.Vec`** and use ArrayList inside shims |
| `Text` (new, owned bytes) | `std.ArrayList(u8)`: `append`, `appendSlice`, `insert`, `pop() ?T` (✔ returns null when empty; `popOrNull` is gone), `orderedRemove` / `swapRemove`, `toOwnedSlice(gpa)` (the list resets ✔), `fromOwnedSlice(slice)`, `print(gpa, fmt, args)` (u8 lists), `clearRetainingCapacity`, `addOne` | `Allocator.Error` = `error{OutOfMemory}`, which becomes a panic | `std.ArrayListUnmanaged` is a deprecated alias of `std.ArrayList`. There is no `.writer()`: use `list.print` or `std.Io.Writer.Allocating.fromArrayList(gpa, &list)` |
| struct-of-arrays (later) | `std.MultiArrayList(T)`: `.empty`, `append(gpa, x)`, `slice().items(.field)`, `deinit(gpa)` | unmanaged | `swapRemove` and `orderedRemove` return **void**; `toOwnedSlice()` takes no gpa |
| Deque, priority queue, bit set | `std.Deque(T)`, `std.PriorityQueue(T, Ctx, lessThan)`, `std.DynamicBitSetUnmanaged` | unmanaged, `.empty` | `BoundedArray` and `SegmentedList` are gone |

### 2.2 Hash maps

| Rig feature | Zig 0.16 backing | Notes |
|---|---|---|
| `Map[K, V]` | `std.HashMapUnmanaged(K, V, Ctx, default_max_load_percentage /* 80 */)` | `.empty`, `deinit(gpa)`. `put`, `getOrPut` (`{key_ptr, value_ptr, found_existing}`), `fetchPut`, and `putNoClobber` take `gpa` and return `Allocator.Error!…`. `get` (`?V`), `getPtr`, `contains`, `remove` (`bool`), `fetchRemove` (`?KV`), `count() u32`, `iterator`, `keyIterator`, and `valueIterator` take none |
| String keys | `std.hash_map.StringContext` (Wyhash over bytes plus `mem.eql`) | **Keys are not copied.** That is safe for Rig `String` keys, which are static. An owned `Text` key must be moved into the map and dropped by it |
| Other keys | `std.hash_map.AutoContext(K)` (Wyhash plus `std.meta.eql`) | `autoHash` **refuses at compile time**: floats, `[]const u8` (it suggests StringHashMap), structs and unions containing slices, untagged unions. **Single pointers are accepted but hashed by address** ✔, so `*T` keys would have identity semantics. Rig needs a `hash` requirement that admits integers, `Bool`, plain enums, `String`, plain structs of those, and types with `__rig_hash` / `__rig_eql` |
| Insertion-ordered map | `std.array_hash_map.Auto(K, V)` / `.String(V)` / `.Custom(K, V, Ctx, store_hash)` | Unmanaged. **Its context differs**: `hash(self, K) u32` and `eql(self, a, b, b_index) bool`. `keys()` and `values()` are live slices. Removal must choose `swapRemove` (O(1)) or `orderedRemove` (O(n)). The `…ArrayHashMapUnmanaged` names are deprecated, and there is no managed form |
| Pointer stability | none | Any insertion that grows the map invalidates `getPtr`, `value_ptr`, and iterators. Rig's `!self` on `put` already forbids a live `?m.get_ref(k)` borrow across it. `lockPointers()` can assert this in Debug |

### 2.3 Text

These are functions for the shims and for Rig APIs over `String` and
text views.

| Need | 0.16 function | Notes |
|---|---|---|
| Equality, prefix, suffix, order | `std.mem.eql(u8, a, b)`, `startsWith`, `endsWith`, `order` (→ `math.Order`), `lessThan` | |
| Find | `std.mem.find`, `findLast`, `findPos`, `findScalar`, `findScalarLast`, `findAny`, `findNone` | **`indexOf*` and `lastIndexOf*` are deprecated aliases**; use `find*` |
| Split (keeps empty fields) | `splitScalar`, `splitSequence`, `splitAny`, `splitBackwards*`; the iterator has `next`, `peek`, `rest`, `first`, `reset` | The bare `split` and `tokenize` are gone. `splitSequence` asserts a non-empty delimiter, so the shim must check it and panic with a Rig message |
| Tokenize (skips empty fields) | `tokenizeScalar`, `tokenizeAny`, `tokenizeSequence` | |
| Cut once | `cut`, `cutLast`, `cutScalar`, `cutScalarLast` → `?struct{ []const T, []const T }`; `cutPrefix` / `cutSuffix` → `?[]const T` | Maps to a Rig `(String, String)?`, or two views |
| Trim | `trim`, `trimStart`, `trimEnd` | **`trimLeft` and `trimRight` no longer exist** |
| Allocating helpers | `join(gpa, sep, parts)`, `concat(gpa, u8, parts)`, `replaceOwned(u8, gpa, s, a, b)`, `ascii.allocLowerString` | The caller owns the result, so return a `Text` |
| ASCII | `std.ascii.isDigit`, `isAlphabetic`, `isAlphanumeric`, `isWhitespace`, `isHex`, `toLower`, `toUpper`, `lowerString(out, s)`, `eqlIgnoreCase`, `findIgnoreCase` | Pure functions over `U8`; trivially Zig-backed or written in Rig |
| UTF-8 | `std.unicode.utf8ValidateSlice(s) bool`; `Utf8View.init(s) error{InvalidUtf8}!Utf8View` / `initUnchecked`; `Utf8Iterator.nextCodepoint() ?u21`, `nextCodepointSlice`; `utf8Encode(c, out) !u3`; `utf8CountCodepoints(s) !usize`; `utf8ByteSequenceLength` | **`Utf8Iterator` does `catch unreachable` on bad bytes**, so it is illegal behavior on unvalidated input. Validate first. `utf8Decode` is deprecated in favor of `utf8Decode2`/`3`/`4`. Rig strings are "UTF-8 bytes" by SPEC but not validated; a `Text.from_bytes` must validate |

### 2.4 Formatting

| Need | 0.16 | Notes |
|---|---|---|
| Format into owned text | `std.fmt.allocPrint(gpa, fmt, args) Allocator.Error![]u8`; `list.print(gpa, fmt, args)` on `ArrayList(u8)` ✔ (the prototype's `push_int`) | Formats must be comptime strings, so a Rig `format` built-in would lower to `list.print` with a generated format string, or to one call per piece |
| Into a buffer | `bufPrint(buf, fmt, args) error{NoSpaceLeft}![]u8`, `fmt.count`, `fmt.printInt(buf, v, base, case, opts) usize` | |
| Parse | `std.fmt.parseInt(T, s, base)` → `error{Overflow, InvalidCharacter}`. Base 0 reads `0x`/`0o`/`0b`. It accepts `_` and a leading `+`/`-`; empty input or leading whitespace is `InvalidCharacter` ✔. `parseUnsigned` rejects `-`. `parseFloat(T, s)` → `error{InvalidCharacter}` and accepts `nan` and `inf` | Rename the errors to Rig names in the shim (the prototype maps them to `.invalid` and `.overflow`) |
| Writer interface | `std.Io.Writer` is a concrete struct (`vtable`, `buffer`, `end`) with `print`, `writeAll`, `writeByte`, `printInt`, `flush`; `Error = error{WriteFailed}` (the cause lives in the concrete writer's `.err`). `Writer.fixed(buf)`; `Writer.Allocating` with `.init(gpa)`, `.fromArrayList(gpa, &list)`, `.writer` (a **field**), `written()`, `toOwnedSlice()`, `toArrayList()`, `deinit()` | **Never copy a writer interface**: take `&fw.interface`. `{f}` is the only specifier that calls `format`, and a `format` method is `fn (self, *Writer) Writer.Error!void`. `{}` no longer prints strings (use `{s}`) or optionals (use `{?}`) |
| Rig's own rendering | `rig.writeValue` (private today) | Shims that print containers (`Map`) need it exported (§5.6) |

### 2.5 I/O under the 0.16 Io model

Everything goes through a `std.Io`. For all synchronous work,
**`std.Io.Threaded.global_single_threaded.io()` suffices** ✔. That
covers files, `Dir.iterate`, `access`, `deleteFile`, stdin lines,
`readFileAlloc`, clocks, sleep, and `io.random` / `io.randomSecure`. Its
`failing` allocator is used only by `async`/`concurrent`/groups,
process spawn and replace, and memory mapping.

| Rig feature | 0.16 backing | Errors and gotchas |
|---|---|---|
| stdout (`print`) | `std.Io.File.stdout().writerStreaming(io, &buf)`, then `&w.interface` | Already in the runtime |
| stderr | `File.stderr()`, same shape | Needs its own buffer, flushed with stdout on panic |
| stdin lines | One process-wide `File.stdin().readerStreaming(io, &buf)`. **Unbounded lines**: `r.streamDelimiterEnding(&aw.writer, '\n')` into an `Allocating` writer, then `takeByte()` to consume the `\n` (or see `EndOfStream`) ✔ (prototype `read_line`, tested with a 10,000-byte line and a 4 KiB buffer) | `takeDelimiter('\n')` returns `?[]u8` borrowed from the reader's buffer and fails with `StreamTooLong` for a longer line. `takeDelimiterExclusive` **does not consume the delimiter** (a second call returns `""`). `takeDelimiterInclusive` returns `EndOfStream` for a last line without `\n` |
| Read a whole file | `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit) ReadFileAllocError![]u8`, where the error set is `File.OpenError ∥ File.Reader.Error ∥ OOM ∥ StreamTooLong` | **The limit is "reached or exceeded"**: a file exactly `.limited(n)` long is `StreamTooLong` ✔. Use `.unlimited`. The result is allocated by the `gpa` passed in (the Rig allocator), so it is owned by the caller and seen by the leak checker ✔. `Text` takes it with `ArrayList.fromOwnedSlice`, whose capacity equals its length, so the free size matches `LeakChecker`'s record ✔ |
| Open, create, write | `dir.openFile(io, p, .{})`, `dir.createFile(io, p, .{})`, `dir.writeFile(io, .{ .sub_path, .data })`, `file.writer(io, &buf)` / `writerStreaming`, `file.close(io)`, `file.length(io)`, `file.writeStreamingAll(io, bytes)`, `dir.createFileAtomic` | Every method takes `io`. `std.fs.File`, `std.fs.Dir`, and `std.io` are gone; `std.fs` keeps only `path`. An open `File` is an owning Rig type whose drop is `close(io)` |
| Directories | `dir.openDir(io, p, .{ .iterate = true })`, `it.next(io) !?Entry{ name, kind, inode }` (a 2 KiB internal buffer, no allocator), `createDirPath(io, p)`, `deleteFile`, `access(io, p, .{})` | `Dir.cwd()` is not iterable (open `"."`) and must never be closed. `Entry.name` borrows the iterator's buffer, so it is a *view* result |
| Paths | `std.fs.path.join`, `dirname`, `basename`, `extension`, `resolve`, `isAbsolute` | Pure |

Error mapping for I/O: shims map Zig's large error sets onto a small
Rig set, for example:

| Zig errors | Rig name |
|---|---|
| `FileNotFound`, `NotDir` | `not_found` |
| `AccessDenied`, `PermissionDenied` | `access_denied` |
| `IsDir` | `is_dir` |
| `PathAlreadyExists` | `exists` |
| `StreamTooLong` | `too_long` |
| everything else | `io_failed` |
| `OutOfMemory` | a panic, as Rig specifies |

### 2.6 Process

| Rig feature | 0.16 | Notes |
|---|---|---|
| args | **No global argv exists in 0.16**: `std.os.argv` and `std.process.args()` are gone. `start.zig` `callMain` passes argv only to a `main` that takes `std.process.Init.Minimal` (`{ args, environ }`, no allocation) or `std.process.Init` | **The emitted `main` must become `pub fn main(init: std.process.Init.Minimal) …`** and hand `init` to the runtime ✔ (prototype `os.start`). `init.args.iterate()` is allocation-free on POSIX but a **compile error on Windows and WASI**, which need `iterateAllocator(gpa)` or `toSlice(arena)`. argv bytes live for the whole process, so they cross as `String` ✔ |
| env | `init.environ.getPosix(name) ?[:0]const u8` ✔. It is also reachable without args, through `global_single_threaded.environ.process_environ.getPosix(...)`. Allocating forms are `Environ.getAlloc(gpa, key)` and `createMap(gpa)` | POSIX values are process-lifetime, so `env(name: String) -> String?` is safe while Rig has no `setenv`. Windows needs the allocating form, which returns `Text` |
| exit | `std.process.exit(status: u8) noreturn` | **Runs no `defer`**, so a Rig `exit` must call `rig.finish()`'s flush first. Whether to leak-check on `exit` is a design choice |
| run a child | `std.process.spawn(io, .{ .argv, .stdin, … })`, `child.wait(io)`, `std.process.run(gpa, io, .{ .argv })` | **Allocates through the Io**, so it fails with `OutOfMemory` on `global_single_threaded`. It needs a runtime-owned `std.Io.Threaded` built with the Rig allocator (`Threaded.init(gpa, opts)` at `Io/Threaded.zig:1607`, `deinit` in `rig.finish`) |

### 2.7 Time, random, math, sort, JSON

| Area | 0.16 backing | Rig mapping and gotchas |
|---|---|---|
| Time | **`std.time` keeps only unit constants and `epoch`.** `timestamp`, `milliTimestamp`, `Timer`, `Instant`, and `sleep` are all gone. Use `std.Io.Timestamp.now(io, .real \| .awake)` (`{ nanoseconds: i96 }`), `durationTo`, `untilNow`, `toSeconds`/`toMilliseconds`/…, `std.Io.Duration.fromMilliseconds(i64)`, and `io.sleep(duration, clock) Cancelable!void` ✔ on `global_single_threaded` | `Instant` and `Duration` are **copy-kind** shim types (plain structs, no drop). `now() -> Instant`, `d.ms() -> Int`. The `i96` must be narrowed to `Int` with a checked cast |
| Random | `std.Random` interface `{ ptr, fillFn }`. `DefaultPrng = Xoshiro256` (`.init(seed)`, `.random()`), `DefaultCsprng = ChaCha`. Methods: `int`, `boolean`, `intRangeAtMost`, `intRangeLessThan`, `uintLessThan`, `float` (in [0, 1)), `shuffle`, `weightedIndex`. Seed from `io.random(&buf)` (infallible) or `io.randomSecure(&buf)` (`error{EntropyUnavailable, Canceled}`). `std.Random.IoSource{ .io = io }` gives a `Random` over the Io | **`std.crypto.random` no longer exists.** Keep one process-wide PRNG in the shim, seeded lazily from `io.random`, plus a `Rng` owning type for reproducible seeded streams. `shuffle(!v)` takes a `![]T` |
| Math | `std.math.pi`, `e`, `inf(T)`, `nan(T)`, `sqrt`, `pow`, `powi` (`error{Overflow, Underflow}`), `log`, `log2`, `log10`, `sin`/`cos` (wrappers over builtins), `clamp`, `isNan`, `isInf`, `isFinite`, `cast(T, x) ?T`, `add`/`sub`/`mul(T, a, b) error{Overflow}!T`, `divTrunc`/`divFloor`/`mod`/`rem` (`!T`), `maxInt`/`minInt` (`comptime_int`) | There is **no `std.math.exp`, `floor`, or `ceil`**: use `@exp`, `@floor`, `@ceil`, `@round`, `@trunc`. `std.math.sqrt` of an integer returns a half-width type. Nearly all of this is pure and small, and many functions are builtins Rig already exposes in `raw`, so this is the best case for safe Zig-backed `fun`s |
| Sort | `std.mem.sort(T, items, ctx, lessThan)` is **stable** (block sort); `std.mem.sortUnstable` is pdq; `std.sort.asc(T)` / `desc(T)` with `{}` as the context. Also `binarySearch(T, items, ctx, compareFn(ctx, T) Order) ?usize` (the key goes in `ctx`; `compareFn` returns `order(key, item)`), `lowerBound`, `upperBound`, `partitionPoint`, `equalRange` | ✔ Prototype `sort_by[T](v: !Vec[T], less: ?fun(T, T) -> Bool)` passes Rig's `FnRef` as the sort context. The `!v` borrow keeps the closure from reaching the Vec during the sort |
| JSON | Parse with `std.json.parseFromSlice(T, gpa, s, opts) !Parsed(T)`, where `Parsed = { arena, value }` and `deinit()` frees everything. `parseFromSliceLeaky` allocates into a caller arena. `ParseOptions`: `ignore_unknown_fields = false`, `duplicate_field_behavior`, `max_value_len`, `allocate`. Errors: `SyntaxError`, `UnexpectedEndOfInput`, `UnknownField`, `MissingField`, `DuplicateField`, `InvalidNumber`, `Overflow`, `InvalidEnumTag`, `LengthMismatch`, `UnexpectedToken`, OOM ✔. Dynamic values: `std.json.Value` (`null`, `bool`, `integer: i64`, `float`, `number_string`, `string`, `array: array_list.Managed(Value)`, `object: array_hash_map.String(Value)`). Write with `std.json.Stringify.value(v, opts, *Io.Writer)`, `Stringify.valueAlloc(gpa, v, opts)`, `std.json.fmt(v, opts)` with `{f}`; `opts.whitespace` is `.minified` or `.indent_2` and so on | **The old `stringify`/`stringifyAlloc` names are gone.** Ownership does not map directly: every string in a `Parsed(T)` lives in its arena, so **a parsed value cannot contain Rig `String`s**. Expose `Json` as an owning type (drop is `deinit`) whose accessors return *views* (`?Json`, text views) that borrow it. Parsing straight into a Rig struct needs owned text fields (`Text`), so it is a later step |

---

## 3. Binding mechanisms

### 3.1 The three options

**(a) Hard-code built-ins in the compiler and runtime (status quo).**
Each type's members are known to sema, typecheck, and ownership (member
tables and special rules), emit spells each operation, and
`runtime.zig` implements it. This is how `Vec`, `Cell`, `Box`, and
`Signal` work.

**(b) Zig-backed declarations ("zig extern").** A Rig module declares
types and functions with full Rig signatures and no bodies, bound to a
`.zig` shim. For example:

```rig
# std/text.rig: embedded in the compiler, imported as `use std.text`
error TextError
  not_found
  access_denied
  io_failed
  invalid
  overflow

extern zig "text.zig"
  pub struct Text owns             # owning: moves; drop glue is the shim's __rig_drop
    pub fun new -> Text
    pub sub push(!self, s: String)
    pub sub push_int(!self, n: Int)
    pub fun len(?self) -> Int
    pub fun view(?self) -> []U8    # borrows self (the existing returned-borrow rule)
    pub fun lines(?self) -> Lines  # a view: borrows self

  pub struct Lines view            # holds a borrow; no drop glue
    pub fun next(!self) -> ([]U8)?

  pub fun trim(s: String) -> String
  pub fun split(s: String, sep: String) -> Vec[String]
  pub fun parse_int(s: []U8) -> Int!
  pub fun read_file(path: String) -> Text!
  pub fun read_line -> Text?!

# Rig code in the same module builds on the Zig-backed pieces:
pub fun read_lines(path: String) -> Vec[Box[Text]]!
  ...
```

```rig
# std/map.rig
extern zig "map.zig"
  pub struct Map[K: hash, V] owns
    pub fun new -> Map[K, V]
    pub fun put(!self, k: K, v: V) -> V?
    pub fun get(?self, k: ?K) -> V? where V: plain
    pub fun contains(?self, k: ?K) -> Bool
    pub fun remove(!self, k: ?K) -> V?
    pub fun len(?self) -> Int

  pub fun sorted_keys[K: hash + ord + plain, V](m: ?Map[K, V]) -> Vec[K]
  pub sub sort_by[T: plain](v: !Vec[T], less: ?fun(T, T) -> Bool)
```

The exact surface syntax is the grammar owner's call. What matters is
what the declaration carries:

- the shim path;
- each type's **kind** (`copy`, `owns`, or `view`);
- **requirements** on type parameters, at type level and per method;
- ordinary Rig signatures.

**(c) Everything in Rig over a few primitives.** Add raw pointers,
`alloc` / `free` / `realloc`, `memcpy`, and pointer arithmetic, usable
in `raw`, plus `extern` C for syscalls. Then write `Text`, `Map`,
formatting, UTF-8, files, and so on in Rig.

### 3.2 How each answers the questions

| Question | (a) hard-coded | (b) zig extern | (c) pure Rig |
|---|---|---|---|
| **Type mapping across the boundary** | Internal. The emitter chooses the Zig spelling of each member | The §1 table is the contract. The emitter already spells every Rig type from a sema `TypeId`, so it spells the *expected* shim signature too, and a comptime check compares them (§3.3) | No boundary for Rig code. Raw pointer types need new lowerings, and C `extern` passes only numbers and `Bool` today |
| **`String` → `[]const u8`** | Same | Same, but the shim must never return a `String` pointing into freed memory. Returning a String is allowed only for static or process-lifetime bytes | Same |
| **`Vec` → `rig.Vec(T)`** | Same | Shim code builds and returns `rig.Vec(T)` with `push` ✔ (`split`, `args`, `sorted_keys`) | A Vec written in Rig |
| **`T!` → `anyerror!T`** | Internal | The shim may return any `E!T` whose names all belong to error sets the Rig module declares. Checked at compile time ✔. The shim renames Zig errors (`FileNotFound` → `not_found`) | Native |
| **`T?` → `?T`, `!T` → `*T`** | Internal | As in §1 | Native |
| **Owned values** | Hard-coded per member | **A by-value owning parameter is the callee's; an owning result is the caller's.** The emitter already writes a guarded `defer rig.drop` for results and `rig.take` for moves ✔ | Native, but the implementation manipulates raw memory in `raw` |
| **Generics** | Special-cased per type in sema and emit | Zig type functions, exactly as Rig generics are emitted: `Map([]const u8, i64)`, memoized by Zig ✔ | Rig generics (they work today), but raw memory code must be generic over `T` sizes |
| **Returned memory** | The runtime's allocator | The shim allocates with `rig.defaultAllocator()`, the same Debug leak checker and release `smp_allocator` ✔. The returned owning value carries its own drop glue (`__rig_drop`), found through `rig.drop` ✔ | Rig's allocator primitive |
| **Error mapping** | Internal | Rename in the shim. OOM is a panic. Unknown causes are a catch-all (`io_failed`) | Native errors, but a syscall's errno must be decoded by hand |
| **What the checker must check** | Everything, member by member, in compiler code | The signature, as for any Rig function, plus: the type kinds; declared requirements per instance and per method; that fallible results name declared errors; no `raw` needed at call sites. The rest is **the shim contract** (§4.4), enforced by review and tests | Everything outside `raw` is checked. Inside `raw` nothing is, and most stdlib code would be inside `raw` |
| **Cost per API function** | High: sema, typecheck, ownership, emit, runtime, docs | Low: one Rig line plus a few lines of Zig. Zig std does the work | High: re-implement hashing, float formatting, UTF-8, and I/O |
| **Quality of the implementation** | Hand-written | Zig std (hash maps, `parseFloat`, Io, sort): tested and fast | Hand-written, less mature |
| **Safety story** | Compiler code is trusted | Shim code is trusted like `runtime.zig`: small, reviewed, unit-tested, and leak-checked by the suite | `raw` Rig is trusted. The trusted code is larger and new |
| **Prerequisites** | None | Grammar for body-less declarations, type kinds, and requirement bounds; embedding shims; changing `main` | Raw pointers, allocation, and a C ABI for more than numbers (all roadmap items) |

### 3.3 Why (b) keeps "accept means correct"

1. **Call sites are ordinary calls.** The checker needs only the
   signature, and the existing rules cover everything:
   - "the result borrows from every borrowed argument";
   - by-value owning parameters move;
   - owning results get drop glue;
   - `!self` excludes other borrows.

   So `!t.push_view(t.view())` is rejected, and `longest = <line` moves
   correctly ✔ (in the prototype the emitter produced the correct
   `rig.take` and drop sequence with no changes).
2. **The shim's Zig type is checked against the Rig signature at Zig
   compile time.** `boundary.expect(f, fn (...) R, Errors)` compares:
   - every parameter type exactly;
   - the result type exactly, except that a fallible result may use any
     subset of the declared error names.

   `boundary.expectKind(T, .owns | .view | .copy)` checks that the
   shim's drop glue matches the declared kind. For generic types there
   is one check per instance the program uses; sema already lists
   instances. A mismatch is a Zig compile error naming the shim and
   parameter ✔.
3. **Mismatches must never reach users.** The shims ship with the
   compiler, so a mismatch is a compiler bug. `./test/run` must
   instantiate every std declaration (at least one test per declaration
   and per generic method) so that it fails there. That keeps AGENTS.md
   rule 2: `rig check` accepting a program means the emitted Zig
   compiles, because every shim/signature pair was compiled by the
   suite.
4. **Requirements are declared, not inferred.** The checker cannot see
   the shim's body.
   - Without declarations, the prototype showed the problem. With
     `Map[Int, *Node]`, `nodes.get(?one)` was **accepted by `rig check`**.
     The shim copies the handle out of the map. The caller's copy is
     dropped ("drop node 10" printed while node 10 was still in the
     map), and the map's later drop touches freed memory. The program
     exits 0 and nothing notices (`scratchpad/stdlib/zig/req/`).
   - With `where V: plain` on `get`, the instance is rejected at the
     call.
   - Sema's existing `checkRequirements` does this once the requirement
     list is seeded from the declaration instead of from a body.
5. **Views.**
   - A `view` type returned by a function borrows from every borrowed
     argument of that call, as a struct holding a borrow does today
     (SPEC §7).
   - Its methods returning borrows (`Lines.next -> ([]U8)?`) borrow
     through `!self`, which the checker already accepts and tracks ✔.

---

## 4. Prototype

The prototype is in `scratchpad/stdlib/zig/`:

```
standin.rig            the Rig program, with stand-in declarations whose signatures are the proposed API
standin.emitted.zig    `bin/rig emit standin.rig`, untouched
handedit.py            the hand edit: stand-in declarations → shim aliases + boundary checks; main takes Init.Minimal
run.sh                 check → emit → hand edit → build Debug and ReleaseSafe → run → compare
proto/__rig_main.zig   the hand-edited program (only declarations changed; every call site is the emitter's)
proto/rig/runtime.zig  the Rig runtime, unmodified
proto/rig/std/text.zig Text, Lines, trim, trim_view, split, parse_int, read_file, read_line
proto/rig/std/map.zig  Map(K, V) over std.HashMapUnmanaged, sorted_keys, sort_by
proto/rig/std/os.zig   start(Init.Minimal), args, env
proto/rig/std/boundary.zig  expect / expectResult / expectKind
neg/                   six deliberately broken copies (neg/README)
req/                   the undeclared-requirement use-after-free
```

### 4.1 Method

1. Write the program in Rig with **stand-in** declarations that have the
   proposed signatures and placeholder bodies, so `rig check` accepts it
   today and the emitter produces real call sites. The call sites
   include moves, borrows, drop guards, `catch` blocks, generic
   instances, closures passed as `FnRef`, and `while !it.next() as line`.
2. Replace only the declarations in the emitted Zig:
   - `pub const Text = std_text.Text;`, and so on;
   - one `comptime { boundary.expect… }` per declaration and per method
     of each generic instance;
   - `main(__rig_init: std.process.Init.Minimal)` calling
     `std_os.start`.

   The real emitter would qualify calls (`std_text.trim(p)`) instead of
   aliasing. Aliases keep the edit to the declarations.
3. Build with `zig build-exe` in Debug (the Rig `LeakChecker` is active,
   and `rig.finish` exits 1 on any leak) and in ReleaseSafe. Run both
   and compare.

### 4.2 What it exercises

| Feature | Zig std behind it | Rig ownership aspect |
|---|---|---|
| `Text.new`, `push`, `push_int`, `len`, `view` | `ArrayList(u8)`: `appendSlice`, `print(gpa, "{d}", …)` | An owning type (`__rig_drop`); `view` borrows `?self` |
| `print(t)` | `__rig_print` hook | The runtime's existing hook |
| `trim`, `split` | `mem.trim`, `mem.splitSequence` → `rig.Vec([]const u8)` | Static Strings in, a caller-owned Vec out; `for p in split(...)` consumes it through `IntoIter` |
| `parse_int(trim_view(t.view()[6..9]))` | `fmt.parseInt`, errors renamed | A chain of borrows; a fallible result; `catch \|e\|` prints `.invalid` |
| `read_file` | `Io.Dir.cwd().readFileAlloc(io, p, rig gpa, .unlimited)` on `global_single_threaded` | Owned result, allocated by the Rig allocator; `.not_found` on a missing file |
| `Lines` / `next` | `mem.splitScalar` | A view type; a returned borrow through `!self` |
| `read_line` | stdin `readerStreaming`, `streamDelimiterEnding` into `Writer.Allocating`, `toArrayList` | `Text?!`. `longest = <line` moves and drops the old value; unbounded line length |
| `sort_by(!nums, \|a, b\| a > b)` | `mem.sort` with `rig.FnRef` as context | A stack closure called from Zig |
| `Map[String, Int]`, `Map[Int, *Node]`, `Map[Text, Int]` | `HashMapUnmanaged` with `StringContext`, `AutoContext`, or a context over `__rig_hash` / `__rig_eql` | Moves keys and values in. `put` returns the replaced value (the caller drops it: "drop node 1"). `remove` hands the value over. The duplicate owned `Text` key is dropped by `put`. Drop glue drops every key and value ("drop node 10" at exit) |
| `sorted_keys` | `keyIterator` + `mem.sort` with `rig.compare` | A generic function; a Vec out |
| `args`, `env` | `Init.Minimal.args.iterate()`, `environ.getPosix` | Process-lifetime bytes as `String` |

### 4.3 Results

- `./run.sh`: Debug run exits 0, so the leak checker found no leaks.
  The ReleaseSafe run exits 0, and the outputs are identical.
- Standard input edge cases:
  - a 10,000-byte line with a 4 KiB buffer is read whole;
  - empty input gives 0 lines;
  - a trailing `\n` adds no empty line.
- Negative tests (`neg/`):

| Deliberate shim bug | Caught by |
|---|---|
| `Text.__rig_drop` does not free | Leak checker: "13 allocations (1653 bytes) never freed", exit 1 |
| `Map.put` does not drop a duplicate owned key | Leak checker: 1 allocation, exit 1 |
| `read_line` copies the line and forgets the buffer | Leak checker: 3 allocations, exit 1 |
| `push_int` takes `i32`; Rig says `Int` | Compile error: `rig: shim fn (*Text, i32) void: parameter 1 is i32, the Rig signature needs i64` |
| `read_file` can fail with `error.FileNotFound` | Compile error: `can fail with error.FileNotFound, which no Rig error set declares` |
| Rig declares `Lines` `owns`; the shim has no drop glue | Compile error: `has no drop glue, but its Rig declaration says it is owns` |

- Not caught, and needing the declared requirements of §3.3(4):
  `req/` (`get` copying a `*Node` out of a map) is accepted by `rig
  check` and silently uses freed memory.

A pitfall found while writing `read_line`: a `defer` that restores
state into a local after `return local;` runs after the return value was
copied, so the buffer leaked. The leak checker caught it. Shim code
should avoid `defer` that mutates a value being returned. This is a
point for the shim-author checklist.

### 4.4 The shim contract (the trusted-code checklist)

1. **Allocation.** Allocate only through `rig.defaultAllocator()`.
   `OutOfMemory` panics ("out of memory"), as the runtime does.
2. **By-value parameters.** A by-value owning parameter is consumed
   exactly once: stored, returned, or `rig.drop`ped.
3. **Owned results.** An owned result is fully owned by the caller.
   Never return a shallow copy of an owning value the shim still holds;
   a handle must be `cloneStrong`d.
4. **Borrowed results.** A borrowed result (`?T`, `[]T`, a view type)
   points only into what the call's borrowed arguments reach.
5. **Retained borrows.** Keep no borrow past the call, except inside a
   declared `view` result.
6. **No reentrant Rig code mid-mutation.** No Rig code (a closure, or a
   user `drop` through `rig.drop`) runs while the shim's state is
   inconsistent:
   - drop replaced keys and values last;
   - move a table out before dropping its elements.

   `Map.__rig_drop` and `put` do this, as `Cell.vecClear` does.
7. **Errors.** Fail only with the declared error names, which is
   checked. Rename Zig errors.
8. **Global state.** Keep no global mutable state beyond process-wide
   resources (the stdin reader, the PRNG). Programs are single-threaded.
9. **Hooks.** Use the runtime's hooks: `__rig_drop`, `__rig_print`,
   `__rig_hash` / `__rig_eql`. Never hold a `Cell`, which is checked.
10. **Tests.** Every shim has Zig unit tests run under the leak checker,
    and every declaration is used by a Rig test program in `./test/run`.

---

## 5. Recommendation and compiler changes

**Adopt (b) for the standard library.** Keep (a) for the substrate
types whose rules the checker must know intimately: `Cell`, `Vec`,
`Box`, `Signal`, handles, and closures. Let stdlib modules mix
Zig-backed declarations with ordinary Rig code built on them, which
makes (c) the default for everything that does not need Zig. Add (c)'s
primitives (raw pointers) later, for users, not as the stdlib's
foundation.

### 5.1 Declaring a Zig-backed API (grammar and IR)

Changes in `rig.grammar`, then `zig build parser`:

- **A block `extern zig "file.zig"`.** It holds body-less `fun`/`sub`
  declarations and `struct` declarations whose members are body-less
  methods and associated functions. `pub` and privacy work as for other
  declarations. `extern fun` (C) keeps its current meaning.
- **A type kind on a Zig-backed struct**: `copy` (plain data), `owns`
  (moves; drop glue in the shim), or `view` (holds a borrow).
  - An `owns` type may also declare `clone` to support `+x`.
- **Requirement bounds.**
  - On type parameters: `Map[K: hash, V]`, `sorted_keys[K: hash + ord + plain, V]`.
  - Per method: `where V: plain`.
  - The vocabulary maps onto sema's existing requirement kinds:
    `plain` (copies), `eq` (`==`), `ord` (ordering), `num`
    (arithmetic), plus a new `hash`.
  - These bounds are allowed only on Zig-backed declarations. Rig bodies
    keep inferring theirs.
- **IR.** New schema nodes for the block, the kind, and bounds, read by
  role through `parser.ir`, per rule 6. Any new grammar conflict must be
  justified in INTERNALS.

### 5.2 Where shims live, and how they ship

- **Source layout** in the compiler repo: `lib/std/text.rig` +
  `lib/std/text.zig`, `lib/std/map.rig` + `lib/std/map.zig`, and so on,
  plus `src/boundary.zig`.
  - `emit.zig` `@embedFile`s them as it embeds `runtime.zig`.
  - `modules.zig` resolves `use std.text` to the embedded `.rig`
    instead of the root directory. The `std.` prefix is reserved, as
    `__rig` names are.
- **Package layout.** The emitter writes a used module's shim to
  `rig/std/text.zig` in the package, beside `rig/runtime.zig`.
  - Shims import the runtime as `@import("../runtime.zig")`, as in the
    prototype.
  - Shim paths in `extern zig "…"` resolve relative to the declaring
    `.rig` file. That covers the embedded stdlib now and allows user
    shims later.
- **Testing.**
  - `zig build test` runs each shim's unit tests.
  - `./test/run` runs Rig programs that use every declaration, which
    makes every `boundary.expect` compile under the suite.
  - Every stdlib doc example runs, as today.
- **User shims (later).** A user module may declare `extern zig` only
  inside a visible trust marker (for example `raw extern zig
  "mine.zig"`). The `boundary` checks turn a signature mismatch into a
  clear build error. That is the same trust level as `raw`, and it is
  visible in the source.

### 5.3 How the checker trusts the signatures

Changes in `resolve.zig`, `typecheck.zig`, `ownership.zig`, and `sema.zig`:

- **Declarations.** `resolve.zig` declares Zig-backed functions as
  ordinary function symbols with an origin flag (`zig_backed`, the
  shim's path). Zig-backed structs are nominal types with a kind and no
  fields visible to Rig.
  - `owns` gives the type drop glue (`needsDrop` in sema).
  - `view` marks it as holding a borrow, with its lifetime taken from
    the call that produced it.
  - `copy` makes it plain data.
- **Calls.** `typecheck.zig` checks calls exactly as calls to Rig
  functions. No `raw` is required: the signature is complete and the
  implementation is trusted. It also:
  - checks that each module with fallible Zig-backed declarations
    declares at least one error set;
  - rejects `print` of an `owns` or `view` type unless it declares a
    print hook (the kind declaration can say so).
- **Ownership.** `ownership.zig` needs no new rules for functions. For
  `view` types it applies the existing rule for a struct that holds a
  borrow: the value keeps its source borrowed while alive.
- **Requirements.** Sema seeds `generic_requirements` of a Zig-backed
  generic's parameters from the declared bounds. `checkRequirements`
  checks type-level bounds at each instance and method-level `where`
  bounds at each call of that method, so `Map[Int, *Node]` stays legal
  and only its `get` is rejected. It also adds a `hash` requirement kind
  with its admissible types (§2.2).

### 5.4 Emission, generics, and drop glue across the boundary

Changes in `emit.zig`:

- **Declarations.** For each Zig-backed declaration, emit in the
  declaring module `pub const f = @import("rig/std/text.zig").f;`, or
  qualify its uses. Importers then reach it through the existing
  cross-module machinery, unchanged.
- **Boundary checks.** Emit one `comptime` block of
  `boundary.expect(f, <Zig type spelled from the sema signature>,
  <the module's error sets merged>)` and `boundary.expectKind(T, kind)`
  per declaration. For generic types and functions, emit one per
  instance and method the program uses: sema's instance list. For a
  generic function, emit `expectResult` on `@TypeOf(f(T…, undefined…))`
  plus a thunk check if parameter types matter.
- **Generics.** Zig type functions and comptime type parameters first,
  as emitted today. `Map[K, V]` is `Map(K', V')`, memoized by Zig. The
  shim reads borrows through `rig.ReadBorrow(K)` / `rig.borrowed`.
- **Drop glue.** No new emitter logic. An `owns` value gets the usual
  guarded `defer rig.drop(&x)`, which dispatches to the shim's
  `__rig_drop`, and generic containers drop elements through `rig.drop`
  (compile-time no-ops for plain data). `expectKind` guarantees the
  shim's hook exists exactly when sema thinks it does.
- **`main`.** Emit `pub fn main(__rig_init: std.process.Init.Minimal)
  void` (or `anyerror!void`), calling `rig.start(__rig_init)` first.
  Zig 0.16 offers argv no other way.

### 5.5 Runtime changes (`src/runtime.zig`)

- **`start(init: std.process.Init.Minimal)`.** Store args and the
  environment, and add `io()`: `global_single_threaded` today, and a
  runtime-owned `std.Io.Threaded` over `defaultAllocator()` (deinit in
  `finish`) once process spawning or concurrency is supported.
- **Exports for shims.** Export `writeValue` so shims can print Rig
  values inside containers. Make `oom` public. Export `Int` / `len` for
  length conversion.
- **`__rig_print(self, w, top)`.** Pass `top` through, so a `Text`
  prints raw at the top level and quoted inside other values, as a
  `String` does.
- **Hash hooks.** Add `__rig_hash` / `__rig_eql` to the runtime's hook
  vocabulary (used by `Map` contexts), and make `rig.eql` use
  `__rig_eql` when present.
- **`boundary.zig`.** Keep it beside the runtime, compiled into every
  package that uses a Zig-backed module.

### 5.6 Language decisions the stdlib forces

These are separate changes, but they must be made before the stdlib API
freezes.

1. **A text-view type.** Dynamic text cannot be `String`, and `[]U8`
   cannot be printed. Add a borrowed UTF-8 view type: second-class like
   `[]T`, printable as text, with `String` converting to it implicitly.
   It would be the return type of `Text.view`, `trim_view`, `Lines.next`,
   `Dir` entry names, and JSON strings. Without it, every text API needs
   a `String` version and a `[]U8` version, and the `[]U8` ones cannot
   print.
2. **`Vec` of owning structs.** Either allow `Vec[Text]`, or accept
   `Vec[Box[Text]]` as the idiom for lists of owned text (split of owned
   text, `read_lines`).
3. **Lending Copy values to `?T`.** A `?K` parameter (map lookups)
   currently needs `?w` even for a `String`, and a literal cannot be
   lent (`first(?"a")`: "a borrow of a temporary lives only for the
   call"). Let a Copy argument satisfy a `?T` parameter implicitly, or
   let a temporary be lent to a call whose result holds no borrow.
4. **An iteration protocol.** `for x in it` over a type with
   `next(!self) -> T?`, so `for line in text.lines()` works.
   `while !it.next() as line` works today ✔.
5. **Map printing and iteration**, which need items 4 and the exported
   `writeValue`.

---

## 6. Risks and open questions

- **Signatures cannot express everything.** Two cases are not captured:
  - "returns a borrow of *one* of my borrowed arguments" is always
    conservative (every borrowed argument);
  - "keeps a borrow of an argument inside `!self`" (a map of views) is
    rejected.

  Keep stdlib shims to owned or static data plus views derived from the
  receiver.
- **Windows and WASI.** `Args.iterate` and `Environ.getPosix` are
  POSIX-only. Supporting other targets needs the allocating forms,
  returning owned `Text`.
- **`std.process.exit` skips `defer`s.** A Rig `exit` must flush, and
  must decide whether leak checking applies.
- **The shims' size must stay small.** A shim is trusted like
  `runtime.zig`. If shims start duplicating checker logic (for example
  element-drop order for new containers), that logic belongs in the
  runtime or in Rig.
