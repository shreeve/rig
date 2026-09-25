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
sub main()
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

sub main()
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

  drop self: !File
    print("closing", self.name)

sub archive(f: File)
  print("archiving", f.name)

sub main()
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

  drop self: !Config
    print("config released")

sub main()
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

### Closures and a little reactivity

```rig
sub main()
  clicks: *Signal(Int) = *Signal(value: 0)
  total: *Cell(Int) = *Cell(value: 0)
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
| `?` | `?x` read borrow | `?T` read-borrowed; `T?` optional |
| `!` | `!x` write borrow; `f()!` propagate failure | `!T` write-borrowed; `T!` fallible |
| `+` | `+x` clone (a new owner) | |
| `-` | `-x` drop now (as a statement) | |
| `*` | `*x` share: move into a counted box | `*T` shared handle |
| `~` | `~x` weak handle | `~T` weak handle |

A sigil is a prefix when it touches its operand, so `a < b` is still a
comparison and `a * b` a product. The [language reference](SPEC.md)
covers every rule; [docs/DESIGN.md](docs/DESIGN.md) explains how the
sigils form a small algebra.

## Build and run

You need Zig 0.16.

```bash
zig build                              # builds bin/rig
bin/rig run examples/hello.rig         # check, build, and run (Debug)
bin/rig run --release file.rig         # the same, optimized (ReleaseSafe)
bin/rig build -o hello file.rig        # a native executable
bin/rig build --release=fast file.rig  # ReleaseFast: no runtime safety checks
bin/rig test file.rig                  # run the program's `test` blocks
bin/rig check file.rig                 # check only
bin/rig check --facts file.rig         # check, then print the IR as facts
bin/rig emit file.rig                  # print the emitted Zig
./test/run                             # the whole test suite
```

Debug builds (the default) check for memory leaks: a program that
leaks reports how many allocations it lost and exits 1; set
`RIG_LEAK_TRACE=1` when building to see where each was allocated.
`--release` builds keep Zig's safety checks (integer overflow, bounds);
`--release=fast` drops them. `rig --help` lists every option. Changing
the grammar needs [Nexus](https://github.com/shreeve/nexus) 1.0, the
parser generator: `zig build parser -Dnexus=path/to/nexus` (or build
Nexus next to this checkout, `cd ../nexus && zig build
-Doptimize=ReleaseSafe`, and run `zig build parser`).

## Status

**Works today**, with tests for each feature:

- structs, enums with payloads, error sets, generic types, type
  aliases, methods with explicit receivers, field defaults, exhaustive
  `match`
- `Int` and `Float` (64-bit), sized numbers, compile-time checked
  constant arithmetic, arrays, strings, slices (`s[a..b]`, `?xs[a..b]`)
- loops as values (`x = for ... break v ... else w`), labeled loops
- moves, read and write borrows (including borrows returned from
  functions and held in structs), clones, drops, automatic drop on every
  path, drop glue, user `drop` bodies
- shared `*T` and weak `~T` handles, `Cell`, `Vec`, and `Signal`
- stack and owned closures with explicit captures, any arity, inferred
  parameter types, and return values
- optionals with `none`, `??`, `if x as v`, and `x?`; fallible functions that
  fail with error values, handled with `f()!`, `catch`, and `catch |err|`
- checked numeric conversions (`I32(x)`, `Float(n)`), and borrows that
  end at their last use
- modules with `pub` and module-level constants, `raw` blocks, and C
  functions through `extern`
- a test suite where every program runs leak-checked, and every
  example in these docs is checked

**Not yet:**

- a standard library (there is a small runtime and `print`)
- concurrency and async
- passing a stack closure as an argument (owned closures work)
- generic functions, traits or interfaces
- string building

## Learn more

- [SPEC.md](SPEC.md): the language reference
- [docs/DESIGN.md](docs/DESIGN.md): principles, the sigil algebra, and
  influences
- [docs/INTERNALS.md](docs/INTERNALS.md): how the compiler works
- [docs/ROADMAP.md](docs/ROADMAP.md): where Rig is going
- [FAQ.md](FAQ.md): common questions
- [examples/](examples/README.md): short programs
- [AGENTS.md](AGENTS.md): rules for working on Rig
