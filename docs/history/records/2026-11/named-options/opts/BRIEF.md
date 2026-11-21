# Committee brief: options at the call, the goldilocks design

The owner asks for a design that gets **as many least-surprise advantages as
possible, in a maximally flexible, powerful and efficient way**, and invites
innovation. This is a proposal; nothing is built.

Rig compiles to Zig 0.17. North Star: **a program the compiler accepts is
correct**, and **effects stay visible**. The repo is `~/Data/Code/rig` (main
75a6c7b5e): read `AGENTS.md`, `docs/CORE.md` (ownership: places, read and write
views, owners, moves), SPEC's calls section (search "A call passes arguments by
position, by keyword, or both", and "closure written as a call's last
argument") and its objects section (how fields are set by name, `Point(x: 1,
y: 2)`; "a type with more than one field sets them by name"), and
`docs/SYNTAX.md` §11. Run programs with `~/Data/Code/rig/bin/rig run FILE`.
Read only: don't edit, commit or push.

## Where the design stands

A panel of three unanimously recommended a rule (reports in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/kwonly/`:
`PANEL.md` the brief, `designer.md`, `evangelist.md`, `practitioner.md`; the
measured cost is in `calls.tsv` and `summary-raw.txt`):

> **A parameter with a default is an option, and options are given by name.**
> Positional arguments come first; options follow by name.

`connect(host, 5432, timeout: 5)`. 326 call sites would change, mechanically;
emitted Zig is unchanged. Open points they raised: wrappers repeat `timeout:
timeout` (about 650 such lines in Trig already); a required argument can't be
made name-only; parameter names with defaults become API; adding a default
later breaks positional callers.

## What the owner wants added

Zig's idiom, `connect(host, .{ .timeout = 30, .retry = true })`, is clean and
flexible: options are **a value**. They can be built once, stored, passed whole,
forwarded through wrappers, partly overridden, and shared by several functions.
Ruby's keyword arguments (`**opts`), Python's `**kwargs`, JavaScript's options
objects with spread, and OCaml's labels each get part of this. The owner wants
Rig to have an "opts bag" to forward, alongside the rule's readability.

## Your task

Propose the best design for Rig. Consider, and go beyond:
- an options value per function, derived from its defaulted parameters or
  declared (`connect.Options`? an `opts` type the author names?); building one
  (`Options(timeout: 5)`); passing it whole; spreading it into a call
  (`connect(host, ..opts)`) with overrides (`..opts, timeout: 5`); returning,
  storing and sharing one across functions;
- the forwarding shorthand (`connect(host, timeout:, retry:)` meaning
  `timeout: timeout`), and whether an options value makes it unnecessary;
- static typing throughout: no dynamic dictionary, every option name and type
  checked at compile time, misspelled options refused;
- **zero cost**: what the emitted Zig looks like (Zig structs with defaults are
  the natural lowering; is it still one call with plain arguments?);
- interactions: generics, APIs (can an API method declare options?), function
  values (does an options type make a function-with-options expressible as a
  value?), the trailing closure, ownership (an option that is a view or an
  owner; moving vs copying an options value; Rig's places and views),
  `!` and effects, defaults that are constants, evolution of a library's
  options over time (adding an option is compatible?);
- the rule's open points above: does your design solve them?
- the datetime library's needs (`dt.add(duration:, years:, months:, weeks:,
  days:)`, `with(year:, month:, ...)`, `round(minutes: 15)`), as a test case;
- teaching: can it be explained in two sentences?

Show each idea with short Rig code, and say what it costs to build (compiler
areas, rough size) and what it would refuse. Be bold where it pays; say plainly
where an idea isn't worth its weight. Cite precedent precisely (Zig, Ruby,
Python, JavaScript, Swift, Kotlin, OCaml, C#, Dart, Jai, Odin, Nim, Rust's
builder and struct-update idioms).

Write your full report to your file in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/opts/`
(name given in your prompt). Return at most 400 words: your proposed design in
a short code block, what it gets right, what it costs, and what you'd leave out.
