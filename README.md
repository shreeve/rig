# Rig

Rig is a compiled systems language with ownership like Rust's, fewer
rules, and no garbage collector. How a value is moved, lent, shared,
failed, or run at the same time is written as a one-character sigil
where it happens, and the compiler checks every one. Rig compiles to
[Zig](https://ziglang.org) 0.17, which optimizes, generates code, and
links.

```rig
fun total(xs: ?List[Int]) -> Int
  xs.sum()

fun sq(x: Int) -> Int
  x * x

sub main()
  xs = List([3, 4])
  t = sq(5)&
  u = total(?xs)&
  print(>t, >u)
```

```output
25 7
```

`&` after a call runs it as a task, and `>t` waits for it and takes its
result. `?xs` lends `xs` to read. There is no `async`, no `await`, and
no executor to set up: `total` and `sq` are ordinary functions, and any
function can run as a task. The task reads the list in place, with no
copy and no reference count, and the compiler keeps the loan until `>u`.
So this is rejected:

```rig reject
fun total(xs: ?List[Int]) -> Int
  xs.sum()

sub main()
  xs = List([3, 4])
  u = total(?xs)&
  !xs.push(1)
  print(>u)
```

```error
cannot lend `xs` to write while a read loan is live
```

That is the rule Rig applies to every view, not a special rule for
tasks. Each idea here has a precedent, in Rust's ownership, Go's waiting
without `async`, and Erlang's actors. Rig holds them all at once, in a
handful of sigils:

- **Effects are visible.** Every move, clone, write, failure path, and
  task is marked on the line where it happens. Reading is unmarked.
- **Memory safety without a collector.** The ownership checker rules out
  use after move, double free, dangling views, and leaks in safe code.
  Every value is freed at a point you can see.
- **Concurrency without async.** No function is colored. A task never
  outlives its owner, an actor takes the place of a lock, a deadlock
  panics with the calls that formed it, and a test replays the same
  schedule from a seed.
- **Zig's cost model.** The output is plain Zig. Starting and switching
  tasks costs less than in Tokio or Go, and the HTTP server answers
  about as many requests as hyper on a Mac, and more on Linux
  ([Performance](#performance)).

Every `rig` example in this README is checked by the test suite, and
each one shown with its output runs and prints exactly that.

## Contents

- [The central idea](#the-central-idea)
- [Ownership without a garbage collector](#ownership-without-a-garbage-collector)
- [Errors and optionals](#errors-and-optionals)
- [Concurrency](#concurrency)
- [The rest of the language](#the-rest-of-the-language)
- [The standard library](#the-standard-library)
- [What the compiler guarantees](#what-the-compiler-guarantees)
- [Performance](#performance)
- [Status](#status)
- [Install](#install)
- [Build and run](#build-and-run)
- [Where to go next](#where-to-go-next)

## The central idea

**Sigils are the language's mechanics; words are its libraries.** How
data is bound, taken, lent, held, failed, and run at the same time is a
one-character sigil, and a sigil means the same thing wherever it
appears:

| Mechanic | Sigils |
|---|---|
| Binding | `x = e` binds, `x =! e` binds for good |
| Taking and copying | `<x` moves (alone on a line, drops), `+x` copies or makes another handle |
| Lending | `?x` lends to read, `!x` to write; as types, `?T` and `!T` |
| Holding | `*x` shared (`*w` upgrades a weak handle), `^x` boxed, `~x` weak, `@` self |
| Failure and absence | `T?` may be absent, `T!` may fail; `e?` and `e!` pass them on |
| Concurrency | `f(x)&` sends work off, `>t` takes its result back |

What a library chooses stays a word: canceling a task is
`<t.cancel()`, and waiting for the first of several is
`<ts.wait_first()`.

`?` and `!` carry one idea each, in four positions:

| | before a value | before a type | after a type | after an expression |
|---|---|---|---|---|
| `?` "maybe, just look" | `?x` lend to read | `?T` read view | `T?` optional | `e?` pass `none` up |
| `!` "for real, act" | `!x` lend to write | `!T` write view | `T!` can fail | `e!` pass a failure up |

`!` means "act": write, or fail, as in Ruby's `sort!`. Rig spells
negation `not`, so `!` never means "not".

A sigil is a prefix where an operand starts, so `a < b` is still a
comparison. [docs/QUICK.md](docs/QUICK.md) puts every sigil on one
page, and [docs/DESIGN.md](docs/DESIGN.md) shows their algebra.

## Ownership without a garbage collector

Rig's ownership model is Rust's with two differences: every transfer
is written, and there is no lifetime syntax, since the checker follows
where each view came from. The whole model fits on one page,
[docs/CORE.md](docs/CORE.md), in three words: *you lend a view; the
compiler remembers the loan.*

```rig
obj File
  name: ?String
  lines: Int

  sub write(!@, n: Int)
    @lines += n

  drop(!@)
    print("closing", @name, "after", @lines, "lines")

fun size(f: ?File) -> Int
  f.lines

sub archive(f: File)
  print("archiving", f.name)

sub main()
  log = File(name: "log.txt", lines: 0)
  !log.write(3)
  print(size(?log))
  archive(<log)
  cfg = *File(name: "cfg.toml", lines: 2)
  cfg2 = +cfg
  <cfg
  print("still open:", cfg2.name)
```

```output
3
archiving log.txt
closing log.txt after 3 lines
still open: cfg.toml
closing cfg.toml after 2 lines
```

- **Lending.** `!log.write(3)` lends `log` to write, and `size(?log)`
  lends it to read. The sigil at the call shows what the call may do to
  your value. Views are checked, never counted, so they cost nothing at
  run time. A value has many readers or one writer at a time, never
  both.
- **Moving.** `<log` moves the file into `archive`, which owns it and
  closes it on return; a later use of `log` is a compile error.
- **Sharing.** `*File(...)` puts a file behind a counted handle, `+cfg`
  makes a second owner, and `<cfg` alone on its line drops the first
  one now. The file closes when `cfg2`, its last owner, goes out of
  scope.

An object is a value: it lives where it is declared, and `^` puts it on
the heap or `*` shares it only when a sigil says so. There are no
finalizers. The one leak the checker does not prevent is a cycle of
strong handles, as in Rust and Swift; a weak handle, `~x`, breaks it,
and a debug build reports the leak.

## Errors and optionals

A `T?` may be `none` and a `T!` may fail. Every call to either says
what happens: `e?` and `e!` pass the absence or failure up, `??` and
`catch` handle it.

```rig
error Stack
  empty

fun peek(v: ?List[Int]) -> Int?
  return none if v.len == 0
  v[v.len - 1]

fun pop(v: !List[Int]) -> Int!
  return Stack.empty if v.len == 0
  (!v).pop() ?? 0

fun next(v: ?List[Int]) -> Int?
  peek(?v)? + 1

fun drain(v: !List[Int]) -> Int!
  pop(!v)! + pop(!v)!

sub main()
  v: List[Int] = List()
  !v.push(1)
  !v.push(2)
  print(next(?v))
  print(drain(!v) catch -1)
  print(next(?v), drain(!v) catch -1)
```

```output
3
3
none -1
```

`peek` lends `v` to read and gives an `Int?`; `next` passes its `none`
up with `?`. `pop` lends `v` to write and gives an `Int!`; `drain`
passes a failure up with `!`, which `catch` turns into `-1`. There are
no exceptions and no hidden control flow.

## Concurrency

Concurrency is the last row of the sigil table, built on the same rules
as the rest. [SPEC §18](SPEC.md#18-tasks) has every rule, and
[docs/launch/post.md](docs/launch/post.md) tells the story.

### Tasks

A task keeps the loans of its arguments until `>t` takes its result,
and it never outlives the scope that owns it: dropping a task that was
not waited for cancels it, if it can fail, and waits for it. There are
no detached tasks and no `'static` bounds. A task's failure arrives
through `>t`, as any failure does: `>t!` passes it on, and `catch`
handles it. For a task that can fail, a cancel (`<t.cancel()`) or a
deadline (`time.within(ns, f)`) arrives as an error at its next waiting
point, with no token to pass down.

The compiler knows, for every type, whether a value may move to another
core or be read from two at once, and decides where each task may run.
A task handed a `*T` handle, whose count is not atomic, runs on the
thread of the task that makes it, so a GUI program's shared state can
use `&` too. `Tasks[T]` holds a set of tasks, `*Chan[T](n)` is a
bounded channel, `task.select` commits exactly one of its arms, and
`par.map` and `par.each` spread a loop over the cores.

### Actors

State that many tasks change lives in an actor, which runs its methods
one at a time, each to its end:

```rig
obj Ledger
  entries: List[Int]

  sub post(!@, n: Int)
    !@entries.push(n)

  fun count(?@) -> Int
    @entries.len

sub work(l: *Actor[Ledger])
  for 0..100
    !l.post(1)

sub main()
  l = *Actor(Ledger(entries: List[Int]()))
  ts = Tasks[Void]()
  for 0..4
    !ts.add(work(+l)&)
  >ts
  print(l.count())
```

```output
400
```

`*Actor(x)` moves the value into the actor; nothing in `Ledger` changes.
A call that finds the actor idle takes it in one atomic step and runs
the method on the caller's own stack, so an uncontended actor costs
about what a lock does. Rig has no `Mutex` type. A one-word `*Cell`,
such as a counter, becomes atomic instructions.

### When it goes wrong

**A deadlock is reported, not suffered.** An actor runs one method at a
time, so a call that comes back to it can never be answered:

```rig
obj Ledger
  n: Int

  sub post(!@, bank: *Actor[Bank])
    @n += bank.balance()

obj Bank
  cash: Int

  fun balance(?@) -> Int
    @cash

  sub pay(!@, me: *Actor[Bank], ledger: *Actor[Ledger])
    !ledger.post(+me)

sub main()
  bank = *Actor(Bank(cash: 100))
  ledger = *Actor(Ledger(n: 0))
  !bank.pay(+bank, +ledger)
```

Every wait records what it waits on, and the wait that closes a cycle
panics with the calls, so the program does not hang:

```text
panic: deadlock: these calls wait on each other, and none can go on: Bank.pay -> Ledger.post -> Bank.balance
```

**A panic stops at a boundary.** `task.isolate(f)` runs `f`, and a panic
in it, or in any task it started, fails the call with
`task.Stop.panicked` while the program goes on. A panic in an actor's
method ends that actor; `*Actor.supervised(make)` starts a fresh value
instead.

### A small server

`std.http` serves HTTP/1.1. Each connection is a task, and each request
runs isolated:

```rig
use std.http
use std.net

fun pick(xs: ?List[Int], i: Int) -> Int
  xs[i]

sub main()!
  hits = *Cell(0)
  l = net.listen("127.0.0.1:8080")!
  http.serve(<l, |+hits, req|
    match req.path
      "/hit" => http.text(String("hits ", (!hits).add(1)))
      "/boom" => http.text(String(pick(List([1, 2, 3]), 7)))
      _ => http.not_found()
  )!
```

The compiler checks that what the closure captures is safe to share
across connections. `/boom` indexes past the end of a list, so it
panics, the request answers 500, and the server goes on. The same
server in Go and in Rust with Tokio and hyper, with what each needs, is
in [docs/launch/examples/](docs/launch/examples/README.md).

### Tests that fail the same way twice

`rig test` runs concurrent code on one thread, with a virtual clock and
a seed that picks which task runs next. Sleeps take no time, and the
same seed gives the same interleaving:

```rig
use std.time

fun slow(ms: Int) -> Int!
  time.sleep(ms * time.MS)!
  ms

test "a deadline stops a slow call"
  r = time.within(5 * time.MS, || slow(60_000)!) catch -1
  r == -1
```

```text
$ rig test deadline.rig
ok    test "a deadline stops a slow call"
1 passed, 0 failed
```

The one-minute sleep finishes at once. `--seeds=20` runs the tests
under twenty schedules, and a failing run prints the seed that replays
it.

## The rest of the language

Generics take no traits or bounds: `fun max[T](a: T, b: T) -> T` is
checked at each instance a program makes, against what the body does
with `T`, the methods it calls on one included, and after a name `[]` is compile time and `()` is run time.
A closure's capture list says how it holds each outer value,
`|+total, ~clicks| ...`. Rig also has objects, enums with payloads and
exhaustive `match`, modules of one file or a directory, SIMD vectors
(`Simd[U8, 16]`), C functions through `extern` and `raw`, `test`
blocks, and a language server, `rig lsp` ([editors/](editors/README.md)).
[WELCOME.md](WELCOME.md) tours them for programmers coming from Rust,
Zig, C, Python, Ruby, JavaScript, or Go.

## The standard library

A program imports a module with `use std.NAME`
([docs/STD.md](docs/STD.md)). Built in, with no import: `print`,
`String`, `List`, `Cell`, `Signal`, `Actor`, `Chan`, and `Tasks`.

| Area | Modules |
|---|---|
| Numbers | `std.math`, `std.bigint` (integers of any size), `std.random` (seedable) |
| System | `std.os` (arguments and environment), `std.file` (files, whole or open, making, moving, and removing them, and what is at a path), `std.io` (copying between files and sockets), `std.time`, `std.target` |
| Concurrency | `std.task` (cancel, wait, isolate, supervise), `std.par` (parallel `map` and `each`) |
| Networking | `std.net` (TCP), `std.http` (an HTTP/1.1 server) |
| Data | `std.hash` (`Map` and `Set`, in insertion order), `std.sort`, `std.slices` |
| Text | `std.text`, `std.utf8`, `std.utf16`, `std.unicode` |
| Experimental | `std.json` (a fast, validating JSON parser), `std.terminal` (a terminal emulator as a library) |

The modules are Rig code, under `std/`, checked like any other.

## What the compiler guarantees

These promises are about the compiler. A program that breaks one is a
compiler bug, not a user error.

| Promise | What it means |
|---|---|
| Accept means correct | If `rig check` accepts a program, the emitted Zig compiles, runs, and does what the source says. What the compiler cannot lower correctly, it rejects with a Rig diagnostic. |
| Safe code cannot corrupt memory | Use after move, double free, use after free, dangling views, and leaks cannot happen outside a `raw` block. The test suite runs every program under a sanitizer that crashes at any use of freed memory. |
| Effects stay visible | No feature hides a move, clone, allocation, failure, or mutation. |
| Tasks share safely | A task takes only what may move to its core or be read from two at once; no two tasks hold a write view of one value. |
| Tasks end in scope | No task outlives the scope that owns it, or the loans it keeps. |

At run time, integer overflow, out-of-bounds indexing, and a numeric
conversion that does not fit panic in debug and `--release` builds.
`--release=fast` drops the overflow and conversion checks, which makes
an overflow undefined behavior, and keeps the bounds checks. Running
out of stack stops with `error: rig: stack overflow` in every mode.
Debug builds check for leaks on exit.

Some of this is machine-checked. Proofs in Lean ([formal/](formal/README.md))
show, for a small core of the language, that a program the ownership
checker accepts runs without a memory fault; and, for models of the
runtime, that a wait is ended by at most one waker and that no task
outlives its owner. They cover models, not the compiler itself.

## Performance

Tasks are fibers on a worker thread per core, with work stealing, and
each worker waits on its own kqueue or epoll poller. These numbers are
from [docs/launch/benchmarks.md](docs/launch/benchmarks.md): an Apple
M5 (macOS, arm64) and a 22-core Linux machine (x86-64), with Rig built
`--release=fast`, Tokio with `--release` and LTO, and Go with `go build`.

| Measure (Mac / Linux) | Rig | Tokio | Go |
|---|---|---|---|
| start a task and wait for it | 44 / 80 ns | 118 / 250 ns | 188 / 271 ns |
| switch between tasks | 10 / 8 ns | 42 / 47 ns | 245 / 440 ns |
| wait behind a long computation | 80 / 77 µs | 4.3 / 2.3 ms | 4.3 / 2.0 ms |
| actor call, 8 tasks contending | 31 / 35 ns | 269 / 270 ns (actor) | 79 / 65 ns (mutex) |
| HTTP requests a second | 169,000 / 830,000 | 179,000 / 297,000 (hyper) | 163,000 / 235,000 |
| memory per idle HTTP connection | 17.0 / 9.2 KiB | 18.6 / 10.8 KiB | 18.3 / 18.7 KiB |
| memory per sleeping task | 17.0 / 5.2 KiB | 264 / 355 B | 2.9 / 2.9 KiB |
| CPU work spread over the cores | 78 / 108 ms | 72 / 103 ms | 71 / 93 ms |

Where Rig is behind: a task holds at least one page of stack, so many
idle tasks cost more than Tokio's; CPU-heavy work spread over the cores
trails Tokio and Go by 5 to 16 percent, in the compiled loops rather
than the scheduler; and opening a connection on Linux takes 36 µs,
against Tokio's 31. The Linux HTTP figure shares the machine with its
load generator, so a server that spends less CPU leaves more to the
load; it needs reproducing elsewhere.

Each benchmark directory under [bench/](bench/) builds all three
versions and prints its table. If a number does not hold up on your
machine, please say so.

## Status

Rig is young, and its language still changes. The latest release is
`v0.2.9`. The `main` branch renames `Box`, `Vec`, `Text`, and `struct`
to `^T`, `List`, `String`, and `obj`; `tools/migrate-0.3.py` migrates
0.2 programs.

**Built and tested:** the language in this README, its ownership
checker, generics, closures, modules, SIMD vectors, C functions through
`extern`, `test` blocks, the language server, the concurrency model
(tasks, sets of tasks, cancellation, deadlines, actors, supervision,
channels, `select`, `par`, deterministic tests), and the standard
library above. The scheduler runs on macOS and Linux, on arm64 and
x86-64.

**Not built yet:**

- TLS, and an HTTP client.
- Errors that carry data (declared sets such as `T!E`).
- Traits or bounds, and raw pointers.
- Storing or returning a stack closure, and `drop` bodies on enums and
  generic objects. [SPEC §19](SPEC.md#19-reserved-and-unsupported-forms)
  lists every form the compiler rejects as not supported yet, each
  with what to write instead.

**Not in Rig:** macros, which are not planned, and string
interpolation: text is built with `String(a, b)`.

[HANDOFF.md](HANDOFF.md) says where the work stands, and
[docs/ROADMAP.md](docs/ROADMAP.md) lists the plans.

## Install

Rig needs [Zig](https://ziglang.org/download/) 0.17.0, which
`mise.toml` pins (`mise install` gets it), and
[Nexus](https://github.com/shreeve/nexus) 2.0, the parser generator.
The parser is generated from `rig.grammar` at build time, so every
build needs Nexus. Clone it beside this checkout and build it there:

```bash
git clone https://github.com/shreeve/nexus ../nexus
(cd ../nexus && zig build -Doptimize=safe)
zig build                  # builds bin/rig in the checkout
cp bin/rig ~/.local/bin/   # puts it on PATH
```

`zig build -Dnexus=PATH`, or `NEXUS=PATH zig build`, names another
Nexus binary. `rig` runs the `zig` on `PATH`, or `$ZIG` when it is set.

The test suite runs on Swarm, from [Rip](https://github.com/shreeve/rip),
which runs on Bun. Its command-line scripts also need bash, GNU
`timeout` (or `gtimeout`), and perl.

## Build and run

```bash
bin/rig run examples/hello.rig         # check, build, and run (debug, leak-checked)
bin/rig run --release file.rig         # the same, optimized (safe)
bin/rig build -o hello file.rig        # a native executable
bin/rig build --release=fast file.rig  # fast: no overflow checks
bin/rig test file.rig                  # run the file's own `test` blocks
bin/rig test --seeds=20 file.rig       # the same, under 20 schedules
bin/rig check file.rig                 # check only
bin/rig emit file.rig                  # print the emitted Zig
bin/rig clean                          # remove the cache of built programs
bin/rig lsp                            # the language server (editors/README.md)
swarm test/rig.rip all                 # the whole test suite (test/README.md)
```

A debug build reports any allocation still live when `main` returns,
and exits 1; set `RIG_LEAK_TRACE=1` when building to see where each
was allocated. `rig run`, `build`, and `test` keep built programs in a
cache under `~/.cache/rig`, which they trim themselves. `rig --help`
lists every command, option, and environment variable, the cache's
included.

## Where to go next

| To | Read |
|---|---|
| learn Rig's ideas, one journey at a time | [docs/learn/](docs/learn/README.md), starting with [sigils](docs/learn/01-sigils.md) |
| learn Rig from another language | [WELCOME.md](WELCOME.md) |
| see every sigil on one page | [docs/QUICK.md](docs/QUICK.md) |
| understand ownership | [docs/CORE.md](docs/CORE.md), the whole model on one page |
| look up how a form is written | [SYNTAX.md](SYNTAX.md) |
| look up what a form means | [SPEC.md](SPEC.md), the language reference |
| use the standard library | [docs/STD.md](docs/STD.md) |
| read about concurrency | [docs/launch/post.md](docs/launch/post.md), then [docs/design/concurrency.md](docs/design/concurrency.md) |
| check the numbers | [docs/launch/benchmarks.md](docs/launch/benchmarks.md), [bench/](bench/) |
| compare with Rust | [docs/BEYOND-RUST.md](docs/BEYOND-RUST.md) |
| see why Rig is the way it is | [docs/DESIGN.md](docs/DESIGN.md) |
| read complete programs | [examples/](examples/README.md) |
| find common questions | [FAQ.md](FAQ.md) |
| see how the compiler works | [docs/internals/INTERNALS.md](docs/internals/INTERNALS.md) |
| work on Rig | [AGENTS.md](AGENTS.md), then [HANDOFF.md](HANDOFF.md) |
