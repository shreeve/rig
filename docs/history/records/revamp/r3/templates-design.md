# Backtick templates: how not to screw it up

2026-10-16. A synthesis of six expert reports, one per lens: historian, safety, systems,
ownership, lexing/editors/docs, usage survey. Raw reports: tasks a4a5d82d63d8f94e4,
a3b7721b52dd41f7c, ace12b9bd6e3cfafb, aa05fa75b158a27a7, a4c26944fd6120773,
a365dbdd5cfc599b9. Probes: scratchpad/tpl/*.

## The nugget

A backtick is an invalid character in Rig today, so a backtick string is a new
kind of literal with no history. `` `hello, {name}!` `` can be
JavaScript's shape (pieces of text with values between them) without changing
any program that runs today. Ordinary `"…"` strings never gain slots.

## Seven ways to screw it up, and the guard for each

1. **Making a String too early.** Python needed t-strings (PEP 750) to undo
   this. Java previewed string templates and withdrew them in JDK 23. Guard: a
   template is never a value. It stands only where print's argument list goes
   (`print`, `warn`, `panic`, `String(...)`, `!t.add(...)`). Anywhere else it is
   an error that says to write `String(...)`. This keeps a template parameter
   type possible later.
2. **Text from run time becoming a template.** This is the bug behind C's
   format-string attacks and Log4Shell. Guard: a template exists only as a
   backtick literal in source. Its pieces are fixed at compile time. Nothing
   turns run-time text into a template, and a slot's value is written, never
   searched again for slots.
3. **Lexing slots as a substring and re-parsing them.** Python had to rewrite its
   f-string grammar over this (3.12), and Rust's slots take only identifiers.
   Guard: the lexer wrapper (Nexus's lang module) emits real tokens: TEMPLATE,
   HEAD, MID and TAIL, with a stack of brace kinds. Slots are real code, so
   nested strings, `??`, sigils, diagnostics, hover and highlighting all work
   from day one.
4. **A brace escape chosen after JSON-like text exists.** C# and Kotlin each
   added special string forms just to print `{`. Guard: a literal brace is
   `\{` and `\}`, with no `{{` doubling, so `{{a, b}}` stays free for the
   tuple idea. An empty slot `{}` is an error.
5. **Lazy, skipped or interleaved slots.** C# handlers can skip evaluating
   slots, and lazy slots print half lines. Guard: every slot is evaluated
   once, left to right, before any byte is written. A failing slot prints
   nothing and leaks nothing. For the checker, the slots are flat argument
   positions, so `` !t.add(`{t}`) `` and `` `{v} {grow(!v)}` `` are rejected by
   today's argument rule.
6. **A format mini-language.** Go needs `vet`, Rust spent `:` on one, and
   Zig's `std.fmt` changes between releases (`{d:5}` prints `+42`). Guard: a
   top-level `:` in a slot is reserved and rejected. Formatting comes later as
   methods (`x.fixed(2)`, `n.hex(width: 2)`, `s.pad(10)`). No Rig value is ever
   written through a `std.fmt` spec.
7. **Freezing today's value rendering.** Templates will make `{x}` common, and
   whatever it prints becomes permanent. Today `print(["a\"b"])` prints
   `["a"b"]`, and `print(1.5e300)` prints about 300 digits. Guard: fix nested
   string escaping and the default float form before templates ship.

## The v1 shape (all six agree)

- `` `text {e} text {e=}` `` gives the pieces with no separators, which is
  `String(...)`'s rule, not print's spaces.
- Escapes are the `"…"` table plus `` \` ``, `\{` and `\}`. An unknown escape
  is an error. A `"` needs no escape inside backticks, which is the single
  biggest readability gain the survey found (244 `\"` in Trig).
- A slot takes exactly what a print argument takes, with no exception list.
  The Core gains one phrase in §3 ("or a template's slot"), and the
  desugaring goes in INTERNALS. No new fact and no new classifier.
- `{e=}` adds a compile-time label: the source of `e` as written, then the
  value. Strings are quoted and `none` is visible. The exact spacing is
  decision 1.
- A template, slots included, sits on one line in v1. A raw newline is an
  error, and multi-line comes later under Swift's closing-delimiter rule.
- These are errors: a slot holding only a literal (`{0}`, which catches
  ported `{0}` text), `{}`, an unclosed slot or backtick, and `:` at the top
  level of a slot.
- Lowering: merged constant writes plus one shared `noinline` writer per slot
  type, with no allocation in print, warn or panic. `` !t.add(`…`) `` makes
  the same pushes as the variadic `add`. This is checked by the JSON bench
  guard and a code-bytes-per-site bound.
- `rig fmt` never edits anything between backticks.
- Trig's run-time `{0}` catalogs stay a library function and are never mixed
  with templates.

## Before T1 (prerequisite rounds)

- **P:** print's new lowering, about 11 times less code per site.
- **R:** value rendering: nested strings quoted and escaped, the default float
  form (decision 7), and printability as one per-type fact.
- **F:** flushing. Stdout is flushed before stderr writes, before stdin
  reads, before spawning a process, and on every exit. `warn` makes one atomic
  write. Plus the write-error policy (decision 9).
- **Nexus:** a `@highlight` region whose slots contain the top-level items
  (TextMate `include: $self`, an hljs SUBST mode, a Vim cluster). It ships with
  T1 so the sigils inside slots stay coloured. This is for the Nexus and
  syntax sessions.
- **0:** `warn` and `panic` (the panic/print study, round A).

## Later, without breaking anything (v1 rejects all of these)

- A template parameter type (a statement-scoped read view of the slots, type
  erased, with the pieces fixed at compile time). It serves Trig's 66 test
  checks, 22 panics and a logger, called the same way as `print`.
- Formatting methods.
- Multi-line templates.
- A user print hook.
- Typed-slot consumers such as SQL parameter binding.
- The inline wrap, which is its own round and its own fact. It is spelled
  apart from the slot's `=`.

## Owner decisions

1. **The `=` label.** Either verbatim, where the spacing you type is the
   spacing you get (`{tax=}` → `tax=80`, `{tax = }` → `tax = 80`), or the
   trimmed source followed by a fixed ` = `. Four experts lean towards fixed,
   which is stable under reformatting. The owner asked earlier for "print what
   you wrote". Recommendation: verbatim, which is the owner's ask, Python's
   rule and safe because fmt never touches templates.
2. **A lone `}` in template text.** Recommendation: an error with the hint
   `\}`. It is strict now and can be loosened later.
3. **`${` in a template.** It prints `$` and then the value. JavaScript users
   expect a slot. Recommendation: reject it with a hint and write a literal
   dollar as `\$`. Loosen later if currency text hurts.
4. **Escaping in debug output.** Recommendation: `{e=}`, the wrap and panic's
   values escape control characters. `print` and `warn` write bytes exactly.
5. **The template parameter type.** v1, or later? Trig would use it at once.
   Recommendation: later, as its own round right after T1. v1's rejection
   keeps the door open.
6. **Multi-line.** Recommendation: rejected in v1, with Swift's rule reserved.
7. **Default float form.** Shortest round-trip, with an exponent beyond JS's
   1e21 and 1e-6 or Python's 1e16 and 1e-4. Recommendation: JS's thresholds,
   spelled `1e21`.
8. **Width unit for `pad`.** Bytes or chars (graphemes)?
   Recommendation: chars, since a char is a grapheme in Rig.
9. **A closed stdout pipe (`| head`).** Today the program dies by SIGPIPE.
   Recommendation: exit quietly with status 0 on EPIPE.
10. **Printing objects.** Every field by default, with an opt-out to protect
    secrets, or opt-in? Recommendation: by default, with an opt-out later via a
    print hook.
11. **One escape table.** Should `"…"` also accept `\{`, `\}` and `` \` `` so text
    moves between the two kinds of string? Recommendation: yes. It changes only
    programs rejected today.
12. **Dead keys.** Do we accept that a backtick needs an extra keystroke on
    AZERTY and QWERTZ? Recommendation: yes, with an error hint when a
    composed `è` appears where a backtick was meant.

Also from the safety lens: reject Unicode bidi control characters in all
literals (Trojan Source), and say in the docs that `Static` means "lives for
the program", not "trusted".

## Build order

P → R → F → 0 (warn/panic) → T1 (templates, fast gate plus a slots × callers grid,
with Nexus highlighting alongside) → T2 (formatting methods) → the template
parameter type → W (the wrap, its own classifier round with the full matrix).

## Owner, 2026-10-16

- Loves the design. "Holes" are now **slots**.
- Approved defaults: 2 (lone `}` is an error), 4 (`{=e}` escapes control characters; print and warn write bytes), 5 (template parameters come after v1), 7 (floats), 8 (pad counts chars), 9 (EPIPE exits 0), 10 (objects print all fields), 11 (one escape table), 12 (dead keys).
- Open, proposed by me: the show form is the prefix `{=e}` in templates and `(=e)` as the inline wrap, with the expression as typed (outer spaces trimmed), then a fixed ` = `, then the value. The owner disliked Python's verbatim suffix.
- Open: the panic format (keep `file:L:C: panic: msg`), the `${` guard, and whether multi-line templates (Swift's closing-column rule) go in v1.

## Owner, 2026-10-16 (second pass)

- **Show form:** `{=e}`, with the expression as typed (outer spaces trimmed), then a fixed ` = `, then the value. Inside a template it writes that into the output, with no location. As an expression it is the inline wrap (Rust's `dbg!`): `total = {=price * qty} + tax` writes `file:L:C: price * qty = 1250` to stderr and evaluates to the value. Braces in both places, chosen for consistency over `(=e)`. `{` is a parse error in expression position today, and `{=` can never begin the floated `{a, b}` tuple.
- **`$`:** no guard. `$` and `${` are plain text, so `` `${x}` `` prints `$` and then the slot.
- **Control characters:** confirmed. `{=foo}` quotes and escapes, and `{foo}` writes the bytes.
- **Multi-line:** in v1, with Rip's heredoc rule on a single backtick (rip/src/lexer.js heredocProcess, test/rip/strings.rip):
  - when the closing backtick sits alone on its line, its column is the left margin. Deeper indentation is kept, and a shallower content line lowers the margin to its own;
  - when the closer is inline, the margin is the shallowest content line;
  - the newline right after the opening backtick and the newline plus spaces before the closer are dropped;
  - CRLF becomes LF, and a one-line template is unchanged;
  - code continues right after the closing backtick (`` `) ``);
  - slots stay on one line;
  - the wrapper lexer emits the whole template as tokens, so layout never sees its inner newlines.
- **Chars:** confirmed for `pad`.
- **Still open:** the panic format (my recommendation is to keep `main.rig:9:3: panic: msg`).

## Final panel review (6 experts, 2026-10-16): ship, with small strict-now rules

Verdicts: ownership says ship as designed; the other five say ship with small changes. None changes the syntax. Raw reports: task w2muuwz81 (workflow wf_44dc6395-e01).

**For the owner to confirm (each is strict now and can be loosened later):**
1. Multi-line margin. When the closer sits alone on its line, a non-blank line shallower than the closer is an ERROR (Swift's rule), not a lowered margin. Rip's code has quirks: a line at column 0 is ignored, slots are dropped when measuring, and leftover spaces are kept. So we port its idea, not its code: the rule works on raw source lines, a slot counts as content, and shifting a whole template never changes its value (a tested property).
2. Multi-line whitespace. A whitespace-only line becomes empty. Trailing spaces or tabs after content are an error (hint `\x20`), because editors strip them on save. A tab in the margin is an error, and so is a lone CR.
3. A multi-line template's opening backtick ends its line, as in Swift, so a stray backtick is reported on its own line.
4. Reserve as errors: the empty template ``` `` ``` and any run of 2 or more backticks (kept for a later fenced or raw form); a name touching a backtick (``sql`…` ``, kept for tagged templates); `\` followed by a newline (kept for line continuation); a template nested inside a slot (kept for composition); `#` inside a slot; named arguments to print, warn and panic (`to:` and `end:` stay free).
5. Write errors. EPIPE exits 0 silently. Any other write error to stdout or stderr prints `error: stdout: <reason>` and exits 1. Either way it ends the program as a panic does: flush, with no drops.
6. Panic format: keep `file:L:C: panic: msg`. The path is relative to the package root, columns are in runes as in diagnostics, and only the first line of a multi-line message carries the prefix. Runtime panics get the same prefix.

**Adopted as specification and tests (no owner decision needed):**
- `{=` is one token. `{x=}` is rejected with the hint `{=x}`. `{=}`, `{ =x}` and `{==x}` are each rejected or accepted on purpose.
- The statement `{=xs}` is exempt from the "does nothing" error. It reads a place and never moves it.
- The wrap starts as a branch: a value, never a place. `size({=v})` asks for `{=?v}`. `!{=v}`, `{=v} = 3` and `{=v}.push(1)` are rejected.
- In INTERNALS, slots flatten into the caller's argument list. Slots are evaluated eagerly, which rules out lazy loggers; we say so.
- One renderer per type, with an escape flag. `{=e}`, the wrap and panic slot values escape C0, DEL, C1, bidi controls and invalid UTF-8; text pieces stay raw. A later display hook changes `{e}` only. A later field redaction mark applies to every form.
- Bidi controls (U+202A–202E, U+2066–2069, U+200E/200F, U+061C) are rejected raw in every literal, template text and comment, and allowed as `\u{…}`.
- Rig owns the float layout and the escape table; only the shortest-digits core comes from Zig. A golden table fails on any Zig upgrade.
- `warn` promises one write per line up to 4 KiB, not atomicity.
- A printed Float and the output of `{=s}` re-lex as Rig literals of the same value.
- The fmt rule becomes: "fmt never changes a template's value; it may shift all of a template's lines together".
- The IR keeps each slot's source span and show flag, for the later parameter type.
- The template parameter type will be a read view (`?`): never stored, never converted to a String implicitly. Slot kinds stay open for typed consumers such as SQL binding.
- T2 shape: the quoting renderer gets a name (e.g. `x.quoted()`); zero padding lives on numbers (`n.dec(width: 2)`); `pad` counts chars forever, and display width gets its own later name; `xs.join(", ")` is a value print writes without allocating.
- Docs harness: four-backtick fences, and template examples in `test/highlight/sample.rig`.
- The full edge-case test lists in the raw reports go into T1's test plan.

## Owner, 2026-10-16 (on the panel's items): APPROVED

1. A mis-indented line in a multi-line template (shallower than a closer that sits alone on its line) is an ERROR.
2. A line of only spaces becomes an empty line ("\n").
3. **Trailing spaces after text are TRIMMED, not an error** (the owner's change). Editors that strip them on save then change nothing. A space you mean to keep is written `\x20`.
4. A tab inside the margin is an error.
5. A multi-line template's opening backtick ends its line, and the content starts on the next line. The closing backtick's position sets the margin, so mind where it sits.
6. The empty template ``` `` ``` is an error (and runs of 2 or more backticks are reserved).
7. A name touching a backtick (``sql`…` ``) is an error, reserved for tagged templates.
8. A backslash at the end of a line is reserved for joining lines without a newline (an error in v1 unless built with T1).
9. A template inside a slot is an error.
10. `#` inside a slot is an error.
11. No named arguments to `print`, `warn` or `panic`.
- Write errors: EPIPE exits 0 silently; any other write error prints `error: stdout: <reason>` and exits 1, ending the program as a panic does. AGREED.
- Panic format `file:L:C: panic: msg` (path relative to the package, rune columns, prefix on the first line only, runtime panics alike). AGREED.
The design is complete. The build order is P → R → F → 0 (warn/panic) → T1 → T2 → the template parameter type → W.
- Owner on item 5: the first content line is measured like every other line. The closing backtick's column sets the margin, and any spaces a line has beyond the margin are kept, the first line included. So the first line may start with spaces when it sits deeper than the closer. Test it: the first line deeper than the closer keeps its extra spaces; every line deeper does too; a line shallower than the closer is an error.
