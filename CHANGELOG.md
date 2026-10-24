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

- **API objects cross tasks by a bound in their braces (APIs Stage 5,
  phase 1):** `Sends` and `Syncs` may stand in an object's braces where
  its form uses them (`^{Job + Sends}`, `^{Shape + Syncs}`,
  `?{Shape + Syncs}`, `!{Shape + Sends}`) and in its API's
  (`api Job: Sends + Owned`). Each is checked on the hidden value where
  its type is erased, a type parameter's by its bounds, and the error
  names the part that keeps it from crossing; then each form crosses by
  its row of SPEC §18's table, to tasks, channels, actors, and `par`,
  and a call through an object is a task when its self may go. A bound
  a form cannot use is rejected toward the one it can
  (`?{Shape + Sends}` toward `Syncs`), and a box's views name only the
  bound their form uses. An object without the bound a task needs goes
  to none, a local one included, naming the bound to write. An API's
  `Owned` now counts as the braces' does, and every built-in API an
  object's API builds on is checked at the erasure, so a generic type
  that provides the API only where its arguments do is erased only
  there (`^Wrap[Tok](...)` into `^{Shape}` of an `api Shape: Clone` was
  accepted and cloned a unique value). An owned closure captures no task
  or set of tasks: `*|<t| 7` was accepted, and let a task leave
  `task.isolate` or hide in an API object. The reference checker gains
  rule T1, an object given to a task without its bound. Of what this
  rejects, v0.2.9 accepted an owned closure that captures a task,
  `f: *fun() -> Int = *|<t| 7`; wait for the task first and capture its
  value. A generic body's erasure of a value holding a type parameter
  its bounds do not decide, `^Wrap[U](...)`, is checked at each instance
  for every bound the object names: it had passed them all, so a box of
  `Owned` could outlive what it viewed and a box of `Sends` could carry
  a `*Int` to another core. `par.map` over read views of objects no
  longer fails in Zig. A value erased where a task or an actor takes an
  object crosses by that object's braces, not its known type:
  `work(^Sum(...))&` to a `^{Job}` is rejected toward `^{Job + Sends}`.
  `*{Shape}` and `~{Shape}` stay unbuilt.
- **`rig check` and `rig lsp` on a file of a directory module:** the
  file is checked as its module, whose imports are beside the
  directory, so opening `src/ast/ast.rig` in an editor no longer reports
  its `use core` as a module it cannot read. A directory is a program's,
  and each file its own root, when one of its files declares `sub main`
  or `use`s a module found in it and not beside it (SPEC §1).
- **Docs: shared and crossing API objects in the Core (APIs Stage 5,
  phase 0):** CORE §1, §4, and sentences 8 and 9 state, as planned, that
  `*{Shape}` counts a value of hidden type and `~{Shape}` is its weak
  handle, that a frozen value's handle erases only to
  `*{Shape + Syncs}`, and that an API object crosses tasks only by a
  bound it names, with five `rig pending` examples; SPEC §18's crossing
  table gains the objects' rows, marked planned. docs/design/apis.md's
  Stage 5 and its build plan follow the approved text. Nothing is built
  yet.
- **A generic instance gives no task what goes to none:** a generic
  body that gives or lends a task a `T`, or a value holding one (a
  task's arguments, self, and result, an actor's value, arguments, and
  result, `par`'s elements, values, and captures), is checked at each
  instance with the crossing walk that checks a known type, at the call
  that makes the instance, with a note at the task. An instance whose
  `T` holds an owned closure, an API object, or a set of tasks is
  rejected, and so is one whose `T` stays on one thread (`*Node`) where
  the body's task crosses, which ran on another core. A method of a
  generic type, or an API's default, is checked at each type that
  reaches it (a call, a call through a bound, or erasure to an object
  of its API); one never reached is not compiled and is not checked. A
  generic body that erases a `T` to an API object, or gives one out of
  `task.isolate`, is checked at each instance for a task the `T` holds.
  A bounded or `pub` generic whose calls give its `T` to a task that
  crosses states `Sends` or `Syncs`. Whether an API object crosses
  (`Sends`, `Syncs`) is decided by the same walk. v0.2.9 accepted the
  forms this rejects, each of which let a value reach a task its known
  type could not: `spawn(<cb)` of `fun spawn[T](x: T)` whose body runs
  `use(<x)&`, with `cb: *fun() -> Int` or `n: *Node`; `par.map(xs, f)`
  over a `?List[T]` of owned closures; `*Actor(Box[T](x: <x))` with `T`
  an owned closure; a `fun go[T](f: fun() -> T)` whose task `call(f)&`
  gives back an owned closure; `h.go()`, an API default whose task
  takes `?@`, on a type holding an owned closure;
  `task.isolate(|<x| keep(<x))` with `T = Task[Int]`; and a `pub fun
  outer[U]` that passes a `U` to a generic whose task crosses, which
  now writes `[U: Sends]` or `[U: Syncs]`.
- **Boxes of API objects (APIs Stage 4, phase 3):** a `^T` moves into a
  `^{Shape}` and keeps its allocation, `<c` or a `^Square(...)` written
  where one goes, and a `^T?` into a `^{Shape}?`. A box lends its
  `?{Shape}` and `!{Shape}`, is replaced by assignment, and drops its
  value through its table and the drop queue, so `next: ^{Node}?` chains
  of any length drop without deep recursion; a List of boxes grows,
  sorts by a key, and clears. `<b.close()` ends the box, which drops its
  value once even when the method fails. A box clones through its table
  where its braces or API name `Clone`, and prints where they name
  `Print`. Its loans last to its drop; with `Owned` in its braces,
  checked on the erased type, it holds none, and an owned closure takes
  it. An object has no default value (`Table[^{Shape + Owned}?, n]`), an
  error's field holds none, and a Cell of one is Stage 5's. An object
  goes to no task, a local one included, since its hidden value may hold
  an owned closure or a set of tasks: this narrows Stage 4's default 14,
  which made a task over a call through one local (the owner's decision,
  2026-10-23). A call through a generic type at
  arguments that hold an object, `Ph[^{Shape}].mk()`, is built too. No
  value that holds a task or a set of tasks is erased, and a generic
  body prints an object only where its braces or API name `Print`. A
  channel and an actor print as `<chan>` and `<actor>`, where printing
  one failed in Zig.
- **API objects lend and call through a table (APIs Stage 4, phase
  2):** a value lends `?{Shape}` and `!{Shape}` by the lend table's last
  row, through boxes, handles, frozen handles, and optionals, unwritten
  where it lasts only for a call (`area_of(sq)`), and `s.area()` or
  `Shape.area(s)` calls the hidden type's method, an addition's, or a
  default through the API's table, `__rig_table_Shape_of(T, W)`, which
  Zig makes once per API and type. A call is checked by the API's
  declaration, passes on only its `from` and `keeps`, and fails with
  its set, a set's fields through the slot. An object carries every loan
  of its value to its last use; through a `!{Shape}` nothing assigns,
  swaps, or copies the value; an object is never cloned, compared, or
  hashed, and prints only by the braces' or API's `Print`. An object of
  a read view of plain data, or of a type parameter's value, views a
  copy local to its block, and is rejected where it would leave it. A
  call through an object costs what a call through a `?fun` does
  (bench/apis).
- **API object types (APIs Stage 4, phase 1):** a type may name an API
  in braces behind a view or a box, `?{Shape}`, `!{Shape}`,
  `^{Shape}`, with `Owned`, `Print`, and `Clone` beside it, `^{Shape +
  Owned + Print}`. The compiler checks what the braces name (one API
  of a program's own; a type, a type parameter, a second API, `Copy`,
  `Eq`, `Hash`, `Ord`, and the number APIs each rejected with why;
  crossing tasks and `*{Shape}` Stage 5's), rejects a bare `{Shape}`
  anywhere a value's type or a type argument goes, inferred too, and
  decides the bounds an object meets and the methods a call through
  one reaches. A type alias names such a type and `$name` spells it; a
  value holding an object, an erasure, a call through one, and a call
  through a type that holds one (`Ph[S].mk()`) are rejected as not
  built yet, and no frozen value holds one. A brace in an expression
  says to name the type with an alias, and one anywhere else keeps its
  message, "Rig has no braces".
- **Docs: API objects in the Core (APIs Stage 4, phase 0):** CORE §1
  and §4 state, as planned, that an API object (`?{Shape}`, `!{Shape}`,
  `^{Shape}`) hides its value's type, never its loans, with two
  `rig pending` examples; docs/design/apis.md's Stage 4 and its build
  plan follow the approved text. Nothing is built yet.
- **Public generics state their bounds (APIs Stage 3, the last step):**
  a `pub` function, a `pub` type, and a `pub` method of a `pub` type
  name, by bounds, everything their bodies do with each type parameter
  that an API names: a copy, `==`, ordering, `.hash()`, printing,
  arithmetic, keeping a `T` where no loan is tracked, crossing to other
  tasks, a call of another generic or a type bounded so, and a method
  call, which goes through an API. The error is at the parameter, with
  the bounds to write: `` `pub fun sum[T]` adds `T`s: write `[T: Num]`
  ``. A bound a signature's types already require counts as stated:
  `K` named in `Map[K, V]`, or in a type whose field names one, is
  `K: Hash` without saying it, whether or not it has bounds of its own,
  so `[K: Print]` no longer restates `Hash`. A private generic keeps
  per-instance checking, and what no API names (a literal's fit, a
  table's default, freezing) is checked at each instance everywhere. A
  bound asked of an argument made of other types in a signature
  (`Chain[Pair[T, U]]` under `Chain[T: Copy]`) is checked once every
  type's contents are known, where it crashed the compiler. Printing a
  view of a `T` (`print(x)`, `x: ?T`) needs `Print`, as printing a `T`
  does. *Rejected now:* a `pub` generic whose body does with a type
  parameter what its bounds do not name, which earlier releases checked
  at each instance. `tools/state-bounds.py PROGRAM.rig` writes every
  such bound from the compiler's own fixes (`--dry-run` prints the
  diff); std and examples/ need none, and Trig's src/ needs 51 bounds
  on 49 declarations.

- **A method's view names the path of self it views:** `-> ?String from
  @text` (also `from @a.b`, and beside parameters, `from @map, k`) lets
  the result carry the loans self holds and a loan on that path alone,
  so the caller may write self's other fields while it lives (Core
  sentence 7). A path that is a field declared as a read view (`?T`,
  `[]T`, `?String`) puts no loan on self, so self may be lent again,
  even to write: a Map's and a Set's iterators say `from @map` and
  `from @set`, so their items outlive the step of the loop, a function
  lent an iterator holds two items at once, and `iter.count` and any
  body bounded by `Iter` take them. The body is checked against the
  path. A path in `keeps`, in an API, through a read view, beside `@`,
  or of more than 8 fields is rejected with the fix. A task through
  such a method (`(!it).next()&`) keeps all of self lent until it is
  waited for.

- **A slot compares with a literal below its count:** `s == 0`,
  `0 == s`, `s != 3`, and `s < 3` for a `Slot[n]` were "cannot compare",
  though the literal is a `Slot[n]` at an assignment, an argument, and a
  return; beside a slot in a comparison it is one too, checked to fit
  below `n`.

- **A narrowed error is a view of the caught one:** a `g: E =>` arm
  under `match e` bound nothing the ownership checker saw, so `<g`,
  `y = g`, and a `?g` kept past the handler were accepted and read
  freed memory. The arm binds `g` as a payload is bound: a view of `e`
  under `match e`, the error itself under `match <e`. The reference
  checker (`bin/rig-oracle`) found it, now that it models CORE's "A
  failure moves its error": the hidden `E?` a fallible call's statement
  holds, which `!` returns, `catch |e|` moves into the handler's own
  binding, and a nameless catch drops, and the `g: E =>` arm, on which
  it abstained.

- **A generic body hands its caller no view it never declared:** a body
  that called a `keeps` method on a `T` it held by value, then moved the
  value into its caller's List, let the caller drop what the view read
  and read freed memory. Such an instance is refused at the call that
  makes it, as the call through a bound already was.

- **Errors compared with a member:** an `L?` of a union with fields
  tested with a member of a set without fields (`o == .y`) failed in
  Zig; it tests the member. A member with fields written as a shorthand
  beside an error (`l == .x(n: 3)`) failed in Zig or with an internal
  error; it is told to name the set, `A.x(n: 3)`, and beside an
  optional, to unwrap it first. SPEC says that a comparison of made
  `T`s in a generic body needs `Copy`, or a binding of each. The HTTP
  server test's descriptor check waits up to 2 s for the server to
  accept again.

- **A wait fails with the set its work declares:** `task.all`,
  `par.map`, `par.each`, `task.isolate`, and `task.supervise` failed with
  any error even where what they wait for declares a set, so a function
  declaring that set could not pass their failure on with `!`. Each now
  fails with that set when it holds `task.Stop` (for `task.all`, the one
  of its tasks' sets that holds the others), as a set of tasks does.

- **A generic body takes a `T`'s failure as the value's fallible:** a
  call on a `T` caught in a `-> Int!` body was taken as an `Int!!`, which
  the message showed; it is an `Int!`. A body declaring a set of its own
  that passes such a failure on with `!` is told that a call on a `T` is
  taken to fail with any error.

- **A frozen value's handles order by what they reach,** as they compare
  and hash: `*Frozen[T]` provides `Ord` when `T` does, so `<`, a `T: Ord`
  bound, and `sort` take it.

- **A variant written with an empty payload, `a()`, is bare:** an enum
  of `a()` and `b` compared with `==` but was refused `<` and `Int(x)` as
  having payloads. One classifier now says an enum is plain
  (`sema.isPlainEnum`), and the values `Int(x)`, ordering, and
  `$variants` read go through it.

- **`.len` of a List behind a shared handle is an `Int`:** `0..f.len`,
  `n = f.len`, and `f.is_empty()` of a `*Frozen[List[T]]` or a
  `*List[T]` passed the check and then failed in Zig. One classifier
  (`hasLenReached`) now says a length is read through handles and
  boxes alike.

- **Small fixes the Learn Rig journeys found:** a local a closure uses
  without capturing it is reported once for each closure, at its first
  use; `List(...)` of objects, and an array lent where a `?List[T]`
  goes, name the form that works (an empty List pushed into, or a `[]T`
  parameter); `RIG_LEAK_TRACE=1 rig test` shows each leaked
  allocation's trace after the summary, and the leak note names the
  command that was run; what `print` buffers is written out before the
  program goes idle waiting on I/O or time, so a server piped to another
  program shows its first line while it waits; and `rig check
  --facts=proofs` names the file of each line in a directory module.

- **`rig check --tasks` lists each local task,** each task that stays
  on its maker's thread, in source order, module by module: its file,
  line, and column, the call that makes it, the part that pins it, and
  the type in that part that cannot go to another core. A directory
  module's lines name their file; a program with no local task prints
  nothing.

- **An ordering in a generic body reads its operands as `==` does:** a
  made `T` beside `<`, `<=`, `>`, or `>=` is a temporary of `T`, which an
  instance that owns a resource cannot leave, and which a body bounded by
  `Ord` alone cannot leave either (`[K: Copy + Ord]`, or bind it to a
  name). Before, `f() < f()` with `K = String` leaked both Strings, and
  so did `sort.sort_by_key` with an owned key; it now binds each key to a
  name and drops it. A generic body that ordered made values of a type
  parameter without `Copy` is now rejected.

- **An error code widens to a union that holds it where a view of the
  union goes:** for sets without fields, `m.get(B.y)` for a
  `Map[L, Int]` of `error L = A | B`, and `take(B.y)` for a `?L`
  parameter, were rejected with a hint, `?B.y`, that led to another
  error, and `o == A.x` for an `L?` was "cannot compare". Each now takes
  the member as a value of `L`. Where the union has fields, the error
  says to bind it as the union first. Fixed with it: an `L?` of a union
  with fields compared with one of its members (`o == .w`) failed in
  Zig.

- **Three programs `rig check` accepted that Zig rejected, and a message
  that blamed recursion on a chain.** A vector's and a number's built-in
  methods (`with`, `select`, `bits`, `lookup`, `lag`, `not`,
  `count_ones`, `to_bits`, ...) read their `self` through a call's
  write view (`vs(!v, 0).with(0, 7)`), as an operator's operand is
  read. The runtime's walk over a type's parts (`rig.needsDrop`) takes
  the budget an emitted function does, so an object of many fields, or
  a chain of objects, kept in a `List` compiles. A type nests at most
  1000 levels by value (an object, enum, optional, array, or vector each
  a level), past which Zig's compiler runs out of stack; a deeper one is
  rejected once, at the first type past it. A clone, an error's fields,
  and the drop-body check follow a type to any depth, not only 32
  types down. A chain of distinct generic functions whose type arguments
  nest more than 24 deep is reported as that, not as a function calling
  itself. *Rejected now:* a type nesting more than 1000 levels by value,
  which Zig could not compile past about 1250.

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

- **APIs of a program's own (Stage 3, declarations and conformance):**
  `api Shape` declares the methods a type provides, required or with a
  default body, and may build on other APIs and on the built-in ones
  (`api Job: Moves`). A type provides one on its header, `obj Square:
  Shape + Print`, and `add Int: Shape` or `add Wrap[T: Shape]: Shape`
  gives one to a built-in type, another module's type, or a type under a
  bound. Each method meets its API exactly, but for a narrower `from`
  and `keeps`, and compile-time parameters match in kind, type, and
  bounds; a type provides an API once in the program, in its module or
  the API's, the APIs an addition's API builds on included; an addition
  names no member its type has, a String's `push` included; and a bound
  by an API, `[T: Shape]`, holds at each instance. `api` and `add` are keywords only at the start of a
  module-level declaration, before the name it declares or the type it
  names, so `user.api`, `!set.add(x)`, and a binding named `add` stay
  names; `trait` and `impl` say to write `api` and `add`. A type, an
  API, or an alias named `Int`, `Float`, `Bool`, or a sized number is
  rejected, as one named `String` is: an `obj Int` was accepted and
  never reached, since the name named the built-in type.

- **APIs of a program's own (Stage 3, calls through a bound):** a call
  on a bounded `T`, `x.area()`, is typed from the API's declaration: its
  self, parameters, compile-time parameters, and result with its failure,
  so `x.size()!` passes the API's set into a frame whose set holds it,
  `catch |e|` gives `e` that set, and a set with fields passes them
  through the slot; ownership reads the API's `from` and `keeps`, which
  every implementation is within. A call through a bound may be a task
  and may stand in a closure. `Shape.area(c)` calls a method through the
  API by name, and `c.area()` on a type with no `area` of its own
  reaches the default or addition of the one API the module sees that
  gives it one; two such APIs make the call name one. A call on a `T`
  with no bound that would reach a default or an addition says to write
  the bound. Each conformance has a witness, `__rig_impl_Shape_Square`,
  beside it, naming the type's methods, an addition's, and the defaults
  it takes; each bound adds one compile-time parameter, its witness,
  after the type it bounds, a generic type's included, so `Bag[Square]`
  stays one Zig type. Defaults' bodies and additions' methods are
  checked and lowered: a default as a method generic over `Self`. Every
  method call records how it dispatches, `direct` or `static`, and `rig
  check --facts=sema` prints it. A call through a bound that would store
  a view of a local in a value of a type parameter's type is rejected. A
  type parameter with no bound meets no bound by an API (`Bag[U]` or
  `total(x)` in a body whose `U` has none), which phase 1 left to each
  instance: the error gives the bound to write.

- **APIs of a program's own (Stage 3, method bounds and additions):** a
  method declared outside its type's body may bound the type's
  parameters, `fun Wrap[T: Print].show(?@)`: its signature and body have
  the type's bounds and these, a call's type argument provides them, and
  it takes a witness, after self, for each API of a program's own they
  name. A bound the type already gives, and `Copy`, `Clone`, `Owned`,
  `Moves`, or `Shares` (or an API built on them), are rejected toward the
  type's brackets; such a method meets no API on the type's header, gives
  no own meaning, and is no loop's `next`, and a call on a `T` with no
  bound, or on a `Wrap[U]` whose `U` has none, reaches it with an error.
  `add` names a type's value parameters as its type parameters, `add
  Slot[n]: Shape` and `add Table[T, n]: Shape`, whose witnesses are
  functions of `n`; every `Slot[n]` is one type constructor for
  coherence.

- **APIs of a program's own (Stage 3, associated types and `Iter`):**
  `type Item` in an API names a type each provider chooses, by what its
  methods give where the API's required methods name it; a bounded body
  reads it `S.Item` and bounds it by built-in APIs as an entry of its
  own, `[S: Source, S.Item: Ord]`, checked at each instance with what it
  does that no API names. A witness carries each associated type (`pub
  const Item = i64;`). `Iter` is the built-in API a `for` loop walks: a
  type with `next(!@) -> T?` provides it, by the loop's own rule, with
  `Item` its `T`; `[I: Iter]` loops over and calls `next` on an `I`, an
  API may build on it, and no header names it. std.iter gives `count`
  and `sum` over any iterator; every std iterator is an `Iter` whose item
  is what the loop gives. An instance whose associated type may view
  memory its base owns is rejected, since a generic body does not track
  that view across `next`; a Map's and a Set's iterators are walked by a
  loop instead.

- **APIs of a program's own (Stage 3, the proof):** formal/ proves, in
  Lean, that a call checked against an API's `from` and `keeps` is
  sound for any implementation whose clauses are within them, by
  position: over the machine's loans, every view such an implementation
  leaves behind stays live through whatever the caller's record allows
  (`within_live`); and a λRig program whose calls, taking read views,
  are checked against their APIs' clauses alone runs without a fault
  for any such implementations (`api_calls_run`).

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
- **`time.since_start()`:** the nanoseconds on the monotonic clock
  since the program started, an `Int`, so a plain function value reads
  a duration with no `Instant` to hold (virtual in a deterministic run).
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

std.json: an escaped string checks its length once, so safe builds keep
#538's gain on x86 (pup's safe builds are back within 2% of the earlier
reference on every file). Canada runs 2.4-2.8% (pup) and up to 4% (Mac
safe) slower than before, which is layout and is noted, not fixed.

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
- **Renamed:** the task bounds `Moves` and `Shares` are `Sends` and
  `Syncs`, Rust's words: the sigils `<` and `*` name moves and sharing
  within a task, the bounds name crossing to other tasks. The old names
  are rejected with the new ones.
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
  they kick no one as they do (`sched.sleepIn`). A worker going to
  sleep, or a check that takes the notice of waiting work, leaves that
  notice set while another worker's run-next slot holds a task
  (`sched.takeWaiting`), so a maker computing in recursion, whose checks
  read only the notice, hands the task on; one that cleared it left the
  task waiting until the maker finished.
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
