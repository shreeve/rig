# Riff: string templates, "show the expression", and the inline wrap

Design study, 2026-10-16. Nothing here is built, and nothing is decided:
every spelling is the owner's to choose. This follows
[proposal-panic-print.md](proposal-panic-print.md), which settled `print`,
`warn` and `panic` and left the debug form open. The owner rejected `dbg` as
a name and as "a magic function that reads source code". He wants:
- interpolation;
- a way to show an expression's own text;
- an inline wrap that prints a value and gives it back.

All three should be syntax.

Four experts riffed independently on the same brief:
1. a Python/Ruby/JS programmer;
2. a Rust/Zig/C systems programmer;
3. a least-surprise language designer;
4. a reader of typecheck and the ownership checker.

The inline wrap (item g) arrived mid-riff as owner input; all four answered it. Their probes are in the session scratchpad,
`riff/{python,systems,designer,ownership}/`, and ran against `a5a991366` on
the Mac. Examples marked *proposed* use forms that do not exist and were not
run.

---

## 0. The fact that decided most of it

Today, inside `"…"`, every backslash sequence that is not a listed escape
is a **compile error** (typecheck's `checkEscapes`). Every other candidate
marker is plain text that **runs and prints literally**. All four experts
found this independently, and the lead re-ran it:

```
print("\(x)")             error: invalid escape `\(` in a string; the escapes are `\n`, ...
print("\{x}")             error: invalid escape `\{` in a string; ...
print("@{x} #{x} {x}")    @{x} #{x} {x}          (accepted today)
print({x})                unexpected `{`; Rig has no braces
total = @{a} + 1          the pin sigil `@x` is reserved; `@` only starts a builtin call
y = \{x} + 1              invalid character
```

So a backslash marker turns only rejected programs into accepted ones. Any
of `@{`, `#{`, `{`, `$"…"` or `f"…"` would silently change what running
programs print. That is not hypothetical. Trig has three live strings
that `@{` would rewrite, in `src/diagnostics/diagnostics_generated.rig`:
- line 9268: `"… write '@{0}()'?"`;
- line 10773: `"JSDoc '@{0}' …"`;
- line 10774: `"JSDoc '@{0} {1}' …"`.

Under `@{`, each would print `0` where it prints `@{0}` today.

> "The best interpolation marker is the one that's a compile error today."
> (Python/Ruby/JS)

A second point all four agree on: **a hole is a print argument.**
- `print(v, grow(!v))` is already rejected today ("cannot lend `v` to write while an earlier argument's read of it is in use"). That is exactly the hazard the corpus probes `t-q5` and `review-never-data-1-d07_interp` were written for.
- Every argument is already evaluated before any byte is written. A failing `parse(s)!` therefore prints nothing and leaks nothing.

Templates inherit both properties for free.

---

## 1. Shortlist

All three designs share the same rules for everything but the marker:
- **The pieces.** A template is `String`'s argument list written inside the quotes: no separators, holes evaluated left to right, only read, and temporaries dropped at the end of the statement.
- **Where it may stand.** Only as an argument to `print`, `warn`, `panic`, `String(...)` or `!t.add(...)`. It is never a value.
- **Showing the expression.** `=` at the end of a hole shows the hole's source text.
- **Formatting.** Formatting goes on values (§4), not into a mini-language.
- **The wrap.** The inline wrap is the same marker used as an expression.

### A. `\(e)`: Swift's hole, and the same form as the wrap (recommended)

The designer's first choice. The Python expert ranks it second; the ownership and systems experts rank it third.

One rule: inside a double-quoted string, a backslash already means "what follows is not literal text". `\n` is a newline, `\u{e9}` is é, and `\(e)` is a value. Outside a string there is no text, so `\(e)` shows `e` where it stands (on stderr) and is `e`.

```rig
print("\(price * qty=) \(tax=)")       # price * qty = 1250 tax = 80
print("hello, \(name)!")               # hello, ada!
print("\(name=) \(nick=)")             # name = "ada" nick = none
warn("retrying \(path) (\(n) of 3)")   # stderr: retrying a.txt (2 of 3)
panic("bad index \(i=), \(v.len=)")    # main.rig:9:3: panic: bad index i = 7, v.len = 4
msg = String("user \(u.name) is \(u.age)")
print("{\"a\": \(n)}")                 # {"a": 3}   (JSON braces untouched)
print("literal \\(x), '\(x)'")         # literal \(x), '\(x)'   (raw strings take no holes)

total = \(price * qty) + tax           # stderr: main.rig:7:9: price * qty = 1250
n = \(parse(s))!                       # shows the T! (value or error), then propagates
for x in \(xs)                         # stderr: main.rig:9:10: xs = [1, 2, 3]
\(state)                               # a statement: shows, reads, discards
```

What it buys:
- Nothing that runs today changes.
- No new escape character and no new kind of string.
- `@` stays "ask the compiler about a type".
- Braces stay free for the floated tuple `{a, b}`.
- Parentheses already mean "run-time grouping".
- The wrap is a primary like `(e)`, so postfix forms compose honestly: `\(parse(s))!` shows the fallible value, while `\(parse(s)!)` shows only the success.

What it costs:
- A nested call is paren-heavy: `"\(f(g(x)))"`.
- It reads as Swift.

### B. `\{e}`: Java 21's hole, braces as f-strings taught

The Python expert's first choice. The designer and the ownership expert rank it second, and the systems expert ranks second "`\{e}` in strings, with `@{e}` as the wrap".

Same rule as A. It rhymes with `\u{e9}`, which already puts braces after a backslash, and it uses the braces that Python, C#, Rust and JS taught.

```rig
print("\{price * qty=} \{tax=}")       # price * qty = 1250 tax = 80
print("hello, \{name}!")               # hello, ada!
warn("retrying \{path} (\{n} of 3)")
panic("bad kind: \{k=}")               # main.rig:4:3: panic: bad kind: k = .func
s = String("sum \{a + b}!")            # sum 5!
!s.add(" and \{a * b}")
print("{\"a\": \{n}}")                 # {"a": 3}
total = \{price * qty = } + tax        # the wrap, in the Python expert's spelling
```

Costs:
- It puts `{` into the expression grammar exactly where the floated tuple wants it. Is `\{a, b}` a wrap of a tuple or a mistake?
- A tuple inside a hole stutters: `"\{{a, b}}"`.

### C. `@{e}`: the owner's sketch, made safe

The first choice of the ownership and systems experts. The Python expert and the designer rank it third.

```rig
print("@{price * qty=} @{tax=}")       # price * qty = 1250 tax = 80
print("hello, @{name}!")
s = String("sum @{a + b}!")
print('@{a}', "\@{a}")                 # @{a} @{a}   (raw strings, and a new \@ escape)
total = @{price * qty} + tax           # stderr: main.rig:7:9: price * qty = 1250
v = @{parse(s)}!
```

It needs two guards:
- A hole that is only a literal, such as `"@{0}"`, must be rejected ("write it in the text, or `\@{0}`"), so that Trig's three strings fail loudly instead of changing.
- A new escape, `\@`, is needed.

For it:
- It does not touch the backslash.
- It reads as "compiler, splice here". The systems expert would amend the mantra to: "`@` is the compiler speaking: about a type (`@size(T)`), or about your source (`@{e}`)."
- The same marker in both places is the owner's own idea.
- `"…{…}…"` text, JSON, Trig's `{0}` placeholders and the corpus probes all stay literal.

Against it:
- The mantra, in the compiler's own words, is that `@` only starts a builtin call that asks about a type. A hole is work done on a value at run time.
- The reserved pin `@x` sits one character away, with an unrelated meaning.
- It changes the output of running programs silently, except where the literal-hole guard happens to catch it.

### Considered and dropped by all four

- **Bare `{…}` arguments**, `print({price * qty}, {tax})`. They spend Rig's only free bracket on a meaning that exists only in print, and `print({a, b})` collides with the floated tuple. `warn`, `panic` and `String` would each need the form again.
- **A prefix, `f"…"` or `$"…"`.** One letter changes what every `{` means, so JSON samples would need `{{` doubling. A forgotten prefix silently prints `{x}`. It also adds a second kind of string.
- **`#{…}`.** `#` is the comment character, and the change is silent. Reviewers already tried `#{` in `d07_interp` expecting it to work.
- **Backticks.** A third kind of quote, for no gain.
- **A postfix wrap, `e=` or `(e)=`.** `total = price * qty= + tax` has no clear scope, and `(x)= +1` against `x += 1` is a typo magnet.
- **A prefix debug sigil, `=e`.** Rig's sigils are ownership. This isn't.

---

## 2. What each expert said

**Python/Ruby/JS.** Ranking: `\{`, then `\(`, then `@{`, `#{`, a prefix, bare `{`, backticks.

> "Python spent from 3.6 to 3.14 learning that a template is not a string.
> Rig can start at 3.14."

> "The best interpolation marker is the one that's a compile error today."

- **The `=` form.** `=` is "the most loved debug feature of Python 3.8", and it covers "about 90% of dbg".
- **The wrap.** "The unifying mark is `=`, not the brace": the marker says "code here" and `=` says "say what I wrote". The owner's `@{e}` has one spelling with two meanings: value only inside a string, text and value outside. So the Python expert's wrap is `\{e = }`, with `=` required.
- **Leftover wraps.** A CI flag, `rig check --no-wrap`, like Clippy's `dbg_macro` lint.
- **Nested quotes.** `"\{name ?? "anon"}"` must work from day one (the PEP 701 lesson).

**Least-surprise designer.** Ranking: `\(`, then `\{`, `@{`, a prefix, `#{`, backticks; no bare `{`.

> "Inside a double-quoted string, a backslash already means 'not literal
> text'. `\(x)` just lets that text be any value, and outside a string,
> where there is no text, it shows the value where it stands."

- **The `=` form.** The label is the source exactly as written, trimmed, never normalized: normalizing would need a pretty-printer for every form, and surprises anyone who greps for what they typed. The separator is always ` = `. The value is written as `print` writes a nested value, so strings are quoted (`name = ""` is visible) and `none` shows.
- **Grammar.** `hole := '\(' expr '='? ')'`. It is conflict-free, because an `=` directly before `)` cannot be an assignment.
- **Lexing.** The lexing belongs in the `src/rig.zig` wrapper, where the Nexus lang module is extensible. It emits STRING_HEAD, MID and TAIL tokens, counting parentheses. A string, holes included, lives on one line, so layout never changes. Highlighting gets real tokens inside holes: the `!` in `"\(grow(!v))"` is coloured.

**Ownership checker reader.** Ranking: `@{` with literal holes rejected, then `\{`, then `\(`.

> "A hole is a print argument that lives inside the quotes. It is no more
> and no less, and the checker already knows how to read one."

- **No restrictions inside holes.** Banning `<` or `!` inside a hole would be "the first exception list".
- **"Stream".** It must mean *no allocation*, never *evaluate while writing*. Lazy holes would print half lines.
- **The wrap is a different fact.** It is decision 7 (b): a one-leaf branch, plus a storage fact so a place is evaluated once. It must not share a classifier with the hole, because the hole needs none. They share the marker, the lexer split, the span text and `writeValue`.
- **Why rank `@{` first.** No clash with JSON's `{`, and one marker serves both uses. The literal-hole guard covers Trig's strings.

**Rust/Zig/C systems programmer.** Ranking: `@{` in both places, with the constant-hole guard; then `\{` in strings with `@{` as the wrap; then `\(`, a prefix, `#{`.

> "A template is not a string; it is print's argument list written inside
> the quotes, so it costs what print costs, allocates only where `String`
> says so, and is checked as exactly the arguments it becomes."

- **The holes are free.** Rust allows only names inside its holes because `format_args!` re-parses a string token. Rig's own grammar parses the hole, so a hole may hold any expression and keeps exact positions for its diagnostics.
- **Never hand a spec to Zig's `std.fmt`.** Probed: `{d:5}` of an `i64` 42 prints `  +42`, and `{d:0>5}` prints `00+42`. Rig's `Int` is `i64`, so every padded Int would grow a plus sign. Rig needs its own small writers; the prototype `putInt` prints `[   10] [-0010] [10   ] [0000beef]`.
- **Change print's lowering, whatever the syntax.** Today `rig.print(.{...})` compiles once per call site. With 200 print lines, ReleaseFast grows by 387K, about 1.9 KB a site. Straight-line code, with merged literals and one `noinline` writer per type, grows by 34K, about 0.17 KB a site. Its output is byte-identical (`cmp`), and a 5,000,000-line loop ran within 6%.
- **The wrap's lowering, probed in ReleaseFast.** `(blk: { const p = &xs[f()]; rig.peek("w.rig:5:7", "xs[f()]", p.*); break :blk p.*; })` printed the right line and called `f` once.
- **Specs in v1.** A small Rig-owned spec, `@{e:[fill][<^>][0][width][.prec][x|X|b|o|e]}`: checked against the hole's type at compile time, literal widths only, each spec a call to one shared runtime writer. Text widths would count chars, which needs an owner decision.
- **Leftover wraps.** `rig build --release` prints a note listing them, never an error.

---

## 3. Where they agree

- **A template is not a value**, and is never a lazy `?String` ("a hidden cost wearing a familiar type"). `t = "x=\(x)"` is rejected with a hint: `String("x=\(x)")`. Keeping one is visible.
  - Later, a template parameter type (`Fmt`, `Template`) could serve lazy loggers, injection-safe queries, and Trig's 8 panic wrappers that build a String only to stop. It waits until Trig asks.
- **The desugaring** fits the Core in one phrase. CORE §3's reading list becomes "a `print` or `String(...)` argument *or template hole*". It adds no fact and no classifier:
  - In `String(...)` and `!t.add(...)`, the pieces are spliced flat: `String("a=\(a)!")` is `String("a=", a, "!")`.
  - In `print`, `warn` and `panic`, the template is one argument written piece by piece with no separators, `rig.tpl(.{ "a=", a, "!" })`. It makes no String.
  - `\(e=)` adds the compile-time piece `"<source of e> = "`, so `e` is still evaluated once.
- **Every hole is evaluated before any byte is written.** This is today's print behaviour. A failing `\(parse(s)!)` prints nothing and leaks nothing. Pin it with a test: a failing hole after a hole that makes a String prints nothing and leaks nothing.
- **Escapes.**
  - `{`, `}`, `@{`, `#{` and `$` stay plain text under A and B.
  - A literal marker is `"\\("` (or `"\\{"`).
  - Single-quoted `'raw'` strings take no holes.
  - There is no `{{` doubling.
- **The wrap is its operand.** This is decision 7 (b) of the panic/print study, now with syntax instead of the name `dbg`:
  - `\(xs)` only reads, so Ruby's `p xs` habit works.
  - `y = \(v)` is rejected exactly as `y = v` is.
  - `\(<v)` shows the value, then moves it through.
  - `\(?v)` shows the value, then lends.
  - A place is evaluated once, so `\(xs[f()])` calls `f` once.
  - `\(!v)` is rejected in v1 ("show `v` on the line after").
  - `print(\(a), \(b))` writes two stderr lines, then the stdout line.
- **The wrap stays in every build mode.** "A marker asks for speed, never for meaning": stripping the wrap would change what runs.
- **No Zig `std.fmt` spec ever reaches a Rig value's output.** Whether Rig has specs at all is disputed (§4).

## 4. Where they disagree

| Question | Positions | Lead's resolution |
|---|---|---|
| The marker | Backslash: `\(` (designer), `\{` (Python). `@{` with constant holes rejected (ownership, systems). A 2–2 split | `\(`; see §5 |
| May a string hole hold `<x` or a writing call `grow(!v)`? | Reject both, "compute it on its own line" (Python). Allow both: the hole is a print argument, `print(grow(!v))` is legal, and a ban would be the first exception list (ownership, designer) | **Allow.** The hazard the probes feared, a read and a write of one value in one line, is already rejected by the argument rule. The sigil stays visible and highlighted inside the hole. `\(!v)` alone is rejected, as `print(!v)` is. |
| The `=` label's spacing | Verbatim, including the `=` and its spaces, as Python does (`\{tax=}` gives `tax=80`) (Python). Trimmed source, then always ` = ` (designer, ownership) | **Always ` = `.** It matches the owner's own sketch (`tax = 80`), and the output doesn't depend on how the source was spaced. |
| `=` in the wrap | Required, `\{e = }`, so that `=` always means "say what I wrote" (Python). Implied: outside a string `\(e)` always writes the label, and `\(e=)` is a diagnostic (designer, ownership) | **Implied.** A wrap that shows no label has no use, and the common case should be the shortest one. The rule reads "inside quotes it's text; outside, it's a report". Owner decision 3. |
| Formatting | Methods returning a small value `print` writes, `price.fixed(2)`, `p.hex(width: 8)`, `name.pad(10)` (designer). The same as functions, `fixed(x, 2)` (Python). A small Rig-owned `:spec` in v1, checked at compile time (systems). Compile-time `:spec` text later, never a run-time width (ownership) | Methods first: "a method, when the value is the subject", and they work outside strings too. Reserve a top-level `:` in a hole now, with "format specs are not built; write `x.fixed(2)`". If the owner wants specs, take the systems expert's: Rig's own, compile-time, never passed to `std.fmt` |
| Leftover wraps in release | A `rig check --no-wrap` lint (Python); `build --release` refuses wraps without `--allow-show` (designer); a `rig check --shows` listing (ownership); a note from `build --release` listing them (systems) | A listing and an opt-in lint; never a mode-dependent `rig check`. Owner decision 5. |
| A tuple inside a wrap | `@{{a, b}}` (ownership, under C) | Under A it is `\({a, b})`, with no ambiguity |

---

## 5. Recommendation

**Design A, `\(e)`, in both places.** This is the lead's call on a panel split 2–2. The `@{` side is strong: two experts chose it, and it is the owner's own idea. What decides it is a mantra: "It's better to dissolve a problem than to solve it."
- Under a backslash marker, a silent change of meaning cannot happen: every existing use is a compile error.
- Under `@{`, the change is solved by a guard. A constant hole is rejected, which catches Trig's `'@{0}'`. But a hole naming a variable in scope, such as `"@{user} joined"` in ported text, still changes silently.

C is the close second. If the owner prefers `@{`, take it with the systems expert's guard and mantra clause.

1. **Inside a string,** `\(e)` writes `e`'s value and `\(e=)` writes `source = value`.
   - A template stands only where `print`'s argument list goes: `print`, `warn`, `panic`, `String(...)` and `!t.add(...)`.
   - It desugars into the format arguments the checker already reads.
2. **Outside a string,** `\(e)` writes `file:L:C: source = value` to stderr and is `e`. That is decision 7 (b), spelled as syntax. It replaces `dbg` completely.
3. **Formatting** is done by methods on values, not a spec language. `:` is reserved inside a hole.

Why A over B:
- It is equally safe: both are compile errors today.
- It keeps braces out of expressions, so the floated tuple stays unambiguous.
- Parentheses already mean "run time" in Rig.
- The wrap reads like what it is, a parenthesized expression with a mark: `total = \(price * qty) + tax`.

Why A over C:
- C silently changes running code (Trig's `'@{0}'` strings), and needs a guard and a new escape to contain the damage.
- C spends `@` against the mantra the compiler's own error message states.

The owner's instinct holds under A: one marker serves both the string and the wrap. The experts only moved the marker from `@` to `\`.

**The owner's sketches, under A:**
- `print({price * qty}, {tax})` becomes `print("\(price * qty=) \(tax=)")`, which prints `price * qty = 1250 tax = 80`.
- `print("@{price * qty}, @{tax}")` becomes `print("\(price * qty=), \(tax=)")`, which prints `price * qty = 1250, tax = 80`. The comma is text, and the labels come from `=`.

---

## 6. The owner's decisions

1. **The marker.**
   - **Recommend `\(e)`.** It breaks nothing that runs, keeps `@` and braces free, and matches the escape rule.
   - The alternatives are `\{e}` (familiar braces, same safety) and `@{e}` (needs the constant-hole guard, `\@`, and a mantra clause; two experts' first choice).
2. **The `=` form.** Recommend:
   - the label is the source exactly as written, trimmed;
   - then always ` = `;
   - then the value written as a nested value, so strings are quoted and `none` shows.
3. **The wrap's label.** Recommend implied: outside a string, `\(e)` always writes `file:L:C: source = value`, and `\(e=)` there is a diagnostic. The alternative is to require `=` in both places, which is one rule but costs a character every time.
4. **Holes and effects.** Recommend that a string hole takes any expression a `print` argument takes, `<x` and `grow(!v)` included. Today's argument rule already rejects a read and a write of one value on one line.
5. **Leftover wraps.** Recommend that the wrap stays in every mode, with `rig check --shows` to list wraps and an opt-in flag to reject them in CI. The designer's alternative is that `build --release` refuses wraps unless `--allow-show` is given.
6. **Formatting.** Recommend methods (`x.fixed(2)`, `x.hex(width: 8)`, `s.pad(10)`) in a later round, with a top-level `:` in a hole reserved and rejected now. The alternative is the systems expert's compile-time spec. If chosen, text widths must count chars or bytes; the owner picks which.
7. **Templates as values.** Recommend no. A later `Fmt` parameter type waits for Trig.
8. **Print's lowering.** Recommend straight-line writes into one shared writer per type, about 11 times less code per print site in ReleaseFast. It is independent of the syntax, and lands before T1 so templates lower the new way.

---

## 7. Build order

The templates come first. The wrap follows as its own round. Nothing here
should open while another ownership branch is open (AGENTS: one branch at a
time per fact or classifier).

| Round | What | Gate |
|---|---|---|
| P | Print's lowering: straight-line writes with merged literals and one `noinline` writer per type, in place of `rig.print(.{...})` per site. Output must be byte-identical, and the JSON benchmark guard must show it is no slower | fast gate, plus the bench guard |
| 0 | Prerequisites from the panic/print study: `warn` and `panic` (round A there). `print` must also quote strings nested inside other values (round C there), which `=` needs for `name = ""` | fast gate |
| T1 | Templates. In the lexer wrapper (`src/rig.zig`), STRING_HEAD, MID and TAIL tokens with real offsets, one line per string, and grammar highlight rules. The template in `print`, `warn`, `panic`, `String` and `add`, through `checkFormatArgs`; `rig.tpl` in the runtime; `\(e=)` labels from the span text; reject a template anywhere else, a `:` spec, `\(a = b)`, an unclosed hole and a hole that crosses a line. One phrase in CORE §3 (through the CORE change process) and the desugaring in INTERNALS. New-spelling versions of the t-q5 and d07 probes in `test/corpus/`, and the test that a failing hole after a String-making hole prints nothing and leaks nothing | fast gate, plus a grid over holes × the five callers. It adds no classifier |
| T2 | Formatting methods (`fixed`, `hex`, `pad`) as small values that `print` writes without allocating | fast gate |
| W | The wrap `\(e)` as an expression: decision 7 (b)'s one-leaf branch, the storage fact that evaluates a place once, the `file:L:C:` report, the rejection of `\(!v)`, and a grid over `\(e)` for every form and context | full matrix; the only ownership branch open. If it needs a second soundness round, it stops and falls back to decision 7 (a), checking it as an identity call |
