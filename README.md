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
copy and no reference count, and the compiler keeps the loan until
`>u`, so a write to `xs` before then is rejected. That is the rule Rig
applies to every view, not a special rule for tasks.

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
  ([benchmarks](docs/launch/benchmarks.md)).

Every `rig` example in this README is checked by the test suite.

## The sigils

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
`<t.cancel()`. Rig spells negation `not`, so `!` never means "not".
[docs/QUICK.md](docs/QUICK.md) puts every sigil on one page, and
[the sigils journey](docs/learn/01-sigils.md) teaches them.

## Status

Rig is young, and its language still changes. The latest release is
`v0.3.0`. `^T`, `List`, `String`, and `obj` are 0.3's spellings of `Box`, `Vec`,
`Text`, and `struct`, which `v0.2.9` used;
[docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md) migrates 0.2 programs,
`tools/migrate-0.3.py` first.

Built and tested: the language, its ownership checker, generics, APIs
and API objects, compile-time functions, closures, modules, C
functions through `extern`, the concurrency model, and the
[standard library](docs/STD.md). The scheduler runs on macOS and Linux,
on arm64 and x86-64. Not built yet: TLS and an HTTP client, declared
error sets in std's I/O signatures, raw pointers, API objects of an API
with an associated type, storing or returning a stack closure, and
`drop` bodies on enums and generic objects;
[SPEC §19](SPEC.md#19-reserved-and-unsupported-forms) lists each form
the compiler rejects, with what to write instead. Rig has no macros,
which are not planned.
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
bin/rig run examples/hello.rig
```

`zig build -Dnexus=PATH`, or `NEXUS=PATH zig build`, names another
Nexus binary. `rig` runs the `zig` on `PATH`, or `$ZIG` when it is set.
`rig --help` lists every command, and
[the welcome page](docs/learn/00-welcome.md#running-a-program) shows
the common ones.

The test suite runs on Swarm, from [Rip](https://github.com/shreeve/rip),
which runs on Bun: `swarm test/rig.rip all` ([test/](test/README.md)).
Its command-line scripts also need bash, GNU `timeout` (or `gtimeout`),
and perl.

## Where to read next

| To | Read |
|---|---|
| learn Rig from the language you know, with a tour | [the welcome page](docs/learn/00-welcome.md) |
| learn Rig's ideas, one journey at a time | [docs/learn/](docs/learn/README.md) |
| look up how a form is written | [docs/SYNTAX.md](docs/SYNTAX.md) |
| look up what a form means | [SPEC.md](SPEC.md), the language reference |
| understand ownership | [docs/CORE.md](docs/CORE.md), the whole model on one page |
| use the standard library | [docs/STD.md](docs/STD.md) |
| find common questions | [docs/FAQ.md](docs/FAQ.md), then [docs/DESIGN.md](docs/DESIGN.md) for why |
| read about concurrency | [docs/launch/post.md](docs/launch/post.md), then [docs/design/concurrency.md](docs/design/concurrency.md) |
| check the numbers | [docs/launch/benchmarks.md](docs/launch/benchmarks.md), [bench/](bench/) |
| compare with Rust | [docs/BEYOND-RUST.md](docs/BEYOND-RUST.md) |
| read complete programs | [examples/](examples/README.md) |
| see how the compiler works | [docs/internals/INTERNALS.md](docs/internals/INTERNALS.md) |
| find any document by its question | [docs/README.md](docs/README.md) |
| see what changed | [CHANGELOG.md](CHANGELOG.md) |
| work on Rig | [AGENTS.md](AGENTS.md), then [HANDOFF.md](HANDOFF.md) |
