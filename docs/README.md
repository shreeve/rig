# Rig's documentation

Each question has one home, and every other page links to it. The
journeys of [learn/](learn/README.md) teach each big idea once;
[WELCOME](../WELCOME.md) translates from the language you know;
[QUICK](QUICK.md) is the card to recall from; [FAQ](../FAQ.md) and
[DESIGN](DESIGN.md) say why; [SYNTAX](../SYNTAX.md), [SPEC](../SPEC.md),
[CORE](CORE.md), and [STD](STD.md) specify.

## Which document answers which question

| Question | Document |
|---|---|
| What is Rig, and how do I install it? | [README.md](../README.md) |
| I know Rust, Zig, Go, or Python: what is different? | [WELCOME.md](../WELCOME.md), then [BEYOND-RUST.md](BEYOND-RUST.md) for Rust |
| What does each sigil mean? | [learn/01-sigils.md](learn/01-sigils.md) to learn, [QUICK.md](QUICK.md) to recall |
| How is memory freed with no collector? | [learn/02-ownership.md](learn/02-ownership.md), then [CORE.md](CORE.md) |
| How do errors and optionals work? | [learn/03-errors.md](learn/03-errors.md), then [SPEC §12 and §13](../SPEC.md#12-optionals) |
| How do I run things concurrently? | [learn/04-concurrency.md](learn/04-concurrency.md), then [SPEC §18](../SPEC.md#18-tasks) |
| How do I handle text? | [TEXT.md](TEXT.md), and the text modules of [STD.md](STD.md) |
| What is in the standard library? | [STD.md](STD.md) |
| How do I write a form? | [SYNTAX.md](../SYNTAX.md) |
| What exactly does a form mean? | [SPEC.md](../SPEC.md) |
| Why was it designed this way? | [FAQ.md](../FAQ.md), then [DESIGN.md](DESIGN.md) and [design/](design/) |
| How fast is it, and how was that measured? | [launch/benchmarks.md](launch/benchmarks.md), and each benchmark's README under [bench/](../bench/) |
| What is planned? | [ROADMAP.md](ROADMAP.md) |
| What has been proved? | [formal/README.md](../formal/README.md) |
| Where do things stand right now? | [HANDOFF.md](../HANDOFF.md) |
| How do I work on the compiler? | [AGENTS.md](../AGENTS.md), then [internals/](internals/) |
| How do tests work? | [test/README.md](../test/README.md) and [internals/tests.md](internals/tests.md) |
| What was tried before? | [history/](history/) |

## Reading orders

**A newcomer**, deciding whether to care and then writing a first
program: [README](../README.md), then [WELCOME](../WELCOME.md) for
your language, then the journeys in order: [sigils](learn/01-sigils.md),
[ownership](learn/02-ownership.md), [errors](learn/03-errors.md),
[concurrency](learn/04-concurrency.md). Then the
[examples](../examples/README.md), and the [FAQ](../FAQ.md) when a
"why" comes up.

**A user**, writing Rig: [QUICK](QUICK.md) beside the editor,
[SYNTAX](../SYNTAX.md) and [STD](STD.md) while writing, and
[SPEC](../SPEC.md) for an exact rule.

**A contributor**, changing the compiler or library:
[AGENTS](../AGENTS.md), [HANDOFF](../HANDOFF.md), [CORE](CORE.md),
[SPEC](../SPEC.md), [internals/INTERNALS](internals/INTERNALS.md),
[test/README](../test/README.md) and [internals/tests](internals/tests.md),
[internals/zig-0.17](internals/zig-0.17.md),
[formal/README](../formal/README.md), the record behind a feature in
[design/](design/), and the [ROADMAP](ROADMAP.md).

## The folders

| Folder | Holds |
|---|---|
| [learn/](learn/README.md) | the journeys: one chapter for each of Rig's big ideas |
| [design/](design/) | the records of decisions that hold today: concurrency and its panel, `as` patterns, the formal plan, the mantras, JSON, SIMD |
| [internals/](internals/) | for contributors: the compiler, Zig 0.17, the scheduler, SIMD lowering, the tests |
| [launch/](launch/) | the launch post on concurrency, its FAQ, its benchmarks, and one server in three languages |
| [history/](history/) | superseded and dated documents, each opening with what replaced it |
