# Proposal: symbols (`:name`), and labels move off `:`

Status: DRAFT 2. Four independent reviews are folded in (§10). Nothing
here is built on `main`. The prototype lives in a scratch worktree
(detached at `8d06bfc75`). It was never pushed and has no PR.

```rig pending
w = :width          # a symbol; its id is fixed when the program is built
print(w.text)       # width
```

## 0. Summary

1. **Labels move off `:`.** The owner proposed `@name`:
   `@outer for ...`, `break @outer`, `continue @outer`. The reviews
   raised an alternative, `$name`, which gives the sigil one meaning
   (§1.7, decision S2). Both spellings check with **no Nexus
   conflicts** (§1.3). They move 618 label sites in 200 tracked files,
   plus 29 in Trig. On its own, the move removes one exception: a
   jump in a `while` header may name a label.
2. **`:name` becomes a symbol literal** of a builtin plain type,
   `Symbol`. A symbol is a `U32` id, numbered once for the whole
   program, backed by static name and hash tables. `==`, `match`,
   `.text`, `print`, Map keys, and a static lookup from text
   (`Symbol.from_text(word) -> Symbol?`) need no table and allocate
   nothing.
3. **Run-time names** that are not literals of the program go through
   a table the program owns (`hash.Symbols`, renamed from
   `hash.Interner` in PR #236). There is no hidden global table (§4.1).
   The table returns plain ids, not `Symbol`s, so every `Symbol`
   operation stays total (§4.3).
4. **Ownership:** a symbol is plain data, like a plain enum value. It
   adds no rule to the Core (§3).
5. **What argues against it** (§11): one reviewer would defer symbols
   until a real program line needs them, and land only `.text` and
   `from_text` on plain enums now. Another reviewer suggests checking
   whether string patterns in `match` would cover most of the use.

---

## 1. Labels off `:`

### 1.1 Every place a label appears

The table uses `@`. With `$`, read `$` wherever it shows `@`.

| Form | Today | Proposed |
|---|---|---|
| a labeled loop | `:outer for x in xs`, `:outer while c` | `@outer for x in xs`, `@outer while c` |
| a labeled `match` or `raw` | `:m match k`, `:r raw` | `@m match k`, `@r raw` |
| leave a labeled statement | `break :outer`, `break :outer v` | `break @outer`, `break @outer v` |
| start the next iteration | `continue :outer` | `continue @outer` |
| a jump as a fallback | `x ?? continue :outer`, `f() catch break :out` | `x ?? continue @outer`, `f() catch break @out` |
| a jump in a `while` header | rejected: `while a ?? break :o` reads `o` as the step | **allowed**: `while a ?? break @o : i += 1` |

The last row removes an exception. Today SYNTAX says a jump names a
label "except in a `while` header, where the first `:` starts the
step", and typecheck has a diagnostic for that case alone
(`test/reject/types/while_header_jump_label.rig`). Once labels leave
`:`, the header's `:` no longer serves a label. The prototype runs that
test's program correctly and sanitizer-clean, so it becomes a behavior
test.

These rules do not change:
- A label names a loop, a `match`, or a `raw` statement.
- No statement takes two labels.
- A label may repeat an enclosing label's name; the innermost is meant.
- A keyword is not a label name. Give it its own message: "a keyword
  is not a label name".

### 1.2 The grammar change (`rig.grammar`)

Three rules change. With `@`, the label's sigil is a token the rewriter
classifies, `LABEL_AT`. With `$`, it is a new lexer rule, `'$' →
dollar`, and the rewriter does nothing.

```text
stmt     = ...
         | LABEL_AT label:name stmt:stmt              → (labeled)     # or "$"
simple   = ...
         | BREAK [LABEL_AT label:name] [value:tail]    → (break)
         | CONTINUE [LABEL_AT label:name]              → (continue)
jump     = RETURN [value:value]                       → (return)
         | BREAK [LABEL_AT label:name] [value:value]   → (break)
         | CONTINUE [LABEL_AT label:name]              → (continue)
```

The `@schema` does not change for labels. `labeled label:leaf stmt`,
`break value? label:leaf?`, and `continue label:leaf?` keep their
roles, so sema, the ownership checker, and emit read the same tree.

### 1.3 Nexus conflict check

All six grammars below were generated from `main`'s and checked with
Nexus 2.3.0 (`nexus check`). The parser reviewer reran them
independently and confirmed every result.

| Grammar | Result |
|---|---|
| `main` today | no errors; 1160 states |
| **naive**: labels as `"@" name stmt`, one `@` token for both uses | **2 conflicts** (below) |
| labels only, with a `LABEL_AT` token | no errors; 1160 states |
| **`LABEL_AT` labels, plus symbols** (`":" name → (symbol)` in `atom` and `patatom`) | **no errors**; 1164 states |
| the same, with a `SYMBOL_COLON` token | no errors; 1164 states |
| **`"$"` labels (a plain lexer token), plus symbols** | **no errors**; 1164 states |
| any of the above, plus quoted symbols `":" STRING_DQ` | no errors; 1166 states |

The naive grammar's two conflicts are exactly the ambiguity between a
builtin and a label:

```text
state 393, on ")":  atom → "(" cclosure • ")"  vs  args → cclosure •
   example: "@" IDENT "(" cclosure • ")"
state 392, on ")":  atom → "(" expr • ")"      vs  callarg → expr •
   example: "@" IDENT "(" expr • ")"
```

`@size (x)` could be the builtin `@size` called on `x`, or a statement
labeled `size` whose body is the expression `(x)`. With `@`, the
rewriter settles this as it settles `STEP_COLON` and `NULLISH_JUMP`, so
the grammar keeps its no-conflicts policy without an `@conflicts`
entry. With `$`, the ambiguity never arises.

### 1.4 Telling a builtin from a label (`@` only)

The rewriter looks ahead from `@`, by position and never by spacing:

| Source | Token | Rule |
|---|---|---|
| `@size(T)`, `@type(x)` | `AT` (builtin) | `@`, a word, then `(`: the same as today (`isBuiltinCall`) |
| `@outer for`, `break @outer`, `continue @outer` | `LABEL_AT` | `@` and a name, where a statement starts or right after `break` or `continue` |
| `x = @size`, `f(@x)` | error | anywhere else, `@` without a `(` stays reserved for the pin sigil (SPEC §18) |

What this costs, all of it probed:

- **`break @l (i)`** reads as a builtin call, and the spacing rule then
  rejects it with the wrong advice ("write `l(i)`"). The value
  `((a+b)*c)` cannot follow a labeled break either. The fix is to
  bind the value first, or write `break @l i` when the value needs no
  parentheses. `@name (` right after `break` gets its own message. No
  tracked program writes this.
- **`RIG-MANTRAS.md` says "`@` asks the compiler about a type"**, and a
  label is no such question. The mantra has to be rewritten in the
  same change.
- **The pin sigil keeps every operand position**, but loses statement
  starts and the slot after a jump.
- **The label must end the way a statement's label ends.** After
  `break @o`, the next token starts an operand and is not a
  continuation of a value. The prototype got this wrong (parser
  review, finding 3): `break @o : done` slipped past the touch check.

### 1.5 The old spelling after the change

Every old label either stops parsing with a hint, or is rejected by the
checker. None changes meaning silently, because no program written
before symbols can produce a `Symbol`. The parser review confirmed this
for whole programs.

| Old source | After the change |
|---|---|
| `:outer for ...` (a statement start, then `for`, `while`, `match`, or `raw`) | rewriter error: "a label is written `@name`: ..." (prototype) |
| `continue :outer`, or a detached `continue : outer` | the same rewriter error (prototype) |
| `:c :d while` (two old labels) | the same hint: `isOldLabel` must accept a following `:name` |
| `break :outer` in a loop whose value is unused | today's checker error, "the value of this loop is not used". The change adds the label hint when the value is a bare symbol that names an enclosing label |
| `break :outer` in a value loop | a type error, because the loop's other values are not `Symbol`s, with the same hint |

The hint stays for one release, then goes.

### 1.6 Migration script plan (`tools/migrate-0.4.py`)

The script follows `tools/migrate-0.3.py`:
- `scan PATH...` reports what would change; `apply PATH...` rewrites in
  place.
- Each change is its own pass, and every pass is idempotent.
- It prints `MANUAL` lines for what it cannot decide.
- It never rewrites Markdown prose.

**The rule is on tokens, not spacing** (corrected after the parser
review). A label's `:` is a `:` at a statement start, or right after
`break` or `continue`, with any space between it and the name. Two
tracked corpus files write a detached label (`x ?? break : l`,
`break : l`), and `main` accepts them. The script scans code spans
with the 0.3 tool's `spans()`, so strings and comments are handled
apart, and rewrites that `:` to `@` (or `$`), removing the space.

In comments, the script rewrites only three label shapes, `break :x`,
`continue :x`, and `:x for/while/match/raw`, plus a backticked
`` `:x` `` on a `# error:` line. It lists each rewrite it makes.

Counts from the prototype script on `main`:

| Where | Sites | Notes |
|---|---|---|
| `test/corpus/` | 448 | including the two detached labels |
| `test/behavior/` | 111 | |
| `test/reject/` | 55 | plus 7 `# error:` expectations |
| ```` ```rig ```` blocks in SPEC and SYNTAX | 4 | |
| **code total** | **618 in 200 files** | the brief's figure of about 490 counted lines |
| comments | about 45 | listed |
| prose spans in SPEC, SYNTAX, INTERNALS, and test/README | 33 | by hand; several are Zig's `break :blk` and must stay |
| `src/typecheck.zig` diagnostics | 9 | `` `:{s}` `` becomes `` `@{s}` ``; the `while`-header diagnostic is deleted |
| `src/rig.zig` | about 12 unit tests (`expectCats`) | plus the `label_colon` and `after_jump_label` state |
| `test/matrix.py` | 19 lines | generated label forms |
| std | 0 | |
| Trig | 29, all in `src/lexer` | the owner's other repo; the same script |

Prototype result (with `@`): the grammar and rewriter change were built
and the script applied, and `./test/run` ran the 196 test files it
touched.
- **193 passed.** After two fixes to the script, the label reject tests
  pass too.
- **The one test still failing is the `while`-header reject test**,
  which is meant to become a behavior test.
- The parser review then found the two detached labels the old rule
  missed, and the `while`-step blocker in §6. No test in the repo
  covers that blocker's shape.
- **Not done in the prototype:** the full suite, the matrix, the oracle,
  and the docs. The oracle reads labels from the IR, not from text.

### 1.7 `@` or `$`

| | `@name` (the owner's proposal) | `$name` |
|---|---|---|
| meanings of the sigil | two: a builtin call and a label, told apart by whether `(` follows | one |
| rewriter | a new classification, `LABEL_AT`, plus state after a jump's label | none: `$` is a lexer token |
| `break l (expr)` | `break @l (x)` is rejected: bind the value first | `break $l (x)` works, as `break :l (x)` does today |
| mantra "`@` asks the compiler about a type" | rewritten | kept |
| the reserved pin sigil `@x` | narrowed | kept whole |
| precedent | Kotlin (`outer@ for`, `break@outer`), where `@` also marks annotations | Perl, PHP, and the shell use `$` for variables, which a label is not |
| reads as | an annotation, which is close to what a label is | a variable, at first sight |

The other spellings were considered and ruled out:
- `'outer` (Rust): `'` starts a raw string in Rig.
- `#outer`: `#` starts a comment.
- Zig's `outer:` with `break :outer`: the jump still needs `:`, which
  clashes with symbols.
- A keyword label (`for ... as outer`): `break outer` already means
  "break with the value `outer`", so the jump still needs a marker.

---

## 2. Symbol literals `:name`

### 2.1 Syntax

A symbol is `:` followed directly by a name, where an operand starts:
`:width`, `:if`, `:type`. A keyword is a fine symbol name: the rewriter
reads a word after a symbol's `:` as a name, as it does after `.` and
`@`. A symbol is also a pattern (`:width =>`).

```text
atom     = ...
         | SYMBOL_COLON name:name                     → (symbol)
patatom  = ...
         | SYMBOL_COLON name:name                     → (symbol)
@schema
    symbol                      name:leaf
```

**The token is `SYMBOL_COLON`** (parser review, finding 9). The rewriter
decides once what a `:` is, and the parser reads only that decision.
This is one classifier per fact, and Nexus checks it with no conflicts.

The rewriter's rules for `:` (corrected after the parser review):

| A `:` that... | is | Example |
|---|---|---|
| follows a value, or ends a jump (`break`, `continue`, `return`, or a jump's label), at a `while` header's bracket depth, the first such | `STEP_COLON` | `while i < n : i += 1`, `while x ?? break : i += 1` |
| follows a value anywhere else | `:` | `x: Int`, `f(a: 1)`, `?len: Int` |
| stands where an operand starts and touches a name | `SYMBOL_COLON` | `x = :a`, `f(a: :b)`, `[:a, :b]`, `:a =>` |
| stands where an operand starts and does not touch a name | error: "a prefix `:` touches its operand" | `y = : width` |

Two classifier bugs from the prototype are fixed by this table and must
not come back:
- **A bare jump before the step** (parser review, finding 1, a
  blocker): `while more(n) ?? break : n -= 1` runs on `main`, and the
  prototype read its `:` as a symbol. A jump leaves an empty operand
  slot, so the rule has to name it. A symbol given as a jump's value
  inside a header needs parentheses.
- **A keyword argument is recognized only where an argument starts**
  (parser review, finding 2). Today any word followed by `:` inside
  `( )` becomes a keyword argument's name, so `print(c or :a)`,
  `print(x if c else :b)`, and `print(not :a)` misparse. The fix is a
  positional list: a word is an argument's name only right after `(`,
  `,`, or a closure's opening bar.

Names are identifiers only. Quoted symbols (`:"content-type"`) are open
decision S6.

### 2.2 The type: builtin `Symbol`, plain

- `Symbol` is a builtin plain type. It is 4 bytes, compares with `==`
  and `!=`, and can be hashed and printed. `:width` has type `Symbol`
  wherever it stands; unlike `.width`, it is not inferred from context.
- Its values are **exactly the symbol literals of the whole program**,
  in every module, std included. This closed set is what makes every
  operation total: every `Symbol` has static text.
- **`.width` where a `Symbol` is expected is rejected**, with the hint
  "a symbol is written `:width`" (purist review, finding 5). The
  desugaring in §3 uses an enum, but a symbol has one spelling.
- It has no `<` (decision S4).

### 2.3 Representation and emitted Zig

Each module emits to its own Zig file. The program gets one more file,
`__rig_symbols.zig`, which every module that uses a symbol imports.

```zig
pub const Symbol = enum(u32) { @"height" = 0, @"if" = 1, @"std" = 2, @"width" = 3, _ };
pub const names = [_][]const u8{ "height", "if", "std", "width" };
// from_text: an open-addressed table computed by the Rig compiler (§2.6)
pub fn text(s: Symbol) []const u8 { return names[@intFromEnum(s)]; }
```

- **A module writes `:width` as a tag, `__rig_sym.Symbol.@"width"`,
  never as a number.** `U32(:width)` lowers to `@intFromEnum` of that
  tag, so adding a symbol anywhere changes only `__rig_symbols.zig`.
- **Every tag is quoted `@"..."`**, so no symbol name can meet a Zig
  keyword or a name the emitter uses.
- **The id `0xFFFF_FFFF` is reserved**, so that a later general niche
  feature can make `Symbol?` 4 bytes without renumbering. Zig 0.17 has
  no niche for optional enums: `?Symbol` is 8 bytes, as `?u32` is.
- **Every way to make a `Symbol` from a number checks it**:
  `Symbol.from_int(n)` emits `n < names.len`, since `@enumFromInt` on a
  non-exhaustive enum accepts any `u32`.

Checked with Zig 0.17.0:
- The declaration above compiles. `text` gives `width` and `@tagName`
  gives `if`.
- `@sizeOf(Symbol)` is 4.
- A `switch` that names every tag and also has an `else` compiles. The
  enum is non-exhaustive, so the `else` is never "unreachable", which
  an exhaustive enum would reject whenever a match happens to name
  every literal.
- `enum(u32) { _ }`, for a program with no symbols, compiles.

### 2.4 Whole-program numbering

- **When:** ids are assigned after every module is checked and before
  emit. This is the same point at which `src/inlining.zig` decides
  inlining for the whole program.
- **How:** one pass collects every `symbol` leaf of every module,
  removes duplicates, **sorts them by text** (bytewise), and numbers
  them from 0.
- **Why sorted:** ids are then deterministic. They do not depend on the
  order modules load in, on file names, or on which module mentions a
  name first. Two builds of the same program agree. Zig compiles the
  whole program as one unit, so renumbering costs nothing new. For
  `--delta`, it reruns the programs whose literal set changed, which is
  the same as any std edit today.
- **Not stable across programs:** ids differ between programs, and
  between versions of one program. They are never stored in files or
  sent over a wire; the text is (`.text`, `from_text`).
- **Checking needs no ids.** `rig check` types a symbol without
  numbering it. The numbering is a fact that emit reads (`Facts`), not
  a classifier.

### 2.5 Operations

| Operation | Meaning | Lowers to |
|---|---|---|
| `:width` | the symbol | `.@"width"` |
| `a == b`, `a != b` | the same name | an integer compare |
| `s.text` | its name, as a `Static` (`width`) | `names[id]` |
| `Symbol.from_text(word)` | the program's symbol spelled `word`, or `none`; allocates nothing | one hash, then a probe (§2.6) |
| `print(:width)` | `:width`, as written, as an enum prints `.dot`; a List prints `[:a, :b]` | the runtime formatter |
| `s.hash()` | the hash of the id, so equal symbols hash equal | the integer hash |
| `hash.Map[Symbol, V]`, `hash.Set[Symbol]` | keyed on the id; iterated in insertion order, so renumbering changes no output | an integer key |
| `U32(s)`, `Symbol.from_int(n)` | decision S5 | `@intFromEnum`; a checked range |
| `match s` | arms such as `:a =>` and `:a, :b =>`, guards, and a **required `_`** | a Zig `switch` with `else` |

A `match` on a `Symbol` always needs a catch-all, as on an `Int`. The
set of values belongs to the whole program, so no module could list
them, and a library's `match` would break whenever its user added a
literal. Duplicate arms are rejected, as for integers.

**`from_text` answers "is this name written somewhere in the
program?", never "is this name allowed?".** Its answer can change when
an unrelated module, or std, adds a literal. A
`Symbol.from_text(input)` that returns `none` today can return a symbol
tomorrow. SPEC must show validation as a `match` whose `_ =>` arm
rejects. This point came from three of the four reviews.

```rig pending
fun area(shape: Symbol, w: Int, h: Int) -> Int
  match shape
    :rect => w * h
    :triangle => w * h / 2
    _ => 0

sub main()
  print(area(:rect, 3, 4), area(:triangle, 3, 4), :rect)
  print(Symbol.from_text("rect") == :rect, Symbol.from_text("hexagon"))
```

```output
12 6 :rect
true none
```

### 2.6 How `from_text` is built (changed after the performance review)

Draft 1 used `std.StaticStringMap`. In Zig 0.17, that map sorts its
keys by length only, then compares every key of the input's length one
byte at a time. Nothing is hashed, so a miss scans the whole
same-length bucket.

Measured (ReleaseFast, Apple Silicon, identifier-like keys):

| Literals | StaticStringMap, miss | hash + tag table, miss | StaticStringMap, hit | hash + tag table, hit |
|---|---|---|---|---|
| 64 | 9.1 ns | 3.9 ns | 5.7 ns | 3.1 ns |
| 400 | 44.8 ns | 5.8 ns | 13.8 ns | 3.5 ns |
| 3000 | 216 ns | 9.2 ns | 130 ns | 4.9 ns |

- **Most lookups miss.** `from_text` is mostly used on input, and the
  literal set includes every std literal.
- **Comptime cost.** Building the map at comptime added 1.6 s to a
  debug build with 10,000 literals.

**The design instead:**
- The Rig compiler computes the table itself and emits it as plain
  data: an open-addressed table with a one-byte tag per slot and an id
  array, a power of two in size, at most four fifths full. This is the
  layout `hash.Symbols` uses.
- Each name is hashed with `std.hash.Wyhash.hash(0, name)`, the function
  `s.hash()` uses for text.
- `from_text` hashes once and probes. That costs about 4 to 9 ns at any
  size, with no comptime work, and it is the same in every build.
- A perfect hash would save only the tag probe, about 1 to 2 ns, so it
  is not worth it below roughly 100,000 literals.

---

## 3. Ownership

**The Core paragraph.** In CORE §1, the plain row of the table gains
`Symbol`, and this paragraph is added:

> **A symbol is plain data, one value like a plain enum's.** `:name` is
> a constant of the builtin type `Symbol`, whose values are the
> program's symbol literals. It owns nothing and views nothing: a bare
> use copies it, it carries no loan, and nothing moves, clones, or
> drops it but the rules of whatever holds it. Its text is a `Static`,
> which carries no loan either. *(planned)*

There is no exception list. Every sigil does to a symbol what it does
to a plain enum value today:
- `<s` and `+s` copy. Checked: `y = <x` on a plain enum is accepted.
- `?s` and `!s` lend the place that holds the symbol.

**The desugaring** (for `docs/INTERNALS.md`):

```text
:name               ≡ Symbol.name           a variant of a plain enum
                                             `enum Symbol` the compiler
                                             writes once per program, one
                                             variant per distinct literal
s.text              ≡ symbol_text(s)        fun symbol_text(s: Symbol) -> Static,
                                             indexing a module constant
                                             `[N]Static` of the names
Symbol.from_text(w) ≡ symbol_find(w)        fun symbol_find(w: ?String) -> Symbol?,
                                             reading only module constants;
                                             the result is plain, so it
                                             keeps no loan on `w`
match s / :a =>     ≡ a match on that enum, with its `_` arm
```

Every form on the right exists today: plain enums, `Static`, module
constants of plain arrays, and a `fun` with a plain result. So the
checker rule for symbols is the one those forms already have, which is
none.

---

## 4. Run-time names: `hash.Symbols`

The owner settled this: literals, `.text`, `==`, `match`, and the
static `from_text` need no table and allocate nothing. Making a **new**
name at run time always goes through a table the program owns,
`hash.Symbols`. The simple case, "is this input one of the names my
program knows?", is `Symbol.from_text` or a `match`, with no table.

### 4.1 Why there is no hidden global table

Ruby, Erlang, and Lisp intern into one table per process. Rig rules
that out for three reasons, each of which is one of Rig's rules:

- **Hidden allocation.** Ruby's `to_sym` on input allocates where the
  source shows no allocation. Rig has no hidden allocation.
- **Growth without bound.** A global table can never shrink while any
  symbol might still name an entry.
  - Erlang caps its atom table (1,048,576 by default), and the VM
    **crashes** when it fills. That makes `binary_to_atom` on untrusted
    input a known denial of service; Erlang's answer is
    `binary_to_existing_atom`, which is what `from_text` is.
  - Ruby leaked every `to_sym` until version 2.2 added symbol GC, and
    Rig has no GC.
  - A table the program owns is dropped with its owner.
- **Threads.** A global mutable table needs a lock on every intern, or
  it is a data race. Its ids would also depend on which thread interned
  first. A table the program owns is one value, lent to write like any
  other.

A global table would also need a drop nobody wrote: who frees it at
exit, under the leak checker?

### 4.2 The table starts out holding every literal, lazily

`hash.Symbols()` starts out knowing the program's literals: ids `0` to
`N-1` are the literals' ids, and their text is the static name table.

Draft 1 had `intern` consult `from_text` first. The performance review
measured that as about 14 times slower for a name already in the table
(at 400 literals), and that cost falls on every identifier Trig
interns.

**The design instead (lazy seeding):**
1. Hash the name once, and probe the table's own index.
2. Only on a miss, probe the static table with the same hash.
3. On a static hit, record that literal's id in the index, without
   copying its text.
4. Otherwise, copy the name into the table's one String and give it the
   next id, `N + count`.

After a name is first seen, every `intern` is one probe, as today.
Seeding costs no allocation and no setup. `text(id)` gains one branch:
an id below `N` reads the static name table.

```rig pending
use std.hash

sub main()
  syms = hash.Symbols()
  a = (!syms).intern("width")      # a literal's id: no copy
  b = (!syms).intern("depth")      # new: copied into the table
  print(syms.symbol(a) == :width, syms.text(b), syms.symbol(b))
```

```output
true depth none
```

### 4.3 What `intern` returns

**Design A, recommended by all four reviews: `Symbol` stays closed, and
a table hands out plain ids.**
- `intern(!self, s: ?String) -> Id`, `id(?self, s: ?String) -> Id?`,
  and `text(?self, id: Id) -> ?String from self`, as `hash.Interner`
  has today.
- Two bridges go on the table, not on `Symbol`:
  - `syms.symbol(id) -> Symbol?` gives the program's symbol when the id
    is a literal's. Then `match` works on it.
  - `syms.id(:width) -> Id` gives a literal's id.
- **`.text` of a name a table created:** such a name is never a
  `Symbol`. Its text lives in the table, and `syms.text(id)` reads it
  as a view `from self`. So the ownership checker already keeps that
  text from outliving the table. `Symbol.text` stays total and stays a
  `Static`.
- **`Id`** is either `U32`, as today, or a plain id type of the table's
  own, so that an id cannot be confused with a count or a List index
  (Ruby review, finding 3). That is decision S9.

**Design B: `intern` returns `Symbol`, and `Symbol` becomes an open
set.** It is simpler to call, but then a `Symbol` may have no static
text:
- `s.text` must panic for a table-made symbol ("its text is in the
  table that made it: write `syms.text(s)`").
- `==`, `from_int`, and printing all need a second story.
- Every `Symbol` operation becomes partial.

### 4.4 Misuse with another table, or after the table is dropped

**Under design A**, no table makes a `Symbol`, so no `Symbol` can be
misused with a table. A table's ids index that table, the way a List
index indexes its List:

| Misuse | Result |
|---|---|
| an id from table `t1` passed to `t2.text(id)` | in range: the wrong text, silently; past `t2`'s length: a bounds panic |
| `t1` dropped, its id kept | the id is a number, and nothing can call `t1.text` any more, because `t1` is gone; its text views died with it (`from self`) |
| ids from two tables compared | literal ids (below `N`) agree in every table; other ids mean nothing across tables |

None of these is a memory error: `text` is bounds-checked, and the
ownership checker already keeps every view of a table's text from
outliving the table. They are logic errors of the same class as an
index into the wrong List, and SPEC documents them. A distinct `Id`
type (S9) stops an id from being mixed up with other integers, though
not with another table's ids.

**Under design B**, the same misuses reach `Symbol` itself, the type
users trust most: `a == b` can be true for two different names from
two tables. Catching that would take one of two things:
- **A table serial in every symbol.** That makes a symbol 8 bytes
  instead of 4 in every program, including programs that never make a
  table. It doubles a `List[Symbol]` and takes a `Map[Symbol, V]` entry
  from 12 bytes to 16.
- **A symbol that carries a loan on its table.** Then it is no longer
  plain data, it cannot be a Map key that outlives a scope, and the
  Core gains an exception.

An 8-bit serial packed into the top bits of a 4-byte id would catch
mixing about 255 times in 256. But it caps a table at 16 million names
and breaks dense indexing, so the performance review recommends
against it too.

### 4.5 Two tables (both designs)

Two tables agree on every literal's id and on nothing else. A program
that needs one id space for all its names makes one table and lends it.

Trig already does this with `ast.Names`, one per program. It seeds that
table by hand with 18 numbered constants (`ATOM_MISSING: Atom = 1`,
...), which is the case seeding replaces. But most of Trig's seeded
names are not identifiers (`"\xFEmissing"`, TypeScript's prefix for
internal names), so `:name` cannot spell them without quoted symbols
(S6). Trig's interning is also its own `Map[String, Atom]`, not
`hash.Symbols`. **So Trig, the main workload, does not use symbols as
drafted.**

---

## 5. The name clash: Trig's `Symbol`

A builtin nominal name cannot be declared today (checked): `obj String`
gives "`String` is a reserved built-in nominal name and cannot be
redefined", and so do `Static`, `Cell`, and `Signal`. So a builtin
`Symbol` would forbid `obj Symbol` in every program.

Trig is a port of TypeScript-Go. It has `pub obj SymbolRec` and
`pub type SymbolId = U32` (src/ast/symbol.rig), and many of its
comments name Go's `Symbol`. It does not declare `obj Symbol` now, but
in a checker whose whole domain is symbols, `Symbol` is the record's
natural name.

| Option | Cost |
|---|---|
| **S1a.** a builtin `Symbol`; Trig keeps `SymbolRec` | nothing today; in a TypeScript checker, `Symbol` reads as two things forever |
| **S1b.** name the builtin `Sym` | short and no clash, but it reads as an abbreviation, and Ruby and Elixir readers look for `Symbol` |
| **S1c.** name it `Atom` (Erlang, Elixir) | Trig has `type Atom = U32` for its interned names, a closer clash |
| **S1d.** name it `Name`, `Tag`, `Key`, or `Word` | all common names for user types; `Word` also collides with the text vocabulary |
| **S1e.** let a module's own declaration shadow a builtin type name inside that module | a language change for every builtin, and a confusing one (`String` would mean two things) |

All four reviews accept S1a, `Symbol`. The purist adds that under design
A, the name promises Ruby's interning at run time, which `Symbol` does
not do.

---

## 6. The `while` header

`:` starts a `while` step: `while i < n : i += 1`. That covers 228 of
the 900 `while` lines in the repo, and 14 of 288 in Trig. With symbols:

```rig pending
while s != :done : s = next()
```

The prototype parses this as meant, and so do these: a step that is
tight against the symbol, a header with a keyword-argument call, a
symbol inside the call, a ternary, and a symbol in the step. The step
rule is the first row of the table in §2.1, including the case of a
jump right before the step, which the prototype had wrong.

Moving labels off `:` removes the other `:` that used to stand in a
header (`?? break :outer`). The header's `:` then means a step or a
symbol, and the token before it decides which.

Assessment: the parser finds it unambiguous. To the eye, it is busier
only when a symbol ends the condition right before the step.

| Option | |
|---|---|
| **W1.** keep it, and change nothing | the recommendation of all four reviews |
| **W2.** add a style note: bind the symbol (`DONE = :done`), or put it first (`while :done != s : s = next()`) | free |
| **W3.** change the step separator (`while i < n; i += 1`, `while i < n step i += 1`) | moves 228 sites, and `;` is not Rig |

---

## 7. Typos: `:widht`

A misspelled symbol is a new symbol. `:widht` compiles, compares
unequal to `:width`, and falls through to the `_` arm. An enum literal
is checked: `.widht` where a `Dim` is expected is an error.

| Use | Tool |
|---|---|
| a closed set the program defines, matched exhaustively, where a missing case should be an error | an **enum** (`.width`) |
| a set of names that is never declared in one place: names that cross modules and libraries without a shared declaration, or that are passed through code that cannot know them all, used as tags and cheap Map keys | a **symbol** (`:width`) |
| known words read from input (command words, JSON keys), turned into a name and matched | either one: an enum with `from_text` (S7) when the set is closed; a symbol when it is not |

**Draft 1's typo guard is dropped.** It would have rejected a literal
used only once. Two reviews independently showed that it rejects the
main use:
- `match Symbol.from_text(arg)` with an arm like `:help =>` uses every
  literal exactly once.
- Whether a library compiles would depend on what its callers write,
  which breaks locality.
- It is an exception list in disguise: which kinds of use count?
- It would be Rig's first lint.

**The answer to typos is the table above: use an enum when the set is
closed.** If Rig ever gets lints, a hint that names the nearest literal
belongs there.

---

## 8. Doc and test plan (when built)

**Docs:**
- **SYNTAX:** rewrite "Labels, break, and continue"; add a "Symbols"
  subsection beside enum literals; update the grammar summary.
- **SPEC:**
  - Rewrite §Labels.
  - Add a new §Symbols under types, beside Static and Enums, including
    the meaning of `from_text` (§2.5) and the misuse table (§4.4).
  - Update §17 Printing.
  - Update §18 if the pin reservation narrows.
- **CORE §1:** add `Symbol` to the plain row, plus the paragraph from
  §3.
- **INTERNALS:**
  - The token table: the label sigil and the four rows for `:`.
  - The desugaring from §3.
  - The numbering pass and `__rig_symbols.zig`.
- **RIG-MANTRAS:** update it if labels use `@`.
- **STD:** document `hash.Symbols` (§4).
- **WELCOME:** a short "coming from Ruby, Elixir, or Clojure" section:
  - `f(width: 3)` names an argument, not a symbol.
  - There is no `{width: 3}` literal.
  - `match` needs `_`.
  - Symbols share one namespace (Clojure has `::ns/kw`; Rig has no
    equivalent).
  - `from_text` is the equivalent of `String.to_existing_atom`.

**Tests:**
- Every row of §1.5 as a reject test.
- The `while`-header label as a behavior test.
- The four shapes of a bare jump before a step:
  `while a ?? break : s`, `?? continue : s`, `?? return : s`, and
  `catch break : s`.
- Symbols around `or`, `and`, `not`, `catch`, and a ternary, inside
  `( )`.
- `break @l (x)` and its message.
- Symbols in `match`, as Map keys, through `from_text`, and when
  printed.
- A pair of modules sharing a literal.
- A program with no literals.
- Keyword symbols (`:if`).
- A `pending` block for each open decision.

---

## 9. Open decisions for the owner

| # | Decision | Recommendation | Reviews |
|---|---|---|---|
| S0 | sequencing | **DECIDED by owner (2026-10-16): S7 first (enum `.text`, `E.from_text`), then symbols** | owner |
| S1 | the type's name | `Symbol` | all four agree |
| S2 | the label sigil | **DECIDED by owner: `@name`** (was: `$name`): one meaning, no rewriter rule, `break $l (x)` works, and the mantra and the pin reservation stay whole. `@name` works too if the owner prefers it: the rewriter must classify it (§1.4), and the mantra must be rewritten | Ruby and parser: `@` is sound; purist: `@` is a blocker, use `$`. This is the main disagreement (§11) |
| S3 | what `print(:width)` prints | **DECIDED: `:width`; `s.text` gives `width` once bound (`:width.text` is the symbol `width.text`)** | owner |
| S4 | `<` on symbols | **DECIDED: no** | owner |
| S5 | `U32(s)` and `Symbol.from_int(n)` | **DECIDED: no; ids stay internal** | owner |
| S6 | names with `-` and `.` | **DECIDED by owner (2026-10-16), from Rip: `:content-type` and `:content.type` are plain symbols.** A symbol is `:` + a name, then any run of `-` or `.` each followed by a letter, digit or `_` (`:utf-8`, `:a.b-c`). A symbol has no arithmetic and a literal is never a method receiver, so neither can mean anything else; `x = :content` then `x.text` (no parens, like `xs.len`). Stops at `..`, a trailing `-`/`.`, or a space. Today `:content-type` is a parse error, so no program changes. Quoted or spaced symbols (`:"x y"`) are skipped: not planned | owner |
| S7 | the lookup's name, and enums | **DECIDED: `Symbol.from_text(word) -> Symbol?` and `s.text`; plain enums get `E.from_text(word) -> E?` and `e.text`. Not `Symbol(word)`: a `Type(...)` call always makes a value, and this lookup can fail** | owner |
| S8 | a typo guard | **DECIDED: no; use an enum when the set is closed** | owner |
| S9 | run-time symbols | **DECIDED (design D): there are none. The symbols are exactly the names the program spells, numbered at build time. Run-time names are Strings (or `hash.Symbols` ids); `Symbol.from_text` is the zero-allocation bridge. No table, no intern, no clear. Adding run-time symbols later (A's bridges, or a clearable global table C) would be purely additive** | owner |
| S10 | the `while` header | **DECIDED: keep it (W1)** | owner |

---

## 10. The reviews, and what changed

Four reviewers worked independently on draft 1.

**Ruby, Elixir, and Clojure veteran.** Approve, with changes.
- The typo guard rejects the main use. → Dropped (§7).
- `from_text` depends on the whole program. → Its meaning is now stated
  (§2.5).
- Give the table its own id type. → S9.
- Don't expose the numbering. → S5 changed to no.
- Allow `<` by text order. → Recorded as a disagreement under S4.
- Quoted symbols soon. → S6.
- Write a WELCOME section. → Added to §8.
- Its worry that Map order would follow the hash is moot: Rig's Maps
  keep insertion order.
- It argues against: string patterns in `match` might cover most of the
  need (§11).

**Parser and grammar engineer.** The Nexus claims are confirmed. Labels
are sound.
- **Blocker:** a bare jump before a `while` step broke code that runs
  on `main`. → The step rule is fixed (§2.1, §6). Verified: `main`
  prints `12`; the prototype rejects the program.
- Inside `( )`, a word before a symbol misparses as a keyword argument.
  → Keyword arguments are now recognized by position (§2.1).
- After a jump's label, the rewriter treats the label as a value. →
  Fixed (§1.4).
- The migration rule leaned on spacing and missed two detached labels.
  → The rule is now on tokens (§1.6).
- Use a `SYMBOL_COLON` token. → Adopted.
- Smaller messages: a keyword used as a label name, `:c :d`, and
  `break @l (`. → Added.

**Zig and Rust systems and performance engineer.** Approve, with two
changes.
- `StaticStringMap` is a linear scan, 8 to 24 times slower than hashing
  on a miss. → Replaced with a hashed tag table (§2.6).
- Checking the literals first in `intern` is about 14 times slower on
  the hot path. → Replaced with lazy seeding (§4.2).
- Reserve `0xFFFF_FFFF`, never write an id as a number in a module's
  Zig, and range-check `from_int`. → Adopted (§2.3).
- Design A over B, and an 8-byte tagged symbol is not worth it. →
  Recorded (§4.4).

**Least-surprise purist.** Against landing as drafted.
- `@` has two meanings, and that is a blocker. → `$` is offered (§1.7,
  S2), and its grammar is checked with no conflicts.
- `.width` must not be accepted as a `Symbol`. → Adopted (§2.2).
- Behavior should not depend on unrelated modules. → S5 changed to no,
  and `from_text` is documented (§2.5).
- The typo rule is an exception list. → Dropped.
- Kotlin's precedent hurts: it gives `@` three roles.
- Land `.text` and `from_text` on enums first. → S0.

## 11. What argues against the change

1. **The case for symbols is narrow, and no real program needs them
   yet** (purist; Ruby review, finding 10). CORE §10 asks a feature to
   answer "a line that failed in a real program", and this draft names
   none.
   - With S7, a checked, exhaustive enum covers "turn known text into a
     name and match it".
   - JSON keys and other input arrive at run time and, under design A,
     become ids, not `Symbol`s.
   - Trig cannot use `:name` for its seeded names without quoted
     symbols, and it interns through its own Map (§4.5).

   Trig does compare text against literals often: 532 `== "..."` sites,
   though many are tests and paths. String patterns in `match`, lowered
   to the same static hash table, would serve those sites with no new
   type, no numbering pass, and no name clash. **What only symbols
   add:** a 4-byte tag that crosses modules without a shared
   declaration, and fast Map keys.
2. **`@` for labels breaks "one sigil, one meaning"** and the
   "`@` asks the compiler about a type" mantra. It also takes part of
   the reserved pin sigil (purist). `$` answers all three, at the cost
   of reading like a variable.
3. **Behavior can depend on unrelated modules.** `from_text`, and
   `U32(:x)` if it is exposed, change when any module, std included,
   adds a literal. §2.5 and S5 contain this; they do not remove it.
4. **The prototype's two parse regressions** show that `:` is now
   decided in four places. They are fixed in the design above, but the
   fixed classifier needs the tests in §8 before it is trusted.

None of the four reviews found a reason against moving labels off `:`.
That move removes the `while`-header exception, and it stands without
symbols.
