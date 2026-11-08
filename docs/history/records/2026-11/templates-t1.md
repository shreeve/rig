# Backtick templates, T1: the design as built

2026-11-07. One place for what T1 builds: the October design
([revamp/r3/templates-design.md](../revamp/r3/templates-design.md),
approved 2026-10-16 in three passes) with the revision the owner
approved on 2026-11-07 (the strings panel of three: a designer, a
systems engineer, and a survey of other languages; its reports are kept
in the session's `strings-panel/`). Where the two differ, 2026-11-07
wins; the differences are marked **(revised)**.

## The three quote forms

| Form | Meaning |
|---|---|
| `'raw'` | text as written, no escapes; `''` is one `'` (unchanged) |
| `"text"` | fixed text with escapes, a `Static` (unchanged) |
| `` `built {x}` `` | text built from pieces and slots |

A backtick was an invalid character, so a template is a new literal and
changes no program that ran before. `"…"` never gains slots.

## What a template is

`` `a{x}b{=y}c` `` is pieces of fixed text with slots between them.

- **A slot takes exactly what a print argument takes,** with no
  exception list. For the checker a template's slots are flat argument
  positions, read as `print`'s are: `` !t.add(`{t}`) `` and
  `` `{v} {grow(!v)}` `` are rejected by today's argument rule. The Core
  gains one phrase in §3, "or a template's slot".
- **Every slot is evaluated once, left to right, before any byte is
  written.** A failing slot writes nothing and leaks nothing. Slots are
  eager, which rules out lazy loggers.
- **No separators:** a template writes exactly what is typed
  (`String(...)`'s rule, not print's spaces). `print(a, b, c)` keeps its
  single spaces; `` print(`{a}, {b}, {c}`) `` prints `1, 2, 3`.
- **The show form `{=e}`** writes the expression as typed (outer spaces
  trimmed), a fixed ` = `, then the value as it prints inside another
  value: text quoted and escaped, `none` visible. `{x=}` is rejected
  with the hint `{=x}`; `{=` is one token, so `{ =x}` is rejected, and
  `{=}` too. The inline wrap (`total = {=price * qty} + tax`, Rust's
  `dbg!`) is round W, after T2, not T1.
- **Escapes** are the `"…"` table (`\n`, `\r`, `\t`, `\\`, `\'`, `\"`,
  `\xNN`, `\u{N}`) plus `\{`, `\}`, and `` \` ``; an unknown escape is an
  error. A `"` needs no escape inside backticks (244 `\"` in Trig).
  **One escape table** (October decision 11): `"…"` accepts `\{`, `\}`,
  and `` \` `` too, so text moves between the two forms.
- **Text from run time never becomes a template.** A template exists only
  as a backtick literal in the source; its pieces are fixed when the
  program is compiled, and a slot's value is written, never searched
  again for slots (C's format strings, Log4Shell).

## The place decides (revised)

October's guard was "a template is never a value": it stood only where
print's arguments go, and anywhere else asked for `String(...)`. The
owner's 2026-11-07 constraint, "no `String(...)` required", reopens it.
**Templates go where text is read or stored, and the place decides what
a template becomes:**

| Where it stands | What it is | Cost |
|---|---|---|
| an argument of `print`, `warn`, `panic` | its pieces, written straight | no allocation, no String |
| an argument of `!t.add(...)` or `String(...)` | its pieces, spliced as arguments | the call's own |
| where a `?String` is expected (a parameter that reads) | a temporary of its statement, read as a view (CORE §3) | a 256-byte buffer in the caller's frame, the heap past it, freed when the statement ends |
| where a `String` is expected (a binding, a field, a return, an owning parameter, an element) | a new owned String | one allocation of the exact length |
| anywhere else (an operand, a member's object, a `Static` place) | an error, with a hint | |

The stored form needs no extra mark: **the backtick is the allocation's
mark** (owner, 2026-11-07, default 2; the systems engineer's `` +`…` ``
was not taken). This keeps a template parameter type possible later: at
a later `?Template` parameter a template would be its pieces, at a
`?String` a temporary; the only commitment is that a template where a
`?String` goes is a temporary.

**The quadratic trap is rejected:** `` s = `{s}{i}` ``, a template that
reads the binding it assigns, is an error with the hint `!s.add(...)`.

**Why the temporary is sound with no new rule.** CORE §3 already makes a
value made where it is only read a temporary, dropped when its statement
ends, and the ownership checker already rejects every escape of its
views: `s = ?String("a", 1)` ("a view of the temporary … outlives its
statement"), `t = work(String("a", 1))&` (a task cannot keep it). A
template where a `?String` goes is that temporary. The buffer is storage,
not ownership: the checker sees a temporary String, and emit lowers it
as the storage fact says (North Star 4: emit decides nothing).

**Why 256 bytes, and where.** The buffer lives in the caller's frame,
since the view outlives the render (`String.of`'s 256-byte stack sits in
a `noinline` frame that returns). 256 matches `String.of`'s `of_stack`;
it counts toward `src/frames.zig`'s page warning and a task's proven
stack bound. A per-thread scratch arena is unsound: `net.connect` yields
while the view lives, and another task on the thread would overwrite it.

## Compile time when obvious

A template whose slots are all constant (a `Static` constant, a
compile-time Int or Bool, an enum literal) folds to fixed text: in
`print` one write, where a `?String` goes a view of the program's bytes
with no buffer, where a `String` goes one allocation of the folded
bytes. Floats fold only once compile-time evaluation shares Rig's float
writer; until then they run, with the same bytes. A golden test pins
folded bytes to run-time bytes.

## No format mini-language

A top-level `:` in a slot is reserved and rejected. Formatting is
methods, T2, not T1: `x.fixed(2)`, `n.hex(width: 8)`, `n.dec(width: 2)`,
`s.pad(10)` (chars), `xs.join(", ")`. No Rig value is ever written
through a Zig `std.fmt` spec (`{d:5}` of an `i64` 42 prints `  +42`).
printf-style patterns arrive at run time only, as a library (the
coreutils `printf` port); Trig's `{0}` catalogs stay a library function.

## The strict rules (each strict now, loosened later if it hurts)

Each is an error, with a message that says what to write:

- a backtick with no slot (write `"…"`) **(revised: 2026-11-07, default 3)**;
- an empty slot `{}`; a slot holding only a literal (`{0}`, which
  catches ported `{0}` text; `{"a"}`);
- a top-level `:` in a slot (formatting is methods);
- `#` in a slot; a template in a slot (kept for composition);
- a name touching a backtick (`` sql`…` ``, kept for tagged templates);
- the empty template ``` `` ``` and any run of two or more backticks
  (kept for a fenced or raw form);
- a lone `}` in template text (hint `\}`);
- an unclosed slot or template; an unknown escape; a control character
  or a bidirectional control written raw;
- `\` at the end of a line (kept for joining lines with no newline);
- a keyword argument to `print`, `warn`, or `panic` (unchanged:
  `to:` and `end:` stay free).

`$` and `${` are plain text (owner, 2026-10-16): `` `${x}` `` prints `$`
and then the slot.

## Text over several lines: one margin rule (revised)

- **A backtick that ends its line opens a multi-line template.**
- **`"""` (escaped) and `'''` (raw) open fixed multi-line text** only when
  the opener ends its line (2026-11-07, default 5). Mid-line, `'''abc'''`
  keeps today's meaning (a raw string with doubled quotes, `'abc'`), and
  `"""abc"""` stays rejected. Rig's test files' `'''` results move to the
  same rule by a script after T1.
- In all three, the **closing delimiter's column sets the left margin**,
  by October's approved rules:
  - the content starts on the line after the opener; the newline after
    the opener and the newline and spaces before the closer are dropped;
  - every content line keeps the spaces it has beyond the margin, the
    first included;
  - a non-blank line shallower than the closer is an error;
  - a line of only spaces becomes an empty line;
  - trailing spaces after text are trimmed (a space meant to stay is
    `\x20`);
  - a tab in the margin is an error, and so is a lone CR; CRLF becomes LF;
  - code continues right after the closer (`` `) ``);
  - slots stay on one line;
  - shifting a whole template never changes its value (a tested
    property), and `rig fmt` never changes a template's value.
- The wrapper lexer emits the whole template as tokens, so layout never
  sees its inner newlines.

## Lexing: real tokens, no re-parsing

The Lexer wrapper (Nexus's lang module) emits real tokens and keeps a
stack of open templates:

| Token | Text | Example in `` `a{x}b{=y}c` `` |
|---|---|---|
| `TPL_HEAD` | from the opening backtick to a slot's `{` | `` `a{ `` |
| `TPL_MID` | from a slot's `}` to the next slot's `{` | `}b{` |
| `TPL_TAIL` | from the last slot's `}` to the closing backtick | `` }c` `` |
| `TPL_SHOW` | the `=` touching a slot's `{` | `=` |

Between them the slot's tokens are Rig's own, so nested strings, `??`,
sigils, diagnostics, hover, and highlighting work in a slot as anywhere.
The base lexer reads a backtick as one `backtick` token, which the
wrapper never hands the parser. Python rewrote its f-string grammar (3.12)
to get here; Rust's slots take only names.

The parser makes `(template ...parts)`: a text leaf (the token, its
delimiters included, decoded by one function), then a slot, then a text
leaf, alternately, first and last a text leaf (empty pieces included). A
slot is its expression, or `(show eq value)` for `{=e}`, whose `eq` leaf
and the next text leaf bound the label's source.

## Lowering

- **print, warn, panic, add, String:** the template's pieces join the
  call's tuple of pieces (`emitPrintArgs`) with no separators between
  them; print's separators go only between the call's own arguments.
  The runtime already merges each run of constant text into one write
  (`piecesOf`) and writes each value by its type's one writer. A show
  slot is its label, a text piece, then `rig.shown(&v)`, which writes
  `v` as a part of another value (`writeValue(w, v, false)`).
- **A `?String` temporary:** a storage fact (`src/storage.zig`) names
  the template and its hidden buffer. Emit writes the buffer, a
  `rig.TextBuf` of 256 bytes, beside the statement's other temporaries,
  renders the pieces into it (spilling to one heap block past 256
  bytes), reads its bytes as the view, and drops it where the statement's
  temporaries drop.
- **A `String`:** `rig.String.of(.{ pieces })`, `String(...)`'s lowering:
  one exact allocation.
- **Folded:** a fact holds the bytes; emit writes them as one literal.

## What T1 does not do

T2's formatting methods; the template parameter type (a statement-scoped
read view of the slots, after T1); the inline wrap W; a print hook;
typed-slot consumers such as SQL binding; `net.connect(host, port)`
(IPv6 breaks host:port text, as Go's `JoinHostPort` shows: its own std
PR); `+"ada"` making a String where one is expected (raised separately).
`String(a, b, ...)` and `!t.add(a, b, ...)` stay through the templates
release; the owner decides later whether variadic `String(...)` goes
(a migration script, and Trig told first).

## Stages

One PR each, green on its own:

- **T1a:** this record; SPEC, SYNTAX, and CORE §3 text with `rig pending`
  examples.
- **T1b:** lexing and parsing; `print`, `warn`, `panic`, `add`, and
  `String` splicing; the show form; the `?String` temporary; the
  `String` place; folding. Tests first, in `test/rig/templates.rig.test`:
  a `test` case for each rule, a `fail` case for every error, a grid of
  slot kinds by callers, and a rejection for every view of a temporary
  that could escape, sanitizer clean.
- **T1c:** `"""`, `'''`, and multi-line backticks under the margin rule.

Each stage turns its pending examples into ordinary ones and adds its
CHANGELOG lines. Gates per PR: the core suite, `tools/emit-diff
origin/main` unchanged for programs with no template, the check guard
within 2%, the json guard if print's lowering moves; Trig's and loco's
light gates.

## Nexus

`@highlight` needs a region for a template whose slots hold the
top-level items (TextMate `include: $self`, an hljs SUBST mode, a Vim
cluster), so the sigils inside slots stay coloured; the escapes `\{`,
`\}`, `` \` `` within it; `"""` and `'''` regions for T1c. It is the
owner's Nexus work; each PR says what it needs.

## The owner's decisions behind it

- 2026-10-16: slots (not holes); a lone `}` is an error; `{=e}`
  escapes control characters, `print` and `warn` write bytes; template
  parameters after v1; floats' default form; `pad` counts chars; EPIPE
  exits 0; objects print every field; one escape table; dead keys
  accepted; the show form `{=e}` (prefix, trimmed, fixed ` = `); `$` is
  plain text; multi-line in v1 under the closer's column; the panel's
  strict items 1-11, trailing spaces trimmed.
- 2026-11-07, "Approve the seven defaults": templates go where text is
  read or stored, the place decides; the stored form needs no mark; a
  backtick with no slot is an error; the temporary's 256-byte stack
  buffer, then the heap; `"""` and `'''` only when the opener ends its
  line, `'''abc'''` unchanged mid-line; `String(...)` and `!t.add(...)`
  kept through the release; build T1 next.
