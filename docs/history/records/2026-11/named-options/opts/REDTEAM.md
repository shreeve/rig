# Red-team brief: is the options design too good to be true?

The owner found the committee's recommendation "almost too good to be true" and
asks for one more check. Your job is adversarial: **find what's wrong with it**.
Don't restate its merits. If it survives, say so plainly, but only after trying
hard to break it.

Rig compiles to Zig 0.17. North Star: **a program the compiler accepts is
correct**, and **effects stay visible**. Repo `~/Data/Code/rig` (main
75a6c7b5e): `AGENTS.md`, `docs/CORE.md` (ownership), SPEC (calls: "A call
passes arguments by position, by keyword, or both"; objects and fields set by
name; defaults "a literal or a module constant"), `docs/SYNTAX.md` §11. Run
programs with `~/Data/Code/rig/bin/rig run FILE`. Read only: don't edit, commit
or push.

## The recommendation under test

Reports, in this folder
(`/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/opts/`):
`BRIEF.md` (the committee's brief), `innovator.md`, `zig.md`, `rig.md` (the
final recommendation). And the earlier keyword-only panel in
`../kwonly/` (`PANEL.md`, `designer.md`, `evangelist.md`, `practitioner.md`).

```rig
fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Conn!
connect(host, 5432, timeout: 5)                # options by name (the keyword-only rule)
o = connect.Options(timeout: 5)                # a function's options, as a value
connect(host, 5432, ..o, retry: false)         # spread, then override
obj Net
  timeout: Duration? = none
  retries: Int = 3
fun fetch(url: ?String, ..net: Net) -> Response!   # a shared group
fetch(url, retries: 5)
fetch(url, ..cfg.net)
fun connect_logged(host: ?String, port: Int, ..o: connect.Options) -> Conn!
  connect(host, port, ..o)                     # typed forwarding
q = Point(..p, x: 3)                           # struct update
Mapping(generated_position:, source_index:)    # punning: name: means name: name
```

The rule: **a parameter with a default is an option, given by name** (no
first-parameter exemption; positional first, then named; no default on `_`; no
required parameter after a defaulted one unless it takes a closure; a trailing
closure fills the function parameter). Decisions proposed: `..` for groups,
spreads and struct update, plus punning; built as a rewrite of `..o` into
`timeout: o.timeout, ...` before checking and a group flattened into name-only
parameters (not new argument slots); v1 = punning, spread, struct update,
`f.Options`, groups (later: function values keeping options, groups in APIs,
`..o: ?T`, generic groups); a spread's operand is a name or field path;
spreads nominal (the value's type must be `f.Options` or one of `f`'s groups);
groups hold only plain values and read views; in datetime, `Period`,
`DateFields`, `ClockFields` become groups; `round`/`floor` keep inline units.
Claimed cost about 1.0k compiler lines plus 0.7k tests and docs, none in
ownership, storage or emit's call path; zero run-time cost.

## Attack it

Look for, at least:
- **Contradictions and holes** between the pieces (the rule vs groups vs
  spreads vs punning vs the trailing closure vs duration forms vs the
  constant-argument rule vs `stdArgChecks`); a program the design accepts that
  is wrong, or a sensible one it refuses.
- **The claims**: zero cost; "none in ownership, storage or emit"; the rewrite
  keeps evaluation order and effects visible; nominal spreads are always
  unambiguous (a value whose type is a group of two functions? a group nested in
  a group? two groups in one signature with a shared field name? an option
  named like a positional parameter?); `f.Options` for methods, generic
  functions, overloaded-free names, a function whose options include a closure.
- **Ownership**: punning an owner, struct update leaving fields behind, a group
  field that is a read view outliving its source, a spread of a field path
  through a read view, write views and `!` arguments near a spread.
- **Evolution and teaching**: adding an option to a group used by many functions;
  renaming; error messages for each mistake; whether "two sentences" really
  covers it; what a newcomer from Python, Ruby, JavaScript, Swift, Zig, Rust or
  Go would get wrong.
- **Precedent failures**: Ruby 2's keyword/hash ambiguity, Python's `**kwargs`
  opacity, C#'s optional parameters baked into callers, Scala's named-argument
  pitfalls, JavaScript spread's silent coupling: does this design repeat any?
- **Scope**: is it too much for one language? What would you cut?

Probe with real programs where you can (today's compiler accepts the named
form and struct literals; `..` and punning are not built, so reason about them
precisely).

Write your full report to your file in this folder (name in your prompt): each
finding with a concrete example, why it matters, severity (fatal, serious,
minor), and a fix. Return at most 400 words: the findings ranked, and your
verdict (sound as proposed, sound with these fixes, or unsound).
