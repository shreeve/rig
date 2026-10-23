# Changelog

What changed in Rig. The entry under "Unreleased" lists what
`main` carries beyond the last tag; the tag's release notes take it over
and add a migration guide for the renames (`tools/migrate-0.3.py`).
[HANDOFF](HANDOFF.md) says where the work stands, and
[docs/ROADMAP.md](docs/ROADMAP.md) lists what is planned.

## Unreleased (toward v0.3.0)

`v0.2.9` is the latest release (Zig 0.17.0, Nexus 2.0.0). `main` has
changed the language since it:

### Language and compiler

- **A frozen value's handles order by what they reach,** as they compare
  and hash: `*Frozen[T]` provides `Ord` when `T` does, so `<`, a `T: Ord`
  bound, and `sort` take it.

- **What a function value is where a call runs it** is decided once
  (`Checker.fnArg`): a closure written in the call, a function's name, a
  closure binding, a closure's view or an owned closure, or none. Fixed
  with it: `http.serve` took a closure's view or binding whose captures it
  could not check, so a closure lending a local to write ran on every
  connection's task at once; it now refuses one, as `par.map` does.
  `task.isolate` and `task.supervise` refuse a closure written in the call
  that captures a closure or a write view, which could write outside
  them and leave the change half made after a panic. Every arm of
  `task.select` takes a closure's view, the first as well as the rest.

- **A lend of a branch is decided where it is reported:** inference checks
  a generic call's arguments quietly first, and a lend of a branch that
  was refused there (`look(?(a if c else b))`, `T` inferred, or the same
  inside a closure given to a generic) kept the verdict without its error,
  so the program was accepted and Zig failed. The verdict is now kept
  only from a check that reports. Two siblings are fixed with it: a kept
  view in a closure given to a generic lost its error the same way, and
  the trial of whether `<t[i]` could take a table's optional element
  recorded the slot as written, so a read through `?Table` failed in Zig.
  Debug and self-check builds also refuse to accept a module that types
  an expression `invalid` with no error.

- **Generic sets:** a function may take the set it fails with as a type
  parameter, `fun total[E](f: ?fun(?String) -> Int!E) -> Int!E`. A call
  binds it from its callbacks' sets (`error` for a `T!` callback), and
  fails with that set; in the body `!` passes only `E`, and `catch |e|`
  gives an `e: E` that `return e` fails with again. A callable view of a
  fallible function always takes the hidden slot, which has no bits in a
  program whose sets have none. A fallible arm of `task.select` hands its
  failure's fields to whoever catches it.

- **`std.json`'s `JsonError`:** `(!doc).load(?src)` parses as `parse`
  does and fails with `JsonError.bad(kind:, at:)`, the first error and
  its byte offset, where `parse` answers `false`. `parse`, a `Bool`,
  stays as it was.

- **One representation for `error`:** an `error` is always an error value
  that may carry fields, and every `T!` function takes the hidden slot,
  which has no bits in a program whose sets have none. A program's code
  no longer changes because another module declares a member with
  fields. Fixed with it: a value of a set without fields put where
  `error`, or a set with fields, goes; a temporary `error` that leaked;
  the slot passed to a built-in type's method or a runtime call (a
  `Chan`, `http.serve`, `io.copy`); function-value types without the
  slot; a `catch` read in place; `reduce` with a fallible function.

- **A task set of a declared set:** `Tasks[Int!L]()` and `Task[T!E]`
  parse in an expression, as in a type.

- **An array element that fails no longer leaks:** an array literal
  whose element leaves (`!`, `?`, or a `catch` that returns, breaks, or
  continues) drops the elements made before it, as a call's arguments,
  an object's fields, and the results of `return a, b` already did.

- **Clones across modules:** `+x` deep-copies an object or enum declared
  in another module, part by part, as it does one of its own, and so a
  `Map` or `Set` (built in, written in Rig) whose keys and values clone.
  A type with a `drop` body, a unique type, and a `Signal` still have no
  clone.

- **Errors that carry fields:** an error set's member may declare fields,
  `bad(pos: Int, msg: String)`, which hold no loan or handle and clone.
  A failure moves its error up through `!` to the `catch` that owns it;
  `match` names a member with its set, `E.bad(pos, msg) =>`, and a bare
  `e == E.bad` tests the member. An error prints with its fields, and
  `main` or a test that fails with one shows them. Tasks, `task.all`,
  `par`, `isolate`, `supervise`, `time.within`, and actor methods hand
  the fields to the waiter. A program whose errors carry fields is built
  outside a `rig batch`. Two errors compare whole only when their set's
  fields all compare, and two of `error`, of any set, no longer do: a
  program that wrote `a == b` of two `error` values now matches one, or
  compares it with a member (`e == E.name`).
- **Declared error sets:** a function may name the set it fails with,
  `-> T!E` or `sub f()!E`, and `T!` stays any error. `error L = A | B`
  names a union of sets. `catch |e|` gives `e` the callee's set, so a
  `match` on it names every member and needs no `_`, and `g: E =>`
  narrows an `error` or a union to a set. `!` and a failing `return`
  keep to the declared set. A task's set holds `task.Stop`, which
  `task.check` and `time.sleep` now declare. A program that ignored a
  typed binding (`catch |e| 0` on a `T!E` call) now names it `_`.
- **Member tests:** `x == K.name` tests which variant `x` holds, as
  `x == .name` does, one with a payload too, and needs no `==` on the
  payloads.

- **Renames:** `Box[T]` is `^T`, `Vec` is `List`, the owned `Text` is
  `String` and its read view is `?String`, and `Static` is the type of
  literal text.
- **`obj`:** `struct` is spelled `obj`, a contextual keyword.
  `struct` is an ordinary name, and a declaration written with it is
  rejected with a hint. `unique`, `from`, and `static` are contextual
  keywords too.
- **Syntax:** a deeper-indented line starting with `.` continues the
  statement above (not after a line that opens a block); a closure may
  omit trailing parameters; a bare `for X` loops over `X`; an iterator
  in a place is written `for x in !it`.
- **Optionals cost nothing where an object has a niche:** an object
  holding a `String`, `List`, box, handle, `Bool`, plain enum, or an
  object that does holds `none` in bytes no value of it holds, so its
  `T?` is the size of the object (`Cheese?` with a `String` is 32
  bytes, not 40) and `== none` is one compare. An optional of it,
  `(T?)?`, takes the next spare value where one is left. An object of
  numbers alone keeps its flag. It holds for an enum of thousands of
  variants and an object of thousands of fields, in an object's field
  types and defaults too.
- **An object that names its none:** `obj Node` with one integer or
  plain-enum field may declare `none id == 0`; its `Node?` then holds
  that value for `none`, the size of a `Node`, tested with one compare,
  and an object holding a `Node` has an optional its own size too. No
  `Node` holds the value: a constant is rejected, a run-time value is
  checked as the object is made, and the field is read-only everywhere
  (SPEC §12, "An object that names its none").
- **Inclusive ranges:** `a..=b` runs through `b`, beside `a..b`, which
  stops before it: a `for` source (`for b in 0..=U8.max` reaches the
  type's largest value without stepping past it), a slice
  (`xs[a..=b]`, `xs[..=b]`), and a range pattern (`1..=5 =>`,
  `200..=255 =>`).
- **Bytes are strings:** where a `U8` is expected, a string literal of
  one byte is that byte (`c: U8 = 'A'`, `c == "\n"`, `'0'..='9' =>` on a
  `U8`, `U8('>')`), and where a `[N]U8` is, its bytes
  (`HOME: [3]U8 = "\x1b[H"`). `b'…'` and `b"…"` are gone: `b'A'` is the
  name `b` and a string. Quotes decide only escapes, so a byte that
  needs one is written in double quotes (`"\n"`, `"\x1b"`).
- **`catch` binds as `??`:** the two share a level and read left to
  right, as Zig's `catch` and `orelse` do: `f() catch none ?? -1` is
  `(f() catch none) ?? -1`. A jump handler still takes the rest of the
  expression, and a block below `catch |e|` is unchanged; a handler that
  compares, joins with `and` or `or`, or chooses with `if` is
  parenthesized, `f() catch |e| (1 if e == E.bad else 2)`.
- **Weak handles:** `*w` upgrades a weak handle to a `*T?` (`*<w`
  upgrades and takes it); the method `w.upgrade()` is rejected with a
  hint, and so is `*~T`, as every holding sigil over a held value is.
- **Numbers:** `x.not()`, the integer bit methods `leading_zeros`,
  `trailing_zeros`, `count_ones`, and `swap_bytes`, and the wrapping
  left shift `<<%` and `<<%=`.
- **Text and lists:** String `reserve`, `push[T, e]`, and List
  `reserve`; a byte order on a one-byte type is rejected; clearing a
  List of plain values sets its length.
- **Closures capture field paths:** a capture's sigil takes a field
  path as it does in an expression, `|?@template, k| fill(@template, k)`,
  lending, copying, taking, or holding weakly that field alone; in the
  body the path names the capture, and the closure reaches nothing
  else of the object (SPEC §11).
- **A closure never called is rejected:** alone on a line, discarded
  with `_ =`, or bound and never used, with one message; `_ = |x| ...`
  passed the checker and failed in the Zig it emitted.
- **Frozen values:** `*Frozen(x)` puts a value that never changes again
  behind a handle counted atomically, so many tasks read it with no
  copy (Rust's `Arc`). It holds only data that never changes, reads as
  the value through its handle, and compares and hashes as the value,
  so it keys a Map (SPEC §18, "Frozen values").
- **One message for one mistake:** a closure that stores a view of one
  field of a value into another (`|!p.a, ?p.b| !p.a.push(p.b)`) is
  reported where the closure is made, not again in its body, and a
  generic that names `*Frozen[T]` and freezes a `T` reports a bad
  instance once.
- **Owned closures:** `*fun` and `*sub` take and return anything a
  function's signature may hold: write and read views for the call,
  owners, and handles (docs/CORE.md §7). A temporary callee,
  `(+h.f)(x)`, is planned.
- **Vectors:** `Simd[T, n]`, `n` lanes of a number or `Bool` (`n` a
  power of two from 2 to 64): lane-wise operators that panic on
  overflow (`+%` and friends wrap), comparisons that give a mask
  `Simd[Bool, n]` with `any()`, `all()`, and `bits()`, `v.with(i, x)`,
  and byte reads with one bounds check. A vector is plain data
  (docs/CORE.md).
- **Modules at scale:** a directory is a module whose `.rig` files
  share one namespace, as a Go package's do: `use a.b` names the
  directory `a/b/`, a `use` binds its name in its own file, private
  names are module-wide, and each module emits one Zig file. Modules
  still may not import each other in a cycle. A method may be
  declared outside its type's body in the type's module
  (`fun Point.norm(?@)`, `fun Wrap[T].map[U](...)`), which
  desugars to the member. Module constants fold in dependency order,
  and one that depends on itself is rejected. A directory's
  `_test.rig` files belong to its module only as the root of `rig test`
  (docs/internals/INTERNALS.md, "Directory modules").
- **Methods on a type parameter:** a generic body calls a method on a
  `T`, `x.m(args)`, `!x.m(args)`, or `<x.m(args)`, checked at each
  instance as the built-in operations are: the instance's type declares
  the method, taking self as the sigil says, the arguments the body
  passes, and giving the result the body takes from where the call
  stands (SPEC "Generic bodies", Stage 1 of
  [docs/design/apis.md](docs/design/apis.md)).
- **Bounds:** a type parameter may name built-in APIs in its brackets,
  `[T: Ord]`, `[K: Hash + Print]`, and its body is checked against them
  alone; each instance must provide them, checked at the call. A type's
  header names the APIs it gives a meaning of its own, `obj Version:
  Ord`, which orders an object by its fields and an enum by its
  variants, then payloads. `Bool` and `String` are ordered (`false <
  true`, a String by its bytes), and so are optionals, arrays, and
  slices of ordered values, element by element (docs/design/apis.md,
  Stage 2). A `T` bounded by `Copy` is copied out of a view of it as out
  of a name: `fun get[T: Copy](x: ?T) -> T` gives `x`.
- **Own meanings:** a type that names `Eq`, `Hash`, `Ord`, or `Print`
  on its header and writes `eq`, `hash_into`, `order`, or `print`, with
  the signature the API fixes, gives `==`, hashing, ordering, or
  printing its own meaning, at every level of nesting; a type with its
  own `==` and no `hash_into` has no hash. The built-in types `Order`,
  `Printer`, and `Hasher` serve them, and `x.order(?y)` orders any two
  values that provide `Ord`. A method merely named `hash` is an ordinary method: a
  Map keys such a type by its parts, where it rejected it.
- **Map and Set are built in:** they and the types their members give
  (`Item`, `Items`, `Keys`, `Values`, `Members`) are named with no
  import, as `List` is, and print with no module; there is no
  `std.hash`. A module's own type of one of these names hides the
  built-in one. `tools/migrate-builtin-map.py` rewrites a tree's
  programs, tests, and Markdown: it removes `use std.hash` and the
  `hash.` before these names.
- **`text.Interner`:** the run-time string interner, which gives each
  string a dense `U32` id, is std.text's `Interner` (`use std.text`,
  then `text.Interner()`), apart from the built-in `Symbol`, a name the
  program writes. `tools/rename-interner.py` rewrites a tree's uses of
  its earlier name.
- **std takes bounds:** `Map[K: Hash, V]` and `Set[K: Hash]`;
  `sort`, `search`, `lower_bound`, and `math.min`, `max`, and `clamp`
  take `T: Ord`; `slices.contains` and `index_of` take `T: Eq`;
  `math.abs` takes `T: Signed + Ord`; and `sort.sort_by_key` sorts by a
  key that provides `Ord`.
- **Parameter names:** a type parameter starts with a capital letter and
  a compile-time value parameter with a lowercase one; `[t]` and
  `[N: Int]`, which earlier releases accepted, are rejected with the
  rename.
- **Evaluation order:** every assignment evaluates its value first,
  then its target's steps, then stores; the order is one recorded fact
  (`storage.SetOrder`, `storage.eachSetStep`) that emit and the
  ownership checker both read.
- **Errors:** `error` is a type, an error of any set (a parameter, a
  field, `List[error]`), and it is owning in every program: `<e`
  moves it and `+e` clones it (docs/CORE.md, "A failure moves its
  error").
- **Speed:** runtime fast paths for push, add, and clear; small,
  only-called functions are emitted `inline` by a size rule the
  compiler decides (`src/inlining.zig`); a function marked `inline fun`
  is inlined at every call, one marked `called fun` is always a call
  (`noinline fn`), and a block whose first line is `rarely` (a
  function's body, a branch, a `catch` handler, a loop's body) is laid
  out as the unlikely path with Zig's cold hint, and such a function is
  kept out of line (the three words are contextual; `rarely fun` is
  gone); a
  `for` index counter needs no per-iteration cast; a List index makes
  one bounds test, not two; and the proven checks cover Lists, Lists in
  fields, `for` ranges, `s[i + c]`, a bound through a bound, and flags:
  facts tested once before a statement, which omit the tests they prove
  while they hold, so a record read from consecutive slots or a loop
  whose bound may pass a List's length makes its tests once
  (docs/internals/INTERNALS.md, "Flags").
- **Lengths:** reading the length of a List, a String, or a slice
  makes no test: no List grows past `2^62 - 1` elements (growth past
  it panics, "length out of range"), and no buffer of elements of a
  byte or more can be that long (docs/internals/INTERNALS.md,
  `heldLen`).
- **The stack:** a program runs on a 64 MiB stack the runtime maps
  over a 64 GiB guard (`rig.onOwnStack`), so running out of stack, by
  deep recursion or a frame no larger than the guard, stops with
  `error: rig: stack overflow` in every build mode; each frame's reach
  (what it keeps and every value its code makes or copies) is held to
  a bound that keeps it within the guard by a measured factor, not yet
  a proven one (destination-passing, in [docs/internals/backlog.md](docs/internals/backlog.md), will make it one), and a
  large frame is never inlined; a fill a box or a local takes is built
  in place (docs/internals/INTERNALS.md, "The program's stack").
- **Release builds:** a conversion to an unsigned integer type from a
  signed one keeps its high bit (`U8(200) >= 128` is true), as do shift
  amounts and `$fromBackingInt`: they cast through the unsigned type of
  the source's width, since Zig 0.17 lowers a direct cast as LLVM
  `trunc nsw`, which made such values poison.
- **Heap profile:** a program built with `RIG_HEAP_PROFILE=1` (debug or
  release) reports at exit what owned its memory at its peak: live bytes
  by the type each block holds, largest first; `RIG_HEAP_PROFILE=sites`
  adds the calls that held the most, each as a short stack.
- **Map and Set:** a key of 8 bytes or fewer keeps no stored hash, so
  such a Map takes 8 bytes an entry fewer; Trig's ts-pattern peaks at
  403 MB rather than 425.
- **Inline room:** `List[T, inline: n]` keeps its first `n` elements (1
  to 1024) inside the List value itself and allocates only once it
  holds more, when they all move to the heap, so a short-lived List of
  a few elements makes no allocation. It has every member a `List[T]`
  has and is a type of its own (SPEC, "Inline room").
- **`reduce`:** `xs.reduce(start, f)` on a slice, an array, or a List
  passes the running value, `start` first, and each element in order,
  lent as `?T`, to `f`, and keeps what `f` gives; an empty one gives
  `start`. The running value moves through, so it may own what it holds
  (`people.reduce(String(), |s, p| String(s, p.name, " "))`); a closure
  that can fail makes the call fallible, ending at the first failure. It
  works in a generic body on a `[]T` through the APIs a type gives, and
  a closure written at the call is inlined in a release build, as fast
  as the loop written out (docs/STD.md, "reduce").
- **A match on an element:** `match v[0]` with an arm that reads no
  binding, such as `_ => 1`, compiles for Lists and Tables, as a value
  and as a statement; it failed in the Zig it emitted.
- **A closure literal given to an actor:** a method call through an
  actor's handle, waited on or run as a task, rejects a closure literal
  argument, as a task's call does: the actor runs it on a task of its
  own while its captures live in the caller's statement. `*g` of a
  function, where a `*fun` is expected, is rejected as `*g` alone is.
- **Tables:** `Table[T, n]` holds `n` slots from the moment it is made,
  each `T()` until written, and a `Slot[n]` is a number below `n` that
  only `push`, `Slot[n].of(i)`, and a literal below `n` make, so `t[s]`
  reads or writes its slot with no bounds test, whichever table gave
  `s`. A table of plain data whose default is all zero bytes reserves its
  slots with its own `mmap`, so untouched slots take no memory and the
  table never copies as it grows; other elements are made in every slot,
  up to 64 MiB. `Table()` is no field's default: a table is made where its
  owner is. A measuring build of Trig whose store indexes were treated
  as proven, a stand-in for tables, ran ts-pattern about 3% faster
  (fastest of 10, 2.8% fewer cycles); Trig's stores move to tables in a
  change of its own (docs/STD.md, "Table and Slot"). A generic call
  infers `n` from a `Slot[n]` argument, as from a `Table[T, n]`.
- **Compile-time functions:** a `fun` with only a bracket parameter
  list, `fun cap[n: Int] -> Int`, runs in the checker, and its call
  `cap[8]` is a constant wherever one may stand: an expression, a module
  constant, an array length (`[cap[4] * 2]Int`), a type argument
  (`Ring[Int, cap[1]]`), an enum value, and from another module. Its
  parameters are integers, `Bool`, and plain enums, its result one of
  those or a fixed array of them, and its body a fixed list of forms
  (locals, arithmetic, `if`, `match`, loops, arrays, and calls of other
  compile-time functions, recursion included). Overflow, a bad index,
  a `panic`, and more than 10,000,000 steps or 256 nested calls are Rig
  diagnostics at the call. Emit writes the value as a literal and never
  the function (SPEC, "Compile-time functions").
- **A closure stored into an existing slot:** a closure literal assigned
  to a `fun` local or through a write view is rejected as escaping its
  scope; it was accepted and failed in emit.
- **Optionals:** an object's `T?` of at most 8 bytes, such as one of
  a single `U32` field, is written in one store of its full width, the
  payload and its flag byte together, so a later read of the whole value
  is forwarded from that store; on x86, writing them apart stalled such
  reads (Trig's binder binds 7% faster on an x86 core). Its type and
  layout are Zig's `?T`, as before.
- **BOLT:** `rig build --release --bolt -- WORKLOAD` lays the
  executable out again with LLVM's BOLT, by a `perf` profile of the
  workload (Linux), and `--bolt-profile=FILE` keeps that profile or
  lays a later build out by it.
- **Compiler and tools:** a synthetic span outside its source reads as
  empty; the package cache and the build store have size caps;
  `src/parser.zig` is generated at build time from `rig.grammar`
  with Nexus, which is co-developed with Rig; and `tools/migrate-0.3.py`
  migrates 0.2 programs, each rename an independent pass (box, list,
  string, `obj`).
- **Rig's own repository:** `tools/heavy`, `test/rig.rip`,
  `test/matrix.py`, `tools/equiv.py`, and `tools/zig-next.py` find their
  git directory through `tools/gitdir`, which takes only a repository
  whose top level is Rig's. From a plain copy of Rig they stop with a
  message naming `GIT_DIR`, rather than keep a lock or a build store in
  a repository that encloses the copy.

### `std.json` (experimental)

A one-pass, validating JSON parser in
safe Rig (`std/json.rig`) that builds a tape, with a tiered string
scan (SWAR, then `Simd[U8, 16]`). `bench/json/check/compare.py`
checks it against Python's `json` module on 10,511 inputs;
`tools/fetch-json-data.sh` fetches the third-party files those read. `bench/json/` times it
against Zig's `std.json`, serde_json, simd-json, sonic-rs and
zimdjson (docs/history/json-results.md). Its API is not settled
(docs/design/json.md, "Open items").

### Concurrency

The model and its plan are
[docs/design/concurrency.md](docs/design/concurrency.md), with its reviews in
[docs/design/concurrency-panel/](docs/design/concurrency-panel/README.md). The plan's
first step is on `main` (SPEC §18):

- **Tasks:** `f(x)&` runs a call as a task and gives a `Task[T]`,
  which keeps its arguments' loans until `>t` takes its
  result; a task is never left running past its scope.
- **Cancellation:** `<t.cancel()`, a cancel that sticks, `std.task`
  (`Stop`, `check`), and a fallible `time.sleep`.
- **A cancel passes only down:** a task that cancels the tasks it owns
  is not canceled itself. A failed `par.map` or `par.each`, and
  `http.serve` closing its connections, no longer left the calling task
  canceled, failing its next wait with `task.Stop.canceled`.
- **Interrupts:** Ctrl-C (SIGINT) or SIGTERM cancels a `main` that can
  fail: its defers and drops run, the tasks it owns are canceled, and
  the program ends with status 130 or 143, showing no error. A second
  interrupt ends it at once; a `main` that cannot fail keeps the
  signals' default; `rig run` waits for its program to end.
- **Sets and joins:** `Tasks[T]` with `>ts` and `wait_first`, and
  `task.all`; a deadline for any wait is `time.within`'s, which calls
  its closure exactly once, so it may move a task or a set in.
- **Isolating a panic:** `task.isolate(f)` stops a panic in `f`, or
  in a task under it, cancels and waits for those tasks, leaves `f`'s
  frames where they stand, and fails with `task.Stop.panicked`
  (`tasks.Isolate`, `sched.runApart`).
- **Actors:** `*Actor(x)` holds a value that many tasks change, one
  method at a time: a call through a handle is a message in the
  caller's frame, waited for, or a task with `&` that takes a mailbox
  slot; a call not yet started is withdrawn on a cancel or deadline
  (`tasks.Actor`, `typecheck.actorCall`). A call that finds the actor
  idle runs inline, as the actor, at about a lock's cost
  (`Actor.claim`; bench/actors times it against a Go mutex and a Tokio
  actor). A wait that closes a cycle of actor calls and task waits
  panics, naming the calls (`sched.block`). A panic in an actor's
  method ends the actor and panics in its caller, and later calls
  panic (`Actor.kill`, `tasks.actorsDie`). `*Actor.supervised(*|| ...)`
  makes its value again after such a panic, within `restarts:` and
  `per:` (`typecheck.actorSupervised`, `Actor.remake`).
- **Deterministic tests:** `rig test` runs tasks on one thread with
  a virtual clock and a seed (`--seed`, `--seeds`, `RIG_SEED`), so a
  concurrent test fails the same way twice and sleeps take no time;
  the suite's concurrency cases run again under 20 seeds.
- **Deadlines and parallel loops:** `time.within(ns, || ...)`, a
  deadline every fallible waiting point honors, kept by the tasks it
  starts; it calls its closure once, so `time.within(d, |<t| >t!)`
  gives a deadline to a task, or a set, started before it. `par.map`
  and `par.each` (`std.par`), typed by the checker as `task.all` is,
  with chunks taken in turn by a task per worker.
- **Closures called once:** a parameter written `f: once ?fun() -> T`
  is called at most once, and a closure literal passed to one owns
  what it moves in, so its call may move it out
  (`resolve.recordOnce`, `Origins.once`).
- **Removed:** `within:` on a set's wait, `wait_all`, and `task.both`.
  A deadline is `time.within`'s, a set is waited for with `>ts`, and
  `task.all` takes two tasks; each removed form is rejected with the
  form to write.
- **Where tasks run:** on Rig's own scheduler (`src/sched.zig`,
  `src/tasks.zig`): fibers on a worker per core, `RIG_WORKERS` of
  them when set, with yield checks in long loops and recursion
  ([docs/internals/scheduler.md](docs/internals/scheduler.md)).
  Each worker sleeps in a poller of its own (kqueue, epoll), with its
  own heap of timers; a fiber can wait for a file descriptor to be
  ready (`sched.waitReady`). `std.net` builds TCP listeners and
  streams on it, as fast as Tokio's and Go's on loopback (bench/net);
  `std.http`'s `http.serve(<listener, |req| ...)` runs each
  connection as a task and each request isolated, a panic answering
  500 (`rig/net.zig`, `serve`). bench/http times it against hyper
  and Go: as fast as hyper on the Mac and about three and a half
  times its requests on pup, at 8.6 to 16.6 KiB per idle connection, below
  Tokio's and Go's: an idle connection holds no buffer (`net.Conn`).
  The server answers `Expect: 100-continue`, refuses a body over
  16 MiB with 413, closes a connection idle 60 s or a request head
  slower than 10 s, and pauses accepting when out of descriptors
  (docs/STD.md, std.http).
- **Waking a task wakes no other worker** when the worker that woke it
  runs it next, or the waker's next yield check hands it on
  (`sched.wake`): two tasks that answer each other over a socket stay
  on one worker, with no system call to wake another, and fork-join
  (`t = f()&; g(); >t`) spreads at `g`'s first yield check. The worker
  watching busy workers' pollers keeps the watch while they wake, so
  they kick no one as they do (`sched.sleepIn`).
- **Each worker on cache lines of its own:** no line holds two
  workers' fields (`sched.Worker`), so a yield takes about 5 ns on the
  Mac and 22 on pup's two hyperthreads, 45% and 12% less (bench/tasks).
- **Channels:** `*Chan[T](n)` sends and receives between tasks, and
  `task.select` commits exactly one of its arms (`tasks.Chan`,
  `selectArms`). `task.supervise(f, restarts:, per:)` runs a
  function isolated again after it fails or panics.
- **Function values cross:** a `fun` or `sub` value is a named
  function's address and holds nothing, so a task given or lent one,
  alone or inside an object, a List, or a channel, runs on any core. A
  callable view `?fun` and an owned closure `*fun` or `~fun` go to no
  task.
- **Local tasks:** a task given or lent what stays on one thread (a
  `*T` whose count is not atomic, a `Cell` of more than one word, a
  `Signal`) is local: it and the task making it are
  pinned to one worker, whose pinned queue no other worker steals
  from (`sema.localBlocker`, `Task.spawnLocal`, `sched.pinHere`).
- **The scheduler's cost:** `bench/tasks` times it against Tokio and Go, and
  `bench/tasks/PROGRESS.md` records each step: it starts, waits for,
  and switches tasks faster than Tokio, but a sleeping task holds
  one stack page (17 KiB on the Mac), where Tokio's holds about 300
  bytes.
