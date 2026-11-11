# Changelog

What changed in Rig, newest release first. An entry "Unreleased",
when there is one, lists what `main` carries beyond the last tag; each
release's notes, its summary, are in [docs/releases/](docs/releases/).
0.3.0's "Upgrading" section goes with the migration guide,
[docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md).
[HANDOFF](HANDOFF.md) says where the work stands, and
[docs/ROADMAP.md](docs/ROADMAP.md) lists what is planned.

## Unreleased

### Upgrading from v0.3.0

**`loop` is a keyword, and the one loop that gives a value**:
`loop` repeats its block until a `break` leaves it, and
`r = loop` ... `break v` gives `v`. `tools/migrate-loops.py PATH`
rewrites `while true` and `while (true)` to `loop`, and flags each of
the others below, and each name `loop`,
with a suggested rewrite (it changes no other code). These are rejected
now, each with the Rig spelling in the message:

- `while true` or `while (true)`: "write `loop`: `while` takes a
  condition that can end it". Only the literal `true`; `while cond` is
  unchanged;
- an `else` on any loop: "a loop has no `else`; to act when nothing
  matched, test first, as in `if not xs.any(f)` or `xs.find(f) ?? d`";
- a `for` or `while` used as a value, and `break v` in one: "a `for` or
  `while` loop gives no value; use `loop` with `break v`, a chain such
  as `xs.find(f) ?? d`, or `return` from a function";
- `loop` as a name, and `file.FileError.loop`, which is
  `file.FileError.link_loop`. A keyword written as a name says so:
  "`loop` is a keyword; choose another name".

Trig has no loop `else`, no loop used as a value, and no `break v`; its
`while true` lines are what the script rewrites. loco has one `while
true`. A labeled `loop` may be a binding's or `return`'s value,
`r = $found: loop`, left from an inner `for` by `break $found v`: the
search that a `for` ... `else` wrote.
`List.index_of(x)` gives the index of the first element equal to `x`,
or `none`, as `slices.index_of` does. A block after `??`, a list
comprehension, `x => ...`, `lambda`, `if let`, `o or 0` for an
optional, `range(3)`, and `enumerate(xs)` are rejected with the Rig
spelling, where each got a parse error or an unbound name.

**`extend_from_bytes` and `$embed` records read only `exact` objects**
(a change to main since 0.3.0, which had neither): an object made from
bytes, a literal's, a `?String`'s, or an embedded file's, is declared
`obj Name exact`, which holds its fields in
declaration order with no padding, so its bytes are the record's. Any
other object is rejected with the fix: "`Span` is not `exact`, so Zig
may lay out its fields in an order of its own: add `exact` to `obj
Span`". `tools/migrate-exact.py PATH` adds the word where `rig check`
asks for it.

**A duration's bare number is seconds now, where 0.3.0 read
nanoseconds:** `time.sleep(5)` sleeps five seconds, and 0.3.0's
`time.sleep(5)` is `time.sleep(ns: 5)`. `tools/migrate-durations.py
PATH` rewrites a 0.3.0 program's durations so that each means what it
meant; run it once ([docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md),
"From 0.3.0 to 0.3.1"). It changes the meaning of every `time.sleep`,
`time.after`, `time.within`, `time.Instant.at`, and Instant `add` given
a bare number, and of `per:` of `task.supervise` and
`*Actor.supervised`. 0.3.1 rejects these, which 0.3.0 accepted:

- a bare duration that names one of std.time's constants, which count
  nanoseconds: `time.sleep(5 * time.MS)`, `time.sleep(time.SECOND)`,
  `time.within(2 * time.SECOND, f)`, `late: time.after(time.MS)`,
  `t.add(3 * time.SECOND)`, rejected for `ms: 5`, `1`, `2`, `ms: 1`,
  and `3`; and `per: time.MINUTE`, for `per: 60`;
- a duration more nanoseconds than an `Int` holds, as a constant:
  `time.sleep(10_000_000_000)` (ten billion seconds);
- a name of a several-result binding, `if f() as a, b`, that reuses a
  visible local's name: "optional binding `a` shadows the local `a`",
  as `if g() as a` already said. It holds in an `if`, an `else if`, a
  `while`, and a ternary (`x = a + b if pair() as a, b else a` gave
  `a` two meanings). Rename the binding.

**Four ownership holes are closed**, each rejecting programs 0.3.0
accepted:

- a write view of a read view, `x` of `for x in !vv` over a
  `List[?T]`, reaches its value only to read it: `for n in !x.ns`,
  which built and wrote through the view, is rejected, "cannot
  write-iterate through a read view", as are the writes and lends
  through `x` that Zig rejected. Write through the values' owners;
- a box of a read view, `^?T`, reaches its value only to read it, as
  the view does: a consuming method through it (`(^<b).eat()` or
  `<x.eat()` of an `x = ^?b`, which freed the value `b` viewed), a
  write method, a write lend (`!x.v.push(1)`), an assignment (`x.n =
  2`), and a `match !x` are rejected: "method `eat` consumes `self`;
  cannot consume through a view", "cannot lend to write through a read
  view". Take a write view, or own the value;
- a `defer` body that moves an outer binding and assigns it again,
  `defer head = ^Node(v: 1, next: <head)`, is rejected, as one that
  only moves it was: "a `defer` body cannot move or drop `head`". Write
  the deferred code in a block that owns what it moves;
- a one-line `defer` that binds several results to new names, `defer
  _, z = two()`, is rejected, as `defer z = one()` was ("a deferred
  statement runs at scope exit and cannot declare `z`"), where `rig
  check` crashed.

**Programs `rig check` accepted and Zig then rejected** are rejected
now, each with a Rig diagnostic; but for a builtin alone as a statement,
none of these ever built:

- `&` on a constructor typed by where it goes, `v: List[Int] =
  List()&`, `m: Map[K, V] = Map()&`, `p: P[Int] = P(x: 1)&`, `e: E =
  .v(x: 1)&`: "a task runs a call of a function or a method", as
  `List[Int]()&` already said. Drop the `&`.
- `defer defer s`, `errdefer defer s`: "a deferred statement cannot
  itself be a `defer` or an `errdefer`". Write one.
- a builtin alone as a statement, `$plain(T)` (which Zig rejected) or
  `$size(T)` (which built and did nothing): "this expression does
  nothing as a statement". Remove it, or use its value. Neither Trig
  nor loco has one.
- a box where a type parameter bounded by `Iter` goes, `show(!w)` of a
  `w: ^Words`: name the iterator's type, `show[Words](!w)`.
- a closure literal with an untyped parameter where a generic
  parameter that is no function goes, `app(|x| x)` for `xs: ?List[T]`:
  "closure parameter `x` needs a type", or "cannot infer `T`", where
  `rig build` reported an internal error.

### Added

- **`task.workers(n)` raises the workers after the first task.** A program that learns how much work it has only once running, as a checker does after parsing, can ask for more workers then. It only raises; it gives false for fewer than run, and a deterministic run keeps to one thread.
- **Dense stacks.** `rig build --release` gives a task that cannot need much stack a dense stack, which holds 17.6 KB on the Mac where a large one holds 33.5 KB. A task with recursion, or a call through a pointer, keeps a large stack, as does every task of a debug build or `rig run`.
- **`task.fast_cores()`** gives how many fast physical cores the
  program may run on, at least 1: on macOS the performance cores, on
  Linux the affinity mask's cores, the threads of one core counted once
  and slower cores left out while a fast one is allowed. The number of
  workers does not follow it: tasks still run on one worker per logical
  CPU.
- **Text over several lines** (T1c): `"""` (with escapes) and `'''`
  (raw) open fixed text over several lines, a `Static`, when the opener
  ends its line, and a backtick that ends its line opens a template over
  several lines. The closer's column is the margin: spaces past it are
  text, a line less indented than a closer alone on its line is an
  error, a line of only spaces is empty, the spaces ending a line are
  dropped, and a tab in the margin is an error, so moving the text never
  changes it. Mid-line, `'''abc'''` is still the raw string `'abc'`
  (SPEC "Text over several lines").
- **Backtick templates** (T1b): `` `{name} is {age}` `` builds text
  from pieces and slots, and the place decides what it becomes. In
  `print`, `warn`, and `panic` its pieces are written straight, with no
  allocation and no separators; in `String(...)` and `!t.add(...)` they
  are the call's arguments; where a `?String` goes it is a temporary of
  its statement, built in 256 bytes of the caller's stack and then the
  heap; where a `String` goes (a binding, a field, a return) it is a new
  String of its length. A slot takes what a print argument takes;
  `{=e}` shows the expression and its value; `\{`, `\}`, and
  `` \` `` are literal, and a `"` needs no escape. A template whose
  slots are all constant Ints, Bools, and `Static`s is fixed text, a
  `Static`, so a module's constant may be one; a Float, an enum, or a
  show slot is written as the program runs. The strict rules (no slot, an empty slot, a literal slot, a
  `:`, `#`, or template in a slot, a name touching a backtick, ``` `` ```,
  a lone `}`, and `` s = `{s}…` ``) are errors with hints (SPEC
  "Templates").
- **A large embedded table loads without a copy on macOS too**: a
  macOS release build maps 64 KiB or more of an embedded file added to
  an empty List from the program's own file, as a Linux one does,
  finding the run in the image's read-only segments (`LC_SEGMENT_64`)
  at its slide. Trig's peak memory on the Mac is 9.2 to 9.5 MiB lower
  on zod3 and ts-pattern at one, four, and its balanced checkers, with
  no run slower (SPEC "List").

- **A large embedded table loads without a copy** in a Linux release
  build: `!xs.extend_from_bytes($embed(path))` of 64 KiB or more into an
  empty List maps the file's pages from the program itself
  (`MAP_PRIVATE` of `/proc/self/exe`), read when first touched and
  copied when first written; growing the List copies it as growth does.
  On Trig, whose lib trees load this way, mitt runs 17.3% fewer cycles
  and neverthrow 14.5%, with less memory (SPEC "List").

- **`obj Name exact`** holds an object's fields in declaration order
  with no padding, a Zig `extern struct`, so its bytes are its fields'
  one after another, as a file of records lays them out. Each field is
  a number, a `Bool`, a plain enum, an `exact` object, or a fixed array
  of them; padding is written as a field (`_pad: [3]U8`), and a
  declaration that needs hidden padding is rejected, naming the field
  and the bytes. `exact` is a word only after an `obj` header's name
  (SPEC "Objects").

- **Durations in four forms:** a call of std.time that takes a length
  of time writes it bare in seconds, `time.sleep(2)`,
  `time.sleep(0.5)`, or with one unit's keyword, `time.sleep(ms: 40)`,
  `us: 40`, `ns: 40`; the value of each is an `Int` or a `Float`, a
  `Float` rounded to the nearest whole nanosecond, a half away from
  zero. `time.sleep`, the deadline arm `time.after`, `time.within`,
  `time.Instant.at`, and an Instant's `add` take them; `per:` of
  `task.supervise` and `*Actor.supervised` is in seconds, `per: 0.5`.
  Two units, a keyword beside a bare number, `seconds:`, a non-number,
  and a constant that is not finite or that no `Int` of nanoseconds
  holds are rejected, each with its fix; at run time a NaN, an
  infinity, or an overflow panics. Typecheck decides each argument's
  unit once (`sema.duration`, the parameters std.time declares `ns:
  Duration`), and emit writes the nanoseconds through the runtime's
  `durationInt` and `durationFloat` (SPEC "Durations").

- **`!xs.extend_from_bytes(s)`** appends to a `List[T]` the records the
  bytes of `s` hold, a `?String` or a `Static` such as `$embed(path)`,
  with one copy and one growth. `T` is an integer, a float, or an object
  or array of them with no padding and no named none, so every bit
  pattern is a value;
  each record is its fields' bytes in declaration order, in the
  machine's byte order. Any other `T` is rejected with the field that
  disqualifies it (`field `on` of `Flag` is a `Bool`, which is only 0 or
  1`), and so is a literal or an embedded file that is not a whole
  number of records; another length panics (SPEC "List").
- **An embedded file's records may hold `Bool`s and enums:**
  `!nodes.extend_from_bytes($embed("nodes.bin"))` of an object with a
  `kind: Kind` field. The compiler reads the file and checks every
  record, each `Bool` 0 or 1 and each enum a variant's value, and names
  the first that is not: `` `extend_from_bytes` reads whole `Node`s from
  "nodes.bin": field `kind` of record 3 (byte 36) holds 900, and no
  variant of `Kind` has that value ``. A `Bool` is one byte, an enum of
  declared values four, any other plain enum the fewest of 1, 2, or 4
  bytes that number its variants. Bytes known only at run time, a
  `?String` or another `Static`, still make no such record (SPEC
  "List").
- **An embedded file is held at 16 bytes** in a build by LLVM (every
  release, and a debug build on macOS): the assembler includes it
  (`.incbin`) after a `.balign 16`, which costs a build no more time
  and less memory than `@embedFile`, where an aligned Zig constant of an
  8 MB file costs 1.5 s and 430 MB more (INTERNALS, "Embedded files").
- **`$embed(path)`** gives a file's bytes as a `Static`, read when the
  program is compiled: `LIBS = $embed("libtrees.bin")`. The path is a
  string literal, from the directory of the file that names it, and may
  not be absolute or leave the program's directory. The bytes are taken
  as they are, with no escaping and no literal for the compiler to read:
  `rig check` opens the file and reads none of it, and the package
  holds a copy beside the emitted Zig, so a build after the bytes
  change builds again (through the cache, `RIG_BUILD_STORE`, a kept
  `rig build`, a split build, and a batch). A missing file, a
  directory, and a file of 2 GiB or more are rejected where the call is
  written: `$embed: cannot read "libtrees.bin" (no such file),
  relative to src/ast/prebuilt.rig` (SPEC "Builtins").
- **A task's end as an arm of `task.select`:** `done: ?t.on_end()`
  completes once the task `t` has ended, before the select or while it
  waits, beside the receive, send, and deadline arms. The arm lends `t`
  to read, so its variant carries nothing and the select neither waits
  for `t` nor takes its result: the winner's body takes it with `>t`
  (`>t!`, or `catch`), which gives it at once. A task that fails or is
  canceled has ended as any other; the select fails only with its own
  cancel or deadline. Two task arms are a race. The arm waits on the
  task's completion record (`sched.Done`) and takes its wait back as
  the select returns, so a task moved on after its arm lost ends with
  no stale waiter (SPEC "Channels").

### Compiler

- An object or payload enum that holds a generic of another module
  whose fields name the generic's parameter as an optional (`kids:
  List[T?]` in `W[T]`, held as `w.W[Node]` in `Node`) is rejected with
  the message a generic of its own module gets, where `rig check`
  accepted it and Zig then failed with a dependency loop. An alias of
  such an instance is rejected the same way, and so is an object that
  holds a map of itself whose entries name its optional (`kids:
  Map[Node]`, where `Map[V]` holds `List[Slot[V]]` and `Slot[V]` holds
  `value: V?`), which Zig also failed on. A payload enum that does the
  same (Trig's `CompilerOptionsValue`) is laid out, and stays accepted.
  A program that declared such a type and never made one compiled
  before, and is rejected now.
- A generic whose field is a box of its parameter's optional (`up: ^T?`)
  holds no `T` inline, so an object holding the generic of itself
  (`w: W[Node]` in `Node`) is accepted, where it was rejected as
  containing itself by value. A List, a box, or a table keeps its
  elements in heap memory, inside a generic as outside one.
- `rig build --release`'s warning about a frame larger than a page reads
  a program's own code section too, where a program that makes tasks
  keeps its functions when it is preempted by signal, and where the
  warning found none of them.
- A debug build on x86-64 is built by LLVM (`-fllvm`), as on arm64. Zig
  0.17's own x86-64 backend, its default there, overwrote a compare's
  result with an atomic's flags, so a function that returned a compare
  and dropped a counted handle answered wrong in debug builds
  (`docs/learn/04-concurrency.md`'s `*Frozen` example printed all
  `true`). A debug panic's trace names the program's line on x86-64 too.

- Emit decides nothing the checkers did not walk: whether a `match` arm
  takes every value, whether a `match` picks its arm first, whether a
  loop or `as` binds a String's bytes, whether `return a, b` makes its
  parts first, how an `as` binding reads through a write view, how a
  new binding holds its value, and which call a compound assignment
  lowers to are decisions of the storage plan, verified at its end, and
  emit reads them. What a `swap` exchanges is decided once, by
  typecheck, and read by the ownership checker, the oracle, and emit:
  `old = swap(!x, pick(!y))`, with `pick` giving a write view, puts the
  value it views in `x`, where emit wrote an exchange of two places
  that Zig rejected. A unit test fails on a `Facts` method that answers
  about a node with a classifier instead of a record.
- A List element lent to write inside a call whose result is read,
  `check(swap(!wholes[f], List()))` with `check` taking a `?` parameter,
  or `check(!bags[f].take())` with `take` writing its self, is reached
  through its writable slot: its own `!` decides, where emit read the
  element through the read slot of the read around it, and Zig rejected
  the write.
- Each name `as a, b` binds is a new name, checked as `as v`'s is: one
  that shadows a local, or a module-level declaration, is rejected.
- A one-line `defer` that assigns several results to names declared
  before it, `defer a, b = two()`, is emitted as a block, where Zig
  rejected the statements it wrote.
- Builds of one package at once no longer race on a split build's
  objects: a split build holds a lock in the package's Zig cache from
  its check for a kept executable to its link, so on Linux, where Zig
  replaces an object by deleting it first, one build's link no longer
  finds another's object gone (`failed to open object
  __rig_unit_0.o: FileNotFound`).
- A read lend copied out where a value goes adapts as the value it
  copies: `o: Item[K, V]? = ?none` of an optional held as a niche
  becomes its `none`, and `?B.y` where an error with fields goes widens
  as `B.y` does. `?wr(!x)` of a call giving a write view `!Int` reads
  the `Int` through it. Each built, where Zig rejected the emitted code.
- `e = +E.v(x: 9223372036854775807)`, a clone of a constant, and
  `P(a: ?n)`, a constant copied out of a read lend, are run-time values,
  as the value without `+` or `?` is: `x + 1` on one panics with an
  overflow when it runs, where Zig failed the build. `_ = $plain(T)` in
  a generic body builds.
- `for x in !out`, where `out` itself holds a read view (`out = ?a`, a
  call that returns one, a `?List` field or element), is rejected as
  `!out.push(...)` is: "cannot write-iterate through a read view". It
  was accepted and wrote through the read view, so a String another
  view still read was dropped and then read (a use after free). A
  method that writes the elements, `out.fill(0)`, says it cannot lend
  to write through a read view, where it advised writing `!out.fill(0)`,
  which is rejected too; `for x in !xs` over a `?` parameter says the
  same, where it said parameters are immutable.
- A write view of a read view, `x` of `for x in !vv` over a
  `List[?P]`, writes nothing through the read view: `x.t = v`,
  `!x.set()`, `x.n += 1`, `for n in !x.ns`, and `!x.push(1)` are
  rejected, "cannot assign through a read view (`?T`)", "cannot lend to
  write through a read view", or "cannot write-iterate through a read
  view". The loop may still point the element at another view. Zig
  rejected the writes and lends, but a write-iterate built and wrote
  through the view (the element of a List another view reads).
- A code a handle or box made where a view of a wider set goes holds,
  `look(*X.one)` with `look` taking `?error`, or `f(*B.z)` with `f`
  taking `?L` of `error L = A | B`, has its handle or box dropped at
  the end of its statement, where it leaked.
- `rig check` no longer crashes on a sigil before a call through
  `Slot[n]`, `!Slot[4].of(1)`: a `!`, `?`, or `<` there reaches the
  type, and is reported as it is before a call through an object's type.
- A value loop that breaks with a constant, `x = loop` ... `break MAX`,
  and a read view of a module constant's part, `row = ?grid[1]`, are
  run-time values: `x + 1` past the maximum, or a division by zero,
  panics when it runs, where Zig failed the build.
- A read view of a module constant held in an object, an array, or an
  optional, `p = P(a: ?top)`, `[?top, ?top]`, `Q(p: P(a: ?top))`, or
  `P(a: ?top).a[0]`, is a run-time value, as `p = ?top` is: `p.a[0] + 1`
  past the maximum panics when it runs, where Zig failed the build.
- `<none` and `+none` become the optional they go into as `none` does,
  one held as a niche or beside a flag too: a binding, an argument, a
  push, and a return built. `print(?none)` is a bare `none`, reported.
- A `return`, `break`, `continue`, or `panic` followed by a statement
  after a `loop` that nothing breaks out of is reported as unreachable
  code, as it is anywhere else, where Zig rejected it.
- A one-word object, which a field holds at four bytes, builds where
  Zig wanted its natural alignment: the drop of an object partly moved
  out (`take(<p.v)` beside a one-word field), a rebound write view of
  one, a box's or handle's view of one lent into `(?P)?`, and `o ?? b`
  of a `(?T)?`.
- `List(?a)` of an array copies the array the view reaches, and
  `!t.push(v, keep: k)` reads the vector a held write view reaches;
  `List(!a)` and `!t.push(!b, keep: k)` are rejected as write lends only
  read. A `!{Shape}` returned where a `(?{Shape})?` goes is the read
  view it lends. Write-iterating a `List[?List[Int]]` reaches each
  element's members through both views. `(<User(age: 5)).age` reads the
  field of the moved temporary. `$plain(~T)` in a generic whose `T` is
  named nowhere else builds.
- `^` of a task or a set of tasks, `^four()&`, is rejected: a task is a
  handle to work the runtime holds, held as it is. Each program these
  fixes reject failed to build before.

### Tests

- `tools/mac-claim LABEL CMD` runs one timing job holding the Mac's
  claim line: it waits while another claim holds the Mac or a
  correctness job holds or waits for a heavy slot, gives up after 45
  minutes (exit 75), stops the job at its limit (19 minutes, at most 20;
  exit 124), and clears the line however the job ends
  (`test/cli/mac_claim.sh`).
- `pup-slot state` prints `running=R`, the builds not paused, and
  `late=L`, the builds its guard paused after the slot opened, beside
  `paused=K`; a board race with any running is void (decision 14). A
  board slot's guard looks for new builds every 2 seconds (an ab slot's
  every 10).
- `tools/pup-slot` opens and closes pup's timing slots (`open NN
  MINUTES board|ab LABEL`, `close`, `status`, `state`), pausing builds by
  PID and resuming the same PIDs. A board slot pauses every build and
  opens only with no build over 2 GB resident and 64 free 2 MiB blocks
  after compacting; an ab slot lets builds pinned to E-cores 12-19 run.
  Neither pauses a running test suite; a board slot never pauses a
  running correctness build, and a board run past 45 minutes leaves a
  15-minute window when one waits (release-slot's
  `TRIG_RELEASE_CLASS=correctness` files); every wait
  gives up after 45 minutes (exit 75); each open and close is a line in
  `/zfs/trig-pup/slot-tools/slots.log` (`test/cli/pup_slot.sh`, which
  runs on Linux).
- `tools/heavy --class correctness CMD` puts a gate a merge waits on
  ahead of every other waiter. A waiter names each holder (PID, minutes
  held, command) after a minute and every ten minutes, and gives up
  after `RIG_HEAVY_WAIT` seconds (45 minutes) with exit status 75;
  `tools/heavy --status` shows the holders and the queue and takes no
  slot (`test/cli/heavy_class.sh`).
- `test/cli/agree.sh` fails on macOS when `lake` is missing, and says
  it skipped on stderr elsewhere; it fails, too, when fewer programs
  than its floor (22) are in λRig's scope, or when lrig writes a line it
  does not know.
- The reference ownership checker (`bin/rig-oracle`) agrees with the
  compiler on a closure literal lent to a call, whose result carries the
  loans of what the closure captured, and decides the flow of sets of
  tasks: `!ts.add`, `>ts`, a closure holding a set or another value with
  a `drop` body, and a generic instance at a task or a set. Its floors
  rise by what it now decides (59 functions of the tests, 10 of the
  docs).
- The reference ownership checker reads a value written through a write
  view of plain data out of the view that gives it (`w = ?a` writes an
  `Int`), where it reported a view leaving the function, and rejects a
  consuming method called through a view or through a box of a read
  view (C7).
- `tools/stack-census.py` reads a preempted Mach-O program's code in
  `__rig_text`, which carries no instruction attributes, so bench/tasks'
  release build on the Mac has 6 of its 9 task types bounded, where it
  had 1. It resolves a call through a `FnRef` to the thunks of that
  FnRef's type, a fact it checks in the runtime's source, and leaves out
  `clone`'s child branch, which runs on the new thread's stack. Four
  under-counts are gone: a pointer the linker wrote out whole read as a
  fixup, two `__const` sections joined at the wrong addresses, a
  function's address spilled to the stack trusted after a store or call
  that may have written it, and a spill read at its offset from a moved
  sp. `test/cli/stack_census.sh` tests each rule.
- The core suite, `swarm test/rig.rip`, runs the scripts of `test/cli`
  and the probes of past reviews (`test/rig/probes-*.rig.test`) too, so
  a change that breaks one fails its gate; `cli` and `probes` run them
  alone.

### Docs

- The docs, std, the examples, and the benchmarks write a self sigil
  short wherever it applies, `!c.read(!buf, 4096)!`, `?p.dist(q)`,
  `<conn.close()`; the long form stays only for a write call whose
  `Bool` value is used and for an assignment's target, as SYNTAX "Self
  sigils" asks. The emitted Zig is the same.
  `tools/drop-write-parens.py` drops the parentheses of `?` and `<` as
  well as `!`, and of a `for` source, leaves an assignment's target, and
  with `--md` rewrites the ```` ```rig ```` blocks of Markdown files,
  each program checked on its own.

### Runtime

- `file.read` of a regular file on Linux makes four system calls: an
  open, a stat of the descriptor, one read, and a close (tsc's makes
  five, reading once more to find the end). It no longer stats the path
  before opening it: the open is nonblocking, and a FIFO it opens goes
  to the pool as its descriptor, which is polled and read to the end its
  last writer leaves. Trig checking Material UI's docs makes 17,690
  fewer of these calls (149,710 to 132,020; tsc makes 149,233). macOS
  keeps the stat of the path first, since its poll of a FIFO never
  reports the writers gone. On every system a file whose size is known
  is read only up to that size: a small file, whose buffer the heap
  rounds up, no longer gets a last read of nothing.
- `List.filled(n, x)` with `x` all zero takes memory the heap knows is
  zero, a block never handed out before, without writing it, as `calloc`
  does; a block taken again is zeroed. The array of workers is written
  one worker at a time as each starts, not all 64 when the program does.
- On the Mac a program built to be preempted finds its code section as
  `main` starts, before any worker thread. A worker that read the
  bounds while they were being written could take the scheduler's code
  for the program's, and panic with "the scheduler's code was inlined
  into the program's" (2 runs in 20,000 of a doc example).
- A thread whose alternate signal stack cannot be set stops the program
  with a message, where it ran on with signals taken on a task's stack
  and no report of a stack overflow.
- An idle connection of `http.serve` waits on a dense stack, which shares
  page tables with its neighbours: 17.2 KiB on the Mac and 9.2 KiB on
  Linux, page tables included, where it held 32.8 and 13.0 KiB.
- On the Mac a program built by `--pgo` tears down at `os.exit`, as
  every other release build there does: Trig 1.3 to 15.2% faster at 4
  and 8 checkers on its small projects.
- `rig build --release --pgo -- WORKLOAD` works on the Mac, with Apple's
  command-line tools: Trig 5 to 15% faster on projects it was not
  trained on.
- On Linux a `Table` of a heap that does little waits to ask for huge
  pages until its heap faults in ahead, instead of each asking as it is
  made: Trig's smallest projects 2 to 3% faster at 8 checkers, and large
  heaps keep their huge pages.
- A panic in a method on an actor's own task now cancels and waits for
  the tasks that method started before the stack goes and the caller
  goes on, where a task could read freed stack. A panic in such a task
  ends the actor instead of the program, a supervised actor starts
  again only once they have ended, and an isolate inside a method stops
  a panic there and leaves the actor running.
- The scheduler's shared counters and queues each fill whole cache lines,
  so what the linker places beside them cannot slow them.
- On x86-64 Linux and arm64 macOS, a program that makes tasks and no
  local task is preempted by signal: a monitor thread stops a task that
  has run 10 ms while other work waits, in the program's own code, and
  its loops run with no yield checks. `RIG_PREEMPT` is gone. Trig on pup
  is 1.3-3.3% faster at one checker, with 3.8-4.6% fewer instructions,
  and a fork-join's sum is 5 times faster on the Mac (14.1 ms to 2.7 ms
  on ten workers; Rayon 2.4 ms). Other targets, Linux debug builds,
  programs with local tasks, `rig test`, and the test runner's batch
  packs keep their yield checks
  ([records/2026-11/preempt/](docs/history/records/2026-11/preempt/design.md)).
- stdout's flushes, a panic's report on stderr, and the deadlock walk
  run on the worker's own stack, not the task's, through
  `sched.onWorkerStack`. No signal stops the task meanwhile, and a safe
  build panics if the call would park. With the clock bounded by each
  host's own vDSO, `tools/stack-census.py` bounds 6 of bench/tasks' 9
  task types on pup, where it bounded 1.
- Free task stacks move between workers through a spare list all
  workers share, and the surplus a burst of tasks leaves goes back to
  the system once the workers are idle, in address order, each run of
  neighbouring stacks in one call. Each stack past a worker's 64 was
  returned on its own as its task ended, flushing every running core's
  TLB: bench-scale's `alloc` as tasks on pup at 8 workers took 3,220
  flushes a run and takes 24 to 58, and `tree` is 2-3% faster at every
  worker count. On the Mac, bench/tasks' `spawn` is 47% faster
  (7.3 ms, from 13.7). A program keeps at most 64 free stacks a worker,
  as before, and holds less memory after a burst of 4,096 tasks: 21-23
  MiB, from 25, on the Mac, and 9.5-10 MiB, from 11, on pup.
- Stacks ask for small pages where Linux gives huge ones unasked
  (`enabled=always`), so a sleeping task cannot take a 2 MiB page.
- The deadlock walk runs on the worker's stack, not the task's.
- The runtime's SIGPIPE, SIGINT and SIGTERM, and SIGALRM handlers run on
  the thread's alternate signal stack, and a program that makes tasks
  installs again with `SA_ONSTACK` any handler other code installed
  without it, the SIGPIPE and SIGIO handlers of Zig's task backend
  among them.
- As `main` returns, the preemption monitor is woken and ended before
  the workers it reads are freed; it read them after the free.
- A macOS release build maps an embedded run from its file only when the
  file's header and load commands, its LC_UUID among them, are the
  running image's: a build renamed over the file while the program ran
  had the program read the new build's bytes.
- A worker keeps four tasks to run next, in a circle, where it kept
  one. A task made and then waited for runs at once while it is still
  in a slot, ahead of older tasks in the ring, and a thief takes the
  oldest. `bench/tasks`' `hog` waited 19-134 ms on its first step on the
  Mac with `RIG_PREEMPT=signal`, behind tasks that ran until the monitor
  stopped them, and now waits 0.1-0.7 ms. With yield checks, `hog` takes
  157 ns where it took 73 µs on the Mac, and 192 ns where it took 166 µs
  on pup. `bench/actors`' `contend` is 43% faster on the Mac, and `spawn`
  is 9% faster on the Mac and level on pup
  ([run-next-2026-11-07.md](docs/history/records/2026-11/preempt/run-next-2026-11-07.md)).
- The release allocator follows Linux's mode for transparent huge pages,
  read once from /sys/kernel/mm/transparent_hugepage/: under `madvise`
  it asks as before, and with no test of /proc/buddyinfo where `defrag`
  is `defer` or `never`, as no fault compacts there; under `always`,
  where every range gets huge pages unasked and asking only makes faults
  compact, it asks for none, and what should keep small pages (a
  segment of a heap that does not fault in ahead, a large block under
  16 MiB, a Table's first 2 MiB) asks for small ones; under `never` it
  asks for nothing and reads nothing. The test counts only the free
  2 MiB blocks of the asking thread's NUMA node, so a host of two
  sockets no longer asks on another node's blocks, and a reading cut
  short before that node's lines counts none. A host of one node
  under `madvise`, as pup, behaves as before
  ([records/2026-11/huge-pages/gate-modes.md](docs/history/records/2026-11/huge-pages/gate-modes.md)).
- On the Mac a release build's `os.exit` stops the other workers, when
  none runs a task and the blocking pool is idle, and unmaps the
  program's Tables, segments and free fiber stacks on four of them
  before the process ends, where the kernel would free their page
  tables on one core: Trig at four and eight checkers is 9-18% faster
  on mitt, neverthrow and superstruct and 4-7% on tiny-invariant, and
  level on zod3 and ts-pattern and at one checker, peak memory level. The work stays in the
  process, so its time and CPU time count it. Tables take their ranges
  from 32 GiB regions on the Mac, as from Linux's 256 GiB ones, which
  the teardown unmaps; Linux, debug builds, and a return from `main`
  end as before
  ([records/2026-11/exit/](docs/history/records/2026-11/exit/parallel-teardown.md)).
- std.text's search leaves out of optimized builds the bounds and
  overflow checks its own tests prove (`rig.proven_checks`): built with
  `--release`, `find`, `count`, and the functions on them are 12-44%
  faster on needles of 3 to 40 bytes on the Mac, and 26% for one byte
  over a long text, as fast as `--release=fast`, whose code is the same
  as before. `bench/text` times std.text against the memchr crate and
  Go's `bytes.Index` (`bench-text --rivals`): 17-30% faster than memchr
  over a whole text, and about twice as slow for one byte in 16 B to
  4 KiB
  ([records/2026-11/text/](docs/history/records/2026-11/text/memchr-2026-11-06.md)).
- `task.worker_count()` gives the number of workers tasks run on (one
  per core, `RIG_WORKERS`, or what `task.workers(n)` set), before the
  first task starts them or after; 1 in a deterministic run.
- On the Mac a program built with `RIG_PREEMPT=signal` has `dsymutil`
  write its `.dSYM` after the link, so a panic's trace shows the source
  lines of the program's own frames; without Apple's command-line tools
  a note says the lines are missing
  ([mac-port-2026-11-05.md](docs/history/records/2026-11/preempt/mac-port-2026-11-05.md)).
- std.json decodes a run of `\u` escapes of three-byte characters two
  at a time, and takes indentation after a value too, after a line
  break as up to 16 pair tests in a row, as yyjson does: on the Mac
  twitterescaped 11.4% faster, citm_catalog 5.2%, twitter and
  github_events 4.8%, gsoc-2018 2.6%, canada level
  ([records/2026-11/json/](docs/history/records/2026-11/json/runs-2026-11-07.md)).
- std.json tests a string's first 8 bytes inline before scanning the
  rest: 1.8-3.5% faster on the Mac on five files, canada level
  ([records/2026-11/json/](docs/history/records/2026-11/json/head-2026-11-06.md)).
- std.json takes a key's `: ` at once when the value's first byte follows
  it: 0.5-4.7% faster on the Mac on five files (citm_catalog 4.7%,
  twitter 2.3%), canada level
  ([records/2026-11/json/](docs/history/records/2026-11/json/colon-2026-11-06.md)).
- std.json parses a key after a comma inline, returns at once when a
  key's colon is followed by its value, and puts an integer of up to 18
  digits with no fraction or exponent on the tape as soon as its digits
  end: 0.5-3.4% faster on the Mac on five files, twitterescaped level
  ([records/2026-11/json/](docs/history/records/2026-11/json/key-int-2026-11-06.md)).
- std.json makes its tape entries with wrapping arithmetic, which the
  2^32-byte input cap keeps from wrapping, so no overflow check runs:
  0.5-4.4% faster on the Mac (citm_catalog 4.4%, canada 2.7%), every
  file faster
  ([records/2026-11/json/](docs/history/records/2026-11/json/tape-wrap-2026-11-06.md)).
- A task that makes tasks keeps its worker while idle workers take what
  it makes, as Go's `go` leaves its maker running: a yield check leaves
  work another worker could take to an idle one, which it wakes, and
  yields only when every worker is busy, its ring holds work, or the
  work is a local task's. A producer that makes 200 tasks between its own
  work runs 8.7% faster in bench/tasks' new `produce` row, and 25% faster
  at 9 µs a task; the other rows are level
  ([records/2026-11/spawn/](docs/history/records/2026-11/spawn/README.md)).
- Text compares by one byte equality of the runtime's, `bytesEql`:
  String `==` and `!=`, a string pattern, the text keys of `Map`,
  `Set`, `HashMap`, and `HashSet`, `E.from_text`, and `==` on slices of
  integers. It tests lengths, then overlapping words and 16-byte
  vectors, each one unaligned load: 3-50% faster than `std.mem.eql`
  at every length to 128 bytes on the Mac, and 8-73% on x86-64 with
  AVX2. In code a `--pgo` profile finds cold its loads stay wide,
  where `std.mem.eql`'s array casts moved each byte through the stack
  (`bench/eql`).
- std.json takes a pretty-printer's line break and indentation after a
  `,` or an opening bracket as fixed steps the processor predicts:
  4.6-12.7% faster on indented input on the Mac (citm_catalog 12.7%,
  github_events 7.4%, twitter 6.5%), with minified input level
  ([records/2026-11/json/](docs/history/records/2026-11/json/indent-2026-11-05.md)).
- In a build with `RIG_PREEMPT=signal`, the allocator's slow path and a
  List's growth run a yield check a signal left owed when they return to
  the program's own code: a loop that allocates, which spends its time in
  the runtime where a signal stops nothing, let a 20 ms timer due on its
  worker fire after up to 70 ms on the Mac, and now it fires at 20-21 ms.
  A build without the option is the same code as before
  ([default-on-2026-11-06.md](docs/history/records/2026-11/preempt/default-on-2026-11-06.md)).
- In a build with `RIG_PREEMPT=signal`, std.text's searches (`find`,
  `find_last`, `count`, and the code they call) are in the program's code
  section, where a signal stops a task as in the program's own code: a
  loop of searches over a long text held its worker and a 20 ms timer due
  on it for up to 15.8 s on x86-64 and 2.1 s on the Mac, and now the timer
  fires at 20 ms. No search costs an instruction more, and a build
  without the option is the same code as before
  ([default-on-2026-11-06.md](docs/history/records/2026-11/preempt/default-on-2026-11-06.md)).
- In a build with `RIG_PREEMPT=signal`, a signal that finds a task in
  a system call or the runtime, outside the program's code, leaves the
  yield check it asked for owed, and the task's next waiting point (any
  call that reaches the file system or a socket) runs it: eight tasks
  looping on `file.read` held four workers, and a 20 ms timer due on
  them, for up to 4.8 s on the Mac and 17.6 s on x86-64 Linux, and now
  it fires at 21 ms
  ([owed-2026-11-06.md](docs/history/records/2026-11/preempt/owed-2026-11-06.md)).
- A prototype, off by default: a program that makes tasks, built with
  `RIG_PREEMPT=signal` for Linux x86-64 or arm64 macOS in an optimized
  build, has no
  yield checks; a monitor thread stops a task that runs a slice while
  other work waits by a signal, only in the program's own code and
  while its worker holds no lock
  ([records/2026-11/preempt/](docs/history/records/2026-11/preempt/design.md)).
  A build without it is the same code as before. On the Mac, x15 is
  reserved in such a build, and its frames in a panic's trace show no
  source line
  ([mac-port-2026-11-05.md](docs/history/records/2026-11/preempt/mac-port-2026-11-05.md)).

## v0.3.0 (2026-11-04)

`v0.3.0` follows `v0.2.9` (Zig 0.17.0, Nexus 2.0.0) and changes the
language since it. Its release notes, the summary of this entry, are
[docs/releases/v0.3.0.md](docs/releases/v0.3.0.md).

### Upgrading from v0.2.9

[docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md) takes a 0.2.9 program to
0.3.0 in order: `tools/migrate-0.3.py`, the spellings rewritten by hand,
`tools/state-bounds.py`, `tools/migrate-std-0.3.py`, and what the
compiler asks for. Each form
below was accepted by `v0.2.9` and is rejected by 0.3.0, most with the
form to write in the message. A form marked *unsound* let a program
read freed memory or write through a view it should not have; the rest
are renames and spellings.

Renamed, by `tools/migrate-0.3.py`:

1. `struct Name` is `obj Name`.
2. `Box[T]` and `Box(v)` are `^T` and `^v`.
3. `Vec[T]` is `List[T]`; a type of a program's own named `List` is
   renamed `Chain`.
4. `Text` is `String`, and 0.2's `String`, a read view, is `?String`.
5. Self is `@`: a method declares `?@`, `!@`, or `<@` and its body says
   `@x`, `@m()`; `?self`, `self.x`, and a typed `self: ?P` are rejected.
6. A label is `$outer:` and `break $outer`, not `:outer`.
7. A built-in call is `$size(T)`, `$truncate(x)`, not `@size(T)`.
8. A fixed binding is `x =! e`; `const` is rejected.

Renamed, by hand (no script):

9. `replace(!p, v)` is `swap(!p, v)`, and a Cell's `c.replace(v)` is
   `(!c).swap(v)`.
10. A statement `-x` no longer drops `x`; `<x` does.
11. `w.upgrade()` of a weak handle is `*w`.
12. A compile-time value parameter starts with a lowercase letter,
    `[n: Int]`, and a type parameter with a capital, `[T]`.
13. `text.valid_utf8` is gone; `utf8.is_valid` checks a `?String`.
14. A built-in named through a module, `lib.Vec[Int]()` or
    `lib.Cell(1)`, is "no member" (#646); write `List[Int]()`, `Cell(1)`.
15. `panic` is a keyword, so no function or binding takes the name.
16. `Task`, `Tasks`, `Chan`, `Actor`, `Frozen`, `Simd`, `Symbol`,
    `Static`, `Int`, `Float`, `Bool`, and the sized numbers name built-in
    types, and a program's own type may not take one.
17. An enum's variant may not be named `none`.

Public generics:

18. A `pub` generic states, by bounds, everything its body does with a
    type parameter (`[T: Num]`, `[T: Ord]`, `[T: Copy]`, `[T: Eq]`,
    `[T: Print]`, `[T: Clone]`); `tools/state-bounds.py` writes them.
    It states `Print` too where it passes a `T` to a generic that prints
    it, `pub sub show[T](x: ?T)` calling a private `helper(x)` that
    does `print(x)`, which the compiler reports with the fix.

Syntax:

19. An operator has the same spacing on both sides: `x -1`, `a <b`,
    `a *b`, `a +b`, `steps= 1`, and `n.. 3` are rejected with the two
    spellings each could mean.
20. A bracket, a call's parenthesis, a member's `.`, and a postfix `?`
    touch what they follow: `a [1]`, `obj Wrap [T]`, `xs .len`, `. red`,
    `Int? ?`, and `f(x) ?`.
21. `not a == b` is `a != b` or `not (a == b)`.
22. `catch` binds as `??` does, so a handler that compares or chooses is
    parenthesized: `f() catch |e| (1 if e == E.bad else 2)`.
23. A closure body below its bar list ends with its line; the `)` that
    closes the call goes on the next line.
24. A write call whose `Bool` value is used is parenthesized:
    `if (!s).add(k)`, not `if !s.add(k)`.
25. A lend is written on a whole path, not its base: `v.len` and
    `<s.o`, not `(?v).len` and `<(!s).o`.

Cells, handles, and views:

26. An object, enum, or element that holds a `Cell` or a `Signal` lives
    behind a shared handle, `*C(...)`.
27. A call that changes a Cell or a Signal is marked with `!`:
    `!c.set(v)`, `!s.subscribe(f)`, `(!b.c)[i] = e`; through a read view
    a Cell is not changed.
28. A write view, `!T`, is no field's or element's type.
29. One heap holding: `Box[Box[T]]`, `Box[*T]`, `*~T`, and a box of a
    function are rejected; and a type alias of a box is not called as a
    constructor (`^5`, not `BI(5)`).
30. `read[U8, .big]`, a byte order on a one-byte type, is rejected.
31. `!x` lent where the callee only reads, or a copy goes, is `?x` or
    `x`.
32. A method's result that views self, bound to a name, is written as
    the lend it is: `r = ?b.first()`, not `r = b.first()`.
33. *Unsound:* a function that stores a view of a parameter in what its
    caller reaches says so, `keeps t`.
34. *Unsound:* a lend of a branching value that may be a named value,
    `(a if c else b)[0].m()`, lends each branch; `o ?? w` does not copy
    out an object that holds a Cell.
35. *Unsound:* a temporary that owns a resource, with nothing to drop
    it, is bound to a name first.
36. *Unsound:* a scope's defers run after the value it gives, so a
    `defer` may not change, drop, or lend to write what a block's value,
    a `return` value, or a `break` value views (`defer !@xs.clear()`
    before a last value `!@xs[0]`); and `return s` or a last value `s`
    of a write view moves `s`, so no defer, closure a defer calls, or
    task waited for at the scope's end may use it after.

Effects and errors:

37. `time.sleep` can fail (a canceled task stops there): `time.sleep(n)!`
    or a `catch`.
38. Two caught errors are not compared with `==`; compare one with a
    member, `e == E.bad`, or match it.

Other:

39. A closure never called (`_ = |x| x + 1`) is rejected.
40. `*g` of a function, where a `*fun` goes, is `*|| g()`.
41. A method's parameter may not take the name of a module-level
    declaration.
42. A directory's `.rig` files are one module, sharing one namespace, so
    two files beside each other that 0.2.9 took as separate modules may
    not declare the same name; move one into a directory of its own.
43. A read view of text, `?String`, is not lent to write (`w = !s`);
    hold a `String` to change text in place.

43. A write view re-pointed inside a `match` arm at the payload the arm
    binds (`w = !p[0..1]` in `.has(p)` of `match !o`) is rejected: the
    binding ends with the arm. Write through `p` inside the arm instead.
44. *Unsound:* a closure parameter given `!?String` by the type the
    closure is checked against, as `|k, v|` passed to `update` or
    `retain` of a `Map[K, ?String]`, is rejected, as a written
    `!?String` is: the body could store the key's view in a value that
    outlives it. Leave the parameter out (`|k| ...`) or name it `_`,
    hold the values as `String`, or walk the Map with `items`.
45. *Unsound:* a generic body's value that it holds by value tracks no
    view, so an instance whose type argument can hold the view the body
    could put in one is refused (SPEC "Generic bodies"):
    - `update`, `retain`, and `ensure_with` of a `Map` or `HashMap`
      whose value type can hold the key's view: `(?String)?`,
      `List[?String]`, `?String` (`retain(|k| ...)` too), an object, an
      enum, or an API object that holds a `?String`, even with a closure
      that stores nothing. Hold a value that owns what it holds, or walk
      `items`;
    - a program's own generic body that gives a function value (a
      closure, a named function, an owned closure, one held in a field)
      a write view of a `T` it holds beside another view, or holds as a
      `T` a function value's result given a view of its own memory (a
      local, a parameter given by value, self's storage), at an
      instance whose `T` can hold the view; and one that holds as a `T`
      the result of a type argument's method that views self or an
      argument. Give the instance a type that owns what it holds.
46. A write view of a read view, `!?T` (`!?List[Int]`, `!?Int`), is
    rejected as `!?String` is, written or given by the type a closure
    is checked against (`update` of a `Map[K, ?List[Int]]`).
47. *Unsound:* a float provides no `Ord`, since a NaN is neither below
    nor above a number (SPEC "Floats in order"). `v0.2.9` ordered floats
    by Zig's `std.math.order`, which reaches `unreachable` on a NaN: a
    panic in safe builds, undefined behavior under `--release=fast`. And
    `sort.sort` left floats holding a NaN unsorted. Rejected now, each
    with the fix in the message:
    - `sort.sort`, `sort.lower_bound`, `sort.search`, and
      `sort.sort_by_key` with a float key: sort with
      `sort.sort_by(!xs, |a, b| a.total_order(?b) == .less)`;
    - `math.min`, `math.max`, and `math.clamp` of floats: write
      `a.min(b)`, `a.max(b)`, `x.clamp(lo, hi)`, where a NaN loses to a
      number;
    - a program's own `[T: Ord]` generic at `Float` or `F32`, and a
      body's `a.order(?b)` at a float;
    - `obj` or `enum` that names `Ord` with a float field: write its own
      `fun order(?@, other: ?Self) -> Order` with `total_order`;
    - `x.order(?y)` of floats: write `x.total_order(?y)`;
    - `<`, `<=`, `>`, `>=` on an optional, an array, or a slice of floats.
    `<` on two floats stays, IEEE 754's, and so does `math.abs`, which
    takes `T: Signed`.
48. A method with the very signature a built-in API fixes,
    `fun eq(?@, other: ?Self) -> Bool`, `fun order(?@, other: ?Self) ->
    Order`, `sub hash_into(?@, h: !Hasher)`, or `sub print(?@, out:
    !Printer)`, on a type whose header does not name the API, is
    rejected: `==` and the others passed it by. Name the API on the
    header, `obj P: Eq`, or rename the method; under another signature
    the method stays an ordinary one.
49. A parameter `?^T`, a read view of a box, is `?T`, which takes a
    `^T` too: `fun eval(e: ?Expr)`. A `!^T` parameter, which may
    replace the box, and a view of an optional box, `?^T?`, stay.
50. A clone that copies a String's bytes or a value's parts into a read
    view, `peek(+w)` where `peek` takes a `?T`, a `[]T`, or a
    `?String`, or `(+w).len()` of a `?@` method, is a lend:
    `peek(?w)`, `w.len()`. A clone the same call keeps apart from a
    write lend or a move of the original, `g(+w, !w)`, stays.
51. *Unsound:* a Cell or Signal reached through a read view of a
    handle is not changed: `!n.c.set(5)` with `n: ?*Node`, through `if
    n as x` of an `n: ?(*Node)?`, a `?@` method's `if @head as x`, a
    read match's or `for` loop's binding of a handle (`for h in hs`), or
    a closure's `|?h|`, is rejected, as `?Cell[T]` was ("cannot lend to
    write through a read view `?*Node`"). Change it through a handle of
    your own (`mine = +n`, then `!mine.c.set(5)`), or take a write view
    (`n: !*Node`, `if !o as x`, `for h in !hs`, `!@`).

52. `file.FileError` gains a member for each reason the system gives:
    `not_permitted`, `read_only`, `loop`, `name_too_long`, `busy`,
    `cross_device`, `no_space`, `invalid`, `bad_descriptor`,
    `broken_pipe`, and `io`. A `match` over a `FileError` with no `_`
    arm names them or adds one. `denied` is now only EACCES: EPERM is
    `not_permitted` and EROFS `read_only`, and EBADF (a write to a file
    opened to read), once `denied`, is `bad_descriptor`; a program that
    caught `denied` for those catches the new member too. What was
    `failed` for these reasons is its own member now.
53. *Unsound:* a member with fields written short without them, `.bad`,
    where an `error` or a union goes, was accepted and printed fields
    never written. Give it its fields, `.bad(at: 3)`, or name its set
    with them, `Oops.bad(at: 3)`.
54. A short-form member lent where a view of a union or of
    `error` goes, `.plain` passed to a `?Both`, is rejected, as
    `Oops.plain` there is. Bind it first, `k: Both = .plain`, then lend
    `?k`. Trig needs no migration: its emitted Zig is unchanged.
55. `Os` names a built-in type, the operating system `target.os` gives,
    so a program's own type may not take the name, as it may not take
    `Arch`. No program in Rig, Trig, or loco declares one, so Trig needs
    no migration.
56. `Feature` names a built-in type, the CPU feature `target.has(f)`
    tests, so a program's own type may not take the name, as it may not
    take `Os`. Rig makes `Feature` a reserved built-in type (std.target's
    `target.has(.avx2)`); Trig declares no type named `Feature`, so no
    migration is needed.
57. *Unsound:* a branch before its condition in the source runs after
    it, so the condition may not change, move, or lend to write what
    the branch views: `print(r.n) if bump(!v) > 0`, `x = r.n if
    bump(!v) > 0 else 0`, and `return r.n if take(<v) > 0`, with `r =
    ?v[0]`, read freed memory. Read the view into a value first (`n =
    r.n`), or run the condition as a statement of its own. Trig needs
    no migration: it has no such form.
58. A pattern is tested with `matches`, not `as`: `if s as .circle(r)`
    is `if s matches .circle(r)`, and `x as .p` is rejected with "write
    `x matches .p`". `tools/migrate-matches.py` rewrites each, in `.rig`
    files and in Markdown's code. Trig has none; loco has one
    (`rig/loc/scan.rig`). `matches` is a word only after a value, so a
    local, parameter, or function named `matches` keeps its name.
59. *Unsound:* a generic type's fields go to a task as they hold each
    argument: a `W[Task[Int]]` whose field is `r: ?T` holds a
    `?Task[Int]`, which no task but its holder may read, and was given
    to a task on another core. So was an object held both by value and
    through a view (`a: G`, `b: ?G`), whose view was not looked into, and
    a type that a local task takes and a channel it holds carries
    (`g: G`, `c: *Chan[G]`, `G` holding a `*List`), whose elements go to
    any task.
    Each is rejected where the value goes to the task, as the same type
    written without generics is.
60. A payload enum naming its own optional in its layout, `call(args:
    List[Expr?])` in `enum Expr`, is rejected with the fix to write, as
    an object's is; Zig failed on it with a dependency loop. Hold an
    optional box (`^Expr?`) or an optional view (`(?Expr)?`).
61. A type whose fields reach more than 64 generic instances, the last
    of which names the type's own optional (`List[Node?]` inside the
    65th), is rejected as a nearer one is; Zig failed on it with a
    dependency loop.
62. A read view that holds a copy of its value counts at its value's
    size against the 8 MiB limit on a value and the 13 MiB limit on a
    frame: `[20000 of ?v]` with `v: Simd[I64, 64]` takes 10240000 bytes,
    as `[20000 of v]` does, and is rejected; it was counted as pointers,
    and a larger one overflowed the stack. Keep such data in a `List`.
63. In a closure that captures a path, `|?p.a|`, a `new p` is rejected:
    the body's `p.a` read the capture, not the new `p`, so `new p =
    P(a: 7)` then `print(p.a)` printed the captured field. Name the new
    value otherwise.
64. A type parameter may not take the name of a built-in type written
    in Rig (`Map`, `Set`, `Item`, `Keys`, ...), as it may not take
    `Int`'s or `List`'s: `fun f[Item](x: Int)` is rejected with "has the
    name of a built-in type". One that used the name was rejected
    already; Trig and loco have none.
65. *Unsound:* a compile-time call folded in a type, an alias, or an
    enum's value holds each argument to its parameter's type, as a call
    in a body does: `[size[Other.east]]Int`, for `fun size[d: Dir]`,
    was computed as `Dir.east`, as was a constant `H: Other = .east` or
    a call giving an `Other`, `[size[Nope.east]]Int` with `Nope`
    unbound was accepted, and `[flag[1]]Int` for a `Bool` parameter was
    "must be known at compile time". Pass a value of the parameter's
    type.
66. *Unsound:* a value lent bare to an actor's method where a `?T` goes
    is shared with the actor's task, so `T` syncs (SPEC §18), as when
    `?` is written: `c.peek(Holder(...))` of a `Holder` holding a
    `^{Job + Sends}` is rejected, as `c.peek(?Holder(...))` was.
67. An object's none given to its constructor as a qualified variant or
    a constant, `Tagged(kind: Kind.empty)` or `Tagged(kind: EMPTY)` for
    `none kind == .empty`, or as a binding that never changes or a
    compile-time call's value, is rejected when checked, as `.empty` was
    (SPEC "An object that names its none"); it panicked when run.
68. *Unsound:* a slice going to a task shares its elements, so they
    sync, as a `?T`'s value does (SPEC §18): `n(?ts)&` for `fun
    n(ts: []Task[Int])`, and a `[]Holder` lent to an actor whose
    `Holder` holds a `^{Job + Sends}`, are rejected. A `![]T` still
    needs only that `T` sends.
69. A sigil before a `for` source's method call lends the call's self,
    as before any call (SPEC "for"), so `for x in <b.mk()`, where `mk`
    does not consume `self`, is rejected as `<b.mk()` is anywhere:
    "`mk` does not consume `self`; remove the `<`". Write
    `for x in b.mk()`, which consumes the List the call makes, as the
    `<` did.
70. *Unsound:* the right side of `and` and `or`, and each part of a
    binding condition after the first (`if a and b as x`, the same in a
    `while` and a ternary), runs only on some paths, and a move or a
    take there counts only on those: `ok = no() and take(<g)` then
    `<a`, where `g` views `a` and has a `drop` body, is "cannot drop
    `a` while it is lent" (its drop body read freed memory), and a
    field taken there and assigned after is dropped first (it leaked).
71. A store the ownership checker would follow through more than 16
    write views in a chain, and generic methods whose calls do not
    settle what they require of each other in 1,000 rounds, are "this
    store (call) is too complex for the ownership checker; split it
    into smaller functions", as a loop past its bound is; such a
    program was accepted unchecked.
72. A task is placed in no Cell, even one with no loan, nor a value
    holding one in a Cell (`*Cell(<t)`, `*Cell(Job(t: f()&))`): "a Cell
    holds no task, and `Task[Int]` is one: a cycle through a Cell could
    keep the task from ever being waited for". A task lent to write
    leaves its binding by no use of its name: `break t` of one is
    "`t` is a task lent to write, ... only waited for or canceled where
    it is bound", as `<t` was. Wait for the task first.
73. *Unsound:* a value holding a task keeps the task's loans while it
    lives. A local object (`j = Job(t: total(?xs)&)`), an optional
    (`o: Task[Int]? = total(?xs)&`), a count of a `*Job` holding one,
    and a task given back by a `time.within` closure (`|?xs|
    total(?xs)&`) let `!xs.push(2)` or `<xs` through before the wait,
    and the task read the List after it changed or was dropped (one
    program printed `0` for `3`, and the sanitizer did not see it).
    Each is "cannot lend `xs` to write while a read loan is live" or
    "cannot drop `xs` while it is lent": wait for the task first.
    The same rule rejects two sound forms: a function `-> Task[Int]`
    keeps the caller's lent parameter lent until the wait, even when
    its task does not read it (take the parameter away, or wait before
    writing), and a `?@` method that gives a task is called with its
    lend written, `?b.spawn()`, and keeps `b` lent until the wait.
74. A pattern binds a variant's fields by name: `:w` binds the field
    `w`, `w: width` binds it as `width`, and only a variant with one
    field binds by position too (`.circle(r)`). A positional pattern
    over several fields, which a reorder of the fields rebinds without a
    word, is rejected with its by-name form: "`rect` has 2 fields; bind
    them by name: `.rect(:w, :h)`" (`.rect(h, w)` is `.rect(w: h, h:
    w)`). `w: w` is rejected for `:w`, and a pattern that binds and
    tests nothing, `.rect(_, _)`, `.circle(_)`, `.rect(w: _)`, or
    `.dot()`, for the bare `.rect`; `w: _` beside other fields is left
    out. Inside a pattern's parentheses `:x` names a field, never a
    symbol. `tools/migrate-patterns.py PATH...` rewrites each, from each
    variant's declaration, and prints `MANUAL` where it cannot be sure.
    It rewrites 21 patterns in 6 of Trig's files and 15 in 4 of
    loco's (`rig/loc/`), with no `MANUAL`.

Standard library, by `tools/migrate-std-0.3.py` (MIGRATING-0.3, Step
4), each old name rejected with the new one in the message:

72. std.json: `json.parse(?src)!` makes a Doc in one step, and
    `json.new_doc()` is `json.Doc()`, which `(!doc).load(?src)!` fills
    again and again. `(!doc).parse(?src)`, which answered a `Bool`, is
    gone. `doc.size()` is the field `doc.len`, and `get_int`,
    `get_str`, `get_bool`, `get_float` are `doc.int(i)`,
    `doc.string(i)`, `doc.bool(i)`, `doc.float(i)`. Each reason a
    document cannot be read is a member of `JsonError` carrying its
    offset, `JsonError.eof(at: 5)`: `JsonError.bad(kind:, at:)`,
    `json.Error`, `json.error_name`, `doc.error`, and `doc.error_pos`
    are gone.
73. `text.compare(a, b)` and a BigInt's `a.compare(b)`, which gave -1,
    0, or 1, are gone: `a.order(?b)` gives `.less`, `.equal`, or
    `.greater`, and `<` compares. The script rewrites a comparison of
    the result with 0, and prints `MANUAL` for a result used as an
    `Int`.
74. A BigInt compares with `==`, and `a.equals(b)` is gone; `to_f64` is
    `to_float`.
75. `math.powf(x, y)` is `math.pow(x, y)`, one `pow` for every number
    type.
76. `std.iter` is gone: `iter.count(!it)` is `(!it).count()`, and
    `iter.sum(!it) ?? 0` is `(!it).sum()`, which gives 0 for no items
    where `iter.sum` gave `none`.
77. `slices.contains`, `slices.index_of`, `sort.lower_bound`, and
    `sort.search` take a view of what they look for, `x: ?T`, so a
    clone passed there, `+s`, is "lend `?s` instead", and a branching
    value, `a if c else b`, is lent as `?(a if c else b)`; a literal or
    a bare name is lent as before.

Trig: 38 sites rewritten by the script, 22 left `MANUAL` (20 a
`compare` result used as an `Int`, a `powf` of two `Number`s, one
test's `parse`). loco needs no change.

One change in what a program prints: `random.int` draws by Lemire's
method, one multiply in place of two divisions, so a seeded `Random`'s
`int` and `shuffle` give other numbers than 0.2.9's for the same seed.
`next` and `float` are unchanged.

One form changes meaning rather than failing: a binding with no type of
a loop's value that is a write view at every `break` (`l = while true`
then `break slot(!n)`) holds the write view, as an `if` does, so `l = 1`
writes 1 into `n`. `v0.2.9` copied the value, so such a program compiles
under both and now writes where it read. Give the binding its value's
type, `l: Int = while ...`, to copy as before, or keep the view.
`tools/migrate-0.3.py` prints a `MANUAL` line for each such binding and
rewrites none; 2 of the 4,836 v0.2.9 programs have the shape, at one
site each.

Programs written against `main` since `v0.2.9` also meet forms that
changed again before 0.3.0: `Moves` and `Shares` are `Sends` and
`Syncs` (`tools/rename-task-bounds.py`), `std.hash` is gone
(`tools/migrate-builtin-map.py`), `Symbols` is `text.Interner`
(`tools/rename-interner.py`), `rarely fun` is `rarely` in the body
(`tools/rarely-body.py`), `b'A'` is `'A'`, an iterator in a place is
`for x in !it`, `within:`, `wait_all`, and `task.both` are gone, and a
public generic that nests itself through a call through an API is
reported where it is declared (#647), and, the select making every arm
before it runs one, an arm of `task.select` may not take or write what
another arm's closure views, nor two arms lend one value to write,
nor read what an earlier arm's closure lends to write, nor take a
channel, or the List holding it, that another arm waits on
(*unsound*: the first read freed memory). An arm for an enum's
variant after arms that test its optional field both ways
(`.got(v?)`, `.got(none)`, then `.got(_)`, or a `_` that covers
nothing else) never runs and is rejected. A sigil before a `for`
source's method call or chain lends its self or source as anywhere:
`for x in !(!b).items()` is "remove the outer `!`", `for x in
!b.each().filter(f)` of a `?@` `each` is "remove the `!`", `for x in
<xs.filter(f)` is "`(<xs).filter(...)` takes `xs`, and
`xs.filter(...)` walks it where it stands", a `?` or `<` before a
chain that reaches no place (`?mk().filter(f)`) is "remove it", and
`?it.filter(f)` of an iterator is "lend it to write". A chain whose
result keeps its source lent is written with the lend where it is
bound or returned, as any such call is: `vs =
?names.filter(f).collect()`, `y = ?ps.min_by(f) ?? return`.
*Unsound:* a view escaping a block that also held a chain or a closure
padded to its type (`each(|a| print(a))` for a `sub(Int, Int)`) is
"does not live long enough", as it is in any other block; it read
freed memory. A `for` over a chain binds its items immutably, as any
`for` does: `for x in !b.items().filter(f)` then `x += 10` changed a
copy. A loop over a read view held in a binding or a field
(`for x in src`, `src = ?a`) binds slot views, as `for x in ?a` does:
`z = <x` there is "cannot move loop view `x`".
MIGRATING-0.3 lists each.
`(!doc).load(?src)`, failing with `JsonError.bad(kind:, at:)` on `main`,
fails with the reason's own member, `JsonError.eof(at: 5)` (item 72).

### Language and compiler

- **A pattern binds a variant's fields by name** (Upgrading, item 74):
  `.rect(:w, h: tall)`, and a variant with one field by position too,
  `.circle(r)`. The message for a positional pattern over several
  fields gives the by-name pattern that means what the positions did,
  and coverage messages name fields the same way
  (`.d(p: none, r: none)`). The emitted Zig is unchanged. Editors
  colour a pattern's `:w` as the field's name, not as a symbol: the
  language server everywhere, and the generated grammars in a `match`
  arm.
- **`$type(x)` takes an operand that runs nothing.** Zig's `@TypeOf`
  never evaluates `x`, while the checkers walked it as run: `$size($type(<s))`
  was a move of `s` that never happened, and `$size($type(f()))` a call
  of `f` that never ran. A call, a move, a write lend, a clone, a box or
  handle, a propagation, a `catch`, or a `panic` in the operand is
  rejected, naming what was found. `$variants($type(x))`, which stopped
  the build with an internal error, is rejected as any `$type` outside
  `$size`, `$align`, `$name`, and `$plain` is. No program in the corpus
  wrote either.
- **`E.from_int(n)` is a range test when `E`'s values fill a range.**
  An enum declaring no values, whose values run from 0, or one whose
  values fill any range `lo..hi`, tests `n` against the range and casts
  it; any other enum decides by a `switch` over its values, which Zig
  lowers to a jump table or a tree of compares. Each scanned the values
  before: a hit on a 352-variant enum takes 0.2 ns (50 ns before), and
  on 2,228 values spread apart 1.2 ns (265 ns).
- **A source file or a module holds less than 2 GiB.** The limit was
  16 MiB; positions in a source are 32 bits, and the upper half of
  their range numbers the names the compiler adds past a source's end.
  A program of 24 MB of string literals, in one file or in a directory
  module of eight, checks in 0.3 s and builds in debug in under 2 s.
- **A closure that captures a field path longer than 65533 bytes is
  rejected** with a message; it crashed the compiler.
- **A call evaluates what it calls before its arguments, every form
  of it.** When a call's arguments run first, into temporaries
  (keyword arguments out of order, or an owned argument before one
  that can fail), the handle of an actor's method, a self that can
  leave (`(o?).f(...)`, `(o ?? return -1).f(...)`), and a callee that
  is a value (`pick(k)(...)`, `fs[i](...)`, `mk().f(...)`, `b.f(...)`,
  a local `f`) run first, as written, as a method's self already
  did. A function value is copied in its turn, as plain data is. An
  actor's handle, or a function read through a box, evaluated after an
  argument that took what it read was a use of freed memory; a callee
  read after an argument reassigned it called the new function.
- **A handle made for an actor's read method is dropped.**
  `mka(3).get()` and `mka(3).get()&` drop the handle `mka(3)` gives
  at the statement's end, as any method's made self is; the actor
  leaked.
- **The ownership checker is linear in a function's branches.** A
  branch's end reports a dropped loan only when some value declared in
  the branch is lent: a function of 40,000 `if` statements, each over
  its own List, checks its ownership in 101 ms (831 ms before), and
  16,000 in 38 ms (145 ms).
- **A ternary's condition binds names.** `id = v.id if r.decl as v
  else 0`, `area = r * r if s matches .circle(r) else 0`, and
  `v.id if x as v and v.id > 0 else 0` bind as an `if` condition does,
  with its ownership (an owned temporary, `?a` and `!a` views, `<a.f`),
  and the names are visible in the value before `if` only. The test
  runs first, and emit writes Zig's `if (x) |v| v.id else 0`. A postfix
  guard that binds is rejected with its own message ("a postfix guard's
  condition binds no names"), and a name an `else` cannot see because its
  condition binds it says so.
- **Emit is linear in a type's methods.** Each name written inside a
  type was compared with every method of the type; a set per type
  makes it a lookup. `rig build` of Trig's checker, whose `Checker`
  has 3,244 methods, takes 30.3G instructions to reach Zig rather than
  42.4G (2.03 s rather than 2.52 s), against 27.4G for `rig check`
  alone.
- **A shift amount past the width panics with Rig's message.** A
  run-time amount that is negative or not below the shifted type's bit
  count, for a scalar or a vector's lanes, panics with ``shift amount
  `9` is out of range for `U8` (0..7)``, the text of the constant check,
  not Zig's "integer does not fit in destination type"
  (`rig.shiftAmount`).
- **`task.select` names its arms and gives a value that `match` takes
  apart.** `match task.select(add: !a.on_recv(), sub: !b.on_recv(),
  late: time.after(50 * time.MS))!` gives a value of its own type,
  `select(add, sub, late)` in messages, whose variants are the arms'
  names: a receive's carries the value as `T?`, a send's and a
  deadline's nothing. No arm holds a closure, so the winner's body runs
  in the enclosing scope, two bodies may write one value, and arms may
  give different types; the value may be bound and matched later, or
  tested with `matches`. `time.after(ns)` is the deadline arm. Arms of
  closures are the old spelling, still accepted;
  `tools/migrate-select.py` rewrites them. An unnamed arm of the new
  form is rejected with its name to write.
- **Arms that test one optional field both ways cover the variant.**
  `.got(v?)` and `.got(none)`, with no guard, cover an enum's `.got`, so
  a `match` needs no `_` for it. An arm after them that only that
  variant reaches never runs and is rejected: `.got(_)` ("this arm never
  runs: `.got(v?)` and `.got(none)` cover `.got`"), and a `_` that
  covers nothing else. A match on errors is unchanged: such arms cover
  no member there.
- **A sigil before a `for` source's method call lends its self,** as
  before any call: `for x in !b.drain()` is `for x in (!b).drain()`,
  which was rejected ("write `(!b).drain()`"), as `?b.each()` already
  was. A call's result is walked as its type says: a `!List[T]` for
  writing, so `for x in (!b).items()` writes the elements, and a List
  made there is consumed. In a chain the sigil lends the source, so
  `for x in <xs.filter(f)`, which walked `xs` and dropped the `<`, is
  rejected with both spellings, and a `?` or `<` before a chain that
  reaches no place, which did nothing, is rejected.
- **`collect` keeps views.** A chain's items are what its source's
  `for` gives, and `ps.filter(f).collect()` of a `List[P]` gives a
  `List[?P]` that keeps `ps` lent, as one of a `List[String]` gave a
  `List[?String]`; it was rejected ("`collect` keeps each item"),
  against SPEC. A chain whose result keeps its source lent (`collect`,
  `find`, `min`, `max`, `min_by`, `max_by` of views) is written with
  the lend where it is bound, `vs = ?names.filter(f).collect()`, as
  `r = head(?v)` is; the unmarked form was accepted.
- **A loop over a read view held in a binding views what the view
  views.** `src = ?ps` then `for p in src` and `!vs.push(p)` was
  rejected, "`src` does not live long enough", where `!vs.push(?src[0])`
  and a loop over a view held in a field were accepted, as CORE §9 and
  the reference checker allow.
- **A block that holds a chain or a padded closure checks its views'
  lifetimes** (*unsound*). Their hidden names sit past the source's
  end, and the ownership checker took a node's extent from its leaves'
  raw positions, so such a block ended past every use and no view
  escaping it was reported: `best = ?qs[0]` in a block beside
  `xs.filter(f).count()` read `qs` after it was freed. A hidden leaf
  now stands where its span puts it, at its home in the source.
- **A `for` over a chain binds its items immutably,** as any `for`
  does; assigning one changed a copy and was accepted.
- **Two arms of `task.select` that lend one value to write** are
  rejected with the rewrite: "let one arm write it, or have each arm
  give a value and write `n` after the select".

- **An arm of `task.select` keeps its closure until the select runs
  it.** Emit made each arm's closure environment in a block of the arm
  that ended before the select called the arm, so an arm that captured
  (`|+k, v|`, `|?s, v|`) read a dead stack frame: it printed garbage or
  panicked. The select's block now holds every arm's parts, their
  storage fact's life `select`, each arm's channel evaluated first in
  its turn, and a later arm that fails drops the value an earlier send
  arm made, which leaked.
- **A keyword argument given twice is the call's one error.**
  `*Actor(x, mailbox: 4, mailbox: 8)` crashed the compiler, and
  `task.supervise(f, restarts: 2, restarts: 3)`,
  `*Actor.supervised(..., restarts: 2, restarts: 3)`, and `f(1, a: 2)`
  also reported a parameter missing.
- **An actor's method and `reduce` take a place lent bare where a view
  goes.** `d.peek(p)`, for `fun peek(?@, h: ?Plain)`, and
  `xs.reduce(0, g)` of a closure binding `g` were rejected as if the
  call kept the argument ("keeps `p` lent in what `peek` stores").
- **`task.select`'s arms join their types.** An arm that can fail and
  one that cannot give the type that can, in either order, and an arm
  that panics decides nothing; the first
  arm alone decided it, so `select(a.on_recv(|v| v ?? 0),
  b.on_recv(|v| chk(v)!))` was rejected and the same arms swapped ran.
- **A `par` closure in error is reported once.** `par.map(?xs, |x| x +
  nope)!` also reported "`!` needs a fallible operand; this expression
  has type `List[invalid]`"; the call now builds nothing on a body in
  error, as a generic call does.
- **Three messages say what is wrong.** `a > 2` of an `a: Int?` says an
  optional orders only beside another, and gives `a ?? x` and `if a as
  v`, where it said `Int?` cannot be ordered; `List(["p", "q"])` for a
  `List[?String]` says to push each element, `!xs.push(x)`, not a copy,
  which such a List does not take; and an error of a set whose name
  starts with a vowel is "an `AB` error".
- **A compile-time `panic` reads its message's escapes as the run time
  does.** `panic("bad \x41 \u{42}")` in a compile-time function was
  reported as `bad x41 u{42}`; it is `bad A B`.
- **A `?T` parameter takes a literal beside a `String`.** `keep(String("own"),
  "lit")`, for `fun keep[T](a: T, b: ?T)`, was "conflicting types for
  `T`: `String` and `Static`"; a `Static` binds as the `?String` it is
  read as, so `T` is `String`.
- **`sum` adds a generic's elements.** `xs.sum()` of a `[]T` with
  `T: Num` adds them, as `+` on a `T` does, and on an unbounded `T` is
  checked at each instance; it was "`sum` adds numbers".
- **A built-in type written in Rig is found by scope.** `Map`, `Set`,
  and the other types of std/prelude.rig are declared in a scope around
  each module's that names one, where any nearer name hides them. The
  Parser wrapper rewrote every leaf so spelled into the prelude's type,
  whatever it named: an enum's or error set's variant `Set` or `Map`
  vanished from its type, so a `match` without it was accepted as
  exhaustive; a local or closure parameter named `Values` or `Map` was
  "a type, not a value"; one file's `use x as Map` hid the built-in
  `Map` from every file of a directory module; and messages named
  `__rig_prelude.Map`. Each keeps its own name now, and messages say
  `Map`. `rig check` of a directory module of 400 files that name
  `Map` runs 68% fewer instructions (lexing and parsing it took 409 ms,
  now 21 ms), and bench/check's workload 2.7% fewer.
- **A match on another module's enum reads its payload fields in that
  module's types.** Emit told a binding `r?` of an imported variant's
  optional field by looking the field's type up in the matching
  module's own type store, where it named another type, or none: a
  module with fewer types than the enum's stopped the compiler.
- **`x matches none` says to write `x == none`.** It was rejected as
  "`none` matches every value", which `none`, the absent optional, does
  not.
- **A chain takes up to 64 stages.** One of 9 to 12 stages was
  rejected with a message about a hidden name (closure `0`, or `none`),
  and one of 13 or more stopped the compiler; each stage up to 64 works,
  and a longer chain is rejected with the limit. A `map` before
  `count`, whose items `count` does not read, is accepted: it was
  rejected as an unread hidden binding.
- **A type that prints itself prints whatever it holds,** a `[]U8`
  included, and a generic one whatever its type arguments are (a
  `G[[]U8]`), since its `print` method chooses what to write; a weak
  handle prints whether its value lives whatever it reaches, a `~T` of
  an object holding a `^{Shape}` with no `Print` included.
- **A `*Frozen[List[T]]` lends its `[]T` to a generic parameter,** as
  it does to a concrete one: `first(f)` with `first[T](xs: []T)` infers
  `T` from the List the handle froze.
- **The compiler says self, never receiver.** `rig check --facts`
  names the self of a method call `self` (`self call 18:9-18:13 ...`
  under `--facts=storage`, ` self` among a call's fills under
  `--facts=sema`), and the compiler's sources, tests, and docs say
  self, object, and lend where they said receiver, struct, and borrow.
  The emitted Zig is unchanged.
- **`text.find_last` searches 16 bytes at a time,** as `find` does. It
  was Zig's `std.mem.findLast`, a byte at a time for needles of up to 4
  bytes: a needle of 1 to 4 bytes at the start of a 64 KiB text is now
  found 45 to 100 times faster, and a longer one 3 to 8 times.
- **`text.Interner`'s table is at most half full.** It was rebuilt only
  past four fifths, where a miss probes about 13 slots; it now doubles
  at half, so it is a quarter to half full (it was a fifth to four
  fifths), and a lookup at 100,000 strings is about a third faster.
- **std.terminal bounds what a program's output makes it hold.** A
  char keeps at most 64 runes after its first, as Ghostty does, and a
  terminal drops the styles no cell uses once they pass 4,096 and a
  quarter of its cells. Two million truecolor SGRs and as many combining
  marks grew an 80x24 terminal without history to 164 MB; it stays under
  5 MB.
- **`terminal.Terminal.new` panics on a size that is not positive.**
  A terminal of no columns looped forever at its first `feed`, and one
  of no rows panicked deep in `print`; `new` panics at once, naming its
  arguments.
- **std's argument panics are Rig's `panic`.** std.text, std.bigint,
  std.math, and std.random raised the panics of a misused argument (an
  empty separator, a negative shift, an empty range) from Zig shims;
  each is a `panic` in the Rig function, with the same message and
  the position of the std line that raises it, and std/bigint.zig is
  gone.
- **std.utf8 checks UTF-8 for std.json and std.utf16.** One block
  check, `utf8.block_errors` (Keiser and Lemire's), serves `is_valid`,
  `rune_count`, `utf16.unit_count`, which is `utf8.weighted_count[2]`,
  and std.json's strings, which also read a sequence with
  `utf8.rune_after` and write one with `utf8.push_rune`; std.json and
  std.utf16 each held a copy. `is_valid` checks 64 bytes at a time
  where it read a rune at a time: over 1 MiB of mixed ASCII, Latin, and
  CJK text it takes 80 µs where it took 127 µs, and pure ASCII as fast
  as before. std.json's guard: gsoc-2018 takes 4.5% fewer instructions
  per byte, the other five files within 0.5%.
- **std's names, one per idea** (owner, 2026-11-04). std.json reads a
  document in one step, `json.parse(?src)!`, and fails with the reason
  as a member of `JsonError` carrying its offset; a Doc's length is
  `doc.len` and its getters `doc.int(i)`, `doc.string(i)`, `doc.bool(i)`,
  `doc.float(i)`. `BigInt` provides `Eq`, `Ord`, and `Hash`, so `==`,
  `<`, `sort`, and a Map's keys take it, and `order` replaces
  `compare` there and in std.text. One `math.pow` serves every number
  type, an integer's by squaring and a float's by Zig's `std.math.pow`.
  `slices.contains`, `index_of`, `sort.lower_bound`, and `search` take
  a view of what they look for. std.iter goes: a chain counts and sums
  any iterator, and a chain's `sum` adds items that view numbers, as a
  Map's values are (`?m.values().sum()`), which it rejected.
  `random.int` draws by Lemire's method, one multiply and a division
  only on the rare draw it rejects. `tools/migrate-std-0.3.py` rewrites
  the old names.
- **Iterator chains.** `xs.filter(f).map(g).sum()`, on any `for` source
  (a List, array, slice, range, or iterator), is the loop it means,
  checked and emitted as that loop: stages `filter`, `map`, `take`,
  `skip`, `enumerate`, `zip`, and consumers `count`, `sum`, `any`,
  `all`, `find`, `min`, `max`, `min_by`, `max_by`, `reduce`, `collect`,
  or a `for` over it (docs/design/iterators.md). `min` keeps the first
  of equal items and `max` the last, as Rust's do. Over 200,000 Map
  entries, `?m.items().filter(f).min_by(k)` ran 6-8% faster than the
  hand loop it replaces (it copies the key once, at the end); a
  filter-map-sum over 20 million `U64`s ran as fast as its loop. A
  chain's function that can fail is rejected for now. A chain is
  checked stage by stage before it is rewritten, and its errors speak
  its terms: `` `sum` adds numbers, and these items are `String`s ``,
  `` `min_by`'s key is compared with `<`; `P` has no order ``, and a
  `collect` of views gives the fix, `.map(|x| +x).collect()`. After
  `zip` or `enumerate`, `count()` counts the pairs, and `sum`, `min`,
  `max`, `min_by`, `max_by`, and `collect` ask for a `map` to one value
  first; `take` or `zip` before a `min` or `max` stops it, and a `min`
  over a List's made values continues after its first item.
- **`x matches P` tests a pattern.** It is a `Bool` anywhere, and in
  an `if` or `while` condition binds the pattern's names in the body;
  anywhere else the names flow right through `and`
  (`e.state matches .ready(s) and s > 0` in a closure). Alternatives go
  in parentheses after a space, `x matches (.a, .b, .c)`. It is the
  `match` it means, so it costs what that `match` costs. It replaces
  `x as .p`, which read as a cast and stood only in a condition.
- **Alternatives bind when they agree.** `.failed(c, _), .timed_out(c)
  => report(c)`, and the same list after `matches`, binds `c` when every
  alternative binds the same names with the same types; otherwise the
  message names the name or type that differs. Emit writes an `inline`
  prong, which Zig instantiates per variant.
- **A payload's optional in a pattern.** `.ready(r?)` matches when the
  optional field holds a value and binds it, `.ready(none)` when it
  holds none, and `.ready(_?)` tests for a value. One `<` on the
  subject sets how every binding is held: `if <e.state matches
  .ready(img?)` owns `img`. The diagnostic for a field of a read
  binding passed by value offers `<` on the subject before `+`.
- **Every form checks and lowers a pattern one way.** A match arm, the
  `Bool` of `matches`, and the one arm of an `if`, `while`, or ternary
  condition share their checks, so each accepts and rejects the same
  patterns. Alternatives that bind `name?` beside a plain field
  (`.b(m), .d(m?)`) bind the value inside the optional in every form;
  the Zig failed with "expected `i64`, found `?i64`" for a String, a
  List, an object, an `Int` in arithmetic, and a write view. A match
  arm whose alternatives name every variant runs; its Zig failed with
  "unreachable else prong". In a condition, error alternatives that
  bind, and a name alternatives bind that nothing reads, are rejected
  as the `Bool` form and a match arm reject them; the Zig failed.
  `if <s matches .a`, binding nothing, drops what the pattern leaves
  out at the end of the block, as `match <s` does; it dropped the value
  before the body. `n matches K`, `K` a module constant, compares with
  it, as a match arm does; it was rejected as matching every value.
  A literal subject compares with an `Int` constant (`match 4` / `K
  =>`), which was "expected `Int`, got `Int`".
- **Optional fields are covered value by value.** An arm that tests a
  payload's optionals covers the values it tests, each field holding a
  value or none, so arms over two fields, or over different fields,
  cover a variant once no value is left out, and a match that misses
  one names it (`.d(none, _, none)`). Rejected: an arm whose values
  the arms before it cover (`.ready(_?) => 1` then `.ready(_?) => 2`),
  which was accepted and never ran; two alternatives of one variant
  that match a value in common, or bind a name to two fields; and a
  `matches` whose alternatives name every variant, which always holds
  (`if s matches (.a(n), .b(n))`, whose Zig failed): bind its fields
  with `match`. `(.ready(_?), .ready(none))` is accepted, as
  alternatives that match different values. A test of an error's
  optional field (`.bad(n?)`, `.bad(none)`) is rejected with the
  binding to write instead; its Zig failed.
- *Unsound:* names that alternatives bind (`.b(t), .c(t)`) take the
  loans and moves one pattern's names take, in the ownership checker
  and its oracle: reassigning, moving, or reading the subject while one
  lives, and moving one twice, were accepted and used freed memory.
- **`name?` in a generic instance.** `.b(n?)` of an `E[Int?]` binds the
  value inside, by the pattern's test; its Zig failed when the type
  argument was optional. Alternatives whose name nothing reads compile
  in a generic body, and `return v` of a read binding copies the view,
  as the tail value does.
- **A clone ends a view before the call writes.** A clone that holds
  no view is made where it stands and keeps nothing lent there (CORE
  §6), so `!m.take(+e.key)` works where `e` views `m`, as in a cache's
  `trim`; `!m.take(e.key)` is still rejected. A clone made through a
  view, passed to a call that writes or moves anything, is no longer
  reported as a wasted clone.
- **A guard takes no block.** `return if c`, `break if c`, and every
  other postfix guard end their statement, and a deeper line after one
  is rejected at the guard's `if`, with the fix: `return` in each
  branch, or no `return` where the `if` is the function's last
  expression. It was "unexpected indentation". A guard's condition
  still continues on a deeper `.` line.
- **`text.find` tests 16 places at once.** std.text's `find`, and
  `count`, `contains`, `cut`, `split`, and `lines` through it, find a
  needle of two bytes or more by testing 16 places a match may start at
  with two compares of 16 bytes, at its first and last bytes, or at its
  two rarest over a text of 64 KiB or more, and confirming each
  candidate; Zig's `std.mem.find`, which it replaces, tested one place
  at a time. A needle of one byte keeps Zig's `findScalar` for a text's
  first 4 KiB and, on aarch64, steps 64 bytes past it. On the Mac, over
  lib.dom.d.ts (2.4 MB), a miss of a 3-byte needle takes 72 µs where it took 2.98 ms,
  of a 12-byte one 71 µs where it took 711 µs, of a 40-byte one 73 µs
  where it took 303 µs, and of one byte 30 µs where it took 50 µs (66%
  faster); no search of 8 bytes to 4 KiB is slower. `bench/text/guard.py`
  holds each search's instructions to a baseline, and AGENTS.md makes it
  a gate for compiler, runtime, and std changes, as the json and hash
  guards are.
- **Small objects of integers are one word.** An object whose fields
  are integers, slots, or other such objects, filling 8, 16, 32, or 64
  bits exactly, is word-sized. A read view of it copies it, as one of a
  number does. Emit holds it as a Zig `packed struct`, which is made,
  copied, and compared as one word: there are no two half-word stores
  then read as one load, which the processor cannot forward. It stays a
  plain struct where a write lend anywhere in the program takes one of
  its fields' addresses (docs/internals/INTERNALS.md, "Word-held
  objects"). Programs mean what they meant.
- **A match on an error value binds what it checked.** A read match's
  catch-all of an `error`, or of a set whose members carry fields, is a
  view of the error where it is, and a write match's a write view, so
  `match a` then `y` lent on as `?y`, `!y`, or `y` builds; it was bound
  as a copy that the view it was used as did not fit, a Zig error. A
  guard's `g: X` binding of such an error, `X` a set without fields, is
  the error's code as an `X`, as the arm's is; it was the whole error.
- **A field's default may be a vector constant.** `v: Quad = NONE`,
  with `NONE = Quad.splat(0)`, builds: the default reads the value the
  constant was made from, which Zig knows when it compiles, while the
  program's other uses of `NONE` stay run-time values.
- **A statement's loans end at their last use.** A loan a statement
  took lasted to the statement's end; it now ends at the last use of
  the value that carries it (CORE sentence 6), in the order CORE §6
  gives: a binding's last use in its statement, and an argument or
  operand once its call returns or its operator yields. Plain data read
  as a value (an operand, a field or element read, an argument of a
  plain type) is copied where it stands, through a view too, and keeps
  nothing lent. So `x = ?v[0]` then `!v.push(Item(n: x.n))`,
  `print(firstw(!v).n, v.len)`, `print(w == a)` with `w = !a` and `a`
  plain data, `print(r == bump(!a))` with `r = ?a`, a `match find(!v)`
  or `if o as it` whose body writes `v` after its payload's last use,
  `mk(?v).len + grow(!v)`, and `v, s = mk(?s)` with `v` not read again
  are accepted. Still rejected: a view an earlier argument or operand
  hands over while a later one writes what it views
  (`print(first(?v), bump(!v))`, `f(r, bump(!v))`), a binding read in
  a loop it was declared outside of, a match guard that writes what a
  later arm reads, and a name that a call, an array, or an assignment
  reads where it runs, after a later operand (`f(b: r, a: bump(!v))`,
  `xs[bump(!v)] = r`). This only accepts more programs; the emitted Zig
  of every program accepted before is the same.

- **An argument evaluated first reads a held view into a value.** A
  call whose arguments go into temporaries first (keyword arguments
  given out of order, or an owned argument before one that may fail)
  gave a name, field, or element holding a view, passed where a value
  goes (to a function, a method, or a constructor), the view's type
  while writing its value: `g(b: r, a: bump(!v))` with `r =
  ?u[0]` and `b: Item` was accepted and failed in Zig. The temporary
  now has the value's type wherever the checkers recorded that the
  parameter or field reads the view through.

- **A loop reads a view a call returns where it points.** What the
  loans of a value name (a place, a value made in its statement, both,
  or neither) is one fact, decided by `sema.viewsOf` from what each part
  hands over (CORE §9, now built), and recorded where a loop's source
  asks it. A `for` over a call's returned view of places walks it in
  place, as it walks a place: `for x in first(?ls)`, a path through one
  (`pick(?lss)[0]`), a view field of a made value (`wrap(?xs).items`), a
  lend of one (`?first(?ls)`), and a write view one returns
  (`!first_mut(!ls)`), where a List of owners was rejected with "bind it
  to a name first". The owner stays lent while the loop runs. A view
  whose loans name a value made in the header is still rejected, and
  the hint now names that value (`bind mk() to a name first`). This only
  accepts more programs; the emitted Zig of every program accepted
  before is the same.

- **A `for` over a call keeps lent only what its view carries.** The
  loans its header takes end with the header (CORE §3), and the loop
  holds what the source's value carries: of `b.all()`, whose method
  says `from @items`, only `b.items`, as `r = ?b.all()` does; of
  `find(?lss, ?k)`, only `lss`. So the body may write `b.other` or `k`,
  where all of `b`, and `k`, stayed lent for the loop.

- **A member's facts live in the tree.** A type declaration holds the
  names of its `pub` members and its read-only fields in its `pubs` and
  `read_only` groups; a function the names of its `once` parameters in
  its `once` group; a method declared outside its type's body the tag
  `outside`; and a `for` whose `?` reaches the self of its source's
  first method call the tag `lent`. They replace five tables of the
  parser wrapper's, keyed by node id or source position, and the
  ownership checker reads a `once` parameter from the function's
  recorded origins. A stray `rarely` is found from the tree. No
  program's meaning changes: the emitted Zig is the same.

- **`rig check` of Trig is twice as fast in a third of the memory.**
  On the Mac it takes 1.9 s where it took 3.9, with 58% fewer
  instructions, and peaks at 0.65 GB where it peaked at 2.15. Sema's
  integer-keyed tables hash by one multiply, not Wyhash; what a view of a
  type could hold is worked out once per pair of types; decisions and
  expression types are kept by node id; and the compiler allocates from
  `smp_allocator`, not one arena that kept every buffer a table grew out
  of. What `rig check` accepts and the Zig it emits are unchanged
  (docs/history/records/2026-10/check-speed/).

- **Parentheses and bounds live in the tree.** The grammar keeps a
  parenthesized expression or type as `(paren e)`, which the parser
  wrapper reads for the self-sigil rule (`!(v.pop())` against
  `!v.pop()`), a handle's suffix (`*(T?)`), and a `??` chain's grouping,
  then drops, so the wrapper no longer lexes the source again after a
  sigil or compares where nodes start. A declaration's type-parameter
  bounds are its `bounds` group in the IR (`owner_bounds` for a method
  declared outside its type's body), which the resolver reads from the
  declaration, in place of three tables keyed by source position.
  `rig parse` shows `(paren e)`, and `rig normalize` each declaration's
  bounds. No program's meaning changes: the emitted Zig is the same.

- **Plain data views nothing.** SPEC's "Plain data" is CORE's plain
  kind: a value that copies, owns nothing, and views nothing. A
  `?String`, and an object, enum, optional, or array holding one, is a
  view, as CORE §1 says and as the compiler already treats it
  (`$plain(?String)` is `false`). A `Cell` or `Signal` holds a value
  that copies and whose only views are `?String`s, as before. Docs
  only: no program's meaning changes.

- **`target.debug`, the build mode.** `std.target` gives `debug: Bool`,
  whether the build is a debug build, which checks for leaks (`rig run`,
  `rig test`, and `rig build` without `--release`), false in a release
  build. It is a constant the build sets, as `target.os` is. So a
  program can end at once after its output in a release build, with
  `os.exit(code) if not target.debug`, and still be dropped and
  leak-checked in a debug one.

- **`target.has(f)`, the CPU's features.** `std.target` gives
  `has(f: Feature) -> Bool`, whether the CPU the program is compiled for
  has feature `f`: a value of the built-in enum `Feature`, whose
  variants are Zig's names for the features of x86-64 and arm64, merged
  (`.avx2`, `.bmi2`, `.sse4_2`, `.neon`, `.sha3`, `.sve`, ...), false
  where the architecture has no feature by that name. Called on a
  variant it is a constant, checked as `target.arch` is, so
  `LANES = 8 if target.has(.avx2) else 4` keeps both branches and Zig
  takes the one the CPU picks. A Zig-backed function may be an
  `inline fn`.

- **`none` of a large optional is one store.** A `T?` over 16 bytes
  whose `T` is an object, a payload enum, or an array writes `none` by
  its flag alone, where Zig wrote every byte of it zero: an empty pop of
  sanstun's 176-byte `Event?` takes 0.26 ns, from 1.9. A payload enum's
  optional now goes through the optional helpers, as an object's does,
  and under `RIG_STRICT_OPTIONALS` is a tagged struct too. A payload
  variant literal compared with an optional (`o == .square(side: 2)`)
  is its payload's value.

- **`target.os`, the operating system a program is compiled for.**
  `std.target` gives `os: Os` beside `arch: Arch`: a value of the
  built-in enum `Os`, whose variants are Zig's (`std.Target.Os.Tag`:
  `.macos`, `.linux`, `.freebsd`, `.windows`, ...), lowered to Zig's own
  type and checked as `Arch` is. A constant that differs by system, a
  signal's number or a `sysconf` name, branches on it,
  `SIGBUS = 7 if target.os == .linux else 10`, and Zig keeps the branch
  the target picks.

- **`rig test std.NAME` runs a standard library module's own tests.**
  `rig test std.crypto` loads `std.crypto` from the library in use, the
  one built into `rig` or `RIG_STD`'s, as the library loads it, and runs
  its test blocks, a directory module's `*_test.rig` files included, so
  a test reaches the module's private names. `rig test std` is rejected,
  and a path still names a program's file.

- **A view of an array held where a slice goes is lent as one.** A
  `?[4]U8` parameter or binding passed bare where a `[]U8` goes, as an
  argument, a binding's value, or an assignment's, reaches Zig as the
  address it holds, where it was written as the array and rejected by
  Zig; a field or an element always was.
- **A short form a fallback gives is written with its type.** The
  checker records each `.name` and `.name(fields)` a `??` or `catch`
  fallback gives, through a branch, an arm, or a block, a bound
  `catch |e|`'s handler included, since its enum's type comes from the
  value the fallback stands for, which Zig does not see: `f() catch |e|
  .err(e)` for an `Out?!E`, and `o ?? (.red if n == 1 else .blue)`,
  were accepted and then rejected by Zig.

- **A lent String or List is appended to in registers.** A function
  lent a `String`, or a `List` with no inline room, to write, which uses
  it in a loop, holds the String's or List's header (its pointer,
  length, and capacity) in a local for its body and writes it back as it
  returns: the storage fact `held_header`. The call's write loan is the
  header's only one while the function runs, so no other code can see
  the difference, and a loop of appends no longer stores and reloads the
  length each time. coreutils' `basenc --base16` encode, whose loop
  appends to a lent String, takes 81 ms of user time on the Mac, where
  it took 218 (and 119 before #780, whose paired load of the length and
  capacity stalled on Apple cores). Not held: a parameter a task, a
  closure, or a `raw` block names, or one of a function whose result
  holds a view (docs/history/records/2026-10/store-forward/).

- **`std.hint.keep`, `net.Ip` and `net.Addr`, and an `Instant` that
  adds and orders.** `hint.keep(?x)` is Rust's `black_box`: an empty
  `asm volatile` that takes `x`'s address and clobbers memory, so a
  benchmark's result is computed and no load moves out of its round.
  `net.Ip` is an IPv4 or IPv6 address and `net.Addr` one with a `U16`
  port, plain data that compares, hashes, prints in the usual text
  (RFC 5952 for IPv6), and parses (`Ip.parse("::1")`,
  `Addr.parse("[::1]:51820")`); `ip.prefix(n)` keeps the first `n`
  bits, the key of a limit by /32 or /64. `time.Instant` is `: Ord`,
  with `t.add(ns)` and `Instant.at(ns)` for code handed the time. A
  Zig-backed function of the standard library may take bare type
  parameters, which its Zig function takes first, when it cannot fail.
- **`file.unlink` and `file.rmdir` remove one kind.** `unlink(path)`
  removes anything but a directory, a symbolic link itself and never
  what it names, and `rmdir(path)` only an empty directory; each gives
  `false` when nothing was there, as `remove` does. Each is one system
  call, so a program that must refuse the other kind needs no `stat`
  first, and each failure is the system's own: `rmdir` of a file is
  `FileError.not_directory`, `unlink` of a directory `is_directory` on
  Linux and `not_permitted` on macOS. `remove` stays either, as C's
  `remove` and Go's `os.Remove` are.
- **A `file.File` syncs, says whether it is a terminal, and opens a
  FIFO without waiting.** `f.sync()` writes the file and what the file
  system records of it out to the device and waits until it has them
  (fsync, or `F_FULLFSYNC` on macOS, which also empties the drive's
  cache), `f.sync_data()` the bytes alone (fdatasync), and
  `f.sync_fs()` the file system that holds it (Linux's syncfs; every
  file system elsewhere); `os.sync()` writes out every file system, as
  sync(2) does, on the blocking pool. `f.is_terminal()` asks isatty, so
  `io.stdout().is_terminal()` decides whether to print columns.
  `file.open(p, wait: false)` does not wait for a FIFO's writer, and
  the File's reads wait as any File's do. The descriptor stays private.
- **std.io gives the standard streams.** `io.stdin()`, `io.stdout()`,
  and `io.stderr()` are `file.File`s on descriptors 0, 1, and 2, left
  open when dropped, so `cat` is `io.copy(!f, !out)` and stdin reads as
  any file does, a block at a time, without opening `/dev/stdin` (which
  on Linux opens the file again, losing a shared offset and truncating
  a `>>` target). A write to stdout goes through `print`'s buffer, and
  one to stderr writes that buffer out first, so all four stay in order;
  a write adds no newline, and `File.flush` writes the buffer out. A
  write that fails is a `FileError`, not the end of the program.
- **`File.read` reads into the caller's buffer.** The read fills the
  room `into` has, on the blocking pool, and allocates nothing when it
  has room for `max` more: one buffer, cleared and read into again,
  carries a whole file. Reading 247 MB 64 KiB at a time into one buffer
  takes 19.3 ms on an M-series Mac, against 32.6 ms before (24.9 ms with
  a fresh String for each read, now 19.7 ms) and 19.6 ms for `cat`.
- **`FileError` keeps the system's reason.** Each errno a file call
  meets is its own member (`no_space`, `broken_pipe`, `loop`,
  `cross_device`, and seven more), and `file.reason(e)` gives the
  system's words for it, as `strerror` does: `true: No space left on
  device` prints as the system's tools print it, not as `Input/output
  error`.
- **A member written short, `.name` or `.name(fields)`, is the error
  value its set makes, wherever the set goes.** The checker records the
  set it names, and emit writes from that: `.bad(at: 3)` passed for an
  `Oops`, returned, held in a field, a List, an array, a Map, a branch,
  an arm, a closure, or a fallback was accepted and then rejected by Zig
  as a field of `rig.ErrorValue`, and so was `.plain()`. Where `error` or
  a union goes, `.name(fields)` is the member of the one set that has
  it, as `.name` was; `.bad` without its fields there is rejected, where
  it was accepted and read fields never written (*unsound*). A member of
  a set without fields is widened to an error value there, and a
  default `.plain` of a set with fields is one. A short-form member lent
  where a view of `error` or a union goes is rejected as `E.name` is.
  `.bad(at: 3)` where a `T!` goes says to name the error set. A payload
  variant as a `??` or `catch` fallback in print's arguments names its
  enum, which Zig needs there.
- **`os.on_broken_pipe(how)`:** a program that calls
  `os.on_broken_pipe(.die)` dies by SIGPIPE when the reader of its
  stdout closes the pipe, as a C program does, so `yes | head -1` gives
  a shell status 141, whether it writes by `print` or through
  `io.stdout()`; `.exit`, the default, still ends a `print` quietly with
  status 0 and fails an `io.stdout()` write with
  `FileError.broken_pipe`. A failed `warn` is still dropped, and a socket's closed peer
  is still `net.NetError.closed`. `.inherit` follows the program's
  parent, as uutils' coreutils do: it is `.die`, unless the program
  started with SIGPIPE ignored (`trap '' PIPE`), when it is `.exit`, so
  a write of `io.stdout()` fails with `FileError.broken_pipe` and the
  program can report it.
- **A SIGSEGV or SIGBUS that was sent ends the program by that
  signal.** `kill -SEGV`, `kill -BUS`, or a program's own `kill` of
  itself ends it as the signal's default action does, status 139, or
  138 for SIGBUS on macOS and 135 on Linux, with no message. The stack
  guard's handler and the sanitizer's took every such signal for a
  fault outside their pages and returned, so a sent one was lost: the
  program went on, a second one aborted it (134), and a later stack
  overflow lost its message. A real fault is reported as before. A sent
  SIGILL or SIGFPE does the same, status 132 or 136, where a debug or
  `--release` build reported it as an illegal instruction or an
  arithmetic exception, with a trace, and aborted (134).
- **A blocking call ends when its task stops, with or without tasks.**
  A file's open, read, or write waiting on another process (the open of
  a FIFO no one writes, a read of an empty pipe, a write to a full one)
  fails with `task.Stop.timeout` at a `time.within` deadline, and SIGTERM
  or SIGINT ends a program waiting in one with status 143 or 130. In a
  program that made no task the open retried the signal's EINTR forever,
  and no deadline could end any of them; in a task the wait ended but
  the call's pool thread stayed blocked, holding a read's buffer, which
  the leak check then reported, and the program's exit waited a second
  for it. Every retry of a blocking system call now asks the task
  whether to stop; with no tasks a deadline sets an alarm that wakes the
  call, and on the blocking pool the waiter that leaves wakes the call's
  thread.
- **`std.crypto`: WireGuard's primitives, in Rig and in constant
  time.** `crypto.ChaCha.of(key)` and `crypto.XChaCha.of(key)` seal and open
  ChaCha20-Poly1305 and XChaCha20-Poly1305 in place
  (`tag = c.seal(!packet, nonce, header)`, `c.open(!packet, tag, nonce,
  header)!`) or from one buffer into another (`seal_into`,
  `open_into`); an open with a wrong tag fails with `crypto.Forged` and
  leaves zeros. `std.crypto.x25519` has `Secret` with `public()` and
  `share(peer)!`, which refuses a low-order key with
  `KeyError.low_order`; `std.crypto.blake2s` has `hash`, `mac[n]`,
  `Hasher`, `hmac`, and `Hmac.of(key)`; `crypto.wipe`,
  `crypto.equal`, and `crypto.random` round it out. Key objects keep
  their keys private, print as `ChaCha(…)` and the like, and wipe
  themselves when they drop. A small Zig file sets Arm's DIT bit around X25519, wipes so the
  optimizer keeps it, and keeps masks from becoming branches. On the
  Mac X25519 is 1.3x as fast as dalek and BLAKE2s 5% to 14% faster than
  blake2; the AEAD beats ring at 8192 bytes and on most opens, and
  trails it on shorter seals (record:
  docs/history/records/2026-10/std-crypto/).
- **ChaCha20-Poly1305 on x86-64 MACs a block at a time.** Past 192
  bytes, the loop on x86-64 runs Poly1305 on 64-bit limbs, four blocks
  one at a time after each of the first 8 double rounds, as a measured
  Zig ceiling does: its one multiplier port makes arm64's 44-bit,
  four-block step twice the work. arm64 keeps that step, as fast as it
  was. The loop is one function, generic over its MAC, and
  `rig test std.crypto` checks both MACs on any machine.
- **A range's counter has its bounds' type.** The counter of `for _ in
  a..b`, and of a bare `for a..=b`, has the type the checker records on
  the range, as a named binding's always did: a range of `U64`, `U128`,
  or `I128` bounds was accepted and then rejected by Zig, which got an
  `i64` counter, and a narrower one counted in `i64`. Every integer type
  runs through its largest value with `..=` and from its smallest.
- **A HashMap's `ensure` lends the value where its table found the
  key.** The table's `ensure` peels the home group, as a lookup does, so
  a key found there returns before the probe keeps a free lane, and it
  lends the value from the slot it found rather than giving an index
  that `value_mut` turns back into the slot; it writes the HashMap's
  `len` only for a new key. A put keeps its own pass, which lays out
  faster for new keys. `ensure_with` and `ensure_by` lend a key's
  value from `edit` when it is there. knucleotide's counts on tables of
  4, 16, and 256 keys (`kn12.rig`) take 9%, 15%, and 13% less time on
  the Mac, within 5% of Rust's hashbrown either way, and 33%, 28%, and
  34% less on pup, less than hashbrown's; bench/hash's `ensure` and
  `ensure_with` rows take up to 13% less on the Mac and 24% on pup, no
  row slower
  ([small-table.md](docs/history/records/2026-10/hash-race/small-table.md)).
- **A large optional result through an API object goes out through
  the caller's place.** A table entry whose result is an optional wider
  than three words, a `Hit?`, writes the value through a place the
  caller lends and returns whether there is one, so a `none` writes
  nothing; the call gives the same `T?` as before. A `none`'s payload,
  and that place, are no longer filled with 0xaa in a safe build.
  ray-dyn: 10% fewer cycles in a fast build and 28% fewer in a safe one
  on the Mac, 18% and 21% fewer on pup, where it is now level with the
  Rust's `Box<dyn>`.
- **A loop of appends keeps a String's or a List's fields in
  registers.** A String's `push`, `reserve`, `push[T, e]`,
  `push(v, keep: k)`, and `add`'s bytes, and a List's `push` and
  `reserve`, grow through one out-of-line function each that takes the
  buffer and returns the grown one by value, so no append passes the
  String's or List's address to a call, and a local's length is no
  longer loaded and stored back on every append. On the Mac a loop of
  pushes to a local String takes 32% less time, to a local `List[Int]`
  39% less, and to a List in a field 21% less; the Benchmarks Game's
  revcomp plain takes 25% less, knucleotide plain 11% less, and Trig on
  pup runs ts-pattern 1.6% and zod3 1.0% faster.
- **A shared value made in a variant's call is the payload's value.**
  `Frame.bulk(data: *Frozen(String("x")))`, and a `*Chan[T](n)` or
  `*Actor(x)` made there, recorded its own signature on the variant's
  callee, so the variant was written as a Zig call that did not
  compile; each call now records only its own. `*Actor(x)` takes its
  type from `x` wherever an `*Actor[T]` is expected (a typed binding,
  an argument, a field, a payload), as `*Frozen(x)` does; it was
  rejected as an opaque type before.
- **`slices.reverse` swaps the first half with the last, its indexes
  proven.** It counts `i` over `0..n / 2` and swaps `xs[i]` with
  `xs[n - 1 - i]`, and the proof pass now proves both: a `for` over
  `0..b / c` bounds its binding by `b`, an index `b - c - i` counted
  down from the end is in range when `i + c <= b` and `0 <= i`, and a
  `!s.swap(i, j)` whose two indexes are proven omits their tests
  (`rig.swapProven`). Its loop was 13 instructions a swap on arm64
  against Rust's 6, and fannkuchredux, which flips with it, took 10%
  more cycles than Rust's; it now takes the same (n = 11: 6.32 billion
  cycles on the M5 against Rust's 6.33, 8.67 on x86 against 8.69).
- **A generic function is inlined by the size rule.** The compiler
  inlined no function with compile-time type parameters unless it was
  marked `inline`; it now judges one as any other function, under the
  largest frame of its instances, so a small generic helper costs what
  the same helper written for one type does. The ray tracer's generic
  `ray_color` needed `inline` for that: without it ray-dyn took 3% more
  cycles, and now takes the same as with it.
- **An instance calling another instance is no cycle.** The yield
  checks of recursion (docs/internals/scheduler.md) treat each instance
  of a function whose compile-time parameters are values as a function
  of its own, and skip a call in an `if` branch its values rule out, so
  `at[true]` calling `at[false]` no longer puts a check at `at`'s
  entry. The check on every call kept LLVM from vectorizing the calls
  of `at` in spectralnorm's inner loop: without it spectralnorm-fast
  takes 1.65 times fewer cycles. An instance that reaches itself, as
  `down[true]` calling `down[false]` calling `down[true]`, still checks.
- **A method call's self is lent where it is, an element too.**
  `?@balls[i].hit(lo)` on a `List[Ball]` whose `Ball` copies gave `hit`
  a view of a copy of the element, so a result that keeps self (`from
  @`) viewed a temporary the next turn of a loop wrote over: every hit
  took the last ball's material. Each element on the path of a lent
  self (`?xs[i].m()`, `?xs[i].f.m()`, `?g[r][c].m()`, a slice's element,
  a generic method's self) is now reached in place, as a `!` self
  already was. *Unsound before.*
- **A write call whose value is used is written short,** `x =
  !v.pop()`, `t = !@new_node(k)`, `while !it.next() as x`, in a
  binding, an argument, an `as` header, under `??`, and in a result.
  Only a call whose method declares a `Bool` result (or `Bool!`) keeps
  its `!` in parentheses where its value is used, `if (!seen).add(k)`,
  so it never reads as `not`; a call returning a `T` is short even
  where `T` is a `Bool`. The long form `(!v).pop()` stays valid
  everywhere. The change only accepts programs rejected before, and
  `tools/drop-write-parens.py` drops the parentheses no longer needed.
- **`^T?` and `~T?` are a pointer's size:** `none` is the null
  address, as it is for a `*T?`, so an optional box or weak handle is 8
  bytes, not 16, and a list node of an `Int` and a `^Node?` is 16 bytes.
- **A field taken with `<p.f` and assigned again drops nothing:** the
  ownership checker knows it holds `none` until it is written or lent
  to write, so `@head = ^Node(elem: <e, next: <@head)` stores without a
  drop of the old value; a drop of an optional tests for `none` where
  it is, before it calls out.
- **The last drop of a short chain of boxes or handles calls nothing
  more:** the queue that deep chains are released through is drained
  only when a release left something in it.
- **A `*T` handle's drop is inline while the count stays above zero:**
  the decrement and its test are where the handle drops, and only the
  last handle's release is a call.
- **An optional view compares as the optional of what it views:**
  `(?Int)? == 3`, `!=`, beside `none`, an `Int?`, or another `(?Int)?`,
  `(?String)?` beside any text or optional of text, and `(?P)?` of an
  object that provides `Eq`, as `?Int == 3` and `Int? == 3` did.
- **A taken binding that owns a resource is lent to write:** `if <o as
  node` then `bump(!node)` of a `bump(h: !*Node)` compiles, as it did
  for a `String`, a List, or a box, for a handle too, in `if … as`,
  `while … as`, `match <x`, and `for x in <v`, in a generic body as in
  a plain one; the binding is a Zig `var` wherever it is written
  through, where a handle's was a `const` that Zig rejected. A taken
  binding of plain data stays a copy that is not written, and one of a
  type parameter's value is moved into a new binding: `new x = <x`.
- **A read view of a handle changes nothing.** A write lend reached
  through any read view is rejected, a Cell or Signal behind a handle
  the view holds or reaches included, with the read view's message,
  "cannot lend to write through a read view `?*Node`"; a handle field
  under a read view (`!w.h.c.set(5)` with `w: ?W`) named the shared
  handle instead. The emitted Zig had written through a `*const`
  (Upgrading, item 51).
- **A generic object holds an optional view of itself:** `prev:
  (?Frame[T])?` in `obj Frame[T]`, a pair of generic objects that view
  each other, and an enum that views itself compile, as their plain
  forms do; a view of an object is a pointer whatever its type
  arguments. A field that names the object's own optional, `T?`,
  anywhere the object's layout needs it (`?Node?`, `List[Node?]`,
  `^(Node?)`, `*(Node?)`, or a generic instance whose fields name it)
  is rejected with the two forms to hold instead, `(?Node)?` or
  `^Node?`; Zig rejected each before.
- **A literal is self of a call through an API:** `Twice.twice(4)` and
  `5.twice()`, given `add Int: Twice`, call `Int`'s method, as
  `Twice.twice(x)` of an `x: Int` does, and a literal that does not fit
  `Int` is reported there.
- **`async` and `await` say what Rig writes instead:** a task is
  started with `f(x)&` and waited for with `>t`.
- **`rarely` in a branch is unlikely:** a `rarely` that starts a branch,
  a `catch` handler, or a loop's body emits Zig's unlikely hint, which
  keeps the block near and lays out the code around it for the path
  that skips it; a `rarely` that starts a function's body still emits
  the cold hint, which moves the function out of line.
- **A frozen value's allocation has no weak count.** A `*Frozen[T]`
  holds a strong count and the value, 8 bytes less than before, and its
  last drop is one atomic decrement that frees the allocation, as a
  frozen value has no weak handle. A `*T` is unchanged
  ([frozen-no-weak](docs/history/records/2026-10/frozen-no-weak/README.md)).
- **`!s.swap(i, i)` leaves the element in place** without handing Zig's
  `std.mem.swap` one place twice, which Zig leaves undefined.
- **A `*Cell` of one word has a cache line of its own** in a program
  that makes tasks: its allocation is aligned and sized to 128 bytes,
  where it took 24. Four tasks each adding to its own Cell, the Cells
  made one after another, took 4-10× as long as one task did. They now
  take the same time
  ([atomics](docs/history/records/2026-10/atomics/README.md)). Every
  other `*T` keeps its size.
- **`for x in ?h` walks a List or an array that a shared handle
  holds**, `*List[T]`, `*Frozen[List[T]]`, or `*[N]T`: it reads each
  element in place, with the loan on `h`, as `?h` lends the value the
  handle holds (SPEC §6 "for"). Tasks walk one frozen List each through
  its own handle. `for x in !h` and `for x in <h` stay rejected, each
  with its own message, since nothing is written or taken through a
  handle.
- **A type that contains itself is told to box the field that leads
  back:** "`Node` contains itself by value through `next`, so it would
  have no finite size; own it through a box (`next: ^Node?`), or share
  it through a handle (`*Node`)". The message suggested only `*Node`, a
  shared handle, which a tree or a list of its own nodes does not want.
- **The runtime's hot helpers make none of Zig's checks that the
  runtime's own invariants prove** (`len <= buf.len`, `len < n`, a
  block aligned by its class) in an optimized build: List's `pop`,
  `items`, and `IntoIter.next`, `at`, `elemPtr`, and `swap` after their
  index test, a table's `push`, String's copies, `FnRef`'s context,
  `freeSlice`, and the allocator's `free`. A debug build keeps the
  checks and asserts each invariant. Trig retires 1.7% fewer
  instructions on ts-pattern and 1.3% fewer on zod3, with `.text` 2.2%
  smaller
  ([runtime-unchecked.md](docs/history/records/2026-10/perf-stage/runtime-unchecked.md)).
- **A Map or Set is 64 bytes, a cache line** (it was 112): the table's
  small tags share their place with an indexed table's index pointers,
  and its counts are narrower; an indexed table of 33 to 48 entries holds
  room for 48 rather than 64. Lookups, puts, takes, and walks run as
  before. On pup, Trig's peak memory is 3.5% lower on ts-pattern (9.8 MB)
  and 4.3% on zod3, with 5-7% fewer L3 load misses and 3-6% fewer kernel
  cycles, user cycles level
  ([small-maps.md](docs/history/records/2026-10/hash-race/small-maps.md)).
- **bench/hash's guard builds its key lists out of line** (`called`), so
  each row's loop runs to the List's length rather than to a constant
  LLVM knows and may build again on every lookup. With it, Rig before
  and after growth by value counts the same on every row (HashMap
  text-hit 100.78 and 100.84 instructions, text-miss 61.96 and 62.15),
  where with the constant the HashMap's text rows read 3.3 and 3.6% more
  after it. The baseline is written again.
- **bench/hash's guard gives the same counts every run.** Each row's two
  runs differ by about 1,000 million instructions, and each count is the
  least of 5, so the 1 to 2 million instructions the kernel adds to a
  run move a row by 0.2% at most, where they moved a cheap row by up to
  7% and failed the guard on `main` in 2 runs of 5. The baseline
  is written again for the Map of 64 bytes, whose rows it predated.
- **bench/hash times each row in a function of its own**, for every
  contestant (`called`, `noinline`, `#[inline(never)]`,
  `__attribute__((noinline))`, `//go:noinline`), so a row's loop is
  compiled for itself and not with the other rows of its group. Every
  line's checksum is unchanged; the guard's program already timed each
  row alone, and its baseline is unchanged.
- **A HashMap grows without waiting on its own stores, on x86-64.** A
  growth to twice the groups places each entry at the next free lane
  of its new group, kept as a count, where it loaded the group's control
  bytes just after the entry before it wrote a tag there, a load that
  waits for the store to commit. bench/hash's growing inserts are 5-36%
  faster on pup and no row is slower; arm64, whose random-key inserts
  were 4-6% slower with the counts, keeps its placement
  ([rehash-counts.md](docs/history/records/2026-10/hash-race/rehash-counts.md)).
- **The built-in tables have a guard.** `bench/hash/guard.py` counts the
  instructions per operation of `Map` and `HashMap` on Int, text, and
  two-word keys, and fails any row more than 2% over its baseline, as
  `bench/json/guard.py` holds std.json; AGENTS.md makes it a gate for
  compiler, runtime, and std changes.
- **`String(...)` is one block of its length.** Text of up to 256 bytes
  is written on the stack and allocated once, as Rust's `format!` makes
  one block, where it grew the String's buffer piece by piece and left
  each key scattered with spare room. bench/hash's text hits at 100,000
  keys take 7.0 ns, not 16.3, against the Zig prototype's 5.7, and text
  removes are faster than the prototype's. A HashMap walk steps by the
  table's `next_slot`, with no checked arithmetic in the loop, so its
  iterate rows are level with the prototype; a HashMap prefetches its
  40-byte text slots; and a Map's rebuilt index clears only its tags
  ([table-gaps.md](docs/history/records/2026-10/hash-race/table-gaps.md)).
- **A float provides no `Ord`.** A NaN is neither below nor above a
  number, so `T: Ord` takes no `Float` or `F32`, a header that names
  `Ord` takes no float field, and a float has no `order`; each
  rejection names `total_order`, or a float's `min`, `max`, or `clamp`
  in place of `math`'s. Comparing two `obj V: Ord` values with a NaN
  field reached Zig's `unreachable`, and `sort.sort` left floats with a
  NaN unsorted. `<` on floats stays IEEE 754's.
- **Floats have methods that compare them.** `x.min(y)` and `x.max(y)`
  give the smaller and the larger float, and a NaN loses to a number
  on either side. `x.clamp(lo, hi)` limits `x` to `lo..hi`.
  `x.total_order(?y)` is the `Order` of IEEE 754's totalOrder, which
  places every float, NaN too, so floats that may hold a NaN sort with
  `sort.sort_by(!xs, |a, b| a.total_order(?b) == .less)`. A `T: Num`
  (and so a `T: Integer` or `T: Signed`) is compared with `<`, `<=`,
  `>`, and `>=` as a number is, and `math.abs` takes `T: Signed`.
  They take the place of `Ord` for floats (SPEC "Floats in order").

- **A generic body's own values hold no untracked view.** A `T` the
  body holds by value carries no loan it tracks, so an instance whose
  type argument can hold the view the body could put in one is refused
  at the call or type that makes it, with a note at the body line:
  where a function value is given a write view of one beside another
  view, where the body holds as one a function value's result given a
  view of memory it owns, and where a type argument's method gives a
  view of self or an argument held as one. The function value's type at
  the instance decides (`sema.defaultOrigins`), so `update` of a
  `Map[?String, Int]` passes. A method's requirement is checked at each
  call of it, so a `Map[String, (?String)?]` is refused only where
  `update`, `retain`, or `ensure_with` is called on one, and
  `ensure_with` keeps nothing of `make`. The oracle refuses those three
  calls alike. A write view of any read view, `!?T`, is rejected as
  `!?String` is, which also ends the Zig a closure's `!?List[Int]`
  parameter could not compile.
- **`HashMap[K, V]` and `HashSet[K]`**, built in beside `Map` and `Set`:
  hash tables whose iteration order is unspecified, with every member
  of `Map` and `Set`, declared as theirs are, but `Map.at`. Their
  entries are held by the compiler built-ins `UnorderedMap[K, V]` and
  `UnorderedSet[K]`, bench/hash's `zig-hash` in the runtime
  (src/unordered.zig). Against the Map, on the Mac and pup: removes at
  4M keys 25-35% faster, turnovers of 1,000 keys and up 23-52% faster,
  misses at 3M-4M 52-81% faster, random hits there 35-45% faster; walks
  and text removes stay the Map's. Of bench/hash's 104 rows, 60 on the
  Mac and 77 on pup are within 5% of zig-hash or faster; 4,000,000 Int
  keys take 51.1 and 54.5 bytes an entry
  ([hashmap-builtin.md](docs/history/records/2026-10/hash-race/hashmap-builtin.md)).
  A program's own type named `HashMap`, `HashSet`, `HashItems`,
  `HashKeys`, `HashValues`, or `HashMembers` hides the built-in one.
- **Map and Set hold their entries in a table built into the compiler**,
  `OrderedMap[K, V]` and `OrderedSet[K]`, which only std/prelude.rig
  names: bench/hash's `zig-ordered` in the runtime (src/ordered.zig),
  as a List's buffer is. `Map` and `Set` keep every declaration in the
  prelude, so every member, its ownership, the order, printing, and
  every diagnostic a test names are unchanged; a message about a Map's
  `==` or `.hash()` names its field `t` where it named `ps`. On pup,
  Trig takes 2.9% fewer cycles on ts-pattern and 3.6% fewer on zod3,
  with 2.2% and 3.1% fewer instructions, and peak memory 0.55% higher
  and 0.8% lower. A Map is 112 bytes (176 before), and holds 4,000,000 Int keys in
  30.7 bytes an entry on the Mac. In bench/hash, 108 of 130 rows on the
  Mac and 109 of 114 on pup are faster than before
  ([map-builtin.md](docs/history/records/2026-10/hash-race/map-builtin.md)).
- **A Map or Set of plain wide keys keeps no hash in its entries:** a
  key of at most four words of integers, plain enums, and `Bool`s
  (through nested objects, none with its own `==` or hash) is hashed
  again when the index grows rather than kept beside it, so a two-word
  key's entry is 24 bytes, not 32, and a probe compares the key where it
  compared the hash. On pup, Trig's peak memory is 3.1% lower on
  ts-pattern and 1.4% on zod3, its time unchanged; bench/hash's
  hits on two-word and three-word keys are 22% and 7% faster on pup,
  as fast as the hand-written Zig table they came from
  ([map-wide-keys.md](docs/history/records/2026-10/hash-race/map-wide-keys.md)).
- **`Map.ensure_by` checks its key**: the key `key(k)` makes must
  equal `k`, and one that differs panics, rather than leaving two equal
  keys in the Map.
- **The built-in Map and Set take zig-ordered's design**
  (std/prelude.rig, still safe Rig): the entries in one List in first-put
  order, with no optional for plain keys and values (16 bytes for a
  `Map[Int, Int]`); up to 16 entries a tag byte each inside the Map, and
  past that an index of 16-byte tag groups (15 tags and an overflow
  byte) beside 32-bit entry indexes, matched a group at once by
  `m.lanes()`, its group and lane indexes masked so they make no test.
  A take drops its key at once and marks the entry gone, so the order
  holds; the gone entries are compacted only when the List is full and
  a quarter gone, as the index grows, or when the last is taken, and a
  walk passes them by runs. Every member, the order, and printing are
  unchanged. On pup, Trig takes 6.0% fewer cycles on ts-pattern and
  4.4% fewer on zod3, with 0.2% and 1.4% more instructions, and peak
  memory 8.0% and 2.8% lower. A Map is 176 bytes, and holds 4,000,000
  Int keys in 32.8 bytes an entry on the Mac (51.0 before; zig-ordered
  37.1). A Map holds at most 4,294,967,295 entries.

- **Masked indexes are proven:** `s[e & m]`, where `m` is `s.len -% 1`
  (or `s.len - 1`) taken inside a guard `s.len > 0`, or any `Int` known
  not negative whose room below `s.len` is known, makes no bounds test,
  for any `e`, a negative one too; and a loop whose every write of `i`
  is `i = e & m` keeps `0 <= i < s.len` at every step, so a probe of
  slot `(home +% d) & mask` is tested nowhere
  (docs/internals/INTERNALS.md, "Proven checks").
- **Prefetch:** `xs.prefetch(i)` asks for element `i` of a List, an
  array, or a slice ahead of its read. It reads `xs` for the call and
  does nothing a program can see: an `i` out of range does nothing and
  never panics. It is one prefetch instruction, `prfm pldl1keep` on ARM
  and `prefetcht0` on x86, with no range test (`test/cli/prefetch.sh`),
  and nothing where a target has none. In bench/prefetch, lookups into
  a 256 MiB List that branch on what they read take 7.8 ns with it, 64
  lookups ahead, and 47 ns without it on Apple M5; 11.3 and 73 ns on
  pup.
- **A mask's true lanes:** `for k in m.lanes()` visits each true lane of
  a mask `Simd[Bool, n]`, lowest first, as an `Int`. `lanes()` gives the
  prelude's `Lanes`, an iterator, so `break`, `continue`, a resumed
  loop, and std.iter work on it. The compiler holds the lanes in the
  form the target reaches fastest: one bit a lane from `pmovmskb` on
  x86 and WASM, and on ARM the nibble mask of 16 lanes (`cmeq`, `shrn`,
  `fmov`) and the bytes of 8 (`cmeq`, `fmov`), with no reduction or
  constant load. Each lane is a count of trailing zeros, a clear of the
  lowest bit, and the branch back: four instructions on Apple M5 and
  x86-64-v3, five on Apple M1 and baseline x86-64
  (`test/cli/mask_lanes.sh`).
- **A view of a generic `as` binding views the optional:** in a generic
  body, `if o as x` and `while o as x` over a view of a `T?` (`o: ?T?`,
  `?h.item`, `?xs[0]`, `?@item`) bind `x` to the value inside where it
  stands, so `return ?x` from a function `from o` views the caller's
  value. It was a copy the body made, which the view outlived: an
  object's fields read back as garbage once the stack was reused.
- **The prelude:** the built-in Map and Set are written in
  `std/prelude.rig`, module `std.prelude`, which every program has with
  no `use`; error messages and profiles name it so. `use std.prelude` is
  rejected with the reason, and a program's own module named `prelude`
  stays its own.
- **Runs of lines for tasks, and counting by a viewed key:**
  `text.chunks(s, n)` cuts text into at most `n` runs of whole lines, to
  hand to `par.workers` a run at a time rather than a line at a time,
  and `(!m).ensure_by(k, key, v)` is `ensure` with the key viewed, its
  key made by `key` only when it is new: `(!m).ensure_by(word, |w| +w,
  0) += 1`. STD's `std.par` says why a task should take runs.
- **Removing from a List in one step:** `(!v).swap_remove(i)` hands
  over the element at `i` and moves the last element into its place,
  where `remove(i)` moves every element after `i`: on a List of 100,000
  elements, 4-5 ns against 63 microseconds to take the first. The order
  of what is left changes.
- **Hashing objects of integers:** an object whose parts are integers,
  plain enums and Bools hashes its words two at a time, one folded
  multiply a pair, as foldhash and abseil do, where it took two
  multiplies a word: Trig's two-word cache keys hash in one, its
  three-word instantiation keys in two
  (docs/history/records/2026-10/pair-hash/).
- **`$plain(T)` narrows a generic body (SPEC "Generic bodies"):**
  `$plain(T)` is whether `T` is plain data, known when the program
  compiles. Where it is an operand of a condition's `and` chain (an
  `if`, an `else if`, a `while`, or a statement's or arm's guard), the
  code that runs once it has held is checked with `T` known to copy and
  to hold no loan, and only the instances where `T` is plain compile
  it: `if $plain(K)` lets a generic body copy a `K` that every other
  instance never reaches. A generic that tests it takes each instance's
  answer as a compile-time Bool, and every generic that builds it from
  its own parameters passes the answer on, so `f[Int]` and `f[?Int]`
  are two Zig instances there; a program that tests no `$plain` emits
  the Zig it did. SPEC's copy rule says what the compiler already did:
  where a body copies a `T`, every instance must be plain data or a read
  view.
- **Generic calls' messages name what they mean:** a conflict between
  the type expected of a call's result and an argument names "the type
  expected of the result", not "argument 0" (`s: String = apply(3, |x|
  x + 1)`), and a numeric one converts the argument, not "argument 0";
  a bracketed generic call is named as written (`` `id[Int]` ``, not
  `` `expression` ``); and an argument whose type differs from a generic
  parameter's inside it names both whole types, as for any call
  ("expected `?fun(Int) -> Int!E`, got `fun(Int) -> Int`", not
  "expected `Int!E`, got `Int`"). A conflict inside one argument says
  where in it each type came from: `ap(h, 3)` of an `h: fun(Int) ->
  String` reads "`Int` (the parameter of argument 1) and `String` (the
  result of argument 1)", not "`String` (argument 1) and `Int`
  (argument 1)", and a numeric one no longer offers to convert the
  argument.
- **`os.exit(code)`:** ends the program now, from `main` or any task,
  with `code` as its status: what `print` and `warn` wrote is flushed,
  and no drop, `defer`, or leak check runs.
- **A Map's lookup and an insert into room are inlined** (Trig's PGO
  build 1.4-1.7% fewer instructions, about 1% faster; release 3.0-3.5%
  fewer; [records](docs/history/records/2026-10/map-inline/README.md)):
  `find` and `insert` are `inline` in Map and Set, so a probe keeps its
  state in its caller's registers and an insert copies no key into a
  call, and only making room (`grow`) is a call. The Map's spills and
  reloads in Trig fell from 412M to 47M instructions a run.
- **Reads cost Trig fewer instructions** (1.5% fewer on ts-pattern
  and zod3, 1.2-2.2% fewer cycles;
  [records](docs/history/records/2026-10/perf-stage/table-reads.md)):
  an inlined call's optional or fallible result is made a run-time
  value in place rather than passed through `rig.rt`, whose memory
  round trip stalled every `m.get(k) ?? x` (`rig.copiedOut` is inline
  too), and a signed index is tested against a List's or slice's length
  with one unsigned compare. A `rarely` function is `noinline`, out of
  line as SPEC says, no longer left to LLVM.
- **A signed index against a compile-time bound is one compare**
  (Trig PGO 0.5-0.7% fewer instructions, 1.5-1.7% with #706's yield check;
  [records](docs/history/records/2026-10/perf-stage/bounds-enum.md)):
  a `Table` read by an `Int`, `Slot[n].of(i)`, an array's element, and a
  vector's lane test `i` as unsigned against `n`, which a negative `i`
  always fails, where a sign test and a bound test made two.
- **A function's name given to `par.map` or `par.each` is checked
  against what they pass:** each element's view, or the value of a
  scalar's read view; a write view as itself. `par.map(?xs, f)` with
  `xs: List[Int]` and `fun f(s: ?String)`, and `par.each(!xs, show)`
  with `sub show(x: Int)`, were accepted and failed in Zig; the first is
  "`par.map` calls `f` with each element as `?Int`, and `f` takes
  `?String`".
- **A view lent through a write-view binding may outlive it:**
  `if !@slots[j] as s` / `return !s.value` in a method `-> (!Int)? from
  @` is accepted, as are the same through `s = !@a`, a `for s in !@xs`
  element, a call's result (`if (!@).find(j) as e`), and a `match !`
  payload (CORE sentence 7). Such a view carries the binding's own
  loans and a loan on the binding that ends with the binding's scope;
  each was "cannot return a view of `s`, which this function was not
  lent". What it views stays lent while it lives, and nothing in the
  binding's scope, its defers included, uses the binding while it
  does; a block's value through a binding of its own block keeps that
  binding from its defers (CORE §7, Defer). A view of a local
  (`s = !x`, then `!s.value`) is still the local's.


- **A field of an owned object moves like a name (CORE §5):** `<p.f`
  of a field that is neither optional nor copies, from an object a
  local or parameter owns, moves the field and leaves `p` partly moved.
  Its other fields stay usable, `p.f = x` makes a local's field usable
  again, and only the fields still held drop, at the scope's end and at
  every exit, each behind a drop flag of its own. Until every moved
  field is assigned again on every path, no use touches all of `p`
  except `p = x`. No field moves through a view, a handle, a box, an
  element, or an optional's value, nor out of a type on its path with a
  `drop` body. Owned bindings (`if <o as s`, `match <x`, `for x in <v`,
  `<@`) are names too. Nothing accepted before is rejected; the
  programs that moved a field out of an owned object, rejected before,
  now run.
- **An optional field of a binding whose fields cannot be assigned
  moves like a name (CORE §5):** `<p.tags` of a parameter, a capture, or a `=!`
  local moves the field and leaves `p` partly moved, where it was
  rejected as a take no one could write (``cannot take parameter `p` ``).
  A local that can be assigned, and a write view, keep the take, which
  leaves `none`. Only programs rejected before are accepted.
- **A public generic states the `Print` of what its callees print:**
  `pub sub show[T](x: ?T)` passing `x` to a private generic that prints
  it is rejected, `` `pub sub show[T]` prints a `T`: write `[T:
  Print]` ``, as printing `x` in `show` is; through any number of
  calls, from a method of a `pub` generic type, through an instance of
  a generic type whose method prints it (`Box(v: x).show()`), and for
  a bounded `T` of any generic. Every instance without `Print` was already rejected
  at the callee's instance, under the callee's name, or printed as
  `print` writes it. Newly rejected: such a `pub` generic without
  `Print`, and a bounded `T` without it passed to a generic that
  prints it.
- **A generic body printing `T`s in a slice or a List checks each
  instance:** `print(xs)` of a `[]T` or a `List[T]` took `T = []U8` and
  wrote its bytes as text, `["Hi"]`; the instance is now rejected, as
  `print` of a `[][]U8` is. Newly rejected: such an instance, and a
  `pub` generic printing a `[]T` without `[T: Print]`.

- **A value of an associated type views its base per instance:** a
  value of `S.Item` that a call on `s` gives (an item of `next`, or of
  `fun one(!@) -> Item from @`) keeps `s` lent only at an instance whose
  `Item` may view memory `s` owns, as Stage 3 checks a call through a
  bound at each instance. A body that holds one past a change of its
  base (a write, a move, a drop), itself or through the generic bodies
  it calls, is rejected at each such instance, with a note at the
  change; a body that holds none, as `iter.count` does, takes every
  iterator. Such an
  instance was rejected whatever the body did, so `iter.count` of an
  iterator whose items view its own memory was refused.

- **A scope's defers run after its value, which they may not touch:**
  the checker re-checks each `defer` at every exit with the loans of
  the value the exit leaves with in force (a block's or an arm's value,
  a `return` or `break` value, a function's last value), so `if c` /
  `defer !@xs.clear()` / `!@xs[0]` is "use of `@xs` while a write loan
  is live", where the caller wrote into a freed element; an `errdefer`
  runs only where that value is an error, and is checked without it.
  `return s`, `return s, n`, and a last value `s` of a write view move
  `s`, as `<s` does (CORE sentence 1), so a later `defer s = ...`, a
  deferred `|!s|` closure, or a task lent `!s` and waited for at the
  scope's end is rejected. The reference checker now holds a task's
  loans until the task's drop waits for it, and keeps a write view
  handed where a `(!T)?` goes a view.

- **A Map and a Set print their entries:** `print(m)` writes
  `{"a": 1, "b": 2}` and `print(s)` writes `{1, 2}`, `{}` when empty,
  the entries in the order their keys were first put in, each key and
  value as an element of a List prints. They wrote their hidden fields,
  `Map(len: 1, es: [...], hs: [...], table: ...)`. `String(m)` and
  `!t.add(m)` write the same text.
- **A release build of objects nested by value is linear:** the
  runtime's `==`, `.hash()`, and `+` reach a field that nests objects
  more than eight deep through a call of its own, so a chain of 400
  objects nested by value builds in 4.9 s, not 211 s, and 1000 in 11 s,
  where it ran past 20 minutes. Shallower objects compile as before.
- **A function value held in an object holds nothing:** the checker
  counted a `fun` field as a view that may point anywhere, so a call
  through a `?sub` lent `!@` and `!n` kept `n` lent past it when `@`
  held a `fun` field. A function value is a named function's address
  (CORE §7); a function type walked itself (a closure binding's), a
  lent `?fun`, and an owned closure still count as anything.
- **API objects' messages give the fix:** `?{Shape}?` and `?{Shape}!E`
  read as a view of a suffixed `{Shape}` and say to write `(?{Shape})?`
  or `(?{Shape})!E`; `[T: {Shape}]` says a bound names the API,
  `[T: Shape]`, and nothing more (it spoke of a value parameter); `+s`
  of a `?{Shape}` says a view copies, and of a `!{Shape}` to lend it on
  with `?s`. An API object's braces join lines as brackets do.
- **Instances reached through an API are named as written:** an
  addition's method shows its type's arguments and its own,
  `Map[Int, Int].look[Float]` (it was `Map.look[Int, Int, Float]`), and
  a public generic that nests itself through a call through an API on
  a type of its module is reported where it is declared, as one that
  calls itself is, though no module calls it (it was reported only at
  an instance another module made).
- **A module's members are its own declarations:** `lib.List[Int]`,
  `lib.print`, or `lib.Cell[Int]`, a built-in named through a module,
  is "no member `List` in module `lib`" as an expression and as a type.
  As an expression it reached the built-in, and as a type it was "not
  public". One lookup, `SemContext.moduleMember`, serves every pass.
- **A method makes the instances it names where it is reached:** a
  generic type's method that names a deeper instance of its type
  (`$name(Wrap[T?])` in `Wrap[T]`'s method) makes it only where the
  program reaches the method, and that instance's methods only where
  they are reached, so it is no longer "ever deeper instances". A
  method that reaches itself on ever deeper instances still is, at the
  call, or where it is declared for a `pub` type. An instance a method
  the program never reaches would make is no longer checked against the
  body's requirements (`Holder[*B]`'s uncalled method making an
  `Opt[*B]`), as Zig compiles no such method.
- **A code lent where a view of a union with fields goes:** an error of
  a set without fields, `B.y` or a binding of one, is lent where a `?L`
  of `error L = A | B` with fields goes, or a `?error`, as the error
  value of the code, a constant (`code(B.y)` was "bind it first"). An
  error with fields where a `?error` goes is told to bind it first, as
  where a `?L` goes, moving a place that moves (`k: error = <a`); it was
  told to write `?a`, which is rejected too.
- **API objects crossing tasks (Stage 5, the proof):** formal/ proves,
  in Lean, that erasing a type keeps what a crossing check reads: an
  object holds what its hidden value holds, so a value that may not
  cross before erasure may not cross after (`crosses_erase`); an object
  whose bound was checked at erasure holds nothing that stays on one
  thread and no task, so a free task may take it (`erase_sends`); one
  naming no bound goes to no task (`bare_no_spawn`); and after a spawn
  of an erased value, two tasks holding one value that stays on one
  thread are still pinned to one core (`erase_confined`).

- **API objects (Stage 4, the proof):** formal/ proves, in Lean, that
  erasing a type keeps its loans: the checker's rule for an access to an
  owner reads only each name's loans, so an object's type, rebuilt from
  its kind and loans alone, gets the verdicts the erased type got
  (`allows_erase`); an object's value carries a live loan on each owner
  its type names (`erase_live`); and a λRig program with API objects,
  reached only by calls checked against their APIs' clauses, runs
  without a fault (`erased_runs`), while a program without erasure
  checks as before (`checkE_lift`).

- **Shared and weak API objects (APIs Stage 5, phase 2):** `*{Shape}`
  is a counted handle to a value of some type that provides `Shape`, and
  `~{Shape}` its weak handle. A `*Square` moves into a `*{Shape}` and
  keeps its allocation (`<h`, `+h`, and `*Square(...)` or `*<sq`
  written where one goes), and a frozen value's handle only into a
  `*{Shape + Syncs}`, which counts atomically, goes to any task, names
  no `Owned`, and has no weak handle; neither becomes the other, and a
  handle is erased only as it moves or counts, never through a view.
  It only reads: a call through it reaches `?@` methods, `?s` lends the
  `?{Shape}` it holds, `+s` adds a count, and the last count's drop
  drops the value through the table, a long chain without deep
  recursion. `~s` makes a `~{Shape}`, `*w` gives a `*{Shape}?`, and both
  carry the loans of what they hold until the last count is dropped. A
  frozen value may hold `*{A + Syncs}` handles, so a
  `*Frozen[List[*{Plugin + Syncs}]]` is a registry many tasks read. An
  API's table gains three entries, the weak count's, and its function
  a holding, `__rig_table_Shape_of(T, W, .counted)`. A Cell of an API
  object is rejected for good, no longer as not built. The reference
  checker gains the kinds of both forms.
- **One reason for an API object that may hold a loan:** an owned
  closure's capture, a channel's values, a generic body's Cell, Signal,
  or owned closure, and an `Owned` bound name the object and its fix ("a
  `*{Shape}` may hold one: write `*{Shape + Owned}`"), where a channel
  called a `*{Shape}` one that "may hold a view" and an instance said
  "a view keeps what it views lent" of a `^{Shape}`.
- **`I.Item` of any iterator:** a generic body bounded by `Iter` that
  names `I.Item` compiles for an iterator whose item's optional holds
  its none in the item (an object with a `Bool` or enum field, or one
  that names its none); it failed in Zig.
- **A fallible result erases its value:** a function returning
  `(^{Shape})!`, `(*{Shape})!`, or `(?{Shape})!` erases its last
  expression, `return`'s operand, and `f()!` into the object, as a
  binding of the object's type does (`^Square(...)` was "type mismatch:
  expected `^{Shape}!`"), by the erasure's own rules.
- **One rule for a value hidden from a task's waiting:** an erasure to
  an API object, a value given out of `task.isolate`, and an owned
  closure's capture check that it holds no task by one function, for
  its known type and for each instance's `T`. A generic owned closure
  over a `T` made with a `Task[Int]` is refused by the task rule
  ("captures a value that holds a `T` in an owned closure, which would
  hide a task"), no longer by the loan rule.
- **Frozen values:** `Frozen[T]` is no type argument, inferred as well
  as written, so a `*Frozen[T]` given where a generic `*T` goes is
  rejected toward a `T` (it failed in Zig); and the last handle of a
  long chain of frozen values, or of `*{A + Syncs}` objects, drops it
  through the queue a `*T`'s chain takes, not by deep recursion.
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

- **An API object prints as the value it hides:** `print(b)` of a
  `^{Shape + Print}`, `?{Shape + Print}`, or `*{Shape + Print}` hiding
  a String writes its text as is, as `print` of the String does, and
  quotes it only inside a List or a field; the table's print entry
  takes `print`'s `top` flag, as a box passes it on.
- **A generic `?T` of an error with fields:** `show(a)` for a
  `sub show[T](x: ?T)` and `a` of an error set with a member with
  fields, or `A?` of one, checked and then failed in Zig: sema lent it
  as a copy, and the runtime's `ReadView`, which a generic body's
  parameter is, held its `rig.ErrorValue` by address. Sema now lends
  every error that is a `rig.ErrorValue` by address
  (`sema.isErrorValueForm`, the one test emit asks too), the rule the
  runtime applies.

- **`.len` of a List behind a shared handle is an `Int`:** `0..f.len`,
  `n = f.len`, and `f.is_empty()` of a `*Frozen[List[T]]` or a
  `*List[T]` passed the check and then failed in Zig. One classifier
  (`hasLenReached`) now says a length is read through handles and
  boxes alike.

- **`[T: Clone]` clones:** `+x` of a `T`, a `?T`, or a `T?` in a
  generic body asked for `Copy` ("`T` is bounded by `Clone`, which does
  not give a value that copies"), though `Clone` is the bound that
  gives `+x`; a `|+x|` capture too. It now clones as each instance
  does (`rig.cloneAs`), a body without bounds is checked at each
  instance (`Requirement.clones`), and an instance that does not
  clone, a type with a `drop` body or a unique one, is rejected there.
- **`if ?o as v` of a `?T?` in a generic body views the `T`:** under
  any bound, `if ?o as v` and `while ?o as v` asked for `Copy`; the `T`
  is now read where it stands, as a `for` reads an element of a
  `?List[T]`, the optional stays lent while `v` lives, and only taking
  `v` out needs a `T` that copies at each instance.
- **A loop over a slice of a `T` reads its elements in place:** in a
  generic body, `for s in xs` and `for s in ?xs` of a `[]T` (or an
  array of `T`) asked for `Copy` under any bound, where a loop over a
  `?List[T]` did not; both now read each element where it stands, and
  only taking one out needs a `T` that copies at each instance.
- **Inference sees through a box or a handle lent as a view:**
  `first(?bx)` of a `^List[P]` for `first[T](xs: ?List[T])` was a type
  mismatch, and `f(?fz)` of a `*Frozen[Square]` for `f[T: Shape](s: ?T)`
  bound `T` to the handle, which provides no `Shape`; each now binds the
  value the lend reaches, as `first[P](?bx)` and `f[Square](?fz)` did.
- **A box or a handle of an object that holds no loan views nothing:**
  an API's method giving `^{Job + Owned}` or `*{Job + Syncs}` had to say
  `from @`, as if the object could view what it was passed; the view
  targets of a type now stop at a box or a handle whose braces say it
  holds no loan (`sema.heldObjectOwned`, which `objectUnowned` asks
  too), and such a result takes no `from`.

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
  is what the loop gives. A body that holds an item past a change of
  its iterator is rejected at each instance whose items may view memory
  the iterator owns.

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
- **`os.memory()`:** what the program's allocations come to: `live`
  bytes, the `peak`, and how many `allocs` it has made, for reports
  such as "Memory used". The release allocator counts on each thread's
  heap and adds to atomic totals every 64 KiB or 1,024 blocks, so its
  fast paths gain no atomic operation (Trig 0.5-0.8% slower on pup,
  within noise on the Mac). Only a program that names `os.memory`
  counts: any other compiles to the allocator without the counts.
- **`time.since_start()`:** the nanoseconds on the monotonic clock
  since the program started, an `Int`, so a plain function value reads
  a duration with no `Instant` to hold (virtual in a deterministic run).
  Only a program that names it reads the clock as it starts, so any
  other's code is what it would be without it (std.json's safe builds
  on the Mac had moved 4-7% slower with the reading, their hot
  functions 60 bytes later).
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
- **Map trace:** a program built with `RIG_MAP_TRACE=1` records every
  operation on a built-in Map or Set, 48 bytes each, in
  `$RIG_MAP_TRACE_FILE` (default `rig-map-trace.bin`), with each Map's
  key and value types beside it; `tools/map-trace.py` summarizes a
  trace. A build without the flag is unchanged.
- **Map and Set:** a key of 8 bytes or fewer keeps no stored hash, so
  such a Map takes 8 bytes an entry fewer; Trig's ts-pattern peaks at
  403 MB rather than 425.
- **The scheduler's spin lock waits by reading:** a thread waiting for
  it reads until it looks free before trying to take it, so waiters do
  not fight over its line, and the blocking pool reads the clock before
  taking its lock rather than under it. A walk of a large tree with
  loco spent 62% of a worker's time spinning there; in a copy so
  patched its user time fell from 14.9 s to 1.4 s at the same wall time.
- **Release allocator:** on Linux, the heap that does the program's
  work faults in ahead the memory it is about to fill: one that has
  taken from the system at least four times what every other heap has
  together. A thread beside it that takes little, as the blocking pool's
  reading a file, no longer turns faulting ahead off, and a program of
  several busy threads still faults lazily. Trig's ts-pattern at one
  checker on pup takes 37.8K page faults rather than 81.0K and runs 2 to
  3% faster (zod3 4 to 7%), for 4 to 6% more peak memory: ts-pattern
  peaks at 342 MB rather than 328, since memory faulted in ahead is
  resident before it is filled. At four checkers both are unchanged.
- **Release allocator:** on Linux, a heap that has taken from the
  system two segments' worth (8 MB) faults in ahead too, beside others
  as large: each of several parallel checkers does, while a server's or
  a task program's workers, each within one segment, fault lazily.
  Trig on pup at four checkers takes 51.4K page faults on ts-pattern
  rather than 91.4K (zod3 20.0K rather than 30.8K), for 5 to 6% more
  peak memory: ts-pattern peaks at 402 MB rather than 383, zod3 at 150
  rather than 142. zod3 runs 4 to 6% faster; ts-pattern's time is
  unchanged. The task, actor, net and http benches are unchanged.
- **Release allocator:** a small block of up to 1 KiB, aligned to 8 or
  less, is taken and given back with no call: 23 instructions to
  allocate and 26 to free on x86-64, where each took about 50. Trig checks ts-pattern
  at one checker with 1.8% fewer instructions (zod3 2.0%); its time
  moves within the run-to-run spread.
- **Release allocator:** a large block that grows moves into a kept
  block that fits, copying it into pages already resident, and keeps
  the block it left; one no kept block fits grows on Linux by moving
  its pages (`mremap`) from 64 KiB, where it did from 1 MiB, so it
  leaves no old block resident. Growing by `mremap` had taken fresh
  pages for every table while the heap gave back the resident ones it
  kept. On pup, bench/hash's 100,000-key inserts run 7 to 30% faster
  under the Zig table and 7 to 22% for the built-in Map, and every row
  1.7% faster (geometric mean), the 3M and 4M rows unchanged; Trig's
  peak memory is 2.8% lower on ts-pattern and 2.9% on zod3, its time
  and instructions unchanged. The Mac is unchanged.
- **Release allocator:** a freed block over 32 KiB serves any later
  request it fits, the smallest kept block that does, with the rest kept
  apart, where it served only a request of its own size; and a heap
  keeps freed blocks while what it holds in large blocks, handed out and
  kept, is no more than the most it has handed out at once and 16 MiB,
  where it kept 16 MiB. bench/hash's big-value inserts on pup run 17 to
  65% faster (1.36 times malloc's time, from 1.76), on the Mac 9 to
  46%. Trig's peak memory is 1.0 to 3.0% lower on ts-pattern and zod3,
  its instructions and time unchanged. Huge pages for blocks of 2 MiB
  or more were measured and left out: they raised ts-pattern's peak
  memory by 1.3 to 2.0%.
- **Release allocator:** on Linux, a large block of 16 MiB or more
  that a heap maps afresh, or that `mremap` grows to that size, is
  aligned to 2 MiB and asks for transparent huge pages
  (`MADV_HUGEPAGE`); smaller blocks and blocks reused from those a heap
  keeps are left as they are. On pup, bench/hash's 3M and 4M-key rows
  run 11% faster and its big-value inserts 10% faster (`big1000000`
  36%). Trig's peak memory on ts-pattern is 0.4% higher at one checker
  (296.2 MB against 295.0) and the same at four, zod3's the same; its
  time and instructions are unchanged. Other systems are unchanged.
- **Release allocator:** on Linux, a heap that faults in ahead (one
  that leads the heaps or has taken two segments) asks for transparent
  huge pages for each new segment (`MADV_HUGEPAGE`); other heaps keep
  small pages. Trig on pup runs 1.7 to 3.2% faster at one checker and
  2.9 to 4.6% at four, with 22 to 36% fewer dTLB misses and its
  instructions unchanged; its peak memory is 0.1 to 0.7% higher on
  ts-pattern and 1.5 to 2.0% on zod3. Other systems are unchanged.
- **Release runtime:** on Linux, a reserved Table past its first 2 MiB,
  a heap's new segment, and a new large block of 16 MiB or more ask for
  transparent huge pages only while `/proc/buddyinfo` shows more than
  128 free blocks of 2 MiB or more. Under the default `defrag` setting,
  a fault in a range that asked compacts memory when no free 2 MiB
  block is left: on pup with its memory fragmented, Trig ran 34 to 41%
  slower than with no huge pages, the Tables' requests the most and the
  segments' as surely. With the test, Trig on pup is 4.6% faster than
  with no huge pages on ts-pattern (main 5.4%) and 3.0% on zod3 (main
  4.0%) when memory is free, and within 0.4% of no huge pages when it
  is fragmented, where main is 54 to 57% slower. Other systems are
  unchanged.
- **Release runtime:** on Linux, the test for huge pages asks while
  more than 64 free 2 MiB blocks are left, where it asked for more than
  128. pup idles at about 90 to 140, where 128 shut the test for most
  of Trig's runs, as a run's own huge pages drain the count: there Trig
  on pup is 5.8% faster on ts-pattern and 1.9% on zod3. When memory is
  free it is within 1.4% of 128, and with memory partly fragmented (35
  to 65 free) it asks for none and runs as with no huge pages, where
  spares of 32 and 16 stalled in compaction. Peak memory is unchanged.
- **Release runtime:** on Linux, a heap's new segment and a new large
  block of 16 MiB or more ask for huge pages while free 2 MiB blocks
  number what they need and 8 more, where they waited for more than 64;
  a reserved Table keeps the spare of 64. A segment or block asks just
  before its pages fault, so the count is current, where a Table asks
  once for a reservation it grows into all run. With 12 to 17 free
  blocks on pup, Trig runs zod3 2.6% faster and its small projects 3.2
  to 5.4%, ts-pattern 0.8%; with 35 free, ts-pattern 2.1% and zod3 3.0%.
  No compaction stall, peak memory up to 2 MB higher; with memory free
  it runs as before.
- **Release runtime:** on Linux, reserved Tables take ranges of whole
  huge pages from regions of 256 GiB, each mapped and advised for small
  pages once, where each Table mapped, advised, and trimmed its own; a
  Table dropped gives its pages back (`MADV_DONTNEED`) and its range to
  the next. A reading of `/proc/buddyinfo` answers the huge-page tests
  for 4 ms, so a burst of Tables reads it once; a segment or large block
  asks only on a reading taken then. Trig at four checkers reads the
  file 4 times where it read it 174, and maps 69 times where it mapped
  240: 1.8 to 3.7% fewer instructions on its small projects, and with
  its checkers made in tasks 1.6 to 4.5% less time. Peak memory is
  unchanged; debug builds map each Table on their own, as before.
- **Release allocator:** a heap keeps freed large blocks within its
  settled peak, the most it has had handed out just after a free, and
  16 MiB, where the peak was the most handed out at any moment. That
  counted a growth's new block, mostly untouched, beside the old one,
  so a table that grew left the block it grew from resident:
  bench/hash's 4M-key map takes 39.5 bytes an entry on the Mac, from
  51.0 (39.7 before the bound). Tables built and dropped again and
  again still take their pages from what the heap kept, and bench/hash
  runs at its speed (all rows within 0.3%). Trig's time, instructions
  and peak memory are unchanged.
- **Release allocator:** a heap that does not fault in ahead, as a
  server's worker's, keeps 1 MiB of the large blocks it frees resident.
  Past that, it gives the pages of each block after its first back to
  the system (`MADV_DONTNEED` on Linux, `MADV_FREE_REUSABLE` on macOS)
  and keeps the block by address for its next request. A server's
  workers free blocks that other workers made, so what each kept grew
  toward 16 MiB. On pup's 22 workers, kv with 64 KiB values peaks at
  34% less memory (34-40 MB rather than 56-61) for 1.1-1.5% fewer
  requests a second by the median of 50 interleaved pairs (3.3-4.2% by
  the geometric mean), a trade the owner accepted; mimalloc-bench's
  xmalloc-test peaks at 71% less (80 MB rather than 275) at its speed,
  and sh8bench is level. A heap that does the program's work, as each
  of Trig's checkers', is unchanged: Trig's time and peak memory, and
  the task, actor, net and http benches, are as before.

- **Map and Set growth:** a table that grows is made anew with its
  free slots written at once, where it pushed them one at a time: Trig
  checks ts-pattern and zod3 with 1.5% fewer instructions and 1.6% fewer
  cycles.
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
- **Deadlock reports under load:** a deadlock found in an actor's method
  run inline is reported as the deadlock. A caller of the actor it ends,
  panicking at that end on another worker, could be reported in its
  place. A call that waits into a cycle it is not on names that cycle;
  its report failed with an index out of bounds in the runtime.
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
- **Frame pointers:** release builds (`--release`, `--release=fast`)
  omit them, which frees a register in every function: Trig checks
  ts-pattern and zod3 on an x86 core with 2.5-2.9% fewer instructions
  and 1-2% faster. Debug builds keep them. A profiler that walks them
  (`perf record -g`, macOS's `sample`) sees no callers in a release
  build unless `RIG_FRAME_POINTERS=1` was set when it was built.
- **Split builds:** a large program's debug build (`rig build`, `run`,
  `test`) compiles as several units at once, each a `zig build-obj` on
  its own core, linked into one executable, when Zig builds it with
  LLVM (every target but x86-64) and its own modules hold at least 18k
  lines: one unit for each 9k lines, up to the cores. Trig's debug build
  on the Mac goes from 291 s of Zig to 30 s, its output the same.
  `--units=N` sets the count, for a release build too (which then runs
  slower, its calls between units not inlined), and `--units=1` never
  splits.
- **Stack canaries:** release builds leave out the canaries Zig adds
  wherever libc is linked (every macOS program; on Linux, a program
  that declares an `extern`). Safe Rig checks or proves every index, so
  a canary guards only `raw` code and the runtime's Zig. Trig on the
  Mac checks with 6.2-7.0% fewer instructions and 2.5-4.5% fewer
  cycles. Debug builds keep them; `RIG_STACK_PROTECTOR=1` keeps them in
  a release build.
- **BOLT:** `rig build --release --bolt -- WORKLOAD` lays the
  executable out again with LLVM's BOLT, by a `perf` profile of the
  workload (Linux), and `--bolt-profile=FILE` keeps that profile or
  lays a later build out by it.
- **PGO:** `rig build --release --pgo -- WORKLOAD` optimizes the
  executable by LLVM's profile-guided optimization, trained on the
  workload: Zig's bitcode of the program is compiled by `zig cc` with
  LLVM's counters, the workload runs it, and the same bitcode is
  compiled again by the merged profile and linked by Zig (Linux, a
  program that links no C library, with `llvm-profdata` and the profile
  runtime of Zig's LLVM). `--pgo-profile=FILE` keeps the profile or
  builds by it; a profile of an older program is used for the functions
  that did not change, and the build says how many did. Trig checks
  ts-pattern 10% faster with 14% fewer instructions, trained on zod3,
  and 5-9% faster than with BOLT alone. A build without `--pgo` is
  unchanged.
- **Compiler and tools:** a synthetic span outside its source reads as
  empty; the package cache and the build store have size caps;
  `src/parser.zig` is generated at build time from `rig.grammar`
  with Nexus, which is co-developed with Rig; and `tools/migrate-0.3.py`
  migrates 0.2 programs, each rename an independent pass (box, list,
  string, `obj`, builtin, label, self, `const`), in `.rig` files, test
  files' cases, and Markdown's `rig` blocks, with `--dry-run` to print
  the diff. Of the 4,836 programs `v0.2.9` accepts, `main` accepts
  1,094 as written and 3,495 after the guide's scripts.
- **Rig's own repository:** `tools/heavy`, `test/rig.rip`,
  `test/matrix.py`, `tools/equiv.py`, and `tools/zig-next.py` find their
  git directory through `tools/gitdir`, which takes only a repository
  whose top level is Rig's. From a plain copy of Rig they stop with a
  message naming `GIT_DIR`, rather than keep a lock or a build store in
  a repository that encloses the copy.
- **`tools/emit-diff BASE`** says whether `bin/rig` emits the same Zig
  as a `rig` built at `BASE` for the examples, the benches, every std
  module, and Trig; a change whose emit is identical skips its timing
  round. **`tools/baseline SHA`** prints the path of a `rig` built at a
  commit, built once and cached in the git directory.

### `std.json` (experimental)

A one-pass, validating JSON parser in
safe Rig (`std/json.rig`) that builds a tape, with a tiered string
scan (SWAR, then `Simd[U8, 16]`). `bench/json/check/compare.py`
checks it against Python's `json` module on 10,511 inputs;
`tools/fetch-json-data.sh` fetches the third-party files those read. `bench/json/` times it
against Zig's `std.json`, serde_json, simd-json, sonic-rs and
zimdjson (docs/history/records/2026-10/json/json-results.md). Its API is not settled
(docs/design/json.md, "Open items").

std.json: an escaped string checks its length once, so safe builds keep
#538's gain on x86 (pup's safe builds are back within 2% of the earlier
reference on every file). Canada runs 2.4-2.8% (pup) and up to 4% (Mac
safe) slower than before, which is layout and is noted, not fixed.

### Concurrency

The model and its plan are
[docs/design/concurrency.md](docs/design/concurrency.md), with its reviews in
[docs/history/records/2026-10/concurrency-panel/](docs/history/records/2026-10/concurrency-panel/README.md). The plan's
first step is on `main` (SPEC §18):

- **A function returns a task with read loans only, as any result.**
  `fun start(v: ?List[Int]) -> Task[Int] from v` then `total(v)&` is
  accepted, and the caller keeps `v` lent to read until it waits; so
  is a task returned in a `Tasks` set, an object, an optional, a
  fallible result, through a generic, and a task made of a returned
  task. A task's type may hold a view of anything, as the ownership
  checker always kept every loan of a task's call, so the signature's
  origins and the `from` check agree with it. A task lent to write is
  still only bound and waited for: no `return`, last value, or
  `break` takes it, and the reference ownership checker gives a
  task the loans of its call too.
- **A panic stops where a runtime panic does.** `panic(...)` in an
  actor's method ends the actor and stops at its runner, or at the
  caller's isolate, as an index out of range does. A method run inline
  on a task under an isolate ends that task, which its isolate then
  stops. A call made with `&` gives its mailbox slot back when it is
  answered, so a supervised actor whose methods panic keeps its slots.
  A send on a closed channel, and a close with senders waiting, panic
  in the sender's own task with the channel unlocked, so an isolate
  that stops the panic leaves the channel working. A supervised actor
  whose value panics as it is made again answers the call it took,
  which panics in its caller rather than wait for ever.
- **A task's frames outlive its panic while its tasks read them.** A
  task under an isolate that panics leaves its stack to the isolate,
  which gives it back only once every task under it has ended, so a
  task it lent its frames to (`sum(?d)&`) never reads a stack another
  task reuses. A build that sanitizes (`RIG_SANITIZE=1`) returns each
  stack to the system as its task ends, so a late write into one
  faults.
- **Every wait sleeps.** Tasks that share a listener each wait for a
  connection of their own: a second waiter no longer took the first's
  place, which then missed its wakeup and spun at its deadline. A call
  made with `&` waiting for a mailbox slot, and an isolate waiting for
  its tasks after a panic, sleep until woken rather than spin on a
  yield, so neither burns a core, and a deterministic run (`rig test`)
  reaches the timers that end them.
- **`http.serve` registers each connection as it accepts it**, with
  the acceptor's poller, as a server's own accept loop does, rather
  than in the connection's task: on the Mac, under bench/http's load of
  64 connections, 2.6% more requests a second and a 99th percentile
  latency 8% lower (543 µs, from 591).
- **Tasks waiting on one socket each see every edge that comes after
  their own call**, even when another task, woken by the same edge, runs
  first and takes what came: an acceptor no longer sleeps with a
  connection queued.
- **A yield wakes a sleeping worker only when other work waits behind
  it**, so a lone task calling `task.check()` a million times no longer
  wakes one on each call (0.05 s to 0.02 s with ten workers, and no
  system time), and closing a socket kicks the poller only when a
  worker sleeps in it. In a deterministic run (`rig test --seeds`),
  every loop's yield check wakes the timers the virtual clock has
  reached, so a seeded run's interleavings, and output that depends on
  them, may differ from before.
- **`http.serve` and a `Tasks[Void]` set find their ended tasks at once**,
  from the list those tasks join as they end, rather than looking at
  every task alive on each accept or `add`. Such a set allocates that
  list's record at its first `add`.
- **Smaller fixes:** `time.within` inside a deadline of `Int.max` no
  longer overflows in a safe build; a socket the poller refused fails
  its wait with `NetError.failed` rather than block its worker, as a
  failed `poll` does; and a poller that cannot be made panics naming
  the call and its error, not as out of memory.
- **A `print` method no longer hangs a program with tasks.** `print`
  and `warn` held the output lock while a value's own `print` method
  ran, so a method that printed, warned, wrote `io.stdout()`, or called
  `os.exit` hung its task, and one that looped past a yield could hang
  every task that printed (always under `rig test --seeds`). A line
  whose value may run a `print` method is rendered first, with no lock
  held, and copied out under it; what the method prints comes before
  the line, whole, with or without tasks. `warn`, and an error's report
  as it leaves `main`, are rendered the same way, so a `warn` of any
  length is one write. `String(...)` writes each piece once, so a
  `print` method of a value in text over 256 bytes runs once, not
  twice.
- **A shared Cell's `add` that overflows stores nothing.** In a program
  that makes tasks, `!c.add(n)` and `!c.sub(n)` on a `*Cell[Int]`
  stored the wrapped value before they panicked, so an isolate that
  stopped the panic left it there; they panic first, as `+` does.
- **A regular file's read runs in its task.** `file.read` of a regular
  file, and `exists`, `stat`, `realpath`, and `read_dir`, run on the
  task's own worker, not the blocking pool, as Go's and tsrs's do; a
  read of a FIFO or a device, every open of a `File`, and every write,
  rename, `mkdir`, and removal stay on the pool, with their cancel and
  SIGTERM behavior. The read opens only what the path's stat says is a
  regular file, with O_NONBLOCK, and reads it only if the descriptor's
  stat agrees, so no FIFO is opened twice. On pup, Trig 1.0 to 3.9%
  faster at one checker and 4.9 to 6.4% at four; loco 10.8 to 28.5%
  faster; instructions, user time, and peak memory level.
- **A call on the blocking pool no longer spins its core away.** The
  waiter of a file call (`realpath`, `stat`, `read`) spins 64 times while
  the call's thread finishes, then yields its thread. Pinned to one
  core, it spun until the kernel preempted it, about 2.4 ms of every
  Trig run: 37% of its gap to tsrs on a small project.
- **A file's call on the blocking pool takes no lock.** `File.read`,
  `write`, and `sync` move a duplicate of the file's descriptor, and a
  read the caller's String, into the pool's call by value, which gives
  them back with its answer; a call its task stopped waiting for drops
  them as it ends, and one that never started gives them back at once. The
  process-wide table of lent descriptors, and its lock, are gone, and
  without the scheduler a call takes the file's own descriptor, with no
  duplicate. `io.copy` lends each file once and moves one buffer through
  every block, with no allocation or copy for each: copying 256 MiB from
  file to file four times takes 0.21 s on an M-series Mac, against
  0.26 s before (19% faster), and 0.41 s against 0.63 s in a task (35%
  faster). Reading 32 MiB 4 KiB at a time and writing 200,000 lines of
  64 bytes takes 0.27 s against 0.32 s (16% faster), and 1.61 s
  against 1.79 s in a task (10% faster). A stoppable blocking call's
  arguments are checked at every depth: any pointer but a `[]const u8`,
  which is copied, does not compile.
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
- **Workers with state:** `par.workers(!states, ?items, |s, x| ...)`
  runs one task for each state, which it holds to write, and each task
  takes the next item, in the caller's order, until none is left; the
  values come back in the order of the items, whichever task made each
  (`typecheck.parWorkers`, `tasks.parWorkers`). A caller that puts the
  heavy items first balances an uneven load, as a checker per task does.
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
- **A server's memory no longer grows with workers times
  connections:** a `net.Stream` read into a String without room for
  `max` more reads through the worker's block and keeps only the bytes
  that came, so a task waiting for bytes holds no buffer, and a String
  freed on another worker is a small block, not a 24 KiB one. Each
  thread's alternate signal stack is a mapping of the runtime's,
  untouched until a signal runs on it, not Zig's 256 KiB thread-local
  array, which every worker and blocking-pool thread kept resident; a
  task that blocks on another task or an actor touches one stack page,
  its deadlock walk in a frame of its own (`sched.walkFrom`); and a new
  reservation's stacks hold no page until used. A task-per-connection
  key-value server (Redis's protocol, an actor for the store) under
  load holds 6.4 to 6.8 MB at 50 connections on the Mac, was 16.5 to
  19.4, and 24 to 26 MB at 1,000, was 89 to 148; on pup, with 22
  workers, 5.0 MB at 50, was 14.5, and 10.6 MB at 1,000, was 128 to
  137. The same server in Tokio holds 5.6 to 5.7 MB and 25 MB on the
  Mac, 5.9 and 21 MB on pup.
- **Reads grow a String unfilled:** std.file's reads, std.http's
  strings, and net's reads grow a String through the runtime's raw
  growth, as every String append does, so a safe build writes no 0xAA
  over the room a read makes, and a socket read without tasks reserves
  exactly `max`, 16 KiB for a read of 16 KiB where it took 28. A read
  of 64 MiB that five bytes fill holds no pages for the rest.
- **A stream sends each write at once:** every accepted and connected
  `net.Stream` sets `TCP_NODELAY`, so a request written in pieces, or
  pipelined behind one not yet answered, no longer waits for the other
  end's delayed acknowledgment, about 40 ms on Linux. `!s.batch(true)`
  lets the system hold small writes and send them together again.
- **A stream splits in two:** `r, w = <s.split()` gives a `net.Reader`
  and a `net.Writer`, which two tasks own: one reads while the other
  writes, on one connection. `<w.close()`, or the writer's drop, ends
  this side's writing (a half-close), and the other end reads the end
  while the reader still reads; the connection closes once both halves
  are gone.
- **An end wakes only the waits it ends:** the poller marks the end of
  reading as readiness to read and the end of writing as readiness to
  write, where any end once woke every wait on the descriptor for good.
  A reader no longer spins after its own side half-closes (kqueue's
  write filter reports it), nor a writer on a full buffer after the
  other end does.
- **Each worker on cache lines of its own:** no line holds two
  workers' fields (`sched.Worker`), so a yield takes about 5 ns on the
  Mac and 22 on pup's two hyperthreads, 45% and 12% less (bench/tasks).
- **Fewer yield checks, the same bound:** a recursive check sits only
  in the functions that cut every cycle of calls, a feedback vertex set
  the compiler picks once (`inlining.Pass.cutCycles`), and a loop counts
  a turn as the next one begins, so a turn that leaves the loop counts
  nothing. A task that recurses still checks on every turn of any cycle.
  Trig's checker keeps 387 of its 2,812 recursive checks; on ts-pattern
  with one checker it runs 5% fewer instructions and 2% faster (pup).
- **A yield check costs no registers:** in an optimized build for
  x86_64 or aarch64, a loop's turn check and a recursive function's
  entry check call the scheduler through a function that saves and
  restores every register a call may change (`rig.callKeeping`), so the
  code around a check no longer keeps its values in registers a call
  preserves for the sake of a call it rarely makes. The call may still
  read and write any memory. Trig built with `--pgo` runs 0.8-0.9%
  fewer instructions on ts-pattern and zod3 (1.9% in a plain release
  build), in about the same time
  ([records](docs/history/records/2026-10/perf-stage/loop-hoist.md)).
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
