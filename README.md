# Rig

Rig is a small, fast systems language that aims for the readability of
Python and Ruby and the memory safety of Rust, without a garbage
collector. Blocks are indented, most code carries no annotations at
all, and the places where ownership matters are marked by a handful of
one-character sigils: `<x` moves, `?x` borrows, `+x` clones, `-x`
drops. The compiler checks every one of them, then lowers the program
to [Zig](https://ziglang.org) 0.16, which does the optimizing, code
generation, and linking.

> **Status: early.** The core language and its ownership checker work
> and are tested end to end, every program running leak-checked. There
> is no standard library, concurrency, or async yet, and the language
> will change. See [what works](#status).

## A short tour

Every example in this README is compiled and run by the test suite, and
prints exactly the output shown under it.

### Hello

```rig
sub main
  print "hello, rig"
```

```output
hello, rig
```

`sub` declares a routine that returns nothing; `fun` declares one that
returns a value. Calls can drop their parentheses when they end the
line.

### Borrowing

```rig
struct User
  name: String
  visits: Int

fun greeting(u: ?User) -> String
  if u.visits > 1
    "welcome back"
  else
    "hello"

sub visit(u: !User)
  u.visits += 1

sub main
  ada = User(name: "Ada", visits: 1)
  visit(!ada)
  print(greeting(?ada), ada.name)
```

```output
welcome back Ada
```

`?User` is a read borrow and `!User` a write borrow. The same sigil
appears at the call site, `greeting(?ada)` and `visit(!ada)`, so you can
see what a call may do to your value without looking it up. Borrows are
checked, never counted: they cost nothing at run time. A value can have
many readers or one writer at a time, never both.

### Resources and drop

```rig
struct File
  name: String

  drop(!self)
    print("closing", self.name)

sub archive(f: File)
  print("archiving", f.name)

sub main
  log = File(name: "log.txt")
  data = File(name: "data.csv")
  archive(<log)
  print("working")
```

```output
archiving log.txt
closing log.txt
working
closing data.csv
```

A `drop` body runs when a value is released. `<log` moves the file into
`archive`, which now owns it and closes it on return; using `log`
afterwards would be a compile error. `data` is still owned by `main` and
is closed when `main` ends. There are no finalizers and no GC: cleanup
happens at a point you can see.

### Shared handles

```rig
struct Config
  level: Int

  drop(!self)
    print("config released")

sub main
  a = *Config(level: 3)
  b = +a
  -a
  print("still here:", b.level)
```

```output
still here: 3
config released
```

`*Config(...)` puts the value in a reference-counted box, `+a` makes
another owner (a visible refcount bump), and `-a` drops one now. The
value goes when its last owner does.

### Generics

```rig
struct Pair[T, U]
  first: T
  second: U

fun max[T](a: T, b: T) -> T
  a if a > b else b

sub main
  p = Pair(first: max(3, 7), second: max(2.5, 1.0))
  print(p.first, p.second, max[Float](1, 2))
```

```output
7 2.5 2.0
```

Square brackets hold what is known at compile time, and parentheses
what is known when the program runs. Type arguments are usually
inferred, and given in brackets when they are not: `max[Float](1, 2)`,
`Vec[Int]()`. There are no trait bounds: each instance a program makes
is checked against what the generic body does with `T`, and an error
names the call, with a note at the line of the body.

### Closures and a little reactivity

```rig
sub main
  clicks: *Signal[Int] = *Signal(value: 0)
  total: *Cell[Int] = *Cell(value: 0)
  clicks.subscribe(*|~clicks, +total|
    if clicks.upgrade() as c
      total.set(total.get() + c.get())
      print("clicks", c.get(), "total", total.get()))
  clicks.set(1)
  clicks.set(2)
```

```output
clicks 1 total 1
clicks 2 total 3
```

A closure's bar list says how it holds each outer value: `+total`
clones a handle, `<x` would move one in, and `~clicks` holds the signal
weakly, so the signal and its subscriber don't keep each other alive.
The `*` before the bars makes the closure *owned*, a heap handle the
signal can keep. `Signal` is deliberately tiny; richer reactive
libraries are written in Rig itself (see
[examples/memo_canary.rig](examples/memo_canary.rig)).

## The sigils

| Sigil | In an expression | In a type |
|---|---|---|
| `<` | `<x` move `x` | |
| `?` | `?x` read borrow; `x?` propagate `none` | `?T` read-borrowed; `T?` optional |
| `!` | `!x` write borrow; `f()!` propagate failure | `!T` write-borrowed; `T!` fallible |
| `+` | `+x` clone (a new owner) | |
| `-` | `-x` drop now (as a statement) | |
| `*` | `*x` share: move into a counted box | `*T` shared handle |
| `~` | `~x` weak handle | `~T` weak handle |

A sigil is a prefix when it touches its operand, so `a < b` is still a
comparison and `a * b` a product. The [language reference](SPEC.md)
covers every rule; [docs/DESIGN.md](docs/DESIGN.md) explains how the
sigils form a small algebra.

## Install

Rig needs [Zig](https://ziglang.org/download/) 0.16 on `PATH`; `rig`
itself runs `$ZIG` instead when it is set.

```bash
zig build                  # builds bin/rig in the checkout
zig build -p ~/.local      # or installs ~/.local/bin/rig
```

The test runner also needs GNU `timeout` (on macOS, `gtimeout` from
`brew install coreutils`). [Nexus](https://github.com/shreeve/nexus)
1.0, the parser generator, is needed only to change the grammar: clone
it beside this checkout and build it there (`zig build
-Doptimize=ReleaseSafe`), and `zig build parser` and the suite find it
([AGENTS.md](AGENTS.md#workflow) has the details).

## Build and run

```bash
bin/rig run examples/hello.rig         # check, build, and run (Debug)
bin/rig run --release file.rig         # the same, optimized (ReleaseSafe)
bin/rig build -o hello file.rig        # a native executable
bin/rig build --release=fast file.rig  # ReleaseFast: no overflow checks
bin/rig test file.rig                  # run the program's `test` blocks
bin/rig check file.rig                 # check only
bin/rig emit file.rig                  # print the emitted Zig
./test/run                             # the whole test suite
```

Debug builds (the default) check for memory leaks: a program that
leaks reports how many allocations it lost and exits 1; set
`RIG_LEAK_TRACE=1` when building to see where each was allocated.
`--release` keeps the overflow, conversion, and bounds checks;
`--release=fast` drops the overflow and conversion checks, which makes
overflow undefined behavior. `rig --help` lists every command, option,
and environment variable. The suite runs on Linux and macOS in
[CI](.github/workflows/test.yml).

## Status

**Works today**, with tests for each feature:

- structs with field defaults, enums with payloads, error sets, type
  aliases, module-level constants, methods with explicit receivers,
  exhaustive `match`
- generic types, functions, and methods (`struct Box[T]`,
  `fun max[T](a: T, b: T) -> T`), with inferred type arguments and
  per-instance checking, and compile-time value parameters
  (`fun check[mode: Mode](n: Int)`)
- `Int` and `Float` (64-bit), sized numbers, checked conversions
  (`I32(x)`, `Float(n)`), compile-time checked constant arithmetic,
  arrays, strings, slices (`s[a..b]`, `?xs[a..b]`)
- loops as values (`x = for ... break v ... else w`), labeled loops
- moves, read and write borrows (including borrows returned from
  functions and held in structs) that end at their last use, clones,
  drops, automatic drop on every path, drop glue, user `drop` bodies
- shared `*T` and weak `~T` handles, `Cell`, `Vec`, and `Signal`
- stack and owned closures with explicit captures, any arity, inferred
  parameter types, and return values
- optionals with `none`, `??`, `if x as v`, and `x?`; fallible functions
  that fail with error values, handled with `f()!`, `catch`, and
  `catch |err|`
- modules with `pub`, `raw` blocks, C functions through `extern`, and
  `test` blocks run by `rig test`

**Not yet:** a standard library (there is a small runtime and `print`),
concurrency, and async. [SPEC §19](SPEC.md#19-reserved-and-unsupported-forms)
lists every form the compiler rejects as not supported yet, among them
passing a stack closure as an argument;
[the roadmap](docs/ROADMAP.md) lists the plans.

## Learn more

- [SYNTAX.md](SYNTAX.md): the syntax, taught to Zig and Rust
  programmers, from a tour to a full reference
- [SPEC.md](SPEC.md): the language reference
- [docs/DESIGN.md](docs/DESIGN.md): principles, the sigil algebra, and
  influences
- [docs/INTERNALS.md](docs/INTERNALS.md): how the compiler works
- [docs/ROADMAP.md](docs/ROADMAP.md): where Rig is going
- [FAQ.md](FAQ.md): common questions
- [examples/](examples/README.md): short programs
- [AGENTS.md](AGENTS.md): rules for working on Rig
